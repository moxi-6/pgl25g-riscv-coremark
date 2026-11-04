"""Decode the CoreMark ILA capture saved by the Fabric Debugger.

The Debugger stores sampled data in a WDF container where each channel is a Qt
QString: a big-endian 32-bit byte length followed by UTF-16BE text. A 512-deep
capture therefore appears as a length token of 1024 followed by 512 '0'/'1'
characters. Channel names use the same encoding immediately before their data,
which is how each block is identified without a full WDF parser.

This decoder emits one CSV row per sample plus a summary JSON that proves the
capture describes a running core: the 8-bit cycle counter must advance by one
per sample and the retirement counter must never move backwards.
"""
import argparse
import csv
import hashlib
import json
import re
from pathlib import Path

FIELDS = [
    ("commit_pc", 0, 32),
    ("commit_instr", 32, 32),
    ("commit_valid", 64, 1),
    ("ex_valid", 65, 1),
    ("ex_wait", 66, 1),
    ("redirect", 67, 1),
    ("dmem_valid", 68, 1),
    ("dmem_ready", 69, 1),
    ("dmem_write", 70, 1),
    ("imem_valid", 71, 1),
    ("imem_ready", 72, 1),
    ("imem_rvalid", 73, 1),
    ("fetch_valid", 74, 1),
    ("fetch_take", 75, 1),
    ("cycle_low", 76, 8),
    ("retire_low", 84, 8),
]


def decode(wdf: Path, project: Path, schema: Path, output: Path, depth: int) -> dict:
    raw = wdf.read_bytes()
    width = json.loads(schema.read_text(encoding="utf-8"))["debug_probe_width"]
    expected = [f"dbg_probe[{index}]" for index in range(width)]

    project_text = project.read_text(encoding="utf-8-sig")
    channel_names = re.findall(
        r"(?m)^Project\.Device<0>\.Core<0>\.DataChannel<\d+>=(.+)$", project_text
    )
    if channel_names != expected:
        raise ValueError(
            f"Debugger channel map mismatch: got {len(channel_names)} names, expected {width}"
        )

    names_at = {}
    for name in expected:
        token = len(name.encode("utf-16-be")).to_bytes(4, "big") + name.encode("utf-16-be")
        for match in re.finditer(re.escape(token), raw):
            names_at[match.start()] = name

    samples = {}
    order = []
    length_token = (depth * 2).to_bytes(4, "big")
    for match in re.finditer(re.escape(length_token), raw):
        offset = match.start()
        data = raw[offset + 4 : offset + 4 + depth * 2]
        if len(data) != depth * 2:
            continue
        try:
            bits = data.decode("utf-16-be")
        except UnicodeDecodeError:
            continue
        if not re.fullmatch(r"[01XZxz]{%d}" % depth, bits):
            continue
        preceding = [pos for pos in names_at if 0 < offset - pos <= 64]
        if not preceding:
            raise ValueError("Unlabelled sample block")
        name = names_at[max(preceding)]
        if name in samples:
            raise ValueError(f"Duplicate sample block for {name}")
        if re.search(r"[^01]", bits):
            raise ValueError(f"Unknown level in samples for {name}")
        samples[name] = bits
        order.append(name)

    if order != expected:
        raise ValueError(f"Expected {width} ordered sample blocks, got {len(order)}")

    rows = []
    for index in range(depth):
        row = {"sample": index}
        for name, lsb, bits_width in FIELDS:
            value = 0
            for bit in range(bits_width):
                if samples[f"dbg_probe[{lsb + bit}]"][index] == "1":
                    value |= 1 << bit
            row[name] = value
        rows.append(row)

    cycle_steps = [
        (right["cycle_low"] - left["cycle_low"]) & 0xFF
        for left, right in zip(rows, rows[1:])
    ]
    retire_deltas = [
        (right["retire_low"] - left["retire_low"]) & 0xFF
        for left, right in zip(rows, rows[1:])
    ]
    commits = sum(row["commit_valid"] for row in rows)
    dmem_accesses = sum(row["dmem_valid"] for row in rows)
    took_branches = sum(row["fetch_take"] for row in rows)
    pcs = [row["commit_pc"] for row in rows if row["commit_valid"]]

    output.mkdir(parents=True, exist_ok=True)
    with (output / "coremark_ila_samples.csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.writer(stream)
        writer.writerow(["sample"] + [name for name, _, _ in FIELDS])
        for row in rows:
            writer.writerow([row["sample"]] + [row[name] for name, _, _ in FIELDS])

    unique_pcs = sorted(set(pcs))
    result = {
        "wdf_sha256": hashlib.sha256(raw).hexdigest().upper(),
        "project_sha256": hashlib.sha256(project.read_bytes()).hexdigest().upper(),
        "sample_count": depth,
        "channels": width,
        "commit_valid_samples": commits,
        "dmem_access_samples": dmem_accesses,
        "fetch_take_samples": took_branches,
        "unique_commit_pcs": len(unique_pcs),
        "commit_pc_min": f"0x{min(pcs):08x}" if pcs else None,
        "commit_pc_max": f"0x{max(pcs):08x}" if pcs else None,
        "cycle_counter_advances_every_sample": all(step == 1 for step in cycle_steps),
        "retire_counter_monotonic": all(delta < 128 for delta in retire_deltas),
        "retire_counter_advanced": any(delta != 0 for delta in retire_deltas),
        "core_was_running": bool(commits > 0 and any(step == 1 for step in cycle_steps)),
        "first_commit_pcs": [f"0x{pc:08x}" for pc in pcs[:16]],
    }
    (output / "coremark_ila_summary.json").write_text(
        json.dumps(result, indent=2) + "\n", encoding="utf-8"
    )
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("wdf", type=Path)
    parser.add_argument("project", type=Path)
    parser.add_argument("schema", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--depth", type=int, default=512)
    args = parser.parse_args()
    print(json.dumps(
        decode(args.wdf, args.project, args.schema, args.output, args.depth),
        indent=2,
    ))
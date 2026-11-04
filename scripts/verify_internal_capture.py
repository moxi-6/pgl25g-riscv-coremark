"""Check this diagnostic's named 512-bit waveforms in PDS 2022.2 WDF.

This is a bounded extractor for this capture, not a general WDF reader.
Raw WDF and the matching Debugger project remain the primary evidence.
"""
import argparse
import csv
import hashlib
import json
import re
from pathlib import Path


def verify(wdf: Path, project: Path, output: Path) -> dict:
    raw = wdf.read_bytes()
    expected = [f"count_q[{i}]" for i in range(24)] + [
        "nt_led[2]", "nt_sys_rst_n", "nt_led[3]"
    ]
    project_text = project.read_text(encoding="utf-8-sig")
    channel_names = re.findall(
        r"(?m)^Project\.Device<0>\.Core<0>\.DataChannel<\d+>=(.+)$",
        project_text,
    )
    if channel_names != expected:
        raise ValueError("Debugger channel map does not match the diagnostic")
    # PDS uses Qt QStrings: big-endian byte length, then UTF-16BE data.
    names_at = {}
    for name in expected:
        encoded = name.encode("utf-16-be")
        token = len(encoded).to_bytes(4, "big") + encoded
        for match in re.finditer(re.escape(token), raw):
            names_at[match.start()] = name
    samples = {}
    sampled_order = []
    length_token = (512 * 2).to_bytes(4, "big")
    for match in re.finditer(re.escape(length_token), raw):
        offset = match.start()
        data = raw[offset + 4:offset + 4 + 1024]
        if len(data) != 1024:
            continue
        try:
            bits = data.decode("utf-16-be")
        except UnicodeDecodeError:
            continue
        if not re.fullmatch(r"[01XZxz]{512}", bits):
            continue
        preceding = [pos for pos in names_at if 0 < offset - pos <= 64]
        if not preceding:
            raise ValueError("Unlabelled sample block")
        name = names_at[max(preceding)]
        if name in samples or re.search(r"[^01]", bits):
            raise ValueError(f"Duplicate or unknown samples for {name}")
        samples[name] = bits
        sampled_order.append(name)
    if sampled_order != expected:
        raise ValueError("Expected exactly 27 ordered and named sample blocks")
    counters = [
        sum(int(samples[expected[bit]][index]) << bit for bit in range(25))
        for index in range(512)
    ]
    increments = [
        (right - left) & ((1 << 25) - 1)
        for left, right in zip(counters, counters[1:])
    ]
    reset_values = sorted(set(samples["nt_sys_rst_n"]))
    led3_values = sorted(set(samples["nt_led[3]"]))
    inverse_matches = all(
        int(reset) ^ int(led) == 1
        for reset, led in zip(samples["nt_sys_rst_n"], samples["nt_led[3]"])
    )
    output.mkdir(parents=True, exist_ok=True)
    with (output / "internal_capture_512.csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.writer(stream)
        writer.writerow(["sample", "counter", "counter_hex", "reset_n", "led3_logic"])
        for index, counter in enumerate(counters):
            writer.writerow([index, counter, f"0x{counter:07x}",
                             samples["nt_sys_rst_n"][index], samples["nt_led[3]"][index]])
    result = {
        "wdf_sha256": hashlib.sha256(raw).hexdigest().upper(),
        "project_sha256": hashlib.sha256(project.read_bytes()).hexdigest().upper(),
        "sample_count": 512,
        "sampled_channels": 27,
        "counter_first": counters[0],
        "counter_last": counters[-1],
        "consecutive_plus_one_pairs": increments.count(1),
        "total_consecutive_pairs": len(increments),
        "counter_running_in_capture": all(delta == 1 for delta in increments),
        "reset_n_values": reset_values,
        "led3_logic_values": led3_values,
        "reset_inverse_matches_led3_logic": inverse_matches,
        "physical_led_output_verified": False,
        "sample_clock_frequency_measured": False,
    }
    (output / "internal_capture_summary.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("wdf", type=Path)
    parser.add_argument("project", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.wdf, args.project, args.output), ensure_ascii=False, indent=2))

"""Export measured board results and reproducible release identities for publication.

Original build artifacts are read only. Public text removes local user paths,
host names and cable identifiers. The manifest records both original and
published hashes so this transformation remains explicit.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
from pathlib import Path

from coremark_score import evaluate

ROOT = Path(__file__).resolve().parents[1]
DATE = "2026-11-04"
EVIDENCE = ROOT / "docs/evidence" / DATE
RELEASES = ROOT / "releases" / DATE
ENTRIES: list[dict] = []


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def relative(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def sanitize_text(text: str) -> str:
    project = str(ROOT).replace("\\", "/")
    # JSON strings are sanitized after decoding, so escaped paths cannot leak.
    text = text.replace("\\", "/")
    text = re.sub(re.escape(project), "<project>", text, flags=re.I)
    text = re.sub(r"C:/fpga/riscv_l50", "<pds-work>", text, flags=re.I)
    text = re.sub(r"C:/pango/PDS_[^/\s]+", "<pds-install>", text, flags=re.I)
    text = re.sub(r"[A-Za-z]:/Users/[^/\s]+", "<user-home>", text, flags=re.I)
    text = re.sub(r"[A-Za-z]:/[^\s\"'<>)}\]]+", "<local-path>", text)
    text = re.sub(r"(?m)^#Hostname:.*$", "#Hostname: <redacted>", text)
    text = re.sub(r"(?m)^(Cable index \d+:USB Cable II)/[^\r\n]*", r"\1/<redacted>", text)
    return text


def sanitize_json(value):
    if isinstance(value, dict):
        return {sanitize_text(k): ("<board-uart>" if k == "port" else sanitize_json(v)) for k, v in value.items()}
    if isinstance(value, list):
        return [sanitize_json(v) for v in value]
    return sanitize_text(value) if isinstance(value, str) else value


def emit(destination: Path, data: bytes, source: Path | None = None,
         transformation: str = "generated", sources: list[str] | None = None):
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)
    entry = {"path": relative(destination), "bytes": len(data),
             "sha256": sha(data), "transformation": transformation}
    if source is not None:
        original = source.read_bytes()
        entry.update(source=relative(source), original_bytes=len(original), original_sha256=sha(original))
    if sources:
        entry["derived_from"] = sources
    ENTRIES.append(entry)


def emit_json(destination: Path, value, source: Path | None = None,
              transformation="generated", sources=None):
    emit(destination, (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode(),
         source, transformation, sources)


def copy_artifact(source: Path, destination: Path, mode="raw"):
    raw = source.read_bytes()
    if mode == "raw":
        data = raw
    elif mode == "json":
        data = (json.dumps(sanitize_json(json.loads(raw.decode("utf-8-sig"))),
                           ensure_ascii=False, indent=2) + "\n").encode()
    else:
        data = sanitize_text(raw.decode("utf-8-sig")).encode()
    emit(destination, data, source, "byte-identical" if mode == "raw" else "local-path-and-host-redaction")


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def verify_original_release(path):
    release = read_json(path / "release.json")
    for item in release["files"]:
        assert sha((path / item["file"]).read_bytes()) == item["sha256"].lower(), item["file"]
    return release


def publish_target(name, target, capture_name):
    original = ROOT / "build/board_release" / target / name
    release = verify_original_release(original)
    capture = ROOT / "build/uart_capture" / capture_name
    out = EVIDENCE / name
    public_release = RELEASES / name
    top = release["top"]
    program_path = (capture / "program_result.json" if (capture / "program_result.json").exists()
                    else ROOT / "build" / f"{target}_sram_result.json")
    program = read_json(program_path)
    bit_hash = sha((original / f"{top}.sbit").read_bytes())
    assert program["bitstream_sha256"].lower() == bit_hash
    assert program["programmed_sram"] and program["readback_verified"]
    assert program["done_asserted"] and program["gouten_asserted"] and program["status_sources_agree"]

    for filename in ("capture.txt", "capture.bin"):
        copy_artifact(capture / filename, out / filename)
    copy_artifact(capture / "result.json", out / "capture_metadata.json", "json")
    copy_artifact(program_path, out / "program_result.json", "json")
    copy_artifact(ROOT / "build" / f"{target}_sram_program.log", out / "program_log.txt", "text")
    for source_name, public_name in (("timing.rtr", "timing.rtr"), ("device_map.log", "device_map.txt"),
                                     ("timing.log", "timing_tool.txt"), ("pins.pcf", "pins.pcf"),
                                     ("constraints.fdc", "constraints.fdc")):
        copy_artifact(original / source_name, out / public_name, "text")
    copy_artifact(original / "run_inputs.json", out / "build_inputs.json", "json")

    checks = sanitize_json(read_json(original / "implementation_checks.json"))
    checks["original_report_sha256"] = {
        key: checks.pop(key) for key in ("map_log_sha256", "timing_report_sha256", "timing_log_sha256")}
    checks["public_report_sha256"] = {
        filename: sha((out / filename).read_bytes())
        for filename in ("timing.rtr", "device_map.txt", "timing_tool.txt")}
    emit_json(out / "implementation_checks.json", checks, original / "implementation_checks.json",
              "redaction-with-original-and-public-report-hashes")

    for filename in (f"{top}.sbit", f"{top}.smsk", "firmware.hex", "build_flags.txt"):
        copy_artifact(original / filename, public_release / filename)
    copy_artifact(original / "firmware.json", public_release / "firmware_manifest.json", "json")
    for filename in ("firmware.hex.even", "firmware.hex.odd", "mine_font.hex", "mine_font_map.json"):
        if (original / filename).exists():
            copy_artifact(original / filename, public_release / filename)

    public_files = [item for item in ENTRIES if item["path"].startswith(relative(public_release) + "/")]
    emit_json(public_release / "manifest.json", {
        "date": DATE, "target": target, "application": name, "top": top,
        "device": "PGL25G", "package": "MBG324", "speed_grade": "-6",
        "configuration": "SRAM", "flash_written": program["flash_written"],
        "programming_evidence": relative(out / "program_result.json"),
        "runtime_evidence": relative(out / "capture.txt"),
        "implementation_evidence": relative(out / "implementation_checks.json"),
        "bitstream_sha256": bit_hash,
        "files": [{"file": Path(item["path"]).name, "bytes": item["bytes"], "sha256": item["sha256"]}
                  for item in public_files],
        "rebuild": {
            "firmware": ("scripts/build_firmware.ps1 -App coremark -Isa rv32i_zba_zbb_zmmul -Opt '-O3' -Relax 1 -ExtraCflags '-flto -finline-limit=1000' -RamBytes 8192 -Rebuild"
                         if name == "coremark" else "scripts/build_firmware.ps1 -App mine -Isa rv32i -RamBytes 16384 -Rebuild"),
            "bitstream": f"scripts/run_pds.ps1 -Target {target} -FirmwareApp {name} -ConstraintProfile Vcc33 -Stage Bitstream -WorkRoot <ascii-build-directory>",
            "identity": "Firmware source hashes identify the build inputs. Placement and bitstream generation may vary between PDS runs."
        }
    }, sources=[relative(original / "release.json"), relative(program_path)])
    return original, out, capture


def main():
    cpu_original, cpu_out, cpu_capture = publish_target("coremark", "cpu", "coremark_r9_25mhz_20261104_02")
    mine_original, mine_out, mine_capture = publish_target("mine", "mine", "mine_board_20261104_02")

    score = evaluate((cpu_out / "capture.txt").read_text(), 25_000_000, "BoardCapture", 11864)
    assert score["verdict"] == "PASS" and score["iterations"] == 2000 and score["total_ticks"] == 398164697
    score.update(capture="capture.txt", capture_sha256=sha((cpu_out / "capture.txt").read_bytes()),
                 formula={"seconds": "total_ticks / clock_hz", "coremark": "iterations * clock_hz / total_ticks",
                          "coremark_per_mhz": "iterations * 1000000 / total_ticks"},
                 printed_integer_rate_note="HAS_FLOAT=0 prints whole seconds and an integer rate; exact score uses the raw tick count.")
    emit_json(cpu_out / "score.json", score, cpu_capture / "coremark_score.json", "independently-recomputed-from-raw-capture")

    simulation_rows = []
    for stage, label in (
        ("R2", "cpu_r2_20261104"), ("R4", "cpu_r4_zmmul_20261104"),
        ("R5", "cpu_r5_fastmem_20261104"), ("R6", "cpu_r4_o3_lto_inline_b_20261104"),
        ("R7", "cpu_r7_dual_20261104"), ("R8 BTB16", "cpu_r8_dualbranch_20261104"),
        ("R9 BTB128", "cpu_r9_mul2_btb128_20261104")):
        profile = ROOT / "build/optimization_20261103" / label
        summary = read_json(profile / "summary.json")
        run_log = (profile / "run.log").read_text(encoding="utf-8-sig")
        assert summary["status"] == "PASS" and "[PASS] coremark" in run_log
        crcs = {}
        for field in ("seedcrc", "[0]crclist", "[0]crcmatrix", "[0]crcstate"):
            match = re.search(r"^UART\[\d+\] " + re.escape(field) + r"\s*:\s*(0x[0-9a-fA-F]+)", run_log, re.M)
            assert match, (label, field)
            crcs[field] = match[1]
        summary_out = cpu_out / "simulation" / f"{label}.json"
        copy_artifact(profile / "summary.json", summary_out, "json")
        copy_artifact(profile / "run.log", cpu_out / "simulation" / f"{label}.txt", "text")
        simulation_rows.append({"stage": stage, "original_label": label,
                                "configuration": summary.get("configuration", {}),
                                "cycles": summary["metrics"]["cycles"],
                                "retired": summary["metrics"]["retired"],
                                "projected_coremark_per_mhz": 1_000_000 / summary["metrics"]["cycles"],
                                "crcs": crcs, "summary": relative(summary_out),
                                "scope": "Single-iteration simulation; CRC check passed; not a >=10-second board score."})
    emit_json(cpu_out / "simulation_comparison.json", {"evidence_type": "simulation", "rows": simulation_rows,
              "comparison_scope": "Compiler settings, instruction extensions and memory/pipeline configuration differ between rows; compare complete configurations."})

    audit_source = ROOT / "build/mine_audit.json"
    audit = sanitize_json(read_json(audit_source))
    # The automated audit checks files/pins; operator confirmation is a separate
    # evidence item and must not be silently presented as an automated check.
    audit.pop("physical_display_verified", None)
    audit.pop("physical_display_evidence", None)
    audit["scope"] = "Automated pin, voltage-configuration, source and artifact identity checks."
    emit_json(mine_out / "pin_and_source_audit.json", audit, audit_source, "automated-checks-only")
    emit_json(mine_out / "operator_acceptance.json", {
        "date": DATE, "target": "mine", "board": "ATK-L50 / PGL25G",
        "evidence_type": "operator_confirmation", "result": "accepted",
        "display_and_controls": "normal", "scope": "Displayed minesweeper interface and interactive operation after SRAM loading.",
        "bitstream_sha256": sha((mine_original / "atk_l50_mine.sbit").read_bytes()),
        "independent_machine_evidence": ["capture.txt", "program_result.json"],
        "source": "Board operator confirmation recorded on 2026-11-04"
    })
    copy_artifact(ROOT / "build/mine_checks/tb_mine.run.log", mine_out / "simulation_integration.txt", "text")
    copy_artifact(ROOT / "build/mine_checks/tb_mine_top_smoke.run.log", mine_out / "simulation_top_smoke.txt", "text")
    for name in ("initial", "lost", "stage3", "won"):
        copy_artifact(ROOT / f"build/mine_checks/{name}.png", mine_out / f"simulation_{name}.png")

    ila = ROOT / "build/coremark_ila"
    ila_out = EVIDENCE / "historical_ila"
    copy_artifact(ila / "coremark_ila_summary.json", ila_out / "summary.json", "json")
    copy_artifact(ila / "capture_result.json", ila_out / "capture_metadata.json", "json")
    copy_artifact(ila / "coremark_ila_samples.csv", ila_out / "samples.csv", "text")
    copy_artifact(ila / "coremark_ila_512.wdf", ila_out / "wave.wdf")
    copy_artifact(ila / "probe_schema.json", ila_out / "probe_schema.json", "json")
    emit_json(ila_out / "scope.json", {
        "captured_date": "2026-11-01", "evidence_type": "hardware_ila",
        "configuration": "Earlier single-issue CPU with debug instrumentation",
        "samples": 512, "channels": 92, "valid_commit_samples": 149,
        "scope": "Historical proof of running CPU and advancing counters. This is not an ILA capture of the 2026-11-04 dual-issue release.",
        "bitstream_sha256": read_json(ila / "capture_result.json")["bitstream_sha256"].lower()
    })

    emit_json(EVIDENCE / "results.json", {
        "date": DATE, "platform": "ATK-L50 / PGL25G / -6 / MBG324",
        "coremark": {key: score[key] for key in ("iterations", "total_ticks", "clock_hz", "seconds",
                    "coremark_score", "coremark_per_mhz", "coremark_per_lut", "seedcrc", "crclist", "crcmatrix", "crcstate", "crcfinal", "verdict")},
        "mine": {"stages": 8, "simulation_assertions": 1882, "simulation_cycles": 6257589,
                 "sram_readback_verified": True, "operator_acceptance": "accepted",
                 "simulation_previews": "mine/simulation_*.png"},
        "evidence_scope": {"coremark": "One measured performance-seed run lasting 15.92658788 s at a configured 25 MHz CPU clock.",
                           "mine": "Board boot UART, SRAM readback and operator acceptance; exhaustive eight-stage checks are simulation evidence.",
                           "timing": "PDS post-route reports; external LCD setup/hold budget is provisional and board skew was not measured."}
    })
    manifest = {
        "schema_version": 1, "date": DATE, "hash": "SHA256",
        "source_path_base": "project repository root", "published_path_base": "project repository root",
        "redactions": ["Personal absolute paths replaced by project/work/install placeholders", "Host name removed",
                       "JTAG cable unique identifier removed", "Local serial-port number replaced by board-uart placeholder"],
        "original_artifacts": "Original files remain unchanged in the local build directory.",
        "entries": ENTRIES
    }
    (EVIDENCE / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    for item in ENTRIES:
        path = ROOT / item["path"]
        assert sha(path.read_bytes()) == item["sha256"]
        raw = path.read_bytes()
        private_tokens = {str(ROOT), str(ROOT).replace("\\", "/"), Path.home().name}
        private_tokens.update(value for name in ('USERNAME', 'COMPUTERNAME') if (value := os.environ.get(name)))
        for private in private_tokens:
            assert private.encode() not in raw and private.encode("utf-16le") not in raw, (path, private)
        if path.suffix not in (".sbit", ".smsk", ".bin", ".png"):
            assert not re.search(rb"[A-Za-z]:[/\\]", raw), f"Unredacted absolute path: {path}"
    print(f"[PASS] Public evidence: {len(ENTRIES)} files with original/public hashes; bitstreams unchanged")
    print(relative(EVIDENCE / "manifest.json"))


if __name__ == "__main__":
    main()

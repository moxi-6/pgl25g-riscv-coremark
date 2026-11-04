#!/usr/bin/env python3
"""Check banked instruction ROM initialization, boundaries and both ports."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
from split_imem_banks import split_imem_banks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--words", nargs="+", type=int, default=[1, 2, 5, 8, 16384])
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[1]
    out = project / "build" / "imem_pair"
    out.mkdir(parents=True, exist_ok=True)
    tool_dir = project.parent / "tools" / "iverilog" / "bin"
    sources = ["rtl/soc/sync_imem.sv", "sim/tb_imem_pair.sv"]
    results = []
    for words in args.words:
        if words < 1:
            parser.error("--words values must be positive")
        image = out / f"input_{words}.hex"
        initialized = words - 3 if words > 4 else words - 1
        image.write_text("".join(f"{(0x9e3779b9 ^ ((i * 0x01010203) & 0xffffffff)):08x}\n"
                                 for i in range(initialized)), encoding="ascii")
        bank_evidence = split_imem_banks(image, words)
        executable = out / f"pair_{words}.vvp"
        executable.unlink(missing_ok=True)
        compile_cmd = [str(tool_dir / "iverilog.exe"), "-g2012", "-s", "tb_imem_pair",
                       f"-Ptb_imem_pair.WORDS={words}",
                       f'-Ptb_imem_pair.INIT_FILE="{image.relative_to(project).as_posix()}"',
                       "-o", str(executable)] + sources
        compile_result = subprocess.run(compile_cmd, cwd=project, capture_output=True, text=True)
        (out / f"pair_{words}.compile.log").write_text(compile_result.stdout + compile_result.stderr, encoding="utf-8")
        if compile_result.returncode:
            raise RuntimeError(f"WORDS={words} compile failed; see {out / f'pair_{words}.compile.log'}")
        run = subprocess.run([str(tool_dir / "vvp.exe"), str(executable)], cwd=project,
                             capture_output=True, text=True, timeout=90)
        (out / f"pair_{words}.run.log").write_text(run.stdout + run.stderr, encoding="utf-8")
        print(run.stdout, end="", flush=True)
        passed = run.returncode == 0 and f"[PASS] imem_pair WORDS={words} " in run.stdout
        results.append({"words": words, "passed": passed, "returncode": run.returncode,
                        "initialization": bank_evidence})
        if not passed:
            raise RuntimeError(f"WORDS={words} simulation failed; see {out / f'pair_{words}.run.log'}")
    evidence_sources = sources + ["scripts/split_imem_banks.py", "scripts/run_imem_pair_checks.py"]
    evidence = {"results": results, "source_sha256": {
        source: hashlib.sha256((project / source).read_bytes()).hexdigest() for source in evidence_sources}}
    (out / "summary.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()

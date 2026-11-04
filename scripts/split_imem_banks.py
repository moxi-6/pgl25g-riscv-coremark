#!/usr/bin/env python3
"""Generate direct-readmemh even/odd ROM banks from a verified 32-bit hex image.

Output paths append .even and .odd to the input path, as sync_imem expects.
Unspecified words and the unused odd word of odd-sized ROMs contain EBREAK.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

EBREAK = 0x00100073


def split_imem_banks(source: Path, words: int = 16384) -> dict:
    source = Path(source)
    if words < 1:
        raise ValueError("ROM word count must be positive")
    text = source.read_text(encoding="ascii")
    text = re.sub(r"/\*.*?\*/|//[^\n]*", " ", text, flags=re.DOTALL)
    image = [EBREAK] * words
    index = 0
    initialized = 0
    for token in text.split():
        token = token.replace("_", "")
        if token.startswith("@"):
            if not re.fullmatch(r"@[0-9a-fA-F]+", token):
                raise ValueError(f"Invalid ROM address token: {token!r}")
            index = int(token[1:], 16)
            if index >= words:
                raise ValueError(f"ROM address {index} exceeds {words} words")
        else:
            if not re.fullmatch(r"[0-9a-fA-F]{1,8}", token):
                raise ValueError(f"Invalid 32-bit ROM word: {token!r}")
            if index >= words:
                raise ValueError(f"ROM image exceeds {words} words")
            image[index] = int(token, 16)
            index += 1
            initialized += 1
    if words % 2:
        image.append(EBREAK)
    paths = [Path(str(source) + suffix) for suffix in (".even", ".odd")]
    for parity, destination in enumerate(paths):
        destination.write_text("".join(f"{value:08x}\n" for value in image[parity::2]), encoding="ascii")
    return {
        "source": str(source), "words": words, "initialized_words": initialized,
        "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "banks": {p.name: {"words": (words + 1) // 2,
                           "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p in paths},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--words", type=int, default=16384)
    args = parser.parse_args()
    print(json.dumps(split_imem_banks(args.source, args.words), indent=2))


if __name__ == "__main__":
    main()

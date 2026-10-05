#!/usr/bin/env python3
"""Assemble a pin_engine program into one hex byte per line.

Mnemonics match src/pin_engine.v:

    HALT     0x00
    NOP      0x10   unknown opcode: pc advances, pin unchanged, no hold
    SET 0    0x20
    SET 1    0x21
    SHIFT    0x30

Blank lines and comments (`;` or `//`) are ignored. Output is padded to 16
bytes with HALT, which is the size of imem.
"""

import sys


def encode(line: str):
    line = line.split(";", 1)[0].split("//", 1)[0].strip()
    if not line:
        return None
    parts = line.replace(",", " ").split()
    op = parts[0].upper()
    if op == "HALT" and len(parts) == 1:
        return 0x00
    if op == "NOP" and len(parts) == 1:
        return 0x10
    if op == "SHIFT" and len(parts) == 1:
        return 0x30
    if op == "SET" and len(parts) == 2 and parts[1] in ("0", "1"):
        return 0x20 | int(parts[1])
    raise ValueError(f"bad instruction: {line}")


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(f"usage: {sys.argv[0]} program.asm program.hex")
    src, dst = sys.argv[1], sys.argv[2]
    words = []
    with open(src) as handle:
        for lineno, line in enumerate(handle, 1):
            try:
                word = encode(line)
            except ValueError as exc:
                raise SystemExit(f"{src}:{lineno}: {exc}") from exc
            if word is not None:
                words.append(word)
    if len(words) > 16:
        raise SystemExit(f"{src}: {len(words)} words, imem holds 16")
    words.extend([0x00] * (16 - len(words)))
    with open(dst, "w") as handle:
        for word in words:
            handle.write(f"{word:02x}\n")


if __name__ == "__main__":
    main()

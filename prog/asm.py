#!/usr/bin/env python3
"""Assemble a pin_engine program into one 16-bit word per line.

Mnemonics match src/pin_engine.v and docs/instruction_definition.html.
Fields the line omits are 0. `side` is a flag. `setx` and `xdec` are flags.

    HALT
    WAIT role=0 val=0 hold=none
    SET role=0 val=0 hold=T setx
    SHIFT role=0 hold=T xdec back=0
    IN role=2 side side_val=1 hold=Thi xdec back=1
    OD role=0 val=pull side side_val=release hold=Tlo
    ODSHIFT role=0 side side_val=pull hold=Tlo
    HOLD hold=T/2 setx
    .word 0x2001

hold is T, T/2, Tlo, Thi, 1, or none. val is 0, 1, pull, or release.
Blank lines and comments (`;` or `//`) are ignored. Output is padded to 32
words with HALT, which is the size of imem.
"""

import sys

OPS = {
    "HALT": 0x0,
    "WAIT": 0x1,
    "SET": 0x2,
    "SHIFT": 0x3,
    "IN": 0x4,
    "OD": 0x5,
    "ODSHIFT": 0x6,
    "HOLD": 0x7,
}

HOLDS = {
    "T": 0,
    "T/2": 1,
    "THALF": 1,
    "TLO": 2,
    "THI": 3,
    "1": 4,
    "NONE": 5,
}

LEVELS = {
    "0": 0,
    "1": 1,
    "PULL": 0,
    "RELEASE": 1,
}


def pack(op, role, val, side, side_val, hold, xdec, back, setx):
    return (
        ((op & 0xF) << 12)
        | ((role & 0x3) << 10)
        | ((val & 0x1) << 9)
        | ((side & 0x1) << 8)
        | ((side_val & 0x1) << 7)
        | ((hold & 0x7) << 4)
        | ((xdec & 0x1) << 3)
        | ((back & 0x3) << 1)
        | (setx & 0x1)
    )


def encode(line: str):
    line = line.split(";", 1)[0].split("//", 1)[0].strip()
    if not line:
        return None
    parts = line.replace(",", " ").split()
    head = parts[0].upper()
    if head == ".WORD":
        if len(parts) != 2:
            raise ValueError(f"bad instruction: {line}")
        return int(parts[1], 0) & 0xFFFF
    if head not in OPS:
        raise ValueError(f"bad instruction: {line}")

    role = val = side = side_val = hold = xdec = back = setx = 0
    for tok in parts[1:]:
        if "=" in tok:
            key, raw = tok.split("=", 1)
            key = key.lower()
            upper = raw.upper()
            if key == "role":
                role = int(raw, 0)
            elif key == "val":
                val = LEVELS[upper] if upper in LEVELS else int(raw, 0)
            elif key == "hold":
                if upper not in HOLDS:
                    raise ValueError(f"bad hold: {raw}")
                hold = HOLDS[upper]
            elif key == "back":
                back = int(raw, 0)
            elif key == "side_val":
                side_val = LEVELS[upper] if upper in LEVELS else int(raw, 0)
            else:
                raise ValueError(f"bad field: {tok}")
        else:
            flag = tok.lower()
            if flag == "setx":
                setx = 1
            elif flag == "xdec":
                xdec = 1
            elif flag == "side":
                side = 1
            else:
                raise ValueError(f"bad field: {tok}")

    if not 0 <= role <= 3 or not 0 <= back <= 3:
        raise ValueError(f"field out of range: {line}")
    return pack(OPS[head], role, val, side, side_val, hold, xdec, back, setx)


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(f"usage: {sys.argv[0]} program.asm program.hex")
    src, dst = sys.argv[1], sys.argv[2]
    words = []
    with open(src) as handle:
        for lineno, line in enumerate(handle, 1):
            try:
                word = encode(line)
            except (ValueError, KeyError) as exc:
                raise SystemExit(f"{src}:{lineno}: {exc}") from exc
            if word is not None:
                words.append(word)
    if len(words) > 32:
        raise SystemExit(f"{src}: {len(words)} words, imem holds 32")
    words.extend([0x0000] * (32 - len(words)))
    with open(dst, "w") as handle:
        for word in words:
            handle.write(f"{word:04x}\n")


if __name__ == "__main__":
    main()

"""Bit-cell model for prog/usb_ls_tx.asm.

A JMP does not write the pins, so its tick stays on the symbol already
driven. Idle and the trailer are T. A data bit with no stuff is T+2.
The bit that inserts a stuff, and the stuffed bit, are T+1.
"""


def machine_cells(packet, yreload, period):
    """Ticks prog/usb_ls_tx.asm spends on each symbol."""
    dp = 0
    ones = yreload
    cells = [("idle", dp, period)]
    for byte in packet:
        for i in range(8):
            bit = (byte >> i) & 1
            if bit == 0:
                dp ^= 1
                ones = yreload
                cells.append(("data", dp, period + 2))
            else:
                ones -= 1
                if ones == 0:
                    cells.append(("data", dp, period + 1))
                    dp ^= 1
                    ones = yreload
                    cells.append(("stuff", dp, period + 1))
                else:
                    cells.append(("data", dp, period + 2))
    cells.append(("se0", 0, period))
    cells.append(("se0", 0, period))
    cells.append(("j", 0, period))
    return cells


def wave(cells):
    samples = []
    for _kind, level, ticks in cells:
        samples.extend([level] * ticks)
    return samples


def cell_report(cells, period):
    lines = []
    for kind, level, ticks in cells:
        gap = ticks - period
        lines.append(f"{kind:5} D+={level} {ticks} ticks ({gap:+d})")
    return "\n".join(lines)

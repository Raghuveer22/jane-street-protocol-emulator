"""Bit-cell model for prog/usb_ls_tx.asm.

The claim under test: every symbol lasts T ticks, and a stuffed bit is
the same length as any other symbol. `uniform_cells` is that claim.
`machine_cells` is the schedule the program actually executes. A JMP
does not write the pins, so each JMP that sits between two pin writes
adds one tick to the cell it follows.
"""


def _walk(packet, yreload, period, extra):
    """`extra(kind)` is the ticks added after the pin write of that kind."""
    dp = 0
    ones = yreload
    cells = [("idle", dp, period + extra("idle"))]
    for byte in packet:
        for i in range(8):
            bit = (byte >> i) & 1
            if bit == 0:
                dp ^= 1
                ones = yreload
                cells.append(("data", dp, period + extra("data")))
            else:
                cells.append(("data", dp, period + extra("data")))
                ones -= 1
                if ones == 0:
                    dp ^= 1
                    ones = yreload
                    cells.append(("stuff", dp, period + extra("stuff")))
    for kind in ("se0", "se0", "j"):
        cells.append((kind, 0, period + extra(kind)))
    return cells


def uniform_cells(packet, yreload, period):
    """The claim: idle, data, stuff, and the trailer are all T ticks."""
    return _walk(packet, yreload, period, lambda _kind: 0)


def machine_cells(packet, yreload, period):
    """Ticks the program in prog/usb_ls_tx.asm spends on each symbol.

    SET of idle and of the trailer is followed by another pin write, so
    those cells are T. A data bit that does not stuff is followed by two
    JMPs. The data bit that reaches Y = 0, and the stuffed toggle after
    it, are each followed by one JMP.
    """

    def extra(kind):
        if kind == "data":
            return None
        if kind == "stuff":
            return 1
        return 0

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


def run_lengths(samples):
    if not samples:
        return []
    runs = []
    level = samples[0]
    count = 1
    for sample in samples[1:]:
        if sample == level:
            count += 1
        else:
            runs.append((level, count))
            level = sample
            count = 1
    runs.append((level, count))
    return runs


def cell_report(cells, period):
    lines = []
    for kind, level, ticks in cells:
        gap = ticks - period
        lines.append(f"{kind:5} D+={level} {ticks} ticks ({gap:+d})")
    return "\n".join(lines)

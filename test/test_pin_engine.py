"""Cocotb checks for the programmable pin engine.

UART 8N1 is one program. A second program only toggles the pin, which locks
the claim that the frame comes from imem rather than a hardcoded UART block.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer

CMD_PERIOD_LO = 0
CMD_PERIOD_HI = 1
CMD_SHIFT = 2
CMD_ADDR = 3
CMD_IMEM = 4
CMD_PC = 5
CMD_RUN = 6

OP_HALT = 0x00
OP_SET0 = 0x20
OP_SET1 = 0x21
OP_SHIFT = 0x30

# start, 8 data bits LSB first, stop
UART_PROG = [OP_SET0] + [OP_SHIFT] * 8 + [OP_SET1, OP_HALT]
TOGGLE_PROG = [OP_SET0, OP_SET1, OP_HALT]

def tx_of(dut):
    return int(dut.uo_out.value) & 1


def busy_of(dut):
    return (int(dut.uo_out.value) >> 1) & 1


async def step(dut):
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")


async def boot(dut):
    # Each test cancels the previous clock task, so start a fresh one.
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())

    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.ena.value = 1
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 2)
    dut.rst_n.value = 1
    await step(dut)


async def pulse(dut, cmd, data):
    dut.uio_in.value = data & 0xFF
    dut.ui_in.value = 1 | ((cmd & 7) << 1)
    await step(dut)
    dut.ui_in.value = 0


async def load_program(dut, words):
    await pulse(dut, CMD_ADDR, 0)
    for word in words:
        await pulse(dut, CMD_IMEM, word)


async def capture(dut, ncycles):
    """Run, then collect `ncycles` of tx starting at the first executed instruction."""
    await pulse(dut, CMD_RUN, 0)
    assert busy_of(dut) == 1, "RUN should accept before the first instruction"
    await step(dut)
    samples = [tx_of(dut)]
    for _ in range(ncycles - 1):
        await step(dut)
        samples.append(tx_of(dut))
    return samples


def uart_frame(byte, period):
    bits = [0] + [((byte >> i) & 1) for i in range(8)] + [1]
    wave = []
    for bit in bits:
        wave.extend([bit] * period)
    return wave


async def send_uart(dut, byte, period):
    await pulse(dut, CMD_PERIOD_LO, period & 0xFF)
    await pulse(dut, CMD_PERIOD_HI, (period >> 8) & 0xFF)
    await pulse(dut, CMD_SHIFT, byte)
    await pulse(dut, CMD_PC, 0)
    samples = await capture(dut, 10 * period)
    assert busy_of(dut) == 1, "busy should stay high through the stop bit"
    await step(dut)
    assert busy_of(dut) == 0, "HALT should drop busy on the clock after the stop bit"
    assert tx_of(dut) == 1
    return samples


@cocotb.test()
async def test_reset_idles_high(dut):
    await boot(dut)
    assert tx_of(dut) == 1
    assert busy_of(dut) == 0

    await pulse(dut, CMD_RUN, 0)
    await step(dut)
    assert tx_of(dut) == 1
    assert busy_of(dut) == 0, "empty imem is HALT, so RUN should stop immediately"


@cocotb.test()
async def test_uart_8n1(dut):
    await boot(dut)
    await load_program(dut, UART_PROG)

    for byte in (0x00, 0xFF, 0x55, 0xA5, 0x01):
        samples = await send_uart(dut, byte, period=4)
        assert samples == uart_frame(byte, 4), f"0x{byte:02X} frame mismatch"


@cocotb.test()
async def test_period_scales_and_zero_clamps(dut):
    await boot(dut)
    await load_program(dut, UART_PROG)

    slow = await send_uart(dut, 0x01, period=0x0102)
    assert slow == uart_frame(0x01, 0x0102)

    await pulse(dut, CMD_PERIOD_LO, 0)
    await pulse(dut, CMD_PERIOD_HI, 0)
    await pulse(dut, CMD_SHIFT, 0x00)
    await pulse(dut, CMD_PC, 0)
    clamped = await capture(dut, 10)
    await step(dut)
    assert clamped == uart_frame(0x00, 1)
    assert busy_of(dut) == 0


@cocotb.test()
async def test_toggle_program(dut):
    """A different program must change the pin. This is not a UART block."""
    await boot(dut)
    await load_program(dut, TOGGLE_PROG)
    await pulse(dut, CMD_PERIOD_LO, 3)
    await pulse(dut, CMD_PC, 0)
    samples = await capture(dut, 6)
    await step(dut)
    assert samples == [0, 0, 0, 1, 1, 1]
    assert busy_of(dut) == 0
    assert tx_of(dut) == 1


@cocotb.test()
async def test_writes_ignored_while_running(dut):
    await boot(dut)
    await load_program(dut, UART_PROG)
    await pulse(dut, CMD_PERIOD_LO, 4)
    await pulse(dut, CMD_SHIFT, 0xA5)
    await pulse(dut, CMD_PC, 0)

    await pulse(dut, CMD_RUN, 0)
    await step(dut)
    samples = [tx_of(dut)]

    # Hostile rewrite of the shift register on the second bit-clock.
    dut.uio_in.value = 0xFF
    dut.ui_in.value = 1 | (CMD_SHIFT << 1)
    await step(dut)
    dut.ui_in.value = 0
    samples.append(tx_of(dut))

    for _ in range(10 * 4 - 2):
        await step(dut)
        samples.append(tx_of(dut))

    assert samples == uart_frame(0xA5, 4)
    await step(dut)
    assert busy_of(dut) == 0


@cocotb.test()
async def test_reset_aborts_and_clears_program(dut):
    await boot(dut)
    await load_program(dut, TOGGLE_PROG)
    await pulse(dut, CMD_PERIOD_LO, 8)
    await pulse(dut, CMD_PC, 0)
    await pulse(dut, CMD_RUN, 0)
    await step(dut)
    assert tx_of(dut) == 0
    assert busy_of(dut) == 1

    dut.rst_n.value = 0
    await step(dut)
    assert tx_of(dut) == 1
    assert busy_of(dut) == 0

    dut.rst_n.value = 1
    await step(dut)
    await pulse(dut, CMD_RUN, 0)
    await step(dut)
    assert tx_of(dut) == 1
    assert busy_of(dut) == 0, "reset should wipe imem back to HALT"

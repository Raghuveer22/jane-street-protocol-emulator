"""Cocotb checks for the programmable pin engine.

UART transmit, UART receive, SPI mode 0, and I2C master are programs.
A toggle program locks the claim that the waveform comes from imem.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

CMD_ADDR = 0
CMD_WRITE = 1
CMD_PAYLOAD = 2
CMD_PC = 3
CMD_RUN = 4
CMD_READ = 5
CMD_PUSH = 6
CMD_POP = 7

# UART sender: start, eight data bits, stop, halt.
UART_TX = [0x2001, 0x3008, 0x2200, 0x0000]
# Different program. Not a UART frame.
TOGGLE = [0x2000, 0x2200, 0x0000]
# UART receiver. Stop is WAIT, so the eight data samples stay in the shift.
UART_RX = [0x1050, 0x7000, 0x7011, 0x4008, 0x1250, 0x0000]
# SPI mode 0, MSB first.
SPI = [0x2421, 0x3120, 0x49BA, 0x2620, 0x0000]
# I2C master. Address 10 reloads x so a later byte can start at pc 2.
I2C = [
    0x51A0, 0x5421, 0x6120, 0x5640, 0x1650, 0x403E,
    0x5320, 0x5640, 0x1650, 0x4030, 0x5421,
    0x5120, 0x5640, 0x1650, 0x53B0, 0x0000,
]

# Bindings. Pin 8 is uo[0]. Pin 15 is running, not a role.
TX = 0x68       # uo[0], push-pull, idle 1
RX = 0x04       # ui[4], input
MOSI = 0x48     # uo[0], push-pull, idle 0
CS = 0x69       # uo[1], push-pull, idle 1
MISO = 0x04     # ui[4], input
SCK = 0x4A      # uo[2], push-pull, idle 0
SDA = 0xB0      # uio[0], open-drain, idle released
SCL = 0xB1      # uio[1], open-drain, idle released
LSB8 = 0x08     # bit 0 first, xreload 8
MSB8 = 0xC8     # bit 7 first, both directions, xreload 8
LSB_PULL = 0x28 # LSB8 plus autopull
LSB_PUSH = 0x18 # LSB8 plus autopush
MSB_FIFO = 0xF8 # MSB8 plus autopull and autopush

# Looping forms. The one-byte programs above are unchanged.
UART_TX_STREAM = [0x2001, 0x3008, 0x220D]
UART_RX_STREAM = [0x1001, 0x7010, 0x4008, 0x125F]
SPI_STREAM = [0x2421, 0x3120, 0x49BB]
# Two nibbles, then halt. Side is SCK. Width and base come from 0x4C.
QSPI_OUT = [0x3140, 0x31C0, 0x0000]
# setx, then four shifts of one group. xreload is the number of groups.
QSPI_GROUPS = [0x7041, 0x3048, 0x0000]
QSPI_IN = [0x4040, 0x4040, 0x0000]


def uo(dut):
    return int(dut.uo_out.value)


def tx_of(dut):
    return uo(dut) & 1


def busy_of(dut):
    return (uo(dut) >> 7) & 1


def u16(value):
    return [value & 0xFF, (value >> 8) & 0xFF]


async def step(dut):
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")


async def boot(dut):
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.ena.value = 1
    dut.rst_n.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await step(dut)


async def pulse(dut, cmd, data):
    dut.uio_in.value = data & 0xFF
    dut.ui_in.value = 1 | ((cmd & 7) << 1)
    await step(dut)
    dut.ui_in.value = 0


async def load_bytes(dut, addr, blob):
    await pulse(dut, CMD_ADDR, addr)
    for byte in blob:
        await pulse(dut, CMD_WRITE, byte)


async def load_words(dut, words):
    blob = []
    for word in words:
        blob.extend(u16(word))
    await load_bytes(dut, 0x00, blob)


async def load_cfg(dut, t=1, tlo=1, thi=1, roles=(0, 0, 0, 0), side=0, dirs=LSB8):
    blob = u16(t) + u16(tlo) + u16(thi) + list(roles) + [side, dirs]
    await load_bytes(dut, 0x40, blob)


async def read_shift(dut):
    dut.ui_in.value = 1 | (CMD_READ << 1)
    await Timer(1, unit="ns")
    assert int(dut.uio_oe.value) == 0xFF
    value = int(dut.uio_out.value) & 0xFF
    await step(dut)
    dut.ui_in.value = 0
    await Timer(1, unit="ns")
    return value


def uart_frame(byte, period):
    bits = [0] + [((byte >> i) & 1) for i in range(8)] + [1]
    wave = []
    for bit in bits:
        wave.extend([bit] * period)
    return wave


async def capture(dut, ncycles):
    await pulse(dut, CMD_RUN, 0)
    assert busy_of(dut) == 1, "RUN should accept before the first instruction"
    await step(dut)
    samples = [tx_of(dut)]
    for _ in range(ncycles - 1):
        await step(dut)
        samples.append(tx_of(dut))
    return samples


async def send_uart(dut, byte, period):
    await load_bytes(dut, 0x40, u16(period))
    await pulse(dut, CMD_PAYLOAD, byte)
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
    await load_cfg(dut, roles=(TX, 0, 0, 0), dirs=LSB8)
    await load_words(dut, UART_TX)

    for byte in (0x00, 0xFF, 0x55, 0xA5, 0x01):
        samples = await send_uart(dut, byte, period=4)
        assert samples == uart_frame(byte, 4), f"0x{byte:02X} frame mismatch"


@cocotb.test()
async def test_period_scales_and_zero_clamps(dut):
    await boot(dut)
    await load_cfg(dut, roles=(TX, 0, 0, 0), dirs=LSB8)
    await load_words(dut, UART_TX)

    slow = await send_uart(dut, 0x01, period=0x0102)
    assert slow == uart_frame(0x01, 0x0102)

    await load_bytes(dut, 0x40, [0x00, 0x00])
    await pulse(dut, CMD_PAYLOAD, 0x00)
    await pulse(dut, CMD_PC, 0)
    clamped = await capture(dut, 10)
    await step(dut)
    assert clamped == uart_frame(0x00, 1)
    assert busy_of(dut) == 0


@cocotb.test()
async def test_toggle_program(dut):
    """A different program must change the pin. This is not a UART block."""
    await boot(dut)
    await load_cfg(dut, t=3, roles=(TX, 0, 0, 0), dirs=LSB8)
    await load_words(dut, TOGGLE)
    await pulse(dut, CMD_PC, 0)
    samples = await capture(dut, 6)
    await step(dut)
    assert samples == [0, 0, 0, 1, 1, 1]
    assert busy_of(dut) == 0
    assert tx_of(dut) == 1


@cocotb.test()
async def test_writes_ignored_while_running(dut):
    await boot(dut)
    await load_cfg(dut, t=4, roles=(TX, 0, 0, 0), dirs=LSB8)
    await load_words(dut, UART_TX)
    await pulse(dut, CMD_PAYLOAD, 0xA5)
    await pulse(dut, CMD_PC, 0)

    await pulse(dut, CMD_RUN, 0)
    await step(dut)
    samples = [tx_of(dut)]

    dut.uio_in.value = 0xFF
    dut.ui_in.value = 1 | (CMD_PAYLOAD << 1)
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
    await load_cfg(dut, t=8, roles=(TX, 0, 0, 0), dirs=LSB8)
    await load_words(dut, TOGGLE)
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


@cocotb.test()
async def test_uart_rx(dut):
    await boot(dut)
    period = 8
    await load_cfg(dut, t=period, roles=(RX, 0, 0, 0), dirs=LSB8)
    await load_words(dut, UART_RX)

    for byte in (0x00, 0xFF, 0xA5, 0x01, 0x80):
        got = await receive_uart(dut, byte, period)
        assert got == byte, f"RX 0x{byte:02X} assembled 0x{got:02X}"


async def receive_uart(dut, byte, period):
    """Drive an 8N1 frame on ui[4] and return the byte CMD_READ presents."""
    await pulse(dut, CMD_PC, 0)
    await pulse(dut, CMD_RUN, 0)
    assert busy_of(dut) == 1

    # Idle, long enough for WAIT to be the instruction that sees the fall.
    dut.ui_in.value = 0x10
    await step(dut)
    await step(dut)
    await step(dut)

    bits = [0] + [((byte >> i) & 1) for i in range(8)] + [1]
    for bit in bits:
        dut.ui_in.value = (bit & 1) << 4
        for _ in range(period):
            await step(dut)

    # The sample point sits 1 + T/2 ticks into the bit. Keep stop high until halt.
    dut.ui_in.value = 0x10
    for _ in range(period + 4):
        await step(dut)
        if busy_of(dut) == 0:
            break
    assert busy_of(dut) == 0, "receiver did not halt on the stop bit"
    return await read_shift(dut)


@cocotb.test()
async def test_spi_mode0(dut):
    await boot(dut)
    await load_cfg(dut, tlo=2, thi=2, roles=(MOSI, CS, MISO, 0), side=SCK, dirs=MSB8)
    await load_words(dut, SPI)
    for tx_byte, rx_byte in ((0xA5, 0x3C), (0x00, 0xFF), (0xFF, 0x01), (0x96, 0x96)):
        mosi, miso = await transfer_spi(dut, tx_byte, rx_byte)
        assert mosi == tx_byte, f"MOSI sent 0x{mosi:02X}, want 0x{tx_byte:02X}"
        assert miso == rx_byte, f"MISO got 0x{miso:02X}, want 0x{rx_byte:02X}"


async def transfer_spi(dut, tx_byte, rx_byte):
    await pulse(dut, CMD_PAYLOAD, tx_byte)
    await pulse(dut, CMD_PC, 0)
    # Side binding already idled SCK low and CS high. Restore that before a
    # second byte, because the last sample leaves SCK high.
    await load_bytes(dut, 0x4A, [SCK])
    await pulse(dut, CMD_RUN, 0)
    assert busy_of(dut) == 1
    assert (uo(dut) & 0x06) == 0x02, "CS should idle high and SCK low"

    bit_i = 0
    captured = []
    prev_sck = (uo(dut) >> 2) & 1
    for _ in range(80):
        cs = (uo(dut) >> 1) & 1
        sck = (uo(dut) >> 2) & 1
        if cs == 0 and sck == 0 and bit_i < 8:
            dut.ui_in.value = ((rx_byte >> (7 - bit_i)) & 1) << 4
        else:
            dut.ui_in.value = 0
        await step(dut)
        cs = (uo(dut) >> 1) & 1
        sck = (uo(dut) >> 2) & 1
        mosi = uo(dut) & 1
        if prev_sck == 0 and sck == 1 and cs == 0 and bit_i < 8:
            captured.append(mosi)
            bit_i += 1
        prev_sck = sck
        if busy_of(dut) == 0 and bit_i == 8:
            break
    assert bit_i == 8, f"saw {bit_i} rising edges"
    assert busy_of(dut) == 0
    sent = 0
    for bit in captured:
        sent = ((sent << 1) | bit) & 0xFF
    got = await read_shift(dut)
    return sent, got


@cocotb.test()
async def test_i2c_master(dut):
    await boot(dut)
    await load_cfg(dut, tlo=2, thi=2, roles=(SDA, SCL, 0, 0), side=SCL, dirs=MSB8)
    await load_words(dut, I2C)

    plain = await transfer_i2c(dut, 0xA5, ack=0, stretch=0)
    assert plain["ack"] == 0
    assert plain["start"]
    assert plain["stop"]
    assert plain["data"] == [1, 0, 1, 0, 0, 1, 0, 1]

    nack = await transfer_i2c(dut, 0xA5, ack=1, stretch=0)
    assert nack["ack"] == 1

    stretched = await transfer_i2c(dut, 0x55, ack=0, stretch=5)
    assert stretched["ack"] == 0
    assert stretched["cycles"] >= plain["cycles"] + 5
    assert stretched["data"] == [0, 1, 0, 1, 0, 1, 0, 1]


@cocotb.test()
async def test_i2c_second_byte_holds_the_bus(dut):
    await boot(dut)
    await load_cfg(dut, tlo=2, thi=2, roles=(SDA, SCL, 0, 0), side=SCL, dirs=MSB8)
    held = I2C[:11] + [0x0000]
    await load_words(dut, held)

    first = await transfer_i2c(dut, 0xA0, ack=0, stretch=0, full_stop=False)
    assert first["ack"] == 0
    assert (int(dut.uio_oe.value) & 0x02) == 0x02, "SCL should stay pulled"

    second = await transfer_i2c(dut, 0x5A, ack=0, stretch=0, full_stop=False, pc=2)
    assert second["ack"] == 0
    assert second["data"] == [0, 1, 0, 1, 1, 0, 1, 0]
    assert (int(dut.uio_oe.value) & 0x02) == 0x02


async def transfer_i2c(dut, byte, ack, stretch, full_stop=True, pc=0):
    await pulse(dut, CMD_PAYLOAD, byte)
    await pulse(dut, CMD_PC, pc)
    await pulse(dut, CMD_RUN, 0)
    dut.uio_in.value = 0xFF
    assert busy_of(dut) == 1

    prev_scl_oe = (int(dut.uio_oe.value) >> 1) & 1
    releases = 0
    stretch_left = 0
    ack_pull = False
    data_bits = []
    saw_start = False
    cycles = 0
    prev_sda_pull = 0

    for _ in range(400):
        holding = stretch_left > 0
        level = 0xFF
        if holding:
            level &= ~0x02
        if ack_pull:
            level &= ~0x01
        dut.uio_in.value = level
        await step(dut)
        cycles += 1

        oe = int(dut.uio_oe.value)
        out = int(dut.uio_out.value)
        sda_oe = oe & 1
        scl_oe = (oe >> 1) & 1
        sda_pull = 1 if (sda_oe and not (out & 1)) else 0
        scl_pull = 1 if (scl_oe and not ((out >> 1) & 1)) else 0

        if sda_pull and not scl_pull and not prev_sda_pull:
            saw_start = True
        prev_sda_pull = sda_pull

        if holding:
            stretch_left -= 1

        if prev_scl_oe and not scl_oe:
            releases += 1
            if releases <= 8:
                data_bits.append(0 if sda_pull else 1)
            if releases == 1 and stretch:
                stretch_left = stretch
            if releases == 9:
                ack_pull = ack == 0
        if not prev_scl_oe and scl_oe and releases >= 9:
            ack_pull = False
        prev_scl_oe = scl_oe

        if busy_of(dut) == 0:
            break
    else:
        raise AssertionError("I2C program did not halt")

    assert busy_of(dut) == 0
    shift = await read_shift(dut)
    stopped = (int(dut.uio_oe.value) & 0x03) == 0
    return {
        "ack": shift & 1,
        "start": saw_start,
        "stop": stopped if full_stop else True,
        "data": data_bits,
        "cycles": cycles,
    }


def contains(haystack, needle):
    n = len(needle)
    return any(haystack[i:i + n] == needle for i in range(len(haystack) - n + 1))


async def pop_rx(dut, ui_rest=0):
    """Pop one RX FIFO byte. ui_rest keeps protocol input bits, usually RX idle."""
    dut.ui_in.value = (ui_rest & 0xF0) | 1 | (CMD_POP << 1)
    await Timer(1, unit="ns")
    assert int(dut.uio_oe.value) == 0xFF
    value = int(dut.uio_out.value) & 0xFF
    await step(dut)
    dut.ui_in.value = ui_rest & 0xF0
    await Timer(1, unit="ns")
    return value


@cocotb.test()
async def test_uart_stream_back_to_back(dut):
    """Three preloaded bytes leave the wire with no idle gap between frames."""
    await boot(dut)
    await load_cfg(dut, t=4, roles=(TX, 0, 0, 0), dirs=LSB_PULL)
    await load_words(dut, UART_TX_STREAM)
    await pulse(dut, CMD_PAYLOAD, 0x55)
    await pulse(dut, CMD_PUSH, 0xA5)
    await pulse(dut, CMD_PUSH, 0x01)
    await pulse(dut, CMD_PC, 0)

    samples = await capture(dut, 30 * 4)
    assert samples == (
        uart_frame(0x55, 4) + uart_frame(0xA5, 4) + uart_frame(0x01, 4)
    )
    await step(dut)
    assert busy_of(dut) == 1
    assert tx_of(dut) == 1, "an empty TX FIFO holds the line at idle"

    await pulse(dut, CMD_PUSH, 0x0F)
    extra = [tx_of(dut)]
    for _ in range(10 * 4 + 2):
        await step(dut)
        extra.append(tx_of(dut))
    assert contains(extra, uart_frame(0x0F, 4))


@cocotb.test()
async def test_uart_stream_push_during_the_frame(dut):
    """A push in the middle of a bit does not stretch that bit."""
    await boot(dut)
    await load_cfg(dut, t=4, roles=(TX, 0, 0, 0), dirs=LSB_PULL)
    await load_words(dut, UART_TX_STREAM)
    await pulse(dut, CMD_PAYLOAD, 0x55)
    await pulse(dut, CMD_PC, 0)
    await pulse(dut, CMD_RUN, 0)
    await step(dut)
    samples = [tx_of(dut)]
    await step(dut)
    samples.append(tx_of(dut))
    await pulse(dut, CMD_PUSH, 0xA5)
    samples.append(tx_of(dut))
    for _ in range(10 * 4 - 3):
        await step(dut)
        samples.append(tx_of(dut))
    for _ in range(10 * 4):
        await step(dut)
        samples.append(tx_of(dut))
    assert samples == uart_frame(0x55, 4) + uart_frame(0xA5, 4)


@cocotb.test()
async def test_uart_rx_autopush(dut):
    await boot(dut)
    period = 4
    await load_cfg(dut, t=period, roles=(RX, 0, 0, 0), dirs=LSB_PUSH)
    await load_words(dut, UART_RX_STREAM)
    await pulse(dut, CMD_PC, 0)
    await pulse(dut, CMD_RUN, 0)
    assert busy_of(dut) == 1

    dut.ui_in.value = 0x10
    for _ in range(3):
        await step(dut)

    for byte in (0xA5, 0x5A):
        bits = [0] + [((byte >> i) & 1) for i in range(8)] + [1]
        for bit in bits:
            dut.ui_in.value = (bit & 1) << 4
            for _ in range(period):
                await step(dut)

    dut.ui_in.value = 0x10
    for _ in range(period + 4):
        await step(dut)

    assert await pop_rx(dut, ui_rest=0x10) == 0xA5
    assert await pop_rx(dut, ui_rest=0x10) == 0x5A
    assert busy_of(dut) == 1, "the receiver stays armed for another start"


@cocotb.test()
async def test_spi_stream_two_bytes(dut):
    """CS stays low and the clock does not pause between the two bytes."""
    await boot(dut)
    await load_cfg(
        dut, tlo=2, thi=2, roles=(MOSI, CS, MISO, 0), side=SCK, dirs=MSB_FIFO
    )
    await load_words(dut, SPI_STREAM)
    await pulse(dut, CMD_PAYLOAD, 0xA5)
    await pulse(dut, CMD_PUSH, 0x3C)
    await pulse(dut, CMD_PC, 0)
    await load_bytes(dut, 0x4A, [SCK])
    await pulse(dut, CMD_RUN, 0)
    assert busy_of(dut) == 1

    rx_bytes = (0x96, 0x0F)
    bit_i = 0
    captured = []
    prev_sck = (uo(dut) >> 2) & 1
    for _ in range(120):
        cs = (uo(dut) >> 1) & 1
        sck = (uo(dut) >> 2) & 1
        if cs == 0 and sck == 0 and bit_i < 16:
            rx_byte = rx_bytes[bit_i // 8]
            dut.ui_in.value = ((rx_byte >> (7 - (bit_i % 8))) & 1) << 4
        else:
            dut.ui_in.value = 0
        await step(dut)
        cs = (uo(dut) >> 1) & 1
        sck = (uo(dut) >> 2) & 1
        mosi = uo(dut) & 1
        if prev_sck == 0 and sck == 1 and cs == 0 and bit_i < 16:
            captured.append(mosi)
            bit_i += 1
        prev_sck = sck
        if bit_i == 16 and busy_of(dut) == 1 and sck == 1:
            # The last sample leaves SCK high, and an empty TX FIFO holds it.
            break
    assert bit_i == 16, f"saw {bit_i} rising edges"
    assert busy_of(dut) == 1
    assert (uo(dut) & 0x02) == 0, "CS stays low across both bytes"
    sent = []
    for n in range(2):
        value = 0
        for bit in captured[n * 8:(n + 1) * 8]:
            value = ((value << 1) | bit) & 0xFF
        sent.append(value)
    assert sent == [0xA5, 0x3C]
    assert await pop_rx(dut) == 0x96
    assert await pop_rx(dut) == 0x0F


def uo_nibble(dut):
    return uo(dut) & 0xF


@cocotb.test()
async def test_qspi_nibbles(dut):
    """Four data pins move with the clock. uo[3:0] is the nibble, uo[4] is SCK."""
    await boot(dut)
    await load_cfg(dut, roles=(0, 0, 0, 0), side=0x4C, dirs=0x80)
    await load_bytes(dut, 0x4C, [0x48])  # width 4, base pin 8
    await load_words(dut, QSPI_OUT)
    await pulse(dut, CMD_PAYLOAD, 0xA5)
    await pulse(dut, CMD_PC, 0)
    await pulse(dut, CMD_RUN, 0)

    await step(dut)
    assert uo_nibble(dut) == 0xA
    assert ((uo(dut) >> 4) & 1) == 0
    await step(dut)
    assert uo_nibble(dut) == 0x5
    assert ((uo(dut) >> 4) & 1) == 1
    await step(dut)
    assert busy_of(dut) == 0


@cocotb.test()
async def test_qspi_in_and_autopull(dut):
    await boot(dut)
    await load_cfg(dut, roles=(0, 0, 0, 0), dirs=0x40)
    await load_bytes(dut, 0x4C, [0x44])  # width 4, base ui[4]
    await load_words(dut, QSPI_IN)
    await pulse(dut, CMD_PC, 0)
    await pulse(dut, CMD_RUN, 0)

    dut.ui_in.value = 0xA0
    await step(dut)
    dut.ui_in.value = 0x50
    await step(dut)
    await step(dut)
    assert busy_of(dut) == 0
    assert await read_shift(dut) == 0xA5

    await load_cfg(dut, roles=(0, 0, 0, 0), dirs=0xA4)  # MSB, autopull, xreload 4
    await load_bytes(dut, 0x4C, [0x48])
    await load_words(dut, QSPI_GROUPS)
    await pulse(dut, CMD_PAYLOAD, 0xA5)
    await pulse(dut, CMD_PUSH, 0x3C)
    await pulse(dut, CMD_PC, 0)
    await pulse(dut, CMD_RUN, 0)
    await step(dut)  # HOLD reloads x
    got = []
    for _ in range(4):
        await step(dut)
        got.append(uo_nibble(dut))
    await step(dut)
    assert got == [0xA, 0x5, 0x3, 0xC]
    assert busy_of(dut) == 0


@cocotb.test()
async def test_dual_shift(dut):
    await boot(dut)
    await load_cfg(dut, roles=(0, 0, 0, 0), dirs=0x84)  # MSB, xreload 4
    await load_bytes(dut, 0x4C, [0x28])  # width 2, base pin 8
    await load_words(dut, QSPI_GROUPS)
    await pulse(dut, CMD_PAYLOAD, 0xA5)
    await pulse(dut, CMD_PC, 0)
    await pulse(dut, CMD_RUN, 0)
    await step(dut)
    got = []
    for _ in range(4):
        await step(dut)
        got.append(uo(dut) & 0x3)
    assert got == [0b10, 0b10, 0b01, 0b01]


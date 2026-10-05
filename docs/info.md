## Problem

A chip built this way is a loop with no operating system. One clock tick is one iteration. The only values other chips can see are the pins, each a single bit on a wire. There is no function call and no shared memory across that wire. A byte is sent by changing pins at counted ticks.

The Verilog is printed into the silicon. After that print it cannot be edited. The bytes in instruction memory can. So a protocol has to be a program those bytes encode: instructions that read a pin, write a pin, and wait a number of clocks. UART, SPI, and I2C are three programs. A protocol that is not in this list has to be a later program, using the pins and the clock the silicon already has.

These three are already on the boards a software engineer debugs. The text console is UART. The flash chip or the display is often SPI. The temperature sensor is often I2C. This chip has to be able to play the other end of each conversation.

The deadline is 18 January 2027. The circuit size, the one clock, and the pin list are fixed. Bounds, below, is each of those as a rule.

### Why this problem

A UART chip, an SPI chip, and an I2C chip already exist and cost less than this shuttle. Wiring three of them down answers the three named protocols and nothing else. The board you meet next has a variant: a baud rate that is not standard, an SPI mode the peripheral chip does not implement, a single-wire protocol that showed up in a datasheet after the board was built. The silicon is already printed by then. The program is the only part you can still change, which is why a new protocol has to be another program and not a new block of Verilog.

A program on a laptop does not hit the bit times either. `write()` on a serial device goes through USB and a scheduler. The gaps are milliseconds, or tens of microseconds when the process is lucky. One bit at 115200 baud is about 8.7 microseconds, and an I2C clock at 400 kHz is 2.5 microseconds high or low. The loop that changes the pins has to be the only thing running, beside the pins, counting the chip's own clock. That is the same reason the RP2040 has PIO state machines: a small program whose instructions are pin reads, pin writes, and waits, instead of a core that also runs an operating system.

The area bound is what keeps the machine that small. About 24k logic cells does not fit a general processor. It fits a program counter, a wait counter, and the pins. The instruction set is the design. Getting UART, SPI, and I2C out of one such set shows the set is big enough for the protocols people already bit-bang, and for the next protocol written as more of those instructions.

### What to build

Two pieces, both in the submission. The machine is Verilog, printed into the chip. The protocols are programs loaded into that machine afterward.

The machine is an interpreter that runs beside the pins. It needs:

- Instruction memory the host can write, through the fixed pins, before a program runs. The host is the test, or later a controller on the board.
- A program counter, and a way to wait a counted number of ticks of the one 50 MHz clock.
- Instructions that write a pin to 0 or 1, release a pin, read a pin, and branch or keep waiting based on the bit just read.
- Enough pins for the wires below at the same time. UART needs a transmit wire and a receive wire. SPI needs a clock, two data wires, and a chip-select. I2C needs two wires that can be released. Those wires come out of `ui`, `uo`, and `uio`. No port can be added.

The programs, written in that instruction set:

- **UART.** Send an 8N1 frame on the transmit wire, and assemble a byte from the receive wire by sampling in the middle of each bit. The baud rate is a count of ticks, loaded with the program.
- **SPI.** Act as the master. Drive the clock, shift a byte out, and shift a byte in on the chosen edge. Chip-select frames the transfer.
- **I2C.** Act as the master. Produce start, eight data bits, the acknowledgement bit, and stop. Release the data wire for the acknowledgement and read it back. If the other chip holds the clock low, wait until it rises.

A fourth program, for a protocol with no block in the Verilog, has to be loadable the same way. Low-speed USB and 10 Mbit Ethernet are optional later programs, not part of this requirement.

The submission is open-source Verilog that place-and-route can lay out inside the bounds and that meets the 20 ns tick. Tests drive the pins and check the traces: a UART byte on the wire, an SPI transfer, an I2C exchange that includes an acknowledgement and a stretched clock. The deadline is the date above.

### UART

UART (universal asynchronous receiver-transmitter) is the serial port. It began as the chip that let a computer talk to a teletype, and later to a modem, on an RS-232 connector. The bit pattern survived. On a board today the same frame is a 3.3 V or 5 V logic level, and a USB-serial chip turns it into the COM port or `/dev/ttyUSB0` opened from a serial monitor. `Serial.print` on a microcontroller, the kernel log on an embedded Linux board, and the NMEA sentences from a GPS module are this protocol. Two devices, no addresses.

One direction is one wire. This side's transmit pin is wired to the other side's receive pin, and the other pair runs the opposite way, plus a shared ground. Both ends are configured with the same bit rate, the baud rate, such as 9600 or 115200 bits per second. If the rates differ, the other end assembles the wrong byte and you see garbage characters. There is no second wire carrying a clock. Each end times the bits with its own clock, from the moment the line leaves idle.

Idle is 1, the same rest state as a serial-port line between bytes. A frame uses the format 8N1:

| Piece | Bits | Level | What the other end does with it |
| --- | --- | --- | --- |
| Start | 1 | 0 | The fall from 1 to 0 starts its timer |
| Data | 8 | the byte, bit 0 first | It samples once in the middle of each bit |
| Parity | 0 | | **N** means this bit is absent |
| Stop | 1 | 1 | It checks the line is back at idle |

Bit 0 first means the opposite of writing a hex constant. In `0xA5` (`0b10100101`) the leftmost bit is bit 7, and it goes on the wire last.

Sending `0xA5` is this sequence. Each column is one bit-time:

```text
idle  start  b0  b1  b2  b3  b4  b5  b6  b7  stop  idle
  1     0     1   0   1   0   0   1   0   1    1     1
```

Receiving is the same frame on an input pin. The receiver waits for the falling edge, waits one and a half bit-times so it is in the middle of bit 0, then samples once per bit-time. The two clocks drift. They only have to stay aligned for these ten bit-times. A couple of percent of error still samples inside the bit.

On a 50 MHz clock the bit-time is an integer number of ticks. `period` is that integer. The baud rate is `clock_hz / period`.

| Baud | `period` | Rate this period actually produces |
| --- | --- | --- |
| 9600 | 5208 | 50e6 / 5208 ≈ 9601 |
| 115200 | 434 | 50e6 / 434 ≈ 115207 |

### SPI

SPI (serial peripheral interface) came from Motorola, around 1979, so a microcontroller could talk to other chips on the same board without an 8-bit parallel bus. One side, the master, generates the clock. Flash that holds firmware, an SD card used in SPI mode, a small OLED display, and an analog-to-digital converter are typical devices. The SPI pins on a Raspberry Pi header are the same four signals. The wires stay short, on the board. Several devices can share the clock and the two data wires. Each device has its own chip-select, and it listens only while that wire is 0.

The usual wires are:

| Wire | Direction | Meaning |
| --- | --- | --- |
| SCK | master → device | One edge of this clock moves one bit |
| MOSI | master → device | The bit the master is sending |
| MISO | device → master | The bit the device is sending |
| CS | master → device | 0 means this device pays attention |

On each clock edge a bit goes out on MOSI and a bit comes in on MISO, in the same moment. That is full duplex. A transfer that only needs one direction still clocks the other direction, and that side is discarded. The usual devices send the most-significant bit first, and sample the data line on the rising edge while the clock idles at 0. Clock idle level and which edge samples are the SPI mode. The mode is part of the program, because two chips disagreeing on it read every bit shifted by one. There is no start bit and no agreed baud rate. The edge is the synchronization. The master can run the clock as fast as both chips and the wires allow.

```c
cs = 0;
for (int i = 7; i >= 0; i--) {
    mosi = (byte >> i) & 1;
    sck = 1;          // the device reads mosi here, in the usual mode
    incoming = (incoming << 1) | miso;
    sck = 0;
}
cs = 1;
```

Each assignment stays on its pin for a counted number of ticks of the one chip clock.

### I2C

I2C (inter-integrated circuit) came from Philips in 1982. Microcontroller chips were running out of pins, and a sensor, an EEPROM, and a clock chip each wanted their own wires. I2C puts every one of them on the same two wires, and gives each an address. A temperature sensor, an accelerometer, the small EEPROM soldered on a board, a real-time clock, and the battery gauge in a laptop are typical. The monitor name and resolution a computer reads over HDMI travel as I2C. On Linux those devices show up under `i2cdetect`, at addresses such as `0x48` or `0x68`.

SDA is data. SCL is the clock. Both are shared by every chip on the bus. A wire is never driven to 1. A chip either pulls it to 0 or lets go. A resistor on the board pulls a released wire up to 1. Any chip can force 0. The rise through that resistor is slow, so the usual clocks are 100 kHz and 400 kHz, far below SPI.

```c
sda = !(me_pull_low || them_pull_low);
```

The value a program reads is `sda` after that expression. It can differ from the bit the program tried to send.

Idle is both wires released, so both read 1. A start is SDA falling while SCL stays 1. A stop is SDA rising while SCL stays 1. A byte is eight bits, most-significant bit first, then a ninth bit for the acknowledgement. The sender releases SDA for that ninth bit. The receiver pulls SDA to 0 to say the byte arrived. If the receiver is not ready, it holds SCL at 0, and the sender waits until SCL reads 1. That wait is clock stretching.

A 7-bit device address, followed by a read/write bit, is the first byte on the wire. The wires do not mark it as an address. The program does.

## Bounds

These numbers are fixed by the shuttle. A program that misses one of them does not fit the chip.

| Limit | Value |
| --- | --- |
| Process | IHP 130 nm CMOS5L, through Tiny Tapeout |
| Area | 6×4 tiles, about 0.7 mm², about 24k logic cells. Stay at 6×4 unless the cap becomes 8×4 |
| Clock | 50 MHz. One tick is 20 ns. The layout build checks that a tick is enough |
| Pins | `ui[7:0]` inputs, `uo[7:0]` outputs, `uio[7:0]` bidirectional, plus `clk`, `rst_n`, `ena` |

The process is the factory's transistor library. Verilog is mapped onto that library. A tile is Tiny Tapeout's unit of silicon area. A logic cell is one small gate or one flip-flop. About 1k cells fit in a tile, so 24 tiles are about 24k cells. That number is the size of the circuit. It is not a heap.

**State.** Every register spends cells. A large instruction memory built from flip-flops spends the budget quickly. The alternative on this process is the SRAM block: present an address on one tick, read the byte on a later tick. The address computed on a tick is not the byte on that same tick.

**Step.** One rising edge updates every register from the values on the previous edge. The logic of that update has to settle inside 20 ns once the gates are placed and wired. That placement is the place-and-route build. A step can be boolean-correct and still fail the build when the update is a deep chain of gates. A wait is a counter that decrements across ticks. The shortest pulse on a pin is one tick, 20 ns.

**Pins.** The top module's ports are the whole interface. A protocol wire has to be one of them.

- `ui[7:0]` is sampled at the edge.
- `uo[7:0]` is driven by the chip.
- Each `uio[i]` has an output value, an output enable, and an input sample.

`clk` is the tick. It is not a value the program reads. `rst_n = 0` at an edge returns every register to one known initial state, and a test is a finite list of writes and pin samples starting from that state. `ena` is 1 while this design is the one being run.

**A shared wire.** An I2C pin pulls to 0 or releases. Releasing is the output enable turned off, not a write of 1. The bit the program reads is the wire after every chip on it has pulled or released. The boolean model treats a released wire as 1 on the next tick when no chip is pulling. How strongly the resistor pulls, and how long the voltage takes to rise, sit outside that model. A test supplies the other chip's pull as an input.

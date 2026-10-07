# How the RP2040 PIO does this

The RP2040 is the chip on the Raspberry Pi Pico. Beside its two ARM cores it has PIO, programmable I/O. PIO is the machine the competition points at. It bit-bangs UART, SPI, and I2C from programs. The cores know which program is loaded. The state machine does not.

The programs below are the ones in Raspberry Pi's [pico-examples](https://github.com/raspberrypi/pico-examples) (`uart_tx.pio`, `uart_rx.pio`, `spi.pio`, `i2c.pio`), BSD-3-Clause.

## Input and output

There are two PIO blocks. Each block has four state machines, so eight programs can be in flight. The four machines in one block share one memory of 32 instructions. Each instruction is 16 bits. Each machine has its own program counter, so they can sit in different parts of those 32 words.

A state machine's inputs and outputs:

| In | Out |
| --- | --- |
| Words the ARM core pushes into a TX FIFO | Words the ARM core pops from an RX FIFO |
| The GPIO pins it is configured to read | The GPIO pins it is configured to drive |

The core is the host. It writes the 32 instructions, maps them onto GPIO numbers, sets the clock divider, and enables the machine. Then it pushes the bytes to send and pops the bytes received. The FIFO is the data path. The instruction memory is the protocol.

One machine executes one instruction per its own clock. That clock is the system clock divided by a programmed ratio. At 125 MHz and a divider of 1, the machine takes one step every 8 ns. A delay field on an instruction stalls extra clocks, up to 31, without spending another instruction slot.

## Who knows the program

The person who wrote the assembly, and the ARM core that copies it in. `uart_tx` and `spi_cpha0` are different instruction lists placed at different addresses. The state machine fetches `mem[pc]` and does that operation. Nothing in the fetch says "this is UART."

The other chip sees only the pins. Mapping which GPIO is TX, which is SCK, and which is MOSI is configuration written by the core before start, not something the program discovers.

## What one instruction can do

Nine operations. Each can also side-set and delay.

| Instruction | Effect |
| --- | --- |
| `JMP` | Branch. The condition can be a scratch counter, a pin, or "output shift register empty" |
| `WAIT` | Stall until a pin is 0 or 1 |
| `IN` | Shift pin levels into the input shift register |
| `OUT` | Shift bits from the output shift register onto pins |
| `PUSH` | Copy the input shift register into the RX FIFO, toward the core |
| `PULL` | Copy a TX FIFO word into the output shift register. Stalls if the FIFO is empty |
| `MOV` | Copy between the scratch registers, the shift registers, and the pins |
| `IRQ` | Raise or wait on a flag the core can see |
| `SET` | Write a small immediate to pins or to a scratch register |

Side-set writes more pins at the start of that same instruction. SPI uses it for the clock, so the clock edge and the data bit are one instruction. The number in square brackets is the delay. `out pins, 1 [7]` shifts one bit, then holds for 7 extra clocks.

Each machine also has two scratch registers, X and Y, used as loop counters.

## UART transmit

This is the whole transmitter. OUT and side-set are both wired to the TX pin. Side-set forces the start and stop levels. OUT shifts the data byte, least-significant bit first, because the shift direction is configured to the right.

```text
pull       side 1 [7]   ; stop bit, or idle high while the FIFO is empty
set x, 7   side 0 [7]   ; start bit, and X counts seven more data bits
bitloop:
out pins, 1             ; next data bit
jmp x-- bitloop   [6]   ; 1 + 6 clocks, plus the OUT, is 8 clocks per bit
```

`pull` stalls when the core has not pushed a byte. The side-set still applies during the stall, so TX stays 1, which is idle. Each bit is 8 machine clocks. The core sets

```text
divider = system_clock / (8 * baud)
```

so those 8 clocks are one bit-time. Pushing `0xA5` into the TX FIFO is the input. The output is the same frame as in `docs/info.md`: start 0, then bit 0 first, then stop 1.

## UART receive

A second program, usually a second state machine, on the RX pin.

```text
wait 0 pin 0       ; stall until the line falls, the start bit
set x, 7    [10]   ; land in the middle of bit 0
bitloop:
in pins, 1         ; sample one bit into the shift register
jmp x-- bitloop [6]
push               ; the assembled byte goes to the RX FIFO
```

`wait` plus `set` and its delay are 12 clocks from the falling edge. A bit is 8 clocks, so 12 clocks is the middle of the first data bit. Each later sample is 8 clocks after the previous one. The core pops the byte from the RX FIFO. The fuller program in the same file also checks the stop bit and does not push a byte whose framing is wrong.

## SPI

Clock phase 0, the usual mode, is two instructions. Side-set is SCK. OUT is MOSI. IN is MISO. The shift direction is configured left, so bit 7 goes first. Autopull and autopush move FIFO words when the shift register has moved a whole byte, so the program has no `pull` or `push` of its own.

```text
out pins, 1 side 0 [1]   ; data bit, clock low
in pins, 1  side 1 [1]   ; sample MISO, clock high
```

The program counter wraps from the second instruction back to the first. The input is a word pushed by the core, and the level on MISO at each rising clock. The output is SCK, MOSI, and a word in the RX FIFO containing what was sampled. Chip-select is a third pin, either driven by the core or by a longer program whose side-set is two bits wide.

## I2C

I2C is the same machine using pin direction as the open-drain bit. The pad is wired so that "output" drives 0 and "input" releases the wire. A pull-up makes a released wire read as 1. The data bit shifted out is that direction: a 1 releases SDA, a 0 pulls SDA low.

Side-set is SCL, also as a direction. `side 1` releases the clock. `side 0` pulls it low. The byte loop is:

```text
set x, 7
bitloop:
out pindirs, 1         [7]   ; next SDA bit, as release or pull-low
nop             side 1 [2]   ; release SCL
wait 1 pin 1           [4]   ; stay here while the other chip holds SCL low
in pins, 1             [7]   ; sample SDA in the middle of the high clock
jmp x-- bitloop side 0 [7]   ; pull SCL low again
```

`wait 1 pin 1` is clock stretching. The acknowledgement is the same clock pulse with SDA released, then `jmp pin` on SDA. If SDA reads 1, nobody pulled it down, and that is a NAK.

Start and stop are not separate opcodes. The core pushes raw instructions through the FIFO, and `out exec, 16` makes the state machine execute them. Those instructions are `set` of SDA and SCL directions: SDA falling while SCL is released is a start, SDA rising while SCL is released is a stop. The core knows the transfer. The state machine knows the current instruction.

## What is different from the chip in this repository

`src/pin_engine.v` is the same idea with the fields this chip can afford: `WAIT`, `IN`, a side pin, and open-drain pull or release, plus the `T` / `Tlo` / `Thi` holds that stand in for PIO's delay field. UART receive, SPI, and I2C are programs in `prog/`.

PIO can do all three because the instruction set can read a pin, write an extra pin on the same instruction, and branch. The ARM cores are outside that instruction set. They own the FIFOs and they choose which of the 32 slots to start. On the ASIC there is no second processor on the die. The host writes the program through the pins, and the instruction set is the whole chip.

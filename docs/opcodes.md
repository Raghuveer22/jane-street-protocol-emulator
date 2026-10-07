# Commands and opcodes

The host loads a program with six commands. The program is 16-bit words. The opcode is the high nibble of each word. The full encoding, the load map, and the four example programs are in `docs/instruction_definition.html`.

Writes only take while `running` is 0. The strobe is `ui[0]` for one tick. The command is `ui[3:1]`. The data byte is `uio[7:0]`.

## Commands

```text
CMD_ADDR    0   set the load address
CMD_WRITE   1   store one byte there, then address + 1
CMD_PAYLOAD 2   output shift register (the byte to send)
CMD_PC      3   first instruction of this run
CMD_RUN     4   running = 1, data ignored
CMD_READ    5   stopped: input shift on uio. running: FIFO status on uio
CMD_PUSH    6   enqueue one byte in the TX FIFO. legal while running
CMD_POP     7   dequeue one byte from the RX FIFO onto uio. legal while running
```

`CMD_ADDR`, `CMD_WRITE`, `CMD_PAYLOAD`, `CMD_PC`, and `CMD_RUN` are ignored while `running` is 1. `CMD_PUSH` and `CMD_POP` are not. A push during a hold does not skip a tick of that hold. `CMD_READ` and `CMD_POP` drive `uio` as an output for that tick, so a program that is using `uio` as a wire (I2C) cannot take them mid-transfer. The instruction at `pc` runs on the tick after `CMD_RUN`.

`CMD_ADDR` / `CMD_WRITE` walk a flat byte space:

| Address | Field |
| --- | --- |
| `0x00`–`0x3F` | `imem`, 32 words, low byte then high byte |
| `0x40`, `0x41` | `T`, UART bit time |
| `0x42`, `0x43` | `Tlo` |
| `0x44`, `0x45` | `Thi` |
| `0x46`–`0x49` | role 0–3 binding |
| `0x4A` | side-pin binding |
| `0x4B` | `out_dir`, `in_dir`, `autopull`, `autopush`, `xreload` |
| `0x4C` | shift width and the base pin. Absent means width 1 |

A protocol load is `CMD_ADDR 0x40` plus twelve writes, then `CMD_ADDR 0x00` plus two writes per word. A later frame of the same protocol is three ticks: `CMD_PAYLOAD`, `CMD_PC`, `CMD_RUN`. After a receive or a full-duplex transfer, `CMD_READ` returns the assembled byte.

Byte `0x4B` is `{out_dir, in_dir, autopull, autopush, xreload[3:0]}`. Both FIFO bits come up 0, which is the one-byte machine.

## TX and RX FIFOs

Four bytes each. `CMD_PUSH` enqueues. `CMD_POP` dequeues and drives that byte on `uio` for the strobe tick. Empty pop drives `0x00` and does not move the pointer. A push into a full TX FIFO is dropped and sticks `tx_overrun`. An autopush into a full RX FIFO is dropped and sticks `rx_overrun`. `CMD_READ` while running drives this status byte and clears both flags unless the same tick overflowed:

```text
7  tx_full
6  tx_empty
5  rx_full
4  rx_empty
3  stall_tx     autopull is holding the program, pins frozen
2  rx_overrun
1  tx_overrun
0  osr empty    the output shift has no byte loaded
```

Autopull (`0x4B` bit 5): the 8th `OP_SHIFT` or `OP_ODSHIFT` of a byte keeps that bit on the pin and, if the TX FIFO has a byte, loads it into the output shift on that same tick. The first byte is still `CMD_PAYLOAD`, or the oldest queued byte if `CMD_RUN` finds the shift empty. A looping program whose backward branch retires with no byte queued finishes that instruction (UART's stop bit, SPI's last sample) and then waits with the pins held. The wait is idle on a UART transmitter whose stop bit is the branch. It is a stretched last clock-high on the streaming SPI program, whose branch is the sample.

Autopush (`0x4B` bit 4): the 8th `OP_IN` copies the input shift into the RX FIFO. The shift register itself is left alone, so `CMD_READ` after halt still returns it. The copy is dropped if the FIFO is full. Sampling does not stall.

`prog/uart_8n1_stream.asm`, `prog/uart_rx_stream.asm`, and `prog/spi_mode0_stream.asm` are the looping forms. I2C is not one of them: the acknowledgement decides whether another byte exists, and SDA/SCL are `uio`, the same pins a push or pop would use.

## Opcodes

```text
OP_HALT    0x0  running = 0. Pins stay.
OP_WAIT    0x1  stall until role reads val
OP_SET     0x2  drive role to val, push-pull
OP_SHIFT   0x3  drive role to the next payload bit, push-pull
OP_IN      0x4  sample role into the input shift
OP_OD      0x5  pull or release role. val 0 pulls, val 1 releases
OP_ODSHIFT 0x6  payload bit 0 pulls role, bit 1 releases it
OP_HOLD    0x7  change no pin, only load the wait
```

`OP_SHIFT` and `OP_ODSHIFT` consume one, two, or four bits of the output shift. `OP_IN` shifts that many sampled bits in. Width 1, the reset value, drives or samples the role pin. Width 2 or 4 uses consecutive pins at the base in `0x4C`, and the low pin of the group is the low bit of that group. Bit order is `out_dir` / `in_dir`: 0 sends the low group first, 1 sends the high group first. A group has to sit inside one port. Pin 15 is `running`, so four bits cannot cross from `uo` into `uio`. `uo[6:0]` and `uio[7:0]` and `ui[7:0]` can each hold one.

Byte `0x4C` is `{0, width[1:0], base[4:0]}`. `width` 0 is one bit, 1 is two, 2 is four. A twelve-byte config load stops at `0x4B` and leaves this at one bit.

Autopull and autopush count bits. A quad shift empties the byte in two instructions.

`side` is allowed on `OP_SET`, `OP_SHIFT`, `OP_IN`, `OP_OD`, and `OP_ODSHIFT`. The data pin and the side pin update together, then the hold runs.

## Word fields

```text
15:12  op
11:10  role        0–3, bound in the load map
    9  val         SET level, WAIT level, OD pull/release
    8  side        1 writes the side pin this tick
    7  side_val    level, or pull/release if the side pin is open-drain
  6:4  hold        which wait to load after the pin update
    3  xdec        1: x -= 1; if x > 0 jump back `back` instructions
  2:1  back        0 = this instruction, 1 = previous, …
    0  setx        1 loads x with xreload
```

| `hold` | Name | Ticks |
| --- | --- | --- |
| 0 | `T` | UART bit time |
| 1 | `T/2` | midpoint of a UART bit. `T` must be even |
| 2 | `Tlo` | low half of a generated clock |
| 3 | `Thi` | high half. Fastest SPI is `Tlo = Thi = 1` |
| 4 | `1` | one tick |
| 5 | none | next instruction on the next tick |
| 6, 7 | | reserved |

Unused fields are 0.

## What they cover

Shift out (`OP_SHIFT`, `OP_ODSHIFT`), shift in (`OP_IN`), a second pin on the same tick (`side`), six hold lengths, a loop of `xreload` bits (`setx` / `xdec` / `back`), stall (`OP_WAIT`), pull/release (`OP_OD`), and halt with the pins held (`OP_HALT`).

No forward jump. No branch on the bit just sampled. Two pins per step, not three. One byte per shift register per run.

## SPI: as many slaves as the ASIC pins allow

This is an on-chip master. Every chip-select is a pin of **this** die. No off-chip CS demux is part of the design.

SCK, MOSI, and MISO are shared. Each slave needs its own CS, driven high when idle and low only for that transfer. Only one CS is low at a time.

| How CS is chosen | Limit |
| --- | --- |
| Named in the program | Role 1 is CS0. Role 3 is free for CS1. At most two selects the instruction word can name. |
| Driven on leftover ASIC outputs | Every unused `uo` / `uio` pin can be another CS. The host pulls exactly one low before `CMD_RUN` and raises it after halt. Still on this chip. |

`ui` cannot be a CS: those pins are inputs only. CS must sit on `uo` or `uio`.

The bit loop does not change with the slave count. Extra slaves are extra CS pins and host (or program) sequencing, not new opcodes. The ceiling is the Tiny Tapeout pin list: three shared wires plus as many CS lines as remain on `uo` and `uio` after SCK, MOSI, and MISO are placed.

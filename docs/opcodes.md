# Commands and opcodes

The host loads a program with eight commands. The program is 16-bit words. The opcode is the high nibble of each word. The full encoding, the load map, and the UART, SPI, and I2C listings are in `docs/instruction_definition.html`. Streaming, quad-shift, and low-speed USB programs in the same word format are in `prog/`.

Config and payload writes take while `running` is 0. Instruction-memory writes also take while `running` is 1, and those land in the idle bank. The strobe is `ui[0]` for one tick. The command is `ui[3:1]`. The data byte is `uio[7:0]`.

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

`CMD_PAYLOAD`, `CMD_PC`, and `CMD_RUN` are ignored while `running` is 1. `CMD_ADDR` and `CMD_WRITE` are not: they fill the bank the engine is not executing, and byte `0x4D` can arm a switch. Config bytes other than `0x4D` are ignored while running. `CMD_PUSH` and `CMD_POP` are accepted either way. A push during a hold does not skip a tick of that hold. `CMD_READ` and `CMD_POP` drive `uio` as an output for that tick, so a program that is using `uio` as a wire (I2C) cannot take them mid-transfer. The instruction at `pc` runs on the tick after `CMD_RUN`.

`CMD_ADDR` / `CMD_WRITE` walk a flat byte space:

| Address | Field |
| --- | --- |
| `0x00`–`0x3F` | One bank of `imem`, 32 words, low byte then high byte. Stopped: the bank the engine runs. Running: the other bank |
| `0x40`, `0x41` | `T`, UART bit time |
| `0x42`, `0x43` | `Tlo` |
| `0x44`, `0x45` | `Thi` |
| `0x46`–`0x49` | role 0–3 binding |
| `0x4A` | side-pin binding |
| `0x4B` | `out_dir`, `in_dir`, `autopull`, `autopush`, `xreload` |
| `0x4C` | shift width and the base pin. Absent means width 1 |
| `0x4D` | bit 0 arms a bank switch. Bits `[4:1]` are `yreload`. The switch is taken on `OP_HALT`, or when `pc` steps off word 31 without a backward branch: banks flip, `pc` is 0, `running` stays 1 |

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

Autopull (`0x4B` bit 5): the 8th `OP_SHIFT`, `OP_ODSHIFT`, or `OP_XOR` of a byte keeps that bit on the pin and, if the TX FIFO has a byte, loads it into the output shift on that same tick. On `OP_XOR`, an empty FIFO clears `osr_valid` and does not stall. The first byte is still `CMD_PAYLOAD`, or the oldest queued byte if `CMD_RUN` finds the shift empty. A looping program whose backward branch retires with no byte queued finishes that instruction (UART's stop bit, SPI's last sample) and then waits with the pins held. The wait is idle on a UART transmitter whose stop bit is the branch. It is a stretched last clock-high on the streaming SPI program, whose branch is the sample.

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
OP_MATCH   0x8  continue only if the role reads val. Otherwise stop
OP_JMP     0x9  branch on a condition. No pin write
OP_XOR     0xA  width-1 differential bit. side is the complement
```

Bit 9 of `OP_ODSHIFT` is the match flag. Existing programs leave it 0. When it is 1 and the role is open-drain, the bit just driven is compared with the wire on that same tick. A driven 0 is dominant and always matches. A driven 1 loses when the wire reads 0: the role is released and `running` clears, so the rest of the frame is not sent. `OP_MATCH` is the same halt for a level the instruction names. A match records the sample and continues. A mismatch releases an open-drain role and stops. That is an I2C NACK check, or any other single-bit expect.

`OP_JMP` takes bits `[9:7]` as the condition. True and `back != 0` goes to `pc - back`. True and `back == 0` skips the next word (`pc + 2`). False advances one. The conditions are 0 always, 1 `Y != 0`, 2 `Y == 0`, and 3 more payload (the output shift still holds a bit, or the TX FIFO is not empty). UART streams keep using `xdec` and the TX stall; they never take condition 3, so an empty FIFO still holds the line.

`OP_XOR` is width 1. `val` 0 drives `level XOR ~bit` (a 0 toggles, a 1 holds) and consumes the bit, including autopull. `val` 1 toggles without taking a bit. `side` drives the other pin to the complement; `side_val` is unused. On this opcode `xdec` and `setx` touch `Y`, not `X`: a payload 1 decrements `Y` and stops at 0, a payload 0 reloads `yreload`, and `setx` loads `Y` from `yreload`. `CMD_RUN` loads `Y` from `yreload`. An empty TX FIFO after the last bit clears `osr_valid` and does not stall, so `JMP cond=more` can fall through to a trailer.

`OP_SHIFT` and `OP_ODSHIFT` consume one, two, four, or eight bits of the output shift. `OP_IN` shifts that many sampled bits in. Width 1, the reset value, drives or samples the role pin. Width 2, 4, or 8 uses consecutive pins at the base in `0x4C`, and the low pin of the group is the low bit of that group. Bit order is `out_dir` / `in_dir`: 0 sends the low group first, 1 sends the high group first. Width 8 sends the whole byte, so `out_dir` 1 reverses it onto the pins. A group has to sit inside one port. Pin 15 is `running`, so eight bits fit on `uio[7:0]` or `ui[7:0]`, not on `uo`.

Byte `0x4C` is `{0, width[1:0], base[4:0]}`. `width` 0 is one bit, 1 is two, 2 is four, 3 is eight. A twelve-byte config load stops at `0x4B` and leaves this at one bit.

Autopull and autopush count bits. A quad shift empties the byte in two instructions. An 8-bit shift empties it in one.

`side` is allowed on `OP_SET`, `OP_SHIFT`, `OP_IN`, `OP_OD`, and `OP_ODSHIFT`. The data pin and the side pin update together, then the hold runs.

## Word fields

```text
15:12  op
11:10  role        0–3, bound in the load map
    9  val         SET level, WAIT level, OD pull/release.
               ODSHIFT: 1 enables the bus-match halt. MATCH: expected level.
               XOR: 0 consumes a payload bit, 1 toggles only.
               JMP: high bit of the condition
    8  side        1 writes the side pin this tick. JMP: middle condition bit
    7  side_val    level, or pull/release if the side pin is open-drain.
               JMP: low condition bit. XOR with side: unused (complement)
  6:4  hold        which wait to load after the pin update
    3  xdec        1: x -= 1; if x > 0 jump back `back` instructions.
               On XOR: count ones into Y instead
  2:1  back        0 = this instruction, 1 = previous, …
               JMP: 0 means skip the next word when the condition is true
    0  setx        1 loads x with xreload. On XOR: loads Y with yreload
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

Shift out (`OP_SHIFT`, `OP_ODSHIFT`, `OP_XOR`), shift in (`OP_IN`), a second pin on the same tick (`side`), six hold lengths, a loop of `xreload` bits (`setx` / `xdec` / `back`), a second counter `Y` with `yreload`, a conditional branch (`OP_JMP`), stall (`OP_WAIT`), pull/release (`OP_OD`), and halt with the pins held (`OP_HALT`).

`OP_JMP` can skip one word or jump backward. A sampled bit still does not choose an address: `OP_MATCH` and `OP_ODSHIFT` with bit 9 set only halt when the wire disagrees. Two pins per step, not three.

`prog/usb_ls_tx.asm` is the low-speed USB transmitter written with `OP_XOR` and `OP_JMP`. Sync, PID, and CRC stay on the host. `yreload = 6` is the USB stuff length; a test with `yreload = 3` inserts sooner, so the silicon has no constant 6.

## SPI: as many slaves as the ASIC pins allow

This is an on-chip master. Every chip-select is a pin of **this** die. No off-chip CS demux is part of the design.

SCK, MOSI, and MISO are shared. Each slave needs its own CS, driven high when idle and low only for that transfer. Only one CS is low at a time.

| How CS is chosen | Limit |
| --- | --- |
| Named in the program | Role 1 is CS0. Role 3 is free for CS1. At most two selects the instruction word can name. |
| Driven on leftover ASIC outputs | Every unused `uo` / `uio` pin can be another CS. The host pulls exactly one low before `CMD_RUN` and raises it after halt. Still on this chip. |

`ui` cannot be a CS: those pins are inputs only. CS must sit on `uo` or `uio`.

The bit loop does not change with the slave count. Extra slaves are extra CS pins and host (or program) sequencing, not new opcodes. The ceiling is the Tiny Tapeout pin list: three shared wires plus as many CS lines as remain on `uo` and `uio` after SCK, MOSI, and MISO are placed.

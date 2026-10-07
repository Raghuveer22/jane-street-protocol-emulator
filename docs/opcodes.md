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
CMD_READ    5   present the input shift on uio for one tick
CMD_BUF     6   present rx_buf[ui[7:4]] on uio for one tick
```

7 is unused. `CMD_READ` and `CMD_BUF` are only legal while stopped. Each drives `uio` as an output for that tick. The byte index for `CMD_BUF` is `ui[7:4]`, because `uio` cannot be the index and the result on the same tick. The instruction at `pc` runs on the tick after `CMD_RUN`.

`CMD_ADDR` / `CMD_WRITE` walk a flat byte space:

| Address | Field |
| --- | --- |
| `0x00`–`0x3F` | `imem`, 32 words, low byte then high byte |
| `0x40`, `0x41` | `T`, UART bit time |
| `0x42`, `0x43` | `Tlo` |
| `0x44`, `0x45` | `Thi` |
| `0x46`–`0x49` | role 0–3 binding |
| `0x4A` | side-pin binding |
| `0x4B` | `out_dir`, `in_dir`, `xreload` |
| `0x4C` | `pkt_len`, 1 to 16. Longer values clamp to 16 |
| `0x50`–`0x5F` | USB transmit bytes. The host writes sync, PID, data, and CRC |

A protocol load is `CMD_ADDR 0x40` plus twelve writes, then `CMD_ADDR 0x00` plus two writes per word. A later frame of the same protocol is three ticks: `CMD_PAYLOAD`, `CMD_PC`, `CMD_RUN`. After a receive or a full-duplex transfer, `CMD_READ` returns the assembled byte.

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
OP_USB_OUT 0x8  NRZI bit from the packet buffer onto D+ and not-D+
OP_USB_IN  0x9  sample NRZI from D+, drop a stuff bit, stop on SE0
```

`OP_USB_OUT` and `OP_USB_IN` drive or sample D+ on the role pin and D− on the side pin. D− is the complement of D+ during a bit, and `side_val` is ignored. A 0 toggles the pair. A 1 keeps it. After six 1s the engine inserts, or drops, one extra 0 and does not take it from the buffer. `OP_USB_OUT` falls through when `pkt_len` bytes have been sent. `OP_USB_IN` falls through when both pins read 0, and that sample is not stored. `CMD_RUN` clears the NRZI state, so a transmit program sets idle J (D+ low, D− high) before the first `OP_USB_OUT`.

`OP_SHIFT` and `OP_ODSHIFT` consume one bit of the output shift. `OP_IN` shifts one sampled bit in. Bit order is `out_dir` / `in_dir` from the load map: 0 is bit 0 first, 1 is bit 7 first.

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

No forward jump. No branch on the bit just sampled. Two pins per step, not three. One byte per shift register per run. A USB packet is the exception: up to 16 bytes stay in the packet buffer so the bit times are not broken by a halt.

## SPI: as many slaves as the ASIC pins allow

This is an on-chip master. Every chip-select is a pin of **this** die. No off-chip CS demux is part of the design.

SCK, MOSI, and MISO are shared. Each slave needs its own CS, driven high when idle and low only for that transfer. Only one CS is low at a time.

| How CS is chosen | Limit |
| --- | --- |
| Named in the program | Role 1 is CS0. Role 3 is free for CS1. At most two selects the instruction word can name. |
| Driven on leftover ASIC outputs | Every unused `uo` / `uio` pin can be another CS. The host pulls exactly one low before `CMD_RUN` and raises it after halt. Still on this chip. |

`ui` cannot be a CS: those pins are inputs only. CS must sit on `uo` or `uio`.

The bit loop does not change with the slave count. Extra slaves are extra CS pins and host (or program) sequencing, not new opcodes. The ceiling is the Tiny Tapeout pin list: three shared wires plus as many CS lines as remain on `uo` and `uio` after SCK, MOSI, and MISO are placed.

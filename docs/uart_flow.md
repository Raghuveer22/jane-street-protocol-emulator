# UART, one byte, on the pin engine

This is the path one byte takes from a host write to the TX pin. The machine is `src/pin_engine.v`. The wrapper is `src/project.v`. What an 8N1 frame is, and why the baud rate is `clock_hz / T`, is `docs/info.md`. The register list is `docs/pin_engine.md`. The instruction word is `docs/instruction_definition.html`.

The worked example is byte `0xA5`, `T = 4`. Four clocks is not a serial-port baud rate. On the 50 MHz clock, 9600 baud is `T = 5208` and 115200 baud is `T = 434`. The steps are the same at those periods. Only the hold is longer.

UART here is not a peripheral. Nothing in the Verilog knows the words start, data, or stop. Those are four words in `imem`. The same words send any payload. The host writes a new output shift and runs from `pc = 0`.

## The frame the pin has to show

Idle is 1. A frame is a start bit of 0, eight data bits with bit 0 first, and a stop bit of 1. `0xA5` is `0b10100101`, so bit 0 is the rightmost 1.

```text
idle  start  b0  b1  b2  b3  b4  b5  b6  b7  stop  idle
  1     0     1   0   1   0   0   1   0   1    1     1
```

Each of those ten columns lasts `T` clocks. After the stop bit the pin is already 1.

## Where the pins go

| Pin | Role |
| --- | --- |
| `ui[0]` | Write strobe, one clock |
| `ui[3:1]` | Command |
| `uio[7:0]` | Write data, while stopped |
| `uo[0]` | TX, once role 0 is bound to pin 8 |
| `uo[7]` | `running` |

A host write is accepted only while `running` is 0.

## The program

`prog/uart_8n1.asm` is four words. Role 0 is TX. `xreload` is 8. Bit 0 goes first.

| `pc` | Word | Instruction | Bit it produces |
| --- | --- | --- | --- |
| 0 | `0x2001` | `SET` 0, hold `T`, `setx` | start. `x = 8` |
| 1 | `0x3008` | `SHIFT`, hold `T`, `xdec`, `back` 0 | one data bit, then this word again while `x > 0` |
| 2 | `0x2200` | `SET` 1, hold `T` | stop |
| 3 | `0x0000` | `HALT` | TX stays 1 |

`SHIFT` drives TX from bit 0 of the output shift, then shifts that register right by one.

## Load, then run

Commands are `ui[3:1]`. The data byte is `uio`. The binding and `T` are bytes at `0x40` and up, written with `CMD_ADDR` then `CMD_WRITE`. One later byte is three ticks: `CMD_PAYLOAD`, `CMD_PC` 0, `CMD_RUN`.

`CMD_RUN` does not execute `imem[0]`. That instruction runs on the next rising clock. From then until `HALT`, a host write is dropped.

On the clock a `SET` or `SHIFT` runs, `wait_left` is loaded with `T - 1`. A stored `T` of 0 holds for 1 clock. One execute clock plus `T - 1` countdown clocks is `T` clocks at the new level.

## The forty clocks of `0xA5`

Clock 0 is the first clock after `CMD_RUN`. `shift` is shown after the right shift. `SET` does not change it. The eight data rows are all word 1; `x` counts down from 8 to 0.

| Clocks | Instruction | `tx` | `shift` after |
| --- | --- | --- | --- |
| 0–3 | `SET` 0, `x = 8` | 0 start | `0xA5` |
| 4–7 | `SHIFT`, `x = 7` | 1 b0 | `0x52` |
| 8–11 | `SHIFT`, `x = 6` | 0 b1 | `0x29` |
| 12–15 | `SHIFT`, `x = 5` | 1 b2 | `0x14` |
| 16–19 | `SHIFT`, `x = 4` | 0 b3 | `0x0A` |
| 20–23 | `SHIFT`, `x = 3` | 0 b4 | `0x05` |
| 24–27 | `SHIFT`, `x = 2` | 1 b5 | `0x02` |
| 28–31 | `SHIFT`, `x = 1` | 0 b6 | `0x01` |
| 32–35 | `SHIFT`, `x = 0`, fall through | 1 b7 | `0x00` |
| 36–39 | `SET` 1 | 1 stop | `0x00` |

The ten levels, each repeated four times, are:

```text
0000 1111 0000 1111 0000 0000 1111 0000 1111 1111
```

Clock 40 executes `HALT`. `running` becomes 0. TX stays 1. There is no extra hold.

The receiver, the SPI master, and the I2C master are the other programs in `prog/`. They use the same load path and the same hold.

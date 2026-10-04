## How it works

A 16-word instruction memory drives one pin. `SET` writes a level and holds it for `period` clocks. `SHIFT` does the same with the next LSB of a host-loaded byte, then shifts right. `HALT` stops and leaves the pin where it is.

UART 8N1 is the program `SET 0`, eight `SHIFT`s, `SET 1`, `HALT`. The baud rate is `clock / period`. A period of 0 holds for one clock.

## How to test

Pulse `WR` (`ui[0]`) for one clock with a command on `ui[3:1]` and data on `uio`:

| cmd | write |
| --- | --- |
| 0 | period[7:0] |
| 1 | period[15:8] |
| 2 | shift register |
| 3 | imem address |
| 4 | imem byte, then address increments |
| 5 | program counter |
| 6 | run |

`uo[0]` is the pin. `uo[1]` is high while a program is running. The first instruction executes on the clock after run is accepted.

`make -B` in `test/` checks 8N1 frames, baud scaling, a toggle program, ignored writes while running, and reset.

## External hardware

None for this milestone. A logic analyser on `TX` is enough to see the frame.

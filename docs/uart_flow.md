# UART, one byte, on the pin engine

This is the path one byte takes from a host write to the `tx` pin. The machine is `src/pin_engine.v`. The Tiny Tapeout wrapper is `src/project.v`. What an 8N1 frame is, and why the baud rate is `clock_hz / period`, is `docs/info.md`. The register list is `docs/pin_engine.md`. The same picture, with a slider along the frame, is `docs/pin_engine.html`.

The worked example is the one the test uses: byte `0xA5`, `period = 4`. Four clocks is not a serial-port baud rate. On the 50 MHz clock, 9600 baud is period 5208 and 115200 baud is period 434. The steps are the same at those periods. Only the hold is longer.

UART here is not a peripheral. Nothing in the Verilog knows the words start, data, or stop. Those are eleven bytes in `imem`. The engine has one output pin and spends `period` clocks at whatever level the current instruction wrote.

## The frame the pin has to show

Idle is 1. A frame is a start bit of 0, eight data bits with bit 0 first, and a stop bit of 1. There is no parity bit. `0xA5` is `0b10100101`, so bit 0 is the rightmost 1 and bit 7 is the leftmost 1.

```text
idle  start  b0  b1  b2  b3  b4  b5  b6  b7  stop  idle
  1     0     1   0   1   0   0   1   0   1    1     1
```

Each of those ten columns (start through stop) lasts `period` clocks. After the stop bit the pin is already 1, which is idle again.

## Where the pins go

`tt_um_posamokshith_proto` wires the engine straight through.

| Pin | Engine port | Role on a write |
| --- | --- | --- |
| `ui[0]` | `wr` | 1 for exactly one clock |
| `ui[3:1]` | `cmd` | which register |
| `uio[7:0]` | `wdata` | the byte |
| `uo[0]` | `tx` | the UART wire |
| `uo[1]` | `busy` | `running` |

`uio_oe` is 0, so `uio` is an input. `ena` and `ui[7:4]` are unused. `uo[7:2]` is 0.

A host write is accepted only while `running` is 0. The host is the test, or later a controller. It is not an instruction.

## Step 1. Reset

`rst_n` low on a rising clock clears the machine:

| Register | Value |
| --- | --- |
| `tx` | 1, the idle level |
| `imem[0]` … `imem[15]` | `0x00`, which is `HALT` |
| `running` | 0 |
| `pc`, `waddr`, `shift`, `wait_left` | 0 |
| `period` | 1 |

`uo[0]` is high. `uo[1]` is low. The host can write.

## Step 2. Load the eleven-byte program

Each line is one clock with `ui[0]` set. The strobe returns to 0 afterward. Command 4 stores a byte and then increments the address, so one address write is enough for the whole program.

| Clock | `ui[3:1]` | `uio` | Result |
| --- | --- | --- | --- |
| 1 | 3 | `0x00` | address = 0 |
| 2 | 4 | `0x20` | `imem[0] = SET 0`, address = 1 |
| 3–10 | 4 | `0x30` | `imem[1]` … `imem[8] = SHIFT` |
| 11 | 4 | `0x21` | `imem[9] = SET 1`, address = 10 |
| 12 | 4 | `0x00` | `imem[10] = HALT`, address = 11 |

`imem` is now:

| `pc` | Byte | Instruction | Bit it will produce |
| --- | --- | --- | --- |
| 0 | `0x20` | `SET 0` | start |
| 1 | `0x30` | `SHIFT` | b0 |
| 2 | `0x30` | `SHIFT` | b1 |
| 3 | `0x30` | `SHIFT` | b2 |
| 4 | `0x30` | `SHIFT` | b3 |
| 5 | `0x30` | `SHIFT` | b4 |
| 6 | `0x30` | `SHIFT` | b5 |
| 7 | `0x30` | `SHIFT` | b6 |
| 8 | `0x30` | `SHIFT` | b7 |
| 9 | `0x21` | `SET 1` | stop |
| 10 | `0x00` | `HALT` | pin stays where it is |

The opcode is the high nibble. `SET` uses bit 0 of the byte as the new pin level and does not touch `shift`. `SHIFT` drives the pin from bit 0 of `shift`, then shifts that register right by one, filling the top with 0.

`imem[11]` through `imem[15]` are still `HALT` from reset. This program never reaches them.

## Step 3. Load the bit time and the byte

Reset left `period` at 1, so the high byte is already 0. Command 1 is only required when that byte must change.

| Clock | `ui[3:1]` | `uio` | Result |
| --- | --- | --- | --- |
| 13 | 0 | `0x04` | `period = 4` |
| 14 | 2 | `0xA5` | `shift = 0xA5` |
| 15 | 5 | `0x00` | `pc = 0` |

`tx` is still 1. `running` is still 0. The same eleven bytes send any later payload. Only `shift` has to change.

## Step 4. Run

| Clock | `ui[3:1]` | `uio` | Result |
| --- | --- | --- | --- |
| 16 | 6 | ignored | `running = 1`, `wait_left = 0` |

That clock does not execute `imem[0]`. The write is accepted because `running` was still 0 at the edge. `running` becomes 1 as a result of the edge, so the instruction runs on the next rising clock. From that next clock until `HALT`, a host write is dropped, including another command 6.

`uo[1]` goes high on the RUN clock and stays high through the stop bit.

## Step 5. How one bit lasts four clocks

On the clock an instruction runs, `wait_left` is 0, so the engine executes `imem[pc]`. For `SET` and `SHIFT` it does three things on that edge:

1. Update `tx`.
2. Advance `pc`.
3. Load `wait_left` with `period - 1`.

A period of 0 is stored as a hold of 1, so the load is `max(period, 1) - 1`. With `period = 4` the load is 3.

The next clocks find `running` set and `wait_left` nonzero, so each of them only does `wait_left -= 1`. The pin is not touched. After three such clocks `wait_left` is 0 again and the following clock executes the next instruction.

One execute clock plus three countdown clocks is four clocks at the new level. The same split is what makes period 5208 last 5208 clocks: one execute, then 5207 countdowns.

`HALT` is the exception. It clears `running` and does not load `wait_left`. The pin stays at the level the previous instruction left.

## Step 6. The forty clocks of the frame

Clock 0 in this table is the first clock after RUN, the one that executes `imem[0]`. The test samples `tx` there. Each row is the execute clock. The next `period - 1` clocks hold that same `tx`.

`shift` is shown after the right shift. `SET` does not change it.

| Clocks | `pc` before | Instruction | `tx` for this bit | `shift` after |
| --- | --- | --- | --- | --- |
| 0–3 | 0 | `SET 0` | 0 start | `0xA5` |
| 4–7 | 1 | `SHIFT` | 1 b0 | `0x52` |
| 8–11 | 2 | `SHIFT` | 0 b1 | `0x29` |
| 12–15 | 3 | `SHIFT` | 1 b2 | `0x14` |
| 16–19 | 4 | `SHIFT` | 0 b3 | `0x0A` |
| 20–23 | 5 | `SHIFT` | 0 b4 | `0x05` |
| 24–27 | 6 | `SHIFT` | 1 b5 | `0x02` |
| 28–31 | 7 | `SHIFT` | 0 b6 | `0x01` |
| 32–35 | 8 | `SHIFT` | 1 b7 | `0x00` |
| 36–39 | 9 | `SET 1` | 1 stop | `0x00` |

Read one `SHIFT` the way the Verilog does. At clocks 4–7 the register is still `0xA5`, which is `0b10100101`. Bit 0 is 1, so `tx` becomes 1. The shift `{1'b0, shift[7:1]}` yields `0b01010010`, which is `0x52`. The next `SHIFT` takes bit 0 of `0x52`, which is 0, and the register becomes `0x29`. Eight shifts consume the byte from the bottom and leave `shift` at 0.

The ten levels, each repeated four times, are the samples `test/test_pin_engine.py` checks:

```text
0000 1111 0000 1111 0000 0000 1111 0000 1111 1111
```

That is start, then bits `1 0 1 0 0 1 0 1`, then stop.

## Step 7. Halt

Clock 40 executes `imem[10]`, which is `0x00`. `running` becomes 0. `tx` stays 1. `uo[1]` falls. There is no extra hold.

The host can write again. A second byte reuses `imem`. It needs a new `shift`, `pc = 0`, and command 6. The program does not have to be loaded twice.

## What this flow does not do

There is no instruction that reads a pin, so this program cannot assemble a received byte. The receiver described in `docs/info.md` waits for the falling edge, waits one and a half bit-times, and samples the middle of each data bit. That program is not in `imem` yet.

SPI and I2C need more than one driven pin, and I2C needs a pin that can be released. `uio_oe` is tied off, and the instruction set has no read. Those protocols are later programs on a larger machine. This flow is the transmit half of 8N1 only.

# The program in the repository

`src/pin_engine.v` is an interpreter with one output pin. The program it runs transmits one UART 8N1 byte. The problem that program is aimed at is `docs/info.md`.

The host is the test, or later a controller on the board. It fills the interpreter's state, then starts it. The host is not an instruction. It writes the way a driver writes memory-mapped registers, one register per clock, and only while the program is stopped.

## State

| Name | Width | Role |
| --- | --- | --- |
| `imem` | 16 bytes | The program. One byte is one instruction |
| `pc` | 4 bits | Index into `imem` |
| `period` | 16 bits | Clocks to hold the pin after `SET` or `SHIFT` |
| `shift` | 8 bits | The data byte |
| `wait_left` | 16 bits | How many clocks remain in the current hold |
| `tx` | 1 bit | The output pin. Reset value is 1, UART idle |
| `running` | 1 bit | 1 while the program has not reached `HALT` |

On each rising clock the interpreter does one of these, in order:

```text
if reset:                          tx = 1, imem = all HALT, running = 0
else if stopped and host writes:   update the register named by the command
else if running and wait_left > 0: wait_left -= 1
else if running:                   execute imem[pc]
```

The opcode is the high nibble of the instruction byte.

| Byte | Name | Effect, then a hold of `period` clocks |
| --- | --- | --- |
| `0x00` | `HALT` | `running = 0`. The pin stays where it is. No hold |
| `0x20` | `SET 0` | `tx = 0` |
| `0x21` | `SET 1` | `tx = 1` |
| `0x30` | `SHIFT` | `tx = shift & 1`, then `shift >>= 1` |
| other | | `pc += 1`, and the pin is left alone |

`SET` uses the low bit of the opcode and does not touch `shift`. A period of 0 is stored as a hold of 1, so the pin always spends at least one clock at the new level. The hold counter is loaded with `period - 1` on the clock the instruction runs, which makes the level last `period` clocks in total.

The first instruction runs on the clock after the host's RUN write, because that write is the clock that sets `running`. While `running` is 1, host writes are dropped.

## UART transmit program

Eleven of the sixteen bytes:

```text
0x20   SET 0      start bit
0x30   SHIFT      eight times, bit 0 first
0x21   SET 1      stop bit
0x00   HALT
```

The baud rate is `clock_hz / period`, from `docs/info.md`. The same eleven bytes send any payload. The host writes a new `shift` and runs from `pc = 0` again.

`SHIFT` is the data bits:

```c
tx = shift & 1;
shift >>= 1;
```

For `0xA5` (`0b10100101`) and `period = 4`, each column is four clocks:

```text
idle  start  b0  b1  b2  b3  b4  b5  b6  b7  stop  idle
  1     0     1   0   1   0   0   1   0   1    1     1
```

There is no instruction that reads a pin. SPI and I2C need more than this one output, so this program does not run them.

## Loading it

`tt_um_posamokshith_proto` in `src/project.v` connects the interpreter to the Tiny Tapeout pins. For one clock the host presents a command and a data byte:

| Pins | Role |
| --- | --- |
| `ui[0]` | Write strobe. 1 for exactly one clock |
| `ui[3:1]` | Command number |
| `uio[7:0]` | Data byte for that command |
| `uo[0]` | `tx` |
| `uo[1]` | `running` |

| Command | Writes |
| --- | --- |
| 0 | `period[7:0]` |
| 1 | `period[15:8]` |
| 2 | `shift` |
| 3 | Address in `imem` |
| 4 | `imem[address] = data`, then the address increments |
| 5 | `pc` |
| 6 | `running = 1`. Data is ignored |

Sending `0xA5` at `period = 4`. Each line is one clock with the strobe set, then the strobe returns to 0.

```text
cmd 3, data 0        address = 0
cmd 4, data 0x20     imem[0] = SET 0
cmd 4, data 0x30     eight times
cmd 4, data 0x21
cmd 4, data 0x00
cmd 0, data 4        period = 4
cmd 2, data 0xA5     shift = 0xA5
cmd 5, data 0        pc = 0
cmd 6, data 0        run
```

`ui[7:4]` and `uo[7:2]` are unused. `uio_oe` is 0, so `uio` is an input.

## Running the tests

From the repository root, with the virtualenv that has cocotb:

```bash
source .venv/bin/activate
cd test && make -B
```

`test/test_pin_engine.py` checks 8N1 frames for several bytes, a longer period and a one-clock period, a second program that only toggles the pin, host writes dropped while running, and reset clearing the program back to `HALT`. The toggle program is there so a passing test means the waveform came from `imem`. The simulation writes `test/tb.fst`, the same record a logic analyser would capture from `tx`. No board is required.

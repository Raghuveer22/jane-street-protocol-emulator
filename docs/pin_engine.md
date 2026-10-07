# The program in the repository

`src/pin_engine.v` is an interpreter. UART transmit, UART receive, SPI, I2C, and low-speed USB are programs it runs. The word format and those programs are `docs/instruction_definition.html`. The problem they are aimed at is `docs/info.md`.

The host is the test, or later a controller on the board. It fills the interpreter's state, then starts it. The host is not an instruction. It writes one register per clock, and only while the program is stopped.

## State

| Name | Width | Role |
| --- | --- | --- |
| `imem` | 32 words of 16 bits | The program. One word is one run step |
| `pc` | 5 bits | Index into `imem` |
| `T`, `Tlo`, `Thi` | 16 bits each | The hold lengths a step can name. `T/2` is `T` shifted right by 1 |
| roles 0–3, side | one byte each | Which pin, how it is driven, and the idle level |
| `out_dir`, `in_dir`, `xreload` | packed in one byte | Bit order of the two shift registers, and the value `setx` loads |
| output shift | 8 bits | The payload byte |
| input shift | 8 bits | The byte assembled from sampled pins |
| `x` | 4 bits | Loop counter |
| `wait_left` | 16 bits | Clocks remaining in the current hold |
| `running` | 1 bit | 1 while the program has not reached `HALT`. This is `uo[7]` |
| `tx_buf`, `rx_buf` | 16 bytes each | One USB packet. Transmit bytes are loaded. Receive bytes are read back with command 6 |
| `pkt_len` | 8 bits | How many of those bytes this run uses, clamped to 16 |
| `nrzi`, `ones`, `bit_idx` | 1, 3, and 9 bits | Last D+ level, consecutive 1s, and the next buffer bit. Cleared by `CMD_RUN` |

On each rising clock the interpreter does one of these, in order:

```text
if reset:                          pins at idle, imem = all HALT, running = 0
else if stopped and host writes:   update the register named by the command
else if running and wait_left > 0: wait_left -= 1
else if running:                   execute imem[pc]
```

The opcode is the high nibble of the instruction word.

| Opcode | Name | Effect, then the named hold |
| --- | --- | --- |
| `0x0` | `HALT` | `running = 0`. Pins stay. No hold |
| `0x1` | `WAIT` | Stall until the role reads `val` |
| `0x2` | `SET` | Drive the role to `val`, push-pull |
| `0x3` | `SHIFT` | Drive the role to the next payload bit, push-pull |
| `0x4` | `IN` | Sample the role into the input shift |
| `0x5` | `OD` | Pull or release the role. `val` 0 pulls, 1 releases |
| `0x6` | `ODSHIFT` | Payload bit 0 pulls the role, bit 1 releases it |
| `0x7` | `HOLD` | Change no pin. Load the wait |
| `0x8` | `USB_OUT` | NRZI bit from the packet buffer onto D+ and not-D+ |
| `0x9` | `USB_IN` | Sample NRZI from D+. Drop the stuff bit. Fall through on SE0 |

`side` on `SET`, `SHIFT`, `IN`, `OD`, and `ODSHIFT` writes the side pin on that same tick. A hold length of 0 is stored as a hold of 1. The hold counter is loaded with `ticks - 1` on the clock the instruction runs, so the level lasts `ticks` clocks. `hold = none` and `hold = 1` both last one clock.

The first instruction runs on the clock after the host's `CMD_RUN`, because that write is the clock that sets `running`. While `running` is 1, host writes are dropped. `CMD_RUN` clears the input shift.

## Pins

A binding byte is `{mode[1:0], idle, pin[4:0]}`. Mode 0 is an input, 1 is push-pull, 2 is open-drain. Pins 0–7 are `ui`, 8–14 are `uo[6:0]`, and 16–23 are `uio`. Pin 15 is `running`, so it is not a role.

Push-pull drives 0 and 1. Open-drain pull sets the enable and drives 0. Open-drain release clears the enable. While the enable is clear, the bit the program reads is `uio_in`. The test, standing in for the other chip and the pull-up, has to present a 1 on a released line that nobody is pulling down.

`ui[3:0]` is the host port: `ui[0]` is the strobe and `ui[3:1]` is the command. `ui[4]` is the input the UART, SPI, and USB programs use for RX, MISO, and D+. USB D− receive is `ui[5]`. `ui[7:4]` is also the byte index for command 6.

## Loading it

`tt_um_posamokshith_proto` in `src/project.v` connects the interpreter to the Tiny Tapeout pins. For one clock the host presents a command and a data byte:

| Pins | Role |
| --- | --- |
| `ui[0]` | Write strobe. 1 for exactly one clock |
| `ui[3:1]` | Command number |
| `uio[7:0]` | Data byte for that command |
| `uo[7]` | `running` |
| `uo[6:0]`, `uio` | The pins the bindings name |

| Command | Writes |
| --- | --- |
| 0 `CMD_ADDR` | Load address |
| 1 `CMD_WRITE` | Store one byte there, then the address increments |
| 2 `CMD_PAYLOAD` | Output shift register |
| 3 `CMD_PC` | First instruction of this run. Five bits |
| 4 `CMD_RUN` | `running = 1`. Data is ignored |
| 5 `CMD_READ` | While stopped, drive the input shift onto `uio` for that tick |
| 6 `CMD_BUF` | While stopped, drive `rx_buf[ui[7:4]]` onto `uio` for that tick |

`CMD_ADDR` / `CMD_WRITE` walk a flat byte space. `0x00`–`0x3F` is `imem`, low byte then high byte. `0x40`–`0x4B` is `T`, `Tlo`, `Thi`, the five bindings, and the direction byte. `0x4C` is the USB packet length. `0x50`–`0x5F` are the USB transmit bytes. The map is in `docs/opcodes.md`.

The programs:

| File | What it is |
| --- | --- |
| `prog/uart_8n1.asm` | Transmit. Start, eight bits, stop |
| `prog/uart_rx.asm` | Receive. Start edge, sample the middle of each bit |
| `prog/spi_mode0.asm` | Master. MOSI out, MISO in, on the rising clock |
| `prog/i2c_master.asm` | Master. Start, eight bits, acknowledgement, stop |
| `prog/usb_ls_tx.asm` | Low-speed USB transmit. NRZI, stuff bits, then SE0 |
| `prog/usb_ls_rx.asm` | Low-speed USB receive. Sample until both pins read 0 |

`prog/asm.py` assembles those mnemonics to one word per line.

## Running the tests

From the repository root, with the virtualenv that has cocotb:

```bash
source .venv/bin/activate
cd test && make -B
```

`test/test_pin_engine.py` checks UART frames, a receiver, an SPI transfer, an I2C exchange with an acknowledgement and a stretched clock, a second I2C byte that leaves SCL pulled, a toggle program, host writes dropped while running, reset clearing `imem` back to `HALT`, a stuffed USB transmit, a `T = 33` byte of zeros, and a receive that stores the same bytes and stops on SE0. The toggle program is there so a passing test means the waveform came from `imem`.

`make -f Makefile.uart` in `test/` is the longer UART transmitter bench. It assembles `prog/uart_8n1.asm` and checks the wire at several bit times, including 434 and 5208.

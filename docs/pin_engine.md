# The program in the repository

`src/pin_engine.v` is an interpreter. UART transmit, UART receive, SPI, and I2C are programs it runs. The word format and those programs are `docs/instruction_definition.html`. The problem they are aimed at is `docs/info.md`.

The host is the test, or later a controller on the board. It fills the interpreter's state, then starts it. The host is not an instruction. It writes one register per clock. Config and the payload are accepted only while the program is stopped. Instruction words can also be written while it is running, and those words go into the bank that is not executing.

## State

| Name | Width | Role |
| --- | --- | --- |
| `imem` | 2 banks, 32 words of 16 bits each | The program. The engine reads the active bank. One word is one run step |
| `pc` | 5 bits | Index into the active bank |
| `T`, `Tlo`, `Thi` | 16 bits each | The hold lengths a step can name. `T/2` is `T` shifted right by 1 |
| roles 0–3, side | one byte each | Which pin, how it is driven, and the idle level |
| `out_dir`, `in_dir`, `autopull`, `autopush`, `xreload` | packed in one byte | Bit order, FIFO refill, and the value `setx` loads into `x` |
| shift width, base pin | one byte, `0x4C` | 1, 2, or 4 bits, starting at a pin. Width 1 uses the role |
| `yreload` | 4 bits in `0x4D[4:1]` | What `setx` on `OP_XOR` loads into `Y`. Bit 0 still arms the bank switch |
| TX FIFO, RX FIFO | 4 bytes each | Bytes queued ahead of the shift registers |
| output shift | 8 bits | The payload byte |
| input shift | 8 bits | The byte assembled from sampled pins |
| `x` | 4 bits | Loop counter |
| `Y` | 4 bits | Run-length counter for `OP_XOR` / `OP_JMP`. `CMD_RUN` loads `yreload` |
| `wait_left` | 16 bits | Clocks remaining in the current hold |
| `running` | 1 bit | 1 while the program has not reached `HALT`. This is `uo[7]` |

On each rising clock the interpreter does one of these, in order:

```text
if reset:                          pins at idle, imem = all HALT, running = 0
else if stopped and host writes:   update the register named by the command
else if running and wait_left > 0: wait_left -= 1
else if running:                   execute imem[active_bank][pc]
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
| `0x6` | `ODSHIFT` | Payload bit 0 pulls the role, bit 1 releases it. Bit 9 set: a lost open-drain bit releases the role and stops |
| `0x7` | `HOLD` | Change no pin. Load the wait |
| `0x8` | `MATCH` | Continue if the role reads `val`. Otherwise release an open-drain role and stop |
| `0x9` | `JMP` | Branch on a condition. No pin write. Bits `[9:7]` name it |
| `0xA` | `XOR` | Width-1 differential bit. `side` is the complement. `xdec` / `setx` touch `Y` |

`side` on `SET`, `SHIFT`, `IN`, `OD`, `ODSHIFT`, and `XOR` writes the side pin on that same tick. On `XOR` the side pin is the complement of the new role level. A hold length of 0 is stored as a hold of 1. The hold counter is loaded with `ticks - 1` on the clock the instruction runs, so the level lasts `ticks` clocks. `hold = none` and `hold = 1` both last one clock.

The first instruction runs on the clock after the host's `CMD_RUN`, because that write is the clock that sets `running`. While `running` is 1, config and payload writes are dropped, except a store into the idle instruction bank and byte `0x4D`. `CMD_PUSH` and `CMD_POP` still move one FIFO byte on that clock, and a push does not steal a tick from a hold. `CMD_RUN` clears the input shift and loads `Y` from `yreload`.

`0x4D` bit 0 arms a bank switch. Bits `[4:1]` are `yreload`. `OP_HALT` takes the arm, and so does the step that would leave word 31 without a backward branch. The banks flip, `pc` becomes 0, and `running` stays 1. The program that was running is now the idle bank, so the host can refill it for the next handoff. A loop that branches backward never hands off. With the arm clear, `OP_HALT` still stops.

## Pins

A binding byte is `{mode[1:0], idle, pin[4:0]}`. Mode 0 is an input, 1 is push-pull, 2 is open-drain. Pins 0–7 are `ui`, 8–14 are `uo[6:0]`, and 16–23 are `uio`. Pin 15 is `running`, so it is not a role.

Push-pull drives 0 and 1. Open-drain pull sets the enable and drives 0. Open-drain release clears the enable. While the enable is clear, the bit the program reads is `uio_in`. The test, standing in for the other chip and the pull-up, has to present a 1 on a released line that nobody is pulling down.

`ui[3:0]` is the host port: `ui[0]` is the strobe and `ui[3:1]` is the command. `ui[4]` is the input the UART and SPI programs use for RX and MISO.

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
| 2 `CMD_PAYLOAD` | Output shift register. Ignored while running |
| 3 `CMD_PC` | First instruction of this run. Five bits |
| 4 `CMD_RUN` | `running = 1`. Data is ignored |
| 5 `CMD_READ` | Stopped: input shift on `uio`. Running: FIFO status on `uio` |
| 6 `CMD_PUSH` | Enqueue one TX byte. Legal while running |
| 7 `CMD_POP` | Dequeue one RX byte onto `uio`. Legal while running |

`CMD_ADDR` / `CMD_WRITE` walk a flat byte space. `0x00`–`0x3F` is one bank of `imem`, low byte then high byte. While stopped that is the active bank. While running it is the other one. `0x40`–`0x4C` is `T`, `Tlo`, `Thi`, the five bindings, the direction byte, and the shift width. `0x4D` bit 0 arms the bank switch and bits `[4:1]` are `yreload`. The map is in `docs/opcodes.md`.

The programs:

| File | What it is |
| --- | --- |
| `prog/uart_8n1.asm` | Transmit. Start, eight bits, stop |
| `prog/uart_rx.asm` | Receive. Start edge, sample the middle of each bit |
| `prog/spi_mode0.asm` | Master. MOSI out, MISO in, on the rising clock |
| `prog/i2c_master.asm` | Master. Start, eight bits, acknowledgement, stop |
| `prog/uart_8n1_stream.asm` | Transmit frames back to back from the TX FIFO |
| `prog/uart_rx_stream.asm` | Receive frames back to back into the RX FIFO |
| `prog/spi_mode0_stream.asm` | Master, CS held, bytes from the FIFOs |
| `prog/qspi_nibble.asm` | Two width-4 shifts with the side pin as SCK |
| `prog/usb_ls_tx.asm` | Low-speed USB packet. `XOR`, `JMP`, programmable stuff length |

`prog/asm.py` assembles those mnemonics to one word per line.

## Running the tests

From the repository root, with the virtualenv that has cocotb:

```bash
source .venv/bin/activate
cd test && make -B
```

`test/test_pin_engine.py` checks UART frames, a receiver, an SPI transfer, an I2C exchange with an acknowledgement and a stretched clock, a second I2C byte that leaves SCL pulled, a toggle program, config writes dropped while running, reset clearing `imem` back to `HALT`, back-to-back UART and SPI through the FIFOs, a bank handoff on `HALT` and on the step off word 31, quad and dual shifts, and a low-speed USB packet that checks the differential complement, SE0, and a stuff length set by `yreload`. The toggle program is there so a passing test means the waveform came from `imem`.

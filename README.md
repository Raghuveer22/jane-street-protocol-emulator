# Jane Street protocol-emulator ASIC

Open-source chip for the [Jane Street protocol-emulator ASIC competition](https://blog.janestreet.com/protocol-emulator-asic-competition/).

Deadline: **18 January 2027**.

## What to build

A small reprogrammable CPU whose instruction set reads pins, writes pins, and counts cycles tightly enough to run a protocol in firmware. Fixed UART, SPI, and I2C blocks do not meet the brief. New protocols have to be possible after fabrication, inside the timing and pin limits.

Required first protocols: UART, SPI, I2C.

Stretch: low-speed USB, 10 Mbit Ethernet. Also worth considering: JTAG, SWD, PS/2, CAN.

## Silicon budget

| Constraint | Value |
| :--- | :--- |
| Process | IHP 130 nm CMOS5L, through Tiny Tapeout |
| Tile size | 6×4 in `info.yaml` (24 tiles, about 0.7 mm²) |
| Cell budget | About 1K logic cells per tile |
| Clock and route | Run place-and-route and check timing. Synthesis area is not enough |
| License | Open source. Building in public is allowed |
| Prize | Selected designs taped out on the March 2027 CMOS5L shuttle. Winners get chips on a dev board |

Jane Street may raise the cap to 8×4 tiles. Stay on 6×4 until they say otherwise.

This folder is the [Tiny Tapeout CMOS5L Verilog template](https://github.com/TinyTapeout/ttihp-verilog-template), with the pin engine filled in. First milestone from the announcement: a UART transmitter on a pin, then make that transmitter programmable.

## Where the RTL is

`src/pin_engine.v` is a 16-word program memory and one timed pin. UART 8N1 is firmware:

`SET 0`, eight `SHIFT`s (LSB first), `SET 1`, `HALT`.

Each `SET` or `SHIFT` holds the pin for `period` clocks, so baud is `clock / period`. A second program that only toggles the pin is in the test, to keep this from turning into a fixed UART block. The top `tt_um_posamokshith_proto` is the Tiny Tapeout pinout (`info.yaml`, 6×4 tiles).

Install the template's test tools, then run the suite. `test/tb.v` wraps the top, which is what `.github/workflows/test.yaml` runs:

```bash
pip install -r test/requirements.txt
cd test && make -B
```

`src/config.json` is the template OpenLane config (50 MHz). `.github/workflows/` is the template's test, GDS, docs, and FPGA actions. They run on push because this repository root is the Tiny Tapeout project.

Host command map and the instruction encodings are in `docs/info.md`.

Next: sample an input pin and branch, so SPI and I2C can be programs on the same engine.

Questions: asic-competition@janestreet.com

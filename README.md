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

This folder is the [Tiny Tapeout CMOS5L Verilog template](https://github.com/TinyTapeout/ttihp-verilog-template), with the pin engine filled in.

## Where the RTL is

`src/pin_engine.v` is two banks of 32 16-bit words. The engine runs one bank. While that bank runs, the host can fill the other, then arm a switch that takes effect on `HALT` or at the end of the bank. UART transmit, UART receive, SPI mode 0, and I2C master are programs in `prog/`, not Verilog blocks. The host loads them through six commands. `uo[7]` is `running`. A toggle program in the test keeps this from turning into a fixed UART block. The top `tt_um_posamokshith_proto` is the Tiny Tapeout pinout (`info.yaml`, 6×4 tiles).

Install the template's test tools, then run the suite. `test/tb.v` wraps the top, which is what `.github/workflows/test.yaml` runs:

```bash
pip install -r test/requirements.txt
cd test && make -B
```

`src/config.json` is the template OpenLane config (50 MHz). `.github/workflows/` is the template's test, GDS, docs, and FPGA actions. They run on push because this repository root is the Tiny Tapeout project.

The problem is `docs/info.md`. The instruction word and the host command map are in `docs/instruction_definition.html`. How the engine applies them is `docs/pin_engine.md`.

Questions: asic-competition@janestreet.com

## License

The pin engine in `src/pin_engine.v`, and the rest of this design, are licensed under the CERN Open Hardware Licence Version 2, Strongly Reciprocal (`CERN-OHL-S-2.0`). The full text is `LICENSE`.

If you take the pin engine, change it, or build it into a larger design, and you distribute that work (sources, a bitstream, a GDS, or a chip), you must publish the complete source of that work under the same licence. Keeping a private copy does not trigger this. Shipping one does.

Tiny Tapeout template files this repository started from remain under the Apache License 2.0 (`LICENSE.Apache-2.0`).

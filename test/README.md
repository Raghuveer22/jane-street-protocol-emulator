# Pin engine tests

[cocotb](https://docs.cocotb.org/en/stable/) drives the Tiny Tapeout top and checks the pins. See also the [Tiny Tapeout testing guide](https://tinytapeout.com/hdl/testing/).

## Layout

- `PROJECT_SOURCES` is `pin_engine.v project.v`
- `tb.v` instantiates `tt_um_posamokshith_proto`
- `COCOTB_TEST_MODULES` is `test_pin_engine`

## How to run

From this directory, with the virtualenv that has the packages in `requirements.txt`:

```sh
make -B
```

That runs `test_pin_engine.py`: UART TX/RX, SPI mode 0, I2C master, streaming FIFOs, bank handoff, quad and dual shifts, and low-speed USB transmit.

To run gate-level simulation, first harden the project and copy `../runs/wokwi/results/final/verilog/gl/{your_module_name}.v` to `gate_level_netlist.v`, then:

```sh
make -B GATES=yes
```

For a VCD waveform instead of FST, edit `tb.v` to use `$dumpfile("tb.vcd");` and run:

```sh
make -B FST=
```

## How to view the waveform

GTKWave:

```sh
gtkwave tb.fst tb.gtkw
```

Surfer:

```sh
surfer tb.fst
```

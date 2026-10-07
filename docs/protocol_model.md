# What counts as a protocol on this chip

This is a model of the protocols named in the problem, written against the machine that has to run them. The bounds are `docs/info.md`: one 50 MHz clock, the Tiny Tapeout pins, and a program that can still be changed after the Verilog is printed. The RP2040 version of the same idea is `docs/rp2040_pio.md`. The chip in the repository today is the transmit half of one of these programs, walked in `docs/uart_flow.md`.

Nothing below is a proposal for an instruction encoding. It is the list of facts the encoding has to cover if one machine is going to run all of these as programs. What that machine has to do on one tick, including how many pins move together and both UART phases, is `docs/machine_definition.html`.

## Definition

The same formulas, typeset, are in `docs/protocol_definition.html`. Open that file in a browser.

Time is the tick index `t`, a non-negative integer. The clock and the tick length are fixed by the shuttle:

```text
f = 5e7 Hz
τ = 1/f = 20 ns
```

Tick `t` is the physical instant `t * τ`.

The chip's pins are three copies of `{0, …, 7}`:

```text
U_I   inputs
U_O   outputs
U_B   bidirectional
```

At tick `t` the chip applies an action and observes a sample:

```text
a(t) = ( y_O(t), e(t), y_B(t) )     each in {0,1}^8
x(t) = ( x_I(t), x_B(t) )           each in {0,1}^8
```

`y_O` is driven onto `U_O` on every tick. On a bidirectional pin `i`, the enable `e_i(t)` selects the local driver:

```text
d_i(t) = y_B,i(t)    if e_i(t) = 1
       = Z           if e_i(t) = 0
```

A released pin does not force the wire. With a pull-up, the value sampled back is 0 when this chip or any other chip is pulling low, and 1 otherwise:

```text
x_B,i(t) = not ( me_pull_low_i(t)  or  them_pull_low_i(t) )

me_pull_low_i(t) = e_i(t)  and  not y_B,i(t)
```

That is the whole electrical model the digital program is allowed to use. Rise time through the resistor is outside it.

A protocol is a tuple

```text
Π = ( W, ι, μ, σ, Enc )
```

that satisfies the five constraints below.

`W` is a finite set of roles (TX, SCK, SDA, …). The placement

```text
ι : W  →  U_I ∪ U_O ∪ U_B
```

is injective, so the roles occupy distinct pins. Constraint C1 is the pin budget:

```text
|W|  ≤  |U_I| + |U_O| + |U_B|  =  24          (C1)
```

The drive map `μ : W → {in, push, od}` says how each role is allowed to act:

```text
μ(w) = in     ι(w) is an input pin, and the program only reads x
μ(w) = push   the program sets a level in {0,1} and holds it
μ(w) = od     the program sets me_pull_low in {0,1} and may read x back
```

Constraint C2 is that a push-pull role on `U_B` keeps `e = 1` for the whole frame, and an open-drain role never drives a strong 1. It only pulls or releases.

The synchronizer `σ` is one of three predicates. `y_w(t)` is the level of role `w` at tick `t`.

**Clock I generate.** Some role `c` in `W` has `μ(c) = push`. Bit `k ≥ 0` is the half-open stretch from the `k`-th rising edge of `c` to the next one. The shortest legal clock has each phase at least one tick:

```text
T_clk  ≥  2
f_clk  =  f / T_clk  ≤  f/2  =  25 MHz          (C3)
```

**Clock they generate.** Bit `k` starts at an edge of an input role. The program may take that step only when the sampled bit matches the edge it is waiting for. Between edges it holds.

**No clock wire.** A start condition becomes true at a tick `t0` (for UART, `y(t0-1) = 1` and `y(t0) = 0`). A nominal length `T ≥ 1` then places bit `k` at

```text
[ t0 + kT,  t0 + (k+1)T )                         (C4)
```

For an NRZ bit of value `s_k` in `{0,1}` the level is constant on that interval:

```text
for every t in [ t0 + kT,  t0 + (k+1)T ):    y(t) = s_k
```

The rate this integer `T` actually produces, and its relative error against a named rate `r`, are

```text
r_hat(T) = f / T

ε(T, r)  = | f / (r * T)  -  1 |
```

`T` is an exact hit only when `r` divides `f`, because only then is `f/r` an integer. A named rate is representable when some `T ≥ 1` has `ε(T, r)` inside that protocol's tolerance.

A symbol that needs a transition in the middle of the cell (Manchester) splits `[0, T)` into two halves of length `T/2`. That split is a legal tick count only when

```text
T is even                                         (C5)
```

`Enc` turns a payload into the symbol string. For an 8N1 byte `b = b7 b6 … b0` with `b0` the least significant bit,

```text
Enc(b) = ( 0, b0, b1, b2, b3, b4, b5, b6, b7, 1 )
```

Ten symbols, each held for `T` ticks, so the frame occupies `10T` ticks after `t0`. The idle level on either side is 1. SPI's `Enc` is different in shape and the same kind of object: eight symbols, each a pair `(MOSI, MISO)` aligned to one edge of SCK. MSB first or LSB first is part of `Enc`.

## What may produce a trace

`Π` is realizable on this die when some program `ρ`, fixed for the whole run, produces the waveform. One tick, one step. The state at tick `t` is `q(t)`, the sample is `x(t)`, the action is `a(t)`:

```text
q(t+1) = δ_ρ( q(t), x(t) )
a(t)   = λ( q(t) )
```

A hold step changes no pin and no program counter. If `wait(q) > 0`,

```text
λ(q).pins   = λ(q').pins
wait(q')    = wait(q) - 1
```

where `q'` is the next state. A run step executes one instruction of `ρ` at the program counter and may load a new wait. The program bytes themselves do not change while the machine is running:

```text
running(t) = 1    implies    ρ(t) = ρ(0)
```

A host write at tick `t` is applied to `q` only when `running(t) = 0`. That is the separation between the agreement `ρ` and the payload. Both cross the same pins. They are different fields of `q`, and the running bit says which field a write may touch.

The engine in `src/pin_engine.v` uses this hold for every pin write. On the tick a step with hold length `T` executes, it sets the pins and loads

```text
wait_left  ←  max(T, 1) - 1
```

The following `max(T, 1) - 1` ticks are hold steps. The level therefore lasts `max(T, 1)` ticks, and `r_hat = f / max(T, 1)`.

Checked against C3–C5:

| Target r | Smallest useful T | r_hat(T) | ε | Constraint |
| --- | --- | --- | --- | --- |
| 9600 baud | 5208 | 50e6/5208 ≈ 9601 | 0.006% | C4, exact enough for UART |
| 115200 baud | 434 | 50e6/434 ≈ 115207 | 0.006% | C4 |
| I2C 100 kHz | 500 per full SCL | 100 kHz | 0 | 250 high and 250 low, both integers |
| I2C 400 kHz | 125 per full SCL | 400 kHz | 0 on the period | 125 is odd, so a 50% split is 62+63, not 62.5+62.5 |
| SPI | T_clk = 2 | 25 MHz | 0 | C3 |
| USB 1.5 Mbit/s | 33 | 50e6/33 ≈ 1.515e6 | 1.01% | f/r = 100/3 is not an integer |
| USB 1.5 Mbit/s | 34 | ≈ 1.471e6 | 1.96% | past the usual ±1.5% window |
| USB 12 Mbit/s | 4 or 5 | 12.5 or 10 Mbit/s | 4.2% or 17% | no T lands on 12 Mbit/s |
| Ethernet 10 Mbit/s | 5 | 10 Mbit/s | 0 | C5 fails: T is odd, so no equal mid-bit halves |

## The same definition in words

A protocol, here, is a way to move bits across wires by agreeing in advance on three things:

1. Which wires exist, and whether each wire is driven, released, or only sampled.
2. How the two ends decide where one bit starts. Either a clock wire, or a start edge plus a count of clocks.
3. The order of the bits, and what a 0 and a 1 look like on the wire.

The other chip never sees a byte. It sees pin levels. A byte exists only inside a shift register, on one side or the other.

The Verilog is the machine that can perform that agreement. The bytes in instruction memory are one agreement. UART, SPI, and I2C are three agreements loaded into the same machine. A protocol that shows up later is a fourth loading. A block of Verilog per protocol cannot be that, because the print is already done.

Two streams go through the pins, and they are not the same stream:

| Stream | What it is | How often it changes |
| --- | --- | --- |
| Program | The agreement: which pins, the waits, the branches | Once per protocol |
| Payload | The bytes being sent or assembled | Once per frame |

The UART program already splits them. The words in `imem` stay put. A new payload is the next byte.

## Three ways to stay in step

Every protocol in the list uses one of these. A machine that can do all three can host the list. A machine that can do only the first can host UART transmit and nothing else on this list.

| Sync | Who marks the bit | Protocols |
| --- | --- | --- |
| I generate the clock | An edge on a wire I drive | SPI, JTAG, SWD, I2C as master |
| They generate the clock | I wait until their clock pin moves | PS/2, I2C when the other chip stretches SCL |
| No clock wire | A start edge, then both sides count the same number of ticks | UART, CAN, low-speed USB, 10 Mbit Ethernet |

The count is `period` in the engine that exists today. At 50 MHz one tick is 20 ns, so the baud rate is `50e6 / period` whenever the protocol is the third kind. SPI has no baud rate in that sense. The edge is the whole agreement, and the fastest edge this clock can make is one tick high and one tick low, which is a 25 MHz clock.

## Three ways to put a level on a wire

| Drive | What 0 and 1 mean on the pin | Protocols |
| --- | --- | --- |
| Push-pull | The chip drives 0 and drives 1 | UART, SPI, JTAG |
| Open-drain | The chip drives 0, or releases. A resistor makes a released wire read as 1 | I2C, PS/2, CAN at the controller pin |
| Two pins | A bit is a pair of levels, or a mid-bit transition | USB D+ and D−, Ethernet Manchester |

Open-drain is the output enable, not a second kind of write. `uio_oe` at 0 releases that pin. `uio_oe` at 1 drives `uio_out`. I2C's data bit is that choice: a 1 in the shift register releases SDA, a 0 pulls SDA low. The same choice is CAN's recessive and dominant bits. The engine has to be able to read the wire back after releasing it, because another chip may be pulling it down. That read is the I2C acknowledgement, CAN arbitration, and the PS/2 line.

Push-pull never needs the enable to change during the frame. UART transmit is this case, which is why a single driven pin is enough for it.

## The operations the programs are made of

Laid next to each other, the protocols repeat the same eight moves. The names in the middle column are the RP2040 PIO instructions that already do that move. They are names for the move, not an encoding chosen for this chip.

| Move | PIO name | Why it shows up |
| --- | --- | --- |
| Drive one or more pins to a constant | `SET`, side-set | UART start and stop, SPI chip-select, I2C start and stop |
| Hold for N ticks | delay field, or `period` | The bit time, or half of it |
| Stall until a pin is 0 or 1 | `WAIT` | UART start edge, I2C clock stretch, PS/2 clock edge |
| Shift a bit out of a register onto a pin | `OUT` | Every data bit of every protocol |
| Shift a pin into a register | `IN` | UART receive, SPI MISO, I2C ACK, CAN read-back |
| Change a second pin in the same tick as the shift | side-set | SPI clock beside MOSI, I2C clock beside SDA |
| Count N bits and branch | `JMP` on X | 8 data bits, or 9 with the acknowledgement |
| Release a pin instead of driving 1 | `OUT` to pin direction | I2C, PS/2, CAN recessive |

A loop of those moves is a frame. The payload register is what the loop shifts. The program counter is what makes the next frame the same shape.

Side-set is the one that is easy to miss. SPI is not "shift, then later wiggle the clock." The data bit and the clock edge are one step, so the other chip samples a stable bit. I2C start is the same kind of fact about two pins: SDA falls while SCL stays released. An instruction that can name only one pin cannot say either of those.

## Each protocol as the same record

Columns are the choices above. "Host still does" is the part that is bookkeeping on bytes rather than edges on wires. On this die the host is outside the chip, writing through `ui` and `uio`. There is no second processor next to the state machine the way the RP2040 has its ARM cores.

| Protocol | Wires | Sync | Drive | Shift | Host still does |
| --- | --- | --- | --- | --- | --- |
| UART | TX out, RX in | Start edge, then `period` | Push-pull | LSB first | The bytes. Framing is the program |
| SPI | SCK, MOSI, MISO, CS | Clock I generate | Push-pull | Usually MSB first, both directions on one edge | Chip-select can be the host. Mode is the program |
| I2C | SDA, SCL | Clock I generate, plus their stretch | Open-drain | MSB first, then a 9th bit that is a read | Address and the decision to read or write |
| JTAG | TCK, TMS, TDI, TDO | Clock I generate | Push-pull | LSB first through a shift register | The TAP state diagram, unless the program encodes it |
| SWD | SWCLK, SWDIO | Clock I generate | SWDIO turns around | A packet of header, ACK, data | The turnaround is the program. The memory access is the host |
| PS/2 | CLK, DATA | Clock they generate | Open-drain | Start, 8 data LSB first, parity, stop | Almost nothing at bit rate. The clock is slow |
| CAN | TX, RX behind a transceiver | Start of a dominant bit, then a bit time made of segments | Open-drain at the controller pin | Read back while sending | CRC, acceptance, retransmission |
| USB low-speed | D+, D− | Sync pattern, then a bit time | Two driven pins, NRZI | Bit stuffing, packets | Enumeration and the higher descriptors |
| 10 Mbit Ethernet | A PHY's MII pins, or the cable pair | Preamble, then a bit or a nibble time | Manchester on the cable, nibbles at a PHY | Frame, FCS | The CRC is the heavy part |

JTAG shows the split cleanly. The bit engine is SPI-shaped: a clock, a bit out on TDI, a bit in on TDO, and TMS as one more driven pin. The 16-state TAP is a diagram of those bits. It can live in the program, as branches, or it can live in the host, which then feeds TMS and TDI one bit at a time and lets the machine only clock. Both are the same wires. The difference is how much of the agreement was loaded into `imem`.

SWD is I2C's direction change on a clocked wire. For a few clocks SWDIO stops being an output and becomes an input so the target can drive the ACK. The program has to release, wait, sample, and drive again.

PS/2 is a UART frame with a clock pin and open-drain wires. The device makes the clock, around 10 to 17 kHz, so a bit is thousands of 20 ns ticks. The program waits for the clock edge and samples DATA. The host-inhibit condition is pulling CLK low, which is the open-drain write.

## Clocks available at 50 MHz

A derived count is `50e6 / rate`, in ticks of 20 ns. The two UART rows are the ones already in `docs/info.md`. The others are the same division.

| Protocol | Rate | Ticks per bit | What that means for a program |
| --- | --- | --- | --- |
| UART | 9600 | 5208 | `period = 5208` gives about 9601 baud |
| UART | 115200 | 434 | `period = 434` gives about 115207 baud |
| I2C | 100 kHz | 500 per full clock, 250 high or low | A wait, not a tight loop |
| I2C | 400 kHz | 125 per full SCL | Period is exact. 125 is odd, so the high and low halves are 62 and 63 ticks |
| SPI | up to 25 MHz | 2 per full clock | One tick low, one tick high. Slower modes insert waits |
| PS/2 | about 10–17 kHz | thousands | Waiting on their edge dominates |
| CAN | 1 Mbit/s | 50 | Room inside the bit to place the sample point |
| USB low-speed | 1.5 Mbit/s | 33.3 | 33 ticks is about 1.515 Mbit/s, near 1 percent fast |
| USB full-speed | 12 Mbit/s | 4.17 | No integer tick count lands on 12 Mbit/s |
| Ethernet | 10 Mbit/s | 5 | The bit fits. A half-bit is 2.5 ticks, which is not an integer |

The waits in UART and I2C are the easy ones. `wait_left` in `src/pin_engine.v` is that counter for every hold a program names.

USB low-speed is the first place the tick size shows. The usual rate tolerance on low-speed is about 1.5 percent, and 33 ticks sits inside that. Full-speed does not have an integer `period` on this clock, so it falls outside the model even before the electrical interface is considered.

10 Mbit Ethernet lands on exactly 5 ticks per bit. Manchester coding wants a transition in the middle of the bit, and half of 5 is not a whole number of ticks. The two halves would be 2 ticks and 3 ticks, 40 ns and 60 ns. That is a real deformation of the symbol. Speaking MII to an external PHY instead of Manchester on the cable moves the problem back to nibbles, at 2.5 MHz, which is 20 ticks and an integer.

## Pins

`ui`, `uo`, and `uio` are 24 wires, plus `clk`, `rst_n`, and `ena`. The problem asks for UART's two wires, SPI's four, and I2C's two to be available together. That is eight wires. JTAG adds four, SWD two, PS/2 two, CAN two logic pins behind a transceiver, USB two. All of those roles still fit in 24 if they are not all live at once. A parallel MII Ethernet port is the one that spends most of the pin budget. Ten-megabit on the cable itself is a differential analog pair, which these CMOS pins are not. The programmable part, if Ethernet is attempted, is the digital side of a PHY.

## Where the engine in the repository sits

`src/pin_engine.v` is that machine. The eight moves are the eight opcodes. A step names one of four roles, and may write the side pin on the same tick. The host commands and the load map are `docs/opcodes.md`.

| Move | Opcode |
| --- | --- |
| Drive a pin to 0 or 1 | `OP_SET` |
| Hold for N ticks | `wait_left`, from `T`, `T/2`, `Tlo`, `Thi`, one tick, or none |
| Shift a bit out | `OP_SHIFT` push-pull, `OP_ODSHIFT` open-drain. Either bit order |
| Stall until a pin matches | `OP_WAIT` |
| Shift a pin in | `OP_IN` |
| Second pin in the same tick | `side` on the data opcode |
| Count and branch | `setx`, `xdec`, `back` |
| Release a pin | `OP_OD` and `OP_ODSHIFT`. `uio_oe` follows the binding |

UART transmit, UART receive, SPI mode 0, and I2C master are the programs in `prog/`. `uo[7]` is `running`. Pin 15 is that flag.

The part that stays outside instruction memory is the part that is not an edge. CRC polynomials, USB descriptors, and the decision of which I2C address to talk to are byte bookkeeping. They can run in the host between frames. The frame itself, the edges and the waits, is the program, because a host behind USB and a scheduler cannot hit a 2.5 microsecond I2C half-period. That split is the one `docs/info.md` is built around.

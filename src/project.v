/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Tiny Tapeout top for the Jane Street protocol-emulator ASIC.
 * UART, SPI, and I2C are programs loaded into pin_engine.
 *
 *   ui_in[0]     write strobe, one clock
 *   ui_in[3:1]   command
 *   ui_in[7:4]   free inputs. UART RX and SPI MISO use ui[4]
 *   uio_in       config/payload while stopped; CMD_PUSH data while running
 *   uo_out[6:0]  program outputs. Pin 8 is uo[0]
 *   uo_out[7]    running. Pin 15 is this flag, not a protocol pin
 *   uio_out/oe   program pins, or the shift/FIFO/status byte for one tick
 */

`timescale 1ns/1ps
`default_nettype none

module tt_um_posamokshith_proto (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    pin_engine engine (
        .clk     (clk),
        .rst_n   (rst_n),
        .ui      (ui_in),
        .uio_in  (uio_in),
        .uo      (uo_out),
        .uio_out (uio_out),
        .uio_oe  (uio_oe)
    );

    wire _unused = &{ena, 1'b0};

endmodule

`default_nettype wire

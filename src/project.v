/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Tiny Tapeout top for the Jane Street protocol-emulator ASIC.
 * Milestone: a UART 8N1 waveform, produced by a program on pin_engine.
 *
 *   ui_in[0]   write strobe, one clock
 *   ui_in[3:1] command
 *   uio_in     write data
 *   uo_out[0]  tx
 *   uo_out[1]  busy
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

    wire tx;
    wire busy;

    pin_engine engine (
        .clk   (clk),
        .rst_n (rst_n),
        .wr    (ui_in[0]),
        .cmd   (ui_in[3:1]),
        .wdata (uio_in),
        .tx    (tx),
        .busy  (busy)
    );

    assign uo_out  = {6'b0, busy, tx};
    assign uio_out = 8'b0;
    assign uio_oe  = 8'b0;

    wire _unused = &{ena, ui_in[7:4], 1'b0};

endmodule

`default_nettype wire

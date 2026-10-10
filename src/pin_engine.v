/*
 * SPDX-License-Identifier: CERN-OHL-S-2.0
 * SPDX-FileCopyrightText: 2026 Posa Mokshith
 *
 * Copyright Posa Mokshith 2026.
 *
 * This source describes Open Hardware and is licensed under the CERN-OHL-S v2.
 *
 * You may redistribute and modify this pin engine and make products
 * using it under the terms of the CERN-OHL-S v2
 * (https://ohwr.org/cern_ohl_s_v2.txt).
 * Including this file in a larger design makes that larger design
 * modified Covered Source. If you convey the sources, a bitstream, a
 * GDS, or a chip, you must make the complete source of that work
 * public under CERN-OHL-S.
 *
 * This source is distributed WITHOUT ANY EXPRESS OR IMPLIED WARRANTY,
 * INCLUDING OF MERCHANTABILITY, SATISFACTORY QUALITY AND FITNESS FOR A
 * PARTICULAR PURPOSE. Please see the CERN-OHL-S v2 for applicable
 * conditions.
 *
 * Source Location: https://github.com/Raghuveer22/jane-street-protocol-emulator
 * A Product made from this source must state that Source Location in
 * its documentation.
 *
 * Programmable pin engine. UART, SPI, and I2C are programs in imem.
 * The 16-bit word, the load map, and those programs are documented in
 * docs/instruction_definition.html.
 *
 *   OP_HALT    0x0  running = 0. Pins stay.
 *   OP_WAIT    0x1  stall until role reads val
 *   OP_SET     0x2  drive role to val, push-pull
 *   OP_SHIFT   0x3  drive the next payload bits, push-pull
 *   OP_IN      0x4  sample into the input shift
 *   OP_OD      0x5  pull or release role. val 0 pulls, val 1 releases
 *   OP_ODSHIFT 0x6  payload bit 0 pulls role, bit 1 releases it.
 *                  Bit 9 set: if an open-drain bus reads back a
 *                  different bit on this tick, release and stop.
 *   OP_HOLD    0x7  change no pin, only load the wait
 *   OP_MATCH   0x8  if the role reads val, continue. Otherwise release
 *                  an open-drain role and stop.
 *   OP_JMP     0x9  branch on a condition. No pin write. Bits [9:7]
 *                  name the condition. True and back != 0: pc - back.
 *                  True and back == 0: skip the next word. False: pc + 1.
 *   OP_XOR     0xA  width-1 differential bit. val 0: level XOR ~bit
 *                  (a 0 toggles, a 1 holds) and consume the bit. val 1:
 *                  toggle without taking a bit. side drives the complement.
 *                  xdec counts ones into Y; a 0 reloads yreload. setx
 *                  loads Y. Neither touches X.
 *
 * Instruction memory is two banks of 32 words. The engine fetches the
 * active bank. While stopped, CMD_WRITE stores into that bank. While
 * running, CMD_WRITE stores into the other bank, so a host fill cannot
 * change the program that is executing. Byte 0x4D bit 0 arms a switch.
 * Bits [4:1] are yreload. The switch happens on OP_HALT, or when pc
 * steps off word 31 without a backward branch: the banks flip, pc
 * returns to 0, and running stays 1. Other config writes are ignored
 * while a program is running. CMD_PUSH and CMD_POP are not: they move
 * one byte into the TX FIFO or out of the RX FIFO on that clock,
 * including during a hold. Autopull and autopush are bits in the
 * direction byte. Off, this is the one-byte machine.
 *
 * The instruction at pc runs on the clock after CMD_RUN. A hold length of
 * 0 is a hold of 1. CMD_RUN loads Y from yreload. uo[7] is `running`, so
 * pin 15 is not a protocol pin.
 *
 * Pin drive and sample are pin_io. The statements below are included from
 * the headers named here. The clocked process shares one set of registers.
 *
 *   pin_engine_decode.vh  word fields, next shift, jump target
 *   pin_engine_tasks.vh   retire a step and consume payload bits
 *   pin_engine_config.vh  writes while stopped
 *   pin_engine_ops.vh     the opcode case
 */

`timescale 1ns/1ps
`default_nettype none

module pin_engine (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] ui,
    input  wire [7:0] uio_in,
    output wire [7:0] uo,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe
);

    localparam [2:0] CMD_ADDR    = 3'd0;
    localparam [2:0] CMD_WRITE   = 3'd1;
    localparam [2:0] CMD_PAYLOAD = 3'd2;
    localparam [2:0] CMD_PC      = 3'd3;
    localparam [2:0] CMD_RUN     = 3'd4;
    localparam [2:0] CMD_READ    = 3'd5;
    localparam [2:0] CMD_PUSH    = 3'd6;
    localparam [2:0] CMD_POP     = 3'd7;

    localparam [3:0] OP_HALT    = 4'h0;
    localparam [3:0] OP_WAIT    = 4'h1;
    localparam [3:0] OP_SET     = 4'h2;
    localparam [3:0] OP_SHIFT   = 4'h3;
    localparam [3:0] OP_IN      = 4'h4;
    localparam [3:0] OP_OD      = 4'h5;
    localparam [3:0] OP_ODSHIFT = 4'h6;
    localparam [3:0] OP_HOLD    = 4'h7;
    localparam [3:0] OP_MATCH   = 4'h8;
    localparam [3:0] OP_JMP     = 4'h9;
    localparam [3:0] OP_XOR     = 4'hA;

    reg [15:0] imem [0:1][0:31];
    reg        active_bank;
    reg        switch_pend;
    reg [15:0] t_reg, tlo_reg, thi_reg;
    reg [7:0]  bind0, bind1, bind2, bind3, side_bind;
    reg        out_dir, in_dir, autopull, autopush;
    reg [3:0]  xreload;
    reg [3:0]  yreload;
    reg [1:0]  width_code;
    reg [4:0]  base_pin;
    reg [7:0]  tx_mem [0:3];
    reg [7:0]  rx_mem [0:3];
    reg [1:0]  tx_w, tx_r, rx_w, rx_r;
    reg [2:0]  tx_count, rx_count;
    reg [3:0]  shift_n, in_n;
    reg        osr_valid, stall_tx, rx_overrun, tx_overrun;
    // Temps for one clock's FIFO decision. Not state.
    reg        host_push_b, host_pop_b, eng_pop_b, eng_push_b;
    reg        rx_over_b, tx_over_b;
    reg [7:0]  eng_push_data_b;
    reg [7:0]  oshift, ishift;
    reg [4:0]  pc;
    reg [7:0]  waddr;
    reg        running;
    reg [15:0] wait_left;
    reg [3:0]  xcnt;
    reg [3:0]  ycnt;
    reg [7:0]  uo_q, uio_q, uio_oe_q;

    wire       wr   = ui[0];
    wire [2:0] cmd  = ui[3:1];
    wire [7:0] wdata = uio_in;

    // Driven by pin_io. Declared here so decode can form xor_level.
    wire        sampled;
    wire [7:0]  in_group;
    wire        lose_bit;
    wire [23:0] pins_set;
    wire [23:0] pins_shift;
    wire [23:0] pins_in;
    wire [23:0] pins_od;
    wire [23:0] pins_odshift;
    wire [23:0] pins_release;
    wire [23:0] pins_xor;
    wire [23:0] pins_idle;

    `include "pin_engine_decode.vh"

    pin_io pins (
        .cur          ({uo_q, uio_q, uio_oe_q}),
        .ui           (ui),
        .uio_in       (uio_in),
        .role_pin     (role_pin),
        .side_pin     (side_pin),
        .side_od      (side_od),
        .role_od      (role_od),
        .base_pin     (base_pin),
        .sh_width     (sh_width),
        .wide         (wide),
        .side         (side),
        .side_val     (side_val),
        .val          (val),
        .out_bit      (out_bit),
        .out_group    (out_group),
        .xor_level    (xor_level),
        .wdata        (wdata),
        .sampled      (sampled),
        .in_group     (in_group),
        .lose_bit     (lose_bit),
        .pins_set     (pins_set),
        .pins_shift   (pins_shift),
        .pins_in      (pins_in),
        .pins_od      (pins_od),
        .pins_odshift (pins_odshift),
        .pins_release (pins_release),
        .pins_xor     (pins_xor),
        .pins_idle    (pins_idle)
    );

    wire [7:0] in_group_rev = {in_group[0], in_group[1], in_group[2], in_group[3],
                               in_group[4], in_group[5], in_group[6], in_group[7]};
    wire [7:0] ishift_next =
        (sh_width == 4'd8) ? (in_dir ? in_group_rev : in_group) :
        (sh_width == 4'd4) ? (in_dir ? {ishift[3:0], in_group[3:0]} : {in_group[3:0], ishift[7:4]}) :
        (sh_width == 4'd2) ? (in_dir ? {ishift[5:0], in_group[1:0]} : {in_group[1:0], ishift[7:2]}) :
                             (in_dir ? {ishift[6:0], sampled} : {sampled, ishift[7:1]});

    integer i, b;

    assign uo      = {running, uo_q[6:0]};
    assign uio_out = show_ishift ? ishift :
                     show_pop    ? rx_head :
                     show_status ? status_byte :
                     uio_q;
    assign uio_oe  = (show_ishift | show_pop | show_status) ? 8'hFF : uio_oe_q;

    `include "pin_engine_tasks.vh"

    always @(posedge clk) begin
        if (!rst_n) begin
            t_reg     <= 16'd1;
            tlo_reg   <= 16'd1;
            thi_reg   <= 16'd1;
            bind0     <= 8'd0;
            bind1     <= 8'd0;
            bind2     <= 8'd0;
            bind3     <= 8'd0;
            side_bind <= 8'd0;
            out_dir   <= 1'b0;
            in_dir    <= 1'b0;
            autopull   <= 1'b0;
            autopush   <= 1'b0;
            xreload    <= 4'd0;
            yreload    <= 4'd0;
            width_code <= 2'd0;
            base_pin   <= 5'd0;
            oshift    <= 8'd0;
            ishift    <= 8'd0;
            pc          <= 5'd0;
            waddr       <= 8'd0;
            running     <= 1'b0;
            active_bank <= 1'b0;
            switch_pend <= 1'b0;
            wait_left <= 16'd0;
            xcnt      <= 4'd0;
            ycnt      <= 4'd0;
            tx_w      <= 2'd0;
            tx_r      <= 2'd0;
            rx_w      <= 2'd0;
            rx_r      <= 2'd0;
            tx_count  <= 3'd0;
            rx_count  <= 3'd0;
            shift_n   <= 4'd0;
            in_n      <= 4'd0;
            osr_valid <= 1'b0;
            stall_tx  <= 1'b0;
            rx_overrun <= 1'b0;
            tx_overrun <= 1'b0;
            // Bit 0 high is UART idle before a binding is loaded.
            uo_q      <= 8'h01;
            uio_q     <= 8'h00;
            uio_oe_q  <= 8'h00;
            for (b = 0; b < 2; b = b + 1)
                for (i = 0; i < 32; i = i + 1)
                    imem[b][i] <= 16'h0000;
        end else begin
            host_push_b     = wr && (cmd == CMD_PUSH);
            host_pop_b      = wr && (cmd == CMD_POP);
            eng_pop_b       = 1'b0;
            eng_push_b      = 1'b0;
            eng_push_data_b = 8'h00;
            rx_over_b       = 1'b0;
            tx_over_b       = 1'b0;

            // The running program is the active bank. Fills land in the
            // other one. 0x4D bit 0 requests the handoff; it does not
            // change pins or the live config.
            if (running && wr) begin
                case (cmd)
                    CMD_ADDR: waddr <= wdata;
                    CMD_WRITE: begin
                        if (waddr < 8'h40) begin
                            if (waddr[0])
                                imem[~active_bank][waddr[5:1]][15:8] <= wdata;
                            else
                                imem[~active_bank][waddr[5:1]][7:0]  <= wdata;
                        end else if (waddr == 8'h4D) begin
                            switch_pend <= wdata[0];
                            yreload     <= wdata[4:1];
                        end
                        waddr <= waddr + 8'd1;
                    end
                    default: ;
                endcase
            end

            if (!running) begin
                if (wr) begin
                    `include "pin_engine_config.vh"
                end
            end else if (wait_left != 16'd0) begin
                wait_left <= wait_left - 16'd1;
            end else if (stall_tx) begin
                if (tx_count != 3'd0) begin
                    oshift    <= tx_mem[tx_r];
                    osr_valid <= 1'b1;
                    shift_n   <= 4'd0;
                    stall_tx  <= 1'b0;
                    eng_pop_b  = 1'b1;
                end else if (host_push_b) begin
                    oshift      <= wdata;
                    host_push_b  = 1'b0;
                    osr_valid   <= 1'b1;
                    shift_n     <= 4'd0;
                    stall_tx    <= 1'b0;
                end
            end else if (autopull && !osr_valid &&
                         ((op == OP_SHIFT) || (op == OP_ODSHIFT))) begin
                stall_tx <= 1'b1;
            end else begin
                `include "pin_engine_ops.vh"
            end

            if (eng_pop_b && (tx_count != 3'd0) && host_push_b) begin
                tx_mem[tx_w] <= wdata;
                tx_w <= tx_w + 2'd1;
                tx_r <= tx_r + 2'd1;
            end else if (eng_pop_b && (tx_count != 3'd0)) begin
                tx_r     <= tx_r + 2'd1;
                tx_count <= tx_count - 3'd1;
            end else if (host_push_b && (tx_count < 3'd4)) begin
                tx_mem[tx_w] <= wdata;
                tx_w     <= tx_w + 2'd1;
                tx_count <= tx_count + 3'd1;
            end else if (host_push_b)
                tx_over_b = 1'b1;

            if (eng_push_b && host_pop_b && (rx_count != 3'd0)) begin
                rx_mem[rx_w] <= eng_push_data_b;
                rx_w <= rx_w + 2'd1;
                rx_r <= rx_r + 2'd1;
            end else if (eng_push_b) begin
                rx_mem[rx_w] <= eng_push_data_b;
                rx_w     <= rx_w + 2'd1;
                rx_count <= rx_count + 3'd1;
            end else if (host_pop_b && (rx_count != 3'd0)) begin
                rx_r     <= rx_r + 2'd1;
                rx_count <= rx_count - 3'd1;
            end

            // A status read clears a sticky overrun unless this clock
            // produced a new one. The byte the host samples is the old flag.
            if (running && wr && (cmd == CMD_READ)) begin
                rx_overrun <= rx_over_b;
                tx_overrun <= tx_over_b;
            end else begin
                if (rx_over_b)
                    rx_overrun <= 1'b1;
                if (tx_over_b)
                    tx_overrun <= 1'b1;
            end
        end
    end

endmodule

`default_nettype wire

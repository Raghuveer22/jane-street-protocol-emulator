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

    wire [15:0] insn     = imem[active_bank][pc];
    wire [3:0]  op       = insn[15:12];
    wire [1:0]  role     = insn[11:10];
    wire        val      = insn[9];
    wire        side     = insn[8];
    wire        side_val = insn[7];
    wire [2:0]  hold     = insn[6:4];
    wire        xdec     = insn[3];
    wire [1:0]  back     = insn[2:1];
    wire        setx     = insn[0];
    // JMP packs the condition into bits [9:7].
    wire [2:0]  jmp_cond = {val, side, side_val};

    wire [7:0] role_b =
        (role == 2'd0) ? bind0 :
        (role == 2'd1) ? bind1 :
        (role == 2'd2) ? bind2 : bind3;
    wire [4:0] role_pin = role_b[4:0];
    wire [4:0] side_pin = side_bind[4:0];
    wire       side_od  = (side_bind[7:6] == 2'd2);
    wire       role_od  = (role_b[7:6] == 2'd2);

    wire [3:0] x_set  = setx ? xreload : xcnt;
    wire [3:0] x_next = xdec ? (x_set - 4'd1) : x_set;
    wire       take_back = xdec && (x_next != 4'd0);
    wire [4:0] pc_next = take_back ? (pc - {3'b0, back}) : (pc + 5'd1);
    // More payload for JMP: a bit still in the output shift, or a TX byte queued.
    wire       more_payload = osr_valid || (tx_count != 3'd0);
    wire       jmp_taken =
        (jmp_cond == 3'd0) ? 1'b1 :
        (jmp_cond == 3'd1) ? (ycnt != 4'd0) :
        (jmp_cond == 3'd2) ? (ycnt == 4'd0) :
        (jmp_cond == 3'd3) ? more_payload : 1'b0;
    wire [4:0] jmp_pc =
        jmp_taken ? ((back != 2'd0) ? (pc - {3'b0, back}) : (pc + 5'd2))
                  : (pc + 5'd1);
    // One-bit next shift for OP_XOR. Independent of width_code.
    wire [7:0] oshift_next1 = out_dir ? {oshift[6:0], 1'b0} : {1'b0, oshift[7:1]};
    wire       xor_level = val ? ~sampled : (sampled ^ ~out_bit);

    // 00 is one bit, 01 is two, 10 is four, 11 is eight. One bit uses the role pin.
    wire [3:0] sh_width =
        (width_code == 2'd1) ? 4'd2 :
        (width_code == 2'd2) ? 4'd4 :
        (width_code == 2'd3) ? 4'd8 : 4'd1;
    wire       wide = (sh_width != 4'd1);
    wire       out_bit = out_dir ? oshift[7] : oshift[0];
    // Low bit of the group is base+0. MSB-first puts the high bit on that pin.
    // Width 8 is the whole byte: pin base+n carries oshift[n], or oshift[7-n].
    wire [7:0] out_group =
        (sh_width == 4'd8) ? (out_dir ? {oshift[0], oshift[1], oshift[2], oshift[3],
                                         oshift[4], oshift[5], oshift[6], oshift[7]}
                                      : oshift) :
        (sh_width == 4'd4) ? {4'b0, out_dir ? oshift[7:4] : oshift[3:0]} :
        (sh_width == 4'd2) ? {6'b0, out_dir ? oshift[7:6] : oshift[1:0]} :
                             {7'b0, out_bit};
    wire [7:0] oshift_next =
        (sh_width == 4'd8) ? 8'h00 :
        (sh_width == 4'd4) ? (out_dir ? {oshift[3:0], 4'b0} : {4'b0, oshift[7:4]}) :
        (sh_width == 4'd2) ? (out_dir ? {oshift[5:0], 2'b0} : {2'b0, oshift[7:2]}) :
                             (out_dir ? {oshift[6:0], 1'b0} : {1'b0, oshift[7:1]});
    wire       show_ishift = ~running & wr & (cmd == CMD_READ);
    wire       show_pop    = wr & (cmd == CMD_POP);
    wire       show_status = running & wr & (cmd == CMD_READ);
    wire [7:0] status_byte = {
        tx_count == 3'd4,
        tx_count == 3'd0,
        rx_count == 3'd4,
        rx_count == 3'd0,
        stall_tx,
        rx_overrun,
        tx_overrun,
        ~osr_valid
    };
    wire [7:0] rx_head = (rx_count != 3'd0) ? rx_mem[rx_r] : 8'h00;

    integer i, b;

    assign uo      = {running, uo_q[6:0]};
    assign uio_out = show_ishift ? ishift :
                     show_pop    ? rx_head :
                     show_status ? status_byte :
                     uio_q;
    assign uio_oe  = (show_ishift | show_pop | show_status) ? 8'hFF : uio_oe_q;

    function [7:0] set_bit;
        input [7:0] vec;
        input [2:0] idx;
        input       bitval;
        integer k;
        begin
            for (k = 0; k < 8; k = k + 1)
                if (k[2:0] == idx)
                    set_bit[k] = bitval;
                else
                    set_bit[k] = vec[k];
        end
    endfunction

    // cur is {uo, uio, oe}. od=1 is pull/release. od=0 is push-pull.
    function [23:0] drive;
        input [23:0] cur;
        input [4:0]  pin;
        input        od;
        input        bitval;
        reg [7:0] nuo, nuio, noe;
        reg [2:0] idx;
        begin
            nuo  = cur[23:16];
            nuio = cur[15:8];
            noe  = cur[7:0];
            if (pin >= 5'd8 && pin <= 5'd14) begin
                idx = pin[2:0];
                nuo = set_bit(nuo, idx, bitval);
            end else if (pin >= 5'd16 && pin <= 5'd23) begin
                idx = pin[2:0];
                if (od) begin
                    noe  = set_bit(noe, idx, ~bitval);
                    nuio = set_bit(nuio, idx, 1'b0);
                end else begin
                    noe  = set_bit(noe, idx, 1'b1);
                    nuio = set_bit(nuio, idx, bitval);
                end
            end
            drive = {nuo, nuio, noe};
        end
    endfunction

    function [23:0] drive_pair;
        input [23:0] cur;
        input        wr_role;
        input        wr_side;
        input        role_od;
        input [4:0]  rpin;
        input [4:0]  spin;
        input        rval;
        input        sval;
        reg [23:0] p;
        begin
            p = cur;
            if (wr_role)
                p = drive(p, rpin, role_od, rval);
            if (wr_side)
                p = drive(p, spin, side_od, sval);
            drive_pair = p;
        end
    endfunction

    function same_port;
        input [4:0] a;
        input [4:0] b;
        reg [1:0] pa, pb;
        begin
            pa = (a <= 5'd7) ? 2'd0 :
                 (a <= 5'd14) ? 2'd1 :
                 ((a >= 5'd16) && (a <= 5'd23)) ? 2'd2 : 2'd3;
            pb = (b <= 5'd7) ? 2'd0 :
                 (b <= 5'd14) ? 2'd1 :
                 ((b >= 5'd16) && (b <= 5'd23)) ? 2'd2 : 2'd3;
            same_port = (pa != 2'd3) && (pa == pb);
        end
    endfunction

    // Width 2, 4, or 8. base+0 is the low bit of the group. Side is applied
    // after, so a clock on the same tick wins if it overlaps a data pin.
    function [23:0] drive_bus;
        input [23:0] cur;
        input        wr_data;
        input        od;
        input [7:0]  bits;
        input        wr_side;
        input        sval;
        integer n;
        reg [23:0] p;
        reg [4:0] pin;
        begin
            p = cur;
            if (wr_data)
                for (n = 0; n < 8; n = n + 1)
                    if (n < sh_width) begin
                        pin = base_pin + n[4:0];
                        if (same_port(base_pin, pin))
                            p = drive(p, pin, od, bits[n]);
                    end
            if (wr_side)
                p = drive(p, side_pin, side_od, sval);
            drive_bus = p;
        end
    endfunction

    function level_of;
        input [4:0] pin;
        input [7:0] ui_i, uo_i, uio_i, uioe_i, uioin_i;
        begin
            if (pin < 5'd8)
                level_of = ui_i[pin[2:0]];
            else if (pin < 5'd16)
                level_of = uo_i[pin[2:0]];
            else
                level_of = uioe_i[pin[2:0]] ? uio_i[pin[2:0]] : uioin_i[pin[2:0]];
        end
    endfunction

    function [23:0] apply_idle;
        input [23:0] cur;
        input [7:0]  bcfg;
        reg [1:0] mode;
        reg       idle;
        reg [4:0] pin;
        reg [7:0] noe;
        begin
            mode = bcfg[7:6];
            idle = bcfg[5];
            pin  = bcfg[4:0];
            if (mode == 2'd0) begin
                apply_idle = cur;
                if (pin >= 5'd16 && pin <= 5'd23) begin
                    noe = set_bit(cur[7:0], pin[2:0], 1'b0);
                    apply_idle[7:0] = noe;
                end
            end else if (mode == 2'd2)
                apply_idle = drive(cur, pin, 1'b1, idle);
            else if (mode == 2'd1)
                apply_idle = drive(cur, pin, 1'b0, idle);
            else
                apply_idle = cur;
        end
    endfunction

    // A function call in a continuous assign is not re-evaluated by Icarus
    // when the pins change, so the sample is a mux.
    wire sampled =
        (role_pin < 5'd8)  ? ui[role_pin[2:0]] :
        (role_pin < 5'd16) ? uo_q[role_pin[2:0]] :
        uio_oe_q[role_pin[2:0]] ? uio_q[role_pin[2:0]] : uio_in[role_pin[2:0]];
    // Arguments are passed in so a change on ui/uio retriggers this block.
    reg [7:0] in_group;
    always @(*) begin
        in_group[0] = same_port(base_pin, base_pin)
            ? level_of(base_pin, ui, uo_q, uio_q, uio_oe_q, uio_in) : 1'b0;
        in_group[1] = same_port(base_pin, base_pin + 5'd1)
            ? level_of(base_pin + 5'd1, ui, uo_q, uio_q, uio_oe_q, uio_in) : 1'b0;
        in_group[2] = same_port(base_pin, base_pin + 5'd2)
            ? level_of(base_pin + 5'd2, ui, uo_q, uio_q, uio_oe_q, uio_in) : 1'b0;
        in_group[3] = same_port(base_pin, base_pin + 5'd3)
            ? level_of(base_pin + 5'd3, ui, uo_q, uio_q, uio_oe_q, uio_in) : 1'b0;
        in_group[4] = same_port(base_pin, base_pin + 5'd4)
            ? level_of(base_pin + 5'd4, ui, uo_q, uio_q, uio_oe_q, uio_in) : 1'b0;
        in_group[5] = same_port(base_pin, base_pin + 5'd5)
            ? level_of(base_pin + 5'd5, ui, uo_q, uio_q, uio_oe_q, uio_in) : 1'b0;
        in_group[6] = same_port(base_pin, base_pin + 5'd6)
            ? level_of(base_pin + 5'd6, ui, uo_q, uio_q, uio_oe_q, uio_in) : 1'b0;
        in_group[7] = same_port(base_pin, base_pin + 5'd7)
            ? level_of(base_pin + 5'd7, ui, uo_q, uio_q, uio_oe_q, uio_in) : 1'b0;
    end
    wire [7:0] in_group_rev = {in_group[0], in_group[1], in_group[2], in_group[3],
                               in_group[4], in_group[5], in_group[6], in_group[7]};
    wire [7:0] ishift_next =
        (sh_width == 4'd8) ? (in_dir ? in_group_rev : in_group) :
        (sh_width == 4'd4) ? (in_dir ? {ishift[3:0], in_group[3:0]} : {in_group[3:0], ishift[7:4]}) :
        (sh_width == 4'd2) ? (in_dir ? {ishift[5:0], in_group[1:0]} : {in_group[1:0], ishift[7:2]}) :
                             (in_dir ? {ishift[6:0], sampled} : {sampled, ishift[7:1]});
    // Open-drain arbitration. A 0 we drive wins. A 1 we drive loses when
    // the other chip is pulling. The compare uses this tick's bit, not the
    // pin register, which still holds the previous bit.
    wire       ext_bit =
        (role_pin >= 5'd16 && role_pin <= 5'd23) ? uio_in[role_pin[2:0]] :
        (role_pin < 5'd8) ? ui[role_pin[2:0]] : 1'b0;
    wire       bus_bit  = out_bit ? ext_bit : 1'b0;
    wire       lose_bit = val && role_od && !wide && (bus_bit != out_bit);

    function [15:0] hold_ticks;
        input [2:0] h;
        reg [15:0] n;
        begin
            case (h)
                3'd0: n = t_reg;
                3'd1: n = {1'b0, t_reg[15:1]};
                3'd2: n = tlo_reg;
                3'd3: n = thi_reg;
                default: n = 16'd1;
            endcase
            hold_ticks = (n == 16'd0) ? 16'd1 : n;
        end
    endfunction

    task commit_pins;
        input [23:0] pins;
        begin
            uo_q     <= pins[23:16];
            uio_q    <= pins[15:8];
            uio_oe_q <= pins[7:0];
        end
    endtask

    task retire;
        input [2:0] hold_code;
        begin
            xcnt      <= x_next;
            // Word 31 stepping forward is the end of this bank. A backward
            // branch stays here, so a loop does not hand off.
            if (switch_pend && !take_back && (pc == 5'd31)) begin
                active_bank <= ~active_bank;
                pc          <= 5'd0;
                switch_pend <= 1'b0;
            end else
                pc <= pc_next;
            wait_left <= hold_ticks(hold_code) - 16'd1;
            // A backward branch is the frame seam. Stall there, after this
            // instruction's pins and hold are committed, if the next byte
            // never arrived. UART's stop bit is that branch: the line sits
            // at idle instead of emitting another start.
            if (autopull && take_back && !osr_valid)
                stall_tx <= 1'b1;
        end
    endtask

    // JMP and XOR name their own next pc. X is left alone.
    task retire_to;
        input [2:0] hold_code;
        input [4:0] next_pc;
        begin
            if (switch_pend && (next_pc == (pc + 5'd1)) && (pc == 5'd31)) begin
                active_bank <= ~active_bank;
                pc          <= 5'd0;
                switch_pend <= 1'b0;
            end else
                pc <= next_pc;
            wait_left <= hold_ticks(hold_code) - 16'd1;
        end
    endtask

    // The shift that finishes the current byte. The pins already took
    // this step's bits. A queued byte replaces the register on this clock.
    task take_out_bit;
        begin
            if (autopull && (({1'b0, shift_n} + {1'b0, sh_width}) >= 5'd8)) begin
                if (tx_count != 3'd0) begin
                    oshift    <= tx_mem[tx_r];
                    eng_pop_b  = 1'b1;
                    shift_n   <= 4'd0;
                    osr_valid <= 1'b1;
                end else if (host_push_b) begin
                    oshift       <= wdata;
                    host_push_b   = 1'b0;
                    shift_n      <= 4'd0;
                    osr_valid    <= 1'b1;
                end else begin
                    oshift    <= oshift_next;
                    shift_n   <= 4'd8;
                    osr_valid <= 1'b0;
                    if (take_back)
                        stall_tx <= 1'b1;
                end
            end else begin
                oshift <= oshift_next;
                if (autopull)
                    shift_n <= shift_n + sh_width[3:0];
            end
        end
    endtask

    // OP_XOR always moves one bit. An empty TX FIFO clears osr_valid and
    // does not stall: JMP cond=more falls through to the trailer.
    task take_one_bit;
        begin
            if (autopull && (shift_n >= 4'd7)) begin
                if (tx_count != 3'd0) begin
                    oshift    <= tx_mem[tx_r];
                    eng_pop_b  = 1'b1;
                    shift_n   <= 4'd0;
                    osr_valid <= 1'b1;
                end else if (host_push_b) begin
                    oshift       <= wdata;
                    host_push_b   = 1'b0;
                    shift_n      <= 4'd0;
                    osr_valid    <= 1'b1;
                end else begin
                    oshift    <= oshift_next1;
                    shift_n   <= 4'd8;
                    osr_valid <= 1'b0;
                end
            end else begin
                oshift <= oshift_next1;
                if (autopull)
                    shift_n <= shift_n + 4'd1;
            end
        end
    endtask

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
                    case (cmd)
                        CMD_ADDR: waddr <= wdata;
                        CMD_WRITE: begin
                            if (waddr < 8'h40) begin
                                if (waddr[0])
                                    imem[active_bank][waddr[5:1]][15:8] <= wdata;
                                else
                                    imem[active_bank][waddr[5:1]][7:0]  <= wdata;
                            end else begin
                                case (waddr)
                                    8'h40: t_reg[7:0]   <= wdata;
                                    8'h41: t_reg[15:8]  <= wdata;
                                    8'h42: tlo_reg[7:0]  <= wdata;
                                    8'h43: tlo_reg[15:8] <= wdata;
                                    8'h44: thi_reg[7:0]  <= wdata;
                                    8'h45: thi_reg[15:8] <= wdata;
                                    8'h46: begin
                                        bind0 <= wdata;
                                        commit_pins(apply_idle({uo_q, uio_q, uio_oe_q}, wdata));
                                    end
                                    8'h47: begin
                                        bind1 <= wdata;
                                        commit_pins(apply_idle({uo_q, uio_q, uio_oe_q}, wdata));
                                    end
                                    8'h48: begin
                                        bind2 <= wdata;
                                        commit_pins(apply_idle({uo_q, uio_q, uio_oe_q}, wdata));
                                    end
                                    8'h49: begin
                                        bind3 <= wdata;
                                        commit_pins(apply_idle({uo_q, uio_q, uio_oe_q}, wdata));
                                    end
                                    8'h4A: begin
                                        side_bind <= wdata;
                                        commit_pins(apply_idle({uo_q, uio_q, uio_oe_q}, wdata));
                                    end
                                    8'h4B: begin
                                        out_dir  <= wdata[7];
                                        in_dir   <= wdata[6];
                                        autopull <= wdata[5];
                                        autopush <= wdata[4];
                                        xreload  <= wdata[3:0];
                                    end
                                    8'h4C: begin
                                        width_code <= wdata[6:5];
                                        base_pin   <= wdata[4:0];
                                    end
                                    8'h4D: begin
                                        switch_pend <= wdata[0];
                                        yreload     <= wdata[4:1];
                                    end
                                    default: ;
                                endcase
                            end
                            waddr <= waddr + 8'd1;
                        end
                        CMD_PAYLOAD: begin
                            oshift    <= wdata;
                            osr_valid <= 1'b1;
                            shift_n   <= 4'd0;
                        end
                        CMD_PC: pc <= wdata[4:0];
                        CMD_RUN: begin
                            running   <= 1'b1;
                            wait_left <= 16'd0;
                            ishift    <= 8'd0;
                            in_n      <= 4'd0;
                            ycnt      <= yreload;
                            if (autopull && !osr_valid && (tx_count != 3'd0)) begin
                                oshift    <= tx_mem[tx_r];
                                osr_valid <= 1'b1;
                                shift_n   <= 4'd0;
                                stall_tx  <= 1'b0;
                                eng_pop_b  = 1'b1;
                            end else if (autopull && !osr_valid)
                                stall_tx <= 1'b1;
                            else
                                stall_tx <= 1'b0;
                        end
                        default: ;
                    endcase
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
                case (op)
                    OP_HALT: begin
                        if (switch_pend) begin
                            active_bank <= ~active_bank;
                            pc          <= 5'd0;
                            switch_pend <= 1'b0;
                        end else begin
                            running  <= 1'b0;
                            stall_tx <= 1'b0;
                        end
                    end
                    OP_WAIT: begin
                        if (sampled == val)
                            retire(hold);
                    end
                    OP_SET: begin
                        commit_pins(drive_pair(
                            {uo_q, uio_q, uio_oe_q},
                            1'b1, side, 1'b0, role_pin, side_pin, val, side_val
                        ));
                        retire(hold);
                    end
                    OP_SHIFT: begin
                        if (wide)
                            commit_pins(drive_bus(
                                {uo_q, uio_q, uio_oe_q},
                                1'b1, 1'b0, out_group, side, side_val
                            ));
                        else
                            commit_pins(drive_pair(
                                {uo_q, uio_q, uio_oe_q},
                                1'b1, side, 1'b0, role_pin, side_pin, out_bit, side_val
                            ));
                        take_out_bit();
                        retire(hold);
                    end
                    OP_IN: begin
                        if (wide)
                            commit_pins(drive_bus(
                                {uo_q, uio_q, uio_oe_q},
                                1'b0, 1'b0, 8'b0, side, side_val
                            ));
                        else
                            commit_pins(drive_pair(
                                {uo_q, uio_q, uio_oe_q},
                                1'b0, side, 1'b0, role_pin, side_pin, 1'b0, side_val
                            ));
                        ishift <= ishift_next;
                        if (autopush && (({1'b0, in_n} + {1'b0, sh_width}) >= 5'd8)) begin
                            if ((rx_count < 3'd4) || (host_pop_b && (rx_count != 3'd0))) begin
                                eng_push_b       = 1'b1;
                                eng_push_data_b  = ishift_next;
                            end else
                                rx_over_b = 1'b1;
                            in_n <= 4'd0;
                        end else if (autopush)
                            in_n <= in_n + sh_width[3:0];
                        retire(hold);
                    end
                    OP_OD: begin
                        commit_pins(drive_pair(
                            {uo_q, uio_q, uio_oe_q},
                            1'b1, side, 1'b1, role_pin, side_pin, val, side_val
                        ));
                        retire(hold);
                    end
                    OP_ODSHIFT: begin
                        if (lose_bit) begin
                            commit_pins(drive_pair(
                                {uo_q, uio_q, uio_oe_q},
                                1'b1, 1'b0, 1'b1, role_pin, side_pin, 1'b1, 1'b0
                            ));
                            running  <= 1'b0;
                            stall_tx <= 1'b0;
                        end else begin
                            if (wide)
                                commit_pins(drive_bus(
                                    {uo_q, uio_q, uio_oe_q},
                                    1'b1, 1'b1, out_group, side, side_val
                                ));
                            else
                                commit_pins(drive_pair(
                                    {uo_q, uio_q, uio_oe_q},
                                    1'b1, side, 1'b1, role_pin, side_pin, out_bit, side_val
                                ));
                            take_out_bit();
                            retire(hold);
                        end
                    end
                    OP_MATCH: begin
                        ishift <= ishift_next;
                        if (sampled == val)
                            retire(hold);
                        else begin
                            if (role_od)
                                commit_pins(drive_pair(
                                    {uo_q, uio_q, uio_oe_q},
                                    1'b1, 1'b0, 1'b1, role_pin, side_pin, 1'b1, 1'b0
                                ));
                            running  <= 1'b0;
                            stall_tx <= 1'b0;
                        end
                    end
                    OP_HOLD: retire(hold);
                    OP_JMP: retire_to(hold, jmp_pc);
                    OP_XOR: begin
                        commit_pins(drive_pair(
                            {uo_q, uio_q, uio_oe_q},
                            1'b1, side, 1'b0, role_pin, side_pin,
                            xor_level, ~xor_level
                        ));
                        if (!val) begin
                            take_one_bit();
                            if (setx)
                                ycnt <= yreload;
                            else if (xdec) begin
                                if (out_bit)
                                    ycnt <= (ycnt == 4'd0) ? 4'd0 : (ycnt - 4'd1);
                                else
                                    ycnt <= yreload;
                            end
                        end else if (setx)
                            ycnt <= yreload;
                        retire_to(hold, pc + 5'd1);
                    end
                    default: begin
                        if (switch_pend && (pc == 5'd31)) begin
                            active_bank <= ~active_bank;
                            pc          <= 5'd0;
                            switch_pend <= 1'b0;
                        end else
                            pc <= pc + 5'd1;
                    end
                endcase
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

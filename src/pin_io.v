/*
 * SPDX-License-Identifier: CERN-OHL-S-2.0
 * SPDX-FileCopyrightText: 2026 Posa Mokshith
 *
 * Copyright Posa Mokshith 2026.
 *
 * This source describes Open Hardware and is licensed under the CERN-OHL-S v2
 * (https://ohwr.org/cern_ohl_s_v2.txt). Drive a pin and sample a pin for
 * pin_engine. Conveying a product built from this source requires the
 * complete source to be made public under CERN-OHL-S.
 *
 * This source is distributed WITHOUT ANY EXPRESS OR IMPLIED WARRANTY,
 * INCLUDING OF MERCHANTABILITY, SATISFACTORY QUALITY AND FITNESS FOR A
 * PARTICULAR PURPOSE. Please see the CERN-OHL-S v2 for applicable
 * conditions.
 *
 * Source Location: https://github.com/Raghuveer22/jane-street-protocol-emulator
 *
 * Combinational pin drive and sample. cur is {uo, uio, oe}. The next-pin
 * vectors are computed every tick; the engine chooses which one to commit.
 */

`timescale 1ns/1ps
`default_nettype none

module pin_io (
    input  wire [23:0] cur,
    input  wire [7:0]  ui,
    input  wire [7:0]  uio_in,
    input  wire [4:0]  role_pin,
    input  wire [4:0]  side_pin,
    input  wire        side_od,
    input  wire        role_od,
    input  wire [4:0]  base_pin,
    input  wire [3:0]  sh_width,
    input  wire        wide,
    input  wire        side,
    input  wire        side_val,
    input  wire        val,
    input  wire        out_bit,
    input  wire [7:0]  out_group,
    input  wire        xor_level,
    input  wire [7:0]  wdata,
    output wire        sampled,
    output wire [7:0]  in_group,
    output wire        lose_bit,
    output wire [23:0] pins_set,
    output wire [23:0] pins_shift,
    output wire [23:0] pins_in,
    output wire [23:0] pins_od,
    output wire [23:0] pins_odshift,
    output wire [23:0] pins_release,
    output wire [23:0] pins_xor,
    output wire [23:0] pins_idle
);

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
        input [23:0] cur_i;
        input [4:0]  pin;
        input        od;
        input        bitval;
        reg [7:0] nuo, nuio, noe;
        reg [2:0] idx;
        begin
            nuo  = cur_i[23:16];
            nuio = cur_i[15:8];
            noe  = cur_i[7:0];
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
        input [23:0] cur_i;
        input        wr_role;
        input        wr_side;
        input        role_od_i;
        input [4:0]  rpin;
        input [4:0]  spin;
        input        rval;
        input        sval;
        reg [23:0] p;
        begin
            p = cur_i;
            if (wr_role)
                p = drive(p, rpin, role_od_i, rval);
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
        input [23:0] cur_i;
        input        wr_data;
        input        od;
        input [7:0]  bits;
        input        wr_side;
        input        sval;
        integer n;
        reg [23:0] p;
        reg [4:0] pin;
        begin
            p = cur_i;
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
        input [23:0] cur_i;
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
                apply_idle = cur_i;
                if (pin >= 5'd16 && pin <= 5'd23) begin
                    noe = set_bit(cur_i[7:0], pin[2:0], 1'b0);
                    apply_idle[7:0] = noe;
                end
            end else if (mode == 2'd2)
                apply_idle = drive(cur_i, pin, 1'b1, idle);
            else if (mode == 2'd1)
                apply_idle = drive(cur_i, pin, 1'b0, idle);
            else
                apply_idle = cur_i;
        end
    endfunction

    wire [7:0] uo_i  = cur[23:16];
    wire [7:0] uio_i = cur[15:8];
    wire [7:0] oe_i  = cur[7:0];

    // A function call in a continuous assign is not re-evaluated by Icarus
    // when the pins change, so the sample is a mux.
    assign sampled =
        (role_pin < 5'd8)  ? ui[role_pin[2:0]] :
        (role_pin < 5'd16) ? uo_i[role_pin[2:0]] :
        oe_i[role_pin[2:0]] ? uio_i[role_pin[2:0]] : uio_in[role_pin[2:0]];

    // Arguments are passed in so a change on ui/uio retriggers this block.
    reg [7:0] in_group_r;
    always @(*) begin
        in_group_r[0] = same_port(base_pin, base_pin)
            ? level_of(base_pin, ui, uo_i, uio_i, oe_i, uio_in) : 1'b0;
        in_group_r[1] = same_port(base_pin, base_pin + 5'd1)
            ? level_of(base_pin + 5'd1, ui, uo_i, uio_i, oe_i, uio_in) : 1'b0;
        in_group_r[2] = same_port(base_pin, base_pin + 5'd2)
            ? level_of(base_pin + 5'd2, ui, uo_i, uio_i, oe_i, uio_in) : 1'b0;
        in_group_r[3] = same_port(base_pin, base_pin + 5'd3)
            ? level_of(base_pin + 5'd3, ui, uo_i, uio_i, oe_i, uio_in) : 1'b0;
        in_group_r[4] = same_port(base_pin, base_pin + 5'd4)
            ? level_of(base_pin + 5'd4, ui, uo_i, uio_i, oe_i, uio_in) : 1'b0;
        in_group_r[5] = same_port(base_pin, base_pin + 5'd5)
            ? level_of(base_pin + 5'd5, ui, uo_i, uio_i, oe_i, uio_in) : 1'b0;
        in_group_r[6] = same_port(base_pin, base_pin + 5'd6)
            ? level_of(base_pin + 5'd6, ui, uo_i, uio_i, oe_i, uio_in) : 1'b0;
        in_group_r[7] = same_port(base_pin, base_pin + 5'd7)
            ? level_of(base_pin + 5'd7, ui, uo_i, uio_i, oe_i, uio_in) : 1'b0;
    end
    assign in_group = in_group_r;

    // Open-drain arbitration. A 0 we drive wins. A 1 we drive loses when
    // the other chip is pulling. The compare uses this tick's bit, not the
    // pin register, which still holds the previous bit.
    wire ext_bit =
        (role_pin >= 5'd16 && role_pin <= 5'd23) ? uio_in[role_pin[2:0]] :
        (role_pin < 5'd8) ? ui[role_pin[2:0]] : 1'b0;
    wire bus_bit = out_bit ? ext_bit : 1'b0;
    assign lose_bit = val && role_od && !wide && (bus_bit != out_bit);

    assign pins_set = drive_pair(
        cur, 1'b1, side, 1'b0, role_pin, side_pin, val, side_val
    );
    assign pins_shift = wide
        ? drive_bus(cur, 1'b1, 1'b0, out_group, side, side_val)
        : drive_pair(cur, 1'b1, side, 1'b0, role_pin, side_pin, out_bit, side_val);
    assign pins_in = wide
        ? drive_bus(cur, 1'b0, 1'b0, 8'b0, side, side_val)
        : drive_pair(cur, 1'b0, side, 1'b0, role_pin, side_pin, 1'b0, side_val);
    assign pins_od = drive_pair(
        cur, 1'b1, side, 1'b1, role_pin, side_pin, val, side_val
    );
    assign pins_odshift = wide
        ? drive_bus(cur, 1'b1, 1'b1, out_group, side, side_val)
        : drive_pair(cur, 1'b1, side, 1'b1, role_pin, side_pin, out_bit, side_val);
    assign pins_release = drive_pair(
        cur, 1'b1, 1'b0, 1'b1, role_pin, side_pin, 1'b1, 1'b0
    );
    assign pins_xor = drive_pair(
        cur, 1'b1, side, 1'b0, role_pin, side_pin, xor_level, ~xor_level
    );
    assign pins_idle = apply_idle(cur, wdata);

endmodule

`default_nettype wire

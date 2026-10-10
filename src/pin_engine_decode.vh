/*
 * SPDX-License-Identifier: CERN-OHL-S-2.0
 * SPDX-FileCopyrightText: 2026 Posa Mokshith
 *
 * Fields of the word at pc, the next shift, and the jump target.
 * Included by pin_engine.v under the CERN-OHL-S v2
 * (https://ohwr.org/cern_ohl_s_v2.txt).
 *
 * Source Location: https://github.com/Raghuveer22/jane-street-protocol-emulator
 */

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

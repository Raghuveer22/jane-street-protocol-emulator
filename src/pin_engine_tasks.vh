/*
 * SPDX-License-Identifier: CERN-OHL-S-2.0
 * SPDX-FileCopyrightText: 2026 Posa Mokshith
 *
 * Commit the pin registers, retire the step, and consume payload bits.
 * Included by pin_engine.v under the CERN-OHL-S v2
 * (https://ohwr.org/cern_ohl_s_v2.txt).
 *
 * Source Location: https://github.com/Raghuveer22/jane-street-protocol-emulator
 */

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

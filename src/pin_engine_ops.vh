/*
 * SPDX-License-Identifier: CERN-OHL-S-2.0
 * SPDX-FileCopyrightText: 2026 Posa Mokshith
 *
 * Execute one instruction once the hold has expired and transmit is not stalled.
 * Included by pin_engine.v under the CERN-OHL-S v2
 * (https://ohwr.org/cern_ohl_s_v2.txt).
 *
 * Source Location: https://github.com/Raghuveer22/jane-street-protocol-emulator
 */

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
                        commit_pins(pins_set);
                        retire(hold);
                    end
                    OP_SHIFT: begin
                        commit_pins(pins_shift);
                        take_out_bit();
                        retire(hold);
                    end
                    OP_IN: begin
                        commit_pins(pins_in);
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
                        commit_pins(pins_od);
                        retire(hold);
                    end
                    OP_ODSHIFT: begin
                        if (lose_bit) begin
                            commit_pins(pins_release);
                            running  <= 1'b0;
                            stall_tx <= 1'b0;
                        end else begin
                            commit_pins(pins_odshift);
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
                                commit_pins(pins_release);
                            running  <= 1'b0;
                            stall_tx <= 1'b0;
                        end
                    end
                    OP_HOLD: retire(hold);
                    OP_JMP: retire_to(hold, jmp_pc);
                    OP_XOR: begin
                        commit_pins(pins_xor);
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

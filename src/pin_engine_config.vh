/*
 * SPDX-License-Identifier: CERN-OHL-S-2.0
 * SPDX-FileCopyrightText: 2026 Posa Mokshith
 *
 * Host writes while the engine is stopped.
 * Included by pin_engine.v under the CERN-OHL-S v2
 * (https://ohwr.org/cern_ohl_s_v2.txt).
 *
 * Source Location: https://github.com/Raghuveer22/jane-street-protocol-emulator
 */

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
                                        commit_pins(pins_idle);
                                    end
                                    8'h47: begin
                                        bind1 <= wdata;
                                        commit_pins(pins_idle);
                                    end
                                    8'h48: begin
                                        bind2 <= wdata;
                                        commit_pins(pins_idle);
                                    end
                                    8'h49: begin
                                        bind3 <= wdata;
                                        commit_pins(pins_idle);
                                    end
                                    8'h4A: begin
                                        side_bind <= wdata;
                                        commit_pins(pins_idle);
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

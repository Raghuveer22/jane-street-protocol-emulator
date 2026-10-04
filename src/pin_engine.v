/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Programmable pin engine. UART is a program loaded into imem, not a
 * fixed peripheral. Each SET or SHIFT holds the pin for `period` clocks.
 *
 *   0x00      HALT
 *   0x20/0x21 SET tx to 0 or 1, hold for `period` clocks
 *   0x30      SHIFT tx = shift[0], then shift right, hold for `period` clocks
 *
 * Host writes are ignored while a program is running. Execution of imem[pc]
 * begins on the clock after RUN is accepted. A period of 0 holds for 1 clock.
 */

`timescale 1ns/1ps
`default_nettype none

module pin_engine (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       wr,
    input  wire [2:0] cmd,
    input  wire [7:0] wdata,
    output wire       tx,
    output wire       busy
);

    localparam [2:0] CMD_PERIOD_LO = 3'd0;
    localparam [2:0] CMD_PERIOD_HI = 3'd1;
    localparam [2:0] CMD_SHIFT     = 3'd2;
    localparam [2:0] CMD_ADDR      = 3'd3;
    localparam [2:0] CMD_IMEM      = 3'd4;
    localparam [2:0] CMD_PC        = 3'd5;
    localparam [2:0] CMD_RUN       = 3'd6;

    localparam [3:0] OP_HALT  = 4'h0;
    localparam [3:0] OP_SET   = 4'h2;
    localparam [3:0] OP_SHIFT = 4'h3;

    reg [15:0] period;
    reg [7:0]  shift;
    reg [7:0]  imem [0:15];
    reg [3:0]  waddr;
    reg [3:0]  pc;
    reg        running;
    reg [15:0] wait_left;
    reg        tx_q;

    wire [15:0] ticks = (period == 16'd0) ? 16'd1 : period;
    wire [7:0]  insn  = imem[pc];

    integer i;

    assign tx   = tx_q;
    assign busy = running;

    always @(posedge clk) begin
        if (!rst_n) begin
            period    <= 16'd1;
            shift     <= 8'd0;
            waddr     <= 4'd0;
            pc        <= 4'd0;
            running   <= 1'b0;
            wait_left <= 16'd0;
            tx_q      <= 1'b1;
            for (i = 0; i < 16; i = i + 1)
                imem[i] <= 8'h00;
        end else if (!running) begin
            if (wr) begin
                case (cmd)
                    CMD_PERIOD_LO: period[7:0]  <= wdata;
                    CMD_PERIOD_HI: period[15:8] <= wdata;
                    CMD_SHIFT:     shift        <= wdata;
                    CMD_ADDR:      waddr        <= wdata[3:0];
                    CMD_IMEM: begin
                        imem[waddr] <= wdata;
                        waddr       <= waddr + 4'd1;
                    end
                    CMD_PC:  pc      <= wdata[3:0];
                    CMD_RUN: begin
                        running   <= 1'b1;
                        wait_left <= 16'd0;
                    end
                    default: ;
                endcase
            end
        end else if (wait_left != 16'd0) begin
            wait_left <= wait_left - 16'd1;
        end else begin
            case (insn[7:4])
                OP_HALT: running <= 1'b0;
                OP_SET: begin
                    tx_q      <= insn[0];
                    pc        <= pc + 4'd1;
                    wait_left <= ticks - 16'd1;
                end
                OP_SHIFT: begin
                    tx_q      <= shift[0];
                    shift     <= {1'b0, shift[7:1]};
                    pc        <= pc + 4'd1;
                    wait_left <= ticks - 16'd1;
                end
                default: pc <= pc + 4'd1;
            endcase
        end
    end

endmodule

`default_nettype wire

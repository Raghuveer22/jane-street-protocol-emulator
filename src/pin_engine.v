/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Programmable pin engine. UART, SPI, and I2C are programs in imem.
 * The 16-bit word, the load map, and those programs are documented in
 * docs/instruction_definition.html.
 *
 *   OP_HALT    0x0  running = 0. Pins stay.
 *   OP_WAIT    0x1  stall until role reads val
 *   OP_SET     0x2  drive role to val, push-pull
 *   OP_SHIFT   0x3  drive role to the next payload bit, push-pull
 *   OP_IN      0x4  sample role into the input shift
 *   OP_OD      0x5  pull or release role. val 0 pulls, val 1 releases
 *   OP_ODSHIFT 0x6  payload bit 0 pulls role, bit 1 releases it
 *   OP_HOLD    0x7  change no pin, only load the wait
 *
 * Config writes are ignored while a program is running. CMD_PUSH and
 * CMD_POP are not: they move one byte into the TX FIFO or out of the RX
 * FIFO on that clock, including during a hold. Autopull and autopush are
 * bits in the direction byte. Off, this is the one-byte machine.
 *
 * The instruction at pc runs on the clock after CMD_RUN. A hold length of
 * 0 is a hold of 1. uo[7] is `running`, so pin 15 is not a protocol pin.
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

    reg [15:0] imem [0:31];
    reg [15:0] t_reg, tlo_reg, thi_reg;
    reg [7:0]  bind0, bind1, bind2, bind3, side_bind;
    reg        out_dir, in_dir, autopull, autopush;
    reg [3:0]  xreload;
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
    reg [7:0]  uo_q, uio_q, uio_oe_q;

    wire       wr   = ui[0];
    wire [2:0] cmd  = ui[3:1];
    wire [7:0] wdata = uio_in;

    wire [15:0] insn     = imem[pc];
    wire [3:0]  op       = insn[15:12];
    wire [1:0]  role     = insn[11:10];
    wire        val      = insn[9];
    wire        side     = insn[8];
    wire        side_val = insn[7];
    wire [2:0]  hold     = insn[6:4];
    wire        xdec     = insn[3];
    wire [1:0]  back     = insn[2:1];
    wire        setx     = insn[0];

    wire [7:0] role_b =
        (role == 2'd0) ? bind0 :
        (role == 2'd1) ? bind1 :
        (role == 2'd2) ? bind2 : bind3;
    wire [4:0] role_pin = role_b[4:0];
    wire [4:0] side_pin = side_bind[4:0];
    wire       side_od  = (side_bind[7:6] == 2'd2);

    wire [3:0] x_set  = setx ? xreload : xcnt;
    wire [3:0] x_next = xdec ? (x_set - 4'd1) : x_set;
    wire       take_back = xdec && (x_next != 4'd0);
    wire [4:0] pc_next = take_back ? (pc - {3'b0, back}) : (pc + 5'd1);

    wire       out_bit = out_dir ? oshift[7] : oshift[0];
    wire [7:0] oshift_next = out_dir ? {oshift[6:0], 1'b0} : {1'b0, oshift[7:1]};
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

    integer i;

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
    wire [7:0] ishift_next = in_dir ? {ishift[6:0], sampled} : {sampled, ishift[7:1]};

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
            pc        <= pc_next;
            wait_left <= hold_ticks(hold_code) - 16'd1;
            // A backward branch is the frame seam. Stall there, after this
            // instruction's pins and hold are committed, if the next byte
            // never arrived. UART's stop bit is that branch: the line sits
            // at idle instead of emitting another start.
            if (autopull && take_back && !osr_valid)
                stall_tx <= 1'b1;
        end
    endtask

    // The 8th SHIFT/ODSHIFT of a byte. The pin already took `out_bit`.
    // A queued byte replaces the emptied register on this same clock.
    task take_out_bit;
        begin
            if (autopull && (shift_n == 4'd7)) begin
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
            autopull  <= 1'b0;
            autopush  <= 1'b0;
            xreload   <= 4'd0;
            oshift    <= 8'd0;
            ishift    <= 8'd0;
            pc        <= 5'd0;
            waddr     <= 8'd0;
            running   <= 1'b0;
            wait_left <= 16'd0;
            xcnt      <= 4'd0;
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
            for (i = 0; i < 32; i = i + 1)
                imem[i] <= 16'h0000;
        end else begin
            host_push_b     = wr && (cmd == CMD_PUSH);
            host_pop_b      = wr && (cmd == CMD_POP);
            eng_pop_b       = 1'b0;
            eng_push_b      = 1'b0;
            eng_push_data_b = 8'h00;
            rx_over_b       = 1'b0;
            tx_over_b       = 1'b0;

            if (!running) begin
                if (wr) begin
                    case (cmd)
                        CMD_ADDR: waddr <= wdata;
                        CMD_WRITE: begin
                            if (waddr < 8'h40) begin
                                if (waddr[0])
                                    imem[waddr[5:1]][15:8] <= wdata;
                                else
                                    imem[waddr[5:1]][7:0]  <= wdata;
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
                        running  <= 1'b0;
                        stall_tx <= 1'b0;
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
                        commit_pins(drive_pair(
                            {uo_q, uio_q, uio_oe_q},
                            1'b1, side, 1'b0, role_pin, side_pin, out_bit, side_val
                        ));
                        take_out_bit();
                        retire(hold);
                    end
                    OP_IN: begin
                        commit_pins(drive_pair(
                            {uo_q, uio_q, uio_oe_q},
                            1'b0, side, 1'b0, role_pin, side_pin, 1'b0, side_val
                        ));
                        ishift <= ishift_next;
                        if (autopush && (in_n == 4'd7)) begin
                            if ((rx_count < 3'd4) || (host_pop_b && (rx_count != 3'd0))) begin
                                eng_push_b       = 1'b1;
                                eng_push_data_b  = ishift_next;
                            end else
                                rx_over_b = 1'b1;
                            in_n <= 4'd0;
                        end else if (autopush)
                            in_n <= in_n + 4'd1;
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
                        commit_pins(drive_pair(
                            {uo_q, uio_q, uio_oe_q},
                            1'b1, side, 1'b1, role_pin, side_pin, out_bit, side_val
                        ));
                        take_out_bit();
                        retire(hold);
                    end
                    OP_HOLD: retire(hold);
                    default: pc <= pc + 5'd1;
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

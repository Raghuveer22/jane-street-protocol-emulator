`default_nettype none
`timescale 1ns / 1ps

/*
 * Self-checking bench for the UART 8N1 program on pin_engine.
 *
 * The programs live in prog/. This file loads the assembled words
 * through the Tiny Tapeout pins and checks tx/busy every clock.
 *
 * Sampling matches the engine: RUN's clock is still idle, and the first
 * instruction runs on the next clock. Each SET/SHIFT then holds for
 * `hold` clocks. A stored period of 0 is checked as a hold of 1.
 *
 * Run from test/:  make -f Makefile.uart
 */

module tb_uart;

  localparam [2:0] CMD_ADDR    = 3'd0;
  localparam [2:0] CMD_WRITE   = 3'd1;
  localparam [2:0] CMD_PAYLOAD = 3'd2;
  localparam [2:0] CMD_PC      = 3'd3;
  localparam [2:0] CMD_RUN     = 3'd4;

  // Role 0 = TX on uo[0], push-pull, idle 1. Bit 0 first, xreload = 8.
  localparam [7:0] TX_BIND = 8'h68;
  localparam [7:0] LSB8    = 8'h08;

  reg        clk;
  reg        rst_n;
  reg        ena;
  reg  [7:0] ui_in;
  reg  [7:0] uio_in;
  wire [7:0] uo_out;
  wire [7:0] uio_out;
  wire [7:0] uio_oe;

  wire tx   = uo_out[0];
  wire busy = uo_out[7];

  tt_um_posamokshith_proto dut (
      .ui_in  (ui_in),
      .uo_out (uo_out),
      .uio_in (uio_in),
      .uio_out(uio_out),
      .uio_oe (uio_oe),
      .ena    (ena),
      .clk    (clk),
      .rst_n  (rst_n)
  );

  reg [15:0] prog_shift [0:31];
  reg [15:0] prog_nop   [0:31];
  reg [15:0] prog_set   [0:31];

  integer cycle;
  integer passes;
  integer pc_val;
  integer poison_en;
  integer tail_n;
  integer shift_en;
  integer li;
  integer bi;
  integer si;
  integer k;
  reg exp;

  initial clk = 1'b0;
  always #10 clk = ~clk;

  always @(posedge clk) cycle = cycle + 1;

  initial begin
    if ($test$plusargs("dump")) begin
      $dumpfile("tb_uart.fst");
      $dumpvars(0, tb_uart);
    end
  end

  // 0xA5 on the wire is start, then 1 0 1 0 0 1 0 1, then stop.
  function exp_bit;
    input [7:0] data;
    input integer idx;
    begin
      if (idx == 0)
        exp_bit = 1'b0;
      else if (idx == 9)
        exp_bit = 1'b1;
      else
        exp_bit = data[idx - 1];
    end
  endfunction

  task write;
    input [2:0] cmd;
    input [7:0] data;
    begin
      @(posedge clk);
      #1;
      ui_in  = {4'b0, cmd, 1'b1};
      uio_in = data;
      @(posedge clk);
      #1;
      ui_in = 8'h00;
    end
  endtask

  task program_period;
    input integer period;
    begin
      write(CMD_ADDR, 8'h40);
      write(CMD_WRITE, period & 255);
      write(CMD_WRITE, (period >> 8) & 255);
    end
  endtask

  // which: 0 shift program, 1 nop program, 2 unrolled SETs.
  // Words are 16 bits, low byte then high byte. The UART binding is reloaded
  // with the program because reset clears it.
  task load_prog;
    input integer which;
    reg [15:0] word_i;
    begin
      write(CMD_ADDR, 8'h00);
      for (li = 0; li < 32; li = li + 1) begin
        if (which == 0)
          word_i = prog_shift[li];
        else if (which == 1)
          word_i = prog_nop[li];
        else
          word_i = prog_set[li];
        write(CMD_WRITE, word_i[7:0]);
        write(CMD_WRITE, word_i[15:8]);
      end
      write(CMD_ADDR, 8'h46);
      write(CMD_WRITE, TX_BIND);
      write(CMD_WRITE, 8'h00);
      write(CMD_WRITE, 8'h00);
      write(CMD_WRITE, 8'h00);
      write(CMD_WRITE, 8'h00);
      write(CMD_WRITE, LSB8);
    end
  endtask

  task check_pins;
    begin
      // uo[0] is TX. uo[7] is running. The other outputs stay low.
      if (uo_out[6:1] !== 6'b0 || uio_oe !== 8'h00 || uio_out !== 8'h00) begin
        $display("FAIL unused pins uo %02h uio_out %02h uio_oe %02h cycle %0d",
                 uo_out, uio_out, uio_oe, cycle);
        $finish(1);
      end
    end
  endtask

  // Host has already written PERIOD. This writes SHIFT and PC, runs, and
  // checks 10 bit-times of `hold` clocks, then `tail_n` single-clock
  // instructions (the NOP), then HALT, then four idle clocks at mark.
  task check_frame;
    input [7:0] data;
    input integer hold;
    begin
      if (hold < 1) begin
        $display("FAIL hold must be at least 1");
        $finish(1);
      end
      if (shift_en)
        write(CMD_PAYLOAD, data);
      write(CMD_PC, pc_val & 255);
      write(CMD_RUN, 8'h00);
      // This is the clock that accepted RUN. The pin is still idle.
      if (busy !== 1'b1 || tx !== 1'b1) begin
        $display("FAIL RUN clock busy %b tx %b (want 1, 1) cycle %0d", busy, tx, cycle);
        $finish(1);
      end
      check_pins;

      for (bi = 0; bi < 10; bi = bi + 1) begin
        exp = exp_bit(data, bi);
        for (si = 0; si < hold; si = si + 1) begin
          if (poison_en && bi == 0 && si == 1) begin
            ui_in  = {4'b0, CMD_PAYLOAD, 1'b1};
            uio_in = 8'hFF;
          end else if (poison_en && bi == 1 && si == 0) begin
            ui_in  = {4'b0, CMD_WRITE, 1'b1};
            uio_in = 8'h01;
          end else if (poison_en && bi == 2 && si == 0) begin
            ui_in  = {4'b0, CMD_PC, 1'b1};
            uio_in = 8'h00;
          end
          @(posedge clk);
          #1;
          ui_in = 8'h00;
          if (tx !== exp || busy !== 1'b1) begin
            $display("FAIL bit %0d sample %0d/%0d exp %b got tx %b busy %b cycle %0d",
                     bi, si, hold, exp, tx, busy, cycle);
            $finish(1);
          end
        end
      end

      for (k = 0; k < tail_n; k = k + 1) begin
        @(posedge clk);
        #1;
        if (tx !== 1'b1 || busy !== 1'b1) begin
          $display("FAIL tail %0d tx %b busy %b (want 1, 1) cycle %0d", k, tx, busy, cycle);
          $finish(1);
        end
      end

      @(posedge clk);
      #1;
      if (tx !== 1'b1 || busy !== 1'b0) begin
        $display("FAIL HALT tx %b busy %b (want 1, 0) cycle %0d", tx, busy, cycle);
        $finish(1);
      end
      check_pins;

      repeat (4) begin
        @(posedge clk);
        #1;
        if (tx !== 1'b1 || busy !== 1'b0) begin
          $display("FAIL idle mark tx %b busy %b cycle %0d", tx, busy, cycle);
          $finish(1);
        end
      end
      poison_en = 0;
      tail_n    = 0;
      pc_val    = 0;
      shift_en  = 1;
    end
  endtask

  task frame;
    input [7:0] data;
    input integer hold;
    begin
      pc_val    = 0;
      poison_en = 0;
      tail_n    = 0;
      shift_en  = 1;
      check_frame(data, hold);
    end
  endtask

  task pass;
    begin
      $display("  PASS");
      passes = passes + 1;
    end
  endtask

  initial begin
    cycle     = 0;
    passes    = 0;
    pc_val    = 0;
    poison_en = 0;
    tail_n    = 0;
    shift_en  = 1;
    ui_in     = 8'h00;
    uio_in    = 8'h00;
    ena       = 1'b1;
    rst_n     = 1'b0;

    for (li = 0; li < 32; li = li + 1) begin
      prog_shift[li] = 16'h0000;
      prog_nop[li]   = 16'h0000;
      prog_set[li]   = 16'h0000;
    end
    $readmemh("sim_build/uart_8n1.hex", prog_shift);
    $readmemh("sim_build/uart_8n1_nop.hex", prog_nop);
    $readmemh("sim_build/uart_a5_unrolled.hex", prog_set);
    if (prog_shift[0] !== 16'h2001 || prog_shift[1] !== 16'h3008 || prog_shift[3] !== 16'h0000) begin
      $display("FAIL sim_build/uart_8n1.hex did not load (run from test/)");
      $finish(1);
    end
    if (prog_nop[3] !== 16'h7050 || prog_nop[4] !== 16'h0000) begin
      $display("FAIL sim_build/uart_8n1_nop.hex did not load");
      $finish(1);
    end
    if (prog_set[0] !== 16'h2000 || prog_set[1] !== 16'h2200 || prog_set[10] !== 16'h0000) begin
      $display("FAIL sim_build/uart_a5_unrolled.hex did not load");
      $finish(1);
    end
    // Golden from docs/info.md: 0xA5 is start, 1 0 1 0 0 1 0 1, stop.
    if (exp_bit(8'hA5, 0) !== 1'b0 || exp_bit(8'hA5, 1) !== 1'b1 ||
        exp_bit(8'hA5, 2) !== 1'b0 || exp_bit(8'hA5, 3) !== 1'b1 ||
        exp_bit(8'hA5, 4) !== 1'b0 || exp_bit(8'hA5, 5) !== 1'b0 ||
        exp_bit(8'hA5, 6) !== 1'b1 || exp_bit(8'hA5, 7) !== 1'b0 ||
        exp_bit(8'hA5, 8) !== 1'b1 || exp_bit(8'hA5, 9) !== 1'b1) begin
      $display("FAIL checker does not match the 0xA5 waveform");
      $finish(1);
    end

    repeat (2) @(posedge clk);
    #1;
    rst_n = 1'b1;
    @(posedge clk);
    #1;

    $display("UART 8N1 pin_engine");

    $display("TEST reset idles high");
    if (tx !== 1'b1 || busy !== 1'b0) begin
      $display("FAIL tx %b busy %b", tx, busy);
      $finish(1);
    end
    check_pins;
    pass;

    $display("TEST empty imem halts, line stays idle");
    write(CMD_RUN, 8'h00);
    if (busy !== 1'b1 || tx !== 1'b1) begin
      $display("FAIL RUN clock busy %b tx %b", busy, tx);
      $finish(1);
    end
    @(posedge clk);
    #1;
    if (busy !== 1'b0 || tx !== 1'b1) begin
      $display("FAIL after HALT busy %b tx %b", busy, tx);
      $finish(1);
    end
    pass;

    load_prog(0);
    program_period(4);

    $display("TEST 0x00 period 4");
    frame(8'h00, 4);
    pass;
    $display("TEST 0xFF period 4");
    frame(8'hFF, 4);
    pass;
    $display("TEST 0x01 period 4");
    frame(8'h01, 4);
    pass;
    $display("TEST 0x80 period 4");
    frame(8'h80, 4);
    pass;
    $display("TEST 0x55 period 4");
    frame(8'h55, 4);
    pass;
    $display("TEST 0xAA period 4");
    frame(8'hAA, 4);
    pass;
    $display("TEST 0xA5 period 4");
    frame(8'hA5, 4);
    pass;

    $display("TEST second byte, imem not reloaded");
    frame(8'h00, 4);
    frame(8'hFF, 4);
    pass;

    $display("TEST RUN with pc left on HALT sends nothing");
    write(CMD_PAYLOAD, 8'hFF);
    write(CMD_RUN, 8'h00);
    if (busy !== 1'b1 || tx !== 1'b1) begin
      $display("FAIL RUN clock busy %b tx %b", busy, tx);
      $finish(1);
    end
    @(posedge clk);
    #1;
    if (busy !== 1'b0 || tx !== 1'b1) begin
      $display("FAIL expected immediate HALT busy %b tx %b", busy, tx);
      $finish(1);
    end
    pass;

    $display("TEST pc uses five bits, so 0x20 starts at 0");
    pc_val = 8'h20;
    check_frame(8'hA5, 4);
    pass;

    $display("TEST period 1");
    program_period(1);
    frame(8'h80, 1);
    pass;

    $display("TEST period 0 holds for 1 clock");
    program_period(0);
    frame(8'h01, 1);
    pass;

    $display("TEST period 2");
    program_period(2);
    frame(8'h55, 2);
    pass;

    $display("TEST period 255, low byte only");
    program_period(255);
    frame(8'hAA, 255);
    pass;

    $display("TEST period 256, high byte only");
    program_period(256);
    frame(8'h01, 256);
    pass;

    $display("TEST period 0x0102, both bytes");
    program_period(16'h0102);
    frame(8'hA5, 16'h0102);
    pass;

    $display("TEST high byte sticks, period 0x0104");
    write(CMD_ADDR, 8'h40);
    write(CMD_WRITE, 8'h04);
    frame(8'h01, 16'h0104);
    pass;

    $display("TEST writes ignored during 0xA5");
    program_period(4);
    poison_en = 1;
    check_frame(8'hA5, 4);
    pass;

    $display("TEST 115200 baud, period 434, 0xA5");
    program_period(434);
    frame(8'hA5, 434);
    pass;

    $display("TEST 9600 baud, period 5208, 0x00");
    program_period(5208);
    frame(8'h00, 5208);
    pass;

    $display("TEST period 65535, 0x01");
    program_period(65535);
    frame(8'h01, 65535);
    pass;

    $display("TEST NOP after stop is not an extra bit");
    load_prog(1);
    program_period(4);
    tail_n = 1;
    check_frame(8'hA5, 4);
    pass;

    $display("TEST SET-only program sends 0xA5");
    load_prog(2);
    program_period(4);
    write(CMD_PAYLOAD, 8'h00);
    // SHIFT stays 0x00. The 0xA5 waveform has to come from the SET instructions.
    shift_en = 0;
    check_frame(8'hA5, 4);
    pass;

    $display("TEST reset mid-frame returns to idle HALT");
    load_prog(0);
    program_period(4);
    write(CMD_PAYLOAD, 8'hA5);
    write(CMD_PC, 8'h00);
    write(CMD_RUN, 8'h00);
    @(posedge clk);
    #1;
    if (tx !== 1'b0 || busy !== 1'b1) begin
      $display("FAIL start bit tx %b busy %b", tx, busy);
      $finish(1);
    end
    rst_n = 1'b0;
    @(posedge clk);
    #1;
    if (tx !== 1'b1 || busy !== 1'b0) begin
      $display("FAIL during reset tx %b busy %b", tx, busy);
      $finish(1);
    end
    rst_n = 1'b1;
    @(posedge clk);
    #1;
    if (tx !== 1'b1 || busy !== 1'b0) begin
      $display("FAIL after reset tx %b busy %b", tx, busy);
      $finish(1);
    end
    write(CMD_RUN, 8'h00);
    @(posedge clk);
    #1;
    if (tx !== 1'b1 || busy !== 1'b0) begin
      $display("FAIL imem not cleared tx %b busy %b", tx, busy);
      $finish(1);
    end
    pass;

    $display("%0d tests passed, sim time %0t", passes, $time);
    $finish;
  end

  // 65535 * 10 bit-clocks is 13.1 ms. A stuck countdown is much longer.
  initial begin
    #100_000_000;
    $display("FAIL timeout");
    $finish(1);
  end

endmodule

`default_nettype wire

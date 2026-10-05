; UART 8N1 transmit. One program, every payload.
;
; The byte is not in this listing. The host writes it to SHIFT before RUN.
; PERIOD is the bit time in clocks. Baud is clock_hz / PERIOD.
; SHIFT emits bit 0 first. SET drives the start and stop levels and does
; not touch SHIFT.
;
;   idle   start  b0 b1 b2 b3 b4 b5 b6 b7  stop  idle
;     1      0    ........LSB first......    1     1
;
; The testbench (test/tb_uart.v) keeps this image in imem and varies the
; host registers. Those are the edge cases:
;
;   bytes     0x00 0xFF 0x01 0x80 0x55 0xAA 0xA5
;   period    0 (holds 1)  1  2  4  255  256  0x0102
;             0x0104 after rewriting only the low byte
;             434 (115200 at 50 MHz)  5208 (9600)  65535
;   control   empty imem, RUN clock still idle, busy through the stop bit,
;             mark after HALT, second byte without reloading imem,
;             RUN with pc left on HALT, pc 0x10, load address 0x10,
;             writes during the frame, reset during the start bit
;
; uart_8n1_nop.asm and uart_a5_unrolled.asm are the other two images.

SET 0       ; start bit
SHIFT       ; b0
SHIFT       ; b1
SHIFT       ; b2
SHIFT       ; b3
SHIFT       ; b4
SHIFT       ; b5
SHIFT       ; b6
SHIFT       ; b7
SET 1       ; stop bit
HALT

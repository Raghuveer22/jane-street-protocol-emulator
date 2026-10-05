; 0xA5 as pure SET instructions. SHIFT is unused.
; 0xA5 is 0b10100101, and bit 0 goes on the wire first: 1 0 1 0 0 1 0 1.
; The testbench leaves SHIFT at 0x00. A waveform of 0xA5 means the frame
; came from these instructions.

SET 0       ; start
SET 1       ; b0 = 1
SET 0       ; b1 = 0
SET 1       ; b2 = 1
SET 0       ; b3 = 0
SET 0       ; b4 = 0
SET 1       ; b5 = 1
SET 0       ; b6 = 0
SET 1       ; b7 = 1
SET 1       ; stop
HALT

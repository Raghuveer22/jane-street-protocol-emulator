; 0xA5 as pure SET instructions. SHIFT is unused.
; 0xA5 is 0b10100101, and bit 0 goes on the wire first: 1 0 1 0 0 1 0 1.
; The testbench leaves the payload at 0x00. A waveform of 0xA5 means the
; frame came from these instructions.

SET role=0 val=0 hold=T    ; start
SET role=0 val=1 hold=T    ; b0 = 1
SET role=0 val=0 hold=T    ; b1 = 0
SET role=0 val=1 hold=T    ; b2 = 1
SET role=0 val=0 hold=T    ; b3 = 0
SET role=0 val=0 hold=T    ; b4 = 0
SET role=0 val=1 hold=T    ; b5 = 1
SET role=0 val=0 hold=T    ; b6 = 0
SET role=0 val=1 hold=T    ; b7 = 1
SET role=0 val=1 hold=T    ; stop
HALT

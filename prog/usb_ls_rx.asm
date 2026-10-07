; Low-speed USB receive. Role 0 is D+, an input. D− is not sampled:
; the bit is the level on D+.
;
; CMD_RUN leaves the NRZI state at J. The K edge that opens sync is
; the first 0 of the sync byte 0x80. HOLD T/2 then lands in that bit.
; The edge tick is the WAIT, so the sample is one tick past T/2.
; T = 33 puts that sample 17 ticks into a 33-tick bit. T has to be
; at least 4 or the sample falls out of the bit.
;
; OP_NRZIN assembles one byte, LSB first. A repeated level is a 1
; and a change is a 0. The bit after six 1s is the stuffed 0 and is
; dropped. Byte 0x4B is autopush plus the number of bytes expected,
; sync included. The host checks the PID and the CRC.

WAIT role=0 val=1 hold=none                          ; K, the start of sync
HOLD hold=T/2 setx                                   ; into that bit; x = byte count
NRZIN role=0 hold=T xdec back=0                      ; one byte per visit
HALT

; USB low-speed receive. Sample NRZI until both pins read 0.
;
; Role 0 is D+, an input. The side pin is D-.
; The first instruction sees the sync edge. The half-bit hold lands
; the sample inside the bit. USB_IN drops the stuff bit after six 1s
; and falls through on SE0 without storing it.
; After halt, command 6 with the byte index on ui[7:4] reads rx_buf.

WAIT role=0 val=1 hold=none    ; D+ rises out of idle J
HOLD hold=T/2                  ; into the bit
USB_IN side hold=T             ; until SE0
HALT

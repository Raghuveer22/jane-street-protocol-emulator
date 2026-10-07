; UART 8N1 receive that keeps watching the line.
;
; Byte 0x4B bit 4 (autopush) must be 1. Every eighth sample is copied
; into the RX FIFO. CMD_POP takes it, including while this program is
; still running. The branch reaches back to the start wait: `back` only
; spans three instructions, so the start hold is WAIT's own hold.

WAIT role=0 val=0 hold=T setx         ; start edge, then the rest of it
HOLD hold=T/2                         ; middle of bit 0
IN role=0 hold=T xdec back=0         ; eight data bits
WAIT role=0 val=1 hold=none setx xdec back=3

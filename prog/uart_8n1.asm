; UART 8N1 transmit. One program, every payload.
;
; Role 0 is TX, push-pull, idle 1. Shift bit 0 first. xreload is 8.
; T is the bit time. Baud is clock_hz / T.
;
; The byte is not in this listing. The host writes it with CMD_PAYLOAD.
; SET drives the start and stop levels and does not touch the payload.
;
;   idle   start  b0 b1 b2 b3 b4 b5 b6 b7  stop  idle
;     1      0    ........LSB first......    1     1

SET role=0 val=0 hold=T setx          ; start, x = 8
SHIFT role=0 hold=T xdec back=0       ; eight data bits
SET role=0 val=1 hold=T               ; stop
HALT

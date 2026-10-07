; UART 8N1 receive. A second program, run on its own.
;
; Role 0 is RX, an input. The first sample becomes bit 0. xreload is 8.
; T is the bit time and must be even, because the midpoint is T/2.
;
; The WAIT tick is the start edge. HOLD T and HOLD T/2 after it are the
; rest of the start bit and half of bit 0, so the first IN lands inside
; bit 0. Each later IN is one bit time after the previous one.
;
; The stop check is WAIT for 1, not IN. An 8-bit input shift that also
; took the stop bit would shift bit 0 out. A stop level of 0 stalls here.
; After HALT, CMD_READ returns the data byte.

WAIT role=0 val=0 hold=none            ; start edge
HOLD hold=T                            ; rest of the start bit
HOLD hold=T/2 setx                     ; into bit 0, x = 8
IN role=0 hold=T xdec back=0          ; eight data bits
WAIT role=0 val=1 hold=none            ; stop bit must read 1
HALT

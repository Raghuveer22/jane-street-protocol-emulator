; Low-speed USB transmit. D+ is role 0, D− is the side pin. Both push-pull.
;
; Idle, and J, is D+ low and D− high. K is the opposite. T = 33 is
; 50e6/33 ≈ 1.515 Mbit/s, about 1 percent fast of 1.5, inside the
; low-speed window. Byte 0x4B is autopull plus the packet length in
; bytes, sync included, at most 15. The first byte is CMD_PAYLOAD.
; The rest are CMD_PUSH before the run. Bit order is LSB first.
;
; The host queues bytes that are not yet NRZI and not yet stuffed.
; Sync is the byte 0x80. PID, data, and CRC are the host's. OP_NRZI
; sends one byte: a 0 toggles, a 1 holds, and six 1s insert a 0.
; x counts bytes, because one instruction cannot nest a second loop.
;
; EOP is SE0 for two bit times, then J for one. Starting at the first
; SE0 (word 2) is a low-speed keep-alive. Autopull has to be off for
; that run, or the empty shift register stalls the machine before SE0.

HOLD hold=none setx                                  ; x = packet bytes, line stays J
NRZI role=0 side hold=T xdec back=0                  ; one byte, then the next, or EOP
SET role=0 val=0 side side_val=0 hold=T              ; SE0
SET role=0 val=0 side side_val=0 hold=T              ; SE0
NRZI role=0 val=1 side hold=T                        ; J, and the line state is idle again
HALT

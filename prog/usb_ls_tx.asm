; Low-speed USB transmit. D+ is role 0, D− is the side pin. Both push-pull.
;
; Idle, and J, is D+ low and D− high. K is the opposite. T = 33 is
; 50e6/33 ≈ 1.515 Mbit/s, about 1 percent fast of 1.5, inside the
; low-speed window. Byte 0x4D bits [4:1] are yreload: six for USB bit
; stuffing. Autopull is on. Bit order is LSB first.
;
; The host queues plain bytes, sync first (0x80). PID, data, and CRC are
; the host's. XOR toggles on a 0 and holds on a 1. side drives the
; complement. xdec counts ones into Y; a 0 reloads yreload. When Y hits
; 0 the insert XOR toggles once and setx reloads Y. JMP cond=more loops
; while the shift or the TX FIFO still has a bit; otherwise the trailer
; is SE0 for two bit times, then J.

SET role=0 val=0 side side_val=1 hold=T          ; idle J
XOR role=0 side hold=T xdec                      ; one data bit, Y counts ones
JMP cond=y!=0 back=0 hold=none                   ; skip the insert
XOR role=0 val=1 side hold=T setx                ; stuffed toggle, Y reloads
JMP cond=more back=3 hold=none                   ; else the trailer
SET role=0 val=0 side side_val=0 hold=T          ; SE0
SET role=0 val=0 side side_val=0 hold=T          ; SE0
SET role=0 val=0 side side_val=1 hold=T          ; back to J
HALT

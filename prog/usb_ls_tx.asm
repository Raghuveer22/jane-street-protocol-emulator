; USB low-speed transmit. One packet, then end-of-packet.
;
; Role 0 is D+, push-pull. The side pin is D-, push-pull.
; USB_OUT drives D- to the opposite of D+ and ignores side_val.
; T is the bit time. 33 ticks at 50 MHz is about 1.515 Mbit/s.
;
; The host writes pkt_len at 0x4C and the bytes at 0x50-0x5F.
; Those bytes are already the sync, PID, data, and CRC. This program
; only does NRZI and bit stuffing. Idle J is D+ low and D- high.

SET role=0 val=0 side side_val=1 hold=T   ; idle J
USB_OUT side hold=T                        ; packet bits, then fall through
SET role=0 val=0 side side_val=0 hold=T    ; SE0
SET role=0 val=0 side side_val=0 hold=T    ; SE0
SET role=0 val=0 side side_val=1 hold=T    ; back to J
HALT

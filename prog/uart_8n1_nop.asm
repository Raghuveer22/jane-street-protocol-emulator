; Same 8N1 frame as uart_8n1.asm, plus a one-tick HOLD between stop and HALT.
; HOLD hold=none takes one clock and does not stretch the pin for T.
; A T hold here would look like an extra bit on the wire.

SET role=0 val=0 hold=T setx
SHIFT role=0 hold=T xdec back=0
SET role=0 val=1 hold=T
HOLD hold=none
HALT

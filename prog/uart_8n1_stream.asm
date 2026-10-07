; UART 8N1 transmit, back to back, until the TX FIFO runs dry.
;
; Same frame as uart_8n1.asm. The stop bit branches to the start bit.
; Byte 0x4B bit 5 (autopull) must be 1. The first byte is CMD_PAYLOAD.
; Later bytes are CMD_PUSH, before or during the run. On the 8th data
; bit the engine loads the next byte if one is queued. If none is, the
; stop bit still completes and the line stays at idle until a push.

SET role=0 val=0 hold=T setx          ; start, x = 8
SHIFT role=0 hold=T xdec back=0       ; eight data bits
SET role=0 val=1 hold=T setx xdec back=2

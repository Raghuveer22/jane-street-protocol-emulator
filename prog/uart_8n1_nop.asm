; Same 8N1 frame as uart_8n1.asm, plus a NOP between stop and HALT.
; NOP must take one clock and must not hold the pin for PERIOD.
; A hold here would look like an extra bit on the wire.

SET 0       ; start bit
SHIFT       ; b0
SHIFT       ; b1
SHIFT       ; b2
SHIFT       ; b3
SHIFT       ; b4
SHIFT       ; b5
SHIFT       ; b6
SHIFT       ; b7
SET 1       ; stop bit
NOP         ; no pin change, no hold
HALT

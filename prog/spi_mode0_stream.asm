; SPI mode 0, CS held low, clocking until the TX FIFO runs dry.
;
; Byte 0x4B bits 5 and 4 are autopull and autopush. The first byte is
; CMD_PAYLOAD. Each later byte is CMD_PUSH. The IN always branches to
; the SHIFT, so a full byte does not raise CS. The sample of the last
; bit still happens; then the clock waits, high, for another TX byte.

SET role=1 val=0 hold=Tlo setx                 ; CS low, x = 8
SHIFT role=0 side side_val=0 hold=Tlo          ; MOSI, SCK low
IN role=2 side side_val=1 hold=Thi setx xdec back=1

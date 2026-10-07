; I2C master. One address or data byte, then ACK, then stop.
;
; Role 0 is SDA and role 1 is SCL, both open-drain. The side pin is SCL.
; A 0 pulls. A 1 releases. The payload is bit 7 first. xreload is 8.
; in_dir is 1, so CMD_READ bit 0 is the acknowledgement after this program.
; 0 means the other chip pulled SDA.
;
; A second data byte is addresses 2 through 10. Halt after address 10 and
; SCL stays pulled, which holds the bus. Address 10 reloads x, because the
; bit loop leaves it at 0. The host writes the next payload, sets pc to 2,
; and runs. The stop at address 11 runs after the last byte.
; While we have released a wire, the other chip's level is uio_in, and a
; released line with nobody pulling it has to read as 1.

OD role=0 val=pull side side_val=release hold=Tlo       ; start
OD role=1 val=pull hold=Tlo setx                        ; SCL low, x = 8
ODSHIFT role=0 side side_val=pull hold=Tlo              ; next bit, SCL low
OD role=1 val=release hold=1                            ; let SCL rise
WAIT role=1 val=1 hold=none                             ; clock stretch
IN role=0 hold=Thi xdec back=3                          ; sample SDA, loop
OD role=0 val=release side side_val=pull hold=Tlo       ; ACK, we let go
OD role=1 val=release hold=1
WAIT role=1 val=1 hold=none
IN role=0 hold=Thi                                      ; ACK bit
OD role=1 val=pull hold=Tlo setx                        ; SCL low, x = 8 for the next byte
OD role=0 val=pull side side_val=pull hold=Tlo          ; stop: both low
OD role=1 val=release hold=1
WAIT role=1 val=1 hold=none
OD role=0 val=release side side_val=release hold=Thi    ; SDA rises, SCL high
HALT

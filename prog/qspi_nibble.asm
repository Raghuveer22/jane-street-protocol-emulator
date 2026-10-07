; One byte as two nibbles. Width is 4, base is pin 8 (uo[0]).
;
; 0x4C is 0x48: bits 6:5 = 2 (width 4), bits 4:0 = 8.
; out_dir is 1, so the high nibble goes first. base+0 is its low bit,
; so uo[3:0] reads 0xA then 0x5 for payload 0xA5. The side pin is SCK.

SHIFT role=0 side side_val=0 hold=1
SHIFT role=0 side side_val=1 hold=1
HALT

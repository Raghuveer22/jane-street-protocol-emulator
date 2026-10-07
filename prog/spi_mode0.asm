; SPI master, mode 0. Clock idles low. The other chip samples MOSI on the rise.
;
; Role 0 is MOSI, role 1 is CS, role 2 is MISO. The side pin is SCK.
; Shift bit 7 first, out and in. xreload is 8. Tlo and Thi are the two
; halves. Tlo = Thi = 1 is a 25 MHz clock.
;
; CS is its own instruction, so the bit step writes two pins: MOSI and SCK,
; or the MISO sample and SCK. The last IN leaves SCK high. The next frame
; should see SCK idle low again, from the side binding, before CS falls.

SET role=1 val=0 hold=Tlo setx                         ; CS low, x = 8
SHIFT role=0 side side_val=0 hold=Tlo                  ; MOSI, SCK low
IN role=2 side side_val=1 hold=Thi xdec back=1         ; SCK rises, sample MISO
SET role=1 val=1 hold=Tlo                              ; CS high
HALT

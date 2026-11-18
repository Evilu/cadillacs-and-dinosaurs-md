| HUD: the arcade's text layer (scroll 1, 8 x 8 tiles), drawn with sprites.
|
| Only the cells the in-game HUD uses are kept: player 1's panel (arcade
| columns 0-15) and player 2's prompt (columns 17-30, rows 2-3) in the band of
| arcade map rows 34-38, which are screen rows 0-4 with scroll 1 where the game
| keeps it. The game's writes go to a cell store in RAM, which also serves its
| reads. Changed cells are drawn in VBlank into patterns owned by 13 fixed
| sprites, with their pens renumbered onto the CRAM line that holds player 1's
| sprite palette (nearest colour first) and their flips applied. Sprites and
| not the window plane: the window would replace the far background behind the
| HUD. The HUD's sprites come first in the sprite table, so they draw in front
| of the game's as on the arcade; a sprite whose cells are all blank is left out.

    .equ S1_BASE,       0x908000
    .equ HUD_CELLS,     108
    .equ P2_CELL,       80          | first cell of player 2's prompt
    .equ P2_COLUMN,     25          | its first screen column (arcade column 17)
    .equ HUD_SPRITES,   13
    .equ HUD_MAPS,      8
    .equ HUD_ROW0,      34          | arcade map row on screen row 0 (scroll 1 at y = 256)
    .equ HUD_ROWS,      5
    .equ HUD_DRAWS,     8           | cells drawn per frame at most
    .equ TEXT_FLAGS,    0x1a2000    | per 8 x 8 text pattern (code * 2 + half): nonzero if it has pixels
    .equ CELL_ATTR,     0xff1620    | per cell: attribute bits 0-6 (palette, flips)
    .equ CELL_BLANK,    0xff168c    | 14 bytes: bit per cell drawn without pixels
    .equ CELL_DIRTY,    0xff1720    | 14 bytes: bit per cell to draw again
    .equ SPR_COUNT,     0xff172e    | per sprite: its cells with pixels
    .equ PMAP_OF,       0xff173c    | per arcade palette: its pen map, 0xff none
    .equ MAP_PAL,       0xff175c    | per pen map: its arcade palette, 0xff free
    .equ HUD_VARS,      0xff1764
    .equ hud_sat_n,     HUD_VARS        | HUD entries at the start of SAT_BUF, -1 to write them again
    .equ hud_line,      HUD_VARS + 2    | CRAM line the HUD's pens are mapped onto
    .equ hud_line_sum,  HUD_VARS + 4
    .equ hud_check,     HUD_VARS + 6    | pen map whose palette is checked next
    .equ map_dirty,     HUD_VARS + 8    | bit per pen map to compute again
    .equ hud_misses,    HUD_VARS + 10   | draws put off for want of a pen map
    .equ dirty_any,     HUD_VARS + 12   | nonzero: CELL_DIRTY may have bits set
    .equ hud_line_seen, HUD_VARS + 14   | checksum of hud_line at the last check
    .equ MAP_SEEN,      HUD_VARS + 16   | per pen map: checksum of its palette at the last check
    .equ HUD_VARS_END,  HUD_VARS + 32
    .equ MAP_SUM,       0xff1850    | per pen map: checksum of the palette's colours when computed
    .equ PENMAPS,       0xff19a0    | 6 x 16 bytes, then one each in two gaps of the far background's
    .equ PENMAP_6,      0xff1a50    | tables (see hud_maps): Mega Drive pen -> pen in hud_line
    .equ PENMAP_7,      0xff1ab0
    .equ CELL_CODE,     0xff1c20    | per cell: tile code

| Screen column, screen row, width, height (in cells), first VRAM pattern. The
| patterns fill the last gaps in VRAM: 0x001-0x01e, 0x41c-0x41e (the playfield
| cache's last slot), the window table's rows 0-7 (0x680-0x69f, the window is
| off), 0x781-0x79f and 0x7f4-0x7ff.
| Within a sprite, patterns go down each column first.
hud_sprites:
    .byte   0, 0, 4, 4
    .word   0x680
    .byte   4, 0, 4, 4
    .word   0x690
    .byte   8, 0, 4, 4
    .word   0x001
    .byte   12, 0, 4, 4
    .word   0x781
    .byte   0, 4, 3, 1
    .word   0x41c
    .byte   3, 4, 3, 1
    .word   0x7fa
    .byte   6, 4, 3, 1
    .word   0x7fd
    .byte   9, 4, 3, 1
    .word   0x79d
    .byte   12, 4, 4, 1
    .word   0x799
    .byte   25, 2, 4, 2
    .word   0x791
    .byte   29, 2, 4, 2
    .word   0x011
    .byte   33, 2, 3, 2
    .word   0x019
    .byte   36, 2, 3, 2
    .word   0x7f4

| Sprite of each cell: player 1's rows 0-4, then player 2's rows 2-3.
hud_cell_sprite:
    .rept   4
    .byte   0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3
    .endr
    .byte   4, 4, 4, 5, 5, 5, 6, 6, 6, 7, 7, 7, 8, 8, 8, 8
    .rept   2
    .byte   9, 9, 9, 9, 10, 10, 10, 10, 11, 11, 11, 12, 12, 12
    .endr
    .even

hud_maps:
    .long   PENMAPS, PENMAPS + 16, PENMAPS + 32, PENMAPS + 48, PENMAPS + 64, PENMAPS + 80
    .long   PENMAP_6, PENMAP_7

hud_init:
    lea     CELL_CODE, a0
    moveq   #HUD_CELLS - 1, d0
1:  move.w  #0x0020, (a0)+
    dbra    d0, 1b
    lea     CELL_ATTR, a0
    moveq   #HUD_CELLS - 1, d0
2:  move.b  #0x06, (a0)+
    dbra    d0, 2b
    lea     CELL_BLANK, a0
    moveq   #13, d0
3:  st      (a0)+
    dbra    d0, 3b
    lea     CELL_DIRTY, a0
    moveq   #13 + HUD_SPRITES, d0
4:  clr.b   (a0)+
    dbra    d0, 4b
    lea     PMAP_OF, a0
    moveq   #32 + HUD_MAPS - 1, d0
5:  st      (a0)+
    dbra    d0, 5b
    lea     HUD_VARS, a0
    moveq   #(HUD_VARS_END - HUD_VARS) / 2 - 1, d0
6:  clr.w   (a0)+
    dbra    d0, 6b
    rts

| ---------------------------------------------------------------- game side

| d0 address in scroll 1 -> NE and d2 cell, d3 0 for the code word or 2 for the
| attribute; EQ if the HUD does not keep that cell. Uses d4.
s1_cell:
    move.w  d0, d2
    andi.w  #0x3ffc, d2
    lsr.w   #2, d2
    move.w  d2, d3
    lsr.w   #6, d3
    andi.w  #0x20, d3
    move.w  d2, d4
    andi.w  #0x1f, d4
    or.w    d3, d4
    subi.w  #HUD_ROW0, d4
    cmpi.w  #HUD_ROWS, d4
    bhs.s   9f
    lsr.w   #5, d2
    andi.w  #63, d2
    cmpi.w  #16, d2
    bhs.s   2f
    lsl.w   #4, d4
    add.w   d4, d2
    bra.s   8f
2:  subi.w  #17, d2
    cmpi.w  #14, d2
    bhs.s   9f
    subq.w  #2, d4
    cmpi.w  #2, d4
    bhs.s   9f
    tst.w   d4
    beq.s   3f
    addi.w  #14, d2
3:  addi.w  #P2_CELL, d2
8:  move.w  d0, d3
    andi.w  #2, d3
    moveq   #1, d4
    rts
9:  moveq   #0, d4
    rts

| d0 address in scroll 1, d1 word
s1_write:
    movem.l d2-d4/a1, -(sp)
    bsr.s   s1_cell
    beq.s   9f
    tst.w   d3
    bne.s   2f
    move.w  d2, d3
    add.w   d3, d3
    lea     CELL_CODE, a1
    cmp.w   0(a1,d3.w), d1
    beq.s   9f
    move.w  d1, 0(a1,d3.w)
    bra.s   3f
2:  moveq   #0x7f, d3
    and.w   d1, d3
    lea     CELL_ATTR, a1
    cmp.b   0(a1,d2.w), d3
    beq.s   9f
    move.b  d3, 0(a1,d2.w)
3:  move.w  d2, d3
    lsr.w   #3, d3
    lea     CELL_DIRTY, a1
    bset    d2, 0(a1,d3.w)
    st      dirty_any
9:  movem.l (sp)+, d2-d4/a1
    rts

| d0 address in scroll 1 -> d1 word
s1_read:
    movem.l d2-d4/a1, -(sp)
    moveq   #0, d1
    bsr.w   s1_cell
    beq.s   9f
    tst.w   d3
    bne.s   2f
    add.w   d2, d2
    lea     CELL_CODE, a1
    move.w  0(a1,d2.w), d1
    bra.s   9f
2:  lea     CELL_ATTR, a1
    move.b  0(a1,d2.w), d1
9:  movem.l (sp)+, d2-d4/a1
    rts

| d0 tile code, d1 attribute the game filled the whole layer with
hud_fill:
    movem.l d0-d2/a0, -(sp)
    lea     CELL_CODE, a0
    moveq   #HUD_CELLS - 1, d2
1:  move.w  d0, (a0)+
    dbra    d2, 1b
    moveq   #0x7f, d2
    and.w   d1, d2
    lea     CELL_ATTR, a0
    moveq   #HUD_CELLS - 1, d0
2:  move.b  d2, (a0)+
    dbra    d0, 2b
    lea     CELL_DIRTY, a0
    moveq   #13, d0
3:  st      (a0)+
    dbra    d0, 3b
    st      dirty_any
    movem.l (sp)+, d0-d2/a0
    rts

| TRAP #13 replaces the loop at 0x16726 (and its twin at 0x16760) that recolours
| HUD cells: d5 + 1 columns of two cells, attribute = attribute & d4 | (a1)+.
trap_recolour:
    hal_enter
    movem.l d1-d3, -(sp)
1:  bsr.s   recolour_cell
    addq.l  #2, a0
    bsr.s   recolour_cell
    lea     0x7a(a0), a0
    dbra    d5, 1b
    movem.l (sp)+, d1-d3
    hal_leave
    rte

| a0 attribute word of a cell: attribute & d4 | (a1)+, a0 += 2, d0 the new word
recolour_cell:
    move.l  a0, d0
    andi.l  #0xffffff, d0
    bsr.w   s1_read
    and.w   d4, d1
    or.w    (a1)+, d1
    bsr.w   s1_write
    move.w  d1, d0
    addq.l  #2, a0
    rts

| TRAP #14 replaces "move.w d0,(a1)+ / move.w d2,(a1)" in the arcade's text
| printers (0xc34, 0xc8a, 0xcc2): one trap per character instead of two decoded ones.
trap_text:
    hal_enter
    movem.l d0-d1, -(sp)
    move.w  d0, d1
    move.l  a1, d0
    andi.l  #0xffffff, d0
    cmpi.l  #GFX_LO, d0
    blo.s   1f
    cmpi.l  #GFX_HI, d0
    bhs.s   1f
    bsr.w   gfx_write_w
    addq.l  #2, d0
    move.w  d2, d1
    bsr.w   gfx_write_w
    addq.l  #2, a1
    bra.s   2f
1:  move.w  d1, (a1)+
    move.w  d2, (a1)
2:  movem.l (sp)+, d0-d1
    hal_leave
    rte

| TRAP #15 replaces short runs of writes into the text layer at four sites,
| found by the return address; each handler does the writes and resumes after
| the instructions it replaced:
|   0x8506a  (a1)+ = d0, (a1)+ = d2, d0 += 0x10, (a1)+ = d0, (a1)+ = d2
|   0x17a00, 0x17408  0(a0) = (a1)+, 2(a0) = d1, 4(a0) = (a1)+, 6(a0) = d1
|   0x17660  0(a0) = 0x20, 2(a0) = 8(a3)
trap_hud:
    hal_enter
    movem.l d0-d1/d3/a2, -(sp)
    movea.l 16(sp), a2
    move.l  6(a2), d3
    cmpi.l  #0x08506c, d3
    beq.s   1f
    cmpi.l  #0x017662, d3
    beq.s   3f
    move.w  (a1)+, d1
    lea     0(a0), a2
    bsr.s   text_put
    move.w  6(sp), d1
    lea     2(a0), a2
    bsr.s   text_put
    move.w  (a1)+, d1
    lea     4(a0), a2
    bsr.s   text_put
    move.w  6(sp), d1
    lea     6(a0), a2
    bsr.s   text_put
    moveq   #14, d3
    bra.s   8f
1:  move.w  2(sp), d0
    movea.l a1, a2
    move.w  d0, d1
    bsr.s   text_put
    move.w  d2, d1
    lea     2(a2), a2
    bsr.s   text_put
    addi.w  #0x10, d0
    move.w  d0, d1
    lea     2(a2), a2
    bsr.s   text_put
    move.w  d2, d1
    lea     2(a2), a2
    bsr.s   text_put
    lea     8(a1), a1
    move.w  d0, 2(sp)
    moveq   #10, d3
    bra.s   8f
3:  moveq   #0x20, d1
    lea     0(a0), a2
    bsr.s   text_put
    move.w  8(a3), d1
    lea     2(a0), a2
    bsr.s   text_put
    moveq   #10, d3
8:  movea.l 16(sp), a2
    add.l   d3, 6(a2)
    movem.l (sp)+, d0-d1/d3/a2
    hal_leave
    rte

| a2 address, d1 word: writes it, through the hardware layer if it is arcade video RAM
text_put:
    move.l  d0, -(sp)
    move.l  a2, d0
    andi.l  #0xffffff, d0
    cmpi.l  #GFX_LO, d0
    blo.s   1f
    cmpi.l  #GFX_HI, d0
    bhs.s   1f
    bsr.w   gfx_write_w
    move.l  (sp)+, d0
    rts
1:  move.w  d1, (a2)
    move.l  (sp)+, d0
    rts

| ---------------------------------------------------------------- sprites

| Writes the sprite table entries of the HUD's sprites that have pixels at the
| start of SAT_BUF -> a1 after them. Called by build_sprites.
hud_sat:
    movem.l d0-d3/a2-a3, -(sp)
    lea     SAT_BUF, a1
    move.w  hud_sat_n, d3
    bmi.s   0f
    beq.s   9f
    lsl.w   #3, d3
    adda.w  d3, a1
    lsr.w   #3, d3
    move.b  d3, -5(a1)
    bra.s   9f
0:  lea     hud_sprites(pc), a2
    lea     SPR_COUNT, a3
    moveq   #0, d3
    moveq   #HUD_SPRITES - 1, d2
1:  tst.b   (a3)+
    beq.s   2f
    moveq   #0, d0
    move.b  1(a2), d0
    lsl.w   #3, d0
    addi.w  #128, d0
    move.w  d0, (a1)+
    moveq   #0, d0
    move.b  2(a2), d0
    subq.w  #1, d0
    lsl.w   #2, d0
    moveq   #0, d1
    move.b  3(a2), d1
    subq.w  #1, d1
    or.w    d1, d0
    lsl.w   #8, d0
    addq.w  #1, d3
    or.b    d3, d0
    move.w  d0, (a1)+
    move.w  hud_line, d0
    ror.w   #3, d0
    or.w    4(a2), d0
    ori.w   #0x8000, d0
    move.w  d0, (a1)+
    moveq   #0, d0
    move.b  (a2), d0
    lsl.w   #3, d0
    addi.w  #128, d0
    move.w  d0, (a1)+
2:  addq.l  #6, a2
    dbra    d2, 1b
    move.w  d3, hud_sat_n
9:  movem.l (sp)+, d0-d3/a2-a3
    rts

| ---------------------------------------------------------------- VBlank

| Called once per frame from VBlank after build_cram. Follows player 1's palette
| to its CRAM line, recomputes pen maps whose colours changed (one per frame) and
| draws cells that changed (HUD_DRAWS per frame). Colours are checked every 16
| frames and a change counts only once it has held for a check: during a fade
| every palette moves each frame, and the maps would be computed again for nothing.
hud_update:
    lea     line_pal, a0
    moveq   #0, d0
1:  tst.b   0(a0,d0.w)
    beq.s   2f
    addq.w  #1, d0
    cmpi.w  #3, d0
    blo.s   1b
    bra.s   3f
2:  cmp.w   hud_line, d0
    beq.s   3f
    move.w  d0, hud_line
    move.w  #(1 << HUD_MAPS) - 1, map_dirty
    move.w  #1, list_dirty
    move.w  #-1, hud_sat_n
3:  move.l  hal_frames, d0
    andi.w  #15, d0
    bne.w   5f
    move.w  hud_line, d0
    lsl.w   #5, d0
    lea     CRAM_BUF + 2, a0
    adda.w  d0, a0
    bsr.w   colour_sum
    cmp.w   hud_line_sum, d7
    beq.s   4f
    cmp.w   hud_line_seen, d7
    beq.s   7f
    move.w  d7, hud_line_seen
    bra.s   5f
7:  move.w  d7, hud_line_sum
    move.w  #(1 << HUD_MAPS) - 1, map_dirty
    bra.s   5f
4:  move.w  hud_check, d6
    addq.w  #1, d6
    cmpi.w  #HUD_MAPS, d6
    blo.s   6f
    moveq   #0, d6
6:  move.w  d6, hud_check
    lea     MAP_PAL, a1
    moveq   #0, d0
    move.b  0(a1,d6.w), d0
    bmi.s   5f
    lea     PALETTES + 0x400, a0
    lsl.w   #5, d0
    adda.w  d0, a0
    bsr.w   colour_sum
    move.w  d6, d0
    add.w   d0, d0
    lea     MAP_SUM, a0
    cmp.w   0(a0,d0.w), d7
    beq.s   5f
    lea     MAP_SEEN, a0
    cmp.w   0(a0,d0.w), d7
    beq.s   7f
    move.w  d7, 0(a0,d0.w)
    bra.s   5f
7:  move.w  map_dirty, d0
    bset    d6, d0
    move.w  d0, map_dirty
5:  bsr.s   remap_one
    bra.w   draw_dirty

| Computes the lowest dirty pen map again and, if it changed, marks the cells in
| its palette for drawing.
remap_one:
    move.w  map_dirty, d0
    beq.w   9f
    moveq   #0, d6
1:  btst    d6, d0
    bne.s   2f
    addq.w  #1, d6
    bra.s   1b
2:  bclr    d6, d0
    move.w  d0, map_dirty
    lea     MAP_PAL, a1
    moveq   #0, d0
    move.b  0(a1,d6.w), d0
    bmi.s   9f
    bsr.w   map_ptr
    movem.l (a2), d1-d4
    bsr.w   map_make
    cmp.l   (a2)+, d1
    bne.s   6f
    cmp.l   (a2)+, d2
    bne.s   6f
    cmp.l   (a2)+, d3
    bne.s   6f
    cmp.l   (a2)+, d4
    beq.s   9f
6:  lea     CELL_ATTR, a0
    lea     CELL_DIRTY, a3
    moveq   #0, d1
3:  moveq   #31, d2
    and.b   0(a0,d1.w), d2
    cmp.b   d0, d2
    bne.s   5f
    move.w  d1, d2
    lsr.w   #3, d2
    bset    d1, 0(a3,d2.w)
    st      dirty_any
5:  addq.w  #1, d1
    cmpi.w  #HUD_CELLS, d1
    blo.s   3b
9:  rts

| Draws up to HUD_DRAWS cells marked dirty, skipping clean bytes of the mask.
| A cell whose palette gets no pen map stays marked for a later frame.
draw_dirty:
    tst.b   dirty_any
    beq.s   9f
    clr.b   dirty_any
    lea     CELL_DIRTY, a3
    moveq   #HUD_DRAWS - 1, d5
    moveq   #0, d7
1:  tst.b   (a3)
    bne.s   2f
    addq.l  #1, a3
    addq.w  #8, d7
    cmpi.w  #112, d7
    blo.s   1b
    rts
2:  moveq   #7, d6
3:  bclr    d7, (a3)
    beq.s   5f
    cmpi.w  #HUD_CELLS, d7
    bhs.s   5f
    bsr.s   cell_draw
    bne.s   4f
    bset    d7, (a3)
    st      dirty_any
    addq.w  #1, hud_misses
4:  subq.w  #1, d5
    bmi.s   8f
5:  addq.w  #1, d7
    dbra    d6, 3b
    addq.l  #1, a3
    cmpi.w  #112, d7
    blo.s   1b
9:  rts
8:  st      dirty_any
    rts

| d7 cell: draws it into its sprite's pattern -> NE, or EQ if its palette got no
| pen map (nothing drawn). Keeps d5-d7, a3.
cell_draw:
    movem.l d5-d7/a3, -(sp)
    move.w  d7, d0
    cmpi.w  #P2_CELL, d0
    bhs.s   1f
    move.w  d0, d1
    lsr.w   #4, d1
    andi.w  #15, d0
    bra.s   2f
1:  subi.w  #P2_CELL, d0
    moveq   #2, d1
    cmpi.w  #14, d0
    blo.s   3f
    subi.w  #14, d0
    moveq   #3, d1
3:  addi.w  #P2_COLUMN, d0
2:  moveq   #1, d5
    and.w   d0, d5
    lea     hud_cell_sprite(pc), a0
    moveq   #0, d4
    move.b  0(a0,d7.w), d4
    move.w  d4, d2
    mulu    #6, d2
    lea     hud_sprites(pc), a0
    adda.w  d2, a0
    moveq   #0, d2
    move.b  (a0), d2
    move.w  d0, d3
    sub.w   d2, d3
    move.b  1(a0), d2
    move.w  d1, d6
    sub.w   d2, d6
    move.b  3(a0), d2
    mulu    d2, d3
    add.w   d6, d3
    add.w   4(a0), d3
    move.w  d7, d0
    add.w   d0, d0
    lea     CELL_CODE, a0
    move.w  0(a0,d0.w), d1
    lea     CELL_ATTR, a0
    moveq   #0, d2
    move.b  0(a0,d7.w), d2
    moveq   #0, d6
    cmpi.w  #0x1000, d1
    bhs.s   7f
    move.w  d1, d0
    add.w   d0, d0
    or.w    d5, d0
    lea     TEXT_FLAGS, a0
    tst.b   0(a0,d0.w)
    beq.s   7f
    moveq   #31, d0
    and.w   d2, d0
    move.l  d7, -(sp)
    bsr.w   hud_map_for
    movem.l (sp)+, d7
    beq.w   21f
    moveq   #1, d6
7:  lsl.w   #5, d3
    moveq   #0, d0
    move.w  d3, d0
    andi.w  #0x3fff, d0
    ori.w   #0x4000, d0
    swap    d0
    rol.w   #2, d3
    andi.w  #3, d3
    move.w  d3, d0
    move.l  d0, VDP_CTRL
    tst.w   d6
    beq.s   8f
    bsr.s   pattern_load
    bra.s   9f
8:  lea     VDP_DATA, a1
    moveq   #7, d0
10: clr.l   (a1)
    dbra    d0, 10b
9:  lea     CELL_BLANK, a0
    move.w  d7, d0
    lsr.w   #3, d0
    lea     SPR_COUNT, a1
    tst.w   d6
    beq.s   11f
    bclr    d7, 0(a0,d0.w)
    beq.s   20f
    addq.b  #1, 0(a1,d4.w)
    cmpi.b  #1, 0(a1,d4.w)
    bne.s   20f
    bra.s   12f
11: bset    d7, 0(a0,d0.w)
    bne.s   20f
    subq.b  #1, 0(a1,d4.w)
    bne.s   20f
12: move.w  #1, list_dirty
    move.w  #-1, hud_sat_n
20: movem.l (sp)+, d5-d7/a3
    moveq   #1, d0
    rts
21: movem.l (sp)+, d5-d7/a3
    moveq   #0, d0
    rts

| One byte of a pattern row (two pixels) through the pen map a2, into the low
| byte of \dst; reversed reads the bytes backwards and swaps the pixels. Uses d0, d3.
    .macro  pen_byte dst, reversed
    moveq   #0, d0
    .if \reversed
    move.b  -(a0), d0
    moveq   #15, d3
    and.w   d0, d3
    move.b  0(a2,d3.w), \dst
    lsl.b   #4, \dst
    lsr.w   #4, d0
    .else
    move.b  (a0)+, d0
    move.w  d0, d3
    lsr.w   #4, d3
    move.b  0(a2,d3.w), \dst
    lsl.b   #4, \dst
    andi.w  #15, d0
    .endif
    or.b    0(a2,d0.w), \dst
    .endm

| d1 tile code, d5 half, d2 attribute, a2 pen map, VDP address set: writes the
| tile's 8 x 8 pattern with its pens renumbered and its flips applied.
pattern_load:
    movem.l d4/d6-d7, -(sp)
    moveq   #0, d0
    move.w  d1, d0
    lsr.w   #1, d0
    lsl.l   #7, d0
    btst    #0, d1
    beq.s   1f
    moveq   #32, d6
    add.l   d6, d0
1:  tst.w   d5
    beq.s   2f
    moveq   #64, d6
    add.l   d6, d0
2:  addi.l  #TILE_DATA, d0
    movea.l d0, a0
    lea     VDP_DATA, a1
    moveq   #7, d7
    btst    #5, d2
    bne.s   5f
    moveq   #0, d6
    btst    #6, d2
    beq.s   4f
    lea     28(a0), a0
    moveq   #-8, d6
4:  .rept   2
    pen_byte d1, 0
    lsl.w   #8, d1
    pen_byte d4, 0
    move.b  d4, d1
    move.w  d1, (a1)
    .endr
    adda.w  d6, a0
    dbra    d7, 4b
    movem.l (sp)+, d4/d6-d7
    rts
5:  moveq   #12, d6
    addq.l  #4, a0
    btst    #6, d2
    beq.s   6f
    lea     28(a0), a0
    moveq   #0, d6
6:  .rept   2
    pen_byte d1, 1
    lsl.w   #8, d1
    pen_byte d4, 1
    move.b  d4, d1
    move.w  d1, (a1)
    .endr
    adda.w  d6, a0
    subq.l  #4, a0
    dbra    d7, 6b
    movem.l (sp)+, d4/d6-d7
    rts

| ---------------------------------------------------------------- pen maps

| d6 pen map -> a2 its address
map_ptr:
    move.w  d6, -(sp)
    add.w   d6, d6
    add.w   d6, d6
    lea     hud_maps(pc), a2
    movea.l 0(a2,d6.w), a2
    move.w  (sp)+, d6
    rts

| d0 arcade palette -> NE and a2 its pen map, made if needed; EQ if every map
| belongs to a palette still on screen. Uses d6, d7.
hud_map_for:
    movem.l d1-d5/a0-a1, -(sp)
    lea     PMAP_OF, a2
    moveq   #0, d6
    move.b  0(a2,d0.w), d6
    bpl.s   8f
    lea     MAP_PAL, a2
    moveq   #HUD_MAPS - 1, d6
1:  tst.b   0(a2,d6.w)
    bmi.s   4f
    dbra    d6, 1b
    moveq   #HUD_MAPS - 1, d6
2:  moveq   #0, d7
    move.b  0(a2,d6.w), d7
    bsr.s   pal_live
    beq.s   3f
    dbra    d6, 2b
    movem.l (sp)+, d1-d5/a0-a1
    moveq   #0, d6
    rts
3:  lea     PMAP_OF, a0
    st      0(a0,d7.w)
4:  lea     MAP_PAL, a2
    move.b  d0, 0(a2,d6.w)
    lea     PMAP_OF, a2
    move.b  d6, 0(a2,d0.w)
    bsr.w   map_make
8:  bsr.w   map_ptr
    movem.l (sp)+, d1-d5/a0-a1
    moveq   #1, d6
    rts

| d7 arcade palette -> NE if a cell drawn with pixels has it. Uses d1, d2, a0, a1.
pal_live:
    lea     CELL_ATTR, a0
    lea     CELL_BLANK, a1
    moveq   #0, d1
1:  moveq   #31, d2
    and.b   0(a0,d1.w), d2
    cmp.b   d7, d2
    bne.s   2f
    move.w  d1, d2
    lsr.w   #3, d2
    btst    d1, 0(a1,d2.w)
    bne.s   2f
    moveq   #1, d2
    rts
2:  addq.w  #1, d1
    cmpi.w  #HUD_CELLS, d1
    blo.s   1b
    moveq   #0, d2
    rts

| a0 15 colour words -> d7 checksum. Uses d1.
colour_sum:
    moveq   #0, d7
    moveq   #14, d1
1:  add.w   (a0)+, d7
    rol.w   #1, d7
    dbra    d1, 1b
    rts

| d6 pen map, d0 arcade palette: each pen gets the nearest colour in hud_line
| (smallest sum of channel differences). The line's 15 colours are unpacked
| into a table on the stack first, so the search is a short inline loop.
map_make:
    movem.l d0-d7/a0-a6, -(sp)
    lea     -46(sp), sp
    movea.l sp, a5
    move.w  hud_line, d1
    lsl.w   #5, d1
    lea     CRAM_BUF + 2, a0
    adda.w  d1, a0
    movea.l a5, a1
    moveq   #14, d2
1:  move.w  (a0)+, d0
    moveq   #15, d1
    and.b   d0, d1
    move.b  d1, (a1)+
    lsr.w   #4, d0
    moveq   #15, d1
    and.b   d0, d1
    move.b  d1, (a1)+
    lsr.w   #4, d0
    andi.b  #15, d0
    move.b  d0, (a1)+
    dbra    d2, 1b
    movea.l a1, a6
    bsr.w   map_ptr
    clr.b   (a2)+
    move.w  46 + 2(sp), d0
    lsl.w   #5, d0
    lea     PALETTES + 0x400, a0
    adda.w  d0, a0
    lea     COLOUR_TABLE, a4
    moveq   #0, d7
    movea.w #15, a3
2:  move.w  (a0)+, d0
    add.w   d0, d7
    rol.w   #1, d7
    bsr.w   md_colour
    move.w  d3, d4
    lsr.w   #4, d4
    move.w  d4, d5
    lsr.w   #4, d5
    andi.w  #15, d3
    andi.w  #15, d4
    andi.w  #15, d5
    movea.l a5, a1
    moveq   #127, d6
3:  move.b  (a1)+, d0
    sub.b   d3, d0
    bpl.s   4f
    neg.b   d0
4:  move.b  (a1)+, d1
    sub.b   d4, d1
    bpl.s   5f
    neg.b   d1
5:  add.b   d1, d0
    move.b  (a1)+, d1
    sub.b   d5, d1
    bpl.s   6f
    neg.b   d1
6:  add.b   d1, d0
    cmp.b   d6, d0
    bhs.s   7f
    move.b  d0, d6
    move.l  a1, d2
    tst.b   d0
    beq.s   8f
7:  cmpa.l  a6, a1
    blo.s   3b
8:  sub.l   a5, d2
    divu    #3, d2
    move.b  d2, (a2)+
    subq.w  #1, a3
    move.w  a3, d0
    bne.s   2b
    move.w  46 + 26(sp), d0
    add.w   d0, d0
    lea     MAP_SUM, a0
    move.w  d7, 0(a0,d0.w)
    lea     46(sp), sp
    movem.l (sp)+, d0-d7/a0-a6
    rts

| d0 arcade colour, a4 colour table -> d3 Mega Drive colour. Uses d1, d2.
md_colour:
    move.w  d0, d1
    lsr.w   #8, d1
    andi.w  #0xf0, d1
    move.w  d0, d2
    andi.w  #15, d2
    or.w    d1, d2
    moveq   #0, d3
    move.b  0(a4,d2.w), d3
    lsl.w   #4, d3
    move.w  d0, d2
    lsr.w   #4, d2
    andi.w  #15, d2
    or.w    d1, d2
    or.b    0(a4,d2.w), d3
    lsl.w   #4, d3
    move.w  d0, d2
    lsr.w   #8, d2
    andi.w  #15, d2
    or.w    d1, d2
    or.b    0(a4,d2.w), d3
    rts

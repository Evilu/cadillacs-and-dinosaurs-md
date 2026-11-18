| Background layers, and emulation of the arcade code's tilemap accesses.
|
| The arcade playfield (scroll 2: 64 x 64 tiles of 16 x 16) is kept in a RAM
| store of 64 columns x 32 rows (arcade rows taken mod 32) and drawn on plane B,
| a ring of 32 columns x 16 rows that follows the camera. Tiles are loaded into
| a reference-counted VRAM cache. Code that writes or reads arcade video RAM
| through pointers was replaced at build time by TRAP #8 (see gfx_trap) or by
| calls to the fast paths below.

    .equ GFX_LO,        0x900000
    .equ GFX_HI,        0x930000
    .equ S2_BASE,       0x90c000
    .equ S2_END,        0x910000
    .equ S2_STORE,      0xff4000    | (col << 5 | row & 31) * 4: code word, attribute word
    .equ PLANE_B,       0xc000
    .equ S2_SLOTS,      128         | patterns 0x220-0x41f
    .equ S2_W,          23          | columns drawn: the 21 visible ones plus one each side
    .equ S2_PATTERN,    0x220       | first VRAM pattern of the playfield tile cache
    .equ HASH,          0xff7000    | 512 entries: tile code (0xffff empty), slot
    .equ HASH_END,      HASH + 2048
    .equ S2_REF,        0xff7800    | per slot: plane cells using it
    .equ S2_KEY,        0xff7990    | per slot: tile code
    .equ FREE_STACK,    0xff7b20    | free slot numbers
    .equ RING_SLOT,     0xff7c00    | per ring cell (32 x 16): slot, 0xff for none
    .equ DIRTY,         0xff7e00    | 64 words: col << 8 | row
    .equ BG_VARS,       0xff7e80
    .equ COVER,         0xff7f00    | 32 longs, one per ring column: bit r set if store row r shows a fully opaque tile
    .equ free_top,      BG_VARS
    .equ dirty_count,   BG_VARS + 2
    .equ s2_valid,      BG_VARS + 4
    .equ s2_col0,       BG_VARS + 6
    .equ s2_row0,       BG_VARS + 8
    .equ s2_full,       BG_VARS + 10
    .equ s2_hscroll,    BG_VARS + 12
    .equ s2_vscroll,    BG_VARS + 14
    .equ s2_pal,        BG_VARS + 16
    .equ u_count,       BG_VARS + 18
    .equ r_col,         BG_VARS + 20
    .equ r_row,         BG_VARS + 22
    .equ cam2_x,        BG_VARS + 26
    .equ cam2_y,        BG_VARS + 28
    .equ r_attr,        BG_VARS + 24
    .equ S2_PAL_COUNT,  BG_VARS + 32
    .equ ARCADE_FILL_END, 0x000ba8
    .equ PATCH_HASH,    0x198000    | 1024 words: offset of the entry for (pc >> 1) & 1023, 0xffff empty

bg_init:
    lea     HASH, a0
    move.w  #511, d0
1:  move.l  #0xffff0000, (a0)+
    dbra    d0, 1b
    lea     S2_REF, a0
    move.w  #S2_SLOTS - 1, d0
2:  clr.w   (a0)+
    dbra    d0, 2b
    lea     FREE_STACK, a0
    moveq   #0, d0
3:  move.b  d0, (a0)+
    addq.w  #1, d0
    cmpi.w  #S2_SLOTS, d0
    blt.s   3b
    move.w  #S2_SLOTS, free_top
    lea     RING_SLOT, a0
    move.w  #511, d0
4:  move.b  #0xff, (a0)+
    dbra    d0, 4b
    clr.w   dirty_count
    clr.w   s2_valid
    clr.w   s2_full
    clr.w   s2_pal
    bra.w   s3_init

| ---------------------------------------------------------------- tile cache

| d0 key -> d1 slot or -1, a2 entry (the free entry when not found)
hash_lookup:
    move.w  d0, d1
    lsr.w   #7, d1
    eor.w   d0, d1
    andi.w  #511, d1
    lsl.w   #2, d1
    lea     HASH, a2
    adda.w  d1, a2
1:  move.w  (a2), d1
    cmp.w   d0, d1
    beq.s   2f
    cmpi.w  #0xffff, d1
    beq.s   3f
    addq.l  #4, a2
    cmpa.l  #HASH_END, a2
    blo.s   1b
    lea     HASH, a2
    bra.s   1b
2:  move.w  2(a2), d1
    rts
3:  moveq   #-1, d1
    rts

| a2 entry to delete; backward-shift deletion keeps probe chains intact
hash_delete:
    movea.l a2, a3
1:  addq.l  #4, a2
    cmpa.l  #HASH_END, a2
    blo.s   2f
    lea     HASH, a2
2:  move.w  (a2), d1
    cmpi.w  #0xffff, d1
    beq.s   9f
    move.w  d1, d2
    lsr.w   #7, d2
    eor.w   d1, d2
    andi.w  #511, d2
    lsl.w   #2, d2
    lea     HASH, a4
    adda.w  d2, a4
    move.l  a2, d3
    sub.l   a4, d3
    andi.l  #2047, d3
    move.l  a2, d4
    sub.l   a3, d4
    andi.l  #2047, d4
    cmp.l   d4, d3
    blo.s   1b
    move.l  (a2), (a3)
    movea.l a2, a3
    bra.s   1b
9:  move.w  #0xffff, (a3)
    rts

| d0 tile code -> d5 slot or -1
s2_acquire:
    bsr.w   hash_lookup
    tst.w   d1
    bmi.s   1f
    move.w  d1, d5
    add.w   d1, d1
    lea     S2_REF, a3
    addq.w  #1, 0(a3,d1.w)
    rts
1:  move.w  free_top, d1
    bne.s   2f
    moveq   #-1, d5
    rts
2:  subq.w  #1, d1
    move.w  d1, free_top
    lea     FREE_STACK, a3
    moveq   #0, d5
    move.b  0(a3,d1.w), d5
    move.w  d0, (a2)
    move.w  d5, 2(a2)
    move.w  d5, d1
    add.w   d1, d1
    lea     S2_REF, a3
    move.w  #1, 0(a3,d1.w)
    lea     S2_KEY, a3
    move.w  d0, 0(a3,d1.w)

| d0 tile code, d5 slot: copies the tile's four patterns from ROM into the slot
upload_tile:
    move.w  d5, d1
    lsl.w   #2, d1
    addi.w  #S2_PATTERN, d1
    lsl.w   #5, d1
    move.w  d1, d2
    andi.w  #0x3fff, d2
    ori.w   #0x4000, d2
    swap    d2
    move.w  d1, d3
    rol.w   #2, d3
    andi.w  #3, d3
    move.w  d3, d2
    move.l  d2, VDP_CTRL
    moveq   #0, d1
    move.w  d0, d1
    lsl.l   #7, d1
    addi.l  #TILE_DATA, d1
    move.l  d1, d2
    swap    d2
    lsr.w   #3, d2
    move.b  d2, MAPPER7
    andi.l  #0x7ffff, d1
    addi.l  #WINDOW, d1
    movea.l d1, a3
    lea     VDP_DATA, a4
    moveq   #31, d2
3:  move.l  (a3)+, (a4)
    dbra    d2, 3b
    rts

| d5 slot
s2_release:
    move.w  d5, d1
    add.w   d1, d1
    lea     S2_REF, a3
    subq.w  #1, 0(a3,d1.w)
    bne.s   9f
    lea     S2_KEY, a3
    move.w  0(a3,d1.w), d0
    bsr.w   hash_lookup
    tst.w   d1
    bmi.s   8f
    bsr.w   hash_delete
8:  move.w  free_top, d1
    lea     FREE_STACK, a3
    move.b  d5, 0(a3,d1.w)
    addq.w  #1, d1
    move.w  d1, free_top
9:  rts

| ---------------------------------------------------------------- plane B

| r_col, r_row: arcade cell to draw from the store into the plane ring
render_cell:
    move.w  r_col, d6
    move.w  r_row, d7
    move.w  d6, d0
    andi.w  #31, d0
    move.w  d7, d1
    andi.w  #15, d1
    lsl.w   #5, d1
    add.w   d1, d0
    lea     RING_SLOT, a0
    adda.w  d0, a0
    moveq   #0, d5
    move.b  (a0), d5
    cmpi.b  #0xff, d5
    beq.s   1f
    move.l  a0, -(sp)
    bsr.w   s2_release
    movea.l (sp)+, a0
    move.b  #0xff, (a0)
1:  move.w  d6, d0
    andi.w  #31, d0
    lsl.w   #2, d0
    lea     COVER, a1
    adda.w  d0, a1
    move.w  d7, d1
    andi.w  #31, d1
    move.l  (a1), d2
    bclr    d1, d2
    move.l  d2, (a1)
    move.w  #S3_W, s3_pending
    move.w  d6, d0
    andi.w  #63, d0
    lsl.w   #5, d0
    move.w  d7, d1
    andi.w  #31, d1
    or.w    d1, d0
    lsl.w   #2, d0
    lea     S2_STORE, a1
    adda.w  d0, a1
    move.w  2(a1), r_attr
    move.w  (a1), d0
    bmi.w   cell_blank
    lea     TILE_FLAGS, a1
    move.b  0(a1,d0.w), d1
    beq.w   cell_blank
    move.l  a0, -(sp)
    move.w  d1, -(sp)
    bsr.w   s2_acquire
    move.w  (sp)+, d1
    movea.l (sp)+, a0
    tst.w   d5
    bmi.w   cell_blank
    move.b  d5, (a0)
    btst    #1, d1
    beq.s   12f
    move.w  d6, d0
    andi.w  #31, d0
    lsl.w   #2, d0
    lea     COVER, a1
    adda.w  d0, a1
    move.w  d7, d1
    andi.w  #31, d1
    move.l  (a1), d2
    bset    d1, d2
    move.l  d2, (a1)
12:
    lsl.w   #2, d5
    addi.w  #S2_PATTERN, d5
    move.w  r_attr, d0
    move.w  d0, d1
    andi.w  #0x60, d1
    lsl.w   #6, d1
    ori.w   #0xc000, d1
    or.w    d1, d5
    moveq   #0, d2
    btst    #5, d0
    beq.s   2f
    moveq   #2, d2
2:  moveq   #0, d3
    btst    #6, d0
    beq.s   3f
    moveq   #1, d3
3:  move.w  d5, d0
    add.w   d2, d0
    add.w   d3, d0
    move.w  d0, a2
    move.w  d5, d0
    addq.w  #2, d0
    sub.w   d2, d0
    add.w   d3, d0
    move.w  d0, a3
    move.w  d5, d0
    add.w   d2, d0
    addq.w  #1, d0
    sub.w   d3, d0
    move.w  d0, a4
    move.w  d5, d0
    addq.w  #3, d0
    sub.w   d2, d0
    sub.w   d3, d0
    move.w  d0, a5
    bra.s   write_cell
cell_blank:
    suba.l  a2, a2
    suba.l  a3, a3
    suba.l  a4, a4
    suba.l  a5, a5
write_cell:
    move.w  d7, d0
    andi.w  #15, d0
    lsl.w   #8, d0
    move.w  d6, d1
    andi.w  #31, d1
    lsl.w   #2, d1
    add.w   d1, d0
    addi.w  #PLANE_B, d0
    bsr.s   vram_write_at
    lea     VDP_DATA, a1
    move.w  a2, (a1)
    move.w  a3, (a1)
    addi.w  #128, d0
    bsr.s   vram_write_at
    move.w  a4, (a1)
    move.w  a5, (a1)
    rts

| d0 VRAM address
vram_write_at:
    move.w  d0, d1
    andi.w  #0x3fff, d1
    ori.w   #0x4000, d1
    move.w  d1, VDP_CTRL
    move.w  d0, d1
    rol.w   #2, d1
    andi.w  #3, d1
    move.w  d1, VDP_CTRL
    rts

| d3 arcade column: releases the tiles of its 16 ring cells
clear_column:
    andi.w  #31, d3
    move.w  d3, d0
    lsl.w   #2, d0
    lea     COVER, a0
    clr.l   0(a0,d0.w)
    lea     RING_SLOT, a0
    adda.w  d3, a0
    move.w  #15, -(sp)
1:  moveq   #0, d5
    move.b  (a0), d5
    cmpi.b  #0xff, d5
    beq.s   2f
    move.b  #0xff, (a0)
    move.l  a0, -(sp)
    bsr.w   s2_release
    movea.l (sp)+, a0
2:  lea     32(a0), a0
    subq.w  #1, (sp)
    bpl.s   1b
    addq.l  #2, sp
    rts

| d3 arcade column
render_column:
    move.w  d3, r_col
    move.w  s2_row0, r_row
    move.w  #15, -(sp)
1:  bsr.w   render_cell
    move.w  r_row, d0
    addq.w  #1, d0
    andi.w  #63, d0
    move.w  d0, r_row
    subq.w  #1, (sp)
    bpl.s   1b
    addq.l  #2, sp
    rts

| Called once per frame from VBlank (interrupts masked).
update_scroll2:
    move.w  IO_SHADOW + 0x110, d0
    addi.w  #96, d0
    andi.w  #0x3ff, d0
    move.w  d0, cam2_x
    move.w  d0, d2
    neg.w   d2
    andi.w  #0x3ff, d2
    move.w  d2, s2_hscroll
    move.w  IO_SHADOW + 0x112, d1
    addi.w  #16, d1
    andi.w  #0x3ff, d1
    move.w  d1, cam2_y
    move.w  d1, s2_vscroll
    lsr.w   #4, d0
    subq.w  #1, d0
    andi.w  #63, d0
    lsr.w   #4, d1
    andi.w  #63, d1
    tst.w   s2_valid
    beq.w   full_redraw
    tst.w   s2_full
    bne.w   full_redraw
    cmp.w   s2_row0, d1
    bne.w   full_redraw
    move.w  d0, d2
    sub.w   s2_col0, d2
    andi.w  #63, d2
    beq.w   process_dirty
    cmpi.w  #32, d2
    bhs.s   backward
    cmpi.w  #8, d2
    bhi.w   full_redraw
    subq.w  #1, d2
    move.w  d2, u_count
1:  move.w  s2_col0, d3
    bsr.w   clear_column
    move.w  s2_col0, d3
    addi.w  #S2_W, d3
    andi.w  #63, d3
    bsr.w   render_column
    move.w  s2_col0, d0
    addq.w  #1, d0
    andi.w  #63, d0
    move.w  d0, s2_col0
    subq.w  #1, u_count
    bpl.s   1b
    bra.w   process_dirty
backward:
    moveq   #64, d3
    sub.w   d2, d3
    cmpi.w  #8, d3
    bhi.s   full_redraw
    subq.w  #1, d3
    move.w  d3, u_count
2:  move.w  s2_col0, d3
    subq.w  #1, d3
    andi.w  #63, d3
    move.w  d3, s2_col0
    bsr.w   render_column
    move.w  s2_col0, d3
    addi.w  #S2_W, d3
    bsr.w   clear_column
    subq.w  #1, u_count
    bpl.s   2b
    bra.s   process_dirty

full_redraw:
    move.w  d0, s2_col0
    move.w  d1, s2_row0
    move.w  #1, s2_valid
    clr.w   s2_full
    clr.w   dirty_count
    move.w  #31, u_count
5:  move.w  u_count, d3
    bsr.w   clear_column
    subq.w  #1, u_count
    bpl.s   5b
    move.w  #S2_W - 1, u_count
3:  move.w  s2_col0, d3
    add.w   u_count, d3
    andi.w  #63, d3
    bsr.w   render_column
    subq.w  #1, u_count
    bpl.s   3b
    bra.s   scan_palette

process_dirty:
    move.w  dirty_count, d0
    beq.s   scan_palette
    clr.w   dirty_count
    subq.w  #1, d0
    move.w  d0, u_count
4:  move.w  u_count, d0
    add.w   d0, d0
    lea     DIRTY, a0
    move.w  0(a0,d0.w), d0
    move.w  d0, d1
    andi.w  #0xff, d1
    lsr.w   #8, d0
    move.w  d0, r_col
    move.w  d1, r_row
    bsr.w   render_cell
    subq.w  #1, u_count
    bpl.s   4b

| Every 32 frames: the most used playfield palette on screen goes to CRAM line 2.
scan_palette:
    move.l  hal_frames, d0
    andi.w  #31, d0
    bne.s   9f
    lea     S2_PAL_COUNT, a0
    moveq   #15, d0
5:  clr.l   (a0)+
    dbra    d0, 5b
    lea     S2_PAL_COUNT, a0
    lea     S2_STORE + 2, a1
    move.w  s2_col0, d6
    addq.w  #1, d6
    moveq   #10, d5
6:  move.w  s2_row0, d7
    moveq   #7, d4
7:  move.w  d6, d0
    andi.w  #63, d0
    lsl.w   #5, d0
    move.w  d7, d1
    andi.w  #31, d1
    or.w    d1, d0
    lsl.w   #2, d0
    move.w  0(a1,d0.w), d0
    andi.w  #31, d0
    add.w   d0, d0
    addq.w  #1, 0(a0,d0.w)
    addq.w  #2, d7
    dbra    d4, 7b
    addq.w  #2, d6
    dbra    d5, 6b
    moveq   #0, d1
    moveq   #0, d2
    moveq   #31, d0
8:  move.w  (a0)+, d3
    cmp.w   d1, d3
    bls.s   10f
    move.w  d3, d1
    moveq   #31, d2
    sub.w   d0, d2
10: dbra    d0, 8b
    move.w  d2, s2_pal
9:  rts

| ---------------------------------------------------------------- store access

| d0 address in the arcade scroll 2 table -> d4 store offset, d2 column, d3 row
s2_offset:
    move.w  d0, d4
    subi.w  #0xc000, d4
    andi.w  #0x3ffe, d4
    move.w  d4, d3
    lsr.w   #8, d3
    andi.w  #0x30, d3
    move.w  d4, d2
    lsr.w   #2, d2
    andi.w  #15, d2
    or.w    d2, d3
    move.w  d4, d2
    lsr.w   #6, d2
    andi.w  #63, d2
    andi.w  #2, d4
    move.w  d2, -(sp)
    lsl.w   #5, d2
    move.w  d3, -(sp)
    andi.w  #31, d3
    or.w    d3, d2
    lsl.w   #2, d2
    or.w    d2, d4
    move.w  (sp)+, d3
    move.w  (sp)+, d2
    rts

| d0 address -> d1 word
s2_read:
    movem.l d2-d4/a1, -(sp)
    bsr.s   s2_offset
    lea     S2_STORE, a1
    move.w  0(a1,d4.w), d1
    movem.l (sp)+, d2-d4/a1
    rts

| d0 address, d1 word
s2_write:
    movem.l d2-d4/a1, -(sp)
    bsr.s   s2_offset
    lea     S2_STORE, a1
    move.w  d1, 0(a1,d4.w)
    tst.w   s2_valid
    beq.s   9f
    move.w  d2, d4
    sub.w   s2_col0, d4
    andi.w  #63, d4
    cmpi.w  #S2_W, d4
    bhs.s   9f
    move.w  d3, d4
    sub.w   s2_row0, d4
    andi.w  #63, d4
    cmpi.w  #16, d4
    bhs.s   9f
    move.w  dirty_count, d4
    cmpi.w  #64, d4
    blo.s   1f
    move.w  #1, s2_full
    bra.s   9f
1:  lsl.w   #8, d2
    or.w    d3, d2
    add.w   d4, d4
    lea     DIRTY, a1
    move.w  d2, 0(a1,d4.w)
    lsr.w   #1, d4
    addq.w  #1, d4
    move.w  d4, dirty_count
9:  movem.l (sp)+, d2-d4/a1
    rts

| d0 24-bit address in arcade video RAM -> d1 word
gfx_read_w:
    cmpi.l  #S2_BASE, d0
    blo.s   1f
    cmpi.l  #S2_END, d0
    bhs.s   2f
    bra.w   s2_read
2:  cmpi.l  #S3_END, d0
    bhs.s   1f
    bra.w   s3_read
1:  moveq   #0, d1
    rts

| d0 24-bit address in arcade video RAM, d1 word
gfx_write_w:
    cmpi.l  #S2_BASE, d0
    blo.s   1f
    cmpi.l  #S2_END, d0
    bhs.s   2f
    bra.w   s2_write
2:  cmpi.l  #S3_END, d0
    bhs.s   1f
    bra.w   s3_write
1:  rts

| ---------------------------------------------------------------- fast paths

| TRAP #9, #10, #11 replace the arcade's block writer, long copier and table clear.
trap_meta:
    hal_enter
    bsr.s   hal_meta
    hal_leave
    rte

trap_copy:
    hal_enter
    bsr.s   hal_copy
    hal_leave
    rte

trap_fill:
    hal_enter
    bsr.w   hal_fill
    hal_leave
    move.l  #ARCADE_FILL_END, 2(sp)
    rte

| (a3)+ -> (a0)+ twice, a0 += 0x38, twice more.
hal_meta:
    movem.l d0-d1, -(sp)
    bsr.s   copy_long
    bsr.s   copy_long
    lea     0x38(a0), a0
    bsr.s   copy_long
    bsr.s   copy_long
    movem.l (sp)+, d0-d1
    rts

| "move.l (a1)+,(a0)+ / dbra d4": copies d4 + 1 longs.
hal_copy:
    movem.l d0-d1/a3, -(sp)
    movea.l a1, a3
1:  bsr.s   copy_long
    dbra    d4, 1b
    movea.l a3, a1
    movem.l (sp)+, d0-d1/a3
    rts

| (a3)+ -> (a0)+, long, with arcade video RAM served by the hardware layer
copy_long:
    move.l  a0, d0
    andi.l  #0xffffff, d0
    cmpi.l  #GFX_LO, d0
    blo.s   1f
    cmpi.l  #GFX_HI, d0
    bhs.s   1f
    move.w  (a3)+, d1
    bsr.w   gfx_write_w
    addq.l  #2, d0
    move.w  (a3)+, d1
    bsr.w   gfx_write_w
    addq.l  #4, a0
    rts
1:  move.l  (a3)+, (a0)+
    rts

| The arcade's table clear loop at 0xba0: fill [a0, a1) with d0, d1 pairs.
hal_fill:
    movem.l d2-d3/a2, -(sp)
    move.l  a0, d2
    andi.l  #0xffffff, d2
    cmpi.l  #GFX_LO, d2
    blo.s   3f
    cmpi.l  #GFX_HI, d2
    bhs.s   3f
    cmpi.l  #S2_BASE, d2
    bne.s   5f
    lea     S2_STORE, a2
    move.w  #2047, d3
1:  move.w  d0, (a2)+
    move.w  d1, (a2)+
    dbra    d3, 1b
    move.w  #1, s2_full
    bra.s   2f
5:  cmpi.l  #S3_BASE, d2
    bne.s   2f
    lea     S3_STORE, a2
    move.w  #1023, d3
6:  move.w  d0, (a2)+
    move.w  d1, (a2)+
    dbra    d3, 6b
    move.w  #1, s3_full
2:  movea.l a1, a0
    bra.s   4f
3:  move.w  d0, (a0)+
    move.w  d1, (a0)+
    cmpa.l  a1, a0
    blt.s   3b
4:  movem.l (sp)+, d2-d3/a2
    rts

| ---------------------------------------------------------------- TRAP #8

| Each instruction the build replaced with TRAP #8 is listed in PATCH_TABLE with
| its original words. The handler decodes and performs it, sending accesses to
| arcade video RAM through gfx_read_w / gfx_write_w, sets N and Z, and resumes
| after the original instruction. Handles MOVE, CLR, AND and OR with any
| addressing mode except those on A7.
gfx_trap:
    hal_enter
    movem.l d0-d7/a0-a6, -(sp)
    movea.l sp, a4
    movea.l 60(a4), a0
    move.l  6(a0), d0
    subq.l  #2, d0
    move.w  d0, d1
    lsr.w   #1, d1
    andi.w  #1023, d1
    add.w   d1, d1
    lea     PATCH_HASH, a1
    lea     PATCH_TABLE + 2, a0
1:  move.w  0(a1,d1.w), d5
    bmi.w   trap_missing
    cmp.l   0(a0,d5.w), d0
    beq.s   2f
    addq.w  #2, d1
    andi.w  #2047, d1
    bra.s   1b
2:  lea     0(a0,d5.w), a6
    lea     8(a6), a5
    move.w  6(a6), d7
    move.w  d7, d0
    andi.w  #0xc000, d0
    beq.s   emu_move
    move.w  d7, d0
    andi.w  #0xff00, d0
    cmpi.w  #0x4200, d0
    beq.w   emu_clr
    move.w  d7, d0
    andi.w  #0xb000, d0
    cmpi.w  #0x8000, d0
    beq.w   emu_logic
    bra.w   trap_missing

emu_move:
    move.w  d7, d0
    rol.w   #4, d0
    andi.w  #3, d0
    move.b  move_sizes(pc,d0.w), d2
    ext.w   d2
    move.w  d7, d0
    lsr.w   #3, d0
    andi.w  #7, d0
    move.w  d7, d1
    andi.w  #7, d1
    bsr.w   ea_resolve
    bsr.w   op_read
    move.l  d4, d6
    move.w  d7, d0
    lsr.w   #6, d0
    andi.w  #7, d0
    move.w  d7, d1
    rol.w   #7, d1
    andi.w  #7, d1
    bsr.w   ea_resolve
    move.l  d6, d4
    bsr.w   op_write
    move.l  d6, d4
    bra.w   finish
move_sizes:
    .byte   0, 1, 4, 2
size_codes:
    .byte   1, 2, 4, 0

emu_clr:
    move.w  d7, d0
    lsr.w   #6, d0
    andi.w  #3, d0
    move.b  size_codes(pc,d0.w), d2
    ext.w   d2
    move.w  d7, d0
    lsr.w   #3, d0
    andi.w  #7, d0
    move.w  d7, d1
    andi.w  #7, d1
    bsr.w   ea_resolve
    moveq   #0, d4
    bsr.w   op_write
    moveq   #0, d4
    bra.w   finish

| AND and OR, both directions
emu_logic:
    move.w  d7, d0
    lsr.w   #6, d0
    andi.w  #3, d0
    move.b  size_codes(pc,d0.w), d2
    ext.w   d2
    move.w  d7, d1
    rol.w   #7, d1
    andi.w  #7, d1
    lsl.w   #2, d1
    move.l  0(a4,d1.w), d5
    move.w  d7, d0
    lsr.w   #3, d0
    andi.w  #7, d0
    move.w  d7, d1
    andi.w  #7, d1
    bsr.w   ea_resolve
    bsr.w   op_read
    btst    #14, d7
    beq.s   1f
    and.l   d5, d4
    bra.s   2f
1:  or.l    d5, d4
2:  move.l  d4, d6
    btst    #8, d7
    beq.s   3f
    bsr.w   op_write
    bra.s   4f
3:  move.w  d7, d1
    rol.w   #7, d1
    andi.w  #7, d1
    lsl.w   #2, d1
    lea     0(a4,d1.w), a0
    moveq   #1, d3
    move.l  d6, d4
    bsr.w   op_write
4:  move.l  d6, d4
    bra.w   finish

| d0 mode, d1 register, d2 size -> d3 kind: 0 memory at a0, 1 register at a0, 2 immediate in d4
| clobbers d0, d1, a1; keeps d2, d5-d7, a4-a6
ea_resolve:
    add.w   d0, d0
    move.w  ea_jump(pc,d0.w), d0
    jmp     ea_jump(pc,d0.w)
ea_jump:
    .word   ea_dn - ea_jump, ea_an - ea_jump, ea_ind - ea_jump, ea_post - ea_jump
    .word   ea_pre - ea_jump, ea_d16 - ea_jump, ea_idx - ea_jump, ea_m7 - ea_jump
ea_dn:
    lsl.w   #2, d1
    lea     0(a4,d1.w), a0
    moveq   #1, d3
    rts
ea_an:
    lsl.w   #2, d1
    lea     32(a4,d1.w), a0
    moveq   #1, d3
    rts
ea_ind:
    lsl.w   #2, d1
    movea.l 32(a4,d1.w), a0
    moveq   #0, d3
    rts
ea_post:
    lsl.w   #2, d1
    lea     32(a4,d1.w), a1
    movea.l (a1), a0
    move.l  a0, d0
    add.l   d2, d0
    move.l  d0, (a1)
    moveq   #0, d3
    rts
ea_pre:
    lsl.w   #2, d1
    lea     32(a4,d1.w), a1
    move.l  (a1), d0
    sub.l   d2, d0
    move.l  d0, (a1)
    movea.l d0, a0
    moveq   #0, d3
    rts
ea_d16:
    lsl.w   #2, d1
    movea.l 32(a4,d1.w), a0
    adda.w  (a5)+, a0
    moveq   #0, d3
    rts
ea_idx:
    lsl.w   #2, d1
    movea.l 32(a4,d1.w), a0
idx_common:
    move.w  (a5)+, d0
    move.w  d0, d1
    rol.w   #4, d1
    andi.w  #15, d1
    lsl.w   #2, d1
    move.l  0(a4,d1.w), d1
    btst    #11, d0
    bne.s   1f
    ext.l   d1
1:  adda.l  d1, a0
    ext.w   d0
    adda.w  d0, a0
    moveq   #0, d3
    rts
ea_m7:
    move.l  a5, d0
    sub.l   a6, d0
    subq.l  #6, d0
    add.l   (a6), d0
    tst.w   d1
    bne.s   1f
    movea.w (a5)+, a0
    moveq   #0, d3
    rts
1:  cmpi.w  #1, d1
    bne.s   2f
    movea.l (a5)+, a0
    moveq   #0, d3
    rts
2:  cmpi.w  #2, d1
    bne.s   3f
    movea.l d0, a0
    adda.w  (a5)+, a0
    moveq   #0, d3
    rts
3:  cmpi.w  #3, d1
    bne.s   4f
    movea.l d0, a0
    bra.s   idx_common
4:  moveq   #2, d3
    cmpi.w  #4, d2
    beq.s   5f
    moveq   #0, d4
    move.w  (a5)+, d4
    rts
5:  move.l  (a5)+, d4
    rts

| d3 kind, a0, d2 size -> d4 value
op_read:
    cmpi.w  #2, d3
    beq.s   9f
    cmpi.w  #1, d3
    bne.s   mem_read
    cmpi.w  #4, d2
    bne.s   1f
    move.l  (a0), d4
    rts
1:  moveq   #0, d4
    cmpi.w  #2, d2
    bne.s   2f
    move.w  2(a0), d4
    rts
2:  move.b  3(a0), d4
9:  rts
mem_read:
    move.l  a0, d0
    andi.l  #0xffffff, d0
    cmpi.l  #GFX_LO, d0
    blo.s   5f
    cmpi.l  #GFX_HI, d0
    bhs.s   5f
    cmpi.w  #4, d2
    bne.s   3f
    bsr.w   gfx_read_w
    move.w  d1, d4
    swap    d4
    addq.l  #2, d0
    bsr.w   gfx_read_w
    move.w  d1, d4
    rts
3:  btst    #0, d0
    beq.s   4f
    bclr    #0, d0
    bsr.w   gfx_read_w
    moveq   #0, d4
    move.b  d1, d4
    rts
4:  bsr.w   gfx_read_w
    moveq   #0, d4
    move.w  d1, d4
    cmpi.w  #1, d2
    bne.s   9b
    lsr.w   #8, d4
    rts
5:  cmpi.w  #4, d2
    bne.s   6f
    move.l  (a0), d4
    rts
6:  moveq   #0, d4
    cmpi.w  #2, d2
    bne.s   7f
    move.w  (a0), d4
    rts
7:  move.b  (a0), d4
    rts

| d3 kind, a0, d2 size, d4 value
op_write:
    cmpi.w  #1, d3
    bne.s   mem_write
    cmpi.w  #4, d2
    bne.s   1f
    move.l  d4, (a0)
    rts
1:  cmpi.w  #2, d2
    bne.s   2f
    move.w  d4, 2(a0)
    rts
2:  move.b  d4, 3(a0)
    rts
mem_write:
    move.l  a0, d0
    andi.l  #0xffffff, d0
    cmpi.l  #GFX_LO, d0
    blo.s   5f
    cmpi.l  #GFX_HI, d0
    bhs.s   5f
    cmpi.w  #4, d2
    bne.s   3f
    move.l  d4, d1
    swap    d1
    bsr.w   gfx_write_w
    addq.l  #2, d0
    move.w  d4, d1
    bra.w   gfx_write_w
3:  cmpi.w  #2, d2
    bne.s   4f
    move.w  d4, d1
    bra.w   gfx_write_w
4:  rts
5:  cmpi.w  #4, d2
    bne.s   6f
    move.l  d4, (a0)
    rts
6:  cmpi.w  #2, d2
    bne.s   7f
    move.w  d4, (a0)
    rts
7:  move.b  d4, (a0)
    rts

| d4 result, d2 size: sets N and Z, clears V and C, keeps X; resumes after the original instruction
finish:
    movea.l 60(a4), a1
    move.b  5(a1), d0
    andi.b  #0x10, d0
    cmpi.w  #4, d2
    beq.s   1f
    cmpi.w  #2, d2
    beq.s   2f
    tst.b   d4
    bra.s   3f
1:  tst.l   d4
    bra.s   3f
2:  tst.w   d4
3:  smi     d1
    seq     d3
    andi.b  #8, d1
    andi.b  #4, d3
    or.b    d1, d0
    or.b    d3, d0
    move.b  d0, 5(a1)
    move.l  (a6), d0
    moveq   #0, d1
    move.w  4(a6), d1
    add.l   d1, d0
    move.l  d0, 6(a1)
    movem.l (sp)+, d0-d7/a0-a6
    hal_leave
    rte

trap_missing:
    jmp     hal_crash

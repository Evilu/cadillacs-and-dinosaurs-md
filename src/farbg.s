| Far background: arcade scroll 3 (64 x 64 tiles of 32 x 32) on plane A, low
| priority, behind the playfield. Same scheme as the playfield: a RAM store of
| 64 columns x 16 rows (arcade rows mod 16), a ring of 16 columns x 8 rows on
| the plane, and reference-counted 16-pattern VRAM slots shared through the
| playfield's hash table (keys are tile code | 0x8000). Cells the playfield's
| fully opaque tiles hide (with a 16 pixel margin to the sides) get no slot:
| VRAM holds fewer far tiles than a screen shows. When the layers move against
| each other or the playfield redraws, a sweep rechecks every column, two per
| odd frame.

    .equ S3_BASE,       0x910000
    .equ S3_END,        0x914000
    .equ S3_STORE,      0xff6000    | (col << 4 | row & 15) * 4: code word, attribute word
    .equ PLANE_A,       0xe000
    .equ S3_SLOTS,      41
    .equ S3_W,          11          | columns drawn: 320 pixels span at most 11
    .equ S3_REF,        0xff1a00
    .equ S3_KEY,        0xff1a60
    .equ S3_FREE,       0xff1ac0
    .equ RING3,         0xff1af0    | 16 x 8 ring cells: slot, 0xff none
    .equ DIRTY3,        0xff1b70    | 32 words: col << 8 | row
    .equ S3_VARS,       0xff1bb0
    .equ s3_free_top,   S3_VARS
    .equ s3_dirty,      S3_VARS + 2
    .equ s3_valid,      S3_VARS + 4
    .equ s3_col0,       S3_VARS + 6
    .equ s3_row0,       S3_VARS + 8
    .equ s3_full,       S3_VARS + 10
    .equ s3_hscroll,    S3_VARS + 12
    .equ s3_vscroll,    S3_VARS + 14
    .equ s3_count,      S3_VARS + 18
    .equ s3_refresh,    S3_VARS + 16
    .equ t_col,         S3_VARS + 20
    .equ t_row,         S3_VARS + 22
    .equ cam3_x,        S3_VARS + 24
    .equ cam3_y,        S3_VARS + 26
    .equ s3_sweep,      S3_VARS + 28
    .equ s3_pending,    S3_VARS + 30
    .equ s3_rel_x,      S3_VARS + 96
    .equ s3_rel_y,      S3_VARS + 98
    .equ s3_last_y,     S3_VARS + 100
    .equ t_pal,         S3_VARS + 102
    .equ s3_dirty_cols, S3_VARS + 104
    .equ TILE_FLAGS3,   0x1a0000    | per 32 x 32 tile code 0-0x1fff: nonzero if it has pixels
    .equ TILE3_DATA,    TILE_DATA   | 32 x 32 tile c: 16 patterns (column-major) at TILE3_DATA + c * 512

| First VRAM pattern of each slot: the main pattern area, then gaps in the table area
s3_slot_pat:
    .word   0x420, 0x430, 0x440, 0x450
    .word   0x460, 0x470, 0x480, 0x490, 0x4a0, 0x4b0, 0x4c0, 0x4d0, 0x4e0, 0x4f0
    .word   0x500, 0x510, 0x520, 0x530, 0x540, 0x550, 0x560, 0x570, 0x580, 0x590
    .word   0x5a0, 0x5b0, 0x5c0, 0x5d0, 0x5e0, 0x5f0
    .word   0x6a0, 0x6b0, 0x6c0, 0x6d0, 0x6e0, 0x6f0
    .word   0x7b4, 0x7c4, 0x7d4, 0x7e4, 0x781

s3_init:
    lea     S3_REF, a0
    moveq   #S3_SLOTS - 1, d0
1:  clr.w   (a0)+
    dbra    d0, 1b
    lea     S3_FREE, a0
    moveq   #0, d0
2:  move.b  d0, (a0)+
    addq.w  #1, d0
    cmpi.w  #S3_SLOTS, d0
    blt.s   2b
    move.w  #S3_SLOTS, s3_free_top
    lea     RING3, a0
    moveq   #127, d0
3:  move.b  #0xff, (a0)+
    dbra    d0, 3b
    clr.w   s3_dirty
    clr.w   s3_valid
    clr.w   s3_full
    clr.w   s3_sweep
    move.w  #S3_W, s3_pending
    rts

| d6 far column, d7 far row -> EQ if the playfield's opaque cells hide it
far_covered:
    movem.l d0-d5/a1, -(sp)
    move.w  d6, d0
    lsl.w   #5, d0
    sub.w   cam3_x, d0
    andi.w  #0x7ff, d0
    cmpi.w  #0x400, d0
    blo.s   1f
    subi.w  #0x800, d0
1:  move.w  d7, d1
    lsl.w   #5, d1
    sub.w   cam3_y, d1
    andi.w  #0x7ff, d1
    cmpi.w  #0x400, d1
    blo.s   2f
    subi.w  #0x800, d1
2:  move.w  d0, d2
    addi.w  #47, d2
    subi.w  #16, d0
    cmpi.w  #-16, d0
    bge.s   3f
    moveq   #-16, d0
3:  cmpi.w  #335, d2
    ble.s   4f
    move.w  #335, d2
4:  cmp.w   d2, d0
    bgt.s   8f
    move.w  d1, d3
    addi.w  #31, d3
    tst.w   d1
    bge.s   5f
    moveq   #0, d1
5:  cmpi.w  #239, d3
    ble.s   6f
    move.w  #239, d3
6:  cmp.w   d3, d1
    bgt.s   8f
    add.w   cam2_y, d1
    add.w   cam2_y, d3
    lsr.w   #4, d1
    lsr.w   #4, d3
    sub.w   d1, d3
    moveq   #2, d4
    lsl.l   d3, d4
    subq.l  #1, d4
    andi.w  #31, d1
    rol.l   d1, d4
    add.w   cam2_x, d0
    add.w   cam2_x, d2
    asr.w   #4, d0
    asr.w   #4, d2
    sub.w   d0, d2
    moveq   #-1, d5
    lea     COVER, a1
7:  move.w  d0, d1
    andi.w  #31, d1
    lsl.w   #2, d1
    and.l   0(a1,d1.w), d5
    addq.w  #1, d0
    dbra    d2, 7b
    and.l   d4, d5
    cmp.l   d4, d5
    movem.l (sp)+, d0-d5/a1
    rts
8:  cmp.w   d0, d0
    movem.l (sp)+, d0-d5/a1
    rts

| d3 arcade column: redraws the cells whose slot no longer matches what the playfield hides
sweep_column3:
    move.w  d3, t_col
    move.w  s3_row0, t_row
    move.w  #7, -(sp)
1:  move.w  t_col, d6
    move.w  t_row, d7
    move.w  d6, d0
    andi.w  #15, d0
    move.w  d7, d1
    andi.w  #7, d1
    lsl.w   #4, d1
    add.w   d1, d0
    lea     RING3, a0
    moveq   #0, d2
    cmpi.b  #0xff, 0(a0,d0.w)
    sne     d2
    moveq   #0, d3
    move.w  d6, d0
    andi.w  #63, d0
    lsl.w   #4, d0
    move.w  d7, d1
    andi.w  #15, d1
    or.w    d1, d0
    lsl.w   #2, d0
    lea     S3_STORE, a1
    move.w  0(a1,d0.w), d0
    cmpi.w  #0x1fff, d0
    bhi.s   2f
    lea     TILE_FLAGS3, a1
    tst.b   0(a1,d0.w)
    beq.s   2f
    bsr.w   far_covered
    sne     d3
2:  cmp.b   d2, d3
    beq.s   3f
    bsr.w   render_cell3
3:  move.w  t_row, d0
    addq.w  #1, d0
    andi.w  #63, d0
    move.w  d0, t_row
    subq.w  #1, (sp)
    bpl.s   1b
    addq.l  #2, sp
    rts

| d0 tile code -> d5 slot or -1
s3_acquire:
    ori.w   #0x8000, d0
    move.w  t_pal, d1
    andi.w  #31, d1
    move.b  d1, h_pal
    bsr.w   hash_lookup
    tst.w   d1
    bmi.s   1f
    move.w  d1, d5
    add.w   d1, d1
    lea     S3_REF, a3
    addq.w  #1, 0(a3,d1.w)
    bclr    #2, 0(a3,d1.w)
    bne.s   s3_upload
    rts
1:  move.w  s3_free_top, d1
    bne.s   2f
    moveq   #-1, d5
    rts
2:  subq.w  #1, d1
    move.w  d1, s3_free_top
    lea     S3_FREE, a3
    moveq   #0, d5
    move.b  0(a3,d1.w), d5
    move.w  d0, (a2)
    move.b  h_pal, 2(a2)
    move.b  d5, 3(a2)
    moveq   #0, d1
    move.b  h_pal, d1
    ror.w   #5, d1
    addq.w  #1, d1
    move.w  d1, -(sp)
    move.w  d5, d1
    add.w   d1, d1
    lea     S3_REF, a3
    move.w  (sp)+, 0(a3,d1.w)
    lea     S3_KEY, a3
    move.w  d0, 0(a3,d1.w)
s3_upload:
    lea     s3_slot_pat(pc), a3
    move.w  0(a3,d1.w), d1
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
    andi.w  #0x1fff, d1
    lsl.l   #8, d1
    add.l   d1, d1
    addi.l  #TILE3_DATA, d1
    move.l  d1, d2
    swap    d2
    lsr.w   #3, d2
    move.b  d2, MAPPER7
    andi.l  #0x7ffff, d1
    addi.l  #WINDOW, d1
    movea.l d1, a3
    move.w  #255, d2
    move.w  t_pal, d1
    andi.w  #31, d1
    addi.w  #32, d1
    bra.w   remap_copy

| d5 slot
s3_release:
    move.w  d5, d1
    add.w   d1, d1
    lea     S3_REF, a3
    subq.w  #1, 0(a3,d1.w)
    move.w  0(a3,d1.w), d0
    move.w  d0, d2
    andi.w  #0x3ff, d2
    bne.s   9f
    rol.w   #5, d0
    move.b  d0, h_pal
    lea     S3_KEY, a3
    move.w  0(a3,d1.w), d0
    bsr.w   hash_lookup
    tst.w   d1
    bmi.s   8f
    bsr.w   hash_delete
8:  move.w  s3_free_top, d1
    lea     S3_FREE, a3
    move.b  d5, 0(a3,d1.w)
    addq.w  #1, d1
    move.w  d1, s3_free_top
9:  rts

| t_col, t_row: arcade cell to draw from the store into the plane A ring
render_cell3:
    move.w  t_col, d6
    move.w  t_row, d7
    move.w  d6, d0
    andi.w  #15, d0
    move.w  d7, d1
    andi.w  #7, d1
    lsl.w   #4, d1
    add.w   d1, d0
    lea     RING3, a0
    adda.w  d0, a0
    moveq   #0, d5
    move.b  (a0), d5
    cmpi.b  #0xff, d5
    beq.s   1f
    move.l  a0, -(sp)
    bsr.w   s3_release
    movea.l (sp)+, a0
    move.b  #0xff, (a0)
1:  move.w  d6, d0
    andi.w  #63, d0
    lsl.w   #4, d0
    move.w  d7, d1
    andi.w  #15, d1
    or.w    d1, d0
    lsl.w   #2, d0
    lea     S3_STORE, a1
    adda.w  d0, a1
    move.w  2(a1), -(sp)
    move.w  2(a1), t_pal
    move.w  (a1), d0
    cmpi.w  #0x1fff, d0
    bhi.s   3f
    lea     TILE_FLAGS3, a1
    tst.b   0(a1,d0.w)
    beq.s   3f
    bsr.w   far_covered
    beq.s   3f
    move.l  a0, -(sp)
    bsr.w   s3_acquire
    movea.l (sp)+, a0
    tst.w   d5
    bpl.s   30f
    move.w  #S3_W, s3_pending
    bra.s   3f
30:
    move.b  d5, (a0)
    add.w   d5, d5
    lea     s3_slot_pat(pc), a1
    move.w  0(a1,d5.w), d5
    move.w  (sp)+, d0
    andi.w  #0x60, d0
    lsl.w   #6, d0
    ori.w   #0x6000, d0
    move.w  d0, d4
    bra.s   4f
3:  addq.l  #2, sp
    moveq   #-1, d5
4:  lea     VDP_DATA, a1
    moveq   #0, d2
5:  move.w  d7, d0
    andi.w  #7, d0
    lsl.w   #2, d0
    add.w   d2, d0
    lsl.w   #7, d0
    move.w  d6, d1
    andi.w  #15, d1
    lsl.w   #3, d1
    add.w   d1, d0
    addi.w  #PLANE_A, d0
    bsr.w   vram_write_at
    moveq   #0, d3
6:  tst.w   d5
    bpl.s   7f
    move.w  #0, (a1)
    bra.s   8f
7:  move.w  d3, d0
    btst    #11, d4
    beq.s   10f
    neg.w   d0
    addq.w  #3, d0
10: lsl.w   #2, d0
    move.w  d2, d1
    btst    #12, d4
    beq.s   11f
    neg.w   d1
    addq.w  #3, d1
11: add.w   d1, d0
    add.w   d5, d0
    or.w    d4, d0
    move.w  d0, (a1)
8:  addq.w  #1, d3
    cmpi.w  #4, d3
    blt.s   6b
    addq.w  #1, d2
    cmpi.w  #4, d2
    blt.s   5b
    rts

| d3 arcade column: releases the tiles of its 8 ring cells
clear_column3:
    andi.w  #15, d3
    lea     RING3, a0
    adda.w  d3, a0
    move.w  #7, -(sp)
1:  moveq   #0, d5
    move.b  (a0), d5
    cmpi.b  #0xff, d5
    beq.s   2f
    move.b  #0xff, (a0)
    move.l  a0, -(sp)
    bsr.w   s3_release
    movea.l (sp)+, a0
2:  lea     16(a0), a0
    subq.w  #1, (sp)
    bpl.s   1b
    addq.l  #2, sp
    rts

| d3 arcade column
render_column3:
    move.w  d3, t_col
    move.w  s3_row0, t_row
    move.w  #7, -(sp)
1:  bsr.w   render_cell3
    move.w  t_row, d0
    addq.w  #1, d0
    andi.w  #63, d0
    move.w  d0, t_row
    subq.w  #1, (sp)
    bpl.s   1b
    addq.l  #2, sp
    rts

update_scroll3:
    move.w  IO_SHADOW + 0x114, d0
    addi.w  #96, d0
    andi.w  #0x7ff, d0
    move.w  d0, cam3_x
    move.w  d0, d2
    neg.w   d2
    andi.w  #0x3ff, d2
    move.w  d2, s3_hscroll
    move.w  IO_SHADOW + 0x116, d1
    addi.w  #16, d1
    andi.w  #0x7ff, d1
    move.w  d1, cam3_y
    move.w  d1, d2
    andi.w  #0x3ff, d2
    move.w  d2, s3_vscroll
    lsr.w   #5, d0
    andi.w  #63, d0
    lsr.w   #5, d1
    andi.w  #63, d1
    tst.w   s3_valid
    beq.w   3f
    tst.w   s3_full
    bne.w   3f
    tst.w   s3_refresh
    beq.s   21f
    clr.w   s3_refresh
    clr.w   s3_dirty
    clr.w   s3_dirty_cols
    bsr.w   render_window3
    bra.w   6f
21: move.w  d1, d2
    sub.w   s3_row0, d2
    andi.w  #63, d2
    beq.s   23f
    cmpi.w  #1, d2
    bne.s   22f
    move.w  s3_row0, d3
    addq.w  #8, d3
    move.w  d1, s3_row0
    bsr.w   render_row3
    bra.w   update_scroll3
22: cmpi.w  #63, d2
    bne.w   3f
    move.w  d1, s3_row0
    move.w  d1, d3
    bsr.w   render_row3
    bra.w   update_scroll3
23: move.w  d0, d2
    sub.w   s3_col0, d2
    andi.w  #63, d2
    beq.w   5f
    cmpi.w  #32, d2
    bhs.s   2f
    cmpi.w  #4, d2
    bhi.w   3f
    subq.w  #1, d2
    move.w  d2, s3_count
1:  move.w  s3_col0, d3
    bsr.w   clear_column3
    move.w  s3_col0, d3
    addi.w  #S3_W, d3
    andi.w  #63, d3
    bsr.w   render_column3
    move.w  s3_col0, d0
    addq.w  #1, d0
    andi.w  #63, d0
    move.w  d0, s3_col0
    subq.w  #1, s3_count
    bpl.s   1b
    bra.w   5f
2:  moveq   #64, d3
    sub.w   d2, d3
    cmpi.w  #4, d3
    bhi.s   3f
    subq.w  #1, d3
    move.w  d3, s3_count
7:  move.w  s3_col0, d3
    subq.w  #1, d3
    andi.w  #63, d3
    move.w  d3, s3_col0
    bsr.w   render_column3
    move.w  s3_col0, d3
    addi.w  #S3_W, d3
    bsr.w   clear_column3
    subq.w  #1, s3_count
    bpl.s   7b
    bra.w   5f
3:  move.w  d0, s3_col0
    move.w  d1, s3_row0
    move.w  #1, s3_valid
    clr.w   s3_full
    clr.w   s3_refresh
    clr.w   s3_dirty
    move.w  #0x8134, VDP_CTRL
    move.w  #15, s3_count
15: move.w  s3_count, d3
    bsr.w   clear_column3
    subq.w  #1, s3_count
    bpl.s   15b
    bsr.s   render_window3
    move.w  #0x8174, VDP_CTRL
    bra.w   6f

render_window3:
    move.w  #S3_W - 1, s3_count
4:  move.w  s3_col0, d3
    add.w   s3_count, d3
    andi.w  #63, d3
    bsr.w   render_column3
    subq.w  #1, s3_count
    bpl.s   4b
    rts

| d3 arcade row: draws its cells across the window
render_row3:
    andi.w  #63, d3
    move.w  d3, t_row
    move.w  #S3_W - 1, s3_count
1:  move.w  s3_col0, d0
    add.w   s3_count, d0
    andi.w  #63, d0
    move.w  d0, t_col
    bsr.w   render_cell3
    subq.w  #1, s3_count
    bpl.s   1b
    rts

5:  move.w  s3_dirty, d0
    beq.s   6f
    clr.w   s3_dirty
    subq.w  #1, d0
    move.w  d0, s3_count
8:  move.w  s3_count, d0
    add.w   d0, d0
    lea     DIRTY3, a0
    move.w  0(a0,d0.w), d0
    move.w  d0, d1
    andi.w  #0xff, d1
    lsr.w   #8, d0
    move.w  d0, t_col
    move.w  d1, t_row
    bsr.w   render_cell3
    subq.w  #1, s3_count
    bpl.s   8b
6:  move.w  s3_dirty_cols, d0
    beq.s   25f
    clr.w   s3_dirty_cols
    move.w  d0, -(sp)
    move.w  #S3_W - 1, s3_count
24: move.w  s3_col0, d3
    add.w   s3_count, d3
    andi.w  #63, d3
    move.w  d3, d1
    andi.w  #15, d1
    move.w  (sp), d0
    btst    d1, d0
    beq.s   26f
    bsr.w   render_column3
26: subq.w  #1, s3_count
    bpl.s   24b
    addq.l  #2, sp
25: move.w  cam2_x, d0
    sub.w   cam3_x, d0
    move.w  cam2_y, d1
    sub.w   cam3_y, d1
    move.w  cam3_y, d2
    cmp.w   s3_rel_x, d0
    bne.s   19f
    cmp.w   s3_rel_y, d1
    bne.s   19f
    cmp.w   s3_last_y, d2
    beq.s   20f
19: move.w  d0, s3_rel_x
    move.w  d1, s3_rel_y
    move.w  d2, s3_last_y
    move.w  #S3_W, s3_pending
20: move.l  hal_frames, d0
    btst    #0, d0
    beq.s   16f
    move.w  s3_pending, d0
    beq.s   16f
    moveq   #2, d1
    cmp.w   d1, d0
    bls.s   21f
    move.w  d1, d0
21: sub.w   d0, s3_pending
    subq.w  #1, d0
    move.w  d0, s3_count
17: move.w  s3_sweep, d3
    addq.w  #1, d3
    cmpi.w  #S3_W, d3
    blo.s   18f
    moveq   #0, d3
18: move.w  d3, s3_sweep
    add.w   s3_col0, d3
    andi.w  #63, d3
    bsr.w   sweep_column3
    subq.w  #1, s3_count
    bpl.s   17b
16: rts

| d0 address in the arcade scroll 3 table -> d4 store offset, d2 column, d3 row
s3_offset:
    move.w  d0, d4
    andi.w  #0x3ffe, d4
    move.w  d4, d3
    lsr.w   #8, d3
    andi.w  #0x38, d3
    move.w  d4, d2
    lsr.w   #2, d2
    andi.w  #7, d2
    or.w    d2, d3
    move.w  d4, d2
    lsr.w   #5, d2
    andi.w  #63, d2
    andi.w  #2, d4
    move.w  d2, -(sp)
    lsl.w   #4, d2
    move.w  d3, -(sp)
    andi.w  #15, d3
    or.w    d3, d2
    lsl.w   #2, d2
    or.w    d2, d4
    move.w  (sp)+, d3
    move.w  (sp)+, d2
    rts

s3_read:
    movem.l d2-d4/a1, -(sp)
    bsr.s   s3_offset
    lea     S3_STORE, a1
    move.w  0(a1,d4.w), d1
    movem.l (sp)+, d2-d4/a1
    rts

s3_write:
    movem.l d2-d4/a1, -(sp)
    bsr.s   s3_offset
    lea     S3_STORE, a1
    move.w  d1, 0(a1,d4.w)
    btst    #1, d4
    beq.s   7f
    move.w  -2(a1,d4.w), d4
    cmpi.w  #0x1fff, d4
    bhi.s   7f
    lea     TILE_FLAGS3, a1
    tst.b   0(a1,d4.w)
    beq.s   7f
    move.w  d1, d4
    andi.w  #31, d4
    lea     PM_INDEX + 32, a1
    cmpi.b  #0xff, 0(a1,d4.w)
    bne.s   7f
    move.w  #1, q_request
7:  tst.w   s3_valid
    beq.s   9f
    move.w  d2, d4
    sub.w   s3_col0, d4
    andi.w  #63, d4
    cmpi.w  #S3_W, d4
    bhs.s   9f
    move.w  d3, d4
    sub.w   s3_row0, d4
    andi.w  #63, d4
    cmpi.w  #8, d4
    bhs.s   9f
    move.w  s3_dirty, d4
    cmpi.w  #32, d4
    blo.s   1f
    andi.w  #15, d2
    move.w  s3_dirty_cols, d4
    bset    d2, d4
    move.w  d4, s3_dirty_cols
    bra.s   9f
1:  lsl.w   #8, d2
    or.w    d3, d2
    add.w   d4, d4
    lea     DIRTY3, a1
    move.w  d2, 0(a1,d4.w)
    lsr.w   #1, d4
    addq.w  #1, d4
    move.w  d4, s3_dirty
9:  movem.l (sp)+, d2-d4/a1
    rts

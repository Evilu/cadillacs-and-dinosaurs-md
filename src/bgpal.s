| One CRAM line for both background layers. The playfield and the far background
| use more arcade palettes than the Mega Drive has lines, so their colours are
| reduced to 15 and every tile's pixels are renumbered as it is loaded into VRAM.
|
| bg_quantise counts the palettes in both map stores, lists their distinct
| colours (to Mega Drive precision), picks 15 by repeatedly taking the colour
| whose distance to the ones already picked, times its use, is largest, and
| writes a 16-byte pen map per arcade palette. The three most used palettes also
| get a 256-entry table that converts two pixels at a time. It runs when a tile
| arrives in a palette without a map, or when a mapped palette's colours change,
| and both layers are then redrawn. A colour that stays in the line keeps its
| position, so tiles drawn before and after look the same while the redraw,
| which takes several frames, is under way.

    .equ LINE_SRC,      0xff79e0    | 16 words: offset in PALETTES of each line colour's source, 0xffff none
    .equ LINE_RAW,      0xff7a00    | 16 words: the arcade colour words of the line this frame
    .equ PM_INDEX,      0xff7a20    | 64 bytes (page 2, page 3): pen map slot, 0xff not mapped
    .equ PENMAP,        0xff7a60    | 16 slots x 16 bytes: Mega Drive pen -> pen in the line
    .equ PM_SLOTS,      16
    .equ LUT_PAL,       0xff7b60    | 4 bytes: pen map slot each pair table belongs to
    .equ q_request,     0xff7b64
    .equ q_n,           0xff7b66
    .equ q_sig,         0xff7b68
    .equ QCOUNT,        0xff7b70    | 64 words: cells per palette
    .equ LUTS,          0xff7c00    | 3 x 256 bytes
    .equ QW,            LUTS        | work list while quantising, 8 bytes per colour: key, weight, source, distance
    .equ QNEAR,         LUTS + 672  | per colour: nearest line colour
    .equ QMAX,          84

bgpal_init:
    lea     PM_INDEX, a0
    moveq   #63, d0
1:  move.b  #0xff, (a0)+
    dbra    d0, 1b
    lea     PENMAP, a0
    moveq   #0, d0
2:  move.b  d0, (a0)+
    addq.w  #1, d0
    cmpi.w  #16, d0
    blt.s   2b
    lea     LINE_SRC, a0
    moveq   #15, d0
3:  move.w  #0xffff, (a0)+
    dbra    d0, 3b
    move.l  #0xffffffff, LUT_PAL
    clr.w   q_request
    clr.l   q_sig
    rts

| a3 source patterns, d2 words - 1, d1 page index (playfield 0-31, far 32-63); VRAM address set
remap_copy:
    lea     PM_INDEX, a1
    moveq   #0, d0
    move.b  0(a1,d1.w), d0
    cmpi.b  #0xff, d0
    bne.s   1f
    move.w  #1, q_request
    moveq   #0, d0
1:  lea     VDP_DATA, a4
    lea     LUT_PAL, a1
    moveq   #3, d3
2:  cmp.b   (a1)+, d0
    beq.s   5f
    dbra    d3, 2b
    lsl.w   #4, d0
    lea     PENMAP, a1
    adda.w  d0, a1
    moveq   #0, d0
3:  move.b  (a3)+, d0
    move.w  d0, d3
    lsr.w   #4, d3
    andi.w  #15, d0
    move.b  0(a1,d3.w), d1
    lsl.w   #4, d1
    or.b    0(a1,d0.w), d1
    lsl.w   #8, d1
    move.b  (a3)+, d0
    move.w  d0, d3
    lsr.w   #4, d3
    andi.w  #15, d0
    move.b  0(a1,d3.w), d4
    lsl.b   #4, d4
    or.b    0(a1,d0.w), d4
    move.b  d4, d1
    move.w  d1, (a4)
    dbra    d2, 3b
    rts
5:  moveq   #3, d0
    sub.w   d3, d0
    lsl.w   #8, d0
    lea     LUTS, a1
    adda.w  d0, a1
    moveq   #0, d0
6:  move.b  (a3)+, d0
    move.b  0(a1,d0.w), d1
    lsl.w   #8, d1
    move.b  (a3)+, d0
    move.b  0(a1,d0.w), d1
    move.w  d1, (a4)
    dbra    d2, 6b
    rts

| Called every frame before the layers are drawn
bgpal_update:
    move.l  hal_frames, d0
    andi.w  #7, d0
    bne.s   9f
    tst.w   q_request
    bne.s   bg_quantise
    move.l  hal_frames, d0
    andi.w  #31, d0
    bne.s   9f
    bsr.w   q_signature
    cmp.l   q_sig, d0
    bne.s   bg_quantise
9:  rts

bg_quantise:
    lea     -80(sp), sp
    movea.l sp, a5
    clr.w   q_request
    move.l  #0xffffffff, LUT_PAL
    lea     QCOUNT, a0
    moveq   #63, d0
1:  clr.w   (a0)+
    dbra    d0, 1b
    lea     QCOUNT, a1
    lea     TILE_FLAGS, a2
    lea     S2_STORE, a0
    move.w  #2047, d7
2:  move.w  (a0)+, d0
    move.w  (a0)+, d1
    tst.w   d0
    bmi.s   3f
    tst.b   0(a2,d0.w)
    beq.s   3f
    andi.w  #31, d1
    add.w   d1, d1
    addq.w  #1, 0(a1,d1.w)
3:  dbra    d7, 2b
    lea     TILE_FLAGS3, a2
    lea     S3_STORE, a0
    move.w  #1023, d7
4:  move.w  (a0)+, d0
    move.w  (a0)+, d1
    cmpi.w  #0x1fff, d0
    bhi.s   5f
    tst.b   0(a2,d0.w)
    beq.s   5f
    andi.w  #31, d1
    add.w   d1, d1
    addq.w  #4, 64(a1,d1.w)
5:  dbra    d7, 4b

    lea     PM_INDEX, a0
    moveq   #63, d0
6:  move.b  #0xff, (a0)+
    dbra    d0, 6b
    moveq   #0, d6
    moveq   #0, d5
    moveq   #0, d7
q_palette:
    move.w  d7, d0
    add.w   d0, d0
    lea     QCOUNT, a1
    move.w  0(a1,d0.w), d4
    beq.s   q_next_palette
    lea     PM_INDEX, a0
    cmpi.w  #PM_SLOTS, d5
    blo.s   1f
    clr.b   0(a0,d7.w)
    bra.s   q_next_palette
1:  move.b  d5, 0(a0,d7.w)
    addq.w  #1, d5
    move.w  d7, d0
    lsl.w   #5, d0
    addi.w  #0x800, d0
    lea     PALETTES, a2
    adda.w  d0, a2
    moveq   #14, d3
2:  move.w  (a2)+, d1
    andi.w  #0xeee, d1
    lea     QW, a3
    move.w  d6, d2
    bra.s   4f
3:  cmp.w   (a3), d1
    beq.s   5f
    addq.l  #8, a3
4:  dbra    d2, 3b
    cmpi.w  #QMAX, d6
    bhs.s   6f
    move.w  d1, (a3)+
    move.w  d4, (a3)+
    move.l  a2, d1
    subi.l  #PALETTES + 2, d1
    move.w  d1, (a3)+
    clr.w   (a3)
    addq.w  #1, d6
    bra.s   6f
5:  add.w   d4, 2(a3)
    bcc.s   6f
    move.w  #0xffff, 2(a3)
6:  dbra    d3, 2b
q_next_palette:
    addq.w  #1, d7
    cmpi.w  #64, d7
    blt.w   q_palette
    move.w  d6, q_n
    moveq   #0, d7
    tst.w   d6
    beq.w   q_slots

q_select:
    lea     QW, a3
    move.w  q_n, d2
    subq.w  #1, d2
    moveq   #0, d5
    suba.l  a4, a4
1:  moveq   #0, d0
    move.w  2(a3), d0
    tst.w   d7
    beq.s   2f
    cmpi.w  #255, d0
    bls.s   2f
    move.w  #255, d0
2:  addq.l  #1, d0
    tst.w   d7
    beq.s   3f
    mulu    6(a3), d0
3:  cmp.l   d5, d0
    bls.s   4f
    move.l  d0, d5
    movea.l a3, a4
4:  addq.l  #8, a3
    dbra    d2, 1b
    move.l  a4, d0
    beq.w   q_slots
    move.w  d7, d0
    add.w   d0, d0
    move.w  4(a4), 0(a5,d0.w)
    move.w  (a4), 30(a5,d0.w)
    move.w  (a4), d4
    lea     QW, a3
    lea     QNEAR, a2
    move.w  q_n, d2
    subq.w  #1, d2
5:  move.w  (a3), d0
    move.w  d4, d1
    moveq   #0, d3
    move.w  d0, d5
    andi.w  #15, d5
    move.w  d1, d6
    andi.w  #15, d6
    sub.w   d6, d5
    muls    d5, d5
    add.w   d5, d3
    lsr.w   #4, d0
    lsr.w   #4, d1
    move.w  d0, d5
    andi.w  #15, d5
    move.w  d1, d6
    andi.w  #15, d6
    sub.w   d6, d5
    muls    d5, d5
    add.w   d5, d3
    lsr.w   #4, d0
    lsr.w   #4, d1
    sub.w   d1, d0
    muls    d0, d0
    add.w   d0, d3
    tst.w   d7
    beq.s   6f
    cmp.w   6(a3), d3
    bhs.s   7f
6:  move.w  d3, 6(a3)
    move.b  d7, (a2)
7:  addq.l  #8, a3
    addq.l  #1, a2
    dbra    d2, 5b
    addq.w  #1, d7
    cmpi.w  #15, d7
    blt.w   q_select

| d7 colours picked: sources at 0(a5), keys at 30(a5). Gives each a position in
| the line (60(a5)): the one it already has if it is in the line now.
q_slots:
    move.w  d7, 78(a5)
    lea     60(a5), a0
    moveq   #15, d0
1:  move.b  #0xff, (a0)+
    dbra    d0, 1b
    moveq   #0, d6
    moveq   #0, d5
    bra.s   6f
2:  move.w  d5, d0
    add.w   d0, d0
    move.w  30(a5,d0.w), d1
    lea     LINE_RAW, a0
    lea     LINE_SRC, a1
    moveq   #0, d2
3:  btst    d2, d6
    bne.s   4f
    tst.w   (a1)
    bmi.s   4f
    move.w  (a0), d0
    andi.w  #0xeee, d0
    cmp.w   d0, d1
    bne.s   4f
    bset    d2, d6
    move.b  d2, 60(a5,d5.w)
    bra.s   5f
4:  addq.l  #2, a0
    addq.l  #2, a1
    addq.w  #1, d2
    cmpi.w  #15, d2
    blt.s   3b
5:  addq.w  #1, d5
6:  cmp.w   78(a5), d5
    blt.s   2b
    moveq   #0, d5
    bra.s   10f
7:  cmpi.b  #0xff, 60(a5,d5.w)
    bne.s   9f
    moveq   #0, d2
8:  btst    d2, d6
    beq.s   11f
    addq.w  #1, d2
    bra.s   8b
11: bset    d2, d6
    move.b  d2, 60(a5,d5.w)
9:  addq.w  #1, d5
10: cmp.w   78(a5), d5
    blt.s   7b
    lea     LINE_SRC, a0
    moveq   #15, d0
12: move.w  #0xffff, (a0)+
    dbra    d0, 12b
    lea     LINE_SRC, a0
    moveq   #0, d5
    bra.s   14f
13: moveq   #0, d0
    move.b  60(a5,d5.w), d0
    add.w   d0, d0
    move.w  d5, d1
    add.w   d1, d1
    move.w  0(a5,d1.w), 0(a0,d0.w)
    addq.w  #1, d5
14: cmp.w   78(a5), d5
    blt.s   13b
    tst.w   q_n
    beq.w   q_done

q_maps:
    moveq   #0, d7
    moveq   #0, d5
1:  lea     PM_INDEX, a0
    moveq   #0, d0
    move.b  0(a0,d7.w), d0
    cmp.w   d5, d0
    bne.s   6f
    addq.w  #1, d5
    lsl.w   #4, d0
    lea     PENMAP, a1
    adda.w  d0, a1
    clr.b   (a1)+
    move.w  d7, d0
    lsl.w   #5, d0
    addi.w  #0x800, d0
    lea     PALETTES, a2
    adda.w  d0, a2
    moveq   #14, d3
2:  move.w  (a2)+, d1
    andi.w  #0xeee, d1
    lea     QW, a3
    lea     QNEAR, a4
    move.w  q_n, d2
    subq.w  #1, d2
    moveq   #1, d0
3:  cmp.w   (a3), d1
    beq.s   4f
    addq.l  #8, a3
    addq.l  #1, a4
    dbra    d2, 3b
    bra.s   5f
4:  moveq   #0, d0
    move.b  (a4), d0
    move.b  60(a5,d0.w), d0
    addq.b  #1, d0
5:  move.b  d0, (a1)+
    dbra    d3, 2b
6:  addq.w  #1, d7
    cmpi.w  #64, d7
    blt.s   1b

    moveq   #0, d7
q_tables:
    lea     QCOUNT, a1
    moveq   #0, d1
    moveq   #-1, d2
    moveq   #0, d0
1:  cmp.w   (a1)+, d1
    bcc.s   2f
    move.w  -2(a1), d1
    move.w  d0, d2
2:  addq.w  #1, d0
    cmpi.w  #64, d0
    blt.s   1b
    tst.w   d2
    bmi.s   q_done
    lea     QCOUNT, a1
    move.w  d2, d0
    add.w   d0, d0
    clr.w   0(a1,d0.w)
    lea     PM_INDEX, a0
    moveq   #0, d0
    move.b  0(a0,d2.w), d0
    lea     LUT_PAL, a0
    move.b  d0, 0(a0,d7.w)
    lsl.w   #4, d0
    lea     PENMAP, a1
    adda.w  d0, a1
    move.w  d7, d0
    lsl.w   #8, d0
    lea     LUTS, a2
    adda.w  d0, a2
    moveq   #0, d3
3:  move.b  0(a1,d3.w), d4
    lsl.b   #4, d4
    movea.l a1, a3
    moveq   #15, d5
4:  move.b  (a3)+, d0
    or.b    d4, d0
    move.b  d0, (a2)+
    dbra    d5, 4b
    addq.w  #1, d3
    cmpi.w  #16, d3
    blt.s   3b
    addq.w  #1, d7
    cmpi.w  #3, d7
    blt.w   q_tables
q_done:
    bsr.s   q_signature
    move.l  d0, q_sig
    lea     S2_REF, a0
    moveq   #S2_SLOTS - 1, d0
1:  ori.w   #0x400, (a0)+
    dbra    d0, 1b
    lea     S3_REF, a0
    moveq   #S3_SLOTS - 1, d0
2:  ori.w   #0x400, (a0)+
    dbra    d0, 2b
    move.w  #1, s2_refresh
    move.w  #1, s3_refresh
    lea     80(sp), sp
    rts

| -> d0 checksum of the colours (without brightness) of every mapped palette
q_signature:
    moveq   #0, d0
    moveq   #0, d1
    lea     PM_INDEX, a0
    lea     PALETTES + 0x800, a2
    moveq   #63, d7
1:  cmpi.b  #0xff, (a0)+
    beq.s   3f
    movea.l a2, a3
    moveq   #14, d6
2:  move.w  (a3)+, d1
    andi.w  #0xfff, d1
    rol.l   #3, d0
    add.l   d1, d0
    dbra    d6, 2b
3:  lea     32(a2), a2
    dbra    d7, 1b
    rts

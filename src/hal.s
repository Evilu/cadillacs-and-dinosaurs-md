| Hardware layer for the Mega Drive build, linked after the arcade program.

    .equ IO_SHADOW,     0xff1000    | arcade 0x800000-0x8001ff
    .equ Q_SHADOW,      0xff1200    | arcade 0xf18000-0xf1803f
    .equ P3_SHADOW,     0xff1280    | arcade 0xf1c000-0xf1c01f
    .equ HAL_VARS,      0xff12c0
    .equ hal_frames,    HAL_VARS
    .equ sat_count,     HAL_VARS + 4
    .equ queue_count,   HAL_VARS + 6
    .equ stamp,         HAL_VARS + 8
    .equ e_x,           HAL_VARS + 10
    .equ e_y,           HAL_VARS + 12
    .equ e_code,        HAL_VARS + 14
    .equ e_nx,          HAL_VARS + 16
    .equ e_ny,          HAL_VARS + 18
    .equ e_attr,        HAL_VARS + 20
    .equ e_row,         HAL_VARS + 22
    .equ e_col,         HAL_VARS + 24
    .equ e_flip,        HAL_VARS + 26
    .equ line_pal,      HAL_VARS + 28   | 4 bytes: arcade sprite palette shown in each CRAM line
    .equ pal_line,      HAL_VARS + 32   | 32 bytes: CRAM line used for each arcade sprite palette
    .equ last_flag,     HAL_VARS + 64   | SHOWN_FLAG when the sprite table was last built

    .equ SPRITES_A,     0xff2000    | arcade 0x900000 sprite list
    .equ SPRITES_B,     0xff2800    | arcade 0x904000 sprite list
    .equ PALETTES,      0xff3000    | arcade 0x914000-0x917fff: palettes, row scroll
    .equ SAT_BUF,       0xff7000    | 80 entries
    .equ CACHE_KEY,     0xff7280    | 128 words
    .equ CACHE_STAMP,   0xff7380    | 128 words
    .equ QUEUE,         0xff7480    | upload queue: long source, word VRAM address, word length
    .equ PAL_COUNT,     0xff7580    | 32 words
    .equ CRAM_BUF,      0xff75c0    | 64 words
    .equ SHOWN_FLAG,    0xffe9b4    | nonzero: list B is the finished one

    .equ COLOUR_TABLE,  0x187f00    | [brightness][nibble] -> Mega Drive 3-bit level << 1
    .equ TILE_FLAGS,    0x188000    | per arcade 16x16 tile: nonzero if it has pixels
    .equ TILE_FIRST,    0x0800      | tiles stored in ROM: 0x0800-0x6fff
    .equ TILE_END,      0x7000
    .equ TILE_DATA,     0x190000 - TILE_FIRST * 128   | ROM address of tile 0 if it were stored
    .equ WINDOW,        0x380000    | mapper region 7
    .equ MAPPER7,       0xa130ff
    .equ SLOT_BASE,     0x20        | first VRAM pattern of the sprite cache
    .equ MAX_QUEUE,     22
    .equ MAX_SPRITES,   80

    .equ ARCADE_START,  0x0004ce
    .equ ARCADE_RESET,  0x00041a
    .equ ARCADE_VBLANK, 0x000542

    .equ VDP_DATA,      0xc00000
    .equ VDP_CTRL,      0xc00004
    .equ PAD1_DATA,     0xa10003
    .equ PAD1_CTRL,     0xa10009

    .text
hal_ignore:
    rte

hal_boot:
    move.w  #0x2700, sr
    move.b  0xa10001, d0
    andi.b  #0x0f, d0
    beq.s   1f
    move.l  #0x53454741, 0xa14000
1:  move.w  #0x0100, 0xa11100
    move.w  #0x0000, 0xa11200
    lea     vdp_init(pc), a0
    moveq   #(vdp_init_end - vdp_init) / 2 - 1, d0
2:  move.w  (a0)+, VDP_CTRL
    dbra    d0, 2b
    move.l  #0x40000000, VDP_CTRL
    move.w  #0x7fff, d0
    moveq   #0, d1
3:  move.w  d1, VDP_DATA
    dbra    d0, 3b
    move.l  #0xc0000000, VDP_CTRL
    moveq   #63, d0
4:  move.w  d1, VDP_DATA
    dbra    d0, 4b
    move.b  #0x40, PAD1_CTRL
    move.b  #0x40, PAD1_DATA
    jmp     ARCADE_RESET

| Runs after the arcade reset code has cleared work RAM, in place of its
| power-on self-test (which reads back arcade video RAM).
hal_post_reset:
    lea     IO_SHADOW, a0
    moveq   #-1, d0
    move.l  d0, (a0)
    move.w  d0, 0x18(a0)
    move.w  d0, 0x1a(a0)
    move.w  d0, 0x1c(a0)
    move.w  d0, 0x1e(a0)
    move.w  d0, P3_SHADOW
    move.w  d0, P3_SHADOW + 6
    move.b  d0, Q_SHADOW + 0x1f
    lea     CACHE_KEY, a0
    move.w  #127, d1
1:  move.w  d0, (a0)+
    dbra    d1, 1b
    move.l  d0, line_pal
    move.w  d0, last_flag
    move.w  #0x8174, VDP_CTRL
    jmp     ARCADE_START

| Level 6. Sends last frame's video work, refreshes inputs, runs Capcom's VBlank
| handler, then converts the sprite list it just made visible.
hal_vblank:
    movem.l d0-d7/a0-a6, -(sp)
    move.w  VDP_CTRL, d0
    addq.l  #1, hal_frames
    bsr.w   flush_video
    moveq   #-1, d0
    lea     IO_SHADOW, a0
    move.b  d0, (a0)
    move.w  d0, 0x1a(a0)
    move.w  d0, 0x1c(a0)
    move.w  d0, 0x1e(a0)
    move.w  d0, P3_SHADOW
    move.w  d0, P3_SHADOW + 6
    move.b  d0, Q_SHADOW + 0x1f
    bsr.w   read_pad
    pea     hal_after(pc)
    move.w  #0x2700, -(sp)
    jmp     ARCADE_VBLANK
hal_after:
    bsr.w   build_sprites
    movem.l (sp)+, d0-d7/a0-a6
    rte

| ---------------------------------------------------------------- video out

flush_video:
    lea     VDP_CTRL, a4
    lea     QUEUE, a0
    move.w  queue_count, d7
    beq.s   2f
    subq.w  #1, d7
1:  move.l  (a0)+, d0
    move.w  (a0)+, d1
    move.w  (a0)+, d2
    move.l  d0, d3
    swap    d3
    lsr.w   #3, d3
    move.b  d3, MAPPER7
    andi.l  #0x7ffff, d0
    addi.l  #WINDOW, d0
    bsr.s   dma_to_vram
    dbra    d7, 1b
    clr.w   queue_count
2:  move.l  #SAT_BUF, d0
    move.w  #0xf400, d1
    move.w  sat_count, d2
    beq.s   3f
    lsl.w   #2, d2
    bsr.s   dma_to_vram
3:  move.l  #0xc0000000, (a4)
    lea     CRAM_BUF, a0
    moveq   #63, d0
4:  move.w  (a0)+, VDP_DATA
    dbra    d0, 4b
    rts

| d0 source address, d1 VRAM address, d2 length in words, a4 VDP control port
dma_to_vram:
    move.w  #0x9300, d3
    move.b  d2, d3
    move.w  d3, (a4)
    move.w  d2, d3
    lsr.w   #8, d3
    ori.w   #0x9400, d3
    move.w  d3, (a4)
    lsr.l   #1, d0
    move.w  #0x9500, d3
    move.b  d0, d3
    move.w  d3, (a4)
    lsr.l   #8, d0
    move.w  #0x9600, d3
    move.b  d0, d3
    move.w  d3, (a4)
    lsr.l   #8, d0
    move.w  #0x9700, d3
    move.b  d0, d3
    andi.b  #0x7f, d3
    move.w  d3, (a4)
    move.w  d1, d3
    andi.w  #0x3fff, d3
    ori.w   #0x4000, d3
    move.w  d3, (a4)
    move.w  d1, d3
    rol.w   #2, d3
    andi.w  #3, d3
    ori.w   #0x80, d3
    move.w  d3, -(sp)
    move.w  (sp)+, (a4)
    rts

| ---------------------------------------------------------------- sprites

build_sprites:
    move.w  SHOWN_FLAG, d0
    cmp.w   last_flag, d0
    bne.s   1f
    bra.w   build_cram
1:  move.w  d0, last_flag
    addq.w  #1, stamp
    lea     SPRITES_A, a0
    tst.w   d0
    beq.s   2f
    lea     SPRITES_B, a0
2:  bsr.w   count_palettes
    bsr.w   assign_lines
    bsr.w   build_cram
    lea     SAT_BUF, a1
    clr.w   sat_count
    move.w  #255, d7
next_entry:
    move.w  6(a0), d4
    move.w  d4, d0
    andi.w  #0xff00, d0
    cmpi.w  #0xff00, d0
    beq.w   entries_done
    move.w  4(a0), d0
    bmi.w   skip_entry
    move.w  d0, e_code
    move.w  (a0), d0
    andi.w  #0x1ff, d0
    cmpi.w  #0x1c0, d0
    blt.s   2f
    subi.w  #0x200, d0
2:  addi.w  #32, d0
    move.w  d0, e_x
    move.w  2(a0), d0
    andi.w  #0x1ff, d0
    cmpi.w  #0x180, d0
    blt.s   3f
    subi.w  #0x200, d0
3:  addi.w  #112, d0
    move.w  d0, e_y
    move.w  d4, d0
    lsr.w   #8, d0
    andi.w  #15, d0
    addq.w  #1, d0
    move.w  d0, e_nx
    move.w  d4, d0
    rol.w   #4, d0
    andi.w  #15, d0
    addq.w  #1, d0
    move.w  d0, e_ny
    move.w  e_x, d1
    cmpi.w  #448, d1
    bge.w   skip_entry
    move.w  e_nx, d2
    lsl.w   #4, d2
    add.w   d2, d1
    cmpi.w  #128 - 32 + 16, d1
    ble.w   skip_entry
    move.w  e_y, d1
    cmpi.w  #352, d1
    bge.w   skip_entry
    lsl.w   #4, d0
    add.w   d0, d1
    cmpi.w  #128, d1
    ble.w   skip_entry
    move.w  d4, d0
    andi.w  #0x60, d0
    move.w  d0, e_flip
    lsl.w   #6, d0
    ori.w   #0x8000, d0
    move.w  d4, d1
    andi.w  #0x1f, d1
    lea     pal_line, a2
    moveq   #0, d2
    move.b  0(a2,d1.w), d2
    ror.w   #3, d2
    or.w    d2, d0
    move.w  d0, e_attr
    clr.w   e_row
entry_row:
    clr.w   e_col
entry_col:
    move.w  e_code, d0
    move.w  e_col, d5
    move.w  d0, d1
    add.w   d5, d1
    andi.w  #15, d1
    andi.w  #0xfff0, d0
    or.w    d1, d0
    move.w  e_row, d2
    lsl.w   #4, d2
    add.w   d2, d0
    moveq   #0, d6
    tst.w   d0
    bmi.w   piece_skip
    cmpi.w  #15, d1
    beq.s   4f
    move.w  d5, d2
    addq.w  #1, d2
    cmp.w   e_nx, d2
    bge.s   4f
    moveq   #1, d6
4:  move.w  d5, d2
    btst    #5, e_flip + 1
    beq.s   5f
    move.w  e_nx, d2
    subq.w  #1, d2
    sub.w   d5, d2
    sub.w   d6, d2
5:  lsl.w   #4, d2
    add.w   e_x, d2
    move.w  e_row, d3
    btst    #6, e_flip + 1
    beq.s   6f
    move.w  e_ny, d3
    subq.w  #1, d3
    sub.w   e_row, d3
6:  lsl.w   #4, d3
    add.w   e_y, d3
    move.w  d6, d1
    bsr.w   emit_piece
    cmpi.w  #MAX_SPRITES, sat_count
    bhs.s   entries_done
piece_skip:
    move.w  e_col, d5
    addq.w  #1, d5
    add.w   d6, d5
    move.w  d5, e_col
    cmp.w   e_nx, d5
    blt.w   entry_col
    move.w  e_row, d5
    addq.w  #1, d5
    move.w  d5, e_row
    cmp.w   e_ny, d5
    blt.w   entry_row
skip_entry:
    addq.l  #8, a0
    dbra    d7, next_entry
entries_done:
    move.w  sat_count, d0
    bne.s   7f
    clr.l   (a1)+
    clr.l   (a1)+
    move.w  #1, sat_count
    rts
7:  subq.w  #1, d0
    lsl.w   #3, d0
    lea     SAT_BUF, a1
    clr.b   3(a1,d0.w)
    rts

| d0 first tile, d1 1 for a pair of tiles, d2 x, d3 y (sprite coordinates)
| keeps d6, d7, a0
emit_piece:
    cmpi.w  #128 - 32, d2
    ble.w   9f
    cmpi.w  #448, d2
    bge.w   9f
    cmpi.w  #128 - 16, d3
    ble.w   9f
    cmpi.w  #352, d3
    bge.w   9f
    cmpi.w  #TILE_FIRST, d0
    blo.w   9f
    cmpi.w  #TILE_END, d0
    bhs.w   9f
    lea     TILE_FLAGS, a2
    move.b  0(a2,d0.w), d4
    tst.w   d1
    beq.s   1f
    or.b    1(a2,d0.w), d4
1:  tst.b   d4
    beq.w   9f
    move.w  d0, d5
    tst.w   d1
    bne.s   2f
    ori.w   #0x8000, d5
2:  move.w  d5, d4
    lsr.w   #5, d4
    eor.w   d5, d4
    andi.w  #31, d4
    lsl.w   #3, d4
    lea     CACHE_KEY, a2
    adda.w  d4, a2
    movea.l a2, a3
    moveq   #3, d4
3:  cmp.w   (a3), d5
    beq.s   hit
    addq.l  #2, a3
    dbra    d4, 3b
    cmpi.w  #MAX_QUEUE, queue_count
    bhs.w   9f
    move.w  stamp, d4
    movea.l a2, a3
    moveq   #3, d5
4:  cmp.w   0x100(a3), d4
    bne.s   5f
    addq.l  #2, a3
    dbra    d5, 4b
    bra.w   9f
5:  move.w  d0, d5
    tst.w   d1
    bne.s   6f
    ori.w   #0x8000, d5
6:  move.w  d5, (a3)
    move.w  d4, 0x100(a3)
    bsr.s   slot_pattern
    lea     QUEUE, a2
    move.w  queue_count, d5
    lsl.w   #3, d5
    adda.w  d5, a2
    moveq   #0, d5
    move.w  d0, d5
    lsl.l   #7, d5
    addi.l  #TILE_DATA, d5
    move.l  d5, (a2)+
    move.w  d4, d5
    lsl.w   #5, d5
    move.w  d5, (a2)+
    moveq   #64, d5
    tst.w   d1
    beq.s   7f
    add.w   d5, d5
7:  move.w  d5, (a2)
    addq.w  #1, queue_count
    bra.s   write_sat
hit:
    move.w  stamp, 0x100(a3)
    bsr.s   slot_pattern
write_sat:
    move.w  d3, (a1)+
    moveq   #0x05, d5
    tst.w   d1
    beq.s   8f
    moveq   #0x0d, d5
8:  lsl.w   #8, d5
    move.w  sat_count, d0
    addq.w  #1, d0
    move.b  d0, d5
    move.w  d5, (a1)+
    or.w    e_attr, d4
    move.w  d4, (a1)+
    move.w  d2, (a1)+
    move.w  d0, sat_count
9:  rts

| a3 cache key entry -> d4 first VRAM pattern of its slot
slot_pattern:
    move.l  a3, d4
    subi.l  #CACHE_KEY, d4
    lsl.w   #2, d4
    addi.w  #SLOT_BASE, d4
    rts

| ---------------------------------------------------------------- palettes

count_palettes:
    lea     PAL_COUNT, a1
    moveq   #15, d0
1:  clr.l   (a1)+
    dbra    d0, 1b
    lea     PAL_COUNT, a1
    movea.l a0, a2
    move.w  #255, d7
2:  move.w  6(a2), d0
    move.w  d0, d1
    andi.w  #0xff00, d1
    cmpi.w  #0xff00, d1
    beq.s   3f
    move.w  d0, d1
    andi.w  #0x1f, d1
    add.w   d1, d1
    lsr.w   #8, d0
    move.w  d0, d2
    andi.w  #15, d0
    addq.w  #1, d0
    lsr.w   #4, d2
    addq.w  #1, d2
    mulu    d2, d0
    add.w   d0, 0(a1,d1.w)
    addq.l  #8, a2
    dbra    d7, 2b
3:  rts

assign_lines:
    lea     pal_line, a2
    moveq   #7, d0
1:  clr.l   (a2)+
    dbra    d0, 1b
    lea     pal_line, a2
    lea     line_pal, a3
    moveq   #0, d3
2:  lea     PAL_COUNT, a1
    moveq   #0, d1
    moveq   #-1, d2
    moveq   #0, d0
3:  cmp.w   (a1)+, d1
    bcc.s   4f
    move.w  -2(a1), d1
    move.w  d0, d2
4:  addq.w  #1, d0
    cmpi.w  #32, d0
    blt.s   3b
    move.b  d2, 0(a3,d3.w)
    bmi.s   5f
    move.b  d3, 0(a2,d2.w)
    lea     PAL_COUNT, a1
    add.w   d2, d2
    clr.w   0(a1,d2.w)
5:  addq.w  #1, d3
    cmpi.w  #4, d3
    blt.s   2b
    rts

build_cram:
    lea     CRAM_BUF, a1
    lea     line_pal, a3
    lea     COLOUR_TABLE, a4
    moveq   #3, d7
1:  clr.w   (a1)+
    moveq   #0, d0
    move.b  (a3)+, d0
    bmi.s   4f
    lsl.w   #5, d0
    lea     PALETTES, a2
    adda.w  d0, a2
    moveq   #14, d6
2:  move.w  (a2)+, d0
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
    move.w  d3, (a1)+
    dbra    d6, 2b
    bra.s   5f
4:  moveq   #14, d6
3:  clr.w   (a1)+
    dbra    d6, 3b
5:  dbra    d7, 1b
    rts

| ---------------------------------------------------------------- input

| Pad 1 -> arcade player 1 and system inputs (all active low).
| B = attack, C = jump, A = coin, Start = start.
read_pad:
    lea     PAD1_DATA, a0
    move.b  #0x40, (a0)
    nop
    nop
    move.b  (a0), d0
    move.b  #0x00, (a0)
    nop
    nop
    move.b  (a0), d1
    move.b  #0x40, (a0)
    moveq   #-1, d2
    btst    #3, d0
    bne.s   1f
    bclr    #0, d2
1:  btst    #2, d0
    bne.s   2f
    bclr    #1, d2
2:  btst    #1, d0
    bne.s   3f
    bclr    #2, d2
3:  btst    #0, d0
    bne.s   4f
    bclr    #3, d2
4:  btst    #4, d0
    bne.s   5f
    bclr    #4, d2
5:  btst    #5, d0
    bne.s   6f
    bclr    #5, d2
6:  move.b  d2, IO_SHADOW + 1
    moveq   #-1, d2
    btst    #4, d1
    bne.s   7f
    bclr    #0, d2
7:  btst    #5, d1
    bne.s   8f
    bclr    #4, d2
8:  move.b  d2, IO_SHADOW + 0x18
    rts

hal_crash:
    move.w  #0x2700, sr
    move.l  #0xc0000000, VDP_CTRL
    move.w  #0x000e, VDP_DATA
1:  bra.s   1b

vdp_init:
    .word   0x8004, 0x8134, 0x8230, 0x8334, 0x8407, 0x857a, 0x8600, 0x8700
    .word   0x8800, 0x8900, 0x8a00, 0x8b00, 0x8c81, 0x8d3c, 0x8e00, 0x8f02
    .word   0x9001, 0x9100, 0x9200
vdp_init_end:

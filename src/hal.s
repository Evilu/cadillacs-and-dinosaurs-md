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
    .equ pal_known,     HAL_VARS + 68   | bit p: pal_line[p] chosen for the current lines
    .equ last_flag,     HAL_VARS + 64   | SHOWN_FLAG at the last VBlank
    .equ list_dirty,    HAL_VARS + 72   | the game showed a new list since the last conversion
    .equ conv_wait,     HAL_VARS + 74   | frames since the last conversion
    .equ conv_gap,      HAL_VARS + 76   | least frames between conversions: 2, or 3 when the game falls behind
    .equ flips,         HAL_VARS + 78   | lists shown in the current 32-frame window
    .equ conv_count,    HAL_VARS + 80
    .equ cram_dirty,    HAL_VARS + 82
    .equ ent_left,      HAL_VARS + 66
    .equ RAW_CACHE,     0xff1920    | arcade colour last converted for each CRAM entry

    .equ SPRITES_A,     0xff2000    | arcade 0x900000 sprite list
    .equ SPRITES_B,     0xff2800    | arcade 0x904000 sprite list
    .equ PALETTES,      0xff3000    | arcade 0x914000-0x914fff: palette pages 0-3
    .equ SAT_BUF,       0xff1320    | 80 entries
    .equ CACHE_KEY,     0xff15a0    | 64 words
    .equ CACHE_STAMP,   0xff16a0    | 64 words (CACHE_KEY + 0x100)
    .equ QUEUE,         0xff17a0    | upload queue: long source, word VRAM address, word length
    .equ PAL_COUNT,     0xff1860    | 32 words
    .equ CRAM_BUF,      0xff18a0    | 64 words
    .equ SHOWN_FLAG,    0xffe9b4    | nonzero: list B is the finished one

    .equ COLOUR_TABLE,  0x187f00    | [brightness][nibble] -> Mega Drive 3-bit level << 1
    .equ TILE_FLAGS,    0x188000    | per arcade 16x16 tile: bit 0 has pixels, bit 1 fully opaque
    .equ TILE_FIRST,    0x0000      | all 32768 arcade 16x16 tiles are stored
    .equ TILE_END,      0x8000
    .equ TILE_DATA,     0x200000    | ROM address of tile 0, 128 bytes per tile
    .equ PATCH_TABLE,   0x190000    | instructions replaced by TRAP #8: count, then 16-byte entries
    .equ WINDOW,        0x380000    | mapper region 7
    .equ MAPPER7,       0xa130ff
    .equ SLOT_BASE,     0x20        | first VRAM pattern of the sprite cache
    .equ MAX_QUEUE,     22
    .equ MAX_SPRITES,   80

    .equ HAL_STACK_LO,  0xff1c20
    .equ HAL_STACK_TOP, 0xff2000

| The arcade's supervisor stack (0xff0e66) sits just above its task stacks and
| has no room for the hardware layer. Handlers switch to their own stack; the
| exception frame stays on the old one, behind the saved a0.
    .macro  hal_enter
    move.l  a0, -(sp)
    movea.l sp, a0
    cmpa.l  #HAL_STACK_LO, a0
    blo.s   1001f
    cmpa.l  #HAL_STACK_TOP, a0
    bls.s   1002f
1001:
    movea.l #HAL_STACK_TOP, sp
1002:
    move.l  a0, -(sp)
    movea.l (a0), a0
    .endm

    .macro  hal_leave
    movea.l (sp), sp
    addq.l  #4, sp
    .endm

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
    move.w  #1, conv_gap
    bsr.w   bg_init
    move.w  #0x8174, VDP_CTRL
    jmp     ARCADE_START

| Level 6. Sends last frame's video work, refreshes inputs, runs Capcom's VBlank
| handler, then converts the sprite list it just made visible.
hal_vblank:
    hal_enter
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
    bsr.w   bgpal_update
    bsr.w   update_scroll2
    bsr.w   update_scroll3
    bsr.w   build_cram
    movem.l (sp)+, d0-d7/a0-a6
    hal_leave
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
3:  move.l  #0x70000003, (a4)
    move.w  s3_hscroll, VDP_DATA
    move.w  s2_hscroll, VDP_DATA
    move.l  #0x40000010, (a4)
    move.w  s3_vscroll, VDP_DATA
    move.w  s2_vscroll, VDP_DATA
    tst.b   cram_dirty
    beq.s   4f
    clr.b   cram_dirty
    move.l  #0x93409400, (a4)
    move.l  #0x9550968c, (a4)
    move.w  #0x977f, (a4)
    move.w  #0xc000, (a4)
    move.w  #0x0080, -(sp)
    move.w  (sp)+, (a4)
4:  rts

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

| Runs when the game has shown a new list, at most every second frame: the 68000
| cannot convert the list 60 times a second alongside the game. Every 32 frames
| the gap grows by a frame (to four at most) if the game showed fewer than 20
| lists, and shrinks by one (to two at least) if it showed 28 or more. Palette lines are
| reassigned every 8 frames.
build_sprites:
    addq.w  #1, conv_wait
    move.w  SHOWN_FLAG, d0
    cmp.w   last_flag, d0
    beq.s   0f
    move.w  d0, last_flag
    move.w  #1, list_dirty
    addq.w  #1, flips
0:  move.l  hal_frames, d1
    andi.w  #31, d1
    bne.s   2f
    move.w  conv_gap, d1
    cmpi.w  #20, flips
    bhs.s   5f
    cmpi.w  #4, d1
    bhs.s   6f
    addq.w  #1, d1
    bra.s   6f
5:  cmpi.w  #28, flips
    blo.s   6f
    cmpi.w  #1, d1
    bls.s   6f
    subq.w  #1, d1
6:  move.w  d1, conv_gap
    clr.w   flips
2:  tst.w   list_dirty
    beq.s   1f
    move.w  conv_wait, d1
    cmp.w   conv_gap, d1
    bhs.s   7f
1:  rts
7:  clr.w   conv_wait
    clr.w   list_dirty
    addq.w  #2, conv_count
    move.w  conv_count, d1
    addq.w  #1, stamp
    lea     SPRITES_A, a0
    tst.w   d0
    beq.s   3f
    lea     SPRITES_B, a0
3:  andi.w  #7, d1
    bne.s   4f
    bsr.w   count_palettes
    bsr.w   assign_lines
4:  lea     SAT_BUF, a1
    clr.w   sat_count
    lea     TILE_FLAGS, a2
    move.w  #255, ent_left
next_entry:
    move.l  (a0), d0
    or.l    4(a0), d0
    beq.w   entries_done
    cmpi.b  #0xff, 6(a0)
    beq.w   entries_done
    move.w  4(a0), d5
    bmi.w   skip_entry
    move.w  6(a0), d1
    move.w  d1, d7
    lsr.w   #8, d7
    andi.w  #15, d7
    addq.w  #1, d7
    move.w  d1, d0
    rol.w   #4, d0
    andi.w  #15, d0
    addq.w  #1, d0
    move.w  d0, e_ny
    move.w  (a0), d2
    andi.w  #0x1ff, d2
    cmpi.w  #0x1c0, d2
    blt.s   3f
    subi.w  #0x200, d2
3:  addi.w  #32, d2
    cmpi.w  #448, d2
    bge.w   skip_entry
    move.w  d7, d0
    lsl.w   #4, d0
    add.w   d2, d0
    cmpi.w  #128 - 16, d0
    ble.w   skip_entry
    movea.w d2, a4
    move.w  2(a0), d3
    andi.w  #0x1ff, d3
    cmpi.w  #0x180, d3
    blt.s   4f
    subi.w  #0x200, d3
4:  addi.w  #112, d3
    cmpi.w  #352, d3
    bge.w   skip_entry
    move.w  e_ny, d0
    lsl.w   #4, d0
    add.w   d3, d0
    cmpi.w  #128, d0
    ble.w   skip_entry
    move.w  d3, e_y
    move.w  d1, d0
    andi.w  #0x60, d0
    move.w  d0, e_flip
    lsl.w   #6, d0
    ori.w   #0x8000, d0
    andi.w  #0x1f, d1
    lea     pal_line, a3
    moveq   #0, d6
    move.b  0(a3,d1.w), d6
    ror.w   #3, d6
    or.w    d6, d0
    movea.w d0, a6
    clr.w   e_row
row_loop:
    move.w  e_row, d3
    btst    #6, e_flip + 1
    beq.s   5f
    move.w  e_ny, d0
    subq.w  #1, d0
    sub.w   d3, d0
    move.w  d0, d3
5:  lsl.w   #4, d3
    add.w   e_y, d3
    cmpi.w  #128 - 16, d3
    ble.w   row_next
    cmpi.w  #352, d3
    bge.w   row_next
    move.w  e_row, d0
    lsl.w   #4, d0
    move.w  d5, d1
    andi.w  #0xfff0, d1
    add.w   d1, d0
    movea.w d0, a5
    moveq   #0, d4
    btst    #5, e_flip + 1
    bne.w   col_loop_flip
col_loop:
    move.w  d5, d0
    add.w   d4, d0
    andi.w  #15, d0
    moveq   #0, d6
    cmpi.w  #15, d0
    beq.s   6f
    move.w  d4, d1
    addq.w  #1, d1
    cmp.w   d7, d1
    bge.s   6f
    moveq   #1, d6
6:  add.w   a5, d0
    bmi.w   col_next
    move.w  d4, d2
    lsl.w   #4, d2
    add.w   a4, d2
    cmpi.w  #128 - 32, d2
    ble.w   col_next
    cmpi.w  #448, d2
    bge.w   col_next
    move.b  0(a2,d0.w), d1
    tst.w   d6
    beq.s   1f
    or.b    1(a2,d0.w), d1
1:  tst.b   d1
    beq.w   col_next
    move.w  d0, d1
    tst.w   d6
    bne.s   2f
    ori.w   #0x8000, d1
2:  move.w  d1, d0
    lsr.w   #4, d0
    eor.w   d1, d0
    lsl.w   #2, d0
    andi.w  #0x78, d0
    lea     CACHE_KEY, a3
    adda.w  d0, a3
    cmp.w   (a3)+, d1
    beq.s   ep_hit
    cmp.w   (a3)+, d1
    beq.s   ep_hit
    cmp.w   (a3)+, d1
    beq.s   ep_hit
    cmp.w   (a3)+, d1
    beq.s   ep_hit
    addq.w  #8, d0
    andi.w  #0x78, d0
    lea     CACHE_KEY, a3
    adda.w  d0, a3
    cmp.w   (a3)+, d1
    beq.s   ep_hit
    cmp.w   (a3)+, d1
    beq.s   ep_hit
    cmp.w   (a3)+, d1
    beq.s   ep_hit
    cmp.w   (a3)+, d1
    beq.s   ep_hit
    move.w  d1, d0
    andi.w  #0x7fff, d0
    bsr.w   emit_piece
    bra.s   ep_done
ep_hit:
    subq.l  #2, a3
    move.w  stamp, 0x100(a3)
    move.w  a3, d0
    lsl.w   #2, d0
    subi.w  #0x5660, d0
    move.w  a6, d1
    or.w    d0, d1
    move.w  d3, (a1)+
    move.w  a1, d0
    lsr.w   #3, d0
    subi.w  #0x263, d0
    tst.w   d6
    beq.s   3f
    ori.w   #0x0d00, d0
    bra.s   4f
3:  ori.w   #0x0500, d0
4:  move.w  d0, (a1)+
    move.w  d1, (a1)+
    move.w  d2, (a1)+
ep_done:
    cmpa.l  #SAT_BUF + MAX_SPRITES * 8, a1
    bhs.w   entries_done
col_next:
    addq.w  #1, d4
    add.w   d6, d4
    cmp.w   d7, d4
    blt.w   col_loop
    bra.w   row_next
col_loop_flip:
    move.w  d5, d0
    add.w   d4, d0
    andi.w  #15, d0
    moveq   #0, d6
    cmpi.w  #15, d0
    beq.s   6f
    move.w  d4, d1
    addq.w  #1, d1
    cmp.w   d7, d1
    bge.s   6f
    moveq   #1, d6
6:  add.w   a5, d0
    bmi.w   col_next_flip
    move.w  d7, d2
    subq.w  #1, d2
    sub.w   d4, d2
    sub.w   d6, d2
    lsl.w   #4, d2
    add.w   a4, d2
    cmpi.w  #128 - 32, d2
    ble.w   col_next_flip
    cmpi.w  #448, d2
    bge.w   col_next_flip
    move.b  0(a2,d0.w), d1
    tst.w   d6
    beq.s   1f
    or.b    1(a2,d0.w), d1
1:  tst.b   d1
    beq.w   col_next_flip
    move.w  d0, d1
    tst.w   d6
    bne.s   2f
    ori.w   #0x8000, d1
2:  move.w  d1, d0
    lsr.w   #4, d0
    eor.w   d1, d0
    lsl.w   #2, d0
    andi.w  #0x78, d0
    lea     CACHE_KEY, a3
    adda.w  d0, a3
    cmp.w   (a3)+, d1
    beq.s   ep_hit_flip
    cmp.w   (a3)+, d1
    beq.s   ep_hit_flip
    cmp.w   (a3)+, d1
    beq.s   ep_hit_flip
    cmp.w   (a3)+, d1
    beq.s   ep_hit_flip
    addq.w  #8, d0
    andi.w  #0x78, d0
    lea     CACHE_KEY, a3
    adda.w  d0, a3
    cmp.w   (a3)+, d1
    beq.s   ep_hit_flip
    cmp.w   (a3)+, d1
    beq.s   ep_hit_flip
    cmp.w   (a3)+, d1
    beq.s   ep_hit_flip
    cmp.w   (a3)+, d1
    beq.s   ep_hit_flip
    move.w  d1, d0
    andi.w  #0x7fff, d0
    bsr.w   emit_piece
    bra.s   ep_done_flip
ep_hit_flip:
    subq.l  #2, a3
    move.w  stamp, 0x100(a3)
    move.w  a3, d0
    lsl.w   #2, d0
    subi.w  #0x5660, d0
    move.w  a6, d1
    or.w    d0, d1
    move.w  d3, (a1)+
    move.w  a1, d0
    lsr.w   #3, d0
    subi.w  #0x263, d0
    tst.w   d6
    beq.s   3f
    ori.w   #0x0d00, d0
    bra.s   4f
3:  ori.w   #0x0500, d0
4:  move.w  d0, (a1)+
    move.w  d1, (a1)+
    move.w  d2, (a1)+
ep_done_flip:
    cmpa.l  #SAT_BUF + MAX_SPRITES * 8, a1
    bhs.w   entries_done
col_next_flip:
    addq.w  #1, d4
    add.w   d6, d4
    cmp.w   d7, d4
    blt.w   col_loop_flip
row_next:
    move.w  e_row, d0
    addq.w  #1, d0
    move.w  d0, e_row
    cmp.w   e_ny, d0
    blt.w   row_loop
skip_entry:
    addq.l  #8, a0
    subq.w  #1, ent_left
    bpl.w   next_entry
entries_done:
    move.w  a1, d0
    subi.w  #SAT_BUF & 0xffff, d0
    lsr.w   #3, d0
    move.w  d0, sat_count
    bne.s   8f
    lea     SAT_BUF, a1
    clr.l   (a1)+
    clr.l   (a1)+
    move.w  #1, sat_count
    rts
8:  subq.w  #1, d0
    lsl.w   #3, d0
    lea     SAT_BUF, a1
    clr.b   3(a1,d0.w)
    rts

| d0 first tile, d6 1 for two tiles side by side, d2 x, d3 y, a6 attribute bits
| keeps d2-d7, a0, a2, a4-a6
emit_piece:
    move.b  0(a2,d0.w), d1
    tst.w   d6
    beq.s   1f
    or.b    1(a2,d0.w), d1
1:  tst.b   d1
    beq.w   9f
    movem.l d4-d5, -(sp)
    move.w  d0, d5
    tst.w   d6
    bne.s   2f
    ori.w   #0x8000, d5
2:  move.w  d5, d4
    lsr.w   #4, d4
    eor.w   d5, d4
    lsr.w   #1, d4
    andi.w  #15, d4
    lsl.w   #3, d4
    lea     CACHE_KEY, a3
    adda.w  d4, a3
    cmp.w   (a3)+, d5
    beq.w   hit
    cmp.w   (a3)+, d5
    beq.w   hit
    cmp.w   (a3)+, d5
    beq.w   hit
    cmp.w   (a3)+, d5
    beq.w   hit
    addq.w  #8, d4
    andi.w  #0x78, d4
    lea     CACHE_KEY, a3
    adda.w  d4, a3
    cmp.w   (a3)+, d5
    beq.w   hit
    cmp.w   (a3)+, d5
    beq.w   hit
    cmp.w   (a3)+, d5
    beq.w   hit
    cmp.w   (a3)+, d5
    beq.w   hit
    cmpi.w  #MAX_QUEUE, queue_count
    bhs.w   8f
    move.w  stamp, d1
    subq.w  #8, d4
    andi.w  #0x78, d4
    lea     CACHE_KEY, a3
    adda.w  d4, a3
    bsr.w   free_way
    bne.s   3f
    addq.w  #8, d4
    andi.w  #0x78, d4
    lea     CACHE_KEY, a3
    adda.w  d4, a3
    bsr.w   free_way
    bne.s   3f
    move.w  #14, -(sp)
ep_scan:
    addq.w  #8, d4
    andi.w  #0x78, d4
    lea     CACHE_KEY, a3
    adda.w  d4, a3
    bsr.w   free_way
    bne.s   ep_found
    subq.w  #1, (sp)
    bne.s   ep_scan
    addq.l  #2, sp
    bra.w   8f
ep_found:
    addq.l  #2, sp
3:  move.w  d5, (a3)
    move.w  d1, 0x100(a3)
    move.l  a3, d4
    subi.l  #CACHE_KEY, d4
    lsl.w   #2, d4
    addi.w  #SLOT_BASE, d4
    move.w  queue_count, d5
    lsl.w   #3, d5
    lea     QUEUE, a3
    adda.w  d5, a3
    moveq   #0, d5
    move.w  d0, d5
    lsl.l   #7, d5
    addi.l  #TILE_DATA, d5
    move.l  d5, (a3)+
    move.w  d4, d5
    lsl.w   #5, d5
    move.w  d5, (a3)+
    moveq   #64, d5
    tst.w   d6
    beq.s   4f
    add.w   d5, d5
4:  move.w  d5, (a3)
    addq.w  #1, queue_count
    bra.s   write_sat
hit:
    subq.l  #2, a3
    move.w  stamp, 0x100(a3)
    move.l  a3, d4
    subi.l  #CACHE_KEY, d4
    lsl.w   #2, d4
    addi.w  #SLOT_BASE, d4
write_sat:
    move.w  d3, (a1)+
    move.w  a1, d1
    lsr.w   #3, d1
    subi.w  #0x263, d1
    moveq   #0x05, d5
    tst.w   d6
    beq.s   5f
    moveq   #0x0d, d5
5:  lsl.w   #8, d5
    move.b  d1, d5
    move.w  d5, (a1)+
    move.w  a6, d5
    or.w    d4, d5
    move.w  d5, (a1)+
    move.w  d2, (a1)+
8:  movem.l (sp)+, d4-d5
9:  rts

| a3 cache set, d1 stamp -> NE and a3 on a way not used this frame, or EQ
free_way:
    cmp.w   0x100(a3), d1
    bne.s   1f
    addq.l  #2, a3
    cmp.w   0x100(a3), d1
    bne.s   1f
    addq.l  #2, a3
    cmp.w   0x100(a3), d1
    bne.s   1f
    addq.l  #2, a3
    cmp.w   0x100(a3), d1
1:  rts

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
2:  move.l  (a2), d0
    or.l    4(a2), d0
    beq.s   3f
    move.w  6(a2), d0
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

| Sprites get lines 0 to 2; line 3 belongs to the backgrounds (bgpal.s). A line keeps
| its palette while that palette is on screen, unless another covers a quarter more
| area; the players' palettes (0 to 2) always win. Palettes without a line use the
| line whose colours are closest, chosen again every 16 conversions because the
| game fades palettes in.
assign_lines:
    movem.l d0-d7/a0-a5, -(sp)
    lea     PAL_COUNT, a1
    moveq   #2, d0
0:  tst.w   (a1)
    beq.s   1f
    ori.w   #0x4000, (a1)
1:  addq.l  #2, a1
    dbra    d0, 0b
    move.w  conv_count, d0
    andi.w  #0x1f, d0
    bne.s   1f
    clr.l   pal_known
1:  lea     PAL_COUNT, a1
    lea     line_pal, a3
    move.l  (a3), -(sp)
    moveq   #2, d3
1:  moveq   #0, d0
    move.b  0(a3,d3.w), d0
    cmpi.b  #0xff, d0
    beq.s   2f
    add.w   d0, d0
    tst.w   0(a1,d0.w)
    bne.s   2f
    move.b  #0xff, 0(a3,d3.w)
2:  dbra    d3, 1b
    moveq   #2, d7
3:  moveq   #0, d1
    moveq   #-1, d2
    moveq   #0, d0
4:  cmp.b   (a3), d0
    beq.s   5f
    cmp.b   1(a3), d0
    beq.s   5f
    cmp.b   2(a3), d0
    beq.s   5f
    move.w  d0, d4
    add.w   d4, d4
    move.w  0(a1,d4.w), d4
    cmp.w   d4, d1
    bcc.s   5f
    move.w  d4, d1
    move.w  d0, d2
5:  addq.w  #1, d0
    cmpi.w  #32, d0
    blt.s   4b
    tst.w   d2
    bmi.s   9f
    moveq   #0, d3
6:  cmpi.b  #0xff, 0(a3,d3.w)
    beq.s   8f
    addq.w  #1, d3
    cmpi.w  #3, d3
    blt.s   6b
    move.w  #0xffff, d4
    moveq   #0, d6
7:  moveq   #0, d0
    move.b  0(a3,d6.w), d0
    add.w   d0, d0
    move.w  0(a1,d0.w), d5
    cmp.w   d4, d5
    bcc.s   17f
    move.w  d5, d4
    move.w  d6, d3
17: addq.w  #1, d6
    cmpi.w  #3, d6
    blt.s   7b
    move.w  d4, d0
    lsr.w   #2, d0
    add.w   d0, d4
    bcs.s   9f
    cmp.w   d4, d1
    bls.s   9f
8:  move.b  d2, 0(a3,d3.w)
    dbra    d7, 3b
9:  move.l  (sp)+, d0
    cmp.l   (a3), d0
    beq.s   10f
    clr.l   pal_known
10: lea     pal_line, a5
    moveq   #0, d3
11: moveq   #2, d4
12: cmp.b   0(a3,d4.w), d3
    bne.s   13f
    move.b  d4, (a5)
    bra.s   16f
13: dbra    d4, 12b
    move.w  d3, d0
    add.w   d0, d0
    tst.w   0(a1,d0.w)
    beq.s   15f
    move.l  pal_known, d0
    btst    d3, d0
    bne.s   16f
    bset    d3, d0
    move.l  d0, pal_known
    clr.b   (a5)
    move.w  #0x7fff, d5
    moveq   #2, d4
14: moveq   #0, d0
    move.b  0(a3,d4.w), d0
    cmpi.b  #0xff, d0
    beq.s   18f
    bsr.s   pal_distance
    cmp.w   d5, d0
    bhs.s   18f
    move.w  d0, d5
    move.b  d4, (a5)
18: dbra    d4, 14b
    bra.s   16f
15: move.l  pal_known, d0
    bclr    d3, d0
    move.l  d0, pal_known
    clr.b   (a5)
16: addq.l  #1, a5
    addq.w  #1, d3
    cmpi.w  #32, d3
    blt.s   11b
    movem.l (sp)+, d0-d7/a0-a5
    rts

| d3 arcade sprite palette, d0 another -> d0 sum of RGB nibble differences
pal_distance:
    movem.l d1-d2/d4-d7/a2/a4, -(sp)
    lsl.w   #5, d0
    lea     PALETTES, a2
    lea     0(a2,d0.w), a4
    move.w  d3, d0
    lsl.w   #5, d0
    adda.w  d0, a2
    moveq   #0, d0
    moveq   #14, d7
1:  move.w  (a2)+, d4
    move.w  (a4)+, d6
    moveq   #2, d2
2:  move.w  d4, d1
    andi.w  #15, d1
    move.w  d6, d5
    andi.w  #15, d5
    sub.w   d5, d1
    bpl.s   3f
    neg.w   d1
3:  add.w   d1, d0
    lsr.w   #4, d4
    lsr.w   #4, d6
    dbra    d2, 2b
    dbra    d7, 1b
    movem.l (sp)+, d1-d2/d4-d7/a2/a4
    rts

| Converts only the colours whose arcade value changed since the last frame.
| Unchanged colours are skipped two at a time.
build_cram:
    lea     CRAM_BUF, a1
    lea     line_pal, a3
    lea     COLOUR_TABLE, a4
    lea     RAW_CACHE, a5
    moveq   #3, d7
1:  addq.l  #2, a1
    addq.l  #2, a5
    moveq   #0, d0
    move.b  (a3)+, d0
    tst.w   d7
    bne.s   6f
    btst    #0, hal_frames + 3
    bne.w   5f
    lea     LINE_SRC, a0
    lea     LINE_RAW, a2
    lea     PALETTES, a6
    moveq   #14, d6
9:  move.w  (a0)+, d0
    bmi.s   10f
    move.w  0(a6,d0.w), (a2)+
    bra.s   11f
10: clr.w   (a2)+
11: dbra    d6, 9b
    lea     LINE_RAW, a2
    bra.s   7f
6:  tst.b   d0
    bmi.s   4f
    lsl.w   #5, d0
    lea     PALETTES, a2
    adda.w  d0, a2
7:  moveq   #6, d6
2:  cmpm.l  (a2)+, (a5)+
    bne.s   8f
    addq.l  #4, a1
    dbra    d6, 2b
    bra.s   12f
8:  subq.l  #4, a2
    subq.l  #4, a5
    bsr.s   cram_one
    bsr.s   cram_one
    dbra    d6, 2b
12: bsr.s   cram_one
    bra.s   5f
4:  moveq   #14, d6
3:  clr.w   (a1)+
    clr.w   (a5)+
    dbra    d6, 3b
5:  dbra    d7, 1b
    rts

| a2 arcade colour, a5 its cached copy, a1 Mega Drive colour, a4 colour table
cram_one:
    move.w  (a2)+, d0
    cmp.w   (a5), d0
    beq.s   2f
    move.w  d0, (a5)
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
    move.w  d3, (a1)
    st      cram_dirty
2:  addq.l  #2, a5
    addq.l  #2, a1
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

| Capcom's new-game initialiser clears 0xff0e66-0xff7fff; the hardware layer lives from
| 0xff1000, so only the game's own part is cleared. Leaves d0 zero.
hal_clear_game_ram:
    lea     0xff0e66, a0
    moveq   #0, d0
1:  move.w  d0, (a0)+
    cmpa.l  #0xff1000, a0
    bne.s   1b
    rts

hal_crash:
    move.w  #0x2700, sr
    move.l  #0xc0000000, VDP_CTRL
    move.w  #0x000e, VDP_DATA
1:  bra.s   1b

vdp_init:
    .word   0x8004, 0x8134, 0x8238, 0x8334, 0x8406, 0x857a, 0x8600, 0x8700
    .word   0x8800, 0x8900, 0x8a00, 0x8b00, 0x8c81, 0x8d3c, 0x8e00, 0x8f02
    .word   0x9001, 0x9100, 0x9200
vdp_init_end:

    .include "background.s"
    .include "bgpal.s"
    .include "farbg.s"

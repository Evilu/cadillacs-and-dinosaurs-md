| Hardware layer for the Mega Drive build, linked after the arcade program.

    .equ IO_SHADOW,     0xff1000    | arcade 0x800000-0x8001ff
    .equ Q_SHADOW,      0xff1200    | arcade 0xf18000-0xf1803f
    .equ P3_SHADOW,     0xff1280    | arcade 0xf1c000-0xf1c01f
    .equ HAL_VARS,      0xff12c0
    .equ hal_frames,    HAL_VARS
    .equ box_count,     HAL_VARS + 4
    .equ SPRITES_A,     0xff2000    | arcade 0x900000 sprite list
    .equ SPRITES_B,     0xff2800    | arcade 0x904000 sprite list
    .equ SHOWN_FLAG,    0xffe9b4    | nonzero: list B is the finished one

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
    move.w  #0x0100, 0xa11200
    lea     vdp_init(pc), a0
    moveq   #(vdp_init_end - vdp_init) / 2 - 1, d0
2:  move.w  (a0)+, VDP_CTRL
    dbra    d0, 2b
    move.l  #0xc0000000, VDP_CTRL
    moveq   #63, d0
3:  move.w  #0, VDP_DATA
    dbra    d0, 3b
    move.b  #0x40, PAD1_CTRL
    move.b  #0x40, PAD1_DATA
    bsr.w   load_box_graphics
    jmp     ARCADE_RESET

load_box_graphics:
    move.l  #0x40200000, VDP_CTRL
    moveq   #15, d0
1:  move.l  #0x22222222, VDP_DATA
    moveq   #6, d1
2:  move.l  #0x21111111, VDP_DATA
    dbra    d1, 2b
    dbra    d0, 1b
    lea     box_colours(pc), a0
    move.l  #0xc0000000, d1
    moveq   #3, d0
3:  move.l  d1, VDP_CTRL
    move.w  (a0)+, VDP_DATA
    move.w  (a0)+, VDP_DATA
    move.w  (a0)+, VDP_DATA
    addi.l  #0x00200000, d1
    dbra    d0, 3b
    rts

box_colours:
    .word   0x0420, 0x0eee, 0x0000
    .word   0x0000, 0x00ee, 0x0000
    .word   0x0000, 0x0e80, 0x0000
    .word   0x0000, 0x0e4e, 0x0000

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
    move.w  #0x8174, VDP_CTRL
    jmp     ARCADE_START

hal_vblank:
    movem.l d0-d7/a0-a2, -(sp)
    move.w  VDP_CTRL, d0
    bsr.w   draw_boxes
    addq.l  #1, hal_frames
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
    movem.l (sp)+, d0-d7/a0-a2
    jmp     ARCADE_VBLANK

| Draws every entry of the finished arcade sprite list as outlined boxes:
| one Mega Drive sprite per 32x32 piece of each tile block.
draw_boxes:
    move.l  #0x74000003, VDP_CTRL
    lea     VDP_DATA, a1
    lea     SPRITES_A, a0
    tst.w   SHOWN_FLAG
    beq.s   1f
    lea     SPRITES_B, a0
1:  clr.w   box_count
    move.w  #255, d6
box_entry:
    move.w  6(a0), d3
    move.w  d3, d0
    andi.w  #0xff00, d0
    cmpi.w  #0xff00, d0
    beq.w   box_done
    move.w  (a0), d0
    andi.w  #0x1ff, d0
    cmpi.w  #0x1c0, d0
    blt.s   2f
    subi.w  #0x200, d0
2:  addi.w  #32, d0
    move.w  2(a0), d1
    andi.w  #0x1ff, d1
    cmpi.w  #0x180, d1
    blt.s   3f
    subi.w  #0x200, d1
3:  addi.w  #112, d1
    move.w  d3, d4
    lsr.w   #8, d4
    andi.w  #15, d4
    addq.w  #1, d4
    move.w  d3, d5
    rol.w   #4, d5
    andi.w  #15, d5
    addq.w  #1, d5
    andi.w  #3, d3
    ror.w   #3, d3
    ori.w   #0x8001, d3
    move.w  d6, -(sp)
box_row:
    move.w  d5, d2
    cmpi.w  #2, d2
    bls.s   4f
    moveq   #2, d2
4:  movea.w d0, a2
    move.w  d4, d6
box_col:
    move.w  d6, d7
    cmpi.w  #2, d7
    bls.s   5f
    moveq   #2, d7
5:  cmpi.w  #79, box_count
    bhs.s   box_full
    cmpa.w  #0, a2
    bne.s   6f
    addq.w  #1, a2
6:  move.w  d1, (a1)
    move.w  d7, -(sp)
    lsl.w   #3, d7
    subq.w  #4, d7
    add.w   d2, d7
    add.w   d2, d7
    subq.w  #1, d7
    lsl.w   #8, d7
    addq.w  #1, box_count
    or.b    box_count + 1, d7
    move.w  d7, (a1)
    move.w  d3, (a1)
    move.w  a2, (a1)
    move.w  (sp)+, d7
    move.w  d7, -(sp)
    lsl.w   #4, d7
    adda.w  d7, a2
    move.w  (sp)+, d7
    sub.w   d7, d6
    bgt.s   box_col
    move.w  d2, d7
    lsl.w   #4, d7
    add.w   d7, d1
    sub.w   d2, d5
    bgt.s   box_row
    move.w  (sp)+, d6
    addq.l  #8, a0
    dbra    d6, box_entry
    bra.s   box_done
box_full:
    addq.l  #2, sp
box_done:
    moveq   #0, d0
    move.w  d0, (a1)
    move.w  d0, (a1)
    move.w  d0, (a1)
    move.w  d0, (a1)
    rts

| Pad 1 -> arcade player 1 and system inputs (all active low).
| B = attack, C = jump, A = coin, Start = start.
read_pad:
    lea     PAD1_DATA, a0
    move.b  #0x40, (a0)
    nop
    nop
    move.b  (a0), d0            | --CBRLDU
    move.b  #0x00, (a0)
    nop
    nop
    move.b  (a0), d1            | --SA00DU
    move.b  #0x40, (a0)
    moveq   #-1, d2
    btst    #3, d0
    bne.s   1f
    bclr    #0, d2              | right
1:  btst    #2, d0
    bne.s   2f
    bclr    #1, d2              | left
2:  btst    #1, d0
    bne.s   3f
    bclr    #2, d2              | down
3:  btst    #0, d0
    bne.s   4f
    bclr    #3, d2              | up
4:  btst    #4, d0
    bne.s   5f
    bclr    #4, d2              | button 1
5:  btst    #5, d0
    bne.s   6f
    bclr    #5, d2              | button 2
6:  move.b  d2, IO_SHADOW + 1
    moveq   #-1, d2
    btst    #4, d1
    bne.s   7f
    bclr    #0, d2              | coin 1
7:  btst    #5, d1
    bne.s   8f
    bclr    #4, d2              | start 1
8:  move.b  d2, IO_SHADOW + 0x18
    rts

hal_crash:
    move.w  #0x2700, sr
    move.w  #0x8700, VDP_CTRL
    move.l  #0xc0000000, VDP_CTRL
    move.w  #0x000e, VDP_DATA
1:  bra.s   1b

vdp_init:
    .word   0x8004, 0x8134, 0x8230, 0x8334, 0x8407, 0x857a, 0x8600, 0x8700
    .word   0x8800, 0x8900, 0x8a00, 0x8b00, 0x8c81, 0x8d3c, 0x8e00, 0x8f02
    .word   0x9001, 0x9100, 0x9200
vdp_init_end:

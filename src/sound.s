| Sound. The game hands the QSound board one command a frame through the shared RAM
| (here Q_SHADOW); sound_frame takes it after Capcom's VBlank handler has run. Tunes are
| streams of YM2612 and PSG writes per frame made at build time (tools/build/sound.py),
| on FM channels 1-5 and the PSG. Channel 6 is the DAC: the Z80 plays drums and effects
| through it, one at a time, an effect before a drum. The 68000 takes the bus from the
| Z80 only while it writes registers or the mailbox.

    .equ SND_VARS,      0xff12a0    | 0xff12a0-0xff12bf is free: between the player 3 shadow and HAL_VARS
    .equ snd_at,        SND_VARS        | tune stream position, 0 when no tune plays
    .equ snd_base,      SND_VARS + 4    | start of the stream
    .equ snd_wait,      SND_VARS + 8    | frames to skip
    .equ snd_busy,      SND_VARS + 10   | frames the effect in the DAC still lasts
    .equ snd_bank,      SND_VARS + 12   | ROM bank of the stream
    .equ SOUND_TABLE,   0x186000        | 256 commands x 12 bytes: kind, ROM bank, then stream offset or mailbox
    .equ PCM_TABLE,     SOUND_TABLE + 256 * 12
    .equ Z80_DRIVER,    PCM_TABLE + 256 * 12
    .equ STREAMS,       0x300000        | mapper region 6
    .equ MAPPER5,       0xa130fb        | region 5, 0x280000: PCM, read by the Z80
    .equ MAPPER6,       0xa130fd
    .equ YM_PORT,       0xa04000
    .equ PSG_PORT,      0xc00011
    .equ Z80_RAM,       0xa00000
    .equ Z80_MAILBOX,   0xa01f00
    .equ Z80_BUS,       0xa11100
    .equ Z80_RESET,     0xa11200

sound_init:
    clr.l   snd_at
    clr.w   snd_busy
    move.w  #0x0100, Z80_RESET
    bsr.w   z80_stop
    lea     Z80_DRIVER, a0
    lea     Z80_RAM, a1
    move.w  (a0)+, d0
    beq.s   3f
    subq.w  #1, d0
1:  move.b  (a0)+, (a1)+
    dbra    d0, 1b
    clr.b   Z80_MAILBOX
    move.w  #0x0000, Z80_RESET
    move.w  #0x0000, Z80_BUS
    moveq   #127, d0
2:  dbra    d0, 2b
    move.w  #0x0100, Z80_RESET
    bsr.w   z80_stop
    lea     YM_PORT, a1
    moveq   #0x2b, d0
    move.b  #0x80, d1
    bsr.w   ym_write
    moveq   #0x2a, d0
    move.b  #0x80, d1
    bsr.w   ym_write
    bsr.w   sound_quiet
    bra.w   z80_start
3:  rts

z80_stop:
    move.w  #0x0100, Z80_BUS
1:  btst    #0, Z80_BUS
    bne.s   1b
    rts

| The address port is left on the DAC register: a Z80 stopped between choosing that
| register and writing a sample still writes to it.
z80_start:
    move.b  #0x2a, YM_PORT
    move.w  #0x0000, Z80_BUS
    rts

sound_frame:
    tst.w   snd_busy
    beq.s   1f
    subq.w  #1, snd_busy
1:  tst.b   Q_SHADOW + 0x1f
    bne.w   sound_play
    st      Q_SHADOW + 0x1f
    moveq   #0, d0
    move.b  Q_SHADOW + 3, d0
    tst.b   Q_SHADOW + 1
    beq.s   2f
    tst.b   d0
    bne.w   sound_play
    bsr.w   z80_stop
    bsr.w   sound_quiet
    bsr.w   z80_start
    clr.l   snd_at
    rts
2:  mulu.w  #12, d0
    lea     SOUND_TABLE, a2
    adda.l  d0, a2
    move.b  (a2), d1
    beq.w   sound_play
    cmpi.b  #1, d1
    bne.s   3f
    bsr.w   z80_stop
    bsr.w   sound_quiet
    bsr.w   z80_start
    move.b  1(a2), snd_bank
    move.l  4(a2), d0
    addi.l  #STREAMS, d0
    move.l  d0, snd_at
    move.l  d0, snd_base
    clr.w   snd_wait
    bra.w   sound_play
3:  move.w  10(a2), snd_busy
    bsr.w   z80_stop
    bsr.w   pcm_start
    bsr.w   z80_start

sound_play:
    tst.l   snd_at
    beq.s   9f
    tst.w   snd_wait
    beq.s   1f
    subq.w  #1, snd_wait
9:  rts
1:  bsr.w   z80_stop
    move.b  snd_bank, MAPPER6
    movea.l snd_at, a0
    lea     YM_PORT, a1
2:  moveq   #0, d0
    move.b  (a0)+, d0
    cmpi.w  #0x20, d0
    blo.s   3f
    move.b  (a0)+, d1
    bsr.w   ym_write
    bra.s   2b
3:  add.w   d0, d0
    move.w  4f(pc, d0.w), d0
    jmp     4f(pc, d0.w)
4:  .word   stream_end - 4b, stream_wait - 4b, stream_stop - 4b, stream_loop - 4b
    .word   stream_psg - 4b, stream_part2 - 4b, stream_pcm - 4b
stream_wait:
    moveq   #0, d0
    move.b  (a0)+, d0
    move.w  d0, snd_wait
stream_end:
    move.l  a0, snd_at
    bra.w   z80_start
stream_stop:
    clr.l   snd_at
    bra.w   z80_start
stream_loop:
    moveq   #0, d0
    move.b  (a0)+, d0
    swap    d0
    move.b  (a0)+, d0
    lsl.w   #8, d0
    move.b  (a0)+, d0
    movea.l snd_base, a0
    adda.l  d0, a0
    bra.s   2b
stream_psg:
    move.b  (a0)+, PSG_PORT
    bra.s   2b
stream_part2:
    move.b  (a0)+, d0
    move.b  (a0)+, d1
    lea     YM_PORT + 2, a1
    bsr.w   ym_write
    lea     YM_PORT, a1
    bra.s   2b
stream_pcm:
    moveq   #0, d0
    move.b  (a0)+, d0
    tst.w   snd_busy
    bne.w   2b
    mulu.w  #12, d0
    lea     PCM_TABLE, a2
    adda.l  d0, a2
    bsr.w   pcm_start
    bra.w   2b

| a2 = table entry of a PCM sound. The Z80 must be stopped.
pcm_start:
    move.b  1(a2), MAPPER5
    lea     Z80_MAILBOX, a3
    move.b  2(a2), 1(a3)
    move.b  3(a2), 2(a3)
    move.b  4(a2), 3(a3)
    move.b  5(a2), 4(a3)
    move.b  6(a2), 5(a3)
    move.b  7(a2), 6(a3)
    move.b  8(a2), 7(a3)
    move.b  #1, (a3)
    rts

| d0 = register, d1 = value, a1 = the part's address port.
ym_write:
    btst    #7, YM_PORT
    bne.s   ym_write
    move.b  d0, (a1)
    nop
1:  btst    #7, YM_PORT
    bne.s   1b
    move.b  d1, 1(a1)
    rts

| Silences the FM channels and the PSG. The Z80 must be stopped.
sound_quiet:
    lea     YM_PORT, a1
    lea     1f(pc), a3
    moveq   #4, d2
2:  moveq   #0x28, d0
    move.b  (a3)+, d1
    bsr.s   ym_write
    dbra    d2, 2b
    move.b  #0x9f, PSG_PORT
    move.b  #0xbf, PSG_PORT
    move.b  #0xdf, PSG_PORT
    move.b  #0xff, PSG_PORT
    rts
1:  .byte   0, 1, 2, 4, 5
    .align  2

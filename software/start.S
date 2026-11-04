    .file "start.S"
    .section .text.init
    .option norvc
    .option norelax
    .globl _start
_start:
    la   sp, _stack_top

    # ROM is visible to data loads at 0x20000000. Copy initialized RAM data,
    # including C constants, on every reset before clearing .bss.
    la   t0, __data_load_start
    la   t1, __data_start
    la   t2, __data_end
0:
    bgeu t1, t2, 1f
    lw   t3, 0(t0)
    sw   t3, 0(t1)
    addi t0, t0, 4
    addi t1, t1, 4
    j    0b
1:
    la   t0, __bss_start
    la   t1, __bss_end
2:
    bgeu t0, t1, 3f
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    2b
3:
    call main
    ebreak
4:
    j    4b

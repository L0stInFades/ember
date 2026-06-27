.section .text.init
.globl _start
_start:
    la   sp, _stack_top
    # zero bss
    la   t0, __bss_start
    la   t1, __bss_end
1:  bge  t0, t1, 2f
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    1b
2:  call main
    # exit(main) -> syscon poweroff (a0 ignored, always 0x5555 = ok=0)
    li   t0, 0x11100000
    li   t1, 0x5555
    sw   t1, 0(t0)
3:  j 3b

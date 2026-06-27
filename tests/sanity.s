.section .text
.globl _start
_start:
    li   t0, 0x10000000      # UART THR
    li   t1, 'H'
    sb   t1, 0(t0)
    li   t1, 'i'
    sb   t1, 0(t0)
    li   t1, '\n'
    sb   t1, 0(t0)
    li   t0, 0x11100000      # syscon poweroff
    li   t1, 0x5555
    sw   t1, 0(t0)
1:  j    1b

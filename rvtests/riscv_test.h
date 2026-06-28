// 适配自建 SoC 的最小 riscv-test 环境头
//  - 复位入口 _start 在 0x0
//  - 通过 退出 MMIO(0x1000_0004) 报告 通过(0) / 失败((TESTNUM<<1)|1)
//  - mtvec 指向一个把"非预期陷阱"判为失败的处理程序
#ifndef _ENV_MY_RISCV_TEST_H
#define _ENV_MY_RISCV_TEST_H

#define TESTNUM gp

#define RVTEST_RV32U
#define RVTEST_RV64U
#define RVTEST_RV32M
#define RVTEST_RV64M
#define RVTEST_RV32S
#define RVTEST_RV64S
#define RVTEST_RV32UF
#define RVTEST_RV64UF

#define RVTEST_CODE_BEGIN       \
        .section .text.init;    \
        .globl _start;          \
_start:                         \
        j _rvtest_init;         \
        .align 2;               \
_trap_handler:                  \
        li t0, 0x10000004;      \
        li t1, 0x0bad0bad;      \
        sw t1, 0(t0);           \
99:     j 99b;                  \
        .align 2;               \
_rvtest_init:                   \
        la t0, _trap_handler;   \
        csrw mtvec, t0;

#define RVTEST_CODE_END

#define RVTEST_PASS             \
        li t0, 0x10000004;      \
        li t1, 0;               \
        sw t1, 0(t0);           \
98:     j 98b;

#define RVTEST_FAIL             \
        li t0, 0x10000004;      \
        slli t1, TESTNUM, 1;    \
        ori  t1, t1, 1;         \
        sw t1, 0(t0);           \
97:     j 97b;

#define RVTEST_DATA_BEGIN .align 4;
#define RVTEST_DATA_END

#endif

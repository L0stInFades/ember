#include "io.h"

volatile int ecall_seen = 0, illegal_seen = 0, timer_seen = 0;
volatile unsigned last_cause = 0;

#define MTIMECMP_LO (*(volatile unsigned *)0x02004000u)
#define MTIMECMP_HI (*(volatile unsigned *)0x02004004u)
#define MTIME_LO    (*(volatile unsigned *)0x0200BFF8u)

void handle_trap(void) {
    unsigned cause;
    asm volatile("csrr %0, mcause" : "=r"(cause));
    if (cause & 0x80000000u) {            // 中断(定时器)
        timer_seen++;
        MTIMECMP_LO = 0xffffffffu;        // 关掉以免再次触发
        MTIMECMP_HI = 0xffffffffu;
    } else {                              // 异常
        last_cause = cause;
        if (cause == 11) ecall_seen++;    // M态 ECALL
        else if (cause == 2) illegal_seen++; // 非法指令
        unsigned epc;                     // 跳过出错指令
        asm volatile("csrr %0, mepc" : "=r"(epc));
        epc += 4;
        asm volatile("csrw mepc, %0" : : "r"(epc));
    }
}

__attribute__((naked)) void trap_entry(void) {
    asm volatile(
        "addi sp,sp,-64\n"
        "sw ra,0(sp)\n sw t0,4(sp)\n sw t1,8(sp)\n sw t2,12(sp)\n"
        "sw a0,16(sp)\n sw a1,20(sp)\n sw a2,24(sp)\n sw a3,28(sp)\n"
        "sw a4,32(sp)\n sw a5,36(sp)\n sw a6,40(sp)\n sw a7,44(sp)\n"
        "sw t3,48(sp)\n sw t4,52(sp)\n sw t5,56(sp)\n sw t6,60(sp)\n"
        "call handle_trap\n"
        "lw ra,0(sp)\n lw t0,4(sp)\n lw t1,8(sp)\n lw t2,12(sp)\n"
        "lw a0,16(sp)\n lw a1,20(sp)\n lw a2,24(sp)\n lw a3,28(sp)\n"
        "lw a4,32(sp)\n lw a5,36(sp)\n lw a6,40(sp)\n lw a7,44(sp)\n"
        "lw t3,48(sp)\n lw t4,52(sp)\n lw t5,56(sp)\n lw t6,60(sp)\n"
        "addi sp,sp,64\n"
        "mret\n"
    );
}

int main(void) {
    asm volatile("csrw mtvec, %0" : : "r"((void *)trap_entry));
    puts_("=== 陷阱/中断测试 ===\n");

    puts_("ECALL ......... ");
    asm volatile("ecall");
    puts_((ecall_seen == 1 && last_cause == 11) ? "陷阱 cause=11 OK\n" : "FAIL\n");

    puts_("非法指令 ...... ");
    asm volatile(".word 0xffffffff");
    puts_((illegal_seen == 1 && last_cause == 2) ? "陷阱 cause=2 OK\n" : "FAIL\n");

    puts_("定时器中断 .... ");
    unsigned now = MTIME_LO;
    MTIMECMP_LO = now + 500;
    MTIMECMP_HI = 0;
    asm volatile("csrs mie, %0" : : "r"(1 << 7));       // MTIE
    asm volatile("csrs mstatus, %0" : : "r"(1 << 3));   // MIE 全局开
    volatile int spin = 0;
    while (!timer_seen && spin < 1000000) spin++;
    puts_(timer_seen >= 1 ? "触发 OK\n" : "FAIL\n");

    int ok = (ecall_seen == 1) && (illegal_seen == 1) && (timer_seen >= 1);
    puts_(ok ? "TRAPS ALL PASS\n" : "TRAPS FAIL\n");
    return ok ? 0 : 1;
}

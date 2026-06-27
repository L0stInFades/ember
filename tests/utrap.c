#include "util.h"
#define csrw(r,v) __asm__ volatile("csrw " r ",%0"::"r"(v):"memory")
#define csrr(r)   ({u32 _v; __asm__ volatile("csrr %0," r:"=r"(_v)); _v;})

extern void m_trap(void);
extern void s_entry(void);
extern void u_entry(void);
volatile u32 g_in_user, g_ecall_from;

__asm__(
".section .text\n"
".global m_trap\n m_trap:\n"
"  la t0, g_ecall_from\n  csrr t1, mcause\n  sw t1, 0(t0)\n"
"  la sp,_stack_top\n  call m_report\n"
".global u_entry\n u_entry:\n"
"  la t0, g_in_user\n  li t1, 1\n  sw t1, 0(t0)\n"
"  ecall\n"
"1: j 1b\n"
".global s_entry\n s_entry:\n"
"  csrr t0, sstatus\n"
"  li t1, ~(1<<8)\n  and t0,t0,t1\n"
"  csrw sstatus, t0\n"
"  la t0, u_entry\n  csrw sepc, t0\n"
"  sret\n"
);

void m_report(void){
  CHECK("reached_user", g_in_user, 1);
  CHECK("ecall_from_U", g_ecall_from, 8);
  report();
  *(volatile u32*)0x11100000 = 0x5555;
  for(;;);
}

int main(void){
  csrw("mtvec",(u32)m_trap);
  csrw("medeleg",0);
  u32 ms=csrr("mstatus"); ms&=~(3u<<11); ms|=(1u<<11); csrw("mstatus",ms);
  csrw("mepc",(u32)s_entry);
  __asm__ volatile("mret");
  return 0;
}

#include "util.h"
// Sv32 AMO/LR/SC directed test. LR should act like a load and set only A;
// SC/AMO should require store permission, set D only on non-faulting store-like
// attempts, and preserve memory on a read-only SC page fault.
#define PV 1
#define PR 2
#define PW 4
#define PX 8
#define PA_ 64
#define PD 128
#define MENVCFGH_ADUE (1u<<29)

#define csrw(r,v) __asm__ volatile("csrw " r ",%0"::"r"(v):"memory")
#define csrr(r)   ({u32 _v; __asm__ volatile("csrr %0," r:"=r"(_v)); _v;})

extern void s_trap(void);
extern void m_trap(void);
extern void s_main(void);

volatile u32 g_faults, g_scause, g_stval, g_after_fault;
volatile u32 g_lr_old, g_pte_after_lr, g_pte_after_sc_fault, g_value_after_fault;
volatile u32 g_sc_status, g_after_sc, g_pte_after_sc_success;
volatile u32 g_amo_old, g_amo_final, g_pte_after_amo;

__asm__(
".section .text\n"
".global s_trap\n s_trap:\n"
"  addi sp,sp,-16\n"
"  sw t0,0(sp)\n"
"  sw t1,4(sp)\n"
"  la t1,g_scause\n"
"  csrr t0,scause\n"
"  sw t0,0(t1)\n"
"  la t1,g_stval\n"
"  csrr t0,stval\n"
"  sw t0,0(t1)\n"
"  la t1,g_faults\n"
"  lw t0,0(t1)\n"
"  addi t0,t0,1\n"
"  sw t0,0(t1)\n"
"  csrr t0,sepc\n"
"  addi t0,t0,4\n"
"  csrw sepc,t0\n"
"  lw t0,0(sp)\n"
"  lw t1,4(sp)\n"
"  addi sp,sp,16\n"
"  sret\n"
".global s_main\n s_main:\n"
"  la t0,g_faults\n"
"  sw zero,0(t0)\n"
"  li t0,0x40000000\n"
"  lr.w t1,(t0)\n"
"  la t0,g_lr_old\n"
"  sw t1,0(t0)\n"
"  li t0,0x80201000\n"
"  lw t1,0(t0)\n"
"  la t0,g_pte_after_lr\n"
"  sw t1,0(t0)\n"
"  li t0,0x40000000\n"
"  li t1,0x22222222\n"
"  sc.w t2,t1,(t0)\n"  // read-only page: store/AMO page fault; handler skips this instruction
"  li t0,0xabcdef01\n"
"  la t1,g_after_fault\n"
"  sw t0,0(t1)\n"
"  li t0,0x80201000\n"
"  lw t1,0(t0)\n"
"  la t0,g_pte_after_sc_fault\n"
"  sw t1,0(t0)\n"
"  li t0,0x40000000\n"
"  lw t1,0(t0)\n"
"  la t0,g_value_after_fault\n"
"  sw t1,0(t0)\n"
"  li t0,0x80201000\n"
"  lw t1,0(t0)\n"
"  ori t1,t1,4\n"
"  li t2,0xffffff7f\n"
"  and t1,t1,t2\n"
"  sw t1,0(t0)\n"
"  sfence.vma\n"
"  li t0,0x40000000\n"
"  lr.w t1,(t0)\n"
"  li t2,0x33333333\n"
"  sc.w t3,t2,(t0)\n"
"  la t0,g_sc_status\n"
"  sw t3,0(t0)\n"
"  li t0,0x40000000\n"
"  lw t1,0(t0)\n"
"  la t0,g_after_sc\n"
"  sw t1,0(t0)\n"
"  li t0,0x80201000\n"
"  lw t1,0(t0)\n"
"  la t0,g_pte_after_sc_success\n"
"  sw t1,0(t0)\n"
"  li t0,0x80202000\n"
"  li t1,0x10\n"
"  sw t1,0(t0)\n"
"  li t0,0x80201000\n"
"  lw t1,0(t0)\n"
"  li t2,0xffffff7f\n"
"  and t1,t1,t2\n"
"  sw t1,0(t0)\n"
"  sfence.vma\n"
"  li t0,0x40000000\n"
"  li t1,5\n"
"  amoadd.w t2,t1,(t0)\n"
"  la t0,g_amo_old\n"
"  sw t2,0(t0)\n"
"  li t0,0x40000000\n"
"  lw t1,0(t0)\n"
"  la t0,g_amo_final\n"
"  sw t1,0(t0)\n"
"  li t0,0x80201000\n"
"  lw t1,0(t0)\n"
"  la t0,g_pte_after_amo\n"
"  sw t1,0(t0)\n"
"  ecall\n"
"1: j 1b\n"
".global m_trap\n m_trap:\n"
"  la sp,_stack_top\n"
"  call m_report\n"
);

void m_report(void){
  puts("=== AMO MMU TEST ===\n");
  CHECK("lr_old",             g_lr_old, 0x11111111);
  CHECK("pte_lr_a_only",      g_pte_after_lr & (PA_|PD), PA_);
  CHECK("faults",             g_faults, 1);
  CHECK("scause",             g_scause, 15);
  CHECK("stval",              g_stval, 0x40000000);
  CHECK("after_fault",        g_after_fault, 0xabcdef01);
  CHECK("pte_sc_fault_a",     g_pte_after_sc_fault & (PA_|PD), PA_);
  CHECK("pte_sc_fault_ro",    g_pte_after_sc_fault & PW, 0);
  CHECK("value_after_fault",  g_value_after_fault, 0x11111111);
  CHECK("sc_status",          g_sc_status, 0);
  CHECK("after_sc",           g_after_sc, 0x33333333);
  CHECK("pte_sc_success_ad",  g_pte_after_sc_success & (PA_|PD), PA_|PD);
  CHECK("amo_old",            g_amo_old, 0x10);
  CHECK("amo_final",          g_amo_final, 0x15);
  CHECK("pte_amo_ad",         g_pte_after_amo & (PA_|PD), PA_|PD);
  poweroff(report());
}

int main(void){
  u32 *root=(u32*)0x80200000, *l0=(u32*)0x80201000;
  for(int i=0;i<1024;i++){ root[i]=0; l0[i]=0; }
  root[0x200] = (0x80000u<<10)|PV|PR|PW|PX|PA_|PD;  // identity megapage
  root[0x100] = (0x80201u<<10)|PV;                  // VA 0x40000000 -> l0
  l0[0]       = (0x80202u<<10)|PV|PR;               // read-only, A/D clear
  *(volatile u32*)0x80202000 = 0x11111111;

  g_faults = 0;
  g_scause = 0;
  g_stval = 0;
  g_after_fault = 0;
  g_lr_old = 0;
  g_pte_after_lr = 0;
  g_pte_after_sc_fault = 0;
  g_value_after_fault = 0;
  g_sc_status = 0xffffffffu;
  g_after_sc = 0;
  g_pte_after_sc_success = 0;
  g_amo_old = 0;
  g_amo_final = 0;
  g_pte_after_amo = 0;

  csrw("mtvec",(u32)m_trap);
  csrw("stvec",(u32)s_trap);
  csrw("medeleg",(1u<<15));                         // delegate store/AMO page faults
  csrw("mideleg",0);
  csrw("0x31a",MENVCFGH_ADUE);
  csrw("satp",(1u<<31)|0x80200u);
  __asm__ volatile("sfence.vma"::: "memory");

  u32 ms=csrr("mstatus"); ms&=~(3u<<11); ms|=(1u<<11); csrw("mstatus",ms);
  csrw("mepc",(u32)s_main);
  __asm__ volatile("mret");
  return 0;
}

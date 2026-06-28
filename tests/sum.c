#include "util.h"
// Sv32 S-mode SUM directed test. Supervisor accesses to user pages should fault
// with SUM=0, should not set A/D on those faults, and should succeed with SUM=1.
#define PV 1
#define PR 2
#define PW 4
#define PX 8
#define PU 16
#define PA_ 64
#define PD 128
#define SSTATUS_SUM (1u<<18)
#define MENVCFGH_ADUE (1u<<29)

#define csrw(r,v) __asm__ volatile("csrw " r ",%0"::"r"(v):"memory")
#define csrr(r)   ({u32 _v; __asm__ volatile("csrr %0," r:"=r"(_v)); _v;})

extern void s_trap(void);
extern void m_trap(void);
extern void s_main(void);

volatile u32 g_faults, g_scause[2], g_stval[2], g_after_faults;
volatile u32 g_pte_after_faults, g_sum_load, g_pte_after_load;
volatile u32 g_store_read, g_pte_after_store;

__asm__(
".section .text\n"
".global s_trap\n s_trap:\n"
"  addi sp,sp,-24\n"
"  sw t0,0(sp)\n"
"  sw t1,4(sp)\n"
"  sw t2,8(sp)\n"
"  sw t3,12(sp)\n"
"  la t1,g_faults\n"
"  lw t2,0(t1)\n"
"  li t3,2\n"
"  bgeu t2,t3,1f\n"
"  csrr t0,scause\n"
"  la t1,g_scause\n"
"  slli t3,t2,2\n"
"  add t1,t1,t3\n"
"  sw t0,0(t1)\n"
"  csrr t0,stval\n"
"  la t1,g_stval\n"
"  add t1,t1,t3\n"
"  sw t0,0(t1)\n"
"1:\n"
"  la t1,g_faults\n"
"  lw t0,0(t1)\n"
"  addi t0,t0,1\n"
"  sw t0,0(t1)\n"
"  csrr t0,sepc\n"
"  addi t0,t0,4\n"
"  csrw sepc,t0\n"
"  lw t0,0(sp)\n"
"  lw t1,4(sp)\n"
"  lw t2,8(sp)\n"
"  lw t3,12(sp)\n"
"  addi sp,sp,24\n"
"  sret\n"
".global m_trap\n m_trap:\n"
"  la sp,_stack_top\n"
"  call m_report\n"
);

void m_report(void){
  puts("=== SUM TEST ===\n");
  CHECK("faults",           g_faults, 2);
  CHECK("store_scause",     g_scause[0], 15);
  CHECK("store_stval",      g_stval[0], 0x40000000);
  CHECK("load_scause",      g_scause[1], 13);
  CHECK("load_stval",       g_stval[1], 0x40000000);
  CHECK("after_faults",     g_after_faults, 0x13579bdf);
  CHECK("pte_fault_no_ad",  g_pte_after_faults & (PA_|PD), 0);
  CHECK("sum_load",         g_sum_load, 0x10203040);
  CHECK("pte_load_a_only",  g_pte_after_load & (PA_|PD), PA_);
  CHECK("store_read",       g_store_read, 0xa5a55a5a);
  CHECK("pte_store_ad",     g_pte_after_store & (PA_|PD), PA_|PD);
  poweroff(report());
}

int main(void){
  u32 *root=(u32*)0x80200000, *l0=(u32*)0x80201000;
  for(int i=0;i<1024;i++){ root[i]=0; l0[i]=0; }
  root[0x200] = (0x80000u<<10)|PV|PR|PW|PX|PA_|PD;  // identity megapage
  root[0x100] = (0x80201u<<10)|PV;                  // VA 0x40000000 -> l0
  l0[0]       = (0x80202u<<10)|PV|PR|PW|PU;         // user R/W, A/D clear
  *(volatile u32*)0x80202000 = 0x10203040;

  csrw("mtvec",(u32)m_trap);
  csrw("stvec",(u32)s_trap);
  csrw("medeleg",(1u<<13)|(1u<<15));                // data page faults to S
  csrw("mideleg",0);
  csrw("0x31a",MENVCFGH_ADUE);
  csrw("satp",(1u<<31)|0x80200u);
  __asm__ volatile("sfence.vma"::: "memory");

  u32 ms=csrr("mstatus"); ms&=~(3u<<11); ms|=(1u<<11); csrw("mstatus",ms);
  csrw("mepc",(u32)s_main);
  __asm__ volatile("mret");
  return 0;
}

void s_main(void){
  volatile u32 *uva=(volatile u32*)0x40000000;
  volatile u32 *pte=(volatile u32*)0x80201000;

  g_faults = 0;
  __asm__ volatile("sw %1,0(%0)"::"r"(uva),"r"(0xdeadbeef):"memory");
  __asm__ volatile("lw t0,0(%0)"::"r"(uva):"t0","memory");
  g_after_faults = 0x13579bdf;
  g_pte_after_faults = *pte;

  csrw("sstatus", csrr("sstatus") | SSTATUS_SUM);
  g_sum_load = *uva;
  g_pte_after_load = *pte;
  *uva = 0xa5a55a5a;
  g_store_read = *uva;
  g_pte_after_store = *pte;

  __asm__ volatile("ecall");
  for(;;);
}

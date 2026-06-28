#include "util.h"
// Sv32 write-permission fault directed test. A read-only supervisor page should
// accept loads and set A, reject stores without setting D, then set D only after
// S-mode makes the PTE writable and retries the store.
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
volatile u32 g_load, g_pte_after_load, g_pte_after_fault;
volatile u32 g_store_read, g_pte_after_store;

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
".global m_trap\n m_trap:\n"
"  la sp,_stack_top\n"
"  call m_report\n"
);

void m_report(void){
  puts("=== WPERM/AD TEST ===\n");
  CHECK("load_value",      g_load, 0x11223344);
  CHECK("faults",          g_faults, 1);
  CHECK("scause",          g_scause, 15);
  CHECK("stval",           g_stval, 0x40000000);
  CHECK("after_fault",     g_after_fault, 0xabcdef01);
  CHECK("pte_load_a_only", g_pte_after_load & (PA_|PD), PA_);
  CHECK("pte_fault_no_d",  g_pte_after_fault & PD, 0);
  CHECK("store_read",      g_store_read, 0x55667788);
  CHECK("pte_store_ad",    g_pte_after_store & (PA_|PD), PA_|PD);
  poweroff(report());
}

int main(void){
  u32 *root=(u32*)0x80200000, *l0=(u32*)0x80201000;
  for(int i=0;i<1024;i++){ root[i]=0; l0[i]=0; }
  root[0x200] = (0x80000u<<10)|PV|PR|PW|PX|PA_|PD;  // identity megapage
  root[0x100] = (0x80201u<<10)|PV;                  // VA 0x40000000 -> l0
  l0[0]       = (0x80202u<<10)|PV|PR;               // read-only, A/D clear
  *(volatile u32*)0x80202000 = 0x11223344;

  csrw("mtvec",(u32)m_trap);
  csrw("stvec",(u32)s_trap);
  csrw("medeleg",(1u<<15));                         // delegate store page faults
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
  volatile u32 *va=(volatile u32*)0x40000000;
  volatile u32 *pte=(volatile u32*)0x80201000;

  g_load = *va;
  g_pte_after_load = *pte;

  g_faults = 0;
  *va = 0xdeadbeef;                                 // store page fault
  g_after_fault = 0xabcdef01;
  g_pte_after_fault = *pte;

  *pte = (g_pte_after_fault | PW) & ~PD;            // writable, D clear
  __asm__ volatile("sfence.vma"::: "memory");
  *va = 0x55667788;
  g_store_read = *va;
  g_pte_after_store = *pte;

  __asm__ volatile("ecall");
  for(;;);
}

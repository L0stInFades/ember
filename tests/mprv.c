#include "util.h"
// MPRV + SUM permission directed test. M-mode data accesses should use MPP=S
// permissions when MPRV is set, including S-mode SUM checks on user pages.
#define PV 1
#define PR 2
#define PW 4
#define PX 8
#define PU 16
#define PA_ 64
#define PD 128
#define MENVCFGH_ADUE (1u << 29)
#define MSTATUS_MPP_S (1u << 11)
#define MSTATUS_MPRV  (1u << 17)
#define MSTATUS_SUM   (1u << 18)

#define csrw(r,v) __asm__ volatile("csrw " r ",%0"::"r"(v):"memory")
#define csrr(r)   ({u32 _v; __asm__ volatile("csrr %0," r:"=r"(_v)); _v;})

extern void m_trap(void);
volatile u32 g_sum_load, g_after_fault, g_mcause, g_mtval, g_mstatus;

__asm__(
".section .text\n"
".global m_trap\n m_trap:\n"
"  csrr t0,mcause\n"
"  la t1,g_mcause\n"
"  sw t0,0(t1)\n"
"  csrr t0,mtval\n"
"  la t1,g_mtval\n"
"  sw t0,0(t1)\n"
"  csrr t0,mstatus\n"
"  la t1,g_mstatus\n"
"  sw t0,0(t1)\n"
"  li t1,~(1<<17)\n"
"  and t0,t0,t1\n"
"  csrw mstatus,t0\n"
"  la sp,_stack_top\n"
"  call m_report\n"
);

void m_report(void){
  puts("=== MPRV/SUM TEST ===\n");
  CHECK("sum_load",    g_sum_load,    0x13572468);
  CHECK("fault_guard", g_after_fault, 0xfeedface);
  CHECK("mcause",      g_mcause,      13);
  CHECK("mtval",       g_mtval,       0x40000000);
  CHECK("mprv_was_set", g_mstatus & MSTATUS_MPRV, MSTATUS_MPRV);
  poweroff(report());
}

int main(void){
  u32 *root=(u32*)0x80200000, *l0=(u32*)0x80201000;
  volatile u32 *uva=(volatile u32*)0x40000000;

  for(int i=0;i<1024;i++){ root[i]=0; l0[i]=0; }
  root[0x200] = (0x80000u<<10)|PV|PR|PW|PX|PA_|PD;  // identity megapage
  root[0x100] = (0x80201u<<10)|PV;                  // VA 0x40000000 -> l0
  l0[0]       = (0x80202u<<10)|PV|PR|PW|PU;         // user R/W, A/D clear
  *(volatile u32*)0x80202000 = 0x13572468;

  csrw("mtvec",(u32)m_trap);
  csrw("0x31a",MENVCFGH_ADUE);                       // match Spike/Svadu hardware A/D update mode
  csrw("satp",(1u<<31)|0x80200u);
  __asm__ volatile("sfence.vma"::: "memory");

  csrw("mstatus", MSTATUS_MPRV | MSTATUS_SUM | MSTATUS_MPP_S);
  g_sum_load = *uva;                                // succeeds because SUM=1

  g_after_fault = 0xfeedface;
  csrw("mstatus", MSTATUS_MPRV | MSTATUS_MPP_S);
  g_after_fault = *uva;                             // load page fault, SUM=0
  poweroff(1);
  return 1;
}

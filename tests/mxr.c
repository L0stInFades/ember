#include "util.h"
// Sv32 MXR permission directed test. S-mode loads from an execute-only page
// should fault with MXR=0 and succeed with MXR=1.
#define PV 1
#define PR 2
#define PW 4
#define PX 8
#define PA_ 64
#define PD 128
#define MSTATUS_MXR (1u << 19)
#define MENVCFGH_ADUE (1u << 29)

#define csrw(r,v) __asm__ volatile("csrw " r ",%0"::"r"(v):"memory")
#define csrr(r)   ({u32 _v; __asm__ volatile("csrr %0," r:"=r"(_v)); _v;})

extern void s_trap(void);
extern void m_trap(void);
extern void s_main(void);

volatile u32 g_faults, g_scause, g_stval, g_after_fault, g_mxr_load, g_pte;

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
  puts("=== MXR TEST ===\n");
  CHECK("faults",      g_faults, 1);
  CHECK("scause",      g_scause, 13);
  CHECK("stval",       g_stval, 0x40000000);
  CHECK("after_fault", g_after_fault, 0x12345678);
  CHECK("mxr_load",    g_mxr_load, 0xc001d00d);
  CHECK("pte_a_only",  g_pte & (PA_|PD), PA_);
  poweroff(report());
}

int main(void){
  u32 *root=(u32*)0x80200000, *l0=(u32*)0x80201000;
  for(int i=0;i<1024;i++){ root[i]=0; l0[i]=0; }
  root[0x200] = (0x80000u<<10)|PV|PR|PW|PX|PA_|PD;  // identity megapage
  root[0x100] = (0x80201u<<10)|PV;                  // VA 0x40000000 -> l0
  l0[0]       = (0x80202u<<10)|PV|PX;               // X-only supervisor page
  *(volatile u32*)0x80202000 = 0xc001d00d;

  csrw("mtvec",(u32)m_trap);
  csrw("stvec",(u32)s_trap);
  csrw("medeleg",(1u<<13));                         // delegate load page faults
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
  volatile u32 *xva=(volatile u32*)0x40000000;
  u32 value;

  g_faults = 0;
  __asm__ volatile("lw t0,0(%0)"::"r"(xva):"t0","memory"); // MXR=0 load fault
  g_after_fault = 0x12345678;

  csrw("sstatus", csrr("sstatus") | MSTATUS_MXR);
  __asm__ volatile("lw %0,0(%1)":"=r"(value):"r"(xva):"memory");
  g_mxr_load = value;
  g_pte = *(volatile u32*)0x80201000;
  __asm__ volatile("ecall");
  for(;;);
}

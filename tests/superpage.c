#include "util.h"
// Sv32 level-1 leaf PTEs are 4 MiB superpages. PPN0 must be zero; a
// valid-looking leaf with PPN0 set must fault and must not receive A/D updates.
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
extern const u32 super_probe[1024];

__attribute__((used, aligned(4096), section(".rodata.superpage")))
const u32 super_probe[1024] = {0x00008067u}; // JALR x0,0(ra): returns if a bad fetch succeeds

volatile u32 g_faults, g_scause[2], g_stval[2], g_sepc[2];
volatile u32 g_probe_va, g_pte_after_store_fault, g_pte_after_fetch_fault;
volatile u32 g_after_store, g_after_fetch, g_phys_after_store;

__asm__(
".section .text\n"
".global s_trap\n s_trap:\n"
"  addi sp,sp,-24\n"
"  sw t0,0(sp)\n"
"  sw t1,4(sp)\n"
"  sw t2,8(sp)\n"
"  sw t3,12(sp)\n"
"  sw ra,16(sp)\n"
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
"  csrr t0,sepc\n"
"  la t1,g_sepc\n"
"  add t1,t1,t3\n"
"  sw t0,0(t1)\n"
"1:\n"
"  la t1,g_faults\n"
"  lw t0,0(t1)\n"
"  addi t0,t0,1\n"
"  sw t0,0(t1)\n"
"  csrr t0,scause\n"
"  li t1,12\n"
"  beq t0,t1,2f\n"
"  csrr t0,sepc\n"
"  addi t0,t0,4\n"
"  csrw sepc,t0\n"
"  j 3f\n"
"2:\n"
"  csrw sepc,ra\n"
"3:\n"
"  lw t0,0(sp)\n"
"  lw t1,4(sp)\n"
"  lw t2,8(sp)\n"
"  lw t3,12(sp)\n"
"  lw ra,16(sp)\n"
"  addi sp,sp,24\n"
"  sret\n"
".global s_main\n s_main:\n"
"  la t0,g_faults\n"
"  sw zero,0(t0)\n"
"  la t0,g_probe_va\n"
"  lw t0,0(t0)\n"
"  li t1,0xdeadbeef\n"
"  sw t1,0(t0)\n"       // misaligned-superpage store fault; handler skips this instr
"  li t0,0x13579bdf\n"
"  la t1,g_after_store\n"
"  sw t0,0(t1)\n"
"  li t0,0x80200400\n"
"  lw t1,0(t0)\n"
"  la t0,g_pte_after_store_fault\n"
"  sw t1,0(t0)\n"
"  la t0,g_probe_va\n"
"  lw t0,0(t0)\n"
"  jalr ra,0(t0)\n"     // misaligned-superpage instruction fault; handler returns to ra
"  li t0,0x2468ace0\n"
"  la t1,g_after_fetch\n"
"  sw t0,0(t1)\n"
"  li t0,0x80200400\n"
"  lw t1,0(t0)\n"
"  la t0,g_pte_after_fetch_fault\n"
"  sw t1,0(t0)\n"
"  la t0,super_probe\n"
"  lw t1,0(t0)\n"
"  la t0,g_phys_after_store\n"
"  sw t1,0(t0)\n"
"  ecall\n"
"1: j 1b\n"
".global m_trap\n m_trap:\n"
"  la sp,_stack_top\n"
"  call m_report\n"
);

void m_report(void){
  u32 leaf_flags = PV|PR|PW|PX;
  puts("=== SUPERPAGE ALIGN TEST ===\n");
  CHECK("faults",              g_faults, 2);
  CHECK("store_scause",        g_scause[0], 15);
  CHECK("store_stval",         g_stval[0], g_probe_va);
  CHECK("fetch_scause",        g_scause[1], 12);
  CHECK("fetch_stval",         g_stval[1], g_probe_va);
  CHECK("fetch_sepc",          g_sepc[1], g_probe_va);
  CHECK("after_store",         g_after_store, 0x13579bdf);
  CHECK("after_fetch",         g_after_fetch, 0x2468ace0);
  CHECK("pte_store_no_ad",     g_pte_after_store_fault & (PA_|PD), 0);
  CHECK("pte_fetch_no_ad",     g_pte_after_fetch_fault & (PA_|PD), 0);
  CHECK("pte_leaf_flags",      g_pte_after_fetch_fault & (PV|PR|PW|PX), leaf_flags);
  CHECK("pte_ppn0_nonzero",    (g_pte_after_fetch_fault >> 10) & 0x3ff, 1);
  CHECK("phys_unchanged",      g_phys_after_store, 0x00008067);
  poweroff(report());
}

int main(void){
  u32 *root=(u32*)0x80200000;
  u32 probe_pa=(u32)super_probe;
  u32 probe_ppn1=probe_pa >> 22;
  u32 misaligned_ppn=(probe_ppn1 << 10) | 1u;
  for(int i=0;i<1024;i++) root[i]=0;
  root[0x200] = (0x80000u<<10)|PV|PR|PW|PX|PA_|PD; // aligned identity superpage
  root[0x100] = (misaligned_ppn<<10)|PV|PR|PW|PX;  // invalid level-1 leaf: PPN0=1

  g_probe_va = 0x40000000u | (probe_pa & 0x003fffffu);
  g_faults = 0;
  g_scause[0] = g_scause[1] = 0;
  g_stval[0] = g_stval[1] = 0;
  g_sepc[0] = g_sepc[1] = 0;
  g_pte_after_store_fault = 0;
  g_pte_after_fetch_fault = 0;
  g_after_store = 0;
  g_after_fetch = 0;
  g_phys_after_store = 0;

  csrw("mtvec",(u32)m_trap);
  csrw("stvec",(u32)s_trap);
  csrw("medeleg",(1u<<12)|(1u<<15));                // fetch/store page faults to S
  csrw("mideleg",0);
  csrw("0x31a",MENVCFGH_ADUE);
  csrw("satp",(1u<<31)|0x80200u);
  __asm__ volatile("sfence.vma"::: "memory");

  u32 ms=csrr("mstatus"); ms&=~(3u<<11); ms|=(1u<<11); csrw("mstatus",ms);
  csrw("mepc",(u32)s_main);
  __asm__ volatile("mret");
  return 0;
}

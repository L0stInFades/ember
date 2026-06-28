#include "util.h"
// Sv32 instruction page-fault directed test. S-mode jumps to a valid
// supervisor-readable page with X=0, which must delegate cause 12 to S-mode.
#define PV 1
#define PR 2
#define PW 4
#define PX 8
#define PA_ 64
#define PD 128
#define MENVCFGH_ADUE (1u<<29)
#define REC_FAULTS_ADDR 0x80300000u
#define REC_SCAUSE_ADDR 0x80300004u
#define REC_STVAL_ADDR 0x80300008u
#define REC_SEPC_ADDR 0x8030000cu
#define REC_PTE_ADDR 0x80300010u
#define REC_AFTER_ADDR 0x80300014u
#define REC_FAULTS (*(volatile u32*)REC_FAULTS_ADDR)
#define REC_SCAUSE (*(volatile u32*)REC_SCAUSE_ADDR)
#define REC_STVAL (*(volatile u32*)REC_STVAL_ADDR)
#define REC_SEPC (*(volatile u32*)REC_SEPC_ADDR)
#define REC_PTE (*(volatile u32*)REC_PTE_ADDR)
#define REC_AFTER (*(volatile u32*)REC_AFTER_ADDR)

#define csrw(r,v) __asm__ volatile("csrw " r ",%0"::"r"(v):"memory")
#define csrr(r)   ({u32 _v; __asm__ volatile("csrr %0," r:"=r"(_v)); _v;})

extern void s_trap(void);
extern void m_trap(void);
extern void s_main(void);
extern const u32 fault_instr;

__attribute__((used, aligned(4096), section(".rodata.ifault")))
const u32 fault_instr = 0x00000013u; // ADDI x0,x0,0: a 32-bit instruction word

__asm__(
".section .text\n"
".global s_trap\n s_trap:\n"
"  addi sp,sp,-20\n"
"  sw t0,0(sp)\n"
"  sw t1,4(sp)\n"
"  sw t2,8(sp)\n"
"  sw ra,12(sp)\n"
"  csrr t0,scause\n"
"  li t1,0x80300004\n"
"  sw t0,0(t1)\n"
"  li t1,0x80300008\n"
"  csrr t0,stval\n"
"  sw t0,0(t1)\n"
"  li t1,0x8030000c\n"
"  csrr t0,sepc\n"
"  sw t0,0(t1)\n"
"  li t1,0x80300000\n"
"  lw t0,0(t1)\n"
"  addi t0,t0,1\n"
"  sw t0,0(t1)\n"
"  csrw sepc,ra\n"
"  lw t0,0(sp)\n"
"  lw t1,4(sp)\n"
"  lw t2,8(sp)\n"
"  lw ra,12(sp)\n"
"  addi sp,sp,20\n"
"  sret\n"
".global s_main\n s_main:\n"
"  li t0,0x80300000\n"
"  sw zero,0(t0)\n"
"  sw zero,4(t0)\n"
"  sw zero,8(t0)\n"
"  sw zero,12(t0)\n"
"  sw zero,16(t0)\n"
"  sw zero,20(t0)\n"
"  la t0,fault_instr\n"
"  jalr ra,0(t0)\n"
"  li t0,0x80300014\n"
"  li t1,0x12345678\n"
"  sw t1,0(t0)\n"
"  la t0,fault_instr\n"
"  srli t1,t0,12\n"
"  andi t1,t1,1023\n"
"  slli t1,t1,2\n"
"  li t2,0x80201000\n"
"  add t1,t1,t2\n"
"  lw t2,0(t1)\n"
"  li t0,0x80300010\n"
"  sw t2,0(t0)\n"
"  ecall\n"
"1: j 1b\n"
".global m_trap\n m_trap:\n"
"  la sp,_stack_top\n"
"  call m_report\n"
);

void m_report(void){
  puts("=== IFAULT TEST ===\n");
  CHECK("faults",      REC_FAULTS, 1);
  CHECK("scause",      REC_SCAUSE, 12);
  CHECK("stval",       REC_STVAL, (u32)&fault_instr);
  CHECK("sepc",        REC_SEPC, (u32)&fault_instr);
  CHECK("after_fault", REC_AFTER, 0x12345678);
  CHECK("pte_no_ad",   REC_PTE & (PA_|PD), 0);
  CHECK("pte_no_x",    REC_PTE & PX, 0);
  CHECK("pte_read",    REC_PTE & PR, PR);
  poweroff(report());
}

int main(void){
  u32 *root=(u32*)0x80200000, *l0=(u32*)0x80201000;
  u32 fault_va=(u32)&fault_instr;
  for(int i=0;i<1024;i++){ root[i]=0; l0[i]=0; }
  root[0x200] = (0x80201u<<10)|PV;                 // 0x80000000 VA range -> l0
  for(int i=0;i<1024;i++)
    l0[i] = ((0x80000u + (u32)i) << 10) | PV|PR|PW|PX|PA_|PD;
  l0[(fault_va >> 12) & 0x3ff] = ((fault_va >> 12) << 10) | PV|PR;

  REC_FAULTS = 0;
  REC_SCAUSE = 0;
  REC_STVAL = 0;
  REC_SEPC = 0;
  REC_PTE = 0;
  REC_AFTER = 0;

  csrw("mtvec",(u32)m_trap);
  csrw("stvec",(u32)s_trap);
  csrw("medeleg",(1u<<12));                         // delegate instruction page faults
  csrw("mideleg",0);
  csrw("0x31a",MENVCFGH_ADUE);
  csrw("satp",(1u<<31)|0x80200u);
  __asm__ volatile("sfence.vma"::: "memory");

  u32 ms=csrr("mstatus"); ms&=~(3u<<11); ms|=(1u<<11); csrw("mstatus",ms);
  csrw("mepc",(u32)s_main);
  __asm__ volatile("mret");
  return 0;
}


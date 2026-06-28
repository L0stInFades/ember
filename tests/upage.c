#include "util.h"
// Sv32 U-mode page execution/data directed test. This covers user-page fetch,
// user data load/store, U->S fault delegation, and U->S->M trap return.
#define PV 1
#define PR 2
#define PW 4
#define PX 8
#define PU 16
#define PA_ 64
#define PD 128
#define MENVCFGH_ADUE (1u<<29)
#define UDATA_ADDR 0x80300000u
#define SUPDATA_ADDR 0x80301000u
#define REC_FAULTS_ADDR 0x80302000u
#define REC_SCAUSE_ADDR 0x80302004u
#define REC_STVAL_ADDR 0x80302008u
#define REC_ECALL_ADDR 0x8030200cu
#define REC_FAULTS (*(volatile u32*)REC_FAULTS_ADDR)
#define REC_SCAUSE (*(volatile u32*)REC_SCAUSE_ADDR)
#define REC_STVAL (*(volatile u32*)REC_STVAL_ADDR)
#define REC_ECALL (*(volatile u32*)REC_ECALL_ADDR)

#define csrw(r,v) __asm__ volatile("csrw " r ",%0"::"r"(v):"memory")
#define csrr(r)   ({u32 _v; __asm__ volatile("csrr %0," r:"=r"(_v)); _v;})

extern void s_trap(void);
extern void m_trap(void);
extern void s_entry(void);
extern void u_entry(void);

__asm__(
".section .text.user\n"
".balign 4096\n"
".global u_entry\n u_entry:\n"
"  li t0,0x80301000\n"
"  lw t2,0(t0)\n"              // U load from supervisor page: delegated load fault
"  li t0,0x80300000\n"
"  li t1,0x5a5a1234\n"
"  sw t1,0(t0)\n"
"  lw t2,0(t0)\n"
"  li t0,0x80300004\n"
"  sw t2,0(t0)\n"
"  ecall\n"
"1: j 1b\n"
".section .text\n"
".global s_trap\n s_trap:\n"
"  addi sp,sp,-16\n"
"  sw t0,0(sp)\n"
"  sw t1,4(sp)\n"
"  sw t2,8(sp)\n"
"  csrr t0,scause\n"
"  li t2,8\n"
"  beq t0,t2,1f\n"
"  li t1,0x80302004\n"
"  sw t0,0(t1)\n"
"  li t1,0x80302008\n"
"  csrr t0,stval\n"
"  sw t0,0(t1)\n"
"  li t1,0x80302000\n"
"  lw t0,0(t1)\n"
"  addi t0,t0,1\n"
"  sw t0,0(t1)\n"
"  csrr t0,sepc\n"
"  addi t0,t0,4\n"
"  csrw sepc,t0\n"
"  lw t0,0(sp)\n"
"  lw t1,4(sp)\n"
"  lw t2,8(sp)\n"
"  addi sp,sp,16\n"
"  sret\n"
"1:\n"
"  li t1,0x8030200c\n"
"  sw t0,0(t1)\n"
"  lw t0,0(sp)\n"
"  lw t1,4(sp)\n"
"  lw t2,8(sp)\n"
"  addi sp,sp,16\n"
"  ecall\n"
".global m_trap\n m_trap:\n"
"  la sp,_stack_top\n"
"  call m_report\n"
);

void m_report(void){
  puts("=== U-PAGE TEST ===\n");
  CHECK("faults",      REC_FAULTS, 1);
  CHECK("scause",      REC_SCAUSE, 13);
  CHECK("stval",       REC_STVAL, SUPDATA_ADDR);
  CHECK("u_ecall",     REC_ECALL, 8);
  CHECK("u_flag",      *(volatile u32*)UDATA_ADDR, 0x5a5a1234);
  CHECK("u_seen",      *(volatile u32*)(UDATA_ADDR + 4), 0x5a5a1234);
  poweroff(report());
}

static void map_page(u32 *l0, u32 va, u32 pa, u32 flags){
  l0[(va >> 12) & 0x3ff] = ((pa >> 12) << 10) | flags;
}

int main(void){
  u32 *root=(u32*)0x80200000, *l0=(u32*)0x80201000;
  for(int i=0;i<1024;i++){ root[i]=0; l0[i]=0; }
  root[0x200] = (0x80201u<<10)|PV;                 // 0x80000000 VA range -> l0
  for(int i=0;i<1024;i++)
    l0[i] = ((0x80000u + (u32)i) << 10) | PV|PR|PW|PX|PA_|PD;
  map_page(l0, (u32)u_entry, (u32)u_entry, PV|PR|PX|PU);  // user executable page
  map_page(l0, UDATA_ADDR, UDATA_ADDR, PV|PR|PW|PU);      // user data page
  *(volatile u32*)SUPDATA_ADDR = 0xdecafbad;
  REC_FAULTS = 0;
  REC_SCAUSE = 0;
  REC_STVAL = 0;
  REC_ECALL = 0;
  *(volatile u32*)UDATA_ADDR = 0;
  *(volatile u32*)(UDATA_ADDR + 4) = 0;

  csrw("mtvec",(u32)m_trap);
  csrw("stvec",(u32)s_trap);
  csrw("medeleg",(1u<<8)|(1u<<13));                // U ecall and load fault to S
  csrw("mideleg",0);
  csrw("0x31a",MENVCFGH_ADUE);
  csrw("satp",(1u<<31)|0x80200u);
  __asm__ volatile("sfence.vma"::: "memory");

  u32 ms=csrr("mstatus"); ms&=~(3u<<11); ms|=(1u<<11); csrw("mstatus",ms);
  csrw("mepc",(u32)s_entry);
  __asm__ volatile("mret");
  return 0;
}

void s_entry(void){
  csrw("sepc",(u32)u_entry);
  csrw("sstatus", csrr("sstatus") & ~(1u<<8));     // SPP=U
  __asm__ volatile("sret");
}

#include "util.h"
// Sv32 MMU + M/S privilege + delegated page-fault directed test.
#define PV 1
#define PR 2
#define PW 4
#define PX 8
#define PU 16
#define PA_ 64
#define PD 128
#define MENVCFGH_ADUE (1u<<29)
#define csrw(r,v) __asm__ volatile("csrw " r ",%0"::"r"(v):"memory")
#define csrr(r)   ({u32 _v; __asm__ volatile("csrr %0," r:"=r"(_v)); _v;})

extern void s_trap(void);
extern void m_trap(void);
extern void s_main(void);

volatile u32 g_r1, g_phys, g_fault, g_scause, g_ad;
volatile u32 g_b0,g_b1,g_b2,g_b3, g_h0,g_h1, g_sb;

// trap handlers (S skips faulting instr; M ecall -> report)
__asm__(
".section .text\n"
".global s_trap\n s_trap:\n"
"  addi sp,sp,-16\n  sw t0,0(sp)\n  sw t1,4(sp)\n"
"  la t1, g_scause\n  csrr t0,scause\n  sw t0,0(t1)\n"
"  la t1, g_fault\n  lw t0,0(t1)\n  addi t0,t0,1\n  sw t0,0(t1)\n"
"  csrr t0,sepc\n  addi t0,t0,4\n  csrw sepc,t0\n"
"  lw t0,0(sp)\n  lw t1,4(sp)\n  addi sp,sp,16\n  sret\n"
".global m_trap\n m_trap:\n"
"  la sp,_stack_top\n  call m_report\n"
);

void m_report(void){
  puts("=== MMU/PRIV TEST ===\n");
  CHECK("xlate_load",  g_r1,   0xdeadbeef);   // VA 0x40000000 read-back
  CHECK("xlate_phys",  g_phys, 0xdeadbeef);   // same PA seen via identity map
  CHECK("pagefaults",  g_fault, 2);           // store + load fault both caught
  CHECK("fault_cause", g_scause, 13);         // last was load page fault (13)
  CHECK("ad_set",      g_ad & (PA_|PD), PA_|PD); // HW set A+D on the leaf PTE
  CHECK("xlate_lbu0",  g_b0, 0x11);
  CHECK("xlate_lbu1",  g_b1, 0x22);
  CHECK("xlate_lbu2",  g_b2, 0x33);
  CHECK("xlate_lbu3",  g_b3, 0x44);
  CHECK("xlate_lhu0",  g_h0, 0x2211);
  CHECK("xlate_lhu1",  g_h1, 0x4433);
  CHECK("xlate_sb",    g_sb, 0x44337F11);    // byte store through MMU (byte1 -> 0x7F)
  poweroff(report());
}

int main(void){
  u32 *root=(u32*)0x80200000, *l0=(u32*)0x80201000;
  for(int i=0;i<1024;i++){ root[i]=0; l0[i]=0; }
  root[0x200] = (0x80000u<<10)|PV|PR|PW|PX|PA_|PD;  // identity megapage 0x80000000-0x803FFFFF
  root[0x100] = (0x80201u<<10)|PV;                  // -> l0 (non-leaf)
  l0[0]       = (0x80202u<<10)|PV|PR|PW|PX;         // leaf VA 0x40000000 -> PA 0x80202000 (A/D clear)

  csrw("mtvec",(u32)m_trap);
  csrw("stvec",(u32)s_trap);
  csrw("medeleg",(1u<<12)|(1u<<13)|(1u<<15));       // delegate page faults to S
  csrw("mideleg",0);
  csrw("0x31a",MENVCFGH_ADUE);                      // menvcfgh.ADUE: hardware A/D update for Spike/Svadu
  csrw("satp",(1u<<31)|0x80200u);                   // Sv32, root PPN
  __asm__ volatile("sfence.vma"::: "memory");

  u32 ms=csrr("mstatus"); ms&=~(3u<<11); ms|=(1u<<11); csrw("mstatus",ms); // MPP=S
  csrw("mepc",(u32)s_main);
  __asm__ volatile("mret");
  return 0;
}

// S-mode body
void s_main(void){
  volatile u32 *va=(volatile u32*)0x40000000;
  *va = 0xdeadbeef;
  g_r1 = *va;
  g_phys = *(volatile u32*)0x80202000;   // identity view of same physical page
  g_ad = *(volatile u32*)0x80201000;     // l0[0] PTE, A/D bits should now be set by HW
  // byte/halfword loads through translation
  *va = 0x44332211;
  volatile unsigned char *b = (volatile unsigned char*)0x40000000;
  volatile unsigned short *h = (volatile unsigned short*)0x40000000;
  g_b0=b[0]; g_b1=b[1]; g_b2=b[2]; g_b3=b[3];
  g_h0=h[0]; g_h1=h[1];
  b[1] = 0x7F;                            // byte store through translation
  g_sb = *va;
  g_fault = 0;
  *(volatile u32*)0x50000000 = 1;        // unmapped store -> store page fault (15)
  (void)*(volatile u32*)0x50000000;      // unmapped load  -> load page fault (13)
  __asm__ volatile("ecall");             // ecall from S (cause 9, not delegated) -> M
  for(;;);
}

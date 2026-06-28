#include "util.h"

#define csrw(r,v) __asm__ volatile("csrw " r ",%0"::"r"(v):"memory")
#define csrr(r)   ({u32 _v; __asm__ volatile("csrr %0," r:"=r"(_v)); _v;})

extern void m_trap(void);

volatile u32 g_faults;
volatile u32 g_mcause1, g_mtval1, g_mcause2, g_mtval2;
volatile u32 g_after_load;
volatile u32 g_word = 0xaabbccdd;

__asm__(
".section .text\n"
".global m_trap\n m_trap:\n"
"  addi sp,sp,-16\n"
"  sw t0,0(sp)\n"
"  sw t1,4(sp)\n"
"  sw t2,8(sp)\n"
"  sw t3,12(sp)\n"
"  la t0,g_faults\n"
"  lw t1,0(t0)\n"
"  addi t1,t1,1\n"
"  sw t1,0(t0)\n"
"  csrr t2,mcause\n"
"  csrr t3,mtval\n"
"  li t0,1\n"
"  bne t1,t0,1f\n"
"  la t0,g_mcause1\n"
"  sw t2,0(t0)\n"
"  la t0,g_mtval1\n"
"  sw t3,0(t0)\n"
"  j 2f\n"
"1:\n"
"  la t0,g_mcause2\n"
"  sw t2,0(t0)\n"
"  la t0,g_mtval2\n"
"  sw t3,0(t0)\n"
"2:\n"
"  csrr t0,mepc\n"
"  addi t0,t0,4\n"
"  csrw mepc,t0\n"
"  lw t0,0(sp)\n"
"  lw t1,4(sp)\n"
"  lw t2,8(sp)\n"
"  lw t3,12(sp)\n"
"  addi sp,sp,16\n"
"  mret\n"
);

static void misaligned_lw(void){
  volatile u32 *out = &g_after_load;
  volatile u32 *base = &g_word;
  __asm__ volatile(
    "li t1,0x5a5a5a5a\n"
    "lw t1,1(%1)\n"
    "sw t1,0(%0)\n"
    :
    : "r"(out), "r"(base)
    : "t1", "memory");
}

static void misaligned_sw(void){
  volatile u32 *base = &g_word;
  __asm__ volatile(
    "li t1,0x11223344\n"
    "sw t1,2(%0)\n"
    :
    : "r"(base)
    : "t1", "memory");
}

int main(void){
  puts("=== MISALIGN TEST ===\n");
  csrw("mtvec",(u32)m_trap);
  csrw("medeleg",0);

  g_faults = 0;
  g_after_load = 0;
  misaligned_lw();
  misaligned_sw();

  CHECK("faults", g_faults, 2);
  CHECK("load_cause", g_mcause1, 4);
  CHECK("load_tval", g_mtval1, ((u32)&g_word) + 1);
  CHECK("load_no_wb", g_after_load, 0x5a5a5a5a);
  CHECK("store_cause", g_mcause2, 6);
  CHECK("store_tval", g_mtval2, ((u32)&g_word) + 2);
  CHECK("store_no_write", g_word, 0xaabbccdd);
  return report();
}

#include "util.h"

static u32 amoadd(volatile u32*p, u32 v){ u32 old;
  __asm__ volatile("amoadd.w %0,%2,(%1)":"=r"(old):"r"(p),"r"(v):"memory"); return old; }
static u32 amoswap(volatile u32*p, u32 v){ u32 old;
  __asm__ volatile("amoswap.w %0,%2,(%1)":"=r"(old):"r"(p),"r"(v):"memory"); return old; }
static u32 amoor(volatile u32*p, u32 v){ u32 old;
  __asm__ volatile("amoor.w %0,%2,(%1)":"=r"(old):"r"(p),"r"(v):"memory"); return old; }
static int lrsc(volatile u32*p){ u32 t; int fail;
  __asm__ volatile("lr.w %0,(%2)\n addi %0,%0,1\n sc.w %1,%0,(%2)"
                   :"=&r"(t),"=&r"(fail):"r"(p):"memory"); return fail; }

static volatile u32 shared;
int main(void){
  // base ALU / shifts
  volatile int a=-7, b=3;
  CHECK("add", a+b, (u32)-4);
  CHECK("sll", 1u<<20, 0x100000);
  CHECK("sra", (u32)(((int)0x80000000)>>4), 0xf8000000);
  CHECK("srl", 0x80000000u>>4, 0x08000000);
  CHECK("slt", (u32)(a<b), 1);
  CHECK("xor", 0xff00u^0x0ff0u, 0xf0f0);
  // M extension
  volatile int x=-100, y=7;
  CHECK("mul", x*y, (u32)-700);
  CHECK("div", x/y, (u32)(-100/7));
  CHECK("rem", x%y, (u32)(-100%7));
  CHECK("divu", 0xfffffff0u/3u, 0xfffffff0u/3u);
  CHECK("mulhu_hi", (u32)(((u64)0xffffffffull*0xffffffffull)>>32), 0xfffffffe);
  // A extension
  shared=10;
  CHECK("amoadd_old", amoadd(&shared,5), 10);
  CHECK("amoadd_new", shared, 15);
  CHECK("amoswap_old", amoswap(&shared,100), 15);
  CHECK("amoswap_new", shared, 100);
  shared=100;
  puts("  &shared="); puthex((u32)&shared); putc('\n');
  amoor(&shared,0x0f);
  puts("  after amoor shared="); puthex(shared); putc('\n');
  CHECK("amoor", shared, 100|0x0f);
  shared=0;
  CHECK("sc_success", lrsc(&shared), 0);
  CHECK("lrsc_val", shared, 1);
  return report();
}

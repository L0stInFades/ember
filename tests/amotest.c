#include "util.h"
static volatile u32 s;
int main(void){
  u32 v;
  s=100; v=0x0f;
  __asm__ volatile("amoor.w %0,%0,(%1)":"+r"(v):"r"(&s):"memory"); // rd==rs2
  puts("rd==rs2 OR: s="); puthex(s); puts(" old="); puthex(v); putc('\n');
  s=100; v=0x0f;
  __asm__ volatile("amoor.w %0,%2,(%1)":"=r"(v):"r"(&s),"r"(0x0f):"memory");
  puts("rd!=rs2 OR: s="); puthex(s); putc('\n');
  return 0;
}

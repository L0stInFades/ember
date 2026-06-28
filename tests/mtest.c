#include "util.h"
static inline int mulh(int a,int b){int r;__asm__("mulh %0,%1,%2":"=r"(r):"r"(a),"r"(b));return r;}
static inline unsigned mulhu(unsigned a,unsigned b){unsigned r;__asm__("mulhu %0,%1,%2":"=r"(r):"r"(a),"r"(b));return r;}
static inline int mulhsu(int a,unsigned b){int r;__asm__("mulhsu %0,%1,%2":"=r"(r):"r"(a),"r"(b));return r;}
int main(void){
  CHECK("mulh_neg", mulh(-7, 1000000000), (int)(((long long)-7*1000000000)>>32));
  CHECK("mulh_nn",  mulh(-100000, -100000), (int)(((long long)-100000*-100000)>>32));
  CHECK("mulhu",    mulhu(0xFFFFFFFFu,0xFFFFFFFFu), (unsigned)(((unsigned long long)0xFFFFFFFFull*0xFFFFFFFFull)>>32));
  CHECK("mulhsu",   mulhsu(-3, 0xFFFFFFFFu), (int)(((long long)-3*(unsigned long long)0xFFFFFFFFull)>>32));
  // heavy shift/mask like inflate BITS()
  unsigned hold=0xDEADBEEF; int ok=1;
  for(int n=0;n<32;n++){ unsigned m=(1u<<n)-1; if((hold&m)!=(0xDEADBEEF&m)) ok=0; }
  CHECK("bits_mask", ok, 1);
  CHECK("shr_var", (0x80000000u>>31), 1);
  CHECK("sar_var", ((int)0x80000000)>>31, -1);
  return report();
}

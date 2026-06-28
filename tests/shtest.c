#include "util.h"
int main(void){
  volatile int x = -1;            // 0xffffffff
  volatile int y = 0xffffff00;    // negative
  CHECK("srai_-1>>8",  x>>8,  -1);             // arithmetic
  CHECK("srai_neg>>8", y>>8,  (int)0xffffffff);
  CHECK("srli_pos>>8", ((unsigned)0xffffff00)>>8, 0x00ffffff);
  volatile int w = (int)0xFFABCDEF;  // sign-extended 24-bit field (bit23=1)
  CHECK("fieldext",   (w<<8)>>8, w); // (v<<8)>>8 round-trips a sign-extended 24-bit value
  // 24-bit signed bitfield like printf_spec field_width=-1
  volatile unsigned sp = 0xffffff00u | 0x12;   // field_width=0xffffff, type=0x12
  CHECK("fw_signext", ((int)sp)>>8, -1);
  return report();
}

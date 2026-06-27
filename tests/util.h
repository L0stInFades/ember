#pragma once
typedef unsigned int u32;
typedef unsigned long long u64;
#define UART 0x10000000u
static inline void putc(char c){ *(volatile unsigned char*)UART = c; }
static void puts(const char*s){ while(*s) putc(*s++); }
static void puthex(u32 v){ puts("0x"); for(int i=28;i>=0;i-=4){ int d=(v>>i)&0xf; putc(d<10?'0'+d:'a'+d-10);} }
static void putdec(u32 v){ char b[12]; int n=0; if(!v){putc('0');return;} while(v){b[n++]='0'+v%10; v/=10;} while(n--) putc(b[n]); }
static int _fails=0;
#define CHECK(name, got, exp) do{ u32 g=(u32)(got), e=(u32)(exp); \
  if(g!=e){_fails++; puts("FAIL "); puts(name); puts(" got="); puthex(g); puts(" exp="); puthex(e); putc('\n'); } \
  else { puts("ok   "); puts(name); putc('\n'); } }while(0)
static void report(void){ if(_fails){ puts("RESULT: FAIL "); putdec(_fails); putc('\n'); }
  else puts("RESULT: PASS\n"); }

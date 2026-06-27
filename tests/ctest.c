#include "util.h"
int fib(int n){ if(n<2) return n; return fib(n-1)+fib(n-2); }
int main(void){
  int s=0; for(int i=0;i<10;i++) s+=i;     // loops/branches
  CHECK("sum0_9", s, 45);
  CHECK("fib10", fib(10), 55);
  volatile int a=12345, b=678;
  CHECK("mul", a*b, 12345*678);
  report();
  return 0;
}

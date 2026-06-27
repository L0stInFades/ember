#include "io.h"

unsigned gcd(unsigned a, unsigned b) { while (b) { unsigned t = a % b; a = b; b = t; } return a; }
int fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
int fact(int n) { int r = 1; for (int i = 2; i <= n; i++) r *= i; return r; }

int main(void) {
    puts_("=== RV32IM 真实 C 计算测试 ===\n");
    puts_("123*456      = "); print_dec(123 * 456);       putch('\n');
    puts_("1000000/7    = "); print_dec(1000000 / 7);     putch('\n');
    puts_("1000000%7    = "); print_dec(1000000 % 7);     putch('\n');
    puts_("-100/7       = "); print_dec(-100 / 7);        putch('\n');
    puts_("-100%7       = "); print_dec(-100 % 7);        putch('\n');
    puts_("gcd(1071,462)= "); print_dec((int)gcd(1071, 462)); putch('\n');
    puts_("fib(20)      = "); print_dec(fib(20));         putch('\n');
    puts_("10!          = "); print_dec(fact(10));        putch('\n');
    int ok = (123*456==56088) && (1000000/7==142857) && (1000000%7==1)
           && (gcd(1071,462)==21) && (fib(20)==6765) && (fact(10)==3628800);
    puts_(ok ? "ALL PASS\n" : "FAIL\n");
    return ok ? 0 : 1;
}

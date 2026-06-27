#include "io.h"

int main(void) {
    puts_("Hello, RISC-V! 这是真实编译的 C 跑在自建核上。\n");
    puts_("1+2+...+100 = ");
    int s = 0;
    for (int i = 1; i <= 100; i++) s += i;
    print_dec(s);
    putch('\n');
    return 0;
}

// Verilator harness for vtop (rvlinux SoC). Boots OpenSBI+Linux.
#include "Vvtop.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <ctime>
#include <cstring>
#include <unistd.h>
#include <fcntl.h>
#include <termios.h>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vvtop* top = new Vvtop;

    uint64_t max_cyc = 4000000000ULL;     // hard cap
    for (int i=1;i<argc;i++){
        if (sscanf(argv[i],"--maxcyc=%llu",(unsigned long long*)&max_cyc)==1) {}
    }

    // make stdin non-blocking (and raw if a tty) so keystrokes feed UART RX
    { int fl=fcntl(0,F_GETFL,0); if(fl!=-1) fcntl(0,F_SETFL,fl|O_NONBLOCK);
      struct termios tio; if (isatty(0) && tcgetattr(0,&tio)==0){
          struct termios raw=tio; raw.c_lflag &= ~(ICANON|ECHO);
          tcsetattr(0,TCSANOW,&raw); } }
    int rx_pending = -1;     // byte staged for UART RX, -1 = none

    // reset
    top->rst = 1; top->clk = 0;
    top->rx_valid = 0; top->rx_byte_in = 0;
    for (int i=0;i<8;i++){ top->clk=!top->clk; top->eval(); }
    top->rst = 0;

    uint64_t cyc=0; uint32_t last_pc=0; uint64_t stuck=0; unsigned minpriv=3;
    int trace = (getenv("TRACE")!=0);
    int trace_mmio = (getenv("TRACE_MMIO")!=0);
    uint64_t trace_mmio_limit = 2000;
    const char* ml = getenv("TRACE_MMIO_LIMIT");
    if (ml) trace_mmio_limit = strtoull(ml, 0, 0);
    uint64_t trace_mmio_seen = 0;
    const char* wp = getenv("WATCHPC");
    uint32_t watchpc = wp ? (uint32_t)strtoul(wp,0,16) : 0;
    const char* expect_uart = getenv("EXPECT_UART");
    size_t expect_uart_len = expect_uart ? strlen(expect_uart) : 0;
    size_t expect_uart_pos = 0;
    int dumped = 0;
    const char* rn[32]={"zero","ra","sp","gp","tp","t0","t1","t2","s0","s1","a0","a1","a2","a3","a4","a5","a6","a7","s2","s3","s4","s5","s6","s7","s8","s9","s10","s11","t3","t4","t5","t6"};
    time_t t0=time(0);
    while (!Verilated::gotFinish() && cyc<max_cyc) {
        // stage a stdin byte for UART RX when none is in flight
        if (rx_pending<0 && (cyc & 0x3FF)==0) {
            unsigned char ch; ssize_t n=read(0,&ch,1);
            if (n==1) rx_pending = ch;
        }
        top->rx_valid   = (rx_pending>=0);
        top->rx_byte_in = (rx_pending>=0)?(uint8_t)rx_pending:0;
        top->eval();                       // settle rx_ready (clk still low)
        int rx_consumed = top->rx_ready;
        top->clk = 1; top->eval();
        if (trace && cyc<60)
            fprintf(stderr,"cyc%llu pc=%08x priv=%u\n",(unsigned long long)cyc,
                    (unsigned)top->dbg_pc,(unsigned)top->dbg_priv);
        // sample on posedge
        if (top->uart_we) {
            char tx = (char)top->uart_data;
            fputc(tx, stdout); fflush(stdout);
            if (expect_uart_len != 0) {
                if (tx == expect_uart[expect_uart_pos]) {
                    expect_uart_pos++;
                } else {
                    expect_uart_pos = (tx == expect_uart[0]) ? 1 : 0;
                }
                if (expect_uart_pos == expect_uart_len) {
                    fprintf(stderr,
                            "[VSIM] expect matched \"%s\" after %llu cycles pc=%08x priv=%u scause=%08x mcause=%08x stval=%08x satp=%08x sepc=%08x mepc=%08x mip=%08x mie=%08x mtime=%08x mtimecmp=%08x\n",
                            expect_uart, (unsigned long long)cyc,
                            (unsigned)top->dbg_pc, (unsigned)top->dbg_priv,
                            (unsigned)top->dbg_scause, (unsigned)top->dbg_mcause,
                            (unsigned)top->dbg_stval, (unsigned)top->dbg_satp,
                            (unsigned)top->dbg_sepc, (unsigned)top->dbg_mepc,
                            (unsigned)top->dbg_mip, (unsigned)top->dbg_mie,
                            (unsigned)top->dbg_mtime, (unsigned)top->dbg_mtimecmp);
                    break;
                }
            }
        }
        if (trace_mmio && top->dbg_mmio_valid) {
            trace_mmio_seen++;
            if (trace_mmio_limit == 0 || trace_mmio_seen <= trace_mmio_limit) {
                fprintf(stderr,
                        "[MMIO] cyc=%llu pc=%08x priv=%u %c f3=%u pa=%08x wdata=%08x rdata=%08x scause=%08x\n",
                        (unsigned long long)cyc, (unsigned)top->dbg_pc,
                        (unsigned)top->dbg_priv, top->dbg_mmio_we ? 'W' : 'R',
                        (unsigned)top->dbg_mmio_funct3, (unsigned)top->dbg_mmio_pa,
                        (unsigned)top->dbg_mmio_wdata, (unsigned)top->dbg_mmio_rdata,
                        (unsigned)top->dbg_scause);
            } else if (trace_mmio_seen == trace_mmio_limit + 1) {
                fprintf(stderr, "[MMIO] trace limit reached at %llu transactions\n",
                        (unsigned long long)trace_mmio_limit);
            }
        }
        if (top->halt) {
            printf("\n[VSIM] halt exit=%u after %llu cycles pc=%08x priv=%u scause=%08x mcause=%08x stval=%08x satp=%08x sepc=%08x mepc=%08x mip=%08x mie=%08x mtime=%08x mtimecmp=%08x\n",
                   (unsigned)top->exit_code,(unsigned long long)cyc,
                   (unsigned)top->dbg_pc,(unsigned)top->dbg_priv,
                   (unsigned)top->dbg_scause,(unsigned)top->dbg_mcause,
                   (unsigned)top->dbg_stval,(unsigned)top->dbg_satp,
                   (unsigned)top->dbg_sepc,(unsigned)top->dbg_mepc,
                   (unsigned)top->dbg_mip,
                   (unsigned)top->dbg_mie,(unsigned)top->dbg_mtime,
                   (unsigned)top->dbg_mtimecmp);
            break;
        }
        top->clk = 0; top->eval();
        if (rx_consumed) rx_pending = -1;   // byte latched into UART this posedge
        if (top->dbg_priv < minpriv) minpriv = top->dbg_priv;
        if (watchpc && top->dbg_pc==watchpc && !dumped) {
            dumped=1;
            fprintf(stderr,"[WATCH] pc=%08x priv=%u scause=%08x mcause=%08x stval=%08x satp=%08x sepc=%08x mepc=%08x regs:\n",
                    (unsigned)top->dbg_pc,(unsigned)top->dbg_priv,
                    (unsigned)top->dbg_scause,(unsigned)top->dbg_mcause,
                    (unsigned)top->dbg_stval,(unsigned)top->dbg_satp,
                    (unsigned)top->dbg_sepc,(unsigned)top->dbg_mepc);
            for(int r=0;r<32;r++){ top->dbg_rsel=r; top->eval();
                fprintf(stderr,"  %-4s=%08x",rn[r],(unsigned)top->dbg_rval);
                if((r&3)==3) fprintf(stderr,"\n"); }
            // dump string pointed by a1 (panic("%s",err)); a1 virt 0xc0..->phys-0x40000000
            top->dbg_rsel=10; top->eval(); uint32_t p=top->dbg_rval;
            fprintf(stderr,"[WATCH] a0=%08x string: \"",p);
            for(int k=0;k<64;k++){ uint32_t pa=(p+k)-0x40000000;
                top->dbg_maddr=pa & ~3u; top->eval();
                uint32_t w=top->dbg_mval; char c=(w>>((pa&3)*8))&0xff;
                if(c==0) break; fputc(c>=32&&c<127?c:'?',stderr); }
            fprintf(stderr,"\"\n");
        }
        cyc++;
        // stuck detector: same pc for a long time -> dump trap CSRs
        if (top->dbg_pc==last_pc) {
            if (++stuck==3000000ULL) {
                fprintf(stderr,"[STUCK] pc=%08x priv=%u scause=%08x mcause=%08x stval=%08x satp=%08x sepc=%08x mip=%08x mie=%08x\n",
                    (unsigned)top->dbg_pc,(unsigned)top->dbg_priv,
                    (unsigned)top->dbg_scause,(unsigned)top->dbg_mcause,(unsigned)top->dbg_stval,
                    (unsigned)top->dbg_satp,(unsigned)top->dbg_sepc,
                    (unsigned)top->dbg_mip,(unsigned)top->dbg_mie);
            }
        } else { last_pc=top->dbg_pc; stuck=0; }
        // liveness / progress
        if ((cyc % 2000000ULL)==0) {
            fprintf(stderr,"[VSIM] %llu Mcyc  pc=%08x priv=%u minpriv=%u mip=%08x mie=%08x mtime=%08x mtimecmp=%08x (%lds)\n",
                (unsigned long long)(cyc/1000000),(unsigned)top->dbg_pc,
                (unsigned)top->dbg_priv,minpriv,
                (unsigned)top->dbg_mip,(unsigned)top->dbg_mie,
                (unsigned)top->dbg_mtime,(unsigned)top->dbg_mtimecmp,(long)(time(0)-t0));
        }
    }
    if (cyc>=max_cyc) {
        fprintf(stderr,"[VSIM] reached max cycles pc=%08x priv=%u scause=%08x mcause=%08x stval=%08x satp=%08x sepc=%08x mepc=%08x mip=%08x mie=%08x mtime=%08x mtimecmp=%08x\n",
            (unsigned)top->dbg_pc,(unsigned)top->dbg_priv,
            (unsigned)top->dbg_scause,(unsigned)top->dbg_mcause,
            (unsigned)top->dbg_stval,(unsigned)top->dbg_satp,
            (unsigned)top->dbg_sepc,(unsigned)top->dbg_mepc,
            (unsigned)top->dbg_mip,
            (unsigned)top->dbg_mie,(unsigned)top->dbg_mtime,
            (unsigned)top->dbg_mtimecmp);
    }
    top->final(); delete top; return 0;
}

# RISC-V core: from single-cycle RV32I to booting MMU Linux to a shell

Honest summary of what was built, what actually runs, and the measured numbers.

## Headline result
A from-scratch RISC-V core (`rvlinux.v`) boots **real, unmodified Linux 6.1.44 on
OpenSBI** through a full Sv32 MMU all the way to an **interactive BusyBox root
shell**, driven over an emulated 16550 UART with working interrupts.

Live session (commands typed over the UART RX path, output over UART TX IRQ):
```
Welcome to Buildroot
buildroot login: root
# uname -a
Linux buildroot 6.1.44 #3 SMP ... riscv32 GNU/Linux
# cat /proc/cpuinfo
isa : rv32ima      mmu : sv32
# free
Mem:  105284  6560  80396 ...
# echo RVCORE_SHELL_OK
RVCORE_SHELL_OK
```
`/proc/cpuinfo` reporting `rv32ima` + `sv32` confirms the kernel is exercising our
ISA and page-table walker. Full transcript: `/tmp/shell_transcript.txt`.

## What the Linux core implements (`rvlinux.v`, single-cycle)
- **RV32 IMAC** base + multiply/divide + atomics (LR/SC, AMO*) + compressed.
- **M / S / U privilege**, `mstatus`/`mie`/`mip`, full S-mode CSRs, `medeleg`/`mideleg`,
  vectored traps, `MRET`/`SRET`/`WFI`, misaligned-access traps.
- **Sv32 MMU**: combinational page-table walk, A/D bit hardware update, page-fault
  causes, `satp`, `SUM`/`MXR`, `sfence.vma`.
- **SoC**: 16550 UART (with TX-empty + RX interrupts), CLINT (mtime/mtimecmp/msip),
  a minimal **SiFive-style PLIC** (priority/enable/threshold/claim/complete, S-context),
  syscon poweroff/reboot.

## Verification (directed tests, iverilog)
All pass: `isa`, `amotest`, `mmu`, `ctest` (RVC), `shtest`, `mtest` (M-ext),
`utrap` (S->U `sret` + U-mode `ecall`). Run via `tests/build_run.sh <name>`.

## Key bugs found and fixed to reach the shell
1. **`mip.STIP` not writable** — OpenSBI injects the S-timer IRQ via `mip.STIP`; it
   was being dropped, so the S-timer never fired, RCU grace periods never completed,
   and `rcu_barrier()` in `kernel_init` hung forever. Making STIP writable unblocked
   userspace launch.
2. **Timer storm** — `mtime` advances 1/cycle; with a 10 MHz DTB timebase the timer
   handler took longer than a tick, so each `next = now + period` was already in the
   past -> permanent re-fire. Fixed by setting the DTB `timebase-frequency` to 100 MHz.
3. **Hard-float SIGILL** — stock BusyBox was `rv32imafd`; our core has no F/D, so
   `init` died with SIGILL. Rebuilt a **soft-float `rv32imac/ilp32`** userspace.
4. **bunzip2 + misaligned storm** — the initramfs was silently BZIP2-compressed
   (Kconfig "choice" defaulted away from NONE); the in-kernel bunzip2 does floods of
   misaligned accesses, each trapped and software-emulated = pathological. Forced a
   truly **uncompressed (NONE)** initramfs.
5. **Userspace console needed real interrupts** — polled mode let kernel `printk`
   work (busy-poll), but `init`'s buffered tty writes never drained and there was no
   RX. Implemented the **UART THRE/RX interrupts + PLIC**, routed to `mip.SEIP`, and
   fed RX from sim stdin. This produced the interactive shell.
6. Earlier: signed DIV/REM, UART byte-lane, **SRAI sign-extension**, LR/SC reservation
   cleared on trap, explicit MUL sign/zero extension, RVC decompressor.

## Synthesis (yosys + nextpnr-ecp5, LFE5U-45F)
| Block | LUT4 | FF | DSP (MULT18) | Dist-RAM | Fmax |
|---|---|---|---|---|---|
| `rvcore.v` (single-cycle RV32IM+Zicsr "usable chip") | ~3701 (6337 packed COMB) | 723 | 4 | 288 | **~24 MHz** |
| `cache.v` (1 KB direct-mapped, write-back) | 1727 | 351 | 0 | 280 | **~73-97 MHz** |

The single-cycle Fmax is limited by the combinational path fetch->decode->ALU/**multiplier**
->memory->writeback in one cycle (critical path runs through the `MULT18X18D`). The
prior 5-stage pipeline version reached ~68 MHz by breaking that path.

## Cache (stretch goal): `cache.v` + `slowmem.v` + `tb_cache.v`
Direct-mapped, **write-back, write-allocate**, parameterized lines/words, single-cycle
hit, miss stalls the requester while it (optionally writes back the dirty victim and)
refills from a multi-cycle word-wide memory. `RO=1` gives an instruction cache.

Verified (`CACHE_RESULT: PASS`): cold-fill reads return backing data, re-reads hit,
write/read-back, and **write-back-on-eviction** (a dirty line evicted then re-fetched
returns the written value, proving the flush path).

Measured on a 128-word array reused 8x (1 KB cache, 8-cycle memory):
- hit rate **98.5 %** (1009 hits / 38 misses of 1024 accesses)
- backing-memory traffic **6.2x lower** (164 vs 1024 word transfers)
- AMAT **2.32 vs 9.00 cyc/access -> 3.87x faster**

## Honest caveats / scope
- The Linux boot runs in **simulation** (Verilator), not on FPGA silicon. `rvlinux.v`
  uses a large behavioral RAM array and a combinational PTW, so it is a faithful
  *simulation model*; making it synthesizable needs a real (multi-cycle) memory
  interface and a sequential PTW. The synthesis numbers above are for the
  synthesizable `rvcore.v` and the standalone `cache.v`.
- The cache is **verified and synthesized standalone**; it is not yet wired into the
  booting core (the single-cycle datapath assumes 1-cycle memory). Integrating it
  needs the multi-cycle memory interface above.
- Native misaligned-access support was deliberately **not** added (too invasive for a
  single-cycle datapath); misaligned accesses trap and are emulated. The shell boot
  avoids the pathological case by using an uncompressed initramfs.
- No FP (no F/D); userspace is soft-float `rv32imac/ilp32`.

## How to reproduce
- Directed tests: `for t in isa amotest mmu ctest shtest mtest utrap; do bash tests/build_run.sh $t; done`
- Boot to shell: `bash build_vtop.sh linux-build/fw_payload_sf.hex && bash run_shell.sh`
- Cache test: `iverilog -g2012 -o /tmp/tb_cache cache.v slowmem.v tb_cache.v && vvp /tmp/tb_cache`
- Synthesis: `yosys synth_rvcore.ys` / `yosys syn_top_cache.v cache.v` then `nextpnr-ecp5 --45k ...`

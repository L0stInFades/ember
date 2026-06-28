# Ember

A from-scratch RISC-V core that grows from a single-cycle adder into a chip that
**boots real, unmodified Linux through an Sv32 MMU all the way to an interactive
shell** - a tiny spark that lights up a whole operating system.

```
Welcome to Buildroot
buildroot login: root
# uname -a
Linux buildroot 6.1.44 #3 SMP riscv32 GNU/Linux
# cat /proc/cpuinfo
isa : rv32ima      mmu : sv32
# free
Mem:  105284  6560  80396 ...
# echo EMBER_SHELL_OK
EMBER_SHELL_OK
```

Everything here is written by hand in Verilog: the CPU, the MMU, the privilege
modes, the interrupt controller and UART. Linux 6.1.44 (on OpenSBI) boots to a
BusyBox root shell in simulation, with the console driven over an emulated 16550
UART with working interrupts. `/proc/cpuinfo` reporting `rv32ima` + `sv32`
confirms the kernel is genuinely exercising our ISA and page-table walker.

## What's inside

Several cores, built in order of increasing ambition:

| Core | File | Description |
|---|---|---|
| Single-cycle | `rtl/cores/cpu.v` | Minimal RV32I, one instruction per cycle |
| 5-stage pipeline | `rtl/cores/cpu_pipe.v` | Classic IF/ID/EX/MEM/WB with hazard handling |
| Superscalar | `rtl/cores/cpu_super.v` | 2-wide in-order issue |
| Out-of-order | `rtl/cores/cpu_ooo.v` | Tomasulo-style OoO execution |
| "Usable chip" | `rtl/cores/rvcore.v` | Single-cycle RV32IM + Zicsr + M-mode traps + UART SoC |
| **Linux core** | `rtl/cores/rvlinux.v` | **RV32IMAC + M/S/U + Sv32 MMU + CLINT/PLIC/UART** |

The Linux core (`rvlinux.v`) implements:
- **RV32 IMAC**: integer, mul/div, atomics (LR/SC, AMO*), compressed instructions
- **M / S / U privilege**: full S-mode CSRs, `medeleg`/`mideleg`, vectored traps,
  `MRET`/`SRET`/`WFI`, misaligned-access traps
- **Sv32 MMU**: page-table walk, hardware A/D bit update, page faults, `satp`,
  `SUM`/`MXR`, `sfence.vma`
- **SoC**: 16550 UART (TX-empty + RX interrupts), CLINT timer/IPI, a minimal
  SiFive-style PLIC, syscon poweroff/reboot

Plus a standalone **direct-mapped, write-back I/D cache** (`rtl/cache/cache.v`)
with a multi-cycle memory model and a measurement testbench.

## Repository layout

```
rtl/cores/   the CPU cores (single-cycle -> OoO -> Linux SoC)
rtl/cache/   direct-mapped write-back cache + multi-cycle memory model
sim/         Verilator harness (vtop.v, sim_main.cpp) and iverilog testbenches
tests/       directed C tests (ISA, atomics, MMU, RVC, M-ext, U-mode traps)
synth/       yosys ECP5 synthesis scripts and wrappers
tools/       tiny assembler (asm.py) and bin->hex helper
scripts/     build/boot helpers (build_vtop.sh, run_boot.sh, run_shell.sh)
linux/       Docker + buildroot/OpenSBI build scripts and the device tree
docs/        FINAL_REPORT.md (honest write-up of what runs and the numbers)
```

## Quick start

Prerequisites: a RISC-V `clang`/`lld` (e.g. Homebrew LLVM) for the C tests, and
[`oss-cad-suite`](https://github.com/YosysHQ/oss-cad-suite-build) (Verilator,
iverilog, yosys, nextpnr) on your `PATH` or unpacked at `./oss-cad-suite`.

Run the default directed, rvtests, RVTRACE, reference-trace, and cache regression:
```sh
./verify.sh
```

Exercise the cache (correctness + hit-rate/AMAT measurement):
```sh
iverilog -g2012 -o /tmp/tb_cache rtl/cache/cache.v rtl/cache/slowmem.v sim/tb_cache.v
vvp /tmp/tb_cache
```

ECP5 synthesis (area/Fmax):
```sh
yosys synth/synth_rvcore.ys     # single-cycle "usable chip"
yosys synth/synth_cache.ys      # the cache
```

Boot Linux to a shell (after building the payload, see `linux/`):
```sh
bash scripts/build_vtop.sh linux/fw_payload_sf.hex
bash scripts/run_shell.sh       # boots, logs in as root, runs a few commands
```

## Building the Linux image

The prebuilt OpenSBI+Linux payload (~47 MB) is **not** committed (rebuildable and
too large for git). `linux/` contains the Docker + buildroot scripts that produce
it: a **soft-float `rv32imac/ilp32`** BusyBox userspace, an uncompressed initramfs,
a 100 MHz DTB timebase, and an OpenSBI `FW_PAYLOAD`. See the scripts in `linux/`
(`soft_float_build.sh`, `kernel_none_sf.sh`, `repackage_sf.sh`) for the flow.

## Results

ECP5 synthesis (yosys + nextpnr, LFE5U-45F):

| Block | LUT4 | FF | DSP | Fmax |
|---|---|---|---|---|
| `rvcore.v` (single-cycle RV32IM SoC) | ~3700 | 723 | 4 | ~24 MHz |
| 5-stage pipeline (`cpu_pipe.v`) | - | - | - | ~68 MHz |
| `cache.v` (1 KB direct-mapped) | 1727 | 351 | 0 | ~73-97 MHz |

The single-cycle Fmax is limited by the one-cycle path through the multiplier;
the pipeline breaks that path. Cache on a 128-word array reused 8x (8-cycle
memory): **98.5% hit rate, 6.2x less memory traffic, AMAT 3.87x faster**.

## Honest caveats

- The Linux boot runs in **Verilator simulation**, not on FPGA silicon. `rvlinux.v`
  uses a behavioral RAM array and a combinational page-table walk, so it is a
  faithful *simulation model*; the synthesizable cores are `rvcore.v` (and the
  smaller variants) and the standalone `cache.v`.
- The cache is verified and synthesized standalone, not yet wired into the booting
  core (the single-cycle datapath assumes 1-cycle memory).
- No FP; userspace is soft-float `rv32imac/ilp32`. Misaligned accesses trap and are
  emulated rather than handled natively.

Full details, the bug-hunt log, and reproduction steps are in
[`docs/FINAL_REPORT.md`](docs/FINAL_REPORT.md).

## Acknowledgements

Built on the shoulders of [OpenSBI](https://github.com/riscv-software-src/opensbi),
[Buildroot](https://buildroot.org/), the
[riscv-tests](https://github.com/riscv-software-src/riscv-tests) conventions, and
[oss-cad-suite](https://github.com/YosysHQ/oss-cad-suite-build) (Verilator, Icarus
Verilog, yosys, nextpnr).

## License

[MIT](LICENSE)

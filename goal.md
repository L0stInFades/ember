# Ember: the long goal

> A continuous north-star for turning Ember from a simulator-only learning core
> into a **famous, silicon-proven, industrial-grade, high-performance RISC-V
> application processor**. This document is meant to outlive any single milestone:
> re-read it, measure against it, move the numbers.

---

## 0. The one-sentence goal

**Make Ember an RVA23-class 64-bit application processor that boots mainline Linux
distros on its own silicon, is verified to industrial standards in CI, and posts
CoreMark/MHz, DMIPS/MHz and SPEC/GHz numbers competitive with the best open cores.**

If a stranger can buy/clone a board, `apt install` something, and cite Ember's SPEC
number in a paper, we have won.

---

## 1. North stars (what "industrial-grade, high-performance" actually means)

We measure ourselves against the open cores that already crossed the line from
"project" to "industry". These are the bars, with real numbers:

| Core | Class | Pipeline | Perf (reported) | Silicon | Why it matters |
|---|---|---|---|---|---|
| **XiangShan "Kunminghu" (KMH)** | server OoO RV64GC | deep OoO | **>15 SPECCPU2006/GHz**, targets **RVA23** | taped out (multiple nodes) | the gold standard for *open* + *high-perf* + *verified* (difftest vs NEMU/Spike) |
| **BOOMv3 (SonicBOOM)** | OoO RV64GC | 10-stage, 12-cyc mispredict | **3.87 DMIPS/MHz**, TAGE+uBTB | 45nm @1.5GHz, 1.7mm², 300mW | reference open out-of-order microarchitecture |
| **CVA6 / Ariane (OpenHW)** | in-order RV64GC | 6-stage | **1.21 DMIPS/MHz** | 22nm @1.7GHz, 0.3mm², 52mW | industrial *verification* (core-v-verif UVM), real tape-outs |
| **Rocket (Chipyard)** | in-order RV64GC | 5-stage | **1.71 DMIPS/MHz** | 45nm @1.6GHz | the ISA reference; TileLink + Linux + many tape-outs |

Reference ISA target: **RVA23 profile** (ratified 2024-10) - the industry contract
for 64-bit application processors. It makes **Vector (V)** and **Hypervisor (H)**
*mandatory*, alongside the usual IMAFDC + Zicsr/Zifencei + bit-manip (Zba/Zbb/Zbs)
+ cache-management (Zicbom/Zicbop/Zicboz) and more.

---

## 2. Where Ember is today (brutally honest baseline)

What exists (see `README.md` / `docs/FINAL_REPORT.md`):

- A family of hand-written cores: single-cycle, 5-stage pipeline, 2-wide
  superscalar, a Tomasulo OoO, and `rvlinux.v` (RV32IMAC + M/S/U + Sv32) that
  **boots Linux 6.1.44 to a shell - in Verilator simulation**.
- Synthesizable today (ECP5, measured): `cpu_pipe.v` ~68 MHz, `rvcore.v` ~24 MHz,
  `cache.v` (standalone, 1 KB DM write-back) ~73-97 MHz.

The gap to "industrial" is large and we will not pretend otherwise:

| Dimension | Today | Industrial bar |
|---|---|---|
| Width | **RV32** | RV64 (RVA23 is 64-bit only) |
| Float | soft-float only | hardware F/D (and later V) |
| The Linux core | **simulation model**: 128 MB behavioral RAM, **combinational** page-table walk; `cpu_ooo.v` won't even finish place-and-route (~12k FFs from multi-port behavioral memories) | every block maps to real cells/SRAM, closes timing |
| Memory system | single-cycle behavioral arrays; cache **not integrated** | L1 (non-blocking, MSHRs) + L2, real TLBs, **pipelined** HW PTW |
| Interconnect | a custom `req/ack` handshake; mostly no bus at all | **AXI4 / TileLink**, coherent fabric for SMP |
| Verification | directed C tests + one Linux boot | **RISCOF compliance, riscv-dv random + difftest vs Spike, formal (RVFI), UVM coverage closure, CI** |
| Silicon | none | FPGA on a real board, then **ASIC tape-out** |
| Debug | none | RISC-V Debug spec + JTAG, triggers, trace |

---

## 3. The roadmap (phased, measurable, continuous)

Each phase has a hard **Definition of Done (DoD)**. Do not claim a phase until its
DoD is green in CI. Phases are roughly sequential but P1 (verification) runs
*forever* in parallel from the moment it starts.

### P0 - Make it real (synthesizable, on an FPGA, booting from DRAM)
Turn the *simulation* Linux core into *hardware*.
- Replace behavioral `imem/dmem` with a real memory interface; infer/instantiate
  block RAM; add a proper **DRAM controller** path (e.g. LiteDRAM) on a dev board.
- Make the PTW **sequential** (a small FSM), not combinational. Integrate `cache.v`
  as a real L1 behind the LSU/fetch.
- Bring up on a concrete board (Arty A7 / Nexys / KC705 / Genesys2 class) with UART;
  add a JTAG **RISC-V Debug Module**.
- **DoD:** RV32IMAC, in-order, **boots the existing Linux image from DRAM on real
  FPGA hardware** to the shell; ≥100 MHz on the target FPGA; `git`-reproducible
  bitstream build.

### P1 - Verification foundation (the thing that makes it "industrial")
Stand up the methodology used by CVA6/XiangShan. This never stops.
- **Compliance:** pass `riscv-arch-test` via **RISCOF** for every implemented ext.
- **Co-simulation / difftest:** lockstep against a golden ISS (**Spike**/NEMU) via
  **RVVI** trace compare on every instruction; any divergence fails CI.
- **Constrained-random:** integrate **riscv-dv** to generate stress streams.
- **Formal:** wire up **RVFI + riscv-formal** bounded proofs (no illegal state,
  CSR/trap/atomicity properties), expand over time.
- **Coverage:** functional + code coverage with closure targets; nightly regression.
- **DoD:** green RISCOF, ≥1e9 difftest instructions/night with zero mismatches,
  riscv-formal core checks passing, coverage dashboards published, all in CI on PRs.

### P2 - 64-bit application-class (RV64GC, real privileged, mainline distro)
Become a "can run a real OS" core, CVA6-class.
- **RV64GC**: RV64 datapath, **hardware FPU (F/D)** (IEEE-754, proper NaN/rounding),
  **C** decode already present - port to 64-bit.
- Sv39 MMU, full PMP/PMA, **AIA/IMSIC** (modern interrupts) or a real PLIC+CLINT,
  misaligned handled in hardware (no trap-and-emulate).
- Boot flow: boot ROM -> **OpenSBI** -> **U-Boot** -> a **mainline Linux distro**
  (Debian/Ubuntu/Fedora RISC-V) with hard-float userspace.
- **DoD:** RV64GC passes RVA20/RVA22 compliance; boots an *unmodified upstream
  distro* on the FPGA board; difftest still green.

### P3 - Performance microarchitecture (earn the "high-performance")
Rebuild for IPC, the right way (the current `cpu_ooo.v` is a teaching model and is
explicitly retired here as a reference, not a basis).
- **Front-end:** decoupled fetch, **TAGE** + BTB + RAS branch prediction, an L0/uBTB
  for loops (BOOM-style), ≥2-wide fetch/decode.
- **Out-of-order back-end (synthesizable):** physical register file + rename,
  ROB, issue queues, multiple FUs, a real **load/store unit** with store buffer and
  load/store disambiguation; non-blocking **L1 with MSHRs**, an **L2**.
- Continuous benchmarking: **CoreMark, Dhrystone, embench, SPEC** tracked per commit.
- **DoD:** sustained **>2 DMIPS/MHz** and **>3 CoreMark/MHz**, with a public
  perf-vs-commit dashboard; timing still closes on FPGA.

### P4 - Memory & coherence + SMP
- A coherent interconnect (**TileLink-C** or **AXI/ACE/CHI**), shared L2/L3,
  cache-coherent **multi-core SMP**.
- **DoD:** dual- then quad-core **SMP Linux** boots and runs `stress-ng`/parallel
  benchmarks with scaling; coherence verified (litmus tests / formal memory model).

### P5 - RVA23: Vector + Hypervisor (the hard, valuable extensions)
- **RVV 1.0 Vector** unit (the big lift: VRF, lanes, mask/LMUL/SEW, vector LSU).
- **Hypervisor (H)** extension; run **KVM** with a guest Linux.
- The rest of RVA23 mandatory set (Zb*, Zicbo*, Zicond, etc.).
- **DoD:** passes the **RVA23** compliance set; runs vectorized kernels (e.g. BLAS,
  ML inference) with real speedup; boots a hypervisor with a guest VM.

### P6 - Silicon (the line between "project" and "real")
- Harden the design: synthesizable **SRAM macros** (memory compiler), CDC/reset
  discipline, clock gating + power intent (UPF), **DFT** (scan, MBIST).
- Prove the flow open first: **OpenLane/OpenROAD + Sky130** (Caravel/Efabless MPW)
  test chip; then a real PDK shuttle for the full core.
- **DoD:** a **working test chip** that executes code from its own ROM/UART; later,
  the application core closes timing in a real PDK and tapes out.

### P7 - Famous (ecosystem, numbers, community)
- Publish: microarchitecture spec, **SPEC/CoreMark/DMIPS numbers**, a perf
  dashboard, papers/talks, a buyable/clonable **dev board**.
- Open governance, contribution guide, stable releases, a security policy.
- **DoD:** Ember is *cited and used* by people who are not us - in a distro's
  hardware list, a paper, a product, or a course.

---

## 4. KPI scoreboard (move these numbers)

| Metric | Ember today | Near-term target | North-star (peers) |
|---|---|---|---|
| ISA | RV32IMAC + S/U + Sv32 | RV64GC + Sv39 | **RVA23** (V + H + Zb* + ...) |
| Whole-core synthesizable | partial (pipe/rvcore/cache) | entire core + SoC | silicon-proven |
| Fmax | ~68 MHz (ECP5, `cpu_pipe`) | 100-200 MHz FPGA / >1 GHz ASIC | ~2 GHz-class ASIC |
| DMIPS/MHz | n/a (no HW perf) | >2 | BOOM **3.87** |
| CoreMark/MHz | n/a | >3 | ~5-6 (high-end) |
| SPEC2006/GHz | n/a | first real number | XiangShan **>15** |
| Memory system | behavioral + comb PTW | L1(MSHR)+L2+TLB+seq PTW | coherent multi-level |
| Interconnect | custom req/ack | AXI4 + TileLink | coherent TileLink-C/CHI |
| Verification | directed C tests | RISCOF + difftest + formal in CI | full UVM coverage closure |
| OS | Linux in Verilator | mainline distro on FPGA from DRAM | SMP distro + KVM guest |
| Silicon | none | FPGA on real board | ASIC tape-out (MPW -> PDK) |
| Debug | none | RISC-V Debug + JTAG | triggers + trace |

---

## 5. Guardrails (principles that keep us honest)

1. **No simulation-only claims dressed up as hardware.** If it hasn't closed timing
   and run on real silicon/FPGA, say so (today's `rvlinux.v` is explicitly a sim
   model; `docs/FINAL_REPORT.md` keeps that honest).
2. **Difftest is always green.** Every instruction matches a golden ISS, or the
   build is red. Performance work never trades away correctness.
3. **Every feature is gated by compliance + regression + coverage**, not by a demo.
4. **Performance is tracked continuously**, per commit, on fixed benchmarks - no
   cherry-picked peaks.
5. **Reproducible builds** (bitstream, GDS, images) from clean checkout in CI.
6. **Upstream-first**: target mainline Linux, upstream GCC/LLVM, ratified specs -
   not forks we have to carry.

---

## 6. The very next concrete steps (entry into P0/P1)

1. Define a clean memory/bus boundary in `rtl/cores/rvlinux.v` and replace behavioral
   RAM with a BRAM/AXI memory model; make the PTW a sequential FSM.
2. Integrate `rtl/cache/cache.v` as a real L1 behind fetch + LSU (multi-cycle mem).
3. Pick a target FPGA board; bring up UART + DRAM; boot the existing image from DRAM.
4. Stand up RISCOF + a Spike difftest harness over RVVI in CI - before adding any new
   ISA features. Correctness infrastructure first, then RV64, then performance.

---

## References

- XiangShan KMH, ">15/GHz SPECCPU2006", RVA23 - RISC-V Summit Europe 2025; repo
  `github.com/OpenXiangShan/XiangShan`.
- RVA23 Profile, ratified 2024-10 (mandatory V + H) - `riscv.org`, `docs.riscv.org`.
- SonicBOOM (BOOMv3), CVA6/Ariane, Rocket - DMIPS/MHz, pipeline, silicon data from
  the open-source application-class RISC-V survey (CF'21) and the CVA6 22nm paper.
- Verification: RISCOF + riscv-arch-test, Google **riscv-dv**, **RVVI**/**RVFI**,
  **riscv-formal** (YosysHQ), difftest-vs-Spike/NEMU, UVM coverage.
- Physical: OpenLane/OpenROAD + Sky130 + Caravel (Efabless MPW); Chipyard for FPGA
  SoC integration; AXI4 and TileLink interconnect.

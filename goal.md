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

Current P0 snapshot (2026-06-28): the synthesizable Linux path is no longer only a
plan. The `RVLINUX_SYNTH_SHELL` top now routes through real multicycle fetch/LSU,
sequential Sv32 PTW, split I$/D$ L1, MMIO, PLIC/CLINT, and real backing BRAM, and
passes yosys on the core shell. In Verilator with the full soft-float
OpenSBI/Linux payload, the synth-shell path reaches Linux early boot and, with the
platform timebase corrected to 400 MHz, reaches NFS/9p/block-layer init through
`io scheduler kyber registered` within a 5B-cycle bounded run. Follow-up
fast-retire, fetch-overlap, direct CSR-completion fetch, and a retained split
one-entry ITLB/DTLB improve same-path timestamps (`kyber` 6.282s -> 3.121s)
without warnings, Oops, or panic. The split-TLB run also progresses beyond the old
`kyber` stop point into serial/ttyS0, loop, e1000e, usb-storage, PF_INET6,
PF_PACKET, 9pnet, and DNS resolver registration within 5B cycles. A stock-rootfs
10B-cycle split-TLB long run reaches userspace `/sbin/init` and Buildroot init
scripts (`syslogd`, `klogd`, `sysctl` all OK), then waits in `Starting network:
Waiting for interface eth0 to appear...`; the final PC is `arch_cpu_idle`,
consistent with a network/device-wait path rather than a kernel panic or PTW
correctness failure. Because the minimal synth-shell SoC has no Ethernet device, a
no-net rootfs variant now keeps only loopback networking and adds a static
`/dev/null`. With that minimal-SoC payload and the 400 MHz timebase, the
synth-shell Verilator run reaches `buildroot login:` after **8,716,611,501**
cycles. A tested divide-result-cache experiment was rejected because it regressed
the same full Linux run (`kyber` 5.586s -> 5.593s) and added area. A standard
manual runner, `run_synth_shell_nonet.sh`, now rebuilds or reuses the no-net
400 MHz payload, builds/reuses the synth-shell Verilator model, logs stdout/stderr,
and has itself matched the default `buildroot login:` expectation in the same
8,716,611,501-cycle run. An explicit `verify_p0_linux.sh` gate now wraps that path:
default mode runs the expensive boot-to-login check, `--smoke` does a quick OpenSBI
same-payload smoke, and `--check-logs=<prefix>` audits retained full-run logs. The
split ITLB/DTLB unit coverage is also tighter: `tb_rvlinux_mem_boundary.v` now
remaps a hot Sv32 VA to a second leaf PTE, proves both stale DTLB and ITLB entries
continue using the old PA until `tlb_flush`, then proves the flush forces a fresh
walk to the new PA and performs the expected A-bit update. The local Icarus run
passes with `MEM_BOUNDARY_RESULT: PASS` in
`logs/ci-mem-boundary-tlb-remap-20260629/tb_rvlinux_mem_boundary.log`. The
min-core CSR-to-boundary flush path is now covered too:
`tb_rvlinux_min_core_tlb_flush.v` executes `csrw satp`, enters S-mode, loads through
Sv32, executes `sfence.vma`, then loads the same VA again; the regression observes
two `tlb_flush` pulses (`satp=1`, `sfence=1`) and two data-VA PTW starts, passing
with `MIN_CORE_TLB_FLUSH_RESULT: PASS` in
`logs/ci-min-core-tlb-flush-20260629/tb_rvlinux_min_core_tlb_flush.log`. The
current `RVLINUX_SYNTH_SHELL` small-IO top wrapper also has fresh tool evidence:
`yosys synth_rvlinux_synth_shell_top.ys` reports 32 DP16KD, 10902 LUT4, 5118 FF,
108 TRELLIS_DPR16X4, and 0 check problems, and
`nextpnr-ecp5 --85k --package CABGA381 --speed 6 --seed 2 --freq 40` passes on
LFE5U-85F/CABGA381 with final routed Fmax 53.94 MHz. This moves the
synthesis/PnR-honesty item forward. A new `verify_ci.sh` scheduler now gives the
path scriptable local-CI/nightly profiles (`quick`, `pr`, `p0-smoke`, `p0-audit`,
`p0-pnr-audit`, `p0-evidence`, `p0-full`, `p0-pnr`, `p1`, `p1-trace-audit`,
`evidence-health`, `nightly`); its retained-login-log audit, retained-PnR audit,
combined retained Linux+PnR evidence audit, retained RVTRACE/ref-model audit,
retained dashboard/history health audit, and reused P0 smoke profile all pass. The
P1 trace audit rechecks retained `rvtrace_*.csv` with both
structural and reference-model checkers and currently covers 17 tests, 71,683
retired instructions, 27 traps, 6 AMOs, 12 PTE updates, and 25 privilege switches.
The added `mprv` directed trace covers MPRV+SUM data permissions: a user-page load
through `MPRV=1, MPP=S` succeeds with `SUM=1`, then faults with `SUM=0` and records
`mcause=13`, `mtval=0x40000000`, and the pre-trap MPRV bit.
The added `mxr` directed trace covers Sv32 MXR permissions: an S-mode load from a
supervisor execute-only page faults with `MXR=0`, then succeeds with `MXR=1` and
confirms only the PTE A bit was set.
The added `upage` directed trace covers U-mode Sv32 fetch/data permissions and
delegation: S-mode `sret`s into a user executable page, U-mode load from a
supervisor-only page delegates a load-page-fault to S-mode with `scause=13` and
`stval=0x80301000`, U-mode then stores/loads through a user data page, and a U-mode
`ecall` delegates to S before M-mode reporting.
The added `ifault` directed trace covers delegated Sv32 instruction page faults:
S-mode jumps to a supervisor-readable but non-executable page, the S trap handler
records `scause=12` and `stval=sepc`, returns to the `jalr` continuation, and
confirms the non-executable target PTE did not receive A/D updates. The local
`tools/rvtrace_ref.py` model now handles cause-12 fetch page-fault rows instead of
rejecting them as outside the reference model.
The added `wpfault` directed trace covers Sv32 store-permission faults and A/D
side effects: an S-mode load from a read-only supervisor page succeeds and sets
only A, an S-mode store to that same page delegates a store page fault without
setting D, then S-mode updates the PTE to add W and confirms the retried store
sets D.
The added `sum` directed trace covers S-mode SUM permissions directly: supervisor
store and load attempts to a user page fault with `SUM=0` and leave A/D clear,
then the same page loads and stores successfully with `SUM=1`, setting A and D in
order.
The added `badpte` directed trace covers the Sv32 reserved `R=0/W=1` PTE encoding:
S-mode store and instruction fetch through a `V|W|X` / `R=0` PTE both fault,
leave A/D clear, and leave the backing physical word unchanged.
The added `superpage` directed trace covers Sv32 level-1 superpage alignment:
a valid-looking leaf with nonzero PPN0 faults on S-mode store and instruction
fetch, leaves A/D clear, and leaves the backing physical return instruction
unchanged.
The added `amo_mmu` directed trace covers LR/SC/AMO under Sv32 permissions:
LR on a read-only page sets A only, SC faults without D while the page is
read-only, then successful SC and AMOADD on a writable page set D and update memory.
The added `misalign` directed trace covers M-mode misaligned LW/SW traps:
the misaligned load raises cause 4 with `mtval=&g_word+1` and leaves the
destination register unchanged, while the misaligned store raises cause 6 with
`mtval=&g_word+2` and leaves the backing word unchanged.
`tools/collect_ci_metrics.py` now emits per-run `summary.json` and `summary.md`
artifacts from `verify_ci.sh` logs, covering CI pass/fail, retained RVTRACE
coverage, CI evidence health, exact P1 external test names, P0 Linux gate
status/login cycles, and PnR Fmax/resource metrics;
`verify_ci.sh` generates those summaries automatically and the GitHub workflows
publish `summary.md` into the Actions step summary. `tools/render_ci_dashboard.py`
now builds cross-run `logs/ci-dashboard.json` / `logs/ci-dashboard.md` from those
summary artifacts and maintains a de-duplicated retained trend history in
`logs/ci-history.jsonl` plus `logs/ci-trend.md`. `tools/import_github_run_artifacts.py`
downloads a selected GitHub Actions run into `logs/github-run-<run-id>/`, writes a
small import manifest, and refreshes that same dashboard/history so hosted
artifacts can be retained without a manual `/tmp` staging step. The RVTRACE audit
now also writes
per-test `rvtrace_coverage.json` / `rvtrace_coverage.md` artifacts that expose where
the retained traps, AMOs, PTE updates, and privilege switches come from, and it now
enforces default per-test coverage floors so those signals cannot silently move out
of the intended directed tests. `tools/check_ci_dashboard.py` now turns retained
dashboard/history artifacts into a cheap `evidence-health` gate over parse-clean
artifacts, at least one successful imported GitHub run manifest with the expected
hosted artifact/summary counts plus resolvable quick/P1/RVTRACE summaries under
that same imported run, P0 Linux login evidence with a default 9B-cycle
ceiling, exact P1 external test composition across summary/dashboard/history
artifacts, 48 P1 external per-test floors including SV32 clean device-completion
checks, exact ACT/Spike group counts, exact
RVTRACE coverage test composition across summary/dashboard/history artifacts, 40
MHz PnR evidence, RVTRACE aggregate counts, and 48 RVTRACE per-test
coverage-floor checks. The current dashboard in this worktree scans 104
summaries, retains 104 history records, has a 35-run pass streak, and tracks the
latest P0 Linux evidence with
its 8,716,611,501-cycle login point, the latest P1 external evidence from
`logs/ci-p1-20260629-device-complete`, the latest imported hosted RVTRACE
audit/coverage from run `28341807002`, latest CI
evidence health, best PnR Fmax, profile counts, floor-check status, latest run
per profile, and recent runs. `verify_ci.sh` refreshes this dashboard
and trend history after every profile,
and the GitHub workflows publish the per-run summary plus cross-run dashboard/trend
artifacts.
The CI/cron wiring now exists too:
`.github/workflows/ci.yml` runs the hosted macOS quick profile on push/PR,
`.github/workflows/nightly.yml` targets a self-hosted macOS nightly at 01:00
Asia/Shanghai, and `tools/ci_cron.sh` provides a locked local cron/launchd wrapper;
`tools/ci_cron.sh p0-audit`, `tools/ci_cron.sh p0-evidence`,
`tools/ci_cron.sh p1-trace-audit`, `./verify_ci.sh evidence-health`, and quick
profile all have retained local passing evidence. After moving the work into the actual
GitHub worktree at `/Users/Apple/ember`, the source-only quick profile also passes
there with `logs/ci-quick-20260629-010333`; the retained RVTRACE audit/coverage
passes in `logs/ci-p1-trace-audit-20260629-010528`; and the local retained
evidence-health gate passes in `logs/ci-evidence-health-20260629-010541` with
36/36 checks passing. For the current `wpfault` increment, local directed tests,
rvtests, RVTRACE structural checks, RVTRACE reference-model checks, and cache/stage
smokes pass in `logs/ci-quick-20260629-wpfault/quick`, while full local `quick`
stops at `vtop_synth` because this machine has no `verilator` or `oss-cad-suite`.
The retained RVTRACE audit/coverage over those traces passes in
`logs/ci-p1-trace-audit-20260629-wpfault` with 12 tests, 45,586 retired
instructions, 14 traps, 5 AMOs, 7 PTE updates, 17 privilege switches, and 31/31
floor checks; the local retained evidence-health gate passes in
`logs/ci-evidence-health-20260629-wpfault` with 36/36 checks.
For the current `sum` increment, local directed tests, rvtests, RVTRACE structural
checks, RVTRACE reference-model checks, and cache/stage smokes pass in
`logs/ci-quick-20260629-sum/quick`, while full local `quick` still stops at
`vtop_synth` because this machine has no `verilator` or `oss-cad-suite`. The
retained RVTRACE audit/coverage over those traces passes in
`logs/ci-p1-trace-audit-20260629-sum` with 13 tests, 51,394 retired instructions,
17 traps, 5 AMOs, 9 PTE updates, 19 privilege switches, and 35/35 floor checks;
the local retained evidence-health gate passes in
`logs/ci-evidence-health-20260629-sum` with 36/36 checks.
For the current `badpte` increment, local directed tests, rvtests, RVTRACE
structural checks, RVTRACE reference-model checks, and cache/stage smokes pass in
`logs/ci-quick-20260629-badpte/quick`, while full local `quick` still stops at
`vtop_synth` because this machine has no `verilator` or `oss-cad-suite`. The
retained RVTRACE audit/coverage over those traces passes in
`logs/ci-p1-trace-audit-20260629-badpte` with 14 tests, 61,346 retired
instructions, 20 traps, 5 AMOs, 9 PTE updates, 21 privilege switches, and 38/38
floor checks; the local retained evidence-health gate passes in
`logs/ci-evidence-health-20260629-badpte` with 36/36 checks.
For the current `superpage` increment, local directed tests, rvtests, RVTRACE
structural checks, RVTRACE reference-model checks, and cache/stage smokes pass in
`logs/ci-quick-20260629-superpage/quick`, while full local `quick` still stops at
`vtop_synth` because this machine has no `verilator` or `oss-cad-suite`. The
retained RVTRACE audit/coverage over those traces passes in
`logs/ci-p1-trace-audit-20260629-superpage-v2` with 15 tests, 65,270 retired
instructions, 23 traps, 5 AMOs, 9 PTE updates, 23 privilege switches, and 41/41
floor checks; the local retained evidence-health gate passes in
`logs/ci-evidence-health-20260629-superpage-v2` with 36/36 checks.
For the current `amo_mmu` increment, local directed tests, rvtests, RVTRACE
structural checks, RVTRACE reference-model checks, and cache/stage smokes pass in
`logs/ci-quick-20260629-amo-mmu/quick`, while full local `quick` still stops at
`vtop_synth` because this machine has no `verilator` or `oss-cad-suite`. The
retained RVTRACE audit/coverage over those traces passes in
`logs/ci-p1-trace-audit-20260629-amo-mmu` with 16 tests, 71,237 retired
instructions, 25 traps, 6 AMOs, 12 PTE updates, 25 privilege switches, and 46/46
floor checks; the local retained evidence-health gate passes in
`logs/ci-evidence-health-20260629-amo-mmu` with 36/36 checks.
For the current `misalign` increment, the standalone directed run
`LOG=/tmp/tb_misalign.log bash tests/build_run.sh misalign` passes, and local
directed tests, rvtests, RVTRACE structural checks, RVTRACE reference-model
checks, and cache/stage smokes pass in `logs/ci-quick-20260629-misalign/quick`;
full local `quick` still stops only at `vtop_synth` because this machine has no
`verilator`. The retained RVTRACE audit/coverage over those traces passes in
`logs/ci-p1-trace-audit-20260629-misalign` with 17 tests, 71,682 retired
instructions, 27 traps, 6 AMOs, 12 PTE updates, 25 privilege switches, and 48/48
floor checks; the local retained evidence-health gate passes in
`logs/ci-evidence-health-20260629-misalign` with 36/36 checks. The hosted macOS
GitHub quick CI now runs both quick and
retained RVTRACE coverage audit: run `28332600873` on commit `5e39a55` completed
`quick regression` successfully, with `logs/github-quick-28332600873` reporting
quick `pass=1 fail=0`, including hosted `misalign` directed/trace/reftrace rows,
the stale TLB remap `MEM_BOUNDARY_RESULT: PASS`, and min-core
`MIN_CORE_TLB_FLUSH_RESULT: PASS` checks in `quick/cache.log`; its hosted
`vtop_synth` also builds and halts cleanly under Verilator 5.048. The
`logs/github-p1-trace-audit-28332600873` artifact reports RVTRACE coverage for
17 tests, 71,682 retired instructions, 27 traps, 6 AMOs, 12 PTE updates,
25 privilege switches, and 48/48 floor checks passing. The
migration fixed
reproducibility issues that had been hidden by local generated artifacts:
`run_rvtests.sh` now locates LLVM tools, rebuilds `soc_rt` with `SIM_INIT`, and
uses checked-in `rvtests/` plus `link.ld`; `tests/build_run.sh` compiles objects
and invokes `ld.lld` directly instead of relying on macOS clang's
`-fuse-ld=lld`; the hosted workflow installs Homebrew's split-out `lld` formula;
the synth-shell memfile fixture is checked in; `build_vtop.sh` falls back to
`sim/sim_main.cpp`; and optional `oss-cad-suite` loading no longer fails when the
directory is absent. Negative
checks for `--min-pnr-fmax-mhz 60`, `mprv:retired=6000`, `mxr:retired=6000`,
`upage:retired=10000`, `ifault:retired=10000`, `wpfault:pte_updates=3`, and
`sum:pte_updates=3`, `badpte:traps=4`, `superpage:traps=4`,
`amo_mmu:pte_updates=4`, `misalign:traps=3`, plus `--min-rvtrace-tests 18` fail
as expected. The remaining P0/P1 work is observing the first real self-hosted
scheduled/nightly green run, broader coverage beyond directed trace/ref-model tests,
populating the retained trend history from real remote CI/cron runs, and default
integration. The behavioral single-cycle path is no longer the only login path, but
it remains the historical simulation model; this is still far from the RVA23-class,
silicon-proven north star.
The local external P1 environment has also been restored as reproducible setup
steps: `tools/setup_riscof_env.sh` installs RISCOF 1.25.3,
`tools/setup_spike_env.sh` builds Spike 1.1.1-dev from `riscv-isa-sim` commit
`55b4658dbf574ba0b714083ec436ce2cb5be1998`, and `tools/p1_tool_audit.py` passes
with both on `PATH`. The full external gate passes in
`logs/p1-external-20260629-misalign`, covering the five no-trap Spike prefixes,
`mmu`, `utrap`, and the new `misalign` terminal-trap comparison (`rows=98`,
`ret=97`, `trap=1`) where Spike's first misaligned-load exception is matched
against the DUT TRAP row. This is evidence hardening, not performance work: it
adds an independent ISS check for the new trap behavior while full RVVI/complete
post-trap lockstep remains future P1 work.
The pushed source commit `eb8d405` also passed hosted macOS quick CI as run
`28333237998`: quick `pass=1 fail=0`, `verify.sh` `pass=6 fail=0`, and retained
RVTRACE audit totals of 17 tests, 71,682 retired instructions, 27 traps, 6 AMOs,
12 PTE updates, 25 privilege switches, and 48/48 floor checks.
The retained metrics path now treats P1 external as first-class health evidence:
`tools/collect_ci_metrics.py` parses `SPIKE_TRACE_PREFIX` and `P1_EXTERNAL`
summaries, `tools/render_ci_dashboard.py` records latest/trend P1 external runs,
and `tools/check_ci_dashboard.py` requires at least one retained P1 external run
with 17 tests and one terminal trap by default. A fresh `./verify_ci.sh p1` passes
in `logs/ci-p1-20260629-p1-external` with 8 external tests, 9,167 compared
retired rows, 3 compared trap rows, 9,167 Spike commits, and 1 terminal-trap
comparison; `logs/ci-evidence-health-20260629-p1-external-v2` passes 42/42
checks. Negative checks for `--min-p1-external-runs 3`,
`--min-p1-external-tests 9`, and `--min-p1-external-terminal-traps 2` fail as
expected.
The pushed source commit `8fe3078` passed hosted macOS quick CI as run
`28333520885`: quick `pass=1 fail=0`, `verify.sh` `pass=6 fail=0`, and retained
RVTRACE audit totals of 17 tests, 71,682 retired instructions, 27 traps, 6 AMOs,
12 PTE updates, 25 privilege switches, and 48/48 floor checks.
The hosted macOS workflow now also runs the external P1 Spike gate as its own
job. Source commit `1cde00e` passed run `28333671496`: the quick job again
reported quick `pass=1 fail=0` and `verify.sh` `pass=6 fail=0`; the retained
RVTRACE audit reported 17 tests, 71,682 retired instructions, 27 traps, 6 AMOs,
12 PTE updates, 25 privilege switches, and 48/48 floor checks; and the new
`P1 external Spike gate` job reported `p1` `pass=1 fail=0` with 8 external
tests, 9,167 compared retired rows, 3 compared trap rows, 9,167 Spike commits,
and 1 terminal-trap comparison. That moves the current external Spike prefix
gate from local-only evidence into hosted CI, while full RISCOF plugin/RVVI
lockstep remains future P1 work.
The local external Spike gate has now been widened beyond the initial 8-test
hosted gate: `verify_p1_external.sh` dynamically detects each newer directed
test's syscon report-store stop point, then compares Spike prefixes for `mxr`,
`upage`, `ifault`, `wpfault`, `sum`, `badpte`, `superpage`, and `amo_mmu` with
`RV32IMA_Svadu` and a 4 MB memory map. The
`logs/ci-p1-20260629-p1-external-sv32` run passes with 16 external tests,
65,219 compared retired rows, 23 compared trap rows, 77,632 Spike commits, and
1 terminal-trap comparison.
`logs/ci-evidence-health-20260629-p1-external-sv32` passes 42/42 checks with
the new default 16-test floor. Negative checks for `--min-p1-external-tests 17`
and `--min-p1-external-terminal-traps 2` fail as expected.
The pushed source commit `0447a1f` passed hosted macOS CI as run `28334099355`:
quick `pass=1 fail=0`, `verify.sh` `pass=6 fail=0`, retained RVTRACE audit
totals of 17 tests, 71,682 retired instructions, 27 traps, 6 AMOs, 12 PTE
updates, 25 privilege switches, and 48/48 floor checks, plus the hosted
`P1 external Spike gate` summary with 16 external tests, 65,219 compared retired
rows, 23 compared trap rows, 77,632 Spike commits, and 1 terminal-trap
comparison.
The remaining `mprv` directed test is now Spike-comparable too: `tests/mprv.c`
sets `menvcfgh.ADUE` before enabling `satp`, matching the other Sv32 permission
tests and Spike/Svadu's hardware A/D update mode. `verify_p1_external.sh` now
includes `mprv` in the dynamic syscon-stop SV32 prefix set, and
`tools/check_ci_dashboard.py` raises the default P1 external floor to all 17
directed tests. `logs/ci-p1-20260629-p1-external-mprv-v2` passes with 17
external tests, 70,670 compared retired rows, 24 compared trap rows, 85,628
Spike commits, and 1 terminal-trap comparison. `logs/ci-evidence-health-20260629-p1-external-mprv-v2`
passes 42/42 checks; negative checks for `--min-p1-external-tests 18` and
`--min-p1-external-terminal-traps 2` fail as expected. A local quick run also
passes directed, rvtests, RVTRACE structural/ref-model, and cache checks for the
ADUE-updated `mprv`; its only failure is the known local `vtop_synth`
environment gap (`verilator` missing), which hosted CI covers.
The pushed source commit `61c50d0` passed hosted macOS CI as run `28334435648`:
quick `pass=1 fail=0`, `verify.sh` `pass=6 fail=0`, retained RVTRACE audit
totals of 17 tests, 71,683 retired instructions, 27 traps, 6 AMOs, 12 PTE
updates, 25 privilege switches, and 48/48 floor checks, plus the hosted
`P1 external Spike gate` summary with all 17 external tests, 70,670 compared
retired rows, 24 compared trap rows, 85,628 Spike commits, and 1 terminal-trap
comparison.
The external Spike prefix gate now also compares non-terminal DUT `TRAP` rows
against Spike's logged exception `pc`/`cause`/`tval` and `instr` when Spike
reports the faulting instruction. The fresh local `logs/ci-p1-20260629-trap-exceptions`
run passes with the same 17 external tests, 70,670 compared retired rows, 24
compared trap rows, 23 ordinary trap-exception checks, 85,628 Spike commits, and
1 terminal-trap comparison. `logs/ci-evidence-health-20260629-trap-exceptions`
passes 43/43 checks under the new default 23-trap-exception floor; a negative
`--min-p1-external-trap-exceptions 24` check fails as expected.
The pushed source commit `762922a` passed hosted macOS CI as run `28334858340`:
quick `pass=1 fail=0`, `verify.sh` `pass=6 fail=0`, retained RVTRACE audit
totals of 17 tests, 71,683 retired instructions, 27 traps, 6 AMOs, 12 PTE
updates, 25 privilege switches, and 48/48 floor checks, plus the hosted
`P1 external Spike gate` summary with all 17 external tests, 70,670 compared
retired rows, 24 compared trap rows, 23 non-terminal trap-exception checks,
85,628 Spike commits, and 1 terminal-trap comparison.
The current upstream architectural-test path is now explicit too: RISCOF 1.25.3
does not discover the newer ACT4 `START_TEST_CONFIG`/`MARCH` test metadata in
the current `riscv-arch-test` tree, so the repo carries a narrower ACT/Spike
smoke instead of claiming full RISCOF/ACT4 certification. `tools/setup_riscof_env.sh`
pins `riscv-arch-test` to commit
`c6c69dc33414101c7ea94bf4fbea40885f9447ce` and installs the ACT4 Python
framework/testgen/coverage packages into `.p1/riscof-venv`;
`p1/act4/ember-rv32i/` provides the DUT link script and `rvmodel` macros; and
`tools/run_act4_spike_smoke.sh` compiles upstream ACT4 RV32I tests, generates
expected signatures with Spike, rebuilds them in `RVTEST_SELFCHECK` mode, and
runs the resulting ELFs on the Ember RTL testbench. `logs/ci-p1-20260629-act4-spike`
passes the existing 17-test Spike-prefix gate plus the initial 6/6 ACT/Spike
smoke subset (`I-add`, `I-addi`, `I-lw`, `I-sw`, `I-beq`, `I-jalr`). A follow-up
local run `logs/p1-act4-spike-all-rv32i` passes all 39 pinned upstream RV32I-I
ACT/Spike tests, and the retained evidence floor is raised from 6 to 39.
`logs/ci-p1-20260629-act4-spike-39` passes the widened P1 profile with the same
17-test Spike-prefix gate (`ret=70670`, `trap_exceptions=23`,
`terminal_traps=1`) plus 39/39 ACT/Spike tests. `logs/ci-evidence-health-20260629-act4-spike-39`
passes 47/47 checks under the new 39-test ACT/Spike floor, and a negative
`--min-p1-act4-spike-tests 40` check fails against the retained value of 39.
Full ACT4/UDB generation and certification remain future work; the local system
Ruby is still 2.6, while upstream UDB currently wants Ruby 3.2+, so that path is
not part of this smoke.
The pushed source commit `394657a` then passed hosted macOS CI as run
`28335561543`: quick `pass=1 fail=0`, retained RVTRACE audit still reports 17
tests, 71,683 retired instructions, 27 traps, 6 AMOs, 12 PTE updates, 25
privilege switches, and 48/48 floor checks, and the hosted P1 external summary
now includes both the 17-test Spike-prefix gate (`ret=70670`,
`trap_exceptions=23`, `terminal_traps=1`) and 6/6 ACT/Spike smoke tests.
The pushed source commit `ad11d07` passed hosted macOS CI as run `28336035414`:
quick `pass=1 fail=0`, retained RVTRACE audit remains green, and the hosted P1
external artifact records the same 17-test Spike-prefix gate plus 39/39
ACT/Spike RV32I-I smoke tests.
The local ACT/Spike smoke default has now been widened across the implemented
RV32 IMAC-facing architectural groups that pass against Spike: `I`, `M`,
`Zaamo`, `Zalrsc`, `Zca`, and `Zifencei`. `tools/run_act4_spike_smoke.sh`
now discovers tests by group, reads each source file's `MARCH` metadata for GCC
and Spike, and defaults to a 1.5M-cycle DUT cap. A standalone run in
`logs/p1-act4-spike-imac-zifencei-default` passes 85/85 tests. The full local
P1 profile in `logs/ci-p1-20260629-act4-spike-85` also passes with the same
17-test Spike-prefix gate (`ret=70670`, `trap_exceptions=23`,
`terminal_traps=1`) plus 85/85 ACT/Spike smoke tests. Evidence-health is raised
to the 85-test ACT/Spike floor and passes 47/47 checks in
`logs/ci-evidence-health-20260629-act4-spike-85`; a negative
`--min-p1-act4-spike-tests 86` check fails against the retained value of 85.
The upstream `Zicsr` ACT group is deliberately kept out of the default smoke for
now because its no-`C` MARCH metadata exposed a `mepc`/`sepc` WARL low-bit
expectation mismatch with Ember's compressed-instruction decode path; that is a
separate correctness item rather than a coverage count to hide.
The pushed source commit `16f0b80` passed hosted macOS CI as run
`28336556293`: quick `pass=1 fail=0`, retained RVTRACE audit remains green, and
the hosted P1 external artifact `logs/github-p1-external-28336556293` records
the same 17-test Spike-prefix gate (`ret=70670`, `trap_exceptions=23`,
`terminal_traps=1`) plus 85/85 ACT/Spike smoke tests.
The `Zicsr` ACT mismatch is now converted from a documented exclusion into a
passing external smoke case. `rvlinux.v`, `rtl/cores/rvlinux.v`, and
`rvlinux_csr_trap_stage.v` now advertise `misa.C` and mask only `mepc[0]` /
`sepc[0]` on CSR writes; `tools/rvtrace_ref.py` mirrors the same `misa` and EPC
WARL behavior; and `tb_rvlinux_csr_trap_stage.v` checks both `mepc=0x123 ->
0x122` and `sepc=0x303 -> 0x302`. `tools/run_act4_spike_smoke.sh` includes
`Zicsr` in the default group list and runs that group against the C-aware
`rv32i_zicsr_zifencei_zca` Spike ISA. Local evidence: the CSR stage test passes,
`logs/p1-act4-spike-zicsr-caware` passes 6/6 `Zicsr` tests,
`logs/p1-act4-spike-imac-zicsr-default` passes 91/91 default ACT/Spike tests,
and `logs/ci-p1-20260629-epc-zicsr-91` passes the full P1 profile with the same
17-test Spike-prefix gate (`ret=70670`, `trap_exceptions=23`,
`terminal_traps=1`) plus 91/91 ACT/Spike tests. Evidence-health is raised to the
91-test ACT/Spike floor and passes 47/47 checks in
`logs/ci-evidence-health-20260629-epc-zicsr-91`; a negative
`--min-p1-act4-spike-tests 92` check fails against the retained value of 91.
The local quick profile's code-related stages (`directed`, `rvtests`, `trace`,
`reftrace`, and `cache`) pass, but the full local quick run stops at `vtop_synth`
because this host currently lacks `verilator`; hosted macOS CI is expected to
cover that after push.
The pushed source commit `f7d794e` passed hosted macOS CI as run `28337247599`:
quick `pass=1 fail=0`, retained RVTRACE audit remains green, and the hosted P1
external artifact `logs/github-p1-external-28337247599` records the same
17-test Spike-prefix gate (`ret=70670`, `trap_exceptions=23`,
`terminal_traps=1`) plus 91/91 ACT/Spike smoke tests.
The default ACT/Spike smoke is now expanded again to 106 pinned upstream RV32
tests by adding `Zmmul`, `Zicntr`, `Zihintpause`, `Zihintntl`, and
`ZihintntlZca` to the existing `I`, `M`, `Zaamo`, `Zalrsc`, `Zca`, `Zicsr`, and
`Zifencei` set. Candidate evidence `logs/p1-act4-spike-candidates-20260629`
passes those 15 newly added tests, while `logs/p1-act4-spike-zihpm-negative-20260629`
confirms `Zihpm` remains excluded because the HPM counter CSR bank is not
implemented. The new default run `logs/p1-act4-spike-expanded-default-20260629`
passes 106/106; full local P1 `logs/ci-p1-20260629-act4-spike-106` passes with
17 Spike-prefix tests (`ret=70670`, `trap_exceptions=23`, `terminal_traps=1`)
plus 106/106 ACT/Spike tests; evidence-health passes in
`logs/ci-evidence-health-20260629-act4-spike-106`; and the negative
`--min-p1-act4-spike-tests 107` check fails against the retained value of 106.
The pushed source commit `5e70ce0` passed hosted macOS CI as run `28337807540`:
quick `pass=1 fail=0`; hosted P1 external `logs/github-p1-external-28337807540`
records the same 17-test Spike-prefix gate (`ret=70670`,
`trap_exceptions=23`, `terminal_traps=1`) plus 106/106 ACT/Spike smoke tests.
The ACT/Spike evidence path now records selected group composition, not just the
106-test total: `tools/run_act4_spike_smoke.sh` emits `P1_ACT4_SPIKE_GROUPS`,
`tools/collect_ci_metrics.py` and `tools/render_ci_dashboard.py` retain it, and
`tools/check_ci_dashboard.py` requires the exact 12-group default composition by
default. Local evidence `logs/ci-p1-20260629-act4-groups` passes with 17
Spike-prefix tests plus 106/106 ACT/Spike tests and the expected group CSV;
`logs/ci-evidence-health-20260629-act4-groups` passes the refreshed 48-check
health gate; the pre-refresh dashboard check fails on missing groups; and an
intentionally shortened `--require-p1-act4-spike-groups` list fails against the
retained CSV. The pushed source commit `9227152` passed hosted macOS CI as run
`28338350815`: quick `pass=1 fail=0`, and hosted P1 external
`logs/github-p1-external-28338350815` records 17 Spike-prefix tests
(`ret=70670`, `trap_exceptions=23`, `terminal_traps=1`) plus 106/106
ACT/Spike tests with `group_count=12` and the expected group CSV.
`logs/p1-act4-spike-misalign-candidates-20260629` records the
negative `Misalign`/`MisalignZca` ACT result: those groups require
`MISALIGNED_LDST: true` successful non-aligned load/store behavior, while Ember
currently implements precise misaligned-access traps.
The retained P0 Linux evidence path now also records the boot-to-login cycle
point as structured data: `verify_p0_linux.sh` emits `P0_LINUX_BOOT`, the
metrics/dashboard/trend pipeline retains `cycles=8716611501` for
`logs/ci-p0-evidence-20260629-boot-cycles`, and
`logs/ci-evidence-health-20260629-p0-boot-cycles` passes 52/52 checks with the
new default `--max-p0-linux-login-cycles 9000000000` guard. A negative check at
8,000,000,000 cycles fails as expected against the retained 8,716,611,501-cycle
login evidence.
The pushed source commit `f06b828` passed hosted macOS CI as run `28338812276`:
quick `pass=1 fail=0`, and hosted P1 external
`logs/github-p1-external-28338812276` still records 17 Spike-prefix tests
(`ret=70670`, `trap_exceptions=23`, `terminal_traps=1`) plus 106/106
ACT/Spike tests with `group_count=12` and the expected group CSV.
The retained P1 external evidence path now also records and checks the exact
Spike-prefix test-name list, not just the 17-test count:
`isa,amotest,ctest,shtest,mtest,mmu,utrap,misalign,mprv,mxr,upage,ifault,wpfault,sum,badpte,superpage,amo_mmu`.
`tools/collect_ci_metrics.py` emits this list in `summary.md`, and
`tools/check_ci_dashboard.py` requires it by default. Local
`logs/ci-evidence-health-20260629-p1-test-list` passes the refreshed 53-check
health gate; an intentionally shortened `--require-p1-external-tests` list fails
against the retained CSV, proving the gate catches silent P1 test-set shrinkage.
The pushed source commit `d1acc71` passed hosted macOS CI as run `28339094468`:
quick `pass=1 fail=0`, and hosted P1 external
`logs/github-p1-external-28339094468` records the exact 17-test Spike-prefix list
(`isa,amotest,ctest,shtest,mtest,mmu,utrap,misalign,mprv,mxr,upage,ifault,wpfault,sum,badpte,superpage,amo_mmu`)
with `ret=70670`, `trap_exceptions=23`, and `terminal_traps=1`, plus 106/106
ACT/Spike tests with `group_count=12` and the expected group CSV.
The dashboard/trend layer now exposes that same P1 external test list directly:
`logs/ci-dashboard.md` and `logs/ci-trend.md` print the latest CSV, and
`tools/check_ci_dashboard.py` checks the list from the latest summary, dashboard
top-level JSON, and history trend JSON. Local
`logs/ci-evidence-health-20260629-p1-dashboard-tests` passes the refreshed
55-check health gate; a shortened `--require-p1-external-tests` list now fails in
all three places, proving the retained dashboard/history cannot silently drop the
`amo_mmu` test either.
The pushed source commit `fe7b580` passed hosted macOS CI as run `28339355694`:
quick `pass=1 fail=0`, and hosted P1 external
`logs/github-p1-external-28339355694` records the same exact 17-test list in
`summary.json`, `ci-dashboard.json`, `ci-dashboard.md`, and `ci-trend.md`, with
`ret=70670`, `trap_exceptions=23`, `terminal_traps=1`, and 106/106 ACT/Spike
tests across the expected 12 groups.
The P1 external health gate now also checks per-test floors over the retained
Spike-prefix evidence: base no-trap tests retain minimum retired rows, Sv32
permission tests retain their expected trap/trap-exception counts, and `misalign`
is required to remain the terminal-trap test. Local
`logs/ci-evidence-health-20260629-p1-per-test-floors` passes 94/94 checks, and a
negative `--require-p1-external-test-floors amo_mmu:ret=6000` check fails against
the retained `amo_mmu` value of 5,965 retired rows.
The pushed source commit `436c619` passed hosted macOS CI as run `28339606080`:
quick `pass=1 fail=0`, and hosted P1 external
`logs/github-p1-external-28339606080` retains the same 17-test Spike-prefix set
with `ret=70670`, `trap_exceptions=23`, `terminal_traps=1`, `misalign`
terminal-trap coverage, `amo_mmu` at 5,965 retired rows / 2 trap exceptions, and
106/106 ACT/Spike tests across the expected 12 groups.
The ACT/Spike evidence path now also retains exact selected test counts per
extension group: `I=39,M=8,Zmmul=4,Zaamo=9,Zalrsc=2,Zca=26,Zicsr=6,Zicntr=2,Zifencei=1,Zihintpause=1,Zihintntl=4,ZihintntlZca=4`.
`tools/run_act4_spike_smoke.sh` emits `P1_ACT4_SPIKE_GROUP_COUNTS`,
`tools/collect_ci_metrics.py` can also infer those counts from existing
`ACT4_SPIKE_TEST` lines, and dashboard/history retain the resulting
`group_tests`. `tools/check_ci_dashboard.py` also resolves hosted artifact
summaries by scanning the dashboard root for a matching internal `logdir`, so
nested GitHub downloads remain checkable after they leave the recent-run table.
Local `logs/ci-evidence-health-20260629-act4-group-counts-v2` passes 95/95
checks; a negative `--require-p1-act4-spike-group-counts` with `Zca=25` fails
against the retained `Zca=26` count.
The same ACT/Spike evidence chain now retains and checks the exact selected
106-test list as `test_names`, not only total/group/group-count coverage.
`tools/run_act4_spike_smoke.sh` emits `P1_ACT4_SPIKE_TESTS`,
`tools/collect_ci_metrics.py` can also infer the list from retained
`ACT4_SPIKE_TEST` lines, and `tools/render_ci_dashboard.py` preserves the list in
dashboard top-level JSON and history trend data. Local
`logs/ci-evidence-health-20260629-act4-test-list` passes 98/98 checks; an
intentionally equal-length `--require-p1-act4-spike-test-list` with the final
`ZihintntlZca` test name replaced fails in the latest summary, dashboard, and
history checks.
Hosted CI run `28339985935` for source commit `b55bf85` passed with quick
regression in 1m37s and P1 external in 8m49s. Downloaded artifact
`github-p1-external-28339985935/summary.json` is `status=pass`, retains the same
17-test P1 external set with `ret=70670`, `trap_exceptions=23`,
`terminal_traps=1`, and records ACT/Spike `group_tests` exactly as
`I=39,M=8,Zmmul=4,Zaamo=9,Zalrsc=2,Zca=26,Zicsr=6,Zicntr=2,Zifencei=1,Zihintpause=1,Zihintntl=4,ZihintntlZca=4`.
Hosted CI run `28340424330` for source commit `735c01f` passed with quick
regression in 1m52s and P1 external in 10m46s. Its downloaded
`github-p1-external-28340424330/summary.json` is `status=pass`, keeps the same
17-test P1 external set with `ret=70670`, `trap_exceptions=23`,
`terminal_traps=1`, records ACT/Spike 106/106 across the expected 12 groups, and
retains `test_names_count=106` with first tests
`I/I-add-00,I/I-addi-00,I/I-and-00` and final tests
`ZihintntlZca/ZihintntlZca-c.ntl.p1-00,ZihintntlZca/ZihintntlZca-c.ntl.pall-00,ZihintntlZca/ZihintntlZca-c.ntl.s1-00`.
The RVTRACE coverage evidence chain now also retains the exact 17-test directed
coverage list, not only aggregate counts/floors. `tools/render_ci_dashboard.py`
publishes `latest_rvtrace_coverage_tests` in the dashboard and
`history.rvtrace_coverage.latest_tests` in the trend summary, while
`tools/check_ci_dashboard.py` defaults
`--require-rvtrace-coverage-tests` to
`isa,amotest,mmu,ctest,shtest,mtest,misalign,utrap,mprv,mxr,upage,ifault,wpfault,sum,badpte,superpage,amo_mmu`
and checks the latest summary, dashboard, and history copies. Local
`logs/ci-evidence-health-20260629-rvtrace-test-list` passes 101/101 checks; a
negative list with `amo_mmu` replaced by `BAD` fails the three RVTRACE coverage
list checks. The refreshed dashboard now scans 84 summaries, retains 84 history
runs, and has a 15-run pass streak.
Hosted CI run `28340935386` for source commit `fdd2e05` passed with quick
regression in 1m59s and P1 external in 3m39s. Its downloaded quick artifact
`quick-logs-28340935386` includes `logs/github-p1-trace-audit-28340935386` with
the exact RVTRACE coverage list above, 48/48 floor checks, and totals of 17
tests, 71,683 retired instructions, 27 traps, 6 AMOs, 12 PTE updates, and 25
privilege switches; the artifact `ci-dashboard.json` exposes the same list as
`latest_rvtrace_coverage_tests` and
`history.rvtrace_coverage.latest_tests`, and a local RVTRACE-only
`tools/check_ci_dashboard.py` pass over the downloaded dashboard reports 29/29
checks. The downloaded P1 artifact `p1-external-logs-28340935386` remains green
with the same 17 Spike-prefix tests (`ret=70670`, `trap_exceptions=23`,
`terminal_traps=1`) plus ACT/Spike 106/106 across 12 groups.
The hosted artifact import path is now scripted instead of ad hoc:
`python3 tools/import_github_run_artifacts.py 28340935386` imported the same
hosted run into `logs/github-run-28340935386`, recorded manifest metadata
(`repo=L0stInFades/ember`, `headSha=fdd2e05e19b942b7ac2a18c85bbcaa1e65044d27`,
`artifacts=2`, `summary_json_count=3`), and refreshed the dashboard to 87/87
runs with the latest quick, P1 external, and RVTRACE evidence all pointing at
that hosted run. A default `tools/check_ci_dashboard.py` pass over the refreshed
retained evidence reports 101/101 checks. The formal
`logs/ci-evidence-health-20260629-github-import` run then passes 101/101 checks
and refreshes the dashboard to 88 summaries, 88 history records, and a 19-run
pass streak.
The source commit `b6bd08e` that added that importer passed hosted CI as run
`28341253692`: quick regression completed in 1m24s and P1 external completed in
2m50s. Running the committed importer on its own hosted run,
`python3 tools/import_github_run_artifacts.py 28341253692`, downloads 2 artifacts
and 3 summaries into `logs/github-run-28341253692`, records manifest metadata
for head SHA `b6bd08ed69b67a0eac49acdacc3a3ded6f2f1434`, and refreshes the
dashboard to 91/91 with latest quick, P1 external, and RVTRACE evidence all
coming from run `28341253692`. The default evidence-health checker then passes
101/101 over that imported evidence, and the formal
`logs/ci-evidence-health-20260629-github-import-self` profile passes 101/101 and
refreshes the dashboard to 92 summaries, 92 history records, and a 23-run pass
streak.
The imported-hosted-evidence gate is now part of `evidence-health`, not just a
documented workflow. `tools/render_ci_dashboard.py` publishes `github_import_runs`,
`github_imports`, and `latest_github_import` from retained
`github_run_import.json` manifests, and `tools/check_ci_dashboard.py` now requires
at least one successful import with at least 2 artifacts and 3 summaries by
default. The refreshed default checker passes 106/106 checks; a negative
`--min-github-import-summaries 4` fails on the latest manifest's
`summary_json_count=3`. The formal
`logs/ci-evidence-health-20260629-github-import-manifest` profile passes 106/106
and refreshes the dashboard to 93 summaries, 93 history records, and a 24-run
pass streak.
The source commit `f4240c6` that made imported GitHub manifests a default health
gate passed hosted CI as run `28341494649`: quick regression completed in 1m26s
and P1 external completed in 3m1s. Running the committed importer on that same
hosted run, `python3 tools/import_github_run_artifacts.py 28341494649`, imports
2 artifacts and 3 summaries into `logs/github-run-28341494649`, records head SHA
`f4240c64cef12c503044571dfc7f5eeffbf34c2c`, and refreshes the dashboard to
96/96 with latest quick, P1 external, and RVTRACE evidence all coming from run
`28341494649`. The default evidence-health checker passes 106/106 over that
imported evidence with a 27-run pass streak, and the formal
`logs/ci-evidence-health-20260629-github-import-manifest-self` profile passes
106/106 and refreshes the dashboard to 97 summaries, 97 history records, and a
28-run pass streak.
The imported-hosted-evidence gate now also proves each imported GitHub run's own
dashboard evidence can be resolved, not just that a successful import exists:
`tools/check_ci_dashboard.py` checks the expected quick, P1 external, RVTRACE,
and RVTRACE coverage logdirs for run `28341494649`, and checks that their resolved
`summary.json` sources live under `logs/github-run-28341494649`. The refreshed
default checker passes 117/117 checks. The formal
`logs/ci-evidence-health-20260629-github-import-binding` profile passes 117/117
and refreshes the dashboard to 98 summaries, 98 history records, and a 29-run
pass streak.
The source commit `838e27b` that added those binding checks passed hosted CI as
run `28341807002`: quick regression completed in 1m48s and P1 external completed
in 3m22s. Running `python3 tools/import_github_run_artifacts.py 28341807002`
imports 2 artifacts and 3 summaries into `logs/github-run-28341807002`, records
head SHA `838e27bdebccacb3659fd7af57048744dcba7150`, and refreshes the dashboard
to 101/101 with latest quick, P1 external, RVTRACE, and RVTRACE coverage evidence
all coming from run `28341807002`. The default evidence-health checker passes
117/117 over that self-imported evidence with a 32-run pass streak, and the formal
`logs/ci-evidence-health-20260629-github-import-binding-self` profile passes
117/117 and refreshes the dashboard to 102 summaries, 102 history records, and a
33-run pass streak.
The SV32 Spike-prefix gate now makes clean device completion explicit.
`tools/spike_trace_prefix.py --expect-device-complete` verifies that the compared
prefix stops immediately before an M-mode syscon poweroff store, with the prior
rows loading pass code `0x5555` and syscon base `0x11100000`; `verify_p1_external.sh`
enables that check for `mprv`, `mxr`, `upage`, `ifault`, `wpfault`, `sum`,
`badpte`, `superpage`, and `amo_mmu`. `tools/collect_ci_metrics.py` and
`tools/render_ci_dashboard.py` retain `device_complete` per test and
`device_completions` in the P1 external summary, while `tools/check_ci_dashboard.py`
now requires 9 device completions by default plus per-test `device_complete=1`
floors. Local positive evidence:
`logs/ci-p1-20260629-device-complete` passes the full P1 profile with 17 external
tests, 70,670 compared retired rows, 23 trap-exception checks, one terminal trap,
and 9 device completions. Negative checks
`--min-p1-external-device-completions 10` and
`--require-p1-external-test-floors mxr:device_complete=2` fail as expected. The
formal `logs/ci-evidence-health-20260629-device-complete` profile passes 125/125
and refreshes the dashboard to 104 summaries, 104 history records, and a 35-run
pass streak.

---

## 3. The roadmap (phased, measurable, continuous)

Each phase has a hard **Definition of Done (DoD)**. Do not claim a phase until its
DoD is green in CI. Phases are roughly sequential but P1 (verification) runs
*forever* in parallel from the moment it starts.

> **Current strategy: physical hardware is deliberately deferred.** The main line is
> **simulation + tool synthesis** on macOS (Verilator for behavior, yosys+nextpnr for
> real area/Fmax). The FPGA board is an *optional* track (see "Optional - Hardware
> bring-up" after P0) that can be picked up anytime, because the RTL is kept
> FPGA-ready and timing-closed in the tool. Priority order right now:
> **P0 (make it synthesizable) + P1 (verification), both 100% on the Mac.**

### P0 - Make it synthesizable (simulation + tool synthesis, no board required)
Turn the *simulation* Linux core into real, mappable hardware - verified in
simulation and pushed through yosys+nextpnr for an honest area/Fmax. **No physical
board needed** (see the optional "Hardware bring-up" track below).

- Replace behavioral `imem/dmem` with a real **multi-cycle memory interface**
  (req/valid + stall), backed by inferable **block RAM** for synthesis.
- Make the datapath **stall** on memory; make the PTW a **sequential FSM** that
  issues real memory reads per level, not a combinational walk.
- Integrate `rtl/cache/cache.v` as a real **L1** (I$/D$) behind fetch + LSU, over a
  `rtl/cache/slowmem.v`-style multi-cycle backing memory.
- Push the whole core through **yosys + nextpnr-ecp5** (already on our Mac) and read
  off real **area + Fmax**; optionally simulate the post-PnR netlist.
- **DoD:** the *entire* core+SoC is synthesizable (no behavioral RAM, no combinational
  PTW); nextpnr **closes timing on an ECP5-85F** with a reported Fmax (realistically
  ~40-75 MHz); **all directed tests pass and Linux still boots in Verilator** with the
  new memory hierarchy; `cpu_ooo.v` is either retired or refactored enough to PnR.

#### Optional - Hardware bring-up (deferred; pick up anytime for "silicon proof")
Not on the critical path. When we want the on-hardware credibility, the RTL is already
FPGA-ready, so this becomes a thin integration step. On our **Intel Mac, macOS**, use
the **open flow** (`oss-cad-suite`: yosys + nextpnr + `openFPGALoader`/`fujprog`/
`ecpprog`/`openocd`, all installed) targeting **Lattice ECP5 / Gowin** boards;
Xilinx/Intel (Vivado/Quartus) only run in a Linux x86 VM/Docker, so they are a
fallback. DRAM + SoC glue from **LiteX** (LiteDRAM + ready targets). Recommended board:
**ULX3S (ECP5-85F, 32 MB SDRAM)**, flashed by the `fujprog` we already have; **ECPIX-5
/ OrangeCrab 85F** (DDR3) for more memory; **Tang Primer 20K/25K** (Gowin) as a cheap
alt. **DoD:** boots the image from DRAM on real silicon to the shell.

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
| Fmax | ~68 MHz (ECP5, `cpu_pipe`) | ~40-75 MHz on ECP5-85F (open flow) | >1 GHz / ~2 GHz-class ASIC |
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
3. Push the refactored core through **yosys + nextpnr-ecp5** on the Mac for honest
   **area + Fmax** (no board); keep it timing-closed as features land.
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

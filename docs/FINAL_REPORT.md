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
`bash verify.sh` is the current one-command regression gate. It runs:
- directed SoC tests: `isa`, `amotest`, `mmu`, `ctest` (RVC), `shtest`,
  `mtest` (M-ext), `utrap` (S->U `sret` + U-mode `ecall`), `mprv`
  (MPRV+SUM data permission), `mxr` (Sv32 MXR execute-only load permission),
  `upage` (U-mode Sv32 fetch/data plus U->S fault delegation), and `ifault`
  (delegated Sv32 instruction page fault)
- the local `rv32ui` + `rv32um` riscv-tests subset (46 tests)
- cache correctness/perf, cache-backing-memory arbiter tests, sequential PTW/L1
  coherency tests, and the new `rvlinux_mem_boundary.v` plus decode,
  CSR/trap, fetch/LSU/AMO/muldiv/MMIO multi-cycle stage, shared-cluster, and
  minimal multicycle core FSM tests, including core-level UART/syscon MMIO,
  real `EBREAK` trap routing, delegated UART/PLIC external-interrupt paths,
  and top-level STIP delivery
- an `RVTRACE` gate over all directed SoC tests that emits and checks a DUT-side CSV
  retire/trap stream
  (`event,cycle,pc,instr,priv,rd,wdata,next_pc,cause,tval`) against the test image for
  trace shape, cycle monotonicity, PC/instruction consistency, privilege values, and
  writeback basics.
- an RV32IMA+privileged/Sv32 reference-trace compare for all directed SoC tests:
  `isa`, `amotest`, `mmu`, `ctest`, `shtest`, `mtest`, `utrap`, `mprv`, `mxr`,
  `upage`, and `ifault`. This replays
  the same hex image in `tools/rvtrace_ref.py`
  and compares each `RET`/`TRAP` row's `event`, `pc`, `instr`, `priv`, `rd`,
  `wdata`, `next_pc`, `cause`, and `tval`. The `utrap` path covers the minimal
  CSR/trap-return flow (`mret`, `sret`, U-mode `ecall`); the `mmu` path covers the
  directed Sv32 translation case, hardware A/D PTE update, and delegated page
  faults; `mprv`, `mxr`, `upage`, and `ifault` cover MPRV data-privilege, MXR
  permission, U-page fetch/data/trap-delegation, and instruction page-fault edges.

External P1 verification bring-up has a strict tool gate separate from the default
regression:
- `tools/setup_riscof_env.sh` creates `.p1/riscof-venv`, installs RISCOF, and
  clones `riscv-arch-test` into `.p1/riscv-arch-test`.
- `verify_p1_external.sh` checks the host/RISCOF/difftest/DUT-simulation
  toolchain (`riscof`, RISC-V GCC/binutils, LLVM/iverilog/vvp, and `spike`) and
  automatically searches local `.p1/spike/bin` when present.
- Current local audit passes with RISCOF 1.25.3, Homebrew `riscv64-elf-gcc`
  16.1.0/binutils 2.46.1, and a locally built Spike 1.1.1-dev under `.p1/spike`.
- The same external gate now runs Spike commit-log prefix comparison for the five
  no-trap directed tests: `isa`, `amotest`, `ctest`, `shtest`, and `mtest`. For
  each test it builds a DUT RVTRACE run, runs the matching ELF under Spike, drops
  Spike's `0x1000` boot-stub commits, and compares all committed rows up to the
  shared syscon-pass boundary (`pc=0x80000048`). Current compared row counts are
  623, 474, 2146, 245, and 238 respectively.
- The external gate also covers the `mmu` directed test with Spike `Svadu`
  enabled and trap-boundary alignment. It compares 5295 committed `RET` rows plus
  2 delegated page-fault `TRAP` boundaries through the S-mode handler and stops
  before the final S-mode `ecall` (`pc=0x80001e58` in the current build), where
  raw Spike no longer emits a comparable handler commit stream.
- The `utrap` directed test is now covered up to its U-mode `ecall`: 49 committed
  `RET` rows spanning M-mode setup, `mret` into S-mode, `sret` into U-mode, and
  the U-mode store before `pc=0x8000007c`.
- This is a Spike prefix gate, not full RVVI. RISCOF DUT/reference plugins,
  complete Spike comparison after the final `mmu`/`utrap` `ecall` trap,
  device-complete comparison, and full Spike/RVVI lockstep over all directed tests
  are still the next implementation step. The local `tools/rvtrace_ref.py` path
  still covers full `mmu`/`utrap` today.
- `run_rvtests.sh` now executes the compiled `./soc_rt` vvp script through its own
  shebang instead of whichever `vvp` appears first in `PATH`; this avoids false
  rvtests failures when the OSS CAD Suite Icarus runtime is sourced over a test
  image compiled by Homebrew Icarus 13.

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

## Cache / memory boundary (stretch goal): `cache.v` + `slowmem.v` + `mem_arbiter2.v` + `l1_mem_system.v`
Direct-mapped, **write-back, write-allocate**, parameterized lines/words, single-cycle
hit, miss stalls the requester while it (optionally writes back the dirty victim and)
refills from a multi-cycle word-wide memory. `RO=1` gives an instruction cache.
`slowmem.v` now latches each accepted request and waits for the requester to drop
`req` after `ack`, so one held request cannot be accepted twice.

Verified (`CACHE_RESULT: PASS`): cold-fill reads return backing data, re-reads hit,
write/read-back, and **write-back-on-eviction** (a dirty line evicted then re-fetched
returns the written value, proving the flush path).

`mem_arbiter2.v` is a synthesizable two-client arbiter for sharing one word-wide
backing memory between future I$/D$ instances. Its regression (`ARB_RESULT: PASS`)
covers simultaneous I/D reads, D-side writes becoming visible to I-side reads, and
interleaved I-read/D-write traffic against `slowmem.v`. `yosys synth_mem_arbiter.ys`
maps it to 156 LUT4 + 202 FF on ECP5 before place-and-route.

`l1_mem_system.v` now composes two real L1 instances (`RO=1` I$, write-back D$), the
two-client arbiter, and a `slowmem.v` backing RAM into the split CPU-side boundary the
multi-cycle `rvlinux` core will need. Its regression (`L1MEM_RESULT: PASS`) covers
I-cache hits/misses, D-cache writes with byte enables, I$/D$ concurrent traffic, and
D-cache dirty eviction becoming visible to a later I-cache miss through backing memory.
The D$ CPU-side port is now shared by LSU and PTW through `cache_client_arbiter2.v`,
so page-table walks see dirty PTEs resident in D$ instead of bypassing to stale backing
memory. `yosys synth_l1_mem_system.ys` maps the combined subsystem to 33 DP16KD block
RAMs, 2453 LUT4, 1017 FF, and 408 TRELLIS_DPR16X4 on ECP5.

For place-and-route, `syn_top_l1_mem_system.v` wraps the L1 subsystem with registered,
small-width IO so nextpnr measures the block without exhausting package pins. On
LFE5U-45F/CABGA381, `nextpnr-ecp5 --freq 50` passes with a routed clock Fmax of
67.44 MHz; utilisation is 34/108 DP16KD (31%), 1114 FF, and about 4660 total LUT4s.

Measured on a 128-word array reused 8x (1 KB cache, 8-cycle memory):
- hit rate **98.5 %** (1009 hits / 38 misses of 1024 accesses)
- backing-memory traffic **7.7x lower** (132 vs 1024 word transfers)
- AMAT **2.32 vs 9.00 cyc/access -> 3.87x faster**

## Sequential Sv32 PTW building block: `sv32_ptw.v`
`sv32_ptw.v` is a synthesizable FSM version of the current `rvlinux.v` combinational
Sv32 page-table walk. It issues one real word-read request per PTE level over the same
req/ack memory interface, returns `pa`/`fault`/`cause`, and exposes the leaf PTE plus
`set_a`/`set_d` so the core can perform the existing A/D writeback policy later.

Verified (`PTW_RESULT: PASS`): bare/M-mode no-walk path, two-level S-mode fetch,
S-mode store with A/D update request, SUM+MXR load from a user execute-only page,
permission faults, invalid-PTE instruction fault, and exact read accounting
(`ptw reads=12`). `yosys synth_sv32_ptw.ys` maps the walker to 388 LUT4 + 226 FF on
ECP5.

Verified with the L1 subsystem (`PTW_DCACHE_RESULT: PASS`): page-table entries are
written through the D$ side and kept dirty in cache; `sv32_ptw.v` then walks through
the PTW D$ port, hits those dirty PTEs (`d_hits=4`, `d_misses=2`), and performs no
extra backing-memory reads during the walk (`backing_reads` stays at 8).

## Sequential rvlinux memory boundary: `rvlinux_mem_boundary.v`
`rvlinux_mem_boundary.v` is the first synthesizable core-facing boundary for replacing
the simulation-only RAM/PTW path in `rvlinux.v`. One upstream request now sequences
Sv32 translation, optional hardware A/D PTE writeback through the D$ PTW port, and the
final I$ fetch or D$ load/store. The upstream protocol is deliberately the same
hold-`req`-until-`ready` shape as the cache blocks, so the next core step is a stall
FSM around fetch/decode/LSU/AMO rather than another memory-system redesign.

The boundary also reserves `core_access=3` as a translate-only operation. With
`core_be[0]=1`, it validates store permissions and performs A/D PTE writeback, then
returns the PA without issuing a final D$ write. With `core_be[0]=0`, it validates load
permissions, sets only the A bit when needed, returns the PA, and suppresses the final
D$ read. The store-check form is used by failed `SC.W` and by AMO preflight checks;
the load-check form is ready for translate-then-route MMIO dispatch.

Verified (`MEM_BOUNDARY_RESULT: PASS`): bare M-mode stores create page tables and data,
S-mode translated fetch updates the A bit and reads through I$, repeated fetch hits I$,
S-mode load sees D$-dirty data, S-mode store sets the D bit before writing through D$,
dirty A/D PTE updates are visible to later reads, and an unmapped S-mode load returns
load page-fault cause 13. The regression also checks that PTW reads of dirty PTEs do
not hit backing memory, cached load/fetch hits avoid extra backing reads, and
store-check sets A/D while leaving the target data word unchanged, and load translate-only
sets A without touching the target data word. It now also remaps a hot Sv32 VA to a
second leaf PTE, proves stale DTLB and ITLB entries continue using the old PA until a
`tlb_flush`, then proves the flush forces a fresh walk to the new PA and performs the
expected A-bit update.

## Multi-cycle rvlinux fetch stage: `rvlinux_fetch_stage.v`
`rvlinux_fetch_stage.v` is the first core-side stall controller split out of the
single-cycle `rvlinux.v` fetch path. It drives `rvlinux_mem_boundary.v` with one or
two fetch requests, then reconstructs the same `lo16`, `raw32`, and `is_rvc` values
that the current core derives from combinational `pread()` calls. A 32-bit instruction
at `pc[1]=1` performs a second fetch at `pc+2`, which also gives the real boundary a
place to raise the second-half Sv32 page fault.

Verified (`FETCH_STAGE_RESULT: PASS`) with the real memory boundary behind it:
aligned RV32 fetch, high-half RVC fetch with no second request, halfword-offset RV32
fetch reassembly from two cache/boundary requests, cross-page second-half instruction
fault with cause 12 and `tval` semantics matching the existing `rvlinux.v` PC, I$
hit/miss exercise, and translated fetch A-bit update. `yosys
synth_rvlinux_fetch_stage.ys` maps the controller itself to 152 LUT4 + 139 FF on ECP5
with 0 check problems.

## rvlinux decode packet stage: `rvlinux_decode_stage.v`
`rvlinux_decode_stage.v` is the post-fetch decode packet for the future stall FSM. It
accepts the stable `lo16`, `raw32`, and `is_rvc` outputs from `rvlinux_fetch_stage.v`,
performs the same RVC decompression as `rvlinux.v`, and emits the canonical 32-bit
instruction, instruction length, decoded register/immediate fields, basic instruction
class flags, AMO/LR/SC flags, SYSTEM sub-op flags, and a base legality bit. CSR
existence and privilege checks intentionally remain outside this stage because they
depend on current privileged state.

Verified (`DECODE_STAGE_RESULT: PASS`): RV32 passthrough decode, representative Q0/Q1/Q2
compressed instructions (`C.ADDI4SPN`, `C.LW`, `C.SW`, `C.JAL`, `C.LI`, `C.LUI`,
`C.SUB`, `C.J`, `C.BEQZ`, `C.LWSP`, `C.JR`, `C.EBREAK`, `C.SWSP`), illegal
compressed encodings, AMO LR/SC classification, and MRET SYSTEM classification.
`yosys synth_rvlinux_decode_stage.ys` maps the combinational decode packet to 534
LUT4 and 0 FF on ECP5 with 0 check problems.

## rvlinux privileged CSR/trap stage: `rvlinux_csr_trap_stage.v`
`rvlinux_csr_trap_stage.v` factors the privileged control plane out of the current
single-cycle `rvlinux.v` block. It holds M/S/U privilege, M/S CSR state, `satp`,
counter state, delegation registers, and the trap/return side effects needed by the
future stall FSM. CSR `time`/`timeh` now read the CLINT/MMIO `mtime` value supplied
by the shell rather than a duplicate private counter, matching the original booting
`rvlinux.v` time source. The stage also accepts a `check_interrupts` qualifier so
the FSM can defer trap-taking interrupts until after already-completed stores, AMOs,
and MMIO side effects retire architecturally. One `step_valid` event can retire a
normal instruction, execute a CSR instruction, take ECALL/EBREAK or an external
exception, evaluate interrupt delegation, and perform MRET/SRET privilege restoration.
It also accepts a `fast_retire` pulse for ordinary min-core instructions that have
already been proven not to need a CSR/trap step; this preserves `minstret` accounting
without forcing a two-cycle retire path for every ALU/load/store/M/AMO instruction.

Verified (`CSR_STAGE_RESULT: PASS`): M-mode CSR writes to `mtvec`, `medeleg`,
`stvec`, `mepc`, and `mstatus`; MRET into S-mode; S-mode `satp` and `sstatus`
writes with `SUM`/`MXR` outputs; delegated S-mode ECALL to `stvec` with `sepc`,
`scause`, and `SPP` update; SRET into U-mode; and illegal U-mode access to an
M-mode CSR trapping back to `mtvec` with cause 2. `yosys
synth_rvlinux_csr_trap_stage.ys` maps it to 1469 LUT4 and 720 FF on ECP5 after the
CLINT-backed `time`/`timeh`, side-effect interrupt-gating, and fast-retire fixes.

## Multi-cycle rvlinux LSU stage: `rvlinux_lsu_stage.v`
`rvlinux_lsu_stage.v` is the matching core-side load/store controller. It performs
the `rvlinux.v` responsibilities that should stay in the core pipeline: early
misaligned load/store exceptions, store byte-enable/data-lane generation, and load
sign/zero extension. It delegates translation, hardware A/D PTE updates, and the D$
transaction to `rvlinux_mem_boundary.v`.

Verified (`LSU_STAGE_RESULT: PASS`) with the real memory boundary behind it: LB/LBU
and LH/LHU sign/zero extension, SB/SH/SW byte-enable visibility through D$, load/store
misaligned faults with causes 4/6 and no backing-memory request for the load fault,
translated S-mode LW/SW through Sv32, A-bit and D-bit update sequencing, translated
store readback, and a translated load page fault with cause 13. `yosys
synth_rvlinux_lsu_stage.ys` maps the controller itself to 207 LUT4 + 172 FF on ECP5
with 0 check problems.

## Multi-cycle rvlinux M-extension stage: `rvlinux_muldiv_stage.v`
`rvlinux_muldiv_stage.v` replaces the simulation-style behavioral `*`, `/`, and `%`
path for the synthesizable multicycle shell. It implements every RV32M operation with
a 32-cycle shift/add multiplier and 32-cycle restoring divider, including signed
high-half multiply variants, divide-by-zero behavior, and signed overflow behavior.
The handshake matches the other core stages: hold `start` until one-cycle `done`,
then drop `start` so the stage returns to idle.

Verified (`MULDIV_RESULT: PASS`): `MUL`, `MULH`, `MULHSU`, `MULHU`, `DIV`, signed
overflow `DIV`, `DIVU`, `REM`, divide-by-zero `REM`, and `REMU`. `yosys
synth_rvlinux_muldiv_stage.ys` maps the stage to 903 LUT4 and 335 FF on ECP5, with
no DSPs and no combinational divider.

## Multi-cycle rvlinux AMO stage: `rvlinux_amo_stage.v`
`rvlinux_amo_stage.v` is the LR/SC/AMO controller split out for the future stall FSM.
It handles early word-alignment faults, LR reservation create, SC success/failure and
reservation clear, AMO read-modify-write functions, and inter-transaction request-drop
bubbles required by `rvlinux_mem_boundary.v`. Store-check requests let the stage check
Sv32 store permissions and update A/D bits without committing a failed `SC.W` store.

Verified (`AMO_STAGE_RESULT: PASS`) with the real memory boundary behind it: AMOOR,
AMOADD, signed AMOMIN, unsigned AMOMAXU, LR read/reservation setup, SC success and
failed SC no-store behavior, misaligned LR/AMO faults with causes 4/6 and no memory
request on the LR fault, translated S-mode AMOSWAP with A/D update, translated
readback, and translated AMO/LR page faults with causes 15/13. `yosys
synth_rvlinux_amo_stage.ys` maps the controller itself to 611 LUT4 + 238 FF on ECP5
with 0 check problems.

## Multi-cycle rvlinux MMIO/device stage: `rvlinux_mmio_stage.v`
`rvlinux_mmio_stage.v` lifts the qemu-virt device subset out of the single-cycle
`rvlinux.v` block into a synthesizable sequential stage. It implements CLINT
`mtime`/`mtimecmp`/`msip`, a 16550-style UART register file with TX pulse and RX
holding register, the single-source S-context PLIC path used by the UART, and syscon
poweroff exit codes. It also exports an `irq_pending` vector for the CSR/trap stage
so MTI/MSI/SEI are no longer hardwired away in the multicycle shell, plus full-width
`mtime`/`mtimecmp` outputs so CSR `time` observes the same writable CLINT counter.

Verified (`MMIO_STAGE_RESULT: PASS`): UART THR store emits one TX byte, UART LSR/RBR
RX-ready and consume behavior, UART IER-driven interrupt pending through PLIC
priority/enable/threshold/claim/complete, CLINT MSIP set/clear, CLINT MTIP via
`mtimecmp`, parameterized `MTIME_TICK_CYCLES` mtime hold/tick behavior, misaligned
MMIO load fault cause 4, and syscon `0x5555` exit-zero halt. `yosys
synth_rvlinux_mmio_stage.ys` maps it to 825 LUT4 and 273 FF on ECP5 with
0 check problems.

## Shared rvlinux stage cluster: `rvlinux_stage_cluster.v`
`rvlinux_stage_cluster.v` is the reusable integration point for the next `rvlinux.v`
stall-FSM cut. It instantiates `rvlinux_fetch_stage.v`, `rvlinux_lsu_stage.v`, and
`rvlinux_amo_stage.v` behind a single shared `rvlinux_mem_boundary.v`, and now also
exposes a direct translate-only client for PA preflight before MMIO dispatch. A small
owner/grant FSM lets fetch, translate, LSU, or AMO own the boundary until its request
is complete and the upstream `start` is dropped. This removes the testbench-only
pattern where each stage had its own private boundary/cache/PTW instance.

Verified (`STAGE_CLUSTER_RESULT: PASS`) through the shared boundary: bare fetch with
I$ hit reuse, bare LSU store/load, AMOOR/LR/SC with LSU readback of the SC store,
translated S-mode fetch/LSU/AMO through one Sv32/L1 path, translated fetch/load/AMO
fault propagation with causes 12/13/15, owner release after each command, I$/D$
exercise, load and store translate-only PA return, A-only and A/D PTE updates from
translate-only requests, no target-data modification during translate-only, shared
PTW A/D updates, and MPRV-style data privilege: fetch still uses the current execute
privilege while LSU/AMO/translate-only accesses use the CSR stage's
`data_priv = mstatus.MPRV ? mstatus.MPP : priv`. The regression checks that S data
privilege faults on a U page when `SUM=0` and succeeds when `SUM=1`. `yosys
synth_rvlinux_stage_cluster.ys` maps the cluster to 34 DP16KD, 3761 LUT4, 2121 FF,
and 384 TRELLIS_DPR16X4 on ECP5 with 0 check problems.

## Minimal multicycle rvlinux core shell: `rvlinux_min_core_fsm.v`
`rvlinux_min_core_fsm.v` is the first executable control loop around the new decode
packet, privileged CSR/trap stage, sequential M stage, shared memory-stage cluster,
and sequential MMIO stage. It is not yet the default Linux-booting core, but it now
has a top-level `rvlinux.v`/`vtop.v` migration path and proves the main stall-FSM
shape: fetch through I$, decode the stable packet, execute
ALU/control/M ops, issue LSU and AMO/LR/SC commands through the shared boundary,
preflight load/store addresses through translate-only, dispatch physical device
addresses to the MMIO stage, route MMIO interrupt pending into CSR/trap logic, route
every retire/trap/xRET decision through the CSR stage, wait for owner release, write
back, and advance variable-length PCs.

The shell now has an explicit decode-capture / execute split: after fetch returns, the
decode packet, source-register values, immediates, CSR metadata, and instruction class
bits are registered before ALU/branch/LSU/AMO/CSR dispatch. This adds one control
cycle per instruction in the minimal shell, but cuts the prior decode/register-read to
CSR-next-PC timing path.

To claw back fixed per-instruction overhead without changing trap semantics, the shell
now uses the CSR stage's `fast_retire` input for ordinary ALU/control instructions,
completed loads, stores, M-extension results, and AMO/LR/SC results when no enabled
interrupt is pending. Stores are always allowed to use this path after their side
effect commits because the prior CSR path already deferred interrupt-taking for
completed stores. CSR/SYSTEM, exception, xRET, WFI, MMIO, and interrupt-taking paths
still go through the full CSR step.

The fetch side now overlaps owner release with decode/execute as well. When
`rvlinux_fetch_stage.v` raises `done`, the FSM captures the instruction packet and
goes straight to decode instead of waiting in a separate fetch-drop state for the
shared stage-cluster owner to return to idle. Fast-retired ALU/load/store/M/AMO
instructions also seed `fetch_pc` and assert the next fetch immediately, so the next
request waits behind any in-flight LSU/AMO owner release naturally instead of burning
an extra `S_FETCH_START` cycle first. The full CSR/trap/xRET completion path now
does the same after `csr_done`: it advances `pc`, seeds `fetch_pc` from
`csr_next_pc`, asserts `fetch_start`, and enters `S_FETCH_WAIT` directly instead of
spending a fixed extra cycle in `S_FETCH_START`.

Verified (`MIN_CORE_RESULT: PASS`) with a backing-memory program: RV32I ADD/ADDI,
SW/LW through D$, BEQ branch over a bad write, two `C.NOP` instructions proving
16-bit PC stepping, `MUL`/`DIV`/`REM` through `rvlinux_muldiv_stage.v`, AMOADD,
LR/SC through `rvlinux_amo_stage.v`, D$ readback of the SC store, `AMOADD.W.AQRL`,
explicit `SRAI`/`SRA` sign-extension coverage against `SRLI`, and clean `EBREAK`
halt. The run retires 26 instructions, ends at `pc=0x68`, leaves `x3=x5=x10=12`,
`x11=35`, `x12=7`, `x13=0`, AMO/LR old values `x14=12` and `x15=17`, successful
SC `x17=0`, SC readback `x18=9`, AQ/RL AMO old/readback values `x24=9` and
`x25=14`, skipped `x6=0`, `x20=x22=0xffff_ffff` for arithmetic right shift, and
`x23=0x00ff_ffff` for logical right shift; it exercises I$/D$ misses and hits
(`ihit=20 imiss=7 dhit=9 dmiss=1`).

`EBREAK` handling is parameterized as `EBREAK_HALTS`. The default remains the
testbench-friendly direct halt, but `EBREAK_HALTS=0` routes `EBREAK` through the
privileged CSR/trap stage. Verified (`MIN_CORE_EBREAK_TRAP_RESULT: PASS`): M-mode
sets `mtvec=0x80`, executes `EBREAK`, traps with `mcause=3`/`mepc=0x8`, then halts
through real syscon. This is required for OpenSBI's semihosting probe, which uses an
`EBREAK` that must trap rather than terminate the simulation.

Verified (`PRIV_CORE_RESULT: PASS`) with a second backing-memory program: M-mode CSR
setup, MRET into S-mode, SRET into U-mode, delegated U-mode ECALL back to an S-mode
handler, S-handler reads of `scause` and `sepc`, and clean `EBREAK` halt in S-mode.
The run retires 20 instructions, ends at `pc=0x8c`, leaves `priv=1`, `x2=8`,
`x3=0x64`, `x4=7`, and `x10=12`.

Verified (`MIN_CORE_MMIO_RESULT: PASS`) with a third backing-memory program: `SB` to
UART THR at `0x10000000` emits `0x41`, `LBU` from UART LSR returns `0x60` into `x6`
and `x10`, and `SW 0x5555` to syscon `0x11100000` halts with `exit_code=0`. The run
retires 9 instructions and ends at `pc=0x24`.

Verified (`MIN_CORE_TRANSLATED_MMIO_RESULT: PASS`) with a fourth backing-memory
program: M-mode installs an Sv32 root and `mret`s into S-mode; S-mode then accesses
virtual address `0x1000` mapped to UART PA `0x10000000` and virtual address `0x2000`
mapped to syscon PA `0x11100000`. UART emits `0x42`, UART LSR returns `0x60` into
`x6`/`x10`, syscon halts with `exit_code=0`, the run ends in S-mode at `pc=0x60`
after 18 retired instructions, and the boundary reports 3 hardware A/D updates.

Verified (`MIN_CORE_TLB_FLUSH_RESULT: PASS`) with a dedicated backing-memory
program: M-mode writes `satp`, enters S-mode, loads from an Sv32 data VA, executes
`sfence.vma`, then loads the same VA again. The test observes exactly two
core-generated `tlb_flush` pulses (`satp=1`, `sfence=1`) and two PTW starts for the
data VA, proving the min-core CSR path drives the boundary flush used by the retained
split ITLB/DTLB. The local run passed in
`logs/ci-min-core-tlb-flush-20260629/tb_rvlinux_min_core_tlb_flush.log`.

Verified (`MIN_CORE_MPRV_RESULT: PASS`) with an MPRV backing-memory program: M-mode
enables Sv32, sets `mstatus.MPRV=1` and `MPP=S` while leaving `SUM=0`, then executes
an M-mode `LW` from a U page at VA `0x1000`. Correct behavior is a load page fault
using S-mode data permissions, so the trap returns to the M handler with
`mcause=13`, `mtval=0x1000`, `x10=13`, and the attempted load destination still zero.

Verified (`MIN_CORE_INTERRUPT_RESULT: PASS`) with an interrupt backing-memory program:
M-mode delegates supervisor external interrupts, enables `mie.SEIE`, enters S-mode,
configures UART source 1 through the PLIC priority/enable/threshold registers, enables
UART RX interrupt generation, and sets `sstatus.SIE`. The testbench injects UART RX
byte `0x5a`; the core takes an S-mode external interrupt with
`scause=0x80000009`, records `sepc=0x7c`, claims PLIC source 1, reads the UART byte
into `x12`, completes the PLIC interrupt, and halts in S-mode at `pc=0xa4`.

Verified (`MIN_CORE_WFI_TIMER_RESULT: PASS`) for real WFI behavior: the CSR stage
now exposes a combinational local-interrupt wake signal, the FSM parks in
`S_WFI_WAIT`, and a WFI that wakes into an interrupt records the post-WFI PC in
`mepc/sepc` so `xRET` resumes after WFI. The timer test stalls at WFI for 999
cycles, then takes `mcause=0x80000007` with `mepc=0x3c`, leaves the fall-through
sentinel register unchanged, and halts in the handler at `pc=0x88`.

Verified (`MIN_CORE_TIME_CSR_RESULT: PASS`) for the CLINT/CSR time-source contract:
the program writes CLINT `mtime` low to `0x00100000`, reads CSR `time` into `x10`,
then reads CLINT `mtime` through MMIO into `x11`. Before the fix this failed with
`x10=0x000000ac` and `x11=0x00100051`; after the fix it passes with
`x10=0x00100037`, `x11=0x00100049`, and an 18-cycle read-spacing delta.

Verified (`MIN_CORE_INTERRUPT_SIDE_EFFECT_RESULT: PASS`) for interrupt delivery
around side-effecting instructions. The regression makes an S-mode UART `SB` execute
while an M-timer interrupt is pending. Before the fix, the UART write happened, the
interrupt trapped with `mepc` still pointing at the store, and `mret` replayed the
store, producing two UART bytes. After the fix, the UART write happens once and the
interrupt records `mepc=0x40`, the post-store PC. WFI wake still observes pending
interrupts directly; only trap-taking during already-completed store/MMIO/AMO commit
is masked for one CSR step.

Post-synth JSON for the integrated min-core shell reports 32 DP16KD, 11097 LUT4,
5278 TRELLIS_FF, and 108 TRELLIS_DPR16X4 on ECP5 after `yosys -q
synth_rvlinux_min_core_fsm.ys`. The ALU uses an explicit `sra32` helper for
arithmetic right shift so simulation and synthesis do not depend on
conditional-expression signedness around `>>>`.

`rvlinux.v` itself now has an `RVLINUX_SYNTH_SHELL` compile path that instantiates
this multicycle shell while leaving the default Linux-booting behavioral model
unchanged. Verified (`RVLINUX_SYNTH_SHELL_RESULT: PASS`): the `rvlinux` top-level
port list drives the translated S-mode UART/syscon MMIO program through the shell,
emits UART byte `0x43`, ends in S-mode at `pc=0x60`, and reads UART LSR `0x60`
into `x6`/`x10`. The shell path now also forwards the min-core debug state through
the top-level `rvlinux.v` ports: generic GPR reads via `dbg_rsel`/`dbg_rval`,
`dbg_scause`, `dbg_mcause`, `dbg_mip`, `dbg_mie`, `dbg_stval`, `dbg_satp`,
`dbg_mepc`, `dbg_sepc`, and CLINT-style `dbg_mtime`/`dbg_mtimecmp`.
Verified (`RVLINUX_SYNTH_SHELL_DEBUG_RESULT: PASS`): a top-level shell program
delegates a U-mode ECALL to S-mode and observes non-old-mux GPR `x4=7`, `x10=12`,
`dbg_scause=8`, `dbg_mcause=0`, `dbg_stval=0`, `dbg_mip=0`, `dbg_mie=0`, advancing
`dbg_mtime`, and reset `dbg_mtimecmp=0xffff_ffff` at the `rvlinux` top-level.
Verified (`RVLINUX_SYNTH_SHELL_INTERRUPT_RESULT: PASS`): the same top-level synth shell
delegates a UART RX interrupt through the PLIC to S-mode, reports
`dbg_scause=0x80000009`, exposes `sepc=0x7c` in `x3`, PLIC claim source 1 in `x5`,
and the received byte `0x5a` in `x6`, then halts in S-mode at `pc=0xa8`. Verified
(`RVLINUX_SYNTH_SHELL_STIP_RESULT: PASS`): M-mode sets `mip.STIP`, delegates/enables
STIE, enters S-mode, and the top-level synth shell takes the S-mode timer interrupt
with `dbg_scause=0x80000005`, `sepc=0x48`, and `dbg_mip=0x20`, then halts at
`pc=0x88`. `yosys -q synth_rvlinux_synth_shell.ys` synthesizes `rvlinux.v` under
that macro at the default-style `RAMBASE=0x80000000` to 32 DP16KD, 10465 LUT4,
5005 TRELLIS_FF, and 108 TRELLIS_DPR16X4 on ECP5 after the CLINT-backed `time`,
side-effect interrupt-gating, fast-retire, fetch-overlap, and direct
CSR-completion fetch fixes.

The shell backing memory now honors `RAMBASE` when indexing the inferable BRAM and
accepts top-level `MEMFILE`/`MEMFILE_WORDS` initialization through
`rvlinux.v -> rvlinux_min_core_fsm.v -> rvlinux_stage_cluster.v ->
rvlinux_mem_boundary.v -> l1_mem_system.v -> slowmem.v`. Verified
(`RVLINUX_SYNTH_SHELL_MEMFILE_RESULT: PASS`): the `rvlinux` top-level loads a small
hex file into the real backing memory, resets at `0x80000000`, emits UART byte
`0x44`, reads UART LSR `0x60` into `x6`/`x10`, and the 10-instruction smoke program
halts through syscon at `pc=0x80000024`.

The Verilator boot harness is now parameterized for the migration path too:
`vtop.v` forwards `MEMFILE`, `MEMWORDS`, `MEMFILE_WORDS`, `RAMBASE`,
`MTIME_TICK_CYCLES`, and `EBREAK_HALTS` into `rvlinux.v`, and `build_vtop.sh`
accepts `SYNTH_SHELL=1` to
compile the same top through `RVLINUX_SYNTH_SHELL` with the full
multicycle/cache/PTW/MMIO RTL source set. Verified in the main regression
(`vtop_synth`): building `tb_rvlinux_synth_shell_memfile.hex` with `MEMWORDS=4096`,
`MEMFILE_WORDS=10`, and `SYNTH_SHELL=1` emits UART byte `0x44` and halts through
syscon under Verilator after 259 cycles with fast-retire, fetch-overlap, and direct
CSR-completion fetch enabled.
`MTIME_TICK_CYCLES` defaults to 1, so the
normal model remains unchanged; higher values are an explicit diagnostic knob for
separating CLINT timebase/timer-pressure effects from unrelated boot bugs. The same
parameter now also drives the default behavioral `rvlinux.v` CLINT model, with
`RVLINUX_TIMEBASE_PARAM_RESULT: PASS` checking that `MTIME_TICK_CYCLES=4` holds
`mtime` for three cycles and increments on the fourth. The divider terminal compare
uses equality rather than an unsigned `>= 0` case so default `MTIME_TICK_CYCLES=1`
still builds cleanly under Verilator warning-as-error in `vtop_synth`.

`linux-build/make_timebase_payload.sh` now provides a host-side DTB-only payload
variant path for timer diagnostics. It recompiles `linux-build/device.dts` with a
new `/cpus/timebase-frequency`, locates the exact embedded `device.dtb` inside the
existing `fw_payload_sf.bin`, replaces it in place when the new DTB fits, and
regenerates the matching `.hex` via `bin2hex.py`. This avoids a full OpenSBI/container
rebuild for timebase-only experiments. The generated 400 MHz artifacts
(`linux-build/fw_payload_sf_tb400m.{bin,dtb,hex}`) were checked with `dtc`; the DTB
contains `timebase-frequency = <0x17d78400>`, and the patched payload contains the
400,000,000 Hz marker once and no remaining 100,000,000 Hz marker.

Bounded full-payload evidence now exists for the synthesizable shell path:
`SYNTH_SHELL=1 EBREAK_HALTS=0 MEMWORDS=33554432 MEMFILE_WORDS=11718914` builds the
soft-float OpenSBI/Linux payload into `vtop`. The Verilator harness also supports
`EXPECT_UART=<string>` and stops with a CSR/PC dump when the UART transcript matches.
Before the SRAI fix, a 240M-cycle MMIO trace reached S-mode but recorded 4789 MMIO
operations all in M-mode and then sat in Linux `number()` with `s2=0x00ffffff` after
`srai`, explaining the missing Linux console. After the `sra32` fix, a 300M-cycle
trace produced Linux earlycon output and 6427 total MMIO operations, including 1638
S-mode UART transactions. A 700M-cycle bounded run without MMIO trace prints Linux
6.1.44 through `devtmpfs: initialized`.

The latest side-effect-replay-corrected run used
`EXPECT_UART='buildroot login:' ./obj_vtop_synth_linux_sf_sidefx/Vvtop
--maxcyc=5000000000` and naturally reached the 5B-cycle bound. It advances beyond
the previous context-tracking WARN failure signature and beyond the earlier
post-`cpuidle` stop: stdout reaches `HugeTLB`, `iommu`, `SCSI subsystem initialized`,
`usbcore`, `vgaarb`, and `clocksource: Switched to clocksource riscv_clocksource`.
No `WARNING: CPU`, `context_tracking`, Oops, panic, `usb-storage`, init handoff, or
login prompt appears. The final dump is
`pc=0xc004686a priv=1 scause=0x80000005 mcause=0x80000007 sepc=0xc002e428
mepc=0xc0006b30 mip=0xa0 mie=0x20a mtime=0x2a05f200 mtimecmp=0x2a020fb4`.
Tail symbolization over the 2.5B-5B cycle window concentrates in `account_system_index_time`,
`div_u64_rem`, `hrtimer_update_next_event`, `update_load_avg`,
`__update_load_avg_cfs_rq`, `hrtimer_interrupt`, `update_process_times`, and
`tick_do_update_jiffies64`, with `sepc` at `finish_task_switch.isra.0+0x72` and
`mepc` in `__sbi_set_timer_v02+0x1c`.

A follow-up 5B-cycle diagnostic run built the same payload with
`MTIME_TICK_CYCLES=2`:
`SYNTH_SHELL=1 EBREAK_HALTS=0 MEMWORDS=33554432 MEMFILE_WORDS=11718914
MTIME_TICK_CYCLES=2 OBJ_DIR=obj_vtop_synth_linux_sf_mtime2 bash build_vtop.sh
linux-build/fw_payload_sf.hex`, then ran with `EXPECT_UART='buildroot login:'`.
It still did not reach login, but advanced materially beyond the default run:
stdout continues past the clocksource handoff through `NET: Registered PF_INET
protocol family`, TCP/UDP hash-table setup, `NET: Registered PF_UNIX/PF_LOCAL
protocol family`, RPC modules, NFS layout drivers, `9p: Installing v9fs 9p2000
file system support`, `NET: Registered PF_ALG protocol family`, the block-layer
SCSI generic driver, and both `mq-deadline` and `kyber` IO scheduler registration.
No panic, Oops, BUG, or warning appears. The final dump is
`pc=0xc043a354 priv=1 scause=0x80000005 mcause=0x00000009 stval=0x00000000
satp=0x80082cb9 sepc=0xc072afba mepc=0xc0006b30 mip=0x0 mie=0x2aa
mtime=0x9502f900 mtimecmp=0x95041b3d`. Symbolization shows the hot tail in
`task_tick_fair`, `scheduler_tick`, `calc_global_load_tick`,
`perf_event_task_tick`, `clear_buddies`, `_raw_spin_unlock`, and `__memcpy`;
the final PC is `devtmpfs_create_node`, `sepc` is `_raw_spin_unlock_irqrestore`,
and `mepc` remains `__sbi_set_timer_v02+0x1c`.

That diagnostic confirms the current blocker is timer/scheduler pressure after
clocksource switch: slowing the CLINT timebase lets Linux progress into later
network, filesystem, devtmpfs, and block-layer init, while the default run ends with
timer interrupt pressure (`mip=0xa0` and `mtimecmp` already behind `mtime`). With
`MTIME_TICK_CYCLES=2`, the final timer state is no longer continuously pending
(`mip=0`, `mtimecmp` in the future), but the synth-shell path still has not reached
an interactive shell. The earlier SRA, WFI-EPC, CLINT/CSR time-source, and
side-effect replay bugs are not the current limiting signature.

A second diagnostic 5B-cycle run used `MTIME_TICK_CYCLES=4`
(`OBJ_DIR=obj_vtop_synth_linux_sf_mtime4`). It also did not reach login and produced
no panic, Oops, BUG, or warning, but it reached the same late `kyber` IO scheduler
registration point by about 3.1B cycles instead of only at the 5B bound. Final stdout
still stops at `io scheduler kyber registered`. The final dump is
`pc=0xc03678f4 priv=1 scause=0x80000005 mcause=0x00000009 stval=0x00000000
satp=0x80082cb9 sepc=0xc072afba mepc=0xc0006b30 mip=0x0 mie=0x2aa
mtime=0x4a817c80 mtimecmp=0x4a8213e1`. Tail symbolization over the 2.5B-5B window
is again scheduler/timer dominated: `task_tick_fair`, `sched_slice`,
`__calc_delta`, `__memcpy`, `__memset`, and `__might_resched`; the final PC is
`copy_page_from_iter_atomic`, `sepc` is `_raw_spin_unlock_irqrestore`, and `mepc`
remains `__sbi_set_timer_v02+0x1c`. This confirms the timebase/CPU-throughput ratio
is a real bottleneck, but increasing the divider alone is not yet sufficient to
reach init or login within 5B cycles.

A platform-correct 5B-cycle run then kept the default synth-shell timer behavior
(`MTIME_TICK_CYCLES=1`) and instead booted the 400 MHz DTB payload generated above
(`OBJ_DIR=obj_vtop_synth_linux_sf_tb400m`). OpenSBI reports
`aclint-mtimer @ 400000000Hz`, Linux reports `sched_clock: 64 bits at 400MHz`,
and the run reaches the same late NFS/9p/block layer path by about 3.0B cycles:
`NFS: Registering the id_resolver key type`, `9p: Installing v9fs 9p2000 file
system support`, `io scheduler mq-deadline registered`, and `io scheduler kyber
registered`. It still does not reach init or login within 5B cycles, and produces
no panic, Oops, BUG, or warning. The final dump is
`pc=0xc0719388 priv=1 scause=0x80000005 mcause=0x00000009 stval=0x00000000
satp=0x80082cb9 sepc=0xc072afbe mepc=0xc0006b30 mip=0x0 mie=0x2aa
mtime=0x2a05f200 mtimecmp=0x2a083062`. Tail symbolization over the 2.5B-5B window
is again timer/scheduler and memory-copy dominated: `perf_event_task_tick`,
`__memcpy`, `do_raw_spin_unlock`, `_raw_spin_unlock`, `calc_global_load_tick`,
`task_tick_fair`, `kmem_cache_alloc`, and `blake2s_compress`; the final PC is
`__memcpy`, `sepc` is `_raw_spin_unlock_irqrestore`, and `mepc` is
`__sbi_set_timer_v02`. This is the cleaner result: the correct 400 MHz platform
timebase gives the same improvement as the `MTIME_TICK_CYCLES=4` workaround without
changing RTL timer cadence. The remaining synth-shell blocker is post-`kyber`
initialization throughput, not a newly observed timer functional bug.

A fast-retire 5B-cycle run then rebuilt the same 400 MHz/default-tick payload with
the ordinary-instruction CSR bypass enabled
(`OBJ_DIR=obj_vtop_synth_linux_sf_tb400m_fastretire`). OpenSBI still reports
`aclint-mtimer @ 400000000Hz`, Linux still reports `sched_clock: 64 bits at
400MHz`, and there is no panic, Oops, BUG, or warning. It improves the Linux
timestamps for the same milestones: clocksource handoff moves from 1.999741s to
1.936822s, PF_INET from 3.052739s to 2.954319s, NFS id-resolver registration from
6.098090s to 5.872767s, 9p from 6.218102s to 5.994973s, and `io scheduler kyber
registered` from 6.282051s to 6.057009s. It still does not reach init or login
within 5B cycles, and final stdout again stops at `io scheduler kyber registered`.
The final dump is
`pc=0xc002f824 priv=1 scause=0x80000005 mcause=0x80000007 stval=0x00000000
satp=0x80082cb9 sepc=0xc002d52a mepc=0xc002d52a mip=0xa0 mie=0x20a
mtime=0x2a05f200 mtimecmp=0x2a0302dd`. Tail sampling over the post-`kyber`
window is spread across scheduler tick/accounting and general kernel helpers:
`update_curr`, `task_tick_fair`, `update_rq_clock`, `__might_resched`,
`do_raw_spin_lock`, `__memcpy`, `__memset`, `vsnprintf`, `idr_get_free`, and
`blake2s_compress`. This confirms the bypass is a real throughput improvement, but
the P0 limiter is still broader post-`kyber` initialization throughput rather than a
single newly exposed functional fault.

A follow-up front-end fixed-bubble optimization then overlapped fetch owner release
with decode/execute and launched the next fetch directly from fast-retire paths
(`OBJ_DIR=obj_vtop_synth_linux_sf_tb400m_fetchfast`). The 10-instruction Verilator
synth-shell MEMFILE smoke improved from 294 cycles to 261 cycles. In the 400
MHz/default-tick full-payload 5B-cycle run, OpenSBI and Linux still report the 400
MHz platform timer, and there is still no panic, Oops, BUG, or warning. Linux
milestones move earlier again: `devtmpfs: initialized` is 0.283649s, clocksource
handoff 1.793023s, PF_INET 2.731636s, NFS id-resolver registration 5.446581s, 9p
5.543298s, and `io scheduler kyber registered` 5.599753s. The run still does not
reach init or login within 5B cycles; final stdout again stops at `io scheduler
kyber registered`. The final dump is
`pc=0xc038ed30 priv=1 scause=0x80000005 mcause=0x00000009 stval=0x00000000
satp=0x80082cb9 sepc=0xc072af8e mepc=0xc0006b30 mip=0x0 mie=0x2aa
mtime=0x2a05f200 mtimecmp=0x2a0a27b9`. Post-`kyber` sampling now concentrates
heavily in `timekeeping_advance`, with additional hits in `__memcpy`,
`do_raw_spin_unlock`, `__might_sleep`, `__might_resched`, and final PC
`percpu_counter_add_batch`. This confirms the front-end bubble removal is another
real throughput win, while the remaining P0 limiter is still the post-`kyber`
timekeeping/timer-heavy initialization tail.

A smaller CSR-completion fetch optimization then removed the fixed `S_FETCH_START`
bubble after full CSR/trap/xRET steps (`OBJ_DIR=obj_vtop_synth_linux_sf_tb400m_csrfetch`).
The 10-instruction Verilator synth-shell MEMFILE smoke improves again from 261
cycles to 259 cycles. In the 400 MHz/default-tick full-payload 5B-cycle run, there
is still no panic, Oops, BUG, or warning, and the run still does not reach init or
login. The Linux milestones move slightly earlier than fetch-overlap alone:
`devtmpfs: initialized` 0.283338s, clocksource handoff 1.791866s, PF_INET
2.729900s, NFS id-resolver registration 5.420852s, 9p 5.529651s,
`io scheduler mq-deadline registered` 5.584181s, and `io scheduler kyber registered`
5.585537s. The final dump is
`pc=0xc0040d04 priv=1 scause=0x80000005 mcause=0x80000007 stval=0x00000000
satp=0x80082cb9 sepc=0xc01684d0 mepc=0xc01684d0 mip=0xa0 mie=0x20a
mtime=0x2a05f200 mtimecmp=0x2a02e4d5`. Post-`kyber` sampling remains concentrated
in scheduler/timekeeping and memory helpers: `__memcpy`, `__memset`,
`__update_load_avg_se`, `div_u64_rem`, `do_raw_spin_unlock`, and `new_slab`.

A one-entry M-extension divide-result cache was tested and rejected rather than kept.
It made a back-to-back same-operand `REM(U)` then `DIV(U)` sequence complete the
second instruction in one cycle in `tb_rvlinux_muldiv_stage`, but the real 400 MHz
synth-shell Linux run regressed: `kyber` moved from 5.585537s to 5.592661s, NFS from
5.420852s to 5.439155s, and the 5B-cycle run still stopped after `kyber`. It also
increased the synthesized MULDIV block from 903 LUT4/335 FF to 1057 LUT4/530 FF and
the synth-shell top from 10465 LUT4/5005 FF to 10795 LUT4/5200 FF. The experiment
was reverted.

A split one-entry ITLB/DTLB in `rvlinux_mem_boundary.v` is now the retained
performance baseline after CSR-completion fetch. It caches successful Sv32 leaf PTEs
for instruction fetches separately from data/translate-only accesses, refilters hits
against current privilege/SUM/MXR/A/D permissions, fills after PTW or A/D writeback,
and flushes on `sfence.vma` and `satp` writes from the core shell. Directed memory
boundary tests now assert that repeated fetch/load translations skip a second PTW,
that stale DTLB/ITLB entries keep using the old PA after a same-VA PTE remap until
flush, and that `tlb_flush` makes the next load/fetch observe the new PA. The local
Icarus regression passed with `MEM_BOUNDARY_RESULT: PASS` in
`logs/ci-mem-boundary-tlb-remap-20260629/tb_rvlinux_mem_boundary.log`.
In the same 400 MHz/default-tick full-payload 5B-cycle run, there is still no panic,
Oops, BUG, or warning, and the run still does not reach login, but the milestones move
substantially earlier and stdout progresses beyond the old `kyber` stopping point:
`devtmpfs: initialized` 0.162228s, clocksource handoff 1.013694s, PF_INET
1.522142s, NFS id-resolver registration 3.038591s, 9p 3.090800s,
`io scheduler kyber registered` 3.121159s, then serial/ttyS0, loop, e1000e,
usb-storage, mousedev, sdhci/usbhid, PMU, PF_INET6, PF_PACKET, 9pnet, and
`dns_resolver registered`. The final 5B dump is
`pc=0xc00530aa priv=1 scause=0x80000005 mcause=0x00000009 stval=0x00000000
satp=0x80082cb9 sepc=0xc072afba mepc=0xc0006b30 mip=0x0 mie=0x2aa
mtime=0x2a05f200 mtimecmp=0x2a0cbf7f`. Post-3B/5B sampling is now dominated by
`__memcpy`, `do_raw_spin_lock`, `plist_*`, and raw spin unlock/SBI timer paths rather
than page-table-walk overhead. A longer 10B-cycle run of the same split-TLB build
with the stock rootfs still does not reach `buildroot login:`, but it reaches
userspace: stdout prints
`Freeing unused kernel image`, `Run /sbin/init as init process`, then Buildroot init
script progress through `Starting syslogd: OK`, `Starting klogd: OK`,
`Running sysctl: OK`, and finally `Starting network: Waiting for interface eth0 to
appear...`. The final 10B dump is
`pc=0xc0003586 priv=1 scause=0x80000005 mcause=0x00000009 stval=0x00000000
satp=0x8e884161 sepc=0xc000358e mepc=0xc0006b30 mip=0x0 mie=0x2aa
mtime=0x540be400 mtimecmp=0x5d9c199a`; `addr2line` maps the final PC to
`arch_cpu_idle`, consistent with waiting for the missing/undriven `eth0` path rather
than a kernel panic or PTW correctness failure.

That `eth0` wait is now confirmed as a rootfs/platform mismatch. The synth-shell
minimal SoC exposes CLINT, PLIC, UART, and syscon, but no Ethernet MAC, while the
Buildroot rootfs inherited an `auto eth0` DHCP stanza.
`linux-build/repackage_sf_nonet.sh` repackages the soft-float rootfs for this
minimal SoC by keeping only loopback in
`/etc/network/interfaces`, adding a static `/dev/null`, regenerating `rootfs.cpio`,
rebuilding the Linux `Image`, and rebuilding the OpenSBI payload. With that payload
converted to the same 400 MHz timebase (`linux-build/fw_payload_sf_tb400m_nonet.hex`),
the synth-shell Verilator run matches `buildroot login:` after **8,716,611,501**
cycles. The stdout tail is `Starting network: OK`, `Welcome to Buildroot`, then
`buildroot login:`, with no `/dev/null` errors and no `eth0` wait.
`run_synth_shell_nonet.sh` now wraps this path as the standard manual long-run
entry point: it can rebuild the no-net payload with `--prepare-payload`, patches
the 400 MHz DTB payload when needed, builds or reuses the synth-shell `Vvtop`, logs
stdout/stderr under `logs/`, and fails unless `EXPECT_UART` is observed. The default
runner invocation was also run with `--no-build` and matched the login prompt after
the same **8,716,611,501** cycles (`logs/run-synth-shell-nonet-default-login.*`).
`verify_p0_linux.sh` is now the explicit P0 Linux gate around that runner: the default
mode runs the full boot-to-login check, `--smoke` uses the same payload/model path but
matches `OpenSBI` quickly, and `--check-logs=<prefix>` audits an existing expensive
run without rerunning it. The gate's smoke mode passed with `--reuse`, and the
existing full login logs pass the `--check-logs=logs/run-synth-shell-nonet-default-login`
audit. A shorter wrapper smoke using `EXPECT_UART=OpenSBI` matched after 49,374,942
cycles.
`verify_ci.sh` now provides the scriptable CI/nightly scheduler around these gates:
`quick`, `pr`, `p0-smoke`, `p0-audit`, `p0-pnr-audit`, `p0-evidence`, `p0-full`,
`p0-pnr`, `p1`, `p1-trace-audit`, `evidence-health`, and `nightly` profiles keep
the expensive 10B-cycle Linux run and fresh PnR out of the default fast regression
while still giving CI/cron stable entry points. The scheduler's retained-log audit passed in
`logs/ci-p0-audit-20260628-230341`, its reused P0 smoke profile passed in
`logs/ci-p0-smoke-20260628-230345`, its retained PnR audit passed in
`logs/ci-p0-pnr-audit-20260628-231353`, and the combined retained Linux+PnR
evidence profile passed in `logs/ci-p0-evidence-20260628-231300`.
`tools/audit_rvtrace_logs.py` adds the same retained-evidence pattern for P1 trace
coverage: it rechecks the retained `rvtrace_*.csv` files with `check_rvtrace.py`
and `rvtrace_ref.py`, then enforces aggregate coverage signals for traps, AMOs,
PTE A/D updates, and privilege switches. It now also emits machine-readable
`rvtrace_coverage.json` and human-readable `rvtrace_coverage.md` artifacts with
per-test rows, retired counts, traps, AMOs, PTE updates, privilege switches, stores,
writes, UART writes, and syscon writes. The same gate now enforces default per-test
coverage floors: the AMO coverage must remain in `isa`/`amotest`, PTE and main trap
coverage must remain in `mmu`, user-trap privilege switching must remain in `utrap`,
MPRV+SUM permission-fault coverage must remain in `mprv`, MXR execute-only-load
coverage must remain in `mxr`, U-mode page fetch/data plus delegated U->S faults
must remain in `upage`, instruction page-fault coverage must remain in `ifault`,
write-permission-fault plus A/D side-effect coverage must remain in `wpfault`,
S-mode SUM user-page permission coverage must remain in `sum`,
reserved invalid-PTE encoding coverage must remain in `badpte`,
misaligned level-1 Sv32 superpage coverage must remain in `superpage`,
Sv32 LR/SC/AMO permission and A/D coverage must remain in `amo_mmu`,
and every directed trace must keep a minimum
retired-instruction floor. `tests/mprv.c` lifts the existing
MPRV/SUM data-privilege smoke into the default directed/trace/reftrace baseline:
M-mode enables Sv32, sets `MPRV=1, MPP=S`, proves a user-page load succeeds with
`SUM=1`, then proves the same user-page load faults with `SUM=0` while the trap
handler records `mcause=13`, `mtval=0x40000000`, and the pre-trap MPRV bit.
`tests/mxr.c` adds the paired Sv32 MXR path: an S-mode load from a supervisor
execute-only page faults with `MXR=0`, then succeeds with `MXR=1`, while confirming
only the PTE A bit was set. `tests/upage.c` adds U-mode Sv32 page coverage:
M-mode enables Sv32 and enters S-mode, S-mode `sret`s into a user executable page,
a U-mode load from a supervisor-only page delegates a load-page-fault to S-mode,
the S handler records `scause=13` and `stval=0x80301000`, U-mode then stores and
loads through a user data page, and a U-mode `ecall` delegates to S before S calls
into M-mode reporting. `tools/rvtrace_ref.py` now models Sv32 instruction
page-fault traps instead of rejecting fetch faults as outside the reference model,
and `tests/ifault.c` covers that path: S-mode jumps to a supervisor-readable but
non-executable page, the delegated S handler records `scause=12`, `stval=sepc`,
returns to the `jalr` continuation, and confirms the faulting PTE did not receive
A/D updates. `tests/wpfault.c` adds the paired Sv32 store-permission path: S-mode
loads from a read-only supervisor page and observes only A set, then attempts a
store to the same page, catches delegated `scause=15` with `stval=0x40000000`,
confirms D is still clear, updates the PTE to add W, retries the store, and
confirms D is finally set. `tests/sum.c` covers the direct S-mode SUM path:
supervisor store and load attempts to a user page fault with `SUM=0` and leave
the PTE A/D bits clear, then a `SUM=1` load sets A and a `SUM=1` store sets D.
`tests/badpte.c` covers the Sv32 reserved `R=0/W=1` PTE encoding by mapping a
real image page with `V|W|X` and `R=0`, proving S-mode store and instruction fetch
both fault, proving A/D remain clear, and proving the backing physical word was not
modified by the faulting store. `tools/rvtrace_ref.py` now preserves the leaf PA
for valid-looking invalid leaf PTE faults so its trap-row instruction field matches
the DUT RVTRACE stream while still reporting a fault and no A/D update.
`tests/superpage.c` covers the Sv32 level-1 superpage alignment rule: a root-level
leaf with nonzero PPN0 is valid-looking and has R/W/X set, but S-mode store and
instruction fetch both take page faults, the PTE A/D bits remain clear, and the
backing physical return instruction remains unchanged. The combinational
`rvlinux.v` walker, the sequential `sv32_ptw.v` walker, and `tools/rvtrace_ref.py`
now all reject that misaligned-superpage encoding. `tools/check_rvtrace.py` also
skips image-base instruction lookup for cause-12 fetch-fault rows, leaving exact
fetch-fault semantics to the reference trace checker.
`tests/amo_mmu.c` adds LR/SC/AMO coverage under Sv32: LR from a read-only
supervisor page succeeds and sets only A, SC to that page delegates a store/AMO
page fault without setting D or changing memory, then S-mode makes the PTE writable
and proves successful SC plus AMOADD set D and update the mapped word. This keeps
the default trace set from treating bare-mode atomics as enough A-extension
coverage.
A fresh quick profile passed in
`logs/ci-quick-20260629-010333` from the GitHub worktree, and the retained
`verify_ci.sh p1-trace-audit` profile over that logdir passed in
`logs/ci-p1-trace-audit-20260629-010528` across 11 tests with 39,918 retired
instructions, 12 traps, 5 AMOs, 5 PTE updates, and 15 privilege switches.
For the current `wpfault` increment, the local directed, rvtests, trace, reftrace,
and cache/stage portions of `quick` passed in
`logs/ci-quick-20260629-wpfault/quick`; full local `quick` stopped only at
`vtop_synth` because this machine does not have `verilator` or `oss-cad-suite`.
The retained `verify_ci.sh p1-trace-audit` profile over those traces passed in
`logs/ci-p1-trace-audit-20260629-wpfault` across 12 tests with 45,586 retired
instructions, 14 traps, 5 AMOs, 7 PTE updates, 17 privilege switches, and 31/31
coverage-floor checks.
For the current `sum` increment, the local directed, rvtests, trace, reftrace, and
cache/stage portions of `quick` passed in `logs/ci-quick-20260629-sum/quick`; full
local `quick` stopped only at `vtop_synth` because this machine does not have
`verilator` or `oss-cad-suite`. The retained `verify_ci.sh p1-trace-audit` profile
over those traces passed in `logs/ci-p1-trace-audit-20260629-sum` across 13 tests
with 51,394 retired instructions, 17 traps, 5 AMOs, 9 PTE updates, 19 privilege
switches, and 35/35 coverage-floor checks.
For the current `badpte` increment, the local directed, rvtests, trace, reftrace,
and cache/stage portions of `quick` passed in
`logs/ci-quick-20260629-badpte/quick`; full local `quick` stopped only at
`vtop_synth` because this machine does not have `verilator` or `oss-cad-suite`.
The retained `verify_ci.sh p1-trace-audit` profile over those traces passed in
`logs/ci-p1-trace-audit-20260629-badpte` across 14 tests with 61,346 retired
instructions, 20 traps, 5 AMOs, 9 PTE updates, 21 privilege switches, and 38/38
coverage-floor checks.
For the current `superpage` increment, the local directed, rvtests, trace,
reftrace, and cache/stage portions of `quick` passed in
`logs/ci-quick-20260629-superpage/quick`; full local `quick` stopped only at
`vtop_synth` because this machine does not have `verilator` or `oss-cad-suite`.
The retained `verify_ci.sh p1-trace-audit` profile over those traces passed in
`logs/ci-p1-trace-audit-20260629-superpage-v2` across 15 tests with 65,270 retired
instructions, 23 traps, 5 AMOs, 9 PTE updates, 23 privilege switches, and 41/41
coverage-floor checks.
For the current `amo_mmu` increment, the local directed, rvtests, trace, reftrace,
and cache/stage portions of `quick` passed in
`logs/ci-quick-20260629-amo-mmu/quick`; full local `quick` stopped only at
`vtop_synth` because this machine does not have `verilator` or `oss-cad-suite`.
The retained `verify_ci.sh p1-trace-audit` profile over those traces passed in
`logs/ci-p1-trace-audit-20260629-amo-mmu` across 16 tests with 71,237 retired
instructions, 25 traps, 6 AMOs, 12 PTE updates, 25 privilege switches, and 46/46
coverage-floor checks.
Hosted macOS GitHub Actions now runs both quick and the retained RVTRACE coverage
audit. Run `28331969765` for commit `8990e32` passed `quick regression`; artifact
summary `logs/github-quick-28331969765` reports quick `pass=1 fail=0`, including
the stale TLB remap `MEM_BOUNDARY_RESULT: PASS` checks in `quick/cache.log`, and
`logs/github-p1-trace-audit-28331969765` reports the 16-test /
71,237-retired / 25-trap / 6-AMO / 12-PTE-update / 25-privilege-switch baseline
with all 46 coverage-floor checks passing.
`tools/collect_ci_metrics.py` now turns any `verify_ci.sh` log directory into
machine-readable `summary.json` and human-readable `summary.md`, collecting CI
pass/fail, `verify.sh` pass/fail, retained RVTRACE coverage, CI evidence health,
P0 Linux gate status, and PnR Fmax/resource metrics. `verify_ci.sh` writes those
artifacts automatically at the end of every profile. `tools/render_ci_dashboard.py` then scans
`logs/**/summary.json` and refreshes `logs/ci-dashboard.json` plus
`logs/ci-dashboard.md`, so the latest P0 Linux evidence, latest RVTRACE audit, best
PnR Fmax, latest run per profile, and recent-run table are visible without manually
reading long logs. The same renderer now maintains a de-duplicated retained trend
history in `logs/ci-history.jsonl` and a human-readable `logs/ci-trend.md`, tracking
pass streak, profile counts, P0 Linux evidence count, RVTRACE audit/coverage counts,
latest CI evidence health, latest per-test RVTRACE coverage/floor-check status, and
PnR Fmax range across runs. `tools/check_ci_dashboard.py` turns those retained
artifacts into a cheap evidence-health gate: by default it requires parse-clean
dashboard/history files, a passing streak, retained P0 Linux login evidence, retained
PnR evidence at or above the 40 MHz target, retained RVTRACE coverage for 16 tests
with at least 70,000 retired instructions, 25 traps, 6 AMOs, 12 PTE updates,
25 privilege switches, and 46 passing per-test floor checks. The
`./verify_ci.sh evidence-health` profile passed in `logs/ci-evidence-health-20260629-min-core-tlb-flush`, writing
`ci_health.json` / `ci_health.md` with 36/36 checks passing; negative checks also
failed as intended for `--min-pnr-fmax-mhz 60`, `mprv:retired=6000`,
`mxr:retired=6000`, `upage:retired=10000`, `ifault:retired=10000`, and
`wpfault:pte_updates=3`, `sum:pte_updates=3`, `badpte:traps=4`,
`superpage:traps=4`, `amo_mmu:pte_updates=4`, plus `--min-rvtrace-tests 17`.
Both GitHub workflows append the per-run `summary.md` and
the cross-run dashboard Markdown to the Actions step summary before uploading logs,
including the dashboard, history, and trend artifacts. This was verified on
`logs/ci-p0-evidence-20260628-232125`, `logs/ci-p1-trace-audit-20260628-232133`,
and the cron-run `logs/cron/p0-evidence-20260628-232232`, whose summary captures
P0 Linux login evidence plus PnR **53.94 MHz** at a 40 MHz target and the 32 DP16KD /
5118 FF / 12682 TRELLIS_COMB utilization. A fresh retained P0 Linux+PnR evidence
profile passed in `logs/ci-p0-evidence-20260628-233213`, and the latest retained
RVTRACE audit with per-test coverage artifacts passed in
`logs/ci-p1-trace-audit-20260629-003025`. A negative floor check was also exercised
by requiring `isa:amos=4`, which correctly failed while the retained trace only has
3 `isa` AMOs, and the new `upage` floor check also failed as intended when requiring
`upage:retired=10000` against the retained 9,593 retired instructions; the `ifault`
floor check likewise failed as intended when requiring `ifault:retired=10000`
against the retained 9,655 retired instructions. The current cross-run dashboard
reports 28 summaries scanned, 28 retained history runs, a 4-run pass streak,
profile counts of `evidence-health=10`, `p0-evidence=1`, `p1-trace-audit=10`, and
`quick=7`, 10 RVTRACE coverage artifact runs, 10 CI evidence
health runs, latest P0 Linux evidence from
`logs/ci-p0-evidence-20260628-233213`, latest RVTRACE audit/coverage from
`logs/ci-p1-trace-audit-20260629-amo-mmu`, latest CI evidence health from
`logs/ci-evidence-health-20260629-min-core-tlb-flush`, and best PnR at **53.94 MHz** for the
40 MHz target. The latest coverage table shows 46/46 floor checks passing:
`isa`/`amotest` plus `amo_mmu` cover the 6 AMOs, `mmu` covers the original PTE
update and 3 traps,
`utrap` covers the user trap plus 3 privilege switches, and `mprv` contributes
5,452 retired instructions, 1 load page fault, and 1 additional PTE A-bit update;
`mxr` contributes 5,501 retired instructions, 2 traps, 2 privilege switches, and
1 additional PTE A-bit update; `upage` contributes 9,593 retired instructions,
3 traps, 6 privilege switches, and 2 additional PTE A/D updates; `ifault`
contributes 9,655 retired instructions, 2 traps, 2 privilege switches, and 0 PTE
A/D updates on its non-executable target page; `wpfault` contributes 5,668 retired
instructions, 2 traps, 2 privilege switches, and 2 PTE A/D updates while proving a
read-only store fault leaves D clear; `sum` contributes 5,808 retired instructions,
3 traps, 2 privilege switches, and 2 PTE A/D updates while proving `SUM=0` faults
leave A/D clear; `badpte` contributes 9,952 retired instructions, 3 traps, 2
privilege switches, and 0 PTE A/D updates while proving the reserved `R=0/W=1`
encoding faults for store and fetch; `superpage` contributes 3,924 retired
instructions, 3 traps, 2 privilege switches, and 0 PTE A/D updates while proving a
level-1 leaf with nonzero PPN0 faults for store and fetch; `amo_mmu` contributes
5,967 retired instructions, 2 traps, 2 privilege switches, 1 AMO, and 3 PTE A/D
updates while proving LR sets A only, a read-only SC faults without D, and
successful SC/AMOADD set D.
The scheduling layer is now wired for automation: `.github/workflows/ci.yml` runs
the hosted macOS quick profile on push/PR/manual dispatch, `.github/workflows/nightly.yml`
runs the longer profile on a self-hosted macOS runner at 01:00 Asia/Shanghai and
also exposes `evidence-health` as a manual profile, and `tools/ci_cron.sh` provides
the same locked, timestamped entry for local cron/launchd.
`tools/ci_cron.sh p0-audit` passed in `logs/cron/p0-audit-20260628-230808`, and a
fresh `./verify_ci.sh quick` passed with `pass=1 fail=0` in
`logs/ci-quick-20260629-010333`. The same cron wrapper also passed the combined
retained evidence profile in `logs/cron/p0-evidence-20260628-231323`. The
hosted/self-hosted workflow files have been syntax-parsed locally; `actionlint` is
not installed in this environment. The hosted macOS quick workflow now passes
remotely with retained RVTRACE coverage audit enabled; the first self-hosted
scheduled/nightly runner execution is still pending. The hosted workflow ignores
docs-only Markdown pushes so evidence-record updates do not consume full quick
runner time unless source, script, test, or workflow files also changed.
The GitHub worktree migration also removed several hidden local-artifact
dependencies: `run_rvtests.sh` now locates LLVM tools and rebuilds `soc_rt` from
source with `SIM_INIT`, `tests/build_run.sh` compiles objects and invokes
`ld.lld` directly instead of relying on macOS clang's `-fuse-ld=lld`, the hosted
workflow installs Homebrew's split-out `lld` formula, `rvtests/` plus `link.ld`
are present as source inputs, the small synth-shell memfile fixture is checked in
despite the general `*.hex` ignore, `build_vtop.sh` can use the structured
`sim/sim_main.cpp` harness, and missing `oss-cad-suite/` no longer causes
empty-log shell exits when system tools are on `PATH`.

`syn_top_rvlinux_synth_shell.v` wraps the same top-level shell behind 74 package IOs
for place-and-route without trimming the core, cache, PTW, MMIO, or debug-output
paths.

Synthesis/PnR evidence:
- Direct `yosys synth_rvlinux_mem_boundary.ys`: 34 DP16KD, 3098 LUT4, 1734 FF,
  384 TRELLIS_DPR16X4; `check` reports 0 problems.
- Direct `yosys synth_rvlinux_stage_cluster.ys`: 34 DP16KD, 4186 LUT4, 2289 FF,
  384 TRELLIS_DPR16X4; `check` reports 0 problems.
- Direct `yosys synth_rvlinux_min_core_fsm.ys`: 32 DP16KD, 11494 LUT4, 5446 FF,
  108 TRELLIS_DPR16X4; `check` reports 0 problems.
- Direct `yosys synth_rvlinux_synth_shell.ys`: 32 DP16KD, 10747 LUT4, 5173 FF,
  108 TRELLIS_DPR16X4; `check` reports 0 problems.
- Small-IO wrapper `syn_top_rvlinux_mem_boundary.v` for package-realistic PnR:
  `nextpnr-ecp5 --freq 50` passes on LFE5U-45F/CABGA381 with routed Fmax
  **61.61 MHz**, 34/108 DP16KD (31%), 1584 FF, and 5335 TRELLIS_COMB.
- Small-IO wrapper `syn_top_rvlinux_synth_shell.v` for the `rvlinux.v`
  `RVLINUX_SYNTH_SHELL` top path: current `yosys synth_rvlinux_synth_shell_top.ys`
  reports 32 DP16KD, 10902 LUT4, 5118 FF, 108 TRELLIS_DPR16X4, and 0 check
  problems (`logs/yosys-rvlinux-synth-shell-top-current.log`). The current
  post-fix small-IO top wrapper also passes LFE5U-85F/CABGA381
  `nextpnr-ecp5 --85k --package CABGA381 --speed 6 --seed 2 --freq 40`; the
  initial placement estimate was 38.83 MHz (fail at 40 MHz), but the final
  routed result is **53.94 MHz** (pass at 40 MHz), with 32/208 DP16KD (15%),
  5118 FF (6%), and 12682 TRELLIS_COMB (15%). The routed config is
  `rvlinux_synth_shell_current_seed2_f40.config`; the log is
  `logs/nextpnr-rvlinux-synth-shell-top-current-seed2-f40.log`.

## Honest caveats / scope
- The Linux boot runs in **simulation** (Verilator), not on FPGA silicon. The default
  `rvlinux.v` path still uses a large behavioral RAM array and a combinational PTW,
  so it remains a faithful *simulation model*. The same `rvlinux.v` file now has an
  `RVLINUX_SYNTH_SHELL` path that synthesizes through the multicycle shell and, with
  the minimal-SoC no-net rootfs, reaches Buildroot login in Verilator.
- The cache, two-client arbiters, composed split-L1 subsystem, sequential PTW,
  `rvlinux_mem_boundary.v`, decode/CSR-trap/fetch/LSU/AMO/muldiv stage controllers,
  MMIO device stage, shared stage cluster, and minimal RV32IMAC privileged multicycle
  core shell are **verified standalone** and reachable through the `rvlinux.v`
  `RVLINUX_SYNTH_SHELL` top path. They are not yet the default boot-to-shell core;
  the default single-cycle datapath still assumes 1-cycle behavioral memory.
- The minimal multicycle shell now performs translate-first PA-based MMIO dispatch,
  including S-mode virtual addresses mapped to UART/syscon. That path is now
  reachable from both Icarus tests and the Verilator `vtop` harness via
  `SYNTH_SHELL=1`, and the full soft-float OpenSBI/Linux payload reaches Linux
  early boot with S-mode UART output under that path; the old 100 MHz payload with
  default timer cadence reaches the clocksource handoff, while `MTIME_TICK_CYCLES=2`
  and `=4` diagnostics and the cleaner 400 MHz DTB/default-cadence run reach later
  network, filesystem, devtmpfs, block-layer init through `kyber`, and with the
  split TLB continue into serial, storage, IPv6, PF_PACKET, 9pnet, and DNS resolver
  registration, then into `/sbin/init` and Buildroot init scripts in a 10B-cycle run.
  The stock rootfs waits for `eth0` because this minimal SoC has no Ethernet device;
  the no-net rootfs variant removes that platform mismatch and reaches the Buildroot
  login prompt. This is not yet a full network-capable Linux platform, and the default
  single-cycle path remains the historical boot-to-shell model.
- Native misaligned-access support was deliberately **not** added (too invasive for a
  single-cycle datapath); misaligned accesses trap and are emulated. The shell boot
  avoids the pathological case by using an uncompressed initramfs.
- No FP (no F/D); userspace is soft-float `rv32imac/ilp32`.

## How to reproduce
- Full current regression: `bash verify.sh` (latest local run:
  `logs/ci-quick-20260629-010333/quick`, `pass=6 fail=0`)
- External P1 tool + Spike prefix gate: `tools/setup_riscof_env.sh` then `./verify_p1_external.sh`
- Directed tests: `for t in isa amotest mmu ctest shtest mtest utrap mprv mxr upage ifault; do bash tests/build_run.sh $t; done`
- Boot to shell: `bash build_vtop.sh linux-build/fw_payload_sf.hex && bash run_shell.sh`
- Verilator synth-shell smoke: `SYNTH_SHELL=1 MEMWORDS=4096 MEMFILE_WORDS=10 OBJ_DIR=obj_vtop_verify_synth bash build_vtop.sh tb_rvlinux_synth_shell_memfile.hex && ./obj_vtop_verify_synth/Vvtop --maxcyc=20000`
- Bounded synth-shell Linux payload smoke: `SYNTH_SHELL=1 EBREAK_HALTS=0 MEMWORDS=33554432 MEMFILE_WORDS=11718914 OBJ_DIR=obj_vtop_synth_linux_sf_sidefx bash build_vtop.sh linux-build/fw_payload_sf.hex && EXPECT_UART='buildroot login:' ./obj_vtop_synth_linux_sf_sidefx/Vvtop --maxcyc=5000000000`
- Timer-pressure diagnostic synth-shell Linux smoke: `SYNTH_SHELL=1 EBREAK_HALTS=0 MEMWORDS=33554432 MEMFILE_WORDS=11718914 MTIME_TICK_CYCLES=2 OBJ_DIR=obj_vtop_synth_linux_sf_mtime2 bash build_vtop.sh linux-build/fw_payload_sf.hex && EXPECT_UART='buildroot login:' ./obj_vtop_synth_linux_sf_mtime2/Vvtop --maxcyc=5000000000`
- Stronger timer-pressure diagnostic: `SYNTH_SHELL=1 EBREAK_HALTS=0 MEMWORDS=33554432 MEMFILE_WORDS=11718914 MTIME_TICK_CYCLES=4 OBJ_DIR=obj_vtop_synth_linux_sf_mtime4 bash build_vtop.sh linux-build/fw_payload_sf.hex && EXPECT_UART='buildroot login:' ./obj_vtop_synth_linux_sf_mtime4/Vvtop --maxcyc=5000000000`
- Generate 400 MHz DTB payload variant: `linux-build/make_timebase_payload.sh 400000000 linux-build/fw_payload_sf_tb400m`
- Platform-correct 400 MHz/default-tick synth-shell diagnostic: `SYNTH_SHELL=1 EBREAK_HALTS=0 MEMWORDS=33554432 MEMFILE_WORDS=11718914 MTIME_TICK_CYCLES=1 OBJ_DIR=obj_vtop_synth_linux_sf_tb400m bash build_vtop.sh linux-build/fw_payload_sf_tb400m.hex && EXPECT_UART='buildroot login:' ./obj_vtop_synth_linux_sf_tb400m/Vvtop --maxcyc=5000000000`
- Fast-retire 400 MHz/default-tick synth-shell diagnostic: `SYNTH_SHELL=1 EBREAK_HALTS=0 MEMWORDS=33554432 MEMFILE_WORDS=11718914 MTIME_TICK_CYCLES=1 OBJ_DIR=obj_vtop_synth_linux_sf_tb400m_fastretire bash build_vtop.sh linux-build/fw_payload_sf_tb400m.hex && EXPECT_UART='buildroot login:' ./obj_vtop_synth_linux_sf_tb400m_fastretire/Vvtop --maxcyc=5000000000`
- Fetch-overlap 400 MHz/default-tick synth-shell diagnostic: `SYNTH_SHELL=1 EBREAK_HALTS=0 MEMWORDS=33554432 MEMFILE_WORDS=11718914 MTIME_TICK_CYCLES=1 OBJ_DIR=obj_vtop_synth_linux_sf_tb400m_fetchfast bash build_vtop.sh linux-build/fw_payload_sf_tb400m.hex && EXPECT_UART='buildroot login:' ./obj_vtop_synth_linux_sf_tb400m_fetchfast/Vvtop --maxcyc=5000000000`
- Current CSR-completion-fetch 400 MHz/default-tick synth-shell diagnostic: `SYNTH_SHELL=1 EBREAK_HALTS=0 MEMWORDS=33554432 MEMFILE_WORDS=11718914 MTIME_TICK_CYCLES=1 OBJ_DIR=obj_vtop_synth_linux_sf_tb400m_csrfetch bash build_vtop.sh linux-build/fw_payload_sf_tb400m.hex && EXPECT_UART='buildroot login:' ./obj_vtop_synth_linux_sf_tb400m_csrfetch/Vvtop --maxcyc=5000000000`
- Current split-TLB 400 MHz/default-tick synth-shell diagnostic: `SYNTH_SHELL=1 EBREAK_HALTS=0 MEMWORDS=33554432 MEMFILE_WORDS=11718914 MTIME_TICK_CYCLES=1 OBJ_DIR=obj_vtop_synth_linux_sf_tb400m_tlb bash build_vtop.sh linux-build/fw_payload_sf_tb400m.hex && EXPECT_UART='buildroot login:' ./obj_vtop_synth_linux_sf_tb400m_tlb/Vvtop --maxcyc=5000000000`
- Current split-TLB 10B long run: `EXPECT_UART='buildroot login:' ./obj_vtop_synth_linux_sf_tb400m_tlb/Vvtop --maxcyc=10000000000`
- Repackage the soft-float rootfs for the minimal no-Ethernet SoC: `docker run --rm -v "$PWD/linux-build:/out" rvl-sf-img bash /out/repackage_sf_nonet.sh`
- Convert that no-net payload to hex and patch the DTB timebase to 400 MHz: `python3 bin2hex.py linux-build/fw_payload_sf_nonet.bin linux-build/fw_payload_sf_nonet.hex && SRC_BIN=linux-build/fw_payload_sf_nonet.bin linux-build/make_timebase_payload.sh 400000000 linux-build/fw_payload_sf_tb400m_nonet`
- Standard synth-shell no-net boot-to-login run: `./run_synth_shell_nonet.sh` (add `--prepare-payload` if `linux-build/fw_payload_sf_nonet.bin` is missing; add `--no-build` to reuse an existing `obj_vtop_synth_linux_sf_tb400m_nonet/Vvtop`)
- Explicit P0 Linux gate: `./verify_p0_linux.sh` for the full expensive boot-to-login run, `./verify_p0_linux.sh --smoke --reuse` for a quick OpenSBI harness/payload smoke, or `./verify_p0_linux.sh --check-logs=logs/run-synth-shell-nonet-default-login` to audit the retained full-run logs.
- Profiled CI/nightly scheduler: `./verify_ci.sh quick` for the normal regression, `./verify_ci.sh pr` for quick plus P0 smoke, `P0_SMOKE_REUSE=1 ./verify_ci.sh p0-smoke` for a reused fast P0 Linux smoke, `./verify_ci.sh p0-audit` to audit retained login logs, `./verify_ci.sh p0-pnr-audit` to audit retained current PnR evidence, `./verify_ci.sh p0-evidence` to audit retained Linux+PnR evidence together, `./verify_ci.sh p1-trace-audit` to audit retained RVTRACE/ref-model evidence and write `rvtrace_coverage.json` / `rvtrace_coverage.md`, `./verify_ci.sh evidence-health` to check retained dashboard/history evidence and write `ci_health.json` / `ci_health.md`, `./verify_ci.sh p0-pnr` for current synth-shell top yosys+nextpnr, and `./verify_ci.sh nightly` for quick + P1 + P1 trace audit + P0 smoke + P0 PnR + full P0 Linux. Every profile now writes `summary.json` and `summary.md` under its `LOGDIR` and refreshes `logs/ci-dashboard.json`, `logs/ci-dashboard.md`, `logs/ci-history.jsonl`, and `logs/ci-trend.md`; the dashboard and trend history can also be regenerated manually with `python3 tools/render_ci_dashboard.py --root logs`.
- Automation wrappers: GitHub hosted quick CI is `.github/workflows/ci.yml`, self-hosted nightly CI is `.github/workflows/nightly.yml`, and local cron/launchd can use `tools/ci_cron.sh nightly` (for example `0 1 * * * cd /Users/Apple/riscv-rv32i-core && tools/ci_cron.sh nightly`), `tools/ci_cron.sh p0-evidence` for low-cost P0 evidence audits, `tools/ci_cron.sh p1-trace-audit` for retained P1 trace audits, or `tools/ci_cron.sh evidence-health` for cheap retained-evidence health checks between expensive runs.
- WFI timer regression: `iverilog -g2012 -o /tmp/tb_rvlinux_min_core_wfi_timer cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_fetch_stage.v rvlinux_lsu_stage.v rvlinux_amo_stage.v rvlinux_stage_cluster.v rvlinux_decode_stage.v rvlinux_csr_trap_stage.v rvlinux_muldiv_stage.v rvlinux_mmio_stage.v rvlinux_min_core_fsm.v tb_rvlinux_min_core_wfi_timer.v && vvp /tmp/tb_rvlinux_min_core_wfi_timer`
- CLINT/CSR time regression: `iverilog -g2012 -o /tmp/tb_rvlinux_min_core_time_csr cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_fetch_stage.v rvlinux_lsu_stage.v rvlinux_amo_stage.v rvlinux_stage_cluster.v rvlinux_decode_stage.v rvlinux_csr_trap_stage.v rvlinux_muldiv_stage.v rvlinux_mmio_stage.v rvlinux_min_core_fsm.v tb_rvlinux_min_core_time_csr.v && vvp /tmp/tb_rvlinux_min_core_time_csr`
- Side-effect interrupt replay regression: `iverilog -g2012 -o /tmp/tb_rvlinux_min_core_interrupt_side_effect cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_fetch_stage.v rvlinux_lsu_stage.v rvlinux_amo_stage.v rvlinux_stage_cluster.v rvlinux_decode_stage.v rvlinux_csr_trap_stage.v rvlinux_muldiv_stage.v rvlinux_mmio_stage.v rvlinux_min_core_fsm.v tb_rvlinux_min_core_interrupt_side_effect.v && vvp /tmp/tb_rvlinux_min_core_interrupt_side_effect`
- Cache/memory-boundary tests: `iverilog -g2012 -o /tmp/tb_cache cache.v slowmem.v tb_cache.v && vvp /tmp/tb_cache`; `iverilog -g2012 -o /tmp/tb_mem_arbiter mem_arbiter2.v slowmem.v tb_mem_arbiter.v && vvp /tmp/tb_mem_arbiter`; `iverilog -g2012 -o /tmp/tb_l1_mem_system cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v tb_l1_mem_system.v && vvp /tmp/tb_l1_mem_system`; `iverilog -g2012 -o /tmp/tb_sv32_ptw sv32_ptw.v tb_sv32_ptw.v && vvp /tmp/tb_sv32_ptw`; `iverilog -g2012 -o /tmp/tb_ptw_dcache cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v tb_ptw_dcache.v && vvp /tmp/tb_ptw_dcache`; `iverilog -g2012 -o /tmp/tb_rvlinux_decode_stage rvlinux_decode_stage.v tb_rvlinux_decode_stage.v && vvp /tmp/tb_rvlinux_decode_stage`; `iverilog -g2012 -o /tmp/tb_rvlinux_csr_trap_stage rvlinux_csr_trap_stage.v tb_rvlinux_csr_trap_stage.v && vvp /tmp/tb_rvlinux_csr_trap_stage`; `iverilog -g2012 -o /tmp/tb_rvlinux_muldiv_stage rvlinux_muldiv_stage.v tb_rvlinux_muldiv_stage.v && vvp /tmp/tb_rvlinux_muldiv_stage`; `iverilog -g2012 -o /tmp/tb_rvlinux_mmio_stage rvlinux_mmio_stage.v tb_rvlinux_mmio_stage.v && vvp /tmp/tb_rvlinux_mmio_stage`; `iverilog -g2012 -o /tmp/tb_rvlinux_mem_boundary cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v tb_rvlinux_mem_boundary.v && vvp /tmp/tb_rvlinux_mem_boundary`; `iverilog -g2012 -o /tmp/tb_rvlinux_fetch_stage cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_fetch_stage.v tb_rvlinux_fetch_stage.v && vvp /tmp/tb_rvlinux_fetch_stage`; `iverilog -g2012 -o /tmp/tb_rvlinux_lsu_stage cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_lsu_stage.v tb_rvlinux_lsu_stage.v && vvp /tmp/tb_rvlinux_lsu_stage`; `iverilog -g2012 -o /tmp/tb_rvlinux_amo_stage cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_amo_stage.v tb_rvlinux_amo_stage.v && vvp /tmp/tb_rvlinux_amo_stage`; `iverilog -g2012 -o /tmp/tb_rvlinux_stage_cluster cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_fetch_stage.v rvlinux_lsu_stage.v rvlinux_amo_stage.v rvlinux_stage_cluster.v tb_rvlinux_stage_cluster.v && vvp /tmp/tb_rvlinux_stage_cluster`; `iverilog -g2012 -o /tmp/tb_rvlinux_min_core_fsm cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_fetch_stage.v rvlinux_lsu_stage.v rvlinux_amo_stage.v rvlinux_stage_cluster.v rvlinux_decode_stage.v rvlinux_csr_trap_stage.v rvlinux_muldiv_stage.v rvlinux_mmio_stage.v rvlinux_min_core_fsm.v tb_rvlinux_min_core_fsm.v && vvp /tmp/tb_rvlinux_min_core_fsm`; `iverilog -g2012 -o /tmp/tb_rvlinux_min_core_priv cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_fetch_stage.v rvlinux_lsu_stage.v rvlinux_amo_stage.v rvlinux_stage_cluster.v rvlinux_decode_stage.v rvlinux_csr_trap_stage.v rvlinux_muldiv_stage.v rvlinux_mmio_stage.v rvlinux_min_core_fsm.v tb_rvlinux_min_core_priv.v && vvp /tmp/tb_rvlinux_min_core_priv`; `iverilog -g2012 -o /tmp/tb_rvlinux_min_core_mmio cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_fetch_stage.v rvlinux_lsu_stage.v rvlinux_amo_stage.v rvlinux_stage_cluster.v rvlinux_decode_stage.v rvlinux_csr_trap_stage.v rvlinux_muldiv_stage.v rvlinux_mmio_stage.v rvlinux_min_core_fsm.v tb_rvlinux_min_core_mmio.v && vvp /tmp/tb_rvlinux_min_core_mmio`; `iverilog -g2012 -o /tmp/tb_rvlinux_min_core_translated_mmio cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_fetch_stage.v rvlinux_lsu_stage.v rvlinux_amo_stage.v rvlinux_stage_cluster.v rvlinux_decode_stage.v rvlinux_csr_trap_stage.v rvlinux_muldiv_stage.v rvlinux_mmio_stage.v rvlinux_min_core_fsm.v tb_rvlinux_min_core_translated_mmio.v && vvp /tmp/tb_rvlinux_min_core_translated_mmio`; `iverilog -g2012 -D RVLINUX_SYNTH_SHELL -o /tmp/tb_rvlinux_synth_shell cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_fetch_stage.v rvlinux_lsu_stage.v rvlinux_amo_stage.v rvlinux_stage_cluster.v rvlinux_decode_stage.v rvlinux_csr_trap_stage.v rvlinux_muldiv_stage.v rvlinux_mmio_stage.v rvlinux_min_core_fsm.v rvlinux.v tb_rvlinux_synth_shell.v && vvp /tmp/tb_rvlinux_synth_shell`
- Top shell CSR/debug smoke: `iverilog -g2012 -D RVLINUX_SYNTH_SHELL -o /tmp/tb_rvlinux_synth_shell_debug cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_fetch_stage.v rvlinux_lsu_stage.v rvlinux_amo_stage.v rvlinux_stage_cluster.v rvlinux_decode_stage.v rvlinux_csr_trap_stage.v rvlinux_muldiv_stage.v rvlinux_mmio_stage.v rvlinux_min_core_fsm.v rvlinux.v tb_rvlinux_synth_shell_debug.v && vvp /tmp/tb_rvlinux_synth_shell_debug`
- Top shell delegated UART/PLIC interrupt smoke: `iverilog -g2012 -D RVLINUX_SYNTH_SHELL -o /tmp/tb_rvlinux_synth_shell_interrupt cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_fetch_stage.v rvlinux_lsu_stage.v rvlinux_amo_stage.v rvlinux_stage_cluster.v rvlinux_decode_stage.v rvlinux_csr_trap_stage.v rvlinux_muldiv_stage.v rvlinux_mmio_stage.v rvlinux_min_core_fsm.v rvlinux.v tb_rvlinux_synth_shell_interrupt.v && vvp /tmp/tb_rvlinux_synth_shell_interrupt`
- Top shell STIP smoke: `iverilog -g2012 -D RVLINUX_SYNTH_SHELL -o /tmp/tb_rvlinux_synth_shell_stip cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_fetch_stage.v rvlinux_lsu_stage.v rvlinux_amo_stage.v rvlinux_stage_cluster.v rvlinux_decode_stage.v rvlinux_csr_trap_stage.v rvlinux_muldiv_stage.v rvlinux_mmio_stage.v rvlinux_min_core_fsm.v rvlinux.v tb_rvlinux_synth_shell_stip.v && vvp /tmp/tb_rvlinux_synth_shell_stip`
- Top shell MEMFILE/RAMBASE smoke: `iverilog -g2012 -D RVLINUX_SYNTH_SHELL -D SIM_INIT -o /tmp/tb_rvlinux_synth_shell_memfile cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_fetch_stage.v rvlinux_lsu_stage.v rvlinux_amo_stage.v rvlinux_stage_cluster.v rvlinux_decode_stage.v rvlinux_csr_trap_stage.v rvlinux_muldiv_stage.v rvlinux_mmio_stage.v rvlinux_min_core_fsm.v rvlinux.v tb_rvlinux_synth_shell_memfile.v && vvp /tmp/tb_rvlinux_synth_shell_memfile`
- MPRV/data-privilege smoke: `iverilog -g2012 -o /tmp/tb_rvlinux_min_core_mprv cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_fetch_stage.v rvlinux_lsu_stage.v rvlinux_amo_stage.v rvlinux_stage_cluster.v rvlinux_decode_stage.v rvlinux_csr_trap_stage.v rvlinux_muldiv_stage.v rvlinux_mmio_stage.v rvlinux_min_core_fsm.v tb_rvlinux_min_core_mprv.v && vvp /tmp/tb_rvlinux_min_core_mprv`
- Delegated UART/PLIC interrupt smoke: `iverilog -g2012 -o /tmp/tb_rvlinux_min_core_interrupt cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_fetch_stage.v rvlinux_lsu_stage.v rvlinux_amo_stage.v rvlinux_stage_cluster.v rvlinux_decode_stage.v rvlinux_csr_trap_stage.v rvlinux_muldiv_stage.v rvlinux_mmio_stage.v rvlinux_min_core_fsm.v tb_rvlinux_min_core_interrupt.v && vvp /tmp/tb_rvlinux_min_core_interrupt`
- Synthesis/PnR: `yosys synth_rvcore.ys` / `yosys syn_top_cache.v cache.v` / `yosys synth_mem_arbiter.ys` / `yosys synth_l1_mem_system.ys` / `yosys synth_l1_mem_system_top.ys` / `yosys synth_sv32_ptw.ys` / `yosys synth_rvlinux_decode_stage.ys` / `yosys synth_rvlinux_csr_trap_stage.ys` / `yosys synth_rvlinux_muldiv_stage.ys` / `yosys synth_rvlinux_mmio_stage.ys` / `yosys synth_rvlinux_mem_boundary.ys` / `yosys synth_rvlinux_mem_boundary_top.ys` / `yosys synth_rvlinux_fetch_stage.ys` / `yosys synth_rvlinux_lsu_stage.ys` / `yosys synth_rvlinux_amo_stage.ys` / `yosys synth_rvlinux_stage_cluster.ys` / `yosys synth_rvlinux_min_core_fsm.ys` / `yosys synth_rvlinux_synth_shell.ys` / `yosys synth_rvlinux_synth_shell_top.ys`; L1 PnR smoke: `nextpnr-ecp5 --45k --package CABGA381 --speed 6 --json syn_top_l1_mem_system.json --textcfg l1_mem_system.config --freq 50`; rvlinux boundary PnR smoke: `nextpnr-ecp5 --45k --package CABGA381 --speed 6 --json syn_top_rvlinux_mem_boundary.json --textcfg rvlinux_mem_boundary.config --freq 50`; rvlinux shell PnR smoke: `nextpnr-ecp5 --85k --package CABGA381 --speed 6 --seed 2 --json syn_top_rvlinux_synth_shell.json --textcfg rvlinux_synth_shell_current_seed2_f40.config --freq 40`

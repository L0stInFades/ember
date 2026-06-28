# Ember ACT/Spike Smoke Config

This directory holds the minimal DUT-side configuration used by
`tools/run_act4_spike_smoke.sh`.

The smoke uses upstream ACT4 `riscv-arch-test` RV32I assembly tests, generates
expected signatures with Spike, recompiles the tests in ACT self-check mode, and
runs the resulting ELFs on the Ember RTL testbench.

It is intentionally narrower than full ACT4/UDB certification: the default gate
runs the pinned upstream RV32 `I`, `M`, `Zmmul`, `Zaamo`, `Zalrsc`, `Zca`,
`Zicsr`, `Zicntr`, `Zifencei`, `Zihintpause`, `Zihintntl`, and
`ZihintntlZca` assembly tests, but not generated UDB flows or the full
implemented extension matrix. `Zihpm` remains excluded because Ember does not
implement the optional HPM counter CSR bank. `Misalign` and `MisalignZca` remain
excluded because those upstream groups are tagged `MISALIGNED_LDST: true` and
validate successful non-aligned load/store behavior; Ember currently implements
precise misaligned-access traps instead.

`tools/run_act4_spike_smoke.sh` emits `P1_ACT4_SPIKE_TESTS`,
`P1_ACT4_SPIKE_GROUPS`, and `P1_ACT4_SPIKE_GROUP_COUNTS` so retained summaries
and the dashboard health gate can verify the exact default selected test list,
group composition, and per-group test counts, not just the total number of
passing ACT/Spike tests.

The upstream `Zicsr` tests use no-`C` MARCH metadata, but Ember decodes
compressed instructions and advertises `misa.C`. The smoke therefore runs that
group with the C-aware `rv32i_zicsr_zifencei_zca` reference ISA by default so
Spike and the DUT agree on `mepc`/`sepc` WARL low-bit behavior.

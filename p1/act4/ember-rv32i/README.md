# Ember ACT/Spike Smoke Config

This directory holds the minimal DUT-side configuration used by
`tools/run_act4_spike_smoke.sh`.

The smoke uses upstream ACT4 `riscv-arch-test` RV32I assembly tests, generates
expected signatures with Spike, recompiles the tests in ACT self-check mode, and
runs the resulting ELFs on the Ember RTL testbench.

It is intentionally narrower than full ACT4/UDB certification: the default gate
runs the pinned upstream RV32I `I` assembly tests, but not generated UDB flows or
the full implemented extension matrix.

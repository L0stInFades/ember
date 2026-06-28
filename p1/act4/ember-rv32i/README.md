# Ember ACT/Spike Smoke Config

This directory holds the minimal DUT-side configuration used by
`tools/run_act4_spike_smoke.sh`.

The smoke uses upstream ACT4 `riscv-arch-test` RV32I assembly tests, generates
expected signatures with Spike, recompiles the tests in ACT self-check mode, and
runs the resulting ELFs on the Ember RTL testbench.

It is intentionally narrower than full ACT4/UDB certification: the default gate
runs the pinned upstream RV32 `I`, `M`, `Zaamo`, `Zalrsc`, `Zca`, and `Zifencei`
assembly tests, but not generated UDB flows or the full implemented extension
matrix.

The upstream `Zicsr` group is kept out of the default smoke for now. Those tests
currently use no-`C` MARCH metadata while this DUT decodes compressed
instructions, which makes the `mepc`/`sepc` WARL low-bit expectation an explicit
follow-up bug instead of something to hide by widening the smoke set.

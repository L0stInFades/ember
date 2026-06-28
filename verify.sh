#!/usr/bin/env bash
# One-command regression entry point for the current P1 verification baseline.
set -uo pipefail

cd "$(dirname "$0")"

LOGDIR=${LOGDIR:-logs/verify-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$LOGDIR"
export LOGDIR

pass=0
fail=0

run_step() {
  local name=$1
  shift
  local log="$LOGDIR/$name.log"

  printf '=== %-14s ===\n' "$name"
  if "$@" >"$log" 2>&1; then
    printf 'PASS %-14s log=%s\n' "$name" "$log"
    pass=$((pass+1))
  else
    local code=$?
    printf 'FAIL %-14s exit=%d log=%s\n' "$name" "$code" "$log"
    tail -n 80 "$log"
    fail=$((fail+1))
  fi
}

run_step directed bash -lc '
  set -euo pipefail
  for t in isa amotest mmu ctest shtest mtest utrap mprv mxr upage ifault wpfault sum badpte superpage amo_mmu; do
    echo "=== $t ==="
    LOG=/tmp/tb_${t}.log bash tests/build_run.sh "$t"
  done
'

run_step rvtests bash run_rvtests.sh

run_step trace bash -lc '
  set -euo pipefail
  for t in isa amotest mmu ctest shtest mtest utrap mprv mxr upage ifault wpfault sum badpte superpage amo_mmu; do
    echo "=== trace $t ==="
    rm -f rvtrace.log "$LOGDIR/rvtrace_${t}.csv"
    LOG=/tmp/tb_trace_${t}.log EXTRA_IVERILOG_FLAGS="-D RVTRACE" bash tests/build_run.sh "$t"
    test -s rvtrace.log
    mv rvtrace.log "$LOGDIR/rvtrace_${t}.csv"
    trap_arg="--no-trap"
    case "$t" in
      mmu|utrap|mprv|mxr|upage|ifault|wpfault|sum|badpte|superpage|amo_mmu) trap_arg="" ;;
    esac
    python3 tools/check_rvtrace.py \
      --trace "$LOGDIR/rvtrace_${t}.csv" \
      --hex "tests/${t}.hex" \
      --base 0x80000000 \
      --min-ret 1 \
      $trap_arg
  done
'

run_step reftrace bash -lc '
  set -euo pipefail
  for t in isa amotest mmu ctest shtest mtest utrap mprv mxr upage ifault wpfault sum badpte superpage amo_mmu; do
    echo "=== reftrace $t ==="
    priv_arg="--expect-priv 3"
    case "$t" in
      mmu|utrap|mprv|mxr|upage|ifault|wpfault|sum|badpte|superpage|amo_mmu) priv_arg="" ;;
    esac
    python3 tools/rvtrace_ref.py \
      --trace "$LOGDIR/rvtrace_${t}.csv" \
      --hex "tests/${t}.hex" \
      --base 0x80000000 \
      $priv_arg
  done
'

run_step cache bash -lc '
  set -euo pipefail
  if [ -f oss-cad-suite/environment ]; then
    source oss-cad-suite/environment
  fi
  iverilog -g2012 -o /tmp/tb_cache cache.v slowmem.v tb_cache.v
  vvp /tmp/tb_cache | tee /tmp/tb_cache.log
  grep -q "CACHE_RESULT: PASS" /tmp/tb_cache.log
  iverilog -g2012 -o /tmp/tb_mem_arbiter mem_arbiter2.v slowmem.v tb_mem_arbiter.v
  vvp /tmp/tb_mem_arbiter | tee /tmp/tb_mem_arbiter.log
  grep -q "ARB_RESULT: PASS" /tmp/tb_mem_arbiter.log
  iverilog -g2012 -o /tmp/tb_l1_mem_system cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v tb_l1_mem_system.v
  vvp /tmp/tb_l1_mem_system | tee /tmp/tb_l1_mem_system.log
  grep -q "L1MEM_RESULT: PASS" /tmp/tb_l1_mem_system.log
  iverilog -g2012 -o /tmp/tb_sv32_ptw sv32_ptw.v tb_sv32_ptw.v
  vvp /tmp/tb_sv32_ptw | tee /tmp/tb_sv32_ptw.log
  grep -q "PTW_RESULT: PASS" /tmp/tb_sv32_ptw.log
  iverilog -g2012 -o /tmp/tb_ptw_dcache cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v tb_ptw_dcache.v
  vvp /tmp/tb_ptw_dcache | tee /tmp/tb_ptw_dcache.log
  grep -q "PTW_DCACHE_RESULT: PASS" /tmp/tb_ptw_dcache.log
  iverilog -g2012 -o /tmp/tb_rvlinux_decode_stage rvlinux_decode_stage.v tb_rvlinux_decode_stage.v
  vvp /tmp/tb_rvlinux_decode_stage | tee /tmp/tb_rvlinux_decode_stage.log
  grep -q "DECODE_STAGE_RESULT: PASS" /tmp/tb_rvlinux_decode_stage.log
  iverilog -g2012 -o /tmp/tb_rvlinux_csr_trap_stage rvlinux_csr_trap_stage.v tb_rvlinux_csr_trap_stage.v
  vvp /tmp/tb_rvlinux_csr_trap_stage | tee /tmp/tb_rvlinux_csr_trap_stage.log
  grep -q "CSR_STAGE_RESULT: PASS" /tmp/tb_rvlinux_csr_trap_stage.log
  iverilog -g2012 -o /tmp/tb_rvlinux_muldiv_stage rvlinux_muldiv_stage.v tb_rvlinux_muldiv_stage.v
  vvp /tmp/tb_rvlinux_muldiv_stage | tee /tmp/tb_rvlinux_muldiv_stage.log
  grep -q "MULDIV_RESULT: PASS" /tmp/tb_rvlinux_muldiv_stage.log
  iverilog -g2012 -o /tmp/tb_rvlinux_mmio_stage rvlinux_mmio_stage.v tb_rvlinux_mmio_stage.v
  vvp /tmp/tb_rvlinux_mmio_stage | tee /tmp/tb_rvlinux_mmio_stage.log
  grep -q "MMIO_STAGE_RESULT: PASS" /tmp/tb_rvlinux_mmio_stage.log
  iverilog -g2012 -o /tmp/tb_rvlinux_mem_boundary cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v tb_rvlinux_mem_boundary.v
  vvp /tmp/tb_rvlinux_mem_boundary | tee /tmp/tb_rvlinux_mem_boundary.log
  grep -q "MEM_BOUNDARY_RESULT: PASS" /tmp/tb_rvlinux_mem_boundary.log
  iverilog -g2012 -o /tmp/tb_rvlinux_fetch_stage cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_fetch_stage.v tb_rvlinux_fetch_stage.v
  vvp /tmp/tb_rvlinux_fetch_stage | tee /tmp/tb_rvlinux_fetch_stage.log
  grep -q "FETCH_STAGE_RESULT: PASS" /tmp/tb_rvlinux_fetch_stage.log
  iverilog -g2012 -o /tmp/tb_rvlinux_lsu_stage cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_lsu_stage.v tb_rvlinux_lsu_stage.v
  vvp /tmp/tb_rvlinux_lsu_stage | tee /tmp/tb_rvlinux_lsu_stage.log
  grep -q "LSU_STAGE_RESULT: PASS" /tmp/tb_rvlinux_lsu_stage.log
  iverilog -g2012 -o /tmp/tb_rvlinux_amo_stage cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_amo_stage.v tb_rvlinux_amo_stage.v
  vvp /tmp/tb_rvlinux_amo_stage | tee /tmp/tb_rvlinux_amo_stage.log
  grep -q "AMO_STAGE_RESULT: PASS" /tmp/tb_rvlinux_amo_stage.log
  iverilog -g2012 -o /tmp/tb_rvlinux_stage_cluster cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_fetch_stage.v rvlinux_lsu_stage.v rvlinux_amo_stage.v rvlinux_stage_cluster.v tb_rvlinux_stage_cluster.v
  vvp /tmp/tb_rvlinux_stage_cluster | tee /tmp/tb_rvlinux_stage_cluster.log
  grep -q "STAGE_CLUSTER_RESULT: PASS" /tmp/tb_rvlinux_stage_cluster.log
  iverilog -g2012 -o /tmp/tb_rvlinux_min_core_fsm cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_fetch_stage.v rvlinux_lsu_stage.v rvlinux_amo_stage.v rvlinux_stage_cluster.v rvlinux_decode_stage.v rvlinux_csr_trap_stage.v rvlinux_muldiv_stage.v rvlinux_mmio_stage.v rvlinux_min_core_fsm.v tb_rvlinux_min_core_fsm.v
  vvp /tmp/tb_rvlinux_min_core_fsm | tee /tmp/tb_rvlinux_min_core_fsm.log
  grep -q "MIN_CORE_RESULT: PASS" /tmp/tb_rvlinux_min_core_fsm.log
  iverilog -g2012 -o /tmp/tb_rvlinux_min_core_wfi_timer cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_fetch_stage.v rvlinux_lsu_stage.v rvlinux_amo_stage.v rvlinux_stage_cluster.v rvlinux_decode_stage.v rvlinux_csr_trap_stage.v rvlinux_muldiv_stage.v rvlinux_mmio_stage.v rvlinux_min_core_fsm.v tb_rvlinux_min_core_wfi_timer.v
  vvp /tmp/tb_rvlinux_min_core_wfi_timer | tee /tmp/tb_rvlinux_min_core_wfi_timer.log
  grep -q "MIN_CORE_WFI_TIMER_RESULT: PASS" /tmp/tb_rvlinux_min_core_wfi_timer.log
  iverilog -g2012 -o /tmp/tb_rvlinux_min_core_time_csr cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_fetch_stage.v rvlinux_lsu_stage.v rvlinux_amo_stage.v rvlinux_stage_cluster.v rvlinux_decode_stage.v rvlinux_csr_trap_stage.v rvlinux_muldiv_stage.v rvlinux_mmio_stage.v rvlinux_min_core_fsm.v tb_rvlinux_min_core_time_csr.v
  vvp /tmp/tb_rvlinux_min_core_time_csr | tee /tmp/tb_rvlinux_min_core_time_csr.log
  grep -q "MIN_CORE_TIME_CSR_RESULT: PASS" /tmp/tb_rvlinux_min_core_time_csr.log
  iverilog -g2012 -o /tmp/tb_rvlinux_min_core_interrupt_side_effect cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_fetch_stage.v rvlinux_lsu_stage.v rvlinux_amo_stage.v rvlinux_stage_cluster.v rvlinux_decode_stage.v rvlinux_csr_trap_stage.v rvlinux_muldiv_stage.v rvlinux_mmio_stage.v rvlinux_min_core_fsm.v tb_rvlinux_min_core_interrupt_side_effect.v
  vvp /tmp/tb_rvlinux_min_core_interrupt_side_effect | tee /tmp/tb_rvlinux_min_core_interrupt_side_effect.log
  grep -q "MIN_CORE_INTERRUPT_SIDE_EFFECT_RESULT: PASS" /tmp/tb_rvlinux_min_core_interrupt_side_effect.log
  iverilog -g2012 -o /tmp/tb_rvlinux_min_core_priv cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_fetch_stage.v rvlinux_lsu_stage.v rvlinux_amo_stage.v rvlinux_stage_cluster.v rvlinux_decode_stage.v rvlinux_csr_trap_stage.v rvlinux_muldiv_stage.v rvlinux_mmio_stage.v rvlinux_min_core_fsm.v tb_rvlinux_min_core_priv.v
  vvp /tmp/tb_rvlinux_min_core_priv | tee /tmp/tb_rvlinux_min_core_priv.log
  grep -q "PRIV_CORE_RESULT: PASS" /tmp/tb_rvlinux_min_core_priv.log
  iverilog -g2012 -o /tmp/tb_rvlinux_min_core_mmio cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_fetch_stage.v rvlinux_lsu_stage.v rvlinux_amo_stage.v rvlinux_stage_cluster.v rvlinux_decode_stage.v rvlinux_csr_trap_stage.v rvlinux_muldiv_stage.v rvlinux_mmio_stage.v rvlinux_min_core_fsm.v tb_rvlinux_min_core_mmio.v
  vvp /tmp/tb_rvlinux_min_core_mmio | tee /tmp/tb_rvlinux_min_core_mmio.log
  grep -q "MIN_CORE_MMIO_RESULT: PASS" /tmp/tb_rvlinux_min_core_mmio.log
  iverilog -g2012 -o /tmp/tb_rvlinux_min_core_translated_mmio cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_fetch_stage.v rvlinux_lsu_stage.v rvlinux_amo_stage.v rvlinux_stage_cluster.v rvlinux_decode_stage.v rvlinux_csr_trap_stage.v rvlinux_muldiv_stage.v rvlinux_mmio_stage.v rvlinux_min_core_fsm.v tb_rvlinux_min_core_translated_mmio.v
  vvp /tmp/tb_rvlinux_min_core_translated_mmio | tee /tmp/tb_rvlinux_min_core_translated_mmio.log
  grep -q "MIN_CORE_TRANSLATED_MMIO_RESULT: PASS" /tmp/tb_rvlinux_min_core_translated_mmio.log
  iverilog -g2012 -o /tmp/tb_rvlinux_min_core_mprv cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_fetch_stage.v rvlinux_lsu_stage.v rvlinux_amo_stage.v rvlinux_stage_cluster.v rvlinux_decode_stage.v rvlinux_csr_trap_stage.v rvlinux_muldiv_stage.v rvlinux_mmio_stage.v rvlinux_min_core_fsm.v tb_rvlinux_min_core_mprv.v
  vvp /tmp/tb_rvlinux_min_core_mprv | tee /tmp/tb_rvlinux_min_core_mprv.log
  grep -q "MIN_CORE_MPRV_RESULT: PASS" /tmp/tb_rvlinux_min_core_mprv.log
  iverilog -g2012 -o /tmp/tb_rvlinux_min_core_ebreak_trap cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_fetch_stage.v rvlinux_lsu_stage.v rvlinux_amo_stage.v rvlinux_stage_cluster.v rvlinux_decode_stage.v rvlinux_csr_trap_stage.v rvlinux_muldiv_stage.v rvlinux_mmio_stage.v rvlinux_min_core_fsm.v tb_rvlinux_min_core_ebreak_trap.v
  vvp /tmp/tb_rvlinux_min_core_ebreak_trap | tee /tmp/tb_rvlinux_min_core_ebreak_trap.log
  grep -q "MIN_CORE_EBREAK_TRAP_RESULT: PASS" /tmp/tb_rvlinux_min_core_ebreak_trap.log
  iverilog -g2012 -o /tmp/tb_rvlinux_min_core_interrupt cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_fetch_stage.v rvlinux_lsu_stage.v rvlinux_amo_stage.v rvlinux_stage_cluster.v rvlinux_decode_stage.v rvlinux_csr_trap_stage.v rvlinux_muldiv_stage.v rvlinux_mmio_stage.v rvlinux_min_core_fsm.v tb_rvlinux_min_core_interrupt.v
  vvp /tmp/tb_rvlinux_min_core_interrupt | tee /tmp/tb_rvlinux_min_core_interrupt.log
  grep -q "MIN_CORE_INTERRUPT_RESULT: PASS" /tmp/tb_rvlinux_min_core_interrupt.log
  iverilog -g2012 -o /tmp/tb_rvlinux_timebase_param rvlinux.v tb_rvlinux_timebase_param.v
  vvp /tmp/tb_rvlinux_timebase_param | tee /tmp/tb_rvlinux_timebase_param.log
  grep -q "RVLINUX_TIMEBASE_PARAM_RESULT: PASS" /tmp/tb_rvlinux_timebase_param.log
  iverilog -g2012 -D RVLINUX_SYNTH_SHELL -o /tmp/tb_rvlinux_synth_shell cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_fetch_stage.v rvlinux_lsu_stage.v rvlinux_amo_stage.v rvlinux_stage_cluster.v rvlinux_decode_stage.v rvlinux_csr_trap_stage.v rvlinux_muldiv_stage.v rvlinux_mmio_stage.v rvlinux_min_core_fsm.v rvlinux.v tb_rvlinux_synth_shell.v
  vvp /tmp/tb_rvlinux_synth_shell | tee /tmp/tb_rvlinux_synth_shell.log
  grep -q "RVLINUX_SYNTH_SHELL_RESULT: PASS" /tmp/tb_rvlinux_synth_shell.log
  iverilog -g2012 -D RVLINUX_SYNTH_SHELL -o /tmp/tb_rvlinux_synth_shell_debug cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_fetch_stage.v rvlinux_lsu_stage.v rvlinux_amo_stage.v rvlinux_stage_cluster.v rvlinux_decode_stage.v rvlinux_csr_trap_stage.v rvlinux_muldiv_stage.v rvlinux_mmio_stage.v rvlinux_min_core_fsm.v rvlinux.v tb_rvlinux_synth_shell_debug.v
  vvp /tmp/tb_rvlinux_synth_shell_debug | tee /tmp/tb_rvlinux_synth_shell_debug.log
  grep -q "RVLINUX_SYNTH_SHELL_DEBUG_RESULT: PASS" /tmp/tb_rvlinux_synth_shell_debug.log
  iverilog -g2012 -D RVLINUX_SYNTH_SHELL -o /tmp/tb_rvlinux_synth_shell_interrupt cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_fetch_stage.v rvlinux_lsu_stage.v rvlinux_amo_stage.v rvlinux_stage_cluster.v rvlinux_decode_stage.v rvlinux_csr_trap_stage.v rvlinux_muldiv_stage.v rvlinux_mmio_stage.v rvlinux_min_core_fsm.v rvlinux.v tb_rvlinux_synth_shell_interrupt.v
  vvp /tmp/tb_rvlinux_synth_shell_interrupt | tee /tmp/tb_rvlinux_synth_shell_interrupt.log
  grep -q "RVLINUX_SYNTH_SHELL_INTERRUPT_RESULT: PASS" /tmp/tb_rvlinux_synth_shell_interrupt.log
  iverilog -g2012 -D RVLINUX_SYNTH_SHELL -o /tmp/tb_rvlinux_synth_shell_stip cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_fetch_stage.v rvlinux_lsu_stage.v rvlinux_amo_stage.v rvlinux_stage_cluster.v rvlinux_decode_stage.v rvlinux_csr_trap_stage.v rvlinux_muldiv_stage.v rvlinux_mmio_stage.v rvlinux_min_core_fsm.v rvlinux.v tb_rvlinux_synth_shell_stip.v
  vvp /tmp/tb_rvlinux_synth_shell_stip | tee /tmp/tb_rvlinux_synth_shell_stip.log
  grep -q "RVLINUX_SYNTH_SHELL_STIP_RESULT: PASS" /tmp/tb_rvlinux_synth_shell_stip.log
  iverilog -g2012 -D RVLINUX_SYNTH_SHELL -D SIM_INIT -o /tmp/tb_rvlinux_synth_shell_memfile cache.v cache_client_arbiter2.v mem_arbiter2.v slowmem.v l1_mem_system.v sv32_ptw.v rvlinux_mem_boundary.v rvlinux_fetch_stage.v rvlinux_lsu_stage.v rvlinux_amo_stage.v rvlinux_stage_cluster.v rvlinux_decode_stage.v rvlinux_csr_trap_stage.v rvlinux_muldiv_stage.v rvlinux_mmio_stage.v rvlinux_min_core_fsm.v rvlinux.v tb_rvlinux_synth_shell_memfile.v
  vvp /tmp/tb_rvlinux_synth_shell_memfile | tee /tmp/tb_rvlinux_synth_shell_memfile.log
  grep -q "RVLINUX_SYNTH_SHELL_MEMFILE_RESULT: PASS" /tmp/tb_rvlinux_synth_shell_memfile.log
'

run_step vtop_synth bash -lc '
  set -euo pipefail
  rm -rf obj_vtop_verify_synth
  SYNTH_SHELL=1 MEMWORDS=4096 MEMFILE_WORDS=10 OBJ_DIR=obj_vtop_verify_synth \
    bash build_vtop.sh tb_rvlinux_synth_shell_memfile.hex
  ./obj_vtop_verify_synth/Vvtop --maxcyc=20000 | tee /tmp/vtop_synth_shell_smoke.log
  grep -q "^D$" /tmp/vtop_synth_shell_smoke.log
  grep -q "\[VSIM\] halt exit=0 after" /tmp/vtop_synth_shell_smoke.log
'

printf '\nSummary: pass=%d fail=%d logdir=%s\n' "$pass" "$fail" "$LOGDIR"
if [ "$fail" -ne 0 ]; then
  exit 1
fi

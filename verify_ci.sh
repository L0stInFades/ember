#!/usr/bin/env bash
# Profile-based regression scheduler for local CI/nightly use.
set -uo pipefail

cd "$(dirname "$0")"

usage() {
  cat >&2 <<'EOF'
usage: ./verify_ci.sh [profile]

Profiles:
  quick       Run the normal directed/P1 baseline: ./verify.sh
  pr          Run quick plus the P0 Linux OpenSBI smoke gate.
  p0-smoke    Run only the fast P0 Linux OpenSBI smoke gate.
  p0-audit    Audit retained full P0 Linux login logs without simulation.
  p0-pnr-audit
              Audit retained RVLINUX_SYNTH_SHELL top yosys+nextpnr evidence.
  p0-evidence Audit retained P0 Linux login logs plus retained P0 PnR evidence.
  p0-full     Run the full P0 Linux no-net boot-to-login gate.
  p0-pnr      Rerun current RVLINUX_SYNTH_SHELL top yosys+nextpnr at 40 MHz.
  p1          Run the external P1 tool/Spike-prefix gate.
  p1-trace-audit
              Audit retained RVTRACE CSVs through check_rvtrace + rvtrace_ref.
  evidence-health
              Check retained CI dashboard/history evidence health without rerunning long jobs.
  nightly     Run quick, P1, P0 smoke, P0 PnR, then full P0 Linux.
  all         Alias for nightly.

Environment:
  LOGDIR                  Root log directory for this scheduler run.
  VERIFY_PROFILE          Default profile when no positional profile is given.
  P0_PREPARE_PAYLOAD      Set to 1 to rebuild the no-net Linux payload.
  P0_SMOKE_REUSE          Set to 1 to reuse an existing smoke Vvtop.
  P0_FULL_REUSE           Set to 1 to reuse an existing full-login Vvtop.
                          Nightly defaults this to 1 after the smoke build.
  P0_SMOKE_MAXCYC         Override the smoke cycle cap.
  P0_FULL_MAXCYC          Override the full-login cycle cap.
  P0_LOGIN_LOG_PREFIX     Prefix for p0-audit logs, without .out/.err.
  P0_PNR_YOSYS_LOG        Retained yosys log for p0-pnr-audit.
  P0_PNR_NEXTPNR_LOG      Retained nextpnr log for p0-pnr-audit.
  P0_PNR_CONFIG           Retained nextpnr textcfg for p0-pnr-audit.
  P1_TRACE_LOGDIR         Retained verify.sh/quick logdir with rvtrace_*.csv.
EOF
}

PROFILE=${1:-${VERIFY_PROFILE:-pr}}
if [ "$#" -gt 1 ]; then
  usage
  exit 2
fi
case "$PROFILE" in
  -h|--help)
    usage
    exit 0
    ;;
esac

LOGDIR=${LOGDIR:-logs/ci-${PROFILE}-$(date +%Y%m%d-%H%M%S)}
P0_LOGIN_LOG_PREFIX=${P0_LOGIN_LOG_PREFIX:-logs/run-synth-shell-nonet-default-login}
P0_PNR_YOSYS_LOG=${P0_PNR_YOSYS_LOG:-logs/yosys-rvlinux-synth-shell-top-current.log}
P0_PNR_NEXTPNR_LOG=${P0_PNR_NEXTPNR_LOG:-logs/nextpnr-rvlinux-synth-shell-top-current-seed2-f40.log}
P0_PNR_CONFIG=${P0_PNR_CONFIG:-rvlinux_synth_shell_current_seed2_f40.config}
mkdir -p "$LOGDIR"

pass=0
fail=0

run_step() {
  local name=$1
  shift
  local log="$LOGDIR/${name}.log"

  printf '=== %-18s ===\n' "$name"
  if "$@" >"$log" 2>&1; then
    printf 'PASS %-18s log=%s\n' "$name" "$log"
    pass=$((pass + 1))
  else
    local code=$?
    printf 'FAIL %-18s exit=%d log=%s\n' "$name" "$code" "$log"
    tail -n 80 "$log" || true
    fail=$((fail + 1))
  fi
}

write_metrics() {
  local summary_line=$1
  printf '%s\n' "$summary_line" >"$LOGDIR/ci_summary.log"
  if ! python3 tools/collect_ci_metrics.py \
      --logdir "$LOGDIR" \
      --json "$LOGDIR/summary.json" \
      --markdown "$LOGDIR/summary.md"; then
    echo "CI_METRICS: WARN failed to collect metrics for $LOGDIR" >&2
  fi
  if ! python3 tools/render_ci_dashboard.py \
      --root logs \
      --json logs/ci-dashboard.json \
      --markdown logs/ci-dashboard.md \
      --history-jsonl logs/ci-history.jsonl \
      --trend-markdown logs/ci-trend.md; then
    echo "CI_DASHBOARD: WARN failed to render dashboard" >&2
  fi
}

run_quick() {
  run_step quick env LOGDIR="$LOGDIR/quick" bash ./verify.sh
}

run_p1_external() {
  run_step p1_external env LOGDIR="$LOGDIR/p1_external" bash ./verify_p1_external.sh
}

find_latest_trace_logdir() {
  find logs -type f -name rvtrace_isa.csv -print 2>/dev/null \
    | sed 's#/rvtrace_isa\.csv$##' \
    | sort \
    | tail -n 1
}

run_p1_trace_audit() {
  local trace_logdir=${P1_TRACE_LOGDIR:-}
  if [ -z "$trace_logdir" ]; then
    trace_logdir=$(find_latest_trace_logdir)
  fi
  if [ -z "$trace_logdir" ]; then
    run_step p1_trace_audit bash -lc 'echo "missing retained RVTRACE logdir" >&2; exit 1'
  else
    run_step p1_trace_audit python3 tools/audit_rvtrace_logs.py \
      --logdir "$trace_logdir" \
      --json "$LOGDIR/rvtrace_coverage.json" \
      --markdown "$LOGDIR/rvtrace_coverage.md"
  fi
}

run_ci_dashboard() {
  run_step ci_dashboard python3 tools/render_ci_dashboard.py \
    --root logs \
    --json logs/ci-dashboard.json \
    --markdown logs/ci-dashboard.md \
    --history-jsonl logs/ci-history.jsonl \
    --trend-markdown logs/ci-trend.md
}

run_evidence_health() {
  run_ci_dashboard
  run_step evidence_health python3 tools/check_ci_dashboard.py \
    --dashboard logs/ci-dashboard.json \
    --history-jsonl logs/ci-history.jsonl \
    --json "$LOGDIR/ci_health.json" \
    --markdown "$LOGDIR/ci_health.md"
}

run_p0_smoke() {
  local args=(--smoke "--logdir=$LOGDIR/p0-smoke")
  if [ "${P0_SMOKE_REUSE:-0}" != "0" ]; then
    args+=(--reuse)
  fi
  if [ "${P0_PREPARE_PAYLOAD:-0}" != "0" ]; then
    args+=(--prepare-payload)
  fi
  if [ -n "${P0_SMOKE_MAXCYC:-}" ]; then
    args+=("--maxcyc=$P0_SMOKE_MAXCYC")
  fi
  run_step p0_linux_smoke bash ./verify_p0_linux.sh "${args[@]}"
}

run_p0_audit() {
  run_step p0_linux_audit \
    bash ./verify_p0_linux.sh \
      "--logdir=$LOGDIR/p0-audit" \
      "--check-logs=$P0_LOGIN_LOG_PREFIX"
}

run_p0_pnr_audit() {
  run_step p0_pnr_audit bash -lc '
    set -euo pipefail
    yosys_log=$1
    nextpnr_log=$2
    textcfg=$3

    [ -s "$yosys_log" ] || { echo "missing yosys log: $yosys_log" >&2; exit 1; }
    [ -s "$nextpnr_log" ] || { echo "missing nextpnr log: $nextpnr_log" >&2; exit 1; }
    [ -s "$textcfg" ] || { echo "missing textcfg: $textcfg" >&2; exit 1; }

    grep -q "Found and reported 0 problems" "$yosys_log"
    grep -Eq "^[[:space:]]+32[[:space:]]+DP16KD$" "$yosys_log"
    grep -Eq "^[[:space:]]+10902[[:space:]]+LUT4$" "$yosys_log"
    grep -Eq "^[[:space:]]+5118[[:space:]]+TRELLIS_FF$" "$yosys_log"

    grep -q "Program finished normally" "$nextpnr_log"
    grep -q "Max frequency.*53.94 MHz (PASS at 40.00 MHz)" "$nextpnr_log"
    grep -Eq "DP16KD:[[:space:]]+32/[[:space:]]+208[[:space:]]+15%" "$nextpnr_log"
    grep -Eq "TRELLIS_FF:[[:space:]]+5118/[[:space:]]+83640[[:space:]]+6%" "$nextpnr_log"
    grep -Eq "TRELLIS_COMB:[[:space:]]+12682/[[:space:]]+83640[[:space:]]+15%" "$nextpnr_log"

    echo "yosys_log=$yosys_log"
    echo "nextpnr_log=$nextpnr_log"
    echo "textcfg=$textcfg"
    grep -E "Number of cells|DP16KD|LUT4|TRELLIS_FF" "$yosys_log" | tail -n 8
    grep -E "DP16KD:|TRELLIS_FF:|TRELLIS_COMB:|Max frequency.*PASS|Program finished normally" "$nextpnr_log"
  ' bash "$P0_PNR_YOSYS_LOG" "$P0_PNR_NEXTPNR_LOG" "$P0_PNR_CONFIG"
}

run_p0_full() {
  local args=("--logdir=$LOGDIR/p0-full")
  if [ "${P0_FULL_REUSE:-0}" != "0" ]; then
    args+=(--reuse)
  fi
  if [ "${P0_PREPARE_PAYLOAD:-0}" != "0" ]; then
    args+=(--prepare-payload)
  fi
  if [ -n "${P0_FULL_MAXCYC:-}" ]; then
    args+=("--maxcyc=$P0_FULL_MAXCYC")
  fi
  run_step p0_linux_full bash ./verify_p0_linux.sh "${args[@]}"
}

run_p0_pnr() {
  local detail_dir="$LOGDIR/p0-pnr"
  mkdir -p "$detail_dir"
  run_step p0_pnr bash -lc '
    set -euo pipefail
    detail_dir=$1
    if [ -f oss-cad-suite/environment ]; then
      source oss-cad-suite/environment
    fi

    yosys_log="$detail_dir/yosys-rvlinux-synth-shell-top.log"
    nextpnr_log="$detail_dir/nextpnr-rvlinux-synth-shell-top-seed2-f40.log"
    textcfg="$detail_dir/rvlinux_synth_shell_seed2_f40.config"

    yosys -s synth_rvlinux_synth_shell_top.ys >"$yosys_log" 2>&1
    grep -q "Found and reported 0 problems" "$yosys_log"

    nextpnr-ecp5 --85k --package CABGA381 --speed 6 --seed 2 \
      --json syn_top_rvlinux_synth_shell.json \
      --textcfg "$textcfg" \
      --freq 40 >"$nextpnr_log" 2>&1
    grep -q "Max frequency.*PASS at 40.00 MHz" "$nextpnr_log"
    grep -q "Program finished normally" "$nextpnr_log"

    echo "yosys_log=$yosys_log"
    echo "nextpnr_log=$nextpnr_log"
    echo "textcfg=$textcfg"
    grep -E "Max frequency|DP16KD|TRELLIS_COMB" "$nextpnr_log" | tail -n 8
  ' bash "$detail_dir"
}

case "$PROFILE" in
  quick)
    run_quick
    ;;
  pr)
    run_quick
    run_p0_smoke
    ;;
  p0-smoke)
    run_p0_smoke
    ;;
  p0-audit)
    run_p0_audit
    ;;
  p0-pnr-audit)
    run_p0_pnr_audit
    ;;
  p0-evidence)
    run_p0_audit
    run_p0_pnr_audit
    ;;
  p0-full)
    run_p0_full
    ;;
  p0-pnr)
    run_p0_pnr
    ;;
  p1)
    run_p1_external
    ;;
  p1-trace-audit)
    run_p1_trace_audit
    ;;
  evidence-health)
    run_evidence_health
    ;;
  nightly|all)
    run_quick
    run_p1_external
    P1_TRACE_LOGDIR=${P1_TRACE_LOGDIR:-$LOGDIR/quick} run_p1_trace_audit
    run_p0_smoke
    run_p0_pnr
    P0_FULL_REUSE=${P0_FULL_REUSE:-1} run_p0_full
    ;;
  *)
    echo "unknown profile: $PROFILE" >&2
    usage
    exit 2
    ;;
esac

summary_line=$(printf 'CI summary: profile=%s pass=%d fail=%d logdir=%s' \
  "$PROFILE" "$pass" "$fail" "$LOGDIR")
printf '\n%s\n' "$summary_line"
write_metrics "$summary_line"
if [ "$fail" -ne 0 ]; then
  exit 1
fi

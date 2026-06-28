#!/usr/bin/env bash
# Run a verify_ci.sh profile from cron/launchd with a lock and timestamped logs.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

usage() {
  cat >&2 <<'EOF'
usage: tools/ci_cron.sh [profile]

Default profile is nightly, or VERIFY_PROFILE when set.
Example crontab line for a 01:00 Asia/Shanghai nightly run:
  0 1 * * * cd /Users/Apple/riscv-rv32i-core && tools/ci_cron.sh nightly
Example low-cost evidence audit between expensive runs:
  0 */6 * * * cd /Users/Apple/riscv-rv32i-core && tools/ci_cron.sh p0-evidence
Example retained P1 trace audit:
  30 */6 * * * cd /Users/Apple/riscv-rv32i-core && tools/ci_cron.sh p1-trace-audit
Example retained evidence health check:
  45 */6 * * * cd /Users/Apple/riscv-rv32i-core && tools/ci_cron.sh evidence-health

Environment:
  CI_LOGROOT     Root for timestamped cron logs (default: logs/cron).
  CI_LOCKDIR     Lock directory path (default: .ci-<profile>.lock).
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

PROFILE=${1:-${VERIFY_PROFILE:-nightly}}
LOGROOT=${CI_LOGROOT:-logs/cron}
LOCKDIR=${CI_LOCKDIR:-.ci-${PROFILE}.lock}

mkdir -p "$LOGROOT"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  echo "CI_CRON: another $PROFILE run appears active: $LOCKDIR" >&2
  exit 75
fi
trap 'rmdir "$LOCKDIR"' EXIT

stamp=$(date +%Y%m%d-%H%M%S)
run_logdir="$LOGROOT/${PROFILE}-${stamp}"
mkdir -p "$run_logdir"
top_log="$run_logdir/cron.log"

echo "CI_CRON: profile=$PROFILE logdir=$run_logdir" | tee "$top_log"
set +e
LOGDIR="$run_logdir" ./verify_ci.sh "$PROFILE" 2>&1 | tee -a "$top_log"
status=${PIPESTATUS[0]}
set -e
echo "CI_CRON: profile=$PROFILE exit=$status logdir=$run_logdir" | tee -a "$top_log"
exit "$status"

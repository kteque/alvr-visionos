#!/bin/bash
# Runs protocol-harness scenarios and prints one line per scenario.
#   run.sh [--tsan] [--out DIR] [scenario...]     (default: every scenario)
# Exit status: number of failed scenarios. Per scenario: DIR/<name>.log (client + harness lines), DIR/<name>.json (verdict),
# DIR/<name>.tsan (ThreadSanitizer reports, --tsan only).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/build/protocol_harness"
OUT="$HERE/results/$(date +%Y%m%d-%H%M%S)"
TSAN=0
NAMES=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tsan) TSAN=1; BIN="$HERE/build/protocol_harness_tsan"; shift ;;
        --out) OUT="$2"; shift 2 ;;
        *) NAMES+=("$1"); shift ;;
    esac
done
[[ ${#NAMES[@]} -eq 0 ]] && mapfile -t NAMES < <("$BIN" list | awk '{print $1}')
mkdir -p "$OUT"
FAILS=0
printf "%-20s %-8s %6s %6s %6s %6s %5s %s\n" scenario result tail% idr reconn decerr races failures
for n in "${NAMES[@]}"; do
    if [[ $TSAN == 1 ]]; then
        TSAN_OPTIONS="log_path=$OUT/$n.tsan halt_on_error=0 report_signal_unsafe=0" timeout 150 "$BIN" run "$n" --out "$OUT" > /dev/null 2>"$OUT/$n.stderr"
    else
        timeout 150 "$BIN" run "$n" --out "$OUT" > /dev/null 2>"$OUT/$n.stderr"
    fi
    rc=$?
    races=$(cat "$OUT/$n.tsan".* 2>/dev/null | grep -c "WARNING: ThreadSanitizer: data race" || true)
    case $rc in
        0) res=pass ;; 1) res=FAIL ;; 42) res=SELFEXIT ;; 124) res=TIMEOUT ;; *) res="CRASH($rc)" ;;
    esac
    # ThreadSanitizer exits 66 when it reported something: the verdict still says pass/fail, the races column counts
    if [[ $TSAN == 1 && $rc == 66 ]]; then
        if grep -q '"pass" : true' "$OUT/$n.json" 2>/dev/null; then res=pass; else res=FAIL; fi
        rc=$([[ $res == pass ]] && echo 0 || echo 1)
    fi
    if [[ $rc == 42 ]] && grep -q '"pass" : true' "$OUT/$n.json" 2>/dev/null; then res="pass(exit)"; rc=0; fi
    [[ $rc != 0 ]] && FAILS=$((FAILS+1))
    if [[ -f "$OUT/$n.json" ]]; then
        python3 - "$OUT/$n.json" "$n" "$res" "$races" <<'PY'
import json, sys
v = json.load(open(sys.argv[1])); m = v["metrics"]
print("%-20s %-8s %6.0f %6d %6d %6d %5s %s" % (sys.argv[2], sys.argv[3], m.get("tail_new_fraction", 0) * 100, m.get("idr_requests", 0),
      m.get("reconnects", 0), m.get("decode_errors", 0), sys.argv[4], "; ".join(v["failures"])))
PY
    else
        printf "%-20s %-8s %s\n" "$n" "$res" "(no verdict: see $OUT/$n.stderr)"
    fi
done
echo "results: $OUT"
exit $FAILS

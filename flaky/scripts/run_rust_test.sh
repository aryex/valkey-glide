#!/usr/bin/env bash
# Usage: run_rust_test.sh <test_name> <max_iterations> <output_dir> [--no-failfast]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_NAME="$1"
MAX_ITER="${2:-1000}"
OUT_DIR="$3"
FAILFAST=true
[[ "${4:-}" == "--no-failfast" ]] && FAILFAST=false
mkdir -p "$OUT_DIR"

cleanup() { bash "$SCRIPT_DIR/cleanup_clusters.sh" 2>/dev/null || true; rm -f "$OUT_DIR"/tmp_*.log; }
trap cleanup EXIT

TEST_FILE="test_client"
[[ "$TEST_NAME" == *"cluster_client"* ]] && TEST_FILE="test_cluster_client"

FAILURES=0
FIRST_FAILURE=""

for i in $(seq 1 "$MAX_ITER"); do
  echo "[iteration $i/$MAX_ITER] $TEST_NAME"
  if ! cargo test --test "$TEST_FILE" "$TEST_NAME" -- --exact 2>"$OUT_DIR/tmp_stderr.log" >"$OUT_DIR/tmp_stdout.log"; then
    cat "$OUT_DIR/tmp_stdout.log" "$OUT_DIR/tmp_stderr.log" > "$OUT_DIR/iteration_$(printf '%04d' $i).log"
    FAILURES=$((FAILURES + 1))
    [[ -z "$FIRST_FAILURE" ]] && FIRST_FAILURE=$i
    echo "FAILED at iteration $i"
    if $FAILFAST; then
      echo "{\"test\":\"$TEST_NAME\",\"language\":\"rust\",\"iterations\":$i,\"first_failure\":$i,\"failures\":$FAILURES,\"status\":\"failed\"}" > "$OUT_DIR/summary.json"
      exit 1
    fi
  fi
done

if [[ $FAILURES -gt 0 ]]; then
  echo "{\"test\":\"$TEST_NAME\",\"language\":\"rust\",\"iterations\":$MAX_ITER,\"first_failure\":$FIRST_FAILURE,\"failures\":$FAILURES,\"status\":\"failed\"}" > "$OUT_DIR/summary.json"
  echo "FAILED $FAILURES/$MAX_ITER iterations (first failure: $FIRST_FAILURE)"
  exit 1
else
  echo "{\"test\":\"$TEST_NAME\",\"language\":\"rust\",\"iterations\":$MAX_ITER,\"first_failure\":null,\"failures\":0,\"status\":\"passed\"}" > "$OUT_DIR/summary.json"
  echo "PASSED all $MAX_ITER iterations"
fi

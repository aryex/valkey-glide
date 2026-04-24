#!/usr/bin/env bash
# Usage: run_node_test.sh <test_name_pattern> <max_iterations> <output_dir>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_NAME="$1"
MAX_ITER="${2:-1000}"
OUT_DIR="$3"
mkdir -p "$OUT_DIR"

cleanup() { bash "$SCRIPT_DIR/cleanup_clusters.sh" 2>/dev/null || true; rm -f "$OUT_DIR"/tmp_*.log; }
trap cleanup EXIT

for i in $(seq 1 "$MAX_ITER"); do
  echo "[iteration $i/$MAX_ITER] $TEST_NAME"
  if ! npx jest --testNamePattern="$TEST_NAME" --forceExit --detectOpenHandles 2>"$OUT_DIR/tmp_stderr.log" >"$OUT_DIR/tmp_stdout.log"; then
    cat "$OUT_DIR/tmp_stdout.log" "$OUT_DIR/tmp_stderr.log" > "$OUT_DIR/iteration_$(printf '%04d' $i).log"
    echo "{\"test\":\"$TEST_NAME\",\"language\":\"node\",\"iterations\":$i,\"first_failure\":$i,\"status\":\"failed\"}" > "$OUT_DIR/summary.json"
    echo "FAILED at iteration $i"
    exit 1
  fi
done

echo "{\"test\":\"$TEST_NAME\",\"language\":\"node\",\"iterations\":$MAX_ITER,\"first_failure\":null,\"status\":\"passed\"}" > "$OUT_DIR/summary.json"
echo "PASSED all $MAX_ITER iterations"

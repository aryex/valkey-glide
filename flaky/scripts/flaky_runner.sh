#!/usr/bin/env bash
# Usage: flaky_runner.sh [max_iterations] [csv_file] [repo_root]
# Runs all tests from the CSV through their language-specific runners.
set -euo pipefail

MAX_ITER="${1:-1000}"
CSV_FILE="${2:-flaky/flaky_tests.csv}"
REPO_ROOT="${3:-$(pwd)}"
RESULTS_DIR="flaky/results"
SCRIPTS_DIR="flaky/scripts"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

mkdir -p "$RESULTS_DIR"

# Cluster endpoints (override via env if needed)
STANDALONE_HOST="${STANDALONE_HOST:-127.0.0.1}"
STANDALONE_PORT="${STANDALONE_PORT:-6379}"
CLUSTER_HOST="${CLUSTER_HOST:-127.0.0.1}"
CLUSTER_PORT="${CLUSTER_PORT:-7000}"

flush_server() {
  echo "--- Flushing server state ---"
  redis-cli -h "$STANDALONE_HOST" -p "$STANDALONE_PORT" FLUSHALL 2>/dev/null || true
  redis-cli -h "$STANDALONE_HOST" -p "$STANDALONE_PORT" SCRIPT FLUSH 2>/dev/null || true
  redis-cli -h "$STANDALONE_HOST" -p "$STANDALONE_PORT" FUNCTION FLUSH 2>/dev/null || true
  redis-cli -h "$CLUSTER_HOST" -p "$CLUSTER_PORT" FLUSHALL 2>/dev/null || true
  redis-cli -h "$CLUSTER_HOST" -p "$CLUSTER_PORT" SCRIPT FLUSH 2>/dev/null || true
  redis-cli -h "$CLUSTER_HOST" -p "$CLUSTER_PORT" FUNCTION FLUSH 2>/dev/null || true
}

get_working_dir() {
  local lang="$1"
  case "$lang" in
    rust)   echo "$REPO_ROOT/glide-core" ;;
    java)   echo "$REPO_ROOT/java" ;;
    python) echo "$REPO_ROOT/python" ;;
    node)   echo "$REPO_ROOT/node" ;;
    go)     echo "$REPO_ROOT/go" ;;
    *)      echo "$REPO_ROOT" ;;
  esac
}

get_runner() {
  local lang="$1"
  echo "$REPO_ROOT/$SCRIPTS_DIR/run_${lang}_test.sh"
}

# Track results for final summary
TOTAL=0
FAILED=0
PASSED=0
SKIPPED=0

echo "============================================"
echo "Flaky Test Verification Run"
echo "Timestamp: $TIMESTAMP"
echo "Max iterations: $MAX_ITER"
echo "CSV: $CSV_FILE"
echo "============================================"
echo ""

# Skip header line, read CSV
tail -n +2 "$CSV_FILE" | while IFS=, read -r issue language test_id engine platform notes; do
  TOTAL=$((TOTAL + 1))
  OUT_DIR="$RESULTS_DIR/$issue"
  RUNNER=$(get_runner "$language")
  WORK_DIR=$(get_working_dir "$language")

  echo "============================================"
  echo "[$TOTAL] Issue #$issue ($language)"
  echo "Test: $test_id"
  echo "Engine: $engine | Platform: $platform"
  echo "============================================"

  if [ ! -x "$RUNNER" ]; then
    echo "SKIP — runner not found or not executable: $RUNNER"
    mkdir -p "$OUT_DIR"
    echo "{\"test\":\"$test_id\",\"language\":\"$language\",\"iterations\":0,\"first_failure\":null,\"status\":\"skipped\",\"reason\":\"runner not found\"}" > "$OUT_DIR/summary.json"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Flush between tests
  flush_server

  # Run from the language's working directory
  pushd "$WORK_DIR" > /dev/null
  if bash "$RUNNER" "$test_id" "$MAX_ITER" "$REPO_ROOT/$OUT_DIR"; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
  fi
  popd > /dev/null

  echo ""
done

# Generate final summary
echo "============================================"
echo "VERIFICATION COMPLETE"
echo "Total: $TOTAL | Passed: $PASSED | Failed: $FAILED | Skipped: $SKIPPED"
echo "============================================"

# Aggregate all summary.json files into one report
echo "[" > "$RESULTS_DIR/summary_report.json"
FIRST=true
for f in "$RESULTS_DIR"/*/summary.json; do
  if [ "$FIRST" = true ]; then
    FIRST=false
  else
    echo "," >> "$RESULTS_DIR/summary_report.json"
  fi
  cat "$f" >> "$RESULTS_DIR/summary_report.json"
done
echo "]" >> "$RESULTS_DIR/summary_report.json"

echo "Report written to $RESULTS_DIR/summary_report.json"

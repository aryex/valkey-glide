#!/usr/bin/env bash
# flaky_agent.sh — Orchestrates the flaky test investigation agent.
#
# Usage:
#   flaky_agent.sh --issue <github_issue_number>
#   flaky_agent.sh --csv <path_to_csv>
#   flaky_agent.sh --test <test_id> --language <lang>
#   flaky_agent.sh --from-db [--language <lang>] [--limit <N>]
#
# Options:
#   --issue <N>          GitHub issue number to investigate
#   --csv <path>         CSV file with flaky test entries
#   --test <id>          Single test ID (e.g. tests/async_tests/test_async_client.py::TestClass::test_method)
#   --from-db            Query postgres for top flaky tests
#   --language <lang>    Language filter (default: python)
#   --iterations <N>     Reproduction iterations (default: 1000)
#   --limit <N>          Max tests to investigate in --from-db mode (default: 5)
#   --skip-worktree      Run in current directory instead of creating a worktree
#   --skip-build         Skip the build step
#   --skip-clusters      Skip cluster setup (assumes clusters are already running)
set -euo pipefail

REPO_ROOT="/home/ec2-user/valkey-glide"
WORKTREE_BASE="/home/ec2-user/valkey-glide-worktrees"
AGENT_DIR="$REPO_ROOT/flakky/agent"
SCRIPTS_DIR="$REPO_ROOT/flakky/scripts"
RESULTS_DIR="$REPO_ROOT/flakky/results"

# Defaults
ISSUE=""
CSV_FILE=""
TEST_ID=""
LANGUAGE="python"
ITERATIONS=1000
FROM_DB=false
DB_LIMIT=5
SKIP_WORKTREE=false
SKIP_BUILD=false
SKIP_CLUSTERS=false

usage() {
  sed -n '2,/^set /{ /^#/s/^# \?//p }' "$0"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue)      ISSUE="$2"; shift 2 ;;
    --csv)        CSV_FILE="$2"; shift 2 ;;
    --test)       TEST_ID="$2"; shift 2 ;;
    --from-db)    FROM_DB=true; shift ;;
    --language)   LANGUAGE="$2"; shift 2 ;;
    --iterations) ITERATIONS="$2"; shift 2 ;;
    --limit)      DB_LIMIT="$2"; shift 2 ;;
    --skip-worktree) SKIP_WORKTREE=true; shift ;;
    --skip-build)    SKIP_BUILD=true; shift ;;
    --skip-clusters) SKIP_CLUSTERS=true; shift ;;
    -h|--help)    usage ;;
    *)            echo "Unknown option: $1"; usage ;;
  esac
done

# Validate input — exactly one of --issue, --csv, --test, or --from-db must be provided
INPUT_COUNT=0
[[ -n "$ISSUE" ]] && INPUT_COUNT=$((INPUT_COUNT + 1))
[[ -n "$CSV_FILE" ]] && INPUT_COUNT=$((INPUT_COUNT + 1))
[[ -n "$TEST_ID" ]] && INPUT_COUNT=$((INPUT_COUNT + 1))
[[ "$FROM_DB" == true ]] && INPUT_COUNT=$((INPUT_COUNT + 1))
if [[ $INPUT_COUNT -ne 1 ]]; then
  echo "Error: Provide exactly one of --issue, --csv, --test, or --from-db"
  usage
fi

# Determine a run ID for this investigation
if [[ -n "$ISSUE" ]]; then
  RUN_ID="issue-${ISSUE}"
elif [[ -n "$CSV_FILE" ]]; then
  RUN_ID="csv-$(date +%Y%m%d_%H%M%S)"
elif [[ "$FROM_DB" == true ]]; then
  RUN_ID="db-${LANGUAGE}-$(date +%Y%m%d_%H%M%S)"
else
  # Derive a short name from the test ID
  SHORT_TEST=$(echo "$TEST_ID" | sed 's|.*/||; s|\.py.*||')
  RUN_ID="test-${SHORT_TEST}-$(date +%s)"
fi

WORK_DIR="$REPO_ROOT"
BRANCH_NAME="flaky/$RUN_ID"

# --- Step 1: Create worktree ---
if [[ "$SKIP_WORKTREE" == false ]]; then
  WORK_DIR="$WORKTREE_BASE/$RUN_ID"
  echo "==> Creating worktree at $WORK_DIR (branch: $BRANCH_NAME)"
  mkdir -p "$WORKTREE_BASE"
  cd "$REPO_ROOT"
  git worktree add -b "$BRANCH_NAME" "$WORK_DIR" main 2>/dev/null || {
    # Branch may already exist
    git worktree add "$WORK_DIR" "$BRANCH_NAME" 2>/dev/null || {
      echo "Worktree already exists at $WORK_DIR, reusing."
    }
  }
else
  echo "==> Skipping worktree, working in $REPO_ROOT"
fi

# --- Step 2: Build (Python) ---
if [[ "$SKIP_BUILD" == false && "$LANGUAGE" == "python" ]]; then
  echo "==> Building Python client..."
  cd "$WORK_DIR/python"
  python3 dev.py build --client async --mode release
  python3 dev.py build --client sync --mode release
fi

# --- Step 3: Start clusters ---
if [[ "$SKIP_CLUSTERS" == false ]]; then
  echo "==> Setting up test clusters..."
  bash "$SCRIPTS_DIR/setup_clusters.sh" "$WORK_DIR"
  source "$WORK_DIR/flakky/cluster_env.sh" 2>/dev/null || source "$REPO_ROOT/flakky/cluster_env.sh" 2>/dev/null || true
fi

# --- Step 4: Build the agent prompt ---
build_agent_prompt() {
  local system_prompt
  system_prompt=$(cat "$AGENT_DIR/system_prompt.md")

  local task_block=""
  if [[ -n "$ISSUE" ]]; then
    task_block="Investigate flaky test from GitHub issue #${ISSUE} in the valkey-io/valkey-glide repository.

Steps:
1. Fetch the issue details using GitHub MCP (owner: valkey-io, repo: valkey-glide, issue: ${ISSUE})
2. Read the issue body and comments to understand the flaky behavior
3. Identify the test ID, language, and failure pattern
4. Read the test source code
5. Reproduce by running ${ITERATIONS} iterations using the scripts in flakky/scripts/
6. Analyze failures, identify root cause, propose fix(es)
7. Write findings to flakky/results/${RUN_ID}/findings.md"

  elif [[ -n "$CSV_FILE" ]]; then
    local csv_content
    csv_content=$(cat "$CSV_FILE")
    task_block="Investigate all flaky tests listed in this CSV:

\`\`\`csv
${csv_content}
\`\`\`

For each entry, follow the full investigation workflow: understand, reproduce (${ITERATIONS} iterations), root-cause, fix, record.
Write findings for each test to flakky/results/<issue_id>/findings.md"

  elif [[ "$FROM_DB" == true ]]; then
    local db_results
    db_results=$(PGPASSWORD=ci_pass psql -h localhost -U ci_user -d ci_failures -t -A -F'|' -c "
      SELECT tf.test_suite, tf.test_name, tf.parameters, tf.failure_type, COUNT(*) as occurrences
      FROM test_failures tf JOIN jobs j ON tf.job_id = j.job_id
      WHERE j.language = '${LANGUAGE}' AND tf.test_suite != 'N/A' AND tf.failure_type NOT LIKE 'infra%'
      GROUP BY 1,2,3,4 ORDER BY 5 DESC LIMIT ${DB_LIMIT};
    " 2>/dev/null)
    task_block="Investigate the top ${DB_LIMIT} flaky ${LANGUAGE} tests from the CI failures database.

Database query results (test_suite|test_name|parameters|failure_type|occurrences):
\`\`\`
${db_results}
\`\`\`

Database connection: PGPASSWORD=ci_pass psql -h localhost -U ci_user -d ci_failures
Local CI logs: /home/ec2-user/valkey-glide-logs/
Parsed failures CSV: /home/ec2-user/valkey-glide-logs/failed-${LANGUAGE}-tests.csv

For each test above:
1. Query the DB for full failure history (platforms, engines, dates)
2. Read the raw CI logs from /home/ec2-user/valkey-glide-logs/runs/ for stack traces
3. Read the test source code
4. Reproduce with ${ITERATIONS} iterations using flakky/scripts/run_python_test.sh
5. Identify root cause and propose fix(es)
6. Write findings to flakky/results/${RUN_ID}/<test_name>/findings.md"

  elif [[ -n "$TEST_ID" ]]; then
    task_block="Investigate flaky test: ${TEST_ID} (language: ${LANGUAGE})

Steps:
1. Read the test source code and understand what it tests
2. Reproduce by running ${ITERATIONS} iterations:
   cd ${WORK_DIR}/python
   bash ${SCRIPTS_DIR}/run_python_test.sh \"${TEST_ID}\" ${ITERATIONS} ${RESULTS_DIR}/${RUN_ID}
3. Analyze any failures from the iteration logs
4. Identify root cause and propose fix(es)
5. Write findings to flakky/results/${RUN_ID}/findings.md"
  fi

  echo "${task_block}"
}

AGENT_PROMPT=$(build_agent_prompt)
OUT_DIR="$RESULTS_DIR/$RUN_ID"
mkdir -p "$OUT_DIR"

# Save the prompt for debugging/auditing
echo "$AGENT_PROMPT" > "$OUT_DIR/agent_prompt.txt"

echo ""
echo "============================================"
echo "Flaky Test Agent — $RUN_ID"
echo "Work dir:    $WORK_DIR"
echo "Results dir: $OUT_DIR"
echo "Iterations:  $ITERATIONS"
echo "============================================"
echo ""
echo "Agent prompt saved to $OUT_DIR/agent_prompt.txt"
echo ""
echo "To launch the agent, run:"
echo ""
echo "  kiro-cli chat --system-prompt $AGENT_DIR/system_prompt.md \\"
echo "    --prompt \"$OUT_DIR/agent_prompt.txt\" \\"
echo "    --working-dir $WORK_DIR"
echo ""
echo "Or manually start a kiro-cli session and paste the prompt."

# --- Step 5: Auto-launch if kiro-cli is available ---
if command -v kiro-cli &>/dev/null; then
  echo ""
  read -r -p "Launch agent now? [Y/n] " REPLY
  REPLY=${REPLY:-Y}
  if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    echo "==> Launching agent..."
    exec kiro-cli chat \
      --system-prompt "$AGENT_DIR/system_prompt.md" \
      --prompt "$(cat "$OUT_DIR/agent_prompt.txt")" \
      --working-dir "$WORK_DIR"
  fi
fi

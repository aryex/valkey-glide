# Flaky Test Agent

An AI-powered agent that independently investigates, reproduces, and fixes flaky tests in the valkey-glide project. Currently focused on Python tests, with infrastructure ready for all languages.

## Quick Start

```bash
# Investigate a GitHub issue
./flakky/agent/flaky_agent.sh --issue 1234

# Investigate a specific test
./flakky/agent/flaky_agent.sh --test "tests/async_tests/test_async_client.py::TestClass::test_method"

# Process a batch from CSV
./flakky/agent/flaky_agent.sh --csv flakky/flaky_tests.csv

# Auto-pick top flaky tests from the postgres DB
./flakky/agent/flaky_agent.sh --from-db --language python --limit 5
```

## How It Works

The agent follows a 5-phase workflow:

1. **Understand** — Reads the issue/logs/CSV, fetches context from GitHub, reads test source code
2. **Reproduce** — Runs the test 1000 times using `flakky/scripts/run_python_test.sh`, collects failure logs
3. **Root Cause** — Analyzes failure patterns, classifies as test bug vs product bug
4. **Fix** — Proposes and implements one or more fixes in an isolated git worktree
5. **Record** — Writes a structured findings report to `flakky/results/<run_id>/findings.md`

## Options

| Flag | Description | Default |
|------|-------------|---------|
| `--issue <N>` | GitHub issue number to investigate | — |
| `--csv <path>` | CSV file with flaky test entries | — |
| `--test <id>` | Single test ID to investigate | — |
| `--from-db` | Query postgres for top flaky tests | — |
| `--language <lang>` | Language filter | `python` |
| `--iterations <N>` | Number of reproduction iterations | `1000` |
| `--limit <N>` | Max tests in `--from-db` mode | `5` |
| `--skip-worktree` | Work in repo root instead of a worktree | `false` |
| `--skip-build` | Skip the Python client build step | `false` |
| `--skip-clusters` | Skip cluster setup (use existing) | `false` |

Exactly one of `--issue`, `--csv`, `--test`, or `--from-db` is required.

## Data Sources

The agent has access to three data sources for understanding flaky behavior:

**PostgreSQL Database (`ci_failures`)**
- Connection: `host=localhost, user=ci_user, password=ci_pass, dbname=ci_failures`
- Tables: `runs` (22 rows), `jobs` (13,886 rows), `test_failures` (2,815 rows)
- Coverage: 22 FMT runs from April 1–20, all jobs (pass/fail/cancelled)

**Local CI Logs (`/home/ec2-user/valkey-glide-logs/`)**
- Raw logs: `runs/<run_id>/<language>/<job_id>.log`
- Parsed CSVs: `failed-{python,node,java,go}-tests.csv`
- Job metadata: `jobs_meta/<run_id>.jsonl`

**GitHub Issues (via MCP)**
- Issue body, comments, linked CI runs

## CSV Format

```csv
issue,language,test_id,engine,platform,notes
1234,python,tests/async_tests/test_async_client.py::TestClass::test_method,valkey-8.0,ubuntu-22.04,Intermittent timeout
```

## Directory Structure

```
flakky/
├── agent/
│   ├── flaky_agent.sh       # Entry point — sets up worktree, builds, launches agent
│   └── system_prompt.md     # Agent system prompt (investigation workflow)
├── scripts/
│   ├── flaky_runner.sh      # Batch orchestrator — reads CSV, dispatches to runners
│   ├── run_python_test.sh   # Runs pytest N iterations, tracks flake rate
│   ├── run_rust_test.sh     # Rust test runner
│   ├── run_java_test.sh     # Java test runner
│   ├── run_node_test.sh     # Node.js test runner
│   ├── run_go_test.sh       # Go test runner
│   ├── setup_clusters.sh    # Starts standalone + cluster + TLS clusters
│   └── cleanup_clusters.sh  # Stops all clusters
├── results/                 # Output: logs, summaries, findings per investigation
├── flaky_tests.csv          # Input: list of flaky tests to investigate
└── README.md                # This file
```

## Output

Each investigation produces:

```
flakky/results/<run_id>/
├── agent_prompt.txt         # The prompt sent to the agent (for auditing)
├── summary.json             # Pass/fail/flaky status with iteration counts
├── iteration_NNNN.log       # Full stdout+stderr for each failed iteration
└── findings.md              # Structured investigation report
```

## Prerequisites

- `kiro-cli` installed and available in PATH
- Python 3.9+ with virtualenv at `python/.env/`
- Rust toolchain (for building glide-core)
- Valkey/Redis server binaries (for cluster setup)
- `redis-cli` available (for state flushing)

## Extending to Other Languages

The scripts in `flakky/scripts/` already support Rust, Java, Node.js, and Go. To add a new language to the agent:

1. Add language-specific context to `agent/system_prompt.md`
2. Ensure the corresponding `run_<lang>_test.sh` script works
3. Add entries to `flaky_tests.csv` with the appropriate `language` column

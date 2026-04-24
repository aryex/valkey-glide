#!/usr/bin/env bash
# Usage: setup_clusters.sh [repo_root]
# Starts standalone, cluster-mode, and TLS clusters for flaky test verification.
# Exports connection info to flaky/cluster_env.sh for other scripts to source.
set -euo pipefail

REPO_ROOT="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
CLUSTER_SCRIPT="$REPO_ROOT/utils/cluster_manager.py"
ENV_FILE="$REPO_ROOT/flaky/cluster_env.sh"

echo "Starting test clusters..."

# Standalone (3 shards, 1 replica)
echo "--- Starting standalone cluster ---"
STANDALONE_OUTPUT=$(python3 "$CLUSTER_SCRIPT" start -n 3 -r 1 2>&1)
STANDALONE_NODES=$(echo "$STANDALONE_OUTPUT" | grep "^CLUSTER_NODES=" | cut -d= -f2)
STANDALONE_FOLDER=$(echo "$STANDALONE_OUTPUT" | grep "^CLUSTER_FOLDER=" | cut -d= -f2)
STANDALONE_PORT=$(echo "$STANDALONE_NODES" | cut -d, -f1 | cut -d: -f2)
echo "Standalone ready: $STANDALONE_NODES"

# Cluster mode (3 shards, 1 replica)
echo "--- Starting cluster-mode cluster ---"
CLUSTER_OUTPUT=$(python3 "$CLUSTER_SCRIPT" start --cluster-mode -n 3 -r 1 2>&1)
CLUSTER_NODES=$(echo "$CLUSTER_OUTPUT" | grep "^CLUSTER_NODES=" | cut -d= -f2)
CLUSTER_FOLDER=$(echo "$CLUSTER_OUTPUT" | grep "^CLUSTER_FOLDER=" | cut -d= -f2)
CLUSTER_PORT=$(echo "$CLUSTER_NODES" | cut -d, -f1 | cut -d: -f2)
echo "Cluster ready: $CLUSTER_NODES"

# TLS cluster (3 shards, 1 replica)
echo "--- Starting TLS cluster ---"
TLS_OUTPUT=$(python3 "$CLUSTER_SCRIPT" --tls start --cluster-mode -n 3 -r 1 2>&1)
TLS_NODES=$(echo "$TLS_OUTPUT" | grep "^CLUSTER_NODES=" | cut -d= -f2)
TLS_FOLDER=$(echo "$TLS_OUTPUT" | grep "^CLUSTER_FOLDER=" | cut -d= -f2)
TLS_PORT=$(echo "$TLS_NODES" | cut -d, -f1 | cut -d: -f2)
echo "TLS cluster ready: $TLS_NODES"

# Write env file for other scripts
cat > "$ENV_FILE" <<EOF
export STANDALONE_NODES="$STANDALONE_NODES"
export STANDALONE_PORT="$STANDALONE_PORT"
export STANDALONE_FOLDER="$STANDALONE_FOLDER"
export CLUSTER_NODES="$CLUSTER_NODES"
export CLUSTER_PORT="$CLUSTER_PORT"
export CLUSTER_FOLDER="$CLUSTER_FOLDER"
export TLS_NODES="$TLS_NODES"
export TLS_PORT="$TLS_PORT"
export TLS_FOLDER="$TLS_FOLDER"
EOF

echo ""
echo "All clusters started. Environment written to $ENV_FILE"
echo "Source it with: source $ENV_FILE"

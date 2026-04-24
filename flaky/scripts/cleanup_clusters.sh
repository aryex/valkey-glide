#!/usr/bin/env bash
# Usage: cleanup_clusters.sh [repo_root]
# Finds and stops any running Valkey/Redis clusters created by cluster_manager.py.
set -euo pipefail

REPO_ROOT="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
CLUSTER_SCRIPT="$REPO_ROOT/utils/cluster_manager.py"
CLUSTERS_DIR="$REPO_ROOT/utils/clusters"

if [ ! -d "$CLUSTERS_DIR" ]; then
  exit 0
fi

FOLDERS=$(find "$CLUSTERS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
if [ -z "$FOLDERS" ]; then
  exit 0
fi

echo "Stopping all clusters in $CLUSTERS_DIR ..."
for folder in $FOLDERS; do
  echo "--- Stopping: $(basename "$folder") ---"
  python3 "$CLUSTER_SCRIPT" stop --cluster-folder "$folder" 2>&1 || true
done

echo "All clusters stopped."

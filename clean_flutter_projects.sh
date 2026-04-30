#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECTS=(
  "example"
  "xb_scaffold"
  "xb_simple_router"
  "xb_network"
)

for project in "${PROJECTS[@]}"; do
  project_dir="$ROOT_DIR/$project"
  if [[ ! -d "$project_dir" ]]; then
    echo "[skip] $project_dir does not exist"
    continue
  fi

  echo "==> flutter clean in $project"
  (
    cd "$project_dir"
    flutter clean
  )
done

echo "==> remove generated/cache directories in repo"
find "$ROOT_DIR" -type d \
  \( -name build -o -name .dart_tool -o -name Pods -o -name .symlinks -o -name .flutter-plugins-dependencies \) \
  -prune -exec rm -rf {} +

echo "==> remove editor/system cache files"
find "$ROOT_DIR" -type d \( -name .idea -o -name .vscode \) -prune -exec rm -rf {} +
find "$ROOT_DIR" -type f -name .DS_Store -delete

echo "Done."

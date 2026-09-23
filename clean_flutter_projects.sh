#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECTS=(
  "example"
  "xb_scaffold"
  "xb_simple_router"
  "xb_network"
  "xb_analytics_plus"
  "xb_ume"
)

# 判断仓库内相对路径是否包含 git 跟踪的文件；跟踪的文件不允许被清理
has_tracked_files() {
  [[ -n "$(git -C "$ROOT_DIR" ls-files -- "$1")" ]]
}

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

  # flutter clean 会删除 git 跟踪的生成文件，这里恢复它们
  for f in .flutter-plugins .flutter-plugins-dependencies; do
    if git -C "$ROOT_DIR" ls-files --error-unmatch "$project/$f" >/dev/null 2>&1; then
      git -C "$ROOT_DIR" checkout -- "$project/$f"
      echo "[restore] $project/$f (git-tracked)"
    fi
  done
done

echo "==> remove generated/cache directories in repo (skip git-tracked)"
while IFS= read -r -d '' d; do
  rel="${d#"$ROOT_DIR"/}"
  if has_tracked_files "$rel"; then
    echo "[skip] $rel contains git-tracked files"
  else
    rm -rf "$d"
  fi
done < <(find "$ROOT_DIR" -type d \
  \( -name build -o -name .dart_tool -o -name Pods -o -name .symlinks \) \
  -prune -print0)

echo "==> remove editor/system cache files (skip git-tracked)"
while IFS= read -r -d '' d; do
  rel="${d#"$ROOT_DIR"/}"
  if has_tracked_files "$rel"; then
    echo "[skip] $rel contains git-tracked files"
  else
    rm -rf "$d"
  fi
done < <(find "$ROOT_DIR" -type d \( -name .idea -o -name .vscode \) -prune -print0)

# .DS_Store 不会被 git 跟踪，直接删除
find "$ROOT_DIR" -type f -name .DS_Store -delete

echo "Done."

"""iOS Pods 复用：把项目已安装的 ios/Pods 复制进隔离 worktree，避免全量网络下载。

仓库 ios/Pods 与隔离 worktree 的 Podfile.lock 均来自同一 git HEAD，
版本必然一致；CocoaPods 安装时校验 checksum 通过即秒级跳过下载。
复制失败自动回退为全量 pod install，不影响构建正确性。
"""

from __future__ import annotations

import subprocess
from pathlib import Path


def reuse_pods(src_dir: Path, dst_dir: Path) -> None:
    """尝试复用现有 Pods；源缺失/目标已存在/复制失败时静默跳过。"""
    if not src_dir.is_dir():
        return
    if dst_dir.exists():
        return
    try:
        subprocess.run(
            ["rsync", "-a", f"{src_dir}/", f"{dst_dir}/"], check=True
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        print("ios/Pods 复用失败，将执行全量 pod install")
        return
    print(f"已复用 ios/Pods: {dst_dir} -> 源 {src_dir}")

"""Android 构建：flutter build apk --release，产物复制到输出目录。"""

from __future__ import annotations

import glob
import shutil
import subprocess
from pathlib import Path

from .config import BuildConfig
from .worktree import WorktreeSession, check_tool


def _newest_artifact(patterns: list[str]) -> Path | None:
    """在多个 glob 模式中取修改时间最新的产物文件。"""
    best: tuple[float, Path] | None = None
    for pattern in patterns:
        for path_str in glob.glob(pattern, recursive=True):
            path = Path(path_str)
            if not path.is_file():
                continue
            mtime = path.stat().st_mtime
            if best is None or mtime > best[0]:
                best = (mtime, path)
    return best[1] if best else None


def build_android(cfg: BuildConfig, session: WorktreeSession) -> Path:
    """执行 Android 打包，返回 APK 路径。"""
    check_tool("flutter")
    work_dir = session.work_dir
    cfg_android = cfg.android

    cmd = ["flutter", "build", "apk", "--release"]
    target_platforms = cfg_android.get("target_platforms")
    if isinstance(target_platforms, list) and target_platforms:
        cmd += ["--target-platform", *[str(item) for item in target_platforms]]

    print(f"\n>>> [Android]: {' '.join(cmd)}")
    completed = subprocess.run(cmd, cwd=work_dir)
    if completed.returncode != 0:
        raise SystemExit(f"[Android] 构建失败，退出码 {completed.returncode}")

    apk = _newest_artifact(
        [str(work_dir / "build" / "app" / "outputs" / "flutter-apk" / "*.apk")]
    )
    if apk is None:
        raise SystemExit("[Android] 未找到构建产物 APK")

    cfg.output_dir.mkdir(parents=True, exist_ok=True)
    apk_name = str(cfg_android.get("apk_name") or f"{cfg.name}.apk")
    target = cfg.output_dir / apk_name
    shutil.copy2(apk, target)
    print(f"\n[Android] 打包完成: {target}")
    return target

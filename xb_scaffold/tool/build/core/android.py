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


def _enable_build_cache(work_dir: Path) -> None:
    """在隔离目录的 android/gradle.properties 追加 org.gradle.caching=true。

    Gradle Build Cache 按任务输入内容哈希存取产物（~/.gradle/caches/build-cache-1），
    与项目路径无关——worktree 每次路径都不同，这是跨目录复用编译结果的唯一有效手段。
    只写入 worktree 内的 gradle.properties，随目录销毁，不影响工程文件。
    """
    props = work_dir / "android" / "gradle.properties"
    if not props.is_file():
        return
    try:
        text = props.read_text(encoding="utf-8")
        if "org.gradle.caching" in text:
            return
        props.write_text(
            text.rstrip() + "\norg.gradle.caching=true\n", encoding="utf-8"
        )
        print("[Android] 已启用 Gradle Build Cache（仅写入隔离目录 gradle.properties）")
    except OSError as exc:
        print(f"[Android] 写入 gradle.properties 失败，跳过 Build Cache: {exc}")


def build_android(cfg: BuildConfig, session: WorktreeSession) -> Path:
    """执行 Android 打包，返回 APK 路径。"""
    check_tool("flutter")
    work_dir = session.work_dir
    cfg_android = cfg.android

    cmd = ["flutter", "build", "apk", "--release"]
    target_platforms = cfg_android.get("target_platforms")
    if isinstance(target_platforms, list) and target_platforms:
        cmd += ["--target-platform", *[str(item) for item in target_platforms]]
    # 版本参数三端通用：仅在显式指定时追加，未指定则用工程自身版本
    if cfg.build_number:
        cmd += ["--build-number", cfg.build_number]
    if cfg.build_name:
        cmd += ["--build-name", cfg.build_name]

    if cfg_android.get("build_cache", True) and session.isolated:
        _enable_build_cache(work_dir)

    print(f"\n>>> [Android]: {' '.join(cmd)}")
    completed = subprocess.run(cmd, cwd=work_dir)
    if completed.returncode != 0:
        print(
            "[Android] 提示: 若上方日志是依赖解析/下载超时（Read timed out），通常是仓库列表中靠前"
            "的 maven 仓库不可达且该依赖从未成功下载过；请确认公司内网/VPN 可达后重跑一次，"
            "成功后依赖将永久缓存于 ~/.gradle，之后可离线构建。编译类错误请直接查看上方日志。"
        )
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

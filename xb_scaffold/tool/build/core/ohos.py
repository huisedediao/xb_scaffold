"""鸿蒙(ohos)构建：flutter build hap/app --release，产物复制到输出目录。

依赖支持 ohos 平台的 Flutter 工具链（ohos 定制版）。目标项目需存在
ohos/ 目录且已按官方指引完成签名配置，签名在工程内配置、不做注入。
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

from .android import _newest_artifact
from .config import BuildConfig
from .worktree import WorktreeSession, check_tool


def _reuse_oh_modules(src_ohos: Path, dst_ohos: Path) -> None:
    """复用主目录的鸿蒙依赖（oh_modules 目录 + oh-package-lock.json5），
    避免隔离构建时 ohpm 全量网络下载。

    与 iOS 复用 Pods 同哲学：预置后由 ohpm/hvigor 自行校验增量；
    源缺失或复制失败时静默回退全量安装，不影响构建正确性。
    """
    for rel in ("oh_modules", "oh-package-lock.json5"):
        src = src_ohos / rel
        dst = dst_ohos / rel
        if not src.exists() or dst.exists():
            continue
        try:
            if src.is_dir():
                subprocess.run(["rsync", "-a", f"{src}/", f"{dst}/"], check=True)
            else:
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, dst)
        except (subprocess.CalledProcessError, FileNotFoundError):
            print(f"[Ohos] 依赖 {rel} 复用失败，将执行全量依赖安装")
            return
        print(f"[Ohos] 已复用 {rel}: {dst}")


def build_ohos(cfg: BuildConfig, session: WorktreeSession) -> Path:
    """执行鸿蒙打包，返回产物（.hap/.app）路径。"""
    check_tool("flutter")
    work_dir = session.work_dir
    ohos_dir = work_dir / "ohos"
    if not ohos_dir.is_dir():
        raise SystemExit("[Ohos] 未找到 ohos/ 目录，无法打包")

    cfg_ohos = cfg.ohos
    # 1. 复用主目录 ohos 依赖（仅隔离构建时生效，思路同 iOS 复用 Pods）
    if cfg_ohos.get("reuse_oh_modules", True) and session.isolated:
        _reuse_oh_modules(session.project_dir / "ohos", ohos_dir)
    package_type = str(cfg_ohos.get("package_type") or "hap")
    if package_type not in ("hap", "app"):
        raise SystemExit(f"[Ohos] 不支持的包类型: {package_type}（可选 hap/app）")

    cmd = ["flutter", "build", package_type, "--release"]
    flavor = str(cfg_ohos.get("flavor") or "").strip()
    if flavor:
        cmd += ["--flavor", flavor]
    # 版本参数三端通用：仅在显式指定时追加，未指定则用工程自身版本
    if cfg.build_number:
        cmd += ["--build-number", cfg.build_number]
    if cfg.build_name:
        cmd += ["--build-name", cfg.build_name]

    print(f"\n>>> [Ohos]: {' '.join(cmd)}")
    completed = subprocess.run(cmd, cwd=work_dir)
    if completed.returncode != 0:
        raise SystemExit(f"[Ohos] 构建失败，退出码 {completed.returncode}")

    suffix = ".hap" if package_type == "hap" else ".app"
    artifact = _newest_artifact(
        [
            str(ohos_dir / "build" / "outputs" / "**" / f"*{suffix}"),
            str(ohos_dir / "entry" / "build" / "**" / f"*{suffix}"),
        ]
    )
    if artifact is None:
        raise SystemExit(f"[Ohos] 未找到构建产物（{suffix}）")

    cfg.output_dir.mkdir(parents=True, exist_ok=True)
    target = cfg.output_dir / f"{cfg.name}{suffix}"
    shutil.copy2(artifact, target)
    print(f"\n[Ohos] 打包完成: {target}")
    return target

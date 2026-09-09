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


def build_ohos(cfg: BuildConfig, session: WorktreeSession) -> Path:
    """执行鸿蒙打包，返回产物（.hap/.app）路径。"""
    check_tool("flutter")
    work_dir = session.work_dir
    ohos_dir = work_dir / "ohos"
    if not ohos_dir.is_dir():
        raise SystemExit("[Ohos] 未找到 ohos/ 目录，无法打包")

    cfg_ohos = cfg.ohos
    package_type = str(cfg_ohos.get("package_type") or "hap")
    if package_type not in ("hap", "app"):
        raise SystemExit(f"[Ohos] 不支持的包类型: {package_type}（可选 hap/app）")

    cmd = ["flutter", "build", package_type, "--release"]
    flavor = str(cfg_ohos.get("flavor") or "").strip()
    if flavor:
        cmd += ["--flavor", flavor]

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

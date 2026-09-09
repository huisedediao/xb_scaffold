"""iOS 构建：pub get → pod install →（可选补丁）→ xcodebuild archive。

签名通用化（不修改工程文件）：
xcodebuild 命令行 build setting 优先级高于 project.pbxproj 内配置，
证书/描述文件等信息按签名样式注入到 archive 命令末尾：
- style=automatic: CODE_SIGN_STYLE=Automatic + DEVELOPMENT_TEAM + -allowProvisioningUpdates
- style=manual:    CODE_SIGN_STYLE=Manual + CODE_SIGN_IDENTITY + PROVISIONING_PROFILE_SPECIFIER
- style=none:      不注入，使用工程自带签名配置
另外保留可选 patch_files 兜底机制（备份→覆盖→还原），用于极少数
build setting 无法表达的工程结构调整，默认关闭。
"""

from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Any

from .config import BuildConfig
from .pods import reuse_pods
from .worktree import WorktreeSession, check_tool

_ARCHIVE_SUFFIX = ".xcarchive"


def _run(cmd: list[str], cwd: Path, step: str) -> None:
    print(f"\n>>> [iOS] {step}: {' '.join(cmd)}")
    completed = subprocess.run(cmd, cwd=cwd)
    if completed.returncode != 0:
        raise SystemExit(f"[iOS] {step} 失败，退出码 {completed.returncode}")


def _ensure_toolchain() -> None:
    check_tool("flutter")
    check_tool("pod")
    check_tool("xcodebuild")
    check_tool("rsync")


def _signing_settings(cfg_ios: dict) -> tuple[list[str], bool]:
    """按签名样式生成 xcodebuild 追加参数；返回 (settings, allow_provisioning_updates)。"""
    signing = cfg_ios.get("signing", {}) or {}
    style = signing.get("style", "none")
    settings: list[str] = []
    if style == "automatic":
        settings.append("CODE_SIGN_STYLE=Automatic")
        team = str(signing.get("team") or "").strip()
        if not team:
            raise SystemExit(
                "[iOS] 签名样式为 automatic 但未配置 DEVELOPMENT_TEAM；"
                "请在用户级配置 ~/.xb_build_config.json 的 ios.signing.team 中填写"
            )
        settings.append(f"DEVELOPMENT_TEAM={team}")
        print(f"[iOS] 签名: 自动签名 (team={team})")
    elif style == "manual":
        settings.append("CODE_SIGN_STYLE=Manual")
        identity = str(signing.get("identity") or "").strip()
        profile = str(signing.get("profile") or "").strip()
        if identity:
            settings.append(f"CODE_SIGN_IDENTITY={identity}")
        if profile:
            settings.append(f"PROVISIONING_PROFILE_SPECIFIER={profile}")
        team = str(signing.get("team") or "").strip()
        if team:
            settings.append(f"DEVELOPMENT_TEAM={team}")
        print(f"[iOS] 签名: 手动 (profile={profile or '未配置'})")
    else:
        print("[iOS] 签名: 使用工程自带配置")
    allow_updates = bool(cfg_ios.get("allow_provisioning_updates", True))
    return settings, allow_updates


class _Patches:
    """文件补丁兜底：备份工程文件→用本地补丁覆盖→restore() 还原。"""

    def __init__(self, project_dir: Path, work_dir: Path, patch_map: dict):
        self._project_dir = project_dir
        self._work_dir = work_dir
        self._patch_map = patch_map if isinstance(patch_map, dict) else {}
        self._backups: list[tuple[Path, Path]] = []  # (工程文件, 备份文件)

    @property
    def enabled(self) -> bool:
        return bool(self._patch_map)

    def apply(self) -> None:
        for target_rel, patch_rel in self._patch_map.items():
            target = self._work_dir / str(target_rel)
            patch = self._project_dir / str(patch_rel)
            if not patch.is_file():
                print(f"警告: 补丁文件不存在，跳过: {patch}")
                continue
            if not target.is_file():
                print(f"警告: 补丁目标文件不存在，跳过: {target}")
                continue
            with tempfile.NamedTemporaryFile(delete=False) as backup_file:
                backup = Path(backup_file.name)
            shutil.copy2(target, backup)
            shutil.copy2(patch, target)
            self._backups.append((target, backup))
            print(f"已应用补丁: {patch} -> {target}（构建后自动还原）")

    def restore(self) -> None:
        for target, backup in self._backups:
            shutil.copy2(backup, target)
            backup.unlink(missing_ok=True)
        self._backups.clear()


def build_ios(cfg: BuildConfig, session: WorktreeSession) -> Path:
    """执行 iOS 打包，返回 xcarchive 路径。"""
    _ensure_toolchain()
    cfg_ios: dict[str, Any] = cfg.ios
    work_dir = session.work_dir
    ios_dir = work_dir / "ios"
    if not ios_dir.is_dir():
        raise SystemExit("[iOS] 未找到 ios/ 目录，无法打包")

    # 1. 复用 Pods（仅隔离构建时生效；源目录必须是真实项目的 ios/Pods）
    if cfg_ios.get("reuse_pods", True) and session.isolated:
        reuse_pods(session.project_dir / "ios" / "Pods", ios_dir / "Pods")

    # 2. 刷新依赖并生成 iOS 工程辅助文件
    _run(["flutter", "pub", "get"], work_dir, "flutter pub get")
    _run(["pod", "install"], ios_dir, "pod install")

    # 3. 补丁兜底（须在 pod install 之后，否则会冲掉 CocoaPods 的工程集成）
    patches = _Patches(
        session.project_dir, work_dir, cfg_ios.get("patch_files", {})
    )
    try:
        patches.apply()

        # 4. xcodebuild archive
        scheme = str(cfg_ios.get("scheme") or "Runner")
        configuration = str(cfg_ios.get("configuration") or "Release")
        workspace_rel = str(cfg_ios.get("workspace") or "ios/Runner.xcworkspace")
        workspace = work_dir / workspace_rel
        if not workspace.is_dir():
            workspace = ios_dir / f"{scheme}.xcworkspace"
        if not workspace.is_dir():
            raise SystemExit(f"[iOS] 找不到 workspace: {workspace_rel}")

        archive_path = cfg.output_dir / f"{cfg.name}{_ARCHIVE_SUFFIX}"
        archive_path.parent.mkdir(parents=True, exist_ok=True)
        if archive_path.exists():
            shutil.rmtree(archive_path)
            print(f"[iOS] 已清理旧的归档: {archive_path}")

        cmd = [
            "xcodebuild",
            "-workspace",
            str(workspace),
            "-scheme",
            scheme,
            "-configuration",
            configuration,
            "-sdk",
            "iphoneos",
            "archive",
            "-archivePath",
            str(archive_path),
        ]
        signing_settings, allow_updates = _signing_settings(cfg_ios)
        cmd += signing_settings
        if allow_updates:
            cmd.append("-allowProvisioningUpdates")
        # 版本号通过命令行覆盖（优先级高于 xcconfig），无需改工程文件
        build_number = str(cfg_ios.get("build_number") or "").strip()
        build_name = str(cfg_ios.get("build_name") or "").strip()
        if build_number:
            cmd.append(f"FLUTTER_BUILD_NUMBER={build_number}")
        if build_name:
            cmd.append(f"FLUTTER_BUILD_NAME={build_name}")
        extra = cfg_ios.get("extra_settings", [])
        cmd += [str(item) for item in extra] if isinstance(extra, list) else []

        _run(cmd, work_dir, "xcodebuild archive")
        if not archive_path.is_dir():
            raise SystemExit(f"[iOS] 归档未生成: {archive_path}")
        print(f"\n[iOS] 归档完成: {archive_path}")
        return archive_path
    finally:
        patches.restore()

"""iOS 构建：pub get → pod install →（可选补丁）→ xcodebuild archive。

签名通用化：证书/描述文件等信息按用户级 ios.signing 配置注入到
xcodebuild 命令末尾（命令行优先级高于 project.pbxproj）：
- style=automatic: CODE_SIGN_STYLE=Automatic + DEVELOPMENT_TEAM + -allowProvisioningUpdates
- style=manual:    CODE_SIGN_STYLE=Manual + CODE_SIGN_IDENTITY + PROVISIONING_PROFILE_SPECIFIER
- style=none:      不注入，使用工程自带签名配置
若工程文件残留与用户级配置冲突的签名设置（如手动 profile/identity 残留
或签名样式不一致，Xcode 会报 conflicting provisioning settings），打包前
临时按用户级配置改写 project.pbxproj，构建完成后自动还原，不影响工程。
另外保留可选 patch_files 兜底机制（备份→覆盖→还原），用于极少数
build setting 无法表达的工程结构调整，默认关闭。
"""

from __future__ import annotations

import re
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


# pbxproj 中签名行的值可能带引号（含空串/特殊字符）也可能不带（简单标识符）。
_PROFILE_LINE_RE = re.compile(
    r'^(?P<head>\s*(?:"PROVISIONING_PROFILE_SPECIFIER\[sdk=[^"]*\]"'
    r'|PROVISIONING_PROFILE_SPECIFIER)\s*=\s*)(?:"[^"]*"|[^;\n]*?)'
    r'[ \t]*;(?=[ \t]*(?:\r?\n|$))',
    re.M,
)
_STYLE_LINE_RE = re.compile(
    r'^(?P<head>\s*CODE_SIGN_STYLE\s*=\s*)(?:"[^"]*"|[^;\n]*?)'
    r'[ \t]*;(?=[ \t]*(?:\r?\n|$))',
    re.M,
)
_IDENTITY_LINE_RE = re.compile(
    r'^(?P<head>\s*(?:"CODE_SIGN_IDENTITY\[sdk=[^"]*\]"'
    r'|CODE_SIGN_IDENTITY)\s*=\s*)(?:"[^"]*"|[^;\n]*?)'
    r'[ \t]*;(?=[ \t]*(?:\r?\n|$))',
    re.M,
)


def _find_pbxproj(ios_dir: Path):
    """定位 ios/ 下的 project.pbxproj（优先 Runner.xcodeproj）。"""
    cand = ios_dir / "Runner.xcodeproj" / "project.pbxproj"
    if cand.is_file():
        return cand
    for proj in sorted(ios_dir.glob("*.xcodeproj")):
        cand = proj / "project.pbxproj"
        if cand.is_file():
            return cand
    print("[iOS] 未找到 project.pbxproj，跳过工程签名配置对齐")
    return None


def _reconcile_signing(pbxproj: Path, cfg_ios: dict):
    """按用户级 ios.signing 配置生成对齐后的 pbxproj 文本；无差异返回 None。

    工程文件里残留的手动 profile（PROVISIONING_PROFILE_SPECIFIER 非空）或
    不一致的 CODE_SIGN_STYLE，会使 Xcode 报 conflicting provisioning settings。
    这里把签名相关行统一改写成用户级配置期望的形态，由调用方在构建后还原：
    - style=automatic: profile 全部置空，identity -> "Apple Development"，
      CODE_SIGN_STYLE -> Automatic（Xcode 要求自动签名配 Apple Development 证书）
    - style=manual:    profile/identity 统一为用户配置值（未配则置空），样式 -> Manual
    - style=none:      不改动，使用工程自带配置
    """
    signing = cfg_ios.get("signing", {}) or {}
    style = str(signing.get("style") or "none").strip()
    if style not in ("automatic", "manual"):
        return None
    try:
        text = pbxproj.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"[iOS] 读取 {pbxproj} 失败，跳过签名配置对齐: {exc}")
        return None

    target_style = "Automatic" if style == "automatic" else "Manual"
    target_profile = "" if style == "automatic" else str(signing.get("profile") or "").strip()
    target_identity = (
        "Apple Development"
        if style == "automatic"
        else str(signing.get("identity") or "").strip()
    )

    def _align_profile(m: re.Match) -> str:
        return f'{m.group("head")}"{target_profile}";'

    def _align_style(m: re.Match) -> str:
        return f'{m.group("head")}{target_style};'

    def _align_identity(m: re.Match) -> str:
        return f'{m.group("head")}"{target_identity}";'

    aligned = _PROFILE_LINE_RE.sub(_align_profile, text)
    aligned = _STYLE_LINE_RE.sub(_align_style, aligned)
    aligned = _IDENTITY_LINE_RE.sub(_align_identity, aligned)
    if aligned == text:
        return None
    return aligned


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
    pbxproj = _find_pbxproj(ios_dir)
    signing_backup = None
    try:
        patches.apply()

        # 3.5 工程签名配置对齐：automatic/manual 时按用户级配置临时改写
        # pbxproj 残留（如手动 profile 与自动签名冲突），构建后 finally 还原。
        if pbxproj is not None:
            aligned = _reconcile_signing(pbxproj, cfg_ios)
            if aligned is not None:
                signing_backup = pbxproj.read_text(encoding="utf-8")
                pbxproj.write_text(aligned, encoding="utf-8")
                print(
                    f"[iOS] 工程签名配置已按用户级配置对齐"
                    f"（构建后自动还原）: {pbxproj}"
                )

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
        build_number = cfg.build_number
        build_name = cfg.build_name
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
        if signing_backup is not None and pbxproj is not None:
            try:
                pbxproj.write_text(signing_backup, encoding="utf-8")
            except OSError as exc:
                print(f"[iOS] 还原工程签名配置失败: {exc}")
        patches.restore()

#!/usr/bin/env python3
"""xb.build - 通用 Flutter 多平台打包工具（worktree 隔离 + iOS Pods 复用）。

用法:
  python3 xb_build.py [--project-dir <路径>] [--platform android|ios|ohos ...]
                      [--build-number <num>] [--build-name <版本>] [--ohos hap|app]
                      [--no-worktree] [--no-reuse-pods] [--dry-run] [--config <路径>]

配置层级（后加载者覆盖前者）:
  内置默认值 < 项目级 .xb_build_config.json < 用户级 ~/.xb_build_config.json < 命令行
  签名证书等个人配置放在用户级文件，勿提交 git。
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from core.android import build_android
from core.config import BuildConfig
from core.ios import build_ios
from core.ohos import build_ohos
from core.worktree import WorktreeSession, resolve_repo, check_tool


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="xb.build",
        description="通用 Flutter 多平台打包（git worktree 隔离构建）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "示例:\n"
            "  python3 xb_build.py                                  # 自动检测平台全量打包\n"
            "  python3 xb_build.py --platform ios                   # 只打 iOS\n"
            "  python3 xb_build.py --platform ios --build-number 100 --build-name 1.2.0\n"
            "  python3 xb_build.py --dry-run                        # 仅校验配置与环境\n"
        ),
    )
    parser.add_argument("--project-dir", default=".", help="目标 Flutter 项目根（默认当前目录）")
    parser.add_argument(
        "--platform",
        nargs="+",
        choices=["android", "ios", "ohos", "auto"],
        help="要构建的平台；默认 auto（按工程目录自动检测）",
    )
    parser.add_argument("--ohos", choices=["hap", "app"], help="鸿蒙包类型")
    parser.add_argument("--build-number", help="iOS CFBundleVersion")
    parser.add_argument("--build-name", help="iOS CFBundleShortVersionString")
    parser.add_argument("--config", help="额外配置文件路径（最低优先级之外的覆盖层）")
    parser.add_argument("--no-worktree", action="store_true", help="关闭 worktree 隔离，直接构建")
    parser.add_argument("--no-reuse-pods", action="store_true", help="不复用项目已有 ios/Pods")
    parser.add_argument("--dry-run", action="store_true", help="只解析配置与校验环境，不执行构建")
    parser.add_argument("--open", action="store_true", help="构建完成后打开输出目录")
    return parser.parse_args()


def _cli_overrides(args: argparse.Namespace) -> dict:
    """把命令行参数翻译成配置覆盖层。"""
    overrides: dict = {}
    if args.platform and args.platform != ["auto"]:
        overrides["platforms"] = args.platform
    if args.ohos:
        overrides.setdefault("ohos", {})["package_type"] = args.ohos
    if args.build_number:
        overrides["build_number"] = args.build_number
    if args.build_name:
        overrides["build_name"] = args.build_name
    if args.no_worktree:
        overrides["git_worktree"] = False
    if args.no_reuse_pods:
        overrides.setdefault("ios", {})["reuse_pods"] = False
    return overrides


def _load_extra_config(path: Path) -> dict:
    if not path.is_file():
        raise SystemExit(f"配置文件不存在: {path}")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise SystemExit(f"配置文件解析失败 {path}: {exc}")
    return data if isinstance(data, dict) else {}


def _run_platform(platform: str, cfg: BuildConfig, session: WorktreeSession) -> None:
    if platform == "android":
        build_android(cfg, session)
    elif platform == "ios":
        build_ios(cfg, session)
    elif platform == "ohos":
        build_ohos(cfg, session)


def _dry_run(cfg: BuildConfig, args: argparse.Namespace) -> None:
    print("=" * 60)
    print("dry-run 配置预览:")
    for line in cfg.describe():
        print(f"  {line}")

    print("\n环境检测:")
    for tool in ("git", "flutter"):
        try:
            check_tool(tool)
            print(f"  [OK] {tool}: 可用")
        except SystemExit as exc:
            print(f"  [!!] {exc}")
    repo = resolve_repo(cfg.project_dir)
    if repo is None:
        print("  [!!] 项目不在 git 仓库中（无法使用 worktree 隔离）")
    else:
        print(f"  [OK] git 仓库顶层: {repo.toplevel}")
        print(f"  [OK] 项目相对仓库位置: {repo.relative_sub or '.'}")
        print(f"  [OK] 当前检出是 worktree: {repo.linked_worktree}")
    if "ios" in cfg.platforms:
        pods = cfg.project_dir / "ios" / "Pods"
        print(f"  [{'OK' if pods.is_dir() else '!!'}] ios/Pods 复用源: "
              f"{'存在（将跳过全量下载）' if pods.is_dir() else '不存在（将全量 pod install）'}")
        for tool in ("pod", "xcodebuild", "rsync"):
            try:
                check_tool(tool)
                print(f"  [OK] {tool}: 可用")
            except SystemExit as exc:
                print(f"  [!!] {exc}")
    print("=" * 60)
    print("dry-run 结束：未执行任何构建动作。")


def main() -> int:
    args = _parse_args()
    project_dir = Path(args.project_dir).expanduser().resolve()
    if not (project_dir / "pubspec.yaml").is_file():
        print(f"错误: {project_dir} 不是 Flutter 项目（缺少 pubspec.yaml）", file=sys.stderr)
        return 64

    extra_config = _load_extra_config(Path(args.config).expanduser()) if args.config else None
    overrides = _cli_overrides(args)
    if extra_config:
        overrides = {**extra_config, **overrides}
    cfg = BuildConfig(project_dir, cli_overrides=overrides)

    if not cfg.platforms:
        print(f"提示: 项目目录中未检测到 android/ios/ohos 平台目录，无平台可构建。", file=sys.stderr)
        return 0
    if args.dry_run:
        _dry_run(cfg, args)
        return 0

    session = WorktreeSession(cfg.project_dir, enabled=cfg.use_worktree)
    try:
        cfg.output_dir.mkdir(parents=True, exist_ok=True)
        for platform in cfg.platforms:
            print(f"\n{'=' * 60}\n开始构建平台: {platform}\n{'=' * 60}")
            _run_platform(platform, cfg, session)
        print(f"\n全部平台构建完成，产物目录: {cfg.output_dir}")
        if args.open:
            import subprocess

            subprocess.run(["open", str(cfg.output_dir)])
    finally:
        session.cleanup()
    return 0


if __name__ == "__main__":
    sys.exit(main())

"""配置加载与合并：默认值 <- 项目级 .xb_build_config.json <- 用户级 ~/.xb_build_config.json <- CLI。

分层原则：项目级配置随 git 共享；签名证书等个人/机器属性放在用户级配置，
保持任何项目 clone 后仅需配置一次本机签名即可打包。
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

CONFIG_FILE_NAME = ".xb_build_config.json"
USER_CONFIG_PATH = Path.home() / CONFIG_FILE_NAME

_PUBSPEC_NAME_RE = re.compile(r"^name\s*:\s*(\S+)", re.MULTILINE)
_PUBSPEC_PATH_RE = re.compile(r"^(\s+)path\s*:\s*(\S+)", re.MULTILINE)

DEFAULT_CONFIG: dict[str, Any] = {
    "project_name": "",  # 空 -> 自动读取 pubspec name
    "output_dir": "~/Desktop/xb_build",
    "platforms": ["auto"],  # auto=按 android/ios/ohos 目录自动检测；可显式指定子集
    "git_worktree": True,
    # 三端通用版本覆盖；不填则各平台使用工程自身配置
    "build_name": "",
    "build_number": "",
    "ios": {
        "scheme": "Runner",
        "workspace": "ios/Runner.xcworkspace",
        "configuration": "Release",
        # style: none(用工程自带配置) | automatic(自动签名+team) | manual(手动描述文件)
        "signing": {
            "style": "none",
            "team": "",
            "identity": "Apple Distribution",
            "profile": "",
        },
        "allow_provisioning_updates": True,
        "reuse_pods": True,
        # 兜底机制：工程文件(键,相对项目根) -> 本地补丁文件(值,相对项目根)。
        # 构建前备份并用补丁覆盖，构建后自动还原；默认不使用。
        "patch_files": {},
        # 追加到 xcodebuild 的自定义 build setting（如 ENABLE_BITCODE=NO）
        "extra_settings": [],
    },
    "android": {
        "target_platforms": None,  # None=flutter 默认；如 ["android-arm64"]
        "apk_name": "",  # 空 -> <project_name>.apk
    },
    "ohos": {
        "package_type": "hap",  # hap | app
        "flavor": "",  # 空则不传 --flavor
    },
}


def _deep_merge(base: dict, override: dict) -> dict:
    """深度合并两个 dict，override 优先；返回新 dict。"""
    result = dict(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = _deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def _load_json(path: Path) -> dict:
    if not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise SystemExit(f"配置文件解析失败 {path}: {exc}")
    return data if isinstance(data, dict) else {}


def read_pubspec_name(project_dir: Path) -> str:
    pubspec = project_dir / "pubspec.yaml"
    if not pubspec.is_file():
        return ""
    match = _PUBSPEC_NAME_RE.search(
        pubspec.read_text(encoding="utf-8", errors="ignore")
    )
    return match.group(1).strip() if match else ""


def read_pubspec_path_deps(pubspec_path: Path) -> list[str]:
    """读取 pubspec.yaml 中依赖块里 path 依赖的相对路径（按出现顺序去重）。"""
    if not pubspec_path.is_file():
        return []
    content = pubspec_path.read_text(encoding="utf-8", errors="ignore")
    result: list[str] = []
    seen: set[str] = set()
    for match in _PUBSPEC_PATH_RE.finditer(content):
        indent = match.group(1)
        # path 依赖行要求行首有缩进（处于某个依赖 key 之下）；
        # ^(\s+) 已保证至少一个空白，仅需防跨行匹配吞入换行
        if "\n" in indent:
            continue
        rel = match.group(2)
        if rel not in seen:
            seen.add(rel)
            result.append(rel)
    return result


def detect_platforms(project_dir: Path, configured: Any) -> list[str]:
    """按配置或自动检测得到实际要构建的平台列表（保持配置声明顺序）。"""
    if not isinstance(configured, list) or not configured:
        configured = ["auto"]
    if "auto" in configured:
        return [p for p in ("android", "ios", "ohos") if (project_dir / p).is_dir()]
    return [p for p in configured if p in ("android", "ios", "ohos")]


class BuildConfig:
    """合并后的配置视图。"""

    def __init__(
        self,
        project_dir: Path,
        *,
        cli_overrides: dict[str, Any] | None = None,
        user_config_path: Path = USER_CONFIG_PATH,
    ):
        self.project_dir = project_dir
        project_cfg = _load_json(project_dir / CONFIG_FILE_NAME)
        user_cfg = _load_json(user_config_path)
        data = _deep_merge(
            _deep_merge(_deep_merge(DEFAULT_CONFIG, project_cfg), user_cfg),
            cli_overrides or {},
        )
        self.data = data
        self.name = data.get("project_name") or read_pubspec_name(project_dir) or "app"
        self.platforms = detect_platforms(project_dir, data.get("platforms"))
        self.use_worktree = bool(data.get("git_worktree", True))
        output = Path(str(data.get("output_dir") or "~/Desktop/xb_build")).expanduser()
        self.output_dir = output if output.is_absolute() else (project_dir / output)
        self.ios: dict = data.get("ios", {}) or {}
        self.android: dict = data.get("android", {}) or {}
        self.ohos: dict = data.get("ohos", {}) or {}
        # 版本参数三端通用：优先顶层，兼容历史配置写在 ios 段
        self.build_name = str(
            data.get("build_name") or self.ios.get("build_name") or ""
        ).strip()
        self.build_number = str(
            data.get("build_number") or self.ios.get("build_number") or ""
        ).strip()

    def get(self, key: str, default: Any = None) -> Any:
        return self.data.get(key, default)

    def describe(self) -> list[str]:
        lines = [
            f"项目目录: {self.project_dir}",
            f"项目名称: {self.name}",
            f"构建平台: {', '.join(self.platforms) or '(无)'}",
            f"输出目录: {self.output_dir}",
            f"worktree 隔离: {'开启' if self.use_worktree else '关闭'}",
        ]
        if "ios" in self.platforms:
            signing = self.ios.get("signing", {})
            lines.append(
                "iOS 签名: "
                + {
                    "none": "使用工程自带配置",
                    "automatic": f"自动签名(team={signing.get('team') or '未配置'})",
                    "manual": f"手动(profile={signing.get('profile') or '未配置'}, "
                    f"identity={signing.get('identity') or '未配置'})",
                }.get(signing.get("style"), signing.get("style", "none"))
            )
        return lines

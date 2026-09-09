"""git worktree 隔离构建 + pubspec 路径依赖软链。

在临时 worktree（HEAD 快照）中构建，保证打包代码与 git HEAD 一致、
不受工作区未提交改动影响；构建结束自动清理。

支持两类项目形态：
- 项目根 == git 仓库顶层（最常见）
- 项目根是 git 仓库内的子目录（monorepo 子项目，如 example/）
"""

from __future__ import annotations

import atexit
import shutil
import signal
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

from .config import read_pubspec_path_deps


def _git(args: list[str], cwd: Path) -> str:
    completed = subprocess.run(
        ["git", *args], cwd=cwd, capture_output=True, text=True
    )
    if completed.returncode != 0:
        raise RuntimeError(f"git {args[0]} 失败: {completed.stderr.strip()}")
    return completed.stdout.strip()


@dataclass
class RepoInfo:
    toplevel: Path  # git 仓库顶层目录
    linked_worktree: bool  # 当前检出本身是否已是 git worktree
    relative_sub: Path | None  # 项目根相对 toplevel；None 表示二者相同


def resolve_repo(project_dir: Path) -> RepoInfo | None:
    """解析项目根所属的 git 仓库信息；非 git 仓库返回 None。"""
    try:
        toplevel = Path(_git(["rev-parse", "--show-toplevel"], project_dir))
        git_dir = _git(["rev-parse", "--git-dir"], project_dir)
    except RuntimeError:
        return None
    linked = "/worktrees/" in git_dir
    try:
        relative_sub = project_dir.resolve().relative_to(toplevel.resolve())
    except ValueError:
        return None
    return RepoInfo(toplevel=toplevel, linked_worktree=linked, relative_sub=relative_sub)


class WorktreeSession:
    """隔离构建会话：退出（含异常）时自动清理临时 worktree。"""

    def __init__(self, project_dir: Path, enabled: bool):
        self.project_dir = project_dir.resolve()
        self.work_dir = self.project_dir  # 隔离后变为 worktree 内对应目录
        self._temp_dir: Path | None = None
        self._symlinks: list[Path] = []
        self._cleaned = False

        repo = resolve_repo(self.project_dir)
        if not enabled:
            print("已关闭 worktree 隔离，直接在当前目录构建。")
            return
        if repo is None:
            print("项目不在 git 仓库中，无法隔离，直接在当前目录构建。")
            return
        if repo.linked_worktree:
            print("当前检出本身已是 git worktree，跳过嵌套隔离，直接构建。")
            return

        branch = _git(["rev-parse", "--abbrev-ref", "HEAD"], repo.toplevel).replace(
            "/", "-"
        )
        # resolve() 统一为真实路径：macOS 上 /var 是 /private/var 的符号链接，
        # 不 resolve 会导致后续与 resolve() 后的路径比较（软链落点边界）误判
        temp_dir = Path(
            tempfile.mkdtemp(prefix=f"xb-build-{repo.toplevel.name}-{branch}-")
        ).resolve()
        _git(["worktree", "add", "--detach", str(temp_dir), "HEAD"], repo.toplevel)

        self._temp_dir = temp_dir
        self.work_dir = temp_dir
        if repo.relative_sub is not None and repo.relative_sub != Path("."):
            self.work_dir = temp_dir / repo.relative_sub
            self.work_dir.mkdir(parents=True, exist_ok=True)
        print(f"已创建隔离 worktree: {temp_dir}")
        print(f"构建目录: {self.work_dir}")

        self._link_path_deps(repo)
        atexit.register(self.cleanup)
        signal.signal(signal.SIGTERM, lambda *_: (self.cleanup(), _exit(143)))

    @property
    def isolated(self) -> bool:
        return self._temp_dir is not None

    def _link_path_deps(self, repo: RepoInfo) -> None:
        """把 pubspec path 依赖（../xxx 型）软链到隔离环境对应位置。"""
        pubspec = self.work_dir / "pubspec.yaml"
        if not pubspec.is_file():
            return
        temp_root = self._temp_dir
        for rel in read_pubspec_path_deps(pubspec):
            if not rel.startswith(".."):
                continue
            src = (self.project_dir / rel).resolve()
            dst = (self.work_dir / rel).resolve()
            if src == dst or not src.exists() or dst.exists():
                continue
            # 软链落点仅允许在临时 worktree 或其父级（系统临时区）内，防止越界
            try:
                dst.relative_to(temp_root.parent)
            except ValueError:
                print(f"警告: 路径依赖 {rel} 落点超出临时区，跳过（本次可能需网络解析依赖）")
                continue
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.symlink_to(src)
            self._symlinks.append(dst)
            print(f"已软链路径依赖: {dst} -> {src}")

    def cleanup(self) -> None:
        if self._cleaned:
            return
        self._cleaned = True
        for link in self._symlinks:
            if link.is_symlink():
                link.unlink(missing_ok=True)
        if self._temp_dir is None:
            return
        temp_dir = self._temp_dir
        # worktree add 时该目录已被 git 使用，清理归属 git
        subprocess.run(
            ["git", "worktree", "remove", "--force", str(temp_dir)],
            capture_output=True,
        )
        if temp_dir.exists():
            shutil.rmtree(temp_dir, ignore_errors=True)
        print(f"已清理临时 worktree: {temp_dir}")


def _exit(code: int) -> None:
    import sys

    sys.exit(code)


def check_tool(name: str) -> str:
    """校验工具链命令存在，返回其路径。"""
    path = shutil.which(name)
    if not path:
        raise SystemExit(f"未找到命令: {name}，请先安装对应工具链")
    return path

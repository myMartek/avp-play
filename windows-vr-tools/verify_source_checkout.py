"""Reject source worktrees that do not represent their pinned Git revisions."""
from pathlib import Path
import subprocess


def verify_source_checkout(source: Path, revision: str) -> None:
    def git(*args):
        return subprocess.check_output(["git", "-C", str(source), *args], text=True).strip()

    if git("rev-parse", "HEAD") != revision:
        raise SystemExit(f"Source revision does not match its lock: {source}")
    status = git("status", "--porcelain", "--untracked-files=all", "--ignore-submodules=none")
    if status:
        raise SystemExit(f"Pinned source has local or submodule changes: {source}\n{status}")
    # A clean superproject can still contain uninitialized submodules. Check
    # every gitlink, including nested dependencies, before copying its sources.
    for line in git("submodule", "status", "--recursive").splitlines():
        # Do not strip individual lines: their first character is Git's status.
        if line and line[0] in "-+U":
            raise SystemExit(f"Pinned source has an uninitialized or mismatched submodule: {line}")

#!/usr/bin/env python3
"""Acquire pinned source only. Never configure, compile, test, or execute dependencies."""
import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def git(*arguments, directory=None):
    return subprocess.run(["git", *arguments], cwd=directory, check=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache-root", type=Path, default=ROOT / "third-party")
    parser.add_argument("--include-d3d12-experimental", action="store_true",
                        help="Also acquire the isolated, currently unported D3D12 DXMT source profile")
    args = parser.parse_args()
    args.cache_root.mkdir(parents=True, exist_ok=True)
    lock = json.loads((ROOT / "windows-vr-tools/sources.lock.json").read_text())
    for source in lock["sources"]:
        if source["name"] == "dxmt-d3d12-experimental" and not args.include_d3d12_experimental:
            continue
        destination = args.cache_root / source["name"]
        if not destination.exists():
            git("clone", "--no-checkout", source["url"], str(destination))
        # Fetch and check out the pinned ref without resetting user changes.
        git("fetch", "origin", source["revision"], directory=destination)
        git("checkout", "--detach", source["revision"], directory=destination)
        if source["recursive"]:
            git("submodule", "update", "--init", "--recursive", directory=destination)

if __name__ == "__main__":
    main()

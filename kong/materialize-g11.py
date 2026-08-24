#!/usr/bin/env python3
"""Materialize locked G11 repositories and require explicit local Payment source."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).parent
SPEC = importlib.util.spec_from_file_location("materialize_g10", ROOT / "materialize-g10.py")
G10 = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(G10)

ENV_NAMES = G10.ENV_NAMES | {"payment": "G11_PAYMENT_ROOT"}
LOCAL_REPOSITORIES = {
    "gymProto": "gym-proto",
    "identifier": "ms-gym-identifier",
    "member": "ms-gym-member",
    "plans": "ms-gym-plans",
    "checkin": "ms-gym-checkin",
    "infrastructure": "gym-infra",
}


def local_root() -> Path | None:
    candidate = ROOT.parent.parent
    return candidate if all((candidate / path / ".git").exists() for path in LOCAL_REPOSITORIES.values()) else None


def materialize(name: str, repository: dict, workspace: Path, env: dict[str, str], root: Path | None) -> Path:
    if root is None:
        return G10.materialize(name, repository, workspace, env)
    source = root / LOCAL_REPOSITORIES[name]
    target = workspace / name
    G10.run("git", "clone", "--quiet", "--no-local", "--no-tags", str(source), str(target), env=env)
    G10.run("git", "checkout", "--quiet", "--detach", repository["sha"], cwd=target, env=env)
    if G10.run("git", "rev-parse", "HEAD", cwd=target) != repository["sha"]:
        raise SystemExit(f"{name} source SHA mismatch")
    if G10.run("git", "status", "--porcelain", cwd=target):
        raise SystemExit(f"{name} materialized checkout is dirty")
    return target


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock", type=Path, required=True)
    parser.add_argument("--workspace", type=Path, required=True)
    args = parser.parse_args()
    lock = json.loads(args.lock.read_text())
    source = os.environ.get("G11_PAYMENT_SOURCE", "")
    payment = Path(source).expanduser().resolve() if source else None
    if payment is None or not payment.is_dir() or not (payment / "Dockerfile").is_file():
        raise SystemExit("G11_PAYMENT_SOURCE must be a Payment service directory containing Dockerfile")
    if args.workspace.exists():
        raise SystemExit(f"workspace already exists: {args.workspace}")
    args.workspace.mkdir(mode=0o700)
    env = G10.git_environment()
    try:
        repositories = lock["repositories"]
        root = local_root()
        paths = {name: materialize(name, repositories[name], args.workspace, env, root) for name in G10.NAMES}
        paths["payment"] = payment
        for name, path in paths.items():
            print(f"export {ENV_NAMES[name].replace('G10_', 'G11_')}={shlex.quote(str(path))}")
    except BaseException:
        shutil.rmtree(args.workspace, ignore_errors=True)
        raise
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(f"G11 source materialization failed: {error}", file=sys.stderr)
        raise SystemExit(1)

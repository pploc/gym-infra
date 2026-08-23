#!/usr/bin/env python3
"""Materialize locked G10 repositories into a private temporary workspace."""

from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import subprocess
from pathlib import Path

ENV_NAMES = {
    "gymProto": "G10_PROTO_ROOT",
    "identifier": "G10_IDENTIFIER_ROOT",
    "member": "G10_MEMBER_ROOT",
    "plans": "G10_PLANS_ROOT",
    "checkin": "G10_CHECKIN_ROOT",
    "infrastructure": "G10_INFRA_ROOT",
}
NAMES = tuple(ENV_NAMES)


def run(*command: str, cwd: Path | None = None, env: dict[str, str] | None = None) -> str:
    return subprocess.check_output(command, cwd=cwd, env=env, text=True, stderr=subprocess.STDOUT).strip()


def git_environment() -> dict[str, str]:
    token = os.environ.get("GITHUB_TOKEN")
    if not token:
        raise SystemExit("GITHUB_TOKEN is required to materialize G10 repositories")
    env = os.environ.copy()
    env.update({
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_CONFIG_COUNT": "2",
        "GIT_CONFIG_KEY_0": "core.autocrlf",
        "GIT_CONFIG_VALUE_0": "false",
        "GIT_CONFIG_KEY_1": "url.https://x-access-token:" + token + "@github.com/.insteadOf",
        "GIT_CONFIG_VALUE_1": "https://github.com/",
    })
    return env


def materialize(name: str, repository: dict, workspace: Path, env: dict[str, str]) -> Path:
    target = workspace / name
    run("git", "clone", "--quiet", "--no-tags", repository["url"], str(target), env=env)
    run("git", "checkout", "--quiet", "--detach", repository["sha"], cwd=target, env=env)
    if run("git", "rev-parse", "HEAD", cwd=target) != repository["sha"]:
        raise SystemExit(f"{name} source SHA mismatch")
    if run("git", "status", "--porcelain", cwd=target):
        raise SystemExit(f"{name} materialized checkout is dirty")
    return target


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock", type=Path, required=True)
    parser.add_argument("--workspace", type=Path, required=True)
    args = parser.parse_args()
    lock = json.loads(args.lock.read_text())
    repositories = lock["repositories"]
    if set(repositories) != set(NAMES):
        raise SystemExit("G10 lock repository set is invalid")
    if args.workspace.exists():
        raise SystemExit(f"workspace already exists: {args.workspace}")
    args.workspace.mkdir(mode=0o700)
    env = git_environment()
    try:
        paths = {name: materialize(name, repositories[name], args.workspace, env) for name in NAMES}
        for name, path in paths.items():
            print(f"export {ENV_NAMES[name]}={shlex.quote(str(path))}")
    except BaseException:
        shutil.rmtree(args.workspace, ignore_errors=True)
        raise
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(f"G10 source materialization failed: {error}", file=os.sys.stderr)
        raise SystemExit(1)

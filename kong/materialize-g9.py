#!/usr/bin/env python3
"""Materialize the G9 service sources at release-lock commits."""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path


ENVIRONMENT_NAMES = {
    "gymProto": "G9_PROTO_ROOT",
    "identifier": "G9_IDENTIFIER_ROOT",
    "member": "G9_MEMBER_ROOT",
    "plans": "G9_PLANS_ROOT",
}
GIT_SHA = re.compile(r"^[0-9a-f]{40}$")


def run(*command: str, cwd: Path | None = None, env: dict[str, str] | None = None) -> str:
    return subprocess.check_output(command, cwd=cwd, env=env, text=True).strip()


def git_environment() -> dict[str, str]:
    token = os.environ.get("GITHUB_TOKEN")
    if not token:
        raise SystemExit("GITHUB_TOKEN is required to materialize private G9 repositories")
    environment = os.environ.copy()
    environment.update({
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_CONFIG_COUNT": "1",
        "GIT_CONFIG_KEY_0": "url.https://x-access-token:" + token + "@github.com/.insteadOf",
        "GIT_CONFIG_VALUE_0": "https://github.com/",
    })
    return environment


def materialize(name: str, repository: dict[str, str], workspace: Path, env: dict[str, str]) -> Path:
    destination = workspace / name
    run("git", "clone", "--quiet", repository["url"], str(destination), env=env)
    run("git", "checkout", "--quiet", "--detach", repository["sha"], cwd=destination, env=env)
    actual_sha = run("git", "rev-parse", "HEAD", cwd=destination, env=env)
    if actual_sha != repository["sha"]:
        raise SystemExit(f"{name} source SHA mismatch: expected {repository['sha']}, got {actual_sha}")
    if run("git", "status", "--porcelain", cwd=destination, env=env):
        raise SystemExit(f"{name} materialized checkout is dirty")
    return destination


def validate_repositories(lock: dict) -> dict[str, dict[str, str]]:
    repositories = lock.get("repositories")
    if not isinstance(repositories, dict):
        raise ValueError("G9 release lock has no repositories")
    if set(repositories) != set(ENVIRONMENT_NAMES):
        raise ValueError(f"G9 release lock repositories must be {sorted(ENVIRONMENT_NAMES)}")
    for name, repository in repositories.items():
        if not isinstance(repository, dict) or not isinstance(repository.get("url"), str) or not isinstance(repository.get("sha"), str):
            raise ValueError(f"G9 release lock repository is invalid: {name}")
        if not repository["url"].startswith("https://github.com/"):
            raise ValueError(f"G9 release lock repository URL is invalid: {name}")
        if GIT_SHA.fullmatch(repository["sha"]) is None:
            raise ValueError(f"G9 release lock repository SHA is invalid: {name}")
    return repositories


def given_release_lock_when_sources_materialized_then_emit_compose_paths() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock", type=Path, required=True)
    parser.add_argument("--workspace", type=Path, required=True)
    args = parser.parse_args()

    lock = json.loads(args.lock.read_text())
    repositories = validate_repositories(lock)
    if args.workspace.exists():
        raise SystemExit(f"G9 materialization workspace already exists: {args.workspace}")
    args.workspace.mkdir(mode=0o700)
    environment = git_environment()
    try:
        values = {
            ENVIRONMENT_NAMES[name]: materialize(name, repositories[name], args.workspace, environment)
            for name in ENVIRONMENT_NAMES
        }
    except BaseException:
        shutil.rmtree(args.workspace, ignore_errors=True)
        raise

    for name, value in values.items():
        print(f"export {name}={shlex.quote(str(value))}")


if __name__ == "__main__":
    try:
        given_release_lock_when_sources_materialized_then_emit_compose_paths()
    except (KeyError, ValueError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"G9 source materialization failed: {error}", file=sys.stderr)
        raise SystemExit(1)

"""Bootstrap orchestrator.

Composes each sub-repo's documented standalone step into a full system
bootstrap.  All external work is done via subprocess — this module never
imports envoy code.

Usage:
    python -m bootstrap            # path 1: full personal (SSH, ssh-dir, Stage 3)
    python -m bootstrap --public   # path 2: public (HTTPS, no ssh-dir, no Stage 3)
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

from bootstrap._env import Env


def _run(*args: str, extra_env: dict[str, str] | None = None, check: bool = True) -> "subprocess.CompletedProcess[bytes]":
    cmd = list(args)
    print(f"+ {' '.join(cmd)}", flush=True)
    env = {**os.environ, **(extra_env or {})}
    return subprocess.run(cmd, check=check, env=env)


def _git_clone_or_pull(url: str, dest: Path, accept_new_host: bool = False) -> None:
    extra: dict[str, str] = {}
    if accept_new_host:
        extra["GIT_SSH_COMMAND"] = "ssh -o StrictHostKeyChecking=accept-new"
    if dest.is_dir() and (dest / ".git").exists():
        print(f"Updating {dest} ...", flush=True)
        _run("git", "-C", str(dest), "pull", extra_env=extra)
    else:
        dest.parent.mkdir(parents=True, exist_ok=True)
        print(f"Cloning {url} → {dest} ...", flush=True)
        _run("git", "clone", url, str(dest), extra_env=extra)


def _git_url(repo: str, ssh: bool) -> str:
    return f"git@github.com:{repo}.git" if ssh else f"https://github.com/{repo}.git"


def _envoy_installer(envoy_dir: Path, name: str, *args: str) -> None:
    script = envoy_dir / "install" / f"{name}.py"
    _run(sys.executable, str(script), *args)


# ---------------------------------------------------------------------------
# Stage 1: envoy + tools (all paths)
# ---------------------------------------------------------------------------

def stage1_envoy(env: Env, ssh: bool) -> None:
    print("\n" + "=" * 72, flush=True)
    print("Stage 1: envoy + tools", flush=True)
    _git_clone_or_pull(_git_url("ickc/envoy", ssh), env.envoy_dir, accept_new_host=ssh)

    envoy = env.envoy_dir
    # Install tools in dependency order: mamba first (others may use its python),
    # then zim, code, chezmoi (tool only; apply is Stage 2), sman.
    for tool in ("mamba", "zim", "code", "chezmoi", "sman"):
        _envoy_installer(envoy, tool, "install")
    # mamba_env installs the system conda environment (supplies gh, git, etc.)
    _envoy_installer(envoy, "mamba_env", "install", "--name", "system")


# ---------------------------------------------------------------------------
# Stage 2: dotfiles + data repos (paths 1 and 2)
# ---------------------------------------------------------------------------

def stage2_data(env: Env, ssh: bool) -> None:
    print("\n" + "=" * 72, flush=True)
    print("Stage 2: dotfiles + data repos", flush=True)

    # chezmoi applies dotfiles; pass full SSH URL for path 1 so chezmoi clones
    # over SSH (write access); HTTPS short spec for path 2 (read-only).
    chezmoi = shutil.which("chezmoi") or str(env.opt_root / "bin" / "chezmoi")
    if ssh:
        repo_spec = "git@github.com:ickc/dotfiles.git"
        extra: dict[str, str] = {"GIT_SSH_COMMAND": "ssh -o StrictHostKeyChecking=accept-new"}
    else:
        repo_spec = "ickc/dotfiles"
        extra = {}
    _run(chezmoi, "init", "--apply", repo_spec, extra_env=extra)

    # data repos
    _git_clone_or_pull(_git_url("ickc/sman-snippets", ssh), env.sman_snippets_dir, accept_new_host=ssh)
    _git_clone_or_pull(_git_url("ickc/navi-cheatsheets", ssh), env.navi_cheats_dir, accept_new_host=ssh)

    if ssh:
        # Clone ssh-dir into ~/.ssh; ssh-keygen lands here in Stage 3.
        _git_clone_or_pull(
            "git@github.com:ickc/ssh-dir.git",
            env.home / ".ssh",
            accept_new_host=True,
        )
        ssh_dir = env.home / ".ssh"
        if (ssh_dir / "makefile").exists():
            _run("make", "-C", str(ssh_dir), "permission", check=False)


# ---------------------------------------------------------------------------
# Stage 3: machine SSH identity (path 1 only, interactive)
# ---------------------------------------------------------------------------

def stage3_ssh_identity(env: Env) -> None:
    print("\n" + "=" * 72, flush=True)
    print("Stage 3: machine SSH identity", flush=True)

    ssh_dir = env.home / ".ssh"
    ed_key = ssh_dir / "id_ed25519"
    if ed_key.exists():
        print(f"{ed_key} already exists; skipping keygen.", flush=True)
    else:
        ssh_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        user = os.environ.get("USER", "user")
        host = os.uname().nodename
        _run("ssh-keygen", "-t", "ed25519", "-C", f"{user}@{host}", "-f", str(ed_key))

    # Register the public key with GitHub (interactive browser flow).
    gh = shutil.which("gh") or str(env.opt_root / "bin" / "gh")
    if not Path(gh).exists():
        # gh may be in the system conda env installed by mamba_env
        gh_conda = env.opt_root / "system" / "bin" / "gh"
        if gh_conda.exists():
            gh = str(gh_conda)
    print("Authenticating with GitHub (interactive)...", flush=True)
    _run(gh, "auth", "login", "--git-protocol", "ssh", "--web", check=False)


# ---------------------------------------------------------------------------
# Final: generate shell completions (all paths)
# ---------------------------------------------------------------------------

def stage_final_completions(env: Env) -> None:
    print("\n" + "=" * 72, flush=True)
    print("Final: generate shell completions", flush=True)
    envoy = env.envoy_dir
    _run(
        sys.executable, "-m", "bsos.shell.completion", "generate",
        extra_env={"PYTHONPATH": str(envoy / "src")},
    )


# ---------------------------------------------------------------------------
# Top-level entry point
# ---------------------------------------------------------------------------

def bootstrap(public: bool = False) -> None:
    env = Env()
    ssh = not public

    stage1_envoy(env, ssh)
    stage2_data(env, ssh)
    if ssh:
        stage3_ssh_identity(env)
    stage_final_completions(env)

    print("\n" + "=" * 72, flush=True)
    print("Bootstrap complete.", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Bootstrap system environment.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Path 1 (default): SSH clones, ssh-dir installed to ~/.ssh, machine key generated.\n"
            "Path 2 (--public): HTTPS clones, no ssh-dir, no SSH key generation."
        ),
    )
    parser.add_argument(
        "--public",
        action="store_true",
        help="path 2: HTTPS clones, no ssh-dir, no Stage-3 identity step",
    )
    args = parser.parse_args()
    bootstrap(public=args.public)


if __name__ == "__main__":
    main()

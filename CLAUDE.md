# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This repo aggregates personal environment setup via git submodules. It solves a chicken-and-egg bootstrap problem: SSH keys must exist before private repos can be cloned, so `submodule/ssh-dir` is bootstrapped first via `gh` CLI, then the rest follows.

## Submodules

| Path | Repo | Purpose |
|------|------|---------|
| `submodule/ssh-dir` | `ickc/ssh-dir` (private) | SSH keys, known_hosts, authorized_keys |
| `submodule/dotfiles` | `ickc/dotfiles` (public) | Shell dotfiles, XDG config symlinks |
| `submodule/envoy` | `ickc/envoy` (public) | Binary/environment installers (mamba, sman, zim, VS Code CLI) |
| `submodule/sman-snippets` | `ickc/sman-snippets` (public) | Shell snippet manager snippets |

## Common Commands

```bash
# Initialize submodules after a fresh clone
task init

# Pull latest commits in all submodules
task update

# Format shell scripts (envoy)
cd submodule/envoy && make format

# Lint shell scripts (envoy)
cd submodule/envoy && make check

# Install dotfiles
cd submodule/dotfiles && make all

# Fix SSH permissions
cd submodule/ssh-dir && make permission
```

## Bootstrap Flow

The entry point is `submodule/envoy/install/bootstrap.sh`. It runs on a fresh UNIX system and:
1. Downloads minimal dotfiles (`.zshenv`, `.zshrc`) temporarily from GitHub over HTTPS
2. Installs VS Code CLI, Miniforge3 (mamba), a conda system environment, and zim (zsh plugin manager)
3. Generates an SSH key and authenticates with GitHub via `gh auth login`
4. Clones `ickc/dotfiles` (git+ssh) and runs `make all` to symlink everything
5. Installs `sman` (snippet manager) and clones `sman-snippets`
6. Clones `ickc/envoy` and generates shell completions
7. Clones `ickc/ssh-dir` into `~/.ssh` (replacing the temporary `~/.ssh`)

## Key Paths (runtime, not this repo)

All paths set by `dotfiles/home/.zshenv` (dotfiles have ultimate authority; bootstrap.sh defaults are overridden after sourcing):

- `$__LOCAL_ROOT` (`$HOME/.local`) — arch-**independent** prefix (share, state, zim)
- `$__OPT_ROOT` (`$HOME/.local/opt/$__OSTYPE-$__ARCH`) — arch-**dependent** prefix; binaries land in `$__OPT_ROOT/bin`, conda envs under `$__OPT_ROOT/`
- `$MAMBA_ROOT_PREFIX` (`$__OPT_ROOT/miniforge3`) — Miniforge installation
- `$XDG_CONFIG_HOME` (`$HOME/.config`) — symlinked wholesale to `dotfiles/config/`
- `$HOME/.ssh` — replaced by `ssh-dir` repo clone at end of bootstrap

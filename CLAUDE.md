# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This repo is the top-level bootstrap orchestrator for a personal UNIX environment. It composes
per-repo standalone steps (envoy, dotfiles, data repos, ssh-dir) into a one-liner that
bootstraps a fresh machine. Submodules under `submodule/` are for development and version-pinning;
bootstrapped end-systems clone each component to its runtime XDG location.

## Submodules

| Path | Repo | Purpose |
|------|------|---------|
| `submodule/ssh-dir` | `ickc/ssh-dir` (private) | SSH config, known_hosts, authorized_keys |
| `submodule/dotfiles` | `ickc/dotfiles` (public) | chezmoi source state (shell config, XDG config) |
| `submodule/envoy` | `ickc/envoy` (public) | Python installers (mamba, sman, zim, VS Code CLI, chezmoi, …) |
| `submodule/sman-snippets` | `ickc/sman-snippets` (public) | Shell snippet manager snippets |
| `submodule/navi-cheatsheets` | `ickc/navi-cheatsheets` (public) | navi cheatsheet data |

## Common Commands

```bash
# Initialize submodules after a fresh clone
pixi run init

# Pull latest commits in all submodules
pixi run update

# Format/lint envoy installers
cd submodule/envoy && pixi run format
cd submodule/envoy && pixi run lint

# Compile envoy installers after source changes
cd submodule/envoy && pixi run compile

# Apply dotfiles (Phase 3+)
chezmoi apply

# Fix SSH permissions
cd submodule/ssh-dir && make permission
```

## Coding Conventions (envoy installers)

- **Never call GitHub API endpoints** (`api.github.com`) to resolve "latest" release versions.
  Use the `/releases/latest` redirect URL — `GitHubRedirect` in `_recipe.py` handles this.
- **Fail hard on missing prerequisites.** Exit 1 for missing dependencies on supported platforms;
  exit 0 (skip) is reserved for unsupported platforms only.
- **Compile after every source edit.** Each installer source in `src/bsos/installers/` has a
  compiled counterpart in `install/`. Run `pixi run compile` after any change; freshness is
  enforced by CI.

## Bootstrap Flow (Phase 4)

The one-liner entry point is `bootstrap.sh` (Stage 0, ~35 lines of POSIX sh). It:
1. Installs pixi (if not present)
2. Clones this repo to `$XDG_DATA_HOME/bootstrap` (SSH for path 1, HTTPS for path 2)
3. Runs `pixi run bootstrap` (or `bootstrap-public`)

The pixi tasks invoke `src/bootstrap/__main__.py`, a stdlib-only Python orchestrator:

- **Stage 1** (all paths): clone envoy → `$XDG_DATA_HOME/envoy`; run `install/mamba.py`,
  `mamba_env.py --name system`, `zim.py`, `code.py`, `chezmoi.py`, `sman.py`
- **Stage 2** (paths 1–2): `chezmoi init --apply ickc/dotfiles`; clone sman-snippets and
  navi-cheatsheets; (path 1 only) clone ssh-dir → `~/.ssh` + `make permission`
- **Stage 3** (path 1 only, interactive): `ssh-keygen`; `gh auth login`
- **Final** (all paths): `python -m bsos.shell.completion generate`

Path 1 (default) uses SSH throughout and assumes SSH agent forwarding is active.
Path 2 (`--public`) uses HTTPS, skips ssh-dir and Stage 3.

```bash
# Full personal bootstrap:
curl -fsSL https://raw.githubusercontent.com/ickc/bootstrap/main/bootstrap.sh | bash

# Public bootstrap (HTTPS, no ssh-dir):
curl -fsSL https://raw.githubusercontent.com/ickc/bootstrap/main/bootstrap.sh | bash -s -- --public
```

## Key Paths (runtime)

Set by `dotfiles` (chezmoi-applied) and `envoy/env.sh`:

- `$__LOCAL_ROOT` (`$HOME/.local`) — arch-independent prefix
- `$__OPT_ROOT` (`$HOME/.local/opt/$__OSTYPE-$__ARCH`) — arch-dependent prefix; binaries in `$__OPT_ROOT/bin`
- `$MAMBA_ROOT_PREFIX` (`$__OPT_ROOT/miniforge3`) — Miniforge installation
- `$XDG_DATA_HOME` (`$HOME/.local/share`) — runtime installs: envoy, sman/snippets, navi/cheats
- `$XDG_CONFIG_HOME` (`$HOME/.config`) — real directory managed by chezmoi (Phase 3+)
- `$HOME/.ssh` — ssh-dir repo clone (path 1 only); private keys generated per-machine, never committed

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
| `submodule/envoy` | `ickc/envoy` (public) | Python installers (micromamba, mamba, sman, zim, VS Code CLI, chezmoi, …) |
| `submodule/sman-snippets` | `ickc/sman-snippets` (public) | Shell snippet manager snippets |
| `submodule/navi-cheatsheets` | `ickc/navi-cheatsheets` (public) | navi cheatsheet data |

## Common Commands

```bash
# Initialize submodules after a fresh clone
pixi run init

# Pull latest commits in all submodules
pixi run update

# Validate a completed bootstrap (run after the matching bootstrap)
pixi run test-bootstrap          # path 1 (personal)
pixi run test-bootstrap-public   # path 2 (public)

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

`bootstrap.sh` is the single entry point — a self-contained bash script (~80 lines).
It does NOT require this repo to be cloned first; `curl | bash` works on a fresh machine.

Stages:

- **Stage 0**: downloads `env.sh` from envoy (temp) to derive `__OPT_ROOT`/`PIXI_HOME`/etc.;
  installs pixi via the official `pixi.sh/install.sh` (`PIXI_NO_PATH_UPDATE=1`; respects `PIXI_HOME`).
- **Stage 1** (all paths): clone envoy → `$XDG_DATA_HOME/envoy`; run `install/micromamba.py`,
  `mamba_env.py --name system --backend micromamba`, `zim.py`, `code.py`, `chezmoi.py`, `sman.py`
- **Stage 2** (paths 1–2): `chezmoi init --apply ickc/dotfiles`; clone sman-snippets and
  navi-cheatsheets; (path 1 only) clone ssh-dir → `~/.ssh` + `make permission`
- **Stage 3** (path 1 only, interactive): `ssh-keygen`; `gh auth login`.
  `--no-identity` (implied by `CI=true`) generates the key with an empty passphrase
  and skips `gh auth login`, so the personal path runs unattended for testing.
- **Final** (all paths): `PYTHONPATH=$ENVOY_DIR/src python3 -m bsos.shell.completion generate`

Path 1 (default) uses SSH throughout and assumes SSH agent forwarding is active.
Path 2 (`--public`) uses HTTPS, skips ssh-dir and Stage 3.

```bash
# Full personal bootstrap:
curl -fsSL https://raw.githubusercontent.com/ickc/provision/main/bootstrap.sh | bash

# Public bootstrap (HTTPS, no ssh-dir):
curl -fsSL https://raw.githubusercontent.com/ickc/provision/main/bootstrap.sh | bash -s -- --public

# From a local clone (also works):
bash bootstrap.sh [--public]
pixi run bootstrap[-public]

# Validate the result (Phase 5). --no-identity makes path 1 unattended:
bash bootstrap.sh --no-identity && pixi run test-bootstrap
pixi run test-bootstrap-public
```

`test/smoke.sh` asserts the provisioned environment (tools functional, `~/.config`
a real dir, data repos cloned, completions present, SSH key + perms on path 1). CI
(`.github/workflows/test-bootstrap.yml`) runs the public path end-to-end — fresh
install, smoke, then a second run to prove idempotency — on the same four runners
as envoy.

## Key Paths (runtime)

Set by `dotfiles` (chezmoi-applied) and `envoy/env.sh`:

- `$__LOCAL_ROOT` (`$HOME/.local`) — arch-independent prefix
- `$__OPT_ROOT` (`$HOME/.local/opt/$__OSTYPE-$__ARCH`) — arch-dependent prefix; binaries in `$__OPT_ROOT/bin`
- `$MAMBA_ROOT_PREFIX` (`$__OPT_ROOT/micromamba`) — micromamba root prefix (pkgs cache + named envs); also where opt-in Miniforge installs
- `$XDG_DATA_HOME` (`$HOME/.local/share`) — runtime installs: envoy, sman/snippets, navi/cheats
- `$XDG_CONFIG_HOME` (`$HOME/.config`) — real directory managed by chezmoi (Phase 3+)
- `$HOME/.ssh` — ssh-dir repo clone (path 1 only); private keys generated per-machine, never committed

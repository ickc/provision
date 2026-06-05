# provision

One-shot personal UNIX environment bootstrap. Composes
[envoy](https://github.com/ickc/envoy) installers, dotfiles, data repos, and
SSH configuration into a single script that turns a fresh account into a
fully configured environment.

## Quick start

### Prerequisites

Only `curl`, `git`, and a POSIX shell are required on the target machine.
**No Python required** — pixi is a static binary installed via `curl | sh`.

### Personal bootstrap (SSH, private repos)

Uses SSH throughout; clones `ssh-dir`, generates a machine SSH key, and
registers it with GitHub. Requires SSH agent forwarding active on the target.

```bash
# 1. Derive platform path (mirrors env.sh convention) and install pixi
read -r _os _arch <<< "$(uname -sm)"
export PIXI_HOME="${HOME}/.local/opt/${_os}-${_arch}/pixi"
PIXI_NO_PATH_UPDATE=1 curl -fsSL https://pixi.sh/install.sh | sh

# 2. Clone this repo
mkdir -p ~/git/source
git clone git@github.com:ickc/provision.git ~/git/source/provision

# 3. Run bootstrap
"${PIXI_HOME}/bin/pixi" run -d ~/git/source/provision bootstrap
```

### Public bootstrap (HTTPS, no private repos)

Uses HTTPS throughout; skips `ssh-dir` and SSH key generation. Suitable for
shared/HPC machines where you only need tools + dotfiles.

```bash
# 1. Derive platform path and install pixi
read -r _os _arch <<< "$(uname -sm)"
export PIXI_HOME="${HOME}/.local/opt/${_os}-${_arch}/pixi"
PIXI_NO_PATH_UPDATE=1 curl -fsSL https://pixi.sh/install.sh | sh

# 2. Clone this repo
mkdir -p ~/git/source
git clone https://github.com/ickc/provision.git ~/git/source/provision

# 3. Run bootstrap
"${PIXI_HOME}/bin/pixi" run -d ~/git/source/provision bootstrap-public
```

### Why clone first?

`pixi run bootstrap` activates the project's conda environment (Python ≥ 3.10)
before running the script. This guarantees the installer scripts have a
supported Python regardless of what the host provides — important on systems
with Python 3.6 or no Python at all. The clone is cheap (shallow is fine:
`git clone --depth 1 …`).

`PIXI_NO_PATH_UPDATE=1` keeps the pixi installer from modifying shell RC files;
`PIXI_HOME` is set to the platform-specific path that `env.sh` expects
(`~/.local/opt/<OS>-<arch>/pixi`) rather than the default `~/.pixi`.

## What the bootstrap does

| Stage | Description |
|-------|-------------|
| **0** | Downloads `env.sh` from envoy to set `__OPT_ROOT`, `PIXI_HOME`, `XDG_DATA_HOME`; installs pixi (idempotent). |
| **1** | Clones envoy → `$XDG_DATA_HOME/envoy`; runs `mamba`, `mamba_env --name system`, `zim`, `code`, `chezmoi`, `sman` installers. |
| **2** | Applies dotfiles via chezmoi; clones sman-snippets and navi-cheatsheets. Personal path also clones ssh-dir → `~/.ssh`. |
| **3** | *(Personal path only)* Generates machine SSH key (`ed25519`); runs `gh auth login` (interactive browser flow). |
| **Final** | Generates shell completions for all installed tools. |

## Submodules

| Path | Repo | Purpose |
|------|------|---------|
| `submodule/envoy` | `ickc/envoy` | Python installers for the core toolchain |
| `submodule/dotfiles` | `ickc/dotfiles` | chezmoi-managed shell + tool config |
| `submodule/ssh-dir` | `ickc/ssh-dir` *(private)* | SSH config, known_hosts, authorized_keys |
| `submodule/sman-snippets` | `ickc/sman-snippets` | sman snippet library |
| `submodule/navi-cheatsheets` | `ickc/navi-cheatsheets` | navi cheatsheet data |

## Development

```bash
pixi run init      # initialize submodules after a fresh clone
pixi run update    # pull latest commits in all submodules
```

Installer development lives in `submodule/envoy`; see its `CLAUDE.md` for
conventions.

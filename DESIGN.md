# Bootstrap Design

## Goal

Turn a fresh UNIX account (macOS, Linux) into a fully configured personal environment in a single script run. The entry point is `submodule/envoy/install/bootstrap.sh`.

## Components

### ssh-dir (private)
Stores SSH keys (`id_ed25519`, `id_ed25519.pub`), `known_hosts`, `authorized_keys`, and per-cluster SSH configs. Installed last during bootstrap because SSH authentication is required to clone it.

### dotfiles (public)
Shell startup files (`.zshenv`, `.zshrc`, `.zimrc`, `.bash_profile`, `.bashrc`), and an entire `config/` directory tree covering ~20+ tools (git, gh, helix, starship, ghostty, pixi, etc.). Installed via `make all`, which symlinks `dotfiles/config/` as `$XDG_CONFIG_HOME` and symlinks individual shell files into `$HOME`.

### envoy (public)
Provides installer scripts for the core toolchain: Miniforge3/mamba, conda environments (pinned via per-platform YAML lockfiles), VS Code CLI, sman, zim, and shell completions. The `install/` directory contains shell source fragments that `bootstrap.sh` inlines at compile time via `install/compile.sh`. The conda env lockfiles (`conda/*.yml`) are themselves generated from CSV config files using the `bsos` library.

### sman-snippets (public)
YAML snippet library for `sman` (a shell snippet manager). Cloned to `~/git/source/sman-snippets`.

## Bootstrap Sequence

```
1. Download .zshenv + .zshrc temporarily (HTTPS, no SSH needed)
2. Source them → sets __LOCAL_ROOT, __OPT_ROOT, MAMBA_ROOT_PREFIX, XDG_CONFIG_HOME, etc.
3. Install VS Code CLI  → $__OPT_ROOT/bin/code
4. Install Miniforge3   → $MAMBA_ROOT_PREFIX
5. Create conda "system" env  → $__OPT_ROOT/system  (system-level tools)
6. Install zim          → $ZIM_HOME
7. Re-source .zshrc
8. Generate SSH key + gh auth login  ← pivot point: git-over-ssh now works
9. Clone + install dotfiles  (overwrites temp .zshenv/.zshrc with permanent symlinks)
10. Install sman binary + rc + snippets  (requires SSH from step 8)
11. Clone envoy + generate completions
12. Clone ssh-dir → replace ~/.ssh
```

The pivot at step 8 separates the HTTPS-only phase from the git-over-ssh phase. Steps 1–7 run without GitHub credentials.

**Why dotfiles are sourced multiple times:** `bootstrap.sh` sets fallback defaults for `__OPT_ROOT`, `MAMBA_ROOT_PREFIX`, etc. *after* sourcing `.zshenv`/`.zshrc`. The dotfiles have ultimate authority — their computed values (based on `__HOST` detection, HPC cluster paths, etc.) override the script's simple defaults. Re-sourcing at steps 2 and 7 propagates any new path additions made by earlier install steps.

## Key Environment Variables

All ultimately set by `dotfiles/home/.zshenv`:

| Variable | Personal default | Purpose |
|----------|-----------------|---------|
| `__LOCAL_ROOT` | `$HOME/.local` | Arch-**independent** prefix (share, state, zim) |
| `__OPT_ROOT` | `$HOME/.local/opt/$__OSTYPE-$__ARCH` | Arch-**dependent** prefix (binaries, conda envs) |
| `MAMBA_ROOT_PREFIX` | `$__OPT_ROOT/miniforge3` | Miniforge installation prefix |
| `PIXI_HOME` | `$__OPT_ROOT/pixi` | Pixi installation prefix |
| `XDG_CONFIG_HOME` | `$HOME/.config` | Symlinked wholesale to `dotfiles/config/` |
| `XDG_DATA_HOME` | `$__LOCAL_ROOT/share` | |
| `XDG_STATE_HOME` | `$__LOCAL_ROOT/state` | |
| `ZIM_HOME` | `$__LOCAL_ROOT/zim` | Arch-independent, so under `__LOCAL_ROOT` |
| `SMAN_SNIPPET_DIR` | `$HOME/git/source/sman-snippets` | Hardcoded path in dotfiles |

On HPC clusters where `__APPDIR` is set (e.g. `/cosma/apps/durham/$USER`), `__LOCAL_ROOT` and `__OPT_ROOT` are redirected there instead of `$HOME/.local`.

## Shell Architecture (.zshenv / .zshrc)

`.zshenv` handles pure environment: OS/arch detection, host detection, path variable setup, XDG, Homebrew detection. No PATH modification.

`.zshrc` handles interactive shell: defines `ml_*` / `mu_*` "module" functions that lazily add tool directories to PATH (conda, pixi, brew, cargo, ghcup, etc.), then calls `ml` (load all) or `ml_clean` (minimal, when `__CLEAN=1` is set). Also sets up zim, starship, fzf, direnv.

The `__PATH` / `__MANPATH` snapshot trick in `.zshrc` ensures PATH is reset to the pre-zshrc baseline each time a new interactive shell starts, preventing PATH accumulation across nested shells.

## Platform Support

| Platform | bootstrap.sh | conda envs | Notes |
|----------|-------------|------------|-------|
| Darwin arm64 | ✓ | ✓ | |
| Darwin x86_64 | ✓ | ✓ | |
| Linux x86_64 | ✓ | ✓ | |
| Linux aarch64 | ✓ | ✓ | |
| Linux ppc64le | ✓ | ✓ | |
| FreeBSD amd64 | partial | ✗ | sman installer supports it; conda/mamba does not |

FreeBSD support is partial: the sman binary installer handles FreeBSD, but Miniforge3 and all conda env steps will fail. A full bootstrap on FreeBSD would need an alternative to mamba for the system environment.

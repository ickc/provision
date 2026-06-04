# Migration Plan

## Decision

- **Dotfiles layer:** chezmoi — manages **public, non-secret** config files; templates machine-specific *public* output (HPC paths, per-machine git email, OS differences). chezmoi's encryption is intentionally **not** used; dotfiles never carries secrets.
- **Orchestration layer:** pixi — task runner + Python runtime for envoy's installer toolkit
- **ssh-dir:** stays a standalone **private** repo, cloned to `~/.ssh` (not absorbed into dotfiles). Only sensitive-but-shareable files (`authorized_keys`, `known_hosts`, SSH `config`) are committed; private keys are **never** committed — generated per-machine, local-only. (Absorbing it via chezmoi-encrypted secrets is a possible *future* exploration, deferred.)
- **sman-snippets, navi-cheatsheets:** remain standalone repos, each documenting its expected install location
- **envoy:** refactored as a pixi-orchestrated, portable installer toolkit; compile.sh system fully replaced; ships a shell env library (`env.sh`) that is usable independently of any personal dotfiles
- **Individually bootstrappable repos:** every repo can be set up on its own via a copy-paste codeblock in its README that only *places files* and never edits the user's shell rc; each README also documents the minimum shell-rc additions (env vars / PATH) needed to use it. See "Individual Bootstrappability" below.
- **This repo:** top-level orchestrator; submodule pinning for development; ships the bootstrap one-liner

## Repo End State

| Repo | Role | Visibility |
|------|------|------------|
| `envoy` | Portable installer toolkit (pixi tasks), shell env library, conda env examples | public |
| `dotfiles` | chezmoi source state: shell configs, tool configs (public, **no secrets**) | public |
| `sman-snippets` | sman snippet data | public |
| `navi-cheatsheets` | navi cheatsheet data | public |
| `bootstrap` (this repo) | Orchestrator, submodule pinning, bootstrap one-liner | public |
| `ssh-dir` | SSH `config`, `known_hosts`, `authorized_keys` (no private keys) | **private** |

## Supported Bootstrap Paths

The system supports four configurations, from most to least personalized. **dotfiles is
always public and never carries secrets**, so the only "private" axis is whether the
`ssh-dir` repo is cloned:

| Path | dotfiles | envoy | ssh-dir (private) | Use case |
|------|----------|-------|-------------------|----------|
| 1. Full personal | yes | yes | yes (`~/.ssh`; keys still per-machine) | Personal machine setup |
| 2. Public personal | yes | yes | no | Testing, shared accounts |
| 3. Envoy only | no | yes | no | Third-party reuse, minimal setup |
| 4. Dotfiles only | yes | no | no | Config management without envoy |

The key architectural constraint: **envoy never depends on dotfiles.** envoy's `env.sh`
checks for pre-existing environment variables (which dotfiles may have set) and falls
back to sensible defaults when they are absent. This means envoy is always usable
standalone (path 3), and dotfiles can be applied before or without envoy (path 4).

When both are present (paths 1-2), dotfiles is sourced first to set personal/machine-specific
variables (like `__APPDIR`), then envoy's `env.sh` is sourced and respects those values.

Even in path 1, `ssh-dir` only supplies sensitive-but-shareable files (`config`,
`known_hosts`, `authorized_keys`); private keys are generated per-machine during bootstrap
and never come from any repo.

## Individual Bootstrappability

**Invariant:** every repo in this system can be bootstrapped on its own — without the
orchestrator, and without knowing the other repos exist. This generalizes the
"envoy never depends on dotfiles" rule to all repos.

Each repo's `README.md` provides:
1. **A copy-paste install codeblock** that only *places files/binaries where they belong*
   (clone to the documented path, drop a binary, etc.). It must **not** edit the user's
   shell rc (`.bashrc`/`.zshrc`) or any dotfiles — placement only.
2. **A "minimum shell-rc additions" section** documenting the env vars / `PATH` / sourcing
   the user must add *by hand* to actually use what was placed, plus any tool
   prerequisites. (Applying it automatically is out of scope; we only document it.)

This is the same philosophy as envoy's `env.sh` (which both *is* envoy's machine-readable
"minimum env" and respects pre-existing vars): the standalone path places things and
documents the env contract without taking over the user's shell config.

Per-repo status (these per-repo READMEs are the tracked deliverables):

| Repo | Standalone install (placement only) | Documented shell-rc contract |
|------|-------------------------------------|------------------------------|
| `envoy` | `python3 install/<tool>.py install` (curl-to-python3 too) | source `env.sh` — already satisfied (Phase 2) |
| `dotfiles` | `chezmoi init --apply <repo>` (path 4) | n/a — it *is* the shell config |
| `ssh-dir` | clone into `~/.ssh` + `make permission` | none required (optionally note `IdentityFile`) |
| `sman-snippets` | clone to `$XDG_DATA_HOME/sman/snippets` | needs `sman` binary; set `SMAN_SNIPPET_DIR`; source `sman.rc` |
| `navi-cheatsheets` | clone to `$XDG_DATA_HOME/navi/cheats` | needs `navi` binary; navi config / widget keybind |

The Phase 4 orchestrator **composes** these documented standalone steps rather than
reimplementing them, so the README codeblocks and the orchestrated path stay in sync.
envoy already satisfies this; the data-repo and `ssh-dir` READMEs are non-breaking and can
be written immediately; the `dotfiles` README is finalized with the Phase 3 restructure.

## File Layout (bootstrapped system)

```
$XDG_DATA_HOME/envoy/              # envoy git repo (arch-independent)
$XDG_DATA_HOME/sman/snippets/      # sman-snippets git repo
$XDG_DATA_HOME/navi/cheats/        # navi-cheatsheets git repo (already here)
$XDG_DATA_HOME/zsh/functions/      # shell completions (generated by envoy)
$XDG_DATA_HOME/bash-completion/completions/  # bash completions
$XDG_DATA_HOME/sman/sman.rc        # sman shell integration
$__OPT_ROOT/pixi/                  # pixi installation
$__OPT_ROOT/miniforge3/            # mamba installation
$__OPT_ROOT/system/                # conda system env
$__OPT_ROOT/bin/                   # standalone binaries (sman, code, etc.)
~/.config/                         # real directory, individual files managed by chezmoi
~/.ssh/                            # ssh-dir repo clone (private); private keys per-machine, never committed
```

Where `$XDG_DATA_HOME` defaults to `~/.local/share` and `$__OPT_ROOT` defaults to
`~/.local/opt/$__OSTYPE-$__ARCH`. On HPC clusters where `__APPDIR` is set,
`~/.local` is redirected accordingly.

## Platform Support

| Platform | Bootstrap target | Individual installers |
|----------|:---:|:---:|
| Darwin arm64 | yes | yes |
| Darwin x86_64 | yes | yes |
| Linux x86_64 | yes | yes |
| Linux aarch64 | yes | yes |
| Linux ppc64le | no (pixi unavailable) | where trivial |
| FreeBSD amd64 | no | where trivial |

ppc64le and FreeBSD are not bootstrap targets (pixi has no binary). However,
individual installer scripts that support these platforms at negligible cost (e.g.,
adding a download URL case) should continue to do so.

---

## Commit Discipline

Throughout all phases, commits follow this protocol:

1. Commit atomically within each submodule (separate logical units).
2. Commit in this repo afterward (some commits may only update a submodule pointer).
3. Non-breaking work stays on `main`. Once a phase introduces breaking changes,
   branch all affected repos to `dev`. This repo's `dev` points to `dev` in
   all submodules.

## Implementation Discipline

**Implement only what the current phase concretely requires. Do not front-load
work that belongs to a later phase.**

Later phases are described at a level of intent, not specification. What is
actually built in phase N may differ from what the plan says about phase N —
because earlier decisions change constraints. Each phase should be designed from
the concrete state left by the previous phase, not from the plan's description
of what a future phase might want.

Corollary: if a change is only justified by "phase M will need it", defer it to
phase M. Phase M's plan will be revised when it begins.

---

## Phase 0 — Housekeeping

**Goal:** Clean slate before structural changes. Everything here is non-breaking on `main`.

### 0a. Rename default branches to `main`

Repos needing rename: `dotfiles`, `sman-snippets`, `ssh-dir` (the other two already use `main`).

For each repo:
```bash
gh repo edit ickc/<repo> --default-branch main
# locally:
git branch -m master main
git push -u origin main
git push origin --delete master
```

Update `.gitmodules` if any entry tracks a specific branch. Update `bootstrap.sh`
line 12 which hardcodes `master` for the dotfile download URL.

### 0b. Move sman-snippets to XDG-compliant path

Follow the navi pattern. Currently:
- navi: `$XDG_DATA_HOME/navi/cheats` — correct
- sman: `~/git/source/sman-snippets` — non-standard

Change to: `$XDG_DATA_HOME/sman/snippets`.

Requires updating:
- `dotfiles/home/.zshenv`: `SMAN_SNIPPET_DIR="${XDG_DATA_HOME}/sman/snippets"`
- `envoy/install/src/lib/sman.sh`: clone/pull target path
- This repo's `Taskfile.yml` symlink task
- Each snippet/data repo (`sman-snippets`, `navi-cheatsheets`) should document its
  expected install location in its README with a one-liner git clone command.
  Downstream consumers (dotfiles, this repo) conform to that location but may use
  symlinks instead of direct clones. This is one instance of the **Individual
  Bootstrappability** invariant (see above); the same per-repo README treatment applies
  to `ssh-dir`, `envoy`, and `dotfiles`.

### 0c. Move sman.rc to XDG_DATA_HOME

Currently `sman_install_rc()` downloads `sman.rc` to `$XDG_CONFIG_HOME/zsh/functions/`,
which is inside the dotfiles-managed config directory. This conflicts with chezmoi
later managing individual files under `$XDG_CONFIG_HOME`.

Move to: `$XDG_DATA_HOME/sman/sman.rc`. Update `.zshrc` to source from the new location.

### 0d. Fix envoy's env.sh defaults

`install/src/state/env.sh` has wrong defaults (`__OPT_ROOT` defaults to `$HOME/.local`
instead of arch-specific path; `MAMBA_ROOT_PREFIX` defaults to `$HOME/.miniforge3`
instead of using `__OPT_ROOT`). Align with the correct derivation from
`envoy/dotfiles/.zshenv`.

---

## Phase 1 — Decouple Environment Setup

**Goal:** Separate installer path knowledge (owned by envoy) from personal shell configuration
(owned by dotfiles), so that each is independently usable without assuming the other exists.

**Why this must come first:** Both Phase 2 (pixi) and Phase 3 (chezmoi) depend on knowing
where the boundary is. The content split determines what envoy's shell library provides
and what chezmoi templates generate.

**Branch point:** This phase modifies both envoy and dotfiles in a coordinated, breaking way.
Branch all affected repos to `dev` before starting.

### The split

The guiding principle: env.sh answers "where does envoy put things?" — nothing more.
dotfiles answers "what is the user's personal environment?" — which may build on top of
those paths, but doesn't depend on them for its own functioning.

**envoy's env.sh** (installer path knowledge):
- OS/arch detection (`__OSTYPE`, `__ARCH`) — needed for arch-specific install paths
- `__LOCAL_ROOT` / `__OPT_ROOT` derivation (respecting `__APPDIR` if pre-set)
- `MAMBA_ROOT_PREFIX`, `PIXI_HOME` derivation
- XDG base directory defaults (`XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`,
  `XDG_CACHE_HOME`) — envoy uses `XDG_DATA_HOME` as its own install root

**Stays in dotfiles** (personal shell configuration):
- `__HOST` / cluster detection, `__APPDIR` assignment, `SCRATCH` paths
- `__NCPU` detection (used for `MAKEFLAGS`; envoy has no use for it)
- Homebrew prefix detection (PATH setup for interactive shell; not an install concern)
- XDG base dirs set directly with simple defaults (dotfiles needs them independently
  of envoy, e.g. for `SMAN_SNIPPET_DIR`)
- Personal exports: `EDITOR`, `LANG`, `SMAN_SNIPPET_DIR`, `CARGO_PREFIX`, `GOPATH`, etc.
- Tool-specific XDG overrides (`CONDA_BLD_PATH`, `IPYTHONDIR`, etc.)
- The `ml_*` / `mu_*` module system (stays in dotfiles — mechanism is generic but tool
  list is personal; extracting the mechanism is a future refinement if there's demand)

### envoy's env.sh — design

envoy provides a single shell library file (`env.sh`) at `$XDG_DATA_HOME/envoy/env.sh`.
It is designed to be sourced by other shell configs and respects pre-existing env vars:

```bash
# env.sh pseudocode:
# 1. Platform detection (always runs)
__OSTYPE, __ARCH ← uname

# 2. Path derivation (respects pre-existing values)
__LOCAL_ROOT="${__LOCAL_ROOT:-${__APPDIR:+${__APPDIR}/local}}"
__LOCAL_ROOT="${__LOCAL_ROOT:-${HOME}/.local}"
__OPT_ROOT="${__OPT_ROOT:-${__LOCAL_ROOT}/opt/${__OSTYPE}-${__ARCH}}"

# 3. Tool paths (respect pre-existing values)
MAMBA_ROOT_PREFIX="${MAMBA_ROOT_PREFIX:-${__OPT_ROOT}/miniforge3}"
PIXI_HOME="${PIXI_HOME:-${__OPT_ROOT}/pixi}"

# 4. XDG base dirs (respect pre-existing values)
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"
XDG_DATA_HOME="${XDG_DATA_HOME:-${__LOCAL_ROOT}/share}"
XDG_STATE_HOME="${XDG_STATE_HOME:-${__LOCAL_ROOT}/state}"
XDG_CACHE_HOME="${XDG_CACHE_HOME:-${HOME}/.cache}"
```

The key pattern: every variable is set with `${VAR:-default}`. If dotfiles has already
set `__APPDIR`, `XDG_CONFIG_HOME`, etc. before env.sh is sourced, those values are
preserved. If not, env.sh uses sensible defaults.

> **Updated in Phase 2:** `env.sh` is no longer hand-maintained. It is generated from
> `bsos.installers._env`, which is the single source of truth for both this shell file and
> the Python installers' path logic. The pseudocode above still describes its semantics;
> see Phase 2 for the generator.

This means:
- **Path 3 (envoy only):** env.sh runs with no pre-existing vars, uses all defaults.
  A user gets a working environment at `~/.local/...`.
- **Paths 1-2 (dotfiles + envoy):** dotfiles' `.zshenv` sets `__APPDIR`, XDG base
  dirs, etc. first, then sources env.sh. env.sh sees `__APPDIR` and derives
  `__OPT_ROOT` accordingly (e.g., `/cosma/apps/durham/$USER/opt/...` on an HPC cluster).
- **Path 4 (dotfiles only):** dotfiles sets XDG base dirs directly and optionally
  references `__OPT_ROOT`/`MAMBA_ROOT_PREFIX` for personal exports — but those vars
  will simply be unset, which is correct: if envoy isn't installed, the tools it
  manages aren't installed either. No fallback logic needed.

### Why not `.envrc` / direnv

The modularization principle (envoy checks pre-existing vars, falls back to defaults)
could in theory be expressed as a direnv `.envrc`. However, `.envrc` has specific
direnv semantics: it's auto-loaded when entering a directory and sandboxed. What we
need is a shell library sourced at shell startup (`~/.zshenv`), regardless of the
current directory. Using the name `.envrc` would cause unintended direnv activation
for anyone who has direnv enabled and clones envoy. The file is named `env.sh` instead.

### envoy's dotfiles/ subdirectory

Currently envoy ships fallback dotfiles (`.zshenv`, `.zshrc`, `.bashrc`, etc.) used
during bootstrap's HTTPS-only phase.

After this refactoring, envoy's `dotfiles/` directory is replaced by `env.sh` (the
extracted generic env setup). The fallback `.zshrc` is either removed or reduced to
a minimal interactive shell setup that only activates envoy-provided tools. The
bootstrap script downloads `env.sh` instead of full dotfiles during Stage 0.

### Sourcing order in dotfiles' .zshenv

```bash
# 1. Personal/machine-specific setup (runs unconditionally, no envoy dependency)
#    Sets __HOST, __APPDIR, SCRATCH, __NCPU, Homebrew prefix.
#    Sets XDG base dirs directly (dotfiles needs these regardless of envoy).

# 2. Source envoy's env.sh if available — no fallback needed
#    env.sh derives __LOCAL_ROOT, __OPT_ROOT, MAMBA_ROOT_PREFIX, PIXI_HOME
#    (using __APPDIR if already set). If env.sh is absent, those vars are
#    simply unset — correct, because the tools envoy manages aren't installed.
[[ -f "${XDG_DATA_HOME}/envoy/env.sh" ]] && . "${XDG_DATA_HOME}/envoy/env.sh"

# 3. Personal exports (EDITOR, LANG, SMAN_SNIPPET_DIR, CARGO_PREFIX, etc.)
#    May reference __OPT_ROOT or XDG vars set above. If __OPT_ROOT is unset
#    (envoy absent), exports that reference it are simply empty — harmless.
```

The "no fallback" design is intentional: the variables env.sh provides only have
meaning when envoy is installed. dotfiles need not replicate envoy's path logic.

### What this phase produces

- envoy is usable standalone: source `env.sh`, get correct platform detection and paths.
- dotfiles is usable standalone: personal shell config works with XDG base dirs it
  sets itself; vars like `MAMBA_ROOT_PREFIX` are simply absent when envoy isn't installed.
- When both are present, dotfiles sets `__APPDIR` and XDG dirs first, then sources
  env.sh which derives `__OPT_ROOT` and tool paths respecting those pre-set values.
- The boundary is enforced by two clear invariants:
  1. envoy never references dotfiles, only checks pre-existing env vars.
  2. dotfiles never replicates envoy's path derivation logic — it either gets those
     vars from env.sh (envoy present) or doesn't use them (envoy absent).

---

## Phase 2 — Python-based Installers with Compile System

**Goal:** Replace envoy's bash compile.sh / makefile system with Python-based installers.
Each installer is a modular Python submodule, stdlib-only, compiled into a self-contained
single-file script for `curl | python3` distribution. pixi tasks provide the development
and orchestration interface.

**Depends on:** Phase 1 (installers reference the decoupled env vars; `env.sh` is now
*generated* from the same Python module — see below).

**Status: Complete.** PR #1 merged into envoy `main`. All installers are ported; the bash
compile system is superseded; CI covers smoke, unit, freshness, lint, and dead-code checks.
The remaining bash artefacts (`install/src/compile.sh`, `install/makefile`,
`install/src/lib/*.sh`, `install/src/bin/bootstrap.sh`, `install/src/bin/dotfiles.sh`,
`install/bootstrap.sh`, `install/dotfiles.sh`) are kept until Phase 4's bootstrap
orchestrator replaces them.

### Installer module: `bsos.installers`

A stdlib-only package inside bsos:

```
src/bsos/installers/
  __init__.py       # package docstring; install/uninstall/update/reinstall/test convention
  __main__.py       # entry point: python -m bsos.installers <action> [names…]
  _env.py           # EnvConfig (path derivation) + env.sh generator — single source of truth
  _download.py      # stdlib download + tar/zip extraction helpers (with retry)
  _subprocess.py    # find_command / require_command / run (explicit child env)
  _compile.py       # the compile system (see below)
  _recipe.py        # declarative Recipe engine — most installers reduce to one RECIPE line
  clifton.py        # Clifton HPC workflow tool installer
  code.py           # VS Code CLI installer
  codex.py          # OpenAI Codex CLI installer
  gh.py             # GitHub CLI installer
  mamba.py          # Miniforge3 (mamba) installer
  mamba_env.py      # conda environment installer (uses local env files or URL)
  pixi.py           # pixi installer
  sman.py           # sman snippet manager installer
  zim.py            # zim zsh plugin manager installer
```

A companion `bsos.shell` subpackage holds:
```
src/bsos/shell/
  completion.py     # generate-completions: writes to XDG_DATA_HOME dirs
```

**Hard constraint:** `bsos.installers` uses only Python stdlib. No exceptions. `bsos.__version__`
is baked to a literal at compile time, so compiled artefacts carry no `bsos` dependency.

### Declarative Recipe engine

`_recipe.py` introduces a `Recipe` dataclass and `github_binary` / `run_cli` helpers.
Most tool installers reduce to a single declaration:

```python
RECIPE = github_binary(name="gh", repo="cli/cli", asset="gh_{version}_linux_amd64.tar.gz",
                       targets={…}, member="bin/gh")
if __name__ == "__main__":
    run_cli(RECIPE)
```

The engine implements the five shared stages (locate → unpack/place → cleanup → test →
uninstall) exactly once, and the tree-shaker inlines only the stages each recipe actually
reaches into its compiled output.

### Env as a single source of truth

`_env.py` is the authority for envoy's path knowledge, exposed two ways:
- `EnvConfig` — a Python class the installers use to derive `__OPT_ROOT`, `bin_dir`,
  `MAMBA_ROOT_PREFIX`, the XDG dirs, etc., respecting pre-existing values and treating an
  empty string as unset (matching the shell `${VAR:-default}` semantics). It also builds
  the controlled environment (`subprocess_env()`) handed to installer subprocesses.
- `generate_env_sh()` — emits the shell `env.sh` from the same definitions.

Phase 1's hand-maintained `env.sh` is now a *generated artefact*: `_env.py` is the source
of truth, `env.sh` is regenerated from it (`pixi run generate-env-sh`) and pinned by a
test. Non-Python shells keep sourcing `env.sh`, and the installers' path logic can no
longer drift from it.

### Entry-point convention

Every installer module exposes five actions: `install`, `update`, `reinstall`, `uninstall`,
and `test`.
- `install` is idempotent — prints "already installed" and exits 0 if the tool is present.
- `update` updates an existing install in-place.
- `reinstall` is `uninstall` + fresh `install`.
- `test` validates the install on the current platform and **skips cleanly (exit 0) on an
  unsupported platform**, so CI can run it on any runner.

Each module runs as `python -m bsos.installers.<name> <action>` and, once compiled, as
`python3 install/<name>.py <action>` (or `curl … | python3 - <action>`).

The package entry point (`python -m bsos.installers <action> [names…]`) auto-discovers all
non-private installer modules and drives them in order, with optional filtering by name.

### Compile system

`bsos.installers._compile` produces a self-contained script from a source module
(`python -m bsos.installers._compile` or `pixi run compile`).
It is AST-based and does more than concatenation:
- resolves intra-package imports and topologically sorts dependencies;
- **tree-shakes to definition granularity** — only the functions/classes/assignments
  actually reachable from what each importer uses are emitted (the target module itself is
  kept whole), so a small installer pulls in only the helpers it touches;
- merges, de-duplicates, and canonicalizes stdlib imports; drops intra-package imports;
  hoists `__future__` (including `annotations` for PEP 563 safety); carries the target's
  docstring; emits the `if __name__` block last;
- **bakes `from bsos import <const>`** to a literal (e.g. `__version__ = '0.1.0'`) so the
  output needs no `bsos` package. Only simple constants may be baked.

### Compiled output and distribution

Compiled scripts live in `install/` and are tracked in git. Each is directly usable:
```bash
curl -fsSL https://raw.githubusercontent.com/ickc/envoy/main/install/code.py | python3 - install
```
The unported bash scripts (`bootstrap.sh`, `dotfiles.sh`) remain until Phase 4.

### Pixi tasks

pixi config lives in `pyproject.toml` under `[tool.pixi.*]`. Key tasks:

- `compile` — recompile all installer modules (`python -m bsos.installers._compile`);
  pass `-- <name>` to target one module
- `install`, `uninstall`, `smoke` — drive all (or named) installers; auto-discover modules
- `generate-env-sh` — regenerate `env.sh` from `_env.py`
- `generate-completions` — write shell completions to `$XDG_DATA_HOME/zsh/functions/`
  and `$XDG_DATA_HOME/bash-completion/completions/`
- `test` — run the pytest suite
- `format`, `lint` — run all formatters / linters (shell + Python)
- `lint-compiled` — dead-code check on `install/*.py` via vulture

All installer tasks auto-discover modules; adding a new module requires no task boilerplate.

### Tests

`tests/` holds several test files, all new in this phase (the plan originally deferred
testing to Phase 5):
- `test_env.py` — env derivation: defaults, `__APPDIR` redirect, pre-existing values,
  empty-as-unset, subprocess env
- `test_compile.py` — compile correctness: topological order; valid Python with no leaked
  `bsos`/relative imports; version baked; annotations safe under PEP 563
- `test_download.py` — download helpers
- `test_idempotency.py` — idempotency: artifact-freshness guards for `env.sh` and all
  `install/*.py` (stale checked-in artefacts fail CI)
- `test_main.py` — package entry-point and action dispatch

### CI

`.github/workflows/test-installers.yml` runs on push and PR, with five jobs:
- **smoke** — for each `install/*.py`, run `install`, idempotency check, `update`, and
  `reinstall` + `test` on all four supported runners (`ubuntu-latest`, `ubuntu-24.04-arm`,
  `macos-latest`, `macos-26-intel`). Uses stock `actions/setup-python` (no pixi) —
  proving the `curl | python3` path needs only a system Python. Globs `install/*.py`
  so new installers are covered automatically.
- **unit** — `pixi run test` (pytest suite including freshness guards).
- **generated** — `pixi run format && pixi run compile` then `git diff --exit-code`;
  enforces that formatted/compiled artefacts are always committed in sync with source.
- **lint** — `pixi run lint` (shellcheck + ruff + mypy + pyright).
- **lint-compiled** — `pixi run lint-compiled` (vulture dead-code check on `install/*.py`).

This installer-level CI exercises installers via their real entry points on real OSes.
Phase 5's full-bootstrap container CI (paths 1/2/3) is a separate, later concern.

### What remains from the original removal list

The following bash artefacts survive Phase 2 and will be removed in Phase 4 when the
bootstrap orchestrator module lands:
- `install/src/compile.sh` — the old bash preprocessor
- `install/makefile`
- `install/src/lib/*.sh` — the old bash installer libraries
- `install/src/bin/bootstrap.sh`, `install/src/bin/dotfiles.sh`
- `install/bootstrap.sh`, `install/dotfiles.sh` — the two unported bash installers

Already removed (Phase 1 + Phase 2): `envoy/dotfiles/`, `install/src/bin/` (except the
two above), all other `install/*.sh`.

---

## Phase 3 — Chezmoi-based Dotfiles

**Goal:** Restructure dotfiles as a chezmoi source state (public, **no secrets**).
Replace `make all` with `chezmoi apply`. `ssh-dir` is **not** absorbed — it stays a
standalone private repo (see Phase 4).

**Depends on:** Phase 1 (the content split defines what chezmoi templates generate
vs. what envoy provides).

**Scope note:** chezmoi is used here only for **public, non-secret** config plus
machine-class *templating* of public values (HPC `__APPDIR`/`SCRATCH`, per-machine git
email, macOS vs. Linux differences). chezmoi's encryption features are intentionally
unused. Anything secret (SSH private keys, `gh`'s `oauth_token`, etc.) is kept out of the
dotfiles repo entirely.

### Restructure dotfiles repo

The current layout:
```
dotfiles/
  home/.zshenv, .zshrc, .zimrc, ...   # symlinked to ~
  config/                              # symlinked wholesale as ~/.config
  makefile
```

Becomes a chezmoi source directory:
```
dotfiles/
  dot_zshenv.tmpl              # template: sets personal vars, sources envoy/env.sh
  dot_zshrc.tmpl               # template: ml_*/mu_* modules, tool integrations
  dot_zimrc                    # static
  dot_bash_profile             # static
  dot_bashrc                   # static
  dot_config/
    exact_git/config.tmpl      # templated (e.g., email per machine class)
    exact_helix/config.toml    # static
    exact_starship.toml        # static
    exact_navi/config.yaml     # static
    ...                        # ~27 config subdirs, individually listed
  .chezmoidata.yaml            # machine-class variables
  .chezmoiignore               # OS-specific ignores
```

There is **no** `private_dot_ssh/` here — SSH is owned by the separate `ssh-dir` repo.
Any config that would embed a secret (e.g. `gh`'s `hosts.yml` with an `oauth_token`) is
`.chezmoiignore`d or templated to exclude the secret; the token is produced locally by
`gh auth login` during bootstrap, never committed.

### Breaking the wholesale config/ symlink

Every subdirectory of `config/` becomes an individual entry in chezmoi's source tree.
Most are static copies (not templates). The benefit: `~/.config` becomes a real directory.
Tools can create files in it without git noise. chezmoi tracks only what we manage.

### Template variables via .chezmoidata.yaml

Machine class is determined by hostname patterns. Templates use variables for **public,
machine-specific** values only:
- HPC cluster paths (`__APPDIR`, `SCRATCH`)
- Per-machine public config (e.g. git email per machine class)
- OS-specific config (macOS vs. Linux differences)

There is no "decrypt secrets" mode — dotfiles never carries secrets, so every machine
class applies the same (public) source state, differing only in templated public values.

### ssh-dir stays separate (not absorbed)

SSH is **not** moved into chezmoi. The `ssh-dir` repo remains a standalone **private**
repo cloned to `~/.ssh`, keeping its own `config` / `config_clifton` / `config_DiRAC`,
`known_hosts`, and `authorized_keys`. Private keys are never committed there — they are
generated per-machine during bootstrap and stay local-only. This gives two independent
layers of protection: a private (access-controlled) repo for sensitive-but-shareable
files, and never-committed local-only private keys.

> **Deferred / future:** absorbing `ssh-dir` into chezmoi via encrypted secrets (age,
> 1Password, etc.) may be revisited once there's more comfort with chezmoi's secret
> management. It is explicitly out of scope for now.

### Graceful degradation (path 4: dotfiles without envoy)

chezmoi templates for `.zshenv` include a fallback path: if envoy's `env.sh` is not
found, dotfiles inlines a minimal version of the platform detection and path derivation.
This keeps dotfiles functional standalone, at the cost of a small amount of duplicated
logic.

### What replaces `make all`

`chezmoi apply` replaces the makefile's `config`, `shell`, and `taskfile` targets.
`chezmoi init` sets up the machine-class config on first run.

### Idempotency

chezmoi tracks file state and only writes changed files. Re-running `chezmoi apply`
is safe by design — this directly solves ISSUES.md #7 for the dotfiles component.

### README (standalone path)

Per the **Individual Bootstrappability** invariant, dotfiles' README documents its
standalone setup (`chezmoi init --apply <repo>`). dotfiles *is* the shell config, so it
has no separate "minimum shell-rc additions" contract.

---

## Phase 4 — Orchestrator Integration

**Goal:** This repo becomes the top-level bootstrap entry point. One-liner setup on
fresh systems.

**Depends on:** Phase 2 (envoy has pixi tasks) + Phase 3 (dotfiles has chezmoi source).

### Top-level pixi.toml

This repo gets a `pixi.toml` that composes envoy's tasks and adds orchestration:
- `bootstrap` — full personal sequence (path 1)
- `bootstrap-public` — no secrets, HTTPS-only (path 2)
- `init` — submodule setup (development use)
- `update` — submodule pull (development use)

Per the **Individual Bootstrappability** invariant, these tasks **compose** each repo's
documented standalone step (clone-to-path / `python3 install/<tool>.py` / `chezmoi apply`)
rather than reimplementing it, so the orchestrated path and the README codeblocks stay in
sync.

### Bootstrap sequence (path 1: full personal)

```
Stage 0 (pure shell, ~30 lines — the one-liner):
  1. Detect OS/arch, compute PIXI_HOME
  2. Install pixi via curl
  3. Clone this repo via HTTPS
  4. Hand off to pixi

Stage 1 (pixi available):
  5. pixi run install-envoy       # clone envoy to XDG_DATA_HOME/envoy
  6. source envoy/env.sh          # now all paths are set
  7. pixi run install-mamba
  8. pixi run install-system-env  # provides task, git, zsh, etc.
  9. pixi run install-zim
  10. pixi run install-code

Stage 2 (SSH pivot — interactive):
  11. pixi run ssh-keygen
  12. pixi run gh-auth

Stage 3 (git+SSH available):
  13. pixi run install-chezmoi
  14. pixi run chezmoi-init       # chezmoi init + apply — public dotfiles only (no secrets)
  15. pixi run clone-ssh-dir      # clone ickc/ssh-dir (private) into ~/.ssh, fix perms
                                  #   (path 1 only; preserves the per-machine key from step 11)
  16. pixi run install-sman-bin   # binary
  17. pixi run clone-snippets     # sman-snippets, navi-cheatsheets
  18. pixi run generate-completions
```

### Bootstrap sequence (path 2: public)

Same as path 1 but omits Stage 2 (no SSH keygen, no gh auth) and the `clone-ssh-dir`
step. dotfiles applies identically — it is always public and never carries secrets — so
there is no separate "chezmoi public mode"; machine-class *templating* of public values
still applies.

### Bootstrap sequence (path 3: envoy only)

Only Stages 0-1. No chezmoi, no dotfiles, no SSH.

### The one-liner

```bash
curl -fsSL https://raw.githubusercontent.com/ickc/bootstrap/main/bootstrap.sh | bash
```

`bootstrap.sh` is a ~30-line Stage 0 shell script (not compiled, not generated — the
only shell script in the system). It installs pixi and hands off to `pixi run bootstrap`.

For public mode:
```bash
curl -fsSL ... | bash -s -- --public
```

### Submodule changes

- Keep `ssh-dir` as a submodule (standalone private repo; cloned to `~/.ssh` on path 1)
- Keep `dotfiles`, `envoy`, `sman-snippets`, `navi-cheatsheets` as submodules
  (for development and version-pinning; not required on bootstrapped end systems)

---

## Phase 5 — Testing and Migration

**Goal:** Automated validation of the bootstrap. Migration path for existing systems.

### Automated smoke tests

After bootstrap completes, verify:
- pixi, mamba, code CLI are on PATH and functional
- `~/.config` exists as a real directory (not a symlink)
- Expected config files exist (spot-check)
- `$MAMBA_ROOT_PREFIX/bin/mamba` works
- System env tools are discoverable (`task --version`, `git --version`)
- SSH key exists with correct permissions (path 1 only)
- sman and navi are functional
- Shell completions are present in `$XDG_DATA_HOME/zsh/functions/`

This is a pixi task (`pixi run test-bootstrap`) that runs assertions.

### CI: test on fresh containers

Installer-level CI already exists from Phase 2 (`test-installers.yml`: per-installer
`install` + `test` on native GitHub runners). Phase 5 adds end-to-end CI for the *full
bootstrap* — run the one-liner in Docker containers (or similar) for each supported platform:
- Linux x86_64, Linux aarch64
- macOS arm64, macOS x86_64 (if CI supports it)

Test paths 1 (with mock secret key), 2 (public), and 3 (envoy only).

### Migration script for existing systems

Existing systems have:
- Repos at `~/git/source/{dotfiles,envoy,sman-snippets}`
- `~/.ssh` as a git clone of ssh-dir
- `~/.config` → symlink to dotfiles/config/
- mamba already at `$MAMBA_ROOT_PREFIX`

The migration (`pixi run migrate`):
1. **Move repos** to new XDG locations:
   - `~/git/source/envoy` → `$XDG_DATA_HOME/envoy`
   - `~/git/source/sman-snippets` → `$XDG_DATA_HOME/sman/snippets`
2. **Convert dotfiles:** remove `~/.config` symlink, run `chezmoi init` + `chezmoi apply`
   (chezmoi places individual files, `~/.config` becomes a real directory)
3. **Keep ssh-dir as-is:** `~/.ssh` is already an `ssh-dir` clone — just ensure it tracks
   the renamed `main` branch and run `make permission`. (No merge into dotfiles.)
4. **No re-bootstrap needed** for mamba/system-env/pixi — already installed at
   correct paths
5. **Update sman.rc location** and verify .zshrc sources from new path
6. **Verify** via smoke tests

The migration should be idempotent (safe to re-run) and refuse to overwrite
without `--force`.

---

## Phase Dependencies

```
Phase 0 (housekeeping)
  │
  ▼
Phase 1 (env decoupling) ←── branch to dev here
  │         │
  ▼         ▼
Phase 2   Phase 3
(pixi)    (chezmoi)    ←── can proceed in parallel
  │         │
  └────┬────┘
       ▼
Phase 4 (orchestrator)
       │
       ▼
Phase 5 (testing + migration)
```

Phase 2 and Phase 3 are independent (both depend only on Phase 1).
They can proceed in parallel or in either order. Phase 2 is likely easier
(less restructuring) and builds momentum.

---

## Discussion Items

### 1. Completion and generated file placement

Completions and sman.rc move from `$XDG_CONFIG_HOME/zsh/functions/` to
`$XDG_DATA_HOME/zsh/functions/` and `$XDG_DATA_HOME/sman/sman.rc`. The `.zshrc`
fpath must be updated. Confirm this doesn't break zsh/bash completion discovery
(standard completions dirs are typically under `$XDG_DATA_HOME`).

### 2. chezmoi update lifecycle

Currently, dotfile changes propagate instantly (symlink to git working tree). With
chezmoi, changes require `chezmoi apply`. During development, `chezmoi apply --watch`
can auto-apply. For production use it's an explicit step — a tradeoff for idempotency.

### 3. ssh-dir stays standalone (absorption deferred)

`ssh-dir` is **not** absorbed into dotfiles. It remains a standalone private repo cloned
to `~/.ssh`, with private keys generated per-machine (never committed). chezmoi carries no
secrets and uses no encryption backend. Revisiting absorption via chezmoi-encrypted
secrets (age, 1Password, Bitwarden, gopass, vault) is a possible future exploration,
deferred until there's more comfort with chezmoi's secret management.

### 4. ml_* / mu_* module system

The module system in `.zshrc` is a lazy-loading mechanism (generic) with a
tool-specific load list (personal). Currently it stays in dotfiles. If there's future
demand to reuse the mechanism without the personal tool list, it could be extracted to
envoy as a shell library function. Not a Phase 1 concern.

### 5. Standalone shell script extraction

The compile system currently produces self-contained `bash foo.sh install` scripts
with zero dependencies. With pixi, single-tool install requires pixi first:
`pixi run install-code`. This is a deliberate tradeoff: pixi is a single static binary
(~20s download), and the benefit of real task orchestration, dependency tracking, and
testability outweighs the loss of zero-dependency scripts. For platforms without pixi
(ppc64le, FreeBSD), individual installer functions remain usable as plain shell by
sourcing them directly.

# Issues and Migration Plan

This document captures current structural problems with the bootstrap process and a migration path toward a more modular, decoupled design. It intentionally preserves the reasoning behind each decision, because many of the design choices involve trade-offs that will need to be revisited at each concrete step.

---

## Current Issues

### 1. Tight coupling between dotfiles and envoy
`bootstrap.sh` runs both `dotfiles` and `envoy` install logic in a fixed order. A change in one often requires coordinated changes in the other. Most concretely: both touch `$XDG_CONFIG_HOME/zsh/functions` (sman.rc goes there, dotfiles owns that dir).

### 2. Personal and reusable bits mixed in envoy
`envoy` ships generic installers (mamba, VS Code CLI, sman) alongside personal choices (specific conda env lockfiles). The conda lockfiles (`conda/*.yml`) are generated from CSV config files via the `bsos` library and represent personal software choices, not a reusable library interface. A third party can't use `envoy` as-is without either forking or ignoring the conda layer. That said, the conda YML files serve as *examples* of how to use the installer framework, and `system` in particular is load-bearing for the bootstrap. The question of whether to ship all variants as examples or only `system` is open.

### 3. No supported public/non-personal bootstrap mode
Everything is treated as a single pipeline that ends with personal SSH keys. There is no path for:
- Running on a throw-away or shared account to get a "home-like" environment without personal artifacts (no `ssh-dir`, no `gh auth`, HTTPS-only git)
- A third party using the public repos without the private pieces

This has been needed in practice (e.g., setting up a testing environment) and currently requires manually skipping steps.

### 4. dotfiles mixes personal and environment-bootstrap concerns
`.zshenv` and `.zshrc` currently handle both reusable bootstrap logic (arch/host detection, path helper functions, `ml_*` module system) and personal choices (EDITOR=nano, terminal title format, cluster-specific `$SCRATCH` paths, alias for JupyterLab.app). These can't be separated by a user who wants the infrastructure but not the personal opinions.

### 5. Bootstrap dependency on mamba system env (chicken-and-egg)
The mamba `system` environment provides tools that are needed later in the bootstrap (e.g., `task` for Taskfile, a recent-enough `git`, `zsh`). This is intentional — it works around systems where the distro-provided versions are too old or unavailable. But it means: **any orchestration tool used after step 5 must either come from the system env or be available before mamba is installed.** If the end-state design uses Taskfile for orchestration, the very first stage of bootstrap must still be plain shell (or a tiny pre-task script) that installs mamba + system env first.

### 6. `sman-snippets` path is hardcoded in dotfiles
`SMAN_SNIPPET_DIR="${HOME}/git/source/sman-snippets"` is set in `.zshenv`. The bootstrap clones to that path. Any divergence (e.g., using this repo's `submodule/sman-snippets`) silently breaks sman.

### 7. No idempotency guarantees
Several install steps do the wrong thing on re-run. The `config` target in dotfiles deletes all symlinks under `$XDG_CONFIG_HOME` before relinking — any manually-added config is destroyed. `ssh_dir_install` in bootstrap.sh does `rm -rf ~/.ssh` before moving. The right behavior on re-run is an open question: fail-fast with a clear error, or accept a `--force` flag to overwrite.

### 8. bootstrap.sh is a compiled artifact
The script in `envoy/install/bootstrap.sh` is assembled from fragments in `install/src/` by `install/compile.sh`. The fragments are the source of truth. It's easy to edit `bootstrap.sh` directly and have the change silently overwritten.

---

## Proposed Migration

### Open Design Questions

Before committing to a phase, these questions should be answered:

**Q1: How should dotfiles be split?**
One option: split `.zshenv` into a "bootstrap layer" (arch/OS detection, path variable derivation, `ml_*` functions — owned by envoy or a new `shell-lib` repo) and a "personal layer" (EDITOR, title, cluster paths, alias — owned by dotfiles). A master `.zshenv` sources bootstrap layer first, then personal layer. Similarly for `.zshrc`. The bootstrap layer becomes reusable; the personal layer is clearly personal. This maintains a single entry point (`.zshenv`) without losing the current sourcing-order guarantees.

Alternative: keep them merged in dotfiles but annotate sections clearly, and rely on the public/private fork structure to separate them. Simpler but doesn't help third parties.

**Q2: What goes in envoy vs envoy-personal?**
Current thinking: `envoy` keeps the installer functions and the `system` conda env as the canonical example. Other conda envs (py310–py314, jupyterlab) move to `envoy-personal` as personal configurations that happen to also serve as examples of the framework. The `bsos`-generated CSV→YML pipeline stays in `envoy` as the generation tooling; the CSVs and generated YMLs for personal envs move to `envoy-personal`.

**Q3: Should envoy-personal be public?**
Yes. It contains no secrets — just software lists and version pins. Being public makes it usable by others as a reference and simplifies the submodule model (no mixed public/private access required).

**Q4: Should this repo (bootstrap) be public?**
Probably yes, with the caveat that `ssh-dir` is a private submodule so others can't run it as-is. The repo itself contains no secrets and could be useful as a reference architecture. A public repo also makes the "public bootstrap mode" (see Phase 2) accessible without authentication.

**Q5: What is the right idempotency model?**
Two reasonable modes: (a) refuse-if-exists — safe by default, explicit `--force` or `--update` to overwrite; (b) update-if-newer — always run, but use `mamba env update --prune` style semantics. These may differ per component: dotfiles probably want mode (a) to protect manual edits; binary installs probably want mode (b) to stay current.

---

### Phase 1 — Split the dotfiles

Refactor `.zshenv` and `.zshrc` into layered files:

- `envoy` (or a new `shell-lib` repo): provides the reusable bootstrap layer — OS/arch detection, `__LOCAL_ROOT`/`__OPT_ROOT` derivation, XDG setup, `ml_*` / `mu_*` module functions, path helpers.
- `dotfiles`: provides the personal layer — EDITOR, title format, cluster-specific `$SCRATCH` and `__APPDIR` paths, macOS aliases.
- A top-level `.zshenv` sources the bootstrap layer, then the personal layer, in that order.

This is the key decoupling step. Without it, `envoy` can never be truly reusable because its path variables depend on personal host-detection logic in dotfiles.

*Feasibility note:* The current `.zshenv` has interleaved personal and generic logic (e.g., `__HOST` detection sets `__APPDIR`, which then affects `__OPT_ROOT`). Splitting requires careful sequencing. One approach: the bootstrap layer owns `__OPT_ROOT` derivation with a hook point (`__APPDIR` override) that the personal layer can set before sourcing the bootstrap layer.

### Phase 2 — Add a public bootstrap mode

Extend `bootstrap.sh` (or a new top-level `bootstrap.sh` in this repo) with a `--public` flag:
- Uses HTTPS-only git throughout (no `gh auth`, no `ssh_dir_install`)
- Skips `ssh-dir` entirely
- Uses dotfiles' public-mode (no personal cluster paths, no EDITOR=nano if that's personal)
- Result: a functional "home-like" environment on any account, no credentials required

This directly addresses the use case of bootstrapping testing environments. The `--public` variant should be the one that can be `curl | bash`'d by a third party.

### Phase 3 — Separate envoy into generic and personal

- `envoy` retains: installer functions (mamba, VS Code CLI, sman, zim), `system` conda env as canonical example, `bsos`-based CSV→YML generation tooling.
- `envoy-personal` (new, public): personal conda env CSVs + generated YMLs (py3xx, jupyterlab variants), personal `system.csv` overrides if any.
- `bootstrap` (this repo) references `envoy-personal` as a submodule (or just documents how to wire it in).

### Phase 4 — Make this repo the orchestration layer

Move the bootstrap sequence from `envoy/install/bootstrap.sh` into this repo:
- Stage 0 (plain shell, no taskfile): install mamba + system env — this stage must be self-contained
- Stage 1+ (taskfile available from system env): Taskfile tasks per component
- Each submodule exposes its own install target; this repo's Taskfile calls them in order
- Separation of stages is explicit, not implicit from script ordering

The key constraint: Taskfile is available only after stage 0 completes. Stage 0 must be plain shell (or use only tools guaranteed on a fresh system: curl/wget, bash, git).

### Phase 5 — Harden idempotency

Per component:
- Dotfiles: refuse-if-exists by default; `--force` to overwrite. Prevents accidental destruction of manual edits.
- Binary installs (mamba, sman, VS Code CLI, zim): update-if-installed semantics (already partially done for mamba).
- Conda envs: `mamba env update --prune` (already done).
- SSH key generation: already idempotent (skips if key exists).
- `ssh_dir_install`: currently destructive (`rm -rf ~/.ssh`). Should check for existing install and either skip or `--force`.

---

## Repo Visibility End State

| Repo | Visibility | Contains |
|------|------------|---------|
| `envoy` | public | Generic installer functions, `system` conda env example, bsos tooling |
| `envoy-personal` | public | Personal conda env CSVs + YMLs; no secrets |
| `dotfiles` | public | Shell bootstrap layer + personal dotfiles |
| `sman-snippets` | public | Shell snippets |
| `ssh-dir` | private | SSH keys, known_hosts — the only secret-holding repo |
| `bootstrap` (this repo) | public (likely) | Orchestration, submodule pinning; private submodule means others can't fully run it but can read it |

## End State Bootstrap Flow

```
# Anyone (public mode):
curl -fsSL https://raw.githubusercontent.com/ickc/bootstrap/main/bootstrap.sh | bash --public

# Personal (private mode, after initial public bootstrap or on a machine with SSH):
git clone git@github.com:ickc/bootstrap.git && cd bootstrap
task init    # git submodule update --init --recursive
task install # Stage 0 (shell): mamba + system env
             # Stage 1+ (taskfile): dotfiles, sman, envoy completions, ssh-dir
```

Re-running `task install` on an existing machine follows the idempotency rules per component (refuse-if-exists or update depending on component type).

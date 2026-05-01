# Proposals

The bootstrap system solves one problem: turn a bare UNIX account into a working
personal environment. Every issue in ISSUES.md traces to a single root cause —
**"what to install" and "how to install" live in the same code.** Fixing that
separation is the entire game. Everything else (idempotency, public mode,
re-runnability) falls out naturally once the boundary is clean.

## Hard Constraints

These are non-negotiable and eliminate entire categories of tooling:

1. **No sudo.** The bootstrap must work on accounts where the user has no
   root access and cannot ask an administrator to install anything. This
   rules out Nix (requires root or a daemon for multi-user installs, and
   even single-user Nix can conflict with restrictive HPC filesystem
   policies), system package managers, and anything that touches `/usr`,
   `/etc`, or `/nix`.

2. **User-local only.** Everything installs under `$HOME` (or a redirected
   `$__LOCAL_ROOT`/`$__OPT_ROOT` on HPC clusters). The host OS provides
   only a POSIX shell, curl/wget, tar, and git.

3. **Standalone extraction.** The current compile system lets individual
   tools be installed via a single self-contained shell script (e.g.,
   `bash code.sh install` — no task runner, no package manager, nothing).
   Any new design must preserve the ability to install a single component
   with minimal prerequisites, even if the full bootstrap uses heavier
   orchestration.

Below are five approaches. They differ in where the boundary between
"reusable infrastructure" and "personal choices" lives, and what enforces it.

---

## Approach A: Layered Shell Split (the ISSUES.md plan)

**Idea:** Keep the current shell-script architecture but refactor into layers.
Split `.zshenv`/`.zshrc` into a "bootstrap layer" (generic) and "personal layer."
Split `envoy` into `envoy` (generic installers) and `envoy-personal` (conda env
lists). Add a `--public` flag. Harden idempotency per-component. Preserve the
compile system for standalone scripts.

**Boundary enforcement:** Convention. The split is a file-level agreement between
repos. Nothing prevents drift back toward coupling except discipline.

### Strengths
- Minimal disruption — every piece of existing code survives in some form.
- No new tooling dependencies. The bootstrap stays pure shell at Stage 0.
- The 5-phase plan is already designed and can be executed incrementally.
- The compile system continues to produce standalone scripts naturally.

### Weaknesses
- The boundary is soft. Shell scripts that source each other have no interface
  contract; a new function in the bootstrap layer that references a personal
  variable re-creates the coupling silently.
- Five phases across six repos is a long migration. The intermediate states
  (phase 2 done, phase 3 not started) are themselves fragile configurations
  that need testing.
- Idempotency is bolted on per-component with ad-hoc logic rather than coming
  from an underlying model.
- The compiled artifact problem persists — the compile system works but
  editing the output rather than the source remains a pitfall.

### Best for
Someone who values continuity with the current system and wants to evolve
rather than replace.

---

## Approach B: Plugin Architecture (shell-based)

**Idea:** The bootstrap becomes a minimal shell core (~100 lines) that:
1. Installs a package manager (mamba) and a task runner (task) — Stage 0.
2. Discovers "component descriptors" — small files (TOML, YAML, or even just
   shell snippets) that declare: name, dependencies, install command, update
   command, check command.
3. Topologically sorts them and runs install/update.

Each current piece (dotfiles, sman, ssh-dir, each conda env) becomes a
component. A "profile" is a list of component names. `--public` is just
a profile that omits `ssh-dir` and `gh-auth`.

```
components/
  dotfiles.toml      # depends: [], install: "make -C $DOTFILES all"
  mamba.toml          # depends: [], install: "..."
  system-env.toml     # depends: [mamba], install: "mamba env update ..."
  sman.toml           # depends: [gh-auth], install: "..."
  ssh-dir.toml        # depends: [gh-auth], install: "..."
  gh-auth.toml        # depends: [ssh-keygen], install: "gh auth login"
profiles/
  public.txt          # mamba, system-env, dotfiles
  personal.txt        # mamba, system-env, dotfiles, gh-auth, sman, ssh-dir
```

**Boundary enforcement:** Structural. Components can only interact through
declared dependencies. The core runner doesn't know what any component does.

### Strengths
- Clean separation by construction, not convention. Adding a new tool means
  adding a file, not editing a monolithic script.
- Dependency ordering is explicit and verifiable. Today it's implicit in
  script line order.
- Idempotency is a first-class concept: each component has `check` (am I
  installed?), `install`, and `update` as distinct operations.
- Profiles solve the `--public` problem generically — you can have
  `minimal`, `public`, `personal`, `hpc-cluster`, etc.
- The compiled artifact problem disappears — there's nothing to compile.

### Weaknesses
- Requires writing the plugin runner. It's small (~100-200 lines of shell)
  but it's new code that needs testing.
- The component descriptors need a format. If TOML/YAML, you need a parser
  available at Stage 0 (before mamba). Pure shell descriptors avoid this but
  are less readable.
- The `.zshenv`/`.zshrc` layering problem is orthogonal — this approach
  solves orchestration but doesn't automatically decouple the shell config.
- Over-engineering risk: if there are only 6-8 components and they rarely
  change, the abstraction layer may cost more than it saves.
- **Loses standalone extraction.** The compile system produces self-contained
  scripts. A plugin runner requires the runner itself. You can still keep the
  compile system alongside, but then you have two orchestration models.

### Best for
Someone who wants a system that scales to more components and profiles
without proportional complexity growth.

---

## Approach C: Chezmoi for Dotfiles

**Idea:** Use [chezmoi](https://www.chezmoi.io/) to manage the **dotfiles
layer only** — the files that land in `$HOME` and `$XDG_CONFIG_HOME`. Envoy
remains an independent project handling software installation (mamba, VS Code
CLI, sman, zim). The bootstrap orchestrator (this repo, or envoy's
`bootstrap.sh`) calls both: envoy for tooling, chezmoi for configuration.

Chezmoi is a single static binary, no sudo
(`sh -c "$(curl -fsLS get.chezmoi.io)"`). It manages files via a "source
state" — a directory of templates and scripts — and applies them to the
home directory idempotently.

```
dotfiles repo (restructured as chezmoi source):
  dot_zshenv.tmpl              # templated for OS/arch/host
  dot_zshrc.tmpl
  dot_config/                  # individual config files, not a wholesale symlink
    git/config.tmpl
    starship.toml
    helix/config.toml
    ...
  private_dot_ssh/             # mode 0600 enforcement; or age-encrypted

bootstrap sequence:
  1. envoy: install mamba, system env, VS Code CLI, zim (unchanged)
  2. chezmoi init + chezmoi apply (replaces `make all` in dotfiles)
  3. envoy: gh auth, sman, ssh-dir (unchanged, or ssh-dir absorbed by chezmoi)
```

Envoy doesn't know about chezmoi. Chezmoi doesn't know about envoy. The
bootstrap orchestrator calls them in sequence.

**Boundary enforcement:** Chezmoi owns file placement and templating.
Envoy owns software installation. The boundary is "files on disk" vs.
"binaries and environments." They interact only through the filesystem
(e.g., chezmoi writes `.zshenv` which references paths that envoy populated).

### Strengths
- **No sudo, single static binary.** Same bootstrapping ease as pixi.
- **Idempotency for dotfiles is built in.** `chezmoi apply` tracks file
  state and skips unchanged files — directly solves ISSUES.md #7 for the
  dotfiles component.
- **Template system solves the shell config split naturally.** Instead of
  splitting `.zshenv` into two files across repos (Phase 1 of ISSUES.md),
  chezmoi templates generate machine-appropriate `.zshenv` from a single
  source. HPC cluster paths, `__APPDIR` overrides, personal aliases — all
  controlled by `.chezmoidata.yaml` variables per machine class.
- **Secret management** via age encryption could absorb `ssh-dir` — SSH
  keys stored encrypted in the dotfiles repo, decrypted on apply. Eliminates
  a private repo.
- **Envoy is untouched.** The install scripts, compile system, and
  standalone extraction all survive exactly as they are. Chezmoi doesn't
  compete with envoy — it replaces only `make all` in dotfiles.
- **Active ecosystem** with good documentation.

### Weaknesses
- **Opinionated about layout.** The current dotfiles repo symlinks
  `config/` wholesale as `$XDG_CONFIG_HOME`. Chezmoi manages individual
  files. Migration requires breaking the `config/` directory into
  individual entries in chezmoi's source tree. This is a significant
  one-time restructuring.
- **Go template syntax** is another thing to learn. For simple
  conditionals it's fine; for the complex host-detection logic currently in
  `.zshenv` it's less readable than native shell.
- **Two tools to understand.** Someone working on the bootstrap must know
  both chezmoi (for dotfiles) and envoy's compile system (for installers).
  The current system is all shell.
- **Doesn't solve orchestration.** The question of how Stage 0 → Stage 1
  → dotfiles → sman → ssh-dir is sequenced is orthogonal. Chezmoi is a
  component, not a coordinator.
- **The `.zshenv` content split is deferred, not solved.** Templates can
  generate different output per machine, but the generic-vs-personal
  separation within the shell logic is still a content-level decision.
  Chezmoi makes it easier to vary the output but doesn't tell you where
  to draw the line.

### Best for
Someone whose primary pain point is dotfile management across diverse
machines (HPC clusters, personal laptop, throwaway VMs) and who wants to
keep envoy's installer infrastructure unchanged.

---

## Approach D: Pixi as Foundation

**Idea:** Bootstrap pixi first (a single static binary, `curl | sh`, no
sudo), then use pixi as both the task runner (`pixi run`) and the provider
of a Python runtime. With Python available, the orchestration logic becomes
a proper Python package — a core library of installer functions plus
driver/pipeline scripts that compose them.

```
Stage 0 (pure shell, ~20 lines):
  curl -fsSL https://pixi.sh/install.sh | PIXI_HOME=$__OPT_ROOT/pixi bash
  → pixi is now available

Stage 1 (pixi available):
  pixi run bootstrap --profile personal
  → Python runtime from pixi, orchestration in Python
```

The Python package structure naturally separates reusable from personal:

```
bootstrap/              # the core library (reusable)
  installers/
    code.py             # install VS Code CLI
    mamba.py            # install miniforge3
    sman.py             # install sman + snippets
    zim.py              # install zim
    dotfiles.py         # clone + make all
    ssh_dir.py          # clone ssh-dir to ~/.ssh
  registry.py           # component registry with dependency graph
  runner.py             # topological executor with profiles

pipelines/              # driver scripts (personal)
  bootstrap.py          # full personal bootstrap
  public.py             # public-mode bootstrap
  code_only.py          # just VS Code CLI

pixi.toml               # declares Python + any build deps
```

**Boundary enforcement:** Python's module system. The library exposes
installer functions; the pipelines import and compose them. Adding a
personal tool means writing a new pipeline, not touching the library. A
third party writes their own pipelines against the same library.

### Strengths
- **Clean separation by language design.** Library vs. application is
  standard software engineering. Import what you need, compose as you
  like. Testing, linting, type checking all come for free.
- **Pixi is a single static binary, no sudo.** Bootstrapping it is as
  lightweight as bootstrapping chezmoi. It also provides `pixi run` as
  a task runner, replacing Taskfile without needing mamba's system env
  first.
- **Python is a better orchestration language than shell** for anything
  beyond trivial sequencing: error handling, dependency graphs, templating,
  platform detection, dry-run mode, logging.
- **Profiles are just code.** `pipelines/bootstrap.py` imports the
  components it wants. No descriptor format to parse, no profile files to
  maintain.
- **Scales naturally.** Adding a component means adding an installer module.
  Adding a profile means adding a pipeline script. The patterns are familiar
  to any Python developer.
- **The compile system's role is absorbed.** Standalone extraction is a
  pipeline that imports one installer and runs it. No separate compilation
  step needed.

### Weaknesses
- **Loses standalone shell scripts.** For installing just the VS Code CLI,
  the user must first install pixi (~20s), then `pixi run install-code`.
  The current `bash code.sh install` requires nothing beyond bash+curl.
  This can be mitigated by keeping the compiled shell scripts in envoy as a
  parallel path, but then there are two implementations to maintain.
- **pixi binary availability.** The pixi binary has official releases for
  Linux x86_64, Linux aarch64, macOS x86_64, and macOS arm64. It does not
  ship a binary for ppc64le or FreeBSD. However, pixi *as a package
  manager* supports ppc64le as a target platform (conda packages can be
  resolved and installed for it). The gap is only at Stage 0: you can't
  `curl | bash` to get pixi on a ppc64le machine. Stage 0 would need a
  fallback (e.g., build pixi from source via cargo, or use the shell
  bootstrap directly).
- **Python adds a layer of abstraction** over what is fundamentally "run
  shell commands." The installer functions will be `subprocess.run(["curl",
  ...])` wrappers. Some will argue this is unnecessary indirection.
- **Shell config decoupling is still orthogonal.** The `.zshenv`/`.zshrc`
  layering is a content problem within dotfiles, not an orchestration
  problem.
- **Chicken-and-egg shift, not elimination.** The current system needs
  mamba before task runner. This system needs pixi before Python. The
  dependency is lighter (static binary vs. full conda install) but the
  structure is the same.

### Best for
Someone who wants the bootstrap to be a normal software project —
importable library, composable pipelines, testable with pytest — and is
willing to accept pixi as a prerequisite for the full bootstrap.

---

## Approach E: Ansible Roles

**Idea:** Each component becomes an Ansible role. A playbook composes roles
for a given profile. Ansible runs locally (`ansible-playbook --connection=local`)
and handles idempotency through its module system. Ansible itself is installed
via pip/pipx/conda — no sudo required.

```yaml
# playbook.yml
- hosts: localhost
  roles:
    - role: mamba
    - role: system-env
      when: "'system-env' in profile"
    - role: dotfiles
    - role: sman
      when: "'personal' in profile"
    - role: ssh-dir
      when: "'personal' in profile"
```

**Boundary enforcement:** Ansible role boundaries. Roles communicate through
variables, not shared global state.

### Strengths
- Idempotency is Ansible's core design principle — every module is
  designed to be re-run safely.
- Roles are well-understood, testable units. `ansible-lint`, Molecule for
  testing.
- Profiles are just variable-driven `when` conditions — trivial to add.
- Multi-platform (macOS + Linux) with platform-specific task files.

### Weaknesses
- **Ansible needs Python.** Ansible itself is a Python package — no sudo
  needed (`pip install --user ansible`, or via mamba/pixi). But a bare
  system may not have Python at all, so a Stage 0 script must provide it
  first (via mamba or pixi). The dependency chain is: shell → mamba/pixi →
  Python → Ansible → playbook. This is heavier than pixi (single static
  binary) but not fundamentally different from the current mamba → task
  chain.
- **Heavy for the problem size.** Ansible shines at managing fleets of
  servers. For a single-user dotfile setup with <10 components, the YAML
  boilerplate and role directory structure is overhead.
- **Shell integration is indirect.** Sourcing `.zshenv` mid-bootstrap to
  pick up computed paths — the current system's strength — is awkward in
  Ansible. You're shelling out from YAML to do what a shell script does
  natively.
- **Doesn't solve the shell config split.** Like Approaches B and D, the
  `.zshenv`/`.zshrc` layering is orthogonal.
- **Loses standalone extraction.** You can't hand someone an Ansible role
  and say "run this" without them having Ansible.

### Best for
Someone managing multiple machines (personal laptop + several HPC clusters)
who wants fleet-style consistency guarantees and already has Ansible
experience.

---

## Comparison Matrix

Note: Approaches are **not mutually exclusive**. C (Chezmoi) operates on the
dotfiles layer only and can combine with any orchestration approach (A, B, D,
or E). The matrix evaluates each approach within its own scope.

| Criterion | A: Layered Split | B: Plugin Arch | C: Chezmoi (dotfiles) | D: Pixi | E: Ansible |
|-----------|:---:|:---:|:---:|:---:|:---:|
| **Scope** | All layers | Orchestration | Dotfiles only | Orchestration | All layers |
| Disruption to current system | Low | Medium | Medium (dotfiles repo) | Medium | High |
| Stage 0 dependency | None (pure shell) | None (pure shell) | curl (static binary) | curl (static binary) | Python (via mamba/pixi) |
| Requires sudo | No | No | No | No | No |
| Idempotency | Bolted on | First-class | Built in (for dotfiles) | First-class (in Python) | Built in |
| Boundary enforcement | Convention | Structure (descriptors) | Tool boundary (chezmoi=files, envoy=software) | Language (Python modules) | Role boundaries |
| Shell config decoupling | Directly addressed | Orthogonal | Addressed (templates) | Orthogonal | Orthogonal |
| Profile/public-mode support | Flag-based | Native (profile files) | Template conditionals | Native (pipeline scripts) | Variable-driven |
| Standalone script extraction | Preserved (compile system) | Lost | Preserved (envoy untouched) | Lost (mitigatable) | Lost |
| HPC cluster compatibility | High | High | High | Medium (no ppc64le binary) | Medium |
| Learning curve | Low | Low | Medium (Go templates) | Low (Python) | Medium |
| Scales to more components | Poorly | Well | N/A (dotfiles only) | Well | Well |
| Third-party reusability | Medium | High | Medium | High | Medium |
| Testability | Low (shell) | Low (shell) | Low | High (pytest) | Medium (Molecule) |
| Combinable with other approaches | — | Yes (any dotfile approach) | Yes (any orchestration approach) | Yes (C for dotfiles) | Yes (C for dotfiles) |

---

## Analysis

The approaches operate at two different levels, and recognizing this
matters more than ranking them linearly:

**Dotfiles layer** — how config files are managed, templated, and placed:
- A addresses this by splitting `.zshenv`/`.zshrc` into layered files
  across repos (convention-based).
- C addresses this by using chezmoi templates to generate
  machine-appropriate config from a single source (tool-enforced).

**Orchestration layer** — how the bootstrap sequence is structured and
how reusable/personal separation is enforced:
- A uses the existing compile system + shell monolith.
- B replaces the monolith with a shell plugin runner.
- D replaces it with pixi + Python library/pipeline.
- E replaces it with Ansible roles.

**A (Layered Split)** is the conservative choice. It addresses both layers
but with soft boundaries. The compile system and standalone scripts survive.
The risk is re-coupling over time.

**B (Plugin Architecture)** adds structural boundaries to orchestration
while staying in shell. For ~8 components, the plugin runner may be more
complex than the problem warrants. Loses standalone extraction unless the
compile system is kept alongside.

**C (Chezmoi for dotfiles)** solves dotfile management — templating,
idempotency, per-machine variation — without touching envoy's installer
infrastructure. The compile system and standalone scripts are unaffected.
The cost is restructuring the dotfiles repo (breaking the wholesale
`config/` symlink into individual files) and learning Go templates. It
combines naturally with D or B for orchestration.

**D (Pixi)** is the cleanest orchestration approach. Python's module
system provides real boundary enforcement and testability. The cost is
losing zero-dependency standalone scripts (mitigated by keeping envoy's
compile system) and no pixi binary for ppc64le.

**E (Ansible)** is over-specified for the problem. The role abstraction is
sound but the YAML indirection is heavy for what amounts to "run these
shell commands in order."

---

## Recommendation

The approaches are best evaluated as choices at two levels:

### Dotfiles layer: A (shell split) vs. C (chezmoi)

Both solve the shell config decoupling problem. The trade-off:

- **A** keeps everything in shell. Lower learning curve, no new tool. But
  the boundary between "bootstrap layer" and "personal layer" is a
  file-level convention that can drift.
- **C** uses chezmoi templates. The per-machine variation problem (HPC
  paths, cluster detection, personal aliases) is solved by a purpose-built
  tool rather than hand-rolled sourcing logic. Idempotency for dotfiles is
  free. The cost is restructuring the dotfiles repo and learning Go
  templates.

Either works. C is more upfront effort but a more durable boundary.

### Orchestration layer: keep compile system vs. D (pixi + Python)

- **Keeping the compile system** means no new orchestration dependency.
  Standalone scripts continue to work. The `bootstrap.sh` monolith stays,
  but with better-separated content (from whichever dotfiles approach is
  chosen). Profiles and public mode are added as flags.
- **D (pixi)** replaces the monolith with a Python package. Clean
  library/pipeline separation, testable, scales well. Standalone scripts
  are preserved by keeping envoy's compile system as a parallel fallback
  path for single-component installs and platforms where pixi has no
  binary (ppc64le, FreeBSD).

### Concrete combinations

**Minimal change (A only):** Split the shell configs, add `--public` flag,
harden idempotency. No new tools. Lowest risk, but soft boundaries.

**A + D:** Shell config split for the dotfiles content, pixi + Python for
orchestration. Envoy's compile system stays for standalone scripts.

**C + D:** Chezmoi for dotfiles, pixi + Python for orchestration. The
most structurally clean option but the most migration work. Both the
dotfiles repo and the bootstrap orchestration are rewritten.

**C + keep compile system:** Chezmoi for dotfiles, envoy's existing
`bootstrap.sh` for orchestration (with `--public` flag added). Moderate
change — dotfiles repo is restructured, but the installer side is
untouched.

The right combination depends on which pain point is sharper: the dotfile
management problem (→ prioritize C) or the orchestration/reusability
problem (→ prioritize D).

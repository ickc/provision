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

## Approach C: Chezmoi

**Idea:** Replace the dotfiles symlink approach with
[chezmoi](https://www.chezmoi.io/), a single static binary that manages
dotfiles with templates, scripts, and built-in state tracking.

Chezmoi bootstraps itself without sudo (`sh -c "$(curl -fsLS get.chezmoi.io)"`)
and installs to `$HOME/bin`. It manages files by maintaining a "source state"
(a directory of templates and scripts) and applying it to the home directory.

```
chezmoi-source/
  dot_zshenv.tmpl          # templated — adapts to OS/arch/host
  dot_zshrc.tmpl
  dot_config/               # replaces XDG_CONFIG_HOME symlinking
    git/config
    starship.toml
    ...
  run_onchange_install-mamba.sh.tmpl    # runs when hash changes
  run_onchange_install-system-env.sh.tmpl
  run_once_install-code.sh.tmpl         # runs once, tracked in state
  private_dot_ssh/                      # mode 0600 enforcement
```

`chezmoi apply` is inherently idempotent — it tracks what it has applied
and skips unchanged files. `run_onchange_` scripts re-execute only when
their content (or a hash marker in a comment) changes. `run_once_` scripts
execute exactly once per machine.

**Boundary enforcement:** Chezmoi's source state structure. Templates
naturally separate "what varies per machine" from "what is constant."
Personal vs. reusable is handled by chezmoi's external source feature or
by having the reusable scripts live in envoy and be called from `run_`
scripts.

### Strengths
- **No sudo, single static binary.** Same bootstrapping profile as pixi.
- **Idempotency is built in** — file-level state tracking, `run_once_`,
  `run_onchange_` semantics.
- **Template system replaces compile system** for machine-specific
  adaptation. Go `text/template` with `.chezmoidata` for variables (OS,
  arch, hostname, cluster).
- **Secret management** via age encryption — could handle SSH keys
  directly, potentially replacing the `ssh-dir` repo.
- **Dotfile management is the primary use case** — the tool is designed
  exactly for this problem.
- **Active ecosystem** with good documentation.

### Weaknesses
- **Dotfile-centric, not orchestration-centric.** The heavy install steps
  (mamba, conda envs, zim) are awkward as `run_` scripts. Chezmoi manages
  files well; managing multi-step software installation is a stretch of its
  design.
- **Opinionated about layout.** Migrating from the current dotfiles
  symlink-everything approach to chezmoi's source state model requires
  restructuring the entire dotfiles repo. The `config/` directory that is
  currently symlinked wholesale must be broken into individual files in
  chezmoi's source tree.
- **Go template syntax** is another thing to learn and maintain. It's less
  readable than the current shell-native approach for complex conditionals
  (HPC cluster detection, path overrides).
- **Loses standalone extraction.** Chezmoi's `run_` scripts are not
  standalone — they depend on chezmoi's execution context (template
  rendering, working directory, state tracking). You can't extract
  `code.sh` and hand it to someone who doesn't have chezmoi.
- **Shell config layering is only partially addressed.** Templates can
  generate different `.zshenv` content per machine, but the
  generic-vs-personal split within the shell logic is still a content
  problem that templates don't solve.
- **Overlap with existing compile system.** The compile system already
  solves composable script assembly. Chezmoi's templates solve a similar
  problem differently. Migrating means rewriting, not wrapping.

### Best for
Someone whose primary pain is dotfile management (templating for multiple
machines, secret handling) and who is willing to treat the installer
scripts as secondary `run_` hooks.

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
- **pixi platform coverage.** pixi supports Linux x86_64, Linux aarch64,
  macOS x86_64, macOS arm64. It does **not** support ppc64le or FreeBSD.
  The current system supports ppc64le (via mamba) and partially supports
  FreeBSD. Stage 0 would need a fallback for these platforms.
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
- **Ansible must be installed first.** It needs Python, which on a truly
  bare system may not exist. This is a heavier Stage 0 than pixi (which is
  a static binary). Installing Ansible via mamba creates the same
  chicken-and-egg as today, just with a different egg.
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

| Criterion | A: Layered Split | B: Plugin Arch | C: Chezmoi | D: Pixi | E: Ansible |
|-----------|:---:|:---:|:---:|:---:|:---:|
| Disruption to current system | Low | Medium | High | Medium | High |
| Stage 0 dependency | None (pure shell) | None (pure shell) | curl (static binary) | curl (static binary) | Python + pip |
| Requires sudo | No | No | No | No | No |
| Idempotency | Bolted on | First-class | Built in | First-class (in Python) | Built in |
| Boundary enforcement | Convention | Structure (descriptors) | File layout + templates | Language (Python modules) | Role boundaries |
| Shell config decoupling | Directly addressed | Orthogonal | Partial (templates) | Orthogonal | Orthogonal |
| Profile/public-mode support | Flag-based | Native (profile files) | Template conditionals | Native (pipeline scripts) | Variable-driven |
| Standalone script extraction | Preserved (compile system) | Lost | Lost | Lost (mitigatable) | Lost |
| HPC cluster compatibility | High | High | High | Medium (no ppc64le) | Medium |
| Learning curve | Low | Low | Medium (Go templates) | Low (Python) | Medium |
| Scales to more components | Poorly | Well | Moderately | Well | Well |
| Third-party reusability | Medium | High | Medium | High | Medium |
| Testability | Low (shell) | Low (shell) | Low | High (pytest) | Medium (Molecule) |

---

## Analysis

The approaches sit on a spectrum from "minimal change" to "full rewrite":

**A (Layered Split)** is the conservative choice. It solves the shell config
coupling directly — which is needed regardless — but leaves orchestration
as a monolithic shell script with soft boundaries. The compile system
survives, standalone scripts work, and no new dependencies are introduced.
The risk is re-coupling over time.

**B (Plugin Architecture)** adds structural boundaries to orchestration while
staying in shell. It's a good idea in theory, but for ~8 components the
plugin runner may be more complex than the problem warrants. And it doesn't
help with the shell config split or standalone extraction.

**C (Chezmoi)** solves dotfile management well but is a poor fit for
orchestrating software installation. The `run_` script model pushes complex
install logic into an awkward execution context. It would also require a
near-complete rewrite of the dotfiles repo. Most importantly, it kills
standalone extraction — the compile system's ability to produce `code.sh`
as a dependency-free script has no equivalent in chezmoi.

**D (Pixi)** is the most architecturally clean. Python's module system
provides real boundary enforcement, testability, and the
library-plus-pipeline separation maps directly to "reusable infrastructure
vs. personal choices." The cost is losing `bash code.sh install` as a
zero-dependency operation and dropping ppc64le platform support.

**E (Ansible)** is over-specified for the problem. The role abstraction is
well-designed but the YAML indirection is heavy for what amounts to "run
these shell commands in order." Shell integration is painful.

---

## Recommendation

No single approach covers everything. The best path combines elements:

### Primary: Approach A's shell config split + Approach D's pixi orchestration

1. **Start with A's Phase 1** — split `.zshenv`/`.zshrc` into bootstrap and
   personal layers. This is a content-level fix that every approach needs.

2. **Adopt pixi as the Stage 0 foundation** instead of mamba+task. Pixi is
   a lighter bootstrap (static binary vs. full conda install) and replaces
   both the task runner and the Python provider in one step.

3. **Write the orchestration as a Python package** against pixi's Python.
   Installers are library functions; personal bootstrap is a pipeline
   script. Third parties import the library and write their own pipeline.

4. **Keep the compile system in envoy for standalone scripts.** The shell
   lib/bin/state model continues to produce `code.sh`, `mamba.sh`, etc.
   for cases where someone needs a single tool without pixi. These are the
   "escape hatch" — the Python orchestrator is the primary path, the
   compiled scripts are the minimal-dependency fallback.

This means two implementations of each installer exist: one in
`envoy/install/src/lib/` (shell, for standalone use) and one in the Python
library (for orchestrated bootstrap). The shell versions already exist and
rarely change. The Python versions add value through composition, testing,
and clean separation — not by reimplementing the install logic, but by
calling the shell functions or reimplementing the simple ones (most are
just a curl + extract + move).

### Addressing the "pixi feels heavy for one thing" concern

The standalone shell scripts remain the answer for single-component
installs. `bash code.sh install` still works. Pixi is only needed when you
want the *orchestrated* bootstrap — profiles, dependency ordering, the full
pipeline. This is a reasonable trade: someone installing just the VS Code
CLI on a random server doesn't need profiles or dependency graphs; someone
bootstrapping a full environment can afford to install pixi first.

### Platform gap

For ppc64le (and FreeBSD), the compiled shell scripts are the only path.
The Python orchestrator can detect this at Stage 0 and fall back to the
shell bootstrap. This keeps the current platform coverage without
contorting the pixi-based system to support platforms pixi doesn't run on.

# Proposals

The bootstrap system solves one problem: turn a bare UNIX account into a working
personal environment. Every issue in ISSUES.md traces to a single root cause —
**"what to install" and "how to install" live in the same code.** Fixing that
separation is the entire game. Everything else (idempotency, public mode,
re-runnability) falls out naturally once the boundary is clean.

Below are four genuinely distinct approaches. They differ in where the boundary
lives and what enforces it.

---

## Approach A: Layered Shell Split (the ISSUES.md plan)

**Idea:** Keep the current shell-script architecture but refactor into layers.
Split `.zshenv`/`.zshrc` into a "bootstrap layer" (generic) and "personal layer."
Split `envoy` into `envoy` (generic installers) and `envoy-personal` (conda env
lists). Add a `--public` flag. Harden idempotency per-component.

**Boundary enforcement:** Convention. The split is a file-level agreement between
repos. Nothing prevents drift back toward coupling except discipline.

### Strengths
- Minimal disruption — every piece of existing code survives in some form.
- No new tooling dependencies. The bootstrap stays pure shell at Stage 0.
- The 5-phase plan is already designed and can be executed incrementally.

### Weaknesses
- The boundary is soft. Shell scripts that source each other have no interface
  contract; a new function in the bootstrap layer that references a personal
  variable re-creates the coupling silently.
- Five phases across six repos is a long migration. The intermediate states
  (phase 2 done, phase 3 not started) are themselves fragile configurations
  that need testing.
- Idempotency is bolted on per-component with ad-hoc logic rather than coming
  from an underlying model.
- The "compiled artifact" problem (bootstrap.sh assembled from fragments)
  persists unless explicitly addressed — the proposal doesn't eliminate it,
  just moves it.

### Best for
Someone who values continuity with the current system and wants to evolve
rather than replace.

---

## Approach B: Plugin Architecture

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
- The "compiled artifact" problem disappears — there's nothing to compile.

### Weaknesses
- Requires writing the plugin runner. It's small (~100-200 lines of shell)
  but it's new code that needs testing.
- The component descriptors need a format. If TOML/YAML, you need a parser
  available at Stage 0 (before mamba). Pure shell descriptors avoid this but
  are less readable.
- The `.zshenv`/`.zshrc` layering problem is orthogonal — this approach
  solves orchestration but doesn't automatically decouple the shell config.
  That split still needs to happen.
- Over-engineering risk: if there are only 6-8 components and they rarely
  change, the abstraction layer may cost more than it saves.

### Best for
Someone who wants a system that scales to more components and profiles
without proportional complexity growth.

---

## Approach C: Declarative with Nix Home-Manager

**Idea:** Replace the imperative install scripts with a declarative
specification. Nix Home-Manager lets you declare "I want these packages,
these dotfiles linked here, these shell options set" and it produces the
result atomically and reproducibly.

```nix
# home.nix (simplified)
{
  home.packages = [ pkgs.git pkgs.starship pkgs.helix pkgs.fzf ];
  programs.zsh = {
    enable = true;
    envExtra = builtins.readFile ./zshenv-bootstrap.sh;
    initExtra = builtins.readFile ./zshrc-personal.sh;
  };
  home.file.".ssh" = { source = ./ssh-dir; recursive = true; };
  xdg.configFile = { source = ./config; recursive = true; };
}
```

**Boundary enforcement:** The Nix language. Modules compose via well-defined
interfaces. Personal config is a module that imports the base module.

### Strengths
- Idempotency, rollback, and reproducibility are solved problems — Nix's
  core value proposition.
- The "what vs. how" separation is native: you declare what you want, Nix
  figures out how.
- Atomic generations mean a failed install doesn't leave a half-configured
  system.
- Dependency resolution is built in (Nix packages declare their own deps).
- Multi-platform: Nix runs on Linux and macOS.

### Weaknesses
- **Steep learning curve.** Nix has a notoriously difficult language and
  ecosystem. This is the dominant cost.
- **Nix must be installed first** — a new Stage 0 dependency. On some HPC
  clusters, installing Nix may not be possible (no root, restrictive
  filesystems).
- **Conda/mamba integration is awkward.** Nix has its own Python packaging;
  mixing Nix-managed packages with mamba-managed conda environments creates
  friction. The current system's mamba-centric approach would need to either
  move to Nix's Python or use Nix to manage mamba as an escape hatch.
- **Overkill for dotfile symlinks.** Much of what the current system does
  (symlink config dirs, source shell files) doesn't benefit from Nix's
  reproducibility guarantees.
- **FreeBSD is unsupported** by Nix. (Currently a partial-support platform
  anyway, but this closes the door entirely.)

### Best for
Someone who is already in the Nix ecosystem or wants maximal reproducibility
and is willing to pay the learning/migration cost.

---

## Approach D: Ansible Roles

**Idea:** Each component becomes an Ansible role. A playbook composes roles
for a given profile. Ansible runs locally (`ansible-playbook --connection=local`)
and handles idempotency through its module system.

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
- Large ecosystem of existing modules for package installation, file
  management, service configuration.
- Multi-platform (macOS + Linux) with platform-specific task files.

### Weaknesses
- **Ansible itself must be installed first** — another Stage 0 dependency.
  It requires Python, which on a truly bare system may not exist (though
  mamba could provide it, creating a two-stage bootstrap).
- **Heavy for the problem size.** Ansible shines at managing fleets of
  servers. For a single-user dotfile setup with <10 components, the YAML
  boilerplate and role directory structure may feel like overhead.
- **Shell integration is indirect.** The current system's strength is deep
  shell integration (sourcing `.zshenv` mid-bootstrap to pick up computed
  paths). Ansible's `shell` module can do this but it's awkward — you're
  shelling out from YAML to do what a shell script does natively.
- **Doesn't solve the shell config split.** Like Approach B, the
  `.zshenv`/`.zshrc` layering is orthogonal.

### Best for
Someone managing multiple machines (personal laptop + several HPC clusters)
who wants fleet-style consistency guarantees.

---

## Comparison Matrix

| Criterion | A: Layered Split | B: Plugin Arch | C: Nix | D: Ansible |
|-----------|:---:|:---:|:---:|:---:|
| Disruption to current system | Low | Medium | High | High |
| New dependencies at Stage 0 | None | None | Nix | Python+Ansible |
| Idempotency | Bolted on | First-class | Built in | Built in |
| Boundary enforcement | Convention | Structure | Language | Role boundaries |
| Shell config decoupling | Directly addressed | Orthogonal | Native | Orthogonal |
| Profile/public-mode support | Flag-based | Native | Module composition | Variable-driven |
| HPC cluster compatibility | High | High | Low | Medium |
| Learning curve | Low | Low | High | Medium |
| Scales to more components | Poorly | Well | Well | Well |
| Third-party reusability | Medium | High | High | Medium |

---

## Recommendation

**Approach B (Plugin Architecture)** hits the best balance for this project.

The core insight is that the current system has only ~8 components with
well-defined dependencies. The problem isn't that the install logic is
wrong — it's that the orchestration is monolithic. A plugin runner is the
minimum intervention that makes the boundary structural rather than
conventional, while keeping the install logic in shell where it's natural.

The practical path:

1. **Start with Approach A's shell config split** (Phase 1 from ISSUES.md).
   This is necessary regardless of orchestration approach — the `.zshenv`
   coupling is a content problem, not an orchestration problem.

2. **Build the plugin runner as Stage 1's replacement** for the compiled
   `bootstrap.sh`. Keep Stage 0 as plain shell (install mamba + system env).
   Once the task runner is available from system env, it discovers and
   executes component descriptors.

3. **Skip the intermediate repo proliferation.** Instead of creating
   `envoy-personal` as a separate repo immediately, start with a
   `components/` directory in this repo. Each component descriptor points
   to a submodule + install command. Splitting into separate repos can
   happen later if the boundary proves stable.

This avoids the two failure modes: Approach A's soft boundaries that invite
re-coupling, and Approach C/D's heavy dependencies that conflict with the
"bare system" constraint.

#!/usr/bin/env bash
# Bootstrap a personal UNIX environment.
#
# Self-contained: `curl | bash` works on a bare machine — the only external
# dependency is curl. Everything else is bootstrapped from micromamba:
#
#   micromamba  →  conda `system` env (pixi, git, gh, zsh, chezmoi, …)  →  the rest
#
# Because the `system` env brings pixi, the Python-based envoy installers are run
# via `pixi run` inside the envoy clone, which guarantees Python ≥ 3.10 from
# envoy's pixi env — no system Python of any version is required.
#
#   curl -fsSL https://raw.githubusercontent.com/ickc/provision/main/bootstrap.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/ickc/provision/main/bootstrap.sh | bash -s -- --public
#   bash bootstrap.sh [--public]                 # from a local clone
#   pixi run bootstrap[-public]                  # convenience wrappers
#
# Path 1 (default): SSH clones, ssh-dir → ~/.ssh, SSH key generated + registered.
# Path 2 (--public): HTTPS clones, no ssh-dir, no SSH key generation.
#
# --no-identity: path-1 provisioning without the interactive bits — generates the
# SSH key with an empty passphrase and skips `gh auth login`. CI=true implies it,
# so the personal path runs unattended (see `pixi run test-bootstrap`).

set -euo pipefail

# ── parse flags ───────────────────────────────────────────────────────────────
PUBLIC=0
NO_IDENTITY=0
for _a in "$@"; do
    case "${_a}" in
        --public)      PUBLIC=1 ;;
        --no-identity) NO_IDENTITY=1 ;;
    esac
done
# CI runners export CI=true; treat that as an implicit --no-identity so the
# personal path runs unattended (no passphrase prompt, no browser gh auth login).
[ "${CI:-}" = "true" ] && NO_IDENTITY=1

# ── helpers ───────────────────────────────────────────────────────────────────
title() { echo; echo "════════════════════════════════════════"; echo "  $*"; }

# sha256 of a file, portable across Linux (coreutils) and macOS (perl shasum).
sha256_of() {
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum "${1}" | cut -d' ' -f1
    elif command -v shasum > /dev/null 2>&1; then
        shasum -a 256 "${1}" | cut -d' ' -f1
    else
        echo "Need sha256sum (coreutils) or shasum (perl) to verify the system env lockfile." >&2
        return 1
    fi
}

# Hard-sync a repo to its remote default branch: fetch, then force the working
# tree onto origin's default branch (e.g. main). This intentionally:
#   • follows a renamed default branch — clones stuck on master move to main;
#   • discards local commits and uncommitted changes to TRACKED files (these are
#     managed runtime clones, not dev checkouts; the remote is the source of truth);
#   • leaves UNTRACKED files in place (e.g. private keys under ~/.ssh).
git_hard_sync() {
    local dest="${1}" url="${2}" branch
    if git -C "${dest}" remote get-url origin >/dev/null 2>&1; then
        git -C "${dest}" remote set-url origin "${url}"   # enforce ssh/https for the chosen path
    else
        git -C "${dest}" remote add origin "${url}"
    fi
    git -C "${dest}" fetch origin
    git -C "${dest}" remote set-head origin --auto         # refresh origin/HEAD → remote default
    branch="$(git -C "${dest}" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"
    branch="${branch#origin/}"
    : "${branch:=main}"                                    # fallback if HEAD can't be resolved
    git -C "${dest}" checkout -f -B "${branch}" "origin/${branch}"
}

# Clone if absent; hard-sync to the remote default branch if it already exists;
# init+sync if the dir exists but isn't a repo. The init+sync path overlays the
# repo's tracked files while leaving untracked files intact (e.g. a pre-existing
# ~/.ssh holding authorized_keys and per-machine private keys).
git_clone_or_pull() {
    local url="${1}" dest="${2}"
    if [ -d "${dest}" ] && git -C "${dest}" rev-parse --git-dir >/dev/null 2>&1; then
        git_hard_sync "${dest}" "${url}"
    elif [ -d "${dest}" ]; then
        git -C "${dest}" init -q
        git_hard_sync "${dest}" "${url}"
    else
        mkdir -p "${dest%/*}"
        git clone "${url}" "${dest}"
    fi
}

# ── stage 0: env setup ────────────────────────────────────────────────────────
title "Stage 0: env setup"

# Download env.sh temporarily to derive __OSTYPE/__ARCH, __OPT_ROOT,
# MAMBA_ROOT_PREFIX, XDG_DATA_HOME, etc. (it runs `uname -sm` for platform facts).
_tmpenv="$(mktemp)"
_tmpdir="$(mktemp -d)"   # holds the system env lockfile (needs a `-lock.yml` name — see Stage 1)
_known_hosts_tmp=""
trap 'rm -rf "${_tmpenv}" "${_tmpdir}" "${_known_hosts_tmp}"' EXIT
curl -fsSL "https://raw.githubusercontent.com/ickc/envoy/main/env.sh" -o "${_tmpenv}"
# shellcheck source=/dev/null
. "${_tmpenv}"
export PATH="${__OPT_ROOT}/bin:${__OPT_ROOT}/system/bin:${PATH}"
ENVOY_DIR="${XDG_DATA_HOME}/envoy"

# XDG_CONFIG_DIRS may contain invalid paths (e.g. a broken nix profile symlink pointing
# to a file instead of a directory). Filter to actual directories so tools like chezmoi
# don't error when scanning the list.
if [ -n "${XDG_CONFIG_DIRS:-}" ]; then
    _xdg_filtered=""
    _IFS_SAVE="${IFS}"; IFS=:
    for _xdg_d in ${XDG_CONFIG_DIRS}; do
        [ -d "${_xdg_d}" ] && _xdg_filtered="${_xdg_filtered:+${_xdg_filtered}:}${_xdg_d}"
    done
    IFS="${_IFS_SAVE}"
    export XDG_CONFIG_DIRS="${_xdg_filtered}"
    unset _xdg_filtered _xdg_d _IFS_SAVE
fi

# ── stage 1: micromamba + system env ──────────────────────────────────────────
title "Stage 1: micromamba + system env"

# Guard on the platforms system-lock.yml is solved for (linux-64, linux-aarch64,
# osx-64, osx-arm64), keyed on the very `uname -sm` facts env.sh exported. Anywhere
# else micromamba would find no packages for the subdir and create an EMPTY env
# rather than fail, so refuse up front.
case "${__OSTYPE}-${__ARCH}" in
    Linux-x86_64 | Linux-aarch64 | Darwin-arm64 | Darwin-x86_64) ;;
    *) echo "Unsupported platform: ${__OSTYPE}-${__ARCH}" >&2; exit 1 ;;
esac

# Below, a stale `system` env is `rm -rf`'d before being recreated — the only
# destructive step in the bootstrap. env.sh honours a pre-set __OPT_ROOT, so a
# stray value ("" or "/") would aim that at /system. Refuse anything that isn't
# an absolute path below the root.
case "${__OPT_ROOT:-}" in
    /) echo "Refusing __OPT_ROOT=/ — it must be a directory below the root." >&2; exit 1 ;;
    /?*) ;;
    *) echo "Refusing non-absolute __OPT_ROOT='${__OPT_ROOT:-}'." >&2; exit 1 ;;
esac

# Install the micromamba static binary to $__OPT_ROOT/bin — exactly where envoy's
# own micromamba.py would place it. The upstream installer honours a pre-set
# BIN_FOLDER (it only prompts when stdin is a tty); INIT_YES / CONDA_FORGE_YES = no
# keep it side-effect-free (no shell-rc edits, no ~/.mambarc). </dev/null guarantees
# it never blocks on a prompt.
MICROMAMBA="${__OPT_ROOT}/bin/micromamba"
if [ ! -x "${MICROMAMBA}" ]; then
    mkdir -p "${__OPT_ROOT}/bin"
    BIN_FOLDER="${__OPT_ROOT}/bin" INIT_YES="no" CONDA_FORGE_YES="no" \
        bash <(curl -fsSL https://micro.mamba.pm/install.sh) </dev/null
fi

# Create the conda `system` env at $__OPT_ROOT/system straight from envoy's
# published lockfile — no envoy clone needed yet. This is the moment pixi,
# git, gh, zsh, chezmoi, … come into existence; every later stage assumes them.
# MAMBA_ROOT_PREFIX (exported by env.sh) is micromamba's package cache.
#
# The spec is envoy's version-pinned multi-platform conda-lock file. The local
# copy MUST keep the `-lock.yml` suffix — that suffix (not content sniffing) is
# how micromamba recognizes a conda-lock file; misnamed, it would silently
# create an EMPTY env. `env update` cannot consume conda-lock files (libmamba
# fails re-solving exact-pin specs), so an out-of-date env is removed and
# recreated instead — the lock pins every package, so recreation converges
# exactly, and the files are re-hardlinked from the package cache rather than
# rewritten. The sha256 stamp is the same file envoy's mamba_env.py writes and
# reads, so an unchanged lockfile is a no-op here *and* in a later
# `mamba_env update`: re-running the bootstrap does not touch the env at all.
_syslock="${_tmpdir}/system-lock.yml"
_sysstamp="${__OPT_ROOT}/system/conda-meta/.bsos-lock-sha256"
curl -fsSL "https://raw.githubusercontent.com/ickc/envoy/main/conda/system-lock.yml" -o "${_syslock}"
_lockhash="$(sha256_of "${_syslock}")"
if [ -f "${_sysstamp}" ] && [ "$(cat "${_sysstamp}")" = "${_lockhash}" ]; then
    echo "system env already matches system-lock.yml; skipping"
else
    rm -rf "${__OPT_ROOT}/system"
    "${MICROMAMBA}" env create -y -p "${__OPT_ROOT}/system" -f "${_syslock}"
    printf '%s\n' "${_lockhash}" > "${_sysstamp}"
fi

# ── stage 2: envoy + remaining tools ──────────────────────────────────────────
title "Stage 2: envoy + remaining tools"

# StrictHostKeyChecking=accept-new covers the window before ssh-dir provides known_hosts.
# Write accepted keys to a throwaway file, NOT ~/.ssh/known_hosts: Stage 3 clones ssh-dir
# directly into ~/.ssh, and git refuses to clone into a non-empty directory.
_known_hosts_tmp="$(mktemp)"
export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${_known_hosts_tmp}"

if [ "${PUBLIC}" = "1" ]; then
    git_clone_or_pull "https://github.com/ickc/envoy.git" "${ENVOY_DIR}"
else
    git_clone_or_pull "git@github.com:ickc/envoy.git" "${ENVOY_DIR}"
fi
# Re-source env.sh from the cloned repo (canonical copy going forward).
# shellcheck source=/dev/null
. "${ENVOY_DIR}/env.sh"

# code (VS Code CLI) and sman aren't conda-forge packages, so they stay envoy
# Python installers. Run them through envoy's pixi env to guarantee Python ≥ 3.10
# — micromamba, the system env, pixi and chezmoi already exist (Stage 1), so they
# are no longer installed here. `update` forces a refresh on re-runs.
( cd "${ENVOY_DIR}" && pixi run python -m bsos.installers update code sman )

# ── stage 3: dotfiles + data repos ────────────────────────────────────────────
title "Stage 3: dotfiles + data repos"

if [ "${PUBLIC}" = "1" ]; then
    chezmoi init --apply ickc/dotfiles
    git_clone_or_pull "https://github.com/ickc/sman-snippets.git"    "${XDG_DATA_HOME}/sman/snippets"
    git_clone_or_pull "https://github.com/ickc/navi-cheatsheets.git" "${XDG_DATA_HOME}/navi/cheats"
else
    chezmoi init --apply "git@github.com:ickc/dotfiles.git"
    git_clone_or_pull "git@github.com:ickc/sman-snippets.git"    "${XDG_DATA_HOME}/sman/snippets"
    git_clone_or_pull "git@github.com:ickc/navi-cheatsheets.git" "${XDG_DATA_HOME}/navi/cheats"
    git_clone_or_pull "git@github.com:ickc/ssh-dir.git"          "${HOME}/.ssh"
    if [ -f "${HOME}/.ssh/makefile" ]; then
        make -C "${HOME}/.ssh" permission || echo "WARNING: 'make permission' failed; check ~/.ssh permissions manually." >&2
    fi
fi

# ── stage 4: machine SSH identity (path 1 only) ───────────────────────────────
if [ "${PUBLIC}" = "0" ]; then
    title "Stage 4: machine SSH identity"

    _ssh_key="${HOME}/.ssh/id_ed25519"
    if [ -f "${_ssh_key}" ]; then
        echo "${_ssh_key} already exists; skipping keygen."
    elif [ "${NO_IDENTITY}" = "1" ]; then
        # Non-interactive (CI / throwaway machines): empty passphrase, no prompt.
        ssh-keygen -t ed25519 -C "${USER}@$(hostname)" -N '' -f "${_ssh_key}"
    else
        ssh-keygen -t ed25519 -C "${USER}@$(hostname)" -f "${_ssh_key}"
    fi

    # Register pubkey with GitHub (interactive browser flow). --no-identity skips
    # this irreproducible, account-touching step so the personal path stays testable.
    if [ "${NO_IDENTITY}" = "1" ]; then
        echo "--no-identity: skipping 'gh auth login'. Register this key later with:"
        echo "  gh auth login --git-protocol ssh --web   # then: gh ssh-key add ${_ssh_key}.pub"
    elif "${__OPT_ROOT}/system/bin/gh" auth status &>/dev/null; then
        echo "gh: already authenticated; skipping 'gh auth login'."
    else
        "${__OPT_ROOT}/system/bin/gh" auth login --git-protocol ssh --web || true
    fi
fi

# ── final: generate shell completions ─────────────────────────────────────────
title "Final: generate shell completions"
( cd "${ENVOY_DIR}" && pixi run generate-completions )

title "Bootstrap complete."

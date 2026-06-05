#!/usr/bin/env bash
# Bootstrap a personal UNIX environment.
#
# Recommended usage (guarantees Python ≥ 3.10 via the pixi environment):
#   git clone git@github.com:ickc/provision.git /tmp/provision
#   cd /tmp/provision && pixi run bootstrap          # personal (SSH)
#   cd /tmp/provision && pixi run bootstrap-public   # public (HTTPS)
#
# Direct invocation (requires Python ≥ 3.10 on PATH):
#   bash bootstrap.sh [--public]
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

# Clone if absent; pull if already a git repo; init+fetch if dir exists but isn't a repo.
git_clone_or_pull() {
    local url="${1}" dest="${2}"
    if [ -d "${dest}" ] && git -C "${dest}" rev-parse --git-dir >/dev/null 2>&1; then
        git -C "${dest}" pull
    elif [ -d "${dest}" ]; then
        # Directory exists but is not a git repo (e.g. pre-existing ~/.ssh with authorized_keys).
        # git init + reset overlays tracked files while leaving untracked files (private keys) intact.
        git -C "${dest}" init
        git -C "${dest}" remote add origin "${url}"
        git -C "${dest}" fetch origin
        git -C "${dest}" remote set-head origin --auto
        git -C "${dest}" reset --hard origin/HEAD
    else
        mkdir -p "${dest%/*}"
        git clone "${url}" "${dest}"
    fi
}

# Install a single envoy tool (idempotent: prints "already installed" if present).
envoy_install() {
    python3 "${ENVOY_DIR}/install/${1}.py" install "${@:2}"
}

# ── stage 0: env setup ────────────────────────────────────────────────────────
title "Stage 0: env setup"

# Download env.sh temporarily to derive __OPT_ROOT, PIXI_HOME, XDG_DATA_HOME, etc.
# This is the only bootstrap download before envoy is cloned in Stage 1.
_tmpenv="$(mktemp)"
trap 'rm -f "${_tmpenv}"' EXIT
curl -fsSL "https://raw.githubusercontent.com/ickc/envoy/main/env.sh" -o "${_tmpenv}"
# shellcheck source=/dev/null
. "${_tmpenv}"
export PATH="${__OPT_ROOT}/bin:${__OPT_ROOT}/system/bin:${PIXI_HOME}/bin:${PATH}"
ENVOY_DIR="${XDG_DATA_HOME}/envoy"

# Install pixi; PIXI_HOME is already set by env.sh; PIXI_NO_PATH_UPDATE skips rc-file edits.
if [ ! -x "${PIXI_HOME}/bin/pixi" ]; then
    PIXI_NO_PATH_UPDATE=1 curl -fsSL https://pixi.sh/install.sh | sh
fi

# ── verify python ────────────────────────────────────────────────────────────
# Envoy installers require Python ≥ 3.10 (stdlib-only, but uses modern syntax).
# When invoked via `pixi run bootstrap` the project env supplies the right
# python3 automatically.  Fail fast here rather than getting a cryptic syntax
# error deep in an installer.
if ! python3 - <<'EOF'
import sys, textwrap
if sys.version_info < (3, 10):
    print(textwrap.dedent(f"""\
        ERROR: python3 {sys.version} is too old (need ≥ 3.10).
        Run via the pixi project to get the right Python:
          git clone git@github.com:ickc/provision.git /tmp/provision
          cd /tmp/provision && pixi run bootstrap          # personal (SSH)
          cd /tmp/provision && pixi run bootstrap-public   # public (HTTPS)
        """), file=sys.stderr)
    sys.exit(1)
EOF
then
    exit 1
fi

# ── stage 1: envoy + tools ────────────────────────────────────────────────────
title "Stage 1: envoy + tools"

# StrictHostKeyChecking=accept-new covers the window before ssh-dir provides known_hosts.
# Write accepted keys to a throwaway file, NOT ~/.ssh/known_hosts: Stage 2 clones ssh-dir
# directly into ~/.ssh, and git refuses to clone into a non-empty directory.
_known_hosts_tmp="$(mktemp)"
trap 'rm -f "${_tmpenv}" "${_known_hosts_tmp}"' EXIT
export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${_known_hosts_tmp}"

if [ "${PUBLIC}" = "1" ]; then
    git_clone_or_pull "https://github.com/ickc/envoy.git" "${ENVOY_DIR}"
else
    git_clone_or_pull "git@github.com:ickc/envoy.git" "${ENVOY_DIR}"
fi
# Re-source env.sh from the cloned repo (canonical copy going forward).
# shellcheck source=/dev/null
. "${ENVOY_DIR}/env.sh"

envoy_install mamba
envoy_install mamba_env --name system   # provides gh, git, zsh, navi, direnv, starship
envoy_install zim
envoy_install code
envoy_install chezmoi
envoy_install sman

# ── stage 2: dotfiles + data repos ────────────────────────────────────────────
title "Stage 2: dotfiles + data repos"

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

# ── stage 3: machine SSH identity (path 1 only) ───────────────────────────────
if [ "${PUBLIC}" = "0" ]; then
    title "Stage 3: machine SSH identity"

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
    else
        "${__OPT_ROOT}/system/bin/gh" auth login --git-protocol ssh --web || true
    fi
fi

# ── final: generate shell completions ─────────────────────────────────────────
title "Final: generate shell completions"
PYTHONPATH="${ENVOY_DIR}/src" python3 -m bsos.shell.completion generate

title "Bootstrap complete."

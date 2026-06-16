#!/usr/bin/env bash
# Smoke-test a completed bootstrap: assert the environment a fresh bootstrap.sh
# run is expected to produce. Runs against the *current* machine — invoke right
# after `pixi run bootstrap[-public]`, or as the CI step following the bootstrap.
#
#   bash test/smoke.sh            # path 1 (personal): also checks SSH key + ssh-dir
#   bash test/smoke.sh --public   # path 2 (public):   skips SSH/identity checks
#
# Every assertion runs (no fail-fast); exit status is non-zero if any failed.

set -uo pipefail   # deliberately NOT -e: one failed check must not abort the rest.

PUBLIC=0
for _a in "$@"; do [ "${_a}" = "--public" ] && PUBLIC=1; done

# ── derive paths from the canonical env.sh the bootstrap installed ─────────────
# env.sh respects pre-existing values, so an already-set XDG_DATA_HOME is honoured;
# otherwise it defaults to ~/.local/share — the same path the bootstrap cloned into.
ENVOY_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/envoy"
if [ ! -f "${ENVOY_DIR}/env.sh" ]; then
    echo "FATAL: ${ENVOY_DIR}/env.sh not found — has the bootstrap run?" >&2
    exit 1
fi
# shellcheck source=/dev/null
. "${ENVOY_DIR}/env.sh"

SYSTEM_BIN="${__OPT_ROOT}/system/bin"   # the `system` env (gh, git, task, zsh, …)
# Reconstruct the PATH a provisioned login shell gets; a bare CI shell has none of it.
# micromamba is a single binary in ${__OPT_ROOT}/bin (first below); the root prefix
# holds only pkgs/envs, so it is not on PATH.
export PATH="${__OPT_ROOT}/bin:${SYSTEM_BIN}:${PIXI_HOME}/bin:${PATH}"

# ── assertion harness ─────────────────────────────────────────────────────────
_pass=0
_fail=0
check() {  # check "<description>" <command> [args…]
    local desc="${1}"
    shift
    if "$@" >/dev/null 2>&1; then
        printf '  ok   %s\n' "${desc}"
        _pass=$((_pass + 1))
    else
        printf '  FAIL %s\n' "${desc}"
        _fail=$((_fail + 1))
    fi
}

_mode() { stat -c '%a' "${1}" 2>/dev/null || stat -f '%Lp' "${1}" 2>/dev/null; }  # octal, Linux|macOS
is_mode() { [ "$(_mode "${1}")" = "${2}" ]; }
nonempty_dir() { [ -d "${1}" ] && [ -n "$(ls -A "${1}" 2>/dev/null)" ]; }
envoy_test() { python3 "${ENVOY_DIR}/install/${1}.py" test; }

echo "== core toolchain =="
check "pixi functional"  pixi --version
check "micromamba functional" "${__OPT_ROOT}/bin/micromamba" --version

echo "== envoy installers self-test =="
# Only the tools bootstrap.sh Stage 1 actually installs — envoy also ships
# clifton/codex/gh/mamba/pixi installers, but the bootstrap does not run those.
for _t in micromamba mamba_env code chezmoi sman; do
    check "envoy: ${_t}" envoy_test "${_t}"
done

echo "== system conda env =="
for _t in git gh task zsh navi starship direnv; do
    check "system: ${_t}" test -x "${SYSTEM_BIN}/${_t}"
done
check "git --version"  "${SYSTEM_BIN}/git" --version
check "task --version" "${SYSTEM_BIN}/task" --version

echo "== dotfiles (chezmoi) =="
check "config dir exists"           test -d "${HOME}/.config"
check "config dir is not a symlink" test ! -L "${HOME}/.config"
check "config dir is non-empty"     nonempty_dir "${HOME}/.config"

echo "== data repos =="
check "sman snippets cloned" test -d "${XDG_DATA_HOME}/sman/snippets/.git"
check "navi cheats cloned"   test -d "${XDG_DATA_HOME}/navi/cheats/.git"

echo "== shell completions =="
check "zsh functions populated" nonempty_dir "${XDG_DATA_HOME}/zsh/functions"

if [ "${PUBLIC}" = "0" ]; then
    echo "== machine identity (path 1) =="
    _key="${HOME}/.ssh/id_ed25519"
    check "ssh key exists"    test -f "${_key}"
    check "ssh key perms 600" is_mode "${_key}" 600
    check "ssh-dir cloned"    test -d "${HOME}/.ssh/.git"
fi

echo
if [ "${_fail}" -gt 0 ]; then
    echo "SMOKE FAILED: ${_fail} failed, ${_pass} passed."
    exit 1
fi
echo "SMOKE OK: ${_pass} passed."

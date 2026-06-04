#!/usr/bin/env sh
# Stage 0: install pixi, clone bootstrap repo, hand off to `pixi run bootstrap`.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ickc/bootstrap/main/bootstrap.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/ickc/bootstrap/main/bootstrap.sh | bash -s -- --public
set -eu

BOOTSTRAP_REPO="ickc/bootstrap"
XDG_DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}"
BOOTSTRAP_DEST="${XDG_DATA_HOME}/bootstrap"

# Parse --public flag (remaining args forwarded to pixi run bootstrap below)
PUBLIC=0
for _arg in "$@"; do
    [ "${_arg}" = "--public" ] && PUBLIC=1
done
unset _arg

# Install pixi if not already in PATH
if ! command -v pixi > /dev/null 2>&1; then
    curl -fsSL https://pixi.sh/install.sh | bash
    # The official installer adds ~/.pixi/bin to PATH in shell init files but
    # not to the current process; add it now.
    export PATH="${HOME}/.pixi/bin:${PATH}"
fi

# Clone or update this bootstrap repo
if [ -d "${BOOTSTRAP_DEST}/.git" ]; then
    git -C "${BOOTSTRAP_DEST}" pull
else
    mkdir -p "${XDG_DATA_HOME}"
    if [ "${PUBLIC}" = "1" ]; then
        git clone "https://github.com/${BOOTSTRAP_REPO}.git" "${BOOTSTRAP_DEST}"
    else
        # Assumes SSH agent forwarding is active; accept-new because known_hosts
        # is not yet populated from ssh-dir (that happens in Stage 2).
        GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new" \
            git clone "git@github.com:${BOOTSTRAP_REPO}.git" "${BOOTSTRAP_DEST}"
    fi
fi

# Hand off to pixi; pass original args through
cd "${BOOTSTRAP_DEST}"
if [ "${PUBLIC}" = "1" ]; then
    pixi run bootstrap-public
else
    pixi run bootstrap
fi

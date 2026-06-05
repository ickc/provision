#!/usr/bin/env bash
# Migrate from legacy bootstrap (~/git/source/ layout) to the current one.
#
# What this does:
#   1. Moves ~/git/source/envoy        → $XDG_DATA_HOME/envoy
#   2. Moves ~/git/source/dotfiles     → $XDG_DATA_HOME/chezmoi  (chezmoi source dir)
#   3. Moves ~/git/source/sman-snippets → $XDG_DATA_HOME/sman/snippets
#   4. Removes broken symlinks at $HOME  (legacy dotfiles' "make all" created them;
#      chezmoi will re-create them correctly on the next bootstrap run)
#
# Each move is skipped if the source does not exist or the destination already exists.
# After running this script, run bootstrap.sh to complete the migration:
#   bash bootstrap.sh [--public]

set -euo pipefail

# Derive paths the same way envoy/env.sh does (without sourcing it).
read -r __OSTYPE __ARCH <<< "$(uname -sm)"
__LOCAL_ROOT="${__LOCAL_ROOT:-${HOME}/.local}"
XDG_DATA_HOME="${XDG_DATA_HOME:-${__LOCAL_ROOT}/share}"

# ── helpers ───────────────────────────────────────────────────────────────────
# Move a git repo from $1 to $2; skip if source absent or dest already exists.
move_repo() {
    local src="${1}" dst="${2}"
    if [ ! -d "${src}/.git" ]; then
        echo "INFO: ${src} not found or not a git repo; skipping."
    elif [ -d "${dst}" ]; then
        echo "INFO: ${dst} already exists; skipping move of ${src}."
    else
        echo "Moving ${src} → ${dst}"
        mkdir -p "${dst%/*}"
        mv "${src}" "${dst}"
    fi
}

# ── 1. move legacy git repos ──────────────────────────────────────────────────
move_repo "${HOME}/git/source/envoy"         "${XDG_DATA_HOME}/envoy"
move_repo "${HOME}/git/source/dotfiles"      "${XDG_DATA_HOME}/chezmoi"
move_repo "${HOME}/git/source/sman-snippets" "${XDG_DATA_HOME}/sman/snippets"

# ── 2. remove broken symlinks at HOME ─────────────────────────────────────────
echo "Scanning ${HOME} for broken symlinks..."
_removed=0
while IFS= read -r link; do
    if [ ! -e "${link}" ]; then
        echo "Removing broken symlink: ${link}"
        rm "${link}"
        _removed=$((_removed + 1))
    fi
done < <(find "${HOME}" -maxdepth 1 -type l)
echo "Removed ${_removed} broken symlink(s)."

echo
echo "Migration complete. Now run: bash bootstrap.sh"

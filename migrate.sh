#!/usr/bin/env bash
# Migrate from legacy bootstrap (~/git/source/ layout) to the current one.
#
# What this does:
#   1. Moves ~/git/source/envoy        → $XDG_DATA_HOME/envoy
#   2. Moves ~/git/source/dotfiles     → $XDG_DATA_HOME/chezmoi  (chezmoi source dir)
#   3. Moves ~/git/source/sman-snippets → $XDG_DATA_HOME/sman/snippets
#   4. Hard-syncs the chezmoi source onto its remote default branch — a legacy clone
#      stuck on master moves to main, and local changes to tracked files are discarded.
#      bootstrap.sh does this for the repos it manages, but the chezmoi source is owned
#      by chezmoi, whose plain `git pull` would otherwise leave it stuck.
#   5. Removes broken symlinks at $HOME  (legacy dotfiles' "make all" created them;
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

# Hard-sync a repo to its remote default branch using its existing origin: fetch,
# then force the working tree onto origin's default (master→main included). Discards
# local commits and uncommitted changes to TRACKED files; leaves untracked files
# alone. Best-effort — warns and continues rather than aborting the migration.
hard_sync_to_default() {
    local dir="${1}" branch
    if ! git -C "${dir}" rev-parse --git-dir >/dev/null 2>&1; then
        echo "INFO: ${dir} not found or not a git repo; skipping hard-sync."
        return 0
    fi
    if ! git -C "${dir}" remote get-url origin >/dev/null 2>&1; then
        echo "INFO: ${dir} has no 'origin' remote; skipping hard-sync."
        return 0
    fi
    echo "Hard-syncing ${dir} to its remote default branch..."
    if ! git -C "${dir}" fetch origin; then
        echo "WARNING: fetch failed for ${dir}; leaving it as-is." >&2
        return 0
    fi
    git -C "${dir}" remote set-head origin --auto || true
    branch="$(git -C "${dir}" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)"
    branch="${branch#origin/}"
    : "${branch:=main}"   # fallback if HEAD can't be resolved
    if git -C "${dir}" checkout -f -B "${branch}" "origin/${branch}"; then
        echo "  ${dir} now on ${branch}."
    else
        echo "WARNING: could not check out ${branch} in ${dir}." >&2
    fi
}

# ── 1. move legacy git repos ──────────────────────────────────────────────────
move_repo "${HOME}/git/source/envoy"         "${XDG_DATA_HOME}/envoy"
move_repo "${HOME}/git/source/dotfiles"      "${XDG_DATA_HOME}/chezmoi"
move_repo "${HOME}/git/source/sman-snippets" "${XDG_DATA_HOME}/sman/snippets"

# ── 2. hard-sync the migrated chezmoi source onto its default branch ───────────
# chezmoi owns this repo from here on, and its plain `git pull` would leave a legacy
# clone stuck on master (or refuse to update a dirty tree). One-time fix so the next
# `chezmoi init --apply` starts clean on main. The repos bootstrap.sh manages (envoy,
# sman-snippets, navi-cheats, ssh-dir) are hard-synced there on every run instead.
hard_sync_to_default "${XDG_DATA_HOME}/chezmoi"

# ── 3. remove broken symlinks at HOME ─────────────────────────────────────────
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

#!/bin/bash
# build_ios.sh — sync the project from the Windows drive to a WSL-native
# mirror and build the iOS app there.
#
# Why: SwiftPM's explicit-module build (clang dependency scanning, shared
# module cache) races when run on /mnt/c — the NTFS mount lacks reliable
# atomic-file semantics, producing "module 'X' is defined in both <pcm> and
# <pcm>" failures. The ext4-native filesystem is reliable and much faster.
#
# Usage (from Windows): wsl.exe -d Ubuntu-xtool --exec bash /mnt/c/Users/Bhargav/Documents/XTermux/build_ios.sh
# Source of truth stays on C:\Users\Bhargav\Documents\XTermux; this mirror
# is build-only.

set -e

# `wsl --exec bash <script>` skips profile loading, so the swiftly-managed
# Swift toolchain is not on PATH yet — source its environment explicitly.
[ -f "$HOME/.local/share/swiftly/env.sh" ] && . "$HOME/.local/share/swiftly/env.sh"
command -v swift >/dev/null || { echo "error: swift not on PATH (swiftly env missing?)"; exit 1; }

SRC=/mnt/c/Users/Bhargav/Documents/XTermux
DST="$HOME/xtermux-build"

mkdir -p "$DST"
rsync -a --delete \
    --exclude ".build" \
    --exclude ".bsp" \
    --exclude "xtool/" \
    --exclude ".git" \
    --exclude "build_ios.sh" \
    "$SRC/" "$DST/"

cd "$DST"

# First-time or corrective builds may need a clean re-plan: the llbuild
# description on disk references explicit-module artifacts (.scan files), so
# deleting module caches alone leaves dangling references ("Failed to query
# serialized dependencies ... No such file or directory"). Run with WIPE=1 to
# force a full re-build (~10-15 min). Plain source edits rebuild incrementally.
if [ "${WIPE:-0}" = "1" ]; then
    rm -rf .build/out
fi

exec xtool dev build "$@"

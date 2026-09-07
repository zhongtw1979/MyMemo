#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/mymemo-guided-module-cache"
export SWIFT_MODULECACHE_PATH="$CLANG_MODULE_CACHE_PATH"
action="${1:-build}"
if [ "$#" -gt 0 ]; then shift; fi
workspace_key=$(printf '%s' "$PWD" | /usr/bin/shasum | /usr/bin/cut -c1-12)
build_root="${TMPDIR:-/tmp}/mymemo-guided-$workspace_key"
mkdir -p "$build_root/source"
# Build a stable local snapshot: iCloud can change source mtimes during hydration.
/usr/bin/rsync -a --delete Package.swift Sources Tests "$build_root/source/"
printf '%s\n' "$build_root/build" > .build-location
exec /usr/bin/xcrun swift "$action" --disable-sandbox \
 --package-path "$build_root/source" \
 --cache-path "${TMPDIR:-/tmp}/mymemo-guided-spm-cache" \
 --config-path "${TMPDIR:-/tmp}/mymemo-guided-spm-config" \
 --security-path "${TMPDIR:-/tmp}/mymemo-guided-spm-security" \
 --scratch-path "$build_root/build" "$@"

#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
configuration="${1:-release}"
if [[ "$configuration" != "release" && "$configuration" != "debug" ]]; then
    print -u2 'Usage: ./scripts/package-app.sh [release|debug] [absolute-app-path]'
    exit 2
fi
cd "$project_root"
export CLANG_MODULE_CACHE_PATH="$project_root/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_root/.build/module-cache"
swift build --disable-sandbox -c "$configuration"
binary_directory="$(swift build --disable-sandbox -c "$configuration" --show-bin-path)"
app_directory="${2:-$project_root/build/Find Yoshi IT.app}"
if [[ "$app_directory" != /* || "$app_directory" != *.app ]]; then
    print -u2 'The destination must be an absolute path ending in .app.'
    exit 2
fi
mkdir -p "$project_root/build"
# Sign outside FileProvider-managed Documents folders; providers can attach FinderInfo mid-sign.
staging_directory="$(mktemp -d "${TMPDIR:-/tmp}/FindAnything-package.XXXXXX")"
trap 'rm -rf "$staging_directory"' EXIT
staged_app="$staging_directory/Find Yoshi IT.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
cp "$binary_directory/FindYoshiIT" "$staged_app/Contents/MacOS/FindYoshiIT"
cp "$project_root/scripts/Info.plist" "$staged_app/Contents/Info.plist"
swift "$project_root/scripts/generate-icon.swift" "$staging_directory"
cp "$staging_directory/AppIcon.icns" "$staged_app/Contents/Resources/AppIcon.icns"
xattr -dr com.apple.FinderInfo "$staged_app" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$staged_app" 2>/dev/null || true
codesign --force --deep --sign - "$staged_app"
xattr -dr com.apple.FinderInfo "$staged_app" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$staged_app" 2>/dev/null || true
codesign --verify --deep --strict "$staged_app"
# Never overwrite a running signed executable. Retain its inode in a rollback bundle.
if [[ -d "$app_directory" ]]; then
    previous_directory="$project_root/build/previous/$(uuidgen)"
    mkdir -p "$previous_directory"
    mv "$app_directory" "$previous_directory/Find Yoshi IT.app"
fi
mkdir -p "${app_directory:h}"
mv "$staged_app" "$app_directory"
print "Built: $app_directory"
print "Launch: open '$app_directory'"

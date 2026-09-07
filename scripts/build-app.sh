#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/swift.sh build -c release
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
architecture=$(/usr/bin/uname -m)
bundle_name="MyMemo 引导版 $version.app"
build_dir=$(cat .build-location)
staging=$(mktemp -d "${TMPDIR:-/tmp}/mymemo-app.XXXXXX")
trap 'rm -rf "$staging"' EXIT
app="$staging/$bundle_name"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" dist
cp "$build_dir/release/MyMemoGuided" "$app/Contents/MacOS/MyMemoGuided"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
cp LICENSE "$app/Contents/Resources/LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
# Sign a fresh local staging bundle, avoiding Finder/iCloud metadata on old output.
/usr/bin/xattr -cr "$app"
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --deep --strict "$app"
archive="MyMemo-Guided-$version-macOS-$architecture.zip"
/usr/bin/ditto --noextattr --norsrc -c -k --keepParent "$app" "dist/$archive"
/usr/bin/ditto --noextattr --norsrc "$app" "dist/$bundle_name"
(cd dist && /usr/bin/shasum -a 256 "$archive" > SHA256SUMS)
printf 'Created: dist/%s\n' "$archive"

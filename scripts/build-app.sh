#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/swift.sh build -c release
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
architecture=$(/usr/bin/uname -m)
profile="${1:-guided}"
case "$profile" in
  guided) bundle_name="MyMemo 引导版 $version.app"; archive_prefix="MyMemo-Guided" ;;
  --classic) bundle_name="MyMemo 经典版升级包 $version.app"; archive_prefix="MyMemo-Classic" ;;
  *) echo "Usage: bash scripts/build-app.sh [--classic]" >&2; exit 1 ;;
esac
build_dir=$(cat .build-location)
staging=$(mktemp -d "${TMPDIR:-/tmp}/mymemo-app.XXXXXX")
trap 'rm -rf "$staging"' EXIT
app="$staging/$bundle_name"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" dist
cp "$build_dir/release/MyMemoGuided" "$app/Contents/MacOS/MyMemoGuided"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [ "$profile" = "--classic" ]; then
  /usr/libexec/PlistBuddy -c 'Set CFBundleIdentifier com.zhongtw.MyMemo' "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set CFBundleName MyMemo 经典版' "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set CFBundleDisplayName MyMemo 经典版' "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add MyMemoDataProfile string classic' "$app/Contents/Info.plist"
fi
cp Resources/AppIcon.icns "$app/Contents/Resources/"
cp LICENSE "$app/Contents/Resources/LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
# Sign a fresh local staging bundle, avoiding Finder/iCloud metadata on old output.
/usr/bin/xattr -cr "$app"
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --deep --strict "$app"
archive="$archive_prefix-$version-macOS-$architecture.zip"
/usr/bin/ditto --noextattr --norsrc -c -k --keepParent "$app" "dist/$archive"
# Verify the distributed ZIP after extraction outside cloud-managed directories.
# iCloud may attach FinderInfo to the convenience .app copy in dist afterwards.
mkdir -p "$staging/verified"
/usr/bin/ditto --noextattr --norsrc -x -k "dist/$archive" "$staging/verified"
/usr/bin/codesign --verify --deep --strict "$staging/verified/$bundle_name"
/usr/bin/ditto --noextattr --norsrc "$app" "dist/$bundle_name"
(cd dist && /usr/bin/shasum -a 256 *-"$version"-macOS-*.zip > SHA256SUMS)
printf 'Created: dist/%s\n' "$archive"

#!/bin/bash
set -euo pipefail

fail() {
  printf 'Codex TPS packaging: %s\n' "$*" >&2
  exit 1
}

[[ $# == 3 ]] || fail 'Usage: bash scripts/package-macos.sh APP OUTPUT_DIR OWNER/REPO'
app=$1
output=$2
repo=$3
[[ "$repo" =~ ^[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+$ ]] || fail 'Expected a GitHub owner/repository.'
[[ -d "$app" && ! -L "$app" ]] || fail 'The app bundle is missing.'
[[ ! -e "$output" && ! -L "$output" ]] || fail 'The output directory already exists.'

plist="$app/Contents/Info.plist"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$plist")
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist")
minimum_macos=$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$plist")
[[ "$bundle_id" == local.codex-tps.app ]] || fail 'Unexpected App Bundle ID.'
[[ "$version" =~ ^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$ ]] || fail 'Expected a three-part app version.'
[[ "$minimum_macos" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || fail 'Expected a numeric macOS deployment target.'
architectures=$(/usr/bin/lipo -archs "$app/Contents/MacOS/Codex TPS")
[[ " $architectures " == *' arm64 '* && " $architectures " == *' x86_64 '* ]] \
  || fail 'Expected a universal app with arm64 and x86_64.'
/usr/bin/codesign --verify --deep --strict "$app"

script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
output_parent=$(dirname -- "$output")
mkdir -p "$output_parent"
work=$(mktemp -d "$output_parent/.codex-tps-package.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir "$work/image" "$work/assets"
/usr/bin/ditto "$app" "$work/image/Codex TPS.app"
ln -s /Applications "$work/image/Applications"
/usr/bin/install -m 0644 "$script_dir/../LICENSE" "$work/image/License.txt"

image=Codex-TPS-macOS-universal.dmg
assets="$work/assets"
/usr/bin/hdiutil create -quiet -fs HFS+ -format UDZO -volname "Codex TPS $version" \
  -srcfolder "$work/image" "$assets/$image"
digest=$(/usr/bin/shasum -a 256 "$assets/$image")
digest=${digest%% *}
/usr/bin/sed -e "s|@VERSION@|$version|g" -e "s|@REPO@|$repo|g" \
  -e "s|@MIN_MACOS@|$minimum_macos|g" -e "s|@DMG_SHA256@|$digest|g" \
  "$script_dir/install-macos.sh.in" > "$assets/install.sh"
/bin/bash -n "$assets/install.sh"
(
  cd "$assets"
  /usr/bin/shasum -a 256 "$image" install.sh > SHA256SUMS.txt
  /usr/bin/shasum -a 256 -c SHA256SUMS.txt
)
/bin/mv -n "$assets" "$output"
[[ ! -e "$assets" ]] || fail 'The output directory appeared while packaging.'
printf 'Packaged Codex TPS %s in %s\n' "$version" "$output"

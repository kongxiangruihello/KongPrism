#!/bin/bash
# Builds KongPrism.app into ./build.
#
#   scripts/build-app.sh                 build only
#   scripts/build-app.sh --test          run the unit tests first (including `sing-box check` on a generated config)
#   scripts/build-app.sh --install       quit the running copy, install to /Applications, launch
#   scripts/build-app.sh --zip           also write build/KongPrism-<version>.zip and its SHA-256 (for releases)
#   scripts/build-app.sh --dmg           also write build/KongPrism-<version>.dmg (drag-to-Applications installer)
#
# Environment:
#   KONGPRISM_ARCH=arm64|amd64           target architecture (default: this Mac)
#   KONGPRISM_VERSION=0.2.0              override CFBundleShortVersionString (the release workflow sets it from the tag)
#   KONGPRISM_SIGN_IDENTITY="…"          code-signing identity; otherwise a local "KongPrism/KongSeek/KongFetch Local Signing"
#                                        certificate if present, else ad hoc
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
mkdir -p build
log="$root/build/build.log"
exec > >(tee "$log") 2>&1

install=0; test=0; zip=0; dmg=0
for arg in "$@"; do
  case "$arg" in
    --install) install=1 ;;
    --test) test=1 ;;
    --zip) zip=1 ;;
    --dmg) dmg=1 ;;
    *) echo "unknown option: $arg"; exit 2 ;;
  esac
done

host_arch=amd64
[[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" == "1" ]] && host_arch=arm64
arch="${KONGPRISM_ARCH:-$host_arch}"
swift_arch=$([[ "$arch" == "arm64" ]] && echo arm64 || echo x86_64)

echo "== KongPrism build $(date '+%Y-%m-%d %H:%M:%S') ($arch) =="
sw_vers -productVersion | sed 's/^/macOS /'
xcrun swift --version 2>&1 | head -1

echo "== sing-box core =="
core="$(bash "$root/scripts/download-core.sh" "$arch")"
"$core" version | head -1 || true

if [[ $test -eq 1 ]]; then
  echo "== tests =="
  if [[ "$arch" == "$host_arch" ]]; then export KONGPRISM_SINGBOX="$core"; fi
  xcrun swift test
fi

echo "== compile =="
xcrun swift build -c release --product KongPrism --arch "$swift_arch"
bin_dir="$(xcrun swift build -c release --arch "$swift_arch" --show-bin-path)"

# Assemble outside the project folder: iCloud-synced folders add extended attributes codesign rejects.
staging="$(mktemp -d "${TMPDIR:-/tmp}/kongprism-build.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/KongPrism.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/rules"
cp "$bin_dir/KongPrism" "$app/Contents/MacOS/KongPrism"
cp "$core" "$app/Contents/MacOS/sing-box"
cp "$root"/Resources/rules/*.srs "$app/Contents/Resources/rules/"
cp "$root/Resources/tun-helper.sh" "$app/Contents/Resources/tun-helper.sh"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$root/LICENSE-sing-box.txt" "$app/Contents/Resources/" 2>/dev/null || true
build_number="$(git -C "$root" rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app/Contents/Info.plist"
if [[ -n "${KONGPRISM_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${KONGPRISM_VERSION#v}" "$app/Contents/Info.plist"
fi
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
echo "Version: $version ($build_number)"

echo "== icon =="
iconset="$staging/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z $size $size "$root/Resources/AppIcon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$root/Resources/AppIcon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

xattr -cr "$app"

echo "== sign =="
identity=""
for candidate in "${KONGPRISM_SIGN_IDENTITY:-}" "KongPrism Local Signing" "KongSeek Local Signing" "KongFetch Local Signing"; do
  [[ -z "$candidate" ]] && continue
  if security find-identity -p codesigning 2>/dev/null | grep -Fq "\"$candidate\""; then identity="$candidate"; break; fi
done
sign_as="${identity:--}"
# The core is signed first; signing the bundle does not sign nested executables.
codesign --force --sign "$sign_as" --identifier io.nekohasekai.sing-box "$app/Contents/MacOS/sing-box"
codesign --force --sign "$sign_as" --identifier com.kongxiangrui.KongPrism "$app"
if [[ -n "$identity" ]]; then echo "Signed with: $identity"; else echo "Signed ad hoc"; fi
codesign --verify --deep --strict "$app" && echo "Signature OK"

rm -rf "$root/build/KongPrism.app"
ditto "$app" "$root/build/KongPrism.app"
echo "Built: $root/build/KongPrism.app"

if [[ $zip -eq 1 ]]; then
  echo "== zip =="
  zip_path="$root/build/KongPrism-$version.zip"
  rm -f "$zip_path"
  ditto -c -k --keepParent "$root/build/KongPrism.app" "$zip_path"
  sha="$(shasum -a 256 "$zip_path" | awk '{print $1}')"
  echo "$sha" > "$zip_path.sha256"
  echo "Zip: $zip_path"
  echo "SHA-256: $sha"
  # Lite package (更新包瘦身): the same signed app without the core, used when the installed core
  # is byte-identical (the updater checks core.sha256 and puts its own core back in).
  lite_stage="$staging/lite"
  rm -rf "$lite_stage"; mkdir -p "$lite_stage"
  ditto "$root/build/KongPrism.app" "$lite_stage/KongPrism.app"
  rm "$lite_stage/KongPrism.app/Contents/MacOS/sing-box"
  lite_path="$root/build/KongPrism-$version-lite.zip"
  rm -f "$lite_path"
  ditto -c -k --keepParent "$lite_stage/KongPrism.app" "$lite_path"
  shasum -a 256 "$lite_path" | awk '{print $1}' > "$lite_path.sha256"
  shasum -a 256 "$root/build/KongPrism.app/Contents/MacOS/sing-box" | awk '{print $1}' > "$root/build/core.sha256"
  echo "Lite zip: $lite_path ($(du -h "$lite_path" | cut -f1)), core SHA-256 $(cat "$root/build/core.sha256")"
fi

if [[ $dmg -eq 1 ]]; then
  echo "== dmg =="
  dmg_stage="$staging/dmg"
  mkdir -p "$dmg_stage"
  ditto "$root/build/KongPrism.app" "$dmg_stage/KongPrism.app"
  ln -s /Applications "$dmg_stage/Applications"
  dmg_path="$root/build/KongPrism-$version.dmg"
  rm -f "$dmg_path"
  # hdiutil's own size estimate is sometimes too small ("No space left on device"):
  # give it the folder size plus room, and retry a couple of times.
  size_mb=$(( $(du -sm "$dmg_stage" | cut -f1) + 40 ))
  for attempt in 1 2 3; do
    if hdiutil create -volname "KongPrism $version" -srcfolder "$dmg_stage" -size "${size_mb}m" -ov -format UDZO "$dmg_path" >/dev/null; then break; fi
    [[ $attempt == 3 ]] && { echo "DMG 创建失败"; exit 1; }
    echo "hdiutil 失败，重试（第 ${attempt} 次）"; size_mb=$(( size_mb * 2 )); sleep 3
  done
  echo "DMG: $dmg_path"
fi

if [[ $install -eq 1 ]]; then
  echo "== install =="
  # Quitting normally lets KongPrism put the system proxy back first.
  osascript -e 'tell application id "com.kongxiangrui.KongPrism" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 25); do pgrep -x KongPrism >/dev/null || break; sleep 0.2; done
  pkill -x KongPrism >/dev/null 2>&1 || true
  rm -rf /Applications/KongPrism.app
  ditto "$root/build/KongPrism.app" /Applications/KongPrism.app
  open /Applications/KongPrism.app
  echo "Installed: /Applications/KongPrism.app"
fi

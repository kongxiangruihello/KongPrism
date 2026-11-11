#!/bin/bash
# Downloads the pinned sing-box release for macOS into .downloads/ and verifies its SHA-256.
#   scripts/download-core.sh [arm64|amd64]   (default: this Mac's architecture)
# Uses the system proxy when one is set (GitHub is often unreachable directly in mainland China).
set -euo pipefail

VERSION="1.14.4"
SHA_arm64="0d8c7f5ed5d587b0f1a5e9772a708ec3bfa4ac4c9329604b01d8d9c2ba406838"
SHA_amd64="eae86b9b033bba50b7c44ab719e4bfac0aca05efd28483390ed3aa510f32db25"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
arch="${1:-}"
if [[ -z "$arch" ]]; then
  if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" == "1" ]]; then arch=arm64; else arch=amd64; fi
fi
sha_var="SHA_$arch"
expected="${!sha_var}"
out="$root/.downloads/sing-box-$VERSION-$arch"
if [[ -x "$out" ]]; then echo "$out"; exit 0; fi
mkdir -p "$root/.downloads"

# Pick up the macOS system proxy for curl if none is set in the environment.
if [[ -z "${https_proxy:-}${HTTPS_PROXY:-}" ]] && command -v scutil >/dev/null; then
  proxy_info="$(scutil --proxy)"
  if echo "$proxy_info" | grep -q "HTTPSEnable : 1"; then
    host="$(echo "$proxy_info" | awk '/HTTPSProxy :/ {print $3}')"
    port="$(echo "$proxy_info" | awk '/HTTPSPort :/ {print $3}')"
    export https_proxy="http://$host:$port"
    echo "使用系统代理 $https_proxy 下载" >&2
  fi
fi

name="sing-box-$VERSION-darwin-$arch"
archive="$root/.downloads/$name.tar.gz"
url="https://github.com/SagerNet/sing-box/releases/download/v$VERSION/$name.tar.gz"
echo "下载 $url" >&2
curl -L --fail --retry 3 --connect-timeout 20 -o "$archive" "$url" >&2
actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
if [[ "$actual" != "$expected" ]]; then
  echo "SHA-256 校验失败：$actual" >&2
  rm -f "$archive"
  exit 1
fi
tar -xzf "$archive" -C "$root/.downloads"
mv "$root/.downloads/$name/sing-box" "$out"
rm -rf "$root/.downloads/$name" "$archive"
chmod +x "$out"
echo "$out"

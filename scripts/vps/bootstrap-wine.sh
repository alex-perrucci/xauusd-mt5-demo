#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/vps/bootstrap-wine.sh" >&2
  exit 1
fi

source /etc/os-release
if [[ "${ID:-}" != "ubuntu" || "${VERSION_CODENAME:-}" != "resolute" ]]; then
  echo "This bootstrap is intentionally pinned to Ubuntu 26.04 (resolute). Found: ${PRETTY_NAME:-unknown}" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

dpkg --add-architecture i386

rm -f /etc/apt/sources.list.d/winehq-resolute.sources
rm -f /etc/apt/keyrings/winehq-archive.key
rm -f /etc/apt/keyrings/winehq-archive.gpg

apt-get update
apt-get install -y --no-install-recommends ca-certificates wget gnupg xvfb xauth

install -d -m 0755 /etc/apt/keyrings

tmp_key="$(mktemp)"
tmp_sources="$(mktemp)"
trap 'rm -f "$tmp_key" "$tmp_sources"' EXIT

wget -qO "$tmp_key" https://dl.winehq.org/wine-builds/winehq.key
gpg --batch --yes --dearmor -o /etc/apt/keyrings/winehq-archive.gpg "$tmp_key"
chmod 0644 /etc/apt/keyrings/winehq-archive.gpg

wget -qO "$tmp_sources" https://dl.winehq.org/wine-builds/ubuntu/dists/resolute/winehq-resolute.sources
sed 's#/etc/apt/keyrings/winehq-archive\.key#/etc/apt/keyrings/winehq-archive.gpg#g' \
  "$tmp_sources" > /etc/apt/sources.list.d/winehq-resolute.sources
chmod 0644 /etc/apt/sources.list.d/winehq-resolute.sources

apt-get update

# Wine 11.17 has an upstream startup regression that can produce
# 'could not load kernel32.dll, status c0000135'. Pin 11.16 until fixed.
TARGET_VERSION="$(apt-cache madison winehq-devel | awk '$3 ~ /^11\.16/ {print $3; exit}')"
if [[ -z "$TARGET_VERSION" ]]; then
  echo "WineHQ 11.16 not found. Available versions:" >&2
  apt-cache madison winehq-devel >&2 || true
  exit 1
fi

apt-get install -y --allow-downgrades --install-recommends \
  "winehq-devel=${TARGET_VERSION}" \
  "wine-devel=${TARGET_VERSION}" \
  "wine-devel-amd64=${TARGET_VERSION}" \
  "wine-devel-i386:i386=${TARGET_VERSION}"
apt-mark hold winehq-devel wine-devel wine-devel-amd64 wine-devel-i386:i386 >/dev/null

WINE_BIN="$(command -v wine || true)"
if [[ -z "$WINE_BIN" && -x /opt/wine-devel/bin/wine ]]; then
  WINE_BIN=/opt/wine-devel/bin/wine
fi

printf '\nWine installation:\n'
if [[ -n "$WINE_BIN" ]]; then
  printf 'binary: %s\n' "$WINE_BIN"
  "$WINE_BIN" --version
else
  echo "Wine installed package but no wine binary was found" >&2
  exit 1
fi

printf '\nXvfb installation:\n'
command -v Xvfb

printf '\nForeign architectures:\n'
dpkg --print-foreign-architectures

printf '\nHeld Wine packages:\n'
apt-mark showhold | grep '^wine' || true

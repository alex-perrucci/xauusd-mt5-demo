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

# WineHQ publishes both amd64 and i386 dependencies. This is idempotent.
dpkg --add-architecture i386

# A previous interrupted/bootstrap attempt may have left a WineHQ source that
# references an invalid .key file. Remove only our known WineHQ Resolute source
# and key files BEFORE the first apt update, otherwise apt exits before we can
# repair them.
rm -f /etc/apt/sources.list.d/winehq-resolute.sources
rm -f /etc/apt/keyrings/winehq-archive.key
rm -f /etc/apt/keyrings/winehq-archive.gpg

# Refresh only with the already-trusted Ubuntu/Docker sources, then install the
# tools needed to build a valid WineHQ keyring.
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
apt-get install -y --install-recommends winehq-devel

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

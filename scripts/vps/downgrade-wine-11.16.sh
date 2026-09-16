#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/vps/downgrade-wine-11.16.sh" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
WINE_BIN=/opt/wine-devel/bin/wine
WINESERVER_BIN=/opt/wine-devel/bin/wineserver
PREFIX=/home/perrucci/.mt5

apt-get update

# Wine GUI components on this headless host still need EGL at runtime. Install
# both architectures because the WineHQ devel build carries 64/32-bit pieces.
apt-get install -y --no-install-recommends libegl1 libegl1:i386

# Stop any 11.17 wineserver that may still be attached to this prefix before
# replacing binaries on disk.
if [[ -x "$WINESERVER_BIN" ]]; then
  sudo -u perrucci env HOME=/home/perrucci WINEPREFIX="$PREFIX" "$WINESERVER_BIN" -k || true
  sleep 2
fi

# Do not use `awk ... exit` in a pipe while `pipefail` is enabled: apt-cache can
# receive SIGPIPE and abort this script before the downgrade starts.
MADISON_OUTPUT="$(apt-cache madison winehq-devel || true)"
TARGET_LINE="$(awk '$3 ~ /^11\.16/ && !found {v=$3; found=1} END {print v}' <<<"$MADISON_OUTPUT")"

if [[ -z "$TARGET_LINE" ]]; then
  echo "WineHQ 11.16 is not present in the configured repository." >&2
  echo "Available winehq-devel versions:" >&2
  printf '%s\n' "$MADISON_OUTPUT" >&2
  exit 1
fi

printf 'Target WineHQ version: %s\n' "$TARGET_LINE"

# In case an earlier attempt managed to hold any Wine package, clear those
# holds before performing the explicit downgrade.
apt-mark unhold winehq-devel wine-devel wine-devel-amd64 wine-devel-i386:i386 >/dev/null 2>&1 || true

apt-get install -y --allow-downgrades --install-recommends \
  "winehq-devel=${TARGET_LINE}" \
  "wine-devel=${TARGET_LINE}" \
  "wine-devel-amd64=${TARGET_LINE}" \
  "wine-devel-i386:i386=${TARGET_LINE}"

apt-mark hold winehq-devel wine-devel wine-devel-amd64 wine-devel-i386:i386 >/dev/null

printf '\nInstalled Wine version:\n'
INSTALLED_VERSION="$($WINE_BIN --version)"
printf '%s\n' "$INSTALLED_VERSION"

if [[ "$INSTALLED_VERSION" != wine-11.16* ]]; then
  echo "Expected Wine 11.16 but got: $INSTALLED_VERSION" >&2
  exit 1
fi

printf '\nEGL libraries:\n'
ldconfig -p | grep 'libEGL.so.1' || true

printf '\nHeld Wine packages:\n'
apt-mark showhold | grep '^wine' || true

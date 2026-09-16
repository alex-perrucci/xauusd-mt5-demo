#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/vps/downgrade-wine-11.16.sh" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
WINEPREFIX=/home/perrucci/.mt5
WINE_BIN=/opt/wine-devel/bin/wine
WINESERVER_BIN=/opt/wine-devel/bin/wineserver

# Stop any Wine 11.17 processes tied to the MT5 prefix before replacing the
# binaries on disk. Ignore failure because the regression itself can prevent
# normal Wine startup/shutdown.
if [[ -x "$WINESERVER_BIN" ]]; then
  sudo -u perrucci env HOME=/home/perrucci WINEPREFIX="$WINEPREFIX" "$WINESERVER_BIN" -k >/dev/null 2>&1 || true
fi
pkill -u perrucci -f '/opt/wine-devel/bin/.*wine' >/dev/null 2>&1 || true
sleep 2

# Wine 11.17 has a regression that can fail prefix startup with
# 'could not load kernel32.dll, status c0000135'. Pin the last known-good
# development build (11.16) until the upstream regression is fixed.
TARGET_LINE="$(apt-cache madison winehq-devel | awk '$3 ~ /^11\.16/ {print $3; exit}')"
if [[ -z "${TARGET_LINE}" ]]; then
  echo "WineHQ 11.16 is not present in the configured repository." >&2
  echo "Available winehq-devel versions:" >&2
  apt-cache madison winehq-devel >&2 || true
  exit 1
fi

printf 'Downgrading WineHQ development packages to %s...\n' "${TARGET_LINE}"

apt-get install -y --allow-downgrades --install-recommends \
  "winehq-devel=${TARGET_LINE}" \
  "wine-devel=${TARGET_LINE}" \
  "wine-devel-amd64=${TARGET_LINE}" \
  "wine-devel-i386:i386=${TARGET_LINE}"

apt-mark hold winehq-devel wine-devel wine-devel-amd64 wine-devel-i386:i386 >/dev/null

printf '\nInstalled Wine version:\n'
"$WINE_BIN" --version
printf '\nHeld packages:\n'
apt-mark showhold | grep '^wine' || true

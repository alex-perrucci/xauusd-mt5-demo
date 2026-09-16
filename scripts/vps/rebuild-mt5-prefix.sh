#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT=/opt/xauusd-mt5-demo
RUN_USER=perrucci
RUN_HOME=/home/perrucci
PREFIX=${RUN_HOME}/.mt5
WINE_BIN=/opt/wine-devel/bin/wine
WINESERVER_BIN=/opt/wine-devel/bin/wineserver

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash ${REPO_ROOT}/scripts/vps/rebuild-mt5-prefix.sh" >&2
  exit 1
fi

[[ -x "$WINE_BIN" ]] || { echo "Wine not found at $WINE_BIN" >&2; exit 1; }

WINE_VERSION="$($WINE_BIN --version)"
if [[ "$WINE_VERSION" != wine-11.16* ]]; then
  echo "Refusing to rebuild prefix with $WINE_VERSION. Expected Wine 11.16." >&2
  exit 1
fi

if [[ "$PREFIX" != "/home/perrucci/.mt5" ]]; then
  echo "Safety check failed: unexpected prefix path: $PREFIX" >&2
  exit 1
fi

printf 'Using %s\n' "$WINE_VERSION"
printf 'Current prefix size: '
if [[ -d "$PREFIX" ]]; then
  du -sh "$PREFIX" | awk '{print $1}'
else
  echo "not present"
fi

# Stop only Wine processes attached to this user's MT5 prefix.
if [[ -x "$WINESERVER_BIN" ]]; then
  sudo -u "$RUN_USER" env HOME="$RUN_HOME" WINEPREFIX="$PREFIX" "$WINESERVER_BIN" -k || true
  sleep 2
fi

# This prefix was originally initialized under Wine 11.17, whose upstream
# regression can leave freshly-created prefixes unable to launch external PE
# executables. No broker credentials/account configuration have been added yet,
# so rebuilding is safer than trying to mutate the damaged prefix in place.
echo "Removing old MT5 prefix: $PREFIX"
rm -rf --one-file-system "$PREFIX"

# Reclaim downloaded package archives before rebuilding; this does not remove
# installed packages or touch Docker/Fluxa data.
apt-get clean

printf 'Disk after removing old prefix/cache:\n'
df -h /

# Recreate the prefix and MT5 under Wine 11.16, then install Windows Python and
# the MetaTrader5 package in the same prefix.
bash "$REPO_ROOT/scripts/vps/install-mt5.sh"
bash "$REPO_ROOT/scripts/vps/install-python-windows.sh"

printf '\nRebuild completed.\n'
printf 'Wine: '
"$WINE_BIN" --version
printf 'Prefix size: '
du -sh "$PREFIX" | awk '{print $1}'
printf 'Disk:\n'
df -h /

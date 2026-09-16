#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/vps/install-python-windows.sh" >&2
  exit 1
fi

USER_NAME=perrucci
USER_HOME=/home/perrucci
WINEPREFIX=${USER_HOME}/.mt5
DISPLAY_NUM=:99
WINE_BIN=/opt/wine-devel/bin/wine
WINEPATH_BIN=/opt/wine-devel/bin/winepath
PY_EXE='C:\\Python311\\python.exe'
PY_VERSION=3.11.9
INSTALLER="/tmp/python-${PY_VERSION}-amd64.exe"
INSTALLER_URL="https://www.python.org/ftp/python/${PY_VERSION}/python-${PY_VERSION}-amd64.exe"
REPO_ROOT=/opt/xauusd-mt5-demo

[[ -x "$WINE_BIN" ]] || { echo "Wine not found at $WINE_BIN" >&2; exit 1; }
[[ -x "$WINEPATH_BIN" ]] || { echo "winepath not found at $WINEPATH_BIN" >&2; exit 1; }
[[ -d "$WINEPREFIX" ]] || { echo "Wine prefix not found: $WINEPREFIX" >&2; exit 1; }
[[ -f "$WINEPREFIX/drive_c/Program Files/MetaTrader 5/terminal64.exe" ]] || {
  echo "MetaTrader 5 terminal not found in prefix" >&2
  exit 1
}

started_xvfb=0
if ! pgrep -f "Xvfb ${DISPLAY_NUM}" >/dev/null 2>&1; then
  echo "Starting temporary Xvfb on ${DISPLAY_NUM}..."
  sudo -u "$USER_NAME" Xvfb "$DISPLAY_NUM" -screen 0 1280x720x24 -nolisten tcp -ac >/tmp/xauusd-xvfb-install.log 2>&1 &
  XVFB_PID=$!
  started_xvfb=1
  sleep 2
fi

cleanup() {
  rm -f "$INSTALLER"
  if [[ "$started_xvfb" == "1" ]]; then
    kill "$XVFB_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "Downloading Python ${PY_VERSION} Windows x64 installer..."
wget -q --show-progress -O "$INSTALLER" "$INSTALLER_URL"
chown "$USER_NAME:$USER_NAME" "$INSTALLER"

echo "Installing Python ${PY_VERSION} into C:\\Python311..."
sudo -u "$USER_NAME" env \
  HOME="$USER_HOME" \
  DISPLAY="$DISPLAY_NUM" \
  WINEPREFIX="$WINEPREFIX" \
  PATH="/opt/wine-devel/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  "$WINE_BIN" "$INSTALLER" /quiet \
    InstallAllUsers=1 \
    TargetDir='C:\Python311' \
    Include_pip=1 \
    Include_test=0 \
    Include_launcher=0 \
    AssociateFiles=0 \
    Shortcuts=0 \
    PrependPath=0

sleep 2

echo "Verifying Windows Python..."
sudo -u "$USER_NAME" env HOME="$USER_HOME" DISPLAY="$DISPLAY_NUM" WINEPREFIX="$WINEPREFIX" \
  PATH="/opt/wine-devel/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  "$WINE_BIN" "$PY_EXE" --version

echo "Upgrading pip..."
sudo -u "$USER_NAME" env HOME="$USER_HOME" DISPLAY="$DISPLAY_NUM" WINEPREFIX="$WINEPREFIX" \
  PATH="/opt/wine-devel/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  "$WINE_BIN" "$PY_EXE" -m pip install --disable-pip-version-check --no-cache-dir --upgrade pip

echo "Installing Windows dependencies..."
REQ_WIN="$(sudo -u "$USER_NAME" env HOME="$USER_HOME" WINEPREFIX="$WINEPREFIX" "$WINEPATH_BIN" -w "${REPO_ROOT}/requirements-windows.txt")"
sudo -u "$USER_NAME" env HOME="$USER_HOME" DISPLAY="$DISPLAY_NUM" WINEPREFIX="$WINEPREFIX" \
  PATH="/opt/wine-devel/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  "$WINE_BIN" "$PY_EXE" -m pip install --disable-pip-version-check --no-cache-dir -r "$REQ_WIN"

echo "Verifying MetaTrader5 package..."
sudo -u "$USER_NAME" env HOME="$USER_HOME" DISPLAY="$DISPLAY_NUM" WINEPREFIX="$WINEPREFIX" \
  PATH="/opt/wine-devel/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  "$WINE_BIN" "$PY_EXE" -c "import MetaTrader5 as mt5; print('MetaTrader5', mt5.__version__)"

echo
echo "Windows Python setup completed."
du -sh "$WINEPREFIX"
df -h /

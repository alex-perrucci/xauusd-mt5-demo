#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="/opt/xauusd-mt5-demo"
RUN_USER="perrucci"
RUN_HOME="/home/perrucci"
WINE_PREFIX="${RUN_HOME}/.mt5"
WINE_BIN="/opt/wine-devel/bin/wine"
WINEBOOT_BIN="/opt/wine-devel/bin/wineboot"
DISPLAY_NUM=99
DISPLAY=":${DISPLAY_NUM}"
MT5_URL="https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"
INSTALLER="/tmp/mt5setup.exe"
TERMINAL_EXE="${WINE_PREFIX}/drive_c/Program Files/MetaTrader 5/terminal64.exe"
XVFB_PID=""

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash ${REPO_ROOT}/scripts/vps/install-mt5.sh" >&2
  exit 1
fi

id "${RUN_USER}" >/dev/null 2>&1 || { echo "Missing user ${RUN_USER}" >&2; exit 1; }
[[ -x "${WINE_BIN}" ]] || { echo "Wine not found at ${WINE_BIN}" >&2; exit 1; }
command -v Xvfb >/dev/null 2>&1 || { echo "Xvfb is not installed" >&2; exit 1; }
command -v wget >/dev/null 2>&1 || { echo "wget is not installed" >&2; exit 1; }

if [[ -f "${TERMINAL_EXE}" ]]; then
  echo "MetaTrader 5 is already installed at: ${TERMINAL_EXE}"
  exit 0
fi

cleanup() {
  if [[ -n "${XVFB_PID}" ]] && kill -0 "${XVFB_PID}" 2>/dev/null; then
    kill "${XVFB_PID}" 2>/dev/null || true
    wait "${XVFB_PID}" 2>/dev/null || true
  fi
  rm -f "${INSTALLER}"
}
trap cleanup EXIT

# Use an already-running :99 display if present; otherwise create a temporary one.
if ! pgrep -af "Xvfb :${DISPLAY_NUM}( |$)" >/dev/null 2>&1; then
  sudo -u "${RUN_USER}" Xvfb "${DISPLAY}" -screen 0 1280x720x24 -nolisten tcp -ac >/tmp/xauusd-xvfb-install.log 2>&1 &
  XVFB_PID=$!
  sleep 2
  kill -0 "${XVFB_PID}" 2>/dev/null || {
    echo "Temporary Xvfb failed to start; see /tmp/xauusd-xvfb-install.log" >&2
    exit 1
  }
fi

install -d -o "${RUN_USER}" -g "${RUN_USER}" -m 0700 "${WINE_PREFIX}"

echo "Initializing Wine prefix ${WINE_PREFIX}..."
sudo -u "${RUN_USER}" env \
  HOME="${RUN_HOME}" \
  DISPLAY="${DISPLAY}" \
  WINEPREFIX="${WINE_PREFIX}" \
  WINEARCH=win64 \
  WINEDEBUG=-all \
  "${WINEBOOT_BIN}" --init

# Give wineserver a moment to finish first-run prefix setup.
sleep 3

echo "Downloading official MetaTrader 5 installer..."
wget -q --https-only -O "${INSTALLER}" "${MT5_URL}"
[[ -s "${INSTALLER}" ]] || { echo "MT5 installer download is empty" >&2; exit 1; }
chmod 0644 "${INSTALLER}"

echo "Installing MetaTrader 5 in automated mode..."
set +e
timeout --signal=TERM --kill-after=15s 300s \
  sudo -u "${RUN_USER}" env \
    HOME="${RUN_HOME}" \
    DISPLAY="${DISPLAY}" \
    WINEPREFIX="${WINE_PREFIX}" \
    WINEDEBUG=-all \
    "${WINE_BIN}" "${INSTALLER}" /auto
installer_rc=$?
set -e

# /auto may launch the terminal and keep Wine alive. The installation result on disk
# is authoritative; a timeout is acceptable only if terminal64.exe exists.
if [[ ! -f "${TERMINAL_EXE}" ]]; then
  echo "MetaTrader 5 installation did not produce ${TERMINAL_EXE} (installer rc=${installer_rc})" >&2
  exit 1
fi

chown -R "${RUN_USER}:${RUN_USER}" "${WINE_PREFIX}"

printf '\nMetaTrader 5 installed successfully.\n'
printf 'Terminal: %s\n' "${TERMINAL_EXE}"
printf 'Wine prefix size: '
du -sh "${WINE_PREFIX}" | awk '{print $1}'
printf 'Disk after install:\n'
df -h /

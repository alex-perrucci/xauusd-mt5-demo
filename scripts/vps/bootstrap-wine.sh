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

apt-get update
apt-get install -y --no-install-recommends ca-certificates wget xvfb xauth

install -d -m 0755 /etc/apt/keyrings
wget -qO /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key
wget -qO /etc/apt/sources.list.d/winehq-resolute.sources https://dl.winehq.org/wine-builds/ubuntu/dists/resolute/winehq-resolute.sources

apt-get update
apt-get install -y --install-recommends winehq-devel

printf '\nWine installation:\n'
command -v wine || true
wine --version || true
printf '\nXvfb installation:\n'
command -v Xvfb || true

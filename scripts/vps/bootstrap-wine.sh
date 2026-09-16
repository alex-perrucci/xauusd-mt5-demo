#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "run as root" >&2
  exit 1
fi

source /etc/os-release
if [[ ${ID:-} != ubuntu || ${VERSION_CODENAME:-} != resolute ]]; then
  echo "supported host: Ubuntu 26.04 resolute; found ${PRETTY_NAME:-unknown}" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
dpkg --add-architecture i386

rm -f /etc/apt/sources.list.d/winehq-resolute.sources
rm -f /etc/apt/keyrings/winehq-archive.key /etc/apt/keyrings/winehq-archive.gpg
apt-get update
apt-get install -y --no-install-recommends ca-certificates wget gnupg xvfb xauth libegl1 libegl1:i386

install -d -m 0755 /etc/apt/keyrings
tmp_key=$(mktemp)
tmp_sources=$(mktemp)
trap 'rm -f "$tmp_key" "$tmp_sources"' EXIT
wget -qO "$tmp_key" https://dl.winehq.org/wine-builds/winehq.key
gpg --batch --yes --dearmor -o /etc/apt/keyrings/winehq-archive.gpg "$tmp_key"
chmod 0644 /etc/apt/keyrings/winehq-archive.gpg
wget -qO "$tmp_sources" https://dl.winehq.org/wine-builds/ubuntu/dists/resolute/winehq-resolute.sources
sed 's#/etc/apt/keyrings/winehq-archive\.key#/etc/apt/keyrings/winehq-archive.gpg#g' "$tmp_sources" > /etc/apt/sources.list.d/winehq-resolute.sources
chmod 0644 /etc/apt/sources.list.d/winehq-resolute.sources
apt-get update

madison=$(apt-cache madison winehq-devel || true)
target=$(awk '$3 ~ /^11\.16/ && !found {v=$3; found=1} END {print v}' <<<"$madison")
if [[ -z $target ]]; then
  echo "WineHQ 11.16 not available" >&2
  printf '%s\n' "$madison" >&2
  exit 1
fi

apt-mark unhold winehq-devel wine-devel >/dev/null 2>&1 || true
apt-get install -y --allow-downgrades --install-recommends "winehq-devel=$target" "wine-devel=$target"
apt-mark hold winehq-devel wine-devel >/dev/null

version=$(/opt/wine-devel/bin/wine --version)
[[ $version == wine-11.16* ]] || { echo "expected Wine 11.16, got $version" >&2; exit 1; }
printf 'Wine ready: %s\n' "$version"
printf 'Xvfb: %s\n' "$(command -v Xvfb)"

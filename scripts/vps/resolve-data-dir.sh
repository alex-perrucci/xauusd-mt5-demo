#!/usr/bin/env bash
set -Eeuo pipefail

PREFIX=${PREFIX:-/home/perrucci/.mt5}
RUN_USER=${RUN_USER:-perrucci}
BASE="$PREFIX/drive_c/users/$RUN_USER/AppData/Roaming/MetaQuotes/Terminal"
INSTALL_HINT='MetaTrader 5'

[[ -d "$BASE" ]] || {
  echo "MT5 data root not found: $BASE" >&2
  exit 1
}

mapfile -t origins < <(find "$BASE" -mindepth 2 -maxdepth 2 -type f -name origin.txt -print 2>/dev/null)

if [[ ${#origins[@]} -eq 0 ]]; then
  echo "No MetaTrader origin.txt found under $BASE" >&2
  exit 1
fi

if [[ ${#origins[@]} -eq 1 ]]; then
  dirname "${origins[0]}"
  exit 0
fi

matches=()
for origin in "${origins[@]}"; do
  text=""
  if command -v iconv >/dev/null 2>&1; then
    text="$(iconv -f UTF-16LE -t UTF-8 "$origin" 2>/dev/null || true)"
  fi
  if [[ -z "$text" ]]; then
    text="$(tr -d '\000' < "$origin" 2>/dev/null || true)"
  fi
  if grep -Fqi "$INSTALL_HINT" <<<"$text"; then
    matches+=("$(dirname "$origin")")
  fi
done

if [[ ${#matches[@]} -eq 1 ]]; then
  printf '%s\n' "${matches[0]}"
  exit 0
fi

# Last-resort deterministic fallback: newest origin file.
newest="$(find "$BASE" -mindepth 2 -maxdepth 2 -type f -name origin.txt -printf '%T@ %h\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)"
[[ -n "$newest" ]] || {
  echo "Unable to resolve MT5 data directory" >&2
  exit 1
}
printf '%s\n' "$newest"

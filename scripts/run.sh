#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ ! -f config.json ]]; then
  echo "Missing config.json. Run: cp config.example.json config.json" >&2
  exit 2
fi

exec python3 bridge/poller.py --config "$ROOT/config.json" "$@"

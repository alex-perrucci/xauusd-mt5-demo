#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
SIGNAL_PATH = ROOT / "signal.json"
STATE_DIR = ROOT / "state"
STATE_PATH = STATE_DIR / "poller_state.json"
EXECUTOR_PATH = ROOT / "bridge" / "mt5_executor.py"

ALLOWED_ACTIONS = {"NO_TRADE", "BUY", "SELL", "HOLD", "CLOSE", "MODIFY"}


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as fh:
        return json.load(fh)


def save_json_atomic(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, sort_keys=True)
        fh.write("\n")
    tmp.replace(path)


def parse_iso8601(value: str) -> datetime:
    dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        raise ValueError("timestamp must include timezone")
    return dt


def validate_signal(signal: dict[str, Any], max_risk_pct: float) -> None:
    if signal.get("schema_version") != 1:
        raise ValueError("unsupported schema_version")

    signal_id = signal.get("id")
    if not isinstance(signal_id, str) or not signal_id.strip():
        raise ValueError("signal id is required")

    if signal.get("symbol") != "XAUUSD":
        raise ValueError("only XAUUSD is accepted")

    action = signal.get("action")
    if action not in ALLOWED_ACTIONS:
        raise ValueError(f"unsupported action: {action}")

    created_at = signal.get("created_at")
    valid_until = signal.get("valid_until")
    if not isinstance(created_at, str) or not isinstance(valid_until, str):
        raise ValueError("created_at and valid_until are required")

    created_dt = parse_iso8601(created_at)
    valid_until_dt = parse_iso8601(valid_until)
    if valid_until_dt <= created_dt:
        raise ValueError("valid_until must be after created_at")

    now = datetime.now(timezone.utc)
    if now > valid_until_dt.astimezone(timezone.utc):
        raise ValueError("signal is expired")

    if action in {"BUY", "SELL"}:
        if signal.get("entry_type") != "MARKET":
            raise ValueError("only MARKET entries are supported")
        for key in ("sl", "tp", "risk_pct"):
            value = signal.get(key)
            if not isinstance(value, (int, float)):
                raise ValueError(f"{key} must be numeric")
        if float(signal["sl"]) <= 0 or float(signal["tp"]) <= 0:
            raise ValueError("sl and tp must be positive")
        risk_pct = float(signal["risk_pct"])
        if risk_pct <= 0 or risk_pct > max_risk_pct:
            raise ValueError(f"risk_pct must be > 0 and <= {max_risk_pct}")

    if action == "MODIFY":
        sl = signal.get("sl")
        tp = signal.get("tp")
        if sl is None and tp is None:
            raise ValueError("MODIFY requires sl and/or tp")
        for key, value in (("sl", sl), ("tp", tp)):
            if value is not None and (not isinstance(value, (int, float)) or float(value) <= 0):
                raise ValueError(f"{key} must be a positive number or null")


def git_pull() -> None:
    result = subprocess.run(
        ["git", "-C", str(ROOT), "pull", "--ff-only"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"git pull failed: {result.stdout.strip()}")


def winepath(path: Path, env: dict[str, str]) -> str:
    result = subprocess.run(
        ["winepath", "-w", str(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )
    if result.returncode != 0:
        raise RuntimeError(f"winepath failed for {path}: {result.stderr.strip()}")
    return result.stdout.strip()


def execute_signal(signal: dict[str, Any], config: dict[str, Any]) -> int:
    action = signal["action"]
    if action in {"NO_TRADE", "HOLD"}:
        print(f"[{datetime.now().isoformat()}] {action}: nothing to execute")
        return 0

    env = os.environ.copy()
    wine_prefix = os.path.expanduser(str(config.get("wine_prefix", "~/.wine-mt5")))
    env["WINEPREFIX"] = wine_prefix

    windows_python = str(config.get("windows_python", "")).strip()
    if not windows_python:
        raise RuntimeError("windows_python is missing from config.json")

    win_executor = winepath(EXECUTOR_PATH, env)
    win_signal = winepath(SIGNAL_PATH, env)

    cmd = [
        "wine",
        windows_python,
        win_executor,
        "--signal",
        win_signal,
        "--broker-symbol",
        str(config.get("broker_symbol", "XAUUSD")),
        "--magic",
        str(int(config.get("magic", 560017))),
        "--max-risk-pct",
        str(float(config.get("max_risk_pct", 0.5))),
        "--max-spread-points",
        str(float(config.get("max_spread_points", 100))),
        "--deviation-points",
        str(int(config.get("deviation_points", 30))),
    ]

    terminal_path = str(config.get("terminal_path", "")).strip()
    if terminal_path:
        cmd.extend(["--terminal-path", terminal_path])

    result = subprocess.run(cmd, env=env)
    return result.returncode


def load_state() -> dict[str, Any]:
    if not STATE_PATH.exists():
        return {"processed_ids": []}
    try:
        state = load_json(STATE_PATH)
    except Exception:
        return {"processed_ids": []}
    if not isinstance(state.get("processed_ids"), list):
        state["processed_ids"] = []
    return state


def mark_processed(state: dict[str, Any], signal_id: str) -> None:
    ids = [str(x) for x in state.get("processed_ids", []) if x]
    if signal_id not in ids:
        ids.append(signal_id)
    state["processed_ids"] = ids[-500:]
    state["last_processed_id"] = signal_id
    state["last_processed_at"] = datetime.now(timezone.utc).isoformat()
    save_json_atomic(STATE_PATH, state)


def process_once(config: dict[str, Any]) -> None:
    if bool(config.get("auto_git_pull", True)):
        git_pull()

    signal = load_json(SIGNAL_PATH)
    max_risk_pct = float(config.get("max_risk_pct", 0.5))
    validate_signal(signal, max_risk_pct=max_risk_pct)

    state = load_state()
    signal_id = str(signal["id"])
    if signal_id in state.get("processed_ids", []):
        return

    print(f"[{datetime.now().isoformat()}] processing {signal_id}: {signal['action']}")
    rc = execute_signal(signal, config)
    if rc != 0:
        raise RuntimeError(f"MT5 executor exited with code {rc}")

    mark_processed(state, signal_id)


def main() -> int:
    parser = argparse.ArgumentParser(description="Poll ChatGPT-produced XAUUSD signals and execute them on MT5 demo.")
    parser.add_argument("--config", default=str(ROOT / "config.json"))
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()

    config_path = Path(args.config).resolve()
    if not config_path.exists():
        print(f"Missing config: {config_path}. Copy config.example.json to config.json first.", file=sys.stderr)
        return 2

    config = load_json(config_path)
    poll_seconds = max(10, int(config.get("poll_seconds", 60)))

    while True:
        try:
            process_once(config)
        except ValueError as exc:
            # Invalid or expired signals should not hammer MT5. Log and wait for a new Git commit.
            print(f"[{datetime.now().isoformat()}] signal rejected: {exc}", file=sys.stderr)
        except Exception as exc:
            print(f"[{datetime.now().isoformat()}] poller error: {exc}", file=sys.stderr)

        if args.once:
            break
        time.sleep(poll_seconds)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import subprocess
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
ALLOWED_ACTIONS = {"NO_TRADE", "BUY", "SELL", "HOLD", "CLOSE", "MODIFY"}


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as fh:
        return json.load(fh)


def parse_dt(value: str, field: str) -> datetime:
    dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        raise ValueError(f"{field} must be timezone-aware")
    return dt.astimezone(timezone.utc)


def validate_signal(signal: dict[str, Any], max_risk_pct: float) -> tuple[str, int, int]:
    if signal.get("schema_version") != 1:
        raise ValueError("schema_version must be 1")

    signal_id = str(signal.get("id", "")).strip()
    if not signal_id or "|" in signal_id or "\n" in signal_id or "\r" in signal_id:
        raise ValueError("invalid signal id")

    if signal.get("symbol") != "XAUUSD":
        raise ValueError("logical symbol must be XAUUSD")

    action = str(signal.get("action", ""))
    if action not in ALLOWED_ACTIONS:
        raise ValueError(f"unsupported action {action!r}")

    created = parse_dt(str(signal.get("created_at", "")), "created_at")
    valid_until = parse_dt(str(signal.get("valid_until", "")), "valid_until")
    if valid_until <= created:
        raise ValueError("valid_until must be after created_at")

    now = datetime.now(timezone.utc)
    if now > valid_until:
        raise ValueError("signal is expired")

    risk_raw = signal.get("risk_pct", 0.0)
    try:
        risk_pct = float(risk_raw)
    except (TypeError, ValueError) as exc:
        raise ValueError("risk_pct must be numeric") from exc

    if risk_pct < 0 or risk_pct > max_risk_pct or risk_pct > 0.5:
        raise ValueError(f"risk_pct must be between 0 and {min(max_risk_pct, 0.5)}")

    if action in {"BUY", "SELL"}:
        if signal.get("entry_type") != "MARKET":
            raise ValueError("BUY/SELL require MARKET entry_type")
        for field in ("sl", "tp"):
            try:
                value = float(signal[field])
            except (KeyError, TypeError, ValueError) as exc:
                raise ValueError(f"{field} must be numeric for {action}") from exc
            if value <= 0:
                raise ValueError(f"{field} must be > 0 for {action}")
        if risk_pct <= 0:
            raise ValueError("BUY/SELL require positive risk_pct")

    if action == "MODIFY" and signal.get("sl") is None and signal.get("tp") is None:
        raise ValueError("MODIFY requires sl and/or tp")

    return action, int(created.timestamp()), int(valid_until.timestamp())


def to_bridge_line(signal: dict[str, Any], created_epoch: int, valid_epoch: int) -> str:
    def optional_number(name: str) -> str:
        value = signal.get(name)
        return "" if value is None else format(float(value), ".10g")

    fields = [
        "1",
        str(signal["id"]),
        str(signal["action"]),
        "XAUUSD",
        optional_number("sl"),
        optional_number("tp"),
        format(float(signal.get("risk_pct", 0.0)), ".10g"),
        str(created_epoch),
        str(valid_epoch),
    ]
    return "|".join(fields) + "\n"


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent), text=True)
    try:
        with os.fdopen(fd, "w", encoding="ascii", newline="\n") as fh:
            fh.write(content)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp_name, 0o600)
        os.replace(tmp_name, path)
    finally:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass


def git_pull() -> None:
    subprocess.run(
        ["git", "-C", str(ROOT), "pull", "--ff-only"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=45,
    )


def read_ack(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        return ""


def main() -> int:
    parser = argparse.ArgumentParser(description="Publish GitHub XAUUSD signals into the MT5 MQL5 file sandbox.")
    parser.add_argument("--config", required=True)
    args = parser.parse_args()

    config_path = Path(args.config)
    config = load_json(config_path)
    signal_path = ROOT / str(config.get("signal_path", "signal.json"))
    bridge_path = Path(os.path.expanduser(str(config["bridge_file"])))
    ack_path = Path(os.path.expanduser(str(config["ack_file"])))
    poll_seconds = max(5, int(config.get("poll_seconds", 30)))
    max_risk_pct = min(0.5, float(config.get("max_risk_pct", 0.5)))
    auto_git_pull = bool(config.get("auto_git_pull", True))

    last_published = ""
    last_ack = ""
    print(f"bridge ready: signal={signal_path} -> {bridge_path}", flush=True)

    while True:
        try:
            if auto_git_pull:
                git_pull()

            signal = load_json(signal_path)
            action, created_epoch, valid_epoch = validate_signal(signal, max_risk_pct)
            signal_id = str(signal["id"])

            if signal_id != last_published:
                atomic_write(bridge_path, to_bridge_line(signal, created_epoch, valid_epoch))
                last_published = signal_id
                print(f"published signal id={signal_id} action={action}", flush=True)

            ack = read_ack(ack_path)
            if ack and ack != last_ack:
                last_ack = ack
                print(f"mt5 ack: {ack}", flush=True)

        except subprocess.TimeoutExpired:
            print("ERROR git pull timed out", flush=True)
        except subprocess.CalledProcessError as exc:
            output = exc.stdout.strip() if exc.stdout else str(exc)
            print(f"ERROR git pull failed: {output}", flush=True)
        except Exception as exc:
            print(f"ERROR {type(exc).__name__}: {exc}", flush=True)

        time.sleep(poll_seconds)


if __name__ == "__main__":
    raise SystemExit(main())

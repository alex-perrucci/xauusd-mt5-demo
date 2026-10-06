#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
ALLOWED_ACTIONS = {
    "NO_TRADE", "HOLD", "STATUS",
    "BUY", "SELL", "BUY_STOP", "SELL_STOP",
    "CLOSE", "CANCEL", "MODIFY",
}


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as fh:
        return json.load(fh)


def parse_dt(value: str, field: str) -> datetime:
    dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        raise ValueError(f"{field} must be timezone-aware")
    return dt.astimezone(timezone.utc)


def validate_signal(signal: dict[str, Any], max_risk_pct: float) -> tuple[str, int, int]:
    if signal.get("schema_version") != 2:
        raise ValueError("schema_version must be 2")

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
    if datetime.now(timezone.utc) > valid_until:
        raise ValueError("signal is expired")

    try:
        risk_pct = float(signal.get("risk_pct", 0.0))
    except (TypeError, ValueError) as exc:
        raise ValueError("risk_pct must be numeric") from exc

    if risk_pct < 0 or risk_pct > max_risk_pct or risk_pct > 0.5:
        raise ValueError(f"risk_pct must be between 0 and {min(max_risk_pct, 0.5)}")

    if action in {"BUY", "SELL", "BUY_STOP", "SELL_STOP"}:
        for field in ("sl", "tp"):
            try:
                value = float(signal[field])
            except (KeyError, TypeError, ValueError) as exc:
                raise ValueError(f"{field} must be numeric for {action}") from exc
            if value <= 0:
                raise ValueError(f"{field} must be > 0 for {action}")
        if risk_pct <= 0:
            raise ValueError(f"{action} requires positive risk_pct")

    if action in {"BUY_STOP", "SELL_STOP"}:
        try:
            entry = float(signal["entry"])
        except (KeyError, TypeError, ValueError) as exc:
            raise ValueError(f"entry must be numeric for {action}") from exc
        if entry <= 0:
            raise ValueError("entry must be > 0 for pending orders")

    if action == "MODIFY" and signal.get("sl") is None and signal.get("tp") is None:
        raise ValueError("MODIFY requires sl and/or tp")

    return action, int(created.timestamp()), int(valid_until.timestamp())


def to_bridge_line(signal: dict[str, Any], created_epoch: int, valid_epoch: int) -> str:
    def optional_number(name: str) -> str:
        value = signal.get(name)
        return "" if value is None else format(float(value), ".10g")

    fields = [
        "2", str(signal["id"]), str(signal["action"]), "XAUUSD",
        optional_number("entry"), optional_number("sl"), optional_number("tp"),
        format(float(signal.get("risk_pct", 0.0)), ".10g"),
        str(created_epoch), str(valid_epoch),
    ]
    return "|".join(fields) + "\n"


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent), text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
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


def run_git(*args: str, timeout: int = 45, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(ROOT), *args],
        check=check,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=timeout,
    )


def git_pull() -> None:
    run_git("pull", "--rebase", "--autostash")


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        return ""


def nullable_number(value: str) -> float | None:
    return None if value == "" else float(value)


def nullable_int(value: str) -> int | None:
    return None if value == "" else int(value)


def parse_state_line(raw: str) -> dict[str, Any]:
    fields = raw.strip().split("|")
    if len(fields) != 23 or fields[0] != "1":
        raise ValueError(f"invalid MT5 state format: expected 23 fields, got {len(fields)}")

    server_epoch = int(fields[1]) if fields[1] else 0
    server_time = datetime.fromtimestamp(server_epoch, timezone.utc).isoformat() if server_epoch > 0 else None

    return {
        "schema_version": 1,
        "captured_at": datetime.now(timezone.utc).isoformat(),
        "server_time": server_time,
        "connected": fields[2] == "1",
        "demo": fields[3] == "1",
        "trade_allowed": fields[4] == "1",
        "symbol": fields[5],
        "bid": nullable_number(fields[6]),
        "ask": nullable_number(fields[7]),
        "managed_position": {
            "count": int(fields[8] or 0),
            "type": fields[9] or None,
            "ticket": nullable_int(fields[10]),
            "volume": nullable_number(fields[11]),
            "open_price": nullable_number(fields[12]),
            "sl": nullable_number(fields[13]),
            "tp": nullable_number(fields[14]),
            "profit": nullable_number(fields[15]),
        },
        "managed_pending_order": {
            "count": int(fields[16] or 0),
            "type": fields[17] or None,
            "ticket": nullable_int(fields[18]),
            "price": nullable_number(fields[19]),
            "sl": nullable_number(fields[20]),
            "tp": nullable_number(fields[21]),
        },
        "last_signal_id": fields[22] or None,
    }


def parse_ack(raw: str) -> dict[str, Any] | None:
    if not raw:
        return None
    fields = raw.split("|", 3)
    if len(fields) != 4:
        return {"raw": raw}
    epoch = int(fields[2]) if fields[2].isdigit() else 0
    return {
        "signal_id": fields[0],
        "status": fields[1],
        "server_time": datetime.fromtimestamp(epoch, timezone.utc).isoformat() if epoch > 0 else None,
        "message": fields[3],
    }


def structural_fingerprint(state: dict[str, Any]) -> str:
    position = state.get("managed_position") or {}
    pending = state.get("managed_pending_order") or {}
    compact = {
        "connected": state.get("connected"),
        "demo": state.get("demo"),
        "trade_allowed": state.get("trade_allowed"),
        "symbol": state.get("symbol"),
        "managed_position": {
            key: position.get(key)
            for key in ("count", "type", "ticket", "volume", "open_price", "sl", "tp")
        },
        "managed_pending_order": {
            key: pending.get(key)
            for key in ("count", "type", "ticket", "price", "sl", "tp")
        },
        "last_signal_id": state.get("last_signal_id"),
        "last_ack": state.get("last_ack"),
    }
    return hashlib.sha256(
        json.dumps(compact, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()


def publish_repo_state(repo_path: Path, payload: dict[str, Any]) -> None:
    git_pull()
    atomic_write(repo_path, json.dumps(payload, indent=2, sort_keys=True) + "\n")
    rel = repo_path.relative_to(ROOT)
    run_git("add", str(rel))

    diff = run_git("diff", "--cached", "--quiet", check=False)
    if diff.returncode == 0:
        return
    if diff.returncode != 1:
        raise RuntimeError(diff.stdout.strip() or "git diff --cached failed")

    run_git(
        "-c", "user.name=xauusd-vps",
        "-c", "user.email=xauusd-vps@users.noreply.github.com",
        "commit", "-m", "runtime: update MT5 demo state",
    )
    branch = run_git("rev-parse", "--abbrev-ref", "HEAD").stdout.strip()
    if not branch or branch == "HEAD":
        raise RuntimeError("cannot publish runtime state from detached HEAD")

    pushed = run_git("push", "origin", f"HEAD:{branch}", timeout=60, check=False)
    if pushed.returncode != 0:
        run_git("pull", "--rebase", "--autostash", timeout=60)
        pushed = run_git("push", "origin", f"HEAD:{branch}", timeout=60, check=False)
        if pushed.returncode != 0:
            raise RuntimeError(pushed.stdout.strip() or "git push failed")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Bidirectional GitHub <-> MT5 MQL5 bridge for the XAUUSD demo experiment."
    )
    parser.add_argument("--config", required=True)
    args = parser.parse_args()

    config = load_json(Path(args.config))
    signal_path = ROOT / str(config.get("signal_path", "signal.json"))
    bridge_path = Path(os.path.expanduser(str(config["bridge_file"])))
    ack_path = Path(os.path.expanduser(str(config["ack_file"])))
    state_file = Path(os.path.expanduser(str(config.get("state_file", bridge_path.with_name("state.txt")))))
    state_repo_path = ROOT / str(config.get("state_repo_path", "runtime/state.json"))
    poll_seconds = max(5, int(config.get("poll_seconds", 30)))
    state_push_seconds = max(60, int(config.get("state_push_seconds", 3600)))
    max_risk_pct = min(0.5, float(config.get("max_risk_pct", 0.5)))
    auto_git_pull = bool(config.get("auto_git_pull", True))
    auto_state_push = bool(config.get("auto_state_push", False))

    last_published = ""
    last_ack = ""
    last_state_fingerprint = ""
    last_state_push = 0.0
    print(
        f"bridge ready: signal={signal_path} -> {bridge_path}; state={state_file} -> {state_repo_path}",
        flush=True,
    )

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

            ack_raw = read_text(ack_path)
            if ack_raw and ack_raw != last_ack:
                last_ack = ack_raw
                print(f"mt5 ack: {ack_raw}", flush=True)

            state_raw = read_text(state_file)
            if auto_state_push and state_raw:
                state = parse_state_line(state_raw)
                state["last_ack"] = parse_ack(ack_raw)
                fp = structural_fingerprint(state)
                now_monotonic = time.monotonic()
                changed = fp != last_state_fingerprint
                heartbeat_due = now_monotonic - last_state_push >= state_push_seconds
                if changed or heartbeat_due:
                    publish_repo_state(state_repo_path, state)
                    last_state_fingerprint = fp
                    last_state_push = now_monotonic
                    print("published MT5 state " + ("(change)" if changed else "(heartbeat)"), flush=True)

        except subprocess.TimeoutExpired:
            print("ERROR git operation timed out", flush=True)
        except subprocess.CalledProcessError as exc:
            output = exc.stdout.strip() if exc.stdout else str(exc)
            print(f"ERROR git operation failed: {output}", flush=True)
        except Exception as exc:
            print(f"ERROR {type(exc).__name__}: {exc}", flush=True)

        time.sleep(poll_seconds)


if __name__ == "__main__":
    raise SystemExit(main())

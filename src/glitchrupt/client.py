"""Private per-request file IPC to the single macOS app instance.

Desktop images never pass through this bridge. Timeout means outcome unknown;
clients must not retry automatically because the first cue may have run.
"""
from __future__ import annotations

import json
import math
import os
import re
from pathlib import Path
import stat
import subprocess
import time
from typing import Any, Callable
import uuid

VARIANTS = {
    "classic": "Original digital crackle: balanced static and electrical ticks.",
    "fracture": "Sharper fractured crackle with brittle, splintering transients.",
    "brownout": "Lower, heavier crackle with a power-sag character.",
    "arc": "Bright electrical arcs and a rising, tearing charge.",
    "stutter": "Rhythmic chopped crackle with irregular digital dropouts.",
}
STATUSES = {"ready", "completed", "muted", "cooldown", "busy", "permission_required", "reduce_motion", "error", "waiting", "resolved", "pending"}

KEY_PATTERN = r"[A-Za-z0-9._:-]{1,160}"


class GlitchruptError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code

    def result(self) -> dict[str, Any]:
        return {"status": "error", "code": self.code, "message": str(self)}


def validate_signal(variant: str = "classic", duration_ms: int = 600,
                    volume: float = .28, sound: bool = True,
                    preview: bool = False) -> dict[str, Any]:
    if not isinstance(variant, str) or variant not in VARIANTS:
        raise GlitchruptError("invalid_argument", "variant must be one of: " + ", ".join(VARIANTS))
    if type(duration_ms) is not int or not 300 <= duration_ms <= 1000:
        raise GlitchruptError("invalid_argument", "duration_ms must be an integer from 300 to 1000")
    if type(volume) not in (float, int) or not math.isfinite(volume) or not 0 <= volume <= .5:
        raise GlitchruptError("invalid_argument", "volume must be a finite number from 0 to 0.5")
    if type(sound) is not bool or type(preview) is not bool:
        raise GlitchruptError("invalid_argument", "sound and preview must be booleans")
    return dict(variant=variant, duration_ms=duration_ms, volume=float(volume), sound=sound, preview=preview)


def validate_key(value: str, field: str = "key") -> str:
    if not isinstance(value, str) or re.fullmatch(KEY_PATTERN, value) is None:
        raise GlitchruptError("invalid_argument", field + " must contain 1–160 letters, digits, dots, underscores, colons or hyphens")
    return value


def validate_response(action: str, result: dict[str, Any]) -> None:
    """Reject malformed success payloads instead of claiming an alert is scheduled."""
    expected = {"status": "ready", "wait": "waiting", "resolve": "resolved", "pending": "pending"}
    allowed = {"error", expected[action]} if action in expected else STATUSES - {"ready", "waiting", "resolved", "pending"}
    if result["status"] not in allowed:
        raise GlitchruptError("invalid_response", "Unexpected response to " + action)
    if result["status"] == "error":
        return
    if action == "status":
        boolean_fields = ("permission", "reduce_motion", "agents_enabled", "busy")
        valid = (all(type(result.get(key)) is bool for key in boolean_fields)
                 and type(result.get("cooldown_remaining_ms")) is int and result["cooldown_remaining_ms"] >= 0
                 and isinstance(result.get("app_version"), str) and result.get("variants") == list(VARIANTS))
    elif action in {"wait", "resolve", "pending"}:
        valid = type(result.get("pending_count")) is int and 0 <= result["pending_count"] <= 256
        if action == "wait":
            valid = (valid and isinstance(result.get("key"), str)
                     and re.fullmatch(KEY_PATTERN, result["key"]) is not None
                     and result.get("repeat_interval_ms") == 900000 and type(result["repeat_interval_ms"]) is int
                     and result.get("burst_duration_ms") == 600 and type(result["burst_duration_ms"]) is int
                     and result.get("gap_ms") == 200 and type(result["gap_ms"]) is int
                     and isinstance(result.get("alert_status"), str)
                     and type(result.get("repeat")) is bool)
        elif action == "resolve":
            valid = valid and type(result.get("removed_count")) is int and 0 <= result["removed_count"] <= 256
        else:
            entries = result.get("entries")
            valid = valid and isinstance(entries, list) and len(entries) == result["pending_count"]
            if valid:
                valid = all(isinstance(entry, dict) and isinstance(entry.get("key"), str)
                            and re.fullmatch(KEY_PATTERN, entry["key"]) is not None
                            and type(entry.get("next_reminder_ms")) is int and entry["next_reminder_ms"] >= 0
                            for entry in entries)
    else:
        valid = True
    if not valid:
        raise GlitchruptError("invalid_response", "App response fields are missing or malformed.")


def discover_app() -> Path:
    configured = os.environ.get("GLITCHRUPT_APP")
    if configured:
        candidates = [Path(configured).expanduser()]
    else:
        candidates = [Path("/Applications/Glitchrupt.app"), Path.home() / "Applications/Glitchrupt.app"]
        # Source checkout; not a general search through user files.
        candidates.append(Path(__file__).resolve().parents[2] / "build/Glitchrupt.app")
    for path in candidates:
        if path.is_dir() and path.suffix == ".app":
            return path.resolve()
    raise GlitchruptError("app_not_found", "Build or install Glitchrupt.app, or set GLITCHRUPT_APP to its absolute path.")


def _open_app(app: Path, url: str | None = None) -> None:
    args = ["/usr/bin/open", "-g", "-a", str(app)]
    if url:
        args.extend([url, "--args", "--agent-mode"])
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=5, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise GlitchruptError("launch_failed", "macOS could not open Glitchrupt: " + str(exc)) from exc
    if result.returncode:
        raise GlitchruptError("launch_failed", result.stderr.strip() or "macOS refused to open Glitchrupt.")


class NativeClient:
    def __init__(self, *, request_dir: Path | None = None, app_path: Path | None = None,
                 opener: Callable[[Path, str | None], None] = _open_app,
                 timeout: float = 15, poll_interval: float = .05,
                 clock: Callable[[], float] = time.monotonic,
                 sleeper: Callable[[float], None] = time.sleep):
        self.request_dir = request_dir or Path.home() / "Library/Application Support/Glitchrupt/requests"
        self.app_path = app_path
        self.opener = opener
        self.timeout = timeout
        self.poll_interval = poll_interval
        self.clock = clock
        self.sleeper = sleeper

    def app(self) -> Path:
        return self.app_path or discover_app()

    def launch(self) -> dict[str, Any]:
        app = self.app()
        self.opener(app, None)
        return {"status": "opened", "app": str(app)}

    def status(self) -> dict[str, Any]:
        return self.request("status")

    def signal(self, variant: str = "classic", duration_ms: int = 600,
               volume: float = .28, sound: bool = True, preview: bool = False) -> dict[str, Any]:
        payload = validate_signal(variant, duration_ms, volume, sound, preview)
        return self.request("signal", **payload)

    def wait(self, key: str, variant: str = "classic", volume: float = .28,
             sound: bool = True, preview: bool = False, *, repeat: bool = True) -> dict[str, Any]:
        key = validate_key(key)
        if type(repeat) is not bool:
            raise GlitchruptError("invalid_argument", "repeat must be a boolean")
        payload = validate_signal(variant, 600, volume, sound, preview)
        payload.pop("duration_ms")
        payload["repeat"] = repeat
        result = self.request("wait", key=key, **payload)
        if result.get("status") == "waiting" and (result.get("key") != key or result.get("repeat") is not repeat):
            raise GlitchruptError("invalid_response", "The app registered a different approval key or repetition mode.")
        return result

    def resolve(self, key: str | None = None, key_prefix: str | None = None) -> dict[str, Any]:
        if (key is None) == (key_prefix is None):
            raise GlitchruptError("invalid_argument", "Provide exactly one of key or key_prefix")
        field, value = ("key", key) if key is not None else ("key_prefix", key_prefix)
        return self.request("resolve", **{field: validate_key(value, field)})

    def pending(self) -> dict[str, Any]:
        return self.request("pending")

    def _prepare_dir(self) -> None:
        # Never follow a planted symlink for the app directory or requests folder.
        for path in (self.request_dir.parent, self.request_dir):
            if path.is_symlink():
                raise GlitchruptError("unsafe_ipc_path", "The private IPC directory must not be a symbolic link.")
            path.mkdir(parents=True, exist_ok=True, mode=0o700)
            info = path.stat()
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
                raise GlitchruptError("unsafe_ipc_path", "The private IPC directory must be owned by the current user.")
            path.chmod(0o700)

    def request(self, action: str, **fields: Any) -> dict[str, Any]:
        if action not in {"status", "signal", "wait", "resolve", "pending"}:
            raise GlitchruptError("invalid_argument", "Unsupported action")
        app = self.app()
        request_id = str(uuid.uuid4())
        request = {"id": request_id, "action": action, **fields}
        target = self.request_dir / (request_id + ".request.json")
        response = self.request_dir / (request_id + ".response.json")
        temp = self.request_dir / (request_id + ".tmp")
        try:
            self._prepare_dir()
            fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as stream:
                json.dump(request, stream, allow_nan=False)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temp, target)
            self.opener(app, "glitchrupt://request/" + request_id)
            deadline = self.clock() + self.timeout
            while self.clock() < deadline:
                try:
                    info = response.lstat()
                except FileNotFoundError:
                    self.sleeper(self.poll_interval)
                    continue
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > 65536 or info.st_mode & 0o077:
                    raise GlitchruptError("invalid_response", "The app response is not a private regular JSON file.")
                # O_NOFOLLOW closes the symlink race between inspection and read.
                fd = os.open(response, os.O_RDONLY | os.O_NOFOLLOW)
                with os.fdopen(fd) as stream:
                    try:
                        result = json.load(stream)
                    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
                        raise GlitchruptError("invalid_response", "The app returned malformed JSON.") from exc
                if not isinstance(result, dict) or result.get("request_id") != request_id or result.get("status") not in STATUSES:
                    raise GlitchruptError("invalid_response", "The app returned a malformed or mismatched response.")
                validate_response(action, result)
                return result
            raise GlitchruptError("timeout", f"No app response within {self.timeout:g} seconds. The cue may have run; do not retry automatically.")
        except GlitchruptError:
            raise
        except (OSError, ValueError, TypeError) as exc:
            raise GlitchruptError("ipc_error", "Could not complete the local app request: " + str(exc)) from exc
        finally:
            for path in (temp, target, response):
                try:
                    path.unlink(missing_ok=True)
                except OSError:
                    pass

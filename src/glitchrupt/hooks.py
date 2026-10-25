"""Advisory Codex lifecycle adapter. No transcript reads or approval decisions.

Only hashed identifiers cross into native IPC. Raw tool inputs are used in memory
solely to correlate PermissionRequest with PostToolUse, then discarded.
Automatic hooks request only an initial pair because tool completion is not an
authoritative signal that the user just answered an approval.
"""
from __future__ import annotations

import hashlib
import json
import sys
from typing import Any, TextIO

from .client import GlitchruptError, NativeClient

MAX_EVENT_BYTES = 262144
CLEANUP_EVENTS = {"Interrupt", "Stop", "SessionEnd", "UserPromptSubmit"}
EVENTS = CLEANUP_EVENTS | {"PermissionRequest", "PostToolUse"}


def _identifier(event: dict[str, Any], field: str) -> str:
    value = event.get(field)
    if not isinstance(value, str) or not value.strip() or len(value) > 4096:
        raise ValueError("missing or invalid event identifier")
    return value


def session_prefix(event: dict[str, Any]) -> str:
    session = _identifier(event, "session_id")
    return "codex:" + hashlib.sha256(session.encode()).hexdigest()[:20] + ":"


def approval_key(event: dict[str, Any]) -> str:
    turn = _identifier(event, "turn_id")
    tool = _identifier(event, "tool_name")
    # Both names have been used for the same shell path in Codex integrations.
    tool = {"Bash": "bash", "exec_command": "bash", "shell_command": "bash",
            "functions.exec_command": "bash", "functions.shell_command": "bash"}.get(tool, tool)
    if "tool_input" not in event or not isinstance(event["tool_input"], (dict, str)):
        raise ValueError("missing or invalid tool input")
    canonical = json.dumps([turn, tool, event["tool_input"]], sort_keys=True,
                           separators=(",", ":"), ensure_ascii=False, allow_nan=False)
    return session_prefix(event) + hashlib.sha256(canonical.encode()).hexdigest()[:32]


def process_event(event: Any, native: NativeClient) -> None:
    if not isinstance(event, dict):
        raise ValueError("hook payload must be an object")
    name = event.get("hook_event_name")
    if name not in EVENTS:
        raise ValueError("unsupported hook event")
    if name == "PermissionRequest":
        result = native.wait(approval_key(event), repeat=False)
    elif name == "PostToolUse":
        result = native.resolve(key=approval_key(event))
    else:
        result = native.resolve(key_prefix=session_prefix(event))

    if result.get("status") == "error":
        raise GlitchruptError("native_error", "Native app rejected the advisory request")


def run_hook(*, client: NativeClient | None = None, stdin: TextIO | None = None,
             stderr: TextIO | None = None) -> int:
    """Always advisory: benign {} JSON, exit zero, no decision/control fields."""
    source = stdin if stdin is not None else sys.stdin
    errors = stderr if stderr is not None else sys.stderr
    native = client if client is not None else NativeClient(timeout=1.5)
    try:
        # Read bytes on real stdin to enforce the limit before decoding.
        stream = getattr(source, "buffer", source)
        raw = stream.read(MAX_EVENT_BYTES + 1)
        size = len(raw.encode("utf-8")) if isinstance(raw, str) else len(raw)
        if size > MAX_EVENT_BYTES:
            raise ValueError("hook event exceeds limit")
        event = json.loads(raw, parse_constant=lambda _: (_ for _ in ()).throw(ValueError("non-finite JSON")))
        process_event(event, native)
    except Exception as exc:
        # Never echo raw input or exception messages: tools may contain secrets.
        code = exc.code if isinstance(exc, GlitchruptError) else "invalid_event"
        print("Glitchrupt advisory hook skipped (" + code + "); approval behavior is unchanged.", file=errors)
    print("{}")
    return 0

"""Local tools over MCP stdio. No listener or external service."""
from __future__ import annotations

import asyncio
from typing import Annotated, Any, Literal
from pydantic import BeforeValidator, Field, StrictBool
from mcp.server import MCPServer
from mcp.types import ToolAnnotations
from . import __version__
from .client import (NativeClient, GlitchruptError, VARIANTS, KEY_PATTERN,
                     validate_chat_id, validate_claude_session_id, validate_metadata_text, validate_wait_metadata,
                     with_default_claude_session)

Variant = Literal["classic", "fracture", "brownout", "arc", "stutter"]
Duration = Annotated[int, Field(strict=True, ge=300, le=1000)]
ApprovalKey = Annotated[str, Field(strict=True, pattern="^" + KEY_PATTERN + "$", min_length=1, max_length=160)]
ChatName = Annotated[str, Field(strict=True, min_length=1, max_length=100),
                     BeforeValidator(lambda value: validate_metadata_text(value, "chat_name", 100))]
Reason = Annotated[str, Field(strict=True, min_length=1, max_length=240),
                   BeforeValidator(lambda value: validate_metadata_text(value, "reason", 240))]
ChatID = Annotated[str, Field(strict=True, pattern=r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"),
                   BeforeValidator(validate_chat_id)]
ClaudeSessionID = Annotated[str, BeforeValidator(validate_claude_session_id)]
Volume = Annotated[float, Field(strict=True, ge=0, le=.5, allow_inf_nan=False)]


def create_server(client: NativeClient | None = None) -> MCPServer:
    native = client if client is not None else NativeClient()
    server = MCPServer("Glitchrupt", version=__version__, instructions=(
        "For every user input request, first present a live structured input box in the owning chat, "
        "then register one stable key with glitchrupt_wait_for_approval in the same turn. "
        "An existing live platform approval card counts; do not duplicate it. "
        "Supply a short nonsensitive chat_name and reason, and the real canonical chat_id when available. "
        "These labels are visible on screen and kept in memory, so never include secrets. "
        "If no live input control can be created, do not leave a recurring wait registered; "
        "resolve that exact key immediately when answered, cancelled, or no longer blocked. "
        "The app repeats the user-configured attention pattern every 15 minutes while pending. "
        "Do not register ordinary completion events. Native pause and suppression apply. "
        "Never retry an effect automatically after timeout. Hooks are best-effort and do not cover all questions."))

    @server.tool(structured_output=True, annotations=ToolAnnotations(readOnlyHint=True, destructiveHint=False, openWorldHint=False))
    async def glitchrupt_status() -> dict[str, Any]:
        """Check permission, reduced motion, pause, busy state, cooldown, and installed app version. Opens app in background if needed."""
        try:
            return await asyncio.to_thread(native.status)
        except GlitchruptError as exc:
            return exc.result()

    @server.tool(structured_output=True, annotations=ToolAnnotations(readOnlyHint=True, destructiveHint=False, openWorldHint=False))
    def glitchrupt_variants() -> dict[str, Any]:
        """List five original digital-crackle sounds. Listing does not play a cue."""
        return {"variants": [{"id": key, "description": value} for key, value in VARIANTS.items()],
                "defaults": {"variant": "classic", "duration_ms": 600, "volume": .28, "sound": True, "preview": False}}

    @server.tool(structured_output=True, annotations=ToolAnnotations(readOnlyHint=False, destructiveHint=False, openWorldHint=False))
    async def glitchrupt_signal(variant: Variant = "classic", duration_ms: Duration = 600,
                             volume: Volume = .28, sound: StrictBool = True,
                             preview: StrictBool = False) -> dict[str, Any]:
        """Request one brief visual glitch with optional sound. preview=true uses a test window. Duration is 300–1000 ms, volume 0–0.5. Native pause, reduced-motion and cooldown safeguards apply. completed means playback finished; timeout means outcome unknown."""
        try:
            return await asyncio.to_thread(native.signal, variant, duration_ms, volume, sound, preview)
        except GlitchruptError as exc:
            return exc.result()

    @server.tool(structured_output=True, annotations=ToolAnnotations(readOnlyHint=False, destructiveHint=False, openWorldHint=False))
    async def glitchrupt_wait_for_approval(key: ApprovalKey, variant: Variant = "classic",
                                         volume: Volume = .28, sound: StrictBool = True,
                                         preview: StrictBool = False, chat_name: ChatName | None = None,
                                         reason: Reason | None = None, chat_id: ChatID | None = None,
                                         claude_session_id: ClaudeSessionID | None = None) -> dict[str, Any]:
        """After presenting one live input box in this chat, register its pending decision. Optional nonsensitive chat_name (100 characters), reason (240), and canonical chat_id or claude_session_id identify the banner and pending menu. Inside Claude Code, the current Claude Desktop session is detected automatically when neither chat_id nor claude_session_id is given. Chat links open only on a user click. Plays the configured attention pattern; repeats every 15 minutes until resolved. Reusing the same key is idempotent and does not replay or reset its timer. Returns registration, not completed playback."""
        try:
            metadata = with_default_claude_session(
                validate_wait_metadata(chat_name=chat_name, reason=reason, chat_id=chat_id, claude_session_id=claude_session_id))
            return await asyncio.to_thread(native.wait, key, variant, volume, sound, preview, **metadata)
        except GlitchruptError as exc:
            return exc.result()

    @server.tool(structured_output=True, annotations=ToolAnnotations(readOnlyHint=False, destructiveHint=False, openWorldHint=False))
    async def glitchrupt_resolve_approval(key: ApprovalKey | None = None,
                                         key_prefix: ApprovalKey | None = None) -> dict[str, Any]:
        """Stop pending approval reminders. Supply exactly one key, or an owned key_prefix for session cleanup. Resolve as soon as the wait is answered, cancelled, or no longer blocks work; never clear another chat's keys."""
        try:
            return await asyncio.to_thread(native.resolve, key, key_prefix)
        except GlitchruptError as exc:
            return exc.result()

    @server.tool(structured_output=True, annotations=ToolAnnotations(readOnlyHint=True, destructiveHint=False, openWorldHint=False))
    async def glitchrupt_pending_approvals() -> dict[str, Any]:
        """List pending approval keys, optional chat labels and reasons, and milliseconds to their next reminders. Does not play a cue."""
        try:
            return await asyncio.to_thread(native.pending)
        except GlitchruptError as exc:
            return exc.result()

    return server


def run_server() -> None:
    create_server().run(transport="stdio")

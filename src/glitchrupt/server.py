"""Local tools over MCP stdio. No listener or external service."""
from __future__ import annotations

import asyncio
from typing import Annotated, Any, Literal
from pydantic import Field, StrictBool
from mcp.server import MCPServer
from mcp.types import ToolAnnotations
from . import __version__
from .client import NativeClient, GlitchruptError, VARIANTS, KEY_PATTERN

Variant = Literal["classic", "fracture", "brownout", "arc", "stutter"]
Duration = Annotated[int, Field(strict=True, ge=300, le=1000)]
ApprovalKey = Annotated[str, Field(strict=True, pattern="^" + KEY_PATTERN + "$", min_length=1, max_length=160)]
Volume = Annotated[float, Field(strict=True, ge=0, le=.5, allow_inf_nan=False)]


def create_server(client: NativeClient | None = None) -> MCPServer:
    native = client if client is not None else NativeClient()
    server = MCPServer("Glitchrupt", version=__version__, instructions=(
        "For the user's agreed approval policy, register one stable key with glitchrupt_wait_for_approval before asking; "
        "resolve that exact key immediately when answered, cancelled, or no longer blocked. "
        "The app repeats 600ms + 200ms gap + 600ms every 15 minutes while pending. "
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
                                         preview: StrictBool = False) -> dict[str, Any]:
        """Register an actual wait on the user's approval. Plays two complete 600 ms glitches separated by 200 ms; repeats every 15 minutes until resolved. Reusing the same key is idempotent and does not replay or reset its timer. Returns registration, not completed playback."""
        try:
            return await asyncio.to_thread(native.wait, key, variant, volume, sound, preview)
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
        """List currently registered approval keys and milliseconds to their next reminders. Does not play a cue."""
        try:
            return await asyncio.to_thread(native.pending)
        except GlitchruptError as exc:
            return exc.result()

    return server


def run_server() -> None:
    create_server().run(transport="stdio")

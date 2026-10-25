"""Machine-readable command line; stdout is JSON (or MCP stdio only)."""
from __future__ import annotations
import argparse
import json
import sys
from . import __version__
from .client import NativeClient, GlitchruptError, VARIANTS


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="glitchrupt", description="Brief local macOS glitch cues for humans and agents.")
    p.add_argument("--version", action="version", version=__version__)
    commands = p.add_subparsers(dest="command", required=True)
    for name in ("mcp", "status", "doctor", "list", "app", "pending", "hook"):
        commands.add_parser(name)
    for name in ("signal", "preview", "wait"):
        sub = commands.add_parser(name)
        sub.add_argument("--variant", choices=VARIANTS, default="classic")
        if name == "wait":
            sub.add_argument("key")
            sub.add_argument("--preview", action="store_true")
        else:
            sub.add_argument("--duration-ms", type=int, default=600)
        sub.add_argument("--volume", type=float, default=.28)
        sub.add_argument("--silent", action="store_true", help="Do not play sound")
    sub = commands.add_parser("resolve")
    keys = sub.add_mutually_exclusive_group(required=True)
    keys.add_argument("--key")
    keys.add_argument("--key-prefix")
    return p


def main(argv: list[str] | None = None, *, client: NativeClient | None = None) -> int:
    args = parser().parse_args(argv)
    if args.command == "mcp":
        from .server import run_server
        run_server()
        return 0
    if args.command == "hook":
        from .hooks import run_hook
        return run_hook(client=client)
    native = client if client is not None else NativeClient()
    try:
        if args.command == "list":
            result = {"variants": [{"id": key, "description": value} for key, value in VARIANTS.items()]}
        elif args.command == "app":
            result = native.launch()
        elif args.command == "wait":
            result = native.wait(args.key, args.variant, args.volume, not args.silent, args.preview)
        elif args.command == "resolve":
            result = native.resolve(args.key, args.key_prefix)
        elif args.command == "pending":
            result = native.pending()
        elif args.command in {"status", "doctor"}:
            result = native.status()
        else:
            result = native.signal(args.variant, args.duration_ms, args.volume, not args.silent, args.command == "preview")
    except GlitchruptError as exc:
        result = exc.result()
    print(json.dumps(result, allow_nan=False))
    if result.get("code") == "invalid_argument":
        return 2
    return 1 if result.get("status") in {"error", "permission_required"} else 0

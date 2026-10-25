import json
import sys
import pytest
from mcp.client import Client
from mcp.client.stdio import StdioServerParameters
from glitchrupt.server import create_server
from glitchrupt.client import GlitchruptError


class NativeFake:
    def __init__(self):
        self.signals = []
    def status(self):
        return {"status": "ready", "permission": True}
    def signal(self, *args):
        self.signals.append(args)
        return {"status": "completed", "variant": args[0], "duration_ms": args[1], "mode": "preview"}


async def test_real_sdk_lists_calls_and_validates_without_coercion():
    native = NativeFake()
    async with Client(create_server(native)) as client:
        tools = (await client.list_tools()).tools
        assert {t.name for t in tools} == {"glitchrupt_status", "glitchrupt_variants", "glitchrupt_signal", "glitchrupt_wait_for_approval", "glitchrupt_resolve_approval", "glitchrupt_pending_approvals"}
        result = await client.call_tool("glitchrupt_variants", {})
        assert len(result.structured_content["variants"]) == 5
        result = await client.call_tool("glitchrupt_signal", {"variant": "arc", "preview": True})
        assert result.structured_content["status"] == "completed"
        assert native.signals == [("arc", 600, .28, True, True)]
        invalid = [{"duration_ms": True}, {"duration_ms": 600.0}, {"duration_ms": 299},
                   {"volume": True}, {"volume": .6}, {"volume": "0.2"},
                   {"variant": "../../bad"}, {"sound": 1}, {"preview": "true"}]
        for arguments in invalid:
            result = await client.call_tool("glitchrupt_signal", arguments)
            assert result.is_error, arguments
        assert len(native.signals) == 1


async def test_sdk_reports_operational_error_as_explicit_status():
    class Missing:
        def status(self):
            raise GlitchruptError("app_not_found", "Build the app")
    async with Client(create_server(Missing())) as client:
        result = await client.call_tool("glitchrupt_status")
        assert result.structured_content == {"status": "error", "code": "app_not_found", "message": "Build the app"}


async def test_actual_stdio_transport_with_injected_native_test_client():
    code = """
from glitchrupt.server import create_server
class Native:
    def status(self):
        return {"status": "ready", "permission": True}
    def signal(self, *args):
        return {"status": "completed", "variant": args[0], "duration_ms": args[1], "mode": "preview"}
create_server(Native()).run(transport="stdio")
"""
    async with Client(StdioServerParameters(command=sys.executable, args=["-c", code])) as client:
        assert len((await client.list_tools()).tools) == 6
        result = await client.call_tool("glitchrupt_signal", {"variant": "stutter", "preview": True, "sound": False})
        assert not result.is_error
        assert result.structured_content == {"status": "completed", "variant": "stutter", "duration_ms": 600, "mode": "preview"}


async def test_approval_tools_validate_keys_and_dispatch_registry_without_duration_override():
    class Registry:
        def __init__(self):
            self.calls = []
        def wait(self, *args):
            self.calls.append(("wait", args))
            return {"status": "waiting", "key": args[0]}
        def resolve(self, *args):
            self.calls.append(("resolve", args))
            return {"status": "resolved", "removed_count": 1}
        def pending(self):
            return {"status": "pending", "entries": []}
    native = Registry()
    async with Client(create_server(native)) as client:
        tools = {t.name: t for t in (await client.list_tools()).tools}
        assert "duration_ms" not in tools["glitchrupt_wait_for_approval"].input_schema["properties"]
        result = await client.call_tool("glitchrupt_wait_for_approval", {"key": "chat:one", "preview": True})
        assert result.structured_content["status"] == "waiting"
        assert native.calls[-1] == ("wait", ("chat:one", "classic", .28, True, True))
        for arguments in ({"key": "bad/path"}, {"key": "x" * 161}, {"key": "ok", "preview": 1}):
            assert (await client.call_tool("glitchrupt_wait_for_approval", arguments)).is_error
        assert len(native.calls) == 1
        result = await client.call_tool("glitchrupt_resolve_approval", {"key": "chat:one"})
        assert result.structured_content["status"] == "resolved"
        assert native.calls[-1] == ("resolve", ("chat:one", None))
        assert (await client.call_tool("glitchrupt_pending_approvals")).structured_content["entries"] == []

"""Wait requests made inside Claude Code default to the Claude Desktop session.

The default is read from CLAUDE_CODE_HOST_SESSION_ID each time a wait runs. It never
replaces an explicit claude_session_id, a Codex chat_id suppresses it, and the Codex
hook adapter never adds it.
"""
import io
import json
import pytest
from mcp.client import Client
from glitchrupt.cli import main
from glitchrupt.client import CLAUDE_HOST_SESSION_ENV, NativeClient, default_claude_session_id
from glitchrupt.hooks import run_hook
from glitchrupt.server import create_server
from test_approvals import waiting
from test_client import responder

HOST_UUID = "479ea81a-6045-4873-8458-ddc7f9a299dc"
HOST_SESSION = "local_" + HOST_UUID
OTHER_SESSION = "local_3f2a9c1e-8b7d-4e6f-9a0b-1c2d3e4f5a6b"
CHAT_ID = "01a17469-7323-7261-9be3-3965854b8643"


@pytest.fixture(autouse=True)
def no_host_session(monkeypatch):
    # Start every test without the host variable so the developer's shell cannot change results.
    monkeypatch.delenv(CLAUDE_HOST_SESSION_ENV, raising=False)


class RecordingNative:
    def __init__(self):
        self.calls = []

    def wait(self, *args, **kwargs):
        self.calls.append((args, kwargs))
        return {"status": "waiting"}

    def pending(self):
        return {"status": "pending", "pending_count": 1,
                "entries": [{"key": "task:one", "next_reminder_ms": 900000, "muted": True}]}


async def register(path, native, cli_flags=(), mcp_arguments=None):
    """Register task:one the way an agent would: through the CLI or through the MCP tool."""
    if path == "cli":
        assert main(["wait", "task:one", *cli_flags], client=native) == 0
    else:
        async with Client(create_server(native)) as client:
            result = await client.call_tool("glitchrupt_wait_for_approval", {"key": "task:one", **(mcp_arguments or {})})
            assert not result.is_error, result


def test_default_reads_only_valid_session_values(monkeypatch):
    assert default_claude_session_id({CLAUDE_HOST_SESSION_ENV: HOST_SESSION}) == HOST_SESSION
    monkeypatch.setenv(CLAUDE_HOST_SESSION_ENV, OTHER_SESSION)
    assert default_claude_session_id() == OTHER_SESSION
    assert default_claude_session_id({}) is None
    assert default_claude_session_id({CLAUDE_HOST_SESSION_ENV: HOST_SESSION + "?x=1"}) is None
    assert default_claude_session_id({CLAUDE_HOST_SESSION_ENV: 42}) is None
    # Never raises, even when the environment is not a mapping at all.
    assert default_claude_session_id(object()) is None


@pytest.mark.parametrize("path", ["cli", "mcp"])
async def test_valid_host_session_is_used_when_no_chat_is_named(path, monkeypatch):
    monkeypatch.setenv(CLAUDE_HOST_SESSION_ENV, HOST_SESSION)
    native = RecordingNative()
    await register(path, native)
    assert native.calls == [(("task:one", "classic", .28, True, False), {"claude_session_id": HOST_SESSION})]


@pytest.mark.parametrize("path", ["cli", "mcp"])
async def test_chat_name_alone_still_gets_host_session(path, monkeypatch):
    monkeypatch.setenv(CLAUDE_HOST_SESSION_ENV, HOST_SESSION)
    native = RecordingNative()
    await register(path, native, cli_flags=["--chat-name", "Android"], mcp_arguments={"chat_name": "Android"})
    assert native.calls[-1][1] == {"chat_name": "Android", "claude_session_id": HOST_SESSION}


@pytest.mark.parametrize("path", ["cli", "mcp"])
async def test_explicit_claude_session_wins_over_host_session(path, monkeypatch):
    monkeypatch.setenv(CLAUDE_HOST_SESSION_ENV, HOST_SESSION)
    native = RecordingNative()
    await register(path, native, cli_flags=["--claude-session-id", OTHER_SESSION],
                   mcp_arguments={"claude_session_id": OTHER_SESSION})
    assert native.calls[-1][1] == {"claude_session_id": OTHER_SESSION}


@pytest.mark.parametrize("path", ["cli", "mcp"])
async def test_chat_id_suppresses_host_session(path, monkeypatch):
    monkeypatch.setenv(CLAUDE_HOST_SESSION_ENV, HOST_SESSION)
    native = RecordingNative()
    await register(path, native, cli_flags=["--chat-id", CHAT_ID], mcp_arguments={"chat_id": CHAT_ID})
    assert native.calls[-1][1] == {"chat_id": CHAT_ID}


@pytest.mark.parametrize("path", ["cli", "mcp"])
@pytest.mark.parametrize("value", [None, "", HOST_UUID, "local_" + HOST_UUID.upper(), "local_not-a-uuid",
                                   "claude://claude.ai/epitaxy/" + HOST_SESSION])
async def test_missing_or_invalid_host_session_is_ignored_without_error(path, value, monkeypatch):
    if value is not None:
        monkeypatch.setenv(CLAUDE_HOST_SESSION_ENV, value)
    native = RecordingNative()
    await register(path, native)
    assert native.calls[-1][1] == {}


def test_cli_invalid_explicit_claude_session_is_rejected_not_replaced(monkeypatch, tmp_path, capsys):
    monkeypatch.setenv(CLAUDE_HOST_SESSION_ENV, HOST_SESSION)
    native = NativeClient(app_path=tmp_path, opener=lambda *args: pytest.fail("invalid metadata opened app"))
    assert main(["wait", "task:one", "--claude-session-id", CHAT_ID], client=native) == 2
    assert json.loads(capsys.readouterr().out)["code"] == "invalid_argument"


async def test_mcp_invalid_explicit_claude_session_is_rejected_not_replaced(monkeypatch):
    monkeypatch.setenv(CLAUDE_HOST_SESSION_ENV, HOST_SESSION)
    native = RecordingNative()
    async with Client(create_server(native)) as client:
        result = await client.call_tool("glitchrupt_wait_for_approval", {"key": "task:one", "claude_session_id": CHAT_ID})
    assert result.is_error
    assert native.calls == []


@pytest.mark.parametrize("path", ["cli", "mcp"])
async def test_host_session_reaches_the_app_request(path, monkeypatch, tmp_path):
    monkeypatch.setenv(CLAUDE_HOST_SESSION_ENV, HOST_SESSION)
    directory = tmp_path / "Glitchrupt/requests"
    bodies = []
    def respond(rid, body):
        bodies.append(body)
        return waiting(rid, body)
    native = NativeClient(request_dir=directory, app_path=tmp_path, opener=responder(directory, respond))
    await register(path, native)
    assert bodies[-1]["claude_session_id"] == HOST_SESSION
    assert "chat_id" not in bodies[-1]


def test_codex_hook_never_takes_host_session(monkeypatch, tmp_path):
    monkeypatch.setenv(CLAUDE_HOST_SESSION_ENV, HOST_SESSION)
    directory = tmp_path / "Glitchrupt/requests"
    bodies = []
    def respond(rid, body):
        bodies.append(body)
        return waiting(rid, body)
    native = NativeClient(request_dir=directory, app_path=tmp_path, opener=responder(directory, respond))
    event = {"hook_event_name": "PermissionRequest", "session_id": "codex-session", "turn_id": "turn-1",
             "tool_name": "Bash", "tool_input": {"command": "echo hello"}}
    assert run_hook(client=native, stdin=io.StringIO(json.dumps(event)), stderr=io.StringIO()) == 0
    assert bodies and not {"claude_session_id", "chat_id"} & bodies[-1].keys()


async def test_mcp_pending_output_keeps_muted_flag():
    async with Client(create_server(RecordingNative())) as client:
        result = await client.call_tool("glitchrupt_pending_approvals")
    assert result.structured_content["entries"] == [{"key": "task:one", "next_reminder_ms": 900000, "muted": True}]


def test_cli_pending_output_keeps_muted_flag(capsys):
    assert main(["pending"], client=RecordingNative()) == 0
    assert json.loads(capsys.readouterr().out)["entries"][0]["muted"] is True

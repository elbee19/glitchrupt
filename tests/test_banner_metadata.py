"""Banner labels share the same bounds through IPC, CLI and MCP."""
import json
import pytest
from mcp.client import Client
from glitchrupt.cli import main
from glitchrupt.client import CLAUDE_HOST_SESSION_ENV, NativeClient, GlitchruptError, validate_wait_metadata
from glitchrupt.server import create_server
from test_client import responder
from test_approvals import waiting

CHAT_ID = "01a17469-7323-7261-9be3-3965854b8643"


@pytest.fixture(autouse=True)
def isolated_host_session(monkeypatch):
    # Claude Code exports its Desktop session to tests run inside it; these tests assert exact metadata.
    monkeypatch.delenv(CLAUDE_HOST_SESSION_ENV, raising=False)


def test_metadata_trims_and_counts_unicode_codepoints():
    assert validate_wait_metadata(chat_name="  Android ⚡  ", reason=" Approve test ", chat_id=CHAT_ID) == {
        "chat_name": "Android ⚡", "reason": "Approve test", "chat_id": CHAT_ID}
    assert validate_wait_metadata(chat_name="⚡" * 100, reason="é" * 240)["chat_name"] == "⚡" * 100
    # A multi-scalar grapheme counts each scalar, as Swift unicodeScalars does.
    assert validate_wait_metadata(chat_name="e\u0301" * 50)["chat_name"] == "e\u0301" * 50
    assert validate_wait_metadata() == {}


@pytest.mark.parametrize("kwargs", [
    {"chat_name": "⚡" * 101}, {"reason": "é" * 241}, {"chat_name": "e\u0301" * 51},
    {"chat_name": "   "}, {"reason": "\u2003"}, {"chat_name": True}, {"reason": 5}, {"chat_name": "\ud800"}, {"reason": "\udfff"},
    *({"chat_name": "label" + chr(code)} for code in [0, 9, 10, 13, 31, 127, 128, 159, 0x2028, 0x2029]),
    {"chat_id": CHAT_ID.upper()}, {"chat_id": CHAT_ID.replace("-", "")},
    {"chat_id": "codex://threads/" + CHAT_ID}, {"chat_id": "https://example.com"},
    {"chat_id": "{" + CHAT_ID + "}"}, {"chat_id": True}, {"chat_id": "invalid"},
])
def test_invalid_metadata_fails_before_opening_the_app(kwargs, tmp_path):
    client = NativeClient(app_path=tmp_path, opener=lambda *args: pytest.fail("invalid metadata opened app"))
    with pytest.raises(GlitchruptError) as error:
        client.wait("task:one", **kwargs)
    assert error.value.code == "invalid_argument"


def test_wait_ipc_forwards_only_supplied_normalized_metadata(tmp_path):
    directory = tmp_path / "Glitchrupt/requests"
    bodies = []
    def respond(rid, body):
        bodies.append(body)
        return waiting(rid, body)
    native = NativeClient(request_dir=directory, app_path=tmp_path, opener=responder(directory, respond))
    native.wait("old:caller")
    assert not {"chat_name", "reason", "chat_id"} & bodies[-1].keys()
    native.wait("task:one", chat_name=" Android ", reason="Approve guest run", chat_id=CHAT_ID)
    assert {key: bodies[-1][key] for key in ("chat_name", "reason", "chat_id")} == {
        "chat_name": "Android", "reason": "Approve guest run", "chat_id": CHAT_ID}


@pytest.mark.parametrize("metadata", [{"chat_name": "Android", "reason": "Approve", "chat_id": CHAT_ID}, {}])
def test_pending_response_tolerates_valid_optional_metadata(metadata, tmp_path):
    directory = tmp_path / "Glitchrupt/requests"
    def respond(rid, body):
        return {"status": "pending", "request_id": rid, "pending_count": 1,
                "entries": [{"key": "task:one", "next_reminder_ms": 900000, **metadata}]}
    native = NativeClient(request_dir=directory, app_path=tmp_path, opener=responder(directory, respond))
    assert native.pending()["entries"][0] == {"key": "task:one", "next_reminder_ms": 900000, **metadata}


@pytest.mark.parametrize("extra", [{"muted": True}, {"muted": False}, {}])
def test_pending_response_passes_muted_flag_through(extra, tmp_path):
    directory = tmp_path / "Glitchrupt/requests"
    def respond(rid, body):
        return {"status": "pending", "request_id": rid, "pending_count": 1,
                "entries": [{"key": "task:one", "next_reminder_ms": 900000, **extra}]}
    native = NativeClient(request_dir=directory, app_path=tmp_path, opener=responder(directory, respond))
    assert native.pending()["entries"][0] == {"key": "task:one", "next_reminder_ms": 900000, **extra}


@pytest.mark.parametrize("metadata", [{"chat_name": " "}, {"chat_id": "https://example.com"}, {"reason": None}])
def test_pending_response_rejects_malformed_metadata(metadata, tmp_path):
    directory = tmp_path / "Glitchrupt/requests"
    def respond(rid, body):
        return {"status": "pending", "request_id": rid, "pending_count": 1,
                "entries": [{"key": "task:one", "next_reminder_ms": 900000, **metadata}]}
    native = NativeClient(request_dir=directory, app_path=tmp_path, opener=responder(directory, respond))
    with pytest.raises(GlitchruptError) as error:
        native.pending()
    assert error.value.code == "invalid_response"


class MetadataNative:
    def __init__(self):
        self.calls = []
    def wait(self, *args, **kwargs):
        self.calls.append((args, kwargs))
        return {"status": "waiting"}


def test_cli_forwards_metadata_flags_without_changing_legacy_call(capsys):
    native = MetadataNative()
    assert main(["wait", "task:one", "--chat-name", "Android", "--reason", "Approve test",
                 "--chat-id", CHAT_ID], client=native) == 0
    assert native.calls[-1] == (("task:one", "classic", .28, True, False), {
        "chat_name": "Android", "reason": "Approve test", "chat_id": CHAT_ID})
    assert json.loads(capsys.readouterr().out)["status"] == "waiting"
    assert main(["wait", "old:caller"], client=native) == 0
    assert native.calls[-1][1] == {}


async def test_sdk_exposes_bounds_and_forwards_labels_without_breaking_old_clients():
    native = MetadataNative()
    async with Client(create_server(native)) as client:
        tools = {tool.name: tool for tool in (await client.list_tools()).tools}
        properties = tools["glitchrupt_wait_for_approval"].input_schema["properties"]
        assert properties["chat_name"]["anyOf"][0]["maxLength"] == 100
        assert properties["reason"]["anyOf"][0]["maxLength"] == 240
        valid = {"key": "task:one", "chat_name": " Android ⚡ ", "reason": "Approve test", "chat_id": CHAT_ID}
        result = await client.call_tool("glitchrupt_wait_for_approval", valid)
        assert not result.is_error
        assert native.calls[-1] == (("task:one", "classic", .28, True, False), {
            "chat_name": "Android ⚡", "reason": "Approve test", "chat_id": CHAT_ID})
        result = await client.call_tool("glitchrupt_wait_for_approval", {"key": "old:caller"})
        assert not result.is_error and native.calls[-1][1] == {}
        before = len(native.calls)
        for invalid in ({"chat_name": "a" * 101}, {"reason": "a" * 241}, {"chat_id": "bad"},
                        {"chat_name": "\nAndroid"}, {"reason": True}, {"chat_id": CHAT_ID.upper()},
                        {"chat_name": "\u2003"}):
            result = await client.call_tool("glitchrupt_wait_for_approval", {"key": "task:invalid", **invalid})
            assert result.is_error or result.structured_content.get("status") == "error", invalid
        assert len(native.calls) == before


def test_cli_rejects_invalid_metadata_before_native_launch(tmp_path, capsys):
    native = NativeClient(app_path=tmp_path, opener=lambda *args: pytest.fail("invalid metadata opened app"))
    assert main(["wait", "task:one", "--chat-id", "https://example.com"], client=native) == 2
    result = json.loads(capsys.readouterr().out)
    assert result["code"] == "invalid_argument"


def test_claude_session_id_is_distinct_and_strict():
    cid = 'local_' + CHAT_ID
    assert validate_wait_metadata(claude_session_id=cid) == {'claude_session_id': cid}
    for bad in [CHAT_ID, 'local_' + CHAT_ID.upper(), 'local_' + CHAT_ID + '?x=1', 'claude://claude.ai/epitaxy/' + cid]:
        with pytest.raises(GlitchruptError):
            validate_wait_metadata(claude_session_id=bad)
    with pytest.raises(GlitchruptError):
        validate_wait_metadata(chat_id=CHAT_ID, claude_session_id=cid)


def test_cli_forwards_claude_session(capsys):
    native = MetadataNative()
    assert main(['wait', 'task:one', '--claude-session-id', 'local_' + CHAT_ID], client=native) == 0
    assert native.calls[-1][1]['claude_session_id'] == 'local_' + CHAT_ID

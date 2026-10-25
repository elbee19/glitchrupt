import io
import json
import pytest
from glitchrupt.cli import main
from glitchrupt.client import NativeClient, GlitchruptError
from glitchrupt.hooks import MAX_EVENT_BYTES, approval_key, session_prefix, run_hook
from test_client import responder


def waiting(rid, body):
    assert "duration_ms" not in body
    return dict(status="waiting", request_id=rid, key=body["key"], pending_count=1,
                repeat_interval_ms=900000, burst_duration_ms=600, gap_ms=200, alert_status="queued", repeat=body.get("repeat", True))


def test_wait_passes_fixed_policy_and_resolve_pending_contracts(tmp_path):
    directory = tmp_path / "Glitchrupt/requests"
    client = NativeClient(request_dir=directory, app_path=tmp_path, opener=responder(directory, waiting))
    assert client.wait("chat:one", "fracture", .1, False, True)["status"] == "waiting"
    client.opener = responder(directory, lambda rid, body: dict(status="resolved", request_id=rid, removed_count=1, pending_count=0))
    assert client.resolve(key_prefix="chat:")["removed_count"] == 1
    client.opener = responder(directory, lambda rid, body: dict(status="pending", request_id=rid, pending_count=1,
                               entries=[dict(key="chat:one", next_reminder_ms=899999)]))
    assert client.pending()["entries"][0]["key"] == "chat:one"


@pytest.mark.parametrize("kwargs", [dict(key=""), dict(key="x" * 161), dict(key="bad/path"), dict(key=True), dict(key="ok", volume=True), dict(key="ok", repeat=1)])
def test_invalid_wait_never_opens_app(kwargs, tmp_path):
    client = NativeClient(app_path=tmp_path, opener=lambda *a: pytest.fail("invalid wait opened app"))
    with pytest.raises(GlitchruptError):
        client.wait(**kwargs)


@pytest.mark.parametrize("kwargs", [{}, dict(key="one", key_prefix="two"), dict(key_prefix="../")])
def test_resolve_requires_exactly_one_safe_selector(kwargs):
    with pytest.raises(GlitchruptError):
        NativeClient().resolve(**kwargs)


@pytest.mark.parametrize("change", [dict(repeat_interval_ms=300000), dict(gap_ms=0), dict(burst_duration_ms=1000), dict(pending_count=True), dict(key="other"), dict(alert_status=None), dict(repeat=False)])
def test_invalid_registration_response_rejected(change, tmp_path):
    directory = tmp_path / "Glitchrupt/requests"
    def result(rid, body):
        value = waiting(rid, body)
        value.update(change)
        return value
    client = NativeClient(request_dir=directory, app_path=tmp_path, opener=responder(directory, result))
    with pytest.raises(GlitchruptError):
        client.wait("chat:one")


class Registry:
    def __init__(self):
        self.calls = []
        self.keys = set()
        self.pulses = 0
    def wait(self, key, *args, **kwargs):
        self.calls.append(("wait", key, args))
        self.wait_options = kwargs
        if key not in self.keys:
            self.keys.add(key)
            self.pulses += 1
        return {"status": "waiting"}
    def resolve(self, key=None, key_prefix=None):
        self.calls.append(("resolve", key, key_prefix))
        self.keys = {item for item in self.keys if item != key and not (key_prefix and item.startswith(key_prefix))}
        return {"status": "resolved"}
    def pending(self):
        return {"status": "pending", "pending_count": len(self.keys)}


def event(name="PermissionRequest", **fields):
    return dict(hook_event_name=name, session_id="session-private", turn_id="turn-1", tool_name="Bash",
                tool_input={"command": "private secret payload", "cwd": "/private"}, **fields)


def hook(payload, registry):
    errors = io.StringIO()
    assert run_hook(client=registry, stdin=io.StringIO(json.dumps(payload)), stderr=errors) == 0
    return errors.getvalue()


def test_hook_correlation_is_canonical_private_and_idempotent(capsys):
    registry = Registry()
    request = event()
    assert hook(request, registry) == ""
    assert hook(request, registry) == ""
    assert registry.pulses == 1
    assert registry.wait_options == {"repeat": False}
    key = next(iter(registry.keys))
    assert key.startswith("codex:") and "session-private" not in key and "secret" not in key
    post = event("PostToolUse", tool_use_id="only-present-in-post", tool_response={"anything": "private"})
    post["tool_name"] = "exec_command"
    post["tool_input"] = {"cwd": "/private", "command": "private secret payload"}
    assert hook(post, registry) == ""
    assert not registry.keys
    assert set(capsys.readouterr().out.splitlines()) == {"{}"}


def test_keys_distinguish_sessions_turns_and_inputs():
    base = event()
    for field, value in (("session_id", "other"), ("turn_id", "other"), ("tool_input", {"command": "different"})):
        changed = {**base, field: value}
        assert approval_key(changed) != approval_key(base)
    assert session_prefix(base) == session_prefix({**base, "turn_id": "other"})


@pytest.mark.parametrize("name", ["Interrupt", "Stop", "SessionEnd", "UserPromptSubmit"])
def test_cleanup_only_resolves_its_session(name):
    registry = Registry()
    hook(event(), registry)
    other = {**event(), "session_id": "another-session"}
    hook(other, registry)
    hook({"hook_event_name": name, "session_id": "session-private"}, registry)
    assert registry.keys == {approval_key(other)}


@pytest.mark.parametrize("payload", [[], {}, {"hook_event_name": "PermissionRequest", "session_id": "s"},
    {"hook_event_name": "Other", "session_id": "s"}, {"hook_event_name": "Stop", "session_id": ""}])
def test_malformed_hook_fails_open_without_output_or_raw_input(payload, capsys):
    registry = Registry()
    assert "skipped" in hook(payload, registry)
    assert registry.calls == []
    assert set(capsys.readouterr().out.splitlines()) == {"{}"}


def test_hook_bounded_invalid_json_and_native_failure_are_advisory(capsys):
    class Missing:
        def wait(self, *args, **kwargs):
            raise GlitchruptError("timeout", "SECRET must never be echoed")
    errors = io.StringIO()
    assert run_hook(client=Missing(), stdin=io.StringIO(json.dumps(event())), stderr=errors) == 0
    assert "timeout" in errors.getvalue() and "SECRET" not in errors.getvalue()
    for raw in ("{bad", "x" * (MAX_EVENT_BYTES + 1), '{"hook_event_name": NaN}'):
        assert run_hook(client=Registry(), stdin=io.StringIO(raw), stderr=io.StringIO()) == 0
    assert set(capsys.readouterr().out.splitlines()) == {"{}"}


def test_cli_registry_dispatch_is_json(capsys):
    registry = Registry()
    assert main(["wait", "task:one", "--variant", "arc", "--silent", "--preview"], client=registry) == 0
    assert registry.calls[-1] == ("wait", "task:one", ("arc", .28, False, True))
    assert json.loads(capsys.readouterr().out)["status"] == "waiting"
    assert main(["pending"], client=registry) == 0
    assert json.loads(capsys.readouterr().out)["pending_count"] == 1
    assert main(["resolve", "--key", "task:one"], client=registry) == 0
    assert json.loads(capsys.readouterr().out)["status"] == "resolved"


def test_native_hook_error_status_is_advisory(capsys):
    class Reject:
        def wait(self, *args, **kwargs):
            return {"status": "error", "message": "private native detail"}
    errors = io.StringIO()
    assert run_hook(client=Reject(), stdin=io.StringIO(json.dumps(event())), stderr=errors) == 0
    assert "native_error" in errors.getvalue() and "private native detail" not in errors.getvalue()
    assert set(capsys.readouterr().out.splitlines()) == {"{}"}


def test_each_hook_emits_exactly_one_benign_json_object(capsys):
    for raw in (json.dumps(event()), "malformed JSON"):
        assert run_hook(client=Registry(), stdin=io.StringIO(raw), stderr=io.StringIO()) == 0
        assert capsys.readouterr().out == "{}\n"


def test_native_internal_repeat_flag_is_sent_and_defaults_to_true(tmp_path):
    directory = tmp_path / "Glitchrupt/requests"
    values = []
    def registration(rid, body):
        values.append(body["repeat"])
        return waiting(rid, body)
    client = NativeClient(request_dir=directory, app_path=tmp_path, opener=responder(directory, registration))
    client.wait("manual:repeat")
    client.wait("hook:once", repeat=False)
    assert values == [True, False]

import json
import os
from pathlib import Path
import subprocess
import pytest
from glitchrupt.client import NativeClient, GlitchruptError, VARIANTS, validate_signal, discover_app, _open_app
from glitchrupt.cli import main


def ready(request_id):
    return dict(status="ready", request_id=request_id, permission=True, reduce_motion=False,
                agents_enabled=True, busy=False, cooldown_remaining_ms=0, app_version="0.1.0", variants=list(VARIANTS))


def responder(directory, result=None):
    def respond(app, url):
        request_id = url.rsplit("/", 1)[1]
        request = directory / (request_id + ".request.json")
        assert request.stat().st_mode & 0o777 == 0o600
        assert directory.stat().st_mode & 0o777 == 0o700
        body = json.loads(request.read_text())
        assert body["id"] == request_id
        response = directory / (request_id + ".response.json")
        data = ready(request_id) if result is None else result(request_id, body)
        response.write_text(json.dumps(data))
        response.chmod(0o600)
    return respond


def test_private_atomic_status_and_cleanup(tmp_path):
    directory = tmp_path / "Glitchrupt/requests"
    client = NativeClient(request_dir=directory, app_path=tmp_path, opener=responder(directory))
    assert client.status()["status"] == "ready"
    assert list(directory.iterdir()) == []


def test_signal_waits_for_response_and_passes_exact_settings(tmp_path):
    directory = tmp_path / "Glitchrupt/requests"
    def completed(request_id, body):
        assert body == dict(id=request_id, action="signal", variant="arc", duration_ms=600,
                            volume=.2, sound=False, preview=True)
        return dict(status="completed", request_id=request_id, variant="arc", duration_ms=600, mode="preview")
    client = NativeClient(request_dir=directory, app_path=tmp_path, opener=responder(directory, completed))
    assert client.signal("arc", 600, .2, False, True)["status"] == "completed"


@pytest.mark.parametrize("result", [lambda rid, body: {"status": "completed", "request_id": "wrong"},
    lambda rid, body: {"status": "invented", "request_id": rid},
    lambda rid, body: [], lambda rid, body: {"status": "ready", "request_id": rid}])
def test_invalid_native_responses(tmp_path, result):
    directory = tmp_path / "Glitchrupt/requests"
    client = NativeClient(request_dir=directory, app_path=tmp_path, opener=responder(directory, result))
    with pytest.raises(GlitchruptError, match="malformed|mismatched|missing"):
        client.status()
    assert not list(directory.iterdir())


def test_timeout_does_not_retry_and_cleans_request(tmp_path):
    opened = []
    ticks = [0.0]
    def sleep(seconds):
        ticks[0] += seconds
    client = NativeClient(request_dir=tmp_path / "Glitchrupt/requests", app_path=tmp_path,
                          opener=lambda app, url: opened.append(url), timeout=.1,
                          clock=lambda: ticks[0], sleeper=sleep)
    with pytest.raises(GlitchruptError, match="do not retry automatically") as err:
        client.signal()
    assert err.value.code == "timeout"
    assert len(opened) == 1
    assert not list(client.request_dir.iterdir())


def test_launch_failure_cleans_request(tmp_path):
    def fail(app, url):
        raise GlitchruptError("launch_failed", "LaunchServices failed")
    client = NativeClient(request_dir=tmp_path / "Glitchrupt/requests", app_path=tmp_path, opener=fail)
    with pytest.raises(GlitchruptError):
        client.signal()
    assert not list(client.request_dir.iterdir())


def test_response_symlink_rejected(tmp_path):
    directory = tmp_path / "Glitchrupt/requests"
    def symlink(app, url):
        target = directory / (url.rsplit("/", 1)[1] + ".response.json")
        target.symlink_to(tmp_path / "elsewhere")
    client = NativeClient(request_dir=directory, app_path=tmp_path, opener=symlink)
    with pytest.raises(GlitchruptError, match="private regular"):
        client.status()


def test_directory_symlink_rejected(tmp_path):
    (tmp_path / "Glitchrupt").symlink_to(tmp_path)
    client = NativeClient(request_dir=tmp_path / "Glitchrupt/requests", app_path=tmp_path, opener=lambda *a: None)
    with pytest.raises(GlitchruptError, match="symbolic link"):
        client.status()


@pytest.mark.parametrize("kwargs", [dict(duration_ms=True), dict(duration_ms=299), dict(duration_ms=1001),
    dict(duration_ms=600.0), dict(volume=True), dict(volume=float("nan")), dict(volume=float("inf")),
    dict(volume=-.1), dict(volume=.51), dict(variant="../../fake"), dict(sound=1), dict(preview="false")])
def test_invalid_signal_cannot_open_app(kwargs, tmp_path):
    client = NativeClient(app_path=tmp_path, opener=lambda *a: pytest.fail("invalid input launched app"))
    with pytest.raises(GlitchruptError):
        client.signal(**kwargs)


def test_open_uses_single_app_background_launch_and_no_shell(monkeypatch, tmp_path):
    calls = []
    monkeypatch.setattr(subprocess, "run", lambda args, **kw: calls.append((args, kw)) or subprocess.CompletedProcess(args, 0))
    _open_app(tmp_path / "Glitchrupt.app", "glitchrupt://request/id")
    args, kw = calls[0]
    assert args == ["/usr/bin/open", "-g", "-a", str(tmp_path / "Glitchrupt.app"), "glitchrupt://request/id", "--args", "--agent-mode"]
    assert "shell" not in kw and "-n" not in args


def test_explicit_missing_app_does_not_fall_back(monkeypatch, tmp_path):
    monkeypatch.setenv("GLITCHRUPT_APP", str(tmp_path / "missing.app"))
    with pytest.raises(GlitchruptError) as err:
        discover_app()
    assert err.value.code == "app_not_found"


def test_cli_suppression_and_errors_are_json(capsys):
    class Fake:
        def status(self):
            return {"status": "cooldown", "cooldown_remaining_ms": 42}
        def signal(self, *args):
            raise GlitchruptError("invalid_argument", "bad duration")
    assert main(["status"], client=Fake()) == 0
    assert json.loads(capsys.readouterr().out)["status"] == "cooldown"
    assert main(["signal"], client=Fake()) == 2
    assert json.loads(capsys.readouterr().out)["code"] == "invalid_argument"


def test_malformed_json_is_invalid_response(tmp_path):
    directory = tmp_path / "Glitchrupt/requests"
    def malformed(app, url):
        response = directory / (url.rsplit("/", 1)[1] + ".response.json")
        response.write_text("{bad json")
        response.chmod(0o600)
    client = NativeClient(request_dir=directory, app_path=tmp_path, opener=malformed)
    with pytest.raises(GlitchruptError) as err:
        client.status()
    assert err.value.code == "invalid_response"
    assert not list(directory.iterdir())

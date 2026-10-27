"""`claude -p` ohne Konsolenfenster: In der Windows-App (ohne eigene Konsole) oeffnete jeder KI-Aufruf ein Terminal
"claude" (27.10.2026). Unter Windows bekommt der Unterprozess CREATE_NO_WINDOW und ein verstecktes Startfenster."""
import subprocess
import sys


def test_no_console_flags_only_on_windows(monkeypatch):
    from app import ai
    monkeypatch.setattr(sys, "platform", "linux")
    assert ai.no_console() == {}
    if hasattr(subprocess, "CREATE_NO_WINDOW"):
        monkeypatch.setattr(sys, "platform", "win32")
        kw = ai.no_console()
        assert kw["creationflags"] == subprocess.CREATE_NO_WINDOW
        assert kw["startupinfo"].dwFlags & subprocess.STARTF_USESHOWWINDOW and kw["startupinfo"].wShowWindow == subprocess.SW_HIDE


def test_ask_passes_the_flags_to_the_subprocess(monkeypatch, tmp_path):
    from app import ai
    monkeypatch.setattr(ai, "_claude_bin", lambda: "claude")
    monkeypatch.setattr(ai, "LOG_DIR", tmp_path)
    monkeypatch.setattr(ai, "no_console", lambda: {"creationflags": 123})
    seen = {}

    class Proc:
        returncode, stdout, stderr = 0, '{"result": "ok"}', ""

    def run(cmd, **kw):
        seen.update(kw)
        return Proc()
    monkeypatch.setattr(subprocess, "run", run)
    assert ai.ask("Frage") == "ok"
    assert seen["creationflags"] == 123 and seen["shell"] is False

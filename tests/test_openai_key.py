"""Eigenes ChatGPT per OpenAI-API-Schluessel (app/openai_key.py, 08.11.2026): Regeln wie auf dem iPad, Ablage nur auf dem PC
(nie im Zustand, nie in Antworten), Einwilligung vor dem Speichern, Pruefung gegen GET /v1/models (Attrappe), Weg der KI
(ai_relay.source), Endpunkte, im Dienst aus. Dazu: "Mit ChatGPT anmelden" ist ohne Schalter aus."""
import json

import pytest
from conftest import asgi_call

from app import ai, ai_relay, chatgpt_login, config, openai_key as ok, token_store

KEY = "sk-test-abcdefghijklmnopqrstuvwxyz0123"
CATALOG = {"data": [{"id": "gpt-4o"}, {"id": "gpt-4o-mini"}, {"id": "o3-mini"}, {"id": "gpt-4o-mini-tts"}, {"id": "text-embedding-3-small"},
                    {"id": "gpt-image-1"}, {"id": "whisper-1"}]}


@pytest.fixture
def local(monkeypatch, tmp_path):
    monkeypatch.setattr(config, "MODE", "local")
    monkeypatch.delenv(chatgpt_login.ENABLED_ENV, raising=False)
    monkeypatch.delenv("LERNAPP_AI_CLI", raising=False)
    monkeypatch.setattr(ok, "state_path", lambda: tmp_path / "openai-key.json")
    ok.use_key_store(token_store.MemoryStore())
    monkeypatch.setattr(ok, "http_get_json", lambda url, bearer: pytest.fail(f"unerwarteter Aufruf {url}"))
    yield ok
    ok.use_key_store(None)


def _j(res):
    st, _, body = res
    return st, json.loads(body or b"{}")


def test_rules_like_the_ipad(local):
    assert ok.normalize("  " + KEY + " ") == KEY
    assert ok.normalize("abc") is None and ok.normalize("sk-kurz") is None and ok.normalize("sk-mit leer zeichen" + "x" * 20) is None
    assert ok.normalize("sk-" + "a" * 398) is None and ok.normalize("sk-ä" + "a" * 30) is None
    assert ok.masked(KEY) == "sk-…0123" and ok.masked("") == ""
    assert ok.is_chat_model("gpt-4o") and ok.is_chat_model("o3-mini") and not ok.is_chat_model("gpt-4o-mini-tts")
    assert not ok.is_chat_model("text-embedding-3-small") and not ok.is_chat_model("chatgpt-4o-latest")
    assert ok.chat_models(ok.model_ids(CATALOG)) == ["gpt-4o-mini", "o3-mini", "gpt-4o"]
    assert ok.pick_default(["gpt-4o", "gpt-4o-mini"]) == "gpt-4o-mini"
    assert ok.pick_default(["gpt-5-mini", "gpt-4.1-mini", "gpt-4o-mini-2024-07-18", "gpt-4o"]) == "gpt-5-mini"
    assert ok.pick_default(["gpt-4o", "o3"]) == "gpt-4o" and ok.pick_default([]) is None


def test_chatgpt_sign_in_is_off_without_the_switch(local, monkeypatch):
    assert not chatgpt_login.available() and not chatgpt_login.enabled_for_ai()
    assert chatgpt_login.status()["available"] is False
    monkeypatch.setenv(chatgpt_login.ENABLED_ENV, "1")
    assert chatgpt_login.available()


def test_save_needs_consent_and_a_valid_key(local):
    with pytest.raises(ok.OpenAIKeyError) as e:
        ok.save_key(KEY, consent=False)
    assert (e.value.code, e.value.status) == ("consent_required", 428)
    with pytest.raises(ok.OpenAIKeyError) as e:
        ok.save_key("kein-schluessel", consent=True)
    assert e.value.code == "openai_key_invalid"
    assert not ok.has_key() and not ok.enabled_for_ai()


def test_save_checks_picks_default_model_and_never_leaks_the_key(local, monkeypatch, tmp_path):
    calls = []
    monkeypatch.setattr(ok, "http_get_json", lambda url, bearer: (calls.append((url, bearer)), CATALOG)[1])
    st = ok.save_key(KEY, consent=True)
    assert calls == [(ok.MODELS_URL, KEY)]
    assert st["has_key"] and st["key_hint"] == "sk-…0123" and st["checked"] and st["last_error"] is None
    assert st["model"] == "gpt-4o-mini" and st["consent_given"] and st["enabled_for_ai"]
    assert KEY not in json.dumps(st) and KEY not in (tmp_path / "openai-key.json").read_text(encoding="utf-8")
    assert ok.api_key() == KEY and ok.storage_kind() == "memory"
    assert ok.models() == ["gpt-4o-mini", "o3-mini", "gpt-4o"], "aus dem Zwischenspeicher, kein zweiter Aufruf"
    assert len(calls) == 1
    assert ai.uses_openai_key() and ai_relay.source() == "openai_key"


def test_failed_check_keeps_the_key_and_reports_without_it(local, monkeypatch):
    def rejected(url, bearer):
        raise ok.OpenAIKeyError("openai_key_rejected", "OpenAI hat den Schlüssel abgelehnt (401).", 401)
    monkeypatch.setattr(ok, "http_get_json", rejected)
    st = ok.save_key(KEY, consent=True)
    assert st["has_key"] and st["last_error"].startswith("OpenAI hat den Schlüssel abgelehnt") and not st["checked"]
    assert KEY not in st["last_error"]
    assert st["model"] == "" and not st["enabled_for_ai"], "ohne Modell keine KI ueber den Schluessel"
    ok.set_model("gpt-4o-mini")
    assert ok.enabled_for_ai()
    ok.set_use_for_ai(False)
    assert not ok.enabled_for_ai() and ai_relay.source() != "openai_key"


def test_ask_uses_the_users_key_directly(local, monkeypatch):
    from app import ai_backend
    monkeypatch.setattr(ok, "http_get_json", lambda url, bearer: CATALOG)
    ok.save_key(KEY, consent=True)
    seen = {}

    class Fake:
        def __init__(self, api_key, model_name, **kw):
            seen["key"], seen["model"] = api_key, model_name

        def complete(self, system, prompt, schema=None, **kw):
            seen["prompt"] = prompt
            return ai_backend.Completion("Antwort", 1, 1, "gpt-4o-mini")
    monkeypatch.setattr(ai_backend, "OpenAIProvider", Fake)
    assert ai.ask("Was ist 2+2?", "System") == "Antwort"
    assert seen == {"key": KEY, "model": "gpt-4o-mini", "prompt": "Was ist 2+2?"}
    with pytest.raises(ai.AIError):
        ai.ask("Bild", allowed_tools=["Read"])            # Bilder liest nur Claude


def test_endpoints_on_the_pc(app, local, monkeypatch):
    monkeypatch.setattr(ok, "http_get_json", lambda url, bearer: CATALOG)
    st, d = _j(asgi_call(app, "GET", "/api/integrations/openai-key"))
    assert st == 200 and d["available"] and not d["has_key"] and d["consent_text"].startswith("Dein Schlüssel bleibt")
    assert "platform.openai.com" in d["consent_text"] and d["keys_url"] == ok.KEYS_URL
    st, d = _j(asgi_call(app, "PUT", "/api/integrations/openai-key", body=json.dumps({"key": KEY})))
    assert (st, d["code"]) == (428, "consent_required")
    st, d = _j(asgi_call(app, "PUT", "/api/integrations/openai-key", body=json.dumps({"key": KEY, "consent": True})))
    assert st == 200 and d["has_key"] and d["model"] == "gpt-4o-mini" and KEY not in json.dumps(d)
    st, d = _j(asgi_call(app, "GET", "/api/integrations/openai-key/models"))
    assert st == 200 and d["models"][0] == "gpt-4o-mini"
    st, d = _j(asgi_call(app, "PUT", "/api/integrations/openai-key/settings", body=json.dumps({"model": "o3-mini", "use_for_ai": True})))
    assert st == 200 and d["model"] == "o3-mini" and d["enabled_for_ai"]
    st, d = _j(asgi_call(app, "GET", "/api/ai/source"))
    assert st == 200 and d["source"] == "openai_key" and d["openai_key"] and d["label"] == "über deinen OpenAI-Schlüssel · 0 Credits"
    st, d = _j(asgi_call(app, "POST", "/api/integrations/openai-key/check"))
    assert st == 200 and d["checked"]
    st, d = _j(asgi_call(app, "DELETE", "/api/integrations/openai-key"))
    assert st == 200 and not d["has_key"] and not ok.enabled_for_ai()


def test_nothing_in_the_hosted_service(app, local, monkeypatch):
    monkeypatch.setattr(config, "MODE", "hosted")
    assert not ok.available() and not ok.enabled_for_ai() and ok.api_key() == ""
    assert ok.status()["available"] is False and ok.status()["message"] == ok.NOT_AVAILABLE
    with pytest.raises(ok.OpenAIKeyError) as e:
        ok.save_key(KEY, consent=True)
    assert (e.value.code, e.value.status) == ("openai_key_not_available", 503)
    # Im Dienst verlangt jede /api-Anfrage die Anmeldung (401); ohne Konto gibt es hier nichts zu sehen
    st, _ = _j(asgi_call(app, "PUT", "/api/integrations/openai-key", body=json.dumps({"key": KEY, "consent": True})))
    assert st == 401
    assert not chatgpt_login.available()


def test_reset_removes_the_key(local, monkeypatch):
    monkeypatch.setattr(ok, "http_get_json", lambda url, bearer: CATALOG)
    ok.save_key(KEY, consent=True)
    from app import reset
    out = reset.wipe(clear_webview=False)
    assert out["openai_key"] is True and not ok.has_key() and not ok.state_path().exists()

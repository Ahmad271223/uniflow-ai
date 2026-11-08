"""Missbrauchsschutz der StudiNow-KI im Dienst: nur mit bestaetigter E-Mail, Probekonten mit eigenem kleinen Budget-Becken,
ohne Token-Preise gesperrt; die KI-Kommandozeile des Servers (`claude -p`) ist im Dienst nicht erreichbar."""
import json
import sqlite3

import pytest
from conftest import asgi_call
from test_subscriptions import FakeAI, _j, hosted, library_test, user  # noqa: F401 - hosted ist eine Fixture


def trial_account(app, email, verified=True):
    """Frisch registriertes Konto mit laufender Probe (Quelle trial, Pro AI), wie jede echte Registrierung."""
    from app import accounts
    st, d = _j(asgi_call(app, "POST", "/api/account/register",
                         body=json.dumps({"email": email, "password": "sehr-geheim-123", "university": "luh"})))
    assert st == 201, d
    if verified:
        accounts.mark_email_verified(d["user"]["id"])
    return d["user"], {"Authorization": f"Bearer {d['token']}"}


def tutor(app, headers, text):
    return _j(asgi_call(app, "POST", "/api/ai/tutor", headers=headers,
                        body=json.dumps({"mode": "explain", "page_text": text, "request_id": "r-" + text})))


def scaled_budgets(monkeypatch, total="0.1", user_="1", trial="0.04"):
    """Ein FakeAI-Tutor-Aufruf (120+40 Tokens) kostet 0,016 EUR, eine Reservierung 0,02 EUR."""
    monkeypatch.setenv("LERNAPP_AI_PRICE_IN_EUR", "100")
    monkeypatch.setenv("LERNAPP_AI_PRICE_OUT_EUR", "100")
    monkeypatch.setenv("LERNAPP_AI_BUDGET_EUR", total)
    monkeypatch.setenv("LERNAPP_AI_USER_BUDGET_EUR", user_)
    monkeypatch.setenv("LERNAPP_AI_TRIAL_BUDGET_EUR", trial)
    # Bei 100 EUR je 1 Mio. Tokens reserviert jede Anfrage ~25 Credits (app/credits.py); diese Tests pruefen die Becken
    # des Dienstes, nicht die Credits je Konto (tests/test_credits.py) - darum hier genug Credits fuer die Probe
    monkeypatch.setenv("LERNAPP_CREDITS_TRIAL", "1000")


# ---------------------------------------------------------------- E-Mail bestaetigt

def test_unverified_account_gets_no_studora_ai(hosted):
    from app import ai_backend
    fake = FakeAI()
    ai_backend.set_provider(fake)
    u, h = trial_account(hosted, "neu@beispiel.de", verified=False)
    st, d = _j(asgi_call(hosted, "GET", "/api/entitlements", headers=h))
    assert d["plan"] == "pro_ai" and d["source"] == "trial"
    assert _j(asgi_call(hosted, "GET", "/api/account/me", headers=h))[1]["user"]["email_verified"] is False
    st, d = tutor(hosted, h, "Matrizen")
    assert (st, d["code"]) == (403, "email_unverified") and "E-Mail-Adresse" in d["detail"]
    st, d = library_test(hosted, h, "Determinanten")
    assert (st, d["code"]) == (403, "email_unverified")
    assert fake.calls == 0, "kein Aufruf des Anbieters, nichts protokolliert"
    conn = ai_backend.connect()
    try:
        assert conn.execute("SELECT COUNT(*) FROM ai_usage_log").fetchone()[0] == 0
    finally:
        conn.close()
    from app import accounts
    accounts.mark_email_verified(u["id"])
    assert tutor(hosted, h, "Matrizen")[0] == 200
    assert library_test(hosted, h, "Determinanten")[0] == 200 and fake.calls >= 2


def test_unverified_account_can_still_reuse_the_library(hosted):
    """Wiederverwenden kostet kein KI-Budget: nur das Erzeugen verlangt die bestaetigte Adresse."""
    from app import ai_backend
    ai_backend.set_provider(FakeAI())
    _, h = trial_account(hosted, "alt@beispiel.de")
    assert library_test(hosted, h, "Basiswechsel")[0] == 200            # fuellt den Pool
    from app import accounts
    _, h2 = trial_account(hosted, "neu2@beispiel.de", verified=False)
    st, d = library_test(hosted, h2, "Basiswechsel")
    assert st == 200 and d["generated"] == 0, d


def test_weekly_plan_waits_for_verified_email(hosted):
    from app import accounts, config, weekly
    u, _ = trial_account(hosted, "wt@beispiel.de", verified=False)
    t = config.set_user_context(u["id"], "luh")
    try:
        with pytest.raises(weekly.WeeklyError, match="E-Mail-Adresse bestätigen"):
            weekly._ask("Frage", "SYS")
    finally:
        config.reset_user_context(t)


# ---------------------------------------------------------------- eigenes Becken fuer Probekonten

def test_trial_accounts_never_drain_the_budget_of_paying_accounts(hosted, monkeypatch):
    from app import ai_backend
    ai_backend.set_provider(FakeAI())
    scaled_budgets(monkeypatch)
    _, paid = user(hosted, "zahlend@beispiel.de", plan="pro_ai")
    assert tutor(hosted, paid, "bezahlt-0")[0] == 200
    for n in range(1, 4):                                    # beliebig viele (bestaetigte) Probekonten
        _, h = trial_account(hosted, f"probe{n}@beispiel.de")
        codes = [tutor(hosted, h, f"probe{n}-{i}") for i in range(3)]
        if n == 1:
            assert [c[0] for c in codes] == [200, 200, 429] and codes[2][1]["code"] == "ai_trial_budget_exhausted"
        else:
            assert {c[0] for c in codes} == {429} and codes[0][1]["code"] == "ai_trial_budget_exhausted", "Becken ist leer"
        st, d = tutor(hosted, paid, f"bezahlt-{n}")
        assert st == 200, (n, d)                             # vorher: 503 ai_budget_exhausted fuer alle
    conn = ai_backend.connect()
    try:
        assert conn.execute("SELECT SUM(cost_microeur) FROM ai_usage_log WHERE trial=1").fetchone()[0] == 32000
        assert conn.execute("SELECT SUM(cost_microeur) FROM ai_usage_log WHERE trial=0").fetchone()[0] == 16000 * 4
    finally:
        conn.close()


def test_account_with_paid_plan_during_trial_uses_the_paid_pool(hosted, monkeypatch):
    from app import accounts, ai_backend, billing
    ai_backend.set_provider(FakeAI())
    scaled_budgets(monkeypatch)
    u, h = trial_account(hosted, "kauft@beispiel.de")
    assert tutor(hosted, h, "a")[0] == 200
    conn = billing.connect()
    try:
        assert ai_backend.is_trial_account(conn, u["id"], ai_backend._now())
        # Credit-Regel 08.11.2026: Plus neben der Probe bleibt Probe (25 Credits, Probe-Becken); erst Pro AI ist bezahlt
        billing.set_entitlement(conn, u["id"], "stripe", "plus", expires_at=None, status="active", will_renew=True)
        assert ai_backend.is_trial_account(conn, u["id"], ai_backend._now()), "Plus neben der Probe: weiter Probe"
        billing.set_entitlement(conn, u["id"], "stripe", "pro_ai", expires_at=None, status="active", will_renew=True)
        assert not ai_backend.is_trial_account(conn, u["id"], ai_backend._now()), "Pro AI neben der Probe"
        assert not ai_backend.is_trial_account(conn, "gibt-es-nicht", ai_backend._now())
    finally:
        conn.close()
    accounts.set_plan(u["id"], "pro_ai")


def test_old_usage_table_gets_the_trial_column(hosted):
    from app import accounts, ai_backend, db
    conn = sqlite3.connect(accounts.db_path())
    conn.execute("DROP TABLE IF EXISTS ai_usage_log")
    conn.execute("CREATE TABLE ai_usage_log (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT, period TEXT NOT NULL, "
                 "purpose TEXT NOT NULL, provider TEXT, model TEXT, input_tokens INTEGER DEFAULT 0, output_tokens INTEGER DEFAULT 0, "
                 "cost_microeur INTEGER NOT NULL DEFAULT 0, state TEXT NOT NULL DEFAULT 'reserved', created_at TEXT NOT NULL)")
    conn.commit()
    ai_backend.ensure_schema(conn)
    assert "trial" in [r[1] for r in conn.execute("PRAGMA table_info(ai_usage_log)")]
    ai_backend.ensure_schema(conn)                                      # zweimal ist unschaedlich
    conn.close()


# ---------------------------------------------------------------- ohne Preise gesperrt

def test_hosted_ai_fails_closed_without_token_prices(hosted, monkeypatch):
    from app import ai_backend
    fake = FakeAI()
    ai_backend.set_provider(fake)
    _, h = user(hosted, "preise@beispiel.de", plan="pro_ai")
    for name in ("LERNAPP_AI_PRICE_IN_EUR", "LERNAPP_AI_PRICE_OUT_EUR"):
        monkeypatch.setenv(name, "0")
    st, d = tutor(hosted, h, "Seite")
    assert (st, d["code"]) == (503, "ai_not_configured_prices") and "Token-Preise" in d["detail"]
    assert library_test(hosted, h, "Eigenwerte")[1]["code"] == "ai_not_configured_prices"
    assert fake.calls == 0
    st, e = _j(asgi_call(hosted, "GET", "/api/entitlements", headers=h))
    assert e["quotas"]["ai_assist"]["used"] == 0, "zurueckgebucht"
    monkeypatch.delenv("LERNAPP_AI_PRICE_OUT_EUR")
    monkeypatch.setenv("LERNAPP_AI_PRICE_IN_EUR", "1")
    assert tutor(hosted, h, "Seite")[1]["code"] == "ai_not_configured_prices", "auch nur ein Preis fehlt"
    monkeypatch.setenv("LERNAPP_AI_PRICE_OUT_EUR", "2")
    assert tutor(hosted, h, "Seite")[0] == 200


def test_prices_are_not_required_on_the_own_pc(app, monkeypatch):
    """Einzelplatz: ai_backend.complete wird dort nicht genutzt, die Preispflicht gilt nur im Dienst."""
    from app import ai_backend, config
    monkeypatch.setattr(config, "MODE", "local")
    monkeypatch.setenv("LERNAPP_AI_PRICE_IN_EUR", "0")
    ai_backend.set_provider(FakeAI())
    try:
        assert ai_backend.complete(None, "explain", "s", "p").text
    finally:
        ai_backend.set_provider(None)


# ---------------------------------------------------------------- KI-Kommandozeile im Dienst

def multipart(source, **fields):
    b = "bnd"
    parts = [f'--{b}\r\nContent-Disposition: form-data; name="source"\r\n\r\n{source}\r\n']
    for k, v in fields.items():
        parts.append(f'--{b}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n')
    return "".join(parts + [f"--{b}--\r\n"]).encode(), f"multipart/form-data; boundary={b}"


def test_hosted_timetable_import_and_start_test_never_reach_the_cli(hosted, monkeypatch):
    from app import ai
    calls = []

    def recorder(*a, **k):
        calls.append((a, k))
        raise ai.AIError("ask erreicht")
    monkeypatch.setattr(ai, "ask", recorder)
    monkeypatch.setattr(ai, "ask_pdf", recorder)
    _, h = user(hosted, "stundenplan@beispiel.de")                      # Free-Tarif genuegt, um bis hierher zu kommen
    for source, extra in (("text", {"text": "Mo 10:00-11:30 Mathe"}), ("image", {})):
        body, ctype = multipart(source, **extra)
        st, _, raw = asgi_call(hosted, "POST", "/api/timetable/import/preview", headers=h, body=body, content_type=ctype)
        assert st == 501 and json.loads(raw)["code"] == "not_available_hosted", (source, raw)
    st, _, raw = asgi_call(hosted, "POST", "/api/tasks/7/start-test", headers=h, body="{}")
    assert st == 501 and json.loads(raw)["code"] == "not_available_hosted"
    assert asgi_call(hosted, "POST", "/api/tests/generate", headers=h, body="{}")[0] == 501
    assert calls == []


def test_ai_ask_refuses_in_the_service(app, monkeypatch):
    from app import ai, config
    monkeypatch.setattr(config, "MODE", "hosted")
    ran = []
    monkeypatch.setattr(ai.subprocess, "run", lambda *a, **k: ran.append(a))
    monkeypatch.setattr(ai, "_claude_bin", lambda: ran.append("bin") or "claude")
    with pytest.raises(ai.AIError, match="Im Dienst"):
        ai.ask("Hallo")
    with pytest.raises(ai.AIError, match="Im Dienst"):
        ai.ask("Hallo", allowed_tools=["Read"])
    with pytest.raises(ai.AIError, match="Im Dienst"):
        ai.ask_pdf("Hallo", "", [("/nicht/da.pdf", 3)])
    assert ran == []


def test_cli_child_gets_only_a_small_environment(app, monkeypatch):
    from app import ai
    for k, v in {"LERNAPP_OPENAI_API_KEY": "geheim-1", "LERNAPP_STRIPE_SECRET": "geheim-2", "LERNAPP_SECRET_KEY": "geheim-3",
                 "SMTP_PASSWORD": "geheim-4", "CLAUDECODE": "1", "ANTHROPIC_API_KEY": "fuer-die-cli", "PATH": "/usr/bin"}.items():
        monkeypatch.setenv(k, v)
    seen = {}

    class P:
        returncode, stdout, stderr = 0, json.dumps({"result": "{}"}), ""
    monkeypatch.setattr(ai, "_claude_bin", lambda: "claude")
    monkeypatch.setattr(ai, "uses_chatgpt", lambda: False)
    monkeypatch.setattr(ai.subprocess, "run", lambda cmd, **k: seen.update(k) or P())
    ai.ask("Hallo")
    env = seen["env"]
    assert env["ANTHROPIC_API_KEY"] == "fuer-die-cli" and env["PATH"] == "/usr/bin" and env["PYTHONIOENCODING"] == "utf-8"
    assert not [k for k in env if k.startswith("LERNAPP_") or k in ("SMTP_PASSWORD", "CLAUDECODE")]

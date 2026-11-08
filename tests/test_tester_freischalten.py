"""TestFlight-Tester freischalten (app/tester_freischalten.py, tools/tester-freischalten.py, 08.11.2026): die Probe des
StudiNow-Kontos im Dienst verlaengern, damit Tester nach der verbrauchten iPad-Probe weiter alles pruefen koennen.
Das iPad uebernimmt eine laufende Probe des Dienstes (UFPlanPrecedence), geprueft in PurchaseTests/PlanContractTests."""
import datetime as dt
import io
import json

from test_subscriptions import ent, hosted, user  # noqa: F401 - Fixture und Helfer wiederverwenden

UTC = dt.timezone.utc


def _run(argv, now=None):
    from app import tester_freischalten
    out = io.StringIO()
    code = tester_freischalten.run(argv, now=now, out=out)
    lines = out.getvalue().strip().splitlines()
    rows = [json.loads(l) for l in lines if l.startswith("{")]
    return code, rows, lines[-1] if lines else ""


def test_extended_trial_gives_the_tester_pro_ai_scope_with_trial_credits(hosted):
    """Konto mit verbrauchter Probe: nach dem Werkzeug laeuft die Probe 14 Tage, GET /api/entitlements meldet sie wie eine
    frische Probe (Pro-AI-Umfang, Quelle trial, Probe-Credits), keine Aufforderung zur Tarifwahl."""
    from app import plans
    u, h = user(hosted, "tester@beispiel.de")                  # user() beendet die Probe des neuen Kontos
    e = ent(hosted, h)
    assert e["plan"] == "free" and e["trial"]["expired"] and e["needs_plan_choice"]
    code, rows, summary = _run(["--email", "Tester@beispiel.de", "--tage", "14", "--ausfuehren"])
    assert code == 0 and len(rows) == 1 and rows[0]["tage"] == 14 and rows[0]["probe_vorher"].startswith("vorbei"), rows
    assert "1 Konto/Konten freigeschaltet" in summary
    e = ent(hosted, h)
    assert e["plan"] == plans.TRIAL["plan"] == "pro_ai" and e["source"] == "trial" and e["paid_plan"] == "free"
    assert e["trial"]["active"] and e["trial"]["days_left"] == 14 and e["trial"]["plan"] == "pro_ai" and not e["needs_plan_choice"]
    assert e["entitlements"]["can_annotate_pdf"] and e["entitlements"]["can_use_ai_explanations"]
    assert e["credits"]["allowance"] == plans.CREDITS["trial"], "Probe-Credits, nicht die 100 von Pro AI"
    assert e["access"]["state"] == "trial" and e["access"]["trial_days_left"] == 14


def test_dry_run_changes_nothing_and_unknown_addresses_are_named(hosted):
    u, h = user(hosted, "trocken@beispiel.de")
    code, rows, summary = _run(["--email", "trocken@beispiel.de", "--email", "niemand@beispiel.de"])
    assert code == 0 and len(rows) == 2, rows
    assert rows[0]["ergebnis"] == "kein aktives Konto" and rows[0]["email"] == "niemand@beispiel.de"
    assert rows[1]["ergebnis"].startswith("Probelauf") and "Probelauf" in summary
    assert ent(hosted, h)["plan"] == "free", "ohne --ausfuehren nichts geschrieben"
    code, rows, _ = _run(["--email", "niemand@beispiel.de", "--ausfuehren"])
    assert code == 1 and rows[0]["ergebnis"] == "kein aktives Konto"


def test_registration_window_selects_only_accounts_created_in_it(hosted):
    from app import accounts
    a, ha = user(hosted, "neu-a@beispiel.de")
    b, hb = user(hosted, "neu-b@beispiel.de")
    alt, halt = user(hosted, "alt@beispiel.de")
    with accounts.cursor() as conn:
        conn.execute("UPDATE users SET created_at='2026-10-01T10:00:00Z' WHERE id=?", (alt["id"],))
    today = dt.datetime.now(UTC).date()
    code, rows, _ = _run(["--registriert-seit", "2026-11-08", "--registriert-bis", today.isoformat(), "--bis",
                          (today + dt.timedelta(days=20)).isoformat(), "--ausfuehren"])
    assert code == 0 and sorted(r["email"] for r in rows) == ["neu-a@beispiel.de", "neu-b@beispiel.de"], rows
    assert ent(hosted, ha)["trial"]["active"] and ent(hosted, hb)["trial"]["active"]
    assert ent(hosted, halt)["plan"] == "free" and ent(hosted, halt)["trial"]["expired"], "aelteres Konto nicht beruehrt"
    assert 20 <= ent(hosted, ha)["trial"]["days_left"] <= 21, "bis einschliesslich des Tages (Europe/Berlin)"


def test_paid_or_sandbox_subscription_stays_and_the_highest_plan_wins(hosted):
    """Ein Tester mit Sandbox-Plus behaelt sein Abo; die verlaengerte Probe (Pro-AI-Umfang) gilt daneben, solange sie
    laeuft, danach wieder Plus."""
    from app import billing
    u, h = user(hosted, "plus-tester@beispiel.de")
    conn = billing.connect()
    try:
        billing.set_entitlement(conn, u["id"], "app_store", "plus", original_transaction_id="tf-1",
                                expires_at=(dt.datetime.now(UTC) + dt.timedelta(days=30)).isoformat(), environment="Sandbox")
    finally:
        conn.close()
    assert ent(hosted, h)["plan"] == "plus"
    code, rows, _ = _run(["--email", "plus-tester@beispiel.de", "--tage", "3", "--ausfuehren"])
    assert code == 0 and rows[0]["tarif_vorher"] == "plus"
    e = ent(hosted, h)
    assert e["plan"] == "pro_ai" and e["trial"]["active"] and e["subscriptions"]["app_store"], "Abo bleibt, Probe obenauf"
    conn = billing.connect()
    try:
        later = dt.datetime.now(UTC) + dt.timedelta(days=4)
        assert billing.current_plan(conn, u["id"], later) == "plus", "nach der Probe wieder das Abo"
        # die Probe verlaengert sich nie von selbst und darf nicht in die Vergangenheit gesetzt werden
        import pytest
        with pytest.raises(ValueError):
            billing.extend_trial(conn, u["id"], dt.datetime.now(UTC) - dt.timedelta(days=1))
    finally:
        conn.close()


def test_arguments_are_checked(hosted):
    code, _, msg = _run([])
    assert code == 2 and "--email oder --registriert-seit" in msg
    code, _, msg = _run(["--email", "x@beispiel.de", "--tage", "0"])
    assert code == 2 and "groesser als 0" in msg
    code, _, msg = _run(["--email", "x@beispiel.de", "--bis", "2020-01-01"])
    assert code == 2 and "Zukunft" in msg


def test_tools_wrapper_imports_the_module():
    from pathlib import Path
    t = (Path(__file__).resolve().parents[1] / "tools" / "tester-freischalten.py").read_text(encoding="utf-8")
    assert "from app.tester_freischalten import main" in t and "python -m app.tester_freischalten" in t

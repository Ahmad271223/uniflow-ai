"""Audit 09.11.2026, Pakete 67/69/75/78/79/86 (Kauf, Stud.IP am PC, Konten, StoreKit, Tarife, Release):
docs/audit/AUDIT-2026-11-09-PAKET-67-69-75-78-79-86.md. Hier die Dienst-Haelfte der Belege; die iPad-Haelfte steht in
apps/apple/UniFlowTests/PurchaseServiceRetryP78Tests.swift. Signierte Test-Transaktionen wie tests/test_subscriptions.py
(eigene Kette mit Apple-OIDs), nie ein Netz."""
import datetime as dt
import json
import os

from conftest import asgi_call
from test_reset import filled  # noqa: F401 (Fixture)
from test_subscriptions import IN_30, UTC, FakeAI, _j, apple, ent, hosted, user, verify  # noqa: F401 (Fixtures)

PRO, PRO_YEARLY = "de.uniflow.proai.monthly", "de.uniflow.proai.yearly"


def _tutor(app, headers):
    return _j(asgi_call(app, "POST", "/api/ai/tutor", headers=headers,
                        body=json.dumps({"mode": "explain", "page_text": "Matrizen"})))


def test_p78_01_purchase_reported_again_after_a_failed_check_unlocks_plan_credits_and_ai(hosted, apple, monkeypatch):
    """P78-F1/P78-01: Scheitert die Pruefung im Dienst (503 apple_not_configured, z. B. Zertifikat fehlt kurz), bleibt
    das Konto Free und die StudiNow-KI gesperrt. Dieselbe signierte Transaktion beim naechsten Start (das iPad meldet
    alle `currentEntitlements` erneut) schaltet Pro AI mit 100 Credits frei, die KI antwortet. Eine weitere Meldung
    derselben Transaktion (naechster Start) aendert nichts: keine zweiten Credits, kein Zuruecksetzen des Verbrauchs."""
    from app import ai_backend
    ai_backend.set_provider(FakeAI())
    u, h = user(hosted, "p78-nachmeldung@beispiel.de")
    signed = apple.tx(u["id"], PRO, IN_30, otid="7800000000000001")
    roots = os.environ["LERNAPP_APPLE_ROOT_CERTS"]

    monkeypatch.setenv("LERNAPP_APPLE_ROOT_CERTS", "")
    st, d = verify(hosted, h, signed)
    assert (st, d["code"]) == (503, "apple_not_configured")
    e = ent(hosted, h)
    assert e["plan"] == "free" and e["credits"]["allowance"] == 0
    st, d = _tutor(hosted, h)
    assert (st, d["required_plan"]) == (403, "pro_ai"), "ohne angekommenen Kauf keine KI"

    monkeypatch.setenv("LERNAPP_APPLE_ROOT_CERTS", roots)
    st, d = verify(hosted, h, signed)                        # naechster Start: dieselbe JWS
    assert st == 200 and d["plan"] == "pro_ai", d
    e = ent(hosted, h)
    assert e["plan"] == "pro_ai" and e["source"] == "app_store" and e["credits"]["allowance"] == 100
    st, d = _tutor(hosted, h)
    assert st == 200 and "Matrix" in d["answer"], d
    used = ent(hosted, h)["credits"]["used"]

    st, d = verify(hosted, h, signed)                        # noch ein Start
    assert st == 200 and d["plan"] == "pro_ai"
    e = ent(hosted, h)
    assert e["credits"]["allowance"] == 100 and e["credits"]["used"] == used, "idempotent"


def test_p78_f4_purchase_without_token_belongs_to_the_account_that_reports_it_first(hosted, apple):
    """P78-F4/P86-F9 (Weg der App-Pruefung): Kauf vor der Anmeldung (ohne appAccountToken), dann Anmeldung beim
    StudiNow-Konto: das meldende Konto bekommt Pro AI mit 100 Credits; ein zweites Konto bekommt denselben Kauf nie (409)."""
    a, ha = user(hosted, "p78-review-a@beispiel.de")
    b, hb = user(hosted, "p78-review-b@beispiel.de")
    signed = apple.tx(a["id"], PRO, IN_30, otid="7800000000000002", token=False)
    st, d = verify(hosted, ha, signed)
    assert st == 200 and d["plan"] == "pro_ai", d
    assert ent(hosted, ha)["credits"]["allowance"] == 100
    st, d = verify(hosted, hb, signed)
    assert (st, d["code"]) == (409, "subscription_owned_by_other_account"), d
    assert ent(hosted, hb)["plan"] == "free" and ent(hosted, hb)["credits"]["allowance"] == 0


def test_p79_08_yearly_pro_ai_gives_100_credits_per_calendar_month_not_twelve_at_once(hosted, apple):
    """P79-F8: Jahresabo Pro AI = 100 Credits je Kalendermonat (Europe/Berlin), im naechsten Monat wieder 100 - nie
    1.200 auf einmal; das Jahresabo laeuft bis zum Ende der Jahresperiode."""
    from app import credits
    u, h = user(hosted, "p79-jahr@beispiel.de")
    in_365 = dt.datetime.now(UTC) + dt.timedelta(days=365)
    st, d = verify(hosted, h, apple.tx(u["id"], PRO_YEARLY, in_365, otid="7900000000000008"))
    assert st == 200 and d["plan"] == "pro_ai", d
    e = ent(hosted, h)
    assert e["plan"] == "pro_ai" and e["credits"]["allowance"] == 100
    conn = credits.connect()
    try:
        now = dt.datetime.now(UTC)
        for months in (1, 6, 11):
            later = (now.replace(day=15) + dt.timedelta(days=31 * months)).replace(day=15)
            b = credits.balance(conn, u["id"], later)
            assert (b["allowance"], b["used"], b["period"]) == (100, 0, credits.period_of(later)), months
        after = credits.balance(conn, u["id"], in_365 + dt.timedelta(days=2))
        assert after["allowance"] == 0 and after["plan"] == "free", "nach der Jahresperiode ohne Verlaengerung: Free"
    finally:
        conn.close()


def test_p79_05_month_boundaries_follow_the_documented_rule():
    """P79-F5 (Entscheidung, festgenagelt): Credits und uebernommene Karteikarten-Stapel zaehlen im Kalendermonat
    Europe/Berlin (Credit-Regel 08.11., P43-06), die uebrigen Kontingente (KI-Tests, KI-Hilfe) im UTC-Monat (P21-10).
    An der Monatsgrenze springen sie darum bis zu zwei Stunden versetzt - auch bei Sommer-/Winterzeit."""
    from app import billing, credits
    cases = [
        (dt.datetime(2026, 11, 30, 23, 30, tzinfo=UTC), "2026-12", "2026-11"),   # Winterzeit: 01.12. 00:30 Berlin
        (dt.datetime(2027, 3, 31, 22, 30, tzinfo=UTC), "2027-04", "2027-03"),    # Sommerzeit: 01.04. 00:30 Berlin
        (dt.datetime(2026, 10, 31, 23, 30, tzinfo=UTC), "2026-11", "2026-10"),   # Tag der Zeitumstellung
        (dt.datetime(2026, 12, 1, 0, 30, tzinfo=UTC), "2026-12", "2026-12"),     # danach wieder gleich
    ]
    for t, berlin, utc in cases:
        assert credits.period_of(t) == berlin, t
        assert billing.feature_period("card_stacks_adopted", t) == berlin, t
        assert billing.feature_period("ai_tests_new", t) == utc and billing.period_of(t) == utc, t


def test_p69_f8_login_screenshot_stays_local_and_goes_with_the_reset(filled):  # noqa: F811
    """P69-F8 (= P12-10): `login-fehler.png` entsteht nur am PC (der Dienst meldet sich seit 06.11. nicht bei der
    Hochschule an: Browser-Auftraege werden uebersprungen), liegt im Protokollordner dieses Rechners, und
    "Hochschul-Konto entfernen" (`reset.wipe`) loescht ihn mit."""
    from app import config, jobs, reset
    assert jobs.HOSTED_UNI_SYNC is False and "sync" in jobs.BROWSER_KINDS
    shot = config.log_dir() / "login-fehler.png"
    shot.parent.mkdir(parents=True, exist_ok=True)
    shot.write_bytes(b"\x89PNG Kennung luh123 sichtbar")
    out = reset.wipe(clear_webview=False)
    assert out["ok"] and not shot.exists()

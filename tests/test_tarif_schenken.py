"""Tarif schenken (app/tarif_schenken.py, tools/tarif-schenken.py, billing.grant_gift; Auftrag des Inhabers 18.11.2026):
ein Konto bekommt Pro AI dauerhaft ohne Abo, ohne Ablauf, ohne Zahlung - mit allem, was Pro AI enthaelt (auch den 100
Monats-Credits); Credit-Pakete kauft es selbst wie jedes andere Konto."""
import datetime as dt
import io
import json

import pytest

from test_subscriptions import ent, hosted, user  # noqa: F401 - Fixture und Helfer wiederverwenden

UTC = dt.timezone.utc


def _run(argv, now=None):
    from app import tarif_schenken
    out = io.StringIO()
    code = tarif_schenken.run(argv, now=now, out=out)
    lines = out.getvalue().strip().splitlines()
    rows = [json.loads(l) for l in lines if l.startswith("{")]
    return code, rows, lines[-1] if lines else ""


def _conn():
    from app import apple_store, billing
    conn = billing.connect()
    apple_store.ensure_schema(conn)
    return conn


def _apple_sub(conn, uid, plan_product, otid, days=30, **extra):
    """Abo-Transaktion aus dem App Store anwenden (ohne Signatur: apply_transaction nimmt die gepruefte Nutzlast)."""
    from app import apple_store
    now = dt.datetime.now(UTC)
    tx = {"bundleId": apple_store.bundle_id(), "productId": plan_product, "originalTransactionId": otid,
          "transactionId": otid + "-1", "signedDate": int(now.timestamp() * 1000) + extra.pop("signed_offset", 0),
          "purchaseDate": int(now.timestamp() * 1000), "expiresDate": int((now + dt.timedelta(days=days)).timestamp() * 1000),
          "environment": "Production", **extra}
    return tx


def test_gift_gives_pro_ai_without_end_with_pro_ai_credits(hosted):
    """Nach dem Schenken: wirksamer Tarif Pro AI, Quelle gift, ohne Ablauf und ohne Verlaengerung (kein "Abo verwalten",
    kein "Laeuft ab"), alle Rechte von Pro AI, 100 Monats-Credits wie bezahltes Pro AI (nicht die 25 der Probe), keine
    Probe-Anzeige und keine Aufforderung zur Tarifwahl."""
    from app import plans
    u, h = user(hosted, "geschenk@beispiel.de")
    assert ent(hosted, h)["plan"] == "free"
    code, rows, summary = _run(["--email", "Geschenk@beispiel.de", "--plan", "pro_ai", "--unbefristet", "--ausfuehren"])
    assert code == 0 and len(rows) == 1, rows
    assert rows[0]["tarif_vorher"] == "free" and rows[0]["tarif_jetzt"] == "pro_ai" and rows[0]["geschenk_vorher"] == "keines"
    assert rows[0]["email"] == "g***@beispiel.de" and "geschenk@beispiel.de" not in json.dumps(rows), "Zeilen ohne volle Adresse"
    assert "StudiNow Pro AI geschenkt (unbefristet)" in summary and "Geschenk@beispiel.de" in summary, "Bestaetigung an den Aufrufer"
    e = ent(hosted, h)
    assert e["plan"] == "pro_ai" and e["plan_name"] == "StudiNow Pro AI"
    assert e["source"] == "gift" and e["expires_at"] is None and e["will_renew"] is False and e["pending_plan"] is None
    assert e["gift"] == {"active": True, "plan": "pro_ai", "ends_at": None}, "Feld fuer die Apple-App"
    assert e["paid_plan"] == "pro_ai", "zaehlt fuer die Apps wie ein bezahlter Tarif (keine Probe-Anzeige)"
    assert e["subscriptions"] == {"app_store": False, "stripe": False}, "kein Abo, also nichts zu verwalten"
    assert e["entitlements"] == {**plans.entitlements("pro_ai"), "chatgpt_connection_premium": e["entitlements"]["chatgpt_connection_premium"]}
    assert e["quotas"]["ai_tests_new"]["limit"] == plans.quota_limit("pro_ai", "ai_tests_new")
    assert e["credits"]["allowance"] == plans.CREDITS["pro_ai"] == 100 and e["credits"]["plan"] == "pro_ai"
    assert e["credits"]["can_buy"] is True and e["credits"]["purchased_scope"] == "all"
    assert not e["needs_plan_choice"] and e["access"]["state"] == "active" and not e["access"]["locked"]
    # Monate spaeter: weiter Pro AI, Credits neu je Monat
    conn = _conn()
    try:
        from app import billing, credits
        later = dt.datetime.now(UTC) + dt.timedelta(days=3650)
        assert billing.current_plan(conn, u["id"], later) == "pro_ai"
        assert credits.balance(conn, u["id"], later)["allowance"] == 100
    finally:
        conn.close()


def test_credit_purchase_stays_paid_and_adds_to_the_monthly_credits(hosted):
    """Das Geschenk schenkt keine Credit-Pakete: sie kosten weiter Geld (Apple), ein gekauftes kommt zu den 100 dazu."""
    from app import apple_store, plans
    u, h = user(hosted, "kauft@beispiel.de")
    assert _run(["--email", "kauft@beispiel.de", "--plan", "pro_ai", "--unbefristet", "--ausfuehren"])[0] == 0
    e = ent(hosted, h)
    assert e["credits"]["purchased"] == 0 and e["credits"]["available"] == 100
    assert all(p["price_cents"] > 0 for p in plans.credit_packs()), "Pakete bleiben kostenpflichtig"
    conn = _conn()
    try:
        now = dt.datetime.now(UTC)
        tx = {"bundleId": apple_store.bundle_id(), "productId": "de.uniflow.credits.klein", "transactionId": "pack-1",
              "originalTransactionId": "pack-1", "purchaseDate": int(now.timestamp() * 1000), "environment": "Production",
              "appAccountToken": apple_store.account_token(u["id"])}
        out = apple_store.apply_credit_purchase(conn, u["id"], tx, now=now)
        assert out["status"] == "granted" and out["credits_added"] == plans.credit_pack_credits("de.uniflow.credits.klein")
    finally:
        conn.close()
    e = ent(hosted, h)
    n = plans.credit_pack_credits("de.uniflow.credits.klein")
    assert e["credits"]["allowance"] == 100 and e["credits"]["purchased"] == n and e["credits"]["available"] == 100 + n
    assert e["plan"] == "pro_ai" and e["source"] == "gift", "der Kauf aendert am Geschenk nichts"


def test_revoke_ends_the_gift_and_only_the_gift(hosted):
    from app import billing
    u, h = user(hosted, "zurueck@beispiel.de")
    assert _run(["--email", "zurueck@beispiel.de", "--plan", "pro_ai", "--unbefristet", "--ausfuehren"])[0] == 0
    assert ent(hosted, h)["plan"] == "pro_ai"
    code, rows, _ = _run(["--email", "zurueck@beispiel.de", "--zuruecknehmen"])
    assert code == 0 and rows[0]["ergebnis"].startswith("Probelauf") and ent(hosted, h)["plan"] == "pro_ai"
    code, rows, summary = _run(["--email", "zurueck@beispiel.de", "--zuruecknehmen", "--ausfuehren"])
    assert code == 0 and rows[0]["ergebnis"] == "Geschenk zurueckgenommen" and rows[0]["tarif_jetzt"] == "free"
    assert "Geschenk zurueckgenommen fuer 1" in summary
    e = ent(hosted, h)
    assert e["plan"] == "free" and e["source"] is None and e["credits"]["allowance"] == 0 and e["gift"] is None
    conn = _conn()
    try:
        info = billing.gift_info(conn, u["id"])
        assert info["granted"] and not info["active"] and info["status"] == "revoked", "bleibt nachvollziehbar stehen"
    finally:
        conn.close()
    code, rows, _ = _run(["--email", "zurueck@beispiel.de", "--zuruecknehmen", "--ausfuehren"])
    assert code == 1 and rows[0]["ergebnis"] == "kein Geschenk zum Zuruecknehmen"
    # erneut schenken holt es zurueck
    assert _run(["--email", "zurueck@beispiel.de", "--plan", "pro_ai", "--unbefristet", "--ausfuehren"])[0] == 0
    assert ent(hosted, h)["plan"] == "pro_ai"


def test_dry_run_changes_nothing(hosted):
    u, h = user(hosted, "trocken@beispiel.de")
    code, rows, summary = _run(["--email", "trocken@beispiel.de", "--plan", "pro_ai", "--unbefristet"])
    assert code == 0 and rows[0]["ergebnis"].startswith("Probelauf: wuerde StudiNow Pro AI schenken") and "Probelauf" in summary
    assert "tarif_jetzt" not in rows[0]
    e = ent(hosted, h)
    assert e["plan"] == "free" and e["source"] is None


def test_paid_subscription_and_gift_the_highest_plan_wins(hosted):
    """Bezahltes Pro AI + geschenktes Plus: Pro AI aus dem App Store. Bezahltes Plus + geschenktes Pro AI: Pro AI aus dem
    Geschenk, das Abo bleibt daneben bestehen (Anzeige "Apple-Abo" fuer Windows/Web bleibt)."""
    from app import apple_store
    a, ha = user(hosted, "zahlt-pro@beispiel.de")
    b, hb = user(hosted, "zahlt-plus@beispiel.de")
    conn = _conn()
    try:
        apple_store.apply_transaction(conn, a["id"], _apple_sub(conn, a["id"], "de.uniflow.proai.yearly", "otid-a"))
        apple_store.apply_transaction(conn, b["id"], _apple_sub(conn, b["id"], "de.uniflow.plus.yearly", "otid-b"))
    finally:
        conn.close()
    assert _run(["--email", "zahlt-pro@beispiel.de", "--plan", "plus", "--unbefristet", "--ausfuehren"])[0] == 0
    assert _run(["--email", "zahlt-plus@beispiel.de", "--plan", "pro_ai", "--unbefristet", "--ausfuehren"])[0] == 0
    ea, eb = ent(hosted, ha), ent(hosted, hb)
    assert ea["plan"] == "pro_ai" and ea["source"] == "app_store" and ea["will_renew"] is True
    assert ea["gift"] == {"active": True, "plan": "plus", "ends_at": None}, "das Geschenk steht auch unter einem hoeheren Abo"
    assert eb["plan"] == "pro_ai" and eb["source"] == "gift" and eb["subscriptions"]["app_store"] is True
    assert eb["credits"]["allowance"] == 100


def test_apple_refund_or_expiry_of_a_subscription_leaves_the_gift(hosted):
    """Apple-Mitteilungen (Erstattung, Ablauf) schreiben nur die Quelle app_store: das Geschenk bleibt stehen."""
    from app import apple_store, billing
    u, h = user(hosted, "erstattet@beispiel.de")
    assert _run(["--email", "erstattet@beispiel.de", "--plan", "pro_ai", "--unbefristet", "--ausfuehren"])[0] == 0
    conn = _conn()
    try:
        apple_store.apply_transaction(conn, u["id"], _apple_sub(conn, u["id"], "de.uniflow.plus.yearly", "otid-r"))
        now = dt.datetime.now(UTC)
        refund = _apple_sub(conn, u["id"], "de.uniflow.plus.yearly", "otid-r", signed_offset=5000,
                            revocationDate=int(now.timestamp() * 1000))
        st = apple_store.apply_transaction(conn, u["id"], refund, notification=("REFUND", None))
        assert st["status"] == "revoked"
        expired = _apple_sub(conn, u["id"], "de.uniflow.plus.yearly", "otid-r", days=-1, signed_offset=10000)
        apple_store.apply_transaction(conn, u["id"], expired, notification=("EXPIRED", "VOLUNTARY"))
        assert billing.gift_info(conn, u["id"])["active"]
    finally:
        conn.close()
    e = ent(hosted, h)
    assert e["plan"] == "pro_ai" and e["source"] == "gift" and e["subscriptions"]["app_store"] is False
    assert e["credits"]["allowance"] == 100


def test_unknown_or_deleted_account_is_named_and_skipped(hosted):
    from app import accounts
    u, h = user(hosted, "da@beispiel.de")
    weg, _ = user(hosted, "weg@beispiel.de")
    accounts.delete_account(weg["id"], "sehr-geheim-123")
    code, rows, summary = _run(["--email", "niemand@beispiel.de", "--email", "weg@beispiel.de", "--email", "da@beispiel.de",
                                "--plan", "pro_ai", "--unbefristet", "--ausfuehren"])
    assert code == 0, rows
    skipped = [r for r in rows if "kein aktives Konto" in r["ergebnis"]]
    assert [r["email"] for r in skipped] == ["n***@beispiel.de", "w***@beispiel.de"]
    assert "an 1 Konto/Konten: da@beispiel.de" in summary
    code, rows, _ = _run(["--email", "niemand@beispiel.de", "--plan", "pro_ai", "--unbefristet", "--ausfuehren"])
    assert code == 1 and len(rows) == 1


def test_gift_with_end_date_and_deleted_account_purges_it(hosted, monkeypatch):
    """--bis: gilt bis einschliesslich des Tages (Berlin), dann wieder der Tarif davor. Beim endgueltigen Loeschen des
    Kontos verschwindet das Geschenk mit den anderen Eintraegen."""
    from app import accounts, billing
    u, h = user(hosted, "befristet@beispiel.de")
    end = (dt.datetime.now(UTC) + dt.timedelta(days=10)).date()
    code, rows, summary = _run(["--email", "befristet@beispiel.de", "--plan", "plus", "--bis", end.isoformat(), "--ausfuehren"])
    assert code == 0 and rows[0]["tarif_jetzt"] == "plus" and end.strftime("%d.%m.%Y") in summary
    e = ent(hosted, h)
    assert e["plan"] == "plus" and e["source"] == "gift" and e["expires_at"] and e["will_renew"] is False
    conn = _conn()
    try:
        assert billing.current_plan(conn, u["id"], dt.datetime.now(UTC) + dt.timedelta(days=12)) == "free"
    finally:
        conn.close()
    accounts.delete_account(u["id"], "sehr-geheim-123")
    later = accounts.now() + dt.timedelta(days=31)
    monkeypatch.setattr(accounts, "now", lambda: later)
    assert accounts.purge_deleted() >= 1
    conn = _conn()
    try:
        assert conn.execute("SELECT COUNT(*) FROM entitlements WHERE user_id=?", (u["id"],)).fetchone()[0] == 0
    finally:
        conn.close()


def test_arguments_are_checked(hosted):
    assert _run([])[0] == 2
    code, _, msg = _run(["--email", "x@beispiel.de", "--unbefristet"])
    assert code == 2 and "--plan" in msg
    code, _, msg = _run(["--email", "x@beispiel.de", "--plan", "pro_ai"])
    assert code == 2 and "--unbefristet oder --bis" in msg
    code, _, msg = _run(["--email", "x@beispiel.de", "--plan", "pro_ai", "--bis", "2020-01-01"])
    assert code == 2 and "Zukunft" in msg
    code, _, msg = _run(["--email", "x@beispiel.de", "--plan", "pro_ai", "--zuruecknehmen"])
    assert code == 2 and "ohne --plan" in msg
    with pytest.raises(SystemExit):
        _run(["--email", "x@beispiel.de", "--plan", "free", "--unbefristet"])
    with pytest.raises(SystemExit):
        _run(["--email", "x@beispiel.de", "--plan", "pro_ai", "--unbefristet", "--bis", "2030-01-01"])


def test_grant_gift_rejects_free_and_past_end():
    import sqlite3
    from app import billing
    conn = sqlite3.connect(":memory:", isolation_level=None)
    billing.ensure_schema(conn)
    with pytest.raises(ValueError):
        billing.grant_gift(conn, "u1", "free")
    with pytest.raises(ValueError):
        billing.grant_gift(conn, "u1", "pro_ai", until=dt.datetime.now(UTC) - dt.timedelta(days=1))
    r = billing.grant_gift(conn, "u1", "pro_connect")          # alter Schluessel gilt wie Pro AI
    assert r["plan"] == "pro_ai" and r["ends_at"] is None
    assert billing.current_plan(conn, "u1") == "pro_ai"


def test_gift_has_no_http_route_and_tools_wrapper_imports_the_module():
    from pathlib import Path
    root = Path(__file__).resolve().parents[1]
    users = sorted(p.relative_to(root).as_posix() for p in (root / "app").rglob("*.py")
                   if "grant_gift" in p.read_text(encoding="utf-8"))
    assert users == ["app/billing.py", "app/tarif_schenken.py"], "schenken nur ueber das Betriebs-Werkzeug"
    tf = (root / "app" / "tarif_schenken.py").read_text(encoding="utf-8")
    assert "router" not in tf and "fastapi" not in tf.lower() and "--ausfuehren" in tf
    t = (root / "tools" / "tarif-schenken.py").read_text(encoding="utf-8")
    assert "from app.tarif_schenken import main" in t and "python -m app.tarif_schenken" in t

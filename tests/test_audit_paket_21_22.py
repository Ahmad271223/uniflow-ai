"""Audit Paket 21 (billing-/Kontingent-Teil) und Paket 22 (app/billing.py, app/access.py), externer statischer Bericht vom
08.11.2026; Ergebnisse in docs/audit/AUDIT-2026-11-08-PAKET-21-22.md.

Je Befund ein Test: bestaetigt -> erst rot, dann behoben; sonst nagelt der Test das richtige Verhalten fest. Alles auf
leeren Datenbanken im Temp-Datenordner (conftest), nie auf echten Daten, kein Anbieter, kein Server.
"""
from __future__ import annotations

import json
import re
import sqlite3
import threading
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest
from conftest import asgi_call
from test_subscriptions import FakeAI, _j, end_trial, hosted, user  # noqa: F401 - hosted ist eine Fixture

ROOT = Path(__file__).resolve().parents[1]
T0 = datetime(2026, 11, 8, 10, 0, tzinfo=UTC)


def _conn():
    from app import billing
    return billing.connect()


def _uid(email: str) -> str:
    from app import accounts
    return accounts.register(email, "sehr-geheim-123", "luh")["id"]


# ================================================================ Paket 21 (billing-Teil)

# ---------------------------------------------------------------- P21-05 usage_requests waechst ohne Ende
def test_p21_05_retention_prunes_old_usage_requests(hosted):
    """Die Anfrage-IDs braucht nur der laufende Monat (Doppelte) und der vorige (spaeter refund ueber die Monatsgrenze);
    aeltere Zeilen raeumt der taegliche Lauf weg. Die Zaehler (usage) bleiben unberuehrt."""
    from app import billing, retention
    uid = _uid("p2105@beispiel.de")
    conn = _conn()
    try:
        for i, month in enumerate(("2026-08", "2026-09", "2026-10", "2026-11")):
            billing.consume(conn, uid, "ai_tests_new", f"r{i}", now=datetime.fromisoformat(f"{month}-15T12:00:00+00:00"), plan="pro_ai")
    finally:
        conn.close()
    out = retention.purge_account_db(T0)
    assert out["usage_requests"] == 2
    conn = _conn()
    try:
        assert [r[0] for r in conn.execute("SELECT period FROM usage_requests ORDER BY period")] == ["2026-10", "2026-11"]
        assert conn.execute("SELECT COUNT(*) FROM usage WHERE user_id=?", (uid,)).fetchone()[0] == 4
    finally:
        conn.close()


def test_p21_05_retention_dry_run_counts_only(hosted):
    from app import billing, retention
    uid = _uid("p2105b@beispiel.de")
    conn = _conn()
    try:
        billing.consume(conn, uid, "ai_tests_new", "alt", now=datetime(2026, 6, 1, tzinfo=UTC), plan="pro_ai")
    finally:
        conn.close()
    assert retention.purge_account_db(T0, dry_run=True)["usage_requests"] == 1
    conn = _conn()
    try:
        assert conn.execute("SELECT COUNT(*) FROM usage_requests").fetchone()[0] == 1
    finally:
        conn.close()


# ---------------------------------------------------------------- P21-06 users.plan ohne plan_until
def test_p21_06_legacy_plan_without_until_is_permanent_but_only_set_by_operations(hosted):
    """Absicht (Produktentscheidung): users.plan ohne plan_until ist eine Dauerberechtigung des Betriebs. Neue Konten
    haben keine; nur accounts.set_plan (CLI `python -m app.accounts plan`) schreibt users.plan, kein HTTP-Endpunkt."""
    from app import accounts, billing
    uid = _uid("p2106@beispiel.de")
    u = accounts.get_user(uid)
    assert billing.normalize_plan(u.get("plan")) in (None, "free")
    conn = _conn()
    try:
        assert billing.current_plan(conn, uid, T0, {"plan": "pro_ai", "plan_until": None}) == "pro_ai"
        assert billing.current_plan(conn, uid, T0, {"plan": "pro_ai", "plan_until": "2026-11-07"}) in ("pro_ai", "free")
        assert billing.current_plan(conn, "x", T0, {"plan": "pro_ai", "plan_until": "2026-11-07"}) == "free"
        assert billing.current_plan(conn, "x", T0, {"plan": "pro_ai", "plan_until": "2026-11-08"}) == "pro_ai", "bis einschliesslich"
        assert billing.current_plan(conn, "x", T0, {"plan": "kaputt", "plan_until": None}) == "free"
    finally:
        conn.close()
    writers = [p.name for p in (ROOT / "app").glob("*.py") if re.search(r"UPDATE users SET plan", p.read_text(encoding="utf-8"))]
    assert writers == ["accounts.py"]
    callers = [p.name for p in (ROOT / "app").glob("*.py")
               if p.name != "accounts.py" and re.search(r"\bset_plan\(", p.read_text(encoding="utf-8"))]
    assert callers == [], "set_plan nur ueber die CLI in app/accounts.py"


# ---------------------------------------------------------------- P21-07 Zeitvergleich als Zeichenkette
@pytest.mark.parametrize("expires,active", [
    ("2026-11-08T10:30:00+01:00", False),     # 09:30 UTC: schon vorbei (als Text "groesser")
    ("2026-11-08T10:30:00+00:00", True),
    ("2026-11-08T10:00:00Z", False),          # genau jetzt: vorbei
    ("2026-11-08T09:59:59.999999Z", False),
    ("2026-11-08T10:00:01Z", True),
    ("2026-11-08T11:30:00+02:00", False),     # 09:30 UTC
    ("2026-11-08T08:30:00-02:00", True),      # 10:30 UTC (als Text "kleiner")
    ("2026-11-08T10:30:00", True),            # ohne Zone = UTC
    ("2026-12-01", True),
])
def test_p21_07_expiry_compares_instants_not_strings(expires, active):
    from app import billing
    assert billing._row_active("active", expires, T0.isoformat()) is active


def test_p21_07_set_entitlement_stores_utc(hosted):
    from app import billing
    uid = _uid("p2107@beispiel.de")
    conn = _conn()
    try:
        billing.set_entitlement(conn, uid, "stripe", "plus", original_transaction_id="sub_1", expires_at="2026-11-08T10:30:00+01:00", now=T0)
        row = conn.execute("SELECT expires_at FROM entitlements WHERE user_id=? AND source='stripe'", (uid,)).fetchone()
        assert row[0] == "2026-11-08T09:30:00+00:00"
        assert billing.current_plan(conn, uid, T0 + timedelta(days=30)) == "free"
    finally:
        conn.close()


# ---------------------------------------------------------------- P21-08 Migration usage_requests
def test_p21_08_migration_from_old_layout_runs_once_across_parallel_starts(tmp_path):
    """Alte Tabelle (PRIMARY KEY request_id): zwei Prozesse (hier Faeden mit eigenen Verbindungen) migrieren zugleich;
    das Ergebnis ist das neue Layout mit allen Zeilen, keine Restetabelle, Zaehler unberuehrt."""
    from app import billing
    p = tmp_path / "accounts.db"
    c = sqlite3.connect(p, isolation_level=None)
    c.execute("PRAGMA journal_mode=WAL")
    c.execute("CREATE TABLE usage_requests (request_id TEXT PRIMARY KEY, user_id TEXT NOT NULL, period TEXT NOT NULL, "
              "feature TEXT NOT NULL, created_at TEXT NOT NULL)")
    c.execute("CREATE TABLE usage (user_id TEXT NOT NULL, period TEXT NOT NULL, feature TEXT NOT NULL, count INTEGER NOT NULL DEFAULT 0, "
              "PRIMARY KEY (user_id, period, feature))")
    for i in range(50):
        c.execute("INSERT INTO usage_requests VALUES (?,?,?,?,?)", (f"r{i}", f"u{i % 5}", "2026-11", "ai_tests_new", "t"))
    c.execute("INSERT INTO usage VALUES ('u1','2026-11','ai_tests_new',10)")
    c.close()
    errors: list = []
    start = threading.Barrier(4)

    def run():
        conn = sqlite3.connect(p, isolation_level=None, timeout=15)
        try:
            start.wait()
            billing.ensure_schema(conn)
        except Exception as e:      # noqa: BLE001
            errors.append(e)
        finally:
            conn.close()
    ts = [threading.Thread(target=run) for _ in range(4)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    assert errors == []
    c = sqlite3.connect(p)
    cols = {r[1]: r[5] for r in c.execute("PRAGMA table_info(usage_requests)")}
    assert cols["user_id"] and cols["request_id"], "zusammengesetzter Schluessel"
    assert c.execute("SELECT COUNT(*) FROM usage_requests").fetchone()[0] == 50
    assert c.execute("SELECT count FROM usage WHERE user_id='u1'").fetchone()[0] == 10
    assert not c.execute("SELECT 1 FROM sqlite_master WHERE name='usage_requests_new'").fetchone()
    c.close()


# ---------------------------------------------------------------- P21-09 consume und Leistung getrennt
def test_p21_09_crash_after_consume_costs_one_item_never_a_second_charge(hosted):
    """Absicht: bricht der Prozess nach consume ab, bleibt das Element gezaehlt (zu Lasten des Kontos, nie der Kasse);
    dieselbe ID zaehlt nie ein zweites Mal (duplicate), ein neuer Versuch braucht eine neue ID. KI-Kosten selbst laufen
    ueber credits.reserve/settle mit Verfall liegengebliebener Reservierungen (Audit Paket 1-2, 6-8)."""
    from app import billing
    uid = _uid("p2109@beispiel.de")
    conn = _conn()
    try:
        r1 = billing.consume(conn, uid, "ai_tests_new", "x", now=T0, plan="plus")
        r2 = billing.consume(conn, uid, "ai_tests_new", "x", now=T0, plan="plus")
        assert (r1.ok, r1.used, r2.duplicate, r2.used) == (True, 1, True, 1)
        assert billing.used(conn, uid, "ai_tests_new", T0) == 1
    finally:
        conn.close()


# ---------------------------------------------------------------- P21-10 refund trifft den falschen Monat
def test_p21_10_refund_with_period_hits_exactly_the_booked_month(hosted):
    from app import billing
    uid = _uid("p2110@beispiel.de")
    oct_, nov = datetime(2026, 10, 31, 23, 59, tzinfo=UTC), datetime(2026, 11, 1, 0, 1, tzinfo=UTC)
    conn = _conn()
    try:
        r_oct = billing.consume(conn, uid, "ai_tests_new", "gleich", now=oct_, plan="plus")
        r_nov = billing.consume(conn, uid, "ai_tests_new", "gleich", now=nov, plan="plus")
        assert (r_oct.period, r_nov.period) == ("2026-10", "2026-11")
        # der verspaetete refund der Oktober-Anfrage trifft den Oktober, nicht den November
        assert billing.refund(conn, uid, "ai_tests_new", "gleich", period=r_oct.period) is True
        assert (billing.used(conn, uid, "ai_tests_new", oct_), billing.used(conn, uid, "ai_tests_new", nov)) == (0, 1)
        assert billing.refund(conn, uid, "ai_tests_new", "gleich", period="2026-10") is False, "zweimal: nichts mehr"
        # ohne period wie bisher: der juengste Monat
        assert billing.refund(conn, uid, "ai_tests_new", "gleich") is True
        assert billing.used(conn, uid, "ai_tests_new", nov) == 0
    finally:
        conn.close()


def test_p21_10_entitlements_refund_passes_the_period(hosted, monkeypatch):
    import inspect
    from app import entitlements
    assert "period" in inspect.signature(entitlements.refund).parameters


# ================================================================ Paket 22

def _token_of(app, email, plan="free", trial=False):
    """Konto mit gewuenschtem Stand; liefert (user, token)."""
    from app import accounts
    st, d = _j(asgi_call(app, "POST", "/api/account/register",
                         body=json.dumps({"email": email, "password": "sehr-geheim-123", "university": "luh"})))
    assert st == 201, d
    if not trial:
        end_trial(d["user"]["id"])
    accounts.mark_email_verified(d["user"]["id"])
    if plan != "free":
        accounts.set_plan(d["user"]["id"], plan)
    return d["user"], d["token"]


def _call(app, method, path, token, client, body=None):
    from app import account_api
    headers, cookies = {}, None
    if client == "web":
        cookies = f"{account_api.COOKIE}={token}"
    else:
        headers["Authorization"] = f"Bearer {token}"
        if client in ("windows", "ipad"):
            headers["X-StudiNow-Client"] = client
    return _j(asgi_call(app, method, path, headers=headers, cookies=cookies, body=json.dumps(body or {})))


# ---------------------------------------------------------------- P22-01 Client-Kennung
def test_p22_01_client_header_never_unlocks_paid_features(hosted):
    """Bearer ohne Kopfzeile (iPad) ist Absicht: dort gilt Free wie bisher (Free darf Free-Funktionen schreiben). Ein
    gefaelschtes "ipad"/fehlendes Merkmal bringt nie ein bezahltes Recht; Web/Windows sperren zusaetzlich das Schreiben."""
    from app import access
    _, tok = _token_of(hosted, "p2201@beispiel.de")
    stack = {"name": "Stapel"}
    for client, want in (("app", 403), ("ipad", 403), ("windows", 402), ("web", 402)):
        st, d = _call(hosted, "POST", "/api/flashcard-stacks", tok, client, stack)
        assert st == want, (client, st, d)
        assert d["code"] == ("plan_required" if want == 403 else "subscription_required"), (client, d)
    # Free-Funktion schreiben: auf dem iPad ja, in Web/Windows ohne Abo nein
    assert _call(hosted, "POST", "/api/tasks/skip", tok, "app", {"task_ids": []})[0] == 200
    assert _call(hosted, "POST", "/api/tasks/skip", tok, "windows", {"task_ids": []})[0] == 402

    class R:
        def __init__(self, h):
            self.headers = h
    assert access.client_type(R({"authorization": "Bearer x", "x-studinow-client": "IPAD"})) == "app"
    assert access.client_type(R({"authorization": "Bearer x", "x-studinow-client": " Windows "})) == "windows"
    assert access.client_type(R({})) == "web"
    assert access.client_type(R({"authorization": "Basic abc", "x-studinow-client": "app"})) == "web"


# ---------------------------------------------------------------- P22-02 Pfadpraefixe bei Sperre
# Jede schreibende Route unter den Praefixen, die eine Sperre durchlassen, mit Begruendung. Kommt eine neue dazu, faellt
# dieser Test, bis jemand entschieden hat, ob sie ohne Abo gehen darf.
LOCKED_WRITE_ROUTES = {
    ("POST", "/api/account/register"), ("POST", "/api/account/login"), ("POST", "/api/account/login/{provider}"),
    ("POST", "/api/account/link/{provider}"), ("DELETE", "/api/account/identities/{provider}"),
    ("DELETE", "/api/account/sessions/{session_id}"), ("POST", "/api/account/logout"), ("POST", "/api/account/logout-all"),
    ("POST", "/api/account/password"), ("POST", "/api/account/password/reset-request"), ("POST", "/api/account/verify-email"),
    ("POST", "/api/account/verify-email/resend"), ("POST", "/api/account/password/reset"), ("POST", "/api/account/university"),
    ("POST", "/api/account/delete"),
    ("POST", "/api/billing/apple/verify"), ("POST", "/api/billing/stripe/checkout"), ("POST", "/api/billing/stripe/portal"),
    ("POST", "/api/billing/stripe/webhook"), ("POST", "/api/billing/plan-choice"), ("POST", "/api/billing/apple/notifications"),
    ("POST", "/api/billing/offer-codes"),                       # nur Admin (Admins sind ohnehin von der Pflicht ausgenommen)
    ("POST", "/api/app-login/code"), ("POST", "/api/app-login/token"),
}


def _routes(app):
    """Schreibende Routen (Methode, Pfad), auch aus eingebundenen Routern (FastAPI: _IncludedRouter.original_router)."""
    out = set()

    def walk(routes):
        for r in routes:
            inner = getattr(r, "original_router", None)
            if inner is not None:
                walk(inner.routes)
                continue
            path, methods = getattr(r, "path", ""), getattr(r, "methods", None) or set()
            for m in methods - {"GET", "HEAD", "OPTIONS"}:
                out.add((m, path))
    walk(app.router.routes)
    assert len(out) > 50, "Routen nicht gefunden"
    return out


def test_p22_02_every_write_route_behind_the_locked_prefixes_is_known(hosted):
    from app import access
    found = {(m, p) for m, p in _routes(hosted) if p.startswith(access.LOCKED_WRITE_PREFIXES)}
    assert found == LOCKED_WRITE_ROUTES


def test_p22_02_prefix_needs_the_slash_and_dot_segments_do_not_escape(hosted):
    from app import access
    assert not access.write_allowed_when_locked("POST", "/api/accountx")
    assert not access.write_allowed_when_locked("POST", "/api/billing")
    assert access.write_allowed_when_locked("GET", "/api/flashcards")
    _, tok = _token_of(hosted, "p2202@beispiel.de")
    for path in ("/api/account/../tasks/skip", "/api/account/%2e%2e/tasks/skip", "/api/billing/..%2ftasks/skip"):
        st, _ = _call(hosted, "POST", path, tok, "windows", {"task_ids": []})
        assert st != 200, path          # Starlette loest ".." nicht auf: keine Route dahinter


# ---------------------------------------------------------------- P22-03 Quelle bei mehreren gleichrangigen Zeilen
def test_p22_03_status_source_is_paid_with_the_latest_end(hosted):
    from app import accounts, billing
    uid = _uid("p2203@beispiel.de")              # mit Probe (pro_ai)
    conn = _conn()
    try:
        now = datetime.now(UTC)
        billing.set_entitlement(conn, uid, "app_store", "pro_ai", original_transaction_id="a1",
                                expires_at=(now + timedelta(days=10)).isoformat())
        billing.set_entitlement(conn, uid, "stripe", "pro_ai", original_transaction_id="sub_1",
                                expires_at=(now + timedelta(days=40)).isoformat())
        st = billing.status(conn, accounts.get_user(uid))
        assert (st["plan"], st["source"]) == ("pro_ai", "stripe")
        assert st["expires_at"] == billing._utc_iso((now + timedelta(days=40)).isoformat())
        billing.set_entitlement(conn, uid, "app_store", "pro_ai", original_transaction_id="a1", expires_at=None)
        assert billing.status(conn, accounts.get_user(uid))["source"] == "app_store", "unbefristet zuerst"
    finally:
        conn.close()


def test_p22_03_trial_is_never_the_source_beside_a_paid_row(hosted):
    from app import accounts, billing
    uid = _uid("p2203b@beispiel.de")
    conn = _conn()
    try:
        billing.set_entitlement(conn, uid, "stripe", "pro_ai", original_transaction_id="sub_2",
                                expires_at=(datetime.now(UTC) + timedelta(days=2)).isoformat())
        assert billing.status(conn, accounts.get_user(uid))["source"] == "stripe"
    finally:
        conn.close()


# ---------------------------------------------------------------- P22-04 Probe-Ende ohne Zeitzone
def test_p22_04_trial_info_with_naive_or_z_timestamps(hosted):
    from app import billing
    uid = _uid("p2204@beispiel.de")
    conn = _conn()
    try:
        conn.execute("UPDATE entitlements SET expires_at='2026-11-09T10:00:00' WHERE user_id=? AND source='trial'", (uid,))
        tr = billing.trial_info(conn, uid, T0)
        assert (tr["active"], tr["days_left"]) == (True, 1)
        conn.execute("UPDATE entitlements SET expires_at='2026-11-08T09:00:00Z' WHERE user_id=? AND source='trial'", (uid,))
        assert billing.trial_info(conn, uid, T0)["expired"] is True
        conn.execute("UPDATE entitlements SET expires_at='kaputt' WHERE user_id=? AND source='trial'", (uid,))
        assert billing.trial_info(conn, uid, T0)["active"] is False
    finally:
        conn.close()


# ---------------------------------------------------------------- P22-05 Rechte je Tarif und Client ueber die API
@pytest.mark.parametrize("plan,trial,flash,ai", [
    ("free", False, (403, 402), (403, 402)),
    ("free", True, (200, 200), (200, 200)),
    ("plus", False, (200, 200), (403, 403)),
    ("pro_ai", False, (200, 200), (200, 200)),
])
def test_p22_05_server_side_rights_per_plan_and_client(hosted, plan, trial, flash, ai):
    """(iPad, Web/Windows): Karteikarten ab Plus, StudiNow-KI ab Pro AI; Free ohne Abo in Web/Windows: 402."""
    from app import ai_backend
    ai_backend.set_provider(FakeAI())
    _, tok = _token_of(hosted, f"p2205-{plan}-{int(trial)}@beispiel.de", plan=plan, trial=trial)
    for i, client in enumerate(("app", "windows", "web")):
        want_f, want_a = (flash[0], ai[0]) if client == "app" else (flash[1], ai[1])
        st, d = _call(hosted, "POST", "/api/flashcard-stacks", tok, client, {"name": f"S{i}"})
        assert st == want_f, (client, st, d)
        st, d = _call(hosted, "POST", "/api/ai/tutor", tok, client,
                      {"mode": "explain", "page_text": "Was ist ein Vektor?", "request_id": f"r-{client}"})
        assert st == want_a, (client, st, d)


# ---------------------------------------------------------------- P22-06 set_entitlement ueberschreibt
def test_p22_06_late_event_of_another_subscription_does_not_overwrite_the_running_one(hosted):
    from app import billing
    uid = _uid("p2206@beispiel.de")
    conn = _conn()
    try:
        later = (T0 + timedelta(days=30)).isoformat()
        assert billing.set_entitlement(conn, uid, "app_store", "pro_ai", original_transaction_id="B", expires_at=later, now=T0) is True
        # spaete Meldung zum alten Abo A (abgelaufen) kommt danach
        assert billing.set_entitlement(conn, uid, "app_store", "plus", original_transaction_id="A",
                                       expires_at=(T0 - timedelta(days=1)).isoformat(), status="expired", now=T0) is False
        assert billing.current_plan(conn, uid, T0) == "pro_ai"
        row = conn.execute("SELECT original_transaction_id, status FROM entitlements WHERE user_id=? AND source='app_store'", (uid,)).fetchone()
        assert tuple(row) == ("B", "active")
        # dasselbe Abo B: jede Meldung wird uebernommen (auch Ablauf, Widerruf)
        assert billing.set_entitlement(conn, uid, "app_store", "pro_ai", original_transaction_id="B", expires_at=later,
                                       status="revoked", now=T0) is True
        assert billing.current_plan(conn, uid, T0) != "pro_ai" or billing.trial_info(conn, uid, T0)["active"]
        # neues Abo C nach Ablauf von B: besser, wird uebernommen
        assert billing.set_entitlement(conn, uid, "app_store", "plus", original_transaction_id="C", expires_at=later, now=T0) is True
        assert conn.execute("SELECT original_transaction_id FROM entitlements WHERE user_id=? AND source='app_store'", (uid,)).fetchone()[0] == "C"
    finally:
        conn.close()


def test_p22_06_stale_events_are_already_dropped_by_the_callers():
    """Gleiches Abo, Meldungen ausser der Reihe: apple_store.apply_transaction (signedDate) und
    stripe_billing.apply_subscription (event_created) verwerfen aeltere Meldungen, bevor set_entitlement laeuft."""
    apple = (ROOT / "app" / "apple_store.py").read_text(encoding="utf-8")
    stripe = (ROOT / "app" / "stripe_billing.py").read_text(encoding="utf-8")
    assert "stale = bool(seen and signed and signed < seen[1])" in apple and "if not stale:" in apple
    assert "event_created < last[0]" in stripe and '"stale_event"' in stripe


# ---------------------------------------------------------------- P22-07 Probe verlaengern ist privilegiert
def test_p22_07_extend_trial_has_no_http_route():
    users = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "app").rglob("*.py")
                   if "extend_trial" in p.read_text(encoding="utf-8"))
    assert users == ["app/billing.py", "app/tester_freischalten.py"]
    tf = (ROOT / "app" / "tester_freischalten.py").read_text(encoding="utf-8")
    assert "router" not in tf and "@app." not in tf and "fastapi" not in tf.lower()
    assert "--ausfuehren" in tf, "ohne --ausfuehren nur Probelauf"


def test_p22_07_no_route_writes_a_trial(hosted):
    for m, p in _routes(hosted):
        assert "trial" not in p.lower(), (m, p)


# ---------------------------------------------------------------- P22-08 end_trial bei schon abgelaufener Probe
def test_p22_08_end_trial_marks_an_expired_but_active_row(hosted):
    from app import billing
    uid = _uid("p2208@beispiel.de")
    conn = _conn()
    try:
        conn.execute("UPDATE entitlements SET expires_at=? WHERE user_id=? AND source='trial'", ((T0 - timedelta(days=1)).isoformat(), uid))
        assert billing.end_trial(conn, uid, now=T0) is False, "lief nicht mehr"
        row = conn.execute("SELECT status, expires_at FROM entitlements WHERE user_id=? AND source='trial'", (uid,)).fetchone()
        assert tuple(row) == ("expired", (T0 - timedelta(days=1)).isoformat()), "Stand angeglichen, Ende unveraendert"
        assert billing.end_trial(conn, uid, now=T0) is False
        assert billing.start_trial(conn, uid, now=T0) is None, "startet nicht erneut"
    finally:
        conn.close()


# ---------------------------------------------------------------- P22-09 ein Stand fuer for_user
def test_p22_09_for_user_reads_in_one_snapshot(hosted, monkeypatch):
    from app import access, accounts, billing
    uid = _uid("p2209@beispiel.de")
    seen: list = []
    real = billing.connect

    class Spy:
        def __init__(self, c):
            self.c = c

        def execute(self, sql, *a):
            if sql.lstrip().upper().startswith("SELECT"):
                seen.append(self.c.in_transaction)
            return self.c.execute(sql, *a)

        def __getattr__(self, name):
            return getattr(self.c, name)
    monkeypatch.setattr(billing, "connect", lambda: Spy(real()))
    acc = access.for_user(accounts.get_user(uid), "web")
    assert acc["state"] == "trial"
    assert seen and all(seen), seen


def test_p22_09_status_reads_in_one_snapshot(hosted):
    from app import accounts, billing
    uid = _uid("p2209b@beispiel.de")
    conn = _conn()
    try:
        st = billing.status(conn, accounts.get_user(uid))
        assert st["plan"] == "pro_ai" and not conn.in_transaction, "Transaktion wieder zu"
        conn.execute("BEGIN")
        billing.status(conn, accounts.get_user(uid))
        assert conn.in_transaction, "fremde Transaktion bleibt offen"
        conn.execute("COMMIT")
    finally:
        conn.close()


# ---------------------------------------------------------------- P22-10 Tarifwahl nach der Probe
def test_p22_10_plan_choice_after_trial_buy_and_cancel(hosted):
    """Aufforderung nur: Probe vorbei, kein bezahlter Tarif, noch keine Antwort. Nach Kauf keine; nach Ablauf des Kaufs
    ohne fruehere Antwort wieder (Produktentscheidung: eine Antwort genuegt fuer immer). Gesperrt in Web/Windows ist
    davon unabhaengig (access.evaluate) und hat immer einen Text mit dem Weg hinaus."""
    from app import access, accounts, billing
    uid = _uid("p2210@beispiel.de")
    conn = _conn()
    try:
        billing.end_trial(conn, uid, now=T0)
        assert billing.needs_plan_choice(conn, uid, "free", T0) is True
        billing.set_entitlement(conn, uid, "stripe", "plus", original_transaction_id="sub_x",
                                expires_at=(T0 + timedelta(days=30)).isoformat(), now=T0)
        assert billing.needs_plan_choice(conn, uid, billing.current_plan(conn, uid, T0), T0) is False
        later = T0 + timedelta(days=31)
        assert billing.current_plan(conn, uid, later) == "free"
        assert billing.needs_plan_choice(conn, uid, "free", later) is True
        billing.record_plan_choice(conn, uid, "free", now=later)
        assert billing.needs_plan_choice(conn, uid, "free", later) is False
        st = billing.status(conn, accounts.get_user(uid), now=later)
    finally:
        conn.close()
    acc = access.for_status(st, "web")
    assert (acc["state"], acc["locked"]) == ("subscription_required", True) and "Plus" in acc["message"]
    assert access.for_status(st, "app")["state"] == "free"

"""Audit Paket 1 und 2 (externer statischer Bericht vom 08.11.2026; docs/audit/AUDIT-2026-11-08-PAKET-1-2.md).

Paket 1: app/credits.py Funktionen 1-20 und app/accounts.py 21-30, Befunde B01-B04.
Paket 2: app/accounts.py Funktionen 31-60, Befunde B02-01 bis B02-08.

Je Funktion mindestens ein Normal- und ein Grenzfall; je Befund ein Test, der ihn entweder reproduziert (dann behoben)
oder das richtige Verhalten festnagelt (widerlegt bzw. nicht erreichbar). Alles auf einer leeren accounts.db im
Temp-Datenordner (conftest), nie auf echten Daten.
"""
from __future__ import annotations

import json
import sqlite3
import threading
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest
from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]
PW = "sehr-geheim-123"


# ---------------------------------------------------------------- Hilfen

@pytest.fixture
def hosted(app, monkeypatch):
    """Gehosteter Modus mit leerer Kontodatenbank; Versandwege und Pruefer leer; gesammelte Zeitstempel verworfen."""
    from app import accounts, config
    monkeypatch.setattr(config, "MODE", "hosted")

    def wipe():
        for suffix in ("", "-wal", "-shm"):
            accounts.db_path().with_name(accounts.db_path().name + suffix).unlink(missing_ok=True)
    wipe()
    monkeypatch.setattr(accounts, "identity_verifiers", {})
    monkeypatch.setattr(accounts, "reset_sender", None)
    monkeypatch.setattr(accounts, "verify_sender", None)
    with accounts._seen_lock:
        accounts._seen_pending.clear()
    yield app
    with accounts._seen_lock:
        accounts._seen_pending.clear()
    wipe()


def _j(resp):
    st, _, b = resp
    return st, (json.loads(b) if b else None)


def _auth(token):
    return {"Authorization": f"Bearer {token}"}


def _threads(n, fn):
    out: list = []
    lock = threading.Lock()
    start = threading.Barrier(n)

    def run(i):
        start.wait()
        try:
            r = fn(i)
        except Exception as e:  # noqa: BLE001 - Ergebnis des Fadens
            r = e
        with lock:
            out.append(r)
    ts = [threading.Thread(target=run, args=(i,)) for i in range(n)]
    [t.start() for t in ts]
    [t.join(60) for t in ts]
    return out


def _user(email="a@beispiel.de", plan=None, trial=True):
    """Konto ohne Probe (Standard der Tarif-Tests) oder mit laufender Probe; optional Tarif von Hand."""
    from app import accounts
    u = accounts.register(email, PW, "luh")
    if not trial:
        accounts.end_trial(u["id"])
    if plan:
        accounts.set_plan(u["id"], plan)
    return u["id"]


def _count(sql, *args):
    from app import accounts
    with accounts.cursor() as c:
        return c.execute(sql, args).fetchone()[0]


T0 = datetime(2026, 11, 10, 9, 0, tzinfo=UTC)


# ================================================================ PAKET 1 – app/credits.py (1-20)

# 1 _now
def test_01_now_keeps_the_instant_and_defaults_to_utc():
    from app import credits
    berlin = datetime(2026, 3, 29, 3, 30, tzinfo=credits.TZ)              # direkt nach der Umstellung auf Sommerzeit
    t = credits._now(berlin)
    assert t.tzinfo == UTC and t == berlin and t.hour == 1, "aware: derselbe Augenblick, nur in UTC"
    auto = credits._now(None)
    assert auto.tzinfo == UTC and abs((auto - datetime.now(UTC)).total_seconds()) < 5
    naive = datetime(2026, 6, 1, 12, 0)
    assert credits._now(naive) == naive.astimezone(UTC), "naiv gilt als Ortszeit des Rechners (kein Aufrufer in app/ gibt naive Zeiten)"


def test_01_no_caller_in_app_passes_a_naive_datetime():
    """Alle `now=`-Argumente an credits kommen aus Tests oder sind None; app/ uebergibt keine naiven Datetimes."""
    import re
    hits = []
    for p in (ROOT / "app").glob("*.py"):
        if p.name == "credits.py":
            continue
        for m in re.finditer(r"credits\.(reserve|settle|refund|balance|lookup|record_free|admin_costs|period_of|day_of|resets_at)\([^)]*\)", p.read_text(encoding="utf-8")):
            if "now=" in m.group(0):
                hits.append((p.name, m.group(0)))
    assert hits == [], hits


# 2-4 period_of, day_of, resets_at
@pytest.mark.parametrize("utc, period, day", [
    (datetime(2026, 1, 31, 23, 30, tzinfo=UTC), "2026-02", "2026-02-01"),        # Berlin ist schon im Februar
    (datetime(2026, 1, 31, 22, 59, tzinfo=UTC), "2026-01", "2026-01-31"),        # noch Januar (23:59 Berlin)
    (datetime(2026, 12, 31, 23, 30, tzinfo=UTC), "2027-01", "2027-01-01"),       # Silvester
    (datetime(2026, 3, 28, 23, 30, tzinfo=UTC), "2026-03", "2026-03-29"),        # Nacht der Sommerzeit-Umstellung
    (datetime(2026, 6, 30, 22, 30, tzinfo=UTC), "2026-07", "2026-07-01"),        # Sommerzeit: +2 h
    (datetime(2026, 10, 25, 0, 30, tzinfo=UTC), "2026-10", "2026-10-25"),        # Rueckstellung auf Winterzeit
])
def test_02_03_period_and_day_follow_berlin(utc, period, day):
    from app import credits
    assert (credits.period_of(utc), credits.day_of(utc)) == (period, day)


@pytest.mark.parametrize("utc, resets", [
    (datetime(2026, 1, 15, 12, 0, tzinfo=UTC), "2026-02-01T00:00:00+01:00"),
    (datetime(2026, 12, 15, 12, 0, tzinfo=UTC), "2027-01-01T00:00:00+01:00"),    # Dezember -> Januar des Folgejahres
    (datetime(2026, 6, 15, 12, 0, tzinfo=UTC), "2026-07-01T00:00:00+02:00"),     # Versatz des Folgemonats (Sommerzeit)
    (datetime(2026, 10, 15, 12, 0, tzinfo=UTC), "2026-11-01T00:00:00+01:00"),    # Folgemonat wieder Winterzeit
    (datetime(2026, 3, 31, 22, 30, tzinfo=UTC), "2026-05-01T00:00:00+02:00"),    # Berlin ist schon April
])
def test_04_resets_at_is_the_first_of_the_next_berlin_month(utc, resets):
    from app import credits
    assert credits.resets_at(utc) == resets


# 5 ensure_schema (B02)
def test_05_B02_ensure_schema_sees_only_fresh_autocommit_connections(hosted):
    """B02: `if conn.in_transaction: conn.commit()` kann nur eine offene Transaktion des Aufrufers festschreiben. Jede
    Aufrufstelle (credits.connect, ai_backend.connect ueber db.schema_once) uebergibt eine frisch geoeffnete
    Autocommit-Verbindung ohne Transaktion; executescript wuerde eine offene Transaktion ohnehin beenden."""
    from app import ai_backend, credits
    for conn in (credits.connect(), ai_backend.connect()):
        try:
            assert conn.isolation_level is None and not conn.in_transaction
            credits.ensure_schema(conn)                                   # idempotent
            credits.ensure_schema(conn)
            tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            assert {"credit_months", "credit_ledger"} <= tables
            assert not conn.in_transaction
        finally:
            conn.close()
    # Semantik dokumentiert: mit offener Transaktion wird deren Inhalt festgeschrieben - deshalb nur frische Verbindungen
    conn = credits.connect()
    try:
        conn.execute("BEGIN")
        conn.execute("INSERT INTO credit_months(user_id, period, allowance, created_at, updated_at) VALUES ('x','2026-01',1,'t','t')")
        assert conn.in_transaction
        credits.ensure_schema(conn)
        assert not conn.in_transaction
        assert conn.execute("SELECT COUNT(*) FROM credit_months WHERE user_id='x'").fetchone()[0] == 1
    finally:
        conn.close()


# 6 connect
def test_06_connect_wal_schema_and_parallel_first_start(hosted):
    from app import credits
    conn = credits.connect()
    try:
        assert conn.execute("PRAGMA journal_mode").fetchone()[0] == "wal"
        assert conn.execute("PRAGMA synchronous").fetchone()[0] == 1, "NORMAL"
        assert conn.execute("SELECT COUNT(*) FROM credit_ledger").fetchone()[0] == 0
    finally:
        conn.close()
    with pytest.raises(sqlite3.ProgrammingError):
        conn.execute("SELECT 1")                                        # geschlossen
    # Erststart auf einer neuen Datei aus mehreren Faeden (db.wal_once / schema_once)
    for suffix in ("", "-wal", "-shm"):
        from app import accounts
        accounts.db_path().with_name(accounts.db_path().name + suffix).unlink(missing_ok=True)

    def first(_i):
        c = credits.connect()
        try:
            return c.execute("SELECT COUNT(*) FROM credit_months").fetchone()[0]
        finally:
            c.close()
    out = _threads(8, first)
    assert out == [0] * 8, out


# 7 _int_env
@pytest.mark.parametrize("raw, expected", [("0", 0), ("-5", 0), ("", 100), ("abc", 100), ("12", 12), ("99999999999", 99999999999),
                                           (" 7", 7), (None, 100)])
def test_07_int_env(monkeypatch, raw, expected):
    from app import credits
    if raw is None:
        monkeypatch.delenv("LERNAPP_AUDIT_X", raising=False)
    else:
        monkeypatch.setenv("LERNAPP_AUDIT_X", raw)
    assert credits._int_env("LERNAPP_AUDIT_X", 100) == expected


# 8 plan_and_trial (B03)
def test_08_plan_and_trial_normal_cases(hosted):
    from app import credits
    uid = _user("p@beispiel.de")
    conn = credits.connect()
    try:
        assert credits.plan_and_trial(conn, uid) == ("pro_ai", True), "neues Konto: Probe mit Pro-AI-Umfang"
        from app import accounts
        accounts.set_plan(uid, "pro_ai")
        assert credits.plan_and_trial(conn, uid) == ("pro_ai", False), "von Hand gesetzter Tarif schlaegt die Probe"
        accounts.set_plan(uid, "free")
        accounts.end_trial(uid)
        assert credits.plan_and_trial(conn, uid) == ("free", False)
        assert credits.plan_and_trial(conn, "gibt-es-nicht") == ("free", False)
    finally:
        conn.close()


class _Flaky:
    """Verbindung, die bei der users-Abfrage einen bestimmten OperationalError wirft, sonst durchreicht."""

    def __init__(self, conn, message):
        self._c, self._m = conn, message

    def execute(self, sql, *a):
        if "FROM users" in sql:
            raise sqlite3.OperationalError(self._m)
        return self._c.execute(sql, *a)

    def __getattr__(self, name):
        return getattr(self._c, name)


def test_08_B03_missing_users_table_is_legacy_but_real_db_errors_surface(hosted):
    """B03: nur die Schema-Faelle (keine users-Tabelle/Spalte, z. B. Tests und Werkzeuge auf einer reinen Billing-Datei)
    gelten als 'kein Altbestand'; ein echter Datenbankfehler darf nicht still als Tarif 'free' enden (sonst 429
    credits_exhausted statt einer sichtbaren Stoerung)."""
    from app import credits
    conn = credits.connect()
    try:
        assert credits.plan_and_trial(conn, "u1") == ("free", False), "ohne users-Tabelle: kein Altbestand"
        assert credits.plan_and_trial(_Flaky(conn, "no such table: users"), "u1") == ("free", False)
        assert credits.plan_and_trial(_Flaky(conn, "no such column: plan_until"), "u1") == ("free", False)
        for msg in ("database is locked", "disk I/O error", "unable to open database file"):
            with pytest.raises(sqlite3.OperationalError):
                credits.plan_and_trial(_Flaky(conn, msg), "u1")
    finally:
        conn.close()


# 9 allowance
def test_09_allowance_trial_wins_and_zero_is_allowed(monkeypatch):
    from app import credits
    assert credits.allowance("unbekannt", True) == 25, "Probe zaehlt auch bei unbekanntem Tarifnamen"
    monkeypatch.setenv("LERNAPP_CREDITS_PRO_AI", "0")
    assert credits.allowance("pro_ai", False) == 0
    monkeypatch.setenv("LERNAPP_CREDITS_TRIAL", "-3")
    assert credits.allowance("free", True) == 0, "negativ wird 0"


# 10 _month
def test_10_month_row_follows_plan_changes_and_month_boundaries(hosted):
    from app import accounts, credits
    uid = _user("m@beispiel.de", trial=False)
    conn = credits.connect()
    try:
        conn.execute("BEGIN IMMEDIATE")
        row = credits._month(conn, uid, T0)
        conn.execute("COMMIT")
        assert tuple(row) == (0, 0, 0, "free")
        accounts.set_plan(uid, "pro_ai")                                 # Upgrade mitten im Monat: sofort 100
        conn.execute("BEGIN IMMEDIATE")
        conn.execute("UPDATE credit_months SET used=60 WHERE user_id=?", (uid,))
        row = credits._month(conn, uid, T0)
        conn.execute("COMMIT")
        assert tuple(row) == (100, 60, 0, "pro_ai")
        accounts.set_plan(uid, "free")                                   # Downgrade: Verbrauch bleibt, Rest wird 0
        conn.execute("BEGIN IMMEDIATE")
        row = credits._month(conn, uid, T0)
        conn.execute("COMMIT")
        assert tuple(row) == (0, 60, 0, "free") and credits._balance_dict(row, T0)["remaining"] == 0
        conn.execute("BEGIN IMMEDIATE")
        row = credits._month(conn, uid, T0 + timedelta(days=31))         # neuer Monat: neue Zeile, used 0
        conn.execute("COMMIT")
        assert tuple(row) == (0, 0, 0, "free")
        assert conn.execute("SELECT COUNT(*) FROM credit_months WHERE user_id=?", (uid,)).fetchone()[0] == 2
    finally:
        conn.close()


# 11 _balance_dict
def test_11_balance_dict_clips_negative_rest_and_reports_period_and_reset():
    from app import credits
    d = credits._balance_dict((10, 8, 5, "pro_ai"), T0)
    assert d["remaining"] == 0 and d["period"] == "2026-11" and d["resets_at"] == "2026-12-01T00:00:00+01:00"
    assert d["credit_eur"] == 0.009 and d["plan"] == "pro_ai" and (d["allowance"], d["used"], d["reserved"]) == (10, 8, 5)
    assert credits._balance_dict((100, 20, 30, "x"), T0)["remaining"] == 50


# 12 _housekeeping
def test_12_housekeeping_expires_old_reservations_per_period_and_clears_old_results(hosted):
    from app import credits
    uid = _user("h@beispiel.de", plan="pro_ai", trial=False)
    conn = credits.connect()
    try:
        credits.balance(conn, uid, T0)
        old = T0 - timedelta(minutes=16)
        prev = T0 - timedelta(days=40)                                     # Vormonat
        credits.balance(conn, uid, prev)
        credits.reserve(conn, uid, "alt", "tutor", 10, now=old)
        credits.reserve(conn, uid, "jung", "tutor", 5, now=T0 - timedelta(minutes=14))
        credits.reserve(conn, uid, "vormonat", "tutor", 7, now=prev)
        credits.settle(conn, uid, "fertig", 0, result="x")                 # ohne Reservierung: bleibt wie er ist (0)
        credits.reserve(conn, uid, "antwort", "tutor", 1, now=T0 - timedelta(hours=25))
        credits.settle(conn, uid, "antwort", 9000, result="gespeichert", now=T0 - timedelta(hours=25))
        conn.execute("BEGIN IMMEDIATE")
        credits._housekeeping(conn, uid, T0)
        conn.execute("COMMIT")
        states = dict(conn.execute("SELECT request_id, state FROM credit_ledger WHERE user_id=?", (uid,)).fetchall())
        assert states == {"alt": "expired", "jung": "reserved", "vormonat": "expired", "antwort": "settled"}
        months = {r[0]: (r[1], r[2]) for r in conn.execute("SELECT period, used, reserved FROM credit_months WHERE user_id=?", (uid,))}
        assert months[credits.period_of(T0)] == (1, 5), "nur die junge Reservierung bleibt; Vormonat getrennt"
        assert months[credits.period_of(prev)] == (0, 0)
        assert conn.execute("SELECT result FROM credit_ledger WHERE request_id='antwort'").fetchone()[0] is None, "Antwort nach 24 h geleert"
        # eine Antwort juenger als 24 h bleibt
        credits.reserve(conn, uid, "frisch", "tutor", 1, now=T0)
        credits.settle(conn, uid, "frisch", 9000, result="bleibt", now=T0)
        conn.execute("BEGIN IMMEDIATE")
        credits._housekeeping(conn, uid, T0 + timedelta(hours=23))
        conn.execute("COMMIT")
        assert conn.execute("SELECT result FROM credit_ledger WHERE request_id='frisch'").fetchone()[0] == "bleibt"
    finally:
        conn.close()


# 13 balance
def test_13_balance_commits_or_rolls_back(hosted, monkeypatch):
    from app import credits
    uid = _user("b@beispiel.de", plan="pro_ai", trial=False)
    conn = credits.connect()
    try:
        assert credits.balance(conn, uid, T0)["remaining"] == 100 and not conn.in_transaction
        monkeypatch.setattr(credits, "_month", lambda *a: (_ for _ in ()).throw(RuntimeError("kaputt")))
        with pytest.raises(RuntimeError):
            credits.balance(conn, "neu", T0)
        assert not conn.in_transaction
        assert conn.execute("SELECT COUNT(*) FROM credit_months WHERE user_id='neu'").fetchone()[0] == 0, "Rollback"
    finally:
        conn.close()


# 14 lookup
def test_14_lookup_states(hosted):
    from app import credits
    uid = _user("l@beispiel.de", plan="pro_ai", trial=False)
    conn = credits.connect()
    try:
        assert credits.lookup(conn, uid, "nie", T0) is None
        credits.reserve(conn, uid, "r1", "tutor", 3, now=T0)
        assert credits.lookup(conn, uid, "r1", T0) == ("reserved", None)
        credits.settle(conn, uid, "r1", 9000, result="antwort", now=T0)
        assert credits.lookup(conn, uid, "r1", T0) == ("settled", "antwort")
        assert credits.lookup(conn, uid, "r1", T0 + timedelta(hours=25)) == ("settled", None), "nach 24 h ohne Antwort"
        credits.reserve(conn, uid, "r2", "tutor", 3, now=T0)
        assert credits.lookup(conn, uid, "r2", T0 + timedelta(minutes=16)) == ("expired", None)
        credits.reserve(conn, uid, "r3", "tutor", 3, now=T0)
        credits.refund(conn, uid, "r3")
        assert credits.lookup(conn, uid, "r3", T0) == ("refunded", None)
        assert credits.lookup(conn, "anderer", "r1", T0) is None, "je Konto"
    finally:
        conn.close()


# 15 funding_for
@pytest.mark.parametrize("shared, own, expected", [(True, True, "shared"), (True, False, "shared"), (False, True, "own_chatgpt"), (False, False, "credits")])
def test_15_funding_priority(shared, own, expected):
    from app import credits
    assert credits.funding_for(shared_hit=shared, own_chatgpt=own) == expected


# 16 reserve
def test_16_reserve_rules(hosted):
    from app import credits
    uid = _user("r@beispiel.de", plan="pro_ai", trial=False)
    conn = credits.connect()
    try:
        with pytest.raises(ValueError):
            credits.reserve(conn, uid, "", "tutor", 1, now=T0)
        r = credits.reserve(conn, uid, "a", "tutor", 0, now=T0)
        assert r.reserved == 1 and r.balance["reserved"] == 1, "Schaetzung mindestens 1"
        with pytest.raises(credits.CreditsError) as x:
            credits.reserve(conn, uid, "a", "tutor", 1, now=T0)
        assert (x.value.code, x.value.status) == ("duplicate_request", 409) and not conn.in_transaction
        credits.settle(conn, uid, "a", 9000, result="fertig", now=T0)
        again = credits.reserve(conn, uid, "a", "tutor", 50, now=T0)
        assert again.replay and again.result == "fertig" and again.reserved == 0 and again.charged == 1
        with pytest.raises(credits.CreditsError) as x:
            credits.reserve(conn, uid, "zu-gross", "tutor", 100, now=T0)       # Rest ist 99
        assert x.value.code == "credits_exhausted" and x.value.status == 429 and x.value.extra["credits"]["needed"] == 100
        assert x.value.message == credits.EXHAUSTED_MESSAGE
        assert conn.execute("SELECT COUNT(*) FROM credit_ledger WHERE request_id='zu-gross'").fetchone()[0] == 0
        # verfallen/zurueckgegeben: derselbe Versuch noch einmal nutzt die Zeile wieder
        credits.reserve(conn, uid, "b", "tutor", 10, now=T0)
        credits.refund(conn, uid, "b")
        r2 = credits.reserve(conn, uid, "b", "tutor", 20, now=T0 + timedelta(minutes=1), model="m2")
        assert r2.reserved == 20 and not r2.replay
        assert conn.execute("SELECT state, reserved, model FROM credit_ledger WHERE request_id='b'").fetchone() == ("reserved", 20, "m2")
        assert conn.execute("SELECT COUNT(*) FROM credit_ledger WHERE user_id=?", (uid,)).fetchone()[0] == 2
    finally:
        conn.close()


def test_16_parallel_reservations_on_separate_connections_never_exceed_the_allowance(hosted):
    from app import credits
    uid = _user("par@beispiel.de", plan="pro_ai", trial=False)

    def one(i):
        c = credits.connect()
        try:
            return credits.reserve(c, uid, f"p{i}", "tutor", 30, now=T0).reserved
        finally:
            c.close()
    out = _threads(10, one)
    ok = [o for o in out if isinstance(o, int)]
    errs = [o for o in out if not isinstance(o, int)]
    assert len(ok) == 3 and sum(ok) == 90 and all(getattr(e, "code", None) == "credits_exhausted" for e in errs), out
    conn = credits.connect()
    try:
        assert conn.execute("SELECT reserved FROM credit_months WHERE user_id=?", (uid,)).fetchone()[0] == 90
    finally:
        conn.close()


# 17 settle
def test_17_settle_caps_and_edge_cases(hosted):
    from app import credits
    uid = _user("s@beispiel.de", plan="pro_ai", trial=False)
    conn = credits.connect()
    try:
        assert credits.settle(conn, uid, "unbekannt", 9000, now=T0) == 0
        credits.reserve(conn, uid, "a", "tutor", 5, now=T0)
        assert credits.settle(conn, uid, "a", 90_000, now=T0) == 5, "nie mehr als reserviert (10 Credits echte Kosten)"
        assert credits.settle(conn, uid, "a", 1, now=T0) == 5, "zweite Abrechnung aendert nichts"
        row = conn.execute("SELECT used, reserved FROM credit_months WHERE user_id=?", (uid,)).fetchone()
        assert tuple(row) == (5, 0)
        assert conn.execute("SELECT cost_microeur FROM credit_ledger WHERE request_id='a'").fetchone()[0] == 90_000, "echte Kosten bleiben"
        credits.reserve(conn, uid, "neg", "tutor", 3, now=T0)
        assert credits.settle(conn, uid, "neg", -500, now=T0) == 0 and tuple(conn.execute(
            "SELECT used, reserved FROM credit_months WHERE user_id=?", (uid,)).fetchone()) == (5, 0)
        # verspaetet: Reservierung schon verfallen -> hoechstens der freie Rest
        credits.reserve(conn, uid, "spaet", "tutor", 10, now=T0)
        credits.balance(conn, uid, T0 + timedelta(minutes=16))                 # verfallen lassen
        assert credits.lookup(conn, uid, "spaet", T0 + timedelta(minutes=16)) == ("expired", None)
        assert credits.settle(conn, uid, "spaet", 2_000_000, now=T0 + timedelta(minutes=16)) == 95, "Rest 100-5"
        assert tuple(conn.execute("SELECT used, reserved FROM credit_months WHERE user_id=?", (uid,)).fetchone()) == (100, 0)
        # verfallen und Monatszeile fehlt: 0 Credits, aber abgeschlossen
        conn.execute("INSERT INTO credit_ledger(user_id, request_id, period, day, purpose, funding, state, reserved, created_at) "
                     "VALUES (?,?,?,?,?,?,?,?,?)", (uid, "ohne-monat", "2020-01", "2020-01-01", "tutor", "credits", "expired", 4, "2020-01-01T00:00:00+00:00"))
        assert credits.settle(conn, uid, "ohne-monat", 9000, now=T0) == 0
        assert conn.execute("SELECT state FROM credit_ledger WHERE request_id='ohne-monat'").fetchone()[0] == "settled"
    finally:
        conn.close()


# 18 refund
def test_18_refund_twice_and_after_settle(hosted):
    from app import credits
    uid = _user("f@beispiel.de", plan="pro_ai", trial=False)
    conn = credits.connect()
    try:
        credits.reserve(conn, uid, "a", "tutor", 7, now=T0)
        assert credits.refund(conn, uid, "a") is True and credits.refund(conn, uid, "a") is False
        assert tuple(conn.execute("SELECT used, reserved FROM credit_months WHERE user_id=?", (uid,)).fetchone()) == (0, 0)
        credits.reserve(conn, uid, "b", "tutor", 7, now=T0)
        credits.settle(conn, uid, "b", 18_000, now=T0)
        assert credits.refund(conn, uid, "b") is False and credits.refund(conn, uid, "nie") is False
        assert tuple(conn.execute("SELECT used, reserved FROM credit_months WHERE user_id=?", (uid,)).fetchone()) == (2, 0)
        # parallel settle/refund derselben Reservierung: genau eine Wirkung
        credits.reserve(conn, uid, "c", "tutor", 10, now=T0)

        def race(i):
            c = credits.connect()
            try:
                return credits.settle(c, uid, "c", 27_000, now=T0) if i % 2 else credits.refund(c, uid, "c")
            finally:
                c.close()
        out = _threads(6, race)
        assert not any(isinstance(o, Exception) for o in out), out
        state, charged = conn.execute("SELECT state, charged FROM credit_ledger WHERE request_id='c'").fetchone()
        used, reserved = conn.execute("SELECT used, reserved FROM credit_months WHERE user_id=?", (uid,)).fetchone()
        assert reserved == 0 and ((state, charged, used) == ("settled", 3, 5) or (state, charged, used) == ("refunded", 0, 2)), (state, charged, used)
    finally:
        conn.close()


# 19 record_free
def test_19_record_free_never_overwrites_a_charged_request(hosted):
    """INSERT OR IGNORE ist Absicht: traegt eine request_id schon eine Reservierung oder Abrechnung, bleibt diese Zeile
    (sonst koennte ein 'geteilter' Treffer eine echte Abrechnung ueberschreiben)."""
    from app import credits
    uid = _user("g@beispiel.de", plan="pro_ai", trial=False)
    conn = credits.connect()
    try:
        credits.record_free(conn, uid, "frei", "tutor:doc", "shared", now=T0, result="geteilt")
        row = conn.execute("SELECT state, funding, reserved, charged, result, period, day FROM credit_ledger WHERE request_id='frei'").fetchone()
        assert tuple(row) == ("free", "shared", 0, 0, "geteilt", "2026-11", "2026-11-10")
        assert credits.lookup(conn, uid, "frei", T0) == ("free", "geteilt")
        assert credits.reserve(conn, uid, "frei", "tutor", 5, now=T0).replay, "freie ID wird wiederholt, nicht neu berechnet"
        credits.reserve(conn, uid, "bezahlt", "tutor", 5, now=T0)
        credits.record_free(conn, uid, "bezahlt", "tutor:doc", "shared", now=T0)
        assert conn.execute("SELECT state, reserved FROM credit_ledger WHERE request_id='bezahlt'").fetchone() == ("reserved", 5)
        assert conn.execute("SELECT COUNT(*) FROM credit_months WHERE user_id=?", (uid,)).fetchone()[0] == 1, "record_free legt keine Monatszeile an"
    finally:
        conn.close()


# 20 admin_costs (B01)
def test_20_B01_admin_costs_window_is_exactly_days_calendar_days(hosted):
    """B01 behauptet: days=1 liefert bis zu drei Kalendertage. Tatsaechlich: since = heute - (days-1) Tage (Berlin),
    Filter day >= since -> genau `days` Kalendertage einschliesslich heute."""
    from app import credits
    conn = credits.connect()
    try:
        def row(day, period, cost):
            conn.execute("INSERT INTO credit_ledger(user_id, request_id, period, day, purpose, funding, state, model, charged, cost_microeur, created_at) "
                         "VALUES ('u', ?, ?, ?, 'tutor', 'credits', 'settled', 'm', 1, ?, 't')", (f"{day}-{cost}", period, day, cost))
        row("2026-02-27", "2026-02", 1000)
        row("2026-02-28", "2026-02", 2000)
        row("2026-03-01", "2026-03", 3000)
        row("2026-02-23", "2026-02", 4000)
        row("2026-02-22", "2026-02", 5000)
        now = datetime(2026, 2, 28, 23, 30, tzinfo=UTC)                   # 01.03. 00:30 Berlin
        d = credits.admin_costs(conn, 1, now)
        assert d["since"] == "2026-03-01" and [r["day"] for r in d["per_day_model"]] == ["2026-03-01"]
        assert d["month"]["period"] == "2026-03" and d["month"]["requests"] == 1 and d["month"]["cost_eur"] == 0.003
        d = credits.admin_costs(conn, 2, now)
        assert d["since"] == "2026-02-28" and [r["day"] for r in d["per_day_model"]] == ["2026-03-01", "2026-02-28"]
        d = credits.admin_costs(conn, 7, now)
        assert d["since"] == "2026-02-23" and [r["day"] for r in d["per_day_model"]] == ["2026-03-01", "2026-02-28", "2026-02-27", "2026-02-23"]
        assert credits.admin_costs(conn, 0, now)["since"] == "2026-03-01", "unter 1 wird 1"
        assert credits.admin_costs(conn, 1000, now)["since"] == "2025-03-01", "hoechstens 366 Tage"
        # UTC-Datum ist noch der 28.02., Berlin schon der 01.03.: das Fenster folgt Berlin wie die Spalte day
        assert now.strftime("%Y-%m-%d") == "2026-02-28"
    finally:
        conn.close()


# ================================================================ PAKET 1 – app/accounts.py (21-30)

# 21 now, 22 iso
def test_21_22_now_and_iso():
    from app import accounts
    t = accounts.now()
    assert t.tzinfo == UTC and t.microsecond == 0
    assert accounts.iso(datetime(2026, 1, 2, 3, 4, 5, tzinfo=UTC)) == "2026-01-02T03:04:05Z"
    assert accounts.iso(datetime(2026, 1, 2, 3, 4, 5, 678, tzinfo=UTC)) == "2026-01-02T03:04:05.000678Z"
    berlin = datetime(2026, 1, 2, 4, 4, 5, tzinfo=__import__("zoneinfo").ZoneInfo("Europe/Berlin"))
    assert accounts.iso(berlin) == "2026-01-02T04:04:05+01:00", "anderer Versatz bleibt stehen (nur UTC wird Z)"
    assert accounts.iso(datetime(2026, 1, 2, 3, 4, 5)) == "2026-01-02T03:04:05", "naiv: ohne Zone (kein Aufrufer uebergibt naive Zeiten)"
    # Zeitstrings vergleichen sich als Text korrekt, solange alle aus iso(now()) stammen
    assert accounts.iso(t) < accounts.iso(t + timedelta(seconds=1))


# 23 db_path, 25 cursor
def test_23_25_db_path_and_cursor_semantics(hosted):
    from app import accounts, config
    assert accounts.db_path() == config.BASE_DATA_DIR / "accounts.db" and "users" not in accounts.db_path().parts
    with accounts.cursor() as c:
        c.execute("INSERT INTO users(id, email, university, created_at) VALUES ('u1','u1@x.de','luh','t')")
    assert _count("SELECT COUNT(*) FROM users") == 1, "normaler Ausgang: commit"
    with pytest.raises(RuntimeError):
        with accounts.cursor() as c:
            c.execute("INSERT INTO users(id, email, university, created_at) VALUES ('u2','u2@x.de','luh','t')")
            raise RuntimeError("mitten drin")
    assert _count("SELECT COUNT(*) FROM users") == 1, "Ausnahme: nichts festgeschrieben (Rollback beim Schliessen)"
    with pytest.raises(sqlite3.IntegrityError):
        with accounts.cursor() as c:
            c.execute("INSERT INTO sessions(token_hash, user_id, created_at, last_seen_at, expires_at) VALUES ('h','niemand','t','t','t')")
    assert _count("SELECT COUNT(*) FROM sessions") == 0, "Fremdschluessel sind an"
    with accounts.cursor() as c:
        held = c
    with pytest.raises(sqlite3.ProgrammingError):
        held.execute("SELECT 1")                                         # Verbindung geschlossen


# 24 _migrate
def test_24_migrate_adds_email_to_old_identities_and_is_repeatable(tmp_path):
    from app import accounts
    conn = sqlite3.connect(tmp_path / "alt.db")
    conn.execute("CREATE TABLE identities (provider TEXT NOT NULL, subject TEXT NOT NULL, user_id TEXT NOT NULL, created_at TEXT NOT NULL, PRIMARY KEY (provider, subject))")
    conn.execute("INSERT INTO identities VALUES ('google','s1','u1','t')")
    accounts._migrate(conn)
    accounts._migrate(conn)
    cols = [r[1] for r in conn.execute("PRAGMA table_info(identities)")]
    # seit 12.11.2026 zusaetzlich das verschluesselte Apple-Refresh-Token fuer den Widerruf beim Loeschen (5.1.1(v))
    assert cols == ["provider", "subject", "user_id", "created_at", "email", "apple_refresh_enc", "apple_client_id"]
    assert conn.execute("SELECT email FROM identities").fetchone() == (None,), "alte Zeilen bleiben"
    conn.executescript(accounts.SCHEMA)                                 # aktuelles Schema dazu: keine Aenderung mehr noetig
    accounts._migrate(conn)
    assert [r[1] for r in conn.execute("PRAGMA table_info(identities)")] == cols
    conn.close()


# 26 normalize_email
@pytest.mark.parametrize("raw, expected", [(None, ""), ("", ""), ("  A.B@Example.DE \n", "a.b@example.de"), ("ÄÖ@Üni.DE", "äö@üni.de"),
                                           ("x@y.de", "x@y.de"), ("\tmax@uni.de ", "max@uni.de")])
def test_26_normalize_email(raw, expected):
    from app import accounts
    assert accounts.normalize_email(raw) == expected


# 27 validate_email
@pytest.mark.parametrize("email, ok", [("max@uni.de", True), ("max.mustermann+tag@stud.uni-hannover.de", True), ("äöü@uni.de", True),
                                       ("max@müller.de", True), ("max@uni.d", False), ("max@uni", False), ("max uni@x.de", False),
                                       ("max@@x.de", False), ("@x.de", False), ("max@x.de" + "a" * 250, False), ("a" * 240 + "@uni.de", True),
                                       ("a" * 248 + "@uni.de", False)])
def test_27_validate_email(email, ok):
    from app import accounts
    if ok:
        accounts.validate_email(email)
    else:
        with pytest.raises(accounts.AccountError) as x:
            accounts.validate_email(email)
        assert x.value.code == "email_invalid"


# 28 validate_password
@pytest.mark.parametrize("pw, email, code", [("a" * 9, "", "password_short"), ("a" * 10, "", None), ("a" * 200, "", None),
                                             ("a" * 201, "", "password_long"), (None, "", "password_short"),
                                             ("  MAX@UNI.DE ", "max@uni.de", "password_is_email"), ("max@uni.de", "", None),
                                             ("mit leer zeichen", "", None), ("         x", "", None)])
def test_28_validate_password(pw, email, code):
    from app import accounts
    if code:
        with pytest.raises(accounts.AccountError) as x:
            accounts.validate_password(pw, email)
        assert x.value.code == code
    else:
        accounts.validate_password(pw, email)


# 29 hash_password
def test_29_hash_password_salt_format_unicode():
    from app import accounts
    h1, h2 = accounts.hash_password("pässwört-✓-1234"), accounts.hash_password("pässwört-✓-1234")
    assert h1 != h2, "neues Salz je Aufruf"
    parts = h1.split("$")
    assert parts[:4] == ["scrypt", "16384", "8", "1"] and len(parts) == 6 and len(bytes.fromhex(parts[4])) == 16 and len(bytes.fromhex(parts[5])) == 32
    assert accounts.verify_password("pässwört-✓-1234", h1) and accounts.verify_password("pässwört-✓-1234", h2)
    assert not accounts.verify_password("pässwört-✓-1235", h1)
    assert accounts.hash_password("x" * 10, b"\x01" * 16) == accounts.hash_password("x" * 10, b"\x01" * 16), "gleiches Salz: gleicher Hash"


# 30 verify_password (B04)
@pytest.mark.parametrize("stored", [None, "", "scrypt", "scrypt$1$2$3", "bcrypt$16384$8$1$00$00", "scrypt$abc$8$1$00$00",
                                    "scrypt$16384$8$1$zz$00", "scrypt$16384$8$1$00$zz", "scrypt$16384$8$1$00$00$extra"])
def test_30_verify_password_rejects_corrupt_hashes(stored):
    from app import accounts
    assert accounts.verify_password("egal-egal-egal", stored) is False


def test_30_B04_unbounded_scrypt_parameters_are_not_reachable_and_oversized_ones_fail_fast(hosted):
    """B04: n, r, p stammen aus dem gespeicherten Hash. Den schreibt nur hash_password (feste SCRYPT-Parameter); ein
    Nutzer erreicht pw_hash nie. Ausserdem lehnt OpenSSL zu grosse Parameter sofort ab (Speichergrenze 32 MiB), statt
    minutenlang zu rechnen."""
    import time
    from app import accounts
    uid = _user("hash@beispiel.de")
    with accounts.cursor() as c:
        stored = c.execute("SELECT pw_hash FROM users WHERE id=?", (uid,)).fetchone()[0]
    assert stored.startswith(f"scrypt${accounts.SCRYPT['n']}${accounts.SCRYPT['r']}${accounts.SCRYPT['p']}$")
    salt = "00" * 16
    t = time.monotonic()
    assert accounts.verify_password("x", f"scrypt${2 ** 20}$8$1${salt}${'00' * 32}") is False
    assert accounts.verify_password("x", f"scrypt$16384$8${2 ** 20}${salt}${'00' * 32}") is False
    assert accounts.verify_password("x", f"scrypt$16384${2 ** 16}$1${salt}${'00' * 32}") is False
    assert time.monotonic() - t < 2, "sofort abgelehnt, nicht gerechnet"
    assert accounts.verify_password("x", f"scrypt$15$8$1${salt}${'00' * 32}") is False, "n keine Zweierpotenz"
    # nichts in app/ schreibt pw_hash ausser hash_password (bzw. NULL beim Loeschen/Anbieter-Konto)
    import re
    writes = []
    for p in (ROOT / "app").glob("*.py"):
        for m in re.finditer(r"pw_hash\s*=\s*(\?|NULL)", p.read_text(encoding="utf-8")):
            writes.append((p.name, m.group(0)))
    assert {w[0] for w in writes} == {"accounts.py"}, writes


# ================================================================ PAKET 2 – app/accounts.py (31-60)

# 31 _token_hash
def test_31_token_hash():
    from app import accounts
    assert accounts._token_hash("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    assert accounts._token_hash("tök€n") == accounts._token_hash("tök€n") != accounts._token_hash("token")
    assert len(accounts._token_hash("x")) == 64


# 32 _public
def test_32_public_whitelists_fields(hosted):
    from app import accounts
    uid = _user("pub@beispiel.de")
    with accounts.cursor() as c:
        u = c.execute("SELECT * FROM users WHERE id=?", (uid,)).fetchone()
        pub = accounts._public(u)
    assert set(pub) == {"id", "email", "email_verified", "university", "plan", "plan_until", "role", "created_at"}
    assert pub["email_verified"] is False and "pw_hash" not in pub and "status" not in pub


# 33 _locked, 34 _fail, 35 _clear_fails
def test_33_34_35_fail_counters_thresholds_windows_and_keys(hosted, monkeypatch):
    from app import accounts
    with accounts.cursor() as c:
        for _ in range(7):
            accounts._fail(c, "email:x@y.de")
        assert accounts._locked(c, "email:x@y.de") is False, "7 von 8"
        accounts._fail(c, "email:x@y.de")
        assert accounts._locked(c, "email:x@y.de") is True
        monkeypatch.setenv("LERNAPP_LOGIN_FAILS_IP", "3")
        for _ in range(2):
            accounts._fail(c, "ip:1.2.3.4")
        assert accounts._locked(c, "ip:1.2.3.4") is False
        accounts._fail(c, "ip:1.2.3.4")
        assert accounts._locked(c, "ip:1.2.3.4") is True
        monkeypatch.setenv("LERNAPP_LOGIN_FAILS_IP", "0")
        assert accounts.max_fails_ip() == accounts.MAX_FAILS_IP and accounts._locked(c, "ip:1.2.3.4") is False
        monkeypatch.setenv("LERNAPP_LOGIN_FAILS_IP", "kaputt")
        assert accounts.max_fails_ip() == accounts.MAX_FAILS_IP
        # manipulierter Zeitstempel: ohne last_fail_at nie gesperrt; Sperre laeuft nach 10 Minuten ab
        c.execute("UPDATE login_attempts SET last_fail_at=NULL WHERE key='email:x@y.de'")
        assert accounts._locked(c, "email:x@y.de") is False
        c.execute("UPDATE login_attempts SET last_fail_at=? WHERE key='email:x@y.de'", (accounts.iso(accounts.now() - timedelta(minutes=10, seconds=1)),))
        assert accounts._locked(c, "email:x@y.de") is False
        c.execute("UPDATE login_attempts SET last_fail_at=? WHERE key='email:x@y.de'", (accounts.iso(accounts.now() - timedelta(minutes=9)),))
        assert accounts._locked(c, "email:x@y.de") is True
        # _fail nach dem Fenster faengt bei 1 an
        accounts._fail(c, "email:x@y.de")
        assert c.execute("SELECT fails FROM login_attempts WHERE key='email:x@y.de'").fetchone()[0] == 9
        c.execute("UPDATE login_attempts SET last_fail_at=? WHERE key='email:x@y.de'", (accounts.iso(accounts.now() - timedelta(minutes=11)),))
        accounts._fail(c, "email:x@y.de")
        assert c.execute("SELECT fails FROM login_attempts WHERE key='email:x@y.de'").fetchone()[0] == 1
        # _clear_fails loescht nur die genannten Schluessel
        accounts._clear_fails(c, "email:x@y.de", "gibt-es-nicht")
        assert [r[0] for r in c.execute("SELECT key FROM login_attempts")] == ["ip:1.2.3.4"]


def test_34_43_parallel_wrong_passwords_are_all_rejected_and_counted(hosted):
    from app import accounts
    _user("par@beispiel.de")
    out = _threads(8, lambda i: accounts.login("par@beispiel.de", "falsch-falsch", client_ip="10.0.0.9"))
    assert all(isinstance(o, accounts.AccountError) and o.code == "credentials_invalid" for o in out), out
    fails = _count("SELECT fails FROM login_attempts WHERE key='email:par@beispiel.de'")
    assert 1 <= fails <= 8
    assert _count("SELECT fails FROM login_attempts WHERE key='ip:10.0.0.9'") >= 1


# 36 _limit
@pytest.mark.parametrize("raw, expected", [("", (3, 60)), ("0/60", (3, 60)), ("-1/5", (3, 60)), ("abc", (3, 60)), ("10", (3, 60)),
                                           ("10/0", (3, 60)), ("1000000/1", (1000000, 1)), (" 5/7 ", (5, 7)), ("5/7/9", (3, 60))])
def test_36_limit_env_parsing(monkeypatch, raw, expected):
    from app import accounts
    monkeypatch.setenv("LERNAPP_LIMIT_RESET_EMAIL", raw)
    assert accounts._limit("reset_email") == expected


# 37 _hit (B02-01), 38 hit_limit
def test_37_B02_01_hit_commits_only_counters_because_every_caller_counts_first(hosted, monkeypatch):
    """B02-01: `_hit` committet die Verbindung des Aufrufers - absichtlich (der Zaehler muss auch nach einer fachlichen
    Ausnahme stehen). Jede Aufrufstelle zaehlt, BEVOR sie fachlich schreibt, darum schreibt der Commit nie Teilzustaende."""
    from app import accounts
    monkeypatch.setenv("LERNAPP_LIMIT_REGISTER_IP", "2/60")
    _user("erste@beispiel.de")
    with pytest.raises(accounts.AccountError) as x:
        accounts.register("erste@beispiel.de", PW, "luh", client_ip="9.9.9.9")
    assert x.value.code == "email_taken"
    assert _count("SELECT count FROM rate_limits WHERE key='register_ip:9.9.9.9'") == 1, "gezaehlt trotz Ausnahme"
    assert _count("SELECT COUNT(*) FROM users") == 1, "kein Teilzustand"
    with pytest.raises(accounts.AccountError):
        accounts.register("erste@beispiel.de", PW, "luh", client_ip="9.9.9.9")
    with pytest.raises(accounts.AccountError) as x:
        accounts.register("dritte@beispiel.de", PW, "luh", client_ip="9.9.9.9")
    assert (x.value.code, x.value.status) == ("rate_limited", 429) and x.value.retry_after and x.value.retry_after <= 3601
    assert _count("SELECT count FROM rate_limits WHERE key='register_ip:9.9.9.9'") == 2 and _count("SELECT COUNT(*) FROM users") == 1
    # Reihenfolge am Code: in register, request_password_reset, request_email_verification kommt _hit vor dem ersten
    # INSERT/UPDATE desselben Blocks
    src = (ROOT / "app" / "accounts.py").read_text(encoding="utf-8")
    for fn in ("def register(", "def request_password_reset(", "def request_email_verification("):
        body = src.split(fn, 1)[1].split("\ndef ", 1)[0]
        assert body.index("_hit(") < min(i for i in (body.find("INSERT"), body.find("UPDATE")) if i >= 0), fn


def test_37_38_hit_window_and_hit_limit(hosted, monkeypatch):
    from app import accounts
    monkeypatch.setenv("LERNAPP_LIMIT_EXPORT_USER", "2/1")
    accounts.hit_limit("export_user", "u1")
    accounts.hit_limit("export_user", "u1")
    with pytest.raises(accounts.AccountError) as x:
        accounts.hit_limit("export_user", "u1")
    assert x.value.status == 429 and 1 <= x.value.retry_after <= 61 and "Minute" in x.value.message
    accounts.hit_limit("export_user", "u2")                               # anderer Schluessel unberuehrt
    with accounts.cursor() as c:
        c.execute("UPDATE rate_limits SET window_start=? WHERE key='export_user:u1'", (accounts.iso(accounts.now() - timedelta(minutes=2)),))
    accounts.hit_limit("export_user", "u1")                               # neues Fenster
    assert _count("SELECT count FROM rate_limits WHERE key='export_user:u1'") == 1


# 39 register (B02-02), 40 grant_trial, 41 end_trial
def test_39_B02_02_register_leaves_no_account_when_the_trial_cannot_be_granted(hosted, monkeypatch):
    """B02-02: Konto-Insert und Probe liefen in zwei Transaktionen; ein Fehler bei der Probe liess ein Konto ohne Probe
    zurueck (Antwort 500, zweiter Versuch 409 email_taken). Jetzt: beides oder nichts."""
    from app import accounts, billing

    def boom(*a, **k):
        raise sqlite3.OperationalError("database is locked")
    monkeypatch.setattr(billing, "start_trial", boom)
    with pytest.raises(sqlite3.OperationalError):
        accounts.register("probe@beispiel.de", PW, "luh")
    assert _count("SELECT COUNT(*) FROM users") == 0, "kein Konto ohne Probe"
    monkeypatch.undo()
    u = accounts.register("probe@beispiel.de", PW, "luh")
    assert u["email"] == "probe@beispiel.de"
    assert _count("SELECT COUNT(*) FROM entitlements WHERE user_id=? AND source='trial'", u["id"]) == 1


def test_39_40_41_register_trial_and_end(hosted):
    from app import accounts
    with pytest.raises(accounts.AccountError) as x:
        accounts.register("x@y.de", PW, "mars")
    assert x.value.code == "university_unknown" and _count("SELECT COUNT(*) FROM users") == 0
    with pytest.raises(accounts.AccountError) as x:
        accounts.register("kein-at", PW, "luh")
    assert x.value.code == "email_invalid"
    u = accounts.register("Neu@Beispiel.DE", PW, "hildesheim")
    assert u["email"] == "neu@beispiel.de" and u["plan"] == "free" and u["email_verified"] is False
    accounts.grant_trial(u["id"])                                        # zweiter Aufruf: unveraendert
    assert _count("SELECT COUNT(*) FROM entitlements WHERE user_id=? AND source='trial'", u["id"]) == 1
    assert accounts.end_trial(u["id"]) is True and accounts.end_trial(u["id"]) is False
    accounts.grant_trial(u["id"])
    assert _count("SELECT COUNT(*) FROM entitlements WHERE user_id=? AND source='trial' AND status='expired'", u["id"]) == 1, "keine zweite Probe"
    assert accounts.end_trial("niemand") is False


# 42 create_session
def test_42_create_session_tokens_and_device_fields(hosted):
    from app import accounts
    uid = _user("s@beispiel.de")
    with accounts.cursor() as c:
        t1 = accounts.create_session(c, uid, "g" * 200, "n" * 300)
        t2 = accounts.create_session(c, uid, "", None)
        assert t1 != t2 and len(t1) >= 43
        rows = c.execute("SELECT device_id, device_name, created_at, expires_at FROM sessions WHERE user_id=? ORDER BY id", (uid,)).fetchall()
    assert (len(rows[0]["device_id"]), len(rows[0]["device_name"])) == (80, 120)
    assert rows[1]["device_id"] is None and rows[1]["device_name"] is None
    exp = datetime.fromisoformat(rows[0]["expires_at"].replace("Z", "+00:00"))
    assert exp - datetime.fromisoformat(rows[0]["created_at"].replace("Z", "+00:00")) == timedelta(days=30)
    assert _count("SELECT COUNT(*) FROM sessions WHERE token_hash IN (?,?)", t1, t2) == 0, "nur Hashes gespeichert"


# 43 login
def test_43_login_cases(hosted):
    from app import accounts
    uid = _user("l@beispiel.de")
    with pytest.raises(accounts.AccountError) as x:
        accounts.login("l@beispiel.de", "falsch-falsch")
    assert (x.value.code, x.value.status) == ("credentials_invalid", 401)
    with pytest.raises(accounts.AccountError) as x:
        accounts.login("niemand@beispiel.de", PW)
    assert x.value.code == "credentials_invalid", "unbekanntes Konto: dieselbe Meldung"
    u, tok = accounts.login(" L@Beispiel.de ", PW, device_id="d1")
    assert u["id"] == uid and accounts.authenticate(tok)["id"] == uid
    assert _count("SELECT COUNT(*) FROM login_attempts WHERE key='email:l@beispiel.de'") == 0, "Erfolg loescht die Zaehler des Kontos"
    assert _count("SELECT COUNT(*) FROM login_attempts") == 1, "der Zaehler der unbekannten Adresse bleibt"
    accounts.delete_account(uid, PW)
    with pytest.raises(accounts.AccountError):
        accounts.login("l@beispiel.de", PW)                              # geloeschtes Konto


# 44 authenticate
def test_44_authenticate_boundaries_and_deferred_extension(hosted):
    from app import accounts
    uid = _user("a@beispiel.de")
    _, tok = accounts.login("a@beispiel.de", PW)
    h = accounts._token_hash(tok)
    with accounts.cursor() as c:
        c.execute("UPDATE sessions SET expires_at=? WHERE token_hash=?", (accounts.iso(accounts.now()), h))
    assert accounts.authenticate(tok) is None, "genau an der Grenze: abgelaufen"
    with accounts.cursor() as c:
        c.execute("UPDATE sessions SET expires_at=?, last_seen_at=? WHERE token_hash=?",
                  (accounts.iso(accounts.now() + timedelta(seconds=2)), accounts.iso(accounts.now() - timedelta(minutes=2)), h))
    assert accounts.authenticate(tok)["id"] == uid
    assert accounts.pending_seen() == 1, "Verlaengerung gesammelt, nicht sofort geschrieben"
    assert accounts.flush_seen() == 1 and accounts.pending_seen() == 0
    with accounts.cursor() as c:
        exp = c.execute("SELECT expires_at FROM sessions WHERE token_hash=?", (h,)).fetchone()[0]
    assert datetime.fromisoformat(exp.replace("Z", "+00:00")) > accounts.now() + timedelta(days=29)
    assert accounts.authenticate(tok)["id"] == uid and accounts.pending_seen() == 0, "innerhalb von 60 s kein zweites Mal"
    accounts.logout(tok)
    assert accounts.authenticate(tok) is None and accounts.authenticate("") is None


# 45 logout, 46 logout_all, 47 revoke_session, 48 sessions
def test_45_46_47_48_sessions_lifecycle(hosted):
    from app import accounts
    uid = _user("s1@beispiel.de")
    other = _user("s2@beispiel.de")
    _, t1 = accounts.login("s1@beispiel.de", PW, device_id="ipad", device_name="iPad")
    _, t2 = accounts.login("s1@beispiel.de", PW, device_id="mac")
    _, t3 = accounts.login("s1@beispiel.de", PW, device_id="web")
    _, to = accounts.login("s2@beispiel.de", PW)
    lst = accounts.sessions(uid, t1)
    assert len(lst) == 3 and [s["current"] for s in lst].count(True) == 1 and {s["device_id"] for s in lst} == {"ipad", "mac", "web"}
    assert "token_hash" not in lst[0] and lst[0]["device_name"] in ("iPad", None)
    assert accounts.logout(t3) is True and accounts.logout(t3) is False and accounts.logout("fremd") is False and accounts.logout(None) is False
    s2 = [s for s in accounts.sessions(uid, t1) if s["device_id"] == "mac"][0]
    assert accounts.revoke_session(other, s2["id"]) is False, "fremde Sitzung nicht widerrufbar"
    assert accounts.revoke_session(uid, s2["id"]) is True and accounts.revoke_session(uid, s2["id"]) is False
    assert accounts.authenticate(t2) is None and accounts.authenticate(t1)["id"] == uid
    _, t4 = accounts.login("s1@beispiel.de", PW)
    assert accounts.logout_all(uid, keep_token=t1) == 1 and accounts.authenticate(t4) is None and accounts.authenticate(t1)["id"] == uid
    assert accounts.authenticate(to)["id"] == other, "anderer Nutzer unberuehrt"
    assert accounts.logout_all(uid) == 1 and accounts.authenticate(t1) is None and accounts.sessions(uid) == []
    # abgelaufene Sitzungen erscheinen nicht in der Liste
    _, t5 = accounts.login("s1@beispiel.de", PW)
    with accounts.cursor() as c:
        c.execute("UPDATE sessions SET expires_at=? WHERE token_hash=?", (accounts.iso(accounts.now()), accounts._token_hash(t5)))
    assert accounts.sessions(uid) == []


# 49 change_password (B02-03)
def test_49_B02_03_password_change_logs_out_other_devices_at_the_api(hosted):
    """B02-03: die Modulfunktion change_password widerruft keine Sitzungen - der API-Endpunkt /api/account/password tut
    es seit jeher (logout_all mit keep_token). Produktentscheidung: ob das auch in die Modulfunktion gehoert."""
    from app import accounts
    uid = _user("pw@beispiel.de")
    _, t1 = accounts.login("pw@beispiel.de", PW, device_id="a")
    _, t2 = accounts.login("pw@beispiel.de", PW, device_id="b")
    with pytest.raises(accounts.AccountError) as x:
        accounts.change_password(uid, "falsch-falsch", "noch-geheimer-456")
    assert x.value.code == "credentials_invalid"
    with pytest.raises(accounts.AccountError) as x:
        accounts.change_password(uid, PW, "kurz")
    assert x.value.code == "password_short"
    accounts.change_password(uid, PW, "noch-geheimer-456")
    assert accounts.authenticate(t1) and accounts.authenticate(t2), "Modulfunktion allein: Sitzungen bleiben (heutiger Stand)"
    assert accounts.login("pw@beispiel.de", "noch-geheimer-456")
    st, d = _j(asgi_call(hosted, "POST", "/api/account/password", headers=_auth(t1),
                         body=json.dumps({"old_password": "noch-geheimer-456", "new_password": "ganz-neu-789-abc"})))
    assert (st, d) == (200, {"ok": True})
    assert accounts.authenticate(t1)["id"] == uid and accounts.authenticate(t2) is None, "API: andere Geraete abgemeldet, dieses bleibt"
    st, _ = _j(asgi_call(hosted, "POST", "/api/account/password", headers=_auth(t1),
                         body=json.dumps({"old_password": "falsch-falsch", "new_password": "ganz-neu-789-abc"})))
    assert st == 401 and accounts.authenticate(t1)["id"] == uid


# 50 request_password_reset (B02-04)
def test_50_B02_04_reset_without_sender_creates_token_but_sends_nothing(hosted):
    from app import accounts
    uid = _user("r@beispiel.de")
    sent = []
    tok = accounts.request_password_reset("R@Beispiel.de ")
    assert tok and len(tok) >= 43 and _count("SELECT COUNT(*) FROM reset_tokens WHERE user_id=?", uid) == 1
    assert _count("SELECT COUNT(*) FROM reset_tokens WHERE token_hash=?", tok) == 0, "nur der Hash liegt in der Datenbank"
    accounts.reset_sender = lambda e, t: sent.append((e, t))
    tok2 = accounts.request_password_reset("r@beispiel.de", client_ip="1.1.1.1")
    assert sent == [("r@beispiel.de", tok2)]
    assert accounts.request_password_reset("niemand@beispiel.de", client_ip="1.1.1.1") is None and len(sent) == 1
    tok3 = accounts.request_password_reset("r@beispiel.de")
    assert accounts.request_password_reset("r@beispiel.de") is None, "4. Mail je Stunde: still, kein Versand"
    assert len(sent) == 2 and tok3, "drei Tokens je Stunde, zwei davon ueber den Versandweg"


def test_50_B02_04_hosted_service_wires_mail_and_the_env_template_names_the_smtp_mailbox(hosted, monkeypatch):
    """B02-04: Im Dienst haengt server.wire_hosted_services mail.send_reset ein. deploy/.env.example nennt SMTP-Host,
    Port und Absender (STRATO) und verlangt Nutzer/Passwort des Postfachs ('PFLICHT fuer den Versand'). Ohne SMTP-Host
    faellt der Versand auf mail.log zurueck - der Link geht nie verloren, er steht dann im Protokoll."""
    from app import accounts, config, mail, server
    server.wire_hosted_services()
    assert accounts.reset_sender is mail.send_reset and accounts.verify_sender is mail.send_verify
    env = (ROOT / "deploy" / ".env.example").read_text(encoding="utf-8")
    values = dict(line.split("=", 1) for line in env.splitlines() if line and not line.startswith("#") and "=" in line)
    assert values["LERNAPP_SMTP_HOST"] == "smtp.strato.de" and values["LERNAPP_SMTP_PORT"] == "465"
    assert values["LERNAPP_MAIL_FROM"].endswith("<no-reply@studinow.app>") and values["LERNAPP_PUBLIC_URL"]
    assert values["LERNAPP_SMTP_USER"] == "" and values["LERNAPP_SMTP_PASSWORD"] == "", "muss der Betreiber eintragen"
    assert "PFLICHT fuer den Versand" in env
    monkeypatch.delenv("LERNAPP_MAIL", raising=False)
    monkeypatch.setenv("LERNAPP_SMTP_HOST", "smtp.strato.de")
    assert config.is_hosted() and mail.mode() == "smtp"
    monkeypatch.setenv("LERNAPP_SMTP_HOST", "")
    assert mail.mode() == "log", "ohne SMTP-Host: Link in mail.log"
    monkeypatch.setattr(config, "MODE", "local")
    monkeypatch.setenv("LERNAPP_SMTP_HOST", "smtp.strato.de")
    assert mail.mode() == "log", "am eigenen PC nie SMTP ohne ausdrueckliche Wahl"


# 51 reset_password
def test_51_reset_password_once_expiry_and_parallel_redemption(hosted):
    """Ein Reset-Token gilt genau einmal - auch wenn vier Einloesungen gleichzeitig kommen (vorher gewannen alle)."""
    from app import accounts
    uid = _user("rp@beispiel.de")
    _, t1 = accounts.login("rp@beispiel.de", PW)
    with accounts.cursor() as c:
        c.execute("INSERT INTO identities(provider, subject, user_id, created_at) VALUES ('google','sub','" + uid + "','t')")
    tok = accounts.request_password_reset("rp@beispiel.de")
    with pytest.raises(accounts.AccountError) as x:
        accounts.reset_password(tok, "kurz")
    assert x.value.code == "password_short" and accounts.authenticate(t1), "ungueltiges Passwort verbraucht das Token nicht"
    accounts.reset_password(tok, "neues-passwort-123")
    assert accounts.authenticate(t1) is None and _count("SELECT COUNT(*) FROM identities WHERE user_id=?", uid) == 0
    assert _count("SELECT email_verified FROM users WHERE id=?", uid) == 1, "Link kam per Mail: Adresse bestaetigt"
    for bad in (tok, "", None, "x" * 50):
        with pytest.raises(accounts.AccountError) as x:
            accounts.reset_password(bad, "noch-ein-passwort-456")
        assert x.value.code == "reset_invalid"
    assert accounts.login("rp@beispiel.de", "neues-passwort-123")
    tok = accounts.request_password_reset("rp@beispiel.de")
    with accounts.cursor() as c:
        c.execute("UPDATE reset_tokens SET expires_at=? WHERE token_hash=?", (accounts.iso(accounts.now()), accounts._token_hash(tok)))
    with pytest.raises(accounts.AccountError):
        accounts.reset_password(tok, "abgelaufen-passwort-789")
    # parallel: genau eine Einloesung gewinnt
    tok = accounts.request_password_reset("rp@beispiel.de")
    out = _threads(4, lambda i: accounts.reset_password(tok, f"parallel-passwort-{i}"))
    ok = [o for o in out if o is None]
    assert len(ok) == 1 and all(isinstance(o, accounts.AccountError) and o.code == "reset_invalid" for o in out if o is not None), out
    winners = [i for i in range(4) if _login_ok("rp@beispiel.de", f"parallel-passwort-{i}")]
    assert len(winners) == 1


def _login_ok(email, pw):
    from app import accounts
    try:
        accounts.login(email, pw)
        return True
    except accounts.AccountError:
        return False


# 52 request_email_verification, 53 verify_email
def test_52_53_email_verification_flow(hosted):
    from app import accounts
    uid = _user("v@beispiel.de")
    sent = []
    accounts.verify_sender = lambda e, t: sent.append((e, t))
    assert accounts.request_email_verification("niemand") is None
    tok = accounts.request_email_verification(uid, send=False, count=False)
    assert tok and sent == []
    for _ in range(5):
        assert accounts.request_email_verification(uid)
    with pytest.raises(accounts.AccountError) as x:
        accounts.request_email_verification(uid)
    assert x.value.code == "rate_limited" and len(sent) == 5 and sent[0][0] == "v@beispiel.de"
    for bad in ("", None, "falsch"):
        with pytest.raises(accounts.AccountError) as x:
            accounts.verify_email(bad)
        assert x.value.code == "verify_invalid"
    with accounts.cursor() as c:                                         # Adresse inzwischen geaendert: Link gilt nicht
        c.execute("UPDATE users SET email='neu@beispiel.de' WHERE id=?", (uid,))
    with pytest.raises(accounts.AccountError):
        accounts.verify_email(tok)
    with accounts.cursor() as c:
        c.execute("UPDATE users SET email='v@beispiel.de' WHERE id=?", (uid,))
    u = accounts.verify_email(tok)
    assert u["email_verified"] is True
    with pytest.raises(accounts.AccountError):
        accounts.verify_email(tok)                                       # Replay
    assert accounts.request_email_verification(uid) is None, "schon bestaetigt"
    t2 = sent[-1][1]
    with pytest.raises(accounts.AccountError):
        accounts.verify_email(t2 + "x")
    with accounts.cursor() as c:
        c.execute("UPDATE verify_tokens SET expires_at=? WHERE token_hash=?", (accounts.iso(accounts.now()), accounts._token_hash(t2)))
        c.execute("UPDATE users SET email_verified=0 WHERE id=?", (uid,))
    with pytest.raises(accounts.AccountError):
        accounts.verify_email(t2)                                        # abgelaufen


# 54 mark_email_verified (B02-05)
def test_54_B02_05_mark_email_verified_has_no_api_or_app_caller(hosted):
    """B02-05: die Funktion prueft keine Berechtigung - sie wird in app/ nirgends aufgerufen (nur Werkzeuge in tools/
    und Tests), es gibt keinen Endpunkt dafuer."""
    from app import accounts
    callers = [p.name for p in (ROOT / "app").glob("*.py") if "mark_email_verified" in p.read_text(encoding="utf-8")]
    assert callers == ["accounts.py"], callers
    uid = _user("m@beispiel.de")
    assert accounts.mark_email_verified(uid)["email_verified"] is True
    assert accounts.mark_email_verified(uid)["email_verified"] is True, "wiederholbar"
    with pytest.raises(Exception):                                         # noqa: B017 - unbekanntes Konto: kein Treffer -> Fehler
        accounts.mark_email_verified("niemand")


# 55 verify_identity (B02-06)
def test_55_B02_06_verify_identity_error_paths(hosted):
    """B02-06: der Text einer Pruefer-Ausnahme landet in der Fehlermeldung. Erreichbar nur mit einem Pruefer in
    accounts.identity_verifiers - den setzt im Dienst niemand (app/ liest das Woerterbuch nur); der Dienst prueft
    ueber app/social_login.py. Empfehlung dokumentiert, kein Umbau."""
    from app import accounts
    setters = [p.name for p in (ROOT / "app").glob("*.py") if "identity_verifiers[" in p.read_text(encoding="utf-8")
               or "identity_verifiers =" in p.read_text(encoding="utf-8").replace("identity_verifiers: dict", "")]
    assert setters == [], setters
    with pytest.raises(accounts.AccountError) as x:
        accounts.verify_identity("google", "tok")
    assert (x.value.code, x.value.status) == ("provider_not_configured", 501)
    st, d = _j(asgi_call(hosted, "POST", "/api/account/login/google", body=json.dumps({"id_token": "x", "university": "luh"})))
    assert st == 501 and d["code"] == "provider_not_configured" and _count("SELECT COUNT(*) FROM users") == 0
    accounts.identity_verifiers["google"] = lambda tok, nonce=None: {"subject": ""}
    with pytest.raises(accounts.AccountError) as x:
        accounts.verify_identity("google", "tok")
    assert x.value.code == "identity_invalid" and x.value.status == 401
    accounts.identity_verifiers["google"] = lambda tok, nonce=None: (_ for _ in ()).throw(RuntimeError("intern: DSN=geheim"))
    with pytest.raises(accounts.AccountError) as x:
        accounts.verify_identity("google", "tok", nonce="n1")
    assert x.value.code == "identity_invalid"
    assert "intern: DSN=geheim" in x.value.message, "heutiger Stand (Befund B02-06, nur mit Test-Pruefern erreichbar)"


# 56 link_provider, 57 identities, 58 unlink_provider, 59 link_identity
def test_56_57_58_59_link_identities_unlink(hosted):
    from app import accounts
    uid = _user("li@beispiel.de")
    other = _user("li2@beispiel.de")
    with pytest.raises(accounts.AccountError) as x:
        accounts.link_provider(uid, "google", "sub1")
    assert (x.value.code, x.value.status) == ("email_unverified", 403)
    accounts.mark_email_verified(uid)
    accounts.mark_email_verified(other)
    assert accounts.link_provider(uid, "google", "sub1", "relay@privaterelay.appleid.com") == {"provider": "google", "linked": True}
    assert accounts.link_provider(uid, "google", "sub1") == {"provider": "google", "linked": True}, "doppelt: idempotent"
    with pytest.raises(accounts.AccountError) as x:
        accounts.link_provider(other, "google", "sub1")
    assert (x.value.code, x.value.status) == ("identity_taken", 409)
    with pytest.raises(accounts.AccountError) as x:
        accounts.link_provider("niemand", "google", "sub9")
    assert x.value.status == 404
    ids = accounts.identities(uid)
    assert len(ids) == 1 and set(ids[0]) == {"provider", "email", "created_at"} and ids[0]["email"] == "relay@privaterelay.appleid.com"
    assert accounts.identities(other) == []
    # unlink: mit Passwort immer; ohne Passwort nicht den letzten Weg
    assert accounts.unlink_provider(uid, "apple") is False
    assert accounts.unlink_provider(uid, "google") is True and accounts.identities(uid) == []
    accounts.link_provider(uid, "google", "sub1")
    with accounts.cursor() as c:
        c.execute("UPDATE users SET pw_hash=NULL WHERE id=?", (uid,))
    with pytest.raises(accounts.AccountError) as x:
        accounts.unlink_provider(uid, "google")
    assert (x.value.code, x.value.status) == ("last_login_method", 409)
    accounts.link_provider(uid, "apple", "sub-a")
    assert accounts.unlink_provider(uid, "google") is True and [i["provider"] for i in accounts.identities(uid)] == ["apple"]
    with pytest.raises(accounts.AccountError):
        accounts.unlink_provider("niemand", "apple")
    # link_identity: ungueltiges Token 401, fremdes Subject 409
    accounts.identity_verifiers["google"] = lambda tok, nonce=None: {"subject": "sub-" + tok, "email": f"{tok}@gmail.com", "email_verified": True}
    assert accounts.link_identity(other, "google", "o")["linked"] is True
    with pytest.raises(accounts.AccountError) as x:
        accounts.link_identity(uid, "google", "o")
    assert x.value.code == "identity_taken"
    accounts.identity_verifiers["google"] = lambda tok, nonce=None: (_ for _ in ()).throw(ValueError("kaputt"))
    with pytest.raises(accounts.AccountError) as x:
        accounts.link_identity(uid, "google", "o")
    assert x.value.status == 401


# 60 login_with_provider (B02-07, B02-08)
def test_60_B02_07_api_never_reaches_login_with_provider_without_a_verified_subject(hosted, monkeypatch):
    from app import accounts

    def never(*a, **k):
        raise AssertionError("login_with_provider ohne Pruefung aufgerufen")
    monkeypatch.setattr(accounts, "login_with_provider", never)
    body = json.dumps({"id_token": "x", "university": "luh", "email": "wer@beispiel.de"})
    assert _j(asgi_call(hosted, "POST", "/api/account/login/google", body=body))[0] == 501
    assert _j(asgi_call(hosted, "POST", "/api/account/login/facebook", body=body))[0] in (401, 404), "kein freier Pfad der Middleware, kein Anbieter"
    accounts.identity_verifiers["google"] = lambda tok, nonce=None: (_ for _ in ()).throw(ValueError("Signatur falsch"))
    st, d = _j(asgi_call(hosted, "POST", "/api/account/login/google", body=body))
    assert st == 401 and d["code"] == "identity_invalid"
    assert _count("SELECT COUNT(*) FROM users") == 0
    # direkt: leeres Subject wird nie angenommen
    monkeypatch.undo()
    with pytest.raises(accounts.AccountError) as x:
        accounts.login_with_provider("google", "", "x@y.de", True, "luh")
    assert x.value.status == 401
    with pytest.raises(accounts.AccountError) as x:
        accounts.login_with_provider("facebook", "s", "x@y.de", True, "luh")
    assert x.value.status == 404


def test_60_B02_08_provider_signup_leaves_no_account_when_the_trial_cannot_be_granted(hosted, monkeypatch):
    from app import accounts, billing

    def boom(*a, **k):
        raise sqlite3.OperationalError("database is locked")
    monkeypatch.setattr(billing, "start_trial", boom)
    with pytest.raises(sqlite3.OperationalError):
        accounts.login_with_provider("google", "sub-neu", "neu@beispiel.de", True, "luh")
    assert _count("SELECT COUNT(*) FROM users") == 0 and _count("SELECT COUNT(*) FROM identities") == 0 and _count("SELECT COUNT(*) FROM sessions") == 0
    monkeypatch.undo()
    u, tok, created = accounts.login_with_provider("google", "sub-neu", "neu@beispiel.de", True, "luh")
    assert created and u["email_verified"] is True and accounts.authenticate(tok)["id"] == u["id"]
    assert _count("SELECT COUNT(*) FROM entitlements WHERE user_id=? AND source='trial'", u["id"]) == 1


def test_60_login_with_provider_mapping_rules_and_double_tap(hosted):
    from app import accounts
    # 1. bekannte Verknuepfung
    u, tok, created = accounts.login_with_provider("apple", "sub-a", None, False, "luh", fallback_email="relay@beispiel.de")
    assert created and u["email"] == "relay@beispiel.de" and u["email_verified"] is False
    u2, _, created2 = accounts.login_with_provider("apple", "sub-a")
    assert not created2 and u2["id"] == u["id"], "ohne Hochschule und Adresse: bekannte Kennung reicht"
    # 2. bestaetigte Anbieter-Adresse -> bestehendes Konto nur, wenn dieses seine Adresse bestaetigt hat
    uid = _user("vorhanden@beispiel.de")
    with pytest.raises(accounts.AccountError) as x:
        accounts.login_with_provider("google", "sub-g", "vorhanden@beispiel.de", True, "luh")
    assert (x.value.code, x.value.status) == ("email_taken", 409)
    accounts.mark_email_verified(uid)
    u3, _, created3 = accounts.login_with_provider("google", "sub-g", "Vorhanden@Beispiel.de", True)
    assert not created3 and u3["id"] == uid and [i["provider"] for i in accounts.identities(uid)] == ["google"]
    # unbestaetigte Anbieter-Adresse eines bestehenden Kontos: kein Zugriff, 409
    with pytest.raises(accounts.AccountError) as x:
        accounts.login_with_provider("google", "sub-h", "vorhanden@beispiel.de", False, "luh")
    assert x.value.code == "email_taken"
    # 3. neues Konto braucht Adresse und Hochschule
    with pytest.raises(accounts.AccountError) as x:
        accounts.login_with_provider("google", "sub-i", None, False, "luh")
    assert x.value.code == "email_required"
    with pytest.raises(accounts.AccountError) as x:
        accounts.login_with_provider("google", "sub-i", "i@beispiel.de", True, None)
    assert x.value.code == "university_unknown"
    # Doppeltipp: zwei gleichzeitige erste Anmeldungen derselben Kennung -> ein Konto, beide angemeldet
    out = _threads(4, lambda i: accounts.login_with_provider("google", "sub-doppelt", "doppelt@beispiel.de", True, "luh"))
    assert not any(isinstance(o, Exception) for o in out), out
    assert sum(1 for o in out if o[2]) == 1 and len({o[0]["id"] for o in out}) == 1
    assert _count("SELECT COUNT(*) FROM users WHERE email='doppelt@beispiel.de'") == 1 and _count("SELECT COUNT(*) FROM identities WHERE subject='sub-doppelt'") == 1
    assert all(accounts.authenticate(o[1]) for o in out)

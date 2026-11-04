"""Kontingente und Berechtigungen (app/billing.py mit der Tarif-Tabelle app/plans.py), auf einer eigenen Temp-Datenbank."""
import sqlite3
import threading
from datetime import datetime, timedelta, timezone

import pytest

from app import billing, plans

NOW = datetime(2026, 10, 25, 12, 0, tzinfo=timezone.utc)


@pytest.fixture
def db_path(tmp_path):
    p = tmp_path / "billing.db"
    with sqlite3.connect(p) as c:
        c.execute("PRAGMA journal_mode=WAL")
        billing.ensure_schema(c)
    return p


def connect(p):
    return sqlite3.connect(p, isolation_level=None, timeout=10)


def test_free_plan_has_no_ai_tests_and_no_editing(db_path):
    c = connect(db_path)
    assert billing.current_plan(c, "u1", NOW) == "free"
    assert billing.allowed(c, "u1", "can_view_pdf", NOW) and not billing.allowed(c, "u1", "can_annotate_pdf", NOW)
    r = billing.consume(c, "u1", "ai_tests_new", "r1", NOW)
    assert not r.ok and r.used == 0 and r.limit == 0


def test_parallel_requests_cannot_exceed_quota(db_path):
    setup = connect(db_path)
    billing.set_entitlement(setup, "u7", "app_store", "plus", original_transaction_id="t-7",
                            expires_at=(NOW + timedelta(days=20)).isoformat(), now=NOW)
    results = []
    lock = threading.Lock()

    def worker(i):
        c = connect(db_path)
        r = billing.consume(c, "u7", "ai_tests_new", f"req-{i}", NOW)
        with lock:
            results.append(r.ok)
        c.close()
    threads = [threading.Thread(target=worker, args=(i,)) for i in range(20)]
    [t.start() for t in threads]
    [t.join(30) for t in threads]
    n = plans.QUOTAS["plus"]["ai_tests_new"]                      # 4 seit der Tabelle vom 04.11.2026
    assert results.count(True) == n, f"Plus erlaubt genau {n} neue KI-Tests, {results.count(True)} wurden vergeben"


def test_retry_with_same_request_id_counts_once(db_path):
    c = connect(db_path)
    billing.set_entitlement(c, "u2", "manual", "pro_ai", now=NOW)
    a = billing.consume(c, "u2", "ai_tests_new", "same", NOW)
    b = billing.consume(c, "u2", "ai_tests_new", "same", NOW)
    assert a.ok and b.ok and b.duplicate and b.used == 1


def test_refund_returns_quota(db_path):
    c = connect(db_path)
    billing.set_entitlement(c, "u3", "manual", "plus", now=NOW)
    for i in range(plans.QUOTAS["plus"]["ai_tests_new"]):
        assert billing.consume(c, "u3", "ai_tests_new", f"x{i}", NOW).ok
    assert not billing.consume(c, "u3", "ai_tests_new", "x9", NOW).ok
    assert billing.refund(c, "u3", "ai_tests_new", "x1")
    assert billing.consume(c, "u3", "ai_tests_new", "x10", NOW).ok


def test_quota_resets_each_month(db_path):
    c = connect(db_path)
    billing.set_entitlement(c, "u4", "manual", "plus", now=NOW)
    for i in range(plans.QUOTAS["plus"]["ai_tests_new"]):
        assert billing.consume(c, "u4", "ai_tests_new", f"m{i}", NOW).ok
    assert not billing.consume(c, "u4", "ai_tests_new", "m9", NOW).ok
    assert billing.consume(c, "u4", "ai_tests_new", "m10", NOW + timedelta(days=10)).ok, "November: neues Kontingent"


def test_expired_subscription_downgrades_without_data_loss(db_path):
    c = connect(db_path)
    billing.set_entitlement(c, "u5", "app_store", "pro_ai", original_transaction_id="t-5",
                            expires_at=(NOW - timedelta(minutes=1)).isoformat(), now=NOW)
    assert billing.current_plan(c, "u5", NOW) == "free"
    assert billing.allowed(c, "u5", "can_view_pdf", NOW), "Lesen bleibt nach Ablauf erlaubt"
    rows = c.execute("SELECT COUNT(*) FROM entitlements WHERE user_id='u5'").fetchone()[0]
    assert rows == 1, "Berechtigungsdaten bleiben fuer Wiederherstellung erhalten"


def test_legacy_plan_names_and_manual_plan():
    assert billing.normalize_plan("pro") == "pro_ai" and billing.normalize_plan("gold") is None
    c = sqlite3.connect(":memory:", isolation_level=None)
    billing.ensure_schema(c)
    assert billing.current_plan(c, "u", NOW, legacy={"plan": "plus", "plan_until": "2026-10-25"}) == "plus", "bis einschliesslich"
    assert billing.current_plan(c, "u", NOW, legacy={"plan": "plus", "plan_until": "2026-10-24"}) == "free"


def test_request_id_is_scoped_to_user_period_and_feature(db_path):
    c = connect(db_path)
    for u in ("ua", "ub"):
        billing.set_entitlement(c, u, "manual", "pro_ai", now=NOW)
    assert billing.consume(c, "ua", "ai_assist", "gleich", NOW).ok
    b = billing.consume(c, "ub", "ai_assist", "gleich", NOW)
    assert b.ok and not b.duplicate and b.used == 1, "dieselbe ID bei einem anderen Konto ist eine neue Anfrage"
    f = billing.consume(c, "ua", "ai_tests_new", "gleich", NOW)
    assert f.ok and not f.duplicate, "dieselbe ID bei einer anderen Funktion ist eine neue Anfrage"
    n = billing.consume(c, "ua", "ai_assist", "gleich", NOW + timedelta(days=10))
    assert n.ok and not n.duplicate and n.used == 1, "im neuen Monat zählt die ID wieder"
    assert billing.consume(c, "ua", "ai_assist", "gleich", NOW + timedelta(days=10)).duplicate


def test_foreign_request_id_does_not_bypass_exhausted_quota(db_path):
    c = connect(db_path)
    billing.set_entitlement(c, "ua", "manual", "plus", now=NOW)
    billing.set_entitlement(c, "ub", "manual", "plus", now=NOW)
    for i in range(plans.QUOTAS["plus"]["ai_tests_new"]):
        assert billing.consume(c, "ua", "ai_tests_new", f"k{i}", NOW).ok
        assert billing.consume(c, "ub", "ai_tests_new", f"b{i}", NOW).ok
    r = billing.consume(c, "ub", "ai_tests_new", "k1", NOW)       # fremde ID, eigenes Kontingent leer
    assert not r.ok and not r.duplicate


def test_refund_touches_only_the_callers_own_row(db_path):
    c = connect(db_path)
    billing.set_entitlement(c, "ua", "manual", "pro_ai", now=NOW)
    billing.set_entitlement(c, "ub", "manual", "pro_ai", now=NOW)
    assert billing.consume(c, "ua", "ai_assist", "a1", NOW).ok
    assert not billing.refund(c, "ub", "ai_assist", "a1"), "fremde ID: nichts zurückgenommen"
    assert not billing.refund(c, "ua", "ai_tests_new", "a1"), "andere Funktion: nichts zurückgenommen"
    assert billing.used(c, "ua", "ai_assist", NOW) == 1
    assert c.execute("SELECT COUNT(*) FROM usage_requests WHERE request_id='a1'").fetchone()[0] == 1
    assert billing.refund(c, "ua", "ai_assist", "a1")
    assert billing.used(c, "ua", "ai_assist", NOW) == 0


def test_old_usage_requests_table_is_migrated_keeping_rows(tmp_path):
    p = tmp_path / "alt.db"
    c = sqlite3.connect(p, isolation_level=None)
    c.executescript("""
        CREATE TABLE usage (user_id TEXT NOT NULL, period TEXT NOT NULL, feature TEXT NOT NULL,
                            count INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (user_id, period, feature));
        CREATE TABLE usage_requests (request_id TEXT PRIMARY KEY, user_id TEXT NOT NULL, period TEXT NOT NULL,
                                     feature TEXT NOT NULL, created_at TEXT NOT NULL);
        INSERT INTO usage VALUES ('ua', '2026-10', 'ai_assist', 1);
        INSERT INTO usage_requests VALUES ('alt-1', 'ua', '2026-10', 'ai_assist', '2026-10-25T12:00:00+00:00');
    """)
    billing.ensure_schema(c)
    billing.ensure_schema(c)                                      # zweimal: ohne Wirkung
    pk = {r[1]: r[5] for r in c.execute("PRAGMA table_info(usage_requests)")}
    assert pk["request_id"] > 0 and pk["user_id"] > 0 and pk["period"] > 0 and pk["feature"] > 0
    assert c.execute("SELECT user_id, period, feature FROM usage_requests WHERE request_id='alt-1'").fetchone() == ("ua", "2026-10", "ai_assist")
    assert c.execute("SELECT name FROM sqlite_master WHERE name='idx_usage_requests_user'").fetchone()
    billing.set_entitlement(c, "ua", "manual", "pro_ai", now=NOW)
    assert billing.consume(c, "ua", "ai_assist", "alt-1", NOW).duplicate, "vorhandene Zeile gilt weiter als gezählt"

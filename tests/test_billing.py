"""Kontingente und Berechtigungen (app/billing.py mit der Tarif-Tabelle app/plans.py), auf einer eigenen Temp-Datenbank."""
import sqlite3
import threading
from datetime import datetime, timedelta, timezone

import pytest

from app import billing

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
    assert results.count(True) == 3, f"Plus erlaubt genau 3 neue KI-Tests, {results.count(True)} wurden vergeben"


def test_retry_with_same_request_id_counts_once(db_path):
    c = connect(db_path)
    billing.set_entitlement(c, "u2", "manual", "pro_ai", now=NOW)
    a = billing.consume(c, "u2", "ai_tests_new", "same", NOW)
    b = billing.consume(c, "u2", "ai_tests_new", "same", NOW)
    assert a.ok and b.ok and b.duplicate and b.used == 1


def test_refund_returns_quota(db_path):
    c = connect(db_path)
    billing.set_entitlement(c, "u3", "manual", "plus", now=NOW)
    for i in range(3):
        assert billing.consume(c, "u3", "ai_tests_new", f"x{i}", NOW).ok
    assert not billing.consume(c, "u3", "ai_tests_new", "x9", NOW).ok
    assert billing.refund(c, "x1")
    assert billing.consume(c, "u3", "ai_tests_new", "x10", NOW).ok


def test_quota_resets_each_month(db_path):
    c = connect(db_path)
    billing.set_entitlement(c, "u4", "manual", "plus", now=NOW)
    for i in range(3):
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

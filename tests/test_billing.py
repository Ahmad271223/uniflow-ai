"""Kontingente und Berechtigungen (app/billing.py), auf einer eigenen Temp-Datenbank."""
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


def test_free_plan_has_one_test_and_no_editing(db_path):
    c = connect(db_path)
    assert billing.current_plan(c, 1, NOW) == "free"
    assert billing.allowed(c, 1, "read", NOW) and not billing.allowed(c, 1, "annotate", NOW)
    assert billing.consume(c, 1, "ai_tests", "r1", NOW).ok
    r = billing.consume(c, 1, "ai_tests", "r2", NOW)
    assert not r.ok and r.used == 1 and r.limit == 1


def test_parallel_requests_cannot_exceed_quota(db_path):
    setup = connect(db_path)
    billing.set_entitlement(setup, 7, "app_store", "plus", original_transaction_id="t-7",
                            expires_at=(NOW + timedelta(days=20)).isoformat(), now=NOW)
    results = []
    lock = threading.Lock()

    def worker(i):
        c = connect(db_path)
        r = billing.consume(c, 7, "ai_tests", f"req-{i}", NOW)
        with lock:
            results.append(r.ok)
        c.close()
    threads = [threading.Thread(target=worker, args=(i,)) for i in range(20)]
    [t.start() for t in threads]
    [t.join(30) for t in threads]
    assert results.count(True) == 6, f"Plus erlaubt genau 6 Tests, {results.count(True)} wurden vergeben"


def test_retry_with_same_request_id_counts_once(db_path):
    c = connect(db_path)
    billing.set_entitlement(c, 2, "manual", "pro", now=NOW)
    a = billing.consume(c, 2, "ai_tests", "same", NOW)
    b = billing.consume(c, 2, "ai_tests", "same", NOW)
    assert a.ok and b.ok and b.duplicate and b.used == 1


def test_refund_returns_quota(db_path):
    c = connect(db_path)
    assert billing.consume(c, 3, "ai_tests", "x1", NOW).ok
    assert billing.refund(c, "x1")
    assert billing.consume(c, 3, "ai_tests", "x2", NOW).ok


def test_quota_resets_each_month(db_path):
    c = connect(db_path)
    assert billing.consume(c, 4, "ai_tests", "m1", NOW).ok
    assert not billing.consume(c, 4, "ai_tests", "m2", NOW).ok
    assert billing.consume(c, 4, "ai_tests", "m3", NOW + timedelta(days=10)).ok, "November: neues Kontingent"


def test_expired_subscription_downgrades_without_data_loss(db_path):
    c = connect(db_path)
    billing.set_entitlement(c, 5, "app_store", "pro", original_transaction_id="t-5",
                            expires_at=(NOW - timedelta(minutes=1)).isoformat(), now=NOW)
    assert billing.current_plan(c, 5, NOW) == "free"
    assert billing.allowed(c, 5, "read", NOW), "Lesen bleibt nach Ablauf erlaubt"
    rows = c.execute("SELECT COUNT(*) FROM entitlements WHERE user_id=5").fetchone()[0]
    assert rows == 1, "Berechtigungsdaten bleiben fuer Wiederherstellung erhalten"

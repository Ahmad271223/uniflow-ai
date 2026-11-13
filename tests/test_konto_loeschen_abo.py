"""Konto löschen beendet ein Karten-Abo (Stripe) mit (Entscheidung des Inhabers vom 13.11.2026): beim Löschen fragt der
Dienst Stripe nach allen Abos des Kunden und beendet jedes laufende sofort (app/stripe_billing.cancel_for_deleted_account,
aufgerufen aus accounts._after_delete). Scheitert Stripe, bleibt das Konto trotzdem gelöscht und purge_deleted versucht
es täglich erneut. Ein Apple-Abo kann nur der Nutzer selbst kündigen. Stripe ist eine Attrappe (kein Netz, kein Geld)."""
import json

import pytest
from conftest import asgi_call
from test_trial_stripe import register, stripe, subscription  # noqa: F401  (Fixture stripe)
from test_subscriptions import hosted  # noqa: F401  (Fixture hosted)

PW = "sehr-geheim-123"


@pytest.fixture
def deletes(stripe, monkeypatch):
    """DELETE-Aufrufe an Stripe mitschreiben (die Attrappe aus test_trial_stripe kennt nur POST und GET)."""
    out = []

    def delete(path):
        stripe.calls.append(("DELETE", path, None, None))
        if stripe.__dict__.get("fail_delete"):
            from app.stripe_billing import StripeError
            raise StripeError("stripe_unreachable", "Stripe ist nicht erreichbar.", 502)
        out.append(path)
        return {"id": path.rsplit("/", 1)[-1], "status": "canceled"}
    monkeypatch.setattr(stripe.module, "http_delete", delete)
    stripe.deleted = out
    return stripe


def _customer(uid, cid="cus_1"):
    from app import billing
    conn = billing.connect()
    try:
        conn.execute("INSERT OR IGNORE INTO stripe_customers(user_id, customer_id, created_at) VALUES (?,?,?)", (uid, cid, "2026-11-01T00:00:00+00:00"))
    finally:
        conn.close()


def _delete(app, h, password=PW):
    st, _, b = asgi_call(app, "POST", "/api/account/delete", body=json.dumps({"password": password}), headers=h)
    return st, json.loads(b)


LIST = "/subscriptions?customer=cus_1&status=all&limit=100"


def test_deleting_the_account_ends_running_card_subscriptions_now(hosted, deletes):
    u, h = register(hosted, "abo@example.org")
    _customer(u["id"])
    deletes.answers[LIST] = {"data": [subscription("sub_laeuft"), subscription("sub_alt", status="canceled"),
                                      subscription("sub_offen", status="past_due")]}
    st, d = _delete(hosted, h)
    assert st == 200 and d["deleted"], d
    assert deletes.deleted == ["/subscriptions/sub_laeuft", "/subscriptions/sub_offen"], "nur laufende, beendete nicht erneut"


def test_without_a_stripe_customer_stripe_is_not_called(hosted, deletes):
    u, h = register(hosted, "ohne@example.org")
    st, d = _delete(hosted, h)
    assert st == 200 and d["deleted"]
    assert deletes.calls == [], "kein Aufruf an Stripe ohne Kunden"


def test_wrong_password_ends_nothing(hosted, deletes):
    u, h = register(hosted, "falsch@example.org")
    _customer(u["id"])
    deletes.answers[LIST] = {"data": [subscription("sub_laeuft")]}
    st, d = _delete(hosted, h, password="nicht-richtig-1")
    assert st == 401
    assert deletes.calls == []


def test_stripe_down_account_is_still_deleted_and_the_daily_run_catches_up(hosted, deletes):
    from app import accounts
    u, h = register(hosted, "spaeter@example.org")
    _customer(u["id"])
    deletes.answers[LIST] = {"data": [subscription("sub_laeuft")]}
    deletes.fail_delete = True
    st, d = _delete(hosted, h)
    assert st == 200 and d["deleted"], "das Recht auf Löschen haengt nicht an Stripe"
    assert deletes.deleted == []
    deletes.fail_delete = False
    accounts.purge_deleted()                                  # taeglicher Lauf: holt das Beenden nach
    assert deletes.deleted == ["/subscriptions/sub_laeuft"]
    deletes.answers[LIST] = {"data": [subscription("sub_laeuft", status="canceled")]}
    accounts.purge_deleted()                                  # danach nichts mehr doppelt
    assert deletes.deleted == ["/subscriptions/sub_laeuft"]


def test_stripe_not_configured_does_not_block_deleting(hosted, deletes, monkeypatch):
    monkeypatch.delenv("LERNAPP_STRIPE_SECRET_KEY")
    from app import stripe_billing as sb
    monkeypatch.setattr(sb, "http_get", lambda path: sb._request("GET", path))     # echter Weg: ohne Schluessel ein Fehler
    u, h = register(hosted, "ohnekey@example.org")
    _customer(u["id"])
    st, d = _delete(hosted, h)
    assert st == 200 and d["deleted"]

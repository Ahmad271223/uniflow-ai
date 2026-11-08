"""Audit-Paket 36 (08.11.2026): App-Store-Kaeufe im Dienst – Erstattung/Widerruf, Upgrade/Downgrade, verspaetete und
doppelte Meldungen, Kontobindung ueber appAccountToken (docs/audit/AUDIT-2026-11-08-PAKET-36.md). Signierte
Test-Transaktionen wie in tests/test_subscriptions.py (eigene Kette mit Apple-OIDs)."""
import datetime as dt
import uuid

from test_subscriptions import IN_30, UTC, apple, ent, hosted, notify, user, verify  # noqa: F401 (Fixtures)

PLUS, PRO = "de.uniflow.plus.monthly", "de.uniflow.proai.monthly"


def raw_tx(signer, user_id, product, expires, otid, token=True, **extra):
    """Transaktion wie AppleSigner.tx, mit beliebigen weiteren Feldern (isUpgraded, revocationDate ...)."""
    signer.seq += 1
    ms = lambda d: int(d.timestamp() * 1000)
    p = {"transactionId": f"{otid}-{signer.seq}", "originalTransactionId": otid, "productId": product, "bundleId": "de.uniflow.ai",
         "type": "Auto-Renewable Subscription", "expiresDate": ms(expires), "environment": "Sandbox",
         "signedDate": ms(dt.datetime.now(UTC)) + signer.seq}
    if token:
        p["appAccountToken"] = str(uuid.UUID(hex=user_id))
    p.update(extra)
    return signer.sign(p)


def test_p36_refund_is_not_undone_by_old_transaction_with_fresh_renewal(hosted, apple):
    """P36-R1: Nach REFUND darf eine alte (vor der Erstattung signierte) Transaktion das Recht nicht zurueckholen, auch
    nicht mit einer frisch signierten Verlaengerungsinfo dazu (vorher zaehlte deren signedDate als Alter der Meldung)."""
    u, h = user(hosted, "p36-refund@beispiel.de")
    otid = "3600000000000001"
    old = apple.tx(u["id"], PRO, IN_30, otid=otid)
    assert verify(hosted, h, old)[1]["plan"] == "pro_ai"
    st, d = notify(hosted, apple.notification("REFUND", apple.tx(u["id"], PRO, IN_30, otid=otid, revoked=True)))
    assert st == 200 and d["status"] == "revoked" and ent(hosted, h)["plan"] == "free"
    st, d = verify(hosted, h, old, renewal=apple.renewal(otid, PRO))
    assert ent(hosted, h)["plan"] == "free", (st, d)
    assert ent(hosted, h)["credits"]["allowance"] == 0


def test_p36_renewal_info_of_another_subscription_is_ignored(hosted, apple):
    """P36-R2: Die Verlaengerungsinfo muss zum selben Abo (originalTransactionId) gehoeren, sonst zaehlt sie nicht."""
    u, h = user(hosted, "p36-renewal@beispiel.de")
    st, d = verify(hosted, h, apple.tx(u["id"], PRO, IN_30, otid="3600000000000002"),
                   renewal=apple.renewal("3600000000000999", PLUS, auto_renew=False))
    assert st == 200 and d["plan"] == "pro_ai", d
    assert d["pending_plan"] is None and d["will_renew"] is True, d


def test_p36_upgraded_transaction_never_downgrades(hosted, apple):
    """P36-R3: Nach Upgrade Plus -> Pro AI meldet StoreKit die alte Plus-Transaktion mit isUpgraded=true (z. B. ueber
    Transaction.updates oder beim Wiederherstellen neu signiert). Sie darf den Tarif im Dienst nicht auf Plus setzen."""
    u, h = user(hosted, "p36-upgrade@beispiel.de")
    otid = "3600000000000003"
    assert verify(hosted, h, raw_tx(apple, u["id"], PLUS, IN_30, otid))[1]["plan"] == "plus"
    assert verify(hosted, h, raw_tx(apple, u["id"], PRO, IN_30, otid))[1]["plan"] == "pro_ai"
    st, d = verify(hosted, h, raw_tx(apple, u["id"], PLUS, IN_30, otid, isUpgraded=True))
    assert st == 200, d
    e = ent(hosted, h)
    assert e["plan"] == "pro_ai" and e["credits"]["allowance"] == 100, e["plan"]
    # nur die ersetzte Transaktion, noch nichts gemeldet (z. B. Wiederherstellen in anderer Reihenfolge): kein Fehler
    w, hw = user(hosted, "p36-upgrade-erst@beispiel.de")
    st, d = verify(hosted, hw, raw_tx(apple, w["id"], PLUS, IN_30, "3600000000000013", isUpgraded=True))
    assert st == 200 and d["stale"] and d["plan"] is None, d
    assert ent(hosted, hw)["plan"] == "free"


def test_p36_refund_declined_or_consumption_request_change_nothing(hosted, apple):
    """P36-R4: REFUND_DECLINED und CONSUMPTION_REQUEST tragen die Transaktion, zu der eine Erstattung angefragt wurde
    (auch eine aeltere, abgelaufene Periode). Sie aendern den Abo-Stand nicht."""
    u, h = user(hosted, "p36-declined@beispiel.de")
    otid = "3600000000000004"
    assert verify(hosted, h, apple.tx(u["id"], PLUS, IN_30, otid=otid))[1]["plan"] == "plus"
    past = dt.datetime.now(UTC) - dt.timedelta(days=3)
    for ntype in ("CONSUMPTION_REQUEST", "REFUND_DECLINED"):
        st, d = notify(hosted, apple.notification(ntype, apple.tx(u["id"], PLUS, past, otid=otid)))
        assert st == 200 and not d["applied"], (ntype, d)
        assert ent(hosted, h)["plan"] == "plus", ntype


# ---------------------------------------------------------------- festgenagelt (schon richtig bzw. nach Fix)

def test_p36_family_revoke_and_refund_reversed(hosted, apple):
    """REVOKE (Familienfreigabe entzogen) entzieht das Recht, auch ohne revocationDate in der Transaktion;
    REFUND_REVERSED (Erstattung zurueckgenommen) stellt es wieder her."""
    u, h = user(hosted, "p36-revoke@beispiel.de")
    otid = "3600000000000005"
    assert notify(hosted, apple.notification("SUBSCRIBED", apple.tx(u["id"], PLUS, IN_30, otid=otid)))[1]["plan"] == "plus"
    st, d = notify(hosted, apple.notification("REVOKE", apple.tx(u["id"], PLUS, IN_30, otid=otid, revoked=True)))
    assert d["status"] == "revoked" and ent(hosted, h)["plan"] == "free"
    st, d = notify(hosted, apple.notification("REFUND_REVERSED", apple.tx(u["id"], PLUS, IN_30, otid=otid)))
    assert d["status"] == "active" and ent(hosted, h)["plan"] == "plus"
    st, d = notify(hosted, apple.notification("REVOKE", apple.tx(u["id"], PLUS, IN_30, otid=otid)))
    assert d["status"] == "revoked" and ent(hosted, h)["plan"] == "free"


def test_p36_late_notifications_do_not_override_newer_state(hosted, apple):
    """Apple liefert nicht immer in Reihenfolge: eine aeltere DID_RENEW nach EXPIRED aendert nichts, eine doppelte
    Meldung zaehlt einmal."""
    u, h = user(hosted, "p36-late@beispiel.de")
    otid = "3600000000000006"
    renew = apple.notification("DID_RENEW", apple.tx(u["id"], PLUS, IN_30, otid=otid))
    past = dt.datetime.now(UTC) - dt.timedelta(minutes=1)
    expired = apple.notification("EXPIRED", apple.tx(u["id"], PLUS, past, otid=otid), subtype="VOLUNTARY")
    assert notify(hosted, expired)[1]["status"] == "expired"
    st, d = notify(hosted, renew)
    assert st == 200 and not d["applied"] and d["stale"] and ent(hosted, h)["plan"] == "free"
    assert notify(hosted, expired)[1]["duplicate"]


def test_p36_purchase_stays_with_its_account_on_account_switch(hosted, apple):
    """Kontowechsel auf demselben iPad (gleiche Apple-ID): Konto B meldet den Kauf von A (Token A) -> 409, B bleibt
    Free, A behaelt das Abo. Ein Kauf ohne Token gehoert dem Konto, das ihn zuerst meldet; danach nie einem zweiten,
    auch nicht ueber spaetere Server-Benachrichtigungen."""
    a, ha = user(hosted, "p36-a@beispiel.de")
    b, hb = user(hosted, "p36-b@beispiel.de")
    assert verify(hosted, ha, apple.tx(a["id"], PRO, IN_30, otid="3600000000000007"))[1]["plan"] == "pro_ai"
    st, d = verify(hosted, hb, apple.tx(a["id"], PRO, IN_30, otid="3600000000000007"))
    assert (st, d["code"]) == (409, "subscription_owned_by_other_account")
    assert ent(hosted, hb)["plan"] == "free" and ent(hosted, ha)["plan"] == "pro_ai"
    # ohne Token: B meldet zuerst
    assert verify(hosted, hb, apple.tx(b["id"], PLUS, IN_30, otid="3600000000000008", token=False))[1]["plan"] == "plus"
    st, d = verify(hosted, ha, apple.tx(a["id"], PLUS, IN_30, otid="3600000000000008", token=False))
    assert (st, d["code"]) == (409, "subscription_owned_by_other_account")
    st, d = notify(hosted, apple.notification("DID_RENEW", apple.tx(a["id"], PLUS, IN_30, otid="3600000000000008", token=False)))
    assert st == 200 and ent(hosted, hb)["plan"] == "plus" and ent(hosted, ha)["plan"] == "pro_ai"


def test_p36_notification_for_unknown_account_is_retried_not_recorded(hosted, apple):
    """Kauf ohne Token, den noch kein Konto gemeldet hat: 404, die notificationUUID wird nicht gemerkt, damit Apples
    Wiederholung spaeter (nach der Meldung aus der App) greift."""
    u, h = user(hosted, "p36-unknown@beispiel.de")
    note = apple.notification("SUBSCRIBED", apple.tx(u["id"], PLUS, IN_30, otid="3600000000000009", token=False))
    st, d = notify(hosted, note)
    assert (st, d["code"]) == (404, "unknown_account")
    assert verify(hosted, h, apple.tx(u["id"], PLUS, IN_30, otid="3600000000000009", token=False))[1]["plan"] == "plus"
    st, d = notify(hosted, note)
    assert st == 200 and not d.get("duplicate")

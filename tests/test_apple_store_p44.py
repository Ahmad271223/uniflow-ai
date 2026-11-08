"""Audit-Paket 44 (08.11.2026): Kulanzfrist (Billing Grace Period) im Dienst (docs/audit/AUDIT-2026-11-08-PAKET-44.md).
Waehrend der Frist zaehlt Apple das Abo weiter; die App meldet beim Start alle `currentEntitlements` neu – darunter die
Transaktion des abgelaufenen Zeitraums (`expiresDate` vorbei, ohne Verlaengerungsinfo). Diese Meldung darf den
Frist-Stand aus DID_FAIL_TO_RENEW/GRACE_PERIOD nicht auf `expired` setzen. Signierte Test-Transaktionen wie in
tests/test_subscriptions.py."""
import datetime as dt

from test_apple_store_p36 import PRO, raw_tx
from test_subscriptions import UTC, apple, ent, hosted, notify, user, verify  # noqa: F401 (Fixtures)


def _ms(d):
    return int(d.timestamp() * 1000)


def _grace_renewal(signer, otid, until):
    signer.seq += 1
    return signer.sign({"originalTransactionId": otid, "autoRenewProductId": PRO, "autoRenewStatus": 1,
                        "isInBillingRetryPeriod": True, "gracePeriodExpiresDate": _ms(until),
                        "signedDate": _ms(dt.datetime.now(UTC)) + signer.seq})


def test_p44_app_report_during_grace_period_keeps_the_plan(hosted, apple):
    u, h = user(hosted, "p44-grace@beispiel.de")
    otid = "4400000000000001"
    now = dt.datetime.now(UTC)
    ended = now - dt.timedelta(hours=1)
    until = now + dt.timedelta(days=16)
    assert verify(hosted, h, raw_tx(apple, u["id"], PRO, now + dt.timedelta(days=1), otid))[1]["plan"] == "pro_ai"
    st, d = notify(hosted, apple.notification("DID_FAIL_TO_RENEW", raw_tx(apple, u["id"], PRO, ended, otid),
                                              renewal=_grace_renewal(apple, otid, until), subtype="GRACE_PERIOD"))
    assert st == 200 and d["status"] == "grace", d
    assert ent(hosted, h)["plan"] == "pro_ai"
    # App startet neu und meldet currentEntitlements: Transaktion des abgelaufenen Zeitraums, spaeter signiert
    st, d = verify(hosted, h, raw_tx(apple, u["id"], PRO, ended, otid))
    assert st == 200, d
    e = ent(hosted, h)
    assert e["plan"] == "pro_ai", (d, e["plan"])
    assert e["credits"]["allowance"] == 100
    # dieselbe Meldung mit Verlaengerungsinfo der Frist (falls die App sie einmal mitschickt): ebenfalls Frist
    st, d = verify(hosted, h, raw_tx(apple, u["id"], PRO, ended, otid), renewal=_grace_renewal(apple, otid, until))
    assert st == 200 and d["status"] == "grace" and ent(hosted, h)["plan"] == "pro_ai", d
    # Ende der Frist ohne Zahlung: Free
    st, d = notify(hosted, apple.notification("GRACE_PERIOD_EXPIRED", raw_tx(apple, u["id"], PRO, ended, otid)))
    assert st == 200 and d["status"] == "expired", d
    assert ent(hosted, h)["plan"] == "free"
    # danach aendert eine erneute Meldung der App nichts (bleibt abgelaufen)
    verify(hosted, h, raw_tx(apple, u["id"], PRO, ended, otid))
    assert ent(hosted, h)["plan"] == "free"


def test_p44_expired_report_without_grace_still_expires(hosted, apple):
    """Festgenagelt: ohne Frist setzt die Meldung eines abgelaufenen Zeitraums das Abo wie bisher auf abgelaufen."""
    u, h = user(hosted, "p44-expired@beispiel.de")
    otid = "4400000000000002"
    now = dt.datetime.now(UTC)
    assert verify(hosted, h, raw_tx(apple, u["id"], PRO, now + dt.timedelta(days=1), otid))[1]["plan"] == "pro_ai"
    st, d = verify(hosted, h, raw_tx(apple, u["id"], PRO, now - dt.timedelta(hours=1), otid))
    assert st == 200 and d["status"] == "expired", d
    assert ent(hosted, h)["plan"] == "free"

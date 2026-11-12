"""Eine Apple-ID = ein StudiNow-Konto = ein Abo (Entscheidung des Inhabers 12.11.2026, „eine Anmeldung für alles“):
die App meldet mit der Apple-Anmeldung vom ersten Start auch beim Dienst an. Belegt wird: dieselbe Apple-Kennung
(`sub`) auf einem zweiten iPad fuehrt ohne Hochschule in dasselbe Konto (gleicher Tarif, Probe nicht erneut); eine
neue Kennung ohne Hochschule bekommt 400 `university_unknown` (die App versucht es nach der Hochschulwahl erneut);
ein Abo gehoert dem Konto, das es meldet, ein zweites Konto (andere Apple-ID) uebernimmt es nie; der Notizen-Abgleich
bleibt an Pro AI gebunden. Apple-Pruefung ist ersetzt (accounts.identity_verifiers), Kaeufe signiert eine eigene
Test-Kette (tests/test_subscriptions.py); nichts geht ins Netz."""
import json

import pytest
from conftest import asgi_call
from test_subscriptions import IN_30, _j, apple, ent, hosted, verify  # noqa: F401 (Fixtures)

PRO = "de.uniflow.proai.monthly"


@pytest.fixture
def apple_login(hosted, monkeypatch):  # noqa: F811
    """Apple-Pruefer: das „Token“ ist die Kennung selbst (wie identity_verifiers in den Fixtures)."""
    from app import accounts
    for k in ("LERNAPP_APPLE_CLIENT_IDS", "LERNAPP_APPLE_WEB_CLIENT_ID"):
        monkeypatch.delenv(k, raising=False)
    monkeypatch.setitem(accounts.identity_verifiers, "apple",
                        lambda token, nonce=None: {"subject": token, "email": f"{token}@privaterelay.appleid.com", "email_verified": True})

    def login(sub, device, university=None):
        body = {"identity_token": sub, "device_id": device, "device_name": device}
        if university:
            body["university"] = university
        st, d = _j(asgi_call(hosted, "POST", "/api/account/login/apple", body=json.dumps(body)))
        return st, d, ({"Authorization": f"Bearer {d['token']}"} if st in (200, 201) else None)
    return login


def _trial_rows(user_id):
    from app import billing
    conn = billing.connect()
    try:
        return conn.execute("SELECT COUNT(*) FROM entitlements WHERE user_id=? AND source='trial'", (user_id,)).fetchone()[0]
    finally:
        conn.close()


def test_same_apple_id_on_second_ipad_is_the_same_account_without_new_trial(apple_login, hosted):  # noqa: F811
    # erstes iPad: neue Kennung ohne Hochschule -> 400 (vor der Hochschulwahl), danach mit Hochschule -> neues Konto
    st, d, _ = apple_login("apple-sub-A", "ipad-1")
    assert (st, d["code"]) == (400, "university_unknown")
    st, a, ha = apple_login("apple-sub-A", "ipad-1", university="luh")
    assert st == 201 and a["created"] is True
    first = ent(hosted, ha)
    assert _trial_rows(a["user"]["id"]) == 1
    # zweites iPad, dieselbe Apple-ID: sofort angemeldet, ohne Hochschule, dasselbe Konto, keine zweite Probe
    st, b, hb = apple_login("apple-sub-A", "ipad-2")
    assert st == 200 and b["created"] is False and b["user"]["id"] == a["user"]["id"]
    assert b["user"]["university"] == "luh"
    second = ent(hosted, hb)
    assert second["plan"] == first["plan"]
    assert _trial_rows(a["user"]["id"]) == 1, "Probe nur bei der Neuanlage"
    st, me = _j(asgi_call(hosted, "GET", "/api/account/me", headers=hb))
    assert sorted(s["device_id"] for s in me["sessions"]) == ["ipad-1", "ipad-2"]
    # andere Apple-ID: eigenes Konto
    st, c, _ = apple_login("apple-sub-B", "ipad-3", university="luh")
    assert st == 201 and c["user"]["id"] != a["user"]["id"]


def test_one_subscription_belongs_to_one_account_on_all_its_devices(apple_login, hosted, apple):  # noqa: F811
    from app import accounts
    st, a, ha = apple_login("apple-sub-A", "ipad-1", university="luh")
    accounts.end_trial(a["user"]["id"])
    # Kauf auf iPad 1 (appAccountToken = Konto A): gilt beim Dienst fuer das Konto, also auf jedem Geraet mit A
    assert verify(hosted, ha, apple.tx(a["user"]["id"], PRO, IN_30, otid="5100000000000001"))[1]["plan"] == "pro_ai"
    st, _, hb = apple_login("apple-sub-A", "ipad-2")
    assert ent(hosted, hb)["plan"] == "pro_ai"
    # iPad 2 meldet denselben Kauf beim Wiederherstellen erneut: kein Fehler, dasselbe Konto
    st, d = verify(hosted, hb, apple.tx(a["user"]["id"], PRO, IN_30, otid="5100000000000001"))
    assert st == 200 and d["plan"] == "pro_ai", d
    # ein zweites Konto (andere Apple-ID beim Dienst) kann dasselbe Abo nicht uebernehmen, auch ohne appAccountToken
    st, c, hc = apple_login("apple-sub-B", "ipad-3", university="luh")
    accounts.end_trial(c["user"]["id"])
    st, d = verify(hosted, hc, apple.tx(a["user"]["id"], PRO, IN_30, otid="5100000000000001"))
    assert (st, d["code"]) == (409, "subscription_owned_by_other_account")
    st, d = verify(hosted, hc, apple.tx(a["user"]["id"], PRO, IN_30, otid="5100000000000001", token=False))
    assert (st, d["code"]) == (409, "subscription_owned_by_other_account")
    assert ent(hosted, hc)["plan"] == "free" and ent(hosted, ha)["plan"] == "pro_ai"


def test_note_sync_between_devices_stays_pro_ai_only(apple_login, hosted):  # noqa: F811
    from app import accounts, plans
    assert plans.ENTITLEMENTS["can_sync_annotations"]["from"] == "pro_ai"
    st, a, ha = apple_login("apple-sub-N", "ipad-1", university="luh")
    accounts.end_trial(a["user"]["id"])
    note = {"entity": "annotations", "id": "f1", "data": {"version": 2, "pages": {}}}
    for plan, refused in (("free", True), ("plus", True), ("pro_ai", False)):
        accounts.set_plan(a["user"]["id"], plan)
        st, out = _j(asgi_call(hosted, "POST", "/api/sync/push", headers=ha,
                               body=json.dumps({"device_id": "ipad-1", "items": [note]})))
        assert st == 200, out
        statuses = [r["status"] for r in out["results"] if r.get("entity") == "annotations"]
        assert ("plan_required" in statuses) is refused, (plan, statuses)

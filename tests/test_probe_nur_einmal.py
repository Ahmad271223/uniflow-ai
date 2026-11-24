"""Probe nur einmal je Person und Geraet, auch nach "Konto loeschen" (Auftrag des Inhabers 24.11.2026,
app/trial_claims.py). Vorher: Konto loeschen + neu anmelden = neues Konto = neue 7 Tage; ebenso eine zweite Apple-ID
auf demselben Geraet (die App uebernimmt eine laufende Probe des Dienstes mit Vorrang vor ihrer Geraete-Marke).
Belegt wird ueber die echten Endpunkte: Apple-Anmeldung, Registrierung mit E-Mail, Loeschen, Tarifauskunft."""
import json
from datetime import datetime, timedelta, timezone

import pytest
from conftest import asgi_call
from test_one_apple_id import apple_login  # noqa: F401 (Fixture)
from test_subscriptions import _j, ent, hosted  # noqa: F401 (Fixtures)

PW = "ein-langes-passwort-42"


def _trial(user_id):
    from app import billing
    conn = billing.connect()
    try:
        return billing.trial_info(conn, user_id)
    finally:
        conn.close()


def _days_pass(days):
    """Zeit vergehen lassen, ohne die Uhr zu stellen: jedes Probe-Ende (Konten und gemerkte Kennungen) rueckt um
    `days` Tage naeher bzw. in die Vergangenheit."""
    from app import billing
    now = datetime.now(timezone.utc)
    conn = billing.connect()
    try:
        for uid, ends in conn.execute("SELECT user_id, expires_at FROM entitlements WHERE source='trial'").fetchall():
            new = datetime.fromisoformat(ends) - timedelta(days=days)
            conn.execute("UPDATE entitlements SET expires_at=?, status=? WHERE user_id=? AND source='trial'",
                         (new.isoformat(), "active" if new > now else "expired", uid))
        for key, ends in conn.execute("SELECT key, trial_ends_at FROM trial_claims WHERE kind<>'meta'").fetchall():
            conn.execute("UPDATE trial_claims SET trial_ends_at=? WHERE key=?",
                         ((datetime.fromisoformat(ends) - timedelta(days=days)).isoformat(), key))
    finally:
        conn.close()


def _delete(app, headers, password=None):
    st, d = _j(asgi_call(app, "POST", "/api/account/delete", headers=headers,
                         body=json.dumps({"password": password} if password else {})))
    assert st == 200 and d["deleted"] is True, d


def _claims():
    from app import accounts
    with accounts.cursor() as conn:
        return {r["kind"]: r["n"] for r in conn.execute("SELECT kind, COUNT(*) AS n FROM trial_claims WHERE kind<>'meta' GROUP BY kind")}


def test_delete_and_sign_in_again_keeps_the_old_trial_end(apple_login, hosted):  # noqa: F811
    st, a, ha = apple_login("apple-sub-A", "ipad-1", university="luh")
    assert st == 201 and ent(hosted, ha)["plan"] == "pro_ai"
    first = _trial(a["user"]["id"])
    assert first["active"] and first["days_left"] == 7
    # Tag 3 der Probe: Konto loeschen, mit derselben Apple-ID neu anmelden -> neues Konto, aber dieselbe Probe
    _days_pass(2)
    ends = datetime.fromisoformat(_trial(a["user"]["id"])["ends_at"])
    _delete(hosted, ha)
    st, b, hb = apple_login("apple-sub-A", "ipad-1", university="luh")
    assert st == 201 and b["created"] is True and b["user"]["id"] != a["user"]["id"]
    again = _trial(b["user"]["id"])
    assert again["active"] and again["days_left"] == 5, "Rest der alten Probe, keine neuen 7 Tage"
    assert again["ends_at"] == ends.replace(microsecond=0).isoformat()
    assert ent(hosted, hb)["plan"] == "pro_ai"


def test_delete_after_the_trial_and_sign_in_again_starts_without_trial(apple_login, hosted):  # noqa: F811
    st, a, ha = apple_login("apple-sub-A", "ipad-1", university="luh")
    _days_pass(8)
    assert ent(hosted, ha)["plan"] == "free"
    _delete(hosted, ha)
    # auch von einem ANDEREN Geraet: die Apple-Kennung allein genuegt
    st, b, hb = apple_login("apple-sub-A", "ipad-2", university="luh")
    assert st == 201 and b["created"] is True
    t = _trial(b["user"]["id"])
    assert t["granted"] and t["expired"] and not t["active"] and t["days_left"] == 0
    e = ent(hosted, hb)
    assert e["plan"] == "free" and e["trial"]["expired"] is True


def test_same_device_with_another_apple_id_gets_no_second_trial(apple_login, hosted):  # noqa: F811
    st, a, ha = apple_login("apple-sub-A", "ipad-1", university="luh")
    _days_pass(8)
    # zweite Apple-ID auf demselben iPad, das erste Konto besteht weiter (kein Loeschen noetig fuer den Trick)
    st, b, hb = apple_login("apple-sub-B", "ipad-1", university="luh")
    assert st == 201 and b["created"] is True
    assert _trial(b["user"]["id"])["expired"] and ent(hosted, hb)["plan"] == "free"
    # ... und auch nach dem Loeschen beider Konten bleibt das Geraet bekannt
    _delete(hosted, ha)
    _delete(hosted, hb)
    st, c, hc = apple_login("apple-sub-C", "ipad-1", university="luh")
    assert st == 201 and ent(hosted, hc)["plan"] == "free"
    # ein anderes, neues Geraet mit neuer Apple-ID bekommt seine Probe wie bisher
    st, d, hd = apple_login("apple-sub-D", "ipad-9", university="luh")
    assert st == 201 and _trial(d["user"]["id"])["days_left"] == 7 and ent(hosted, hd)["plan"] == "pro_ai"


def test_second_device_of_an_account_with_trial_is_marked_too(apple_login, hosted):  # noqa: F811
    st, a, _ = apple_login("apple-sub-A", "ipad-1", university="luh")
    _days_pass(3)
    apple_login("apple-sub-A", "iphone-1")                        # dieselbe Person meldet am 4. Tag ihr iPhone an
    # andere Apple-ID auf diesem iPhone, noch in der Probe: Rest der ersten Probe, keine neuen 7 Tage
    st, b, hb = apple_login("apple-sub-B", "iphone-1", university="luh")
    assert st == 201 and _trial(b["user"]["id"])["ends_at"] == _trial(a["user"]["id"])["ends_at"]
    assert _trial(b["user"]["id"])["days_left"] == 4 and ent(hosted, hb)["plan"] == "pro_ai"
    _days_pass(5)
    st, c, hc = apple_login("apple-sub-C", "iphone-1", university="luh")
    assert st == 201 and _trial(c["user"]["id"])["expired"] and ent(hosted, hc)["plan"] == "free"


def test_email_account_delete_and_register_again(hosted):  # noqa: F811
    def register(email, device=None):
        body = {"email": email, "password": PW, "university": "luh"}
        if device:
            body.update(device_id=device, device_name=device)
        st, d = _j(asgi_call(hosted, "POST", "/api/account/register", body=json.dumps(body)))
        assert st == 201, d
        return d["user"]["id"], {"Authorization": f"Bearer {d['token']}"}

    uid, h = register("probe@beispiel.de")
    assert _trial(uid)["days_left"] == 7
    _days_pass(9)
    _delete(hosted, h, PW)
    uid2, h2 = register("probe@beispiel.de")
    assert uid2 != uid and _trial(uid2)["expired"] and ent(hosted, h2)["plan"] == "free"
    # eine andere Adresse im Browser (ohne Geraete-Kennung) ist ein neuer Mensch: Probe wie bisher
    uid3, _ = register("andere@beispiel.de")
    assert _trial(uid3)["days_left"] == 7


def test_used_trial_credits_follow_into_the_new_account(apple_login, hosted):  # noqa: F811
    from app import billing, credits
    st, a, ha = apple_login("apple-sub-A", "ipad-1", university="luh")
    uid = a["user"]["id"]
    conn = billing.connect()
    try:
        credits.ensure_schema(conn)
        assert credits.balance(conn, uid)["allowance"] == 25
        conn.execute("UPDATE credit_months SET used=18 WHERE user_id=?", (uid,))
    finally:
        conn.close()
    _delete(hosted, ha)
    st, b, _ = apple_login("apple-sub-A", "ipad-1", university="luh")
    conn = billing.connect()
    try:
        bal = credits.balance(conn, b["user"]["id"])
    finally:
        conn.close()
    assert (bal["allowance"], bal["used"], bal["remaining"], bal["plan"]) == (25, 18, 7, "pro_ai:trial"), \
        "Loeschen und neu anmelden fuellt die Probe-Credits nicht auf"


def test_operator_extended_trial_survives_delete_with_its_real_end(apple_login, hosted):  # noqa: F811
    from app import billing
    st, a, ha = apple_login("apple-sub-A", "ipad-1", university="luh")
    until = datetime.now(timezone.utc) + timedelta(days=30)
    conn = billing.connect()
    try:
        billing.extend_trial(conn, a["user"]["id"], until)         # TestFlight-Tester (app/tester_freischalten.py)
    finally:
        conn.close()
    _delete(hosted, ha)
    st, b, _ = apple_login("apple-sub-A", "ipad-2", university="luh")
    assert _trial(b["user"]["id"])["ends_at"] == until.replace(microsecond=0).isoformat()


def test_only_hashes_are_stored_and_they_survive_the_final_purge(apple_login, hosted):  # noqa: F811
    from app import accounts
    st, a, ha = apple_login("apple-sub-A", "ipad-1", university="luh")
    uid = a["user"]["id"]
    assert _claims() == {"apple": 1, "email": 1, "device": 1}
    _delete(hosted, ha)
    with accounts.cursor() as conn:
        conn.execute("UPDATE users SET deleted_at=? WHERE id=?", ((datetime.now(timezone.utc) - timedelta(days=31)).isoformat(), uid))
    assert accounts.purge_deleted() == 1
    with accounts.cursor() as conn:
        assert conn.execute("SELECT 1 FROM users WHERE id=?", (uid,)).fetchone() is None
        dump = json.dumps([tuple(r) for r in conn.execute("SELECT * FROM trial_claims").fetchall()])
    assert "apple-sub-A" not in dump and "ipad-1" not in dump and "privaterelay" not in dump and uid not in dump
    assert _claims() == {"apple": 1, "email": 1, "device": 1}, "bleibt ohne Konto stehen"
    st, b, hb = apple_login("apple-sub-A", "ipad-7", university="luh")
    assert st == 201 and _trial(b["user"]["id"])["days_left"] <= 7
    assert _trial(b["user"]["id"])["ends_at"] == _first_end_of("apple", "apple-sub-A")


def _first_end_of(kind, value):
    from app import accounts, trial_claims
    with accounts.cursor() as conn:
        return conn.execute("SELECT trial_ends_at FROM trial_claims WHERE key=?", (trial_claims.claim_key(kind, value),)).fetchone()[0]


def test_old_marks_are_removed_after_three_years(apple_login, hosted):  # noqa: F811
    from app import accounts, trial_claims
    apple_login("apple-sub-A", "ipad-1", university="luh")
    with accounts.cursor() as conn:
        assert trial_claims.purge_old(conn) == 0
        late = datetime.now(timezone.utc) + timedelta(days=trial_claims.KEEP_DAYS + 1)
        assert trial_claims.purge_old(conn, now=late) == 3
        assert conn.execute("SELECT COUNT(*) FROM trial_claims WHERE kind='meta'").fetchone()[0] == 1, "Marke des Nachtrags bleibt"


def test_backfill_marks_devices_of_accounts_from_before_the_rule(apple_login, hosted):  # noqa: F811
    from app import accounts, trial_claims
    st, a, _ = apple_login("apple-sub-A", "ipad-1", university="luh")
    apple_login("apple-sub-A", "iphone-1")
    _days_pass(10)
    with accounts.cursor() as conn:                                # Stand wie vor dem Deploy: keine Eintraege
        conn.execute("DELETE FROM trial_claims")
    # der Nachtrag laeuft von selbst mit der Schema-Arbeit (accounts._migrate); hier ausdruecklich, falls die Datei
    # in diesem Prozess schon eingerichtet ist
    with accounts.cursor() as conn:
        trial_claims.backfill(conn)
    with accounts.cursor() as conn:
        assert trial_claims.backfill(conn) == 0, "nur einmal"
    assert _claims() == {"device": 2}
    st, b, hb = apple_login("apple-sub-B", "iphone-1", university="luh")
    assert st == 201 and _trial(b["user"]["id"])["expired"] and ent(hosted, hb)["plan"] == "free"


@pytest.mark.parametrize("device", [None, "", "   "])
def test_without_a_device_id_only_the_identity_counts(apple_login, hosted, device):  # noqa: F811
    from app import trial_claims
    assert trial_claims.keys_for(None, [], [device]) == []
    assert trial_claims.keys_for("deleted-abc@invalid", [("apple", "")], []) == []

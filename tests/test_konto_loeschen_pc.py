"""Konto löschen in der Windows-App (13.11.2026, app/account_mode.delete_account, POST /api/app-account/delete), wie
"Konto löschen" auf dem iPad: der PC leitet an den Dienst weiter (dort sofort gesperrt, nach 30 Tagen endgueltig) und
meldet sich danach ab; die Daten auf dem PC bleiben. Falsches Passwort ergibt 403 (nicht 401: das hiesse in der
Oberflaeche "abgemeldet"). Dienst und PC laufen im selben Prozess wie in tests/test_account_mode.py; kein Netz."""
from test_account_mode import PW, _end_trial, _hosted, _local, _login, _register, svc  # noqa: F401  (Fixture svc)


def _status(uid):
    from app import accounts
    with accounts.cursor() as conn:
        return conn.execute("SELECT status FROM users WHERE id=?", (uid,)).fetchone()["status"]


def test_delete_from_the_pc_deletes_at_the_service_and_signs_out(svc):
    from app import db
    u, _ = _register(svc.app, "weg@example.org")
    _login(svc.app, "weg@example.org")
    assert _local(svc.app, "GET", "/api/app-account/status")[1]["signed_in"]
    local_db = db.DB_PATH
    st, d = _local(svc.app, "POST", "/api/app-account/delete", {"password": PW})
    assert st == 200, d
    assert d == {"deleted": True, "purge_after_days": 30, "local_data_kept": True}
    assert _status(u["id"]) == "deleted", "beim Dienst gesperrt"
    assert ("POST", "/api/account/delete") in [(m, p) for m, p, _ in svc.calls]
    s = _local(svc.app, "GET", "/api/app-account/status")[1]
    assert not s["signed_in"] and s["state"] == "signed_out", s
    assert local_db.exists(), "die Daten auf diesem PC bleiben"
    # mit dem alten Zugang geht es nicht mehr
    st, d = _local(svc.app, "POST", "/api/app-account/login", {"email": "weg@example.org", "password": PW})
    assert st >= 400


def test_wrong_password_is_403_and_nothing_happens(svc):
    u, _ = _register(svc.app, "falsch@example.org")
    _login(svc.app, "falsch@example.org")
    for body in ({"password": "nicht-richtig-123"}, {}):
        st, d = _local(svc.app, "POST", "/api/app-account/delete", body)
        assert st == 403 and d["code"] == "credentials_invalid", (st, d)
    assert _status(u["id"]) == "active"
    assert _local(svc.app, "GET", "/api/app-account/status")[1]["signed_in"], "weiter angemeldet"


def test_account_without_password_apple_or_google_deletes_without_one(svc):
    from app import accounts
    u, _ = _register(svc.app, "apple@example.org")
    _login(svc.app, "apple@example.org")
    with accounts.cursor() as conn:                     # wie ein Konto aus "Mit Apple anmelden": kein Passwort
        conn.execute("UPDATE users SET pw_hash=NULL WHERE id=?", (u["id"],))
    st, d = _local(svc.app, "POST", "/api/app-account/delete", {})
    assert st == 200 and d["deleted"], d
    assert _status(u["id"]) == "deleted"


def test_offline_nothing_is_deleted_and_the_pc_stays_signed_in(svc):
    u, _ = _register(svc.app, "offline@example.org")
    _login(svc.app, "offline@example.org")
    svc.offline = True
    st, d = _local(svc.app, "POST", "/api/app-account/delete", {"password": PW})
    svc.offline = False
    assert st >= 500 or st == 503, (st, d)
    assert _status(u["id"]) == "active"
    assert _local(svc.app, "GET", "/api/app-account/status")[1]["signed_in"]


def test_works_also_without_subscription_after_the_trial(svc):
    """Ohne Abo ist die App gesperrt; loeschen muss trotzdem gehen (Apple 5.1.1(v), Recht auf Loeschung)."""
    u, _ = _register(svc.app, "ohneabo@example.org")
    _end_trial(u["id"])
    _login(svc.app, "ohneabo@example.org")
    st, d = _local(svc.app, "POST", "/api/app-account/delete", {"password": PW})
    assert st == 200 and d["deleted"], d


def test_foreign_web_page_cannot_delete(svc):
    from conftest import asgi_call
    u, _ = _register(svc.app, "csrf@example.org")
    _login(svc.app, "csrf@example.org")
    st, _, _ = asgi_call(svc.app, "POST", "/api/app-account/delete", body='{"password": "%s"}' % PW,
                         headers={"Origin": "https://boese.example"})
    assert st == 403
    assert _status(u["id"]) == "active"


def test_not_offered_in_the_hosted_service(svc):
    u, token = _register(svc.app, "dienst@example.org")
    st, d = _hosted(svc.app, "POST", "/api/app-account/delete", {"password": PW}, headers={"Authorization": f"Bearer {token}"})
    assert st == 404, (st, d)
    assert _status(u["id"]) == "active"

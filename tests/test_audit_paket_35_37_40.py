"""Audit 08.11.2026, Pakete 35, 37 und 40 (docs/audit/AUDIT-2026-11-08-PAKET-35-37-40.md): Kontotrennung beim
Geraete-Abgleich (Vertrag G2). Python-Seite: app/sync.py (Dienst) und app/sync_client.py (Windows-App). Erfundene Konten,
Dienst per ASGI (Fixture `two_devices` aus test_sync_client.py), nie ein Netz."""
import json

from conftest import asgi_call
from test_sync_client import _hosted, ipad_pull, ipad_push, two_devices  # noqa: F401 - Fixture


def _second_account(app, email="zweit@example.org"):
    from app import accounts
    st, d = _hosted(app, "POST", "/api/account/register", {"email": email, "password": "sehr-geheim-456", "university": "luh"})
    assert st == 201, d
    accounts.mark_email_verified(d["user"]["id"])
    accounts.end_trial(d["user"]["id"])
    accounts.set_plan(d["user"]["id"], "pro_ai")
    return d["token"], d["user"]


def test_p37_02_switching_the_account_during_a_windows_sync_run_keeps_both_accounts_apart(two_devices, monkeypatch):
    """Windows-App ist mit Konto A verbunden; waehrend eines Laufs meldet sich der Nutzer ab und mit Konto B an. Der Lauf
    bleibt bei A (Token und Adresse vom Start): nichts von diesem PC landet in B, nichts von B auf diesem PC. Vorher las
    jede Anfrage den gerade gespeicherten Stand: der Rest des Laufs ging mit dem Token von B, aber mit der Zuordnung
    (`sync_link_map`) von A – lokale Zeilen gingen an B, Zeilen von B ueberschrieben lokale."""
    from app import db, service_link, sync_client
    app, _ = two_devices
    assert sync_client.run()["ok"]
    b_token, b_user = _second_account(app)
    b = {"Authorization": f"Bearer {b_token}"}
    ipad_push(app, b, [{"entity": "modules", "local_id": -1, "data": {"name": "Nur-bei-B"}}])
    with db.cursor() as c:
        c.execute("INSERT INTO modules(name) VALUES ('Windows-von-A')")

    real = service_link.transport
    switched = []

    def transport(method, url, headers, body, timeout):
        r = real(method, url, headers, body, timeout)
        if not switched:                                    # nach der ersten Anfrage: abmelden, mit B anmelden
            switched.append(url)
            s = service_link.load_state()
            s["token"], s["user"] = b_token, {"id": b_user["id"], "email": b_user["email"]}
            s.pop("sync_last", None)
            service_link.save_state(s)
        return r
    monkeypatch.setattr(service_link, "transport", transport)
    out = sync_client.run()
    assert switched
    changes, _ = ipad_pull(app, b)
    assert "Windows-von-A" not in [m["name"] for m in changes.get("modules", [])], out
    with db.cursor() as c:
        names = [r[0] for r in c.execute("SELECT name FROM modules")]
    assert "Nur-bei-B" not in names, out
    # der neue Stand (B) bleibt angemeldet und bekommt kein Ergebnis des Laufs von A
    st = service_link.load_state()
    assert st.get("token") == b_token
    assert "sync_last" not in st, st.get("sync_last")


def test_p37_sync_endpoints_need_the_account_in_hosted_mode(app, monkeypatch):
    """G2 im Dienst: ohne Token weder abrufen noch senden; mit dem Token von B weder Zeilen von A lesen noch aendern."""
    from app import accounts, config
    monkeypatch.setattr(config, "MODE", "hosted")
    accounts.db_path().unlink(missing_ok=True)
    try:
        toks = []
        for mail in ("p37a@beispiel.de", "p37b@beispiel.de"):
            st, _, b = asgi_call(app, "POST", "/api/account/register", body=json.dumps({"email": mail, "password": "sehr-geheim-123", "university": "luh"}))
            toks.append(json.loads(b)["token"])
        h = lambda t: {"Authorization": f"Bearer {t}"}  # noqa: E731
        body = json.dumps({"device_id": "ipad-a", "items": [{"entity": "modules", "local_id": -1, "data": {"name": "Nur-A-37"}}]})
        assert asgi_call(app, "POST", "/api/sync/push", body=body)[0] == 401
        st, _, b = asgi_call(app, "POST", "/api/sync/push", headers=h(toks[0]), body=body)
        a_id = json.loads(b)["mapping"][0]["id"]
        # B versucht, die Zeile von A (gleiche ID im eigenen Konto) zu aendern und zu loeschen: trifft nur eigene Daten
        upd = json.dumps({"device_id": "ipad-b", "items": [{"entity": "modules", "id": a_id, "base_version": 1, "data": {"name": "von-B"}}],
                          "deletes": [{"entity": "modules", "id": a_id}]})
        asgi_call(app, "POST", "/api/sync/push", headers=h(toks[1]), body=upd)
        st, _, b = asgi_call(app, "GET", "/api/sync/changes", headers=h(toks[0]))
        mods = json.loads(b)["changes"]["modules"]
        assert [m["name"] for m in mods if m["id"] == a_id] == ["Nur-A-37"]
        assert "von-B" not in b.decode()
    finally:
        accounts.db_path().unlink(missing_ok=True)

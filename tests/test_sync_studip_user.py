"""Datentrennung im Geraete-Abgleich (12.11.2026): die App schickt den Hash ihrer Stud.IP-Benutzerkennung mit
(`GET /api/sync/changes?studip_user=…`, `POST /api/sync/push` Feld `studip_user`). Der erste Wert wird je Konto und
Hochschule gemerkt; ein anderer bekommt 409 `studip_user_mismatch`, bevor etwas gelesen oder geschrieben wird. Ohne
Wert (Windows-App) bleibt alles wie bisher. Kein Netz."""
import hashlib
import json

import pytest
from conftest import asgi_call

A = hashlib.sha256(b"studip:ada").hexdigest()
B = hashlib.sha256(b"studip:bob").hexdigest()


@pytest.fixture
def hosted(app, monkeypatch):
    from app import accounts, config
    monkeypatch.setattr(config, "MODE", "hosted")
    monkeypatch.setenv("LERNAPP_JOBS", "off")
    for suffix in ("", "-wal", "-shm"):
        accounts.db_path().with_name(accounts.db_path().name + suffix).unlink(missing_ok=True)
    st, _, b = asgi_call(app, "POST", "/api/account/register",
                         body=json.dumps({"email": "trennung@beispiel.de", "password": "sehr-geheim-123", "university": "luh"}))
    assert st == 201
    yield app, {"Authorization": f"Bearer {json.loads(b)['token']}"}
    accounts.db_path().unlink(missing_ok=True)


def _push(app, h, name, studip_user=None, **extra):
    body = {"device_id": "ipad-x", "items": [{"entity": "modules", "local_id": -1, "data": {"name": name}}], **extra}
    if studip_user is not None:
        body["studip_user"] = studip_user
    st, _, b = asgi_call(app, "POST", "/api/sync/push", headers=h, body=json.dumps(body))
    return st, json.loads(b)


def _changes(app, h, studip_user=None):
    q = f"?studip_user={studip_user}" if studip_user is not None else ""
    st, _, b = asgi_call(app, "GET", "/api/sync/changes" + q, headers=h)
    return st, json.loads(b)


def _modules(app, h):
    return [m["name"] for m in _changes(app, h)[1]["changes"].get("modules", [])]


def test_first_studip_user_is_kept_and_another_is_refused_before_anything_happens(hosted):
    app, h = hosted
    st, out = _push(app, h, "Von-Ada", A)
    assert st == 200 and out["results"][0]["status"] == "created"
    assert _changes(app, h, A)[0] == 200
    # zweites Geraet mit anderem Stud.IP-Benutzer: weder abrufen noch senden
    st, d = _changes(app, h, B)
    assert (st, d["code"]) == (409, "studip_user_mismatch") and "anderen Stud.IP-Benutzers" in d["detail"]
    st, d = _push(app, h, "Von-Bob", B)
    assert (st, d["code"]) == (409, "studip_user_mismatch")
    assert "Von-Bob" not in _modules(app, h), "nichts geschrieben"
    # ohne Angabe (Windows-App, aeltere App): wie bisher
    assert _push(app, h, "Ohne-Angabe")[0] == 200
    assert {"Von-Ada", "Ohne-Angabe"} <= set(_modules(app, h))


def test_owner_hash_is_private_and_cannot_be_changed_by_devices(hosted):
    app, h = hosted
    assert _changes(app, h, A)[0] == 200                        # erster Abruf merkt A
    st, d = _changes(app, h)
    assert all(s["key"] != "studip_user_hash" for s in d["changes"].get("settings", [])), "nie an Geraete ausgeliefert"
    # per Push ueberschreiben oder loeschen geht nicht
    st, out = _j_push(app, h, {"items": [{"entity": "settings", "local_id": "studip_user_hash", "data": {"value": B}}],
                                "deletes": [{"entity": "settings", "id": "studip_user_hash"}]})
    assert st == 200 and [r["status"] for r in out["results"]] == ["ignored", "ignored"]
    # und nicht ueber PUT /api/settings
    asgi_call(app, "PUT", "/api/settings", headers=h, body=json.dumps({"studip_user_hash": B}))
    assert _changes(app, h, B)[0] == 409 and _changes(app, h, A)[0] == 200


def test_invalid_value_is_rejected(hosted):
    app, h = hosted
    st, d = _changes(app, h, "nicht-hex")
    assert (st, d["code"]) == (400, "studip_user_invalid")
    assert _changes(app, h, A)[0] == 200, "kaputter Wert hat nichts gemerkt"


def _j_push(app, h, body):
    st, _, b = asgi_call(app, "POST", "/api/sync/push", headers=h, body=json.dumps({"device_id": "ipad-x", **body}))
    return st, json.loads(b)

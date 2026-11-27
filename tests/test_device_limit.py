"""Geraete-Regel (Auftrag des Inhabers vom 14.11.2026, app/device_limit.py).

Free: ein Konto gilt fuer EIN Geraet, das zweite Apple-Geraet bekommt `blocked`. Plus: laeuft ueberall, das zweite
Geraet bekommt `hint_plus`. Pro AI und die laufende Probe: keine Einschraenkung. Web und Windows zaehlen nicht. Die
Regel greift nur fuer Clients mit `X-StudiNow-Caps: device_limit`; aeltere Apps (1.0.3, Builds 36-40) merken nichts.
Fixture `hosted` und Helfer aus tests/test_subscriptions.py; kein Netz."""
import io
import json
import zipfile
from pathlib import Path

import pytest
from conftest import asgi_call
from test_api_schemas import check, schema_v2
from test_subscriptions import _j, end_trial, hosted, user  # noqa: F401

CAPS = {"X-StudiNow-Caps": "device_limit"}
PW = "sehr-geheim-123"
KINDS = ("free", "plus", "pro_ai", "trial")
# Zustand des ZWEITEN Geraets je Tarif (das erste ist immer ok). 26.11.2026 neues Modell: Plus hat den Abgleich
# (can_sync_annotations ab Plus) und laeuft wie Pro AI ohne Hinweis; der Hinweis fuer Free nennt Plus (1,99 EUR im Monat)
SECOND = {"free": "blocked", "plus": "ok", "pro_ai": "ok", "trial": "ok"}
PRICE = {"upgrade_plan": "plus", "price_cents": 199, "currency": "EUR", "period": "month"}


def account(app, kind, email):
    """Konto fuer einen Tarif der Matrix, angelegt wie von einem Client ohne Geraete-Angaben (Web)."""
    if kind != "trial":
        return user(app, email, plan=kind)[0]
    st, d = _j(asgi_call(app, "POST", "/api/account/register", body=json.dumps({"email": email, "password": PW, "university": "luh"})))
    assert st == 201, d
    return d["user"]


def login(app, email, device_id=None, name=None, caps=True, extra=None):
    """Anmelden wie die Apple-App: Geraete-Kennung im Rumpf, Faehigkeit in der Kopfzeile. Liefert (Antwort, Kopfzeilen)."""
    body = {"email": email, "password": PW}
    if device_id:
        body |= {"device_id": device_id, "device_name": name or device_id}
    headers = {**(CAPS if caps else {}), **(extra or {})}
    st, d = _j(asgi_call(app, "POST", "/api/account/login", body=json.dumps(body), headers=headers))
    assert st == 200, d
    return d, {"Authorization": f"Bearer {d['token']}", **headers}


def ent(app, headers):
    st, d = _j(asgi_call(app, "GET", "/api/entitlements", headers=headers))
    assert st == 200, d
    return d


def me(app, headers):
    st, d = _j(asgi_call(app, "GET", "/api/account/me", headers=headers))
    assert st == 200, d
    return d


def use_this(app, headers):
    return _j(asgi_call(app, "POST", "/api/account/device/primary", headers=headers))


# ---------------------------------------------------------------- reine Regel

@pytest.mark.parametrize("plan, device, primary, state", [
    # 26.11.2026 neues Modell: Plus hat den Abgleich, das zweite Geraet ist ok (frueher hint_plus)
    ("free", "a", "a", "ok"), ("free", "b", "a", "blocked"), ("plus", "a", "a", "ok"), ("plus", "b", "a", "ok"),
    ("pro_ai", "b", "a", "ok"), ("pro_connect", "b", "a", "ok"),
    ("free", None, "a", "ok"), ("free", "b", None, "ok"), ("gibtsnicht", "b", "a", "blocked"), (None, "b", "a", "blocked")])
def test_rule(plan, device, primary, state):
    from app import device_limit
    assert device_limit.evaluate(plan, device, primary) == state


def test_upgrade_plan_follows_the_sync_right():
    """Der Hinweis nennt den Tarif, der den Abgleich zwischen Geraeten hat. 26.11.2026 neues Modell: Plus (1,99 EUR im
    Monat) statt Pro AI (39,99 EUR im Jahr)."""
    from app import device_limit, plans
    assert device_limit.upgrade_plan() == "plus" == plans.ENTITLEMENTS["can_sync_annotations"]["from"]
    assert (plans.PLANS["plus"]["price_cents"], plans.PLANS["plus"]["period"]) == (199, "month")
    assert plans.has("plus", "can_sync_annotations"), "Plus hat seit 26.11.2026 den Abgleich"


# ---------------------------------------------------------------- Matrix: Tarif x erstes/zweites Geraet

@pytest.mark.parametrize("kind", KINDS)
def test_matrix_first_and_second_device(hosted, kind):
    email = f"{kind}@beispiel.de"
    account(hosted, kind, email)
    first, h1 = login(hosted, email, "ipad-1", "iPad")
    assert first["device"] == {"state": "ok", "is_primary": True, "primary_name": "iPad",
                               "primary_set_at": first["device"]["primary_set_at"], **PRICE}, "Anmelde-Antwort traegt den Zustand"
    assert first["device"]["primary_set_at"]
    second, h2 = login(hosted, email, "iphone-1", "iPhone")
    assert second["device"]["state"] == SECOND[kind]
    assert second["device"]["is_primary"] is False and second["device"]["primary_name"] == "iPad"
    # dieselbe Auskunft in der Status-Antwort (das, was die App regelmaessig abfragt) und in der Konto-Antwort
    for h, state, primary in ((h1, "ok", True), (h2, SECOND[kind], False)):
        d = ent(hosted, h)["device"]
        assert (d["state"], d["is_primary"], d["primary_name"]) == (state, primary, "iPad")
        assert me(hosted, h)["device"] == d
        assert {k: d[k] for k in PRICE} == PRICE
    assert check(ent(hosted, h2)["device"], schema_v2("me")["properties"]["device"]) == []


def test_third_device_and_mac_count_like_the_second(hosted):
    account(hosted, "free", "drei@beispiel.de")
    login(hosted, "drei@beispiel.de", "ipad-1", "iPad")
    assert login(hosted, "drei@beispiel.de", "mac-1", "Mac")[0]["device"]["state"] == "blocked"
    assert login(hosted, "drei@beispiel.de", "iphone-1", "iPhone")[0]["device"]["state"] == "blocked"
    assert login(hosted, "drei@beispiel.de", "ipad-1", "iPad")[0]["device"]["state"] == "ok", "dasselbe Geraet neu angemeldet"


# ---------------------------------------------------------------- Wechsel: "Dieses Geraet stattdessen nutzen"

def test_switch_makes_this_device_the_one_and_the_other_sees_the_hint(hosted):
    account(hosted, "free", "wechsel@beispiel.de")
    _, h1 = login(hosted, "wechsel@beispiel.de", "ipad-1", "iPad")
    _, h2 = login(hosted, "wechsel@beispiel.de", "iphone-1", "iPhone")
    assert ent(hosted, h2)["device"]["state"] == "blocked"
    st, d = use_this(hosted, h2)
    assert st == 200 and d["device"]["state"] == "ok" and d["device"]["is_primary"] and d["device"]["primary_name"] == "iPhone"
    assert ent(hosted, h2)["device"]["state"] == "ok"
    other = ent(hosted, h1)["device"]
    assert (other["state"], other["is_primary"], other["primary_name"]) == ("blocked", False, "iPhone"), "beim naechsten Kontakt"
    # und zurueck: niemand ist ohne Ausweg ausgesperrt
    assert use_this(hosted, h1)[1]["device"]["state"] == "ok"
    assert ent(hosted, h2)["device"]["state"] == "blocked"
    # auf dem Hauptgeraet selbst aendert der Aufruf nichts
    assert use_this(hosted, h1)[1]["device"]["is_primary"] is True


def test_switch_needs_a_session_with_a_device(hosted):
    account(hosted, "free", "ohne@beispiel.de")
    _, h1 = login(hosted, "ohne@beispiel.de", "ipad-1", "iPad")
    assert _j(asgi_call(hosted, "POST", "/api/account/device/primary"))[0] == 401
    _, nodev = login(hosted, "ohne@beispiel.de")                                 # Faehigkeit, aber Sitzung ohne Geraete-Kennung
    st, d = use_this(hosted, nodev)
    assert st == 400 and d["code"] == "device_unknown"
    assert ent(hosted, h1)["device"]["is_primary"] is True, "das Hauptgeraet bleibt"


def test_switch_refuses_web_and_windows_even_when_locked(hosted):
    """Die Route liegt unter /api/account/ und geht damit durch die Abo-Sperre von Web und Windows
    (access.LOCKED_WRITE_PREFIXES, tests/test_audit_paket_21_22.py und _25_27.py). Darum prueft sie selbst: nur
    Apple-Apps mit der Faehigkeit. Die Windows-App meldet eine Geraete-Kennung an - ohne die Pruefung machte sie sich
    zum Hauptgeraet und sperrte das iPad eines Free-Kontos aus."""
    from app import access, account_api, device_limit
    u = account(hosted, "free", "sperre@beispiel.de")
    _, ipad = login(hosted, "sperre@beispiel.de", "ipad-1", "iPad")
    assert access.for_user(u, "windows")["locked"] and access.for_user(u, "web")["locked"], "Free an Web/Windows: Abo-Sperre"
    assert access.write_allowed_when_locked("POST", "/api/account/device/primary"), "die Sperre laesst die Route durch"
    refused = {"status": 400, "code": "device_rule_not_applicable"}

    def result(resp):
        st, d = resp
        return {"status": st, "code": (d or {}).get("code")}

    # Windows-App: Sitzung MIT Geraete-Kennung, mit und ohne die Kopfzeile der Faehigkeit
    _, win = login(hosted, "sperre@beispiel.de", "win-0123456789ab", "StudiNow für Windows", caps=False, extra={"X-StudiNow-Client": "windows"})
    assert result(use_this(hosted, win)) == refused
    assert result(use_this(hosted, {**win, **CAPS})) == refused
    # Browser: nur das Cookie, auch mit der Kopfzeile
    st, hdrs, _ = asgi_call(hosted, "POST", "/api/account/login", body=json.dumps({"email": "sperre@beispiel.de", "password": PW, "device_id": "browser-1"}))
    cookie = next(v.decode().split(";")[0] for k, v in hdrs if k == b"set-cookie")
    assert cookie.startswith(account_api.COOKIE + "=")
    assert result(_j(asgi_call(hosted, "POST", "/api/account/device/primary", cookies=cookie))) == refused
    assert result(_j(asgi_call(hosted, "POST", "/api/account/device/primary", cookies=cookie, headers=CAPS))) == refused
    # aeltere Apple-App ohne die Faehigkeit (kennt die Regel nicht, ruft die Route nie auf)
    _, old = login(hosted, "sperre@beispiel.de", "iphone-alt", "iPhone", caps=False)
    assert result(use_this(hosted, old)) == refused
    # nichts hat sich geaendert: das iPad ist weiter das eine Geraet
    assert device_limit.primary(u["id"])["device_id"] == "ipad-1"
    assert ent(hosted, ipad)["device"] == {**ent(hosted, ipad)["device"], "state": "ok", "is_primary": True, "primary_name": "iPad"}
    # die Apple-App mit der Faehigkeit darf (Free ohne Abo: genau dafuer ist die Route da)
    _, phone = login(hosted, "sperre@beispiel.de", "iphone-1", "iPhone")
    st, d = use_this(hosted, phone)
    assert st == 200 and d["device"]["is_primary"] and device_limit.primary(u["id"])["device_id"] == "iphone-1"
    # und sie schaltet nichts Bezahltes frei
    assert ent(hosted, phone)["plan"] == "free" and not ent(hosted, phone)["entitlements"]["can_sync_annotations"]


# ---------------------------------------------------------------- Kauf hebt die Sperre auf, Ablauf setzt sie

def test_purchase_lifts_the_block_and_expiry_brings_it_back(hosted):
    from app import accounts
    u = account(hosted, "free", "kauf@beispiel.de")
    login(hosted, "kauf@beispiel.de", "ipad-1", "iPad")
    _, h2 = login(hosted, "kauf@beispiel.de", "iphone-1", "iPhone")
    assert ent(hosted, h2)["device"]["state"] == "blocked"
    accounts.set_plan(u["id"], "pro_ai")
    assert ent(hosted, h2)["device"]["state"] == "ok", "nach dem Kauf von Pro AI sofort frei"
    accounts.set_plan(u["id"], "plus")
    # 26.11.2026 neues Modell: Plus hat den Abgleich und laeuft wie Pro AI ohne Hinweis (frueher hint_plus)
    assert ent(hosted, h2)["device"]["state"] == "ok", "Plus wird nie gesperrt"
    accounts.set_plan(u["id"], "free")
    assert ent(hosted, h2)["device"]["state"] == "blocked"


def test_trial_counts_like_its_plan_and_free_after_it_blocks_the_second_device(hosted):
    u = account(hosted, "trial", "probe@beispiel.de")
    _, h1 = login(hosted, "probe@beispiel.de", "ipad-1", "iPad")
    _, h2 = login(hosted, "probe@beispiel.de", "iphone-1", "iPhone")
    # 26.11.2026 neues Modell: die Probe ist Plus (mit Abgleich)
    assert ent(hosted, h2)["plan"] == "plus" and ent(hosted, h2)["device"]["state"] == "ok"
    end_trial(u["id"])
    assert ent(hosted, h2)["plan"] == "free" and ent(hosted, h2)["device"]["state"] == "blocked", "beim naechsten Kontakt"
    assert ent(hosted, h1)["device"]["state"] == "ok"


def test_register_from_the_app_claims_the_device(hosted):
    st, d = _j(asgi_call(hosted, "POST", "/api/account/register", headers=CAPS, body=json.dumps(
        {"email": "neu@beispiel.de", "password": PW, "university": "luh", "device_id": "ipad-1", "device_name": "iPad"})))
    assert st == 201 and d["device"]["state"] == "ok" and d["device"]["is_primary"] is True


def test_apple_login_response_carries_the_state(hosted, monkeypatch):
    from app import accounts
    monkeypatch.setattr(accounts, "identity_verifiers", {"apple": lambda t: {"subject": "sub-1", "email": "a@privaterelay.appleid.com", "email_verified": True}})
    body = {"identity_token": "tok", "university": "luh", "device_id": "ipad-1", "device_name": "iPad"}
    st, d = _j(asgi_call(hosted, "POST", "/api/account/login/apple", headers=CAPS, body=json.dumps(body)))
    assert st == 201 and d["created"] and d["device"]["state"] == "ok" and d["device"]["is_primary"]
    end_trial(d["user"]["id"])
    st, d = _j(asgi_call(hosted, "POST", "/api/account/login/apple", headers=CAPS,
                         body=json.dumps(body | {"device_id": "iphone-1", "device_name": "iPhone"})))
    assert st == 200 and d["device"]["state"] == "blocked" and d["device"]["primary_name"] == "iPad"


# ---------------------------------------------------------------- alte Clients, Web, Windows

def test_old_clients_notice_nothing(hosted):
    """Ohne die Faehigkeit (1.0.3, Builds 36-40): kein Feld `device`, kein Hauptgeraet, auch nicht als zweites Geraet."""
    account(hosted, "free", "alt@beispiel.de")
    old1, h1 = login(hosted, "alt@beispiel.de", "ipad-alt", "iPad", caps=False)
    old2, h2 = login(hosted, "alt@beispiel.de", "iphone-alt", "iPhone", caps=False)
    for d in (old1, old2):
        assert set(d) == {"user", "token"}
    for h in (h1, h2):
        assert "device" not in ent(hosted, h) and set(me(hosted, h)) == {"user", "sessions"}
    from app import device_limit
    assert device_limit.primary(old1["user"]["id"]) is None, "alte Clients werden nie Hauptgeraet"
    # ein neues Geraet daneben: es wird Hauptgeraet; die alten merken weiter nichts
    new, hn = login(hosted, "alt@beispiel.de", "ipad-neu", "iPad")
    assert new["device"]["state"] == "ok" and new["device"]["is_primary"]
    assert "device" not in ent(hosted, h1) and "device" not in ent(hosted, h2)
    # aktualisiert sich das alte Geraet, meldet es die Faehigkeit und sieht dann den Hinweis
    assert ent(hosted, {**h1, **CAPS})["device"]["state"] == "blocked"


def test_web_and_windows_do_not_count(hosted):
    account(hosted, "free", "web@beispiel.de")
    # Browser: nur das Cookie, auch mit der Kopfzeile kein Geraet
    st, hdrs, raw = asgi_call(hosted, "POST", "/api/account/login", body=json.dumps({"email": "web@beispiel.de", "password": PW}))
    cookie = next(v.decode().split(";")[0] for k, v in hdrs if k == b"set-cookie")
    st, d = _j(asgi_call(hosted, "GET", "/api/entitlements", cookies=cookie, headers=CAPS))
    assert st == 200 and "device" not in d
    # Windows-App: Bearer mit X-StudiNow-Client, auch mit Geraete-Kennung und Kopfzeile kein Geraet
    win, hw = login(hosted, "web@beispiel.de", "pc-1", "Windows-PC", extra={"X-StudiNow-Client": "windows"})
    assert "device" not in win and "device" not in ent(hosted, hw) and "device" not in me(hosted, hw)
    from app import device_limit
    assert device_limit.primary(win["user"]["id"]) is None
    # das erste Apple-Geraet danach ist das eine Geraet, nicht das zweite
    assert login(hosted, "web@beispiel.de", "iphone-1", "iPhone")[0]["device"]["state"] == "ok"


def test_session_without_device_id_is_never_blocked(hosted):
    account(hosted, "free", "kennung@beispiel.de")
    login(hosted, "kennung@beispiel.de", "ipad-1", "iPad")
    d, h = login(hosted, "kennung@beispiel.de")                                  # Faehigkeit, aber keine Kennung
    assert d["device"]["state"] == "ok" and d["device"]["is_primary"] is False
    assert ent(hosted, h)["device"]["state"] == "ok"


def test_local_mode_has_no_device_rule(app):
    from app import device_limit

    class R:
        headers = {"x-studinow-caps": "device_limit", "authorization": "Bearer x"}
    assert device_limit.applies(R()) is False, "Einzelplatz: keine Konten, keine Regel"
    st, d = _j(asgi_call(app, "GET", "/api/entitlements", headers=CAPS))
    assert st == 200 and "device" not in d
    assert _j(asgi_call(app, "POST", "/api/account/device/primary", headers=CAPS))[0] == 501


def test_caps_header_is_a_list(hosted):
    from app import device_limit

    class R:
        def __init__(self, **h):
            self.headers = h
    assert device_limit.client_caps(R(**{"x-studinow-caps": " Device_Limit , anderes "})) == {"device_limit", "anderes"}
    assert device_limit.client_caps(R()) == frozenset()
    assert device_limit.applies(R(**{"x-studinow-caps": "anderes", "authorization": "Bearer x"})) is False
    assert device_limit.applies(R(**{"x-studinow-caps": "device_limit"})) is False, "ohne Bearer keine App-Anfrage"
    assert device_limit.applies(R(**{"x-studinow-caps": "device_limit"}), login=True) is True
    assert device_limit.applies(R(**{"x-studinow-caps": "device_limit", "x-studinow-client": "web"}), login=True) is False


# ---------------------------------------------------------------- Konto loeschen, Export

def test_export_names_the_primary_device(hosted):
    account(hosted, "free", "export@beispiel.de")
    _, h1 = login(hosted, "export@beispiel.de", "ipad-1", "iPad")
    st, _, raw = asgi_call(hosted, "GET", "/api/account/export", headers=h1)
    assert st == 200
    konto = json.loads(zipfile.ZipFile(io.BytesIO(raw)).read("konto.json"))
    assert konto["hauptgeraet"]["device_id"] == "ipad-1" and konto["hauptgeraet"]["device_name"] == "iPad" and konto["hauptgeraet"]["set_at"]


def test_delete_account_forgets_the_primary_device(hosted):
    from app import accounts, device_limit
    u = account(hosted, "free", "weg@beispiel.de")
    _, h1 = login(hosted, "weg@beispiel.de", "ipad-1", "iPad")
    assert device_limit.primary(u["id"])["device_id"] == "ipad-1"
    st, d = _j(asgi_call(hosted, "POST", "/api/account/delete", headers=h1, body=json.dumps({"password": PW})))
    assert st == 200 and d["deleted"]
    assert device_limit.primary(u["id"]) is None, "sofort beim Loeschen, nicht erst nach 30 Tagen"
    assert _j(asgi_call(hosted, "POST", "/api/account/device/primary", headers=h1))[0] == 401
    with accounts.cursor() as conn:
        conn.execute("UPDATE users SET deleted_at='2020-01-01T00:00:00Z' WHERE id=?", (u["id"],))
    assert accounts.purge_deleted() == 1
    # dieselbe Adresse neu: ein neues Konto ohne Hauptgeraet, das erste Geraet wird es
    account(hosted, "free", "weg@beispiel.de")
    assert login(hosted, "weg@beispiel.de", "iphone-9", "iPhone")[0]["device"]["state"] == "ok"


# ---------------------------------------------------------------- bestehende Datenbank, Vertrag

def test_existing_database_gets_the_columns(hosted):
    """Server-Update: accounts.db von vorher (ohne die Spalten) bekommt sie beim ersten Zugriff, Konten bleiben."""
    import sqlite3
    from app import accounts, db
    account(hosted, "free", "bestand@beispiel.de")
    p = accounts.db_path()
    conn = sqlite3.connect(p)
    for col in ("primary_device_id", "primary_device_name", "primary_device_set_at"):
        conn.execute(f"ALTER TABLE users DROP COLUMN {col}")
    conn.commit()
    conn.close()
    # `db.schema_once` merkt sich je Prozess und Datei, dass das Schema steht; ein neu gestarteter Dienst weiss das nicht
    for ident in [i for i in db._schema_done if i[0] == "accounts"]:
        db._schema_done.discard(ident)
    d, h = login(hosted, "bestand@beispiel.de", "ipad-1", "iPad")
    assert d["device"]["state"] == "ok" and d["device"]["is_primary"]
    assert login(hosted, "bestand@beispiel.de", "iphone-1", "iPhone")[0]["device"]["state"] == "blocked"


class _StaleTableInfo:
    """Verbindung, deren PRAGMA table_info einen alten Stand liefert: so sieht es aus, wenn ein anderer Prozess die
    Spalte zwischen Pruefen und ALTER angelegt hat (wie tests/test_audit_paket_11_12.py)."""

    def __init__(self, conn, table, missing):
        self._c, self._t, self._m = conn, table, missing

    def execute(self, sql, *a):
        if sql.strip() == f"PRAGMA table_info({self._t})":
            return [r for r in self._c.execute(sql).fetchall() if r[1] not in self._m]
        return self._c.execute(sql, *a)

    def __getattr__(self, n):
        return getattr(self._c, n)


def _cols(conn, table):
    return [r[1] for r in conn.execute(f"PRAGMA table_info({table})")]


def test_migration_survives_a_database_without_users(tmp_path):
    """Alte oder halb angelegte accounts.db (nur identities, noch keine Tabelle users): die Migration bricht nicht mit
    "no such table: users" ab, ist wiederholbar, und sobald es users gibt, kommen die Spalten nach."""
    import sqlite3
    from app import accounts
    conn = sqlite3.connect(tmp_path / "halb.db")
    conn.execute("CREATE TABLE identities (provider TEXT NOT NULL, subject TEXT NOT NULL, user_id TEXT NOT NULL, created_at TEXT NOT NULL)")
    accounts._migrate(conn)
    accounts._migrate(conn)
    assert _cols(conn, "users") == [], "keine Tabelle users angelegt, kein Fehler"
    assert "email" in _cols(conn, "identities"), "die uebrigen Spalten kamen trotzdem"
    conn.executescript(accounts.SCHEMA)                                  # naechster Start: Schema, dann Migration
    assert not set(accounts.PRIMARY_DEVICE_COLUMNS) & set(_cols(conn, "users"))
    accounts._migrate(conn)
    assert _cols(conn, "users")[-3:] == list(accounts.PRIMARY_DEVICE_COLUMNS)
    before = _cols(conn, "users")
    accounts._migrate(conn)
    accounts._migrate(conn)
    assert _cols(conn, "users") == before, "wiederholbar"
    conn.close()


def test_migration_keeps_old_accounts_and_tolerates_a_parallel_start(tmp_path):
    """users von vor der Geraete-Regel mit Konten: Spalten werden angehaengt, Zeilen bleiben. Hat ein anderer Prozess
    eine Spalte zwischen Pruefen und ALTER angelegt (12 Dienst-Prozesse starten gleichzeitig), ist das kein Fehler."""
    import sqlite3
    from app import accounts, db
    conn = sqlite3.connect(tmp_path / "alt.db")
    conn.executescript(accounts.SCHEMA)
    conn.execute("INSERT INTO users(id, email, university, created_at) VALUES ('u1', 'a@b.de', 'luh', '2026-11-01T00:00:00Z')")
    conn.commit()
    assert not set(accounts.PRIMARY_DEVICE_COLUMNS) & set(_cols(conn, "users")), "SCHEMA allein ist der Stand von vorher"
    accounts._migrate(conn)
    assert set(accounts.PRIMARY_DEVICE_COLUMNS) <= set(_cols(conn, "users"))
    assert conn.execute("SELECT id, email, plan, primary_device_id, primary_device_name, primary_device_set_at FROM users").fetchall() \
        == [("u1", "a@b.de", "free", None, None, None)], "alte Konten bleiben, ohne Hauptgeraet"
    # der andere Prozess war schneller: table_info zeigt die Spalten noch nicht, ALTER meldet "duplicate column name"
    for missing in ([accounts.PRIMARY_DEVICE_COLUMNS[0]], list(accounts.PRIMARY_DEVICE_COLUMNS)):
        accounts._migrate(_StaleTableInfo(conn, "users", missing))
    assert db.add_column(_StaleTableInfo(conn, "users", ["primary_device_id"]), "users", "primary_device_id", "TEXT") is False
    assert _cols(conn, "users").count("primary_device_id") == 1
    conn.close()


def test_schema_describes_the_device_field():
    s = schema_v2("me")["properties"]["device"]
    assert s["properties"]["state"]["enum"] == ["ok", "blocked", "hint_plus"]
    from app import device_limit
    assert tuple(s["properties"]["state"]["enum"]) == device_limit.STATES
    assert "device" not in schema_v2("me")["required"], "aeltere Clients bekommen das Feld nicht"
    sample = {"state": "blocked", "is_primary": False, "primary_name": "iPad", "primary_set_at": "2026-11-14T10:00:00Z", **PRICE}
    assert check(sample, s) == []
    assert check({**sample, "state": "gesperrt"}, s) != []


def test_fixture_matches_python(hosted):
    """packages/shared-contracts/fixtures/device-limit/contract.json (liest auch der Swift-Kern) entspricht dem Dienst."""
    import importlib.util
    root = Path(__file__).resolve().parents[1]
    spec = importlib.util.spec_from_file_location("gen_device_limit_fixture", root / "tools" / "gen-device-limit-fixture.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    stored = json.loads((root / "packages/shared-contracts/fixtures/device-limit/contract.json").read_text(encoding="utf-8"))
    assert mod.build(hosted) == stored, "python tools/gen-device-limit-fixture.py neu ausfuehren"

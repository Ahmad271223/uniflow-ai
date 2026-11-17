"""Weck-Signal (app/wake_push.py, app/wake_push_api.py, docs/WECK-SIGNAL-2026-11-17.md): Zeitplan, Endpunkte,
Abmelden/Konto loeschen, Versand an ein nachgebautes APNs.

Kein Test sendet an Apple: der Versand laeuft ueber eine Attrappe (`FakeApns`) bzw. einen eigenen HTTP/2-Server auf
127.0.0.1 (`local_apns`); der echte Weg (`Http2Transport`) ist in allen anderen Tests gesperrt (`_no_real_apns`).
Der APNs-Schluessel wird je Test frisch in einem Temp-Ordner erzeugt, im Repo liegt keiner.
"""
import base64
import hashlib
import io
import json
import logging
import socket
import ssl
import threading
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest
from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]
BERLIN = ZoneInfo("Europe/Berlin")
PW = "sehr-geheim-123"
KEY_ID, TEAM_ID = "KEYID12345", "TEAMID1234"


# ---------------------------------------------------------------- Hilfen

def tokens_with_offset(offset: int, n: int = 1) -> list[str]:
    """Erfundene APNs-Token (64 Hex-Zeichen), deren Versatz genau `offset` Minuten ist; alphabetisch sortiert."""
    from app import wake_push
    out, i = [], 0
    while len(out) < n:
        t = hashlib.sha256(f"geraet-{offset}-{i}".encode()).hexdigest()
        if wake_push.offset_minutes(t) == offset:
            out.append(t)
        i += 1
    return sorted(out)


def berlin(y, mo, d, h, mi=0, s=0) -> datetime:
    return datetime(y, mo, d, h, mi, s, tzinfo=BERLIN)


def signals_in_24h(start: datetime, tz: str, token: str) -> list[datetime]:
    """Minute fuer Minute 24 Stunden ab `start`: jede Minute, in der ein Signal anstuende (wie die Schleife sendet)."""
    from app import wake_push
    last, out = None, []
    for i in range(24 * 60):
        t = start.astimezone(timezone.utc) + timedelta(minutes=i)
        if wake_push.is_due(t, tz, token, last):
            last = t
            out.append(t)
    return out


def _json(st_hdr_body):
    st, headers, body = st_hdr_body
    return st, (json.loads(body) if body else None), {k.decode().lower(): v.decode() for k, v in headers}


def _auth(token):
    return {"Authorization": f"Bearer {token}"}


def _account(app, email, device_id="ipad-1", name="iPad"):
    """Konto anlegen und mit einer Geraete-Kennung anmelden (wie die Apple-App); liefert (Konto, Sitzungs-Kopfzeile)."""
    st, data, _ = _json(asgi_call(app, "POST", "/api/account/register", body=json.dumps({"email": email, "password": PW, "university": "luh"})))
    assert st == 201, data
    return data["user"], _login(app, email, device_id, name)


def _login(app, email, device_id=None, name=None):
    body = {"email": email, "password": PW, **({"device_id": device_id, "device_name": name} if device_id else {})}
    st, data, _ = _json(asgi_call(app, "POST", "/api/account/login", body=json.dumps(body)))
    assert st == 200, data
    return _auth(data["token"])


def _put(app, headers, token, **over):
    body = {"token": token, "platform": "ipados", "app_version": "1.0.6 (45)", "timezone": "Europe/Berlin", **over}
    return _json(asgi_call(app, "PUT", "/api/account/push-token", body=json.dumps(body), headers=headers))


def _delete(app, headers, body=None):
    return _json(asgi_call(app, "DELETE", "/api/account/push-token", body=json.dumps(body) if body is not None else None, headers=headers))


def _rows(user_id=None) -> list[dict]:
    from app import wake_push
    with wake_push.cursor() as conn:
        sql = "SELECT * FROM push_tokens" + (" WHERE user_id=?" if user_id else "") + " ORDER BY token"
        return [dict(r) for r in conn.execute(sql, (user_id,) if user_id else ())]


class FakeApns:
    """Nachgebautes APNs: merkt sich jeden Aufruf, antwortet je Token wie eingestellt (Standard 200)."""

    def __init__(self):
        self.calls, self.responses, self.default = [], {}, (200, {}, b"")

    def __call__(self, host, token, headers, body):
        self.calls.append({"host": host, "token": token, "headers": dict(headers), "body": body})
        r = self.responses.get(token, self.default)
        if isinstance(r, Exception):
            raise r
        return r

    def tokens(self):
        return [c["token"] for c in self.calls]


def apple(status, reason=None, headers=None, **extra):
    return status, headers or {}, json.dumps({"reason": reason, **extra}).encode() if reason else b""


@pytest.fixture
def hosted(app, monkeypatch):
    """Gehosteter Modus mit leerer Kontodatenbank (wie tests/test_accounts.py); Weck-Signal wie im Auslieferzustand aus."""
    from app import accounts, config
    monkeypatch.setattr(config, "MODE", "hosted")
    for name in ("STUDINOW_WAKE_PUSH", "APNS_KEY_PATH", "APNS_KEY_ID", "APNS_TEAM_ID", "APNS_TOPIC", "LERNAPP_APPLE_TEAM_ID"):
        monkeypatch.delenv(name, raising=False)

    def wipe():
        accounts.db_path().unlink(missing_ok=True)
        for suffix in ("-wal", "-shm"):
            accounts.db_path().with_name(accounts.db_path().name + suffix).unlink(missing_ok=True)
    wipe()
    monkeypatch.setattr(accounts, "identity_verifiers", {})
    monkeypatch.setattr(accounts, "reset_sender", None)
    yield app
    wipe()


@pytest.fixture
def apns_key(tmp_path):
    """Eigener EC-Schluessel (P-256) als .p8 im Temp-Ordner, nur fuer diesen Test."""
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    key = ec.generate_private_key(ec.SECP256R1())
    path = tmp_path / "AuthKey_TEST.p8"
    path.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    return path, key.public_key()


@pytest.fixture
def switched_on(hosted, apns_key, monkeypatch):
    """Weck-Signal eingeschaltet und eingerichtet (Schluessel aus dem Temp-Ordner)."""
    monkeypatch.setenv("STUDINOW_WAKE_PUSH", "1")
    monkeypatch.setenv("APNS_KEY_PATH", str(apns_key[0]))
    monkeypatch.setenv("APNS_KEY_ID", KEY_ID)
    monkeypatch.setenv("APNS_TEAM_ID", TEAM_ID)
    return hosted


@pytest.fixture(autouse=True)
def _no_real_apns(monkeypatch, request):
    """Der echte Weg zu Apple ist in Tests gesperrt; nur `local_apns` (eigener Server auf 127.0.0.1) gibt ihn frei."""
    from app import wake_push
    if "local_apns" in request.fixturenames:
        return

    def blocked(self, *a, **k):
        raise AssertionError("Tests senden nie an Apple")
    monkeypatch.setattr(wake_push.Http2Transport, "__call__", blocked)


def _user_with_tokens(email, tokens, tz="Europe/Berlin", environment=None):
    """Konto mit je einem gemeldeten Geraet je Token (ohne HTTP); liefert die Konto-ID."""
    from app import accounts, wake_push
    u = accounts.register(email, PW, "luh")
    for i, t in enumerate(tokens):
        _, session = accounts.login(email, PW, f"geraet-{i}", f"Gerät {i}")
        wake_push.register(u["id"], session, t, "ios", "1.0.6", tz, environment)
    return u["id"]


# ---------------------------------------------------------------- Zeitplan: Fenster, Staffelung, 20 je Tag

def test_the_three_numbers_live_in_one_place():
    from app import wake_push
    assert (wake_push.WINDOW_START_HOUR, wake_push.WINDOW_END_HOUR, wake_push.INTERVAL_MINUTES) == (8, 18, 30)
    assert wake_push.SIGNALS_PER_DAY == 20
    t = tokens_with_offset(7)[0]
    assert wake_push.schedule_info(t) == {"from": "08:00", "to": "18:00", "every_minutes": 30, "offset_minutes": 7}


@pytest.mark.parametrize("h, mi, s, expected", [
    (7, 59, 59, None),              # 07:59: noch nichts
    (8, 0, 0, (8, 0)),              # 08:00: gehoert dazu
    (8, 29, 59, (8, 0)),
    (8, 30, 0, (8, 30)),
    (17, 29, 0, (17, 0)),
    (17, 59, 59, (17, 30)),         # 17:59: letzter Abschnitt
    (18, 0, 0, None),               # 18:00: gehoert nicht mehr dazu
    (23, 15, 0, None),
])
def test_window_edges_for_a_token_without_offset(h, mi, s, expected):
    from app import wake_push
    token = tokens_with_offset(0)[0]
    slot = wake_push.slot_start(berlin(2026, 11, 17, h, mi, s), "Europe/Berlin", token)
    if expected is None:
        assert slot is None
    else:
        assert slot == berlin(2026, 11, 17, *expected) and slot.tzinfo is timezone.utc


def test_offset_moves_every_signal_but_never_outside_the_window():
    from app import wake_push
    token = tokens_with_offset(29)[0]
    day = lambda h, mi: berlin(2026, 11, 17, h, mi)  # noqa: E731
    assert wake_push.slot_start(day(8, 0), "Europe/Berlin", token) is None, "erstes Signal erst um 08:29"
    assert wake_push.slot_start(day(8, 28), "Europe/Berlin", token) is None
    assert wake_push.slot_start(day(8, 29), "Europe/Berlin", token) == day(8, 29)
    assert wake_push.slot_start(day(17, 58), "Europe/Berlin", token) == day(17, 29)
    assert wake_push.slot_start(day(17, 59), "Europe/Berlin", token) == day(17, 59), "letztes Signal um 17:59"
    assert wake_push.slot_start(day(18, 0), "Europe/Berlin", token) is None, "ab 18:00 nichts, auch wenn der Abschnitt noch liefe"


def test_offset_is_stable_per_token_and_spreads_over_all_minutes():
    from app import wake_push
    tokens = [hashlib.sha256(f"viele-{i}".encode()).hexdigest() for i in range(3000)]
    offsets = [wake_push.offset_minutes(t) for t in tokens]
    assert offsets == [wake_push.offset_minutes(t) for t in tokens], "bei jedem Aufruf derselbe Versatz"
    assert wake_push.offset_minutes(tokens[0].upper()) == offsets[0], "Gross-/Kleinschreibung aendert nichts"
    assert set(offsets) == set(range(30)), "alle Minuten 0 bis 29 kommen vor"
    per_minute = [offsets.count(k) for k in range(30)]
    assert min(per_minute) > 60 and max(per_minute) < 140, "ungefaehr gleich verteilt (100 je Minute erwartet)"
    # derselbe Wert wie in der Doku beschrieben: SHA-256 ueber Vorspann und Token, erste 8 Byte, Rest bei Teilung durch 30
    d = hashlib.sha256(b"studinow.wake.v1\x00" + tokens[0].encode()).digest()
    assert offsets[0] == int.from_bytes(d[:8], "big") % 30


@pytest.mark.parametrize("offset", [0, 13, 29])
def test_twenty_signals_a_day_exactly_thirty_minutes_apart(offset):
    token = tokens_with_offset(offset)[0]
    sent = signals_in_24h(berlin(2026, 11, 17, 0), "Europe/Berlin", token)
    local = [t.astimezone(BERLIN) for t in sent]
    assert len(sent) == 20
    assert (local[0].hour, local[0].minute) == (8, offset) and (local[-1].hour, local[-1].minute) == (17, 30 + offset)
    assert all(8 <= t.hour < 18 for t in local)
    assert {b - a for a, b in zip(sent, sent[1:])} == {timedelta(minutes=30)}


def test_no_second_signal_in_the_same_section_and_a_late_start_catches_up_once():
    from app import wake_push
    token = tokens_with_offset(0)[0]
    sent_at = berlin(2026, 11, 17, 9, 0, 5)
    assert wake_push.is_due(berlin(2026, 11, 17, 9, 0, 5), "Europe/Berlin", token, None)
    assert not wake_push.is_due(berlin(2026, 11, 17, 9, 0, 6), "Europe/Berlin", token, sent_at)
    assert not wake_push.is_due(berlin(2026, 11, 17, 9, 29, 59), "Europe/Berlin", token, sent_at)
    assert wake_push.is_due(berlin(2026, 11, 17, 9, 30), "Europe/Berlin", token, sent_at)
    # der Dienst stand von 09:00 bis 11:50: ein Signal fuer den laufenden Abschnitt, nicht fuenf nachgeholte
    late = berlin(2026, 11, 17, 11, 50)
    assert wake_push.is_due(late, "Europe/Berlin", token, sent_at)
    assert not wake_push.is_due(late + timedelta(minutes=1), "Europe/Berlin", token, late)


def test_summer_and_winter_time_follow_the_clock_on_the_wall():
    from app import wake_push
    token = tokens_with_offset(0)[0]
    utc = timezone.utc
    # Winter (MEZ, UTC+1): 08:00 in Berlin ist 07:00 UTC; Sommer (MESZ, UTC+2): 06:00 UTC
    assert wake_push.slot_start(datetime(2026, 11, 17, 6, 59, tzinfo=utc), "Europe/Berlin", token) is None
    assert wake_push.slot_start(datetime(2026, 11, 17, 7, 0, tzinfo=utc), "Europe/Berlin", token) == datetime(2026, 11, 17, 7, 0, tzinfo=utc)
    assert wake_push.slot_start(datetime(2027, 7, 1, 5, 59, tzinfo=utc), "Europe/Berlin", token) is None
    assert wake_push.slot_start(datetime(2027, 7, 1, 6, 0, tzinfo=utc), "Europe/Berlin", token) == datetime(2027, 7, 1, 6, 0, tzinfo=utc)
    assert wake_push.slot_start(datetime(2027, 7, 1, 16, 0, tzinfo=utc), "Europe/Berlin", token) is None, "18:00 MESZ"
    # die Tage der Umstellung selbst (28.03.2027 vor, 31.10.2027 zurueck) und der Tag davor: immer 20, immer 08:00 bis 17:30
    for y, mo, d in ((2027, 3, 27), (2027, 3, 28), (2027, 10, 30), (2027, 10, 31)):
        sent = [t.astimezone(BERLIN) for t in signals_in_24h(berlin(y, mo, d, 0), "Europe/Berlin", token)]
        assert len(sent) == 20 and (sent[0].hour, sent[0].minute, sent[-1].hour, sent[-1].minute) == (8, 0, 17, 30), (y, mo, d)
        assert all(t.date() == datetime(y, mo, d).date() for t in sent)
    first = lambda y, mo, d: signals_in_24h(berlin(y, mo, d, 0), "Europe/Berlin", token)[0]  # noqa: E731
    assert first(2027, 3, 27).hour == 7 and first(2027, 3, 28).hour == 6, "nach der Umstellung eine Stunde frueher in UTC"
    assert first(2027, 10, 30).hour == 6 and first(2027, 10, 31).hour == 7


@pytest.mark.parametrize("tz, utc_first", [
    ("America/New_York", (13, 0)),          # 08:00 EST = 13:00 UTC
    ("Asia/Tokyo", (23, 0)),                # 08:00 JST = 23:00 UTC am Vortag
    ("Asia/Kolkata", (2, 30)),              # 08:00 IST = 02:30 UTC (halbe Stunde Versatz)
    ("UTC", (8, 0)),
])
def test_other_time_zones_use_their_own_local_time(tz, utc_first):
    from app import wake_push
    token = tokens_with_offset(0)[0]
    zone = ZoneInfo(tz)
    sent = signals_in_24h(datetime(2026, 11, 17, 0, 0, tzinfo=zone), tz, token)
    assert len(sent) == 20
    assert (sent[0].hour, sent[0].minute) == utc_first
    assert [(t.astimezone(zone).hour, t.astimezone(zone).minute) for t in (sent[0], sent[-1])] == [(8, 0), (17, 30)]
    # derselbe Augenblick: in Berlin Mittag, in New York noch Nacht, in Tokio schon Abend
    noon = berlin(2026, 11, 17, 12, 0)
    assert wake_push.slot_start(noon, "Europe/Berlin", token) == noon
    assert wake_push.slot_start(noon, "America/New_York", token) is None
    assert wake_push.slot_start(noon, "Asia/Tokyo", token) is None


def test_planning_needs_an_aware_time_and_a_known_zone():
    from app import wake_push
    token = tokens_with_offset(0)[0]
    with pytest.raises(ValueError):
        wake_push.slot_start(datetime(2026, 11, 17, 12, 0), "Europe/Berlin", token)
    with pytest.raises(ValueError):
        wake_push.slot_start(berlin(2026, 11, 17, 12), "Mars/Olympus_Mons", token)
    for bad in ("", "europe/berlin", "Europe", "../etc/passwd", "Europe/Berlin ", None, 5):
        assert not wake_push.valid_timezone(bad), bad
    assert wake_push.valid_timezone("Europe/Berlin") and wake_push.valid_timezone("America/Argentina/Buenos_Aires")


# ---------------------------------------------------------------- Endpunkte

def test_endpoints_need_a_session(hosted):
    token = tokens_with_offset(0)[0]
    for method, body in (("PUT", {"token": token, "platform": "ios", "timezone": "Europe/Berlin"}), ("DELETE", {"token": token})):
        st, data, _ = _json(asgi_call(hosted, method, "/api/account/push-token", body=json.dumps(body)))
        assert (st, data["code"]) == (401, "unauthenticated")
        st, data, _ = _json(asgi_call(hosted, method, "/api/account/push-token", body=json.dumps(body), headers=_auth("erfunden")))
        assert (st, data["code"]) == (401, "unauthenticated")
    assert _rows() == []


def test_endpoints_exist_only_in_the_hosted_service(app):
    token = tokens_with_offset(0)[0]
    st, data, _ = _put(app, {}, token)
    assert (st, data["code"]) == (501, "not_hosted")
    st, data, _ = _delete(app, {}, {"token": token})
    assert (st, data["code"]) == (501, "not_hosted")


def test_web_and_windows_clients_are_refused_even_when_locked(hosted):
    """Die Routen liegen unter /api/account/ und gehen damit an der Abo-Sperre von Web und Windows vorbei: sie nehmen
    darum nur die Apple-Apps an (Bearer ohne Client-Kopfzeile). Web (Cookie) und Windows aendern nichts."""
    token = tokens_with_offset(0)[0]
    user, h = _account(hosted, "a@beispiel.de")
    assert _put(hosted, h, token)[0] == 200
    bearer = h["Authorization"][len("Bearer "):]
    body = json.dumps({"token": tokens_with_offset(1)[0], "platform": "ios", "timezone": "Europe/Berlin"})
    for extra in ({"X-StudiNow-Client": "windows"}, {"X-StudiNow-Client": "web"}):
        for method in ("PUT", "DELETE"):
            st, data, _ = _json(asgi_call(hosted, method, "/api/account/push-token", body=body, headers={**h, **extra}))
            assert (st, data["code"]) == (400, "push_not_applicable"), (method, extra)
    for method in ("PUT", "DELETE"):                        # Browser: Sitzung im Cookie
        st, data, _ = _json(asgi_call(hosted, method, "/api/account/push-token", body=body, cookies=f"uniflow_session={bearer}"))
        assert (st, data["code"]) == (400, "push_not_applicable"), method
    assert [r["token"] for r in _rows()] == [token], "nichts dazugekommen, nichts geloescht"


def test_set_token_stores_only_the_allowed_fields(hosted):
    from app import wake_push
    token = tokens_with_offset(4)[0]
    user, h = _account(hosted, "a@beispiel.de", "ipad-1", "iPad von A")
    st, data, headers = _put(hosted, h, token.upper())
    assert st == 200 and data["ok"] is True
    assert headers["cache-control"] == "no-store"
    assert set(data) == {"ok", "push", "schedule"} and token not in json.dumps(data).lower(), "die Antwort wiederholt das Token nicht"
    assert data["schedule"] == {"from": "08:00", "to": "18:00", "every_minutes": 30, "offset_minutes": 4}
    p = data["push"]
    assert set(p) == {"platform", "app_version", "timezone", "environment", "created_at", "last_seen_at"}
    assert (p["platform"], p["app_version"], p["timezone"], p["environment"]) == ("ipados", "1.0.6 (45)", "Europe/Berlin", "production")
    rows = _rows()
    assert len(rows) == 1
    r = rows[0]
    assert set(r) == {"token", "user_id", "device_id", "platform", "app_version", "timezone", "environment",
                      "created_at", "last_seen_at", "last_sent_at", "last_error"}, "nichts ausser dem Vereinbarten, keine Uni-Daten"
    assert (r["token"], r["user_id"], r["device_id"]) == (token, user["id"], "ipad-1"), "Token klein geschrieben, Geraet aus der Sitzung"
    assert r["last_sent_at"] is None and r["last_error"] is None and r["created_at"] == r["last_seen_at"]
    assert wake_push.devices(user["id"])[0]["token"] == token


def test_set_token_again_updates_time_zone_and_version_without_a_second_row(hosted):
    from app import wake_push
    token = tokens_with_offset(0)[0]
    user, h = _account(hosted, "a@beispiel.de")
    assert _put(hosted, h, token)[0] == 200
    with wake_push.cursor() as conn:                      # als waere die erste Meldung gestern gewesen und schon gesendet
        conn.execute("UPDATE push_tokens SET created_at='2026-11-16T08:00:00Z', last_seen_at='2026-11-16T08:00:00Z', "
                     "last_sent_at='2026-11-16T09:00:00Z', last_error='PayloadEmpty'")
    st, data, _ = _put(hosted, h, token, timezone="America/New_York", app_version="1.0.7 (46)", environment="sandbox", platform="iOS")
    assert st == 200
    r, = _rows()
    assert (r["timezone"], r["app_version"], r["environment"], r["platform"]) == ("America/New_York", "1.0.7 (46)", "sandbox", "ios")
    assert r["created_at"] == "2026-11-16T08:00:00Z" and r["last_seen_at"] > "2026-11-16T08:00:00Z"
    assert r["last_sent_at"] == "2026-11-16T09:00:00Z", "zuletzt gesendet bleibt: kein zweites Signal im selben Abschnitt"
    assert r["last_error"] is None, "eine neue Meldung raeumt den alten Fehler weg"
    assert data["push"]["created_at"] == "2026-11-16T08:00:00Z"


def test_a_new_token_of_the_same_device_replaces_the_old_one(hosted):
    old, new, other = tokens_with_offset(0)[0], tokens_with_offset(1)[0], tokens_with_offset(2)[0]
    user, h1 = _account(hosted, "a@beispiel.de", "ipad-1")
    h2 = _login(hosted, "a@beispiel.de", "iphone-1", "iPhone")
    assert _put(hosted, h1, old)[0] == 200 and _put(hosted, h2, other, platform="ios")[0] == 200
    assert _put(hosted, h1, new)[0] == 200
    assert [(r["token"], r["device_id"]) for r in _rows()] == sorted([(new, "ipad-1"), (other, "iphone-1")]), "je Konto und Geraet ein Eintrag"


def test_a_token_belongs_to_one_account_only_and_moves(hosted):
    token = tokens_with_offset(0)[0]
    a, ha = _account(hosted, "a@beispiel.de", "ipad-1")
    b, hb = _account(hosted, "b@beispiel.de", "ipad-1")
    assert _put(hosted, ha, token)[0] == 200
    assert _put(hosted, hb, token, timezone="Asia/Tokyo")[0] == 200
    r, = _rows()
    assert (r["user_id"], r["timezone"]) == (b["id"], "Asia/Tokyo"), "das Token ist umgezogen"
    # A kann B's Token nicht loeschen und erfaehrt auch nichts darueber
    st, data, _ = _delete(hosted, ha, {"token": token})
    assert (st, data) == (200, {"ok": True, "removed": 0})
    assert [x["user_id"] for x in _rows()] == [b["id"]]
    st, data, _ = _delete(hosted, hb, {"token": token})
    assert (st, data) == (200, {"ok": True, "removed": 1}) and _rows() == []


def test_delete_without_body_removes_the_device_of_this_session(hosted):
    t1, t2 = tokens_with_offset(0)[0], tokens_with_offset(1)[0]
    user, h1 = _account(hosted, "a@beispiel.de", "ipad-1")
    h2 = _login(hosted, "a@beispiel.de", "iphone-1", "iPhone")
    assert _put(hosted, h1, t1)[0] == 200 and _put(hosted, h2, t2)[0] == 200
    st, data, _ = _delete(hosted, h1)
    assert (st, data) == (200, {"ok": True, "removed": 1})
    assert [r["device_id"] for r in _rows()] == ["iphone-1"]
    assert _delete(hosted, h1)[1] == {"ok": True, "removed": 0}, "noch einmal: nichts mehr da, kein Fehler"


@pytest.mark.parametrize("over, code", [
    ({"timezone": "Mars/Olympus_Mons"}, "timezone_invalid"),
    ({"timezone": ""}, "timezone_invalid"),
    ({"timezone": "europe/berlin"}, "timezone_invalid"),
    ({"timezone": "GMT+0100"}, "timezone_invalid"),
    ({"timezone": "../../etc/passwd"}, "timezone_invalid"),
    ({"token": "abc"}, "push_token_invalid"),
    ({"token": "a" * 63}, "push_token_invalid"),
    ({"token": "a" * 65}, "push_token_invalid"),            # ungerade Laenge: kein Hex von Bytes
    ({"token": "a" * 202}, "push_token_invalid"),
    ({"token": "g" * 64}, "push_token_invalid"),
    ({"token": ""}, "push_token_invalid"),
    ({"token": "a" * 32 + " " + "a" * 31}, "push_token_invalid"),
    ({"platform": "android"}, "platform_invalid"),
    ({"platform": ""}, "platform_invalid"),
    ({"environment": "staging"}, "environment_invalid"),
    ({"app_version": "x" * 41}, "app_version_invalid"),
    ({"app_version": "1.0\n6"}, "app_version_invalid"),
    ({"timezone": 5}, "invalid_input"),
    ({"token": ["a" * 64]}, "invalid_input"),
    ({"platform": {"x": 1}}, "invalid_input"),
])
def test_invalid_input_is_refused_and_nothing_is_stored(hosted, over, code):
    over = dict(over)
    _, h = _account(hosted, "a@beispiel.de")
    st, data, _ = _put(hosted, h, over.pop("token", "a" * 64), **over)
    assert (st, data["code"]) == (400, code) and data["detail"]
    assert _rows() == []


def test_longest_token_and_missing_optional_fields_are_fine(hosted):
    _, h = _account(hosted, "a@beispiel.de")
    st, data, _ = _json(asgi_call(hosted, "PUT", "/api/account/push-token", headers=h,
                                  body=json.dumps({"token": "ab" * 100, "platform": "macos", "timezone": "Europe/Berlin"})))
    assert st == 200 and data["push"]["environment"] == "production" and data["push"]["app_version"] is None
    assert _delete(hosted, h, {"token": "zz"})[1]["code"] == "push_token_invalid"


def test_reports_are_limited_per_account(hosted, monkeypatch):
    monkeypatch.setenv("LERNAPP_LIMIT_PUSH_TOKEN_USER", "2/60")
    token = tokens_with_offset(0)[0]
    _, ha = _account(hosted, "a@beispiel.de")
    _, hb = _account(hosted, "b@beispiel.de", "ipad-2")
    assert _put(hosted, ha, token)[0] == 200 and _put(hosted, ha, token)[0] == 200
    st, data, headers = _put(hosted, ha, token)
    assert (st, data["code"]) == (429, "rate_limited") and int(headers["retry-after"]) > 0
    assert _put(hosted, hb, tokens_with_offset(1)[0])[0] == 200, "die Grenze gilt je Konto"


def test_default_limit_is_not_part_of_the_account_contract():
    from app import accounts, wake_push
    assert wake_push.LIMIT_NAME not in accounts.LIMITS, "accounts.LIMITS steht in contract.json (rules.limits)"
    assert accounts._limit(wake_push.LIMIT_NAME, wake_push.LIMIT) == (60, 60)


def test_an_account_keeps_at_most_ten_devices(hosted):
    from app import accounts, wake_push
    u = accounts.register("a@beispiel.de", PW, "luh")
    tokens = [hashlib.sha256(f"viele-geraete-{i}".encode()).hexdigest() for i in range(12)]
    start = datetime(2026, 11, 17, 8, 0, tzinfo=timezone.utc)
    for i, t in enumerate(tokens):
        _, session = accounts.login("a@beispiel.de", PW, f"geraet-{i}", None)
        wake_push.register(u["id"], session, t, "ios", "1.0.6", "Europe/Berlin", now=start + timedelta(minutes=i))
    assert sorted(r["token"] for r in _rows()) == sorted(tokens[2:]), "die zwei am laengsten nicht gemeldeten fallen weg"
    assert wake_push.MAX_TOKENS_PER_ACCOUNT == 10


def test_routes_are_not_in_the_account_contract_router(app):
    """Die Routenliste von account_api ist Teil von contract.json; das Weck-Signal haengt an einem eigenen Router."""
    from app import account_api, wake_push_api
    assert not any("push-token" in r.path for r in account_api.router.routes)
    assert sorted((m, r.path) for r in wake_push_api.router.routes for m in r.methods) == [
        ("DELETE", "/api/account/push-token"), ("PUT", "/api/account/push-token")]
    assert "/api/account/push-token" not in account_api.PUBLIC_PATHS


# ---------------------------------------------------------------- Abmelden, Konto loeschen, Export, Loeschfrist

def test_logout_removes_the_device_and_keeps_the_others(hosted):
    t1, t2 = tokens_with_offset(0)[0], tokens_with_offset(1)[0]
    _, h1 = _account(hosted, "a@beispiel.de", "ipad-1")
    h2 = _login(hosted, "a@beispiel.de", "iphone-1", "iPhone")
    assert _put(hosted, h1, t1)[0] == 200 and _put(hosted, h2, t2)[0] == 200
    assert asgi_call(hosted, "POST", "/api/account/logout", headers=h1)[0] == 200
    assert [r["device_id"] for r in _rows()] == ["iphone-1"]
    assert _put(hosted, h1, t1)[0] == 401, "abgemeldet: keine neue Meldung"


def test_logout_all_keeps_only_the_device_that_stays_signed_in(hosted):
    t1, t2, t3 = (tokens_with_offset(k)[0] for k in (0, 1, 2))
    _, h1 = _account(hosted, "a@beispiel.de", "ipad-1")
    h2 = _login(hosted, "a@beispiel.de", "iphone-1", "iPhone")
    h3 = _login(hosted, "a@beispiel.de", "mac-1", "Mac")
    for h, t in ((h1, t1), (h2, t2), (h3, t3)):
        assert _put(hosted, h, t)[0] == 200
    st, data, _ = _json(asgi_call(hosted, "POST", "/api/account/logout-all", headers=h2))
    assert st == 200 and data["revoked"] >= 2
    assert [(r["token"], r["device_id"]) for r in _rows()] == [(t2, "iphone-1")]


def test_signing_a_device_out_from_the_list_removes_it(hosted):
    t1, t2 = tokens_with_offset(0)[0], tokens_with_offset(1)[0]
    _, h1 = _account(hosted, "a@beispiel.de", "ipad-1")
    h2 = _login(hosted, "a@beispiel.de", "iphone-1", "iPhone")
    assert _put(hosted, h1, t1)[0] == 200 and _put(hosted, h2, t2)[0] == 200
    sessions = _json(asgi_call(hosted, "GET", "/api/account/me", headers=h1))[1]["sessions"]
    iphone = next(s for s in sessions if s["device_id"] == "iphone-1")
    assert asgi_call(hosted, "DELETE", f"/api/account/sessions/{iphone['id']}", headers=h1)[0] == 200
    assert [r["device_id"] for r in _rows()] == ["ipad-1"]
    # zwei Sitzungen auf demselben Geraet (alte Anmeldung blieb liegen): die alte abmelden nimmt dem Geraet nichts
    h1b = _login(hosted, "a@beispiel.de", "ipad-1", "iPad")
    sessions = _json(asgi_call(hosted, "GET", "/api/account/me", headers=h1b))[1]["sessions"]
    old = next(s for s in sessions if s["device_id"] == "ipad-1" and not s["current"])
    assert asgi_call(hosted, "DELETE", f"/api/account/sessions/{old['id']}", headers=h1b)[0] == 200
    assert [r["device_id"] for r in _rows()] == ["ipad-1"], "das Konto ist dort noch angemeldet"


def test_changing_or_resetting_the_password_signs_other_devices_out_of_the_signal(hosted):
    from app import accounts
    t1, t2 = tokens_with_offset(0)[0], tokens_with_offset(1)[0]
    user, h1 = _account(hosted, "a@beispiel.de", "ipad-1")
    h2 = _login(hosted, "a@beispiel.de", "iphone-1", "iPhone")
    assert _put(hosted, h1, t1)[0] == 200 and _put(hosted, h2, t2)[0] == 200
    st = asgi_call(hosted, "POST", "/api/account/password", headers=h1,
                   body=json.dumps({"old_password": PW, "new_password": "noch-geheimer-456"}))[0]
    assert st == 200 and [r["device_id"] for r in _rows()] == ["ipad-1"]
    sent = {}
    accounts.reset_sender = lambda email, token: sent.update(token=token)
    accounts.request_password_reset("a@beispiel.de")
    accounts.reset_password(sent["token"], "ganz-neues-passwort-789")
    assert _rows() == [], "nach dem Zuruecksetzen ist jedes Geraet abgemeldet"


def test_deleting_the_account_removes_every_device_at_once(hosted):
    from app import accounts
    t1, t2, tb = (tokens_with_offset(k)[0] for k in (0, 1, 2))
    a, h1 = _account(hosted, "a@beispiel.de", "ipad-1")
    h2 = _login(hosted, "a@beispiel.de", "iphone-1", "iPhone")
    b, hb = _account(hosted, "b@beispiel.de", "ipad-9")
    assert _put(hosted, h1, t1)[0] == 200 and _put(hosted, h2, t2)[0] == 200 and _put(hosted, hb, tb)[0] == 200
    st, data, _ = _json(asgi_call(hosted, "POST", "/api/account/delete", headers=h1, body=json.dumps({"password": PW})))
    assert st == 200 and data["deleted"] is True
    assert [(r["token"], r["user_id"]) for r in _rows()] == [(tb, b["id"])], "sofort weg, nicht erst nach 30 Tagen"
    assert accounts.purge_deleted(0) == 1
    assert [r["user_id"] for r in _rows()] == [b["id"]]


def test_final_purge_removes_leftover_rows_of_a_deleted_account(hosted):
    """Sollte doch ein Eintrag stehen geblieben sein (alter Stand, Fehler): das endgueltige Loeschen nimmt ihn mit."""
    from app import accounts, wake_push
    assert "push_tokens" in accounts.ACCOUNT_TABLES
    uid = _user_with_tokens("a@beispiel.de", tokens_with_offset(0, 1))
    with accounts.cursor() as conn:
        conn.execute("UPDATE users SET status='deleted', deleted_at='2026-01-01T00:00:00Z' WHERE id=?", (uid,))
    assert len(_rows(uid)) == 1
    assert accounts.purge_deleted(30) == 1
    assert _rows() == [] and wake_push.devices(uid) == []


def test_export_lists_what_is_stored_for_the_signal(hosted):
    token = tokens_with_offset(0)[0]
    _, h = _account(hosted, "a@beispiel.de", "ipad-1")
    assert _put(hosted, h, token)[0] == 200
    st, _, raw = asgi_call(hosted, "GET", "/api/account/export", headers=h)
    assert st == 200
    z = zipfile.ZipFile(io.BytesIO(raw))
    konto = json.loads(z.read("konto.json"))
    d, = konto["weck_signal_geraete"]
    assert (d["token"], d["device_id"], d["platform"], d["timezone"], d["environment"]) == (token, "ipad-1", "ipados", "Europe/Berlin", "production")
    assert "Weck-Signal" in z.read("LIESMICH.txt").decode("utf-8")


def test_devices_that_stopped_reporting_are_removed_by_the_retention_job(hosted):
    from app import accounts, retention, wake_push
    old, fresh = tokens_with_offset(0)[0], tokens_with_offset(1)[0]
    _user_with_tokens("a@beispiel.de", [old, fresh])
    now = accounts.now()
    with wake_push.cursor() as conn:
        conn.execute("UPDATE push_tokens SET last_seen_at=? WHERE token=?", (accounts.iso(now - timedelta(days=wake_push.STALE_DAYS + 1)), old))
    assert retention.purge_account_db(now, dry_run=True)["push_tokens"] == 1 and len(_rows()) == 2
    assert retention.purge_account_db(now)["push_tokens"] == 1
    assert [r["token"] for r in _rows()] == [fresh]


def test_account_hooks_work_before_the_table_exists(hosted):
    """Rueckwaertsvertraeglich: eine accounts.db ohne die neue Tabelle (alter Stand) - Abmelden und Loeschen gehen."""
    from app import accounts
    u = accounts.register("a@beispiel.de", PW, "luh")
    _, s1 = accounts.login("a@beispiel.de", PW, "ipad-1", "iPad")
    _, s2 = accounts.login("a@beispiel.de", PW, "ipad-2", "iPad")
    with accounts.cursor() as conn:
        assert not accounts._has_table(conn, "push_tokens")
        sid = conn.execute("SELECT id FROM sessions WHERE token_hash=?", (accounts._token_hash(s2),)).fetchone()["id"]
    assert accounts.revoke_session(u["id"], sid) and accounts.logout_all(u["id"], keep_token=s1) == 0 and accounts.logout(s1)
    assert accounts.delete_account(u["id"], PW)["deleted"] is True


# ---------------------------------------------------------------- Versand: Kopfzeilen, Nutzlast, JWT

def _jwt_parts(jwt: str):
    def dec(part):
        return base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))
    h, p, s = jwt.split(".")
    return json.loads(dec(h)), json.loads(dec(p)), dec(s), f"{h}.{p}".encode("ascii")


def _verify(jwt: str, public_key) -> None:
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature
    _, _, sig, signing = _jwt_parts(jwt)
    assert len(sig) == 64
    public_key.verify(encode_dss_signature(int.from_bytes(sig[:32], "big"), int.from_bytes(sig[32:], "big")), signing, ec.ECDSA(hashes.SHA256()))


def test_headers_payload_and_jwt_are_exactly_what_apple_expects(switched_on, apns_key):
    from app import wake_push
    prod, sand = tokens_with_offset(0, 2)
    _user_with_tokens("a@beispiel.de", [prod])
    _user_with_tokens("b@beispiel.de", [sand], environment="sandbox")
    apns, now = FakeApns(), berlin(2026, 11, 17, 12, 0, 7)
    out = wake_push.Sender(apns).tick(now)
    assert out == {"sent": 2, "removed": 0, "errors": 0, "state": "ok"}
    by_token = {c["token"]: c for c in apns.calls}
    assert by_token[prod]["host"] == "api.push.apple.com" and by_token[sand]["host"] == "api.sandbox.push.apple.com"
    for c in apns.calls:
        assert c["body"] == b'{"aps":{"content-available":1}}', "die Nutzlast enthaelt nichts ausser dem Weck-Zeichen"
        h = c["headers"]
        assert set(h) == {"authorization", "apns-push-type", "apns-priority", "apns-topic", "apns-expiration"}
        assert (h["apns-push-type"], h["apns-priority"], h["apns-topic"]) == ("background", "5", "de.uniflow.ai")
        assert h["apns-expiration"] == str(int(berlin(2026, 11, 17, 12, 30).timestamp())), "verfaellt mit dem Ende des Abschnitts"
        assert h["authorization"].startswith("bearer ")
        jwt = h["authorization"][len("bearer "):]
        head, claims, _, _ = _jwt_parts(jwt)
        assert head == {"alg": "ES256", "kid": KEY_ID}
        assert claims == {"iss": TEAM_ID, "iat": int(now.timestamp())}
        _verify(jwt, apns_key[1])
    assert len({c["headers"]["authorization"] for c in apns.calls}) == 1, "ein JWT fuer alle Signale"
    assert [r["last_sent_at"] for r in _rows()] == ["2026-11-17T11:00:07Z"] * 2 and all(r["last_error"] is None for r in _rows())


def test_topic_and_team_come_from_the_environment(switched_on, monkeypatch):
    from app import wake_push
    assert wake_push.settings().topic == wake_push.DEFAULT_TOPIC == "de.uniflow.ai"
    project = (ROOT / "apps" / "apple" / "project.yml").read_text(encoding="utf-8")
    assert f"PRODUCT_BUNDLE_IDENTIFIER: {wake_push.DEFAULT_TOPIC}\n" in project, "Standard ist die Bundle-ID der App"
    monkeypatch.setenv("APNS_TOPIC", "de.beispiel.andere")
    monkeypatch.delenv("APNS_TEAM_ID")
    monkeypatch.setenv("LERNAPP_APPLE_TEAM_ID", "ANDERESTEAM")
    _user_with_tokens("a@beispiel.de", tokens_with_offset(0, 1))
    apns = FakeApns()
    assert wake_push.Sender(apns).tick(berlin(2026, 11, 17, 12))["sent"] == 1
    h = apns.calls[0]["headers"]
    assert h["apns-topic"] == "de.beispiel.andere"
    assert _jwt_parts(h["authorization"][7:])[1]["iss"] == "ANDERESTEAM", "ohne APNS_TEAM_ID gilt die Team-ID von Mit Apple anmelden"


def test_jwt_is_reused_for_fifty_minutes(switched_on):
    from app import wake_push
    assert (wake_push.JWT_REFRESH_S, wake_push.JWT_MIN_INTERVAL_S) == (50 * 60, 20 * 60)
    token = tokens_with_offset(0)[0]
    _user_with_tokens("a@beispiel.de", [token])
    apns = FakeApns()
    sender = wake_push.Sender(apns)
    start = berlin(2026, 11, 17, 8, 0)
    for minutes in (0, 30, 60, 90, 120):
        assert sender.tick(start + timedelta(minutes=minutes))["sent"] == 1
    jwts = [c["headers"]["authorization"] for c in apns.calls]
    assert jwts[0] == jwts[1], "nach 30 Minuten noch dasselbe"
    assert jwts[2] != jwts[1], "nach 60 Minuten ein neues (aelter als 50 Minuten)"
    assert jwts[3] == jwts[2] and jwts[4] != jwts[3]
    issued = sorted({_jwt_parts(j[7:])[1]["iat"] for j in jwts})
    assert issued == [int((start + timedelta(minutes=m)).timestamp()) for m in (0, 60, 120)]


def test_jwt_is_never_renewed_within_twenty_minutes_even_if_apple_rejects_it(switched_on, monkeypatch):
    from app import wake_push
    monkeypatch.setattr(wake_push, "CONFIG_PAUSE_S", 60)
    a, b, c = (tokens_with_offset(k)[0] for k in (0, 10, 25))
    _user_with_tokens("a@beispiel.de", [a, b, c])
    apns = FakeApns()
    sender = wake_push.Sender(apns)
    day = lambda h, mi: berlin(2026, 11, 17, h, mi)  # noqa: E731
    assert sender.tick(day(8, 0))["sent"] == 1
    first = apns.calls[-1]["headers"]["authorization"]
    # 08:10: Apple lehnt das JWT ab (403). Es ist erst 10 Minuten alt: kein neues, Pause, das Signal bleibt offen
    apns.responses[b] = apple(403, "ExpiredProviderToken")
    assert sender.tick(day(8, 10))["state"] == "paused" and sender.paused_until() == day(8, 11)
    apns.responses.clear()
    assert sender.tick(day(8, 12))["sent"] == 1 and apns.calls[-1]["token"] == b
    assert apns.calls[-1]["headers"]["authorization"] == first, "dasselbe JWT, kein neues vor Ablauf von 20 Minuten"
    # 08:25: wieder 403, das JWT ist jetzt 25 Minuten alt: nach der Pause gibt es ein neues
    apns.responses[c] = apple(403, "ExpiredProviderToken")
    assert sender.tick(day(8, 25))["state"] == "paused"
    apns.responses.clear()
    assert sender.tick(day(8, 27))["sent"] == 1 and apns.calls[-1]["token"] == c
    second = apns.calls[-1]["headers"]["authorization"]
    assert second != first and _jwt_parts(second[7:])[1]["iat"] == int(day(8, 27).timestamp())
    assert _jwt_parts(second[7:])[1]["iat"] - _jwt_parts(first[7:])[1]["iat"] >= wake_push.JWT_MIN_INTERVAL_S


# ---------------------------------------------------------------- Versand: kein Doppel, ungueltige Token, Pause

def test_no_double_send_in_the_same_section_even_after_a_restart(switched_on):
    from app import db, wake_push
    token = tokens_with_offset(0)[0]
    _user_with_tokens("a@beispiel.de", [token])
    apns, now = FakeApns(), berlin(2026, 11, 17, 9, 0)
    assert wake_push.Sender(apns).tick(now)["sent"] == 1
    assert wake_push.Sender(apns).tick(now + timedelta(minutes=1))["sent"] == 0, "derselbe Abschnitt"
    # Neustart des Dienstes: neuer Sender, Schema-Merker des Prozesses weg - `zuletzt gesendet` steht in der Datenbank
    db._schema_done.clear()
    restarted = wake_push.Sender(apns)
    assert restarted.tick(now + timedelta(minutes=29, seconds=59)) == {"sent": 0, "removed": 0, "errors": 0, "state": "ok"}
    assert len(apns.calls) == 1
    assert restarted.tick(now + timedelta(minutes=30))["sent"] == 1 and len(apns.calls) == 2, "naechster Abschnitt"


def test_only_one_of_two_processes_gets_the_section(switched_on):
    from app import wake_push
    token = tokens_with_offset(0)[0]
    _user_with_tokens("a@beispiel.de", [token])
    now = berlin(2026, 11, 17, 9, 0)
    (row, slot), = wake_push.due(now)
    assert slot == now and row["token"] == token
    assert wake_push.claim(token, slot, now) is True
    assert wake_push.claim(token, slot, now) is False, "der zweite Prozess geht leer aus"
    assert wake_push.due(now) == []
    assert wake_push.claim(token, slot + timedelta(minutes=30), now + timedelta(minutes=30)) is True


def test_a_full_day_through_the_sender_gives_twenty_signals_per_device(switched_on):
    from app import wake_push
    t0, t29 = tokens_with_offset(0)[0], tokens_with_offset(29)[0]
    _user_with_tokens("a@beispiel.de", [t0, t29])
    _user_with_tokens("b@beispiel.de", tokens_with_offset(5, 1), tz="America/New_York")
    apns = FakeApns()
    sender = wake_push.Sender(apns)
    start = berlin(2026, 11, 17, 0, 0)
    for i in range(24 * 60):                               # jede Minute ein Durchlauf, zwischendurch ein "Neustart"
        if i % 300 == 0:
            sender = wake_push.Sender(apns)
        sender.tick(start + timedelta(minutes=i))
    sent = apns.tokens()
    assert sent.count(t0) == 20 and sent.count(t29) == 20
    ny = [c for c in apns.calls if c["token"] == tokens_with_offset(5)[0]]
    assert len(ny) == 20, "New York: 08:00 dort ist 14:00 in Berlin; die 20 Signale liegen zwischen 14:05 und 23:35 Berliner Zeit"
    assert len(apns.calls) == 60


def test_tokens_apple_calls_invalid_are_deleted(switched_on):
    from app import wake_push
    gone, bad, unreg, wrong_topic, odd, fine = tokens_with_offset(0, 6)
    _user_with_tokens("a@beispiel.de", [gone, bad, unreg, wrong_topic, odd, fine])
    apns = FakeApns()
    apns.responses = {gone: apple(410, "Unregistered"), bad: apple(400, "BadDeviceToken"), unreg: apple(400, "Unregistered"),
                      wrong_topic: apple(400, "DeviceTokenNotForTopic"), odd: apple(400, "PayloadEmpty")}
    out = wake_push.Sender(apns).tick(berlin(2026, 11, 17, 10, 0))
    assert out == {"sent": 1, "removed": 4, "errors": 1, "state": "ok"}
    left = {r["token"]: r for r in _rows()}
    assert set(left) == {odd, fine}, "nur wirklich ungueltige Token fallen weg"
    assert left[odd]["last_error"] == "PayloadEmpty" and left[fine]["last_error"] is None
    # 410 ganz ohne Rumpf loescht auch
    apns.responses = {odd: (410, {}, b"")}
    assert wake_push.Sender(apns).tick(berlin(2026, 11, 17, 10, 30))["removed"] == 1
    assert [r["token"] for r in _rows()] == [fine]


def test_410_older_than_the_latest_report_keeps_the_device(switched_on):
    """Apple nennt bei 410 den Zeitpunkt, seit dem das Token ungueltig ist. Hat die App sich danach neu gemeldet,
    bleibt der Eintrag."""
    from app import accounts, wake_push
    token = tokens_with_offset(0)[0]
    _user_with_tokens("a@beispiel.de", [token])
    seen = accounts._parse_ts(_rows()[0]["last_seen_at"])
    apns = FakeApns()
    apns.responses[token] = apple(410, "Unregistered", timestamp=int((seen - timedelta(days=1)).timestamp() * 1000))
    out = wake_push.Sender(apns).tick(berlin(2026, 11, 17, 10, 0))
    assert out["removed"] == 0 and _rows()[0]["last_error"] == "Unregistered"
    apns.responses[token] = apple(410, "Unregistered", timestamp=int((seen + timedelta(hours=1)).timestamp() * 1000))
    assert wake_push.Sender(apns).tick(berlin(2026, 11, 17, 10, 30))["removed"] == 1 and _rows() == []


@pytest.mark.parametrize("status, reason", [(429, "TooManyRequests"), (503, "ServiceUnavailable"), (503, None), (500, "InternalServerError")])
def test_apple_asks_to_slow_down_and_the_service_pauses_instead_of_storming(switched_on, status, reason):
    from app import wake_push
    tokens = tokens_with_offset(0, 5)
    _user_with_tokens("a@beispiel.de", tokens)
    apns = FakeApns()
    sender = wake_push.Sender(apns)
    apns.default = apple(status, reason)
    now = berlin(2026, 11, 17, 10, 0)
    out = sender.tick(now)
    assert out == {"sent": 0, "removed": 0, "errors": 0, "state": "paused"} and len(apns.calls) == 1, "nach der ersten Absage ist Schluss"
    assert sender.paused_until() == now + timedelta(seconds=wake_push.BACKOFF_START_S)
    for seconds in (1, 20, 40, 59):
        assert sender.tick(now + timedelta(seconds=seconds))["state"] == "paused"
    assert len(apns.calls) == 1, "in der Pause geht nichts hinaus"
    r = {x["token"]: x for x in _rows()}[tokens[0]]
    assert r["last_sent_at"] is None and r["last_error"] == (reason or str(status)), "nicht zugestellt: der Abschnitt bleibt offen"
    # nach der Pause ein Versuch; Apple sagt wieder nein: die Pause verdoppelt sich
    t2 = now + timedelta(seconds=60)
    assert sender.tick(t2)["state"] == "paused" and len(apns.calls) == 2
    assert sender.paused_until() == t2 + timedelta(seconds=2 * wake_push.BACKOFF_START_S)
    # Apple ist wieder da: alle fuenf bekommen ihr Signal fuer diesen Abschnitt, genau einmal
    apns.default = (200, {}, b"")
    t3 = t2 + timedelta(seconds=120)
    assert sender.tick(t3) == {"sent": 5, "removed": 0, "errors": 0, "state": "ok"}
    assert sorted(apns.tokens()[2:]) == tokens and sender.tick(t3 + timedelta(seconds=20))["sent"] == 0
    assert all(x["last_error"] is None for x in _rows())
    # die naechste Absage beginnt wieder bei der kurzen Pause
    apns.default = apple(status, reason)
    t4 = berlin(2026, 11, 17, 10, 30)
    sender.tick(t4)
    assert sender.paused_until() == t4 + timedelta(seconds=wake_push.BACKOFF_START_S)


def test_pause_grows_only_up_to_a_limit_and_respects_retry_after(switched_on):
    from app import wake_push
    token = tokens_with_offset(0)[0]
    _user_with_tokens("a@beispiel.de", [token])
    apns = FakeApns()
    sender = wake_push.Sender(apns)
    apns.default = apple(503, "ServiceUnavailable")
    now, pauses = berlin(2026, 11, 17, 8, 0), []
    for _ in range(8):
        sender.tick(now)
        pauses.append(int((sender.paused_until() - now).total_seconds()))
        now = sender.paused_until()
    assert pauses == [60, 120, 240, 480, 960, 1800, 1800, 1800] and wake_push.BACKOFF_MAX_S == 1800
    assert len(apns.calls) == 8, "je Pause genau ein Versuch"
    sender2 = wake_push.Sender(apns)
    apns.default = apple(429, "TooManyRequests", headers={"retry-after": "900"})
    t = berlin(2026, 11, 18, 9, 0)
    sender2.tick(t)
    assert sender2.paused_until() == t + timedelta(seconds=900), "Apple nennt die Wartezeit"


def test_no_connection_pauses_too_and_does_not_send_twice(switched_on):
    from app import wake_push
    tokens = tokens_with_offset(0, 3)
    _user_with_tokens("a@beispiel.de", tokens)
    apns = FakeApns()
    sender = wake_push.Sender(apns)
    apns.responses[tokens[0]] = TimeoutError("keine Antwort")
    now = berlin(2026, 11, 17, 10, 0)
    out = sender.tick(now)
    assert out == {"sent": 0, "removed": 0, "errors": 1, "state": "paused"} and len(apns.calls) == 1
    apns.responses.clear()
    out = sender.tick(now + timedelta(seconds=61))
    assert out["sent"] == 2 and tokens[0] not in apns.tokens()[1:], \
        "ob das erste Signal ankam, ist offen: in diesem Abschnitt kein zweiter Versuch"
    assert {r["token"]: r["last_error"] for r in _rows()}[tokens[0]] == "transport"


def test_setup_errors_from_apple_pause_long_and_are_said_once(switched_on, caplog):
    from app import wake_push
    tokens = tokens_with_offset(0, 3)
    _user_with_tokens("a@beispiel.de", tokens)
    apns = FakeApns()
    sender = wake_push.Sender(apns)
    apns.default = apple(400, "BadTopic")
    now = berlin(2026, 11, 17, 10, 0)
    with caplog.at_level(logging.DEBUG):
        assert sender.tick(now)["state"] == "paused" and len(apns.calls) == 1
        assert sender.paused_until() == now + timedelta(seconds=wake_push.CONFIG_PAUSE_S)
        assert sender.tick(now + timedelta(minutes=31))["state"] == "paused" and len(apns.calls) == 2
    said = [r.getMessage() for r in caplog.records if "lehnt die Einrichtung ab" in r.getMessage()]
    assert len(said) == 1 and "BadTopic" in said[0] and "APNS_TOPIC" in said[0]
    assert len(_rows()) == 3, "kein Token wird wegen eines Einrichtungsfehlers geloescht"


# ---------------------------------------------------------------- ausgeschaltet, ohne Schluessel, Protokoll

def test_switched_off_by_default_nothing_is_sent_and_it_is_said_once(hosted, caplog):
    from app import wake_push
    assert wake_push.settings().enabled is False, "Standard: aus"
    _user_with_tokens("a@beispiel.de", tokens_with_offset(0, 2))
    apns = FakeApns()
    sender = wake_push.Sender(apns)
    with caplog.at_level(logging.DEBUG):
        for minutes in (0, 30, 60):
            assert sender.tick(berlin(2026, 11, 17, 10, 0) + timedelta(minutes=minutes)) == {"sent": 0, "removed": 0, "errors": 0, "state": "off"}
    assert apns.calls == [] and all(r["last_sent_at"] is None for r in _rows())
    lines = [r.getMessage() for r in caplog.records if r.name == "uniflow.wake"]
    assert lines == ["Weck-Signal: ausgeschaltet (STUDINOW_WAKE_PUSH ist nicht 1). Es wird nichts an Apple gesendet."]


@pytest.mark.parametrize("value", ["", "0", "true", "ja", "on", " 2 "])
def test_only_the_value_one_switches_on(hosted, monkeypatch, value):
    from app import wake_push
    monkeypatch.setenv("STUDINOW_WAKE_PUSH", value)
    assert wake_push.settings().enabled is False
    monkeypatch.setenv("STUDINOW_WAKE_PUSH", " 1 ")
    assert wake_push.settings().enabled is True


@pytest.mark.parametrize("missing, words", [
    ("APNS_KEY_PATH", "es fehlt APNS_KEY_PATH"),
    ("APNS_KEY_ID", "es fehlt APNS_KEY_ID"),
    ("APNS_TEAM_ID", "es fehlt APNS_TEAM_ID"),
    ("file", "die Schlüsseldatei aus APNS_KEY_PATH gibt es nicht"),
])
def test_switched_on_without_a_complete_key_sends_nothing_and_says_why_once(switched_on, apns_key, monkeypatch, caplog, missing, words):
    from app import wake_push
    if missing == "file":
        apns_key[0].unlink()
    else:
        monkeypatch.delenv(missing)
    _user_with_tokens("a@beispiel.de", tokens_with_offset(0, 2))
    apns = FakeApns()
    sender = wake_push.Sender(apns)
    with caplog.at_level(logging.DEBUG):
        for minutes in (0, 30, 60):
            assert sender.tick(berlin(2026, 11, 17, 10, 0) + timedelta(minutes=minutes))["state"] == "off"
    assert apns.calls == []
    lines = [r.getMessage() for r in caplog.records if r.name == "uniflow.wake"]
    assert len(lines) == 1 and words in lines[0] and "Es wird nichts an Apple gesendet." in lines[0]
    assert str(apns_key[0]) not in lines[0]


def test_a_file_that_is_not_a_key_sends_nothing_and_keeps_the_section_open(switched_on, apns_key, caplog):
    from app import wake_push
    apns_key[0].write_text("kein Schluessel", encoding="utf-8")
    token = tokens_with_offset(0)[0]
    _user_with_tokens("a@beispiel.de", [token])
    apns = FakeApns()
    sender = wake_push.Sender(apns)
    with caplog.at_level(logging.DEBUG):
        assert sender.tick(berlin(2026, 11, 17, 10, 0))["state"] == "off"
        assert sender.tick(berlin(2026, 11, 17, 10, 5))["state"] == "paused"
    assert apns.calls == [] and _rows()[0]["last_sent_at"] is None
    lines = [r.getMessage() for r in caplog.records if "lässt sich nicht lesen" in r.getMessage()]
    assert len(lines) == 1


def test_without_the_http2_package_nothing_is_sent_and_it_is_said_once(switched_on, monkeypatch, caplog):
    from app import wake_push

    def no_h2():
        raise ImportError("No module named 'h2'")
    monkeypatch.setattr(wake_push, "_http_client_module", no_h2)
    _user_with_tokens("a@beispiel.de", tokens_with_offset(0, 1))
    sender = wake_push.Sender()                            # ohne Attrappe: der echte Weg waere dran
    with caplog.at_level(logging.DEBUG):
        assert sender.tick(berlin(2026, 11, 17, 10, 0))["state"] == "off" and sender.tick(berlin(2026, 11, 17, 10, 30))["state"] == "off"
    lines = [r.getMessage() for r in caplog.records if r.name == "uniflow.wake"]
    assert len(lines) == 1 and "h2" in lines[0] and "requirements.txt" in lines[0]
    assert _rows()[0]["last_sent_at"] is None
    assert "h2==" in (ROOT / "requirements.txt").read_text(encoding="utf-8")


def test_log_never_contains_a_token_only_a_short_hash(switched_on, caplog):
    from app import wake_push
    gone, odd, fine, down = tokens_with_offset(0, 4)
    _user_with_tokens("a@beispiel.de", [gone, odd, fine, down])
    apns = FakeApns()
    sender = wake_push.Sender(apns)
    apns.responses = {gone: apple(410, "Unregistered"), odd: apple(400, "Seltsam\nGEFÄLSCHTE ZEILE " + odd),
                      down: OSError(f"connect https://api.push.apple.com/3/device/{down} failed")}
    with caplog.at_level(logging.DEBUG):
        out = sender.tick(berlin(2026, 11, 17, 10, 0))
        assert out["removed"] == 1 and out["errors"] == 2 and out["state"] == "paused"
        apns.default = apple(503, "ServiceUnavailable")
        apns.responses = {}
        sender.tick(berlin(2026, 11, 17, 10, 31))
        apns.default = apple(403, "InvalidProviderToken")
        wake_push.Sender(apns).tick(berlin(2026, 11, 17, 11, 0))
    text = "\n".join(r.getMessage() for r in caplog.records) + caplog.text
    assert len(caplog.records) >= 5
    for t in (gone, odd, fine, down):
        assert t not in text and t[:16] not in text and t[-16:] not in text
    for t in (gone, odd, down):
        assert wake_push.short(t) in text, "gekuerzter Hash zum Wiederfinden"
    assert len(wake_push.short(gone)) == 10 and wake_push.short(gone) == hashlib.sha256(gone.encode()).hexdigest()[:10]
    assert "GEFÄLSCHTE ZEILE" not in text and "\nGEF" not in text, "der Grund von Apple wird auf Buchstaben und Ziffern gekuerzt"
    assert "bearer " not in text.lower() and "eyJ" not in text, "auch das JWT steht nie im Protokoll"


def test_status_command_shows_the_state_without_sending(switched_on, capsys):
    from app import wake_push
    prod, sand = tokens_with_offset(0, 2)
    _user_with_tokens("a@beispiel.de", [prod])
    _user_with_tokens("b@beispiel.de", [sand], environment="sandbox")
    assert wake_push.main(["--status"]) == 0
    out = capsys.readouterr().out
    assert "bereit" in out and "1 (production), 1 (sandbox)" in out and "noch nie" in out and "de.uniflow.ai" in out
    assert prod not in out and sand not in out and KEY_ID not in out
    assert wake_push.main([]) == 2


# ---------------------------------------------------------------- Schleife im Dienst

def test_loop_survives_errors_and_ends_with_the_stop_signal():
    from app import wake_push
    stop, seen = threading.Event(), []

    class Broken(wake_push.Sender):
        def tick(self, now=None):
            seen.append(1)
            if len(seen) >= 3:
                stop.set()
            raise RuntimeError("kaputt")
    t = threading.Thread(target=wake_push.run_loop, args=(stop, Broken(), 0.01))
    t.start()
    t.join(10)
    assert not t.is_alive() and len(seen) == 3


def _quiet_runner(monkeypatch):
    """Job-Runner ohne Abgleich und ohne Loeschfristen (die gehoeren zu anderen Tests)."""
    from app import jobs, retention
    monkeypatch.setattr(jobs, "schedule_due", lambda *a, **k: 0)
    monkeypatch.setattr(retention, "schedule_due", lambda *a, **k: None)
    return jobs.Runner(workers=1, poll_seconds=0.05)


def test_service_starts_no_loop_while_switched_off(hosted, monkeypatch, caplog):
    from app import wake_push
    monkeypatch.setattr(wake_push, "_said_off", False)
    runners = []
    try:
        with caplog.at_level(logging.DEBUG):
            for _ in range(2):
                r = _quiet_runner(monkeypatch)
                runners.append(r)
                r.start()
                assert r._wake is None and r.alive()
                assert r.stop(10) == []
    finally:
        for r in runners:
            r.stop(10)
    assert not any(t.name == "uniflow-wake" for t in threading.enumerate())
    lines = [x.getMessage() for x in caplog.records if x.name == "uniflow.wake"]
    assert lines == ["Weck-Signal: ausgeschaltet (STUDINOW_WAKE_PUSH ist nicht 1). Es wird nichts an Apple gesendet."], "einmal je Prozess"


def test_service_runs_the_loop_when_switched_on_and_stops_it_cleanly(switched_on, monkeypatch):
    from app import wake_push
    ticks = []
    monkeypatch.setattr(wake_push.Sender, "tick", lambda self, now=None: ticks.append(1) or {})
    r = _quiet_runner(monkeypatch)
    try:
        r.start()
        assert r._wake is not None and r._wake.name == "uniflow-wake" and r._wake.daemon
        assert r._wake not in r._threads, "das Weck-Signal zaehlt nicht zum Lebenszeichen der Jobs"
        for _ in range(200):
            if ticks:
                break
            threading.Event().wait(0.01)
        assert ticks, "die Schleife laeuft"
    finally:
        assert r.stop(10) == []
        r._wake.join(10)
    assert not r._wake.is_alive()


def test_a_broken_start_of_the_signal_never_stops_the_jobs(hosted, monkeypatch, capsys):
    from app import wake_push

    def boom(stop):
        raise RuntimeError("kaputt")
    monkeypatch.setattr(wake_push, "start_background", boom)
    r = _quiet_runner(monkeypatch)
    try:
        r.start()
        assert r.alive() and r._wake is None
    finally:
        assert r.stop(10) == []
    assert "Weck-Signal nicht gestartet" in capsys.readouterr().out


def test_local_mode_has_no_loop(app, monkeypatch):
    """Am eigenen PC und in der Windows-App startet der Job-Runner nicht - also auch kein Weck-Signal."""
    from app import config, jobs
    monkeypatch.setenv("STUDINOW_WAKE_PUSH", "1")
    assert not config.is_hosted() and jobs.start_background() is None
    assert not any(t.name == "uniflow-wake" for t in threading.enumerate())


# ---------------------------------------------------------------- der echte HTTP/2-Weg gegen einen eigenen Server

class LocalApns:
    """Nachgebautes APNs als echter HTTP/2-Server (TLS, ALPN h2) auf 127.0.0.1 mit eigenem Zertifikat."""

    def __init__(self, tmp_path):
        import ipaddress

        from cryptography import x509
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import ec
        from cryptography.x509.oid import NameOID
        key = ec.generate_private_key(ec.SECP256R1())
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "apns.test")])
        t = datetime.now(timezone.utc)
        cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
                .serial_number(x509.random_serial_number()).not_valid_before(t - timedelta(minutes=5))
                .not_valid_after(t + timedelta(hours=1))
                .add_extension(x509.SubjectAlternativeName([x509.IPAddress(ipaddress.ip_address("127.0.0.1"))]), critical=False)
                .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
                .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False)
                .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(key.public_key()), critical=False)
                .add_extension(x509.KeyUsage(digital_signature=True, key_cert_sign=True, crl_sign=False, content_commitment=False,
                                             key_encipherment=False, data_encipherment=False, key_agreement=False,
                                             encipher_only=False, decipher_only=False), critical=True)
                .sign(key, hashes.SHA256()))
        self.cert_path, key_path = tmp_path / "apns-test.crt", tmp_path / "apns-test.key"
        self.cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
        key_path.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(self.cert_path, key_path)
        ctx.set_alpn_protocols(["h2"])
        self._ctx = ctx
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._sock.bind(("127.0.0.1", 0))
        self._sock.listen(8)
        self.port = self._sock.getsockname()[1]
        self.requests, self.responses, self.connections, self.alpn = [], {}, 0, []
        self._stop = threading.Event()
        self._threads = [threading.Thread(target=self._accept, daemon=True)]
        self._threads[0].start()

    def client_context(self) -> ssl.SSLContext:
        return ssl.create_default_context(cafile=str(self.cert_path))

    def _accept(self):
        self._sock.settimeout(0.2)
        while not self._stop.is_set():
            try:
                raw, _ = self._sock.accept()
            except (TimeoutError, OSError):
                continue
            t = threading.Thread(target=self._serve, args=(raw,), daemon=True)
            self._threads.append(t)
            t.start()

    def _serve(self, raw):
        import h2.config
        import h2.connection
        import h2.events
        try:
            tls = self._ctx.wrap_socket(raw, server_side=True)
        except (ssl.SSLError, OSError):
            return
        self.connections += 1
        number = self.connections
        self.alpn.append(tls.selected_alpn_protocol())
        conn = h2.connection.H2Connection(config=h2.config.H2Configuration(client_side=False))
        conn.initiate_connection()
        tls.sendall(conn.data_to_send())
        streams = {}
        tls.settimeout(0.2)
        try:
            while not self._stop.is_set():
                try:
                    data = tls.recv(65535)
                except (TimeoutError, ssl.SSLWantReadError):
                    continue
                if not data:
                    return
                for ev in conn.receive_data(data):
                    if isinstance(ev, h2.events.RequestReceived):
                        streams[ev.stream_id] = {"headers": {k.decode() if isinstance(k, bytes) else k: v.decode() if isinstance(v, bytes) else v
                                                             for k, v in ev.headers}, "body": b"", "connection": number}
                    elif isinstance(ev, h2.events.DataReceived):
                        streams[ev.stream_id]["body"] += ev.data
                        conn.acknowledge_received_data(ev.flow_controlled_length, ev.stream_id)
                    elif isinstance(ev, h2.events.StreamEnded):
                        req = streams.pop(ev.stream_id)
                        self.requests.append(req)
                        status, body = self.responses.get(req["headers"][":path"].rsplit("/", 1)[-1], (200, b""))
                        conn.send_headers(ev.stream_id, [(":status", str(status)), ("apns-id", "0000-test"),
                                                         ("content-length", str(len(body)))], end_stream=not body)
                        if body:
                            conn.send_data(ev.stream_id, body, end_stream=True)
                out = conn.data_to_send()
                if out:
                    tls.sendall(out)
        except (OSError, ssl.SSLError):
            return
        finally:
            try:
                tls.close()
            except OSError:
                pass

    def close(self):
        self._stop.set()
        self._sock.close()
        for t in self._threads:
            t.join(5)


@pytest.fixture
def local_apns(tmp_path):
    pytest.importorskip("h2", reason="HTTP/2-Paket h2 (requirements.txt) nicht installiert")
    server = LocalApns(tmp_path)
    yield server
    server.close()


def test_real_http2_transport_speaks_to_a_local_apns(local_apns, caplog):
    from app import wake_push
    ok, gone = tokens_with_offset(0, 2)
    local_apns.responses[gone] = (410, json.dumps({"reason": "Unregistered", "timestamp": 1763380800000}).encode())
    transport = wake_push.Http2Transport(verify=local_apns.client_context(), port=local_apns.port)
    headers = {"authorization": "bearer test.jwt.sig", "apns-push-type": "background", "apns-priority": "5",
               "apns-topic": "de.uniflow.ai", "apns-expiration": "1763380800"}
    try:
        with caplog.at_level(logging.DEBUG):
            status, resp_headers, body = transport("127.0.0.1", ok, headers, wake_push.PAYLOAD)
            assert (status, body) == (200, b"") and resp_headers["apns-id"] == "0000-test"
            status, _, body = transport("127.0.0.1", gone, headers, wake_push.PAYLOAD)
            assert status == 410 and json.loads(body)["reason"] == "Unregistered"
    finally:
        transport.close()
    assert local_apns.alpn == ["h2"] and local_apns.connections == 1, "HTTP/2, beide Signale ueber dieselbe Verbindung"
    first, second = local_apns.requests
    assert first["headers"][":method"] == "POST" and first["headers"][":scheme"] == "https"
    assert first["headers"][":path"] == f"/3/device/{ok}" and second["headers"][":path"] == f"/3/device/{gone}"
    for name, value in headers.items():
        assert first["headers"][name] == value
    assert first["body"] == b'{"aps":{"content-available":1}}' == second["body"]
    assert first["headers"]["content-length"] == str(len(wake_push.PAYLOAD))
    assert ok not in caplog.text and gone not in caplog.text, "auch der HTTP-Client schreibt das Token nicht ins Protokoll"


def test_sender_end_to_end_over_http2_against_the_local_apns(local_apns, switched_on, apns_key, monkeypatch):
    from app import wake_push
    fine, gone = tokens_with_offset(0, 2)
    _user_with_tokens("a@beispiel.de", [fine, gone])
    local_apns.responses[gone] = (410, json.dumps({"reason": "Unregistered"}).encode())
    monkeypatch.setattr(wake_push, "HOSTS", {"production": "127.0.0.1", "sandbox": "127.0.0.1"})
    transport = wake_push.Http2Transport(verify=local_apns.client_context(), port=local_apns.port)
    try:
        out = wake_push.Sender(transport).tick(berlin(2026, 11, 17, 12, 0))
    finally:
        transport.close()
    assert out == {"sent": 1, "removed": 1, "errors": 0, "state": "ok"}
    assert [r["token"] for r in _rows()] == [fine]
    req = next(r for r in local_apns.requests if r["headers"][":path"].endswith(fine))
    assert req["headers"]["apns-topic"] == "de.uniflow.ai" and req["headers"]["apns-push-type"] == "background"
    _verify(req["headers"]["authorization"][len("bearer "):], apns_key[1])


def test_real_transport_fails_fast_when_nobody_listens(local_apns):
    from app import wake_push
    port = local_apns.port
    local_apns.close()
    transport = wake_push.Http2Transport(verify=local_apns.client_context(), port=port, timeout=2)
    try:
        with pytest.raises(Exception) as e:
            transport("127.0.0.1", tokens_with_offset(0)[0], {}, wake_push.PAYLOAD)
        assert not isinstance(e.value, AssertionError)
    finally:
        transport.close()


# ---------------------------------------------------------------- Doku und Vertrag

def test_docs_name_every_setting_and_the_contract():
    from app import wake_push
    doc = (ROOT / "docs" / "WECK-SIGNAL-2026-11-17.md").read_text(encoding="utf-8")
    for name in (wake_push.ENV_SWITCH, wake_push.ENV_KEY_PATH, wake_push.ENV_KEY_ID, wake_push.ENV_TEAM_ID, wake_push.ENV_TOPIC):
        assert name in doc, name
    for word in ("/api/account/push-token", "08:00", "18:00", "30 Minuten", "python -m app.wake_push --status",
                 "push_token_invalid", "timezone_invalid", "Stromsparmodus"):
        assert word in doc, word
    contract = (ROOT / "docs" / "VERTRAEGE-KONTO-SYNC.md").read_text(encoding="utf-8")
    assert "/api/account/push-token" in contract and "WECK-SIGNAL-2026-11-17.md" in contract
    assert "BEGIN PRIVATE KEY" not in doc and "BEGIN PRIVATE KEY" not in contract

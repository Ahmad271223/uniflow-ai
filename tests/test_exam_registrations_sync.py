"""Angemeldete Pruefungen im Geraeteabgleich (Entscheidung des Inhabers 20.11.2026 "Ja, abgleichen").

Der eigene Abruf ersetzt die Tabelle nicht mehr, sondern fuehrt ueber den fachlichen Schluessel zusammen
(`qis_registrations.store`): gleiche IDs, keine Loeschmarken fuer unveraenderte Pruefungen. Der Abgleich bringt die
Zeilen auf die anderen Geraete desselben Uni-Kontos, ohne Name der Pruefenden, Rohtext und Abrufzeit; der Dienst
speichert diese Spalten nie. Zwei Geraete, die dieselbe Pruefung gleichzeitig senden, ergeben eine Zeile."""
import json
from datetime import date

import pytest
from test_sync_client import _hosted, ipad_pull, ipad_push, two_devices  # noqa: F401  (Fixture)

PRIVATE = ("pruefer", "raw", "fetched_at")


def reg(nr="4711", text="Rechnernetze", semester="WiSe 26/27", datum="01.03.2027", **kw):
    r = {"pruefungsnr": nr, "text": text, "semester": semester, "datum": datum, "time": "09:00", "room": "HS A",
         "pruefer": "Prof. Dr. Erika Beispiel", "versuch": "1", "status": "AN", "withdraw": None, "form": "Klausur",
         "abschluss": "Abschluss 82 Bachelor of Science", "raw": f"{nr} | {text} | Prof. Dr. Erika Beispiel | {semester}"}
    r.update(kw)
    return r


@pytest.fixture
def local_db(monkeypatch, tmp_path):
    from app import db
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "anmeldungen.db")
    db.init_db()
    return db


def _table(conn):
    from app import db
    return db.rows(conn, "SELECT * FROM exam_registrations ORDER BY id")


def _tombs(conn):
    return conn.execute("SELECT COUNT(*) FROM sync_tombstones WHERE entity='exam_registrations'").fetchone()[0]


# ---------------------------------------------------------------- eigener Abruf: zusammenfuehren statt ersetzen

def test_second_fetch_changes_nothing(local_db):
    from app import qis_registrations as Q
    with local_db.cursor() as conn:
        Q.store(conn, [reg(), reg("4712", "Datenbanken", datum="")], "2026-11-20T10:00:00")
        before = _table(conn)
        Q.store(conn, [reg(), reg("4712", "Datenbanken", datum="")], "2026-11-21T10:00:00")
        after = _table(conn)
        assert after == before, "gleicher Abruf: keine Zeile neu geschrieben (gleiche ID, Version, Abrufzeit)"
        assert _tombs(conn) == 0
        assert [r["pruefer"] for r in after] == ["Prof. Dr. Erika Beispiel"] * 2, "auf dem Geraet bleibt der Pruefer"


def test_fetch_updates_inserts_and_deletes_only_what_changed(local_db):
    from app import qis_registrations as Q
    with local_db.cursor() as conn:
        Q.store(conn, [reg(), reg("4712", "Datenbanken", datum=""), reg("4713", "Physik")], "2026-11-20T10:00:00")
        ids = {r["pruefungsnr"]: r["id"] for r in _table(conn)}
        # Raum geaendert, Datum nachgetragen, Physik abgemeldet, Mathe neu
        Q.store(conn, [reg(room="HS B"), reg("4712", "Datenbanken", datum="12.02.2027"), reg("4714", "Mathematik I")],
                "2026-11-21T10:00:00")
        rows = {r["pruefungsnr"]: r for r in _table(conn)}
        assert sorted(rows) == ["4711", "4712", "4714"]
        assert rows["4711"]["id"] == ids["4711"] and rows["4711"]["room"] == "HS B"
        assert rows["4712"]["id"] == ids["4712"] and rows["4712"]["datum"] == "12.02.2027", "nachgetragenes Datum: dieselbe Zeile"
        assert rows["4714"]["id"] not in ids.values()
        assert _tombs(conn) == 1, "nur Physik hinterlaesst eine Loeschmarke"


def test_key_like_swift():
    """Gleicher Schluessel wie `QISRegistrationsSync.key` (ExamRegistrationSyncTests.testKeyLikePython)."""
    from app import qis_registrations as Q, sync
    k = Q.key({"pruefungsnr": " 4711", "text": "Rechnernetze  I ", "semester": "WiSe 26/27", "datum": None})
    assert k == ("4711", "rechnernetze i", "wise 26/27", "")
    assert sync.natural_key("exam_registrations", {"pruefungsnr": "4711", "text": "RECHNERNETZE I", "semester": "WiSe 26/27"}) == k


def test_doubles_in_the_table_are_cleaned_up(local_db):
    from app import qis_registrations as Q
    with local_db.cursor() as conn:
        Q.store(conn, [reg()], "t")
        conn.execute("""INSERT INTO exam_registrations(pruefungsnr, text, semester, datum, raw)
                        VALUES ('4711', ' rechnernetze ', 'WiSe 26/27', '01.03.2027', '')""")
        Q.store(conn, [reg(), reg(text="RECHNERNETZE")], "t2")
        assert len(_table(conn)) == 1, "doppelte Zeile (z. B. aus einem alten Abgleich) verschwindet, Schreibweise egal"


# ---------------------------------------------------------------- Abgleich zwischen Geraeten

def _server_regs(app, ipad):
    changes, _ = ipad_pull(app, ipad)
    return changes.get("exam_registrations", [])


def test_rows_reach_the_other_device_without_examiner(two_devices):
    """Windows liest das QIS, das iPad bekommt die Liste; Pruefer, Rohtext und Abrufzeit verlassen den PC nie."""
    app, ipad = two_devices
    from app import db, qis_registrations as Q, sync_client
    with db.cursor() as conn:
        Q.store(conn, [reg(), reg("4712", "Datenbanken", datum="")], "2026-11-20T10:00:00")
    out = sync_client.run()
    assert out["ok"], out
    rows = _server_regs(app, ipad)
    assert sorted(r["text"] for r in rows) == ["Datenbanken", "Rechnernetze"]
    for r in rows:
        for col in PRIVATE:
            assert col not in r, col
        assert r["room"] == "HS A" and r["status"] == "AN" and r["versuch"] == "1"
    assert "Erika" not in json.dumps(rows, ensure_ascii=False)
    # zweiter Lauf: nichts mehr zu senden, keine Loeschmarke
    again = sync_client.run()
    assert again["ok"] and again["pushed"] == 0 and again["deleted"] == 0
    _, tombs = ipad_pull(app, ipad)
    assert not [t for t in tombs if t["entity"] == "exam_registrations"]


def test_service_drops_examiner_even_if_a_device_sends_it(two_devices):
    app, ipad = two_devices
    r = ipad_push(app, ipad, [{"entity": "exam_registrations", "local_id": -1, "updated_at": "2026-11-20T10:00:00.000Z",
                               "data": {k: v for k, v in reg().items()}}])
    assert r["results"][0]["status"] == "created"
    rows = _server_regs(app, ipad)
    assert len(rows) == 1 and not any(c in rows[0] for c in PRIVATE)
    assert "Erika" not in json.dumps(rows, ensure_ascii=False)


def test_device_without_own_fetch_shows_rows_and_own_fetch_merges(two_devices):
    """Das iPad hat gelesen; der PC (ohne gespeichertes Passwort, Tabelle gibt es hier noch nicht) zeigt die Zeilen.
    Liest der PC spaeter selbst, entsteht keine zweite Zeile, weder hier noch im Dienst."""
    app, ipad = two_devices
    from app import db, exams, qis_registrations as Q, sync_client
    with db.cursor() as conn:
        assert not conn.execute("SELECT 1 FROM sqlite_master WHERE name='exam_registrations'").fetchone()
    data = {k: v for k, v in reg().items() if k not in PRIVATE}
    r = ipad_push(app, ipad, [{"entity": "exam_registrations", "local_id": -1, "updated_at": "2026-11-20T10:00:00.000Z", "data": data}])
    sid = r["results"][0]["id"]
    out = sync_client.run()
    assert out["ok"], out
    with db.cursor() as conn:
        rows = Q.rows(conn)
        assert [(x["pruefungsnr"], x["registered"], x["iso_date"], x["clock"]) for x in rows] == [("4711", True, "2027-03-01", "09:00")]
        assert rows[0]["pruefer"] is None, "der Pruefer kommt nicht ueber den Abgleich"
        # Hinweis "Stand von deinem anderen Gerät" mit der Zeit der letzten Aenderung im Dienst (Ortszeit)
        stamp = Q.synced_at(conn)
        assert stamp and len(stamp) == 19 and stamp[10] == "T", stamp
        from app import exam_registration_api
        view = exam_registration_api.response(conn, "2026-11-20")
        assert view["registrations_synced_at"] == stamp and view["registrations_checked_at"] is None
        assert any(e.get("title", "").startswith("Rechnernetze") or "Rechnernetze" in json.dumps(e, ensure_ascii=False)
                   for e in exams.upcoming(conn, date(2026, 11, 20))), "Termin erscheint wie nach einem eigenen Abruf"
        # eigener Abruf des PCs: dieselbe Pruefung (anders geschrieben) plus eine neue
        Q.store(conn, [reg(text="Rechnernetze "), reg("4712", "Datenbanken", datum="")], "2026-11-21T10:00:00")
        rows = _table(conn)
        assert len(rows) == 2 and rows[0]["pruefer"] == "Prof. Dr. Erika Beispiel", "Pruefer nur lokal ergaenzt"
        assert _tombs(conn) == 0
    out = sync_client.run()
    assert out["ok"], out
    srv = _server_regs(app, ipad)
    assert sorted(x["pruefungsnr"] for x in srv) == ["4711", "4712"], "keine Doppelten im Dienst"
    assert next(x for x in srv if x["pruefungsnr"] == "4711")["id"] == sid
    _, tombs = ipad_pull(app, ipad)
    assert not [t for t in tombs if t["entity"] == "exam_registrations"]


def test_deregistration_on_one_device_removes_it_on_the_other(two_devices):
    app, ipad = two_devices
    from app import db, qis_registrations as Q, sync_client
    with db.cursor() as conn:
        Q.store(conn, [reg(), reg("4712", "Datenbanken")], "t")
    assert sync_client.run()["ok"]
    srv = {x["pruefungsnr"]: x["id"] for x in _server_regs(app, ipad)}
    # das iPad liest spaeter: 4712 abgemeldet -> es loescht die Zeile
    r = ipad_push(app, ipad, [], deletes=[{"entity": "exam_registrations", "id": srv["4712"], "deleted_at": "2099-01-01T00:00:00.000Z"}])
    assert r["results"][0]["status"] == "deleted"
    assert sync_client.run()["ok"]
    with db.cursor() as conn:
        assert [x["pruefungsnr"] for x in Q.rows(conn)] == ["4711"]
        # der PC liest selbst und findet 4711 auch nicht mehr: Loeschmarke an den Dienst
        Q.store(conn, [], "t2")
    assert sync_client.run()["ok"]
    assert _server_regs(app, ipad) == [] or all(x["id"] not in srv.values() for x in _server_regs(app, ipad))
    _, tombs = ipad_pull(app, ipad)
    assert {t["entity_id"] for t in tombs if t["entity"] == "exam_registrations"} == {str(srv["4711"]), str(srv["4712"])}


def test_two_devices_sending_the_same_exam_at_once_give_one_row(two_devices):
    """Gleichzeitiger Abruf: beide senden die Pruefung als neue Zeile, bevor sie die des anderen kennen."""
    app, ipad = two_devices
    data = {k: v for k, v in reg().items() if k not in PRIVATE}
    a = ipad_push(app, ipad, [{"entity": "exam_registrations", "local_id": -1, "updated_at": "2026-11-20T10:00:00.000Z", "data": data}])
    st, b = _hosted(app, "POST", "/api/sync/push", {"device_id": "iphone-1", "items": [
        {"entity": "exam_registrations", "local_id": -7, "updated_at": "2099-01-01T00:00:00.000Z",
         "data": {**data, "text": "rechnernetze", "room": "HS B"}}], "deletes": []}, ipad)
    assert st == 200
    res = b["results"][0]
    assert res["id"] == a["results"][0]["id"], "dieselbe Zeile im Dienst"
    assert res["status"] == "created", "spaeterer Stand gewinnt in allen Feldern: nichts zu uebernehmen"
    assert b["mapping"] == [{"entity": "exam_registrations", "local_id": -7, "id": res["id"]}]
    rows = _server_regs(app, ipad)
    assert len(rows) == 1 and rows[0]["room"] == "HS B"
    # ein drittes Geraet mit aelterem Stand: der Dienst behaelt seine Felder, das Geraet uebernimmt sie (Konflikt)
    st, c = _hosted(app, "POST", "/api/sync/push", {"device_id": "mac-1", "items": [
        {"entity": "exam_registrations", "local_id": -3, "updated_at": "2000-01-01T00:00:00.000Z",
         "data": {**data, "room": "HS C"}}], "deletes": []}, ipad)
    assert st == 200
    x = c["results"][0]
    assert (x["status"], x["id"], x["local_id"], x["client_won"]) == ("conflict", res["id"], -3, [])
    assert c["conflicts"][0]["server"]["room"] == "HS B" and "pruefer" not in c["conflicts"][0]["server"]
    assert [r["room"] for r in _server_regs(app, ipad)] == ["HS B"]


def test_older_service_rows_and_tombstones_for_unknown_tables_are_harmless(two_devices):
    """Loeschmarke fuer eine Tabelle, die im Dienst noch gar nicht existiert: kein Fehler."""
    app, ipad = two_devices
    r = ipad_push(app, ipad, [], deletes=[{"entity": "exam_registrations", "id": 5, "deleted_at": "2026-11-20T10:00:00.000Z"}])
    assert r["results"][0]["status"] == "deleted"
    changes, tombs = ipad_pull(app, ipad)
    assert "exam_registrations" not in changes and not [t for t in tombs if t["entity"] == "exam_registrations"]


def test_race_through_the_windows_client_ends_with_one_row(two_devices, monkeypatch):
    """Der PC sendet seine Zeile, bevor er die des iPads abgerufen hat (erster Abruf faellt aus): der Dienst ordnet sie
    der vorhandenen Zeile zu, der PC merkt sich deren ID; ueberall bleibt eine Zeile, keine Loeschmarke."""
    app, ipad = two_devices
    from app import db, qis_registrations as Q, sync_client
    data = {k: v for k, v in reg().items() if k not in PRIVATE}
    sid = ipad_push(app, ipad, [{"entity": "exam_registrations", "local_id": -1, "updated_at": "2099-01-01T00:00:00.000Z",
                                 "data": {**data, "room": "HS B"}}])["results"][0]["id"]
    with db.cursor() as conn:
        Q.store(conn, [reg()], "2026-11-20T10:00:00")
    real_pull, calls = sync_client.Client.pull, []

    def pull(self):
        calls.append(1)
        if len(calls) > 1:
            real_pull(self)
    monkeypatch.setattr(sync_client.Client, "pull", pull)
    out = sync_client.run()
    assert out["ok"], out
    with db.cursor() as conn:
        rows = _table(conn)
        assert [(r["room"], r["pruefer"]) for r in rows] == [("HS A", "Prof. Dr. Erika Beispiel")], "der spaetere Abruf (PC) gilt"
        m = conn.execute("SELECT remote_id FROM sync_link_map WHERE entity='exam_registrations'").fetchall()
        assert [x[0] for x in m] == [str(sid)]
    srv = _server_regs(app, ipad)
    assert [(x["id"], x["room"]) for x in srv] == [(sid, "HS A")]
    again = sync_client.run()
    assert again["ok"] and again["pushed"] == 0 and again["deleted"] == 0
    _, tombs = ipad_pull(app, ipad)
    assert not [t for t in tombs if t["entity"] == "exam_registrations"]


def test_same_exam_of_two_uni_accounts_stays_apart(tmp_path):
    """Zwei Uni-Konten unter einem StudiNow-Konto (zwei Raeume): dieselbe Pruefungsnummer wird nicht zusammengefuehrt,
    jedes Uni-Konto sieht nur seine Zeile."""
    import hashlib
    import sqlite3

    from app import db, sync
    c = sqlite3.connect(tmp_path / "konto.db", check_same_thread=False)
    c.row_factory = sqlite3.Row
    db._init_db(c)
    ka, kb = hashlib.sha256(b"a").hexdigest(), hashlib.sha256(b"b").hexdigest()
    data = {k: v for k, v in reg().items() if k not in PRIVATE}

    def push(device, key):
        return sync.push(c, device, [{"entity": "exam_registrations", "local_id": -1, "data": data}], [],
                         rooms=sync.resolve_room(c, device, key))
    a = push("ipad-a", ka)["results"][0]
    b = push("ipad-b", kb)["results"][0]
    assert a["status"] == b["status"] == "created" and a["id"] != b["id"]
    a2 = push("iphone-a", ka)["results"][0]
    assert a2["id"] == a["id"], "zweites Geraet desselben Uni-Kontos: dieselbe Zeile"
    seen = sync.changes(c, None, rooms=sync.resolve_room(c, "iphone-a", ka))["changes"]["exam_registrations"]
    assert [r["id"] for r in seen] == [a["id"]]
    c.close()


# ---------------------------------------------------------------- Status ja, Ergebnis nein (20.11.2026)

def test_result_status_rule():
    from app import qis_registrations as Q
    for s in ("BE", "nb", "EN", "bestanden", "Nicht bestanden", "endgültig nicht bestanden", "BE (2. Versuch)"):
        assert Q.is_result_status(s), s
    for s in (None, "", "AN", "angemeldet", "zugelassen", "storniert", "nicht zugelassen", "abgemeldet", "RT", "bestätigt", "entschuldigt"):
        assert not Q.is_result_status(s), s


def test_result_status_stays_on_the_device(two_devices):
    """Der PC liest "BE" (bestanden) fuer 4711: gesendet wird der Status leer, "AN" fuer 4712 geht mit. Aendert das iPad
    die Zeile, bleibt das Ergebnis auf dem PC stehen. Schickt ein Geraet doch ein Ergebnis, speichert der Dienst es nicht."""
    app, ipad = two_devices
    from app import db, qis_registrations as Q, sync_client
    with db.cursor() as conn:
        Q.store(conn, [reg(status="BE"), reg("4712", "Datenbanken", status="AN")], "t")
    assert sync_client.run()["ok"]
    srv = {x["pruefungsnr"]: x for x in _server_regs(app, ipad)}
    assert (srv["4711"]["status"], srv["4712"]["status"]) == (None, "AN")
    assert "BE" not in json.dumps(list(srv.values()))
    # das iPad aendert den Raum (sein eigener Abruf); dabei kaeme auch ein anderer Status, z. B. ein altes "AN"
    r = ipad_push(app, ipad, [{"entity": "exam_registrations", "id": srv["4711"]["id"], "base_version": srv["4711"]["sync_version"],
                               "updated_at": "2099-01-01T00:00:00.000Z", "data": {**srv["4711"], "room": "HS C", "status": "AN"}}])
    assert r["results"][0]["status"] == "applied"
    assert sync_client.run()["ok"]
    with db.cursor() as conn:
        row = next(x for x in _table(conn) if x["pruefungsnr"] == "4711")
        assert (row["room"], row["status"]) == ("HS C", "BE"), "Raum kommt an, das eigene Ergebnis bleibt"
    # ein Geraet schickt doch ein Ergebnis: der Dienst verwirft es
    r = ipad_push(app, ipad, [{"entity": "exam_registrations", "local_id": -5, "updated_at": "2099-01-01T00:00:00.000Z",
                               "data": {k: v for k, v in reg("4799", "Physik", status="endgültig nicht bestanden").items() if k not in PRIVATE}}])
    assert r["results"][0]["status"] == "created"
    assert next(x for x in _server_regs(app, ipad) if x["pruefungsnr"] == "4799")["status"] is None
    from app import sync
    assert sync._row_out("exam_registrations", {"id": 1, "status": "NB", "pruefer": "x"}) == {"id": 1, "status": None}

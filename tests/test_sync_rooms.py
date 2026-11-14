"""Raeume je Uni-Konto im Geraete-Abgleich (14.11.2026, docs/ABGLEICH-UNI-KONTO-2026-11-14.md).

Geraete desselben StudiNow-Kontos teilen nur, wenn sie zum selben Uni-Konto gehoeren. Das Geraet meldet einen Hash
(`uni_key`, aeltere Apple-Apps `studip_user`); der Dienst fuehrt je Uni-Konto einen Raum. Diese Datei ersetzt
test_sync_studip_user.py (12.11.2026: der zweite Stud.IP-Benutzer bekam 409 und war ganz ausgesperrt). Kein Netz,
erfundene Daten."""
import hashlib
import json
import sqlite3

import pytest
from conftest import asgi_call

A = hashlib.sha256(b"studip-user:ada").hexdigest()          # alter Hash (Apple 1.0.3, Builds 34-41)
B = hashlib.sha256(b"studip-user:bob").hexdigest()
KA = hashlib.sha256(b"studinow-uni-konto|1|luh|" + A.encode()).hexdigest()      # neuer Schluessel
KB = hashlib.sha256(b"studinow-uni-konto|1|luh|" + B.encode()).hexdigest()


# ---------------------------------------------------------------- Regeln direkt auf der Konto-Datenbank

@pytest.fixture
def conn(tmp_path):
    from app import db
    c = sqlite3.connect(tmp_path / "konto.db", check_same_thread=False)
    c.row_factory = sqlite3.Row
    c.execute("PRAGMA foreign_keys=ON")
    db._init_db(c)
    c.execute("INSERT INTO courses(id, title, kind, active, created_at) VALUES ('c1', 'Kurs', 'vorlesung', 1, '2026-10-26')")
    c.execute("INSERT INTO files(id, course_id, name, kind, status) VALUES ('f1', 'c1', 'x.pdf', 'pdf', 'neu')")
    c.commit()
    yield c
    c.close()


def _room(conn, device, key=None, user=None):
    from app import sync
    return sync.resolve_room(conn, device, key, user)


def _push(conn, device, items=None, deletes=None, key=None, user=None):
    from app import sync
    return sync.push(conn, device, items or [], deletes or [], rooms=_room(conn, device, key, user))


def _new(conn, device, name, key=None, user=None) -> int:
    out = _push(conn, device, [{"entity": "modules", "local_id": -1, "data": {"name": name}}], key=key, user=user)
    assert out["results"][0]["status"] == "created", out
    return out["results"][0]["id"]


def _pull(conn, device, key=None, user=None, since=None):
    from app import sync
    return sync.changes(conn, since, rooms=_room(conn, device, key, user))


def _names(d) -> list[str]:
    return sorted(m["name"] for m in d["changes"].get("modules", []))


def test_two_uni_accounts_under_one_account_do_not_see_each_other(conn):
    a = _new(conn, "ipad-ada", "Ada-Fach", key=KA, user=A)
    b = _new(conn, "ipad-bob", "Bob-Fach", key=KB, user=B)
    da, db_ = _pull(conn, "ipad-ada", KA, A), _pull(conn, "ipad-bob", KB, B)
    assert _names(da) == ["Ada-Fach"] and _names(db_) == ["Bob-Fach"]
    # die neue App erfaehrt, was nachweislich dem anderen Uni-Konto gehoert, und dass es ein zweites gibt
    assert da["foreign"] == [{"entity": "modules", "id": b}] and db_["foreign"] == [{"entity": "modules", "id": a}]
    assert da["uni"] == {"rooms": 2, "room": True}
    # Kinder bleiben im Raum der Eltern, auch Termine und Lernpakete
    out = _push(conn, "ipad-bob", [{"entity": "course_events", "local_id": -1, "data": {"module_id": b, "title": "Bob-VL", "weekday": 1,
                                                                                         "start_time": "08:00", "end_time": "10:00"}}], key=KB, user=B)
    assert out["results"][0]["status"] == "created"
    assert "course_events" not in _pull(conn, "ipad-ada", KA, A)["changes"]
    assert [e["title"] for e in _pull(conn, "ipad-bob", KB, B)["changes"]["course_events"]] == ["Bob-VL"]


def test_same_uni_key_keeps_sharing_edits_and_deletes(conn):
    m = _new(conn, "ipad-ada", "Mathe", key=KA, user=A)
    first = _pull(conn, "iphone-ada", KA, A)
    assert _names(first) == ["Mathe"] and first["foreign"] == [] and first["uni"]["rooms"] == 1
    out = _push(conn, "iphone-ada", [{"entity": "modules", "id": m, "base_version": 1, "data": {"name": "Mathe I"}}], key=KA, user=A)
    assert out["results"][0]["status"] == "applied"
    assert _names(_pull(conn, "ipad-ada", KA, A, since=first["cursor"])) == ["Mathe I"]
    out = _push(conn, "ipad-ada", deletes=[{"entity": "modules", "id": m}], key=KA, user=A)
    assert out["results"][0]["status"] == "deleted"
    assert [(t["entity"], t["entity_id"]) for t in _pull(conn, "iphone-ada", KA, A, since=first["cursor"])["tombstones"]] == [("modules", str(m))]


def test_old_clients_without_any_hash_behave_exactly_as_before(conn):
    from app import sync
    m = sync.push(conn, "win-1", [{"entity": "modules", "local_id": -1, "data": {"name": "Alt"}}])["results"][0]["id"]
    d = sync.changes(conn, None, rooms=sync.resolve_room(conn, "ipad-alt"))
    assert "Alt" in _names(d) and set(d) == {"cursor", "changes", "tombstones", "has_more"}, "keine neuen Felder fuer alte Clients"
    assert d["changes"] == sync.changes(conn, None)["changes"]
    out = sync.push(conn, "ipad-alt", [{"entity": "modules", "id": m, "base_version": 1, "data": {"name": "Alt 2"}}])
    assert out["results"][0] == {"entity": "modules", "id": m, "status": "applied", "version": 2, "client_won": ["name"]}
    out = sync.push(conn, "ipad-alt", [], [{"entity": "modules", "id": m}])
    assert out["results"][0] == {"entity": "modules", "id": m, "status": "deleted"}
    assert conn.execute("SELECT COUNT(*) FROM modules").fetchone()[0] == 0, "ohne Raum im Konto loescht ein altes Geraet wie bisher"
    assert conn.execute("SELECT COUNT(*) FROM sync_rooms").fetchone()[0] == 0


def test_older_apple_app_with_studip_user_gets_a_room_and_the_new_key_joins_it(conn):
    _new(conn, "ipad-ada", "Von-Ada", user=A)                   # 1.0.3: nur der alte Hash
    _new(conn, "ipad-bob", "Von-Bob", user=B)                   # frueher 409, jetzt eigener Raum
    da = _pull(conn, "ipad-ada", user=A)
    assert _names(da) == ["Von-Ada"] and _names(_pull(conn, "ipad-bob", user=B)) == ["Von-Bob"]
    assert "foreign" not in da and "uni" not in da, "aeltere App: Antwort in der bekannten Form"
    # dasselbe Uni-Konto mit der neuen App: Schluessel und alter Hash zeigen auf denselben Raum
    assert _names(_pull(conn, "iphone-ada", KA, A)) == ["Von-Ada"]
    assert conn.execute("SELECT COUNT(*) FROM sync_rooms").fetchone()[0] == 2
    assert tuple(conn.execute("SELECT uni_key, studip_user FROM sync_rooms ORDER BY id").fetchone()) == (KA, A)
    # und umgekehrt: die aeltere App findet den Raum, den die neue zuerst angelegt hat
    _new(conn, "iphone-bob", "Bob neu", key=KB, user=B)
    assert _names(_pull(conn, "ipad-bob", user=B)) == ["Bob neu", "Von-Bob"]
    assert conn.execute("SELECT COUNT(*) FROM sync_rooms").fetchone()[0] == 2


def test_delete_and_edit_stay_inside_the_room(conn):
    m = _new(conn, "ipad-ada", "Ada-Fach", key=KA, user=A)
    cursor = _pull(conn, "ipad-ada", KA, A)["cursor"]
    # neue App im anderen Raum: `other_room`, nichts geschieht
    out = _push(conn, "iphone-bob", [{"entity": "modules", "id": m, "base_version": 1, "data": {"name": "gekapert"}}],
                [{"entity": "modules", "id": m}], key=KB, user=B)
    assert [r["status"] for r in out["results"]] == ["other_room", "other_room"] and out["conflicts"] == []
    # aeltere App im anderen Raum: dasselbe Ergebnis; sie kennt es nicht und tut nichts (kein Fehler, kein stilles
    # "uebernommen": die Zeile bleibt bei ihr als geaendert stehen)
    out = _push(conn, "ipad-bob", [{"entity": "modules", "id": m, "base_version": 1, "op_id": "ipad-bob.modules.9.2", "data": {"name": "gekapert"}}],
                [{"entity": "modules", "id": m}], user=B)
    assert out["results"] == [{"entity": "modules", "id": m, "status": "other_room"}] * 2 and out["conflicts"] == []
    row = conn.execute("SELECT name, sync_version FROM modules WHERE id=?", (m,)).fetchone()
    assert tuple(row) == ("Ada-Fach", 1), "Zeile unveraendert"
    after = _pull(conn, "ipad-ada", KA, A, since=cursor)
    assert after["tombstones"] == [] and after["changes"] == {}
    assert conn.execute("SELECT COUNT(*) FROM sync_tombstones").fetchone()[0] == 0
    assert conn.execute("SELECT COUNT(*) FROM sync_ops").fetchone()[0] == 0, "abgelehnte Eintraege werden nicht gemerkt"


def test_tombstone_of_another_room_never_reaches_a_device_as_deleted(conn):
    """Bob loescht sein Fach. Ada hat es (aus der Zeit vor den Raeumen) noch verknuepft und aendert es: sie darf
    weder Bobs Tombstone als `deleted` bekommen (das loeschte ihre Zeile) noch die Zeile im Dienst wiederherstellen."""
    b = _new(conn, "ipad-bob", "Bob-Fach", key=KB, user=B)
    _room(conn, "ipad-ada", KA, A)
    assert _push(conn, "ipad-bob", deletes=[{"entity": "modules", "id": b}], key=KB, user=B)["results"][0]["status"] == "deleted"
    out = _push(conn, "ipad-ada", [{"entity": "modules", "id": b, "base_version": 1, "updated_at": "2000-01-01T00:00:00.000Z",
                                    "data": {"name": "alt"}}], key=KA, user=A)
    assert out["results"][0]["status"] == "other_room"
    assert conn.execute("SELECT COUNT(*) FROM modules").fetchone()[0] == 0
    assert _pull(conn, "ipad-ada", KA, A)["tombstones"] == []
    assert len(_pull(conn, "ipad-bob", KB, B)["tombstones"]) == 1


def test_legacy_rows_are_assigned_when_their_device_reports_its_uni_account(conn):
    """Altbestand: zwei Geraete haben ohne Hash gesendet. Wer dazugehoert, weiss der Dienst erst, wenn das
    Ursprungsgeraet sich meldet; bis dahin geht die Zeile an kein Geraet mit Raum, und niemand loescht sie."""
    from app import sync
    m_ada = sync.push(conn, "ipad-ada", [{"entity": "modules", "local_id": -1, "data": {"name": "Ada alt"}}])["results"][0]["id"]
    m_bob = sync.push(conn, "ipad-bob", [{"entity": "modules", "local_id": -1, "data": {"name": "Bob alt"}}])["results"][0]["id"]
    assert _names(sync.changes(conn, None)) == ["Ada alt", "Bob alt"], "so entstand die Vermischung"
    # Adas iPhone meldet sich mit Schluessel: es hat nichts davon angelegt
    first = _pull(conn, "iphone-ada", KA, A)
    assert _names(first) == [] and first["foreign"] == []
    # ein Geraet mit Raum kann eine Zeile unbekannter Herkunft weder aendern noch loeschen: "noch offen", spaeter erneut
    change = [{"entity": "modules", "id": m_ada, "base_version": 1, "op_id": "iphone-ada.modules.7.2", "data": {"name": "Ada alt, am iPhone umbenannt"}}]
    out = _push(conn, "iphone-ada", change + [{"entity": "modules", "id": m_bob, "base_version": 1, "data": {"name": "x"}}],
                [{"entity": "modules", "id": m_bob}], key=KA, user=A)
    assert [r["status"] for r in out["results"]] == ["room_pending", "room_pending", "room_pending"]
    assert [r[0] for r in conn.execute("SELECT name FROM modules ORDER BY id")] == ["Ada alt", "Bob alt"]
    # Adas iPad meldet seinen Schluessel: seine Zeile gehoert jetzt zum Raum; das iPhone holt sie nach (Cursor ist weiter)
    assert _names(_pull(conn, "ipad-ada", KA, A)) == ["Ada alt"]
    later = _pull(conn, "iphone-ada", KA, A, since=first["cursor"])
    assert _names(later) == ["Ada alt"] and later["foreign"] == []
    # die Aenderung des iPhones von vorhin ging nicht verloren: derselbe Eintrag noch einmal gelingt jetzt
    out = _push(conn, "iphone-ada", change, key=KA, user=A)
    assert out["results"][0]["status"] == "applied" and "repeated" not in out["results"][0]
    later = _pull(conn, "ipad-ada", KA, A, since=later["cursor"])
    assert _names(later) == ["Ada alt, am iPhone umbenannt"]
    # Bobs Geraet meldet sich: seine Zeile ist nun nachweislich fremd
    assert _names(_pull(conn, "ipad-bob", user=B)) == ["Bob alt"]
    last = _pull(conn, "iphone-ada", KA, A, since=later["cursor"])
    assert last["changes"] == {} and last["foreign"] == [{"entity": "modules", "id": m_bob}]
    assert {m_ada, m_bob} == {r[0] for r in conn.execute("SELECT id FROM modules")}, "nichts geloescht"


def test_device_without_hash_in_an_account_with_rooms(conn):
    from app import sync
    old = sync.push(conn, "win-alt", [{"entity": "modules", "local_id": -1, "data": {"name": "Windows alt"}}])["results"][0]["id"]
    a = _new(conn, "ipad-ada", "Ada-Fach", key=KA, user=A)
    # ein Raum: das alte Geraet sieht weiter alles und darf aendern, aber nicht in den Raum hinein loeschen
    assert _names(sync.changes(conn, None, rooms=_room(conn, "win-alt"))) == ["Ada-Fach", "Windows alt"]
    out = sync.push(conn, "win-alt", [{"entity": "modules", "id": a, "base_version": 1, "data": {"name": "Ada-Fach I"}}],
                    [{"entity": "modules", "id": a}])
    assert [r["status"] for r in out["results"]] == ["applied", "room_pending"]
    assert conn.execute("SELECT name FROM modules WHERE id=?", (a,)).fetchone()[0] == "Ada-Fach I", "geaendert, nicht geloescht"
    # was das alte Geraet angelegt hat, geht an kein Geraet mit Raum (Herkunft unbekannt)
    assert _names(_pull(conn, "ipad-ada", KA, A)) == ["Ada-Fach I"]
    # zwei Raeume: das alte Geraet sieht und aendert nur noch Zeilen ohne Raum
    _new(conn, "ipad-bob", "Bob-Fach", key=KB, user=B)
    assert _names(sync.changes(conn, None, rooms=_room(conn, "win-alt"))) == ["Windows alt"]
    out = sync.push(conn, "win-alt", [{"entity": "modules", "id": a, "base_version": 2, "data": {"name": "nein"}},
                                      {"entity": "modules", "id": old, "base_version": 1, "data": {"name": "Windows alt 2"}}])
    assert [r["status"] for r in out["results"]] == ["room_pending", "applied"]
    assert [r[0] for r in conn.execute("SELECT name FROM modules ORDER BY id")] == ["Windows alt 2", "Ada-Fach I", "Bob-Fach"]
    # das eigene darf es weiter loeschen
    assert sync.push(conn, "win-alt", [], [{"entity": "modules", "id": old}])["results"][0]["status"] == "deleted"
    assert conn.execute("SELECT COUNT(*) FROM modules WHERE id=?", (old,)).fetchone()[0] == 0


def test_rows_from_the_web_go_to_the_only_room(conn):
    conn.execute("INSERT INTO modules(name, created_at) VALUES ('Im Browser angelegt', '2026-11-14')")
    web = conn.execute("SELECT id FROM modules").fetchone()[0]
    first = _pull(conn, "ipad-ada", KA, A)
    assert _names(first) == ["Im Browser angelegt"]
    # die erste Aenderung eines Geraets ordnet die Zeile seinem Raum zu
    out = _push(conn, "ipad-ada", [{"entity": "modules", "id": web, "base_version": 1, "data": {"name": "Im Browser, am iPad umbenannt"}}], key=KA, user=A)
    assert out["results"][0]["status"] == "applied"
    assert _push(conn, "ipad-ada", deletes=[{"entity": "modules", "id": web}], key=KA, user=A)["results"][0]["status"] == "deleted"
    # zwei Raeume: eine Web-Zeile gehoert zu keinem; kein Geraet mit Raum bekommt sie oder loescht sie
    _room(conn, "ipad-bob", KB, B)
    conn.execute("INSERT INTO modules(name, created_at) VALUES ('Web bei zwei Uni-Konten', '2026-11-14')")
    web2 = conn.execute("SELECT id FROM modules WHERE name LIKE 'Web bei%'").fetchone()[0]
    assert _names(_pull(conn, "ipad-ada", KA, A, since=first["cursor"])) == [] and _names(_pull(conn, "ipad-bob", KB, B)) == []
    assert _push(conn, "ipad-bob", deletes=[{"entity": "modules", "id": web2}], key=KB, user=B)["results"][0]["status"] == "room_pending"
    assert conn.execute("SELECT COUNT(*) FROM modules WHERE id=?", (web2,)).fetchone()[0] == 1


def test_settings_and_notes_with_the_same_key_stay_with_the_first_room(conn):
    out = _push(conn, "ipad-ada", [{"entity": "settings", "local_id": "lieblingsfarbe", "data": {"value": "blau"}},
                                   {"entity": "annotations", "id": "f1", "base_version": None, "data": {"note": "Ada"}}], key=KA, user=A)
    assert [r["status"] for r in out["results"]] == ["applied", "applied"]
    out = _push(conn, "ipad-bob", [{"entity": "settings", "local_id": "lieblingsfarbe", "data": {"value": "rot"}},
                                   {"entity": "annotations", "id": "f1", "base_version": None, "data": {"note": "Bob"}}], key=KB, user=B)
    assert [r["status"] for r in out["results"]] == ["other_room", "other_room"]
    assert conn.execute("SELECT value FROM settings WHERE key='lieblingsfarbe'").fetchone()[0] == "blau"
    assert json.loads(conn.execute("SELECT data FROM annotations WHERE file_id='f1'").fetchone()[0]) == {"note": "Ada"}
    d = _pull(conn, "ipad-bob", KB, B)
    assert "annotations" not in d["changes"] and all(s["key"] != "lieblingsfarbe" for s in d["changes"].get("settings", []))
    da = _pull(conn, "iphone-ada", KA, A)
    assert [s["value"] for s in da["changes"]["settings"] if s["key"] == "lieblingsfarbe"] == ["blau"]
    assert all(s["key"] != "studip_user_hash" for s in da["changes"]["settings"]), "bleibt privat"


def test_delete_is_refused_while_rows_of_another_room_hang_on_the_row(conn):
    """Altbestand: zwei Uni-Konten hatten dasselbe Fach, der Dienst hat es als eine Zeile gefuehrt. Loescht ein Raum
    sein Fach, naehme ON DELETE CASCADE dem anderen das Lernziel weg."""
    from app import sync
    m = sync.push(conn, "ipad-ada", [{"entity": "modules", "local_id": -1, "data": {"name": "Mathe"}}])["results"][0]["id"]
    out = sync.push(conn, "ipad-bob", [{"entity": "study_goals", "local_id": -1, "data": {"module_id": m, "target_grade": 2.0}}])
    assert out["results"][0]["status"] == "created", out
    _room(conn, "ipad-bob", KB, B)
    out = _push(conn, "ipad-ada", deletes=[{"entity": "modules", "id": m}], key=KA, user=A)
    assert out["results"][0]["status"] == "other_room"
    assert conn.execute("SELECT COUNT(*) FROM modules").fetchone()[0] == 1 and conn.execute("SELECT COUNT(*) FROM study_goals").fetchone()[0] == 1


def test_duplicate_subjects_are_merged_only_inside_a_room(conn):
    from app import study
    a = _new(conn, "ipad-ada", "Mathematik I", key=KA, user=A)
    b = _new(conn, "ipad-bob", "Mathematik I", key=KB, user=B)
    assert study.merge_duplicate_modules(conn) == 0, "zwei Uni-Konten, dasselbe Fach: zwei Zeilen"
    a2 = _new(conn, "iphone-ada", "Mathematik I", key=KA, user=A)
    assert study.merge_duplicate_modules(conn) == 1
    assert {r[0] for r in conn.execute("SELECT id FROM modules")} == {a, b} and a2 not in (a, b)


def test_pages_respect_the_room_and_the_late_assignment(conn):
    from app import sync
    ids = [sync.push(conn, "ipad-ada", [{"entity": "modules", "local_id": -1, "data": {"name": f"M{i}"}}])["results"][0]["id"] for i in range(5)]
    _new(conn, "ipad-bob", "Bob-Fach", key=KB, user=B)
    seen, cursor = [], None
    _room(conn, "ipad-ada", KA, A)                               # ordnet die fuenf alten Zeilen in einem Zug zu (ein Zeitstempel)
    for _ in range(10):
        d = sync.changes(conn, cursor, limit=2, rooms=_room(conn, "iphone-ada", KA, A))
        seen += [m["id"] for m in d["changes"].get("modules", [])]
        cursor = d["cursor"]
        if not d["has_more"]:
            break
    assert sorted(seen) == ids and len(seen) == len(set(seen))
    assert all("_ts" not in m for m in d["changes"].get("modules", []))


# ---------------------------------------------------------------- Migration

def test_migration_on_an_old_database_is_repeatable_and_touches_no_row(tmp_path):
    """Konto-Datenbank von vor dem 14.11.2026: Zeilen mit `sync_device`, Ergebnisse in `sync_ops`, keine Raum-Tabellen."""
    from app import db, sync
    c = sqlite3.connect(tmp_path / "alt.db")
    c.row_factory = sqlite3.Row
    db._init_db(c)
    for t in ("sync_rooms", "sync_devices", "sync_row_room"):
        c.execute(f"DROP TABLE {t}")
    out = sync.push(c, "ipad-ada", [{"entity": "modules", "local_id": -1, "op_id": "ipad-ada.modules.1.1", "data": {"name": "Ada alt"}},
                                    {"entity": "modules", "local_id": -2, "data": {"name": "ohne op_id"}}])
    m1, m2 = (r["id"] for r in out["results"])
    # ein zweites Geraet hat Adas Zeile zuletzt geaendert (so stand `sync_device` am echten Konto)
    sync.push(c, "ipad-bob", [{"entity": "modules", "id": m1, "base_version": 1, "data": {"active": 0}}])
    c.execute("INSERT INTO modules(name, created_at) VALUES ('im Browser', '2026-11-01')")
    c.execute("INSERT INTO sync_ops(op_id, entity, result, device, created_at) VALUES ('kaputt-0001', 'modules', '{', 'x', '2026-11-01')")
    c.commit()
    before = [tuple(r) for r in c.execute("SELECT id, name, sync_version, sync_updated_at, sync_device FROM modules ORDER BY id")]
    assert not c.execute("SELECT 1 FROM sqlite_master WHERE name='sync_row_room'").fetchone()
    for _ in range(3):                                           # wiederholbar
        sync.ensure_schema(c)
    assert [tuple(r) for r in c.execute("SELECT id, name, sync_version, sync_updated_at, sync_device FROM modules ORDER BY id")] == before
    origin = dict(c.execute("SELECT entity_id, origin FROM sync_row_room WHERE entity='modules'").fetchall())
    assert origin == {str(m1): "ipad-ada", str(m2): "ipad-ada"}, "wer angelegt hat (sync_ops) geht vor dem letzten Schreiber"
    assert c.execute("SELECT COUNT(*) FROM sync_row_room WHERE room IS NOT NULL").fetchone()[0] == 0
    assert c.execute("SELECT COUNT(*) FROM sync_tombstones").fetchone()[0] == 0
    # nach dem Marker laeuft die Zuordnung nicht noch einmal (eine spaetere Aenderung verfaelscht die Herkunft nicht)
    sync.push(c, "ipad-bob", [{"entity": "modules", "id": m2, "base_version": 1, "data": {"active": 0}}])
    sync.ensure_schema(c)
    assert c.execute("SELECT origin FROM sync_row_room WHERE entity='modules' AND entity_id=?", (str(m2),)).fetchone()[0] == "ipad-ada"
    c.close()


def test_migration_survives_missing_tables(tmp_path):
    """Halb angelegte oder sehr alte Datenbank (am 14.11.2026 scheiterte eine Migration an `no such table: users`)."""
    from app import sync
    empty = sqlite3.connect(tmp_path / "leer.db")
    sync.ensure_schema(empty)
    sync.ensure_schema(empty)
    assert sync.Rooms(empty).ready and sync.resolve_room(empty, "ipad", KA, A).room == 1
    empty.close()
    half = sqlite3.connect(tmp_path / "halb.db")
    half.execute("CREATE TABLE modules (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, semester TEXT)")
    half.execute("CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT)")
    half.execute("INSERT INTO modules(name) VALUES ('uralt')")
    half.execute("CREATE TABLE sync_ops (op_id TEXT PRIMARY KEY, entity TEXT NOT NULL, result TEXT NOT NULL, device TEXT, created_at TEXT NOT NULL)")
    half.execute("INSERT INTO sync_ops VALUES ('op-000001', 'study_packages', '{\"id\": 3, \"status\": \"created\"}', 'ipad', '2026-11-01')")
    half.execute("INSERT INTO sync_ops VALUES ('op-000002', 'modules', '{\"id\": 1, \"status\": \"created\"}', 'ipad', '2026-11-01')")
    sync.ensure_schema(half)
    sync.ensure_schema(half)
    assert half.execute("SELECT origin FROM sync_row_room WHERE entity='modules'").fetchone()[0] == "ipad"
    assert half.execute("SELECT COUNT(*) FROM sync_row_room WHERE entity='study_packages'").fetchone()[0] == 0, "Tabelle fehlt: uebersprungen"
    half.close()
    # eine Datenbank ganz ohne Raum-Tabellen (Schema-Arbeit noch nicht gelaufen): alles wie bisher, kein Fehler
    raw = sqlite3.connect(tmp_path / "roh.db")
    raw.row_factory = sqlite3.Row
    ctx = sync.resolve_room(raw, "ipad", KA, A)
    assert not ctx.ready and ctx.room is None and ctx.legacy and ctx.deny_update("modules", 1, "x") is None and ctx.deny_delete("modules", 1) is None
    raw.close()


# ---------------------------------------------------------------- ueber die Schnittstelle des Dienstes

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


def _api_push(app, h, device, name, **hashes):
    body = {"device_id": device, "items": [{"entity": "modules", "local_id": -1, "data": {"name": name}}], **hashes}
    st, _, b = asgi_call(app, "POST", "/api/sync/push", headers=h, body=json.dumps(body))
    return st, json.loads(b)


def _api_changes(app, h, device, **hashes):
    q = "".join(f"&{k}={v}" for k, v in hashes.items())
    st, _, b = asgi_call(app, "GET", f"/api/sync/changes?device_id={device}{q}", headers=h)
    return st, json.loads(b)


def test_api_second_uni_account_gets_its_own_room_instead_of_409(hosted):
    app, h = hosted
    st, out = _api_push(app, h, "ipad-ada", "Von-Ada", studip_user=A)
    assert st == 200 and out["results"][0]["status"] == "created"
    # zweites Geraet mit anderem Stud.IP-Benutzer (1.0.3): vom 12. bis 14.11.2026 409 studip_user_mismatch
    st, d = _api_changes(app, h, "ipad-bob", studip_user=B)
    assert st == 200 and d["changes"].get("modules") is None
    st, out = _api_push(app, h, "ipad-bob", "Von-Bob", studip_user=B)
    assert st == 200 and out["results"][0]["status"] == "created"
    assert [m["name"] for m in _api_changes(app, h, "ipad-ada", studip_user=A)[1]["changes"]["modules"]] == ["Von-Ada"]
    # neue App: Schluessel in Abruf und Sendung
    st, d = _api_changes(app, h, "iphone-bob", studip_user=B, uni_key=KB)
    assert st == 200 and [m["name"] for m in d["changes"]["modules"]] == ["Von-Bob"] and d["uni"]["rooms"] == 2
    assert [f["entity"] for f in d["foreign"]] == ["modules"]
    st, out = _api_push(app, h, "iphone-bob", "Bob am iPhone", studip_user=B, uni_key=KB)
    assert st == 200
    assert [m["name"] for m in _api_changes(app, h, "ipad-ada", studip_user=A)[1]["changes"]["modules"]] == ["Von-Ada"]


def test_api_without_hash_stays_as_it_was(hosted):
    app, h = hosted
    assert _api_push(app, h, "win-1", "Ohne-Angabe")[0] == 200
    st, d = _api_changes(app, h, "win-2")
    assert st == 200 and [m["name"] for m in d["changes"]["modules"]] == ["Ohne-Angabe"]
    assert set(d) == {"cursor", "changes", "tombstones", "has_more"}


def test_api_invalid_values_are_rejected_and_remember_nothing(hosted):
    app, h = hosted
    st, d = _api_changes(app, h, "ipad", studip_user="nicht-hex")
    assert (st, d["code"]) == (400, "studip_user_invalid")
    st, d = _api_changes(app, h, "ipad", uni_key="auch-nicht")
    assert (st, d["code"]) == (400, "uni_key_invalid")
    st, d = _api_push(app, h, "ipad", "x", uni_key=["liste"])
    assert (st, d["code"]) == (400, "uni_key_invalid")
    st, d = _api_changes(app, h, "ipad", uni_key=KA)
    assert st == 200 and d["uni"] == {"rooms": 1, "room": True}, "kaputte Werte haben keinen Raum angelegt"


def test_api_private_hash_cannot_be_set_by_devices(hosted):
    app, h = hosted
    body = {"device_id": "ipad-x", "uni_key": KA, "items": [{"entity": "settings", "local_id": "studip_user_hash", "data": {"value": B}}],
            "deletes": [{"entity": "settings", "id": "studip_user_hash"}]}
    st, _, b = asgi_call(app, "POST", "/api/sync/push", headers=h, body=json.dumps(body))
    assert st == 200 and [r["status"] for r in json.loads(b)["results"]] == ["ignored", "ignored"]
    asgi_call(app, "PUT", "/api/settings", headers=h, body=json.dumps({"studip_user_hash": B}))
    st, d = _api_changes(app, h, "ipad-x", uni_key=KA)
    assert st == 200 and all(s["key"] != "studip_user_hash" for s in d["changes"].get("settings", []))

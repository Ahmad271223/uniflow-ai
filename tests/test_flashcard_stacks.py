"""Geschlossene Stapel und nachtraegliches Bearbeiten (Entscheidungen vom 04.11.2026, docs/KARTEIKARTEN-STAPEL-2026-11-04.md):
Stapel anlegen, umbenennen, verschieben, loeschen (Karten mit oder ohne Umzug), Ueben nur in einem Stapel
(`?stack_id=`), Zaehler je Stapel, Karte bearbeiten ohne Lernstandverlust, Bestand ohne Stapel bekommt Stapel
(Migration), Loeschen eines Dokuments raeumt leere Stapel weg, Stapel im Export und im Geraete-Abgleich."""
import json
import sqlite3

from conftest import asgi_call


def _call(app, method, path, body=None, status=200):
    st, _, raw = asgi_call(app, method, path, body=json.dumps(body) if body is not None else None)
    assert st == status, f"{method} {path}: {st} {raw[:300]}"
    return json.loads(raw) if raw else None


def _clean():
    from app import db
    with db.cursor() as conn:
        conn.execute("DELETE FROM flashcards")
        conn.execute("DELETE FROM flashcard_stacks")
        conn.execute("INSERT OR IGNORE INTO courses(id, title, subject, kind, created_at) VALUES ('st-k1', 'Testmathe', 'Testmathe', 'vorlesung', '2026-10-01')")
        conn.execute("INSERT OR IGNORE INTO courses(id, title, subject, kind, created_at) VALUES ('st-k2', 'Testphysik', 'Testphysik', 'vorlesung', '2026-10-01')")
        conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, title, kind, status) VALUES ('st-f1', 'st-k1', 'VL01.pdf', 'Folgen', 'pdf', 'neu')")
        conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, kind, status) VALUES ('st-f2', 'st-k2', 'Physik.pdf', 'pdf', 'neu')")


def test_stack_crud_and_counts_per_stack(app):
    _clean()
    a = _call(app, "POST", "/api/flashcard-stacks", {"name": " Klausur ", "subject": "Testmathe"})
    assert a["name"] == "Klausur" and a["subject"] == "Testmathe" and a["cards"] == 0 and a["due"] == 0 and a["last_practised"] is None
    b = _call(app, "POST", "/api/flashcard-stacks", {"name": "Aus Skript", "file_id": "st-f1"})
    assert b["subject"] == "Testmathe" and b["file_id"] == "st-f1" and b["file_name"] == "VL01.pdf", "Fach aus dem Kurs des Dokuments"
    assert _call(app, "POST", "/api/flashcard-stacks", {"name": ""}, status=422)["detail"] == "Name des Stapels fehlt"
    assert _call(app, "POST", "/api/flashcard-stacks", {"name": "x", "file_id": "gibtsnicht"}, status=404)["detail"] == "Dokument nicht gefunden"
    assert _call(app, "POST", "/api/flashcard-stacks", {"name": "x", "subject": 1}, status=422)["detail"].startswith("subject")
    r = _call(app, "POST", "/api/flashcards", {"cards": [{"question": "Q1", "answer": "A1"}, {"question": "Q2", "answer": "A2"}], "stack_id": a["id"]})
    assert r["count"] == 2 and r["stack_id"] == a["id"]
    _call(app, "POST", "/api/flashcards", {"cards": [{"question": "Q3", "answer": "A3"}], "file_id": "st-f1", "stack_id": b["id"]})
    assert _call(app, "POST", "/api/flashcards", {"cards": [{"question": "x", "answer": "y"}], "stack_id": 9999}, status=404)["detail"] == "Stapel nicht gefunden"
    stacks = {s["id"]: s for s in _call(app, "GET", "/api/flashcard-stacks")}
    assert (stacks[a["id"]]["cards"], stacks[a["id"]]["due"]) == (2, 2) and (stacks[b["id"]]["cards"], stacks[b["id"]]["due"]) == (1, 1)
    # umbenennen, in ein anderes Modul verschieben (Karten folgen), Dokument loesen
    p = _call(app, "PATCH", f"/api/flashcard-stacks/{a['id']}", {"name": "Klausur 2", "subject": "Testphysik"})
    assert p["name"] == "Klausur 2" and p["subject"] == "Testphysik" and p["cards"] == 2
    assert {c["subject"] for c in _call(app, "GET", f"/api/flashcards?stack_id={a['id']}")} == {"Testphysik"}
    assert _call(app, "PATCH", f"/api/flashcard-stacks/{b['id']}", {"file_id": None})["file_id"] is None
    assert _call(app, "PATCH", "/api/flashcard-stacks/9999", {"name": "x"}, status=404)["detail"] == "Stapel nicht gefunden"
    assert _call(app, "PATCH", f"/api/flashcard-stacks/{a['id']}", {"name": "  "}, status=422)


def test_practice_is_closed_per_stack_and_touches_last_practised(app):
    _clean()
    a = _call(app, "POST", "/api/flashcard-stacks", {"name": "A"})["id"]
    b = _call(app, "POST", "/api/flashcard-stacks", {"name": "B"})["id"]
    _call(app, "POST", "/api/flashcards", {"cards": [{"question": "A1", "answer": "a"}, {"question": "A2", "answer": "a"}], "stack_id": a})
    _call(app, "POST", "/api/flashcards", {"cards": [{"question": "B1", "answer": "b"}], "stack_id": b})
    due_a = _call(app, "GET", f"/api/flashcards?stack_id={a}&due=1")
    assert {c["question"] for c in due_a} == {"A1", "A2"} and all(c["stack_name"] == "A" for c in due_a), "nur dieser Stapel wird abgefragt"
    assert [c["question"] for c in _call(app, "GET", f"/api/flashcards?stack_id={b}&due=true")] == ["B1"]
    assert len(_call(app, "GET", "/api/flashcards?due=true")) == 3, "ohne Stapel: Gesamtzaehler"
    assert _call(app, "GET", "/api/flashcards?stack_id=abc", status=422)
    _call(app, "POST", f"/api/flashcards/{due_a[0]['id']}/review", {"correct": True})
    stacks = {s["id"]: s for s in _call(app, "GET", "/api/flashcard-stacks")}
    assert stacks[a]["last_practised"] and stacks[b]["last_practised"] is None
    assert stacks[a]["due"] == 1 and stacks[b]["due"] == 1
    _call(app, "PATCH", f"/api/flashcards/{_call(app, 'GET', f'/api/flashcards?stack_id={b}')[0]['id']}", {"last_result": "right"})
    assert {s["id"]: s for s in _call(app, "GET", "/api/flashcard-stacks")}[b]["last_practised"], "Trainer zaehlt als Ueben"


def test_edit_keeps_leitner_box_and_due(app):
    _clean()
    s = _call(app, "POST", "/api/flashcard-stacks", {"name": "S", "subject": "Testmathe"})["id"]
    t = _call(app, "POST", "/api/flashcard-stacks", {"name": "T", "subject": "Testphysik"})["id"]
    cid = _call(app, "GET", "/api/flashcards?stack_id=%d" % s) or None
    _call(app, "POST", "/api/flashcards", {"cards": [{"question": "Alt", "answer": "alt"}], "stack_id": s})
    cid = _call(app, "GET", f"/api/flashcards?stack_id={s}")[0]["id"]
    for _ in range(2):
        _call(app, "POST", f"/api/flashcards/{cid}/review", {"correct": True})
    before = _call(app, "GET", f"/api/flashcards?stack_id={s}")[0]
    assert before["box"] == 3
    c = _call(app, "PATCH", f"/api/flashcards/{cid}", {"question": " Neu ", "answer": "neu"})
    assert (c["question"], c["answer"], c["box"], c["due"]) == ("Neu", "neu", 3, before["due"]), "Bearbeiten setzt das Fach nicht zurueck"
    c = _call(app, "PATCH", f"/api/flashcards/{cid}", {"stack_id": t})
    assert c["stack_id"] == t and c["subject"] == "Testphysik" and c["box"] == 3, "Stapelwechsel: Fach des Stapels"
    c = _call(app, "PATCH", f"/api/flashcards/{cid}", {"subject": "Eigen"})
    assert c["subject"] == "Eigen"
    assert _call(app, "PATCH", f"/api/flashcards/{cid}", {"question": ""}, status=422)["detail"] == "Frage und Antwort dürfen nicht leer sein"
    assert _call(app, "PATCH", f"/api/flashcards/{cid}", {"stack_id": "x"}, status=422)["detail"] == "stack_id: ganze Zahl erwartet"
    assert _call(app, "PATCH", f"/api/flashcards/{cid}", {"stack_id": 9999}, status=404)["detail"] == "Stapel nicht gefunden"
    assert _call(app, "PATCH", "/api/flashcards/9999", {"question": "x"}, status=404)["detail"] == "Karteikarte nicht gefunden"
    assert _call(app, "GET", f"/api/flashcards?stack_id={cid and t}")[0]["box"] == 3


def test_delete_stack_with_move_or_with_cards(app):
    _clean()
    a = _call(app, "POST", "/api/flashcard-stacks", {"name": "A", "subject": "Testmathe"})["id"]
    b = _call(app, "POST", "/api/flashcard-stacks", {"name": "B", "subject": "Testphysik"})["id"]
    _call(app, "POST", "/api/flashcards", {"cards": [{"question": "A1", "answer": "a"}, {"question": "A2", "answer": "a"}], "stack_id": a})
    cid = _call(app, "GET", f"/api/flashcards?stack_id={a}")[0]["id"]
    _call(app, "POST", f"/api/flashcards/{cid}/review", {"correct": True})
    assert _call(app, "DELETE", f"/api/flashcard-stacks/{a}?move_to={a}", status=422)
    assert _call(app, "DELETE", f"/api/flashcard-stacks/{a}?move_to=9999", status=404)["detail"] == "Zielstapel nicht gefunden"
    r = _call(app, "DELETE", f"/api/flashcard-stacks/{a}?move_to={b}")
    assert r == {"ok": True, "moved": 2, "deleted": 0}
    moved = _call(app, "GET", f"/api/flashcards?stack_id={b}")
    assert {c["subject"] for c in moved} == {"Testphysik"} and {c["box"] for c in moved} == {1, 2}, "Lernstand zieht mit"
    assert [s["id"] for s in _call(app, "GET", "/api/flashcard-stacks")] == [b]
    assert _call(app, "DELETE", f"/api/flashcard-stacks/{b}") == {"ok": True, "moved": 0, "deleted": 2}
    assert _call(app, "GET", "/api/flashcards") == [] and _call(app, "GET", "/api/flashcard-stacks") == []
    assert _call(app, "DELETE", f"/api/flashcard-stacks/{b}", status=404)["detail"] == "Stapel nicht gefunden"


def test_existing_cards_get_stacks_like_the_migration(app, tmp_path, monkeypatch):
    from app import db
    _clean()
    with db.cursor() as conn:
        for fid, subject, q in (("st-f1", "Testmathe", "Mit Datei"), ("st-f1", "Testmathe", "Mit Datei 2"), (None, "Testmathe", "Nur Fach"),
                                (None, None, "Ohne alles"), ("", "", "Leer")):
            conn.execute("INSERT INTO flashcards(file_id, subject, question, answer, created_at, box, due) VALUES (?,?,?,?,'2026-10-20T08:00:00',4,'2026-12-01')",
                         (fid, subject, q, "a"))
    stacks = {(s["name"], s["subject"], s["file_id"]): s for s in _call(app, "GET", "/api/flashcard-stacks")}
    assert set(stacks) == {("Folgen", "Testmathe", "st-f1"), ("Allgemein", "Testmathe", None), ("Ohne Modul", None, None)}
    assert stacks[("Folgen", "Testmathe", "st-f1")]["cards"] == 2 and stacks[("Ohne Modul", None, None)]["cards"] == 2
    cards = _call(app, "GET", "/api/flashcards")
    assert all(c["stack_id"] for c in cards) and {c["box"] for c in cards} == {4}, "Lernstand bleibt"
    # alte Datenbank ohne die Spalte: init_db legt Stapel an, ein zweiter Start aendert nichts
    path = tmp_path / "alt.db"
    with sqlite3.connect(path) as c:
        c.executescript("""CREATE TABLE courses (id TEXT PRIMARY KEY, title TEXT NOT NULL, number TEXT, semester TEXT, subject TEXT, kind TEXT,
                                                active INTEGER DEFAULT 1, test_minutes INTEGER DEFAULT 90, created_at TEXT);
                           CREATE TABLE files (id TEXT PRIMARY KEY, course_id TEXT, name TEXT NOT NULL, size INTEGER, mime TEXT, author TEXT,
                                              chdate INTEGER, download_url TEXT, local_path TEXT, downloaded_at TEXT, first_seen TEXT, status TEXT, seen_by_user INTEGER DEFAULT 0);
                           CREATE TABLE flashcards (id INTEGER PRIMARY KEY AUTOINCREMENT, file_id TEXT, subject TEXT, question TEXT NOT NULL,
                                                    answer TEXT NOT NULL, created_at TEXT, box INTEGER DEFAULT 1, due TEXT);
                           CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT);
                           INSERT INTO courses(id, title, subject) VALUES ('k', 'Kurs', 'Fach A');
                           INSERT INTO files(id, course_id, name) VALUES ('f', 'k', 'Skript.pdf');
                           INSERT INTO flashcards(file_id, subject, question, answer, box) VALUES ('f', 'Fach A', 'q1', 'a', 2);
                           INSERT INTO flashcards(subject, question, answer, box) VALUES ('Fach B', 'q2', 'a', 3);
                           INSERT INTO flashcards(question, answer, box) VALUES ('q3', 'a', 5);""")
    saved = db.DB_PATH
    monkeypatch.setattr(db, "DB_PATH", path)
    db.init_db()
    db.init_db()
    monkeypatch.setattr(db, "DB_PATH", saved)
    c = sqlite3.connect(path)
    assert c.execute("SELECT name, subject, file_id FROM flashcard_stacks ORDER BY name").fetchall() == \
        [("Allgemein", "Fach B", None), ("Ohne Modul", None, None), ("Skript.pdf", "Fach A", "f")]
    assert c.execute("""SELECT fc.question, s.name, fc.box FROM flashcards fc JOIN flashcard_stacks s ON s.id=fc.stack_id
                        ORDER BY fc.id""").fetchall() == [("q1", "Skript.pdf", 2), ("q2", "Allgemein", 3), ("q3", "Ohne Modul", 5)]


def test_deleting_a_document_forever_removes_its_empty_stack(app):
    from app import db
    _clean()
    with db.cursor() as conn:
        conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, kind, status) VALUES ('st-own', '__user__', 'Eigen.pdf', 'pdf', 'neu')")
    r = _call(app, "POST", "/api/flashcards", {"cards": [{"question": "Q", "answer": "A"}], "file_id": "st-own"})
    keep = _call(app, "POST", "/api/flashcard-stacks", {"name": "Bleibt", "file_id": "st-own"})["id"]
    _call(app, "POST", "/api/flashcards", {"cards": [{"question": "Q2", "answer": "A"}], "stack_id": keep})
    _call(app, "PATCH", "/api/library/files/st-own", {"delete_forever": True})
    stacks = {s["id"]: s for s in _call(app, "GET", "/api/flashcard-stacks")}
    assert r["stack_id"] not in stacks, "leerer Dokumentstapel ist weg"
    assert stacks[keep]["file_id"] is None and stacks[keep]["cards"] == 1, "Stapel mit anderen Karten bleibt ohne Quelle"


def test_stacks_are_synced_and_exported():
    from app import sync, sync_client
    assert list(sync.ENTITIES).index("flashcard_stacks") < list(sync.ENTITIES).index("flashcards"), "Eltern vor Kindern"
    assert sync.ENTITIES["flashcards"]["fk"] == {"stack_id": "flashcard_stacks"}
    assert sync_client.natural_key("flashcard_stacks", {"name": "A", "subject": "B", "file_id": None}) == ("a", "b", "")
    from app import account_export
    assert "flashcard_stacks" in account_export.README, "Export (ganze Datenbank) nennt die Stapel"


def test_week_and_kind_of_stacks(app):
    """Ergaenzung 04.11.2026: Lehrwoche (null = Allgemein) und Art (vorlesung | uebung | eigene) je Stapel; aus dem
    Dokument kommt die Art aus seiner Einordnung und die Woche aus dem Dateinamen."""
    from app import db
    _clean()
    with db.cursor() as conn:
        conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, kind, status) VALUES ('st-blatt', 'st-k1', 'Uebungsblatt_03.pdf', 'pdf', 'neu')")
        conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, kind, status) VALUES ('st-vl', 'st-k1', 'VL05_Folgen.pdf', 'pdf', 'neu')")
    a = _call(app, "POST", "/api/flashcard-stacks", {"name": "Eigen"})
    assert (a["kind"], a["week"]) == ("eigene", None), "Vorgabe"
    b = _call(app, "POST", "/api/flashcard-stacks", {"name": "Blatt", "file_id": "st-blatt"})
    assert (b["kind"], b["week"]) == ("uebung", 3), "Einordnung und Lehrwoche des Dokuments"
    c = _call(app, "POST", "/api/flashcard-stacks", {"name": "Folien", "file_id": "st-vl", "week": 7})
    assert (c["kind"], c["week"]) == ("vorlesung", 7), "eigene Woche geht vor"
    r = _call(app, "POST", "/api/flashcards", {"cards": [{"question": "Q", "answer": "A"}], "file_id": "st-blatt", "stack_name": "KI-Karten"})
    ki = {s["id"]: s for s in _call(app, "GET", "/api/flashcard-stacks")}[r["stack_id"]]
    assert (ki["kind"], ki["week"], ki["file_id"]) == ("uebung", 3, "st-blatt"), "KI-Karten: Stapel nach dem Dokument"
    p = _call(app, "PATCH", f"/api/flashcard-stacks/{a['id']}", {"week": 2, "kind": "vorlesung"})
    assert (p["kind"], p["week"]) == ("vorlesung", 2)
    assert _call(app, "PATCH", f"/api/flashcard-stacks/{a['id']}", {"week": None})["week"] is None
    for bad in ({"week": 0}, {"week": "2"}, {"week": True}, {"kind": "klausur"}, {"kind": None}):
        assert _call(app, "PATCH", f"/api/flashcard-stacks/{a['id']}", bad, status=422)
    assert _call(app, "POST", "/api/flashcard-stacks", {"name": "x", "week": 1.5}, status=422)["detail"].startswith("week")

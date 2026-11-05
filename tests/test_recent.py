"""Weitermachen und "Zuletzt benutzt" am PC und im Dienst (app/recent.py, docs/WEITERMACHEN-2026-11-04.md):
GET /api/recent wie RecentEndpoints.swift plus die KI-Gespraeche je Dokument (/api/tutor-conversations, wie
TutorConversations.swift: hoechstens 15, aeltestes faellt heraus, "Neu" loescht)."""
import json

import pytest
from conftest import asgi_call


def _j(r):
    st, _, b = r
    return st, (json.loads(b) if b else None)


@pytest.fixture
def local(app, monkeypatch, tmp_path):
    from app import db
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "lernapp.db")
    db.init_db()
    with db.cursor() as conn:
        conn.execute("INSERT INTO courses(id, title, subject) VALUES ('c1', 'Analysis I', 'Analysis')")
        conn.execute("INSERT INTO files(id, course_id, name, last_opened, last_page, opened_count) VALUES ('f1','c1','Skript.pdf','2026-11-03T10:00:00',4,3)")
        conn.execute("INSERT INTO files(id, course_id, name, last_opened, last_page) VALUES ('f2','c1','Blatt 1.pdf','2026-11-04T09:00:00',1)")
        conn.execute("INSERT INTO files(id, course_id, name) VALUES ('f3','c1','nie geoeffnet.pdf')")
        conn.execute("INSERT INTO files(id, course_id, name, last_opened, deleted_at) VALUES ('f4','c1','weg.pdf','2026-11-05T09:00:00','2026-11-05T10:00:00')")
        conn.execute("INSERT INTO analysis(file_id, title) VALUES ('f1', 'Analysis Skript Kapitel 1')")
        conn.execute("""INSERT INTO tests(id, subject, title, questions, started_at, submitted_at, score, max_score)
                        VALUES (7, 'Analysis', 'Wochentest 3', '[]', '2026-11-02T08:00:00', '2026-11-02T08:30:00', 9, 12)""")
        conn.execute("INSERT INTO tests(id, subject, questions, started_at) VALUES (8, 'Physik', '[]', '2026-11-04T12:00:00')")
        conn.execute("INSERT INTO tests(id, subject, questions) VALUES (9, 'Chemie', '[]')")
    return app


def test_recent_lists_documents_and_tests_newest_first(local):
    st, r = _j(asgi_call(local, "GET", "/api/recent?limit=15"))
    assert st == 200
    items = r["items"]
    assert [(i["kind"], str(i["id"])) for i in items] == [("test", "8"), ("document", "f2"), ("document", "f1"), ("test", "7")]
    f1 = next(i for i in items if i["id"] == "f1")
    assert f1["title"] == "Analysis Skript Kapitel 1" and f1["sub"] == "Analysis" and f1["page"] == 4 and f1["opened_count"] == 3
    t7 = next(i for i in items if i["id"] == "7")
    assert t7["done"] is True and t7["title"] == "Wochentest 3" and "submitted_at" not in t7
    assert next(i for i in items if i["id"] == "8")["done"] is False
    st, r = _j(asgi_call(local, "GET", "/api/recent?limit=2"))
    assert len(r["items"]) == 2
    st, r = _j(asgi_call(local, "GET", "/api/recent?limit=999"))
    assert st == 200 and len(r["items"]) == 4


def test_conversation_roundtrip_and_recent_merge(local):
    msgs = [{"fromUser": True, "text": "Was ist eine Cauchy-Folge?\nBitte kurz", "mode": "ask"},
            {"fromUser": False, "text": "Eine Folge, deren Glieder ...", "mode": "ask", "sources": [{"n": 1, "file_id": "f1", "page": 3}],
             "explain": {"stored": True}},
            {"fromUser": False, "text": "", "cards": []},                     # leer: faellt weg
            "kaputt"]
    st, r = _j(asgi_call(local, "PUT", "/api/tutor-conversations/f1", body=json.dumps({"file_name": "Skript.pdf", "messages": msgs})))
    assert st == 200 and r["saved"] is True and r["messages"] == 2
    st, c = _j(asgi_call(local, "GET", "/api/tutor-conversations/f1"))
    assert st == 200 and c["file_name"] == "Skript.pdf" and len(c["messages"]) == 2
    assert c["messages"][1]["sources"][0]["page"] == 3 and c["messages"][1]["explain"] == {"stored": True}
    st, r = _j(asgi_call(local, "GET", "/api/recent"))
    conv = next(i for i in r["items"] if i["kind"] == "conversation")
    assert conv["id"] == "f1" and conv["title"] == "Was ist eine Cauchy-Folge? Bitte kurz" and conv["sub"] == "Skript.pdf"
    assert r["items"][0]["kind"] == "conversation"                            # gerade gespeichert = neuestes
    # "Neu" loescht das Gespraech
    assert asgi_call(local, "DELETE", "/api/tutor-conversations/f1")[0] == 200
    assert asgi_call(local, "GET", "/api/tutor-conversations/f1")[0] == 404
    # leere Liste loescht ebenso
    asgi_call(local, "PUT", "/api/tutor-conversations/f2", body=json.dumps({"messages": msgs[:1]}))
    st, r = _j(asgi_call(local, "PUT", "/api/tutor-conversations/f2", body=json.dumps({"messages": []})))
    assert r["saved"] is False and asgi_call(local, "GET", "/api/tutor-conversations/f2")[0] == 404


def test_keeps_only_last_15_conversations(local):
    from app import db, recent
    with db.cursor() as conn:
        for i in range(17):
            recent.save_conversation(conn, f"d{i}", f"Datei {i}", [{"fromUser": True, "text": f"Frage {i}"}], now=f"2026-11-01T10:{i:02d}:00")
        keys = [c["key"] for c in recent.list_conversations(conn)]
    assert len(keys) == 15 and keys[0] == "d16" and "d0" not in keys and "d1" not in keys


def test_exam_conversation_and_limits():
    from app import recent
    assert recent.parse_exam_key("exam:12:3a") == (12, "3a")
    assert recent.parse_exam_key("f1") is None and recent.parse_exam_key("exam:x:1") is None
    items = recent.merge([], [{"key": "exam:12:3", "file_name": "Aufgabe 3 – Wochentest", "last_question": "Warum?", "updated_at": "2026-11-05T10:00:00"}], 5)
    assert items == [{"kind": "conversation", "id": "exam:12:3", "title": "Aufgabe 3 – Wochentest", "sub": "Wochentest",
                      "at": "2026-11-05T10:00:00", "page": None, "test_id": 12, "nr": "3"}]
    many = [{"fromUser": i % 2 == 0, "text": "x" * 10} for i in range(200)]
    assert len(recent.clean_messages(many)) == recent.MAX_MESSAGES
    big = [{"fromUser": True, "text": "y" * 19000} for _ in range(40)]
    out = recent.clean_messages(big)
    assert len(json.dumps(out)) <= recent.MAX_BYTES and len(out) < 40


def test_invalid_key(local):
    assert asgi_call(local, "GET", "/api/tutor-conversations/" + "k" * 300)[0] == 400

"""Gemeinsame Wochentests: gleiche Vorlesung + gleiche Uebung -> derselbe Test, ohne neue KI-Anfrage."""
import hashlib
import json
from pathlib import Path

import pytest

FIX = Path(__file__).resolve().parents[1] / "packages" / "shared-contracts" / "fixtures" / "testshare" / "cases.json"


def test_share_key_matches_shared_fixture():
    """Dieselben Erwartungswerte prueft die iPad-App (UniFlowCore)."""
    from app import testshare
    doc = json.loads(FIX.read_text(encoding="utf-8"))
    assert doc["version"] == testshare.VERSION and tuple(doc["minute_steps"]) == testshare.MINUTE_STEPS
    for cs in doc["cases"]:
        got = testshare.share_key(cs["university"], cs["minutes"], [{"content_sha256": h} for h in cs["materials"]])
        assert got == cs["expected_key"], cs["name"]


def test_share_key_rules():
    from app import testshare
    a, b, c = ({"content_sha256": hashlib.sha256(x).hexdigest()} for x in (b"VL3", b"Blatt3-A", b"Blatt3-B"))
    k = testshare.share_key("luh", 45, [a, b])
    assert k == testshare.share_key("luh", 41, [b, a])           # Reihenfolge und Dauer-Stufe egal
    assert k != testshare.share_key("luh", 45, [a, c])           # andere Uebungsgruppe -> eigener Test
    assert k != testshare.share_key("hildesheim", 45, [a, b])    # Unis werden nie gemischt
    assert testshare.share_key("luh", 45, [a, {"content_sha256": None, "local_path": None}]) is None   # unsicher -> nicht teilen
    assert testshare.share_key("luh", 45, []) is None
    assert [testshare.minutes_bucket(m) for m in (10, 15, 16, 45, 61, 500, None)] == [15, 15, 30, 45, 90, 120, 45]


def test_file_hash_is_stored_on_download(app, tmp_path):
    from app import db
    from app.studip_sync import store_course_files, upsert_course
    course = {"id": "ts-c1", "title": "TS Kurs", "number": None, "semester": "WiSe 2026/27"}
    f = {"id": "ts-f1", "name": "vl.pdf", "size": 4, "mime": "application/pdf", "author": None, "chdate": 1, "download_url": "x"}

    def dl(url, target, size=0):
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b"%PDF inhalt")

    with db.cursor() as conn:
        upsert_course(conn, course, "2026-10-25")
        store_course_files(conn, course, [f], {}, dl, "2026-10-25", [], pause=0)
        h = db.row(conn, "SELECT content_sha256 FROM files WHERE id='ts-f1'")["content_sha256"]
        conn.execute("DELETE FROM files WHERE id='ts-f1'"); conn.execute("DELETE FROM courses WHERE id='ts-c1'")
    assert h == hashlib.sha256(b"%PDF inhalt").hexdigest()


@pytest.fixture
def two_modules_same_course(app, tmp_path, monkeypatch):
    """Zwei Module mit identischen Materialien (wie zwei Studierende im selben Kurs) und eines mit anderem Blatt."""
    from app import db, planner
    files = {"vl": b"%PDF Vorlesung 3", "a": b"%PDF Blatt 3 Gruppe A", "b": b"%PDF Blatt 3 Gruppe B"}
    paths = {}
    for k, data in files.items():
        p = tmp_path / f"{k}.pdf"; p.write_bytes(data); paths[k] = p

    def mats(conn, subject, limit=8, module_id=None, week_no=None):
        use = {"M1": ("vl", "a"), "M2": ("a", "vl"), "M3": ("vl", "b")}[subject]
        return [{"id": k, "name": f"{k}.pdf", "text": "Inhalt", "local_path": str(paths[k]), "content_sha256": None} for k in use]

    calls = []

    def fake_generate(subject, minutes, materials):
        calls.append(subject)
        return {"title": f"Wochentest {subject}", "questions": [{"q": f"Frage aus {subject}", "points": 1}]}

    monkeypatch.setattr(planner, "_materials_for_test", mats)
    monkeypatch.setattr(planner.ai, "generate_test", fake_generate)
    with db.cursor() as conn:
        ids = []
        for name in ("M1", "M2", "M3"):
            cur = conn.execute("INSERT INTO modules(name, color, created_at) VALUES (?, '#123456', '2026-10-25')", (name,))
            ids.append(cur.lastrowid)
    yield ids, calls
    with db.cursor() as conn:
        conn.execute(f"DELETE FROM tests WHERE module_id IN ({','.join('?' * len(ids))})", ids)
        conn.execute(f"DELETE FROM modules WHERE id IN ({','.join('?' * len(ids))})", ids)


def test_same_course_and_exercise_share_one_test(two_modules_same_course):
    from app import db, planner
    (m1, m2, m3), calls = two_modules_same_course
    t1 = planner.create_test("M1", 45, module_id=m1, week_no=3, auto=True, log=lambda *_: None)
    t2 = planner.create_test("M2", 40, module_id=m2, week_no=4, auto=True, log=lambda *_: None)
    t3 = planner.create_test("M3", 45, module_id=m3, week_no=3, auto=True, log=lambda *_: None)
    assert calls == ["M1", "M3"]                         # M2 hat dieselben Materialien: keine zweite KI-Anfrage
    with db.cursor() as conn:
        r = {t["id"]: t for t in db.rows(conn, "SELECT id, title, questions, share_key, week_no FROM tests WHERE id IN (?,?,?)", (t1, t2, t3))}
    assert r[t1]["share_key"] == r[t2]["share_key"] != r[t3]["share_key"]
    assert r[t1]["questions"] == r[t2]["questions"]      # identischer Test
    assert r[t2]["title"].startswith("Lehrwoche 4: ") and "Lehrwoche 3" not in r[t2]["title"]   # eigene Woche im Titel

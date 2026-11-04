"""Gemeinsame Wochentests: gleiche Vorlesung + gleiche Uebung -> derselbe Test, ohne neue KI-Anfrage."""
import hashlib
import json
import time
from pathlib import Path

import pytest

from conftest import asgi_call

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
    assert [testshare.minutes_bucket(m) for m in (10, 15, 16, 45, 61, 500, None, 0)] == [15, 15, 30, 45, 90, 120, 45, 45]


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

    def fake_generate(subject, minutes, materials, exam=None):
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


# ---------------------------------------------------------------- Varianten (Regel des Inhabers vom 04.11.2026)

from test_subscriptions import _j, hosted, user  # noqa: E402,F401 - Fixture und Helfer des Dienstes


def test_variant_and_pick_match_shared_fixture():
    """Dieselben Erwartungswerte prueft der Swift-Kern (TestShareVariantsTests)."""
    from app import testshare
    doc = json.loads(FIX.read_text(encoding="utf-8"))
    assert doc["max_variants"] == testshare.MAX_VARIANTS == 3
    assert doc["variants"], "Fixture ohne Varianten"
    for c in doc["variants"]:
        assert testshare.variant(c["user_id"], c["key"]) == c["expected"], c["user_id"]
    for c in doc["pick_cases"]:
        assert testshare.pick(c["ready"], c["assigned"], c["pending"]) == (c["action"], c["variant"]), c


def test_variant_is_stable_and_evenly_distributed_over_10000_users():
    from app import testshare
    key = "wt2:" + "ab" * 32
    counts = [0, 0, 0]
    for i in range(10_000):
        v = testshare.variant(f"_user-{i}", key)
        assert v == testshare.variant(f"_user-{i}", key)
        counts[v] += 1
    for v, n in enumerate(counts):
        assert 3_000 <= n <= 3_600, f"Variante {v}: {n} von 10000 (30-36 %)"


def test_pick_rule_and_shared_info():
    from app import testshare
    assert testshare.pick([], 2) == ("generate", 2)
    assert testshare.pick([2], 2) == ("adopt", 2)
    assert testshare.pick([2, 0], 2) == ("adopt", 2)                      # eigene fertig -> uebernehmen
    assert testshare.pick([2], 1) == ("generate", 1)                      # eigene frei
    assert testshare.pick([], 1, pending=[1]) == ("generate", 2)          # eigene in Arbeit (Wettlauf): naechste freie
    assert testshare.pick([0], 1, pending=[1]) == ("generate", 2)
    assert testshare.pick([0, 2], 1, pending=[1]) == ("adopt", 2)         # drei belegt: nie erzeugen, naechste fertige (zyklisch)
    assert testshare.pick([0], 1, pending=[1, 2]) == ("adopt", 0)
    assert testshare.pick([0, 1, 2], 1) == ("adopt", 1)
    assert testshare.pick([], 1, pending=[0, 1, 2]) == ("none", None)     # alle belegt, keine fertig
    assert testshare.pick({7: "x"}, 1, pending={1: "y"}) == ("generate", 2)   # fremde Zahlen zaehlen nicht
    assert testshare.shared_info({"share_variant": 1, "adopted_from": "cloudkit"}) == {"variant": 2, "of": 3, "adopted": True}
    assert testshare.shared_info({"share_variant": 0, "adopted_from": None}) == {"variant": 1, "of": 3, "adopted": False}
    assert testshare.shared_info({"share_variant": None}) is None and testshare.shared_info(None) is None


def test_local_app_remembers_own_variant_and_exposes_shared_in_json(two_modules_same_course):
    """Einzelplatz ohne Dienst: eigene Variante aus der Installationskennung, kein Uebernehmen; das zweite Modul mit
    denselben Dateien nimmt den eigenen Test (adopted_from local); GET /api/tests[/id] liefert `shared`."""
    from app import db, planner, testshare
    from app.server import app as fastapi_app
    (m1, m2, m3), calls = two_modules_same_course
    t1 = planner.create_test("M1", 45, module_id=m1, week_no=3, auto=True, log=lambda *_: None)
    t2 = planner.create_test("M2", 40, module_id=m2, week_no=4, auto=True, log=lambda *_: None)
    with db.cursor() as conn:
        uid = db.row(conn, "SELECT value FROM settings WHERE key='share_user_id'")["value"]
        assert uid == testshare.user_id(conn), "einmal erzeugt, dann fest"
        r = {t["id"]: t for t in db.rows(conn, "SELECT id, share_key, share_variant, adopted_from FROM tests WHERE id IN (?,?)", (t1, t2))}
    assert r[t1]["share_variant"] == testshare.variant(uid, r[t1]["share_key"]) and r[t1]["adopted_from"] is None
    assert r[t2]["share_variant"] == r[t1]["share_variant"] and r[t2]["adopted_from"] == "local"
    st, d = _j(asgi_call(fastapi_app, "GET", f"/api/tests/{t2}"))
    assert st == 200 and d["shared"] == {"variant": r[t1]["share_variant"] + 1, "of": 3, "adopted": True}
    st, rows = _j(asgi_call(fastapi_app, "GET", "/api/tests"))
    mine = {t["id"]: t for t in rows}
    assert mine[t1]["shared"] == {"variant": r[t1]["share_variant"] + 1, "of": 3, "adopted": False}
    assert "share_variant" not in mine[t1]
    assert calls == ["M1"]


def _users_for_variants(key, n=4):
    """n Konten, deren Varianten zuerst 0, 1, 2 (in irgendeiner Reihenfolge) und dann eine davon sind"""
    from app import testshare
    users, seen, i = [], set(), 0
    while len(seen) < testshare.MAX_VARIANTS:
        u = f"{i:032x}"; i += 1
        if testshare.variant(u, key) not in seen:
            seen.add(testshare.variant(u, key)); users.append(u)
    while len(users) < n:
        users.append(f"{i:032x}"); i += 1
    return users


def test_hosted_pool_four_students_three_tests_fourth_adopts(hosted):
    """Dienst: vier Konten mit denselben Dateien -> genau drei KI-Tests, das vierte Konto uebernimmt (nie ein vierter)."""
    from app import test_library, testshare
    key = testshare.share_key("luh", 45, [{"content_sha256": "a" * 64}, {"content_sha256": "b" * 64}])
    users = _users_for_variants(key)
    calls = []

    def gen():
        calls.append(1)
        return {"title": f"Wochentest M – T{len(calls)}", "questions": [{"nr": 1, "question": f"Frage {len(calls)}"}]}

    got = [testshare.obtain(key, u, gen, log=lambda *_: None, wait_s=0) for u in users]
    assert len(calls) == 3
    for u, g in zip(users[:3], got[:3]):
        assert g["share_variant"] == testshare.variant(u, key) and g["adopted_from"] is None
    fourth = got[3]
    assert fourth["adopted_from"] == "service" and fourth["share_variant"] == testshare.variant(users[3], key)
    assert fourth["questions"] == test_library.shared_get(key, fourth["share_variant"], count_use=False)["questions"]
    assert {v: s["status"] for v, s in test_library.shared_slots(key).items()} == {0: "ready", 1: "ready", 2: "ready"}
    # ein fuenftes Konto mit der Variante des ersten uebernimmt dessen Test, egal wie viele kommen
    for u in _users_for_variants(key, 40)[3:]:
        g = testshare.obtain(key, u, gen, log=lambda *_: None, wait_s=0)
        assert g["adopted_from"] == "service" and g["share_variant"] == testshare.variant(u, key)
    assert len(calls) == 3


def test_hosted_pool_race_same_variant_one_generates_other_waits_and_adopts(hosted):
    """Zwei Konten mit derselben Variante gleichzeitig: Ben hat den Platz belegt und erzeugt; Ada wartet und uebernimmt."""
    import threading
    from app import test_library, testshare
    key = testshare.share_key("luh", 45, [{"content_sha256": "c" * 64}])
    ada = "a" * 32
    v = testshare.variant(ada, key)
    ben = next(u for u in (f"{i:032x}" for i in range(1, 500)) if testshare.variant(u, key) == v)
    assert test_library.shared_claim(key, v, ben)
    assert not test_library.shared_claim(key, v, ada), "Platz ist vergeben"
    test_library.SHARED_POLL_S = 0.02

    def ben_finishes():
        time.sleep(0.15)
        test_library.shared_publish(key, v, ben, "Wochentest M – Ben", [{"nr": 1, "question": "von Ben"}])
    threading.Thread(target=ben_finishes).start()
    got = testshare.obtain(key, ada, lambda: pytest.fail("Ada erzeugt nicht"), log=lambda *_: None, wait_s=5)
    assert got == {"title": "Wochentest M – Ben", "questions": [{"nr": 1, "question": "von Ben"}], "share_variant": v, "adopted_from": "service"}
    # Ben kann seinen fertigen Platz nicht mehr freigeben, Ada nie
    test_library.shared_release(key, v, ben); test_library.shared_release(key, v, ada)
    assert test_library.shared_slots(key)[v]["status"] == "ready"


def test_hosted_pool_wait_timeout_claims_next_free_and_failure_releases(hosted):
    from app import test_library, testshare
    key = testshare.share_key("luh", 45, [{"content_sha256": "d" * 64}])
    ada = "b" * 32
    v = testshare.variant(ada, key)
    other = next(u for u in (f"{i:032x}" for i in range(1, 500)) if testshare.variant(u, key) == v)
    assert test_library.shared_claim(key, v, other)
    got = testshare.obtain(key, ada, lambda: {"title": "T", "questions": [{"nr": 1}]}, log=lambda *_: None, wait_s=0)
    assert got["share_variant"] == (v + 1) % 3 and got["adopted_from"] is None, "naechste freie Variante, der andere behaelt seinen Platz"
    # Erzeugen scheitert: Platz wieder frei
    before = set(test_library.shared_slots(key))

    def boom():
        raise RuntimeError("KI weg")
    free = next(u for u in (f"{i:032x}" for i in range(1, 500)) if testshare.variant(u, key) == (v + 2) % 3)
    with pytest.raises(RuntimeError):
        testshare.obtain(key, free, boom, log=lambda *_: None, wait_s=0)
    assert set(test_library.shared_slots(key)) == before
    # verwaiste Belegung (aelter als PENDING_STALE_S) wird freigegeben
    with test_library.cursor() as conn:
        conn.execute("UPDATE shared_tests SET created_at='2020-01-01T00:00:00+00:00' WHERE share_key=? AND variant=?", (key, v))
    assert v not in test_library.shared_slots(key)
    assert test_library.shared_claim(key, v, ada)


def test_shared_test_endpoints_for_devices(hosted):
    """iPad mit Dienst (V2): nachsehen, belegen, veroeffentlichen, freigeben; fremde Plaetze bleiben unberuehrt."""
    from app import ai, testshare
    key = testshare.share_key("luh", 45, [{"content_sha256": "e" * 64}])
    ada, ha = user(hosted, "ada@beispiel.de")
    ben, hb = user(hosted, "ben@beispiel.de")
    va, vb = testshare.variant(ada["id"], key), testshare.variant(ben["id"], key)
    st, d = _j(asgi_call(hosted, "GET", f"/api/v2/shared-tests/{key}", headers=ha))
    assert st == 200 and d["action"] == "generate" and d["generate_as"] == va and d["variant"] == va and d["of"] == 3
    st, d = _j(asgi_call(hosted, "GET", "/api/v2/shared-tests/kaputt", headers=ha))
    assert st == 400
    st, d = _j(asgi_call(hosted, "POST", f"/api/v2/shared-tests/{key}/claim", headers=ha, body="{}"))
    assert st == 200 and d == {"key": key, "variant": va, "claimed": True, "variants": {str(va): "pending"}}
    # Ben mit derselben Variante soll warten, mit einer anderen erzeugen
    st, d = _j(asgi_call(hosted, "GET", f"/api/v2/shared-tests/{key}", headers=hb))
    assert d["action"] == ("wait" if vb == va else "generate")
    # veroeffentlichen nur in der Form vom 29.10.2026 und nur in den eigenen Platz
    qs = [{"nr": i + 1, "type": "calc", "difficulty": d, "question": f"Aufgabe {i + 1}", "answer": "1", "points": 6}
          for i, d in enumerate(["leicht"] * 4 + ["mittel"] * 6 + ["schwer"] * 5)]
    assert ai.check_week_test({"questions": qs}) is None
    st, d = _j(asgi_call(hosted, "POST", f"/api/v2/shared-tests/{key}/{va}", headers=hb, body=json.dumps({"title": "T", "questions": qs})))
    assert st == 409
    st, d = _j(asgi_call(hosted, "POST", f"/api/v2/shared-tests/{key}/{va}", headers=ha, body=json.dumps({"title": "T", "questions": qs[:3]})))
    assert st == 400 and d["code"] == "week_test_form", d
    st, d = _j(asgi_call(hosted, "POST", f"/api/v2/shared-tests/{key}/{va}", headers=ha, body=json.dumps({"title": "Wochentest M", "questions": qs})))
    assert st == 200 and d["published"] is True
    st, d = _j(asgi_call(hosted, "GET", f"/api/v2/shared-tests/{key}", headers=ha))
    assert d["action"] == "adopt" and d["test"]["title"] == "Wochentest M" and len(d["test"]["questions"]) == 15
    if vb == va:
        st, d = _j(asgi_call(hosted, "GET", f"/api/v2/shared-tests/{key}", headers=hb))
        assert d["action"] == "adopt" and d["test"]["questions"] == qs
    # Freigeben nur den eigenen leeren Platz
    st, d = _j(asgi_call(hosted, "DELETE", f"/api/v2/shared-tests/{key}/{va}", headers=hb))
    assert st == 200
    st, d = _j(asgi_call(hosted, "GET", f"/api/v2/shared-tests/{key}", headers=ha))
    assert d["variants"] == {str(va): "ready"}
    # ohne Anmeldung nichts
    st, _ = _j(asgi_call(hosted, "GET", f"/api/v2/shared-tests/{key}"))
    assert st == 401


def test_old_database_gets_share_variant_and_adopted_from(tmp_path, monkeypatch):
    """Migration (Python wie Migrations.swift, Fixture schema/legacy.json): die Spalten kommen hinter share_key dazu."""
    import sqlite3
    from app import db
    path = tmp_path / "alt.db"
    with sqlite3.connect(path) as c:
        c.executescript("""CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE tests (id INTEGER PRIMARY KEY AUTOINCREMENT, subject TEXT NOT NULL, week_start TEXT, title TEXT,
                                duration_min INTEGER, questions TEXT NOT NULL, created_at TEXT, started_at TEXT, submitted_at TEXT,
                                answers TEXT, score REAL, max_score REAL, feedback TEXT);
            INSERT INTO tests(subject, questions) VALUES ('Algebra', '[]');""")
    monkeypatch.setattr(db, "DB_PATH", path)
    db.init_db(); db.init_db()
    c = sqlite3.connect(path)
    cols = [r[1] for r in c.execute("PRAGMA table_info(tests)")]
    i = cols.index("share_key")
    assert cols[i:i + 3] == ["share_key", "share_variant", "adopted_from"]
    assert c.execute("SELECT share_variant, adopted_from FROM tests").fetchone() == (None, None)
    assert cols.count("share_variant") == 1

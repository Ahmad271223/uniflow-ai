"""Wochentests mit Vorlesungs-Seitenmarker: Stoffgrenzen, Zuordnung, Zeitplan, Nachtraege, Probeklausur.

Die KI wird simuliert (FakeAI), die Datenbank ist pro Test frisch (Temp-Datei), echte Daten bleiben unberuehrt.
"""
import json
import re
import threading
from datetime import datetime

import pytest

from conftest import asgi_call

MOD = 1
LEC = "lec-prog1"
MON = "2026-10-19"          # Montag, Lehrwoche 2 (Semester ab 12.10.2026)
WED = "2026-10-21"


# ---------------------------------------------------------------- Testmaterial
def lecture_pages(n=120):
    pages = []
    for i in range(1, n + 1):
        if i <= 36:
            body = ("Variablen und Datentypen. Ein Integer speichert ganze Zahlen, die Zuweisung legt den Wert der Variablen fest. "
                    "Ausdruecke kombinieren Operatoren. Datentyp double float char, Deklaration, Initialisierung, Typumwandlung.")
        elif i <= 62:
            body = ("Schleifen und Bedingungen. Die while Schleife wiederholt Anweisungen solange die Abbruchbedingung gilt. "
                    "for Schleife mit Schleifenzaehler, if Bedingung, Verzweigung, else Zweig, Vergleichsoperator.")
        else:
            body = ("Arrays und Felder. Ein Array speichert Feldelemente, der Index beginnt bei null. Arraygroesse, Feldlaenge, "
                    "mehrdimensionale Felder, Zeiger auf das erste Feldelement, Speicheradresse.")
        pages.append(f"Folie {i}\n{body} Kennung{i:03d}x")
    return pages


EX_SHEET = [  # "Übung_04.pdf": Aufgabe 1 = Woche-1-Stoff, Aufgabe 2 = Schleifen (spaeter)
    "Übungsblatt 4\nAufgabe 1: Deklarieren Sie eine Variable vom Datentyp Integer und eine vom Datentyp double. "
    "Erklaeren Sie Initialisierung, Zuweisung und Typumwandlung zwischen Integer und double.\n"
    "Aufgabe 2: Schreiben Sie eine while Schleife mit Schleifenzaehler und Abbruchbedingung. Ergaenzen Sie eine if Bedingung "
    "mit else Zweig und Vergleichsoperator in der Schleife.",
]
HUE = ["Hörsaalübung 1\nAufgabe 1: Welche Datentypen gibt es fuer ganze Zahlen und Kommazahlen? Integer, double, float, char. "
       "Zeigen Sie Deklaration und Initialisierung einer Variablen sowie eine Zuweisung."]
GUE = ["Gruppenübung 2\nAufgabe 1: Typumwandlung: Ein Ausdruck kombiniert Integer und double mit Operatoren. "
       "Welchen Datentyp hat das Ergebnis? Deklaration und Zuweisung der Variablen angeben."]
EXAMS = {
    "Klausur_WS23.pdf": ("Alte Klausuren/WS 23", "Klausur Programmieren WS 23\nAufgabe 4 (10 Punkte): Schleifen. Schreiben Sie eine for Schleife "
                         "mit Schleifenzaehler und eine while Schleife mit Abbruchbedingung, die die Summe berechnet."),
    "Klausur_SS24.pdf": ("Alte Klausuren/SS 24", "Klausur Programmieren SS 24\nAufgabe 2 (8 Punkte): Bedingungen. Verzweigung mit if Bedingung, "
                         "else Zweig und Vergleichsoperator fuer eine Notenberechnung."),
    "Klausur_WS25.pdf": ("Alte Klausuren/WS 25", "Klausur Programmieren WS 25\nAufgabe 6 (12 Punkte): Arrays. Legen Sie ein Array an, greifen Sie "
                         "per Index auf Feldelemente zu und bestimmen Sie die Feldlaenge mehrdimensionaler Felder."),
    "Klausur_WS22.pdf": ("Alte Klausuren/WS 22", "Klausur Programmieren WS 22\nAufgabe 1 (6 Punkte): Datentypen. Welcher Datentyp speichert ganze "
                         "Zahlen? Erklaeren Sie Integer, double, Deklaration und Initialisierung einer Variablen mit Zuweisung."),
}


# ---------------------------------------------------------------- Simulierte KI
class FakeAI:
    def __init__(self, mode="good"):
        self.mode = mode; self.calls = []; self.lock = threading.Lock()

    def __call__(self, prompt, system=""):
        with self.lock:
            self.calls.append(prompt)
        kind = re.search(r"### AUFTRAG: (\w+)", prompt).group(1)
        if kind == "PRUEFUNG":
            qs = json.loads(prompt.split("AUFGABEN:\n", 1)[1].split("\n\nAntworte als JSON", 1)[0])
            return json.dumps({"results": [{"nr": q["nr"], "ok": self.mode != "review_fail", "solvable": True, "solution_correct": True,
                                            "issue": "Loesung falsch" if self.mode == "review_fail" else ""} for q in qs]})
        if self.mode == "garbage":
            return "Entschuldigung, das kann ich gerade nicht."
        n = int(re.search(r"Erstelle GENAU (\d+) Aufgaben", prompt).group(1))
        new_sec = prompt.split("NEUER STOFF DIESER WOCHE", 1)[1].split("\n\n", 1)[0]
        new_ids = re.findall(r"^\[(L\d+)\]", new_sec, re.M) or re.findall(r"^\[(L\d+)\]", prompt, re.M)
        task_ids = re.findall(r"^\[(A\d+)\]", prompt, re.M)
        m = (re.search(r"an eine dieser Altklausuraufgaben angelehnt: ([A\d, ]+) \(", prompt)
             or re.search(r"Baue 1–2 der Altklausuraufgaben ([A\d, ]+) ein", prompt))
        exam = [x.strip() for x in m.group(1).split(",")] if m else []
        qs = []
        for i in range(1, n + 1):
            refs = [new_ids[(i - 1) % len(new_ids)]] if new_ids else []
            if task_ids and i % 3 == 0:
                refs.append(task_ids[i % len(task_ids)])
            q = {"nr": i, "level": "leicht" if i <= 4 else ("schwer" if i > 10 else "mittel"), "type": "mc" if i % 4 == 0 else "short",
                 "topic": f"Thema {i}", "difficulty": 2 if i <= 5 else 4, "question": f"Eigenstaendige Frage Nummer {i} zum markierten Stoff?",
                 "answer": f"Antwort {i} mit Begruendung", "steps": ["Ansatz", "Rechnung"], "rubric": [{"criterion": "Ansatz", "points": 3}],
                 "points": 100 / n, "refs": refs, "from_exam": None, "exam_mode": None}
            if q["type"] == "mc":
                q["options"] = ["A eins", "B zwei", "C drei", "D vier"]; q["answer"] = "B zwei"
            if i == 13 and exam:                                   # eine der schweren Aufgaben
                q.update(from_exam=exam[0], exam_mode="angelehnt", refs=refs + [exam[0]])
            if self.mode == "leak" and i == 2:
                q["refs"] = ["L999"]
            qs.append(q)
        return json.dumps({"title": "Testversion", "questions": qs})

    def gen_prompts(self):
        return [c for c in self.calls if "### AUFTRAG: PRUEFUNG" not in c]


# ---------------------------------------------------------------- Fixtures
@pytest.fixture
def env(tmp_path, monkeypatch, app):
    from app import db, scriptsearch, weekly
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "t.db")
    scriptsearch._CACHE.clear()
    db.init_db()
    fake = FakeAI()
    monkeypatch.setattr(weekly, "_ask", fake)
    E = Env(tmp_path, fake)
    E.setup()
    return E


class Env:
    def __init__(self, tmp, fake):
        self.tmp = tmp; self.fake = fake; self.n = 0

    def conn(self):
        from app import db
        return db.cursor()

    def add_file(self, fid, name, folder, pages, course="cu", chdate=1760000000):
        from app import db
        p = self.tmp / f"{fid}.pdf"; p.write_bytes(b"%PDF-1.4 test")
        with db.cursor() as c:
            c.execute("INSERT OR REPLACE INTO files(id, course_id, name, local_path, chdate, studip_folder, status, kind, first_seen) VALUES (?,?,?,?,?,?, 'neu', 'pdf', ?)",
                      (fid, course, name, str(p), chdate, folder, "2026-10-01"))
            c.execute("DELETE FROM page_texts WHERE file_id=?", (fid,))
            c.executemany("INSERT INTO page_texts(file_id, page, text, chdate) VALUES (?,?,?,?)", [(fid, i + 1, t, chdate) for i, t in enumerate(pages)])
        from app import scriptsearch
        scriptsearch._CACHE.clear()

    def setup(self):
        from app import db
        with db.cursor() as c:
            c.execute("INSERT INTO modules(id, name, created_at, weekly_test, active) VALUES (?, 'Programmieren 1', '2026-10-01', 1, 1)", (MOD,))
            c.execute("INSERT INTO courses(id, title, kind, module_id, active, subject) VALUES ('cv', 'Programmieren 1', 'vorlesung', ?, 1, 'Programmieren 1')", (MOD,))
            c.execute("INSERT INTO courses(id, title, kind, module_id, active, subject) VALUES ('cu', 'Übung Programmieren 1', 'uebung', ?, 1, 'Programmieren 1')", (MOD,))
            c.execute("""INSERT INTO course_events(module_id, title, kind, weekday, start_time, end_time, rrule, attend, source, created_at)
                         VALUES (?, 'Programmieren 1', 'vorlesung', 0, '10:00', '11:30', 'weekly', 1, 'manual', '2026-10-01')""", (MOD,))
        self.add_file(LEC, "Prog1_Vorlesung.pdf", "Vorlesung", lecture_pages(), course="cv")
        self.add_file("ex4", "Übung_04.pdf", "Übungsblätter", EX_SHEET)
        self.add_file("hue1", "HÜ 1.pdf", "Hörsaalübung", HUE)
        for i, (name, (folder, text)) in enumerate(EXAMS.items()):
            self.add_file(f"kl{i}", name, folder, [text])

    def mark(self, page, day=MON, user="local"):
        from app import weekly
        with self.conn() as c:
            return weekly.create_marker(c, LEC, page, user_id=user, lecture_date=day, now=datetime.fromisoformat(f"{day}T12:00:00"))

    def tick(self, when):
        from app import weekly
        return weekly.tick(datetime.fromisoformat(when), log=lambda *_: None)

    def plans(self):
        from app import db
        with self.conn() as c:
            return db.rows(c, "SELECT * FROM wt_plans WHERE status!='ersetzt' ORDER BY week_no, part")

    def defs(self, kind="wochentest"):
        from app import db
        with self.conn() as c:
            return db.rows(c, "SELECT * FROM wt_defs WHERE kind=? ORDER BY id", (kind,))


def _ctx(env, plan_id):
    from app import db, weekly
    with env.conn() as c:
        plan = db.row(c, "SELECT * FROM wt_plans WHERE id=?", (plan_id,))
        cj = json.loads(plan["coverage"])
        newp = {(s["file_id"], x) for s in cj["new"] for x in range(s["from"], s["to"] + 1)}
        allp = newp | {(s["file_id"], x) for s in cj["prior"] for x in range(s["from"], s["to"] + 1)}
        return weekly.candidates(c, MOD, {"pages": allp}, newp), cj


# ================================================================ 1-2: Seitenmarker begrenzt den Stoff
def test_marker_36_limits_week_test(env):
    m = env.mark(36)
    assert m["page_range"] == [1, 36] and m["week_no"] == 2
    r = env.tick("2026-10-20T11:31:00")
    assert len(r["published"]) == 1
    d = env.defs()[0]
    src = json.loads(d["sources"])
    pages = {p for f, p in src["lecture_pages"]}
    assert pages and max(pages) <= 36, "kein Material aus Folie 37-120"
    gen = env.fake.gen_prompts()[0]
    assert "Kennung037x" not in gen and "while Schleife" not in gen and "Feldelemente" not in gen
    assert "Kennung036x" in gen


def test_second_marker_62_adds_new_material(env):
    env.mark(36)
    env.mark(62, day="2026-10-26")
    env.tick("2026-10-27T11:31:00")
    plans = env.plans()
    assert [(p["week_no"], p["status"]) for p in plans] == [(2, "veroeffentlicht"), (3, "veroeffentlicht")]
    cj = json.loads(plans[1]["coverage"])
    assert [(s["from"], s["to"]) for s in cj["new"]] == [(37, 62)]
    assert [(s["from"], s["to"]) for s in cj["prior"]] == [(1, 36)]
    week3 = json.loads(env.defs()[1]["sources"])
    assert {p for _, p in week3["lecture_pages"]} <= set(range(37, 63))
    assert "Kennung063x" not in env.fake.gen_prompts()[-1]


# ================================================================ 3-6: Zuordnung von Uebungen und Altklausuren
def test_exercises_with_other_names_matched_by_content(env):
    env.mark(36)
    env.tick("2026-10-20T11:31:00")
    cands, _ = _ctx(env, env.plans()[0]["id"])
    labels = {c["label"] for c in cands["ok"]}
    assert any("HÜ 1" in l for l in labels), "Hörsaalübung mit anderem Dateinamen gefunden"
    assert any("Übung_04" in l and "Aufgabe 1" in l for l in labels)


def test_sheet_with_tasks_from_different_weeks_is_split(env):
    env.mark(36)
    env.mark(62, day="2026-10-26")
    env.tick("2026-10-27T11:31:00")
    w2, w3 = env.plans()
    c2, _ = _ctx(env, w2["id"])
    ok2 = {c["label"] for c in c2["ok"] if "Übung_04" in c["label"]}
    assert ok2 == {next(l for l in ok2 if "Aufgabe 1" in l)}, "Woche 2: nur Aufgabe 1"
    assert any("Übung_04" in x["label"] and "Aufgabe 2" in x["label"] for x in c2["excluded"])
    c3, _ = _ctx(env, w3["id"])
    assert any("Übung_04" in c["label"] and "Aufgabe 2" in c["label"] and c["is_new_week"] for c in c3["ok"])


def test_exam_tasks_filtered_by_covered_topics(env):
    env.mark(36)
    env.mark(62, day="2026-10-26")
    env.tick("2026-10-27T11:31:00")
    _, w3 = env.plans()
    c3, _ = _ctx(env, w3["id"])
    exams = {c["label"] for c in c3["ok"] if c["source"] == "altklausur"}
    assert any("WS23" in l for l in exams) and any("SS24" in l for l in exams), "Schleifen + Bedingungen passen"
    assert not any("WS25" in l for l in exams), "Arrays noch nicht behandelt"
    assert any("WS25" in x["label"] for x in c3["excluded"])


def test_matching_exam_tasks_are_used_in_test(env):
    env.mark(36)
    env.mark(62, day="2026-10-26")
    env.tick("2026-10-27T11:31:00")
    d = env.defs()[1]
    src = json.loads(d["sources"])
    assert src["exam_candidates"] >= 1
    assert sum(1 for q in src["per_question"] if q["from_exam"]) == 1, "genau eine Altklausuraufgabe (Regel 29.10.)"
    qs = json.loads(d["questions"])
    assert len(qs) == 15
    assert [sum(q["level"] == k for q in qs) for k in ("leicht", "mittel", "schwer")] == [4, 6, 5]
    assert all(q["level"] == "schwer" for q in qs if q.get("from_exam")), "die Altklausuraufgabe ist eine schwere"


# ================================================================ 7-8: gleicher Test fuer alle, 24 h nach Vorlesung
def test_same_test_for_all_participants(env):
    from app import db, weekly
    a = env.mark(36, user="anna")
    with env.conn() as c:
        weekly.release_marker(c, a["id"], user_id="anna", confirm=True)
    env.tick("2026-10-20T11:31:00")
    assert len(env.defs()) == 1
    did = env.defs()[0]["id"]
    with env.conn() as c:
        t1 = weekly.attempt_for(c, did, "anna"); t2 = weekly.attempt_for(c, did, "ben")
        q1 = db.row(c, "SELECT questions FROM tests WHERE id=?", (t1,))["questions"]
        q2 = db.row(c, "SELECT questions FROM tests WHERE id=?", (t2,))["questions"]
    assert t1 != t2 and q1 == q2
    assert len(env.fake.gen_prompts()) == 1, "nur einmal generiert"


def test_release_requires_explicit_confirmation(env):
    from app import weekly
    m = env.mark(36)
    with env.conn() as c:
        with pytest.raises(weekly.WeeklyError):
            weekly.release_marker(c, m["id"])
        assert weekly.coverage(c, MOD)["scope"] == "personal"


def test_publish_24h_after_lecture_end(env):
    env.mark(36)
    p = env.plans()
    assert not p
    env.tick("2026-10-20T11:29:00")
    p = env.plans()[0]
    assert p["lecture_end"] == "2026-10-19T11:30:00" and p["publish_at"] == "2026-10-20T11:30:00"
    assert p["status"] == "geplant" and not env.defs()
    env.tick("2026-10-20T11:30:00")
    assert env.plans()[0]["status"] == "veroeffentlicht"


# ================================================================ 9: verspaetete Uploads
def test_late_upload_waits_then_publishes(env):
    from app import db
    with env.conn() as c:
        c.execute("UPDATE modules SET expected_materials=? WHERE id=?", (json.dumps(["gruppenuebung"]), MOD))
    env.mark(36)
    env.tick("2026-10-20T11:31:00")
    p = env.plans()[0]
    assert p["status"] == "wartet" and json.loads(p["missing"]) == ["gruppenuebung"]
    env.add_file("gue2", "GÜ 2.pdf", "Gruppenübung", GUE)
    env.tick("2026-10-20T15:00:00")
    p = env.plans()[0]
    assert p["status"] == "veroeffentlicht"
    assert any("Gruppenübung" in t for t in [c for c in env.fake.gen_prompts()[0].splitlines() if c.startswith("[A")])


def test_missing_upload_published_at_deadline_with_gaps(env):
    with env.conn() as c:
        c.execute("UPDATE modules SET expected_materials=? WHERE id=?", (json.dumps(["gruppenuebung"]), MOD))
    env.mark(36)
    env.tick("2026-10-21T11:00:00")
    assert env.plans()[0]["status"] == "wartet"
    env.tick("2026-10-22T11:31:00")          # 24 h + 48 h nach Vorlesungsende
    p = env.plans()[0]
    assert p["status"] == "veroeffentlicht" and json.loads(p["missing"]) == ["gruppenuebung"]
    assert json.loads(env.defs()[0]["sources"])["missing"] == ["gruppenuebung"]


# ================================================================ 10-11: veroeffentlichte Tests bleiben, Nachtrag ohne Ranking-Einfluss
def test_published_test_unchanged_and_nachtrag_offered(env):
    from app import db
    env.mark(36)
    env.tick("2026-10-20T11:31:00")
    d0 = env.defs()[0]
    with env.conn() as c:
        with pytest.raises(Exception):
            c.execute("UPDATE wt_defs SET questions='[]' WHERE id=?", (d0["id"],))
    env.add_file("gue2", "GÜ 2.pdf", "Gruppenübung", GUE)
    r = env.tick("2026-10-21T09:00:00")
    assert len(r["nachtraege"]) == 1
    assert env.defs()[0]["questions"] == d0["questions"], "Original unveraendert"
    n = env.defs("nachtrag")[0]
    assert n["parent_id"] == d0["id"]
    assert not env.tick("2026-10-21T10:00:00")["nachtraege"], "kein zweiter Nachtrag fuer dasselbe Material"


def test_nachtrag_does_not_change_ranking(env):
    from app import db, weekly
    env.mark(36)
    env.tick("2026-10-20T11:31:00")
    d0 = env.defs()[0]
    with env.conn() as c:
        tid = weekly.attempt_for(c, d0["id"], "local")
        c.execute("UPDATE tests SET submitted_at='2026-10-20T13:00:00', score=80, max_score=100, duration_sec=1200 WHERE id=?", (tid,))
        before = weekly.ranking(c, d0["id"]); mod_before = weekly.module_ranking(c, MOD)
    env.add_file("gue2", "GÜ 2.pdf", "Gruppenübung", GUE)
    env.tick("2026-10-21T09:00:00")
    n = env.defs("nachtrag")[0]
    with env.conn() as c:
        nt = weekly.attempt_for(c, n["id"], "local")
        c.execute("UPDATE tests SET submitted_at='2026-10-21T10:00:00', score=5, max_score=20 WHERE id=?", (nt,))
        assert weekly.ranking(c, d0["id"]) == before
        assert weekly.module_ranking(c, MOD) == mod_before


def test_consistent_grading_for_mc(env):
    from app import weekly
    qs = [{"nr": 1, "type": "mc", "answer": "B zwei", "points": 10}, {"nr": 2, "type": "short", "answer": "x", "points": 10}]
    ai = {"per_question": [{"nr": 1, "points": 3}, {"nr": 2, "points": 25}], "total": 28}
    r = weekly.grade_consistent(qs, {"1": "B zwei", "2": "y"}, ai)
    assert r["per_question"][0]["points"] == 10 and r["per_question"][1]["points"] == 10 and r["total"] == 20


# ================================================================ 12-13: Marker bleiben erhalten, Dokumentaenderungen
def test_markers_survive_reopen_via_api(env, app):
    m = env.mark(36)
    st, _, b = asgi_call(app, "GET", f"/api/markers?file_id={LEC}")
    assert st == 200 and [x["page"] for x in json.loads(b)] == [36]
    st, _, b = asgi_call(app, "PATCH", f"/api/markers/{m['id']}", body=json.dumps({"page": 38}))
    assert st == 200 and json.loads(b)["page"] == 38
    st, _, b = asgi_call(app, "POST", "/api/markers", body=json.dumps({"file_id": LEC, "page": 30, "lecture_date": "2026-10-26"}))
    assert st == 400 and "Reihenfolge" in json.loads(b)["detail"]
    st, _, _ = asgi_call(app, "DELETE", f"/api/markers/{m['id']}")
    assert st == 200
    st, _, b = asgi_call(app, "GET", f"/api/markers?file_id={LEC}")
    assert json.loads(b) == []


def test_document_change_relocates_or_flags_marker(env):
    from app import db, weekly
    env.mark(36)
    pages = lecture_pages()
    env.add_file(LEC, "Prog1_Vorlesung.pdf", "Vorlesung", ["Neue Titelseite mit Organisatorischem und Terminen"] + pages, course="cv", chdate=1760100000)
    with env.conn() as c:
        ch = weekly.revalidate_markers(c, LEC)
        m = db.row(c, "SELECT * FROM lecture_markers")
    assert ch and m["page"] == 37 and not m["needs_review"]
    env.add_file(LEC, "Prog1_Vorlesung.pdf", "Vorlesung", [p.replace("Kennung", "Nr") for p in pages], course="cv", chdate=1760200000)
    with env.conn() as c:
        weekly.revalidate_markers(c, LEC)
        m = db.row(c, "SELECT * FROM lecture_markers")
        cov = weekly.coverage(c, MOD)
    assert m["needs_review"] == 1 and not cov["segments"] and cov["blocked"], "unsicherer Stoff zaehlt nicht"


# ================================================================ 14: Probeklausur nur freigegebener Stoff
def test_mock_exam_only_released_topics(env):
    from app import weekly
    env.mark(36)
    env.mark(62, day="2026-10-26")
    r = weekly.create_mock_exam(MOD, now=datetime.fromisoformat("2026-10-28T10:00:00"), log=lambda *_: None)
    gen = env.fake.gen_prompts()[-1]
    assert "PROBEKLAUSUR" in gen and "Feldelemente" not in gen and "Kennung063x" not in gen
    assert "WS25" not in gen, "Arrays-Altklausur nicht verwendet"
    assert r["def"]["kind"] == "probeklausur" and r["test_id"]
    with pytest.raises(weekly.WeeklyError):
        weekly.create_mock_exam(MOD, full=True, log=lambda *_: None)


# ================================================================ 15-16: Parallelitaet, fehlerhafte KI
def test_parallel_ticks_create_single_test(env):
    env.mark(36)
    errs = []

    def run():
        try:
            env.tick("2026-10-20T11:31:00")
        except Exception as e:  # noqa: BLE001
            errs.append(e)
    th = [threading.Thread(target=run) for _ in range(4)]
    [t.start() for t in th]; [t.join() for t in th]
    assert not errs
    assert len(env.defs()) == 1 and len(env.fake.gen_prompts()) == 1
    from app import db
    with env.conn() as c:
        assert db.row(c, "SELECT COUNT(*) n FROM tests WHERE def_id IS NOT NULL")["n"] == 1


@pytest.mark.parametrize("mode", ["garbage", "leak", "review_fail"])
def test_faulty_ai_output_never_published(env, mode):
    env.fake.mode = mode
    env.mark(36)
    r = env.tick("2026-10-20T11:31:00")
    p = env.plans()[0]
    assert r["failed"] and p["status"] == "fehlgeschlagen" and p["last_error"]
    assert not env.defs(), "keine ungepruefte Version gespeichert"
    from app import db
    with env.conn() as c:
        assert not db.row(c, "SELECT 1 FROM tests WHERE def_id IS NOT NULL")
    env.fake.mode = "good"
    env.tick("2026-10-20T12:00:00")
    assert env.plans()[0]["status"] == "veroeffentlicht", "naechster Lauf klappt"


# ================================================================ Extras
def test_overview_api_and_details(env, app):
    env.mark(36)
    env.tick("2026-10-20T11:31:00")
    st, _, b = asgi_call(app, "GET", f"/api/weekly/module/{MOD}")
    d = json.loads(b)
    assert st == 200 and d["weeks"][0]["status"] == "Test verfügbar"
    did = d["weeks"][0]["plans"][0]["def_id"]
    st, _, b = asgi_call(app, "GET", f"/api/weekly/defs/{did}")
    det = json.loads(b)
    assert det["question_count"] == 15 and det["pages"][0]["from"] == 1 and det["pages"][0]["to"] == 36
    tid = det["test"]["id"]
    st, _, b = asgi_call(app, "GET", f"/api/tests/{tid}")
    q = json.loads(b)["questions"][0]
    assert "answer" not in q and "steps" not in q and "refs" not in q, "Loesung erst nach Abgabe"


def test_old_auto_tests_skip_modules_with_markers(env, monkeypatch):
    from app import planner
    env.mark(36)
    called = []
    monkeypatch.setattr(planner, "create_test", lambda *a, **k: called.append(k) or 1)
    planner.create_weekly_tests(log=lambda *_: None)
    assert not any(k.get("module_id") == MOD for k in called)


# ================================================================ Regressionen aus der Selbstpruefung
def test_task_touching_future_topic_is_excluded_even_if_many_pages_match(env):
    """Viele gleich gute Treffer im behandelten Stoff duerfen spaeteren Stoff nicht aus der Pruefung draengen."""
    env.add_file("mix", "Übung_07.pdf", "Übungsblätter",
                 ["Aufgabe 1: Schreiben Sie eine while Schleife mit Schleifenzaehler und Abbruchbedingung, die alle Feldelemente "
                  "eines Array per Index durchlaeuft und die Feldlaenge und Arraygroesse ausgibt."])
    env.mark(36)
    env.mark(62, day="2026-10-26")
    env.tick("2026-10-27T11:31:00")
    _, w3 = env.plans()
    c3, _ = _ctx(env, w3["id"])
    assert not any("Übung_07" in c["label"] for c in c3["ok"]), "Arrays sind noch nicht behandelt"
    assert any("Übung_07" in x["label"] for x in c3["excluded"])


def test_identical_slides_from_older_semester_do_not_block(env):
    """Gleiche Folien in einer Kopie aus dem Vorsemester (ohne Marker) zaehlen als behandelt, neue Inhalte nicht."""
    old = [p.replace("Kennung", "Code") for p in lecture_pages()]
    env.add_file("lec-old", "Prog1_Vorlesung_WS24.pdf", "Vorlesung", old, course="cv")
    env.mark(36)
    env.tick("2026-10-20T11:31:00")
    c2, _ = _ctx(env, env.plans()[0]["id"])
    assert any("HÜ 1" in c["label"] for c in c2["ok"])
    assert not any("Übung_04" in c["label"] and "Aufgabe 2" in c["label"] for c in c2["ok"])


def test_marker_preview_on_existing_page_and_future_date(env):
    from app import weekly
    env.mark(36)
    with env.conn() as c:
        pv = weekly.marker_preview(c, LEC, 36, now=datetime.fromisoformat("2026-10-20T09:00:00"))
        assert pv["existing"] and pv["lecture_date"] == MON
        with pytest.raises(weekly.WeeklyError, match="Zukunft"):
            weekly.create_marker(c, LEC, 50, lecture_date="2026-11-30", now=datetime.fromisoformat("2026-10-20T09:00:00"))


def test_submitted_shared_attempt_cannot_be_deleted(env, app):
    from app import weekly
    env.mark(36)
    env.tick("2026-10-20T11:31:00")
    with env.conn() as c:
        tid = weekly.attempt_for(c, env.defs()[0]["id"], "local")
        c.execute("UPDATE tests SET submitted_at='2026-10-20T13:00:00', score=50, max_score=100 WHERE id=?", (tid,))
    st, _, _ = asgi_call(app, "DELETE", f"/api/tests/{tid}")
    assert st == 400

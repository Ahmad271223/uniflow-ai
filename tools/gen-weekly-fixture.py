"""Erzeugt packages/shared-contracts/fixtures/local-backend/weekly.json: Vorlesungs-Seitenmarker und gemeinsame
Wochentests (app/weekly.py) als Ablauf gegen den echten Python-Server, mit simulierter KI.

Aufgezeichnet werden je Schritt Anfrage und Antwort (Marker, Vorschau, Uebersicht, Testdetails, Versuch, Abgabe,
Rangliste, Fehlerfaelle), die Ergebnisse von `weekly.tick` und `weekly.create_mock_exam` mit fester Uhr, jeder
KI-Aufruf (System, Prompt, Antwort) und am Ende die Tabellen der Wochentests. Der Swift-Kern spielt denselben Ablauf
mit derselben Uhr ab (`WeeklyFixtureTests`): er muss dieselben Prompts senden, dieselben Antworten geben und dieselben
Zeilen schreiben (JSON-Texte byte-gleich).

Aufruf im Projektordner: python tools/gen-weekly-fixture.py [--check]
"""
from __future__ import annotations

import importlib.util
import json
import re
import sys
from datetime import date, datetime, timedelta

from schema_source import ROOT, SchemaSource, without_sync, write_or_check

OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "local-backend" / "weekly.json"
MOD = 1
LEC = "lec-prog1"


def _asgi():
    spec = importlib.util.spec_from_file_location("gen_local_backend", ROOT / "tools" / "gen-local-backend-fixture.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m.asgi


# ---------------------------------------------------------------- Testmaterial (wie tests/test_weekly.py)
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


EX_SHEET = [
    "Übungsblatt 4\nAufgabe 1: Deklarieren Sie eine Variable vom Datentyp Integer und eine vom Datentyp double. "
    "Erklaeren Sie Initialisierung, Zuweisung und Typumwandlung zwischen Integer und double.\n"
    "Aufgabe 2: Schreiben Sie eine while Schleife mit Schleifenzaehler und Abbruchbedingung. Ergaenzen Sie eine if Bedingung "
    "mit else Zweig und Vergleichsoperator in der Schleife.",
]
HUE = ["Hörsaalübung 1\nAufgabe 1: Welche Datentypen gibt es fuer ganze Zahlen und Kommazahlen? Integer, double, float, char. "
       "Zeigen Sie Deklaration und Initialisierung einer Variablen sowie eine Zuweisung."]
GUE = ["Gruppenübung 2\nAufgabe 1 (4 Punkte): Typumwandlung: Ein Ausdruck kombiniert Integer und double mit Operatoren. "
       "Welchen Datentyp hat das Ergebnis? Deklaration und Zuweisung der Variablen angeben."]
EXAMS = {
    "Klausur_WS23.pdf": ("Alte Klausuren/WS 23", "Klausur Programmieren WS 23\nAufgabe 4 (10 Punkte): Schleifen. Schreiben Sie eine for Schleife "
                         "mit Schleifenzaehler und eine while Schleife mit Abbruchbedingung, die die Summe berechnet."),
    "Klausur_WS22.pdf": ("Alte Klausuren/WS 22", "Klausur Programmieren WS 22\nAufgabe 1 (6 Punkte): Datentypen. Welcher Datentyp speichert ganze "
                         "Zahlen? Erklaeren Sie Integer, double, Deklaration und Initialisierung einer Variablen mit Zuweisung. Bearbeitungszeit: 90 Minuten"),
}


def seed() -> list[list]:
    """SQL in der Reihenfolge der Ausfuehrung (Swift fuehrt dieselben Anweisungen aus)"""
    out = [
        ["INSERT INTO modules(id, name, created_at, weekly_test, active, test_minutes) VALUES (?, 'Programmieren 1', '2026-10-01', 1, 1, 45)", [MOD]],
        ["INSERT INTO courses(id, title, kind, module_id, active, subject) VALUES ('cv', 'Programmieren 1', 'vorlesung', ?, 1, 'Programmieren 1')", [MOD]],
        ["INSERT INTO courses(id, title, kind, module_id, active, subject) VALUES ('cu', 'Übung Programmieren 1', 'uebung', ?, 1, 'Programmieren 1')", [MOD]],
        ["INSERT INTO course_events(module_id, title, kind, weekday, start_time, end_time, rrule, attend, source, created_at) "
         "VALUES (?, 'Programmieren 1', 'vorlesung', 0, '10:00', '11:30', 'weekly', 1, 'manual', '2026-10-01')", [MOD]],
    ]
    out += add_file(LEC, "Prog1_Vorlesung.pdf", "Vorlesung", lecture_pages(), course="cv")
    out += add_file("ex4", "Übung_04.pdf", "Übungsblätter", EX_SHEET)
    out += add_file("hue1", "HÜ 1.pdf", "Hörsaalübung", HUE)
    for i, (name, (folder, text)) in enumerate(EXAMS.items()):
        out += add_file(f"kl{i}", name, folder, [text])
    return out


def add_file(fid, name, folder, pages, course="cu", chdate=1760000000) -> list[list]:
    out = [["INSERT OR REPLACE INTO files(id, course_id, name, local_path, chdate, studip_folder, status, kind, first_seen) "
            "VALUES (?,?,?,?,?,?, 'neu', 'pdf', ?)", [fid, course, name, None, chdate, folder, "2026-10-01"]],
           ["DELETE FROM page_texts WHERE file_id=?", [fid]]]
    out += [["INSERT INTO page_texts(file_id, page, text, chdate) VALUES (?,?,?,?)", [fid, i + 1, t, chdate]] for i, t in enumerate(pages)]
    return out


# ---------------------------------------------------------------- Simulierte KI (wie FakeAI in tests/test_weekly.py)
def fake_answer(prompt: str) -> str:
    kind = re.search(r"### AUFTRAG: (\w+)", prompt)
    if not kind:                                            # Bewertung (app/ai.py grade_prompt)
        return json.dumps({"per_question": [{"nr": i, "points": 2.5, "feedback": "teilweise"} for i in range(1, 16)],
                           "total": 37.5, "max": 100, "feedback": "Solide Grundlagen."}, ensure_ascii=False)
    kind = kind.group(1)
    if kind == "PRUEFUNG":
        qs = json.loads(prompt.split("AUFGABEN:\n", 1)[1].split("\n\nAntworte als JSON", 1)[0])
        return json.dumps({"results": [{"nr": q["nr"], "ok": True, "solvable": True, "solution_correct": True, "issue": ""} for q in qs]})
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
             "points": round(100 / n, 2), "refs": refs, "from_exam": None, "exam_mode": None}
        if q["type"] == "mc":
            q["options"] = ["A eins", "B zwei", "C drei", "D vier"]; q["answer"] = "B zwei"
        if exam and ((n == 15 and i == 13) or (n != 15 and i == n)):
            q.update(from_exam=exam[0], exam_mode="angelehnt", refs=refs + [exam[0]])
        qs.append(q)
    return json.dumps({"title": "Testversion", "questions": qs, "duration_min": 90 if kind == "PROBEKLAUSUR" else None}, ensure_ascii=False)


def build() -> dict:
    src = SchemaSource()
    clock = {"now": datetime(2026, 10, 19, 12, 0, 0)}
    try:
        src.freeze(lambda: clock["now"].date(), lambda: clock["now"].isoformat(), lambda: clock["now"])
        from app import ai, planner, server, study, weekly

        class FrozenDateTime(datetime):
            @classmethod
            def now(cls, tz=None):
                return clock["now"]

        class FrozenDate(date):
            @classmethod
            def today(cls):
                d = clock["now"].date()
                return cls(d.year, d.month, d.day)

        for mod in (weekly, planner):
            mod.datetime = FrozenDateTime
        for mod in (weekly, study, planner):
            mod.date = FrozenDate
        src.fresh_db("weekly")
        ai_log = []

        def recorder(prompt, system=""):
            answer = fake_answer(prompt)
            ai_log.append({"system": system, "prompt": prompt, "answer": answer})
            return answer
        weekly._ask = recorder
        ai.ask = recorder
        asgi = _asgi()
        app = server.app
        sql = seed()
        with src.db.cursor() as c:
            for s, p in sql:
                c.execute(s, p)

        steps = []

        def at(when):
            clock["now"] = datetime.fromisoformat(when)

        def http(method, path, body=None):
            status, value = asgi(app, method, path, body)
            steps.append({"op": "http", "now": clock["now"].isoformat(), "method": method, "path": path, "body": body,
                          "status": status, "response": value})
            return value

        def tick(when):
            at(when)
            res = weekly.tick(clock["now"], log=lambda *_: None)
            steps.append({"op": "tick", "now": clock["now"].isoformat(), "result": res})
            return res

        def background(ai=True, busy=False):
            with src.db.cursor() as c:
                snap = weekly.background_snapshot(c, clock["now"])
            dec = weekly.background_decision(snap, clock["now"], ai=ai, busy=busy)
            steps.append({"op": "background", "now": clock["now"].isoformat(), "ai": ai, "busy": busy, "snapshot": snap, "decision": dec})
            return dec

        def run_sql(stmts):
            with src.db.cursor() as c:
                for s, p in stmts:
                    c.execute(s, p)
            steps.append({"op": "sql", "now": clock["now"].isoformat(), "sql": stmts})

        def add(fid, name, folder, pages, when):
            at(when)
            stmts = add_file(fid, name, folder, pages)
            with src.db.cursor() as c:
                for s, p in stmts:
                    c.execute(s, p)
            steps.append({"op": "sql", "now": clock["now"].isoformat(), "sql": stmts})

        # Woche 2: Vorschau, Marker bis Folie 36, Fehlerfaelle
        at("2026-10-19T12:00:00")
        http("GET", f"/api/markers/preview?file_id={LEC}&page=36&lecture_date=2026-10-19")
        http("POST", "/api/markers", {"file_id": LEC, "page": 36, "lecture_date": "2026-10-19"})
        http("POST", "/api/markers", {"file_id": LEC, "page": 36, "lecture_date": "2026-10-19"})
        http("POST", "/api/markers", {"file_id": LEC, "page": 500})
        http("POST", "/api/markers", {"page": 3})
        http("GET", "/api/markers/preview?file_id=lec-prog1&page=40&lecture_date=2026-10-30")
        http("GET", f"/api/markers?file_id={LEC}")
        http("GET", f"/api/weekly/module/{MOD}")
        background()                                             # noch kein Plan: nichts zu tun, kein Termin
        # vor der Veroeffentlichung (24 h nach Vorlesungsende) nichts, danach der Test
        tick("2026-10-20T11:00:00")
        background()                                             # Plan geplant fuer 11:30: naechster Termin 15:00
        run_sql([("INSERT OR REPLACE INTO settings(key, value) VALUES ('auto_tests', '0')", [])])
        background()                                             # aus
        run_sql([("INSERT OR REPLACE INTO settings(key, value) VALUES ('auto_tests', '1')", [])])
        at("2026-10-20T11:31:00")
        background(ai=False)                                     # faellig, aber keine KI
        background()                                             # faellig: laufen
        tick("2026-10-20T11:31:00")
        background()                                             # veroeffentlicht: kein Termin mehr
        http("GET", f"/api/weekly/module/{MOD}")
        http("GET", "/api/weekly/defs/1")
        tests = http("GET", "/api/tests") or []
        tid = next((t["id"] for t in tests if t.get("def_id")), 0)
        at("2026-10-20T12:00:00")
        test = http("GET", f"/api/tests/{tid}")
        answers = {str(q["nr"]): ("B zwei" if q.get("type") == "mc" else "meine Antwort") for q in (test or {}).get("questions", [])}
        at("2026-10-20T12:30:00")
        http("POST", f"/api/tests/{tid}/submit", {"answers": answers})
        http("POST", f"/api/tests/{tid}/submit", {"answers": answers})
        http("DELETE", f"/api/tests/{tid}")
        http("GET", f"/api/weekly/ranking?module_id={MOD}")
        http("GET", "/api/weekly/defs/1")
        # Woche 3: zweiter Marker, Plan, neue Gruppenuebung als Nachtrag
        at("2026-10-26T12:00:00")
        http("POST", "/api/markers", {"file_id": LEC, "page": 62, "lecture_date": "2026-10-26", "topic": "Schleifen"})
        http("POST", "/api/markers", {"file_id": LEC, "page": 50, "lecture_date": "2026-10-27"})
        # Testaufgabe im Lernplan (study.py) fuer die Lehrwoche 3: oeffnet den gemeinsamen Wochentest, vorher 409 mit Grund
        run_sql([("INSERT INTO study_packages(id, date, module_id, subject, title, week_no, planned_minutes, status, sort, generated, created_at) "
                  "VALUES (900, '2026-10-29', ?, 'Programmieren 1', 'Woche 3', 3, 45, 'geplant', 0, 1, '2026-10-26T12:00:00')", [MOD]),
                 ("INSERT INTO study_tasks(id, package_id, type, title, sort, est_minutes, status, created_at) "
                  "VALUES (900, 900, 'test', 'Gemeinsamer Wochentest Lehrwoche 3', 0, 45, 'geplant', '2026-10-26T12:00:00')", []),
                 ("INSERT INTO study_packages(id, date, module_id, subject, title, week_no, planned_minutes, status, sort, generated, created_at) "
                  "VALUES (901, '2026-10-29', ?, 'Programmieren 1', 'Woche 5', 5, 45, 'geplant', 0, 1, '2026-10-26T12:00:00')", [MOD]),
                 ("INSERT INTO study_tasks(id, package_id, type, title, sort, est_minutes, status, created_at) "
                  "VALUES (901, 901, 'test', 'Gemeinsamer Wochentest Lehrwoche 5', 0, 45, 'geplant', '2026-10-26T12:00:00')", [])])
        http("POST", "/api/tasks/900/start-test")
        http("POST", "/api/tasks/901/start-test")
        tick("2026-10-26T13:00:00")                              # Plan der Woche 3 angelegt, noch nicht faellig
        background()                                             # naechster Termin 27.10. 15:00
        http("POST", "/api/tasks/900/start-test")
        at("2026-10-27T11:31:00")
        background(busy=True)                                    # faellig, aber ein anderer Auftrag laeuft
        background()
        tick("2026-10-27T11:31:00")
        background()
        http("POST", "/api/tasks/900/start-test")              # beim Veroeffentlichen verknuepft
        # nach der Veroeffentlichung geplante Testaufgabe: der Versuch am gemeinsamen Test, Status in Bearbeitung
        run_sql([("INSERT INTO study_tasks(id, package_id, type, title, sort, est_minutes, status, created_at) "
                  "VALUES (902, 900, 'test', 'Gemeinsamer Wochentest Lehrwoche 3', 1, 45, 'geplant', '2026-10-27T11:31:00')", [])])
        http("POST", "/api/tasks/902/start-test")
        add("gue2", "GÜ 2.pdf", "Gruppenübung", GUE, "2026-10-28T09:00:00")
        tick("2026-10-28T10:00:00")
        http("POST", "/api/tasks/900/start-test")
        http("POST", "/api/tasks/900/start-test")
        http("GET", f"/api/weekly/module/{MOD}")
        http("POST", "/api/weekly/defs/2/attempt")
        http("POST", "/api/weekly/defs/99/attempt")
        # Marker aendern, freigeben, loeschen
        at("2026-10-28T11:00:00")
        markers = http("GET", f"/api/markers?module_id={MOD}") or []
        first = markers[0]["id"] if markers else 1
        http("PATCH", f"/api/markers/{first}", {"topic": "Variablen und Datentypen"})
        http("POST", f"/api/markers/{first}/release", {})
        http("POST", f"/api/markers/{first}/release", {"confirm": True})
        http("POST", f"/api/markers/{first}/release", {"confirm": True})
        http("DELETE", "/api/markers/9999")
        # Probeklausur ueber den markierten Stoff
        at("2026-10-28T12:00:00")
        mock = weekly.create_mock_exam(MOD, full=False, now=clock["now"], log=lambda *_: None)
        steps.append({"op": "mock", "now": clock["now"].isoformat(), "module_id": MOD, "full": False,
                      "result": {"test_id": mock["test_id"], "blueprint": mock["blueprint"], "reused": mock["reused"], "def_id": mock["def"]["id"]}})
        http("GET", f"/api/weekly/module/{MOD}")

        tables = {}
        with src.db.cursor() as c:
            for t, q in (("lecture_markers", "SELECT * FROM lecture_markers ORDER BY id"),
                         ("doc_index", "SELECT * FROM doc_index ORDER BY file_id"),
                         ("task_index", "SELECT * FROM task_index ORDER BY file_id, nr"),
                         ("wt_plans", "SELECT * FROM wt_plans ORDER BY id"),
                         ("wt_defs", "SELECT * FROM wt_defs ORDER BY id"),
                         ("study_tasks", "SELECT id, test_id, status FROM study_tasks ORDER BY id"),
                         ("tests", "SELECT id, subject, title, duration_min, questions, created_at, started_at, submitted_at, answers, "
                                   "score, max_score, feedback, module_id, week_no, auto, def_id, user_id, duration_sec FROM tests ORDER BY id")):
                rows = [dict(r) for r in c.execute(q).fetchall()]
                for r in rows:
                    r.pop("lock_token", None); r.pop("lock_until", None)
                tables[t] = rows
        cases = background_cases(weekly)
    finally:
        src.cleanup()
    return without_sync({"generator": "tools/gen-weekly-fixture.py", "module_id": MOD, "start": "2026-10-19T12:00:00",
                         "seed": sql, "steps": steps, "ai": ai_log, "tables": tables, "background_cases": cases})


def background_cases(weekly) -> list:
    """Erfundene Staende fuer `background_decision` ohne Datenbank: Termingrenzen, Monats- und Jahreswechsel, die
    Zeitumstellung (naive Ortszeit, daher ohne Sprung), Sperre, Versuche, Tageslimit, aus / keine KI / beschaeftigt."""
    def plan(pid=1, status="geplant", publish="2026-10-20T11:30:00", deadline=None, attempts=0, lock=None, reusable=False):
        return {"id": pid, "status": status, "publish_at": publish,
                "deadline_at": deadline or (datetime.fromisoformat(publish) + timedelta(hours=48)).isoformat(),
                "attempts": attempts, "lock_until": lock, "reusable": reusable}

    def snap(*plans, auto=True, limit=8, today=0):
        return {"auto_tests": auto, "daily_limit": limit, "today_defs": today, "plans": list(plans)}

    specs = [
        ("leer", "2026-10-20T10:00:00", snap()),
        ("genau_8_uhr_faellig", "2026-10-20T08:00:00", snap(plan(publish="2026-10-20T07:00:00"))),
        ("geplant_vor_termin", "2026-10-20T08:00:00", snap(plan())),
        ("publish_genau_auf_termin", "2026-10-20T09:00:00", snap(plan(publish="2026-10-20T15:00:00"))),
        ("publish_sekunde_nach_termin", "2026-10-20T09:00:00", snap(plan(publish="2026-10-20T15:00:01"))),
        ("nach_20_uhr", "2026-10-20T20:30:00", snap(plan(publish="2026-10-20T21:00:00"))),
        ("monatswechsel", "2026-10-31T19:00:00", snap(plan(publish="2026-10-31T20:30:00"))),
        ("jahreswechsel", "2026-12-31T21:00:00", snap(plan(publish="2026-12-31T22:00:00"))),
        ("zeitumstellung_oktober", "2026-10-24T22:00:00", snap(plan(publish="2026-10-25T01:30:00"))),
        ("zeitumstellung_maerz", "2026-03-28T23:00:00", snap(plan(publish="2026-03-29T02:30:00"))),
        ("faellig_sekunde_vor_termin", "2026-10-20T14:59:59", snap(plan(publish="2026-10-20T14:59:59"))),
        ("genau_termin_nicht_faellig", "2026-10-20T15:00:00", snap(plan(publish="2026-10-20T15:00:01"))),
        ("drei_versuche", "2026-10-20T12:00:00", snap(plan(status="fehlgeschlagen", attempts=3))),
        ("zwei_versuche", "2026-10-20T12:00:00", snap(plan(status="fehlgeschlagen", attempts=2))),
        ("sperre_laeuft", "2026-10-20T12:00:00", snap(plan(lock="2026-10-20T12:10:00"))),
        ("sperre_bis_termin", "2026-10-20T12:00:00", snap(plan(lock="2026-10-20T15:00:00"))),
        ("sperre_abgelaufen", "2026-10-20T12:00:00", snap(plan(lock="2026-10-20T11:50:00"))),
        ("sperre_genau_jetzt", "2026-10-20T12:00:00", snap(plan(lock="2026-10-20T12:00:00"))),
        ("wartend_vor_frist", "2026-10-21T09:00:00", snap(plan(status="wartet"))),
        ("wartend_frist_vorbei", "2026-10-23T09:00:00", snap(plan(status="wartet"))),
        ("limit_ohne_wiederverwendung", "2026-10-20T12:00:00", snap(plan(), today=8)),
        ("limit_mit_wiederverwendung", "2026-10-20T12:00:00", snap(plan(reusable=True), today=8)),
        ("limit_nicht_faellig", "2026-10-20T08:00:00", snap(plan(), today=8)),
        ("limit_eigene_grenze", "2026-10-20T12:00:00", snap(plan(), limit=2, today=2)),
        ("limit_eins_von_zwei_wiederverwendbar", "2026-10-20T12:00:00",
         snap(plan(1, publish="2026-10-20T11:00:00"), plan(2, publish="2026-10-20T11:00:00", reusable=True), today=8)),
        ("aus", "2026-10-20T12:00:00", snap(plan(), auto=False)),
        ("fremde_stati_zaehlen_nicht", "2026-10-20T12:00:00", snap(plan(status="veroeffentlicht"), plan(2, status="ersetzt"))),
        ("mehrere_plaene_kleinster_termin", "2026-10-20T12:00:00",
         snap(plan(1, publish="2026-10-21T09:00:00"), plan(2, publish="2026-10-20T16:00:00"))),
        ("faellig_und_spaeter", "2026-10-20T12:00:00", snap(plan(1, publish="2026-10-20T11:00:00"), plan(2, publish="2026-10-22T09:00:00"))),
        ("spaeter_und_faellig_reihenfolge", "2026-10-20T12:00:00",
         snap(plan(7, publish="2026-10-22T09:00:00"), plan(3, publish="2026-10-20T11:00:00"), plan(5, publish="2026-10-20T10:00:00"))),
    ]
    out = []
    for name, now, s in specs:
        for ai, busy in ((True, False), (False, False), (True, True)):
            out.append({"name": name, "now": now, "ai": ai, "busy": busy, "snapshot": s,
                        "decision": weekly.background_decision(s, datetime.fromisoformat(now), ai=ai, busy=busy)})
    return out


def main() -> int:
    check = "--check" in sys.argv[1:]
    data = build()
    ok = write_or_check(OUT, json.dumps(data, ensure_ascii=False, indent=1) + "\n", check)
    return 0 if ok or not check else 1


if __name__ == "__main__":
    sys.exit(main())

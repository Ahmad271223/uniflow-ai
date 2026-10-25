"""Erzeugt die Fixtures des lokalen Backends in packages/shared-contracts/fixtures/local-backend/.

- app-paths.json: alle /api/-Pfade, die die iPad-App aufruft (per grep in apps/apple/UniFlow), je mit einer
  Beispielanfrage, der Antwort von app/server.py bei leerer Datenbank (nur die Form: Typen und Schluessel, keine
  Werte) und dem Status, den das lokale Backend liefern soll. Der Swift-Kern (LocalBackendCoverageTests) schickt
  jede Anfrage an den lokalen Router und vergleicht. Eine lokal leere Liste gegen eine in Python gefuellte gilt
  als Abweichung, ausser sie steht in "expect.empty_lists" (mit Begruendung). "expect.values" sind Werte, die
  lokal exakt gleich sein muessen (z. B. die feste Dienste-Liste SERVICES aus app/server.py).
- settings-terms.json: eine Folge von Anfragen an GET/PUT /api/settings und /api/terms mit den Antworten von
  app/server.py und dem Inhalt der Tabelle settings danach (exakter Text wie db.set_setting ihn schreibt).
- timetable-free.json: freie Zeitfenster und Sperrzeiten aus GET /api/timetable/day und /week fuer mehrere
  Einstellungen (erfundene Werte) ohne Termine und Lernpakete, wie timetable.free_windows sie berechnet.
- library-files.json (S3): erfundene Datenbank mit Kursen, Dateien (auch auf der Platte), Ordnern und Notizen, eine
  Folge von Anfragen an Bibliothek, Kurse, Dateien, Datei-Inhalt, Notizen (Versionen, Konflikt), Bilder, Ordner,
  Notizbuecher und Dokument-Aktionen mit den Antworten von app/server.py und den Tabellen danach. Uhr und uuid4 sind
  eingefroren wie in den Swift-Tests (Frozen).
- studip-import.json (S3): mehrere Durchgaenge von studip_sync.run_sync ohne Netz und Playwright (Kurse, Dateilisten,
  Ordner und Downloads ersetzt, Einordnung classify erst mit S4) und die Tabellen courses, files, sync_log danach.

Der Server laeuft dabei nur gegen Dateien in einem Temp-Ordner (tools/schema_source.py), nie gegen data/.
Pfade mit Netzwerk, KI oder Zugangsdaten (Sync, QIS, Tests, /api/credentials, /api/services) werden nicht
aufgerufen; fuer sie steht die erwartete lokale Antwort in SAMPLES.
Aufruf im Projektordner: python tools/gen-local-backend-fixture.py [--check]
"""
from __future__ import annotations

import asyncio
import json
import os
import re
import shutil
import sys
from pathlib import Path

from schema_source import ROOT, SchemaSource, write_or_check

OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "local-backend"
APP = ROOT / "apps" / "apple" / "UniFlow"

# Aufrufe, deren Pfad nicht als Text im Quelltext steht
EXTRA = {
    "GET /api/assets/{}/{}": "UniFlow/Services/DocumentStore.swift (Bilder aus Notizen, src)",
}

# Beispielanfrage je Pfad. "python": False -> nicht gegen app/server.py ausfuehren (Netzwerk, KI, .env),
# dann ist "expect" Pflicht. "expect" ueberschreibt sonst den Status von Python, "reason" erklaert warum.
# "expect.empty_lists": Listen (Pfad ab "$"), die lokal bewusst leer bleiben, obwohl Python sie fuellt.
# "values": Schluessel der Antwort -> Name eines Werts in app.server, der lokal exakt gleich sein muss.
MP = "uniflow-fixture"
SAMPLES: dict[str, dict] = {
    "GET /api/dashboard": {"path": "/api/dashboard"},
    "GET /api/bg": {"path": "/api/bg"},
    "GET /api/sync/status": {"path": "/api/sync/status"},
    "POST /api/sync": {"path": "/api/sync?ai=false", "python": False,
                       "expect": {"status": 409, "reason": "Stud.IP-Abgleich laeuft auf dem iPad direkt (StudIPSync)"}},
    "GET /api/search": {"path": "/api/search?q=algebra"},
    "POST /api/files/mark-seen": {"path": "/api/files/mark-seen"},
    "GET /api/library": {"path": "/api/library"},
    "POST /api/folders": {"path": "/api/folders", "body": {"name": "Neuer Ordner"}},
    "PATCH /api/folders/{}": {"path": "/api/folders/1", "body": {"name": "x"}},
    "DELETE /api/folders/{}": {"path": "/api/folders/1"},
    "POST /api/notebooks": {"path": "/api/notebooks", "form": {"kind": "notebook", "title": "Notizbuch"}},
    "PATCH /api/library/files/{}": {"path": "/api/library/files/f1", "body": {"title": "Neu"}},
    "POST /api/files/{}/favorite": {"path": "/api/files/f1/favorite", "body": {"favorite": True}},
    "POST /api/files/{}/opened": {"path": "/api/files/f1/opened", "body": {}},
    "GET /api/files/{}/content": {"path": "/api/files/f1/content"},
    "GET /api/files/{}/pagetext": {"path": "/api/files/f1/pagetext?page=1"},
    "GET /api/assets/{}/{}": {"path": "/api/assets/f1/bild.png"},
    "GET /api/files/{}/annotations": {"path": "/api/files/f1/annotations"},
    "PUT /api/files/{}/annotations": {"path": "/api/files/f1/annotations?base_version=0", "body": {"version": 2, "pages": {}},
                                      "expect": {"status": 409, "reason": "Dokument fehlt in der Datenbank: Python 500 (Fremdschluessel), "
                                                 "lokal 409 ohne version, die App behaelt die Notizen im Journal"}},
    "POST /api/related": {"path": "/api/related", "body": {"file_id": "f1", "text": "Eigenwerte"}},
    "GET /api/modules": {"path": "/api/modules"},
    "GET /api/modules/{}": {"path": "/api/modules/1"},
    "POST /api/modules": {"path": "/api/modules", "body": {"name": "Testmodul"},
                          "expect": {"status": 409, "reason": "Module kommen mit S4"}},
    "PATCH /api/modules/{}": {"path": "/api/modules/1", "body": {"active": 1}},
    "POST /api/modules/auto-assign": {"path": "/api/modules/auto-assign"},
    "GET /api/courses": {"path": "/api/courses"},
    "PATCH /api/courses/{}": {"path": "/api/courses/k1", "body": {"kind": "uebung"}},
    "POST /api/courses/{}/module": {"path": "/api/courses/k1/module", "body": {"module_id": None}},
    "GET /api/calendar": {"path": "/api/calendar?start=2026-10-26&end=2026-11-01"},
    "GET /api/calendar/feasibility": {"path": "/api/calendar/feasibility"},
    "POST /api/calendar/generate": {"path": "/api/calendar/generate", "body": {"start": "2026-10-26", "days": 1}},
    "POST /api/calendar/suggest": {"path": "/api/calendar/suggest", "body": {"rescue": True}},
    "POST /api/calendar/apply": {"path": "/api/calendar/apply", "body": {"moves": []}},
    "GET /api/tasks/open": {"path": "/api/tasks/open"},
    "POST /api/tasks/skip": {"path": "/api/tasks/skip", "body": {"task_ids": []}},
    "POST /api/tasks/{}/status": {"path": "/api/tasks/1/status", "body": {"status": "erledigt"}},
    "PATCH /api/tasks/{}": {"path": "/api/tasks/1", "body": {"title": "x"}},
    "DELETE /api/tasks/{}": {"path": "/api/tasks/1"},
    "POST /api/tasks/{}/start-test": {"path": "/api/tasks/1/start-test", "python": False,
                                      "expect": {"status": 404, "reason": "Wochentests (KI) entfallen in V1"}},
    "POST /api/packages": {"path": "/api/packages", "body": {"date": "2026-10-26", "title": "Lernen"},
                           "expect": {"status": 409, "reason": "Lernpakete kommen mit S6"}},
    "GET /api/packages/{}": {"path": "/api/packages/1"},
    "PATCH /api/packages/{}": {"path": "/api/packages/1", "body": {"title": "x"}},
    "DELETE /api/packages/{}": {"path": "/api/packages/1"},
    "POST /api/packages/{}/tasks": {"path": "/api/packages/1/tasks", "body": {"title": "x"}},
    "GET /api/timetable/week": {"path": "/api/timetable/week?start=2026-10-26"},
    "GET /api/timetable/day": {"path": "/api/timetable/day?date=2026-10-26"},
    "GET /api/timetable/events": {"path": "/api/timetable/events"},
    "POST /api/timetable/events": {"path": "/api/timetable/events", "body": {"title": "Testvorlesung", "weekday": 0},
                                   "expect": {"status": 409, "reason": "Termine kommen mit S5"}},
    "PATCH /api/timetable/events/{}": {"path": "/api/timetable/events/1", "body": {"title": "x"}},
    "DELETE /api/timetable/events/{}": {"path": "/api/timetable/events/1"},
    "POST /api/timetable/attendance": {"path": "/api/timetable/attendance", "body": {"event_id": 1, "mode": "today_skip"}},
    "GET /api/timetable/event-materials/{}": {"path": "/api/timetable/event-materials/1?date=2026-10-26"},
    "GET /api/timetable/conflicts": {"path": "/api/timetable/conflicts"},
    "GET /api/timetable/auto-status": {"path": "/api/timetable/auto-status"},
    "POST /api/timetable/reslot": {"path": "/api/timetable/reslot", "body": {"dates": ["2026-10-26"]}},
    "POST /api/timetable/import/preview": {"path": "/api/timetable/import/preview", "form": {"source": "studip"}, "python": False,
                                           "expect": {"status": 409, "reason": "Import kommt mit S5"}},
    "POST /api/timetable/import/confirm": {"path": "/api/timetable/import/confirm", "body": {"entries": []},
                                           "expect": {"status": 409, "reason": "Import kommt mit S5"}},
    "GET /api/tests": {"path": "/api/tests"},
    "GET /api/tests/{}": {"path": "/api/tests/1"},
    "POST /api/tests/generate": {"path": "/api/tests/generate", "body": {"module_id": 1, "duration_min": 45}, "python": False,
                                 "expect": {"status": 404, "reason": "Wochentests (KI) entfallen in V1"}},
    "POST /api/tests/generate-week": {"path": "/api/tests/generate-week", "python": False,
                                      "expect": {"status": 404, "reason": "Wochentests (KI) entfallen in V1"}},
    "POST /api/tests/{}/submit": {"path": "/api/tests/1/submit", "body": {"answers": {}},
                                  "expect": {"status": 404, "reason": "Python 500 (Test nicht gefunden); lokal 404, Tests entfallen"}},
    "DELETE /api/tests/{}": {"path": "/api/tests/1"},
    "GET /api/flashcards": {"path": "/api/flashcards?due=true"},
    "POST /api/flashcards/{}/review": {"path": "/api/flashcards/1/review", "body": {"correct": True}},
    "DELETE /api/flashcards/{}": {"path": "/api/flashcards/1"},
    "POST /api/ai/tutor": {"path": "/api/ai/tutor", "body": {"mode": "explain"}, "python": False,
                           "expect": {"status": 404, "reason": "KI entfaellt in V1"}},
    "GET /api/settings": {"path": "/api/settings"},
    "PUT /api/settings": {"path": "/api/settings", "body": {"user_name": "Testperson"}},
    "GET /api/terms": {"path": "/api/terms"},
    "PUT /api/terms": {"path": "/api/terms", "body": {"name": "SoSe 2027", "start": "2027-04-01", "end": "2027-09-30"}},
    "GET /api/credentials": {"path": "/api/credentials", "python": False,
                             "expect": {"status": 200, "type": "object", "keys": ["password_set", "user"],
                                        "reason": "Zugaenge entfallen; Form wie server.py ohne .env"}},
    "PUT /api/credentials/{}": {"path": "/api/credentials/qis", "body": {"clear": True}, "python": False,
                                "expect": {"status": 404, "reason": "keine Zugangsdaten auf dem iPad"}},
    "GET /api/services": {"path": "/api/services", "python": False, "values": {"services": "SERVICES"},
                          "expect": {"status": 200, "type": "object", "keys": ["credentials", "qis", "services", "studip"],
                                     "reason": "Form wie server.py; liest dort die .env, darum nicht aufgerufen"}},
    "GET /api/grades": {"path": "/api/grades"},
    "POST /api/grades/sync": {"path": "/api/grades/sync", "python": False,
                              "expect": {"status": 404, "reason": "QIS auf dem iPad folgt (F4)"}},
    "GET /api/qis/documents/{}": {"path": "/api/qis/documents/1"},
}


# ----------------------------------------------------------------------------
# Pfade aus dem Swift-Quelltext
# ----------------------------------------------------------------------------

def _string_literal(text: str, start: int) -> tuple[str, int]:
    """Swift-Zeichenkette ab dem oeffnenden Anfuehrungszeichen; Interpolationen \\(...) werden zu {}."""
    i = start + 1
    out = []
    while i < len(text):
        c = text[i]
        if c == "\\" and i + 1 < len(text) and text[i + 1] == "(":
            depth, i = 1, i + 2
            while i < len(text) and depth:
                if text[i] == "(":
                    depth += 1
                elif text[i] == ")":
                    depth -= 1
                elif text[i] == '"':                      # Zeichenkette innerhalb der Interpolation
                    i = _string_literal(text, i)[1] - 1
                i += 1
            out.append("{}")
            continue
        if c == "\\":
            out.append(text[i:i + 2]); i += 2
            continue
        if c == '"':
            return "".join(out), i + 1
        out.append(c); i += 1
    raise ValueError("Zeichenkette nicht abgeschlossen")


def _call_args(text: str, pos: int) -> str:
    """Rest der Argumentliste bis zur schliessenden Klammer des Aufrufs (Zeichenketten uebersprungen)."""
    depth, i, start = 1, pos, pos
    while i < len(text) and depth:
        c = text[i]
        if c == '"':
            i = _string_literal(text, i)[1]
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        i += 1
    return text[start:i]


def app_calls() -> dict[str, list[str]]:
    """{"METHOD /api/...": [Dateien]} fuer alle Aufrufe in apps/apple/UniFlow."""
    calls: dict[str, set[str]] = {}
    for f in sorted(APP.rglob("*.swift")):
        text = f.read_text(encoding="utf-8")
        for m in re.finditer(r'"/api/', text):
            line = text[text.rfind("\n", 0, m.start()) + 1:m.start()]
            if line.lstrip().startswith("//"):
                continue
            path, end = _string_literal(text, m.start())
            shape = path.split("?", 1)[0]
            before = text[max(0, m.start() - 40):m.start()]
            args = _call_args(text, end)
            mm = re.search(r'method:\s*"([A-Z]+)"', args)
            if re.search(r"\.(form|upload)\(\s*$", before):
                method = "POST"
            else:
                method = mm.group(1) if mm else "GET"
            calls.setdefault(f"{method} {shape}", set()).add(str(f.relative_to(APP.parent)))
    for key, src in EXTRA.items():
        calls.setdefault(key, set()).add(src)
    return {k: sorted(v) for k, v in sorted(calls.items())}


# ----------------------------------------------------------------------------
# Aufrufe gegen app/server.py (ASGI direkt, ohne Netzwerk)
# ----------------------------------------------------------------------------

def asgi(app, method: str, path: str, body=None, form=None):
    p, _, q = path.partition("?")
    if form is not None:
        parts = [f'--{MP}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n' for k, v in form.items()]
        raw = ("".join(parts) + f"--{MP}--\r\n").encode()
        ctype = f"multipart/form-data; boundary={MP}"
    else:
        raw = json.dumps(body).encode() if body is not None else b""
        ctype = "application/json"
    headers = [(b"host", b"localhost"), (b"content-type", ctype.encode()), (b"content-length", str(len(raw)).encode())]
    scope = {"type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1", "method": method, "scheme": "http",
             "path": p, "raw_path": p.encode(), "query_string": q.encode(), "headers": headers,
             "client": ("127.0.0.1", 5000), "server": ("localhost", 80)}
    out = {"status": None, "body": b""}
    sent = {"done": False}

    async def receive():
        if not sent["done"]:
            sent["done"] = True
            return {"type": "http.request", "body": raw, "more_body": False}
        return {"type": "http.disconnect"}

    async def send(msg):
        if msg["type"] == "http.response.start":
            out["status"] = msg["status"]
        elif msg["type"] == "http.response.body":
            out["body"] += msg.get("body", b"")

    try:
        asyncio.run(app(scope, receive, send))
    except Exception:  # noqa: BLE001 - unbehandelte Ausnahme: Starlette hat 500 schon gesendet
        if out["status"] is None:
            out["status"] = 500
    try:
        value = json.loads(out["body"]) if out["body"] else None
    except json.JSONDecodeError:
        value = None
    return out["status"], value


def shape(v):
    """Form einer Antwort ohne Werte: Typ, bei Objekten die Schluessel, bei Listen die Form des ersten Eintrags."""
    if v is None:
        return {"type": "null"}
    if isinstance(v, bool):
        return {"type": "bool"}
    if isinstance(v, (int, float)):
        return {"type": "number"}
    if isinstance(v, str):
        return {"type": "string"}
    if isinstance(v, list):
        return {"type": "array", "item": shape(v[0]) if v else None}
    return {"type": "object", "keys": {k: shape(v[k]) for k in sorted(v)}}


def fresh_db(src: SchemaSource, name: str) -> None:
    path = src.tmp / f"{name}.db"
    for suffix in ("", "-wal", "-shm"):
        path.with_name(path.name + suffix).unlink(missing_ok=True)
    src.use_db(path)
    src.db.init_db()


def coverage(src: SchemaSource, app, server) -> dict:
    calls = app_calls()
    missing = sorted(set(calls) - set(SAMPLES))
    stale = sorted(set(SAMPLES) - set(calls))
    if missing or stale:
        raise SystemExit(f"SAMPLES passt nicht zur App: fehlt {missing}, veraltet {stale}")
    entries = []
    for key in calls:
        method, path_shape = key.split(" ", 1)
        s = SAMPLES[key]
        entry = {"method": method, "shape": path_shape, "sources": calls[key],
                 "request": {k: s[k] for k in ("path", "body", "form") if k in s}}
        if s.get("python", True):
            fresh_db(src, "leer")                          # jede Anfrage auf einer frischen, leeren Datenbank
            status, value = asgi(app, method, s["path"], s.get("body"), s.get("form"))
            entry["python"] = {"status": status, "shape": shape(value)}
        expect = dict(s.get("expect") or {})
        if "values" in s:
            expect["values"] = {k: getattr(server, name) for k, name in s["values"].items()}
        if "status" not in expect:
            expect["status"] = entry["python"]["status"]
        entry["expect"] = expect
        entries.append(entry)
    return {"generator": "tools/gen-local-backend-fixture.py", "count": len(entries), "paths": entries}


# Folge fuer settings/terms auf einer Datenbank; erfundene Werte
SETTINGS_STEPS = [
    ("GET", "/api/settings", None),
    ("PUT", "/api/settings", {"hours_per_day": 4.5, "free_days": [5, 6], "auto_plan": False, "user_name": "Testperson Ä",
                              "blocked_times": [{"weekday": 0, "start": "12:00", "end": "13:00", "title": "Mittag ü 😀"}],
                              "eigener_schluessel": None, "subjects_per_day": "x", "test_minutes": 30.0,
                              "travel_minutes": " 25 ", "x_int": 7, "x_float": 1e-7, "x_big": 1e16,
                              "x_obj": {"b": 1, "a": [True, None, 2.5, "\n\t\"\\"]}}),
    ("GET", "/api/settings", None),
    ("PUT", "/api/settings", {"lan_pin": "123456", "free_days": {"6": True}}),
    ("PUT", "/api/settings", {"free_days": [True, 6.0], "min_slot_minutes": "1_5", "hours_per_day": "1_0"}),
    ("PUT", "/api/settings", [1]),
    ("PUT", "/api/settings", None),
    ("PUT", "/api/settings", {"hours_per_day": "abc"}),
    ("GET", "/api/settings", None),
    ("GET", "/api/terms", None),
    ("PUT", "/api/terms", {"name": "SoSe 2027", "start": "2027-04-01", "end": "2027-09-30"}),
    ("PUT", "/api/terms", {"name": "", "start": "2027-10-01", "end": "2028-03-31"}),
    ("GET", "/api/terms", None),
]


def settings_terms(src: SchemaSource, app) -> dict:
    fresh_db(src, "einstellungen")
    steps = []
    for method, path, body in SETTINGS_STEPS:
        status, value = asgi(app, method, path, body)
        # "raw": genau die gesendeten Bytes (4.0 bleibt float; JSONValue in Swift kennt den Unterschied nicht)
        steps.append({"method": method, "path": path, "body": body, "raw": json.dumps(body) if body is not None else None,
                      "status": status,
                      "response": value})
    import sqlite3
    conn = sqlite3.connect(src.db.DB_PATH)
    try:
        rows = [[k, v] for k, v in conn.execute("SELECT key, value FROM settings ORDER BY key")]
    finally:
        conn.close()
    return {"generator": "tools/gen-local-backend-fixture.py", "steps": steps, "settings_rows": rows}


# Freie Zeitfenster ohne Termine und Lernpakete; erfundene Einstellungen. Woche ab Montag, 26.10.2026.
FREE_START = "2026-10-26"
FREE_SCENARIOS = [
    ("Standard", None),
    ("Sperrzeiten", {"blocked_times": [
        {"weekday": 0, "start": "12:00", "end": "13:00", "title": "Mittag"},
        {"weekday": 0, "start": "12:30", "end": "14:00"},                      # ueberlappend
        {"weekday": 1, "start": "07:00", "end": "09:00"},                      # vor Lernbeginn
        {"weekday": 2, "start": "20:30", "end": "22:00"},                      # ueber Lernende hinaus
        {"weekday": 3, "start": "08:00", "end": "08:20"},
        {"weekday": "4", "start": "10:00", "end": "11:00"},                    # Wochentag als Text
        {"weekday": 4, "start": "11:20", "end": "12:00"},                      # Luecke unter min_slot
        {"weekday": 5, "start": None, "end": "09:00"},                         # None zaehlt als 00:00
        {"weekday": 6, "start": "08:00", "end": "21:00"},                      # ganzer Tag gesperrt
    ]}),
    ("Lernzeit und Mindestlaenge", {"learn_start": "09:15", "learn_end": "18:45", "min_slot_minutes": 45,
                                    "blocked_times": [{"weekday": 0, "start": "10:00", "end": "10:50"},
                                                      {"weekday": 0, "start": "11:30", "end": "12:15:00"},
                                                      {"weekday": 2, "start": "17:30", "end": "18:00"}]}),
    ("leere Lernzeit", {"learn_start": "07:00", "learn_end": "07:00"}),
    ("Ende vor Beginn", {"learn_start": "20:00", "learn_end": "10:00",
                         "blocked_times": [{"weekday": 0, "start": "12:00", "end": "13:00"}]}),
]


def timetable_free(src: SchemaSource, app) -> dict:
    from datetime import date, timedelta
    scenarios = []
    for name, body in FREE_SCENARIOS:
        fresh_db(src, "frei")
        if body is not None:
            status, _ = asgi(app, "PUT", "/api/settings", body)
            assert status == 200, (name, status)
        status, week = asgi(app, "GET", f"/api/timetable/week?start={FREE_START}")
        assert status == 200, (name, status, week)
        days = []
        for i in range(7):
            d = (date.fromisoformat(FREE_START) + timedelta(days=i)).isoformat()
            status, day = asgi(app, "GET", f"/api/timetable/day?date={d}")
            assert status == 200, (name, d, status)
            wd = week["days"][i]
            assert wd["date"] == d and wd["free"] == day["free"] and wd["blocked"] == day["blocked"], (name, d)
            days.append({"date": d, "free": day["free"], "blocked": day["blocked"]})
        scenarios.append({"name": name, "settings": body, "raw": json.dumps(body) if body is not None else None,
                          "learn_start": week["learn_start"], "learn_end": week["learn_end"], "days": days})
    return {"generator": "tools/gen-local-backend-fixture.py", "start": FREE_START, "scenarios": scenarios}


# ----------------------------------------------------------------------------
# S3: Bibliothek, Dateien, Notizen (erfundene Datenbank, eingefrorene Uhr und Kennungen)
# ----------------------------------------------------------------------------

FROZEN = "2026-10-25T14:30:05"           # Uhr der Swift-Tests (UniFlowClock.fixed(berlin:))
STUDIP_BASE_TEST = "https://studip.test"


def tiny_pdf(pages: int, marker: str) -> bytes:
    """Kleine gueltige PDF mit leeren A4-Seiten (pypdf liest sie, Swift zaehlt /Type /Page)."""
    objs = ["<< /Type /Catalog /Pages 2 0 R >>",
            f"<< /Type /Pages /Kids [{' '.join(f'{3 + i} 0 R' for i in range(pages))}] /Count {pages} >>"]
    objs += ["<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] >>"] * pages
    objs.append(f"<< /Title ({marker}) >>")
    out = b"%PDF-1.4\n"
    offsets = []
    for n, o in enumerate(objs, 1):
        offsets.append(len(out))
        out += f"{n} 0 obj\n{o}\nendobj\n".encode()
    xref = len(out)
    out += f"xref\n0 {len(objs) + 1}\n0000000000 65535 f \n".encode()
    out += b"".join(f"{off:010d} 00000 n \n".encode() for off in offsets)
    out += f"trailer\n<< /Size {len(objs) + 1} /Root 1 0 R /Info {len(objs)} 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    return out


# 1x1 Pixel, PNG
PNG = bytes.fromhex("89504e470d0a1a0a0000000d4948445200000001000000010806000000"
                    "1f15c4890000000d49444154789c6360f8cfc0f01f0005fe02fea72c5c"
                    "6d0000000049454e44ae426082")


def hexid(n: int) -> str:
    """n-te eingefrorene Kennung (uuid4().hex): 8 Hex-Ziffern Zaehler, 24 Nullen"""
    return f"{n:08x}" + "0" * 24


class Frozen:
    """Uhr (db.now_iso, datetime.now in server.py, study.today) und uuid4 wie in den Swift-Tests: Kennung n (ab 1)
    ist hexid(n), die Zaehlung vorn, damit auch "u" + hex[:23] eindeutig bleibt (LocalContext.newHex).
    Zeitzone Europe/Berlin fuer datetime.timestamp()."""

    def __init__(self, server, now: str = FROZEN):
        self.server, self.now = server, now

    def __enter__(self):
        import itertools
        import time
        import uuid
        from datetime import date, datetime
        from app import db, study
        self.saved = (os.environ.get("TZ"), db.now_iso, self.server.datetime, study.today, uuid.uuid4)
        os.environ["TZ"] = "Europe/Berlin"
        time.tzset()
        frozen = datetime.fromisoformat(self.now)

        class FrozenDateTime(datetime):
            @classmethod
            def now(cls, tz=None):
                return frozen if tz is None else frozen.astimezone(tz)

        counter = itertools.count(1)
        db.now_iso = lambda: self.now
        self.server.datetime = FrozenDateTime
        study.today = lambda: date.fromisoformat(self.now[:10])
        uuid.uuid4 = lambda: uuid.UUID(hex=hexid(next(counter)))
        return self

    def __exit__(self, *exc):
        import time
        import uuid
        from app import db, study
        tz, db.now_iso, self.server.datetime, study.today, uuid.uuid4 = self.saved
        if tz is None:
            os.environ.pop("TZ", None)
        else:
            os.environ["TZ"] = tz
        time.tzset()


def asgi_raw(app, method: str, path: str, raw: bytes = b"", ctype: str = "application/json"):
    """Wie asgi(), aber mit rohem Inhalt und Kopfzeilen der Antwort: (status, {kopf: wert}, bytes)."""
    from urllib.parse import unquote
    p, _, q = path.partition("?")
    headers = [(b"host", b"localhost"), (b"content-type", ctype.encode()), (b"content-length", str(len(raw)).encode())]
    scope = {"type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1", "method": method, "scheme": "http",
             "path": unquote(p), "raw_path": p.encode(), "query_string": q.encode(), "headers": headers,
             "client": ("127.0.0.1", 5000), "server": ("localhost", 80)}
    out = {"status": None, "headers": {}, "body": b""}
    sent = {"done": False}

    async def receive():
        if not sent["done"]:
            sent["done"] = True
            return {"type": "http.request", "body": raw, "more_body": False}
        return {"type": "http.disconnect"}

    async def send(msg):
        if msg["type"] == "http.response.start":
            out["status"] = msg["status"]
            out["headers"] = {k.decode().lower(): v.decode("latin-1") for k, v in msg.get("headers", [])}
        elif msg["type"] == "http.response.body":
            out["body"] += msg.get("body", b"")

    try:
        asyncio.run(app(scope, receive, send))
    except Exception:  # noqa: BLE001 - unbehandelte Ausnahme: Starlette hat 500 schon gesendet
        if out["status"] is None:
            out["status"] = 500
    return out["status"], out["headers"], out["body"]


def multipart(fields: dict, files: dict | None = None) -> tuple[bytes, str]:
    """multipart/form-data: Textfelder in Reihenfolge, Dateien als {feld: (name, typ, bytes)}"""
    raw = b""
    for k, v in fields.items():
        raw += f'--{MP}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode()
    for k, (name, ctype, data) in (files or {}).items():
        raw += (f'--{MP}\r\nContent-Disposition: form-data; name="{k}"; filename="{name}"\r\n'
                f"Content-Type: {ctype}\r\n\r\n").encode() + data + b"\r\n"
    raw += f"--{MP}--\r\n".encode()
    return raw, f"multipart/form-data; boundary={MP}"


LIB_ANN_F2 = {"version": 2, "zoom": 1.2, "pages": {"p1": {"objects": [
    {"id": "s1", "type": "stroke", "tool": "pen", "points": [10, 20.5, 30.25, 40], "width": 2.0, "note": "Grüße ✓"}]}},
    "pageOrder": [{"key": "p1", "type": "pdf", "index": 1}]}
LIB_ANN_U1 = {"version": 2, "zoom": 1.2, "pages": {"b1": {"objects": []}},
              "pageOrder": [{"key": "b1", "type": "blank", "template": "grid", "w": 595, "h": 842}], "bookmarks": [], "outline": []}


def _course(cid, title, *, number=None, semester="WiSe 2026/27", subject=None, kind=None, active=1):
    return {"id": cid, "title": title, "number": number, "semester": semester, "subject": subject, "kind": kind,
            "active": active, "test_minutes": 90, "created_at": "2026-10-20T09:00:00"}


def _file(fid, cid, name, chdate, *, mime="application/pdf", local=True, kind="pdf", status="neu", seen=0, folder="", **extra):
    row = {"id": fid, "course_id": cid, "name": name, "size": 100 + len(name), "mime": mime, "author": None, "chdate": chdate,
           "download_url": f"{STUDIP_BASE_TEST}/jsonapi.php/v1/file-refs/{fid}/content",
           "local_path": f"studip/files/{fid}/{name}" if local else None,
           "downloaded_at": "2026-10-20T10:00:00" if local else None,
           "first_seen": f"2026-10-{20 + chdate % 5:02d}T10:00:{chdate % 60:02d}",
           "status": status, "seen_by_user": seen, "kind": kind, "studip_folder": folder}
    row.update(extra)
    return row


# Erfundene Datenbank: Kurse wie nach dem Abgleich (ohne Fach, S3) und wie vom PC (mit Fach, fuer ensure_modules)
LIB_SEED = {
    "courses": [
        _course("k1", "Testkurs Algebra", number="T-101"),
        _course("k2", "Übung zu Testkurs Physik"),
        _course("k3", "Testkurs Alt", semester="SoSe 2026", active=0),
        _course("k4", "Testfach Mechanik Vorlesung", subject="Testfach Mechanik", kind="vorlesung"),
        _course("k5", "Testfach Mechanik Übung", subject="Testfach Mechanik", kind="uebung"),
        _course("k6", "Testbegrüßung", subject="Testbegrüßung", kind="sonstiges"),
    ],
    "folders": [
        {"id": 1, "name": "Testordner B", "parent_id": None, "module_id": None, "color": "#336699", "created_at": "2026-10-21T10:00:00"},
        {"id": 2, "name": "Testordner A", "parent_id": 1, "module_id": None, "color": None, "created_at": "2026-10-21T10:01:00"},
        {"id": 3, "name": "Unterordner", "parent_id": 2, "module_id": None, "color": None, "created_at": "2026-10-21T10:02:00"},
    ],
    "files": [
        _file("f1", "k1", "Folien 1.pdf", 1792400011),
        _file("f2", "k1", "Blatt 2.pdf", 1792500012, status="gelesen", seen=1, folder="Übungen", favorite=1,
              last_opened="2026-10-22T08:00:00", folder_id=2),
        _file("f3", "k2", "notizen.txt", 1792300013, mime=None, kind="file"),
        _file("f4", "k2", "seite.html", 1792200014, mime="text/html", kind="file"),
        _file("f5", "k1", "Grafik ä.png", 1792100015, mime="image/png", kind="image"),
        _file("f6", "k1", "Nicht geladen.pdf", 1792000016, local=False),
        _file("f7", "k3", "Alt.pdf", 1791900017),
        _file("f8", "k2", "Fehlt.pdf", 1791800018),
        _file("f9", "k4", "Mechanik VL01.pdf", 1791700019, folder="Vorlesung"),
        _file("f10", "k5", "Mechanik Blatt 1.pdf", 1791600020, folder="Übung"),
        _file("f11", "k6", "Begrüßung.pdf", 1791500021),
        {"id": "u1", "course_id": "__user__", "name": "Mein Heft", "size": 0, "mime": None, "author": "Ich", "chdate": 1791400022,
         "download_url": "", "local_path": None, "downloaded_at": "2026-10-21T11:00:00", "first_seen": "2026-10-21T11:00:00",
         "status": "gelesen", "seen_by_user": 1, "kind": "notebook", "title": "Mein Heft", "folder_id": 1},
        {"id": "u2", "course_id": "__user__", "name": "Eigenes Skript.pdf", "size": 0, "mime": "application/pdf", "author": "Ich",
         "chdate": 1791300023, "download_url": "", "local_path": "files/Eigene Dokumente/u2.pdf", "downloaded_at": "2026-10-21T12:00:00",
         "first_seen": "2026-10-21T12:00:00", "status": "gelesen", "seen_by_user": 1, "kind": "pdf", "title": "Eigenes Skript",
         "page_count": 2},
    ],
    "annotations": [
        {"file_id": "f2", "data": json.dumps(LIB_ANN_F2, ensure_ascii=False), "updated_at": "2026-10-22T09:00:00", "version": 3},
        {"file_id": "u1", "data": json.dumps(LIB_ANN_U1), "updated_at": "2026-10-21T11:00:00", "version": 1},
    ],
    "annotation_versions": [
        {"file_id": "f2", "version": v, "data": json.dumps(LIB_ANN_F2, ensure_ascii=False), "created_at": f"2026-10-22T0{6 + v}:00:00"}
        for v in (1, 2, 3)
    ],
    "sync_log": [
        {"started_at": "2026-10-24T08:00:00", "finished_at": "2026-10-24T08:01:00", "ok": 1, "new_files": 3,
         "message": "3 neue/geaenderte Dateien"},
    ],
}

# Dateien auf der Platte (relativ zum Datenordner bzw. App-Container)
LIB_DISK = {
    "studip/files/f1/Folien 1.pdf": tiny_pdf(1, "Folien 1"),
    "studip/files/f2/Blatt 2.pdf": tiny_pdf(2, "Blatt 2"),
    "studip/files/f3/notizen.txt": "Notizen äöü\n".encode(),
    "studip/files/f4/seite.html": b"<html><script>alert(1)</script></html>",
    "studip/files/f5/Grafik ä.png": PNG,
    "studip/files/f7/Alt.pdf": tiny_pdf(1, "Alt"),
    "studip/files/f9/Mechanik VL01.pdf": tiny_pdf(1, "VL01"),
    "studip/files/f10/Mechanik Blatt 1.pdf": tiny_pdf(1, "Blatt 1"),
    "studip/files/f11/Begrüßung.pdf": tiny_pdf(1, "Begruessung"),
    "files/Eigene Dokumente/u2.pdf": tiny_pdf(2, "Eigenes Skript"),
}

# Notizen mit Umlauten, Ersatzpaar, Kommazahlen, doppeltem Schluessel (gespeicherter Text wie json.dumps)
ANN_BODY = ('{"version": 2, "zoom": 1.0, "pages": {"p1": {"objects": [{"id": "a", "type": "stroke", "points": [1, 2.5, 1e-7, 30], '
            '"text": "Ü \\u00e4 \\ud83d\\ude00 \\"x\\"\\n", "w": 2.0}]}}, "pageOrder": [{"key": "p1", "type": "pdf", "index": 1}], '
            '"doppelt": 1, "doppelt": 2}')


def library_steps(hexid):
    """Folge der Anfragen; `hexid(n)` ist die n-te Kennung (uuid4().hex), z. B. fuer hochgeladene Bilder."""
    pdf3 = tiny_pdf(3, "Import")
    J = lambda b: json.dumps(b, ensure_ascii=False).encode()          # noqa: E731
    svg = b"<svg xmlns='http://www.w3.org/2000/svg'/>"
    steps = [
        ("GET", "/api/library", None), ("GET", "/api/courses", None), ("GET", "/api/files", None),
        ("GET", "/api/files?course_id=k1", None), ("GET", "/api/files?subject=Testfach%20Mechanik", None),
        ("GET", "/api/files?course_id=", None),
        ("GET", "/api/files/f1", None), ("GET", "/api/files/f6", None), ("GET", "/api/files/f8", None),
        ("GET", "/api/files/gibtsnicht", None),
        ("GET", "/api/files/f1/content", None), ("GET", "/api/files/f3/content", None), ("GET", "/api/files/f4/content", None),
        ("GET", "/api/files/f5/content", None), ("GET", "/api/files/f6/content", None), ("GET", "/api/files/f8/content", None),
        ("GET", "/api/files/u2/content", None), ("GET", "/api/files/u1/content", None),
        ("PATCH", "/api/files/f1", J({"status": "gelesen"})), ("PATCH", "/api/files/f3", J({"status": "kaputt", "difficulty": 4})),
        ("PATCH", "/api/files/gibtsnicht", J({"status": "neu"})),
        ("POST", "/api/files/f1/opened", b""), ("POST", "/api/files/f1/opened", J({})),
        ("POST", "/api/files/f1/opened", J({"last_page": "7"})),
        ("POST", "/api/files/f2/favorite", J({"favorite": 0})), ("POST", "/api/files/f1/favorite", J({"favorite": "ja"})),
        ("GET", "/api/dashboard", None), ("POST", "/api/files/mark-seen", None), ("GET", "/api/dashboard", None),
        ("GET", "/api/sync/status", None),
        ("GET", "/api/files/f1/annotations", None),
        ("PUT", "/api/files/f1/annotations?base_version=0", ANN_BODY.encode()),
        ("GET", "/api/files/f1/annotations", None),
        ("PUT", "/api/files/f1/annotations?base_version=0", J({"version": 2, "pages": {}})),
        ("PUT", "/api/files/f1/annotations?base_version=1", J({"version": 2, "pages": {"p1": {"objects": []}}, "x": 1.5})),
        ("PUT", "/api/files/f1/annotations", J({"version": 2, "pages": {}, "ohne": "Basis"})),
        ("GET", "/api/files/f1/annotations/versions", None),
        ("POST", "/api/files/f1/annotations/restore/1", None), ("POST", "/api/files/f1/annotations/restore/99", None),
        ("GET", "/api/files/f1/annotations", None),
        ("PUT", "/api/files/gibtsnicht/annotations?base_version=0", J({"version": 2, "pages": {}})),
        ("PUT", "/api/files/f1/annotations?base_version=abc", J({"version": 2, "pages": {}})),
        ("PUT", "/api/files/f1/annotations", J([1])),
    ]
    steps += [("PUT", "/api/files/f2/annotations", J({"version": 2, "pages": {}, "n": i})) for i in range(31)]
    steps += [
        ("GET", "/api/files/f2/annotations/versions", None), ("GET", "/api/files/f2/annotations", None),
        ("POST", "/api/files/f1/assets", ({}, {"upload": ("bild.png", "image/png", PNG)})),
        ("GET", f"/api/assets/f1/{hexid(1)}.png", None),
        ("POST", "/api/files/f1/assets", ({}, {"upload": ("skizze.SVG", "image/svg+xml", svg)})),
        ("GET", f"/api/assets/f1/{hexid(2)}.svg", None),
        ("POST", "/api/files/f1/assets", ({}, {"upload": ("x.exe", "application/octet-stream", b"MZ")})),
        ("POST", "/api/files/a.b/assets", ({}, {"upload": ("bild.png", "image/png", PNG)})),
        ("POST", "/api/files/f1/assets", ({"kein": "bild"}, None)),
        ("GET", "/api/assets/f1/kaputt%20name.png", None), ("GET", "/api/assets/f1/fehlt.png", None),
        ("GET", "/api/assets/a.b/fehlt.png", None),
        ("POST", "/api/folders", J({"name": "Neu C", "color": "#aa0000"})), ("POST", "/api/folders", J({})),
        ("PATCH", "/api/folders/4", J({"name": "Umbenannt", "parent_id": 1})), ("PATCH", "/api/folders/999", J({"name": "x"})),
        ("DELETE", "/api/folders/2", None), ("PATCH", "/api/folders/abc", J({"name": "x"})),
        ("POST", "/api/notebooks", ({"kind": "notebook", "title": "Heft Ü", "template": "lined", "folder_id": "1"}, None)),
        ("POST", "/api/notebooks", ({"kind": "whiteboard", "title": ""}, None)),
        ("POST", "/api/notebooks", ({"kind": "notebook", "title": "Modulheft", "module_id": "1"}, None)),
        ("POST", "/api/notebooks", ({"kind": "notebook", "title": "Modulheft 2", "module_id": "1"}, None)),
        ("POST", "/api/notebooks", ({"kind": "pdf", "title": "Import"}, {"upload": ("skript.pdf", "application/pdf", pdf3)})),
        ("POST", "/api/notebooks", ({"kind": "pdf"}, {"upload": ("kaputt.pdf", "application/pdf", b"kein pdf")})),
        ("POST", "/api/notebooks", ({"kind": "image"}, {"upload": ("foto.bmp", "image/bmp", b"BM")})),
        ("POST", "/api/notebooks", ({"kind": "image", "title": "Foto"}, {"upload": ("foto.png", "image/png", PNG)})),
        ("PATCH", "/api/library/files/f1", J({"title": "Neuer Titel", "folder_id": 1})),
        ("PATCH", "/api/library/files/f3", J({"trash": True})), ("PATCH", "/api/library/files/f4", J({"trash": 1})),
        ("PATCH", "/api/library/files/f4", J({"restore": True})),
        # Kennung 11: Kopie von u2 (davor zwei Bilder und acht Notizbuch-Anfragen); sie teilt die PDF-Datei mit u2
        ("PATCH", "/api/library/files/u2", J({"duplicate": True})),
        ("PATCH", f"/api/library/files/u{hexid(11)[:23]}", J({"delete_forever": True})),
        ("PATCH", "/api/library/files/f1", J({"title": "Nicht gespeichert", "delete_forever": True})),
        ("PATCH", "/api/library/files/u1", J({"duplicate": True})),
        ("PATCH", "/api/courses/k2", J({"kind": "uebung", "test_minutes": 60.5, "foo": 1})),
        ("PATCH", "/api/courses/k1", J({"active": False})), ("PATCH", "/api/courses/gibtsnicht", J({"kind": "x"})),
        ("GET", "/api/library", None), ("GET", "/api/courses", None), ("GET", "/api/files", None),
    ]
    return steps


def _strip(v, prefix: str):
    """Absolute Pfade des Temp-Ordners entfernen (lokal stehen Pfade relativ zum Container)"""
    if isinstance(v, str):
        return v.replace(prefix, "")
    if isinstance(v, list):
        return [_strip(x, prefix) for x in v]
    if isinstance(v, dict):
        return {k: _strip(x, prefix) for k, x in v.items()}
    return v


def _seed(conn, seed: dict, data_dir: Path) -> None:
    for table, rows in seed.items():
        for r in rows:
            r = dict(r)
            if r.get("local_path"):
                r["local_path"] = str(data_dir / r["local_path"])
            conn.execute(f"INSERT INTO {table}({', '.join(r)}) VALUES ({', '.join('?' * len(r))})", tuple(r.values()))


def _tables(conn, prefix: str) -> dict:
    q = {"files": "SELECT * FROM files ORDER BY id", "courses": "SELECT * FROM courses ORDER BY id",
         "folders": "SELECT * FROM folders ORDER BY id", "modules": "SELECT * FROM modules ORDER BY id",
         "annotations": "SELECT file_id, data, updated_at, version FROM annotations ORDER BY file_id",
         "annotation_versions": "SELECT file_id, version, data, created_at FROM annotation_versions ORDER BY file_id, version"}
    out = {}
    for name, sql in q.items():
        cur = conn.execute(sql)
        cols = [d[0] for d in cur.description]
        out[name] = _strip([dict(zip(cols, row)) for row in cur.fetchall()], prefix)
    return out


def library_files(src: SchemaSource, server) -> dict:
    import base64
    import mimetypes
    import sqlite3
    data_dir = Path(os.environ["LERNAPP_DATA_DIR"])
    for sub in ("studip", "assets", "files/Eigene Dokumente"):
        shutil.rmtree(data_dir / sub, ignore_errors=True)
    with Frozen(server):
        fresh_db(src, "bibliothek")
        conn = sqlite3.connect(src.db.DB_PATH)
        conn.execute("PRAGMA foreign_keys=ON")
        _seed(conn, LIB_SEED, data_dir)
        conn.commit()
        conn.close()
        for rel, data in LIB_DISK.items():
            (data_dir / rel).parent.mkdir(parents=True, exist_ok=True)
            (data_dir / rel).write_bytes(data)
        prefix = str(data_dir) + "/"
        steps = []
        for method, path, payload in library_steps(hexid):
            form = None
            if isinstance(payload, tuple):
                fields, files = payload
                raw, ctype = multipart(fields, files)
                form = {"fields": fields, "files": {k: {"name": n, "type": t, "base64": base64.b64encode(d).decode()}
                                                    for k, (n, t, d) in (files or {}).items()}}
            else:
                raw, ctype = payload or b"", "application/json"
            # Bild ohne Pillow: bleibt ein Bild (wie lokal ohne Umwandlung, NoDocumentTools)
            no_pil = form is not None and path == "/api/notebooks" and form["fields"].get("kind") == "image"
            saved_pil = sys.modules.get("PIL", "fehlt")
            if no_pil:
                sys.modules["PIL"] = None
            try:
                status, headers, body = asgi_raw(server.app, method, path, raw, ctype)
            finally:
                if no_pil:
                    if saved_pil == "fehlt":
                        sys.modules.pop("PIL", None)
                    else:
                        sys.modules["PIL"] = saved_pil
            step = {"method": method, "path": path, "status": status}
            if form is not None:
                step["form"] = form
            elif payload is not None:
                step["raw"] = payload.decode()
            if headers.get("content-type", "").startswith("application/json"):
                step["response"] = _strip(json.loads(body), prefix) if body else None
            else:
                step["headers"] = {k: headers[k] for k in ("content-type", "content-disposition", "x-content-type-options",
                                                           "content-security-policy") if k in headers}
                step["base64"] = base64.b64encode(body).decode()
            steps.append(step)
        conn = sqlite3.connect(src.db.DB_PATH)
        try:
            tables = _tables(conn, prefix)
        finally:
            conn.close()
        disk = sorted(str(p.relative_to(data_dir)) for p in data_dir.rglob("*")
                      if p.is_file() and not p.name.startswith("lernapp.db"))
    guesses = {n: mimetypes.guess_type(n)[0] for n in ("a.pdf", "a.PNG", "a.jpg", "a.jpeg", "a.gif", "a.webp", "a.svg", "a.txt",
                                                      "a.html", "a.zip", "a.docx", "ohne", ".png", "a.")}
    return {"generator": "tools/gen-local-backend-fixture.py", "now": FROZEN, "studip_base": STUDIP_BASE_TEST,
            "seed": LIB_SEED, "disk_seed": {k: base64.b64encode(v).decode() for k, v in LIB_DISK.items()},
            "steps": steps, "tables": tables, "disk": disk, "mime_guess": guesses,
            "s4_fields": ["doc_type", "sub_label", "week_hint"],
            "unordered": ["/api/library", "/api/files"],
            "expect": {"PUT /api/files/gibtsnicht/annotations?base_version=0":
                       {"status": 409, "reason": "Python 500 (Fremdschluessel annotations.file_id); lokal 409 ohne version"}}}


# ----------------------------------------------------------------------------
# S3: Stud.IP-Abgleich in die Datenbank (run_sync ohne Netz, Playwright und Einordnung)
# ----------------------------------------------------------------------------

def _f(fid, name, changed, *, size=10, mime="application/pdf", folder="", downloadable=True, fail=False):
    # fail: Download bricht ab (z. B. Netz), obwohl Stud.IP die Datei als ladbar meldet
    return {"id": fid, "name": name, "size": size, "mime": mime, "changed": changed, "folder": folder, "downloadable": downloadable,
            **({"fail": True} if fail else {})}


IMPORT_ROUNDS = [
    {"name": "Erster Abgleich", "now": "2026-10-20T08:00:00",
     "courses": [{"id": "c1", "title": "Testkurs Analysis", "number": "T-1", "semester": "WiSe 2026/27"},
                 {"id": "c2", "title": "Testkurs Chemie", "number": None, "semester": ""}],
     "files": {"c1": [_f("a1", "Folien 1.pdf", "2026-10-19T10:00:00+02:00", size=100),
                      _f("a2", "Blatt 1.pdf", "2026-10-19T12:00:00.250+02:00", folder="Übungen"),
                      _f("a3", "Daten.zip", "2026-10-18T09:00:00Z", mime=None, folder="Material/Extra"),
                      _f("a4", "Gesperrt.pdf", "2026-10-18T09:30:00+02:00", downloadable=False)],
               "c2": [_f("b1", "Bild.PNG", "1792000000", mime="image/png"),
                      _f("b2", "Tabelle.xlsx", "2026-10-17T08:00:00", mime="application/vnd.ms-excel")]}},
    {"name": "Zweiter Abgleich mit Aenderungen", "now": "2026-10-21T08:00:00",
     "user_sql": ["UPDATE files SET status='erledigt', seen_by_user=1, favorite=1, folder_id=7, title='Mein Titel', last_page=3 WHERE id='a1'",
                  "UPDATE files SET seen_by_user=1 WHERE id='b1'",
                  "UPDATE courses SET subject='Eigenes Fach', kind='uebung', active=0 WHERE id='c2'"],
     "delete_local": ["a3"],
     "courses": [{"id": "c1", "title": "Testkurs Analysis I", "number": "T-1a", "semester": "WiSe 2026/27"},
                 {"id": "c2", "title": "Testkurs Chemie", "number": None, "semester": ""}],
     "files": {"c1": [_f("a1", "Folien 1.pdf", "2026-10-19T10:00:00+02:00", size=100),
                      _f("a2", "Blatt 1 (neu).pdf", "2026-10-20T18:00:00+02:00", size=60, folder="Übungen/Neu"),
                      _f("a3", "Daten.zip", "2026-10-18T09:00:00Z", mime=None, folder="Material/Extra"),
                      _f("a4", "Gesperrt.pdf", "2026-10-18T09:30:00+02:00", downloadable=False),
                      _f("a5", "Folien 2.pdf", "2026-10-20T10:00:00+02:00", size=120)],
               "c2": [_f("b2", "Tabelle.xlsx", "2026-10-17T08:00:00", mime="application/vnd.ms-excel")]}},
    {"name": "Dritter Abgleich, aeltere Aenderungszeit", "now": "2026-10-22T08:00:00",
     "courses": [{"id": "c1", "title": "Testkurs Analysis I", "number": "T-1a", "semester": "WiSe 2026/27"}],
     "files": {"c1": [_f("a1", "Folien 1.pdf", "2026-10-19T10:00:00+02:00", size=100),
                      _f("a2", "Blatt 1 (neu).pdf", "2026-10-20T18:00:00+02:00", size=60, folder="Übungen/Neu"),
                      _f("a5", "Folien 2.pdf", "2026-10-19T10:00:00+02:00", size=120)]}},
    # neue Fassung von a1, ihr Download scheitert: Aenderungszeit, Groesse und Typ bleiben beim alten Stand, damit der
    # naechste Abgleich die Datei wieder als geaendert erkennt und laedt (vorher ging die neue Fassung verloren)
    {"name": "Neue Fassung, Download scheitert", "now": "2026-10-22T12:00:00",
     "courses": [{"id": "c1", "title": "Testkurs Analysis I", "number": "T-1a", "semester": "WiSe 2026/27"}],
     "files": {"c1": [_f("a1", "Folien 1 (v2).pdf", "2026-10-22T09:00:00+02:00", size=130, mime="application/x-pdf", fail=True),
                      _f("a2", "Blatt 1 (neu).pdf", "2026-10-20T18:00:00+02:00", size=60, folder="Übungen/Neu")]}},
    {"name": "Naechster Abgleich laedt die neue Fassung", "now": "2026-10-22T18:00:00",
     "courses": [{"id": "c1", "title": "Testkurs Analysis I", "number": "T-1a", "semester": "WiSe 2026/27"}],
     "files": {"c1": [_f("a1", "Folien 1 (v2).pdf", "2026-10-22T09:00:00+02:00", size=130, mime="application/x-pdf"),
                      _f("a2", "Blatt 1 (neu).pdf", "2026-10-20T18:00:00+02:00", size=60, folder="Übungen/Neu")]}},
    {"name": "Abgleich mit Fehler", "now": "2026-10-23T08:00:00", "error": "Testfehler"},
]


def _unix(changed: str) -> int:
    from datetime import datetime
    if changed.lstrip("-").isdigit():
        return int(changed)
    return int(datetime.fromisoformat(changed).timestamp())          # ohne Zone: Ortszeit (TZ=Europe/Berlin)


def studip_import(src: SchemaSource) -> dict:
    import sqlite3
    import time as _time
    from app import db, studip_sync, timetable
    files_dir = Path(studip_sync.FILES_DIR)
    shutil.rmtree(files_dir, ignore_errors=True)
    saved_now = db.now_iso
    db.now_iso = lambda: FROZEN                                          # Pseudokurs __user__ wie in den Swift-Tests
    try:
        fresh_db(src, "abgleich")
    finally:
        db.now_iso = saved_now
    names = ("sync_playwright", "login", "fetch_courses", "fetch_events", "fetch_files", "fetch_folder_paths", "download",
             "classify", "SEMESTER_FILTER")
    saved = {k: getattr(studip_sync, k) for k in names}
    saved_sleep, saved_auto, saved_now, saved_tz = studip_sync.time.sleep, timetable.auto_import, db.now_iso, os.environ.get("TZ")
    os.environ["TZ"] = "Europe/Berlin"
    _time.tzset()
    rounds = []
    state: dict = {}

    class Request:
        def get(self, *a, **k):
            raise RuntimeError("kein Netz im Fixture")             # persoenlicher Stundenplan: S5

    class Page:
        request = Request()

    class Ctx:
        def new_page(self):
            return Page()

        def close(self):
            pass

    class Chromium:
        def launch_persistent_context(self, *a, **k):
            return Ctx()

    class PW:
        chromium = Chromium()

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

    def fetch_courses(page):
        if state["round"].get("error"):
            raise RuntimeError(state["round"]["error"])
        return [dict(c) for c in state["round"]["courses"]]

    def fetch_files(page, cid):
        return [{"id": f["id"], "name": f["name"], "size": f["size"], "mime": f["mime"], "author": None, "chdate": _unix(f["changed"]),
                 "download_url": f"{STUDIP_BASE_TEST}/jsonapi.php/v1/file-refs/{f['id']}/content"}
                for f in state["round"]["files"].get(cid, [])]

    def fetch_folder_paths(page, cid):
        return {f["id"]: f["folder"] for f in state["round"]["files"].get(cid, [])}

    def download(page, url, target):
        fid = url.split("/file-refs/")[1].split("/")[0]
        state["attempted"].append(fid)
        f = next(x for fs in state["round"]["files"].values() for x in fs if x["id"] == fid)
        if not f["downloadable"]:
            raise RuntimeError("Download fehlgeschlagen (403)")
        if f.get("fail"):
            raise RuntimeError("Verbindung abgebrochen")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(f"Inhalt {fid}".encode())
        state["downloaded"].append(fid)

    try:
        studip_sync.sync_playwright = lambda: PW()
        studip_sync.login = lambda page: None
        studip_sync.fetch_courses = fetch_courses
        studip_sync.fetch_events = lambda page, cid: []                  # Termine: S5
        studip_sync.fetch_files = fetch_files
        studip_sync.fetch_folder_paths = fetch_folder_paths
        studip_sync.download = download
        studip_sync.classify = lambda title: (None, None)                # S3: Fach und Art erst mit S4
        studip_sync.SEMESTER_FILTER = ""
        studip_sync.time.sleep = lambda s: None
        timetable.auto_import = lambda conn: {"new": 0}                  # Stundenplan: S5
        for r in IMPORT_ROUNDS:
            state.update(round=r, attempted=[], downloaded=[])
            conn = sqlite3.connect(src.db.DB_PATH)
            for sql in r.get("user_sql", []):
                conn.execute(sql)
            for fid in r.get("delete_local", []):
                Path(conn.execute("SELECT local_path FROM files WHERE id=?", (fid,)).fetchone()[0]).unlink()
            conn.commit()
            conn.close()
            db.now_iso = lambda r=r: r["now"]
            studip_sync.run_sync()
            conn = sqlite3.connect(src.db.DB_PATH)
            try:
                tables = {}
                for name, sql in (("courses", "SELECT * FROM courses ORDER BY id"), ("files", "SELECT * FROM files ORDER BY id"),
                                  ("sync_log", "SELECT * FROM sync_log ORDER BY id")):
                    cur = conn.execute(sql)
                    cols = [d[0] for d in cur.description]
                    rows = [dict(zip(cols, row)) for row in cur.fetchall()]
                    for row in rows:
                        if row.get("local_path") is not None:
                            row["local_path"] = "<lokal>"              # Ablage: Python je Kurs, lokal je Datei-ID
                    tables[name] = rows
            finally:
                conn.close()
            rounds.append({**r, "attempted": state["attempted"], "downloaded": state["downloaded"], "tables": tables})
    finally:
        for k, v in saved.items():
            setattr(studip_sync, k, v)
        studip_sync.time.sleep, timetable.auto_import, db.now_iso = saved_sleep, saved_auto, saved_now
        if saved_tz is None:
            os.environ.pop("TZ", None)
        else:
            os.environ["TZ"] = saved_tz
        _time.tzset()
        shutil.rmtree(files_dir, ignore_errors=True)
    unix = {c: _unix(c) for c in sorted({f["changed"] for r in IMPORT_ROUNDS for fs in r.get("files", {}).values() for f in fs})}
    return {"generator": "tools/gen-local-backend-fixture.py", "studip_base": STUDIP_BASE_TEST, "rounds": rounds, "unix_times": unix}


def main() -> int:
    check = "--check" in sys.argv[1:]
    src = SchemaSource()
    try:
        from app import server                           # nach SchemaSource: DB_PATH liegt im Temp-Ordner
        app = server.app
        cov = coverage(src, app, server)
        st = settings_terms(src, app)
        tf = timetable_free(src, app)
        lib = library_files(src, server)
        imp = studip_import(src)
    finally:
        src.cleanup()
    out = {"app-paths.json": json.dumps(cov, ensure_ascii=False, indent=1) + "\n",
           "settings-terms.json": json.dumps(st, ensure_ascii=False, indent=1) + "\n",
           "timetable-free.json": json.dumps(tf, ensure_ascii=False, indent=1) + "\n",
           "library-files.json": json.dumps(lib, ensure_ascii=False, indent=1) + "\n",
           "studip-import.json": json.dumps(imp, ensure_ascii=False, indent=1) + "\n"}
    ok = all([write_or_check(OUT / name, content, check) for name, content in out.items()])
    return 0 if ok or not check else 1


if __name__ == "__main__":
    sys.exit(main())

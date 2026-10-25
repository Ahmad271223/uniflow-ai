"""Erzeugt die Fixtures des lokalen Backends in packages/shared-contracts/fixtures/local-backend/.

- app-paths.json: alle /api/-Pfade, die die iPad-App aufruft (per grep in apps/apple/UniFlow), je mit einer
  Beispielanfrage, der Antwort von app/server.py bei leerer Datenbank (nur die Form: Typen und Schluessel, keine
  Werte) und dem Status, den das lokale Backend liefern soll. Der Swift-Kern (LocalBackendCoverageTests) schickt
  jede Anfrage an den lokalen Router und vergleicht.
- settings-terms.json: eine Folge von Anfragen an GET/PUT /api/settings und /api/terms mit den Antworten von
  app/server.py und dem Inhalt der Tabelle settings danach (exakter Text wie db.set_setting ihn schreibt).

Der Server laeuft dabei nur gegen Dateien in einem Temp-Ordner (tools/schema_source.py), nie gegen data/.
Pfade mit Netzwerk, KI oder Zugangsdaten (Sync, QIS, Tests, /api/credentials, /api/services) werden nicht
aufgerufen; fuer sie steht die erwartete lokale Antwort in SAMPLES.
Aufruf im Projektordner: python tools/gen-local-backend-fixture.py [--check]
"""
from __future__ import annotations

import asyncio
import json
import re
import sys

from schema_source import ROOT, SchemaSource, write_or_check

OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "local-backend"
APP = ROOT / "apps" / "apple" / "UniFlow"

# Aufrufe, deren Pfad nicht als Text im Quelltext steht
EXTRA = {
    "GET /api/assets/{}/{}": "UniFlow/Services/DocumentStore.swift (Bilder aus Notizen, src)",
}

# Beispielanfrage je Pfad. "python": False -> nicht gegen app/server.py ausfuehren (Netzwerk, KI, .env),
# dann ist "expect" Pflicht. "expect" ueberschreibt sonst den Status von Python, "reason" erklaert warum.
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
    "POST /api/folders": {"path": "/api/folders", "body": {"name": "Neuer Ordner"},
                          "expect": {"status": 409, "reason": "Anlegen kommt mit S3"}},
    "PATCH /api/folders/{}": {"path": "/api/folders/1", "body": {"name": "x"}},
    "DELETE /api/folders/{}": {"path": "/api/folders/1"},
    "POST /api/notebooks": {"path": "/api/notebooks", "form": {"kind": "notebook", "title": "Notizbuch"},
                            "expect": {"status": 409, "reason": "Eigene Dokumente kommen mit S3"}},
    "PATCH /api/library/files/{}": {"path": "/api/library/files/f1", "body": {"title": "Neu"}},
    "POST /api/files/{}/favorite": {"path": "/api/files/f1/favorite", "body": {"favorite": True}},
    "GET /api/files/{}/content": {"path": "/api/files/f1/content"},
    "GET /api/files/{}/pagetext": {"path": "/api/files/f1/pagetext?page=1"},
    "GET /api/assets/{}/{}": {"path": "/api/assets/f1/bild.png"},
    "GET /api/files/{}/annotations": {"path": "/api/files/f1/annotations"},
    "PUT /api/files/{}/annotations": {"path": "/api/files/f1/annotations?base_version=0", "body": {"version": 2, "pages": {}},
                                      "expect": {"status": 409, "reason": "Notizen lokal erst mit S3; Journal behaelt alles"}},
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
    "GET /api/services": {"path": "/api/services", "python": False,
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


def coverage(src: SchemaSource, app) -> dict:
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


def main() -> int:
    check = "--check" in sys.argv[1:]
    src = SchemaSource()
    try:
        from app.server import app                       # nach SchemaSource: DB_PATH liegt im Temp-Ordner
        cov = coverage(src, app)
        st = settings_terms(src, app)
    finally:
        src.cleanup()
    out = {"app-paths.json": json.dumps(cov, ensure_ascii=False, indent=1) + "\n",
           "settings-terms.json": json.dumps(st, ensure_ascii=False, indent=1) + "\n"}
    ok = all([write_or_check(OUT / name, content, check) for name, content in out.items()])
    return 0 if ok or not check else 1


if __name__ == "__main__":
    sys.exit(main())

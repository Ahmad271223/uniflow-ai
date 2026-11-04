"""Erzeugt packages/shared-contracts/fixtures/flashcards/stacks.json: Vertrag der Karteikarten-Stapel (04.11.2026) aus der
Python-Referenz, fuer die Mac-Sitzung (iPad: lokaler Kern und Dienst-Anbindung).

Inhalt:
- "local": Karteikarten-Stapel am Geraet (app/flashcard_stacks.py, app/flashcards_api.py) auf erfundenen Daten mit
  eingefrorener Uhr (Ortszeit Berlin, Dienstag 04.11.2026): POST /api/flashcards/stack (Doppel, Herkunft, Fehler),
  GET /api/flashcards/stacks, GET /api/flashcards/stack, POST /api/flashcards/move, aeltere Karte am Dokument
  (Modul ueber die Datei) und die Tabelle flashcards danach. Der Swift-Kern soll dieselben Antworten liefern.
- "ai_stack": KI-Auftrag POST /api/ai/flashcards mit module_id (Pro AI) gegen eine Attrappe: Anfrage, Material der
  Lehrwoche (Quellen), genauer Prompt, Antwort, Doppel-Filter und Fehler. Im Dienst kommen Recht, bestaetigte E-Mail,
  Kontingent ai_assist und Budget dazu (tests/test_flashcards_hosted.py).
- "community": Stapel teilen und nutzen im Dienst (app/community_decks.py, LERNAPP_MODE=hosted) mit Status und Antwort
  je Schritt; IDs, Pseudonyme und Zeiten ersetzt.
Nur Temp-Ordner (tools/schema_source.py), keine echte KI, kein Netz.
Aufruf im Projektordner: python tools/gen-flashcard-stacks-fixture.py [--check]
"""
from __future__ import annotations

import importlib.util
import json
import os
import re
import sys
from datetime import date, datetime
from pathlib import Path

os.environ.setdefault("LERNAPP_ALLOWED_HOSTS", "test")
from schema_source import ROOT, SchemaSource, berlin_time, without_sync, write_or_check  # noqa: E402

OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "flashcards" / "stacks.json"
NOW = "2026-11-04T10:00:00"
CHDATE = 1793437200                     # 31.10.2026, 09:00 UTC: Dateien dieses Semesters (Woche aus dem Dateinamen)

SEED = [
    ("INSERT INTO modules(id, name, color, sort) VALUES (1, 'Analysis Beispiel', '#175ee8', 1)", []),
    ("INSERT INTO modules(id, name, color, sort) VALUES (2, 'Lineare Algebra Beispiel', '#e95905', 2)", []),
    ("INSERT INTO courses(id, title, semester, subject, kind, active, module_id, created_at) VALUES ('k-an', 'Analysis Beispiel', 'WiSe 2026/27', 'Analysis Beispiel', 'vorlesung', 1, 1, '2026-10-01T09:00:00')", []),
    ("INSERT INTO files(id, course_id, name, status, kind, chdate, first_seen) VALUES ('f-vl3', 'k-an', 'VL03_Folgen.pdf', 'neu', 'pdf', ?, '2026-10-31T08:00:00')", [CHDATE]),
    ("INSERT INTO files(id, course_id, name, status, kind, chdate, first_seen) VALUES ('f-ue3', 'k-an', 'Blatt03.pdf', 'neu', 'pdf', ?, '2026-10-31T08:00:00')", [CHDATE]),
    ("INSERT INTO files(id, course_id, name, status, kind, chdate, first_seen) VALUES ('f-vl4', 'k-an', 'VL04_Reihen.pdf', 'neu', 'pdf', ?, '2026-10-31T08:00:00')", [CHDATE]),
]

CARD = lambda q, a: {"question": q, "answer": a}  # noqa: E731
COMMUNITY_ID = "community:" + "d" * 32
LOCAL_STEPS = [
    ("GET", "/api/flashcards/stacks", None),
    ("POST", "/api/flashcards/stack", {"module_id": 1, "lecture_week": 3, "cards": [CARD("Was ist eine Folge?", "Abbildung N -> R"), CARD(" was ist eine FOLGE ", "doppelt"),
                                                                                       CARD("", "leer"), "kein Objekt", CARD("Grenzwert?", "lim a_n")]}),
    ("POST", "/api/flashcards/stack", {"module_id": 1, "lecture_week": "3", "cards": [CARD("Was ist eine Folge", "schon da"), CARD("Cauchy-Folge?", "Glieder beliebig nah")]}),
    ("POST", "/api/flashcards/stack", {"module_id": 1, "lecture_week": None, "origin": "ai", "cards": [CARD("Was ist eine Folge?", "im ganzen Modul erlaubt")]}),
    ("POST", "/api/flashcards/stack", {"module_id": 2, "lecture_week": 1, "origin": COMMUNITY_ID, "cards": [CARD("Basis?", "linear unabhaengiges Erzeugendensystem")]}),
    ("POST", "/api/flashcards/stack", {"module_id": 99, "cards": [CARD("q", "a")]}),
    ("POST", "/api/flashcards/stack", {"module_id": 1, "lecture_week": 31, "cards": [CARD("q", "a")]}),
    ("POST", "/api/flashcards/stack", {"module_id": 1, "lecture_week": 2.5, "cards": [CARD("q", "a")]}),
    ("POST", "/api/flashcards/stack", {"module_id": 1, "origin": "fremd", "cards": [CARD("q", "a")]}),
    ("POST", "/api/flashcards/stack", {"module_id": 1, "cards": "keine Liste"}),
    ("POST", "/api/flashcards/stack", {"module_id": 1, "cards": [CARD("q", "x" * 4001)]}),
    ("POST", "/api/flashcards/stack", {"module_id": None, "cards": [CARD("q", "a")]}),
    ("POST", "/api/flashcards", {"cards": [CARD("Alt am Dokument", "Modul ueber die Datei")], "file_id": "f-vl4"}),
    ("POST", "/api/flashcards", {"cards": [CARD("Ganz ohne Bezug", "Ohne Modul")]}),
    ("GET", "/api/flashcards/stacks", None),
    ("GET", "/api/flashcards/stack?module_id=1&lecture_week=3", None),
    ("GET", "/api/flashcards/stack?module_id=1", None),
    ("GET", "/api/flashcards/stack?module_id=1&lecture_week=module", None),
    ("GET", "/api/flashcards/stack?module_id=1&lecture_week=x", None),
    ("GET", "/api/flashcards/stack?module_id=99", None),
    ("POST", "/api/flashcards/move", {"ids": [6], "module_id": 1, "lecture_week": 4}),       # Karte am Dokument in Woche 4
    ("POST", "/api/flashcards/move", {"ids": [], "module_id": 1}),
    ("POST", "/api/flashcards/move", {"ids": [1], "module_id": 99}),
    ("GET", "/api/flashcards/stacks", None),
]

PAGES = {"f-vl3": ["Folgen: Definition und Beispiele", "Konvergenz und Grenzwert", "Cauchy-Folgen"],
         "f-ue3": ["Aufgabe 1: Zeige, dass 1/n gegen 0 konvergiert."],
         "f-vl4": ["Reihen und Partialsummen"]}
AI_ANSWERS = [
    '{"cards": [{"question": "Was ist eine Folge?", "answer": "doppelt"}, {"question": "Wann ist eine Folge beschraenkt?", "answer": "|a_n| <= C"}, {"question": " ", "answer": "leer"}]}',
    '{"cards": [{"question": "Was ist eine Reihe?", "answer": "Folge der Partialsummen"}]}',
    "keine Karten",
]
AI_STEPS = [
    {"module_id": 1, "lecture_week": 3, "count": 12, "topic": "Konvergenz"},
    {"module_id": 1, "lecture_week": None, "count": 80},
    {"module_id": 1, "lecture_week": 3, "count": 5},
    {"module_id": 1, "lecture_week": 9, "count": 5},
    {"module_id": 1, "lecture_week": 9, "count": 5, "material": [{"title": "Eigene Notiz", "text": "Monotone Folgen"}]},
    {"module_id": 1, "lecture_week": "x"},
    {"module_id": 99},
]


def _gen():
    spec = importlib.util.spec_from_file_location("gen_local_backend_fixture", Path(__file__).with_name("gen-local-backend-fixture.py"))
    gen = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gen)
    return gen


def local(src: SchemaSource, gen, server) -> dict:
    src.fresh_db("stapel")
    with src.db.cursor() as conn:
        for sql, params in SEED:
            conn.execute(sql, params)
    src.freeze(lambda: date.fromisoformat(NOW[:10]), lambda: NOW, lambda: datetime.fromisoformat(NOW))
    steps = []
    for method, path, body in LOCAL_STEPS:
        raw = json.dumps(body) if body is not None else None
        status, value = gen.asgi(server.app, method, path, raw_body=raw)
        steps.append({"method": method, "path": path, "raw": raw, "status": status, "response": value})
    with src.db.cursor() as conn:
        table = src.db.rows(conn, "SELECT * FROM flashcards ORDER BY id")
    return {"now": NOW, "seed": [{"sql": q, "params": p} for q, p in SEED], "steps": steps, "tables_after": {"flashcards": table}}


def ai_stack(src: SchemaSource, gen, server) -> dict:
    from app import ai, scriptsearch
    src.fresh_db("ki")
    with src.db.cursor() as conn:
        for sql, params in SEED:
            conn.execute(sql, params)
        conn.execute("INSERT INTO flashcards(question, answer, created_at, box, due, module_id, lecture_week) VALUES ('Was ist eine Folge?', 'a', ?, 1, '2026-11-04', 1, 3)", (NOW,))
    src.freeze(lambda: date.fromisoformat(NOW[:10]), lambda: NOW, lambda: datetime.fromisoformat(NOW))
    saved = (scriptsearch.page_texts, ai.ask)
    scriptsearch.page_texts = lambda conn, file_id, *a, **k: PAGES.get(file_id, [])
    answers = iter(AI_ANSWERS * 3)
    seen = {}

    def ask(prompt, system, schema=None):
        seen["prompt"] = prompt
        return next(answers)
    ai.ask = ask
    out = []
    try:
        for body in AI_STEPS:
            seen.clear()
            status, value = gen.asgi(server.app, "POST", "/api/ai/flashcards", raw_body=json.dumps(body))
            out.append({"request": body, "status": status, "response": value, "prompt": seen.get("prompt")})
    finally:
        scriptsearch.page_texts, ai.ask = saved
    return {"pages": PAGES, "ai_answers": AI_ANSWERS, "steps": out}


# ---------------------------------------------------------------- Dienst: Stapel teilen und nutzen

_ISO = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})?$")


def community() -> dict:
    sys.path.insert(0, str(ROOT / "tests"))
    from conftest import asgi_call
    from app import accounts, community as cm, config
    from app.server import app
    config.MODE = "hosted"
    for p in (accounts.db_path(), cm.db_path()):
        p.unlink(missing_ok=True)
    key = "c" * 64
    names: dict[str, str] = {}
    flows: list[dict] = []

    def scrub(x):
        if isinstance(x, dict):
            return {k: scrub(v) for k, v in x.items()}
        if isinstance(x, list):
            return [scrub(v) for v in x]
        if isinstance(x, str):
            for real, alias in names.items():
                x = x.replace(real, alias)
            if _ISO.match(x):
                return "<zeit-utc>"
        return x

    def user(email, plan="plus", verified=True, member=True, alias=""):
        st, _, raw = asgi_call(app, "POST", "/api/account/register", body=json.dumps({"email": email, "password": "sehr-geheim-123", "university": "luh"}))
        d = json.loads(raw)
        uid = d["user"]["id"]
        accounts.end_trial(uid)
        if verified:
            accounts.mark_email_verified(uid)
        if plan != "free":
            accounts.set_plan(uid, plan)
        if member:
            with cm.cursor() as conn:
                conn.execute("INSERT INTO community_members(user_id, community_key, university, kind, joined_at) VALUES (?,?,?,?,?)",
                             (uid, key, "luh", "course", "2026-11-04T00:00:00Z"))
        names[cm.pseudonym(uid)] = f"<pseudonym-{alias}>"
        names[uid] = f"<user-{alias}>"
        return d["token"]

    def call(step, method, path, body=None, token=None):
        st, _, raw = asgi_call(app, method, path, body=json.dumps(body) if body is not None else None,
                               headers={"Authorization": f"Bearer {token}"} if token else None)
        data = json.loads(raw) if raw else None
        flows.append({"step": step, "method": method, "path": scrub(path), "request": scrub(body), "status": st, "response": scrub(data)})
        return data

    ta = user("autor@beispiel.de", alias="autor")
    tl = user("leser@beispiel.de", alias="leser")
    tf = user("frei@beispiel.de", plan="free", alias="frei")
    tu = user("unbestaetigt@beispiel.de", verified=False, alias="unbestaetigt")
    to = user("fremd@beispiel.de", member=False, alias="fremd")
    cards = [{"question": "Was ist eine Folge?", "answer": "Abbildung N -> R"}, {"question": "Grenzwert?", "answer": "lim a_n"}]
    base = f"/api/community/communities/{key}/decks"
    d = call("Stapel fuer Woche 3 teilen", "POST", base, {"title": "Analysis · Woche 3", "lecture_week": 3, "cards": cards}, ta)
    names[d["id"]] = "<deck-1>"
    flows[-1]["response"] = scrub(d)
    d2 = call("Stapel fuers ganze Modul (ohne Titel)", "POST", base, {"lecture_week": None, "cards": cards[:1]}, ta)
    names[d2["id"]] = "<deck-2>"
    flows[-1]["response"] = scrub(d2)
    call("Zweiter Stapel derselben Woche: Aktualisieren?", "POST", base, {"lecture_week": 3, "cards": cards}, ta)
    call("Teilen ohne Plus", "POST", base, {"lecture_week": 4, "cards": cards}, tf)
    call("Teilen ohne bestaetigte E-Mail", "POST", base, {"lecture_week": 4, "cards": cards}, tu)
    call("Teilen ohne Mitgliedschaft", "POST", base, {"lecture_week": 4, "cards": cards}, to)
    call("Zu viele Karten", "POST", base, {"lecture_week": 5, "cards": cards * 251}, ta)
    call("Kartenseite zu lang", "POST", base, {"lecture_week": 5, "cards": [{"question": "q", "answer": "x" * 1001}]}, ta)
    call("Ungueltige Woche", "POST", base, {"lecture_week": 0, "cards": cards}, ta)
    call("Liste fuer Mitglieder (auch Free)", "GET", base, None, tf)
    call("Liste: nur Woche 3", "GET", base + "?week=3", None, tl)
    call("Liste: nur ganzes Modul", "GET", base + "?week=module", None, tl)
    call("Liste ohne Mitgliedschaft", "GET", base, None, to)
    call("Stapel ansehen (mit Karten)", "GET", f"/api/community/decks/{d['id']}", None, tl)
    call("Stapel ansehen ohne Mitgliedschaft", "GET", f"/api/community/decks/{d['id']}", None, to)
    call("Uebernehmen", "POST", f"/api/community/decks/{d['id']}/adopt", None, tl)
    call("Uebernehmen noch einmal (zaehlt nicht doppelt)", "POST", f"/api/community/decks/{d['id']}/adopt", None, tl)
    call("Uebernehmen ohne Plus", "POST", f"/api/community/decks/{d['id']}/adopt", None, tf)
    call("Eigenen Stapel ersetzen", "PUT", f"/api/community/decks/{d['id']}", {"title": "Analysis · Woche 3 (neu)", "cards": cards[::-1]}, ta)
    call("Fremden Stapel ersetzen", "PUT", f"/api/community/decks/{d['id']}", {"cards": cards}, tl)
    call("Eigene Stapel", "GET", "/api/community/decks/mine", None, ta)
    call("Melden", "POST", f"/api/community/decks/{d['id']}/report", {"reason": "spam"}, tl)
    call("Melden: schon gemeldet", "POST", f"/api/community/decks/{d['id']}/report", {"reason": "spam"}, tl)
    call("Melden: eigener Stapel", "POST", f"/api/community/decks/{d['id']}/report", {"reason": "spam"}, ta)
    call("Zurueckziehen: nicht der Autor", "DELETE", f"/api/community/decks/{d2['id']}", None, tl)
    call("Zurueckziehen", "DELETE", f"/api/community/decks/{d2['id']}", None, ta)
    call("Zurueckgezogen: nicht mehr sichtbar", "GET", f"/api/community/decks/{d2['id']}", None, tl)
    return {"community_key": key, "flows": flows}


def main() -> int:
    check = "--check" in sys.argv[1:]
    src = SchemaSource()
    try:
        from app import server
        gen = _gen()
        with berlin_time():
            loc = local(src, gen, server)
            ki = ai_stack(src, gen, server)
            com = community()
    finally:
        src.cleanup()
    out = without_sync({
        "generator": "tools/gen-flashcard-stacks-fixture.py",
        "rules": {"count": {"min": 5, "max": 50, "default": 20}, "week": {"min": 1, "max": 30, "module": None},
                  "local_side_chars": 4000, "local_cards_per_request": 500, "material_chars": 24000,
                  "deck": {"max_cards": 500, "max_side_chars": 1000, "max_title": 120, "reports_to_hide": 3, "limit_per_day": "deck_user 10",
                           "update_limit": "update_user 60", "report_limit": "report_user 10"},
                  "origin": ["null = selbst angelegt", "ai", "community:<deck-id 32 hex>"],
                  "entitlements": {"anlegen": "can_create_flashcards (plus)", "teilen_und_uebernehmen": "can_share_flashcards (plus)",
                                   "ki_auftrag": "can_generate_ai_flashcards (pro_ai) + email_verified + ai_assist"}},
        "local": loc, "ai_stack": ki, "community": com})
    ok = write_or_check(OUT, json.dumps(out, ensure_ascii=False, indent=1) + "\n", check)
    return 0 if ok or not check else 1


if __name__ == "__main__":
    sys.exit(main())

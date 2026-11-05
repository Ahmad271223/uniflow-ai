"""Erzeugt packages/shared-contracts/fixtures/flashcards/stacks.json: Pruefdaten fuer KI-Karteikarten auf Auftrag und
geteilte Karteikarten-Stapel im Dienst (04.11.2026) aus der Python-Referenz.

Aus der Cloud-Sitzung vom 04.11.2026 uebernommen und an das Stapel-Modell angepasst (docs/KARTEIKARTEN-STAPEL-2026-11-04.md):
Stapel sind Zeilen in `flashcard_stacks` (Name, Fach = Modulname, Woche, Art), Karten tragen `stack_id`. Die Stapel am
Geraet selbst (Anlegen, Bearbeiten, Ueben, Loeschen) pinnt fixtures/local-backend/flashcards.json (Swift-Kern und
Python gleich); diese Datei ergaenzt, was nur der Dienst kann:

- "ai_stack": KI-Auftrag POST /api/ai/flashcards mit module_id (app/flashcard_order.py) gegen eine Attrappe auf
  erfundenen Daten mit eingefrorener Uhr (Ortszeit Berlin, Dienstag 04.11.2026): Anfrage, Material der Lehrwoche
  (Quellen), genauer Prompt, Antwort, Doppel-Filter gegen die Karten der Stapel des Moduls und Fehler; dazu
  GET /api/ai/flashcards/weeks. Im Dienst kommen Recht (can_use_ai_generated_questions), bestaetigte E-Mail, Kontingent
  ai_assist und Credits dazu (tests/test_flashcards_hosted.py).
- "community": Stapel teilen, ersetzen, auflisten, uebernehmen, melden, zurueckziehen im Dienst
  (app/community_cards_api.py, LERNAPP_MODE=hosted) mit Status und Antwort je Schritt; IDs, Pseudonyme und Zeiten
  ersetzt.
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
    # vorhandener Stapel der Woche 3 im Modul mit einer Karte: kommt in den Prompt und wird aus der Antwort gefiltert
    ("INSERT INTO flashcard_stacks(id, name, subject, file_id, created_at, kind, week) VALUES (1, 'Folgen', 'Analysis Beispiel', NULL, ?, 'eigene', 3)", [NOW]),
    ("INSERT INTO flashcards(file_id, subject, question, answer, created_at, box, due, stack_id) VALUES (NULL, 'Analysis Beispiel', 'Was ist eine Folge?', 'a', ?, 1, '2026-11-04', 1)", [NOW]),
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
    {"module_id": 1, "week": 3, "count": 12, "topic": "Konvergenz"},
    {"module_id": 1, "week": None, "count": 80},
    {"module_id": 1, "week": 3, "count": 5},
    {"module_id": 1, "week": 9, "count": 5},
    {"module_id": 1, "week": 9, "count": 5, "material": [{"title": "Eigene Notiz", "text": "Monotone Folgen"}]},
    {"module_id": 1, "lecture_week": 3, "count": 5},
    {"module_id": 1, "week": "x"},
    {"module_id": 99},
]


def _gen():
    spec = importlib.util.spec_from_file_location("gen_local_backend_fixture", Path(__file__).with_name("gen-local-backend-fixture.py"))
    gen = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gen)
    return gen


def ai_stack(src: SchemaSource, gen, server) -> dict:
    from app import ai, scriptsearch
    src.fresh_db("ki")
    with src.db.cursor() as conn:
        for sql, params in SEED:
            conn.execute(sql, params)
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
        weeks = []
        for path in ("/api/ai/flashcards/weeks?module_id=1", "/api/ai/flashcards/weeks?module_id=99"):
            status, value = gen.asgi(server.app, "GET", path)
            weeks.append({"path": path, "status": status, "response": value})
        for body in AI_STEPS:
            seen.clear()
            status, value = gen.asgi(server.app, "POST", "/api/ai/flashcards", raw_body=json.dumps(body))
            out.append({"request": body, "status": status, "response": value, "prompt": seen.get("prompt")})
    finally:
        scriptsearch.page_texts, ai.ask = saved
    return {"now": NOW, "seed": [{"sql": q, "params": p} for q, p in SEED], "pages": PAGES, "ai_answers": AI_ANSWERS,
            "weeks": weeks, "steps": out}


# ---------------------------------------------------------------- Dienst: Stapel teilen und nutzen

_ISO = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})?$")


def community() -> dict:
    sys.path.insert(0, str(ROOT / "tests"))
    from conftest import asgi_call
    from app import accounts, community as cm, community_cards_api, config, db, server
    from app.server import app
    community_cards_api.date = server.date              # eingefrorene Uhr (src.freeze) auch fuer uebernommene Karten
    from app.solution_format import community_module_key
    config.MODE = "hosted"
    for p in (accounts.db_path(), cm.db_path()):
        p.unlink(missing_ok=True)
    key = community_module_key("luh", "Analysis Beispiel")
    names: dict[str, str] = {key: "<community-key>"}
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
                return "<zeit>"
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
        h = {"Authorization": f"Bearer {d['token']}"}
        tok = config.set_user_context(uid, "luh")
        try:
            db.init_db()
            with db.cursor() as conn:
                conn.execute("INSERT INTO modules(name, color, created_at) VALUES ('Analysis Beispiel', '#175ee8', '2026-10-01')")
        finally:
            config.reset_user_context(tok)
        if member:
            asgi_call(app, "POST", "/api/community/claims", body=json.dumps({"fingerprints": [], "course_keys": [key]}), headers=h)
            asgi_call(app, "POST", f"/api/community/communities/{key}/join", body=json.dumps({"kind": "course"}), headers=h)
        names[cm.pseudonym(uid)] = f"<pseudonym-{alias}>"
        names[uid] = f"<user-{alias}>"
        return h

    def call(step, method, path, body=None, headers=None):
        st, _, raw = asgi_call(app, method, path, body=json.dumps(body) if body is not None else None, headers=headers)
        data = json.loads(raw) if raw else None
        if isinstance(data, dict) and isinstance(data.get("id"), str) and len(data["id"]) == 32 and data["id"] not in names:
            names[data["id"]] = f"<geteilt-{sum(v.startswith('<geteilt-') for v in names.values()) + 1}>"
        flows.append({"step": step, "method": method, "path": scrub(path), "request": scrub(body), "status": st, "response": scrub(data)})
        return data

    ha = user("autor@beispiel.de", alias="autor")
    hl = user("leser@beispiel.de", alias="leser")
    hf = user("frei@beispiel.de", plan="free", alias="frei")
    hu = user("unbestaetigt@beispiel.de", verified=False, alias="unbestaetigt")
    ho = user("fremd@beispiel.de", member=False, alias="fremd")
    cards = [{"question": "Was ist eine Folge?", "answer": "Abbildung N -> R"}, {"question": "Grenzwert?", "answer": "lim a_n"}]
    s3 = call("Stapel fuer Woche 3 anlegen", "POST", "/api/flashcard-stacks", {"name": "Analysis · Woche 3", "subject": "Analysis Beispiel", "week": 3, "kind": "vorlesung"}, ha)
    call("Karten in den Stapel", "POST", "/api/flashcards", {"stack_id": s3["id"], "cards": cards}, ha)
    sg = call("Stapel ohne Woche (Allgemein)", "POST", "/api/flashcard-stacks", {"name": "Formeln", "subject": "Analysis Beispiel"}, ha)
    call("Karte in den Stapel", "POST", "/api/flashcards", {"stack_id": sg["id"], "cards": cards[:1]}, ha)
    d = call("Stapel der Woche 3 teilen", "POST", f"/api/flashcard-stacks/{s3['id']}/share", None, ha)
    call("Allgemein teilen", "POST", f"/api/flashcard-stacks/{sg['id']}/share", None, ha)
    call("Schon geteilt", "POST", f"/api/flashcard-stacks/{s3['id']}/share", None, ha)
    call("Free legt keinen Stapel an", "POST", "/api/flashcard-stacks", {"name": "x", "subject": "Analysis Beispiel"}, hf)
    su = call("Unbestaetigt: Stapel anlegen geht", "POST", "/api/flashcard-stacks", {"name": "U", "subject": "Analysis Beispiel"}, hu)
    call("Karte", "POST", "/api/flashcards", {"stack_id": su["id"], "cards": cards[:1]}, hu)
    call("Teilen ohne bestaetigte E-Mail", "POST", f"/api/flashcard-stacks/{su['id']}/share", None, hu)
    so = call("Nicht-Mitglied: Stapel", "POST", "/api/flashcard-stacks", {"name": "O", "subject": "Analysis Beispiel"}, ho)
    call("Karte", "POST", "/api/flashcards", {"stack_id": so["id"], "cards": cards[:1]}, ho)
    call("Teilen ohne Mitgliedschaft", "POST", f"/api/flashcard-stacks/{so['id']}/share", None, ho)
    call("Liste ohne Plus (Community ab Plus, 05.11.2026)", "GET", f"/api/community/card-stacks?module={key}", None, hf)
    call("Liste: nur Woche 3", "GET", f"/api/community/card-stacks?module={key}&week=3", None, hl)
    call("Liste: nur Allgemein", "GET", f"/api/community/card-stacks?module={key}&week=0", None, hl)
    call("Liste ohne Mitgliedschaft", "GET", f"/api/community/card-stacks?module={key}", None, ho)
    call("Stapel ansehen (mit Karten)", "GET", f"/api/community/card-stacks/{d['id']}", None, hl)
    call("Uebernehmen", "POST", f"/api/community/card-stacks/{d['id']}/adopt", None, hl)
    call("Uebernehmen noch einmal (derselbe Stapel)", "POST", f"/api/community/card-stacks/{d['id']}/adopt", None, hl)
    call("Uebernehmen ohne Plus", "POST", f"/api/community/card-stacks/{d['id']}/adopt", None, hf)
    call("Karte ergaenzen", "POST", "/api/flashcards", {"stack_id": s3["id"], "cards": [{"question": "Cauchy-Folge?", "answer": "Glieder beliebig nah"}]}, ha)
    call("Geteilte Kopie ersetzen", "PUT", f"/api/flashcard-stacks/{s3['id']}/share", None, ha)
    sp = call("Privater Stapel", "POST", "/api/flashcard-stacks", {"name": "Privat", "subject": "Analysis Beispiel"}, ha)
    call("Ersetzen: nicht geteilt", "PUT", f"/api/flashcard-stacks/{sp['id']}/share", None, ha)
    call("Eigene geteilte Stapel", "GET", "/api/community/card-stacks/mine", None, ha)
    call("Liken", "POST", f"/api/community/card-stacks/{d['id']}/like", None, hl)
    call("Melden", "POST", f"/api/community/card-stacks/{d['id']}/report", {"reason": "spam"}, hl)
    call("Melden: schon gemeldet", "POST", f"/api/community/card-stacks/{d['id']}/report", {"reason": "spam"}, hl)
    call("Melden: eigener Stapel", "POST", f"/api/community/card-stacks/{d['id']}/report", {"reason": "spam"}, ha)
    call("Zurueckziehen", "DELETE", f"/api/flashcard-stacks/{sg['id']}/share", None, ha)
    call("Zurueckziehen: nicht geteilt", "DELETE", f"/api/flashcard-stacks/{sg['id']}/share", None, ha)
    return {"community_key": "<community-key>", "flows": flows}


def main() -> int:
    check = "--check" in sys.argv[1:]
    src = SchemaSource()
    try:
        from app import server
        gen = _gen()
        with berlin_time():
            ki = ai_stack(src, gen, server)
            com = community()
    finally:
        src.cleanup()
    out = without_sync({
        "generator": "tools/gen-flashcard-stacks-fixture.py",
        "rules": {"count": {"min": 5, "max": 50, "default": 20}, "week": {"min": 1, "max": 30, "module": None},
                  "material_chars": 24000,
                  "shared": {"max_cards": 500, "max_card_chars": 2000, "max_name": 120, "reports_to_hide": 3,
                             "limit_per_day": "deck_user 10", "replace_limit": "update_user", "report_limit": "report_user 10"},
                  "stack_model": "flashcard_stacks (name, subject = Modulname, week, kind) + flashcards.stack_id; "
                                 "lokal gepinnt in fixtures/local-backend/flashcards.json",
                  "entitlements": {"anlegen_teilen_uebernehmen": "can_use_flashcards (plus)",
                                   "ki_auftrag": "can_use_ai_generated_questions (pro_ai) + email_verified + ai_assist + Credits"}},
        "ai_stack": ki, "community": com})
    ok = write_or_check(OUT, json.dumps(out, ensure_ascii=False, indent=1) + "\n", check)
    return 0 if ok or not check else 1


if __name__ == "__main__":
    sys.exit(main())

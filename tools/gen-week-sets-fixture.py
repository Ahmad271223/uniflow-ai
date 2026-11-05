"""Erzeugt packages/shared-contracts/fixtures/week-sets/week-sets.json: Vertrag „Fertige Fragen je Vorlesungswoche“
(Pro AI, app/week_library.py und app/week_library_api.py, docs/BIBLIOTHEK-WOCHENFRAGEN.md) fuer die iPad-App und die
Web-Oberflaeche.

Inhalt:
- constants: Version des Schluessels, Saetze je Woche, Fragen je Satz, Status, Fehlercodes mit HTTP-Status
- endpoints: Pfade, Methode, Recht, was gezaehlt wird
- key_cases: Schluessel der Woche aus Hochschule und Inhalts-Hashes (week_library.content_key; gleiche Rechnung auf dem
  Geraet, falls es den Stand vorab pruefen will)
- form_cases: Formpruefung einer Frage (week_library.check_question): ok, Gruende, bereinigte Loesung
- card_modes: was die Karte je Status zeigt (app/static/week-sets-logic.js cardMode, geprueft in
  tests/js/week-sets.test.mjs)
- example_ready: Antwort von GET /api/library/week-sets/{module_id}/{week} fuer eine fertige Woche (erfundene Daten)

Aufruf im Projektordner: python tools/gen-week-sets-fixture.py [--check]
"""
from __future__ import annotations

import json
import sys

from schema_source import ROOT, SchemaSource, write_or_check

OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "week-sets" / "week-sets.json"

CARD_MODES = [  # hosted, allowed, status, current -> mode
    (False, True, "ready", True, "service_only"),
    (False, True, "ready", False, "hidden"),
    (True, False, "ready", True, "locked"),
    (True, False, "none", False, "locked"),
    (True, True, "ready", False, "show"),
    (True, True, "preparing", False, "poll"),
    (True, True, "none", True, "auto_prepare"),
    (True, True, "none", False, "offer_prepare"),
    (True, True, "failed", True, "retry"),
    (True, True, "missing_content", False, "info"),
    (True, True, "no_material", True, "hidden"),
]

Q = "Welche Aussage zur Determinante einer 2x2-Matrix ist richtig?"
FORM_CASES = [
    ("gueltig", {"question": Q, "options": ["det = ad + bc", "det = ad - bc", "det = ab - cd", "det = 0"], "answer": "det = ad - bc",
                 "explanation": "Die Formel lautet ad minus bc.", "difficulty": 2}),
    ("Buchstabe als Loesung", {"question": Q, "options": ["A) ad + bc", "B) ad - bc", "C) ab - cd"], "answer": "B",
                               "explanation": "Die Formel lautet ad minus bc.", "difficulty": "3"}),
    ("Loesung nicht unter den Antworten", {"question": Q, "options": ["a", "b", "c", "d"], "answer": "e",
                                          "explanation": "Die Formel lautet ad minus bc.", "difficulty": 3}),
    ("Link in der Erklaerung", {"question": Q, "options": ["a", "b", "c", "d"], "answer": "b",
                                "explanation": "Siehe https://example.org/det", "difficulty": 3}),
    ("E-Mail in der Frage", {"question": Q + " Fragen an tutor@uni-beispiel.de", "options": ["a", "b", "c", "d"], "answer": "b",
                             "explanation": "Die Formel lautet ad minus bc.", "difficulty": 3}),
    ("Erklaerung fehlt", {"question": Q, "options": ["a", "b", "c", "d"], "answer": "b", "explanation": "", "difficulty": 3}),
    ("doppelte Antworten", {"question": Q, "options": ["gleich", "gleich"], "answer": "gleich",
                            "explanation": "Die Formel lautet ad minus bc.", "difficulty": 3}),
    ("Schwierigkeit ausserhalb", {"question": Q, "options": ["a", "b"], "answer": "b",
                                  "explanation": "Die Formel lautet ad minus bc.", "difficulty": 7}),
]


def render() -> str:
    SchemaSource()
    from app import week_library as wl
    key_cases = []
    for uni, prints in (("luh", ["a" * 64]), ("luh", ["b" * 64, "a" * 64]), ("luh", ["a" * 64, "b" * 64, "a" * 64]),
                        ("hildesheim", ["a" * 64, "b" * 64])):
        key_cases.append({"university": uni, "prints": prints, "key": wl.content_key(uni, prints)})
    form_cases = []
    for name, q in FORM_CASES:
        c, errs = wl.check_question(q)
        form_cases.append({"name": name, "question": q, "ok": not errs, "errors": errs, "answer": c["answer"] if c else None})
    row = {"status": "ready", "finished_at": "2026-11-04T10:00:00+00:00", "error_code": None, "error": None,
           "topics": [{"title": "Determinanten", "summary": "Rechenregeln für 2x2-Matrizen."}],
           "hints": ["Auf das Vorzeichen beim Zeilentausch achten."],
           "solutions": [{"task_hash": "0123456789abcdef", "nr": "1", "source": "uebungsblatt", "label": "Übungsblatt · Aufgabe 1",
                          "answer": "det(A) = -2", "explanation": "ad - bc = 1·4 - 2·3.", "steps": ["Formel ad - bc", "einsetzen"],
                          "official": True}],
           "sets": [{"nr": i, "title": f"Satz {i}", "focus": wl.SET_FOCUS[i - 1], "question_ids": [f"q{i}-{k}" for k in range(wl.SET_SIZE)]}
                    for i in (1, 2, 3)]}
    data = {
        "_hinweis": "Erzeugt mit tools/gen-week-sets-fixture.py aus app/week_library.py; nicht von Hand aendern.",
        "constants": {"version": wl.VERSION, "sets_per_week": wl.SETS, "min_sets": wl.MIN_SETS, "set_size": wl.SET_SIZE,
                      "statuses": list(wl.STATUSES), "right": "can_use_prepared_week_sets",
                      "quota_on_start": "library_tests", "never_charged": ["ai_tests_new", "ai_assist"],
                      "codes": {"plan_required": 403, "email_unverified": 403, "not_hosted": 501, "not_found": 404,
                                "week_invalid": 400, "not_prepared": 409, "no_material": 409, "missing_content": 409,
                                "set_not_found": 404, "set_empty": 409, "quota_exhausted": 429, "library_prep_limit": 429,
                                "ai_library_budget_exhausted": 429, "ai_not_configured": 503, "ai_not_configured_prices": 503,
                                "generation_failed": "status failed (im Rumpf error_code)"}},
        "endpoints": [
            {"method": "GET", "path": "/api/library/week-sets/{module_id}", "right": "can_use_prepared_week_sets",
             "returns": "module_id, sets_per_week, set_size, weeks[{week, label, files, status, sets}]"},
            {"method": "GET", "path": "/api/library/week-sets/{module_id}/{week}", "right": "can_use_prepared_week_sets",
             "returns": "module_id, week, status, topics, hints, solutions, sets[{nr, title, focus, count}], error_code, error"},
            {"method": "POST", "path": "/api/library/week-sets/{module_id}/{week}/prepare", "body": {"wait_s": "0..60, optional"},
             "right": "can_use_prepared_week_sets", "needs": "bestaetigte E-Mail", "returns": "wie GET und started (bool)",
             "charges": "nichts beim Konto; Kosten im Bibliotheksbudget"},
            {"method": "POST", "path": "/api/library/week-sets/{module_id}/{week}/sets/{nr}/start", "body": {"request_id": "optional"},
             "right": "can_use_prepared_week_sets", "returns": "test_id, title, question_count, charged (library_tests | null), reused",
             "charges": "library_tests (offener Test desselben Satzes: nichts)"},
            {"method": "GET", "path": "/api/library/week-sets/{module_id}/{week}/explain?question_id=…|task=…",
             "right": "can_use_prepared_week_sets", "returns": "kind question|task mit answer, explanation (task: steps, label)"},
        ],
        "key_cases": key_cases,
        "form_cases": form_cases,
        "card_modes": [{"hosted": h, "allowed": a, "status": s, "current": c, "mode": m} for h, a, s, c, m in CARD_MODES],
        "example_ready": {"module_id": 7, "week": 3, **wl.public(row, "ready")},
    }
    return json.dumps(data, ensure_ascii=False, indent=1) + "\n"


def build(check: bool) -> int:
    return 0 if write_or_check(OUT, render(), check) or not check else 1


if __name__ == "__main__":
    sys.exit(build("--check" in sys.argv))

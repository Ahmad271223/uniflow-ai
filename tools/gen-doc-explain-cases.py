"""Erzeugt packages/shared-contracts/fixtures/doc-explain/cases.json: Erwartungswerte der KI-Hilfe fuer das ganze Dokument,
wie app/doc_explain.py sie bildet, fuer den Geraete-Kern (Swift: DocExplainTests) und das Web (tests/js/doc-explain.test.mjs).
Absicht aus der Frage, Kapitel und Umfang, Aufgaben, Schritte mit Schluesseln und Prompts, Bloecke, Kostenzeilen. Alles
erfunden. Aufruf im Projektordner: python tools/gen-doc-explain-cases.py [--check]"""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "doc-explain" / "cases.json"
sys.path.insert(0, str(ROOT))

QUESTIONS = [
    "Erkläre die ganze Vorlesung", "nimm dem dokument erkläre ganze vorlesung", "Fasse das Dokument zusammen",
    "Gib mir eine Zusammenfassung der gesamten Vorlesung", "erkläre alle aufgaben", "Löse alle Aufgaben", "LÖSE ALLE AUFGABEN!",
    "Bitte rechne mir die Aufgaben vor", "Erkläre Seiten 5 bis 12", "Erkläre S. 3–4", "fasse seite 7-9 zusammen",
    "Erkläre von Seite 2 bis Seite 6", "erkläre ab Seite 7", "Fasse Kapitel 3 zusammen", "Erkläre Abschnitt 2",
    "Erkläre alle Aufgaben auf dieser Seite", "geh die Aufgaben von Seite 2 bis 3 durch", "Überblick über alle Folien",
    "Was ist ein Eigenwert?", "Was steht auf Seite 5?", "Seiten 5 bis 12", "Erkläre das", "", "   ",
    "Wie löse ich Aufgabe 2?", "Erkläre Kapitel 3 auf Seite 4",
]

TOC_TEXTS = ["Lineare Algebra\nInhalt\n1 Vektoren\n2 Matrizen\n3 Eigenwerte\n4 Anwendungen",
             "1 Vektoren\nEin Vektor ...", "Basen und Dimension", "2 Matrizen\nLineare Abbildungen", "Kapitel 3: Eigenwerte\nPolynom",
             "3.1 Diagonalisierung\nwenn ...", "4 Anwendungen\nPageRank", "Anhang\n3 Punkte gibt es für jede Teilaufgabe"]

SHEET = ["Übungsblatt 3 – Lineare Algebra (€, 😀)\nAufgabe 1 (4 Punkte)\nBerechne die Determinante der Matrix A = (1 2; 3 4).\n"
         "  Aufgabe 2\na) Zeige, dass A invertierbar ist.",
         "b) Folgere daraus die Lösung. Siehe Aufgabe 1.\nAufgabe 1\nWiederholung\nÜBUNGSAUFGABE 3A\nLöse das LGS mit Gauß.\n"
         "Exercise 3.2b\nInterpret the result.",
         "   ", "Abgabe bis Freitag im Briefkasten.\nProblem 4\nBeweise die Aussage für alle n ∈ ℕ."]


def lecture(pages: int, chars: int, tag: str) -> list[str]:
    out = []
    for p in range(1, pages + 1):
        body = f"Folie {p} – {tag}: Eigenwerte, Matrizen, Abbildungen (ä ö ü ß, ∑ x²). "
        out.append((body * (chars // len(body) + 1))[:chars])
    return out


def public_step(s: dict, page_count: int) -> dict:
    from app import doc_explain as de
    prompt = de.step_prompt(s, page_count, [])
    return {"id": s["id"], "n": s["n"], "kind": s["kind"], "from": s["from"], "to": s["to"], "title": s["title"], "tasks": s["tasks"],
            "hash": s["hash"], "store_mode": de.store_mode(s),
            "prompt_sha": hashlib.sha256(prompt.encode("utf-8")).hexdigest(), "prompt_chars": len(prompt)}


def build() -> dict:
    from app import doc_explain as de
    big = lecture(10, 5000, "Lineare Algebra")
    small = lecture(4, 900, "Kurz")
    scan_texts = ["", "  3 ", small[0], small[1]]
    plans = []
    for name, mode, texts, a, b, summaries, index_tasks in (
            ("big_lecture", "lecture", big, 1, 10, None, None),
            ("short_lecture", "lecture", small, 1, 4, None, None),
            ("scan_with_index", "lecture", scan_texts, 1, 4, {2: "Skizze eines Regelkreises"}, None),
            ("sheet", "tasks", SHEET, 1, 4, None, None),
            ("sheet_page_2", "tasks", SHEET, 2, 2, None, None),
            ("no_tasks", "tasks", small, 1, 2, None, None),
            ("index_tasks", "tasks", small, 1, 4, None, [(3, "Aufgabe 7"), (3, "aufgabe 7"), (9, "Aufgabe 9"), (2, "Aufgabe 5")])):
        p = de.plan_steps(mode, texts, a, b, summaries, index_tasks)
        plans.append({"name": name, "mode": mode, "texts": None if name == "big_lecture" else texts,
                      "generate": {"pages": 10, "chars": 5000, "tag": "Lineare Algebra"} if name == "big_lecture" else None,
                      "from": a, "to": b, "index_summaries": {str(k): v for k, v in (summaries or {}).items()},
                      "index_tasks": [[pg, lab] for pg, lab in (index_tasks or [])],
                      "steps": [public_step(s, len(texts)) for s in p["steps"]], "skipped_pages": p["skipped_pages"]})
    sheet_steps = de.plan_steps("tasks", SHEET, 1, 4)["steps"]
    short_steps = de.plan_steps("lecture", small, 1, 4)["steps"]
    big_steps = de.plan_steps("lecture", big, 1, 10)["steps"]
    sections = [{"title": "Eigenwerte", "from": 1, "to": 3, "text": "Kernideen " * 200}, {"title": "Matrizen", "from": 4, "to": 10, "text": "kurz"}]
    answers = [
        ("tasks", sheet_steps[0], "Gern!\n## Aufgabe 1 [S. 1]\nDeterminante ...\n## Aufgabe 2 [S. 1–2]\nInvertierbar ...\r\n"
                                  "## Übungsaufgabe 3a [S. 9]\nGauß ...\n### Exercise 3.2b:\nResult\n# Problem 4 [Seite 4]\nBeweis"),
        ("tasks_plain", sheet_steps[0], "Nur Text ohne Überschrift.\n\nZweiter Absatz."),
        ("full", short_steps[0], "## Überblick [S. 1–4]\nRote Linie.\n## Eigenwerte [S. 2-3]\n$Ax = \\lambda x$\nPrüfungsrelevant: ja\n"
                                 "## Prüfungsrelevant [S. 1–4]\n- Polynom (S. 2)\n## Leer [S. 3]\n"),
        ("lecture_intro", big_steps[0], "Ein langer Vorspann. " * 20 + "\n## Teil [S. 2–1]\nText"),
        ("empty", big_steps[1], ""),
    ]
    return {
        "_hinweis": "Erzeugt mit tools/gen-doc-explain-cases.py aus app/doc_explain.py; nicht von Hand aendern.",
        "constants": {"version": de.DOC_EXPLAIN_VERSION, "lang": de.LANG, "max_pages": de.MAX_PAGES, "page_chars_max": de.PAGE_CHARS_MAX,
                      "lecture_step_chars": de.LECTURE_STEP_CHARS, "task_step_chars": de.TASK_STEP_CHARS,
                      "tasks_per_step": de.TASKS_PER_STEP, "task_chars_max": de.TASK_CHARS_MAX, "confirm_above": de.CONFIRM_ABOVE,
                      "overview_section_chars": de.OVERVIEW_SECTION_CHARS, "overview_chars": de.OVERVIEW_CHARS},
        "system": de.SYSTEM,
        "intents": [{"q": q, "out": de.parse_intent(q)} for q in QUESTIONS],
        "chapters": {"texts": TOC_TEXTS, "found": {str(n): list(de.find_chapter(TOC_TEXTS, n) or []) for n in range(1, 6)}},
        "scopes": [{"scope": s, "pages": n, "current": c, "out": _scope(de, s, n, c)}
                   for s, n, c in (({"kind": "all"}, 40, 3), ({"kind": "page"}, 40, 9), ({"kind": "page"}, 5, 9),
                                   ({"kind": "range", "from": 12, "to": 5}, 40, 1), ({"kind": "range", "from": 30, "to": None}, 40, 1),
                                   ({"kind": "range", "from": 0, "to": 3}, 40, 1), ({"kind": "range", "from": 50, "to": 60}, 40, 1),
                                   ({"kind": "chapter", "chapter": 3}, 8, 1), ({"kind": "chapter", "chapter": 9}, 8, 1),
                                   ({"kind": "egal"}, 40, 1), ({"kind": "all"}, 151, 1), (None, 12, 1))],
        "tasks": {"texts": SHEET, "out": de.detect_tasks(SHEET, 1, 4)},
        "plans": plans,
        "prompts": [{"plan": "sheet", "step": 0, "prompt": de.step_prompt(sheet_steps[0], 4)},
                    {"plan": "short_lecture", "step": 0, "prompt": de.step_prompt(short_steps[0], 4)},
                    {"plan": "no_tasks", "step": 0, "prompt": de.step_prompt(de.plan_steps("tasks", small, 1, 2)["steps"][0], 4)},
                    {"plan": "big_lecture", "step": len(big_steps) - 1, "sections": sections,
                     "prompt": de.step_prompt(big_steps[-1], 10, sections)}],
        "blocks": [{"name": n, "step": {k: s[k] for k in ("kind", "from", "to", "title", "tasks")}, "answer": a, "out": de.parse_blocks(a, s)}
                   for n, s, a in answers],
        "estimates": [{"in": {"way": w, "calls": c, "cached": k, "credits": cr, "remaining": r}, "out": de.estimate_message(w, c, k, cr, r)}
                      for w, c, k, cr, r in (("credits", 6, 0, 6, 74), ("credits", 2, 0, 2, 74), ("credits", 3, 1, 3, 74),
                                             ("credits", 4, 2, 5, 74), ("credits", 6, 0, 6, 2), ("credits", 1, 0, 1, None),
                                             ("credits", 0, 4, 0, 74), ("chatgpt", 4, 0, None, None), ("chatgpt", 1, 0, None, None),
                                             ("chatgpt", 3, 2, None, None), ("local", 5, 0, None, None))],
        "labels": [{"from": a, "to": b, "short": de.pages_label(a, b), "words": de.range_words(a, b)} for a, b in ((5, 5), (5, 7))],
        "store_modes": [{"mode": m, "ok": de.is_store_mode(m)} for m in ("doc1_lecture_2_30", "doc1_full_1_4", "doc12_overview_4_150",
                                                                         "doc1_quiz_1_2", "explain", "doc1_tasks_1", "")],
    }


def _scope(de, s, n, c):
    try:
        return de.resolve_scope(s, n, c, TOC_TEXTS)
    except de.DocExplainError as e:
        return {"error": e.code}


def main(argv: list[str]) -> int:
    text = json.dumps(build(), ensure_ascii=False, indent=1) + "\n"
    if "--check" in argv:
        current = OUT.read_text(encoding="utf-8") if OUT.exists() else ""
        if current != text:
            print(f"{OUT} ist nicht aktuell: python tools/gen-doc-explain-cases.py")
            return 1
        print("doc-explain cases.json aktuell")
        return 0
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text, encoding="utf-8")
    print(f"geschrieben: {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

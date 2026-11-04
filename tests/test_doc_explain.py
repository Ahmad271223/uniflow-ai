"""KI-Hilfe fuer das ganze Dokument (05.11.2026, docs/KI-GANZES-DOKUMENT-2026-11-05.md, app/doc_explain.py): Absicht aus
der Frage, Umfang und Kapitel, Aufgaben erkennen, Schritte, Bloecke mit Seiten, Kostenzeile, gemeinsamer Speicher
(der zweite mit demselben Dokument zahlt 0) und Credits im Dienst. Keine echte KI: ai.ask bzw. FakeAI."""
import json
import uuid

import pytest
from conftest import asgi_call
from test_subscriptions import FakeAI, _j, hosted, user  # noqa: F401 - hosted ist eine Fixture

from app import doc_explain as de


def lecture_texts(tag: str, pages: int = 40, chars: int = 1500) -> list[str]:
    """Erfundene Vorlesung: je Seite etwa `chars` Zeichen, eindeutig je Test (gemeinsamer Speicher)"""
    out = []
    for p in range(1, pages + 1):
        head = f"{p // 10 + 1} Abschnitt {p // 10 + 1}\n" if p % 10 == 1 else ""
        body = f"Folie {p} zu {tag}: Eigenwerte, Matrizen und lineare Abbildungen. "
        out.append(head + (body * (chars // len(body) + 1))[:chars])
    return out


SHEET = ["Übungsblatt 3\nAufgabe 1 (4 Punkte)\nBerechne die Determinante der Matrix A.\nAufgabe 2\na) Zeige, dass A invertierbar ist.",
         "b) Folgere daraus die Lösung.\nAufgabe 3a\nLöse das LGS mit Gauß.\nAufgabe 3b\nInterpretiere das Ergebnis geometrisch.",
         "Abgabe bis Freitag im Briefkasten."]


# ---------------------------------------------------------------- reine Regeln

@pytest.mark.parametrize("q, mode, scope", [
    ("Erkläre die ganze Vorlesung", "lecture", {"kind": "all"}),
    ("nimm dem dokument erkläre ganze vorlesung", "lecture", {"kind": "all"}),
    ("Fasse das Dokument zusammen", "lecture", {"kind": "all"}),
    ("erkläre alle aufgaben", "tasks", {"kind": "all"}),
    ("Löse alle Aufgaben", "tasks", {"kind": "all"}),
    ("Erkläre Seiten 5 bis 12", "lecture", {"kind": "range", "from": 5, "to": 12}),
    ("Erkläre S. 3–4", "lecture", {"kind": "range", "from": 3, "to": 4}),
    ("Fasse Kapitel 3 zusammen", "lecture", {"kind": "chapter", "chapter": 3}),
    ("Erkläre alle Aufgaben auf dieser Seite", "tasks", {"kind": "page"}),
    ("geh die Aufgaben von Seite 2 bis 3 durch", "tasks", {"kind": "range", "from": 2, "to": 3}),
])
def test_intent_from_natural_language(q, mode, scope):
    assert de.parse_intent(q) == {"mode": mode, "scope": scope}


@pytest.mark.parametrize("q", ["Was ist ein Eigenwert?", "Was steht auf Seite 5?", "Erkläre das", "", "Seiten 5 bis 12"])
def test_normal_questions_stay_with_the_page(q):
    assert de.parse_intent(q) is None


def test_scope_and_chapters():
    texts = ["Lineare Algebra\nInhalt\n1 Vektoren\n2 Matrizen\n3 Eigenwerte\n4 Anwendungen",
             "1 Vektoren\nEin Vektor ...", "Basen und Dimension", "2 Matrizen\nLineare Abbildungen", "3 Eigenwerte\nPolynom",
             "3.1 Diagonalisierung\nwenn ...", "4 Anwendungen\nPageRank"]
    assert de.find_chapter(texts, 3) == (5, 6), "Inhaltsverzeichnis zaehlt nicht"
    assert de.find_chapter(texts, 4) == (7, 7) and de.find_chapter(texts, 9) is None
    assert de.resolve_scope({"kind": "chapter", "chapter": 1}, 7, 1, texts) == {"kind": "chapter", "from": 2, "to": 3,
                                                                                "label": "Kapitel 1 (Seiten 2–3)"}
    assert de.resolve_scope({"kind": "all"}, 7, 3)["label"] == "Ganzes Dokument (Seiten 1–7)"
    assert de.resolve_scope({"kind": "range", "from": 12, "to": 5}, 40, 1)["label"] == "Seiten 5–12"
    assert de.resolve_scope({"kind": "range", "from": 30, "to": None}, 40, 1)[("to")] == 40
    assert de.resolve_scope({"kind": "page"}, 40, 9)["label"] == "Seite 9"
    for bad, code in (({"kind": "chapter", "chapter": 9}, "chapter_not_found"), ({"kind": "range", "from": 50, "to": 60}, "bad_scope"),
                      ({"kind": "egal"}, "bad_scope")):
        with pytest.raises(de.DocExplainError) as e:
            de.resolve_scope(bad, 40, 1, texts)
        assert e.value.code == code
    with pytest.raises(de.DocExplainError) as e:
        de.resolve_scope({"kind": "all"}, 400, 1)
    assert e.value.code == "too_long" and "150" in e.value.message


def test_tasks_are_detected_once_each_with_pages_and_text():
    tasks = de.detect_tasks(SHEET, 1, 3)
    assert [(t["label"], t["from"], t["to"]) for t in tasks] == [("Aufgabe 1", 1, 1), ("Aufgabe 2", 1, 2), ("Aufgabe 3a", 2, 2),
                                                                  ("Aufgabe 3b", 2, 3)]
    assert tasks[1]["text"].startswith("Aufgabe 2\na) Zeige") and "b) Folgere" in tasks[1]["text"], "Aufgabe ueber zwei Seiten"
    # ohne Treffer: Aufgaben aus dem Dokument-Index
    assert de.detect_tasks(["Text ohne Aufgaben " * 5, "noch mehr " * 5], 1, 2, [(2, "Aufgabe 7"), (2, "aufgabe 7"), (5, "X")]) == [
        {"label": "Aufgabe 7", "from": 2, "to": 2, "text": ("noch mehr " * 5).strip()}]


def test_a_40_page_lecture_is_three_parts_and_an_overview():
    texts = lecture_texts("plan")
    p = de.plan_steps("lecture", texts, 1, 40)
    kinds = [(s["kind"], s["from"], s["to"]) for s in p["steps"]]
    assert [k for k, _, _ in kinds] == ["lecture", "lecture", "lecture", "overview"]
    assert kinds[0][1] == 1 and kinds[2][2] == 40 and all(kinds[i][2] + 1 == kinds[i + 1][1] for i in range(2)), "lueckenlos"
    assert len({s["hash"] for s in p["steps"]}) == 4 and p["skipped_pages"] == []
    # derselbe Text an anderer Stelle (anderer Zeilenumbruch) gibt denselben Schluessel; ein anderes Dokument nicht
    again = de.plan_steps("lecture", [t.replace(" ", "\n", 3) for t in texts], 1, 40)
    assert [s["hash"] for s in again["steps"]] == [s["hash"] for s in p["steps"]]
    assert de.plan_steps("lecture", lecture_texts("anders"), 1, 40)["steps"][0]["hash"] != p["steps"][0]["hash"]
    # kurz: ein einziger Aufruf mit Ueberblick
    short = de.plan_steps("lecture", texts, 1, 5)["steps"]
    assert [s["kind"] for s in short] == ["full"] and "## Überblick [S. 1–5]" in de.step_prompt(short[0], 40)
    # Seiten ohne Text werden ausgelassen, ausser der Dokument-Index kennt sie
    scan = de.plan_steps("lecture", ["", "  3 "] + texts[:2], 1, 4, index_summaries={2: "Skizze eines Regelkreises"})
    assert scan["skipped_pages"] == [1] and "[Einordnung aus der Bibliothek] Skizze" in scan["steps"][0]["parts"][0]
    with pytest.raises(de.DocExplainError) as e:
        de.plan_steps("lecture", ["", ""], 1, 2)
    assert e.value.code == "no_text"


def test_tasks_steps_prompt_and_blocks():
    st = de.plan_steps("tasks", SHEET, 1, 3)["steps"]
    assert [(s["kind"], s["title"]) for s in st] == [("tasks", "Aufgabe 1, Aufgabe 2, Aufgabe 3a, Aufgabe 3b")]
    prompt = de.step_prompt(st[0], 3)
    assert "in dieser Reihenfolge: Aufgabe 1, Aufgabe 2, Aufgabe 3a, Aufgabe 3b" in prompt and de.UNTRUSTED in prompt
    answer = ("Gern!\n## Aufgabe 1 [S. 1]\nDeterminante ...\n## Aufgabe 2 [S. 1–2]\nInvertierbar ...\n"
              "## Aufgabe 3a [S. 9]\nGauß ...\n### Aufgabe 3b:\nGeometrisch ...")
    blocks = de.parse_blocks(answer, st[0])
    assert [(b["kind"], b["title"], b["from"], b["to"]) for b in blocks] == [
        ("task", "Aufgabe 1", 1, 1), ("task", "Aufgabe 2", 1, 2), ("task", "Aufgabe 3a", 2, 2), ("task", "Aufgabe 3b", 2, 3)], \
        "Vorspann faellt weg, falsche Seite -> Seite der Aufgabe"
    # ohne Ueberschriften: ein Block fuer den ganzen Schritt; keine Aufgabe erkannt -> die KI sucht seitenweise
    assert de.parse_blocks("Nur Text.", st[0]) == [{"kind": "task", "title": st[0]["title"], "from": 1, "to": 3, "text": "Nur Text."}]
    scan = de.plan_steps("tasks", ["Hier stehen nur Fragen zum Nachdenken, nummeriert " * 3], 1, 1)["steps"]
    assert scan[0]["kind"] == "scan" and "Keine Aufgaben auf diesen Seiten" in de.step_prompt(scan[0], 1)


def test_cost_line_asks_before_more_than_three_credits():
    assert de.estimate_message("credits", 6, 0, 6, 74) == {"message": "Kostet etwa 6 Credits, du hast 74.", "confirm": True, "enough": True}
    assert de.estimate_message("credits", 2, 0, 2, 74)["confirm"] is False
    assert de.estimate_message("credits", 3, 1, 3, 74)["message"] == "Kostet etwa 3 Credits, du hast 74. 1 von 4 Teilen ist schon erklärt (0 Credits)."
    assert de.estimate_message("credits", 6, 0, 6, 2)["enough"] is False
    assert de.estimate_message("credits", 0, 4, 0, 74) == {"message": "Schon erklärt · 0 Credits", "confirm": False, "enough": True}
    assert de.estimate_message("chatgpt", 4, 0)["message"] == "4 Anfragen über dein ChatGPT · 0 Credits."


def test_estimate_for_a_typical_lecture_with_the_recommended_model():
    """40 Seiten mit gpt-6-luna: jede Anfrage bleibt unter einem Cent, der Lauf kostet etwa so viele Credits wie Teile"""
    steps = de.plan_steps("lecture", lecture_texts("kosten"), 1, 40)["steps"]
    assert sum(de.estimate_step_credits(s, "gpt-6-luna") for s in steps) == 4
    assert sum(de.estimate_step_credits(s, "gpt-6-luna") for s in de.plan_steps("tasks", SHEET, 1, 3)["steps"]) == 1


def test_store_keeps_three_variants_and_never_overwrites(app):
    conn = de.connect()
    try:
        key = uuid.uuid4().hex * 2
        assert de.cached(conn, key) is None
        assert [de.store(conn, key, "full", f"Text {i}", "m")["variant"] for i in range(4)] == [1, 2, 3, 0]
        assert de.cached(conn, key)["text"] == "Text 0" and de.cached_keys(conn, [key, "x"]) == {key}
    finally:
        conn.close()


def test_store_modes_for_the_explain_records():
    from app import page_explain
    st = de.plan_steps("lecture", lecture_texts("modus"), 1, 40)["steps"]
    assert de.store_mode(st[1]) == f"doc1_lecture_2_{st[1]['to']}" and de.is_store_mode(de.store_mode(st[3]))
    assert page_explain.check_mode(de.store_mode(st[0])) and not de.is_store_mode("ask")


# ---------------------------------------------------------------- Endpunkte am eigenen PC

def _file(file_id: str):
    from app import db
    db.init_db()
    with db.cursor() as conn:
        conn.execute("INSERT OR IGNORE INTO courses(id, title, kind, active, created_at) VALUES ('dx-kurs', 'Lineare Algebra', 'vorlesung', 1, '2026-10-26')")
        conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, status) VALUES (?, 'dx-kurs', 'vl.pdf', 'neu')", (file_id,))


def post(app, path, body, headers=None):
    return _j(asgi_call(app, "POST", path, body=json.dumps(body), headers=headers))


def test_local_run_plans_steps_streams_blocks_and_reuses_them(app, monkeypatch):
    from app import ai, scriptsearch
    texts = lecture_texts(uuid.uuid4().hex)
    _file("dx-vl")
    monkeypatch.setattr(scriptsearch, "page_texts", lambda conn, fid, *a, **k: texts if fid == "dx-vl" else [])
    monkeypatch.setattr(ai, "uses_chatgpt", lambda: False)
    calls = []

    def fake_ask(prompt, system):
        calls.append(prompt)
        if "Genau zwei Abschnitte" in prompt:
            return "## Überblick [S. 1–40]\nRote Linie.\n## Prüfungsrelevant [S. 1–40]\n- Eigenwerte (S. 12)"
        a = int(prompt.split("(Seiten ")[1].split("–")[0])
        return f"## Abschnitt ab {a} [S. {a}]\nKernideen.\nPrüfungsrelevant: Polynom."
    monkeypatch.setattr(ai, "ask", fake_ask)
    # keine Absicht in der Frage -> normale KI-Hilfe
    assert post(app, "/api/ai/document/plan", {"file_id": "dx-vl", "question": "Was ist ein Eigenwert?"}) == (200, {"intent": False})
    st, plan = post(app, "/api/ai/document/plan", {"file_id": "dx-vl", "page": 3, "question": "Erkläre die ganze Vorlesung"})
    assert st == 200, plan
    assert (plan["mode"], plan["scope"]["label"], plan["calls"], plan["cached"]) == ("lecture", "Ganzes Dokument (Seiten 1–40)", 4, 0)
    assert plan["estimate"] == {"way": "local", "credits": None, "calls": 4} and plan["confirm"] is True
    assert plan["message"] == "4 Anfragen an die KI." and plan["title"] == "Ganze Vorlesung erklären · Ganzes Dokument (Seiten 1–40)"
    body = {"file_id": "dx-vl", "page": 3, "mode": plan["mode"], "scope": {"kind": "all"}}
    # der Ueberblick braucht die Abschnitte
    st, d = post(app, "/api/ai/document/step", {**body, "step": plan["steps"][3]["id"]})
    assert (st, d["code"]) == (409, "sections_missing")
    blocks = []
    for s in plan["steps"]:
        st, d = post(app, "/api/ai/document/step", {**body, "step": s["id"]})
        assert st == 200, d
        assert d["stored"]["stored"] is False and d["stored"]["variant"] == 1
        blocks += d["blocks"]
    assert len(calls) == 4 and "Abschnitt ab 1" in calls[3], "Ueberblick aus den Abschnitten"
    assert [b["kind"] for b in blocks] == ["section"] * 3 + ["overview"] * 2 and blocks[0]["from"] == 1
    # zweiter Lauf: alles schon erklaert, 0 Anfragen
    st, plan2 = post(app, "/api/ai/document/plan", {**body})
    assert (plan2["calls"], plan2["cached"], plan2["message"], plan2["confirm"]) == (0, 4, "Schon erklärt · 0 Credits", False)
    assert all(s["cached"] for s in plan2["steps"])
    st, d = post(app, "/api/ai/document/step", {**body, "step": plan2["steps"][0]["id"]})
    assert d["stored"]["stored"] is True and d["stored"]["source"] == "cache" and len(calls) == 4
    # "Neu erklaeren lassen" fragt live und belegt den naechsten Platz
    st, d = post(app, "/api/ai/document/step", {**body, "step": plan2["steps"][0]["id"], "force": True})
    assert d["stored"]["variant"] == 2 and len(calls) == 5
    # unbekannter Schritt, fehlender Modus, Kapitel nicht gefunden
    assert post(app, "/api/ai/document/step", {**body, "step": "9:lecture:1-2"})[1]["code"] == "step_not_found"
    assert post(app, "/api/ai/document/plan", {"file_id": "dx-vl", "mode": "quiz"})[1]["code"] == "bad_mode"
    st, d = post(app, "/api/ai/document/plan", {"file_id": "dx-vl", "question": "Fasse Kapitel 9 zusammen"})
    assert (st, d["code"]) == (422, "chapter_not_found")
    st, d = post(app, "/api/ai/document/plan", {"file_id": "dx-vl", "question": "Fasse Kapitel 2 zusammen"})
    assert st == 200 and d["scope"]["from"] == 11 and d["scope"]["to"] == 20


def test_local_tasks_run_uses_browser_text_when_the_service_has_none(app, monkeypatch):
    from app import ai, scriptsearch
    _file("dx-blatt")
    monkeypatch.setattr(scriptsearch, "page_texts", lambda conn, fid, *a, **k: [])
    monkeypatch.setattr(ai, "uses_chatgpt", lambda: True)
    monkeypatch.setattr(ai, "ask", lambda prompt, system: "## Aufgabe 1 [S. 1]\nA\n## Aufgabe 2\nB\n## Aufgabe 3a\nC\n## Aufgabe 3b\nD")
    sheet = [t + f" ({uuid.uuid4().hex})" for t in SHEET]
    assert post(app, "/api/ai/document/plan", {"file_id": "dx-blatt", "mode": "tasks"})[1]["code"] == "no_content"
    st, plan = post(app, "/api/ai/document/plan", {"file_id": "dx-blatt", "question": "Löse alle Aufgaben", "page_texts": sheet})
    assert st == 200, plan
    assert plan["estimate"]["way"] == "chatgpt" and plan["message"] == "1 Anfrage über dein ChatGPT · 0 Credits." and plan["confirm"] is False
    assert plan["steps"][0]["tasks"][1] == {"label": "Aufgabe 2", "from": 1, "to": 2}
    st, d = post(app, "/api/ai/document/step", {"file_id": "dx-blatt", "mode": "tasks", "scope": plan["scope"], "step": plan["steps"][0]["id"],
                                                "page_texts": sheet})
    assert st == 200, d
    assert [(b["title"], b["from"], b["to"]) for b in d["blocks"]] == [("Aufgabe 1", 1, 1), ("Aufgabe 2", 1, 2), ("Aufgabe 3a", 2, 2),
                                                                       ("Aufgabe 3b", 2, 3)]


# ---------------------------------------------------------------- im Dienst: Recht, Credits, gemeinsamer Speicher

def _hosted_file(app, headers, texts, monkeypatch):
    from app import scriptsearch
    from test_subscriptions import add_file
    add_file(app, headers, "dx-doc")
    monkeypatch.setattr(scriptsearch, "page_texts", lambda conn, fid, *a, **k: texts)


def test_hosted_needs_pro_ai_and_charges_credits_once_then_shares(hosted, monkeypatch):
    from app import ai_backend, credits
    fake = FakeAI()
    ai_backend.set_provider(fake)
    monkeypatch.setenv("LERNAPP_AI_MODEL", "gpt-6-luna")
    monkeypatch.setenv("LERNAPP_AI_PRICE_IN_EUR", "0.10")          # Preise wie gpt-6-luna (conftest setzt fast 0)
    monkeypatch.setenv("LERNAPP_AI_PRICE_OUT_EUR", "0.50")
    monkeypatch.setenv("LERNAPP_CREDITS_PRO_AI", "100")
    texts = lecture_texts(uuid.uuid4().hex)
    _, plus = user(hosted, "plus@beispiel.de", plan="plus")
    _hosted_file(hosted, plus, texts, monkeypatch)
    st, d = post(hosted, "/api/ai/document/plan", {"file_id": "dx-doc", "question": "Erkläre die ganze Vorlesung"}, plus)
    assert (st, d["code"]) == (403, "plan_required"), "Plus hat keine KI: Tarif-Schranken bleiben"
    assert post(hosted, "/api/ai/document/plan", {"file_id": "dx-doc", "question": "Was ist das?"}, plus) == (200, {"intent": False})

    u1, h1 = user(hosted, "pro1@beispiel.de", plan="pro_ai")
    _hosted_file(hosted, h1, texts, monkeypatch)
    st, plan = post(hosted, "/api/ai/document/plan", {"file_id": "dx-doc", "question": "Erkläre die ganze Vorlesung"}, h1)
    assert st == 200, plan
    assert plan["estimate"] == {"way": "credits", "credits": 4, "calls": 4}
    assert plan["message"] == "Kostet etwa 4 Credits, du hast 100." and plan["confirm"] is True and plan["enough"] is True
    body = {"file_id": "dx-doc", "mode": "lecture", "scope": plan["scope"]}
    for i, s in enumerate(plan["steps"]):
        st, d = post(hosted, "/api/ai/document/step", {**body, "step": s["id"], "request_id": f"r{i}"}, h1)
        assert st == 200, d
        assert d["credits"]["charged"] == 1 and d["stored"]["shared"] is True, d
    assert fake.calls == 4
    assert d["credits"]["remaining"] == 96
    # dieselbe request_id noch einmal: nicht doppelt berechnet
    st, d = post(hosted, "/api/ai/document/step", {**body, "step": plan["steps"][0]["id"], "request_id": "r0", "force": True}, h1)
    assert st == 200 and d["credits"]["replay"] is True and fake.calls == 4

    # zweites Konto mit demselben Dokument: alles schon erklaert, 0 Credits, keine KI
    u2, h2 = user(hosted, "pro2@beispiel.de", plan="pro_ai")
    _hosted_file(hosted, h2, texts, monkeypatch)
    st, plan2 = post(hosted, "/api/ai/document/plan", body, h2)
    assert (plan2["calls"], plan2["message"], plan2["estimate"]["credits"]) == (0, "Schon erklärt · 0 Credits", 0)
    for i, s in enumerate(plan2["steps"]):
        st, d = post(hosted, "/api/ai/document/step", {**body, "step": s["id"], "request_id": f"s{i}"}, h2)
        assert st == 200 and d["stored"]["source"] == "cache" and d["credits"]["charged"] == 0
    assert fake.calls == 4 and d["credits"]["remaining"] == 100
    conn = credits.connect()
    try:
        rows = conn.execute("SELECT funding, state, charged FROM credit_ledger WHERE user_id=?", (u2["id"],)).fetchall()
    finally:
        conn.close()
    assert sorted(tuple(r) for r in rows) == [("shared", "free", 0)] * 4


def test_hosted_plan_says_when_credits_are_not_enough(hosted, monkeypatch):
    from app import ai_backend
    ai_backend.set_provider(FakeAI())
    monkeypatch.setenv("LERNAPP_AI_MODEL", "gpt-6-luna")
    monkeypatch.setenv("LERNAPP_CREDITS_PRO_AI", "2")
    _, h = user(hosted, "knapp@beispiel.de", plan="pro_ai")
    _hosted_file(hosted, h, lecture_texts(uuid.uuid4().hex), monkeypatch)
    st, plan = post(hosted, "/api/ai/document/plan", {"file_id": "dx-doc", "mode": "lecture", "scope": {"kind": "all"}}, h)
    assert st == 200 and plan["enough"] is False
    assert plan["message"].startswith("Reicht nicht: kostet etwa 4 Credits, du hast 2.")

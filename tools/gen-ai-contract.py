"""Erzeugt packages/shared-contracts/ai/contract.json: die KI von StudiNow so, wie app/ai.py und app/chatgpt_login.py
sie am PC bauen, als gemeinsamer Vertrag fuer die Geraete-Kerne (Swift: AIContractTests). Wer KI-Anfragen selbst
stellt (iPad mit dem ChatGPT-Abo des Nutzers), baut daraus byte-gleiche Prompts und prueft Antworten gleich.

Inhalt:
- texts: System-Prompts, Modi des Tutors, Analysefelder, Regel des Wochentests (29.10.2026)
- prompts: je Funktion Eingaben -> Prompt (Tutor mit Quellen und Kuerzungen, Analyse aus Text,
  Wochentest mit und ohne Altklausur samt Materialblock, Bewertung)
- parse_json: Antworttext -> JSON oder Fehler
- check_week_test: Antwort -> Grund (null = in Ordnung), auch mit Parametern des Dialogs (options)
- week_test_options / week_test_distribution / week_test_is_standard: Parameter des Dialogs (04.11.2026) pruefen,
  Schwierigkeiten verteilen, Standardeinstellung (nur sie wird geteilt) erkennen
- chatgpt: Adressen, Scopes, Autorisierungsadressen, PKCE, Zugangsdaten aus Token-Antworten, Anfrage an die
  Responses API, Text aus der Antwort, Fehlercodes
Alles erfunden; nichts geht ins Netz. Aufruf im Projektordner: python tools/gen-ai-contract.py [--check]
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "packages" / "shared-contracts" / "ai" / "contract.json"


def _tutor_cases(ai) -> list[dict]:
    long = "Lange Seite ä€😀 " * 800                       # ueber 9000 Zeichen, mit Umlaut, Euro und Emoji
    src = [{"n": 1, "title": "Testskript Kapitel 2", "page": 4, "current": True, "snippet": "wird nicht angehaengt"},
           {"n": 2, "name": "vl03.pdf", "page": 12, "snippet": "Grenzwert " * 60},
           {"n": 3, "title": "Uebungsblatt 3", "page": 1}]
    inputs = [
        {"mode": "explain", "page_text": "Definition: Eine Folge heisst konvergent ...", "selection": "konvergent",
         "course": "Testmathe I", "file_name": "vl02.pdf", "page": 3},
        {"mode": "steps", "page_text": "Aufgabe 3", "selection": "Markierung ü " * 400, "course": "Testkurs", "file_name": "m.pdf", "page": 7},
        {"mode": "check", "page_text": "Aufgabe 1", "own_solution": "x = 2 " * 1200, "question": "Stimmt das? " * 200,
         "course": "Testphysik", "file_name": "blatt1.pdf"},
        {"mode": "unbekannt", "page_text": "", "course": "", "file_name": ""},
        {"mode": "summary", "page_text": long, "selection": "  \n ", "course": "Testkurs", "file_name": "s.pdf", "page": 1,
         "sources": src},
        {"mode": "flashcards", "page_text": "Begriffe", "course": "Testkurs", "file_name": "k.pdf", "page": 2, "sources": src},
        {"mode": "ask", "page_text": "Aufgabe 4: Berechne den Grenzwert.", "question": "Und warum darf ich hier kuerzen?",
         "course": "Testmathe I", "file_name": "blatt4.pdf", "page": 2,
         "history": [{"role": "user", "text": "Loese Aufgabe 4"}, {"role": "assistant", "text": "  Schritt 1: ä€😀 " * 200},
                     {"role": "user", "text": "Danke"}]},
        {"mode": "hints", "page_text": "  Aufgabe 2  ", "selection": "  markiert  ", "course": "K", "file_name": "f.pdf",
         "page": 0, "sources": []},
        # Kontext aus Stud.IP (02.11.2026): Kursbeschreibung und Sitzungsthemen, gekuerzt
        {"mode": "explain", "page_text": "Satz von Bolzano", "course": "Testmathe I", "file_name": "vl05.pdf", "page": 2, "sources": src,
         "studip": "  Kursbeschreibung: Analysis fuer Ingenieure\nSitzung am 03.11.: Stetigkeit ä€😀  " + "x" * 800},
        {"mode": "ask", "page_text": "Aufgabe", "question": "Warum?", "course": "K", "file_name": "f.pdf", "studip": " \n "},
    ]
    out = []
    for i in inputs:
        args = {k: v for k, v in i.items() if k != "mode"}
        out.append({"in": i, "prompt": ai.tutor_prompt(i["mode"], args.pop("page_text"), **args)})
    return out


def _studip_context_cases(ai) -> list[dict]:
    """Kontextblock aus Stud.IP (ai.studip_context): Kursbeschreibung, Sonstiges, Sitzungsthemen, Kuerzungen"""
    inputs = [
        {"course_desc": "Grundlagen der Messtechnik:\n  Messfehler,\tSensoren.", "misc": "Anmeldung bis 01.11.",
         "sessions": [{"date": "2026-11-03", "topic": "Kapitel 3"}, {"date": "2026-11-05", "topic": "  "},
                      {"date": "2026-11-06T10:00:00", "topic": "Sensoren\nund Messketten"}, {"date": "", "topic": "ohne Datum"},
                      {"date": "2026-11-09", "topic": "zu viel"}]},
        {"course_desc": "ä€😀 Wort " * 80, "misc": None, "sessions": [{"date": "2026-11-03", "topic": "Thema " * 60}]},
        {"course_desc": "", "misc": "  ", "sessions": []},
        {"course_desc": None, "misc": "Hinweis " * 40, "sessions": [{"date": "2026-11-03", "topic": "T"}] * 3},
        {"course_desc": "x" * 299 + " yz", "misc": "y" * 200, "sessions": [{"date": "2026-11-0" + str(i), "topic": "z " * 150} for i in range(1, 4)]},
    ]
    return [{"in": i, "out": ai.studip_context(i["course_desc"], i["misc"], i["sessions"])} for i in inputs]


def _test_cases(ai) -> list[dict]:
    mats = [{"name": "vl05.pdf", "title": "Kapitel 5: Reihen", "doc_type": "vorlesung", "difficulty": 4, "text": "Reihen " * 800},
            {"name": "blatt5.pdf", "doc_type": "uebung", "text": "Aufgabe 1: Konvergenz"},
            {"name": "ohne-text.pdf", "text": None}]
    exam = {"name": "klausur-ws25.pdf", "title": "Testklausur WiSe 25/26", "text": "Aufgabe 1: Bestimmen Sie ... " * 200}
    cases = []
    options = [None, None, None,
               {"count": 5, "difficulty": "leicht", "types": ["tf", "cloze"], "topic": "  nur Kapitel 3 "},
               {"count": 20, "difficulty": "schwer", "types": ["calc"], "topic": "x" * 400},
               {"count": 10, "difficulty": "mittel", "types": ["mc", "short", "cloze"]},
               {"count": "15", "types": ["calc", "mc"], "topic": "Reihen ä€😀"}]
    pairs = [("Testmathe", 45, None), ("Testmathe", 90, exam), ("Testphysik", 30, {"name": "alt.pdf", "text": ""}),
             ("Testmathe", 30, exam), ("Testmathe", 60, exam), ("Testmathe", 45, exam), ("Testinfo", 45, None)]
    for (subject, minutes, ex), opts in zip(pairs, options):
        block, exam_block = ai.test_text_block(mats), ai.exam_text_block(ex)
        cases.append({"in": {"subject": subject, "duration_min": minutes, "materials": mats, "exam": ex, "options": opts},
                      "text_block": block, "exam_block": exam_block, "prompt": ai._test_prompt(subject, minutes, block, exam_block, opts)})
    return cases


def _options_cases(ai) -> dict:
    """ai.week_test_options (Pruefung und Vervollstaendigung, Fehlertexte), week_test_distribution, week_test_is_standard"""
    bodies = [None, {}, {"count": 15}, {"count": "10", "difficulty": "", "types": ["calc", "mc", "calc"], "topic": None},
              {"count": 5, "difficulty": "schwer", "types": ["tf"], "topic": " nur Kapitel 3 "},
              {"count": 20, "difficulty": "beliebig", "types": ["mc", "tf", "cloze", "short", "calc"], "topic": "x" * 400},
              {"count": 12}, {"count": "abc"}, {"count": True}, {"count": 15.0}, {"count": None},
              {"difficulty": "einfach"}, {"difficulty": 3}, {"types": "mc"}, {"types": ["essay"]}, {"types": []},
              {"types": [1]}, {"topic": 42}, {"types": None, "difficulty": None, "topic": "  "},
              {"module_id": 7, "duration_min": 30, "week_no": 3}]
    parsed = []
    for b in bodies:
        try:
            parsed.append({"in": b, "out": ai.week_test_options(b), "standard": ai.week_test_is_standard(b)})
        except ValueError as e:
            parsed.append({"in": b, "error": str(e)})
    dist = [{"count": c, "difficulty": d, "out": ai.week_test_distribution(c, d)} for c in ai.WEEK_TEST_COUNTS for d in ai.WEEK_TEST_LEVELS]
    return {"standard": ai.WEEK_TEST_STANDARD, "parse": parsed, "distribution": dist}


def _flashcards_cases(ai) -> list[dict]:
    """Karteikarten aus einem Dokument (ai.flashcards_prompt): Seitenangabe, Zahl, Schwerpunkt, Kuerzungen"""
    inputs = [
        {"course": "Testmathe I", "file_name": "vl02.pdf", "pages": [3, 4, 5], "text": "Definition: Eine Folge heisst konvergent ...", "count": 10, "topic": ""},
        {"course": "Testkurs", "file_name": "skript.pdf", "pages": [7], "text": "  Satz von Bolzano ä€😀  ", "count": 5, "topic": "  nur Beweise  "},
        {"course": "", "file_name": "", "pages": [], "text": "", "count": 1, "topic": "x" * 400},
        {"course": "K \"zitiert\"", "file_name": "a b.pdf", "pages": None, "text": "Lange Seite ä€😀 " * 1000, "count": 30, "topic": " \n "},
    ]
    return [{"in": i, "prompt": ai.flashcards_prompt(i["course"], i["file_name"], i["pages"], i["text"], i["count"], i["topic"])} for i in inputs]


def _flashcards_check_cases(ai) -> list[dict]:
    """ai.check_flashcards und ai.flashcards_count: Objekt mit cards, Liste, Leerraum, Unbrauchbares, Hoechstzahl"""
    many = {"cards": [{"question": f"F{i}", "answer": f"A{i}"} for i in range(40)]}
    answers = [
        {"cards": [{"question": " Was ist x? ", "answer": " 2 "}, {"question": "", "answer": "leer"}, {"question": "ohne Antwort"}, "Text", 7]},
        [{"question": "Liste", "answer": "geht auch"}, {"question": 3, "answer": 4.5}, {"question": None, "answer": "x"}],
        {"cards": "keine Liste"}, {"title": "ohne cards"}, [], "Text", None, many,
    ]
    counts = [None, "", 0, -3, 1, 7, "12", 30, 31, 999, 2.7, "abc", True]
    # Qualitaet (13.11.2026): Seitenangabe nur fuer Seiten des Inhalts, Doppel, fast gleiche Fragen, Frage verraet die
    # Antwort, zu lange Felder, Frage gleich Antwort, Unicode-Woerter (Umlaute, Griechisch, Hochzahlen, Indizes)
    quality = [
        ({"cards": [
            {"question": "Wie lautet die Bedingung des Abtasttheorems?", "answer": "f_A > 2 · f_max", "kind": "formel", "page": 4},
            {"question": "Wie lautet die Bedingung des Abtasttheorems?", "answer": "doppelt", "page": 4},
            {"question": "wie LAUTET die Bedingung des Abtasttheorems ?!", "answer": "Gross/klein und Zeichen egal", "page": 4},
            {"question": "Wie lautet die Bedingung des Abtasttheorems genau?", "answer": "fast gleich", "page": 4},
            {"question": "Welche Bedingung nennt das Abtasttheorem für die Abtastfrequenz?", "answer": "aehnlich, aber nicht gleich", "page": 4},
            {"question": "Wie heißt der Tiefpass vor der Abtastung (Anti-Aliasing-Filter)?", "answer": "Anti-Aliasing-Filter.", "page": 5},
            {"question": "Warum braucht man ein Anti-Aliasing-Filter vor der Abtastung?", "answer": "Es entfernt Frequenzen über f_A/2, die sonst als Alias erscheinen.", "page": 5},
            {"question": "Was ist ein Alias?", "answer": "Eine hohe Frequenz, die nach der Abtastung als tiefe erscheint.", "page": 9},
            {"question": "Was ist T?", "answer": "Das Abtastintervall", "page": True},
            {"question": "Was ist f_A?", "answer": "Die Abtastfrequenz 1/T", "page": 3.0},
            {"question": "Was ist x[n]?", "answer": "Der Abtastwert x(nT)", "page": "3"},
            {"question": "Ja", "answer": "ja"},
            {"question": "F" * (ai.FLASHCARDS_QUESTION_CHARS + 1), "answer": "zu lange Frage"},
            {"question": "Zu lange Antwort?", "answer": "A" * (ai.FLASHCARDS_ANSWER_CHARS + 1)},
            {"question": "F" * ai.FLASHCARDS_QUESTION_CHARS, "answer": "A" * ai.FLASHCARDS_ANSWER_CHARS, "page": 3},
            {"question": "Ergänze: Für |q| < 1 gilt Σ qᵏ = ___", "answer": "1/(1−q)", "kind": "lueckentext", "page": 13},
            {"question": "Was gilt für Σ qᵏ bei |q| ≥ 1?", "answer": "Die Reihe divergiert.", "page": 13},
            {"question": "Was liefert s == t für zwei mit new erzeugte Strings mit gleichem Inhalt?", "answer": "false", "page": 22},
            {"question": "Welche Ausgabe hat x² für x = 3?", "answer": "9", "page": 0},
            {"question": "ω ist was?", "answer": "ω", "page": 4},
            {"question": "Was ist x²?", "answer": "x mal x"}, {"question": "Was ist x2?", "answer": "eine Variable"},
            {"question": "Was ist X²?", "answer": "doppelt (gross/klein)"},
            {"question": "Welchen Wert hat die geometrische Reihe für q = 1/2?", "answer": "2"},
            {"question": "Welchen Wert hat die geometrische Reihe für q = 1/3?", "answer": "3/2"},
            {"question": "Vorlesung Frage 1 (Lauf 1)", "answer": "A"}, {"question": "Vorlesung Frage 2 (Lauf 1)", "answer": "B"},
            {"question": "Was beschreibt ω₀ beim Schwingkreis?", "answer": "Die Resonanzkreisfrequenz ω₀ = 1/√(L·C)."},
        ]}, [3, 4, 5, 13, 22]),
        ([{"question": "Liste ohne Seiten", "answer": "keine Angabe", "page": 2}], None),
        ({"cards": [{"question": "Was ist T?", "answer": "Intervall", "page": 2}]}, []),
    ]
    out = [{"in": a, "out": ai.check_flashcards(a)} for a in answers] + [{"count_in": c, "count": ai.flashcards_count(c)} for c in counts]
    return out + [{"in": a, "pages": pages, "out": ai.check_flashcards(a, pages)} for a, pages in quality]


def _flashcards_pages_text_cases(ai) -> list[dict]:
    """ai.flashcards_pages_text: Seitenueberschriften, Leerraum, leere Seiten"""
    cases = [([3, 4], ["  Abtastung \n", "Aliasing"]), ([1, 2, 3], ["", " \n ", "nur Seite 3"]), ([], []), ([7], ["ä€😀"])]
    return [{"pages": p, "texts": t, "out": ai.flashcards_pages_text(p, t)} for p, t in cases]


def _grade_cases(ai) -> list[dict]:
    qs = [{"nr": 1, "points": 6, "type": "mc", "question": "Welche Reihe konvergiert?", "answer": "B"},
          {"nr": "2", "points": 8, "type": "calc", "question": "Summe von 1/2^n", "answer": "2"}]
    return [{"in": {"subject": "Testmathe", "questions": qs, "answers": a}, "prompt": ai.grade_prompt("Testmathe", qs, a)}
            for a in ({"1": "B", "2": "2"}, {"1": ""}, {})]


def _parse_cases(ai) -> list[dict]:
    texts = ['{"a": 1}', '```json\n{"a": [1, 2]}\n```', "Hier ist das Ergebnis:\n{\"title\": \"T\", \"x\": {\"y\": 2}}\nViel Erfolg!",
             '[{"question": "Q", "answer": "A"}]', "  ```\n[1, 2]\n```  ", "kein JSON hier", "{\"a\": 1,}", '{"a": "ä\\u00fc"}',
             'Text {"a": 1} und {"b": 2} Ende']
    out = []
    for t in texts:
        try:
            out.append({"in": t, "out": ai.parse_json(t)})
        except ai.AIError as e:
            out.append({"in": t, "error": str(e).split(":")[0]})
    return out


def _check_cases(ai) -> list[dict]:
    def valid(count=15, difficulty="beliebig", type_="calc"):
        dist = ai.week_test_distribution(count, difficulty)
        diffs = [k for k in ai.WEEK_TEST_DIFFICULTY for _ in range(dist[k])]
        return {"title": "T", "questions": [{"nr": i + 1, "type": type_, "difficulty": d, "question": f"A{i}", "answer": "1",
                                             "explanation": f"Weil {i}.", "points": 6 if i < 10 else 8, "exam_style": False}
                                            for i, d in enumerate(diffs)]}
    cases = []

    def add(name, res, exam=False, options=None):
        cases.append({"name": name, "exam": exam, "options": options, "in": res, "reason": ai.check_week_test(res, exam=exam, options=options)})
    add("gueltig", valid())
    t = valid(); t["questions"][0].pop("explanation"); add("ohne Erklaerung", t)
    t = valid(); t["questions"][1]["explanation"] = "  "; add("leere Erklaerung", t)
    t = valid(); t["questions"][2].update(type="tf", options=["Wahr", "Falsch"], answer="Falsch"); add("tf gueltig", t)
    t = valid(); t["questions"][2].update(type="tf", options=[" Wahr", "Falsch "], answer=" Wahr "); add("tf mit Leerraum", t)
    t = valid(); t["questions"][2].update(type="tf", options=["Ja", "Nein"], answer="Ja"); add("tf falsche Optionen", t)
    t = valid(); t["questions"][2].update(type="tf", options=["Falsch", "Wahr"], answer="Wahr"); add("tf vertauscht", t)
    t = valid(); t["questions"][2].update(type="tf", answer="Wahr"); add("tf ohne Optionen", t)
    t = valid(); t["questions"][2].update(type="tf", options=["Wahr", "Falsch"], answer="B"); add("tf Loesung daneben", t)
    t = valid(); t["questions"][3].update(type="cloze", blank="Konvergenz", question="Eine Folge heisst ___, wenn ..."); add("cloze gueltig", t)
    t = valid(); t["questions"][3].update(type="cloze", question="Eine Folge heisst ___"); add("cloze ohne Luecke", t)
    t = valid(); t["questions"][3].update(type="cloze", blank=""); add("cloze leere Luecke", t)
    t = valid(); t["questions"][3].update(type="cloze", blank=7); add("cloze Luecke als Zahl", t)
    add("5 leicht tf", valid(5, "leicht", "tf") | {}, options={"count": 5, "difficulty": "leicht", "types": ["tf"]})
    t = valid(5, "leicht", "tf")
    for q in t["questions"]:
        q.update(options=["Wahr", "Falsch"], answer="Wahr")
    add("5 leicht tf gueltig", t, options={"count": 5, "difficulty": "leicht", "types": ["tf"]})
    t = valid(5, "leicht", "tf")
    for q in t["questions"]:
        q.update(options=["Wahr", "Falsch"], answer="Wahr")
    t["questions"][4]["exam_style"] = True
    add("5 leicht mit Klausuraufgabe", t, exam=True, options={"count": 5, "difficulty": "leicht", "types": ["tf"]})
    t = valid(5, "leicht", "tf")
    for q in t["questions"]:
        q.update(options=["Wahr", "Falsch"], answer="Wahr")
    add("5 leicht, Klausur ohne schwere Aufgabe", t, exam=True, options={"count": 5, "difficulty": "leicht", "types": ["tf"]})
    add("10 beliebig calc", valid(10), options={"count": 10, "types": ["calc", "short"]})
    add("10 statt 15", valid(10), options={"count": 15})
    add("15 statt 10", valid(15), options={"count": 10})
    t = valid(10); t["questions"][0]["difficulty"] = "schwer"; add("10 Verteilung", t, options={"count": 10})
    add("nicht gewaehlte Art", valid(10), options={"count": 10, "types": ["mc", "tf"]})
    t = valid(20, "schwer"); t["questions"][19]["exam_style"] = True; add("20 schwer mit Klausur", t, exam=True, options={"count": 20, "difficulty": "schwer"})
    t = valid(20, "schwer"); t["questions"][0]["difficulty"] = "mittel"; add("20 schwer Verteilung", t, options={"count": 20, "difficulty": "schwer"})
    t = valid(); t["questions"].pop(); add("14 Aufgaben", t)
    t = valid(); t["questions"].append(dict(t["questions"][0])); add("16 Aufgaben", t)
    t = valid(); t["questions"][0]["difficulty"] = "mittel"; add("Verteilung", t)
    t = valid(); t["questions"][3]["difficulty"] = "einfach"; add("unbekannte Schwierigkeit", t)
    t = valid(); t["questions"][4]["type"] = "essay"; add("unbekannter Typ", t)
    t = valid(); t["questions"][2].update(type="mc", options=["A"]); add("mc ohne Optionen", t)
    t = valid(); t["questions"][2].update(type="mc", options=["A", "B"]); add("mc mit Optionen", t)
    t = valid(); t["questions"][5]["answer"] = " "; add("leere Loesung", t)
    t = valid(); t["questions"][6]["question"] = None; add("ohne Text", t)
    t = valid(); t["questions"][7]["points"] = True; add("Punkte bool", t)
    t = valid(); t["questions"][7]["points"] = 0; add("Punkte 0", t)
    t = valid(); t["questions"][7]["points"] = 2.5; add("Punkte Kommazahl", t)
    t = valid(); t["questions"][8] = "Text"; add("kein Objekt", t)
    add("Liste statt Objekt", [])
    add("ohne questions", {"title": "T"})
    t = valid(); add("Klausur verlangt, fehlt", t, exam=True)
    t = valid(); t["questions"][14]["exam_style"] = True; add("Klausuraufgabe schwer", t, exam=True)
    t = valid(); t["questions"][14]["exam_style"] = True; add("Klausuraufgabe ohne Klausur", t)
    t = valid(); t["questions"][0]["exam_style"] = True; add("Klausuraufgabe leicht", t, exam=True)
    t = valid(); t["questions"][13]["exam_style"] = t["questions"][14]["exam_style"] = True; add("zwei Klausuraufgaben", t, exam=True)
    t = valid(); t["questions"][14]["exam_style"] = "ja"; add("exam_style kein bool", t, exam=True)
    return cases


def _chatgpt(cl, backend) -> dict:
    auth = [
        {"client_id": None, "host": "urn:uuid:00000000-0000-4000-8000-000000000001", "redirect_uri": "http://127.0.0.1:53682/auth/callback",
         "state": "st-1", "nonce": "no-1", "challenge": "ch-1", "login_hint": None, "reconsent": False},
        {"client_id": "oaiapp_testclient", "host": "urn:uuid:00000000-0000-4000-8000-000000000002", "redirect_uri": "http://127.0.0.1:1/auth/callback",
         "state": "s t/+&=ä", "nonce": "n", "challenge": "c", "login_hint": "ich+x@beispiel.de", "reconsent": False},
        {"client_id": "oaiapp_testclient", "host": "h", "redirect_uri": "r", "state": "s", "nonce": "n", "challenge": "c", "login_hint": None, "reconsent": True},
        {"client_id": "oaiapp_testclient", "host": "h", "redirect_uri": "r", "state": "s", "nonce": "n", "challenge": "c", "login_hint": "a@b", "reconsent": True},
        {"client_id": None, "host": "h", "redirect_uri": "r", "state": "s", "nonce": "n", "challenge": "c", "login_hint": "ignoriert", "reconsent": True},
    ]
    for a in auth:
        a["url"] = cl.build_auth_url(a["client_id"], a["host"], a["redirect_uri"], a["state"], a["nonce"], a["challenge"],
                                     login_hint=a["login_hint"], reconsent=a["reconsent"])
    import base64
    import hashlib
    pkce = [{"verifier": v, "challenge": base64.urlsafe_b64encode(hashlib.sha256(v.encode("ascii")).digest()).decode("ascii").rstrip("=")}
            for v in ("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", "a" * 96)]
    creds = []
    for resp, prev in [
        ({"access_token": "at-1", "refresh_token": "rt-1", "id_token": "id-1", "expires_in": 3600, "scope": "openid chatgpt.tokens.use.direct", "token_type": "Bearer"}, None),
        ({"access_token": "at-2", "expires_in": "120"}, {"refresh_token": "rt-1", "id_token": "id-1", "scopes": ["openid", "chatgpt.tokens.use.direct"]}),
        ({"access_token": "at-3", "expires_in": "kaputt", "scope": "  openid   profile "}, None),
        ({"access_token": "", "expires_in": 10}, None),
        ({"refresh_token": "rt"}, None),
        ({"access_token": "at-5", "expires_in": 600, "earliest_refresh_at": 1900000000}, None),
        ({"access_token": "at-6", "expires_in": 600, "earliest_refresh_at": "2030-01-01T00:00:00Z"}, None),
        ({"access_token": "at-7", "expires_in": 600, "earliest_refresh_at": "2030-01-01T02:00:00+02:00"}, None),
        ({"access_token": "at-8", "expires_in": 600, "earliest_refresh_at": "2030-01-01T00:00:00"}, None),
        ({"access_token": "at-9", "expires_in": 600, "earliest_refresh_at": "irgendwann"}, None),
        ({"access_token": "at-10", "expires_in": 600, "earliest_refresh_at": True}, None),
    ]:
        try:
            c = cl._credentials_from(resp, prev)
            c.pop("saved_at")
            c["expires_in_used"] = round(c.pop("expires_at") - __import__("time").time())
            creds.append({"response": resp, "previous": prev, "credentials": c})
        except cl.ChatGPTError as e:
            creds.append({"response": resp, "previous": prev, "error": e.code})
    responses = [
        {"model": "gpt-test", "system": "SYS", "prompt": "Frage", "schema": None},
        {"model": "gpt-test", "system": "", "prompt": "Plan", "schema": {"type": "object", "properties": {"notes": {"type": "string"}}}},
    ]
    for r in responses:
        r["body"] = backend.ChatGPTProvider.request_body(r["model"], r["system"], r["prompt"], r["schema"])
    # Kopfzeilen: ein (ungueltiges, unsigniertes) JWT mit und ohne Kontokennung, ein Token ohne JWT-Form
    def jwt(claims: dict) -> str:
        enc = lambda d: base64.urlsafe_b64encode(json.dumps(d).encode()).decode().rstrip("=")  # noqa: E731
        return f"{enc({'alg': 'none'})}.{enc(claims)}.sig"
    headers = [{"token": t, "headers": backend.ChatGPTProvider.request_headers(t)} for t in (
        "at-ohne-jwt",
        jwt({"sub": "s", "https://api.openai.com/auth": {"chatgpt_account_id": "acct_test_1234", "chatgpt_plan_type": "plus"}}),
        jwt({"sub": "s", "https://api.openai.com/auth": {"per_user_salt": "x", "encrypted_auth_metadata": "y"}}),
        jwt({"sub": "s", "https://api.openai.com/auth": {"chatgpt_account_id": "   "}}),
    )]
    # Ereignisstrom der Responses API (stream: true): Text erst mit response.completed, Fehler nach Code
    def ev(t: str, **fields) -> str:
        return f"event: {t}\ndata: {json.dumps({'type': t, **fields})}\n\n"
    done = {"id": "resp_1", "model": "gpt-6.1-sol", "output": [{"type": "message", "content": [{"type": "output_text", "text": "Hallo Welt"}]}],
            "usage": {"input_tokens": 12, "output_tokens": 3}}
    streams = [
        {"raw": ev("response.created", response={"id": "resp_1"}) + ev("response.output_text.delta", delta="Hallo ")
                + ev("response.output_text.delta", delta="Welt") + ev("response.completed", response=done) + "data: [DONE]\n\n"},
        {"raw": ev("response.output_text.delta", delta="nur ") + ev("response.output_text.delta", delta="Deltas")
                + ev("response.completed", response={"model": "gpt-x", "output": []})},
        {"raw": "data: {\"type\": \"response.output_text.delta\",\r\ndata: \"delta\": \"CR\"}\r\n\r\n"
                "data: {\"type\": \"response.completed\", \"response\": {\"output\": []}}\r\n\r\n"},
        {"raw": ev("response.output_text.delta", delta="x")
                + ev("response.failed", response={"error": {"code": "subscription_sharing_usage_limit_exceeded", "message": "limit"}})},
        {"raw": ev("response.failed", response={"error": {"code": "subscription_sharing_user_not_eligible", "message": "nein"}})},
        {"raw": ev("response.failed", response={"error": {"code": "subscription_sharing_usage_unavailable", "message": "spaeter"}})},
        {"raw": ev("response.failed", response={"error": {"code": "subscription_sharing_invalid_user", "message": "wer"}})},
        {"raw": ev("response.failed", response={"error": {"code": "server_error", "message": "kaputt"}})},
        {"raw": ev("error", code="rate_limit_exceeded", message="zu schnell")},
        {"raw": ev("response.incomplete", response={"incomplete_details": {"reason": "max_output_tokens"}})},
        {"raw": ev("response.output_text.delta", delta="abgebrochen")},
        {"raw": ""},
        {"raw": json.dumps({"output": [{"type": "message", "content": [{"type": "output_text", "text": "ohne Strom"}]}], "model": "gpt-y"})},
        {"raw": json.dumps({"error": {"code": "model_not_found", "message": "kein Modell"}})},
    ]
    for s_ in streams:
        try:
            text, data = backend.stream_text(s_["raw"])
            s_["text"], s_["model"] = text, data.get("model") or ""
        except backend.AIUnavailable as e:
            s_["error"] = {"code": e.code, "message": e.message}
    # Modellliste: Katalog des Abos (Reihenfolge des Servers, nur sichtbare) oder oeffentliche Liste (alphabetisch)
    model_lists = []
    for resp in [
        {"models": [{"slug": "gpt-6-luna", "display_name": "GPT-6-Luna", "visibility": "list", "priority": 4},
                    {"slug": "gpt-daybreak-red-latest", "visibility": "hide", "priority": 12},
                    {"slug": "gpt-6.1-sol", "display_name": "GPT-6.1-Sol", "visibility": "list", "priority": 1},
                    {"slug": "gpt-6-luna", "visibility": "list"}, {"slug": "  ", "visibility": "list"}, {"id": "ohne-slug"}, "kaputt"]},
        {"models": []},
        {"data": [{"id": "gpt-b"}, {"slug": "gpt-a"}, {"id": "gpt-b"}, {"x": 1}]},
        {},
    ]:
        model_lists.append({"response": resp, "ids": cl.model_ids(resp), "catalog": cl.is_model_catalog(resp)})
    error_texts = [{"body": b, "text": cl._error_text(b)} for b in (
        '{"detail":"The \'gpt-5.5-codex\' model is not supported when using Codex with a ChatGPT account.","error":{"type":"invalid_request_error","code":"model_not_found"}}',
        '{"error":{"message":"Nachricht","code":"c"}}', '{"error":{"code":"nur_code"}}', '{"error_description":"Beschreibung"}',
        '{"detail":"nur detail"}', "kein json", "")]
    outputs = [
        {"response": {"model": "gpt-x", "output": [{"type": "reasoning", "summary": []},
                                                   {"type": "message", "content": [{"type": "output_text", "text": "Hallo "}, {"type": "refusal", "refusal": "nein"},
                                                                                   {"type": "output_text", "text": "Welt"}]},
                                                   {"type": "message", "content": [{"type": "output_text", "text": "!"}]}],
                      "usage": {"input_tokens": 12, "output_tokens": 3}}},
        {"response": {"output": [], "usage": {}}},
        {"response": {}},
    ]
    for o in outputs:
        d = o["response"]
        o["text"] = "".join(c.get("text", "") for item in d.get("output") or [] if item.get("type") == "message"
                            for c in item.get("content") or [] if c.get("type") == "output_text")
    errors = [
        {"status": 401, "code": "chatgpt_login_needed", "message": "Die Anmeldung bei ChatGPT ist abgelaufen – bitte in den Einstellungen neu verbinden."},
        {"status": 402, "code": "chatgpt_limit", "message": "Dein ChatGPT-Kontingent ist aufgebraucht oder die Nutzung in Apps ist nicht freigegeben. In ChatGPT unter Einstellungen → Nutzung verwalten."},
        {"status": 403, "code": "chatgpt_limit"}, {"status": 429, "code": "chatgpt_limit"},
        {"status": 500, "code": "ai_provider_error"}, {"status": 0, "code": "ai_provider_unreachable", "message": "ChatGPT ist nicht erreichbar."},
    ]
    # Texte aus ai_backend, damit sie nicht auseinanderlaufen
    import inspect
    src = inspect.getsource(backend.ChatGPTProvider.complete)
    for e in errors:
        if "message" in e and e["message"].split(" – ")[0].split(".")[0][:30] not in src:
            raise RuntimeError(f"Fehlertext nicht mehr in ai_backend: {e['message']}")
    return {
        "auth_url": cl.AUTH_URL, "token_url": cl.TOKEN_URL, "issuer": cl.ISSUER, "jwks_url": cl.JWKS_URL, "resource": cl.RESOURCE,
        "responses_url": cl.RESPONSES_URL, "models_url": cl.MODELS_URL, "usage_help_url": cl.USAGE_HELP_URL, "scope": cl.SCOPE,
        "usage_scope": cl.USAGE_SCOPE, "first_client_id": cl.FIRST_CLIENT_ID, "agent_name": cl.AGENT_NAME,
        "callback_path": cl.CALLBACK_PATH, "flow_timeout_s": cl.FLOW_TIMEOUT_S, "refresh_margin_s": cl.REFRESH_MARGIN_S,
        "token_request": {"code": ["grant_type=authorization_code", "client_id", "code", "code_verifier", "redirect_uri", "resource"],
                          "refresh": ["grant_type=refresh_token", "refresh_token", "client_id", "resource"],
                          "content_type": "application/x-www-form-urlencoded"},
        "id_token": {"algorithms": ["RS256", "ES256"], "checks": ["kid in JWKS (bei unbekanntem kid einmal neu laden)", "iss == issuer",
                                                                  "client_id in aud", "exp + 60 s >= jetzt", "nonce"]},
        "authorize": auth, "pkce": pkce, "credentials": creds, "responses_request": responses, "responses_output": outputs,
        "request_headers": headers, "responses_stream": streams, "model_lists": model_lists, "error_texts": error_texts,
        "errors": errors,
    }


def main() -> int:
    check = "--check" in sys.argv[1:]
    tmp = tempfile.mkdtemp(prefix="studora-ai-contract-")
    os.environ["LERNAPP_DATA_DIR"] = str(Path(tmp) / "data")
    os.environ["LERNAPP_LOG_DIR"] = str(Path(tmp) / "logs")
    sys.path.insert(0, str(ROOT))
    from app import ai, ai_backend, chatgpt_login
    out = {
        "_hinweis": "Erzeugt mit tools/gen-ai-contract.py aus app/ai.py und app/chatgpt_login.py; nicht von Hand aendern.",
        "texts": {"system": ai.SYSTEM, "tutor_system": ai.TUTOR_SYSTEM, "tutor_modes": ai.TUTOR_MODES,
                  "analysis_fields": ai.ANALYSIS_FIELDS, "week_test_difficulty": ai.WEEK_TEST_DIFFICULTY,
                  "week_test_total": ai.WEEK_TEST_TOTAL, "week_test_types": list(ai.WEEK_TEST_TYPES),
                  "week_test_counts": list(ai.WEEK_TEST_COUNTS), "week_test_levels": list(ai.WEEK_TEST_LEVELS),
                  "week_test_topic_chars": ai.WEEK_TEST_TOPIC_CHARS, "week_test_type_names": ai.WEEK_TEST_TYPE_NAMES,
                  "tf_options": list(ai.TF_OPTIONS),
                  "tutor_history_turns": ai.TUTOR_HISTORY_TURNS, "tutor_history_chars": ai.TUTOR_HISTORY_CHARS,
                  "untrusted": ai.UNTRUSTED,
                  "flashcards_default": ai.FLASHCARDS_DEFAULT, "flashcards_max": ai.FLASHCARDS_MAX,
                  "flashcards_text_chars": ai.FLASHCARDS_TEXT_CHARS, "flashcards_schema": ai.FLASHCARDS_SCHEMA},
        "prompts": {"tutor": _tutor_cases(ai), "studip_context": _studip_context_cases(ai),
                    "analysis": [{"in": {"course": c, "file_name": f, "text": t}, "prompt": ai.analysis_prompt(c, f, t)}
                                 for c, f, t in [("Testmathe I", "vl01.pdf", "Folgen und Reihen"), ("Testkurs", "leer.pdf", "  \n"),
                                                 ("K \"zitiert\"", "a b.pdf", "x" * 50)]],
                    "week_test": _test_cases(ai), "grade": _grade_cases(ai), "flashcards": _flashcards_cases(ai)},
        "parse_json": _parse_cases(ai),
        "check_week_test": _check_cases(ai),
        "week_test_options": _options_cases(ai),
        "check_flashcards": _flashcards_check_cases(ai),
        "flashcards_pages_text": _flashcards_pages_text_cases(ai),
        "chatgpt": _chatgpt(chatgpt_login, ai_backend),
    }
    text = json.dumps(out, ensure_ascii=False, indent=1) + "\n"
    current = OUT.read_text(encoding="utf-8") if OUT.exists() else None
    if current == text:
        print(f"aktuell: {OUT.relative_to(ROOT)}")
        return 0
    if check:
        print(f"VERALTET: {OUT.relative_to(ROOT)}", file=sys.stderr)
        return 1
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text, encoding="utf-8")
    print(f"geschrieben: {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

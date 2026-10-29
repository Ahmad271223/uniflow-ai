"""Erzeugt packages/shared-contracts/ai/contract.json: die KI von Studora so, wie app/ai.py und app/chatgpt_login.py
sie am PC bauen, als gemeinsamer Vertrag fuer die Geraete-Kerne (Swift: AIContractTests). Wer KI-Anfragen selbst
stellt (iPad mit dem ChatGPT-Abo des Nutzers), baut daraus byte-gleiche Prompts und prueft Antworten gleich.

Inhalt:
- texts: System-Prompts, Modi des Tutors, Analysefelder, Regel des Wochentests (29.10.2026)
- prompts: je Funktion Eingaben -> Prompt (Tutor mit Quellen und Kuerzungen, Analyse aus Text, Wochenplan,
  Wochentest mit und ohne Altklausur samt Materialblock, Bewertung)
- parse_json: Antworttext -> JSON oder Fehler
- check_week_test: Antwort -> Grund (null = in Ordnung)
- chatgpt: Adressen, Scopes, Autorisierungsadressen, PKCE, Zugangsdaten aus Token-Antworten, Anfrage an die
  Responses API, Text aus der Antwort, Fehlercodes
Alles erfunden; nichts geht ins Netz. Aufruf im Projektordner: python tools/gen-ai-contract.py [--check]
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
from datetime import date
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
        {"mode": "check", "page_text": "Aufgabe 1", "own_solution": "x = 2 " * 1200, "question": "Stimmt das? " * 200,
         "course": "Testphysik", "file_name": "blatt1.pdf"},
        {"mode": "unbekannt", "page_text": "", "course": "", "file_name": ""},
        {"mode": "summary", "page_text": long, "selection": "  \n ", "course": "Testkurs", "file_name": "s.pdf", "page": 1,
         "sources": src},
        {"mode": "flashcards", "page_text": "Begriffe", "course": "Testkurs", "file_name": "k.pdf", "page": 2, "sources": src},
        {"mode": "hints", "page_text": "  Aufgabe 2  ", "selection": "  markiert  ", "course": "K", "file_name": "f.pdf",
         "page": 0, "sources": []},
    ]
    out = []
    for i in inputs:
        args = {k: v for k, v in i.items() if k != "mode"}
        out.append({"in": i, "prompt": ai.tutor_prompt(i["mode"], args.pop("page_text"), **args)})
    return out


def _plan_cases(ai) -> list[dict]:
    mats = [{"id": "f1", "subject": "Testmathe", "course_title": "Testmathematik für Ingenieure I – Vorlesung und Übung",
             "doc_type": "vorlesung", "difficulty": 4, "est_minutes": 90, "title": "Kapitel 1: Folgen", "name": "vl01.pdf"},
            {"id": "f2", "subject": "Testphysik", "course_title": "Testphysik", "name": "blatt1.pdf"}]
    subjects = [{"subject": "Testmathe", "test_minutes": 45}, {"subject": "Testphysik", "test_minutes": 60}]
    settings = {"free_days": [5, 6], "hours_per_day": 3.5, "day_start": "09:00"}
    carry = [{"title": "Blatt 2 nachholen", "subject": "Testmathe"}, {"title": "Ohne Fach"}]
    cases = []
    for ws, today, m, c, st in [
        ("2026-10-26", "2026-10-28", mats, carry, settings),                                    # heute in der Woche
        ("2026-11-02", "2026-10-28", mats, [], settings),                                       # kommende Woche
        ("2026-10-19", "2026-10-28", [], [], {"free_days": [], "hours_per_day": 2, "day_start": "08:30"}),  # vergangen, leer
    ]:
        args = {"week_start": ws, "materials": m, "subjects": subjects, "settings": st, "carry_over": c, "today": today}
        cases.append({"in": args, "prompt": ai.week_plan_prompt(date.fromisoformat(ws), m, subjects, st, c, date.fromisoformat(today))})
    return cases


def _test_cases(ai) -> list[dict]:
    mats = [{"name": "vl05.pdf", "title": "Kapitel 5: Reihen", "doc_type": "vorlesung", "difficulty": 4, "text": "Reihen " * 800},
            {"name": "blatt5.pdf", "doc_type": "uebung", "text": "Aufgabe 1: Konvergenz"},
            {"name": "ohne-text.pdf", "text": None}]
    exam = {"name": "klausur-ws25.pdf", "title": "Testklausur WiSe 25/26", "text": "Aufgabe 1: Bestimmen Sie ... " * 200}
    cases = []
    for subject, minutes, ex in [("Testmathe", 45, None), ("Testmathe", 90, exam), ("Testphysik", 30, {"name": "alt.pdf", "text": ""})]:
        block, exam_block = ai.test_text_block(mats), ai.exam_text_block(ex)
        cases.append({"in": {"subject": subject, "duration_min": minutes, "materials": mats, "exam": ex},
                      "text_block": block, "exam_block": exam_block, "prompt": ai._test_prompt(subject, minutes, block, exam_block)})
    return cases


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
    def valid():
        diffs = ["leicht"] * 4 + ["mittel"] * 6 + ["schwer"] * 5
        return {"title": "T", "questions": [{"nr": i + 1, "type": "calc", "difficulty": d, "question": f"A{i}", "answer": "1",
                                             "points": 6 if i < 10 else 8, "exam_style": False} for i, d in enumerate(diffs)]}
    cases = []

    def add(name, res, exam=False):
        cases.append({"name": name, "exam": exam, "in": res, "reason": ai.check_week_test(res, exam=exam)})
    add("gueltig", valid())
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
         "state": "st-1", "nonce": "no-1", "challenge": "ch-1", "id_token_hint": None},
        {"client_id": "oaiapp_testclient", "host": "urn:uuid:00000000-0000-4000-8000-000000000002", "redirect_uri": "http://127.0.0.1:1/auth/callback",
         "state": "s t/+&=ä", "nonce": "n", "challenge": "c", "id_token_hint": "eyJ.hint.x"},
        {"client_id": None, "host": "h", "redirect_uri": "r", "state": "s", "nonce": "n", "challenge": "c", "id_token_hint": "ignoriert"},
    ]
    for a in auth:
        a["url"] = cl.build_auth_url(a["client_id"], a["host"], a["redirect_uri"], a["state"], a["nonce"], a["challenge"], a["id_token_hint"])
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
        body = {"model": r["model"], "instructions": r["system"], "input": r["prompt"]}
        if r["schema"]:
            body["text"] = {"format": {"type": "json_schema", "name": "studora", "schema": r["schema"], "strict": False}}
        r["body"] = body
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
                  "week_test_total": ai.WEEK_TEST_TOTAL, "week_test_types": list(ai.WEEK_TEST_TYPES)},
        "prompts": {"tutor": _tutor_cases(ai),
                    "analysis": [{"in": {"course": c, "file_name": f, "text": t}, "prompt": ai.analysis_prompt(c, f, t)}
                                 for c, f, t in [("Testmathe I", "vl01.pdf", "Folgen und Reihen"), ("Testkurs", "leer.pdf", "  \n"),
                                                 ("K \"zitiert\"", "a b.pdf", "x" * 50)]],
                    "week_plan": _plan_cases(ai), "week_test": _test_cases(ai), "grade": _grade_cases(ai)},
        "parse_json": _parse_cases(ai),
        "check_week_test": _check_cases(ai),
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

"""StudiNow-Wissensbank (app/wissensbank.py, Auftrag des Inhabers 20.11.2026): Zuordnung ueber den Wortlaut, 1 Credit,
Wiederholung -> KI + Ja/Nein, Kandidaten, Freigabe, nur Pro AI an der LUH.

Die Bibliothek hier ist ein kleines, ERFUNDENES Beispiel (tests/fixtures/wissensbank: 2 Faecher, 3 Einheiten). Echte
Inhalte der privaten Wissensbibliothek gehoeren nie in dieses Repository."""
import json
import re
import unicodedata
import uuid
from pathlib import Path

import pytest
from conftest import asgi_call
from test_credits import cheap_calls
from test_subscriptions import FakeAI, _j, hosted, user  # noqa: F401 (Fixtures)

FIXTURE = Path(__file__).parent / "fixtures" / "wissensbank"
STATIK = "Beispiel-Statik-für-Testzwecke"
ALGO = "Beispiel-Algorithmen"
FOLIEN = "bsp-statik-folien-2026.pdf"
BLATT = "Übungsblatt 03 - Balken.pdf"


def _quote(path: str, heading: str) -> str:
    """Folientext (`>`-Zeilen) bzw. Aufgabentext eines Abschnitts im Fixture - so, wie er auf der PDF-Seite steht."""
    text = (FIXTURE / path).read_text(encoding="utf-8")
    part = text.split("## " + heading, 1)[1].split("\n## ", 1)[0]
    quotes = [ln[1:].strip() for ln in part.split("\n") if ln.startswith(">")]
    if quotes:
        return "\n".join(quotes)
    m = re.search(r"\*\*Aufgabentext\.\*\* (.*?)\n\n", part, re.S)
    return m.group(1)


G1 = f"Bibliothek/{STATIK}/Einheiten/WiSe_2026_27/Vorlesungsfolien/G0001/01-erklaert.md"
G2 = f"Bibliothek/{STATIK}/Einheiten/WiSe_2026_27/Gruppenuebung/G0002/02-geloest.md"
A1 = f"Bibliothek/{ALGO}/Einheiten/_aeltere-PC-Version/direkt/G0001/01-erklaert.md"
S2 = _quote(G1, "[Q1] Seite 2")
S3 = _quote(G1, "[Q1] Seite 3")
A1A = _quote(G2, "[Q1] Aufgabe 1 a)")
A1B = _quote(G2, "[Q1] Aufgabe 1 b)")
A2 = _quote(G2, "[Q1] Aufgabe 2")
ALGO2 = _quote(A1, "[Q1] Seite 2")
ALGO3 = _quote(A1, "[Q1] Seite 3")

K_S2 = f"explain:{STATIK}/G0001/01#Q1-Seite-2"
K_S3 = f"explain:{STATIK}/G0001/01#Q1-Seite-3"
K_1AB = f"steps:{STATIK}/G0002/02#Q1-Aufgabe-1-a+02#Q1-Aufgabe-1-b"
K_1A = f"steps:{STATIK}/G0002/02#Q1-Aufgabe-1-a"
K_2 = f"steps:{STATIK}/G0002/02#Q1-Aufgabe-2"
K_ALGO2 = f"explain:{ALGO}/G0001/01#Q1-Seite-2"
K_ALGO3 = f"explain:{ALGO}/G0001/01#Q1-Seite-3"


def rewrap(text: str, width: int = 47, hyphen: bool = True) -> str:
    """Anderer Zeilenumbruch, Silbentrennung am Zeilenende (wie die Textebene eines PDFs)."""
    words, lines, cur = " ".join(text.split()).split(" "), [], ""
    for w in words:
        if len(cur) + len(w) + 1 > width and cur:
            if hyphen and len(w) > 8 and w.isalpha():
                cut = len(w) // 2
                lines.append(cur + " " + w[:cut] + "-")
                cur = w[cut:]
                continue
            lines.append(cur)
            cur = w
        else:
            cur = (cur + " " + w).strip()
    return "\n".join(lines + [cur])


# Faelle: (Name, Modus, Datei, Kurs, Seite, Text, erwarteter Schluessel oder None)
CASES = [
    ("Folie genau", "explain", FOLIEN, "", 2, S2, K_S2),
    ("Folie verschoben (neue Seite davor)", "explain", FOLIEN, "", 3, "Beispiel-Statik · Folie 3 von 40\n" + S2, K_S2),
    ("Folie, anderer Umbruch + Silbentrennung", "explain", FOLIEN, "", 2, rewrap(S2) + "\n– 2 –", K_S2),
    ("Folie, Verweis 'identisch mit' (Seite 4)", "explain", FOLIEN, "", 4, S2, K_S2),
    ("Schnittprinzip", "explain", FOLIEN, "", 3, rewrap(S3, 60), K_S3),
    ("Datei umbenannt, Kurs passt", "explain", "Statik_Folien_neu_v2.pdf", "Beispiel-Statik für Testzwecke (WiSe 2026/27)", 2, S2, K_S2),
    ("Datei umbenannt, ohne Kurs", "explain", "Statik_Folien_neu_v2.pdf", "", 2, S2, None),
    ("Datei umbenannt, fremder Kurs", "explain", "Statik_Folien_neu_v2.pdf", "Einführung in die Chemie", 2, S2, None),
    ("voellig anderer Text", "explain", FOLIEN, "", 2,
     "Die Photosynthese wandelt Lichtenergie in chemische Energie um. Dabei entstehen aus Kohlendioxid und Wasser "
     "Traubenzucker und Sauerstoff; der Vorgang findet in den Chloroplasten der Pflanzenzellen statt.", None),
    ("Aufgabenblatt Seite mit 1 a) und 1 b)", "steps", BLATT, "", 1, "Gruppenübung 3\n" + A1A + "\n" + A1B, K_1AB),
    ("nur Aufgabe 1 a) markiert", "steps", BLATT, "", 1, rewrap(A1A, 70, hyphen=False), K_1A),
    ("Aufgabe 1 a) mit anderen Zahlen", "steps", BLATT, "", 1, A1A.replace("l = 4 m", "l = 5 m").replace("F = 12 kN", "F = 15 kN"), None),
    ("Aufgabe 1 a) mit einer anderen Zahl", "steps", BLATT, "", 1, A1A.replace("F = 12 kN", "F = 10 kN"), None),
    ("Aufgabe 1 b) Zahl gegen eine vorhandene getauscht", "steps", BLATT, "", 1, A1B.replace("F = 12 kN", "F = 4 kN"), None),
    ("Aufgabe 1 a) Dezimalkomma statt Zahl", "steps", BLATT, "", 1, A1A.replace("l = 4 m", "l = 4,5 m"), None),
    ("Aufgabe 2 (KI-Loesung)", "steps", BLATT, "", 2, A2, K_2),
    ("Dateiname NFD und Leerraum", "steps", unicodedata.normalize("NFD", "Übungsblatt  03 -  Balken"), "", 2, A2, K_2),
    ("Folie im Modus Loesen", "steps", FOLIEN, "", 2, S2, None),
    ("Animationsstufe: Grundfolie", "explain", "algo-skript-bsp.pdf", "", 2, ALGO2, K_ALGO2),
    ("Animationsstufe: mit Beispiel", "explain", "algo-skript-bsp.pdf", "", 2, ALGO3, K_ALGO3),
    ("Animationsstufe: anderes Zahlenbeispiel", "explain", "algo-skript-bsp.pdf", "", 3,
     ALGO3.replace("5, 2, 4, 6, 1, 3", "9, 7, 8, 0, 1, 2").replace("1, 2, 3, 4, 5, 6", "0, 1, 2, 7, 8, 9"), K_ALGO2),
    ("zu kurzer Text", "explain", FOLIEN, "", 1, "Beispiel-Statik für Testzwecke", None),
]


@pytest.fixture
def lib(monkeypatch):
    from app import wissensbank
    return wissensbank.Library(FIXTURE)


def run_case(lib, case):
    from app import wissensbank
    _name, mode, datei, kurs, seite, text, _want = case
    hit = wissensbank.match(lib, mode=mode, datei=datei, kurs=kurs, seite=seite, text=text)
    return hit.key if hit else None


@pytest.mark.parametrize("case", CASES, ids=[c[0] for c in CASES])
def test_matching_by_wording(lib, case):
    assert run_case(lib, case) == case[-1]


def test_matching_quality_on_the_invented_fixture(lib):
    """Trefferqualitaet mit der festen Schwelle: alle Faelle richtig, kein falscher Treffer."""
    from app import wissensbank
    right = sum(run_case(lib, c) == c[-1] for c in CASES)
    false_hits = sum(1 for c in CASES if c[-1] is None and run_case(lib, c) is not None)
    wrong_key = sum(1 for c in CASES if c[-1] is not None and run_case(lib, c) not in (None, c[-1]))
    assert (right, false_hits, wrong_key) == (len(CASES), 0, 0)
    assert (wissensbank.SCHWELLE, wissensbank.SCHWELLE_OHNE_VORLAGE, wissensbank.KURS_ZUSCHLAG) == (0.6, 0.75, 0.1)


def test_normalize_keeps_digits_and_formula_signs_and_joins_hyphenation():
    from app import wissensbank
    assert wissensbank.tokens("Bezugs-\npunkt σ₁ = 0,8 T") == ["bezugspunkt", "σ", "1", "=", "0.8", "t"]
    assert wissensbank.norm_title("Übungsblatt 03 - Balken.pdf") == wissensbank.norm_title(unicodedata.normalize("NFD", "übungsblatt_03 -balken"))


def test_front_matter_and_sources_in_the_known_forms():
    from app import wissensbank
    fm, body = wissensbank.front_matter("---\nfach: X\nquellen:\n  - kurz: Q1\n    titel: a-b\n    seiten: \"1-3\"\n"
                                        "  - {kurz: Q2, titel: \"Übung 07 - WS2930\", seiten: 4}\n"
                                        "  - \"[Q3] .../Ordner/Zettel 09 Lösungen.pdf, Seiten 1-2 (Musterlösung)\"\n"
                                        "  - \"Q4: probe99_auf.pdf (Kurztest, 10 Seiten)\"\n"
                                        "  - XY-Notizen_Teil_5 (Seiten 1–13)\nloesung_von: KI\n---\n# Titel\n")
    assert fm["fach"] == "X" and fm["loesung_von"] == "KI" and body.startswith("# Titel")
    src = {s.kurz: s.titles for s in wissensbank.sources_of(fm["quellen"])}
    assert "ab" in src["Q1"] and "übung07ws2930" in src["Q2"]
    assert "zettel09lösungen" in src["Q3"] and "probe99auf" in src["Q4"] and "xynotizenteil5" in src[None]


def test_answer_text_and_hints(lib):
    from app import wissensbank
    hit = wissensbank.match(lib, mode="steps", datei=BLATT, seite=2, text=A2)
    text = wissensbank.answer_text(hit.unit, hit.sections)
    assert text.startswith("## Aufgabe 2: Kragarm") and "LOESUNG-2" in text and "[Q1]" not in text.split("\n")[0]
    assert "KI-Lösung, ungeprüft" in wissensbank.hints(hit.unit, hit.sections, text)
    hit = wissensbank.match(lib, mode="steps", datei=BLATT, seite=1, text=A1A + "\n" + A1B)
    text = wissensbank.answer_text(hit.unit, hit.sections)
    assert "LOESUNG-1A" in text and "LOESUNG-1B" in text and "LOESUNG-2" not in text


# ================================================================== Ablauf im Dienst

@pytest.fixture
def wb(hosted, monkeypatch):
    from app import ai_backend, wissensbank
    cheap_calls(monkeypatch)
    monkeypatch.setenv("LERNAPP_AI_RATE_PER_MINUTE", "500")
    monkeypatch.setenv("LERNAPP_AI_RATE_PER_HOUR", "500")
    monkeypatch.setenv("LERNAPP_WISSENSBANK", "1")
    monkeypatch.setenv("LERNAPP_WISSENSBANK_DIR", str(FIXTURE))
    wissensbank._LIB.clear()
    fake = FakeAI()
    ai_backend.set_provider(fake)
    return hosted, fake


def ask(app, headers, *, mode="explain", text=S2, datei=FOLIEN, seite=2, rid=None, **extra):
    body = {"task": f"tutor:{mode}", "prompt": "SEITENTEXT:\n" + text, "request_id": rid or uuid.uuid4().hex,
            "wissensbank": {"datei": datei, "kurs": "", "seite": seite, "text": text}, **extra}
    return _j(asgi_call(app, "POST", "/api/ai/relay", headers=headers, body=json.dumps(body)))


def feedback(app, headers, token, better):
    return _j(asgi_call(app, "POST", "/api/ai/feedback", headers=headers, body=json.dumps({"token": token, "better": better})))


def ledger(user_id):
    from app import credits
    conn = credits.connect()
    try:
        return conn.execute("SELECT purpose, charged, cost_microeur, model FROM credit_ledger WHERE user_id=? ORDER BY created_at",
                            (user_id,)).fetchall()
    finally:
        conn.close()


def test_first_answer_from_the_wissensbank_then_ai_and_question(wb):
    app, fake = wb
    u, h = user(app, "luh1@beispiel.de", plan="pro_ai")
    st, d = ask(app, h)
    assert st == 200, d
    assert d["source"] == "wissensbank" and d["wissensbank_key"] == K_S2 and "ERKLAERUNG-SEITE-2" in d["answer"]
    assert d["wissensbank"]["badge"] == "Aus der StudiNow-Wissensbank" and "feedback_token" not in d
    assert d["credits"]["charged"] == 1 and d["credits"]["remaining"] == 99 and fake.calls == 0
    assert ledger(u["id"]) == [("tutor:wissensbank", 1, 0, "wissensbank")], "1 Credit, echte Kosten 0"
    # dieselbe Stelle auf einer verschobenen Seite noch einmal: normale KI, wie immer berechnet, mit Frage
    st, d = ask(app, h, text="Neue Folie davor\n" + S2, seite=3)
    assert st == 200 and fake.calls == 1 and d["source"] == "ki" and d["wissensbank_key"] == K_S2
    assert d["credits"]["charged"] == 9 and d["feedback_token"] and d["feedback_question"] == "Gefällt dir diese Antwort besser?"
    # eine andere Stelle ist wieder neu
    st, d = ask(app, h, text=S3, seite=3)
    assert d["source"] == "wissensbank" and d["wissensbank_key"] == K_S3 and fake.calls == 1


def test_yes_stores_a_candidate_without_account_and_review_releases_it(wb, capsys):
    from app import wissensbank, wissensbank_pruefen
    app, fake = wb
    _u1, h1 = user(app, "luh-a@beispiel.de", plan="pro_ai")
    ask(app, h1)
    _, d = ask(app, h1)
    st, r = feedback(app, h1, d["feedback_token"], True)
    assert (st, r) == (200, {"ok": True, "stored": True})
    assert feedback(app, h1, d["feedback_token"], True)[0] == 404, "jede Frage nur einmal"
    conn = wissensbank.connect()
    try:
        cols = [c[1] for c in conn.execute("PRAGMA table_info(wissensbank_candidates)")]
        cand = conn.execute("SELECT id, wb_key, answer, status, votes_yes FROM wissensbank_candidates").fetchall()
        assert conn.execute("SELECT COUNT(*) FROM wissensbank_feedback").fetchone()[0] == 0
    finally:
        conn.close()
    assert "user_id" not in cols and "question" not in cols and "prompt" not in cols
    (cid, key, answer, status, votes), = cand
    assert (key, status, votes) == (K_S2, "ungeprueft", 1) and answer.startswith("Erklärung: Eine Matrix")
    # ungeprueft: ein anderes Konto bekommt weiter die Bibliothek
    _u2, h2 = user(app, "luh-b@beispiel.de", plan="pro_ai")
    _, d = ask(app, h2)
    assert d["source"] == "wissensbank" and "ERKLAERUNG-SEITE-2" in d["answer"] and d["wissensbank"]["status"] == ""
    # Pruefung durch den Inhaber
    assert wissensbank_pruefen.main(["--liste"]) == 0 and f"#{cid}" in capsys.readouterr().out
    assert wissensbank_pruefen.main(["--zeigen", str(cid)]) == 0 and "ERKLAERUNG-SEITE-2" in capsys.readouterr().out
    assert wissensbank_pruefen.main(["--freigeben", str(cid)]) == 0
    _u3, h3 = user(app, "luh-c@beispiel.de", plan="pro_ai")
    _, d = ask(app, h3)
    assert d["source"] == "wissensbank" and d["answer"].startswith("Erklärung: Eine Matrix") and d["wissensbank"]["status"] == "geprüft"
    # "Nein" nach dem freigegebenen Kandidaten: Stimme fuer ihn; Wahl des Inhabers geht vor
    _, d = ask(app, h3)
    assert feedback(app, h3, d["feedback_token"], False)[1] == {"ok": True, "stored": False}
    assert wissensbank_pruefen.main(["--waehlen", K_S2, "--antwort", "bibliothek"]) == 0
    _u4, h4 = user(app, "luh-d@beispiel.de", plan="pro_ai")
    assert "ERKLAERUNG-SEITE-2" in ask(app, h4)[1]["answer"]
    assert wissensbank_pruefen.main(["--waehlen", K_S2, "--antwort", "auto"]) == 0
    assert wissensbank_pruefen.main(["--ablehnen", str(cid)]) == 0
    _u5, h5 = user(app, "luh-e@beispiel.de", plan="pro_ai")
    assert "ERKLAERUNG-SEITE-2" in ask(app, h5)[1]["answer"], "abgelehnt: wieder die Bibliothek"
    assert wissensbank_pruefen.main(["--freigeben", "999"]) == 1


def test_choice_rule_library_votes_against_approved_candidate(wb):
    from app import wissensbank
    conn = wissensbank.connect()
    try:
        conn.execute("INSERT INTO wissensbank_candidates(wb_key, answer, answer_hash, created_at, votes_yes, status) "
                     "VALUES (?,?,?,?,?,?)", ("k", "A", "h1", "2026-11-20", 2, "geprueft"))
        conn.execute("INSERT INTO wissensbank_candidates(wb_key, answer, answer_hash, created_at, votes_yes, status) "
                     "VALUES (?,?,?,?,?,?)", ("k", "B", "h2", "2026-11-20", 5, "ungeprueft"))
        conn.commit()
        assert wissensbank.choose(conn, "k")["answer"] == "A", "nur Freigegebene; mehr Stimmen als die Bibliothek (0)"
        conn.execute("INSERT INTO wissensbank_keys(wb_key, library_votes) VALUES ('k', 2)")
        conn.commit()
        assert wissensbank.choose(conn, "k") is None, "Gleichstand: die Bibliothek"
    finally:
        conn.close()


def test_only_pro_ai_at_luh_and_only_with_the_switch(wb, monkeypatch):
    from app import wissensbank
    app, fake = wb
    _u, h_hi = user(app, "hi@beispiel.de", plan="pro_ai", uni="hildesheim")
    st, d = ask(app, h_hi)
    assert st == 200 and d["source"] == "ki" and "wissensbank_key" not in d and fake.calls == 1
    _, d = ask(app, h_hi)
    assert "feedback_token" not in d, "keine Frage, keine Kandidaten ausserhalb der LUH"
    conn = wissensbank.connect()
    try:
        assert conn.execute("SELECT COUNT(*) FROM wissensbank_delivered").fetchone()[0] == 0
    finally:
        conn.close()
    _u, h = user(app, "luh-pro@beispiel.de", plan="pro_ai")
    assert _j(asgi_call(app, "GET", "/api/entitlements", headers=h))[1]["wissensbank"] is True
    assert "wissensbank" not in _j(asgi_call(app, "GET", "/api/entitlements", headers=h_hi))[1]
    _u, h_plus = user(app, "luh-plus@beispiel.de", plan="plus")
    assert "wissensbank" not in _j(asgi_call(app, "GET", "/api/entitlements", headers=h_plus))[1]
    st, d = ask(app, h_plus)
    assert st == 403, "Erklaeren bleibt Pro AI"
    # Bild ("Bereich an KI") und zweite Meinung: nie aus der Wissensbank
    _, d = ask(app, h, second_opinion=True)
    assert d["source"] == "ki"
    monkeypatch.setenv("LERNAPP_WISSENSBANK", "0")
    _, d = ask(app, h)
    assert "source" not in d and "wissensbank_key" not in d, "Schalter aus: Antwort wie bisher"
    assert "wissensbank" not in _j(asgi_call(app, "GET", "/api/entitlements", headers=h))[1]


def test_university_of_the_account_counts_not_the_client(wb):
    app, fake = wb
    _u, h = user(app, "hsh@beispiel.de", plan="pro_ai", uni="hsh")
    _, d = ask(app, h, university="luh")
    assert d["source"] == "ki" and fake.calls == 1


def test_replay_of_the_same_request_is_free_and_keeps_the_badge(wb):
    app, fake = wb
    _u, h = user(app, "luh-replay@beispiel.de", plan="pro_ai")
    _, d1 = ask(app, h, rid="r-1")
    st, d2 = ask(app, h, rid="r-1")
    assert st == 200 and d2["answer"] == d1["answer"] and d2["credits"]["replay"] is True
    assert d2["source"] == "wissensbank" and d2["wissensbank_key"] == K_S2 and fake.calls == 0
    assert d2["credits"]["remaining"] == 99


def test_no_credits_no_wissensbank_answer(wb, monkeypatch):
    app, fake = wb
    monkeypatch.setenv("LERNAPP_CREDITS_PRO_AI", "0")
    _u, h = user(app, "luh-leer@beispiel.de", plan="pro_ai")
    st, d = ask(app, h)
    assert (st, d["code"]) == (429, "credits_exhausted") and fake.calls == 0


def test_rate_limit_counts_wissensbank_answers(wb, monkeypatch):
    app, _ = wb
    monkeypatch.setenv("LERNAPP_AI_RATE_PER_MINUTE", "1")
    _u, h = user(app, "luh-rate@beispiel.de", plan="pro_ai")
    assert ask(app, h)[0] == 200
    st, d = ask(app, h, text=S3, seite=3)
    assert (st, d["code"]) == (429, "ai_rate_limited")


def test_feedback_is_only_for_the_asker_and_validated(wb):
    app, _ = wb
    _u, h = user(app, "luh-x@beispiel.de", plan="pro_ai")
    _u, h_other = user(app, "luh-y@beispiel.de", plan="pro_ai")
    ask(app, h)
    _, d = ask(app, h)
    assert feedback(app, h_other, d["feedback_token"], True)[0] == 404
    assert feedback(app, h, d["feedback_token"], "ja")[0] == 400
    assert feedback(app, h, d["feedback_token"], True)[0] == 200


def test_account_deletion_removes_delivered_log_and_open_questions():
    from app import accounts
    assert {"wissensbank_delivered", "wissensbank_feedback"} <= set(accounts.ACCOUNT_TABLES)


def test_fixture_is_invented_and_small():
    """Schutz vor echten Inhalten im oeffentlichen Repository: nur das kleine, erfundene Beispiel."""
    files = [p for p in FIXTURE.rglob("*") if p.is_file()]
    assert len(files) <= 10 and sum(p.stat().st_size for p in files) < 20_000
    kat = json.loads((FIXTURE / "katalog.json").read_text(encoding="utf-8"))
    assert "ERFUNDENES" in kat["hinweis"] and len(kat["faecher"]) == 2
    assert sum(len(f["einheiten"]) for f in kat["faecher"]) == 3


def test_open_questions_expire_after_seven_days(wb):
    from datetime import datetime, timedelta, timezone

    from app import wissensbank
    app, _ = wb
    _u, h = user(app, "luh-alt@beispiel.de", plan="pro_ai")
    ask(app, h)
    _, d = ask(app, h)
    conn = wissensbank.connect()
    try:
        old = (datetime.now(timezone.utc) - timedelta(days=8)).isoformat()
        conn.execute("UPDATE wissensbank_feedback SET created_at=?", (old,))
        conn.commit()
        wissensbank._expire_feedback(conn)
        assert conn.execute("SELECT COUNT(*) FROM wissensbank_feedback").fetchone()[0] == 0
    finally:
        conn.close()
    assert feedback(app, h, d["feedback_token"], True)[0] == 404

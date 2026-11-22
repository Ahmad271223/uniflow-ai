"""StudiNow-Wissensbank, Erweiterungen vom 21.11.2026 (Auftrag des Inhabers):
C. Vorab-Frage `POST /api/ai/wissensbank` (die App fragt VOR ihrem Erklaerungsspeicher), Vorrang vor dem Zwischenspeicher.

Die Bibliothek ist das kleine, ERFUNDENE Beispiel aus tests/fixtures/wissensbank (siehe tests/test_wissensbank.py)."""
import json
import uuid

from conftest import asgi_call
from test_subscriptions import _j, hosted, user  # noqa: F401 (Fixtures)
from test_wissensbank import FOLIEN, K_S2, K_S3, S2, S3, ask, ledger, wb  # noqa: F401 (Fixtures)

ANDERER_TEXT = ("Die Photosynthese wandelt Lichtenergie in chemische Energie um. Dabei entstehen aus Kohlendioxid und Wasser "
                "Traubenzucker und Sauerstoff; der Vorgang findet in den Chloroplasten der Pflanzenzellen statt.")


def vorab(app, headers, *, mode="explain", text=S2, datei=FOLIEN, seite=2, rid=None, wb_extra=None, **extra):
    body = {"mode": mode, "request_id": rid or uuid.uuid4().hex,
            "wissensbank": {"datei": datei, "kurs": "", "seite": seite, "text": text, **(wb_extra or {})}, **extra}
    return _j(asgi_call(app, "POST", "/api/ai/wissensbank", headers=headers, body=json.dumps(body)))


def quota_used(app, headers, feature="ai_assist"):
    d = _j(asgi_call(app, "GET", "/api/entitlements", headers=headers))[1]
    return d["quotas"][feature]["used"]


# ================================================================== C. Vorab-Frage

def test_vorab_hit_delivers_like_the_relay_and_costs_one_credit(wb):
    app, fake = wb
    u, h = user(app, "vorab1@beispiel.de", plan="pro_ai")
    rid = uuid.uuid4().hex
    st, d = vorab(app, h, rid=rid)
    assert st == 200 and d["treffer"] is True, d
    assert d["source"] == "wissensbank" and d["wissensbank_key"] == K_S2 and "ERKLAERUNG-SEITE-2" in d["answer"]
    assert d["wissensbank"] == {"badge": "Aus der StudiNow-Wissensbank", "status": "", "hinweise": []}
    assert d["task"] == "tutor:explain" and d["model"] == "wissensbank" and d["shared"] is False and d["replay"] is False
    assert d["credits"]["charged"] == 1 and d["credits"]["remaining"] == 99 and fake.calls == 0
    assert ledger(u["id"]) == [("tutor:wissensbank", 1, 0, "wissensbank")]
    assert quota_used(app, h) == 1, "zaehlt im Kontingent wie eine KI-Anfrage"
    # dieselbe Antwort wie ueber /api/ai/relay (bis auf `treffer`)
    u2, h2 = user(app, "vorab1b@beispiel.de", plan="pro_ai")
    _, r = ask(app, h2)
    assert {k: v for k, v in d.items() if k not in ("treffer", "credits")} == {k: v for k, v in r.items() if k != "credits"}
    # dieselbe request_id noch einmal (Netzfehler): dieselbe Antwort, nichts neu berechnet
    st, d2 = vorab(app, h, rid=rid)
    assert st == 200 and d2["treffer"] is True and d2["replay"] is True and d2["answer"] == d["answer"]
    assert d2["source"] == "wissensbank" and d2["wissensbank_key"] == K_S2 and d2["credits"]["charged"] == 0
    assert len(ledger(u["id"])) == 1 and quota_used(app, h) == 1 and fake.calls == 0


def test_vorab_without_hit_costs_nothing_and_never_calls_the_ai(wb):
    app, fake = wb
    u, h = user(app, "vorab2@beispiel.de", plan="pro_ai")
    st, d = vorab(app, h, text=ANDERER_TEXT)
    assert (st, d) == (200, {"treffer": False, "grund": "kein_treffer", "task": "tutor:explain"})
    st, d = vorab(app, h, text="   ")
    assert (st, d["treffer"], d["grund"]) == (200, False, "keine_angaben")
    st, d = _j(asgi_call(app, "POST", "/api/ai/wissensbank", headers=h, body=json.dumps({"mode": "steps", "request_id": "x1"})))
    assert (st, d["treffer"], d["grund"], d["task"]) == (200, False, "keine_angaben", "tutor:steps")
    assert ledger(u["id"]) == [] and quota_used(app, h) == 0 and fake.calls == 0
    # schon geliefert: die Vorab-Frage liefert die Stelle demselben Konto kein zweites Mal
    assert vorab(app, h)[1]["treffer"] is True
    st, d = vorab(app, h, text="Neue Folie davor\n" + S2, seite=3)
    assert (st, d) == (200, {"treffer": False, "grund": "schon_geliefert", "task": "tutor:explain"})
    assert len(ledger(u["id"])) == 1 and quota_used(app, h) == 1 and fake.calls == 0
    # ueber /api/ai/relay kommt dann wie bisher die KI mit der Ja/Nein-Frage
    st, d = ask(app, h, text="Neue Folie davor\n" + S2, seite=3)
    assert d["source"] == "ki" and d["feedback_token"] and fake.calls == 1


def test_vorab_only_for_entitled_accounts_and_only_with_the_switch(wb, monkeypatch):
    app, fake = wb
    for email, kw in (("vorab-hi@beispiel.de", dict(plan="pro_ai", uni="hildesheim")), ("vorab-plus@beispiel.de", dict(plan="plus")),
                      ("vorab-frei@beispiel.de", dict()), ("vorab-unbest@beispiel.de", dict(plan="pro_ai", verified=False))):
        u, h = user(app, email, **kw)
        st, d = vorab(app, h)
        assert (st, d) == (200, {"treffer": False, "grund": "nicht_berechtigt", "task": "tutor:explain"}), email
        assert ledger(u["id"]) == []
    u, h = user(app, "vorab-luh@beispiel.de", plan="pro_ai")
    monkeypatch.setenv("LERNAPP_WISSENSBANK", "0")
    assert vorab(app, h)[1] == {"treffer": False, "grund": "nicht_berechtigt", "task": "tutor:explain"}
    monkeypatch.setenv("LERNAPP_WISSENSBANK", "1")
    assert vorab(app, h)[1]["treffer"] is True and fake.calls == 0


def test_vorab_errors_like_the_relay(wb):
    app, _ = wb
    _u, h = user(app, "vorab-fehler@beispiel.de", plan="pro_ai")
    st, d = _j(asgi_call(app, "POST", "/api/ai/wissensbank", body=json.dumps({"mode": "explain", "wissensbank": {"text": S2}})))
    assert st == 401
    for body in ({"mode": "ask"}, {"task": "tutor:summary"}, {"task": "week_test"}, {}):
        st, d = _j(asgi_call(app, "POST", "/api/ai/wissensbank", headers=h, body=json.dumps({**body, "wissensbank": {"text": S2, "datei": FOLIEN}})))
        assert (st, d["code"]) == (400, "task_unknown"), body
    # `task` wie in /api/ai/relay geht auch
    st, d = _j(asgi_call(app, "POST", "/api/ai/wissensbank", headers=h, body=json.dumps(
        {"task": "tutor:explain", "request_id": "r-task", "wissensbank": {"text": S2, "datei": FOLIEN, "seite": 2}})))
    assert st == 200 and d["treffer"] is True


def test_vorab_no_credits_quota_or_rate_is_an_empty_answer(wb, monkeypatch):
    from app import plans
    app, fake = wb
    monkeypatch.setenv("LERNAPP_AI_RATE_PER_MINUTE", "1")
    u, h = user(app, "vorab-rate@beispiel.de", plan="pro_ai")
    assert vorab(app, h)[1]["treffer"] is True
    st, d = vorab(app, h, text=S3, seite=3)
    assert (st, d["treffer"], d["grund"]) == (200, False, "rate")
    assert len(ledger(u["id"])) == 1 and quota_used(app, h) == 1, "Kontingent zurueckgegeben"
    monkeypatch.setenv("LERNAPP_AI_RATE_PER_MINUTE", "500")
    monkeypatch.setitem(plans.QUOTAS, "pro_ai", {**plans.QUOTAS["pro_ai"], "ai_assist": 1})
    st, d = vorab(app, h, text=S3, seite=3)
    assert (st, d["treffer"], d["grund"]) == (200, False, "kontingent") and len(ledger(u["id"])) == 1
    monkeypatch.setenv("LERNAPP_CREDITS_PRO_AI", "0")
    u2, h2 = user(app, "vorab-leer@beispiel.de", plan="pro_ai")
    st, d = vorab(app, h2)
    assert (st, d["treffer"], d["grund"]) == (200, False, "credits") and fake.calls == 0 and quota_used(app, h2) == 0


def test_vorab_takes_ausschnitt_from_the_wissensbank_fields(wb):
    """Hier gibt es kein Bild: ob der Text nur ein Ausschnitt ist, sagt allein das Feld `wissensbank.ausschnitt`."""
    app, _ = wb
    from test_wissensbank import KURS_STATIK, S2_HALB
    _u, h = user(app, "vorab-teil@beispiel.de", plan="pro_ai")
    kw = dict(text=S2_HALB, datei="Statik_Folien_neu_v2.pdf")
    body = {"mode": "explain", "request_id": uuid.uuid4().hex, "wissensbank": {"datei": kw["datei"], "kurs": KURS_STATIK, "seite": 2, "text": S2_HALB}}
    st, d = _j(asgi_call(app, "POST", "/api/ai/wissensbank", headers=h, body=json.dumps(body)))
    assert d["treffer"] is False and d["grund"] == "kein_treffer"
    body["wissensbank"]["ausschnitt"] = True
    body["request_id"] = uuid.uuid4().hex
    st, d = _j(asgi_call(app, "POST", "/api/ai/wissensbank", headers=h, body=json.dumps(body)))
    assert d["treffer"] is True and d["wissensbank_key"] == K_S2


def test_relay_prefers_the_wissensbank_over_the_shared_cache(wb):
    """Im Zwischenspeicher des Dienstes liegt zur selben Anfrage schon eine KI-Antwort (0 Credits fuer alle). Ein Konto
    mit Wissensbank bekommt trotzdem die Stelle aus der Wissensbank; nur dieselbe request_id bleibt eine Wiederholung."""
    app, fake = wb
    _u, h_hi = user(app, "cache-hi@beispiel.de", plan="pro_ai", uni="hildesheim")
    st, d = ask(app, h_hi, cache=True)
    assert st == 200 and d["source"] == "ki" and d["shared"] is False and fake.calls == 1
    st, d = ask(app, h_hi, cache=True)
    assert d["shared"] is True and d["credits"]["charged"] == 0 and fake.calls == 1, "der Zwischenspeicher ist gefuellt"
    u, h = user(app, "cache-luh@beispiel.de", plan="pro_ai")
    rid = uuid.uuid4().hex
    st, d = ask(app, h, cache=True, rid=rid)
    assert d["source"] == "wissensbank" and d["shared"] is False and d["wissensbank_key"] == K_S2 and fake.calls == 1
    assert ledger(u["id"]) == [("tutor:wissensbank", 1, 0, "wissensbank")]
    st, d = ask(app, h, cache=True, rid=rid)
    assert d["replay"] is True and d["source"] == "wissensbank" and len(ledger(u["id"])) == 1


# ================================================================== A. KI mit Auszuegen aus der Wissensbank

import pytest  # noqa: E402
from test_subscriptions import FakeAI  # noqa: E402
from test_wissensbank import (A1A, A4, BLATT, K_4, KURS_STATIK, S5, STATIK, feedback)  # noqa: E402


class SpyAI(FakeAI):
    """Attrappe, die die Prompts festhaelt und je Aufruf eine andere Antwort gibt."""

    def __init__(self):
        super().__init__()
        self.prompts = []

    def complete(self, system, prompt, schema=None):
        from app.ai_backend import Completion
        super().complete(system, prompt, schema)
        self.prompts.append(prompt)
        return Completion(f"KI-ANTWORT-{self.calls}", 120, 40, "fake")


@pytest.fixture
def ki(wb, monkeypatch):
    from app import ai_backend
    app, _ = wb
    spy = SpyAI()
    ai_backend.set_provider(spy)
    return app, spy


# Aufgabe 4, wie die Texterkennung sie liefert: ohne die Zahlen (der genaue Abgleich liefert dann nichts)
A4_OHNE_ZAHLEN = ("Aufgabe 4 (6 Punkte)\nEin Dreigelenkbogen hat die Punkte A, B und C (Angaben in Metern).\nIm Punkt C greift die "
                  "Last F an. Bestimmen Sie den Hebelarm der Last um den Punkt A\nund mit dem Momentengleichgewicht die Auflagerkraft im Punkt B.")
A4_NEUE_ZAHLEN = A4.replace("(4, 0, 7)", "(1, 0, 3)").replace("(9, 3, 8)", "(5, 2, 9)").replace("(6, 5, 2)", "(7, 4, 1)").replace("18 kN", "30 kN")
# Aufgabe 4 unter einer anderen Nummer (verschobenes Blatt): kein genauer Treffer, aber die Zahlen belegen die Stelle
A4_NR9 = A4.replace("Aufgabe 4", "Aufgabe 9")
OHNE_FELDER = {"answer", "model", "shared", "replay", "credits", "task", "source"}


def test_kontext_switch_off_changes_nothing(ki):
    """Schalter aus (Standard): Prompt und Antwortfelder wie bisher."""
    app, spy = ki
    u, h = user(app, "kontext-aus@beispiel.de", plan="pro_ai")
    st, d = ask(app, h, mode="steps", text=A4_OHNE_ZAHLEN, datei=BLATT, seite=2)
    assert st == 200 and set(d) == OHNE_FELDER and d["source"] == "ki" and d["answer"] == "KI-ANTWORT-1"
    assert spy.prompts == ["SEITENTEXT:\n" + A4_OHNE_ZAHLEN]
    assert [r[0] for r in ledger(u["id"])] == ["tutor:steps"]


def test_kontext_gives_the_ai_the_matching_section_as_a_marked_block(ki, monkeypatch):
    from app import wissensbank, wissensbank_ki
    monkeypatch.setenv("LERNAPP_WISSENSBANK_KONTEXT", "1")
    app, spy = ki
    u, h = user(app, "kontext1@beispiel.de", plan="pro_ai")
    st, d = ask(app, h, mode="steps", text=A4_NR9, datei=BLATT, seite=2)
    assert st == 200 and d["source"] == "ki" and d["wissensbank_kontext"] is True and d["answer"] == "KI-ANTWORT-1"
    assert set(d) == OHNE_FELDER | {"wissensbank_kontext"}, "kein Abzeichen, kein Schluessel: fuer die heutige App eine KI-Antwort"
    prompt = spy.prompts[0]
    assert prompt.startswith("SEITENTEXT:\n" + A4_NR9 + wissensbank_ki.KONTEXT_KOPF) and prompt.endswith(wissensbank_ki.KONTEXT_FUSS)
    block = prompt.split(wissensbank_ki.KONTEXT_KOPF, 1)[1]
    # die Zahlen der Anfrage waehlen die Stelle: nur dieses Semester, nicht das Vorjahr mit anderen Zahlen
    assert "LOESUNG-4:" in block and "LOESUNG-4-VORJAHR" not in block and block.count("--- Auszug") == 1
    assert "nur, wenn er wirklich dieselbe Seite bzw. dieselbe Aufgabe" in prompt and "Musterlösung" in wissensbank_ki.KONTEXT_KOPF
    assert "[Q1]" not in block and "G000" not in block
    # abgerechnet wie jede KI-Antwort, nichts als "geliefert" vermerkt
    assert ledger(u["id"]) == [("tutor:steps", 9, 56000, "fake")]
    conn = wissensbank.connect()
    try:
        assert conn.execute("SELECT COUNT(*) FROM wissensbank_delivered").fetchone()[0] == 0
    finally:
        conn.close()


def test_kontext_never_carries_the_abgleich_notes_or_internal_marks(lib_ki):
    from app import wissensbank_ki
    unit = lib_ki.unit(STATIK, "G0002")
    sec = next(x for x in unit.sections if x.sid == "02#Q1-Aufgabe-1-a")
    text = wissensbank_ki._auszug(unit, sec, 4000)
    assert "LOESUNG-1A" in text and "ERKLAERUNG-1A" in text
    for gone in ("ABGLEICH", "Abgleich", "[Q1]", "G0002"):
        assert gone not in text, gone


def test_kontext_other_numbers_other_title_or_other_account_get_nothing(ki, monkeypatch):
    monkeypatch.setenv("LERNAPP_WISSENSBANK_KONTEXT", "1")
    app, spy = ki
    _u, h = user(app, "kontext3@beispiel.de", plan="pro_ai")
    # dieselbe Aufgabe mit anderen Zahlen (neues Semester): kein Auszug - die Loesung waere falsch
    st, d = ask(app, h, mode="steps", text=A4_NEUE_ZAHLEN, datei=BLATT, seite=2)
    assert "wissensbank_kontext" not in d and spy.prompts[-1] == "SEITENTEXT:\n" + A4_NEUE_ZAHLEN
    # Aufgabe ohne lesbare Zahlen (Texterkennung): nichts, auch wenn Dateititel und Aufgabennummer passen - dieselbe
    # Aufgabe eines anderen Semesters haette denselben Wortlaut
    st, d = ask(app, h, mode="steps", text=A4_OHNE_ZAHLEN, datei=BLATT, seite=2)
    assert "wissensbank_kontext" not in d and "AUSZÜGE" not in spy.prompts[-1]
    # zu einer Aufgabe gehen keine Folien mit (die Begriffe der Lagerarten-Folie, aber mit Aufgaben-Ueberschrift)
    st, d = ask(app, h, text="Aufgabe 2 (3 Punkte)\n" + S5, seite=9)
    assert "wissensbank_kontext" not in d and "AUSZÜGE" not in spy.prompts[-1]
    # ganz anderer Text
    st, d = ask(app, h, text=ANDERER_TEXT)
    assert "wissensbank_kontext" not in d and "AUSZÜGE" not in spy.prompts[-1]
    # zweite Meinung: wie bisher ohne Wissensbank
    st, d = ask(app, h, mode="steps", text=A4_NR9, datei=BLATT, seite=2, second_opinion=True)
    assert "wissensbank_kontext" not in d and "AUSZÜGE" not in spy.prompts[-1]
    # Konto ohne Wissensbank
    _u, h_hi = user(app, "kontext-hi@beispiel.de", plan="pro_ai", uni="hildesheim")
    st, d = ask(app, h_hi, mode="steps", text=A4_NR9, datei=BLATT, seite=2)
    assert set(d) == OHNE_FELDER and "AUSZÜGE" not in spy.prompts[-1]
    # Gegenprobe: mit Wissensbank bekommt dieselbe Anfrage den Auszug
    st, d = ask(app, h, mode="steps", text=A4_NR9, datei=BLATT, seite=2)
    assert d["wissensbank_kontext"] is True and "LOESUNG-4:" in spy.prompts[-1]


def test_kontext_for_slides_and_typed_questions_and_exact_hits_stay_exact(ki, monkeypatch):
    monkeypatch.setenv("LERNAPP_WISSENSBANK_KONTEXT", "1")
    app, spy = ki
    u, h = user(app, "kontext4@beispiel.de", plan="pro_ai")
    # Folie auf einer anderen Seite als in der Bibliothek (kein genauer Treffer): die Erklaerung geht als Auszug mit
    st, d = ask(app, h, text=S5, seite=9)
    assert d["source"] == "ki" and d["wissensbank_kontext"] is True and "ERKLAERUNG-SEITE-5" in spy.prompts[-1]
    # interne Kennungen der Bibliothek ("[Q1]", "G0001") stehen im Abschnitt, aber nicht im Auszug
    assert "Vergleiche Seite 2 in ." in spy.prompts[-1] and "[Q1]" not in spy.prompts[-1] and "G0001" not in spy.prompts[-1]
    # getippte Frage (`tutor:ask`) mit Angaben zur Stelle: Auszug, aber nie eine Lieferung aus der Wissensbank
    st, d = ask(app, h, mode="ask", text=S5, seite=5)
    assert st == 200 and d["source"] == "ki" and d["wissensbank_kontext"] is True and "ERKLAERUNG-SEITE-5" in spy.prompts[-1]
    calls = spy.calls
    # ein genauer Treffer bleibt eine Lieferung aus der Wissensbank (ohne KI)
    st, d = ask(app, h, text=S5, seite=5)
    assert d["source"] == "wissensbank" and "wissensbank_kontext" not in d and spy.calls == calls
    st, d = ask(app, h, mode="steps", text=A4, datei=BLATT, seite=2)
    assert d["source"] == "wissensbank" and d["wissensbank_key"] == K_4 and spy.calls == calls


def test_kontext_search_and_block_are_bounded(lib_ki):
    from test_wissensbank import A4_VORJAHR
    from app import wissensbank_ki
    funde = wissensbank_ki.suche(lib_ki, datei=BLATT, seite=2, text=A4_NR9, stellen=5)
    assert [f.key for f in funde] == [f"{STATIK}/G0002/02#Q1-Aufgabe-4"] and funde[0].zahlen
    funde_vj = wissensbank_ki.suche(lib_ki, datei=BLATT, seite=2, text=A4_VORJAHR.replace("Aufgabe 4", "Aufgabe 9"))
    assert [f.key for f in funde_vj] == [f"{STATIK}/G0003/02#Q1-Aufgabe-4"], "gleicher Dateiname: die Zahlen waehlen das Semester"
    assert wissensbank_ki.suche(lib_ki, datei=BLATT, seite=2, text=A4_OHNE_ZAHLEN) == [], \
        "ohne Zahlen: Aufgabe 4 steht in zwei Semestern mit verschiedenen Zahlen, nichts entscheidet"
    assert wissensbank_ki.suche(lib_ki, datei=BLATT, seite=2, text=A4_NEUE_ZAHLEN) == [], "andere Zahlen: andere Fassung"
    assert wissensbank_ki.suche(lib_ki, datei=BLATT, seite=2, text="Aufgabe 4\n1 0 1 1 0 1 0 0 1") == []
    # Folie: ueber den Dateititel schon mit der Haelfte der Begriffe, ueber den Kurs erst mit 0,65
    assert [f.key for f in wissensbank_ki.suche(lib_ki, datei=FOLIEN, seite=9, text=S5)] == [f"{STATIK}/G0001/01#Q1-Seite-5"]
    assert [f.key for f in wissensbank_ki.suche(lib_ki, datei="x.pdf", kurs=KURS_STATIK, seite=9, text=S5)] == [f"{STATIK}/G0001/01#Q1-Seite-5"]
    halb = S5 + "\nWerkstoffe: Beton, Stahl, Holz\nKennwerte der Baustoffe"
    assert len(wissensbank_ki.suche(lib_ki, datei=FOLIEN, seite=9, text=halb)) == 1
    assert wissensbank_ki.suche(lib_ki, datei="x.pdf", kurs=KURS_STATIK, seite=9, text=halb) == []
    assert wissensbank_ki.suche(lib_ki, datei="x.pdf", kurs="Einführung in die Chemie", seite=9, text=S5) == []
    k = wissensbank_ki.kontext_block(funde)
    assert len(k.block) <= len(wissensbank_ki.KONTEXT_KOPF) + wissensbank_ki.KONTEXT_ZEICHEN + 200 and len(k.keys) == 1
    assert wissensbank_ki.kontext_block([]) is None
    assert wissensbank_ki._auszug(funde[0].unit, funde[0].sec, 60).endswith("[…gekürzt]")
    assert (wissensbank_ki.KONTEXT_STELLEN, wissensbank_ki.KONTEXT_ZEICHEN, wissensbank_ki.KONTEXT_ANTEIL,
            wissensbank_ki.KONTEXT_ANTEIL_KURS, wissensbank_ki.KONTEXT_BEGRIFFE) == (2, 6000, 0.5, 0.65, 6)


# Fehlfall des Inhabers 22.11.2026, nachgebaut mit einer erfundenen Formel: eingekreister Kopf einer Formel-Aufgabe, so
# wie die Texterkennung ihn liefert ("V" fuer ∨, "A" oder "1" fuer ∧)
FORMEL_TEIL = "Aufgabe 2.3.1 Schaltfunktionen\na) Regel 3: Ausmultiplizieren\nz = a1 A (a2 V a3 V (a4 1 a5))"
UEBUNG_NEU, UEBUNG_ALT = "logik-uebung2-ws26.pdf", "logik-uebung2.pdf"
F231_STELLE = "Beispiel-Algorithmen/G0002/02#Q1-Aufgabe-2-3-1"


def test_short_formula_task_goes_to_the_ai_as_an_excerpt(lib_ki):
    """Dateititel + dieselbe Aufgabenbezeichnung in der Ueberschrift + die mitgeschickte Seite steht im Abschnitt + die
    wenigen Woerter passen: Der Abschnitt geht als Auszug mit, auch ohne lesbare Zahlen. Das laufende Semester hat nur
    Verweise; mitgegeben wird der Abschnitt mit dem Inhalt (einmal, nicht je Verweis)."""
    from app import wissensbank_ki
    funde = wissensbank_ki.suche(lib_ki, datei=UEBUNG_NEU, kurs="Beispiel-Algorithmen", seite=15, text=FORMEL_TEIL)
    assert [f.key for f in funde] == [F231_STELLE] and funde[0].hinweis
    assert [f.key for f in wissensbank_ki.suche(lib_ki, datei=UEBUNG_ALT, seite=16, text=FORMEL_TEIL)] == [F231_STELLE]
    assert "FORMEL-LOESUNG-A" in wissensbank_ki.kontext_block(funde).block
    # auch ein laengerer Ausschnitt ohne lesbare Zahlen (die Texterkennung hat die Formel ausgelassen)
    lang = ("Aufgabe 2.3.1 Schaltfunktionen\nGegeben ist der Ausdruck z. a) Lösen Sie die Klammern des Ausdrucks auf.\n"
            "b) Geben Sie eine Struktur an, die nur aus NOR-Gattern besteht.")
    assert [f.key for f in wissensbank_ki.suche(lib_ki, datei=UEBUNG_NEU, seite=14, text=lang)] == [F231_STELLE]
    assert wissensbank_ki.suche(lib_ki, datei=UEBUNG_NEU, seite=3, text=lang) == [], "ohne Zahlen nur mit der Seite"
    # lesbare Zahlen duerfen nicht widersprechen: andere Indizes, eine Zahl, die der Abschnitt nicht hat
    assert wissensbank_ki.suche(lib_ki, datei=UEBUNG_NEU, seite=15, text=FORMEL_TEIL.replace("a2 V a3 V (a4 1 a5)", "a7 V a9 V (a8 1 a6)")) == []
    assert wissensbank_ki.suche(lib_ki, datei=UEBUNG_NEU, seite=15, text=FORMEL_TEIL + " für n = 64") == []
    # der eingekreiste Bereich reicht bis in die Ueberschrift der naechsten Aufgabe: Die Woerter gehoeren zur Aufgabe
    # davor (gemessen am 22.11.2026: Auszug der Folgeaufgabe, weil deren Ueberschrift am Ende des Ausschnitts stand)
    from test_wissensbank import KURZ, STATIK
    bis_in_die_naechste = "Aufgabe 6\n" + KURZ + "\nAufgabe 7"
    assert [f.key for f in wissensbank_ki.suche(lib_ki, datei=BLATT, seite=2, text=bis_in_die_naechste)] == [f"{STATIK}/G0002/02#Q1-Aufgabe-6"]
    # ... auch mit dem Anfang ihrer ersten Zeile: Ein kleiner Rest am Ende des Ausschnitts ist nicht die gefragte Aufgabe
    mit_rest = bis_in_die_naechste + "\nSkizzieren Sie den Verlauf"
    assert [f.key for f in wissensbank_ki.suche(lib_ki, datei=BLATT, seite=2, text=mit_rest)] == [f"{STATIK}/G0002/02#Q1-Aufgabe-6"]
    for anders, kw in (("andere Seite, die der Abschnitt nicht nennt", dict(seite=3)),
                       ("andere Aufgabennummer", dict(text=FORMEL_TEIL.replace("2.3.1", "2.3.2"))),
                       ("anderer Dateititel", dict(datei="logik-uebung3.pdf")),
                       ("andere Woerter unter derselben Nummer", dict(text="Aufgabe 2.3.1 Sortierverfahren\na) Laufzeit von Quicksort\nT = n1 + n2")),
                       ("ohne Ueberschrift", dict(text=FORMEL_TEIL.split("\n", 1)[1]))):
        args = {**dict(datei=UEBUNG_NEU, seite=15, text=FORMEL_TEIL), **kw}
        assert wissensbank_ki.suche(lib_ki, **args) == [], anders


def test_short_formula_task_in_the_relay(ki, monkeypatch):
    monkeypatch.setenv("LERNAPP_WISSENSBANK_KONTEXT", "1")
    app, spy = ki
    u, h = user(app, "formel@beispiel.de", plan="pro_ai")
    st, d = ask(app, h, text=FORMEL_TEIL, datei=UEBUNG_NEU, seite=15, image="/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAAA//EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AN//Z")
    assert st == 200 and d["source"] == "ki" and d["wissensbank_kontext"] is True, d
    assert "FORMEL-LOESUNG-A" in spy.prompts[-1] and spy.prompts[-1].count("--- Auszug") == 1
    assert [r[0] for r in ledger(u["id"])] == ["tutor:explain"], "keine Lieferung aus der Wissensbank, normale KI-Antwort"


@pytest.fixture
def lib_ki():
    from app import wissensbank
    from test_wissensbank import FIXTURE
    return wissensbank.Library(FIXTURE)


# ================================================================== B. Antworten merken

AUSSCHNITT = ("Ein Fachwerk besteht aus geraden Stäben, die in den Knoten gelenkig verbunden sind. Die Lasten greifen nur in den "
              "Knoten an, deshalb übertragen die Stäbe nur Zugkräfte oder Druckkräfte. Mit dem Knotenpunktverfahren schneidet "
              "man jeden Knoten frei und stellt zwei Gleichgewichtsbedingungen auf; bei 7 Stäben und 5 Knoten ist das Fachwerk "
              "statisch bestimmt.")
# derselbe Ausschnitt, von einem anderen Geraet gelesen: anderer Umbruch, ein Wort mehr am Rand
AUSSCHNITT_2 = "Fachwerke\n" + AUSSCHNITT.replace(". ", ".\n").replace("Ein Fachwerk", "Ein  Fachwerk")
FACHWERK = "Fachwerke - Folien 07.pdf"


def frage(app, headers, *, text=AUSSCHNITT, datei=FACHWERK, kurs=KURS_STATIK, seite=12, mode="explain", teilbar=True, rid=None, **extra):
    wbd = {"datei": datei, "kurs": kurs, "seite": seite, "text": text}
    if teilbar is not None:
        wbd["teilbar"] = teilbar
    body = {"task": f"tutor:{mode}", "prompt": "AUSSCHNITT:\n" + text, "request_id": rid or uuid.uuid4().hex, "wissensbank": wbd, **extra}
    return _j(asgi_call(app, "POST", "/api/ai/relay", headers=headers, body=json.dumps(body)))


def gemerkt_rows():
    from app import wissensbank_ki
    conn = wissensbank_ki.connect()
    try:
        cur = conn.execute("SELECT * FROM wissensbank_gemerkt ORDER BY id")
        cols = [c[0] for c in cur.description]
        return [dict(zip(cols, r)) for r in cur.fetchall()]
    finally:
        conn.close()


def test_merken_switch_off_changes_nothing(ki):
    app, spy = ki
    _u, h = user(app, "merken-aus@beispiel.de", plan="pro_ai")
    st, d = frage(app, h)
    st, d2 = frage(app, h)
    assert set(d) == OHNE_FELDER == set(d2) and spy.calls == 2 and gemerkt_rows() == []


def test_first_ai_answer_is_remembered_and_given_to_the_next_account(ki, monkeypatch):
    monkeypatch.setenv("LERNAPP_WISSENSBANK_MERKEN", "sofort")
    app, spy = ki
    u1, h1 = user(app, "merken1@beispiel.de", plan="pro_ai")
    st, d = frage(app, h1)
    assert st == 200 and d["source"] == "ki" and d["answer"] == "KI-ANTWORT-1" and set(d) == OHNE_FELDER
    rows = gemerkt_rows()
    assert len(rows) == 1 and rows[0]["answer"] == "KI-ANTWORT-1" and rows[0]["status"] == "ungeprueft" and rows[0]["seite"] == 12
    # ohne Konto und ohne Frage: keine Spalte nennt das Konto, der Prompt wird nicht gespeichert
    assert set(rows[0]) == {"id", "titel", "kurs", "mode", "seite", "text", "labels", "answer", "model", "kontext", "status", "votes_fuer",
                            "votes_gegen", "geliefert", "created_at", "reviewed_at"}
    assert u1["id"] not in json.dumps(rows[0]) and "merken1" not in json.dumps(rows[0]) and "AUSSCHNITT:" not in rows[0]["text"]
    # ein anderes Konto mit praktisch demselben Ausschnitt bekommt dieselbe Antwort, ohne KI
    u2, h2 = user(app, "merken2@beispiel.de", plan="pro_ai")
    rid = uuid.uuid4().hex
    st, d = frage(app, h2, text=AUSSCHNITT_2, rid=rid)
    assert st == 200 and d["source"] == "gemerkt" and d["answer"] == "KI-ANTWORT-1" and spy.calls == 1
    assert d["gemerkt"] == {"hinweis": "Gemerkte KI-Antwort"} and d["model"] == "gemerkt" and d["shared"] is False
    assert set(d) == OHNE_FELDER | {"gemerkt"} and "wissensbank_key" not in d, "die heutige App zeigt kein Abzeichen"
    assert d["credits"]["charged"] == 1 and ledger(u2["id"]) == [("tutor:gemerkt", 1, 0, "gemerkt")]
    assert gemerkt_rows()[0]["geliefert"] == 1 and len(gemerkt_rows()) == 1
    # dieselbe request_id noch einmal: dieselbe Antwort, nichts neu berechnet
    st, d = frage(app, h2, text=AUSSCHNITT_2, rid=rid)
    assert d["replay"] is True and d["source"] == "gemerkt" and d["answer"] == "KI-ANTWORT-1" and len(ledger(u2["id"])) == 1
    # der Erste selbst bekommt sie beim naechsten Mal auch (er hat sie nie "geliefert" bekommen)
    st, d = frage(app, h1)
    assert d["source"] == "gemerkt" and spy.calls == 1


def test_same_account_again_gets_a_fresh_answer_and_votes_can_replace_the_remembered_one(ki, monkeypatch):
    from app import wissensbank_ki
    monkeypatch.setenv("LERNAPP_WISSENSBANK_MERKEN", "sofort")
    app, spy = ki
    _u, h1 = user(app, "stimme1@beispiel.de", plan="pro_ai")
    frage(app, h1)                                             # KI-ANTWORT-1 wird gemerkt
    tokens = []
    for i in (2, 3):
        _u, h = user(app, f"stimme{i}@beispiel.de", plan="pro_ai")
        assert frage(app, h)[1]["source"] == "gemerkt"
        st, d = frage(app, h)                                  # dasselbe Konto noch einmal: frische KI-Antwort und die Frage
        assert d["source"] == "ki" and d["answer"] == f"KI-ANTWORT-{i}" and d["feedback_question"] == "Gefällt dir diese Antwort besser?"
        assert d["wissensbank_key"] == "gemerkt:1" and set(d) == OHNE_FELDER | {"wissensbank_key", "feedback_token", "feedback_question"}
        tokens.append((h, d["feedback_token"]))
    assert len(gemerkt_rows()) == 1, "es gilt noch die erste gemerkte Antwort"
    assert feedback(app, *tokens[0], True)[1] == {"ok": True, "stored": False}
    assert (gemerkt_rows()[0]["votes_gegen"], gemerkt_rows()[0]["votes_fuer"]) == (1, 0)
    _u, h4 = user(app, "stimme4@beispiel.de", plan="pro_ai")
    assert frage(app, h4)[1]["source"] == "gemerkt", "eine Stimme dagegen reicht nicht"
    assert feedback(app, *tokens[1], True)[0] == 200 and gemerkt_rows()[0]["votes_gegen"] == wissensbank_ki.MERKEN_ABWAHL
    # abgewaehlt: der Naechste bekommt die KI, und diese Antwort wird die neue gemerkte
    _u, h5 = user(app, "stimme5@beispiel.de", plan="pro_ai")
    st, d = frage(app, h5)
    assert d["source"] == "ki" and d["answer"] == "KI-ANTWORT-4" and "feedback_token" not in d
    rows = gemerkt_rows()
    assert [r["answer"] for r in rows] == ["KI-ANTWORT-1", "KI-ANTWORT-4"]
    _u, h6 = user(app, "stimme6@beispiel.de", plan="pro_ai")
    assert frage(app, h6)[1]["answer"] == "KI-ANTWORT-4" and spy.calls == 4
    # "Nein" (die gemerkte war besser) ist eine Stimme dafuer
    st, d = frage(app, h6)
    assert feedback(app, h6, d["feedback_token"], False)[0] == 200 and gemerkt_rows()[1]["votes_fuer"] == 1


def test_nothing_is_remembered_or_served_without_teilbar(ki, monkeypatch):
    """Die App sichert mit `teilbar: true` zu, dass nichts Persoenliches in der Anfrage steckt. Fehlt das Feld (heutige
    App) oder ist es false: nicht merken, nicht aus dem Gemerkten antworten."""
    monkeypatch.setenv("LERNAPP_WISSENSBANK_MERKEN", "sofort")
    app, spy = ki
    _u, h1 = user(app, "privat1@beispiel.de", plan="pro_ai")
    for teilbar in (None, False, "true", 1):
        st, d = frage(app, h1, teilbar=teilbar)
        assert d["source"] == "ki" and set(d) == OHNE_FELDER
    assert gemerkt_rows() == [] and spy.calls == 4
    frage(app, h1)                                             # jetzt teilbar: gemerkt
    assert len(gemerkt_rows()) == 1
    _u, h2 = user(app, "privat2@beispiel.de", plan="pro_ai")
    for teilbar in (None, False):
        assert frage(app, h2, teilbar=teilbar)[1]["source"] == "ki"
    # getippte Frage (`tutor:ask`) und zweite Meinung: nie
    assert frage(app, h2, mode="ask")[1]["source"] == "ki" and frage(app, h2, second_opinion=True)[1]["source"] == "ki"
    assert len(gemerkt_rows()) == 1 and frage(app, h2)[1]["source"] == "gemerkt"


def test_only_practically_the_same_part_gets_the_remembered_answer(ki, monkeypatch):
    monkeypatch.setenv("LERNAPP_WISSENSBANK_MERKEN", "sofort")
    app, spy = ki
    _u, h1 = user(app, "gleich1@beispiel.de", plan="pro_ai")
    frage(app, h1)
    _u, h2 = user(app, "gleich2@beispiel.de", plan="pro_ai")
    andere = [dict(text=AUSSCHNITT.replace("7 Stäben", "9 Stäben")),                 # andere Zahl
              dict(text=AUSSCHNITT.split("Mit dem Knotenpunktverfahren")[0]),        # nur die Haelfte
              dict(text=AUSSCHNITT + " " + ANDERER_TEXT),                            # viel mehr drumherum
              # Entscheidung des Inhabers 22.11.2026: nie ueber Seiten-, Datei- oder Kursgrenzen, auch bei gleichem Text
              dict(seite=13), dict(datei="Fachwerke - Folien 08.pdf"), dict(kurs="Einführung in die Chemie"), dict(mode="steps"),
              dict(text="Aufgabe 3\n" + AUSSCHNITT)]                                # Aufgabenbezeichnung im Ausschnitt
    for kw in andere:
        st, d = frage(app, h2, **kw)
        assert d["source"] == "ki", kw
    assert len(gemerkt_rows()) == 1 + len(andere), "jede davon ist eine eigene Stelle und wird selbst gemerkt"
    # gleicher Text unter einer anderen Aufgabennummer ist eine andere Stelle; dieselbe Nummer trifft
    _u, h4 = user(app, "gleich4@beispiel.de", plan="pro_ai")
    assert frage(app, h4, text="Aufgabe 4\n" + AUSSCHNITT)[1]["source"] == "ki"
    assert frage(app, h4, text="Aufgabe 3\n" + AUSSCHNITT_2)[1]["source"] == "gemerkt"
    # ohne Kurs oder ohne Dateititel ist "dieselbe Stelle" nicht belegt: nicht merken, nicht ausliefern
    n = len(gemerkt_rows())
    assert frage(app, h4, kurs="")[1]["source"] == "ki" and frage(app, h4, datei="")[1]["source"] == "ki" and len(gemerkt_rows()) == n
    assert frage(app, h2)[1]["source"] == "gemerkt"
    # "Neu erklaeren lassen": frische Antwort, die gemerkte bleibt
    _u, h3 = user(app, "gleich3@beispiel.de", plan="pro_ai")
    calls = spy.calls
    st, d = frage(app, h3, fresh=True)
    assert d["source"] == "ki" and spy.calls == calls + 1 and len(gemerkt_rows()) == n


def test_gleich_rule():
    from app import wissensbank, wissensbank_ki
    t = wissensbank.tokens
    assert wissensbank_ki.gleich(t(AUSSCHNITT), t(AUSSCHNITT_2))
    assert not wissensbank_ki.gleich(t(AUSSCHNITT), t(AUSSCHNITT.replace("5 Knoten", "6 Knoten")))
    assert not wissensbank_ki.gleich(t(AUSSCHNITT), t(AUSSCHNITT + " Zusatz: 7 Stäbe."))
    assert not wissensbank_ki.gleich(t(AUSSCHNITT), t(ANDERER_TEXT))
    assert not wissensbank_ki.gleich(t("1 0 1 1 0 1 0 0 1 1 0 1"), t("1 0 1 1 0 1 0 0 1 1 0 1")), "Zahlenreihen sind keine Stelle"
    assert (wissensbank_ki.MERKEN_GLEICH, wissensbank_ki.MERKEN_ABWAHL, wissensbank_ki.MERKEN_CREDITS) == (0.8, 2, 1)


def test_freigabe_mode_serves_only_after_the_owner_released_it(ki, monkeypatch):
    from app import wissensbank_pruefen
    monkeypatch.setenv("LERNAPP_WISSENSBANK_MERKEN", "freigabe")
    app, spy = ki
    _u, h1 = user(app, "frei1@beispiel.de", plan="pro_ai")
    frage(app, h1)
    _u, h2 = user(app, "frei2@beispiel.de", plan="pro_ai")
    st, d = frage(app, h2)
    assert d["source"] == "ki" and spy.calls == 2 and len(gemerkt_rows()) == 1, "wartet auf die Freigabe, kein zweiter Eintrag"

    def tool(*argv):
        import io
        out = io.StringIO()
        return wissensbank_pruefen.main(list(argv), out=out), out.getvalue()

    code, text = tool("--gemerkt")
    assert code == 0 and "#1  ungeprüft" in text and "fachwerkefolien07 · Seite 12 · explain" in text and "KI-ANTWORT-1" in text
    assert "Betriebsart LERNAPP_WISSENSBANK_MERKEN: freigabe" in text
    code, text = tool("--gemerkt-zeigen", "1")
    assert code == 0 and "--- Ausschnitt (normalisiert) ---" in text and "knotenpunktverfahren" in text and "KI-ANTWORT-1" in text
    assert tool("--gemerkt-zeigen", "99")[0] == 1
    assert tool("--gemerkt-freigeben", "1") == (0, "Gemerkte Antwort #1: geprüft.\n")
    _u, h3 = user(app, "frei3@beispiel.de", plan="pro_ai")
    st, d = frage(app, h3)
    assert d["source"] == "gemerkt" and d["answer"] == "KI-ANTWORT-1" and spy.calls == 2
    # abgelehnt: nie mehr ausliefern; die naechste KI-Antwort wird neu gemerkt (und wartet wieder)
    assert tool("--gemerkt-ablehnen", "1")[0] == 0 and "Keine gemerkten" in tool("--gemerkt")[1]
    _u, h4 = user(app, "frei4@beispiel.de", plan="pro_ai")
    assert frage(app, h4)[1]["source"] == "ki" and [r["status"] for r in gemerkt_rows()] == ["abgelehnt", "ungeprueft"]


def test_merken_only_for_accounts_with_the_wissensbank_and_never_before_the_library(ki, monkeypatch):
    monkeypatch.setenv("LERNAPP_WISSENSBANK_MERKEN", "sofort")
    monkeypatch.setenv("LERNAPP_WISSENSBANK_KONTEXT", "1")
    app, spy = ki
    _u, h_hi = user(app, "merken-hi@beispiel.de", plan="pro_ai", uni="hildesheim")
    assert frage(app, h_hi)[1]["source"] == "ki" and gemerkt_rows() == []
    u, h = user(app, "merken-luh@beispiel.de", plan="pro_ai")
    # eine Stelle der Bibliothek hat Vorrang; sie wird nicht "gemerkt"
    st, d = frage(app, h, text=S2, datei=FOLIEN, kurs="", seite=2)
    assert d["source"] == "wissensbank" and d["wissensbank_key"] == K_S2 and gemerkt_rows() == []
    # eine KI-Antwort mit Auszuegen aus der Wissensbank wird gemerkt und so gekennzeichnet
    st, d = frage(app, h, mode="steps", text=A4_NR9, datei=BLATT, seite=2)
    assert d["source"] == "ki" and d["wissensbank_kontext"] is True
    rows = gemerkt_rows()
    assert len(rows) == 1 and rows[0]["kontext"] == 1 and rows[0]["mode"] == "steps" and rows[0]["labels"] == "9"
    _u, h2 = user(app, "merken-luh2@beispiel.de", plan="pro_ai")
    calls = spy.calls
    st, d = frage(app, h2, mode="steps", text=A4_NR9, datei=BLATT, seite=2)
    assert d["source"] == "gemerkt" and "wissensbank_kontext" not in d and spy.calls == calls
    # Konto loeschen: die "geliefert"-Zeilen des Kontos gehen, die gemerkte Antwort (ohne Konto) bleibt
    from app import accounts, wissensbank
    assert "wissensbank_gemerkt" not in accounts.ACCOUNT_TABLES and "wissensbank_delivered" in accounts.ACCOUNT_TABLES
    conn = wissensbank.connect()
    try:
        assert conn.execute("SELECT wb_key, served FROM wissensbank_delivered WHERE wb_key LIKE 'gemerkt:%'").fetchall() == [("gemerkt:1", "gemerkt")]
    finally:
        conn.close()

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
A3 = _quote(G2, "[Q1] Aufgabe 3")
ALGO2 = _quote(A1, "[Q1] Seite 2")
ALGO3 = _quote(A1, "[Q1] Seite 3")

K_S2 = f"explain:{STATIK}/G0001/01#Q1-Seite-2"
K_S3 = f"explain:{STATIK}/G0001/01#Q1-Seite-3"
K_1AB = f"steps:{STATIK}/G0002/02#Q1-Aufgabe-1-a+02#Q1-Aufgabe-1-b"
K_1A = f"steps:{STATIK}/G0002/02#Q1-Aufgabe-1-a"
K_2 = f"steps:{STATIK}/G0002/02#Q1-Aufgabe-2"
K_3 = f"steps:{STATIK}/G0002/02#Q1-Aufgabe-3"
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
    ("Aufgabe 3 (nur Abgleich: zugeordnet, aber nicht lieferbar)", "steps", BLATT, "", 2, A3, K_3),
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


# ================================================================== Abgleich-Notizen (Entscheidung des Inhabers 21.11.2026)
# Keine Musterloesungen der Lehrenden herausgeben: die internen Abgleich-Notizen der Bibliothek (Vergleich der eigenen
# Loesung mit der Loesung der Lehrenden) stehen nie im ausgelieferten Text. Alle Texte hier sind erfunden.

def test_abgleich_paragraph_and_subsection_are_not_delivered_solution_and_explanation_stay(lib):
    from app import wissensbank
    hit = wissensbank.match(lib, mode="steps", datei=BLATT, seite=1, text="Gruppenübung 3\n" + A1A + "\n" + A1B)
    assert hit.key == K_1AB, "Zuordnung unveraendert"
    text = wissensbank.answer_text(hit.unit, hit.sections)
    for kept in ("Aufgabentext", "LOESUNG-1A", "ERKLAERUNG-1A", "LOESUNG-1B", "MERKSATZ-1B", "### Merksatz"):
        assert kept in text, kept
    for gone in ("ABGLEICH", "Abgleich", "Musterlösung", "Lösungsfolie", "gleiche Zahl, gleiche Stelle"):
        assert gone not in text, gone
    assert "in der Trägermitte. □\n" in text, "der Satz vor der Notiz bleibt ganz"
    # der ganze Abschnitt bleibt lesbar (Hinweise, Pruef-Werkzeug); er wird nie ausgeliefert
    raw = wissensbank.answer_text(hit.unit, hit.sections, raw=True)
    assert "ABGLEICH-1A" in raw and "ABGLEICH-1B" in raw and "ABGLEICH-1B-KURZ" in raw


def test_section_with_nothing_but_the_abgleich_is_not_deliverable(lib):
    from app import wissensbank
    hit = wissensbank.match(lib, mode="steps", datei=BLATT, seite=2, text=A3)
    assert hit is not None and hit.key == K_3, "die Zuordnung liest weiter den ganzen Abschnitt"
    assert wissensbank.answer_text(hit.unit, hit.sections) == "", "nur der Aufgabentext waere uebrig: nichts Eigenes"
    assert "ABGLEICH-3" in wissensbank.answer_text(hit.unit, hit.sections, raw=True)


ABGLEICH_FORMS = [
    ("fett, eigener Absatz", "**Lösung.** L1.\n\n**Abgleich mit der Musterlösung.** WEG eins\nWEG zwei\n\n**Erklärung.** E1.",
     "**Lösung.** L1.\n\n**Erklärung.** E1."),
    ("fett mit Doppelpunkt", "**Lösung.** L1.\n\n**Abgleich:** WEG.\n\nE1 bleibt.", "**Lösung.** L1.\n\nE1 bleibt."),
    ("kursiv", "L1.\n\n*Abgleich (Q2, Seite 9).* WEG.\n\nE1.", "L1.\n\nE1."),
    ("ohne Auszeichnung am Absatzanfang", "L1.\n\nAbgleich zu G0001 Q1: WEG.\n\nE1.", "L1.\n\nE1."),
    ("Notiz, direkt danach die Loesung", "**Abgleich.** wie G0001 Aufgabe 3, WEG.\n**Lösung (nachgerechnet).** L1 = 5 kN.",
     "**Lösung (nachgerechnet).** L1 = 5 kN."),
    ("Notiz und naechste Marke in einer Zeile", "**Abgleich.** WEG. **Kernergebnis.** K1 = 3.", "**Kernergebnis.** K1 = 3."),
    ("mitten im Absatz, fett", "**Lösung.** L1 = **5 kN**. **Abgleich mit der ML.** WEG eins\nWEG zwei", "**Lösung.** L1 = **5 kN**."),
    ("am Satzende, ohne Auszeichnung", "**Lösung.** L1 = **5 kN**. Abgleich: gleich WEG. □\n\nE1.", "**Lösung.** L1 = **5 kN**.\n\nE1."),
    ("kursiv mitten im Absatz, danach wieder Eigenes", "*Aufgabe.* A1. *Abgleich:* WEG, WEG. *Lösung.* L1.", "*Aufgabe.* A1. *Lösung.* L1."),
    ("fettes Ergebnis in der Notiz ist keine neue Marke", "**Abgleich.** WEG **F = 3 kN**. WEG **[sic]** WEG.\n\nE1.", "E1."),
    ("Listenpunkt", "- P1\n- **Abgleich mit der Musterlösung:** WEG\n  WEG weiter\n  - WEG Unterpunkt\n- P2", "- P1\n- P2"),
    ("Notiz mit ihrer Liste", "**Abgleich.** WEG:\n- WEG a\n- WEG b\n\n- P1 bleibt", "- P1 bleibt"),
    ("Zitat", "> Vorlage V1\n\nL1.\n\n> **Abgleich.** WEG", "> Vorlage V1\n\nL1."),
    ("Unterueberschrift bis zur naechsten gleicher Ebene",
     "L1.\n\n### Abgleich mit der Musterlösung\n\nWEG\n\n#### WEG tiefer\n\nWEG\n\n### Probe\n\nP1.", "L1.\n\n### Probe\n\nP1."),
    ("Unterueberschrift vierter Ebene", "### Lösung\n\nL1.\n\n#### Abgleich\n\nWEG\n\n### Probe\n\nP1.", "### Lösung\n\nL1.\n\n### Probe\n\nP1."),
    ("Wort im Fliesstext bleibt", "Der Abgleich der Einheiten zeigt: m/s. Siehe Abgleichstabelle; Abgleichsvermerk: ok.",
     "Der Abgleich der Einheiten zeigt: m/s. Siehe Abgleichstabelle; Abgleichsvermerk: ok."),
    ("andere Marke mit dem Wort bleibt", "**Nachrechnung/Abgleich.** Stimmt, mit sympy geprüft.", "**Nachrechnung/Abgleich.** Stimmt, mit sympy geprüft."),
    ("Code-Block bleibt", "L1.\n\n```python\n# Abgleich der Werte\n**Abgleich** = 1\n```", "L1.\n\n```python\n# Abgleich der Werte\n**Abgleich** = 1\n```"),
    ("Tabelle bleibt", "| Größe | Abgleich |\n| --- | --- |\n| F | **Abgleich** ok |", "| Größe | Abgleich |\n| --- | --- |\n| F | **Abgleich** ok |"),
    ("ohne Notiz bleibt alles", "> Vorlage V1\n\n\n\n**Lösung.** L1.", "> Vorlage V1\n\n**Lösung.** L1."),
    ("nur die Vorlage uebrig (Zitat)", "> Vorlage V1\n\n**Abgleich mit der Musterlösung.** WEG", ""),
    ("nur der Aufgabentext uebrig", "**Aufgabentext.** Berechnen Sie x.\n\n**Abgleich.** WEG\n\n---", ""),
    ("Aufgabentext und Loesung in einem Absatz", "**Aufgabentext.** Berechnen Sie x. **Lösung.** x = 2.\n\n**Abgleich.** WEG",
     "**Aufgabentext.** Berechnen Sie x. **Lösung.** x = 2."),
    ("nur die Notiz", "**Abgleich: identisch mit G0042 Aufgabe 5 → Erklärung dort.** WEG", ""),
]


@pytest.mark.parametrize("case", ABGLEICH_FORMS, ids=[c[0] for c in ABGLEICH_FORMS])
def test_without_abgleich_forms(case):
    from app import wissensbank
    _name, body, want = case
    got = wissensbank.without_abgleich(body)
    assert got == want
    assert "WEG" not in got


def test_heading_of_the_next_part_does_not_belong_to_the_section():
    """`# [Q2] ...` leitet den naechsten Teil der Datei ein; der Abschnitt davor endet dort (Code-Bloecke ausgenommen)."""
    from app import wissensbank
    body = "L1.\n\n```python\n# Kommentar bleibt\n```\n\n# [Q2] Lösungen der Lehrenden: Abgleich\n\nEinleitung zum naechsten Teil.\n"
    assert wissensbank._own_part(body) == "L1.\n\n```python\n# Kommentar bleibt\n```\n"


# ================================================================== Text aus echten PDFs (Messung 21.11.2026)
# Gemessen mit Text, wie die App ihn schickt (PDFKit-Seitentext, Vision-Text eingekreister Ausschnitte): Der Wortlaut
# allein traf selten. Die Regeln dazu stehen in app/wissensbank.py; hier je Regel ein Treffer und die Gegenproben.
# Vorgabe des Inhabers: lieber kein Treffer als eine falsche Loesung. Alle Texte sind erfunden.

K_S5 = f"explain:{STATIK}/G0001/01#Q1-Seite-5"
K_4 = f"steps:{STATIK}/G0002/02#Q1-Aufgabe-4"
K_4_VORJAHR = f"steps:{STATIK}/G0003/02#Q1-Aufgabe-4"
K_5 = f"steps:{STATIK}/G0002/02#Q1-Aufgabe-5"
K_6 = f"steps:{STATIK}/G0002/02#Q1-Aufgabe-6"
K_7 = f"steps:{STATIK}/G0002/02#Q1-Aufgabe-7"
KURS_STATIK = "Beispiel-Statik für Testzwecke (WiSe 2026/27)"
# Seite 5 der Folien, wie die Textebene sie liefert: Stichworte einer Tabelle, kein Satz der Erklaerung
S5 = ("Lagerarten und ihre Wertigkeit\nLoslager einwertig\nFestlager zweiwertig\nfeste Einspannung dreiwertig\n"
      "Wertigkeit = Zahl der unbekannten Lagerreaktionen\nBeispiel-Statik für Testzwecke 5")
# Aufgabe 4 des Blatts: die Bibliothek hat dazu nur die Loesung, keinen Aufgabentext
A4 = ("Aufgabe 4 (6 Punkte)\nEin Dreigelenkbogen hat die Punkte A = (4, 0, 7), B = (9, 3, 8) und C = (6, 5, 2) (Angaben in "
      "Metern).\nIm Punkt C greift die Last F = 18 kN an. Bestimmen Sie den Hebelarm der Last um den Punkt A\nund mit dem "
      "Momentengleichgewicht die Auflagerkraft im Punkt B.")
A4_VORJAHR = A4.replace("(4, 0, 7)", "(2, 0, 5)").replace("(9, 3, 8)", "(7, 1, 6)").replace("(6, 5, 2)", "(8, 3, 4)").replace("18 kN", "24 kN")
A5 = ("Ein Kran hält eine Kiste der Masse 250 kg an einem Seil der Länge 7 m. Das Seil ist um 20 Grad gegen die Senkrechte "
      "geneigt, weil eine waagrechte Windkraft auf die Kiste wirkt. Berechnen Sie die Seilkraft und die Windkraft.")
KURZ = "Skizzieren Sie den Verlauf des Biegemoments über die ganze Länge. Ist das Tragwerk statisch bestimmt?"
S2_HALB = " ".join(S2.split()[:34])                  # eingekreister Teil der Folie Seite 2 (etwa die Haelfte)
ALGO_TEIL = " ".join(ALGO2.split()[:26])             # steht auf Seite 2 und auf der Aufbaustufe Seite 3


def key(lib, **kw):
    from app import wissensbank
    hit = wissensbank.match(lib, **kw)
    return hit.key if hit else None


def test_split_umlauts_of_pdf_text_layers_are_joined():
    """LaTeX-PDFs liefern in der Textebene das Trema getrennt vor dem Buchstaben (PDFKit: "f¨ ur", auch ueber den
    Zeilenumbruch), andere Programme dahinter; Klammerteile aus Formelschriften liegen im Privatbereich."""
    from app import wissensbank
    assert wissensbank.tokens("Fakult¨ at f¨ ur Bauwesen\n¨\nUbungsblatt 3") == ["fakultät", "für", "bauwesen", "übungsblatt", "3"]
    assert wissensbank.tokens("Tr¨ager, gr¨oßer, f ̈ur, fu¨r, Träger") == ["träger", "grösser", "für", "für", "träger"]
    assert wissensbank.tokens("x = \uf8eb 4\n7 \uf8f6 ﬁnden") == ["x", "=", "4", "7", "finden"]
    assert wissensbank.tokens("Lager-\nreaktionen") == ["lagerreaktionen"]


def test_whole_page_with_split_umlauts_matches_like_the_clean_text(lib):
    kaputt = S3.replace("ä", "¨ a").replace("ö", "¨ o").replace("ü", "¨ u").replace("ß", "ß")
    assert kaputt != S3 and key(lib, mode="explain", datei=FOLIEN, seite=3, text=kaputt) == K_S3


def test_circled_part_of_a_slide_needs_containment_not_similarity(lib):
    """"Bereich an KI": nur ein Teil der Folie. Ohne Kennzeichen gilt die Aehnlichkeit zur ganzen Folie (kein Treffer),
    als Ausschnitt das Enthaltensein."""
    umbenannt = dict(mode="explain", datei="Statik_Folien_neu_v2.pdf", kurs=KURS_STATIK, seite=2, text=S2_HALB)
    assert key(lib, **umbenannt) is None
    assert key(lib, **umbenannt, ausschnitt=True) == K_S2
    # ein Ausschnitt mit fremdem Text dazwischen ist nicht mehr "enthalten"
    fremd = S2_HALB + " Die Photosynthese wandelt Lichtenergie in chemische Energie um und findet in den Chloroplasten statt."
    assert key(lib, **{**umbenannt, "text": fremd}, ausschnitt=True) is None
    # anderer Kurs: kein Treffer
    assert key(lib, **{**umbenannt, "kurs": "Einführung in die Chemie"}, ausschnitt=True) is None


def test_ambiguous_part_only_with_the_sent_page(lib):
    """Derselbe Ausschnitt steht auf zwei Folien (Aufbaustufe): Es zaehlt die mitgeschickte PDF-Seite - und nur bei
    bekanntem Dateititel. Sonst kein Treffer."""
    datei = "algo-skript-bsp.pdf"
    assert key(lib, mode="explain", datei=datei, seite=2, text=ALGO_TEIL, ausschnitt=True) == K_ALGO2
    assert key(lib, mode="explain", datei=datei, seite=3, text=ALGO_TEIL, ausschnitt=True) == K_ALGO3
    assert key(lib, mode="explain", datei=datei, seite=9, text=ALGO_TEIL, ausschnitt=True) is None
    assert key(lib, mode="explain", datei="skript-umbenannt.pdf", kurs="Beispiel-Algorithmen", seite=2, text=ALGO_TEIL,
               ausschnitt=True) is None, "Titel unbekannt: die Seitennummer einer anderen Datei sagt nichts"


def test_number_rows_alone_never_match_as_a_part(lib):
    """Eine reine Zahlenreihe (Tabelle, Wahrheitstafel) belegt keine Folie, auch wenn die Zahlen dort stehen."""
    zahlen = "5, 2, 4, 6, 1, 3\n1, 2, 3, 4, 5, 6"
    assert key(lib, mode="explain", datei="algo-skript-bsp.pdf", seite=3, text=zahlen, ausschnitt=True) is None
    assert key(lib, mode="explain", datei="algo-skript-bsp.pdf", seite=3, text=zahlen) is None
    # fast nur Zahlen, woertlich von Seite 3: unter MIN_BEGRIFFE Begriffen belegt ein Text keine Stelle
    zeile = "Das Feld 5, 2, 4, 6, 1, 3 wird nach sechs Durchläufen zu 1, 2, 3, 4, 5, 6"
    assert zeile in " ".join(ALGO3.split())
    assert key(lib, mode="explain", datei="algo-skript-bsp.pdf", seite=3, text=zeile, ausschnitt=True) is None


def test_two_header_lines_are_not_a_part_of_a_slide(lib):
    """Kopfzeile oder Titel (wenige Woerter) stehen aehnlich auf vielen Folien: Ein Ausschnitt braucht mindestens
    AUSSCHNITT_GEMEINSAM gemeinsame Wortfolgen mit dem Folientext."""
    kopf = " ".join(S3.split()[:11])
    lang = " ".join(S3.split()[:22])
    args = dict(mode="explain", datei="Statik_Folien_neu_v2.pdf", kurs=KURS_STATIK, seite=3, ausschnitt=True)
    assert key(lib, **args, text=kopf) is None
    assert key(lib, **args, text=lang) == K_S3
    # auch wenn die Bibliothek zur Seite keinen markierten Folientext hat (Vergleich mit dem ganzen Abschnitt)
    satz = "Das Loslager überträgt nur eine Kraft senkrecht zur Unterlage und ist einwertig."
    assert key(lib, **{**args, "seite": 5}, text=satz) is None


def test_task_without_numbers_needs_the_file_title(lib):
    """Dateititel unbekannt, nur der Kurs passt: Eine Aufgabe ohne Zahlen im Text kann jedes Jahr eine andere sein (die
    Angaben stehen dann im Bild). Mit bekanntem Dateititel trifft derselbe Text."""
    aufgabe = "Aufgabe 7\n" + KURZ
    assert {s.sid: s.explicit for s in lib.unit(STATIK, "G0002").sections}["02#Q1-Aufgabe-7"] is True
    assert key(lib, mode="steps", datei=BLATT, seite=2, text=aufgabe) == K_7
    assert key(lib, mode="steps", datei="Blatt_neu.pdf", kurs=KURS_STATIK, seite=2, text=aufgabe) is None


def test_slide_without_slide_text_by_title_page_and_terms(lib):
    """Die Bibliothek hat zu Seite 5 nur die Erklaerung. Treffer nur mit bekanntem Dateititel, genau dieser Seitennummer
    und den Begriffen der Seite - und nur, wenn keine andere Seite annaehernd so gut passt."""
    assert key(lib, mode="explain", datei=FOLIEN, seite=5, text=S5) == K_S5
    assert key(lib, mode="explain", datei=FOLIEN, seite=5, text=S5.replace("ä", "¨ a")) == K_S5
    assert key(lib, mode="explain", datei=FOLIEN, seite=1, text=S5) is None, "andere Seite"
    assert key(lib, mode="explain", datei=FOLIEN, seite=6, text=S5) is None, "Seite gibt es in der Bibliothek nicht"
    assert key(lib, mode="explain", datei="Statik_Folien_neu_v2.pdf", kurs=KURS_STATIK, seite=5, text=S5) is None, "Titel unbekannt"
    assert key(lib, mode="steps", datei=FOLIEN, seite=5, text=S5) is None, "Folie im Modus Loesen"
    anderes = ("Werkstoffe im Bauwesen\nBeton druckfest\nStahl zugfest\nHolz leicht\nKennwerte = Festigkeit und "
               "Steifigkeit der Baustoffe\nBeispiel-Statik für Testzwecke 5")
    assert key(lib, mode="explain", datei=FOLIEN, seite=5, text=anderes) is None, "anderer Inhalt auf Seite 5 (neue Fassung)"
    # eine Seite mit Aufgaben geht nie ueber diesen Weg (Blaetter gleichen sich im Wortlaut, nur die Zahlen aendern sich)
    assert key(lib, mode="explain", datei=FOLIEN, seite=5, text="Aufgabe 2 (4 Punkte)\n" + S5) is None
    # nur knapp die Haelfte der Begriffe der Seite steht im Abschnitt (Seite wurde stark erweitert): kein Treffer
    assert key(lib, mode="explain", datei=FOLIEN, seite=5, text=S5 + "\n" + anderes.replace("Beispiel-Statik für Testzwecke 5", "")) is None


def test_evidence_thresholds():
    from app import wissensbank
    assert (wissensbank.NACHWEIS_ANTEIL, wissensbank.NACHWEIS_BEGRIFFE, wissensbank.NACHWEIS_ABSTAND) == (0.6, 6, 0.15)
    assert wissensbank._accept(0.8, 9, 0.5)
    assert not wissensbank._accept(0.8, 9, 0.7), "eine andere Stelle passt fast so gut: kein Treffer"
    assert not wissensbank._accept(0.55, 9, 0.0) and not wissensbank._accept(0.9, 5, 0.0)
    assert (wissensbank.SCHWELLE_AUSSCHNITT, wissensbank.AUSSCHNITT_GEMEINSAM, wissensbank.MIN_BEGRIFFE, wissensbank.KURZ_AUFGABE) == (0.7, 12, 5, 25)
    assert (wissensbank.NACHWEIS_ZAHLEN, wissensbank.NACHWEIS_ZAHLEN_BITS) == (0.6, 14.0)


def test_task_without_task_text_by_title_number_terms_and_numbers(lib):
    """Die Bibliothek hat zu Aufgabe 4 nur die Loesung. Treffer nur mit Dateititel, Aufgabennummer, den Begriffen und den
    Zahlen der Aufgabe in ihrer Reihenfolge."""
    assert key(lib, mode="steps", datei=BLATT, seite=2, text=A4) == K_4
    assert key(lib, mode="explain", datei=BLATT, seite=2, text=A4) == K_4.replace("steps:", "explain:")
    from app import wissensbank
    hit = wissensbank.match(lib, mode="steps", datei=BLATT, seite=2, text=A4)
    assert "LOESUNG-4:" in wissensbank.answer_text(hit.unit, hit.sections)


def test_same_file_name_in_two_semesters_numbers_decide(lib):
    """Sorge des Inhabers: gleicher Dateiname, gleiche Aufgabe, andere Zahlen. Die Zahlen waehlen das Semester; passen
    sie zu keinem, gibt es keinen Treffer."""
    assert key(lib, mode="steps", datei=BLATT, seite=2, text=A4_VORJAHR) == K_4_VORJAHR
    neu = A4.replace("(4, 0, 7)", "(1, 0, 3)").replace("(9, 3, 8)", "(5, 2, 9)").replace("(6, 5, 2)", "(7, 4, 1)").replace("18 kN", "30 kN")
    assert key(lib, mode="steps", datei=BLATT, seite=2, text=neu) is None, "neues Semester, neue Zahlen"
    assert key(lib, mode="steps", datei=BLATT, seite=2, text=A4.replace("18 kN", "19 kN")) is None, "eine Zahl anders"
    assert key(lib, mode="steps", datei=BLATT, seite=2, text=A4.replace("(9, 3, 8)", "(9, 8, 3)")) is None, "Zahlen vertauscht"


def test_task_route_needs_readable_numbers_the_right_number_and_the_title(lib):
    # Texterkennung hat die Zahlen nicht gelesen: kein Treffer (gleiche Aufgabe eines anderen Jahres saehe genauso aus)
    ohne = re.sub(r"\(\d, \d, \d\)", "", A4).replace("18 kN", "")
    assert "7" not in ohne.split("Punkte)")[1] and key(lib, mode="steps", datei=BLATT, seite=2, text=ohne) is None
    # die Aufgabe steht unter einer anderen Nummer (verschoben) oder ohne Ueberschrift
    assert key(lib, mode="steps", datei=BLATT, seite=2, text=A4.replace("Aufgabe 4", "Aufgabe 2")) is None
    assert key(lib, mode="steps", datei=BLATT, seite=2, text=A4.replace("Aufgabe 4 (6 Punkte)\n", "")) is None
    # anderer Dateititel, auch mit passendem Kurs
    assert key(lib, mode="steps", datei="Blatt_neu.pdf", kurs=KURS_STATIK, seite=2, text=A4) is None
    # andere Aufgabe unter der Nummer 4
    andere = ("Aufgabe 4 (6 Punkte)\nEin Fachwerk mit den Knoten A = (4, 0, 7), B = (9, 3, 8) und C = (6, 5, 2) trägt im Knoten C "
              "eine Kraft von 18 kN. Bestimmen Sie die Stabkräfte mit dem Knotenpunktverfahren und nennen Sie die Nullstäbe.")
    assert key(lib, mode="steps", datei=BLATT, seite=2, text=andere) is None


def test_number_evidence_weighs_digits():
    from array import array

    from app import wissensbank
    seq = array("I", [hash(t) & 0xFFFFFFFF for t in "4 2 4 0 7 9 3 8 6 5 2 18 3 54".split()])
    assert wissensbank.number_block("4 0 7 9 3 8 6 5 2 18".split(), seq)[0] == pytest.approx(31.6)
    assert wissensbank.number_block("9 3 8 4 0 7".split(), seq)[0] == pytest.approx(9.0), "nur am Stueck"
    assert wissensbank.number_bits("0") == 1.0 and wissensbank.number_bits("7") == 3.0 and wissensbank.number_bits("13.5") == pytest.approx(9.9)
    words, nums, stream = wissensbank.terms(wissensbank.tokens("Aufgabe 4 (1+2 Punkte) am 02.11.2026: F = 18 kN, l = 4 m, Intervallen"), skip="4")
    assert stream == ["18", "4"] and nums == {"18"} and "interv" in words


def test_plain_aufgabentext_label_counts_as_task_text(lib):
    """"Aufgabentext: ..." ohne Fettdruck (so steht es in vielen Einheiten) ist der Aufgabentext der Bibliothek: dann gilt
    der strenge Wortlaut-Vergleich mit allen Zahlen."""
    unit = lib.unit(STATIK, "G0002")
    assert {s.sid: s.explicit for s in unit.sections}["02#Q1-Aufgabe-5"] is True
    assert key(lib, mode="steps", datei=BLATT, seite=2, text=A5) == K_5
    assert key(lib, mode="steps", datei=BLATT, seite=2, text=A5.replace("250 kg", "300 kg")) is None
    assert key(lib, mode="steps", datei="Blatt_neu.pdf", kurs=KURS_STATIK, seite=2, text=A5) == K_5, "Wortlaut traegt auch ueber den Kurs"


def test_short_generic_task_text_only_with_its_number(lib):
    """Derselbe kurze Satz steht in Aufgabe 6 und 7 mit verschiedenen Loesungen (gemessen an einer Aufgabensammlung).
    Ohne die Nummer im angefragten Text gibt es keinen Treffer."""
    assert key(lib, mode="steps", datei=BLATT, seite=2, text=KURZ) is None
    assert key(lib, mode="steps", datei=BLATT, seite=2, text="Aufgabe 7\n" + KURZ) == K_7
    assert key(lib, mode="steps", datei=BLATT, seite=2, text="Aufgabe 6\n" + KURZ) == K_6
    assert key(lib, mode="steps", datei=BLATT, seite=2, text="Aufgabe 9\n" + KURZ) is None
    # ein langer, eindeutiger Aufgabentext braucht die Nummer nicht (Aufgabe unter neuer Nummer, gleicher Inhalt)
    assert key(lib, mode="steps", datei=BLATT, seite=1, text="Aufgabe 9\n" + A1A) == K_1A


def test_other_date_means_other_version():
    from app import wissensbank
    assert wissensbank.dates_of(wissensbank.normalize("Version vom 2026-10-13, Blatt vom 4. 11. 2024")) == {"2026-10-13", "4.11.2024"}


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


def test_delivered_answer_has_no_abgleich_but_keeps_the_hints_of_the_section(wb):
    app, fake = wb
    u, h = user(app, "luh-abgleich@beispiel.de", plan="pro_ai")
    st, d = ask(app, h, mode="steps", text=A1A, datei=BLATT, seite=1)
    assert st == 200 and d["source"] == "wissensbank" and d["wissensbank_key"] == K_1A and fake.calls == 0
    assert "LOESUNG-1A" in d["answer"] and "ERKLAERUNG-1A" in d["answer"]
    assert "ABGLEICH" not in d["answer"] and "Abgleich" not in d["answer"] and "Musterlösung" not in d["answer"]
    # der Hinweis steht in der Bibliothek in der Abgleich-Notiz; das Abzeichen zeigt ihn weiter
    assert "nachgerechnet, nicht unabhängig gelöst" in d["wissensbank"]["hinweise"]


def test_section_without_own_solution_gets_the_normal_ai_answer(wb):
    app, fake = wb
    u, h = user(app, "luh-abgleich3@beispiel.de", plan="pro_ai")
    st, d = ask(app, h, mode="steps", text=A3, datei=BLATT, seite=2)
    assert st == 200 and fake.calls == 1 and d["source"] == "ki", "nur die Notiz zur Musterloesung: nichts zu liefern"
    assert "wissensbank_key" not in d and "feedback_token" not in d and "ABGLEICH" not in d["answer"]
    assert ledger(u["id"])[0][0] != "tutor:wissensbank"


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
    # zweite Meinung: nie aus der Wissensbank
    _, d = ask(app, h, second_opinion=True)
    assert d["source"] == "ki"
    monkeypatch.setenv("LERNAPP_WISSENSBANK", "0")
    _, d = ask(app, h)
    assert "source" not in d and "wissensbank_key" not in d, "Schalter aus: Antwort wie bisher"
    assert "wissensbank" not in _j(asgi_call(app, "GET", "/api/entitlements", headers=h))[1]


def test_circled_area_with_image_is_answered_from_the_wissensbank_when_its_text_matches(wb):
    """Meldung des Inhabers 21.11.2026 (iPad, eingekreiste Aufgabe = "Bereich an KI", Bild + erkannter Text): Es kam die
    KI, weil eine Anfrage mit Bild die Wissensbank nie fragte. Jetzt zaehlt der erkannte Text des Ausschnitts: passt er,
    kommt die Antwort aus der Wissensbank (1 Credit, die KI wird nicht gerufen); passt er nicht, antwortet die KI mit
    dem Bild wie bisher."""
    import base64
    app, fake = wb
    jpeg = base64.b64encode(b"\xff\xd8\xff\xe0" + b"\x00" * 64).decode()
    u, h = user(app, "luh-bild@beispiel.de", plan="pro_ai")
    st, d = ask(app, h, image=jpeg)
    assert st == 200 and d["source"] == "wissensbank", d
    assert fake.calls == 0, "Treffer: die KI wird nicht gerufen"
    assert [r[0] for r in ledger(u["id"])] == ["tutor:wissensbank"]
    st, d = ask(app, h, image=jpeg, text="Ein ganz anderer Ausschnitt ohne Bezug zur Bibliothek, nur eine Skizze mit Beschriftung.")
    assert st == 200 and d["source"] == "ki" and fake.calls == 1, "kein Treffer: KI mit Bild wie bisher"


def test_circled_part_of_a_slide_is_recognised_by_the_image(wb):
    """Der Dienst erkennt den Ausschnitt am Bild (oder am Feld `ausschnitt`): Ein eingekreister Teil einer Folie trifft
    dann ueber das Enthaltensein; derselbe Text ohne Bild gilt als ganze Seite und trifft nicht."""
    import base64
    app, fake = wb
    jpeg = base64.b64encode(b"\xff\xd8\xff\xe0" + b"\x00" * 64).decode()
    u, h = user(app, "luh-ausschnitt@beispiel.de", plan="pro_ai")

    def frage(**extra):
        wbody = {"datei": "Statik_Folien_neu_v2.pdf", "kurs": KURS_STATIK, "seite": 2, "text": S2_HALB, **extra.pop("wb", {})}
        body = {"task": "tutor:explain", "prompt": "SEITENTEXT:\n" + S2_HALB, "request_id": uuid.uuid4().hex, "wissensbank": wbody, **extra}
        return _j(asgi_call(app, "POST", "/api/ai/relay", headers=h, body=json.dumps(body)))

    st, d = frage()
    assert st == 200 and d["source"] == "ki" and fake.calls == 1, "ohne Bild: ganze Seite, kein Treffer"
    st, d = frage(image=jpeg)
    assert st == 200 and d["source"] == "wissensbank" and d["wissensbank_key"] == K_S2 and fake.calls == 1
    assert "ERKLAERUNG-SEITE-2" in d["answer"]
    u2, h2 = user(app, "luh-ausschnitt2@beispiel.de", plan="pro_ai")
    h = h2
    st, d = frage(wb={"ausschnitt": True})
    assert st == 200 and d["source"] == "wissensbank", "Feld der App (auch fuer markierten Text ohne Bild)"
    u3, h3 = user(app, "luh-ausschnitt3@beispiel.de", plan="pro_ai")
    h = h3
    st, d = frage(image=jpeg, wb={"ausschnitt": False})
    assert st == 200 and d["source"] == "ki", "das Feld geht vor"


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
    assert sum(len(f["einheiten"]) for f in kat["faecher"]) == 4


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

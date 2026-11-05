"""Aufgaben fuer tools/ki-vergleich.py (docs/KI-VERGLEICH-2026-11-05.md).

Nur erfundene Aufgaben, oeffentliches Lehrbuchwissen und der Demo-Inhalt der App ("Demo: Grundlagen der Informatik",
app/demo.py, gleich UniFlowCore DemoContent). Keine Daten von Studierenden, nichts Persoenliches: Diese Texte gehen auch an
DeepSeek (Server in China).

Jede Aufgabe: id, kind (explain | steps | flashcards | week_test | grade | doc), subject, die Eingaben fuer den
Prompt-Baustein der App und `expect` fuer die automatische Vorpruefung.
"""
from __future__ import annotations

# ---------------------------------------------------------------- Demo-Inhalt der App (app/demo.py FILES)


def demo_pages(demo_files: list[dict], file_id: str) -> list[str]:
    f = next(x for x in demo_files if x["id"] == file_id)
    return [title + "\n" + "\n".join(lines) for title, lines in f["pages"]]


def demo_name(demo_files: list[dict], file_id: str) -> str:
    return next(x for x in demo_files if x["id"] == file_id)["name"]


# ---------------------------------------------------------------- 10-seitige Dokumente (erfunden, Lehrbuchwissen)

DOC_SORTIEREN = [
    "Algorithmen und Datenstrukturen – Vorlesung 6: Sortieren\nLernziele: Sortierproblem formal angeben, einfache und "
    "effiziente Sortierverfahren kennen, Laufzeiten im besten, mittleren und schlechtesten Fall bestimmen, Stabilität und "
    "In-place-Eigenschaft beurteilen.",
    "Das Sortierproblem\nEingabe: Folge a1, ..., an von Schlüsseln mit einer totalen Ordnung. Ausgabe: Permutation mit "
    "a'1 <= a'2 <= ... <= a'n. Ein Verfahren heißt stabil, wenn gleiche Schlüssel ihre Reihenfolge behalten. In-place: "
    "nur O(1) zusätzlicher Speicher.",
    "Insertion Sort\nIdee: Der vordere Teil ist sortiert; das nächste Element wird von rechts nach links an die richtige "
    "Stelle geschoben. Bester Fall (schon sortiert): n-1 Vergleiche, also O(n). Schlechtester Fall (umgekehrt sortiert): "
    "n(n-1)/2 Vergleiche, also O(n^2). Stabil und in-place.",
    "Selection Sort\nIdee: Suche das Minimum des unsortierten Rests und tausche es an die erste freie Stelle. Immer "
    "n(n-1)/2 Vergleiche, höchstens n-1 Vertauschungen. Laufzeit Theta(n^2) in jedem Fall. In-place, aber in der "
    "üblichen Form nicht stabil.",
    "Mergesort\nTeile und herrsche: Folge halbieren, beide Hälften rekursiv sortieren, dann mischen (merge). Rekursion "
    "T(n) = 2 T(n/2) + Theta(n), also T(n) = Theta(n log n) in jedem Fall. Stabil, braucht aber Theta(n) Zusatzspeicher "
    "für das Mischen.",
    "Mischen (merge) im Detail\nZwei sortierte Folgen L und R: Zeiger auf den Anfang beider Folgen, das kleinere Element "
    "übernehmen, Zeiger weiterschieben. Bei Gleichheit das Element aus L zuerst nehmen, damit das Verfahren stabil bleibt. "
    "Aufwand: höchstens |L| + |R| - 1 Vergleiche.",
    "Quicksort\nWähle ein Pivotelement p, teile die Folge in Elemente < p, = p und > p (Partitionierung), sortiere die "
    "Teile rekursiv. Mittlerer Fall Theta(n log n), schlechtester Fall Theta(n^2) (z. B. sortierte Eingabe mit erstem "
    "Element als Pivot). In-place möglich, nicht stabil.",
    "Pivotwahl und Randomisierung\nZufälliges Pivot oder Median-of-three machen den schlechtesten Fall unwahrscheinlich. "
    "Erwartete Vergleichszahl bei zufälligem Pivot: etwa 1,39 n log2 n. In der Praxis ist Quicksort oft am schnellsten, "
    "weil die innere Schleife einfach und cachefreundlich ist.",
    "Untere Schranke für vergleichsbasiertes Sortieren\nEntscheidungsbaum: jedes Blatt ist eine Permutation, also "
    "mindestens n! Blätter. Höhe h >= log2(n!) = Omega(n log n). Kein vergleichsbasiertes Verfahren ist im schlechtesten "
    "Fall schneller als Omega(n log n). Counting Sort umgeht die Schranke, weil es nicht vergleicht (Laufzeit O(n + k)).",
    "Zusammenfassung und Klausurhinweise\nTabelle: Insertion Sort O(n^2), stabil, in-place; Selection Sort Theta(n^2), "
    "nicht stabil; Mergesort Theta(n log n), stabil, nicht in-place; Quicksort mittel Theta(n log n), schlecht "
    "Theta(n^2). Typische Klausuraufgabe: Ein Feld von Hand mit Mergesort oder Quicksort sortieren und die Zwischenschritte "
    "angeben; Rekursionsgleichung aufstellen und lösen.",
]

DOC_KOSTENRECHNUNG = [
    "Betriebswirtschaftslehre – Kapitel 4: Kosten- und Leistungsrechnung\nLernziele: Kostenbegriffe abgrenzen, "
    "Kostenarten-, Kostenstellen- und Kostenträgerrechnung unterscheiden, Deckungsbeitrag und Break-even-Menge berechnen.",
    "Grundbegriffe\nAuszahlung, Ausgabe, Aufwand, Kosten: Kosten sind der bewertete, sachzielbezogene Güterverbrauch einer "
    "Periode. Neutraler Aufwand (z. B. Spende) ist kein Kostenbestandteil; kalkulatorische Kosten (z. B. kalkulatorischer "
    "Unternehmerlohn) stehen keinem Aufwand gegenüber.",
    "Fixe und variable Kosten\nFixkosten hängen nicht von der Ausbringungsmenge ab (Miete, Abschreibung). Variable Kosten "
    "steigen mit der Menge (Material, Akkordlohn). Gesamtkosten K(x) = Kf + kv * x. Stückkosten k(x) = Kf/x + kv sinken "
    "mit steigender Menge (Fixkostendegression).",
    "Kostenartenrechnung\nFrage: Welche Kosten sind angefallen? Gliederung nach Produktionsfaktoren: Personalkosten, "
    "Materialkosten, Abschreibungen, Zinsen, Fremdleistungen. Einzelkosten lassen sich einem Produkt direkt zurechnen, "
    "Gemeinkosten nur über Schlüssel.",
    "Kostenstellenrechnung\nFrage: Wo sind die Kosten angefallen? Betriebsabrechnungsbogen (BAB): Gemeinkosten werden auf "
    "Kostenstellen verteilt (Material, Fertigung, Verwaltung, Vertrieb). Aus dem BAB folgen Zuschlagssätze, z. B. "
    "Materialgemeinkostenzuschlag = Materialgemeinkosten / Materialeinzelkosten.",
    "Kostenträgerrechnung\nFrage: Wofür sind die Kosten angefallen? Zuschlagskalkulation: Materialeinzelkosten + "
    "Materialgemeinkosten + Fertigungseinzelkosten + Fertigungsgemeinkosten = Herstellkosten; plus Verwaltungs- und "
    "Vertriebsgemeinkosten = Selbstkosten.",
    "Beispiel Zuschlagskalkulation\nMaterialeinzelkosten 200 EUR, MGK-Zuschlag 10 %, Fertigungslöhne 100 EUR, FGK-Zuschlag "
    "150 %, VwGK 10 %, VtGK 5 % auf die Herstellkosten. Herstellkosten = 220 + 250 = 470 EUR, Selbstkosten = 470 * 1,15 = "
    "540,50 EUR.",
    "Deckungsbeitragsrechnung\nStückdeckungsbeitrag db = p - kv. Gesamtdeckungsbeitrag DB = db * x. Betriebsergebnis "
    "G = DB - Kf. Kurzfristig lohnt ein Zusatzauftrag, wenn sein Preis über den variablen Stückkosten liegt "
    "(positiver Deckungsbeitrag) und Kapazität frei ist.",
    "Break-even-Analyse\nGewinnschwelle: G = 0, also x_BE = Kf / (p - kv). Beispiel: Kf = 40.000 EUR, p = 25 EUR, "
    "kv = 15 EUR ergibt x_BE = 4.000 Stück. Sicherheitsabstand: (geplante Menge - x_BE) / geplante Menge.",
    "Zusammenfassung und Klausurhinweise\nKosten vs. Aufwand abgrenzen können; BAB und Zuschlagssätze rechnen; "
    "Zuschlagskalkulation bis zu den Selbstkosten; Deckungsbeitrag, Break-even-Menge und Entscheidung über Zusatzaufträge. "
    "Typische Fehler: Fixkosten in die Entscheidung über Zusatzaufträge einrechnen; Prozentsätze auf die falsche Basis "
    "beziehen.",
]

# ---------------------------------------------------------------- Wochentest-Materialien (erfunden)

SUS_MATERIALS = [
    {"title": "Vorlesung 5: Laplace-Transformation", "doc_type": "vorlesung", "difficulty": 4,
     "text": "Definition: X(s) = Integral von 0 bis unendlich x(t) e^(-st) dt (einseitig). Konvergenzgebiet (ROC): "
             "Menge der s, für die das Integral existiert. Korrespondenzen: epsilon(t) -> 1/s, Re{s} > 0; "
             "e^(-at) epsilon(t) -> 1/(s+a), Re{s} > -a; t epsilon(t) -> 1/s^2. Linearität, Verschiebungssatz "
             "x(t - t0) -> e^(-s t0) X(s), Differentiation x'(t) -> s X(s) - x(0). Übertragungsfunktion eines LTI-Systems "
             "H(s) = Y(s)/X(s); Pole in der linken Halbebene bedeuten Stabilität (kausales System)."},
    {"title": "Übung 5: Laplace und Stabilität", "doc_type": "uebung", "difficulty": 3,
     "text": "Aufgabe 1: Bestimme die Laplace-Transformierte von x(t) = 2 e^(-3t) epsilon(t) mit Konvergenzgebiet. "
             "Aufgabe 2: H(s) = (s+1)/((s+2)(s-1)). Ist das kausale System stabil? Aufgabe 3: Löse y'(t) + 2 y(t) = "
             "epsilon(t), y(0) = 0, mit der Laplace-Transformation. Lösung: Y(s) = 1/(s(s+2)), y(t) = 1/2 (1 - e^(-2t)) "
             "epsilon(t)."},
]

# ---------------------------------------------------------------- Bewertungen (erfundene Antworten)

GRADE_ET = {
    "questions": [
        {"nr": 1, "type": "mc", "points": 2, "question": "Welche Einheit hat der elektrische Widerstand?",
         "options": ["A Volt", "B Ohm", "C Ampere", "D Watt"], "answer": "B Ohm"},
        {"nr": 2, "type": "calc", "points": 4,
         "question": "R1 = 100 Ohm und R2 = 300 Ohm liegen in Reihe an U = 8 V. Wie groß ist der Strom I?",
         "answer": "I = U / (R1 + R2) = 8 V / 400 Ohm = 20 mA"},
        {"nr": 3, "type": "calc", "points": 4, "question": "Wie groß ist der Gesamtwiderstand von 6 Ohm parallel zu 3 Ohm?",
         "answer": "R = 6 * 3 / (6 + 3) Ohm = 2 Ohm"},
        {"nr": 4, "type": "short", "points": 3, "question": "Was besagt die Knotenregel (1. Kirchhoffsches Gesetz)?",
         "answer": "In jedem Knoten ist die Summe der zufließenden Ströme gleich der Summe der abfließenden Ströme."},
        {"nr": 5, "type": "tf", "points": 2,
         "question": "Ein idealer Kondensator lässt im eingeschwungenen Zustand Gleichstrom ungehindert fließen.",
         "options": ["Wahr", "Falsch"], "answer": "Falsch"},
    ],
    "answers": {"1": "B", "2": "I = 8/400 A = 0,02 A", "3": "9 Ohm", "4": "", "5": "Wahr"},
    # erwartete Punkte je Aufgabe als (min, max); eindeutige Faelle exakt
    "expect": {"1": (2, 2), "2": (4, 4), "3": (0, 0), "4": (0, 0), "5": (0, 0)},
}

GRADE_RECHT = {
    "questions": [
        {"nr": 1, "type": "mc", "points": 2, "question": "Ab welchem Alter ist man nach dem BGB voll geschäftsfähig?",
         "options": ["A 7 Jahre", "B 14 Jahre", "C 18 Jahre", "D 21 Jahre"], "answer": "C 18 Jahre"},
        {"nr": 2, "type": "short", "points": 4, "question": "Was ist eine Willenserklärung?",
         "answer": "Die Äußerung eines Willens, der unmittelbar auf die Herbeiführung einer Rechtsfolge gerichtet ist; "
                   "objektiver Tatbestand (Erklärung nach außen) und subjektiver Tatbestand (Handlungswille, "
                   "Erklärungsbewusstsein, Geschäftswille)."},
        {"nr": 3, "type": "tf", "points": 2, "question": "Ein Kaufvertrag über ein Grundstück ist formfrei wirksam.",
         "options": ["Wahr", "Falsch"], "answer": "Falsch"},
        {"nr": 4, "type": "short", "points": 4,
         "question": "Wie heißt das Prinzip, nach dem die Wirksamkeit des Verfügungsgeschäfts unabhängig von der "
                     "Wirksamkeit des Verpflichtungsgeschäfts ist?",
         "answer": "Abstraktionsprinzip"},
    ],
    "answers": {"1": "C", "2": "Eine Äußerung, mit der jemand eine Rechtsfolge herbeiführen will.", "3": "Wahr",
                "4": "Trennungsprinzip"},
    "expect": {"1": (2, 2), "2": (1, 4), "3": (0, 0), "4": (0, 1)},
}


def build_tasks(demo_files: list[dict]) -> list[dict]:
    """Die ~20 Aufgaben des Vergleichs (Reihenfolge = Reihenfolge der Bewertungsseite)."""
    skript = demo_pages(demo_files, "demo-skript")
    blatt = demo_pages(demo_files, "demo-blatt")
    folien = demo_pages(demo_files, "demo-folien")
    T: list[dict] = []

    # ---- Mathe / Analysis
    mws = ("Mittelwertsatz der Differentialrechnung\nSei f: [a, b] -> R stetig und auf (a, b) differenzierbar. Dann gibt es "
           "ein xi in (a, b) mit f'(xi) = (f(b) - f(a)) / (b - a).\nGeometrisch: Es gibt eine Stelle, an der die Tangente "
           "parallel zur Sekante durch (a, f(a)) und (b, f(b)) ist.\nFolgerung: Ist f' = 0 auf einem Intervall, so ist f "
           "dort konstant. Ist f' > 0, so ist f streng monoton wachsend.")
    T.append({"id": "mathe-erklaeren", "kind": "explain", "subject": "Mathe/Analysis", "course": "Mathematik I (Analysis)",
              "file": "Vorlesung 9 – Mittelwertsatz.pdf", "page": 4, "page_text": mws,
              "selection": "Es gibt ein xi in (a, b) mit f'(xi) = (f(b) - f(a)) / (b - a).",
              "expect": {"keywords": ["tangente", "sekante", "steigung", "stetig", "differenzierbar"]}})
    kd = ("Übung 8 – Kurvendiskussion\nAufgabe 3: Gegeben ist f(x) = x^3 - 6x^2 + 9x + 1.\n"
          "a) Bestimme alle lokalen Extrema von f und gib an, ob es Hoch- oder Tiefpunkte sind.\n"
          "b) Bestimme den Wendepunkt.")
    T.append({"id": "mathe-loesen", "kind": "steps", "subject": "Mathe/Analysis", "course": "Mathematik I (Analysis)",
              "file": "Übungsblatt 8.pdf", "page": 1, "page_text": kd, "selection": kd.split("\n", 1)[1],
              "expect": {"patterns": [
                  ("Ableitung 3x^2 - 12x + 9", r"3x\^?2-12x\+9"),
                  ("Hochpunkt (1|5)", r"\(1[|,;]5\)|f\(1\)=5"),
                  ("Tiefpunkt (3|1)", r"\(3[|,;]1\)|f\(3\)=1"),
                  ("Wendepunkt (2|3)", r"\(2[|,;]3\)|f\(2\)=3"),
              ]}})
    folgen = ("Folgen und Reihen\nEine Folge (a_n) konvergiert gegen a, wenn es zu jedem eps > 0 ein N gibt mit |a_n - a| < eps "
              "für alle n >= N. Jede konvergente Folge ist beschränkt. Monotonie und Beschränktheit zusammen ergeben Konvergenz "
              "(Monotoniekriterium).\nReihen: sum a_k konvergiert, wenn die Folge der Partialsummen konvergiert. Notwendig: "
              "a_k -> 0. Geometrische Reihe: sum q^k = 1/(1-q) für |q| < 1. Harmonische Reihe sum 1/k divergiert.\n"
              "Kriterien: Majorantenkriterium, Quotientenkriterium (lim |a_(k+1)/a_k| < 1 => absolut konvergent), "
              "Wurzelkriterium, Leibniz-Kriterium für alternierende Reihen mit monoton fallender Nullfolge.")
    T.append({"id": "mathe-karteikarten", "kind": "flashcards", "subject": "Mathe/Analysis", "course": "Mathematik I (Analysis)",
              "file": "Vorlesung 4 – Folgen und Reihen.pdf", "pages": [1, 3], "text": folgen, "count": 8, "expect": {"count": 8}})

    # ---- Signale und Systeme
    falt = ("Faltung und LTI-Systeme\nEin LTI-System ist durch seine Impulsantwort h(t) vollständig beschrieben. Ausgang: "
            "y(t) = (x * h)(t) = Integral x(tau) h(t - tau) dtau.\nVorgehen: h spiegeln, um t verschieben, mit x multiplizieren, "
            "integrieren. Im Frequenzbereich wird aus der Faltung eine Multiplikation: Y(jw) = X(jw) H(jw).\nKausal: h(t) = 0 "
            "für t < 0. BIBO-stabil: Integral |h(t)| dt < unendlich.")
    T.append({"id": "sus-erklaeren", "kind": "explain", "subject": "Signale und Systeme", "course": "Signale und Systeme",
              "file": "Vorlesung 3 – Faltung.pdf", "page": 7, "page_text": falt,
              "selection": "y(t) = (x * h)(t) = Integral x(tau) h(t - tau) dtau",
              "expect": {"keywords": ["impulsantwort", "spiegel", "verschieb", "integr", "multiplikation"]}})
    lap = ("Übung 5 – Laplace-Transformation\nAufgabe 1: Bestimme die Laplace-Transformierte X(s) von x(t) = 3 e^(-2t) epsilon(t) "
           "und gib das Konvergenzgebiet an.\nAufgabe 2: Ein kausales LTI-System hat H(s) = 1/((s+1)(s+4)). Ist es stabil? "
           "Begründe mit den Polen.")
    T.append({"id": "sus-loesen", "kind": "steps", "subject": "Signale und Systeme", "course": "Signale und Systeme",
              "file": "Übungsblatt 5.pdf", "page": 1, "page_text": lap, "selection": lap.split("\n", 1)[1],
              "expect": {"patterns": [
                  ("X(s) = 3/(s+2)", r"\(?3\)?/\(s\+2\)"),
                  ("Konvergenzgebiet Re{s} > -2", r">-2"),
                  ("Pole -1 und -4", r"-1.{0,80}-4|-4.{0,80}-1"),
                  ("stabil", r"(?<!in)stabil"),
              ]}})
    T.append({"id": "sus-wochentest", "kind": "week_test", "subject": "Signale und Systeme", "duration": 30,
              "materials": SUS_MATERIALS, "options": {"count": 5}, "expect": {}})

    # ---- Elektrotechnik
    kirch = ("Kirchhoffsche Regeln\nKnotenregel: In jedem Knoten ist die Summe aller Ströme null (zufließend positiv, "
             "abfließend negativ).\nMaschenregel: In jeder geschlossenen Masche ist die Summe aller Spannungen null, sum U_k = 0.\n"
             "Mit Ohmschem Gesetz U = R I ergeben beide Regeln ein lineares Gleichungssystem für die Zweigströme.")
    T.append({"id": "et-erklaeren", "kind": "explain", "subject": "Elektrotechnik", "course": "Grundlagen der Elektrotechnik I",
              "file": "Vorlesung 2 – Netzwerke.pdf", "page": 5, "page_text": kirch,
              "selection": "Maschenregel: In jeder geschlossenen Masche ist die Summe aller Spannungen null, sum U_k = 0.",
              "expect": {"keywords": ["masche", "umlauf", "spannung", "vorzeichen", "beispiel"]}})
    teiler = ("Übung 2 – Spannungsteiler\nAufgabe 4: Eine Quelle U = 12 V speist die Reihenschaltung R1 = 2 kOhm und R2 = 4 kOhm.\n"
              "a) Berechne den Strom I.\nb) Berechne die Spannungen U1 an R1 und U2 an R2.\n"
              "c) Welche Leistung nimmt R2 auf?")
    T.append({"id": "et-loesen", "kind": "steps", "subject": "Elektrotechnik", "course": "Grundlagen der Elektrotechnik I",
              "file": "Übungsblatt 2.pdf", "page": 2, "page_text": teiler, "selection": teiler.split("\n", 1)[1],
              "expect": {"patterns": [
                  ("I = 2 mA", r"(?<![\d.,])2([.,]0+)?ma|0[.,]002a"),
                  ("U1 = 4 V", r"(?<![\d.,])4([.,]0+)?v(?![a-z])"),
                  ("U2 = 8 V", r"(?<![\d.,])8([.,]0+)?v(?![a-z])"),
                  ("P2 = 16 mW", r"(?<![\d.,])16([.,]0+)?mw|0[.,]016w"),
              ]}})
    wechsel = ("Wechselstromlehre\nKomplexe Zeiger: u(t) = U_max cos(wt + phi) wird zu U = U_eff e^(j phi). Impedanzen: Widerstand "
               "Z_R = R, Spule Z_L = j w L, Kondensator Z_C = 1/(j w C). Reihenschaltung: Impedanzen addieren; Parallelschaltung: "
               "Admittanzen Y = 1/Z addieren.\nWirkleistung P = U I cos(phi), Blindleistung Q = U I sin(phi), Scheinleistung "
               "S = U I, S^2 = P^2 + Q^2. Resonanz im Reihenschwingkreis bei w0 = 1/sqrt(L C).")
    T.append({"id": "et-karteikarten", "kind": "flashcards", "subject": "Elektrotechnik", "course": "Grundlagen der Elektrotechnik II",
              "file": "Vorlesung 3 – Wechselstrom.pdf", "pages": [2, 4], "text": wechsel, "count": 8, "expect": {"count": 8}})
    T.append({"id": "et-bewerten", "kind": "grade", "subject": "Grundlagen der Elektrotechnik I", **GRADE_ET})

    # ---- Informatik (Demo-Inhalt der App)
    T.append({"id": "info-erklaeren", "kind": "explain", "subject": "Informatik", "course": "Demo: Grundlagen der Informatik",
              "file": demo_name(demo_files, "demo-skript"), "page": 3, "page_text": skript[2],
              "selection": "Negative Zahlen: Bits invertieren und 1 addieren.",
              "expect": {"keywords": ["invert", "addier", "-128", "127", "beispiel"]}})
    T.append({"id": "info-loesen", "kind": "steps", "subject": "Informatik", "course": "Demo: Grundlagen der Informatik",
              "file": demo_name(demo_files, "demo-blatt"), "page": 1, "page_text": blatt[0], "selection": blatt[0],
              "expect": {"patterns": [
                  ("42 = 101010", r"101010(?!\d)"),
                  ("100 = 1100100", r"1100100(?!\d)"),
                  ("255 = 11111111", r"11111111(?!\d)"),
                  ("1011 0110 = 182", r"(?<!\d)182(?!\d)"),
                  ("-37 = 1101 1011", r"11011011(?!\d)"),
              ]}})
    T.append({"id": "info-wochentest", "kind": "week_test", "subject": "Demo Informatik", "duration": 30,
              "materials": [{"title": demo_name(demo_files, "demo-folien"), "doc_type": "vorlesung", "difficulty": 1,
                             "text": "\n\n".join(folien)},
                            {"title": demo_name(demo_files, "demo-skript"), "doc_type": "skript", "difficulty": 2,
                             "text": "\n\n".join(skript)},
                            {"title": demo_name(demo_files, "demo-blatt"), "doc_type": "uebung", "difficulty": 2,
                             "text": "\n\n".join(blatt)}],
              "options": {"count": 5}, "expect": {}})
    T.append({"id": "info-dokument", "kind": "doc", "subject": "Informatik", "pages": DOC_SORTIEREN, "expect": {}})

    # ---- BWL
    be = ("Deckungsbeitrag und Gewinnschwelle\nStückdeckungsbeitrag db = p - kv. Die Gewinnschwelle (Break-even-Menge) ist die "
          "Menge, bei der die Summe der Deckungsbeiträge genau die Fixkosten deckt: x_BE = Kf / (p - kv). Oberhalb von x_BE "
          "entsteht Gewinn, unterhalb Verlust.")
    T.append({"id": "bwl-erklaeren", "kind": "explain", "subject": "BWL", "course": "Einführung in die BWL",
              "file": "Vorlesung 6 – Kostenrechnung.pdf", "page": 11, "page_text": be, "selection": "x_BE = Kf / (p - kv)",
              "expect": {"keywords": ["fixkosten", "deckungsbeitrag", "variable", "gewinn", "beispiel"]}})
    bwl = ("Übung 6 – Break-even\nAufgabe 2: Ein Hersteller hat Fixkosten von 60.000 EUR pro Jahr. Ein Stück kostet variabel "
           "30 EUR und wird für 50 EUR verkauft.\na) Berechne die Break-even-Menge.\nb) Wie hoch ist der Gewinn bei 4.000 Stück?\n"
           "c) Ein Zusatzauftrag über 500 Stück zu 35 EUR je Stück bei freier Kapazität: annehmen?")
    T.append({"id": "bwl-loesen", "kind": "steps", "subject": "BWL", "course": "Einführung in die BWL", "file": "Übungsblatt 6.pdf",
              "page": 1, "page_text": bwl, "selection": bwl.split("\n", 1)[1],
              "expect": {"patterns": [
                  ("x_BE = 3.000 Stück", r"(?<![\d.])3\.?000(?![\d])"),
                  ("Gewinn 20.000 EUR", r"(?<![\d.])20\.?000(?![\d])"),
                  ("Zusatzauftrag DB 2.500 EUR / annehmen", r"(?<![\d.])2\.?500(?![\d])|annehmen"),
              ]}})
    rechtsformen = ("Rechtsformen\nEinzelunternehmen: ein Inhaber, haftet unbeschränkt mit dem Privatvermögen. GbR: mindestens zwei "
                    "Gesellschafter, gemeinsamer Zweck, persönliche Haftung. OHG: Handelsgewerbe, alle Gesellschafter haften "
                    "unbeschränkt. KG: Komplementär haftet unbeschränkt, Kommanditist nur bis zur Einlage. GmbH: juristische "
                    "Person, Stammkapital mindestens 25.000 EUR, Haftung auf das Gesellschaftsvermögen beschränkt. UG "
                    "(haftungsbeschränkt): ab 1 EUR Stammkapital, 25 % des Jahresüberschusses in die Rücklage. AG: Grundkapital "
                    "mindestens 50.000 EUR, Organe Vorstand, Aufsichtsrat, Hauptversammlung.")
    T.append({"id": "bwl-karteikarten", "kind": "flashcards", "subject": "BWL", "course": "Einführung in die BWL",
              "file": "Vorlesung 2 – Rechtsformen.pdf", "pages": [5], "text": rechtsformen, "count": 8, "expect": {"count": 8}})
    T.append({"id": "bwl-dokument", "kind": "doc", "subject": "BWL", "pages": DOC_KOSTENRECHNUNG, "expect": {}})

    # ---- Recht
    abstr = ("Trennungs- und Abstraktionsprinzip\nTrennungsprinzip: Verpflichtungsgeschäft (z. B. Kaufvertrag, § 433 BGB) und "
             "Verfügungsgeschäft (z. B. Übereignung, § 929 S. 1 BGB) sind rechtlich getrennte Geschäfte.\nAbstraktionsprinzip: "
             "Die Wirksamkeit des Verfügungsgeschäfts hängt nicht von der Wirksamkeit des Verpflichtungsgeschäfts ab. Ist der "
             "Kaufvertrag nichtig, wird der Käufer trotzdem Eigentümer; der Verkäufer hat einen Anspruch aus § 812 Abs. 1 S. 1 "
             "Alt. 1 BGB (Leistungskondiktion).")
    T.append({"id": "recht-erklaeren", "kind": "explain", "subject": "Recht", "course": "Bürgerliches Recht I",
              "file": "Vorlesung 5 – Abstraktionsprinzip.pdf", "page": 3, "page_text": abstr,
              "selection": "Die Wirksamkeit des Verfügungsgeschäfts hängt nicht von der Wirksamkeit des Verpflichtungsgeschäfts ab.",
              "expect": {"keywords": ["verpflichtung", "verfügung", "eigentum", "812", "beispiel"]}})
    fall = ("Fall 4 – Das Fahrrad\nDie 16-jährige M kauft ohne Wissen ihrer Eltern beim Händler V ein gebrauchtes Fahrrad für 250 EUR. "
            "Sie zahlt 50 EUR aus ihrem Taschengeld an, der Rest soll in vier Monatsraten folgen. Als die Eltern davon erfahren, "
            "verweigern sie die Genehmigung.\nFrage: Hat V gegen M einen Anspruch auf Zahlung der restlichen 200 EUR aus § 433 "
            "Abs. 2 BGB?")
    T.append({"id": "recht-loesen", "kind": "steps", "subject": "Recht", "course": "Bürgerliches Recht I", "file": "Fallsammlung.pdf",
              "page": 4, "page_text": fall, "selection": fall.split("\n", 1)[1],
              "expect": {"patterns": [
                  ("§ 107 (kein lediglich rechtlicher Vorteil)", r"(?<!\d)107(?!\d)"),
                  ("§ 108 (schwebend unwirksam / Genehmigung)", r"(?<!\d)108(?!\d)"),
                  ("§ 110 (Taschengeld) geprüft", r"(?<!\d)110(?!\d)"),
                  ("Ergebnis: kein Anspruch / unwirksam", r"unwirksam|keinanspruch|keinenanspruch"),
              ]}})
    T.append({"id": "recht-bewerten", "kind": "grade", "subject": "Bürgerliches Recht I", **GRADE_RECHT})
    return T

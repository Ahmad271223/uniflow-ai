"""Leseprogramm `luh-modulbeschreibung`: gemeinsame LUH-Vorlage "Modulbeschreibung" (Naturwissenschaften, Architektur
und Landschaft, Geodaesie, Quantum Engineering, Nanotechnologie, Institute der Philosophischen Fakultaet).

Kopfblock als Tabelle, Feldname und Wert je nach Export in eigener Zeile, in derselben Zeile oder mehrere Felder in
einer Zeile ("Leistungspunkte: 5 Haeufigkeit des Angebots:"):
  Modultitel, Kennnummer / Pruefcode (auch Modul-Nummer, Objektkuerzel/Objekt-ID, Modul-Code), Studiengang, Modultyp,
  Leistungspunkte, Haeufigkeit des Angebots, Sprache, Kompetenzbereich, Empfohlenes Fachsemester, Moduldauer,
  Studentische Arbeitsbelastung, Weitere Verwendung des Moduls
  (englisch: Module Title, Module Code, Degree Course, Module Type, Credit Points, Frequency of Occurrence, Language,
  Special Skills Area, Recommended Semester of Study, Module Duration, Student Workload)
Danach nummerierte Abschnitte 1 Qualifikationsziele, 2 Inhalte des Moduls, 3 Lehrformen, 4a Teilnahmevoraussetzungen,
4b Empfehlungen, 5 Voraussetzungen fuer die Vergabe von Leistungspunkten (Studienleistungen: / Pruefungsleistungen:),
6 Literatur, 7 Weitere Angaben, 8 Organisationseinheit, 9 Modulverantwortliche/r (auch ohne Nummern, englisch).

Modulgrenze: "Haeufigkeit des Angebots" (je Modul genau einmal). Der Kopf beginnt bei der fruehesten Kopfzeile vor
diesem Anker; fehlt "Modultitel", steht der Titel in den Zeilen davor (nach dem Namen der/des Modulverantwortlichen
des vorigen Moduls bzw. am Seitenanfang). Kopf- und Fusszeilen, die sich auf vielen Seiten wiederholen, fallen weg;
"Pflichtmodule"/"Wahlpflichtmodule" in Ueberschriften oder Kopfzeilen dienen als Art und Bereich, wenn das Modul keine
nennt.
"""
from __future__ import annotations

import re
from collections import Counter

from .formats_a_common import NUM, build_catalog, clip, kind_of, language_of, number, page_lines, \
    term_of_catalog, text_join, turnus_of

W = r"(?<![\wäöüÄÖÜß])"   # Wortanfang
E = r"(?![\wäöüÄÖÜß])"    # Wortende


def _lab(p: str) -> str:
    return W + p.replace(" ", r"\s+") + E


# Kopf-Felder: Schluessel -> Muster (laengere Varianten zuerst)
HEAD = [
    ("title", [r"Modultitel / Module Name", r"Modultitel[0-9]?", r"Module Title[0-9]?", r"Modulbezeichnung",
               r"Module title", r"^Title(?=[ ]*$)"]),
    ("code", [r"Kennnummer\s*/\s*Prüfcode", r"Kennnummer\s*/", r"Kenn-Nr\.", r"Modul-Nummer\s*/\s*Module\s+Code",
              r"Modul-Nummer", r"Modulnummer", r"Modul-Code", r"Module Code", r"Objektkürzel\s*/\s*Objekt\s?-\s?ID", r"Objektkürzel",
              r"number StudIP", r"Code/ID", r"Identification number\s*/\s*Code", r"Modul(?=:)"]),
    ("program", [r"Studiengang\s*/\s*Degree\s+Programme", r"Studiengang", r"Study programme", r"Degree Course",
                 r"Degree Programme", r"Degree programme", r"Study program"]),
    ("kind", [r"Modultyp\s*/\s*Modul\s+Type", r"Modultyp", r"Module Type", r"Module type", r"Modul type",
              r"Type of Module"]),
    ("lp", [r"Leistungspunkte\s*/\s*Credit\s+Points", r"Leistungspunkte\s*/\s*Workload", r"Leistungspunkte",
            r"Credit Points", r"Credit points", r"Credits"]),
    ("freq", [r"Häufigkeit\s+des\s+Angebots(?:\s*/\s*Frequency)?", r"Frequency of (?:the )?(?:Occurr?\s?ence|offer|Offer)"]),
    ("language", [r"Sprache\s*/\s*Language", r"Sprache", r"Language"]),
    ("area", [r"Kompetenzbereich\s*/\s*Area\s+of\s+Expertise", r"Vertiefung/\s*Schwerpunkt/\s*Kompetenzbereich",
              r"Kompetenzbereich", r"Spezialisierungsbereich", r"^Vertiefungsrichtung(?=[ ]*$)", r"Special Skills Area",
              r"Special skills area", r"Area of expertise", r"Area of Expertise"]),
    ("semester", [r"Empfohlenes\s+Fachsemester\s*/\s*Recommended\s+Course\s+Semester", r"Empfohlenes\s+Fachsemester",
                  r"Recommended Semester of Study", r"Recommended semester of study", r"Recommended Semester",
                  r"Recommended semester", r"Fachsemester(?= [0-9])"]),
    ("duration", [r"Moduldauer\s*/\s*Duration", r"Moduldauer", r"Module Duration", r"Module duration"]),
    ("workload", [r"Studentische\s+Arbeitsbelastung\s*/\s*Workload", r"Studentische\s+Arbeitsbelastung",
                  r"Student Workload", r"Student workload"]),
    ("usage", [r"Weitere Verwendung des Moduls", r"Weitere Verwendung von Teilveranstaltungen",
               r"Verwendung des Moduls", r"Further use of the module", r"Further Use of the Module",
               r"Further Use of Module", r"Further use of module"]),
    ("offered", [r"Angeboten durch"]),
    ("lead_head", [r"Modulverantwortliche/r(?= )"]),
    ("prereq_head", [r"Teilnahmevoraussetzungen(?= )"]),
    ("lecturer", [r"Dozent\*inn\*en"]),
    ("courses", [r"Lehrveranstaltungen(?=\n)"]),
    ("credit_head", [r"Voraussetzungen\s+für\s+Leistungspunktevergabe"]),
]
HEAD_RES = [(k, re.compile("|".join(_lab(p) for p in pats), re.M)) for k, pats in HEAD]
FREQ_RE = dict(HEAD_RES)["freq"]
# Kopfzeilen vor dem Anker (zur Suche des Kopfanfangs)
PRE_KEYS = ("title", "code", "program", "kind", "lp", "offered", "semester", "area")
PRE_RE = re.compile("|".join(r.pattern for k, r in HEAD_RES if k in PRE_KEYS), re.M)

# Abschnitte im Rumpf: Nummer (optional) + Stichwort
BODY = [
    ("goals", 1, r"Qualifikationsziele|Qualification [Gg]oals|Qualification [Oo]bjectives|Learning [Oo]utcomes|Lernergebnisse|Kompetenzziele"),
    ("content", 2, r"Inhalte des Moduls|Inhalte|Studieninhalte|Module [Cc]ontents?|Contents? of the [Mm]odule|Contents"),
    ("forms", 3, r"Lehrformen|Forms of [Tt]eaching|Teaching [Mm]ethods|Teaching and [Ll]earning"),
    ("prereq", 4, r"Teilnahmevoraussetzungen|Participation [Rr]equirements|Conditions of [Pp]articipation|Prerequisites"),
    ("recommend", 4.5, r"Empfehlungen|Empfohlene|Ggf\. Empfehlungen|Recommendations"),
    ("credit", 5, r"Voraussetzungen für die Vergabe|Voraussetzungen für Leistungspunktevergabe|Requirements for (?:the )?[Aa](?:llocation|ward)|Prerequisites for [Aa]warding"),
    ("literature", 6, r"Literatur|Grundlegende Literatur|Literature|Reading [Ll]ist"),
    ("further", 7, r"Weitere Angaben|Further [Dd]etails|Further [Ii]nformation|Additional [Ii]nformation|Empfehlungen/ Anmerkungen"),
    ("org", 8, r"Organisationseinheit(?:en)?|Organi[sz]ational [Uu]nit|Module [Pp]rovider"),
    ("lead", 9, r"Modulverantwortliche|Module [Cc]oordinator|Person [Rr]esponsible|Responsible for the [Mm]odule|Modulverantwortlicher"),
]
SQUASHED = {"goals": ("qualifikationsziel", "qualification", "lernergebnis", "learningoutcome", "kompetenzziel"),
            "content": ("inhalt", "modulecontent", "content", "studieninhalt"),
            "forms": ("lehrform", "formsofteaching", "teaching"),
            "prereq": ("teilnahmevoraussetzung", "participation", "conditionsofparticipation", "prerequisite"),
            "recommend": ("empfehlung", "empfohlen", "ggf.empfehlung", "recommend"),
            "credit": ("voraussetzungenfür", "voraussetzungfür", "requirementsfor", "prerequisitesfor"),
            "literature": ("literatur", "literature", "readinglist"),
            "further": ("weitereangabe", "further", "additional"),
            "org": ("organisationseinheit", "organisationalunit", "organizationalunit", "moduleprovider"),
            "lead": ("modulverantwortlich", "modulecoordinator", "personresponsible", "responsibleforthe")}
# ganze Zeile als Abschnittsname (ohne Nummer), Leerraum entfernt, klein; auch zerrissene Woerter
PLAIN_LABELS = {}
for _k, _names in {
    "goals": ("qualifikationsziele", "qualificationgoals", "qualificationobjectives", "learningoutcomes",
              "lernergebnisse", "kompetenzziele", "qualificationgoals/modulepurpose"),
    "content": ("inhaltedesmoduls", "inhaltdesmoduls", "inhalte", "inhalt", "studieninhalte", "modulecontents",
                "modulecontent", "contentsofthemodule", "contentofthemodule", "contents"),
    "forms": ("lehrformenundlehrveranstaltungen", "lehrformen", "formsofteachingandcourses",
              "teachingmethodsandcourses"),
    "prereq": ("teilnahmevoraussetzungen", "teilnahmevoraussetzungen;empfehlungen", "participationrequirements",
               "participationrequirements;recommendations", "conditionsofparticipation"),
    "recommend": ("empfehlungen", "recommendations", "recommendedpriorknowledge", "empfohlenevorkenntnisse"),
    "credit": ("voraussetzungenfürdievergabevonleistungspunkten", "requirementsforallocationofcreditpoints",
               "requirementsfortheawardofcreditpoints", "voraussetzungenfürdievergabevonleistungspunkten(lp)",
               "prerequisitesfortheawardingofcreditpoints", "prerequisitesforawardingcreditpoints",
               "requirementsfortheallocationofcreditpoints", "prerequisitesforreceivingcreditpoints"),
    "literature": ("literatur", "literature", "readinglist", "grundlegendeliteratur"),
    "further": ("weitereangaben", "furtherinformation", "furtherdetails", "additionalinformation"),
    "org": ("organisationseinheit", "organisationseinheiten", "organisationalunit", "organizationalunit",
            "moduleprovider"),
    "lead": ("modulverantwortliche/r", "modulverantwortliche", "personresponsibleformodule",
             "personresponsibleforthemodule", "modulecoordinator", "responsibleforthemodule",
             "modulverantwortliche/modulverantwortlicher"),
}.items():
    for _n in _names:
        PLAIN_LABELS[_n] = _k
NUM_TO_KEY = {"1": "goals", "2": "content", "3": "forms", "4": "prereq", "4a": "prereq", "4b": "recommend", "5": "credit",
              "6": "literature", "7": "further", "8": "org", "9": "lead"}
ORDER = {k: o for k, o, _ in BODY}
BODY_NUM_RE = re.compile(r"^([1-9][ab]?)\.?\s*(" + "|".join(p for _, _, p in BODY) + r")")
BODY_PLAIN_RE = re.compile(r"^(" + "|".join(p for _, _, p in BODY) + r")" + E + r"\s*(?::|/|$)")
BODY_KEY_RES = [(k, re.compile(r"^(?:" + p + ")")) for k, _, p in BODY]

EXAM_LAB = r"Prüfungsleistung(?:en)?(?:\s*/\s*Examinations?)?|Prüfungsform|Exam(?:ination)? performance|Examination [Rr]equirements?|Assessments?|Examinations?"
CW_LAB = r"Studienleistung(?:en)?(?:\s*/\s*Course\s+Achievements?)?|Study achievements?|Course [Aa]chievements?|Course ?[Ww]ork"
STOP_LAB = (r"Weitere Informationen zu \w+|Further [Ii]nformations? (?:to|on) [\w ]+?|Dozierende|Lehrende|Lecturers?|"
            r"Bemerkungen?|Hinweise?")
SUB_RE = re.compile(r"(?:^|(?<=\n)|(?<=\s))(?<!of )(?<!Code )(?:(?P<exam>" + EXAM_LAB + r")|(?P<cw>" + CW_LAB + r")|(?P<stop>" + STOP_LAB
                    + r"))\s*:|(?:^|(?<=\n))(?:(?P<exam2>" + EXAM_LAB + r")|(?P<cw2>" + CW_LAB + r"))\s*(?=\n)|"
                    r"(?:^|(?<=\n))(?:(?P<exam3>Prüfungsleistung(?:en)?)|(?P<cw3>Studienleistung(?:en)?))"
                    r"(?:,| \(| die| für| im| in| je| pro)[^\n:]{0,70}(?:\n|$)")

PERSON_RE = re.compile(r"\bProf\b|Prof\.|\bDr\.|@|E-Mail|\bM\.\s?Sc\.|\bDipl\.|N\.\s?N\.|Dozent|Lehrende|Mitarbeiter|"
                       r"www\.|https?://|\bapl\.|Juniorprof|PD Dr|\bstaff\b|Lecturer")
GROUP_RE = re.compile(r"^(?:[0-9]+(?:\.[0-9]+)*\.?\s+)?((?:Pflicht|Wahlpflicht|Wahl)(?:module|bereich)\b.*|"
                      r"(?:Compulsory|Elective|Required [Ee]lective|Mandatory [Ee]lective|Compu?l?sory [Ee]lective) [Mm]odules\b.*)$")
HEADING_COLON_RE = re.compile(r"^(?:Kompetenzfeld|Wahlpflichtmodul|Pflichtmodul|Wahlmodul|Wahlpflichtbereich|Schwerpunkt|"
                              r"Vertiefung)\s*:")
NONE_VALUES = {"", "-", "--", "---", "–", "kein", "keine", "keiner", "entfällt", "n/a", "none", "/", "nein", "no"}
NOISE_RE = re.compile(r"^(?:[0-9]{1,3}|[0-9]{1,2}\.[0-9]{1,2}\.[0-9]{2,4}|Seite [0-9]+(?: von [0-9]+)?|v-[0-9-]+)$")


def _strip_headers(pages: list[list[str]]) -> tuple[list[tuple[int, str]], dict]:
    """Seitenzeilen -> [(seite, zeile)] ohne wiederkehrende Kopf-/Fusszeilen und Seitenzahlen; dazu je Seite die Art
    aus einer entfernten Kopfzeile ("... - Wahlpflichtmodule Stand ...")"""
    def norm(l):
        return re.sub(r"[0-9]+", "#", l)
    cnt: Counter = Counter()
    for lines in pages:
        edge = set(norm(l) for l in lines[:3] + lines[-3:])
        cnt.update(edge)
    limit = max(3, int(len(pages) * 0.2))
    heads = {k for k, v in cnt.items() if v >= limit and len(k) >= 8 and not PRE_RE.search(k) and not FREQ_RE.search(k)
             and not BODY_NUM_RE.match(k) and not BODY_PLAIN_RE.match(k)}
    out, hint = [], {}
    for pno, lines in enumerate(pages, 1):
        n = len(lines)
        for i, l in enumerate(lines):
            edge = i < 3 or i >= n - 3
            if edge and (norm(l) in heads or NOISE_RE.match(l)):
                k = _kind_hint(l)
                if k:
                    hint[pno] = k
                continue
            out.append((pno, l))
    return out, hint


def _kind_hint(text: str) -> str | None:
    t = text.lower()
    if "wahlpflicht" in t or "required elective" in t or "compulsory elective" in t:
        return "wahlpflicht"
    if re.search(r"pflichtmodul|pflichtbereich|compulsory module", t):
        return "pflicht"
    if re.search(r"\bwahlmodul|\bwahlbereich|elective module", t):
        return "wahl"
    return None


def _body_key(line: str):
    """(schluessel, rest) wenn die Zeile einen Rumpf-Abschnitt beginnt"""
    m = BODY_NUM_RE.match(line)
    if m:
        key = NUM_TO_KEY.get(m.group(1))
        word = m.group(2)
        # Nummer und Stichwort muessen zusammenpassen (sonst "1 Vorlesung", "5 LP")
        k2 = next((k for k, r in BODY_KEY_RES if r.match(word)), None)
        if key and k2 and (k2 == key or {key, k2} <= {"prereq", "recommend"}):
            return key, line[m.end(2):].lstrip(" :.").strip()
        if k2 and key and abs(ORDER[k2] - ORDER[key]) <= 1:
            return k2, line[m.end(2):].lstrip(" :.").strip()
        return None
    m = re.match(r"^([1-9][ab]?)\.?\s*(\S.*)$", line)
    if m and m.group(1) in NUM_TO_KEY:
        # zerrissene Woerter ("5 Voraussetzung en fuer die Vergabe von Leistung spunkten")
        squash = re.sub(r"\s+", "", m.group(2)).lower()
        key = NUM_TO_KEY[m.group(1)]
        if any(squash.startswith(st) for st in SQUASHED.get(key, ())):
            rest = m.group(2).split(":", 1)[1].strip() if ":" in m.group(2) else ""
            return key, rest
    if len(line) <= 140:
        sq = re.sub(r"\s+", "", line).lower()
        head, colon, rest = sq.partition(":")
        key = PLAIN_LABELS.get(head)
        if not key and " / " in line:
            # zweisprachig: "Voraussetzungen fuer die Vergabe von Leistungspunkten / Prerequisites ...:"
            key = PLAIN_LABELS.get(re.sub(r"\s+", "", line.split(" / ", 1)[0]).lower())
        if key:
            return key, line.split(":", 1)[1].strip() if colon else ""
    m = BODY_PLAIN_RE.match(line)
    if m:
        word = m.group(1)
        k2 = next((k for k, r in BODY_KEY_RES if r.match(word)), None)
        if k2:
            return k2, line[m.end(1):].lstrip(" :/").strip()
    return None


def _merge_numbers(lines: list[tuple[int, str]]) -> list[tuple[int, str]]:
    """'7' + 'Weitere Angaben' -> '7 Weitere Angaben'; Silbentrennung 'Teilnahmevoraussetzunge n' wird nicht repariert"""
    out = []
    i = 0
    while i < len(lines):
        p, l = lines[i]
        if re.fullmatch(r"[1-9][ab]?", l) and i + 1 < len(lines) and _body_key(l + " " + lines[i + 1][1]):
            out.append((p, l + " " + lines[i + 1][1]))
            i += 2
            continue
        out.append((p, l))
        i += 1
    return out


def _segment(lines: list[tuple[int, str]]):
    """-> [(kopfanfang, anker, titelkandidaten)] je Modul"""
    texts = [l for _, l in lines]
    anchors = []
    for i, l in enumerate(texts):
        if FREQ_RE.search(l) or (l.endswith("Häufigkeit des") and i + 1 < len(texts) and texts[i + 1].startswith("Angebot")):
            if anchors and i - anchors[-1] < 4:
                continue
            anchors.append(i)
    out = []
    prev = -1
    for a in anchors:
        first = a
        gap = 0
        stop = prev
        j = a - 1
        while j > prev:
            l = texts[j]
            bk = _body_key(l)
            if bk and not (bk[0] == "lead" and bk[1] and j + 1 < a and _has_pre(texts[j + 1])):
                stop = j
                break
            if _has_pre(l):
                first = j
                gap = 0
            else:
                gap += 1
                if gap > 4:
                    stop = j
                    break
            j -= 1
        # Titelkandidaten: Zeilen zwischen stop und first (nach Personenzeilen), nur auf der Seite des Kopfanfangs
        cand = []
        for k in range(stop + 1, first):
            l = texts[k]
            if PERSON_RE.search(l) or _body_key(l) or "...." in l or l.endswith((".", ":")) \
                    or re.search(r"[a-zäöüß)]\. [A-ZÄÖÜ]", l) or HEADING_COLON_RE.match(l):
                # Personen, Saetze ("Es muessen Module von mind. 15 LP ..."), Ueberschriften ("Kompetenzfeld: Chemie")
                cand = []
                continue
            if re.search(r"\((?:M|B)\.?\s?(?:Sc|A|Ed)?\.?$", l):   # abgeschnittene Kopfzeile "... (M."
                continue
            cand.append(k)
        page = lines[first][0]
        cand = [k for k in cand if lines[k][0] == page] or cand
        # Gruppenueberschrift ("Compulsory Elective Modules Focus „Soil/" + "Water”") vor dem Titel abtrennen
        for i, k in enumerate(cand):
            if GROUP_RE.match(texts[k]):
                rest = cand[i + 1:]
                if "„" in texts[k] and not re.search(r"[”“\"]", texts[k].split("„", 1)[1]):
                    while rest and not re.search(r"[”“\"]", texts[rest[0]]):
                        rest = rest[1:]
                    rest = rest[1:]
                cand = rest
                break
        out.append((first, a, cand))
        prev = a
    return out


def _label_hits(text: str, keys=None) -> list[tuple[int, int, str]]:
    """Feldnamen im Kopftext. Ein einzelnes Wort mitten in der Zeile ("... 15 Leistungspunkte erbracht werden") zaehlt
    nur, wenn ":" oder das Zeilenende folgt oder die Zeile weitere Feldnamen enthaelt (flach gelesene Tabelle)."""
    hits = []
    for key, rx in HEAD_RES:
        if keys and key not in keys:
            continue
        for m in rx.finditer(text):
            hits.append((m.start(), m.end(), key))
    hits.sort(key=lambda h: (h[0], -(h[1] - h[0])))
    chosen, end = [], -1
    for h in hits:
        if h[0] < end:
            continue
        chosen.append(h)
        end = h[1]
    out = []
    for s, e, key in chosen:
        word = text[s:e]
        ls = text.rfind("\n", 0, s) + 1
        le = text.find("\n", e)
        le = len(text) if le < 0 else le
        if " " not in word.strip() and text[ls:s].strip():
            after = text[e:le].lstrip(" ")
            others = sum(1 for s2, e2, _ in chosen if ls <= s2 < le and s2 != s)
            if not (after.startswith(":") or not after or others):
                continue
        out.append((s, e, key))
    return out


def _has_pre(line: str) -> bool:
    return bool(_label_hits(line, PRE_KEYS))


def _head_values(text: str) -> dict:
    chosen = _label_hits(text)
    vals: dict = {}
    for i, (s, e, key) in enumerate(chosen):
        nxt = chosen[i + 1][0] if i + 1 < len(chosen) else len(text)
        if key in vals:
            continue
        vals[key] = text[e:nxt].strip(" :\n")
    vals["_prefix"] = text[: chosen[0][0]].strip() if chosen else text.strip()
    return vals


def _clean(v: str | None) -> str:
    return re.sub(r"\s+", " ", v or "").strip(" :;,.")


def _strip_english(title: str) -> str:
    """'Allgemeine Botanik (General Botany)' -> 'Allgemeine Botanik'; kurze Klammern ('(M3)', '(MSPP)') bleiben"""
    m = re.match(r"^(.+?)\s*\(([^()]{4,})\)\s*$", title)
    if m and len(m.group(2).split()) >= 3 and len(m.group(1)) >= 4:
        return m.group(1).strip()
    m = re.match(r"^(.+?)\s*\(([^()]+)$", title)   # Klammer nicht geschlossen (umbrochen)
    if m and len(m.group(2).split()) >= 3 and len(m.group(1)) >= 4:
        return m.group(1).strip()
    return title


def _first_int(v: str) -> int | None:
    m = re.search(r"(?<![0-9])([0-9]{1,2})(?![0-9])", v or "")
    if m and 1 <= int(m.group(1)) <= 20:
        return int(m.group(1))
    return None


def _lp(v: str):
    m = re.search(r"(" + NUM + r")\s*(?:LP|ECTS|CP|Leistungspunkte|credit)", v or "", re.I)
    if not m:
        m = re.match(r"^\s*(" + NUM + r")(?![0-9])", v or "")
    if m:
        x = number(m.group(1))
        return x if 0 < x <= 60 else None
    return None


def _workload(v: str):
    t = v or ""
    m = re.search(r"(?:Gesamt|Insgesamt|Total|Summe|Gesamtworkload)[^0-9]{0,40}?(" + NUM + r")", t, re.I)
    if not m:
        m = re.search(r"(" + NUM + r")\s*(?:Stunden|Std\.?|h\b|hours)", t)
    if not m:
        m = re.match(r"^\s*(" + NUM + r")\b", t)
    if m:
        x = number(m.group(1))
        return x if 10 <= x <= 3000 else None
    return None


def _turnus(v: str) -> str:
    t = v.lower()
    if re.search(r"kontinuierlich|laufend|ständig|fortlaufend|continuous|jederzeit|any ?time", t):
        return "WS+SS"
    return turnus_of(v)


def _short(val: str) -> str:
    """Pruefungsangabe ohne Verwaltungstext ('Pruefungsdetails werden ... bekannt gegeben', Nummern)"""
    val = re.sub(r"\s*-?\s*\((?:Prüfungsleistungsnummer|Studienleistungsnummer)[^)]*\)", "", val)
    val = re.sub(r"\s*(?:mit der|mit) (?:Prüfungsleistungsnummer|Studienleistungsnummer)\s*[0-9]+", "", val)
    m = re.search(r"\s(?:Prüfungsdetails|Studienleistungen werden|Alle Prüfungsleistungen|Bitte beachten|Die genaue "
                  r"Prüfungsform|All Course Achievements|Details of the)", val)
    if m and m.start() >= 10:
        val = val[: m.start()]
    val = re.sub(r"\s*-?\s*\((?:Prüfungsleistungsnummer|Studienleistungsnummern?)[^)]*\)?\s*$", "", val)
    if len(val) > 150:
        m = re.search(r"(?<=[a-zäöüß0-9)])\. (?=[A-ZÄÖÜ])", val[20:])
        if m:
            val = val[: 20 + m.start() + 1]
    return val


def _credit_parts(text: str) -> tuple[str | None, str | None]:
    """Abschnitt 5 -> (Pruefungsleistung, Studienleistung)"""
    if not text:
        return None, None
    hits = list(SUB_RE.finditer(text))
    exams, cws = [], []
    for i, m in enumerate(hits):
        nxt = hits[i + 1].start() if i + 1 < len(hits) else len(text)
        val = _clean(text[m.end():nxt])
        if not val or val.lower().strip(" .") in NONE_VALUES or val.lower().startswith(("keine", "none")) and len(val) < 12:
            continue
        val = _short(val)
        if m.group("exam") or m.group("exam2") or m.group("exam3"):
            exams.append(val)
        elif m.group("cw") or m.group("cw2") or m.group("cw3"):
            cws.append(val)
    if not exams:
        # "Eine Pruefungsleistung pro Modul: Klausur ..." oder kurzer Text ohne Feldnamen
        t = _clean(text)
        m = re.search(r"Prüfungsleistung\w*[^:.]{0,40}:\s*([^\n]+)", text)
        if m and _clean(m.group(1)).lower() not in NONE_VALUES and not _clean(m.group(1)).lower().startswith("keine"):
            exams.append(_short(_clean(m.group(1))))
        elif not hits and len(t) <= 200 and re.search(r"Klausur|Prüfung|Hausarbeit|Referat|Portfolio|exam|Präsentation", t, re.I):
            exams.append(t)
    return ("; ".join(exams) or None), ("; ".join(cws) or None)


def parse(pages: list[str], meta: dict) -> tuple[dict, dict]:
    plines = page_lines(pages)
    head_text = " ".join(" ".join(p[:12]) for p in plines[:3])
    term = term_of_catalog(meta.get("catalog_term"), head_text)
    lines, page_hint = _strip_headers(plines)
    lines = _merge_numbers(lines)
    texts = [l for _, l in lines]
    segs = _segment(lines)
    raw = []
    in_head = set()
    for first, anchor, _ in segs:
        in_head.update(range(first, anchor + 14))
    group_kind, group_area = None, None
    gi = 0   # Ueberschriften (Pflichtmodule/Wahlpflichtmodule) bis zum Kopfanfang
    for n, (first, anchor, cand) in enumerate(segs):
        end = segs[n + 1][0] if n + 1 < len(segs) else len(lines)
        if cand:
            end = min(end, len(lines))
        for k in range(gi, first):
            if k in in_head:
                continue
            l = texts[k]
            if "...." in l or len(l) > 90:
                continue
            g = GROUP_RE.match(l)
            if g and not PRE_RE.search(l) and not re.search(r"(?:^|\s)(?:[0-9]+|X|x|-)(?:\s|$)", g.group(1)):
                group_kind = _kind_hint(l) or group_kind
                group_area = g.group(1)
        gi = first
        # Kopf bis zum ersten Rumpf-Abschnitt nach dem Anker
        body_start = end
        for k in range(anchor + 1, end):
            if _body_key(texts[k]):
                body_start = k
                break
        head = "\n".join(texts[first:body_start])
        vals = _head_values(head)
        # Rumpf
        sec: dict = {}
        cur, pos = None, -1.0
        for k in range(body_start, end):
            l = texts[k]
            bk = _body_key(l)
            if bk and ORDER[bk[0]] > pos:
                cur, rest = bk
                pos = ORDER[cur]
                sec.setdefault(cur, [])
                if rest:
                    sec[cur].append(rest)
                continue
            if cur:
                sec[cur].append(l)
        # Titel
        title = _clean(vals.get("title"))
        if title:
            title = title.split(" Kennnummer")[0]
            # zweisprachig "DE: <Titel> EN: <title>"
            title = re.sub(r"^DE\s*:\s*", "", title).split(" EN:")[0].strip()
        prefix = _clean(vals.get("_prefix"))
        if len(prefix) >= 4 and not prefix[0].islower():
            # Titel in der Zeile des ersten Feldnamens ("Pflichtmodul X Studiengang: ...", "X Kennnummer / Pruefcode")
            cand = []
        pre_title = _clean(" ".join([texts[k] for k in cand] + [prefix]))
        kind_word = None
        mk = re.match(r"^(Pflichtmodul|Wahlpflichtmodul|Wahlmodul|Pflicht|Wahlpflicht|Wahl)\s+(.*)$", pre_title)
        if mk:
            kind_word, pre_title = kind_of(mk.group(1)), mk.group(2)
        if not title:
            # Titel ohne Feldnamen; reine Klammerzeilen (englischer Titel) weg
            parts = [texts[k] for k in cand if not re.fullmatch(r"\(.*\)", texts[k])]
            if vals.get("_prefix"):
                parts.append(vals["_prefix"])
            title = _clean(" ".join(parts))
            if mk:
                title = pre_title
            # Ueberschriften vor dem Titel ("Pflichtmodule", "2.1 Wahlpflichtmodule ...") abtrennen
            for k in cand:
                g = GROUP_RE.match(texts[k])
                if g and title.startswith(texts[k]) and len(title) > len(texts[k]) + 3:
                    group_kind = _kind_hint(texts[k]) or group_kind
                    group_area = g.group(1)
                    title = title[len(texts[k]):].strip()
        title = _strip_english(title)
        if not title:
            continue
        code = _clean((vals.get("code") or "").split("\n")[0])
        if code.lower() in NONE_VALUES or len(code) > 80 or not re.search(r"[0-9]", code):
            code = None
        kv = _clean(vals.get("kind"))
        kind = kind_of(" ".join(kv.split(" ")[:2])) or kind_of(kv.split(" ")[0] if kv else "") or kind_word
        area = _clean(vals.get("area"))
        area = re.sub(r"^(?:Kompetenzfeld|Schwerpunkt|Bereich)\s*:\s*", "", area)
        if area.lower() in NONE_VALUES or len(area) > 120:
            area = None
        if not area and group_area:
            area = group_area
        if kind is None:
            kind = page_hint.get(lines[first][0]) or group_kind
        exam, cw = _credit_parts("\n".join(sec.get("credit") or []))
        if exam is None and cw is None and vals.get("credit_head"):
            exam, cw = _credit_parts(vals["credit_head"])
        prereq = " ".join((sec.get("prereq") or []) + (sec.get("recommend") or []) + [vals.get("prereq_head") or ""])
        lit = text_join(sec.get("literature"))
        raw.append({
            "title": title, "code": code, "area": area, "kind": kind,
            "lp": _lp(vals.get("lp") or ""),
            "semester": _first_int(vals.get("semester") or ""),
            "turnus": _turnus(_clean(vals.get("freq"))),
            "exam": exam, "coursework": cw, "prereq": prereq,
            "language": language_of(_clean(vals.get("language")).split(" (")[0]),
            "workload_h": _workload(vals.get("workload") or vals.get("lp") or ""),
            "page": lines[first][0],
            "goals": text_join(sec.get("goals")), "content": text_join(sec.get("content")),
            "literature": None if lit and lit.lower().strip(" .") in NONE_VALUES else lit,
        })
    return build_catalog(meta, raw, None, term)

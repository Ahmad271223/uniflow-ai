"""Leseprogramme fuer die Modulhandbuecher der Universitaet Hildesheim (Grundstock, einmal auf dem Mac gelesen, nie auf
dem Geraet; docs/STUDIENGAENGE-HILDESHEIM-2026-11-05.md). Quelle ist immer das elektronische Verkuendungsblatt
(uniQuIS, `qm/processmanagement/download.php`); jede Seite traegt die Fusszeile "Verkuendungsblatt der Universitaet
Hildesheim - Heft N - Nr. ... - Seite N -", die vor dem Lesen wegfaellt.

Zwei Formate:

`hildesheim-modulbeschreibung` - die Modulbeschreibungen in den Studienordnungen (Anlage "Modulhandbuch" bzw.
"Modulbeschreibungen") fast aller Faecher und Studiengaenge ausserhalb der IT: je Modul eine zweispaltige Tabelle mit
Feldnamen aus einer gemeinsamen Vorlage, die je Fach leicht abweicht:
  Titelzeile ("Basismodul (BM) 1: ...", "Modul G: ...", "Modul „...“", "Modultitel ..."), Modulnummer,
  ModulleiterIn / Modulleitung / Modulverantwortlich, Kompetenz- und Lernziele, Verwendbarkeit, Pflicht- oder
  Wahlpflichtmodul, Lehr- und Lernformen, Lehrinhalte, Zugangsvoraussetzungen, Anzahl der Leistungspunkte, Workload
  (getrennt nach Praesenz- und Selbststudium), Dauer in Semestern, Haeufigkeit des Angebots, Empfohlenes
  (Studien)semester, Voraussetzungen fuer die Zulassung zur Pruefung, Pruefungsleistungen (Art, Umfang),
  Studienleistungen (Art und Umfang), Unterrichts- und Pruefungssprache, Zustaendige Staendige Pruefungskommission.
  Feldnamen brechen ueber bis zu drei Zeilen um ("Pflicht- oder / Wahlpflichtmodul:"); verglichen wird daher in einer
  Kurzform ohne Leerraum, Bindestriche und Umlaute. Modulgrenze: Titel, Modulnummer oder Modulleitung, die im
  laufenden Modul schon vorkamen bzw. nach den Sachfeldern stehen; der Titel steht in den Zeilen davor.

`hildesheim-it-modulhandbuch` - die Modulhandbuecher des Fachbereichs 4 (IT-Studiengaenge, Datenbank-Ausgabe, auch
englisch): vorn ein Verzeichnis je Bereich ("Pflichtmodule im Bachelor" / "Informatik" / "Gebiet ...", Tabelle
"Modul Lehrform/SWS LP S."), danach je Modul "Modul: <Titel>" mit Modulverantwortlicher, Lehrform/SWS,
Leistungspunkte, Arbeitsaufwand, Lernziele/Kompetenzen, Lehrinhalte, Literatur, Voraussetzungen fuer die Teilnahme,
Pruefungsleistung, empfohlenes Semester ("BSc 1", "MSc 1-3"), Turnus, Dauer des Moduls, Verwendung, Sprache
(englisch: Module, Responsible, Type, Credit Points, Workload, Learning goals/Competencies, Content, Literature,
Requirements, Exam, Recommended Term, Turn, Duration, Use, Language). Ein Handbuch gilt fuer Bachelor und Master; der
Katalog eines Eintrags nimmt die Bereiche seines Abschlusses (Verzeichnis: Abschnitt mit "Bachelor"/"Master", sonst
der vorige), ein Modul in mehreren Bereichen steht einmal (erster Bereich) und in `areas[].modules` der anderen.

Beide liefern (Katalog im geteilten Format, lokale Texte) wie die LUH-Leser (formats_a_common.build_catalog).
"""
from __future__ import annotations

import re
import unicodedata

from .formats_a_common import build_catalog, clip, language_of, number, text_join, turnus_of

FOOTER_RE = re.compile(r"\s*Verkündungsblatt der (?:Stiftung )?Universität Hildesheim\s*[-–]\s*Heft[^\n]*?Seite\s*\d+\s*[-–]")
NONE_VALUES = {"", "-", "--", "–", "keine", "kein", "keiner", "entfällt", "none", "no", "n/a", "/", "nein", "s.o.", "s. o."}


def _fold(s: str) -> str:
    """Kurzform fuer Feldnamen: klein, Umlaute ausgeschrieben, nur Buchstaben und Ziffern"""
    t = unicodedata.normalize("NFKC", s or "").lower()
    for a, b in (("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss")):
        t = t.replace(a, b)
    return re.sub(r"[^a-z0-9]", "", t)


def _keep(ch: str) -> int:
    """Zeichen -> Laenge in der Kurzform (Umlaute zaehlen doppelt)"""
    f = _fold(ch)
    return len(f)


def page_lines(pages: list[str]) -> list[tuple[int, str]]:
    """Seiten -> [(Seite, Zeile)] ohne Fusszeile des Verkuendungsblatts und ohne Seitenzahlen"""
    from app.study_catalog import normalize_lines
    out = []
    for i, p in enumerate(pages):
        for line in normalize_lines(FOOTER_RE.sub("\n", p or "")):
            if re.fullmatch(r"[0-9]{1,3}", line):
                continue
            out.append((i + 1, line))
    return out


# --------------------------------------------------------------------------------------------------------------------
# Feldnamen
# --------------------------------------------------------------------------------------------------------------------

# Feld -> Feldnamen (Klartext; verglichen in der Kurzform). Kurze, mehrdeutige Namen gelten nur mit ":" oder am
# Zeilenende (SHORT).
LABELS: list[tuple[str, list[str]]] = [
    ("title", ["Modultitel", "Teilmodultitel", "Modulbezeichnung", "Titel des Moduls", "Modulname", "Bezeichnung"]),
    ("code", ["Modulnummer", "Modul-Nummer", "Modulkennung", "Modulcode", "Modulkürzel"]),
    ("lead", ["ModulleiterIn", "Modulleiter/in", "Modulleiterin", "Modulleiter", "Modulleitung", "Modulverantwortliche/-r",
              "Modulverantwortliche/r", "Modulverantwortlicher", "Modulverantwortliche", "Modulverantwortlich",
              "Modulbeauftragte"]),
    ("goals", ["Kompetenz- und Lernziele", "Kompetenzen und Lernziele", "Kompetenzen- und Qualifikationsziele",
               "Qualifikations- und Kompetenzziele", "Qualifikationsziele", "Lernziele/Kompetenzen", "Lernziele",
               "Kompetenzziele", "Lernergebnisse", "Qualifikations- & Kompetenzziele", "Kompetenzen"]),
    ("usage", ["Verwendbarkeit des Moduls", "Verwendbarkeit", "Verwendung des Moduls"]),
    ("kind", ["Pflicht- oder Wahlpflichtmodul", "Pflicht- oder Wahlpflicht-modul", "Pflicht-/Wahlpflichtmodul",
              "Pflicht- / Wahlpflichtmodul", "Modultyp", "Art des Moduls", "Status des Moduls", "Modulart"]),
    ("forms", ["Lehr- und Lernformen", "Lehr-/Lernformen", "Lehrformen", "Lehrveranstaltungen", "Lehr- und Lernform",
               "Lehrveranstaltungsformen", "Teilmodule / Lehrformen", "Teilmodule"]),
    ("content", ["Lehrinhalte", "Lerninhalte", "Inhalte des Moduls", "Inhaltliche Beschreibung", "Inhalte", "Inhalt"]),
    ("sws", ["Semesterwochenstunden", "SWS"]),
    ("prereq", ["Zugangsvoraussetzungen", "Teilnahmevoraussetzungen", "Voraussetzungen für die Teilnahme",
                "Voraussetzung für die Teilnahme am Modul", "Voraussetzung für die Teilnahme",
                "Voraussetzungen für die Teilnahme am Modul", "Empfohlene Voraussetzungen", "Voraussetzungen"]),
    ("lp", ["Anzahl der Leistungspunkte", "Anzahl Leistungspunkte", "Leistungspunkte (LP)", "Leistungspunkte",
            "Kreditpunkte", "ECTS-Punkte", "Credits", "LP"]),
    ("workload", ["Workload getrennt nach Präsenzstudium und Selbststudium", "Workload, getrennt nach Präsenz- und Selbststudium",
                  "Workload getrennt nach Präsenz- und Selbststudium", "Workload", "Arbeitsaufwand", "Studentischer Arbeitsaufwand"]),
    ("duration", ["Dauer in Semestern", "Dauer des Moduls", "Moduldauer / Empfohlenes Semester", "Moduldauer", "Dauer"]),
    ("freq", ["Häufigkeit des Angebots", "Angebotshäufigkeit", "Angebotsturnus", "Turnus", "Häufigkeit"]),
    ("semester", ["Empfohlenes Studiensemester", "Empfohlenes Fachsemester", "Empfohlenes Semester", "Studiensemester",
                  "Semesterlage", "Studienabschnitt"]),
    ("admission", ["Voraussetzungen für die Zulassung zur Prüfung", "Voraussetzung für die Zulassung zur Prüfung",
                   "Voraussetzung für die Zulassung zur Modulprüfung", "Voraussetzungen für die Zulassung zur Modulprüfung",
                   "Prüfungsvorleistungen", "Prüfungsvorleistung"]),
    ("exam", ["Prüfungsleistungen (Art, Umfang)", "Prüfungsleistung (Art, Umfang)", "Art und Umfang von Prüfungsleistungen (benotet)",
              "Art und Umfang von Prüfungsleistungen", "Art und Umfang der Prüfungsleistungen", "Art und Umfang der Prüfungsleistung",
              "Prüfungsleistungen", "Prüfungsleistung", "Prüfungsformen", "Prüfungsform", "Prüfungsart/-form", "Prüfungsart",
              "Art der Prüfung"]),
    ("coursework", ["Studienleistungen (Art und Umfang)", "Studienleistung (Art und Umfang)", "Art von Studienleistungen (unbenotet)",
                    "Art von Studienleistungen", "Art und Umfang von Studienleistungen", "Studienleistungen", "Studienleistung"]),
    ("language", ["Unterrichts- und Prüfungssprache", "Lehr- und Prüfungssprache", "Unterrichtssprache", "Lehrsprache", "Sprache"]),
    ("board", ["Zuständige Ständige Prüfungskommission", "Zuständige Prüfungskommission", "Ständige Prüfungskommission",
               "Prüfungskommission"]),
    ("literature", ["Literatur", "Literaturhinweise"]),
    ("remarks", ["Bemerkungen", "Bemerkung", "Hinweise", "Hinweis", "Sonstiges", "Weitere Informationen"]),
]
SHORT = 10
_LABEL_KEYS = sorted(((_fold(n), k) for k, names in LABELS for n in names), key=lambda x: -len(x[0]))
HEAD_KEYS = ("title", "code", "lead")
FACT_KEYS = ("goals", "usage", "kind", "forms", "content", "prereq", "lp", "workload", "duration", "freq", "semester",
             "admission", "exam", "coursework", "language", "board", "literature")

# Titelzeilen ("Basismodul (BM) 1: ...", "Modul G: ...", "Modul „...“", "Theoriemodul ...")
TITLE_START_RE = re.compile(r"^(?:Modultitel|Teilmodultitel|Modul\b|Module\b|[A-ZÄÖÜ][\wäöüß-]*modul(?:e)?\b|"
                            r"(?:BM|AM|VM|PM|WPM|M)\s?[0-9]+[a-z]?\b|Bachelorarbeit|Masterarbeit|Praxisphase|Praktikum\b)")
AREA_RE = re.compile(r"^(?:[0-9]+(?:\.[0-9]+)*\.?\s+)?(?:Module (?:des|der|im) [\wäöüÄÖÜß -]+(?::\s*.+)?|"
                     r"(?:Pflicht|Wahlpflicht|Wahl|Profil|Professionalisierungs|Schwerpunkt|Studien|Ergänzungs|"
                     r"Vertiefungs|Kern|Basis|Aufbau|Grundlagen)bereich\b.*|(?:Pflicht|Wahlpflicht|Wahl)module\b.*)$")
ANLAGE_RE = re.compile(r"^Anlage\s*[0-9]*\s*[a-z]?\s*[-–:.]?\s*(?:\(?\s*)?(?:Modulhandbuch|Modulbeschreibung|Modulbeschreibungen)\b", re.I)


def _label_at(lines: list[str], i: int) -> tuple[str, int, int] | None:
    """Feldname am Anfang von Zeile i (auch ueber bis zu drei Zeilen umgebrochen) -> (Feld, Endzeile, Spalte nach dem
    Feldnamen samt ':'/'*'), sonst None"""
    window = lines[i:i + 3]
    if not window or not window[0][:1].isalpha():
        return None                                        # "(LP):", "- Kontaktstunden": Fortsetzung, kein Feldname
    folded = _fold(" ".join(window))
    for key, field in _LABEL_KEYS:
        if not folded.startswith(key):
            continue
        # Position im Original nach len(key) Zeichen der Kurzform
        need, li, col = len(key), 0, 0
        while need > 0 and li < len(window):
            line = window[li]
            if col >= len(line):
                li, col = li + 1, 0
                continue
            need -= _keep(line[col])
            col += 1
        if need > 0 or li >= len(window):
            continue
        line = window[li]
        nxt = line[col:col + 1]
        if nxt and (nxt.isalnum()) and not line[col - 1:col] in ("-", "/"):
            continue                                       # Wortgrenze: "Inhaltlich", "Prüfungsformen" (laengerer Name)
        rest = line[col:]
        m = re.match(r"\s*[)\]]?\s*\*?\s*(?:\([^)]{0,40}\))?\s*\*?\s*:?\s*", rest)
        after = rest[m.end():] if m else rest
        if len(key) < SHORT and not (rest.lstrip(" *").startswith(":") or not after.strip()):
            continue                                       # kurzer Name nur mit ':' oder allein
        return field, i + li, col + (m.end() if m else 0)
    return None


def _first_int(v: str | None, lo: int = 1, hi: int = 20) -> int | None:
    for m in re.finditer(r"(?<![0-9.,])([0-9]{1,2})(?![0-9])", v or ""):
        n = int(m.group(1))
        if lo <= n <= hi:
            return n
    return None


def _lp(v: str | None):
    m = re.search(r"(?<![0-9.,])([0-9]{1,3}(?:[.,][0-9])?)(?![0-9])", v or "")
    if not m:
        return None
    x = number(m.group(1))
    return x if 0 < x <= 120 else None


def _workload(v: str | None, lp=None):
    t = v or ""
    m = re.search(r"(?:Gesamt|gesamt|insgesamt|Insgesamt|Summe|total|Total)\D{0,15}?([0-9]{2,4})", t)
    if m:
        return number(m.group(1))
    hours = [number(x) for x in re.findall(r"([0-9]{1,4}(?:[.,][0-9])?)\s*(?:h\b|Std\b|Std\.|Stunden|hours)", t)]
    hours = [h for h in hours if h > 0]
    if not hours:
        return None
    if lp and len(hours) >= 2 and abs(sum(hours[:2]) - lp * 30) <= lp * 6:
        return sum(hours[:2])
    if lp and abs(max(hours) - lp * 30) <= lp * 6:
        return max(hours)
    return hours[0] if len(hours) == 1 else (sum(hours[:2]) if hours[0] < hours[1] * 3 else hours[0])


def _kind(v: str | None) -> str | None:
    t = (v or "").lower()
    if not t.strip():
        return None
    head = t.strip(" :.-")[:40]
    if head.startswith("pflicht") and "wahlpflicht" not in head:
        return "pflicht"
    if "wahlpflicht" in t or "wahl-pflicht" in t:
        return "wahlpflicht"
    if re.search(r"\bwahl(?:modul)?\b", t):
        return "wahl"
    if "pflicht" in t:
        return "pflicht"
    return None


def _short(v: str | None, limit: int = 200) -> str | None:
    t = re.sub(r"\s+", " ", v or "").strip(" ;,:")
    if t.lower().strip(" .") in NONE_VALUES or t.lower().startswith("s.o") or t.lower().startswith("s. o"):
        return None
    return clip(t, limit)


def _clean_title(t: str) -> str:
    t = re.sub(r"\s+", " ", t or "").strip()
    t = re.sub(r"^Anlage\s*[0-9]*\s*[-–:.]?\s*Modul\w*\s*:?\s*", "", t)
    t = re.sub(r"^(?:Modultitel|Teilmodultitel|Modulbezeichnung|Bezeichnung)\s*\*?\s*:?\s*", "", t)
    t = re.sub(r"^Modul\s*[„\"“”]\s*", "", t)
    t = t.replace("„", "").replace("“", "").replace("”", "").replace('"', "")
    t = re.sub(r"\s*\*+$", "", t)
    # Silbentrennung am Zeilenende ("Labor- praktikum" -> "Laborpraktikum", aber "Natur- und" bleibt)
    t = re.sub(r"([a-zäöüß])- (?!und\b|oder\b|bzw\b)([a-zäöüß])", r"\1\2", t)
    return t.strip(" :.-–")


FINAL_TITLE_RE = re.compile(r"\b(?:Bachelor|Master)-?[Aa]rbeit\b|^Abschlussmodul\b|^Abschlussprüfung\b")


def _area_from_title(t: str) -> str | None:
    m = re.match(r"^(Basis|Aufbau|Vertiefungs|Projekt|Theorie|Praxis|Wahlpflicht|Pflicht|Abschluss|Profil|Schwerpunkt|"
                 r"Ergänzungs|Grundlagen|Kern|Forschungs|Methoden|Studien|Spezialisierungs|Orientierungs)modul", t)
    if m:
        return m.group(1) + "module"
    return None


# --------------------------------------------------------------------------------------------------------------------
# hildesheim-modulbeschreibung
# --------------------------------------------------------------------------------------------------------------------

def _hits(lines: list[str], start: int = 0) -> list[tuple[int, str, int, int]]:
    """Alle Feldnamen ab Zeile `start`: [(Zeile, Feld, Endzeile, Spalte)]"""
    out = []
    i = start
    while i < len(lines):
        h = _label_at(lines, i)
        if h and out and out[-1][1] == h[0] and h[0] not in HEAD_KEYS and i - out[-1][2] <= 2:
            i = h[1] + 1                                   # derselbe Feldname gleich danach: Fortsetzung
            continue
        if h:
            out.append((i, h[0], h[1], h[2]))
            i = h[1] + 1
        else:
            i += 1
    return out


def _title_start(lines: list[str], i: int, floor: int) -> int:
    """Zeile, in der der Titel vor dem Modulkopf in Zeile i beginnt (hoechstens drei Zeilen zurueck, nicht vor floor)"""
    for j in range(i - 1, max(floor, i - 4) - 1, -1):
        if AREA_RE.match(lines[j]) or ANLAGE_RE.match(lines[j]):
            return j + 1 if j + 1 < i else i - 1          # Bereichsueberschrift gehoert nicht zum Titel
        if TITLE_START_RE.match(lines[j]) and not _label_at(lines, j):
            return j
    return i - 1 if i - 1 >= floor else i


def _value(lines: list[str], hit, end: int) -> str:
    _, _, li, col = hit
    parts = [lines[li][col:]] + lines[li + 1:end]
    return "\n".join(p for p in parts if p is not None).strip()


def parse_modulbeschreibung(pages: list[str], meta: dict, require_facts: bool = False) -> tuple[dict, dict]:
    pl = page_lines(pages)
    lines = [l for _, l in pl]
    pages_of = [p for p, _ in pl]
    start = next((i for i, l in enumerate(lines) if ANLAGE_RE.match(l)), 0)
    # das letzte "Anlage ... Modulhandbuch" (das erste steht oft im Inhaltsverzeichnis oder in § 5)
    anl = [i for i, l in enumerate(lines) if ANLAGE_RE.match(l)]
    if anl:
        later = [i for i in anl if any(_label_at(lines, j) and _label_at(lines, j)[0] in HEAD_KEYS
                                         for j in range(i + 1, min(len(lines), i + 12)))]
        start = later[0] if later else anl[-1]
    hits = _hits(lines, start)

    # Module abgrenzen
    modules: list[dict] = []
    cur = None
    for h in hits:
        field = h[1]
        if field in HEAD_KEYS:
            new = cur is None or field in cur["fields"] or (field in ("title", "code") and cur["facts"])
            if field == "lead" and cur is not None and cur["facts"] and "lead" not in cur["fields"] and "code" in cur["fields"]:
                new = False                                # Modulleitung am Ende des Moduls (Sozialpaedagogik)
            if field == "lead" and cur is not None and "lead" not in cur["fields"] and cur["facts"] and "code" not in cur["fields"] \
                    and "title" not in cur["fields"]:
                new = False
            if new:
                cur = {"head": h, "fields": {}, "hits": [], "facts": False}
                modules.append(cur)
        if cur is None:
            continue
        cur["hits"].append(h)
        cur["fields"].setdefault(field, h)
        if field in FACT_KEYS:
            cur["facts"] = True
    # Titelzeilen und Grenzen
    floor = start
    for k, m in enumerate(modules):
        first = m["hits"][0][0]
        if "title" in m["fields"] and m["fields"]["title"][0] == first:
            m["start"] = first
        else:
            m["start"] = _title_start(lines, first, floor)
        floor = first + 1
    for k, m in enumerate(modules):
        m["end"] = modules[k + 1]["start"] if k + 1 < len(modules) else len(lines)

    raw = []
    area = None
    prev_end = start
    for m in modules:
        # Bereichsueberschriften zwischen den Modulen ("Module des Faches ...", "Wahlpflichtbereich ...")
        for j in range(prev_end, m["start"]):
            if AREA_RE.match(lines[j]) and len(lines[j]) <= 90 and not lines[j].endswith("."):
                area = re.sub(r"^[0-9]+(?:\.[0-9]+)*\.?\s+", "", lines[j]).strip(" :")
        prev_end = m["start"]
        hs = [h for h in m["hits"] if h[0] < m["end"]]
        vals: dict = {}
        for n, h in enumerate(hs):
            end = hs[n + 1][0] if n + 1 < len(hs) else m["end"]
            v = _value(lines, h, end)
            if v.strip(" :*") or h[1] not in vals:
                if not vals.get(h[1]):
                    vals[h[1]] = v
        if "title" in vals and vals["title"]:
            title = vals["title"].split("\n")[0] if len(vals["title"]) > 120 else vals["title"]
        else:
            title = " ".join(lines[m["start"]:m["hits"][0][0]])
        title = _clean_title(title)
        if not title or title.lower().startswith("teilmodul") or len(title) > 200 or JUNK_TITLE_RE.search(title):
            continue
        if raw and _same_title(raw[-1]["title"], title):
            _merge_into(raw[-1], vals, pages_of[m["start"]] if m["start"] < len(pages_of) else None)
            continue
        lp = _lp(vals.get("lp"))
        if lp is None:
            m_lp = re.search(r"(?<![0-9.,])([0-9]{1,2}(?:[.,]5)?)\s*(?:LP|ECTS|Leistungspunkte|CP)\b", vals.get("workload") or "")
            lp = number(m_lp.group(1)) if m_lp else None
        wl = _workload(vals.get("workload"), lp)
        if require_facts and lp is None and not vals.get("exam") and not vals.get("coursework") and not vals.get("semester") \
                and not vals.get("kind"):
            continue                                       # Zeile einer Moduluebersicht, keine Beschreibung
        if lp is None and wl and wl % 30 == 0 and 30 <= wl <= 900:
            lp = wl / 30                                   # Hildesheim: 30 Stunden je LP
            lp = int(lp) if lp == int(lp) else lp
        code = _short((vals.get("code") or "").split("\n")[0], 60)
        raw.append({
            "title": title, "code": code,
            "area": _area_from_title(title) or area,
            "kind": "abschluss" if FINAL_TITLE_RE.search(title) else _kind(vals.get("kind")),
            "lp": lp, "semester": _first_int(vals.get("semester")),
            "turnus": turnus_of(vals.get("freq")),
            "exam": _short(vals.get("exam")), "coursework": _short(vals.get("coursework")),
            "prereq": vals.get("prereq") or "", "language": language_of(vals.get("language")) if vals.get("language") else None,
            "workload_h": wl,
            "page": pages_of[m["start"]] if m["start"] < len(pages_of) else None,
            "content": text_join((vals.get("content") or "").split("\n")),
            "goals": text_join((vals.get("goals") or "").split("\n")),
            "literature": text_join((vals.get("literature") or "").split("\n")),
        })
    return build_catalog(meta, raw)


JUNK_TITLE_RE = re.compile(r"^[0-9]+\s+[A-ZÄÖÜ]|Modulbeauftragte|hauptamtlich Lehrende|^Verkündungsblatt|^Anlage\b|^Seite\b")


def _same_title(a: str, b: str) -> bool:
    fa, fb = _fold(a), _fold(b)
    return bool(fa) and bool(fb) and (fa == fb or (len(fb) >= 12 and fa.endswith(fb)) or (len(fa) >= 12 and fb.endswith(fa)))


def _merge_into(rec: dict, vals: dict, page) -> None:
    """Fortsetzung desselben Moduls (Tabellenkopf auf der Folgeseite wiederholt): fehlende Fakten ergaenzen"""
    lp = rec.get("lp") or _lp(vals.get("lp"))
    more = {"lp": _lp(vals.get("lp")), "semester": _first_int(vals.get("semester")), "turnus": turnus_of(vals.get("freq")),
            "exam": _short(vals.get("exam")), "coursework": _short(vals.get("coursework")),
            "language": language_of(vals.get("language")) if vals.get("language") else None,
            "workload_h": _workload(vals.get("workload"), lp), "kind": _kind(vals.get("kind")),
            "code": _short((vals.get("code") or "").split("\n")[0], 60)}
    for k, v in more.items():
        if v is not None and rec.get(k) in (None, "", "unbekannt"):
            rec[k] = v
    if not rec.get("prereq") and vals.get("prereq"):
        rec["prereq"] = vals["prereq"]
    for k, src in (("content", "content"), ("goals", "goals"), ("literature", "literature")):
        if not rec.get(k) and vals.get(src):
            rec[k] = text_join(vals[src].split("\n"))


# --------------------------------------------------------------------------------------------------------------------
# hildesheim-it-modulhandbuch
# --------------------------------------------------------------------------------------------------------------------

IT_LABELS: list[tuple[str, list[str]]] = [
    ("lead", ["Modulverantwortliche(r)", "Modulverantwortlicher", "Modulverantwortliche", "Responsible Instructors",
              "Responsible", "Lehrende", "Dozent(in)"]),
    ("forms", ["Lehrform/SWS", "Type"]),
    ("lp", ["Leistungspunkte", "Credit Points"]),
    ("workload", ["Arbeitsaufwand", "Workload"]),
    ("goals", ["Lernziele/Kompetenzen", "Learning goals/ Competencies", "Learning goals/Competencies"]),
    ("content", ["Lehrinhalte", "Content"]),
    ("sub", ["Teilmodule", "Submodules"]),
    ("literature", ["Literatur", "Literature"]),
    ("prereq", ["Voraussetzungen für die Teilnahme", "Requirements"]),
    ("exam", ["Prüfungsleistung", "Exam"]),
    ("coursework", ["Studienleistung", "Coursework"]),
    ("semester", ["empfohlenes Semester", "Recommended Term"]),
    ("freq", ["Turnus", "Turn"]),
    ("duration", ["Dauer des Moduls", "Duration"]),
    ("usage", ["Verwendung", "Use"]),
    ("language", ["Sprache", "Language"]),
    ("remarks", ["Bemerkungen", "Remarks", "Anmerkungen"]),
]
_IT_KEYS = sorted(((_fold(n), k, n) for k, names in IT_LABELS for n in names), key=lambda x: -len(x[0]))
IT_MODULE_RE = re.compile(r"^(?:Modul|Module):\s*(.+)$")
TOC_HEAD_RE = re.compile(r"^(?:Modul Lehrform/SWS LP S\.|Module Type/HPW CPs P ?\.)$")
TOC_ENTRY_END_RE = re.compile(r"(?:^|\s)([0-9]{1,3})$")
TOP_RE = re.compile(r"^(?:Pflichtmodule|Pflichtbereich|Wahlmodule im|Wahlbereich|Wahlpflichtbereich|Weitere Module je Bereich|"
                    r"Compulsory|Elective|Master Thesis|Thesis)", re.I)


def _it_label(lines: list[str], i: int) -> tuple[str, int, int] | None:
    """Feldname am Zeilenanfang (die Vorlage setzt ihn links, der Wert folgt in derselben Zeile; lange Namen brechen
    um: "Voraussetzungen fuer die / Teilnahme", "Learning goals/ Compe- / tencies")"""
    window = lines[i:i + 2]
    folded = _fold(" ".join(window))
    for key, field, name in _IT_KEYS:
        if not folded.startswith(key):
            continue
        need, li, col = len(key), 0, 0
        while need > 0 and li < len(window):
            line = window[li]
            if col >= len(line):
                li, col = li + 1, 0
                continue
            need -= _keep(line[col])
            col += 1
        if need > 0 or li >= len(window):
            continue
        line = window[li]
        nxt = line[col:col + 1]
        if nxt and nxt.isalnum():
            continue
        if li == 0 and " " not in name and len(key) < 8 and not line[col:].strip() and field not in ("usage", "literature"):
            continue                                       # "Type" / "Turn" allein in einer Zeile: Fliesstext
        return field, i + li, col
    return None


def _it_degree(text: str) -> str | None:
    if re.search(r"Bachelor|\bBSc\b", text):
        return "B"
    if re.search(r"Master|\bMSc\b", text):
        return "M"
    return None


def _it_degrees(text: str) -> set:
    out = set()
    if re.search(r"Bachelor|\bBSc\b|\bB\.\s?Sc\b", text or ""):
        out.add("B")
    if re.search(r"Master|\bMSc\b|\bM\.\s?Sc\b", text or ""):
        out.add("M")
    return out


def _toc(lines: list[str]) -> list[dict]:
    """Verzeichnis: [{top, area, page}] je Eintrag (Seite = Seitenzahl im Handbuch). Ueberschriften vor einer
    Tabelle: oberste Ebene (TOP_RE, z. B. "Wahlbereich Bachelor"), mittlere ("Informatik", "Weitere Wahlmodule anderer
    Faecher") und "Gebiet ..."."""
    out = []
    pending: list[str] = []
    top = mid = leaf = None
    seen_tops: set = set()
    in_table = False
    for line in lines:
        first = line.startswith("\x00")                    # erste Zeile einer Seite (lebender Kolumnentitel?)
        line = line.lstrip("\x00")
        if IT_MODULE_RE.match(line):
            break
        if first and TOP_RE.match(line) and line in seen_tops:
            continue                                       # Kolumnentitel wiederholt einen schon gesehenen Abschnitt
        if TOC_HEAD_RE.match(line):
            for h in pending:
                if re.fullmatch(r"[0-9]+", h):
                    continue
                if TOP_RE.match(h):
                    top, mid, leaf = h, None, None
                    seen_tops.add(h)
                elif h.startswith(("Gebiet", "Area")):
                    leaf = h
                else:
                    mid, leaf = h, None
            pending, in_table = [], True
            continue
        m = TOC_ENTRY_END_RE.search(line)
        if in_table and m and (re.search(r"\b(?:SWS|HPW|LP|CPs?)\b|[0-9]+\s+[0-9]+$|Praktikum|Abschlussarbeit|Thesis|"
                                         r"Unternehmen", line) or pending):
            area = " – ".join(x for x in (mid, leaf) if x) or None
            out.append({"top": top, "area": area, "page": int(m.group(1))})
            pending = []
            continue
        pending.append(line)
        if len(pending) > 6:
            pending = pending[-6:]
    return out


def parse_it(pages: list[str], meta: dict) -> tuple[dict, dict]:
    """FB4-Modulhandbuch -> Katalog des Abschlusses aus meta (B.Sc./M.Sc.)"""
    from app.study_catalog import normalize_lines
    want = "M" if str(meta.get("degree") or "").upper().startswith("M") else "B"
    per_page: list[list[str]] = []
    page_no: list[int | None] = []
    for p in pages:
        raw = normalize_lines(FOOTER_RE.sub("\n", p or ""))
        num = None
        if raw and re.fullmatch(r"[0-9]{1,3}", raw[-1]):
            num = int(raw[-1])
            raw = raw[:-1]
        per_page.append(raw)
        page_no.append(num)
    if sum(1 for n in page_no if n is not None) < len(pages) / 2:
        page_no = list(range(1, len(pages) + 1))          # ohne gedruckte Seitenzahlen: Seite im Handbuch = PDF-Seite
    all_lines = [("\x00" + l if li == 0 else l) for pg in per_page for li, l in enumerate(pg)]
    toc = _toc(all_lines)

    # Module: Startseite, Titel, Felder
    mods: list[dict] = []
    for pi, pg in enumerate(per_page):
        for li, line in enumerate(pg):
            m = IT_MODULE_RE.match(line)
            if not m:
                continue
            title = m.group(1).strip()
            if li + 1 < len(pg) and not _it_label(pg, li + 1) and not re.search(r"[0-9]$", title) and title.endswith("-"):
                title = title[:-1] + pg[li + 1]
            elif li + 1 < len(pg) and not _it_label(pg, li + 1) and len(pg[li + 1]) < 60 and title.endswith(("-", "und", "and", "für", "for", "of")):
                title = title + " " + pg[li + 1]
            header = pg[0] if li > 0 else ""
            mods.append({"title": title, "page_index": pi, "line": li, "page_no": page_no[pi], "header": header,
                         "pre": pg[:li]})
    # Text je Modul (bis zum naechsten Modul), ohne Kopfzeile der Folgeseiten
    flat: list[tuple[int, str]] = []
    starts_on = {}
    for m in mods:
        starts_on.setdefault(m["page_index"], m)
    active = None
    for pi, pg in enumerate(per_page):
        skip = 0
        if pi in starts_on:
            skip = starts_on[pi]["line"]                   # Startseite: Abschnittszeilen vor "Modul:" gehoeren zu keinem Modul
        elif active is not None and pg and "–" in pg[0]:
            # Kolumnentitel "Bereich – Gebiet – <Modultitel>" (auch ueber zwei, drei Zeilen umgebrochen)
            skip = 1
            for k in (1, 2, 3):
                if _fold(" ".join(pg[:k])).endswith(_fold(active["title"])[-40:]):
                    skip = k
                    break
        for li, line in enumerate(pg):
            if li < skip:
                continue
            flat.append((pi, line))
        for m in mods:
            if m["page_index"] == pi:
                active = m
    starts = []
    k = 0
    for idx, (pi, line) in enumerate(flat):
        if k < len(mods) and pi == mods[k]["page_index"] and IT_MODULE_RE.match(line):
            starts.append(idx)
            k += 1
    raw_by_page: dict[int, dict] = {}
    order: list[dict] = []
    for n, m in enumerate(mods[:len(starts)]):
        a = starts[n] + 1
        b = starts[n + 1] if n + 1 < len(starts) else len(flat)
        body = [l for _, l in flat[a:b]]
        vals: dict = {}
        i = 0
        cur = None
        while i < len(body):
            h = _it_label(body, i)
            if h:
                cur = h[0]
                vals.setdefault(cur, [])
                if h[0] in vals and vals[cur]:
                    cur = cur + "#"                        # zweites Vorkommen (Fliesstext): nicht mischen
                    vals.setdefault(cur, [])
                vals[cur].append(body[h[1]][h[2]:].strip())
                i = h[1] + 1
                continue
            if cur:
                vals[cur].append(body[i])
            i += 1
        v = {k2: "\n".join(x for x in v2 if x).strip() for k2, v2 in vals.items()}
        lp = _lp(v.get("lp"))
        sem_text = v.get("semester") or ""
        rec = {
            "title": re.sub(r"\s+", " ", m["title"]).strip(), "code": None, "area": None, "kind": None, "lp": lp,
            "semester": _first_int(re.sub(r"\b[BM]Sc\b", "", sem_text)),
            "turnus": turnus_of(v.get("freq")),
            "exam": _short(v.get("exam")), "coursework": _short(v.get("coursework")),
            "prereq": v.get("prereq") or "", "language": language_of(v.get("language")) if v.get("language") else None,
            "workload_h": _workload(v.get("workload"), lp) if v.get("workload") else (lp * 30 if lp else None),
            "page": m["page_index"] + 1,
            "content": text_join((v.get("content") or "").split("\n")),
            "goals": text_join((v.get("goals") or "").split("\n")),
            "literature": text_join((v.get("literature") or "").split("\n")),
            "_sem_degree": _it_degrees(sem_text), "_header": m["header"], "_pre": m["pre"],
            "_usage": _usage_items(v.get("usage") or ""),
        }
        if m["page_no"] is not None:
            raw_by_page.setdefault(m["page_no"], rec)
        order.append(rec)

    raw = []
    used = set()
    prefix = meta.get("usage_program")
    if prefix:
        # Studiengang ohne eigenes Handbuch (Wirtschaftsinformatik): Module, deren "Verwendung" ihn nennt
        pf = _fold(prefix)
        for rec in order:
            for item in rec["_usage"]:
                if not _fold(item).startswith(pf):
                    continue
                rest = item[len(prefix):] if item.startswith(prefix) else item.split("–", 1)[-1]
                area = re.sub(r"^\s*[–-]\s*", "", rest).strip()
                r = dict(rec)
                r["area"] = clip(area, 200) or None
                r["kind"] = _it_kind(area, rec["title"])
                raw.append(r)
    elif toc:
        for e in toc:
            rec = raw_by_page.get(e["page"])
            top = e["top"] or ""
            if rec is None:
                continue
            deg = _it_degree(top)
            sem = rec["_sem_degree"]
            if deg is None or (sem and deg not in sem):
                deg = "M" if sem == {"M"} else ("B" if sem == {"B"} else deg)   # empfohlenes Semester "MSc 1-3" gilt
            if deg != want:
                continue
            area = top if not e["area"] else (f"{top} – {e['area']}" if top else e["area"])
            r = dict(rec)
            r["area"] = clip(area, 200)
            r["kind"] = _it_kind(f"{top} – {e['area'] or ''}", rec["title"])
            raw.append(r)
            used.add(id(rec))
    else:
        for rec in order:
            path = [x.strip() for x in (rec["_header"] or " – ".join(rec["_pre"])).split("–")]
            path = [p for p in path if p and p != rec["title"]]
            deg = _it_degree(" ".join(path)) or (next(iter(rec["_sem_degree"])) if len(rec["_sem_degree"]) == 1 else None)
            if deg is not None and deg != want:
                continue
            r = dict(rec)
            r["area"] = clip(" – ".join(path), 200) if path else None
            r["kind"] = _it_kind(path[0] if path else "", rec["title"])
            raw.append(r)
    for r in raw:
        for k2 in ("_sem_degree", "_header", "_pre", "_usage"):
            r.pop(k2, None)
    return build_catalog(meta, raw)


def _usage_items(text: str) -> list[str]:
    """Feld "Verwendung": Aufzaehlung mit "•" -> Eintraege, Zeilenumbrueche und Silbentrennung zusammengefuegt"""
    items, cur = [], []
    for line in (text or "").split("\n"):
        line = line.strip()
        if line.startswith("•"):
            if cur:
                items.append(cur)
            cur = [line.lstrip("• ").strip()]
        elif cur:
            cur.append(line)
    if cur:
        items.append(cur)
    out = []
    for parts in items:
        t = ""
        for x in parts:
            if t.endswith("-") and x[:1].islower():
                t = t[:-1] + x
            else:
                t = (t + " " + x).strip()
        out.append(re.sub(r"\s+", " ", t))
    return out


def _it_kind(top: str, title: str) -> str:
    t = (top or "").lower()
    if re.search(r"abschluss|thesis", t) or re.match(r"^(Abschlussprüfung|Master Thesis|Bachelorarbeit|Masterarbeit)", title):
        return "abschluss"
    if re.search(r"pflicht|compulsory|forschungsmethodik", t) and "wahl" not in t:
        return "pflicht"
    return "wahlpflicht"


# Formate, deren Leser Seitentexte im Layout-Modus brauchen (Builder und Register waehlen damit die Textgewinnung)
LAYOUT_FORMATS = ("hildesheim-modultabelle",)


def pages_for(fmt: str, data: bytes) -> list[str]:
    """Seitentexte fuer ein Format: Layout-Modus fuer die Modultabellen, sonst wie app.study_catalog.pdf_pages"""
    if fmt in LAYOUT_FORMATS:
        return layout_pages(data)
    from app.study_catalog import pdf_pages
    return pdf_pages(data)


# --------------------------------------------------------------------------------------------------------------------
# hildesheim-modultabelle (Fachbereiche 2 und 3, Erziehungswissenschaft)
# --------------------------------------------------------------------------------------------------------------------
#
# Zweispaltige Modultabellen, deren Zeilen pypdf im normalen Modus ineinander schiebt. Gelesen wird im Layout-Modus
# (`layout_pages`, Spalten bleiben erhalten): links der Feldname (umbrochen, z. B. "Studienleistun- / gen",
# "Präsenz des Mo- / duls im Studien- / angebot"), rechts der Wert. Daraus werden Zeilen "Feldname: Wert" gebaut und
# mit dem Leser `hildesheim-modulbeschreibung` gelesen. Dazu:
#   - Titelzeilen "Modul 2.1b" + "Das literarische Feld" bzw. "Modul SuT 5: ..." -> "Modultitel: ..."
#   - FB 3 (IKUe): Kopfzeile "Studiensemester | Dauer des Moduls | Häufigkeit des Angebots | Status Modul" mit den Werten
#     in den Zeilen darunter (Spalten aus der Kopfzeile) und die Zeile "Modul Gesamt ... 150h 360h 10 17"
#     (Kontaktzeit, Selbststudium, SWS, LP) in der Tabelle "Lehr-/Lernformen; Arbeitsaufwand"
#   - Fettdruck als vierfach wiederholte Zeichen ("MMMMoooodddduuuullll") wird zusammengezogen.

TABLE_LABELS: list[tuple[str, list[str]]] = [
    ("kind", ["Kennzeichnung", "Status Modul", "Status"]),
    ("coursework", ["Leistungsnachweise Studium", "Studienleistungen (unbenotet)"]),
    ("exam", ["Leistungsnachweise Prüfung", "Modulprüfungsleistungen", "Modulprüfungsleistung", "Modulprüfung", "Prüfungsleistungen (benotet)",
              "Voraussetzung für die Vergabe von ECTS-Leistungspunkten", "Voraussetzungen für die Vergabe von Leistungspunkten"]),
    ("freq", ["Präsenz des Moduls im Studienangebot", "Häufigkeit / Turnus"]),
    ("lead", ["Verantwortlich", "Modulverantwortliche"]),
    ("usage", ["Verflechtung"]),
    ("workload", ["Kontaktstunden (h)", "Selbststudium (h)", "Gesamt (h)", "Lehr-/Lernformen; Arbeitsaufwand"]),
    ("remarks", ["Bemerkungen / Voraussetzungen", "Stellenwert der Note für die Endnote"]),
]
_TABLE_KEYS = sorted({_fold(n) for _, names in LABELS + TABLE_LABELS for n in names}, key=len, reverse=True)
for _f, _names in TABLE_LABELS:
    for _n in _names:
        if (_fold(_n), _f) not in _LABEL_KEYS:
            _LABEL_KEYS.append((_fold(_n), _f))
_LABEL_KEYS.sort(key=lambda x: -len(x[0]))
TABLE_TITLE_RE = re.compile(r"^(?:Modul|Module)\s+[A-ZÄÖÜa-z]{0,8}\s?[0-9]+(?:\.[0-9]+)*[a-z]?\b.*$")
BOLD_RE = re.compile(r"(\S)\1\1\1")


def layout_pages(data: bytes) -> list[str]:
    """PDF -> Seitentexte im Layout-Modus (Spalten erhalten)"""
    import io
    from pypdf import PdfReader
    out = []
    for p in PdfReader(io.BytesIO(data)).pages:
        try:
            out.append(p.extract_text(extraction_mode="layout") or "")
        except Exception:  # noqa: BLE001
            out.append("")
    return out


def _unbold(line: str) -> str:
    if len(BOLD_RE.findall(line)) >= 3:
        return BOLD_RE.sub(r"\1", line)
    return line


_TABLE_KEYSET = set(_TABLE_KEYS)


def _prefix_ok(x: str) -> bool:
    """Anfang eines Feldnamens (auch umbrochen)"""
    return bool(x) and any(k.startswith(x) or (x.startswith(k) and len(x) - len(k) <= 3) for k in _TABLE_KEYS)


def _value_column(lines: list[str]) -> int | None:
    """Spalte der Werte: haeufigste Einrueckung des zweiten Textblocks in Zeilen, die mit einem Feldnamen beginnen"""
    from collections import Counter
    c: Counter = Counter()
    for line in lines:
        m = re.match(r"^(\s*)(\S(?:.*?\S)?)\s{2,}(\S)", line)
        if not m:
            continue
        if _prefix_ok(_fold(m.group(2))):
            c[m.start(3)] += 1
    return c.most_common(1)[0][0] if c else None


def _header_row(lines: list[str], i: int) -> tuple[list[str], int]:
    """FB-3-Kopf "Studiensemester  Dauer des  Häufigkeit des  Status Modul" -> synthetische Zeilen, naechste Zeile"""
    head = lines[i]
    cols = [(m.start(), m.group(0)) for m in re.finditer(r"Studiensemester|Dauer|Häufigkeit|Status", head)]
    if len(cols) < 3:
        return [], i + 1
    names = {"Studiensemester": "Empfohlenes Studiensemester", "Dauer": "Dauer in Semestern",
             "Häufigkeit": "Häufigkeit des Angebots", "Status": "Status Modul"}
    vals: dict = {n: [] for _, n in cols}
    j = i + 1
    while j < len(lines) and lines[j].strip() and not re.match(r"^\s*(Inhalte|Lehr-|Qualifikations)", lines[j]):
        line = lines[j]
        if re.match(r"^\s*(Moduls|Angebots)\s*$", line.strip()) or (j == i + 1 and re.search(r"Moduls|Angebots", line) and
                                                                     not re.search(r"\d", line)):
            j += 1
            continue
        for k, (start, name) in enumerate(cols):
            end = cols[k + 1][0] if k + 1 < len(cols) else len(line)
            part = line[start:end].strip() if k + 1 < len(cols) else line[start:].strip()
            if part and part != "Status Teilmodule":
                vals[name].append(part)
        j += 1
    out = []
    for _, name in cols:
        v = " ".join(vals[name])
        v = v.split("Status Teilmodule")[0].strip()
        if v:
            out.append(f"{names[name]}: {v}")
    return out, j


def table_lines(pages: list[str]) -> list[str]:
    """Layout-Seiten -> Zeilen "Feldname: Wert" (je Feld eine Kopfzeile, Folgezeilen des Werts darunter)"""
    out: list[str] = []
    for page in pages:
        raw = [_unbold(l.rstrip()) for l in FOOTER_RE.sub("\n", page or "").split("\n")]
        raw = [l for l in raw if not re.fullmatch(r"\s*[0-9]{1,3}\s*", l)]
        col = _value_column(raw)
        label: list[str] = []
        values: list[str] = []

        def flush():
            if label:
                out.append(" ".join(label).replace("- ", "-") + ": " + (values[0] if values else ""))
                out.extend(values[1:])
            label.clear()
            values.clear()
        i = 0
        while i < len(raw):
            line = raw[i]
            if not line.strip():
                i += 1
                continue
            if re.search(r"Studiensemester\s{2,}Dauer", line):
                flush()
                synth, i = _header_row(raw, i)
                out.extend(synth)
                continue
            mm = re.search(r"([0-9]+[,.]?[0-9]*)\s*h\s+([0-9]+[,.]?[0-9]*)\s*h\s+([0-9]+)\s+([0-9]+)\s*$", line) \
                if re.match(r"^\s*Modul\b(?!\s+[0-9A-Z])", line) else None
            if mm:
                # Zeile "Modul (Gesamt)" der Tabelle Lehr-/Lernformen: Kontaktzeit, Selbststudium, SWS, LP
                flush()
                wl = number(mm.group(1)) + number(mm.group(2))
                out.append(f"Anzahl der Leistungspunkte: {mm.group(4)}")
                out.append(f"Workload: Gesamt {int(wl) if wl == int(wl) else wl} h")
                i += 1
                continue
            stripped = line.strip()
            if col is not None and len(line) > col and line[:col].strip() and line[col - 1:col] == " " \
                    and line[col:col + 1] != " ":
                left, right = line[:col].strip(), line[col:].strip()
            elif col is not None and len(line.rstrip()) <= col:
                left, right = stripped, ""
            elif col is not None and not line[:col].strip():
                left, right = "", stripped
            else:
                left, right = None, stripped                 # Freie Zeile (Titel, Fliesstext ueber die Spalte)
            if left:
                cont = _fold(" ".join(label + [left]))
                complete = _fold(" ".join(label)) in _TABLE_KEYSET
                if label and _prefix_ok(cont) and not (complete and _prefix_ok(_fold(left))):
                    label.append(left)
                elif _prefix_ok(_fold(left)):
                    flush()
                    label.append(left)
                else:
                    flush()
                    if TABLE_TITLE_RE.match(left) or (out and out[-1].startswith("Modultitel: ") and not right
                                                     and len(left) < 80 and not out[-1].endswith(":")):
                        if TABLE_TITLE_RE.match(left):
                            out.append("Modultitel: " + left + ((" " + right) if right else ""))
                        else:
                            out[-1] += " " + left
                        i += 1
                        continue
                    out.append(left + ((" " + right) if right else ""))
                    i += 1
                    continue
                if right:
                    values.append(right)
            elif left == "":
                if label:
                    values.append(right)
                else:
                    out.append(right)
            else:
                flush()
                if TABLE_TITLE_RE.match(right):
                    out.append("Modultitel: " + right)
                else:
                    out.append(right)
            i += 1
        flush()
    return out


HANDBOOK_HEAD_RE = re.compile(r"(?:Anlage\s*[0-9]+[a-z]?\s*[:–.-]?\s*|[0-9]+\.\s*)?(?:Modulhandbuch|Modulbeschreibung(?:en)?)\b[^.]{0,80}")


def parse_modultabelle(pages: list[str], meta: dict) -> tuple[dict, dict]:
    """Layout-Seiten (layout_pages) -> Katalog; Titel erst nach der Ueberschrift "Modulhandbuch"/"Modulbeschreibung"
    (davor stehen Modueluebersichten mit denselben Titeln)"""
    lines = table_lines(pages)
    head = next((i for i, l in enumerate(lines) if HANDBOOK_HEAD_RE.fullmatch(l.strip()) and not re.search(r"\.{4,}|\s[0-9]+$", l)), None)
    if head is not None:
        lines = [l[len("Modultitel: "):] if i < head and l.startswith("Modultitel: ") else l for i, l in enumerate(lines)]
    return parse_modulbeschreibung(["\n".join(lines)], meta, require_facts=True)

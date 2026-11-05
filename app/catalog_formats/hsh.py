"""Leseprogramm fuer die Modulhandbuecher der Hochschule Hannover (HsH; Auftrag des Inhabers 05.11.2026, Bericht
docs/STUDIENGAENGE-HSH-2026-11-05.md). Einmal auf dem Mac gelesen (Grundstock, tools/build-hsh-seed.py), nie auf dem
Geraet.

Die Handbuecher der fuenf Fakultaeten sind verschieden gebaut, folgen aber fast alle dem Muster "Feldname links,
Wert rechts" (Word-Tabellen, in Fakultaet IV aus einer Datenbank gesetzt). Das Leseprogramm ist deshalb ein
Feldleser mit Erkennung der Modulanfaenge je Bauart:

  hsh-modul-code      "Modul BIN-100 Mathematik 1" / "Teilmodul BIN-100-01 ..." (Fakultaet IV, Teile von II/III)
  hsh-modul-nummer    "Modul 15 – Modulbeschreibung: Theologie I" / "Modul 15 – Teilmodul 01: ..." (Fakultaet V)
  hsh-modultitel      Feld "Modultitel"/"Modulbezeichnung"/"Modulname"/"Titel" beginnt ein Modul (Word-Tabellen)
  hsh-wpf-tabelle     Fakultaet II, Abteilung Bioverfahrenstechnik: "Mod. Nr: 283", Werte vor den Feldnamen

Ausgabe wie die anderen Leser in app/catalog_formats/ (Rohmodule -> formats_a_common.build_catalog). Lokale Texte
(Inhalt, Lernziele, Literatur) gehen nie in die geteilten Fakten.
"""
from __future__ import annotations

import re

from app.catalog_formats.formats_a_common import (
    build_catalog,
    clip,
    kind_of,
    language_of,
    normalize_lines,
    number,
    term_of_catalog,
    turnus_of,
)

FORMATS = ("hsh-modul-code", "hsh-modul-nummer", "hsh-modultitel", "hsh-code-kopf", "hsh-wpf-tabelle")

# --------------------------------------------------------------------------------------------------------------------
# Text
# --------------------------------------------------------------------------------------------------------------------

DOTS_RE = re.compile(r"(?:\.\s?){4,}|…{2,}|_{5,}")
PAGE_FOOT_RE = re.compile(r"^(?:Seite\s*)?\d{1,3}(?:\s*(?:von|/)\s*\d{1,3})?$|^Stand:?\s.*Seite\s+\d+\s+von\s+\d+$", re.I)
# Zeilen, die nie als Kopf-/Fusszeile wegfallen (Modulanfaenge)
KEEP_RE = re.compile(r"^(?:Mod\.\s*Nr|Modul\s|Teilmodul\s|Modultitel|Modulbezeichnung|Modulname)", re.I)
# Kerning-Luecken aus pypdf ("T eilmodul", "V orlesung", "W ahlpflicht")
KERN_RE = re.compile(r"\b([TVWYPF]) (?=[a-zäöüß]{2,})")


def clean_pages(pages: list[str]) -> list[list[str]]:
    """Seiten -> Zeilen ohne Seitenzahlen und ohne Kopf-/Fusszeilen, die auf mehr als 40 % der Seiten gleich stehen"""
    lines = [[KERN_RE.sub(r"\1", ln) for ln in normalize_lines(p)] for p in pages]
    n = len(lines)
    counts: dict[str, int] = {}
    for pl in lines:
        for ln in set(pl[:3] + pl[-3:]):
            key = re.sub(r"\d+", "#", ln)
            counts[key] = counts.get(key, 0) + 1
    rep = {k for k, c in counts.items() if n >= 5 and c >= max(3, 0.4 * n)}
    out = []
    for pl in lines:
        keep = []
        for i, ln in enumerate(pl):
            edge = i < 4 or i >= len(pl) - 3
            # Seitenzahl nur am Rand (einzelne Zahlen mitten auf der Seite sind Werte: "Semester" / "1")
            if edge and PAGE_FOOT_RE.match(ln):
                continue
            if edge and re.sub(r"\d+", "#", ln) in rep and not KEEP_RE.match(ln) and not _FIELD_RE.match(ln):
                continue
            keep.append(ln)
        out.append(keep)
    return out


def is_toc_page(lines: list[str]) -> bool:
    dots = sum(1 for ln in lines if DOTS_RE.search(ln))
    return dots >= 4 and dots >= 0.3 * max(len(lines), 1)


def dehyphen(text: str) -> str:
    """'Prüfungsord-\\nnung' -> 'Prüfungsordnung'; 'IT-\\nSicherheit' -> 'IT-Sicherheit'"""
    text = re.sub(r"(?<=[a-zäöüß])-\n(?=[a-zäöüß])", "", text)
    return re.sub(r"(?<=\w)-\n(?=[A-ZÄÖÜ])", "-", text)


# --------------------------------------------------------------------------------------------------------------------
# Felder
# --------------------------------------------------------------------------------------------------------------------

def _lab(*words: str) -> str:
    """Feldname aus Woertern: dazwischen beliebiger Leerraum (auch Zeilenumbruch), Schraegstrich mit Leerraum"""
    return r"\s+".join(w.replace("/", r"\s*/\s*") for w in words)


# (Feld, Muster) - Reihenfolge: laengere zuerst. Feld None = Grenze ohne Wert (Feld wird nicht gebraucht).
FIELDS: list[tuple[str | None, str]] = [
    ("lp_wl", _lab("Credits/Arbeitsaufwand")),
    ("lp_wl", _lab("ECTS/Workload")),
    ("lp_wl", _lab("Leistungspunkte/Workload")),
    ("lp_wl", _lab("ECTS-Leistungspunkte/Arbeitsaufwand")),
    ("lp", r"(?:ECTS[\s-]*Kreditpunkte(?:\s*\(Cr\))?|ECTS[\s-]*(?:Punkte|Credits|Leistungspunkte)|Leistungspunkte(?:\s*\((?:LP|CP|ECTS)\))?|Kreditpunkte|"
           r"Credit\s*Points|Credits(?:\s*\(?(?:CP|ECTS)\)?)?|ECTS|LP|CP)"),
    ("workload", r"(?:Workload\s+Gesamt\s+Präsenzstudium\s+Selbststudium|Studentische\s+Arbeitsbelastung)"),
    ("wl_pres", r"(?:Präsenzzeit\s+in\s+Stunden|Präsenzstunden(?!\s*/))"),
    ("wl_self", r"(?:Selbststudium-Stunden|Selbststudium\s+in\s+Stunden|Stunden\s+(?:für\s+)?Selbststudium)"),
    ("curricula", r"Zuordnung\s+zu\s+Curricula\s*\(Sem\.\)"),
    ("code", r"Kürzel"),
    ("turnus", r"Dauer\s*/\s*Häufigkeit"),
    ("workload", r"(?:Präsenzstunden\s*/\s*Selbststudium|Präsenzzeit\s*/\s*Selbststudium|Präsenzstudium\s*/\s*Selbststudium|"
                 r"Arbeitsaufwand(?:\s*\(?(?:in\s*)?h\)?)?|Workload|Gesamtaufwand|Studentischer\s+Arbeitsaufwand|"
                 r"Gesamtarbeitsaufwand)"),
    ("semester", r"(?:Studiensemester|Fachsemester|Semesterlage|Lage\s+im\s+Studienverlauf|Empfohlenes\s+(?:Fach)?semester|"
                 r"Regelsemester|Semester)"),
    ("turnus", r"(?:Häufigkeit\s+(?:des|d\.)\s+Angebots?|Angebotshäufigkeit|Angebotsturnus|Turnus|Häufigkeit|"
               r"Angeboten\s+im|Angebot\s+im|Beginn)"),
    ("kind", r"(?:Art,\s*Gewichtung|Pflicht\s*/\s*Wahlpflicht|Pflicht-\s*/\s*Wahlpflicht(?:modul)?|Modulart|Art\s+des\s+Moduls|Modultyp|"
             r"Status|Modultyp\s*\(P/WP\))"),
    ("exam", r"(?:Übliche\s+Art;?\s+Umfang,?\s+Dauer\d?|Studien-\s*/\s*Prüfungsleistung(?:en)?|Prüfungs-\s*/\s*Studienleistung(?:en)?|Prüfungsleistung(?:en)?|"
             r"Prüfungsform(?:en)?|Prüfungsart|Art\s+der\s+Prüfung|Modulprüfung|Leistungsnachweise?|Prüfung)"),
    ("coursework", r"(?:Studienleistung(?:en)?|Prüfungsvorleistung(?:en)?|Prüfungsvorleistung)"),
    ("prereq", r"(?:Voraussetzungen\s+nach\s+Prüfungsordnung|Voraussetzungen\s+für\s+die\s+(?:Teilnahme|Vergabe\s+von\s+"
               r"(?:Leistungspunkten|Credits))|Teilnahmevoraussetzungen|Zugangsvoraussetzungen|Formale\s+Voraussetzungen|"
               r"Voraussetzungen)"),
    ("rec", r"(?:Empfohlene\s+Voraussetzungen|Inhaltliche\s+Voraussetzungen|Empfohlene\s+Vorkenntnisse|Vorkenntnisse)"),
    ("language", r"(?:Lehr-\s*und\s*Prüfungssprache|Lehrsprache|Unterrichtssprache|Sprache\s*\(n\)|Sprachen?)"),
    ("content", r"(?:Lehrinhalte|Modulinhalte|Inhalte\s+des\s+Moduls|Inhalte?)"),
    ("goals", r"(?:Angestrebte\s+Lernergebnisse|Qualifikationsziele\s*/\s*Lernergebnisse|Qualifikationsziele|"
              r"Lernergebnisse|Lernziele|Kompetenzziele|Kompetenzen)"),
    ("literature", r"(?:Literaturempfehlungen|Empfohlene\s+Literatur|Literatur)"),
    ("duration", r"(?:Moduldauer|Dauer\s+des\s+Moduls|Dauer)"),
    ("sws", r"(?:Veranstaltungsart\s*,\s*SWS|SWS|Semesterwochenstunden|Kontaktzeit)"),
    ("level", r"(?:Modulniveau|Niveau)"),
    ("area", r"(?:Modulgruppe|Studienabschnitt|Studienbereich|Cluster|Zuordnung\s+zum\s+Curriculum)"),
    # Grenzen ohne gebrauchten Wert
    (None, r"(?:[\w/-]*verantwortliche?\s*(?:\(\s*r\s*\)|/\s*r|r)?|[\w/-]*verant-\s+wortliche\s*\(?r?\)?|Modulverantwortliche\s*\(?r\)?|Modulverantwortliche/?r?|Modulverantwortung|Modulverantwortlicher?|"
           r"Verantwortliche\s*\(r\)|Verantwortliche/?r?|Dozentinnen\s*/\s*Dozenten|Dozent(?:in|en)?|Lehrende|"
           r"Lehrperson(?:en)?|Untertitel|Teilmodule|Lehrveranstaltungen|Lehrveranstaltung\(en\)|"
           r"Verwendbarkeit(?:\s+des\s+Moduls(?:\s+im\s+Curriculum)?)?|Zuordnung\s+zu\s+Curricula|Veranstaltungsart|"
           r"Lehr-\s*und\s*Lernformen|Lehrform(?:en)?|Lehr-\s*/\s*Lernformen|Lehrmethoden|Medienformen|Gruppengröße|"
           r"Anforderungen\s+(?:der|des)\s+(?:Präsenzzeit|Selbststudiums)|Anforderungen\s+Präsenzzeit|"
           r"Anforderungen\s+Selbststudium|Empfehlungen\s+(?:zum\s+)?Selbststudium|Bemerkungen|Sonstiges|"
           r"Sonstige\s+Informationen|Besonderheiten|Stellenwert\s+der\s+Note|Notengewichtung|Gewichtung|"
           r"Modulnummer|Modul-?Nr\.?|Kennnummer|Kürzel|Modulkürzel|Präsenzstudium|Selbststudium|Präsenzzeit|"
           r"Kontaktstudium|Teilnehmerzahl|Prüfungsumfang\s*/\s*-?\s*dauer|Mögliche\s+Arten;?\s+Umfang,?\s+Dauer\d?|"
           r"Gewichtung\s+bezogen\s+auf|Zugangsempfehlung|Arbeitsleistung|Arbeits-\s*und\s*Prüfungsleistung|"
           r"Teilmodulbezeichnung\s*/\s*Titel|ggf\.\s+Untertitel|Moduleinordnung|Übliche\s+Studien-\s*/\s*Prüfungsleistungen)"),
]
_FIELD_RE = re.compile(r"(?m)^[ \t]*(?:" + "|".join(f"(?P<f{i}>{rx})" for i, (_, rx) in enumerate(FIELDS)) +
                       r")(?=[\s:]|$)[ \t]*:?", re.I)


def split_fields(text: str) -> list[tuple[str | None, str]]:
    """Text eines Moduls -> [(Feld, Wert)] in Reihenfolge; Text vor dem ersten Feld als (None-Kopf) weg"""
    out = []
    hits = list(_FIELD_RE.finditer(text))
    for i, m in enumerate(hits):
        idx = next(int(k[1:]) for k, v in m.groupdict().items() if v is not None)
        end = hits[i + 1].start() if i + 1 < len(hits) else len(text)
        out.append((FIELDS[idx][0], text[m.end():end].strip()))
    return out


NUM = r"[0-9]+(?:[.,][0-9]+)?"


def lp_of(value: str):
    value = re.sub(r"\([^)]*\)", " ", value or "")
    m = re.search(rf"({NUM})\s*(?:LP|CP|ECTS|Credits?|Leistungspunkte)?", value or "")
    if not m:
        return None
    v = number(m.group(1))
    return v if 0 < v <= 120 else None


def workload_of(value: str):
    """'68 h / 112 h' -> 180, '34 / 116' -> 150, '150 h' -> 150, '9/270 h' (mit LP) -> nicht hier"""
    nums = [number(x) for x in re.findall(NUM, value or "")[:3]]
    if not nums:
        return None
    if re.search(r"/|\+", value or "") and len(nums) >= 2:
        total = nums[0] + nums[1]
    else:
        total = nums[0]
    return total if 10 <= total <= 2000 else None


def semester_of(value: str):
    m = re.search(r"(\d{1,2})\s*(?:\.|-|–|bis|/|\s|$)", (value or "").strip())
    if not m:
        return None
    v = int(m.group(1))
    return v if 1 <= v <= 12 else None


def kind_value(value: str):
    v = (value or "").strip().lower()
    if re.match(r"^(pf|p|pflicht)\b", v) and "wahl" not in v[:12]:
        return "pflicht"
    if re.match(r"^(wpf|wp|wpm|wahlpflicht)", v):
        return "wahlpflicht"
    return kind_of(value.split("\n")[0][:40]) if value else None


def _first_line(value: str) -> str:
    return (value or "").split("\n")[0]


def _apply(mod: dict, fields: list[tuple[str | None, str]], sub: bool = False) -> None:
    """Werte eines (Teil-)Moduls eintragen; Teilmodule fuellen nur Luecken und haengen Texte an"""
    for f, v in fields:
        if f is None or not v:
            continue
        flat = re.sub(r"\s+", " ", v).strip()
        if f == "lp_wl":
            nums = re.findall(NUM, v)
            if nums and not sub and mod.get("lp") is None:
                mod["lp"] = lp_of(nums[0])
            if len(nums) > 1 and mod.get("workload_h") is None:
                w = number(nums[1])
                mod["workload_h"] = w if 10 <= w <= 2000 else None
        elif f == "lp":
            if not sub and mod.get("lp") is None:
                mod["lp"] = lp_of(_first_line(v))
        elif f == "workload":
            if mod.get("workload_h") is None:
                mod["workload_h"] = workload_of(_first_line(v))
        elif f == "semester":
            if mod.get("semester") is None:
                mod["semester"] = semester_of(_first_line(v))
        elif f == "turnus":
            t = turnus_of(_first_line(v) + " " + (v.split("\n")[1] if "\n" in v else ""))
            if t == "unbekannt" and re.search(r"jedes\s+semester|semesterweise|halbjährlich", flat, re.I):
                t = "WS+SS"
            if mod.get("turnus") in (None, "unbekannt"):
                mod["turnus"] = t
        elif f == "kind":
            # Teilmodule/Lehrveranstaltungen nur, wenn das Modul selbst nichts sagt (Fakultaet III: Art steht je LV)
            if mod.get("kind") is None:
                mod["kind"] = kind_value(v)
        elif f == "exam":
            if mod.get("exam") is None:
                mod["exam"] = clip(flat, 200)
        elif f == "coursework":
            if mod.get("coursework") is None:
                mod["coursework"] = clip(flat, 200)
        elif f == "prereq":
            mod["prereq"] = (mod.get("prereq") or "") + " " + flat
        elif f == "language":
            if mod.get("language") is None:
                head = " ".join(v.split("\n")[:3])
                hit = re.search(r"deutsch|englisch|english|german|französisch|spanisch", head, re.I)
                mod["language"] = language_of(hit.group(0) if hit else _first_line(v)[:60])
        elif f in ("content", "goals", "literature"):
            mod[f] = ((mod.get(f) or "") + ("\n" if mod.get(f) else "") + v.strip())[:6000]
        elif f == "wl_pres":
            n = re.search(NUM, v)
            if n:
                mod["_wl_pres"] = number(n.group(0))
        elif f == "wl_self":
            n = re.search(NUM, v)
            if n:
                mod["_wl_self"] = number(n.group(0))
        elif f == "curricula":
            # Fakultaet II: "IIM (2/So/Wi), MAB (2/So/Wi), WTD (4/So)" -> Fachsemester und Turnus im eigenen Studiengang
            for ab, sem, t in re.findall(r"([A-Z]{2,5})\s*\((\d{1,2})(?:/([A-Za-z/]+))?\)", flat):
                if ab == mod.get("_abbr"):
                    if mod.get("semester") is None:
                        mod["semester"] = semester_of(sem)
                    if mod.get("turnus") in (None, "unbekannt") and t:
                        tt = t.lower()
                        mod["turnus"] = "WS+SS" if ("so" in tt and "wi" in tt) else ("WS" if "wi" in tt else ("SS" if "so" in tt else "unbekannt"))
                    break
        elif f == "code":
            m = re.match(rf"^\s*({CODE})", v)
            if m and not sub:
                mod["code"] = m.group(1)
        elif f == "level":
            m = re.search(r"(\d{1,2})\.\s*(?:Fach)?[Ss]emester", flat)
            if m and mod.get("semester") is None:
                mod["semester"] = semester_of(m.group(1))
        elif f == "area":
            if mod.get("area_field") is None:
                mod["area_field"] = clip(_first_line(v), 80)


# --------------------------------------------------------------------------------------------------------------------
# Modulanfaenge je Bauart
# --------------------------------------------------------------------------------------------------------------------

CODE = r"[A-ZÄÖÜ][A-Za-z0-9]{0,6}[-_ ]?\d{2,4}[a-z]?"
HEAD_RES = {
    "hsh-modul-code": (re.compile(rf"^Modul\s+(?P<code>{CODE})\s*(?:/|:|–)?\s+(?P<title>\S.*)$"),
                       re.compile(rf"^Teilmodul\s+(?P<code>{CODE}-\d{{1,2}})\s+(?P<title>\S.*)$")),
    "hsh-modul-nummer": (re.compile(r"^Modul\s+(?P<code>\d{1,2}[a-z]?)\s*[–-]\s*(?:Modulbeschreibung(?:en)?\s*:?\s*)?"
                                    r"(?P<title>(?!Teilmodul)\S.*)$"),
                         re.compile(r"^(?:Modul\s+\d{1,2}[a-z]?\s*[–-]\s*)?Teilmodul\s*(?P<code>\d{1,2}(?:\.\d{1,2})?)\s*:?\s*(?P<title>.*)$")),
    # Kopfzeile nur Kuerzel und Titel ("BIM-112 Informationsorganisation", "BME-122 Qualifikation I", "BBA-411" + Titel)
    "hsh-code-kopf": (re.compile(r"^(?P<code>[A-Z][A-Z0-9]{1,5}-\d{3}[a-z]?)(?::?\s+(?P<title>[^\d\s(].*))?$"),
                      re.compile(r"^(?P<code>[A-Z][A-Z0-9]{1,5}-\d{3}[a-z]?-\d{1,2})\s+(?P<title>\S.*)$")),
    "hsh-modultitel": (re.compile(r"^(?:Modultitel|Modulbezeichnung|Modulname|Titel\s+des\s+Moduls|Modul(?:titel)?\s*:)"
                                  r"\s*:?\s*(?P<title>\S.*)?$"),
                       re.compile(r"^(?:Lehrveranstaltung|Teilmodul(?:titel)?|Veranstaltung)\s*:?\s+(?P<title>\S.*)$")),
}
MOD_CODE_IN_TITLE = re.compile(rf"^(?P<code>{CODE}(?:-\d{{1,2}})?)\s*[:\-–]?\s+(?P<title>\S.*)$")


def detect(pages: list[str]) -> str | None:
    """Bauart eines Handbuchs: die mit den meisten gelesenen Modulen mit LP (bei Gleichstand die mit mehr Modulen,
    dann die Reihenfolge in HEAD_RES), None = unbekannt"""
    cp = clean_pages(pages)
    lines = [ln for p in cp if not is_toc_page(p) for ln in p if not DOTS_RE.search(ln)]
    if sum(1 for ln in normalize_lines("\n".join(pages)) if re.match(r"^Mod\.\s*Nr\.?:?\s*\d+", ln)) >= 2:
        return "hsh-wpf-tabelle"
    meta = {"university": "hsh", "program": "x", "degree": "x", "po": "x", "code": "x", "source": {"url": "https://x"}}
    best, score = None, (0, 0)
    for rank, (name, (head, _)) in enumerate(HEAD_RES.items()):
        if sum(1 for ln in lines if head.match(ln)) < 2:
            continue
        try:
            cat, _ = parse_fields_format(pages, meta, name, cp)
        except Exception:  # noqa: BLE001
            continue
        mods = cat.get("modules") or []
        sc = (sum(1 for m in mods if m.get("lp") is not None), len(mods))
        if sc > score:
            best, score = name, sc
    return best if score[1] >= 2 else None


def _blocks(pages: list[list[str]], fmt: str):
    """-> [(Kopfzeile-Match, ist_teilmodul, Seite, Text)]"""
    head, sub = HEAD_RES[fmt]
    blocks = []
    cur = None
    for pno, lines in enumerate(pages, start=1):
        if is_toc_page(lines):
            continue
        for ln in lines:
            if DOTS_RE.search(ln):
                continue
            m = head.match(ln)
            s = sub.match(ln) if sub is not None and not m else None
            if m and fmt == "hsh-code-kopf" and cur is not None and not cur["sub"] \
                    and cur["m"].group("code") == m.group("code"):
                continue                                   # Seitenkopf wiederholt das Modul: weiter im selben Block
            if m or s:
                cur = {"m": m or s, "sub": bool(s), "page": pno, "lines": []}
                blocks.append(cur)
                continue
            if cur is not None:
                cur["lines"].append(ln)
    if fmt == "hsh-code-kopf":
        # Kopf nur, wenn in den ersten Zeilen ein Feldname steht (sonst Verweis im Text wie "BIM-112 muss bestanden sein")
        keep, last = [], None
        for b in blocks:
            if _FIELD_RE.search("\n".join(b["lines"][:12])) or b["sub"]:
                keep.append(b)
                last = b
            elif last is not None:
                last["lines"] += [b["m"].group(0)] + b["lines"]
        blocks = keep
    return blocks


# Spaltentabellen (Feldnamen in einer Zeile, Werte in der naechsten)
IK_ROW_RE = re.compile(r"Semester\s+Häufigkeit(?:\s+des\s+Angebots)?\s+Dauer\s+Art\s+ECTS-?\s*Punkte\s+Studentische\s+Arbeitsbelastung\s*\n"
                       r"(?P<sem>\S+)\s+(?P<freq>.*?)\s+(?P<dur>\d+)\s+Semester\s+(?P<art>\S+)\s+(?P<ects>\d+(?:,\d)?)\s+(?P<wl>\d+)")
IK_EXAM_RE = re.compile(r"Prüfungsform\s+Lehr-\s*und\s+Lernmethoden\s+Modulverantwortliche\s*\(r\)\s*\n(?P<row>[^\n]*(?:\n[^\n]*){0,2})")
BBA_ROW_RE = re.compile(r"Modultyp\s+Studiensemester\s+Angebotsturnus\d?\s+Dauer\s+in\s*\n?\s*Semester\s*\n"
                        r"(?P<art>\S+)\s+(?P<sem>\S+)\s+(?P<turn>.+?)\s+(?P<dur>\d+)\s*$", re.M)


def column_rows(text: str, mod: dict) -> str:
    """Spaltentabellen lesen (Fakultaet III IK, Fakultaet IV BWL) und aus dem Text nehmen"""
    m = IK_ROW_RE.search(text)
    if m:
        mod["semester"] = semester_of(m.group("sem"))
        mod["turnus"] = turnus_of(m.group("freq"))
        mod["kind"] = kind_value(m.group("art"))
        mod["lp"] = lp_of(m.group("ects"))
        w = int(m.group("wl"))
        mod["workload_h"] = w if 10 <= w <= 2000 else None
        text = text[: m.start()] + text[m.end():]
    m = IK_EXAM_RE.search(text)
    if m:
        row = re.sub(r"\s+", " ", m.group("row")).strip()
        row = re.sub(r"^(?:keine|Keine|siehe\s+\S+)\s+", "", row)
        cut = re.search(r"\b[A-ZÄÖÜa-zäöü][a-zäöüß]{3,}", row)
        exam = (row[: cut.start()] if cut else row).strip(" ,;")
        if exam and len(exam) <= 80:
            mod["exam"] = exam
        text = text[: m.start()] + text[m.end():]
    m = BBA_ROW_RE.search(text)
    if m:
        mod["kind"] = kind_value(m.group("art"))
        mod["semester"] = semester_of(m.group("sem"))
        mod["turnus"] = turnus_of(m.group("turn"))
        text = text[: m.start()] + text[m.end():]
    return text


def toc_areas(pages: list[list[str]]) -> dict[str, str]:
    """Inhaltsverzeichnis: Modulkuerzel -> Abschnitt ('Pflichtmodule 2. Studienabschnitt')"""
    out: dict[str, str] = {}
    area = None
    for lines in pages[:8]:
        if not is_toc_page(lines):
            continue
        for ln in lines:
            if DOTS_RE.search(ln):
                m = re.match(rf"^(?:Modul\s+)?({CODE})\s", ln)
                if m and area:
                    out.setdefault(m.group(1), area)
            else:
                m = re.match(r"^(?P<name>[A-ZÄÖÜ0-9][^…]{3,80}?)\s+\d{1,3}$", ln)
                if m and not re.match(rf"^(?:Modul\s+)?{CODE}\s", ln) and re.search(r"[a-zäöü]{3}", m.group("name")):
                    area = re.sub(r"^\d+(?:\.\d+)+\s+", "", m.group("name").strip())
    return out


def _title_code(m, fmt: str) -> tuple[str, str | None]:
    title = (m.groupdict().get("title") or "").strip()
    code = m.groupdict().get("code")
    if fmt == "hsh-modultitel" and title:
        mc = MOD_CODE_IN_TITLE.match(title)
        if mc and re.search(r"\d", mc.group("code")):
            code, title = mc.group("code"), mc.group("title")
    return title, code


AREA_HEADING_RE = re.compile(r"^(?:\d+(?:\.\d+)*\.?\s+)?(?P<name>(?:Pflicht|Wahlpflicht|Wahl|Schwerpunkt|Vertiefung|"
                             r"Kern|Grundlagen|Basis|Profil|Studienschwerpunkt|Praxis|Abschluss)[\wäöüß\- ]{0,70}"
                             r"(?:module|bereich|modulen|phase|richtung|studium)?)\s*$", re.I)


TABLE_ROW_RE = re.compile(r"(?:^|\n)Modul\s+(?P<n>\d{1,2}[a-z]?)\s*\n(?P<code>[A-Z]{2,4}-\d{3}[a-z]?)\s+(?P<title>[^\n]+?(?:\n[^\n]+?)?)"
                          r"\s+(?P<kind>PF|WP|WPF|P)\s+(?P<p>\d+)\s+(?P<s>\d+)\s+(?P<sws>[\d,]+)\s+(?P<cp>[\d,]+)\s*(?:\n|$)")
# Fassung ab PO 2026: "Modul 2 <Titel> PF 180 270 12 15" in einer Zeile, Kuerzel im Feld "Kuerzel:"
TABLE_ROW2_RE = re.compile(r"(?:^|\n)Modul\s+(?P<n>\d{1,2}[a-z]?)\s+(?P<title>[^\n]+?)\s+(?P<kind>PF|WP|WPF|P)\s+(?P<p>\d+)\s+"
                           r"(?P<s>\d+)\s+(?P<sws>[\d,]+)\s+(?P<cp>[\d,]+)\s*(?:\n|$)")


def module_table_rows(text: str) -> dict[str, dict]:
    """Fakultaet V: Tabelle je Modul 'Kuerzel Titel PF/WP Praesenzstunden Selbststudium SWS CP' -> 'Modul 01' ->
    {code, lp, workload_h, kind}"""
    out: dict[str, dict] = {}
    for m in list(TABLE_ROW_RE.finditer(text)) + list(TABLE_ROW2_RE.finditer(text)):
        key = f"Modul {m.group('n')}"
        if key in out:
            continue
        lp = lp_of(m.group("cp"))
        wl = int(m.group("p")) + int(m.group("s"))
        out[key] = {"code": m.groupdict().get("code"), "lp": lp, "workload_h": wl if 10 <= wl <= 2000 else None,
                    "kind": "pflicht" if m.group("kind") in ("PF", "P") else "wahlpflicht"}
    return out


PLAN_LINE_RE = re.compile(r"^(?:(?P<sem>\d{1,2})(?:\s+und\s+\d{1,2})?\s+)?(?:\d\.\d{1,2}(?:\s*\.?[a-c](?:-[a-c])?)?\s+)?"
                          r"(?P<title>[A-ZÄÖÜ][^()]{3,120}?)\s*\((?P<lp>\d{1,2}(?:,\d)?)\s*(?:Cr|CP|LP|ECTS)\)\s*$")


def _tkey(t: str) -> str:
    return re.sub(r"[^a-z0-9äöüß]", "", (t or "").lower())


def plan_lines(pages: list[list[str]], raw: list[dict]) -> None:
    """Studienverlauf als Text im Handbuch ("4 2.1 Evidenzbasierung der Pflege (10 Cr)", Folgezeilen ohne Semester
    gehoeren zum Semester davor): fehlende Fachsemester und LP nach Titel ergaenzen"""
    by_title = {_tkey(r["title"]): r for r in raw}
    sem = None
    for lines in pages:
        if not any(re.search(r"Studienverlauf|Semester\s+Module", ln) for ln in lines):
            continue
        sem = None
        for ln in lines:
            m = PLAN_LINE_RE.match(ln)
            if not m:
                continue
            if m.group("sem"):
                sem = int(m.group("sem"))
            r = by_title.get(_tkey(m.group("title")))
            if r is None:
                continue
            if r.get("lp") is None:
                r["lp"] = lp_of(m.group("lp"))
            if r.get("semester") is None and sem and 1 <= sem <= 12:
                r["semester"] = sem


def parse_fields_format(pages: list[str], meta: dict, fmt: str, cp: list[list[str]] | None = None) -> tuple[dict, dict]:
    cp = cp if cp is not None else clean_pages(pages)
    areas_by_code = toc_areas(cp)
    raw: list[dict] = []
    cur: dict | None = None
    for b in _blocks(cp, fmt):
        title, code = _title_code(b["m"], fmt)
        text = dehyphen("\n".join(b["lines"]))
        pre: dict = {}
        if not b["sub"]:
            text = column_rows(text, pre)
        fields = split_fields(text)
        # mehrzeiliger Titel: Text vor dem ersten Feld gehoert zum Titel (hoechstens 2 Zeilen)
        lead = text.split("\n")
        first = _FIELD_RE.search(text)
        head_text = text[: first.start()] if first else ""
        extra = [x for x in head_text.split("\n") if x.strip()][:2] if head_text and len(head_text) < 160 else []
        if b["sub"]:
            if cur is not None:
                _apply(cur, fields, sub=True)
            continue
        if not title and extra:
            title, extra = extra[0], extra[1:]
        if extra and not re.search(r"[.:;]$", title):
            title = f"{title} {' '.join(extra)}"
        title = re.sub(r"\s+", " ", title).strip(" :–-_")
        title = re.sub(r"^\d{1,2}\.\d{1,2}\s*[a-c]?\s+(?=[A-ZÄÖÜ])", "", title)          # "1.2 Gesundheitssystem"
        title = re.sub(r"(?<=[a-zäöüß])- (?!und\b|oder\b|bzw\b|sowie\b)(?=[a-zäöüß])", "", title)  # "Ziel- gruppen"
        if not title or len(title) > 160:
            cur = None
            continue
        cur = {"title": title, "code": code if fmt != "hsh-modul-nummer" else (f"Modul {code}" if code else None),
               "page": b["page"], "area": areas_by_code.get(code or ""),
               "_n": f"Modul {code}" if fmt == "hsh-modul-nummer" and code else None,
               "_abbr": meta.get("abbr") or (re.match(r"^([A-Z]{2,5})-", code or "") or [None, None])[1]}
        for k, v in pre.items():
            if v is not None:
                cur[k] = v
        _apply(cur, fields)
        raw.append(cur)
        del lead
    if fmt == "hsh-modul-nummer":
        rows = module_table_rows("\n".join("\n".join(p) for p in cp))
        for r in raw:
            row = rows.get(r.get("_n") or "")
            if row:
                if row["code"] and str(r.get("code") or "").startswith("Modul "):
                    r["code"] = row["code"]
                r["lp"] = r.get("lp") or row["lp"]
                r["workload_h"] = r.get("workload_h") or row["workload_h"]
                r["kind"] = r.get("kind") or row["kind"]
    plan_lines(cp, raw)
    for r in raw:
        if r.get("workload_h") is None and r.get("_wl_pres") is not None and r.get("_wl_self") is not None:
            w = r["_wl_pres"] + r["_wl_self"]
            r["workload_h"] = w if 10 <= w <= 2000 else None
        for k in ("_wl_pres", "_wl_self", "_abbr", "_n"):
            r.pop(k, None)
        if not r.get("area") and r.get("area_field"):
            r["area"] = r["area_field"]
        if not r.get("area") and r.get("kind"):
            r["area"] = {"pflicht": "Pflichtmodule", "wahlpflicht": "Wahlpflichtmodule", "wahl": "Wahlmodule"}.get(r["kind"])
        r["prereq"] = r.get("prereq") or ""
        r.pop("area_field", None)
    first = "\n".join(pages[:2])
    term = term_of_catalog(meta.get("catalog_term"), first)
    return build_catalog(meta, raw, term=term)


# --------------------------------------------------------------------------------------------------------------------
# Fakultaet II, Wahlpflichtkatalog (Werte vor den Feldnamen)
# --------------------------------------------------------------------------------------------------------------------

WPF_LABELS = ("Dauer", "ECTS-Punkte", "Präsenzstudium", "Selbststudium", "Modultyp", "Voraussetzungen f. Teilnahme",
              "Cluster", "Modulbezeichnung", "Modulverantwortliche*r", "Häufigkeit d. Angebots")


def parse_wpf_tabelle(pages: list[str], meta: dict) -> tuple[dict, dict]:
    """'Mod. Nr: 283' / Bereich / Titel / Verantwortliche / Turnus / Dauer / ECTS / Praesenz / Selbststudium /
    Pruefung / Voraussetzungen / Cluster, darunter Teilmodule (Pruefungsformen) und Texte"""
    raw = []
    # ohne clean_pages: die Werte (ECTS, Stunden) stehen als einzelne Zahlen wie Seitenzahlen auf jeder Seite
    for pno, lines in enumerate((normalize_lines(p) for p in pages), start=1):
        idx = [i for i, ln in enumerate(lines) if re.match(r"^Mod\.\s*Nr\.?:?\s*\d+", ln)]
        for k, i in enumerate(idx):
            block = lines[i: idx[k + 1] if k + 1 < len(idx) else len(lines)]
            if len(block) < 9:
                continue
            code = re.sub(r"^Mod\.\s*Nr\.?:?\s*", "", block[0]).strip()
            d = next((j for j, x in enumerate(block) if re.match(r"^\d+(?:,\d)?\s*Sem", x)), None)
            if d is None or d < 3 or d + 3 >= len(block):
                continue
            title, turnus, dauer = block[d - 3], block[d - 1], block[d]
            area = block[d - 4] if d - 4 >= 1 else "Wahlpflichtmodule"
            ects, pres, self_ = block[d + 1], block[d + 2], block[d + 3]
            exam = block[d + 4] if len(block) > d + 4 else None
            prereq = block[d + 5] if len(block) > d + 5 else ""
            usual = []
            for ln in block[d + 4:]:
                mu = re.match(r"^\S*\s.*\s([A-Z]{1,3}\d{0,3})\s+\d+(?:,\d)?(?:\s+\d+(?:,\d)?)?$", ln)
                if mu and re.fullmatch(r"[A-Z]{1,3}\d{0,3}", mu.group(1)) and mu.group(1) not in usual:
                    usual.append(mu.group(1))
            if exam and usual:
                exam = f"{exam} (üblich: {', '.join(usual)})"
            lp = lp_of(ects)
            wl = None
            if re.fullmatch(NUM, pres or "") and re.fullmatch(NUM, self_ or ""):
                wl = number(pres) + number(self_)
            text = "\n".join(block)
            content = goals = None
            m = re.search(r"Lehrinhalte\s(.*?)(?:\nVerwendbarkeit|\nQualifikationsziele|$)", text, re.S)
            if m:
                content = m.group(1).strip()
            m = re.search(r"Qualifikationsziele\s(.*?)(?:\nDauer\n|$)", text, re.S)
            if m:
                goals = m.group(1).strip()
            raw.append({"title": title, "code": f"Mod. {code}", "area": area, "kind": "wahlpflicht", "lp": lp,
                        "semester": None, "turnus": turnus_of(turnus.replace("SoS", "SoSe")), "exam": exam,
                        "coursework": None, "prereq": "" if (prereq or "").lower() == "keine" else prereq,
                        "language": None, "workload_h": wl, "page": pno, "content": content, "goals": goals,
                        "literature": None, "duration": dauer})
    first = "\n".join(pages[:2])
    return build_catalog(meta, raw, term=term_of_catalog(meta.get("catalog_term"), first))


def parse(pages: list[str], meta: dict, fmt: str | None = None) -> tuple[dict, dict]:
    """Seitentexte (pypdf) und Kopf (university, program, degree, po, code, catalog_term, regular_semesters,
    total_lp, source) -> (Katalog, lokale Texte). fmt None = erkennen."""
    fmt = fmt or detect(pages)
    if fmt == "hsh-wpf-tabelle":
        return parse_wpf_tabelle(pages, meta)
    if fmt in HEAD_RES:
        return parse_fields_format(pages, meta, fmt)
    raise ValueError("unbekannte Bauart")

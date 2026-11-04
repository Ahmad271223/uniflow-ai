"""Leseprogramm `phil-kv-tabelle`: Modulkataloge der Institute der Philosophischen Fakultaet der LUH
(Politikwissenschaft, Sonderpaedagogik B.A./M.A., Geschichte und Sport im Lehramt, Englisch als Scan).

Aufbau (docs/STUDIENGAENGE-LUH-2026-11-04.md): je Modul eine zweispaltige Tabelle. Kopfzeile "Pflichtmodul |
<Titel> | Modul-Code" (auch "Basismodul B | <Titel>", "Modul MA 2 | <Titel>", "Wahlpflichtmodul | <Titel> | 14 800"),
dann Schluessel links, Wert rechts: "Anbieter", "Modulverantwortliche/r", "Haeufigkeit des Angebots", "Dauer des
Moduls", "Semesterlage", "Verwendbarkeit", "Eingangsvoraussetzungen", "Art der LV/SWS", "ECTS-LP/Workload"
("12 LP (3+3+3+3)/360 Stunden"), "Notenskala", "Pruefungsleistungen", "Studienleistungen", "Inhalte",
"Kompetenzziele", "Literatur". Schluessel ueber mehrere Zeilen ("Semesterlage und / Haeufigkeit des Angebots"),
Werte ueber Seitengrenzen.

Eingabe: Seitentexte mit erhaltener Spaltenlage (pypdf `extraction_mode="layout"`, `layout_pages`, oder OCR-Zeilen
aus ocr_pages.layout_text). Normale pypdf-Texte (eine Leerstelle zwischen Schluessel und Wert) gehen auch: dann wird
am bekannten Schluessel am Zeilenanfang getrennt.

Ein Katalog gilt oft fuer mehrere Studiengaenge (Sport fuer sieben, Geschichte und Englisch fuer vier); mit
meta["program_key"] (Registerschluessel) behaelt `parse` nur die Module, deren Verwendbarkeit oder Titelzusatz
diesen Studiengang nennt (ohne Angabe bleibt das Modul).

Ausgabe wie app/study_catalog.parse_luh_modkat: (Katalog im geteilten Format, {modul_id: {content, goals, literature}}).
"""
from __future__ import annotations

import io
import re
from collections import Counter

from app.study_catalog import _fold, normalize_lines
from app.catalog_formats.formats_a_common import (  # gemeinsame Bausteine der Formate A (anderes Arbeitspaket)
    build_catalog,
    clip,
    kind_of,
    language_of,
    number,
    turnus_of,
    workload_of,
)

FORMAT = "phil-kv-tabelle"

# ----------------------------------------------------------------------------
# Seiten -> Zeilen (links | rechts)
# ----------------------------------------------------------------------------

GAP_RE = re.compile(r" {3,}")
PAGE_NO_RE = re.compile(r"^(?:Seite )?[0-9]{1,3}(?: (?:von|/) [0-9]{1,3})?$")
TOC_RE = re.compile(r"\.{6,} ?[0-9]{1,3}$|(?:\. ){4,}")


def layout_pages(data: bytes) -> list[str]:
    """PDF -> Seitentexte mit Spaltenlage (pypdf Layout-Modus)"""
    from pypdf import PdfReader
    reader = PdfReader(io.BytesIO(data))
    out = []
    for p in reader.pages:
        try:
            out.append(p.extract_text(extraction_mode="layout") or "")
        except Exception:  # noqa: BLE001
            out.append("")
    return out


def _raw_lines(text: str) -> list[str]:
    """Zeilen mit Einrueckung (NFKC, Tabulator -> Leerzeichen), leere weg"""
    import unicodedata
    t = unicodedata.normalize("NFKC", text or "").replace("\t", " ").replace("\r", "\n")
    t = "".join(c for c in t if c not in "­​‌‍﻿")
    return [l.rstrip() for l in t.split("\n") if l.strip()]


def _second_column(lines: list[str]) -> int | None:
    """Spalte der Werte: haeufigster Beginn des zweiten Textblocks einer Zeile (nach >= 3 Leerzeichen)"""
    cols: Counter = Counter()
    indents = Counter(len(l) - len(l.lstrip(" ")) for l in lines)
    base = min((i for i, n in indents.items() if n >= 0.1 * len(lines)), default=0)
    for l in lines:
        s = l.lstrip(" ")
        indent = len(l) - len(s)
        if indent > base + 6:
            continue
        m = GAP_RE.search(s)
        if not m or m.start() > 45 or TOC_RE.search(l):
            continue
        c = indent + m.end()
        if 14 + base <= c <= 80 + base:
            cols[c] += 1
    if not cols:
        return None
    # Werte beginnen fast immer in derselben Spalte; kleine Schwankungen (+-2) zusammenfassen
    best, n = None, -1
    for c in cols:
        k = sum(v for cc, v in cols.items() if abs(cc - c) <= 2)
        if k > n or (k == n and c < best):
            best, n = c, k
    return best


def _cells(text: str) -> list[str]:
    return [c.strip() for c in GAP_RE.split(text.strip()) if c.strip()]


class Row:
    __slots__ = ("left", "right", "full", "page")

    def __init__(self, left: str, right: str, full: bool, page: int):
        self.left, self.right, self.full, self.page = left, right, full, page

    def text(self) -> str:
        return " ".join(x for x in (self.left, self.right) if x)

    def __repr__(self):  # nur zur Fehlersuche
        return f"Row(p{self.page} {self.left!r} | {self.right!r}{' full' if self.full else ''})"


def _split(line: str, col: int, page: int) -> Row:
    s = line.lstrip(" ")
    indent = len(line) - len(s)
    if indent >= col - 4:
        return Row("", "   ".join(_cells(s)), False, page)
    # Luecke nahe der Wertspalte suchen
    for m in GAP_RE.finditer(line):
        if m.start() <= indent:
            continue
        if col - 6 <= m.end() <= col + 10:
            return Row(" ".join(_cells(line[:m.start()])), "   ".join(_cells(line[m.end():])), False, page)
        if m.end() > col + 10:
            break
    if len(line) > col + 2:
        # durchlaufender Text ueber beide Spalten (Abschnitt ohne Tabelle, Fussnote)
        return Row(" ".join(_cells(line)), "", True, page)
    return Row(" ".join(_cells(line)), "", False, page)


def _orig_len(s: str, folded_len: int) -> int:
    """Laenge im Original, deren gefaltete Form folded_len Zeichen hat (Umlaute werden zu zwei Zeichen)"""
    n, acc = 0, 0
    while n < len(s) and acc < folded_len:
        acc += len(_fold(s[n]))
        n += 1
    return n


def _split_by_label(line: str, page: int) -> Row:
    """Ohne Spaltenlage: bekannter Schluessel am Zeilenanfang -> links, Rest rechts"""
    s = " ".join(line.split())
    f = _fold(s)
    for lab in sorted(LABEL_PREFIXES, key=len, reverse=True):
        if f.startswith(lab):
            n = _orig_len(s, len(lab))
            # ganzes Wort des Schluessels ("Studienleistungen", nicht nur "Studienleistung")
            while n < len(s) and s[n].isalpha():
                n += 1
            return Row(s[:n].strip(), s[n:].strip(" :"), False, page)
    if HEADER_RE.match(s):
        parts = s.split(" ", 1)
        return Row(parts[0], parts[1] if len(parts) > 1 else "", False, page)
    return Row("", s, False, page)


def _repeating(pages_lines: list[list[str]]) -> set:
    """Kopf- und Fusszeilen: gleiche Zeile (Ziffern gleichgesetzt) auf mindestens 40 % der Seiten"""
    if len(pages_lines) < 3:
        return set()
    cnt: Counter = Counter()
    for lines in pages_lines:
        keys = {re.sub(r"[0-9]+", "#", " ".join(l.split())) for l in lines[:4] + lines[-3:]}
        cnt.update(keys)
    lim = max(3, int(0.4 * len(pages_lines)))
    return {k for k, v in cnt.items() if v >= lim}


def rows_of(pages: list[str]) -> list[Row]:
    pages_lines = [_raw_lines(t) for t in pages]
    rep = _repeating(pages_lines)
    all_lines = [l for ls in pages_lines for l in ls]
    col = _second_column(all_lines)
    layout = col is not None and sum(1 for l in all_lines if GAP_RE.search(l.strip())) >= 0.15 * max(1, len(all_lines))
    rows: list[Row] = []
    for i, lines in enumerate(pages_lines, start=1):
        for l in lines:
            key = re.sub(r"[0-9]+", "#", " ".join(l.split()))
            if key in rep or PAGE_NO_RE.match(" ".join(l.split())):
                continue
            rows.append(_split(l, col, i) if layout else _split_by_label(l, i))
    return rows


# ----------------------------------------------------------------------------
# Schluessel
# ----------------------------------------------------------------------------

# (Anfang des gefalteten Schluessels, Feld); Reihenfolge zaehlt
LABELS = (
    ("anbieter", "provider"),
    ("modulverantwort", "resp"),
    ("verantwortliche lehrende", "resp"),
    ("beteiligte dozierende", "other"),
    ("dozent", "other"),
    ("dozierende", "other"),
    ("lehrende", "other"),
    ("modultyp", "kind"),
    ("modulname", "title"),
    ("modultitel", "title"),
    ("modul-code", "code"),
    ("modulcode", "code"),
    ("modulnummer", "code"),
    ("kennnummer", "code"),
    ("haeufigkeit", "freq"),
    ("semesterlage", "semlage"),
    ("studiensemester", "semester"),
    ("empfohlenes fachsemester", "semester"),
    ("empfohlenes semester", "semester"),
    ("position im", "semester"),
    ("dauer", "duration"),
    ("verwendbarkeit", "usage"),
    ("voraussetzungen fuer die vergabe", "other"),
    ("voraussetzung fuer die vergabe", "other"),
    ("eingangsvoraussetzung", "prereq"),
    ("teilnahmevoraussetzung", "prereq"),
    ("voraussetzungen", "prereq"),
    ("empfohlene vorkenntnisse", "prereq"),
    ("vorkenntnisse", "prereq"),
    ("art der", "lv"),
    ("art, anzahl", "lv"),
    ("lehrveranstaltungen", "lv"),
    ("lehr- und lernform", "lv"),
    ("lehrformen", "lv"),
    ("semesterwochenstunden", "lp"),
    ("ects", "lp"),
    ("leistungspunkte", "lp"),
    ("arbeitsaufwand", "lp"),
    ("workload", "lp"),
    ("notenskala", "other"),
    ("benotung", "other"),
    ("pruefungs- und studienleistung", "exam_cw"),
    ("pruefungsanforderung", "other"),
    ("pruefungsleistung", "exam"),
    ("pruefungsform", "exam"),
    ("studienleistung", "coursework"),
    ("lehrinhalt", "content"),
    ("inhalte", "content"),
    ("inhalt", "content"),
    ("lern-/kompetenzziele", "goals"),
    ("lern- und kompetenzziele", "goals"),
    ("kompetenzziele", "goals"),
    ("qualifikationsziele", "goals"),
    ("lernziele", "goals"),
    ("lernergebnisse", "goals"),
    ("schluesselkompetenzen", "other"),
    ("grundlegende literatur", "literature"),
    ("literatur", "literature"),
    ("unterrichtssprache", "language"),
    ("sprache", "language"),
    ("anschluesse", "prereq"),
    ("vorausgesetzte kenntnisse", "prereq"),
    ("bemerkung", "other"),
    ("hinweis", "other"),
    ("besonderheiten", "other"),
)
LABEL_PREFIXES = {lab for lab, _ in LABELS}
TEXT_FIELDS = ("content", "goals", "literature")
HEADER_RE = re.compile(r"^(?:[A-Za-zÄÖÜäöüß-]*modul\b|Modul\b|Bachelorarbeit\b|Masterarbeit\b|Abschlussmodul\b)",
                       re.I)
STOP_LEFT_RE = re.compile(r"(?:\bfür die|\bder|\bdie|\bdes|/|,|\bin|\bim|\bnach|\bpro|\bzur|\bzum|\bvon|\bmit)$",
                          re.I)
AND_RE = re.compile(r"(?:\bund|-)$")


def label_key(label: str) -> str | None:
    f = _fold(" ".join(label.split())).strip(" :")
    if "semesterlage" in f and "haeufigkeit" in f:
        return "semlage_freq"
    if "pruefungsleistung" in f and "studienleistung" in f:
        return "exam_cw"
    for lab, key in LABELS:
        if f.startswith(lab):
            return key
    return None


def _is_header(row: Row) -> bool:
    if not row.left or not row.right or row.full or label_key(row.left) or TOC_RE.search(row.text()):
        return False
    if row.right[:1].islower():
        return False
    return bool(HEADER_RE.match(row.left))


# ----------------------------------------------------------------------------
# Module
# ----------------------------------------------------------------------------

CODE_CELL_RE = re.compile(r"^(?:Modul-?|Code ?:?|Modul-Code:?|x{2,}|[0-9]{1,3}(?: ?[0-9]{3})+|[0-9]{4,6})$", re.I)
LV_LINE_RE = re.compile(r"\bSWS\b|^[A-Za-z]{2,6}[A-Z]?[0-9]+[a-z]?:|^[•\-–] ")
SECTION_RE = re.compile(r"^(?:[0-9]+\.|[A-Z]\))\s+[A-ZÄÖÜ]|^Modulkatalog\b.*[Bb]ereich|als (?:Erst|Zweit)fach$"
                        r"|^(?:Pflicht|Wahlpflicht|Wahl|Kern|Profil|Ergänzungs|Abschluss)bereich\b|^(?:Studien)?[Ss]chwerpunkt\b"
                        r"|^Module (?:im|des|der|für) ")
NUM_RE = r"[0-9]+(?:[.,][0-9]+)?"
LP_RE = re.compile(r"(" + NUM_RE + r") ?(?:LP|ECTS|Leistungspunkte|CP|Credits)\b")
SEM_RE = re.compile(r"([0-9]{1,2}) ?\. ?(?:[-–/]|bis|und|oder)? ?(?:[0-9]{1,2} ?\. ?)?(?:Fach)?(?:semester|Semester|Sem\b)")
SEM_AB_RE = re.compile(r"(?:ab|im|Ab|Im) (?:dem )?([0-9]{1,2})\.")


def _modules(rows: list[Row]) -> list[dict]:
    """Zeilen -> Rohbloecke je Modul {header: [Row], fields: [(Schluessel, [Werte])], page, area}"""
    starts = []
    for i, r in enumerate(rows):
        if not _is_header(r):
            continue
        # ein Kopf ist nur einer, wenn bald Tabellenschluessel folgen
        ahead = [label_key(x.left) for x in rows[i + 1:i + 16] if x.left and not x.full]
        if any(k in ("provider", "resp", "freq", "semlage", "semlage_freq", "lp", "usage") for k in ahead):
            starts.append(i)
    blocks = []
    area = None
    prev_end = 0
    for n, s in enumerate(starts):
        # Abschnittsueberschriften vor dem Kopf (Bereich)
        for r in rows[prev_end:s]:
            if (r.full or (r.left and not r.right)) and SECTION_RE.search(r.left) and not label_key(r.left) \
                    and len(r.left) < 120 and not TOC_RE.search(r.left):
                name = re.sub(r"^(?:[0-9]+\.|[A-Z]\)|Modulkatalog|Module im|Module des|Module der|Module für)\s+", "",
                              r.left).strip()
                if name and _fold(name) not in ("modulkatalog", "qualifikationsziele", "inhaltsverzeichnis"):
                    area = name
        end = starts[n + 1] if n + 1 < len(starts) else len(rows)
        # Abschnittsueberschriften direkt vor dem naechsten Kopf gehoeren nicht mehr zu diesem Modul
        cut = end
        while cut - 1 > s and (rows[cut - 1].full or (rows[cut - 1].left and not rows[cut - 1].right)) \
                and SECTION_RE.search(rows[cut - 1].left) and not label_key(rows[cut - 1].left):
            cut -= 1
        header = [rows[s]]
        j = s + 1
        while j < cut and not rows[j].left and not rows[j].full:
            header.append(rows[j])
            j += 1
        while j < cut and rows[j].left and not label_key(rows[j].left) and not rows[j].full \
                and j - s < 8:
            header.append(rows[j])
            j += 1
            while j < cut and not rows[j].left and not rows[j].full:
                header.append(rows[j])
                j += 1
        fields: list[list] = []
        last_left = ""
        for r in rows[j:cut]:
            if r.full:
                if fields:
                    fields[-1][1].append(r.left)
                continue
            if r.left:
                key = label_key(r.left)
                if not fields:
                    cont = False
                elif AND_RE.search(last_left):
                    cont = True
                elif key:
                    cont = False
                else:
                    cont = bool(STOP_LEFT_RE.search(last_left) or r.left[:1].islower() or r.left[:1] in "(/")
                if cont:
                    fields[-1][0] += " " + r.left
                elif key:
                    fields.append([r.left, []])
                elif fields and fields[-1][0] and label_key(fields[-1][0]) in TEXT_FIELDS and len(r.left) > 40:
                    fields[-1][1].append(r.left)
                else:
                    fields.append([r.left, []])
                last_left = r.left
            if r.right and fields:
                fields[-1][1].append(r.right)
        blocks.append({"header": header, "fields": fields, "page": rows[s].page, "area": area})
        prev_end = cut
    return blocks


HEADER_CONT_RE = re.compile(r"^(?:\(|[a-zäöü]|Wahlpflicht|Pflicht|Wahl|LSo|LBS|LG|TE|Master|Bachelor|FüBa|Politik)")


def _title_code(header: list[Row]) -> tuple[str, str | None, str]:
    """Kopfzeilen -> (Titel, Kennung, Text links)"""
    left = " ".join(r.left for r in header if r.left)
    code = None
    title_parts: list[str] = []
    for k, r in enumerate(header):
        cells = _cells(r.right) if r.right else []
        keep = []
        for c in cells:
            c2 = c.strip()
            c2 = re.sub(r"^(?:Modulname|Modultitel|Modulbezeichnung):?\s*", "", c2, flags=re.I)
            if not c2:
                continue
            m = re.fullmatch(r"(?:Modul-?\s*)?Code\s*:?\s*(.*)", c2, re.I)
            if m:
                v = m.group(1).strip(" :")
                if v and not re.fullmatch(r"x+", v, re.I):
                    code = v
                continue
            if CODE_CELL_RE.match(c2):
                if not re.fullmatch(r"x+|Modul-?|Code ?:?", c2, re.I):
                    code = c2
                continue
            # Zelle "Titel 14 800" (Kennung am Ende ohne breite Luecke)
            m = re.fullmatch(r"(.+?)\s+([0-9]{1,3} [0-9]{3}|[0-9]{4,6})", c2)
            if m and not title_parts and k == 0:
                code = m.group(2)
                c2 = m.group(1)
            keep.append(c2)
        text = " ".join(keep).strip()
        if not text:
            continue
        if title_parts:
            prev = " ".join(title_parts)
            open_paren = prev.count("(") > prev.count(")")
            if LV_LINE_RE.search(text) or (r.left and not open_paren) or len(prev) + len(text) > 160 \
                    or (not open_paren and (":" in text or prev.endswith(")") or re.search(r"[0-9]", text))):
                break
        title_parts.append(text)
    title = " ".join(title_parts)
    title = re.sub(r"\s+", " ", title).strip(" :")
    return title, code, left


PROGRAM_TAGS = {
    # Familie -> Muster in Verwendbarkeit / Titelzusatz / Kopf (gefaltet: Umlaute ausgeschrieben, klein;
    # Zertifikatsprogramme und LBS-Sprint vorher ersetzt)
    "fueba": r"fueba|fuessa|faecheruebergreifende|2-faecher|zwei-faecher",
    "te": r"\bte\b|technical education",
    "lg": r"master lg|\blg\b|lehramt an gymnasien|\bgymnasi",
    "lbs": r"\blbs\b|berufsbildend",
    "sprint": r"\bsprint\b",
    "so_ba": r"bachelor(?:studiengang)? so(?:nderpaed[a-z]*)?\b|\bbso\b|bachelor so\)",
    "so_ma": r"\blso\b|lehramt (?:fuer )?sonderpaed|master sonderpaed|\blsop\b",
}


def program_family(program_key: str | None) -> str | None:
    k = (program_key or "").lower()
    if not k:
        return None
    if "sprint" in k:
        return "sprint"
    if "faecheruebergreifenden-bachelor" in k:
        return "fueba"
    if "technical-education" in k:
        return "te"
    if "lehramt-an-gymnasien" in k:
        return "lg"
    if "berufsbildenden-schulen" in k:
        return "lbs"
    if "bachelorstudiengang-sonderpaedagogik" in k:
        return "so_ba"
    if "lehramt-fuer-sonderpaedagogik" in k:
        return "so_ma"
    return None


def _families(text: str) -> set:
    f = _fold(text or "")
    f = re.sub(r"zert(?:ifikats(?:programm|studiengang))?\.? ?(?:drittes fach )?(?:lg|lbs|lso)\b", " ", f)
    f = re.sub(r"\(?lbs[- ]?sprint\)?|lehramt an berufsbildenden schulen ?\(lbs[- ]?sprint\)|"
               r"berufsbildenden schulen fuer fachbachelor", " sprint ", f)
    return {fam for fam, pat in PROGRAM_TAGS.items() if re.search(pat, f)}


def _value(fields: list, *keys) -> str:
    out = []
    for label, vals in fields:
        if label_key(label) in keys:
            out.extend(vals)
    return " ".join(" ".join(out).split())


def _text(fields: list, key: str) -> str | None:
    out = []
    for label, vals in fields:
        if label_key(label) == key:
            out.extend(vals)
    t = "\n".join(" ".join(v.split()) for v in out if v).strip()
    return t or None


BULLET_RE = re.compile(r"^[•\-–▪·]\s*|\s[•▪·]\s")


def _clean(s: str) -> str:
    s = re.sub(r"\s*[•▪·]\s*", " ", s or "")
    return " ".join(s.split()).strip(" ;,")


def _exam_cw(text: str) -> tuple[str | None, str | None]:
    """'Pruefungsleistung: ... Studienleistungen: ...' trennen"""
    t = _clean(text)
    m_pl = re.search(r"Prüfungsleistung(?:en)?:?", t)
    m_sl = re.search(r"Studienleistung(?:en)?:", t)
    exam = cw = None
    if m_pl and m_sl:
        if m_pl.start() < m_sl.start():
            exam, cw = t[m_pl.end():m_sl.start()], t[m_sl.end():]
        else:
            cw, exam = t[m_sl.end():m_pl.start()], t[m_pl.end():]
    elif m_pl:
        exam = t[m_pl.end():]
    else:
        exam = t
    return exam, cw


def _short(s: str | None, limit: int = 300) -> str | None:
    s = _clean(s or "")
    if not s or re.fullmatch(r"[-–—/.\s]*", s) or _fold(s) in ("keine", "-", "nein", "entfaellt", "keine.", "none"):
        return None
    return clip(s, limit)


def _semester(text: str) -> int | None:
    m = SEM_RE.search(text or "")
    if m:
        return int(m.group(1))
    m = SEM_AB_RE.search(text or "")
    if m and re.search(r"Semester|Sem\.", text[m.end():m.end() + 25]):
        return int(m.group(1))
    return None


HOURS_RE = re.compile(r"([0-9]+(?:[.,][0-9]+)?) ?(?:Stunden|Std\.?|h|Arbeitsstunden)\b")


def workload_phil(text: str, lp) -> float | None:
    """'8 LP/ 240 Stunden 75 Kontaktstunden 165 Selbststudium' -> 240; 'Praesenzzeit: 75 h' zaehlt nicht als Summe.
    Passt die Zahl nicht zu den LP (weniger als 20 h je LP), lieber keine Angabe."""
    t = text or ""
    for m in HOURS_RE.finditer(t):
        before = _fold(t[max(0, m.start() - 16):m.start()])
        after = _fold(t[m.end():m.end() + 30])
        m2 = re.match(r"\s*(?:selbst|kontakt|praesenz)[a-z]*(\s*:)?", after)
        if re.search(r"praesenz|selbst|kontakt", before) or (m2 and not m2.group(1)):
            continue
        v = number(m.group(1))
        break
    else:
        parts = [number(x) for x in re.findall(r"(?:Präsenzzeit|Selbststudium|Kontaktzeit):? ([0-9]+)", t)]
        if len(parts) < 2:
            parts = [number(x) for x in re.findall(r"([0-9]+) ?(?:h|Std\.?|Stunden)? ?(?:Kontakt|Präsenz|Selbst)", t)]
        v = sum(parts) if len(parts) >= 2 else None
    if v is not None and lp and v < 20 * lp:
        return None
    return v if v else None


def raw_module(block: dict) -> dict:
    title, code, left = _title_code(block["header"])
    f = block["fields"]
    lp_text = _value(f, "lp")
    m = LP_RE.search(lp_text)
    lp = number(m.group(1)) if m else None
    if lp is None:
        m = re.search(r"\(([0-9]+) ?LP\)", _value(f, "lv"))
        lp = None
    exam = _value(f, "exam")
    cw = _value(f, "coursework")
    both = _value(f, "exam_cw")
    if both:
        e2, c2 = _exam_cw(both)
        exam = exam or e2 or ""
        cw = cw or c2 or ""
    exam = re.sub(r"^Prüfungsleistung(?:en)?:\s*", "", _clean(exam))
    cw = re.sub(r"^\(?Voraussetzung für die Vergabe von LP\)?\s*", "", _clean(cw))
    freq = _value(f, "freq", "semlage_freq")
    semlage = _value(f, "semlage", "semlage_freq")
    turnus = turnus_of(freq) if freq else "unbekannt"
    if turnus == "unbekannt":
        turnus = turnus_of(re.split(r"empfohlen|/", semlage)[0]) if semlage else "unbekannt"
    sem_text = _value(f, "semester") or semlage
    kind = kind_of(_value(f, "kind")) or kind_of(left.split(" ")[0] if left else "")
    if kind is None and re.search(r"wahlpflicht", left, re.I):
        kind = "wahlpflicht"
    usage = _value(f, "usage")
    return {
        "title": title,
        "code": code,
        "area": block.get("area"),
        "kind": kind,
        "kind_text": left,
        "lp": lp,
        "semester": _semester(sem_text),
        "turnus": turnus,
        "exam": _short(exam),
        "coursework": _short(cw),
        "prereq": _value(f, "prereq"),
        "language": language_of(_value(f, "language")) if _value(f, "language") else None,
        "workload_h": workload_phil(lp_text, lp),
        "page": block["page"],
        "usage": usage,
        "content": _text(f, "content"),
        "goals": _text(f, "goals"),
        "literature": _text(f, "literature"),
    }


def keep_for_program(raw: dict, family: str | None) -> bool:
    """Modul fuer diesen Studiengang? Massgeblich ist die Verwendbarkeit; nennt sie keinen Studiengang, der Titelzusatz
    oder Kopf. Nennt sie nur Zertifikatsprogramme: nein. Ohne erkennbare Angabe: ja."""
    if not family:
        return True
    usage = raw.get("usage") or ""
    fams = _families(usage)
    if not fams and re.search(r"zert", _fold(usage)):
        return False
    if not fams:
        fams = _families(raw["title"]) | _families(raw.get("kind_text") or "")
    if not fams:
        return True
    return family in fams


def _kind_for_program(raw: dict, family: str | None) -> str | None:
    """'Pflichtmodul (FueBa) und Wahlpflichtmodul (Master LSo)', 'Pflichtmodul im FueBa-Erstfach Wahlpflichtmodul im
    LBS-Sprint' -> Art fuer den Studiengang"""
    text = raw.get("kind_text") or ""
    marks = list(re.finditer(r"(Wahlpflicht|Pflicht|Wahl)(?:modul|bereich)?", text))
    if family and len(marks) > 1:
        for n, m in enumerate(marks):
            seg = text[m.end():marks[n + 1].start() if n + 1 < len(marks) else len(text)]
            if family in _families(seg):
                return kind_of(m.group(1))
    return raw.get("kind")


DESIGNATOR_RE = re.compile(r"^(?:[A-Za-zÄÖÜäöüß]*modul|Modul) +(?:[A-Z]{1,2}(?:\.[A-Z0-9]{1,2})*|MA ?[0-9]+|[IVX]+)$")
KIND_AREA = {"pflicht": "Pflichtmodule", "wahlpflicht": "Wahlpflichtmodule", "wahl": "Wahlmodule",
             "abschluss": "Abschlussarbeit"}


def area_from_header(raw: dict) -> str | None:
    """Bereich aus dem Kopf links, wenn keine Abschnittsueberschrift einen nennt:
    'Pflichtmodul Politikwissenschaft' -> 'Pflichtmodule Politikwissenschaft', 'Basismodul B' -> 'Basismodule',
    'Modul aus den Faechern des Wahlpflichtbereichs, Fach Englisch' -> 'Wahlpflichtbereich: Englisch';
    Kopf mit Studiengangszusaetzen ('Pflichtmodul (FueBa) und Wahlpflichtmodul (Master LSo)') -> nach Art."""
    left = " ".join((raw.get("kind_text") or "").split())
    left = re.sub(r"(\w)- ([a-zäöü])", r"\1\2", left)
    if not left:
        return None
    m = re.search(r"Wahlpflichtbereich\w*,?\s+Fach(?:es)?\s+(.+)$", left)
    if m:
        return "Wahlpflichtbereich: " + m.group(1).strip(" ,")
    if "(" in left or re.search(r"\bim\b|&|,", left) or len(re.findall(r"modul", left, re.I)) > 1:
        return KIND_AREA.get(raw.get("kind") or "")
    words = left.split(" ")
    while len(words) > 1 and re.fullmatch(r"[A-Z]{1,2}(?:\.[A-Z0-9]{1,2})*|[0-9IVX.]+|[A-Z]\.[0-9]+", words[-1]):
        words.pop()
    first = words[0]
    if len(words) > 4 or any(w in ("aus", "den", "des", "der", "im", "in", "und") for w in words):
        return KIND_AREA.get(raw.get("kind") or "")
    if re.fullmatch(r"[A-Za-zÄÖÜäöüß-]*modul", first, re.I):
        words[0] = first + "e"
    else:
        return None
    if _fold(words[0]) == "module" and len(words) == 1:
        return KIND_AREA.get(raw.get("kind") or "")
    return " ".join(words)


def _drop_programme_suffix(title: str) -> str:
    """'Foundations Linguistics (FueBa Erstfach, Zert. LG)' -> 'Foundations Linguistics'"""
    m = re.match(r"^(.*\S)\s*\(([^()]*)\)$", title)
    if m and _families(m.group(2)) or (m and re.search(r"Erstfach|Zweitfach|Zert\.|Master|Bachelor", m.group(2))):
        return m.group(1)
    return title


def build_with_prereqs(meta: dict, raw: list[dict], term: str | None) -> tuple[dict, dict]:
    """build_catalog (gemeinsam mit den Formaten A), Voraussetzungen danach selbst: laengster Titel zuerst, ein
    Treffer verbraucht seine Stelle ("Lineare Algebra I" zaehlt nicht zugleich als "Algebra I")."""
    from app.study_catalog import _mentions
    texts_by_title: dict = {}
    for r in raw:
        key = " ".join((r.get("title") or "").split()).strip(" .:;-–").lower()
        if r.get("prereq"):
            texts_by_title.setdefault(key, r["prereq"])
    catalog, texts = build_catalog(meta, [dict(r, prereq="") for r in raw], term=term)
    mods = catalog["modules"]
    by_len = sorted(mods, key=lambda m: len(m["title"]), reverse=True)
    for m in mods:
        text = texts_by_title.get(m["title"].lower(), "")
        if not text:
            continue
        out = []
        hay = text
        for o in by_len:
            if o["id"] == m["id"] or len(o["title"]) < 6:
                continue
            if _mentions(hay, o["title"]):
                out.append(o["id"])
                hay = re.sub(re.escape(o["title"]), " " * len(o["title"]), hay, flags=re.I)
        order = {o["id"]: i for i, o in enumerate(mods)}
        m["prerequisites"] = sorted(out, key=lambda i: order[i])
    return catalog, texts


MONTHS = {"januar": 1, "februar": 2, "maerz": 3, "april": 4, "mai": 5, "juni": 6, "juli": 7, "august": 8,
          "september": 9, "oktober": 10, "november": 11, "dezember": 12}


def catalog_term(meta_term: str | None, first_text: str, hint: str | None = None,
                 fetched_at: str | None = None) -> str | None:
    """Katalogsemester: Registerangabe 'WS 2026/27' / 'SS 2026', sonst das spaeteste Datum der ersten Seiten
    ('Stand: 01.10.2026', 'Stand: Oktober 2026', 'Stand 10/2026', 'ab WS 2022/23', 'Wintersemester 2025/26') als
    das an diesem Tag laufende Semester; 'Version vom 1. Juli 2026' zaehlt ebenso. hint: Semesterangabe des Registers,
    die kein Semester ist ('Stand 10.09.2025', 'Stand 10/2026'); ohne jedes Datum das Semester des Abrufs."""
    from app.study_catalog import TERM_RE, current_term
    if meta_term and TERM_RE.match(meta_term):
        return meta_term
    t = _fold((hint or "") + "\n" + (first_text or ""))
    dates = []
    for d, mo, y in re.findall(r"\b([0-9]{1,2})\.([0-9]{1,2})\.(20[0-9]{2})\b", t):
        dates.append((int(y), int(mo), int(d)))
    for d, mon, y in re.findall(r"\b(?:([0-9]{1,2})\. ?)?(" + "|".join(MONTHS) + r") (20[0-9]{2})\b", t):
        dates.append((int(y), MONTHS[mon], int(d or 1)))
    for mo, y in re.findall(r"\b([0-9]{1,2})/(20[0-9]{2})\b", t):
        if 1 <= int(mo) <= 12:
            dates.append((int(y), int(mo), 1))
    for word, y in re.findall(r"\b(wintersemester|sommersemester|wise|sose|ws|ss) ?(20[0-9]{2})", t):
        dates.append((int(y), 10 if word in ("wintersemester", "wise", "ws") else 4, 1))
    if not dates and fetched_at and re.match(r"20[0-9]{2}-[0-9]{2}-[0-9]{2}", fetched_at):
        return current_term(fetched_at[:10])
    if not dates:
        return None
    y, mo, d = max(dates)
    return current_term(f"{y:04d}-{mo:02d}-{min(max(d, 1), 28):02d}")


def parse(pages: list[str], meta: dict) -> tuple[dict, dict]:
    """Seitentexte (am besten mit Spaltenlage) -> (Katalog, lokale Texte)"""
    rows = rows_of(pages)
    blocks = _modules(rows)
    family = program_family(meta.get("program_key"))
    raw = []
    for b in blocks:
        r = raw_module(b)
        if not r["title"]:
            continue
        if meta.get("shared_catalog") and not keep_for_program(r, family):
            continue
        r["kind"] = _kind_for_program(r, family)
        if not r["area"]:
            r["area"] = area_from_header(r)
        if not r["code"] and DESIGNATOR_RE.match(r.get("kind_text") or ""):
            r["code"] = " ".join(r["kind_text"].split())
        if meta.get("shared_catalog"):
            r["title"] = _drop_programme_suffix(r["title"])
        raw.append(r)
    first = "\n".join(" ".join(l.split()) for t in pages[:2] for l in normalize_lines(t))
    term = catalog_term(meta.get("catalog_term"), first, meta.get("term_hint"),
                        (meta.get("source") or {}).get("fetched_at"))
    return build_with_prereqs(meta, raw, term)

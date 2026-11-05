"""Abgaben, Tests und Pruefungstermine in Texten erkennen (Seitentexte der PDFs, Dateinamen, Ankuendigungen), ohne KI.

Python-Fassung von `DueDetection.swift` (UniFlowCore/LocalBackend/Due, 05.11.2026 fuer Web und Windows portiert).
Reine Funktion: Text und Rahmen hinein, Treffer heraus; den Lauf ueber die Datenbank macht app/due_store.py.
Beide Fassungen pruefen sich gegen packages/shared-contracts/fixtures/due-detection/cases.json
(tests/test_due_detection.py; die Swift-Tests koennen dieselbe Datei lesen).

Regeln (lieber weniger, dafuer richtige Treffer), wie in Swift:
- Ein Treffer braucht ein Schluesselwort (Abgabe, Testat, Kurzklausur, Anmeldung ... deutsch und englisch) und ein
  Datum nah beieinander: gleicher Satz bzw. gleiche Tabellenzeile, hoechstens sechs Woerter dazwischen; ueber einen
  Zeilenumbruch nur, wenn der Satz erkennbar weiterlaeuft oder Datum und Schluesselwort je allein in einer Zeile stehen.
- Jedes Datum gehoert hoechstens zu einem Schluesselwort (das naechste gewinnt), ausser bei Datumslisten.
- Jahr ohne Angabe: das Jahr, in dem der Tag im erlaubten Zeitraum (laufendes Semester plus Pruefungszeit) und nah am
  Bezugstag liegt; ein genannter Wochentag muss passen. Daten ausserhalb des Zeitraums fallen weg.
- Kein Datum: "Aufgabe 2.1.", "Folien vom 02.11.", "Stand: 01.10.2026". Kein Termin: Loesungen, Rueckgabe, Einsicht.
- Ueberschriften mit Unterpunkten, Testat-Spalten in Semesterplaenen, englisch klein "test" nur mit Pruefungsbezug,
  Bereiche nach "Klausuren"/"Pruefungen" (Anmeldung oder nichts), "Pruefungszeitraum" nie ein Termin.

Hinweis zur Uebersetzung der Muster: Python `re` kennt kein \\p{L}; Buchstabe = [^\\W\\d_], Buchstabe oder Ziffer =
[^\\W_]. Gross-/Kleinbuchstaben (\\p{Lu}/\\p{Ll}) prueft der Code nach dem Treffer (str.isupper/islower) so, dass
die Treffer dieselben bleiben wie bei NSRegularExpression.
"""
from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field, replace
from datetime import date

from . import announcements, holidays, scriptsearch

L = r"[^\W\d_]"          # \p{L}
LN = r"[^\W_]"           # [\p{L}\p{N}]
I = re.IGNORECASE

KINDS = ("abgabe", "test", "klausur", "anmeldung", "sonstiges")
RANK = {"klausur": 0, "test": 1, "abgabe": 2, "anmeldung": 3, "sonstiges": 4}
KIND_LABEL = {"abgabe": "Abgabe", "test": "Test", "klausur": "Klausur", "anmeldung": "Anmeldung", "sonstiges": "Frist"}


# ---------------------------------------------------------------- Tage

def day_number(d: date) -> int:
    return d.toordinal()


def parse_iso(s: str | None) -> int | None:
    try:
        return date.fromisoformat(str(s or "")[:10]).toordinal()
    except ValueError:
        return None


def iso(n: int) -> str:
    return date.fromordinal(n).isoformat()


def civil(n: int) -> date:
    return date.fromordinal(n)


def weekday(n: int) -> int:
    """0 = Montag"""
    return date.fromordinal(n).weekday()


@dataclass
class Hit:
    date: str
    time: str | None
    kind: str
    label: str
    snippet: str

    def summary(self) -> str:
        return f"{self.date}{' ' + self.time if self.time else ''} {self.kind} {self.label}"


@dataclass(frozen=True)
class SemesterKey:
    winter: bool
    year: int

    def __str__(self) -> str:
        return f"WiSe {self.year}/{(self.year + 1) % 100:02d}" if self.winter else f"SoSe {self.year}"


@dataclass
class Window:
    """Erlaubter Zeitraum: laufendes Semester (Vorlesungszeit) plus Pruefungszeit bis zum Beginn des naechsten"""
    start: int
    end: int
    today: int
    semesters: set = field(default_factory=set)

    LEAD = 21          # Tage vor Vorlesungsbeginn, die schon zum Semester gehoeren
    EXAM_TAIL = 70     # Pruefungszeit nach dem letzten bekannten Semester

    def contains(self, day: int) -> bool:
        return self.start <= day <= self.end

    @classmethod
    def current(cls, university: str, today: int, term: tuple[str, str, str] | None = None) -> "Window | None":
        """Laufende Semester laut Zeitplan der Hochschule (holidays.SEMESTERS) und aktivem Semester der App (`terms`):
        je Semester von 21 Tagen vor Vorlesungsbeginn bis zum Tag vor dem Beginn des naechsten. None, wenn nichts bekannt ist."""
        spans: list[tuple[int, int, SemesterKey | None]] = []
        sems = holidays.SEMESTERS.get(university) or []
        for i, s in enumerate(sems):
            a, e = parse_iso(s[1]), parse_iso(s[2])
            if a is None or e is None:
                continue
            nxt = parse_iso(sems[i + 1][1]) if i + 1 < len(sems) else None
            keys = semesters(s[0])
            spans.append((a - cls.LEAD, nxt - 1 if nxt is not None else e + cls.EXAM_TAIL, keys[0] if keys else None))
        if term:
            a, e = parse_iso(term[1]), parse_iso(term[2])
            if a is not None and e is not None and a <= e:
                keys = semesters(term[0] or "")
                spans.append((a - cls.LEAD, e + cls.EXAM_TAIL, keys[0] if keys else None))
        hits = [s for s in spans if s[0] <= today <= s[1]]
        if not hits:
            later = [s for s in spans if s[0] > today]
            if later:
                nxt = min(later, key=lambda s: s[0])
                if nxt[0] - today <= 60:
                    hits = [nxt]
        if not hits:
            return None
        return cls(min(h[0] for h in hits), max(h[1] for h in hits), today, {h[2] for h in hits if h[2] is not None})


@dataclass
class Context:
    window: Window
    reference: int | None = None     # Bezugstag: ein Datum ohne Jahr liegt hoechstens 45 Tage davor und 300 danach
    name: str | None = None          # Dateiname (fuer "Abgabe Blatt 3")
    head: str | None = None          # Kopf des Dokuments (erste Zeilen der ersten Seite)
    allow_yearless: bool = True      # nein bei Loesungen und Altklausuren
    allow_exams: bool = True


# ---------------------------------------------------------------- Hilfen

def has(rx: re.Pattern, s: str) -> bool:
    return rx.search(s) is not None


def _sub_checked(rx: re.Pattern, text: str, ok, repl) -> str:
    """Wie re.sub, aber ein Treffer zaehlt nur, wenn ok(m) gilt; sonst sucht es ab der naechsten Stelle weiter (wie ein
    Muster, dessen letzte Zeichenklasse enger ist, z. B. \\p{Ll})."""
    out, pos, last = [], 0, 0
    while True:
        m = rx.search(text, pos)
        if not m:
            break
        if ok(m):
            out.append(text[last:m.start()])
            out.append(repl(m))
            last = pos = m.end()
        else:
            pos = m.start() + 1
    out.append(text[last:])
    return "".join(out)


# ---------------------------------------------------------------- Semester im Text

SEMESTER_RE = re.compile(
    rf"(?<!{L})(wintersemester|winter\s+semester|winter\s+term|wise|ws|sommersemester|summer\s+semester|summer\s+term|sose|ss)"
    r"\s*\.?\s*(20[0-9]{2}|[0-9]{2})(?:\s*/\s*(20[0-9]{2}|[0-9]{2}))?(?![0-9])", I)


def semesters(text: str) -> list[SemesterKey]:
    """Genannte Semester in Reihenfolge ("Wintersemester 2020/21", "WS 20/21", "WiSe 2026/27", "SoSe 2022", "SS22")"""
    out: list[SemesterKey] = []
    for m in SEMESTER_RE.finditer(text or ""):
        word, y = m.group(1).lower(), m.group(2)
        year = int(y)
        if len(y) == 2:
            if not 10 <= year <= 60:
                continue
            year += 2000
        winter = word.startswith("w")
        if m.group(3) is not None:
            second = int(m.group(3))
            if not (winter and second % 100 == (year + 1) % 100):
                continue
        key = SemesterKey(winter, year)
        if key not in out:
            out.append(key)
    return out


def _first_lines(text: str, n: int = 2) -> str:
    return "\n".join([x for x in text.split("\n") if x][:n])


def head_lines(text: str | None) -> str | None:
    """Erste zwei Zeilen eines Texts (Kopf einer Seite), hoechstens 120 Zeichen"""
    if text is None:
        return None
    return _first_lines(text)[:120]


def head_semester(first_page: str | None, name: str | None) -> SemesterKey | None:
    """Semester im Kopf eines Dokuments (erste 600 Zeichen der ersten Seite) bzw. im Dateinamen"""
    if first_page is not None:
        s = semesters(first_page[:600])
        if s:
            return s[0]
    if name is not None:
        s = semesters(name.replace("_", " "))
        if s:
            return s[0]
    return None


# ---------------------------------------------------------------- Text vorbereiten

HYPHEN_BREAK_RE = re.compile(rf"({L})-[ \t]*\n[ \t]*({L})")
SPACES_RE = re.compile("[ \t    ]+")


def prepare(raw: str) -> str:
    """Zerlegte Umlaute, Ligaturen (NFKC), Trennstriche am Zeilenende ("Abga-\\nbe" -> "Abgabe", "Probe-\\nKurztest" ->
    "Probe-Kurztest"), Seitenumbruch als Absatz, Leerraum zusammengezogen"""
    t = unicodedata.normalize("NFKC", scriptsearch.normalize(raw or ""))
    t = t.replace("\r\n", "\n").replace("\r", "\n").replace("\x0c", "\n\n").replace("­", "")
    t = _sub_checked(HYPHEN_BREAK_RE, t, lambda m: m.group(2).islower(), lambda m: m.group(1) + m.group(2))
    t = _sub_checked(HYPHEN_BREAK_RE, t, lambda m: m.group(2).isupper(), lambda m: m.group(1) + "-" + m.group(2))
    return SPACES_RE.sub(" ", t)


# ---------------------------------------------------------------- Daten

@dataclass
class Parts:
    day: int
    month: int
    year: int | None = None
    weekday: int | None = None


@dataclass
class DateToken:
    start: int            # ganze Angabe: Wochentag, Datum bzw. Bereich, Uhrzeit
    end: int
    core: int             # Beginn des eigentlichen Datums (ohne Wochentag)
    s: Parts
    e: Parts | None = None
    time: str | None = None


NUMERIC_RE = re.compile(r"(?<![^\W_])(?<![./])([0-9]{1,2})\.\s?([0-9]{1,2})\.(?:\s?(20[0-9]{2})(?![0-9])|([0-9]{2})(?![0-9.:]))?(?![0-9])")
OPEN_START_RE = re.compile(
    rf"(?<![^\W_])(?<![./])([0-9]{{1,2}})\.([0-9]{{1,2}})(?=\s*(?:-|–|—|bis)\s*(?:{L}{{2,10}}\.?,?\s*)?[0-9]{{1,2}}\.\s?[0-9]{{1,2}}\.)", I)
ISO_RE = re.compile(r"(?<![0-9\-./])(20[0-9]{2})-([0-9]{2})-([0-9]{2})(?![0-9\-])(?:[T ]([0-9]{2}):([0-9]{2}))?")
_GERMAN_NAMES = "|".join(sorted(announcements.MONTHS, key=len, reverse=True))
GERMAN_MONTH_RE = re.compile(
    rf"(?<![^\W_])(?<!\.)([0-9]{{1,2}})\.\s?({_GERMAN_NAMES})\.?(?:\s+(20[0-9]{{2}})(?![0-9]))?(?!{L})", I)
ENGLISH_MONTHS = [("january", 1), ("february", 2), ("march", 3), ("april", 4), ("may", 5), ("june", 6), ("july", 7),
                  ("august", 8), ("september", 9), ("october", 10), ("november", 11), ("december", 12), ("jan", 1),
                  ("feb", 2), ("mar", 3), ("apr", 4), ("jun", 6), ("jul", 7), ("aug", 8), ("sept", 9), ("sep", 9),
                  ("oct", 10), ("nov", 11), ("dec", 12)]
ENGLISH = dict(ENGLISH_MONTHS)
_EN_NAMES = "|".join(sorted((n for n, _ in ENGLISH_MONTHS), key=len, reverse=True))
ENGLISH_DAY_MONTH_RE = re.compile(
    rf"(?<![^\W_])(?<!\.)([0-9]{{1,2}})(?:st|nd|rd|th)?\s+({_EN_NAMES})\.?,?\s+(20[0-9]{{2}})(?![0-9])", I)
ENGLISH_MONTH_DAY_RE = re.compile(rf"(?<!{L})({_EN_NAMES})\.?\s+([0-9]{{1,2}})(?:st|nd|rd|th)?,?\s+(20[0-9]{{2}})(?![0-9])", I)

WEEKDAY_LONG_RE = re.compile(
    rf"(?<!{L})(montag|dienstag|mittwoch|donnerstag|freitag|samstag|sonnabend|sonntag|monday|tuesday|wednesday|thursday|friday|saturday|sunday)"
    r"\.?,?\s*(?:(?:den|dem|the)\s+)?$", I)
WEEKDAY_SHORT_RE = re.compile(
    rf"(?<!{L})(Mo|Di|Mi|Do|Fr|Sa|So|Mon|Tue|Tues|Wed|Thu|Thur|Thurs|Fri|Sat|Sun|MO|DI|MI|DO|FR|SA|SO)\.?,?\s*(?:(?:den|dem|the)\s+)?$")
WEEKDAYS = {"montag": 0, "dienstag": 1, "mittwoch": 2, "donnerstag": 3, "freitag": 4, "samstag": 5, "sonnabend": 5, "sonntag": 6,
            "monday": 0, "tuesday": 1, "wednesday": 2, "thursday": 3, "friday": 4, "saturday": 5, "sunday": 6,
            "mo": 0, "di": 1, "mi": 2, "do": 3, "fr": 4, "sa": 5, "so": 6,
            "mon": 0, "tue": 1, "tues": 1, "wed": 2, "thu": 3, "thur": 3, "thurs": 3, "fri": 4, "sat": 5, "sun": 6}

NUMBERING_RE = re.compile(
    rf"(?<!{L})(?:aufgabe|aufg|teilaufgabe|kapitel|kap|abschnitt|satz|lemma|definition|def|abbildung|abb|tabelle|tab|folie|seite|s|nr|no|"
    r"gleichung|gl|beispiel|bsp|theorem|korollar|proposition|bemerkung|exercise|problem|section|chapter|(?:ü|ue)bung|blatt|teil|"
    r"version|v|§)\s*\.?\s*$", I)
RANGE_GAP_RE = re.compile(r"^\s*(?:-|–|—|bis(?:\s+(?:zum|einschlie(?:ß|ss)lich|einschl\.))?|to|until|till)\s*$", I)
TIME_RE = re.compile(
    r"\s*(?:[,(]|–|-)?\s*(?:(?:um|bis|ab|gegen|at|by|until)\s+)?(?:sp(?:ä|ae)testens\s+)?([0-9]{1,2})(?::([0-9]{2})|\.([0-9]{2})"
    r"(?=\s*(?:Uhr|h\b))|(?=\s*(?:Uhr|h\b|[-–]\s*[0-9]{1,2}(?:[:.][0-9]{2})?\s*Uhr)))\s*(?:Uhr|h\b)?\s*\)?\s*(a\.?m\.?|p\.?m\.?)?", I)
LIST_GAP_RE = re.compile(r"^\s*(?:,|;|/|&|\+|und|sowie|bzw\.?|oder|and|or)?\s*(?:(?:und|sowie|and)\s+)?$", I)


def _days_in_month(year: int, month: int) -> int:
    return ((date(year + (month == 12), month % 12 + 1, 1)) - date(year, month, 1)).days


def valid(p: Parts, year: int) -> int | None:
    if not 1 <= p.month <= 12 or not 1 <= year <= 9998 or p.day < 1 or p.day > _days_in_month(year, p.month):
        return None
    return date(year, p.month, p.day).toordinal()


def find_dates(text: str) -> list[DateToken]:
    """Alle Datumsangaben eines Texts, nach Position, ohne Ueberlappungen; mit Wochentag davor, Bereich und Uhrzeit"""
    found: list[tuple[int, int, Parts, str | None]] = []
    numbering_end = -1
    open_starts: set[int] = set()
    numeric = sorted([(m, False) for m in NUMERIC_RE.finditer(text)] + [(m, True) for m in OPEN_START_RE.finditer(text)],
                     key=lambda x: x[0].start())
    for m, is_open in numeric:
        d, mo = int(m.group(1)), int(m.group(2))
        if is_open:
            open_starts.add(m.start())
        year = None
        if not is_open and m.group(3) is not None:
            year = int(m.group(3))
        elif not is_open and m.group(4) is not None:
            year = 2000 + int(m.group(4))
        if year is None:
            # "2.1." ohne Jahr: fast immer eine Nummer; ebenso nach "Aufgabe", "Kapitel" ... und in einer Aufzaehlung dahinter
            numbering = len(m.group(1)) == 1 and len(m.group(2)) == 1
            before = text[max(0, m.start() - 16):m.start()]
            if NUMBERING_RE.search(before):
                numbering = True
            if numbering_end >= 0 and m.start() - numbering_end <= 12 and has(LIST_GAP_RE, text[numbering_end:m.start()]):
                numbering = True
            if numbering:
                numbering_end = m.end()
                continue
        found.append((m.start(), m.end(), Parts(d, mo, year), None))
    for m in ISO_RE.finditer(text):
        time = None
        if m.group(4) is not None:
            h, mi = int(m.group(4)), int(m.group(5))
            if 0 <= h <= 23 and 0 <= mi <= 59:
                time = f"{h:02d}:{mi:02d}"
        found.append((m.start(), m.end(), Parts(int(m.group(3)), int(m.group(2)), int(m.group(1))), time))
    for m in GERMAN_MONTH_RE.finditer(text):
        mo = announcements.MONTHS.get(m.group(2).lower())
        if mo is None:
            continue
        found.append((m.start(), m.end(), Parts(int(m.group(1)), mo, int(m.group(3)) if m.group(3) else None), None))
    for m in ENGLISH_DAY_MONTH_RE.finditer(text):
        mo = ENGLISH.get(m.group(2).lower())
        if mo is None:
            continue
        found.append((m.start(), m.end(), Parts(int(m.group(1)), mo, int(m.group(3))), None))
    for m in ENGLISH_MONTH_DAY_RE.finditer(text):
        mo = ENGLISH.get(m.group(1).lower())
        if mo is None:
            continue
        found.append((m.start(), m.end(), Parts(int(m.group(2)), mo, int(m.group(3))), None))
    # Ueberlappungen: der fruehere, bei gleichem Beginn der laengere
    found.sort(key=lambda f: (f[0], -(f[1] - f[0])))
    tokens: list[DateToken] = []
    last_end = -1
    for a, b, parts, time in found:
        if a < last_end:
            continue
        t = DateToken(a, b, a, parts, None, time)
        before = text[max(0, a - 18):a]
        for rx in (WEEKDAY_LONG_RE, WEEKDAY_SHORT_RE):
            w = rx.search(before)
            if w and w.group(1).lower() in WEEKDAYS:
                t.s.weekday = WEEKDAYS[w.group(1).lower()]
                t.start = a - (len(before) - w.start())
                break
        tokens.append(t)
        last_end = b
    # Bereiche: "02.11.–06.11.", "vom 02.11. bis 06.11.2026"
    merged: list[DateToken] = []
    for t in tokens:
        if merged and merged[-1].e is None and merged[-1].time is None:
            prev = merged[-1]
            gs, gl = prev.end, t.start - prev.end
            if 0 <= gl <= 16 and has(RANGE_GAP_RE, text[gs:t.start]):
                prev.e = t.s
                if prev.s.year is None and t.s.year is not None:
                    # "28.12.–08.01.2027": Beginn im Vorjahr, wenn sein Monat spaeter liegt
                    prev.s.year = t.s.year - 1 if prev.s.month > t.s.month else t.s.year
                prev.end = t.end
                prev.time = t.time
                continue
        merged.append(t)
    merged = [t for t in merged if not (t.e is None and t.core in open_starts)]
    # Uhrzeit direkt danach
    for i, t in enumerate(merged):
        if t.time is not None:
            continue
        a = t.end
        tail = text[a:a + 34]
        if not tail:
            continue
        m = TIME_RE.match(tail)
        if not m:
            continue
        h = int(m.group(1))
        mi = 0
        for g in (2, 3):
            if m.group(g) is not None:
                mi = int(m.group(g))
        if m.group(4) is not None:
            ap = m.group(4).lower()
            if ap.startswith("p") and h < 12:
                h += 12
            if ap.startswith("a") and h == 12:
                h = 0
        if h == 24 and mi == 0:
            h, mi = 23, 59
        if not (0 <= h <= 23 and 0 <= mi <= 59):
            continue
        consumed = m.end()
        # eine folgende Datumsangabe ist keine Uhrzeit ("02.11., 16.11.")
        if i + 1 < len(merged) and merged[i + 1].start < a + consumed:
            continue
        t.time = f"{h:02d}:{mi:02d}"
        t.end += consumed
    return merged


# ---------------------------------------------------------------- Schluesselwoerter

BOTH, DATE_AFTER, RESTRICTED_BEFORE = "both", "dateAfter", "restrictedBefore"


@dataclass(frozen=True)
class KeywordSpec:
    pattern: str
    kind: str
    label: str
    direction: str = BOTH
    weak_lowercase: bool = False
    period_only: bool = False


KEYWORD_SPECS = [
    KeywordSpec(r"(?:pr(?:ü|ue)fungs|klausur|test|testat)anmeldung(?:en)?", "anmeldung", "Anmeldung", RESTRICTED_BEFORE),
    KeywordSpec(r"anmeldeschluss|anmeldefrist(?:en)?|anmeldezeitraum|anmeldephase", "anmeldung", "Anmeldeschluss"),
    KeywordSpec(r"abmeldefrist(?:en)?|abmeldeschluss|r(?:ü|ue)cktrittsfrist", "anmeldung", "Abmeldefrist"),
    KeywordSpec(r"anmeldung(?:en)?|registration(?:\s+deadline)?", "anmeldung", "Anmeldung", RESTRICTED_BEFORE),
    KeywordSpec(r"anzumelden|anmelden", "anmeldung", "Anmeldung"),
    KeywordSpec(r"probe-?kurzklausur(?:en|termin(?:e)?)?", "klausur", "Probe-Kurzklausur"),
    KeywordSpec(r"kurzklausur(?:en|termin|termine)?", "klausur", "Kurzklausur"),
    KeywordSpec(r"probeklausur(?:en|termin(?:e)?)?", "klausur", "Probeklausur"),
    KeywordSpec(r"nachklausur(?:en|termin(?:e)?)?|wiederholungsklausur(?:en|termin(?:e)?)?", "klausur", "Nachklausur"),
    KeywordSpec(r"pr(?:ü|ue)fungs(?:zeitr(?:aum|(?:ä|ae)ume)|phase)|klausur(?:en)?(?:zeitr(?:aum|(?:ä|ae)ume)|phase)", "klausur",
                "Prüfungszeitraum", DATE_AFTER, period_only=True),
    KeywordSpec(r"klausurtermin(?:e)?|klausurdatum|klausur(?:en)?", "klausur", "Klausur"),
    KeywordSpec(r"pr(?:ü|ue)fungstermin(?:e)?|pr(?:ü|ue)fungsdatum|(?:m(?:ü|ue)ndliche|schriftliche)\s+pr(?:ü|ue)fung(?:en)?", "klausur", "Prüfung"),
    KeywordSpec(r"pr(?:ü|ue)fung(?:en)?", "klausur", "Prüfung", DATE_AFTER),
    KeywordSpec(r"(?:final\s+|midterm\s+)?exam(?:s|ination)?|midterm", "klausur", "Prüfung", DATE_AFTER),
    KeywordSpec(r"probe-?kurztest(?:s|e|termin(?:e)?)?", "test", "Probe-Kurztest"),
    KeywordSpec(r"kurztestat(?:e|en|s|termin(?:e)?)?", "test", "Kurztestat"),
    KeywordSpec(r"kurztest(?:s|e|termin(?:e)?)?", "test", "Kurztest"),
    KeywordSpec(r"probetestat(?:e|en)?|testat(?:e|en|s|termin(?:e)?)?", "test", "Testat"),
    KeywordSpec(r"zwischentest(?:s|e|termin(?:e)?)?", "test", "Zwischentest"),
    KeywordSpec(r"online-?test(?:s)?|e-?test(?:s)?", "test", "Online-Test"),
    KeywordSpec(r"quiz(?:ze|zes)?", "test", "Quiz", DATE_AFTER),
    KeywordSpec(r"test(?:s|termin(?:e)?)?", "test", "Test", DATE_AFTER, weak_lowercase=True),
    KeywordSpec(r"(?:(?:ü|ue)bungsblatt|blatt)-?abgabe", "abgabe", "Abgabe"),
    KeywordSpec(r"abgabe(?:termin(?:e)?|frist(?:en)?|schluss|datum)|abgaben?", "abgabe", "Abgabe"),
    KeywordSpec(r"abzugeben|abgeben|abgegeben", "abgabe", "Abgabe"),
    KeywordSpec(r"einzureichen|einreichen|eingereicht|einreichungsfrist|einreichung(?:en)?", "abgabe", "Abgabe"),
    KeywordSpec(r"einsendeschluss", "abgabe", "Einsendeschluss"),
    KeywordSpec(r"deadlines?", "abgabe", "Deadline"),
    KeywordSpec(r"due(?:\s+date)?(?!\s+to\b)", "abgabe", "Abgabe"),
    KeywordSpec(r"submissions?(?:\s+deadline)?|submit(?:ted)?", "abgabe", "Abgabe"),
    KeywordSpec(r"assignments?", "abgabe", "Assignment"),
    KeywordSpec(r"hausaufgaben?|homework", "abgabe", "Hausaufgabe"),
    KeywordSpec(r"hausarbeit(?:en)?", "abgabe", "Hausarbeit"),
    KeywordSpec(r"fristende|fristen|frist|stichtag", "sonstiges", "Frist", DATE_AFTER),
]
KEYWORD_RE = re.compile(r"(?<![^\W_])(?:" + "|".join(f"({s.pattern})" for s in KEYWORD_SPECS) + r")(?![^\W_])", I)

# Teile des Musters fuer die Vorauswahl (Suchform: klein, Umlaute zusammengesetzt)
LIKE_TERMS = ["abgabe", "abgeben", "abzugeben", "abgegeben", "einreich", "einzureich", "eingereicht", "einsendeschluss",
              "deadline", "due", "submi", "assignment", "hausaufgabe", "hausarbeit", "homework", "testat", "test", "quiz",
              "klausur", "prüfung", "pruefung", "exam", "midterm", "anmeld", "anzumelden", "registration",
              "abmeldefrist", "rücktrittsfrist", "frist", "stichtag"]


@dataclass
class Keyword:
    start: int
    end: int
    kind: str
    label: str
    direction: str
    weak: bool = False          # englisch klein "test"/"tests": nur mit "on"/":" vor dem Datum oder Pruefungswort im Satz
    period_only: bool = False   # Zeitraum ("Pruefungszeitraum"): nimmt nur Bereiche, ergibt keinen Treffer


WEAK_BEFORE_RE = re.compile(
    rf"(?<!{L})(?:unit|integration|regression|smoke|acceptance|system|end-to-end|e2e|load|stress|performance|usability|"
    r"property(?:-based)?|automated|automatic|statistical|hypothesis|significance|t|z|f|chi(?:-squared?)?|write|writing|run|running|"
    r"pass|passing|failing|failed)[\s-]+$", I)
WEAK_AFTER_RE = re.compile(
    rf"^\s+(?:for|of|cases?|suites?|data|coverage|driven|runs?|results?|files?|methods?|classes?|code|framework|harness|statistics?)(?!{L})", I)
WEAK_GAP_RE = re.compile(
    r"^\s*(?::\s*|(?:(?:is|will\s+be|takes\s+place|is\s+held|will\s+be\s+held|will\s+take\s+place)\s+)?on\s+)(?:the\s+)?$", I)
EXAM_CONTEXT_RE = re.compile(rf"(?<!{L})(?:exams?|examinations?|quiz(?:zes)?|midterms?)(?!{L})", I)
PAREN_AND_RE = re.compile(rf"(?<!{L})(?:und|and|sowie|or|oder)(?!{L})", I)
HEAD_CONNECTOR_RE = re.compile(r"^\s*(?:zur|zum|zu|f(?:ü|ue)r|der|des|von|for|of|to)(?:\s+(?:der|die|das|den|dem|the))?\s*$", I)
COMPOUND_RE = re.compile(r"^\s*[-/]\s*$")
ADJACENT_RE = re.compile(r"^\s*$")
COMPOUND_TAIL_RE = re.compile(rf"\s*-\s*({L}+)")
DATE_TAILS = {"termin", "termine", "datum", "tag", "tage", "woche", "frist", "zeit", "zeitraum", "date", "deadline"}


def in_paren_list(text: str, a: int, b: int) -> bool:
    """Wort in einer Aufzaehlung in Klammern ("(Variablen, Funktionen, tests)")"""
    i, opened = a - 1, -1
    while i >= 0 and a - i <= 200:
        c = text[i]
        if c == ")" or (c == "\n" and i > 0 and text[i - 1] == "\n"):
            break
        if c == "(":
            opened = i
            break
        i -= 1
    if opened < 0:
        return False
    j = b
    while j < len(text) and j - b <= 200:
        c = text[j]
        if c in ")(" or (c == "\n" and j + 1 < len(text) and text[j + 1] == "\n"):
            break
        j += 1
    inner = text[opened + 1:j]
    return "," in inner or ";" in inner or has(PAREN_AND_RE, inner)


def find_keywords(text: str) -> list[Keyword]:
    out: list[Keyword] = []
    found = list(KEYWORD_RE.finditer(text))
    for n, m in enumerate(found):
        a = m.end()
        tail = text[a:a + 24]
        t = COMPOUND_TAIL_RE.match(tail)
        if t:
            word = t.group(1).lower()
            next_is_keyword = n + 1 < len(found) and found[n + 1].start() <= a + t.start(1)
            if word not in DATE_TAILS and not next_is_keyword:
                continue
        for i, spec in enumerate(KEYWORD_SPECS):
            if m.group(i + 1) is None:
                continue
            weak = False
            if spec.weak_lowercase and m.group(0) in ("test", "tests"):
                # englisch klein: nicht in Wortgruppen ("unit tests", "tests for") und nicht in Klammer-Aufzaehlungen
                before = text[max(0, m.start() - 24):m.start()]
                if has(WEAK_BEFORE_RE, before) or has(WEAK_AFTER_RE, tail):
                    break
                if not tail.lstrip(" ").startswith(":") and in_paren_list(text, m.start(), m.end()):
                    break
                weak = True
            out.append(Keyword(m.start(), m.end(), spec.kind, spec.label, spec.direction, weak, spec.period_only))
            break
    # Wortgruppen: "Anmeldung zur Klausur" -> Anmeldung, "Klausur-Anmeldung" -> Anmeldung, "Abgabe der Hausaufgabe" -> Abgabe
    merged: list[Keyword] = []
    for k in out:
        if merged:
            prev = merged[-1]
            gl = k.start - prev.end
            if 0 <= gl <= 16:
                gap = text[prev.end:k.start]
                head = None
                if HEAD_CONNECTOR_RE.search(gap):
                    head = prev
                elif COMPOUND_RE.search(gap):
                    head = k
                elif ADJACENT_RE.search(gap):
                    head = k if k.kind == "anmeldung" else prev
                if head is not None:
                    merged[-1] = Keyword(prev.start, k.end, head.kind, head.label, head.direction, prev.weak and k.weak, head.period_only)
                    continue
        merged.append(k)
    return merged


# ---------------------------------------------------------------- Paare aus Schluesselwort und Datum

WORD_RE = re.compile(r"[^\W_]+")
SENTENCE_BREAK_RE = re.compile(r"[!?;]|[)\"“”»]\.(?=\s)|\n[ \t]*\n")
WORD_DOT_RE = re.compile(rf"({L}+)\.(?=\s|$)")
_SPACE_RUN_RE = re.compile(r"\s+")
ABBREVIATIONS = {"bzw", "ca", "vgl", "inkl", "evtl", "ggf", "usw", "etc", "nr", "no", "dr", "prof", "abs", "kap",
                 "bsp", "max", "min", "std", "tel", "str", "hr", "fr", "frau", "jan", "feb", "mär", "apr",
                 "jun", "jul", "aug", "sep", "sept", "okt", "oct", "nov", "dez", "dec", "hrsg", "ws", "ss",
                 "wise", "sose", "mo", "di", "mi", "do", "sa", "so", "abb", "tab", "aufg", "bzgl", "z", "b",
                 "u", "a", "s", "d", "h", "o", "e", "i", "v", "ff", "f", "geb", "raum"}


def _word_dots(s: str):
    """Treffer von (\\p{L}+)\\.(?=\\s|$)(\\s+\\p{Lu})? wie NSRegularExpression: (Wort, Ende des Worts, Grossbuchstabe folgt)"""
    pos = 0
    while True:
        m = WORD_DOT_RE.search(s, pos)
        if not m:
            return
        end, upper = m.end(), False
        sp = _SPACE_RUN_RE.match(s, m.end())
        if sp and sp.end() < len(s) and s[sp.end()].isupper() and s[sp.end()].isalpha():
            end, upper = sp.end() + 1, True
        yield m.group(1), m.end(1), upper
        pos = end


def sentence_ends(s: str) -> list[int]:
    """Satzenden in einem Text (Stelle direkt dahinter), ungeordnet"""
    out = [m.end() for m in SENTENCE_BREAK_RE.finditer(s)]
    for w, end, upper in _word_dots(s):
        lw = w.lower()
        if lw not in ABBREVIATIONS and (len(lw) >= 4 or upper):
            out.append(end + 1)
    return out


def sentence_break(gap: str) -> bool:
    """Satzgrenze zwischen Schluesselwort und Datum; Punkte von Abkuerzungen und Datumsangaben zaehlen nicht"""
    if has(SENTENCE_BREAK_RE, gap):
        return True
    for w, _, upper in _word_dots(gap):
        lw = w.lower()
        if lw in ABBREVIATIONS:
            continue
        if len(lw) >= 4 or upper:
            return True
    return False


CONNECTOR_END_RE = re.compile(r"(?:\b(?:am|bis|zum|vom|ab|ist|sind|on|by|until|at|due|den|sp(?:ä|ae)testens|termin|datum|date)|[:–\-])\s*$", I)
RESTRICTED_FOLLOW_RE = re.compile(r"^\s*(?:(?:ü|ue)ber|via|unter|per|im|in|bei|beim|auf|online|through)\b", I)
BLOCKED_BEFORE_DATE_RE = re.compile(
    r"(?:(?:folien?|foliensatz|vorlesung(?:en)?|skript|mitschrift|aufzeichnung|(?:(?:ü|ue)bungs)?blatt|kapitel|(?:ü|ue)bung|sitzung|"
    r"stunde|tutorium)\s+(?:vom|von)|(?:stand|version|aktualisiert|erstellt|updated?|druckdatum|gedruckt|ver(?:ö|oe)ffentlicht|"
    r"published)\b[\W\d_]*(?:am|vom|on)?)\s*$", I)
EXAM_BLOCK_RE = re.compile(
    r"l(?:ö|oe)sung|musterl|solution|ergebnis|\bnoten\b|bewert|korrektur|korrigiert|r(?:ü|ue)ckgabe|zur(?:ü|ue)ckgegeben|einsicht|"
    r"besprechung|altklausur|alte\s+klausur|klausur\s+aus\s+(?:dem|der)", I)
SUBMISSION_BLOCK_RE = re.compile(r"r(?:ü|ue)ckgabe|zur(?:ü|ue)ckgegeben|korrigiert|bewertet|besprechung", I)
NUMBER_AFTER_RE = re.compile(r"\s*(?:Nr\.?\s*|No\.?\s*|#\s*)?([0-9]{1,2})(?![0-9.,:/])", I)
SHEET_RE = re.compile(
    rf"(?<!{L})(?:((?:(?:ü|ue)bungs)?blatt|sheet|(?:ü|ue)bung)|(assignment|hausaufgabe|homework))\s*(?:nr\.?\s*)?0*([0-9]{{1,2}})(?![0-9.])", I)
HAUSARBEIT_RE = re.compile(rf"(?<!{L})hausarbeit(?:en)?(?!{L})", I)


def words(s: str) -> int:
    return len(WORD_RE.findall(s))


def score(k: Keyword, d: DateToken, text: str) -> int | None:
    """Abstand eines Paars (kleiner ist besser); None, wenn Schluesselwort und Datum nicht zusammengehoeren"""
    kf = k.start < d.start
    gs = k.end if kf else d.end
    ge = d.start if kf else k.start
    if not (ge >= gs and ge - gs <= 160):
        return None
    gap = text[gs:ge]
    if sentence_break(gap):
        return None
    lines = gap.split("\n")
    if len(lines) > 2:
        return None
    n = words(gap)
    comma = "," in gap
    if not kf and k.direction == DATE_AFTER:
        return None
    # "Pruefungszeitraum" nimmt nur Bereiche
    if k.period_only and d.e is None:
        return None
    if k.weak and not has(WEAK_GAP_RE, gap):
        lead = text[max(0, k.start - 100):k.start]
        ends = sentence_ends(lead)
        if ends:
            lead = lead[max(ends):]
        if not (has(EXAM_CONTEXT_RE, lead) or has(EXAM_CONTEXT_RE, gap)):
            return None
    if not kf and k.direction == RESTRICTED_BEFORE:
        # "Fr, 11.12.2026, Anmeldung über Stud.IP": Hinweis zur Anmeldung, kein Anmeldeschluss
        if comma:
            return None
        if has(RESTRICTED_FOLLOW_RE, text[k.end:k.end + 24]):
            return None
    if len(lines) == 2:
        if n > 3:
            return None
        if kf:
            # Satz laeuft ueber die Zeile weiter ("... Zwischentest am" / "16.11.2026 im Hörsaal")
            if not (words(lines[0]) <= 3 and has(CONNECTOR_END_RE, text[k.start:k.end] + lines[0]) and words(lines[1]) <= 1):
                return None
        elif not (words(lines[0]) == 0 and words(lines[1]) <= 1):
            # Tabellenzelle je Zeile: Datum am Zeilenende, Schluesselwort am Anfang der naechsten
            return None
    if n > 6:
        return None
    if kf and has(BLOCKED_BEFORE_DATE_RE, text[gs:d.core]):
        return None
    return n + (2 if comma else 0) + (2 if len(lines) == 2 else 0) + (0 if kf else 1)


def resolve(p: Parts, ctx: Context) -> int | None:
    """Tag eines Datums im Rahmen; None, wenn es keinen passenden gibt"""
    w = ctx.window
    if p.year is not None:
        n = valid(p, p.year)
        if n is None or not w.contains(n):
            return None
        if p.weekday is not None and weekday(n) != p.weekday:
            return None
        return n
    if not ctx.allow_yearless:
        return None
    y0, y1 = civil(w.start).year, civil(w.end).year
    candidates = []
    for y in range(y0, max(y0, y1) + 1):
        n = valid(p, y)
        if n is None or not w.contains(n):
            continue
        if p.weekday is not None and weekday(n) != p.weekday:
            continue
        if ctx.reference is not None and (n < ctx.reference - 45 or n > ctx.reference + 300):
            continue
        candidates.append(n)
    if not candidates:
        return None
    anchor = ctx.reference if ctx.reference is not None else w.today
    return min(candidates, key=lambda c: abs(c - anchor))


def line_bounds(text: str, pos: int) -> tuple[int, int]:
    s = e = min(pos, len(text))
    while s > 0 and text[s - 1] != "\n":
        s -= 1
    while e < len(text) and text[e] != "\n":
        e += 1
    return s, e


def snippet(text: str, a: int, b: int) -> str:
    """Zeile(n) um den Treffer, Leerraum zusammengezogen, hoechstens 160 Zeichen"""
    s, _ = line_bounds(text, a)
    _, e = line_bounds(text, b)
    line = " ".join(text[s:e].split())
    if len(line) <= 160:
        return line
    offset = len(" ".join(text[s:a].split()))
    start = max(0, min(offset - 40, len(line) - 158))
    hi = start + min(158, len(line) - start)
    return ("…" if start > 0 else "") + line[start:hi] + ("…" if hi < len(line) else "")


def _has_number(s: str) -> bool:
    return any(c.isnumeric() for c in s)


def label(k: Keyword, text: str, line: str, head: str, doc_head: str | None, name: str | None) -> str:
    """Bezeichnung: Schluesselwort mit Nummer ("Kurztestat 2"); Abgaben mit Blatt aus Zeile, Kopf oder Dateiname"""
    tail = text[k.end:k.end + 12]
    if k.kind != "abgabe" or k.label != "Abgabe":
        m = NUMBER_AFTER_RE.match(tail)
        if m:
            return f"{k.label} {int(m.group(1))}"
    if k.label == "Abgabe" and has(HAUSARBEIT_RE, line):
        return "Hausarbeit"
    if k.label == "Abgabe":
        for source in (line, head, doc_head or "", (name or "").replace("_", " ")):
            m = SHEET_RE.search(source)
            if m:
                n = str(int(m.group(3)))
                if m.group(2) is not None:
                    return ("Assignment " if m.group(2).lower() == "assignment" else "Hausaufgabe ") + n
                return "Abgabe Blatt " + n
    return k.label


# ---------------------------------------------------------------- Ueberschriften mit Unterpunkten

MAIN_BULLETS = {0x25FC, 0x25CF, 0x25A0, 0x25FE, 0x2B1B, 0x26AB, 0x2B24}
SUB_BULLETS = {0x2751, 0x2752, 0x25A1, 0x25AA, 0x25AB, 0x25E6, 0x25CB, 0x2022, 0x2023, 0x2043, 0x2D, 0x2013, 0x2014, 0x2A, 0xB7,
               0x2713, 0x2714, 0x27A2, 0x27A4, 0x25BA, 0x25B8, 0x25B6, 0x25C7, 0x25C6, 0x2756, 0x2192}


def is_bullet(c: int) -> bool:
    return c in MAIN_BULLETS or c in SUB_BULLETS or 0xE000 <= c <= 0xF8FF


def first_visible(text: str, start: int, end: int) -> int | None:
    i = start
    while i < end and text[i] in " \t":
        i += 1
    return i if i < end else None


HEADING_TAIL_RE = re.compile(r"^\s*(?:(?:nr\.?|no\.?|#)?\s*[0-9]{1,2}|(?:(?:ü|ue)bungs)?blatt\s*[0-9]{1,2})?\s*:?\s*$", I)
DATE_LABEL_RE = re.compile(rf"(?<!{L})(?:datum|termin|zeitpunkt|wann|date|when)\s*:?\s*$", I)
OTHER_EVENT_RE = re.compile(
    rf"^[\W_]*(?:(?:die|der|das|the)\s+)?(?:(?:erste|letzte|n(?:ä|ae)chste|first|last|next)\s+)?(?:vorlesung(?:en)?|(?:ü|ue)bung(?:en)?|"
    rf"tutori(?:um|en)|sprechstunde|sitzung|ausgabe|lecture|tutorial)(?!{L})", I)
CONTINUED_RE = re.compile(rf"(?:[:,]|(?<!{L})(?:am|bis|vom|ab|den|on|by|until))\s*$", I)


def heading_date(ki: int, keywords: list[Keyword], dates: list[DateToken], text: str):
    """Ueberschrift aus Aufzaehlungszeichen und Schluesselwort ("◼ Kurzklausurtermin") mit Unterpunkten darunter.
    None: keine solche Ueberschrift. Sonst (True, Index des Datums oder None)."""
    k = keywords[ki]
    if k.weak or k.period_only:
        return None
    head_bullet = None
    i = k.start - 1
    while i >= 0 and text[i] != "\n":
        c = ord(text[i])
        if c not in (32, 9):
            if not is_bullet(c):
                return None
            head_bullet = c
        i -= 1
    ls = i + 1
    a = k.end
    le = line_bounds(text, a)[1]
    if not has(HEADING_TAIL_RE, text[a:le]):
        return None
    head_indented = ls < len(text) and text[ls] in " \t"
    lines: list[tuple[int, int]] = []
    bulleted = continues = False
    pos = le + 1
    while pos < len(text) and len(lines) < 8:
        e = line_bounds(text, pos)[1]
        f = first_visible(text, pos, e)
        if f is None:
            break                                                     # Leerzeile
        c = ord(text[f])
        if c in MAIN_BULLETS:
            break                                                     # naechster Hauptpunkt
        if head_bullet is not None and c == head_bullet:
            break                                                     # Nachbar der Ueberschrift
        if is_bullet(c):
            bulleted = True
        elif not (f > pos and not head_indented) and not (continues and lines):
            break                                                     # weder eingerueckt noch Fortsetzung
        lines.append((pos, e))
        continues = has(CONTINUED_RE, text[pos:e])
        pos = e + 1
    if not lines or not (head_bullet is not None or bulleted):
        return None
    lo, hi = lines[0][0], lines[-1][1]
    first = labelled = None
    for di, d in enumerate(dates):
        if not (lo <= d.start < hi):
            continue
        s, e = line_bounds(text, d.start)
        owned = any(j != ki and s <= kw.start < e and score(kw, d, text) is not None for j, kw in enumerate(keywords))
        if owned:
            continue
        before = text[s:d.core]
        if has(BLOCKED_BEFORE_DATE_RE, before) or has(OTHER_EVENT_RE, before):
            continue
        if first is None:
            first = di
        frm = max(lo, d.start - 40)
        if labelled is None and has(DATE_LABEL_RE, text[frm:d.start]):
            labelled = di
    return (True, labelled if labelled is not None else first)


# ---------------------------------------------------------------- Testate im Semesterplan

TABLE_COLUMN_RE = re.compile(
    rf"(?<!{L})(?:datum|termine?|themen?|inhalte?|woche|kw|vorlesung(?:en)?|vl|(?:gruppen)?(?:ü|ue)bung(?:en)?|tutorium|tutorien|date|"
    rf"topics?|week|lecture)(?!{L})|(?:^|\s)#(?:\s|$)", I)
TESTAT_MARKER_RE = re.compile(r"(?<![^\W_])T ?([0-9]{1,2})(?=\s*:)")
ROW_START_RE = re.compile(rf"^\s*(?:[0-9]{{1,2}}\s+)?(?:{L}{{2,3}}\.?,?\s*)?[0-9]{{1,2}}\.\s?[0-9]{{1,2}}\.")


def testat_tables(text: str, keywords: list[Keyword], dates: list[DateToken]):
    """Tabellen, deren Kopfzeile Testate nennt: darunter, bis zur Leerzeile, ist "T1:" ein Testat. Ergebnis: Kopfwoerter
    (kein Termin) und Testate mit Datum (None: keins)."""
    headers: list[int] = []
    markers: list[tuple[Keyword, int | None]] = []
    seen: set[int] = set()
    markers_by_line: dict[int, bool] = {}
    for ki, k in enumerate(keywords):
        if not (k.kind == "test" and k.label in ("Testat", "Kurztestat")):
            continue
        ls, le = line_bounds(text, k.start)
        line = text[ls:le]
        if line.strip().endswith(":") or any(d.start < le and d.end > ls for d in dates) or words(line) > 14 \
                or not has(TABLE_COLUMN_RE, line):
            continue
        if ls in seen:
            if markers_by_line.get(ls):
                headers.append(ki)
            continue
        seen.add(ls)
        rows: list[tuple[int, int]] = []
        pos = le + 1
        while pos < len(text) and len(rows) < 80:
            e = line_bounds(text, pos)[1]
            if first_visible(text, pos, e) is None:
                break
            rows.append((pos, e))
            pos = e + 1
        before = len(markers)
        for n, (rs, rend) in enumerate(rows):
            found = [(rs + m.start(), rs + m.end(), m.group(1)) for m in TESTAT_MARKER_RE.finditer(text[rs:rend])]
            for j, (_, me, num) in enumerate(found):
                stop = found[j + 1][0] if j + 1 < len(found) else rend
                d = next((i for i, x in enumerate(dates) if me <= x.start < stop), None)
                if d is None and j + 1 == len(found) and n + 1 < len(rows):
                    ns, ne = rows[n + 1]
                    nt = text[ns:ne]
                    if not has(ROW_START_RE, nt) and not has(TESTAT_MARKER_RE, nt):
                        d = next((i for i, x in enumerate(dates) if ns <= x.start < ne), None)
                markers.append((Keyword(found[j][0], me, "test", f"Testat T{int(num)}", DATE_AFTER), d))
        markers_by_line[ls] = len(markers) > before
        if len(markers) > before:
            headers.append(ki)
    return headers, markers


# ---------------------------------------------------------------- Zeitraum nach "Klausuren", "Pruefungen"

PLURAL_EXAM_RE = re.compile(rf"(?<!{L})(?:klausuren|pr(?:ü|ue)fungen)$", I)
DIRECT_GAP_RE = re.compile(r"^\s*(?:[(:–\-]\s*)?(?:(?:vom|von|zwischen)\s+)?$", I)
REGISTRATION_RE = re.compile(
    rf"(?<!{L})(?:{L}*an(?:zu|ge)?meld{L}*|{L}*melde(?:-|zeitr|frist|phase|schluss){L}*|registration|register)", I)


def is_period_after_plural(k: Keyword, t: DateToken, text: str) -> bool:
    if k.kind != "klausur" or t.e is None or k.end > t.start or not has(PLURAL_EXAM_RE, text[k.start:k.end]):
        return False
    return has(DIRECT_GAP_RE, text[k.end:t.start])


def registration_before(pos: int, text: str, dates: list[DateToken]) -> bool:
    lo = max(0, pos - 400)
    lead = text[lo:pos]
    ends = sorted(sentence_ends(lead))
    frm = ends[-3] if len(ends) >= 3 else 0
    found = list(REGISTRATION_RE.finditer(lead[frm:]))
    if not found:
        return False
    after = lo + frm + found[-1].end()
    return not any(after <= d.start < pos for d in dates)


# ---------------------------------------------------------------- Erkennen

def detect(raw: str, ctx: Context) -> list[Hit]:
    """Termine in einem Text (Seite, Dateiname, Ankuendigung), nach Datum; gleiche Art am gleichen Tag nur einmal"""
    text = prepare(raw)
    dates = find_dates(text)
    if not dates:
        return []
    keywords = find_keywords(text)
    if not keywords:
        return []
    forced: list[tuple[int, int | None]] = []
    headers, markers = testat_tables(text, keywords, dates)
    plain = len(keywords)
    for h in headers:
        forced.append((h, None))
    for kw, d in markers:
        keywords.append(kw)
        forced.append((len(keywords) - 1, d))
    header_keys = set(headers)
    for ki in range(plain):
        if ki in header_keys:
            continue
        hd = heading_date(ki, keywords, dates, text)
        if hd is not None:
            forced.append((ki, hd[1]))
    forced_keys = {f[0] for f in forced}

    pairs: list[tuple[int, int, int, bool]] = [(k, d, -1, True) for k, d in forced if d is not None]
    for ki, k in enumerate(keywords):
        if ki in forced_keys:
            continue
        before = next((i for i in range(len(dates) - 1, -1, -1) if dates[i].end <= k.start), None)
        after = next((i for i, x in enumerate(dates) if x.start >= k.end), None)
        for di in (before, after):
            if di is None:
                continue
            s = score(k, dates[di], text)
            if s is not None:
                pairs.append((ki, di, s, k.start < dates[di].start))
    pairs.sort(key=lambda p: (p[2], not p[3], RANK[keywords[p[0]].kind], dates[p[1]].start))
    date_taken: set[int] = set()
    key_taken = {k for k, d in forced if d is None}
    accepted: list[tuple[int, int]] = []
    for k, d, _, kf in pairs:
        if d in date_taken or k in key_taken:
            continue
        date_taken.add(d)
        key_taken.add(k)
        accepted.append((k, d))
        # Datumsliste hinter dem Schluesselwort ("Kurztestate am 02.11., 16.11. und 30.11.")
        if not kf or k >= plain:
            continue
        j = d + 1
        while j < len(dates) and j not in date_taken:
            gs = dates[j - 1].end
            gl = dates[j].start - gs
            if not 0 <= gl <= 12:
                break
            gap = text[gs:dates[j].start]
            if not has(LIST_GAP_RE, gap) or (k in forced_keys and "\n" in gap):
                break
            date_taken.add(j)
            accepted.append((k, j))
            j += 1

    hits: list[Hit] = []
    head = _first_lines(text)[:120]
    for ki, di in accepted:
        k = keywords[ki]
        t = dates[di]
        if k.period_only:
            continue
        if is_period_after_plural(k, t, text):
            if not registration_before(k.start, text, dates):
                continue
            k = replace(k, kind="anmeldung", label="Anmeldung")
        if not ctx.allow_exams and k.kind in ("test", "klausur"):
            continue
        hi = max(k.end, t.end)
        if ki in forced_keys:
            frm = max(line_bounds(text, t.start)[0], k.end)
            around = text[k.start:k.end] + " " + text[frm:t.end]
        else:
            first = min(k.start, t.start)
            lo = max(0, first - 50)
            ends = sentence_ends(text[lo:first])
            if ends:
                lo += max(ends)
            around = text[lo:hi]
        if k.kind in ("test", "klausur") and has(EXAM_BLOCK_RE, around):
            continue
        if k.kind == "abgabe" and has(SUBMISSION_BLOCK_RE, around):
            continue
        uses_end = t.e is not None and k.kind in ("abgabe", "anmeldung", "sonstiges")
        day = resolve(t.e if uses_end else t.s, ctx)
        if day is None:
            continue
        time = t.time if (t.e is None or uses_end) else None
        snip = snippet(text, min(k.start, t.start), hi)
        lab = label(k, text, snip, head, ctx.head, ctx.name)
        if ki >= plain and t.e is not None:
            last = resolve(t.e, ctx)
            if last is not None and last > day:
                c = civil(last)
                lab += f" (bis {c.day:02d}.{c.month:02d}.)"
        d_iso = iso(day)
        same = next((h for h in hits if h.date == d_iso and h.kind == k.kind), None)
        if same is not None:
            if same.time is None and time is not None:
                same.time = time
            if not _has_number(same.label) and _has_number(lab):
                same.label = lab
            continue
        hits.append(Hit(d_iso, time, k.kind, lab, snip))
    return sorted(hits, key=lambda h: (h.date, h.time or "", RANK[h.kind]))


def name_text(name: str) -> str:
    """Dateiname als Text: ohne Endung, Unterstriche als Leerzeichen ("Blatt_3_Abgabe_05.11.pdf" -> "Blatt 3 Abgabe 05.11.")"""
    n = name or ""
    dot = n.rfind(".")
    if dot >= 0 and len(n) - dot <= 6 and all(c.isalpha() for c in n[dot + 1:]):
        n = n[:dot + 1]
    return n.replace("_", " ")

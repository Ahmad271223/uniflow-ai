"""HISinOne (Campusmanagement) der Hochschule Hannover: Anmeldezustand, Stundenplan als iCal, Leistungen.

Aufbau (docs/HSH-2026-11-05.md; Adressen und Tabellen am 05.11.2026 vom Koordinator mit der Anmeldung des Inhabers
nur lesend angesehen, ohne persoenliche Daten): Startseite /qisserver/pages/cs/sys/portal/hisinoneStartPage.faces,
Anmeldung per SAML ("Anmelden mit SSO Hochschule Hannover", /qisserver/api/identityprovider/redirect/4/login) mit dem
SSO-Account. Angemeldet = Abmelden-Link (category=auth.logout); jede Seite traegt ein verstecktes Dialogfeld
"Sitzung abgelaufen" mit Benutzerkennung/Passwort, das NICHT als Anmeldeformular zaehlt.
Je nach Fakultaet laufen Leistungen und Pruefungsanmeldung in HISinOne (Fak. II, IV, HsH Akademie) oder noch im alten
QIS im Iframe (qis_meine_funktionen; Fak. I, III, V und aeltere POs der Fak. IV) - beide Wege werden gelesen.
Die Tests nutzen nachgebaute Seiten (tests/fixtures/hsh/, als nachgebaut gekennzeichnet, ohne echte Daten).

Nur lesend: nie Pruefungs- oder Veranstaltungsanmeldung, nie Formulare absenden ausser der Anmeldung, die der Mensch
selbst im Fenster macht.
"""
from __future__ import annotations

import html as _html
import re
from html.parser import HTMLParser
from urllib.parse import urljoin, urlsplit

from .universities import HSH_CM_BASE

HOST = urlsplit(HSH_CM_BASE).hostname or "campusmanagement.hs-hannover.de"
PAGES = f"{HSH_CM_BASE}/qisserver/pages"
START_URL = f"{PAGES}/cs/sys/portal/hisinoneStartPage.faces"
SSO_LOGIN_URL = f"{HSH_CM_BASE}/qisserver/api/identityprovider/redirect/4/login"
# Menue "Mein Studium" (Flows immer ueber die Menue-Adresse starten: _flowExecutionKey ist Sitzungszustand)
TIMETABLE_URL = f"{PAGES}/plan/individualTimetable.xhtml?_flowId=individualTimetableSchedule-flow"
GRADES_URL = f"{PAGES}/sul/examAssessment/personExamsReadonly.xhtml?_flowId=examsOverviewForPerson-flow"
# Pruefungen anmelden: nur lesen, welche Pruefungen angemeldet ("zugelassen") sind; nie an- oder abmelden
EXAM_REGISTRATION_URL = f"{PAGES}/cm/exa/nominalactualcomparison/sollistvergleichBaum.xhtml?_flowId=sollistvergleich-flow"
# altes QIS im Iframe (Pruefungen und Studium) fuer Fakultaeten, die HISinOne noch nicht fuer Leistungen nutzen
QIS_IFRAME_URL = f"{PAGES}/cs/sys/portal/hisinoneIframePage.faces?id=qis_meine_funktionen"
ENROLLMENTS_URL = f"{PAGES}/cm/exa/enrollment/info/start.xhtml?_flowId=searchOwnEnrollmentInfo-flow"
STUDY_SERVICE_URL = f"{PAGES}/cm/stu/studyService/start.xhtml?_flowId=studyservice-flow"
# oeffentlich (ohne Anmeldung): Modulbeschreibungen und Studiengangsplaene (Quelle fuer den Studienverlauf)
PUBLIC_MODULE_DESCRIPTIONS_URL = (f"{PAGES}/cm/exa/curricula/genericRailsSearchUnitsSimple.xhtml"
                                  "?_flowId=searchCourseOfStudyForModuleDescription-flow")
PUBLIC_STUDY_PLANS_URL = f"{PAGES}/cm/exa/timetable/studyCourseSchedule.xhtml?_flowId=searchStudyCourseSchedule-flow"

# Abmelden-Link (/qisserver/rds?state=user&type=3&category=auth.logout, "Abmelden von diesem Portal")
_LOGOUT_RE = re.compile(r"category=auth\.logout", re.I)
# sichtbare Anmeldung: Knopf/Link zum SSO oder das klassische Formular; das versteckte Dialogfeld "Sitzung abgelaufen"
# steht auf jeder Seite und zaehlt nie
_LOGIN_HINT_RE = re.compile(r"identityprovider/redirect/\d+/login|Anmelden mit SSO|category=auth\.login", re.I)


def is_hisinone_url(url: str | None) -> bool:
    p = urlsplit(url or "")
    return p.scheme == "https" and (p.hostname or "").lower() == HOST


def is_logged_in(html: str, url: str | None = None) -> bool:
    """Angemeldet: Seite von HISinOne mit Abmelden-Link (category=auth.logout); Felder des versteckten Dialogs
    "Sitzung abgelaufen" aendern daran nichts"""
    if url is not None and not is_hisinone_url(url):
        return False
    return bool(_LOGOUT_RE.search(html or ""))


def is_login_page(html: str) -> bool:
    """Nicht angemeldet: kein Abmelden-Link, dafuer der SSO-Knopf oder das Anmeldeformular"""
    return not is_logged_in(html) and bool(_LOGIN_HINT_RE.search(html or ""))


# iCal-Export des persoenlichen Stundenplans: HISinOne zeigt eine Abo-Adresse (Link oder Textfeld zum Kopieren)
_ICS_HREF_RE = re.compile(r"""(?:href|value|data-url)\s*=\s*["']([^"']*(?:CalendarExport|calendarExport|\.ics\b|/ical\b|iCalendar)[^"']*)["']""",
                          re.I)


# Popup "Daten fuer iCalendar (ics) exportieren" steht schon im DOM: textarea
# #plan:scheduleConfiguration:anzeigeoptionen:ical:cal_add mit der Abo-Adresse
# .../qisserver/pages/cm/exa/timetable/individualTimetableCalendarExport.faces?user=<72>&hash=<32>&termgroup=
# Die Adresse ist ein persoenlicher Abo-Link (wie ein Geheimnis: nie protokollieren, nur im Schluesselbund/Tresor)
_ICS_TEXTAREA_RE = re.compile(r"<textarea\b[^>]*\bid=\"[^\"]*ical[^\"]*\"[^>]*>([^<]*)</textarea>", re.I)
EXPORT_PATH = "/qisserver/pages/cm/exa/timetable/individualTimetableCalendarExport.faces"


def is_export_url(url: str | None) -> bool:
    """Abo-Adresse des Stundenplans (nur HISinOne-Rechner, Pfad des Exports, mit user und hash)"""
    p = urlsplit(url or "")
    return is_hisinone_url(url) and p.path == EXPORT_PATH and "user=" in p.query and "hash=" in p.query


def ical_link(page_html: str, base: str = HSH_CM_BASE) -> str | None:
    """Adresse des iCal-Exports aus der Stundenplan-Seite (absolut, nur HISinOne-Rechner); None ohne Export"""
    for m in _ICS_TEXTAREA_RE.finditer(page_html or ""):
        url = _html.unescape(m.group(1).strip())
        if is_export_url(url):
            return url
    for m in _ICS_HREF_RE.finditer(page_html or ""):
        raw = _html.unescape(m.group(1).strip())
        if not raw or raw.startswith(("javascript:", "#")):
            continue
        url = urljoin(base + "/", raw)
        if is_hisinone_url(url):
            return url
    return None


class _Tables(HTMLParser):
    """Tabellen als Zeilen von Zellentexten (th und td), verschachtelte Tabellen getrennt"""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.tables: list[list[list[str]]] = []
        self._stack: list[list[list[str]]] = []
        self._row: list[str] | None = None
        self._cell: list[str] | None = None
        self._skip = 0

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style"):
            self._skip += 1
        elif tag == "table":
            self._stack.append([])
        elif tag == "tr" and self._stack:
            self._row = []
        elif tag in ("td", "th") and self._row is not None:
            self._cell = []
        elif tag == "br" and self._cell is not None:
            self._cell.append(" ")

    def handle_endtag(self, tag):
        if tag in ("script", "style"):
            self._skip = max(0, self._skip - 1)
        elif tag in ("td", "th") and self._cell is not None and self._row is not None:
            self._row.append(" ".join("".join(self._cell).split()))
            self._cell = None
        elif tag == "tr" and self._row is not None and self._stack:
            if self._row:
                self._stack[-1].append(self._row)
            self._row = None
        elif tag == "table" and self._stack:
            self.tables.append(self._stack.pop())

    def handle_data(self, data):
        if self._cell is not None and not self._skip:
            self._cell.append(data)


def tables(page_html: str) -> list[list[list[str]]]:
    p = _Tables()
    p.feed(page_html or "")
    return p.tables


# HISinOne-Spaltennamen -> Namen, die qis.parse_grade_rows kennt (die gemeinsame Zeilenlogik bleibt unveraendert)
_HEADER_ALIASES = {
    "titel": "Text", "freigabedatum": "Datum", "nummer": "Nr.", "prüfungsnummer": "Prüfungsnr.", "pruefungsnummer": "Prüfungsnr.",
    "bezeichnung": "Bezeichnung", "ects-punkte": "ECTS", "ects punkte": "ECTS", "leistungspunkte": "Credits",
    "lp": "Credits", "cp": "Credits", "bewertung": "Note", "prüfungsstatus": "Status", "anerkannt": "Vermerk",
    "semester/termin": "Semester", "termin": "Semester",
}


def _alias(cell: str) -> str:
    c = (cell or "").strip()
    return _HEADER_ALIASES.get(c.lower(), c)


_STAMMDATEN = ("matrikelnummer", "matrikelnr", "geburtsdatum", "geburtsort", "anschrift")


def grade_rows(page_html: str) -> list[list[str]]:
    """Zeilen aller Leistungstabellen der Seite; Kopfzeilen mit HISinOne-Namen werden auf die QIS-Namen gebracht,
    Tabellen mit Stammdaten werden nie gelesen"""
    out: list[list[str]] = []
    for t in tables(page_html):
        flat = " ".join(c.lower() for r in t for c in r)
        if any(s in flat for s in _STAMMDATEN):
            continue
        for row in t:
            out.append([_alias(c) for c in row] if any(c.strip().lower() in _HEADER_ALIASES or c.strip().lower() == "note"
                                                      for c in row) else row)
    return out


_LEVEL_RE = re.compile(r"^\d+(?:\.\d+)*$")


def parse_grades(page_html: str) -> list[dict]:
    """Leistungen der Leistungsuebersicht (personExamsReadonly, Baumtabelle mit 15 Spalten: Ebene, Titel, Nummer,
    Versuch, Ruecktritt, Note, Bonus, Malus, Status, Freiversuch, Vermerk, Vorbehalt, Zusatzmerkmal, Freigabedatum,
    Aktionen) wie qis.parse_grade_rows (pruefungsnr, text, note, status, credits = Bonus, versuch, datum = Freigabedatum,
    abschluss). Jede Tabelle steht doppelt im HTML (tableOverflowFix + treeTableWithIcons): dieselbe Leistung zaehlt
    einmal. Zeilen ohne Note und Status (Ueberschriften der Ebenen) sind keine Leistungen. Abschluss = Titel der
    obersten Ebene ("1") darueber."""
    from .qis import parse_grade_rows
    out, seen = [], set()
    abschluss = ""
    header: list[str] | None = None
    for row in grade_rows(page_html):
        low = [c.strip().lower() for c in row]
        if "note" in low and "text" in low:
            header = row
            continue
        if header is None:
            continue
        level = row[0].strip() if row else ""
        if _LEVEL_RE.match(level) and "." not in level and len(row) > 1 and row[1].strip():
            abschluss = row[1].strip()[:160]                     # oberste Ebene: Abschluss/Studiengang
        for g in parse_grade_rows([header, row], abschluss):
            key = (g.get("pruefungsnr"), g.get("text"), g.get("semester"), g.get("versuch"), g.get("note"), g.get("status"))
            if key not in seen:
                seen.add(key)
                out.append(g)
    return out


def exam_registrations(page_html: str) -> list[dict]:
    """Pruefungen der Seite "Pruefungen anmelden" (sollistvergleichBaum): je Pruefung Nummer, Titel, Hinweis und ob
    sie angemeldet ist ("zugelassen" im Text oder Aktion "abmelden / aendern") oder angemeldet werden koennte (Aktion
    "Anmelden"). Nur lesen; die Knoepfe loest die App nie aus."""
    out, seen = [], set()
    for t in _row_blocks(page_html):
        text = " ".join(_html.unescape(re.sub(r"<[^>]+>", " ", t)).split())
        m = re.search(r"\b(\d{4,8})\s+(.+?)(?:\s+-\s+(.+?))?(?=\s+Detailansicht|\s*$)", text)
        if not m:
            continue
        number, title, hint = m.group(1), m.group(2).strip(), (m.group(3) or "").strip()
        actions = " ".join(re.findall(r"(?:alt|title)=\"([^\"]*)\"", t)).lower()
        if "abmelden" in actions or "zugelassen" in hint.lower() or "angemeldet" in hint.lower():
            state = "angemeldet"
        elif "anmelden" in actions:
            state = "offen"
        else:
            state = "unbekannt"
        if number not in seen:
            seen.add(number)
            out.append({"number": number, "title": title, "hint": hint, "state": state})
    return out


_TR_RE = re.compile(r"<tr\b[^>]*>(.*?)</tr>", re.S | re.I)


def _row_blocks(page_html: str) -> list[str]:
    """Zeilen (rohes HTML) der Baumtabellen; Kopfzeilen ohne Ziffernfolge fallen spaeter weg"""
    return [m.group(1) for m in _TR_RE.finditer(page_html or "") if "<td" in m.group(1).lower()]


_IFRAME_RE = re.compile(r"<iframe\b[^>]*\bsrc=\"([^\"]+)\"", re.I)


def iframe_src(page_html: str, base: str = HSH_CM_BASE) -> str | None:
    """Adresse des alten QIS im Iframe (Pruefungen und Studium), nur auf dem HISinOne-Rechner"""
    m = _IFRAME_RE.search(page_html or "")
    if not m:
        return None
    url = urljoin(base + "/", _html.unescape(m.group(1)))
    return url if is_hisinone_url(url) else None


# Pruefungsanmeldung: Zeitraeume, falls HISinOne sie auf der Seite nennt ("Anmeldezeitraum 01.12.2026 - 15.12.2026")
_PERIOD_RE = re.compile(r"(An(?:-|\s+und\s+Ab)?meld\w*zeitraum|Abmeld\w*zeitraum|Anmeldung|Abmeldung)[^0-9]{0,40}?"
                        r"(\d{1,2}\.\d{1,2}\.\d{4})(?:\s*,?\s*\d{1,2}:\d{2})?\s*(?:-|–|bis)\s*(\d{1,2}\.\d{1,2}\.\d{4})", re.I)


def _iso(d: str) -> str:
    day, month, year = d.split(".")
    return f"{year}-{int(month):02d}-{int(day):02d}"


def registration_periods(page_text: str) -> list[dict]:
    """Zeitraeume der Pruefungsan-/-abmeldung aus einem Seitentext: [{kind, from, to}] (ohne Doppelte)"""
    out, seen = [], set()
    for m in _PERIOD_RE.finditer(" ".join(_html.unescape(re.sub(r"<[^>]+>", " ", page_text or "")).split())):
        kind = "abmeldung" if m.group(1).lower().startswith("abmeld") else "anmeldung"
        item = (kind, _iso(m.group(2)), _iso(m.group(3)))
        if item not in seen:
            seen.add(item)
            out.append({"kind": item[0], "from": item[1], "to": item[2]})
    return out


# ---------------------------------------------------------------------------------------------------------------
# Mit Browser-Sitzung (Playwright, PC): nur lesen
# ---------------------------------------------------------------------------------------------------------------

class SessionExpired(RuntimeError):
    pass


def _open(page, url: str) -> str:
    page.goto(url, wait_until="domcontentloaded")
    page.wait_for_timeout(800)
    content = page.content()
    if not is_logged_in(content, page.url):
        raise SessionExpired("Campusmanagement: Anmeldung nötig (Einstellungen > Zugang > im Browser anmelden).")
    return content


ICS_BUTTON_TEXTS = ("Daten für iCalendar (ics) exportieren", "iCalendar", "iCal-Datei öffnen", "ics")


def fetch_plan_ics(page) -> str | None:
    """iCal des persoenlichen Stundenplans ueber den Knopf "Daten fuer iCalendar (ics) exportieren" (Download oder
    angezeigte Adresse); None, wenn die Seite keinen Export anbietet. Ein Kalender ohne VEVENT ist eine unvollstaendige
    Antwort (Fehler), damit keine Serie entfernt wird."""
    content = _open(page, TIMETABLE_URL)
    link = ical_link(content)
    text = ""
    if not link:
        for label in ICS_BUTTON_TEXTS:
            btn = page.locator(f"button:has-text('{label}'), a:has-text('{label}'), input[value*='{label}'], "
                               f"[title*='{label}']").first
            if not btn.count():
                continue
            try:
                with page.expect_download(timeout=15000) as dl:
                    btn.click()
                path = dl.value.path()
                text = open(path, encoding="utf-8", errors="replace").read() if path else ""
            except Exception:  # noqa: BLE001 - kein Download: vielleicht zeigt die Seite die Adresse
                link = ical_link(page.content())
            if text or link:
                break
    if not text and link:
        r = page.request.get(link)
        text = r.text() if r.ok else ""
    if not text and not link:
        return None
    if "BEGIN:VCALENDAR" not in text:
        raise RuntimeError("Campusmanagement: iCal-Export ohne Kalender")
    if "BEGIN:VEVENT" not in text:
        raise RuntimeError("Campusmanagement: iCal-Export ohne Termine")
    return text


ICMS_BASE = "https://icms.hs-hannover.de"


def open_icms(page) -> str | None:
    """Altes QIS (icms.hs-hannover.de) ueber den Iframe "Pruefungen und Studium": HISinOne leitet per
    rds?state=redirect&sso=qis mit derselben Anmeldung weiter. Liefert die Startadresse im QIS oder None."""
    src = iframe_src(_open(page, QIS_IFRAME_URL))
    if not src:
        return None
    page.goto(src, wait_until="domcontentloaded")
    page.wait_for_timeout(600)
    host = (urlsplit(page.url).hostname or "").lower()
    return page.url if host == urlsplit(ICMS_BASE).hostname else None


def icms_profile(start: str) -> dict:
    """Profil fuer die QIS-Leser der LUH (app/qis.py), hier fuer das alte QIS der HsH; keine Bescheinigungen"""
    return {"key": "hsh", "base": ICMS_BASE, "start": start, "documents": False}


def fetch_grades(page) -> list[dict]:
    """Leistungen aus HISinOne; ist die Leistungsuebersicht leer (Fakultaet noch im alten QIS), der Notenspiegel im
    alten QIS (icms.hs-hannover.de, gleiche HIS-QIS-Technik wie die LUH: app/qis.py fetch_grades)"""
    grades = parse_grades(_open(page, GRADES_URL))
    if grades:
        return grades
    start = open_icms(page)
    if not start:
        return []
    from . import qis
    return qis.fetch_grades(page, icms_profile(start), qis.DocStore())


def fetch_exam_registrations(page) -> list[dict]:
    """Angemeldete Pruefungen: HISinOne (Pruefungen anmelden, nur Zeilen mit "zugelassen"/"abmelden") und das alte QIS
    ("Info ueber angemeldete Pruefungen", app/qis_registrations.py) - als Zeilen fuer exam_registrations"""
    rows = [{"pruefungsnr": r["number"], "text": r["title"], "status": "angemeldet", "raw": r["hint"],
             "abschluss": ""} for r in exam_registrations(_open(page, EXAM_REGISTRATION_URL)) if r["state"] == "angemeldet"]
    start = open_icms(page)
    if start:
        from . import qis_registrations

        def get(url):
            resp = page.goto(url, wait_until="domcontentloaded")
            return (resp.status if resp else 200), page.content(), page.url
        try:
            rows += qis_registrations.walk(get, start)["registrations"]
        except Exception:  # noqa: BLE001 - Fakultaet ohne altes QIS
            pass
    return rows

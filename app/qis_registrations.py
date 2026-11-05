"""QIS "Info über angemeldete Prüfungen" am PC, nur lesend (Entscheidung des Inhabers 05.11.2026,
docs/PRUEFUNGSANMELDUNG-2026-11-05.md). Gleiche Regeln wie der Swift-Kern (ExamRegistration/QISRegistrations.swift):
Startseite -> "Mein Studium" -> Link "Info über angemeldete Prüfungen" -> Tabellen; ohne Tabelle den Baum (Abschluss,
Studiengang) aufklappen, hoechstens MAX_PAGES Seiten. Laeuft im normalen QIS-Abruf mit (app/qis.py, dieselbe
angemeldete Browsersitzung wie der Notenspiegel); getestet mit den erfundenen Seiten
packages/shared-contracts/fixtures/exam-registration/qis-*.html.

NICHT AM ECHTEN KONTO GESEHEN (wie auf dem iPad). Sicherheit: nie einem Link zur Pruefungsanmeldung/-abmeldung folgen
(`is_forbidden`: Text oder Parameter mit Anmeldung, Abmeldung, Ruecktritt), nie ein Formular abschicken (nur GET der
gefundenen Links), nie eine Bescheinigung oeffnen; asi und Stammdaten werden nie gespeichert. Die App meldet nie
selbst an oder ab.
"""
from __future__ import annotations

import json
import re
import unicodedata
from collections import Counter
from datetime import date
from html.parser import HTMLParser
from urllib.parse import unquote_plus, urljoin, urlsplit

from . import db

MAX_PAGES = 12
RUN_KEY = "exam_registration_run"
TABLE_SQL = """CREATE TABLE IF NOT EXISTS exam_registrations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    pruefungsnr TEXT, text TEXT NOT NULL, semester TEXT, datum TEXT, time TEXT, room TEXT, pruefer TEXT,
    versuch TEXT, status TEXT, withdraw TEXT, form TEXT, abschluss TEXT, raw TEXT, fetched_at TEXT
)"""
FIELDS = ("pruefungsnr", "text", "semester", "datum", "time", "room", "pruefer", "versuch", "status", "withdraw", "form", "abschluss")
ASI_RE = re.compile(r"^[A-Za-z0-9._~$-]{1,128}$")


class SessionExpired(Exception):
    pass


class InfoNotFound(Exception):
    def __str__(self) -> str:
        return "Die Seite „Info über angemeldete Prüfungen“ wurde im QIS nicht gefunden."


# ---------------------------------------------------------------------------- Texte

def clean(s: str) -> str:
    s = (s or "").replace("­", "").replace("​", "")
    return " ".join(s.split())


def fold(text: str) -> str:
    s = unicodedata.normalize("NFC", text or "").lower()
    for a, b in (("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss")):
        s = s.replace(a, b)
    return s


# ---------------------------------------------------------------------------- Zeilen der Info-Seite

HEADERS = {
    "prüfungsnr": "pruefungsnr", "pruefungsnr": "pruefungsnr", "nr": "pruefungsnr", "prüfungsnummer": "pruefungsnr",
    "pnr": "pruefungsnr", "modulnr": "pruefungsnr", "nummer": "pruefungsnr",
    "prüfungstext": "text", "pruefungstext": "text", "text": "text", "bezeichnung": "text", "prüfung": "text",
    "pruefung": "text", "titel": "text", "veranstaltung": "text", "modul": "text", "leistung": "text",
    "prüfungsleistung": "text", "veranstaltungstitel": "text",
    "semester": "semester", "sem": "semester",
    "datum": "datum", "prüfungsdatum": "datum", "pruefungsdatum": "datum", "termin": "datum", "prüfungstermin": "datum",
    "tag": "datum",
    "uhrzeit": "time", "zeit": "time", "beginn": "time",
    "raum": "room", "ort": "room", "hörsaal": "room",
    "prüfer": "pruefer", "pruefer": "pruefer", "prüferin": "pruefer", "prüfende": "pruefer", "prüfender": "pruefer",
    "dozent": "pruefer", "dozentin": "pruefer",
    "versuch": "versuch",
    "status": "status", "vermerk": "status", "zustand": "status",
    "rücktritt": "withdraw", "ruecktritt": "withdraw", "rücktrittsfrist": "withdraw", "abmeldung": "withdraw",
    "abmeldefrist": "withdraw", "abmelden": "withdraw", "abmeldeschluss": "withdraw",
    "form": "form", "prüfungsform": "form", "pruefungsform": "form", "art": "form", "prüfungsart": "form", "prfart": "form",
    "note": "note", "bewertung": "note",
}
NON_WORD_RE = re.compile(r"[^\wäöüß]+")
NEGATIVE = {"amd", "abgemeldet", "rt", "rte", "rtu", "rücktritt", "ruecktritt", "zurückgetreten", "be", "bestanden", "nb",
            "nicht bestanden", "en", "endgültig nicht bestanden", "ab"}
STAMMDATEN = ("matrikelnummer", "matrikelnr", "geburtsdatum", "geburtsort", "anschrift")
DMY_RE = re.compile(r"(\d{1,2})\.(\d{1,2})\.(\d{4})")
ISO_RE = re.compile(r"(\d{4})-(\d{2})-(\d{2})")
CLOCK_RE = re.compile(r"(?<!\d)(\d{1,2})[:.](\d{2})(?:\s*Uhr)?(?![\d.])")


def header_map(cells: list[str]) -> list[str | None]:
    out = []
    for h in cells:
        words = NON_WORD_RE.sub(" ", (h or "").strip().lower()).split()
        if not words:
            out.append(None)
            continue
        if words[0] in ("prüfungs", "pruefungs") and len(words) > 1:
            out.append(HEADERS.get(words[0] + words[1]) or HEADERS.get(words[1]))
            continue
        out.append(HEADERS.get(words[0]))
    return out


def is_header(m: list) -> bool:
    return "text" in m and "note" not in m and ("pruefungsnr" in m or "datum" in m or "semester" in m)


def is_stammdaten_row(cells: list[str]) -> bool:
    return any(c.lower().startswith(STAMMDATEN) for c in cells)


def is_registered(status) -> bool:
    """Leer gilt als angemeldet (die Seite listet nur Anmeldungen); abgemeldet, Ruecktritt und bewertet nicht"""
    s = str(status or "").strip().lower()
    if not s or s == "an" or ("angemeldet" in s and "abgemeldet" not in s) or "zugelassen" in s:
        return True
    if s in NEGATIVE or s.startswith(("abgemeldet", "rücktritt", "nicht bestanden", "endgültig", "bestanden")):
        return False
    return True


def _days_in_month(y: int, m: int) -> int:
    return (date(y + (m == 12), m % 12 + 1, 1) - date(y, m, 1)).days


def iso_date(s) -> str | None:
    if not s:
        return None
    m = DMY_RE.search(s)
    if m:
        d, mo, y = int(m.group(1)), int(m.group(2)), int(m.group(3))
    else:
        m = ISO_RE.search(s)
        if not m:
            return None
        y, mo, d = int(m.group(1)), int(m.group(2)), int(m.group(3))
    if y < 2000 or not 1 <= mo <= 12 or d < 1 or d > _days_in_month(y, mo):
        return None
    return f"{y:04d}-{mo:02d}-{d:02d}"


def clock(s) -> str | None:
    if not s:
        return None
    m = DMY_RE.search(s)
    if m:
        s = s.replace(m.group(0), " ")
    m = CLOCK_RE.search(s)
    if not m:
        return None
    h, mi = int(m.group(1)), int(m.group(2))
    if not (0 <= h <= 23 and 0 <= mi <= 59):
        return None
    return f"{h:02d}:{mi:02d}"


def row_view(r: dict) -> dict:
    """Abgeleitete Felder einer Zeile"""
    return {**r, "registered": is_registered(r.get("status")), "iso_date": iso_date(r.get("datum")),
            "clock": clock(r.get("time")) or clock(r.get("datum")), "iso_withdraw": iso_date(r.get("withdraw"))}


def parse_rows(rows: list[list[str]], abschluss: str = "") -> list[dict]:
    out, mapped = [], None
    for raw in rows:
        cells = [clean(c) for c in raw]
        if is_stammdaten_row(cells):
            continue
        hm = header_map(cells)
        if is_header(hm):
            mapped = hm
            continue
        if "note" in hm and "text" in hm:
            mapped = None
            continue
        if mapped is None or sum(1 for c in cells if c) < 2:
            continue
        f: dict[str, str] = {}
        for k, v in zip(mapped, cells):
            if k and v and k not in f:
                f[k] = v
        if not f.get("text") or not any(f.get(k) for k in ("pruefungsnr", "datum", "semester", "status")):
            continue
        rec = {k: f.get(k) for k in FIELDS if k not in ("abschluss",)}
        rec["abschluss"] = abschluss or None
        rec["raw"] = " | ".join(cells)
        out.append(rec)
    return out


def merge(rows: list[dict]) -> list[dict]:
    seen, out = set(), []
    for r in rows:
        k = (r.get("pruefungsnr"), r.get("text"), r.get("semester"), r.get("datum"))
        if k not in seen:
            seen.add(k)
            out.append(r)
    return out


# ---------------------------------------------------------------------------- Seiten (ohne Browser lesbar)

class _Scan(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.anchors: list[dict] = []
        self.tables: list[dict] = []
        self.has_password = False
        self.base = None
        self.forms: list[str] = []
        self.hidden_asi: list[str] = []
        self._a = None
        self._stack: list[dict] = []
        self._cell: list[str] | None = None

    def handle_starttag(self, tag, attrs):
        a = {k.lower(): (v or "") for k, v in attrs}
        if tag == "a" and a.get("href"):
            self._a = {"href": a["href"], "text": [], "title": a.get("title", ""), "alt": ""}
        elif tag == "img" and self._a is not None and not self._a["alt"]:
            self._a["alt"] = a.get("alt") or a.get("title") or ""
        elif tag == "base" and a.get("href") and self.base is None:
            self.base = a["href"]
        elif tag == "input":
            if a.get("type", "").lower() == "password":
                self.has_password = True
            if a.get("type", "").lower() == "hidden" and a.get("name", "").lower() == "asi" and a.get("value"):
                self.hidden_asi.append(a["value"])
        elif tag == "form" and a.get("action"):
            self.forms.append(a["action"])
        elif tag == "table":
            t = {"summary": a.get("summary", ""), "rows": []}
            self.tables.append(t)
            self._stack.append(t)
        elif tag == "tr" and self._stack:
            self._stack[-1]["rows"].append([])
        elif tag in ("td", "th") and self._stack:
            if not self._stack[-1]["rows"]:
                self._stack[-1]["rows"].append([])
            self._cell = []
            self._stack[-1]["rows"][-1].append(self._cell)

    def handle_endtag(self, tag):
        if tag == "a" and self._a is not None:
            text = clean("".join(self._a["text"]))
            self.anchors.append({"href": self._a["href"], "label": text or clean(self._a["title"]) or clean(self._a["alt"])})
            self._a = None
        elif tag == "table" and self._stack:
            self._stack.pop()
            self._cell = None
        elif tag in ("td", "th"):
            self._cell = None

    def handle_data(self, data):
        if self._a is not None:
            self._a["text"].append(data)
        if self._cell is not None:
            self._cell.append(data)


def parameters(address: str) -> dict:
    """Abfrageparameter (Namen klein, Werte dekodiert, der erste gilt)"""
    if "?" not in address:
        return {}
    out = {}
    for item in address.split("?", 1)[1].split("&"):
        k, _, v = item.partition("=")
        name = unquote_plus(k).lower()
        if name and name not in out:
            out[name] = unquote_plus(v)
    return out


def strip_session(url: str) -> tuple[str, str | None]:
    """Adresse ohne asi, jsessionid und Sprungmarke; dazu asi"""
    s = url.split("#", 1)[0]
    q = None
    if "?" in s:
        s, q = s.split("?", 1)
    s = re.sub(r";jsessionid=[^/]*", "", s, flags=re.I)
    asi, kept = None, []
    for item in (q or "").split("&") if q else []:
        name = unquote_plus(item.split("=", 1)[0]).lower()
        if name == "asi":
            if asi is None and "=" in item:
                asi = unquote_plus(item.split("=", 1)[1])
        elif name != "jsessionid" and item:
            kept.append(item)
    return (s + ("?" + "&".join(kept) if kept else "")), asi


class Link:
    def __init__(self, text: str, address: str):
        self.text, self.address = text, address
        self.parameters = parameters(address)

    @property
    def state(self) -> str | None:
        return self.parameters.get("state")

    @property
    def host(self) -> str | None:
        h = urlsplit(self.address).hostname
        return h.lower() if h else None

    def __repr__(self):
        return f"Link({self.text!r}, {self.address!r})"


class Page:
    def __init__(self, html: str, url: str):
        scan = _Scan()
        try:
            scan.feed(html or "")
            scan.close()
        except Exception:  # noqa: BLE001 - kaputtes HTML: was gelesen ist, bleibt
            pass
        base = urljoin(url, scan.base) if scan.base else url
        page_host = (urlsplit(url).hostname or "").lower()
        self.address, tok = strip_session(url)
        tokens = [tok] if tok and ASI_RE.match(tok) else []
        self.links: list[Link] = []
        for a in scan.anchors:
            href = a["href"].strip()
            if href.lower().startswith(("javascript:", "mailto:")):
                continue
            absu = urljoin(base, href)
            if not absu.lower().startswith(("http://", "https://")):
                continue
            address, t = strip_session(absu)
            link = Link(a["label"], address)
            if link.host == page_host and t and ASI_RE.match(t):
                tokens.append(t)
            self.links.append(link)
        for action in scan.forms:
            absu = urljoin(base, action)
            if (urlsplit(absu).hostname or "").lower() == page_host:
                _, t = strip_session(absu)
                if t and ASI_RE.match(t):
                    tokens.append(t)
        tokens += [t for t in scan.hidden_asi if ASI_RE.match(t)]
        counts = Counter(tokens)
        self.session = max(tokens, key=lambda t: (counts[t], -tokens.index(t))) if tokens else None
        self.has_login_form = scan.has_password
        self.tables = [[[clean("".join(c)) for c in row] for row in t["rows"]] for t in scan.tables
                       if "stammdaten" not in t["summary"].lower()
                       and not any(is_stammdaten_row([clean("".join(c)) for c in row]) for row in t["rows"])]

    @staticmethod
    def _logout(l: Link) -> int | None:
        p, t, addr = l.parameters, l.text.lower(), l.address.lower()
        if "logout" in addr or (p.get("state", "").lower() == "user" and p.get("type") == "4"):
            return 0
        return 1 if t in ("logout", "abmelden") else None

    @property
    def is_logged_in(self) -> bool:
        return any(self._logout(l) is not None for l in self.links)

    def mein_studium(self) -> Link | None:
        host = (urlsplit(self.address).hostname or "").lower()
        cands = []
        for l in self.links:
            if l.host != host or self._logout(l) is not None:
                continue
            if l.parameters.get("moduleparameter", "").lower() == "studyposmenu":
                cands.append((0, l))
            elif l.text.lower() == "mein studium":
                cands.append((1, l))
        cands.sort(key=lambda x: x[0])
        return cands[0][1] if cands else None

    def url_for(self, link: Link) -> str:
        """Adresse zum Aufrufen: mit dem asi dieser Seite (nur derselbe Rechner). Nie speichern."""
        if not self.session or link.host is None or link.host != (urlsplit(self.address).hostname or "").lower():
            return link.address
        return link.address + ("&" if "?" in link.address else "?") + "asi=" + self.session


# ---------------------------------------------------------------------------- Links

PROGRAM_RE = re.compile(r"(?:prüfungen|pruefungen|leistungen)\s+f(?:ü|ue)r\s+(.+?)\s+anzeigen\s*$", re.I)


def is_forbidden(l: Link) -> bool:
    """Nie folgen: Pruefungsanmeldung/-abmeldung, Ruecktritt, Bescheinigungen, PDF, Abmelden (Logout)"""
    t = fold(clean(l.text))
    if any(k in t for k in ("abmeld", "ruecktritt", "zuruecktreten", "anmelden", "abmelden", "logout")):
        return True
    if "anmeldung" in t and "angemeldet" not in t:
        return True
    p = l.parameters
    for key in ("state", "next", "moduleparameter", "menuid", "navigationposition", "breadcrumb", "subitem"):
        v = fold(p.get(key, ""))
        if any(k in v for k in ("anmeld", "abmeld", "prfanm", "pruefungsan", "ruecktritt", "rucktritt", "logout")):
            return True
    a = l.address.lower()
    if p.get("state", "").lower() == "verpublish" or ".pdf" in a or "logout" in a or t.startswith("pdf"):
        return True
    if p.get("state") == "user" and p.get("type") == "4":
        return True
    return False


def is_info(l: Link) -> bool:
    if is_forbidden(l):
        return False
    t = fold(clean(l.text))
    return "angemeldete pruefungen" in t or "angemeldeten pruefungen" in t or "angemeldete leistungen" in t


def studiengang(l: Link) -> str | None:
    lower = l.text.lower()
    for prefix in ("leistungen für ", "leistungen fuer "):
        if lower.startswith(prefix) and lower.endswith(" anzeigen"):
            c = clean(l.text[len(prefix):-len(" anzeigen")])
            return c or None
    m = PROGRAM_RE.search(clean(l.text))
    if not m:
        return None
    return clean(m.group(1)) or None


def next_links(page: Page, info: Link, visited: set[str]) -> list[Link]:
    host = (urlsplit(page.address).hostname or "").lower()
    state = (info.state or "").lower()
    visited_nodes = {parameters(v).get("nodeid", "").lower() for v in visited} - {""}
    seen, out = set(), []
    for l in page.links:
        if l.host != host or l.address in visited or is_forbidden(l) or l.address in seen:
            continue
        seen.add(l.address)
        is_list = l.parameters.get("next", "").lower() == "list.vm"
        node = l.parameters.get("nodeid", "").lower()
        if node and not is_list and node in visited_nodes:
            continue
        if is_info(l):
            out.append(l)
            continue
        if state and (l.state or "").lower() == state and (node or is_list):
            out.append(l)
    return out[:10]


def info_tables(p: Page) -> list[list[list[str]]]:
    return [t for t in p.tables if any(is_header(header_map(r)) for r in t)]


def walk(get, start: str, max_pages: int = MAX_PAGES) -> dict:
    """`get(url) -> (status, html, final_url)`; nur GET. Liefert {registrations, pages, tables}."""
    def page(url: str) -> Page:
        status, html, final = get(url)
        if status != 200:
            raise RuntimeError(f"QIS antwortet mit HTTP {status}")
        p = Page(html, final or url)
        if p.has_login_form or not p.is_logged_in:
            raise SessionExpired("QIS-Sitzung abgelaufen")
        return p

    first = page(start)
    pages, src = 1, first
    info = next((l for l in first.links if is_info(l)), None)
    if info is None:
        st = first.mein_studium()
        if st is not None and not is_forbidden(st):
            src = page(first.url_for(st))
            pages += 1
            info = next((l for l in src.links if is_info(l)), None)
    if info is None:
        raise InfoNotFound()
    visited = {first.address, src.address}
    rows, n_tables = [], 0
    pending = [(info, src)]
    while pending and pages < max_pages:
        link, frm = pending.pop(0)
        if link.address in visited or is_forbidden(link):
            continue
        p = page(frm.url_for(link))
        pages += 1
        visited.add(link.address)
        visited.add(p.address)
        ab = studiengang(link) or ""
        for t in info_tables(p):
            n_tables += 1
            rows += parse_rows(t, ab)
        pending = [(l, p) for l in next_links(p, info, visited)] + pending
    return {"registrations": merge(rows), "pages": pages, "tables": n_tables}


# ---------------------------------------------------------------------------- Speicher (nur dieser PC)

def message(count: int) -> str:
    return "Im QIS sind keine Prüfungen angemeldet." if count == 0 else \
        "1 angemeldete Prüfung gelesen." if count == 1 else f"{count} angemeldete Prüfungen gelesen."


def store(conn, rows: list[dict], now: str) -> None:
    conn.execute(TABLE_SQL)
    conn.execute("DELETE FROM exam_registrations")
    for r in rows:
        conn.execute("""INSERT INTO exam_registrations(pruefungsnr, text, semester, datum, time, room, pruefer, versuch, status,
                        withdraw, form, abschluss, raw, fetched_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                     tuple(r.get(k) for k in FIELDS) + (r.get("raw") or "", now))


def rows(conn) -> list[dict]:
    if not conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='exam_registrations'").fetchone():
        return []
    out = []
    for r in db.rows(conn, "SELECT * FROM exam_registrations ORDER BY id"):
        d = {k: (r.get(k) or None) for k in FIELDS}
        d["text"] = r.get("text") or ""
        d["raw"] = r.get("raw") or ""
        out.append(row_view(d))
    return out


def last_run(conn) -> dict | None:
    r = conn.execute("SELECT value FROM settings WHERE key=?", (RUN_KEY,)).fetchone()
    try:
        v = json.loads(r[0]) if r and r[0] else None
    except ValueError:
        v = None
    return v if isinstance(v, dict) else None


def save_run(conn, at: str, ok: bool, count: int, msg: str) -> None:
    conn.execute("INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)",
                 (RUN_KEY, json.dumps({"at": at, "ok": ok, "count": count, "message": msg}, ensure_ascii=False)))


def run(get, start: str, now: str | None = None) -> dict:
    """Abruf und Speichern; bei einem Fehler bleiben die Zeilen, nur der Stand merkt sich die Meldung."""
    at = now or db.now_iso()
    try:
        r = walk(get, start)
    except Exception as e:  # noqa: BLE001
        msg = str(e) if isinstance(e, InfoNotFound) else ("Bitte im QIS anmelden." if isinstance(e, SessionExpired)
                                                          else f"Angemeldete Prüfungen nicht gelesen: {e}")
        with db.cursor() as conn:
            save_run(conn, at, False, 0, msg)
        return {"ok": False, "count": None, "message": msg, "needs_login": isinstance(e, SessionExpired)}
    regs = r["registrations"]
    n = sum(1 for x in regs if is_registered(x.get("status")))
    msg = message(n)
    with db.cursor() as conn:
        store(conn, regs, at)
        save_run(conn, at, True, n, msg)
    return {"ok": True, "count": n, "message": msg, "needs_login": False}


def page_getter(page):
    """Abruf ueber die angemeldete Playwright-Seite des QIS-Abgleichs (nur GET, Weiterleitungen wie im Browser)."""
    def get(url: str):
        resp = page.goto(url, wait_until="domcontentloaded")
        return (resp.status if resp else 200), page.content(), page.url
    return get

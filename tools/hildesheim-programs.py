"""Register aller Studiengaenge der Universitaet Hildesheim mit Pruefungsordnungen und Modulhandbuechern:
packages/shared-contracts/study-sources-hildesheim.json (Auftrag 05.11.2026, Bericht
docs/STUDIENGAENGE-HILDESHEIM-2026-11-05.md; Vorbild tools/luh-programs.py).

Hoeflich gegenueber den Servern der Hochschule:
- nur oeffentliche Seiten und PDFs von www.uni-hildesheim.de; nie Learnweb, LSF (lsf.uni-hildesheim.de), CAS (/sso),
  keine Anmeldeseiten (Links darauf werden verworfen, bevor irgendetwas geholt wird);
- robots.txt wird vor der ersten Anfrage gelesen und beachtet (urllib.robotparser);
- hoechstens eine Anfrage je 2,5 Sekunden, nacheinander, User-Agent "Claude-User (StudiNow-Katalogpruefung/1.0;
  support@studinow.app)" (bis Anfrage 152: "StudiNow-Katalogpruefung/1.0 (support@studinow.app)");
- jede Antwort liegt im Zwischenspeicher ~/Studora-Builds/hildesheim/crawl/ (cache/ + index.json), dieselbe URL wird
  nie zweimal geholt (auch nicht nach einem Fehler); ein zweiter Lauf arbeitet nur aus dem Zwischenspeicher;
- Obergrenze 1500 Anfragen insgesamt (Zaehler in index.json, ueber alle Laeufe).
Heruntergeladene Seiten und PDFs bleiben im Zwischenspeicher, nie im Repo.

Aufruf im Projektordner:
  .venv/bin/python tools/hildesheim-programs.py all       # holen (nur was fehlt) und Register schreiben
  .venv/bin/python tools/hildesheim-programs.py build     # nur aus dem Zwischenspeicher (0 Anfragen) schreiben
  .venv/bin/python tools/hildesheim-programs.py check     # Register frisch aus dem Zwischenspeicher bauen und vergleichen
Werkzeuge zum Nachsehen: fetch URL, links URL [Muster], text URL [Seiten], count.
"""
from __future__ import annotations

import hashlib
import html
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import urllib.robotparser
from html.parser import HTMLParser
from pathlib import Path

# ehrliche Kennung (Auftrag 05.11.2026): Abruf im Auftrag eines Nutzers durch Claude fuer StudiNow
UA = "Claude-User (StudiNow-Katalogpruefung/1.0; support@studinow.app)"
CRAWL = Path(os.environ.get("HILDESHEIM_CRAWL") or os.path.expanduser("~/Studora-Builds/hildesheim/crawl"))
CACHE = CRAWL / "cache"
INDEX = CRAWL / "index.json"
MAX_REQUESTS = 1500
DELAY = 2.5
ROOT = Path(__file__).resolve().parent.parent
OUT_JSON = ROOT / "packages/shared-contracts/study-sources-hildesheim.json"

ALLOWED_HOST = re.compile(r"^www\.uni-hildesheim\.de$")
# nie anfassen: Learnweb, LSF, CAS/SSO, Anmeldung, Intranet
FORBIDDEN_PATH = re.compile(r"(^/learnweb|^/sso|/login|/cas/|shibboleth|/saml|/auth/|typo3/|/admin|^/intranet|"
                            r"^/qisserver|^/moodle|^/webmail|^/campus|^/mein)", re.I)


class Budget(Exception):
    pass


# ---------------------------------------------------------------------------------------------------------------
# Zwischenspeicher und hoefliches Holen
# ---------------------------------------------------------------------------------------------------------------

_IDX: dict | None = None
_ROBOTS: dict[str, urllib.robotparser.RobotFileParser | None] = {}
_LAST = [0.0]
NETWORK = [True]


def idx() -> dict:
    global _IDX
    if _IDX is None:
        CACHE.mkdir(parents=True, exist_ok=True)
        _IDX = json.loads(INDEX.read_text()) if INDEX.exists() else {"requests": 0, "urls": {}, "robots": {}, "log": []}
    return _IDX


def save_index() -> None:
    tmp = INDEX.with_suffix(".tmp")
    tmp.write_text(json.dumps(idx(), ensure_ascii=False, indent=1))
    tmp.replace(INDEX)


def norm_url(url: str) -> str:
    url = html.unescape(url.strip())
    p = urllib.parse.urlsplit(url)
    scheme = "https" if p.scheme in ("http", "https", "") else p.scheme
    return urllib.parse.urlunsplit((scheme, p.netloc.lower(), p.path or "/", p.query, ""))


def _raw_get(url: str) -> tuple[int, str, bytes, str]:
    """Eine echte Anfrage: Wartezeit (auch ueber Laeufe hinweg), Zaehler, Protokoll"""
    ix = idx()
    if ix["requests"] >= MAX_REQUESTS:
        raise Budget(f"Obergrenze {MAX_REQUESTS} Anfragen erreicht")
    wait = _LAST[0] + DELAY - time.time()
    if ix["log"]:
        wait = max(wait, ix["log"][-1]["t"] + DELAY - time.time())
    if wait > 0:
        time.sleep(wait)
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept-Language": "de,en;q=0.5"})
    ix["requests"] += 1
    t0 = time.time()
    _LAST[0] = t0
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            status, ctype, body, final = r.status, r.headers.get("Content-Type", ""), r.read(), r.geturl()
    except urllib.error.HTTPError as e:
        status, ctype, body, final = e.code, e.headers.get("Content-Type", "") if e.headers else "", b"", url
    except Exception as e:  # noqa: BLE001  Netz, Zeitueberschreitung
        status, ctype, body, final = -1, "", str(e).encode(), url
    ix["log"].append({"t": t0, "url": url, "status": status, "bytes": len(body)})
    save_index()
    print(f"  [{ix['requests']:3d}] {status} {url}", file=sys.stderr)
    return status, ctype, body, final


def allowed(url: str) -> bool:
    p = urllib.parse.urlsplit(url)
    return p.scheme == "https" and bool(ALLOWED_HOST.match(p.netloc)) and not FORBIDDEN_PATH.search(p.path)


def robots_ok(url: str) -> bool:
    host = urllib.parse.urlsplit(url).netloc
    if host not in _ROBOTS:
        ix = idx()
        rurl = f"https://{host}/robots.txt"
        if rurl not in ix["robots"]:
            if not NETWORK[0]:
                return False
            status, _, body, _ = _raw_get(rurl)
            ix["robots"][rurl] = {"status": status, "text": body.decode("utf-8", "replace") if status == 200 else ""}
            save_index()
        info = ix["robots"][rurl]
        if info["status"] == 200:
            rp = urllib.robotparser.RobotFileParser()
            rp.parse(info["text"].splitlines())
            _ROBOTS[host] = rp
        else:
            _ROBOTS[host] = None
    rp = _ROBOTS[host]
    return True if rp is None else rp.can_fetch(UA, url)


def fetch(url: str) -> dict | None:
    """{status, ctype, path, final} aus dem Zwischenspeicher oder einmal geholt; None = nicht erlaubt/kein Netz"""
    url = norm_url(url)
    ix = idx()
    if url in ix["urls"]:
        return ix["urls"][url]
    if not NETWORK[0] or not allowed(url):
        return None
    if not robots_ok(url):
        ix["urls"][url] = {"status": "robots", "ctype": "", "path": None, "final": url}
        save_index()
        return ix["urls"][url]
    status, ctype, body, final = _raw_get(url)
    path = None
    if status == 200:
        ext = ".pdf" if (b"%PDF" in body[:1024] or "pdf" in ctype) else ".html"
        name = hashlib.sha1(url.encode()).hexdigest()[:16] + ext
        (CACHE / name).write_bytes(body)
        path = "cache/" + name
    entry = {"status": status, "ctype": ctype, "path": path, "final": norm_url(final), "size": len(body),
             "sha256": hashlib.sha256(body).hexdigest() if status == 200 else None}
    ix["urls"][url] = entry
    save_index()
    return entry


def cached_path(url: str) -> Path | None:
    e = fetch(url)
    if not e or not e.get("path"):
        return None
    p = CRAWL / e["path"]
    return p if p.exists() else None


def read_text(url: str) -> str | None:
    p = cached_path(url)
    return p.read_bytes().decode("utf-8", "replace") if p else None


class _Links(HTMLParser):
    def __init__(self, base: str):
        super().__init__(convert_charrefs=True)
        self.base, self.links, self._a, self._t = base, [], None, []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            href = dict(attrs).get("href")
            if href:
                self._a, self._t = href, []

    def handle_data(self, data):
        if self._a is not None:
            self._t.append(data)

    def handle_endtag(self, tag):
        if tag == "a" and self._a is not None:
            href = urllib.parse.urljoin(self.base, self._a.strip())
            self.links.append((href, " ".join(" ".join(self._t).split())))
            self._a = None


def links(url: str) -> list[tuple[str, str]]:
    txt = read_text(url)
    if txt is None:
        return []
    p = _Links(fetch(url)["final"])
    p.feed(txt)
    return p.links


def pdf_text(path: Path, max_pages: int | None = None) -> tuple[str, int]:
    from pypdf import PdfReader
    r = PdfReader(str(path))
    n = len(r.pages)
    out = []
    for i, pg in enumerate(r.pages):
        if max_pages is not None and i >= max_pages:
            break
        try:
            out.append(pg.extract_text() or "")
        except Exception:  # noqa: BLE001
            out.append("")
    return "\f".join(out), n


def html_text(s: str) -> str:
    s = re.sub(r"(?is)<(script|style).*?</\1>", " ", s)
    s = re.sub(r"(?s)<[^>]+>", " ", s)
    return " ".join(html.unescape(s).split())


def main(argv: list[str]) -> int:
    cmd = argv[1] if len(argv) > 1 else "all"
    try:
        if cmd == "fetch":
            print(json.dumps(fetch(argv[2]), indent=1))
        elif cmd == "links":
            pat = re.compile(argv[3], re.I) if len(argv) > 3 else None
            for h, t in links(argv[2]):
                if pat is None or pat.search(h + " " + t):
                    print(f"{h}\t{t}")
        elif cmd == "text":
            p = cached_path(argv[2])
            if p and p.suffix == ".pdf":
                t, n = pdf_text(p, int(argv[3]) if len(argv) > 3 else None)
                print(f"# {n} Seiten\n{t}")
            elif p:
                print(html_text(p.read_text(errors="replace")))
            else:
                print(fetch(argv[2]))
        elif cmd == "count":
            print(idx()["requests"])
        else:
            return pipeline(cmd)
    except Budget as b:
        print(f"STOP: {b}", file=sys.stderr)
        return 2
    return 0


# ---------------------------------------------------------------------------------------------------------------
# Schritt regs: elektronisches Verkuendungsblatt (uniQuIS) je Studiengang
# ---------------------------------------------------------------------------------------------------------------

QM = "https://www.uni-hildesheim.de/qm/processmanagement/"
QM_STUDIES = QM + "regulations.php?showPage=study"
STUDYFINDER = "https://www.uni-hildesheim.de/studium/studienangebot/"


def qm_html(url: str) -> str | None:
    p = cached_path(url)
    return p.read_bytes().decode("cp1252", "replace") if p else None


def _cell(s: str) -> str:
    return " ".join(html.unescape(re.sub(r"(?s)<[^>]+>", " ", s)).split())


def qm_studies() -> list[dict]:
    """Studiengaenge des Verkuendungsblatts: [{id, name, degree, page}]"""
    s = qm_html(QM_STUDIES) or ""
    out, seen = [], set()
    for m in re.finditer(r"<a href='[^']*\?page=study&study=(\d+)'[^>]*>(.*?)</a>\s*(?:\(([^)<]*)\))?", s, re.S):
        sid = int(m.group(1))
        if sid in seen:
            continue
        seen.add(sid)
        out.append({"id": sid, "label": _cell(m.group(2)), "abbr": _cell(m.group(3) or "")})
    return out


def qm_study_url(sid: int) -> str:
    return f"{QM}regulations.php?page=study&study={sid}"


def qm_rows(sid: int) -> list[dict]:
    """Dokumente eines Studiengangs: [{doc_id, file_id, year, issue, date, page, title, kind, current, studies}]"""
    s = qm_html(qm_study_url(sid)) or ""
    out = []
    for tr in re.findall(r"(?s)<tr valign=\"top\"[^>]*>.*?</tr>", s):
        cls = re.search(r"class='([^']*)'", tr[:80])
        tds = re.findall(r"(?s)<td[^>]*>(.*?)</td>", tr)
        doc = re.search(r"document\.php\?docID=(\d+)", tr)
        if not doc or len(tds) < 8:
            continue
        f = re.search(r"download\.php\?fileID=(\d+)", tds[0])
        studies = [{"id": int(a), "abbr": _cell(b)} for a, b in re.findall(r"<a href='\?study=(\d+)&page=study'>(.*?)</a>", tds[7])]
        out.append({"doc_id": int(doc.group(1)), "file_id": int(f.group(1)) if f else None,
                    "year": _cell(tds[1]), "issue": _cell(tds[2]), "date": _cell(tds[3]), "page": _cell(tds[4]),
                    "title": _cell(tds[5]), "kind": _cell(tds[6]), "current": bool(cls and "emph" in cls.group(1)),
                    "studies": studies})
    return out


def step_regs() -> list[dict]:
    fetch(QM_STUDIES)
    studies = qm_studies()
    for st in studies:
        fetch(qm_study_url(st["id"]))
    return studies


# ---------------------------------------------------------------------------------------------------------------
# Schritt pdfs: geltende Studienordnungen (mit Modulhandbuch als Anlage) und Modulhandbuecher laden
# ---------------------------------------------------------------------------------------------------------------

def download_url(file_id: int) -> str:
    return f"{QM}download.php?fileID={file_id}"


def document_url(doc_id: int) -> str:
    return f"{QM}document.php?docID={doc_id}"


# Studienordnungen, die keine Module eines Studiengangs beschreiben (Teilzeit, Zugang) oder nur Neben-/Begleitfaecher
SKIP_SO = re.compile(r"Teilzeit|Zugang|Auswahl|Zertifikat|Erweiterungsstudium|Didaktik des Erstunterrichts|"
                     r"Zwischenpr|Einrichtung eines|Bezeichnung", re.I)
SIDE_SO = re.compile(r"Nebenfach|Wahlpflichtfach|Anwendungsfach|Begleitfach", re.I)


def all_docs() -> dict[int, dict]:
    """docID -> Dokument (erste Fundstelle) mit allen Studiengaengen"""
    docs: dict[int, dict] = {}
    for st in qm_studies():
        for r in qm_rows(st["id"]):
            d = docs.setdefault(r["doc_id"], r)
            for s2 in r["studies"]:
                if s2["id"] not in [x["id"] for x in d["studies"]]:
                    d["studies"].append(s2)
    return docs


def is_catalog_doc(r: dict) -> bool:
    """Dokument mit Modulbeschreibungen: Modulhandbuch oder geltende Studienordnung eines Studiengangs/Fachs"""
    if not r["current"] or not r["file_id"]:
        return False
    if r["kind"] == "Modulhandbuch":
        return True
    t = r["title"]
    return "tudienordnung" in t and not SKIP_SO.search(t) and not SIDE_SO.search(t)


def step_pdfs() -> list[dict]:
    out = []
    for r in sorted(all_docs().values(), key=lambda r: r["doc_id"]):
        if is_catalog_doc(r):
            fetch(download_url(r["file_id"]))
            out.append(r)
    return out


# ---------------------------------------------------------------------------------------------------------------
# Schritt build: Register aus dem Zwischenspeicher (0 Anfragen)
# ---------------------------------------------------------------------------------------------------------------

def studyfinder() -> list[dict]:
    """Studienangebot (Studienfinder): [{uid, title, degrees, degreeTypes, pageLink, duration, categories}]"""
    t = read_text(STUDYFINDER) or ""
    m = re.search(r'courses="(\[[^"]*)"', t)
    return json.loads(html.unescape(m.group(1))) if m else []


def _date_iso(d: str) -> str | None:
    m = re.match(r"(\d{2})\.(\d{2})\.(\d{4})", d or "")
    if not m or m.group(3) == "0000":
        return None
    return f"{m.group(3)}-{m.group(2)}-{m.group(1)}"


def _doc_ref(r: dict) -> dict:
    out = {"title": r["title"], "url": download_url(r["file_id"]) if r["file_id"] else None,
           "document_url": document_url(r["doc_id"]), "date": _date_iso(r["date"]),
           "issue": r["issue"] or None, "page": int(r["page"]) if (r["page"] or "").isdigit() else None}
    return out


def _sort_key(r: dict):
    return (_date_iso(r["date"]) or "0000", r["doc_id"])


PO_SKIP = re.compile(r"Erweiterungsstudium|Studiengangsbezeichnung|Ergänzende Regelungen|Zwischenprüfung|Teilzeit", re.I)


def _pos_of(docs: list[dict], sid: int) -> list[dict]:
    """Geltende Pruefungsordnungen eines Studiengangs, neueste zuerst"""
    out = [r for r in docs if r["current"] and (r["kind"] == "Prüfungsordnung" or (not r["kind"] and "Prüfungsordnung" in r["title"]))
           and any(x["id"] == sid for x in r["studies"])
           and not PO_SKIP.search(r["title"]) and r["file_id"]]
    return sorted(out, key=_sort_key, reverse=True)


def _so_of(docs: list[dict], sid: int) -> list[dict]:
    """Geltende Studienordnungen/Modulhandbuecher mit Modulbeschreibungen eines Studiengangs, neueste zuerst"""
    out = [r for r in docs if is_catalog_doc(r) and any(x["id"] == sid for x in r["studies"])]
    return sorted(out, key=_sort_key, reverse=True)


def _side_of(docs: list[dict], sid: int) -> list[dict]:
    """Geltende Ordnungen fuer Neben-, Wahlpflicht-, Anwendungs- und Begleitfaecher eines Studiengangs"""
    out = [r for r in docs if r["current"] and r["file_id"] and "tudienordnung" in r["title"] and SIDE_SO.search(r["title"])
           and any(x["id"] == sid for x in r["studies"])]
    return sorted(out, key=_sort_key, reverse=True)


_PARSED: dict = {}
_PAGES: dict = {}


def parsed(file_id: int, fmt: str, degree: str = "B.Sc.", usage: str | None = None) -> dict | None:
    """Katalog aus dem Zwischenspeicher lesen (nur zum Zaehlen und zur Formatbestimmung)"""
    key = (file_id, fmt, degree, usage)
    if key in _PARSED:
        return _PARSED[key]
    p = cached_path(download_url(file_id))
    out = None
    if p is not None:
        sys.path.insert(0, str(ROOT))
        from app import study_catalog as sc
        from app.catalog_formats import get_parser
        from app.catalog_formats.hildesheim import LAYOUT_FORMATS, pages_for
        pk = (file_id, fmt in LAYOUT_FORMATS)
        if pk not in _PAGES:
            _PAGES[pk] = pages_for(fmt, p.read_bytes())
        pages = _PAGES[pk]
        meta = {"university": "hildesheim", "program": "x", "degree": degree, "po": "x", "code": "x",
                "catalog_term": "WS 2026/27", "source": {"url": download_url(file_id)}}
        if usage:
            meta["usage_program"] = usage
        cat, _ = get_parser(fmt)(pages, meta)
        out = {"modules": len(cat["modules"]), "pages": len(pages), "first_page": pages[0][:3000] if pages else ""}
    _PARSED[key] = out
    return out


def _term_of(r: dict) -> str | None:
    sys.path.insert(0, str(ROOT))
    from app import study_catalog as sc
    d = _date_iso(r["date"])
    return sc.current_term(d) if d else None


FACULTIES = {"1": "Fachbereich 1 – Erziehungs- und Sozialwissenschaften",
             "2": "Fachbereich 2 – Kulturwissenschaften und Ästhetische Kommunikation",
             "3": "Fachbereich 3 – Sprach- und Informationswissenschaften",
             "4": "Fachbereich 4 – Mathematik, Naturwissenschaften, Wirtschaft und Informatik"}
# Fach -> Fachbereich (Faecher im Lehramt und im Zwei-Faecher-Bachelor)
SUBJECT_FB = {"Biologie": "4", "Chemie": "4", "Geographie": "4", "Informatik": "4", "Mathematik": "4", "Physik": "4",
              "Technik": "4", "Wirtschaft": "4", "Deutsch": "3", "Englisch": "3", "Geschichte": "1", "Politikwissenschaft": "1",
              "Soziologie": "1", "Psychologie": "1", "Pädagogik": "1", "Sport": "1", "Sachunterricht": "1",
              "Evangelische Theologie": "1", "Katholische Theologie": "1", "Kunst": "2", "Musik": "2", "Philosophie": "2"}
CATEGORY_FB = {"IT & Wirtschaft": "4", "Umwelt & Natur": "4", "Psychologie & Soziales": "1", "Pädagogik & Lehramt": "1",
               "Kultur & Künste": "2", "Sprache & Medien": "3", "Sport & Gesundheit": "1"}


def _faculty(text: str | None, fallback: str | None = None) -> str | None:
    m = re.search(r"Fachbereich(?:s|es)?\s*([1-4])\b", text or "")
    fb = m.group(1) if m else fallback
    return FACULTIES.get(fb) if fb else None


DEGREE_OF = {"bsc": "B.Sc.", "ba": "B.A.", "msc": "M.Sc.", "ma": "M.A.", "medu": "M.Ed."}
DEGREE_LONG = {"B.Sc.": "Bachelor of Science", "B.A.": "Bachelor of Arts", "M.Sc.": "Master of Science",
               "M.A.": "Master of Arts", "M.Ed.": "Master of Education", "B.A./B.Sc.": "Bachelor"}

# Studienfinder (uid) -> Verkuendungsblatt-Studiengang (study) und Katalog. "it": Modulhandbuch des FB 4 (fileID),
# "usage": Studiengang ohne eigenes Handbuch, Module aus der "Verwendung" der FB-4-Handbuecher; "so": Studienordnung
# mit Modulbeschreibungen (fileID, sonst die neueste geltende des Studiengangs); "kind"/"parent": Studienvariante.
# Nicht im Register: Promotion (3), Lehramt-Infoseite (42, siehe 38).
PROGRAMS: dict[int, dict] = {
    4: {"study": 3, "usage": "MSc Wirtschaftsinformatik", "it": [5140, 5141, 5142]},
    5: {"study": 51},
    6: {"it": [5142], "po_study": 66, "note": "Studienvariante des Bachelor- und Masterprogramms Angewandte Informatik"},
    7: {"study": 52},
    8: {"study": 56},
    9: {"study": 38},
    10: {"study": 68, "it": [5146]},
    11: {"study": 35},
    12: {"study": 59},
    13: {"study": 60},
    14: {"study": 46},
    15: {"study": 24, "aliases": []},
    16: {"study": 50, "so": 5320, "umbrella": True},
    17: {"study": 49, "so": 5320, "umbrella": True},
    18: {"study": 64, "aliases": [21]},
    19: {"study": 12},
    20: {"study": 13},
    21: {"study": 9},
    22: {"study": 63, "aliases": [22]},
    23: {"study": 6, "it": [5141]},
    24: {"study": 32},
    25: {},
    26: {"study": 48},
    27: {"study": 67, "it": [5143], "tracks": [("Advanced Track", 5144), ("Cognitive Systems", 5145)]},
    28: {"study": 55},
    29: {"study": 66, "it": [5140]},
    30: {"study": 4, "usage": "BSc Wirtschaftsinformatik", "it": [5140, 5141, 5142]},
    31: {"study": 26, "so": 4671, "variant": True},
    32: {"study": 26, "so": 5261, "variant": True},
    33: {"it": [5142], "po_study": 65, "note": "Studienvariante des Bachelor- und Masterprogramms Angewandte Informatik"},
    34: {"study": 17},
    35: {"study": 25, "so": 5131, "variant": True},
    36: {"study": 69},
    37: {"study": 58},
    38: {"split": [("B.A.", 25), ("B.Sc.", 26)], "so": 5317, "umbrella": True},
    39: {"study": 33},
    40: {"po_study": 65, "note": "Studienvariante des Bachelor- und Masterprogramms Angewandte Informatik; kein eigenes "
                                "Modulhandbuch im Verkündungsblatt"},
    41: {"study": 14, "so": 5209},
    43: {"study": 61, "aliases": [23]},
    44: {"study": 62, "aliases": [20]},
    45: {"study": 10},
    46: {"study": 14, "so": 5209},
    47: {"study": 14, "so": 5209},
    48: {"study": 8, "it": [5141]},
    50: {"study": 31},
    51: {"study": 25, "so": 5259, "variant": True},
    52: {"study": 14, "so": 5209},
    53: {"study": 65, "it": [5140]},
    54: {"study": 14, "so": 5209},
    56: {},
    57: {"po_study": 50},
}
# Studiengaenge nur im Verkuendungsblatt (auslaufend oder Weiterbildung), ohne Promotion und umbenannte
QM_ONLY = [1, 28, 36, 43, 44, 47, 53, 54, 57]
QM_DEGREE = {"Staatsexam": "Staatsexamen", "M. Ed.": "M.Ed.", "B. Sc.": "B.Sc.", "M.Sc": "M.Sc.", "B.Sc": "B.Sc."}
RENAMED = {20: 62, 21: 64, 22: 63, 23: 61}


def _split_title(title: str) -> tuple[str, list[str]]:
    """'Wirtschaftsinformatik (M.Sc.)' -> ('Wirtschaftsinformatik', ['M.Sc.'])"""
    m = re.match(r"^(.*?)\s*\(([^()]*)\)\s*$", title)
    if not m:
        return title.strip(), []
    name, degs, extra = m.group(1).strip(), [], []
    for d in re.split(r",|oder", m.group(2)):
        d = d.strip()
        if re.fullmatch(r"[BM]\.?\s?(?:A|Sc|Ed)\.?", d):
            degs.append(re.sub(r"\s", "", d).rstrip(".") + ".")
        elif d:
            extra.append(d)
    if extra:
        name = f"{name} ({', '.join(extra)})"
    return name, degs


def _qm_label(st: dict) -> tuple[str, str]:
    """'Psychologie, B. Sc.' -> ('Psychologie', 'B.Sc.')"""
    label = re.sub(r"\s+Hinweis:.*$", "", st["label"])
    parts = [p.strip() for p in label.rsplit(",", 1)]
    name, deg = (parts[0], parts[1]) if len(parts) == 2 else (label, "")
    name = re.sub(r",\s*[BM]\.\s?\w+\.?$", "", name)
    deg = QM_DEGREE.get(deg, deg.replace(" ", ""))
    if deg and not deg.endswith(".") and deg not in ("Staatsexamen", "PhD"):
        deg += "."
    name = re.sub(r"\s*\((?:M\.\s?Ed\.?)\)\s*$", "", name)
    return name, deg


def qis_labels(name: str, degree: str, po: str | None, aliases: list[str] = ()) -> list[str]:
    """Geratene LSF-Bezeichnungen (Notenspiegel-Zeile "Abschluss: [nr] <Abschluss> Studiengang: [nr] <Abk.> <Name>
    PO-Version: <Jahr>"); geprueft wird erst mit echten Zeilen"""
    abschluss = "Master" if degree.startswith("M") else ("Staatsexamen" if degree.startswith("Staats") else "Bachelor")
    abbr = degree.split("/")[0] if degree.startswith(("B.", "M.")) else ""
    out = []
    for n in [name] + list(aliases):
        if po:
            out.append(f"Abschluss: {abschluss} Studiengang: {abbr} {n} PO-Version: {po}".replace("  ", " "))
        out.append(n)
    seen, res = set(), []
    for x in out:
        if x not in seen:
            seen.add(x)
            res.append(x)
    return res


def _po_year(pos: list[dict], fallback: str | None = None) -> str | None:
    for r in pos:
        m = re.search(r"\b(?:PO|GPO IT)\s*(20\d\d)\b", r["title"])
        if m:
            return m.group(1)
        d = _date_iso(r["date"])
        if d:
            return d[:4]
    return fallback


MIN_MODULES = 3      # weniger gelesene Module: Bruchstuecke einer anderen Vorlage, kein Katalog


def _catalog_of(r: dict | None, fmt: str, degree: str, usage: str | None = None, label: str | None = None) -> dict:
    if r is None:
        return {"url": None, "term": None, "format": "none",
                "reason": "keine geltende Studienordnung mit Modulbeschreibungen und kein Modulhandbuch im Verkündungsblatt"}
    info = parsed(r["file_id"], fmt, degree, usage)
    if fmt == "hildesheim-modulbeschreibung":
        # dieselbe Vorlage als zweispaltige Tabelle (FB 2/3): den Leser mit mehr Modulen nehmen
        alt = parsed(r["file_id"], "hildesheim-modultabelle", degree)
        if alt and alt["modules"] > (info or {}).get("modules", 0) * 1.2 + 1:
            fmt, info = "hildesheim-modultabelle", alt
    if not info or info["modules"] < MIN_MODULES:
        n = (info or {}).get("modules", 0)
        reason = (f"Studienordnung ({(info or {}).get('pages', '?')} Seiten) ohne lesbare Modulbeschreibungen"
                  + (f" (nur {n} Bruchstück{'e' if n != 1 else ''} gelesen)" if n else ""))
        return {"url": None, "term": None, "format": "none", "document": _doc_ref(r), "reason": reason}
    out = {"url": download_url(r["file_id"]), "term": _term_of(r), "format": fmt, "pages": info["pages"],
           "modules_est": info["modules"], "title": r["title"], "date": _date_iso(r["date"])}
    if usage:
        out["usage_program"] = usage
    if label:
        out["label"] = label
    return out


def _entry(program: str, degree: str, kind: str, *, po: str | None, pos: list[dict], catalog: dict, more: list[dict] = (),
           faculty: str | None, listed: bool, page: str | None, sid: int | None, regular: int | None, aliases=(),
           parent: str | None = None, documents: list[dict] = (), note: str | None = None) -> dict:
    sys.path.insert(0, str(ROOT))
    from app import study_catalog as sc
    reg_src = "studienangebot" if regular else "regel"
    if not regular:
        regular = 6 if degree.startswith("B") else (4 if degree.startswith("M") else None)
    if not faculty:
        # Lehramt und Zwei-Faecher-Bachelor gehoeren keinem Fachbereich allein; sonst nach dem Namen
        if re.search(r"Lehramt|Zwei-Fächer", program):
            faculty = "fachbereichsübergreifend (Lehrerbildung)"
        elif re.search(r"Psycholog|Pädagog|Erziehung", program):
            faculty = FACULTIES["1"]
        elif re.search(r"Kultur|Künste|Literar|Philosoph", program):
            faculty = FACULTIES["2"]
    e = {
        "key": f"hildesheim|{sc.slug(program)}|{degree.lower().replace('/', '-')}|{po or 'unbekannt'}",
        "university": "hildesheim", "program": program, "degree": degree, "kind": kind, "faculty": faculty,
        "listed": listed, "po": po, "po_documents": [_doc_ref(r) for r in pos[:3]],
        "catalog": catalog, "more_catalogs": list(more), "study_plan_url": None, "program_page": page,
        "ordnungen_page": qm_study_url(sid) if sid else None, "start_terms": [],
        "regular_semesters": regular if kind != "fach" else (regular or None), "regular_semesters_source": reg_src,
        "total_lp": ((regular or 0) * 30 or None) if kind == "studiengang" else None,
        "qis_labels": qis_labels(program if kind != "fach" else (parent and program.split(" im ")[0]) or program, degree, po,
                                 aliases),
        "qis_labels_source": "geraten",
    }
    if parent:
        e["parent_program"] = parent
    if documents:
        e["documents"] = [_doc_ref(r) for r in documents]
    if note:
        e["note"] = note
    return e


SUBJECT_RE = re.compile(r"Fach\s+(.+?)\s+(?:--\s*)?(?:Polyvalente|in den polyvalenten|Master-Studieng|Masterstudieng|in den Masterstudieng|"
                        r"als Wahlpflicht|im Bachelor|Master- Studieng)", re.I)


def _subject(title: str) -> str | None:
    m = SUBJECT_RE.search(title)
    if m:
        return m.group(1).strip(" -„“")
    return None


def build_register() -> dict:
    NETWORK[0] = False
    docs = list(all_docs().values())
    studies = {st["id"]: st for st in qm_studies()}
    finder = {c["uid"]: c for c in studyfinder()}
    programs: list[dict] = []

    def main_so(sid, so=None):
        if so:
            return next((r for r in docs if r["file_id"] == so), None)
        # neueste geltende Studienordnung mit Datum, die einer der beiden Leser liest
        cands = [r for r in _so_of(docs, sid) if r["kind"] != "Modulhandbuch"]
        cands.sort(key=lambda r: _date_iso(r["date"]) is None)
        for r in cands:
            n = max((parsed(r["file_id"], f) or {}).get("modules", 0)
                    for f in ("hildesheim-modulbeschreibung", "hildesheim-modultabelle"))
            if n >= MIN_MODULES:
                return r
        return cands[0] if cands else None

    for uid, spec in PROGRAMS.items():
        c = finder.get(uid)
        if c is None:
            continue
        name, degs = _split_title(c["title"])
        cat_fb = next((CATEGORY_FB.get(x) for x in c.get("categories") or [] if x in CATEGORY_FB), None)
        regular = c.get("duration") or None
        page = c.get("pageLink") or None
        degs = degs or [DEGREE_OF.get(t, "") for t in c.get("degreeTypes") or []]
        splits = spec.get("split") or [(degs[0] if degs else "", spec.get("study"))]
        for degree, sid in splits:
            own = sid is not None or bool(spec.get("so"))   # eigene Ordnungen im Verkuendungsblatt
            sid = sid if sid is not None else spec.get("po_study")
            pos = _pos_of(docs, sid) if sid else []
            aliases = [_qm_label(studies[a])[0] for a in spec.get("aliases") or [] if a in studies]
            kind = "vertiefung" if spec.get("variant") else "studiengang"
            more = []
            if spec.get("it"):
                fid = spec["it"][0]
                r = next((x for x in docs if x["file_id"] == fid), None)
                deg_for = degree if degree else "B.Sc."
                po = _po_year([r] if r else [], _po_year(pos))
                cat = _catalog_of(r, "hildesheim-it-modulhandbuch", deg_for, spec.get("usage"))
                for f2 in spec["it"][1:]:
                    r2 = next((x for x in docs if x["file_id"] == f2), None)
                    m2 = _catalog_of(r2, "hildesheim-it-modulhandbuch", deg_for, spec.get("usage"))
                    if m2.get("url"):
                        more.append(m2)
                first = r
            else:
                first = main_so(sid, spec.get("so")) if own else None
                cat = _catalog_of(first, "hildesheim-modulbeschreibung", degree or "B.A.")
                po = _po_year(pos)
            text = (parsed(first["file_id"], cat["format"] if cat.get("url") else "hildesheim-modulbeschreibung",
                           degree or "B.A.") or {}).get("first_page") if first else None
            fac = _faculty(text, cat_fb)
            program = name
            if spec.get("split"):
                program = "Polyvalenter Zwei-Fächer-Bachelor-Studiengang"
            e = _entry(program, degree, kind, po=po, pos=pos, catalog=cat, more=more, faculty=fac,
                       listed=True, page=page, sid=sid, regular=regular, aliases=aliases,
                       parent="Polyvalenter Zwei-Fächer-Bachelor-Studiengang" if spec.get("variant") else None,
                       documents=_side_of(docs, sid) if sid and own else [], note=spec.get("note"))
            programs.append(e)
            for label, fid in spec.get("tracks") or []:
                r = next((x for x in docs if x["file_id"] == fid), None)
                tcat = _catalog_of(r, "hildesheim-it-modulhandbuch", degree)
                programs.append(_entry(f"{name} ({label})", degree, "vertiefung", po=po, pos=pos, catalog=tcat,
                                       faculty=fac, listed=True, page=page, sid=sid, regular=regular,
                                       parent=name))

    # Studiengaenge nur im Verkuendungsblatt
    for sid in QM_ONLY:
        st = studies.get(sid)
        if not st:
            continue
        name, degree = _qm_label(st)
        pos = _pos_of(docs, sid)
        first = main_so(sid)
        cat = _catalog_of(first, "hildesheim-modulbeschreibung", degree)
        text = (parsed(first["file_id"], "hildesheim-modulbeschreibung", degree) or {}).get("first_page") if first else None
        programs.append(_entry(name, degree, "studiengang", po=_po_year(pos), pos=pos, catalog=cat,
                               faculty=_faculty(text), listed=False, page=None, sid=sid, regular=None,
                               documents=_side_of(docs, sid)))

    # Faecher im Polyvalenten Zwei-Faecher-Bachelor (25 B.A., 26 B.Sc.) und im Master Lehramt (49 GS, 50 HRS)
    parents = {25: "Polyvalenter Zwei-Fächer-Bachelor-Studiengang", 26: "Polyvalenter Zwei-Fächer-Bachelor-Studiengang",
               49: "Master Lehramt an Grundschulen", 50: "Master Lehramt an Haupt- und Realschulen"}
    used_variants = {spec["so"] for spec in PROGRAMS.values() if spec.get("variant") or spec.get("umbrella")}
    seen_keys = {e["key"] for e in programs}
    for r in sorted(docs, key=_sort_key, reverse=True):
        if not is_catalog_doc(r) or r["kind"] == "Modulhandbuch" or r["file_id"] in used_variants:
            continue
        sids = [x["id"] for x in r["studies"] if x["id"] in parents]
        if not sids:
            continue
        subj = _subject(r["title"])
        if not subj:
            continue
        info = parsed(r["file_id"], "hildesheim-modulbeschreibung")
        if not info or info["modules"] < 2:
            continue
        year = (_date_iso(r["date"]) or "0000")[:4]
        bachelor = [s2 for s2 in sids if s2 in (25, 26)]
        groups = []
        if bachelor:
            deg = "B.A./B.Sc." if len(bachelor) == 2 else ("B.A." if bachelor == [25] else "B.Sc.")
            groups.append((f"{subj} im Polyvalenten Zwei-Fächer-Bachelor", deg, bachelor[0], parents[25]))
        for s2 in sids:
            if s2 in (49, 50):
                groups.append((f"{subj} im {parents[s2]}", "M.Ed.", s2, parents[s2]))
        for program, deg, s2, parent in groups:
            pos = _pos_of(docs, s2)
            cat = _catalog_of(r, "hildesheim-modulbeschreibung", deg)
            e = _entry(program, deg, "fach", po=year, pos=pos, catalog=cat, faculty=FACULTIES.get(SUBJECT_FB.get(subj, ""))
                       or _faculty(info["first_page"]), listed=True, page=None, sid=s2, regular=None, parent=parent)
            e["qis_labels"] = qis_labels(subj, deg, _po_year(pos), [])
            if e["key"] in seen_keys:
                continue
            seen_keys.add(e["key"])
            programs.append(e)

    programs.sort(key=lambda e: ({"studiengang": 0, "vertiefung": 1, "fach": 2}[e["kind"]], e["key"]))
    return {
        "v": 1, "university": "hildesheim", "generated": "2026-11-05", "generator": "tools/hildesheim-programs.py",
        "note": "Verbindlich ist immer die Pruefungsordnung der Hochschule (Verkuendungsblatt). Quellen: Studienangebot "
                "(Studienfinder) und elektronisches Verkuendungsblatt (uniQuIS, nur oeffentliche Seiten). Modulbeschreibungen "
                "stehen in Hildesheim meist als Anlage in der Studienordnung; die IT-Studiengaenge des Fachbereichs 4 haben "
                "eigene Modulhandbuecher. qis_labels sind geraten (LSF-Zeile 'Abschluss: ... Studiengang: ... PO-Version: ...').",
        "sources": {"studienangebot": STUDYFINDER, "verkuendungsblatt": QM_STUDIES,
                    "download_pattern": QM + "download.php?fileID=<ID>"},
        "formats": {
            "hildesheim-modulbeschreibung": "Modulbeschreibungen in der Studienordnung (Anlage Modulhandbuch): Titelzeile, "
                                            "Modulnummer, ModulleiterIn, Kompetenz- und Lernziele, Pflicht- oder Wahlpflichtmodul, "
                                            "Anzahl der Leistungspunkte, Workload, Haeufigkeit des Angebots, Empfohlenes "
                                            "Studiensemester, Pruefungs- und Studienleistungen",
            "hildesheim-it-modulhandbuch": "Modulhandbuch des Fachbereichs 4 (Datenbank-Ausgabe, auch englisch): Verzeichnis je "
                                           "Bereich, je Modul 'Modul:' mit Leistungspunkte, empfohlenes Semester (BSc/MSc), "
                                           "Turnus, Pruefungsleistung, Verwendung",
            "hildesheim-modultabelle": "Modulbeschreibungen der Fachbereiche 2 und 3 und der Erziehungswissenschaft als "
                                       "zweispaltige Tabelle (Layout-Modus): Kennzeichnung, Workload 'x SWS / y LP', "
                                       "Leistungsnachweise Studium/Pruefung, Praesenz des Moduls im Studienangebot; FB 3 "
                                       "mit Kopfzeile Studiensemester | Dauer | Haeufigkeit | Status",
            "none": "keine Modulbeschreibungen im Verkuendungsblatt gefunden bzw. lesbar"},
        "programs": programs,
    }


def write_register(reg: dict) -> bytes:
    return (json.dumps(reg, ensure_ascii=False, indent=1) + "\n").encode("utf-8")


def step_pos() -> list[dict]:
    """Geltende Pruefungsordnungen laden (Wahlbereiche, Leistungspunkte, Studienverlaufsplaene in den Anlagen)"""
    out = []
    docs = list(all_docs().values())
    for st in qm_studies():
        for r in _pos_of(docs, st["id"])[:2]:
            if r not in out:
                fetch(download_url(r["file_id"]))
                out.append(r)
    return out


def pipeline(cmd: str) -> int:
    if cmd == "regs":
        studies = step_regs()
        for st in studies:
            rows = qm_rows(st["id"])
            print(st["id"], st["label"], len(rows))
        return 0
    if cmd == "pdfs":
        step_regs()
        print(len(step_pdfs()), "Dokumente")
        return 0
    if cmd == "pos":
        step_regs()
        print(len(step_pos()), "Pruefungsordnungen")
        return 0
    if cmd in ("all", "build", "check"):
        if cmd == "all":
            fetch(STUDYFINDER)
            step_regs()
            step_pdfs()
            step_pos()
        before = idx()["requests"]
        data = write_register(build_register())
        assert idx()["requests"] == before, "build darf nichts laden"
        if cmd == "check":
            if not OUT_JSON.exists() or OUT_JSON.read_bytes() != data:
                print(f"Register veraltet: {OUT_JSON.name} (tools/hildesheim-programs.py build ausfuehren)")
                return 1
            print(f"Register aktuell ({len(json.loads(data)['programs'])} Eintraege, 0 Anfragen)")
            return 0
        OUT_JSON.write_bytes(data)
        reg = json.loads(data)
        n = len(reg["programs"])
        with_cat = sum(1 for e in reg["programs"] if (e["catalog"] or {}).get("url"))
        with_po = sum(1 for e in reg["programs"] if e["po_documents"])
        print(f"{n} Eintraege, {with_po} mit Pruefungsordnung, {with_cat} mit Modulbeschreibungen -> {OUT_JSON}")
        print(f"Anfragen insgesamt: {idx()['requests']}")
        return 0
    raise SystemExit(f"unbekannt: {cmd}")


if __name__ == "__main__":
    sys.exit(main(sys.argv))

"""Register aller Studiengaenge der Hochschule Hannover (HsH) mit Modulhandbuechern und Pruefungsordnungen:
packages/shared-contracts/study-sources-hsh.json (Auftrag des Inhabers 05.11.2026 "Hochschule Hannover einbinden" und
"die gleiche Bibliothek wie fuer die LUH", Berichte docs/HSH-2026-11-05.md und docs/STUDIENGAENGE-HSH-2026-11-05.md;
Vorbild tools/luh-programs.py und tools/hildesheim-programs.py).

Hoeflich gegenueber den Servern der Hochschule:
- nur oeffentliche Seiten und PDFs von www.hs-hannover.de und den Fakultaetsseiten f1..f5.hs-hannover.de; nie Moodle,
  Campusmanagement (HISinOne), Accountmanager, Intranet, service.it oder Anmeldeseiten (Links darauf werden verworfen,
  bevor irgendetwas geholt wird);
- robots.txt wird vor der ersten Anfrage je Rechner gelesen und beachtet (RFC 9309, `Robots`);
- hoechstens eine Anfrage je 2,5 Sekunden, nacheinander, User-Agent "StudiNow-Katalogpruefung/1.0
  (support@studinow.app)";
- jede Antwort liegt im Zwischenspeicher ~/Studora-Builds/hsh/crawl/ (cache/ + index.json), dieselbe URL wird nie
  zweimal geholt (auch nicht nach einem Fehler); ein zweiter Lauf arbeitet nur aus dem Zwischenspeicher;
- Obergrenze 190 Anfragen insgesamt (Zaehler in index.json, ueber alle Laeufe). Modulhandbuecher, Ordnungen und
  Verlaufsplaene holt tools/hsh-catalogs.py (eigener Zwischenspeicher ~/Studora-Builds/hsh-catalog, Obergrenze 1500
  mit diesem Lauf zusammen); `attach_catalogs` liest daraus je Studiengang alle Handbuecher mit Bauart
  (app/catalog_formats/hsh.py), PO-Version, Semester und Vertiefung, `build` macht daraus einen Eintrag je
  Studiengang, PO und Vertiefung (aeltere POs: status "auslaufend"). Den Grundstock baut tools/build-hsh-seed.py.
Heruntergeladene Seiten und PDFs bleiben im Zwischenspeicher, nie im Repo.

Aufruf im Projektordner:
  .venv/bin/python tools/hsh-programs.py all       # holen (nur was fehlt) und Register schreiben
  .venv/bin/python tools/hsh-programs.py build     # nur aus dem Zwischenspeicher (0 Anfragen) schreiben
  .venv/bin/python tools/hsh-programs.py check     # Register frisch aus dem Zwischenspeicher bauen und vergleichen
Werkzeuge zum Nachsehen: fetch URL, links URL [Muster], text URL [Seiten], count.

Die reinen Lesefunktionen (`parse_az`, `handbook_links`, `qis_labels`, `degree_short`) prueft
tests/test_hsh.py mit nachgebauten Ausschnitten (ohne Netz).
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
from html.parser import HTMLParser
from pathlib import Path

UA = "StudiNow-Katalogpruefung/1.0 (support@studinow.app)"
CRAWL = Path(os.environ.get("HSH_CRAWL") or os.path.expanduser("~/Studora-Builds/hsh/crawl"))
CACHE = CRAWL / "cache"
INDEX = CRAWL / "index.json"
MAX_REQUESTS = 190
DELAY = 2.5
ROOT = Path(__file__).resolve().parent.parent
OUT_JSON = ROOT / "packages/shared-contracts/study-sources-hsh.json"

AZ_URL = "https://www.hs-hannover.de/studium/studienangebot/studiengaenge-a-z"
ALLOWED_HOST = re.compile(r"^(www|f[1-5])\.hs-hannover\.de$")
# nie anfassen: Anmeldung, Portale mit Login (auch wenn eine Seite darauf verlinkt)
FORBIDDEN_PATH = re.compile(r"(/login|shibboleth|/saml|/sso|/auth/|typo3/|/admin|^/intranet|^/qisserver|^/moodle|"
                            r"/webmail|^/accounts)", re.I)

FACULTIES = {
    "f1": "Fakultät I – Elektro- und Informationstechnik",
    "f2": "Fakultät II – Maschinenbau und Bioverfahrenstechnik",
    "f3": "Fakultät III – Medien, Information und Design",
    "f4": "Fakultät IV – Wirtschaft und Informatik",
    "f5": "Fakultät V – Diakonie, Gesundheit und Soziales",
}


class Budget(Exception):
    pass


# ---------------------------------------------------------------------------------------------------------------
# Zwischenspeicher und hoefliches Holen (wie tools/hildesheim-programs.py)
# ---------------------------------------------------------------------------------------------------------------

_IDX: dict | None = None
_ROBOTS: dict[str, "Robots | None"] = {}
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


def allowed(url: str) -> bool:
    p = urllib.parse.urlsplit(url)
    return p.scheme == "https" and bool(ALLOWED_HOST.match(p.netloc)) and not FORBIDDEN_PATH.search(p.path)


def _raw_get(url: str, data: bytes | None = None) -> tuple[int, str, bytes, str]:
    ix = idx()
    if ix["requests"] >= MAX_REQUESTS:
        raise Budget(f"Obergrenze {MAX_REQUESTS} Anfragen erreicht")
    wait = _LAST[0] + DELAY - time.time()
    if ix["log"]:
        wait = max(wait, ix["log"][-1]["t"] + DELAY - time.time())
    if wait > 0:
        time.sleep(wait)
    req = urllib.request.Request(url, data=data, headers={"User-Agent": UA, "Accept-Language": "de,en;q=0.5",
                                                           **({"Content-Type": "application/x-www-form-urlencoded"} if data else {})})
    ix["requests"] += 1
    t0 = time.time()
    _LAST[0] = t0
    try:
        with urllib.request.urlopen(req, timeout=60) as r:  # noqa: S310 - nur erlaubte Rechner (allowed)
            status, ctype, body, final = r.status, r.headers.get("Content-Type", ""), r.read(), r.geturl()
    except urllib.error.HTTPError as e:
        status, ctype, body, final = e.code, e.headers.get("Content-Type", "") if e.headers else "", b"", url
    except Exception as e:  # noqa: BLE001  Netz, Zeitueberschreitung
        status, ctype, body, final = -1, "", str(e).encode(), url
    ix["log"].append({"t": t0, "url": url, "status": status, "bytes": len(body)})
    save_index()
    print(f"  [{ix['requests']:3d}] {status} {url}", file=sys.stderr)
    return status, ctype, body, final


class Robots:
    """robots.txt nach RFC 9309 (laengste passende Regel gewinnt, Allow bei Gleichstand, * und $): die HsH erlaubt
    ihre Unter-Sitemaps ausdruecklich mit 'Allow: /*sitemap=' gegen 'Disallow: /*cHash'; urllib.robotparser nimmt
    die erste passende Regel und wuerde sie sperren."""

    def __init__(self, text: str, agent: str = UA):
        groups: list[tuple[list[str], list[tuple[bool, str]]]] = []
        agents: list[str] = []
        rules: list[tuple[bool, str]] = []
        for raw in text.splitlines():
            line = raw.split("#", 1)[0].strip()
            if ":" not in line:
                continue
            k, v = (x.strip() for x in line.split(":", 1))
            k = k.lower()
            if k == "user-agent":
                if rules:
                    groups.append((agents, rules))
                    agents, rules = [], []
                agents.append(v.lower())
            elif k in ("allow", "disallow") and agents:
                if v:
                    rules.append((k == "allow", v))
        if agents:
            groups.append((agents, rules))
        token = agent.split("/")[0].lower()
        mine = [r for a, r in groups if token in a]
        self.rules = mine[0] if mine else next((r for a, r in groups if "*" in a), [])

    @staticmethod
    def _match(pattern: str, path: str) -> bool:
        rx = "^" + "".join(".*" if c == "*" else ("$" if c == "$" and i == len(pattern) - 1 else re.escape(c))
                           for i, c in enumerate(pattern))
        return re.match(rx, path) is not None

    def allowed(self, url: str) -> bool:
        p = urllib.parse.urlsplit(url)
        path = (p.path or "/") + (f"?{p.query}" if p.query else "")
        best: tuple[int, bool] | None = None
        for allow, pat in self.rules:
            if self._match(pat, path):
                cand = (len(pat), allow)
                if best is None or cand[0] > best[0] or (cand[0] == best[0] and allow):
                    best = cand
        return True if best is None else best[1]


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
        _ROBOTS[host] = Robots(info["text"]) if info["status"] == 200 else None
    rp = _ROBOTS[host]
    return True if rp is None else rp.allowed(url)


def fetch(url: str, form: dict | None = None) -> dict | None:
    """{status, ctype, path, final} aus dem Zwischenspeicher oder einmal geholt; None = nicht erlaubt/kein Netz.
    `form`: oeffentliches Suchformular (POST, z. B. weitere Seiten des Studienangebots), Schluessel mit Formularwerten"""
    url = norm_url(url)
    data = urllib.parse.urlencode(form).encode() if form else None
    key = f"POST {url} {data.decode()}" if data else url
    ix = idx()
    if key in ix["urls"]:
        return ix["urls"][key]
    if not NETWORK[0] or not allowed(url):
        return None
    if not robots_ok(url):
        ix["urls"][key] = {"status": "robots", "ctype": "", "path": None, "final": url}
        save_index()
        return ix["urls"][key]
    status, ctype, body, final = _raw_get(url, data)
    path = None
    if status == 200:
        ext = ".pdf" if (b"%PDF" in body[:1024] or "pdf" in ctype) else ".html"
        name = hashlib.sha1(key.encode()).hexdigest()[:16] + ext
        (CACHE / name).write_bytes(body)
        path = "cache/" + name
    entry = {"status": status, "ctype": ctype, "path": path, "final": norm_url(final), "size": len(body),
             "sha256": hashlib.sha256(body).hexdigest() if status == 200 else None}
    ix["urls"][key] = entry
    save_index()
    return entry


def cached_path(url: str, form: dict | None = None) -> Path | None:
    e = fetch(url, form)
    if not e or not e.get("path"):
        return None
    p = CRAWL / e["path"]
    return p if p.exists() else None


def read_text(url: str, form: dict | None = None) -> str | None:
    p = cached_path(url, form)
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


def page_links(text: str, base: str) -> list[tuple[str, str]]:
    p = _Links(base)
    p.feed(text)
    return p.links


def links(url: str) -> list[tuple[str, str]]:
    txt = read_text(url)
    return page_links(txt, fetch(url)["final"]) if txt is not None else []


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


# ---------------------------------------------------------------------------------------------------------------
# Reine Lesefunktionen (ohne Netz, getestet)
# ---------------------------------------------------------------------------------------------------------------

_HEADING_RE = re.compile(r'<h2 class="list__heading">(.*?)</h2>(.*?)(?=<h2 class="list__heading">|\Z)', re.S)
_ITEM_RE = re.compile(r"<li>\s*<b>(.*?)</b>\s*<div[^>]*>(.*?)</div>\s*</li>", re.S)
_DETAILS_RE = re.compile(r'<a class="btn[^"]*" href="([^"]+)">\s*<span class="btn__title">\s*Details zum Studiengang', re.S)
_ABBR_RE = re.compile(r"\(([A-Z][A-Za-z]{1,5})\)\s*$")
DEGREES = (
    ("Bachelor of Engineering", "B.Eng."), ("Bachelor of Science", "B.Sc."), ("Bachelor of Arts", "B.A."),
    ("Master of Engineering", "M.Eng."), ("Master of Science", "M.Sc."), ("Master of Arts", "M.A."),
    ("Bachelor of Laws", "LL.B."), ("Master of Business Administration", "MBA"), ("Bachelor", "Bachelor"),
    ("Master", "Master"),
)


def _cell(s: str) -> str:
    s = re.sub(r"<br\s*/?>", "\n", s)
    return "\n".join(" ".join(html.unescape(re.sub(r"(?s)<[^>]+>", " ", line)).replace("­", "").split())
                     for line in s.split("\n")).strip()


def degree_short(text: str) -> str:
    """'Bachelor of Science (B.Sc.)' -> 'B.Sc.'; unbekannt -> der Text selbst"""
    m = re.search(r"\(([^)]+)\)", text or "")
    if m and re.search(r"[A-Z]", m.group(1)):
        return re.sub(r"\.\s+", ".", m.group(1).strip())
    for long, short in DEGREES:
        if (text or "").startswith(long):
            return short
    return (text or "").strip() or "unbekannt"


def _semesters(text: str) -> int | None:
    m = re.search(r"(\d{1,2})", text or "")
    return int(m.group(1)) if m else None


def parse_az(page: str) -> list[dict]:
    """Studienangebot A-Z (www.hs-hannover.de/studium/studienangebot/studiengaenge-a-z): je Studiengang Name, Kuerzel,
    Abschluss, Regelstudienzeit, Studienbeginn, Studienform, Vertiefungen und die Seite "Details zum Studiengang"."""
    out = []
    for m in _HEADING_RE.finditer(page):
        title = _cell(m.group(1))
        body = m.group(2)
        fields = {_cell(k): _cell(v) for k, v in _ITEM_RE.findall(body)}
        det = _DETAILS_RE.search(body)
        page_url = html.unescape(det.group(1)) if det else None
        if page_url and page_url.startswith("/"):
            page_url = "https://www.hs-hannover.de" + page_url
        abbr = _ABBR_RE.search(title)
        host = urllib.parse.urlsplit(page_url or "").netloc
        fac = host.split(".")[0] if host.startswith("f") else None
        # Eintrag "Abteilung Religionspaedagogik und Soziale Arbeit" (so im A-Z) ist der Studiengang BRS
        name = re.sub(r"^Abteilung\s+", "", _ABBR_RE.sub("", title).strip())
        out.append({
            "title": title,
            "program": name,
            "abbr": abbr.group(1) if abbr else None,
            "degree_long": fields.get("Abschluss", ""),
            "degree": degree_short(fields.get("Abschluss", "")),
            "start_terms": [t for t in ("Wintersemester", "Sommersemester") if t[:6] in fields.get("Studienbeginn", "")]
                           or (["Wintersemester", "Sommersemester"] if "Sommer- und Winter" in fields.get("Studienbeginn", "") else []),
            "study_form": fields.get("Studienform") or None,
            "regular_semesters": _semesters(fields.get("Regelstudienzeit", "")),
            "focus": [x for x in (fields.get("Vertiefungen / Studienschwerpunkte") or "").split("\n") if x and x.lower() != "nein"],
            "program_page": page_url,
            "faculty_key": fac,
        })
    return out


HANDBOOK_RE = re.compile(r"modul(handbuch|handbuecher|verzeichnis|katalog|beschreibung|uebersicht)|/modules?-|module[_ -]?handbook|"
                         r"modulhandb", re.I)
PO_DOC_RE = re.compile(r"pr(ue|ü)fungsordnung|/ordnungen/|[_-]po[_-]|btpo|atpo|studienordnung", re.I)
PLAN_RE = re.compile(r"studienverlauf|musterstudienplan|studienplan", re.I)
ARCHIVE_RE = re.compile(r"/archiv/|archiv", re.I)


_PAGES_RE = re.compile(r'<custom-pagination pages="(\d+)"')


def az_page_count(page: str) -> int:
    """Seitenzahl des Studienangebots A-Z (25 Eintraege je Seite, weitere Seiten mit ?page=N)"""
    m = _PAGES_RE.search(page)
    return max(1, min(int(m.group(1)), 10)) if m else 1


_LOC_RE = re.compile(r"<loc>\s*([^<\s]+)\s*</loc>")
PROGRAM_PATH_RE = re.compile(r"^/studium/(?:studiengaenge-und-programme/)?(bachelor|master|duale)[a-z-]*/([a-z0-9-]+)/?$")


def sitemap_locs(xml: str) -> list[str]:
    return [html.unescape(u) for u in _LOC_RE.findall(xml or "")]


def program_pages_from_sitemap(urls: list[str]) -> list[str]:
    """Studiengangsseiten einer Fakultaets-Sitemap (/studium/bachelor-studiengaenge/<name>, auch duale/master)"""
    out = []
    for u in urls:
        p = urllib.parse.urlsplit(u)
        if ALLOWED_HOST.match(p.netloc) and PROGRAM_PATH_RE.match(p.path) and norm_url(u) not in out:
            out.append(norm_url(u))
    return out


_RS_RE = re.compile(r"Regelstudienzeit\D{0,30}?(\d{1,2})\s*(?:Semester|Fachsemester)")
_H1_RE = re.compile(r"<h1[^>]*>(.*?)</h1>", re.S)
_DEGREE_TEXT_RE = re.compile(r"(Bachelor|Master) of (Science|Arts|Engineering|Laws|Business Administration)(?:\s*\(([^)]{2,8})\))?")


def program_from_page(page: str, url: str) -> dict | None:
    """Studiengang aus seiner eigenen Seite (fuer Eintraege, die nur in der Sitemap stehen): Titel (h1), Abschluss aus
    dem Text, Bachelor/Master aus dem Pfad"""
    m = _H1_RE.search(page or "")
    if not m:
        return None
    title = _cell(m.group(1)).replace("\n", " ")
    path = urllib.parse.urlsplit(url).path
    kind = PROGRAM_PATH_RE.match(path)
    d = _DEGREE_TEXT_RE.search(html_text(page or ""))
    if d:
        long = f"{d.group(1)} of {d.group(2)}"
        degree = re.sub(r"\.\s+", ".", d.group(3)) if d.group(3) else degree_short(long)
    else:
        long = "Bachelor" if kind and kind.group(1) == "bachelor" else ("Master" if kind and kind.group(1) == "master" else "")
        degree = long or "unbekannt"
    abbr = _ABBR_RE.search(title)
    host = urllib.parse.urlsplit(url).netloc
    return {"title": title, "program": re.sub(r"^Abteilung\s+", "", _ABBR_RE.sub("", title).strip()),
            "abbr": abbr.group(1) if abbr else (path.rstrip("/").rsplit("-", 1)[-1].upper() if re.search(r"-[a-z]{2,4}$", path.rstrip("/")) else None),
            "degree_long": long, "degree": degree, "start_terms": [], "study_form": None,
            "regular_semesters": _semesters(rs.group(1)) if (rs := _RS_RE.search(html_text(page or ""))) else None,
            "focus": [], "program_page": url, "faculty_key": host.split(".")[0], "from": "sitemap"}


_AJAX_RE = re.compile(r'<custom-ajax-form[^>]*action="([^"]+)"')


def az_ajax_url(page: str) -> str | None:
    """Adresse des Suchformulars (weitere Seiten kommen per POST mit page=N, wie im Browser)"""
    m = _AJAX_RE.search(page)
    return urllib.parse.urljoin(AZ_URL, html.unescape(m.group(1))) if m else None


def handbook_links(page_links_: list[tuple[str, str]], abbr: str | None = None) -> dict:
    """Links einer Studiengangsseite: Modulhandbuecher (aktuell zuerst, Archiv getrennt), Ordnungen, Verlaufsplaene.
    Nur PDFs auf www/fN.hs-hannover.de. Mit Kuerzel ('BIN') werden Handbuecher bevorzugt, die es im Namen tragen."""
    seen: set[str] = set()
    hb, old, po, plans = [], [], [], []
    for href, text in page_links_:
        u = norm_url(href)
        if u in seen or not u.lower().endswith(".pdf") or not allowed(u):
            continue
        seen.add(u)
        name = urllib.parse.unquote(u.rsplit("/", 1)[-1])
        label = text or name
        item = {"url": u, "label": label[:160]}
        hay = f"{u} {text}"
        if HANDBOOK_RE.search(hay):
            (old if ARCHIVE_RE.search(u) else hb).append(item)
        elif PLAN_RE.search(hay):
            plans.append(item)
        elif PO_DOC_RE.search(hay):
            po.append(item)
    if abbr:
        key = re.compile(rf"(^|[^A-Za-z]){re.escape(abbr)}([^A-Za-z]|$)")
        hb.sort(key=lambda x: 0 if key.search(x["url"].rsplit("/", 1)[-1]) else 1)
    # deutsche Fassung vor englischer (gleicher Name mit -DE/-EN)
    hb.sort(key=lambda x: 1 if re.search(r"[-_]EN\.pdf$|_eng?[_.]", x["url"], re.I) else 0)
    return {"handbooks": hb, "archive": old, "po_documents": po, "study_plans": plans}


def qis_labels(program: str, degree: str, abbr: str | None) -> list[str]:
    """Namen, unter denen HISinOne den Studiengang im Notenspiegel fuehren koennte (unbestaetigt, siehe
    docs/HSH-2026-11-05.md): Name, Name mit Abschluss, Kuerzel"""
    out = [program, f"{program} ({degree})", f"{degree.split('.')[0].replace('B', 'Bachelor').replace('M', 'Master')} {program}"]
    if abbr:
        out.append(f"{program} ({abbr})")
    seen, res = set(), []
    for x in out:
        if x and x not in seen:
            seen.add(x)
            res.append(x)
    return res


def slug(text: str) -> str:
    t = text.lower()
    for a, b in (("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss")):
        t = t.replace(a, b)
    return "-".join(re.findall(r"[a-z0-9]+", t))


def classify_pdf(text: str, pages: int) -> dict:
    """Grobe Formatbeschreibung eines Modulhandbuchs (Stichprobe): Textebene ja/nein und erkannte Feldnamen"""
    chars = len(text.strip())
    if pages and chars / max(pages, 1) < 80:
        return {"format": "scanned", "pages": pages, "fields": []}
    fields = [f for f in ("Modulverantwortliche", "Leistungspunkte", "Credits", "ECTS", "Prüfungsform", "Prüfungsleistung",
                          "Studienleistung", "Semesterlage", "Turnus", "Häufigkeit", "Arbeitsaufwand", "Workload",
                          "Lernziele", "Kompetenzen", "Inhalte", "Voraussetzungen", "Modulnummer", "Kennnummer")
              if f.lower() in text.lower()]
    return {"format": "hsh-unbekannt", "pages": pages, "fields": fields}


# ---------------------------------------------------------------------------------------------------------------
# Modulhandbuecher je Studiengang, PO-Version und Vertiefung (Lauf tools/hsh-catalogs.py, ~/Studora-Builds/hsh-catalog)
# ---------------------------------------------------------------------------------------------------------------

_PO_RES = (
    re.compile(r"PO[\s_-]*(?:Version[\s_-]*)?(?:(?:WS|SS|WiSe|SoSe)[\s_-]*)?(20[0-3]\d)(?![0-9])", re.I),
    re.compile(r"PO[\s_-]*(?:Version[\s_-]*)?([0-3]\d)[\s_-]*(?:WS|SS)\b", re.I),
    re.compile(r"[-_ ]([0-3]\d)(?:WS|SS)[-_ .]"),
    re.compile(r"(?:Prüfungsordnung|PO)\s*(?:\(|vom\s|von\s)?\s*(?:\d{1,2}\.\d{1,2}\.)?(20[0-3]\d)", re.I),
    re.compile(r"[-_ ](?:WS|SS|WiSe|SoSe)[-_ ]?(20[0-3]\d)(?![0-9])", re.I),
    re.compile(r"ab[-_ ](?:WiSe|WS|SoSe|SS)[-_ ]?([0-3]\d)[-_/]", re.I),
)
_LANG_EN_RE = re.compile(r"[-_]EN\.pdf$|[-_]eng?(?:lish)?[-_.]|english|course[ _]catalogue", re.I)
VARIANT_RE = re.compile(r"(?:Vertiefung|Studienrichtung|Schwerpunkt|Profil|Richtung)\s*:?\s*([A-ZÄÖÜ][\wäöüß\-]*(?:\s+[\wäöüß\-]+){0,5})", re.I)


def po_of(*texts: str) -> str | None:
    """PO-Version aus Dateiname, Linktext oder erster Seite: 'PO Version 19 WS' -> '2019', 'PO-2021' -> '2021',
    'MAB-AM-WS2016' -> '2016', 'ab_WiSe_22_23' -> '2022'; None = unbekannt"""
    for t in texts:
        t = urllib.parse.unquote(t or "")
        for rx in _PO_RES:
            m = rx.search(t)
            if m:
                y = int(m.group(1))
                y = y + 2000 if y < 100 else y
                if 2000 <= y <= 2030:
                    return str(y)
    return None


def variant_of(url: str, label: str, abbr: str | None) -> str | None:
    """Vertiefung/Studienrichtung eines Handbuchs: 'Vertiefung ADT' (Linktext) oder 'MAB-AM-...' (Dateiname)"""
    m = VARIANT_RE.search(label or "")
    if m:
        return m.group(1).strip()[:40]
    name = urllib.parse.unquote(url.rsplit("/", 1)[-1])
    if abbr:
        m = re.search(rf"(?:^|[^A-Za-z]){re.escape(abbr)}[-_]([A-Z]{{2,3}})[-_]", name)
        if m and m.group(1) not in ("WS", "SS", "PO", "DE", "EN", "MH", "BA", "MA"):
            return m.group(1)
    m = re.match(r"^\d{2}_([A-Z]{3})_(?:WS|SS)\d{4}", name)        # Fakultaet I: 67_ADT_WS2025_...
    return m.group(1) if m else None


def is_english(url: str, label: str) -> bool:
    return bool(_LANG_EN_RE.search(url) or _LANG_EN_RE.search(label or ""))


def _catalog_tools():
    import importlib.util as ilu
    spec = ilu.spec_from_file_location("hsh_catalogs", ROOT / "tools" / "hsh-catalogs.py")
    mod = ilu.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    mod.NETWORK[0] = False
    return mod


def attach_catalogs(progs: list[dict]) -> None:
    """Je Studiengang alle Modulhandbuecher (eigene Seite und Unterseiten, Ordnungsseiten der Fakultaet mit dem Kuerzel
    im Dateinamen) mit Bauart (app/catalog_formats/hsh.py), PO-Version, Katalogsemester, Vertiefung und Sprache.
    Nur aus den Zwischenspeichern (0 Anfragen); was der Katalog-Lauf nicht geholt hat, bleibt Link."""
    sys.path.insert(0, str(ROOT))
    from app.catalog_formats import hsh as reader
    from app.catalog_formats.formats_a_common import term_of_catalog
    cat = _catalog_tools()
    docs = [d for d in cat.documents().get("documents", []) if d.get("kind") in ("handbook", "plan")]
    all_abbrs = {p["abbr"] for p in progs if p.get("abbr")}
    for p in progs:
        page = (p.get("program_page") or "").rstrip("/")
        abbr = p.get("abbr")
        # Kuerzel im Dateinamen, auch mit vorangestelltem B/M ("Modulhandbuch_BSKE_PO_2022.pdf" fuer SKE)
        key_rx = re.compile(rf"(?:^|[^A-Za-z])[BM]?{re.escape(abbr)}(?:[^A-Za-z]|$)") if abbr else None
        found: dict[str, dict] = {}
        for h in p.get("handbooks") or []:
            found[h["url"]] = {"url": h["url"], "label": h["label"], "kind": "handbook"}
        for d in docs:
            own = page and any(x.rstrip("/") == page or x.startswith(page + "/") for x in d.get("pages") or [])
            name = urllib.parse.unquote(d["url"].rsplit("/", 1)[-1])
            tokens = set(re.findall(r"[A-Z]{2,5}", name))
            by_abbr = key_rx is not None and bool(key_rx.search(name))
            # Handbuch eines anderen Studiengangs auf der eigenen Seite (Dateiname nennt nur dessen Kuerzel): nicht hier
            if own and not by_abbr and (tokens & all_abbrs) - {abbr}:
                own = False
            by_name = len(slug(p["program"])) >= 12 and slug(p["program"]) in slug(name.replace("_", " "))
            if own or by_abbr or by_name:
                found.setdefault(d["url"], {"url": d["url"], "label": d.get("label") or "", "kind": d["kind"]})
        out = []
        for u, h in found.items():
            e = cat.fetch(u)
            item = {"url": u, "label": (h["label"] or "")[:160], "kind": h["kind"], "format": "none", "po": None,
                    "term": None, "variant": None, "english": is_english(u, h["label"]), "sha256": None, "modules": None,
                    "fetched_at": None}
            if e and e.get("abs") and str(e["abs"]).endswith(".pdf"):
                pages = cat.pdf_pages_cached(e["abs"], e.get("sha256"))
                item["sha256"] = e.get("sha256")
                item["fetched_at"] = e.get("fetched_at")
                first = "\n".join(pages[:2])
                chars = sum(len(x.strip()) for x in pages)
                if h["kind"] == "handbook":
                    fmt = reader.detect(pages) if pages else None
                    item["format"] = fmt or ("scanned" if pages and chars / len(pages) < 80 else "hsh-unbekannt")
                    if fmt:
                        try:
                            parsed, _ = reader.parse(pages, {"university": "hsh", "program": p["program"], "degree": p["degree"],
                                                             "po": "x", "code": "x", "abbr": abbr,
                                                             "source": {"url": u}}, fmt)
                            item["modules"] = len(parsed["modules"])
                        except Exception:  # noqa: BLE001
                            item["modules"] = 0
                        if item["modules"] < 3:
                            item["format"] = "hsh-wenig"
                else:
                    item["format"] = "plan"
                item["po"] = po_of(urllib.parse.unquote(u.rsplit("/", 1)[-1]), h["label"], first[:1500])
                item["term"] = term_of_catalog(None, first[:3000]) or term_of_catalog(None, urllib.parse.unquote(u.rsplit("/", 1)[-1]).replace("_", " "))
            elif e and e.get("status") == "robots":
                item["format"] = "robots"
            item["variant"] = variant_of(u, h["label"], abbr)
            out.append(item)
        out.sort(key=lambda x: x["url"])
        p["catalog_docs"] = out


# ---------------------------------------------------------------------------------------------------------------
# Ablauf
# ---------------------------------------------------------------------------------------------------------------

def collect(network: bool = True) -> dict:
    NETWORK[0] = network
    page = read_text(AZ_URL)
    if page is None:
        raise SystemExit("Studienangebot A-Z nicht im Zwischenspeicher und kein Netz")
    progs = parse_az(page)
    ajax = az_ajax_url(page)
    for n in range(2, az_page_count(page) + 1):
        more = read_text(ajax, {"page": str(n), "sort": "0"}) if ajax else None
        if more:
            progs += parse_az(more)
    # weitere Seiten des A-Z kommen nur per Formular mit cHash (robots.txt sperrt das): Studiengaenge der Fakultaeten
    # stattdessen aus ihren Sitemaps (robots.txt nennt sie ausdruecklich)
    known = {norm_url(p["program_page"]) for p in progs if p["program_page"]}
    for fac in FACULTIES:
        idx_xml = read_text(f"https://{fac}.hs-hannover.de/sitemap.xml") or ""
        locs = sitemap_locs(idx_xml)
        pages_xml = [read_text(u) or "" for u in locs if "sitemap=" in u][:3]
        for url in program_pages_from_sitemap([u for x in pages_xml for u in sitemap_locs(x)]):
            if url in known:
                continue
            txt = read_text(url)
            prog = program_from_page(txt, url) if txt else None
            if prog:
                known.add(url)
                progs.append(prog)
    unique, seen_keys = [], set()
    for p in progs:
        k = (p["title"], p["program_page"])
        if k not in seen_keys:
            seen_keys.add(k)
            unique.append(p)
    # derselbe Studiengang doppelt (A-Z ohne Kuerzel und Sitemap mit Kuerzel): der mit Kuerzel bleibt
    named = {(slug(p["program"]), p["degree"]) for p in unique if p["abbr"]}
    progs = [p for p in unique if p["abbr"] or (slug(p["program"]), p["degree"]) not in named]
    samples: dict[str, dict] = {}
    for p in progs:
        url = p["program_page"]
        found = {"handbooks": [], "archive": [], "po_documents": [], "study_plans": []}
        status = None
        if url and allowed(url):
            e = fetch(url)
            status = e.get("status") if e else None
            txt = read_text(url) if e and e.get("path") else None
            if txt:
                found = handbook_links(page_links(txt, e["final"]), p["abbr"])
        p["page_status"] = status
        p.update(found)
        # Stichprobe: ein Modulhandbuch je Fakultaet, um das Format zu beschreiben
        fac = p["faculty_key"] or "www"
        if found["handbooks"] and fac not in samples:
            hb = found["handbooks"][0]["url"]
            path = cached_path(hb)
            if path and path.suffix == ".pdf":
                try:
                    t, n = pdf_text(path, 12)
                    total = n
                except Exception:  # noqa: BLE001
                    t, total = "", 0
                samples[fac] = {"url": hb, "program": p["title"], **classify_pdf(t, min(total, 12)), "total_pages": total}
    attach_catalogs(progs)
    # derselbe Studiengang auf zwei Fakultaetsseiten (z. B. Mediendesigninformatik bei III und IV): ein Eintrag mit
    # allen Handbuechern (der erste mit Handbuch zuerst)
    merged: dict[tuple, dict] = {}
    out = []
    for p in sorted(progs, key=lambda x: 0 if x.get("catalog_docs") else 1):
        k = (slug(p["program"]), p["degree"], p["abbr"])
        if k in merged:
            have = {d["url"] for d in merged[k]["catalog_docs"]}
            merged[k]["catalog_docs"] += [d for d in p.get("catalog_docs") or [] if d["url"] not in have]
            continue
        merged[k] = p
        out.append(p)
    order = {id(p): i for i, p in enumerate(progs)}
    progs = sorted(out, key=lambda p: order[id(p)])
    return {"programs": progs, "samples": samples}


READABLE = ("hsh-modul-code", "hsh-modul-nummer", "hsh-modultitel", "hsh-code-kopf", "hsh-wpf-tabelle")  # = app.catalog_formats.hsh.FORMATS


def _term_num(t: str | None) -> int:
    m = re.match(r"^(WS|SS) (\d{4})", t or "")
    return int(m.group(2)) * 2 + (1 if m.group(1) == "WS" else 0) if m else 0


_EXTRA_RE = re.compile(r"wahlpflicht|schwerpunktmodul|belegliste", re.I)


def catalog_groups(docs: list[dict]) -> list[dict]:
    """Handbuecher eines Studiengangs -> Gruppen je (PO, Vertiefung): Haupt-Handbuch (lesbar, deutsch, die meisten
    Module, dann neuestes Semester) und weitere lesbare Handbuecher derselben PO, die nur Wahlpflicht beschreiben
    (extra, werden eingemischt); aeltere Fassungen bleiben Link. Handbuecher ohne PO und Vertiefung gehoeren zur
    neuesten PO, wenn es eine gibt."""
    hbs = [d for d in docs if d["kind"] == "handbook"]
    readable = [d for d in hbs if d["format"] in READABLE]
    # englische Fassung nur, wenn es keine deutsche gibt
    if any(not d["english"] for d in readable):
        readable = [d for d in readable if not d["english"]]
    groups: dict[tuple, list[dict]] = {}
    for d in readable:
        groups.setdefault((d["po"], d["variant"]), []).append(d)
    if (None, None) in groups and len(groups) > 1:
        newest = max((k for k in groups if k != (None, None)), key=lambda k: (k[0] or "", k[1] or ""))
        newest_po = newest[0]
        for k in [k for k in groups if k != (None, None) and k[0] == newest_po]:
            groups[k] = groups[k] + [dict(d, _late=True) for d in groups[(None, None)]]
        del groups[(None, None)]
    out = []
    for (po, variant), items in groups.items():
        extra = [d for d in items if _EXTRA_RE.search(d["url"] + " " + d["label"])]
        rest = [d for d in items if d not in extra and not d.get("_late")] or [d for d in items if d not in extra]
        if not rest:
            rest, extra = extra, []
        rest.sort(key=lambda d: (-(d.get("modules") or 0), -_term_num(d["term"]), d["url"]))
        main = rest[0]
        older = [d for d in items if d is not main and d not in extra]
        out.append({"po": po, "variant": variant, "main": {k: v for k, v in main.items() if k != "_late"},
                    "extra": extra, "older": older})
    out.sort(key=lambda g: (g["po"] or "", g["variant"] or ""))
    return out


def build(data: dict) -> dict:
    progs = []
    keys = set()
    for p in data["programs"]:
        base = f"hsh|{slug(p['program'])}|{p['degree'].lower()}"
        if p["abbr"]:
            base += f"|{p['abbr'].lower()}"
        fac = p["faculty_key"]
        hb = p["handbooks"]
        docs = p.get("catalog_docs") or []
        groups = catalog_groups(docs)
        newest_po = max((g["po"] or "" for g in groups), default="")
        common = {
            "university": "hsh", "program": p["program"], "abbr": p["abbr"], "degree": p["degree"],
            "degree_long": p["degree_long"], "faculty": FACULTIES.get(fac or "", None), "faculty_key": fac, "listed": True,
            "po_documents": p["po_documents"][:6], "archive_catalogs": len(p["archive"]),
            "study_plan_url": p["study_plans"][0]["url"] if p["study_plans"] else None,
            "study_plans": [{"url": d["url"], "label": d["label"], "po": d["po"]} for d in docs if d["kind"] == "plan"][:6],
            "program_page": p["program_page"], "page_status": p["page_status"],
            "start_terms": p["start_terms"], "study_form": p["study_form"],
            "regular_semesters": p["regular_semesters"], "regular_semesters_source": "a-z" if p["regular_semesters"] else None,
            "total_lp": (p["regular_semesters"] * 30) if p["regular_semesters"] else None,
            "focus": p["focus"], "qis_labels": qis_labels(p["program"], p["degree"], p["abbr"]),
        }
        if not groups:
            # kein lesbares Handbuch: ein Eintrag mit Link (Format beschreibt, warum)
            first = next((d for d in docs if d["kind"] == "handbook"), None)
            fmt = first["format"] if first else ("hsh-unbekannt" if hb else "none")
            key = base
            while key in keys:
                key += "-2"
            keys.add(key)
            progs.append({"key": key, **common, "kind": "studiengang", "po": first["po"] if first else None,
                          "status": "aktuell",
                          # kein lesbares Handbuch: catalog.url bleibt leer (die App sucht keinen Katalog), der Link
                          # steht in handbook_url ("Link zum Modulhandbuch")
                          "catalog": {"url": None, "term": first["term"] if first else None, "format": fmt},
                          "handbook_url": first["url"] if first else (hb[0]["url"] if hb else None),
                          "more_catalogs": [], "older_catalogs": []})
            continue
        for g in groups:
            m = g["main"]
            key = base + (f"|{g['po']}" if g["po"] else "") + (f"-{slug(g['variant'])}" if g["variant"] else "")
            while key in keys:
                key += "-2"
            keys.add(key)
            progs.append({
                "key": key, **common, "kind": "vertiefung" if g["variant"] else "studiengang",
                "variant": g["variant"], "po": g["po"],
                # aeltere PO-Versionen laufen aus (neueste PO des Studiengangs = aktuell)
                "status": "aktuell" if (g["po"] or "") == newest_po else "auslaufend",
                "catalog": {"url": m["url"], "term": m["term"], "format": m["format"], "label": m["label"],
                            "sha256": m["sha256"], "fetched_at": m["fetched_at"]},
                "more_catalogs": [{"url": d["url"], "label": d["label"], "format": d["format"], "term": d["term"],
                                   "sha256": d["sha256"], "fetched_at": d["fetched_at"]} for d in g["extra"]],
                "older_catalogs": [{"url": d["url"], "term": d["term"]} for d in g["older"]][:6],
            })
    with_hb = sum(1 for p in progs if p["catalog"]["url"] or p.get("handbook_url"))
    readable = sum(1 for p in progs if p["catalog"]["format"] in READABLE)
    formats = {}
    for p in progs:
        formats[p["catalog"]["format"]] = formats.get(p["catalog"]["format"], 0) + 1
    return {
        "v": 1, "university": "hsh", "generated": "2026-11-05", "generator": "tools/hsh-programs.py",
        "note": ("Verbindlich ist immer die Pruefungsordnung der Hochschule. Quellen: Studienangebot A-Z, die Sitemaps und "
                 "Seiten der Fakultaeten (nur oeffentliche Seiten, robots.txt beachtet; das Campusmanagement HISinOne "
                 "sperrt Crawler per robots.txt und wird nie angefragt). Ein Eintrag je Studiengang, PO-Version und "
                 "Vertiefung; lesbare Modulhandbuecher (catalog.format hsh-*) liest tools/build-hsh-seed.py in den "
                 "Grundstock der App, die anderen stehen nur als Link im Register."),
        "sources": {"az": AZ_URL, "faculties": {k: f"https://{k}.hs-hannover.de/" for k in FACULTIES}},
        "formats": {"hsh-modul-code": "Feldtabelle, Modulanfang 'Modul <Kuerzel> <Titel>' (Fakultaet IV, I, Teile II/III)",
                    "hsh-modul-nummer": "Feldtabelle, 'Modul NN – Modulbeschreibung' mit Modultabelle (Fakultaet V)",
                    "hsh-modultitel": "Feldtabelle, Modulanfang mit Feld 'Modultitel'/'Modulbezeichnung' (Word-Tabellen)",
                    "hsh-wpf-tabelle": "Fakultaet II, Wahlpflichtkatalog 'Mod. Nr: NNN' (Werte vor den Feldnamen)",
                    "hsh-unbekannt": "PDF mit Textebene, keine Modulanfaenge erkannt (Bauart ohne Leseprogramm)",
                    "scanned": "PDF ohne Textebene", "robots": "PDF in einem Archivordner (robots.txt sperrt ihn)",
                    "none": "kein Modulhandbuch auf den Seiten des Studiengangs gefunden"},
        "samples": [{"faculty_key": k, **v} for k, v in sorted(data["samples"].items())],
        "counts": {"entries": len(progs), "programs": len({(p["program"], p["degree"], p["abbr"]) for p in progs}),
                   "with_handbook": with_hb, "readable": readable, "without_handbook": len(progs) - with_hb,
                   "with_po_document": sum(1 for p in progs if p["po_documents"]),
                   "auslaufend": sum(1 for p in progs if p.get("status") == "auslaufend"), "formats": formats},
        "programs": progs,
    }


def write(reg: dict) -> None:
    OUT_JSON.write_text(json.dumps(reg, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")


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
        elif cmd in ("all", "build"):
            reg = build(collect(network=cmd == "all"))
            write(reg)
            print(json.dumps(reg["counts"], ensure_ascii=False))
        elif cmd == "check":
            fresh = build(collect(network=False))
            old = json.loads(OUT_JSON.read_text(encoding="utf-8"))
            if fresh != old:
                print("study-sources-hsh.json weicht vom Zwischenspeicher ab", file=sys.stderr)
                return 1
            print("ok")
        else:
            raise SystemExit(f"unbekannt: {cmd}")
    except Budget as b:
        print(f"STOP: {b}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

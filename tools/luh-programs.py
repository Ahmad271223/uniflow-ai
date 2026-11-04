"""Register aller Studiengaenge der Leibniz Universitaet Hannover (LUH) mit Pruefungsordnungen, Modulhandbuechern
und Studienverlaufsplaenen: packages/shared-contracts/study-sources-luh.json (Auftrag des Inhabers 04.11.2026,
docs/STUDIENVERLAUF-2026-11-04.md, Bericht docs/STUDIENGAENGE-LUH-2026-11-04.md).

Hoeflich gegenueber den Servern der Hochschule:
- nur oeffentliche Seiten und PDFs (www.uni-hannover.de, Fakultaetsseiten *.uni-hannover.de, modkat.*), nie
  Anmeldung, nie Stud.IP, QIS, LSF, SSO;
- robots.txt je Host wird beachtet (urllib.robotparser);
- hoechstens eine Anfrage je 2,5 Sekunden, nacheinander, User-Agent "StudiNow-Katalogpruefung/1.0
  (support@studinow.app)";
- jede Antwort liegt im Zwischenspeicher ~/Studora-Builds/luh-crawl/ (cache/ + index.json), dieselbe URL wird nie
  zweimal geholt (auch nicht nach einem Fehler);
- Obergrenze 600 Anfragen insgesamt (Zaehler in index.json, ueber alle Laeufe), danach nur noch Zwischenspeicher.
Heruntergeladene PDFs bleiben im Zwischenspeicher, nie im Repo.

Ablauf (jeder Schritt laeuft erneut ohne neue Anfragen, wenn alles im Zwischenspeicher liegt):
  list      Studienangebot (A-Z) lesen -> Studiengaenge mit Seiten-URL
  pages     jede Studiengangsseite holen, Links zu Ordnungen, Modulhandbuechern, Verlaufsplaenen sammeln
  modkat    FEI-Modulkataloge: Kuerzel und neuestes Semester aus der modkat-Uebersicht
  pdfs      Modulhandbuecher laden (neueste Fassung je Studiengang zuerst, FEI zuletzt), Format bestimmen
  build     study-sources-luh.json und Zahlen fuer den Bericht schreiben
Aufruf im Projektordner: .venv/bin/python tools/luh-programs.py [all|list|pages|modkat|pdfs|build|fetch URL]
Werkzeuge zum Nachsehen: fetch URL (Pfad im Zwischenspeicher), links URL [Muster], text URL (PDF-/HTML-Text).
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

UA = "StudiNow-Katalogpruefung/1.0 (support@studinow.app)"
CRAWL = Path(os.path.expanduser("~/Studora-Builds/luh-crawl"))
CACHE = CRAWL / "cache"
INDEX = CRAWL / "index.json"
STATE = CRAWL / "state"
MAX_REQUESTS = 600
DELAY = 2.5  # Sekunden zwischen zwei Anfragen (Vorgabe: mindestens 2)
ROOT = Path(__file__).resolve().parent.parent
OUT_JSON = ROOT / "packages/shared-contracts/study-sources-luh.json"

ALLOWED_HOST = re.compile(r"^([a-z0-9-]+\.)*uni-hannover\.de$")
# nie anfassen: Anmeldung, Portale mit Login
FORBIDDEN_HOST = re.compile(r"^(studip|qis|lsf|sso|login|idp|ilias|webmail|cloud|seafile|intranet|moodle|ilias3|"
                            r"mein|my|portal|campus|lernraum)[.-]", re.I)
FORBIDDEN_PATH = re.compile(r"(/login|shibboleth|/saml|/sso/|/auth/|typo3/|/admin)", re.I)


class Budget(Exception):
    pass


# ---------------------------------------------------------------------------------------------------------------
# Zwischenspeicher und hoefliches Holen
# ---------------------------------------------------------------------------------------------------------------

def _load_index() -> dict:
    if INDEX.exists():
        return json.loads(INDEX.read_text())
    return {"requests": 0, "urls": {}, "robots": {}, "log": []}


_IDX = None
_ROBOTS: dict[str, urllib.robotparser.RobotFileParser | None] = {}
_LAST = [0.0]


def idx() -> dict:
    global _IDX
    if _IDX is None:
        CACHE.mkdir(parents=True, exist_ok=True)
        _IDX = _load_index()
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
    """Eine echte Anfrage: Wartezeit, Zaehler, Protokoll."""
    ix = idx()
    if ix["requests"] >= MAX_REQUESTS:
        raise Budget(f"Obergrenze {MAX_REQUESTS} Anfragen erreicht")
    wait = _LAST[0] + DELAY - time.time()
    # auch ueber Laeufe hinweg: letzter Zeitpunkt aus dem Index
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
    except Exception as e:  # Netz, Zeitueberschreitung
        status, ctype, body, final = -1, "", str(e).encode(), url
    ix["log"].append({"t": t0, "url": url, "status": status, "bytes": len(body)})
    save_index()
    print(f"  [{ix['requests']:3d}] {status} {url}", file=sys.stderr)
    return status, ctype, body, final


def robots_ok(url: str) -> bool:
    host = urllib.parse.urlsplit(url).netloc
    if host not in _ROBOTS:
        ix = idx()
        rurl = f"https://{host}/robots.txt"
        if rurl not in ix["robots"]:
            status, _, body, _ = _raw_get(rurl)
            ix["robots"][rurl] = {"status": status, "text": body.decode("utf-8", "replace") if status == 200 else ""}
            save_index()
        info = ix["robots"][rurl]
        if info["status"] == 200:
            rp = urllib.robotparser.RobotFileParser()
            rp.parse(info["text"].splitlines())
            _ROBOTS[host] = rp
        else:
            _ROBOTS[host] = None  # keine robots.txt -> erlaubt
    rp = _ROBOTS[host]
    return True if rp is None else rp.can_fetch(UA, url)


def allowed(url: str) -> bool:
    p = urllib.parse.urlsplit(url)
    return p.scheme == "https" and bool(ALLOWED_HOST.match(p.netloc)) and not FORBIDDEN_HOST.match(p.netloc) \
        and not FORBIDDEN_PATH.search(p.path)


def fetch(url: str, *, network: bool = True) -> dict | None:
    """Liefert {status, ctype, path, final} aus dem Zwischenspeicher oder holt einmal. None = nicht erlaubt/kein Netz."""
    url = norm_url(url)
    ix = idx()
    if url in ix["urls"]:
        return ix["urls"][url]
    if not network or not allowed(url):
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
        path = str(CACHE / name)
    entry = {"status": status, "ctype": ctype, "path": path, "final": norm_url(final), "size": len(body),
             "sha256": hashlib.sha256(body).hexdigest() if status == 200 else None}
    ix["urls"][url] = entry
    save_index()
    return entry


def read_text(url: str, network: bool = True) -> str | None:
    e = fetch(url, network=network)
    if not e or not e.get("path"):
        return None
    return Path(e["path"]).read_bytes().decode("utf-8", "replace")


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


def links(url: str, network: bool = True) -> list[tuple[str, str]]:
    txt = read_text(url, network)
    if txt is None:
        return []
    p = _Links(fetch(url, network=False)["final"])
    p.feed(txt)
    return p.links


def pdf_text(path: str, max_pages: int | None = None) -> tuple[str, int]:
    from pypdf import PdfReader
    r = PdfReader(path)
    n = len(r.pages)
    out = []
    for i, pg in enumerate(r.pages):
        if max_pages is not None and i >= max_pages:
            break
        try:
            out.append(pg.extract_text() or "")
        except Exception:
            out.append("")
    return "\f".join(out), n


def html_text(s: str) -> str:
    s = re.sub(r"(?is)<(script|style).*?</\1>", " ", s)
    s = re.sub(r"(?s)<[^>]+>", " ", s)
    return " ".join(html.unescape(s).split())


# ---------------------------------------------------------------------------------------------------------------

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
            e = fetch(argv[2])
            if e and e.get("path", "") and e["path"].endswith(".pdf"):
                t, n = pdf_text(e["path"], int(argv[3]) if len(argv) > 3 else None)
                print(f"# {n} Seiten\n{t}")
            elif e and e.get("path"):
                print(html_text(Path(e["path"]).read_text(errors="replace")))
            else:
                print(e)
        elif cmd == "count":
            print(idx()["requests"])
        else:
            return PIPELINE(cmd)
    except Budget as b:
        print(f"STOP: {b}", file=sys.stderr)
        return 2
    return 0


# ---------------------------------------------------------------------------------------------------------------
# Schritt list: Studienangebot A-Z, Pruefungsinfos-Uebersicht, Sitemap
# ---------------------------------------------------------------------------------------------------------------

AZ_URL = "https://www.uni-hannover.de/studium/studienangebot/gesamt"
PINFO_URL = "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung"
SITEMAP_PAGES = [
    "https://www.uni-hannover.de/sitemap.xml?sitemap=pages&cHash=9532594ccb2592eeb6f14732b090d54b",
    "https://www.uni-hannover.de/sitemap.xml?page=1&sitemap=pages&cHash=1d242927c7573eed72b0929d8cee9d36",
]
DEGREE_SHORT = {
    "Bachelor of Science": "B.Sc.", "Bachelor of Arts": "B.A.", "Master of Science": "M.Sc.",
    "Master of Arts": "M.A.", "Master of Education": "M.Ed.", "Bachelor of Laws": "LL.B.",
    "Master of Laws": "LL.M.", "Staatsexamen": "Staatsexamen", "Zertifikat": "Zertifikat",
    "Double Degree": "Double Degree",
}


def _clean(s: str) -> str:
    return " ".join(html.unescape(re.sub(r"(?s)<[^>]+>", " ", s)).split())


def step_list(network: bool = True) -> list[dict]:
    """Alle Eintraege der A-Z-Liste mit Art (1-Fach, 2-Fach ...) und Studienbeginn."""
    fetch(AZ_URL, network=network)
    raw = Path(fetch(AZ_URL, network=False)["path"]).read_text(errors="replace")
    out = []
    for m in re.finditer(r'<div class="c-sis__element">(.*?)(?=<div class="c-sis__element">|<footer|\Z)', raw, re.S):
        blk = m.group(1)
        a = re.search(r'<a class="c-sis__link" href="([^"]+)">(.*?)</a>', blk, re.S)
        if not a:
            continue
        kind = re.search(r'c-text--uppercase">(.*?)</div>', blk, re.S)
        start = re.search(r"Studienbeginn:(.*?)</div>", blk, re.S)
        title = _clean(a.group(2))
        tm = re.match(r"^(.*)\(([^()]*)\)$", title)
        name, degs = (tm.group(1).strip(), tm.group(2)) if tm else (title, "")
        degrees = [DEGREE_SHORT.get(d.strip(), d.strip()) for d in degs.split(",") if d.strip()]
        slug = a.group(1).rstrip("/").rsplit("/", 1)[-1]
        out.append({"slug": slug, "title": title, "name": name, "degrees": degrees,
                    "kind": _clean(kind.group(1)) if kind else "",
                    "start": _clean(start.group(1)) if start else "",
                    "program_page": "https://www.uni-hannover.de" + a.group(1)})
    # doppelte (gleicher Link in mehreren Buchstaben) entfernen
    seen, uniq = set(), []
    for e in out:
        if e["slug"] not in seen:
            seen.add(e["slug"])
            uniq.append(e)
    return uniq


def sitemap_urls(network: bool = True) -> list[str]:
    urls = []
    for u in SITEMAP_PAGES:
        t = read_text(u, network)
        if t:
            urls += [html.unescape(x) for x in re.findall(r"<loc>([^<]+)</loc>", t)]
    return sorted(set(urls))


def ordnungen_pages(network: bool = True) -> list[str]:
    return [u for u in sitemap_urls(network) if re.search(r"/pruefungsinfos-fachberatung/[^/]+/ordnungen$", u)]


def parse_ordnungen(url: str) -> dict:
    """Ordnungen-Seite: Titel und alle Dokumente (Ueberschrift, Titel, PDF-URL) in Seitenreihenfolge."""
    e = fetch(url, network=False)
    if not e or not e.get("path"):
        return {"url": url, "title": None, "docs": []}
    raw = Path(e["path"]).read_text(errors="replace")
    body = raw.split("<main", 1)[-1].split("</main>", 1)[0] if "<main" in raw else raw
    h1 = re.search(r"<h1[^>]*>(.*?)</h1>", body, re.S)
    docs, heading = [], None
    for m in re.finditer(r'<h[2-4][^>]*>(.*?)</h[2-4]>|<a\s[^>]*href="([^"]+)"[^>]*>', body, re.S):
        if m.group(1) is not None:
            heading = _clean(m.group(1))
            continue
        tag, href = m.group(0), html.unescape(m.group(2))
        if not re.search(r"\.pdf($|\?)", href, re.I) and "fileadmin" not in href:
            continue
        t = re.search(r'title="([^"]*)"', tag)
        docs.append({"heading": heading, "title": html.unescape(t.group(1)) if t else "",
                     "url": norm_url(urllib.parse.urljoin(url, href))})
    return {"url": url, "title": _clean(h1.group(1)) if h1 else None, "docs": docs}


def step_ordnungen(network: bool = True) -> list[dict]:
    res = []
    for u in ordnungen_pages(network):
        fetch(u, network=network)
        res.append(parse_ordnungen(u))
    return res


# ---------------------------------------------------------------------------------------------------------------
# Fakultaetsseiten: wo die Modulhandbuecher liegen (beim Lauf am 04.11.2026 von Hand auf den oeffentlichen Seiten
# gefunden; die Seiten stehen in FACULTY_PAGES und werden bei "pages" wieder aus dem Zwischenspeicher gelesen)
# ---------------------------------------------------------------------------------------------------------------

FAC = {
    "aul": "Fakultät für Architektur und Landschaft",
    "bug": "Fakultät für Bauingenieurwesen und Geodäsie",
    "eui": "Fakultät für Elektrotechnik und Informatik",
    "mb": "Fakultät für Maschinenbau",
    "maphy": "Fakultät für Mathematik und Physik",
    "nat": "Naturwissenschaftliche Fakultät",
    "jura": "Juristische Fakultät",
    "phil": "Philosophische Fakultät",
    "wiwi": "Wirtschaftswissenschaftliche Fakultät",
    "lnqe": "fakultätsübergreifend (Laboratorium für Nano- und Quantenengineering, LNQE)",
}

MODKAT_HOME = "https://modkat.fei.uni-hannover.de/"
MODKAT_DBS = "https://modkat.dbs.uni-hannover.de/modkat/lvk/"   # am 04.11.2026 nicht erreichbar (Zeitueberschreitung)

# Seiten, auf denen am 04.11.2026 nach Modulhandbuechern gesucht wurde (Fakultaeten, Institute, Studiengangsseiten)
DISCOVERY_PAGES = """
https://modkat.fei.uni-hannover.de/
https://www.archland.uni-hannover.de/
https://www.archland.uni-hannover.de/studium/im-studium
https://www.archland.uni-hannover.de/studium/im-studium/architektur-und-staedtebau/architektur-bachelor-of-science
https://www.archland.uni-hannover.de/studium/im-studium/architektur-und-staedtebau/architektur-und-staedtebau-master-of-science
https://www.archland.uni-hannover.de/studium/im-studium/landschaftsarchitektur-und-umweltplanung/european-master-in-landscape-architecture-emila-master-of-science
https://www.archland.uni-hannover.de/studium/im-studium/landschaftsarchitektur-und-umweltplanung/landschaftsarchitektur-master-of-science
https://www.archland.uni-hannover.de/studium/im-studium/landschaftsarchitektur-und-umweltplanung/landschaftsarchitektur-und-umweltplanung-bachelor-of-science
https://www.archland.uni-hannover.de/studium/im-studium/landschaftsarchitektur-und-umweltplanung/umwelt-und-regionalplanung-major-regionalplanung-master-of-science
https://www.engsem.uni-hannover.de/de/studium/studiengaenge-und-studienfaecher/
https://www.engsem.uni-hannover.de/en/studies/studiengaenge-und-studienfaecher/master-north-american-studies/
https://www.engsem.uni-hannover.de/studium/studiengaenge-und-studienfaecher/bachelor-te-englisch
https://www.engsem.uni-hannover.de/studium/studiengaenge-und-studienfaecher/faecheruebergreifende-bachelorstudiengang-englisch
https://www.engsem.uni-hannover.de/studium/studiengaenge-und-studienfaecher/master-german-and-english-linguistics
https://www.engsem.uni-hannover.de/studium/studiengaenge-und-studienfaecher/master-lbs-englisch
https://www.engsem.uni-hannover.de/studium/studiengaenge-und-studienfaecher/master-lg-englisch
https://www.engsem.uni-hannover.de/studium/studiengaenge-und-studienfaecher/master-north-american-studies
https://www.fbg.uni-hannover.de/
https://www.fbg.uni-hannover.de/de/studium/studienangebot-der-fakultaet/doppelabschluss-resources-and-environment
https://www.fbg.uni-hannover.de/studium/im-studium
https://www.fbg.uni-hannover.de/studium/studienangebot-der-fakultaet
https://www.fbg.uni-hannover.de/studium/studienangebot-der-fakultaet/bau-und-umweltingenieurwesen/bau-und-umweltingenieurwesen-b-sc
https://www.fbg.uni-hannover.de/studium/studienangebot-der-fakultaet/bauingenieurwesen/bauingenieurwesen-m-sc
https://www.fbg.uni-hannover.de/studium/studienangebot-der-fakultaet/computational-methods-in-engineering/computational-methods-in-engineering-m-sc
https://www.fbg.uni-hannover.de/studium/studienangebot-der-fakultaet/fernstudium-konstruktiver-ingenieurbau
https://www.fbg.uni-hannover.de/studium/studienangebot-der-fakultaet/fernstudium-wasser-und-umwelt
https://www.fbg.uni-hannover.de/studium/studienangebot-der-fakultaet/geodaesie-und-geoinformatik/geodaesie-und-geoinformatik-bsc
https://www.fbg.uni-hannover.de/studium/studienangebot-der-fakultaet/geodaesie-und-geoinformatik/geodaesie-und-geoinformatik-msc
https://www.fbg.uni-hannover.de/studium/studienangebot-der-fakultaet/umweltingenieurwesen/umweltingenieurwesen-m-sc
https://www.fbg.uni-hannover.de/studium/studienangebot-der-fakultaet/water-resources-and-environmental-engineering-watenv
https://www.hist.uni-hannover.de/de/studium/studiengaenge-und-studienfaecher/
https://www.hist.uni-hannover.de/studium/studiengaenge-und-studienfaecher/fachmaster-geschichte
https://www.hist.uni-hannover.de/studium/studiengaenge-und-studienfaecher/fueba-geschichte
https://www.hist.uni-hannover.de/studium/studiengaenge-und-studienfaecher/geschichte-im-bachelorstudiengang-sonderpaedagogik
https://www.hist.uni-hannover.de/studium/studiengaenge-und-studienfaecher/geschichte-im-masterstudiengang-lehramt-an-gymnasien-master-of-education
https://www.hist.uni-hannover.de/studium/studiengaenge-und-studienfaecher/geschichte-im-masterstudiengang-lehramt-fuer-sonderpaedagogik-master-of-education
https://www.hist.uni-hannover.de/studium/studiengaenge-und-studienfaecher/master-atlantic-studies-history-culture-and-society
https://www.ifbe.uni-hannover.de/de/studium/studiengaenge-und-studienfaecher/m-a-bildungswissenschaften
https://www.ifs.uni-hannover.de/de/studium/studiengaenge-und-studienfaecher/bachelorstudiengang-sonderpaedagogik/
https://www.ifs.uni-hannover.de/de/studium/studiengaenge-und-studienfaecher/masterstudiengang-sonderpaedagogik-rehabilitationswissenschaften
https://www.ipw.uni-hannover.de/de/studium/studiengaenge-und-studienfaecher/
https://www.ipw.uni-hannover.de/de/studium/studiengaenge-und-studienfaecher/bachelor-politikwissenschaft/
https://www.ipw.uni-hannover.de/de/studium/studiengaenge-und-studienfaecher/master-politikwissenschaft/
https://www.ipw.uni-hannover.de/studium/studiengaenge-und-studienfaecher/bachelor-te-politik
https://www.ipw.uni-hannover.de/studium/studiengaenge-und-studienfaecher/fueba-politik
https://www.ipw.uni-hannover.de/studium/studiengaenge-und-studienfaecher/master-lbs-politik
https://www.ipw.uni-hannover.de/studium/studiengaenge-und-studienfaecher/master-lehramt-an-berufsbildenden-schulen-fuer-ingenieure-unterrichtsfach-politik
https://www.ipw.uni-hannover.de/studium/studiengaenge-und-studienfaecher/master-lg-politik-wirtschaft
https://www.irw.uni-hannover.de/de/studium/studiengaenge-und-studienfaecher/
https://www.irw.uni-hannover.de/de/studium/studiengaenge-und-studienfaecher/internationaler-master-religion-in-the-public-sphere/
https://www.irw.uni-hannover.de/studium/studiengaenge-und-studienfaecher/fueba-religionswissenschaft-werte-und-normen
https://www.irw.uni-hannover.de/studium/studiengaenge-und-studienfaecher/internationaler-master-religion-in-the-public-sphere/studienorganisation
https://www.irw.uni-hannover.de/studium/studiengaenge-und-studienfaecher/master-of-education-lehramt-gymnasium-werte-und-normen
https://www.ish.uni-hannover.de/de/studium/studiengaenge-und-studienfaecher/
https://www.ish.uni-hannover.de/studium/studiengaenge-und-studienfaecher/bachelor-sozialwissenschaften
https://www.ish.uni-hannover.de/studium/studiengaenge-und-studienfaecher/master-hochschule-wissenschaft-gesellschaft
https://www.ish.uni-hannover.de/studium/studiengaenge-und-studienfaecher/master-soziologie
https://www.jura.uni-hannover.de/
https://www.jura.uni-hannover.de/studium/im-studium
https://www.jura.uni-hannover.de/studium/studienangebot-der-fakultaet
https://www.jura.uni-hannover.de/studium/studienangebot-der-fakultaet/bachelor-of-laws-it-recht-und-recht-des-geistigen-eigentums
https://www.jura.uni-hannover.de/studium/studienangebot-der-fakultaet/eulisp
https://www.jura.uni-hannover.de/studium/studienangebot-der-fakultaet/master-of-laws-europaeische-rechtspraxis
https://www.jura.uni-hannover.de/studium/studienangebot-der-fakultaet/rechtswissenschaften-staatsexamen
https://www.lnqe.uni-hannover.de/study_nano_master_modulkatalog.html
https://www.lse.uni-hannover.de/de/
https://www.lse.uni-hannover.de/de/studium/lbs/bate
https://www.lse.uni-hannover.de/de/studium/lehramt-an-gymnasien/faecheruebergreifender-bachelorstudiengang
https://www.lse.uni-hannover.de/de/studium/lehramt-an-gymnasien/master-lehramt-an-gymnasien
https://www.lse.uni-hannover.de/de/studium/lso/baso/
https://www.lse.uni-hannover.de/studium/im-studium
https://www.maphy.uni-hannover.de/
https://www.maphy.uni-hannover.de/de/studium/im-studium/meteorologie/master-meteorologie/
https://www.maphy.uni-hannover.de/studium/im-studium/lehramt
https://www.maphy.uni-hannover.de/studium/im-studium/mathematik
https://www.maphy.uni-hannover.de/studium/im-studium/mathematik/bachelor-mathematik
https://www.maphy.uni-hannover.de/studium/im-studium/mathematik/master-mathematik
https://www.maphy.uni-hannover.de/studium/im-studium/meteorologie
https://www.maphy.uni-hannover.de/studium/im-studium/modulkataloge
https://www.maphy.uni-hannover.de/studium/im-studium/physik
https://www.maphy.uni-hannover.de/studium/im-studium/umweltmeteorologie
https://www.maschinenbau.uni-hannover.de/
https://www.maschinenbau.uni-hannover.de/de/studium/im-studium/modulkataloge-tutorien-und-labore
https://www.maschinenbau.uni-hannover.de/studium/studiengaenge
https://www.maschinenbau.uni-hannover.de/studium/studiengaenge/bachelorstudiengaenge
https://www.maschinenbau.uni-hannover.de/studium/studiengaenge/double-degree-programme
https://www.maschinenbau.uni-hannover.de/studium/studiengaenge/maststudiengaenge
https://www.maschinenbau.uni-hannover.de/studium/studiengaenge/studiengaenge-mit-fakultaetsbeteiligung
https://www.naturwissenschaften.uni-hannover.de/
https://www.naturwissenschaften.uni-hannover.de/studium/im-studium
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot/biologie
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot/biologie/biologie-bsc
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot/biologie/biologie-fueba
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot/biologie/biologie-med
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot/biologie/molekulare-mikrobiologie-msc
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot/chemie-biochemie
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot/chemie-biochemie/biochemie-bsc
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot/chemie-biochemie/biochemie-msc
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot/chemie-biochemie/chemie-bsc
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot/chemie-biochemie/chemie-fueba
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot/chemie-biochemie/chemie-lbs-med
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot/chemie-biochemie/chemie-lg-med
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot/chemie-biochemie/chemie-msc
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot/chemie-biochemie/unterrichtsfach-chemie-bachelor
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot/geographie
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot/geographie/erdkunde-med
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot/geographie/geographie-ba-bsc
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot/geographie/geographie-fueba
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot/geographie/landschaftswissenschaften-msc
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot/geographie/wirtschaftsgeographie-innovation-nachhaltigkeit-m-sc
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot/geographie/wirtschaftsgeographie-ma
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot/geowissenschaften
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot/geowissenschaften/geowissenschaften-bsc
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot/geowissenschaften/geowissenschaften-msc
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot/lebensmittelwissenschaft
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot/lebensmittelwissenschaft/lebensmittelwissenschaft-bsc
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot/lebensmittelwissenschaft/lebensmittelwissenschaft-med
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot/lebensmittelwissenschaft/lebensmittelwissenschaft-med-sprint
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot/lehramt
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot/lifescience
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot/lifescience/life-science-bsc
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot/lifescience/life-science-msc
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot/pflanzenwissenschaften
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot/pflanzenwissenschaften/pflanzenbiotechnologie-msc
https://www.naturwissenschaften.uni-hannover.de/studium/studienangebot/pflanzenwissenschaften/pflanzentiotechnologie-bsc22
https://www.phil.uni-hannover.de/
https://www.phil.uni-hannover.de/studium/im-studium
https://www.phil.uni-hannover.de/studium/studiengaengefaecher
https://www.phil.uni-hannover.de/studium/studiengaengefaecher/bachelor-sonderpaedagogik
https://www.phil.uni-hannover.de/studium/studiengaengefaecher/faecheruebergreifender-bachelor
https://www.phil.uni-hannover.de/studium/studiengaengefaecher/lehramt-an-gymnasien
https://www.philos.uni-hannover.de/de/studium/studiengaenge-und-studienfaecher/
https://www.philos.uni-hannover.de/studium/studiengaenge-und-studienfaecher/philosophie-im-faecheruebergreifenden-bachelor-fueba
https://www.philos.uni-hannover.de/studium/studiengaenge-und-studienfaecher/philosophie-im-masterstudiengang-lehramt-an-gymnasien-master-of-education
https://www.philos.uni-hannover.de/studium/studiengaenge-und-studienfaecher/philosophy-of-science-master-of-arts
https://www.philos.uni-hannover.de/studium/studiengaenge-und-studienfaecher/werte-und-normen-im-masterstudiengang-lehramt-an-gymnasien-master-of-education
https://www.sportwiss.uni-hannover.de/de/studium/studiengaenge-und-studienfaecher/
https://www.sportwiss.uni-hannover.de/de/studium/studiengaenge-und-studienfaecher/master-of-science-gesundheitsfoerderung-durch-sport
https://www.sportwiss.uni-hannover.de/studium/studiengaenge-und-studienfaecher/bachelor-of-arts-sonderpaedagogik
https://www.sportwiss.uni-hannover.de/studium/studiengaenge-und-studienfaecher/bachelor-of-science-technical-education
https://www.sportwiss.uni-hannover.de/studium/studiengaenge-und-studienfaecher/faecheruebergreifender-bachelor-fach-sport
https://www.sportwiss.uni-hannover.de/studium/studiengaenge-und-studienfaecher/master-of-education-lehramt-an-berufsbildenden-schulen
https://www.sportwiss.uni-hannover.de/studium/studiengaenge-und-studienfaecher/master-of-education-lehramt-an-berufsbildenden-schulen-sprint
https://www.sportwiss.uni-hannover.de/studium/studiengaenge-und-studienfaecher/master-of-education-lehramt-an-gymnasien
https://www.sportwiss.uni-hannover.de/studium/studiengaenge-und-studienfaecher/master-of-education-lehramt-fuer-sonderpaedagogik
https://www.uni-hannover.de/de/studium/studienangebot/
https://www.uni-hannover.de/studium/studienangebot/info/studiengang/detail/arbeitswissenschaft-berufsbegleitend
https://www.uni-hannover.de/studium/studienangebot/info/studiengang/detail/atlantic-studies-in-history-culture-and-society
https://www.uni-hannover.de/studium/studienangebot/info/studiengang/detail/bildungswissenschaften
https://www.uni-hannover.de/studium/studienangebot/info/studiengang/detail/biologie
https://www.uni-hannover.de/studium/studienangebot/info/studiengang/detail/faecheruebergreifender-bachelor
https://www.uni-hannover.de/studium/studienangebot/info/studiengang/detail/hochschule-wissenschaft-gesellschaft
https://www.uni-hannover.de/studium/studienangebot/info/studiengang/detail/lehramt-an-gymnasien
https://www.uni-hannover.de/studium/studienangebot/info/studiengang/detail/meteorologie-1
https://www.uni-hannover.de/studium/studienangebot/info/studiengang/detail/nachhaltige-gesundheitsfoerderung-durch-sport
https://www.uni-hannover.de/studium/studienangebot/info/studiengang/detail/neuere-deutsche-literaturwissenschaft
https://www.uni-hannover.de/studium/studienangebot/info/studiengang/detail/north-american-studies
https://www.uni-hannover.de/studium/studienangebot/info/studiengang/detail/philosophy-of-science
https://www.uni-hannover.de/studium/studienangebot/info/studiengang/detail/politikwissenschaft
https://www.uni-hannover.de/studium/studienangebot/info/studiengang/detail/politikwissenschaft-1
https://www.uni-hannover.de/studium/studienangebot/info/studiengang/detail/religion-in-the-public-sphere-1
https://www.uni-hannover.de/studium/studienangebot/info/studiengang/detail/sonderpaedagogik
https://www.uni-hannover.de/studium/studienangebot/info/studiengang/detail/sonderpaedagogik-und-rehabilitationswissenschaften
https://www.uni-hannover.de/studium/studienangebot/info/studiengang/detail/sozialwissenschaften
https://www.uni-hannover.de/studium/studienangebot/info/studiengang/detail/soziologie
https://www.uni-hannover.de/studium/studienangebot/info/studiengang/detail/technical-education
https://www.uni-hannover.de/studium/studienangebot/info/studiengang/detail/water-resources-and-environmental-engineering
https://www.wa.uni-hannover.de/de/studium/master-arbeitswissenschaft/
https://www.wiwi.uni-hannover.de/
https://www.wiwi.uni-hannover.de/studium/studienangebot-der-fakultaet/bsc-digital-business
https://www.wiwi.uni-hannover.de/studium/studienangebot-der-fakultaet/bsc-wirtschaftsingenieur-po-2022
https://www.wiwi.uni-hannover.de/studium/studienangebot-der-fakultaet/bsc-wirtschaftswissenschaft
https://www.wiwi.uni-hannover.de/studium/studienangebot-der-fakultaet/msc-wirtschaftsingenieurwesen
https://www.wiwi.uni-hannover.de/studium/studienangebot-der-fakultaet/msc-wirtschaftswissenschaft
""".split()

FACULTY_PAGES = [
    MODKAT_HOME,
    "https://www.maschinenbau.uni-hannover.de/de/studium/im-studium/modulkataloge-tutorien-und-labore",
    "https://www.maphy.uni-hannover.de/studium/im-studium/modulkataloge",
    "https://www.lnqe.uni-hannover.de/study_nano_master_modulkatalog.html",
]

_MB = "https://www.maschinenbau.uni-hannover.de/fileadmin/maschinenbau/Modulkataloge_Tutorien_Labore/"
_NAT = "https://www.naturwissenschaften.uni-hannover.de/fileadmin/naturwissenschaften/NAT_Studium/Studienangebot/"
_MAPHY = "https://www.maphy.uni-hannover.de/fileadmin/maphy/Studium/Studierende/Modulkataloge/Modulkataloge_2026/"
_FBG = "https://www.fbg.uni-hannover.de/fileadmin/fbg/"
_BAU = _FBG + "Studium/Bauingenieurwesen/"
_AUL = "https://www.archland.uni-hannover.de/fileadmin/archland/STUDIUM/"
_WIWI = "https://www.wiwi.uni-hannover.de/fileadmin/wiwi/pdf/modulhandbuch/"
_MK = "https://modkat.fei.uni-hannover.de/material/modkat-full-{}-WS_2026_27.pdf"
_IPW = "https://www.ipw.uni-hannover.de/fileadmin/ipw/Institut_Dateien/Modulkataloge_WiSe_2026-27/"
_IFS = "https://www.ifs.uni-hannover.de/fileadmin/ifs/Studium/Studiengaenge/"
_ISH = "https://www.ish.uni-hannover.de/fileadmin/ish/"
_HIST = "https://www.hist.uni-hannover.de/fileadmin/hist/News_und_Veranstaltungen/PDF/"
_PHILOS = "https://www.philos.uni-hannover.de/fileadmin/philos/Dateien/"
_RPS = {"url": "https://www.irw.uni-hannover.de/fileadmin/rewi/Relpub/2026_08_28_RELPUB_module_catalogue.pdf",
        "term": "Stand 28.08.2026", "po": None, "label": None}


def C(url, term, po=None, label=None):
    """Ein Modulhandbuch: URL, Katalogsemester, PO (None = gilt fuer die neueste PO), Bezeichnung."""
    return {"url": url, "term": term, "po": po, "label": label}


def MK(code, po=None, label=None):
    return {"url": _MK.format(code), "term": "WS 2026/27", "po": po, "label": label, "modkat_code": code}


# A-Z-Kuerzel (uni-hannover.de/.../detail/<slug>) -> Fakultaet, Ordnungen-Seite(n), Kataloge, Verlaufsplan
P = {
    # --- Architektur und Landschaft
    "architektur": dict(fac="aul", ord="architektur-bsc",
                        cats=[C(_AUL + "architektur/Modulkatalog_BSc-Architektur_PO2019_01.pdf", "PO 2019", "2019")]),
    "architektur-und-staedtebau": dict(fac="aul", ord="architektur-und-staedtebau-msc",
                                       cats=[C(_AUL + "architektur_und_staedtebau/Modulkatalog_MSc-ArchStaedtebau_PO2020_01.pdf", "PO 2020", "2020")]),
    "landschaftsarchitektur-und-umweltplanung": dict(
        fac="aul", ord="landschaftsarchitektur-und-umweltplanung-bsc",
        cats=[C(_AUL + "LAUM/Modulbeschreibungen/Bachelor_LaUp_Modulkatalog_Pflicht_20231205.pdf", "Stand 05.12.2023", label="Pflichtmodule"),
              C(_AUL + "LAUM/Modulbeschreibungen/Bachelor_LaUp_Modulhandbuch_Wahlpflicht_20230912.pdf", "Stand 12.09.2023", label="Wahlpflichtmodule")],
        plan=_AUL + "LAUM/studienverlaufsplaene/Studienveraufsplan_Bachelor_2026.pdf"),
    "landschaftsarchitektur": dict(
        fac="aul", ord="landschaftsarchitektur-msc",
        cats=[C(_AUL + "LAUM/Modulbeschreibungen/Modulkatalog_MA_LA_Pflicht_2026.pdf", "2026", label="Pflichtmodule"),
              C(_AUL + "LAUM/Modulbeschreibungen/Master_Landschaft_Modulhandbuch_Wahlpflicht2019.pdf", "2019", label="Wahlpflichtmodule")],
        plan=_AUL + "LAUM/studienverlaufsplaene/Studienverlaufsgrafik_MasterLa.pdf"),
    "european-master-in-landscape-architecture-emila": dict(
        fac="aul", ord="landschaftsarchitektur-msc",
        cats=[C(_AUL + "LAUM/Modulbeschreibungen/Modulkatalog_MA_LA_Pflicht_2026.pdf", "2026", label="Pflichtmodule Landschaftsarchitektur (M.Sc.)")],
        plan=_AUL + "LAUM/studienverlaufsplaene/Studienverlaufsgrafik_EMiLA.pdf"),
    "umwelt-und-regionalplanung-major-regionalplanung": dict(
        fac="aul", ord="umwelt-und-regionalplanung-msc",
        cats=[C(_AUL + "LAUM/Modulbeschreibungen/Modulkatalog_MA_URP_Pflicht_2026.pdf", "2026", label="Pflichtmodule"),
              C(_AUL + "LAUM/Modulbeschreibungen/Master_Umwelt-und_Regionalplanung_Wahlpflicht_20210719.pdf", "Stand 19.07.2021", label="Wahlpflichtmodule")],
        plan=_AUL + "LAUM/Studienverlaufsgrafiken_Masterstudiengang_Umwelt-_und_Regionalplanung_190516_Regionalplanung.pdf"),
    "umwelt-und-regionalplanung-major-naturschutz-und-landschaftsplanung": dict(
        fac="aul", ord="umwelt-und-regionalplanung-msc",
        cats=[C(_AUL + "LAUM/Modulbeschreibungen/Modulkatalog_MA_URP_Pflicht_2026.pdf", "2026", label="Pflichtmodule"),
              C(_AUL + "LAUM/Modulbeschreibungen/Master_Umwelt-und_Regionalplanung_Wahlpflicht_20210719.pdf", "Stand 19.07.2021", label="Wahlpflichtmodule")]),
    # --- Bauingenieurwesen und Geodaesie
    "bau-und-umweltingenieurwesen": dict(fac="bug", ord="bau-und-umweltingenieurwesen-bsc",
                                         cats=[C(_BAU + "Modulhandbuecher/PO_25/Modulhandbuch_PO25_BU.pdf", "PO 2025", "2025")],
                                         plan=_BAU + "Moduluebersichten/PO_25/Moduluebersicht_PO25_BU.pdf"),
    "bauingenieurwesen": dict(fac="bug", ord="bauingenieurwesen-msc",
                              cats=[C(_BAU + "Modulhandbuecher/PO_25/Modulhandbuch_PO25_BAU.pdf", "PO 2025", "2025")],
                              plan=_BAU + "Moduluebersichten/PO_25/Moduluebersicht_PO25_BAU-KIB.pdf"),
    "konstruktiver-ingenieurbau-fernstudium": dict(
        fac="bug", ord="bauingenieurwesen-vertiefung-konstruktiver-ingenieurbau-fernstudium-master-of-science",
        cats=[C(_BAU + "Modulhandbuecher/PO_25/Modulhandbuch_PO25_BAU.pdf", "PO 2025", label="Modulhandbuch Bauingenieurwesen (M.Sc.)")],
        plan=_BAU + "Moduluebersichten/PO_25/Moduluebersicht_PO25_BAU-FernKIB.pdf"),
    "umweltingenieurwesen": dict(fac="bug", ord="umweltingenieurwesen-msc",
                                 cats=[C(_BAU + "Modulhandbuecher/PO_25/Modulhandbuch_PO25_UIW.pdf", "PO 2025", "2025")],
                                 plan=_BAU + "Moduluebersichten/PO_25/Moduluebersicht_PO25_UIW-Umwelt.pdf"),
    "computational-methods-in-engineering": dict(fac="bug", ord="computational-methods-in-engineering-msc",
                                                 cats=[C(_BAU + "Modulhandbuecher/PO_25/Modulhandbuch_PO25_CME.pdf", "PO 2025", "2025")],
                                                 plan=_BAU + "Moduluebersichten/PO_25/Moduluebersicht_PO25_CME.pdf"),
    "water-resources-and-environmental-engineering": dict(
        fac="bug", ord="water-resources-and-environmental-management-msc",
        cats=[C(_FBG + "WATENV/Documents_pdf/Curriculum_WATENV_2025._aktuell_04.09.2025pdf.pdf", "Stand 04.09.2025", label="Moduluebersicht (Curriculum)")]),
    "wasser-und-umwelt-fernstudium": dict(
        fac="bug", ord="wasser-und-umwelt-msc",
        plan="https://www.fbg.uni-hannover.de/studium/studienangebot-der-fakultaet/fernstudium-wasser-und-umwelt/modulangebot"),
    "geodaesie-und-geoinformatik": dict(fac="bug", ord="geodaesie-und-geoinformatik-bsc",
                                        cats=[C(_FBG + "Geodaesie/Dokumente/Bachelor_GuG/20260305_Modulkatalog_GuG_Bachelor_PO25.pdf", "Stand 05.03.2026", "2025")]),
    "geodaesie-und-geoinformatik-vertiefung-geomatik": dict(
        fac="bug", ord="geodaesie-und-geoinformatik-msc",
        cats=[C(_FBG + "Geodaesie/Dokumente/Master_GuG/20260310_Modulkatalog_GuG_Master_PO25.pdf", "Stand 10.03.2026", "2025")],
        plan=_FBG + "Geodaesie/Dokumente/Master_GuG/20260324_Curriculum_MSc_GuG_Geomatik.pdf"),
    "geodaesie-und-geoinformatik-vertiefung-navigation-und-umweltrobotik": dict(
        fac="bug", ord="geodaesie-und-geoinformatik-msc",
        cats=[C(_FBG + "Geodaesie/Dokumente/Master_GuG/20260310_Modulkatalog_GuG_Master_PO25.pdf", "Stand 10.03.2026", "2025")],
        plan=_FBG + "Geodaesie/Dokumente/Master_GuG/20260316_Curriculum_MSc_GuG_Vertiefung_NuUR.pdf"),
    "geodaesie-und-geoinformatik-vertiefung-remote-sensing-and-gis": dict(
        fac="bug", ord="geodaesie-und-geoinformatik-msc",
        cats=[C(_FBG + "Geodaesie/Dokumente/Master_GuG/20260310_Modulkatalog_GuG_Master_PO25.pdf", "Stand 10.03.2026", "2025")],
        plan=_FBG + "Geodaesie/Dokumente/Master_GuG/Vertiefung_RS-GIS_Curricula-1.pdf"),
    # --- Elektrotechnik und Informatik (modkat)
    "elektrotechnik-und-informationstechnik": dict(fac="eui", ord="elektrotechnik-und-informationstechnik-bsc",
                                                   cats=[MK("ETBSc25", "2025"), MK("ETBSc17", "2017")]),
    "elektrotechnik-und-informationstechnik-1": dict(fac="eui", ord="elektrotechnik-und-informationstechnik-msc",
                                                     cats=[MK("ETMSc17", "2017")]),
    "microelectronics-engineering-electrical-engineering-and-information-technology-track-master-of-science": dict(
        fac="eui", ord="elektrotechnik-und-informationstechnik-msc", cats=[MK("ETMSc17", "2017")]),
    "energietechnik": dict(fac="eui", ord="energietechnik-bsc", cats=[MK("EntBsc24", "2020")]),
    "energietechnik-1": dict(fac="eui", ord="energietechnik-msc", cats=[MK("EntMsc24", "2020")]),
    "renewable-energy-and-electrical-power-engineering-track": dict(fac="eui", ord="energy-technology-msc",
                                                                    cats=[MK("EntMsc24", label="Zuordnung geschaetzt")]),
    "informatik": dict(fac="eui", ord="informatik-bsc", cats=[MK("INFBSc22")]),
    "informatik-1": dict(fac="eui", ord="informatik-msc", cats=[MK("INFMSc25")]),
    "informatik-vertiefung-logic-and-computation": dict(fac="eui", ord="informatik-msc", cats=[MK("INFMSc25")]),
    "technische-informatik": dict(fac="eui", ord="technische-informatik-bsc", cats=[MK("TIBSc25")]),
    "technische-informatik-1": dict(fac="eui", ord="technische-informatik-msc", cats=[MK("TIMSc25")]),
    "mechatronik": dict(fac="eui", ord="mechatronik-bsc", cats=[MK("MechBSc25", "2025"), MK("MechBSc17", "2017")]),
    # --- Maschinenbau
    "maschinenbau": dict(fac="mb", ord="maschinenbau-bsc",
                         cats=[C(_MB + "Modulkatalog_MB_BSC_PO_26.pdf", "WS 2026/27", "2026"),
                               C(_MB + "Modulkatalog_MB_BSC_PO_17.pdf", "WS 2026/27", "2017")]),
    "maschinenbau-1": dict(fac="mb", ord="maschinenbau-msc",
                           cats=[C(_MB + "Modulkatalog_MB_MSc_PO_26.pdf", "WS 2026/27", "2026"),
                                 C(_MB + "Modulkatalog_MB_MSc_PO_17.pdf", "WS 2026/27", "2017")]),
    "mechanical-engineering-mechanical-engineering-track": dict(fac="mb", ord="maschinenbau-msc",
                                                                cats=[C(_MB + "Modulkatalog_ME_MSc_PO_26.pdf", "WS 2026/27", "2026")]),
    "medizintechnik": dict(fac="mb", ord="medizintechnik", cats=[C(_MB + "Modulkatalog_MT_BSC_PO_26.pdf", "WS 2026/27", "2026")]),
    "nachhaltige-ingenieurwissenschaft": dict(fac="mb", ord="nachhaltige-ingenieurwissenschaft-bsc",
                                              cats=[C(_MB + "Modulkatalog_NIng_BSC_PO_21.pdf", "WS 2026/27", "2021")]),
    "nachhaltige-ingenieurwissenschaft-1": dict(fac="mb", ord="nachhaltige-ingenieurwissenschaft-msc",
                                                cats=[C(_MB + "Modulkatalog_NIng_MSc_PO_24.pdf", "WS 2026/27", "2024")]),
    "mechatronik-und-robotik": dict(fac="mb", ord="mechatronik-msc",
                                    cats=[C(_MB + "Modulkatalog_Mech_MSc_PO_25.pdf", "WS 2026/27", "2025"),
                                          C(_MB + "Modukatalog_Mech_MSc_PO_17.pdf", "WS 2026/27", "2017")]),
    "ai-driven-mechatronics-and-robotics": dict(fac="mb", ord="mechatronik-msc",
                                                cats=[C(_MB + "Modulkatalog_AI-driven_MSc_PO_25.pdf", "WS 2026/27", "2025")]),
    "biomedizintechnik": dict(fac="mb", ord="biomedizintechnik-msc",
                              cats=[C(_MB + "Modulkatalog_BMT_MSC_PO_26.pdf", "WS 2026/27", "2026"),
                                    C(_MB + "Modulkatalog_BMT_MSc_PO_17.pdf", "WS 2026/27", "2017")]),
    "optische-technologien": dict(fac="mb", ord="optische-technologien-msc",
                                  cats=[C(_MB + "Modulkatalog_OT_MSc_PO_26_Deu.pdf", "WS 2026/27", "2026"),
                                        C(_MB + "Modulkatalog_OT_MSC_PO_17_Deu.pdf", "WS 2026/27", "2017")]),
    "nanotechnologie": dict(fac="lnqe", ord="nanotechnologie-bsc",
                            cats=[C("https://www.lnqe.uni-hannover.de/fileadmin/lnqe/downloads/Studiengang_Allgemein/Modulkatalog_Nanotechnologie.pdf", "aktuell", label="Kurs- und Modulkatalog Nanotechnologie")]),
    "nanotechnologie-1": dict(fac="lnqe", ord="nanotechnologie-msc",
                              cats=[C("https://www.lnqe.uni-hannover.de/fileadmin/lnqe/downloads/Studiengang_Allgemein/Modulkatalog_Nanotechnologie.pdf", "aktuell", label="Kurs- und Modulkatalog Nanotechnologie")]),
    # --- Mathematik und Physik
    "mathematik": dict(fac="maphy", ord="mathematik-bsc", cats=[C(_MAPHY + "katalog_fach_mathe_2026.pdf", "2026")]),
    "mathematik-1": dict(fac="maphy", ord="mathematik-msc", cats=[C(_MAPHY + "katalog_fach_mathe_2026.pdf", "2026")]),
    "physik": dict(fac="maphy", ord="physik-bsc", cats=[C(_MAPHY + "katalog_fach_physik_2026.pdf", "2026")]),
    "physik-1": dict(fac="maphy", ord="physik-msc", cats=[C(_MAPHY + "katalog_fach_physik_2026.pdf", "2026")]),
    "umweltmeteorologie": dict(fac="maphy", ord="umweltmeteorologie-bsc",
                               cats=[C(_MAPHY + "katalog_fach_umweltmeteorlogie_2026.pdf", "2026")],
                               plan="https://www.maphy.uni-hannover.de/fileadmin/maphy/Studium/Studierende/Studienverlaufsplanung/Studienverlauf_UMet_18082022.pdf"),
    "meteorologie-1": dict(fac="maphy", ord="meteorologie-msc"),
    "quantum-engineering": dict(fac="maphy", ord="quantum-engineering-msc", cats=[C(_MAPHY + "Modulkatalog_QE_03112026.pdf", "Stand 03.11.2026")]),
    # --- Naturwissenschaftliche Fakultaet
    "biologie": dict(fac="nat", ord="biologie-bsc",
                     cats=[C(_NAT + "Biologie/Detail-Biologie-BSc/Modulkataloge/2026_Modulkatalog_Biologie_WiSe26-27_final.pdf", "WS 2026/27")],
                     plan=_NAT + "Biologie/Detail-Biologie-BSc/Studienverlaufsplan/Studienverlaufsplan_Biologie.pdf"),
    "molekulare-mikrobiologie": dict(fac="nat", ord="molekulare-mikrobiologie-msc",
                                     cats=[C(_NAT + "Biologie/Detail-MolekulareMikrobiologie-MSc/PDF/Modulkatalog_Molekulare_Mikrobiologie_26-27.pdf", "WS 2026/27")],
                                     plan=_NAT + "Biologie/Detail-MolekulareMikrobiologie-MSc/PDF/Studienverlaufsplan_MolMi_2018-19.pdf"),
    "chemie": dict(fac="nat", ord="chemie-bsc",
                   cats=[C(_NAT + "Chemie-Biochemie/Detail-Chemie-BSc/20240827_Modulkatalog_Bachelor_Chemie.pdf", "Stand 27.08.2024", "2024"),
                         C(_NAT + "Chemie-Biochemie/Detail-Chemie-BSc/Modulhandbuch_Bachelor_Chemie_20230918.pdf", "Stand 18.09.2023", "2016")],
                   plan=_NAT + "Chemie-Biochemie/Detail-Chemie-BSc/Studienplan_Bachelor_Chemie_PO_2024.pdf"),
    "chemie-1": dict(fac="nat", ord="chemie-msc",
                     cats=[C(_NAT + "Chemie-Biochemie/Detail-Chemie-MSc/Modulkatalog-Chemie-Master-PO2024.pdf", "PO 2024", "2024"),
                           C(_NAT + "Chemie-Biochemie/Detail-Chemie-MSc/Modulhandbuch-Chemie-Master-PO2017.pdf", "PO 2017", "2017")],
                     plan=_NAT + "Chemie-Biochemie/Detail-Chemie-MSc/Studienplan-Master-Chemie-PO2024.pdf"),
    "biochemie": dict(fac="nat", ord="biochemie-bsc",
                      cats=[C(_NAT + "Chemie-Biochemie/Detail-Biochemie-BSc/20251001_Modulhandbuch_BScBC_Pflicht.pdf", "Stand 01.10.2025", label="Pflichtmodule"),
                            C(_NAT + "Chemie-Biochemie/Detail-Biochemie-BSc/20251001_Modulhandbuch_BScBC_Wahlpflicht.pdf", "Stand 01.10.2025", label="Wahlpflichtmodule")],
                      plan=_NAT + "Chemie-Biochemie/Detail-Biochemie-BSc/20240920_Uebersicht_BScVerlauf_Planung_2024-25.pdf"),
    "biochemie-1": dict(fac="nat", ord="biochemie-msc"),
    "geographie": dict(fac="nat", ord="geographie-ba-bsc",
                       cats=[C(_NAT + "Geographie/Studiengangsuebergreifende_Dokumente/Modulkatalog_Bachelor_Geographie.pdf", "aktuell")],
                       plan=_NAT + "Geographie/Detail-Geographie-Bachelor/Studienverlauf_Bachelor_Humangeo-2025.pdf"),
    "landschaftswissenschaften": dict(fac="nat", ord="landschaftswissenschaften-msc",
                                      cats=[C(_NAT + "Geographie/Detail-Landschaftswissens-MSc/ModulkatalogLawi_PO2026.pdf", "PO 2026", "2026"),
                                            C(_NAT + "Geographie/Detail-Landschaftswissens-MSc/ModulkatalogLawi_PO19_2026.pdf", "2026", "2019")],
                                      plan=_NAT + "Geographie/Detail-Landschaftswissens-MSc/Studienverlauf_Master_LaWi.pdf"),
    "wirtschaftsgeographie-innovation-und-nachhaltigkeit": dict(
        fac="nat", ord="wirtschaftsgeographie-innovation-und-nachhaltigkeit-msc",
        cats=[C(_NAT + "Geographie/Detail-Wirtschaftsgeographie-MSc/Modulkatalog_MSc_WIN.pdf", "aktuell")]),
    "wirtschaftsgeographie-innovation-und-nachhaltigkeit-double-degree-track": dict(
        fac="nat", ord="wirtschaftsgeographie-innovation-und-nachhaltigkeit-msc",
        cats=[C(_NAT + "Geographie/Detail-Wirtschaftsgeographie-MSc/Modulkatalog_MSc_WIN.pdf", "aktuell")]),
    "geowissenschaften": dict(fac="nat", ord="geowissenschaften-bsc",
                              cats=[C(_NAT + "Geowissenschaften/Detail-Geowissenschaften-BSc/Modulkatalog_Bachelor_Geowissenschaften2025.pdf", "2025")],
                              plan=_NAT + "Geowissenschaften/Detail-Geowissenschaften-BSc/Studienverlaufsplan.pdf"),
    "geowissenschaften-1": dict(fac="nat", ord="geowissenschaften-msc",
                                cats=[C(_NAT + "Geowissenschaften/Detail-Geowissenschaften-MSc/Modulkatalog_Master_Geowissenschaften2025.pdf", "2025")]),
    "life-science": dict(fac="nat", ord="life-science-bsc",
                         cats=[C(_NAT + "LifeScience/Detail-LifeScience-BSc/Dokumente/Modulkatalog_Bachelor_Life_Science_Pflicht.pdf", "aktuell", label="Pflichtmodule"),
                               C(_NAT + "LifeScience/Detail-LifeScience-BSc/Dokumente/2024-11-13_Modulkatalog_Bachelor_Life_Science_Wahlpflicht.pdf", "Stand 13.11.2024", label="Wahlpflichtmodule")],
                         plan=_NAT + "LifeScience/Detail-LifeScience-BSc/Dokumente/2023_BSc-Pflichtplan.pdf"),
    "life-science-1-1": dict(fac="nat", ord="life-science-msc",
                             cats=[C(_NAT + "LifeScience/Detail-LifeScience-MSc/Dokumente/2025_07_16_Modulkatalog_MSc_LS__final.pdf", "Stand 16.07.2025", "2024"),
                                   C(_NAT + "LifeScience/Detail-LifeScience-MSc/Dokumente/2023_Modulhandbuch_Master_LS-PO-2022.pdf", "2023", "2022")]),
    "pflanzenbiotechnologie-2": dict(fac="nat", ord="pflanzenbiotechnologie-bsc",
                                     cats=[C(_NAT + "Pflanzenwissenschaften/Detail-Pflanzenbiotechnologie-BSc-PO2022/Modulkatalog_BSc_Pflanzenbiotechnologie_26-27.pdf", "WS 2026/27", "2022")]),
    "pflanzenbiotechnologie": dict(fac="nat", ord="pflanzenbiotechnologie-msc",
                                   cats=[C(_NAT + "Pflanzenwissenschaften/Detail-Pflanzenbiotechnologie-MSc/Modulkatalog_MSc_PBT_26-27.pdf", "WS 2026/27")],
                                   plan=_NAT + "Pflanzenwissenschaften/Detail-Pflanzenbiotechnologie-MSc/Struktur_PBT_MSc.pdf"),
    # --- Jura
    "rechtswissenschaften": dict(fac="jura", ord=["rechtswissenschaften", "rechtswissenschaften-llb"],
                                 plan="https://www.uni-hannover.de/fileadmin/luh/content/pruefungsamt/formulare/Rechtswiss/Studienordnung_vom_01.09.2026.pdf"),
    "informationstechnologierecht-und-recht-des-geistigen-eigentums-llb": dict(
        fac="jura", ord="it-recht-llb",
        plan="https://www.jura.uni-hannover.de/studium/studienangebot-der-fakultaet/bachelor-of-laws-it-recht-und-recht-des-geistigen-eigentums/studienverlauf"),
    "informationstechnologierecht-und-recht-des-geistigen-eigentums-llm": dict(
        fac="jura", ord="it-recht-llm", plan="https://www.jura.uni-hannover.de/studium/studienangebot-der-fakultaet/eulisp/studienverlauf"),
    "european-legal-practice-llm-joint-degree": dict(
        fac="jura", ord="europaeische-rechtspraxis-llm",
        plan="https://www.jura.uni-hannover.de/studium/studienangebot-der-fakultaet/master-of-laws-europaeische-rechtspraxis/studienverlauf"),
    # --- Philosophische Fakultaet
    "politikwissenschaft": dict(fac="phil", ord="politikwissenschaft-ba",
                                cats=[C(_IPW + "BA_Polwiss_Modulkatalog_Stand_10_26.pdf", "WS 2026/27")],
                                plan=_IPW + "BA_Pol_2026_MusterPlan_Variante_1.pdf"),
    "politikwissenschaft-1": dict(fac="phil", ord="politikwissenschaft-ma",
                                  cats=[C(_IPW + "MA_Polwiss_Modulkatalog_Stand_10_26.pdf", "WS 2026/27")],
                                  plan=_IPW + "MA_Pol_2026_Musterstudienplan.pdf"),
    "sozialwissenschaften": dict(fac="phil", ord="sozialwissenschaften-ba",
                                 cats=[C(_ISH + "institut/dokumente/Modulkatalog_Sowi_November_2025.pdf", "Stand 11/2025")],
                                 plan=_ISH + "institut/dokumente/Studiengangsstruktur_B.A._Sozialwissenschaften_ab_WiSe_2026__2027.pdf"),
    "soziologie": dict(fac="phil", ord="soziologie-ma",
                       cats=[C(_ISH + "institut/dokumente/Modulkatalog_MA_Soziologie_April_2025_.pdf", "Stand 04/2025")]),
    "atlantic-studies-in-history-culture-and-society": dict(
        fac="phil", ord="atlantic-studies-ma",
        cats=[C("https://www.hist.uni-hannover.de/fileadmin/hist/News_und_Veranstaltungen/PDF/Modulkatalog_Atlantic_Studies_ab_WiSe_2026_2027.pdf", "ab WS 2026/27")]),
    "north-american-studies": dict(fac="phil", ord="north-american-studies"),
    "neuere-deutsche-literaturwissenschaft": dict(fac="phil", ord="neuere-deutsche-literaturwissenschaft-ma"),
    "philosophy-of-science": dict(
        fac="phil", ord="philosophy-of-science-ma",
        cats=[C("https://www.philos.uni-hannover.de/fileadmin/philos/Dateien/Modulkataloge/Modulkatalog_Philosophy_of_Science_WiSe2022.23.pdf", "ab WS 2022/23")],
        plan="https://www.philos.uni-hannover.de/fileadmin/philos/Dateien/Studienverlaufsplaene/Studienverlaufsplan_MA_Philosophy_of_Science_2026_01_12.pdf"),
    "religion-in-the-public-sphere-1": dict(fac="phil", ord="religion-in-the-public-sphere", cats=[_RPS]),
    "religion-in-the-public-sphere-double-degree-track": dict(fac="phil", ord="religion-in-the-public-sphere", cats=[_RPS]),
    "bildungswissenschaften": dict(fac="phil", ord="bildungswissenschaften-ma",
                                   cats=[C("https://www.ifbe.uni-hannover.de/fileadmin/ifbe/PDF/MA_BW_Modulkatalog_ab_WS_26-27_Stand_2026-09-08.pdf", "ab WS 2026/27")]),
    "sonderpaedagogik": dict(fac="phil", ord="sonderpaedagogik-ba",
                             cats=[C(_IFS + "Studium_B.A._Sonderpaedagogik/BA_Modulkataloge_10_2026.pdf", "Stand 10/2026")]),
    "sonderpaedagogik-und-rehabilitationswissenschaften": dict(
        fac="phil", ord="sonderpaedagogik-und-rehabilitationswissenschaften-ma",
        cats=[C(_IFS + "Studium_M.A._Sonderpaedagogik_und_Rehabilitationswissenschaften/Modulkataloge_M.A._10_2026.pdf", "Stand 10/2026")]),
    "hochschule-wissenschaft-gesellschaft": dict(
        fac="phil", ord="hochschule-wissenschaft-gesellschaft-ma",
        cats=[C(_ISH + "ma_wug/Dokumente/Modulhandbuch/Modulhandbuch_MA_Hochschule__Wissenschaft__Gesellschaft_Stand_10_09_2025.pdf", "Stand 10.09.2025")],
        plan=_ISH + "ma_wug/Dokumente/Studienverlauf/Studienverlaufsplaene_MA_Hochschule__Wissenschaft__Gesellschaft_2025.pdf"),
    "nachhaltige-gesundheitsfoerderung-durch-sport": dict(
        fac="phil", ord="nachhaltige-gesundheitsfoerderung-durch-sport-ms",
        cats=[C("https://www.sportwiss.uni-hannover.de/fileadmin/sportwiss/Modulhandbuch/Modulkatalog_Master_Nachhaltige_Gesundheitsfoerderung_durch_Sport_WiSe26.27.pdf", "WS 2026/27")],
        plan="https://www.sportwiss.uni-hannover.de/fileadmin/sportwiss/Studiengaenge_und_-Plaene/Studienverlaufsplan_MSc_Nachhaltige_Gesundheitsfoerderung_durch_Sport_20251001.pdf"),
    "arbeitswissenschaft-berufsbegleitend": dict(fac="phil", ord="arbeitswissenschaft-ma"),
    "faecheruebergreifender-bachelor": dict(fac="phil", ord="faecheruebergreifender-bachelorstudiengang"),
    "technical-education": dict(fac="phil", ord="technical-education-bsc"),
    "lehramt-an-gymnasien": dict(fac="phil", ord="lehramt-an-gymnasien-med"),
    "lehramt-an-berufsbildenden-schulen": dict(fac="phil", ord="lehramt-an-berufsbildenden-schulen-med"),
    "lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint": dict(fac="phil", ord="lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint"),
    "lehramt-fuer-sonderpaedagogik": dict(fac="phil", ord="lehramt-fuer-sonderpaedagogik-med"),
    "lehramt-an-berufsbildenden-schulen-zweites-fach": dict(fac="phil", ord="lehramt-an-berufsbildenden-schulen-zweites-fach"),
    "lehramt-an-gymnasien-drittes-fach": dict(fac="phil", ord="lehramt-an-gymnasien-drittes-fach"),
    "lehramt-fuer-sonderpaedagogik-zweites-fach": dict(fac="phil", ord="lehramt-fuer-sonderpaedagogik-zweites-fach"),
    # --- Wirtschaftswissenschaften
    "wirtschaftswissenschaft": dict(fac="wiwi", ord="wirtschaftswissenschaft-bsc",
                                    cats=[C(_WIWI + "sose2026/Modulhandbuch_Bachelor_Wirtschaftswissenschaft_Sommersemester_2026.pdf", "SS 2026")]),
    "wirtschaftswissenschaft-1": dict(fac="wiwi", ord="wirtschaftswissenschaft-msc",
                                      cats=[C(_WIWI + "sose2026/Modulhandbuch_Master_Wirtschaftswissenschaft_Sommersemester_2026.pdf", "SS 2026")]),
    "wirtschaftsingenieurwesen": dict(fac="wiwi", ord="wirtschaftsingenieurwesen-bsc",
                                      cats=[C(_WIWI + "sose2026/Modulhandbuch_Bachelor_Wirtschaftsingenieurwesen_Sommersemester_2026.pdf", "SS 2026"),
                                            MK("WiIngBSc22", label="technischer Teil (FEI)")]),
    "wirtschaftsingenieurwesen-1": dict(fac="wiwi", ord="swirtschaftsingenieurwesen-msc",
                                        cats=[C(_WIWI + "sose2026/Modulhandbuch_Master_Wirtschaftsingenieurwesen_Sommersemester_2026.pdf", "SS 2026")]),
    "digital-business": dict(fac="wiwi", ord="digital-business-bsc",
                             cats=[C(_WIWI + "semesterunabhaengig/Modulhandbuch_Bachelor_Digital_Business.pdf", "semesterunabhaengig"),
                                   MK("DiBu", label="Informatik-Anteil (FEI)")]),
}

# Studiengaenge mit Ordnungen-Seite, aber nicht (mehr) im Studienangebot A-Z (auslaufend, kein Neuzugang)
UNLISTED = {
    "produktion-und-logistik-bsc": dict(name="Produktion und Logistik", deg="B.Sc.", fac="mb",
                                        cats=[C(_MB + "Modulkatalog_PL_BSC_PO_17.pdf", "WS 2026/27", "2017")]),
    "produktion-und-logistik-msc": dict(name="Produktion und Logistik", deg="M.Sc.", fac="mb",
                                        cats=[C(_MB + "Modulkatalog_PL_MSc_PO_17.pdf", "WS 2026/27", "2017")]),
    "optische-technologien-laser-und-photonik-bsc": dict(name="Optische Technologien: Laser und Photonik", deg="B.Sc.", fac="mb",
                                                         cats=[C(_MB + "Modulkatalog_OT_BSC_PO_22.pdf", "WS 2026/27", "2022")]),
    "meteorologie-bsc": dict(name="Meteorologie", deg="B.Sc.", fac="maphy"),
    "wirtschaftsgeographie-ma": dict(name="Wirtschaftsgeographie", deg="M.A.", fac="nat",
                                     cats=[C(_NAT + "Geographie/Detail-Wirtschaftsgeographie-MA/Modulkatalog_MA_WiGeo_Feb_2025.pdf", "Stand 02/2025")]),
    "geschichte-ma": dict(name="Geschichte", deg="M.A.", fac="phil",
                          cats=[C(_HIST + "Modulkataloge_MA_Geschichte_WS_26_27.pdf", "WS 2026/27")]),
    "deutsche-und-englische-linguistik-ma": dict(name="Deutsche und Englische Linguistik", deg="M.A.", fac="phil"),
    "gartenbauwissenschaften-bsc": dict(name="Gartenbauwissenschaften", deg="B.Sc.", fac="nat"),
    "gartenbauwissenschaften-msc": dict(name="Gartenbauwissenschaften", deg="M.Sc.", fac="nat"),
    "international-horticulture": dict(name="International Horticulture", deg="M.Sc.", fac="nat"),
    "molekulare-und-angewandte-pflanzenwissenschaften-bsc": dict(name="Molekulare und Angewandte Pflanzenwissenschaften", deg="B.Sc.", fac="nat"),
    "food-research-and-development-lebensmittelwissenschaft-msc": dict(name="Food Research and Development / Lebensmittelwissenschaft", deg="M.Sc.", fac="nat"),
    "european-master-in-territorial-development-msc": dict(name="European Master in Territorial Development", deg="M.Sc.", fac="aul"),
    "kautschuktechnologie": dict(name="Kautschuktechnologie", deg="Zertifikat", fac="nat"),
    "aesthetische-bildung-zertifikat": dict(name="Ästhetische Bildung", deg="Zertifikat", fac="phil"),
    "erwachsenenbildungweiterbildung-zert": dict(name="Erwachsenenbildung/Weiterbildung", deg="Zertifikat", fac="phil"),
    "arbeitswissenschaft-bsa": dict(name="Arbeitswissenschaft (Weiterbildungsstudium)", deg="Zertifikat", fac="phil"),
    "international-mechatronics": dict(name="International Mechatronics", deg="M.Sc.", fac="mb"),
    "energy-technology": dict(name="Energy Technology", deg="M.Sc.", fac="eui"),
}

# Faecher im Faecheruebergreifenden Bachelor, Technical Education, Sonderpaedagogik und den Lehramts-Mastern
SUBJECT_FAC = {
    "Biologie": "nat", "Chemie": "nat", "Erdkunde": "nat", "Erdkunde / Geographie": "nat",
    "Lebensmittelwissenschaft": "nat", "Mathematik": "maphy", "Physik": "maphy", "Informatik": "eui",
    "Elektrotechnik": "eui", "Metalltechnik": "mb", "Bautechnik": "bug", "Holztechnik": "bug",
    "Farbtechnik und Raumgestaltung": "aul",
}
CONTEXT_ORD = {
    "Fächerübergreifenden Bachelor": ("faecheruebergreifender-bachelorstudiengang", "B"),
    "Bachelorstudiengang Technical Education": ("technical-education-bsc", "B"),
    "Bachelorstudiengang Sonderpädagogik": ("sonderpaedagogik-ba", "B"),
    "Bachelorstudiengang Sonderpädagogik, außerschulisch": ("sonderpaedagogik-ba", "B"),
    "Masterstudiengang Lehramt an Gymnasien": ("lehramt-an-gymnasien-med", "M"),
    "Masterstudiengang Lehramt an berufsbildenden Schulen": ("lehramt-an-berufsbildenden-schulen-med", "M"),
    "Masterstudiengang Lehramt an berufsbildenden Schulen für Fachbachelor (LBS-Sprint)": (
        "lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint", "M"),
    "Masterstudiengang Lehramt für Sonderpädagogik": ("lehramt-fuer-sonderpaedagogik-med", "M"),
}
_LA_MATH = C(_MAPHY + "katalog_LA_mathe_PO_2026.pdf", "2026", label="Modulkatalog Lehraemter Mathematik")
_LA_PHY = C(_MAPHY + "katalog_LA_physik_2026.pdf", "2026", label="Modulkatalog Lehraemter Physik")
# (Fach, Kontext-Anfang) -> Kataloge, Verlaufsplan
SUBJECT_CATS = {
    ("Biologie", "Fächerübergreifenden"): dict(
        cats=[C(_NAT + "Biologie/Detail-Biologie-FueBa/Modulkataloge/2026_Modulkatalog_FueBa_Biologie_WiSe26-27_draft.pdf", "WS 2026/27 (Entwurf)")],
        plan=_NAT + "Biologie/Detail-Biologie-FueBa/Studienverlaufsplan_FueBa/Studienverlaufsplan_FueBa_Erstfach_Biologie.pdf"),
    ("Biologie", "Masterstudiengang Lehramt an Gymnasien"): dict(
        cats=[C(_NAT + "Biologie/Detail-Biologie-MEd/Modulkataloge/2026_Modulkatalog_MEd_Biologie_WiSe26-27_draft.pdf", "WS 2026/27 (Entwurf)")],
        plan=_NAT + "Biologie/Detail-Biologie-MEd/Studienverlaufsplan/Studienverlaufsplan_MasterstudiengangLG.pdf"),
    ("Chemie", "Fächerübergreifenden"): dict(cats=[C(_NAT + "Chemie-Biochemie/Detail-Chemie-FueBa/Modulkatalog_FUEBA_Chemie.pdf", "aktuell")]),
    ("Erdkunde / Geographie", "Fächerübergreifenden"): dict(
        cats=[C(_NAT + "Geographie/Studiengangsuebergreifende_Dokumente/Modulkatalog_Bachelor_Geographie.pdf", "aktuell")]),
    ("Lebensmittelwissenschaft", "Bachelorstudiengang Technical Education"): dict(
        cats=[C(_NAT + "Lebensmittelwissenschaft/Detail-Lebensmittelwissens-TEd/___Modulkatalog-BA-Tec.Ed.-LMW_2026-10-01.pdf", "Stand 01.10.2026")],
        plan=_NAT + "Lebensmittelwissenschaft/Detail-Lebensmittelwissens-TEd/_Studienverlauf_Ba_april2026_.pdf"),
    ("Informatik", "Fächerübergreifenden"): dict(cats=[MK("L_BSc_EINF", label="Erstfach"), MK("L_BSc_ZINF", label="Zweitfach")]),
    ("Informatik", "Masterstudiengang Lehramt an Gymnasien"): dict(cats=[MK("L_MEd_EINF", label="Erstfach"), MK("L_MEd_ZINF", label="Zweitfach")]),
    ("Informatik", "Bachelorstudiengang Technical Education"): dict(cats=[MK("L_BSc_INF")]),
    ("Informatik", "Masterstudiengang Lehramt an berufsbildenden Schulen für"): dict(cats=[MK("L_MEd_Sp-INF")]),
    ("Informatik", "Masterstudiengang Lehramt an berufsbildenden Schulen"): dict(cats=[MK("L_MEd_INF")]),
    ("Elektrotechnik", "Bachelorstudiengang Technical Education"): dict(cats=[MK("L_BSc_ET")]),
    ("Elektrotechnik", "Masterstudiengang Lehramt an berufsbildenden Schulen für"): dict(cats=[MK("L_MEd_Sp_ET")]),
    ("Elektrotechnik", "Masterstudiengang Lehramt an berufsbildenden Schulen"): dict(cats=[MK("L_MEd_ET")]),
    ("Chemie", "Masterstudiengang Lehramt an Gymnasien"): dict(
        cats=[C(_NAT + "Chemie-Biochemie/Detail-Chemie-MEd/Modulhandbuch_MEd_LaG_Chemie.pdf", "aktuell")]),
    ("Chemie", "Bachelorstudiengang Technical Education"): dict(
        cats=[C(_NAT + "Chemie-Biochemie/Detail-Chemie-TEd/Modulkatalog_TE_LBS_Chemie.pdf", "aktuell")]),
    ("Chemie", "Masterstudiengang Lehramt an berufsbildenden Schulen"): dict(
        cats=[C(_NAT + "Chemie-Biochemie/Detail-Chemie-TEd/Modulkatalog_TE_LBS_Chemie.pdf", "aktuell")]),
    ("Erdkunde", "Masterstudiengang Lehramt an Gymnasien"): dict(
        cats=[C(_NAT + "Geographie/Studiengangsuebergreifende_Dokumente/Modulkatalog_Bachelor_Geographie.pdf", "aktuell")]),
    ("Lebensmittelwissenschaft", "Masterstudiengang Lehramt an berufsbildenden Schulen"): dict(
        cats=[C(_NAT + "Lebensmittelwissenschaft/Detail-Lebensmittelwissens-MEd/___Modulkatalog-MA-LBS-LMW_2026-10-01.pdf", "Stand 01.10.2026")],
        plan=_NAT + "Lebensmittelwissenschaft/Detail-Lebensmittelwissens-MEd/_Studienverlauf_Master_Lehramt_okt_2026_2.pdf"),
    ("Lebensmittelwissenschaft", "Masterstudiengang Lehramt an berufsbildenden Schulen für"): dict(
        cats=[C(_NAT + "Lebensmittelwissenschaft/Detail-Lebensmittelwissens-MEd-sprint/Modulkatalog-MA-LBS-Sprint_LMW.pdf", "aktuell")],
        plan=_NAT + "Lebensmittelwissenschaft/Detail-Lebensmittelwissens-MEd-sprint/Studienverlaufsplan_Master_LBS-Sprint_LMW.pdf"),
    ("Politikwissenschaft (Politik)", "Fächerübergreifenden"): dict(
        cats=[C(_IPW + "FUEBA_Pol_Modulkatalog_Stand_10_26.pdf", "WS 2026/27")], plan=_IPW + "FueBA_Pol_2026_MusterPlan_Erstfach.pdf"),
    ("Politikwissenschaft (Politik-Wirtschaft)", "Masterstudiengang Lehramt an Gymnasien"): dict(
        cats=[C(_IPW + "MA_LG_Pol_Wi_Modulkatalog_Stand_10_26.pdf", "WS 2026/27")], plan=_IPW + "MA_LG_2026_MusterPlan_Erstes_Fach.pdf"),
    ("Politikwissenschaft (Politik)", "Masterstudiengang Lehramt an berufsbildenden Schulen"): dict(
        cats=[C(_IPW + "MA_Lbs_Pol_Modulkatalog_Stand_10_26.pdf", "WS 2026/27")], plan=_IPW + "MA_LbS_Pol_2026_MusterPlan.pdf"),
    ("Politikwissenschaft (Politik)", "Masterstudiengang Lehramt an berufsbildenden Schulen für"): dict(
        cats=[C(_IPW + "MA_LBS-Sprint_Pol_Modulkatalog_Stand_10_26__1_.pdf", "WS 2026/27")],
        plan=_IPW + "MA_LbS_Sprint_2026_Pol_MusterPlan__1_.pdf"),
    ("Politikwissenschaft (Politik)", "Bachelorstudiengang Technical Education"): dict(
        cats=[C(_IPW + "BSc_TE_Pol_Modulkatalog_Stand_10_26.pdf", "WS 2026/27")], plan=_IPW + "BA_Tech_Edu_2026_MusterPlan.pdf"),
    ("Geschichte", ""): dict(cats=[C(_HIST + "Modulkatalog_LAG_FueBa_SoPaed.pdf", "aktuell",
                                     label="Modulkatalog Lehramt Gymnasium, FueBa, Sonderpaedagogik")]),
    ("Philosophie", "Fächerübergreifenden"): dict(
        cats=[C(_PHILOS + "Modulkataloge/Modulkatalog_Philosophie_Fu__BaMasterLGZertifikat_WiSe_2025.26_20250801.pdf", "ab 01.10.2025")],
        plan=_PHILOS + "Studienverlaufsplaene/Studienverlaufsplan_Erstfach_Philosophie_FueBa_Fachmaster_2026_01_21.pdf"),
    ("Philosophie", "Masterstudiengang Lehramt an Gymnasien"): dict(
        cats=[C(_PHILOS + "Modulkataloge/Modulkatalog_Philosophie_Fu__BaMasterLGZertifikat_WiSe_2025.26_20250801.pdf", "ab 01.10.2025")],
        plan=_PHILOS + "Studienverlaufsplaene/Studienverlaufsplan_Erstfach_Philosophie_FueBa_MasterLG_2026_01_21.pdf"),
    ("Werte und Normen", "Masterstudiengang Lehramt an Gymnasien"): dict(
        cats=[C(_PHILOS + "Modulkataloge/Modulkatalog_Werte_und_Normen_WiSe_2026.27.pdf", "ab 02.09.2026")],
        plan=_PHILOS + "Studienverlaufsplaene/Studienverlaufsplan_Erstfach_Werte_und_Normen_FueBa_MasterLG_2026_01_21.pdf"),
    ("Religionswissenschaft / Werte und Normen", "Fächerübergreifenden"): dict(
        cats=[C("https://www.irw.uni-hannover.de/fileadmin/rewi/studium/261001_Modulhandbuch_FueBA_Stand_Oktober_26.pdf", "Stand 10/2026")],
        plan="https://www.irw.uni-hannover.de/fileadmin/dvrw/Dateien/Verlaufsplaene.pdf"),
    ("Sport", ""): dict(cats=[C("https://www.sportwiss.uni-hannover.de/fileadmin/sportwiss/Modulhandbuch/Modulkatalog_Fach_Sport_WiSe2026-27.pdf",
                                "WS 2026/27", label="Modulkatalog der Lehramtsstudiengaenge Sport")]),
    ("Englisch", ""): dict(cats=[C("https://www.engsem.uni-hannover.de/fileadmin/engsem/Studium/Modulkatalog_Fach_Englisch_WiSe2025-26.pdf",
                                   "WS 2025/26")]),
    ("Englisch", "Fächerübergreifenden"): dict(
        cats=[C("https://www.engsem.uni-hannover.de/fileadmin/engsem/Studium/Modulkatalog_Fach_Englisch_WiSe2025-26.pdf", "WS 2025/26")],
        plan="https://www.engsem.uni-hannover.de/fileadmin/engsem/Studium/Studienverlauf_2_Fach_Englisch_WS_2526.pdf"),
    ("Mathematik", ""): dict(cats=[_LA_MATH]),
    ("Physik", ""): dict(cats=[_LA_PHY]),
}


def subject_info(name: str) -> tuple[str, str] | None:
    m = re.match(r"^(.*?) im (.*)$", name)
    return (m.group(1), m.group(2)) if m else None


def subject_cats(subj: str, ctx: str) -> dict:
    best, blen = {}, -1
    for (s, c), v in SUBJECT_CATS.items():
        if s == subj and ctx.startswith(c) and len(c) > blen:
            best, blen = v, len(c)
    return best


# ---------------------------------------------------------------------------------------------------------------
# Pruefungsordnungen je Studiengang aus den Ordnungen-Seiten
# ---------------------------------------------------------------------------------------------------------------

_DATE = re.compile(r"(\d{1,2})\.\s?(\d{1,2})\.\s?(\d{4})")  # erstes Datum = Fassung der Ordnung


def current_pos(ordn: dict | None, with_untitled: bool = False) -> list[dict]:
    """Pruefungsordnungen der Ordnungen-Seite (keine auslaufenden, Uebersetzungen, Praktikumsordnungen).
    Ohne Titel stehen meist aeltere Fassungen (titled=False)."""
    out = []
    if not ordn:
        return out
    for d in ordn["docs"]:
        h, t = (d["heading"] or ""), (d["title"] or "")
        if t.lower().startswith("download"):
            t = ""
        if "praktikum" in (h + t + d["url"]).lower() or "englische_uebersetzungen" in d["url"]:
            continue
        if any(x in h + t for x in ("Auslaufend", "English", "Translation", "translation", "Zwischenprüf", "Schwerpunkt",
                                    "Entgelt", "Gebühr", "Studienordnung", "Diplom")):
            continue
        if "rüfungsordnung" not in h and "rüfungsordnung" not in t and h:
            continue
        if not t and not with_untitled:
            continue
        m = _DATE.search(t)
        year = m.group(3) if m else None
        if t and not year:  # Titel ohne Datum: Jahr aus dem Dateinamen
            fy = re.search(r"(20[0-3]\d)", d["url"].rsplit("/", 1)[-1])
            year = fy.group(1) if fy else None
        out.append({"title": t, "url": d["url"], "base_year": year, "titled": bool(t)})
    seen, uniq = set(), []
    for p in out:
        if p["url"] not in seen:
            seen.add(p["url"])
            uniq.append(p)
    return uniq


def other_docs(ordn: dict | None) -> dict:
    """Studienordnung und Praktikumsordnung als Zusatz."""
    res = {}
    for d in (ordn or {}).get("docs", []):
        h, t = (d["heading"] or ""), (d["title"] or "")
        if "Studienordnung" in h and "studienordnung" not in res:
            res["studienordnung"] = d["url"]
        if "raktikum" in (h + t) and "praktikumsordnung" not in res and "englische" not in d["url"]:
            res["praktikumsordnung"] = d["url"]
    return res


def _file_has_year(url: str, year: str) -> bool:
    f = url.rsplit("/", 1)[-1].lower()
    return year in f or bool(re.search(rf"[bm]po_?{year[2:]}(?![0-9])", f))


def split_by_po(cats: list[dict], pos: list[dict]) -> list[tuple[str | None, list[dict], list[dict]]]:
    """Eintraege je PO: (po, Kataloge, PO-Dokumente). Kataloge mit po=None gehoeren zur neuesten PO.
    Zuordnung der Dokumente: gleiche Fassung (Jahr im Titel), sonst Jahr im Dateinamen (auch ohne Titel),
    uebrige betitelte Dokumente der Reihe nach an Gruppen ohne Dokument."""
    titled = [p for p in pos if p["titled"]]
    years = sorted({c["po"] for c in cats if c.get("po")}, reverse=True)
    if not years:
        newest = max((p["base_year"] for p in titled if p["base_year"]), default=None)
        return [(newest, cats, titled)]
    groups = {y: [c for c in cats if c.get("po") == y] for y in years}
    for c in cats:
        if not c.get("po"):
            groups[years[0]].append(c)
    docs = {y: [] for y in years}
    used = set()
    for p in titled:
        if p["base_year"] in docs:
            docs[p["base_year"]].append(p)
            used.add(p["url"])
    for y in years:
        if not docs[y]:
            for p in pos:
                if p["url"] not in used and _file_has_year(p["url"], y):
                    docs[y].append(p)
                    used.add(p["url"])
                    break
    rest = sorted([p for p in titled if p["url"] not in used], key=lambda p: p["base_year"] or "0", reverse=True)
    free = [y for y in years if not docs[y]]
    for y, p in zip(free, rest):
        docs[y].append(p)
    for p in rest[len(free):]:
        docs[years[0]].append(p)
    return [(y, groups[y], docs[y]) for y in years]


# ---------------------------------------------------------------------------------------------------------------
# Schritt modkat: Kuerzel und neuestes Semester aus der modkat-Uebersicht
# ---------------------------------------------------------------------------------------------------------------

def step_modkat(network: bool = True) -> list[dict]:
    fetch(MODKAT_DBS, network=network)       # Hauptadresse laut Spezifikation (am 04.11.2026 nicht erreichbar)
    out, label = [], None
    for h, t in links(MODKAT_HOME, network):
        if "/v2/main/search/" in h and t and not t.startswith("Alle"):
            label = t
        m = re.search(r"/material/modkat-full-(.+)-(WS_\d{4}_\d{2}|SS_\d{4})\.pdf$", h)
        if m:
            term = m.group(2)
            term_h = (f"WS {term[3:7]}/{term[8:10]}" if term.startswith("WS") else f"SS {term[3:7]}")
            out.append({"code": m.group(1), "term": term_h, "file_term": term, "label": label, "url": norm_url(h)})
    return out


# ---------------------------------------------------------------------------------------------------------------
# Register bauen
# ---------------------------------------------------------------------------------------------------------------

def _ordnungen_map() -> dict:
    f = CRAWL / "ordnungen.json"
    R = json.loads(f.read_text()) if f.exists() else step_ordnungen(False)
    return {r["url"].rstrip("/").split("/")[-2]: r for r in R}


def _slugify(s: str) -> str:
    s = s.lower().replace("ä", "ae").replace("ö", "oe").replace("ü", "ue").replace("ß", "ss")
    return re.sub(r"[^a-z0-9.]+", "-", s).strip("-")


DEG_LONG = {"B.Sc.": "Bachelor of Science", "B.A.": "Bachelor of Arts", "M.Sc.": "Master of Science",
            "M.A.": "Master of Arts", "M.Ed.": "Master of Education", "LL.B.": "Bachelor of Laws",
            "LL.M.": "Master of Laws"}


def parent_name(ctx: str) -> str:
    """'Masterstudiengang Lehramt an Gymnasien' -> 'Lehramt an Gymnasien', 'Fächerübergreifenden Bachelor' -> ..."""
    n = re.sub(r"^(Masterstudiengang|Bachelorstudiengang)\s+", "", ctx)
    return n.replace("Fächerübergreifenden Bachelor", "Fächerübergreifender Bachelor")


def qis_labels(program: str, degree: str, po: str | None, parent: str | None = None) -> list[str]:
    """Geratene Schreibweisen der QIS-Spalte "abschluss" (Notenspiegel), z. B. "Technische Informatik (PO-Version 2017)".
    Bei Faechern zaehlt in QIS der Gesamtstudiengang (z. B. "Fächerübergreifender Bachelor (PO-Version 2016)")."""
    labs = []
    names = [parent_name(parent), program.split(" im ")[0]] if parent else [program]
    for nm in names:
        if po:
            labs += [f"{nm} (PO-Version {po})", f"{nm} (PO {po})"]
    first = degree.split("/")[0]
    if first in DEG_LONG and not parent:
        labs.append(f"{DEG_LONG[first].split(' of ')[0]} {program}")
    labs += names
    return list(dict.fromkeys(labs))


def default_semesters(degree: str, kind: str) -> tuple[int | None, int | None]:
    d = degree.split("/")[0]
    if d.startswith("B") or d == "LL.B.":
        return 6, (None if kind == "fach" else 180)
    if d in ("M.Sc.", "M.A.", "M.Ed.", "LL.M."):
        return 4, (None if kind == "fach" else 120)
    if d == "Staatsexamen":
        return 10, None
    return None, None


def steckbrief_rsz(url: str) -> int | None:
    """Regelstudienzeit aus der Studiengangsseite, nur wenn sie schon im Zwischenspeicher liegt."""
    t = read_text(url, network=False)
    m = re.search(r"Regelstudienzeit\s+(\d{1,2})\s+Semester", html_text(t)) if t else None
    return int(m.group(1)) if m else None


def build_registry(network: bool = False) -> dict:
    A = step_list(network)
    ORD = _ordnungen_map()
    MOD = {m["code"]: m for m in step_modkat(network)}
    formats = load_formats()
    programs = []

    def catalog_obj(c: dict | None) -> dict:
        if not c:
            return {"url": None, "term": None, "format": "none"}
        f = formats.get(c["url"], {})
        o = {"url": c["url"], "term": c["term"], "format": f.get("format", "unknown" if f else "not-downloaded")}
        if c.get("label"):
            o["label"] = c["label"]
        if f.get("pages"):
            o["pages"] = f["pages"]
        if f.get("modules_est") is not None:
            o["modules_est"] = f["modules_est"]
        return o

    def add(slug, program, degree, faculty, kind, program_page, start, ordslugs, cats, plan, listed, parent=None):
        ordslugs = [ordslugs] if isinstance(ordslugs, str) else (ordslugs or [])
        pos, extra, ord_pages = [], {}, []
        for o in ordslugs:
            r = ORD.get(o)
            if r:
                ord_pages.append(r["url"])
                pos += current_pos(r, with_untitled=True)
                for k, v in other_docs(r).items():
                    extra.setdefault(k, v)
        sem, lp = default_semesters(degree, kind)
        sem_src = "regel"
        rsz = steckbrief_rsz(program_page) if program_page else None
        if rsz:
            sem, sem_src = rsz, "steckbrief"
            if lp and degree.startswith("B"):
                lp = 30 * sem
        for po, cs, docs in split_by_po(cats or [], pos):
            primary = cs[0] if cs else None
            mk = next((c.get("modkat_code") for c in cs if c.get("modkat_code")), None)
            e = {
                "key": f"luh|{slug}|{_slugify(degree)}|{po or 'unbekannt'}",
                "university": "luh",
                "program": program,
                "degree": degree,
                "kind": kind,
                "faculty": FAC[faculty] if faculty in FAC else faculty,
                "listed": listed,
                "po": po,
                "po_documents": [{"title": d["title"] or None, "url": d["url"]} for d in docs],
                "catalog": catalog_obj(primary),
                "more_catalogs": [catalog_obj(c) for c in cs[1:]],
                "study_plan_url": plan,
                "program_page": program_page,
                "ordnungen_page": ord_pages[0] if ord_pages else None,
                "start_terms": start,
                "regular_semesters": sem,
                "regular_semesters_source": sem_src if sem else None,
                "total_lp": lp,
                "qis_labels": qis_labels(program, degree, po, parent),
            }
            if mk:
                e["modkat_code"] = mk
                e["modkat_term"] = MOD.get(mk, {}).get("term")
            if extra.get("studienordnung"):
                e["studienordnung_url"] = extra["studienordnung"]
            if parent:
                e["parent_program"] = parent
            programs.append(e)

    for a in A:
        degree = "/".join(d for d in a["degrees"] if d != "Double Degree") or "Zertifikat"
        if "Double Degree" in a["degrees"]:
            degree += " (Double Degree)" if degree else "Double Degree"
        start = [("WS" if "Winter" in s else "SS") for s in a["start"].split(",") if "semester" in s.lower()]
        if a["kind"] == "Fach im 2-Fächer Studiengang":
            subj, ctx = subject_info(a["name"])
            o, _ = next(((v[0], v[1]) for k, v in sorted(CONTEXT_ORD.items(), key=lambda kv: -len(kv[0]))
                         if ctx.startswith(k)), (None, None))
            sc = subject_cats(subj, ctx)
            add(a["slug"], a["name"], degree, SUBJECT_FAC.get(subj, "phil"), "fach", a["program_page"], start,
                o, sc.get("cats"), sc.get("plan"), True, parent=ctx)
            continue
        meta = P.get(a["slug"])
        if meta is None:
            raise SystemExit(f"kein Eintrag in P fuer {a['slug']}")
        kind = "vertiefung" if a["kind"] == "Vertiefungsrichtung" else "studiengang"
        add(a["slug"], a["name"], degree, meta["fac"], kind, a["program_page"], start, meta.get("ord"),
            meta.get("cats"), meta.get("plan"), True)
    for oslug, meta in UNLISTED.items():
        add(oslug, meta["name"], meta["deg"], meta["fac"], "studiengang", None, [], oslug, meta.get("cats"),
            meta.get("plan"), False)
    programs.sort(key=lambda p: p["key"])
    return {
        "v": 1,
        "university": "luh",
        "generated": "2026-11-04",
        "generator": "tools/luh-programs.py",
        "note": "Verbindlich ist immer die Pruefungsordnung der Hochschule. Quellen: Studienangebot A-Z, "
                "Pruefungsinfos/Ordnungen, Fakultaetsseiten, modkat der FEI (nur oeffentliche Seiten).",
        "sources": {
            "studienangebot": AZ_URL,
            "ordnungen": "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/<studiengang>/ordnungen",
            "modkat": MODKAT_HOME,
            "modkat_pattern": "https://modkat.fei.uni-hannover.de/material/modkat-full-<CODE>-<WS_JJJJ_JJ|SS_JJJJ>.pdf",
        },
        "formats": FORMATS,
        "modkat_codes": sorted(MOD.values(), key=lambda m: m["code"]),
        "programs": programs,
    }


# ---------------------------------------------------------------------------------------------------------------
# Schritt pdfs: Modulhandbuecher laden und Format bestimmen
# ---------------------------------------------------------------------------------------------------------------

FORMATS = {
    "modkat-FEI": "Datenbank-PDF der FEI (modkat): je Modul Block mit Zustaendigkeit, Einordnung, Angebot, Pruefungsform, "
                  "Studienleistung, Sprache, Studentische Arbeitsleistung, SWS, LP (ECTS), Modulverantwortung, "
                  "Qualifikationsziele; Parser vorhanden",
    "mb-modulkatalog": "Maschinenbau (Datenbank): Seitenkopf 'Modul: <Titel>' / 'Module: <englisch>', Felder Modultyp, "
                       "Kompetenzbereich, Angebot im, Dauer, Sprache, ECTS, Empfohlen ab, Pruefungsleistungen (PL) / "
                       "Studienleistung (SL), Workload, Modulverantwortliche-r",
    "luh-modulbeschreibung": "LUH-Vorlage Modulbeschreibung: Kopfblock Modultitel, Kennnummer / Pruefcode, Studiengang, "
                             "Modultyp, Leistungspunkte, Haeufigkeit des Angebots, Sprache, Kompetenzbereich, Empfohlenes "
                             "Fachsemester, Moduldauer, Studentische Arbeitsbelastung, Weitere Verwendung; danach "
                             "nummerierte Abschnitte 1 Qualifikationsziele, 2 Inhalte, 3 Lehrformen, "
                             "4a Teilnahmevoraussetzungen, 4b Empfehlungen, 5 Voraussetzungen fuer die Vergabe von "
                             "Leistungspunkten (Studien-/Pruefungsleistungen), 6 Literatur",
    "maphy-katalog": "Mathematik/Physik: je Modul Titel, Semesterlage, Verantwortlich, Art der Lehrveranstaltung(en), "
                     "Lehrveranstaltungen (SWS), Leistungsnachweise (Studienleistung/Pruefungsleistung), "
                     "Notenzusammensetzung, Leistungspunkte (ECTS), Kompetenzziel, Inhalte, Modulverwendbarkeit",
    "fbg-modulhandbuch": "Bauingenieurwesen (Datenbank): je Modul Titel deutsch/englisch, 'Moegl. Pruefungsleistungen: "
                         "K/KA/MP...', 'Studienleistungen', SWS / Art, Sprache, LP, Semester, P-Form VbP/PZ I/PZ II, "
                         "Ziel des Moduls, Inhalt des Moduls (englische Fassung: Possible forms of examination, CP)",
    "wiwi-modulhandbuch": "Wirtschaftswissenschaften (Datenbank, je Semester): Verwendbarkeit/Art/Semester von-bis, "
                          "Leistungspunkte (ECTS), Workload in h, Modulverantwortung, Qualifikationsziele, "
                          "'Pruefungsleistung im <Semester>', Pruefungsnummer, Pruefungsform (und -dauer), Belegnr.",
    "phil-kv-tabelle": "Institute der Philosophischen Fakultaet: zweispaltige Tabelle je Modul mit Anbieter, "
                       "Modulverantwortliche/r, Haeufigkeit des Angebots, Dauer des Moduls, Semesterlage, "
                       "Verwendbarkeit, ECTS-LP/Workload, Pruefungsleistungen, Studienleistungen",
    "overview-only": "nur Uebersicht/Curriculum, keine Modulbeschreibungen",
    "scanned": "ohne Textebene: Word-Export, in dem jedes Wort als Bild gezeichnet ist (pypdf und PDFKit liefern "
               "keinen Text, die Seite sieht normal aus); optisch meist LUH-Vorlage oder Institutstabelle, OCR noetig "
               "(z. B. Vision auf dem Geraet)",
    "unknown": "nicht zugeordnet",
    "not-downloaded": "nicht geladen (Anfragegrenze oder Fehler)",
    "none": "kein oeffentliches Modulhandbuch gefunden",
}

FORMATS_FILE = CRAWL / "formats.json"
LABELS = ["Leistungspunkte", "LP", "ECTS", "Semesterlage", "Semester", "Prüfungsleistung", "Studienleistung", "Turnus",
          "Angebotsturnus", "Häufigkeit", "Modulverantwortlich", "Arbeitsaufwand", "Workload", "Präsenzzeit",
          "Selbststudium", "Qualifikationsziele", "Kompetenzziele", "Lernziele", "Inhalte", "Lehrinhalte",
          "Voraussetzungen", "Teilnahmevoraussetzung", "Kennnummer", "Modulnummer", "Modulcode", "Modulkürzel",
          "Dauer", "Sprache", "Lehrform", "Lehrveranstaltungen", "Literatur", "Verwendbarkeit", "Prüfungsform",
          "Credits", "Notenzusammensetzung", "Prüfungsnummer"]


def load_formats() -> dict:
    return json.loads(FORMATS_FILE.read_text()) if FORMATS_FILE.exists() else {}


def _cnt(pat: str, text: str) -> int:
    return len(re.findall(pat, text))


def classify(url: str, path: str, faculty_key: str | None = None) -> dict:
    """Format nach wiedererkennbaren Feldnamen, Modulzahl nach dem Feld, das je Modul genau einmal vorkommt."""
    try:
        text, n = pdf_text(path)
    except Exception as ex:  # kaputte PDF
        return {"format": "unknown", "error": str(ex)[:200]}
    pages = text.split("\f")
    avg = sum(len(p.strip()) for p in pages) / max(1, len(pages))
    counts = {lab: _cnt(r"(?<![A-Za-zÄÖÜäöü])" + re.escape(lab) + r"(?![a-zäöü])", text) for lab in LABELS}
    mb_titles = set(re.findall(r"\nModul: (.+)\nModule: ", text))
    f = {
        "modkat": _cnt(r"Modulverantwortung", text),
        "mb": len(mb_titles),
        "fbg": _cnt(r"Mögl(\.|iche)\s*Prüfungsleistungen|Possible forms of examination", text),
        "wiwi": max(_cnt(r"Workload in h", text), _cnt(r"Qualifikationsziele", text) if _cnt(r"Belegnr\.", text) >= 3 else 0),
        "maphy": _cnt(r"Notenzusammensetzung", text),
        "maphy_mod": _cnt(r"\nSemesterlage ", text),
        "luh": _cnt(r"Häufigkeit des Angebots|Frequency of Occurrence", text),
        "luh_head": _cnt(r"Kennnummer|Modultitel|Empfohlenes Fachsemester|Moduldauer|Module Title|Module Duration", text),
        "kv": _cnt(r"(?<![a-z])Anbieter", text),
    }
    rsz = re.search(r"Regelstudienzeit[^\d]{0,40}(\d{1,2})\s*Semester", text)
    strong = max(v for k, v in f.items() if k != "luh_head")
    if "modkat.fei" in url:
        fmt, mods = "modkat-FEI", f["modkat"]
    elif avg < 300 and strong < 3:
        fmt, mods = "scanned", 0
    elif f["mb"] >= 3:
        fmt, mods = "mb-modulkatalog", f["mb"]
    elif f["fbg"] >= 3:
        fmt, mods = "fbg-modulhandbuch", f["fbg"]
    elif f["luh"] >= 2 and f["luh_head"] >= 2:
        fmt, mods = "luh-modulbeschreibung", f["luh"]
    elif f["wiwi"] >= 3:
        fmt, mods = "wiwi-modulhandbuch", f["wiwi"]
    elif f["maphy"] >= 3:
        fmt, mods = "maphy-katalog", max(f["maphy_mod"], f["maphy"])
    elif f["kv"] >= 3:
        fmt, mods = "phil-kv-tabelle", f["kv"]
    else:
        per = sorted(counts[k] for k in ("Modulverantwortlich", "Qualifikationsziele", "Prüfungsleistung") if counts[k])
        mods = per[len(per) // 2] if per else 0
        fmt = "overview-only" if mods < 3 else "unknown"
    return {"format": fmt, "pages": n, "avg_chars": round(avg), "modules_est": mods, "features": f,
            "labels": {k: v for k, v in counts.items() if v}, "rsz": int(rsz.group(1)) if rsz else None,
            "head": re.sub(r"\s+", " ", text[:400])}


def step_reclassify(network: bool = False) -> int:
    """Alle geladenen PDFs neu einordnen (ohne Anfragen)."""
    F = load_formats()
    for u, old in F.items():
        e = fetch(u, network=False)
        if e and e.get("path", "") and e["path"].endswith(".pdf"):
            F[u] = classify(u, e["path"])
    FORMATS_FILE.write_text(json.dumps(F, ensure_ascii=False, indent=1))
    return 0


def pdf_queue() -> list[tuple[str, str | None]]:
    """Alle Katalog-URLs: Nicht-FEI zuerst (Hauptkatalog vor Zusatzkatalogen), FEI zuletzt."""
    reg = build_registry(False)
    fac_key = {v: k for k, v in FAC.items()}
    first, second, fei = [], [], []
    for p in reg["programs"]:
        fk = fac_key.get(p["faculty"])
        for i, c in enumerate([p["catalog"]] + p["more_catalogs"]):
            u = c.get("url")
            if not u:
                continue
            item = (u, fk)
            tgt = fei if "modkat.fei" in u else (first if i == 0 else second)
            if all(u != x[0] for x in first + second + fei):
                tgt.append(item)
    return first + second + fei


def step_pdfs(network: bool = True, limit_fei: int = 99) -> int:
    F = load_formats()
    q = pdf_queue()
    n_fei = 0
    for u, fk in q:
        if "modkat.fei" in u:
            if n_fei >= limit_fei and u not in F:
                continue
            n_fei += 1
        if u in F and (F[u].get("pages") or F[u].get("status")):
            continue
        try:
            e = fetch(u, network=network)
        except Budget:
            print("STOP: Anfragegrenze", file=sys.stderr)
            break
        if not e or not e.get("path"):
            F[u] = {"format": "not-downloaded", "status": (e or {}).get("status")}
        elif not e["path"].endswith(".pdf"):
            F[u] = {"format": "unknown", "note": "keine PDF"}
        else:
            F[u] = classify(u, e["path"])
        FORMATS_FILE.write_text(json.dumps(F, ensure_ascii=False, indent=1))
    # FEI-Kataloge, die nicht geladen wurden: Format aus dem bekannten Aufbau (gleiche Datenbank)
    for u, fk in q:
        if "modkat.fei" in u and u not in F:
            F[u] = {"format": "modkat-FEI", "note": "nicht geladen, Aufbau aus modkat bekannt"}
    FORMATS_FILE.write_text(json.dumps(F, ensure_ascii=False, indent=1))
    return 0


def step_build(network: bool = False) -> int:
    reg = build_registry(network)
    OUT_JSON.write_text(json.dumps(reg, ensure_ascii=False, indent=1) + "\n")
    print(f"{len(reg['programs'])} Eintraege -> {OUT_JSON.relative_to(ROOT)}")
    return 0


def step_check(network: bool = True) -> int:
    """Wartung: Modulhandbuch-Links auf den Suchseiten, die noch in keinem Eintrag stehen (z. B. neues Semester)."""
    known = set()
    for p in build_registry(False)["programs"]:
        for c in [p["catalog"]] + p["more_catalogs"]:
            if c.get("url"):
                known.add(c["url"])
    hits = 0
    for u in DISCOVERY_PAGES + FACULTY_PAGES:
        for h, t in links(u, network):
            h = norm_url(h.split("#")[0])
            if h.lower().endswith(".pdf") and re.search(r"modul(katalog|handbuch|kataloge|beschreib)|katalog_", h, re.I) \
                    and h not in known and "semesterangebot" not in h and "jahresliste" not in h:
                hits += 1
                print(f"nicht im Register: {h}  ({t[:50]})  <- {u}")
    print(f"{hits} Hinweise", file=sys.stderr)
    return 0


def step_all(network: bool = True) -> int:
    """Kompletter Lauf; mit gefuelltem Zwischenspeicher ohne eine einzige neue Anfrage."""
    step_list(network)
    R = step_ordnungen(network)
    (CRAWL / "ordnungen.json").write_text(json.dumps(R, ensure_ascii=False, indent=1))
    for u in FACULTY_PAGES + DISCOVERY_PAGES:
        fetch(u, network=network)
    step_modkat(network)
    step_pdfs(network)
    return step_build(False)


STEPS = {"modkat": lambda net: print(json.dumps(step_modkat(net), indent=1)) or 0,
         "pdfs": step_pdfs, "reclassify": step_reclassify, "build": step_build, "check": step_check,
         "all": step_all}


def PIPELINE(cmd: str) -> int:
    net = "--offline" not in sys.argv
    if cmd == "list":
        L = step_list(net)
        print(json.dumps(L[:3], ensure_ascii=False, indent=1), len(L))
    elif cmd == "ordnungen":
        R = step_ordnungen(net)
        (CRAWL / "ordnungen.json").write_text(json.dumps(R, ensure_ascii=False, indent=1))
        print(len(R), sum(len(r["docs"]) for r in R))
    elif cmd in STEPS:
        return STEPS[cmd](net) or 0
    else:
        raise SystemExit(f"unbekannt: {cmd}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

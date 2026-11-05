"""Modulhandbuecher, Pruefungsordnungen und Studienverlaufsplaene der Hochschule Hannover (HsH) einsammeln: Grundlage
der HsH-Bibliothek (tools/build-hsh-seed.py, Bericht docs/STUDIENGAENGE-HSH-2026-11-05.md; Auftrag des Inhabers
05.11.2026 "die gleiche Bibliothek wie fuer die LUH").

Quellen: nur oeffentliche Seiten und PDFs der HsH-Webseite (www.hs-hannover.de, f1..f5.hs-hannover.de). Das
Campusmanagement (HISinOne, campusmanagement.hs-hannover.de) sperrt Crawler mit robots.txt vollstaendig
("User-agent: * / Disallow: /", gelesen 05.11.2026) und wird deshalb NIE angefragt, auch nicht die oeffentlichen
Modulbeschreibungen dort (siehe Bericht, Abschnitt "HISinOne").

Hoeflich gegenueber den Servern der Hochschule:
- robots.txt je Rechner vor der ersten Anfrage (RFC 9309, wie tools/hsh-programs.py; die HsH erlaubt in /fileadmin/
  ausschliesslich PDFs und sperrt Archivordner);
- hoechstens eine Anfrage je 2,5 Sekunden, nacheinander, User-Agent "StudiNow-Katalogpruefung/1.0 (support@studinow.app)";
- jede Antwort liegt im Zwischenspeicher ~/Studora-Builds/hsh-catalog/ (cache/ + index.json), dieselbe URL wird nie
  zweimal geholt (auch nicht nach einem Fehler); was der Register-Lauf (tools/hsh-programs.py, ~/Studora-Builds/hsh/crawl)
  schon geholt hat, wird von dort gelesen (0 Anfragen); ein zweiter Lauf arbeitet nur aus dem Zwischenspeicher;
- Obergrenze 1500 Anfragen insgesamt, die des Register-Laufs mitgezaehlt (Zaehler in index.json, ueber alle Laeufe),
  Protokoll in index.json["log"].

Aufruf im Projektordner:
  .venv/bin/python tools/hsh-catalogs.py crawl      # Seiten und PDFs holen (nur was fehlt), Liste schreiben
  .venv/bin/python tools/hsh-catalogs.py list       # nur aus dem Zwischenspeicher: gefundene Dokumente
  .venv/bin/python tools/hsh-catalogs.py count      # Anfragen bisher
Werkzeuge zum Nachsehen: fetch URL, links URL [Muster], text URL [Seiten].

Die Liste der Dokumente (~/Studora-Builds/hsh-catalog/documents.json) liest tools/build-hsh-seed.py.
"""
from __future__ import annotations

import hashlib
import html
import importlib.util
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UA = "StudiNow-Katalogpruefung/1.0 (support@studinow.app)"
BASE = Path(os.environ.get("HSH_CATALOG") or os.path.expanduser("~/Studora-Builds/hsh-catalog"))
CACHE = BASE / "cache"
INDEX = BASE / "index.json"
DOCS = BASE / "documents.json"
# Zwischenspeicher des Register-Laufs (nur lesen)
BORROW = Path(os.environ.get("HSH_CRAWL") or os.path.expanduser("~/Studora-Builds/hsh/crawl"))
MAX_REQUESTS = 1500
DELAY = 2.5
ALLOWED_HOST = re.compile(r"^(www|f[1-5])\.hs-hannover\.de$")
FORBIDDEN_PATH = re.compile(r"(/login|shibboleth|/saml|/sso|/auth/|typo3/|/admin|^/intranet|^/qisserver|^/moodle|"
                            r"/webmail|^/accounts)", re.I)
FACULTIES = ("f1", "f2", "f3", "f4", "f5")


def _load_programs_module():
    spec = importlib.util.spec_from_file_location("hsh_programs", ROOT / "tools" / "hsh-programs.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


HP = _load_programs_module()


class Budget(Exception):
    pass


_IDX: dict | None = None
_BORROWED: dict | None = None
_ROBOTS: dict = {}
_LAST = [0.0]
NETWORK = [True]


def idx() -> dict:
    global _IDX
    if _IDX is None:
        CACHE.mkdir(parents=True, exist_ok=True)
        _IDX = json.loads(INDEX.read_text()) if INDEX.exists() else {"requests": 0, "urls": {}, "robots": {}, "log": []}
    return _IDX


def borrowed() -> dict:
    global _BORROWED
    if _BORROWED is None:
        p = BORROW / "index.json"
        try:
            _BORROWED = json.loads(p.read_text()) if p.exists() else {"urls": {}, "robots": {}}
        except (OSError, ValueError):
            _BORROWED = {"urls": {}, "robots": {}}
    return _BORROWED


def save_index() -> None:
    tmp = INDEX.with_suffix(".tmp")
    tmp.write_text(json.dumps(idx(), ensure_ascii=False, indent=1))
    tmp.replace(INDEX)


norm_url = HP.norm_url


def allowed(url: str) -> bool:
    p = urllib.parse.urlsplit(url)
    return p.scheme == "https" and bool(ALLOWED_HOST.match(p.netloc)) and not FORBIDDEN_PATH.search(p.path)


def _raw_get(url: str) -> tuple[int, str, bytes, str]:
    ix = idx()
    if ix["requests"] + int(borrowed().get("requests") or 0) >= MAX_REQUESTS:
        raise Budget(f"Obergrenze {MAX_REQUESTS} Anfragen erreicht (mit den Anfragen des Register-Laufs)")
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
        with urllib.request.urlopen(req, timeout=90) as r:  # noqa: S310 - nur erlaubte Rechner (allowed)
            status, ctype, body, final = r.status, r.headers.get("Content-Type", ""), r.read(), r.geturl()
    except urllib.error.HTTPError as e:
        status, ctype, body, final = e.code, e.headers.get("Content-Type", "") if e.headers else "", b"", url
    except Exception as e:  # noqa: BLE001  Netz, Zeitueberschreitung
        status, ctype, body, final = -1, "", str(e).encode(), url
    ix["log"].append({"t": t0, "url": url, "status": status, "bytes": len(body)})
    save_index()
    print(f"  [{ix['requests']:4d}] {status} {url}", file=sys.stderr)
    return status, ctype, body, final


def robots_ok(url: str) -> bool:
    host = urllib.parse.urlsplit(url).netloc
    if host not in _ROBOTS:
        rurl = f"https://{host}/robots.txt"
        info = idx()["robots"].get(rurl) or borrowed().get("robots", {}).get(rurl)
        if info is None:
            if not NETWORK[0]:
                return False
            status, _, body, _ = _raw_get(rurl)
            info = {"status": status, "text": body.decode("utf-8", "replace") if status == 200 else ""}
            idx()["robots"][rurl] = info
            save_index()
        _ROBOTS[host] = HP.Robots(info["text"], UA) if info["status"] == 200 else None
    rp = _ROBOTS[host]
    return True if rp is None else rp.allowed(url)


def lookup(url: str) -> tuple[dict, Path] | None:
    """Eintrag aus dem eigenen oder dem geliehenen Zwischenspeicher"""
    e = idx()["urls"].get(url)
    if e is not None:
        return e, BASE
    e = borrowed().get("urls", {}).get(url)
    if e is not None and (not e.get("path") or (BORROW / e["path"]).exists()):
        if e.get("fetched_at") is None:
            # der Register-Lauf merkt sich die Zeit nur im Protokoll
            t = next((x["t"] for x in borrowed().get("log", []) if x.get("url") == url), None)
            e = {**e, "fetched_at": int(t) if t else None}
        return e, BORROW
    return None


def fetch(url: str) -> dict | None:
    """{status, ctype, path(absolut), final}; None = nicht erlaubt oder kein Netz"""
    url = norm_url(url)
    hit = lookup(url)
    if hit:
        e, base = hit
        return {**e, "abs": str(base / e["path"]) if e.get("path") else None}
    if not NETWORK[0] or not allowed(url):
        return None
    ix = idx()
    if not robots_ok(url):
        ix["urls"][url] = {"status": "robots", "ctype": "", "path": None, "final": url}
        save_index()
        return {**ix["urls"][url], "abs": None}
    status, ctype, body, final = _raw_get(url)
    path = None
    if status == 200:
        ext = ".pdf" if (b"%PDF" in body[:1024] or "pdf" in ctype) else ".html"
        name = hashlib.sha1(url.encode()).hexdigest()[:16] + ext
        (CACHE / name).write_bytes(body)
        path = "cache/" + name
    entry = {"status": status, "ctype": ctype, "path": path, "final": norm_url(final), "size": len(body),
             "sha256": hashlib.sha256(body).hexdigest() if status == 200 else None, "fetched_at": int(time.time())}
    ix["urls"][url] = entry
    save_index()
    return {**entry, "abs": str(BASE / path) if path else None}


def read_text(url: str) -> str | None:
    e = fetch(url)
    if not e or not e.get("abs") or str(e["abs"]).endswith(".pdf"):
        return None
    return Path(e["abs"]).read_bytes().decode("utf-8", "replace")


def links(url: str) -> list[tuple[str, str]]:
    txt = read_text(url)
    return HP.page_links(txt, fetch(url)["final"]) if txt is not None else []


TEXT = BASE / "text"


def pdf_pages_cached(path: str | Path, sha: str | None = None) -> list[str]:
    """Seitentexte einer PDF (pypdf wie app.study_catalog.pdf_pages), einmal je Inhalt in text/<sha256>.json gemerkt"""
    p = Path(path)
    data = p.read_bytes()
    sha = sha or hashlib.sha256(data).hexdigest()
    TEXT.mkdir(parents=True, exist_ok=True)
    f = TEXT / f"{sha}.json"
    if f.exists():
        try:
            return json.loads(f.read_text())
        except ValueError:
            pass
    sys.path.insert(0, str(ROOT))
    from app.study_catalog import pdf_pages
    try:
        pages = pdf_pages(data)
    except Exception:  # noqa: BLE001  kaputte PDF
        pages = []
    f.write_text(json.dumps(pages, ensure_ascii=False))
    return pages


def documents() -> dict:
    """Liste des letzten Laufs (documents.json), leer ohne"""
    try:
        return json.loads(DOCS.read_text())
    except (OSError, ValueError):
        return {"pages": [], "documents": []}


# ---------------------------------------------------------------------------------------------------------------
# Reine Lesefunktionen (ohne Netz, getestet in tests/test_hsh_catalogs.py)
# ---------------------------------------------------------------------------------------------------------------

# Seiten, die Studiengaenge, Ordnungen, Modulhandbuecher oder Fristen tragen (Pfad, klein): Studiengangsseiten (nur
# die Seite selbst, keine Unterseiten), deren Unterseiten mit Ordnungen/Modulen und die Ordnungs-, Pruefungs- und
# Terminseiten der Fakultaeten und der Hochschule
PROGRAM_PAGE_RE = re.compile(r"^/studium(?:-old)?/(?:studiengaenge-und-programme/|studienangebot/)?"
                             r"(?:bachelor|master|duale?|weiterbildende?|berufsbegleitende?)[a-z-]*/[a-z0-9-]+/?$"
                             r"|^/studium/[a-z0-9-]*-dual/?$|^/studium/studiengaenge-und-programme/studienprogramme/[a-z0-9-]+/?$"
                             # eine Ebene darunter (Studienstruktur, Schwerpunkte, Varianten wie pflege-berufsbegleitend)
                             r"|^/studium/(?:studiengaenge-und-programme/)?(?:bachelor|master)-studiengaenge/[a-z0-9-]+/"
                             r"(?!lehrende|news|veranstaltungen|bewerbung|zulassung)[a-z0-9-]+/?$")
INFO_PAGE_RE = re.compile(r"(?:^/studium[a-z-]*/.*(?:ordnungen|modulhandb|modulbeschreib|wahlpflicht|schwerpunkte?|studienverlauf|"
                          r"pruefungsangelegenheit|semestertermine|termine|fristen)[a-z0-9-]*(?:/[a-z0-9-]+)?/?$)"
                          r"|^/service/[a-z0-9-]+/(?:abteilung-[a-z-]+/)?(?:termine|wahlpflichtmodule|pruefungsplaene[a-z-]*)/?$"
                          r"|^/service/formulare-und-informationen/abteilung-[a-z-]+/termine/?$"
                          r"|^/ueber-uns/fakultaetsverwaltung/pruefungsverwaltungen?/?$"
                          r"|^/studium/plaene-und-termine/pruefungsplan/[a-z-]+/?$|^/service/f1-quicklinks/zeit-stunden-u-pruefungsplan/?$"
                          r"|^/ueber-uns/organisation/akademische-angelegenheiten/(?:studierende/wichtige-termine-fristen|"
                          r"kompetenzbereiche/pruefungsordnungsmanagement|studieninteressierte/gesetze-und-ordnungen)/?$", re.I)
SKIP_PAGE_RE = re.compile(r"/news/|/aktuelles/|/veranstaltungen/|/alumni|/forschung/|/stundenplan|/praktikumsamt/|"
                          r"/internationales/|/stipendien/|/leben-in-hannover/", re.I)


def page_wanted(path: str) -> bool:
    return not SKIP_PAGE_RE.search(path) and bool(PROGRAM_PAGE_RE.search(path) or INFO_PAGE_RE.search(path))


DOC_KINDS = (
    ("handbook", re.compile(r"modul(?:handb|hb|beschreib|katalog|verzeichnis|uebersicht|übersicht)|[_/-]mhb?[_-]|"
                            r"[_/-]mh[_-]|/modules?-|module[_ -]?handbook|wahlpflicht(?:modul)?katalog|"
                            r"wahlpflichtmodule|schwerpunktmodul", re.I)),
    ("plan", re.compile(r"studienverlauf|musterstudienplan|studienplan|verlaufsplan|studienablauf|semesterplan", re.I)),
    ("termine", re.compile(r"termin|pr(?:ue|ü)fungsanmeldung|pr(?:ue|ü)fungsplan|pruefungsplanung|semestertermine|"
                           r"informationen[_ ]pr(?:ue|ü)fungsausschuss", re.I)),
    ("po", re.compile(r"pr(?:ue|ü)fungsordnung|/ordnungen/|[_-]b?po[_-]|btpo|atpo|bpo|mpo|studienordnung|"
                      r"besonderer[_ -]teil|allgemeiner[_ -]teil", re.I)),
)


def doc_kind(url: str, text: str) -> str | None:
    hay = f"{urllib.parse.unquote(url.rsplit('/', 1)[-1])} {text}"
    for kind, rx in DOC_KINDS:
        if rx.search(hay):
            return kind
    # Ordnerpfad als letzter Hinweis
    path = urllib.parse.unquote(urllib.parse.urlsplit(url).path)
    if re.search(r"modulhandb|modulkatalog", path, re.I):
        return "handbook"
    return None


def candidate_pages(locs: list[str]) -> list[str]:
    out: list[str] = []
    for u in locs:
        p = urllib.parse.urlsplit(u)
        if not ALLOWED_HOST.match(p.netloc) or p.query:
            continue
        if not page_wanted(p.path):
            continue
        n = norm_url(u)
        if n not in out:
            out.append(n)
    return out


def pdf_links(page_links: list[tuple[str, str]]) -> list[dict]:
    """PDF-Links einer Seite mit Art (handbook/plan/po) und Linktext; andere PDFs (Flyer, Formulare) fallen weg"""
    seen, out = set(), []
    for href, text in page_links:
        u = norm_url(href)
        if u in seen or not re.search(r"\.pdf$", u, re.I) or not allowed(u):
            continue
        seen.add(u)
        kind = doc_kind(u, text)
        if kind:
            out.append({"url": u, "label": (text or "")[:200], "kind": kind})
    return out


# ---------------------------------------------------------------------------------------------------------------
# Ablauf
# ---------------------------------------------------------------------------------------------------------------

def sitemap_locs_all() -> list[str]:
    locs: list[str] = []
    for host in ("www",) + FACULTIES:
        top = read_text(f"https://{host}.hs-hannover.de/sitemap.xml") or ""
        subs = [u for u in HP.sitemap_locs(top) if "sitemap=" in u]
        for s in subs:
            locs += HP.sitemap_locs(read_text(s) or "")
    return locs


def collect(network: bool = True) -> dict:
    NETWORK[0] = network
    locs = sitemap_locs_all()
    reg_pages = []
    reg_path = ROOT / "packages/shared-contracts/study-sources-hsh.json"
    if reg_path.exists():
        reg = json.loads(reg_path.read_text())
        reg_pages = [p["program_page"] for p in reg.get("programs", []) if p.get("program_page")]
    pages = candidate_pages(list(reg_pages) + locs)
    docs: dict[str, dict] = {}
    page_info = []
    for url in pages:
        e = fetch(url)
        txt = read_text(url) if e else None
        title = None
        found = []
        if txt:
            m = re.search(r"<h1[^>]*>(.*?)</h1>", txt, re.S)
            title = HP.html_text(m.group(1)) if m else None
            found = pdf_links(HP.page_links(txt, e["final"]))
        page_info.append({"url": url, "status": e.get("status") if e else None, "title": title, "pdfs": len(found)})
        for d in found:
            cur = docs.setdefault(d["url"], {**d, "pages": []})
            if url not in cur["pages"]:
                cur["pages"].append(url)
            if len(d["label"]) > len(cur["label"]):
                cur["label"] = d["label"]
    # PDFs holen: Modulhandbuecher und Verlaufsplaene alle, Ordnungen nur die Besonderen Teile/POs der Studiengaenge
    for u, d in sorted(docs.items()):
        e = fetch(u)
        d["status"] = e.get("status") if e else None
        d["path"] = e.get("abs") if e else None
        d["sha256"] = e.get("sha256") if e else None
        d["fetched_at"] = e.get("fetched_at") if e else None
    out = {"requests": idx()["requests"], "pages": page_info, "documents": [docs[k] for k in sorted(docs)]}
    return out


def main(argv: list[str]) -> int:
    cmd = argv[1] if len(argv) > 1 else "list"
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
            if e and e.get("abs") and e["abs"].endswith(".pdf"):
                t, n = HP.pdf_text(Path(e["abs"]), int(argv[3]) if len(argv) > 3 else None)
                print(f"# {n} Seiten\n{t}")
            elif e and e.get("abs"):
                print(HP.html_text(Path(e["abs"]).read_text(errors="replace")))
            else:
                print(e)
        elif cmd == "count":
            print(idx()["requests"])
        elif cmd in ("crawl", "list"):
            data = collect(network=cmd == "crawl")
            DOCS.write_text(json.dumps(data, ensure_ascii=False, indent=1))
            kinds: dict = {}
            for d in data["documents"]:
                k = (d["kind"], d.get("status"))
                kinds[k] = kinds.get(k, 0) + 1
            print(json.dumps({"pages": len(data["pages"]), "documents": len(data["documents"]),
                              "kinds": {f"{a}:{b}": n for (a, b), n in sorted(kinds.items(), key=str)},
                              "requests": data["requests"]}, ensure_ascii=False))
        else:
            raise SystemExit(f"unbekannt: {cmd}")
    except Budget as b:
        print(f"STOP: {b}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

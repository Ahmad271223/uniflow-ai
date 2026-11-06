"""Bescheinigungen aus den Hochschulportalen (06.11.2026, docs/BESCHEINIGUNGEN-2026-11-06.md).

Auftrag des Inhabers: "Immatrikulationsbescheinigung sehen, alle deren Noten, alles komplett, deren Bescheinigungen die
es noch so gibt". Dieselben Regeln wie der Swift-Kern (UniFlowCore/Certificates), gemeinsame Faelle in
packages/shared-contracts/fixtures/certificates (tools/gen-certificates-fixture.py):

- Art aus dem Titel (`kinds_of`), Semester aus dem Titel (`semester_of`), Titel bereinigt (`clean_title`).
- Angebote einer QIS/LSF-Seite (`qis_offers`): Links mit state=verpublish (nicht state=verify) oder auf eine .pdf,
  Adresse ohne asi/jsessionid. Ein verpublish-Aufruf ERZEUGT im QIS ein Dokument: die Liste liest nur Links; geladen
  wird erst auf Knopfdruck (`download`), genau ein Aufruf.
- Angebote der HISinOne-Seite "Bescheide und Bescheinigungen" (`hisinone_offers`), Semesterauswahl (select) falls
  vorhanden; an der HsH noch nicht mit einem Konto mit Bescheiden gesehen (`confirmed` = False).
- Gespeichert: settings.certificates (JSON) und die PDFs unter <Datenordner>/qis/Bescheinigung-<id>.pdf mit Datum.

Netz nur am PC mit Playwright (`refresh`, `download`) ueber die bestehenden Anmeldungen (QIS/LSF-Zugang wie qis.run,
HsH mit der gemerkten Sitzung); auf dem iPad laeuft dasselbe im Kern mit den Cookies der Webansicht.
"""
from __future__ import annotations

import hashlib
import html as _html
import json
import re
from pathlib import Path
from urllib.parse import unquote, unquote_plus, urljoin, urlsplit

from . import config, db, universities

SETTINGS_KEY = "certificates"

KIND_ORDER = ["immatrikulation", "bafoeg", "datenkontrollblatt", "notenspiegel", "rueckmeldung", "bescheid", "sonstige"]
KIND_LABELS = {
    "immatrikulation": "Immatrikulations- / Studienbescheinigung",
    "bafoeg": "BAföG-Bescheinigung (§ 9)",
    "datenkontrollblatt": "Datenkontrollblatt",
    "notenspiegel": "Notenspiegel / Leistungsübersicht (PDF)",
    "rueckmeldung": "Rückmeldebescheinigung",
    "bescheid": "Bescheide und Zahlungsnachweise",
    "sonstige": "Weitere Dokumente",
}
STANDARD_KINDS = ["immatrikulation", "bafoeg", "datenkontrollblatt", "notenspiegel", "rueckmeldung"]
# Reihenfolge wie CertificateKind.rules im Kern
KIND_RULES = [
    ("datenkontrollblatt", ["datenkontrollblatt"]),
    ("rueckmeldung", ["rückmeldebescheinigung", "rueckmeldebescheinigung", "rückmeldung", "rueckmeldung"]),
    ("immatrikulation", ["immatrikulation", "studienbescheinigung", "studienzeit", "studierendenbescheinigung",
                         "semesterbescheinigung", "enrolment", "enrollment", "certificate of study"]),
    ("bafoeg", ["bafög", "bafoeg", "§ 9", "§9"]),
    ("notenspiegel", ["notenspiegel", "leistungsübersicht", "leistungsuebersicht", "leistungsspiegel", "notenübersicht",
                      "transcript", "leistungsnachweis", "leistungen"]),
    ("bescheid", ["bescheid", "gebühr", "beitrag", "zahlung", "payment"]),
]

PORTAL = {"luh": "QIS", "hildesheim": "PLuS", "hsh": "Campusmanagement"}
# HISinOne je Hochschule (Studienservice mit "Bescheide und Bescheinigungen"); Strukturnotizen 06.11.2026
PLUS_BASE = "https://plus.uni-hildesheim.de"
PLUS_STUDY_SERVICE = f"{PLUS_BASE}/qisserver/pages/cm/exa/enrollment/info/start.xhtml?_flowId=studyservice-flow&initialTab=showTabReport"
PLUS_LOGIN = f"{PLUS_BASE}/qisserver/api/identityprovider/redirect/5/login"
NOTES = {
    "luh": "Quelle: QIS → „Meine Bescheinigungen“ (live bestätigt 06.11.2026): „Studienzeit- / Immatrikulationsbescheinigung / Bescheinigung nach § 9 BAföG“ für das aktuelle Semester, dazu der PDF-Notenspiegel, sobald Leistungen verbucht sind. Jeder Abruf erzeugt im QIS ein neues, verifizierbares Dokument; StudiNow lädt nur, wenn du tippst.",
    "hildesheim": "Quelle: PLuS → Studienservice → „Bescheide / Bescheinigungen“ (live bestätigt 06.11.2026): z. B. Immatrikulationsbescheinigung, Bescheinigung nach § 9 BAföG, Studienverlaufs-, Unbedenklichkeitsbescheinigung, Zahlungsnachweis, englische Fassungen. Das LSF hat keine Bescheinigungen. PLuS hat eine eigene Anmeldung (SSO Uni Hildesheim) und meldet nach 30 Minuten ohne Aktivität ab. Nach dem Tippen erstellt PLuS die PDF im Hintergrund.",
    "hsh": "Quelle: Campusmanagement → Studienservice → „Bescheide und Bescheinigungen“ (live bestätigt 06.11.2026). Welche Berichte dort stehen (z. B. Notenspiegel, Zahlungsbeleg, Bescheinigung über angemeldete Prüfungen, Immatrikulationsbescheinigung), hängt von deinem Konto ab. Nach dem Tippen erstellt das Campusmanagement die PDF im Hintergrund.",
}

_TAG_RE = re.compile(r"<[^>]+>")
_WS_RE = re.compile(r"\s+")
_PDF_PREFIX_RE = re.compile(r"^pdf\s*-?\s*", re.I)
_ACTION_SUFFIX_RE = re.compile(r"\s*(zum drucken|anzeigen|drucken|herunterladen|öffnen|pdf)\s*$", re.I)
_TRAIL_RE = re.compile(r"[\s–\-:|]+$")
_WINTER_RE = re.compile(r"(?<!ab )(?<!seit )\b(?:wintersemester|wise|ws)\s*(\d{4}|\d{2})\s*/\s*(\d{4}|\d{2})\b", re.I)
_SUMMER_RE = re.compile(r"(?<!ab )(?<!seit )\b(?:sommersemester|sose|ss)\s*(\d{4}|\d{2})\b", re.I)
GENERIC = {"", "pdf", "dokument", "download", "herunterladen", "öffnen", "anzeigen", "drucken"}


def text(fragment: str) -> str:
    """Tags entfernen, Entities dekodieren, Leerraum zusammenfassen"""
    return _WS_RE.sub(" ", _html.unescape(_TAG_RE.sub(" ", fragment or ""))).strip()


def clean_title(raw: str) -> str:
    t = _WS_RE.sub(" ", raw or "").strip()
    t = _PDF_PREFIX_RE.sub("", t)
    for _ in range(2):
        t = _ACTION_SUFFIX_RE.sub("", t)
    t = _TRAIL_RE.sub("", t)
    return t[:90]


def kinds_of(title: str) -> list[str]:
    low = (title or "").lower()
    found = [k for k, words in KIND_RULES if any(w in low for w in words)]
    return found or ["sonstige"]


def semester_of(value: str) -> str | None:
    """"WiSe 2026/27" bzw. "SoSe 2026" (der zuerst genannte); None ohne Semester"""
    def year(s: str) -> int:
        return 2000 + int(s) if len(s) == 2 else int(s)
    best = None
    m = _WINTER_RE.search(value or "")
    if m:
        best = (m.start(), f"WiSe {year(m.group(1))}/{year(m.group(2)) % 100:02d}")
    m = _SUMMER_RE.search(value or "")
    if m and (best is None or m.start() < best[0]):
        best = (m.start(), f"SoSe {year(m.group(1))}")
    return best[1] if best else None


def semester_rank(s: str | None) -> int:
    if not s:
        return -1
    m = re.search(r"\d+", s)
    return (int(m.group(0)) if m else 0) * 2 + (1 if s.startswith("WiSe") else 0)


def offer_id(university: str, locator: str) -> str:
    return hashlib.md5(f"{university}|{unquote(locator)}".encode()).hexdigest()[:12]


# ---------------------------------------------------------------- Adressen wie QISParser im Kern

def resolve(href: str, base: str) -> str | None:
    h = re.sub(r"[\n\r\t]", "", href or "").strip()
    low = h.lower()
    if not h or h.startswith("#") or low.startswith(("javascript:", "mailto:", "data:", "tel:")):
        return None
    u = urljoin(base, h)
    return u if u.lower().startswith(("http://", "https://")) else None


def strip_session(abs_url: str) -> str:
    """Adresse ohne asi/jsessionid (Abfrage), ohne ;jsessionid (Pfad) und ohne Anker"""
    s = abs_url.split("#", 1)[0]
    q = None
    if "?" in s:
        s, q = s.split("?", 1)
    s = re.sub(r";jsessionid=[^/]*", "", s, flags=re.I)
    kept = [it for it in (q or "").split("&") if it and unquote_plus(it.split("=", 1)[0]).lower() not in ("asi", "jsessionid")]
    return s + ("?" + "&".join(kept) if kept else "")


def parameters(address: str) -> dict:
    out: dict = {}
    if "?" not in address:
        return out
    for it in address.split("?", 1)[1].split("&"):
        if not it:
            continue
        k, _, v = it.partition("=")
        name = unquote_plus(k).lower()
        if name and name not in out:
            out[name] = unquote_plus(v)
    return out


# ---------------------------------------------------------------- Seiten lesen (rein)

_ANCHOR_RE = re.compile(r"<a\b([^>]*)>(.*?)</a>", re.I | re.S)
_ATTR_RE = re.compile(r"""([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))""")
_ALT_RE = re.compile(r"""\balt\s*=\s*"([^"]*)\"""", re.I)
_BLOCK_OPEN_RE = re.compile(r"<(?:tr|li|p)\b", re.I)


def attributes(tag: str) -> dict:
    out: dict = {}
    for m in _ATTR_RE.finditer(tag or ""):
        name = m.group(1).lower()
        if name not in out:
            v = next((g for g in m.groups()[1:] if g is not None), "")
            out[name] = _html.unescape(v)
    return out


def _context(page_html: str, start: int, end: int) -> str:
    window_start = max(0, start - 2000)
    last = None
    for m in _BLOCK_OPEN_RE.finditer(page_html, window_start, start):
        last = m
    return text(page_html[last.start():end]) if last else ""


def _title(label: str, attr_title: str, context: str) -> str:
    for cand in (label, attr_title, context):
        t = clean_title(cand)
        if t.lower() not in GENERIC:
            return t
    return "Dokument"


def anchors(page_html: str, url: str) -> list[dict]:
    """Links einer Seite: Text, Adresse mit (raw) und ohne Sitzung (address), Parameter"""
    out = []
    for m in _ANCHOR_RE.finditer(page_html or ""):
        a = attributes(m.group(1))
        absu = resolve(a.get("href", ""), url) if "href" in a else None
        if not absu:
            continue
        out.append({"text": text(m.group(2)) or (a.get("title") or "").strip(), "raw": absu, "address": strip_session(absu),
                    "title": a.get("title", ""), "inner": m.group(2), "span": m.span()})
    return out


def qis_offers(page_html: str, url: str, source: str, university: str, confirmed: bool) -> list[dict]:
    host = (urlsplit(url).hostname or "").lower()
    out, seen = [], set()
    for a in anchors(page_html, url):
        address = a["address"]
        if (urlsplit(address).hostname or "").lower() != host:
            continue
        state = (parameters(address).get("state") or "").lower()
        if state == "verify" or not (state == "verpublish" or urlsplit(address).path.lower().endswith(".pdf")):
            continue
        if address in seen:
            continue
        seen.add(address)
        label = text(a["inner"])
        if not label:
            m = _ALT_RE.search(a["inner"])
            label = _html.unescape(m.group(1)) if m else ""
        ctx = _context(page_html, a["span"][0], a["span"][1])
        t = _title(label, a["title"], ctx)
        ks = kinds_of(t)
        out.append({"id": offer_id(university, address), "title": t, "kind": ks[0], "kinds": ks,
                    "semester": semester_of(t) or semester_of(ctx), "semesters": [], "source": source, "portal": "qis",
                    "address": address, "confirmed": confirmed})
    return out


_ROW_RE = re.compile(r"<tr\b[^>]*>(.*?)</tr>", re.I | re.S)
_CELL_RE = re.compile(r"<t[dh]\b[^>]*>(.*?)</t[dh]>", re.I | re.S)
_BUTTON_RE = re.compile(r"<(?:button|input)\b([^>]*)>(?:((?:(?!<input\b|<button\b).)*?)</button>)?", re.I | re.S)
_SELECT_RE = re.compile(r"<select\b([^>]*)>(.*?)</select>", re.I | re.S)
_OPTION_RE = re.compile(r"<option\b([^>]*)>(.*?)</option>", re.I | re.S)
_FORM_RE = re.compile(r"<form\b([^>]*)>(.*?)</form>", re.I | re.S)
ACTION_WORDS = ["pdf", "drucken", "herunterladen", "download", "anzeigen", "erzeugen", "öffnen", "bescheinigung"]
LINK_HINTS = [".pdf", "download", "report", "print", "document"]


def hisinone_rows(page_html: str) -> list[dict]:
    out = []
    for row in _ROW_RE.findall(page_html or ""):
        cells = [text(c) for c in _CELL_RE.findall(row)]
        if not cells:
            continue
        action = None
        for m in _ANCHOR_RE.finditer(row):
            a = attributes(m.group(1))
            href = a.get("href")
            if not href or href.lower().startswith("javascript") or href.startswith("#"):
                continue
            label = (text(m.group(2)) + " " + a.get("title", "")).lower()
            if any(h in href.lower() for h in LINK_HINTS) or any(w in label for w in ACTION_WORDS):
                action = {"href": href}
                break
        if action is None:
            for m in _BUTTON_RE.finditer(row):
                a = attributes(m.group(1))
                if (a.get("type") or "submit").lower() not in ("submit", "image") or "name" not in a or is_job_button(a["name"], a.get("id")):
                    continue
                inner = text(m.group(2)) if m.group(2) is not None else ""
                label = " ".join([a.get("value", ""), a.get("title", ""), a.get("alt", ""), inner]).lower()
                if any(w in label for w in ACTION_WORDS):
                    action = {"button": [a["name"], a.get("value", inner)]}
                    break
        if action is None:
            continue
        title = next((t for t in map(clean_title, cells)
                      if t.lower() not in GENERIC and any(ch.isalpha() for ch in t) and t.lower() not in ACTION_WORDS), None)
        if not title:
            continue
        out.append({"title": title, "semester": semester_of(title) or semester_of(" ".join(cells)), "action": action})
    return out


def hisinone_semesters(page_html: str):
    for m in _SELECT_RE.finditer(page_html or ""):
        a = attributes(m.group(1))
        key = (a.get("name", "") + " " + a.get("id", "")).lower()
        if "name" not in a or not any(w in key for w in ("term", "semester", "period")):
            continue
        opts = []
        for o in _OPTION_RE.finditer(m.group(2)):
            oa = attributes(o.group(1))
            label = text(o.group(2))
            sem = semester_of(label)
            if sem:
                opts.append({"value": oa.get("value", label), "label": sem})
        if opts:
            return a["name"], opts
    return None


_JOB_RE = re.compile(r":job\d*$")
_POLL_RE = re.compile(r'id="([^"]*jobDownloadPoll[^"]*)"')


def is_job_button(name: str, id_: str | None) -> bool:
    """Berichtsknopf (HsH, 06.11.2026): ...reportButtons:jobConfigurationButtons:<i>:jobConfigurationButtons:<j>:job<k>"""
    return any("jobConfigurationButtons" in x and _JOB_RE.search(x) for x in (name or "", id_ or ""))


def hisinone_job_buttons(page_html: str) -> list[dict]:
    out = []
    for m in _BUTTON_RE.finditer(page_html or ""):
        a = attributes(m.group(1))
        name = a.get("name") or a.get("id")
        if not name or not is_job_button(name, a.get("id")):
            continue
        inner = text(m.group(2)) if m.group(2) is not None else ""
        title = next((t for t in map(clean_title, [inner, a.get("value", ""), a.get("title", "")]) if t.lower() not in GENERIC), "")
        if title:
            out.append({"title": title, "name": name, "value": a.get("value", inner)})
    return out


def is_report_tab(page_html: str) -> bool:
    return "jobConfigurationButtons" in (page_html or "") or "Keine Bescheide vorhanden" in (page_html or "")


def hisinone_poll(page_html: str) -> str | None:
    m = _POLL_RE.search(page_html or "")
    return m.group(1) if m else None


def hisinone_offers(page_html: str, university: str) -> list[dict]:
    sel = hisinone_semesters(page_html)
    semesters = sel[1] if sel else []
    out, seen = [], set()
    for b in hisinone_job_buttons(page_html):
        oid = offer_id(university, f"hisinone|{b['title']}|")
        if oid in seen:
            continue
        seen.add(oid)
        ks = kinds_of(b["title"])
        out.append({"id": oid, "title": b["title"], "kind": ks[0], "kinds": ks, "semester": semester_of(b["title"]), "semesters": [],
                    "source": "studienservice", "portal": "hisinone", "address": None, "confirmed": university in ("hsh", "hildesheim")})
    for r in hisinone_rows(page_html):
        oid = offer_id(university, f"hisinone|{r['title']}|{r['semester'] or ''}")
        if oid in seen:
            continue
        seen.add(oid)
        ks = kinds_of(r["title"])
        out.append({"id": oid, "title": r["title"], "kind": ks[0], "kinds": ks, "semester": r["semester"],
                    "semesters": [] if r["semester"] else semesters, "source": "studienservice", "portal": "hisinone",
                    "address": None, "confirmed": False})
    return out


def is_pdf(body: bytes | None) -> bool:
    return bool(body) and body.startswith(b"%PDF")


_EMBEDDED_RE = re.compile(r"""(?:src|href|data|content|url)\s*=\s*["']?([^"'\s>]*(?:\.pdf|verpublish|hisreports|download)[^"'\s>]*)""", re.I)


def embedded_pdf(page_html: str, base: str) -> str | None:
    host = (urlsplit(base).hostname or "").lower()
    for raw in _EMBEDDED_RE.findall(page_html or ""):
        s = _html.unescape(raw)
        if s.lower().startswith("url="):
            s = s[4:]
        u = resolve(s, base)
        if u and (urlsplit(u).hostname or "").lower() == host:
            return u
    return None


# ---------------------------------------------------------------- Speicher und Anzeige

def _empty(university: str) -> dict:
    return {"university": university, "checked_at": None, "status": "never", "message": "", "offers": [], "files": {}}


def load(conn) -> dict | None:
    r = db.row(conn, "SELECT value FROM settings WHERE key=?", (SETTINGS_KEY,))
    if not r:
        return None
    try:
        return json.loads(r["value"])
    except (TypeError, ValueError):
        return None


def save(conn, state: dict) -> None:
    db.set_setting(conn, SETTINGS_KEY, json.dumps(state, ensure_ascii=False, sort_keys=True))


def _file_path(rel: str | None) -> Path | None:
    """Gespeicherte PDF nur im QIS-Ordner des aufrufenden Kontos"""
    if not rel:
        return None
    base = (config.data_dir() / "qis").resolve()
    try:
        p = (config.data_dir() / rel).resolve()
        return p if p.is_relative_to(base) and p.is_file() else None
    except (OSError, ValueError):
        return None


def sorted_offers(offers: list[dict]) -> list[dict]:
    return sorted(offers, key=lambda o: (KIND_ORDER.index(o["kind"]) if o["kind"] in KIND_ORDER else 99, -semester_rank(o.get("semester"))))


def summary_of(state: dict, university: str, documents: list, has_file=lambda path: _file_path(path) is not None) -> dict:
    """GET /api/certificates aus dem gespeicherten Stand (wie CertificatesSync.summary im Kern)"""
    files = state.get("files") or {}
    offers = []
    for o in sorted_offers(state.get("offers") or []):
        f = files.get(o["id"])
        file = None
        if f and has_file(f.get("path")):
            file = {"fetched_at": f["fetched_at"], "size": f["size"], "semester": f.get("semester"),
                    "url": f"/api/certificates/{o['id']}/file"}
        offers.append({"id": o["id"], "title": o["title"], "kind": o["kind"], "kind_label": KIND_LABELS.get(o["kind"], o["kind"]),
                       "kinds": o.get("kinds") or [o["kind"]], "semester": o.get("semester"), "semesters": o.get("semesters") or [],
                       "source": o["source"], "confirmed": bool(o.get("confirmed")), "file": file})
    covered = {k for o in state.get("offers") or [] for k in (o.get("kinds") or [o["kind"]])}
    return {"university": university, "portal": PORTAL.get(university, "QIS"), "status": state.get("status") or "never",
            "message": state.get("message") or "", "checked_at": state.get("checked_at"), "offers": offers,
            "kinds": [{"key": k, "label": KIND_LABELS[k], "offered": k in covered} for k in STANDARD_KINDS],
            "note": NOTES.get(university, ""), "documents": documents}


def summary(conn, university: str | None = None) -> dict:
    uni = university or universities.current_key()
    docs = db.rows(conn, "SELECT id, title, fetched_at FROM qis_documents ORDER BY id DESC")
    return summary_of(load(conn) or _empty(uni), uni, docs)


def file_for(conn, cert_id: str) -> Path | None:
    s = load(conn) or {}
    f = (s.get("files") or {}).get(cert_id)
    return _file_path(f.get("path")) if f else None


def store_offers(conn, offers: list[dict], university: str, now: str) -> None:
    s = load(conn) or _empty(university)
    s.update(university=university, offers=offers, checked_at=now, status="ok",
             message=f"{len(offers)} {'Dokument' if len(offers) == 1 else 'Dokumente'} im Portal" if offers
             else "Das Portal bietet gerade keine Bescheinigungen an.")
    save(conn, s)


def store_status(conn, university: str, status: str, message: str, now: str) -> None:
    s = load(conn) or _empty(university)
    s.update(status=status, message=message)
    s["checked_at"] = s.get("checked_at") or now
    save(conn, s)


def store_file(conn, offer: dict, body: bytes, semester_label: str | None, now: str) -> Path:
    rel = f"qis/Bescheinigung-{offer['id']}.pdf"
    p = config.data_dir() / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".tmp")
    tmp.write_bytes(body)
    tmp.replace(p)                                    # alte Kopie erst ersetzen, wenn die neue PDF da ist
    s = load(conn) or _empty(universities.current_key())
    s.setdefault("files", {})[offer["id"]] = {"path": rel, "fetched_at": now, "size": len(body), "semester": semester_label}
    if s.get("status") == "login":
        s.update(status="ok", message="")
    save(conn, s)
    return p


# ---------------------------------------------------------------- Netz am PC (Playwright)

def _menu_priority(a: dict) -> int | None:
    addr, t = a["address"].lower(), (a["text"] or "").lower()
    if "prfanm" in addr or "logout" in addr or "abmeld" in t or "anmeld" in t:
        return None
    p = parameters(a["address"])
    state = (p.get("state") or "").lower()
    if state in ("verpublish", "verify"):
        return None
    module = (p.get("moduleparameter") or "").lower()
    if module == "studentreportsmenu" or "bescheinigung" in t:
        return 0
    if module == "studysosmenu":
        return 1
    if module == "studyposmenu":
        return 2
    return None


def _qis_walk(page, start: str, university: str, target: str | None = None, max_pages: int = 10):
    """Startseite und Menues des QIS (wie CertificateClient.qisWalk): Angebote sammeln; mit `target` die erste Seite
    mit diesem Link (Rueckgabe: Link mit Sitzung). Den Notenspiegel liest qis.fetch_grades (PDF-Links dort)."""
    confirmed = university == "luh"
    if start:                                         # sonst ab der aktuellen Seite (nach der Anmeldung)
        page.goto(start, wait_until="domcontentloaded")
    offers, known, visited = [], set(), set()
    want = unquote(target) if target else None

    def absorb(source):
        h, u = page.content(), page.url
        for o in qis_offers(h, u, source, university, confirmed and source == "bescheinigungen"):
            if o["id"] not in known:
                known.add(o["id"])
                offers.append(o)
        if want:
            for a in anchors(h, u):
                if unquote(a["address"]) == want:
                    return a["raw"]
        return None

    hit = absorb("bescheinigungen")
    if hit:
        return offers, hit
    links = [a for a in anchors(page.content(), page.url) if _menu_priority(a) is not None]
    queue = [(a, 0) for a in sorted(links, key=_menu_priority)]
    n = 0
    while queue and n < max_pages:
        a, depth = queue.pop(0)
        if a["address"] in visited:
            continue
        visited.add(a["address"])
        page.goto(a["raw"], wait_until="domcontentloaded")
        n += 1
        hit = absorb("bescheinigungen")
        if hit:
            return offers, hit
        if depth < 1:
            queue += [(b, 1) for b in anchors(page.content(), page.url) if _menu_priority(b) == 0 and b["address"] not in visited]
    return offers, None


def _fetch_once(page, url: str) -> bytes:
    """Genau ein Aufruf (erzeugt im Portal ein Dokument); Zwischenseite: ihrem PDF-Link einmal folgen"""
    r = page.request.get(url, timeout=30000)
    body = r.body() if r.ok else b""
    if is_pdf(body):
        return body
    nxt = embedded_pdf(body.decode("utf-8", "ignore"), url)
    if nxt:
        r2 = page.request.get(nxt, timeout=30000)
        body = r2.body() if r2.ok else b""
        if is_pdf(body):
            return body
    raise RuntimeError("Das Portal hat statt der PDF eine Webseite geliefert. Bitte im Portal selbst öffnen.")


def _hisinone_logged_in(page_html: str, url: str, base: str) -> bool:
    """Abmelden-Link auf dem HISinOne-Rechner; der versteckte Block "Sitzung abgelaufen / Anmelden" zaehlt nie"""
    return (urlsplit(url).hostname or "").lower() == (urlsplit(base).hostname or "").lower() and "category=auth.logout" in (page_html or "")


def _documents_page(page, study_service: str, base: str, portal: str) -> str:
    page.goto(study_service, wait_until="domcontentloaded")
    if not _hisinone_logged_in(page.content(), page.url, base):
        raise RuntimeError(f"Anmeldung bei {portal} nötig.")
    if not is_report_tab(page.content()):
        btn = page.locator("button[name$='report_TabBtn'], button:has-text('Bescheide und Bescheinigungen'), input[type=submit][value*='Bescheide']").first
        if btn.count():
            btn.click()
            page.wait_for_load_state("domcontentloaded")
            page.wait_for_timeout(800)
    return page.content()


def _hisinone_context(p, uni: str, show_browser: bool):
    """Browser mit Sitzung: HsH mit der gemerkten Campusmanagement-Sitzung, Hildesheim mit Anmeldung im PLuS (CAS,
    eigener UNI-Account aus der .env wie beim LSF)"""
    if uni == "hsh":
        from . import hisinone, hsh, unilogin
        if not unilogin.has_session(hsh.SESSION):
            raise RuntimeError("Anmeldung beim Campusmanagement nötig (Einstellungen > Zugang > im Browser anmelden).")
        ctx = p.chromium.launch_persistent_context(str(hsh._profile_dir()), headless=not show_browser, locale="de-DE", accept_downloads=True)
        unilogin.restore(ctx, hsh.SESSION)
        return ctx, ctx.new_page(), hisinone.STUDY_SERVICE_URL, universities.HSH_CM_BASE
    from . import cas, hildesheim, lsf, qis
    user, pw = qis.credentials_for("hildesheim")
    if not user or not pw:
        raise RuntimeError("Keine Zugangsdaten (Einstellungen > Zugang: UNI-Account).")
    ctx = p.chromium.launch_persistent_context(str(config.data_dir() / hildesheim.PROFILE_DIR.name if config.current_user_id() else hildesheim.PROFILE_DIR),
                                               headless=not show_browser, locale="de-DE", accept_downloads=True)
    page = ctx.new_page()
    cas.login(page, PLUS_LOGIN, lsf.HILDESHEIM_CAS, user, pw,
              lambda: "plus." in page.url and _hisinone_logged_in(page.content(), page.url, PLUS_BASE), lambda m: None)
    return ctx, page, PLUS_STUDY_SERVICE, PLUS_BASE


def refresh(show_browser: bool = False) -> dict:
    """Liste neu lesen (nur Links/Zeilen): LUH/Hildesheim ueber den QIS-/LSF-Zugang, HsH mit der gemerkten Sitzung.
    Den PDF-Notenspiegel findet der Notenabruf (qis.fetch_grades sammelt die Links mit)."""
    from playwright.sync_api import sync_playwright

    from . import qis
    db.init_db()
    uni = universities.current_key()
    now = db.now_iso()
    try:
        with sync_playwright() as p:
            if uni in ("hsh", "hildesheim"):
                ctx, page, study, base = _hisinone_context(p, uni, show_browser)
                try:
                    offers = hisinone_offers(_documents_page(page, study, base, PORTAL[uni]), uni)
                finally:
                    ctx.close()
            else:
                prof = qis.use_profile(uni)
                user, pw = qis.credentials_for(prof["key"])
                if not user or not pw:
                    raise RuntimeError("Keine Zugangsdaten (Einstellungen > Zugang).")
                ctx = p.chromium.launch_persistent_context(str(qis._profile_dir(prof)), headless=not show_browser, locale="de-DE")
                try:
                    page = ctx.new_page()
                    qis.login(page, user, pw, prof)
                    offers, _ = _qis_walk(page, prof["start"], uni)
                    store = qis.DocStore()
                    nprof = dict(prof, documents=False)           # Notenspiegel nur lesen, keine PDF laden
                    try:
                        qis.fetch_grades(page, nprof, store)
                    except Exception as e:  # noqa: BLE001 - Bescheinigungen bleiben
                        qis.log(f"Bescheinigungen: Notenspiegel nicht gelesen ({type(e).__name__})")
                    offers += [o for o in store.offers if o["id"] not in {x["id"] for x in offers}]
                finally:
                    ctx.close()
        with db.cursor() as conn:
            store_offers(conn, offers, uni, now)
        return {"ok": True, "message": f"{len(offers)} {'Dokument' if len(offers) == 1 else 'Dokumente'} im Portal", "offers": len(offers)}
    except Exception as e:  # noqa: BLE001
        msg = str(e).splitlines()[0][:200] if str(e) else type(e).__name__
        with db.cursor() as conn:
            store_status(conn, uni, "login" if "Anmeldung" in msg or "Login" in msg else "error", msg, now)
        return {"ok": False, "message": msg, "offers": 0}


def download(cert_id: str, semester: str | None = None, show_browser: bool = False) -> dict:
    """Ein Dokument laden (genau ein Aufruf im Portal) und mit Datum ablegen"""
    from playwright.sync_api import sync_playwright

    from . import qis
    db.init_db()
    uni = universities.current_key()
    with db.cursor() as conn:
        s = load(conn) or {}
    offer = next((o for o in s.get("offers") or [] if o["id"] == cert_id), None)
    if not offer:
        return {"ok": False, "message": "Das Dokument steht nicht in der Liste. Bitte die Liste aktualisieren."}
    try:
        with sync_playwright() as p:
            if offer["portal"] == "hisinone":
                ctx, page, study, base = _hisinone_context(p, uni, show_browser)
                try:
                    page_html = _documents_page(page, study, base, PORTAL[uni])
                    job = next((b for b in hisinone_job_buttons(page_html) if offer_id(uni, f"hisinone|{b['title']}|") == cert_id), None)
                    row = None if job else next((r for r in hisinone_rows(page_html)
                                                 if offer_id(uni, f"hisinone|{r['title']}|{r['semester'] or ''}") == cert_id), None)
                    if not job and not row:
                        raise RuntimeError("Das Dokument steht im Portal gerade nicht zur Auswahl.")
                    sel = hisinone_semesters(page_html)
                    if sel and semester:
                        page.select_option(f"select[name='{sel[0]}']", semester)
                    if job:
                        act = page.locator(f"[name='{job['name']}'], [id='{job['name']}']").first
                    else:
                        act = page.locator("tr", has_text=row["title"]).first.locator("a, button, input[type=submit], input[type=image]").first
                    # Hintergrundauftrag (HsH): nach dem Klick fragt die Seite selbst ab und zeigt dann den PDF-Link
                    with page.expect_download(timeout=60000) as dl:
                        act.click()
                        for _ in range(40):
                            link = page.locator("a[href*='download' i], a[href$='.pdf' i]").first
                            if link.count() and link.is_visible():
                                link.click()
                                break
                            page.wait_for_timeout(1500)
                    body = Path(dl.value.path()).read_bytes()
                finally:
                    ctx.close()
            else:
                prof = qis.use_profile(uni)
                user, pw = qis.credentials_for(prof["key"])
                ctx = p.chromium.launch_persistent_context(str(qis._profile_dir(prof)), headless=not show_browser, locale="de-DE")
                try:
                    page = ctx.new_page()
                    qis.login(page, user, pw, prof)
                    _, raw = _qis_walk(page, prof["start"], uni, target=offer.get("address"))
                    if not raw and offer["source"] == "notenspiegel":
                        store = qis.DocStore(target=offer.get("address"))
                        qis.fetch_grades(page, dict(prof, documents=False), store)
                        raw = store.target_raw
                    if not raw:
                        raise RuntimeError("Das Dokument steht im Portal gerade nicht zur Auswahl.")
                    body = _fetch_once(page, raw)
                finally:
                    ctx.close()
        if not is_pdf(body):
            raise RuntimeError("Das Portal hat statt der PDF eine Webseite geliefert. Bitte im Portal selbst öffnen.")
        label = next((x["label"] for x in offer.get("semesters") or [] if x["value"] == semester), None) or offer.get("semester")
        with db.cursor() as conn:
            store_file(conn, offer, body, label, db.now_iso())
        return {"ok": True, "message": f"„{offer['title']}“ gespeichert"}
    except Exception as e:  # noqa: BLE001
        msg = str(e).splitlines()[0][:200] if str(e) else type(e).__name__
        return {"ok": False, "message": msg}

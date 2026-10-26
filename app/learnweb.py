"""Learnweb (Moodle) der Uni Hildesheim: Kurse und Dateien.

Zwei Wege, beide nur lesend:
 1. Mit Sicherheitsschluessel (LEARNWEB_TOKEN in der .env, selbst erzeugt im Learnweb-Profil unter
    "Sicherheitsschluessel" fuer den Dienst "Moodle mobile web service"): REST-Webservice
    core_webservice_get_site_info -> core_enrol_get_users_courses -> core_course_get_contents.
    Liefert Dateilinks mit Aenderungszeit; Downloads loesen in Moodle keine "angesehen"-Markierung aus.
 2. Ohne Schluessel: angemeldete Browsersitzung (CAS-Login mit dem UNI-Account) und Moodles AJAX-Dienste
    core_course_get_enrolled_courses_by_timeline_classification + core_courseformat_get_state.
    core_course_get_contents ist fuer AJAX gesperrt, deshalb werden Dateilinks ueber
    mod/resource/view.php?redirect=1 (nur die Weiterleitung, ohne Inhalt) bzw. die Ordnerseite ermittelt.
    Moodle verbucht dabei einen Aufruf des Materials, genau wie beim Oeffnen im Browser.
"""
from __future__ import annotations

import base64
import hashlib
import json
import unicodedata
import mimetypes
import re
import time
import urllib.parse
import urllib.request
from typing import Callable

SEM_RE = re.compile(r"^\s*((?:SoSe|SS|WiSe|WS)\s*\d{2,4}(?:/\d{2,4})?)\s*:\s*", re.I)
NUM_RE = re.compile(r"^(\d{3,5})\s+")
PLUGINFILE_RE = re.compile(r"/pluginfile\.php/\d+/mod_(resource|folder)/content/(\d+)/(.+)$")
EMBEDDED_RE = re.compile(r"""(https?://[^"'<>\s]+/pluginfile\.php/\d+/mod_resource/content/\d+/[^"'<>\s]+)""")
FOLDER_LINK_RE = re.compile(r'href="([^"]*/pluginfile\.php/\d+/mod_folder/content/\d+/[^"]+)"')
FORCEDL_RE = re.compile(r"[?&]forcedownload=1")


class LearnwebError(RuntimeError):
    pass


# ----------------------------------------------------------------------------
# Hilfsfunktionen (ohne Netzwerk, getestet)
# ----------------------------------------------------------------------------

def parse_course_title(fullname: str) -> dict:
    """'SoSe 2026: 0406 Theorien der Erziehungswissenschaft' -> semester, number (Vst.-Nr. wie im LSF), title."""
    t = re.sub(r"\s+", " ", fullname or "").strip()
    sem = ""
    m = SEM_RE.match(t)
    if m:
        sem = re.sub(r"\s+", " ", m.group(1)).strip()
        t = t[m.end():]
    m = NUM_RE.match(t)
    return {"semester": sem, "number": m.group(1) if m else None, "title": t}


def nfc(s: str | None) -> str:
    return unicodedata.normalize("NFC", s or "")


def file_id(cmid, filepath: str, filename: str) -> str:
    filepath, filename = nfc(filepath), nfc(filename)
    # SHA-256 wie im Swift-Kern (SolutionSHA256), damit iPad und PC dieselben Datei-IDs bilden
    h = hashlib.sha256(f"{filepath or '/'}{filename}".encode("utf-8")).hexdigest()[:8]
    return f"lw-{cmid}-{h}"


def section_label(title: str | None, number: int | None = None) -> str:
    """Abschnittsname als Ordner. Reine Zahlen werden zu 'Woche N' (dann erkennt der Lernplan die Woche)."""
    t = re.sub(r"\s+", " ", (title or "")).strip()
    if re.fullmatch(r"\d{1,2}", t):
        return f"Woche {int(t)}"
    if not t and number:
        return f"Abschnitt {number}"
    return t


def join_folder(*parts: str) -> str:
    return "/".join(p.strip("/ ") for p in parts if p and p.strip("/ "))


def guess_mime(name: str) -> str | None:
    return mimetypes.guess_type(name)[0]


def strip_forcedownload(url: str) -> str:
    return FORCEDL_RE.sub("", url)


def parse_pluginfile(url: str) -> dict | None:
    """Pluginfile-Link -> {area, revision, filepath, filename}. Die Revision steigt, wenn Lehrende die Datei ersetzen."""
    path = urllib.parse.urlparse(url).path
    m = PLUGINFILE_RE.search(path)
    if not m:
        return None
    parts = [nfc(urllib.parse.unquote(p)) for p in m.group(3).split("/") if p]
    if not parts:
        return None
    filepath = "/" + "/".join(parts[:-1]) + ("/" if len(parts) > 1 else "")
    return {"area": m.group(1), "revision": int(m.group(2)), "filepath": filepath, "filename": parts[-1]}


def with_token(url: str, token: str) -> str:
    """Token erst beim Download anhaengen (nie in der Datenbank speichern)."""
    return url + ("&" if "?" in url else "?") + "token=" + urllib.parse.quote(token, safe="")


def files_from_contents(sections: list[dict]) -> list[dict]:
    """core_course_get_contents -> Dateiliste im Format von studip_sync.store_course_files (+ 'folder')."""
    out = []
    for sec in sections or []:
        sec_name = section_label(sec.get("name"), sec.get("section"))
        for mod in sec.get("modules") or []:
            if mod.get("modname") not in ("resource", "folder"):
                continue
            base_folder = sec_name if mod.get("modname") == "resource" else join_folder(sec_name, mod.get("name") or "")
            for c in mod.get("contents") or []:
                if c.get("type") != "file" or not c.get("fileurl"):
                    continue
                fp = c.get("filepath") or "/"
                name = nfc(c.get("filename")) or "datei"
                out.append({
                    "id": file_id(mod["id"], fp, name),
                    "name": name,
                    "size": int(c.get("filesize") or 0),
                    "mime": c.get("mimetype") or guess_mime(name),
                    "author": c.get("author"),
                    "chdate": int(c.get("timemodified") or 0),
                    "download_url": strip_forcedownload(c["fileurl"]),
                    "folder": nfc(join_folder(base_folder, fp)),
                    "module_name": mod.get("name"),
                })
    return out


def _course(c: dict) -> dict:
    p = parse_course_title(c.get("fullname") or c.get("displayname") or "")
    return {"id": f"lw-{c['id']}", "moodle_id": int(c["id"]), "title": p["title"], "number": p["number"],
            "semester": p["semester"], "hidden": bool(c.get("hidden"))}


# ----------------------------------------------------------------------------
# Welche Learnweb-Instanz? Die Uni legt jedes Jahr eine neue an (learnweb2026 = "SoSe 2026 - WiSe 2026/27").
# ----------------------------------------------------------------------------

LEARNWEB_ROOT = "https://www.uni-hildesheim.de"


def semester_label(today=None) -> str:
    """Aktuelles Semester wie in den Learnweb-Namen: April bis September SoSe, sonst WiSe."""
    from datetime import date
    d = today or date.today()
    if 4 <= d.month <= 9:
        return f"SoSe {d.year}"
    start = d.year if d.month >= 10 else d.year - 1
    return f"WiSe {start}/{str(start + 1)[-2:]}"


def _public_sitename(base: str, timeout: int = 15) -> str | None:
    """Name der Moodle-Instanz ueber die oeffentliche Schnittstelle (ohne Anmeldung); None, wenn es sie nicht gibt."""
    body = json.dumps([{"index": 0, "methodname": "tool_mobile_get_public_config", "args": {}}]).encode()
    req = urllib.request.Request(f"{base}/lib/ajax/service-nologin.php?info=tool_mobile_get_public_config", data=body,
                                 headers={"Content-Type": "application/json", "User-Agent": "UniFlow-Lernapp"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310 - feste Uni-Adresse
            d = json.loads(r.read().decode("utf-8", "replace"))[0]
    except Exception:  # noqa: BLE001
        return None
    return None if d.get("error") else (d.get("data") or {}).get("sitename") or ""


def discover_base(today=None, probe=None, override: str | None = None) -> str:
    """Learnweb-Adresse fuer das aktuelle Semester. Reihenfolge: eigene Einstellung (HILDESHEIM_LEARNWEB_URL),
    dann die Instanz des Vorjahrs, des aktuellen und des naechsten Jahres, deren Name das aktuelle Semester nennt,
    sonst die neueste erreichbare. probe(base) -> Sitename oder None (fuer Tests austauschbar)."""
    from datetime import date
    if override:
        return override.rstrip("/")
    d = today or date.today()
    probe = probe or _public_sitename
    want = semester_label(d).lower().replace(" ", "")
    alive = []
    for year in (d.year + 1, d.year, d.year - 1):
        base = f"{LEARNWEB_ROOT}/learnweb{year}"
        name = probe(base)
        if name is None:
            continue
        if want in name.lower().replace(" ", ""):
            return base
        alive.append(base)
    if alive:
        return alive[0]
    raise LearnwebError("Keine Learnweb-Instanz erreichbar (Netz oder Adresse pruefen; "
                        "notfalls HILDESHEIM_LEARNWEB_URL in der .env setzen)")


# ----------------------------------------------------------------------------
# Moodle-Anmeldung fuer Apps (launch.php): liefert am Ende einen Schluessel, ohne dass jemand ihn abtippt
# ----------------------------------------------------------------------------

def launch_url(base: str, passport: str, scheme: str = "moodlemobile") -> str:
    """Startseite der Moodle-App-Anmeldung. Nach dem Login (hier: CAS) leitet Moodle auf
    <scheme>://token=<base64> weiter; die App faengt diese Adresse in der Webansicht ab."""
    return (f"{base.rstrip('/')}/admin/tool/mobile/launch.php?service=moodle_mobile_app"
            f"&passport={urllib.parse.quote(passport, safe='')}&urlscheme={urllib.parse.quote(scheme, safe='')}")


def parse_launch_token(redirect_url: str, base: str, passport: str) -> dict | None:
    """<scheme>://token=<base64(md5(wwwroot + passport) ':::' token [':::' privatetoken])>.
    Prueft die Signatur gegen die eigene Learnweb-Adresse und den eigenen Passport; sonst None."""
    m = re.search(r"token=([A-Za-z0-9+/=_-]+)", redirect_url or "")
    if not m:
        return None
    raw = m.group(1).replace("-", "+").replace("_", "/")
    try:
        text = base64.b64decode(raw + "=" * (-len(raw) % 4)).decode("utf-8")
    except Exception:  # noqa: BLE001
        return None
    parts = text.split(":::")
    if len(parts) < 2 or not parts[1]:
        return None
    if parts[0] != hashlib.md5((base.rstrip("/") + passport).encode("utf-8")).hexdigest():  # noqa: S324 - Moodle-Format
        return None
    return {"token": parts[1], "private_token": parts[2] if len(parts) > 2 and parts[2] else None}


# ----------------------------------------------------------------------------
# Weg 1: REST mit Sicherheitsschluessel
# ----------------------------------------------------------------------------

def _urllib_post(url: str, data: dict, timeout: int = 60) -> bytes:
    body = urllib.parse.urlencode(data).encode()
    req = urllib.request.Request(url, data=body, headers={"User-Agent": "UniFlow-Lernapp"})
    with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310 - feste https-Adresse aus dem Uni-Profil
        return r.read()


class TokenClient:
    def __init__(self, base: str, token: str, post: Callable[[str, dict], bytes] | None = None):
        if not token:
            raise LearnwebError("Kein Learnweb-Sicherheitsschluessel gesetzt")
        self.base = base.rstrip("/")
        self.token = token
        self._post = post or _urllib_post

    def call(self, fn: str, **params):
        data = {"wstoken": self.token, "wsfunction": fn, "moodlewsrestformat": "json", **params}
        raw = self._post(f"{self.base}/webservice/rest/server.php", data)
        j = json.loads(raw.decode("utf-8") or "null")
        if isinstance(j, dict) and j.get("exception"):
            raise LearnwebError(f"{fn}: {j.get('errorcode')} {j.get('message')}")
        return j

    def courses(self) -> list[dict]:
        uid = self.call("core_webservice_get_site_info")["userid"]
        return [_course(c) for c in self.call("core_enrol_get_users_courses", userid=uid)]

    def files(self, courseid: int) -> list[dict]:
        return files_from_contents(self.call("core_course_get_contents", courseid=courseid))

    def download_url(self, url: str) -> str:
        return with_token(url, self.token)

    def deadlines(self, now: int | None = None) -> list[dict]:
        return deadlines_from_events(fetch_deadline_events(lambda fn, a: self.call(fn, **a), int(now or time.time())))

    def announcements(self, courses: list[dict], known: set[str] | None = None, max_discussions: int = 30) -> tuple[list[dict], dict]:
        """Ankuendigungsforen (Typ news) aller Kurse ueber REST; liefert (Ankuendigungen, {Kurs-ID: [Diskussionen]})."""
        from . import announcements as ann
        by_moodle = {c["moodle_id"]: c for c in courses}
        params = {f"courseids[{i}]": cid for i, cid in enumerate(by_moodle)}
        items, seen = [], {c["id"]: [] for c in courses}
        for f in self.call("mod_forum_get_forums_by_courses", **params) or []:
            c = by_moodle.get(int(f.get("course") or 0))
            if not c or f.get("type") != "news":
                continue
            d = self.call("mod_forum_get_forum_discussions", forumid=int(f["id"]), sortorder=-1, page=0, perpage=max_discussions) or {}
            for x in d.get("discussions", []):
                seen[c["id"]].append(f"lw-d-{int(x['discussion'])}")
                items.append(ann.from_moodle_discussion(x, c["id"], self.base))
        return items, seen


# ----------------------------------------------------------------------------
# Weg 2: angemeldete Browsersitzung (Playwright-Seite)
# ----------------------------------------------------------------------------

AJAX_JS = """async ([m, a]) => {
  const r = await fetch(M.cfg.wwwroot + '/lib/ajax/service.php?sesskey=' + M.cfg.sesskey + '&info=' + m,
    {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify([{index: 0, methodname: m, args: a}])});
  return (await r.json())[0];
}"""
LOGGED_IN_JS = "() => !!(window.M && M.cfg && M.cfg.sesskey) && !document.body.classList.contains('notloggedin')"


class SessionClient:
    def __init__(self, page, base: str):
        self.page = page
        self.base = base.rstrip("/")

    def is_logged_in(self) -> bool:
        try:
            return bool(self.page.evaluate(LOGGED_IN_JS))
        except Exception:  # noqa: BLE001
            return False

    def ajax(self, fn: str, args: dict):
        r = self.page.evaluate(AJAX_JS, [fn, args])
        if r.get("error"):
            ex = r.get("exception") or {}
            raise LearnwebError(f"{fn}: {ex.get('errorcode')} {ex.get('message')}")
        return r.get("data")

    def courses(self) -> list[dict]:
        data = self.ajax("core_course_get_enrolled_courses_by_timeline_classification",
                         {"classification": "all", "limit": 0, "offset": 0, "sort": "fullname"})
        return [_course(c) for c in data.get("courses", [])]

    def files(self, courseid: int) -> list[dict]:
        state = json.loads(self.ajax("core_courseformat_get_state", {"courseid": courseid}))
        return files_from_state(state, self._resource_link, self._folder_links)

    def deadlines(self, now: int | None = None) -> list[dict]:
        return deadlines_from_events(fetch_deadline_events(self.ajax, int(now or time.time())))

    def announcements(self, courses: list[dict], known: set[str] | None = None, max_discussions: int = 30) -> tuple[list[dict], dict]:
        """Ankuendigungsforen ueber die Forumsseiten (Foren-Dienste sind fuer AJAX gesperrt). Bereits gespeicherte
        Diskussionen (known) werden nicht erneut geoeffnet. Liefert (neue Ankuendigungen, {Kurs-ID: [Diskussionen]})."""
        from . import announcements as ann
        known = known or set()
        items, seen = [], {}
        for c in courses:
            state = json.loads(self.ajax("core_courseformat_get_state", {"courseid": c["moodle_id"]}))
            ids: list[str] = []
            for cm in [x for x in state.get("cm", []) if x.get("module") == "forum" and x.get("uservisible", True)]:
                self.page.goto(f"{self.base}/mod/forum/view.php?id={cm['id']}", wait_until="domcontentloaded")
                if not ann.is_news_forum(self.page.evaluate("() => document.body.className")):
                    continue
                for did in ann.discussion_links(self.page.content())[:max_discussions]:
                    ids.append(f"lw-d-{did}")
                    if f"lw-d-{did}" in known:
                        continue
                    self.page.goto(f"{self.base}/mod/forum/discuss.php?d={did}", wait_until="domcontentloaded")
                    posts = ann.parse_discussion_html(self.page.content())
                    items += [ann.from_forum_post(p, c["id"], self.base, did) for p in posts[:1]]   # erster Beitrag = Ankuendigung
            seen[c["id"]] = ids
        return items, seen

    def download_url(self, url: str) -> str:
        return url

    def _resource_link(self, cmid) -> list[str]:
        r = self.page.request.get(f"{self.base}/mod/resource/view.php?id={cmid}&redirect=1", max_redirects=0)
        loc = r.headers.get("location") or ""
        if "pluginfile.php" in loc:
            return [urllib.parse.urljoin(self.base + "/", loc)]
        # Anzeigeart "eingebettet": der Link steht in der Seite
        m = EMBEDDED_RE.search(r.text() if r.ok else "")
        return [m.group(1).replace("&amp;", "&")] if m else []

    def _folder_links(self, cmid) -> list[str]:
        r = self.page.request.get(f"{self.base}/mod/folder/view.php?id={cmid}")
        return folder_links(r.text()) if r.ok else []


def folder_links(html_text: str) -> list[str]:
    seen, out = set(), []
    for link in FOLDER_LINK_RE.findall(html_text or ""):
        link = link.replace("&amp;", "&")
        key = strip_forcedownload(link)
        if key not in seen:
            seen.add(key)
            out.append(link)
    return out


def files_from_state(state: dict, resource_links: Callable, folder_links_fn: Callable) -> list[dict]:
    """core_courseformat_get_state -> Dateiliste; Links kommen aus den beiden Callbacks (je cmid)."""
    sections = {str(s["id"]): s for s in state.get("section", [])}
    out = []
    for cm in state.get("cm", []):
        if cm.get("module") not in ("resource", "folder") or cm.get("uservisible") is False:
            continue
        sec = sections.get(str(cm.get("sectionid"))) or {}
        sec_name = section_label(sec.get("title"), sec.get("number"))
        if cm["module"] == "resource":
            links, base_folder = resource_links(cm["id"]), sec_name
        else:
            links, base_folder = folder_links_fn(cm["id"]), join_folder(sec_name, cm.get("name") or "")
        for url in links:
            p = parse_pluginfile(url)
            if not p:
                continue
            out.append({"id": file_id(cm["id"], p["filepath"], p["filename"]), "name": p["filename"], "size": 0,
                        "mime": guess_mime(p["filename"]), "author": None, "chdate": p["revision"],
                        "download_url": strip_forcedownload(url),
                        "folder": join_folder(base_folder, p["filepath"]), "module_name": cm.get("name")})
    return out


# ----------------------------------------------------------------------------
# Fristen aus dem Learnweb-Kalender (Abgaben, Tests), beide Wege nur lesend
# ----------------------------------------------------------------------------
# core_calendar_get_calendar_events ist fuer AJAX gesperrt (Befund 26.10.2026). Deshalb zwei Quellen:
#  - core_calendar_get_action_events_by_timesort: alle offenen Fristen (Abgabe faellig, Test endet) im Zeitfenster,
#    seitenweise; erledigte Aufgaben fehlen hier.
#  - core_calendar_get_calendar_upcoming_view: die naechsten Termine laut Moodle-Vorschau, auch "Test beginnt".
# Beide liefern dieselbe Ereignis-Form; doppelte Ereignisse (gleiche id) werden zusammengefasst.

DEADLINE_KINDS = {("assign", "due"): "abgabe", ("quiz", "close"): "test_ende", ("quiz", "open"): "test_beginn"}
DEADLINE_DAYS_BACK = 120     # ueberfaellige, nicht erledigte Fristen des Semesters (Moodle liefert erledigte nicht mehr)
DEADLINE_DAYS_AHEAD = 200
DEADLINE_PAGES = 10


# Angehaengte Zeitangabe im Aktivitaetsnamen, z. B. "Bonustest (verfügbar vom 30.10. (15:00 Uhr) bis 02.11. (23:59 Uhr))"
# oder "Abgabe ... (schließt am 04.11. um 23:59 Uhr)": steht schon als Datum/Uhrzeit in der Frist
_TRAILING_DATE_RE = re.compile(r"\s*\((?:[^()]|\([^()]*\))*?\b\d{1,2}\.\d{1,2}\.(?:[^()]|\([^()]*\))*\)\s*$")


def short_deadline_title(title: str) -> str:
    """Titel ohne angehaengte Zeitangabe in Klammern; bleibt nichts uebrig, der volle Titel."""
    t = _TRAILING_DATE_RE.sub("", title or "").strip()
    return t or (title or "").strip()


def deadline_kind(modulename: str | None, eventtype: str | None) -> str:
    """abgabe | test_ende | test_beginn | frist (andere Aktivitaet: faellig/schliesst) | termin (alles andere)."""
    k = DEADLINE_KINDS.get(((modulename or "").lower(), (eventtype or "").lower()))
    if k:
        return k
    if modulename and (eventtype or "").lower() in ("due", "close", "expectcompletionon", "gradingdue"):
        return "frist"
    return "termin"


def local_iso(ts: int, tz: str = "Europe/Berlin") -> str:
    """Unix-Zeit als lokale Uhrzeit 'YYYY-MM-DDTHH:MM' (wie die Stundenplan-Zeiten der App)."""
    from datetime import datetime
    from zoneinfo import ZoneInfo
    return datetime.fromtimestamp(int(ts), ZoneInfo(tz)).strftime("%Y-%m-%dT%H:%M")


def deadlines_from_events(events: list[dict]) -> list[dict]:
    """Moodle-Kalenderereignisse -> Fristen der App, nach Zeit sortiert, ohne doppelte Ereignisse."""
    out: dict[str, dict] = {}
    for e in events or []:
        if e.get("id") is None or not e.get("timestart"):
            continue
        course = e.get("course") or {}
        cid = course.get("id") or e.get("courseid")
        title = nfc(e.get("activityname") or e.get("name") or "").strip()
        did = f"lw-ev-{int(e['id'])}"
        out[did] = {"id": did, "course_id": f"lw-{int(cid)}" if cid and int(cid) > 1 else None,
                    "title": short_deadline_title(title) or "Termin", "full_title": title or "Termin", "kind": deadline_kind(e.get("modulename"), e.get("eventtype")),
                    "module": e.get("modulename") or None, "due_at": local_iso(e["timestart"]),
                    "url": e.get("url") or None, "overdue": bool(e.get("overdue"))}
    return sorted(out.values(), key=lambda d: (d["due_at"], d["title"], d["id"]))


def fetch_deadline_events(call: Callable[[str, dict], dict], now: int) -> list[dict]:
    """Ereignisse aus beiden Kalender-Quellen; call(fn, args) ist REST (Schluessel) oder AJAX (Sitzung)."""
    events: list[dict] = []
    args = {"timesortfrom": now - DEADLINE_DAYS_BACK * 86400, "timesortto": now + DEADLINE_DAYS_AHEAD * 86400, "limitnum": 50}
    for _ in range(DEADLINE_PAGES):
        d = call("core_calendar_get_action_events_by_timesort", args) or {}
        page = d.get("events") or []
        events += page
        if len(page) < args["limitnum"] or not d.get("lastid"):
            break
        args = {**args, "aftereventid": d["lastid"]}
    try:
        events += (call("core_calendar_get_calendar_upcoming_view", {"courseid": 1, "categoryid": 0}) or {}).get("events") or []
    except LearnwebError:
        pass        # Vorschau nur Ergaenzung ("Test beginnt"); die Fristen selbst kommen aus der ersten Quelle
    return events


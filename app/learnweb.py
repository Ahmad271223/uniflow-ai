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

import hashlib
import json
import mimetypes
import re
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


def file_id(cmid, filepath: str, filename: str) -> str:
    h = hashlib.sha1(f"{filepath or '/'}{filename}".encode("utf-8")).hexdigest()[:8]
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
    parts = [urllib.parse.unquote(p) for p in m.group(3).split("/") if p]
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
                name = c.get("filename") or "datei"
                out.append({
                    "id": file_id(mod["id"], fp, name),
                    "name": name,
                    "size": int(c.get("filesize") or 0),
                    "mime": c.get("mimetype") or guess_mime(name),
                    "author": c.get("author"),
                    "chdate": int(c.get("timemodified") or 0),
                    "download_url": strip_forcedownload(c["fileurl"]),
                    "folder": join_folder(base_folder, fp),
                    "module_name": mod.get("name"),
                })
    return out


def _course(c: dict) -> dict:
    p = parse_course_title(c.get("fullname") or c.get("displayname") or "")
    return {"id": f"lw-{c['id']}", "moodle_id": int(c["id"]), "title": p["title"], "number": p["number"],
            "semester": p["semester"], "hidden": bool(c.get("hidden"))}


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

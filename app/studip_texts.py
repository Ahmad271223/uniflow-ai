"""Lernstoff aus Stud.IP (2.11.2026): Courseware-Aufgaben mit Abgabefrist, Courseware-Inhalte, Wiki und Forum der
aktuellen Kurse, nur lesend ueber die JSON:API (nie POST/PATCH, nichts "als gelesen" markieren, keine Abos).

- Fristen der Courseware-Aufgaben landen in der vorhandenen Tabelle `deadlines` (source 'studip', module
  'courseware'): Planer, Stundenplan, "Abgaben & Prüfungen" und Naechste Termine zeigen sie wie die Learnweb-Fristen.
- Texte (Courseware-Seiten, Wiki-Seiten, Forum-Themen) stehen in EINER schlanken Tabelle `studip_texts` (Art
  courseware | wiki | forum) und dienen als Lernstoff: KI-Hilfe (Tutor-Quellen), Skriptsuche (/api/related) und
  Wochentests (nur Courseware und Wiki, gekuerzt, mit Herkunft). Forenbeitraege ohne Autorennamen (Datenschutz).
- Last: hoechstens MAX_REQUESTS Anfragen je Abgleich fuer diese Quellen, je Kurs ein gerechter Anteil; Pausen macht
  der Client wie bei allen Stud.IP-Anfragen. Aenderungserkennung ueber `chdate`: Unveraendertes wird nicht neu geladen
  (spaetestens nach RECHECK_DAYS doch, falls Stud.IP chdate nicht weiterzaehlt).
- Fehlt eine Funktion (HTTP 400/403/404/405), merkt sich `studip_text_state` das je Kurs; antwortet sie in einem
  Abgleich nirgends, aber mindestens zweimal "nicht vorhanden", gilt sie an der Hochschule als nicht vorhanden. Beides
  wird erst nach RECHECK_DAYS Tagen wieder gefragt.

ANNAHMEN zur JSON:API (Stud.IP 5.x/6.x, an der LUH erst mit echtem Konto pruefbar; defensiv gelesen):
- Aufgaben: `courseware-tasks?filter[cid]=` mit include task-group, structural-element (Attribute `submission-date`,
  `submitted`, `renewal`/`renewal-state`, `renewal-date`); Ersatzweg `courses/{id}/courseware-task-groups`
  (Attribute `title`, `end-date`). Fristfeld nicht sicher belegt: submission-date, sonst end-date der Gruppe.
- Courseware: `courses/{id}/courseware-units?include=structural-element` (Beziehung `structural-element` = Wurzel),
  `courseware-structural-elements/{id}/children`, `.../containers?include=blocks`, ersatzweise
  `courseware-containers/{id}/blocks`. Block: `block-type` und `payload` (Objekt oder JSON-Text).
- Wiki: `courses/{id}/wiki-pages` mit `keyword`|`name`|`title`, `content-html`|`content`, `chdate`.
- Forum: `courses/{id}/forum-categories`, `forum-categories/{id}/entries`, `forum-entries/{id}/entries` mit `title`,
  `content-html`|`content`, `chdate`. Beziehungen zu Personen (author) werden nie gelesen. Pfade am Stud.IP-Quelltext
  bestaetigt (lib/classes/JsonApi/RouteMap.php, 03.11.2026); 404 der Kategorienliste heisst "noch keine Kategorie"
  (NoForum), 404 der Antworten "keine Antworten".
- Links (nur zum Oeffnen in Stud.IP): Pfade unter dispatch.php/plugins.php wie unten, nicht belegt.
Der Swift-Kern (StudIPTexts.swift) rechnet gleich; Vertrag packages/shared-contracts/fixtures/studip-texts.
"""
from __future__ import annotations

import json
import re
from collections import Counter
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

from . import scriptsearch
from .announcements import html_to_text

KINDS = ("courseware", "wiki", "forum")
KIND_LABELS = {"courseware": "Courseware", "wiki": "Wiki", "forum": "Forum"}
FEATURES = ("tasks", "courseware", "wiki", "forum")
MAX_REQUESTS = 200            # je Abgleich fuer diese Quellen zusammen
MIN_COURSE_REQUESTS = 12      # Anteil je Kurs mindestens (solange noch Anfragen frei sind)
MAX_PAGES = 40                # Courseware-Seiten je Kurs
MAX_DEPTH = 4                 # Tiefe im Courseware-Baum
MAX_WIKI = 30                 # Wiki-Seiten je Kurs
MAX_FORUM = 20                # Forum-Themen je Kurs
MAX_TEXT = 8000               # Zeichen je gespeichertem Text
RECHECK_DAYS = 14
ABSENT_STATUS = (400, 403, 404, 405)
API = "jsonapi.php/v1/"

TABLES = (
    """CREATE TABLE IF NOT EXISTS studip_texts (
    id TEXT PRIMARY KEY,
    course_id TEXT NOT NULL,
    kind TEXT NOT NULL,
    title TEXT NOT NULL,
    text TEXT NOT NULL,
    url TEXT,
    changed TEXT,
    fetched_at TEXT
)""",
    "CREATE INDEX IF NOT EXISTS ix_studip_texts_course ON studip_texts(course_id, kind)",
    "CREATE TABLE IF NOT EXISTS studip_text_state (key TEXT PRIMARY KEY, value TEXT)",
)


def ensure_tables(conn) -> None:
    for sql in TABLES:
        conn.execute(sql)


def has_tables(conn) -> bool:
    return conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='studip_texts'").fetchone() is not None


# ---------------------------------------------------------------- Anfragen

class SessionExpired(Exception):
    pass


class Absent(Exception):
    """HTTP 400/403/404/405: Funktion im Kurs bzw. an der Hochschule nicht vorhanden."""


class Failed(Exception):
    """Anderer Fehler: Gespeichertes bleibt, nichts wird als "nicht vorhanden" gemerkt."""


class NoForum(Exception):
    """`courses/{id}/forum-categories` antwortet 404, solange der Kurs noch keine Forum-Kategorie hat (Stud.IP legt sie
    erst beim ersten Oeffnen des Forums an; JsonApi ForumCategoriesIndex wirft RecordNotFound bei leerer Liste, geprueft
    03.11.2026 am Stud.IP-Quelltext). Kein fehlendes Forum: je Kurs gemerkt, zaehlt nicht fuer die Hochschule."""


class Stop(Exception):
    """Anfragen dieses Kurses bzw. Abgleichs aufgebraucht (oder kein Netz): Gespeichertes bleibt."""


class Api:
    """Nur GET. `get(path)` -> (HTTP-Status, JSON oder None); 401 heisst Anmeldung abgelaufen."""

    def __init__(self, get, budget: int = MAX_REQUESTS):
        self._get = get
        self.budget = budget
        self.limit = budget
        self.used = 0
        self.log: list[str] = []
        self.last_status = 0

    @staticmethod
    def norm(path: str) -> str:
        if path.startswith("http://") or path.startswith("https://"):
            path = "/" + path.split("/", 3)[3] if path.count("/") >= 3 else "/"
        return "/" + path.lstrip("/")

    def _fetch(self, path: str) -> dict:
        p = self.norm(path)
        self.used += 1
        self.log.append(p)
        status, body = self._get(p)
        self.last_status = status
        if status == 401:
            raise SessionExpired()
        if status in ABSENT_STATUS:
            raise Absent()
        if not 200 <= status < 300 or not isinstance(body, dict):
            raise Failed()
        return body

    def list(self, path: str) -> tuple[list, list]:
        """Alle Seiten (links.next) wie StudIPClient.list; die Grenze gilt vor jeder Liste."""
        if self.used >= self.limit:
            raise Stop()
        data, included, nxt, seen = [], [], path, set()
        while nxt and nxt not in seen:
            seen.add(nxt)
            try:
                body = self._fetch(nxt)
            except Absent:
                if nxt != path:                  # eine Folgeseite fehlt: Teilstand, nicht "nicht vorhanden"
                    raise Failed() from None
                raise
            if not isinstance(body.get("data"), list):
                raise Failed()
            data += body["data"]
            included += body.get("included") or []
            nxt = (body.get("links") or {}).get("next")
            nxt = nxt if isinstance(nxt, str) else None
        return data, included

    def one(self, path: str) -> dict:
        if self.used >= self.limit:
            raise Stop()
        d = self._fetch(path).get("data")
        if not isinstance(d, dict):
            raise Failed()
        return d


# ---------------------------------------------------------------- Lesen der Antworten

def _attrs(x) -> dict:
    a = x.get("attributes") if isinstance(x, dict) else None
    return a if isinstance(a, dict) else {}


def _rel_id(x, name: str):
    r = (x.get("relationships") or {}).get(name) if isinstance(x, dict) else None
    d = r.get("data") if isinstance(r, dict) else None
    i = d.get("id") if isinstance(d, dict) else None
    return i if isinstance(i, str) else None


def _text(v) -> str:
    return v if isinstance(v, str) else ""


def _first(a: dict, *keys) -> str:
    for k in keys:
        v = a.get(k)
        if isinstance(v, str) and v.strip():
            return v
    return ""


def _changed(a: dict) -> str:
    """chdate (sonst mkdate) als Text; Zahlen (Unix-Zeit) ganzzahlig"""
    for k in ("chdate", "mkdate"):
        v = a.get(k)
        if isinstance(v, bool):
            continue
        if isinstance(v, str) and v:
            return v
        if isinstance(v, (int, float)):
            return str(int(v))
    return ""


def _truthy(v) -> bool:
    return v is True or v == 1 or (isinstance(v, str) and v.lower() in ("1", "true", "yes"))


def squash(t: str) -> str:
    """Leerraum wie html_to_text: Leerzeichen zusammen, Zeilen ohne Rand"""
    t = (t or "").replace("\xa0", " ")
    t = re.sub(r"[ \t]+", " ", t)
    return re.sub(r"\s*\n\s*", "\n", t).strip()


def markup_to_text(t: str) -> str:
    """Stud.IP-Formatierung (Wiki, Forum) grob als Text: Links, Ueberschriften, Hervorhebungen ohne Zeichen."""
    t = re.sub(r"\[\[[^\]|]*\|([^\]]*)\]\]", r"\1", t or "")
    t = re.sub(r"\[\[([^\]]*)\]\]", r"\1", t)
    t = re.sub(r"(?m)^!{1,4}\s*", "", t)
    for mark in ("**", "%%", "__", "{{", "}}"):
        t = t.replace(mark, "")
    return squash(t)


def rich_to_text(t: str) -> str:
    """HTML oder Stud.IP-Formatierung"""
    t = t or ""
    return html_to_text(t) if re.search(r"<[a-zA-Z/][^>]*>", t) else markup_to_text(t)


def anonymize(t: str) -> str:
    """Forenbeitraege ohne Personen: Zitate (mit Namen der Zitierten) und @Erwaehnungen fallen weg."""
    t = re.sub(r"(?is)\[quote[^\]]*\].*?\[/quote\]", " ", t or "")
    t = re.sub(r"(?is)<blockquote\b.*?</blockquote>", " ", t)
    return re.sub(r"(?<![\w@])@[\w.\-]+", "@…", t)


def cut(t: str, n: int = MAX_TEXT) -> str:
    t = t.strip()
    if len(t) <= n:
        return t
    head = t[:n]
    i = head.rfind(" ")
    return (head[:i] if i > 0 else head) + " …"


def payload(a: dict) -> dict:
    p = a.get("payload")
    if isinstance(p, str):
        try:
            p = json.loads(p)
        except ValueError:
            return {}
    return p if isinstance(p, dict) else {}


def block_text(block: dict) -> str:
    """Text eines Courseware-Blocks: Text, Ueberschrift, Code, Formel; Dateibloecke nur als Verweis; Rest nichts.
    Annahme: block-type-Namen wie in Stud.IP 5 (text, headline, code, key-point, typewriter, document, download,
    folder); Formelbloecke ("katex", "math", "formula") sind nicht belegt."""
    a = _attrs(block)
    kind = _text(a.get("block-type")).lower()
    p = payload(a)
    if kind in ("text", "key-point", "typewriter"):
        return html_to_text(_text(p.get("text")))
    if kind == "headline":
        return squash("\n".join(x for x in (_text(p.get("title")), _text(p.get("subtitle"))) if x.strip()))
    if kind == "code":
        return _text(p.get("content")).strip()
    if kind in ("katex", "math", "formula"):
        return _first(p, "formula", "content", "text").strip()
    if kind in ("document", "download", "folder"):
        name = squash(_first(p, "title", "name", "file_name", "filename")) or "ohne Titel"
        return f"[{'Ordner' if kind == 'folder' else 'Datei'}: {name}]"
    return ""


def berlin_local(v) -> str | None:
    """ISO-Zeitpunkt aus Stud.IP -> Ortszeit Berlin 'YYYY-MM-DDTHH:MM' (wie learnweb.local_iso); ohne Zone schon
    Ortszeit, reines Datum -> 23:59. Anderes (Zahlen, unlesbar) -> None."""
    if not isinstance(v, str) or not re.match(r"^\d{4}-\d{2}-\d{2}", v.strip()):
        return None
    s = v.strip()
    if len(s) == 10:
        try:
            date.fromisoformat(s)
        except ValueError:
            return None
        return s + "T23:59"
    try:
        d = datetime.fromisoformat(s.replace("Z", "+00:00").replace(" ", "T", 1))
    except ValueError:
        return None
    if d.tzinfo is not None:
        d = d.astimezone(ZoneInfo("Europe/Berlin"))
    return d.strftime("%Y-%m-%dT%H:%M")


def links(base: str) -> dict:
    """Links in Stud.IP (Annahme, nur zum Oeffnen)"""
    b = base.rstrip("/")
    return {
        "tasks": lambda cid: f"{b}/dispatch.php/course/courseware/tasks?cid={cid}",
        "courseware": lambda cid, eid: f"{b}/dispatch.php/course/courseware/?cid={cid}#/structural_element/{eid}",
        "wiki": lambda cid, pid: f"{b}/dispatch.php/course/wiki/page/{pid}?cid={cid}",
        "forum": lambda cid, eid: f"{b}/plugins.php/coreforum/index/index/{eid}?cid={cid}#{eid}",
    }


def task_deadline(task: dict, included: dict, course_id: str, base: str) -> dict | None:
    """Frist einer Courseware-Aufgabe (eigene Aufgabe des Nutzers); abgegebene fallen weg."""
    a = _attrs(task)
    tid = task.get("id")
    if not isinstance(tid, str) or _truthy(a.get("submitted")):
        return None
    group = included.get(("courseware-task-groups", _rel_id(task, "task-group")), {})
    element = included.get(("courseware-structural-elements", _rel_id(task, "structural-element")), {})
    granted = _text(a.get("renewal")).lower() == "granted" or _text(a.get("renewal-state")).lower() == "granted"
    due = (berlin_local(a.get("renewal-date")) if granted else None) or berlin_local(a.get("submission-date")) \
        or berlin_local(_attrs(group).get("end-date"))
    if not due:
        return None
    title = squash(_first(_attrs(group), "title") or _first(_attrs(element), "title")) or "Courseware-Aufgabe"
    return {"id": f"sp-cw-{tid}", "course_id": course_id, "title": title, "full_title": f"{title} · Stud.IP Courseware",
            "due_at": due, "url": links(base)["tasks"](course_id)}


def group_deadline(group: dict, course_id: str, base: str) -> dict | None:
    """Ersatzweg ueber Aufgabengruppen des Kurses: Frist der Gruppe"""
    a = _attrs(group)
    gid = group.get("id")
    due = berlin_local(a.get("end-date")) or berlin_local(a.get("submission-date"))
    if not isinstance(gid, str) or not due:
        return None
    title = squash(_first(a, "title")) or "Courseware-Aufgabe"
    return {"id": f"sp-cwg-{gid}", "course_id": course_id, "title": title, "full_title": f"{title} · Stud.IP Courseware",
            "due_at": due, "url": links(base)["tasks"](course_id)}


# ---------------------------------------------------------------- Abruf

def _day(s) -> date | None:
    try:
        return date.fromisoformat(str(s)[:10])
    except ValueError:
        return None


def load(conn) -> tuple[dict, dict]:
    """Stand vor dem Abruf: bekannte Texte {id: (changed, fetched_at)} und Merker (state)"""
    if not has_tables(conn):
        return {}, {}
    known = {r[0]: (r[1] or "", r[2] or "") for r in conn.execute("SELECT id, changed, fetched_at FROM studip_texts").fetchall()}
    state = {r[0]: r[1] for r in conn.execute("SELECT key, value FROM studip_text_state").fetchall()}
    return known, state


def _fresh(known: dict, rid: str, changed: str, today: date) -> bool:
    k = known.get(rid)
    if not k or not changed or k[0] != changed:
        return False
    d = _day(k[1])
    return d is not None and (today - d).days < RECHECK_DAYS


def _absent(state: dict, key: str, today: date) -> bool:
    d = _day(state.get(key) or "")
    return d is not None and today < d


def fetch(get, courses: list[dict], known: dict, state: dict, today: date, base: str, budget: int = MAX_REQUESTS) -> dict:
    """Liest Aufgaben, Courseware, Wiki und Forum der Kurse (`courses`: aktuelle Kurse mit id). Wirft nur bei
    abgelaufener Sitzung (SessionExpired); alles andere steht im Ergebnis. Netzwerk vor dem Speichern (`store`)."""
    api = Api(get, budget)
    until = (today + timedelta(days=RECHECK_DAYS)).isoformat()
    out = {"courses": [], "state_set": {}, "state_del": [], "stopped": False}
    seen_ok = Counter()
    seen_absent = Counter()
    st = dict(state)

    def mark_absent(feature: str, cid: str) -> None:
        seen_absent[feature] += 1
        out["state_set"][f"absent|{feature}|{cid}"] = until
        st[f"absent|{feature}|{cid}"] = until

    def skip(feature: str, cid: str) -> bool:
        return _absent(st, f"absent|{feature}", today) or _absent(st, f"absent|{feature}|{cid}", today)

    for i, c in enumerate(courses):
        cid = c["id"]
        left = api.budget - api.used
        if left <= 0:
            out["stopped"] = True
            break
        api.limit = api.used + min(left, max(MIN_COURSE_REQUESTS, left // (len(courses) - i)))
        res = {"course_id": cid, "rows": [], "seen": {k: [] for k in KINDS}, "complete": {k: False for k in KINDS},
               "deadlines": None, "deadlines_complete": False}
        out["courses"].append(res)
        for feature, fn in (("tasks", _fetch_tasks), ("courseware", _fetch_courseware), ("wiki", _fetch_wiki), ("forum", _fetch_forum)):
            if skip(feature, cid):
                continue
            try:
                fn(api, cid, res, known, today, base, st, out)
                seen_ok[feature] += 1
                if f"absent|{feature}|{cid}" in st:
                    out["state_del"].append(f"absent|{feature}|{cid}")
            except Absent:
                mark_absent(feature, cid)
            except NoForum:
                # noch keine Forum-Kategorie im Kurs: bis zur Nachpruefung nicht wieder fragen, zaehlt nicht fuer die Hochschule
                out["state_set"][f"absent|{feature}|{cid}"] = until
                st[f"absent|{feature}|{cid}"] = until
            except (Failed, Stop):
                pass
    for f in FEATURES:
        if not seen_ok[f] and seen_absent[f] >= 2:
            out["state_set"][f"absent|{f}"] = until
    out["requests"] = api.used
    out["log"] = api.log
    return out


def _fetch_tasks(api: Api, cid: str, res: dict, known, today, base, st: dict, out: dict) -> None:
    path = st.get("tasks_path")
    order = [path] if path in ("1", "2") else ["1", "2"]
    for n, p in enumerate(order):
        try:
            if p == "1":
                data, inc = api.list(f"{API}courseware-tasks?filter[cid]={cid}&include=task-group,structural-element&page[limit]=100")
                included = {(x.get("type"), x.get("id")): x for x in inc if isinstance(x, dict)}
                items = [d for d in (task_deadline(t, included, cid, base) for t in data if isinstance(t, dict)) if d]
            else:
                data, _ = api.list(f"{API}courses/{cid}/courseware-task-groups?page[limit]=100")
                items = [d for d in (group_deadline(g, cid, base) for g in data if isinstance(g, dict)) if d]
        except Absent:
            if n + 1 < len(order):
                continue
            raise
        if path != p:
            out["state_set"]["tasks_path"] = p
            st["tasks_path"] = p
        res["deadlines"] = items
        res["deadlines_complete"] = True
        return


def _element_text(api: Api, eid: str) -> str:
    containers, inc = api.list(f"{API}courseware-structural-elements/{eid}/containers?include=blocks&page[limit]=100")
    blocks = [x for x in inc if isinstance(x, dict) and x.get("type") == "courseware-blocks"]
    parts: list[str] = []
    if blocks:
        by_container: dict = {}
        loose = []
        for b in blocks:
            k = _rel_id(b, "container")
            (by_container.setdefault(k, []) if k else loose).append(b)
        ordered = [b for ct in containers if isinstance(ct, dict) for b in by_container.pop(ct.get("id"), [])]
        ordered += [b for k in by_container for b in by_container[k]] + loose
        parts = [block_text(b) for b in ordered]
    else:
        for ct in containers:
            if not isinstance(ct, dict) or not isinstance(ct.get("id"), str):
                continue
            data, _ = api.list(f"{API}courseware-containers/{ct['id']}/blocks?page[limit]=100")
            parts += [block_text(b) for b in data if isinstance(b, dict)]
    return "\n\n".join(p for p in parts if p.strip())


def _fetch_courseware(api: Api, cid: str, res: dict, known, today, base, st, out) -> None:
    units, inc = api.list(f"{API}courses/{cid}/courseware-units?include=structural-element&page[limit]=50")
    elements = {x.get("id"): x for x in inc if isinstance(x, dict) and x.get("type") == "courseware-structural-elements"}
    link = links(base)["courseware"]
    count = 0
    complete = True

    def visit(eid: str, attrs: dict, depth: int) -> None:
        nonlocal count, complete
        if count >= MAX_PAGES:
            return
        count += 1
        rid = f"cw-{eid}"
        changed = _changed(attrs)
        title = squash(_first(attrs, "title")) or "Courseware"
        res["seen"]["courseware"].append(rid)
        if not _fresh(known, rid, changed, today):
            try:
                text = _element_text(api, eid)
            except Absent:
                text = ""
            except Failed:
                complete = False
                text = None
            if text:
                res["rows"].append({"id": rid, "kind": "courseware", "title": title, "text": cut(text), "url": link(cid, eid), "changed": changed})
            elif text == "":
                res["seen"]["courseware"].remove(rid)          # ohne Text: kein Eintrag (ein alter faellt weg)
        if depth >= MAX_DEPTH:
            return
        try:
            children, _ = api.list(f"{API}courseware-structural-elements/{eid}/children?page[limit]=100")
        except Absent:
            return
        except Failed:
            complete = False
            return
        for ch in children:
            if isinstance(ch, dict) and isinstance(ch.get("id"), str):
                visit(ch["id"], _attrs(ch), depth + 1)

    try:
        for u in units:
            root = _rel_id(u, "structural-element")
            if root:
                visit(root, _attrs(elements.get(root, {})), 0)
    except Stop:
        complete = False
    res["complete"]["courseware"] = complete


def _fetch_wiki(api: Api, cid: str, res: dict, known, today, base, st, out) -> None:
    pages, _ = api.list(f"{API}courses/{cid}/wiki-pages?page[limit]=100")
    link = links(base)["wiki"]
    complete = True
    for p in [p for p in pages if isinstance(p, dict) and isinstance(p.get("id"), str)][:MAX_WIKI]:
        a = _attrs(p)
        rid = f"wiki-{p['id']}"
        changed = _changed(a)
        res["seen"]["wiki"].append(rid)
        if known.get(rid, ("",))[0] == changed and changed:
            continue
        content = a.get("content-html") if isinstance(a.get("content-html"), str) else a.get("content")
        if not isinstance(content, str):
            try:
                content = _first(_attrs(api.one(f"{API}wiki-pages/{p['id']}")), "content-html", "content")
            except (Failed, Absent, Stop):
                complete = False
                continue
        text = rich_to_text(content)
        title = squash(_first(a, "keyword", "name", "title")) or "Wiki"
        if text:
            res["rows"].append({"id": rid, "kind": "wiki", "title": title, "text": cut(text), "url": link(cid, p["id"]), "changed": changed})
        else:
            res["seen"]["wiki"].remove(rid)
    res["complete"]["wiki"] = complete


def _posting(a: dict) -> str:
    raw = a.get("content-html") if isinstance(a.get("content-html"), str) else _text(a.get("content"))
    return rich_to_text(anonymize(raw))


def _fetch_forum(api: Api, cid: str, res: dict, known, today, base, st, out) -> None:
    try:
        cats, _ = api.list(f"{API}courses/{cid}/forum-categories?page[limit]=50")
    except Absent:
        if api.last_status == 404:
            raise NoForum() from None
        raise
    link = links(base)["forum"]
    complete = True
    count = 0
    try:
        for cat in cats:
            if count >= MAX_FORUM:
                break
            if not isinstance(cat, dict) or not isinstance(cat.get("id"), str):
                continue
            try:
                entries, _ = api.list(f"{API}forum-categories/{cat['id']}/entries?page[limit]=50")
            except (Absent, Failed):
                complete = False
                continue
            for e in entries:
                if count >= MAX_FORUM:
                    break
                if not isinstance(e, dict) or not isinstance(e.get("id"), str):
                    continue
                count += 1
                a = _attrs(e)
                rid = f"forum-{e['id']}"
                changed = _changed(a)
                res["seen"]["forum"].append(rid)
                if _fresh(known, rid, changed, today):
                    continue
                try:
                    posts, _ = api.list(f"{API}forum-entries/{e['id']}/entries?page[limit]=100")
                except Absent:
                    posts = []
                except Failed:
                    complete = False
                    continue
                parts = [_posting(a)]
                for x in posts:
                    if isinstance(x, dict):
                        pa = _attrs(x)
                        parts.append("\n".join(y for y in (squash(_first(pa, "title")), _posting(pa)) if y))
                text = "\n---\n".join(y for y in parts if y)
                title = squash(_first(a, "title", "name")) or "Forum"
                if text:
                    res["rows"].append({"id": rid, "kind": "forum", "title": title, "text": cut(text), "url": link(cid, e["id"]), "changed": changed})
                else:
                    res["seen"]["forum"].remove(rid)
    except Stop:
        complete = False
    res["complete"]["forum"] = complete


# ---------------------------------------------------------------- Speichern

def store(conn, download: dict, now: str) -> dict:
    """Abruf in die Datenbank (in einer Transaktion): Texte ersetzen je vollstaendig gelesener Art, Fristen in
    `deadlines` (source 'studip', module 'courseware'). Rueckgabe: neue/geaenderte Texte und Fristen."""
    ensure_tables(conn)
    changed = 0
    deadlines = 0
    for res in download["courses"]:
        cid = res["course_id"]
        for r in res["rows"]:
            conn.execute("""INSERT INTO studip_texts(id, course_id, kind, title, text, url, changed, fetched_at) VALUES (?,?,?,?,?,?,?,?)
                            ON CONFLICT(id) DO UPDATE SET course_id=excluded.course_id, kind=excluded.kind, title=excluded.title,
                            text=excluded.text, url=excluded.url, changed=excluded.changed, fetched_at=excluded.fetched_at""",
                         (r["id"], cid, r["kind"], r["title"], r["text"], r["url"], r["changed"], now))
            changed += 1
        for kind in KINDS:
            if not res["complete"][kind]:
                continue
            keep = set(res["seen"][kind]) | {r["id"] for r in res["rows"] if r["kind"] == kind}
            for (rid,) in conn.execute("SELECT id FROM studip_texts WHERE course_id=? AND kind=? ORDER BY id", (cid, kind)).fetchall():
                if rid not in keep:
                    conn.execute("DELETE FROM studip_texts WHERE id=?", (rid,))
        if res["deadlines"] is not None:
            ids = []
            for d in res["deadlines"]:
                conn.execute("""INSERT INTO deadlines(id, source, course_id, title, full_title, kind, module, due_at, url, overdue, fetched_at)
                                VALUES (?, 'studip', ?, ?, ?, 'abgabe', 'courseware', ?, ?, 0, ?)
                                ON CONFLICT(id) DO UPDATE SET course_id=excluded.course_id, title=excluded.title, full_title=excluded.full_title,
                                kind=excluded.kind, module=excluded.module, due_at=excluded.due_at, url=excluded.url, fetched_at=excluded.fetched_at""",
                             (d["id"], cid, d["title"], d["full_title"], d["due_at"], d["url"], now))
                ids.append(d["id"])
                deadlines += 1
            if res["deadlines_complete"]:
                marks = ",".join("?" * len(ids)) or "''"
                conn.execute(f"DELETE FROM deadlines WHERE source='studip' AND module='courseware' AND course_id=? AND id NOT IN ({marks})",
                             (cid, *ids))
    for k, v in sorted(download["state_set"].items()):
        conn.execute("INSERT OR REPLACE INTO studip_text_state(key, value) VALUES (?,?)", (k, v))
    for k in download["state_del"]:
        if k not in download["state_set"]:
            conn.execute("DELETE FROM studip_text_state WHERE key=?", (k,))
    return {"texts": changed, "deadlines": deadlines}


def summary(result: dict | None) -> list[str]:
    """Teile fuer die Zusammenfassung des Abgleichs (nur wenn es etwas Neues gab)"""
    if not result:
        return []
    parts = []
    if result.get("texts"):
        parts.append(f"{result['texts']} Lerntexte aus Stud.IP")
    if result.get("deadlines"):
        parts.append(f"{result['deadlines']} Courseware-{'Frist' if result['deadlines'] == 1 else 'Fristen'}")
    return parts


# ---------------------------------------------------------------- Lesen: Modulansicht, Suche, KI

def _rows(conn, module_id, kinds=KINDS) -> list[dict]:
    if not has_tables(conn):
        return []
    marks = ",".join("?" * len(kinds))
    cur = conn.execute(f"""SELECT t.id, t.kind, t.title, t.text, t.url, t.changed, c.title AS course_title
                           FROM studip_texts t JOIN courses c ON c.id=t.course_id
                           WHERE c.module_id=? AND c.active=1 AND t.kind IN ({marks}) ORDER BY t.id""", (module_id, *kinds))
    cols = [d[0] for d in cur.description]
    return [dict(zip(cols, r)) for r in cur.fetchall()]


def _day_text(changed: str) -> str:
    """Tag der Aenderung 'YYYY-MM-DD' (ISO) bzw. aus Unix-Zeit; sonst leer"""
    if re.match(r"^\d{4}-\d{2}-\d{2}", changed or ""):
        return changed[:10]
    if re.fullmatch(r"\d{9,11}", changed or ""):
        return datetime.fromtimestamp(int(changed), ZoneInfo("Europe/Berlin")).strftime("%Y-%m-%d")
    return ""


def overview(conn, module_id) -> dict:
    """Bereich "Aus Stud.IP" der Modulansicht: je Art Anzahl, zuletzt geaendert und die Eintraege (neueste zuerst)"""
    groups = []
    rows = _rows(conn, module_id)
    for kind in KINDS:
        items = [r for r in rows if r["kind"] == kind]
        if not items:
            continue
        for r in items:
            r["day"] = _day_text(r["changed"] or "")
        items.sort(key=lambda r: (r["day"], r["id"]), reverse=True)
        groups.append({"kind": kind, "label": KIND_LABELS[kind], "count": len(items), "changed": items[0]["day"] or None,
                       "items": [{"id": r["id"], "title": r["title"], "course_title": r["course_title"], "changed": r["day"] or None,
                                  "url": r["url"]} for r in items[:30]]})
    return {"groups": groups, "total": sum(g["count"] for g in groups)}


def item(conn, text_id: str) -> dict | None:
    if not has_tables(conn):
        return None
    r = conn.execute("""SELECT t.id, t.kind, t.title, t.text, t.url, t.changed, c.title AS course_title FROM studip_texts t
                        LEFT JOIN courses c ON c.id=t.course_id WHERE t.id=?""", (text_id,)).fetchone()
    if not r:
        return None
    d = dict(zip(("id", "kind", "title", "text", "url", "changed", "course_title"), tuple(r)))
    d["kind_label"] = KIND_LABELS.get(d["kind"], d["kind"])
    d["changed"] = _day_text(d["changed"] or "") or None
    return d


def search(conn, module_id, query: str, kinds=KINDS, limit: int = 3) -> list[dict]:
    """Passende Stud.IP-Texte des Moduls zu einer Anfrage: Woerter wie die Skriptsuche (scriptsearch.tokens), Punkte
    = getroffene Woerter (mind. zwei, bei einem Wort eines) vor Haeufigkeit; ganzzahlig, damit Python und Swift gleich
    ordnen."""
    q = list(dict.fromkeys(scriptsearch.tokens(query or "")))
    if not q or module_id is None:
        return []
    need = 2 if len(q) >= 2 else 1
    scored = []
    for r in _rows(conn, module_id, kinds):
        tf = Counter(scriptsearch.tokens(r["title"] + "\n" + r["text"]))
        hit = [t for t in q if tf[t]]
        if len(hit) < need:
            continue
        scored.append((len(hit) * 1000 + min(999, sum(tf[t] for t in hit)), r, hit))
    scored.sort(key=lambda x: (-x[0], x[1]["id"]))
    return [{"id": r["id"], "kind": r["kind"], "kind_label": KIND_LABELS[r["kind"]], "title": r["title"], "course_title": r["course_title"],
             "url": r["url"], "score": s, "snippet": scriptsearch._snippet(scriptsearch.normalize(r["text"]), hit)}
            for s, r, hit in scored[:limit]]


def tutor_sources(conn, module_id, query: str, start: int, limit: int = 2) -> list[dict]:
    """Zusaetzliche Quellen fuer die KI-Hilfe (nummeriert ab `start`), gekuerzt, mit Herkunft"""
    return [{"n": start + i, "studip_id": h["id"], "kind": h["kind"], "title": f"{h['kind_label']}: {h['title']}", "name": h["title"],
             "page": None, "snippet": h["snippet"], "url": h["url"], "current": False}
            for i, h in enumerate(search(conn, module_id, query, limit=limit))]


def run(conn, get, courses: list[dict], base: str, today: date, now: str) -> dict:
    """Ein Durchgang am PC (app/studip_sync.py): Stand lesen, abrufen, speichern. SessionExpired geht weiter."""
    known, state = load(conn)
    d = fetch(get, courses, known, state, today, base)
    r = store(conn, d, now)
    r["requests"] = d["requests"]
    return r


def playwright_get(page, base: str):
    """`get` fuer `fetch` ueber die angemeldete Playwright-Seite; nur GET. Eine Anmeldeseite statt JSON heisst 401."""
    def get(path: str):
        try:
            r = page.request.get(base.rstrip("/") + path, headers={"Accept": "application/vnd.api+json"})
        except Exception:  # noqa: BLE001 - Netz: dieser Teil faellt aus, der Abgleich laeuft weiter
            return 0, None
        if r.status == 401 or "/dispatch.php/login" in (r.url or "") or "text/html" in (r.headers.get("content-type") or ""):
            return 401, None
        if not r.ok:
            return r.status, None
        try:
            return r.status, r.json()
        except Exception:  # noqa: BLE001
            return r.status, None
    return get


def weekly_lines(conn, module_id, query: str, limit: int = 2, chars: int = 600) -> list[str]:
    """Ergaenzung fuer den Wochentest: passende Courseware- und Wiki-Texte (kein Forum), gekuerzt, mit Herkunft"""
    out = []
    for h in search(conn, module_id, query, kinds=("courseware", "wiki"), limit=limit):
        r = item(conn, h["id"])
        text = re.sub(r"\s+", " ", (r or {}).get("text") or "").strip()
        out.append(f"{h['kind_label']} „{h['title']}“: {cut(text, chars)}")
    return out

"""Abgeben in Stud.IP aus dem Web-Editor - Windows-App/Einzelplatz (05.11.2026), wie die iPad-App
(apps/apple/.../StudIPSubmit.swift, docs/ABGEBEN-STUDIP-2026-11-05.md): die eigene Loesung (PDF mit Notizen,
Seitennotizen und Blaettern daneben, gebaut im Browser von derselben Funktion wie "PDF exportieren") in einen Ordner des
Stud.IP-Kurses hochladen. Nur auf Knopfdruck ("Jetzt abgeben"), nie im Abgleich, nie wiederholt (ein zweites Hochladen
legte eine zweite Datei an); die stille Erneuerung bei 401 zaehlt nicht (da hat Stud.IP nichts angenommen).

Routen (nur lokal; im Dienst 404):
  GET  /api/studip/submit?file_id=          Kurse (nur Stud.IP-Kennungen, aktiv; Kurse des Moduls oben, Vorauswahl),
                                            Verlauf des Dokuments, Hinweise
  GET  /api/studip/submit/folders?course_id=&title=
                                            live: beschreibbare Ordner (Abgabeordner zuerst, Vorauswahl), geschlossene
                                            Abgabeordner, Nachname aus users/me und Dateiname "Nachname_Blatt3.pdf"
  POST /api/studip/submit                   multipart: file (PDF), course_id, folder_id, file_name, document_id,
                                            with_notes, pages -> hochladen, Lizenz "selbst verfasst" (bester Versuch)
Verlauf `studip_submissions` in den Einstellungen dieses PCs (hoechstens 300, neueste zuerst; die PDF selbst nie).
"""
from __future__ import annotations

import json
import re
import unicodedata
import urllib.error
import uuid
from functools import cmp_to_key

from fastapi import APIRouter, File, Form, HTTPException, Query, UploadFile

from . import db, studip_live

router = APIRouter(prefix="/api/studip/submit", tags=["studip-submit"])

TYPICAL_LIMIT = 7 * 1024 * 1024
MAX_UPLOAD = 100 * 1024 * 1024
LOG_KEY = "studip_submissions"
LOG_LIMIT = 300
STUDIP_ID_RE = re.compile(r"^[0-9a-f]{32}$")
SUBMISSION_WORDS = ("abgabe", "hausaufgabe", "einreichung", "submission", "homework")
SHEET_RE = re.compile(r"(?<![a-zäöüß])(?:übungsblatt|uebungsblatt|aufgabenblatt|hausaufgabe|übung|uebung|blatt|sheet|exercise|"
                      r"assignment|ha|ü|ue|u)[\s_\-.:#]*(?:nr\.?\s*)?0*(\d{1,3})(?!\d)")
UMLAUTS = {"ä": "ae", "ö": "oe", "ü": "ue", "Ä": "Ae", "Ö": "Oe", "Ü": "Ue", "ß": "ss"}

WARNING = ("Die Datei wird an deine Hochschule hochgeladen (Stud.IP). Lehrende sehen sie; in normalen Ordnern auch andere "
           "Teilnehmende des Kurses.")
ERRORS = {
    "not_writable": "Dieser Ordner nimmt gerade keine Dateien an. Vielleicht ist die Abgabefrist vorbei oder der Ordner noch nicht geöffnet.",
    "too_large": "Die Datei ist zu groß für Stud.IP. Schicke sie ohne Notizen oder verkleinere eingefügte Bilder.",
    "security_token": "Stud.IP hat das Hochladen aus der App abgelehnt (Sicherheitsprüfung). Öffne den Ordner in Stud.IP und lade die Datei dort hoch.",
    "http": "Stud.IP antwortet mit HTTP {status}. Die Datei wurde nicht abgegeben.",
    "offline": "Keine Verbindung zu Stud.IP. Die Datei wurde nicht abgegeben.",
    "not_connected": "Stud.IP ist nicht verbunden. Melde dich unter Einstellungen → Zugang bei der Hochschule an.",
    "login": "Bitte bei Stud.IP anmelden (Einstellungen → Zugang), dann noch einmal „Jetzt abgeben“.",
}


class UploadError(Exception):
    def __init__(self, code: str, status: int | None = None):
        super().__init__(code)
        self.code, self.http_status = code, status

    @property
    def message(self) -> str:
        return ERRORS[self.code].format(status=self.http_status)


# ---------------------------------------------------------------------------- Regeln ohne Netz (wie der Swift-Kern)

def megabytes(n: int) -> str:
    mb = n / (1024 * 1024)
    return (f"{mb:.1f}" if mb < 10 else f"{mb:.0f}").replace(".", ",") + " MB"


def size_notice(n: int) -> str | None:
    if n <= TYPICAL_LIMIT:
        return None
    return f"Die Datei ist {megabytes(n)} groß. Manche Stud.IP-Ordner nehmen nur bis 7 MB an."


def sheet_number(title: str) -> int | None:
    m = SHEET_RE.search((title or "").lower())
    return int(m.group(1)) if m else None


def safe_component(s: str) -> str:
    out = []
    for ch in (s or "").strip():
        if ch in UMLAUTS:
            out.append(UMLAUTS[ch])
            continue
        if ch.isspace() or ch in "/\\":
            out.append("_")
            continue
        for c in unicodedata.normalize("NFD", ch):
            if c.isascii() and (c.isalnum() or c in "-_."):
                out.append(c)
    r = "".join(out)
    while "__" in r:
        r = r.replace("__", "_")
    return r.strip("_.-")


def proposed_file_name(family_name: str | None, title: str) -> str:
    """"Nachname_Blatt3.pdf"; ohne Nummer "Nachname_<Titel>.pdf"; ohne Nachnamen nur der Teil danach"""
    name = safe_component(family_name or "")
    n = sheet_number(title)
    if n is not None:
        part = f"Blatt{n}"
    else:
        t = (title or "").strip()
        if t.lower().endswith(".pdf"):
            t = t[:-4]
        c = safe_component(t)
        part = c[:60] if c else "Abgabe"
    return (f"{name}_{part}" if name else part) + ".pdf"


def final_file_name(text: str) -> str | None:
    t = (text or "").strip()
    if t.lower().endswith(".pdf"):
        t = t[:-4]
    c = safe_component(t)
    return c[:120] + ".pdf" if c else None


def multipart_body(boundary: str, file_name: str, mime: str, data: bytes, field: str = "file") -> bytes:
    safe = file_name.replace('"', "").replace("\r", "").replace("\n", "")
    head = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"{field}\"; filename=\"{safe}\"\r\n"
            f"Content-Type: {mime}\r\n\r\n").encode("utf-8")
    return head + data + f"\r\n--{boundary}--\r\n".encode("utf-8")


def is_homework(f: dict) -> bool:
    return f["folder_type"] == "HomeworkFolder"


def is_timed(f: dict) -> bool:
    return f["folder_type"] == "TimedFolder"


def looks_like_submission(f: dict) -> bool:
    if is_homework(f) or is_timed(f):
        return True
    n = (f["path"] or f["name"]).lower()
    return any(w in n for w in SUBMISSION_WORDS)


def label(f: dict) -> str:
    return f["path"] or "Hauptordner"


def _rank(f: dict) -> int:
    return 0 if is_homework(f) else 1 if looks_like_submission(f) else 3 if not f["path"] else 2


def _natural(s: str) -> list:
    return [int(t) if t.isdigit() else t for t in re.split(r"(\d+)", s.casefold())]


def folders(data: list, course_id: str) -> dict:
    """Ordnerliste aus `courses/{id}/folders` (flach, mit `parent`): beschreibbare und sichtbare Ordner, Abgabeordner
    zuerst; geschlossene Abgabeordner getrennt. Ohne `is-writable` gilt ein Ordner als nicht beschreibbar."""
    names, parents, types = {}, {}, {}
    for f in data:
        if not isinstance(f, dict) or not f.get("id"):
            continue
        a = f.get("attributes") if isinstance(f.get("attributes"), dict) else {}
        fid = str(f["id"])
        names[fid] = str(a.get("name") or "").strip()
        types[fid] = str(a.get("folder-type") or "")
        p = ((f.get("relationships") or {}).get("parent") or {}).get("data") if isinstance(f.get("relationships"), dict) else None
        if isinstance(p, dict) and p.get("id"):
            parents[fid] = str(p["id"])

    def path(fid: str) -> str:
        parts, cur, seen = [], fid, set()
        while cur and cur not in seen and types.get(cur) != "RootFolder" and cur in names:
            seen.add(cur)
            parts.append(names[cur])
            cur = parents.get(cur)
        return "/".join(p for p in reversed(parts) if p)

    writable, closed = [], []
    for f in data:
        if not isinstance(f, dict) or not f.get("id"):
            continue
        a = f.get("attributes") if isinstance(f.get("attributes"), dict) else {}
        if a.get("is-visible") is False:
            continue
        fid = str(f["id"])
        t = types.get(fid, "")
        item = {"id": fid, "course_id": course_id, "name": names.get(fid, ""), "path": "" if t == "RootFolder" else path(fid),
                "folder_type": t, "is_writable": a.get("is-writable") is True}
        item.update(is_homework=is_homework(item), is_submission=looks_like_submission(item), label=label(item))
        if item["is_writable"]:
            writable.append(item)
        elif is_homework(item) or is_timed(item):
            closed.append(item)

    def order(x, y):
        rx, ry = _rank(x), _rank(y)
        if rx != ry:
            return rx - ry
        ax, ay = _natural(x["label"]), _natural(y["label"])
        return (ax > ay) - (ax < ay)

    writable.sort(key=cmp_to_key(order))
    closed.sort(key=cmp_to_key(order))
    suggested = next((f for f in writable if f["is_homework"]), None) or next((f for f in writable if f["is_submission"]), None)
    return {"writable": writable, "closed": closed, "suggested": suggested["id"] if suggested else None}


def folder_web_url(base: str, course_id: str, folder_id: str) -> str:
    return f"{base.rstrip('/')}/dispatch.php/course/files/index/{folder_id}?cid={course_id}"


def upload_error(status: int, data: bytes) -> UploadError | None:
    if 200 <= status < 300:
        return None
    text = data[:4000].decode("utf-8", "replace").lower()
    size = any(k in text for k in ("zu groß", "zu gross", "too large", "too big", "maximal", "upload_max", "filesize",
                                    "dateigröße", "dateigroesse"))
    if status == 413:
        return UploadError("too_large", 413)
    if status == 403:
        if any(k in text for k in ("csrf", "security token", "sicherheits", "security_token")):
            return UploadError("security_token", 403)
        return UploadError("too_large", 403) if size else UploadError("not_writable", 403)
    if status in (400, 422):
        return UploadError("too_large", status) if size else UploadError("http", status)
    return UploadError("http", status)


def file_ref_id(location: str | None, data: bytes) -> str | None:
    if location and "file-refs/" in location:
        rest = re.split(r"[/?#]", location.split("file-refs/", 1)[1])[0]
        if rest:
            return rest
    try:
        j = json.loads(data.decode("utf-8")) if data else None
    except (ValueError, UnicodeDecodeError):
        j = None
    if isinstance(j, dict) and isinstance(j.get("data"), dict) and j["data"].get("id"):
        return str(j["data"]["id"])
    return None


def own_work_license_id(items: list) -> str | None:
    ids = [str(t.get("id")) for t in items if isinstance(t, dict) and t.get("id")]
    exact = next((i for i in ids if i.upper() == "SELFMADE_NONPUB"), None)
    if exact:
        return exact
    for t in items:
        if not isinstance(t, dict):
            continue
        n = str((t.get("attributes") or {}).get("name") or "").lower()
        if any(k in n for k in ("selbst verfasst", "selbstverfasst", "self-made", "selfmade")) and \
                any(k in n for k in ("nicht", "non", "not")):
            return str(t.get("id"))
    return None


# ---------------------------------------------------------------------------- Kurse und Verlauf (lokal)

def courses(conn, file_id: str | None) -> dict:
    """Stud.IP-Kurse (32-stellige Kennung, aktiv), Kurse des Moduls der Datei oben; Vorauswahl: Kurs der Datei, sonst die
    Uebung des Moduls, sonst der einzige Kurs des Moduls."""
    f = db.row(conn, "SELECT id, course_id, name, title FROM files WHERE id=?", (file_id,)) if file_id else None
    module_id = None
    if f:
        c = db.row(conn, "SELECT module_id FROM courses WHERE id=?", (f["course_id"],))
        module_id = c["module_id"] if c else None
    rows = db.rows(conn, """SELECT c.id, c.title, c.kind, c.semester, c.module_id, m.name AS module_name FROM courses c
                            LEFT JOIN modules m ON m.id = c.module_id WHERE COALESCE(c.active, 1) = 1""")
    out = [{"id": r["id"], "title": r["title"], "kind": r["kind"], "semester": r["semester"], "module_id": r["module_id"],
            "module_name": r["module_name"], "in_module": module_id is not None and r["module_id"] == module_id}
           for r in rows if STUDIP_ID_RE.match(str(r["id"] or ""))]
    out.sort(key=lambda c: (not c["in_module"], (c["module_name"] or "~").casefold(), (c["title"] or "").casefold()))
    suggested = None
    if f and any(c["id"] == f["course_id"] for c in out):
        suggested = f["course_id"]
    else:
        mine = [c for c in out if c["in_module"]]
        ue = [c for c in mine if c["kind"] == "uebung"]
        suggested = ue[0]["id"] if ue else (mine[0]["id"] if len(mine) == 1 else None)
    title = (f["title"] or f["name"]) if f else ""
    return {"courses": out, "suggested_course": suggested, "title": title}


def history(conn, document_id: str | None = None) -> list[dict]:
    r = conn.execute("SELECT value FROM settings WHERE key=?", (LOG_KEY,)).fetchone()
    try:
        v = json.loads(r[0]) if r and r[0] else []
    except ValueError:
        v = []
    items = [x for x in v if isinstance(x, dict)] if isinstance(v, list) else []
    return [x for x in items if document_id is None or x.get("document_id") == document_id]


def add_history(conn, record: dict) -> None:
    items = history(conn)
    items.insert(0, record)
    conn.execute("INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)",
                 (LOG_KEY, json.dumps(items[:LOG_LIMIT], ensure_ascii=False)))


def submitted_line(r: dict) -> str:
    from . import studip_reply
    d = studip_reply.instant(r.get("at"))
    when = d.astimezone(studip_reply.BERLIN).strftime("%d.%m.%Y, %H:%M") if d else ""
    return f"Abgegeben am {when} in {r.get('course_title') or 'Stud.IP'} › {r.get('folder_label') or 'Hauptordner'}"


# ---------------------------------------------------------------------------- Live (Stud.IP)

def fetch_folders(course_id: str) -> dict:
    data = studip_live.list_all(f"jsonapi.php/v1/courses/{course_id}/folders?page[limit]=200")
    return folders(data, course_id)


def upload(data: bytes, file_name: str, folder: dict) -> dict:
    """Hochladen (`POST folders/{id}/file-refs`, multipart, Feld `file`), genau ein Versuch; danach die Lizenz als
    bester Versuch."""
    boundary = "StudiNow-" + uuid.uuid4().hex
    r = studip_live.call("POST", f"jsonapi.php/v1/folders/{folder['id']}/file-refs",
                         body=multipart_body(boundary, file_name, "application/pdf", data),
                         headers={"Content-Type": f"multipart/form-data; boundary={boundary}", "Accept": studip_live.JSONAPI,
                                  "X-Requested-With": "XMLHttpRequest"})
    e = upload_error(r.status, r.body)
    if e:
        raise e
    ref = file_ref_id(r.location, r.body)
    licensed = False
    if ref:
        try:
            licensed = set_license(ref)
        except Exception:  # noqa: BLE001 - die Abgabe bleibt bestehen
            licensed = False
    return {"file_ref_id": ref, "license_set": licensed, "url": folder_web_url(studip_live.base(), folder["course_id"], folder["id"])}


def set_license(ref: str) -> bool:
    items = studip_live.list_all("jsonapi.php/v1/terms-of-use", max_pages=2)
    lic = own_work_license_id(items)
    if not lic:
        return False
    body = json.dumps({"data": {"type": "terms-of-use", "id": lic}}).encode()
    r = studip_live.call("PATCH", f"jsonapi.php/v1/file-refs/{ref}/relationships/terms-of-use", body=body,
                         headers={"Content-Type": studip_live.JSONAPI, "Accept": studip_live.JSONAPI, "X-Requested-With": "XMLHttpRequest"})
    return r.ok


# ---------------------------------------------------------------------------- Routen

def _check_local():
    if not studip_live.available():
        raise HTTPException(404, {"detail": "Abgeben gibt es nur in der Windows-App mit Stud.IP.", "code": "not_available"})


def _fail(e: Exception, web: str | None = None):
    if isinstance(e, studip_live.NotAvailable):
        _check_local()
    if isinstance(e, studip_live.NotConnected):
        raise HTTPException(409, {"detail": ERRORS["not_connected"], "code": "studip_not_connected"})
    if isinstance(e, studip_live.SessionExpired):
        raise HTTPException(409, {"detail": ERRORS["login"], "code": "studip_login"})
    if isinstance(e, UploadError):
        status = 413 if e.code == "too_large" else 502 if e.code == "http" else 409
        raise HTTPException(status, {"detail": e.message, "code": f"submit_{e.code}", "web_url": web})
    if isinstance(e, studip_live.StudIPHTTPError):
        if e.status == 403:
            raise HTTPException(409, {"detail": "Stud.IP zeigt dir die Ordner dieses Kurses nicht.", "code": "submit_forbidden"})
        raise HTTPException(502, {"detail": ERRORS["http"].format(status=e.status), "code": "submit_http", "web_url": web})
    if isinstance(e, (urllib.error.URLError, OSError, TimeoutError)):
        raise HTTPException(503, {"detail": ERRORS["offline"], "code": "submit_offline", "web_url": web})
    raise e


@router.get("")
def api_submit_info(file_id: str = Query(default="", max_length=200)):
    _check_local()
    with db.cursor() as conn:
        c = courses(conn, file_id or None)
        hist = [{**r, "line": submitted_line(r)} for r in history(conn, file_id or None)] if file_id else []
    return {**c, "connected": studip_live.connected(), "history": hist, "warning": WARNING,
            "typical_limit": TYPICAL_LIMIT, "max_upload": MAX_UPLOAD}


@router.get("/folders")
def api_submit_folders(course_id: str = Query(..., max_length=64), title: str = Query(default="", max_length=300)):
    _check_local()
    if not STUDIP_ID_RE.match(course_id):
        raise HTTPException(400, {"detail": "Kein Stud.IP-Kurs.", "code": "bad_course"})
    try:
        f = fetch_folders(course_id)
        try:
            me = studip_live.current_user()
            family = str((me.get("attributes") or {}).get("family-name") or "")
        except (studip_live.SessionExpired, studip_live.NotConnected):
            raise
        except Exception:  # noqa: BLE001 - ohne Namen nur der Teil danach
            family = ""
    except Exception as e:  # noqa: BLE001
        _fail(e)
    base = studip_live.base()
    for x in f["writable"] + f["closed"]:
        x["web_url"] = folder_web_url(base, course_id, x["id"])
    return {**f, "family_name": family, "file_name": proposed_file_name(family, title),
            "course_url": f"{base}/dispatch.php/course/files?cid={course_id}"}


@router.post("")
async def api_submit(file: UploadFile = File(...), course_id: str = Form(...), folder_id: str = Form(...),
                     file_name: str = Form(...), document_id: str = Form(default=""), with_notes: str = Form(default="1"),
                     pages: int = Form(default=0)):
    _check_local()
    if not STUDIP_ID_RE.match(course_id) or not re.match(r"^[0-9A-Za-z_-]{1,64}$", folder_id):
        raise HTTPException(400, {"detail": "Kurs oder Ordner fehlt.", "code": "bad_target"})
    name = final_file_name(file_name)
    if not name:
        raise HTTPException(400, {"detail": "Bitte einen Dateinamen eingeben.", "code": "bad_name"})
    data = await file.read(MAX_UPLOAD + 1)
    if len(data) > MAX_UPLOAD:
        raise HTTPException(413, {"detail": ERRORS["too_large"], "code": "submit_too_large"})
    if not data.startswith(b"%PDF"):
        raise HTTPException(400, {"detail": "Das ist keine PDF.", "code": "bad_pdf"})
    base = studip_live.base()
    web = folder_web_url(base, course_id, folder_id)
    from starlette.concurrency import run_in_threadpool

    def work():
        f = fetch_folders(course_id)                         # nur in einen beschreibbaren Ordner (frisch aus Stud.IP)
        folder = next((x for x in f["writable"] if x["id"] == folder_id), None)
        if folder is None:
            raise UploadError("not_writable", 403)
        return folder, upload(data, name, folder)

    try:
        folder, res = await run_in_threadpool(work)
    except Exception as e:  # noqa: BLE001
        _fail(e, web)
    from . import studip_reply
    with db.cursor() as conn:
        c = db.row(conn, "SELECT title FROM courses WHERE id=?", (course_id,))
        record = {"document_id": document_id[:200], "at": studip_reply.now_iso(), "course_id": course_id,
                  "course_title": (c["title"] if c else "") or "Stud.IP", "folder_id": folder_id, "folder_label": folder["label"],
                  "file_name": name, "url": res["url"], "with_notes": with_notes not in ("0", "false", ""),
                  "pages": max(0, int(pages or 0)), "size": len(data), "license_set": res["license_set"],
                  "file_ref_id": res["file_ref_id"]}
        add_history(conn, record)
    return {"submitted": True, "record": {**record, "line": submitted_line(record)}, "url": res["url"],
            "license_set": res["license_set"]}

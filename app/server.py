"""FastAPI-Backend der Lern-App."""
from __future__ import annotations

import json
import mimetypes
import re
import threading
import uuid
from datetime import date, timedelta
from pathlib import Path

from datetime import datetime

from fastapi import Body, FastAPI, File, Form, HTTPException, Query, UploadFile
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.responses import HTMLResponse, JSONResponse

from . import account_api, accounts, config, db, planner, study, timetable, universities
from .config import DATA_DIR, STATIC_DIR
from .studip_sync import run_sync

app = FastAPI(title="Stud.IP Lern-App")
app.include_router(account_api.router)
db.init_db()


@app.exception_handler(HTTPException)
async def _http_error(request, exc: HTTPException):
    """Fehler mit stabilem Code: HTTPException(status, {"detail": ..., "code": ...}) -> flache Antwort
    {"detail": "...", "code": "..."} (Vertrag G1); alle anderen wie bei FastAPI ueblich."""
    d = exc.detail
    body = {"detail": d.get("detail"), "code": d.get("code")} if isinstance(d, dict) and "detail" in d else {"detail": d}
    return JSONResponse(body, status_code=exc.status_code, headers=getattr(exc, "headers", None))

# Gehosteter Modus (LERNAPP_MODE=hosted): diese Pfade gibt es dort noch nicht. Sie antworten 501 mit Grund (Regel G6),
# statt im Dienst mit den Zugangsdaten der .env oder der KI-Kommandozeile des PCs zu arbeiten.
HOSTED_UNAVAILABLE = (
    ("POST", "/api/sync", "Der Hochschul-Abgleich im Dienst kommt mit dem naechsten Schritt (Zugangsdaten je Konto)."),
    ("GET", "/api/credentials", "Hochschul-Zugangsdaten je Konto kommen mit dem naechsten Schritt."),
    ("PUT", "/api/credentials", "Hochschul-Zugangsdaten je Konto kommen mit dem naechsten Schritt."),
    ("GET", "/api/network", "Gibt es nur auf dem eigenen PC (WLAN-Zugang)."),
    ("POST", "/api/ai/tutor", "KI-Funktionen kommen mit dem KI-Update."),
    ("POST", "/api/files/{id}/analyze", "KI-Funktionen kommen mit dem KI-Update."),
    ("POST", "/api/tests/generate", "KI-Funktionen kommen mit dem KI-Update."),
    ("POST", "/api/tests/generate-week", "KI-Funktionen kommen mit dem KI-Update."),
    ("POST", "/api/tests/{id}/submit", "KI-Funktionen kommen mit dem KI-Update."),
    ("POST", "/api/plan/generate", "KI-Funktionen kommen mit dem KI-Update."),
)
_HOSTED_UNAVAILABLE_RE = [(m, re.compile("^" + "[^/]+".join(re.escape(part) for part in p.split("{id}")) + "$"), why)
                          for m, p, why in HOSTED_UNAVAILABLE]
_user_dbs_ready: set = set()


def hosted_unavailable(method: str, path: str) -> str | None:
    for m, rx, why in _HOSTED_UNAVAILABLE_RE:
        if m == method and rx.match(path):
            return why
    return None


@app.middleware("http")
async def hosted_guard(request, call_next):
    """Gehosteter Modus: jede /api-Anfrage braucht eine Sitzung (Bearer-Token oder Cookie), ausser den oeffentlichen
    Kontopfaden. Der angemeldete Nutzer bestimmt den Datenordner der Anfrage (config.set_user_context)."""
    if not config.is_hosted():
        return await call_next(request)
    path = request.url.path
    if not path.startswith("/api/") or path in account_api.PUBLIC_PATHS:
        return await call_next(request)
    why = hosted_unavailable(request.method, path)
    if why:
        return JSONResponse({"detail": why, "code": "not_available_hosted"}, status_code=501)
    user = accounts.authenticate(account_api.token_of(request))
    if not user:
        return JSONResponse({"detail": "Anmeldung erforderlich.", "code": "unauthenticated"}, status_code=401)
    request.state.user = user
    ctx = config.set_user_context(user["id"], user["university"])
    try:
        key = (user["id"], user["university"])
        if key not in _user_dbs_ready:
            db.init_db()
            _user_dbs_ready.add(key)
        return await call_next(request)
    finally:
        config.reset_user_context(ctx)


LOOPBACK = {"127.0.0.1", "::1", "localhost", "testclient"}
_PIN_FAILS: dict[str, list] = {}
PIN_PAGE = """<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>UniFlow AI – PIN</title>
<style>body{font:16px/1.5 Inter,system-ui,sans-serif;background:#f6f7fb;color:#171a26;display:grid;place-items:center;min-height:100vh;margin:0}form{background:#fff;border:1px solid #e5e8f0;border-radius:16px;padding:1.6rem;width:min(360px,92vw);box-shadow:0 4px 16px rgba(20,24,40,.06)}h1{font-size:1.2rem;margin:0 0 .3rem}p{color:#7a8199;margin:0 0 1rem;font-size:.9rem}input{width:100%;font-size:1.4rem;letter-spacing:.3em;text-align:center;padding:.6rem;border:1px solid #d3d8e4;border-radius:10px;box-sizing:border-box}button{margin-top:.8rem;width:100%;padding:.7rem;border:0;border-radius:10px;background:#4f5bd5;color:#fff;font-weight:600;font-size:1rem}</style></head>
<body><form method="get" action="/"><h1>UniFlow AI</h1><p>Dieses Gerät ist nicht der PC, auf dem die App läuft. Bitte die PIN aus „Einstellungen → Zugang“ eingeben.</p><input name="pin" inputmode="numeric" autocomplete="one-time-code" placeholder="••••••" autofocus><button type="submit">Öffnen</button></form></body></html>"""


def _lan_pin() -> str:
    with db.cursor() as conn:
        pin = (db.get_settings(conn).get("lan_pin") or "").strip()
        if not pin:
            import secrets
            pin = "".join(secrets.choice("0123456789") for _ in range(6))
            db.set_setting(conn, "lan_pin", pin)
    return pin


def _nets(*cidrs):
    import ipaddress
    return tuple(ipaddress.ip_network(c) for c in cidrs)


# Ausdrueckliche Liste (ipaddress.is_private zaehlt auch Dokumentations- und Sonderbereiche mit)
_PRIVATE_NETS = _nets("127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "100.64.0.0/10",
                      "::1/128", "fc00::/7", "fe80::/10")


def _client_allowed(host: str) -> bool:
    """Nur Geraete aus privaten Netzen: Heimnetz (RFC 1918), IPv6-ULA, Link-Local, Tailscale/CGNAT (100.64/10).
    Oeffentliche Adressen werden abgelehnt, auch wenn der Router den Port weiterleitet.
    Ausnahme nur bewusst: LERNAPP_ALLOW_PUBLIC_CLIENTS=1."""
    import ipaddress
    import os
    if host in LOOPBACK or os.environ.get("LERNAPP_ALLOW_PUBLIC_CLIENTS") == "1":
        return True
    try:
        ip = ipaddress.ip_address(host.split("%", 1)[0])
    except ValueError:
        return False
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    return any(ip in net for net in _PRIVATE_NETS if net.version == ip.version)


@app.middleware("http")
async def lan_pin_guard(request, call_next):
    """Zugriff von anderen Geraeten (iPad im WLAN) nur mit PIN; vom PC selbst immer frei. Im gehosteten Modus gilt
    statt der PIN die Sitzung des Kontos (hosted_guard)."""
    host = request.client.host if request.client else "127.0.0.1"
    if host in LOOPBACK or config.is_hosted():
        return await call_next(request)
    if not _client_allowed(host):
        return JSONResponse({"detail": "Zugriff nur aus dem eigenen Netz"}, status_code=403)
    pin = _lan_pin()
    given = request.query_params.get("pin") or request.cookies.get("lernapp_pin")
    import time as _time
    fails = _PIN_FAILS.setdefault(host, [0, 0.0])
    if fails[0] >= 8 and _time.time() - fails[1] < 600:
        return JSONResponse({"detail": "Zu viele falsche PIN-Eingaben. Bitte 10 Minuten warten."}, status_code=429)
    if given and given != pin:
        fails[0] = fails[0] + 1 if _time.time() - fails[1] < 600 else 1; fails[1] = _time.time()
    if given == pin:
        _PIN_FAILS.pop(host, None)
        response = await call_next(request)
        if request.query_params.get("pin"):
            response.set_cookie("lernapp_pin", pin, max_age=60 * 60 * 24 * 365, samesite="lax", httponly=True)
        return response
    if request.url.path.startswith("/api/"):
        return JSONResponse({"detail": "PIN erforderlich (Einstellungen > Zugang auf dem PC)"}, status_code=401)
    return HTMLResponse(PIN_PAGE, status_code=401)


@app.middleware("http")
async def no_cache_static(request, call_next):
    """Oberflaechendateien (JS/CSS/HTML) nie zwischenspeichern, damit nach Updates nichts Altes haengen bleibt."""
    response = await call_next(request)
    p = request.url.path
    if not p.startswith("/api/") and (p == "/" or p.endswith((".js", ".mjs", ".css", ".html"))):
        response.headers["Cache-Control"] = "no-cache, must-revalidate"
    return response


def _host_allowed(host_header: str) -> bool:
    """Schutz gegen DNS-Rebinding: nur IP-Adressen, localhost, der eigene Rechnername und lokale Namen."""
    import ipaddress
    import os
    import socket
    h = (host_header or "").strip().lower()
    if not h:
        return True
    if h.startswith("["):                                   # [::1]:8765
        h = h[1:].split("]", 1)[0]
    elif h.count(":") == 1:
        h = h.rsplit(":", 1)[0]
    try:
        ipaddress.ip_address(h)
        return True
    except ValueError:
        pass
    extra = {x.strip().lower() for x in os.environ.get("LERNAPP_ALLOWED_HOSTS", "").split(",") if x.strip()}
    me = socket.gethostname().lower()
    if h in extra or h in ("localhost", me) or h.endswith(".localhost"):
        return True
    return any(h == f"{me}{suffix}" for suffix in (".fritz.box", ".local", ".lan", ".home", ".home.arpa", ".internal", ".speedport.ip"))


@app.middleware("http")
async def same_origin_guard(request, call_next):
    """Schutz gegen fremde Webseiten: falscher Host (Rebinding) -> 421, fremde Herkunft bei Aenderungen -> 403.
    Anfragen ohne Origin (native App, Skripte) bleiben erlaubt; im WLAN gilt zusaetzlich die PIN."""
    host = request.headers.get("host", "")
    if not _host_allowed(host):
        return JSONResponse({"detail": "Unbekannter Hostname"}, status_code=421)
    if request.method not in ("GET", "HEAD", "OPTIONS"):
        origin = request.headers.get("origin")
        if origin is not None:
            from urllib.parse import urlsplit
            o = urlsplit(origin)
            if origin == "null" or o.netloc.lower() != host.lower():
                return JSONResponse({"detail": "Anfrage von fremder Seite abgelehnt"}, status_code=403)
    return await call_next(request)


_FILE_PATHS = re.compile(r"^/api/(files/[^/]+/content|assets/|qis/documents/)")
_INLINE_TYPES = ("application/pdf", "image/png", "image/jpeg", "image/gif", "image/webp", "text/plain")


@app.middleware("http")
async def file_response_headers(request, call_next):
    """Dateien aus Stud.IP, eigene Uploads und QIS-Dokumente: Browser darf den Typ nicht raten, und alles ausser PDF
    laeuft ohne Skripte (Sandbox). Sonst koennte z. B. eine HTML- oder SVG-Datei aus einem Stud.IP-Gruppenordner
    mit den Rechten der App auf die API zugreifen."""
    response = await call_next(request)
    if _FILE_PATHS.match(request.url.path):
        response.headers["X-Content-Type-Options"] = "nosniff"
        ctype = (response.headers.get("content-type") or "").split(";")[0].strip().lower()
        if ctype != "application/pdf":
            response.headers["Content-Security-Policy"] = "sandbox; default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline'"
    return response


_SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$")
_SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,99}\.[A-Za-z0-9]{1,6}$")


def _changed(cur, what: str = "Eintrag") -> None:
    """Regel G6 (docs/AUFGABENTEILUNG-APPLE-PC.md): eine Aenderung oder Loeschung nach ID, die keinen Datensatz
    getroffen hat, meldet 404 statt Erfolg. Der Nutzer darf nie glauben, etwas sei gespeichert oder geloescht."""
    if cur.rowcount == 0:
        raise HTTPException(404, f"{what} nicht gefunden")


def _found(row, what: str = "Eintrag"):
    """Gleiche Regel fuer Antworten nach ID: kein Datensatz -> 404, nie `null` mit 200."""
    if row is None:
        raise HTTPException(404, f"{what} nicht gefunden")
    return row


def _safe_id(value: str) -> str:
    """Datei-IDs werden fuer Pfade benutzt: keine Punkte, Schraegstriche oder Backslashes (Pfad-Traversal)."""
    if not _SAFE_ID.match(value or ""):
        raise HTTPException(400, "Ungueltige ID")
    return value


def _inside(base: Path, p: Path) -> Path:
    rb, rp = base.resolve(), p.resolve()
    if rp != rb and rb not in rp.parents:
        raise HTTPException(400, "Ungueltiger Pfad")
    return rp


# Windows kennt .mjs nicht -> Module-Skripte brauchen den richtigen MIME-Typ
mimetypes.add_type("text/javascript", ".mjs")
mimetypes.add_type("application/manifest+json", ".webmanifest")
mimetypes.add_type("text/javascript", ".js")

_bg_lock = threading.Lock()
_bg_state: dict = {"running": False, "task": None, "message": ""}


def _run_bg(name: str, fn):
    if not _bg_lock.acquire(blocking=False):
        raise HTTPException(409, f"Es laeuft bereits: {_bg_state['task']}")
    _bg_state.update(running=True, task=name, message="")

    def worker():
        try:
            out = fn()
            _bg_state["message"] = f"{name}: fertig" + (f" ({out})" if out else "")
        except Exception as e:  # noqa: BLE001
            _bg_state["message"] = f"{name}: FEHLER {e}"
        finally:
            _bg_state.update(running=False, task=None)
            _bg_lock.release()

    threading.Thread(target=worker, daemon=True).start()
    return {"started": name}


def _full_sync():
    res = run_sync()
    n = planner.analyze_pending()
    with db.cursor() as conn:
        s = db.get_settings(conn)
        plan_exists = db.row(conn, "SELECT 1 FROM plans WHERE week_start=?", (planner.planning_week().isoformat(),))
    if s["auto_plan"] and (res["new_files"] or not plan_exists):
        planner.generate_plan()
    if s["auto_tests"]:
        planner.create_weekly_tests()
    return f"{len(res['new_files'])} neue Dateien, {n} analysiert"


# ----------------------------------------------------------------------------
# Uebersicht / Sync
# ----------------------------------------------------------------------------

@app.get("/api/overview")
def overview():
    with db.cursor() as conn:
        new_files = db.rows(conn, """
            SELECT f.id, f.name, f.first_seen, f.chdate, f.status, c.title AS course_title, c.subject,
                   a.doc_type, a.difficulty, a.est_minutes, a.title AS ai_title
            FROM files f JOIN courses c ON c.id=f.course_id LEFT JOIN analysis a ON a.file_id=f.id
            WHERE f.seen_by_user=0 AND c.active=1 ORDER BY f.first_seen DESC, f.chdate DESC LIMIT 100""")
        recent = db.rows(conn, """
            SELECT f.id, f.name, f.first_seen, f.chdate, f.status, c.title AS course_title, c.subject,
                   a.doc_type, a.difficulty, a.est_minutes, a.title AS ai_title
            FROM files f JOIN courses c ON c.id=f.course_id LEFT JOIN analysis a ON a.file_id=f.id
            WHERE c.active=1 ORDER BY f.chdate DESC LIMIT 30""")
        last_sync = db.row(conn, "SELECT * FROM sync_log ORDER BY id DESC LIMIT 1")
        counts = db.row(conn, """SELECT (SELECT COUNT(*) FROM files) AS files,
                                        (SELECT COUNT(*) FROM courses WHERE active=1) AS courses,
                                        (SELECT COUNT(*) FROM analysis) AS analyzed,
                                        (SELECT COUNT(*) FROM files WHERE status!='erledigt') AS open""")
        today = date.today()
        ws = planner.monday(today).isoformat()
        today_items = db.rows(conn, "SELECT * FROM plan_items WHERE week_start=? AND day=? ORDER BY start_time",
                              (ws, today.weekday()))
    return {"new_files": new_files, "recent": recent, "last_sync": last_sync, "counts": counts,
            "today": today_items, "bg": _bg_state}


@app.post("/api/sync")
def sync_now(ai: bool = True):
    return _run_bg("Sync", _full_sync if ai else lambda: run_sync()["message"])


@app.get("/api/sync/changes")
def api_sync_changes(since: str | None = None, device_id: str | None = None):
    """Vertrag G2: alle Aenderungen nach dem Cursor `since` (aus der letzten Antwort), plus Tombstones."""
    from . import sync
    with db.cursor() as conn:
        return sync.changes(conn, since)


@app.post("/api/sync/push")
def api_sync_push(body: dict = Body(...)):
    """Vertrag G2: Aenderungen eines Geraets uebernehmen; Antwort mit Ergebnis je Eintrag, ID-Zuordnung, Konflikten."""
    from . import sync
    items, deletes = body.get("items") or [], body.get("deletes") or []
    if not isinstance(items, list) or not isinstance(deletes, list):
        raise HTTPException(400, "items und deletes muessen Listen sein")
    with db.cursor() as conn:
        conn.execute("BEGIN IMMEDIATE")
        return sync.push(conn, body.get("device_id"), items, deletes)


@app.get("/api/sync/status")
def sync_status():
    with db.cursor() as conn:
        logs = db.rows(conn, "SELECT * FROM sync_log ORDER BY id DESC LIMIT 20")
    return {"bg": _bg_state, "log": logs}


@app.post("/api/files/mark-seen")
def mark_seen():
    with db.cursor() as conn:
        conn.execute("UPDATE files SET seen_by_user=1")
    return {"ok": True}


# ----------------------------------------------------------------------------
# Kurse & Dateien
# ----------------------------------------------------------------------------

@app.get("/api/courses")
def courses():
    with db.cursor() as conn:
        return db.rows(conn, """
            SELECT c.*, (SELECT COUNT(*) FROM files f WHERE f.course_id=c.id) AS file_count,
                   (SELECT COUNT(*) FROM files f WHERE f.course_id=c.id AND f.status='neu') AS new_count
            FROM courses c ORDER BY c.subject, c.kind, c.title""")


@app.patch("/api/courses/{course_id}")
def patch_course(course_id: str, body: dict = Body(...)):
    allowed = {"subject", "kind", "active", "test_minutes"}
    with db.cursor() as conn:
        for k, v in body.items():
            if k in allowed:
                conn.execute(f"UPDATE courses SET {k}=? WHERE id=?", (v, course_id))
        return _found(db.row(conn, "SELECT * FROM courses WHERE id=?", (course_id,)), "Kurs")


@app.get("/api/files")
def files(course_id: str | None = None, subject: str | None = None):
    sql = """SELECT f.*, c.title AS course_title, c.subject, c.kind AS course_kind,
                    a.doc_type, a.title AS ai_title, a.topics, a.difficulty, a.est_minutes, a.summary,
                    (SELECT 1 FROM annotations an WHERE an.file_id=f.id) AS has_notes
             FROM files f JOIN courses c ON c.id=f.course_id LEFT JOIN analysis a ON a.file_id=f.id WHERE 1=1"""
    params: list = []
    if course_id:
        sql += " AND f.course_id=?"
        params.append(course_id)
    if subject:
        sql += " AND c.subject=?"
        params.append(subject)
    sql += " ORDER BY f.chdate DESC"
    with db.cursor() as conn:
        return db.rows(conn, sql, params)


@app.get("/api/files/{file_id}")
def file_meta(file_id: str):
    with db.cursor() as conn:
        f = db.row(conn, """SELECT f.*, c.title AS course_title, c.subject, c.module_id, a.doc_type, a.title AS ai_title, a.topics,
                                   a.difficulty, a.est_minutes, a.summary, a.prerequisites
                            FROM files f JOIN courses c ON c.id=f.course_id LEFT JOIN analysis a ON a.file_id=f.id
                            WHERE f.id=?""", (file_id,))
        if not f:
            raise HTTPException(404)
        f["exists"] = bool(f["local_path"] and Path(f["local_path"]).exists())
        return f


@app.get("/api/files/{file_id}/content")
def file_content(file_id: str):
    with db.cursor() as conn:
        f = db.row(conn, "SELECT local_path, name, mime FROM files WHERE id=?", (file_id,))
    if not f or not f["local_path"] or not Path(f["local_path"]).exists():
        raise HTTPException(404, "Datei nicht lokal vorhanden")
    mt = (f["mime"] or mimetypes.guess_type(f["name"])[0] or "application/octet-stream").split(";")[0].strip().lower()
    if mt in _INLINE_TYPES:
        return FileResponse(f["local_path"], media_type=mt, filename=f["name"], content_disposition_type="inline")
    # HTML, SVG, Skripte usw. nie im Kontext der App anzeigen, sondern herunterladen
    return FileResponse(f["local_path"], media_type="application/octet-stream", filename=f["name"],
                        content_disposition_type="attachment")


@app.patch("/api/files/{file_id}")
def patch_file(file_id: str, body: dict = Body(...)):
    with db.cursor() as conn:
        if "status" in body and body["status"] in ("neu", "gelesen", "erledigt"):
            conn.execute("UPDATE files SET status=?, seen_by_user=1 WHERE id=?", (body["status"], file_id))
        if "difficulty" in body:
            conn.execute("UPDATE analysis SET difficulty=? WHERE file_id=?", (int(body["difficulty"]), file_id))
        return _found(db.row(conn, "SELECT * FROM files WHERE id=?", (file_id,)), "Datei")


@app.post("/api/files/{file_id}/analyze")
def analyze_one(file_id: str):
    def job():
        with db.cursor() as conn:
            conn.execute("DELETE FROM analysis WHERE file_id=?", (file_id,))
            f = db.row(conn, "SELECT id FROM files WHERE id=?", (file_id,))
        if not f:
            raise RuntimeError("Datei nicht gefunden")
        return planner.analyze_pending(limit=200)
    return _run_bg("Analyse", job)


@app.get("/api/files/{file_id}/annotations")
def get_annotations(file_id: str):
    with db.cursor() as conn:
        _found(db.row(conn, "SELECT 1 FROM files WHERE id=?", (file_id,)), "Datei")     # G6: unbekannte Datei -> 404
        r = db.row(conn, "SELECT data, updated_at, version FROM annotations WHERE file_id=?", (file_id,))
    if not r:
        return {"data": {"version": 2, "pages": {}, "zoom": 1.2}, "updated_at": None, "version": 0}
    return {"data": json.loads(r["data"]), "updated_at": r["updated_at"], "version": r["version"] or 1}


@app.put("/api/files/{file_id}/annotations")
def put_annotations(file_id: str, body: dict = Body(...), base_version: int | None = None):
    """Speichert Annotationen. Mit base_version wird ein Konflikt (409) gemeldet, wenn der Server neuer ist."""
    with db.cursor() as conn:
        conn.execute("BEGIN IMMEDIATE")      # Versionspruefung und Schreiben atomar: zwei Geraete koennen nicht beide gewinnen
        cur = db.row(conn, "SELECT version, data FROM annotations WHERE file_id=?", (file_id,))
        cur_v = (cur["version"] or 1) if cur else 0
        if base_version is not None and cur and cur_v != base_version:
            return JSONResponse(status_code=409, content={"detail": "Konflikt: Server hat eine neuere Version",
                                                          "version": cur_v, "data": json.loads(cur["data"])})
        new_v = cur_v + 1
        payload = json.dumps(body, ensure_ascii=False)
        conn.execute("INSERT INTO annotations(file_id, data, updated_at, version) VALUES (?,?,?,?) "
                     "ON CONFLICT(file_id) DO UPDATE SET data=excluded.data, updated_at=excluded.updated_at, version=excluded.version",
                     (file_id, payload, db.now_iso(), new_v))
        conn.execute("INSERT INTO annotation_versions(file_id, version, data, created_at) VALUES (?,?,?,?)",
                     (file_id, new_v, payload, db.now_iso()))
        conn.execute("""DELETE FROM annotation_versions WHERE file_id=? AND id NOT IN (
                            SELECT id FROM annotation_versions WHERE file_id=? ORDER BY version DESC LIMIT 30)""",
                     (file_id, file_id))
    return {"ok": True, "version": new_v}


@app.get("/api/files/{file_id}/annotations/versions")
def annotation_versions(file_id: str):
    with db.cursor() as conn:
        return db.rows(conn, "SELECT version, created_at, length(data) AS size FROM annotation_versions WHERE file_id=? ORDER BY version DESC", (file_id,))


@app.post("/api/files/{file_id}/annotations/restore/{version}")
def restore_version(file_id: str, version: int):
    with db.cursor() as conn:
        r = db.row(conn, "SELECT data FROM annotation_versions WHERE file_id=? AND version=?", (file_id, version))
        if not r:
            raise HTTPException(404, "Version nicht gefunden")
    return put_annotations(file_id, json.loads(r["data"]))


ASSETS_DIR = DATA_DIR / "assets"


def _assets_dir() -> Path:
    return config.data_dir() / "assets" if config.current_user_id() else ASSETS_DIR


@app.post("/api/files/{file_id}/assets")
async def upload_asset(file_id: str, upload: UploadFile = File(...)):
    """Bild (oder Screenshot) fuer den Editor ablegen. Antwort: URL zum Einbetten."""
    _safe_id(file_id)
    ext = Path(upload.filename or "bild.png").suffix.lower() or ".png"
    if ext not in (".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".pdf"):
        raise HTTPException(400, "Nur Bild- oder PDF-Dateien")
    name = f"{uuid.uuid4().hex}{ext}"
    target = _inside(_assets_dir(), _assets_dir() / file_id)
    target.mkdir(parents=True, exist_ok=True)
    data = await upload.read()
    if len(data) > 15 * 1024 * 1024:
        raise HTTPException(400, "Bild zu gross (max. 15 MB)")
    (target / name).write_bytes(data)
    return {"url": f"/api/assets/{file_id}/{name}", "name": name}


@app.get("/api/assets/{file_id}/{name}")
def get_asset(file_id: str, name: str):
    _safe_id(file_id)
    if not _SAFE_NAME.match(name or ""):
        raise HTTPException(400, "Ungueltiger Dateiname")
    p = _inside(_assets_dir(), _assets_dir() / file_id / name)
    if not p.is_file():
        raise HTTPException(404)
    return FileResponse(p)


@app.get("/api/files/{file_id}/pagetext")
def page_text(file_id: str, page: int = 1):
    with db.cursor() as conn:
        f = db.row(conn, "SELECT local_path FROM files WHERE id=?", (file_id,))
    if not f or not f["local_path"] or not Path(f["local_path"]).exists():
        raise HTTPException(404)
    try:
        from pypdf import PdfReader
        reader = PdfReader(f["local_path"])
        if page < 1 or page > len(reader.pages):
            return {"text": "", "pages": len(reader.pages)}
        return {"text": reader.pages[page - 1].extract_text() or "", "pages": len(reader.pages)}
    except Exception as e:  # noqa: BLE001
        return {"text": "", "error": str(e)}


# ----------------------------------------------------------------------------
# KI-Tutor im Editor und Karteikarten
# ----------------------------------------------------------------------------

@app.post("/api/ai/tutor")
def ai_tutor(body: dict = Body(...)):
    from . import ai
    file_id = body.get("file_id")
    page = int(body.get("page") or 1)
    text = body.get("page_text") or ""
    course, fname = "", ""
    if file_id:
        with db.cursor() as conn:
            f = db.row(conn, "SELECT f.name, c.title AS course_title FROM files f JOIN courses c ON c.id=f.course_id WHERE f.id=?", (file_id,))
        if f:
            course, fname = f["course_title"], f["name"]
        if not text.strip():
            text = page_text(file_id, page).get("text", "")
    try:
        answer = ai.tutor(body.get("mode") or "explain", text, body.get("selection") or "", body.get("question") or "",
                          body.get("own_solution") or "", course, fname, page)
    except ai.AIError as e:
        raise HTTPException(500, str(e))
    cards = None
    if (body.get("mode") == "flashcards"):
        try:
            cards = ai.parse_json(answer)
        except ai.AIError:
            cards = None
    return {"answer": answer, "cards": cards}


@app.get("/api/flashcards")
def list_flashcards(file_id: str | None = None, due: bool = False):
    sql = "SELECT fc.*, f.name AS file_name FROM flashcards fc LEFT JOIN files f ON f.id=fc.file_id WHERE 1=1"
    params: list = []
    if file_id:
        sql += " AND fc.file_id=?"; params.append(file_id)
    if due:
        sql += " AND (fc.due IS NULL OR fc.due <= ?)"; params.append(date.today().isoformat())
    sql += " ORDER BY fc.id DESC"
    with db.cursor() as conn:
        return db.rows(conn, sql, params)


@app.post("/api/flashcards")
def add_flashcards(body: dict = Body(...)):
    cards = body.get("cards") or []
    file_id = body.get("file_id")
    with db.cursor() as conn:
        subj = None
        if file_id:
            r = db.row(conn, "SELECT c.subject FROM files f JOIN courses c ON c.id=f.course_id WHERE f.id=?", (file_id,))
            subj = r["subject"] if r else None
        for c in cards:
            if c.get("question") and c.get("answer"):
                conn.execute("INSERT INTO flashcards(file_id, subject, question, answer, created_at, box, due) VALUES (?,?,?,?,?,1,?)",
                             (file_id, subj, c["question"], c["answer"], db.now_iso(), date.today().isoformat()))
    return {"ok": True, "count": len(cards)}


@app.post("/api/flashcards/{card_id}/review")
def review_flashcard(card_id: int, body: dict = Body(...)):
    """Leitner: richtig -> naechstes Fach (1,2,4,8,16 Tage), falsch -> Fach 1."""
    ok = bool(body.get("correct"))
    with db.cursor() as conn:
        c = db.row(conn, "SELECT box FROM flashcards WHERE id=?", (card_id,))
        if not c:
            raise HTTPException(404)
        box = min(5, (c["box"] or 1) + 1) if ok else 1
        due = (date.today() + timedelta(days=[1, 2, 4, 8, 16][box - 1])).isoformat()
        conn.execute("UPDATE flashcards SET box=?, due=? WHERE id=?", (box, due, card_id))
    return {"box": box, "due": due}


@app.delete("/api/flashcards/{card_id}")
def delete_flashcard(card_id: int):
    with db.cursor() as conn:
        _changed(conn.execute("DELETE FROM flashcards WHERE id=?", (card_id,)), "Karteikarte")
    return {"ok": True}


# ----------------------------------------------------------------------------
# Wochenplan
# ----------------------------------------------------------------------------

@app.get("/api/plan")
def get_plan(week: str | None = None):
    ws = week or planner.planning_week().isoformat()
    with db.cursor() as conn:
        plan = db.row(conn, "SELECT * FROM plans WHERE week_start=?", (ws,))
        items = db.rows(conn, """SELECT p.*, f.name AS file_name, t.submitted_at AS test_submitted, t.score AS test_score
                                 FROM plan_items p LEFT JOIN files f ON f.id=p.file_id LEFT JOIN tests t ON t.id=p.test_id
                                 WHERE p.week_start=? ORDER BY p.day, p.start_time, p.sort_order""", (ws,))
        tests = db.rows(conn, "SELECT id, subject, title, duration_min, submitted_at, score, max_score FROM tests WHERE week_start=?", (ws,))
    prev = (date.fromisoformat(ws) - timedelta(days=7)).isoformat()
    nxt = (date.fromisoformat(ws) + timedelta(days=7)).isoformat()
    return {"week_start": ws, "prev": prev, "next": nxt, "plan": plan, "items": items, "tests": tests}


@app.post("/api/plan/generate")
def gen_plan(week: str | None = None, keep_manual: bool = True):
    ws = date.fromisoformat(week) if week else None
    return _run_bg("Wochenplan", lambda: planner.generate_plan(ws, keep_manual=keep_manual))


@app.post("/api/plan/items")
def add_item(body: dict = Body(...)):
    ws = body.get("week_start") or planner.planning_week().isoformat()
    with db.cursor() as conn:
        cur = conn.execute(
            """INSERT INTO plan_items(week_start, day, start_time, duration_min, subject, file_id, title, kind, manual, sort_order)
               VALUES (?,?,?,?,?,?,?,?,1,999)""",
            (ws, int(body.get("day", 0)), body.get("start_time") or "09:00", int(body.get("duration_min") or 60),
             body.get("subject"), body.get("file_id"), body.get("title") or "Lernen", body.get("kind") or "lernen"))
        return db.row(conn, "SELECT * FROM plan_items WHERE id=?", (cur.lastrowid,))


@app.patch("/api/plan/items/{item_id}")
def patch_item(item_id: int, body: dict = Body(...)):
    allowed = {"day", "start_time", "duration_min", "title", "kind", "done", "subject", "sort_order"}
    with db.cursor() as conn:
        for k, v in body.items():
            if k in allowed:
                conn.execute(f"UPDATE plan_items SET {k}=? WHERE id=?", (v, item_id))
        return db.row(conn, "SELECT * FROM plan_items WHERE id=?", (item_id,))


@app.delete("/api/plan/items/{item_id}")
def delete_item(item_id: int):
    with db.cursor() as conn:
        _changed(conn.execute("DELETE FROM plan_items WHERE id=?", (item_id,)), "Planeintrag")
    return {"ok": True}


# ----------------------------------------------------------------------------
# Tests
# ----------------------------------------------------------------------------

@app.get("/api/subjects")
def subjects():
    with db.cursor() as conn:
        return db.rows(conn, """SELECT subject, MAX(test_minutes) AS test_minutes, COUNT(*) AS courses,
                                       (SELECT COUNT(*) FROM files f JOIN courses c2 ON c2.id=f.course_id WHERE c2.subject=c.subject) AS files
                                FROM courses c WHERE active=1 AND kind!='sonstiges' GROUP BY subject ORDER BY subject""")


@app.get("/api/tests")
def tests():
    with db.cursor() as conn:
        rows = db.rows(conn, """SELECT id, subject, week_start, title, duration_min, created_at, started_at, submitted_at,
                                       score, max_score, module_id, week_no, auto, questions FROM tests ORDER BY created_at DESC""")
    for r in rows:
        try:
            r["question_count"] = len(json.loads(r.pop("questions") or "[]"))
        except Exception:  # noqa: BLE001
            r["question_count"] = None
            r.pop("questions", None)
    return rows


@app.post("/api/tests/generate")
def gen_test(body: dict = Body(...)):
    """Manueller Zusatztest fuer ein Modul (nicht an die Ein-Test-pro-Woche-Regel gebunden)."""
    dur = int(body["duration_min"]) if body.get("duration_min") else None
    if body.get("module_id"):
        with db.cursor() as conn:
            m = db.row(conn, "SELECT name FROM modules WHERE id=?", (int(body["module_id"]),))
        if not m:
            raise HTTPException(404, "Modul nicht gefunden")
        return _run_bg("Test", lambda: planner.create_test(m["name"], dur, module_id=int(body["module_id"]), auto=False))
    subject = body.get("subject")
    if not subject:
        raise HTTPException(400, "subject fehlt")
    return _run_bg("Test", lambda: planner.create_test(subject, dur, auto=False))


@app.post("/api/tests/generate-week")
def gen_week_tests():
    return _run_bg("Wochentests", lambda: len(planner.create_weekly_tests()))


@app.get("/api/tests/{test_id}")
def get_test(test_id: int):
    with db.cursor() as conn:
        t = db.row(conn, "SELECT * FROM tests WHERE id=?", (test_id,))
        if not t:
            raise HTTPException(404)
        if not t["started_at"]:
            conn.execute("UPDATE tests SET started_at=? WHERE id=?", (db.now_iso(), test_id))
            t["started_at"] = db.now_iso()
    t["questions"] = json.loads(t["questions"])
    if not t["submitted_at"]:
        for q in t["questions"]:
            q.pop("answer", None)   # Loesung erst nach Abgabe sichtbar
    t["answers"] = json.loads(t["answers"]) if t["answers"] else {}
    t["feedback"] = json.loads(t["feedback"]) if t["feedback"] else None
    return t


@app.post("/api/tests/{test_id}/submit")
def submit_test(test_id: int, body: dict = Body(...)):
    answers = {str(k): v for k, v in (body.get("answers") or {}).items()}
    try:
        return planner.grade(test_id, answers)
    except Exception as e:  # noqa: BLE001
        raise HTTPException(500, str(e))


@app.delete("/api/tests/{test_id}")
def delete_test(test_id: int):
    with db.cursor() as conn:
        t = _found(db.row(conn, "SELECT auto, module_id, week_no FROM tests WHERE id=?", (test_id,)), "Test")
        # sonst legt der Sync (create_weekly_tests) denselben Wochentest sofort wieder an
        if t["auto"] and t["module_id"] is not None and t["week_no"] is not None:
            conn.execute("INSERT OR IGNORE INTO dismissed_tests(module_id, week_no, dismissed_at) VALUES (?,?,?)",
                         (t["module_id"], t["week_no"], db.now_iso()))
        conn.execute("UPDATE plan_items SET test_id=NULL WHERE test_id=?", (test_id,))
        conn.execute("UPDATE study_tasks SET test_id=NULL WHERE test_id=?", (test_id,))   # Aufgabe bietet dann "Test starten" an
        conn.execute("DELETE FROM tests WHERE id=?", (test_id,))
    return {"ok": True}


# ----------------------------------------------------------------------------
# Einstellungen
# ----------------------------------------------------------------------------

def _public_settings(s: dict) -> dict:
    """Einstellungen ohne die PIN (die steht nur in /api/network fuer die Anzeige am PC)."""
    out = {k: v for k, v in s.items() if k != "lan_pin"}
    out["university"] = config.university()
    out["university_next"] = config.university() if config.is_hosted() else config.configured_university()
    out["files_source"] = universities.PROFILES.get(config.university(), {}).get("files_source", "Stud.IP")
    out["mode"] = config.MODE
    return out


@app.get("/api/settings")
def get_settings():
    with db.cursor() as conn:
        return _public_settings(db.get_settings(conn))


@app.put("/api/settings")
def put_settings(body: dict = Body(...)):
    from . import universities
    body = dict(body)
    if "university" in body:
        uni = body.pop("university")
        if not universities.valid(uni):
            raise HTTPException(400, "Unbekannte Hochschule")
        if config.is_hosted():
            raise HTTPException(400, {"detail": "Die Hochschule gehoert zum Konto: POST /api/account/university", "code": "use_account"})
        # Nur fuer den naechsten Start vormerken: jede Uni hat ihren eigenen Datenordner
        config.set_env({"UNIVERSITY": uni})
    with db.cursor() as conn:
        for k, v in body.items():
            db.set_setting(conn, k, v)
        return _public_settings(db.get_settings(conn))


@app.get("/api/credentials")
def get_credentials():
    user, pw = config.credentials()
    return {"user": user, "password_set": bool(pw)}


@app.put("/api/credentials")
def put_credentials(body: dict = Body(...)):
    user = (body.get("user") or "").strip()
    pw = body.get("password") or ""
    if not user:
        raise HTTPException(400, "LUH-ID fehlt")
    if not pw:
        # Passwort leer gelassen: nur Benutzer aktualisieren, altes Passwort behalten
        _, pw = config.credentials()
        if not pw:
            raise HTTPException(400, "Passwort fehlt")
    config.save_credentials(user, pw)
    return {"ok": True, "user": user, "password_set": True}


# ----------------------------------------------------------------------------
# Module, Lernkalender, Lernpakete
# ----------------------------------------------------------------------------

@app.get("/api/dashboard")
def api_dashboard():
    with db.cursor() as conn:
        d = study.dashboard(conn)
    d["bg"] = _bg_state
    if isinstance(d.get("settings"), dict):
        d["settings"] = _public_settings(d["settings"])
    return d


@app.get("/api/deadlines")
def api_deadlines():
    """Kommende Fristen aus dem Learnweb (Abgaben, Tests), nach Zeit sortiert."""
    with db.cursor() as conn:
        return {"deadlines": study.upcoming_deadlines(conn, study.today())}


@app.get("/api/announcements")
def api_announcements(days: int = 30):
    """Ankuendigungen der Lehrenden (Learnweb/Stud.IP) mit erkannten Terminen, neueste zuerst."""
    from . import announcements
    with db.cursor() as conn:
        return {"announcements": announcements.recent(conn, days=max(1, min(days, 365)), limit=50, today=study.today())}


@app.get("/api/modules")
def api_modules():
    with db.cursor() as conn:
        return study.modules_overview(conn)


@app.get("/api/modules/{module_id}")
def api_module(module_id: int):
    with db.cursor() as conn:
        d = study.module_detail(conn, module_id)
    if not d:
        raise HTTPException(404)
    return d


@app.post("/api/modules/auto-assign")
def api_modules_auto_assign():
    """Ordnet Kurse ohne Modul per Namensaehnlichkeit zu; manuelle Zuordnungen bleiben unangetastet."""
    with db.cursor() as conn:
        study.ensure_modules(conn)
        assigned, uncertain = 0, []
        for c in db.rows(conn, "SELECT id, title, kind FROM courses WHERE module_id IS NULL AND id != '__user__'"):
            if c["kind"] == "sonstiges":
                continue
            mid = timetable.guess_module(conn, c["title"])
            if mid:
                conn.execute("UPDATE courses SET module_id=?, subject=(SELECT name FROM modules WHERE id=?) WHERE id=?", (mid, mid, c["id"]))
                assigned += 1
            else:
                uncertain.append({"id": c["id"], "title": c["title"], "suggestion": None})
    return {"assigned": assigned, "uncertain": uncertain}


@app.patch("/api/modules/{module_id}")
def api_module_patch(module_id: int, body: dict = Body(...)):
    allowed = {"name", "color", "icon", "priority", "exam_date", "sort", "semester", "active", "weekly_test", "test_minutes"}
    with db.cursor() as conn:
        for k, v in body.items():
            if k in allowed:
                conn.execute(f"UPDATE modules SET {k}=? WHERE id=?", (v or None if k == "exam_date" else v, module_id))
        if "name" in body:
            conn.execute("UPDATE courses SET subject=? WHERE module_id=?", (body["name"], module_id))
            conn.execute("UPDATE study_packages SET subject=? WHERE module_id=?", (body["name"], module_id))
        return _found(db.row(conn, "SELECT * FROM modules WHERE id=?", (module_id,)), "Modul")


@app.post("/api/modules")
def api_module_create(body: dict = Body(...)):
    name = (body.get("name") or "").strip()
    if not name:
        raise HTTPException(400, "Name fehlt")
    with db.cursor() as conn:
        n = db.row(conn, "SELECT COUNT(*) n FROM modules")["n"]
        cur = conn.execute("INSERT INTO modules(name, semester, color, sort, created_at) VALUES (?,?,?,?,?)",
                           (name, body.get("semester"), body.get("color") or study.PALETTE[n % len(study.PALETTE)], n, db.now_iso()))
        return db.row(conn, "SELECT * FROM modules WHERE id=?", (cur.lastrowid,))


@app.delete("/api/modules/{module_id}")
def api_module_delete(module_id: int):
    with db.cursor() as conn:
        if db.row(conn, "SELECT 1 FROM courses WHERE module_id=?", (module_id,)):
            raise HTTPException(400, "Modul enthält noch Kurse. Erst Kurse einem anderen Modul zuordnen.")
        _changed(conn.execute("DELETE FROM modules WHERE id=?", (module_id,)), "Modul")
    return {"ok": True}


@app.post("/api/courses/{course_id}/module")
def api_course_module(course_id: str, body: dict = Body(...)):
    """Kurs einem Modul zuordnen (manuell korrigierbar)."""
    with db.cursor() as conn:
        if not body.get("module_id"):
            conn.execute("UPDATE courses SET module_id=NULL WHERE id=?", (course_id,))
            return {"ok": True}
        m = db.row(conn, "SELECT id, name FROM modules WHERE id=?", (body.get("module_id"),))
        if not m:
            raise HTTPException(404, "Modul nicht gefunden")
        conn.execute("UPDATE courses SET module_id=?, subject=? WHERE id=?", (m["id"], m["name"], course_id))
    return {"ok": True}


@app.get("/api/calendar")
def api_calendar(start: str, end: str):
    with db.cursor() as conn:
        c = study.calendar(conn, date.fromisoformat(start), date.fromisoformat(end))
    if isinstance(c, dict) and isinstance(c.get("settings"), dict):
        c["settings"] = _public_settings(c["settings"])
    return c


@app.post("/api/calendar/generate")
def api_calendar_generate(body: dict = Body(default={})):
    start = date.fromisoformat(body["start"]) if body.get("start") else None
    with db.cursor() as conn:
        return study.generate_packages(conn, start, int(body.get("days") or 7), bool(body.get("replace")))


@app.get("/api/calendar/feasibility")
def api_feasibility():
    with db.cursor() as conn:
        return study.feasibility(conn)


@app.get("/api/tasks/open")
def api_open_tasks():
    with db.cursor() as conn:
        return study.open_tasks(conn)


@app.post("/api/tasks/{task_id}/status")
def api_task_status(task_id: int, body: dict = Body(...)):
    st = body.get("status")
    if st not in ("geplant", "in_bearbeitung", "erledigt", "nachholen", "uebersprungen"):
        raise HTTPException(400, "Ungültiger Status")
    with db.cursor() as conn:
        try:
            return study.set_task_status(conn, task_id, st, body.get("actual_minutes"), body.get("note") or "")
        except ValueError as e:
            raise HTTPException(404, str(e))


@app.post("/api/tasks/{task_id}/start-test")
def api_task_start_test(task_id: int):
    """Erzeugt (falls noetig) den Wissenstest zu einer Testaufgabe und liefert die Test-ID."""
    with db.cursor() as conn:
        t = db.row(conn, "SELECT t.*, p.subject, p.week_no, p.module_id FROM study_tasks t JOIN study_packages p ON p.id=t.package_id WHERE t.id=?", (task_id,))
        if not t or t["type"] != "test":
            raise HTTPException(404, "Testaufgabe nicht gefunden")
        if t["test_id"]:
            return {"test_id": t["test_id"]}
        # Gemeinsamer Wochentest des Moduls fuer diese Lehrwoche bereits vorhanden? -> wiederverwenden (idempotent)
        ex = db.row(conn, "SELECT id FROM tests WHERE module_id=? AND week_no=? AND auto=1", (t["module_id"], t["week_no"])) if t["module_id"] and t["week_no"] else None
        if ex:
            conn.execute("UPDATE study_tasks SET test_id=? WHERE id=?", (ex["id"], task_id))
            return {"test_id": ex["id"]}
        s = db.get_settings(conn)
    try:
        tid = planner.create_test(t["subject"], int(t["est_minutes"] or s["test_minutes"]), module_id=t["module_id"], week_no=t["week_no"], auto=True)
    except Exception as e:  # noqa: BLE001
        raise HTTPException(500, f"Test konnte nicht erstellt werden: {e}")
    with db.cursor() as conn:
        conn.execute("UPDATE study_tasks SET test_id=?, status=CASE WHEN status='geplant' THEN 'in_bearbeitung' ELSE status END WHERE id=?", (tid, task_id))
    return {"test_id": tid}


@app.patch("/api/tasks/{task_id}")
def api_task_patch(task_id: int, body: dict = Body(...)):
    allowed = {"title", "est_minutes", "sort", "type"}
    with db.cursor() as conn:
        for k, v in body.items():
            if k in allowed:
                conn.execute(f"UPDATE study_tasks SET {k}=? WHERE id=?", (v, task_id))
        t = _found(db.row(conn, "SELECT package_id FROM study_tasks WHERE id=?", (task_id,)), "Aufgabe")
        study._recalc_package(conn, t["package_id"])
        return db.row(conn, "SELECT * FROM study_tasks WHERE id=?", (task_id,))


@app.delete("/api/tasks/{task_id}")
def api_task_delete(task_id: int):
    with db.cursor() as conn:
        t = db.row(conn, "SELECT package_id FROM study_tasks WHERE id=?", (task_id,))
        _changed(conn.execute("DELETE FROM study_tasks WHERE id=?", (task_id,)), "Aufgabe")
        study._recalc_package(conn, t["package_id"])
    return {"ok": True}


@app.post("/api/packages")
def api_package_create(body: dict = Body(...)):
    """Manuelles Lernpaket mit Aufgaben anlegen."""
    with db.cursor() as conn:
        m = db.row(conn, "SELECT * FROM modules WHERE id=?", (body.get("module_id"),)) if body.get("module_id") else None
        tasks = body.get("tasks") or []
        tl = [{"type": t.get("type") or "frei", "file_id": t.get("file_id"), "title": t.get("title") or "Lernen", "est": int(t.get("est_minutes") or 45)} for t in tasks] or [{"type": "frei", "file_id": None, "title": body.get("title") or "Lernen", "est": int(body.get("minutes") or 60)}]
        pid = study._insert_package(conn, date.fromisoformat(body["date"]), m or {"id": None, "name": body.get("subject") or "Allgemein"}, tl, {"topic": body.get("title")})
        conn.execute("UPDATE study_packages SET generated=0 WHERE id=?", (pid,))
        return db.row(conn, "SELECT * FROM study_packages WHERE id=?", (pid,))


@app.get("/api/packages/{package_id}")
def api_package_get(package_id: int):
    with db.cursor() as conn:
        study.refresh_statuses(conn)
        p = db.row(conn, "SELECT p.*, m.color, m.name AS module_name FROM study_packages p LEFT JOIN modules m ON m.id=p.module_id WHERE p.id=?", (package_id,))
        if not p:
            raise HTTPException(404)
        p["tasks"] = db.rows(conn, """SELECT t.*, f.name AS file_name, f.last_page, te.submitted_at AS test_submitted, te.score AS test_score, te.max_score AS test_max
                                      FROM study_tasks t LEFT JOIN files f ON f.id=t.file_id LEFT JOIN tests te ON te.id=t.test_id WHERE t.package_id=? ORDER BY t.sort""", (package_id,))
        return p


@app.post("/api/packages/{package_id}/tasks")
def api_package_add_task(package_id: int, body: dict = Body(...)):
    with db.cursor() as conn:
        if not db.row(conn, "SELECT 1 FROM study_packages WHERE id=?", (package_id,)):
            raise HTTPException(404)
        n = db.row(conn, "SELECT COUNT(*) n FROM study_tasks WHERE package_id=?", (package_id,))["n"]
        conn.execute("INSERT INTO study_tasks(package_id, type, file_id, test_id, title, sort, est_minutes, status, created_at) VALUES (?,?,?,?,?,?,?, 'geplant', ?)",
                     (package_id, body.get("type") or "frei", body.get("file_id") or None, None, body.get("title") or "Lernen", n, int(body.get("est_minutes") or 45), db.now_iso()))
        study._recalc_package(conn, package_id)
        study.refresh_statuses(conn)
    return {"ok": True}


@app.patch("/api/packages/{package_id}")
def api_package_patch(package_id: int, body: dict = Body(...)):
    with db.cursor() as conn:
        if body.get("date"):
            study.move_package(conn, package_id, body["date"])
        for k in ("title", "sort"):
            if k in body:
                conn.execute(f"UPDATE study_packages SET {k}=? WHERE id=?", (body[k], package_id))
        return _found(db.row(conn, "SELECT * FROM study_packages WHERE id=?", (package_id,)), "Lernpaket")


@app.delete("/api/packages/{package_id}")
def api_package_delete(package_id: int):
    with db.cursor() as conn:
        conn.execute("DELETE FROM study_tasks WHERE package_id=?", (package_id,))
        _changed(conn.execute("DELETE FROM study_packages WHERE id=?", (package_id,)), "Lernpaket")
    return {"ok": True}


@app.post("/api/calendar/suggest")
def api_suggest(body: dict = Body(default={})):
    with db.cursor() as conn:
        if body.get("rescue"):
            return study.rescue_week(conn)
        return study.suggest_reschedule(conn, body.get("task_ids"), body.get("package_id"), int(body.get("horizon") or 10))


@app.post("/api/calendar/apply")
def api_apply(body: dict = Body(...)):
    with db.cursor() as conn:
        n = study.apply_moves(conn, body.get("moves") or [])
    return {"moved": n}


@app.post("/api/tasks/skip")
def api_skip(body: dict = Body(...)):
    with db.cursor() as conn:
        study.skip_tasks(conn, [int(x) for x in body.get("task_ids") or []])
    return {"ok": True}


@app.get("/api/tasks/history")
def api_history(limit: int = 50):
    with db.cursor() as conn:
        return db.rows(conn, "SELECT h.*, t.title FROM task_history h LEFT JOIN study_tasks t ON t.id=h.task_id ORDER BY h.id DESC LIMIT ?", (limit,))


@app.post("/api/files/{file_id}/opened")
def api_file_opened(file_id: str, body: dict = Body(default={})):
    with db.cursor() as conn:
        if "last_page" in body:
            cur = conn.execute("UPDATE files SET last_page=? WHERE id=?", (int(body["last_page"]), file_id))
        else:
            cur = conn.execute("UPDATE files SET last_opened=?, opened_count=COALESCE(opened_count,0)+1, seen_by_user=1 WHERE id=?", (db.now_iso(), file_id))
        _changed(cur, "Datei")
    return {"ok": True}


@app.post("/api/files/{file_id}/favorite")
def api_file_favorite(file_id: str, body: dict = Body(...)):
    with db.cursor() as conn:
        _changed(conn.execute("UPDATE files SET favorite=? WHERE id=?", (1 if body.get("favorite") else 0, file_id)), "Datei")
    return {"ok": True}


@app.get("/api/search")
def api_search(q: str):
    q = (q or "").strip().lower()
    if len(q) < 2:
        return {"files": [], "modules": []}
    like = f"%{q}%"
    with db.cursor() as conn:
        files = db.rows(conn, """SELECT f.id, f.name, c.subject, c.module_id, a.title AS ai_title, a.doc_type, a.topics FROM files f
                                 JOIN courses c ON c.id=f.course_id LEFT JOIN analysis a ON a.file_id=f.id
                                 WHERE lower(f.name) LIKE ? OR lower(COALESCE(a.title,'')) LIKE ? OR lower(COALESCE(a.topics,'')) LIKE ? OR lower(c.subject) LIKE ?
                                 ORDER BY f.chdate DESC LIMIT 20""", (like, like, like, like))
        mods = db.rows(conn, "SELECT id, name, color FROM modules WHERE lower(name) LIKE ? LIMIT 5", (like,))
    return {"files": files, "modules": mods}


# ----------------------------------------------------------------------------
# Stundenplan
# ----------------------------------------------------------------------------

@app.get("/api/timetable/week")
def api_tt_week(start: str):
    with db.cursor() as conn:
        return timetable.week_grid(conn, date.fromisoformat(start))


@app.get("/api/timetable/day")
def api_tt_day(date_: str = Query(alias="date")):
    with db.cursor() as conn:
        return timetable.day_timeline(conn, date.fromisoformat(date_))


@app.get("/api/timetable/events")
def api_tt_events():
    with db.cursor() as conn:
        return db.rows(conn, "SELECT e.*, m.name AS module_name FROM course_events e LEFT JOIN modules m ON m.id=e.module_id ORDER BY weekday, start_time")


@app.post("/api/timetable/events")
def api_tt_event_create(body: dict = Body(...)):
    with db.cursor() as conn:
        cur = conn.execute("""INSERT INTO course_events(module_id, course_id, title, kind, weekday, start_time, end_time, room, lecturer, rrule, date_from, date_to, attend, source, color, created_at)
                              VALUES (?,?,?,?,?,?,?,?,?,?,?,?,1,?,?,?)""",
                           (body.get("module_id"), body.get("course_id"), body.get("title") or "Veranstaltung", body.get("kind") or "vorlesung", int(body.get("weekday", 0)),
                            body.get("start_time") or "08:00", body.get("end_time") or "09:30", body.get("room") or "", body.get("lecturer") or "", body.get("rrule") or "weekly",
                            body.get("date_from"), body.get("date_to"), body.get("source") or "manual", body.get("color"), db.now_iso()))
        return db.row(conn, "SELECT * FROM course_events WHERE id=?", (cur.lastrowid,))


@app.patch("/api/timetable/events/{event_id}")
def api_tt_event_patch(event_id: int, body: dict = Body(...)):
    """scope: series (ganze Reihe) | future (ab Datum: Serie teilen) | single (nur dieser Termin -> Ausnahme)"""
    scope = body.pop("scope", "series")
    d = body.pop("date", None)
    allowed = {"module_id", "title", "kind", "weekday", "start_time", "end_time", "room", "lecturer", "rrule", "date_from", "date_to", "attend", "color"}
    with db.cursor() as conn:
        e = db.row(conn, "SELECT * FROM course_events WHERE id=?", (event_id,))
        if not e:
            raise HTTPException(404)
        if scope == "single" and d:
            timetable.set_exception(conn, event_id, d, "edit", new_start=body.get("start_time"), new_end=body.get("end_time"), note="einzeln bearbeitet")
            if body.get("date") or body.get("new_date"):
                timetable.set_exception(conn, event_id, d, "moved", new_date=body.get("new_date"), new_start=body.get("start_time"), new_end=body.get("end_time"))
            return {"ok": True, "scope": "single"}
        if scope == "future" and d:
            prev_end = (date.fromisoformat(d) - timedelta(days=1)).isoformat()
            conn.execute("UPDATE course_events SET date_to=? WHERE id=?", (prev_end, event_id))
            merged = {k: e[k] for k in allowed if k in e}
            merged.update({k: v for k, v in body.items() if k in allowed})
            merged["date_from"] = d
            merged["date_to"] = e["date_to"]
            cur = conn.execute("""INSERT INTO course_events(module_id, course_id, title, kind, weekday, start_time, end_time, room, lecturer, rrule, date_from, date_to, attend, source, color, created_at)
                                  VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                               (merged["module_id"], e["course_id"], merged["title"], merged["kind"], merged["weekday"], merged["start_time"], merged["end_time"], merged["room"], merged["lecturer"],
                                merged["rrule"], merged["date_from"], merged["date_to"], merged["attend"], e["source"], merged["color"], db.now_iso()))
            return {"ok": True, "scope": "future", "new_id": cur.lastrowid}
        for k, v in body.items():
            if k in allowed:
                conn.execute(f"UPDATE course_events SET {k}=? WHERE id=?", (v, event_id))
        return db.row(conn, "SELECT * FROM course_events WHERE id=?", (event_id,))


@app.delete("/api/timetable/events/{event_id}")
def api_tt_event_delete(event_id: int):
    with db.cursor() as conn:
        conn.execute("DELETE FROM event_exceptions WHERE event_id=?", (event_id,))
        conn.execute("DELETE FROM event_notes WHERE event_id=?", (event_id,))
        conn.execute("DELETE FROM course_events WHERE id=?", (event_id,))
    return {"ok": True}


@app.post("/api/timetable/attendance")
def api_tt_attendance(body: dict = Body(...)):
    """mode: today_skip | today_attend | permanent_skip | permanent_attend | cancelled | reset. Liefert freigewordene Zeit."""
    with db.cursor() as conn:
        e = db.row(conn, "SELECT * FROM course_events WHERE id=?", (body.get("event_id"),))
        if not e:
            raise HTTPException(404)
        d = body.get("date") or date.today().isoformat()
        before = timetable.free_windows(conn, date.fromisoformat(d))
        timetable.set_attendance(conn, e["id"], d, body.get("mode"))
        after = timetable.free_windows(conn, date.fromisoformat(d))
        freed = sum(w["minutes"] for w in after) - sum(w["minutes"] for w in before)
        mats = timetable.materials_for_event(conn, e, date.fromisoformat(d))
        new_windows = [w for w in after if not any(b["start"] == w["start"] and b["end"] == w["end"] for b in before)]
    return {"ok": True, "freed_minutes": max(0, freed), "windows": new_windows, "materials": mats, "event": e}


@app.post("/api/timetable/exceptions")
def api_tt_exception(body: dict = Body(...)):
    with db.cursor() as conn:
        timetable.set_exception(conn, int(body["event_id"]), body["date"], body.get("type") or "edit", body.get("new_date"), body.get("new_start"), body.get("new_end"), body.get("note") or "")
    return {"ok": True}


@app.get("/api/timetable/free")
def api_tt_free(date_: str = Query(alias="date")):
    with db.cursor() as conn:
        return timetable.free_windows(conn, date.fromisoformat(date_))


@app.get("/api/timetable/event-materials/{event_id}")
def api_tt_materials(event_id: int, date_: str = Query(alias="date")):
    with db.cursor() as conn:
        e = db.row(conn, "SELECT * FROM course_events WHERE id=?", (event_id,))
        if not e:
            raise HTTPException(404)
        return timetable.materials_for_event(conn, e, date.fromisoformat(date_))


@app.post("/api/timetable/import/preview")
async def api_tt_import_preview(source: str = Form(...), text: str = Form(default=""), upload: UploadFile | None = File(default=None)):
    """Quelle: studip | ics | text | pdf | image | manual. Liefert bearbeitbare Vorschau + Vergleich mit vorhandenem Plan."""
    raw = text or ""
    entries: list[dict] = []
    with db.cursor() as conn:
        try:
            if source == "studip":
                entries = timetable.studip_entries(conn)
            elif source == "ics":
                raw = (await upload.read()).decode("utf-8", errors="replace") if upload else text
                entries = timetable.parse_ics(raw)
            elif source == "pdf":
                if not upload:
                    raise HTTPException(400, "PDF fehlt")
                tmp = config.data_dir() / "imports"; tmp.mkdir(exist_ok=True)
                p = tmp / f"{uuid.uuid4().hex}.pdf"; p.write_bytes(await upload.read())
                from .extract import extract_text
                raw = extract_text(p, 20000)
                entries = timetable.ai_parse(conn, raw)
            elif source == "image":
                if not upload:
                    raise HTTPException(400, "Bild fehlt")
                tmp = config.data_dir() / "imports"; tmp.mkdir(exist_ok=True)
                ext = Path(upload.filename or "x.png").suffix.lower() or ".png"
                if ext not in (".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic"):
                    raise HTTPException(400, "Nur Bilddateien")
                p = tmp / f"{uuid.uuid4().hex}{ext}"; p.write_bytes(await upload.read())
                raw = str(p)
                entries = timetable.ai_parse(conn, image_path=str(p))
            else:  # text
                entries = timetable.ai_parse(conn, raw)
        except HTTPException:
            raise
        except Exception as e:  # noqa: BLE001
            raise HTTPException(500, f"Import fehlgeschlagen: {e}")
        entries = timetable.enrich(conn, entries)
        diff = timetable.diff_against_existing(conn, entries)
        cur = conn.execute("INSERT INTO schedule_imports(source, created_at, status, raw, parsed, confirmed) VALUES (?,?,?,?,?,0)",
                           (source, db.now_iso(), "preview", raw[:20000], json.dumps(entries, ensure_ascii=False)))
    return {"import_id": cur.lastrowid, "entries": entries, "diff": diff, "modules": _modules_brief()}


def _modules_brief():
    with db.cursor() as conn:
        return db.rows(conn, "SELECT id, name, color FROM modules ORDER BY name")


@app.post("/api/timetable/import/confirm")
def api_tt_import_confirm(body: dict = Body(...)):
    with db.cursor() as conn:
        res = timetable.apply_import(conn, body.get("entries") or [], body.get("source") or "manual", body.get("remove_ids") or [])
        if body.get("import_id"):
            conn.execute("UPDATE schedule_imports SET confirmed=1, status='confirmed' WHERE id=?", (body["import_id"],))
        conflicts = study.slot_conflicts(conn, date.today(), date.today() + timedelta(days=28))
    return {**res, "conflicts": conflicts}


@app.get("/api/timetable/conflicts")
def api_tt_conflicts(days: int = 28):
    with db.cursor() as conn:
        return study.slot_conflicts(conn, date.today(), date.today() + timedelta(days=days))


@app.post("/api/timetable/reslot")
def api_tt_reslot(body: dict = Body(default={})):
    """Lernslots der betroffenen Tage neu in freie Fenster legen."""
    days = body.get("dates") or []
    with db.cursor() as conn:
        if not days:
            days = sorted({c["date"] for c in study.slot_conflicts(conn, date.today(), date.today() + timedelta(days=28))})
        for d in days:
            study.reslot_day(conn, date.fromisoformat(d))
    return {"reslotted": days}


@app.get("/api/terms")
def api_terms():
    with db.cursor() as conn:
        return timetable.term(conn)


@app.put("/api/terms")
def api_terms_put(body: dict = Body(...)):
    with db.cursor() as conn:
        conn.execute("UPDATE terms SET active=0")
        conn.execute("INSERT INTO terms(name, start, end, active) VALUES (?,?,?,1)", (body.get("name") or "Semester", body["start"], body["end"]))
        return timetable.term(conn)


# ----------------------------------------------------------------------------
# Uni-Dienste, QIS (Notenspiegel), Zugaenge
# ----------------------------------------------------------------------------

SERVICES = [
    {"key": "studip", "name": "Stud.IP", "url": "https://studip.uni-hannover.de/", "desc": "Kurse, Dateien, Termine, Ankündigungen", "login": "WebSSO (LUH-ID)", "icon": "book", "connected": True},
    {"key": "ilias", "name": "ILIAS", "url": "https://ilias.uni-hannover.de/", "desc": "Lernplattform: Kurse, Tests, Lernmodule", "login": "WebSSO (LUH-ID)", "icon": "layers"},
    {"key": "qis", "name": "QIS / LSF (Prüfungsverwaltung)", "url": "https://qis.verwaltung.uni-hannover.de/qisserver/servlet/de.his.servlet.RequestDispatcherServlet?state=user&type=0&application=lsf", "desc": "Notenspiegel, Prüfungsanmeldung, Bescheinigungen", "login": "LUH-ID", "icon": "exam", "connector": True},
    {"key": "idm", "name": "IDM Account-Manager", "url": "https://login.uni-hannover.de/", "desc": "LUH-ID verwalten, Passwort ändern, WebSSO", "login": "LUH-ID", "icon": "user"},
    {"key": "mail", "name": "E-Mail (LUIS)", "url": "https://www.luis.uni-hannover.de/de/services/kommunikation/e-mail", "desc": "Studentisches E-Mail-Postfach und Webmail", "login": "LUH-ID", "icon": "bell"},
    {"key": "matrix", "name": "Matrix-Chat", "url": "https://www.luis.uni-hannover.de/de/services/kommunikation/messenger-chat-dienst-matrix", "desc": "Messenger der Uni, auch in Stud.IP-Kursen", "login": "LUH-ID", "icon": "users"},
    {"key": "luhki", "name": "LUHKI", "url": "https://www.luis.uni-hannover.de/de/services/anwendungen/luhki-2", "desc": "KI-Plattform der LUH", "login": "LUH-ID", "icon": "sparkles"},
    {"key": "gitlab", "name": "GitLab (LUIS)", "url": "https://www.luis.uni-hannover.de/de/services/anwendungen/versionsverwaltung-von-software-projekten-gitlab", "desc": "Versionsverwaltung für Programmieren-Projekte", "login": "LUH-ID", "icon": "file-text"},
    {"key": "tib", "name": "TIB Bibliothek", "url": "https://www.tib.eu/", "desc": "Literatur, Lernplätze, Ausleihe", "login": "Bibliotheksausweis", "icon": "book"},
    {"key": "mensa", "name": "Mensa (Studentenwerk)", "url": "https://www.studentenwerk-hannover.de/essen/speiseplaene", "desc": "Speisepläne der Mensen", "login": "–", "icon": "sun"},
    {"key": "servicecenter", "name": "ServiceCenter", "url": "https://www.uni-hannover.de/de/studium/beratung-hilfe/servicecenter", "desc": "Immatrikulation, Rückmeldung, Beratung", "login": "–", "icon": "info"},
    {"key": "luis", "name": "LUIS IT-Support", "url": "https://www.luis.uni-hannover.de/de/services/kurse-beratung-und-support/it-support", "desc": "WLAN, VPN, Software, Zugänge", "login": "–", "icon": "settings"},
]


CRED_SERVICES = {"studip": "STUDIP", "qis": "QIS", "idm": "IDM", "ilias": "ILIAS", "mail": "MAIL", "matrix": "MATRIX", "luhki": "LUHKI", "gitlab": "GITLAB",
                 "hildesheim": "HILDESHEIM"}


def _cred_overview() -> dict:
    su, sp = config.credentials()
    out = {"studip": {"own": bool(su and sp), "same_as": None, "user": su if su and sp else None, "configured": bool(su and sp)}}
    for key, prefix in CRED_SERVICES.items():
        if key != "studip":
            out[key] = config.service_status(prefix)
    return out


def _hildesheim_creds() -> dict:
    u, p = config.own_credentials("HILDESHEIM")
    return {"own": bool(u and p), "same_as": None, "user": u or None, "configured": bool(u and p)}


@app.get("/api/services")
def api_services():
    from . import qis, universities
    with db.cursor() as conn:
        s = qis.summary(conn)
        uni = universities.current(conn)
    creds = _cred_overview()
    creds["hildesheim"] = _hildesheim_creds()
    q = creds["qis"]
    hi = uni["key"] == "hildesheim"
    return {"services": universities.HILDESHEIM_SERVICES if hi else SERVICES, "credentials": creds,
            "university": {k: uni[k] for k in ("key", "name", "short", "files_source", "grades_source", "login", "user_label")},
            "universities": [{"key": k, "name": v["name"]} for k, v in universities.PROFILES.items()],
            "university_next": config.configured_university(),
            "learnweb": {"token_set": bool(config.secret("LEARNWEB_TOKEN"))},
            "qis": {"configured": creds["hildesheim"]["configured"] if hi else q["configured"],
                    "same_as_studip": False if hi else (q.get("same_as") == "studip" or (not q["configured"])), "last_run": s["last_run"]},
            "studip": {"configured": creds["studip"]["configured"]}}


@app.put("/api/learnweb/token")
def put_learnweb_token(body: dict = Body(...)):
    """Learnweb-Sicherheitsschluessel (Moodle mobile web service) lokal in der .env speichern oder loeschen."""
    if body.get("clear"):
        config.set_env({"LEARNWEB_TOKEN": None})
        return {"ok": True, "token_set": False}
    token = (body.get("token") or "").strip()
    if not re.fullmatch(r"[A-Za-z0-9]{16,128}", token):
        raise HTTPException(400, "Der Schlüssel besteht aus Buchstaben und Ziffern (meist 32 Zeichen).")
    config.set_env({"LEARNWEB_TOKEN": token})
    return {"ok": True, "token_set": True}


@app.get("/api/grades")
def api_grades():
    from . import qis
    with db.cursor() as conn:
        return qis.summary(conn)


@app.post("/api/grades/sync")
def api_grades_sync(show: bool = False):
    from . import qis
    return _run_bg("Notenspiegel", lambda: qis.run(show_browser=show)["message"])


@app.get("/api/qis/documents/{doc_id}")
def api_qis_document(doc_id: int):
    with db.cursor() as conn:
        d = db.row(conn, "SELECT * FROM qis_documents WHERE id=?", (doc_id,))
    if not d or not Path(d["local_path"]).exists():
        raise HTTPException(404)
    return FileResponse(d["local_path"], media_type="application/pdf", filename=Path(d["local_path"]).name)


@app.put("/api/credentials/{service}")
def put_service_credentials(service: str, body: dict = Body(...)):
    prefix = CRED_SERVICES.get(service)
    if not prefix or service == "studip":
        raise HTTPException(404, "Unbekannter Dienst")
    if body.get("clear"):
        config.set_env({f"{prefix}_USER": None, f"{prefix}_PASSWORD": None, f"{prefix}_SAME_AS": None})
        return {"ok": True, "configured": False}
    same = (body.get("same_as") or "").strip().lower()
    if same:
        if same not in CRED_SERVICES or same == service:
            raise HTTPException(400, "Ungültiger Verweis")
        config.set_env({f"{prefix}_USER": None, f"{prefix}_PASSWORD": None, f"{prefix}_SAME_AS": CRED_SERVICES[same]})
        return {"ok": True, "configured": True, "same_as": same}
    user = (body.get("user") or "").strip(); pw = body.get("password") or ""
    if not user or not pw:
        raise HTTPException(400, "Benutzername und Passwort angeben")
    config.save_credentials(user, pw, prefix)
    return {"ok": True, "configured": True}


@app.post("/api/related")
def api_related(body: dict = Body(...)):
    """Passende Vorlesungs-/Skriptstellen zu einem Aufgabentext (oder einer Seite) eines Dokuments."""
    from . import scriptsearch
    fid = body.get("file_id"); text = (body.get("text") or "").strip(); page = int(body.get("page") or 0)
    with db.cursor() as conn:
        f = db.row(conn, "SELECT f.id, c.module_id FROM files f JOIN courses c ON c.id=f.course_id WHERE f.id=?", (fid,))
        if not f or not f["module_id"]:
            return {"terms": [], "results": [], "note": "Dokument gehoert zu keinem Modul"}
        if not text and page:
            pages = scriptsearch.page_texts(conn, fid)
            text = pages[page - 1] if 0 < page <= len(pages) else ""
        return scriptsearch.search(conn, f["module_id"], text[:6000], exclude=fid)


@app.get("/api/network")
def api_network():
    import os
    import socket
    ips: set[str] = set()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ips.add(info[4][0])
    except OSError:
        pass
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(("10.255.255.255", 1)); ips.add(s.getsockname()[0]); s.close()
    except OSError:
        pass
    ips = sorted(i for i in ips if not i.startswith("127.") and not i.startswith("169.254."))
    return {"ips": ips, "port": config.PORT, "pin": _lan_pin(), "hostname": socket.gethostname(), "lan": os.environ.get("LERNAPP_LAN") == "1",
            "urls": [f"http://{i}:{config.PORT}" for i in ips]}


@app.get("/api/timetable/auto-status")
def api_tt_auto_status():
    with db.cursor() as conn:
        entries = timetable.studip_entries(conn)
        pending = [e for e in entries if not e.get("selected")]
        groups = sorted({e["title"] for e in pending})
    return {"pending_groups": len(pending), "courses": groups, "personal": [e for e in entries if e.get("personal")]}


# ----------------------------------------------------------------------------
# Bibliothek: Ordner, Notizbuecher, Papierkorb, Aufnahmen
# ----------------------------------------------------------------------------

@app.get("/api/library")
def api_library():
    with db.cursor() as conn:
        study.ensure_modules(conn)
        folders = db.rows(conn, "SELECT * FROM folders ORDER BY name")
        files = db.rows(conn, """SELECT f.id, f.name, COALESCE(f.title, f.name) AS title, f.chdate, f.status, f.favorite, f.last_opened, f.folder_id, f.kind, f.page_count, f.size, f.downloaded_at, f.course_id, f.studip_folder,
                                        c.module_id, c.subject, c.kind AS course_kind, a.doc_type, a.title AS ai_title, a.difficulty,
                                        (SELECT 1 FROM annotations an WHERE an.file_id=f.id) AS has_notes, (SELECT updated_at FROM annotations an WHERE an.file_id=f.id) AS edited_at
                                 FROM files f JOIN courses c ON c.id=f.course_id LEFT JOIN analysis a ON a.file_id=f.id
                                 WHERE f.deleted_at IS NULL AND c.active=1 ORDER BY f.chdate DESC""")
        files = [study.enrich_file(f) for f in files]
        trash = db.rows(conn, "SELECT id, COALESCE(title, name) AS title, deleted_at, kind FROM files WHERE deleted_at IS NOT NULL ORDER BY deleted_at DESC")
        mods = db.rows(conn, "SELECT id, name, color FROM modules ORDER BY sort, name")
    return {"folders": folders, "files": files, "modules": mods, "trash": trash}


@app.post("/api/folders")
def api_folder_create(body: dict = Body(...)):
    with db.cursor() as conn:
        cur = conn.execute("INSERT INTO folders(name, parent_id, module_id, color, created_at) VALUES (?,?,?,?,?)",
                           (body.get("name") or "Neuer Ordner", body.get("parent_id"), body.get("module_id"), body.get("color"), db.now_iso()))
        return db.row(conn, "SELECT * FROM folders WHERE id=?", (cur.lastrowid,))


@app.patch("/api/folders/{folder_id}")
def api_folder_patch(folder_id: int, body: dict = Body(...)):
    with db.cursor() as conn:
        for k in ("name", "parent_id", "module_id", "color"):
            if k in body:
                conn.execute(f"UPDATE folders SET {k}=? WHERE id=?", (body[k], folder_id))
        return _found(db.row(conn, "SELECT * FROM folders WHERE id=?", (folder_id,)), "Ordner")


@app.delete("/api/folders/{folder_id}")
def api_folder_delete(folder_id: int):
    with db.cursor() as conn:
        conn.execute("UPDATE files SET folder_id=(SELECT parent_id FROM folders WHERE id=?) WHERE folder_id=?", (folder_id, folder_id))
        conn.execute("UPDATE folders SET parent_id=(SELECT parent_id FROM folders WHERE id=?) WHERE parent_id=?", (folder_id, folder_id))
        _changed(conn.execute("DELETE FROM folders WHERE id=?", (folder_id,)), "Ordner")
    return {"ok": True}


@app.post("/api/notebooks")
async def api_notebook_create(kind: str = Form(default="notebook"), title: str = Form(default="Neues Notizbuch"), module_id: str = Form(default=""),
                              folder_id: str = Form(default=""), template: str = Form(default="blank"), upload: UploadFile | None = File(default=None)):
    """Eigenes Dokument: notebook | whiteboard | pdf (Import) | image (als PDF-Seite)."""
    fid = "u" + uuid.uuid4().hex[:23]
    local = None
    page_count = None
    if upload is not None and kind in ("pdf", "image"):
        d = config.data_dir() / "files" / "Eigene Dokumente"; d.mkdir(parents=True, exist_ok=True)
        ext = Path(upload.filename or "datei.pdf").suffix.lower() or ".pdf"
        if kind == "image" and ext not in (".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic"):
            raise HTTPException(400, "Nur Bilddateien")
        data = await upload.read()
        if kind == "pdf" and not data.startswith(b"%PDF"):
            raise HTTPException(400, "Die Datei ist keine PDF")
        if kind == "image":
            # Bild in eine PDF-Seite verpacken
            try:
                from PIL import Image  # type: ignore
                import io
                im = Image.open(io.BytesIO(data)).convert("RGB")
                p = d / f"{fid}.pdf"; im.save(p, "PDF")
                local = str(p); page_count = 1; title = title or Path(upload.filename or "Bild").stem
            except Exception:  # noqa: BLE001 - ohne Pillow als Bild-Asset speichern
                p = d / f"{fid}{ext}"; p.write_bytes(data); local = str(p); kind = "image"
        else:
            p = d / f"{fid}.pdf"; p.write_bytes(data); local = str(p)
            try:
                from pypdf import PdfReader
                page_count = len(PdfReader(str(p)).pages)
            except Exception:  # noqa: BLE001
                page_count = None
            title = title or Path(upload.filename or "Dokument").stem
    with db.cursor() as conn:
        conn.execute("""INSERT INTO files(id, course_id, name, size, mime, author, chdate, download_url, local_path, downloaded_at, first_seen, status, seen_by_user,
                                          folder_id, kind, title, page_count)
                        VALUES (?,'__user__',?,?,?,?,?,?,?,?,?,'gelesen',1,?,?,?,?)""",
                     (fid, (title or "Dokument") + (".pdf" if local else ""), 0, "application/pdf" if local else None, "Ich", int(datetime.now().timestamp()), "", local, db.now_iso(), db.now_iso(),
                      int(folder_id) if folder_id else None, kind, title or "Dokument", page_count))
        if kind in ("notebook", "whiteboard"):
            size = {"w": 842, "h": 595} if kind == "whiteboard" else {"w": 595, "h": 842}
            model = {"version": 2, "zoom": 1.2, "pages": {"b1": {"objects": []}}, "pageOrder": [{"key": "b1", "type": "blank", "template": template, **size}], "bookmarks": [], "outline": []}
            conn.execute("INSERT INTO annotations(file_id, data, updated_at, version) VALUES (?,?,?,1)", (fid, json.dumps(model), db.now_iso()))
        if module_id:
            m = db.row(conn, "SELECT name FROM modules WHERE id=?", (int(module_id),))
            if m:
                conn.execute("UPDATE files SET folder_id=COALESCE(folder_id, NULL) WHERE id=?", (fid,))
                # Notizbuch dem Modul zuordnen: ueber Ordner mit module_id
                f = db.row(conn, "SELECT id FROM folders WHERE module_id=? AND parent_id IS NULL AND name='Eigene Notizen'", (int(module_id),))
                if not f:
                    cur = conn.execute("INSERT INTO folders(name, parent_id, module_id, created_at) VALUES ('Eigene Notizen', NULL, ?, ?)", (int(module_id), db.now_iso()))
                    f = {"id": cur.lastrowid}
                conn.execute("UPDATE files SET folder_id=? WHERE id=?", (f["id"], fid))
        return db.row(conn, "SELECT * FROM files WHERE id=?", (fid,))


@app.patch("/api/library/files/{file_id}")
def api_library_file_patch(file_id: str, body: dict = Body(...)):
    with db.cursor() as conn:
        if "title" in body:
            conn.execute("UPDATE files SET title=? WHERE id=?", (body["title"], file_id))
        if "folder_id" in body:
            conn.execute("UPDATE files SET folder_id=? WHERE id=?", (body["folder_id"], file_id))
        if body.get("trash"):
            conn.execute("UPDATE files SET deleted_at=? WHERE id=?", (db.now_iso(), file_id))
        if body.get("restore"):
            conn.execute("UPDATE files SET deleted_at=NULL WHERE id=?", (file_id,))
        if body.get("duplicate"):
            src = db.row(conn, "SELECT * FROM files WHERE id=?", (file_id,))
            ann = db.row(conn, "SELECT data FROM annotations WHERE file_id=?", (file_id,))
            nid = "u" + uuid.uuid4().hex[:23]
            conn.execute("""INSERT INTO files(id, course_id, name, size, mime, author, chdate, download_url, local_path, downloaded_at, first_seen, status, seen_by_user, folder_id, kind, title, page_count)
                            SELECT ?, course_id, name, size, mime, author, ?, download_url, local_path, downloaded_at, ?, 'gelesen', 1, folder_id, kind, COALESCE(title, name) || ' (Kopie)', page_count FROM files WHERE id=?""",
                         (nid, int(datetime.now().timestamp()), db.now_iso(), file_id))
            if ann:
                conn.execute("INSERT INTO annotations(file_id, data, updated_at, version) VALUES (?,?,?,1)", (nid, ann["data"], db.now_iso()))
            return {"ok": True, "id": nid}
        if body.get("delete_forever"):
            f = db.row(conn, "SELECT local_path, course_id FROM files WHERE id=?", (file_id,))
            if f and f["course_id"] != "__user__":
                raise HTTPException(400, "Stud.IP-Dokumente können nur in den Papierkorb, nicht endgültig gelöscht werden.")
            for t in ("annotation_versions", "annotations", "analysis", "flashcards", "recordings"):
                conn.execute(f"DELETE FROM {t} WHERE file_id=?", (file_id,))
            conn.execute("UPDATE study_tasks SET file_id=NULL WHERE file_id=?", (file_id,))
            conn.execute("DELETE FROM files WHERE id=?", (file_id,))
            # Duplikate teilen sich die Datei: nur loeschen, wenn sie kein anderes Dokument mehr nutzt
            shared = f and f["local_path"] and db.row(conn, "SELECT 1 FROM files WHERE local_path=?", (f["local_path"],))
            if f and f["local_path"] and not shared and Path(f["local_path"]).exists():
                try:
                    Path(f["local_path"]).unlink()
                except OSError:
                    pass
            return {"ok": True}
    return {"ok": True}


@app.get("/api/files/{file_id}/recordings")
def api_recordings(file_id: str):
    with db.cursor() as conn:
        return db.rows(conn, "SELECT * FROM recordings WHERE file_id=? ORDER BY id DESC", (file_id,))


@app.post("/api/files/{file_id}/recordings")
async def api_recording_add(file_id: str, upload: UploadFile = File(...), page: int = Form(default=1), title: str = Form(default=""), duration: float = Form(default=0)):
    _safe_id(file_id)
    ext = Path(upload.filename or "aufnahme.webm").suffix.lower() or ".webm"
    if ext not in (".webm", ".m4a", ".mp4", ".ogg", ".oga", ".wav", ".mp3", ".aac"):
        raise HTTPException(400, "Nur Audio-Aufnahmen")
    name = f"rec_{uuid.uuid4().hex}{ext}"
    target = _inside(_assets_dir(), _assets_dir() / file_id); target.mkdir(parents=True, exist_ok=True)
    (target / name).write_bytes(await upload.read())
    with db.cursor() as conn:
        cur = conn.execute("INSERT INTO recordings(file_id, page, title, url, duration, created_at) VALUES (?,?,?,?,?,?)",
                           (file_id, page, title or f"Aufnahme {datetime.now().strftime('%d.%m. %H:%M')}", f"/api/assets/{file_id}/{name}", duration, db.now_iso()))
        return db.row(conn, "SELECT * FROM recordings WHERE id=?", (cur.lastrowid,))


@app.delete("/api/recordings/{rec_id}")
def api_recording_delete(rec_id: int):
    with db.cursor() as conn:
        r = db.row(conn, "SELECT url FROM recordings WHERE id=?", (rec_id,))
        _changed(conn.execute("DELETE FROM recordings WHERE id=?", (rec_id,)), "Aufnahme")
    if r:
        try:
            p = _inside(_assets_dir(), _assets_dir() / r["url"].replace("/api/assets/", ""))
            if p.is_file():
                p.unlink()
        except HTTPException:
            pass                                             # alter Eintrag mit ungueltigem Pfad: nur DB-Zeile loeschen
    return {"ok": True}


@app.get("/api/bg")
def bg():
    return _bg_state


app.mount("/", StaticFiles(directory=str(STATIC_DIR), html=True), name="static")

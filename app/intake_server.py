"""Datei-Eingang: neue Kurs-PDFs der Geraete, einmal gesammelt und geordnet (Auftrag des Inhabers vom 18.11.2026).

Wortlaut: "nur an anderen server schicken erstmal ohne erklaeren bitte aber geordnet unbedingt". Ein eigenes Programm,
das auf einem eigenen Rechner laufen kann (oder als eigener Container neben dem Dienst): es kennt keine Konten, keine
Datenbank des Dienstes und keine KI.

Ablauf:
1. Die App holt beim StudiNow-Dienst ein Ticket (`POST /api/intake/ticket`, app/intake_api.py). Das Ticket traegt nur
   Hochschule, Ablaufzeit und eine Zufallszahl, keine Konto-ID; signiert mit LERNAPP_INTAKE_SECRET (beide Seiten).
2. `POST /intake/v1/check` mit den Karteikarten der neuen Dateien (Fingerabdruck SHA-256, Studiengang, Semester, Modul,
   Art, Name, Seiten). Bekannte Dateien bekommen nur einen weiteren Platz in der Ordnung; zurueck kommt, welche Dateien
   noch fehlen.
3. `POST /intake/v1/file` laedt eine fehlende Datei hoch (PDF, hoechstens MAX_FILE_BYTES). Der Eingang prueft, dass der
   Inhalt zum Fingerabdruck passt, dass es eine PDF ist und dass sie nicht wie eine Liste mit Namen aussieht.

Ablage (INTAKE_DATA_DIR):
- `dateien/<sha[:2]>/<sha>.pdf`: jede Datei genau einmal
- `geordnet/<Hochschule>/<Studiengang>/<Semester>/<Modul>/<Art>/<Name>.pdf`: dieselbe Datei als harter Link (kein
  zweiter Platz auf der Platte), je Studiengang ein Eintrag
- `eingang.db` (SQLite): Tabelle `files` (je Datei) und `places` (je Platz in der Ordnung). Keine Konto-ID, keine
  IP-Adresse.

Start: `INTAKE_DATA_DIR=/data/eingang LERNAPP_INTAKE_SECRET=... uvicorn app.intake_server:app --no-access-log`
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import io
import json
import os
import re
import sqlite3
import threading
import time
import unicodedata
from pathlib import Path

from fastapi import FastAPI, File, Form, Header, HTTPException, Request, UploadFile

MAX_FILE_BYTES = 80 << 20
MAX_CHECK_ITEMS = 500
# je Ticket (gilt eine Stunde): so viele Dateien und Bytes hoechstens
TICKET_MAX_FILES = 300
TICKET_MAX_BYTES = 3 << 30
TICKET_TTL_S = 3600
DOC_TYPES = {"vorlesung", "uebung", "loesung", "skript", "klausur"}
DOC_FOLDERS = {"vorlesung": "Vorlesungen", "uebung": "Uebungen", "loesung": "Loesungen", "skript": "Skripte",
               "klausur": "Klausuren"}
UNIVERSITIES = {"luh": "Leibniz Universitaet Hannover", "hildesheim": "Universitaet Hildesheim",
                "hsh": "Hochschule Hannover"}
NO_PROGRAM = "Ohne Studiengang"
NO_SEMESTER = "Ohne Semester"

_lock = threading.Lock()


# MARK: Ticket

def _secret() -> bytes:
    s = os.environ.get("LERNAPP_INTAKE_SECRET", "")
    if len(s) < 32:
        raise HTTPException(503, detail={"code": "intake_not_configured", "detail": "Der Datei-Eingang ist nicht eingerichtet."})
    return s.encode()


def _b64(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).decode().rstrip("=")


def _unb64(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def make_ticket(university: str, now: float | None = None, secret: bytes | None = None) -> dict:
    """Ticket fuer den Eingang (vom Dienst ausgestellt): Hochschule, Ablauf, Zufallszahl; keine Konto-ID"""
    now = time.time() if now is None else now
    body = {"u": university, "exp": int(now) + TICKET_TTL_S, "n": _b64(os.urandom(12))}
    raw = json.dumps(body, separators=(",", ":"), sort_keys=True).encode()
    sig = hmac.new(secret or _secret(), raw, hashlib.sha256).digest()
    return {"ticket": _b64(raw) + "." + _b64(sig), "expires": body["exp"]}


def read_ticket(authorization: str | None, now: float | None = None) -> dict:
    secret = _secret()                                  # ohne Einrichtung: 503, nicht "Ticket ungueltig"
    token = (authorization or "").removeprefix("Bearer ").strip()
    try:
        raw_b64, sig_b64 = token.split(".", 1)
        raw = _unb64(raw_b64)
        ok = hmac.compare_digest(hmac.new(secret, raw, hashlib.sha256).digest(), _unb64(sig_b64))
        body = json.loads(raw) if ok else None
    except Exception:
        body = None
    if not isinstance(body, dict) or not isinstance(body.get("n"), str) or not isinstance(body.get("exp"), int):
        raise HTTPException(401, detail={"code": "ticket_invalid", "detail": "Ticket ungueltig."})
    if body["exp"] < (time.time() if now is None else now):
        raise HTTPException(401, detail={"code": "ticket_expired", "detail": "Ticket abgelaufen."})
    if body.get("u") not in UNIVERSITIES:
        raise HTTPException(401, detail={"code": "ticket_invalid", "detail": "Ticket ungueltig."})
    return body


# MARK: Ablage

def data_dir() -> Path:
    d = Path(os.environ.get("INTAKE_DATA_DIR", "./eingang-daten")).resolve()
    d.mkdir(parents=True, exist_ok=True)
    return d


def _db() -> sqlite3.Connection:
    c = sqlite3.connect(data_dir() / "eingang.db", timeout=30)
    c.row_factory = sqlite3.Row
    c.execute("PRAGMA journal_mode=WAL")
    c.executescript("""
        CREATE TABLE IF NOT EXISTS files (
            sha256 TEXT PRIMARY KEY,
            size INTEGER NOT NULL,
            pages INTEGER,
            path TEXT NOT NULL,
            first_seen TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS places (
            sha256 TEXT NOT NULL,
            university TEXT NOT NULL,
            program TEXT NOT NULL,
            semester TEXT NOT NULL,
            module TEXT NOT NULL,
            doc_type TEXT NOT NULL,
            file_name TEXT NOT NULL,
            course_title TEXT,
            course_number TEXT,
            week INTEGER,
            path TEXT,
            first_seen TEXT NOT NULL,
            reports INTEGER NOT NULL DEFAULT 1,
            PRIMARY KEY (sha256, university, program, semester, module)
        );
        CREATE TABLE IF NOT EXISTS tickets (
            nonce TEXT PRIMARY KEY,
            files INTEGER NOT NULL DEFAULT 0,
            bytes INTEGER NOT NULL DEFAULT 0,
            expires INTEGER NOT NULL
        );
        """)
    return c


def _now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def folder_name(s: str, fallback: str, limit: int = 90) -> str:
    """Ordner- bzw. Dateiname: lesbar, ohne Pfadzeichen, Umlaute bleiben (NFC), hoechstens `limit` Zeichen"""
    s = unicodedata.normalize("NFC", str(s or "")).strip()
    s = re.sub(r"[\x00-\x1f/\\:*?\"<>|]+", " ", s)
    s = re.sub(r"\s+", " ", s).strip(" .")
    return (s[:limit].rstrip(" .") or fallback)


SHA_RE = re.compile(r"^[0-9a-f]{64}$")


def clean_meta(m: object, university: str) -> dict:
    """Karteikarte einer Datei pruefen und kuerzen. Wirft 422 bei Unsinn."""
    if not isinstance(m, dict):
        raise HTTPException(422, detail="Karteikarte ist kein Objekt")
    sha = str(m.get("sha256", "")).lower()
    if not SHA_RE.match(sha):
        raise HTTPException(422, detail="sha256 fehlt oder ist falsch")
    doc_type = str(m.get("doc_type", ""))
    if doc_type not in DOC_TYPES:
        raise HTTPException(422, detail="Diese Art von Datei nimmt der Eingang nicht an")
    name = folder_name(m.get("file_name"), "Datei", 120)
    if not name.lower().endswith(".pdf"):
        name += ".pdf"
    week = m.get("week")
    pages = m.get("pages")
    return {
        "sha256": sha, "university": university,
        "program": folder_name(m.get("program"), NO_PROGRAM),
        "semester": folder_name(str(m.get("semester") or "").replace("/", "-"), NO_SEMESTER, 40),   # "WS 2026/27" -> "WS 2026-27"
        "module": folder_name(m.get("module"), "Ohne Modul"),
        "doc_type": doc_type, "file_name": name,
        "course_title": folder_name(m.get("course_title"), "", 160) or None,
        "course_number": folder_name(m.get("course_number"), "", 40) or None,
        "week": week if isinstance(week, int) and 1 <= week <= 30 else None,
        "pages": pages if isinstance(pages, int) and 0 < pages <= 5000 else None,
    }


def _place(c: sqlite3.Connection, m: dict) -> None:
    """Platz in der Ordnung anlegen (oder einmal mehr gemeldet); liegt die Datei schon da, gleich verlinken"""
    c.execute("""INSERT INTO places(sha256, university, program, semester, module, doc_type, file_name, course_title,
                 course_number, week, first_seen) VALUES (?,?,?,?,?,?,?,?,?,?,?)
                 ON CONFLICT(sha256, university, program, semester, module) DO UPDATE SET reports=reports+1""",
              (m["sha256"], m["university"], m["program"], m["semester"], m["module"], m["doc_type"], m["file_name"],
               m["course_title"], m["course_number"], m["week"], _now()))
    f = c.execute("SELECT path FROM files WHERE sha256=?", (m["sha256"],)).fetchone()
    if f:
        _link_places(c, m["sha256"], data_dir() / f["path"])


def _link_places(c: sqlite3.Connection, sha: str, stored: Path) -> None:
    """Jeden noch nicht verlinkten Platz der Datei als harten Link in `geordnet/` anlegen"""
    root = data_dir()
    for p in c.execute("SELECT * FROM places WHERE sha256=? AND path IS NULL", (sha,)).fetchall():
        folder = (root / "geordnet" / UNIVERSITIES.get(p["university"], p["university"]) / p["program"] / p["semester"]
                  / p["module"] / DOC_FOLDERS[p["doc_type"]])
        folder.mkdir(parents=True, exist_ok=True)
        target = folder / p["file_name"]
        if target.exists() and not target.samefile(stored):
            # gleicher Name, anderer Inhalt (neue Fassung): Kurzform des Fingerabdrucks anhaengen
            target = folder / f"{Path(p['file_name']).stem} ({sha[:8]}).pdf"
        if not target.exists():
            try:
                os.link(stored, target)
            except OSError:
                target.symlink_to(stored)
        c.execute("""UPDATE places SET path=? WHERE sha256=? AND university=? AND program=? AND semester=? AND module=?""",
                  (str(target.relative_to(root)), sha, p["university"], p["program"], p["semester"], p["module"]))


# MARK: Listen mit Namen

NAME_LIST_WORDS = re.compile(
    r"matrikel|teilnehmerliste|teilnehmer\*innen-?liste|anwesenheitsliste|notenliste|notenspiegel|klausurergebnis"
    r"|ergebnisliste|gruppeneinteilung|sitzplan|raumverteilung|unterschrift", re.I)
MATRICULATION = re.compile(r"(?<!\d)\d{7,8}(?!\d)")


def looks_like_name_list(text: str, file_name: str = "") -> bool:
    """Liste mit Namen oder Matrikelnummern? Solche Dateien nimmt der Eingang nie an (gleiche Regel wie auf dem Geraet,
    `CourseFileIntake.looksLikeNameList`)."""
    if NAME_LIST_WORDS.search(file_name or ""):
        return True
    if len(MATRICULATION.findall(text or "")) >= 5:
        return True
    return len(NAME_LIST_WORDS.findall(text or "")) >= 2


def _first_pages_text(data: bytes, pages: int = 3) -> tuple[str, int | None]:
    try:
        from pypdf import PdfReader
        r = PdfReader(io.BytesIO(data))
        n = len(r.pages)
        return "\n".join((r.pages[i].extract_text() or "") for i in range(min(pages, n))), n
    except Exception:
        return "", None


# MARK: Programm

app = FastAPI(title="StudiNow Datei-Eingang", docs_url=None, redoc_url=None, openapi_url=None)


def _use_ticket(c: sqlite3.Connection, t: dict, add_files: int = 0, add_bytes: int = 0) -> None:
    c.execute("DELETE FROM tickets WHERE expires < ?", (int(time.time()) - 60,))
    c.execute("INSERT OR IGNORE INTO tickets(nonce, expires) VALUES (?,?)", (t["n"], t["exp"]))
    row = c.execute("SELECT files, bytes FROM tickets WHERE nonce=?", (t["n"],)).fetchone()
    if row["files"] + add_files > TICKET_MAX_FILES or row["bytes"] + add_bytes > TICKET_MAX_BYTES:
        raise HTTPException(429, detail={"code": "ticket_used_up", "detail": "Fuer dieses Ticket ist genug angekommen."})
    c.execute("UPDATE tickets SET files=files+?, bytes=bytes+? WHERE nonce=?", (add_files, add_bytes, t["n"]))


@app.get("/intake/v1/health")
def health() -> dict:
    return {"ok": True}


@app.post("/intake/v1/check")
async def check(request: Request, authorization: str | None = Header(default=None)) -> dict:
    t = read_ticket(authorization)
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(422, detail="JSON erwartet")
    items = body.get("files") if isinstance(body, dict) else None
    if not isinstance(items, list) or len(items) > MAX_CHECK_ITEMS:
        raise HTTPException(422, detail=f"files: Liste mit hoechstens {MAX_CHECK_ITEMS} Eintraegen")
    metas = [clean_meta(m, t["u"]) for m in items]
    missing: list[str] = []
    with _lock:
        c = _db()
        try:
            with c:
                _use_ticket(c, t)
                for m in metas:
                    _place(c, m)
                    if not c.execute("SELECT 1 FROM files WHERE sha256=?", (m["sha256"],)).fetchone() and m["sha256"] not in missing:
                        missing.append(m["sha256"])
        finally:
            c.close()
    return {"missing": missing}


@app.post("/intake/v1/file")
async def upload(upload: UploadFile = File(...), meta: str = Form(...), authorization: str | None = Header(default=None)) -> dict:
    t = read_ticket(authorization)
    try:
        m = clean_meta(json.loads(meta), t["u"])
    except json.JSONDecodeError:
        raise HTTPException(422, detail="meta ist kein JSON")
    data = await upload.read(MAX_FILE_BYTES + 1)
    if len(data) > MAX_FILE_BYTES:
        raise HTTPException(413, detail="Datei zu gross")
    if not data.startswith(b"%PDF-"):
        raise HTTPException(415, detail="Nur PDF")
    if hashlib.sha256(data).hexdigest() != m["sha256"]:
        raise HTTPException(422, detail={"code": "sha_mismatch", "detail": "Inhalt passt nicht zum Fingerabdruck."})
    text, pages = _first_pages_text(data)
    if looks_like_name_list(text, m["file_name"]):
        raise HTTPException(422, detail={"code": "name_list", "detail": "Listen mit Namen nimmt der Eingang nicht an."})
    rel = Path("dateien") / m["sha256"][:2] / f"{m['sha256']}.pdf"
    with _lock:
        c = _db()
        try:
            with c:
                _use_ticket(c, t, add_files=1, add_bytes=len(data))
                if c.execute("SELECT 1 FROM files WHERE sha256=?", (m["sha256"],)).fetchone():
                    _place(c, m)
                    return {"status": "known"}
                stored = data_dir() / rel
                stored.parent.mkdir(parents=True, exist_ok=True)
                tmp = stored.with_suffix(".part")
                tmp.write_bytes(data)
                os.replace(tmp, stored)
                c.execute("INSERT INTO files(sha256, size, pages, path, first_seen) VALUES (?,?,?,?,?)",
                          (m["sha256"], len(data), pages or m["pages"], str(rel), _now()))
                _place(c, m)
                _link_places(c, m["sha256"], stored)
        finally:
            c.close()
    return {"status": "stored"}


def overview() -> list[dict]:
    """Uebersicht fuer den Inhaber: je Hochschule, Studiengang, Semester und Modul die Zahl der Dateien"""
    c = _db()
    try:
        return [dict(r) for r in c.execute("""
            SELECT p.university, p.program, p.semester, p.module, COUNT(DISTINCT p.sha256) AS files,
                   COUNT(DISTINCT f.sha256) AS stored
            FROM places p LEFT JOIN files f ON f.sha256=p.sha256
            GROUP BY p.university, p.program, p.semester, p.module ORDER BY 1, 2, 3, 4""")]
    finally:
        c.close()

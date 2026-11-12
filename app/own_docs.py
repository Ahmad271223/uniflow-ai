"""Eigene Dokumente zwischen den Geraeten eines Kontos (12.11.2026, docs/WINDOWS-FERTIG-2026-11-12.md E3).

Eigene Dokumente (`files.course_id = '__user__'`: Notizbuecher, Whiteboards, importierte PDFs und Bilder) lagen nur auf
dem Geraet, das sie angelegt hat; im Web lagen sie nur im Dienst. Der Abgleich G2 (`app/sync.py`) kennt `files` nicht
und bleibt fuer das veroeffentlichte iPad unveraendert. Dieses Modul ist der zweite Weg, den Dienst und Windows-App
gemeinsam nutzen:

- Kennung ist die zufaellige ID des Dokuments (`u` + Hex), auf allen Geraeten gleich.
- `describe` beschreibt ein Dokument (Titel, Art, Ordner, Papierkorb, Favorit, Seitenzahl, Inhalt als SHA-256 und Groesse).
  Aendert sich etwas, merkt sich die Tabelle `own_doc_meta` einen neuen Zeitpunkt (`meta_at`); so erkennt der Abgleich
  auch Aenderungen ueber die normalen Wege der App (Umbenennen, Verschieben, Papierkorb), ohne dass diese etwas wissen.
- Endgueltig geloeschte Dokumente hinterlassen einen Grabstein (`own_doc_tombstones`), damit das Loeschen alle Geraete
  erreicht. `delete_forever` ist der eine Loeschweg (Bibliothek, Abgleich).
- Die Notizen eines eigenen Dokuments laufen weiter ueber G2 (`annotations`), aber nur zu Geraeten, die danach fragen
  (`own=1`); Bilder und eingefuegte PDF-Seiten (Assets) gleicht `asset_index` ab. Aufnahmen (Audio) bleiben am Geraet.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
from pathlib import Path

from . import db

ID_RE = re.compile(r"^u[0-9a-f]{8,40}$")
ASSET_DIR_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$")
# Bilder und PDF-Seiten des Editors (`POST /api/files/{id}/assets` vergibt uuid4().hex + Endung); Aufnahmen nicht
ASSET_NAME_RE = re.compile(r"^[0-9a-f]{32}\.(png|jpg|jpeg|gif|webp|svg|pdf)$")
ASSET_REF_RE = re.compile(r"/api/assets/([A-Za-z0-9][A-Za-z0-9_-]{0,79})/([A-Za-z0-9._-]{1,120})")
KINDS = ("notebook", "whiteboard", "pdf", "image", "file")
# groesser laedt die Windows-App nicht (Antwortgrenze service_link.MAX_BODY = 80 MB); der Status nennt solche Dateien
MAX_SYNC_BYTES = 75 << 20
META_KEYS = ("kind", "title", "name", "mime", "folder_id", "deleted_at", "page_count", "favorite")
OWN_DIR = "Eigene Dokumente"


def ensure_tables(conn) -> None:
    conn.execute("""CREATE TABLE IF NOT EXISTS own_doc_meta (
        file_id TEXT PRIMARY KEY, meta_hash TEXT, meta_at TEXT, sha256 TEXT, size INTEGER, mtime REAL)""")
    conn.execute("CREATE TABLE IF NOT EXISTS own_doc_tombstones (file_id TEXT PRIMARY KEY, deleted_at TEXT NOT NULL)")


def own_files_dir(data_dir: Path) -> Path:
    return Path(data_dir) / "files" / OWN_DIR


# ---------------------------------------------------------------- Beschreibung

def _cols(conn) -> set[str]:
    return {r[1] for r in conn.execute("PRAGMA table_info(files)")}


def content_info(conn, f: dict) -> tuple[str | None, int]:
    """(SHA-256, Groesse) der Datei hinter `local_path`; zwischengespeichert, solange Groesse und Zeitstempel gleich sind."""
    p = f.get("local_path")
    if not p:
        return None, 0
    try:
        st = os.stat(p)
    except OSError:
        return None, 0
    r = db.row(conn, "SELECT sha256, size, mtime FROM own_doc_meta WHERE file_id=?", (f["id"],))
    if r and r["sha256"] and r["size"] == st.st_size and r["mtime"] == st.st_mtime:
        return r["sha256"], st.st_size
    h = hashlib.sha256()
    with open(p, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    sha = h.hexdigest()
    conn.execute("INSERT INTO own_doc_meta(file_id, sha256, size, mtime) VALUES (?,?,?,?) "
                 "ON CONFLICT(file_id) DO UPDATE SET sha256=excluded.sha256, size=excluded.size, mtime=excluded.mtime",
                 (f["id"], sha, st.st_size, st.st_mtime))
    return sha, st.st_size


def meta_of(f: dict) -> dict:
    return {"kind": f.get("kind") or ("pdf" if f.get("local_path") else "notebook"), "title": f.get("title") or f.get("name"),
            "name": f.get("name"), "mime": f.get("mime"), "folder_id": f.get("folder_id"), "deleted_at": f.get("deleted_at"),
            "page_count": f.get("page_count"), "favorite": int(f.get("favorite") or 0)}


def meta_hash(meta: dict, sha: str | None) -> str:
    """Fingerabdruck von Beschreibung und Inhalt; aendert sich bei jeder Aenderung, die andere Geraete sehen sollen."""
    body = {k: meta.get(k) for k in META_KEYS}
    body["sha256"] = sha
    return hashlib.sha256(json.dumps(body, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def describe(conn, f: dict, now: str) -> dict:
    sha, size = content_info(conn, f)
    meta = meta_of(f)
    h = meta_hash(meta, sha)
    r = db.row(conn, "SELECT meta_hash, meta_at FROM own_doc_meta WHERE file_id=?", (f["id"],))
    at = r["meta_at"] if r else None
    if not r or r["meta_hash"] != h or not at:
        at = now
        conn.execute("INSERT INTO own_doc_meta(file_id, meta_hash, meta_at) VALUES (?,?,?) "
                     "ON CONFLICT(file_id) DO UPDATE SET meta_hash=excluded.meta_hash, meta_at=excluded.meta_at", (f["id"], h, at))
    return {"id": f["id"], **meta, "sha256": sha, "size": size, "has_content": bool(sha), "meta_at": at}


def own_rows(conn) -> list[dict]:
    return db.rows(conn, "SELECT * FROM files WHERE course_id='__user__' ORDER BY id")


def listing(conn, now: str) -> dict:
    ensure_tables(conn)
    docs = [describe(conn, f, now) for f in own_rows(conn)]
    tombs = db.rows(conn, "SELECT file_id AS id, deleted_at FROM own_doc_tombstones ORDER BY deleted_at")
    return {"documents": docs, "tombstones": tombs, "max_bytes": MAX_SYNC_BYTES}


# ---------------------------------------------------------------- Anlegen und Aendern

class OwnDocError(ValueError):
    def __init__(self, code: str, message: str, status: int = 400):
        super().__init__(message)
        self.code, self.message, self.status = code, message, status


def clean_meta(meta: dict) -> dict:
    """Beschreibung von einem anderen Geraet pruefen; Ordner-ID ist schon die des Empfaengers (oder None)."""
    if not isinstance(meta, dict):
        raise OwnDocError("meta_invalid", "Beschreibung fehlt.")
    kind = meta.get("kind") if meta.get("kind") in KINDS else "file"
    title = str(meta.get("title") or meta.get("name") or "Dokument").strip()[:300] or "Dokument"
    name = str(meta.get("name") or title).strip()[:300] or title
    mime = str(meta.get("mime"))[:100] if meta.get("mime") else None
    deleted = str(meta.get("deleted_at"))[:40] if meta.get("deleted_at") else None
    try:
        pages = int(meta["page_count"]) if meta.get("page_count") is not None else None
    except (TypeError, ValueError):
        pages = None
    try:
        folder = int(meta["folder_id"]) if meta.get("folder_id") is not None else None
    except (TypeError, ValueError):
        folder = None
    return {"kind": kind, "title": title, "name": name, "mime": mime, "folder_id": folder, "deleted_at": deleted,
            "page_count": pages, "favorite": 1 if meta.get("favorite") else 0}


def apply_meta(conn, fid: str, meta: dict) -> None:
    """Dokument anlegen oder seine Beschreibung uebernehmen. Nie eine Hochschuldatei ueberschreiben."""
    if not ID_RE.fullmatch(fid or ""):
        raise OwnDocError("id_invalid", "Ungültige Kennung eines eigenen Dokuments.")
    m = clean_meta(meta)
    if m["folder_id"] is not None and not db.row(conn, "SELECT 1 FROM folders WHERE id=?", (m["folder_id"],)):
        m["folder_id"] = None
    cur = db.row(conn, "SELECT course_id FROM files WHERE id=?", (fid,))
    if cur and cur["course_id"] != "__user__":
        raise OwnDocError("not_own_document", "Diese Kennung gehört keinem eigenen Dokument.", 409)
    cols = _cols(conn)
    if not cur:
        conn.execute("INSERT INTO files(id, course_id, name, size, mime, author, chdate, download_url, local_path, first_seen, status, "
                     "seen_by_user) VALUES (?,'__user__',?,0,?,'Ich',strftime('%s','now'),'',NULL,?,'gelesen',1)",
                     (fid, m["name"], m["mime"], db.now_iso()))
    sets = {k: m[k] for k in ("name", "mime", "folder_id", "kind", "title", "page_count", "deleted_at", "favorite") if k in cols}
    conn.execute(f"UPDATE files SET {', '.join(f'{k}=?' for k in sets)} WHERE id=?", (*sets.values(), fid))
    conn.execute("DELETE FROM own_doc_tombstones WHERE file_id=?", (fid,))


def content_target(data_dir: Path, fid: str, meta: dict) -> Path:
    """Ablageort des Inhalts: <Datenordner>/files/Eigene Dokumente/<id><Endung> wie beim Import."""
    ext = Path(str(meta.get("name") or "")).suffix.lower()
    if meta.get("kind") == "pdf" or (meta.get("mime") or "").endswith("/pdf") or not re.fullmatch(r"\.[a-z0-9]{1,8}", ext or ""):
        ext = ".pdf"
    return own_files_dir(data_dir) / f"{fid}{ext}"


def set_content(conn, fid: str, path: Path) -> None:
    conn.execute("UPDATE files SET local_path=?, size=?, downloaded_at=? WHERE id=?",
                 (str(path), path.stat().st_size, db.now_iso(), fid))


# ---------------------------------------------------------------- Loeschen

def record_tombstone(conn, fid: str) -> None:
    ensure_tables(conn)
    conn.execute("INSERT INTO own_doc_tombstones(file_id, deleted_at) VALUES (?, strftime('%Y-%m-%dT%H:%M:%fZ','now')) "
                 "ON CONFLICT(file_id) DO UPDATE SET deleted_at=excluded.deleted_at", (fid,))
    conn.execute("DELETE FROM own_doc_meta WHERE file_id=?", (fid,))


def asset_refs(conn, file_id: str) -> set[str]:
    """Asset-Ordner, auf die Notizen und Verlauf eines Dokuments verweisen (ein Duplikat verweist auf die des Originals)."""
    out: set[str] = set()
    for t in ("annotations", "annotation_versions"):
        for r in db.rows(conn, f"SELECT data FROM {t} WHERE file_id=?", (file_id,)):
            out.update(d for d, _ in ASSET_REF_RE.findall(r["data"] or ""))
    return out


def _inside(root: Path, p: Path) -> Path | None:
    try:
        rp = p.resolve()
        return rp if Path(root).resolve() in rp.parents else None
    except OSError:
        return None


def drop_unused_assets(conn, ids: set[str], assets_dir: Path) -> None:
    """Endgueltig geloescht (Audit P29-03): ein Asset-Ordner geht nur, wenn sein Dokument weg ist und keine Notiz,
    Version oder Aufnahme mehr auf ihn verweist."""
    for aid in ids:
        if not ASSET_DIR_RE.fullmatch(aid) or db.row(conn, "SELECT 1 FROM files WHERE id=?", (aid,)):
            continue
        like = f"%/api/assets/{aid}/%"
        if any(db.row(conn, f"SELECT 1 FROM {t} WHERE {c} LIKE ? LIMIT 1", (like,))
               for t, c in (("annotations", "data"), ("annotation_versions", "data"), ("recordings", "url"))):
            continue
        target = _inside(Path(assets_dir), Path(assets_dir) / aid)
        if target is not None:
            shutil.rmtree(target, ignore_errors=True)


def delete_forever(conn, file_id: str, assets_dir: Path, *, tombstone: bool = True) -> bool:
    """Eigenes Dokument endgueltig loeschen (Bibliothek "Endgültig löschen" und Abgleich). False = keins da."""
    f = db.row(conn, "SELECT local_path, course_id FROM files WHERE id=?", (file_id,))
    if f and f["course_id"] != "__user__":
        raise OwnDocError("not_own_document", "Stud.IP-Dokumente können nur in den Papierkorb, nicht endgültig gelöscht werden.")
    asset_dirs = asset_refs(conn, file_id) | {file_id}           # vor dem Loeschen: welche Asset-Ordner nutzt es
    for t in ("annotation_versions", "annotations", "analysis", "flashcards", "recordings"):
        conn.execute(f"DELETE FROM {t} WHERE file_id=?", (file_id,))
    # Stapel des Dokuments: leer -> weg, sonst bleibt er ohne Quelle (Karten aus anderen Dokumenten darin)
    conn.execute("DELETE FROM flashcard_stacks WHERE file_id=? AND NOT EXISTS (SELECT 1 FROM flashcards fc WHERE fc.stack_id=flashcard_stacks.id)", (file_id,))
    conn.execute("UPDATE flashcard_stacks SET file_id=NULL WHERE file_id=?", (file_id,))
    conn.execute("UPDATE study_tasks SET file_id=NULL WHERE file_id=?", (file_id,))
    conn.execute("DELETE FROM files WHERE id=?", (file_id,))
    # Duplikate teilen sich die Datei: nur loeschen, wenn sie kein anderes Dokument mehr nutzt
    shared = f and f["local_path"] and db.row(conn, "SELECT 1 FROM files WHERE local_path=?", (f["local_path"],))
    if f and f["local_path"] and not shared and Path(f["local_path"]).exists():
        try:
            Path(f["local_path"]).unlink()
        except OSError:
            pass
    drop_unused_assets(conn, asset_dirs, assets_dir)
    if tombstone and f:
        record_tombstone(conn, file_id)
    return bool(f)


# ---------------------------------------------------------------- Assets

def asset_index(assets_dir: Path) -> dict[str, dict[str, int]]:
    """Bilder und PDF-Seiten je Asset-Ordner: {ordner: {name: groesse}} (ohne Aufnahmen und fremde Namen)."""
    out: dict[str, dict[str, int]] = {}
    root = Path(assets_dir)
    if not root.is_dir():
        return out
    for d in root.iterdir():
        if not d.is_dir() or not ASSET_DIR_RE.fullmatch(d.name):
            continue
        for p in d.iterdir():
            if p.is_file() and ASSET_NAME_RE.fullmatch(p.name):
                out.setdefault(d.name, {})[p.name] = p.stat().st_size
    return out


def referenced_assets(conn) -> set[tuple[str, str]]:
    """(Ordner, Name) aller Bilder und PDF-Seiten, auf die eine Notiz dieses Geraets verweist."""
    out: set[tuple[str, str]] = set()
    for r in db.rows(conn, "SELECT data FROM annotations"):
        for d, n in ASSET_REF_RE.findall(r["data"] or ""):
            if ASSET_NAME_RE.fullmatch(n):
                out.add((d, n))
    return out

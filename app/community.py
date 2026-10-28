"""Community-Dienst (Vertrag G4): Loesungspakete veroeffentlichen, finden, laden, zurueckziehen, melden, sperren.

Nur im gehosteten Modus. Der Dienst bekommt ausschliesslich das verschluesselte Paket (`docs/LOESUNGEN-TEILEN.md`,
Format `uniflow-solution` Version 1); den Inhalt kann nur oeffnen, wer dieselbe Original-PDF hat (Schluessel aus den
PDF-Bytes). Der Dienst prueft deshalb nur den Kopf des Pakets und speichert es unveraendert.

Berechtigung: Veroeffentlichen, Suchen und Laden gibt es nur fuer Dateien aus dem eigenen Hochschul-Abgleich des
Kontos (Fingerabdruck `document.sha256` muss in der eigenen Datenbank als `files.content_sha256` einer Datei mit
Hochschul-Quelle stehen). Lesen und Schreiben brauchen den Tarif Plus (Entscheidung vom 25.10.2026).

Zentrale Ablage `community.db` und Paketdateien unter `community/` neben den Nutzerordnern. Autoren erscheinen
nur mit einem stabilen Pseudonym (HMAC aus Konto-ID und Dienst-Geheimnis), nie mit Konto-ID oder E-Mail.
Melden: eine Meldung je Konto und Loesung; ab REPORTS_TO_HIDE verschiedenen Meldungen ist die Loesung verborgen,
bis ein Admin entscheidet. Sperren: ein Konto blendet alle Loesungen eines Pseudonyms fuer sich aus. Admin:
verbergen, wiederherstellen, entfernen, Autor sperren.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import re
import sqlite3
import uuid
from contextlib import contextmanager
from datetime import date, datetime, timezone
from pathlib import Path

from . import accounts, config, db

FORMAT, FORMAT_VERSION = "uniflow-solution", 1
MAX_PACKAGE_BYTES = ((48 << 20) + 16 + 2) // 3 * 4 + (1 << 20)      # wie SolutionLimits.maxPackageBytes (rund 65 MB)
MAX_PAGES = 2_000
MAX_DISPLAY_NAME, MAX_TITLE = 60, 200
REPORTS_TO_HIDE = 3
REPORT_REASONS = ("foreignMaterial", "gradedSubmission", "offensive", "spam", "other")
HEADER_KEYS = {"solutionId", "createdAt", "displayName", "document", "contents", "encryption"}
TOP_KEYS = {"format", "formatVersion", "header", "ciphertext"}
HEX64 = re.compile(r"^[0-9a-f]{64}$")
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

SCHEMA = """
CREATE TABLE IF NOT EXISTS solutions (
    id TEXT PRIMARY KEY,                 -- solutionId aus dem Paketkopf (UUID)
    fingerprint TEXT NOT NULL,           -- SHA-256 der Original-PDF
    university TEXT NOT NULL,
    author_id TEXT NOT NULL,             -- Konto-ID (intern), nach aussen nur das Pseudonym
    pseudonym TEXT NOT NULL,
    display_name TEXT NOT NULL,
    title TEXT,
    created_at TEXT NOT NULL,            -- aus dem Kopf
    published_at TEXT NOT NULL,
    page_count INTEGER NOT NULL,         -- Seiten der PDF
    pages INTEGER NOT NULL,              -- geteilte Seiten
    size INTEGER NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',   -- active | withdrawn | hidden | removed
    status_reason TEXT,
    downloads INTEGER NOT NULL DEFAULT 0,
    report_count INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_solutions_fp ON solutions(fingerprint, status);
CREATE INDEX IF NOT EXISTS idx_solutions_author ON solutions(author_id);
CREATE TABLE IF NOT EXISTS reports (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    solution_id TEXT NOT NULL REFERENCES solutions(id),
    reporter_id TEXT NOT NULL,
    reason TEXT NOT NULL,
    note TEXT,
    created_at TEXT NOT NULL,
    UNIQUE (solution_id, reporter_id)
);
CREATE TABLE IF NOT EXISTS blocks (
    user_id TEXT NOT NULL,
    pseudonym TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (user_id, pseudonym)
);
CREATE TABLE IF NOT EXISTS bans (
    author_id TEXT PRIMARY KEY,
    created_at TEXT NOT NULL,
    reason TEXT
);
-- Likes, Kommentare, Besitzmeldungen der Geraete (28.10.2026)
CREATE TABLE IF NOT EXISTS likes (
    solution_id TEXT NOT NULL REFERENCES solutions(id),
    user_id TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (solution_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_likes_user ON likes(user_id);
CREATE TABLE IF NOT EXISTS comments (
    id TEXT PRIMARY KEY,                 -- UUID
    solution_id TEXT NOT NULL REFERENCES solutions(id),
    author_id TEXT NOT NULL,
    pseudonym TEXT NOT NULL,
    parent_id TEXT,                      -- Antwort auf einen Kommentar (eine Ebene)
    page_key TEXT,                       -- Seite der Loesung (pages[].key, z. B. "p3"), NULL = zur ganzen Loesung
    anchor_x REAL, anchor_y REAL,        -- Stelle auf der Seite, 0..1 von links oben (wie ein Kommentar in Word)
    text TEXT NOT NULL,
    created_at TEXT NOT NULL,
    edited_at TEXT,
    status TEXT NOT NULL DEFAULT 'active',   -- active | deleted | hidden
    report_count INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_comments_solution ON comments(solution_id, created_at);
CREATE TABLE IF NOT EXISTS comment_reports (
    comment_id TEXT NOT NULL REFERENCES comments(id),
    reporter_id TEXT NOT NULL,
    reason TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (comment_id, reporter_id)
);
CREATE TABLE IF NOT EXISTS claims (
    user_id TEXT NOT NULL,
    fingerprint TEXT NOT NULL,           -- SHA-256 einer PDF aus dem Hochschul-Abgleich des Geraets
    university TEXT NOT NULL,
    claimed_at TEXT NOT NULL,
    PRIMARY KEY (user_id, fingerprint)
);
"""


class CommunityError(ValueError):
    def __init__(self, code: str, message: str, status: int = 400):
        super().__init__(message)
        self.code, self.message, self.status = code, message, status


def _now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def db_path() -> Path:
    return config.BASE_DATA_DIR / "community.db"


def package_dir() -> Path:
    return config.BASE_DATA_DIR / "community"


@contextmanager
def cursor():
    p = db_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(p, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    db.schema_once(conn, "community", p, lambda c: c.executescript(SCHEMA))
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


# ---------------------------------------------------------------- Pseudonym, Tarif, Berechtigung

def pseudonym(user_id: str) -> str:
    """Stabil je Konto, nicht umkehrbar (HMAC mit dem Dienst-Geheimnis)."""
    from . import vault
    mac = hmac.new(vault.master_key(), b"community-pseudonym:" + user_id.encode("ascii"), hashlib.sha256).hexdigest()
    return "Studi-" + mac[:8]


def plan_ok(user: dict) -> bool:
    """Darf Loesungen teilen (Recht can_share_solutions, ab Studora Plus). Lesen duerfen alle Konten (Free)."""
    from . import entitlements
    return entitlements.has(user, "can_share_solutions")


def require_plan(user: dict) -> None:
    if not plan_ok(user):
        raise CommunityError("plan_required", "Eigene Lösungen teilen gibt es ab Studora Plus.", 403)


def owns_file(fingerprint: str, user_id: str | None = None) -> bool:
    """Die Datei mit diesem Fingerabdruck stammt aus dem eigenen Hochschul-Abgleich: in der Datenbank des Kontos
    (Abgleich im Dienst) oder von einem Geraet des Kontos gemeldet (`claim_files`, Windows-App und iPad gleichen auf
    dem Geraet ab, 28.10.2026). Die Meldung ist eine Angabe des Geraets; wer die PDF nicht hat, kann ein Paket trotzdem
    nicht oeffnen (Schluessel aus der Original-PDF), sieht aber Titel, Pseudonyme und Kommentare."""
    with db.cursor() as conn:
        if db.row(conn, """SELECT 1 FROM files WHERE content_sha256=? AND course_id<>'__user__'
                           AND download_url IS NOT NULL AND download_url<>'' AND deleted_at IS NULL""", (fingerprint,)):
            return True
    uid = user_id or config.current_user_id()
    if not uid:
        return False
    with cursor() as conn:
        return bool(conn.execute("SELECT 1 FROM claims WHERE user_id=? AND fingerprint=? AND university=?",
                                 (uid, fingerprint, config.university())).fetchone())


MAX_CLAIMS = 5_000                      # je Meldung; ein Semester hat selten mehr als einige hundert PDFs


def claim_files(user: dict, university: str, fingerprints: list, replace: bool = False) -> dict:
    """Geraet meldet die Fingerabdruecke seiner PDFs aus dem Hochschul-Abgleich. `replace`: alle bisherigen Meldungen
    des Kontos fuer diese Hochschule ersetzen (voller Abgleich), sonst ergaenzen."""
    if not isinstance(fingerprints, list) or len(fingerprints) > MAX_CLAIMS:
        raise CommunityError("claims_invalid", f"Höchstens {MAX_CLAIMS} Fingerabdrücke je Meldung.")
    fps = sorted({str(f).lower() for f in fingerprints if HEX64.match(str(f).lower())})
    now = _now()
    with cursor() as conn:
        if replace:
            conn.execute("DELETE FROM claims WHERE user_id=? AND university=?", (user["id"], university))
        conn.executemany("INSERT OR REPLACE INTO claims(user_id, fingerprint, university, claimed_at) VALUES (?,?,?,?)",
                         [(user["id"], f, university, now) for f in fps])
        n = conn.execute("SELECT COUNT(*) FROM claims WHERE user_id=? AND university=?", (user["id"], university)).fetchone()[0]
    return {"accepted": len(fps), "ignored": len(fingerprints) - len(fps), "total": n}


def require_file(fingerprint: str, user_id: str | None = None) -> None:
    if not HEX64.match(fingerprint or ""):
        raise CommunityError("fingerprint_invalid", "Ungültiger Fingerabdruck.")
    if not owns_file(fingerprint, user_id):
        raise CommunityError("file_not_owned", "Diese PDF stammt nicht aus deinem Hochschul-Abgleich.", 403)


# ---------------------------------------------------------------- Paket pruefen (nur der Kopf; Inhalt bleibt verschluesselt)

def _b64len(s: str, what: str) -> int:
    try:
        return len(base64.b64decode(s, validate=True))
    except (ValueError, TypeError):
        raise CommunityError("package_invalid", f"Die Lösung ist beschädigt (Kopf: {what}).")


def validate_package(pkg) -> dict:
    """Prueft Form und Kopf wie SolutionPackage.decode (ohne Entschluesselung). Liefert die Kopfdaten fuer die Ablage."""
    def bad(what: str):
        raise CommunityError("package_invalid", f"Die Lösung ist beschädigt (Kopf: {what}).")
    if not isinstance(pkg, dict) or pkg.get("format") != FORMAT:
        raise CommunityError("not_a_solution", "Die Datei ist keine UniFlow-Lösung.")
    if set(pkg) != TOP_KEYS:
        bad("Felder")
    v = pkg.get("formatVersion")
    if not isinstance(v, int) or isinstance(v, bool):
        bad("Formatversion")
    if v != FORMAT_VERSION:
        raise CommunityError("unsupported_version", f"Diese Lösung hat Formatversion {v} – bitte UniFlow aktualisieren.")
    h = pkg.get("header")
    if not isinstance(h, dict) or set(h) != HEADER_KEYS:
        bad("Kopf")
    sid = h.get("solutionId")
    if not isinstance(sid, str) or not UUID_RE.match(sid):
        bad("solutionId")
    created = h.get("createdAt")
    try:
        datetime.fromisoformat(str(created).replace("Z", "+00:00"))
    except ValueError:
        bad("createdAt")
    name = h.get("displayName")
    if not isinstance(name, str) or len(name) > MAX_DISPLAY_NAME:
        bad("displayName")
    doc = h.get("document")
    if not isinstance(doc, dict) or set(doc) != {"sha256", "pageCount"}:
        bad("document")
    fp = doc.get("sha256")
    if not isinstance(fp, str) or not HEX64.match(fp):
        bad("sha256")
    pc = doc.get("pageCount")
    if not isinstance(pc, int) or isinstance(pc, bool) or not (1 <= pc <= 100_000):
        bad("pageCount")
    c = h.get("contents")
    if not isinstance(c, dict) or set(c) != {"pages", "images", "missingImages"}:
        bad("contents")
    pages = c.get("pages")
    if not isinstance(pages, int) or isinstance(pages, bool) or not (1 <= pages <= MAX_PAGES):
        raise CommunityError("package_invalid", "Die Lösung ist beschädigt (Kopf: pages)." if isinstance(pages, int) and pages > 0 else
                             "Eine Lösung ohne eigene Notizen lässt sich nicht veröffentlichen.")
    for k in ("images", "missingImages"):
        if not isinstance(c.get(k), int) or isinstance(c.get(k), bool) or c[k] < 0:
            bad(k)
    e = h.get("encryption")
    if not isinstance(e, dict) or set(e) != {"cipher", "kdf", "keyMaterial", "salt", "nonce", "plaintextBytes"}:
        bad("encryption")
    if e.get("cipher") != "AES-256-GCM" or e.get("kdf") != "HKDF-SHA256" or e.get("keyMaterial") != "original-pdf-bytes":
        bad("Verschlüsselung")
    if _b64len(str(e.get("salt")), "salt") != 32 or _b64len(str(e.get("nonce")), "nonce") != 12:
        bad("Salz/Nonce")
    ct = pkg.get("ciphertext")
    if not isinstance(ct, str) or len(ct) > MAX_PACKAGE_BYTES:
        raise CommunityError("too_large", "Die Lösung ist zu groß.", 413)
    n = _b64len(ct, "ciphertext")
    pb = e.get("plaintextBytes")
    if not isinstance(pb, int) or isinstance(pb, bool) or pb < 0 or pb != n - 16:
        bad("plaintextBytes")
    return {"id": sid.lower(), "fingerprint": fp, "display_name": name, "created_at": created, "page_count": pc, "pages": pages}


# ---------------------------------------------------------------- Veroeffentlichen, Suchen, Laden, Zurueckziehen

def _summary(r, me: str, reported: set[str] | None = None, conn=None) -> dict:
    out = {"solution_id": r["id"], "fingerprint": r["fingerprint"], "display_name": r["display_name"], "pseudonym": r["pseudonym"],
           "title": r["title"], "created_at": r["created_at"], "published_at": r["published_at"], "page_count": r["page_count"],
           "pages": r["pages"], "downloads": r["downloads"], "status": r["status"], "mine": r["author_id"] == me,
           "reported_by_me": r["id"] in (reported or set())}
    if conn is not None:
        out["likes"] = conn.execute("SELECT COUNT(*) FROM likes WHERE solution_id=?", (r["id"],)).fetchone()[0]
        out["liked_by_me"] = bool(conn.execute("SELECT 1 FROM likes WHERE solution_id=? AND user_id=?", (r["id"], me)).fetchone())
        out["comments"] = conn.execute("SELECT COUNT(*) FROM comments WHERE solution_id=? AND status='active'", (r["id"],)).fetchone()[0]
    return out


def publish(user: dict, university: str, pkg, title: str | None = None) -> dict:
    require_plan(user)
    info = validate_package(pkg)
    require_file(info["fingerprint"])
    title = (title or "").strip()[:MAX_TITLE] or None
    raw = json.dumps(pkg, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    if len(raw) > MAX_PACKAGE_BYTES:
        raise CommunityError("too_large", "Die Lösung ist zu groß.", 413)
    with cursor() as conn:
        if conn.execute("SELECT 1 FROM bans WHERE author_id=?", (user["id"],)).fetchone():
            raise CommunityError("author_banned", "Dein Konto darf keine Lösungen mehr veröffentlichen.", 403)
        cur = conn.execute("SELECT author_id, status FROM solutions WHERE id=?", (info["id"],)).fetchone()
        if cur and cur["author_id"] != user["id"]:
            raise CommunityError("solution_exists", "Diese Lösung wurde schon von einem anderen Konto veröffentlicht.", 409)
        if cur and cur["status"] in ("hidden", "removed"):
            raise CommunityError("solution_blocked", "Diese Lösung ist gesperrt und kann nicht erneut veröffentlicht werden.", 403)
        now = _now()
        package_dir().mkdir(parents=True, exist_ok=True)
        (package_dir() / f"{info['id']}.uniflowsolution").write_text(raw, encoding="utf-8")
        conn.execute("""INSERT INTO solutions(id, fingerprint, university, author_id, pseudonym, display_name, title, created_at, published_at,
                        page_count, pages, size, status) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,'active')
                        ON CONFLICT(id) DO UPDATE SET fingerprint=excluded.fingerprint, display_name=excluded.display_name, title=COALESCE(excluded.title, solutions.title),
                          created_at=excluded.created_at, published_at=excluded.published_at, page_count=excluded.page_count,
                          pages=excluded.pages, size=excluded.size, status='active', status_reason=NULL""",
                     (info["id"], info["fingerprint"], university, user["id"], pseudonym(user["id"]), info["display_name"], title,
                      info["created_at"], now, info["page_count"], info["pages"], len(raw)))
    return {"solution_id": info["id"], "published_at": now, "pseudonym": pseudonym(user["id"]), "republished": bool(cur)}


def find(user: dict, university: str, fingerprint: str) -> list[dict]:
    # Lesen duerfen alle Konten (Recht can_read_community, auch Studora Free); weiter nur fuer die eigene PDF
    require_file(fingerprint)
    with cursor() as conn:
        blocked = {r["pseudonym"] for r in conn.execute("SELECT pseudonym FROM blocks WHERE user_id=?", (user["id"],))}
        banned = {r["author_id"] for r in conn.execute("SELECT author_id FROM bans")}
        reported = {r["solution_id"] for r in conn.execute("SELECT solution_id FROM reports WHERE reporter_id=?", (user["id"],))}
        rows = conn.execute("SELECT * FROM solutions WHERE fingerprint=? AND university=? AND status='active' ORDER BY published_at DESC",
                            (fingerprint, university)).fetchall()
        out = [_summary(r, user["id"], reported, conn) for r in rows if r["pseudonym"] not in blocked and r["author_id"] not in banned]
    # meistgelikte zuerst, bei Gleichstand die neueste
    out.sort(key=lambda x: x["published_at"], reverse=True)
    out.sort(key=lambda x: -x["likes"])
    return out


def get_package(user: dict, solution_id: str) -> tuple[dict, dict]:
    with cursor() as conn:
        r = conn.execute("SELECT * FROM solutions WHERE id=?", (solution_id.lower(),)).fetchone()
        if not r or (r["status"] != "active" and r["author_id"] != user["id"]):
            raise CommunityError("not_found", "Lösung nicht gefunden.", 404)
        if conn.execute("SELECT 1 FROM bans WHERE author_id=?", (r["author_id"],)).fetchone() and r["author_id"] != user["id"]:
            raise CommunityError("not_found", "Lösung nicht gefunden.", 404)
        if r["author_id"] != user["id"]:
            require_file(r["fingerprint"])
            conn.execute("UPDATE solutions SET downloads=downloads+1 WHERE id=?", (r["id"],))
        p = package_dir() / f"{r['id']}.uniflowsolution"
        if not p.exists():
            raise CommunityError("not_found", "Lösung nicht gefunden.", 404)
        return json.loads(p.read_text(encoding="utf-8")), _summary(r, user["id"], None, conn)


def mine(user: dict) -> list[dict]:
    with cursor() as conn:
        rows = conn.execute("SELECT * FROM solutions WHERE author_id=? ORDER BY published_at DESC", (user["id"],)).fetchall()
        return [_summary(r, user["id"], None, conn) for r in rows]


def withdraw_all(author_id: str, reason: str) -> int:
    """Alle Loesungen eines Kontos zurueckziehen (Konto geloescht): nicht mehr sichtbar, Pakete weg."""
    with cursor() as conn:
        rows = conn.execute("SELECT id FROM solutions WHERE author_id=? AND status IN ('active','hidden')", (author_id,)).fetchall()
        conn.execute("UPDATE solutions SET status='withdrawn', status_reason=? WHERE author_id=? AND status IN ('active','hidden')",
                     (reason, author_id))
    for r in rows:
        (package_dir() / f"{r['id']}.uniflowsolution").unlink(missing_ok=True)
    return len(rows)


def forget_author(user_id: str) -> int:
    """Konto endgueltig geloescht: Loesungen samt Paketen und Meldungen dazu, eigene Meldungen, Sperrliste und
    Bann-Eintrag entfernen. Liefert die Zahl der entfernten Loesungen."""
    with cursor() as conn:
        ids = [r[0] for r in conn.execute("SELECT id FROM solutions WHERE author_id=?", (user_id,))]
        for sid in ids:
            conn.execute("DELETE FROM reports WHERE solution_id=?", (sid,))
            conn.execute("DELETE FROM likes WHERE solution_id=?", (sid,))
            conn.execute("DELETE FROM comment_reports WHERE comment_id IN (SELECT id FROM comments WHERE solution_id=?)", (sid,))
            conn.execute("DELETE FROM comments WHERE solution_id=?", (sid,))
            conn.execute("DELETE FROM solutions WHERE id=?", (sid,))
        conn.execute("DELETE FROM likes WHERE user_id=?", (user_id,))
        conn.execute("DELETE FROM comment_reports WHERE reporter_id=? OR comment_id IN (SELECT id FROM comments WHERE author_id=?)", (user_id, user_id))
        conn.execute("DELETE FROM comments WHERE author_id=?", (user_id,))
        conn.execute("DELETE FROM claims WHERE user_id=?", (user_id,))
        conn.execute("DELETE FROM reports WHERE reporter_id=?", (user_id,))
        conn.execute("DELETE FROM blocks WHERE user_id=?", (user_id,))
        conn.execute("DELETE FROM bans WHERE author_id=?", (user_id,))
    for sid in ids:
        (package_dir() / f"{sid}.uniflowsolution").unlink(missing_ok=True)
    return len(ids)


def withdraw(user: dict, solution_id: str) -> dict:
    with cursor() as conn:
        r = conn.execute("SELECT * FROM solutions WHERE id=?", (solution_id.lower(),)).fetchone()
        if not r:
            raise CommunityError("not_found", "Lösung nicht gefunden.", 404)
        if r["author_id"] != user["id"]:
            raise CommunityError("not_owner", "Nur der Autor kann eine Lösung zurückziehen.", 403)
        if r["status"] == "withdrawn":
            return {"withdrawn": True, "already": True}
        conn.execute("UPDATE solutions SET status='withdrawn', status_reason=NULL WHERE id=?", (r["id"],))
        (package_dir() / f"{r['id']}.uniflowsolution").unlink(missing_ok=True)
    return {"withdrawn": True, "already": False}


# ---------------------------------------------------------------- Melden, Sperren, Moderation

def report(user: dict, solution_id: str, reason: str, note: str | None) -> dict:
    if reason not in REPORT_REASONS:
        raise CommunityError("reason_invalid", "Unbekannter Meldegrund.")
    with cursor() as conn:
        r = conn.execute("SELECT * FROM solutions WHERE id=?", (solution_id.lower(),)).fetchone()
        if not r or r["status"] not in ("active", "hidden"):
            raise CommunityError("not_found", "Lösung nicht gefunden.", 404)
        if r["author_id"] == user["id"]:
            raise CommunityError("own_solution", "Die eigene Lösung lässt sich nicht melden, aber zurückziehen.")
        if conn.execute("SELECT 1 FROM reports WHERE solution_id=? AND reporter_id=?", (r["id"], user["id"])).fetchone():
            raise CommunityError("already_reported", "Du hast diese Lösung schon gemeldet.", 409)
        conn.execute("INSERT INTO reports(solution_id, reporter_id, reason, note, created_at) VALUES (?,?,?,?,?)",
                     (r["id"], user["id"], reason, (note or "")[:500] or None, _now()))
        n = conn.execute("SELECT COUNT(*) FROM reports WHERE solution_id=?", (r["id"],)).fetchone()[0]
        hidden = r["status"] == "hidden"
        if n >= REPORTS_TO_HIDE and r["status"] == "active":
            conn.execute("UPDATE solutions SET status='hidden', status_reason='reports', report_count=? WHERE id=?", (n, r["id"]))
            hidden = True
        else:
            conn.execute("UPDATE solutions SET report_count=? WHERE id=?", (n, r["id"]))
    return {"reported": True, "hidden": hidden, "reports": n}


def block(user: dict, solution_id: str) -> dict:
    with cursor() as conn:
        r = conn.execute("SELECT pseudonym, author_id FROM solutions WHERE id=?", (solution_id.lower(),)).fetchone()
        if not r:
            raise CommunityError("not_found", "Lösung nicht gefunden.", 404)
        if r["author_id"] == user["id"]:
            raise CommunityError("own_solution", "Du kannst dich nicht selbst sperren.")
        conn.execute("INSERT OR IGNORE INTO blocks(user_id, pseudonym, created_at) VALUES (?,?,?)", (user["id"], r["pseudonym"], _now()))
    return {"blocked": r["pseudonym"]}


def unblock(user: dict, pseudonym_: str) -> dict:
    with cursor() as conn:
        n = conn.execute("DELETE FROM blocks WHERE user_id=? AND pseudonym=?", (user["id"], pseudonym_)).rowcount
    if not n:
        raise CommunityError("not_found", "Nicht gesperrt.", 404)
    return {"unblocked": pseudonym_}


def blocks(user: dict) -> list[str]:
    with cursor() as conn:
        return [r["pseudonym"] for r in conn.execute("SELECT pseudonym FROM blocks WHERE user_id=? ORDER BY created_at", (user["id"],))]


def require_admin(user: dict) -> None:
    if user.get("role") != "admin":
        raise CommunityError("forbidden", "Nur für Moderation.", 403)


def moderation_queue(user: dict) -> list[dict]:
    require_admin(user)
    with cursor() as conn:
        rows = conn.execute("SELECT * FROM solutions WHERE report_count>0 OR status IN ('hidden','removed') ORDER BY status='hidden' DESC, report_count DESC, published_at DESC").fetchall()
        out = []
        for r in rows:
            reps = [{"reason": x["reason"], "note": x["note"], "created_at": x["created_at"]}
                    for x in conn.execute("SELECT reason, note, created_at FROM reports WHERE solution_id=? ORDER BY id", (r["id"],))]
            s = _summary(r, user["id"])
            s["reports"] = reps
            s["author_banned"] = bool(conn.execute("SELECT 1 FROM bans WHERE author_id=?", (r["author_id"],)).fetchone())
            out.append(s)
    return out


def moderate(user: dict, solution_id: str, action: str, reason: str | None = None) -> dict:
    require_admin(user)
    with cursor() as conn:
        r = conn.execute("SELECT * FROM solutions WHERE id=?", (solution_id.lower(),)).fetchone()
        if not r:
            raise CommunityError("not_found", "Lösung nicht gefunden.", 404)
        if action == "hide":
            conn.execute("UPDATE solutions SET status='hidden', status_reason=? WHERE id=?", (reason or "moderation", r["id"]))
        elif action == "restore":
            conn.execute("UPDATE solutions SET status='active', status_reason=NULL WHERE id=? AND status IN ('hidden','removed')", (r["id"],))
            conn.execute("DELETE FROM reports WHERE solution_id=?", (r["id"],))
            conn.execute("UPDATE solutions SET report_count=0 WHERE id=?", (r["id"],))
        elif action == "remove":
            conn.execute("UPDATE solutions SET status='removed', status_reason=? WHERE id=?", (reason or "moderation", r["id"]))
            (package_dir() / f"{r['id']}.uniflowsolution").unlink(missing_ok=True)
        elif action == "ban_author":
            conn.execute("INSERT OR IGNORE INTO bans(author_id, created_at, reason) VALUES (?,?,?)", (r["author_id"], _now(), reason))
            conn.execute("UPDATE solutions SET status='removed', status_reason='ban' WHERE author_id=? AND status IN ('active','hidden')", (r["author_id"],))
            for x in conn.execute("SELECT id FROM solutions WHERE author_id=?", (r["author_id"],)):
                (package_dir() / f"{x['id']}.uniflowsolution").unlink(missing_ok=True)
        elif action == "unban_author":
            conn.execute("DELETE FROM bans WHERE author_id=?", (r["author_id"],))
        else:
            raise CommunityError("action_invalid", "Unbekannte Aktion.")
        s = _summary(conn.execute("SELECT * FROM solutions WHERE id=?", (r["id"],)).fetchone(), user["id"])
    return {"action": action, "solution": s}


# ---------------------------------------------------------------- Likes, Kommentare, Rangliste (28.10.2026)

MAX_COMMENT = 2_000


def _visible_solution(conn, user: dict, solution_id: str):
    """Loesung, die dieses Konto sehen darf (aktiv, Autor nicht gebannt, PDF im eigenen Abgleich) oder die eigene."""
    r = conn.execute("SELECT * FROM solutions WHERE id=?", ((solution_id or "").lower(),)).fetchone()
    if not r or (r["status"] != "active" and r["author_id"] != user["id"]):
        raise CommunityError("not_found", "Lösung nicht gefunden.", 404)
    if r["author_id"] != user["id"]:
        if conn.execute("SELECT 1 FROM bans WHERE author_id=?", (r["author_id"],)).fetchone():
            raise CommunityError("not_found", "Lösung nicht gefunden.", 404)
        require_file(r["fingerprint"], user["id"])
    return r


def _require_verified(user: dict, what: str) -> None:
    if config.is_hosted() and not user.get("email_verified"):
        raise CommunityError("email_unverified", f"Bitte bestätige zuerst deine E-Mail-Adresse, um zu {what}.", 403)


def _limit(name: str, user_id: str) -> None:
    try:
        accounts.hit_limit(name, user_id)
    except accounts.AccountError as e:
        raise CommunityError(e.code, e.message, e.status) from e


def like(user: dict, solution_id: str, on: bool = True) -> dict:
    """Gefaellt mir setzen oder entfernen; nicht fuer die eigene Loesung, idempotent."""
    _require_verified(user, "Lösungen zu liken")
    with cursor() as conn:
        r = _visible_solution(conn, user, solution_id)
        if r["author_id"] == user["id"]:
            raise CommunityError("own_solution", "Die eigene Lösung lässt sich nicht liken.")
        if on:
            if not conn.execute("SELECT 1 FROM likes WHERE solution_id=? AND user_id=?", (r["id"], user["id"])).fetchone():
                _limit("like_user", user["id"])
                conn.execute("INSERT OR IGNORE INTO likes(solution_id, user_id, created_at) VALUES (?,?,?)", (r["id"], user["id"], _now()))
        else:
            conn.execute("DELETE FROM likes WHERE solution_id=? AND user_id=?", (r["id"], user["id"]))
        n = conn.execute("SELECT COUNT(*) FROM likes WHERE solution_id=?", (r["id"],)).fetchone()[0]
    return {"solution_id": r["id"], "liked": on, "likes": n}


def _comment_out(c, me: str, author_of_solution: str) -> dict:
    deleted = c["status"] == "deleted"
    return {"id": c["id"], "solution_id": c["solution_id"], "parent_id": c["parent_id"], "pseudonym": c["pseudonym"],
            "page_key": c["page_key"], "anchor": ({"x": c["anchor_x"], "y": c["anchor_y"]} if c["anchor_x"] is not None else None),
            "text": "" if deleted else c["text"], "deleted": deleted, "created_at": c["created_at"], "edited_at": c["edited_at"],
            "mine": c["author_id"] == me, "by_author": c["author_id"] == author_of_solution}


def comments(user: dict, solution_id: str) -> list[dict]:
    """Kommentare einer Loesung in Reihenfolge (Antworten direkt unter ihrem Kommentar); ohne verborgene und ohne
    Kommentare von Autoren, die ich gesperrt habe. Geloeschte mit Antworten bleiben als „Kommentar gelöscht“ stehen."""
    with cursor() as conn:
        r = _visible_solution(conn, user, solution_id)
        blocked = {x["pseudonym"] for x in conn.execute("SELECT pseudonym FROM blocks WHERE user_id=?", (user["id"],))}
        rows = conn.execute("SELECT * FROM comments WHERE solution_id=? AND status IN ('active','deleted') ORDER BY created_at, rowid",
                            (r["id"],)).fetchall()
    rows = [c for c in rows if c["pseudonym"] not in blocked]
    has_reply = {c["parent_id"] for c in rows if c["parent_id"] and c["status"] == "active"}
    top = [c for c in rows if not c["parent_id"] and (c["status"] == "active" or c["id"] in has_reply)]
    out = []
    for t in top:
        out.append(_comment_out(t, user["id"], r["author_id"]))
        out += [_comment_out(c, user["id"], r["author_id"]) for c in rows if c["parent_id"] == t["id"] and c["status"] == "active"]
    return out


def _anchor(page_key, anchor) -> tuple[str | None, float | None, float | None]:
    pk = (str(page_key)[:40] if page_key else None) or None
    if anchor is None:
        return pk, None, None
    try:
        x, y = float(anchor.get("x")), float(anchor.get("y"))
    except (AttributeError, TypeError, ValueError):
        raise CommunityError("anchor_invalid", "Ungültige Stelle (x und y zwischen 0 und 1).")
    if not (0 <= x <= 1 and 0 <= y <= 1) or not pk:
        raise CommunityError("anchor_invalid", "Ungültige Stelle (x und y zwischen 0 und 1, dazu die Seite).")
    return pk, x, y


def add_comment(user: dict, solution_id: str, text: str, parent_id: str | None = None, page_key=None, anchor=None) -> dict:
    from . import entitlements
    if not entitlements.has(user, "can_write_community_comments"):
        raise CommunityError("plan_required", "Kommentieren gibt es ab Studora Plus.", 403)
    _require_verified(user, "zu kommentieren")
    text = (text or "").strip()
    if not text:
        raise CommunityError("text_empty", "Der Kommentar ist leer.")
    if len(text) > MAX_COMMENT:
        raise CommunityError("text_too_long", f"Höchstens {MAX_COMMENT} Zeichen.")
    pk, ax, ay = _anchor(page_key, anchor)
    with cursor() as conn:
        r = _visible_solution(conn, user, solution_id)
        if conn.execute("SELECT 1 FROM bans WHERE author_id=?", (user["id"],)).fetchone():
            raise CommunityError("author_banned", "Dein Konto darf nicht mehr kommentieren.", 403)
        if parent_id:
            p = conn.execute("SELECT * FROM comments WHERE id=? AND solution_id=?", (str(parent_id), r["id"])).fetchone()
            if not p or p["status"] == "hidden":
                raise CommunityError("parent_invalid", "Der Kommentar, auf den du antwortest, gibt es nicht.")
            parent_id = p["parent_id"] or p["id"]            # eine Ebene: Antwort auf eine Antwort haengt am ersten
            if pk is None:
                pk, ax, ay = p["page_key"], p["anchor_x"], p["anchor_y"]
        _limit("comment_user", user["id"])
        cid, now = str(uuid.uuid4()), _now()
        conn.execute("""INSERT INTO comments(id, solution_id, author_id, pseudonym, parent_id, page_key, anchor_x, anchor_y, text, created_at)
                        VALUES (?,?,?,?,?,?,?,?,?,?)""", (cid, r["id"], user["id"], pseudonym(user["id"]), parent_id, pk, ax, ay, text, now))
        c = conn.execute("SELECT * FROM comments WHERE id=?", (cid,)).fetchone()
        return _comment_out(c, user["id"], r["author_id"])


def _own_comment(conn, user: dict, comment_id: str, allow_solution_author: bool = False):
    c = conn.execute("SELECT c.*, s.author_id AS solution_author FROM comments c JOIN solutions s ON s.id=c.solution_id WHERE c.id=?",
                     (comment_id,)).fetchone()
    if not c or c["status"] != "active":
        raise CommunityError("not_found", "Kommentar nicht gefunden.", 404)
    if c["author_id"] != user["id"] and not (allow_solution_author and c["solution_author"] == user["id"]) and user.get("role") != "admin":
        raise CommunityError("not_owner", "Nur der Verfasser kann das.", 403)
    return c


def edit_comment(user: dict, comment_id: str, text: str) -> dict:
    text = (text or "").strip()
    if not text or len(text) > MAX_COMMENT:
        raise CommunityError("text_empty" if not text else "text_too_long", "Kommentar leer oder zu lang.")
    with cursor() as conn:
        c = _own_comment(conn, user, comment_id)
        if c["author_id"] != user["id"]:
            raise CommunityError("not_owner", "Nur der Verfasser kann seinen Kommentar ändern.", 403)
        conn.execute("UPDATE comments SET text=?, edited_at=? WHERE id=?", (text, _now(), c["id"]))
        c2 = conn.execute("SELECT * FROM comments WHERE id=?", (c["id"],)).fetchone()
        return _comment_out(c2, user["id"], c["solution_author"])


def delete_comment(user: dict, comment_id: str) -> dict:
    """Eigenen Kommentar loeschen; der Autor der Loesung und die Moderation duerfen Kommentare unter einer Loesung
    ebenfalls entfernen. Der Text ist danach weg."""
    with cursor() as conn:
        c = _own_comment(conn, user, comment_id, allow_solution_author=True)
        conn.execute("UPDATE comments SET status='deleted', text='', edited_at=? WHERE id=?", (_now(), c["id"]))
    return {"deleted": True, "id": comment_id}


def report_comment(user: dict, comment_id: str, reason: str) -> dict:
    if reason not in REPORT_REASONS:
        raise CommunityError("reason_invalid", "Unbekannter Meldegrund.")
    with cursor() as conn:
        c = conn.execute("SELECT * FROM comments WHERE id=? AND status='active'", (comment_id,)).fetchone()
        if not c:
            raise CommunityError("not_found", "Kommentar nicht gefunden.", 404)
        if c["author_id"] == user["id"]:
            raise CommunityError("own_comment", "Den eigenen Kommentar kannst du löschen statt melden.")
        try:
            conn.execute("INSERT INTO comment_reports(comment_id, reporter_id, reason, created_at) VALUES (?,?,?,?)",
                         (c["id"], user["id"], reason, _now()))
        except sqlite3.IntegrityError:
            raise CommunityError("already_reported", "Du hast diesen Kommentar schon gemeldet.", 409)
        n = conn.execute("SELECT COUNT(*) FROM comment_reports WHERE comment_id=?", (c["id"],)).fetchone()[0]
        hidden = n >= REPORTS_TO_HIDE
        conn.execute("UPDATE comments SET report_count=?, status=? WHERE id=?", (n, "hidden" if hidden else "active", c["id"]))
    return {"reported": True, "hidden": hidden, "reports": n}


def leaderboard(user: dict, limit: int = 50) -> list[dict]:
    """Nur fuer den Inhaber (Rolle admin): Autoren nach erhaltenen Likes, mit Konto (E-Mail) und Kennzahlen.
    Oeffentlich sieht niemand, wer hinter einem Pseudonym steht."""
    require_admin(user)
    limit = max(1, min(int(limit or 50), 500))
    with cursor() as conn:
        rows = conn.execute("""
            SELECT s.author_id, s.pseudonym,
                   (SELECT COUNT(*) FROM likes l JOIN solutions s2 ON s2.id=l.solution_id WHERE s2.author_id=s.author_id) AS likes,
                   COUNT(DISTINCT s.id) AS solutions, SUM(s.downloads) AS downloads,
                   (SELECT COUNT(*) FROM comments c JOIN solutions s3 ON s3.id=c.solution_id
                     WHERE s3.author_id=s.author_id AND c.status='active' AND c.author_id<>s.author_id) AS comments_received,
                   MAX(s.published_at) AS last_published
            FROM solutions s WHERE s.status IN ('active','hidden') GROUP BY s.author_id, s.pseudonym
            ORDER BY likes DESC, solutions DESC, last_published DESC LIMIT ?""", (limit,)).fetchall()
    emails = {}
    with accounts.cursor() as conn:
        for r in rows:
            u = conn.execute("SELECT email, university, status FROM users WHERE id=?", (r["author_id"],)).fetchone()
            emails[r["author_id"]] = dict(u) if u else {"email": None, "university": None, "status": "deleted"}
    return [{"rank": i + 1, "pseudonym": r["pseudonym"], "email": emails[r["author_id"]]["email"],
             "university": emails[r["author_id"]]["university"], "account_status": emails[r["author_id"]]["status"],
             "likes": r["likes"], "solutions": r["solutions"], "downloads": r["downloads"] or 0,
             "comments_received": r["comments_received"], "last_published": r["last_published"]} for i, r in enumerate(rows)]


def info(user: dict | None) -> dict:
    return {"enabled": config.is_hosted(), "plan_required": "plus", "plan_ok": bool(user and plan_ok(user)),
            "can_read": True, "can_share": bool(user and plan_ok(user)),
            "reasons": list(REPORT_REASONS), "reports_to_hide": REPORTS_TO_HIDE, "format": FORMAT, "format_version": FORMAT_VERSION,
            "max_package_bytes": MAX_PACKAGE_BYTES, "pseudonym": pseudonym(user["id"]) if user else None,
            "admin": bool(user and user.get("role") == "admin"),
            "can_comment": bool(user and _can_comment(user)), "max_comment": MAX_COMMENT}


def _can_comment(user: dict) -> bool:
    from . import entitlements
    return entitlements.has(user, "can_write_community_comments")


def sample_package(fingerprint: str, pages: int = 2, page_count: int = 12, display_name: str = "", solution_id: str | None = None,
                   created_at: str = "2026-10-26T10:00:00Z") -> dict:
    """Syntaktisch gueltiges Paket fuer Tests und den Vertrag (Chiffrat ist Zufall, nicht entschluesselbar)."""
    import os
    ct = os.urandom(48)
    return {"format": FORMAT, "formatVersion": FORMAT_VERSION,
            "header": {"solutionId": solution_id or str(uuid.uuid4()), "createdAt": created_at, "displayName": display_name,
                       "document": {"sha256": fingerprint, "pageCount": page_count},
                       "contents": {"pages": pages, "images": 0, "missingImages": 0},
                       "encryption": {"cipher": "AES-256-GCM", "kdf": "HKDF-SHA256", "keyMaterial": "original-pdf-bytes",
                                      "salt": base64.b64encode(os.urandom(32)).decode(), "nonce": base64.b64encode(os.urandom(12)).decode(),
                                      "plaintextBytes": len(ct) - 16}},
            "ciphertext": base64.b64encode(ct).decode()}

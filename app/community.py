"""Community-Dienst (Vertrag G4): Loesungspakete veroeffentlichen, finden, laden, zurueckziehen, melden, sperren.

Nur im gehosteten Modus. Der Dienst bekommt ausschliesslich das verschluesselte Paket (`docs/LOESUNGEN-TEILEN.md`,
Format `uniflow-solution` Version 1). Der Dienst prueft nur den Kopf des Pakets und speichert es unveraendert.

Communities (1.11.2026): Jeder Kurs ist eine Community, dazu Lerngruppen mit Code. Beitreten kann ein Konto nur Kursen,
die ein Geraet gemeldet hat (`claim_files`, `course_keys`), und Lerngruppen, deren Schluessel es kennt. Eine Loesung
gehoert zu genau einer Community (`community_key`) und ist nur fuer deren Mitglieder sichtbar, auch ohne die PDF: Ihr
Schluessel kommt aus Kurs-ID bzw. Code (`keyMaterial` = `community-secret`). Gleicht das Geraet selbst ab, kennt der Dienst
beides nicht; bei Konten mit Hochschul-Abgleich durch den Dienst liegt die Kurs-ID in deren Datenbank, dann koennte er
die Kurs-Pakete rechnerisch oeffnen. Neu veroeffentlicht wird nur noch in eine Community.

Berechtigung: Veroeffentlichen, Suchen und Laden gibt es nur fuer Dateien aus dem eigenen Hochschul-Abgleich des
Kontos (Fingerabdruck `document.sha256` muss in der eigenen Datenbank als `files.content_sha256` einer Datei mit
Hochschul-Quelle stehen). Lesen und Schreiben brauchen den Tarif Plus (Entscheidung vom 25.10.2026).

Zentrale Ablage `community.db` und Paketdateien unter `community/` neben den Nutzerordnern. Autoren erscheinen
nur mit einem stabilen Pseudonym (HMAC aus Konto-ID und Dienst-Geheimnis), nie mit Konto-ID oder E-Mail.
Melden: eine Meldung je Konto und Loesung; ab REPORTS_TO_HIDE verschiedenen Meldungen ist die Loesung verborgen,
bis ein Admin entscheidet.
Eine Loesung je Konto, PDF und Community (03.11.2026): wer zu derselben PDF (Fingerabdruck) in derselben Community schon
eine Loesung hat, bekommt beim Veroeffentlichen 409 `already_published` mit deren `solution_id`. Der Client fuehrt dann
die Seiten zusammen (das Paket ist Ende-zu-Ende verschluesselt, der Dienst kann es nicht) und ersetzt das Paket der
eigenen Loesung mit `update` (PUT): ID, Likes, Kommentare und Sichtbarkeit bleiben, `updated_at` wird neu gesetzt.
Schon vorhandene Doppel bleiben stehen. Melden (Loesung, Kommentar, Frage, Antwort) verlangt wie Liken und Kommentieren eine
bestaetigte E-Mail-Adresse und die Sichtbarkeit des Beitrags fuer das Konto und ist je Konto und Tag begrenzt
(`report_user`); gezaehlt werden daher nur Meldungen solcher Konten, Wegwerf-Konten koennen nichts verbergen. Die
Moderation sieht je Meldung Pseudonym, Kontoalter und Bestaetigungsstand des Meldenden und kann Verborgenes wieder
freigeben. Sperren: ein Konto blendet alle Loesungen eines Pseudonyms fuer sich aus. Admin:
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
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

from . import accounts, config, db

# Version 2 (2.11.2026): Striche als ganze Zahlen, Klartext mit raw DEFLATE gepackt (app/solution_format.py). Neue
# Pakete sind immer Version 2; Version 1 bleibt gueltig (schon veroeffentlichte und alte App-Staende).
FORMAT, FORMAT_VERSION = "uniflow-solution", 2
FORMAT_VERSIONS = (1, 2)
MAX_PLAINTEXT_BYTES = 48 << 20                                       # wie SolutionLimits.maxPlaintextBytes
MAX_PACKAGE_BYTES = (MAX_PLAINTEXT_BYTES + 16 + 2) // 3 * 4 + (1 << 20)   # wie SolutionLimits.maxPackageBytes (rund 65 MB)
MAX_PAGES = 2_000
MAX_DISPLAY_NAME, MAX_TITLE = 60, 200
REPORTS_TO_HIDE = 3
# Nur fuer Tests der Regeln rund um eine Loesung (Likes, Moderation): Pakete ohne Community. Im Betrieb immer aus.
LEGACY_PUBLISH = False
KEY_MATERIALS = ("original-pdf-bytes", "community-secret")
MAX_GROUP_NAME = 60
REPORT_REASONS = ("foreignMaterial", "gradedSubmission", "offensive", "spam", "other")
HEADER_KEYS = {"solutionId", "createdAt", "displayName", "document", "contents", "encryption"}
TOP_KEYS = {"format", "formatVersion", "header", "ciphertext"}
HEX64 = re.compile(r"^[0-9a-f]{64}\Z")          # \Z statt $: kein Zeilenende am Schluss (Audit 08.11.2026, Nr. 114)
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\Z")

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
CREATE TABLE IF NOT EXISTS course_claims (
    user_id TEXT NOT NULL,
    course_key TEXT NOT NULL,            -- CommunityKeys.courseKey eines Kurses aus dem Abgleich des Geraets
    university TEXT NOT NULL,
    claimed_at TEXT NOT NULL,
    PRIMARY KEY (user_id, course_key)
);
CREATE TABLE IF NOT EXISTS community_members (
    user_id TEXT NOT NULL,
    community_key TEXT NOT NULL,         -- Kurs- oder Gruppen-Schluessel, nie Kurs-ID oder Code im Klartext
    university TEXT NOT NULL,
    kind TEXT NOT NULL,                  -- course | group
    joined_at TEXT NOT NULL,
    PRIMARY KEY (user_id, community_key)
);
CREATE INDEX IF NOT EXISTS idx_members_key ON community_members(community_key);
CREATE TABLE IF NOT EXISTS study_groups (
    group_key TEXT PRIMARY KEY,
    university TEXT NOT NULL,
    name TEXT NOT NULL,
    created_by TEXT NOT NULL,
    created_at TEXT NOT NULL
);
-- Getrennte Namensraeume (Sicherheitspruefung 3.11.2026): jeder Schluessel ist entweder Kurs/Modul oder Lerngruppe
CREATE TABLE IF NOT EXISTS community_kinds (
    community_key TEXT PRIMARY KEY,
    kind TEXT NOT NULL,                  -- course | group
    created_at TEXT NOT NULL
);
-- Erstmeldung je Konto und Kurs-/Modulschluessel (Tagesgrenze fuer neue Schluessel)
CREATE TABLE IF NOT EXISTS course_key_history (
    user_id TEXT NOT NULL,
    course_key TEXT NOT NULL,
    first_at TEXT NOT NULL,
    PRIMARY KEY (user_id, course_key)
);
"""


class CommunityError(ValueError):
    def __init__(self, code: str, message: str, status: int = 400, extra: dict | None = None):
        super().__init__(message)
        self.code, self.message, self.status = code, message, status
        self.extra = extra or {}                 # weitere Felder der Fehlerantwort (z. B. solution_id bei already_published)


def _schema(conn) -> None:
    from . import community_corrections, community_qa
    conn.executescript(SCHEMA)
    conn.executescript(community_qa.SCHEMA)
    conn.executescript(community_corrections.SCHEMA)
    db.add_column(conn, "solutions", "community_key", "TEXT")     # mehrere Prozesse zugleich (Audit P11-02)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_solutions_community ON solutions(community_key, status)")
    db.add_column(conn, "solutions", "updated_at", "TEXT")        # letztes Ersetzen des Pakets (update), sonst NULL
    conn.execute("INSERT OR IGNORE INTO community_kinds(community_key, kind, created_at) SELECT group_key, 'group', created_at FROM study_groups")


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
    # timeout = busy_timeout: community.db teilen sich ALLE Konten und alle API-Prozesse (wie accounts.db); mit den
    # 5 s Standard meldete ein Schreibstau bei Last "database is locked" (08.11.2026, Pruefung fuer 4.000 Nutzer)
    conn = sqlite3.connect(p, check_same_thread=False, timeout=15)
    conn.row_factory = sqlite3.Row
    db.wal_once(conn, p)                    # WAL nur einmal je Datei (Wettlauf auf neuer Datei, db.wal_once)
    conn.execute("PRAGMA foreign_keys=ON")
    db.schema_once(conn, "community", p, _schema)
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
    """Darf Loesungen teilen (Recht can_share_solutions, ab StudiNow Plus). Lesen ebenfalls erst ab Plus
    (can_read_community, Entscheidung 05.11.2026; Pruefung in community_api._user)."""
    from . import entitlements
    return entitlements.has(user, "can_share_solutions")


def require_plan(user: dict) -> None:
    if not plan_ok(user):
        raise CommunityError("plan_required", "Eigene Lösungen teilen gibt es ab StudiNow Plus.", 403)


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
# insgesamt je Konto und Hochschule (Audit P39-10, 08.11.2026): ergaenzende Meldungen (die Windows-App schickt Seiten
# zu 5.000, P19-03) liessen die Tabelle sonst ohne Ende wachsen; ein voller Abgleich (`replace`) ersetzt den Bestand
MAX_CLAIMS_TOTAL = 50_000


def claim_files(user: dict, university: str, fingerprints: list, replace: bool = False, course_keys: list | None = None) -> dict:
    """Geraet meldet die Fingerabdruecke seiner PDFs aus dem Hochschul-Abgleich und die Schluessel seiner Kurse.
    `replace`: alle bisherigen Meldungen des Kontos fuer diese Hochschule ersetzen (voller Abgleich), sonst ergaenzen."""
    if not isinstance(fingerprints, list) or len(fingerprints) > MAX_CLAIMS:
        raise CommunityError("claims_invalid", f"Höchstens {MAX_CLAIMS} Fingerabdrücke je Meldung.")
    if not isinstance(course_keys or [], list) or len(course_keys or []) > MAX_CLAIMS:
        raise CommunityError("claims_invalid", f"Höchstens {MAX_CLAIMS} Kurse je Meldung.")
    fps = sorted({str(f).lower() for f in fingerprints if HEX64.match(str(f).lower())})
    keys = sorted({str(k).lower() for k in course_keys or [] if HEX64.match(str(k).lower())})
    now = _now()
    limited = 0
    with cursor() as conn:
        # Lerngruppen-Schluessel sind nie Kurse (getrennte Namensraeume)
        keys = [k for k in keys if not _kind_is(conn, k, "group")]
        keys, limited = _course_key_budget(conn, user["id"], keys, now)
        if not replace and fps:
            have = conn.execute("SELECT COUNT(*) FROM claims WHERE user_id=? AND university=?", (user["id"], university)).fetchone()[0]
            q = ",".join("?" * len(fps))
            known = conn.execute(f"SELECT COUNT(*) FROM claims WHERE user_id=? AND university=? AND fingerprint IN ({q})",
                                 (user["id"], university, *fps)).fetchone()[0]
            if have + len(fps) - known > MAX_CLAIMS_TOTAL:
                raise CommunityError("claims_limit", f"Höchstens {MAX_CLAIMS_TOTAL} gemeldete PDFs je Konto. Bitte einmal "
                                     "vollständig neu abgleichen.", 429)
        if replace:
            conn.execute("DELETE FROM claims WHERE user_id=? AND university=?", (user["id"], university))
        conn.executemany("INSERT OR REPLACE INTO claims(user_id, fingerprint, university, claimed_at) VALUES (?,?,?,?)",
                         [(user["id"], f, university, now) for f in fps])
        if course_keys is not None and replace:
            conn.execute("DELETE FROM course_claims WHERE user_id=? AND university=?", (user["id"], university))
        conn.executemany("INSERT OR REPLACE INTO course_claims(user_id, course_key, university, claimed_at) VALUES (?,?,?,?)",
                         [(user["id"], k, university, now) for k in keys])
        n = conn.execute("SELECT COUNT(*) FROM claims WHERE user_id=? AND university=?", (user["id"], university)).fetchone()[0]
    out = {"accepted": len(fps), "ignored": len(fingerprints) - len(fps), "total": n, "courses": len(keys)}
    if limited:
        out["courses_limited"] = limited
    return out


def _kind_is(conn, key: str, kind: str) -> bool:
    r = conn.execute("SELECT kind FROM community_kinds WHERE community_key=?", (key,)).fetchone()
    if r:
        return r["kind"] == kind
    if kind == "group":
        return bool(conn.execute("SELECT 1 FROM study_groups WHERE group_key=?", (key,)).fetchone())
    return False


def _course_key_budget(conn, user_id: str, keys: list[str], now: str) -> tuple[list[str], int]:
    """Tagesgrenze fuer neue Kurs-/Modulschluessel je Konto (Sicherheitspruefung 3.11.2026, Begleitmassnahme):
    schon einmal gemeldete Schluessel zaehlen nicht, darueber hinaus gehen nur `course_keys_user` neue je Tag durch,
    der Rest wird ausgelassen (das Geraet meldet ihn beim naechsten Abgleich erneut). Das Schluesselverfahren selbst
    bleibt unveraendert. LERNAPP_LIMIT_COURSE_KEYS_USER=Anzahl/Minuten ueberschreibt."""
    if not keys:
        return keys, 0
    known = {r[0] for r in conn.execute("SELECT course_key FROM course_key_history WHERE user_id=?", (user_id,))}
    fresh = [k for k in keys if k not in known]
    if not fresh:
        return keys, 0
    limit, minutes = accounts._limit("course_keys_user")
    since = (datetime.now(timezone.utc) - timedelta(minutes=minutes)).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    used = conn.execute("SELECT COUNT(*) FROM course_key_history WHERE user_id=? AND first_at>?", (user_id, since)).fetchone()[0]
    allowed = fresh[:max(0, limit - used)]
    conn.executemany("INSERT OR IGNORE INTO course_key_history(user_id, course_key, first_at) VALUES (?,?,?)",
                     [(user_id, k, now) for k in allowed])
    dropped = set(fresh) - set(allowed)
    return [k for k in keys if k not in dropped], len(dropped)


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
        raise CommunityError("not_a_solution", "Die Datei ist keine StudiNow-Lösung.")
    if set(pkg) != TOP_KEYS:
        bad("Felder")
    v = pkg.get("formatVersion")
    if not isinstance(v, int) or isinstance(v, bool):
        bad("Formatversion")
    if v not in FORMAT_VERSIONS:
        raise CommunityError("unsupported_version", f"Diese Lösung hat Formatversion {v} – bitte StudiNow aktualisieren.")
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
    enc_keys = {"cipher", "kdf", "keyMaterial", "salt", "nonce", "plaintextBytes"} | ({"compression", "compressedBytes"} if v == 2 else set())
    if not isinstance(e, dict) or set(e) != enc_keys:
        bad("encryption")
    if v == 2 and e.get("compression") != "deflate-raw":
        bad("Kompression")
    if e.get("cipher") != "AES-256-GCM" or e.get("kdf") != "HKDF-SHA256" or e.get("keyMaterial") not in KEY_MATERIALS:
        bad("Verschlüsselung")
    if _b64len(str(e.get("salt")), "salt") != 32 or _b64len(str(e.get("nonce")), "nonce") != 12:
        bad("Salz/Nonce")
    ct = pkg.get("ciphertext")
    if not isinstance(ct, str) or len(ct) > MAX_PACKAGE_BYTES:
        raise CommunityError("too_large", "Die Lösung ist zu groß.", 413)
    n = _b64len(ct, "ciphertext")
    pb = e.get("plaintextBytes")
    if not isinstance(pb, int) or isinstance(pb, bool) or not (1 <= pb <= MAX_PLAINTEXT_BYTES) or (v == 1 and pb != n - 16):
        bad("plaintextBytes")
    if v == 2:
        cb = e.get("compressedBytes")
        if not isinstance(cb, int) or isinstance(cb, bool) or not (1 <= cb <= MAX_PLAINTEXT_BYTES) or cb != n - 16:
            bad("compressedBytes")
    return {"id": sid.lower(), "fingerprint": fp, "display_name": name, "created_at": created, "page_count": pc, "pages": pages,
            "key_material": e["keyMaterial"]}


# ---------------------------------------------------------------- Veroeffentlichen, Suchen, Laden, Zurueckziehen

def _summary(r, me: str, reported: set[str] | None = None, conn=None) -> dict:
    out = {"solution_id": r["id"], "fingerprint": r["fingerprint"], "display_name": r["display_name"], "pseudonym": r["pseudonym"],
           "title": r["title"], "created_at": r["created_at"], "published_at": r["published_at"], "updated_at": r["updated_at"],
           "page_count": r["page_count"],
           "pages": r["pages"], "downloads": r["downloads"], "status": r["status"], "mine": r["author_id"] == me, "community_key": r["community_key"],
           "reported_by_me": r["id"] in (reported or set())}
    if conn is not None:
        out["likes"] = conn.execute("SELECT COUNT(*) FROM likes WHERE solution_id=?", (r["id"],)).fetchone()[0]
        out["liked_by_me"] = bool(conn.execute("SELECT 1 FROM likes WHERE solution_id=? AND user_id=?", (r["id"], me)).fetchone())
        out["comments"] = conn.execute("SELECT COUNT(*) FROM comments WHERE solution_id=? AND status='active'", (r["id"],)).fetchone()[0]
    return out


def _member(conn, user: dict, community_key: str | None) -> bool:
    return bool(community_key and conn.execute("SELECT 1 FROM community_members WHERE user_id=? AND community_key=?",
                                               (user["id"], community_key)).fetchone())


def _community_key(key) -> str:
    k = str(key or "").lower()
    if not HEX64.match(k):
        raise CommunityError("community_invalid", "Ungültige Community.")
    return k


def join(user: dict, university: str, community_key, kind: str) -> dict:
    """Beitreten: Kurs nur, wenn ein Geraet des Kontos ihn gemeldet hat; Lerngruppe, wenn es sie gibt. Verlangt eine
    bestaetigte E-Mail-Adresse; ein Schluessel ist entweder Kurs oder Lerngruppe (Sicherheitspruefung 3.11.2026)."""
    key = _community_key(community_key)
    if kind not in ("course", "group"):
        raise CommunityError("community_invalid", "Ungültige Community.")
    _require_verified(user, "einer Community beizutreten")
    with cursor() as conn:
        if kind == "course":
            if _kind_is(conn, key, "group") or not conn.execute(
                    "SELECT 1 FROM course_claims WHERE user_id=? AND course_key=? AND university=?", (user["id"], key, university)).fetchone():
                raise CommunityError("course_not_owned", "Diesen Kurs gibt es nicht in deinem Hochschul-Abgleich.", 403)
            conn.execute("INSERT OR IGNORE INTO community_kinds(community_key, kind, created_at) VALUES (?, 'course', ?)", (key, _now()))
        elif not _kind_is(conn, key, "group") or not conn.execute(
                "SELECT 1 FROM study_groups WHERE group_key=? AND university=?", (key, university)).fetchone():
            raise CommunityError("group_not_found", "Keine Lerngruppe mit diesem Code an deiner Hochschule.", 404)
        conn.execute("INSERT OR IGNORE INTO community_members(user_id, community_key, university, kind, joined_at) VALUES (?,?,?,?,?)",
                     (user["id"], key, university, kind, _now()))
    return {"joined": True, "community_key": key}


def leave(user: dict, community_key) -> dict:
    with cursor() as conn:
        conn.execute("DELETE FROM community_members WHERE user_id=? AND community_key=?", (user["id"], _community_key(community_key)))
    return {"left": True}


def create_group(user: dict, university: str, group_key, name) -> dict:
    """Lerngruppe anlegen (ab Plus); der Code bleibt beim Geraet, der Dienst kennt nur den Schluessel."""
    require_plan(user)
    key, clean = _community_key(group_key), str(name or "").strip()
    if not clean or len(clean) > MAX_GROUP_NAME:
        raise CommunityError("group_name_invalid", "Gib der Lerngruppe einen Namen (höchstens 60 Zeichen).")
    with cursor() as conn:
        if conn.execute("SELECT 1 FROM study_groups WHERE group_key=?", (key,)).fetchone():
            raise CommunityError("group_exists", "Diese Lerngruppe gibt es schon.", 409)
        # Kein Gruppenschluessel, der als Kurs/Modul gemeldet ist oder als Kurs-Community existiert (3.11.2026)
        if (_kind_is(conn, key, "course")
                or conn.execute("SELECT 1 FROM course_claims WHERE course_key=?", (key,)).fetchone()
                or conn.execute("SELECT 1 FROM community_members WHERE community_key=? AND kind='course'", (key,)).fetchone()
                or conn.execute("SELECT 1 FROM solutions WHERE community_key=?", (key,)).fetchone()):
            raise CommunityError("group_exists", "Diese Lerngruppe gibt es schon.", 409)
        now = _now()
        conn.execute("INSERT INTO study_groups(group_key, university, name, created_by, created_at) VALUES (?,?,?,?,?)",
                     (key, university, clean, user["id"], now))
        conn.execute("INSERT OR REPLACE INTO community_kinds(community_key, kind, created_at) VALUES (?, 'group', ?)", (key, now))
        conn.execute("INSERT INTO community_members(user_id, community_key, university, kind, joined_at) VALUES (?,?,?,'group',?)",
                     (user["id"], key, university, now))
    return {"community_key": key, "name": clean, "kind": "group"}


def group_preview(user: dict, university: str, group_key) -> dict:
    """Name einer Lerngruppe vor dem Beitritt (Bestaetigungsdialog beim Beitrittslink); den Schluessel kennt nur, wer
    den Code hat. Kurs-/Modulschluessel liefern nie einen Namen (3.11.2026)."""
    key = _community_key(group_key)
    with cursor() as conn:
        g = conn.execute("SELECT name FROM study_groups WHERE group_key=? AND university=?", (key, university)).fetchone()
        if not g or not _kind_is(conn, key, "group"):
            raise CommunityError("group_not_found", "Keine Lerngruppe mit diesem Code an deiner Hochschule.", 404)
        members = conn.execute("SELECT COUNT(*) FROM community_members WHERE community_key=?", (key,)).fetchone()[0]
    return {"community_key": key, "kind": "group", "name": g["name"], "members": members}


def communities(user: dict, university: str) -> list[dict]:
    """Eigene Communities und alle gemeldeten Kurse (`joined` je Eintrag); Kursnamen kennt nur das Geraet. Den Namen
    einer Lerngruppe sehen nur ihre Mitglieder; ein gemeldeter Kursschluessel ist nie eine Gruppe (3.11.2026)."""
    with cursor() as conn:
        joined = {r["community_key"]: r for r in conn.execute("SELECT * FROM community_members WHERE user_id=?", (user["id"],))}
        claimed = {r["course_key"] for r in conn.execute("SELECT course_key FROM course_claims WHERE user_id=? AND university=?",
                                                         (user["id"], university))}
        out = []
        for key in sorted(claimed | set(joined)):
            m = joined.get(key)
            g = conn.execute("SELECT name FROM study_groups WHERE group_key=?", (key,)).fetchone() \
                if m and m["kind"] == "group" else None
            members = conn.execute("SELECT COUNT(*) FROM community_members WHERE community_key=?", (key,)).fetchone()[0]
            count = conn.execute("SELECT COUNT(*) FROM solutions WHERE community_key=? AND status='active'", (key,)).fetchone()[0]
            out.append({"community_key": key, "kind": "group" if g else "course", "name": g["name"] if g else None,
                        "joined": bool(m), "members": members, "solutions": count})
    return out


def community_solutions(user: dict, community_key) -> list[dict]:
    key = _community_key(community_key)
    with cursor() as conn:
        if not _member(conn, user, key):
            raise CommunityError("not_a_member", "Tritt zuerst dieser Community bei.", 403)
        rows = conn.execute("SELECT * FROM solutions WHERE community_key=? AND status='active' ORDER BY published_at DESC", (key,)).fetchall()
        return _listed(conn, user, rows)


def _listed(conn, user: dict, rows) -> list[dict]:
    blocked = {r["pseudonym"] for r in conn.execute("SELECT pseudonym FROM blocks WHERE user_id=?", (user["id"],))}
    banned = {r["author_id"] for r in conn.execute("SELECT author_id FROM bans")}
    reported = {r["solution_id"] for r in conn.execute("SELECT solution_id FROM reports WHERE reporter_id=?", (user["id"],))}
    out = [_summary(r, user["id"], reported, conn) for r in rows if r["pseudonym"] not in blocked and r["author_id"] not in banned]
    out.sort(key=lambda x: x["published_at"], reverse=True)         # meistgelikte zuerst, bei Gleichstand die neueste
    out.sort(key=lambda x: -x["likes"])
    return out


def publish(user: dict, university: str, pkg, title: str | None = None, community_key=None) -> dict:
    require_plan(user)
    info = validate_package(pkg)
    key = _community_key(community_key) if community_key else None
    if key:
        if info["key_material"] != "community-secret":
            raise CommunityError("package_invalid", "Die Lösung ist beschädigt (Kopf: Verschlüsselung).")
        with cursor() as conn:
            if not _member(conn, user, key):
                raise CommunityError("not_a_member", "Tritt zuerst dieser Community bei.", 403)
    elif LEGACY_PUBLISH:
        require_file(info["fingerprint"])
    else:
        raise CommunityError("community_required", "Wähle eine Community aus.")
    title = (title or "").strip()[:MAX_TITLE] or None
    raw = json.dumps(pkg, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    if len(raw) > MAX_PACKAGE_BYTES:
        raise CommunityError("too_large", "Die Lösung ist zu groß.", 413)
    with cursor() as conn:
        if conn.execute("SELECT 1 FROM bans WHERE author_id=?", (user["id"],)).fetchone():
            raise CommunityError("author_banned", "Dein Konto darf keine Lösungen mehr veröffentlichen.", 403)
        cur = conn.execute("SELECT author_id, status FROM solutions WHERE id=?", (info["id"],)).fetchone()
        if not cur:
            other = own_solution(conn, user["id"], info["fingerprint"], key)
            if other:
                # eine Loesung je PDF und Community: der Client fragt "Aktualisieren?" und ersetzt dann per PUT
                raise CommunityError("already_published", "Du hast zu dieser PDF schon eine Lösung geteilt. Aktualisieren?", 409,
                                     {"solution_id": other["id"]})
            _limit("publish_user", user["id"])                 # Spam-Grenze, erneutes Veroeffentlichen zaehlt nicht
        if cur and cur["author_id"] != user["id"]:
            raise CommunityError("solution_exists", "Diese Lösung wurde schon von einem anderen Konto veröffentlicht.", 409)
        if cur and cur["status"] in ("hidden", "removed"):
            raise CommunityError("solution_blocked", "Diese Lösung ist gesperrt und kann nicht erneut veröffentlicht werden.", 403)
        now = _now()
        # Audit P5-01 (08.11.2026): Paket neben die Zieldatei schreiben, Zeile eintragen, dann atomar an die Stelle
        # setzen - alles vor dem Commit. Scheitert die Datenbank, bleibt keine Paketdatei ohne Zeile zurueck (vorher
        # eine Leiche, die weder Zurueckziehen noch Loeschen je fand); ein Leser sieht beim erneuten Veroeffentlichen
        # nie ein halb geschriebenes Paket.
        with _staged_package(info["id"], raw) as install:
            conn.execute("""INSERT INTO solutions(id, fingerprint, university, author_id, pseudonym, display_name, title, created_at, published_at,
                            page_count, pages, size, status, community_key) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,'active',?)
                            ON CONFLICT(id) DO UPDATE SET fingerprint=excluded.fingerprint, community_key=excluded.community_key, display_name=excluded.display_name, title=COALESCE(excluded.title, solutions.title),
                              created_at=excluded.created_at, published_at=excluded.published_at, page_count=excluded.page_count,
                              pages=excluded.pages, size=excluded.size, status='active', status_reason=NULL""",
                         (info["id"], info["fingerprint"], university, user["id"], pseudonym(user["id"]), info["display_name"], title,
                          info["created_at"], now, info["page_count"], info["pages"], len(raw), key))
            install()
    return {"solution_id": info["id"], "published_at": now, "pseudonym": pseudonym(user["id"]), "republished": bool(cur)}


def _package_path(solution_id: str) -> Path:
    return package_dir() / f"{solution_id}.uniflowsolution"


@contextmanager
def _staged_package(solution_id: str, raw: str):
    """Paket in eine Temp-Datei mit eindeutigem Namen je Aufruf schreiben (`<id>.uniflowsolution.<zufall>.neu`); der
    gelieferte Aufruf `install()` setzt sie atomar an die Stelle der Zieldatei (Path.replace, gleiche Platte). Bleibt
    `install()` aus oder scheitert etwas, verschwindet die Temp-Datei. Audit P5-01/P5-02: vorher schrieb `publish`
    direkt in die Zieldatei und `update` nutzte fuer alle Aufrufe denselben Namen `.neu` - zwei gleichzeitige
    Aktualisierungen derselben Loesung ueberschrieben einander die Temp-Datei (FileNotFoundError beim Umbenennen oder
    ein halbes Paket im Ziel)."""
    package_dir().mkdir(parents=True, exist_ok=True)
    target = _package_path(solution_id)
    tmp = target.with_name(f"{target.name}.{uuid.uuid4().hex[:12]}.neu")
    try:
        tmp.write_text(raw, encoding="utf-8")
        yield lambda: tmp.replace(target)
    finally:
        tmp.unlink(missing_ok=True)


def own_solution(conn, author_id: str, fingerprint: str, community_key: str | None):
    """Eigene Loesung zu dieser PDF in dieser Community (aktiv oder verborgen), die zuletzt veroeffentlichte; bei alten
    Doppeln (vor dem 03.11.2026) gilt diese. Zurueckgezogene und entfernte zaehlen nicht."""
    return conn.execute("""SELECT * FROM solutions WHERE author_id=? AND fingerprint=? AND community_key IS ? AND status IN ('active','hidden')
                           ORDER BY published_at DESC, id LIMIT 1""", (author_id, fingerprint, community_key)).fetchone()


def update(user: dict, university: str, solution_id: str, pkg, title: str | None = None, community_key=None) -> dict:
    """Paket der EIGENEN Loesung ersetzen (zusammengefuehrt beim Client). Dieselben Pruefungen wie beim Veroeffentlichen;
    Kopf-ID, Fingerabdruck und Community muessen gleich bleiben. ID, Likes, Kommentare, Sichtbarkeit und
    `published_at` bleiben, `updated_at` wird neu gesetzt."""
    require_plan(user)
    info = validate_package(pkg)
    sid = str(solution_id or "").lower()
    with cursor() as conn:
        r = conn.execute("SELECT * FROM solutions WHERE id=?", (sid,)).fetchone()
        if not r or r["status"] in ("withdrawn",):
            raise CommunityError("not_found", "Lösung nicht gefunden.", 404)
        if r["author_id"] != user["id"]:
            raise CommunityError("not_owner", "Nur der Autor kann seine Lösung aktualisieren.", 403)
        if r["status"] in ("hidden", "removed"):
            raise CommunityError("solution_blocked", "Diese Lösung ist gesperrt und kann nicht aktualisiert werden.", 403)
        if conn.execute("SELECT 1 FROM bans WHERE author_id=?", (user["id"],)).fetchone():
            raise CommunityError("author_banned", "Dein Konto darf keine Lösungen mehr veröffentlichen.", 403)
        if info["id"] != r["id"]:
            raise CommunityError("solution_mismatch", "Das neue Paket gehört zu einer anderen Lösung (Kopf: solutionId).")
        if info["fingerprint"] != r["fingerprint"]:
            raise CommunityError("solution_mismatch", "Das neue Paket gehört zu einer anderen PDF.")
        if community_key and _community_key(community_key) != r["community_key"]:
            raise CommunityError("solution_mismatch", "Die Community einer Lösung lässt sich nicht ändern.")
        if r["community_key"]:
            if info["key_material"] != "community-secret":
                raise CommunityError("package_invalid", "Die Lösung ist beschädigt (Kopf: Verschlüsselung).")
            if not _member(conn, user, r["community_key"]):
                raise CommunityError("not_a_member", "Tritt zuerst dieser Community bei.", 403)
        elif not LEGACY_PUBLISH:
            raise CommunityError("community_required", "Wähle eine Community aus.")
        else:
            require_file(info["fingerprint"])
    raw = json.dumps(pkg, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    if len(raw) > MAX_PACKAGE_BYTES:
        raise CommunityError("too_large", "Die Lösung ist zu groß.", 413)
    _limit("update_user", user["id"])
    title = (title or "").strip()[:MAX_TITLE] or None
    now = _now()
    # Audit P5-02 (08.11.2026): eindeutige Temp-Datei je Aufruf; Zeile und Datei in EINER Transaktion, und nur solange
    # die Loesung noch aktiv ist - hat die Moderation sie inzwischen verborgen oder entfernt (Paket geloescht), kommt
    # kein neues Paket auf die Platte (vorher stand das Paket einer entfernten Loesung wieder da).
    with _staged_package(sid, raw) as install, cursor() as conn:
        n = conn.execute("""UPDATE solutions SET display_name=?, title=COALESCE(?, title), page_count=?, pages=?, size=?, updated_at=?
                            WHERE id=? AND author_id=? AND status='active'""",
                         (info["display_name"], title, info["page_count"], info["pages"], len(raw), now, sid, user["id"])).rowcount
        if n != 1:
            cur = conn.execute("SELECT status FROM solutions WHERE id=?", (sid,)).fetchone()
            if cur and cur["status"] in ("hidden", "removed"):
                raise CommunityError("solution_blocked", "Diese Lösung ist gesperrt und kann nicht aktualisiert werden.", 403)
            raise CommunityError("not_found", "Lösung nicht gefunden.", 404)
        install()
    return {"solution_id": sid, "updated_at": now, "pages": info["pages"], "pseudonym": pseudonym(user["id"])}


def find(user: dict, university: str, fingerprint: str) -> list[dict]:
    """Loesungen zu einer PDF: aus den eigenen Communities, dazu Pakete ohne Community fuer die eigene PDF."""
    fp = fingerprint if HEX64.match(fingerprint or "") else None
    with cursor() as conn:
        joined = [r[0] for r in conn.execute("SELECT community_key FROM community_members WHERE user_id=?", (user["id"],))]
    if not fp or not joined:
        require_file(fingerprint)
    owned = owns_file(fp) if fp else False
    with cursor() as conn:
        rows = conn.execute("SELECT * FROM solutions WHERE fingerprint=? AND university=? AND status='active' ORDER BY published_at DESC",
                            (fp, university)).fetchall()
        return _listed(conn, user, [r for r in rows if (r["community_key"] in joined if r["community_key"] else owned)])


def _require_access(conn, user: dict, r) -> None:
    if not r["community_key"]:
        require_file(r["fingerprint"], user["id"])
    elif not _member(conn, user, r["community_key"]):
        raise CommunityError("not_found", "Lösung nicht gefunden.", 404)


def get_package(user: dict, solution_id: str) -> tuple[dict, dict]:
    raw, summary = get_package_raw(user, solution_id)
    return json.loads(raw), summary


def get_package_raw(user: dict, solution_id: str) -> tuple[str, dict]:
    """Wie `get_package`, aber das Paket als gespeicherter JSON-Text (kompakt, von `publish` selbst geschrieben): spart beim
    Ansehen das Einlesen und erneute Schreiben von bis zu 65 MB je Anfrage (Messung 02.11.2026: Ansehen dreimal schneller)."""
    with cursor() as conn:
        r = conn.execute("SELECT * FROM solutions WHERE id=?", (solution_id.lower(),)).fetchone()
        if not r or (r["status"] != "active" and r["author_id"] != user["id"]):
            raise CommunityError("not_found", "Lösung nicht gefunden.", 404)
        if conn.execute("SELECT 1 FROM bans WHERE author_id=?", (r["author_id"],)).fetchone() and r["author_id"] != user["id"]:
            raise CommunityError("not_found", "Lösung nicht gefunden.", 404)
        if r["author_id"] != user["id"]:
            _require_access(conn, user, r)
            conn.execute("UPDATE solutions SET downloads=downloads+1 WHERE id=?", (r["id"],))
        p = package_dir() / f"{r['id']}.uniflowsolution"
        if not p.exists():
            raise CommunityError("not_found", "Lösung nicht gefunden.", 404)
        return p.read_text(encoding="utf-8"), _summary(r, user["id"], None, conn)


def mine(user: dict) -> list[dict]:
    with cursor() as conn:
        rows = conn.execute("SELECT * FROM solutions WHERE author_id=? ORDER BY published_at DESC", (user["id"],)).fetchall()
        return [_summary(r, user["id"], None, conn) for r in rows]


def withdraw_all(author_id: str, reason: str) -> int:
    """Alle Loesungen eines Kontos zurueckziehen (Konto geloescht): nicht mehr sichtbar, Pakete weg. Audit P5-05
    (08.11.2026): die Pakete verschwinden innerhalb der Transaktion - scheitert ein Loeschen, bleibt die Datenbank
    unveraendert und die Wiederholung (spaetestens `forget_author` beim endgueltigen Loeschen) erledigt alles; vorher
    war die Datenbank schon festgeschrieben und die Wiederholung fand nichts mehr, die Pakete blieben liegen."""
    with cursor() as conn:
        from . import community_cards
        # zuerst: legt beim ersten Aufruf je Prozess sein Schema per executescript an, und das committet still alles
        # davor - danach gehoeren Statuswechsel und Dateiloeschung zu EINER Transaktion
        community_cards.withdraw_all(conn, author_id)                # geteilte Karteikarten-Stapel ebenso
        rows = conn.execute("SELECT id FROM solutions WHERE author_id=? AND status IN ('active','hidden')", (author_id,)).fetchall()
        conn.execute("UPDATE solutions SET status='withdrawn', status_reason=? WHERE author_id=? AND status IN ('active','hidden')",
                     (reason, author_id))
        for r in rows:
            _package_path(r["id"]).unlink(missing_ok=True)
    return len(rows)


def forget_author(user_id: str) -> int:
    """Konto endgueltig geloescht: Loesungen samt Paketen und Meldungen dazu, eigene Meldungen, Sperrliste und
    Bann-Eintrag entfernen. Liefert die Zahl der entfernten Loesungen."""
    with cursor() as conn:
        ids = [r[0] for r in conn.execute("SELECT id FROM solutions WHERE author_id=?", (user_id,))]
        from . import community_corrections
        community_corrections.forget(conn, user_id, ids)         # Korrekturen verweisen auf Loesungen: zuerst
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
        for sid in ids:                                           # alle Pakete des Kontos, auch liegen gebliebene (P5-05)
            _package_path(sid).unlink(missing_ok=True)
    from . import community_qa
    community_qa.forget(user_id)
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
    _require_verified(user, "Lösungen zu melden")
    with cursor() as conn:
        r = _visible_solution(conn, user, solution_id)
        if r["author_id"] == user["id"]:
            raise CommunityError("own_solution", "Die eigene Lösung lässt sich nicht melden, aber zurückziehen.")
        if conn.execute("SELECT 1 FROM reports WHERE solution_id=? AND reporter_id=?", (r["id"], user["id"])).fetchone():
            raise CommunityError("already_reported", "Du hast diese Lösung schon gemeldet.", 409)
        _limit("report_user", user["id"])
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
    """Autor einer Loesung fuer sich ausblenden. Nur fuer Loesungen, die das Konto sehen darf (Audit 38/39, 08.11.2026:
    vorher verriet eine fremde Loesungs-ID das Pseudonym ihres Autors, auch ohne Mitgliedschaft)."""
    with cursor() as conn:
        r = _visible_solution(conn, user, solution_id)
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


def reporter_info(reporter_id: str) -> dict:
    """Fuer die Moderation: wer hat gemeldet (Pseudonym, Kontoalter in Tagen, E-Mail bestaetigt), nie Konto-ID oder E-Mail."""
    u = accounts.get_user(reporter_id)
    age = None
    if u:
        try:
            age = max(0, (accounts.now() - datetime.fromisoformat(u["created_at"].replace("Z", "+00:00"))).days)
        except (KeyError, ValueError):
            pass
    return {"pseudonym": pseudonym(reporter_id), "account_age_days": age, "email_verified": bool(u and u["email_verified"])}


def moderation_queue(user: dict) -> list[dict]:
    require_admin(user)
    with cursor() as conn:
        rows = conn.execute("SELECT * FROM solutions WHERE report_count>0 OR status IN ('hidden','removed') ORDER BY status='hidden' DESC, report_count DESC, published_at DESC").fetchall()
        out = []
        for r in rows:
            reps = [{"reason": x["reason"], "note": x["note"], "created_at": x["created_at"], "reporter": reporter_info(x["reporter_id"])}
                    for x in conn.execute("SELECT reason, note, created_at, reporter_id FROM reports WHERE solution_id=? ORDER BY id", (r["id"],))]
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
            # Audit P5-03 (08.11.2026): `remove` und `ban_author` loeschen die Paketdatei; eine Wiederherstellung ohne
            # Paket wurde "aktiv" gelistet, das Laden lief auf 404. Ohne Paket gilt die Loesung als zurueckgezogen
            # (wie durch den Autor): der Autor veroeffentlicht sie erneut (gleiche ID, Likes und Kommentare bleiben).
            gone = r["status"] in ("hidden", "removed") and not _package_path(r["id"]).exists()
            conn.execute("UPDATE solutions SET status=?, status_reason=? WHERE id=? AND status IN ('hidden','removed')",
                         ("withdrawn" if gone else "active", "package_gone" if gone else None, r["id"]))
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
    out = {"action": action, "solution": s}
    if action == "restore" and gone:
        out["package_gone"] = True                       # Paket war geloescht: zurueckgezogen statt aktiv
    return out


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
        _require_access(conn, user, r)
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
                from . import community_qa
                community_qa.notify(conn, r["author_id"], "like", "solution", r["id"], pseudonym(user["id"]), r["title"] or r["display_name"],
                                    None, user["id"], bundle=f"like:{r['id']}:{_now()[:10]}")
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
        raise CommunityError("plan_required", "Kommentieren gibt es ab StudiNow Plus.", 403)
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
        from . import community_qa
        told = set()
        if parent_id:
            pa = conn.execute("SELECT author_id FROM comments WHERE id=?", (parent_id,)).fetchone()
            if pa:
                community_qa.notify(conn, pa["author_id"], "reply", "solution", r["id"], pseudonym(user["id"]), text, cid, user["id"])
                told.add(pa["author_id"])
        if r["author_id"] not in told:
            community_qa.notify(conn, r["author_id"], "comment", "solution", r["id"], pseudonym(user["id"]), text, cid, user["id"])
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
    _require_verified(user, "Kommentare zu melden")
    with cursor() as conn:
        c = conn.execute("SELECT * FROM comments WHERE id=? AND status='active'", (comment_id,)).fetchone()
        if not c:
            raise CommunityError("not_found", "Kommentar nicht gefunden.", 404)
        _visible_solution(conn, user, c["solution_id"])
        if c["author_id"] == user["id"]:
            raise CommunityError("own_comment", "Den eigenen Kommentar kannst du löschen statt melden.")
        if conn.execute("SELECT 1 FROM comment_reports WHERE comment_id=? AND reporter_id=?", (c["id"], user["id"])).fetchone():
            raise CommunityError("already_reported", "Du hast diesen Kommentar schon gemeldet.", 409)
        _limit("report_user", user["id"])
        conn.execute("INSERT INTO comment_reports(comment_id, reporter_id, reason, created_at) VALUES (?,?,?,?)",
                     (c["id"], user["id"], reason, _now()))
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
            "can_read": bool(user and (user.get("role") == "admin" or _can_read(user))), "can_share": bool(user and plan_ok(user)),
            "reasons": list(REPORT_REASONS), "reports_to_hide": REPORTS_TO_HIDE, "format": FORMAT, "format_version": FORMAT_VERSION,
            "max_package_bytes": MAX_PACKAGE_BYTES, "pseudonym": pseudonym(user["id"]) if user else None,
            "admin": bool(user and user.get("role") == "admin"),
            "can_comment": bool(user and _can_comment(user)), "max_comment": MAX_COMMENT}


def _can_read(user: dict) -> bool:
    from . import entitlements
    return entitlements.has(user, "can_read_community")


def _can_comment(user: dict) -> bool:
    from . import entitlements
    return entitlements.has(user, "can_write_community_comments")


def sample_package(fingerprint: str, pages: int = 2, page_count: int = 12, display_name: str = "", solution_id: str | None = None,
                   created_at: str = "2026-10-26T10:00:00Z", key_material: str = "original-pdf-bytes") -> dict:
    """Syntaktisch gueltiges Paket (Version 2) fuer Tests und den Vertrag (Chiffrat ist Zufall, nicht entschluesselbar)."""
    import os
    ct = os.urandom(48)
    return {"format": FORMAT, "formatVersion": FORMAT_VERSION,
            "header": {"solutionId": solution_id or str(uuid.uuid4()), "createdAt": created_at, "displayName": display_name,
                       "document": {"sha256": fingerprint, "pageCount": page_count},
                       "contents": {"pages": pages, "images": 0, "missingImages": 0},
                       "encryption": {"cipher": "AES-256-GCM", "kdf": "HKDF-SHA256", "keyMaterial": key_material,
                                      "salt": base64.b64encode(os.urandom(32)).decode(), "nonce": base64.b64encode(os.urandom(12)).decode(),
                                      "plaintextBytes": 4 * (len(ct) - 16), "compression": "deflate-raw",
                                      "compressedBytes": len(ct) - 16}},
            "ciphertext": base64.b64encode(ct).decode()}

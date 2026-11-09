"""Korrekturvorschlaege im Dienst (Wunsch des Inhabers 03.11.2026, Gegenstueck zu CommunityCorrection.swift / CloudKit-Typ
`Correction`).

Ein Mitglied einer Community markiert auf einer fremden, geteilten Loesung (Striche, Randnotizen, Begleittext) und schickt
das dem Ersteller. Die Loesung bleibt unveraendert. Der Ersteller sieht einen Hinweis im Posteingang (Oeffnen, Ignorieren,
Gesehen), alle Mitglieder sehen die Korrekturen unter der Diskussion der Loesung.

**Form wie in CloudKit** (docs/CLOUDKIT-SCHEMA-PRODUCTION-2026-11-03.md, Typ `Correction`): `solutionID` -> `solution_id`,
`payload` -> `payload` (Base64, mit dem Community-Geheimnis verschluesselt, der Dienst sieht den Inhalt nie), `createdAt`
-> `created_at`, `createdOrder` -> `order`, `ownerRecordName` (Verfasser) -> `mine` und `pseudonym`, `solutionOwner` ->
`for_me`. Konto-IDs gehen nie nach aussen. Das Chiffrat ist dasselbe wie auf dem iPad (`CommunityCorrections.seal`):
Version 1 (1 Byte), Salz (32), Nonce (12), AES-256-GCM ueber den mit raw DEFLATE gepackten kanonischen Klartext
(`uniflow-community-correction`, Version 2), Schluessel per HKDF-SHA256 aus dem Community-Geheimnis mit Info
`uniflow-community-correction/v1|<loesungs-id>`, Zusatzdaten `…|<loesungs-id>|<korrektur-id>`.

Berechtigung wie "Teilen" (Recht `can_share_solutions`, ab StudiNow Plus) mit bestaetigter E-Mail-Adresse; sichtbar nur fuer
Mitglieder der Community der Loesung (gleiche Pruefung wie Kommentare). Grenzen: `correction_user` je Konto und Tag, hoechstens
`MAX_PER_USER` aktive Korrekturen je Konto und Loesung und `MAX_PER_SOLUTION` je Loesung, Chiffrat hoechstens
`MAX_PAYLOAD_CHARS` Zeichen, eine Liste hoechstens `MAX_LIST_CHARS` Zeichen Chiffrat (die aeltesten fallen weg). Melden wie bei Kommentaren (bestaetigte E-Mail, `report_user`, ab 3 verborgen, Moderation kann
freigeben). Gesehen und Ignorieren speichert der Dienst fuer den Ersteller der Loesung (`owner_status`), damit es auf allen
Geraeten des Kontos gilt; die Zahl offener Hinweise (`open`) ist die Zahl am Menuepunkt "Community".
"""
from __future__ import annotations

import base64
import json
import uuid

from . import community, solution_format as sf
from .community import CommunityError, REPORT_REASONS, REPORTS_TO_HIDE, UUID_RE, _limit, _now, _require_verified, pseudonym

SCHEMA = """
CREATE TABLE IF NOT EXISTS corrections (
    id TEXT PRIMARY KEY,                       -- UUID klein, vom Client (steckt in den Zusatzdaten des Chiffrats)
    solution_id TEXT NOT NULL REFERENCES solutions(id),
    author_id TEXT NOT NULL,                   -- Konto-ID des Verfassers (intern)
    pseudonym TEXT NOT NULL,
    owner_id TEXT NOT NULL,                    -- Konto-ID des Erstellers der Loesung (Posteingang)
    payload TEXT NOT NULL,                     -- Chiffrat (Base64); bei geloeschten Korrekturen leer
    created_at TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',     -- active | deleted | hidden
    report_count INTEGER NOT NULL DEFAULT 0,
    owner_status TEXT NOT NULL DEFAULT 'open'  -- Zustand beim Ersteller der Loesung: open | seen | ignored
);
CREATE INDEX IF NOT EXISTS idx_corrections_solution ON corrections(solution_id, created_at);
CREATE INDEX IF NOT EXISTS idx_corrections_owner ON corrections(owner_id, owner_status);
CREATE TABLE IF NOT EXISTS correction_reports (
    correction_id TEXT NOT NULL REFERENCES corrections(id),
    reporter_id TEXT NOT NULL,
    reason TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (correction_id, reporter_id)
);
"""

FORMAT = "uniflow-community-correction"
CONTENT_VERSION = 2
PAYLOAD_VERSION = 1
SALT_BYTES, NONCE_BYTES, TAG_BYTES = 32, 12, 16
MAX_PAYLOAD_CHARS = 750_000                    # wie CommunityCorrections.maxPayloadChars (CloudKit: rund 1 MB je Datensatz)
MAX_PLAINTEXT_BYTES = 8 << 20
MAX_TEXT, MAX_NOTES_PER_PAGE, MAX_PAGES = 2_000, 50, 300
MAX_PER_USER, MAX_PER_SOLUTION = 5, 50
MAX_LIST_CHARS = 16_000_000                    # Chiffrat je Antwort von `for_solution`: die aeltesten fallen weg
STATUSES = ("open", "seen", "ignored")


# ---------------------------------------------------------------- Chiffrat pruefen (der Dienst entschluesselt nie)

def check_payload(payload) -> None:
    """Form des Chiffrats wie `CommunityCorrections.open` vor dem Entschluesseln: Base64, Version 1, Mindestlaenge."""
    if not isinstance(payload, str) or not payload:
        raise CommunityError("payload_invalid", "Die Korrektur ist beschädigt.")
    if len(payload) > MAX_PAYLOAD_CHARS:
        raise CommunityError("too_large", "Die Korrektur ist zu groß. Markiere weniger Seiten oder schicke sie in Teilen.", 413)
    try:
        raw = base64.b64decode(payload, validate=True)
    except (ValueError, TypeError):
        raise CommunityError("payload_invalid", "Die Korrektur ist beschädigt.")
    if len(raw) <= 1 + SALT_BYTES + NONCE_BYTES + TAG_BYTES or raw[0] != PAYLOAD_VERSION:
        raise CommunityError("payload_invalid", "Die Korrektur ist beschädigt.")


# ---------------------------------------------------------------- Schicken, lesen

def _out(c, me: str, with_payload: bool = True, solution=None) -> dict:
    """Eine Korrektur fuer die Oberflaeche. `mine`/`for_me` statt Konto-IDs; `status` (open|seen|ignored) nur fuer den Ersteller."""
    for_me = c["owner_id"] == me
    out = {"id": c["id"], "solution_id": c["solution_id"], "pseudonym": c["pseudonym"], "created_at": c["created_at"],
           "order": c["rowid"] if "rowid" in c.keys() else 0, "mine": c["author_id"] == me, "for_me": for_me,
           "status": c["owner_status"] if for_me else None}
    if with_payload:
        out["payload"] = c["payload"]
    if solution is not None:
        out["title"] = solution["title"] or solution["display_name"] or "Lösung"
        out["fingerprint"] = solution["fingerprint"]
        out["community_key"] = solution["community_key"]
    return out


def _blocked(conn, user: dict) -> set[str]:
    return {r[0] for r in conn.execute("SELECT pseudonym FROM blocks WHERE user_id=?", (user["id"],))}


def _banned(conn) -> set[str]:
    return {r[0] for r in conn.execute("SELECT author_id FROM bans")}


def send(user: dict, solution_id: str, correction_id, payload) -> dict:
    """Korrektur an den Ersteller der Loesung schicken. Tarif wie Teilen, bestaetigte E-Mail, Mitglied der Community,
    nie zur eigenen Loesung."""
    community.require_plan(user)
    _require_verified(user, "Korrekturen zu schicken")
    cid = str(correction_id or "").lower()
    if not UUID_RE.match(cid):
        raise CommunityError("id_invalid", "Ungültige Kennung der Korrektur.")
    check_payload(payload)
    with community.cursor() as conn:
        s = community._visible_solution(conn, user, solution_id)
        if s["status"] != "active":
            raise CommunityError("not_found", "Lösung nicht gefunden.", 404)
        if s["author_id"] == user["id"]:
            raise CommunityError("own_solution", "Zu deiner eigenen Lösung brauchst du keinen Korrekturvorschlag.")
        if conn.execute("SELECT 1 FROM bans WHERE author_id=?", (user["id"],)).fetchone():
            raise CommunityError("author_banned", "Dein Konto darf in der Community nichts mehr schreiben.", 403)
        if conn.execute("SELECT 1 FROM corrections WHERE id=?", (cid,)).fetchone():
            raise CommunityError("correction_exists", "Diese Korrektur gibt es schon.", 409)
        mine = conn.execute("SELECT COUNT(*) FROM corrections WHERE solution_id=? AND author_id=? AND status='active'",
                            (s["id"], user["id"])).fetchone()[0]
        if mine >= MAX_PER_USER:
            raise CommunityError("corrections_limit", f"Du hast zu dieser Lösung schon {MAX_PER_USER} Korrekturen geschickt. "
                                 "Nimm eine zurück, bevor du eine neue schickst.", 429)
        if conn.execute("SELECT COUNT(*) FROM corrections WHERE solution_id=? AND status='active'", (s["id"],)).fetchone()[0] >= MAX_PER_SOLUTION:
            raise CommunityError("corrections_limit", "Zu dieser Lösung gibt es schon sehr viele Korrekturen.", 429)
        _limit("correction_user", user["id"])
        conn.execute("""INSERT INTO corrections(id, solution_id, author_id, pseudonym, owner_id, payload, created_at)
                        VALUES (?,?,?,?,?,?,?)""", (cid, s["id"], user["id"], pseudonym(user["id"]), s["author_id"], payload, _now()))
        from . import community_qa
        community_qa.notify(conn, s["author_id"], "correction", "solution", s["id"], pseudonym(user["id"]), None, cid, user["id"])
        return _out(conn.execute("SELECT rowid, * FROM corrections WHERE id=?", (cid,)).fetchone(), user["id"])


def for_solution(user: dict, solution_id: str) -> list[dict]:
    """Korrekturen zu einer Loesung (fuer alle Mitglieder), neueste zuerst; ohne gesperrte, verborgene und geloeschte."""
    with community.cursor() as conn:
        s = community._visible_solution(conn, user, solution_id)
        blocked, banned = _blocked(conn, user), _banned(conn)
        # Zeile fuer Zeile statt fetchall: an der Grenze wird nicht weitergelesen (vorher bis 50 x 750.000 Zeichen im
        # Speicher, bevor gekuerzt wurde; Liste 95 Nr. 70)
        rows = conn.execute("SELECT rowid, * FROM corrections WHERE solution_id=? AND status='active' ORDER BY created_at DESC, rowid DESC",
                            (s["id"],))
        out, size = [], 0
        for c in rows:
            if c["pseudonym"] in blocked or c["author_id"] in banned:
                continue
            size += len(c["payload"])
            if size > MAX_LIST_CHARS and out:                # nie unbegrenzt viel auf einmal (neueste zuerst)
                break
            out.append(_out(c, user["id"]))
        return out


def _visible(conn, user: dict, correction_id: str):
    c = conn.execute("SELECT rowid, * FROM corrections WHERE id=?", (str(correction_id or "").lower(),)).fetchone()
    if not c or (c["status"] != "active" and not (user.get("role") == "admin" and c["status"] == "hidden")):
        raise CommunityError("not_found", "Korrektur nicht gefunden.", 404)
    s = community._visible_solution(conn, user, c["solution_id"])
    if c["author_id"] != user["id"] and (c["pseudonym"] in _blocked(conn, user) or c["author_id"] in _banned(conn)):
        raise CommunityError("not_found", "Korrektur nicht gefunden.", 404)
    return c, s


def get(user: dict, correction_id: str) -> dict:
    with community.cursor() as conn:
        c, s = _visible(conn, user, correction_id)
        return _out(c, user["id"], solution=s)


def inbox(user: dict, limit: int = 50, count_only: bool = False) -> dict:
    """Posteingang des Erstellers: Korrekturen an eigene (aktive) Loesungen, nicht ignoriert, ohne Chiffrat (das liefert
    `get`). `open` (noch nicht geoeffnet) ist die Zahl am Menuepunkt, `seen` die Gruppe "Gesehen"."""
    limit = max(1, min(int(limit or 50), 200))
    with community.cursor() as conn:
        blocked, banned = _blocked(conn, user), _banned(conn)
        rows = conn.execute("""SELECT c.rowid AS rowid, c.id, c.solution_id, c.author_id, c.pseudonym, c.owner_id, c.created_at, c.owner_status,
                                      s.title, s.display_name, s.fingerprint, s.community_key
                               FROM corrections c JOIN solutions s ON s.id=c.solution_id
                               WHERE c.owner_id=? AND c.status='active' AND s.status='active' AND c.owner_status<>'ignored'
                               ORDER BY c.created_at DESC, c.rowid DESC""", (user["id"],)).fetchall()
        rows = [r for r in rows if r["author_id"] != user["id"] and r["pseudonym"] not in blocked and r["author_id"] not in banned]
        out = {"open": sum(1 for r in rows if r["owner_status"] == "open"), "seen": sum(1 for r in rows if r["owner_status"] == "seen")}
        if not count_only:
            out["items"] = [_out({**dict(r), "payload": ""}, user["id"], with_payload=False, solution=r) for r in rows[:limit]]
    return out


def set_status(user: dict, correction_id: str, status) -> dict:
    """Nur der Ersteller der Loesung: gesehen, ignoriert oder wieder offen."""
    if status not in STATUSES:
        raise CommunityError("status_invalid", "Unbekannter Zustand.")
    with community.cursor() as conn:
        c = conn.execute("SELECT * FROM corrections WHERE id=? AND status='active'", (str(correction_id or "").lower(),)).fetchone()
        if not c or c["owner_id"] != user["id"]:
            raise CommunityError("not_found", "Korrektur nicht gefunden.", 404)
        conn.execute("UPDATE corrections SET owner_status=? WHERE id=?", (status, c["id"]))
    return {"id": c["id"], "status": status, **{k: v for k, v in inbox(user, count_only=True).items()}}


def delete(user: dict, correction_id: str) -> dict:
    """Zuruecknehmen: nur der Verfasser (oder die Moderation); das Chiffrat wird geleert."""
    with community.cursor() as conn:
        c = conn.execute("SELECT * FROM corrections WHERE id=? AND status<>'deleted'", (str(correction_id or "").lower(),)).fetchone()
        if not c:
            raise CommunityError("not_found", "Korrektur nicht gefunden.", 404)
        if c["author_id"] != user["id"] and user.get("role") != "admin":
            raise CommunityError("not_owner", "Nur der Verfasser kann das.", 403)
        conn.execute("UPDATE corrections SET status='deleted', payload='' WHERE id=?", (c["id"],))
    return {"deleted": True, "id": c["id"]}


def report(user: dict, correction_id: str, reason) -> dict:
    if reason not in REPORT_REASONS:
        raise CommunityError("reason_invalid", "Unbekannter Meldegrund.")
    _require_verified(user, "Korrekturen zu melden")
    with community.cursor() as conn:
        c, _ = _visible(conn, user, correction_id)
        if c["author_id"] == user["id"]:
            raise CommunityError("own_post", "Die eigene Korrektur kannst du zurücknehmen statt melden.")
        if conn.execute("SELECT 1 FROM correction_reports WHERE correction_id=? AND reporter_id=?", (c["id"], user["id"])).fetchone():
            raise CommunityError("already_reported", "Du hast diese Korrektur schon gemeldet.", 409)
        _limit("report_user", user["id"])
        conn.execute("INSERT INTO correction_reports(correction_id, reporter_id, reason, created_at) VALUES (?,?,?,?)",
                     (c["id"], user["id"], reason, _now()))
        n = conn.execute("SELECT COUNT(*) FROM correction_reports WHERE correction_id=?", (c["id"],)).fetchone()[0]
        hidden = n >= REPORTS_TO_HIDE
        conn.execute("UPDATE corrections SET report_count=?, status=CASE WHEN ? THEN 'hidden' ELSE status END WHERE id=?", (n, hidden, c["id"]))
    return {"reported": True, "hidden": hidden, "reports": n}


# ---------------------------------------------------------------- Moderation, Konto, Export

def moderation_items(conn) -> list[dict]:
    """Gemeldete oder verborgene Korrekturen fuer die Moderation (ohne Inhalt, nur Verweise und Meldungen)."""
    items = []
    for r in conn.execute("SELECT * FROM corrections WHERE status='hidden' OR (status='active' AND report_count>0) "
                          "ORDER BY status='hidden' DESC, report_count DESC, created_at DESC"):
        reps = [{"reason": x["reason"], "created_at": x["created_at"], "reporter": community.reporter_info(x["reporter_id"])}
                for x in conn.execute("SELECT reason, created_at, reporter_id FROM correction_reports WHERE correction_id=? ORDER BY created_at, rowid", (r["id"],))]
        items.append({"id": r["id"], "kind": "correction", "status": r["status"], "pseudonym": r["pseudonym"], "text": "",
                      "context": r["solution_id"], "created_at": r["created_at"], "report_count": r["report_count"], "reports": reps})
    return items


def restore(conn, correction_id: str):
    """Moderation: verborgene Korrektur freigeben (Meldungen werden geloescht). None = keine verborgene mit dieser Kennung."""
    r = conn.execute("SELECT id FROM corrections WHERE id=? AND status='hidden'", (str(correction_id),)).fetchone()
    if r:
        conn.execute("UPDATE corrections SET status='active', report_count=0 WHERE id=?", (r["id"],))
        conn.execute("DELETE FROM correction_reports WHERE correction_id=?", (r["id"],))
    return r


def forget(conn, user_id: str, solution_ids: list[str]) -> None:
    """Konto geloescht: Korrekturen des Kontos und alle zu seinen Loesungen samt Meldungen entfernen (vor den Loesungen)."""
    ids = [r[0] for r in conn.execute("SELECT id FROM corrections WHERE author_id=?", (user_id,))]
    for sid in solution_ids:
        ids += [r[0] for r in conn.execute("SELECT id FROM corrections WHERE solution_id=?", (sid,))]
    for cid in set(ids):
        conn.execute("DELETE FROM correction_reports WHERE correction_id=?", (cid,))
        conn.execute("DELETE FROM corrections WHERE id=?", (cid,))
    conn.execute("DELETE FROM correction_reports WHERE reporter_id=?", (user_id,))


def exported(user: dict) -> list[dict]:
    """Eigene Korrekturen fuer den Datenexport (mit Chiffrat)."""
    with community.cursor() as conn:
        return [{"id": r["id"], "solution_id": r["solution_id"], "created_at": r["created_at"], "status": r["status"], "payload": r["payload"]}
                for r in conn.execute("SELECT * FROM corrections WHERE author_id=? ORDER BY created_at", (user["id"],))]


# ---------------------------------------------------------------- Referenz des Chiffrats (Gegenprobe zu Swift und Browser)

def _key_info(solution_id: str) -> bytes:
    return f"{FORMAT}/v{PAYLOAD_VERSION}|{solution_id.lower()}".encode()


def _aad(solution_id: str, correction_id: str) -> bytes:
    return f"{FORMAT}/v{PAYLOAD_VERSION}|{solution_id.lower()}|{correction_id.lower()}".encode()


def page_json(p: dict) -> dict:
    """Seite im Klartext: Loesungsseite (`SolutionPage.json`, Schluessel "c<pdfIndex>", Art pdf) mit Strichen als ganze Zahlen
    (Version 2) und den Randnotizen."""
    return {"key": f"c{p['pdfIndex']}", "kind": "pdf", "pdfIndex": p["pdfIndex"], "width": p["width"], "height": p["height"],
            "rotation": p.get("rotation", 0) % 360, "extraRotation": 0, "objects": [sf.encode_object(o) for o in p.get("strokes", [])],
            "notes": [{"id": n["id"], "x": n["x"], "y": n["y"], "text": n["text"]} for n in p.get("notes", [])]}


def plaintext(c: dict) -> bytes:
    """Kanonischer Klartext der Korrektur (byte-gleich mit Swift `CommunityCorrections.json(wire: true)` und dem Browser)."""
    pages = sorted((p for p in c.get("pages", []) if p.get("strokes") or p.get("notes")), key=lambda p: p["pdfIndex"])
    doc = {"format": FORMAT, "formatVersion": CONTENT_VERSION, "correctionID": c["id"].lower(), "solutionID": c["solution_id"].lower(),
           "pseudonym": c.get("pseudonym", ""), "createdAt": c["created_at"], "note": c.get("note", "").strip(),
           "pages": [page_json(p) for p in pages]}
    return sf.canonical(doc).encode()


def seal(c: dict, secret: bytes, salt: bytes, nonce: bytes) -> str:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    if len(salt) != SALT_BYTES or len(nonce) != NONCE_BYTES:
        raise ValueError("Salz/Nonce")
    packed = sf.deflate(plaintext(c))
    sealed = AESGCM(sf.derive_key(secret, salt, _key_info(c["solution_id"]))).encrypt(nonce, packed, _aad(c["solution_id"], c["id"]))
    out = base64.b64encode(bytes([PAYLOAD_VERSION]) + salt + nonce + sealed).decode()
    if len(out) > MAX_PAYLOAD_CHARS:
        raise ValueError("tooLarge")
    return out


def open_payload(payload: str, correction_id: str, solution_id: str, secret: bytes) -> dict:
    """Entschluesseln und pruefen; falscher Schluessel, veraendertes oder umgehaengtes Chiffrat werfen ValueError."""
    from cryptography.exceptions import InvalidTag
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    try:
        check_payload(payload)
    except CommunityError as e:
        raise ValueError("decryptionFailed") from e
    raw = base64.b64decode(payload, validate=True)
    salt, nonce, sealed = raw[1:1 + SALT_BYTES], raw[1 + SALT_BYTES:1 + SALT_BYTES + NONCE_BYTES], raw[1 + SALT_BYTES + NONCE_BYTES:]
    try:
        packed = AESGCM(sf.derive_key(secret, salt, _key_info(solution_id))).decrypt(nonce, sealed, _aad(solution_id, correction_id))
    except InvalidTag as e:
        raise ValueError("decryptionFailed") from e
    doc = json.loads(sf.inflate(packed, MAX_PLAINTEXT_BYTES))
    if doc.get("format") != FORMAT or doc.get("formatVersion") != CONTENT_VERSION:
        raise ValueError("invalidContent: Formatkennung")
    if doc.get("correctionID") != correction_id.lower() or doc.get("solutionID") != solution_id.lower():
        raise ValueError("invalidContent: passt nicht zum Datensatz")
    pages = []
    for p in doc["pages"]:
        pages.append({"pdfIndex": p["pdfIndex"], "width": p["width"], "height": p["height"], "rotation": p["rotation"],
                      "strokes": [sf.decode_object(o) for o in p["objects"]], "notes": p["notes"]})
    return {"id": doc["correctionID"], "solution_id": doc["solutionID"], "pseudonym": doc["pseudonym"], "created_at": doc["createdAt"],
            "note": doc["note"], "pages": pages}


def new_id() -> str:
    return str(uuid.uuid4())

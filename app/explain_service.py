"""Erklaerungsspeicher des Dienstes fuer die Windows-App (05.11.2026, packages/shared-contracts/page-explain.md).

"Einmal erklaeren, alle profitieren" auch zwischen PCs: Antworten der KI-Hilfe fuer ganze Seiten (geteilte Modi, ohne
Markierung, Frage, eigene Loesung und Notizen) liegen verschluesselt beim Dienst (`/api/explain`, app/page_explain.py).
Der Dienst sieht nur das Chiffrat; lesen kann nur, wer dieselbe Datei hat (Schluesselstoff Datei-SHA und
Seiten-Abdruck). Reihenfolge in POST /api/ai/tutor am PC: eigener Speicher (app/explain_local.py) -> hier -> live.

- `lookup`  sucht die niedrigste lesbare Variante (GET /api/explain?file_key&page&mode); Treffer = "Schon erklaert ·
            sofort da · 0 Credits" (source cloud), ohne KI-Anfrage
- `publish` legt eine frisch erzeugte Antwort (ohne Quellenmarken) auf den naechsten freien Platz (hoechstens drei je
            Seite und Modus, nie ueberschreiben); im Hintergrund, Fehler (offline, E-Mail unbestaetigt, voll) nur im
            Protokoll

Format wie DocIndexCrypto/PageExplainCrypto im Kern: Base64(Version 0x01 | Salz 32 | Nonce 12 | AES-256-GCM mit Tag),
Schluessel HKDF-SHA256(Salz, info "uniflow-pageexplain/v1|page:<p>|mode:<m>") aus "<fileSHA>|<pageHash>", Zusatzdaten
"uniflow-pageexplain/v1|<fileKey>|<page>|<mode>|<variant>|format:1", Klartext JSON mit sortierten Schluesseln
{v, page, pageHash, mode, variant, text, model, createdAt}.
"""
from __future__ import annotations

import base64
import json
import os
import re
import threading
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

from . import db

VERSION = 1
FORMAT = "uniflow-pageexplain"
SALT_BYTES, NONCE_BYTES = 32, 12
SHARED_MODES = ("explain", "explain_simple", "summary", "terms", "steps", "hints")
_SHA = re.compile(r"^[0-9a-f]{64}$")


# ---------------------------------------------------------------- Verschluesselung (reine Funktionen)

def key_material(file_sha: str, page_hash: str) -> bytes:
    return f"{file_sha.lower()}|{page_hash.lower()}".encode("utf-8")


def _info(page: int, mode: str) -> bytes:
    return f"{FORMAT}/v{VERSION}|page:{page}|mode:{mode}".encode("utf-8")


def _aad(file_key: str, page: int, mode: str, variant: int) -> bytes:
    return f"{FORMAT}/v{VERSION}|{file_key}|{page}|{mode}|{variant}|format:{VERSION}".encode("utf-8")


def _key(file_sha: str, page_hash: str, salt: bytes, page: int, mode: str) -> bytes:
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=salt, info=_info(page, mode)).derive(key_material(file_sha, page_hash))


def seal(text: str, *, file_sha: str, page_hash: str, file_key: str, page: int, mode: str, variant: int,
         model: str | None = None, created_at: str | None = None, salt: bytes | None = None, nonce: bytes | None = None) -> str:
    salt = salt or os.urandom(SALT_BYTES)
    nonce = nonce or os.urandom(NONCE_BYTES)
    plain = json.dumps({"v": VERSION, "page": page, "pageHash": page_hash, "mode": mode, "variant": variant, "text": text,
                        "model": model, "createdAt": created_at or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")},
                       sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    ct = AESGCM(_key(file_sha, page_hash, salt, page, mode)).encrypt(nonce, plain, _aad(file_key, page, mode, variant))
    return base64.b64encode(bytes([VERSION]) + salt + nonce + ct).decode("ascii")


def open_payload(payload: str, *, file_sha: str, page_hash: str, file_key: str, page: int, mode: str, variant: int) -> dict | None:
    """Klartext oder None (andere Datei, anderer Modus, andere Variante, kaputt): der Inhalt muss Seite, Abdruck, Modus
    und Variante des Datensatzes nennen."""
    try:
        raw = base64.b64decode(payload, validate=True)
        if len(raw) <= 1 + SALT_BYTES + NONCE_BYTES + 16 or raw[0] != VERSION:
            return None
        salt, nonce, ct = raw[1:1 + SALT_BYTES], raw[1 + SALT_BYTES:1 + SALT_BYTES + NONCE_BYTES], raw[1 + SALT_BYTES + NONCE_BYTES:]
        plain = AESGCM(_key(file_sha, page_hash, salt, page, mode)).decrypt(nonce, ct, _aad(file_key, page, mode, variant))
        d = json.loads(plain)
    except Exception:  # noqa: BLE001 - unlesbar gilt als nicht vorhanden
        return None
    if not isinstance(d, dict) or d.get("page") != page or d.get("pageHash") != page_hash or d.get("mode") != mode \
            or d.get("variant") != variant or not isinstance(d.get("text"), str) or not d["text"].strip():
        return None
    return d


# ---------------------------------------------------------------- Schluessel einer Seite auf diesem PC

def file_sha(file_id: str) -> str | None:
    """SHA-256 des Dokuments (files.content_sha256, sonst aus der Datei auf der Platte berechnet und gemerkt)."""
    from .testshare import file_sha256
    with db.cursor() as conn:
        r = db.row(conn, "SELECT content_sha256, local_path FROM files WHERE id=?", (file_id,))
        if not r:
            return None
        sha = (r.get("content_sha256") or "").lower()
        if _SHA.match(sha):
            return sha
        p = r.get("local_path")
        if not p or not Path(p).is_file():
            return None
        try:
            sha = file_sha256(Path(p))
        except OSError:
            return None
        if sha and _SHA.match(sha):
            conn.execute("UPDATE files SET content_sha256=? WHERE id=?", (sha, file_id))
            return sha
    return None


def page_keys(file_id: str, page: int, text: str) -> dict | None:
    from . import doc_index
    sha = file_sha(file_id)
    if not sha:
        return None
    return {"file_sha": sha, "file_key": doc_index.file_key(sha), "page_hash": doc_index.page_hash(text or "", sha, int(page))}


def usable(file_id: str | None, mode: str) -> bool:
    from . import ai_relay, config
    return bool(file_id) and mode in SHARED_MODES and not config.is_hosted() and ai_relay.linked()


# ---------------------------------------------------------------- Lesen und Veroeffentlichen

def lookup(file_id: str, page: int, mode: str, text: str) -> dict | None:
    """Niedrigste lesbare Variante beim Dienst: {answer, variant, created_at, model} oder None (auch offline)."""
    from . import ai_relay
    if not usable(file_id, mode):
        return None
    k = page_keys(file_id, page, text)
    if not k:
        return None
    try:
        d = ai_relay.service_json("GET", "/api/explain", query=urllib.parse.urlencode(
            {"file_key": k["file_key"], "page": int(page), "mode": mode}), timeout=15)
    except ai_relay.RelayError:
        return None
    for rec in sorted(d.get("records") or [], key=lambda r: int(r.get("variant") or 99)):
        if int(rec.get("version") or VERSION) != VERSION:
            continue
        plain = open_payload(str(rec.get("payload") or ""), file_sha=k["file_sha"], page_hash=k["page_hash"], file_key=k["file_key"],
                             page=int(page), mode=mode, variant=int(rec.get("variant") or 0))
        if plain:
            return {"answer": plain["text"], "variant": int(rec["variant"]), "created_at": rec.get("created_at") or plain.get("createdAt"),
                    "model": plain.get("model")}
    return None


def publish(file_id: str, page: int, mode: str, text: str, answer: str, model: str | None = None) -> int:
    """Antwort verschluesselt auf den naechsten freien Platz legen; Variante oder 0 (voll, offline, nicht erlaubt)."""
    from . import ai_relay, explain_local
    if not usable(file_id, mode):
        return 0
    body_text = explain_local.strip_marks(answer).strip()
    k = page_keys(file_id, page, text)
    if not body_text or not k:
        return 0
    try:
        d = ai_relay.service_json("GET", "/api/explain", query=urllib.parse.urlencode(
            {"file_key": k["file_key"], "page": int(page), "mode": mode}), timeout=15)
    except ai_relay.RelayError:
        return 0
    free = [int(v) for v in (d.get("free") or [])]
    for v in free:
        payload = seal(body_text, file_sha=k["file_sha"], page_hash=k["page_hash"], file_key=k["file_key"], page=int(page),
                       mode=mode, variant=v, model=model)
        try:
            ai_relay.service_json("POST", "/api/explain", {"file_key": k["file_key"], "page": int(page), "mode": mode,
                                                           "payload": payload, "version": VERSION, "variant": v}, timeout=15)
            return v
        except ai_relay.RelayError as e:
            if e.code == "explain_taken":
                continue                         # Wettlauf: naechster freier Platz (mit eigener Verschluesselung)
            return 0
    return 0


def publish_later(file_id: str, page: int, mode: str, text: str, answer: str, model: str | None = None) -> None:
    """Im Hintergrund veroeffentlichen: die Antwort ist schon auf dem Bildschirm, der Dienst darf langsam sein."""
    if not usable(file_id, mode):
        return
    threading.Thread(target=_quiet, args=(file_id, page, mode, text, answer, model), name="studinow-explain", daemon=True).start()


def _quiet(*args) -> None:
    try:
        publish(*args)
    except Exception:  # noqa: BLE001 - nur Zusatz
        pass


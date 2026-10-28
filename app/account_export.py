"""Datenexport eines Kontos (gehosteter Dienst, DSGVO Art. 15 Auskunft und Art. 20 Datenuebertragbarkeit, 28.10.2026).

`build(user)` schreibt eine ZIP-Datei in einen Temp-Ordner und liefert den Pfad; `GET /api/account/export` schickt sie
und loescht sie danach. Inhalt:

- `LIESMICH.txt`: was wo liegt
- `konto.json`: Konto, Sitzungen und Geraete, verknuepfte Anmeldewege, Tarife und Kaeufe, Nutzungszaehler, KI-Nutzung,
  Abgleich-Auftraege, gespeicherte Hochschul-Zugangsdaten (Name und Benutzername; Passwoerter, Schluessel und Cookies
  nur als "gespeichert", damit eine verlorene ZIP keine Zugaenge verraet)
- `daten/`: der Nutzerordner je Hochschule: Datenbanken (`lernapp.db`, konsistent ueber die SQLite-Sicherung kopiert)
  mit Kursen, Notizen, Kalender, Lernpaketen, Karteikarten, Tests, dazu eigene Dateien und Protokolle. Ohne
  Browser-Profile (Sitzungs-Cookies der Hochschule) und ohne Arbeitsordner der KI.
- `community/`: eigene Loesungen (Liste und Pakete), eigene Meldungen und Sperrliste
- `testbibliothek.json`: eigene Fragen in der gemeinsamen Testbibliothek
"""
from __future__ import annotations

import json
import sqlite3
import tempfile
import zipfile
from pathlib import Path

from . import accounts, config

SKIP_DIRS = ("browser-profile", "ai-tmp")
SECRET_HINT = "gespeichert (aus Sicherheitsgründen nicht im Export)"


def _rows(conn, sql: str, params=()) -> list[dict]:
    try:
        return [dict(r) for r in conn.execute(sql, params).fetchall()]
    except sqlite3.OperationalError:            # Tabelle gibt es (noch) nicht
        return []


def _account(user: dict) -> dict:
    from . import vault
    uid = user["id"]
    with accounts.cursor() as conn:
        out = {
            "konto": user,
            "sitzungen": accounts.sessions(uid),
            "anmeldewege": _rows(conn, "SELECT provider, subject, created_at FROM identities WHERE user_id=?", (uid,)),
            "kaeufe": _rows(conn, "SELECT source, plan, original_transaction_id, expires_at, status, will_renew, pending_plan, "
                                  "environment, updated_at FROM entitlements WHERE user_id=?", (uid,)),
            "apple_transaktionen": _rows(conn, "SELECT original_transaction_id, product_id, updated_at FROM apple_transactions WHERE user_id=?", (uid,)),
            "nutzung": _rows(conn, "SELECT period, feature, count FROM usage WHERE user_id=? ORDER BY period, feature", (uid,)),
            "ki_nutzung": _rows(conn, "SELECT period, purpose, provider, model, input_tokens, output_tokens, cost_microeur, state, "
                                      "created_at FROM ai_usage_log WHERE user_id=? ORDER BY created_at", (uid,)),
            "abgleich_auftraege": _rows(conn, "SELECT kind, trigger, status, requested_at, started_at, finished_at, message, new_files "
                                              "FROM sync_jobs WHERE user_id=? ORDER BY id", (uid,)),
        }
    creds = {}
    for name, value in sorted(vault.env_for(uid).items()):
        creds[name] = value if name.endswith("_USER") else SECRET_HINT
    out["hochschul_zugangsdaten"] = creds
    return out


def _add_db(z: zipfile.ZipFile, src: Path, arc: str) -> None:
    """SQLite-Datei konsistent kopieren (auch mit offenem WAL) und in die ZIP legen."""
    with tempfile.TemporaryDirectory() as tmp:
        dst = Path(tmp) / "kopie.db"
        a = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
        b = sqlite3.connect(dst)
        try:
            a.backup(b)
        finally:
            b.close()
            a.close()
        z.write(dst, arc)


def _add_user_dir(z: zipfile.ZipFile, base: Path) -> int:
    n = 0
    if not base.exists():
        return 0
    for p in sorted(base.rglob("*")):
        rel = p.relative_to(base)
        if any(part.startswith(SKIP_DIRS) for part in rel.parts) or not p.is_file():
            continue
        if p.name.endswith(("-wal", "-shm", ".lock")):
            continue
        arc = "daten/" + rel.as_posix()
        if p.suffix == ".db":
            _add_db(z, p, arc)
        else:
            z.write(p, arc)
        n += 1
    return n


def _community(z: zipfile.ZipFile, user: dict) -> int:
    from . import community
    sols = community.mine(user)
    with community.cursor() as conn:
        reports = _rows(conn, "SELECT solution_id, reason, note, created_at FROM reports WHERE reporter_id=?", (user["id"],))
        blocks = _rows(conn, "SELECT pseudonym, created_at FROM blocks WHERE user_id=?", (user["id"],))
    z.writestr("community/meine-loesungen.json", json.dumps(sols, ensure_ascii=False, indent=1))
    z.writestr("community/meine-meldungen.json", json.dumps(reports, ensure_ascii=False, indent=1))
    z.writestr("community/meine-sperrliste.json", json.dumps(blocks, ensure_ascii=False, indent=1))
    for s in sols:
        p = community.package_dir() / f"{s['solution_id']}.uniflowsolution"
        if p.exists():
            z.write(p, f"community/pakete/{p.name}")
    return len(sols)


def _library(user: dict) -> list[dict]:
    from . import test_library
    owner = test_library.owner_hash(user["id"])
    with test_library.cursor() as conn:
        return _rows(conn, "SELECT id, subject, topic, subtopic, qtype, question, options, answer, explanation, source, review, "
                           "created_at FROM questions WHERE owner_hash=? ORDER BY created_at", (owner,))


README = """Studora / UniFlow – Export deiner Daten

Erstellt: {at}
Konto: {email}

konto.json            Konto, angemeldete Geräte, Anmeldewege (Apple/Google), Tarife und Käufe, Nutzungszähler,
                      KI-Nutzung, Abgleich-Aufträge, gespeicherte Hochschul-Zugangsdaten (Passwörter, Schlüssel und
                      Cookies nur als „gespeichert“).
daten/                Deine Daten je Hochschule. lernapp.db ist eine SQLite-Datenbank (öffnen z. B. mit „DB Browser
                      for SQLite“): Kurse, Module, Notizen (Tabelle annotations), Stundenplan, Lernpakete, Aufgaben,
                      Karteikarten, Tests und Noten. Dazu eigene Dateien und Protokolle. Dateien deiner Hochschule
                      speichert der Dienst nicht; sie bleiben in Stud.IP bzw. im Learnweb.
community/            Deine veröffentlichten Lösungen (Liste und Pakete), deine Meldungen und deine Sperrliste.
testbibliothek.json   Deine Fragen in der gemeinsamen Testbibliothek.

Fragen zum Export oder zur Löschung: siehe /datenschutz.
"""


def build(user: dict) -> Path:
    """ZIP mit allen Daten des Kontos; der Aufrufer loescht die Datei nach dem Senden."""
    fd, name = tempfile.mkstemp(prefix="studora-export-", suffix=".zip")
    path = Path(name)
    import os
    os.close(fd)
    at = accounts.iso(accounts.now())
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED, allowZip64=True) as z:
        z.writestr("LIESMICH.txt", README.format(at=at, email=user["email"]))
        z.writestr("konto.json", json.dumps(_account(user), ensure_ascii=False, indent=1))
        _add_user_dir(z, config.BASE_DATA_DIR / "users" / user["id"])
        _community(z, user)
        z.writestr("testbibliothek.json", json.dumps(_library(user), ensure_ascii=False, indent=1))
    return path

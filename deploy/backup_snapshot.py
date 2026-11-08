"""Konsistenter Abzug des Datenordners als tar.gz auf stdout – laeuft IM Container (von deploy/backup.sh gestartet):

    docker compose exec -T app python - < deploy/backup_snapshot.py > uniflow-2026-10-27.tar.gz

SQLite-Datenbanken (accounts.db, users/<id>/lernapp.db, users/<id>/unis/<key>/lernapp.db, auch users-deleted/)
werden mit der Backup-API von sqlite3 kopiert (konsistent, auch waehrend der Dienst schreibt; WAL-Dateien werden
dabei eingearbeitet). Alle anderen Dateien (Notizen, assets/, qis/-Dokumente) kommen unveraendert mit.
Ausgelassen: Browser-Profile (gross, enthalten Hochschul-Sitzungen), files/ (im Dienst leer: LERNAPP_FILES=stream),
logs/, ai-tmp/, index-uploads/ (PDFs duerfen hoechstens 15 Minuten beim Dienst liegen, app/doc_index.py), WAL/SHM-Dateien
und secret.key – das Dienst-Geheimnis gehoert getrennt vom Backup aufbewahrt
(LERNAPP_SECRET_KEY in deploy/.env, siehe .env.example).

Umgebung: LERNAPP_DATA_DIR (Standard /data). Mit BACKUP_INCLUDE_KEY=1 kommt secret.key doch mit (nur, wenn kein
LERNAPP_SECRET_KEY gesetzt ist und das Backup selbst verschluesselt abgelegt wird).

Der Dienst laeuft waehrend des Backups weiter: Dateien, die zwischen Auflisten und Kopieren verschwinden (Loeschfristen,
ersetzte Assets, ein Konto zieht nach users-deleted/ um), werden uebersprungen und gezaehlt, statt das ganze Backup
abzubrechen (Audit P51-10, 08.11.2026).
"""
from __future__ import annotations

import io
import os
import sqlite3
import sys
import tarfile
import tempfile
from datetime import datetime, timezone
from pathlib import Path

DATA = Path(os.environ.get("LERNAPP_DATA_DIR") or "/data")
SKIP_DIRS = {"browser-profile", "browser-profile-qis", "files", "logs", "ai-tmp", "index-uploads", "__pycache__"}
SKIP_SUFFIXES = (".db-wal", ".db-shm", ".db-journal", ".tmp")
PREFIX = "uniflow-data"


def snapshot_db(src: Path, tmpdir: Path, n: int) -> Path | None:
    """Kopie per Backup-API in einem Schritt (pages=-1: eine Lesesperre, Schreiber laufen weiter, kein Neustart der
    Kopie). None, wenn die Datei inzwischen verschwunden ist."""
    dst = tmpdir / f"{n:05d}-{src.name}"
    # `with` auf einer sqlite3-Verbindung schliesst sie nicht (nur commit) – ausdruecklich schliessen, sonst bleibt die
    # Kopie offen, bis der Prozess endet
    try:
        conn = sqlite3.connect(f"file:{src.as_posix()}?mode=ro", uri=True, timeout=30)
    except sqlite3.OperationalError:
        if not src.exists():
            return None
        raise
    out = sqlite3.connect(dst)
    try:
        conn.backup(out)
    finally:
        out.close()
        conn.close()
    return dst


def main() -> int:
    if not DATA.is_dir():
        print(f"Datenordner fehlt: {DATA}", file=sys.stderr)
        return 2
    include_key = os.environ.get("BACKUP_INCLUDE_KEY") == "1"
    n_db = n_files = vanished = 0
    out = sys.stdout.buffer
    with tempfile.TemporaryDirectory(prefix="uniflow-backup-") as tmp, tarfile.open(fileobj=out, mode="w|gz") as tar:
        tmpdir = Path(tmp)
        meta = (f"created={datetime.now(timezone.utc).isoformat(timespec='seconds')}\n"
                f"data_dir={DATA}\nsecret_key_included={'yes' if include_key else 'no'}\n").encode()
        info = tarfile.TarInfo(f"{PREFIX}/BACKUP-INFO.txt")
        info.size, info.mtime = len(meta), int(datetime.now().timestamp())
        tar.addfile(info, io.BytesIO(meta))
        for root, dirs, files in os.walk(DATA):
            dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS and not d.startswith("browser-profile"))
            for name in sorted(files):
                p = Path(root) / name
                rel = p.relative_to(DATA).as_posix()
                if name.endswith(SKIP_SUFFIXES) or (name == "secret.key" and not include_key):
                    continue
                if name.endswith(".db"):
                    snap = snapshot_db(p, tmpdir, n_db + 1)
                    if snap is None:
                        vanished += 1
                        continue
                    n_db += 1
                    tar.add(snap, arcname=f"{PREFIX}/{rel}")
                    snap.unlink(missing_ok=True)       # sonst liegen bis zum Ende ALLE Kopien im Container (4.000 Konten: >1 GB)
                else:
                    try:
                        tar.add(p, arcname=f"{PREFIX}/{rel}", recursive=False)
                    except FileNotFoundError:          # zwischen Auflisten und Kopieren geloescht
                        vanished += 1
                        continue
                    n_files += 1
    print(f"Backup: {n_db} Datenbanken, {n_files} weitere Dateien aus {DATA}"
          + (f", {vanished} waehrenddessen geloeschte uebersprungen" if vanished else ""), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

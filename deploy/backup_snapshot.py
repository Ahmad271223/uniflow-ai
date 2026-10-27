"""Konsistenter Abzug des Datenordners als tar.gz auf stdout – laeuft IM Container (von deploy/backup.sh gestartet):

    docker compose exec -T app python - < deploy/backup_snapshot.py > uniflow-2026-10-27.tar.gz

SQLite-Datenbanken (accounts.db, users/<id>/lernapp.db, users/<id>/unis/<key>/lernapp.db, auch users-deleted/)
werden mit der Backup-API von sqlite3 kopiert (konsistent, auch waehrend der Dienst schreibt; WAL-Dateien werden
dabei eingearbeitet). Alle anderen Dateien (Notizen, assets/, qis/-Dokumente) kommen unveraendert mit.
Ausgelassen: Browser-Profile (gross, enthalten Hochschul-Sitzungen), files/ (im Dienst leer: LERNAPP_FILES=stream),
logs/, ai-tmp/, WAL/SHM-Dateien und secret.key – das Dienst-Geheimnis gehoert getrennt vom Backup aufbewahrt
(LERNAPP_SECRET_KEY in deploy/.env, siehe .env.example).

Umgebung: LERNAPP_DATA_DIR (Standard /data). Mit BACKUP_INCLUDE_KEY=1 kommt secret.key doch mit (nur, wenn kein
LERNAPP_SECRET_KEY gesetzt ist und das Backup selbst verschluesselt abgelegt wird).
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
SKIP_DIRS = {"browser-profile", "browser-profile-qis", "files", "logs", "ai-tmp", "__pycache__"}
SKIP_SUFFIXES = (".db-wal", ".db-shm", ".db-journal", ".tmp")
PREFIX = "uniflow-data"


def snapshot_db(src: Path, tmpdir: Path, n: int) -> Path:
    dst = tmpdir / f"{n:05d}-{src.name}"
    # `with` auf einer sqlite3-Verbindung schliesst sie nicht (nur commit) – ausdruecklich schliessen, sonst bleibt die
    # Kopie offen, bis der Prozess endet
    conn = sqlite3.connect(f"file:{src.as_posix()}?mode=ro", uri=True, timeout=30)
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
    n_db = n_files = 0
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
                    n_db += 1
                    tar.add(snapshot_db(p, tmpdir, n_db), arcname=f"{PREFIX}/{rel}")
                else:
                    tar.add(p, arcname=f"{PREFIX}/{rel}", recursive=False)
                    n_files += 1
    print(f"Backup: {n_db} Datenbanken, {n_files} weitere Dateien aus {DATA}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

"""Loeschfristen des gehosteten Dienstes (Datenschutzerklaerung, Abschnitte 5, 10 und 15), als taeglicher Dienst-Job.

- Zugriffsprotokoll: der Dienst schreibt je Tag eine Datei `<BASE_LOG_DIR>/access/access-YYYY-MM-DD.log`
  (Zeit, IP, Methode, Pfad ohne Abfrageteil, Status, Dauer, Browser-Kennung; nie Tokens, nie Inhalte). Dateien
  aelter als ACCESS_DAYS (14) werden geloescht. Der Dienst sollte daher ohne das Zugriffsprotokoll von uvicorn laufen
  (`--no-access-log`), sonst gilt die Frist dort nicht.
- Abgleich-Protokolle je Konto (`users/<id>/logs`, `users/<id>/unis/<key>/logs`: sync.log, qis.log, Fehlerbilder)
  und die Tabelle `sync_log` in der Kontodatenbank: aelter als SYNC_DAYS (90) weg; sync.log/qis.log werden
  zeilenweise gekuerzt. Dazu `sync_jobs` und `schedule_marks` in accounts.db.
- Konto: abgelaufene oder beendete Sitzungen, verbrauchte oder abgelaufene Reset-Token, alte Fehlversuchszaehler,
  und `accounts.purge_deleted(30)` (Konten 30 Tage nach der Loeschung endgueltig weg). Anfrage-IDs der Kontingente
  (`usage_requests`) aelter als der Vormonat.

Zeitplan: einmal taeglich ab RETENTION_TIME (`LERNAPP_RETENTION_TIME`, Standard 04:00, Ortszeit), gemerkt in
`schedule_marks` wie die Abgleich-Zeitfenster. Von Hand: `python -m app.retention [--dry-run]`.
"""
from __future__ import annotations

import json
import os
import re
import sqlite3
import sys
import threading
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

from . import accounts, config

ACCESS_DAYS = int(os.environ.get("LERNAPP_RETENTION_ACCESS_DAYS") or 14)
SYNC_DAYS = int(os.environ.get("LERNAPP_RETENTION_SYNC_DAYS") or 90)
PURGE_DAYS = 30                                        # wie accounts.purge_deleted
ATTEMPT_HOURS = 24                                     # Fehlversuchszaehler (wirksam nur 10 Minuten) spaetestens dann weg
RETENTION_TIME = (os.environ.get("LERNAPP_RETENTION_TIME") or "04:00").strip()
_ACCESS_NAME = re.compile(r"^access-(\d{4}-\d{2}-\d{2})\.log$")
_DATED_LINE = re.compile(r"^\[?(\d{4}-\d{2}-\d{2})")
_lock = threading.Lock()


# ---------------------------------------------------------------- Zugriffsprotokoll

def access_log_dir() -> Path:
    return config.BASE_LOG_DIR / "access"


_CONTROL = re.compile(r"[\x00-\x1f\x7f]+")


def _field(s) -> str:
    """Ein Feld des Zugriffsprotokolls: Steuerzeichen (Zeilenumbrueche, Tabs) werden zu einem Leerzeichen. Der Pfad
    kommt prozent-dekodiert an (%0A = Zeilenumbruch), eine Anfrage konnte so eine gefaelschte Zeile anhaengen
    (Audit 08.11.2026, Paket 3 Nr. 86)."""
    return _CONTROL.sub(" ", str(s or ""))


def log_access(ip: str, method: str, path: str, status: int, ms: float, user_agent: str = "", now: datetime | None = None) -> None:
    """Eine Zeile ins Tagesprotokoll; der Pfad ohne Abfrageteil (keine Fingerabdruecke oder Suchbegriffe)."""
    now = (now or datetime.now(timezone.utc)).replace(microsecond=0)
    ua = _field(user_agent).replace('"', "'")[:120]
    line = (f'{now.strftime("%Y-%m-%dT%H:%M:%SZ")} {_field(ip) or "-"} {_field(method)} {_field(path.split("?")[0])} '
            f'{status} {ms:.0f}ms "{ua}"\n')
    d = access_log_dir()
    with _lock:
        d.mkdir(parents=True, exist_ok=True)
        with open(d / f"access-{now.strftime('%Y-%m-%d')}.log", "a", encoding="utf-8") as f:
            f.write(line)


def purge_access_logs(today: date, days: int = ACCESS_DAYS, dry_run: bool = False) -> int:
    d = access_log_dir()
    if not d.exists():
        return 0
    cutoff = today - timedelta(days=days)
    n = 0
    for p in d.iterdir():
        m = _ACCESS_NAME.match(p.name)
        if not m:
            continue
        try:
            day = date.fromisoformat(m.group(1))
        except ValueError:                      # z. B. access-2026-99-99.log: kein Datum, nicht unsere Datei (Audit Nr. 87)
            continue
        if day < cutoff:
            if not dry_run:
                p.unlink(missing_ok=True)
            n += 1
    return n


# ---------------------------------------------------------------- Abgleich-Protokolle je Konto

def account_dirs() -> list[Path]:
    """Alle Kontoordner mit eigener Datenbank: users/<id> und users/<id>/unis/<key>."""
    base = config.BASE_DATA_DIR / "users"
    if not base.exists():
        return []
    out = []
    for u in sorted(base.iterdir()):
        if u.is_dir():
            out.append(u)
            unis = u / "unis"
            if unis.exists():
                out.extend(sorted(p for p in unis.iterdir() if p.is_dir()))
    return out


def trim_dated_log(path: Path, cutoff_day: date, dry_run: bool = False) -> int:
    """Zeilen mit Datum vor dem Stichtag entfernen (Folgezeilen ohne Datum gehoeren zur vorigen). Liefert entfernte Zeilen."""
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines(keepends=True)
    except OSError:
        return 0
    keep, drop, dropping = [], 0, False
    for line in lines:
        m = _DATED_LINE.match(line)
        if m:
            try:
                dropping = date.fromisoformat(m.group(1)) < cutoff_day
            except ValueError:
                pass                            # sieht aus wie ein Datum, ist keins: gehoert zur vorigen Zeile (Audit Nr. 89)
        if dropping:
            drop += 1
        else:
            keep.append(line)
    if drop and not dry_run:
        tmp = path.with_suffix(path.suffix + ".tmp")
        try:
            tmp.write_text("".join(keep), encoding="utf-8")
            os.replace(tmp, path)
        except OSError:
            tmp.unlink(missing_ok=True)         # keine .tmp-Leiche; das Original bleibt unveraendert
            raise
    return drop


def purge_account_logs(now: datetime, days: int = SYNC_DAYS, dry_run: bool = False) -> dict:
    """Je Konto: Logdateien kuerzen bzw. loeschen und sync_log/sync_ops bereinigen. Ein Fehler in einem Konto wird
    protokolliert und gezaehlt (`errors`), die uebrigen Konten laufen weiter (Audit 08.11.2026, Paket 3 Nr. 90)."""
    import logging
    cutoff_day = (now - timedelta(days=days)).date()
    cutoff_ts = now - timedelta(days=days)
    # Stichtag fuer die Datenbank in UTC (naiv): run() liefert UTC; ein anderer Aufrufer mit Zeitzone wird umgerechnet
    cutoff_utc = cutoff_ts.astimezone(timezone.utc) if cutoff_ts.tzinfo else cutoff_ts
    cutoff_iso = cutoff_utc.replace(tzinfo=None).isoformat(timespec="seconds")
    out = {"files": 0, "lines": 0, "rows": 0, "errors": 0}
    for d in account_dirs():
        try:
            logs = d / "logs"
            if logs.exists():
                for p in logs.iterdir():
                    if not p.is_file():
                        continue
                    if p.suffix == ".log":
                        out["lines"] += trim_dated_log(p, cutoff_day, dry_run)
                    elif datetime.fromtimestamp(p.stat().st_mtime, tz=timezone.utc) < cutoff_ts:
                        if not dry_run:
                            p.unlink(missing_ok=True)
                        out["files"] += 1
            db_file = d / "lernapp.db"
            if db_file.exists():
                out["rows"] += _purge_sync_log(db_file, cutoff_iso, dry_run)
        except Exception:  # noqa: BLE001 - ein Konto haelt die anderen nicht auf
            out["errors"] += 1
            logging.getLogger("uniflow.retention").exception("Loeschfristen fuer %s nicht angewendet", d)
    return out


def _purge_sync_log(db_file: Path, cutoff_iso: str, dry_run: bool) -> int:
    """sync_log-Zeilen (Ortszeit-ISO wie db.now_iso) vor dem Stichtag; fehlende Tabelle = nichts zu tun."""
    conn = sqlite3.connect(db_file)
    try:
        n = 0
        if conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='sync_ops'").fetchone():
            # Operations-IDs des Geraete-Abgleichs (UTC mit Z): nach derselben Frist weg
            utc_cut = cutoff_iso[:19] + "Z"
            k = conn.execute("SELECT COUNT(*) FROM sync_ops WHERE created_at < ?", (utc_cut,)).fetchone()[0]
            if k and not dry_run:
                conn.execute("DELETE FROM sync_ops WHERE created_at < ?", (utc_cut,))
                conn.commit()
            n += k
        if not conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='sync_log'").fetchone():
            return n
        k = conn.execute("SELECT COUNT(*) FROM sync_log WHERE COALESCE(started_at, finished_at, '') < ?", (cutoff_iso,)).fetchone()[0]
        if k and not dry_run:
            conn.execute("DELETE FROM sync_log WHERE COALESCE(started_at, finished_at, '') < ?", (cutoff_iso,))
            conn.commit()
        return n + k
    finally:
        conn.close()


# ---------------------------------------------------------------- accounts.db: Jobs, Sitzungen, Token, Zaehler

def purge_account_db(now: datetime, days: int = SYNC_DAYS, dry_run: bool = False) -> dict:
    cutoff = accounts.iso(now - timedelta(days=days))
    now_iso = accounts.iso(now)
    attempts_cutoff = accounts.iso(now - timedelta(hours=ATTEMPT_HOURS))
    out = {}
    with accounts.cursor() as conn:
        conn.executescript("""CREATE TABLE IF NOT EXISTS sync_jobs (id INTEGER PRIMARY KEY, user_id TEXT, kind TEXT, trigger TEXT, status TEXT,
                              requested_at TEXT, started_at TEXT, finished_at TEXT, message TEXT, new_files INTEGER);
                              CREATE TABLE IF NOT EXISTS schedule_marks (slot TEXT PRIMARY KEY, created_at TEXT NOT NULL);""")
        conn.executescript(accounts.SCHEMA)
        rules = {
            "jobs": ("sync_jobs", "status IN ('done','failed') AND requested_at < ?", (cutoff,)),
            "marks": ("schedule_marks", "created_at < ?", (cutoff,)),
            "sessions": ("sessions", "expires_at <= ? OR revoked_at IS NOT NULL", (now_iso,)),
            "reset_tokens": ("reset_tokens", "expires_at <= ? OR used_at IS NOT NULL", (now_iso,)),
            "login_attempts": ("login_attempts", "last_fail_at IS NULL OR last_fail_at < ?", (attempts_cutoff,)),
            "verify_tokens": ("verify_tokens", "expires_at <= ? OR used_at IS NOT NULL", (now_iso,)),
            "rate_limits": ("rate_limits", "window_start < ?", (accounts.iso(now - timedelta(days=2)),)),
        }
        # Anfrage-IDs der Kontingente (app/billing.py): gebraucht nur im laufenden Monat (Doppelte) und im vorigen
        # (refund ueber die Monatsgrenze); die Zaehler in `usage` bleiben (Audit P21-05)
        if conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='usage_requests'").fetchone():
            first = now.astimezone(timezone.utc).replace(day=1)
            prev = (first - timedelta(days=1)).strftime("%Y-%m")
            rules["usage_requests"] = ("usage_requests", "period < ?", (prev,))
        for key, (table, where, params) in rules.items():
            n = conn.execute(f"SELECT COUNT(*) FROM {table} WHERE {where}", params).fetchone()[0]
            if n and not dry_run:
                conn.execute(f"DELETE FROM {table} WHERE {where}", params)
            out[key] = n
    if dry_run:
        with accounts.cursor() as conn:
            out["accounts_purged"] = conn.execute("SELECT COUNT(*) FROM users WHERE status='deleted' AND deleted_at<=?",
                                                  (accounts.iso(now - timedelta(days=PURGE_DAYS)),)).fetchone()[0]
    else:
        out["accounts_purged"] = accounts.purge_deleted(PURGE_DAYS)
    return out


# ---------------------------------------------------------------- Lauf und Zeitplan

def run(now: datetime | None = None, dry_run: bool = False) -> dict:
    """Alle Fristen anwenden; liefert die Zaehler (auch im Probelauf)."""
    now = (now or datetime.now(timezone.utc)).replace(microsecond=0)
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)
    result = {"at": accounts.iso(now), "dry_run": dry_run, "access_files": purge_access_logs(now.date(), dry_run=dry_run),
              "account_logs": purge_account_logs(now, dry_run=dry_run), **purge_account_db(now, dry_run=dry_run)}
    if not dry_run and (config.BASE_DATA_DIR / "community.db").exists():
        from . import community_qa                     # gelesene Benachrichtigungen nach 90 Tagen (Community Teil 2)
        result["notifications"] = community_qa.prune()
    if not dry_run:
        p = config.BASE_LOG_DIR / "retention.log"
        p.parent.mkdir(parents=True, exist_ok=True)
        with open(p, "a", encoding="utf-8") as f:
            f.write(json.dumps(result, ensure_ascii=False) + "\n")
        trim_dated_log(p, (now - timedelta(days=365)).date())
    return result


def _parse_time(t: str) -> tuple[int, int]:
    try:
        h, m = t.split(":")
        if 0 <= int(h) < 24 and 0 <= int(m) < 60:
            return int(h), int(m)
    except ValueError:
        pass
    return 4, 0


RETRY_AFTER_MIN = 60     # nach einem fehlgeschlagenen Tageslauf: so lange Pause, dann erneut am selben Tag


def schedule_due(now: datetime | None = None) -> dict | None:
    """Einmal am Tag ab RETENTION_TIME (Ortszeit) laufen; Merkmal `retention:YYYY-MM-DD` in schedule_marks.

    Das Merkmal steht vor `run()` (Reservierung gegen Doppellaeufe). Wirft `run()` eine Ausnahme, faellt es wieder
    und `retention:YYYY-MM-DD:failed` merkt den Fehlversuch: nach RETRY_AFTER_MIN Minuten laeuft der Tag erneut statt
    erst am naechsten Tag (Audit 08.11.2026, P4-01) - und nicht alle 30 s im Takt des Zeitplans."""
    from . import jobs
    local = now or datetime.now()
    h, m = _parse_time(RETENTION_TIME)
    if (local.hour, local.minute) < (h, m):
        return None
    slot = f"retention:{local.strftime('%Y-%m-%d')}"
    stamp = accounts.iso(local.astimezone(timezone.utc))
    retry_from = accounts.iso((local - timedelta(minutes=RETRY_AFTER_MIN)).astimezone(timezone.utc))
    cm, conn = jobs._conn()
    try:
        if conn.execute("SELECT 1 FROM schedule_marks WHERE slot=?", (slot,)).fetchone():
            return None
        failed = conn.execute("SELECT created_at FROM schedule_marks WHERE slot=?", (slot + ":failed",)).fetchone()
        if failed and failed["created_at"] > retry_from:
            return None
        conn.execute("INSERT OR REPLACE INTO schedule_marks(slot, created_at) VALUES (?,?)", (slot, stamp))
    finally:
        cm.__exit__(None, None, None)
    try:
        result = run()
    except BaseException:
        cm, conn = jobs._conn()
        try:
            conn.execute("DELETE FROM schedule_marks WHERE slot=?", (slot,))
            conn.execute("INSERT OR REPLACE INTO schedule_marks(slot, created_at) VALUES (?,?)", (slot + ":failed", stamp))
        finally:
            cm.__exit__(None, None, None)
        raise
    print(f"[retention] {json.dumps(result, ensure_ascii=False)}")
    return result


def main(argv: list[str]) -> int:
    """python -m app.retention [--dry-run]: Fristen jetzt anwenden (auch im Einzelplatzmodus auf den Datenordner)."""
    result = run(dry_run="--dry-run" in argv)
    print(json.dumps(result, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

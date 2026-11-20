"""Kandidaten der StudiNow-Wissensbank pruefen (Betrieb, Auftrag des Inhabers 20.11.2026, app/wissensbank.py).

Ein Kandidat ist eine KI-Antwort, die ein Nutzer nach einer Wiederholung "besser" fand ("Gefaellt dir diese Antwort
besser?" -> Ja). Er steht ohne Konto und ohne Frage in accounts.db (wissensbank_candidates), Status ungeprueft. Erst nach
der Freigabe kann ihn ein anderer Nutzer bekommen (Regel in wissensbank.choose).

Aufruf im Container (deploy/, docs/release/BETRIEB.md):
  docker compose exec app python -m app.wissensbank_pruefen --liste                 offene Kandidaten (ungeprueft)
  docker compose exec app python -m app.wissensbank_pruefen --liste --status alle
  docker compose exec app python -m app.wissensbank_pruefen --zeigen 12             Antwort und Stelle der Bibliothek
  docker compose exec app python -m app.wissensbank_pruefen --freigeben 12
  docker compose exec app python -m app.wissensbank_pruefen --ablehnen 12
  docker compose exec app python -m app.wissensbank_pruefen --waehlen 'explain:Fach/G0001/01#Q1-Seite-3' --antwort 12
        (--antwort bibliothek | <Kandidat-ID> | auto: was diese Stelle ausliefert; auto = Regel nach Stimmen)
  docker compose exec app python -m app.wissensbank_pruefen --bibliothek            Stand des Ordners (Einheiten, Abschnitte)
Rueckgabe 0 = erledigt, 1 = nicht gefunden, 2 = falsche Argumente.
"""
from __future__ import annotations

import argparse
import sys
from datetime import datetime, timezone

from . import wissensbank


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="wissensbank-pruefen", description="Kandidaten der StudiNow-Wissensbank pruefen und freigeben.")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--liste", action="store_true", help="Kandidaten auflisten")
    g.add_argument("--zeigen", type=int, metavar="ID", help="einen Kandidaten ganz zeigen")
    g.add_argument("--freigeben", type=int, metavar="ID", help="Kandidaten freigeben (geprueft)")
    g.add_argument("--ablehnen", type=int, metavar="ID", help="Kandidaten ablehnen")
    g.add_argument("--waehlen", metavar="SCHLUESSEL", help="Antwort einer Stelle festlegen (mit --antwort)")
    g.add_argument("--bibliothek", action="store_true", help="Stand der Bibliothek im Ordner")
    p.add_argument("--status", default="ungeprueft", choices=("ungeprueft", "geprueft", "abgelehnt", "alle"))
    p.add_argument("--antwort", metavar="bibliothek|ID|auto")
    return p


def _row(conn, cid: int):
    return conn.execute("SELECT id, wb_key, answer, model, created_at, votes_yes, status, reviewed_at FROM wissensbank_candidates "
                        "WHERE id=?", (cid,)).fetchone()


def _library_text(key: str) -> str:
    """Text der Bibliothek zur Stelle (zum Vergleich beim Pruefen)."""
    lib = wissensbank.library()
    if lib is None or ":" not in key:
        return ""
    _mode, rest = key.split(":", 1)
    try:
        fach, uid, sids = rest.split("/", 2)
    except ValueError:
        return ""
    unit = lib.unit(fach, uid)
    if unit is None:
        return ""
    wanted = sids.split("+")
    secs = [s for s in unit.sections if s.sid in wanted]
    return wissensbank.answer_text(unit, secs)


def main(argv: list[str] | None = None, out=sys.stdout) -> int:
    try:
        args = parser().parse_args(argv)
    except SystemExit as e:
        return 2 if e.code else 0
    now = datetime.now(timezone.utc).isoformat()
    if args.bibliothek:
        lib = wissensbank.library()
        if lib is None:
            print(f"Keine Bibliothek in {wissensbank.directory()} (katalog.json fehlt).", file=out)
            return 1
        units = list(lib.entries)
        secs = explicit = 0
        for fach, uid in units:
            u = lib.unit(fach, uid)
            secs += len(u.sections)
            explicit += sum(1 for s in u.sections if s.explicit)
        print(f"Stand {lib.stand}: {len(lib.by_fach)} Fächer, {len(units)} Einheiten, {secs} Abschnitte, davon {explicit} mit "
              f"Folien-/Aufgabentext. Schalter LERNAPP_WISSENSBANK: {'an' if wissensbank.switched_on() else 'aus'}.", file=out)
        return 0
    conn = wissensbank.connect()
    try:
        if args.liste:
            where, params = ("", ()) if args.status == "alle" else ("WHERE status=?", (args.status,))
            rows = conn.execute(f"SELECT id, wb_key, status, votes_yes, model, created_at, substr(answer, 1, 80) "
                                f"FROM wissensbank_candidates {where} ORDER BY id", params).fetchall()
            if not rows:
                print("Keine Kandidaten.", file=out)
            for r in rows:
                status = wissensbank.STATUS_TEXT.get(r[2], r[2])
                snippet = " ".join(str(r[6]).split())
                print(f"#{r[0]}  {status:<10} Ja: {r[3]:<3} {r[5][:16]}  {r[4] or '-'}\n     {r[1]}\n     {snippet}…", file=out)
            return 0
        if args.zeigen is not None:
            r = _row(conn, args.zeigen)
            if not r:
                print(f"Kandidat #{args.zeigen} gibt es nicht.", file=out)
                return 1
            print(f"Kandidat #{r[0]} ({wissensbank.STATUS_TEXT.get(r[6], r[6])}, {r[5]}x Ja, Modell {r[3] or '-'}, {r[4]})\n"
                  f"Stelle: {r[1]}\n\n--- KI-Antwort ---\n{r[2]}\n\n--- Bibliothek ---\n{_library_text(r[1]) or '(nicht gefunden)'}", file=out)
            return 0
        if args.freigeben is not None or args.ablehnen is not None:
            cid = args.freigeben if args.freigeben is not None else args.ablehnen
            status = "geprueft" if args.freigeben is not None else "abgelehnt"
            cur = conn.execute("UPDATE wissensbank_candidates SET status=?, reviewed_at=? WHERE id=?", (status, now, cid))
            conn.commit()
            if not cur.rowcount:
                print(f"Kandidat #{cid} gibt es nicht.", file=out)
                return 1
            print(f"Kandidat #{cid}: {wissensbank.STATUS_TEXT[status]}.", file=out)
            return 0
        if args.waehlen:
            a = (args.antwort or "").strip().lower()
            if a not in ("bibliothek", "auto") and not a.isdigit():
                print("--antwort bibliothek | <Kandidat-ID> | auto", file=out)
                return 2
            if a.isdigit() and not conn.execute("SELECT 1 FROM wissensbank_candidates WHERE id=? AND wb_key=?", (int(a), args.waehlen)).fetchone():
                print(f"Kandidat #{a} gehört nicht zu dieser Stelle.", file=out)
                return 1
            conn.execute("INSERT INTO wissensbank_keys(wb_key, choice, updated_at) VALUES (?,?,?) "
                         "ON CONFLICT(wb_key) DO UPDATE SET choice=excluded.choice, updated_at=excluded.updated_at",
                         (args.waehlen, None if a == "auto" else a, now))
            conn.commit()
            print(f"Stelle {args.waehlen}: {'Regel nach Stimmen' if a == 'auto' else a}.", file=out)
            return 0
    finally:
        conn.close()
    return 2


if __name__ == "__main__":
    raise SystemExit(main())

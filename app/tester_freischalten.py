"""TestFlight-Tester freischalten (Betrieb, 08.11.2026): die Probe des StudiNow-Kontos verlaengern.

Hintergrund (docs/release/TESTFLIGHT-500-2026-11-08.md): Die 7-Tage-Probe auf dem iPad (LocalTrial.swift) gibt es
hoechstens einmal je Geraet; wer die TestFlight-Fassung laenger testet, hat sie verbraucht – auch fuer die spaetere
Store-Fassung auf demselben iPad. Der Inhaber will, dass Tester die App vollstaendig pruefen koennen. Der kleinste Weg
ohne App-Aenderung: die Probe des StudiNow-KONTOS im Dienst verlaengern (billing.extend_trial). Das iPad uebernimmt eine
laufende Probe des Dienstes mit Vorrang vor der eigenen (UFPlanPrecedence: Dienst > App Store > iPad-Probe > Free),
also Pro-AI-Umfang samt Apple Pencil, Community und StudiNow-KI mit den Probe-Credits (LERNAPP_CREDITS_TRIAL, 25).
Voraussetzung: die Person ist in der App beim StudiNow-Konto angemeldet (Einstellungen -> Zugang & Darstellung ->
StudiNow-Konto). Ein bezahltes oder in der Sandbox gekauftes Abo bleibt unberuehrt (hoechster aktiver Tarif gilt).

Aufruf im Container (deploy/, docs/release/BETRIEB.md):
  docker compose exec app python -m app.tester_freischalten --email tester@beispiel.de [--email ...] --tage 14
  docker compose exec app python -m app.tester_freischalten --registriert-seit 2026-11-08 [--registriert-bis 2026-11-30] --bis 2026-12-07
Ohne --ausfuehren wird nur angezeigt, was geschaehe (Probelauf). Aus dem Repository: python tools/tester-freischalten.py …
Ein Konto, das es nicht gibt oder das geloescht ist, wird genannt und uebersprungen; Rueckgabe 1, wenn kein Konto
freigeschaltet wurde, 2 bei falschen Argumenten.
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

from . import accounts, billing

TZ = ZoneInfo("Europe/Berlin")
DEFAULT_DAYS = 14


def _date(s: str) -> date:
    try:
        return date.fromisoformat(s)
    except ValueError:
        raise argparse.ArgumentTypeError(f"kein Datum (JJJJ-MM-TT): {s}")


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="tester-freischalten", description="Probe des StudiNow-Kontos fuer Tester verlaengern.",
                                epilog="Ohne --ausfuehren nur anzeigen. Ende: --tage N (ab jetzt) oder --bis JJJJ-MM-TT (einschliesslich, Europe/Berlin).")
    who = p.add_argument_group("Konten")
    who.add_argument("--email", action="append", default=[], metavar="ADRESSE", help="Konto mit dieser E-Mail-Adresse (mehrfach moeglich)")
    who.add_argument("--registriert-seit", type=_date, metavar="JJJJ-MM-TT", help="alle Konten, die ab diesem Tag angelegt wurden")
    who.add_argument("--registriert-bis", type=_date, metavar="JJJJ-MM-TT", help="… und hoechstens bis einschliesslich diesem Tag")
    when = p.add_mutually_exclusive_group()
    when.add_argument("--tage", type=int, metavar="N", help=f"Probe laeuft N Tage ab jetzt (Standard {DEFAULT_DAYS})")
    when.add_argument("--bis", type=_date, metavar="JJJJ-MM-TT", help="Probe laeuft bis einschliesslich diesem Tag")
    p.add_argument("--ausfuehren", action="store_true", help="wirklich schreiben (sonst Probelauf)")
    return p


def trial_end(args: argparse.Namespace, now: datetime) -> datetime:
    if args.bis is not None:
        return datetime.combine(args.bis, time(23, 59, 59), tzinfo=TZ).astimezone(timezone.utc)
    days = args.tage if args.tage is not None else DEFAULT_DAYS
    if days <= 0:
        raise ValueError("--tage muss groesser als 0 sein.")
    return (now + timedelta(days=days)).replace(microsecond=0)


def select_users(emails: list[str], since: date | None, until: date | None) -> tuple[list[dict], list[str]]:
    """Aktive Konten nach E-Mail und/oder Anlegezeitraum; dazu die Adressen ohne (aktives) Konto."""
    found: dict[str, dict] = {}
    missing: list[str] = []
    with accounts.cursor() as conn:
        for e in emails:
            r = conn.execute("SELECT id, email, created_at, plan, plan_until, status FROM users WHERE email=?",
                             (accounts.normalize_email(e),)).fetchone()
            if r and r["status"] == "active":
                found[r["id"]] = dict(r)
            else:
                missing.append(e)
        if since is not None:
            lo = f"{since.isoformat()}T00:00:00Z"
            hi = f"{(until + timedelta(days=1)).isoformat()}T00:00:00Z" if until is not None else "9999"
            for r in conn.execute("SELECT id, email, created_at, plan, plan_until, status FROM users "
                                  "WHERE status='active' AND created_at >= ? AND created_at < ? ORDER BY created_at", (lo, hi)):
                found[r["id"]] = dict(r)
    return list(found.values()), missing


def run(argv: list[str], now: datetime | None = None, out=None) -> int:
    out = out or sys.stdout
    p = parser()
    args = p.parse_args(argv)
    if not args.email and args.registriert_seit is None:
        p.print_usage(out)
        print("Bitte --email oder --registriert-seit angeben.", file=out)
        return 2
    t = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    try:
        ends = trial_end(args, t)
        if ends <= t:
            raise ValueError("Das Ende der Probe liegt nicht in der Zukunft.")
    except ValueError as e:
        print(str(e), file=out)
        return 2
    users, missing = select_users(args.email, args.registriert_seit, args.registriert_bis)
    for e in missing:
        print(json.dumps({"email": e, "ergebnis": "kein aktives Konto"}, ensure_ascii=False), file=out)
    done = 0
    conn = billing.connect()
    try:
        for u in users:
            before = billing.trial_info(conn, u["id"], t)
            row = {"email": u["email"], "angelegt": u["created_at"], "tarif_vorher": billing.current_plan(conn, u["id"], t, {"plan": u["plan"], "plan_until": u["plan_until"]}),
                   "probe_vorher": "keine" if not before["granted"] else ("laeuft bis " + before["ends_at"] if before["active"] else "vorbei seit " + before["ends_at"])}
            if args.ausfuehren:
                r = billing.extend_trial(conn, u["id"], ends, now=t)
                row.update({"ergebnis": "Probe laeuft bis " + r["ends_at"], "tage": r["days_left"]})
                done += 1
            else:
                row["ergebnis"] = "Probelauf: wuerde Probe bis " + ends.isoformat() + " setzen (--ausfuehren)"
            print(json.dumps(row, ensure_ascii=False), file=out)
    finally:
        conn.close()
    if args.ausfuehren:
        print(f"{done} Konto/Konten freigeschaltet bis {ends.astimezone(TZ).strftime('%d.%m.%Y %H:%M')} Uhr (Berlin).", file=out)
    else:
        print(f"Probelauf: {len(users)} Konto/Konten gefunden, nichts geaendert. Mit --ausfuehren schreiben.", file=out)
    return 0 if (done or (not args.ausfuehren and users)) else 1


def main(argv: list[str] | None = None) -> int:
    return run(sys.argv[1:] if argv is None else argv)


if __name__ == "__main__":
    raise SystemExit(main())

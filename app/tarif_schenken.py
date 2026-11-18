"""Einem StudiNow-Konto einen Tarif schenken (Betrieb, Auftrag des Inhabers 18.11.2026).

Auftrag: ein bestimmtes Konto bekommt Pro AI dauerhaft geschenkt – ohne Abo, ohne Ablauf, ohne Zahlung, mit allem, was
Pro AI enthaelt (Rechte, Kontingente, 100 Monats-Credits wie bezahltes Pro AI). Zusaetzliche Credits kauft das Konto
selbst wie jedes andere (Credit-Pakete bleiben kostenpflichtig, gekaufte Credits kommen zu den Monats-Credits dazu).

Technik: eigene Quelle `gift` in accounts.db/entitlements (billing.grant_gift), `will_renew` aus, unbefristet oder bis
zu einem Tag. Ein Abo aus dem App Store oder von Stripe bleibt unberuehrt (es gilt der hoechste aktive Tarif), und deren
Meldungen (Verlaengerung, Ablauf, Erstattung) schreiben nur ihre eigene Quelle, nie das Geschenk. Beim endgueltigen
Loeschen des Kontos verschwindet das Geschenk mit allen anderen Eintraegen. `--zuruecknehmen` beendet es sofort.

Aufruf im Container (deploy/, docs/release/BETRIEB.md):
  docker compose exec app python -m app.tarif_schenken --email tester@beispiel.de --plan pro_ai --unbefristet
  docker compose exec app python -m app.tarif_schenken --email tester@beispiel.de --plan pro_ai --unbefristet --ausfuehren
  docker compose exec app python -m app.tarif_schenken --email tester@beispiel.de --plan plus --bis 2027-06-30 --ausfuehren
  docker compose exec app python -m app.tarif_schenken --email tester@beispiel.de --zuruecknehmen --ausfuehren
Ohne --ausfuehren wird nur angezeigt, was geschaehe (Probelauf). Aus dem Repository: python tools/tarif-schenken.py …
Die Zeilen je Konto nennen die Adresse nur gekuerzt (t***@beispiel.de) und die Konto-ID; die volle Adresse steht nur in
der Bestaetigung am Ende, fuer den Aufrufer. Ein Konto, das es nicht gibt oder das geloescht ist, wird genannt und
uebersprungen. Rueckgabe 0 = mindestens ein Konto bearbeitet (bzw. im Probelauf gefunden), 1 = keines, 2 = falsche
Argumente.
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import date, datetime, time, timezone
from zoneinfo import ZoneInfo

from . import accounts, billing, plans

TZ = ZoneInfo("Europe/Berlin")
GIFT_PLANS = tuple(k for k in plans.ORDER if plans.is_sellable(k))      # plus, pro_ai


def _date(s: str) -> date:
    try:
        return date.fromisoformat(s)
    except ValueError:
        raise argparse.ArgumentTypeError(f"kein Datum (JJJJ-MM-TT): {s}")


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="tarif-schenken", description="Einem StudiNow-Konto einen Tarif schenken (ohne Zahlung, ohne Verlaengerung).",
                                epilog="Ohne --ausfuehren nur anzeigen. Schenken: --plan und --unbefristet oder --bis. "
                                       "Zuruecknehmen: --zuruecknehmen (ohne --plan).")
    p.add_argument("--email", action="append", default=[], metavar="ADRESSE", help="Konto mit dieser E-Mail-Adresse (mehrfach moeglich)")
    p.add_argument("--plan", choices=GIFT_PLANS, help="geschenkter Tarif")
    when = p.add_mutually_exclusive_group()
    when.add_argument("--unbefristet", action="store_true", help="ohne Ablauf")
    when.add_argument("--bis", type=_date, metavar="JJJJ-MM-TT", help="bis einschliesslich diesem Tag (Europe/Berlin)")
    when.add_argument("--zuruecknehmen", action="store_true", help="Geschenk sofort beenden")
    p.add_argument("--ausfuehren", action="store_true", help="wirklich schreiben (sonst Probelauf)")
    return p


def mask_email(email: str | None) -> str:
    """t***@beispiel.de: genug zum Wiedererkennen, nicht die volle Adresse."""
    e = str(email or "")
    local, at, domain = e.partition("@")
    if not at:
        return (e[:1] + "***") if e else ""
    return f"{local[:1]}***@{domain}"


def gift_end(args: argparse.Namespace) -> datetime | None:
    if args.bis is None:
        return None
    return datetime.combine(args.bis, time(23, 59, 59), tzinfo=TZ).astimezone(timezone.utc)


def find_users(emails: list[str]) -> tuple[list[tuple[str, dict]], list[str]]:
    """Aktive Konten zu den Adressen (in der Reihenfolge der Angabe, jedes Konto einmal) und die Adressen ohne aktives
    Konto (nie angelegt oder geloescht: geloeschte Konten tragen ihre Adresse nicht mehr)."""
    found: list[tuple[str, dict]] = []
    seen: set[str] = set()
    missing: list[str] = []
    with accounts.cursor() as conn:
        for e in emails:
            r = conn.execute("SELECT id, email, plan, plan_until, status FROM users WHERE email=?",
                             (accounts.normalize_email(e),)).fetchone()
            if r and r["status"] == "active":
                if r["id"] not in seen:
                    seen.add(r["id"])
                    found.append((e, dict(r)))
            else:
                missing.append(e)
    return found, missing


def _describe(info: dict) -> str:
    if not info["granted"]:
        return "keines"
    name = plans.PLANS.get(info["plan"] or "", {}).get("name", info["plan"])
    if not info["active"]:
        return f"{name}, beendet ({info['status']})"
    return f"{name}, " + ("unbefristet" if not info["ends_at"] else "bis " + info["ends_at"])


def run(argv: list[str], now: datetime | None = None, out=None) -> int:
    out = out or sys.stdout
    p = parser()
    args = p.parse_args(argv)
    if not args.email:
        p.print_usage(out)
        print("Bitte mindestens eine --email angeben.", file=out)
        return 2
    t = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    if args.zuruecknehmen:
        if args.plan:
            print("--zuruecknehmen ohne --plan angeben.", file=out)
            return 2
    else:
        if not args.plan:
            print("Bitte --plan angeben (" + " oder ".join(GIFT_PLANS) + ").", file=out)
            return 2
        if not args.unbefristet and args.bis is None:
            print("Bitte --unbefristet oder --bis JJJJ-MM-TT angeben.", file=out)
            return 2
    ends = gift_end(args)
    if ends is not None and ends <= t:
        print("Das Ende des Geschenks liegt nicht in der Zukunft.", file=out)
        return 2
    users, missing = find_users(args.email)
    for e in missing:
        print(json.dumps({"email": mask_email(e), "ergebnis": "kein aktives Konto (nicht gefunden oder geloescht), uebersprungen"},
                         ensure_ascii=False), file=out)
    plan_name = plans.PLANS[args.plan]["name"] if args.plan else None
    until_text = "unbefristet" if ends is None else "bis " + ends.astimezone(TZ).strftime("%d.%m.%Y")
    done: list[str] = []
    conn = billing.connect()
    try:
        for typed, u in users:
            legacy = {"plan": u["plan"], "plan_until": u["plan_until"]}
            before = billing.gift_info(conn, u["id"], t)
            row = {"konto": u["id"], "email": mask_email(u["email"]),
                   "tarif_vorher": billing.current_plan(conn, u["id"], t, legacy), "geschenk_vorher": _describe(before)}
            if args.zuruecknehmen:
                if not before["granted"] or before["status"] == "revoked":
                    row["ergebnis"] = "kein Geschenk zum Zuruecknehmen"
                elif args.ausfuehren:
                    billing.revoke_gift(conn, u["id"], now=t)
                    row["ergebnis"] = "Geschenk zurueckgenommen"
                    done.append(typed)
                else:
                    row["ergebnis"] = "Probelauf: wuerde das Geschenk zuruecknehmen (--ausfuehren)"
            elif args.ausfuehren:
                billing.grant_gift(conn, u["id"], args.plan, until=ends, now=t)
                row["ergebnis"] = f"{plan_name} geschenkt, {until_text}"
                done.append(typed)
            else:
                row["ergebnis"] = f"Probelauf: wuerde {plan_name} schenken, {until_text} (--ausfuehren)"
            if args.ausfuehren:
                row["tarif_jetzt"] = billing.current_plan(conn, u["id"], t, legacy)
            print(json.dumps(row, ensure_ascii=False), file=out)
    finally:
        conn.close()
    if not args.ausfuehren:
        print(f"Probelauf: {len(users)} Konto/Konten gefunden, nichts geaendert. Mit --ausfuehren schreiben.", file=out)
        return 0 if users else 1
    if args.zuruecknehmen:
        print(f"Geschenk zurueckgenommen fuer {len(done)} Konto/Konten" + (": " + ", ".join(done) if done else "."), file=out)
    else:
        print(f"{plan_name} geschenkt ({until_text}) an {len(done)} Konto/Konten" + (": " + ", ".join(done) if done else "."), file=out)
    return 0 if done else 1


def main(argv: list[str] | None = None) -> int:
    return run(sys.argv[1:] if argv is None else argv)


if __name__ == "__main__":
    raise SystemExit(main())

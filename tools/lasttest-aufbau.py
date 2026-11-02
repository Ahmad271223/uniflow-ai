#!/usr/bin/env python3
"""Testkonten fuer den grossen Lasttest anlegen (docs/LASTTEST-PLAN-GROSS.md). NUR auf dem gemieteten Testserver, nie im Betrieb.

Legt direkt in einem Datenordner N Konten mit Sitzung an (ohne HTTP, mehrere Prozesse) und schreibt die Sitzungs-Token
in eine Datei fuer `tools/lasttest-k6.js`. Adressen enden auf `@lasttest.invalid` (keine echte Adresse, keine Mail).
Aufruf:  LERNAPP_MODE=hosted python3 tools/lasttest-aufbau.py --data-dir /srv/lasttest/data --accounts 20000 --out tokens.json
"""
import argparse
import json
import multiprocessing as mp
import os
import secrets
import sys
import time
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument("--data-dir", required=True, help="Datenordner des Testdienstes (LERNAPP_DATA_DIR)")
ap.add_argument("--accounts", type=int, default=2000)
ap.add_argument("--out", default="tokens.json")
ap.add_argument("--procs", type=int, default=os.cpu_count() or 2)
ap.add_argument("--plus-share", type=float, default=0.2, help="Anteil der Konten mit Tarif Plus (Rest: Free)")
ap.add_argument("--no-warm", action="store_true", help="Konto-Datenbanken nicht vorab anlegen (die erste Anfrage kostet dann ca. 55 ms mehr)")
A = ap.parse_args()
os.environ["LERNAPP_DATA_DIR"] = str(Path(A.data_dir).resolve())
os.environ.setdefault("LERNAPP_MODE", "hosted")
os.environ.setdefault("LERNAPP_JOBS", "off")
sys.path[:0] = [os.getcwd(), str(Path(__file__).resolve().parent.parent)]      # im Container: aus dem App-Ordner starten
from app import accounts, config, db  # noqa: E402


def make(i: int):
    email = f"lt{i}@lasttest.invalid"
    uni = "hildesheim" if i % 4 == 3 else "luh"
    user = accounts.register(email, secrets.token_urlsafe(18) + "aA1!", uni)
    accounts.end_trial(user["id"])
    accounts.mark_email_verified(user["id"])
    if (i % 100) < int(A.plus_share * 100):
        accounts.set_plan(user["id"], "plus")
    with accounts.cursor() as conn:
        token = accounts.create_session(conn, user["id"], f"lasttest-{i}", "Lasttest")
    if not A.no_warm:
        t = config.set_user_context(user["id"], uni)
        try:
            db.init_db()
        finally:
            config.reset_user_context(t)
    return token


if __name__ == "__main__":
    t0 = time.time()
    Path(A.data_dir).mkdir(parents=True, exist_ok=True)
    with mp.Pool(A.procs) as p:
        tokens = p.map(make, range(A.accounts), chunksize=50)
    Path(A.out).write_text(json.dumps(tokens))
    os.chmod(A.out, 0o600)
    print(f"{len(tokens)} Konten in {time.time() - t0:.0f} s; Token in {A.out} (nur auf dem Testserver aufbewahren, danach loeschen)")

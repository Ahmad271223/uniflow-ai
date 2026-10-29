"""Gemeinsame Wochentests: gleicher Kurs + gleiche Uebung -> derselbe Test fuer alle.

Der Schluessel haengt nur an Dingen, die fuer alle Studierenden gleich sind:
  - Hochschule (luh, hildesheim, ...)
  - Testdauer, gerundet auf feste Stufen
  - Fingerabdruecke der verwendeten Materialien: SHA-256 des Dateiinhalts
    (gleiche Folie, gleiches Uebungsblatt -> gleicher Abdruck, egal ueber welchen Weg die Datei kam)
Nicht im Schluessel: Modulname und Lehrwochen-Nummer (pro Nutzer verschieden einstellbar), Nutzer, Geraet.
Wer eine andere Uebungsgruppe mit anderem Blatt hat, bekommt dadurch automatisch einen eigenen Test.

Version: aendert sich der Aufbau eines Tests (Prompt, Format), wird sie erhoeht, damit alte Tests nicht mit neuen
vermischt werden. "wt2" seit 29.10.2026: genau 15 Aufgaben (4 leicht, 6 mittel, 5 schwer), Altklausur im Schluessel. Dieselbe Berechnung steht fuer die iPad-App in
packages/shared-contracts/fixtures/testshare/ (Erwartungswerte).
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

VERSION = "wt2"
MINUTE_STEPS = (15, 30, 45, 60, 90, 120)


def minutes_bucket(minutes: int | None) -> int:
    """Auf die naechste feste Stufe runden, damit 40 und 45 Minuten denselben Test teilen."""
    m = int(minutes or 45)
    return next((s for s in MINUTE_STEPS if m <= s), MINUTE_STEPS[-1])


def file_sha256(path: str | Path | None) -> str | None:
    if not path or not Path(path).is_file():
        return None
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def material_fingerprint(m: dict) -> str | None:
    """Inhalts-Hash der Datei. Ohne Inhalt (nicht geladen) kein Abdruck: dann wird nicht geteilt."""
    return m.get("content_sha256") or file_sha256(m.get("local_path"))


def share_key(university: str, minutes: int | None, materials: list[dict]) -> str | None:
    """Schluessel des gemeinsamen Wochentests oder None, wenn nicht sicher teilbar (Material ohne Inhalts-Hash)."""
    prints = [material_fingerprint(m) for m in materials]
    if not prints or any(p is None for p in prints):
        return None
    canon = json.dumps({"v": VERSION, "uni": university, "minutes": minutes_bucket(minutes), "materials": sorted(set(prints))},
                       separators=(",", ":"), sort_keys=True)
    return f"{VERSION}:" + hashlib.sha256(canon.encode("utf-8")).hexdigest()


def lookup_local(conn, key: str) -> dict | None:
    """Vorhandener Test mit demselben Schluessel in dieser Installation.
    In V2 fragt hier zuerst der gemeinsame Dienst (ein Test je Schluessel fuer alle Nutzer), siehe docs/GEMEINSAME-WOCHENTESTS.md."""
    from . import db
    return db.row(conn, "SELECT title, questions FROM tests WHERE share_key=? ORDER BY id LIMIT 1", (key,))

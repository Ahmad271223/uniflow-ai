"""Datenmodell der Eingabe (JSON-Struktur aus SKILL.md, Abschnitt 10)."""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

TYPEN = ("klausur", "formelblatt", "uebung")

STANDARDHINWEIS = (
    "Bitte geben Sie bei allen Lösungen den Rechenweg an. Ergebnisse sind exakt und "
    "vollständig gekürzt anzugeben."
)


@dataclass
class Teil:
    label: str = ""
    text: str = ""


@dataclass
class Aufgabe:
    nr: str
    punkte: str = ""
    text: str = ""
    teile: list[Teil] = field(default_factory=list)


@dataclass
class LoesungsTeil:
    label: str = ""
    merke: str = ""
    schritte: list[str] = field(default_factory=list)
    ergebnis: str = ""


@dataclass
class Loesung:
    nr: str
    merke: str = ""
    teile: list[LoesungsTeil] = field(default_factory=list)
    wichtig: str = ""


@dataclass
class Formel:
    aufgabe: str
    formel: str
    hinweis: str = ""
    abschnitt: str = ""


@dataclass
class Dokument:
    typ: str
    fach: str
    titel: str
    untertitel: str = ""
    meta: dict = field(default_factory=dict)
    hinweis: str = ""
    aufgaben: list[Aufgabe] = field(default_factory=list)
    loesungen: list[Loesung] = field(default_factory=list)
    formeln: list[Formel] = field(default_factory=list)


class EingabeFehler(ValueError):
    pass


def _str(x) -> str:
    return "" if x is None else str(x)


def aus_dict(d: dict) -> Dokument:
    typ = _str(d.get("typ", "klausur")).strip().lower()
    if typ not in TYPEN:
        raise EingabeFehler(f"typ muss einer von {TYPEN} sein, nicht {typ!r}")
    for pflicht in ("fach", "titel"):
        if not _str(d.get(pflicht)).strip():
            raise EingabeFehler(f"Feld {pflicht!r} fehlt")
    aufgaben = [
        Aufgabe(
            nr=_str(a.get("nr")),
            punkte=_str(a.get("punkte")),
            text=_str(a.get("text")),
            teile=[Teil(_str(t.get("label")), _str(t.get("text"))) for t in a.get("teile", []) or []],
        )
        for a in d.get("aufgaben", []) or []
    ]
    loesungen = [
        Loesung(
            nr=_str(l.get("nr")),
            merke=_str(l.get("merke")),
            wichtig=_str(l.get("wichtig")),
            teile=[
                LoesungsTeil(
                    label=_str(t.get("label")),
                    merke=_str(t.get("merke")),
                    schritte=[_str(s) for s in t.get("schritte", []) or []],
                    ergebnis=_str(t.get("ergebnis")),
                )
                for t in l.get("teile", []) or []
            ],
        )
        for l in d.get("loesungen", []) or []
    ]
    formeln = [
        Formel(_str(f.get("aufgabe")), _str(f.get("formel")), _str(f.get("hinweis")), _str(f.get("abschnitt")))
        for f in d.get("formeln", []) or []
    ]
    if typ == "formelblatt" and not formeln:
        raise EingabeFehler("typ formelblatt braucht mindestens eine Formel")
    if typ != "formelblatt" and not aufgaben:
        raise EingabeFehler("keine Aufgaben gefunden")
    return Dokument(
        typ=typ,
        fach=_str(d["fach"]),
        titel=_str(d["titel"]),
        untertitel=_str(d.get("untertitel")),
        meta=dict(d.get("meta") or {}),
        hinweis=_str(d.get("hinweis")) or (STANDARDHINWEIS if typ != "formelblatt" else ""),
        aufgaben=aufgaben,
        loesungen=loesungen,
        formeln=formeln,
    )


def lade_json(pfad: str | Path) -> Dokument:
    with open(pfad, encoding="utf-8") as f:
        return aus_dict(json.load(f))

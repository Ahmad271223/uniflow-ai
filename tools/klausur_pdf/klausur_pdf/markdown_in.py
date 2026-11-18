"""„Prompt-Modus“: Markdown-Datei (PK-nn.md, 05-Formelblatt.md) → Dokument.

Erwartetes Format (tolerant gelesen):

    ---
    typ: klausur            (oder formelblatt / uebung; ohne Angabe: klausur)
    fach: Mathematik für die Ingenieurwissenschaften I
    titel: Probeklausur 3
    untertitel: Kurzklausur 1, Format wie Original
    dauer: 30 Minuten
    punkte: 10
    hilfsmittel: keine
    semester: WS 2026/27
    datum: 16.11.2026
    hinweis: Bitte geben Sie bei allen Lösungen den Rechenweg an.
    ---
    ## Teil 1: Aufgaben
    ### Aufgabe 1 (2 + 1 Punkte)
    Einleitungstext
    (a) Text der Teilaufgabe
    (b) Text der Teilaufgabe
    ## Teil 2: Lösungen
    ### Aufgabe 1
    **Merke:** Kurzfassung des Verfahrens
    (a)
    Schritt 1: …
    Schritt 2: …
    ▶ **Ergebnis**
    **Wichtig für die Klausur:** …

Formelblatt: „## Abschnitt“ beginnt einen Abschnitt, eine Zeile
„**Aufgabe: „…“**“ beginnt eine Formel, die folgenden Zeilen sind die Formel,
eine Zeile mit „Hinweis:“ der Hinweis. Ohne Kopfblock werden fach und titel
aus der ersten „# “-Überschrift genommen („# Fach – Titel“).
"""
from __future__ import annotations

import re
from pathlib import Path

from .model import Dokument, aus_dict

_TEIL = re.compile(r"^\s*(?:[-*]\s*)?(?:\*\*)?\(?([a-z])\)(?:\*\*)?[:.]?\s*(.*)$")
_AUFGABE = re.compile(r"^###\s+Aufgabe\s+([0-9]+[a-z]?)\s*(?:\(([^)]*?)\s*Punkte?\))?\s*:?\s*(.*)$", re.I)
_ERGEBNIS = re.compile(r"^\s*▶\s*(.*)$")
_MERKE = re.compile(r"^\s*\*\*Merke:?\*\*:?\s*(.*)$", re.I)
_WICHTIG = re.compile(r"^\s*\*\*Wichtig für die Klausur:?\*\*:?\s*(.*)$", re.I)
_FORMEL_AUFGABE = re.compile(r"^\s*\*\*\s*(Aufgabe:.*?)\s*\*\*\s*$")


def _ohne_fett(s: str) -> str:
    s = s.strip()
    if s.startswith("**") and s.endswith("**") and s.count("**") == 2:
        return s[2:-2].strip()
    return s


def _kopfblock(zeilen: list[str]) -> tuple[dict, list[str]]:
    meta: dict = {}
    if zeilen and zeilen[0].strip() == "---":
        for i in range(1, len(zeilen)):
            if zeilen[i].strip() == "---":
                for z in zeilen[1:i]:
                    if ":" in z:
                        k, v = z.split(":", 1)
                        meta[k.strip().lower()] = v.strip()
                return meta, zeilen[i + 1:]
    return meta, zeilen


def parse(text: str) -> Dokument:
    zeilen = text.replace("\r\n", "\n").split("\n")
    kopf, zeilen = _kopfblock(zeilen)
    d: dict = {
        "typ": kopf.pop("typ", "klausur"),
        "fach": kopf.pop("fach", ""),
        "titel": kopf.pop("titel", ""),
        "untertitel": kopf.pop("untertitel", ""),
        "hinweis": kopf.pop("hinweis", ""),
        "meta": {},
        "aufgaben": [],
        "loesungen": [],
        "formeln": [],
    }
    d["meta"] = kopf  # alles Übrige (dauer, punkte, hilfsmittel, semester, datum, fakultaet …)

    for z in zeilen:
        if z.startswith("# ") and not (d["fach"] and d["titel"]):
            t = z[2:].strip()
            fach, _, titel = t.partition(" – ")
            d["fach"] = d["fach"] or fach.strip()
            d["titel"] = d["titel"] or (titel.strip() or fach.strip())
            break

    if d["typ"] == "formelblatt":
        _parse_formeln(zeilen, d)
    else:
        _parse_klausur(zeilen, d)
    return aus_dict(d)


def _parse_klausur(zeilen: list[str], d: dict) -> None:
    modus = "aufgaben"
    aktuell = None
    teil = None
    for roh in zeilen:
        z = roh.rstrip()
        if z.startswith("## "):
            if re.search(r"lösung|loesung", z, re.I):
                modus = "loesungen"
            elif re.search(r"aufgabe", z, re.I):
                modus = "aufgaben"
            aktuell = teil = None
            continue
        m = _AUFGABE.match(z)
        if m:
            nr, punkte, rest = m.group(1), (m.group(2) or "").strip(), m.group(3).strip()
            if modus == "aufgaben":
                aktuell = {"nr": nr, "punkte": punkte, "text": rest, "teile": []}
                d["aufgaben"].append(aktuell)
            else:
                aktuell = {"nr": nr, "merke": "", "wichtig": "", "teile": []}
                d["loesungen"].append(aktuell)
            teil = None
            continue
        if aktuell is None or not z.strip() or z.startswith("# "):
            continue
        if modus == "aufgaben":
            mt = _TEIL.match(z)
            if mt:
                aktuell["teile"].append({"label": mt.group(1), "text": mt.group(2).strip()})
            elif aktuell["teile"]:
                aktuell["teile"][-1]["text"] += " " + z.strip()
            else:
                aktuell["text"] = (aktuell["text"] + " " + z.strip()).strip()
            continue
        # Lösungen
        mm = _MERKE.match(z)
        mw = _WICHTIG.match(z)
        me = _ERGEBNIS.match(z)
        mt = _TEIL.match(z)
        if mm:
            if teil is None:
                aktuell["merke"] = mm.group(1).strip()
            else:
                teil["merke"] = mm.group(1).strip()
        elif mw:
            aktuell["wichtig"] = mw.group(1).strip()
        elif mt and len(mt.group(2)) < 3:
            teil = {"label": mt.group(1), "merke": "", "schritte": [], "ergebnis": ""}
            aktuell["teile"].append(teil)
        elif me:
            if teil is None:
                teil = {"label": "", "merke": "", "schritte": [], "ergebnis": ""}
                aktuell["teile"].append(teil)
            teil["ergebnis"] = _ohne_fett(me.group(1))
        else:
            if teil is None:
                teil = {"label": "", "merke": "", "schritte": [], "ergebnis": ""}
                aktuell["teile"].append(teil)
            schritt = re.sub(r"^\s*[-*]\s+", "", z).strip()
            teil["schritte"].append(schritt)


def _parse_formeln(zeilen: list[str], d: dict) -> None:
    abschnitt = ""
    aktuell = None
    for roh in zeilen:
        z = roh.rstrip()
        if z.startswith("## "):
            abschnitt = z[3:].strip()
            aktuell = None
            continue
        m = _FORMEL_AUFGABE.match(z)
        if m:
            aktuell = {"aufgabe": m.group(1), "formel": "", "hinweis": "", "abschnitt": abschnitt}
            d["formeln"].append(aktuell)
            continue
        if aktuell is None or not z.strip() or z.startswith("#"):
            continue
        if re.match(r"^\s*\*?Hinweis:?\*?:?", z, re.I):
            aktuell["hinweis"] = re.sub(r"^\s*\*?Hinweis:?\*?:?\s*", "", z, flags=re.I)
        else:
            aktuell["formel"] = (aktuell["formel"] + "\n" + z.strip()).strip()


def lade_markdown(pfad: str | Path) -> Dokument:
    return parse(Path(pfad).read_text(encoding="utf-8"))

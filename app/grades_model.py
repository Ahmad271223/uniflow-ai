"""Notenspiegel auswerten: Ebenen, Doppelte, aktueller Schnitt (28.10.2026).

Befund mit echten LUH-Daten: Die App zeigte 93 Zeilen und einen Schnitt von 4,06. Richtig sind 17 benotete,
bestandene Module mit einem LP-gewichteten Schnitt von 3,47 (nach Prüfungsordnung 3,4). Drei Ursachen:

1. QIS zeigt jedes Modul und darunter seine Prüfungen (Modul „Mathematik I“, 8 LP, und Prüfungsleistung „Mathematik
   I“, PL). Die App listete beides flach, der Schnitt zählte beides.
2. Eine zweite QIS-Ansicht liefert dieselben Prüfungen noch einmal mit langen Semesternamen („Wintersemester 23/24“
   statt „WiSe 23/24“): echte Doppelte.
3. Nicht bestandene Versuche (5,0) und verschobene Bereichszeilen („Kompetenzbereich …“, „Pflichtmodule“) gingen in
   den Schnitt ein; Prüfungsnummer und LP wurden aus der LUH-Kopfzeile nicht erkannt.

Regeln (gelten für gespeicherte Zeilen, ein neuer Abruf ist nicht nötig):
- Felder werden zusätzlich aus `raw` (Zellen mit " | ") erkannt, wenn die Kopfzeile sie nicht geliefert hat:
  Nummer (erste Zelle, Ziffern), Art (PL, SL, LN, LA, SO, KL, MP, …), Semester, Note, Status, LP (Zahl nach dem
  Status), Datum, Versuch, Vermerk.
- Ebene: `bereich` (Kompetenzbereich, Pflicht-/Wahl(pflicht)module, Gesamtkonto, Studienbereich), `modul` (ohne Art
  und ohne Versuch), `pruefung` (mit Art oder Versuch).
- Doppelte: gleiche Nummer (sonst Text), Art, Semester (normalisiert), Versuch, Note und Datum -> eine Zeile.
- Schnitt: Module mit Note 1,0-4,0 und Status bestanden, gewichtet nach LP; ohne Modulzeilen (z. B. LSF Hildesheim)
  die bestandenen benoteten Leistungen. Angezeigt wird der Schnitt wie in Prüfungsordnungen üblich nach der ersten
  Nachkommastelle abgeschnitten, dazu der genaue Wert.
"""
from __future__ import annotations

import math
import re

ARTS = {"PL", "SL", "LN", "LA", "SO", "KL", "MP", "PA", "HA", "RE", "BA", "MA", "PR", "TN", "AN", "SP", "ML"}
SEM_RE = re.compile(r"^(WiSe|SoSe|Wintersemester|Sommersemester|WS|SS)\s*(\d{2,4})(?:\s*/\s*(\d{2,4}))?$", re.I)
NOTE_RE = re.compile(r"^\d,\d$")
DATE_RE = re.compile(r"^\d{2}\.\d{2}\.\d{4}$")
STATUS_RE = re.compile(r"^(bestanden|nicht bestanden|angemeldet.*|abgemeldet|endgültig nicht bestanden|prüfung vorhanden|"
                       r"anerkannt|zugelassen|nicht zugelassen|krank|rücktritt)$", re.I)
BEREICH_RE = re.compile(r"^(kompetenzbereich|pflichtmodule|wahlpflichtmodule|wahlmodule|wahlpflichtbereich|wahlbereich|"
                        r"gesamtkonto|studienbereich|schwerpunkt\b|vertiefung\b|fachstudium|grundstudium|hauptstudium)", re.I)


def norm_semester(s: str | None) -> str:
    """'Wintersemester 23/24' -> 'WiSe 23/24', 'Sommersemester 24' -> 'SoSe 24'; Unbekanntes bleibt."""
    s = (s or "").strip()
    m = SEM_RE.match(s)
    if not m:
        return s
    winter = m.group(1).lower().startswith(("wi", "ws"))
    a, b = m.group(2)[-2:], (m.group(3) or "")[-2:]
    return f"WiSe {a}/{b}" if winter and b else (f"WiSe {a}" if winter else f"SoSe {a}")


def _num(v) -> float | None:
    try:
        return float(str(v).strip().replace(",", "."))
    except (TypeError, ValueError):
        return None


def fields_from_raw(raw: str | None) -> dict:
    """Felder aus den Zellen einer Zeile (Inhalt statt Spaltenposition; die LUH-Bereichszeilen haben weniger Zellen)."""
    cells = [c.strip() for c in (raw or "").split(" | ")]
    out: dict = {}
    if cells and cells[0].isdigit():
        out["pruefungsnr"] = cells[0]
    status_i = None
    for i, c in enumerate(cells[1:], 1):
        if "art" not in out and c.upper() in ARTS:
            out["art"] = c.upper()
        elif "semester" not in out and SEM_RE.match(c):
            out["semester"] = c
        elif "note" not in out and NOTE_RE.match(c):
            out["note"] = c
        elif "status" not in out and STATUS_RE.match(c):
            out["status"], status_i = c, i
        elif "datum" not in out and DATE_RE.match(c):
            out["datum"] = c
    if status_i is not None and status_i + 1 < len(cells) and re.fullmatch(r"\d+(,\d+)?", cells[status_i + 1]):
        out["credits"] = cells[status_i + 1]
    if "datum" in out:
        di = cells.index(out["datum"])
        if di + 1 < len(cells) and cells[di + 1].isdigit() and len(cells[di + 1]) <= 2:
            out["versuch"] = cells[di + 1]
        if di + 2 < len(cells) and re.fullmatch(r"[A-ZÄÖÜ]{2,4}", cells[di + 2] or ""):
            out["vermerk"] = cells[di + 2]
    return out


def _level(r: dict) -> str:
    if BEREICH_RE.match(r.get("text") or ""):
        return "bereich"
    if r.get("art") or (r.get("versuch") or "").strip():
        return "pruefung"
    return "modul"


def model(rows: list[dict]) -> list[dict]:
    """Gespeicherte Zeilen -> bereinigte Zeilen mit `level`, `semester_norm`, `passed`, `graded`; ohne Doppelte."""
    out, seen = [], set()
    for r in rows:
        f = fields_from_raw(r.get("raw"))
        g = dict(r)
        for k, v in f.items():                       # Kopfzeile geht vor, Inhalt fuellt Luecken
            cur = g.get(k)
            if cur is None or (isinstance(cur, str) and not cur.strip()):
                g[k] = v
        g.setdefault("art", f.get("art") or "")
        # verschobene Zeilen (weniger Zellen): Inhalt geht vor, wenn die Spaltenzuordnung offensichtlich falsch ist
        if g.get("semester") and not SEM_RE.match(g["semester"]) and "semester" not in f:
            g["semester"] = ""
        if g.get("note") and not NOTE_RE.match(g["note"]):
            g["note"] = f.get("note", "")
        if g.get("status") and not STATUS_RE.match(g["status"]) and f.get("status"):
            g["status"] = f["status"]
        if f.get("credits") and not _num(g.get("credits")):
            g["credits"] = f["credits"]
        g["semester_norm"] = norm_semester(g.get("semester"))
        key = (g.get("pruefungsnr") or g.get("text"), g.get("art"), g["semester_norm"], (g.get("versuch") or "").strip(),
               g.get("note") or "", g.get("datum") or "")
        if key in seen:
            continue
        seen.add(key)
        g["level"] = _level(g)
        note = _num(g.get("note"))
        g["passed"] = (g.get("status") or "").strip().lower() in ("bestanden", "anerkannt")
        g["graded"] = note is not None and 1.0 <= note <= 4.0 and g["passed"]
        out.append(g)
    return out


def truncate1(x: float) -> float:
    """Erste Nachkommastelle, ohne Rundung (uebliche Regel der Pruefungsordnungen)."""
    return math.floor(x * 10 + 1e-9) / 10


def summary(rows: list[dict]) -> dict:
    m = model(rows)
    modules = [r for r in m if r["level"] == "modul"]
    basis = modules if any(r["graded"] for r in modules) else [r for r in m if r["level"] != "bereich"]
    graded = [r for r in basis if r["graded"]]
    weights = [(_num(r["note"]), _num(r.get("credits")) or 0.0) for r in graded]
    lp = sum(w for _, w in weights)
    exact = sum(n * w for n, w in weights) / lp if lp else (sum(n for n, _ in weights) / len(weights) if weights else None)
    passed = [r for r in basis if r["passed"]]
    return {
        "rows": m,
        "average": truncate1(exact) if exact is not None else None,
        "average_exact": round(exact, 2) if exact is not None else None,
        "graded_count": len(graded),
        "graded_credits": round(lp, 1),
        "credits": round(sum(_num(r.get("credits")) or 0.0 for r in passed), 1),
        "passed": len(passed),
        "basis": "module" if basis is modules else "leistungen",
        "bereiche": [{"text": r["text"], "note": r.get("note") or "", "credits": r.get("credits") or "", "status": r.get("status") or ""}
                     for r in m if r["level"] == "bereich"],
        "failed_attempts": len([r for r in m if r["level"] == "pruefung" and (r.get("status") or "").lower().startswith("nicht")]),
    }

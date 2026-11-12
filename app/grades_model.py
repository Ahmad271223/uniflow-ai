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

Regel des Inhabers (12.11.2026): QIS ist die einzige Quelle fuer bestandene Leistungen, Noten und die Summe der LP.
Jede bestandene QIS-Leistung zaehlt einmal (`count`, `credits_done`), auch ohne Modulzeile; Uni & Noten, Studienverlauf
und Uebersicht zeigen dieselbe Zahl. Vorher fehlten Leistungen und LP:
- Pruefungszeilen ohne (bestandene) Modulzeile zaehlten nicht, sobald es irgendein benotetes Modul gab (Studien-
  leistungen, Labore, Schluesselkompetenzen) und standen nicht in der Ansicht "Module".
- bestanden hiess nur genau "bestanden"/"anerkannt": "BE", "bestanden (anerkannt)", "angerechnet" und Zeilen mit Note
  1,0-4,0 ohne Status fehlten.
- Module wie "Vertiefung der Betriebssysteme" galten als Bereichszeile (Summe) und fehlten ganz.
Zugehoerigkeit einer Pruefung zu ihrem Modul (dann zaehlen die LP der Modulzeile, nicht doppelt): gleicher Text, sonst
Nummer (Modul 110 -> Pruefung 111, Modul 11 -> 1101), sonst die Modulzeile direkt davor (QIS listet je Modul seine
Pruefungen darunter; nicht, wenn die Pruefung nach dem Semester des bestandenen Moduls liegt). Ist das Modul nicht
bestanden, zaehlen seine bestandenen Pruefungen mit ihren LP (hoechstens die LP der Modulzeile).
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
# Modultitel, die wie ein Bereich anfangen ("Vertiefung der Betriebssysteme", "Schwerpunkt in ..."): keine Bereichszeile
MODULE_TITLE_RE = re.compile(r"^(schwerpunkt|vertiefung)\s+(der|des|die|das|dem|den|in|im|zu|zur|zum|von|vom|für|fuer|mit)\b", re.I)


# Semester in allen Schreibweisen des QIS/HIS (12.11.2026, Meldung des Inhabers: Studierende hoeherer Semester bekamen
# einen falschen Studienverlauf, weil Semester wie "WS 2024/25", "W24", "24/25 WS", "SoSe2025", "20242" oder eine leere
# Semesterspalte nicht erkannt wurden): Art vorn oder hinten, Jahr zwei- oder vierstellig, Punkte und Bindestriche egal
_TERM_FRONT_RE = re.compile(r"^(wintersemester|sommersemester|wise|sose|ws|ss|wi|so|w|s) ?(\d{2}|\d{4})(?: ?[/-] ?(\d{2}|\d{4}))?$")
_TERM_BACK_RE = re.compile(r"^(\d{2}|\d{4})(?: ?[/-] ?(\d{2}|\d{4}))? ?(wintersemester|sommersemester|wise|sose|ws|ss|w|s)$")
_HIS_TERM_RE = re.compile(r"^(\d{4})([12])$")              # HIS-Semesterschluessel: 20241 = SoSe 24, 20242 = WiSe 24/25
_DATE_DE_RE = re.compile(r"^(\d{1,2})\.(\d{1,2})\.(\d{4})$")
_DATE_ISO_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})")


def parse_term(s) -> int | None:
    """Semester -> Zahl (Jahr*2, +1 im Winter): 'WiSe 24/25', 'WS 2024/25', 'Wintersemester 2024/2025', 'W24', '24/25 WS',
    '2024W', 'SoSe 25', 'SS 2025', 'Sommersemester 2025', 'S25', '20242' (HIS); sonst None"""
    if not isinstance(s, str):
        return None
    t = " ".join(re.sub(r"\([^()]*\)\s*$", "", s).replace(".", " ").replace("\u00a0", " ").lower().split())  # "(2. PZ)" weg
    t = re.sub(r"(?<=[a-z]) (?=[a-z])", "", t)               # "wi se 24/25" (aus "Wi.Se.") -> "wise 24/25"
    m = _HIS_TERM_RE.match(t)
    if m:
        year, winter = int(m.group(1)), m.group(2) == "2"
    else:
        m = _TERM_FRONT_RE.match(t)
        if m:
            kind, y = m.group(1), m.group(2)
        else:
            m = _TERM_BACK_RE.match(t)
            if not m:
                return None
            kind, y = m.group(3), m.group(1)
        year = int(y) + (2000 if len(y) == 2 else 0)
        winter = kind.startswith("w")
    if not 1990 <= year <= 2099:
        return None
    return year * 2 + (1 if winter else 0)


def term_name(t: int) -> str:
    year = t // 2
    if t % 2:
        return f"WiSe {year % 100:02d}/{(year + 1) % 100:02d}"
    return f"SoSe {year % 100:02d}"


def term_of_date(d) -> int | None:
    """Semester einer Pruefung aus ihrem Datum, wenn die Semesterspalte fehlt: Januar-April -> WiSe davor
    (Pruefungszeitraum Februar/Maerz), Mai-Oktober -> SoSe (Juli-September), November/Dezember -> WiSe"""
    if not isinstance(d, str):
        return None
    d = d.strip()
    m = _DATE_DE_RE.match(d)
    if m:
        month, year = int(m.group(2)), int(m.group(3))
    else:
        m = _DATE_ISO_RE.match(d)
        if not m:
            return None
        year, month = int(m.group(1)), int(m.group(2))
    if not 1 <= month <= 12 or not 1990 <= year <= 2099:
        return None
    if month <= 4:
        return (year - 1) * 2 + 1
    return year * 2 if month <= 10 else year * 2 + 1


def row_term(r: dict) -> int | None:
    """Semester einer QIS-Zeile: Semesterspalte, sonst aus dem Pruefungsdatum"""
    t = parse_term(r.get("semester"))
    return t if t is not None else term_of_date(r.get("datum"))


def norm_semester(s: str | None) -> str:
    """'Wintersemester 2023/24', 'WS 23/24', 'W23' -> 'WiSe 23/24', 'Sommersemester 2024' -> 'SoSe 24'; Unbekanntes bleibt."""
    t = parse_term(s)
    return term_name(t) if t is not None else (s or "").strip()


def _is_term_cell(c: str) -> bool:
    """Semester in einer Zelle (ohne die reinen Ziffern des HIS-Schluessels, die auch eine Nummer sein koennten)"""
    return not c.isdigit() and parse_term(c) is not None


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
        elif "semester" not in out and _is_term_cell(c):
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


def is_bereich_text(text: str | None) -> bool:
    """Bereichs-/Summenzeile laut Text (Kompetenzbereich, Pflichtmodule ...), nicht ein Modul wie "Vertiefung der ..." """
    t = text or ""
    return bool(BEREICH_RE.match(t)) and not MODULE_TITLE_RE.match(t)


def is_passed(r: dict) -> bool:
    """Bestanden laut QIS: Status bestanden/BE/anerkannt/angerechnet (auch "bestanden (anerkannt)"), ohne Status (oder
    "AN") mit Note 1,0-4,0. Nie "nicht bestanden", "angemeldet" oder eine Pruefungsanmeldung."""
    if r.get("source") == "anmeldung":
        return False
    s = (r.get("status") or "").strip().lower()
    if s == "be" or s.startswith(("bestanden", "anerkannt", "angerechnet")):
        return True
    note = _num(r.get("note")) if NOTE_RE.match((r.get("note") or "").strip()) else None
    return s in ("", "an") and note is not None and 1.0 <= note <= 4.0


def _level(r: dict) -> str:
    if is_bereich_text(r.get("text")):
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
        if g.get("semester") and parse_term(g["semester"]) is None and "semester" not in f:
            g["semester"] = ""
        if g.get("note") and not NOTE_RE.match(g["note"]):
            g["note"] = f.get("note", "")
        if g.get("status") and not STATUS_RE.match(g["status"]) and f.get("status"):
            g["status"] = f["status"]
        if f.get("credits") and not _num(g.get("credits")):
            g["credits"] = f["credits"]
        g["semester_norm"] = norm_semester(g.get("semester"))
        if not g["semester_norm"] and term_of_date(g.get("datum")) is not None:
            g["semester_norm"] = term_name(term_of_date(g.get("datum")))     # leere Semesterspalte: aus dem Datum
        key = (g.get("pruefungsnr") or g.get("text"), g.get("art"), g["semester_norm"], (g.get("versuch") or "").strip(),
               g.get("note") or "", g.get("datum") or "")
        if key in seen:
            continue
        seen.add(key)
        g["level"] = _level(g)
        note = _num(g.get("note"))
        g["passed"] = is_passed(g)
        g["graded"] = note is not None and 1.0 <= note <= 4.0 and g["passed"]
        out.append(g)
    return count(out)


def _name_key(r: dict) -> str:
    return " ".join((r.get("text") or "").lower().split())


def _nr(r: dict) -> str:
    n = (r.get("pruefungsnr") or "").strip()
    return n if n.isascii() and n.isdigit() else ""


def _nr_child(p: str, m: str) -> bool:
    """Pruefungsnummer unter der Modulnummer: 1101 unter 11 (Praefix), 111 unter 110 (letzte Ziffer)"""
    if not p or not m or p == m:
        return False
    if len(p) > len(m) and p.startswith(m):
        return True
    return len(p) == len(m) >= 3 and m.endswith("0") and p[:-1] == m[:-1]


def _chrono(semester_norm: str) -> int | None:
    """SoSe 24 -> 48, WiSe 24/25 -> 49 (zum Vergleich der Reihenfolge)"""
    m = re.match(r"^(WiSe|SoSe) (\d{2})", semester_norm or "")
    return int(m.group(2)) * 2 + (1 if m.group(1) == "WiSe" else 0) if m else None


def _parent(m: list[dict], i: int) -> int | None:
    """Modulzeile einer Pruefungszeile (Index) oder None"""
    p = m[i]
    mods = [j for j, r in enumerate(m) if r["level"] == "modul" and r.get("source") != "anmeldung"]
    key = _name_key(p)
    same = [j for j in mods if key and _name_key(m[j]) == key]
    if same:
        return min(same, key=lambda j: (j > i, abs(j - i)))
    nr = _nr(p)
    by_nr = [j for j in mods if _nr_child(nr, _nr(m[j]))]
    if by_nr:
        return max(by_nr, key=lambda j: (len(_nr(m[j])), j < i, -abs(j - i)))
    for j in range(i - 1, -1, -1):
        lv = m[j]["level"]
        if lv == "pruefung":
            continue
        if lv != "modul" or m[j].get("source") == "anmeldung":
            return None
        pm, pp = _chrono(m[j].get("semester_norm")), _chrono(p.get("semester_norm"))
        if m[j]["passed"] and pm is not None and pp is not None and pp > pm:
            return None
        return j
    return None


def count(m: list[dict]) -> list[dict]:
    """Je Zeile `counted` (zaehlt als bestandene Leistung) und `lp_counted` (ihre LP in der Summe). Bestandene
    Modulzeile: ihre LP (ohne LP dort die der bestandenen Pruefungen darunter), die Pruefungen darunter nicht noch einmal.
    Nicht bestandenes Modul: seine bestandenen Pruefungen mit ihren LP, zusammen hoechstens die LP der Modulzeile.
    Bestandene Pruefung ohne Modulzeile: ihre LP. Bereichs-/Summenzeilen und Pruefungsanmeldungen nie."""
    for r in m:
        r["counted"], r["lp_counted"] = False, 0.0

    def lp(r):
        v = _num(r.get("credits"))
        return v if v is not None and math.isfinite(v) and v > 0 else 0.0

    kids: dict[int, list[int]] = {}
    alone: list[int] = []
    for i, r in enumerate(m):
        if r["level"] == "pruefung" and r["passed"]:
            j = _parent(m, i)
            if j is None:
                alone.append(i)
            else:
                kids.setdefault(j, []).append(i)
    for i, r in enumerate(m):
        if r["level"] == "modul" and r["passed"]:
            r["counted"] = True
            r["lp_counted"] = lp(r) if lp(r) > 0 else sum(lp(m[k]) for k in kids.get(i, []))
        elif r["level"] == "modul":
            left = lp(r) if lp(r) > 0 else math.inf
            for k in kids.get(i, []):
                take = min(lp(m[k]), left)
                m[k]["counted"], m[k]["lp_counted"] = True, take
                left -= take
    for i in alone:
        m[i]["counted"], m[i]["lp_counted"] = True, lp(m[i])
    return m


def counted_lp(m: list[dict]) -> float:
    """Summe `lp_counted` bereinigter Zeilen (`model`), auf eine Stelle gerundet"""
    return round(sum(r["lp_counted"] for r in m), 1)


def credits_done(rows: list[dict]) -> float:
    """LP aller bestandenen QIS-Leistungen (je Leistung einmal): die eine Zahl fuer "LP erreicht" ueberall
    (Uni & Noten `summary`, Studienverlauf `study_plan.compute`)"""
    return counted_lp(model(rows))


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
    passed = [r for r in m if r["counted"]]
    return {
        "rows": m,
        "average": truncate1(exact) if exact is not None else None,
        "average_exact": round(exact, 2) if exact is not None else None,
        "graded_count": len(graded),
        "graded_credits": round(lp, 1),
        "credits": counted_lp(m),
        "passed": len(passed),
        "basis": "module" if basis is modules else "leistungen",
        "bereiche": [{"text": r["text"], "note": r.get("note") or "", "credits": r.get("credits") or "", "status": r.get("status") or ""}
                     for r in m if r["level"] == "bereich"],
        "failed_attempts": len([r for r in m if r["level"] == "pruefung" and (r.get("status") or "").lower().startswith("nicht")]),
    }

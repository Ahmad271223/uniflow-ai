"""Klausur und Loesung zusammenfuehren: eine Regel fuer die Anzeige (Block "Klausuren & Altklausuren" im Moduldetail,
app/study.py) und fuer den Aufgabenindex der Wochentests (app/weekly.py), 17.11.2026.

- `links(files)`: zu jeder Aufgabendatei eines Moduls ihre Loesungsdatei(en), ueber Dateiname und Ordner
- `groups(files, found)`: Klausuren und Loesungen eines Blocks nach Jahrgang, neuester zuerst; jede Klausur mit ihrer
  Loesung direkt darunter, Sammel-Loesungen und Loesungen ohne erkannte Klausur am Ende ihres Jahrgangs

Nur Text und Listen, keine Datenbank. Derselbe Code im Swift-Kern: ExamPairs.swift; gemeinsame Faelle in
packages/shared-contracts/fixtures/local-backend/exam-pairs.json (tools/gen-exam-pairs-fixture.py).
"""
from __future__ import annotations

import re
from collections import defaultdict

# "sol" als eigenes Wortstueck vor einer Nummer, vor "_" oder "." oder am Ende ("sol1b.pdf", "kk1_sol.pdf", "sol.pdf"),
# nie mitten im Wort ("Solar", "Konsole", "Sol-Gel"); auch fuer study.SOLUTION_NAME
SOL_PIECE = r"(?<![a-zäöüß])sol(?=[ _\-]?\d|[_.]|$)"
# Was aus dem Dateinamen faellt, bevor Aufgabe und Loesung verglichen werden: Loesungswoerter, Fuellwoerter als
# eigenes Wort ("Lösungen zu PK" -> "pk") und Trennzeichen
SOL_WORDS = (r"musterl(ö|oe)sung(en)?|l(ö|oe)sung(en)?|l(ö|oe)s\b|lsg|solutions?|" + SOL_PIECE
             + r"|(?<![a-zäöüß])(zu[rm]?|f(ü|ue)r|von)(?![a-zäöüß])|mit|und|_|-|\s|\(|\)")
PAPER = r"^a[345][ _\-]+|[ _\-]+a[345]$"                  # Papierformat vorn oder hinten: "A4-Loesung-Klausur-WS2122"
ID_TAIL = re.compile(r"^[a-zäöüß]+(\d.*)$")              # "kk1b" -> "1b": Buchstaben, dann die Kennung ab der ersten Ziffer


def stem(name: str | None) -> str:
    return re.sub(r"\.[a-z0-9]+$", "", (name or "").lower())


def solution_key(name: str | None) -> str:
    return re.sub(SOL_WORDS, "", stem(name))


def plain_key(name: str | None) -> str:
    """Schluessel ohne Papierformat am Rand ("A4-Loesung-Beispiel-Klausuraufgaben-WS2122" -> wie die Klausur), sonst
    stoert die 4 den Zahlenvergleich. Nur wenn genug Name uebrig bleibt: "A4.pdf" und "A4_lsg.pdf" (Aufgabe 4)
    behalten ihren Schluessel "a4"."""
    k = re.sub(SOL_WORDS, "", re.sub(PAPER, "", stem(name)))
    return k if len(k) >= 4 else solution_key(name)


def numbers(key: str) -> list[int]:
    """Nummern im Schluessel ("übungsblatt10" -> [10]): der Teilwort-Rueckfall darf "Blatt 1" nie mit "Blatt 10"
    verbinden (Audit P49-06, 08.11.2026)"""
    return [int(x) for x in re.findall(r"\d+", key)]


def folder_of(f: dict) -> tuple:
    """Ordner einer Datei: Kurs und Stud.IP-Ordner (derselbe Ordnername in zwei Kursen ist nicht derselbe Ordner)"""
    return (f.get("course_id"), f.get("studip_folder") or "")


# Art des Treffers in `links`
NAME, IDENT, WHOLE, MODULE = "name", "kennung", "sammel", "modul"


def links(files: list[dict]) -> dict:
    """Loesungsdateien je Aufgabendatei: {Datei-ID: [Art, [Loesungs-IDs]]}; Dateien ohne Loesung fehlen.
    `files`: Dateien eines Moduls mit id, name, course_id, studip_folder und doc_type ("loesung" = Loesung, alles
    andere = Aufgabendatei, "klausur" = Klausur). Reihenfolge, der erste Treffer gilt:
    1. NAME: gleicher Ordner (Kurs + Stud.IP-Ordner), gleicher Name ohne Loesungswort oder Teilwort mit gleichen Zahlen
    2. IDENT: gleicher Ordner, gleiche Kennung: "kk1b.pdf" und "sol1b.pdf", "Übung 3.pdf" und "Lösung 3.pdf"; nur wenn
       im Ordner genau eine Aufgabendatei und genau eine Loesungsdatei diese Kennung haben
    3. WHOLE: gleicher Ordner, Sammeldatei ("Lösungen.pdf" neben den Klausuren): nur Klausuren, nur mit Ordnernamen,
       nur wenn es im Ordner genau eine Sammeldatei gibt. Welche Aufgabe darin zu welcher Klausur gehoert, sagt der
       Name nicht (weekly._link_solutions verbindet darum nur eindeutige Aufgabennummern).
    4. MODULE: ganzes Modul wie vor dem 17.11.2026 (Loesungen in einem eigenen Ordner), aber nie ueber Jahrgaenge
       hinweg: "WS 19/20/KK2.pdf" bekommt nicht "WS 21/22/KK2loes.pdf" (`term` beider Dateien bekannt und verschieden)
    Gleiche Namen in mehreren Semesterordnern ("WS 22/KK1loes.pdf", "WS 23/KK1loes.pdf") trifft damit der eigene Ordner."""
    sols = [f for f in files if f.get("doc_type") == "loesung"]
    tasks = [f for f in files if f.get("doc_type") != "loesung"]
    if not sols:
        return {}
    keys = {"key": {f["id"]: solution_key(f.get("name")) for f in files},
            "plain": {f["id"]: plain_key(f.get("name")) for f in files}}
    key = keys["key"]
    terms = {f["id"]: term(f.get("studip_folder"), f.get("name")) for f in sols}
    tables: dict = {}

    def named(tid: str, folder, field: str):
        """Loesungsdateien zum Schluessel der Datei: gleicher Schluessel, sonst Teilwort mit gleichen Zahlen"""
        if (folder, field) not in tables:
            by_key = defaultdict(list)
            for s in sols:
                if folder is None or folder_of(s) == folder:
                    by_key[keys[field][s["id"]]].append(s["id"])
            tables[(folder, field)] = by_key
        by_key, k = tables[(folder, field)], keys[field][tid]
        return by_key.get(k) or next((v for kk, v in by_key.items() if kk and k and (kk in k or k in kk) and min(len(kk), len(k)) >= 4
                                      and numbers(kk) == numbers(k)), None)

    sol_files, task_files = defaultdict(lambda: defaultdict(list)), defaultdict(list)
    for s in sols:
        sol_files[folder_of(s)][key[s["id"]]].append(s["id"])
    for t in tasks:
        m = ID_TAIL.match(key[t["id"]])
        if m:
            task_files[(folder_of(t), m.group(1))].append(t["id"])

    out = {}
    for t in tasks:
        tid, folder = t["id"], folder_of(t)
        hit = named(tid, folder, "key") or named(tid, folder, "plain")
        if hit:
            out[tid] = [NAME, hit]
            continue
        m = ID_TAIL.match(key[tid])
        twins = sol_files[folder].get(m.group(1), []) if m else []
        if len(twins) == 1 and len(task_files[(folder, m.group(1))]) == 1:
            out[tid] = [IDENT, twins]
            continue
        whole = sol_files[folder].get("", [])
        if t.get("doc_type") == "klausur" and folder[1] and len(whole) == 1:
            out[tid] = [WHOLE, whole]
            continue
        hit = named(tid, None, "key") or named(tid, None, "plain")
        if hit:
            own = term(t.get("studip_folder"), t.get("name"))
            hit = [sid for sid in hit if own is None or terms[sid] is None or terms[sid] == own]
        if hit:
            out[tid] = [MODULE, hit]
    return out


# ------------------------------------------------------------------------------------------------------- Jahrgang
# Semester im Ordner oder Namen: "WS 20/21", "WS25/26", "WiSe 2022/23", "SoSe 23", "SS2023"; mitten im Namen nur gross
# geschrieben nach Kleinbuchstabe oder Ziffer ("KK1aWS2425lsg"), nie "abschluss2023" oder "news24"
TERM = re.compile(r"(?:(?<![A-Za-zÄÖÜäöüß])([Ww][Ii][Ss][Ee]|[Ww][Ss]|[Ss][Oo][Ss][Ee]|[Ss][Ss])|(?<=[a-z0-9äöüß])(WiSe|WS|SoSe|SS))"
                  r"([ _'\-]?)([0-9]{2,4})(?![0-9])")
TERM_WORD = re.compile(r"(?<![a-zäöüß])(winter|sommer)(?:semester)?([ _'\-]?)([0-9]{2,4})(?![0-9])")   # auf Kleinschreibung
YEAR = re.compile(r"(?<![0-9])(19[89][0-9]|20[0-4][0-9])(?![0-9])")                                    # "Klausur_2019.pdf"


def _term(winter: bool, year: int) -> list:
    if winter:
        return [year * 2 + 1, f"WS {year % 100:02d}/{(year + 1) % 100:02d}"]
    return [year * 2, f"SS {year % 100:02d}"]


def _term_of(winter: bool, gap: str, digits: str):
    """[Rang, Bezeichnung] aus den Ziffern hinter dem Semesterwort: "23", "2023", bei Winter auch "2324". "2021" direkt
    am Wort ("WS2021") ist das Paar 20/21, mit Abstand ("WS 2021") das Jahr. None, wenn die Ziffern kein Jahr sind."""
    pair = len(digits) == 4 and winter and int(digits[2:]) == (int(digits[:2]) + 1) % 100
    year4 = len(digits) == 4 and 1990 <= int(digits) <= 2049
    if len(digits) == 2 or (pair and not (year4 and gap)):
        yy = int(digits[:2])
        return _term(winter, (1900 if yy >= 90 else 2000) + yy)
    if year4:
        return _term(winter, int(digits))
    return None


def _terms(text: str) -> list:
    """Alle Jahrgaenge in einem Text in der Reihenfolge des Textes: Semester, sonst ausgeschriebenes Semester, sonst Jahr"""
    out = [_term_of((m.group(1) or m.group(2)).lower() in ("ws", "wise"), m.group(3), m.group(4)) for m in TERM.finditer(text)]
    out = [t for t in out if t]
    if not out:
        out = [_term_of(m.group(1) == "winter", m.group(2), m.group(3)) for m in TERM_WORD.finditer(text.lower())]
        out = [t for t in out if t]
    if not out:
        out = [[int(m.group(1)) * 2, m.group(1)] for m in YEAR.finditer(text)]
    return out


def term(folder: str | None, name: str | None):
    """Jahrgang einer Datei als [Rang, Bezeichnung]: der letzte im Ordnerpfad ("Alte Klausuren/WS 22/23" -> "WS 22/23"),
    sonst der erste im Namen ohne Endung ("KK1aWS2425lsg.pdf" -> "WS 24/25"); None ohne Jahrgang. Hoeherer Rang = neuer."""
    found = _terms(folder or "")
    if found:
        return found[-1]
    found = _terms(re.sub(r"\.[A-Za-z0-9]+$", "", name or ""))
    return found[0] if found else None


EXAM, SOLUTION, EXTRA = "klausur", "loesung", "weitere_loesung"
NO_FOLDER = "Ohne Ordner"


def groups(files: list[dict], found: dict) -> list[dict]:
    """Klausuren und Loesungen eines Blocks nach Jahrgang: [{"label", "files"}], neuester Jahrgang zuerst, danach die
    Dateien ohne Jahrgang je Ordner (nach Name), zuletzt die ohne Ordner. In einer Gruppe steht jede Klausur (nach
    Name) mit ihrer Loesung direkt darunter (`exam_role` "loesung", `solution_of` = ID der Klausur), am Ende die
    Sammel-Loesungen und die Loesungen ohne erkannte Klausur (`exam_role` "weitere_loesung"). Eine Klausur ohne Loesung
    steht allein. Jede Datei steht genau einmal da, keine verschwindet.
    `files`: Dateien des Blocks mit doc_type "klausur" oder "loesung"; `found`: `links` ueber die Dateien des Moduls."""
    exams = sorted([f for f in files if f.get("doc_type") == "klausur"], key=_by_name)
    sols = {f["id"]: f for f in sorted([f for f in files if f.get("doc_type") == "loesung"], key=_by_name)}
    out: dict = {}

    def rows_of(f: dict) -> list:
        t = term(f.get("studip_folder"), f.get("name"))
        label = t[1] if t else (f.get("studip_folder") or "")
        rank = (0, -t[0], label) if t else (1 if label else 2, 0, label.lower())
        return out.setdefault((rank, label), [])

    # erst die sicheren Paare aus dem eigenen Ordner, dann die ueber das ganze Modul: jede Loesung steht nur einmal
    owner: dict = {}
    for kinds in ((NAME, IDENT), (MODULE,)):
        for e in exams:
            kind, ids = found.get(e["id"], ("", []))
            if kind in kinds:
                for sid in ids:
                    if sid in sols:
                        owner.setdefault(sid, e["id"])
    for e in exams:
        rows = rows_of(e)
        rows.append({**e, "exam_role": EXAM, "solution_of": None})
        rows.extend({**x, "exam_role": SOLUTION, "solution_of": e["id"]} for sid, x in sols.items() if owner.get(sid) == e["id"])
    for sid, x in sols.items():
        if sid not in owner:
            rows_of(x).append({**x, "exam_role": EXTRA, "solution_of": None})
    return [{"label": label or NO_FOLDER, "files": rows} for (_rank, label), rows in sorted(out.items(), key=lambda kv: kv[0])]


def _by_name(f: dict):
    """Reihenfolge nach Name wie von Hand sortiert: Zahlen nach ihrem Wert ("KK2" vor "KK10"), sonst Kleinschreibung"""
    name = f.get("name") or ""
    parts = []
    for x in re.findall(r"[0-9]+|[^0-9]+", name.lower()):
        d = x.lstrip("0") if x[0] in "0123456789" else None
        parts.append((0, len(d), d) if d is not None else (1, 0, x))
    return (parts, name, str(f.get("id") or ""))

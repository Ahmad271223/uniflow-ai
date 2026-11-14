"""Echte Lernaufgaben statt Dateinamen, mit Lernschritten (Auftrag des Inhabers 14.11.2026, Teil 2; Beispiele: Skript
und Arbeitsblaetter "Signale und Systeme"; docs/PLANER-FAECHER-WOCHENWUNSCH.md). Spiegel von StudyOutline.swift.

- Gliederung einer PDF aus ihrem Inhaltsverzeichnis (Lesezeichen): Abschnitte mit Nummer, Titel und Seiten, z. B.
  "2.3 Faltung" S. 25-26. Gespeichert je Datei in `file_outline` (mit chdate; neue Fassung = neu lesen).
- `parts`: eine Unterlage in Aufgaben, die in die Lernzeit passen, an Abschnittsgrenzen geteilt ("2.3 Faltung,
  2.4 Korrelation · S. 25-29"); ohne Gliederung nach Seiten ("S. 1-12"). Dauer nach Seiten (MIN_PER_PAGE).
- `steps`: feste Lernschritte je Aufgabenart zum Abhaken (ohne KI, Entscheidung des Inhabers 14.11.2026).
Keine KI, keine Netzanfrage."""
from __future__ import annotations

import json
import re
from pathlib import Path

from . import db

MIN_PER_PAGE = 4                      # Lesen mit Formeln: Minuten je Seite (Skript, Vorlesung)
SKIP = {"title", "titel", "titelseite", "inhaltsverzeichnis", "inhalt", "contents", "table of contents", "vorwort",
        "literatur", "literaturverzeichnis", "index", "stichwortverzeichnis", "abbildungsverzeichnis"}
NUM_RE = re.compile(r"^((?:[A-Z]|\d+)(?:\.\d+)*)\.?\s+(.+)$")
LONG_TITLE = 60


# ---------------------------------------------------------------- Gliederung

def sections_from_entries(entries: list[list], page_count: int) -> list[dict]:
    """Lesezeichen [Ebene, Titel, Seite (1-basiert)] -> Abschnitte [{number, title, chapter, from, to}].
    Benutzt werden die Kapitel der ersten Ebene, und wo ein Kapitel Unterabschnitte hat, diese (zweite Ebene) statt des
    Kapitels; tiefere Ebenen gehoeren zu ihrem Abschnitt. Gibt es nur einen obersten Eintrag mit Kindern (ein Rahmen
    wie "Skript"), zaehlt die Ebene darunter als erste. Titelseite, Inhaltsverzeichnis, Literatur u. ae. entfallen.
    Ein Abschnitt reicht bis vor den naechsten (mindestens seine Startseite), der letzte bis zur letzten Seite."""
    es = [[int(e[0]), str(e[1]).strip(), int(e[2])] for e in entries if 1 <= int(e[2]) <= max(1, page_count) and str(e[1]).strip()]
    if not es:
        return []
    top = min(e[0] for e in es)
    if sum(1 for e in es if e[0] == top) == 1 and any(e[0] > top for e in es):
        top += 1
        es = [e for e in es if e[0] >= top]
    used = []                                            # (Titel, Seite, Kapitel)
    chapter = ""
    for i, (lvl, title, page) in enumerate(es):
        if lvl == top:
            chapter = title
            has_child = i + 1 < len(es) and es[i + 1][0] == top + 1
            if not has_child:
                used.append((title, page, title))
        elif lvl == top + 1:
            used.append((title, page, chapter))
    out = []
    for title, page, chap in used:
        if title.lower().strip(" .:") in SKIP:
            continue
        m = NUM_RE.match(title)
        number, name = (m.group(1), m.group(2).strip()) if m else ("", title)
        out.append({"number": number, "title": name, "chapter": chap, "from": page})
    out.sort(key=lambda s: s["from"])                     # stabil (Swift: mit Index)
    for i, s in enumerate(out):
        nxt = out[i + 1]["from"] if i + 1 < len(out) else page_count + 1
        s["to"] = max(s["from"], nxt - 1)
    return out


def read_pdf(path: str) -> tuple[list[list], int] | None:
    """Lesezeichen und Seitenzahl einer PDF (pypdf); None, wenn die Datei fehlt oder nicht lesbar ist"""
    p = Path(path or "")
    if not p.is_file() or p.suffix.lower() != ".pdf":
        return None
    try:
        from pypdf import PdfReader
        r = PdfReader(str(p))
        entries: list[list] = []

        def walk(items, level):
            for it in items:
                if isinstance(it, list):
                    walk(it, level + 1)
                    continue
                try:
                    entries.append([level, it.title, r.get_destination_page_number(it) + 1])
                except Exception:  # noqa: BLE001 - Lesezeichen ohne Ziel
                    continue
        walk(r.outline, 0)
        return entries, len(r.pages)
    except Exception:  # noqa: BLE001 - beschaedigte PDF: keine Gliederung, Planen geht wie bisher
        return None


def store(conn, file_id: str, chdate, page_count: int, sections: list[dict], source: str) -> None:
    conn.execute("INSERT INTO file_outline(file_id, chdate, page_count, sections, source) VALUES (?,?,?,?,?) "
                 "ON CONFLICT(file_id) DO UPDATE SET chdate=excluded.chdate, page_count=excluded.page_count, "
                 "sections=excluded.sections, source=excluded.source",
                 (file_id, chdate, page_count, json.dumps(sections, ensure_ascii=False, separators=(",", ":")), source))


def refresh(conn, file_ids: list[str] | None = None) -> int:
    """Gliederung fuer lokale PDFs lesen, die noch keine haben oder seitdem geaendert wurden; Anzahl gelesener Dateien"""
    sql = """SELECT f.id, f.local_path, f.chdate, o.chdate AS ochdate FROM files f LEFT JOIN file_outline o ON o.file_id=f.id
             WHERE f.local_path IS NOT NULL AND f.deleted_at IS NULL AND lower(f.local_path) LIKE '%.pdf'
             AND (o.file_id IS NULL OR COALESCE(o.chdate,0) <> COALESCE(f.chdate,0))"""
    rows = db.rows(conn, sql)
    if file_ids is not None:
        rows = [r for r in rows if r["id"] in set(file_ids)]
    n = 0
    for r in rows:
        got = read_pdf(r["local_path"])
        if got is None:
            continue
        entries, pages = got
        secs = sections_from_entries(entries, pages)
        store(conn, r["id"], r["chdate"], pages, secs, "outline" if secs else "none")
        n += 1
    return n


def load(conn, file_id: str) -> dict | None:
    """{page_count, sections} aus file_outline (ohne Zeile: None)"""
    r = db.row(conn, "SELECT page_count, sections FROM file_outline WHERE file_id=?", (file_id,))
    if not r:
        return None
    try:
        secs = json.loads(r["sections"] or "[]")
    except (TypeError, ValueError):
        secs = []
    return {"page_count": int(r["page_count"] or 0), "sections": secs if isinstance(secs, list) else []}


# ---------------------------------------------------------------- Aufgaben

def pages(a: int, b: int) -> str:
    """Seitenangabe: S. 25–29, bei einer Seite S. 17"""
    return f"S. {a}" if a == b else f"S. {a}–{b}"


def label(s: dict) -> str:
    return f"{s['number']} {s['title']}".strip() if s.get("number") else s["title"]


def _title(secs: list[dict], a: int, b: int, piece: str = "") -> str:
    if len(secs) == 1:
        t = label(secs[0]) + piece
    elif len(secs) == 2 and len(label(secs[0])) + len(label(secs[1])) <= LONG_TITLE:
        t = f"{label(secs[0])}, {label(secs[1])}"
    else:
        last = secs[-1]
        t = f"{label(secs[0])} bis {last['number'] or last['title']}"
    return f"{t} · {pages(a, b)}"


def est_total(est: int, page_count: int, kind: str) -> int:
    """Dauer einer ganzen Unterlage: die geschaetzte, bei Skript/Vorlesung mindestens MIN_PER_PAGE je Seite"""
    if kind in ("vorlesung", "skript") and page_count:
        return max(int(est or 0), page_count * MIN_PER_PAGE)
    return int(est or 0)


def parts(sections: list[dict], page_count: int, total: int, budget: int, first: int = 1, last: int | None = None,
          name: str = "") -> list[dict]:
    """Seiten first..last einer Unterlage (Dauer `total` fuer alle `page_count` Seiten) in Aufgaben bis `budget`
    Minuten: ganze Abschnitte zusammen, ein zu langer Abschnitt nach Seiten geteilt; ohne Abschnitte nach Seiten.
    Ergebnis [{title, est, from, to}]."""
    last = page_count if last is None else min(last, page_count)
    if page_count <= 0 or first > last:
        return []
    def mins(a, b):                                      # ganzzahlig (gleich in Swift): aufgerundet, mindestens 5
        return max(5, -(-(total * (b - a + 1)) // page_count))
    span = max(1, budget * page_count // total) if total > 0 else last - first + 1
    out: list[dict] = []
    secs = [dict(s, **{"from": max(s["from"], first), "to": min(s["to"], last)}) for s in sections
            if s["to"] >= first and s["from"] <= last]
    if not secs:
        n = -(-(last - first + 1) // span)
        for k in range(n):
            a = first + k * span
            b = min(last, a + span - 1)
            out.append({"title": f"{name} · {pages(a, b)}".strip(" ·"), "est": mins(a, b), "from": a, "to": b})
        return out
    per_chapter: dict[str, int] = {}
    for x in sections:
        per_chapter[x.get("chapter") or ""] = per_chapter.get(x.get("chapter") or "", 0) + 1

    def close(cur):                                      # ein ganzes Kapitel heisst wie das Kapitel
        ch = cur[0].get("chapter") or ""
        whole = len(cur) > 1 and ch and len(cur) == per_chapter.get(ch, 0)
        t = f"{ch} · {pages(cur[0]['from'], cur[-1]['to'])}" if whole else _title(cur, cur[0]["from"], cur[-1]["to"])
        out.append({"title": t, "est": mins(cur[0]["from"], cur[-1]["to"]), "from": cur[0]["from"], "to": cur[-1]["to"]})
    cur: list[dict] = []
    for s in secs:
        # nie ueber eine Kapitelgrenze, nie ueber die Lernzeit
        if cur and (mins(cur[0]["from"], s["to"]) > budget or (s.get("chapter") or "") != (cur[0].get("chapter") or "")):
            close(cur)
            cur = []
        if mins(s["from"], s["to"]) > budget:               # ein Abschnitt allein ist zu lang: nach Seiten
            n = -(-(s["to"] - s["from"] + 1) // span)
            for k in range(n):
                a = s["from"] + k * span
                b = min(s["to"], a + span - 1)
                out.append({"title": _title([s], a, b, f", Teil {k + 1}/{n}" if n > 1 else ""), "est": mins(a, b), "from": a, "to": b})
            continue
        cur.append(s)
    if cur:
        close(cur)
    return out


# ---------------------------------------------------------------- Lernschritte

def steps(kind: str, a: int | None = None, b: int | None = None) -> list[str]:
    """Lernschritte zum Abhaken (einfaches Deutsch, ohne KI)"""
    where = f" auf {pages(a, b)}" if a and b else ""
    if kind in ("vorlesung", "skript"):
        return [f"Überfliegen: Überschriften, Formeln und Bilder{where} ansehen",
                "Lesen und die wichtigsten Definitionen und Formeln herausschreiben",
                "Ein Beispiel aus dem Abschnitt selbst nachrechnen",
                "In zwei Sätzen erklären, worum es geht"]
    if kind == "uebung":
        return ["Aufgabe lesen: Was ist gegeben, was ist gesucht?",
                "Passende Formel oder den passenden Abschnitt im Skript suchen",
                "Lösungsweg aufschreiben und rechnen",
                "Ergebnis prüfen: Einheit, Vorzeichen, Größenordnung"]
    if kind == "loesung":
        return ["Erst ohne Lösung versuchen",
                "Mit der Lösung vergleichen und Fehler markieren",
                "Die schwierigste Stelle noch einmal ohne Lösung rechnen"]
    return []


def steps_json(kind: str, a: int | None = None, b: int | None = None) -> str | None:
    s = steps(kind, a, b)
    return json.dumps(s, ensure_ascii=False, separators=(",", ":")) if s else None

"""Intelligente Skriptsuche: zur Aufgabe auf einem Uebungsblatt die passende Stelle im Vorlesungsskript finden.

Ohne KI-Aufruf: Seitentexte der Vorlesungs-/Skript-PDFs eines Moduls werden einmal mit pypdf gelesen und in
`page_texts` gespeichert. Die Suche ist BM25 ueber Woerter mit einfacher deutscher Wortstamm-Kuerzung.
Ergebnisse unter einer Mindestguete werden nicht gezeigt (lieber kein Hinweis als ein falscher).
"""
from __future__ import annotations

import math
import re
import threading
import unicodedata
from collections import Counter
from pathlib import Path

from . import config, db, study

import logging
logging.getLogger("pypdf").setLevel(logging.ERROR)

STOP = set("""
aber alle allem allen aller alles also als am an andere anderen auch auf aus bei beide beiden beim bereits bestimmen
bestimmt berechnen berechne bis bitte da dabei damit dann das dass dem den denen der deren des dessen die dies diese
diesem diesen dieser dieses doch dort du durch ein eine einem einen einer eines einige er es etwa euch falls fuer für
gegeben gegebene gegebenen gilt gibt habe haben hat hier ihr ihre im in ins ist ja je jede jedem jeden jeder jedes
kann koennen können man mit muss nach neben nicht noch nun nur ob oder ohne sei seien sein seine sich sie sind so
sodass soll sollen sowie ueber über um und uns unter vom von vor wann war was weil welche welchem welchen welcher
wenn wer werden wie wieder wir wird wo zeigen zeige zu zum zur zwei drei vier fünf funf aufgabe aufgaben teilaufgabe
blatt übung uebung übungsblatt hinweis lösung loesung punkte punkt folgende folgenden folgendes beweisen begründen
geben gib skizzieren betrachten betrachte seite folie vorlesung kapitel definition satz beispiel bemerkung lemma relevant relevanter klausur klausurrelevant stoff tranche
""".split())


def normalize(text: str) -> str:
    """pypdf liefert Umlaute oft zerlegt ("Unabh¨ angigkeit", "ä")."""
    t = text or ""
    for base, uml in (("a", "ä"), ("o", "ö"), ("u", "ü"), ("A", "Ä"), ("O", "Ö"), ("U", "Ü")):
        t = re.sub("¨" + r"\s*" + base, uml, t)
        t = t.replace(base + "̈", uml)
    return t


def search_form(text: str) -> str:
    """Suchform eines Seitentexts fuer find_pages: normalize, klein, NFC. SQLite lower() und LIKE kennen nur ASCII
    ("Übung" passte nicht auf "übung"), und zerlegte Umlaute passten nicht auf die Anfrage."""
    return unicodedata.normalize("NFC", normalize(text).lower())


def contains(q: str, *texts) -> bool:
    """Steht die Anfrage als Teiltext in einem der Texte, beides in der Suchform? Fuer Namen, Titel und Faecher der
    globalen Suche (api_search); ohne SQL-Muster, also ohne Platzhalter."""
    form = search_form(q)
    return any(form in search_form(t) for t in texts if t)


def like_pattern(text: str) -> str:
    """LIKE-Muster "enthaelt text" fuer ESCAPE '!': %, _ und ! im Text sind keine Platzhalter."""
    return "%" + re.sub(r"([!%_])", r"!\1", text) + "%"


def tokens(text: str) -> list[str]:
    out = []
    for w in re.findall(r"[a-zäöüß]{3,}", normalize(text).lower()):
        if w in STOP:
            continue
        for suf in ("ungen", "ung", "en", "er", "es", "em", "e", "n", "s"):
            if len(w) > 5 and w.endswith(suf):
                w = w[: -len(suf)]
                break
        if len(w) >= 3 and w not in STOP:
            out.append(w)
    return out


# ---------------------------------------------------------------- Seitentexte zwischenspeichern

def ensure_table(conn) -> None:
    conn.execute("""CREATE TABLE IF NOT EXISTS page_texts (
        file_id TEXT NOT NULL, page INTEGER NOT NULL, text TEXT, chdate INTEGER, search TEXT,
        PRIMARY KEY (file_id, page))""")
    # Suchform (search_form) kam spaeter dazu; aeltere Zeilen bekommen sie in find_pages
    if "search" not in {r[1] for r in conn.execute("PRAGMA table_info(page_texts)")}:
        conn.execute("ALTER TABLE page_texts ADD COLUMN search TEXT")


def _extract_pages(path: str) -> list[str]:
    from pypdf import PdfReader
    reader = PdfReader(path)
    pages = []
    for p in reader.pages:
        try:
            pages.append(p.extract_text() or "")
        except Exception:  # noqa: BLE001
            pages.append("")
    return pages


def _extract_bytes(data: bytes) -> list[str]:
    import io
    from pypdf import PdfReader
    reader = PdfReader(io.BytesIO(data))
    pages = []
    for p in reader.pages:
        try:
            pages.append(p.extract_text() or "")
        except Exception:  # noqa: BLE001
            pages.append("")
    return pages


def store_pages(conn, file_id: str, pages: list[str], chdate) -> None:
    """Seitentexte einer Datei ablegen (alte Fassung weg), mit `chdate` der Datei und der Suchform fuer find_pages.
    Gemeinsam fuer PDF auf der Platte, Durchreichen (index_bytes) und den Geraete-Abgleich (PUT /api/files/{id}/pagetext,
    das Geraet liest den Text selbst). Der BM25-Index je Modul wird verworfen, damit /api/related die Seiten sieht."""
    ensure_table(conn)
    conn.execute("DELETE FROM page_texts WHERE file_id=?", (file_id,))
    conn.executemany("INSERT INTO page_texts(file_id, page, text, chdate, search) VALUES (?,?,?,?,?)",
                     [(file_id, i + 1, t or "", chdate, search_form(t or "")) for i, t in enumerate(pages)])
    with _LOCK:
        _CACHE.clear()


def index_bytes(conn, file_id: str, data: bytes, chdate) -> list[str]:
    """Seitentexte aus Bytes (Betriebsart stream: Datei liegt nicht auf der Platte) ablegen, wenn noch nicht vorhanden."""
    ensure_table(conn)
    rows = db.rows(conn, "SELECT page, text, chdate FROM page_texts WHERE file_id=? ORDER BY page", (file_id,))
    if rows and all((r["chdate"] or 0) == (chdate or 0) for r in rows):
        return [r["text"] or "" for r in rows]
    try:
        pages = _extract_bytes(data)
    except Exception:  # noqa: BLE001
        return []
    store_pages(conn, file_id, pages, chdate)
    return pages


def page_texts(conn, file_id: str) -> list[str]:
    """Alle Seitentexte einer Datei (aus dem Zwischenspeicher, sonst neu gelesen; im Dienst ohne Datei auf der Platte
    ueber app/filestream.py, das die Seitentexte beim Durchreichen ablegt)."""
    ensure_table(conn)
    f = db.row(conn, "SELECT local_path, chdate, name, download_url, course_id FROM files WHERE id=?", (file_id,))
    if not f:
        return []
    rows = db.rows(conn, "SELECT page, text, chdate FROM page_texts WHERE file_id=? ORDER BY page", (file_id,))
    if rows and all((r["chdate"] or 0) == (f["chdate"] or 0) for r in rows):
        return [r["text"] or "" for r in rows]
    has_file = f["local_path"] and Path(f["local_path"]).exists() and f["local_path"].lower().endswith(".pdf")
    if not has_file:
        if config.streams_files() and f["download_url"] and (f["name"] or "").lower().endswith(".pdf"):
            from . import filestream
            try:
                filestream.content(conn, file_id)
            except Exception:  # noqa: BLE001 - keine Sitzung, keine Datei: dann eben kein Text
                return []
            return [r["text"] or "" for r in db.rows(conn, "SELECT text FROM page_texts WHERE file_id=? ORDER BY page", (file_id,))]
        return []
    try:
        pages = _extract_pages(f["local_path"])
    except Exception:  # noqa: BLE001
        return []
    store_pages(conn, file_id, pages, f["chdate"] or 0)
    return pages


# ---------------------------------------------------------------- Index je Modul (BM25)

_CACHE: dict[tuple, dict] = {}
_LOCK = threading.Lock()


def _sources(conn, module_id: int, exclude: str | None) -> list[dict]:
    files = study._file_rows(conn, module_id)
    out = []
    for f in files:
        if f["id"] == exclude or not (f.get("name") or "").lower().endswith(".pdf"):
            continue
        if f.get("doc_type") in ("vorlesung", "skript"):
            out.append(f)
    return out


def _index(conn, module_id: int) -> dict:
    srcs = _sources(conn, module_id, None)
    key = (module_id, tuple(sorted((f["id"], f.get("chdate") or 0) for f in srcs)))
    with _LOCK:
        if key in _CACHE:
            return _CACHE[key]
    docs = []
    for f in srcs:
        for i, text in enumerate(page_texts(conn, f["id"])):
            toks = tokens(text)
            if len(toks) < 5:
                continue
            docs.append({"file": f, "page": i + 1, "tf": Counter(toks), "len": len(toks), "text": text})
    df = Counter()
    for d in docs:
        df.update(d["tf"].keys())
    avg = sum(d["len"] for d in docs) / max(1, len(docs))
    idx = {"docs": docs, "df": df, "avg": avg, "n": len(docs)}
    with _LOCK:
        _CACHE.clear() if len(_CACHE) > 20 else None
        _CACHE[key] = idx
    return idx


def _snippet(text: str, terms: list[str], width: int = 170) -> str:
    flat = re.sub(r"\s+", " ", text or "").strip()
    low = flat.lower()
    pos = min((low.find(t) for t in terms if low.find(t) >= 0), default=0)
    start = max(0, pos - 50)
    return ("…" if start else "") + flat[start:start + width] + ("…" if start + width < len(flat) else "")


def search(conn, module_id: int, query: str, exclude: str | None = None, limit: int = 3) -> dict:
    q = tokens(query)
    if not q:
        return {"terms": [], "results": []}
    idx = _index(conn, module_id)
    if not idx["n"]:
        return {"terms": [], "results": [], "note": "keine Vorlesungs- oder Skriptseiten im Modul"}
    qtf = Counter(q)
    k1, b = 1.4, 0.75
    scored = []
    for d in idx["docs"]:
        if d["file"]["id"] == exclude:
            continue
        s, hit = 0.0, []
        for t, qn in qtf.items():
            tf = d["tf"].get(t)
            if not tf:
                continue
            idf = math.log(1 + (idx["n"] - idx["df"][t] + 0.5) / (idx["df"][t] + 0.5))
            s += idf * tf * (k1 + 1) / (tf + k1 * (1 - b + b * d["len"] / idx["avg"])) * min(qn, 2)
            hit.append(t)
        if len(hit) >= 2:
            scored.append((s, hit, d))
    scored.sort(key=lambda x: -x[0])
    # Mindestguete: absolute Punktzahl und deutlicher Abstand zum Durchschnitt
    mean = sum(x[0] for x in scored) / len(scored) if scored else 0
    results = []
    seen = set()
    for s, hit, d in scored:
        if s < 6 or (mean and s < mean * 1.6):
            break
        key = re.sub(r"\W+", "", normalize(d["text"]))[:120]   # Druckfassung derselben Folie nicht doppelt
        if key in seen:
            continue
        seen.add(key)
        f = d["file"]
        results.append({"file_id": f["id"], "title": f.get("ai_title") or f.get("name"), "name": f.get("name"), "label": f.get("sub_label"),
                        "page": d["page"], "score": round(s, 2), "terms": sorted(hit, key=lambda t: -idx["df"].get(t, 0))[:6],
                        "snippet": _snippet(normalize(d["text"]), hit)})
        if len(results) >= limit:
            break
    return {"terms": sorted(set(q))[:20], "results": results}


def find_pages(conn, q: str, limit: int = 10) -> list[dict]:
    """Seiten, deren gespeicherter Text den Suchtext enthaelt (globale Suche). Nur Seitentexte der aktuellen Fassung
    (gleiche Aenderungszeit wie die Datei) von Dateien, die vorhanden sind (nach "Dateien löschen" kein Treffer, der
    sich nicht oeffnen laesst), nicht im Papierkorb und aus gewaehlten Kursen (wie die Bibliothek); gelesen wird dabei
    nichts neu. In der Betriebsart stream (Dienst) gilt eine Hochschuldatei mit Quelle als vorhanden: das Geraet laedt
    sie selbst bzw. der Dienst reicht sie durch, auf der Platte liegt sie nie. `q` ist schon klein geschrieben.
    Verglichen wird die Suchform von Text und Anfrage (search_form), % und _ in der Anfrage sind keine Platzhalter
    (like_pattern); Zeilen von vor der Suchform bekommen sie hier."""
    ensure_table(conn)
    for r in db.rows(conn, "SELECT file_id, page, text FROM page_texts WHERE search IS NULL"):
        conn.execute("UPDATE page_texts SET search=? WHERE file_id=? AND page=?", (search_form(r["text"]), r["file_id"], r["page"]))
    rows = db.rows(conn, """SELECT p.file_id, p.page, p.text, f.name, a.title AS ai_title, c.subject, c.module_id
                             FROM page_texts p JOIN files f ON f.id=p.file_id JOIN courses c ON c.id=f.course_id
                             LEFT JOIN analysis a ON a.file_id=f.id
                             WHERE COALESCE(p.chdate, 0)=COALESCE(f.chdate, 0)
                               AND (COALESCE(f.local_path, '')<>'' OR (? AND COALESCE(f.download_url, '')<>'' AND f.course_id<>'__user__'))
                               AND f.deleted_at IS NULL AND c.active=1 AND p.search LIKE ? ESCAPE '!'
                             ORDER BY f.chdate DESC, p.file_id, p.page LIMIT ?""",
                   (1 if config.streams_files() else 0, like_pattern(search_form(q)), limit))
    return [{"file_id": r["file_id"], "page": r["page"], "name": r["name"], "ai_title": r["ai_title"], "subject": r["subject"],
             "module_id": r["module_id"], "snippet": _snippet(normalize(r["text"]), [q])} for r in rows]


def index_all(conn, log=print) -> int:
    """Seitentexte aller Vorlesungs-/Skript-PDFs vorab lesen (nach dem Sync, damit die erste Suche schnell ist)."""
    ensure_table(conn)
    n = 0
    for m in db.rows(conn, "SELECT id FROM modules"):
        for f in _sources(conn, m["id"], None):
            n += 1 if page_texts(conn, f["id"]) else 0
    log(f"Skriptsuche: {n} Skripte indiziert")
    return n

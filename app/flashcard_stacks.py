"""Karteikarten-Stapel (Wunsch des Inhabers vom 04.11.2026, docs/PREISLISTE.md): Karten gehoeren zu einem Modul und
optional zu einer Lehrwoche; dazu die KI auf Auftrag ("Analysis I, Lernwoche 5, 30 Karten", Pro AI) und das Uebernehmen
geteilter Stapel aus der Community (Plus, app/community_decks.py).

Stapel
  Ein Stapel ist (Modul, Lehrwoche); Lehrwoche NULL = Karten fuer das ganze Modul. Spalten in `flashcards`
  (app/db.py, rueckwaertskompatibel angehaengt): `module_id`, `lecture_week`, `origin` (NULL = selbst angelegt, 'ai' =
  KI-Auftrag, 'community:<stapel-id>' = aus der Community uebernommen). Aeltere Karten ohne `module_id` gehoeren zum
  Modul ihres Dokuments (`file_id` -> Kurs -> Modul); ohne beides stehen sie unter "Ohne Modul". Die Spalten laufen
  mit der Geraete-Synchronisierung (app/sync.py, `module_id` als Fremdschluessel auf modules).

KI-Auftrag (POST /api/ai/flashcards mit module_id statt file_id)
  Material genau dieser Lehrwoche: zuerst die mit "Vorlesung bis hier" markierten Seiten der Woche (app/weekly.py),
  dann Vorlesungen und Skripte der Woche (gleiche Wochenregel wie Moduldetail und Lernplan: study.file_week), dann
  Uebungen der Woche. Ganzes Modul: Vorlesungen und Skripte aller Wochen, gleichmaessig ausgewaehlt. Hoechstens
  STACK_TEXT_CHARS Zeichen. Vorhandene Karten des Moduls stehen im Prompt ("nicht wiederholen") und werden danach
  noch einmal ausgefiltert (gleiche oder fast gleiche Frage). Ergebnis ist ein Vorschlag; gespeichert wird erst mit
  POST /api/flashcards/stack.
"""
from __future__ import annotations

import json
import re
from datetime import date

from . import db

STACK_COUNT_MIN, STACK_COUNT_MAX, STACK_COUNT_DEFAULT = 5, 50, 20
STACK_TEXT_CHARS = 24_000            # Material im Prompt (Zeichen)
PAGE_CHARS = 2_500                   # hoechstens so viel Text einer Seite
MAX_FILES_WEEK, MAX_FILES_MODULE = 8, 12
EXISTING_IN_PROMPT, EXISTING_CHARS = 80, 5_000
MAX_SIDE = 4_000                     # Zeichen je Kartenseite (Frage bzw. Antwort)
MAX_CARDS = 500                      # Karten je Anfrage (wie ein Community-Stapel)
WEEK_MAX = 30
TOPIC_CHARS = 300
SIMILAR = 0.85                       # Wortueberschneidung (Jaccard), ab der zwei Fragen als gleich gelten
ORIGIN_RE = re.compile(r"^(ai|community:[0-9a-f]{32})$")

# Modul der Karte: eigenes Modul, sonst das Modul des Dokuments
EFFECTIVE_MODULE = "COALESCE(fc.module_id, c.module_id)"
CARD_JOIN = "flashcards fc LEFT JOIN files f ON f.id=fc.file_id LEFT JOIN courses c ON c.id=f.course_id"


class StackError(ValueError):
    def __init__(self, code: str, message: str, status: int = 400):
        super().__init__(message)
        self.code, self.message, self.status = code, message, status


# ---------------------------------------------------------------- Eingaben

def parse_week(v) -> int | None:
    """Lehrwoche aus der Anfrage: None/""/"module" = ganzes Modul, sonst ganze Zahl 1..WEEK_MAX."""
    if v is None or v == "" or v == "module":
        return None
    if isinstance(v, bool):
        raise StackError("week_invalid", "Ungültige Lernwoche.")
    try:
        w = int(v)
    except (TypeError, ValueError):
        raise StackError("week_invalid", "Ungültige Lernwoche.")
    if isinstance(v, float) and v != w:
        raise StackError("week_invalid", "Ungültige Lernwoche.")
    if not 1 <= w <= WEEK_MAX:
        raise StackError("week_invalid", f"Die Lernwoche liegt zwischen 1 und {WEEK_MAX}.")
    return w


def parse_module(v) -> int:
    if isinstance(v, bool):
        raise StackError("module_invalid", "Ungültiges Modul.")
    try:
        m = int(v)
    except (TypeError, ValueError):
        raise StackError("module_invalid", "Bitte ein Modul wählen.")
    if m < 1:
        raise StackError("module_invalid", "Bitte ein Modul wählen.")
    return m


def stack_count(n) -> int:
    """Zahl der Karten eines KI-Auftrags: STACK_COUNT_MIN..STACK_COUNT_MAX (begrenzt), Unlesbares -> Vorgabe."""
    if isinstance(n, bool):
        return STACK_COUNT_DEFAULT
    try:
        v = int(n)
    except (TypeError, ValueError):
        return STACK_COUNT_DEFAULT
    return max(STACK_COUNT_MIN, min(STACK_COUNT_MAX, v))


def parse_origin(v) -> str | None:
    if v is None or v == "":
        return None
    if not isinstance(v, str) or not ORIGIN_RE.match(v):
        raise StackError("origin_invalid", "Unbekannte Herkunft der Karten.")
    return v


def clean_cards(raw, limit: int = MAX_CARDS, side: int = MAX_SIDE) -> list[dict]:
    """Karten aus einer Anfrage: Liste von {question, answer} (Text, aussen ohne Leerraum, nicht leer, je Seite
    hoechstens `side` Zeichen); Unbrauchbares wird uebersprungen, mehr als `limit` ist ein Fehler."""
    if not isinstance(raw, list):
        raise StackError("cards_invalid", "Karten fehlen.")
    if len(raw) > limit:
        raise StackError("too_many_cards", f"Höchstens {limit} Karten auf einmal.")
    out = []
    for c in raw:
        if not isinstance(c, dict):
            continue
        q, a = c.get("question"), c.get("answer")
        if not isinstance(q, str) or not isinstance(a, str):
            continue
        q, a = q.strip(), a.strip()
        if not q or not a:
            continue
        if len(q) > side or len(a) > side:
            raise StackError("text_too_long", f"Eine Kartenseite hat höchstens {side} Zeichen.")
        out.append({"question": q, "answer": a})
    return out


# ---------------------------------------------------------------- Doppelte erkennen

def norm_q(text: str) -> str:
    """Frage zum Vergleichen: klein, nur Buchstaben/Ziffern, Leerraum zusammengefasst."""
    return " ".join(re.findall(r"\w+", (text or "").lower()))


def _words(text: str) -> set[str]:
    return {w for w in norm_q(text).split() if len(w) > 2}


def is_duplicate(question: str, known_norm: set[str], known_words: list[set[str]]) -> bool:
    n = norm_q(question)
    if not n or n in known_norm:
        return True
    w = _words(question)
    if len(w) < 3:
        return False
    return any(k and len(w & k) / len(w | k) >= SIMILAR for k in known_words)


def without_duplicates(cards: list[dict], existing: list[str]) -> tuple[list[dict], int]:
    """Karten ohne die, deren Frage es schon gibt (auch fast gleich) oder die im selben Auftrag doppelt sind."""
    known_norm = {norm_q(q) for q in existing}
    known_words = [_words(q) for q in existing]
    out, dropped = [], 0
    for c in cards:
        if is_duplicate(c["question"], known_norm, known_words):
            dropped += 1
            continue
        out.append(c)
        known_norm.add(norm_q(c["question"]))
        known_words.append(_words(c["question"]))
    return out, dropped


# ---------------------------------------------------------------- Lesen: Stapel und Karten

def module_row(conn, module_id: int) -> dict:
    m = db.row(conn, "SELECT id, name, color, semester FROM modules WHERE id=?", (module_id,))
    if not m:
        raise StackError("module_not_found", "Modul nicht gefunden.", 404)
    return m


def stack_cards(conn, module_id: int | None, week: int | None) -> list[dict]:
    return db.rows(conn, f"SELECT fc.* FROM {CARD_JOIN} WHERE {EFFECTIVE_MODULE} IS ? AND fc.lecture_week IS ? ORDER BY fc.id",
                   (module_id, week))


def module_questions(conn, module_id: int, week: int | None) -> list[str]:
    """Fragen des Moduls, die Karten des Stapels zuerst (fuer den Prompt und den Doppel-Filter)."""
    rows = db.rows(conn, f"SELECT fc.question, fc.lecture_week FROM {CARD_JOIN} WHERE {EFFECTIVE_MODULE}=? ORDER BY fc.id", (module_id,))
    same = [r["question"] for r in rows if r["lecture_week"] == week]
    return same + [r["question"] for r in rows if r["lecture_week"] != week]


def _week_info(conn) -> tuple:
    from . import study
    start = study.semester_start(conn)
    return start, study.day_week(start, study.today())


def module_weeks(conn, module_id: int, start=None) -> list[dict]:
    """Lehrwochen eines Moduls mit Unterlagen (gleiche Regel wie das Moduldetail): Woche, Beschriftung, Thema, Dateien."""
    from . import study
    start = start or study.semester_start(conn)
    groups: dict[int, list] = {}
    for f in study._file_rows(conn, module_id):
        w = study.file_week(start, f)
        if 1 <= w <= WEEK_MAX:
            groups.setdefault(w, []).append(f)
    return [{"week": w, "label": study.week_label(start, w), "topic": study.week_topic(groups[w]), "files": len(groups[w])}
            for w in sorted(groups)]


def stack_label(week: int | None, start=None) -> str:
    if week is None:
        return "Ganzes Modul"
    if start is None:
        return f"Woche {week}"
    from . import study
    return study.week_label(start, week)


def overview(conn, with_weeks: bool = True) -> dict:
    """Alle Stapel (auch "Ohne Modul") mit Zahlen und Karten-IDs, dazu die aktiven Module samt Lehrwochen fuer den
    KI-Auftrag und die aktuelle Lehrwoche."""
    start, current = _week_info(conn)
    today = date.today().isoformat()
    rows = db.rows(conn, f"""SELECT fc.id, fc.due, fc.hidden, fc.last_result, fc.origin, fc.lecture_week, {EFFECTIVE_MODULE} AS mid
                             FROM {CARD_JOIN} ORDER BY fc.id""")
    names = {m["id"]: m for m in db.rows(conn, "SELECT id, name, color, COALESCE(active, 1) AS active FROM modules")}
    groups: dict[tuple, dict] = {}
    for r in rows:
        mid = r["mid"] if r["mid"] in names else None
        week = r["lecture_week"] if mid is not None else None
        g = groups.get((mid, week))
        if g is None:
            m = names.get(mid) or {}
            g = groups[(mid, week)] = {"key": f"{mid or 0}:{week if week is not None else 'module'}", "module_id": mid,
                                       "module_name": m.get("name") or "Ohne Modul", "color": m.get("color"), "lecture_week": week,
                                       "label": stack_label(week, start) if mid is not None else "Weitere Karten",
                                       "count": 0, "due": 0, "right": 0, "wrong": 0, "unlearned": 0, "hidden": 0,
                                       "origins": {"own": 0, "ai": 0, "community": 0}, "card_ids": []}
        g["count"] += 1
        g["card_ids"].append(r["id"])
        hidden = bool(r["hidden"]) and r["hidden"] != 0
        if hidden:
            g["hidden"] += 1
        else:
            g[r["last_result"] if r["last_result"] in ("right", "wrong") else "unlearned"] += 1
            if r["due"] is None or str(r["due"]) <= today:
                g["due"] += 1
        o = r["origin"] or ""
        g["origins"]["ai" if o == "ai" else "community" if o.startswith("community:") else "own"] += 1
    stacks = sorted(groups.values(), key=lambda g: (g["module_id"] is None, (g["module_name"] or "").lower(),
                                                    g["lecture_week"] is not None, g["lecture_week"] or 0))
    out = {"stacks": stacks, "current_week": current if current >= 1 else None}
    if with_weeks:
        mods = db.rows(conn, "SELECT id, name, color FROM modules WHERE COALESCE(active, 1)=1 ORDER BY sort, name")
        out["modules"] = [{"id": m["id"], "name": m["name"], "color": m["color"], "weeks": module_weeks(conn, m["id"], start)} for m in mods]
    return out


# ---------------------------------------------------------------- Schreiben

def add_cards(conn, module_id, week, raw_cards, origin=None, file_id=None) -> dict:
    """Karten in einen Stapel legen; gleiche oder fast gleiche Fragen des Stapels werden uebersprungen."""
    mid = parse_module(module_id)
    w = parse_week(week)
    org = parse_origin(origin)
    m = module_row(conn, mid)
    cards = clean_cards(raw_cards)
    fid = file_id if isinstance(file_id, str) and file_id and db.row(conn, "SELECT 1 FROM files WHERE id=?", (file_id,)) else None
    existing = [c["question"] for c in stack_cards(conn, mid, w)]
    fresh, skipped = without_duplicates(cards, existing)
    ids = []
    today, now = date.today().isoformat(), db.now_iso()
    for c in fresh:
        cur = conn.execute("""INSERT INTO flashcards(file_id, subject, question, answer, created_at, box, due, module_id, lecture_week, origin)
                              VALUES (?,?,?,?,?,1,?,?,?,?)""", (fid, m["name"], c["question"], c["answer"], now, today, mid, w, org))
        ids.append(cur.lastrowid)
    return {"added": len(ids), "skipped": skipped, "ids": ids, "module_id": mid, "lecture_week": w}


def move_cards(conn, ids, module_id, week) -> dict:
    """Karten in einen anderen Stapel legen (z. B. aeltere Karten einer Woche zuordnen)."""
    if not isinstance(ids, list) or not ids or len(ids) > MAX_CARDS or not all(isinstance(i, int) and not isinstance(i, bool) for i in ids):
        raise StackError("ids_invalid", "Welche Karten?")
    mid = parse_module(module_id)
    w = parse_week(week)
    module_row(conn, mid)
    q = ",".join("?" * len(ids))
    n = conn.execute(f"UPDATE flashcards SET module_id=?, lecture_week=? WHERE id IN ({q})", (mid, w, *ids)).rowcount
    return {"moved": n, "module_id": mid, "lecture_week": w}


# ---------------------------------------------------------------- Material fuer den KI-Auftrag

def _marker_pages(conn, module_id: int, week: int) -> dict[str, list[int]]:
    """Mit "Vorlesung bis hier" markierte Seiten der Woche je Datei (app/weekly.py), leer ohne Marker."""
    try:
        from . import weekly
        cov = weekly.coverage(conn, module_id)
    except Exception:  # noqa: BLE001 - Marker sind ein Zusatz
        return {}
    out: dict[str, list[int]] = {}
    for s in cov.get("segments") or []:
        if s.get("week") == week:
            out.setdefault(s["file_id"], []).extend(range(int(s["from"]), int(s["to"]) + 1))
    return out


def _pick(pages: list[tuple[int, str]], budget: int) -> list[tuple[int, str]]:
    """Seiten innerhalb des Budgets: alle, wenn sie passen, sonst gleichmaessig verteilt (jede k-te Seite)."""
    pages = [(p, t.strip()[:PAGE_CHARS]) for p, t in pages if t and t.strip()]
    total = sum(len(t) for _, t in pages)
    if total <= budget or not pages:
        return pages
    step = -(-total // max(1, budget))
    picked = pages[::step] or pages[:1]
    out, used = [], 0
    for p, t in picked:
        if used >= budget:
            break
        t = t[:budget - used]
        out.append((p, t))
        used += len(t)
    return out


def week_material(conn, module_id: int, week: int | None, budget: int = STACK_TEXT_CHARS) -> dict:
    """Text fuer den KI-Auftrag: {"text", "sources": [{file_id, name, pages}], "markers": bool}. Leer ohne lesbaren Text."""
    from . import scriptsearch, study
    start = study.semester_start(conn)
    files = study._file_rows(conn, module_id)
    by_id = {f["id"]: f for f in files}
    plan: list[tuple[dict, list[int] | None]] = []
    markers = {}
    if week is not None:
        markers = _marker_pages(conn, module_id, week)
        for fid, pages in markers.items():
            if fid in by_id:
                plan.append((by_id[fid], sorted(set(pages))))
        wf = [f for f in files if study.file_week(start, f) == week and f["id"] not in markers]
        plan += [(f, None) for f in wf if f.get("doc_type") in ("vorlesung", "skript")]
        plan += [(f, None) for f in wf if f.get("doc_type") == "uebung"]
        plan = plan[:MAX_FILES_WEEK]
    else:
        lect = [f for f in files if f.get("doc_type") in ("vorlesung", "skript") and study.file_week(start, f) >= 0]
        if not lect:
            lect = [f for f in files if f.get("doc_type") == "uebung" and study.file_week(start, f) >= 0]
        lect.sort(key=lambda f: (study.file_week(start, f), f.get("name") or ""))
        if len(lect) > MAX_FILES_MODULE:                     # gleichmaessig ueber das Semester
            step = len(lect) / MAX_FILES_MODULE
            lect = [lect[int(i * step)] for i in range(MAX_FILES_MODULE)]
        plan = [(f, None) for f in lect]
    texts: list[tuple[dict, list[tuple[int, str]]]] = []
    for f, pages in plan:
        try:
            all_pages = scriptsearch.page_texts(conn, f["id"])
        except Exception:  # noqa: BLE001 - eine unlesbare Datei laesst die anderen gelten
            continue
        chosen = [(p, all_pages[p - 1]) for p in (pages or range(1, len(all_pages) + 1)) if 1 <= p <= len(all_pages)]
        chosen = [(p, t) for p, t in chosen if t and t.strip()]
        if chosen:
            texts.append((f, chosen))
    parts, sources, left = [], [], budget
    for i, (f, chosen) in enumerate(texts):
        share = left // (len(texts) - i)                     # Rest gleichmaessig auf die uebrigen Dateien
        picked = _pick(chosen, share)
        if not picked:
            continue
        name = f.get("ai_title") or f.get("name") or "Dokument"
        for p, t in picked:
            block = f"### {name}, Seite {p}\n{t}"
            parts.append(block)
            left -= len(t)
        sources.append({"file_id": f["id"], "name": f.get("name"), "pages": [p for p, _ in picked], "marked": f["id"] in markers})
    return {"text": "\n\n".join(parts), "sources": sources, "markers": bool(markers)}


def client_material(raw, budget: int = STACK_TEXT_CHARS) -> dict:
    """Material vom Geraet (iPad ohne Abgleich im Dienst): [{title, text}] -> wie week_material, begrenzt."""
    if not isinstance(raw, list):
        return {"text": "", "sources": [], "markers": False}
    items = [(str(x.get("title") or "Material")[:200], x.get("text")) for x in raw[:30] if isinstance(x, dict) and isinstance(x.get("text"), str)]
    items = [(t, s.strip()) for t, s in items if s.strip()]
    parts, sources, left = [], [], budget
    for i, (title, text) in enumerate(items):
        share = left // (len(items) - i)
        t = text[:share]
        if not t:
            continue
        parts.append(f"### {title}\n{t}")
        sources.append({"file_id": None, "name": title, "pages": []})
        left -= len(t)
    return {"text": "\n\n".join(parts), "sources": sources, "markers": False}


# ---------------------------------------------------------------- Prompt und Antwort

def stack_prompt(module: str, week: int | None, sources: list[dict], text: str, count: int, topic: str = "",
                 existing: list[str] | None = None) -> str:
    """Prompt fuer einen KI-Auftrag: genau `count` Karten aus dem Material der Woche bzw. des Moduls; vorhandene Fragen
    werden nicht wiederholt. Die Antwort hat die Form von ai.FLASHCARDS_SCHEMA; das Material ist keine Anweisung."""
    from . import ai
    scope = f"Lernwoche {week}" if week is not None else "das ganze Modul"
    src = "; ".join(f"{s['name']}" + (f" (Seiten {s['pages'][0]}–{s['pages'][-1]})" if len(s.get("pages") or []) > 1 else
                                     f" (Seite {s['pages'][0]})" if s.get("pages") else "") for s in sources[:12])
    parts = [f"Modul: {module}", f"Umfang: {scope}", f"Quellen: {src or 'keine Angabe'}", "",
             f"AUFGABE: Erstelle genau {count} Karteikarten aus dem Material. Vorn eine klare Frage, hinten eine kurze, "
             "vollstaendige Antwort (1-3 Saetze, Formeln als Text). Decke die wichtigsten Begriffe, Definitionen, Saetze, "
             "Zusammenhaenge und Rechenwege ab und verteile die Karten ueber alle Quellen; keine Karte doppelt, nichts "
             "erfinden, was nicht im Material steht."]
    if topic.strip():
        parts += ["", f"SCHWERPUNKT: {topic.strip()[:TOPIC_CHARS]}"]
    have, size = [], 0
    for q in existing or []:
        q = " ".join(q.split())[:200]
        if len(have) >= EXISTING_IN_PROMPT or size + len(q) > EXISTING_CHARS:
            break
        have.append(f"- {q}")
        size += len(q)
    if have:
        parts += ["", "SCHON VORHANDEN (diese Fragen nicht wiederholen, auch nicht umformuliert):", *have]
    parts += ["", f"MATERIAL. {ai.UNTRUSTED}:", "<<<", (text or "").strip()[:STACK_TEXT_CHARS] or "[kein Text extrahierbar]", ">>>",
              "", 'Gib ein JSON-Objekt zurueck: {"cards": [{"question": "Frage", "answer": "Antwort"}]}']
    return "\n".join(parts)


def check_cards(res, limit: int) -> list[dict]:
    """Karten aus der KI-Antwort ({"cards": [...]} oder Liste), nur mit Frage und Antwort, hoechstens `limit`."""
    items = res.get("cards") if isinstance(res, dict) else res
    if not isinstance(items, list):
        return []
    out = []
    for c in items:
        if not isinstance(c, dict):
            continue
        q, a = str(c.get("question") or "").strip()[:MAX_SIDE], str(c.get("answer") or "").strip()[:MAX_SIDE]
        if q and a:
            out.append({"question": q, "answer": a})
    return out[:limit]


def parse_answer(text: str, limit: int) -> list[dict]:
    from . import ai
    try:
        return check_cards(ai.parse_json(text or ""), limit)
    except (ai.AIError, json.JSONDecodeError):
        return []

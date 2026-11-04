"""Kommende Klausuren je Modul aus allen Quellen, die der Abgleich schon liest (Auftrag des Inhabers 04.11.2026:
"Klausur-Pins bei Stud.IP immer anzeigen"). Nur lesend gegenueber der Hochschule: es gibt keine neue Anfrage.

Quellen (Reihenfolge = Vorrang fuer Uhrzeit, Raum und Bezeichnung):
 - Stud.IP-Termine (`studip_events`): Art des Termins (`categories`, seit 04.11.2026 als `category` gespeichert),
   Titel oder kurzes Sitzungsthema nennt eine Klausur/Pruefung. Vorher wurde die Art nie gelesen; ein Klausurtermin
   erschien als gewoehnlicher Termin mit dem Kurstitel oder fehlte, wenn der eigene Kalender ihn nicht zeigte.
 - Klausurtermin am Modul, selbst eingetragen (`modules.exam_date`).
 - QIS: angemeldete Pruefungen mit Datum (`grades`, Status "AN"/"angemeldet"), Modul ueber den Namen.
 - Fristen (`deadlines`, Learnweb-Kalender und Stud.IP Courseware), deren Name eine Klausur nennt ("E-Klausur").
 - Ankuendigungen eines Kurses und Stud.IP-Nachrichten (nur lokal): Tage, deren Satzteil bzw. Satz eine Klausur nennt,
   mit den Regeln von jetzt neu gelesen (`exam_dates`; strenger als die Art "pruefung" der Chips: Anmeldung,
   Einsicht, Probeklausur, Ausfall und alte Termine einer Verlegung zaehlen nicht).
 - Auf dem iPad zusaetzlich erkannte Klausuren aus Dokumenten (DueStore, Tabelle nur auf dem Geraet).

Je Modul (sonst Kurs, sonst Name) und Tag ein Eintrag mit allen Quellen. Der Klausurtermin am Modul wird aus der
Liste gefuellt, wenn er leer ist (`fill_exam_dates`); ein selbst eingetragener Termin wird nie ueberschrieben. Welche
Termine automatisch kamen, steht in `settings.exam_dates_auto` ({Modul-ID: Tag}). Gleiche Regeln im Swift-Kern
(LocalBackend/Exams.swift), Fixture tools/gen-exams-fixture.py.
"""
from __future__ import annotations

import hashlib
import json
import re
from datetime import date, timedelta

from . import announcements, db

WINDOW_DAYS = 400
AUTO_KEY = "exam_dates_auto"
# "Klausur", "Nachklausur", "E-Klausur", "Prüfung(en)", "mündliche Prüfung", "Klausurtermin", "Prüfungsdatum", "Exam";
# nicht "Probeklausur", "Klausureinsicht", "Prüfungsanmeldung", "Prüfungszeitraum", "Klausurvorbereitung"
EXAM_RE = re.compile(r"(?<![a-zäöüß])(?:nach|wiederholungs|abschluss|modul|end|haupt|e-?)?(?:klausur|pr(?:ü|ue)fung|examen|exam)"
                     r"(?:en|s|s?termine?|s?datum)?(?![a-zäöüß])", re.I)
# Tage rund um eine Klausur, die selbst keine sind
# (Anmeldung und Fristen: "meldet euch bis zum 15.01. zur Klausur an")
NOT_EXAM_RE = re.compile(r"meld|einsicht|r(?:ü|ue)ckgabe|ergebnis|\bnoten\b|korrektur|besprechung|fragestunde|repetitorium|"
                         r"sprechstunde|probe|altklausur|zulassung|vorleistung|frist|deadline|bis\s+(?:zum|sp(?:ä|ae)testens)", re.I)
CANCEL_RE = re.compile(dict(announcements.KINDS)["ausfall"], re.I)
MOVED_RE = re.compile(r"verschoben|verlegt", re.I)
# "vom 10.02. auf den 15.02. verschoben": der alte Tag ist keine Klausur mehr
FROM_RE = re.compile(r"\bvo[mn]\s+(?:[a-zäöü]{2,10}\.?,?\s+)?$", re.I)
ROOM_RE = re.compile(r"(?<!\w)((?:H(?:ö|oe)rsaal|Seminarraum|Raum|HS)\s+[A-Za-z]{0,3}\s?-?\s?\d[\w./-]*)")
QIS_REGISTERED_RE = re.compile(r"^\s*an\s*$|angemeldet", re.I)
QIS_DATE_RE = re.compile(r"^\s*(\d{1,2})\.(\d{1,2})\.(\d{4})|^\s*(\d{4})-(\d{2})-(\d{2})")
# Vorrang der Quellen; ein automatisch uebernommener Modultermin kommt nur dazu, wenn keine andere Quelle den Tag nennt
ORDER = {"studip": 0, "modul": 1, "qis": 2, "frist": 3, "ankuendigung": 4, "nachricht": 5, "erkannt": 6, "modul_auto": 9}
DEADLINE_SOURCES = {"learnweb": "aus dem Learnweb-Kalender", "studip": "aus Stud.IP Courseware", "demo": "aus den Demo-Inhalten"}


def word(found: str) -> str:
    """Bezeichnung aus dem Treffer: Nachklausur, Klausur oder Pruefung"""
    w = found.lower()
    if w.startswith(("nach", "wiederholungs")):
        return "Nachklausur"
    return "Klausur" if "klausur" in w else "Prüfung"


def room(sentence: str) -> str | None:
    m = ROOM_RE.search(sentence or "")
    return m.group(1).strip().rstrip(".-/") if m else None


def is_exam_text(s: str | None) -> str | None:
    """Bezeichnung, wenn der Text eine Klausur nennt und nichts drumherum (Anmeldung, Einsicht ...), sonst None"""
    m = EXAM_RE.search(s or "")
    return word(m.group(0)) if m and not NOT_EXAM_RE.search(s or "") else None


def exam_dates(title: str, text: str, posted: date) -> list[dict]:
    """Klausurtage in Betreff und Text einer Ankuendigung oder Nachricht: [{date, time, word, snippet, room}].
    Ein Tag zaehlt, wenn sein Satzteil eine Klausur nennt (ohne Anmeldung, Einsicht usw.), sonst sein Satz; nennt
    nur der Betreff eine Klausur, zaehlt der Tag, wenn es der einzige im Text ist. Nie: ein Satzteil mit Ausfall
    ("Die Klausur am 12.02. entfaellt") und der alte Tag einer Verlegung ("vom 10.02. auf den 15.02. verschoben")."""
    full = f"{title or ''}\n{text or ''}"
    hits = list(announcements.scan_dates(full, posted))
    days = {h[0] for h in hits}
    title_word = is_exam_text(title)
    found: dict[tuple, dict] = {}
    for d, t, sent, clause, a, _b in hits:
        if CANCEL_RE.search(clause):
            continue
        if MOVED_RE.search(clause) and FROM_RE.search(full[max(0, a - 20):a]):
            continue
        m = EXAM_RE.search(clause)
        if m:
            if NOT_EXAM_RE.search(clause):
                continue
            w = word(m.group(0))
        elif (w := is_exam_text(sent)) is None:
            if title_word is None or len(days) != 1 or NOT_EXAM_RE.search(sent):
                continue
            w = title_word
        key = (d.isoformat(), t)
        if key not in found:
            found[key] = {"date": d.isoformat(), "time": t, "word": w, "snippet": sent, "room": room(sent)}
    out = [v for (k, t), v in found.items() if t or not any(x[0] == k and x[1] for x in found)]
    return sorted(out, key=lambda x: (x["date"], x["time"] or ""))


def in_days(n: int) -> str:
    return "heute" if n == 0 else "morgen" if n == 1 else f"in {n} Tagen" if n > 1 else f"vor {-n} Tagen"


def _dmy(iso: str) -> str:
    return f"{iso[8:10]}.{iso[5:7]}.{iso[:4]}"


def _has(conn, table: str) -> bool:
    return conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone() is not None


def auto_map(conn) -> dict[str, str]:
    """{Modul-ID: Tag} der automatisch uebernommenen Klausurtermine (ungueltige Eintraege fallen weg)"""
    r = conn.execute("SELECT value FROM settings WHERE key=?", (AUTO_KEY,)).fetchone()
    try:
        v = json.loads(r[0]) if r and r[0] else {}
    except ValueError:
        return {}
    if not isinstance(v, dict):
        return {}
    return {k: x for k, x in v.items() if isinstance(k, str) and k.isdigit() and isinstance(x, str) and len(x) == 10}


def _auto_text(m: dict[str, str]) -> str:
    return "{" + ", ".join(f'"{k}": "{m[k]}"' for k in sorted(m, key=int)) + "}"


def _cand(kind: str, label: str, day: str, **kw) -> dict:
    # name: Schluessel ohne Modul und Kurs (Betreff, Pruefungsname); title_name: Name im Titel ohne Modul und Kurs
    c = {"kind": kind, "label": label, "date": day, "time": None, "end": None, "room": None, "module_id": None,
         "course_id": None, "course_title": None, "name": None, "title_name": None, "word": "Klausur", "url": None}
    c.update(kw)
    return c


def candidates(conn, today: date) -> list[dict]:
    """Alle Klausurtage ab heute aus allen Quellen, je Quelle in fester Reihenfolge"""
    from . import studip_extras, timetable
    lo, hi = today.isoformat(), (today + timedelta(days=WINDOW_DAYS)).isoformat()
    out: list[dict] = []
    # Stud.IP-Termine: Art, Titel oder kurzes Sitzungsthema
    for r in db.rows(conn, """SELECT s.id, s.course_id, s.title, s.start, s."end", s.room, s.description, s.category,
                                     c.title AS course_title, c.module_id
                              FROM studip_events s JOIN courses c ON c.id=s.course_id
                              WHERE COALESCE(s.cancelled, 0)=0 AND substr(s.start, 1, 10) >= ? AND substr(s.start, 1, 10) <= ?
                              ORDER BY s.start, s.id""", (lo, hi)):
        desc = r["description"] or ""
        w = is_exam_text(r["category"]) or is_exam_text(r["title"]) or (is_exam_text(desc) if len(desc) <= 200 else None)
        if w is None:
            continue
        st, en = r["start"] or "", r["end"] or ""
        out.append(_cand("studip", "aus Stud.IP-Terminen", st[:10], time=st[11:16] or None,
                         end=en[11:16] if en[:10] == st[:10] and en[11:16] else None, room=(r["room"] or "").strip() or None,
                         module_id=r["module_id"], course_id=r["course_id"], course_title=r["course_title"],
                         name=r["course_title"], word=w))
    # Klausurtermin am Modul (selbst eingetragen oder automatisch uebernommen)
    auto = auto_map(conn)
    for r in db.rows(conn, "SELECT id, name, exam_date FROM modules WHERE exam_date IS NOT NULL AND exam_date <> '' ORDER BY id"):
        day = (r["exam_date"] or "")[:10]
        if not (lo <= day <= hi):
            continue
        is_auto = auto.get(str(r["id"])) == day
        out.append(_cand("modul_auto" if is_auto else "modul", "automatisch übernommen" if is_auto else "selbst eingetragen", day,
                         module_id=r["id"], name=r["name"]))
    # QIS: angemeldete Pruefungen mit Datum
    for r in db.rows(conn, "SELECT id, text, status, datum FROM grades ORDER BY id"):
        if not QIS_REGISTERED_RE.search(r["status"] or ""):
            continue
        m = QIS_DATE_RE.match(r["datum"] or "")
        if not m:
            continue
        try:
            d = date(int(m.group(3)), int(m.group(2)), int(m.group(1))) if m.group(1) else date(int(m.group(4)), int(m.group(5)), int(m.group(6)))
        except ValueError:
            continue
        if not (lo <= d.isoformat() <= hi):
            continue
        out.append(_cand("qis", "aus QIS (angemeldet)", d.isoformat(), module_id=timetable.guess_module(conn, r["text"]),
                         name=r["text"], title_name=r["text"], word="Prüfung"))
    # Fristen mit Klausur im Namen (Learnweb-Test "E-Klausur", Courseware)
    for r in db.rows(conn, """SELECT d.id, d.source, d.title, d.due_at, d.url, d.course_id, c.title AS course_title, c.module_id
                              FROM deadlines d LEFT JOIN courses c ON c.id=d.course_id
                              WHERE substr(d.due_at, 1, 10) >= ? AND substr(d.due_at, 1, 10) <= ? ORDER BY d.due_at, d.id""", (lo, hi)):
        w = is_exam_text(r["title"])
        if w is None:
            continue
        due = r["due_at"] or ""
        out.append(_cand("frist", DEADLINE_SOURCES.get(r["source"], "aus einer Frist"), due[:10], time=due[11:16] or None,
                         module_id=r["module_id"], course_id=r["course_id"], course_title=r["course_title"],
                         name=r["course_title"] or r["title"], title_name=r["title"], word=w, url=r["url"]))
    # Ankuendigungen eines Kurses (Stud.IP-weite ohne Kurs nennen kein Modul)
    for r in db.rows(conn, """SELECT a.id, a.title, a.text, a.posted_at, a.url, a.course_id, c.title AS course_title, c.module_id
                              FROM announcements a JOIN courses c ON c.id=a.course_id ORDER BY a.posted_at DESC, a.id"""):
        posted = announcements._posted_day_or_none(r["posted_at"])
        if posted is None:
            continue
        for x in exam_dates(r["title"] or "", r["text"] or "", posted):
            if lo <= x["date"] <= hi:
                out.append(_cand("ankuendigung", f"aus Ankündigung vom {_dmy(posted.isoformat())}", x["date"], time=x["time"],
                                 room=x["room"], module_id=r["module_id"], course_id=r["course_id"], course_title=r["course_title"],
                                 name=r["course_title"], word=x["word"], url=r["url"]))
    # Stud.IP-Nachrichten (nur lokal), Modul ueber den Betreff
    if studip_extras.messages_allowed() and _has(conn, "studip_messages"):
        for r in db.rows(conn, "SELECT id, subject, preview, sent_at, url FROM studip_messages ORDER BY sent_at DESC, id"):
            posted = announcements._posted_day_or_none(r["sent_at"])
            if posted is None:
                continue
            found = [x for x in exam_dates(r["subject"] or "", r["preview"] or "", posted) if lo <= x["date"] <= hi]
            if not found:
                continue
            mid = timetable.guess_module(conn, r["subject"] or "")
            for x in found:
                out.append(_cand("nachricht", f"aus Nachricht vom {_dmy(posted.isoformat())}", x["date"], time=x["time"],
                                 room=x["room"], module_id=mid, name=r["subject"], word=x["word"], url=r["url"]))
    return out


def _scope(c: dict) -> str:
    if c["module_id"] is not None:
        return f"m{c['module_id']}"
    if c["course_id"]:
        return f"c{c['course_id']}"
    return "t" + hashlib.sha256((c["name"] or "").strip().lower().encode()).hexdigest()[:10]


def merge(cands: list[dict], mods: dict, today: date) -> list[dict]:
    """Je Modul (sonst Kurs, sonst Name) und Tag ein Eintrag mit allen Quellen, nach Tag, Uhrzeit, Titel"""
    groups: dict[tuple, list[dict]] = {}
    for c in sorted(cands, key=lambda c: ORDER[c["kind"]]):
        key = (_scope(c), c["date"])
        if c["kind"] == "modul_auto" and key in groups:
            continue
        groups.setdefault(key, []).append(c)
    out = []
    for (scope, day), cs in groups.items():
        first = cs[0]
        timed = next((c for c in cs if c["time"]), None)
        # Raeume: alle der Stud.IP-Termine (je Raum ein Termin, z. B. nach Nachnamen), sonst der erste genannte
        rooms: list[str] = []
        for c in cs:
            if c["kind"] == "studip" and c["room"] and c["room"] not in rooms:
                rooms.append(c["room"])
        if not rooms:
            rooms = [c["room"] for c in cs if c["room"]][:1]
        mid = first["module_id"]
        mod = mods.get(mid) if mid is not None else None
        course = next((c for c in cs if c["course_id"]), None)
        name = (mod or {}).get("name") or (course or {}).get("course_title") or next((c["title_name"] for c in cs if c["title_name"]), None)
        sources: list[dict] = []
        for c in cs:
            kind = "modul" if c["kind"] == "modul_auto" else c["kind"]
            if not any(s["kind"] == kind and s["label"] == c["label"] for s in sources):
                sources.append({"kind": kind, "label": c["label"], "url": c["url"]})
        n = (date.fromisoformat(day) - today).days
        out.append({"id": f"exam-{scope}-{day}", "date": day, "time": timed["time"] if timed else None,
                    "end": timed["end"] if timed else None, "days_left": n, "in_days": in_days(n),
                    "title": f"{first['word']} {name}" if name else first["word"], "kind_label": first["word"],
                    "module_id": mid, "module_name": (mod or {}).get("name"), "color": (mod or {}).get("color"),
                    "course_id": course["course_id"] if course else None, "course_title": course["course_title"] if course else None,
                    "room": " · ".join(rooms) or None, "sources": sources, "source_label": " · ".join(s["label"] for s in sources),
                    "user_set": any(c["kind"] == "modul" for c in cs)})
    out.sort(key=lambda x: (x["date"], x["time"] or "", x["title"]))
    return out


def upcoming(conn, today: date) -> list[dict]:
    mods = {r["id"]: r for r in db.rows(conn, "SELECT id, name, color FROM modules")}
    return merge(candidates(conn, today), mods, today)


def fill_exam_dates(conn, items: list[dict], today: date) -> int:
    """Klausurtermin am Modul aus der Liste: leer -> frueheste Klausur aus einer Quelle (nicht dem Modul selbst).
    Automatisch uebernommen (Tag steht in exam_dates_auto) -> folgt den Quellen, wenn der Tag dort nicht mehr steht
    (verlegt, vorbei). Selbst eingetragen -> bleibt immer. Vom Nutzer geleert -> derselbe Tag kommt nicht wieder.
    Liefert die Zahl der geaenderten Module."""
    auto = auto_map(conn)
    first: dict[int, str] = {}
    listed: dict[int, set] = {}
    for it in items:
        # Quellen ausser dem Modul selbst; aus Dokumenten erkannte (nur iPad) fuellen nicht
        if it["module_id"] is None or not any(s["kind"] not in ("modul", "erkannt") for s in it["sources"]):
            continue
        first.setdefault(it["module_id"], it["date"])
        listed.setdefault(it["module_id"], set()).add(it["date"])
    changed = 0
    for r in db.rows(conn, "SELECT id, exam_date FROM modules ORDER BY id"):
        mid, cur, key = r["id"], (r["exam_date"] or "")[:10], str(r["id"])
        cand, was = first.get(mid), auto.get(key)
        if cand is None:
            continue
        if not cur:
            if cand == was:
                continue                                   # vom Nutzer geleert
        elif was is None or cur != was or cur in listed.get(mid, ()):
            continue                                       # selbst eingetragen oder noch gueltig
        conn.execute("UPDATE modules SET exam_date=? WHERE id=?", (cand, mid))
        auto[key] = cand
        changed += 1
    if changed:
        conn.execute("INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                     (AUTO_KEY, _auto_text(auto)))
    return changed


def response(conn, today: date, module_id: int | None = None) -> dict:
    """GET /api/exams/upcoming: {items, today, filled}; fuellt vorher leere Klausurtermine der Module"""
    items = upcoming(conn, today)
    filled = fill_exam_dates(conn, items, today)
    if filled:
        items = upcoming(conn, today)
    if module_id is not None:
        items = [x for x in items if x["module_id"] == module_id]
    return {"items": items, "today": today.isoformat(), "filled": filled}

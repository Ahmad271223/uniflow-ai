"""Ankuendigungen der Lehrenden (Learnweb-Ankuendigungsforen, Stud.IP-Ankuendigungen) mit erkannten Terminen.

Lehrende schreiben Ausfaelle, Raumwechsel, Online-Termine oder Abgaben oft nur als Text in eine Ankuendigung
(Befund 26.10.2026: Learnweb 27 von 89 Beitraegen mit Datum, Stud.IP 16 von 25). Diese Texte werden gespeichert und
die darin genannten Tage erkannt (`extract_dates`). Die App zeigt sie als Hinweis an den Kalendertagen und auf der
Startseite; sie aendert nie selbst Termine, denn ein Text ist keine verlaessliche Absage. Erkannte Absagen haengen
als Hinweis "Ausfall?" mit Quelle am betroffenen Termin (`mark_cancellations`); bestaetigen oder verwerfen kann sie
nur der Nutzer ueber die Ausnahmen des Tages (event_exceptions).

Quellen, alle nur lesend:
 - Learnweb mit Schluessel: REST mod_forum_get_forums_by_courses -> mod_forum_get_forum_discussions (Typ "news").
 - Learnweb ohne Schluessel: die Forumsseiten (AJAX-Dienste fuer Foren sind gesperrt, geprueft 26.10.2026).
 - Stud.IP: JSON-API /courses/{id}/news.
"""
from __future__ import annotations

import html
import json
import re
from datetime import date, datetime, timedelta
from html.parser import HTMLParser

MONTHS = {"januar": 1, "jan": 1, "februar": 2, "feb": 2, "märz": 3, "maerz": 3, "mär": 3, "april": 4, "apr": 4, "mai": 5,
          "juni": 6, "jun": 6, "juli": 7, "jul": 7, "august": 8, "aug": 8, "september": 9, "sep": 9, "sept": 9,
          "oktober": 10, "okt": 10, "november": 11, "nov": 11, "dezember": 12, "dez": 12}
# Jahr: vierstellig (auch mit Leerzeichen) oder zweistellig direkt angehaengt ("12.11.26"); "28.10. 10-12 Uhr" ist kein Jahr
NUM_DATE_RE = re.compile(r"(?<![\d.])(\d{1,2})\.\s?(\d{1,2})\.(?:\s?(20\d{2})(?!\d)|(\d{2})(?!\d))?(?![\d])")
NAME_DATE_RE = re.compile(r"(?<![\d.])(\d{1,2})\.\s?(" + "|".join(sorted(MONTHS, key=len, reverse=True)) + r")\.?(?:\s+((?:20)\d{2}))?(?![a-zäöü])", re.I)
TIME_RE = re.compile(r"^[^.!?\n]{0,25}?\b(?:um|ab|von)?\s*(\d{1,2})(?:[:.](\d{2}))?\s*(?:Uhr|h\b|-|–|bis)", re.I)
KINDS = [  # Reihenfolge = Vorrang
    # "faellt am 12.11. aus", "findet am Do., 12.11. nicht statt": Datum zwischen Verb und Partikel; "kein Tutorium",
    # "keine Vorlesungen", aber nicht "keine Uebungsblaetter"
    ("ausfall", r"f(?:ä|ae)llt\s+(?:[\w.,]+\s+){0,4}aus\b|entf(?:ä|ae)llt|ausfall|abgesagt|findet\s+(?:[\w.,]+\s+){0,4}nicht\s+statt|"
                r"\bkeine?\s+[a-zäöüß]*?(?:vorlesung(?:en)?|sitzung(?:en)?|veranstaltung(?:en)?|übung(?:en)?|uebung(?:en)?|seminar(?:e)?|tutori(?:um|en))\b"),
    ("verlegt", r"verlegt|verschoben|stattdessen|ersatztermin|nachgeholt|nachholtermin"),
    ("raum", r"\braum\b|raumwechsel|raumänderung|h(?:ö|oe)rsaal|seminarraum|\bin\s+(?:raum|geb(?:ä|ae)ude)"),
    ("frist", r"abgabe|frist|deadline|einreichen|hochladen|bis\s+(?:zum|spätestens|spaetestens)"),
    ("pruefung", r"klausur|pr(?:ü|ue)fung|hausarbeit|portfolio|referat"),
    ("online", r"online|zoom|bigbluebutton|\bbbb\b|webex|digital|videokonferenz"),
]
KIND_LABELS = {"ausfall": "Ausfall?", "verlegt": "Verlegung?", "raum": "Raum", "pruefung": "Prüfung", "frist": "Frist",
               "online": "Online", "termin": "Termin"}


class _Text(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []

    def handle_starttag(self, tag, attrs):
        if tag in ("br", "p", "div", "li", "tr", "h1", "h2", "h3", "h4"):
            self.parts.append("\n")

    def handle_data(self, data):
        self.parts.append(data)


def html_to_text(s: str | None) -> str:
    p = _Text()
    p.feed(s or "")
    t = html.unescape("".join(p.parts)).replace("\xa0", " ")
    t = re.sub(r"[ \t]+", " ", t)
    return re.sub(r"\s*\n\s*", "\n", t).strip()


WEEKDAY_ABBR = ("mo", "di", "mi", "do", "fr", "sa", "so")


def _weekday_abbr(text: str, dot: int) -> bool:
    """Steht vor dem Punkt an `dot` ein abgekuerzter Wochentag ("Do.") als eigenes Wort?"""
    return dot >= 2 and text[dot - 2:dot].lower() in WEEKDAY_ABBR and (dot == 2 or not text[dot - 3].isalnum())


def _sent_bounds(text: str, start: int, end: int) -> tuple[int, int]:
    """Satzgrenzen um [start, end): Index vor dem Satzanfang, Index des Satzendes (Punkte in Datumsangaben zaehlen nicht)."""
    a = max(text.rfind(c, 0, start) for c in ".!?\n")
    # "12.11." und "Do., 12.11." sind kein Satzende
    while a > 0 and text[a] == "." and (text[a - 1].isdigit() or _weekday_abbr(text, a)):
        a = max(text.rfind(c, 0, a) for c in ".!?\n")
    b_candidates = [i for i in (text.find(c, end) for c in "!?\n") if i != -1]
    m = re.search(r"\.(?:\s|$)(?![\d])", text[end:])
    if m:
        b_candidates.append(end + m.start())
    return a, (min(b_candidates) if b_candidates else len(text))


def _sentence(text: str, start: int, end: int) -> str:
    a, b = _sent_bounds(text, start, end)
    s = text[a + 1:b + 1].strip()
    return s if len(s) <= 180 else s[:177].rstrip() + "…"


def _clause(text: str, start: int, end: int) -> str:
    """Satzteil um ein Datum: innerhalb des Satzes vom letzten Komma/Semikolon/Doppelpunkt davor bis zum naechsten danach."""
    sa, sb = _sent_bounds(text, start, end)
    a = max([sa] + [text.rfind(c, sa + 1, start) for c in ",;:"])
    m = re.search(r"[,;]", text[end:sb])
    return text[a + 1:end + m.start() if m else sb]


def _kind(sentence: str) -> str:
    for k, rx in KINDS:
        if re.search(rx, sentence, re.I):
            return k
    return "termin"


def _year(day: int, month: int, posted: date) -> int | None:
    """Jahr ohne Angabe: das Jahr, in dem der Tag zwischen 30 Tagen vor und 300 Tagen nach der Ankuendigung liegt
    (sonst keins: "wie am 01.09. besprochen" im Oktober ist Vergangenheit, nicht der September des Folgejahres)."""
    for y in (posted.year - 1, posted.year, posted.year + 1):
        try:
            d = date(y, month, day)
        except ValueError:
            continue
        if posted - timedelta(days=30) <= d <= posted + timedelta(days=300):
            return y
    return None


def extract_dates(text: str, posted: date) -> list[dict]:
    """Tage, die in einer Ankuendigung genannt werden: [{date, time, kind, snippet}], nach Datum sortiert, ohne Doppelte.
    Erkannt: 12.11., 12.11.26, 12.11.2026, 12. November (2026). Uhrzeit direkt danach (14 Uhr, 14:15, 14.15 Uhr).
    Art aus dem Satz (Ausfall, Verlegung, Raum, Pruefung, Frist, Online, sonst Termin). Tage mehr als 30 Tage vor
    der Ankuendigung (z. B. Bezug auf Vergangenes) werden ignoriert."""
    found: dict[tuple, dict] = {}
    for rx, named in ((NUM_DATE_RE, False), (NAME_DATE_RE, True)):
        for m in rx.finditer(text or ""):
            day = int(m.group(1))
            month = MONTHS[m.group(2).lower()] if named else int(m.group(2))
            y = m.group(3) or (m.group(4) if not named else None)
            year = (2000 + int(y) if len(y) == 2 else int(y)) if y else _year(day, month, posted)
            if not year or not (1 <= month <= 12):
                continue
            try:
                d = date(year, month, day)
            except ValueError:
                continue
            if d < posted - timedelta(days=30) or d > posted + timedelta(days=400):
                continue
            tm = TIME_RE.match(text[m.end():m.end() + 40])
            t = None
            if tm and 6 <= int(tm.group(1)) <= 23 and int(tm.group(2) or 0) < 60:
                t = f"{int(tm.group(1)):02d}:{tm.group(2) or '00'}"
            sent = _sentence(text, m.start(), m.end())
            # Art zuerst aus dem Satzteil um das Datum ("Keine Vorlesung am 24.12., stattdessen am 7.1." -> Ausfall, Verlegung)
            kind = _kind(_clause(text, m.start(), m.end()))
            if kind == "termin":
                kind = _kind(sent)
            key = (d.isoformat(), t)
            if key not in found:
                found[key] = {"date": d.isoformat(), "time": t, "kind": kind, "snippet": sent}
    # gleicher Tag mit und ohne Uhrzeit: nur der Eintrag mit Uhrzeit
    out = [v for (d, t), v in found.items() if t or not any(k[0] == d and k[1] for k in found)]
    return sorted(out, key=lambda x: (x["date"], x["time"] or ""))


# ----------------------------------------------------------------------------
# Learnweb-Forumsseiten (Weg ohne Schluessel)
# ----------------------------------------------------------------------------

class _ForumPosts(HTMLParser):
    """Beitraege einer Diskussionsseite (discuss.php): id, Betreff, Autor, Zeit, Text."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.posts: list[dict] = []
        self._cur: dict | None = None
        self._capture: str | None = None
        self._depth = 0
        self._buf: list[str] = []
        self._author_next = False

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "article" and a.get("data-post-id"):
            self._cur = {"id": int(a["data-post-id"]), "subject": "", "author": "", "posted_at": "", "html": ""}
            self.posts.append(self._cur)
            return
        if self._cur is None:
            return
        if self._capture:
            self._depth += 1
            if self._capture == "content":
                self._buf.append(self.get_starttag_text() or "")
            return
        if a.get("data-region-content") == "forum-post-core-subject":
            self._capture, self._depth, self._buf = "subject", 1, []
        elif tag == "div" and (a.get("id") or "").startswith("post-content-"):
            self._capture, self._depth, self._buf = "content", 1, []
        elif tag == "time" and a.get("datetime") and not self._cur["posted_at"]:
            self._cur["posted_at"] = a["datetime"]
        elif tag == "a" and "/user/view.php" in (a.get("href") or "") and not self._cur["author"]:
            self._capture, self._depth, self._buf = "author", 1, []

    def handle_endtag(self, tag):
        if not self._capture:
            return
        self._depth -= 1
        if self._depth > 0:
            if self._capture == "content":
                self._buf.append(f"</{tag}>")
            return
        val = "".join(self._buf)
        if self._capture == "content":
            self._cur["html"] = val
        else:
            self._cur[self._capture] = re.sub(r"\s+", " ", val).strip()
        self._capture = None

    def handle_data(self, data):
        if self._capture:
            self._buf.append(html.escape(data) if self._capture == "content" else data)


def parse_discussion_html(page_html: str) -> list[dict]:
    p = _ForumPosts()
    p.feed(page_html or "")
    return [x for x in p.posts if x["id"]]


def discussion_links(view_html: str) -> list[int]:
    """Diskussions-IDs der Forumsuebersicht (view.php), in Reihenfolge der Seite (neueste zuerst)."""
    seen: list[int] = []
    for m in re.finditer(r'data-discussionid="(\d+)"|/mod/forum/discuss\.php\?d=(\d+)', view_html or ""):
        d = int(m.group(1) or m.group(2))
        if d not in seen:
            seen.append(d)
    return seen


def is_news_forum(body_class: str) -> bool:
    return "forumtype-news" in (body_class or "").split()


# ----------------------------------------------------------------------------
# Einheitliche Form und Speicher
# ----------------------------------------------------------------------------

def _posted_day_or_none(posted_at: str | None) -> date | None:
    """Tag aus den ersten zehn Zeichen ("2026-11-02", danach "T" oder Leerzeichen), sonst None (wie Swift postedDay)."""
    s = posted_at or ""
    if len(s) < 10 or (len(s) > 10 and s[10] not in "T "):
        return None
    try:
        return date.fromisoformat(s[:10])
    except ValueError:
        return None


def _posted_date(posted_at: str) -> date:
    try:
        return datetime.fromisoformat(posted_at.replace("Z", "+00:00")).date()
    except (ValueError, AttributeError):
        return date.today()


def dates_for(title: str, text: str, posted: date) -> list[dict]:
    """Tage einer Ankuendigung aus Betreff und Text (reiner Text). Betreff "Vorlesung entfaellt", der Text nennt nur den
    Tag ("am 12.11. bin ich auf einer Tagung"): bei genau einem Tag gilt die Art des Betreffs (Ausfall, Verlegung);
    mehrere Tage bleiben offen, welcher gemeint ist."""
    dates = extract_dates(f"{title}\n{text}", posted)
    if len(dates) == 1 and dates[0]["kind"] == "termin" and _kind(title) in ("ausfall", "verlegt"):
        dates[0]["kind"] = _kind(title)
    return dates


def make(aid: str, source: str, course_id: str | None, title: str, body_html: str, author: str, posted_at: str,
         url: str | None, discussion: str | None = None) -> dict:
    text = html_to_text(body_html)
    dates = dates_for(html_to_text(title), text, _posted_date(posted_at))
    return {"id": aid, "source": source, "course_id": course_id, "title": html_to_text(title)[:200] or "Ankündigung",
            "text": text[:6000], "author": (author or "")[:120], "posted_at": posted_at, "url": url,
            "discussion": discussion, "dates": dates}


def from_moodle_discussion(d: dict, course_id: str, base: str) -> dict:
    """REST mod_forum_get_forum_discussions -> Ankuendigung (erster Beitrag der Diskussion)."""
    from .learnweb import local_iso
    posted = local_iso(d.get("created") or d.get("timemodified") or 0) + ":00"
    return make(f"lw-post-{int(d['id'])}", "learnweb", course_id, d.get("subject") or d.get("name") or "", d.get("message") or "",
                d.get("userfullname") or "", posted, f"{base.rstrip('/')}/mod/forum/discuss.php?d={int(d['discussion'])}",
                discussion=f"lw-d-{int(d['discussion'])}")


def from_forum_post(p: dict, course_id: str, base: str, discussion_id: int) -> dict:
    return make(f"lw-post-{p['id']}", "learnweb", course_id, p["subject"], p["html"], p["author"], p["posted_at"],
                f"{base.rstrip('/')}/mod/forum/discuss.php?d={discussion_id}#p{p['id']}", discussion=f"lw-d-{discussion_id}")


def from_studip_news(n: dict, course_id: str, studip_base: str) -> dict:
    a = n.get("attributes") or {}
    return make(f"sp-news-{n['id']}", "studip", course_id, a.get("title") or "", a.get("content") or "", "",
                a.get("publication-start") or a.get("mkdate") or "", f"{studip_base}/dispatch.php/course/overview?cid={course_id}")


def store(conn, items: list[dict], source: str, fetched_at: str, course_ids: list[str] | None = None) -> dict:
    """Ankuendigungen speichern (Upsert). Nur fuer vollstaendig gelesene Kurse (course_ids) werden geloeschte
    entfernt; Learnweb-Beitraege bekannter Diskussionen (nicht erneut gelesen) bleiben stehen."""
    from . import db
    known = {r["id"] for r in db.rows(conn, "SELECT id FROM announcements WHERE source=?", (source,))}
    for a in items:
        conn.execute("""INSERT INTO announcements(id, source, course_id, title, text, author, posted_at, url, discussion, dates, fetched_at)
                        VALUES (?,?,?,?,?,?,?,?,?,?,?)
                        ON CONFLICT(id) DO UPDATE SET course_id=excluded.course_id, title=excluded.title, text=excluded.text,
                          author=excluded.author, posted_at=excluded.posted_at, url=excluded.url, discussion=excluded.discussion,
                          dates=excluded.dates, fetched_at=excluded.fetched_at""",
                     (a["id"], source, a.get("course_id"), a["title"], a["text"], a.get("author") or "", a["posted_at"], a.get("url"),
                      a.get("discussion"), json.dumps(a["dates"], ensure_ascii=False), fetched_at))
    removed = 0
    if course_ids is not None:
        ids = [a["id"] for a in items]
        for cid in course_ids:
            removed += conn.execute(f"""DELETE FROM announcements WHERE source=? AND course_id=?
                                        AND id NOT IN ({",".join("?" * len(ids)) or "''"})""", (source, cid, *ids)).rowcount
    return {"new": len({a["id"] for a in items} - known), "total": len(items), "removed": removed}


def known_discussions(conn) -> set[str]:
    from . import db
    return {r["discussion"] for r in db.rows(conn, "SELECT DISTINCT discussion FROM announcements WHERE discussion IS NOT NULL")}


def _row(r: dict) -> dict:
    return {"id": r["id"], "source": r["source"], "course_id": r["course_id"], "course_title": r.get("course_title"),
            "color": r.get("color"), "title": r["title"], "text": r["text"], "author": r["author"], "posted_at": r["posted_at"],
            "url": r["url"], "dates": json.loads(r["dates"] or "[]")}


def recent(conn, days: int = 30, limit: int = 20, today: date | None = None) -> list[dict]:
    """Ankuendigungen der letzten Tage und solche mit kommenden Terminen, neueste zuerst."""
    from . import db
    t = today or date.today()
    since = (t - timedelta(days=days)).isoformat()
    rows = db.rows(conn, """SELECT a.*, c.title AS course_title, m.color FROM announcements a LEFT JOIN courses c ON c.id=a.course_id
                            LEFT JOIN modules m ON m.id=c.module_id ORDER BY a.posted_at DESC""")
    out = []
    for r in rows:
        x = _row(r)
        upcoming = [d for d in x["dates"] if d["date"] >= t.isoformat()]
        if x["posted_at"][:10] >= since or upcoming:
            x["upcoming"] = upcoming
            out.append(x)
    return out[:limit]


def by_day(conn, start: date, end: date) -> dict[str, list[dict]]:
    """Erkannte Termine aus Ankuendigungen je Kalendertag (fuer Lernkalender und Stundenplan)."""
    from . import db
    lo, hi = start.isoformat(), end.isoformat()
    out: dict[str, list[dict]] = {}
    # course_id/module_id: Termin zum Hinweis finden ("Zum Termin"); posted_at: Datum der Quelle im Detail (03.11.2026)
    for r in db.rows(conn, """SELECT a.*, c.title AS course_title, c.module_id, m.color FROM announcements a LEFT JOIN courses c ON c.id=a.course_id
                              LEFT JOIN modules m ON m.id=c.module_id WHERE a.dates <> '[]'"""):
        x = _row(r)
        for d in x["dates"]:
            if lo <= d["date"] <= hi:
                out.setdefault(d["date"], []).append({
                    "announcement_id": x["id"], "title": x["title"], "kind": d["kind"], "kind_label": KIND_LABELS.get(d["kind"], "Termin"),
                    "time": d["time"], "snippet": d["snippet"], "url": x["url"], "course_title": x["course_title"], "color": x["color"],
                    "source": x["source"], "course_id": x["course_id"], "module_id": r["module_id"], "posted_at": x["posted_at"]})
    for v in out.values():
        v.sort(key=lambda n: (n["time"] or "", n["title"]))
    return out


# ----------------------------------------------------------------------------
# Absagen am Termin im Stundenplan
# ----------------------------------------------------------------------------

# Art der Veranstaltung in einer Absage -> Arten der Termine im Stundenplan (course_events.kind, timetable.UNI_KINDS)
CANCEL_TARGETS = [
    (r"vorlesung|\bvl\b", ("vorlesung",)),
    (r"(?:ü|ue)bung|tutori(?:um|en)", ("uebung", "hoersaaluebung", "gruppenuebung", "tutorium")),
    (r"seminar", ("seminar",)),
    (r"labor|praktikum", ("labor",)),
]
CANCEL_LABEL = "Ausfall?"            # aus Text erkannt, nicht bestaetigt
CANCEL_CONFIRMED_LABEL = "fällt aus"  # der Termin ist als Ausfall eingetragen (Nutzer, Stud.IP, LSF)


def cancel_targets(snippet: str | None, title: str | None) -> set[str]:
    """Welche Arten eine Absage meint: zuerst die Satzteile mit der Absage ("Die Vorlesung am 12.11. faellt aus, die
    Uebung findet statt" -> Vorlesung), dann der ganze Satz, dann der Betreff. Leer: die Nachricht nennt keine Art."""
    ausfall = dict(KINDS)["ausfall"]
    parts = [p for p in re.split(r"[,;]", snippet or "") if re.search(ausfall, p, re.I)]
    for text in (" ".join(parts), snippet or "", title or ""):
        found = {k for rx, kinds in CANCEL_TARGETS if re.search(rx, text, re.I) for k in kinds}
        if found:
            return found
    return set()


def _minutes(t) -> int | None:
    m = re.match(r"^(\d{1,2}):(\d{2})", str(t or ""))
    return int(m.group(1)) * 60 + int(m.group(2)) if m else None


def mark_cancellations(conn, occ: list[dict]) -> list[dict]:
    """Absagen aus Ankuendigungen an die betroffenen Termine haengen (Wunsch des Inhabers 02.11.2026: steht irgendwo,
    dass eine Veranstaltung ausfaellt, ist der Termin im Planer markiert). Zuordnung: Tag der Absage; derselbe Kurs
    wie die Ankuendigung oder dasselbe Modul (Learnweb-Kurs und LSF-/Stud.IP-Serie haengen am Modul); mit Uhrzeit nur
    der Termin, der dann laeuft (oder bis 15 Minuten spaeter beginnt: "10 Uhr" fuer 10:15, c. t.); nennt die Nachricht die Art (Vorlesung, Uebung,
    Tutorium, Seminar, Labor), nur Termine dieser Art, sonst bei Terminen des Kurses selbst nur diese.

    Ein Text ist keine verlaessliche Absage: der Termin bekommt nur `cancel_hint` (Quelle, Satz, "Ausfall?"), Status
    und belegte Zeit bleiben. Der Nutzer entscheidet ueber die vorhandenen Ausnahmen: "faellt aus" (cancelled, dann
    `confirmed` und Label "faellt aus", die Zeit wird frei wie bei jedem Ausfall) oder "findet statt" (attend, dann
    kein Hinweis mehr). Andere Ausnahmen (nicht besucht, verschoben, bearbeitet, vorlesungsfrei) zeigen keinen
    Hinweis. Die neueste Ankuendigung gewinnt. Termine ohne Hinweis bleiben unveraendert (Antwortform wie bisher)."""
    if not occ:
        return occ
    from . import db
    lo, hi = min(o["date"] for o in occ), max(o["date"] for o in occ)
    # Tage mit den Regeln von jetzt neu lesen (die gespeicherten stammen vom Abgleich, evtl. mit aelteren Regeln)
    rows = db.rows(conn, """SELECT a.id, a.source, a.course_id, a.title, a.text, a.url, a.posted_at, c.title AS course_title, c.module_id
                            FROM announcements a LEFT JOIN courses c ON c.id=a.course_id
                            WHERE a.course_id IS NOT NULL ORDER BY a.posted_at DESC, a.id""")
    for r in rows:
        posted = _posted_day_or_none(r["posted_at"])
        if posted is None:
            continue
        dates = dates_for(r["title"] or "", r["text"] or "", posted)
        for d in dates if isinstance(dates, list) else []:
            if not isinstance(d, dict) or d.get("kind") != "ausfall" or not isinstance(d.get("date"), str) or not (lo <= d["date"] <= hi):
                continue
            cand = [o for o in occ if o["date"] == d["date"] and o.get("exception") in (None, "cancelled") and "cancel_hint" not in o
                    and (o.get("course_id") == r["course_id"] or (r["module_id"] is not None and o.get("module_id") == r["module_id"]))]
            t = _minutes(d.get("time"))
            if t is not None:
                cand = [o for o in cand if (s := _minutes(o.get("start"))) is not None and s - 15 <= t < max(s + 1, _minutes(o.get("end")) or 0)]
            types = cancel_targets(d.get("snippet"), r["title"])
            if types:
                cand = [o for o in cand if (o.get("kind") or "vorlesung") in types]
            elif any(o.get("course_id") == r["course_id"] for o in cand):
                cand = [o for o in cand if o.get("course_id") == r["course_id"]]
            for o in cand:
                confirmed = o.get("exception") == "cancelled"
                o["cancel_hint"] = {"announcement_id": r["id"], "title": r["title"], "snippet": d.get("snippet"), "url": r["url"],
                                    "source": r["source"], "course_title": r["course_title"], "posted_at": r["posted_at"],
                                    "confirmed": confirmed, "label": CANCEL_CONFIRMED_LABEL if confirmed else CANCEL_LABEL}
    return occ

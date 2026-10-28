"""Gemeinsamer Wochentest je Kursgruppe (Dienst, 28.10.2026).

Ein Test je Kursgruppe und Kalenderwoche fuer alle berechtigten Studierenden; jeder hat seinen eigenen Versuch, seine
Punkte und (freiwillig) seinen Platz in der Rangliste.

**Kursgruppe** = Hochschule + Kurs-Schluessel (wie CommunityKeys.courseKey aus der Stud.IP-/Learnweb-ID der Vorlesung,
der Dienst kennt nie Kurs-ID oder -Namen) + Semester + Kalenderwoche (ISO, z. B. 2026-W44). Die Kalenderwoche ist fuer
alle gleich; die Lehrwochen-Zaehlung der Geraete kann sich unterscheiden und gehoert deshalb nicht in den Schluessel.

**KI-Einsatz (nur im Dienst, Studora-KI ueber app/ai_backend.py, Budget des Dienstes):**
- *Phase A/B/C auf dem Geraet, ohne KI:* das Geraet stellt das Material der Woche zusammen (Texte, nie PDF-Dateien):
  Vorlesung, Uebung, Gruppen- und Hoersaaluebung, Loesungen der Woche vollstaendig; aus Skript und Altklausuren nur
  passende Seiten (Volltextsuche). Fehlende Arten fehlen einfach.
- *Phase D (eine KI-Anfrage):* Test mit 15 Aufgaben (5 kurz, 6 mittel, 4 schwer), Musterloesung, Bewertungsschema,
  Quellen je Aufgabe, Kennzeichnung von Altklausur-Aufgaben.
- *Phase E (eine KI-Anfrage):* Pruefung jeder Aufgabe (loesbar, Loesung richtig, vom Stoff gedeckt, keine Dublette);
  dazu feste Pruefungen im Code (Anzahl, Typen, Punkte, Optionen, Zahlenwerte). Weniger als 12 gute Aufgaben: nicht
  veroeffentlicht.
- *Bewertung:* Auswahl- und Zahlenaufgaben bewertet der Code (keine KI). Nur offene Antworten gehen in einer
  KI-Anfrage je Abgabe an die KI (Schema, Musterloesung, Punkte); unsichere Bewertungen kommen nicht in die Rangliste.
Kosten entstehen damit je Kursgruppe und Woche (2 Anfragen), nicht je Studierendem; dazu je Abgabe hoechstens eine
Anfrage fuer offene Antworten.

**Fairness und Schutz:** Musterloesungen und Schema bekommt das Geraet erst nach der eigenen Abgabe. Punkte rechnet
nur der Dienst. Nur der erste abgegebene Versuch zaehlt; weitere sind Uebung. Rangliste freiwillig, mit Pseudonym oder
gewaehltem Namen, vollstaendig sichtbar erst nach der Frist (7 Tage nach Veroeffentlichung); gleiche Punkte = gleicher
Platz, die Bearbeitungszeit ist nur Information.

**Altklausuren:** `LERNAPP_WEEKLY_PAST_EXAMS` = `inspire` (Standard: Aufgaben nur angelehnt, nie woertlich, Quelle
genannt) oder `reuse` (Original-Aufgaben duerfen uebernommen werden; erst einschalten, wenn die Weitergabe erlaubt ist).
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import threading
import uuid
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone

from . import community, db
from .community import CommunityError, _now, pseudonym

SCHEMA = """
CREATE TABLE IF NOT EXISTS weekly_tests (
    id TEXT PRIMARY KEY, group_key TEXT NOT NULL UNIQUE, course_key TEXT NOT NULL, university TEXT NOT NULL, term TEXT NOT NULL,
    week TEXT NOT NULL, version INTEGER NOT NULL DEFAULT 1, status TEXT NOT NULL, title TEXT, topics TEXT, questions TEXT,
    solutions TEXT, materials TEXT, created_by TEXT, created_at TEXT NOT NULL, published_at TEXT, closes_at TEXT, error TEXT,
    review TEXT);
CREATE INDEX IF NOT EXISTS idx_weekly_course ON weekly_tests(course_key, university, week);
CREATE TABLE IF NOT EXISTS weekly_attempts (
    id TEXT PRIMARY KEY, test_id TEXT NOT NULL REFERENCES weekly_tests(id), user_id TEXT NOT NULL, official INTEGER NOT NULL DEFAULT 1,
    started_at TEXT NOT NULL, updated_at TEXT, answers TEXT, submitted_at TEXT, status TEXT NOT NULL, score REAL, max_score REAL,
    result TEXT, needs_review INTEGER DEFAULT 0, leaderboard INTEGER DEFAULT 0, display_name TEXT, seconds INTEGER);
CREATE UNIQUE INDEX IF NOT EXISTS idx_weekly_official ON weekly_attempts(test_id, user_id) WHERE official=1;
CREATE INDEX IF NOT EXISTS idx_weekly_attempts_test ON weekly_attempts(test_id, status);
"""
HEX64 = re.compile(r"^[0-9a-f]{64}$")
WEEK_RE = re.compile(r"^\d{4}-W(0[1-9]|[1-4]\d|5[0-3])$")
LEVELS = {"short": (5, "kurz: Grundwissen, Definition, kleine Rechnung"), "medium": (6, "mittel: mehrstufige Anwendung, typische Uebungsaufgabe"),
          "hard": (4, "schwer: Transfer, klausurnah")}
TYPES = ("mc", "multi", "number", "short", "text", "calc")
AUTO_TYPES = ("mc", "multi", "number")
KINDS = ("vorlesung", "uebung", "gruppenuebung", "hoersaaluebung", "tutorium", "loesung", "skript", "altklausur")
MIN_QUESTIONS, TARGET_QUESTIONS = 12, 15
OPEN_DAYS = 7
MAX_MATERIAL_CHARS = 140_000
NAME_RE = re.compile(r"^[\w .\-äöüÄÖÜß]{2,24}$")


class _Busy(Exception):
    pass


@contextmanager
def cursor():
    with community.cursor() as conn:
        db.schema_once(conn, "weekly", community.db_path(), lambda c: c.executescript(SCHEMA))
        yield conn


def group_key(university: str, course_key: str, term: str, week: str) -> str:
    return hashlib.sha256(("studora.weekly.v1\0" + university + "\0" + course_key + "\0" + term + "\0" + week).encode()).hexdigest()


def norm_term(term: str | None) -> str:
    from .grades_model import norm_semester
    return norm_semester(str(term or "").strip())[:40] or "ohne-semester"


def past_exam_mode() -> str:
    return "reuse" if (os.environ.get("LERNAPP_WEEKLY_PAST_EXAMS") or "").strip().lower() == "reuse" else "inspire"


def _check_key_week(course_key: str, week: str) -> tuple[str, str]:
    k = (course_key or "").lower()
    if not HEX64.match(k):
        raise CommunityError("course_invalid", "Ungültiger Kurs-Schlüssel.")
    if not WEEK_RE.match(week or ""):
        raise CommunityError("week_invalid", "Woche im Format JJJJ-Www (z. B. 2026-W44).")
    return k, week


def _may_take(user: dict) -> None:
    from . import entitlements
    if not entitlements.has(user, "can_access_shared_tests"):
        raise CommunityError("plan_required", "Gemeinsame Wochentests gibt es ab Studora Plus.", 403)


# ---------------------------------------------------------------- oeffentliche Sicht eines Tests (ohne Loesungen)

def _public(t, attempt=None, with_solutions: bool = False) -> dict:
    qs = json.loads(t["questions"] or "[]")
    out = {"id": t["id"], "course_key": t["course_key"], "term": t["term"], "week": t["week"], "version": t["version"],
           "status": t["status"], "title": t["title"], "topics": json.loads(t["topics"] or "[]"), "published_at": t["published_at"],
           "closes_at": t["closes_at"], "questions": qs, "max_points": round(sum(q.get("points", 0) for q in qs), 1),
           "levels": {lv: sum(1 for q in qs if q.get("level") == lv) for lv in LEVELS}, "error": t["error"] if t["status"] == "failed" else None,
           "past_exam_mode": past_exam_mode(),
           # Quellen der Aufgaben (Q1, Q2, ...): Art, Titel, Seiten - keine Texte
           "materials": [{"q": f"Q{i}", "kind": m.get("kind"), "title": m.get("title"), "pages": m.get("pages"), "sha256": m.get("sha256")}
                         for i, m in enumerate(json.loads(t["materials"] or "[]"), 1)]}
    if attempt is not None:
        out["attempt"] = _attempt_out(attempt)
    if with_solutions:
        out["solutions"] = json.loads(t["solutions"] or "{}")
    return out


def _attempt_out(a) -> dict:
    return {"id": a["id"], "official": bool(a["official"]), "status": a["status"], "started_at": a["started_at"],
            "submitted_at": a["submitted_at"], "answers": json.loads(a["answers"] or "{}"), "score": a["score"], "max_score": a["max_score"],
            "result": json.loads(a["result"] or "null"), "needs_review": bool(a["needs_review"]), "leaderboard": bool(a["leaderboard"]),
            "display_name": a["display_name"], "seconds": a["seconds"]}


def get_for_week(user: dict, university: str, course_key: str, term: str, week: str) -> dict:
    k, w = _check_key_week(course_key, week)
    term = norm_term(term)
    with cursor() as conn:
        t = conn.execute("SELECT * FROM weekly_tests WHERE group_key=?", (group_key(university, k, term, w),)).fetchone()
        if not t:
            raise CommunityError("not_generated", "Für diese Woche gibt es noch keinen gemeinsamen Test.", 404)
        a = conn.execute("SELECT * FROM weekly_attempts WHERE test_id=? AND user_id=? AND official=1", (t["id"], user["id"])).fetchone()
        done = bool(a and a["submitted_at"])
        return _public(t, a, with_solutions=done)


def list_for_course(user: dict, university: str, course_key: str, term: str) -> dict:
    k, _ = _check_key_week(course_key, "2026-W01")
    with cursor() as conn:
        rows = conn.execute("SELECT * FROM weekly_tests WHERE course_key=? AND university=? AND term=? ORDER BY week DESC",
                            (k, university, norm_term(term))).fetchall()
        out = []
        for t in rows:
            a = conn.execute("SELECT * FROM weekly_attempts WHERE test_id=? AND user_id=? AND official=1", (t["id"], user["id"])).fetchone()
            n = conn.execute("SELECT COUNT(*) FROM weekly_attempts WHERE test_id=? AND official=1 AND submitted_at IS NOT NULL", (t["id"],)).fetchone()[0]
            out.append({"id": t["id"], "week": t["week"], "status": t["status"], "title": t["title"], "published_at": t["published_at"],
                        "closes_at": t["closes_at"], "participants": n,
                        "my_status": a["status"] if a else None, "my_score": a["score"] if a else None, "max_score": a["max_score"] if a else None})
    return {"tests": out}


# ---------------------------------------------------------------- Erstellen (einmal je Kursgruppe und Woche)

def _clean_materials(materials) -> list[dict]:
    if not isinstance(materials, list) or not materials:
        raise CommunityError("materials_missing", "Für diese Woche gibt es noch kein Material (Vorlesung oder Übung).")
    out, total = [], 0
    for m in materials[:40]:
        if not isinstance(m, dict):
            continue
        kind = str(m.get("kind") or "").lower()
        if kind not in KINDS:
            continue
        pages = []
        for p in (m.get("pages") or [])[:60]:
            if isinstance(p, dict) and str(p.get("text") or "").strip():
                txt = str(p["text"])[:6000]
                total += len(txt)
                if total > MAX_MATERIAL_CHARS:
                    break
                pages.append({"page": int(p.get("page") or 0) if str(p.get("page") or "0").isdigit() else 0, "text": txt})
        if pages:
            sha = str(m.get("sha256") or "").lower()
            out.append({"kind": kind, "title": str(m.get("title") or "")[:160], "sha256": sha if HEX64.match(sha) else None, "pages": pages})
        if total > MAX_MATERIAL_CHARS:
            break
    if not any(m["kind"] in ("vorlesung", "uebung", "gruppenuebung", "hoersaaluebung", "tutorium", "skript") for m in out):
        raise CommunityError("materials_missing", "Für diese Woche gibt es noch kein Material (Vorlesung oder Übung).")
    return out


def request(user: dict, university: str, course_key: str, term: str, week: str, materials, run_async: bool = True) -> dict:
    """Test der Kursgruppe holen oder (einmal) erstellen lassen. Gibt es ihn schon oder laeuft die Erstellung, wird
    nichts neu erzeugt: der Eintrag mit `group_key` ist eindeutig (gleichzeitige Anfragen erzeugen nie zwei Tests)."""
    _may_take(user)
    k, w = _check_key_week(course_key, week)
    term = norm_term(term)
    gk = group_key(university, k, term, w)
    with cursor() as conn:
        t = conn.execute("SELECT * FROM weekly_tests WHERE group_key=?", (gk,)).fetchone()
        if t and t["status"] in ("generating", "published", "review"):
            return _public(t)
    community._require_verified(user, "einen Wochentest erstellen zu lassen")
    mats = _clean_materials(materials)
    community._limit("weekly_generate_user", user["id"])
    with cursor() as conn:
        t = conn.execute("SELECT * FROM weekly_tests WHERE group_key=?", (gk,)).fetchone()
        if t and t["status"] != "failed":
            return _public(t)
        tid = t["id"] if t else uuid.uuid4().hex
        meta = json.dumps([{k2: m[k2] for k2 in ("kind", "title", "sha256")} | {"pages": [p["page"] for p in m["pages"]]} for m in mats], ensure_ascii=False)
        if t:
            cur = conn.execute("UPDATE weekly_tests SET status='generating', error=NULL, materials=?, created_by=? WHERE id=? AND status='failed'",
                               (meta, user["id"], tid))
            if not cur.rowcount:
                return _public(conn.execute("SELECT * FROM weekly_tests WHERE id=?", (tid,)).fetchone())
        else:
            try:
                conn.execute("""INSERT INTO weekly_tests(id, group_key, course_key, university, term, week, status, materials, created_by, created_at)
                                VALUES (?,?,?,?,?,?, 'generating', ?,?,?)""", (tid, gk, k, university, term, w, meta, user["id"], _now()))
            except Exception:                              # noqa: BLE001 - gleichzeitig angelegt: den vorhandenen nehmen
                return _public(conn.execute("SELECT * FROM weekly_tests WHERE group_key=?", (gk,)).fetchone())
        row = conn.execute("SELECT * FROM weekly_tests WHERE id=?", (tid,)).fetchone()
    if run_async:
        threading.Thread(target=_generate_safe, args=(tid, mats), name=f"weekly-{tid[:8]}", daemon=True).start()
    else:
        _generate_safe(tid, mats)
        with cursor() as conn:
            row = conn.execute("SELECT * FROM weekly_tests WHERE id=?", (tid,)).fetchone()
    return _public(row)


def _generate_safe(tid: str, mats: list[dict]) -> None:
    try:
        title, topics, questions, solutions, review = generate(mats)
        status = "published" if len(questions) >= MIN_QUESTIONS else "failed"
        now = datetime.now(timezone.utc).replace(microsecond=0)
        with cursor() as conn:
            if status == "published":
                conn.execute("""UPDATE weekly_tests SET status='published', title=?, topics=?, questions=?, solutions=?, review=?, published_at=?,
                                closes_at=?, error=NULL WHERE id=?""",
                             (title, json.dumps(topics, ensure_ascii=False), json.dumps(questions, ensure_ascii=False),
                              json.dumps(solutions, ensure_ascii=False), json.dumps(review, ensure_ascii=False), _iso(now),
                              _iso(now + timedelta(days=OPEN_DAYS)), tid))
            else:
                conn.execute("UPDATE weekly_tests SET status='failed', error=?, review=? WHERE id=?",
                             (f"Nur {len(questions)} geprüfte Aufgaben – der Test wird nicht veröffentlicht. Später erneut versuchen.",
                              json.dumps(review, ensure_ascii=False), tid))
    except Exception as e:                                 # noqa: BLE001 - nie haengen bleiben: Status failed, erneut anforderbar
        msg = getattr(e, "message", None) or str(e)
        with cursor() as conn:
            conn.execute("UPDATE weekly_tests SET status='failed', error=? WHERE id=?", (f"Erstellen fehlgeschlagen: {msg[:300]}", tid))


def _iso(d: datetime) -> str:
    return d.isoformat().replace("+00:00", "Z")


def _materials_block(mats: list[dict]) -> str:
    names = {"vorlesung": "Vorlesung", "uebung": "Übungsblatt", "gruppenuebung": "Gruppenübung", "hoersaaluebung": "Hörsaalübung",
             "tutorium": "Tutorium", "loesung": "Lösung", "skript": "Skript (passende Seiten)", "altklausur": "Altklausur (passende Seiten)"}
    parts = []
    for i, m in enumerate(mats, 1):
        head = f"### Q{i} {names[m['kind']]}: {m['title']}"
        parts.append(head + "\n" + "\n".join(f"[Seite {p['page']}] {p['text']}" for p in m["pages"]))
    return "\n\n".join(parts)


SYSTEM = ("Du erstellst Wochentests fuer Studierende einer deutschen Hochschule. Du arbeitest nur mit dem gegebenen Material, "
          "erfindest keinen Stoff, keine Quellen und keine Altklausur-Aufgaben. Antworte ausschliesslich mit gueltigem JSON.")


def _gen_prompt(mats: list[dict]) -> str:
    past = ("Passen 1-2 Aufgaben aus den Altklausuren (Q-Nummer mit 'Altklausur') wirklich zum Stoff dieser Woche (alle noetigen "
            "Verfahren wurden behandelt), uebernimm sie und setze \"past_exam\": true mit Quelle. Sonst keine." if past_exam_mode() == "reuse" else
            "Altklausuren nur als Vorbild: angelehnte, neu formulierte Aufgaben mit \"past_exam_like\": true und Quelle, nie woertlich. "
            "Passt keine Altklausur-Aufgabe zum Stoff dieser Woche, keine.")
    return f"""Bestimme zuerst die Themen, die dieses Material in dieser Woche wirklich behandelt (Vorlesung, Uebungen). Erstelle dann
einen Wochentest mit genau {TARGET_QUESTIONS} Aufgaben: 5 "short" ({LEVELS['short'][1]}), 6 "medium" ({LEVELS['medium'][1]}),
4 "hard" ({LEVELS['hard'][1]}). Nur Stoff, der bis zu dieser Woche behandelt wurde; Schwierigkeit nicht kuenstlich erhoehen.
Bevorzuge automatisch pruefbare Typen: "mc" (genau eine richtige Option), "multi" (mehrere richtige), "number" (Zahlenwert mit
Toleranz). Hoechstens 4 offene Aufgaben ("short" Kurzantwort, "text" Erklaerung, "calc" Rechenweg). Rechne jede Musterloesung
selbst nach. Punkte zusammen 100. {past}

MATERIAL:
{_materials_block(mats)}

JSON:
{{"title": "kurzer Titel mit den Themen", "topics": ["Thema", ...],
  "questions": [{{"level": "short|medium|hard", "type": "mc|multi|number|short|text|calc", "question": "Aufgabentext, Formeln als Text",
    "options": ["A ...", "B ..."] (nur mc/multi), "points": Zahl, "minutes": Zahl, "goal": "Lernziel",
    "sources": [{{"q": "Q-Nummer", "page": Seite}}], "past_exam": false, "past_exam_like": false,
    "answer": "Musterloesung (bei mc/multi die Buchstaben, z. B. B oder A,C)", "value": Zahl (nur number), "tolerance": Zahl (nur number),
    "rubric": "Punkteschema fuer offene Aufgaben", "explanation": "Erklaerung des Loesungswegs", "typical_errors": ["..."]}}]}}"""


def _review_prompt(mats: list[dict], qs: list[dict]) -> str:
    return f"""Pruefe jede Aufgabe dieses Wochentests streng: vollstaendig gestellt, eindeutig loesbar, Musterloesung fachlich richtig
(selbst nachrechnen), vom Material gedeckt, passende Schwierigkeit, keine Dublette, Quellen stimmen. Antworte mit JSON
{{"verdicts": [{{"i": Index ab 0, "ok": true|false, "problem": "kurz, nur wenn ok=false", "fixed_answer": "nur wenn die
Musterloesung falsch war und du sie sicher korrigieren kannst"}}]}}.

MATERIAL (gekuerzt):
{_materials_block(mats)[:60000]}

AUFGABEN:
{json.dumps(qs, ensure_ascii=False)}"""


def _letters(s) -> set[str]:
    return {x for x in re.findall(r"\b([A-H])\b", str(s or "").upper())}


def check_question(q: dict) -> str | None:
    """Feste Pruefung einer erzeugten Aufgabe; Rueckgabe = Grund oder None."""
    if q.get("level") not in LEVELS or q.get("type") not in TYPES:
        return "Stufe oder Typ unbekannt"
    if len(str(q.get("question") or "").strip()) < 12:
        return "Aufgabe zu kurz"
    try:
        if not 1 <= float(q.get("points")) <= 40:
            return "Punkte"
    except (TypeError, ValueError):
        return "Punkte"
    if q["type"] in ("mc", "multi"):
        opts = q.get("options")
        if not isinstance(opts, list) or not 2 <= len(opts) <= 8:
            return "Optionen"
        letters = _letters(q.get("answer"))
        allowed = {chr(65 + i) for i in range(len(opts))}
        if not letters or not letters <= allowed or (q["type"] == "mc" and len(letters) != 1):
            return "Lösung passt nicht zu den Optionen"
    if q["type"] == "number":
        try:
            float(q.get("value")); float(q.get("tolerance") if q.get("tolerance") is not None else 0)
        except (TypeError, ValueError):
            return "Zahlenwert"
    if not str(q.get("answer") or "").strip() and q["type"] != "number":
        return "Musterlösung fehlt"
    return None


def generate(mats: list[dict]) -> tuple[str, list, list, dict, dict]:
    """Phase D und E. Liefert (Titel, Themen, oeffentliche Aufgaben, Loesungen je Aufgaben-ID, Pruefbericht)."""
    from . import ai_backend
    res = ai_backend.complete(None, "weekly:generate", SYSTEM, _gen_prompt(mats))
    data = _json(res.text)
    raw = [q for q in (data.get("questions") or []) if isinstance(q, dict)]
    report = {"generated": len(raw), "rejected": []}
    good = []
    seen = set()
    for i, q in enumerate(raw):
        why = check_question(q)
        key = re.sub(r"\W+", "", str(q.get("question") or "").lower())[:160]
        if not why and key in seen:
            why = "Dublette"
        seen.add(key)
        if why:
            report["rejected"].append({"i": i, "why": why})
        else:
            good.append(q)
    if good:
        rev = _json(ai_backend.complete(None, "weekly:review", SYSTEM, _review_prompt(mats, good)).text)
        verdicts = {int(v.get("i", -1)): v for v in (rev.get("verdicts") or []) if isinstance(v, dict)}
        kept = []
        for i, q in enumerate(good):
            v = verdicts.get(i)
            if v is None:
                report["rejected"].append({"q": q.get("question", "")[:60], "why": "nicht geprüft"})
                continue
            if not v.get("ok"):
                if v.get("fixed_answer") and q["type"] not in ("mc", "multi", "number"):
                    q["answer"] = str(v["fixed_answer"])
                else:
                    report["rejected"].append({"q": q.get("question", "")[:60], "why": str(v.get("problem") or "Prüfung")[:200]})
                    continue
            kept.append(q)
        good = kept
    # Punkte auf 100 bringen, IDs vergeben, oeffentlichen Teil und Loesungen trennen
    total = sum(float(q["points"]) for q in good) or 1
    public, solutions = [], {}
    order = {"short": 0, "medium": 1, "hard": 2}
    good = sorted(good, key=lambda q: order[q["level"]])
    pts_all = [round(float(q["points"]) * 100 / total, 1) for q in good]
    if pts_all:                                            # Rundungsrest auf die groesste Aufgabe, Summe genau 100
        big = max(range(len(pts_all)), key=lambda i: pts_all[i])
        pts_all[big] = round(pts_all[big] + 100 - sum(pts_all), 1)
    for n, q in enumerate(good, 1):
        qid = f"q{n}"
        pts = pts_all[n - 1]
        public.append({"id": qid, "nr": n, "level": q["level"], "type": q["type"], "question": str(q["question"]),
                       "options": q.get("options") if q["type"] in ("mc", "multi") else None, "points": pts,
                       "minutes": q.get("minutes"), "goal": q.get("goal"), "sources": q.get("sources") or [],
                       "past_exam": bool(q.get("past_exam")), "past_exam_like": bool(q.get("past_exam_like"))})
        solutions[qid] = {"answer": q.get("answer"), "value": q.get("value"), "tolerance": q.get("tolerance"), "rubric": q.get("rubric"),
                          "explanation": q.get("explanation"), "typical_errors": q.get("typical_errors") or []}
    report["published"] = len(public)
    return str(data.get("title") or "Wochentest")[:160], [str(t)[:80] for t in (data.get("topics") or [])][:12], public, solutions, report


def _json(text: str) -> dict:
    t = (text or "").strip()
    m = re.search(r"\{.*\}", t, re.S)
    try:
        d = json.loads(m.group(0) if m else t)
        return d if isinstance(d, dict) else {}
    except ValueError:
        return {}


# ---------------------------------------------------------------- Bearbeiten, Abgeben, Bewerten

def start(user: dict, test_id: str, practice: bool = False) -> dict:
    _may_take(user)
    with cursor() as conn:
        t = conn.execute("SELECT * FROM weekly_tests WHERE id=? AND status='published'", (str(test_id),)).fetchone()
        if not t:
            raise CommunityError("not_found", "Test nicht gefunden.", 404)
        off = conn.execute("SELECT * FROM weekly_attempts WHERE test_id=? AND user_id=? AND official=1", (t["id"], user["id"])).fetchone()
        if off and (not practice or not off["submitted_at"]):
            return _public(t, off, with_solutions=bool(off["submitted_at"]))
        aid = uuid.uuid4().hex
        try:
            conn.execute("INSERT INTO weekly_attempts(id, test_id, user_id, official, started_at, updated_at, answers, status) VALUES (?,?,?,?,?,?, '{}', 'draft')",
                         (aid, t["id"], user["id"], 0 if off else 1, _now(), _now()))
        except Exception:                                  # noqa: BLE001 - zweites Geraet hat gleichzeitig begonnen
            off = conn.execute("SELECT * FROM weekly_attempts WHERE test_id=? AND user_id=? AND official=1", (t["id"], user["id"])).fetchone()
            return _public(t, off, with_solutions=bool(off and off["submitted_at"]))
        a = conn.execute("SELECT * FROM weekly_attempts WHERE id=?", (aid,)).fetchone()
        return _public(t, a, with_solutions=bool(off and off["submitted_at"]))


def _own_attempt(conn, user: dict, attempt_id: str):
    a = conn.execute("SELECT * FROM weekly_attempts WHERE id=?", (str(attempt_id),)).fetchone()
    if not a or a["user_id"] != user["id"]:
        raise CommunityError("not_found", "Versuch nicht gefunden.", 404)
    return a


def _clean_answers(answers) -> dict:
    if not isinstance(answers, dict):
        return {}
    out = {}
    for k, v in list(answers.items())[:40]:
        if isinstance(v, list):
            v = ",".join(str(x)[:4] for x in v[:8])
        out[str(k)[:8]] = str(v if v is not None else "")[:6000]
    return out


def save(user: dict, attempt_id: str, answers) -> dict:
    """Zwischenspeichern (nur offener Versuch). Mehrere Geraete: der zuletzt gespeicherte Stand gilt je Aufgabe."""
    with cursor() as conn:
        a = _own_attempt(conn, user, attempt_id)
        if a["submitted_at"]:
            raise CommunityError("already_submitted", "Der Versuch ist schon abgegeben.", 409)
        merged = json.loads(a["answers"] or "{}") | _clean_answers(answers)
        conn.execute("UPDATE weekly_attempts SET answers=?, updated_at=? WHERE id=?", (json.dumps(merged, ensure_ascii=False), _now(), a["id"]))
    return {"saved": True, "updated_at": _now()}


def _num(s) -> float | None:
    m = re.search(r"-?\d+(?:[.,]\d+)?(?:[eE]-?\d+)?", str(s or ""))
    return float(m.group(0).replace(",", ".")) if m else None


def grade_auto(q: dict, sol: dict, ans: str) -> float | None:
    """Punkte fuer automatisch pruefbare Aufgaben, None fuer offene."""
    if q["type"] == "mc":
        return q["points"] if _letters(ans) == _letters(sol.get("answer")) and _letters(ans) else 0.0
    if q["type"] == "multi":
        return q["points"] if _letters(ans) == _letters(sol.get("answer")) and _letters(ans) else 0.0
    if q["type"] == "number":
        x, want = _num(ans), _num(sol.get("value"))
        tol = abs(_num(sol.get("tolerance")) or 0.0)
        if x is None or want is None:
            return 0.0
        return q["points"] if abs(x - want) <= max(tol, 1e-9 * max(1.0, abs(want))) else 0.0
    return None


def _grade_open(qs: list[dict], sols: dict, answers: dict, user_id: str | None = None) -> dict:
    """Offene Antworten in einer KI-Anfrage; Rueckgabe je Aufgabe {points, feedback, confident}."""
    from . import ai_backend
    items = [{"id": q["id"], "question": q["question"], "max": q["points"], "solution": sols[q["id"]].get("answer"),
              "rubric": sols[q["id"]].get("rubric"), "answer": answers.get(q["id"], "")} for q in qs]
    prompt = ("Bewerte die Antworten streng nach Musterloesung und Schema. Vergib keine Punkte, die das Schema nicht hergibt. "
              "Leere Antwort = 0. JSON: {\"grades\": [{\"id\": \"q..\", \"points\": Zahl, \"feedback\": \"1-2 Saetze\", "
              "\"confidence\": 0..1}]}\n\n" + json.dumps(items, ensure_ascii=False))
    data = _json(ai_backend.complete(user_id, "weekly:grade", SYSTEM, prompt).text)   # Kostenrahmen des Kontos
    out = {}
    for g in data.get("grades") or []:
        if isinstance(g, dict) and g.get("id") in sols:
            mx = next(q["points"] for q in qs if q["id"] == g["id"])
            try:
                pts = max(0.0, min(float(g.get("points") or 0), mx))
            except (TypeError, ValueError):
                pts = 0.0
            out[g["id"]] = {"points": round(pts, 1), "feedback": str(g.get("feedback") or "")[:400],
                            "confident": float(g.get("confidence") or 0) >= 0.6}
    return out


def submit(user: dict, attempt_id: str, answers=None, leaderboard: bool | None = None, display_name: str | None = None) -> dict:
    """Abgeben (einmal; Wiederholung liefert dasselbe Ergebnis). Bewertung nur hier, nie vom Geraet."""
    with cursor() as conn:
        a = _own_attempt(conn, user, attempt_id)
        t = conn.execute("SELECT * FROM weekly_tests WHERE id=?", (a["test_id"],)).fetchone()
        if a["submitted_at"]:
            return _public(t, a, with_solutions=True)
        merged = json.loads(a["answers"] or "{}") | _clean_answers(answers or {})
        now = _now()
        secs = int((datetime.fromisoformat(now.replace("Z", "+00:00")) - datetime.fromisoformat(a["started_at"].replace("Z", "+00:00"))).total_seconds())
        name = _display_name(display_name, user)
        cur = conn.execute("""UPDATE weekly_attempts SET answers=?, submitted_at=?, updated_at=?, status='grading', seconds=?, leaderboard=?, display_name=?
                              WHERE id=? AND submitted_at IS NULL""",
                           (json.dumps(merged, ensure_ascii=False), now, now, secs, 1 if leaderboard else 0, name, a["id"]))
        if not cur.rowcount:                               # gleichzeitig vom anderen Geraet abgegeben
            return _public(t, conn.execute("SELECT * FROM weekly_attempts WHERE id=?", (a["id"],)).fetchone(), with_solutions=True)
    grade(a["id"])
    with cursor() as conn:
        return _public(t, conn.execute("SELECT * FROM weekly_attempts WHERE id=?", (a["id"],)).fetchone(), with_solutions=True)


def grade(attempt_id: str) -> None:
    with cursor() as conn:
        a = conn.execute("SELECT * FROM weekly_attempts WHERE id=?", (attempt_id,)).fetchone()
        t = conn.execute("SELECT * FROM weekly_tests WHERE id=?", (a["test_id"],)).fetchone()
    qs, sols, answers = json.loads(t["questions"]), json.loads(t["solutions"]), json.loads(a["answers"] or "{}")
    per, open_qs = {}, []
    for q in qs:
        pts = grade_auto(q, sols[q["id"]], answers.get(q["id"], ""))
        if pts is None:
            if str(answers.get(q["id"], "")).strip():
                open_qs.append(q)
            else:
                per[q["id"]] = {"points": 0.0, "feedback": "Keine Antwort.", "confident": True, "auto": True}
        else:
            per[q["id"]] = {"points": pts, "auto": True, "confident": True}
    status, review = "graded", False
    if open_qs:
        try:
            got = _grade_open(open_qs, sols, answers, a["user_id"])
            for q in open_qs:
                g = got.get(q["id"])
                if not g:
                    per[q["id"]] = {"points": 0.0, "feedback": "Noch nicht bewertet.", "confident": False}
                    review = True
                else:
                    per[q["id"]] = g
                    review = review or not g["confident"]
        except Exception:                                  # noqa: BLE001 - KI nicht erreichbar: spaeter bewerten
            status = "grading_pending"
            for q in open_qs:
                per[q["id"]] = {"points": 0.0, "feedback": "Bewertung folgt.", "confident": False}
    score = round(sum(v["points"] for v in per.values()), 1)
    mx = round(sum(q["points"] for q in qs), 1)
    with cursor() as conn:
        conn.execute("UPDATE weekly_attempts SET status=?, score=?, max_score=?, result=?, needs_review=? WHERE id=?",
                     (status, score, mx, json.dumps(per, ensure_ascii=False), 1 if (review or status != "graded") else 0, attempt_id))


def _display_name(name: str | None, user: dict) -> str:
    n = (name or "").strip()
    if n and NAME_RE.match(n) and "@" not in n:
        return n
    return pseudonym(user["id"])


def set_leaderboard(user: dict, attempt_id: str, on: bool, display_name: str | None = None) -> dict:
    with cursor() as conn:
        a = _own_attempt(conn, user, attempt_id)
        if not a["official"]:
            raise CommunityError("practice_attempt", "Nur der erste abgegebene Versuch kommt in die Rangliste.")
        conn.execute("UPDATE weekly_attempts SET leaderboard=?, display_name=? WHERE id=?", (1 if on else 0, _display_name(display_name or a["display_name"], user), a["id"]))
    return {"leaderboard": on}


def leaderboard(user: dict, test_id: str, now: datetime | None = None) -> dict:
    """Vor der Frist: Teilnehmerzahl und eigener Stand; danach die ganze Rangliste (nur freiwillige, sicher bewertete
    erste Versuche). Gleiche Punkte = gleicher Platz."""
    with cursor() as conn:
        t = conn.execute("SELECT * FROM weekly_tests WHERE id=?", (str(test_id),)).fetchone()
        if not t:
            raise CommunityError("not_found", "Test nicht gefunden.", 404)
        rows = conn.execute("""SELECT * FROM weekly_attempts WHERE test_id=? AND official=1 AND submitted_at IS NOT NULL
                               AND status='graded' AND needs_review=0 ORDER BY score DESC, submitted_at""", (t["id"],)).fetchall()
        mine = conn.execute("SELECT * FROM weekly_attempts WHERE test_id=? AND user_id=? AND official=1", (t["id"], user["id"])).fetchone()
    t_now = now or datetime.now(timezone.utc)
    closed = bool(t["closes_at"]) and t_now >= datetime.fromisoformat(t["closes_at"].replace("Z", "+00:00"))
    ranked, rank, prev = [], 0, None
    for i, r in enumerate(rows, 1):
        if r["score"] != prev:
            rank, prev = i, r["score"]
        ranked.append((rank, r))
    # eigener Platz erst nach der Frist, wie die Rangliste selbst (sonst beeinflusst er, wer noch nicht abgegeben hat)
    my_rank = next((rk for rk, r in ranked if mine and r["id"] == mine["id"]), None) if closed else None
    out = {"test_id": t["id"], "closes_at": t["closes_at"], "visible": closed, "participants": len(rows), "my_rank": my_rank,
           "mine": _attempt_out(mine) if mine else None}
    if closed:
        out["entries"] = [{"rank": rk, "name": r["display_name"] or "Studi", "score": r["score"], "max": r["max_score"],
                           "percent": round(100 * (r["score"] or 0) / (r["max_score"] or 1)), "minutes": round((r["seconds"] or 0) / 60),
                           "me": bool(mine and r["id"] == mine["id"])} for rk, r in ranked if r["leaderboard"]]
    return out


def forget(user_id: str) -> None:
    with cursor() as conn:
        conn.execute("DELETE FROM weekly_attempts WHERE user_id=?", (user_id,))
        conn.execute("UPDATE weekly_tests SET created_by=NULL WHERE created_by=?", (user_id,))

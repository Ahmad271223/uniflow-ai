"""Gemeinsame StudiNow-Testbibliothek: geprueften Fragen wiederverwenden, nur Fehlendes generieren.

Ablauf beim Erstellen eines Tests (app/library_api.py):
1. Passende, wiederverwendbare Fragen im Pool suchen (Fach, Thema, Unterthema, Lernziel, Schwierigkeit, Modul,
   Hochschule, Dokument und Dokumentfassung, Fingerabdruck der PDF, Textaehnlichkeit). Gleiche PDFs sind nicht noetig:
   „Grundlagen der Statistik“ aus Hannover und Hildesheim teilen sich den Pool, wenn Fach und Thema zusammenpassen.
2. Reicht das, entsteht der Test nur aus dem Pool (Kontingent „Tests aus der Bibliothek“, keine KI-Kosten).
3. Sonst werden nur die fehlenden Fragen von der StudiNow-KI generiert (Kontingent „Neue KI-Tests“), mit einer Sperre
   je Thema, damit gleichzeitige Anfragen nicht doppelt generieren.

Pruefstufen (`review`):
- `private`   – nur fuer den Besitzer, nie im Pool (Standard fuer eigene Tests und Tests aus dem eigenen ChatGPT).
- `pending`   – vom Nutzer ausdruecklich zur Freigabe eingereicht, wartet auf die Moderation. Nicht im Pool.
- `auto_checked` – von der StudiNow-KI erzeugt, und zwar aus Fach, Thema, Unterthema und Lernziel, die der anfragende
  Nutzer frei eingibt (der Prompt enthaelt also Text des Nutzers). Nur eine automatische Formpruefung bestanden: Form,
  Loesung unter den Antwortmoeglichkeiten, keine Links oder persoenlichen Angaben in Frage, Antworten, Loesung und
  Erklaerung. Die fachliche Richtigkeit wird nicht geprueft und es gibt keine Moderation. Im Pool.
- `approved`  – von der Moderation geprueft. Im Pool.
- `rejected`  – abgelehnt, nie im Pool.

Datenschutz: Fragen, die Nutzer freigeben, werden vor dem Einreichen bereinigt (E-Mail, Telefon, Matrikelnummer,
Adressen, Namen nach „Name:“ u. ae.). Der Pool kennt Besitzer nur als nicht umkehrbaren Kurzwert (HMAC).
Die Bibliothek liegt zentral in `library.db` neben `accounts.db`, nie in einem Nutzerordner.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import re
import sqlite3
import unicodedata
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone

from . import config

SCHEMA = """
CREATE TABLE IF NOT EXISTS questions (
    id TEXT PRIMARY KEY,
    fingerprint TEXT NOT NULL UNIQUE,     -- SHA-256 des normalisierten Fragetexts samt Antwort (Dubletten)
    subject TEXT NOT NULL,
    subject_key TEXT NOT NULL,
    topic TEXT NOT NULL,
    topic_key TEXT NOT NULL,
    subtopic TEXT,
    learning_goal TEXT,
    difficulty INTEGER NOT NULL DEFAULT 3, -- 1 leicht … 5 klausurnah
    university TEXT,
    module_key TEXT,
    doc_ref TEXT,
    doc_version TEXT,
    doc_sha256 TEXT,
    qtype TEXT NOT NULL DEFAULT 'mc',     -- mc | short
    question TEXT NOT NULL,
    options TEXT,                         -- JSON-Liste bei mc
    answer TEXT NOT NULL,
    explanation TEXT,
    points INTEGER NOT NULL DEFAULT 10,
    tokens TEXT NOT NULL,                 -- normalisierte Woerter fuer die Aehnlichkeit
    source TEXT NOT NULL,                 -- studora_ai | user_shared | chatgpt_user
    review TEXT NOT NULL,                 -- private | pending | auto_checked | approved | rejected
    owner_hash TEXT,
    created_at TEXT NOT NULL,
    reviewed_at TEXT,
    reviewed_by TEXT,
    uses INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_questions_subject ON questions(subject_key, review);
CREATE TABLE IF NOT EXISTS seen (
    owner_hash TEXT NOT NULL,
    question_id TEXT NOT NULL,
    seen_at TEXT NOT NULL,
    PRIMARY KEY (owner_hash, question_id)
);
-- Gemeinsame Wochentests (app/testshare.py, docs/GEMEINSAME-WOCHENTESTS.md): je Schluessel hoechstens
-- testshare.MAX_VARIANTS Plaetze (variant 0..2). Ein Platz wird zuerst belegt (status pending, ohne Inhalt), dann mit
-- dem fertigen Test gefuellt (ready). Besitzer nur als nicht umkehrbarer Kurzwert (owner_hash), keine Antworten.
CREATE TABLE IF NOT EXISTS shared_tests (
    share_key TEXT NOT NULL,
    variant INTEGER NOT NULL,
    status TEXT NOT NULL,                 -- pending | ready
    owner_hash TEXT,
    title TEXT,
    questions TEXT,                       -- JSON-Liste, erst bei ready
    created_at TEXT NOT NULL,
    published_at TEXT,
    uses INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (share_key, variant)
);
"""

REUSABLE = ("auto_checked", "approved")
STOP = set("""der die das den dem des ein eine einer eines einem einen und oder mit von zu zur zum im in an auf fuer
für aus bei ist sind wird werden als auch nicht nur wie was welche welcher welches wenn dann man sich es sie er wir
ihr ich du dass the and of to for with grundlagen einfuehrung einfuhrung kapitel teil""".split())
MIN_TOPIC_SIM = 0.34
MIN_SUBJECT_SIM = 0.5


def db_path():
    return config.BASE_DATA_DIR / "library.db"


@contextmanager
def cursor():
    p = db_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(p, timeout=15, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    from . import db
    db.schema_once(conn, "test_library", p, lambda c: c.executescript(SCHEMA))
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def forget_owner(user_id: str) -> dict:
    """Konto endgueltig geloescht: eigene, nicht freigegebene Fragen (privat, wartend, vom Nutzer geteilt) entfernen,
    freigegebene Fragen ohne Besitzer behalten (sie enthalten nach der Pruefung keine persoenlichen Angaben),
    Gesehen-Liste loeschen."""
    owner = owner_hash(user_id)
    with cursor() as conn:
        gone = conn.execute("""DELETE FROM questions WHERE owner_hash=? AND (review IN ('private','pending','rejected')
                               OR source IN ('user_shared','chatgpt_user'))""", (owner,)).rowcount
        kept = conn.execute("UPDATE questions SET owner_hash=NULL WHERE owner_hash=?", (owner,)).rowcount
        seen = conn.execute("DELETE FROM seen WHERE owner_hash=?", (owner,)).rowcount
        # gemeinsame Wochentests bleiben fuer die anderen (ohne Besitzer); leere Belegungen werden frei
        conn.execute("DELETE FROM shared_tests WHERE owner_hash=? AND status='pending'", (owner,))
        kept += conn.execute("UPDATE shared_tests SET owner_hash=NULL WHERE owner_hash=?", (owner,)).rowcount
    return {"deleted": gone, "anonymized": kept, "seen": seen}


def owner_hash(user_id: str) -> str:
    from . import vault
    return hmac.new(vault.master_key(), b"library-owner:" + user_id.encode("ascii"), hashlib.sha256).hexdigest()[:24]


# ---------------------------------------------------------------- Text: Normalisierung, Aehnlichkeit

def _fold(s: str) -> str:
    s = (s or "").lower().replace("ä", "ae").replace("ö", "oe").replace("ü", "ue").replace("ß", "ss")
    return unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode("ascii")


def _stem(w: str) -> str:
    for suf in ("ungen", "ung", "en", "er", "es", "e", "n", "s"):
        if len(w) > len(suf) + 3 and w.endswith(suf):
            return w[: -len(suf)]
    return w


def tokens(*texts: str) -> set[str]:
    out = set()
    for t in texts:
        for w in re.findall(r"[a-z0-9]+", _fold(t)):
            if len(w) >= 3 and w not in STOP:
                out.add(_stem(w))
    return out


def key(text: str) -> str:
    return " ".join(sorted(tokens(text))) or _fold(text).strip()


def similarity(a: set[str], b: set[str]) -> float:
    """Jaccard der Wortmengen; austauschbar gegen Einbettungen, ohne die Aufrufer zu aendern."""
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def _plain(text: str) -> str:
    """Vollstaendiger Text ohne Gross-/Kleinschreibung, Akzente und Satzzeichen; Zahlen bleiben (3+4 ist nicht 5+6)."""
    return " ".join(re.findall(r"[a-z0-9]+|[+\-*/=^<>]", _fold(text)))


def fingerprint(question: str, answer: str) -> str:
    return hashlib.sha256((_plain(question) + "|" + _plain(answer)).encode()).hexdigest()


# ---------------------------------------------------------------- Datenschutz und Qualitaet

_PII = [
    (re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+"), "[E-Mail entfernt]"),
    (re.compile(r"https?://\S+"), "[Link entfernt]"),
    (re.compile(r"(?i)\b(matrikel(?:nummer|nr\.?)?|mat\.?-?nr\.?)\s*:?\s*\d{5,9}\b"), "[Matrikelnummer entfernt]"),
    (re.compile(r"(?<![\d.,])\+?\d[\d /-]{7,}\d(?!\d)"), "[Nummer entfernt]"),
    (re.compile(r"(?i)\b(name|student(?:in)?|verfasser(?:in)?|autor(?:in)?|von)\s*:\s*[A-ZÄÖÜ][\wäöüß-]+(?:\s+[A-ZÄÖÜ][\wäöüß-]+)*"),
     r"\1: [Name entfernt]"),
    (re.compile(r"(?i)\b[\wäöüß-]+(?:strasse|straße|str\.|weg|allee|platz)\s+\d+[a-z]?\b"), "[Adresse entfernt]"),
]


def scrub(text: str | None) -> str:
    out = text or ""
    for rx, repl in _PII:
        out = rx.sub(repl, out)
    return out


def scrub_question(q: dict) -> dict:
    q = dict(q)
    for k in ("question", "answer", "explanation"):
        if q.get(k):
            q[k] = scrub(str(q[k]))
    if isinstance(q.get("options"), list):
        q["options"] = [scrub(str(o)) for o in q["options"]]
    return q


_OPT_PREFIX = re.compile(r"^\s*([a-f])\s*[).:]\s*|^\s*([a-f])\s+(?=\S)", re.I)


def _option_index(value: str, options: list[str]) -> int | None:
    """Welche Antwortmoeglichkeit meint `value`? Buchstabe ("B", "b)"), voller Text oder Text ohne Buchstaben."""
    v = _fold(value).strip()
    if not v:
        return None
    m = re.fullmatch(r"([a-f])\s*[).:]?", v)
    if m and "abcdef".index(m.group(1)) < len(options):
        return "abcdef".index(m.group(1))
    v_body = _OPT_PREFIX.sub("", v).strip()
    for i, o in enumerate(options):
        fo = _fold(o).strip()
        body = _OPT_PREFIX.sub("", fo).strip()
        if v in (fo, body) or (v_body and v_body in (fo, body)):
            return i
    return None


def _answer_in_options(answer: str, options: list[str]) -> bool:
    return _option_index(answer, options) is not None


def check(q: dict) -> list[str]:
    """Automatische Pruefung einer Frage; leere Liste = in Ordnung."""
    errs = []
    text = str(q.get("question") or "").strip()
    answer = str(q.get("answer") or "").strip()
    if len(text) < 15:
        errs.append("Fragetext zu kurz")
    if not answer:
        errs.append("Lösung fehlt")
    qtype = q.get("type") or q.get("qtype") or "mc"
    if qtype == "mc":
        opts = q.get("options")
        if not isinstance(opts, list) or not 2 <= len(opts) <= 6 or len({_fold(str(o)) for o in opts}) != len(opts):
            errs.append("Antwortmöglichkeiten fehlen oder doppelt")
        elif answer and not _answer_in_options(answer, [str(o) for o in opts]):
            errs.append("Lösung ist keine der Antwortmöglichkeiten")
    d = q.get("difficulty", 3)
    if not isinstance(d, int) or not 1 <= d <= 5:
        errs.append("Schwierigkeit muss 1 bis 5 sein")
    extra = [str(o) for o in q.get("options") or []] if isinstance(q.get("options"), list) else []
    extra.append(str(q.get("explanation") or ""))        # Optionen und Erklaerung: Links und Personenangaben
    if scrub(text) != text or scrub(answer) != answer or any(scrub(x) != x for x in extra):
        errs.append("enthält persönliche Daten oder Links")
    return errs


# ---------------------------------------------------------------- Pool: Ablegen, Suchen, Zusammenstellen

def add(questions: list[dict], meta: dict, source: str, review: str, owner: str | None = None) -> list[str]:
    """Fragen ablegen; Dubletten (gleicher Fingerabdruck) werden nicht doppelt gespeichert. Liefert die IDs
    (bei Dubletten die vorhandene ID). Fragen, die die Pruefung nicht bestehen, werden uebersprungen."""
    subject, topic = (meta.get("subject") or "").strip(), (meta.get("topic") or "").strip()
    if not subject or not topic:
        raise ValueError("Fach und Thema sind Pflicht")
    ids = []
    with cursor() as conn:
        for q in questions:
            if source != "studora_ai":
                q = scrub_question(q)
            q.setdefault("difficulty", int(meta.get("difficulty") or 3))
            if check(q):
                continue
            fp = fingerprint(q["question"], str(q["answer"]))
            ex = conn.execute("SELECT id, review FROM questions WHERE fingerprint=?", (fp,)).fetchone()
            if ex:
                # eine private Kopie wird durch Einreichen nicht automatisch oeffentlich; hoeher eingestufte bleiben
                if ex["review"] == "private" and review == "pending":
                    conn.execute("UPDATE questions SET review='pending' WHERE id=?", (ex["id"],))
                ids.append(ex["id"])
                continue
            qid = uuid.uuid4().hex
            conn.execute("""INSERT INTO questions(id, fingerprint, subject, subject_key, topic, topic_key, subtopic, learning_goal,
                            difficulty, university, module_key, doc_ref, doc_version, doc_sha256, qtype, question, options, answer,
                            explanation, points, tokens, source, review, owner_hash, created_at)
                            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                         (qid, fp, subject, key(subject), topic, key(topic), meta.get("subtopic"), meta.get("learning_goal"),
                          int(q["difficulty"]), meta.get("university"), key(meta.get("module") or "") or None,
                          meta.get("doc_ref"), meta.get("doc_version"), meta.get("doc_sha256"),
                          q.get("type") or q.get("qtype") or "mc", q["question"].strip(),
                          json.dumps(q.get("options"), ensure_ascii=False) if q.get("options") else None,
                          str(q["answer"]).strip(), q.get("explanation"), int(q.get("points") or 10),
                          " ".join(sorted(tokens(q["question"], " ".join(map(str, q.get("options") or []))))),
                          source, review, owner, _now()))
            ids.append(qid)
    return ids


def _score(req: dict, r: sqlite3.Row) -> float | None:
    subj = similarity(tokens(req.get("subject", "")), set(r["subject_key"].split()))
    if subj < MIN_SUBJECT_SIM and r["subject_key"] != key(req.get("subject", "")):
        return None
    want_topic = tokens(req.get("topic", ""), req.get("subtopic") or "", req.get("learning_goal") or "")
    have_topic = set(r["topic_key"].split()) | tokens(r["subtopic"] or "", r["learning_goal"] or "")
    topic = max(similarity(want_topic, have_topic), similarity(want_topic, set(r["tokens"].split())) * 0.8)
    if topic < MIN_TOPIC_SIM:
        return None
    score = subj * 0.3 + topic * 0.7
    if req.get("doc_sha256") and r["doc_sha256"] == req["doc_sha256"]:
        score += 0.3
    if req.get("module") and r["module_key"] and r["module_key"] == key(req["module"]):
        score += 0.1
    if req.get("university") and r["university"] == req["university"]:
        score += 0.05
    return score


def _difficulty_ok(req: dict, d: int) -> bool:
    want = req.get("difficulty")
    if not want:
        return True
    want = int(want)
    return d >= want if req.get("harder") else abs(d - want) <= 1


def find(req: dict, owner: str | None = None, limit: int = 50) -> list[dict]:
    """Wiederverwendbare Fragen zum Wunsch, beste zuerst; ohne bereits gesehene des Nutzers."""
    with cursor() as conn:
        rows = conn.execute(f"SELECT * FROM questions WHERE review IN ({','.join('?' * len(REUSABLE))})", REUSABLE).fetchall()
        seen = {r[0] for r in conn.execute("SELECT question_id FROM seen WHERE owner_hash=?", (owner,))} if owner else set()
    scored = []
    for r in rows:
        if r["id"] in seen or not _difficulty_ok(req, r["difficulty"]):
            continue
        s = _score(req, r)
        if s is not None:
            scored.append((s, -r["uses"], r))
    scored.sort(key=lambda x: (x[0], x[1]), reverse=True)
    return [_public(r) for _, _, r in scored[:limit]]


def _public(r: sqlite3.Row) -> dict:
    return {"id": r["id"], "type": r["qtype"], "question": r["question"],
            "options": json.loads(r["options"]) if r["options"] else None, "answer": r["answer"],
            "explanation": r["explanation"], "points": r["points"], "difficulty": r["difficulty"],
            "subject": r["subject"], "topic": r["topic"], "subtopic": r["subtopic"], "source": r["source"], "review": r["review"]}


def mark_used(owner: str, question_ids: list[str]) -> None:
    with cursor() as conn:
        for qid in question_ids:
            conn.execute("INSERT OR IGNORE INTO seen(owner_hash, question_id, seen_at) VALUES (?,?,?)", (owner, qid, _now()))
            conn.execute("UPDATE questions SET uses=uses+1 WHERE id=?", (qid,))


def get(question_id: str) -> dict | None:
    with cursor() as conn:
        r = conn.execute("SELECT * FROM questions WHERE id=?", (question_id,)).fetchone()
    return {**_public(r), "owner_hash": r["owner_hash"]} if r else None


def submit_for_sharing(owner: str, questions: list[dict], meta: dict, source: str = "user_shared") -> dict:
    """Eigene Fragen ausdruecklich zur gemeinsamen Nutzung einreichen: bereinigt, gepruefte Form, Stufe `pending`.
    Oeffentlich (im Pool) erst nach Freigabe durch die Moderation."""
    accepted, rejected = [], []
    for q in questions:
        clean = scrub_question(q)
        clean.setdefault("difficulty", int(meta.get("difficulty") or 3))
        (rejected if check(clean) else accepted).append(clean)
    ids = add(accepted, meta, source, "pending", owner) if accepted else []
    return {"submitted": len(ids), "rejected": len(rejected), "ids": ids, "review": "pending"}


def moderation_queue(limit: int = 100) -> list[dict]:
    with cursor() as conn:
        rows = conn.execute("SELECT * FROM questions WHERE review='pending' ORDER BY created_at LIMIT ?", (limit,)).fetchall()
    return [_public(r) for r in rows]


def moderate(question_id: str, action: str, reviewer: str) -> dict:
    if action not in ("approve", "reject"):
        raise ValueError("Unbekannte Aktion")
    with cursor() as conn:
        r = conn.execute("SELECT review FROM questions WHERE id=?", (question_id,)).fetchone()
        if not r:
            raise KeyError(question_id)
        conn.execute("UPDATE questions SET review=?, reviewed_at=?, reviewed_by=? WHERE id=?",
                     ("approved" if action == "approve" else "rejected", _now(), reviewer, question_id))
    return get(question_id)


def topic_lock_key(req: dict) -> str:
    """Schluessel der Generierungssperre: gleiches Fach, Thema und Schwierigkeit = gleiche Generierung."""
    return "gen:" + hashlib.sha256(f"{key(req.get('subject', ''))}|{key(req.get('topic', ''))}|{int(req.get('difficulty') or 3)}|"
                                    f"{bool(req.get('harder'))}".encode()).hexdigest()[:32]


def grade(questions: list[dict], answers: dict) -> dict:
    """Bewertung ohne KI: Multiple-Choice exakt, andere Fragen gegen die Musterloesung (normalisierter Text)."""
    total = mx = 0.0
    items = []
    for i, q in enumerate(questions, start=1):
        nr = str(q.get("nr") or i)
        pts = float(q.get("points") or 10)
        mx += pts
        given = str(answers.get(nr, "")).strip()
        if q.get("type") == "mc" and q.get("options"):
            opts = [str(o) for o in q["options"]]
            want = _option_index(str(q.get("answer") or ""), opts)
            ok = want is not None and _option_index(given, opts) == want
        else:
            ok = bool(given) and _fold(given).strip() == _fold(str(q.get("answer"))).strip()
        total += pts if ok else 0
        items.append({"nr": nr, "correct": ok, "points": pts if ok else 0, "max": pts, "answer": q.get("answer"),
                      "given": given, "topic": q.get("topic"), "question_id": q.get("library_id")})
    return {"total": total, "max": mx, "items": items, "graded_by": "studora"}


# ---------------------------------------------------------------- Gemeinsame Wochentests: Plaetze je Schluessel

# so lange wartet ein Nutzer auf die Variante, die ein anderer gerade erzeugt (dann uebernimmt er sie ohne KI)
SHARED_WAIT_S = 90.0
SHARED_POLL_S = 1.0


def _shared_row(r: sqlite3.Row) -> dict:
    return {"variant": int(r["variant"]), "status": r["status"], "title": r["title"],
            "questions": json.loads(r["questions"]) if r["questions"] else [], "created_at": r["created_at"],
            "published_at": r["published_at"], "owner_hash": r["owner_hash"]}


def _stale_cutoff(now: datetime | None = None) -> str:
    from . import testshare
    from datetime import timedelta
    return ((now or datetime.now(timezone.utc)) - timedelta(seconds=testshare.PENDING_STALE_S)).isoformat()


def shared_slots(key: str, now: datetime | None = None) -> dict[int, dict]:
    """Vorhandene Plaetze eines Schluessels: Variante -> {status, title, questions, ...}. Verwaiste Belegungen
    (pending, aelter als testshare.PENDING_STALE_S) werden dabei freigegeben."""
    with cursor() as conn:
        conn.execute("DELETE FROM shared_tests WHERE share_key=? AND status='pending' AND created_at<?", (key, _stale_cutoff(now)))
        rows = conn.execute("SELECT * FROM shared_tests WHERE share_key=? ORDER BY variant", (key,)).fetchall()
    return {int(r["variant"]): _shared_row(r) for r in rows}


def shared_claim(key: str, variant: int, user_id: str, now: datetime | None = None) -> bool:
    """Platz atomar belegen (PRIMARY KEY). False, wenn ihn gerade ein anderer belegt hat (Wettlauf)."""
    from . import testshare
    if not 0 <= int(variant) < testshare.MAX_VARIANTS:
        raise ValueError("Variante ausserhalb 0..2")
    t = (now or datetime.now(timezone.utc)).isoformat()
    with cursor() as conn:
        conn.execute("DELETE FROM shared_tests WHERE share_key=? AND variant=? AND status='pending' AND created_at<?",
                     (key, int(variant), _stale_cutoff(now)))
        got = conn.execute("INSERT OR IGNORE INTO shared_tests(share_key, variant, status, owner_hash, created_at) VALUES (?,?,'pending',?,?)",
                           (key, int(variant), owner_hash(user_id), t)).rowcount == 1
    return got


def shared_publish(key: str, variant: int, user_id: str, title: str | None, questions: list[dict], now: datetime | None = None) -> None:
    """Fertigen Test in den eigenen (belegten) Platz schreiben; fremde oder nicht belegte Plaetze bleiben unberuehrt."""
    t = (now or datetime.now(timezone.utc)).isoformat()
    with cursor() as conn:
        n = conn.execute("""UPDATE shared_tests SET status='ready', title=?, questions=?, published_at=?
                            WHERE share_key=? AND variant=? AND owner_hash=? AND status='pending'""",
                         (title, json.dumps(questions, ensure_ascii=False), t, key, int(variant), owner_hash(user_id))).rowcount
    if n != 1:
        raise KeyError("Platz nicht belegt oder nicht der eigene")


def shared_release(key: str, variant: int, user_id: str) -> None:
    """Eigenen, noch leeren Platz wieder freigeben (Erzeugen gescheitert)."""
    with cursor() as conn:
        conn.execute("DELETE FROM shared_tests WHERE share_key=? AND variant=? AND owner_hash=? AND status='pending'",
                     (key, int(variant), owner_hash(user_id)))


def shared_get(key: str, variant: int, count_use: bool = True) -> dict | None:
    """Fertiger Test eines Platzes oder None (nicht da oder noch in Arbeit)."""
    with cursor() as conn:
        r = conn.execute("SELECT * FROM shared_tests WHERE share_key=? AND variant=? AND status='ready'", (key, int(variant))).fetchone()
        if r and count_use:
            conn.execute("UPDATE shared_tests SET uses=uses+1 WHERE share_key=? AND variant=?", (key, int(variant)))
    return _shared_row(r) if r else None


def shared_wait(key: str, variant: int, timeout_s: float = SHARED_WAIT_S, poll_s: float = SHARED_POLL_S) -> dict | None:
    """Wartet, bis der Platz fertig ist (ein anderer Nutzer erzeugt ihn gerade). Liefert den Test oder None, wenn er in
    der Zeit nicht fertig wurde oder der Platz wieder frei ist."""
    import time
    end = time.monotonic() + max(0.0, timeout_s)
    while True:
        slot = shared_slots(key).get(int(variant))
        if slot is None:
            return None                                  # freigegeben (gescheitert oder verwaist): selbst erzeugen
        if slot["status"] == "ready":
            return shared_get(key, variant)
        if time.monotonic() >= end:
            return None
        time.sleep(min(poll_s, max(0.0, end - time.monotonic())) or 0.01)

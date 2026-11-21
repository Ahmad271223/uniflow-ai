"""StudiNow-Wissensbank und die KI (Auftrag des Inhabers 21.11.2026 abends; docs/WISSENSBANK-STAND.md).

Der genaue Abgleich (app/wissensbank.py) liefert eine Stelle der Bibliothek nur, wenn sie sicher dieselbe Seite bzw.
Aufgabe ist. Am iPad kam danach "meistens immer noch die KI". Zwei Erweiterungen, beide mit eigenem Schalter (Standard
aus) und nur fuer Konten, die die Wissensbank haben (Pro AI an der LUH, `wissensbank.allowed_for`):

A. KI mit Wissen aus der Wissensbank (`LERNAPP_WISSENSBANK_KONTEXT=1`)
   Gibt es keinen lieferbaren Treffer, sucht `suche` die bestpassenden Abschnitte - lockerer als der Abgleich: Einheiten
   zum Dateititel, sonst zum Kurs; Rang ueber die gemeinsamen Begriffe mit dem ganzen Abschnitt (Aufgabentext UND
   Loesung), Seiten- bzw. Aufgabennummer als Hinweis. Hoechstens KONTEXT_STELLEN Stellen und KONTEXT_ZEICHEN Zeichen gehen
   als klar abgegrenzter Block an den Prompt (`kontext_block`), mit der Anweisung, sie nur zu verwenden, wenn es
   wirklich dieselbe Seite bzw. Aufgabe ist. Abgerechnet wird wie jede KI-Antwort. Antwortfeld `wissensbank_kontext`.

B. Antworten merken (`LERNAPP_WISSENSBANK_MERKEN=freigabe|sofort`)
   Die erste KI-Antwort zu einer Stelle wird ohne Konto und ohne Frage gespeichert (Tabelle `wissensbank_gemerkt`:
   Dateititel, Kurs, Modus, Seite, normalisierter Text des Ausschnitts, Antwort). Ein anderes Konto bekommt sie, wenn
   sein Ausschnitt praktisch derselbe ist (`gleich`: beidseitig MERKEN_GLEICH der Wortfolgen, dieselben Zahlen) - sofort
   oder erst nach der Freigabe durch den Inhaber (`python -m app.wissensbank_pruefen --gemerkt`). Nur wenn die App mit
   `wissensbank.teilbar: true` zusichert, dass in der Anfrage nichts Persoenliches steckt (keine eigenen Notizen im
   Ausschnitt, kein Notiztext, kein Gespraechsverlauf, keine getippte Frage); fehlt das Feld, wird nichts gemerkt und
   nichts aus dem Gemerkten geliefert. Fragt dasselbe Konto dieselbe Stelle noch einmal, antwortet die KI frisch und
   fragt "Gefaellt dir diese Antwort besser?"; nach MERKEN_ABWAHL Stimmen dagegen wird die gemerkte Antwort nicht mehr
   geliefert und die naechste KI-Antwort tritt an ihre Stelle.

Nichts hiervon aendert den genauen Abgleich: Er laeuft zuerst, und eine Stelle der Bibliothek hat immer Vorrang.
"""
from __future__ import annotations

import os
import re
import sqlite3
import unicodedata
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime

from . import wissensbank as wb

# ------------------------------------------------------------------ A. Kontext
KONTEXT_MODES = ("explain", "steps", "ask")
KONTEXT_STELLEN = 2                      # hoechstens so viele Abschnitte je Anfrage
KONTEXT_ZEICHEN = 6000                   # hoechstens so viele Zeichen Auszug je Anfrage (Kosten: rund 1 500 Tokens)
KONTEXT_ZEICHEN_STELLE = 4000            # und je Abschnitt
KONTEXT_ANTEIL = 0.5                     # Anteil der Begriffe der Anfrage, die im Abschnitt stehen (Dateititel bekannt)
KONTEXT_ANTEIL_KURS = 0.65               # ... wenn nur der Kurs passt
KONTEXT_BEGRIFFE = 6                     # mindestens so viele gemeinsame Begriffe

KONTEXT_KOPF = (
    "\n\n=== AUSZÜGE AUS DER STUDINOW-WISSENSBANK (Hilfsmaterial, nicht Teil der Frage) ===\n"
    "Die folgenden Auszüge stammen aus einer Sammlung von Erklärungen und Lösungen zu diesem Kurs. Regeln dafür:\n"
    "- Verwende einen Auszug nur, wenn er wirklich dieselbe Seite bzw. dieselbe Aufgabe behandelt wie die Anfrage oben; "
    "bei Aufgaben müssen die Zahlen und Angaben übereinstimmen. Passt er nicht genau, ignoriere ihn vollständig und "
    "antworte so, als gäbe es ihn nicht.\n"
    "- Prüfe, was du übernimmst (nachrechnen), und antworte im üblichen Stil und Umfang.\n"
    "- Erwähne die Auszüge, ihre Überschriften und Kennungen nicht. Behaupte nie, es gebe eine Musterlösung oder eine "
    "Vorlage.\n")
KONTEXT_FUSS = "=== ENDE DER AUSZÜGE ===\n"

# ------------------------------------------------------------------ B. Merken
MERKEN_MODES = ("explain", "steps")
# Eine gemerkte Antwort kostet so viele Credits (Vorschlag: 1 wie eine Antwort aus der Wissensbank; der geteilte
# Speicher fuer ganze Seiten kostet 0). Entscheidung des Inhabers vor dem Einschalten.
MERKEN_CREDITS = 1
MERKEN_GLEICH = 0.8                      # beidseitiger Anteil gemeinsamer Wortfolgen fuer "derselbe Ausschnitt"
MERKEN_ABWAHL = 2                        # so viele Stimmen dagegen (und mehr als dafuer): nicht mehr ausliefern
PURPOSE_GEMERKT = "tutor:gemerkt"
GEMERKT_HINWEIS = "Gemerkte KI-Antwort"
KEY = "gemerkt:"                         # Schluessel in wissensbank_delivered / wissensbank_feedback: gemerkt:<id>

SCHEMA = """
-- Gemerkte KI-Antworten (21.11.2026): ohne Konto, ohne Frage. `text` ist der normalisierte Text des Ausschnitts
-- (Kursmaterial; die App sichert mit `teilbar` zu, dass nichts Persoenliches darin steckt).
CREATE TABLE IF NOT EXISTS wissensbank_gemerkt (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    titel TEXT NOT NULL,                   -- Dateititel (wissensbank.norm_title)
    kurs TEXT NOT NULL,
    mode TEXT NOT NULL,                    -- explain | steps
    seite INTEGER,
    text TEXT NOT NULL,
    answer TEXT NOT NULL,
    model TEXT,
    kontext INTEGER NOT NULL DEFAULT 0,    -- 1: die Antwort entstand mit Auszuegen aus der Wissensbank
    status TEXT NOT NULL DEFAULT 'ungeprueft',   -- ungeprueft | geprueft | abgelehnt
    votes_fuer INTEGER NOT NULL DEFAULT 0,
    votes_gegen INTEGER NOT NULL DEFAULT 0,
    geliefert INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    reviewed_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_wb_gemerkt_stelle ON wissensbank_gemerkt(titel, kurs, mode, seite);
"""


# ================================================================== Schalter

def kontext_on() -> bool:
    return (os.environ.get("LERNAPP_WISSENSBANK_KONTEXT") or "").strip().lower() in ("1", "true", "on", "ja")


def merken_mode() -> str:
    """aus (Standard) | freigabe (andere bekommen eine gemerkte Antwort erst nach der Freigabe) | sofort"""
    v = (os.environ.get("LERNAPP_WISSENSBANK_MERKEN") or "").strip().lower()
    return v if v in ("freigabe", "sofort") else "aus"


def ensure_schema(conn: sqlite3.Connection) -> None:
    if conn.in_transaction:
        conn.commit()
    conn.executescript(SCHEMA)


def connect() -> sqlite3.Connection:
    from . import accounts, db
    conn = wb.connect()
    db.schema_once(conn, "wissensbank_gemerkt", accounts.db_path(), ensure_schema)
    return conn


# ================================================================== A. Suche und Block

@dataclass
class Fund:
    unit: wb.Unit
    sec: wb.Section
    score: float
    share: float
    hinweis: bool                # Seiten- bzw. Aufgabennummer passt (bei bekanntem Dateititel)
    zahlen: bool                 # die Zahlen der Anfrage stehen im Abschnitt am Stueck

    @property
    def key(self) -> str:
        return f"{self.unit.fach}/{self.unit.uid}/{self.sec.sid}"


def suche(lib: wb.Library, *, datei: str, kurs: str = "", seite: int | None = None, text: str = "",
          stellen: int = KONTEXT_STELLEN) -> list[Fund]:
    """Bestpassende Abschnitte fuer den Kontext, beste zuerst. Lockerer als `wissensbank.match`: Es zaehlen die
    Begriffe (ohne Wortfolge) gegen den ganzen Abschnitt. Fest bleibt:
    - Aufgaben (und Seiten, die Aufgaben nennen): Hat die Anfrage lesbare Zahlen, muessen sie im Abschnitt am Stueck
      stehen - sonst ist es eine andere Fassung (anderes Semester) und der Abschnitt geht nicht mit. Ohne lesbare Zahlen
      geht eine Aufgabe nur mit, wenn Dateititel UND Aufgabennummer passen.
    - Ist nur der Kurs bekannt (Dateititel unbekannt), gilt die hoehere Schwelle KONTEXT_ANTEIL_KURS."""
    toks = wb.tokens(text[:wb.TEXT_MAX])
    words, _big, stream = wb.terms(toks)
    if len(words) < KONTEXT_BEGRIFFE:
        return []
    qh = set(wb._hashes(words))
    qbits = sum(wb.number_bits(t) for t in stream)
    qlabels = wb.labels_in(wb.normalize(text[:wb.TEXT_MAX]), toks)
    title = wb.norm_title(datei)
    by_title = sorted(lib.title_index().get(title, set())) if title else []
    rounds = [(by_title, True)]
    if kurs:
        seen = set(by_title)
        rounds.append(([(f, u) for f in lib.fach_for_course(kurs) for u in lib.by_fach[f] if (f, u) not in seen], False))
    found: dict[int, Fund] = {}
    for units, titled in rounds:
        need = KONTEXT_ANTEIL if titled else KONTEXT_ANTEIL_KURS
        for fach, uid in units:
            unit = lib.unit(fach, uid)
            if unit is None:
                continue
            allowed_q = {s.kurz for s in unit.sources if title in s.titles} if titled else set()
            for sec in unit.sections:
                if allowed_q and None not in allowed_q and sec.q and sec.q not in allowed_q:
                    continue
                at, cand = wb._resolve(lib, unit, sec) if sec.link and not sec.explicit else (unit, sec)
                share, common = wb._share(qh, cand.words)
                if common < KONTEXT_BEGRIFFE or share < need:
                    continue
                hinweis = titled and ((sec.kind == "seite" and bool(seite) and sec.page == seite)
                                      or (sec.kind == "aufgabe" and sec.label is not None and sec.label in qlabels))
                zahlen = False
                if cand.kind == "aufgabe" or cand.tasks:
                    if qbits >= wb.NACHWEIS_ZAHLEN_BITS:
                        block, total = wb.number_block(stream, cand.numseq)
                        zahlen = block >= wb.NACHWEIS_ZAHLEN_BITS and block >= wb.NACHWEIS_ZAHLEN * total
                        if not zahlen:
                            continue
                    elif not hinweis:
                        continue
                score = share + (0.2 if hinweis else 0.0) + (0.2 if zahlen else 0.0)
                old = found.get(id(cand))
                if old is None or score > old.score:
                    found[id(cand)] = Fund(at, cand, score, share, hinweis, zahlen)
        if found:
            break                                    # Treffer ueber den Dateititel: der Kurs wird nicht mehr durchsucht
    return sorted(found.values(), key=lambda f: (-f.score, f.unit.uid, f.sec.sid))[:max(0, stellen)]


_KENNUNG = re.compile(r"\[Q\d+\]\s?|\bG\d{4}\b\s?|`[^`\n]*\.(?:md|py|pdf)`")


def _auszug(unit: wb.Unit, sec: wb.Section, limit: int) -> str:
    """Text eines Abschnitts fuer den Block: wie bei der Auslieferung (ohne Abgleich-Notizen), dazu ohne interne
    Kennungen der Bibliothek ("[Q3]", "G0012", Dateipfade), gekuerzt."""
    text = _KENNUNG.sub("", wb.answer_text(unit, [sec]))
    text = re.sub(r"[ \t]+\n", "\n", text).strip()
    if len(text) > limit:
        text = text[:limit].rsplit("\n", 1)[0].rstrip() + "\n[…gekürzt]"
    return text


@dataclass
class Kontext:
    block: str
    keys: list[str] = field(default_factory=list)


def kontext_block(funde: list[Fund]) -> Kontext | None:
    parts: list[str] = []
    keys: list[str] = []
    left = KONTEXT_ZEICHEN
    for f in funde:
        if left < 400:
            break
        text = _auszug(f.unit, f.sec, min(KONTEXT_ZEICHEN_STELLE, left))
        if not text:
            continue
        parts.append(f"--- Auszug {len(parts) + 1} ---\n{text}\n")
        keys.append(f.key)
        left -= len(text)
    if not parts:
        return None
    return Kontext(KONTEXT_KOPF + "".join(parts) + KONTEXT_FUSS, keys)


# ================================================================== B. Gemerkte Antworten

def _kurs(kurs: str) -> str:
    return " ".join(unicodedata.normalize("NFC", str(kurs or "")).casefold().split())[:400]


def gleich(a: list[str], b: list[str]) -> bool:
    """Praktisch derselbe Ausschnitt: genug Begriffe, beidseitig MERKEN_GLEICH der Wortfolgen gemeinsam und genau
    dieselben Zahlen (jede so oft wie im anderen Text). Zwei Leute kreisen dieselbe Aufgabe leicht verschieden ein; eine
    Zeile mehr mit einer Zahl darin ist schon ein anderer Ausschnitt."""
    if len(wb.terms(a)[0]) < wb.MIN_BEGRIFFE or len(wb.terms(b)[0]) < wb.MIN_BEGRIFFE:
        return False
    qa, qb = wb.shingles(a), wb.shingles(b)
    common = wb._overlap(qa, set(qa), qb)
    if common < wb.MIN_GEMEINSAM or common < MERKEN_GLEICH * len(qa) or common < MERKEN_GLEICH * len(qb):
        return False
    return Counter(t for t in a if t[0].isdigit()) == Counter(t for t in b if t[0].isdigit())


def _abgewaehlt(row) -> bool:
    return int(row["votes_gegen"]) >= MERKEN_ABWAHL and int(row["votes_gegen"]) > int(row["votes_fuer"])


def lieferbar(row, mode: str) -> bool:
    if row["status"] == "abgelehnt" or _abgewaehlt(row):
        return False
    return mode == "sofort" or (mode == "freigabe" and row["status"] == "geprueft")


def finden(conn: sqlite3.Connection, stelle: dict, toks: list[str]) -> list[dict]:
    """Gemerkte Antworten zu dieser Stelle (gleicher Dateititel, Kurs, Modus, Seite) mit praktisch demselben Text,
    neueste zuerst."""
    cur = conn.execute("SELECT id, text, answer, model, kontext, status, votes_fuer, votes_gegen FROM wissensbank_gemerkt "
                       "WHERE titel=? AND kurs=? AND mode=? AND seite IS ? ORDER BY id DESC LIMIT 200",
                       (stelle["titel"], stelle["kurs"], stelle["mode"], stelle["seite"]))
    cols = [d[0] for d in cur.description]
    return [r for r in (dict(zip(cols, row)) for row in cur.fetchall()) if gleich(toks, r["text"].split(" "))]


@dataclass
class KiPlan:
    kontext: Kontext | None = None
    gemerkt: dict | None = None          # diese gemerkte Antwort wird geliefert
    frage_zu: int | None = None          # das Konto hat diese gemerkte Antwort schon bekommen: KI + Ja/Nein-Frage
    merken: dict | None = None           # nach der KI-Antwort unter dieser Stelle merken


def plan(user: dict, task: str, body: dict) -> KiPlan | None:
    """Was ausser dem genauen Abgleich fuer diese Anfrage gilt; None = nichts (Schalter aus, Konto ohne Wissensbank,
    keine Angaben zur Stelle, zweite Meinung). Der Aufrufer fragt nur, wenn `wissensbank.plan` None geliefert hat."""
    if not task.startswith("tutor:") or not wb.enabled():
        return None
    mode = task.split(":", 1)[1]
    wbd = body.get("wissensbank")
    mm = merken_mode()
    if not isinstance(wbd, dict) or body.get("second_opinion") or (mm == "aus" and not kontext_on()):
        return None
    if not wb.allowed_for(user):
        return None
    text = str(wbd.get("text") or "")[:wb.TEXT_MAX]
    datei, kurs = str(wbd.get("datei") or "")[:400], str(wbd.get("kurs") or "")[:400]
    try:
        seite = int(wbd.get("seite")) if wbd.get("seite") not in (None, "") else None
    except (TypeError, ValueError):
        seite = None
    out = KiPlan()
    # B. zuerst: eine gemerkte Antwort erspart die KI
    if mm != "aus" and mode in MERKEN_MODES and wbd.get("teilbar") is True and wb.norm_title(datei):
        toks = wb.tokens(text)
        if len(wb.shingles(toks)) >= wb.MIN_GEMEINSAM and len(wb.terms(toks)[0]) >= wb.MIN_BEGRIFFE:
            stelle = {"titel": wb.norm_title(datei), "kurs": _kurs(kurs), "mode": mode, "seite": seite}
            conn = connect()
            try:
                rows = finden(conn, stelle, toks)
                hit = next((r for r in rows if lieferbar(r, mm)), None)
                if hit is not None:
                    done = conn.execute("SELECT 1 FROM wissensbank_delivered WHERE user_id=? AND wb_key=?",
                                        (str(user["id"]), f"{KEY}{hit['id']}")).fetchone()
                    if done:
                        out.frage_zu = hit["id"]
                    elif not body.get("fresh"):
                        out.gemerkt = hit
                elif not any(r["status"] != "abgelehnt" and not _abgewaehlt(r) for r in rows):
                    # nichts Gemerktes, das noch gilt oder auf die Freigabe wartet: die naechste KI-Antwort merken
                    out.merken = {**stelle, "text": " ".join(toks)}
            finally:
                conn.close()
    # A. Kontext fuer die KI
    if out.gemerkt is None and kontext_on() and mode in KONTEXT_MODES:
        lib = wb.library()
        if lib is not None:
            out.kontext = kontext_block(suche(lib, datei=datei, kurs=kurs, seite=seite, text=text))
    if out.kontext is None and out.gemerkt is None and out.frage_zu is None and out.merken is None:
        return None
    return out


def deliver(user: dict, p: KiPlan, rid: str, now: datetime | None = None):
    """Gemerkte Antwort ausliefern: Rate-Limit wie die KI, MERKEN_CREDITS Credits, Lieferung beim Konto vermerken."""
    from . import ai_backend, credits as ledger
    t = wb._now(now)
    uid = str(user["id"])
    row = p.gemerkt
    ai_backend.connect().close()
    conn = connect()
    try:
        if wb._rate_limited(conn, uid, t):
            raise ai_backend.AIUnavailable("ai_rate_limited", "Zu viele KI-Anfragen in kurzer Zeit. Bitte gleich noch einmal.", 429)
        try:
            held = ledger.reserve(conn, uid, rid, PURPOSE_GEMERKT, max(1, MERKEN_CREDITS), t, model="gemerkt")
        except ledger.CreditsError as e:
            raise ai_backend.AIUnavailable(e.code, e.message, e.status, e.extra)
        if held.replay:
            if held.result is None:
                raise ai_backend.AIUnavailable("duplicate_request", "Diese Anfrage wurde schon verarbeitet.", 409)
            return ai_backend.Completion(held.result, 0, 0, "replay", replay=True)
        charged = ledger.settle(conn, uid, rid, 0, model="gemerkt", result=row["answer"], now=t, fixed_credits=MERKEN_CREDITS)
        conn.execute("INSERT OR REPLACE INTO wissensbank_delivered(user_id, wb_key, request_id, served, delivered_at) VALUES (?,?,?,?,?)",
                     (uid, f"{KEY}{row['id']}", rid, "gemerkt", t.isoformat()))
        conn.execute("UPDATE wissensbank_gemerkt SET geliefert=geliefert+1 WHERE id=?", (row["id"],))
        conn.commit()
    finally:
        conn.close()
    return ai_backend.Completion(row["answer"], 0, 0, "gemerkt", credits_charged=charged, credits_reserved=MERKEN_CREDITS,
                                 provider="gemerkt")


def gemerkt_fields() -> dict:
    return {"source": "gemerkt", "gemerkt": {"hinweis": GEMERKT_HINWEIS}}


def after(user: dict, p: KiPlan, c, now: datetime | None = None) -> dict:
    """Nach der Antwort: zusaetzliche Antwortfelder; eine frische KI-Antwort wird gemerkt bzw. bekommt die Ja/Nein-Frage."""
    if p.gemerkt is not None and getattr(c, "model", "") in ("gemerkt", "replay"):
        return gemerkt_fields()
    out: dict = {}
    if p.kontext is not None:
        out["wissensbank_kontext"] = True
    text = getattr(c, "text", "") or ""
    if getattr(c, "replay", False) or not text.strip():
        return out
    if p.merken is not None:
        t = wb._now(now)
        conn = connect()
        try:
            m = p.merken
            model = getattr(c, "source_model", "") or getattr(c, "model", "") or None
            conn.execute("INSERT INTO wissensbank_gemerkt(titel, kurs, mode, seite, text, answer, model, kontext, created_at) "
                         "VALUES (?,?,?,?,?,?,?,?,?)",
                         (m["titel"], m["kurs"], m["mode"], m["seite"], m["text"], text, model, 1 if p.kontext is not None else 0,
                          t.isoformat()))
            conn.commit()
        finally:
            conn.close()
    if p.frage_zu is not None:
        token = wb.offer_feedback(user, wb.Plan(f"{KEY}{p.frage_zu}", False), c, now)
        if token:
            out["feedback_token"] = token
            out["feedback_question"] = "Gefällt dir diese Antwort besser?"
    return out


def vote(conn: sqlite3.Connection, key: str, better: bool) -> None:
    """Antwort auf "Gefaellt dir diese (frische) Antwort besser?" nach einer gemerkten Antwort: Ja = Stimme gegen die
    gemerkte, Nein = Stimme fuer sie. Laeuft in der Transaktion von `wissensbank.feedback`."""
    try:
        gid = int(key[len(KEY):])
    except ValueError:
        return
    col = "votes_gegen" if better else "votes_fuer"
    conn.execute(f"UPDATE wissensbank_gemerkt SET {col}={col}+1 WHERE id=?", (gid,))


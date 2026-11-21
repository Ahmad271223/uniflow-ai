"""StudiNow-Wissensbank im Dienst (Auftrag des Inhabers 20.11.2026, fuer 1.0.7; docs/WISSENSBANK-STAND.md).

Die private Wissensbibliothek des Inhabers (Seite-fuer-Seite-Erklaerungen und geloeste Aufgaben, Format: MAC-ANLEITUNG.md
im privaten Repo) liegt NUR auf dem Server, in einem Ordner (`LERNAPP_WISSENSBANK_DIR`, Standard `<Daten>/wissensbank`,
im Container /data/wissensbank),
den der Inhaber mit tools/wissensbank-hochladen.sh fuellt. Nichts davon steht in diesem (oeffentlichen) Repository.

Regeln des Inhabers:
- Niemand kann die Wissensbank durchsehen. Ein Pro-AI-Konto der Leibniz Universitaet Hannover (`luh`, Hochschule des
  Kontos) bekommt eine Antwort daraus nur INDIREKT: Es fragt die KI-Hilfe (`tutor:explain` oder `tutor:steps`) zu einer
  Seite bzw. Aufgabe, und der Wortlaut passt zu einer Stelle der Wissensbank. Die Antwort geht nur an diesen Nutzer.
- Zuordnung ueber den INHALT (Nachtrag 20.11.2026): Kandidaten grenzt der Dateititel (`quellen` einer Einheit, tolerant)
  bzw. der Kurs ein, entscheiden tut der Textvergleich (`match`): Folientext (`>`-Zitate, "Folientext", "Aufgabentext" ...)
  gegen den Seitentext bzw. markierten Text der Anfrage, 3-Wort-Shingles, Ueberlappung >= SCHWELLE; bei Aufgaben muessen
  die Zahlenwerte uebereinstimmen. Die Seitennummer ist nur Gleichstand-Entscheider.
- 1 Credit je Wissensbank-Antwort (`tutor:wissensbank` in credit_ledger), Kontingent und Rate-Limit wie die KI.
- Fragt derselbe Nutzer dieselbe Stelle (Einheit + Abschnitt + Modus) noch einmal, bekommt er eine normale KI-Antwort
  (wie immer berechnet) und dazu die Frage "Gefaellt dir diese Antwort besser?" (`feedback_token`).
- "Ja": die KI-Antwort wird als Kandidat (Status ungeprueft, ohne Konto und ohne Frage) zu dieser Stelle gespeichert.
  Nach der Freigabe durch den Inhaber (`python -m app.wissensbank_pruefen`) bekommen andere Nutzer sie, wenn sie die
  Wahl gewinnt (`choose`): Wahl des Inhabers je Stelle, sonst der freigegebene Kandidat mit den meisten Stimmen, wenn er
  mehr hat als die Bibliothek ("Nein" nach einer Bibliotheks-Antwort = Stimme fuer die Bibliothek); sonst die Bibliothek.
- Schalter `LERNAPP_WISSENSBANK=1` (Standard aus). Die App sendet die Angaben zur Stelle nur, wenn der Dienst die Funktion
  in GET /api/entitlements meldet (`wissensbank: true`).
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
import sqlite3
import threading
import unicodedata
from array import array
from collections import OrderedDict
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

from fastapi import APIRouter, Body, HTTPException, Request

from . import config

router = APIRouter(tags=["ai"])

BADGE = "Aus der StudiNow-Wissensbank"
UNIVERSITIES = ("luh",)                  # nur Konten der Leibniz Universitaet Hannover (Vorgabe des Inhabers 20.11.2026)
MODES = {"explain": ("seite", "aufgabe"), "steps": ("aufgabe",)}
PURPOSE = "tutor:wissensbank"
CREDITS = 1
FEEDBACK_DAYS = 7
TEXT_MAX = 20_000                        # so viel Seitentext/markierter Text wird verglichen
SHINGLE = 3                              # Woerter je Shingle
SCHWELLE = 0.6                           # Ueberlappung (|Q∩R| / min(|Q|,|R|)) mit ausdruecklichem Folien-/Aufgabentext
SCHWELLE_OHNE_VORLAGE = 0.75             # ohne ausdruecklichen Text: Anteil der Anfrage, der im Abschnitt steht
KURS_ZUSCHLAG = 0.1                      # Suche ueber alle Einheiten des Kurses (Datei umbenannt): strenger
SEITE_JACCARD = 0.5                      # Folien: Seite und Folientext muessen sich auch insgesamt aehneln (Jaccard)
MIN_GEMEINSAM = 8                        # mindestens so viele gemeinsame Shingles (Titelfolien u. a. treffen nie)
MAX_ABSCHNITTE = 8                       # so viele Aufgaben einer Seite werden hoechstens zusammen geliefert
# Stelle ueber Dateititel und Nummer (21.11.2026, `_anchored`): fuer Abschnitte, deren Wortlaut die Anfrage nicht traegt
# (kein Folien-/Aufgabentext in der Bibliothek oder nur eine Kurzfassung). Werte gemessen an 223 echten Kursdateien.
NACHWEIS_ANTEIL = 0.6                    # Anteil der Begriffe der Anfrage, die im Abschnitt stehen
NACHWEIS_BEGRIFFE = 6                    # mindestens so viele gemeinsame Begriffe
NACHWEIS_ABSTAND = 0.15                  # so viel besser als jeder andere Abschnitt derselben Einheiten
NACHWEIS_ZAHLEN = 0.6                    # Aufgaben: Anteil der Zahlen der Anfrage, die im Abschnitt am Stueck stehen
NACHWEIS_ZAHLEN_BITS = 14.0              # Aufgaben: Gewicht dieser Zahlenfolge (0/1 = 1, Ziffer = 3, sonst 3,3 je Ziffer)
SCHWELLE_AUSSCHNITT = 0.7                # Ausschnitt einer Folie ("Bereich an KI"): Anteil des Ausschnitts im Folientext
MIN_BEGRIFFE = 5                         # jede Anfrage braucht so viele Begriffe (Zahlenreihen allein treffen nie)
AUSSCHNITT_GEMEINSAM = 12                # Ausschnitt einer Folie: mindestens so viele gemeinsame Shingles (keine Kopfzeile)
KURZ_AUFGABE = 25                        # Aufgabe: unter so vielen Shingles (Anfrage oder Aufgabentext) nur mit Nummer
MARKERS = ("KI-Lösung, ungeprüft", "unabhängig gelöst: ja", "nachgerechnet, nicht unabhängig gelöst")
STATUS_TEXT = {"ungeprueft": "ungeprüft", "geprueft": "geprüft", "abgelehnt": "abgelehnt"}


# ================================================================== Einstellungen

def directory() -> Path:
    v = os.environ.get("LERNAPP_WISSENSBANK_DIR")
    return Path(v) if v else config.BASE_DATA_DIR / "wissensbank"


def switched_on() -> bool:
    return (os.environ.get("LERNAPP_WISSENSBANK") or "").strip().lower() in ("1", "true", "on", "ja")


def enabled() -> bool:
    """Schalter an, Dienst, und ein Katalog liegt im Ordner."""
    return switched_on() and config.is_hosted() and (directory() / "katalog.json").is_file()


def allowed_for(user: dict | None) -> bool:
    """Nur Pro AI (auch die Probe, die als Pro AI zaehlt) und nur Konten der LUH - die Hochschule des Kontos zaehlt,
    nie eine Angabe des Clients."""
    if not user or str(user.get("university") or "").lower() not in UNIVERSITIES:
        return False
    from . import entitlements
    return entitlements.plan_of(user) == "pro_ai"


def announce(user: dict | None) -> bool:
    """Feld `wissensbank` in GET /api/entitlements: die App schickt die Angaben zur Stelle nur dann mit."""
    try:
        return enabled() and allowed_for(user)
    except Exception:  # noqa: BLE001 - die Meldung darf den Abo-Stand nie stoeren
        return False


# ================================================================== Text: Normalisieren, Woerter, Shingles

_HYPHEN = re.compile(r"(\w)[-­‐‑]\s*\n\s*(\w)")
_TOKEN = re.compile(r"\d+(?:\.\d+)*|[^\W\d_]+|[=+<>≤≥≠≈∫∑∏√∞∂∇→←↔⇒⇔∈∉⊂⊆∪∩∀∃×·÷^%]")
_DECIMAL = re.compile(r"(?<=\d),(?=\d)")


# Textebene echter PDFs (gemessen am 21.11.2026 mit PDFKit an 740 Kursdateien): LaTeX-Dateien liefern Umlaute getrennt -
# das Trema steht VOR dem Buchstaben, mit Leerzeichen oder Zeilenumbruch dazwischen ("f¨ ur", "Fakult¨at", "¨\nUbungsblatt");
# NFKC macht aus "¨" ein Leerzeichen mit kombinierendem Trema. Selten steht es dahinter ("fu¨r").
_TREMA_BEFORE = re.compile("[ \t]?\u0308[ \t]*\n?[ \t]*([aouAOU])")
_TREMA_AFTER = re.compile("([aouAOU])[ \t]\u0308")
_PRIVATE = re.compile("[\ue000-\uf8ff]")       # Teile grosser Klammern aus Formelschriften (Privatbereich)


def _umlaut(m: re.Match) -> str:
    return unicodedata.normalize("NFC", m.group(1) + "\u0308")


def normalize(text: str) -> str:
    """NFKC (x₁ -> x1, ² -> 2, Ligaturen fi/fl, Formelbuchstaben), getrennte Umlaute zusammensetzen, Silbentrennung am
    Zeilenende zusammenziehen, Kleinschreibung (ß -> ss), Dezimalkomma -> Punkt, Markdown-Zeichen weg. Ziffern und
    Formelzeichen bleiben."""
    t = unicodedata.normalize("NFKC", str(text or ""))
    t = _PRIVATE.sub(" ", t)
    if "\u0308" in t:
        t = _TREMA_AFTER.sub(_umlaut, _TREMA_BEFORE.sub(_umlaut, t))
    t = t.replace("­", "")
    t = _HYPHEN.sub(r"\1\2", t)
    t = t.casefold()
    t = t.replace("−", "-").replace("–", "-")
    t = _DECIMAL.sub(".", t)
    t = re.sub(r"[*_`$\\|#]", " ", t)
    return t


def tokens(text: str) -> list[str]:
    return _TOKEN.findall(normalize(text))


def numbers(toks: list[str]) -> frozenset[str]:
    return frozenset(t for t in toks if t[0].isdigit())


def shingles(toks: list[str], k: int = SHINGLE) -> array:
    if len(toks) < k:
        return array("I")
    return array("I", sorted({hash(tuple(toks[i:i + k])) & 0xFFFFFFFF for i in range(len(toks) - k + 1)}))


def number_shingles(toks: list[str], k: int = SHINGLE) -> dict[int, int]:
    """Shingles mit einer Zahl darin, mit Anzahl: Zahl samt Umgebung ("f = 12", "= 12 kn"). Eine geaenderte Zahl nimmt
    jedem Shingle an ihrer Stelle eine Zaehlung weg, auch wenn dieselbe Zahl oder dieselbe Zahlenfolge anderswo im Text
    vorkommt (eine reine Zahlenmenge oder Shingle-Menge saehe das nicht)."""
    out: dict[int, int] = {}
    for i in range(len(toks) - k + 1):
        if any(t[0].isdigit() for t in toks[i:i + k]):
            h = hash(tuple(toks[i:i + k])) & 0xFFFFFFFF
            out[h] = out.get(h, 0) + 1
    return out


def _missing(need: dict[int, int], have: dict[int, int]) -> int:
    """Wie viele Zaehlungen aus `need` in `have` fehlen (Multimengen)."""
    return sum(max(0, n - have.get(h, 0)) for h, n in need.items())


# Woerter ohne Aussage fuer den Inhaltsnachweis: Funktionswoerter und die ueblichen Wendungen von Aufgabenblaettern
_STOP = frozenset("""
aber alle allen aller alles also auch auf aus bei beim bis bzw dabei dann dass dazu dem den denen der deren des dessen
die dies diese diesem diesen dieser dieses doch dort durch eine einem einen einer eines sich sie sind wird werden wurde
kann kann können soll sollen muss müssen hat haben ist war sein seine ihrer ihre ihren ihrem ihres für gegen gilt
gelten hier hinweis hinweise jede jedem jeden jeder jedes jeweils mehr mit nach nicht noch nur oder ohne sowie über
unter und vom von vor wenn wie wird wobei zwei zwischen zum zur zeigen bestimmen berechnen berechne bestimme geben
gegeben gegebenen gesucht folgende folgenden folgender folgendes aufgabe aufgaben punkte punkt lösung lösungen seite
seiten abbildung beispiel sowie dabei welche welcher welches siehe damit daher somit etwa lassen lässt sei seien
""".split())
_TASK_HEAD = re.compile(r"^[ \t]*[a-zäöü]{0,12}aufgabe[ \t]*([a-z]?[ \t]?\d+(?:[ \t]?[.\-][ \t]?\d+)*)", re.M)
_TASK_WORD = re.compile(r"\baufgabe[ \t]*[a-z]?[ \t]?\d")
_DATE = re.compile(r"\b\d{4}-\d{2}-\d{2}\b|\b\d{1,2}\.[ \t]?\d{1,2}\.[ \t]?(?:19|20)\d{2}\b")
_YEAR = re.compile(r"(19|20)\d\d")


def dates_of(norm: str) -> frozenset:
    """Datumsangaben eines (normalisierten) Texts: "2026-10-13", "4.11.2024". Zwei Fassungen desselben Blatts oder
    Deckblatts unterscheiden sich oft nur darin."""
    return frozenset(re.sub(r"\s", "", m.group(0)) for m in _DATE.finditer(norm))


def labels_in(norm: str, toks: list[str]) -> set[str]:
    """Aufgabennummern, die der angefragte Text nennt: aus den Ueberschriften ("Aufgabe 16", "Aufgabe 1 - 6") und als
    Nummer mit Punkt irgendwo im Text ("16.2 Bestimmen Sie ...")."""
    out = {task_label(m.group(1)) for m in _TASK_HEAD.finditer(norm)}
    out.update(t for t in toks if t[0].isdigit() and "." in t)
    out.discard(None)
    return out


def task_label(raw: str) -> str | None:
    """Aufgabennummer in einer Form: "1.2", "1 - 6" -> "1.6", "H 3" -> "h3" (Eingabe schon klein geschrieben)."""
    t = re.sub(r"\s", "", str(raw or "")).replace("-", ".").strip(".")
    return t or None


def terms(toks: list[str], skip: str | None = None) -> tuple[set[str], set[str], list[str]]:
    """(Begriffe, Zahlen, Zahlen in ihrer Reihenfolge) fuer den Inhaltsnachweis. Begriffe: Woerter ab 4 Buchstaben ohne
    `_STOP`, auf 6 Buchstaben gekuerzt (Intervall, Intervalle, Intervallen sind derselbe Begriff). Zahlen: ab zwei
    Ziffern oder mit Komma; die Reihenfolge enthaelt auch einzelne Ziffern (`P = (4, 7, 9)` -> 4, 7, 9). Nicht gezaehlt:
    Jahreszahlen und Datumsangaben, Punktzahlen ("(60 Punkte)", "(1+2 Punkte)") und die Aufgabennummer `skip`."""
    words: set[str] = set()
    nums: set[str] = set()
    stream: list[str] = []
    label = toks.index(skip) if skip and skip in toks else -1     # die Aufgabennummer selbst (erstes Vorkommen)
    points: set[int] = set()
    for i, t in enumerate(toks):
        if t.startswith("punkt"):
            j = i - 1
            while j >= 0 and j != label and (toks[j][0].isdigit() or toks[j] == "+") and i - j <= 5:
                points.add(j)
                j -= 1
    for i, t in enumerate(toks):
        if t[0].isdigit():
            if i == label or i in points or t.count(".") >= 2 or _YEAR.fullmatch(t):
                continue
            stream.append(t)
            if len(t) >= 2:
                nums.add(t)
        elif len(t) >= 4 and t.isalpha() and t not in _STOP:
            words.add(t[:6])
    return words, nums, stream


def number_bits(tok: str) -> float:
    """Gewicht einer Zahl fuer den Zahlennachweis: 0 und 1 sagen wenig (Wahrheitstafeln), mehrstellige Zahlen viel."""
    digits = tok.replace(".", "")
    return 1.0 if tok in ("0", "1") else 3.0 if len(digits) == 1 else 3.3 * len(digits)


def number_block(stream: list[str], seq: array) -> tuple[float, float]:
    """(Gewicht der laengsten Zahlenfolge der Anfrage, die im Abschnitt AM STUECK steht; Gewicht aller Zahlen der
    Anfrage). `P = (4, 7, 9), Q = (3, 8, 5)` steht in der Loesung derselben Aufgabe wieder so da; dieselbe Aufgabe mit
    anderen Zahlen (anderes Semester) hat keine lange gemeinsame Folge."""
    stream = stream[:150]
    bits = [number_bits(t) for t in stream]
    total = sum(bits)
    if not stream or not len(seq):
        return 0.0, total
    q = [hash(t) & 0xFFFFFFFF for t in stream]
    where: dict[int, list[int]] = {}
    for j, h in enumerate(seq):
        where.setdefault(h, []).append(j)
    best = 0.0
    prev: dict[int, float] = {}                   # Ende der Folge im Abschnitt -> Gewicht der Folge bis hier
    for i, h in enumerate(q):
        cur: dict[int, float] = {}
        for j in where.get(h, ()):
            cur[j] = prev.get(j - 1, 0.0) + bits[i]
            if cur[j] > best:
                best = cur[j]
        prev = cur
    return best, total


def _hashes(items) -> array:
    return array("I", sorted({hash(x) & 0xFFFFFFFF for x in items}))


def norm_title(name: str) -> str:
    """Dateititel tolerant: NFC, Kleinschreibung, ohne Endung, ohne Leerraum und Satzzeichen."""
    t = unicodedata.normalize("NFC", str(name or "")).strip().casefold()
    t = t.rsplit("/", 1)[-1]
    t = re.sub(r"\.(pdf|pptx?|docx?|xlsx?|zip|txt|md|png|jpe?g)$", "", t)
    return re.sub(r"[\W_]+", "", t)


# ================================================================== Bibliothek lesen

def front_matter(text: str) -> tuple[dict, str]:
    """Einfacher, toleranter Kopfblock (`---` ... `---`): `schluessel: wert`, Listen mit `- ...`, Listen von Abbildungen
    (`- kurz: Q1` + eingerueckte Felder) und `{kurz: Q2, titel: ...}`. Unbekanntes bleibt Text."""
    if not text.startswith("---"):
        return {}, text
    end = re.search(r"\n---[ \t]*(\n|$)", text[3:])
    if not end:
        return {}, text
    raw, body = text[3:3 + end.start()], text[3 + end.end():]
    out: dict = {}
    key = None
    item: dict | None = None
    for line in raw.split("\n"):
        if not line.strip():
            continue
        m = re.match(r"^([A-Za-z_äöüÄÖÜß][\w\-äöüÄÖÜß]*):\s*(.*)$", line)
        if m and not line[0].isspace():
            key, val = m.group(1), m.group(2).strip()
            item = None
            out[key] = _scalar(val) if val else []
            continue
        if key is None:
            continue
        s = line.strip()
        if s.startswith("- "):
            v = s[2:].strip()
            if not isinstance(out.get(key), list):
                out[key] = [out[key]] if out.get(key) else []
            if v.startswith("{") and v.endswith("}"):
                item = _inline_map(v[1:-1])
                out[key].append(item)
            elif re.match(r"^(kurz|titel|pfad|seiten)\s*:", v):
                item = {}
                k, _, rest = v.partition(":")
                item[k.strip()] = _scalar(rest.strip())
                out[key].append(item)
            else:
                item = None
                out[key].append(_scalar(v))
        elif item is not None and ":" in s:
            k, _, rest = s.partition(":")
            item[k.strip()] = _scalar(rest.strip())
    return out, body


def _scalar(v: str):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        return v[1:-1]
    return v


def _inline_map(s: str) -> dict:
    out = {}
    for part in re.findall(r'(\w+)\s*:\s*("[^"]*"|\'[^\']*\'|[^,]+)', s):
        out[part[0]] = _scalar(part[1])
    return out


@dataclass
class Source:
    kurz: str | None
    titles: frozenset[str]


def sources_of(quellen) -> list[Source]:
    """`quellen` -> (Kurzname Q1..., moegliche Titel). Die Eintraege sind Freitext in vielen Formen
    ("[Q1] titel.pdf, Seiten 1-8 (...)", "Q2: .../datei.pdf (6 Seiten)", {kurz, titel, pfad, seiten})."""
    if isinstance(quellen, (str, dict)):
        quellen = [quellen]
    out: list[Source] = []
    for q in quellen or []:
        titles: set[str] = set()
        kurz = None
        if isinstance(q, dict):
            kurz = str(q.get("kurz") or "") or None
            for v in (q.get("titel"), q.get("pfad")):
                if v:
                    titles.add(norm_title(str(v)))
        else:
            s = str(q)
            m = re.search(r"\[(Q\d+)\]", s) or re.match(r"\s*(Q\d+)\s*[:(]", s) or re.search(r"\((Q\d+)[,)]", s)
            kurz = m.group(1) if m else None
            s2 = re.sub(r"^\s*(\[Q\d+\]|Q\d+\s*(\([^)]*\))?\s*:)\s*", "", s)
            s2 = re.sub(r"^\.\.\./", "", s2)
            for ext in re.finditer(r"[^,()\[\]]*?\.(pdf|pptx?|docx?|zip)\b", s2, re.I):
                titles.add(norm_title(ext.group(0).strip()))
            head = re.split(r",\s|\s\(", s2, maxsplit=1)[0]
            titles.add(norm_title(head))
        titles.discard("")
        if titles:
            out.append(Source(kurz, frozenset(titles)))
    return out


_REF_LABEL = re.compile(r"^\s*(?:\*{1,2}(Folientext|Folieninhalt|Aufgabentext|Aufgabenstellung|Aufgabe\b|Vorlage|Text der Seite|"
                        r"Seitentext|Seite \d+[^*]*?(Folieninhalt|Aufgabentext|Folientext))[^*]*\*{0,2}[.:]?"
                        r"|(?:Aufgabentext|Aufgabenstellung|Folientext)[ \t]*:)\s*", re.I)
_LINK = re.compile(r"(?:identisch mit|entspricht|Erklärung (?:in|dort:?))\s+(?:komplett\s+)?(G\d{4})\b[^\n→]{0,40}?"
                   r"(?:\[?(Q\d+)\]?\s*)?(?:Seite|S\.|Folie)\s*(\d+)", re.I)


@dataclass
class Section:
    sid: str                     # Datei#Abschnitt (in der Einheit eindeutig)
    datei: str
    index: int                   # Nummer des Abschnitts in der Datei (0 = erster "## ")
    title: str
    kind: str                    # seite | aufgabe
    q: str | None
    page: int | None
    explicit: bool               # ausdruecklicher Folien-/Aufgabentext vorhanden
    sh: array
    nums: frozenset
    numsh: dict                  # Shingles mit Zahl und Anzahl (nur mit ausdruecklichem Text)
    link: tuple | None           # (Einheit, Q, Seite) bei "identisch mit G00xx Seite N"
    body_len: int
    label: str | None = None     # Aufgabennummer ("1.2"), nur bei Aufgaben
    words: array = field(default_factory=lambda: array("I"))   # Begriffe des ganzen Abschnitts (`terms`, gehasht)
    bignums: frozenset = frozenset()                            # Zahlen des ganzen Abschnitts (`terms`)
    numseq: array = field(default_factory=lambda: array("I"))   # Zahlen des ganzen Abschnitts in ihrer Reihenfolge (gehasht)
    tasks: bool = False          # der Abschnitt nennt Aufgaben ("Aufgabe 2 ..."): Blatt, Klausur, Mitschrift einer Uebung
    dates: frozenset = frozenset()                              # Datumsangaben des ganzen Abschnitts (`dates_of`)


@dataclass
class Unit:
    fach: str
    uid: str
    path: Path
    titel: str
    sources: list[Source]
    sections: list[Section] = field(default_factory=list)
    fm: dict = field(default_factory=dict)          # Kopfdaten je Datei (nur fuer Hinweise)


def _heading(h: str) -> tuple[str, str | None, int | None, str] | None:
    """`[Q1] Seite 3: ...` / `[Q2] Aufgabe 1.2 a): ...` / `1.1, Seite 1: ...` -> (Art, Q, Seite, Kurzname)."""
    m = re.match(r"\s*\[(Q\d+)\]\s*", h)
    q = m.group(1) if m else None
    rest = h[m.end():] if m else h
    page_m = re.search(r"\b(?:Seiten?|Folien?|S\.)\s*(\d+)", rest)
    page = int(page_m.group(1)) if page_m else None
    if re.match(r"\s*Aufgaben?\b", rest):
        label = re.split(r":", rest, maxsplit=1)[0].strip()
        return "aufgabe", q, page, label
    if page is not None and (q or re.match(r"\s*[\d.]+,\s*Seite", rest) or re.match(r"\s*Seite", rest)):
        return "seite", q, page, f"Seite {page}"
    return None


def _reference(body: str) -> str:
    """Folien- bzw. Aufgabentext eines Abschnitts: `>`-Zitate und Absaetze mit Kennzeichnung ("Folientext",
    "Aufgabentext", "Aufgabe.", "Vorlage (woertlich)" ...). Leer, wenn es keinen gibt."""
    quotes = [ln.lstrip()[1:].strip() for ln in body.split("\n") if ln.lstrip().startswith(">")]
    paras = []
    for p in re.split(r"\n\s*\n", body):
        m = _REF_LABEL.match(p)
        if m:
            rest = p[m.end():]
            if rest.strip() and not rest.lstrip().startswith(">"):
                # nur bis "Loesung"/"Erklaerung", falls im selben Absatz
                rest = re.split(r"\*\*(Lösung|Erklärung|Kurzlösung|Abgleich)", rest)[0]
                paras.append(rest)
    return "\n".join(quotes + paras).strip()


def _sections(text: str) -> list[tuple[str, str]]:
    parts = re.split(r"^## (?!#)", text, flags=re.M)
    return [(p.split("\n", 1)[0].strip(), p.split("\n", 1)[1] if "\n" in p else "") for p in parts[1:]]


def parse_unit(fach: str, entry: dict, root: Path) -> Unit:
    path = root / str(entry.get("pfad") or "")
    unit = Unit(fach, str(entry.get("id") or ""), path, str(entry.get("titel") or ""), [])
    files = [d for d in entry.get("dateien") or [] if str(d).endswith(".md") and str(d) != "README.md"
             and re.match(r"0[12]-", str(d))]
    seen: set[str] = set()
    srcs: list[Source] = []
    for d in files:
        p = path / d
        try:
            text = p.read_text(encoding="utf-8")
        except OSError:
            continue
        fm, body = front_matter(text)
        unit.fm[d] = {k: v for k, v in fm.items() if k in ("loesung_von", "typ", "abgleich")}
        srcs.extend(sources_of(fm.get("quellen")))
        for i, (h, b) in enumerate(_sections(body)):
            parsed = _heading(h)
            if not parsed:
                continue
            kind, q, page, label = parsed
            if d.startswith("02") and kind == "seite":
                kind = "aufgabe" if re.search(r"Aufgabe", h) else "seite"
            ref = _reference(b)
            explicit = len(tokens(ref)) >= 12
            toks = tokens(ref if explicit else b)
            lm = _LINK.search(b) if len(b) < 1500 else None
            sid = f"{d[:2]}#{q or 'Q'}-{re.sub(r'[^0-9A-Za-zÄÖÜäöüß]+', '-', label).strip('-')}"
            n, base = 2, sid
            while sid in seen:
                sid, n = f"{base}-{n}", n + 1
            seen.add(sid)
            lab = _TASK_HEAD.search(normalize(label)) if kind == "aufgabe" else None
            whole = tokens(h + "\n" + b)
            words, bignums, stream = terms(whole)
            whole_norm = normalize(h + "\n" + b)
            tasky = kind == "aufgabe" or bool(_TASK_WORD.search(whole_norm))
            unit.sections.append(Section(sid, d, i, h, kind, q, page, explicit, shingles(toks), numbers(toks),
                                         number_shingles(toks) if explicit else {},
                                         (lm.group(1), lm.group(2), int(lm.group(3))) if lm else None, len(b),
                                         task_label(lab.group(1)) if lab else None, _hashes(words), frozenset(bignums),
                                         array("I", [hash(t) & 0xFFFFFFFF for t in stream]), tasky, dates_of(whole_norm)))
    # Quellen: Kopf der Dateien, sonst README (Tabelle "Quelle Q1 | titel ...")
    if not srcs:
        try:
            fm, _ = front_matter((path / "README.md").read_text(encoding="utf-8"))
            srcs = sources_of(fm.get("quellen"))
        except OSError:
            pass
    merged: dict = {}
    for s in srcs:
        merged.setdefault(s.kurz, set()).update(s.titles)
    unit.sources = [Source(k, frozenset(v)) for k, v in merged.items()]
    return unit


class Library:
    """Katalog im Speicher; Einheiten werden beim ersten Bedarf gelesen (LRU), Antworttexte bei der Auslieferung."""

    UNIT_CACHE = 400

    def __init__(self, root: Path):
        self.root = root
        self.katalog = json.loads((root / "katalog.json").read_text(encoding="utf-8"))
        self.stand = str(self.katalog.get("stand") or "")
        self.entries: dict[tuple[str, str], dict] = {}
        self.by_fach: dict[str, list[str]] = {}
        for f in self.katalog.get("faecher") or []:
            fach = str(f.get("ordner") or "")
            for e in f.get("einheiten") or []:
                uid = str(e.get("id") or "")
                if fach and uid:
                    self.entries[(fach, uid)] = e
                    self.by_fach.setdefault(fach, []).append(uid)
        self._units: OrderedDict = OrderedDict()
        self._title_index: dict[str, set] | None = None
        self._lock = threading.Lock()

    def unit(self, fach: str, uid: str) -> Unit | None:
        k = (fach, uid)
        with self._lock:
            u = self._units.get(k)
            if u is not None:
                self._units.move_to_end(k)
                return u
        e = self.entries.get(k)
        if e is None:
            return None
        u = parse_unit(fach, e, self.root)
        with self._lock:
            self._units[k] = u
            while len(self._units) > self.UNIT_CACHE:
                self._units.popitem(last=False)
        return u

    def title_index(self) -> dict[str, set]:
        """Dateititel -> {(Fach, Einheit)}; einmal ueber alle Kopfdaten (nur die Quellen, nicht die Abschnitte)."""
        if self._title_index is None:
            idx: dict[str, set] = {}
            for (fach, uid), e in self.entries.items():
                path = self.root / str(e.get("pfad") or "")
                for d in [x for x in e.get("dateien") or [] if str(x).endswith(".md")]:
                    try:
                        with open(path / d, encoding="utf-8") as fh:
                            head = fh.read(6000)
                    except OSError:
                        continue
                    fm, _ = front_matter(head)
                    for s in sources_of(fm.get("quellen")):
                        for t in s.titles:
                            idx.setdefault(t, set()).add((fach, uid))
            self._title_index = idx
        return self._title_index

    def fach_for_course(self, course: str) -> list[str]:
        """Faecher, deren Name ganz im Kurstitel steht (Woerter, NFC, ohne Bindestriche); eine roemische Zahl im Kurstitel,
        die das Fach nicht hat, schliesst es aus ("Mathematik ... I" ist nicht "Mathematik ... II")."""
        def words(s: str) -> set[str]:
            return set(re.findall(r"[^\W_]+", unicodedata.normalize("NFC", s or "").replace("-", " ").casefold()))
        roman = {"i", "ii", "iii", "iv", "v", "vi"}
        cw = words(course)
        out = []
        for fach in self.by_fach:
            fw = words(fach)
            if fw and fw <= cw and not ((cw & roman) - fw):
                out.append(fach)
        return out


_LIB: dict = {}
_LIB_LOCK = threading.Lock()


def library() -> Library | None:
    """Bibliothek des Ordners; neu gelesen, sobald katalog.json sich aendert (Upload des Inhabers)."""
    root = directory()
    try:
        st = (root / "katalog.json").stat()
    except OSError:
        return None
    ident = (str(root), st.st_ino, st.st_mtime_ns, st.st_size)
    with _LIB_LOCK:
        if _LIB.get("ident") != ident:
            try:
                _LIB["lib"] = Library(root)
            except (OSError, ValueError):
                return None
            _LIB["ident"] = ident
        return _LIB["lib"]


# ================================================================== Zuordnung ueber den Wortlaut

@dataclass
class Hit:
    unit: Unit
    sections: list[Section]
    score: float
    jaccard: float
    key: str


def _overlap(q: array, qset: set, r: array) -> int:
    if len(r) <= len(q):
        return sum(1 for h in r if h in qset)
    rset = set(r)
    return sum(1 for h in q if h in rset)


def score(q: array, qset: set, qnums: frozenset, sec: Section, *, strict: float = 0.0,
          qnumsh: dict | None = None, partial: bool = False) -> tuple[float, float] | None:
    """(Ueberlappung, Jaccard) oder None, wenn der Abschnitt nicht passt.

    Mit Folien-/Aufgabentext: |Q∩R| / min(|Q|, |R|) >= SCHWELLE (ganze Seite gegen Folie oder markierte Aufgabe gegen
    Aufgabentext). Ohne: Anteil der Anfrage im Abschnitt >= SCHWELLE_OHNE_VORLAGE. Immer mindestens MIN_GEMEINSAM
    gemeinsame Shingles. Zahlen (mit ausdruecklichem Text): Ist die Anfrage der kleinere Teil, muss jede Zahl der Anfrage
    mit ihren Nachbarwoertern im Abschnitt stehen, sonst jede Zahl des Abschnitts in der Anfrage - bei Aufgaben ohne
    Ausnahme, bei Folien darf jede zehnte fehlen (z. B. eine Fusszeile). Ohne ausdruecklichen Text: alle Zahlen der
    Anfrage kommen im Abschnitt vor.

    `partial` (Ausschnitt einer Folie, "Bereich an KI"): Die Anfrage ist nur ein Teil der Folie. Dann zaehlt, dass
    SCHWELLE_AUSSCHNITT des Ausschnitts im Folientext steht; die Aehnlichkeit zur ganzen Folie (Jaccard) entfaellt.
    Dass genau eine Stelle passt, prueft `match`."""
    if not len(q) or not len(sec.sh):
        return None
    common = _overlap(q, qset, sec.sh)
    if common < MIN_GEMEINSAM:
        return None
    small = min(len(q), len(sec.sh))
    part = partial and sec.kind == "seite" and sec.explicit
    if part:
        ov = common / len(q)
        need = SCHWELLE_AUSSCHNITT + strict
    elif sec.explicit:
        ov = common / small
        need = SCHWELLE + strict
    else:
        ov = common / len(q)
        need = SCHWELLE_OHNE_VORLAGE + strict
    if ov < need:
        return None
    qnumsh = qnumsh or {}
    if not sec.explicit:
        missing, allowed = len(qnums - sec.nums), 0
    else:
        need, have = (qnumsh, sec.numsh) if len(q) <= len(sec.sh) else (sec.numsh, qnumsh)
        missing = _missing(need, have)
        allowed = 0 if sec.kind == "aufgabe" else sum(need.values()) // 10
    if missing > allowed:
        return None
    jac = common / (len(q) + len(sec.sh) - common)
    if sec.kind == "seite" and sec.explicit and jac < SEITE_JACCARD and not part:
        return None
    return ov, jac


def _resolve(lib: Library, unit: Unit, sec: Section, depth: int = 0) -> tuple[Unit, Section]:
    """"identisch mit G00xx Seite N -> Erklaerung dort": die Stelle, auf die verwiesen wird (gleiches Fach)."""
    if not sec.link or depth >= 3:
        return unit, sec
    uid, q, page = sec.link
    target = lib.unit(unit.fach, uid)
    if target is None:
        return unit, sec
    for s in target.sections:
        if s.kind == "seite" and s.page == page and (q is None or s.q in (q, None)) and s.datei[:2] == sec.datei[:2]:
            if s is sec:
                return unit, sec
            return _resolve(lib, target, s, depth + 1)
    return unit, sec


def key_of(mode: str, unit: Unit, secs: list[Section]) -> str:
    return f"{mode}:{unit.fach}/{unit.uid}/" + "+".join(s.sid for s in secs)


def match(lib: Library, *, mode: str, datei: str, kurs: str = "", seite: int | None = None, text: str = "",
          ausschnitt: bool = False) -> Hit | None:
    """Beste Stelle der Wissensbank fuer die Anfrage, oder None. Erst Einheiten, deren `quellen` den Dateititel nennen
    (Wortlaut, sonst `_anchored`: Dateititel + Nummer + Inhaltsnachweis); ohne Treffer alle Einheiten des Kurses (nur
    Wortlaut, strenger).

    `ausschnitt`: Der Text ist nur ein Teil der Seite ("Bereich an KI": erkannter Text eines eingekreisten Ausschnitts).
    Fuer Folien gilt dann das Enthaltensein (`score(partial=True)`) und es muss genau eine Stelle passen; passen mehrere,
    entscheidet die mitgeschickte PDF-Seite, sonst gibt es keinen Treffer."""
    kinds = MODES.get(mode)
    if not kinds or not text.strip():
        return None
    toks = tokens(text[:TEXT_MAX])
    q = shingles(toks)
    if len(q) < MIN_GEMEINSAM:
        return None
    qset, qnums, qnumsh = set(q), numbers(toks), number_shingles(toks)
    _qwords, _qbig, qstream = terms(toks)
    if len(_qwords) < MIN_BEGRIFFE:
        # nur Zahlen oder Formelzeichen (Wahrheitstafel, Zahlenreihe, einzelne Formel): Die drei-Wort-Folgen aus 0 und 1
        # stehen in jeder Tabelle - so ein Text belegt keine Stelle
        return None
    qbits = sum(number_bits(t) for t in qstream)
    qlabels = labels_in(normalize(text[:TEXT_MAX]), toks)
    title = norm_title(datei)
    by_title = sorted(lib.title_index().get(title, set())) if title else []
    rounds = [(by_title, 0.0, True)]
    if kurs:
        rest = [(f, u) for f in lib.fach_for_course(kurs) for u in lib.by_fach[f] if (f, u) not in set(by_title)]
        rounds.append((rest, KURS_ZUSCHLAG, False))
    for units, strict, titled in rounds:
        found: list[tuple[float, float, int, Unit, Section]] = []
        for fach, uid in units:
            unit = lib.unit(fach, uid)
            if unit is None:
                continue
            allowed_q = {s.kurz for s in unit.sources if title in s.titles} if titled else set()
            for sec in unit.sections:
                if sec.kind not in kinds:
                    continue
                if allowed_q and None not in allowed_q and sec.q and sec.q not in allowed_q:
                    continue
                at, cand = unit, sec
                if sec.link and not sec.explicit:
                    # "identisch mit G00xx Seite N": verglichen und geliefert wird die Stelle, auf die verwiesen wird
                    at, cand = _resolve(lib, unit, sec)
                r = score(q, qset, qnums, cand, strict=strict, qnumsh=qnumsh, partial=ausschnitt)
                if r and cand.kind == "aufgabe" and min(len(q), len(cand.sh)) < KURZ_AUFGABE and cand.label not in qlabels:
                    # ein kurzer Satz ("Bestimmen Sie die Impulsantwort. Ist das System kausal?") steht in vielen Aufgaben
                    # mit verschiedenen Loesungen: nur, wenn der angefragte Text die Nummer dieser Aufgabe nennt
                    r = None
                if r and cand.kind == "aufgabe" and not titled and qbits < NACHWEIS_ZAHLEN_BITS:
                    # Dateititel unbekannt (nur der Kurs passt): eine Aufgabe ohne Zahlen im Text ("... fuer das gegebene
                    # Gatter ...") kann jedes Jahr eine andere sein - nur mit Zahlen, die dann genau stimmen muessen
                    r = None
                if r and ausschnitt and cand.kind == "seite" and _overlap(q, qset, cand.sh) < AUSSCHNITT_GEMEINSAM:
                    # zwei Zeilen Kopf oder Titel belegen keine Folie (gemessen: Kopf einer Folie traf die fast gleich
                    # ueberschriebene Folie eines anderen Studiengangs)
                    r = None
                if r:
                    dist = abs((sec.page or 0) - seite) if (seite and sec.page) else 9999
                    found.append((r[0], r[1], dist, at, cand))
        if ausschnitt:
            pages = {id(f[4]): f for f in found if f[4].kind == "seite"}
            if len(pages) > 1:
                # derselbe Ausschnitt steht auf mehreren Folien (Aufbaustufen, Gliederung): nur die mitgeschickte Seite
                exact = {id(f[4]) for f in pages.values() if f[2] == 0 and titled}
                keep = exact if len(exact) == 1 else set()
                found = [f for f in found if f[4].kind != "seite" or id(f[4]) in keep]
        if not found:
            # der Wortlaut traegt nicht (kein Folien-/Aufgabentext in der Bibliothek, Formeln, Kurzfassung): Stelle ueber
            # Dateititel und Seite bzw. Aufgabennummer, Inhalt ueber die Begriffe - nur mit bekanntem Dateititel
            hit = _anchored(lib, units, title, mode, kinds, seite, text[:TEXT_MAX]) if titled else None
            if hit is not None:
                return hit
            continue
        # Folie/Seite vor Aufgabe beim Erklaeren; dann Jaccard (Animationsstufen), dann Naehe der Seitennummer
        pref = {k: i for i, k in enumerate(kinds)}
        found.sort(key=lambda f: (pref[f[4].kind], -round(f[1], 3), f[2]))
        best = found[0]
        unit, sec = best[3], best[4]
        secs = [sec]
        if sec.kind == "aufgabe":
            # mehrere Aufgaben derselben Seite/Einheit: alle Treffer in Dokumentreihenfolge
            same = [f[4] for f in found if f[3] is unit and f[4].kind == "aufgabe"]
            secs = sorted({id(s): s for s in same}.values(), key=lambda s: (s.datei, s.index))[:MAX_ABSCHNITTE]
        if len(secs) == 1:
            unit, s0 = _resolve(lib, unit, sec)
            secs = [s0]
        return Hit(unit, secs, best[0], best[1], key_of(mode, unit, secs))
    return None


# ---------------------------------------------------------------- Stelle ueber Dateititel und Nummer (21.11.2026)
# Gemessen an den echten Kursdateien (PDFKit-Text, Vision-Text eingekreister Aufgaben): Der Wortlaut allein trifft selten,
# weil die Bibliothek zu vielen Aufgaben nur die Loesung hat (kein Aufgabentext) oder die Vorlage in eigenen Worten
# zusammenfasst, und weil Formeln in der Textebene anders aussehen. Sicher bleibt es so:
#   1. Der Dateititel nennt die Einheit und die Quelle (wie bisher, `quellen`).
#   2. Die Stelle ist eindeutig benannt: Seitennummer bzw. Aufgabennummer aus der Ueberschrift im angefragten Text.
#   3. Inhaltsnachweis: mindestens NACHWEIS_BEGRIFFE Begriffe und NACHWEIS_ANTEIL der Begriffe der Anfrage stehen im
#      Abschnitt, jede groessere Zahl der Anfrage ebenfalls, und kein anderer Abschnitt derselben Einheiten passt
#      annaehernd so gut (NACHWEIS_ABSTAND). Steht derselbe Titel in mehreren Einheiten (Semestern), entscheidet der
#      Inhalt; ohne klaren Sieger gibt es keinen Treffer.
# Gleicher Dateiname mit anderem Inhalt, andere Aufgabe unter derselben Nummer, verschobene Nummern: kein Treffer.

def _share(qwords: set, words: array) -> tuple[float, int]:
    common = sum(1 for h in words if h in qwords)
    return common / len(qwords), common


def _anchored(lib: Library, units: list, title: str, mode: str, kinds: tuple, seite: int | None, text: str) -> Hit | None:
    pool: list[tuple[Unit, Section, Unit, Section]] = []      # (Einheit, Abschnitt, geliefert wird: Einheit, Abschnitt)
    for fach, uid in units:
        unit = lib.unit(fach, uid)
        if unit is None:
            continue
        allowed_q = {s.kurz for s in unit.sources if title in s.titles}
        for sec in unit.sections:
            if sec.kind not in kinds or (allowed_q and None not in allowed_q and sec.q and sec.q not in allowed_q):
                continue
            at, cand = _resolve(lib, unit, sec) if sec.link and not sec.explicit else (unit, sec)
            pool.append((unit, sec, at, cand))
    for kind in kinds:
        found = _anchored_page(pool, seite, text) if kind == "seite" else _anchored_tasks(pool, text)
        if found:
            unit, secs, share = found
            return Hit(unit, secs, share, 0.0, key_of(mode, unit, secs))
    return None


def _accept(share: float, common: int, other: float) -> bool:
    return share >= NACHWEIS_ANTEIL and common >= NACHWEIS_BEGRIFFE and share - other >= NACHWEIS_ABSTAND


def _anchored_page(pool: list, seite: int | None, text: str):
    """Seite `seite` der Datei: der Abschnitt mit dieser Seitennummer, wenn die Begriffe der Seite dazu passen.
    Nur fuer Folien und Skripte: Nennt die Anfrage oder der Abschnitt eine Aufgabe ("Aufgabe 2 ..."), gilt dieser Weg
    nicht - Klausuren und Blaetter gleichen sich von Jahr zu Jahr im Wortlaut und unterscheiden sich nur in den Zahlen
    (gemessen: derselbe Dateiname in mehreren Jahren); dafuer gibt es `_anchored_tasks` mit Zahlennachweis."""
    if not seite or _TASK_WORD.search(normalize(text)):
        return None
    qw, qn, _stream = terms(tokens(text))
    qh = set(_hashes(qw))
    if len(qh) < NACHWEIS_BEGRIFFE:
        return None
    here: list[tuple[float, int, Unit, Section]] = []
    other = 0.0
    for _unit, sec, at, cand in pool:
        if sec.kind != "seite" or cand.tasks:
            continue
        share, common = _share(qh, cand.words)
        if sec.page == seite:
            here.append((share, common, at, cand))
        else:
            other = max(other, share)
    if not here:
        return None
    here.sort(key=lambda x: -x[0])
    share, common, at, cand = here[0]
    rivals = [x[0] for x in here[1:] if x[3] is not cand]      # dieselbe Seitennummer in einer anderen Einheit (Semester)
    other = max([other] + rivals)
    if qn - cand.bignums or not _accept(share, common, other):
        return None
    qd = dates_of(normalize(text))
    if qd and cand.dates and not (qd & cand.dates):
        return None                                             # anderes Datum: andere Fassung (Deckblatt, Kopf)
    return at, [cand], share


def _anchored_tasks(pool: list, text: str):
    """Aufgaben mit Ueberschrift im angefragten Text ("Aufgabe 1.2 ..."): je Aufgabe der Abschnitt mit dieser Nummer,
    wenn die Begriffe des Aufgabentexts (bis zur naechsten Ueberschrift) dazu passen UND die Zahlen der Aufgabe dort am
    Stueck in derselben Reihenfolge stehen (`number_block`). Ohne Zahlen in der Anfrage gibt es hier keinen Treffer: Die
    Texterkennung laesst Zahlen und Formeln oft weg, und gleiche Aufgaben mit anderen Zahlen (anderes Semester, gemessen
    an den Kurzklausuren mehrerer Jahre) haben dieselben Begriffe."""
    norm = normalize(text)
    heads = list(_TASK_HEAD.finditer(norm))
    tasks = [x for x in pool if x[1].kind == "aufgabe"]
    if not heads or not tasks:
        return None
    chosen: list[tuple[float, Unit, list[Section]]] = []
    qdates = dates_of(norm)
    for i, m in enumerate(heads[:2 * MAX_ABSCHNITTE]):
        label = task_label(m.group(1))
        seg = norm[m.start():heads[i + 1].start() if i + 1 < len(heads) else len(norm)]
        qw, qn, stream = terms(tokens(seg), skip=label)
        qh = set(_hashes(qw))
        if len(qh) < NACHWEIS_BEGRIFFE or sum(number_bits(t) for t in stream) < NACHWEIS_ZAHLEN_BITS:
            continue                                            # zu wenig Text oder zu wenige Zahlen zum Nachpruefen
        groups: dict[tuple, list[tuple[Unit, Section]]] = {}   # je Einheit und Quelle: die Abschnitte mit dieser Nummer
        other = 0.0
        for unit, sec, at, cand in tasks:
            if sec.label == label:
                groups.setdefault((unit.fach, unit.uid, sec.q), []).append((at, cand))
            else:
                other = max(other, _share(qh, cand.words)[0])
        scored = []
        for members in groups.values():
            words = {h for _at, c in members for h in c.words}
            common = sum(1 for h in words if h in qh)
            nums = frozenset().union(*(c.bignums for _at, c in members))
            numbers_ok = not (qn - nums)
            dates = frozenset().union(*(c.dates for _at, c in members))
            if qdates and dates and not (qdates & dates):
                numbers_ok = False                              # anderes Datum: anderes Semester
            if numbers_ok:
                block, total = max(number_block(stream, c.numseq) for _at, c in members)
                numbers_ok = block >= NACHWEIS_ZAHLEN_BITS and block >= NACHWEIS_ZAHLEN * total
            scored.append((common / len(qh), common, numbers_ok, members))
        # dieselbe Nummer in mehreren Einheiten (gleicher Dateiname in mehreren Semestern): Es zaehlen nur die, deren
        # Zahlen zur Anfrage passen. Stimmen die Zahlen in zweien, ist es dieselbe Aufgabe; dann die mit mehr Begriffen.
        scored = [x for x in scored if x[2]]
        if not scored:
            continue
        scored.sort(key=lambda x: -x[0])
        share, common, _ok, members = scored[0]
        if _accept(share, common, other):
            chosen.append((share, members[0][0], [c for at, c in members if at is members[0][0]]))
    if not chosen:
        return None
    chosen.sort(key=lambda x: -x[0])
    unit = chosen[0][1]
    secs = {id(c): c for _share_, at, cs in chosen if at is unit for c in cs}
    return unit, sorted(secs.values(), key=lambda c: (c.datei, c.index))[:MAX_ABSCHNITTE], chosen[0][0]


# ================================================================== Antworttext und Hinweise

_HEAD_LINE = re.compile(r"^(#{1,6})\s+(.*)$")
_ABGLEICH_HEAD = re.compile(r"(?:\[Q\d+\]\s*)?[*_]{0,3}Abgleich")
_FENCE = re.compile(r"^\s*(```|~~~)")
_LIST_ITEM = re.compile(r"^([ \t]*)(?:[-*+]|\d+[.)])[ \t]+")
_LINE_PREFIX = re.compile(r"[ \t]*(?:>[ \t]*)*(?:(?:[-*+]|\d+[.)])[ \t]+)?")     # Einrueckung, Zitat, Listenzeichen
# "Abgleich" als Marke einer Notiz: fett/kursiv ("**Abgleich mit der Musterlösung.**", "*Abgleich [Q7]:*") oder ohne
# Auszeichnung am Satzanfang ("... **F < 0**. Abgleich: gleich."); nicht "Abgleichsvermerk", nicht "der Abgleich"
_ABGLEICH_WORD = re.compile(r"[*_]{0,3}Abgleich(?![a-zäöüß])")
_SENTENCE_END = re.compile(r"[.!?;□✓)\]`*][ \t\n]+(?:>[ \t]*)*$")
# naechste Marke nach einer Notiz: "**Lösung (nachgerechnet).**", "**Kernergebnis.**", "*Erklärung:*" - hier geht der
# eigene Text weiter. Fette Ergebnisse ("**F = 3 kN**") und "**[sic]**" sind keine Marken.
_LABEL = re.compile(r"(?<![*_\w])(\*{1,3}|_{1,3})(?!Abgleich)[A-ZÄÖÜ][a-zäöüß][^*_\n=]{0,80}?(?:[.:]\1|\1[.:])(?![*_\w])")


def _abgleich_start(text: str, pos: int) -> tuple[int, int] | None:
    """Naechste Abgleich-Marke ab `pos`: (Beginn des Wegfalls, Ende der Marke). Steht die Marke am Zeilenanfang, faellt
    die Zeile ab ihrem Anfang weg (mit Zitat- und Listenzeichen)."""
    for m in _ABGLEICH_WORD.finditer(text, pos):
        i = m.start()
        before = text[:i]
        line_from = before.rfind("\n") + 1
        prefix = _LINE_PREFIX.fullmatch(before[line_from:])
        at_line_start = prefix is not None and line_from >= pos
        if m.group(0)[0] in "*_":
            ok = at_line_start or before[-1:] in (" ", "\t", "(", "")
        else:
            first = not before[:line_from].strip()                       # erste Zeile des Absatzes bzw. Listenpunkts
            listed = prefix is not None and bool(_LIST_ITEM.match(before[line_from:] + "x"))
            ok = (at_line_start and (first or listed)) or bool(_SENTENCE_END.search(before))
        if ok:
            return (line_from if at_line_start else i), m.end()
    return None


def _cut_notes(text: str, open_note: bool = False) -> tuple[str, bool]:
    """Abgleich-Notizen aus einem Absatz bzw. Listenpunkt nehmen: jede reicht von ihrer Marke bis zur naechsten anderen
    Marke (`_LABEL`), sonst bis zum Ende. Liefert den Rest und ob die letzte Notiz am Ende noch offen ist."""
    kept: list[str] = []
    pos = 0
    if open_note:
        nxt = _LABEL.search(text)
        if not nxt:
            return "", True
        pos = nxt.start()
    while True:
        cut = _abgleich_start(text, pos)
        if cut is None:
            kept.append(text[pos:])
            return "".join(kept), False
        kept.append(text[pos:cut[0]].rstrip(" \t"))
        nxt = _LABEL.search(text, cut[1])
        if not nxt:
            return "".join(kept), True
        if kept[-1] and not kept[-1].endswith("\n"):
            kept.append(" ")
        pos = nxt.start()


def _paragraph_without_abgleich(lines: list[str]) -> list[str]:
    """Ein Absatz (Zeilen ohne Leerzeile). Listenpunkte werden einzeln behandelt: eine Notiz in einem Punkt endet mit
    ihm; eine Notiz im Fliesstext nimmt die Punkte darunter mit ("**Abgleich.**" und darunter die Liste dazu)."""
    if lines and lines[0].lstrip().startswith("|"):
        return lines                                                     # Tabellen bleiben ganz
    chunks: list[tuple[int | None, list[str]]] = []
    for line in lines:
        item = _LIST_ITEM.match(line)
        if item or not chunks:
            chunks.append((len(item.group(1)) if item else None, [line]))
        else:
            chunks[-1][1].append(line)
    out: list[str] = []
    open_at: int | None = None        # -1: Notiz im Fliesstext offen, >= 0: im Listenpunkt mit dieser Einrueckung
    for indent, chunk in chunks:
        if open_at is not None and open_at >= 0 and indent is not None and indent <= open_at:
            open_at = None                                               # naechster Punkt derselben Ebene: Notiz zu Ende
        text, still = _cut_notes("\n".join(chunk), open_note=open_at is not None)
        if still and open_at is None:
            open_at = indent if indent is not None else -1
        elif not still:
            open_at = None
        if text.strip():
            out.extend(ln for ln in text.split("\n") if ln.strip())
    return out


def without_abgleich(body: str) -> str:
    """Interne Abgleich-Notizen aus einem Abschnitt nehmen (Entscheidung des Inhabers 21.11.2026: keine Musterloesungen
    der Lehrenden herausgeben, nur die eigene Erklaerung und Loesung). Der Abgleich ist die Pruefnotiz der Bibliothek:
    Vergleich der eigenen Loesung mit der Loesung der Lehrenden, teils mit deren Wortlaut. Entfernt werden
    - eine Notiz, die mit der Marke "Abgleich" beginnt - fett oder kursiv ("**Abgleich mit der Musterlösung.** ...",
      "*Abgleich [Q7]:* ...") oder ohne Auszeichnung am Satzanfang ("Abgleich: gleich."): von der Marke bis zur naechsten
      Leerzeile bzw. bis zur naechsten anderen Marke im selben Absatz ("**Lösung.**", "**Kernergebnis.**");
    - ein Listenpunkt, der so beginnt (die uebrigen Punkte bleiben);
    - eine Unterueberschrift "### Abgleich ..." (bis "######") mit ihrem Inhalt bis zur naechsten Ueberschrift gleicher
      oder hoeherer Ebene.
    Der Rest bleibt, wie er ist (Code-Bloecke und Tabellen unberuehrt). Bleibt danach nichts Eigenes (nur das Zitat der
    Vorlage), ist das Ergebnis leer. Nur fuer den AUSGELIEFERTEN Text; die Zuordnung (`match`) und die Hinweise (`hints`)
    lesen weiter den ganzen Abschnitt."""
    out: list[str] = []
    para: list[str] = []
    skip_level = 0                 # > 0: Unterabschnitt "### Abgleich" wird uebersprungen
    in_code = False
    removed = False

    def flush() -> None:
        nonlocal removed
        if para:
            kept = _paragraph_without_abgleich(para)
            removed = removed or kept != para
            out.extend(kept)
            para.clear()

    for line in str(body or "").split("\n"):
        fence = bool(_FENCE.match(line))
        head = None if in_code or fence else _HEAD_LINE.match(line)
        if skip_level:
            if head and len(head.group(1)) <= skip_level:
                skip_level = 0
            else:
                if fence:
                    in_code = not in_code
                continue
        if head:
            flush()
            if len(head.group(1)) >= 3 and _ABGLEICH_HEAD.match(head.group(2)):
                skip_level = len(head.group(1))
                removed = True
                continue
            out.append(line)
        elif fence or in_code:
            flush()
            if fence:
                in_code = not in_code
            out.append(line)
        elif not line.strip():
            flush()
            out.append(line)
        else:
            para.append(line)
    flush()
    text = re.sub(r"\n{3,}", "\n\n", "\n".join(out)).strip()
    if removed and not _has_own_content(text):
        return ""                  # nur noch die Vorlage (Zitat, Aufgabentext) oder eine Trennlinie: nichts Eigenes mehr
    return text


def _has_own_content(text: str) -> bool:
    """Steht ausser der Vorlage (`>`-Zitat, "**Aufgabentext.** ...") und Ueberschriften noch etwas Eigenes da?"""
    for p in re.split(r"\n\s*\n", text):
        rest = "\n".join(ln for ln in p.split("\n") if not ln.lstrip().startswith(">") and not _HEAD_LINE.match(ln))
        m = _REF_LABEL.match(rest)
        if m:
            nxt = _LABEL.search(rest, m.end())           # "**Aufgabentext.** ... **Lösung.** ..." im selben Absatz
            rest = rest[nxt.start():] if nxt else ""
        if re.search(r"\w", rest):
            return True
    return False


def _own_part(body: str) -> str:
    """Abschnitt bis zur naechsten Ueberschrift der obersten Ebene ("# [Q5] ..." leitet den naechsten Teil der Datei ein
    und gehoert nicht mehr zum Abschnitt); Zeilen in Code-Bloecken zaehlen nicht."""
    lines = body.split("\n")
    in_code = False
    for i, line in enumerate(lines):
        if _FENCE.match(line):
            in_code = not in_code
        elif not in_code and line.startswith("# "):
            return "\n".join(lines[:i])
    return body


def answer_text(unit: Unit, secs: list[Section], *, raw: bool = False) -> str:
    """Ausgelieferter Text: die Abschnitte ohne interne Abgleich-Notizen (`without_abgleich`). Ein Abschnitt, von dem
    danach nichts uebrig ist, faellt weg; bleibt gar nichts, ist die Stelle nicht lieferbar (dann antwortet die KI).
    `raw`: der ganze Abschnitt, wie er in der Bibliothek steht (nur fuer `hints`, wird nie ausgeliefert)."""
    parts = []
    for sec in secs:
        try:
            text = (unit.path / sec.datei).read_text(encoding="utf-8")
        except OSError:
            continue
        _, body = front_matter(text)
        found = _sections(body)
        if sec.index >= len(found):
            continue
        h, b = found[sec.index]
        h = re.sub(r"^\s*\[Q\d+\]\s*", "", h)
        b = b.strip() if raw else without_abgleich(_own_part(b))
        if not b:
            continue
        parts.append(f"## {h}\n\n{b}")
    return "\n\n".join(parts).strip()


def hints(unit: Unit, secs: list[Section], text: str) -> list[str]:
    out = [m for m in MARKERS if m in text]
    for sec in secs:
        lv = str((unit.fm.get(sec.datei) or {}).get("loesung_von") or "")
        if lv.startswith("KI") and sec.datei.startswith("02") and "KI-Lösung, ungeprüft" not in out and "KI-Lösung" not in out:
            out.append("KI-Lösung")
    return out


# ================================================================== Datenbank (accounts.db)

SCHEMA = """
CREATE TABLE IF NOT EXISTS wissensbank_delivered (
    user_id TEXT NOT NULL,
    wb_key TEXT NOT NULL,                  -- Modus:Fach/Einheit/Abschnitt(e)
    request_id TEXT,
    served TEXT,                           -- bibliothek | kandidat:<id>
    delivered_at TEXT NOT NULL,
    PRIMARY KEY (user_id, wb_key)
);
CREATE INDEX IF NOT EXISTS idx_wb_delivered_rid ON wissensbank_delivered(user_id, request_id);
CREATE INDEX IF NOT EXISTS idx_wb_delivered_time ON wissensbank_delivered(user_id, delivered_at);
-- Zweite Antworten ("Gefaellt dir diese Antwort besser?" -> Ja): ohne Konto, ohne Frage
CREATE TABLE IF NOT EXISTS wissensbank_candidates (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    wb_key TEXT NOT NULL,
    answer TEXT NOT NULL,
    answer_hash TEXT NOT NULL,
    model TEXT,
    created_at TEXT NOT NULL,
    votes_yes INTEGER NOT NULL DEFAULT 1,
    status TEXT NOT NULL DEFAULT 'ungeprueft',   -- ungeprueft | geprueft | abgelehnt
    reviewed_at TEXT,
    UNIQUE (wb_key, answer_hash)
);
-- offene Ja/Nein-Fragen: nach der Antwort oder nach FEEDBACK_DAYS geloescht
CREATE TABLE IF NOT EXISTS wissensbank_feedback (
    token TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    wb_key TEXT NOT NULL,
    answer TEXT NOT NULL,
    model TEXT,
    served TEXT,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_wb_feedback_time ON wissensbank_feedback(created_at);
-- je Stelle: Wahl des Inhabers (bibliothek | <Kandidat-ID>) und Stimmen fuer die Bibliothek ("Nein" nach ihr)
CREATE TABLE IF NOT EXISTS wissensbank_keys (
    wb_key TEXT PRIMARY KEY,
    choice TEXT,
    library_votes INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT
);
"""


def ensure_schema(conn: sqlite3.Connection) -> None:
    if conn.in_transaction:
        conn.commit()
    conn.executescript(SCHEMA)


def connect() -> sqlite3.Connection:
    from . import accounts, billing, db
    conn = billing.connect()
    db.schema_once(conn, "wissensbank", accounts.db_path(), ensure_schema)
    return conn


def _now(now: datetime | None = None) -> datetime:
    return now or datetime.now(timezone.utc)


def choose(conn: sqlite3.Connection, key: str) -> dict | None:
    """Welche Antwort eine Stelle bekommt: None = Bibliothek, sonst die Zeile des freigegebenen Kandidaten.
    1. Wahl des Inhabers (`--waehlen`), 2. der freigegebene Kandidat mit den meisten Stimmen, wenn er mehr Stimmen hat als
    die Bibliothek, 3. die Bibliothek."""
    k = conn.execute("SELECT choice, library_votes FROM wissensbank_keys WHERE wb_key=?", (key,)).fetchone()
    choice, lib_votes = (k[0], int(k[1] or 0)) if k else (None, 0)
    if choice == "bibliothek":
        return None
    if choice and str(choice).isdigit():
        r = conn.execute("SELECT id, answer, model, votes_yes FROM wissensbank_candidates WHERE id=? AND wb_key=? AND status='geprueft'",
                         (int(choice), key)).fetchone()
        if r:
            return {"id": r[0], "answer": r[1], "model": r[2], "votes_yes": r[3]}
    r = conn.execute("SELECT id, answer, model, votes_yes FROM wissensbank_candidates WHERE wb_key=? AND status='geprueft' "
                     "ORDER BY votes_yes DESC, id ASC LIMIT 1", (key,)).fetchone()
    if r and int(r[3]) > lib_votes:
        return {"id": r[0], "answer": r[1], "model": r[2], "votes_yes": r[3]}
    return None


# ================================================================== Ablauf im Relay

@dataclass
class Plan:
    """Ergebnis der Vorpruefung einer Anfrage: Treffer, Schluessel, ob ausgeliefert wird (erstes Mal) oder die KI
    antwortet (Wiederholung, dann mit Ja/Nein-Frage)."""
    key: str
    deliver: bool
    text: str = ""
    hints: list = field(default_factory=list)
    served: str = "bibliothek"
    status: str = ""


def plan(user: dict, task: str, body: dict) -> Plan | None:
    """None, wenn die Wissensbank fuer diese Anfrage nicht in Frage kommt (Schalter, Tarif, Hochschule, Modus,
    zweite Meinung, keine Angaben zur Stelle, kein Treffer)."""
    if not task.startswith("tutor:") or not enabled():
        return None
    mode = task.split(":", 1)[1]
    wb = body.get("wissensbank")
    # Mit Bild ("Bereich an KI") seit 21.11.2026 erlaubt: Die App schickt dann nur den im Ausschnitt erkannten Text als
    # Angabe zur Stelle (nie den Text der ganzen Seite); passt er, kommt die Antwort aus der Wissensbank, sonst die KI
    # mit dem Bild wie bisher.
    if mode not in MODES or not isinstance(wb, dict) or body.get("second_opinion"):
        return None
    if not allowed_for(user):
        return None
    lib = library()
    if lib is None:
        return None
    try:
        seite = int(wb.get("seite")) if wb.get("seite") not in (None, "") else None
    except (TypeError, ValueError):
        seite = None
    # Ausschnitt ("Bereich an KI"): die App schickt dann ein Bild mit und als Text nur den im Ausschnitt erkannten Text;
    # ein ausdrueckliches Feld `ausschnitt` (kuenftige App, auch fuer markierten Text) geht vor
    part = wb.get("ausschnitt") if isinstance(wb.get("ausschnitt"), bool) else bool(body.get("image"))
    hit = match(lib, mode=mode, datei=str(wb.get("datei") or "")[:400], kurs=str(wb.get("kurs") or "")[:400], seite=seite,
                text=str(wb.get("text") or "")[:TEXT_MAX], ausschnitt=part)
    if hit is None:
        return None
    conn = connect()
    try:
        _expire_feedback(conn)
        done = conn.execute("SELECT 1 FROM wissensbank_delivered WHERE user_id=? AND wb_key=?", (str(user["id"]), hit.key)).fetchone()
        if done or body.get("fresh"):
            # Wiederholung: normale KI und die Frage; "Neu erklaeren" ohne vorherige Lieferung: normale KI ohne Frage
            return Plan(hit.key, False) if done else None
        cand = choose(conn, hit.key)
    finally:
        conn.close()
    if cand:
        return Plan(hit.key, True, cand["answer"], [], f"kandidat:{cand['id']}", "geprüft")
    text = answer_text(hit.unit, hit.sections)
    if not text:
        return None
    # Hinweise ("KI-Lösung, ungeprüft" ...) aus dem ganzen Abschnitt: sie stehen teils in der Abgleich-Notiz
    return Plan(hit.key, True, text, hints(hit.unit, hit.sections, answer_text(hit.unit, hit.sections, raw=True)),
                "bibliothek", "")


def _expire_feedback(conn: sqlite3.Connection, now: datetime | None = None) -> None:
    """Offene Ja/Nein-Fragen (mit Konto und KI-Antwort) nach FEEDBACK_DAYS loeschen."""
    conn.execute("DELETE FROM wissensbank_feedback WHERE created_at<?", ((_now(now) - timedelta(days=FEEDBACK_DAYS)).isoformat(),))
    conn.commit()


def _rate_limited(conn: sqlite3.Connection, user_id: str, t: datetime) -> bool:
    from . import ai_backend
    n_min = conn.execute("SELECT COUNT(*) FROM wissensbank_delivered WHERE user_id=? AND delivered_at>?",
                         (user_id, (t - timedelta(seconds=60)).isoformat())).fetchone()[0]
    n_hour = conn.execute("SELECT COUNT(*) FROM wissensbank_delivered WHERE user_id=? AND delivered_at>?",
                          (user_id, (t - timedelta(hours=1)).isoformat())).fetchone()[0]
    try:
        n_min += conn.execute("SELECT COUNT(*) FROM ai_usage_log WHERE user_id=? AND created_at>?",
                              (user_id, (t - timedelta(seconds=60)).isoformat())).fetchone()[0]
        n_hour += conn.execute("SELECT COUNT(*) FROM ai_usage_log WHERE user_id=? AND created_at>?",
                               (user_id, (t - timedelta(hours=1)).isoformat())).fetchone()[0]
    except sqlite3.OperationalError:
        pass
    return n_min >= ai_backend.rate_per_minute() or n_hour >= ai_backend.rate_per_hour()


def deliver(user: dict, p: Plan, rid: str, now: datetime | None = None):
    """Wissensbank-Antwort ausliefern: Rate-Limit wie die KI, 1 Credit (reserve + settle mit fester Zahl), Lieferung
    vermerken. Liefert eine ai_backend.Completion (model "wissensbank"); Fehler als ai_backend.AIUnavailable."""
    from . import ai_backend, credits as ledger
    t = _now(now)
    uid = str(user["id"])
    ai_backend.connect().close()                     # Tabellen der KI (ai_usage_log, credit_ledger) sicher angelegt
    conn = connect()
    try:
        if _rate_limited(conn, uid, t):
            raise ai_backend.AIUnavailable("ai_rate_limited", "Zu viele KI-Anfragen in kurzer Zeit. Bitte gleich noch einmal.", 429)
        try:
            held = ledger.reserve(conn, uid, rid, PURPOSE, CREDITS, t, model="wissensbank")
        except ledger.CreditsError as e:
            raise ai_backend.AIUnavailable(e.code, e.message, e.status, e.extra)
        if held.replay:
            if held.result is None:
                raise ai_backend.AIUnavailable("duplicate_request", "Diese Anfrage wurde schon verarbeitet.", 409)
            return ai_backend.Completion(held.result, 0, 0, "replay", replay=True)
        charged = ledger.settle(conn, uid, rid, 0, model="wissensbank", result=p.text, now=t, fixed_credits=CREDITS)
        conn.execute("INSERT OR REPLACE INTO wissensbank_delivered(user_id, wb_key, request_id, served, delivered_at) VALUES (?,?,?,?,?)",
                     (uid, p.key, rid, p.served, t.isoformat()))
        conn.commit()
    finally:
        conn.close()
    return ai_backend.Completion(p.text, 0, 0, "wissensbank", credits_charged=charged, credits_reserved=CREDITS, provider="wissensbank")


def offer_feedback(user: dict, p: Plan, c, now: datetime | None = None) -> str | None:
    """Nach einer KI-Antwort auf eine schon gelieferte Stelle: Einmal-Kennung fuer "Gefaellt dir diese Antwort besser?".
    Haelt die Antwort hoechstens FEEDBACK_DAYS (fuer den Kandidaten bei "Ja"); keine Frage, kein Prompt."""
    text = getattr(c, "text", "") or ""
    if not text.strip() or getattr(c, "replay", False):
        return None
    t = _now(now)
    token = secrets.token_urlsafe(24)
    conn = connect()
    try:
        conn.execute("DELETE FROM wissensbank_feedback WHERE created_at<?", ((t - timedelta(days=FEEDBACK_DAYS)).isoformat(),))
        served = conn.execute("SELECT served FROM wissensbank_delivered WHERE user_id=? AND wb_key=?",
                              (str(user["id"]), p.key)).fetchone()
        model = getattr(c, "source_model", "") or getattr(c, "model", "") or None
        conn.execute("INSERT INTO wissensbank_feedback(token, user_id, wb_key, answer, model, served, created_at) VALUES (?,?,?,?,?,?,?)",
                     (token, str(user["id"]), p.key, text, model, served[0] if served else None, t.isoformat()))
        conn.commit()
    finally:
        conn.close()
    return token


def feedback(user: dict, token: str, better: bool, now: datetime | None = None) -> dict:
    """Antwort auf die Ja/Nein-Frage. "Ja": KI-Antwort als Kandidat (ungeprueft, ohne Konto) oder eine Stimme mehr fuer
    denselben Text. "Nein": eine Stimme fuer das, was der Nutzer vorher aus der Wissensbank bekommen hatte."""
    t = _now(now)
    conn = connect()
    try:
        conn.execute("BEGIN IMMEDIATE")
        row = conn.execute("SELECT wb_key, answer, model, served, created_at FROM wissensbank_feedback WHERE token=? AND user_id=?",
                           (token, str(user["id"]))).fetchone()
        if not row:
            conn.execute("COMMIT")
            raise HTTPException(404, {"detail": "Diese Frage gibt es nicht mehr.", "code": "feedback_unknown"})
        conn.execute("DELETE FROM wissensbank_feedback WHERE token=?", (token,))
        key, answer, model, served, created = row
        if created < (t - timedelta(days=FEEDBACK_DAYS)).isoformat():
            conn.execute("COMMIT")
            raise HTTPException(410, {"detail": "Diese Frage ist abgelaufen.", "code": "feedback_expired"})
        stored = False
        if better:
            h = hashlib.sha256(answer.encode()).hexdigest()
            cur = conn.execute("UPDATE wissensbank_candidates SET votes_yes=votes_yes+1 WHERE wb_key=? AND answer_hash=?", (key, h))
            if cur.rowcount == 0:
                conn.execute("INSERT INTO wissensbank_candidates(wb_key, answer, answer_hash, model, created_at) VALUES (?,?,?,?,?)",
                             (key, answer, h, model, t.isoformat()))
            stored = True
        elif served and served.startswith("kandidat:"):
            conn.execute("UPDATE wissensbank_candidates SET votes_yes=votes_yes+1 WHERE id=? AND wb_key=?", (int(served.split(":", 1)[1]), key))
        else:
            conn.execute("INSERT INTO wissensbank_keys(wb_key, library_votes, updated_at) VALUES (?,1,?) "
                         "ON CONFLICT(wb_key) DO UPDATE SET library_votes=library_votes+1, updated_at=excluded.updated_at", (key, t.isoformat()))
        conn.execute("COMMIT")
    except Exception:
        if conn.in_transaction:
            conn.execute("ROLLBACK")
        raise
    finally:
        conn.close()
    return {"ok": True, "stored": stored}


def replay_info(user: dict, rid: str) -> dict | None:
    """Felder einer schon gelieferten Wissensbank-Antwort fuer dieselbe request_id (Wiederholung nach Netzfehler)."""
    if not enabled():
        return None
    conn = connect()
    try:
        r = conn.execute("SELECT wb_key, served FROM wissensbank_delivered WHERE user_id=? AND request_id=?", (str(user["id"]), rid)).fetchone()
    finally:
        conn.close()
    if not r:
        return None
    return {"source": "wissensbank", "wissensbank_key": r[0],
            "wissensbank": {"badge": BADGE, "status": "geprüft" if str(r[1] or "").startswith("kandidat:") else "", "hinweise": []}}


def response_fields(p: Plan | None, *, delivered: bool, token: str | None) -> dict:
    """Zusaetzliche Felder der Relay-Antwort (alte Apps lesen sie nicht)."""
    if p is None:
        return {"source": "ki"} if enabled() else {}
    if delivered:
        return {"source": "wissensbank", "wissensbank_key": p.key,
                "wissensbank": {"badge": BADGE, "status": p.status, "hinweise": p.hints}}
    out = {"source": "ki", "wissensbank_key": p.key}
    if token:
        out["feedback_token"] = token
        out["feedback_question"] = "Gefällt dir diese Antwort besser?"
    return out


# ================================================================== POST /api/ai/feedback

@router.post("/api/ai/feedback")
def post_feedback(request: Request, body: dict = Body(...)):
    """{token, better: bool} -> {ok, stored}. Nur im Dienst, nur der Nutzer, der die Frage bekommen hat."""
    if not config.is_hosted():
        raise HTTPException(501, {"detail": "Diese Schnittstelle gibt es nur im StudiNow-Dienst.", "code": "not_hosted"})
    user = getattr(request.state, "user", None)
    if not user:
        raise HTTPException(401, {"detail": "Anmeldung erforderlich.", "code": "unauthenticated"})
    token = body.get("token")
    better = body.get("better")
    if not isinstance(token, str) or not token or len(token) > 100 or not isinstance(better, bool):
        raise HTTPException(400, {"detail": "token und better (ja/nein) fehlen.", "code": "feedback_invalid"})
    if not allowed_for(user):
        raise HTTPException(404, {"detail": "Diese Frage gibt es nicht mehr.", "code": "feedback_unknown"})
    return feedback(user, token, better)

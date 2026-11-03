"""Schwarzes Brett aus Stud.IP (Auftrag des Inhabers 03.11.2026: "Schwarzes Brett mit einbinden, wenn eine Uni das hat").
Python-Fassung des Swift-Kerns (StudIPBulletin.swift), gleiche Regeln, gleiche Antworten der Endpunkte.

Die LUH betreibt das Plugin "SchwarzesBrettPlugin" (Kleinanzeigen in Themen wie Biete, Suche, Jobs an der Uni ...). Die
JSON:API kennt das Brett nicht; das Plugin liefert aber je Thema einen RSS-Feed
(plugins.php/schwarzesbrettplugin/rss/{thema}/{anzahl}) und die Themenliste als Seite (.../category/list). Beides
verlangt die angemeldete Sitzung (ohne Cookie: Umleitung auf dispatch.php/login), darum laeuft der Abruf ueber die
angemeldete Browsersitzung des Abgleichs (app/studip_sync.py), nur GET, mit Pausen.

Gespeichert werden je Thema die neuesten PER_TOPIC Anzeigen: Titel, ganzer Text (Absaetze bleiben; MAX_TEXT ist nur eine
Notbremse), Link, Zeitpunkt. Der Feed nennt keine Autoren, es werden keine gespeichert (nie Personennamen). Nur lokal:
im gehosteten Dienst wird nichts abgerufen, gespeichert oder gezeigt; nicht in der Community, keine Quelle der KI.

Hochschulen: BOARD_UNIVERSITIES sagt, ob das Brett erwartet wird (LUH ja, Hildesheim nein). Dazu die Laufzeit-Erkennung
wie bei den uebrigen Ergaenzungen (app/studip_extras.py): fehlt das Plugin (404/403 oder keine Themenliste), merkt sich
das der Abgleich unter `studip_missing_endpoints` ("bulletin") und fragt erst nach studip_extras.RETRY_DAYS wieder.
Mit Plugin: hoechstens alle MIN_HOURS Stunden, dann eine Anfrage fuer die Themen und eine je Thema.

Vertrag mit dem Swift-Kern: packages/shared-contracts/fixtures/studip-bulletin (tools/gen-studip-bulletin-fixture.py).
"""
from __future__ import annotations

import html as _html
import json
import re
import time
from datetime import date, datetime, timedelta
from html.parser import HTMLParser
from zoneinfo import ZoneInfo

from . import announcements, config, studip_extras, studip_texts

PER_TOPIC = 20
MAX_TEXT = 50000                 # nur Notbremse: der RSS-Text ist die ganze Anzeige und bleibt ganz (nie "…")
MISSING_NAME = "bulletin"        # Name in studip_missing_endpoints
MIN_HOURS = 6                    # zwischen zwei Abrufen mindestens so viele Stunden
NEW_DAYS = 7                     # "neu" fuer die Uebersicht
PLUGIN = "plugins.php/schwarzesbrettplugin"
TOPICS_KEY = "studip_bulletin_topics"
FETCHED_KEY = "studip_bulletin_fetched_at"
TOPICS_MARKER = "sb-categories"  # Themenliste in der Seite des Plugins: <ul class="sb-categories">
BOARD_UNIVERSITIES = ("luh",)    # Hochschulen mit dem Plugin (Swift: UniversityProfile.hasBulletinBoard)
PAUSE_SECONDS = 0.25             # zwischen zwei Seitenaufrufen (wie der Client des Swift-Kerns)
BERLIN = ZoneInfo("Europe/Berlin")

TABLE = """CREATE TABLE IF NOT EXISTS studip_bulletin (
    id TEXT PRIMARY KEY,
    topic TEXT NOT NULL,               -- Thema (Titel in Stud.IP)
    title TEXT NOT NULL,
    text TEXT NOT NULL,                -- ganzer Text ohne Formatierung (Absaetze bleiben)
    url TEXT,                          -- Anzeige in Stud.IP
    posted_at TEXT,                    -- YYYY-MM-DDTHH:MM:SS, Ortszeit
    fetched_at TEXT
)"""


class SessionExpired(Exception):
    """Statt der Seite kam die Anmeldung: die Sitzung ist abgelaufen (kein fehlendes Plugin)."""


# ----------------------------------------------------------------------------
# Adressen
# ----------------------------------------------------------------------------

def list_path() -> str:
    return "/" + PLUGIN + "/category/list"


def feed_path(topic_id: str) -> str:
    return f"/{PLUGIN}/rss/{topic_id}/{PER_TOPIC}"


def board_url(base: str) -> str:
    """Startseite des Bretts in Stud.IP (Leser, Karte)"""
    return base.rstrip("/") + list_path()


# ----------------------------------------------------------------------------
# Lesen der Themenliste (HTML)
# ----------------------------------------------------------------------------

_TOPIC_HREF = re.compile(r"/category/(?:view/)?([0-9a-f]{32})(?:[/?#]|$)")
# erste "(N)" im Linktext; danach kann ein Hinweistext des Themas folgen ("Umfragen (5) Umfragen und Befragungen"), der
# nicht zum Titel gehoert
_TOPIC_COUNT = re.compile(r"\(([\d.  ]+)\)")
_ANY_SPACE = re.compile(r"\s+")


class _TopicParser(HTMLParser):
    """Links `<a href=".../category/view/{id}">Titel (Anzahl)</a>` innerhalb `<ul class="sb-categories">`."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.topics: list[dict] = []
        self._seen: set[str] = set()
        self._in_list = False
        self._depth = 0
        self._current: tuple[str, list[str]] | None = None

    def handle_starttag(self, tag, attrs):
        a = dict((k, v or "") for k, v in attrs)
        if tag == "ul":
            if self._in_list:
                self._depth += 1
            elif TOPICS_MARKER in a.get("class", "").split():
                self._in_list, self._depth = True, 0
        elif self._in_list and tag == "a" and self._current is None:
            m = _TOPIC_HREF.search(a.get("href", ""))
            if m:
                self._current = (m.group(1), [])

    def handle_data(self, data):
        if self._current is not None:
            self._current[1].append(data)

    def handle_endtag(self, tag):
        if tag == "ul" and self._in_list:
            if self._depth == 0:
                self._in_list = False
            else:
                self._depth -= 1
        elif tag == "a" and self._current is not None:
            tid, parts = self._current
            self._current = None
            title = _ANY_SPACE.sub(" ", "".join(parts)).strip()
            count = 0
            m = _TOPIC_COUNT.search(title)
            if m:
                count = int(re.sub(r"\D", "", m.group(1)) or 0)
                title = title[:m.start()].strip()
            if title and tid not in self._seen:
                self._seen.add(tid)
                self.topics.append({"id": tid, "title": title, "count": count})


def parse_topics(page: str) -> list[dict]:
    """Themen aus der Seite `category/list`: [{id, title, count}]. Ohne diese Liste leer (Plugin fehlt oder andere Fassung)."""
    p = _TopicParser()
    try:
        p.feed(page or "")
        p.close()
    except Exception:  # noqa: BLE001 - kaputtes HTML: was bis dahin gelesen wurde zaehlt nicht als Liste
        return []
    return p.topics


# ----------------------------------------------------------------------------
# Lesen eines Feeds (RSS 2.0 des Plugins, views/rss/index.php)
# ----------------------------------------------------------------------------

_ITEM_RE = re.compile(r"(?s)<item\b[^>]*>(.*?)</item>")
_CDATA_RE = re.compile(r"(?s)^\s*<!\[CDATA\[(.*?)\]\]>\s*$")
_MONTHS = {"jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12}


def _field(item: str, name: str) -> str | None:
    m = re.search(rf"(?s)<{name}\b[^>]*>(.*?)</{name}>", item)
    if not m:
        return None
    raw = m.group(1)
    c = _CDATA_RE.match(raw)
    return c.group(1) if c else _html.unescape(raw)


def _int(s: str) -> int | None:
    """Ganze Zahl wie Swifts Int(String): optionales Vorzeichen und ASCII-Ziffern, sonst nichts"""
    return int(s) if re.fullmatch(r"[+-]?[0-9]+", s or "") else None


def _days_from_civil(y: int, m: int, d: int) -> int:
    """Tage seit 1970 (H. Hinnant); rechnet auch fuer Tage ausserhalb des Monats weiter, wie der Swift-Kern"""
    y -= m <= 2
    era = (y if y >= 0 else y - 399) // 400
    yoe = y - era * 400
    doy = (153 * (m + (-3 if m > 2 else 9)) + 2) // 5 + d - 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def local_time(rfc2822: str) -> str | None:
    """`pubDate` (RFC 2822, "Mon, 02 Nov 2026 10:15:00 +0100") -> Ortszeit Berlin "YYYY-MM-DDTHH:MM:SS"; None, wenn unlesbar"""
    parts = [p for p in re.split(r"[ ,\t]", rfc2822 or "") if p]
    if parts and _int(parts[0]) is None:
        parts.pop(0)                                              # Wochentag
    if len(parts) < 4:
        return None
    day, month, year = _int(parts[0]), _MONTHS.get(parts[1][:3].lower()), _int(parts[2])
    if day is None or month is None or year is None or not 1 <= day <= 31:
        return None
    if year < 100:
        year += 2000 if year < 50 else 1900
    hms = [n for n in (_int(x) for x in parts[3].split(":") if x != "") if n is not None]
    if len(hms) not in (2, 3) or not 0 <= hms[0] <= 23 or not 0 <= hms[1] <= 59:
        return None
    seconds = hms[0] * 3600 + hms[1] * 60 + (min(59, hms[2]) if len(hms) == 3 else 0)
    offset = 0
    if len(parts) >= 5:
        z = parts[4]
        if len(z) == 5 and z[0] in "+-" and _int(z[1:3]) is not None and _int(z[3:5]) is not None:
            offset = (int(z[1:3]) * 3600 + int(z[3:5]) * 60) * (-1 if z[0] == "-" else 1)
        # GMT, UT, UTC, Z und Zonennamen: 0
    utc = _days_from_civil(year, month, day) * 86400 + seconds - offset
    try:
        return datetime.fromtimestamp(utc, BERLIN).strftime("%Y-%m-%dT%H:%M:%S")
    except (OverflowError, OSError, ValueError):
        return None


def parse_feed(xml: str, topic: str) -> list[dict]:
    """Anzeigen eines Feeds (Thema `topic`): title, link, description (HTML in CDATA), pubDate, guid. Ohne Titel keine
    Anzeige; der Text ist der ganze Text der Anzeige als reiner Text mit Absaetzen, nie gekuerzt ("…").
    Anzeige: {id, topic, title, text, url, posted_at} (url/posted_at leer, wenn unbekannt)."""
    out: list[dict] = []
    seen: set[str] = set()
    for m in _ITEM_RE.finditer(xml or ""):
        item = m.group(1)
        title = _ANY_SPACE.sub(" ", _html.unescape(_field(item, "title") or "")).strip()
        if not title:
            continue
        link = (_field(item, "link") or "").strip()
        guid = (_field(item, "guid") or "").strip()
        if not guid:
            tail = [p for p in link.split("/") if p]
            guid = tail[-1] if tail else ""
        if not guid or guid in seen:
            continue
        seen.add(guid)
        body = announcements.html_to_text(_field(item, "description") or "")
        out.append({"id": "sb-" + guid, "topic": topic, "title": title[:announcements.MAX_TITLE],
                    "text": studip_texts.full(body, MAX_TEXT),
                    "url": link if link.startswith(("https://", "http://")) else "",
                    "posted_at": local_time(_field(item, "pubDate") or "") or ""})
        if len(out) >= PER_TOPIC:
            break
    return out


# ----------------------------------------------------------------------------
# Abruf
# ----------------------------------------------------------------------------

class Reply:
    """Antwort auf einen Seitenaufruf: HTTP-Status, Content-Type, Text und die Adresse nach Weiterleitungen"""

    def __init__(self, status: int, content_type: str = "", body: str = "", final_url: str | None = None):
        self.status, self.content_type, self.body, self.final_url = status, content_type or "", body or "", final_url


class Download:
    def __init__(self, missing: dict):
        self.topics: list[dict] = []
        self.entries: list[dict] | None = None      # None = nicht gelesen (uebersprungen, fehlt, Fehler); der Bestand bleibt
        self.missing = missing
        self.session_expired = False
        self.skipped = False                        # nicht gefragt (zu frueh, als fehlend gemerkt)
        self.feed_unavailable = False               # Themenliste da, aber kein RSS (in Stud.IP abgeschaltet): nichts gespeichert


def looks_like_login(r: Reply) -> bool:
    """Abgelaufene Sitzung: Stud.IP leitet Seitenaufrufe auf die Anmeldung (bzw. die SSO-Seite) um, oder liefert eine
    Seite mit Passwortfeld bzw. Anmelde-Formular."""
    if r.final_url:
        m = re.match(r"^[a-z]+://([^/?#]*)([^?#]*)", r.final_url, re.I)
        host, path = (m.group(1).lower(), m.group(2).lower()) if m else ("", "")
        if "/dispatch.php/login" in path or "/idp/" in path or host.startswith("sso."):
            return True
    head = r.body[:400_000]
    if re.search(r"(?i)<input\b[^>]*\btype\s*=\s*[\"']?password", head):
        return True
    return any("dispatch.php/login" in a.lower() or "/idp/" in a.lower()
               for a in re.findall(r"(?is)<form\b[^>]*\baction\s*=\s*[\"']([^\"']*)", head))


def is_feed(r: Reply) -> bool:
    if "xml" in r.content_type.lower():
        return True
    head = r.body[:600].lower()
    return "<rss" in head or "<?xml" in head


def _utc_seconds(local_iso: str | None) -> int | None:
    for fmt, n in (("%Y-%m-%dT%H:%M:%S", 19), ("%Y-%m-%dT%H:%M", 16)):
        try:
            return int(datetime.strptime((local_iso or "")[:n], fmt).replace(tzinfo=BERLIN).timestamp())
        except ValueError:
            continue
    return None


def fetch(get, missing: dict, last_fetched_at: str | None, today: str, now: str) -> Download:
    """Themen und je Thema die neuesten Anzeigen. `get(path)` -> Reply (nur GET, Pfad ab "/"). Wirft nie: abgelaufene
    Sitzung steht im Ergebnis, Fehler lassen den Bestand. `missing`: gespeicherte Liste fehlender Endpunkte;
    `last_fetched_at`: letzter Abruf (settings); `now`: jetzt als Ortszeit "YYYY-MM-DDTHH:MM:SS"."""
    d = Download(missing)

    def page(path: str) -> Reply:
        r = get(path)
        if looks_like_login(r):
            raise SessionExpired()
        return r

    if not studip_extras.should_ask(missing, MISSING_NAME, today):
        d.skipped = True
        return d
    last, current = _utc_seconds(last_fetched_at), _utc_seconds(now)
    if last is not None and current is not None and current - last < MIN_HOURS * 3600:
        d.skipped = True
        return d
    try:
        r = page(list_path())
    except SessionExpired:
        d.session_expired = True
        return d
    except Exception:  # noqa: BLE001 - Netz weg: Bestand bleibt
        return d
    topics = parse_topics(r.body) if 200 <= r.status < 300 and TOPICS_MARKER in r.body else []
    if not topics:
        # kein Plugin (404, 403, Fehlerseite) oder eine Fassung ohne Themenliste: RETRY_DAYS Tage nicht wieder fragen
        d.missing = studip_extras.remember(missing, MISSING_NAME, 404, today)
        return d
    d.missing = studip_extras.remember(missing, MISSING_NAME, 200, today)
    d.topics = topics
    entries: list[dict] = []
    for t in topics:
        try:
            r = page(feed_path(t["id"]))
        except SessionExpired:
            d.session_expired = True
            return d
        except Exception:  # noqa: BLE001 - Netz weg: Bestand bleibt
            return d
        if not (200 <= r.status < 300 and is_feed(r)):
            if "text/html" in r.content_type.lower():          # RSS abgeschaltet
                d.feed_unavailable = True
                return d
            continue                                            # ein Thema ohne Feed: die anderen weiter
        entries += parse_feed(r.body, t["title"])
    d.entries = entries
    return d


def playwright_get(page, base: str):
    """`get` fuer `fetch` ueber die angemeldete Playwright-Seite; nur GET, mit Pause. Ein Netzfehler wird zur Ausnahme."""
    asked = []

    def get(path: str) -> Reply:
        if asked:
            time.sleep(PAUSE_SECONDS)                         # Pause zwischen zwei Seitenaufrufen
        asked.append(path)
        r = page.request.get(base.rstrip("/") + path, headers={"Accept": "text/html,application/rss+xml"})
        return Reply(r.status, r.headers.get("content-type") or "", r.text(), r.url)
    return get


# ----------------------------------------------------------------------------
# Speicher
# ----------------------------------------------------------------------------

def _has(conn) -> bool:
    return conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='studip_bulletin'").fetchone() is not None


def _setting(conn, key: str) -> str | None:
    r = conn.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
    return r[0] if r else None


def _set_setting(conn, key: str, value: str) -> None:
    conn.execute("INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)", (key, value))


def last_fetched_at(conn) -> str | None:
    """Zeitpunkt des letzten Abrufs (settings) fuer `fetch`"""
    return _setting(conn, FETCHED_KEY)


def store(d: Download, conn, now: str) -> int:
    """Schreibt den Abruf: Anzeigen ersetzen (in Stud.IP Verschwundenes faellt weg), Themen in der Reihenfolge von
    Stud.IP, Zeitpunkt, fehlende Endpunkte. Liefert die Zahl gespeicherter Anzeigen (0 ohne neuen Stand)."""
    studip_extras.save_missing(conn, d.missing)
    if d.entries is None:
        return 0
    conn.execute(TABLE)
    ids = [e["id"] for e in d.entries]
    conn.execute(f"""DELETE FROM studip_bulletin WHERE id NOT IN ({",".join("?" * len(ids)) or "''"})""", ids)
    for e in d.entries:
        conn.execute("""INSERT OR REPLACE INTO studip_bulletin(id, topic, title, text, url, posted_at, fetched_at)
                        VALUES (?,?,?,?,?,?,?)""", (e["id"], e["topic"], e["title"], e["text"], e["url"], e["posted_at"], now))
    _set_setting(conn, TOPICS_KEY, json.dumps([{"id": t["id"], "title": t["title"], "total": t["count"]} for t in d.topics],
                                              ensure_ascii=False, sort_keys=True))
    _set_setting(conn, FETCHED_KEY, now)
    return len(d.entries)


def sync_allowed() -> bool:
    """Brett nur lokal (im Dienst nie) und nur an Hochschulen mit dem Plugin"""
    return not config.is_hosted() and expected()


def run(conn, get, today: str, now: str) -> dict:
    """Ein Durchgang am PC (app/studip_sync.py): Stand lesen, abrufen, speichern. Liefert {entries, topics, skipped, ...}."""
    if not sync_allowed():
        return {"skipped": True}
    d = fetch(get, studip_extras.load_missing(conn), last_fetched_at(conn), today, now)
    if d.skipped:
        return {"skipped": True}
    n = store(d, conn, now)
    return {"entries": n, "topics": len(d.topics), "session_expired": d.session_expired, "feed_unavailable": d.feed_unavailable,
            "missing": MISSING_NAME in d.missing}


# ----------------------------------------------------------------------------
# Lesen: Karte und Leser
# ----------------------------------------------------------------------------

def expected() -> bool:
    """Erwartet die Hochschule dieser Installation ein Schwarzes Brett?"""
    from . import universities
    return universities.current_key() in BOARD_UNIVERSITIES


def _entry_json(r) -> dict:
    return {"id": r[0], "topic": r[1], "title": r[2], "text": r[3], "url": r[4] or None, "posted_at": r[5] or None}


def overview(conn, topic: str | None, today: date) -> dict:
    """`GET /api/studip/bulletin?topic=`: {available, topics: [{title, count, total}], entries: [...], new_count,
    fetched_at, url}. `count` = gespeicherte Anzeigen des Themas (hoechstens PER_TOPIC), `total` = Anzahl laut Stud.IP.
    Neueste zuerst. Im Dienst und an Hochschulen ohne Brett: available false, nichts gelesen."""
    here = not config.is_hosted() and expected()
    out: dict = {"available": here, "topics": [], "entries": [], "new_count": 0, "fetched_at": None,
                 "url": board_url(config.STUDIP_BASE) if expected() else None}
    if not here or not _has(conn):
        return out
    rows = conn.execute("SELECT id, topic, title, text, url, posted_at FROM studip_bulletin ORDER BY posted_at DESC, id").fetchall()
    counts: dict[str, int] = {}
    for r in rows:
        counts[r[1]] = counts.get(r[1], 0) + 1
    order, named = [], set()
    try:
        stored = json.loads(_setting(conn, TOPICS_KEY) or "[]")
    except ValueError:
        stored = []
    for t in stored if isinstance(stored, list) else []:
        title = t.get("title") if isinstance(t, dict) else None
        n = counts.get(title, 0) if isinstance(title, str) else 0
        if n <= 0:
            continue
        named.add(title)
        order.append({"title": title, "count": n, "total": t.get("total", n)})
    for title in sorted(counts):
        if title not in named:
            order.append({"title": title, "count": counts[title], "total": counts[title]})
    since = (today - timedelta(days=NEW_DAYS)).isoformat()
    entries, fresh = [], 0
    for r in rows:
        posted = r[5] or ""
        if posted and posted[:10] >= since:
            fresh += 1
        if topic and r[1] != topic:
            continue
        entries.append(_entry_json(r))
    out.update({"topics": order, "entries": entries, "new_count": fresh, "fetched_at": last_fetched_at(conn)})
    return out


def item(conn, entry_id: str) -> dict | None:
    """`GET /api/studip/bulletin/{id}`: eine Anzeige zum Lesen; None = unbekannt"""
    if config.is_hosted() or not _has(conn):
        return None
    r = conn.execute("SELECT id, topic, title, text, url, posted_at FROM studip_bulletin WHERE id=?", (entry_id,)).fetchone()
    return _entry_json(r) if r else None

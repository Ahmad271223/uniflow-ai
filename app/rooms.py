"""Raumfinder (05.11.2026, docs/RAUMFINDER-2026-11-05.md): Raeume, Gebaeude und Einrichtungen finden, mit Link zu Google Maps.

- LUH: oeffentlicher Standortfinder (https://standortfinder.uni-hannover.de/de/), Suche per `POST /search` mit
  `search=<text>&page=<n>` (100 Treffer je Seite). Der Server verlangt derzeit kein CSRF-Token; antwortet er mit 403,
  holen wir das Cookie `csrftoken` von der Startseite und schicken es als `X-CSRFToken` (einmal je Sitzung).
- HsH und Uni Hildesheim: kein oeffentlicher Raumfinder. Der Ort kommt aus einer kleinen Tabelle der Standorte
  (packages/shared-contracts/rooms.json, Adressen von den Anfahrtsseiten) und wird ehrlich als "Ort laut Hochschule;
  genaue Lage ohne Gewähr" gezeigt.

Raumangaben aus Stundenplan, Lernkalender und Klausurterminen (Stud.IP, QIS/LSF, HISinOne) werden mit `parse` zerlegt
("F102", "1101 - F102", "F102 (1101)", "Gebäude 3403, Raum A003", "Hauptgebäude, F142", "1101.001.F102" ...) und mit
`resolve` aufgeloest; Suchantworten liegen 30 Tage im Cache (Raeume ziehen selten um), "nichts gefunden" einen Tag.
Ohne Netz: Cache oder eine einfache Adress-Suche als Link. An Google geht nie etwas von selbst: die App baut nur Links
(`maps`), die erst beim Antippen geoeffnet werden. Gleiche Regeln im Swift-Kern (Rooms/Rooms.swift); Faelle:
packages/shared-contracts/fixtures/rooms.
"""
from __future__ import annotations

import json
import math
import re
import threading
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parent.parent
DATA_PATH = ROOT / "packages" / "shared-contracts" / "rooms.json"
BERLIN = ZoneInfo("Europe/Berlin")
USER_AGENT = "StudiNow/1.0 (+https://studinow.app; support@studinow.app)"
CACHE_DAYS = 30
MISS_DAYS = 1
CACHE_MAX = 500
MAX_PARTS = 4
MAX_QUERY = 80
ITEM_TYPES = {1: "room", 2: "building", 3: "facility", "lr01": "building"}

_DATA: dict | None = None
_LOCK = threading.Lock()
_SESSION: dict = {"token": None}


def load_data() -> dict:
    global _DATA
    if _DATA is None:
        _DATA = json.loads(DATA_PATH.read_text(encoding="utf-8"))
    return _DATA


def source(data: dict | None = None) -> dict:
    sf = (data or load_data())["standortfinder"]
    return {"key": "standortfinder", "name": sf["name"], "url": sf["url"], "attribution": sf["attribution"]}


# MARK: Links zu Karten (nur gebaut, nie aufgerufen)

def enc(s: str) -> str:
    """Prozent-Kodierung aller Zeichen ausser A-Z a-z 0-9 - . _ ~ (gleich im Swift-Kern)"""
    return urllib.parse.quote(str(s), safe="")


def coord(x: float) -> str:
    """52.38255 -> "52.38255", 52.38 -> "52.38" (hoechstens 6 Nachkommastellen)"""
    return f"{float(x):.6f}".rstrip("0").rstrip(".")


def maps(query: str, label: str | None = None, lat: float | None = None, lon: float | None = None) -> dict:
    """Links fuer Google Maps (Web und App) und Apple Karten. Mit Koordinaten: Ziel "lat,lon", sonst der Suchtext."""
    has = lat is not None and lon is not None
    q = f"{coord(lat)},{coord(lon)}" if has else " ".join(str(query).split())
    apple = (f"https://maps.apple.com/?q={enc(label or q)}&ll={enc(q)}" if has else f"https://maps.apple.com/?q={enc(q)}")
    return {
        "query": q,
        "google": f"https://www.google.com/maps/search/?api=1&query={enc(q)}",
        "google_route": f"https://www.google.com/maps/dir/?api=1&destination={enc(q)}&travelmode=walking",
        "google_app": f"comgooglemaps://?q={enc(q)}",
        "google_app_route": f"comgooglemaps://?daddr={enc(q)}&directionsmode=walking",
        "apple": apple,
        "apple_route": f"https://maps.apple.com/?daddr={enc(q)}&dirflg=w",
    }


# MARK: Treffer des Standortfinders vereinheitlichen

def _s(v) -> str:
    return " ".join(str(v).split()) if v is not None else ""


def _https(v) -> str | None:
    s = _s(v)
    return s if s.startswith("https://") else None


def floor_label(f) -> str | None:
    """"000" -> "Erdgeschoss", "001" -> "1. Obergeschoss", "-01" -> "1. Untergeschoss", sonst "Etage X" """
    s = _s(f)
    if not s:
        return None
    m = re.fullmatch(r"(-?)0*(\d+)", s)
    if not m:
        return f"Etage {s}"
    n = int(m.group(2))
    if n == 0:
        return "Erdgeschoss"
    return f"{n}. Untergeschoss" if m.group(1) else f"{n}. Obergeschoss"


def _address(item: dict) -> dict | None:
    street, no, zipc, city = (_s(item.get(k)) for k in ("street", "house_number", "zip_code", "city"))
    if not street:
        return None
    first = f"{street} {no}".strip()
    second = f"{zipc} {city}".strip()
    return {"street": street, "house_number": no, "zip": zipc, "city": city,
            "line": ", ".join(x for x in (first, second) if x)}


def _bf_rows(info, kind: str, data: dict) -> list[dict]:
    if not isinstance(info, dict):
        return []
    table = data["accessibility"]
    out = []
    for r in table[kind]:
        st = table["status"].get(_s(info.get(r["status"]))) if r["status"] else None
        text = _s(info.get(r["text"])) or None
        if st or text:
            out.append({"key": r["key"], "title": r["title"], "status": st, "text": text})
    return out


def place(item: dict, data: dict | None = None) -> dict:
    """Ein Treffer (Raum, Gebaeude, Einrichtung) in fester Form, mit Kartenlinks"""
    data = data or load_data()
    kind = ITEM_TYPES.get(item.get("item_type"), "building")
    room, bid = _s(item.get("room_nr")) or None, _s(item.get("building_id")) or None
    bname = _s(item.get("building_name")) or None
    rname = _s(item.get("room_name")) or (_s(item.get("item_name")) if kind == "room" else "") or None
    floor = _s(item.get("floor_nr")) or None
    addr = _address(item)
    if kind == "room":
        title = f"Raum {room}" + (f" – {rname}" if rname else "")
        sub = [f"Gebäude {bid}" + (f" ({bname})" if bname else "") if bid else None, floor_label(floor)]
    elif kind == "facility":
        title = _s(item.get("item_name")) or "Einrichtung"
        sub = [f"Gebäude {bid}" + (f" ({bname})" if bname else "") if bid else None, f"Raum {room}" if room else None]
    else:
        title = f"Gebäude {bid}" + (f" – {bname}" if bname else "") if bid else (bname or _s(item.get("item_name")) or "Gebäude")
        sub = []
    sub.append(addr["line"] if addr else None)
    lat, lon = item.get("lat"), item.get("lon")
    has = isinstance(lat, (int, float)) and isinstance(lon, (int, float)) and not isinstance(lat, bool)
    ok = bool(item.get("is_position_correct")) and has
    if ok:
        m = maps("", title, float(lat), float(lon))
    else:
        m = maps(addr["line"] if addr else f"{title}, {data['universities']['luh']['fallback']}", title)
    extra = item.get("extra_info") if isinstance(item.get("extra_info"), dict) else {}
    return {
        "id": _s(item.get("item_id")) or _s(item.get("room_id")) or bid or title,
        "type": kind,
        "title": title,
        "subtitle": " · ".join(x for x in sub if x),
        "room": room,
        "room_name": rname,
        "building": bid,
        "building_name": bname,
        "floor": floor,
        "floor_label": floor_label(floor),
        "address": addr,
        "lat": float(lat) if has else None,
        "lon": float(lon) if has else None,
        "position_ok": ok,
        "note": None if ok else data["note_position"],
        "floorplan_url": _https(item.get("room_floorplan_url")),
        "room_url": _https(item.get("room_url")),
        "building_url": _https(item.get("building_url")),
        "website": _https(extra.get("website_link")),
        "opening_hours_url": _https(extra.get("opening_hours_link")),
        "description": _s(extra.get("description_de")) or None,
        "accessibility": {"building": _bf_rows(item.get("bf_building_info"), "building", data),
                          "room": _bf_rows(item.get("bf_room_info"), "room", data)},
        "maps": m,
        "source": "standortfinder",
    }


def campus_place(c: dict, university: str, data: dict | None = None) -> dict:
    """Standort einer Hochschule (Tabelle in rooms.json) in derselben Form wie ein Treffer"""
    data = data or load_data()
    u = data["universities"][university]
    has = c.get("lat") is not None and c.get("lon") is not None
    line = c["address"]
    return {
        "id": f"{university}:{c['id']}", "type": "campus", "title": c["name"], "subtitle": f"{u['name']} · {line}",
        "room": None, "room_name": None, "building": None, "building_name": None, "floor": None, "floor_label": None,
        "address": {"street": "", "house_number": "", "zip": "", "city": "", "line": line},
        "lat": float(c["lat"]) if has else None, "lon": float(c["lon"]) if has else None, "position_ok": False,
        "note": data["note_campus"], "floorplan_url": None, "room_url": None, "building_url": None, "website": None,
        "opening_hours_url": None, "description": None, "accessibility": {"building": [], "room": []},
        "maps": maps(f"{u['name']}, {line}", c["name"]), "source": "campus",
    }


# MARK: Raumangaben zerlegen

ROOM_ID = re.compile(r"(?<!\d)(\d{4})\.(\d{3})\.([A-Za-z]?\d{2,4}[A-Za-z]?)(?![\w.])")
BUILDING_ROOM = re.compile(r"(?<![\d.])(?!19\d\d|20\d\d)(\d{4})\s*(?:-|–|/|,)\s*(?:Raum\s+)?([A-Z]{1,2}\s?\d{2,3}[A-Z]?|\d{3})(?![\w.])")
ROOM_BUILDING = re.compile(r"(?<![\w.])([A-Z]{1,2}\s?\d{3}[A-Z]?)\s*\(\s*(?:Geb(?:äude|\.)?\s*)?(?!19\d\d|20\d\d)(\d{4})\s*\)")
BUILDING_WORD = re.compile(r"Geb(?:äude|\.)?\s*(\d{4})(?!\d)")
ROOM_CODE = re.compile(r"(?<![\w.])([A-Z]{1,2})\s?(\d{3})([A-Z]?)(?![\w.])")
ROOM_NUMBER = re.compile(r"Raum\s+(\d{3})(?![\d.])")
BUILDING_ALONE = re.compile(r"(?<![\w.,:])(\d{4})(?![\w.,:])")
BUILDING_NAME = re.compile(r"([A-ZÄÖÜ][\wäöüß-]*(?:gebäude|haus))(?![\wäöüß])")
SPLIT = re.compile(r"\s+·\s+|;|\s\|\s|\n")


def _upper(s: str) -> str:
    return re.sub(r"\s+", "", s).upper()


def _contains_word(hay: str, word: str) -> bool:
    return re.search(r"(?<![\wäöüß])" + re.escape(word) + r"(?![\wäöüß])", hay) is not None


def _online(seg: str, data: dict) -> bool:
    low = seg.lower()
    return any(_contains_word(low, w) for w in data["online_words"])


def segments(text: str | None) -> list[str]:
    s = str(text or "").replace("\r", "\n")
    out = [" ".join(p.split()) for p in SPLIT.split(s)]
    return [p for p in out if p][:MAX_PARTS]


def _campus(seg: str, university: str, data: dict) -> str | None:
    low = seg.lower()
    for c in data["universities"].get(university, {}).get("campuses", []):
        if any(_contains_word(low, w) for w in c.get("match", [])):
            return c["id"]
        if c.get("codes") and re.search(c["codes"], seg):
            return c["id"]
    return None


def parse_segment(seg: str, university: str = "luh", data: dict | None = None) -> dict:
    """Eine Raumangabe -> {text, room, building, building_name, floor, campus, online, query, linkable}"""
    data = data or load_data()
    room = building = floor = name = None
    online = _online(seg, data)
    if university == "luh":
        if m := ROOM_ID.search(seg):
            building, floor, room = m.group(1), m.group(2), m.group(3).upper()
        elif m := BUILDING_ROOM.search(seg):
            building, room = m.group(1), _upper(m.group(2))
        elif m := ROOM_BUILDING.search(seg):
            room, building = _upper(m.group(1)), m.group(2)
        else:
            if m := BUILDING_WORD.search(seg):
                building = m.group(1)
            if m := ROOM_CODE.search(seg):
                room = m.group(1) + m.group(2) + m.group(3)
            elif building and (m := ROOM_NUMBER.search(seg)):
                room = m.group(1)
            if not building:
                for m in BUILDING_ALONE.finditer(seg):
                    if m.group(1)[:2] not in ("19", "20"):
                        building = m.group(1)
                        break
        low = seg.lower()
        for b in data["luh_buildings"]:
            if _contains_word(low, b["name"].lower()):
                name = b["name"]
                building = building or b["id"]
                break
        if not name and (m := BUILDING_NAME.search(seg)):
            name = m.group(1)
        query = room or building or name
    else:
        query = None
    campus = _campus(seg, university, data)
    linkable = not online and bool(query if university == "luh" else seg)
    if online and room:          # "Online / Raum F102": der Raum zaehlt
        online, linkable = False, True
    return {"text": seg, "room": room, "building": building, "building_name": name, "floor": floor, "campus": campus,
            "online": online, "query": query, "linkable": linkable}


def parse(text: str | None, university: str = "luh", data: dict | None = None) -> dict:
    data = data or load_data()
    uni = university if university in data["universities"] else "luh"
    parts = [parse_segment(s, uni, data) for s in segments(text)]
    return {"text": " ".join(str(text or "").split()), "university": uni, "parts": parts,
            "linkable": any(p["linkable"] for p in parts)}


# MARK: Treffer auswaehlen

def choose(part: dict, items: list[dict]) -> tuple[str, list[dict]]:
    """Passende Treffer zu einer zerlegten Angabe -> (found|ambiguous|not_found, Treffer)"""
    items = [i for i in items or [] if isinstance(i, dict)]
    if part.get("room"):
        want = _upper(part["room"])
        c = [i for i in items if _upper(_s(i.get("room_nr"))) == want]
        if part.get("building"):
            c = [i for i in c if _s(i.get("building_id")) == part["building"]]
        elif part.get("building_name"):
            n = part["building_name"].lower()
            c = [i for i in c if n in _s(i.get("building_name")).lower()] or c
        if part.get("floor"):
            c = [i for i in c if _s(i.get("floor_nr")) == part["floor"]] or c
    elif part.get("building"):
        c = [i for i in items if i.get("item_type") == 2 and _s(i.get("building_id")) == part["building"]]
    elif part.get("building_name"):
        n = part["building_name"].lower()
        c = ([i for i in items if n == _s(i.get("building_name")).lower() or n == _s(i.get("item_name")).lower()]
             or [i for i in items if n in (_s(i.get("building_name")) + " " + _s(i.get("item_name"))).lower()])
    else:
        c = []
    return ("found" if len(c) == 1 else "ambiguous" if c else "not_found"), c


# MARK: Abruf mit Cache

def now() -> datetime:
    return datetime.now(BERLIN)


def _post(url: str, form: dict, token: str | None, timeout: float) -> bytes:
    sf = load_data()["standortfinder"]
    headers = {"User-Agent": USER_AGENT, "Accept": "application/json", "Referer": sf["url"],
               "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8", "X-Requested-With": "XMLHttpRequest"}
    if token:
        headers["X-CSRFToken"] = token
        headers["Cookie"] = f"csrftoken={token}"
    req = urllib.request.Request(url, data=urllib.parse.urlencode(form).encode(), headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310 - feste https-Adresse aus rooms.json
        return r.read()


def _fresh_token(timeout: float) -> str | None:
    """Cookie csrftoken von der Startseite (nur noetig, wenn die Suche 403 meldet)"""
    sf = load_data()["standortfinder"]
    req = urllib.request.Request(sf["url"], headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310
        for h in r.headers.get_all("Set-Cookie") or []:
            m = re.match(r"\s*csrftoken=([^;]+)", h)
            if m:
                return m.group(1)
    return None


def http_search(term: str, page: int = 0, timeout: float = 10.0) -> dict:
    """POST /search beim Standortfinder (Tests ersetzen diese Funktion; nie echtes Netz in Tests)"""
    url = load_data()["standortfinder"]["search"]
    form = {"search": term, "page": str(page)}
    try:
        raw = _post(url, form, _SESSION["token"], timeout)
    except urllib.error.HTTPError as e:
        if e.code != 403:
            raise
        _SESSION["token"] = _fresh_token(timeout)
        raw = _post(url, form, _SESSION["token"], timeout)
    out = json.loads(raw)
    if not isinstance(out, dict) or not isinstance(out.get("data"), list):
        raise ValueError("unerwartete Antwort")
    return out


def cache_path() -> Path:
    from . import config
    p = Path(config.BASE_DATA_DIR) / "rooms"
    p.mkdir(parents=True, exist_ok=True)
    return p / "search-cache.json"


def _read(path: Path) -> dict:
    try:
        d = json.loads(path.read_text(encoding="utf-8"))
        return d if isinstance(d, dict) and d.get("v") == 1 else {"v": 1, "entries": {}}
    except (OSError, ValueError):
        return {"v": 1, "entries": {}}


def _write(path: Path, cache: dict) -> None:
    entries = cache["entries"]
    if len(entries) > CACHE_MAX:
        keep = sorted(entries.items(), key=lambda kv: kv[1].get("at", ""), reverse=True)[:CACHE_MAX]
        cache["entries"] = dict(keep)
    try:
        path.write_text(json.dumps(cache, ensure_ascii=False), encoding="utf-8")
    except OSError:
        pass


def cache_key(term: str, page: int = 0) -> str:
    return f"{' '.join(term.split()).lower()}|{page}"


def is_fresh(entry: dict | None, at: datetime) -> bool:
    if not entry:
        return False
    try:
        t = datetime.fromisoformat(entry["at"])
    except (KeyError, ValueError, TypeError):
        return False
    days = CACHE_DAYS if entry.get("count") else MISS_DAYS
    return at - t < timedelta(days=days)


def cached_search(term: str, page: int = 0, search=None, path: Path | None = None, at: datetime | None = None) -> tuple[dict | None, bool]:
    """(Antwort {count, data}, stale). Ohne Netz der alte Stand (stale) oder None."""
    search = search or http_search
    path = path or cache_path()
    at = at or now()
    key = cache_key(term, page)
    with _LOCK:
        cache = _read(path)
        entry = cache["entries"].get(key)
    if is_fresh(entry, at):
        return entry, False
    try:
        r = search(term, page)
    except Exception:  # noqa: BLE001 - Netz, HTTP, JSON
        return entry, True
    entry = {"at": at.isoformat(timespec="seconds"), "count": int(r.get("count") or 0),
             "data": [i for i in r.get("data") or [] if isinstance(i, dict)]}
    with _LOCK:
        cache = _read(path)
        cache["entries"][key] = entry
        _write(path, cache)
    return entry, False


OFFLINE = "Keine Verbindung zum Standortfinder. Du siehst den zuletzt geladenen Stand."
OFFLINE_EMPTY = "Der Standortfinder ist gerade nicht erreichbar. Der Link sucht stattdessen nach dem Text in Google Maps."


def search(q: str | None, page: int = 0, search_fn=None, path: Path | None = None, at: datetime | None = None) -> dict:
    """Antwort von GET /api/rooms/search (Seite "Raumfinder")"""
    data = load_data()
    term = " ".join(str(q or "").split())[:MAX_QUERY]
    page = max(0, int(page or 0))
    out = {"query": term, "count": 0, "page": page, "pages": 0, "items": [], "stale": False, "message": None,
           "source": source(data)}
    if not term:
        return out
    entry, stale = cached_search(term, page, search_fn, path, at)
    if entry is None:
        out.update(stale=True, message="Der Standortfinder ist gerade nicht erreichbar. Versuche es später erneut.")
        return out
    size = data["standortfinder"]["page_size"]
    out.update(count=entry["count"], pages=math.ceil(entry["count"] / size) if entry["count"] else 0,
               items=[place(i, data) for i in entry["data"]], stale=stale, message=OFFLINE if stale else None)
    return out


def _fallback(part: dict, university: str, data: dict) -> dict:
    u = data["universities"][university]
    return maps(f"{u['fallback']} {part['text']}", part["text"])


def resolve_part(part: dict, university: str, search_fn=None, path: Path | None = None, at: datetime | None = None,
                 data: dict | None = None) -> tuple[dict, bool]:
    """Eine zerlegte Angabe aufloesen -> (Teil der Antwort, stale)"""
    data = data or load_data()
    out = {**part, "status": "none", "place": None, "candidates": [], "maps": None, "note": None}
    if part["online"]:
        out["status"] = "online"
        return out, False
    if university != "luh":
        cs = {c["id"]: c for c in data["universities"][university]["campuses"]}
        c = cs.get(part["campus"]) if part["campus"] else None
        if c:
            p = campus_place(c, university, data)
            out.update(status="campus", place=p, maps=p["maps"])
        else:
            out.update(status="search", maps=_fallback(part, university, data))
        out["note"] = data["note_campus"]
        return out, False
    if not part["query"]:
        out.update(status="unknown", maps=_fallback(part, university, data),
                   note="Keine Raum- oder Gebäudenummer erkannt; der Link sucht nach dem Text.")
        return out, False
    entry, stale = cached_search(part["query"], 0, search_fn, path, at)
    if entry is None:
        out.update(status="offline", maps=_fallback(part, university, data), note=OFFLINE_EMPTY)
        return out, True
    status, hits = choose(part, entry["data"])
    if status == "not_found" and part["room"] and part["building"]:
        b_entry, b_stale = cached_search(part["building"], 0, search_fn, path, at)
        stale = stale or b_stale
        if b_entry:
            b_status, b_hits = choose({**part, "room": None, "floor": None}, b_entry["data"])
            if b_status == "found":
                p = place(b_hits[0], data)
                out.update(status="building", place=p, maps=p["maps"],
                           note=f"Raum {part['room']} steht nicht im Standortfinder; gezeigt wird das Gebäude.")
                return out, stale
    if status == "found":
        p = place(hits[0], data)
        out.update(status="found", place=p, maps=p["maps"])
    elif status == "ambiguous":
        out.update(status="ambiguous", candidates=[place(i, data) for i in hits[:10]], maps=_fallback(part, university, data),
                   note=f"{len(hits)} Treffer – bitte den richtigen Ort wählen.")
    else:
        out.update(status="not_found", maps=_fallback(part, university, data),
                   note="Im Standortfinder nicht gefunden; der Link sucht nach dem Text.")
    return out, stale


def resolve(text: str | None, university: str = "luh", search_fn=None, path: Path | None = None,
            at: datetime | None = None) -> dict:
    """Antwort von GET /api/rooms/resolve"""
    data = load_data()
    parsed = parse(text, university, data)
    uni = parsed["university"]
    parts, stale = [], False
    for p in parsed["parts"]:
        r, s = resolve_part(p, uni, search_fn, path, at, data)
        parts.append(r)
        stale = stale or s
    return {"text": parsed["text"], "university": uni, "parts": parts,
            "source": source(data) if uni == "luh" else None, "stale": stale,
            "message": OFFLINE if stale and any(p["status"] in ("found", "ambiguous", "building") for p in parts)
            else (OFFLINE_EMPTY if stale else None)}


def campuses(university: str | None) -> dict:
    """Antwort von GET /api/rooms/campuses: Standorte der Hochschule mit Kartenlinks"""
    data = load_data()
    uni = university if university in data["universities"] else "luh"
    u = data["universities"][uni]
    return {"university": uni, "name": u["name"], "finder": bool(u.get("finder")),
            "campuses": [campus_place(c, uni, data) for c in u["campuses"]],
            "note": None if u.get("finder") else data["note_campus"], "source": source(data)}

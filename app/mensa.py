"""Mensa (05.11.2026, docs/MENSA-2026-11-05.md): Speiseplaene der Mensen an LUH, Hochschule Hannover und Uni Hildesheim.

Quellen (packages/shared-contracts/mensa.json, je Mensa `source`):
- studifutter: Studentenwerk Hannover, oeffentliche Schnittstelle hinter der eigenen Webseite und der App Studi|Futter
  (Directus, `items/foodoffers`), Ersatz bei Ausfall: OpenMensa (`openmensa`, gleiche Mensen, Parser der Community).
- stwon: Studierendenwerk OstNiedersachsen, dokumentierte Mensa-API (https://api.stw-on.de/#mensa-api).

Ablauf: ein Abruf je Mensa holt 14 Tage ab heute (eine Anfrage), Ergebnis im Cache je Mensa und Tag (3 Stunden frisch,
danach neu; ohne Netz der letzte Stand mit `stale`). Alles wird auf eine Form gebracht (Kategorie, Name, Preise
Studierende/Bedienstete/Gaeste, Kennzeichen, Allergene mit einheitlichem Schluessel, Zusatzstoffe). Die gleiche Form
liefert der Swift-Kern auf dem iPad (Mensa/Mensa.swift); Faelle: packages/shared-contracts/fixtures/mensa.
"""
from __future__ import annotations

import json
import re
import threading
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parent.parent
DATA_PATH = ROOT / "packages" / "shared-contracts" / "mensa.json"
BERLIN = ZoneInfo("Europe/Berlin")
WINDOW_DAYS = 14
FRESH_SECONDS = 3 * 3600
KEEP_PAST_DAYS = 7
CACHE_VERSION = 2                      # 2: mit Naehrwerten, Bestandteilen, Klima (aeltere Caches werden neu geholt)
USER_AGENT = "StudiNow/1.0 (+https://studinow.app; support@studinow.app)"
ROLES = [{"key": "student", "name": "Studierende"}, {"key": "employee", "name": "Bedienstete"}, {"key": "guest", "name": "Gäste"}]
TIMES = {"morning": "frueh", "noon": "mittag", "evening": "abend"}
STUDIFUTTER_FIELDS = ("id,date,alias,price_student,price_employee,price_guest,foodoffer_category.alias,"
                      "foodoffer_category.sort,markings.markings_id.external_identifier,attribute_values.number_value,"
                      "attribute_values.string_value,attribute_values.food_attribute.external_identifier,"
                      "foodoffer_components.component_foodoffers_id.alias")
NUTRITION_KEYS = ["energy_kj", "energy_kcal", "fat", "saturated_fat", "carbohydrates", "sugar", "fiber", "protein", "salt"]

_DATA: dict | None = None
_LOCKS: dict[str, threading.Lock] = {}
_LOCKS_GUARD = threading.Lock()


def load_data() -> dict:
    global _DATA
    if _DATA is None:
        _DATA = json.loads(DATA_PATH.read_text(encoding="utf-8"))
    return _DATA


# MARK: Mensen

def canteen(cid: str | None, data: dict | None = None) -> dict | None:
    data = data or load_data()
    return next((c for c in data["canteens"] if c["id"] == cid), None)


def public_canteen(c: dict, university: str | None = None, data: dict | None = None) -> dict:
    data = data or load_data()
    src = data["sources"][c["source"]["kind"]]
    return {"id": c["id"], "name": c["name"], "region": c["region"], "universities": list(c["universities"]),
            "own": bool(university and university in c["universities"]), "address": c["address"], "url": c["url"],
            "hours": c["hours"], "source": c["source"]["kind"], "source_name": src["name"]}


def default_canteen(university: str | None, data: dict | None = None) -> str:
    data = data or load_data()
    u = data["universities"].get(university or "") or data["universities"]["luh"]
    return u["default"]


def canteens_response(university: str | None, data: dict | None = None) -> dict:
    """Alle Mensen, zuerst die Region der eigenen Hochschule (eigene Mensen vorn), dann die uebrigen"""
    data = data or load_data()
    uni = university if university in data["universities"] else "luh"
    region = data["universities"][uni]["region"]
    order = {c["id"]: i for i, c in enumerate(data["canteens"])}
    items = sorted(data["canteens"], key=lambda c: (c["region"] != region, uni not in c["universities"], order[c["id"]]))
    return {"university": uni, "region": region, "default": default_canteen(uni, data),
            "canteens": [public_canteen(c, uni, data) for c in items],
            "roles": ROLES, "labels": data["labels"], "allergens": data["allergens"]}


# MARK: Abruf-Adressen

def window(today: date, start: date | None = None) -> tuple[date, date]:
    s = min(start or today, today)
    return s, s + timedelta(days=WINDOW_DAYS - 1)


def source_url(c: dict, start: date, end: date, kind: str | None = None, data: dict | None = None) -> str:
    data = data or load_data()
    kind = kind or c["source"]["kind"]
    api = data["sources"][kind]["api"]
    if kind == "studifutter":
        flt = {"_and": [{"canteen": {"_eq": c["source"]["id"]}}, {"date": {"_between": [start.isoformat(), end.isoformat()]}}]}
        q = [("fields", STUDIFUTTER_FIELDS), ("limit", "-1"), ("filter", json.dumps(flt, separators=(",", ":")))]
        return f"{api}/items/foodoffers?" + "&".join(f"{k}={urllib.parse.quote(v, safe='')}" for k, v in q)
    if kind == "stwon":
        return f"{api}/locations/{c['source']['id']}/menu/{start.isoformat()}/{end.isoformat()}"
    if kind == "openmensa":
        return f"{api}/canteens/{c['openmensa']}/meals"
    raise ValueError(kind)


# MARK: Vereinheitlichen

def pretty_category(s: str | None) -> str:
    """"VEGGIE & VEGAN" -> "Veggie & Vegan", "SÜSSE ECKE" -> "Süße Ecke"; gemischte Schreibung bleibt"""
    s = " ".join(str(s or "").split())
    if not s or s != s.upper():
        return s
    words = [w[:1].upper() + w[1:].lower() for w in s.split(" ")]
    return " ".join(words).replace("Süsse", "Süße")


def _price(v) -> float | None:
    try:
        f = round(float(v), 2)
    except (TypeError, ValueError):
        return None
    return f if f > 0 else None


def _is_side(category: str, data: dict) -> bool:
    return category.lower() in data["side_categories"]


def _number(v) -> float | None:
    """Zahl aus 2.7, "2,7 g" oder "13,2"; sonst None (0 bleibt 0)"""
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return round(float(v), 2)
    m = re.search(r"-?\d+(?:[.,]\d+)?", str(v or ""))
    return round(float(m.group(0).replace(",", ".")), 2) if m else None


def _nutrition(values: dict, basis: str) -> dict | None:
    """Naehrwerte in fester Form; ohne einen einzigen Wert None ("Keine Nährwertangaben vom Studentenwerk")"""
    out = {"basis": basis, **{k: values.get(k) for k in NUTRITION_KEYS}}
    return out if any(out[k] is not None for k in NUTRITION_KEYS) else None


def _finish(meal: dict, labels: set[str], data: dict, nutrition: dict | None = None, components: list[str] | None = None,
            climate: dict | None = None) -> dict:
    """Kennzeichen in fester Reihenfolge; "Fisch" nur ohne "vegetarisch" (Fisch als Allergen etwa in einer Sosse).
    Dazu Naehrwerte (je Portion oder je 100 g), Bestandteile/Beilagen und Klima-Angaben, wie die Quelle sie liefert."""
    meal["nutrition"] = nutrition
    meal["components"] = components or []
    meal["climate"] = climate
    if "vegetarisch" in labels:
        labels.discard("fisch")
    order = [l["key"] for l in data["labels"]]
    meal["labels"] = [k for k in order if k in labels]
    meal["main"] = not _is_side(meal["category"], data)
    return meal


def _add_allergen(out: list[dict], code: str, key: str, name: str) -> None:
    if not any(a["code"] == code and a["key"] == key for a in out):
        out.append({"code": code, "key": key, "name": name})


def parse_studifutter(raw: dict, data: dict | None = None) -> dict:
    """Antwort von items/foodoffers -> {"days": {datum: [meal]}, "closed": []}"""
    data = data or load_data()
    table = data["studifutter_markings"]
    rows = raw.get("data") if isinstance(raw, dict) else raw
    days: dict[str, list[tuple]] = {}
    for i, o in enumerate(rows or []):
        d = str(o.get("date") or "")[:10]
        name = " ".join(str(o.get("alias") or "").split())
        if not d or not name:
            continue
        cat = o.get("foodoffer_category") or {}
        labels: set[str] = set()
        allergens: list[dict] = []
        additives: list[dict] = []
        notes: list[str] = []
        klimateller = False
        for m in o.get("markings") or []:
            code = str(((m or {}).get("markings_id") or {}).get("external_identifier") or "")
            t = table.get(code)
            if not t:
                continue
            if t["type"] == "label":
                labels.update(t["keys"])
            elif t["type"] == "allergen":
                _add_allergen(allergens, code, t["key"], t["name"])
                if t.get("label"):
                    labels.add(t["label"])
            elif t["type"] == "additive":
                additives.append({"code": code, "name": t["name"]})
            elif t["type"] == "climate":
                klimateller = True
            elif t["name"] not in notes:
                notes.append(t["name"])
        meal = {"id": str(o.get("id") or f"{d}-{i}"), "name": name, "category": pretty_category(cat.get("alias")), "time": None,
                "prices": {"student": _price(o.get("price_student")), "employee": _price(o.get("price_employee")),
                           "guest": _price(o.get("price_guest"))},
                "allergens": allergens, "additives": additives, "notes": notes}
        nmap = data["studifutter_nutrition"]
        values: dict = {}
        co2_g, rating = None, None
        for a in o.get("attribute_values") or []:
            ext = str(((a or {}).get("food_attribute") or {}).get("external_identifier") or "")
            num = a.get("number_value") if isinstance(a.get("number_value"), (int, float)) else None
            if ext in nmap and num is not None:
                values[nmap[ext]] = _number(num)
            elif ext == "co2_g" and num is not None and num > 0:
                co2_g = _number(num)
            elif ext == "co2_rating" and str(a.get("string_value") or "").strip():
                rating = str(a["string_value"]).strip()
        components = [" ".join(str(((c or {}).get("component_foodoffers_id") or {}).get("alias") or "").split())
                      for c in o.get("foodoffer_components") or []]
        climate = {"co2_g": co2_g, "rating": rating, "klimateller": klimateller} if (co2_g or rating or klimateller) else None
        sort = cat.get("sort") if isinstance(cat.get("sort"), (int, float)) else 99
        days.setdefault(d, []).append((sort, i, _finish(meal, labels, data, _nutrition(values, "portion"),
                                                         [c for c in components if c], climate)))
    return {"days": {d: [m for _, _, m in sorted(v, key=lambda x: (x[0], x[1]))] for d, v in sorted(days.items())}, "closed": []}


def parse_stwon(raw: dict, data: dict | None = None) -> dict:
    data = data or load_data()
    cats, alls = data["stwon_categories"], data["stwon_allergens"]
    days: dict[str, list[tuple]] = {}
    time_rank = {"frueh": 0, "mittag": 1, "abend": 2}
    for i, o in enumerate((raw or {}).get("meals") or []):
        d = str(o.get("date") or "")[:10]
        name = " ".join(str(o.get("name") or "").split())
        if not d or not name:
            continue
        tags = o.get("tags") or {}
        labels: set[str] = set()
        notes: list[str] = []
        klimateller = False
        for c in tags.get("categories") or []:
            if str(c.get("id") or "").upper() in data["stwon_climate"]:
                klimateller = True
            elif c.get("id") in cats:
                labels.update(cats[c["id"]])
            elif c.get("name") and c["name"] not in notes:
                notes.append(c["name"])
        allergens: list[dict] = []
        raw_all = [(str(a.get("id") or ""), str(a.get("name") or "")) for a in tags.get("allergens") or []]
        codes = {c for c, _ in raw_all}
        for code, aname in raw_all:
            base = code.rstrip("0123456789")
            # "GL" (glutenhaltiges Getreide) entfaellt, wenn die Getreideart ("GL1 Weizen") dabei ist
            if base not in alls or (code == base and any(c != code and c.rstrip("0123456789") == base for c in codes)):
                continue
            aname = aname[len(base) + 1:] if aname.startswith(base + " ") else aname
            _add_allergen(allergens, code, alls[base], aname or code)
        additives = [{"code": str(a.get("id") or ""), "name": str(a.get("name") or "")} for a in tags.get("additives") or []]
        for s in tags.get("special") or []:
            n = str(s.get("name") or "")
            if "alkohol" in n.lower():
                labels.add("alkohol")
            if n and n not in notes:
                notes.append(n)
        if any(a["key"] == "fisch" for a in allergens):
            labels.add("fisch")
        p = o.get("price") or {}
        time = TIMES.get(str(o.get("time") or ""))
        meal = {"id": str(o.get("id") or f"{d}-{i}"), "name": name, "category": pretty_category((o.get("lane") or {}).get("name")),
                "time": time, "prices": {"student": _price(p.get("student")), "employee": _price(p.get("employee")),
                                         "guest": _price(p.get("guest"))},
                "allergens": allergens, "additives": additives, "notes": notes}
        per100 = (o.get("nutritional_values") or {}).get("per_100_grams") or {}
        values = {v: _number(per100.get(k)) for k, v in data["stwon_nutrition"].items()}
        cal = str(per100.get("caloric_value") or "")
        kj, kcal = re.search(r"(\d+(?:[.,]\d+)?)\s*kJ", cal), re.search(r"(\d+(?:[.,]\d+)?)\s*kcal", cal)
        values["energy_kj"] = _number(kj.group(1)) if kj else None
        values["energy_kcal"] = _number(kcal.group(1)) if kcal else None
        parts = [x.strip() for x in name.split(" | ") if x.strip()]
        climate = {"co2_g": None, "rating": None, "klimateller": True} if klimateller else None
        days.setdefault(d, []).append((time_rank.get(time or "", 1), i,
                                       _finish(meal, labels, data, _nutrition(values, "100g"), parts if len(parts) > 1 else [], climate)))
    return {"days": {d: [m for _, _, m in sorted(v, key=lambda x: (x[0], x[1]))] for d, v in sorted(days.items())}, "closed": []}


def parse_openmensa(raw: list, data: dict | None = None) -> dict:
    """GET /canteens/{id}/meals: [{date, closed, meals: [{id, name, category, prices, notes}]}]"""
    data = data or load_data()
    rules = data["openmensa_notes"]
    names = {a["key"]: a["name"] for a in data["allergens"]}
    days: dict[str, list[dict]] = {}
    closed: list[str] = []
    for day in raw or []:
        d = str(day.get("date") or "")[:10]
        if not d:
            continue
        if day.get("closed"):
            closed.append(d)
            continue
        for i, o in enumerate(day.get("meals") or []):
            name = " ".join(str(o.get("name") or "").split())
            if not name:
                continue
            labels: set[str] = set()
            allergens: list[dict] = []
            additives: list[dict] = []
            notes: list[str] = []
            for n in o.get("notes") or []:
                low = str(n).lower()
                hit = False
                for r in rules:
                    if r["match"] in low:
                        hit = True
                        labels.update(r.get("label") or [])
                        if r.get("allergen"):
                            _add_allergen(allergens, "", r["allergen"], names.get(r["allergen"], r["allergen"]))
                if hit:
                    continue
                if low.startswith(("mit ", "geschw", "gewachst", "enthält eine phenylalaninquelle")):
                    additives.append({"code": "", "name": str(n)})
                elif str(n) not in notes:
                    notes.append(str(n))
            p = o.get("prices") or {}
            meal = {"id": str(o.get("id") or f"{d}-{i}"), "name": name, "category": pretty_category(o.get("category")), "time": None,
                    "prices": {"student": _price(p.get("students")), "employee": _price(p.get("employees")),
                               "guest": _price(p.get("others"))},
                    "allergens": allergens, "additives": additives, "notes": notes}
            days.setdefault(d, []).append(_finish(meal, labels, data))
    return {"days": dict(sorted(days.items())), "closed": sorted(closed)}


def parse(kind: str, raw, data: dict | None = None) -> dict:
    return {"studifutter": parse_studifutter, "stwon": parse_stwon, "openmensa": parse_openmensa}[kind](raw, data)


# MARK: Tage

def day_status(d: str, days: dict, closed: list[str], since: str | None = None) -> str:
    """open: Speisen da; closed: ausdruecklich zu oder Luecke vor spaeteren Tagen mit Plan (nur ab `since`, dem Beginn des
    Abrufs: davor weiss niemand etwas); none: (noch) kein Plan"""
    if days.get(d):
        return "open"
    if d in closed or ((since is None or d >= since) and any(k > d and v for k, v in days.items())):
        return "closed"
    return "none"


def build_days(start: date, count: int, parsed: dict, since: str | None = None) -> list[dict]:
    out = []
    for i in range(max(1, count)):
        d = (start + timedelta(days=i)).isoformat()
        st = day_status(d, parsed["days"], parsed.get("closed") or [], since)
        out.append({"date": d, "status": st, "meals": parsed["days"].get(d, []) if st == "open" else []})
    return out


# MARK: Filter und Auswahl (gleiche Regeln in mensa-logic.js und MensaMenu.swift)

def matches(meal: dict, flt: dict | None) -> bool:
    f = flt or {}
    labels = set(meal.get("labels") or [])
    if f.get("vegan") and "vegan" not in labels:
        return False
    if f.get("vegetarisch") and "vegetarisch" not in labels:
        return False
    if f.get("ohne_schwein") and "schwein" in labels:
        return False
    avoid = set(f.get("allergens") or [])
    return not (avoid and any(a.get("key") in avoid for a in meal.get("allergens") or []))


def filter_meals(meals: list[dict], flt: dict | None) -> list[dict]:
    return [m for m in meals if matches(m, flt)]


def top_meals(meals: list[dict], n: int = 3, flt: dict | None = None) -> list[dict]:
    """Fuer die Karte "Heute in der Mensa": Hauptgerichte, die zum Filter passen, mittags vor abends"""
    main = [m for m in filter_meals(meals, flt) if m.get("main")]
    rank = {"frueh": 1, "mittag": 0, None: 0, "abend": 2}
    return sorted(main, key=lambda m: rank.get(m.get("time"), 0))[:n]


def price_for(meal: dict, role: str) -> float | None:
    return (meal.get("prices") or {}).get(role if role in ("student", "employee", "guest") else "student")


SORTS = ["line", "price", "kcal", "protein"]


def sort_meals(meals: list[dict], by: str = "line", role: str = "student") -> list[dict]:
    """Reihenfolge der Liste: line (wie die Mensa), price (guenstig zuerst, Preis der Gruppe), kcal (wenig zuerst),
    protein (viel Eiweiss zuerst); Gerichte ohne Angabe ans Ende, sonst stabil"""
    def val(m: dict) -> float | None:
        n = m.get("nutrition") or {}
        if by == "price":
            return price_for(m, role)
        if by == "kcal":
            return n.get("energy_kcal")
        if by == "protein":
            return None if n.get("protein") is None else -n["protein"]
        return 0.0
    keyed = [(val(m), i, m) for i, m in enumerate(meals or [])]
    return [m for v, i, m in sorted(keyed, key=lambda x: (x[0] is None, x[0] or 0.0, x[1]))]


# MARK: Abruf und Cache

def current_time() -> datetime:
    """Uhr fuer Abruf und Cache (Tests ersetzen sie)"""
    return datetime.now(BERLIN)


def http_get(url: str, timeout: float = 10.0) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310 - feste https-Adressen aus mensa.json
        return r.read()


def cache_dir() -> Path:
    from . import config
    p = Path(config.BASE_DATA_DIR) / "mensa"
    p.mkdir(parents=True, exist_ok=True)
    return p


def _lock(cid: str) -> threading.Lock:
    with _LOCKS_GUARD:
        return _LOCKS.setdefault(cid, threading.Lock())


def _read_cache(cid: str, folder: Path) -> dict | None:
    try:
        return json.loads((folder / f"{cid}.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def merge_cache(old: dict | None, parsed: dict, start: date, end: date, source: str, now: datetime) -> dict:
    """Neue Tage ersetzen das Fenster; aeltere Tage (bis 7 Tage zurueck) bleiben fuer "ohne Netz" erhalten"""
    keep_from = (now.date() - timedelta(days=KEEP_PAST_DAYS)).isoformat()
    s, e = start.isoformat(), end.isoformat()
    days = {d: v for d, v in ((old or {}).get("days") or {}).items() if d >= keep_from and not (s <= d <= e)}
    closed = [d for d in ((old or {}).get("closed") or []) if d >= keep_from and not (s <= d <= e)]
    days.update({d: v for d, v in parsed["days"].items() if s <= d <= e})
    closed += [d for d in parsed.get("closed") or [] if s <= d <= e]
    return {"v": CACHE_VERSION, "fetched_at": now.isoformat(timespec="seconds"), "window": [s, e], "source": source,
            "days": dict(sorted(days.items())), "closed": sorted(set(closed))}


def is_fresh(cache: dict | None, wanted_start: date, wanted_end: date, now: datetime) -> bool:
    if not cache or cache.get("v") != CACHE_VERSION:
        return False
    try:
        at = datetime.fromisoformat(cache["fetched_at"])
        ws, we = (date.fromisoformat(x) for x in cache["window"])
    except (KeyError, ValueError, TypeError):
        return False
    return at.date() == now.date() and (now - at).total_seconds() < FRESH_SECONDS and ws <= wanted_start and wanted_end <= we


def fetch(c: dict, start: date, end: date, get=None, data: dict | None = None) -> tuple[dict, str]:
    """Quelle der Mensa, bei Fehler OpenMensa (falls vorhanden). Wirft, wenn beides scheitert."""
    data = data or load_data()
    get = get or http_get
    kinds = [c["source"]["kind"]] + (["openmensa"] if c.get("openmensa") and c["source"]["kind"] != "openmensa" else [])
    last: Exception | None = None
    for kind in kinds:
        try:
            raw = json.loads(get(source_url(c, start, end, kind, data)))
            parsed = parse(kind, raw, data)
            if kind != "openmensa" and not parsed["days"] and len(kinds) > 1:
                last = ValueError("leer")
                continue
            return parsed, kind
        except Exception as e:  # noqa: BLE001 - Netz, HTTP, JSON: naechste Quelle
            last = e
    raise RuntimeError(str(last or "keine Quelle"))


def menu(cid: str, day: date | None = None, days: int = 1, now: datetime | None = None, get=None, folder: Path | None = None,
         data: dict | None = None) -> dict:
    """Antwort von GET /api/mensa/menu"""
    data = data or load_data()
    now = now or current_time()
    today = now.date()
    c = canteen(cid, data)
    if not c:
        raise KeyError(cid)
    day = day or today
    days = max(1, min(int(days or 1), WINDOW_DAYS))
    want_end = day + timedelta(days=days - 1)
    folder = folder or cache_dir()
    with _lock(cid):
        cache = _read_cache(cid, folder)
        stale, message = False, None
        if not is_fresh(cache, day, want_end, now) and day >= today - timedelta(days=KEEP_PAST_DAYS):
            ws, we = window(today, day)
            try:
                parsed, kind = fetch(c, ws, we, get, data)
                cache = merge_cache(cache, parsed, ws, we, kind, now)
                try:
                    (folder / f"{cid}.json").write_text(json.dumps(cache, ensure_ascii=False), encoding="utf-8")
                except OSError:
                    pass
            except Exception:  # noqa: BLE001
                stale = True
                message = ("Keine Verbindung zum Speiseplan. Du siehst den zuletzt geladenen Stand."
                           if cache else "Der Speiseplan ist gerade nicht erreichbar. Versuche es später erneut.")
    cache = cache or {"days": {}, "closed": [], "source": c["source"]["kind"], "fetched_at": None}
    src = data["sources"][cache.get("source") or c["source"]["kind"]]
    return {"canteen": public_canteen(c, None, data),
            "days": build_days(day, days, {"days": cache.get("days") or {}, "closed": cache.get("closed") or []},
                               (cache.get("window") or [None])[0]),
            "source": {"key": cache.get("source") or c["source"]["kind"], "name": src["name"], "url": src["url"],
                       "attribution": src["attribution"]},
            "fetched_at": cache.get("fetched_at"), "stale": stale, "message": message}

"""Mensa (docs/MENSA-2026-11-05.md): Leser der drei Quellen mit gespeicherten Antworten (Studi|Futter, STW-ON-Mensa-API,
OpenMensa), Status je Tag, Filter und Auswahl fuer die Uebersicht, Abruf mit Cache, Ersatzquelle und "ohne Netz", Routen
/api/mensa/canteens und /api/mensa/menu. Nie eine echte Anfrage: der Abruf ist immer ersetzt."""
import importlib.util
import json
import subprocess
import sys
from datetime import date, datetime, timedelta
from pathlib import Path

import pytest
from conftest import asgi_call

from app import mensa

ROOT = Path(__file__).resolve().parents[1]
FX = ROOT / "packages" / "shared-contracts" / "fixtures" / "mensa"
NOW = datetime(2026, 11, 5, 11, 0, tzinfo=mensa.BERLIN)


def raw(name):
    return (FX / "raw" / name).read_bytes()


def _gen():
    spec = importlib.util.spec_from_file_location("gen_mensa", ROOT / "tools" / "gen-mensa-fixture.py")
    mod = importlib.util.module_from_spec(spec)
    sys.path.insert(0, str(ROOT / "tools"))
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture(autouse=True)
def no_network(monkeypatch):
    def boom(url, timeout=10.0):
        raise AssertionError(f"Netz im Test: {url}")
    monkeypatch.setattr(mensa, "http_get", boom)


def test_fixture_is_current():
    r = subprocess.run([sys.executable, "tools/gen-mensa-fixture.py", "--check"], cwd=ROOT, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


def test_data_file_is_valid():
    d = mensa.load_data()
    assert _gen().check_data(d) == []
    by_uni = {u: [c["id"] for c in d["canteens"] if u in c["universities"]] for u in d["universities"]}
    assert by_uni["luh"] == ["hauptmensa", "contine", "garbsen", "herrenhausen"]
    assert by_uni["hsh"] == ["linden", "grosse-pause", "blumhardt"]
    assert by_uni["hildesheim"] == ["hi-uni", "hi-buehler"]
    assert all(c["openmensa"] for c in d["canteens"] if c["source"]["kind"] == "studifutter"), "Ersatzquelle fuer Hannover"


def test_studifutter_garbsen():
    p = mensa.parse("studifutter", json.loads(raw("studifutter-garbsen.json")))
    assert list(p["days"]) == ["2026-11-05", "2026-11-06", "2026-11-09"]
    day = p["days"]["2026-11-05"]
    curry = next(m for m in day if m["name"].startswith("Gemüse-Kichererbsen-Curry"))
    assert curry["category"] == "Veggie & Vegan" and curry["main"]
    assert curry["prices"] == {"student": 2.5, "employee": 6.3, "guest": 7.9}
    assert curry["labels"] == ["vegan", "vegetarisch"]
    assert "Niedersachsen-Menü" in curry["notes"]
    chili = next(m for m in day if m["name"].startswith("Chili con Carne"))
    assert chili["labels"] == ["fleisch", "rind"]
    assert {a["key"] for a in chili["allergens"]} >= {"gluten", "milch", "sesam"}
    assert next(a for a in chili["allergens"] if a["key"] == "gluten")["name"] == "Weizen"
    salad = next(m for m in day if m["name"] == "Brechbohnensalat")
    assert salad["category"] == "Querbeet" and not salad["main"], "Beilagen und Salate nicht in der Auswahl"
    assert day[0]["category"] == "Pasta & Friends", "Reihenfolge der Menuelinien aus der Quelle"


def test_stwon_hildesheim():
    p = mensa.parse("stwon", json.loads(raw("stwon-hi-uni.json")))
    day = p["days"]["2026-11-05"]
    risotto = day[0]
    assert risotto["name"] == "Winterliches Dinkel Risotto | Obst" and risotto["time"] == "mittag"
    assert risotto["category"] == "Essen 1" and risotto["prices"]["student"] == 2.5
    assert risotto["allergens"] == [{"code": "GL5", "key": "gluten", "name": "enthält Dinkel (eine Weizenart)"}], "GL entfaellt neben GL5"
    assert risotto["additives"] == [{"code": "7", "name": "gewachst"}]
    gulasch = next(m for m in day if m["name"].startswith("Schweinegulasch"))
    assert gulasch["labels"] == ["fleisch", "schwein"]
    assert [m["time"] for m in day] == sorted([m["time"] for m in day], key=lambda t: {"mittag": 1, "abend": 2}[t]), "mittags vor abends"
    assert not next(m for m in day if m["category"] == "Beilage")["main"]
    fish = [m for d in p["days"].values() for m in d if "fisch" in m["labels"]]
    assert fish and all("vegetarisch" not in m["labels"] for m in fish)


def test_openmensa_fallback_format():
    p = mensa.parse("openmensa", json.loads(raw("openmensa-hauptmensa.json")))
    assert p["closed"] == ["2026-11-07"]
    day = p["days"]["2026-11-05"]
    schnitzel = next(m for m in day if "Schweineschnitzel" in m["name"])
    assert schnitzel["labels"] == ["fleisch", "schwein"]
    assert {a["key"] for a in schnitzel["allergens"]} == {"ei", "milch", "sellerie"}
    assert schnitzel["prices"] == {"student": 4.8, "employee": 6.0, "guest": 7.8}
    yog = next(m for m in day if m["name"].startswith("Schlemmerjoghurt"))
    assert yog["labels"] == ["vegetarisch"] and yog["category"] == "Süße Ecke" and not yog["main"]


def test_day_status_and_filters():
    sf = mensa.parse("studifutter", json.loads(raw("studifutter-garbsen.json")))
    st = [d["status"] for d in mensa.build_days(date(2026, 11, 5), 7, sf, "2026-11-05")]
    assert st == ["open", "open", "closed", "closed", "open", "none", "none"], "Wochenende zu, nach dem Plan unbekannt"
    meals = sf["days"]["2026-11-05"]
    assert all("vegan" in m["labels"] for m in mensa.filter_meals(meals, {"vegan": True}))
    assert all("schwein" not in m["labels"] for m in mensa.filter_meals(meals, {"ohne_schwein": True}))
    no_gluten = mensa.filter_meals(meals, {"allergens": ["gluten"]})
    assert no_gluten and all(all(a["key"] != "gluten" for a in m["allergens"]) for m in no_gluten)
    top = mensa.top_meals(meals, 3)
    assert len(top) == 3 and all(m["main"] for m in top)
    assert mensa.price_for(top[0], "guest") == top[0]["prices"]["guest"]
    assert mensa.price_for(top[0], "unsinn") == top[0]["prices"]["student"]


def test_canteens_per_university():
    r = mensa.canteens_response("hildesheim")
    assert r["default"] == "hi-uni" and r["canteens"][0]["id"] == "hi-uni" and r["canteens"][0]["own"]
    assert [x["key"] for x in r["roles"]] == ["student", "employee", "guest"]
    assert mensa.canteens_response("hsh")["default"] == "linden"
    assert mensa.canteens_response("gibtsnicht")["default"] == "hauptmensa"
    assert all("source" in c and "hours" in c for c in r["canteens"])


# MARK: Abruf und Cache

def fake_get(responses, calls):
    def get(url, timeout=10.0):
        calls.append(url)
        for prefix, body in responses:
            if url.startswith(prefix):
                if isinstance(body, Exception):
                    raise body
                return body
        raise OSError("kein Netz")
    return get


SF = "https://studi-futter.rocket-meals.de/"
OM = "https://openmensa.org/"
ON = "https://sls.api.stw-on.de/"


def test_menu_fetches_once_and_caches(tmp_path):
    calls = []
    get = fake_get([(SF, raw("studifutter-garbsen.json"))], calls)
    r = mensa.menu("garbsen", date(2026, 11, 5), 7, now=NOW, get=get, folder=tmp_path)
    assert len(calls) == 1 and "_between" in calls[0] and "2026-11-18" in calls[0], "ein Abruf fuer 14 Tage"
    assert [d["status"] for d in r["days"]][:5] == ["open", "open", "closed", "closed", "open"]
    assert r["source"]["key"] == "studifutter" and not r["stale"] and r["fetched_at"].startswith("2026-11-05T11:00")
    assert r["canteen"]["id"] == "garbsen" and r["canteen"]["hours"]
    # gleicher Tag, eine Stunde spaeter: aus dem Cache
    r2 = mensa.menu("garbsen", date(2026, 11, 6), 1, now=NOW + timedelta(hours=1), get=get, folder=tmp_path)
    assert len(calls) == 1 and r2["days"][0]["status"] == "open"
    # vier Stunden spaeter: neu
    mensa.menu("garbsen", date(2026, 11, 5), 1, now=NOW + timedelta(hours=4), get=get, folder=tmp_path)
    assert len(calls) == 2


def test_menu_falls_back_to_openmensa(tmp_path):
    calls = []
    get = fake_get([(SF, OSError("weg")), (OM, raw("openmensa-hauptmensa.json"))], calls)
    r = mensa.menu("hauptmensa", date(2026, 11, 5), 3, now=NOW, get=get, folder=tmp_path)
    assert [c[:len(OM)] == OM for c in calls] == [False, True]
    assert r["source"]["key"] == "openmensa" and r["source"]["name"] == "OpenMensa"
    assert [d["status"] for d in r["days"]] == ["open", "open", "closed"]


def test_menu_offline_shows_last_state(tmp_path):
    calls = []
    mensa.menu("hi-uni", date(2026, 11, 5), 1, now=NOW, get=fake_get([(ON, raw("stwon-hi-uni.json"))], calls), folder=tmp_path)
    assert calls == ["https://sls.api.stw-on.de/v1/locations/150/menu/2026-11-05/2026-11-18"]
    later = NOW + timedelta(days=1)
    r = mensa.menu("hi-uni", date(2026, 11, 6), 1, now=later, get=fake_get([], calls), folder=tmp_path)
    assert r["stale"] and "zuletzt geladenen Stand" in r["message"]
    assert r["days"][0]["status"] == "open" and r["days"][0]["meals"]
    # ohne Cache und ohne Netz: ehrliche Meldung, kein Absturz
    r = mensa.menu("hi-buehler", date(2026, 11, 6), 1, now=later, get=fake_get([], calls), folder=tmp_path)
    assert r["stale"] and r["days"][0]["status"] == "none" and "nicht erreichbar" in r["message"]


def test_cache_keeps_recent_days_only(tmp_path):
    old = {"days": {"2026-10-01": [{"id": "alt"}], "2026-11-01": [{"id": "x"}]}, "closed": ["2026-10-02"]}
    sf = mensa.parse("studifutter", json.loads(raw("studifutter-garbsen.json")))
    c = mensa.merge_cache(old, sf, date(2026, 11, 5), date(2026, 11, 18), "studifutter", NOW)
    assert "2026-10-01" not in c["days"] and "2026-11-01" in c["days"] and c["closed"] == []
    assert c["window"] == ["2026-11-05", "2026-11-18"]


# MARK: Routen

def _get(path):
    from app.server import app
    status, _, body = asgi_call(app, "GET", path)
    return status, json.loads(body or b"null")


def test_routes(monkeypatch, tmp_path):
    monkeypatch.setattr(mensa, "cache_dir", lambda: tmp_path)
    monkeypatch.setattr(mensa, "current_time", lambda: NOW)
    calls = []
    monkeypatch.setattr(mensa, "http_get", fake_get([(ON, raw("stwon-hi-uni.json"))], calls))
    status, body = _get("/api/mensa/canteens?university=hildesheim")
    assert status == 200 and body["default"] == "hi-uni" and len(body["canteens"]) == 13
    assert {a["key"] for a in body["allergens"]} >= {"gluten", "milch", "ei", "schalenfruechte"}
    status, body = _get("/api/mensa/menu?canteen=hi-uni&date=2026-11-05&days=2")
    assert status == 200 and [d["date"] for d in body["days"]] == ["2026-11-05", "2026-11-06"]
    assert body["source"]["attribution"].startswith("Speiseplan: Studierendenwerk OstNiedersachsen")
    assert _get("/api/mensa/menu?canteen=gibtsnicht")[0] == 404
    assert _get("/api/mensa/menu?canteen=hi-uni&date=05.11.2026")[0] == 400


# MARK: Naehrwerte, Bestandteile, Klima, Sortierung (Wunsch des Inhabers 05.11.2026)

def test_nutrition_components_climate_hannover():
    p = mensa.parse("studifutter", json.loads(raw("studifutter-garbsen.json")))
    chili = next(m for m in p["days"]["2026-11-05"] if m["name"].startswith("Chili con Carne"))
    assert chili["nutrition"] == {"basis": "portion", "energy_kj": None, "energy_kcal": 811.0, "fat": 35.2, "saturated_fat": 15.9,
                                  "carbohydrates": 62.2, "sugar": 12.5, "fiber": None, "protein": 53.6, "salt": 5.3}
    assert chili["components"] == ["Chili con Carne", "Fladenbrot", "wahlweise mit Schmand"]
    assert chili["climate"] == {"co2_g": 2174.0, "rating": None, "klimateller": False}
    salad = next(m for m in p["days"]["2026-11-05"] if m["name"] == "Brechbohnensalat")
    assert salad["components"] == [] and salad["nutrition"]["energy_kcal"] == 72.0


def test_nutrition_hildesheim_per_100g():
    p = mensa.parse("stwon", json.loads(raw("stwon-hi-uni.json")))
    risotto = p["days"]["2026-11-05"][0]
    assert risotto["nutrition"] == {"basis": "100g", "energy_kj": 388.0, "energy_kcal": 93.0, "fat": 2.7, "saturated_fat": 0.2,
                                    "carbohydrates": 12.6, "sugar": 2.0, "fiber": 0.0, "protein": 3.3, "salt": 0.6}
    assert risotto["components"] == ["Winterliches Dinkel Risotto", "Obst"]
    assert mensa._nutrition({}, "100g") is None, "ohne Werte: Keine Nährwertangaben vom Studentenwerk"
    om = mensa.parse("openmensa", json.loads(raw("openmensa-hauptmensa.json")))
    assert all(m["nutrition"] is None and m["components"] == [] for m in om["days"]["2026-11-05"])


def test_sort_meals():
    meals = mensa.parse("studifutter", json.loads(raw("studifutter-garbsen.json")))["days"]["2026-11-05"]
    by_price = mensa.sort_meals(meals, "price", "student")
    prices = [m["prices"]["student"] for m in by_price]
    assert prices == sorted(prices)
    kcal = [m["nutrition"]["energy_kcal"] for m in mensa.sort_meals(meals, "kcal")]
    assert kcal == sorted(kcal)
    protein = [m["nutrition"]["protein"] for m in mensa.sort_meals(meals, "protein")]
    assert protein == sorted(protein, reverse=True)
    assert mensa.sort_meals(meals, "line") == meals
    om = mensa.parse("openmensa", json.loads(raw("openmensa-hauptmensa.json")))["days"]["2026-11-05"]
    assert mensa.sort_meals(om, "kcal") == om, "ohne Naehrwerte bleibt die Reihenfolge"

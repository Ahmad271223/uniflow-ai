"""Raumfinder (docs/RAUMFINDER-2026-11-05.md): Zerlegen von Raumangaben, vereinheitlichte Treffer des Standortfinders
(gespeicherte Antworten 05.11.2026), Auswahl, Aufloesen mit Cache und "ohne Netz", Kartenlinks, CSRF-Wiederholung und die
Routen /api/rooms/search, /api/rooms/resolve, /api/rooms/campuses. Nie eine echte Anfrage: der Abruf ist immer ersetzt."""
import io
import json
import subprocess
import sys
import urllib.error
from datetime import datetime, timedelta
from pathlib import Path
from urllib.parse import quote

import pytest
from conftest import asgi_call

from app import rooms

ROOT = Path(__file__).resolve().parents[1]
FX = ROOT / "packages" / "shared-contracts" / "fixtures" / "rooms"
CASES = json.loads((FX / "cases.json").read_text(encoding="utf-8"))
AT = datetime(2026, 11, 5, 12, 0, tzinfo=rooms.BERLIN)


def raw(name):
    return json.loads((FX / "raw" / name).read_text(encoding="utf-8"))


def fake(calls=None):
    def search(term, page=0):
        if calls is not None:
            calls.append(term)
        return raw(CASES["raw_map"].get(" ".join(term.split()).casefold(), "search-leer.json"))
    return search


@pytest.fixture(autouse=True)
def no_network(monkeypatch):
    def boom(*a, **k):
        raise AssertionError("Netz im Test")
    monkeypatch.setattr(rooms, "_post", boom)
    monkeypatch.setattr(rooms, "_fresh_token", boom)


def test_fixture_is_current():
    r = subprocess.run([sys.executable, "tools/gen-rooms-fixture.py", "--check"], cwd=ROOT, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


def test_parse_patterns():
    by = {(c["text"], c["university"]): c["result"] for c in CASES["parse"]}
    p = lambda t, u="luh": by[(t, u)]["parts"]  # noqa: E731
    assert [(x["room"], x["building"]) for x in p("1101 - F102")] == [("F102", "1101")]
    assert [(x["room"], x["building"]) for x in p("F102 (1101)")] == [("F102", "1101")]
    assert [(x["room"], x["building"]) for x in p("Gebäude 3403, Raum A003")] == [("A003", "3403")]
    assert [(x["room"], x["building"], x["building_name"]) for x in p("Hauptgebäude, F142")] == [("F142", "1101", "Hauptgebäude")]
    assert [(x["room"], x["building"], x["floor"]) for x in p("1101.001.F102")] == [("F102", "1101", "001")]
    assert [x["room"] for x in p("Hörsaal F 303 · Hörsaal F 102")] == ["F303", "F102"]
    assert p("Hauptgebäude Herrenhausen, A003")[0]["building"] == "4105"
    assert p("Gebäude 1101, Raum 029")[0]["room"] == "029"
    assert p("Termin 2026, Raum F102")[0]["building"] is None, "Jahreszahl ist kein Gebaeude"
    assert not p("Seminarraum")[0]["linkable"] and not p("Raum C")[0]["linkable"]
    assert p("Online")[0]["online"] and p("Online / Raum F102")[0]["linkable"]
    assert by[("", "luh")]["parts"] == [] and not by[("", "luh")]["linkable"]
    assert p("1H.1.01", "hsh")[0]["campus"] == "linden"
    assert p("Hörsaal 1 / Hauptgebäude - Hs 1 (Hauptcampus)", "hildesheim")[0]["campus"] == "hauptcampus"
    assert p("Raum 12", "hsh")[0]["linkable"] and p("Raum 12", "hsh")[0]["campus"] is None
    assert by[("F102", "unbekannt")]["university"] == "luh"


def test_cases_match_python():
    for c in CASES["parse"]:
        assert rooms.parse(c["text"], c["university"]) == c["result"], c["text"]
    for name, places in CASES["places"].items():
        assert [rooms.place(i) for i in raw(name)["data"]] == places, name
    for c in CASES["crafted"]:
        assert rooms.place(c["item"]) == c["place"]


def test_place_fields():
    f102 = CASES["places"]["search-f102.json"][0]
    assert f102["title"] == "Raum F102" and f102["floor_label"] == "1. Obergeschoss" and f102["position_ok"]
    assert f102["maps"]["google"] == "https://www.google.com/maps/search/?api=1&query=52.38255%2C9.71785"
    assert f102["maps"]["google_route"] == "https://www.google.com/maps/dir/?api=1&destination=52.38255%2C9.71785&travelmode=walking"
    assert f102["maps"]["google_app"] == "comgooglemaps://?q=52.38255%2C9.71785"
    assert f102["maps"]["google_app_route"] == "comgooglemaps://?daddr=52.38255%2C9.71785&directionsmode=walking"
    assert f102["floorplan_url"].startswith("https://info.cafm.uni-hannover.de/")
    # Position ungenau: Adresse statt Koordinaten, Barrierefreiheit mit Status, unsichere Links verworfen
    t = CASES["crafted"][0]["place"]
    assert not t["position_ok"] and t["maps"]["query"] == "Teststraße 1, 30167 Hannover"
    assert [(r["key"], r["status"]) for r in t["accessibility"]["building"]] == [
        ("parking_spaces", "vorhanden"), ("access", "eingeschränkt"), ("elevator", "nicht vorhanden"), ("orientation", None)]
    assert t["accessibility"]["room"][1] == {"key": "wheelchair", "title": "Plätze für Rollstuhlnutzende", "status": None, "text": "4"}
    assert t["floorplan_url"] is None and t["floor_label"] == "1. Untergeschoss"
    fac = CASES["crafted"][1]["place"]
    assert fac["opening_hours_url"] is None and fac["website"] == "https://www.example.org/"
    assert fac["maps"]["query"] == "Einrichtung ohne Gebäude, Leibniz Universität Hannover"


def test_choose_and_resolve(tmp_path):
    for c in CASES["choose"]:
        part = rooms.parse(c["text"])["parts"][0]
        st, hits = rooms.choose(part, raw(c["fixture"])["data"])
        assert {"status": st, "ids": [i["item_id"] for i in hits]} == c["result"], c["text"]
    for i, c in enumerate(CASES["resolve"]):
        assert rooms.resolve(c["text"], c["university"], fake(), tmp_path / f"c{i}.json", AT) == c["result"], c["text"]
    st = {c["text"]: [p["status"] for p in c["result"]["parts"]] for c in CASES["resolve"]}
    assert st["1101 - F102"] == ["found"] and st["A003"] == ["ambiguous"] and st["Gebäude 1101, Raum Z999"] == ["building"]
    assert st["Hörsaal F 303 · Raum E214"] == ["not_found", "found"] and st["Seminarraum"] == ["unknown"]
    assert st["1H.1.01"] == ["campus"] and st["Raum 12"] == ["search"] and st["online"] == ["online"]


def test_cache_and_offline(tmp_path):
    calls = []
    path = tmp_path / "cache.json"
    rooms.resolve("1101 - F102", "luh", fake(calls), path, AT)
    rooms.resolve("F102 (1101)", "luh", fake(calls), path, AT + timedelta(days=29))
    assert calls == ["F102"], "30 Tage aus dem Cache"
    rooms.resolve("F102", "luh", fake(calls), path, AT + timedelta(days=31))
    assert calls == ["F102", "F102"]
    # nichts gefunden: nur einen Tag gemerkt
    rooms.resolve("Z999", "luh", fake(calls), path, AT)
    rooms.resolve("Z999", "luh", fake(calls), path, AT + timedelta(hours=23))
    rooms.resolve("Z999", "luh", fake(calls), path, AT + timedelta(days=2))
    assert calls.count("Z999") == 2

    def offline(term, page=0):
        raise OSError("kein Netz")
    r = rooms.resolve("F102", "luh", offline, path, AT + timedelta(days=90))
    assert r["stale"] and r["parts"][0]["status"] == "found" and "zuletzt geladenen" in r["message"]
    r = rooms.resolve("E214", "luh", offline, path, AT)
    assert r["parts"][0]["status"] == "offline" and r["parts"][0]["maps"]["query"] == "Leibniz Universität Hannover E214"
    for c in CASES["offline"]:
        assert c["result"]["parts"][0]["maps"] is not None
    # Seminarraum: ohne Raumnummer keine Anfrage, auch ohne Netz kein Hinweis
    assert rooms.resolve("Seminarraum", "luh", offline, path, AT)["stale"] is False


def test_search_cases(tmp_path):
    for i, c in enumerate(CASES["search"]):
        fn = (lambda t, p=0: (_ for _ in ()).throw(OSError("x"))) if c.get("offline") else fake()
        assert rooms.search(c["q"], c["page"], fn, tmp_path / f"s{i}.json", AT) == c["result"], c["q"]
    a = next(c["result"] for c in CASES["search"] if c["q"] == "A003")
    assert a["count"] == 16 and a["pages"] == 1 and len(a["items"]) == 16
    assert next(c["result"] for c in CASES["search"] if c["q"] == "")["items"] == []


def test_maps_and_helpers():
    m = CASES["maps"][0]
    assert m["google"] == "https://www.google.com/maps/search/?api=1&query=Welfengarten%201%2C%2030167%20Hannover"
    assert m["apple"] == "https://maps.apple.com/?q=Welfengarten%201%2C%2030167%20Hannover"
    assert CASES["maps"][2]["query"] == "52.38,9.72272"
    assert CASES["floors"] == {"000": "Erdgeschoss", "001": "1. Obergeschoss", "002": "2. Obergeschoss", "011": "11. Obergeschoss",
                               "-01": "1. Untergeschoss", "U1": "Etage U1", "": None, "4": "4. Obergeschoss"}
    assert CASES["enc"]["Straße"] == quote("Straße", safe="") == "Stra%C3%9Fe"
    assert len(CASES["segments"]["1 · 2 · 3 · 4 · 5"]) == 4 and CASES["segments"]["A / B"] == ["A / B"]


def test_campuses():
    hsh = CASES["campuses"]["hsh"]
    assert not hsh["finder"] and hsh["note"] == "Ort laut Hochschule; genaue Lage ohne Gewähr"
    assert [c["id"] for c in hsh["campuses"]] == ["hsh:linden", "hsh:expo", "hsh:kleefeld", "hsh:ahlem"]
    assert hsh["campuses"][0]["maps"]["query"] == "Hochschule Hannover, Ricklinger Stadtweg 120, 30459 Hannover"
    assert CASES["campuses"]["luh"]["finder"] and CASES["campuses"]["unbekannt"]["university"] == "luh"


class _Resp(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def test_csrf_retry(monkeypatch):
    """403 -> Token von der Startseite holen und einmal neu schicken (X-CSRFToken und Cookie)"""
    sent = []

    def post(url, form, token, timeout):
        sent.append((url, dict(form), token))
        if token is None:
            raise urllib.error.HTTPError(url, 403, "Forbidden", {}, None)
        return json.dumps(raw("search-f102.json")).encode()
    monkeypatch.setattr(rooms, "_post", post)
    monkeypatch.setattr(rooms, "_fresh_token", lambda timeout: "tok123")
    monkeypatch.setitem(rooms._SESSION, "token", None)
    r = rooms.http_search("F102")
    assert r["count"] == 1
    assert sent == [("https://standortfinder.uni-hannover.de/search", {"search": "F102", "page": "0"}, None),
                    ("https://standortfinder.uni-hannover.de/search", {"search": "F102", "page": "0"}, "tok123")]
    rooms.http_search("E214")
    assert sent[-1][2] == "tok123", "Token gilt fuer die Sitzung"


# MARK: Routen

def _get(path):
    from app.server import app
    status, _, body = asgi_call(app, "GET", path)
    return status, json.loads(body or b"null")


def test_routes(monkeypatch, tmp_path):
    calls = []
    monkeypatch.setattr(rooms, "http_search", fake(calls))
    monkeypatch.setattr(rooms, "cache_path", lambda: tmp_path / "cache.json")
    status, body = _get("/api/rooms/search?q=F102")
    assert status == 200 and body["items"][0]["id"] == "1101.001.F102" and body["source"]["key"] == "standortfinder"
    status, body = _get("/api/rooms/resolve?text=" + quote("1101 - F102") + "&university=luh")
    assert status == 200 and body["parts"][0]["status"] == "found"
    assert body["parts"][0]["maps"]["google_route"].endswith("&travelmode=walking")
    status, body = _get("/api/rooms/resolve?text=" + quote("1H.1.01") + "&university=hsh")
    assert body["parts"][0]["status"] == "campus" and body["source"] is None
    status, body = _get("/api/rooms/campuses?university=hildesheim")
    assert status == 200 and len(body["campuses"]) == 4
    assert _get("/api/rooms/search")[1]["items"] == []
    assert calls == ["F102"]

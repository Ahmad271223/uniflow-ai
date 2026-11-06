"""Raumfinder (docs/RAUMFINDER-2026-11-05.md): Datendatei pruefen, Kopie im Swift-Kern und gemeinsame Faelle schreiben.

Quelle der Wahrheit: packages/shared-contracts/rooms.json (Standortfinder der LUH, Standorte von HsH und Uni Hildesheim,
Gebaeudenamen der LUH, Barrierefreiheits-Felder). Das Werkzeug
- prueft die Datei (nur https, eindeutige Standorte, gueltige Ausdruecke, Gebaeudenummern vierstellig),
- schreibt apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/Rooms/RoomsData.swift (woertlich),
- schreibt packages/shared-contracts/fixtures/rooms/cases.json mit app/rooms.py: Zerlegen von Raumangaben (LUH, HsH,
  Hildesheim), vereinheitlichte Treffer aus den gespeicherten Antworten des Standortfinders (fixtures/rooms/raw, gelesen
  05.11.2026), Auswahl, Aufloesen ganzer Angaben (Suche ersetzt durch die gespeicherten Antworten, ohne Netz),
  Kartenlinks, Etagen, Standorte je Hochschule. Swift-Kern (RoomsTests) und node (tests/js/rooms.test.mjs) pruefen
  dieselben Faelle. Laedt nie etwas aus dem Netz.

Aufruf im Projektordner: .venv/bin/python tools/gen-rooms-fixture.py [--check]
"""
from __future__ import annotations

import json
import re
import sys
import tempfile
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from schema_source import ROOT, write_or_check  # noqa: E402

from app import rooms  # noqa: E402

DATA = ROOT / "packages" / "shared-contracts" / "rooms.json"
SWIFT = ROOT / "apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/Rooms/RoomsData.swift"
FX = ROOT / "packages" / "shared-contracts" / "fixtures" / "rooms"
CASES = FX / "cases.json"
AT = datetime(2026, 11, 5, 12, 0, tzinfo=rooms.BERLIN)

# Suchbegriff (klein) -> gespeicherte Antwort; alles andere: keine Treffer (search-leer.json)
RAW = {"f102": "search-f102.json", "1101": "search-1101.json", "hauptgebäude": "search-hauptgebaeude.json",
       "bibliothek": "search-bibliothek.json", "e214": "search-e214.json", "a003": "search-a003.json",
       "3403": "search-3403.json", "audimax": "search-audimax.json"}

PARSE = [
    ("F102", "luh"), ("1101 - F102", "luh"), ("F102 (1101)", "luh"), ("F102 (Geb. 1101)", "luh"),
    ("Gebäude 3403, Raum A003", "luh"), ("Hauptgebäude, F142", "luh"), ("1101.001.F102", "luh"),
    ("Raum 1101-E214", "luh"), ("Raum E214: Großer Physiksaal", "luh"), ("Hörsaal E 214", "luh"),
    ("Hörsaal F 303 · Hörsaal F 102", "luh"), ("Raum F303: Testsaal · Raum 031: e-Classroom · Raum F102", "luh"),
    ("Hauptgebäude Herrenhausen, A003", "luh"), ("Gebäude 1101, Raum 029", "luh"), ("3403", "luh"),
    ("Lessinghaus", "luh"), ("Testgebäude 7 - TG.7.0.01 (Seminarraum)", "luh"), ("Seminarraum", "luh"),
    ("Raum C", "luh"), ("Pool 1", "luh"), ("Online", "luh"), ("Online (Zoom)", "luh"), ("Online / Raum F102", "luh"),
    ("Termin 2026, Raum F102", "luh"), ("", "luh"), ("   ", "luh"), ("P 101, Haus 2", "luh"), ("1101/F102; 3403 - A003", "luh"),
    ("1H.1.01", "hsh"), ("1H.0.12", "hsh"), ("Expo Plaza, Raum 2.1.03", "hsh"), ("Campus Kleefeld 3.05", "hsh"),
    ("Heisterbergallee, Hörsaal", "hsh"), ("Raum 12", "hsh"), ("Zoom", "hsh"),
    ("Hörsaal 1 / Hauptgebäude - Hs 1 (Hauptcampus)", "hildesheim"), ("Bühler-Campus 2.01", "hildesheim"),
    ("Domäne Marienburg, Hohes Haus", "hildesheim"), ("Samelsonplatz 1, Raum 102", "hildesheim"),
    ("Gebäude T (Testcampus) - TC.T.1.01 (Kleiner Testraum)", "hildesheim"), ("online", "hildesheim"),
    ("F102", "unbekannt"),
]

RESOLVE = [
    ("1101 - F102", "luh"), ("F102", "luh"), ("A003", "luh"), ("Gebäude 3403, Raum A003", "luh"), ("Raum 1101-E214", "luh"),
    ("Hauptgebäude, E214", "luh"), ("Hauptgebäude Herrenhausen, A003", "luh"), ("Gebäude 1101, Raum Z999", "luh"),
    ("Hörsaal F 303 · Raum E214", "luh"), ("3403", "luh"), ("Seminarraum", "luh"), ("Online", "luh"),
    ("Bibliotheksgebäude", "luh"), ("", "luh"),
    ("1H.1.01", "hsh"), ("Raum 12", "hsh"), ("Hörsaal 1 / Hauptgebäude - Hs 1 (Hauptcampus)", "hildesheim"),
    ("Bühler-Campus 2.01", "hildesheim"), ("online", "hildesheim"),
]


def check_data(d: dict) -> list[str]:
    errs: list[str] = []
    if d.get("v") != 1:
        errs.append("v")
    sf = d.get("standortfinder", {})
    for k in ("url", "search"):
        if not str(sf.get(k, "")).startswith("https://"):
            errs.append(f"standortfinder.{k}")
    for u, x in d.get("universities", {}).items():
        ids = [c.get("id") for c in x.get("campuses", [])]
        if len(set(ids)) != len(ids) or not ids:
            errs.append(f"universities.{u}: campuses")
        for c in x.get("campuses", []):
            if not str(c.get("source", "")).startswith("https://"):
                errs.append(f"universities.{u}.{c.get('id')}: source")
            if not c.get("address") or not c.get("match"):
                errs.append(f"universities.{u}.{c.get('id')}: address/match")
            if any(w != w.lower() for w in c.get("match", [])):
                errs.append(f"universities.{u}.{c.get('id')}: match klein schreiben")
            if c.get("codes"):
                try:
                    re.compile(c["codes"])
                except re.error:
                    errs.append(f"universities.{u}.{c.get('id')}: codes")
    if "luh" not in d.get("universities", {}):
        errs.append("universities.luh")
    for b in d.get("luh_buildings", []):
        if not re.fullmatch(r"\d{4}", b.get("id", "")) or not b.get("name"):
            errs.append(f"luh_buildings.{b.get('name')}")
    return errs


def swift_text(raw: str) -> str:
    if '"""#' in raw:
        raise ValueError("Datendatei enthaelt das Ende eines Swift-Rohtexts")
    return ("// Erzeugt von tools/gen-rooms-fixture.py aus packages/shared-contracts/rooms.json - nicht von Hand aendern.\n"
            "enum RoomsData {\n    static let json = #\"\"\"\n" + raw.rstrip("\n") + "\n\"\"\"#\n}\n")


# Erfundener Treffer mit Angaben zur Barrierefreiheit und ungenauer Position (die gespeicherten Antworten haben keine;
# die Felder stammen aus map.js des Standortfinders: createBFBuildingInfoTable / createBFRoomInfoTable)
CRAFTED = [
    {"item_type": 1, "item_id": "9999.000.T001", "room_id": "9999.000.T001", "room_nr": "T001", "room_name": "Testraum",
     "building_id": "9999", "building_name": "Testgebäude", "floor_nr": "-01", "street": "Teststraße", "house_number": "1",
     "zip_code": "30167", "city": "Hannover", "lat": 52.1, "lon": 9.1, "is_position_correct": False,
     "room_floorplan_url": "http://unsicher.example/plan", "room_url": "https://info.cafm.uni-hannover.de/de/room/9999.000.T001",
     "building_url": None, "extra_info": None,
     "bf_building_info": {"parking_spaces_available": "BF_YES", "parking_spaces_description": "Zwei Plätze am Eingang",
                          "bf_access_building_available": "BF_RESTRICTED", "bf_access_building_description": "Rampe an der Seite",
                          "bf_elevator_available": "BF_NO", "bf_elevator_description": "", "bf_toilet_available": None,
                          "bf_toilet_description": None, "orientation": "Leitsystem im Foyer", "rest_rooms": ""},
     "bf_room_info": {"bf_access_room_available": "BF_YES", "bf_access_room_description": None, "wheelchair_places": "4",
                      "supportive_acoustics": None}},
    {"item_type": 3, "item_id": "einrichtung-ohne-gebaeude", "item_name": "Einrichtung ohne Gebäude", "building_id": None,
     "street": "", "house_number": "", "zip_code": "", "city": "", "lat": 52.38255, "lon": 9.71785, "is_position_correct": False,
     "extra_info": {"description_de": "Beschreibung", "website_link": "https://www.example.org/", "opening_hours_link": "javascript:alert(1)"}},
    {"item_type": "lr01", "item_id": "lr-1", "building_id": "1101", "building_name": "Hauptgebäude", "street": "Welfengarten",
     "house_number": "1", "zip_code": "30167", "city": "Hannover", "lat": "52.3", "lon": None, "is_position_correct": True},
]


def raw(name: str) -> dict:
    return json.loads((FX / "raw" / name).read_text(encoding="utf-8"))


def fake_search(term: str, page: int = 0) -> dict:
    return raw(RAW.get(" ".join(term.split()).lower(), "search-leer.json"))


def offline(term: str, page: int = 0) -> dict:
    raise OSError("kein Netz")


def cases(d: dict) -> dict:
    with tempfile.TemporaryDirectory() as tmp:
        def fresh(i: int) -> Path:
            return Path(tmp) / f"cache-{i}.json"
        res = [{"text": t, "university": u, "result": rooms.resolve(t, u, fake_search, fresh(i), AT)}
               for i, (t, u) in enumerate(RESOLVE)]
        off = [{"text": t, "result": rooms.resolve(t, "luh", offline, fresh(100 + i), AT)} for i, t in enumerate(["1101 - F102", "Seminarraum"])]
        # erst mit Netz in den Cache, dann ohne Netz: alter Stand, stale
        p = fresh(200)
        rooms.resolve("F102", "luh", fake_search, p, AT)
        off.append({"text": "F102 (Cache)", "result": rooms.resolve("F102", "luh", offline, p, AT.replace(year=2027))})
        search = [{"q": q, "page": pg, "result": rooms.search(q, pg, fake_search, fresh(300 + i), AT)}
                  for i, (q, pg) in enumerate([("F102", 0), ("A003", 0), ("Bibliothek", 0), ("zzqqxx", 0), ("", 0), ("  E214 ", 0)])]
        search.append({"q": "F102", "page": 0, "offline": True, "result": rooms.search("F102", 0, offline, fresh(400), AT)})
    return {
        "at": AT.isoformat(),
        "raw_map": RAW,
        "parse": [{"text": t, "university": u, "result": rooms.parse(t, u, d)} for t, u in PARSE],
        "places": {name: [rooms.place(i, d) for i in raw(name)["data"]] for name in sorted(set(RAW.values()))},
        "crafted": [{"item": i, "place": rooms.place(i, d)} for i in CRAFTED],
        "choose": [{"text": t, "fixture": RAW.get((rooms.parse(t)["parts"][0]["query"] or "").lower(), "search-leer.json"),
                    "result": (lambda st_c: {"status": st_c[0], "ids": [i["item_id"] for i in st_c[1]]})(
                        rooms.choose(rooms.parse(t)["parts"][0], fake_search(rooms.parse(t)["parts"][0]["query"] or "")["data"]))}
                   for t in ["F102", "1101 - F102", "A003", "Gebäude 3403, Raum A003", "Hauptgebäude Herrenhausen, A003",
                             "Lessinghaus, A003", "3403", "1101", "Raum Z999", "Hauptgebäude, E214"]],
        "resolve": res,
        "offline": off,
        "search": search,
        "maps": [rooms.maps("Welfengarten 1, 30167 Hannover", "Hauptgebäude"),
                 rooms.maps("", "Raum F102", 52.38255, 9.71785),
                 rooms.maps("", "Kesselhaus", 52.38, 9.72272),
                 rooms.maps("Hochschule Hannover 1H.1.01 & Co / Süd", None)],
        "floors": {f: rooms.floor_label(f) for f in ["000", "001", "002", "011", "-01", "U1", "", "4"]},
        "coords": {str(x): rooms.coord(x) for x in [52.38255, 9.71785, 52.38, 9.704, 52.0, 9.123456789]},
        "enc": {s: rooms.enc(s) for s in ["Welfengarten 1, 30167 Hannover", "Königsworther Platz 1B", "a/b?c=d&e", "~._-", "Straße"]},
        "segments": {t: rooms.segments(t) for t in ["A · B", "A;B", "A | B", "A\nB", "A / B", "1 · 2 · 3 · 4 · 5", "  "]},
        "campuses": {u: rooms.campuses(u) for u in ["luh", "hsh", "hildesheim", "unbekannt"]},
    }


def main() -> int:
    check = "--check" in sys.argv[1:]
    text = DATA.read_text(encoding="utf-8")
    d = json.loads(text)
    errs = check_data(d)
    if errs:
        print("FEHLER in der Datendatei:\n  " + "\n  ".join(errs), file=sys.stderr)
        return 1
    ok = write_or_check(SWIFT, swift_text(text), check)
    ok = write_or_check(CASES, json.dumps(cases(d), ensure_ascii=False, indent=1) + "\n", check) and ok
    return 1 if check and not ok else 0


if __name__ == "__main__":
    sys.exit(main())

"""Modulkatalog (app/study_catalog.py, docs/STUDIENVERLAUF-2026-11-04.md): erfundene PDF im Aufbau der LUH-Kataloge
(tools/gen-study-catalog-fixture.py), Zeilen-Normalisierung, Parser, Validator, Register und Schluessel gegen die
gemeinsame Fixture (der Swift-Kern prueft dieselben Dateien), lokale Tabellen, Abgleich mit Attrappe statt Netz,
eigener Link, Endpunkt GET /api/study-catalog/status. Kein echtes Netz, kein echter Katalog."""
import hashlib
import json
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]
FX = ROOT / "packages" / "shared-contracts" / "fixtures" / "study-catalog"
PRIMARY = "https://modkat.fei.uni-hannover.de/material/modkat-full-TIBSc25-WS_2026_27.pdf"
MIRROR = "https://modkat.fei.uni-hannover.de/material/modkat-TIBSc25-WS_2026_27.pdf"
OLD_MIRROR = "https://modkat.fei.uni-hannover.de/material/modkat-TIBSc22-WS_2025_26.pdf"
PLAN_URL = ("https://www.fei.uni-hannover.de/fileadmin/fei/Dateien-Studium/Studiengaenge_Technische_Informatik/B.Sc/"
            "Studienverlaufsplan_Bachelor_Technische_Informatik_WS2026-27.pdf")
NOW = datetime(2026, 11, 4, 9, 0, tzinfo=timezone.utc)


def _j(name):
    return json.loads((FX / name).read_text(encoding="utf-8"))


def test_fixture_is_current():
    r = subprocess.run([sys.executable, "tools/gen-study-catalog-fixture.py", "--check"], cwd=ROOT, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


def test_pdf_lines_and_parser_byte_equal():
    from app import study_catalog as sc
    pdf = (FX / "modkat-sample.pdf").read_bytes()
    pages = sc.pdf_pages(pdf)
    assert [sc.normalize_lines(p) for p in pages] == _j("pages.json")
    exp = _j("expected.json")
    assert hashlib.sha256(pdf).hexdigest() == exp["meta"]["source"]["sha256"]
    catalog, texts = sc.parse_luh_modkat(pages, exp["meta"])
    assert sc.dumps(catalog) == exp["dumps"]
    assert sc.dumps(texts) == exp["texts_dumps"]
    assert sc.catalog_key(catalog) == exp["key"] == sc.library_key("luh", "TIBSc22", "WS 2025/26")
    assert sc.validate(catalog) == []
    # Spec: Fakten ohne lange Texte, Texte nur lokal
    assert "Variablen, Schleifen" not in sc.dumps(catalog) and "Variablen, Schleifen" in sc.dumps(texts)
    by = {m["id"]: m for m in catalog["modules"]}
    assert by["beispielprogrammierung-1"]["turnus"] == "WS" and by["beispielprogrammierung-2"]["turnus"] == "SS"
    assert by["beispielprogrammierung-2"]["prerequisites"] == ["beispielprogrammierung-1"]
    assert by["proseminar-beispielthemen"]["semester"] == 4 and by["proseminar-beispielthemen"]["kind"] == "wahlpflicht"
    assert by["bachelorarbeit"]["kind"] == "abschluss"


def test_text_cases():
    from app import study_catalog as sc
    cases = _j("text-cases.json")
    for c in cases["normalize"]:
        assert sc.normalize_lines(c["text"]) == c["lines"]
    for c in cases["slug"]:
        assert sc.slug(c["text"]) == c["slug"]
    assert sc.normalize_lines("Pﬂicht") == ["Pflicht"]
    assert sc.slug("Programmieren I") == "programmieren-1"


def test_validator_cases():
    from app import study_catalog as sc
    for c in _j("validator-cases.json"):
        assert sc.validate(c["catalog"]) == c["errors"], c["name"]
    assert sc.validate([]) == [": type"]


def test_registry_cases_and_schema_file():
    from app import study_catalog as sc
    reg = sc.load_registry()
    cases = _j("registry-cases.json")
    for c in cases["matches"]:
        assert sc.match_program(c["label"], "luh", reg, c["po"]) == c["result"], c["label"]
    for c in cases["keys"]:
        assert sc.library_key(c["university"], c["code"], c["term"]) == c["key"]
    for c in cases["urls"]:
        assert sc.source_urls(reg, "luh", c["code"], c["term"]) == c["urls"]
    for c in cases["terms"]:
        assert sc.candidate_terms(reg, "luh", c["code"], c["today"]) == c["terms"]
    for c in cases["study_plans"]:
        assert (sc.study_plan_source(reg, "luh", c["code"]) or {}).get("url") == c["url"]
    for c in cases["modkat_parts"]:
        assert (list(sc.modkat_parts(c["url"]) or []) or None) == c["parts"]
    m = sc.match_program("Technische Informatik (PO-Version 2017)")
    assert m["code"] == "TIBSc25" and m["needs_confirmation"] is True
    schema = json.loads((ROOT / "packages/shared-contracts/study-catalog.schema.json").read_text(encoding="utf-8"))
    assert set(schema["required"]) <= set(_j("expected.json")["catalog"])
    assert schema["$defs"]["kind"]["enum"] == list(sc.KINDS)
    assert schema["$defs"]["module"]["properties"]["turnus"]["enum"] == list(sc.TURNUS)
    # Register: Kuerzel je Studiengang eindeutig (im gemischten Register teilen sich Studiengaenge einen Katalog, z. B.
    # ETMSc17), im gepflegten Teil ueberall eindeutig, nur https
    codes = [po["code"] for u in reg["universities"] for p in u["programs"] for po in p["pos"]]
    assert all(codes) and {"TIBSc25", "TIBSc22", "INFBSc22"} <= set(codes)
    for u in reg["universities"]:
        for p in u["programs"]:
            own = [po["code"] for po in p["pos"]]
            assert len(own) == len(set(own)), p["id"]
    curated = json.loads(sc.REGISTRY_PATH.read_text(encoding="utf-8"))
    cc = [po["code"] for u in curated["universities"] for p in u["programs"] for po in p["pos"]]
    assert len(cc) == len(set(cc))
    assert "modkat.dbs" not in json.dumps(reg)
    # gemischtes Register = study-sources.json + study-sources-luh.json, gepflegte Eintraege vorn
    luh = json.loads(sc.LUH_REGISTRY_PATH.read_text(encoding="utf-8"))
    assert reg == json.loads(sc.FULL_REGISTRY_PATH.read_text(encoding="utf-8"))
    merged = sc.merge_luh_registry(curated, luh)
    assert merged["universities"][0]["programs"] == reg["universities"][0]["programs"]
    progs = reg["universities"][0]["programs"]
    assert [p["id"] for p in progs[:2]] == ["technische-informatik-bsc", "informatik-bsc"]
    assert len({p["id"] for p in progs}) == len(progs)
    assert set(schema["properties"]) >= {"study_plan", "plan_slots"}


class Stub:
    def __init__(self, responses):
        self.responses = responses
        self.calls = []

    def __call__(self, url, etag=None, last_modified=None):
        from app import study_catalog as sc
        self.calls.append((url, etag))
        r = self.responses.get(url)
        return r if r else sc.FetchResult(404, error="HTTP 404")


def _conn(label="Technische Informatik (PO-Version 2017)", settings=None):
    import sqlite3
    from app import study_catalog as sc
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    conn.executescript("CREATE TABLE grades (id INTEGER PRIMARY KEY, text TEXT, abschluss TEXT);"
                       "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT);")
    conn.execute("INSERT INTO settings VALUES ('university', 'luh')")
    if label:
        conn.execute("INSERT INTO grades(text, abschluss) VALUES ('Programmieren I', ?)", (label,))
    if settings is not None:
        conn.execute("INSERT INTO settings VALUES ('study_plan', ?)", (json.dumps(settings),))
    assert sc.status(conn)["state"] == "idle"
    return conn


def test_sync_download_mirror_local_retry():
    from app import study_catalog as sc
    pdf = (FX / "modkat-sample.pdf").read_bytes()
    conn = _conn()
    fetch = Stub({MIRROR: sc.FetchResult(200, pdf, etag='"e1"')})
    s = sc.run_sync(conn, fetch, NOW)
    assert s["state"] == "ready" and s["origin"] == "download" and s["modules"] == 6, s
    assert s["catalog_term"] == "WS 2026/27" and s["needs_confirmation"] is True
    assert [u for u, _ in fetch.calls if "WS_2026_27" in u] == [PRIMARY, MIRROR]
    assert s["study_plan"]["state"] == "missing", "Verlaufsplan 404: gemerkt, Katalog trotzdem fertig"
    key = sc.library_key("luh", "TIBSc25", "WS 2026/27")
    assert sc.get_catalog(conn, key)["modules"][0]["id"] == "beispielprogrammierung-1"
    n = len(fetch.calls)
    assert sc.run_sync(conn, fetch, NOW)["origin"] == "local" and len(fetch.calls) == n, "zweiter Lauf ohne Anfrage"
    assert sc.status(conn)["state"] == "ready"
    # erzwungen: fehlende Adressen bleiben gemerkt, Spiegel mit ETag
    sc.run_sync(conn, fetch, NOW, force=True)
    assert fetch.calls[-1] == (MIRROR, '"e1"')
    assert not any(u in (PRIMARY, PLAN_URL) for u, _ in fetch.calls[n:])


def test_sync_error_retried_after_24h_and_no_program():
    from app import study_catalog as sc
    conn = _conn()
    fetch = Stub({PRIMARY: sc.FetchResult(0, error="offline"), MIRROR: sc.FetchResult(503, error="HTTP 503")})
    s = sc.run_sync(conn, fetch, NOW)
    assert s["state"] == "error" and "24 Stunden" in s["message"]
    n = len(fetch.calls)
    sc.run_sync(conn, fetch, NOW + timedelta(hours=1))
    assert len(fetch.calls) == n
    fetch.responses[MIRROR] = sc.FetchResult(200, (FX / "modkat-sample.pdf").read_bytes())
    assert sc.run_sync(conn, fetch, NOW + timedelta(hours=25))["state"] == "ready"
    assert sc.run_sync(_conn(label=None), Stub({}), NOW)["reason"] == "no_program"
    assert sc.run_sync(_conn(label="Musterfach (PO-Version 2017)"), Stub({}), NOW)["message"] == sc.MESSAGES["not_found"]


def test_sync_custom_link_and_confirmed_po():
    from app import study_catalog as sc
    link = "https://example.org/handbuch.pdf"
    conn = _conn(label="Musterfach (PO-Version 2017)", settings={"po": "TIBSc22", "catalog_url": link})
    s = sc.run_sync(conn, Stub({link: sc.FetchResult(200, b"kein pdf")}), NOW)
    assert s["reason"] == "unknown_format" and s["message"] == sc.MESSAGES["unknown_format"]
    ok = sc.run_sync(conn, Stub({link: sc.FetchResult(200, (FX / "modkat-sample.pdf").read_bytes())}), NOW, force=True)
    assert ok["state"] == "ready" and ok["program"] == "Technische Informatik" and ok["catalog_term"] == "WS 2025/26"
    assert sc.clean_catalog_url("http://x.de/a.pdf") is None and sc.clean_catalog_url("https://x.de/" + "a" * 600) is None
    assert sc.modkat_parts(PRIMARY) == ("TIBSc25", "WS 2026/27")
    conn.execute("UPDATE settings SET value=? WHERE key='study_plan'", (json.dumps({"po": "TIBSc22"}),))
    po = sc.run_sync(conn, Stub({OLD_MIRROR: sc.FetchResult(200, (FX / "modkat-sample.pdf").read_bytes())}), NOW)
    assert po["code"] == "TIBSc22" and po["state"] == "ready"


def test_full_format_parser_byte_equal():
    """Neuere Form (modkat-full): Bereiche aus den Tabellen, Module alphabetisch, neue Ueberschriften"""
    from app import study_catalog as sc
    pdf = (FX / "modkat-full-sample.pdf").read_bytes()
    pages = sc.pdf_pages(pdf)
    assert [sc.normalize_lines(p) for p in pages] == _j("pages-full.json")
    exp = _j("expected-full.json")
    catalog, texts = sc.parse_luh_modkat(pages, exp["meta"])
    assert sc.dumps(catalog) == exp["dumps"] and sc.dumps(texts) == exp["texts_dumps"]
    by = {m["id"]: m for m in catalog["modules"]}
    assert [a["id"] for a in catalog["areas"]] == ["grundlagen-muster", "vertiefung-muster"], "Kapitel sind keine Bereiche"
    assert by["proseminar-musterthemen"]["area"] == "vertiefung-muster", "Tabellenzeile zerrissen: Bereich ueber das Kuerzel der Einordnung"
    assert by["musterlehre-1"]["turnus"] == "WS" and by["musterlehre-1"]["lp"] == 5 and by["musterlehre-1"]["exam"] == "Klausur"
    assert "Muster und Beispiele" in texts["musterlehre-1"]["content"]


def test_study_plan_parser_and_merge():
    from app import study_catalog as sc
    pdf = (FX / "plan-sample.pdf").read_bytes()
    exp = _j("plan-expected.json")
    assert sc.pdf_items(pdf) == _j("plan-items.json")
    plan = sc.parse_study_plan(_j("plan-items.json"))
    assert sc.dumps(plan) == exp["plan_dumps"]
    assert hashlib.sha256(pdf).hexdigest() == exp["source"]["sha256"]
    catalog = _j("expected.json")["catalog"]
    merged, unmatched = sc.merge_study_plan(catalog, plan, exp["source"])
    assert sc.dumps(merged) == exp["catalog_dumps"] and unmatched == exp["unmatched"]
    assert sc.validate(merged) == []
    by = {m["id"]: m for m in merged["modules"]}
    assert by["beispielprogrammierung-2"]["semester"] == 2, "Trennstrich am Zeilenende"
    assert by["bachelorarbeit"]["semester"] == 6, "Tippfehler und 'inkl. Kolloquium'"
    assert by["studium-beispiel-angebote-anderer-fakultaeten-und-einrichtungen"]["semester"] == 4, "Titel und LP in einer Zeile"
    assert unmatched == ["Einführung in Beispielwerkzeuge"]
    assert {(s["semester"], s["lp"], s["lp_max"]) for s in merged["plan_slots"]} >= {(3, 3, 6), (5, 5, None)}
    assert catalog.get("plan_slots") is None, "Eingabe unveraendert"
    for c in exp["merge_cases"]:
        got, um = sc.merge_study_plan(json.loads(c["catalog_dumps"]), json.loads(c["plan_dumps"]))
        assert sc.dumps(got) == c["dumps"] and um == c["unmatched"], c["name"]


def test_sync_fetches_study_plan_once_and_merges():
    from app import study_catalog as sc
    pdf = (FX / "modkat-sample.pdf").read_bytes()
    plan_pdf = (FX / "plan-sample.pdf").read_bytes()
    conn = _conn()
    fetch = Stub({MIRROR: sc.FetchResult(200, pdf, etag='"e1"'), PLAN_URL: sc.FetchResult(503, error="HTTP 503")})
    s = sc.run_sync(conn, fetch, NOW)
    assert s["state"] == "ready" and s["study_plan"]["state"] == "error", s
    key = sc.library_key("luh", "TIBSc25", "WS 2026/27")
    assert "plan_slots" not in sc.get_catalog(conn, key)
    n = len(fetch.calls)
    assert sc.run_sync(conn, fetch, NOW + timedelta(hours=1))["study_plan"]["state"] == "error"
    assert len(fetch.calls) == n, "Verlaufsplan erst nach 24 Stunden erneut"
    fetch.responses[PLAN_URL] = sc.FetchResult(200, plan_pdf, etag='"p1"')
    later = sc.run_sync(conn, fetch, NOW + timedelta(hours=25))
    assert later["origin"] == "local" and later["study_plan"]["state"] == "merged", later
    assert later["study_plan"]["unmatched"] == ["Einführung in Beispielwerkzeuge"]
    cat = sc.get_catalog(conn, key)
    assert cat["study_plan"]["url"] == PLAN_URL and len(cat["plan_slots"]) == later["study_plan"]["slots"] == 5
    assert {m["id"]: m["semester"] for m in cat["modules"]}["beispielprogrammierung-2"] == 2
    assert sc.validate(cat) == []
    # gemischt: kein weiterer Abruf; erzwungen: Katalog und Plan bedingt (ETag), Plan aus dem Speicher bei 304
    m = len(fetch.calls)
    assert "study_plan" not in sc.run_sync(conn, fetch, NOW + timedelta(hours=26)) and len(fetch.calls) == m
    fetch.responses[PLAN_URL] = sc.FetchResult(304)
    forced = sc.run_sync(conn, fetch, NOW + timedelta(hours=27), force=True)
    assert forced["study_plan"]["state"] == "merged" and (PLAN_URL, '"p1"') in fetch.calls[m:]
    assert sc.dumps(sc.get_catalog(conn, key)["plan_slots"]) == sc.dumps(cat["plan_slots"])


def test_status_endpoint_and_settings_catalog_url(app):
    st, _, b = asgi_call(app, "GET", "/api/study-catalog/status")
    assert st == 200 and json.loads(b)["state"] in ("idle", "ready", "error", "not_found")
    st, _, b = asgi_call(app, "POST", "/api/study-plan/settings", body=json.dumps({"catalog_url": "http://unsicher.example/x.pdf"}))
    assert st == 400
    st, _, b = asgi_call(app, "POST", "/api/study-plan/settings", body=json.dumps({"catalog_url": " https://example.org/mhb.pdf "}))
    assert st == 200 and json.loads(b)["catalog_url"] == "https://example.org/mhb.pdf"
    st, _, b = asgi_call(app, "POST", "/api/study-plan/settings", body=json.dumps({"catalog_url": ""}))
    assert st == 200 and "catalog_url" not in json.loads(b)

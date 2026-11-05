"""Studienverlauf im Web und in der Windows-App (05.11.2026): Ausloeser der Katalogsuche (GET /api/study-catalog/status, POST
/sync), Grundstock und Register im Paket (Windows-Spec, Docker), Register zum Waehlen (GET /api/study-catalog/programs), Modultexte
nachladen und die Pruefung des mitgelieferten Grundstocks auf kopierte Texte. Kein echtes Netz: `FETCH` ist eine Attrappe, die
bei jedem Aufruf laut scheitert. Alle Werte aus dem erfundenen Fixture oder dem Grundstock (nur Fakten)."""
import json
import re
import time
from datetime import date, datetime, timezone
from pathlib import Path

import pytest

from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]
FX = ROOT / "packages" / "shared-contracts" / "fixtures" / "study-catalog"
NOW = datetime(2026, 11, 4, 9, 0, tzinfo=timezone.utc)
TI_LABEL = "Technische Informatik (PO-Version 2017)"


class NoNetwork:
    """Attrappe fuer das Laden: jeder Aufruf ist ein Fehler des Tests"""

    def __init__(self):
        self.calls = []

    def __call__(self, url, etag=None, last_modified=None):
        self.calls.append(url)
        raise AssertionError(f"echtes Netz in einem Test: {url}")


@pytest.fixture()
def fresh(app, tmp_path, monkeypatch):
    from app import db, study, study_catalog as sc
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "web.db")
    db.init_db()
    monkeypatch.setattr(study, "today", lambda: date(2026, 11, 4))
    net = NoNetwork()
    monkeypatch.setattr(sc, "FETCH", net)
    monkeypatch.setattr(sc, "AUTO_SYNC", True)
    sc._active.clear()
    yield app, net
    sc._active.clear()


def _grade(label=TI_LABEL, text="Programmieren I", status="bestanden", semester="WiSe 25/26", note="1,7"):
    from app import db
    with db.cursor() as conn:
        conn.execute("INSERT INTO grades(pruefungsnr, text, semester, note, status, credits, versuch, datum, abschluss) VALUES (?,?,?,?,?,?,?,?,?)",
                     ("1001", text, semester, note, status, "5", "1", "2026-02-10", label))


def _call(app, method, path, body=None):
    st, _, raw = asgi_call(app, method, path, body=json.dumps(body) if body is not None else None)
    return st, json.loads(raw) if raw else None


def _wait(app, want, tries=100):
    """Status abfragen, bis er nicht mehr 'searching' ist (Hintergrundlauf)"""
    for _ in range(tries):
        st, s = _call(app, "GET", "/api/study-catalog/status")
        assert st == 200
        if s["state"] != "searching":
            return s
        time.sleep(0.05)
    raise AssertionError("Suche kam nicht zum Ende")


# ---------------------------------------------------------------- Ausloeser

def test_status_starts_search_from_seed_without_network(fresh):
    """Erster Aufruf: Stand 'searching' sofort, im Hintergrund aus dem Grundstock (0 Downloads), danach ist der Plan da"""
    app, net = fresh
    _grade()
    st, first = _call(app, "GET", "/api/study-catalog/status")
    assert st == 200 and first["state"] == "searching" and first["message"].startswith("StudiNow sucht")
    done = _wait(app, "seed")
    assert done["state"] == "seed" and done["origin"] == "seed" and done["code"] == "TIBSc25", done
    assert done["message"] == "Aus dem StudiNow-Grundstock" and done["modules"] == 85
    assert done["needs_confirmation"] is True and done["suggested_po"] == "2025"
    assert net.calls == [], "der Grundstock braucht keinen Download"
    st, plan = _call(app, "GET", "/api/study-plan")
    assert plan["available"] is True and plan["program"] == "Technische Informatik" and plan["po"] == "2025"
    assert plan["suggested_po"] == "2025" and plan["po_confirmed"] is False, "PO nur vorgeschlagen: die Seite fragt nach"
    assert len(plan["semesters"]) >= 6 and plan["lp_total"] > 0
    assert any(m["status"] == "bestanden" for s in plan["semesters"] for m in s["modules"]), "QIS-Note zaehlt"


def test_status_does_not_search_again_unless_inputs_change(fresh):
    from app import db, study_catalog as sc
    app, net = fresh
    _grade()
    _call(app, "GET", "/api/study-catalog/status")
    first = _wait(app, "seed")
    inputs = first["inputs"]
    assert json.loads(inputs) == [TI_LABEL, None, None]
    # unveraendert: keine neue Suche (Stand bleibt, kein 'searching')
    st, again = _call(app, "GET", "/api/study-catalog/status")
    assert again["state"] == "seed" and again["checked_at"] == first["checked_at"]
    with db.cursor() as conn:
        assert sc.due(conn, NOW) is False
    # PO gewaehlt -> Eingaben geaendert -> neue Suche
    st, _ = _call(app, "POST", "/api/study-plan/settings", {"po": "TIBSc22"})
    assert st == 200
    with db.cursor() as conn:
        assert sc.due(conn, datetime.now(timezone.utc)) is True
    st, s = _call(app, "GET", "/api/study-catalog/status")
    assert s["state"] == "searching"
    done = _wait(app, "x")
    assert json.loads(done["inputs"]) == [TI_LABEL, "TIBSc22", None]
    assert net.calls == [] or done["state"] in ("ready", "not_found", "error"), done


def test_busy_state_is_not_started_twice_and_stale_busy_is_restarted(fresh):
    from app import db, study_catalog as sc
    app, net = fresh
    with db.cursor() as conn:
        sc.set_state(conn, "status", {"state": "searching", "checked_at": sc._iso(NOW), "inputs": "[null,null,null]"})
        assert sc.due(conn, NOW) is False, "laeuft noch"
        assert sc.due(conn, datetime(2026, 11, 4, 9, 9, tzinfo=timezone.utc)) is False
        assert sc.due(conn, datetime(2026, 11, 4, 9, 11, tzinfo=timezone.utc)) is True, "aelter als 10 Minuten: abgebrochen"
        sc.set_state(conn, "status", {"state": "error", "retry_at": "2026-11-05T09:00:00Z", "checked_at": sc._iso(NOW),
                                      "inputs": sc.inputs(conn)})
        assert sc.due(conn, NOW) is False, "Fehler: erst nach 24 Stunden wieder"
        assert sc.due(conn, datetime(2026, 11, 5, 9, 1, tzinfo=timezone.utc)) is True


def test_only_one_search_per_account_at_a_time(fresh):
    from app import db, study_catalog as sc
    app, net = fresh
    _grade()
    with db.cursor() as conn:
        sc._active.add(sc._run_key())
        assert sc.maybe_start(conn, force=True, background=False) is None, "zweiter Start waehrend eines Laufs"
        sc._active.clear()
        end = sc.maybe_start(conn, force=True, background=False, now=NOW, fetch=net, seed=sc.seed_cached())
        assert end["state"] == "seed"
        assert sc._active == set(), "nach dem Lauf frei"


def test_post_sync_force_and_auto_sync_switch(fresh, monkeypatch):
    from app import study_catalog as sc
    app, net = fresh
    _grade()
    st, s = _call(app, "POST", "/api/study-catalog/sync", {"force": True})
    assert st == 200 and s["state"] == "searching"
    _wait(app, "seed")
    # ohne Hintergrund (Tests/Zeitplaene aus) bleibt der Stand ohne Lauf
    monkeypatch.setattr(sc, "AUTO_SYNC", False)
    st, s2 = _call(app, "POST", "/api/study-catalog/sync", {"force": True})
    assert s2["state"] == "seed"


def test_search_failure_is_stored_and_retried_after_24_hours(fresh):
    """Das Netz scheitert (Attrappe wirft): Stand 'error' mit Text, kein neuer Versuch vor retry_at"""
    from app import db, study_catalog as sc
    app, net = fresh
    _grade()
    with db.cursor() as conn:
        end = sc.maybe_start(conn, force=True, background=False, now=NOW, fetch=net, seed={})
    assert end["state"] == "error" and end["retry_at"] > end["checked_at"]
    assert net.calls, "ohne Grundstock versucht er zu laden"
    with db.cursor() as conn:
        assert sc.due(conn, NOW) is False


def test_no_label_is_settled_without_search_loop(fresh):
    """Ohne QIS-Studiengang: einmal 'not_found/no_program', danach keine Dauerschleife"""
    app, net = fresh
    st, first = _call(app, "GET", "/api/study-catalog/status")
    assert first["state"] == "searching"
    done = _wait(app, "x")
    assert done["state"] == "not_found" and done["reason"] == "no_program"
    st, again = _call(app, "GET", "/api/study-catalog/status")
    assert again["state"] == "not_found" and again["checked_at"] == done["checked_at"]


def test_choose_program_from_register_without_qis(fresh):
    """Studiengang aus dem Register waehlen (settings.po = Kuerzel): ohne QIS entsteht der Plan aus dem Grundstock"""
    app, net = fresh
    st, s = _call(app, "POST", "/api/study-plan/settings", {"po": "INFBSc22"})
    assert st == 200
    _call(app, "GET", "/api/study-catalog/status")
    done = _wait(app, "x")
    assert done["state"] == "seed" and done["code"] == "INFBSc22", done
    st, plan = _call(app, "GET", "/api/study-plan")
    assert plan["available"] and plan["program"] == "Informatik" and plan["po_confirmed"] is True
    assert plan["lp_done"] == 0 and len(plan["semesters"]) >= 6
    assert net.calls == []


# ---------------------------------------------------------------- Register zum Waehlen

def test_programs_endpoint_lists_register(app):
    st, r = _call(app, "GET", "/api/study-catalog/programs")
    assert st == 200 and r["count"] == len(r["programs"]) >= 200
    names = {p["program"] for p in r["programs"]}
    assert {"Technische Informatik", "Informatik"} <= names
    ti = next(p for p in r["programs"] if p["program"] == "Technische Informatik")
    assert [x["code"] for x in ti["pos"]][:2] == ["TIBSc25", "TIBSc22"] and ti["pos"][0]["loadable"] is True
    assert any(not p["pos"] for p in r["programs"]), "Studiengaenge ohne Katalog sind dabei, aber ohne PO"
    st, q = _call(app, "GET", "/api/study-catalog/programs?q=informatik")
    assert 1 <= q["count"] < r["count"] and all("informatik" in p["program"].lower() for p in q["programs"])
    from app.study_catalog import name_key
    keys = [name_key(p["program"]) for p in r["programs"]]
    assert keys == sorted(keys), "nach Name sortiert"


# ---------------------------------------------------------------- Modultexte

def _stored_ti22(conn, sc, url="https://modkat.fei.uni-hannover.de/material/modkat-full-TIBSc22-WS_2025_26.pdf"):
    exp = json.loads((FX / "expected.json").read_text(encoding="utf-8"))
    cat = dict(exp["catalog"])
    cat["source"] = dict(cat["source"], url=url)
    return sc.store_catalog(conn, cat, None, "seed", sc._iso(NOW)), cat


def test_module_texts_are_loaded_for_seed_catalog_and_stay_local(fresh):
    from app import db, study_catalog as sc, study_plan
    app, net = fresh
    pdf = (FX / "modkat-sample.pdf").read_bytes()
    calls = []

    def fetch(url, etag=None, last_modified=None):
        calls.append(url)
        return sc.FetchResult(200, pdf, "etag-1", None)

    with db.cursor() as conn:
        key, cat = _stored_ti22(conn, sc)
        assert sc.text_count(conn, key) == 0 and sc.texts_wanted(conn, key, NOW) is True
        r = sc.load_texts(conn, key, fetch, NOW)
        assert r["state"] == "loaded" and r["modules"] >= 1 and len(calls) == 1
        assert sc.text_count(conn, key) == r["modules"]
        assert sc.texts_wanted(conn, key, NOW) is False
        assert sc.load_texts(conn, key, fetch, NOW)["state"] == "have" and len(calls) == 1, "einmal je Katalog"
        # Fakten bleiben, wie sie sind: der geteilte Katalog bekommt keine Texte
        assert "Variablen, Schleifen" not in json.dumps(sc.get_catalog(conn, key))
        mod = study_plan.module_response(conn, "beispielprogrammierung-1", "2026-11-04")
        assert "Variablen, Schleifen" in json.dumps(mod["texts"]) and "texts_loading" not in mod


def test_module_texts_error_pauses_24_hours_and_missing_30_days(fresh):
    from datetime import timedelta
    from app import db, study_catalog as sc
    app, net = fresh
    with db.cursor() as conn:
        key, _ = _stored_ti22(conn, sc)
        assert sc.load_texts(conn, key, lambda *a, **k: sc.FetchResult(0, error="offline"), NOW)["state"] == "error"
        assert sc.texts_wanted(conn, key, NOW + timedelta(hours=23)) is False
        assert sc.texts_wanted(conn, key, NOW + timedelta(hours=25)) is True
        assert sc.load_texts(conn, key, lambda *a, **k: sc.FetchResult(404, error="HTTP 404"), NOW + timedelta(hours=25))["state"] == "missing"
        assert sc.texts_wanted(conn, key, NOW + timedelta(hours=25, days=29)) is False
        assert sc.texts_wanted(conn, key, NOW + timedelta(hours=25, days=31)) is True


def test_module_texts_not_for_other_formats_and_never_in_hosted_mode(fresh, monkeypatch):
    from app import config, db, study_catalog as sc
    app, net = fresh
    with db.cursor() as conn:
        key, cat = _stored_ti22(conn, sc, url="https://www.uni-hannover.de/fileadmin/luh/studium/modulhandbuch.pdf")
        assert sc.texts_wanted(conn, key, NOW) is False, "nur modkat-Links liest der PC"
        assert sc.load_texts(conn, key, net, NOW)["state"] == "unsupported" and net.calls == []
        key2, _ = _stored_ti22(conn, sc)
        sc.set_state(conn, "texts:" + key2, {})                  # Pause und 'unsupported' von oben weg
        assert sc.texts_wanted(conn, key2, NOW) is True, "am eigenen PC wuerde nachgeladen"
        monkeypatch.setattr(config, "is_hosted", lambda: True)
        assert sc.texts_wanted(conn, key2, NOW) is False, "im Dienst bleiben Modultexte aus (nur auf dem Geraet der Person)"


def test_module_route_starts_text_loading_in_background(fresh):
    from app import db, study_catalog as sc
    app, net = fresh
    pdf = (FX / "modkat-sample.pdf").read_bytes()
    monkeypatch_fetch = lambda *a, **k: sc.FetchResult(200, pdf, None, None)       # noqa: E731
    sc.FETCH = monkeypatch_fetch
    try:
        with db.cursor() as conn:
            _stored_ti22(conn, sc)
        _call(app, "POST", "/api/study-plan/settings", {"po": "TIBSc22"})
        with db.cursor() as conn:
            sc.set_state(conn, "status", {"state": "ready", "origin": "seed", "checked_at": sc._iso(NOW), "inputs": sc.inputs(conn)})
        st, m = _call(app, "GET", "/api/study-plan/module/beispielprogrammierung-1")
        assert st == 200 and m["texts"] is None and m["texts_loading"] is True
        for _ in range(100):
            st, m = _call(app, "GET", "/api/study-plan/module/beispielprogrammierung-1")
            if m["texts"]:
                break
            time.sleep(0.05)
        assert m["texts"] and "texts_loading" not in m
    finally:
        sc.FETCH = net


# ---------------------------------------------------------------- Paket: Windows-App und Dienst

def test_windows_spec_and_docker_ship_register_and_seed():
    spec = (ROOT / "apps/windows/backend/uniflow-backend.spec").read_text(encoding="utf-8")
    docker = (ROOT / "deploy/Dockerfile").read_text(encoding="utf-8")
    ignore = (ROOT / ".dockerignore").read_text(encoding="utf-8")
    from app import study_catalog as sc
    needed = [sc.FULL_REGISTRY_PATH, sc.REGISTRY_PATH, sc.SEED_DIR / "luh.json.gz"]
    for p in needed:
        rel = p.relative_to(ROOT).as_posix()
        assert p.exists(), rel
        assert p.name in spec, f"{p.name} fehlt im Windows-Paket (uniflow-backend.spec)"
        assert p.name in docker, f"{p.name} fehlt im Docker-Image (deploy/Dockerfile)"
        assert f"!{rel}" in ignore, f"{rel} wird vom Build-Kontext ausgeschlossen (.dockerignore)"
    # derselbe Unterpfad wie im Repo, sonst findet app/study_catalog.py (ROOT/...) die Dateien nicht
    assert '"packages/shared-contracts"' in spec and '"apps/apple/UniFlow/Resources/StudyCatalogSeed"' in spec
    assert "./packages/shared-contracts/" in docker and "./apps/apple/UniFlow/Resources/StudyCatalogSeed/" in docker
    assert sc.load_seed() and sc.load_registry()["universities"], "Dateien lesbar"
    # Ausnahmen stehen NACH den Ausschluessen von apps und packages (letzte Regel gilt)
    lines = [l.strip() for l in ignore.splitlines()]
    assert lines.index("apps") < lines.index("!apps/apple/UniFlow/Resources/StudyCatalogSeed/luh.json.gz")
    assert lines.index("packages") < lines.index("!packages/shared-contracts/study-sources-all.json")


# ---------------------------------------------------------------- Grundstock: nur Fakten

SEED = ROOT / "apps/apple/UniFlow/Resources/StudyCatalogSeed/luh.json.gz"
LITERATURE = re.compile(r"\bISBN\b|Verlag\b|Springer|Wiley|Oxford|Qualifikationsziele|Qualification objectives|Modulkatalog\s*[-–:]|Literatur\b", re.I)


def _seed_texts():
    for c in __import__("app.study_catalog", fromlist=["x"]).load_seed().values():
        for m in c["modules"]:
            for f in ("exam", "coursework", "title"):
                if isinstance(m.get(f), str):
                    yield c["code"], f, m[f]
        for a in c["areas"]:
            if isinstance(a.get("name"), str):
                yield c["code"], "area", a["name"]


def test_seed_has_only_facts_schema_level():
    """Das Schema verbietet Beschreibungstexte und Texte ueber 500 Zeichen; der Grundstock haelt sich daran"""
    from app import study_catalog as sc
    seed = sc.load_seed()
    assert len(seed) == 152 and sum(len(c["modules"]) for c in seed.values()) == 7227
    forbidden = {"content", "goals", "literature", "module_texts", "description", "beschreibung"}
    for c in seed.values():
        assert not (forbidden & set(c)), c["code"]
        assert sc.validate(c) == [], c["code"]
        for m in c["modules"]:
            assert not (forbidden & set(m)), (c["code"], m["id"])
            assert all(len(v) <= sc.MAX_TEXT for v in m.values() if isinstance(v, str))


@pytest.mark.xfail(strict=True, reason="Fund vom 05.11.2026: Leseprogramme haben bei etwa 70 Katalogen Literaturlisten und Absaetze "
                   "in Pruefungs-/Studienleistung und Bereichsnamen uebernommen (Hinweis an die Mac-Sitzung, build-luh-seed.py). "
                   "Wird der Grundstock bereinigt, schlaegt dieser Test als 'XPASS' an: dann xfail entfernen.")
def test_seed_exam_and_coursework_fields_are_short_facts():
    """Pruefungs- und Studienleistung sind kurze Angaben ('Klausur 90 min'), keine Absaetze oder Literaturlisten"""
    long_fields = [(code, f, len(t)) for code, f, t in _seed_texts() if f in ("exam", "coursework", "area") and len(t) > 300]
    bad = [(code, f) for code, f, t in _seed_texts() if f in ("exam", "coursework", "area") and LITERATURE.search(t)]
    assert not long_fields and not bad, f"{len(long_fields)} Felder ueber 300 Zeichen, {len(bad)} mit Literatur-/Beschreibungsmerkmalen"


def test_seed_known_findings_are_bounded():
    """Zaehlung des Funds (damit er nicht unbemerkt waechst): Felder ueber 150 Zeichen und mit Literaturmerkmalen"""
    over = sum(1 for _, f, t in _seed_texts() if f in ("exam", "coursework") and len(t) > 150)
    marked = sum(1 for _, f, t in _seed_texts() if f in ("exam", "coursework", "area") and LITERATURE.search(t))
    assert 500 <= over <= 650, over            # gemessen am 05.11.2026: 575 (70 davon ueber 300 Zeichen)
    assert 60 <= marked <= 100, marked         # gemessen am 05.11.2026: 78 in 35 Katalogen

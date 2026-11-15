"""Grundstock der Universitaet Hildesheim, wie ihn das Geraet benutzt (14.11.2026): jeder der Kataloge laedt, besteht
`validate`, gehoert zu einem Eintrag im Register und zeigt im Studienverlauf Module (im Semesterplan oder zur Wahl) und
LP. Auffaelligkeiten stehen unten als Liste; ein neuer Fund oder ein behobener aendert sie (nichts wird still
uebersprungen). Gleiche Pruefung im Kern: HildesheimSeedQualityTests.swift.
Dazu jeder Registereintrag: ueber seinen Namen zu finden und waehlbar; ohne Katalog mit ehrlichem Hinweis."""
from app import study_catalog as sc
from app import study_plan as sp

# Module ohne LP (Lesefehler des Grundstocks vom 05.11.2026: Tabellenreste wie "Themen LP", "Leistungspunkte 30",
# Querverweise wie "Modul 7.2 geöffnet für …", LP nur in Teilmodulen). Je Kuerzel die Anzahl.
KNOWN_NO_LP = {
    "inklusive-paedagogik-und-kommunikation|m.a.|unbekannt": 1,
    "politikwissenschaft-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2026": 2,
    "sportwissenschaft-mit-dem-schwerpunkt-sport-gesundheit-und-leistung-in-der-lebensspanne|m.sc.|2021": 1,
    "kunst-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2022": 1,
    "literarisches-schreiben-und-lektorieren|m.a.|2024": 2,
    "deutsch-als-zweitsprache-deutsch-als-fremdsprache|m.a.|2018": 1,
    "internationale-kommunikation-und-uebersetzen|b.a.|2024": 2,
    "internationales-informationsmanagement|b.a.|2024": 10,
    "internationales-informationsmanagement-digitale-sozialwissenschaften|b.a.|2024": 10,
    "internationales-informationsmanagement-interkulturelle-sprachwissenschaft|b.a.|2024": 10,
    "internationales-informationsmanagement-informationswissenschaft|m.a.|2024": 2,
    "internationales-informationsmanagement-informationswissenschaft-und-interkulturelle-kommunikation|b.a.|2024": 10,
    "internationales-informationsmanagement-linguistik|b.a.|2024": 10,
    "internationales-informationsmanagement-sprachwissenschaft-und-interkulturelle-kommunikation|m.a.|2024": 1,
    "medientext-und-medienuebersetzung|m.a.|2024": 8,
    "mathematik-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2025": 1,
    "physik-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2017": 1,
    "physik-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026": 1,
    "wirtschaft-plus|b.sc.|2026": 6,
}
# Kataloge ohne Semesterlage: alle Module stehen nur zur Wahl (kein leerer Plan, aber kein Semesterplan)
KNOWN_ONLY_CHOICE = {"umwelt-naturschutz-und-nachhaltigkeit|m.sc.|2021", "wirtschaftsinformatik|m.sc.|2024"}


def _catalogs():
    return [c for c in sc.load_seed().values() if c.get("university") == "hildesheim"]


def test_every_seed_catalog_loads_maps_and_shows_modules_with_lp():
    reg = sc.load_registry()
    cats = _catalogs()
    assert len(cats) >= 111
    problems, no_lp, only_choice = [], {}, set()
    for c in cats:
        code = c.get("code")
        errs = sc.validate(c)
        if errs:
            problems.append(f"{code}: validate {errs[:2]}")
        if sc.program_entry(reg, "hildesheim", code) is None:
            problems.append(f"{code}: nicht im Register")
        plan = sp.build_plan(c, [], {}, "2026-11-14")
        if not plan.get("lp_total"):
            problems.append(f"{code}: 0 LP")
        placed = sum(len(s.get("modules") or []) for s in plan.get("semesters") or [])
        choice = len(plan.get("electives") or [])
        if placed + choice == 0:
            problems.append(f"{code}: keine Module sichtbar")
        if placed == 0 and choice > 0:
            only_choice.add(code)
        n = sum(1 for m in c.get("modules") or [] if not sp.lp_of(m))
        if n:
            no_lp[code] = n
    assert problems == [], "\n".join(problems)
    assert no_lp == KNOWN_NO_LP, f"Module ohne LP geaendert: {no_lp}"
    assert only_choice == KNOWN_ONLY_CHOICE, only_choice


def test_every_register_entry_is_findable_and_selectable(app, tmp_path, monkeypatch):
    """Jeder Studiengang der Universitaet Hildesheim im Register: ueber seinen Namen zu finden; mit Katalog waehlbar
    ueber das Kuerzel, ohne Katalog ueber die ID und dann mit dem Hinweis, dass es noch keinen Modulkatalog gibt"""
    from app import db
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "register.db")
    db.init_db()
    progs = sc.programs(university="hildesheim")
    assert len(progs) >= 112
    without = [p for p in progs if not p["pos"]]
    minors = [p for p in without if p.get("kind") == "nebenfach"]
    assert len(minors) == 64, "Neben-/Begleitfaecher aus der LSF-Uebersicht"
    assert len(without) - len(minors) == 10, [p["program"] for p in without if p.get("kind") != "nebenfach"]
    for p in progs:
        assert sc.program_matches(p, p["program"]), p["program"]
        key = p["pos"][0]["code"] if p["pos"] else p["id"]
        assert sp.chosen_program_name(key, "hildesheim"), key
    with db.cursor() as conn:
        conn.execute("UPDATE settings SET value='hildesheim' WHERE key='university'")
        for p in without:
            sp.save_settings(conn, {"po": p["id"]}, "2026-11-14")
            plan = sp.plan_response(conn, "2026-11-14")
            assert plan["available"] is False
            assert plan["message"] == f"Für {p['program']} ({p['degree']}) gibt es noch keinen Modulkatalog.", plan["message"]


def test_search_fixture_is_current():
    import subprocess
    import sys
    from pathlib import Path
    r = subprocess.run([sys.executable, "tools/gen-program-search-fixture.py", "--check"], cwd=Path(__file__).resolve().parent.parent,
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


def test_lsf_overview_link_names_and_minors():
    """LSF-Uebersicht (14.11.2026): Link je Studiengang (Wochenraster, kein Studienverlauf), Schreibweisen fuer Suche,
    Begleitfach des Testkontos waehlbar"""
    progs = sc.programs(university="hildesheim")
    ew = next(p for p in progs if p["program"] == "Erziehungswissenschaft" and p["degree"] == "B.A.")
    assert "B.A. Erziehungswissenschaft" in ew["lsf_names"]
    plan = sp.lsf_plan("erziehungswissenschaft|b.a.|2023", "hildesheim")
    assert plan["url"].endswith("idval=174&purge=n&getglobal=n") and plan["label"] == "Veranstaltungen dieses Semesters im LSF"
    bwl = [p for p in progs if p.get("kind") == "nebenfach" and sc.program_matches(p, "Betriebswirtschaftslehre Begleitfach")]
    assert bwl and not bwl[0]["pos"], [p["program"] for p in bwl]
    assert sp.lsf_plan(bwl[0]["id"], "hildesheim")["url"].startswith("https://lsf.uni-hildesheim.de/")
    assert sp.lsf_plan("gibt-es-nicht", "hildesheim") is None

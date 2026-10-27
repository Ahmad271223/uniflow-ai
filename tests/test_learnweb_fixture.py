"""Fixture fuer die Hochschul-Anmeldung auf dem Geraet (fixtures/learnweb/launch.json) entspricht der Python-Referenz;
Swift und Kotlin pruefen dieselbe Datei (Anmeldeprofile, Moodle-App-Anmeldung, Download mit Schluessel, Cookies)."""
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "packages" / "shared-contracts" / "fixtures" / "learnweb" / "launch.json"


def _tool():
    spec = importlib.util.spec_from_file_location("gen_learnweb_fixture", ROOT / "tools" / "gen-learnweb-fixture.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_learnweb_fixture_matches_python():
    built = _tool().build()
    stored = json.loads(FIXTURE.read_text(encoding="utf-8"))
    assert built == stored, "python tools/gen-learnweb-fixture.py neu ausfuehren"


def test_learnweb_fixture_rules_hold():
    from app import learnweb
    fx = json.loads(FIXTURE.read_text(encoding="utf-8"))
    launch = fx["launch"]
    assert launch["url"].startswith(launch["base"]) and "urlscheme=uniflow" in launch["url"] and "passport=" in launch["url"]
    ok = [c for c in fx["token_cases"] if c["expect"]]
    assert len(ok) == 3 and all(learnweb.parse_launch_token(c["redirect"], launch["base"], launch["passport"]) == c["expect"] for c in fx["token_cases"])
    d = fx["download_with_token"]
    assert d["request"]["method"] == "POST" and d["request"]["form"] == {"token": d["token"]} and "token" not in d["request"]["url"].split("?")[-1]
    for key in ("luh", "hildesheim"):
        p = fx["profiles"][key]
        assert p["login_url"].startswith("https://") and p["session_cookie"] and p["file_host"] in p["hosts"]
    assert fx["profiles"]["hildesheim"]["learnweb_base"] and fx["profiles"]["luh"]["learnweb_base"] is None

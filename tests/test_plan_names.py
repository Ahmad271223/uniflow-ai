"""Kurznamen enger Kalenderbloecke: app/static/plan-names.js gegen die gemeinsamen Faelle in
packages/shared-contracts/fixtures/plan-names/cases.json (dieselben prueft PlanNamesTests im Swift-Kern).
Laeuft mit node oder, auf dem Mac ohne node, mit JavaScriptCore (jsc aus dem System)."""
import json
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "app" / "static" / "plan-names.js"
FIXTURE = ROOT / "packages" / "shared-contracts" / "fixtures" / "plan-names" / "cases.json"
JSC = Path("/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc")

RUNNER = """import { tinyName, tinyNames } from %(module)s;
const fx = %(fixture)s;
const out = { single: fx.single.map(c => tinyName(c.title)), plans: fx.plans.map(p => Object.fromEntries(tinyNames(p.items))) };
(typeof print === "function" ? print : console.log)(JSON.stringify(out));
"""


@pytest.fixture(scope="module")
def results(tmp_path_factory):
    node = shutil.which("node")
    if node:
        cmd = [node]
    elif JSC.exists():
        cmd = [str(JSC), "-m"]
    else:
        pytest.skip("weder node noch jsc")
    runner = tmp_path_factory.mktemp("plan-names") / "run.mjs"
    runner.write_text(RUNNER % {"module": json.dumps(MODULE.resolve().as_uri()), "fixture": FIXTURE.read_text(encoding="utf-8")},
                      encoding="utf-8")
    p = subprocess.run(cmd + [str(runner)], capture_output=True, text=True, timeout=60)
    assert p.returncode == 0, p.stderr
    return json.loads(p.stdout)


def test_single_titles(results):
    fx = json.loads(FIXTURE.read_text(encoding="utf-8"))
    assert len(fx["single"]) >= 40
    bad = [(c["title"], got, c["tiny"]) for c, got in zip(fx["single"], results["single"]) if got != c["tiny"]]
    assert bad == []


def test_plans_have_unique_names_per_subject(results):
    fx = json.loads(FIXTURE.read_text(encoding="utf-8"))
    assert len(fx["plans"]) >= 8
    for p, got in zip(fx["plans"], results["plans"]):
        assert got == p["expect"], p["name"]


def test_fixture_rules_hold():
    """Die Faelle selbst: kein "ET" mehr fuer zwei Faecher, Uebungen mit Praefix, kurze Namen (ohne Nummer hoechstens 8 Zeichen)."""
    fx = json.loads(FIXTURE.read_text(encoding="utf-8"))
    tiny = {c["title"]: c["tiny"] for c in fx["single"]}
    assert tiny["Signale und Systeme (für Elektrotechnik)"] != tiny["Elektrotechnische Grundlagen der Informatik"]
    assert tiny["Übung: Signale und Systeme (für Elektrotechnik)"] == "Ü SigSys"
    assert "ET" not in tiny.values()
    plain = [v.removeprefix("Ü ").split(" ")[0] for v in tiny.values() if v]
    assert max(len(v) for v in plain) <= 8, plain


def test_web_uses_plan_names_module():
    views = (ROOT / "app" / "static" / "views-plan.js").read_text(encoding="utf-8")
    assert 'from "./plan-names.js' in views and "const TINY" not in views

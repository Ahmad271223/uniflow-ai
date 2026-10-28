"""Der Vertrag fuer das iPad (fixtures/studip-schedule/woche.json) passt zum Python-Stand (28.10.2026)."""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_week_fixture_is_current():
    r = subprocess.run([sys.executable, "tools/gen-studip-week-fixture.py", "--check"], cwd=ROOT, capture_output=True, text=True,
                       encoding="utf-8", timeout=300)
    assert r.returncode == 0, f"python tools/gen-studip-week-fixture.py neu ausfuehren\n{r.stdout}\n{r.stderr}"

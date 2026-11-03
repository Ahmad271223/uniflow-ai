"""Zusammenfuehren einer bisherigen Loesung mit einer neuen Fassung (03.11.2026): Referenz app/solution_format.merge_contents
gegen die gemeinsamen Faelle (packages/shared-contracts/fixtures/solutions/merge-cases.json), die auch Swift und der
Browser nachrechnen."""
import json
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
CASES = json.loads((ROOT / "packages/shared-contracts/fixtures/solutions/merge-cases.json").read_text(encoding="utf-8"))["cases"]


@pytest.mark.parametrize("case", CASES, ids=[c["name"] for c in CASES])
def test_merge_cases(case):
    from app import solution_format as sf
    if "error" in case:
        with pytest.raises(ValueError, match=case["error"]):
            sf.merge_contents(case["previous"], case["new"])
        return
    m = sf.merge_contents(case["previous"], case["new"])
    assert [p["key"] for p in m["pages"]] == case["keys"]
    assert sf.canonical(m) == sf.canonical(case["merged"])


def test_merged_content_seals_and_opens_with_the_same_id():
    """Das Ergebnis ist ein gueltiger Inhalt: mit dem Community-Schluessel versiegeln und wieder oeffnen (ID bleibt)."""
    import os
    from app import solution_format as sf
    c = next(c for c in CASES if "merged" in c and c["merged"]["images"] == {})
    secret = sf.community_secret("course", "luh", "kurs-1")
    pkg = sf.seal(c["merged"], None, os.urandom(32), os.urandom(12), secret=secret)
    assert pkg["header"]["solutionId"] == c["previous"]["solutionId"]
    assert sf.canonical(sf.open_package(pkg, secret=secret)) == sf.canonical(c["merged"])


def test_is_notebook_key():
    from app import solution_format as sf
    assert sf.is_notebook_key("nb-p1") and sf.is_notebook_key("nb12-x")
    assert not sf.is_notebook_key("nb") and not sf.is_notebook_key("nbx-1") and not sf.is_notebook_key("p1") and not sf.is_notebook_key("nb2")


def test_fixture_is_current():
    r = subprocess.run([sys.executable, "tools/gen-solution-merge-cases.py", "--check"], cwd=ROOT, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr

"""Schreibt packages/shared-contracts/fixtures/plans/plans.json aus app/plans.py (Tarife, Rechte, Kontingente).

Aufruf aus dem Repo-Wurzelverzeichnis:  python tools/gen-plans-fixture.py          (schreibt)
                                        python tools/gen-plans-fixture.py --check  (schreibt nichts; Exit 1, wenn veraltet)
Die Apps (Swift, Kotlin) pruefen ihre Tabellen gegen diese Datei; tests/test_subscriptions.py prueft, dass sie aktuell ist.
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from app import plans  # noqa: E402

OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "plans" / "plans.json"


def render() -> str:
    data = {"_hinweis": "Erzeugt mit tools/gen-plans-fixture.py aus app/plans.py; nicht von Hand aendern.", **plans.contract()}
    return json.dumps(data, ensure_ascii=False, indent=1) + "\n"


if __name__ == "__main__":
    if "--check" in sys.argv[1:]:
        current = OUT.read_text(encoding="utf-8") if OUT.exists() else None
        if current != render():
            print(f"veraltet: {OUT.relative_to(ROOT)} (python tools/gen-plans-fixture.py ausfuehren)")
            sys.exit(1)
        print(f"aktuell: {OUT.relative_to(ROOT)}")
        sys.exit(0)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(render(), encoding="utf-8")
    print(f"geschrieben: {OUT.relative_to(ROOT)}")

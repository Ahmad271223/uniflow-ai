"""Daten im Server-Image (Befund des Inhabers 09.11.2026 auf app.studinow.app: Mensa "Fehler 500", Raumfinder "Suche
gerade nicht moeglich"). Ursache: deploy/Dockerfile kopierte von packages/shared-contracts nur study-sources*.json;
mensa.json, rooms.json, exam-registration-*.json und study-sources-<hochschule>.json fehlten im Image, der Dienst las
sie per ROOT/packages/... und warf FileNotFoundError.

Regel: Jede Datei, die app/*.py zur Laufzeit unter ROOT/packages/shared-contracts liest, und jeder Grundstock-Katalog
unter apps/apple/UniFlow/Resources/StudyCatalogSeed muss (1) im Repo liegen, (2) in .dockerignore als Ausnahme stehen
und (3) von deploy/Dockerfile ins Image kopiert werden."""
import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "app"
DOCKERFILE = (ROOT / "deploy" / "Dockerfile").read_text(encoding="utf-8")
IGNORE = {l.strip() for l in (ROOT / ".dockerignore").read_text(encoding="utf-8").splitlines()
          if l.strip() and not l.lstrip().startswith("#")}
CONTRACT = re.compile(r'ROOT\s*/\s*"packages"\s*/\s*"shared-contracts"\s*/\s*"([^"]+)"')


def runtime_contract_files() -> list[str]:
    found = set()
    for py in APP.glob("*.py"):
        for m in CONTRACT.finditer(py.read_text(encoding="utf-8")):
            found.add(f"packages/shared-contracts/{m.group(1)}")
    return sorted(found)


def seed_files() -> list[str]:
    from app import study_catalog
    d = study_catalog.SEED_DIR
    return sorted(p.relative_to(ROOT).as_posix() for u in study_catalog.SEED_UNIVERSITIES for p in d.glob(f"{u}*.json.gz"))


def copied_by_dockerfile(rel: str) -> bool:
    for line in DOCKERFILE.replace("\\\n", " ").splitlines():
        parts = line.split()
        if parts[:1] == ["COPY"] and rel in parts[1:-1]:
            return True
    return False


def test_finds_the_known_runtime_files():
    files = runtime_contract_files()
    for name in ("mensa.json", "rooms.json", "exam-registration-luh.json", "study-sources.json", "study-sources-luh.json"):
        assert f"packages/shared-contracts/{name}" in files, files
    assert "apps/apple/UniFlow/Resources/StudyCatalogSeed/luh.json.gz" in seed_files()


@pytest.mark.parametrize("rel", runtime_contract_files() + seed_files())
def test_runtime_data_file_reaches_the_image(rel):
    assert (ROOT / rel).is_file(), f"{rel} fehlt im Repo"
    assert f"!{rel}" in IGNORE, f".dockerignore laesst {rel} nicht in den Build-Kontext"
    assert copied_by_dockerfile(rel), f"deploy/Dockerfile kopiert {rel} nicht ins Image"

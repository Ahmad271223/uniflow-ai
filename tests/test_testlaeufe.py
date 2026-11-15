"""Testlaeufe (docs/TESTLAEUFE.md, 15.11.2026): schneller Lauf ohne Lasttests, voller Lauf mit ihnen.

- tests/lasttests.txt und tests/wackeltests.txt nennen nur Tests, die es gibt (ein umbenannter Test fiele sonst still
  aus der Liste und liefe wieder im schnellen Lauf mit bzw. wuerde nicht mehr wiederholt)
- der Marker `last` steht genau an den Tests der Liste und ist in pytest.ini eingetragen; pytest.ini waehlt nichts ab
- tools/tests-schnell.sh laesst die Lasttests weg, tools/tests-voll.sh nicht; beide sind ausfuehrbar
- reparierte Tests stehen nicht bei den Wackel-Tests
- iPhone-Bilder fuer den Store: EIN Weg (IPhoneRealShotsTests), der alte schreibt nicht mehr in den Store-Ordner
"""
import configparser
import os
import re
from pathlib import Path

import pytest
from conftest import lasttests

ROOT = Path(__file__).resolve().parents[1]
TESTS = ROOT / "tests"


def _entries(name: str) -> list[str]:
    out = []
    for line in (TESTS / name).read_text(encoding="utf-8").splitlines():
        entry = line.split("#", 1)[0].strip()
        if entry:
            out.append(entry)
    return out


@pytest.mark.parametrize("name", ["lasttests.txt", "wackeltests.txt"])
def test_lists_name_only_existing_tests(name):
    entries = _entries(name)
    assert entries and len(entries) == len(set(entries)), "leer oder doppelte Eintraege"
    for entry in entries:
        file, _, test = entry.partition("::")
        src = TESTS / file
        assert re.fullmatch(r"test_[A-Za-z0-9_]+\.py", file) and src.is_file(), f"{name}: Datei {file} gibt es nicht"
        if test:
            assert re.search(rf"^(async )?def {re.escape(test)}\(", src.read_text(encoding="utf-8"), re.M), \
                f"{name}: {file} hat keinen Test {test} (umbenannt? Liste nachziehen)"
    if name == "lasttests.txt":
        assert all("::" in e for e in entries), "Lasttests einzeln nennen, keine ganzen Dateien"
        assert lasttests() == set(entries)


def test_marker_last_is_exactly_on_the_listed_tests(request):
    names = lasttests()
    seen = 0
    for item in request.session.items:
        key = f"{item.path.name}::{item.nodeid.split('::', 1)[-1].split('[', 1)[0]}"
        listed = item.path.parent == TESTS and key in names
        assert (item.get_closest_marker("last") is not None) == listed, item.nodeid
        seen += listed
    if request.config.getoption("markexpr") == "not last":
        assert seen == 0, "schneller Lauf: kein Lasttest laeuft mit"


def test_pytest_ini_registers_the_marker_and_deselects_nothing():
    cp = configparser.ConfigParser()
    cp.read(ROOT / "pytest.ini", encoding="utf-8")
    assert [m.split(":")[0] for m in cp["pytest"]["markers"].strip().splitlines()] == ["last"]
    assert set(cp["pytest"]) == {"markers"}, "kein addopts o. ae.: der Aufruf ohne Optionen laesst alles laufen"


def test_scripts_run_the_two_named_runs():
    lib = (ROOT / "tools" / "tests-lib.sh").read_text(encoding="utf-8")
    schnell = (ROOT / "tools" / "tests-schnell.sh").read_text(encoding="utf-8")
    voll = (ROOT / "tools" / "tests-voll.sh").read_text(encoding="utf-8")
    if os.name != "nt":
        assert os.access(ROOT / "tools" / "tests-schnell.sh", os.X_OK) and os.access(ROOT / "tools" / "tests-voll.sh", os.X_OK)
    assert '"$PY" -m pytest -q -p no:cacheprovider "$@"' in lib and "node --test tests/js/" in lib
    assert 'uf_pytest "$LOG" --ignore=tests/test_pwa.py -m "not last" "$@"' in schnell and "uf_node" in schnell
    assert 'uf_pytest "$LOG" --ignore=tests/test_pwa.py "$@"' in voll and "not last" not in voll.split("# 2. alle Tests")[1]
    assert "uf_node" in voll and "wackeltests.txt" in voll and "lasttests.txt" in voll
    assert "NICHT GESTARTET" in voll and 'mkdir "$LOCK"' in voll, "nie zwei volle Laeufe zugleich"
    for word in ("bestanden", "rot", "wiederholt"):
        assert word in voll
    doc = (ROOT / "docs" / "TESTLAEUFE.md").read_text(encoding="utf-8")
    for must in ("tools/tests-schnell.sh", "tools/tests-voll.sh", '-m "not last"', "node --test tests/js/",
                 "tests/lasttests.txt", "tests/wackeltests.txt", "nie zwei volle Läufe", "xcrun simctl clone"):
        assert must in doc, must
    for entry in _entries("lasttests.txt"):
        assert entry.split("::")[1] in doc, f"docs/TESTLAEUFE.md nennt den Lasttest {entry} nicht"


def test_repaired_tests_are_not_listed_as_flaky():
    flaky = " ".join(_entries("wackeltests.txt"))
    for fixed in ("test_modules_race.py", "test_social_login.py", "test_moodle.py"):
        assert fixed not in flaky, f"{fixed} ist repariert (15.11.2026): wieder rot heisst ein neuer Befund, kein Wackler"
    race = (TESTS / "test_modules_race.py").read_text(encoding="utf-8")
    assert 'monkeypatch.setattr(db, "DB_PATH"' in race and "autouse=True" in race, "eigene Datenbank je Test"
    social = (TESTS / "test_social_login.py").read_text(encoding="utf-8")
    body = social[social.index("def test_list_and_unlink_identities"):social.index("def test_unlink_last_login_method")]
    assert 'monkeypatch.setattr(accounts, "now"' in body, "feste Uhr fuer die Reihenfolge der Anmeldewege"


def test_iphone_store_pictures_have_one_way():
    tests = ROOT / "apps" / "apple" / "UniFlowTests"
    old = (tests / "IPhoneStoreScreenshotTests.swift").read_text(encoding="utf-8")
    new = (tests / "IPhoneRealShotsTests.swift").read_text(encoding="utf-8")
    # der alte Weg (Demo-Inhalte, 01-uebersicht…) schreibt nicht mehr in den Ordner der Store-Bilder
    assert 'environment["UF_SCREENSHOT_DIR"]' not in old and 'environment["UF_DEMO_SHOT_DIR"]' in old
    assert 'hasPrefix("appstore-screenshots")' in old and "Ueberholt als Weg zu den App-Store-Bildern" in old
    # der eine Weg: echte Daten, genau die sieben hochgeladenen Motive in der Reihenfolge des Upload-Werkzeugs
    assert 'env["UF_REAL_DB"]' in new and 'env["UF_SCREENSHOT_DIR"]' in new
    shot = re.findall(r'shoot\(env, "(\d\d-[a-z-]+)"', new)
    tool = (ROOT / "tools" / "store_einreichen.py").read_text(encoding="utf-8")
    tool = tool[tool.index('"APP_IPHONE_67"'):tool.index("\n}\n", tool.index('"APP_IPHONE_67"'))]
    assert [f"{n}-light-portrait.png" for n in shot] == re.findall(r'"(\d\d-[a-z-]+-light-portrait\.png)"', tool) and len(shot) == 7
    doc = (ROOT / "docs" / "release" / "SCREENSHOTS.md").read_text(encoding="utf-8")
    part = doc[doc.index('## iPhone (6,9")'):]
    blocks = re.findall(r"```sh\n(.*?)```", part, re.S)
    assert len(blocks) == 1 and "-only-testing:UniFlowTests/IPhoneRealShotsTests" in blocks[0], "genau ein Befehl"
    assert "TEST_RUNNER_UF_REAL_DB=" in blocks[0] and "TEST_RUNNER_UF_SCREENSHOT_DIR=" in blocks[0]
    assert "Der eine Weg zu diesem Satz" in part

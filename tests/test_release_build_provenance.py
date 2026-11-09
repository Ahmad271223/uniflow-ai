"""Build-Herkunft der iPad-App (Audit P46-01/P47-04, 08.11.2026): docs/release/BUILD-HERKUNFT.md, project.yml und
docs/release/APP-STORE.md nennen dieselbe aktuelle und dieselbe eingereichte Build-Nummer; jeder genannte Commit traegt
seine Build-Nummer in project.yml; auf dem Mac des Inhabers stimmt jeder Export-Ordner Datei fuer Datei mit dem Commit.
In GitHub Actions (flacher Checkout ohne alte Commits, kein ~/Studora-Builds) laufen nur die Text-Pruefungen."""
import os
import re
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
DOC = ROOT / "docs" / "release" / "BUILD-HERKUNFT.md"
STORE = ROOT / "docs" / "release" / "APP-STORE.md"
YML = ROOT / "apps" / "apple" / "project.yml"
BUILDS = Path(os.environ.get("STUDORA_BUILDS") or Path.home() / "Studora-Builds")
# beim Bauen erzeugt (xcodegen, Swift-Paket, eingelegte Team-Datei), nicht im Commit
GENERATED = ("apps/apple/Config/Team.xcconfig", "apps/apple/UniFlow.xcodeproj/", "apps/apple/UniFlow/Info.plist",
             "apps/apple/Packages/UniFlowCore/.swiftpm/")
ROW = re.compile(r"^\| (\d+) \| (?:`([0-9a-f]{7,40})`|–) \| ([^|]+) \| ([^|]+) \| ([^|]+) \|$", re.M)


def project_build() -> int:
    return int(re.search(r'CURRENT_PROJECT_VERSION: "(\d+)"', YML.read_text(encoding="utf-8")).group(1))


def rows() -> dict[int, dict]:
    text = DOC.read_text(encoding="utf-8")
    table = text.split("## Builds", 1)[1].split("\n### ", 1)[0]
    return {int(m[1]): {"commit": m[2], "date": m[3].strip(), "status": m[4].strip(), "content": m[5].strip()}
            for m in ROW.finditer(table)}


def submitted() -> int:
    s = [b for b, r in rows().items() if r["status"].startswith("eingereicht")]
    assert len(s) == 1, s
    return s[0]


def git(*args) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True)


def has_commit(c: str) -> bool:
    return git("cat-file", "-e", f"{c}^{{commit}}").returncode == 0


def test_table_lists_every_build_from_21_to_the_current_one():
    r, now = rows(), project_build()
    assert set(range(21, now + 1)) <= set(r), sorted(r)
    assert max(r) == now, "keine Zeile fuer einen Build nach project.yml"
    assert f"Aktueller Stand in project.yml: Build {now} " in DOC.read_text(encoding="utf-8")
    # der aktuelle Build ist noch nicht hochgeladen, solange er keinen Commit hat
    if r[now]["commit"] is None:
        assert "noch nicht hochgeladen" in r[now]["status"]


def test_submitted_build_is_build_25_from_d08cae54():
    """Betriebsfakt 08.11.2026: eingereicht ist 1.0 Build 25 aus d08cae54 (App Store und TestFlight-Beta-Pruefung)."""
    r = rows()
    assert submitted() == 25
    assert r[25]["commit"] == "d08cae54"
    assert "WAITING_FOR_REVIEW" in r[25]["status"] and "TestFlight" in r[25]["status"]
    assert "nie" in r[26]["status"] and r[26]["commit"] is None, "Build 26 wurde nie hochgeladen"
    assert submitted() < project_build(), "neuere Fixes stehen nur in einem spaeteren Build"


def test_app_store_md_names_the_same_builds_as_project_yml_and_this_table():
    store = STORE.read_text(encoding="utf-8")
    row = next(line for line in store.splitlines() if line.startswith("| Version, Build |"))
    assert f"**Build {project_build()}**" in row, row
    assert f"Build {submitted()} in der Prüfung" in row, row
    assert "Build 26 nie hochgeladen" in row, row
    assert f"Build {submitted()} ist seit" in store.splitlines()[2], "Kopfzeile nennt den eingereichten Build"
    assert "BUILD-HERKUNFT.md" in store


def test_every_named_commit_carries_its_build_number():
    r = {b: v for b, v in rows().items() if v["commit"]}
    assert r
    missing = [v["commit"] for v in r.values() if not has_commit(v["commit"])]
    if missing:
        pytest.skip(f"Commits nicht im Checkout (flacher Klon): {missing}")
    for build, v in r.items():
        yml = git("show", f"{v['commit']}:apps/apple/project.yml").stdout
        assert f'CURRENT_PROJECT_VERSION: "{build}"' in yml, (build, v["commit"])


def _export_differences(commit: str, export: Path) -> list[str]:
    tree = git("ls-tree", "-r", commit).stdout.splitlines()
    want = {}
    for line in tree:
        meta, path = line.split("\t", 1)
        _, kind, sha = meta.split()
        if kind == "blob":
            want[path] = sha
    paths = sorted(want)
    missing = [p for p in paths if not (export / p).is_file() and not (export / p).is_symlink()]
    present = [p for p in paths if p not in missing]
    out = subprocess.run(["git", "-C", str(ROOT), "hash-object", "--no-filters", "--stdin-paths"],
                         input="\n".join(str(export / p) for p in present), capture_output=True, text=True, check=True).stdout.split()
    changed = [p for p, h in zip(present, out) if h != want[p]]
    # git archive schreibt Dateien mit "eol=crlf" (.gitattributes, z. B. *.cmd, *.ps1) mit CRLF: Inhalt ohne CR vergleichen
    changed = [p for p in changed
               if (export / p).read_bytes().replace(b"\r\n", b"\n") != subprocess.run(
                   ["git", "-C", str(ROOT), "cat-file", "blob", want[p]], capture_output=True, check=True).stdout.replace(b"\r\n", b"\n")]
    extra = []
    for dirpath, dirnames, filenames in os.walk(export):
        rel_dir = Path(dirpath).relative_to(export).as_posix()
        for name in filenames:
            rel = name if rel_dir == "." else f"{rel_dir}/{name}"
            if rel not in want and not any(rel == g or rel.startswith(g) for g in GENERATED):
                extra.append(rel)
    return [f"fehlt: {p}" for p in missing] + [f"anders: {p}" for p in changed] + [f"zusaetzlich: {p}" for p in extra]


@pytest.mark.parametrize("build", [21, 22, 23, 24, 25, 27, 28, 30])
def test_export_folder_is_exactly_the_commit(build):
    """Nur auf dem Mac des Inhabers: ~/Studora-Builds/export-bNN = git archive <commit> (bis auf erzeugte Dateien)."""
    v = rows()[build]
    export = BUILDS / f"export-b{build}"
    if not export.is_dir():
        pytest.skip(f"{export} nicht auf diesem Rechner")
    if not has_commit(v["commit"]):
        pytest.skip(f"Commit {v['commit']} nicht im Checkout")
    assert _export_differences(v["commit"], export) == []

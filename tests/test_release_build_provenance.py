"""Build-Herkunft der Apple-App, iPad und iPhone (Audit P46-01/P47-04, 08.11.2026): docs/release/BUILD-HERKUNFT.md, project.yml und
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


def submitted() -> int | None:
    """eingereichter Build (hoechstens einer); None, wenn gerade keiner in der Pruefung ist"""
    s = [b for b, r in rows().items() if r["status"].startswith("eingereicht")]
    assert len(s) <= 1, s
    return s[0] if s else None


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


def test_released_builds_and_build_33():
    """Betriebsfakt 11.11.2026: 1.0.1 Build 30 (3b81464a) und 1.0.2 Build 31 (0324eb3d) sind veroeffentlicht, Build 32
    (95943d32) war nur in TestFlight (Absturz), Build 33 (1c911fa5) ist 1.0.3. Build 25 (d08cae54) war als 1.0 freigegeben,
    wurde nie veroeffentlicht und ist zurueckgezogen."""
    r = rows()
    assert r[30]["commit"] == "3b81464a" and r[30]["status"].startswith("veröffentlicht") and "1.0.1" in r[30]["status"]
    assert r[31]["commit"] == "0324eb3d" and r[31]["status"].startswith("veröffentlicht") and "1.0.2" in r[31]["status"]
    assert r[32]["commit"] == "95943d32" and "nie eingereicht" in r[32]["status"]
    assert r[33]["commit"] == "1c911fa5" and "1.0.3" in r[33]["status"]
    assert r[25]["commit"] == "d08cae54"
    assert "nie veröffentlicht" in r[25]["status"] and "zurückgezogen" in r[25]["status"]
    assert "nie" in r[26]["status"] and r[26]["commit"] is None, "Build 26 wurde nie hochgeladen"
    assert "nie" in r[29]["status"] and r[29]["commit"] is None, "Build 29 wurde nie gebaut"
    s = submitted()
    assert s is None or s < project_build(), "neuere Aenderungen stehen nur in einem spaeteren Build"
    yml = YML.read_text(encoding="utf-8")
    assert not re.search(r'MARKETING_VERSION: "1\.0"', yml), "1.0 wurde nie veroeffentlicht"


def test_build_41_is_submitted_as_1_0_4_after_the_server_update():
    """Betriebsfakt 14.11.2026: Build 41 (6923136b, Tag ios-1.0.4-b41) ist seit 19:01 in TestFlight (VALID 19:46) und
    seit 19:56 als Version 1.0.4 in der Pruefung (WAITING_FOR_REVIEW, Freigabe von Hand) - nach dem Server-Update fuer
    die Geraete-Regel (19:55, derselbe Commit, DEPLOY-DIENST-2026-11-14.md) und dem Okay des Inhabers; develop zaehlt als
    Build 42 weiter."""
    r = rows()
    b = r[41]
    assert b["commit"] == "6923136b" and b["date"] == "14.11.2026 19:01"
    assert b["status"].startswith("eingereicht: Version 1.0.4 am 14.11.2026 19:56 zur Prüfung gegeben")
    for must in ("App Store WAITING_FOR_REVIEW", "Freigabe nach der Prüfung von Hand", "iPad + iPhone", "`luh hildesheim`",
                 "Server-Update für die Geräte-Regel (ausgerollt 19:55, `DEPLOY-DIENST-2026-11-14.md`)", "Okay des Inhabers",
                 "hochgeladen 19:01", "VALID gemeldet 19:46", "„LUH-Tester“", "IN_BETA_TESTING", "`ios-1.0.4-b41`"):
        assert must in b["status"], must
    assert "nicht eingereicht" not in b["status"] and "wartet" not in b["status"]
    for must in ("Build 40 plus", "Mac-Reparatur", "Hildesheim", "iPhone-Wochenraster", "Geräte-Regel", "4 pt"):
        assert must in b["content"], must
    assert "greift seit dem Server-Update vom 14.11.2026 19:55" in b["content"] and "greift erst nach" not in b["content"]
    assert r[40]["commit"] == "aefee598" and "nicht eingereicht" in r[40]["status"]
    assert r[42]["commit"] is None and r[42]["status"] == "noch nicht hochgeladen; develop nach Build 41"
    assert r[42]["content"] == "Änderungen nach `6923136b`"
    doc = DOC.read_text(encoding="utf-8")
    assert submitted() == 41
    assert "In der Prüfung bei Apple: 1.0.4 mit Build 41 seit 14.11.2026 19:56." in doc and "keine Version" not in doc
    # seit Build 40 nicht mehr nur LUH, seit Build 39 nicht mehr nur iPad
    assert "bis Build 39\n`UF_SHIPPED_UNIVERSITIES=luh` (nur LUH), ab Build 40 `luh hildesheim`" in doc
    assert "Alle Builds: Release, `UF_SHIPPED_UNIVERSITIES=luh`" not in doc and "(StudiNow 1.0 und 1.0.1)" not in doc
    store = STORE.read_text(encoding="utf-8")
    row = next(line for line in store.splitlines() if line.startswith("| Version, Build |"))
    assert "Build 41 in der Prüfung (Version 1.0.4, eingereicht am 14.11.2026 19:56, WAITING_FOR_REVIEW" in row, row
    assert "Builds 36 bis 40 (1.0.4) nur TestFlight" in row and "noch nicht eingereicht" not in row, row
    head = store.splitlines()[2]
    assert "für StudiNow 1.0.4 (Build 41 ist seit 14.11.2026 19:56 in der Prüfung bei Apple, WAITING_FOR_REVIEW" in head
    assert "noch nicht eingereicht" not in head
    assert "10 iPad-Bilder und\n7 iPhone-Bilder, alle COMPLETE" in store
    sheet = (ROOT / "docs" / "release" / "EINREICHUNG-1-0-4.md").read_text(encoding="utf-8")
    assert "1.0.4 ist mit Build 41 eingereicht" in sheet and "**eingereicht am 14.11.2026 um 19:56**" in sheet
    assert "WAITING_FOR_REVIEW" in sheet and "noch nicht zur Prüfung eingereicht" not in sheet and "wird mit Build 41" not in sheet
    steps = sheet[sheet.index("## Reihenfolge in App Store Connect"):sheet.index("## 1. Name der App")]
    for n, what in ((1, "Neue Version **1.0.4** anlegen"), (2, "Die sieben Textfelder"), (3, "Bildschirmfotos hochladen"),
                    (4, "Build **41** auswählen"), (5, "Freigabe **von Hand**")):
        assert f"{n}. **Erledigt (14.11.2026):** {what}" in steps, (n, what)
    # das Server-Update, auf das die Einreichung gewartet hat: derselbe Commit wie Build 41, vor der Einreichung
    deploy = (ROOT / "docs" / "release" / "DEPLOY-DIENST-2026-11-14.md").read_text(encoding="utf-8")
    assert deploy.startswith("# Dienst-Update 14.11.2026 – ausgerollt 19:55\n")
    for must in ("`d0d178b6` → `6923136b`", "derselbe Commit wie Build 41", "`app/device_limit.py` (neu)",
                 "X-StudiNow-Caps: device_limit", "Ausgerollt am 14.11.2026 um 19:55 (Berlin) auf Freigabe des Inhabers",
                 "uniflow-2026-11-14_1952.tar.gz", "`primary_device_id`, `primary_device_name`, `primary_device_set_at`",
                 "Nicht geprüft: die Geräte-Regel mit einem echten Konto auf zwei echten Geräten",
                 "git archive d0d178b6"):
        assert must in deploy, must
    if has_commit("6923136b") and has_commit("d0d178b6"):    # die Dateiliste des Dokuments ist die des Dienst-Codes
        changed = git("diff", "--name-only", "d0d178b6", "6923136b", "--", "app", "deploy").stdout.split()
        assert changed and not [f for f in changed if f.startswith("deploy/")], changed
        table = deploy[deploy.index("## Was sich im Dienst-Code ändert"):deploy.index("## Tests")]
        assert [f for f in changed if f"`{f}`" not in table] == [], "geaenderte Dienst-Dateien fehlen in der Tabelle"
    tag = git("rev-parse", "--verify", "--quiet", "ios-1.0.4-b41^{commit}")
    if tag.returncode == 0:                                  # im flachen Klon ohne Tags nichts zu pruefen
        assert tag.stdout.strip().startswith("6923136b"), tag.stdout


def test_app_store_md_names_the_same_builds_as_project_yml_and_this_table():
    store = STORE.read_text(encoding="utf-8")
    row = next(line for line in store.splitlines() if line.startswith("| Version, Build |"))
    assert f"**Build {project_build()}**" in row, row
    s = submitted()
    assert (f"Build {s} in der Prüfung" in row) if s else ("veröffentlicht" in row), row
    assert "Build 26 nie hochgeladen" in row, row
    assert (f"Build {s} ist seit" if s else "Build 35 ist seit") in store.splitlines()[2], "Kopfzeile nennt den aktuellen Build"
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


@pytest.mark.parametrize("build", [21, 22, 23, 24, 25, 27, 28, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41])
def test_export_folder_is_exactly_the_commit(build):
    """Nur auf dem Mac des Inhabers: ~/Studora-Builds/export-bNN = git archive <commit> (bis auf erzeugte Dateien)."""
    v = rows()[build]
    export = BUILDS / f"export-b{build}"
    if not export.is_dir():
        pytest.skip(f"{export} nicht auf diesem Rechner")
    if not has_commit(v["commit"]):
        pytest.skip(f"Commit {v['commit']} nicht im Checkout")
    assert _export_differences(v["commit"], export) == []

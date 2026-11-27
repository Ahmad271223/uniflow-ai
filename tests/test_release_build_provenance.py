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


REL = ROOT / "docs" / "release"


def _deploy_table_names_the_changed_service_files(deploy: str, old: str, new: str) -> list[str] | None:
    """Dateien unter app/ und deploy/, die sich zwischen zwei Server-Staenden geaendert haben; None im flachen Klon.
    Jede muss in der Tabelle "Was sich im Dienst-Code aendert" des Deploy-Dokuments stehen."""
    if not (has_commit(old) and has_commit(new)):
        return None
    changed = git("diff", "--name-only", old, new, "--", "app", "deploy").stdout.split()
    table = deploy[deploy.index("## Was sich im Dienst-Code ändert"):deploy.index("## Tests")]
    assert f"(`{old}` → `{new}`)" in table
    assert changed and [f for f in changed if f"`{f}`" not in table] == [], "geaenderte Dienst-Dateien fehlen in der Tabelle"
    return changed


def test_build_41_was_submitted_and_withdrawn_the_same_evening():
    """Betriebsfakt 14.11.2026: Build 41 (6923136b, Tag ios-1.0.4-b41) war seit 19:01 in TestFlight (VALID 19:46) und
    von 19:56 bis 21:54 als Version 1.0.4 eingereicht - nach dem Server-Update fuer die Geraete-Regel (19:55, derselbe
    Commit, DEPLOY-DIENST-2026-11-14.md). Zurueckgezogen (DEVELOPER_REJECTED) wegen Fehlern im iPhone-Layout am echten
    Geraet; Build 41 bleibt nur in TestFlight und ist durch Build 42 ersetzt."""
    r = rows()
    b = r[41]
    assert b["commit"] == "6923136b" and b["date"] == "14.11.2026 19:01"
    assert b["status"].startswith("nur TestFlight: Version 1.0.4, am 14.11.2026 19:56 zur Prüfung eingereicht")
    for must in ("am 14.11.2026 21:54 zurückgezogen", "DEVELOPER_REJECTED", "Entscheidung des Inhabers „Ja, mit Build 42“",
                 "am echten iPhone", "Karten unter dem Kalender gequetscht", "bis 26 Uhr", "„25:15“",
                 "Einstiegs-Bildschirm war halb leer", "ersetzt durch Build 42", "iPad + iPhone", "`luh hildesheim`",
                 "Server-Update für die Geräte-Regel, ausgerollt 19:55, `DEPLOY-DIENST-2026-11-14.md`",
                 "hochgeladen 19:01", "VALID gemeldet 19:46", "„LUH-Tester“", "`ios-1.0.4-b41`"):
        assert must in b["status"], must
    assert not b["status"].startswith("eingereicht") and "nicht eingereicht" not in b["status"]
    for must in ("Build 40 plus", "Mac-Reparatur", "Hildesheim", "iPhone-Wochenraster", "Geräte-Regel", "4 pt"):
        assert must in b["content"], must
    assert "greift seit dem Server-Update vom 14.11.2026 19:55" in b["content"]
    assert r[40]["commit"] == "aefee598" and "nicht eingereicht" in r[40]["status"]
    store = STORE.read_text(encoding="utf-8")
    row = next(line for line in store.splitlines() if line.startswith("| Version, Build |"))
    assert "Build 41 am 14.11.2026 19:56 eingereicht und um 21:54 zurückgezogen" in row and "seitdem nur TestFlight" in row, row
    assert "Build 41 in der Prüfung" not in row, row
    head = store.splitlines()[2]
    assert "Build 41 war am 14.11.2026 von 19:56 bis 21:54 eingereicht und wurde zurückgezogen" in head
    assert "Build 41 ist seit" not in head
    sheet = (REL / "EINREICHUNG-1-0-4.md").read_text(encoding="utf-8")
    assert "Build 41 war am 14.11.2026 um 19:56 eingereicht und wurde um 21:54 zurückgezogen (DEVELOPER_REJECTED" in sheet
    assert "ist mit Build 41 eingereicht" not in sheet and "Build **41** auswählen" not in sheet
    # das Server-Update vom 14.11.: derselbe Commit wie Build 41, vor der Einreichung; Nachtrag zum Rueckzug
    deploy = (REL / "DEPLOY-DIENST-2026-11-14.md").read_text(encoding="utf-8")
    assert deploy.startswith("# Dienst-Update 14.11.2026 – ausgerollt 19:55\n")
    for must in ("derselbe Commit wie Build 41", "`app/device_limit.py` (neu)", "X-StudiNow-Caps: device_limit",
                 "Ausgerollt am 14.11.2026 um 19:55 (Berlin) auf Freigabe des Inhabers",
                 "uniflow-2026-11-14_1952.tar.gz", "`primary_device_id`, `primary_device_name`, `primary_device_set_at`",
                 "Nicht geprüft: die Geräte-Regel mit einem echten Konto auf zwei echten Geräten",
                 "git archive d0d178b6",
                 "Nachtrag 15.11.2026: Die Einreichung mit Build 41 wurde am 14.11.2026 um 21:54 zurückgezogen",
                 "`DEPLOY-DIENST-2026-11-15.md`"):
        assert must in deploy, must
    changed = _deploy_table_names_the_changed_service_files(deploy, "d0d178b6", "6923136b")
    assert changed is None or (len(changed) == 16 and not [f for f in changed if f.startswith("deploy/")]), changed
    tag = git("rev-parse", "--verify", "--quiet", "ios-1.0.4-b41^{commit}")
    if tag.returncode == 0:                                  # im flachen Klon ohne Tags nichts zu pruefen
        assert tag.stdout.strip().startswith("6923136b"), tag.stdout


def test_build_42_is_in_review_as_1_0_4_and_the_server_runs_the_same_commit():
    """Betriebsfakt 15.11.2026: Build 42 (fc66fba4, Tag ios-1.0.4-b42) ist seit 10:11 in TestFlight (VALID 10:12) und
    seit 10:13 als Version 1.0.4 in der Pruefung (WAITING_FOR_REVIEW, Freigabe von Hand), Texte und Bilder unveraendert
    vom 14.11.; der Server laeuft seit 01:17 auf demselben Commit (DEPLOY-DIENST-2026-11-15.md, nur app/study.py);
    Build 43 (e2e26e56) liegt seit 15.11. 19:41 nur intern in TestFlight; develop zaehlt als Build 44 weiter."""
    r = rows()
    b = r[42]
    assert b["commit"] == "fc66fba4" and b["date"] == "15.11.2026 10:11"
    # 16.11.2026 10:49: von Apple genehmigt und vom Inhaber freigegeben
    assert b["status"].startswith("veröffentlicht: Version 1.0.4 am 16.11.2026 10:49 vom Inhaber freigegeben (von Apple genehmigt, READY_FOR_SALE")
    assert "eingereicht: Version 1.0.4 am 15.11.2026 10:13 neu zur Prüfung gegeben" in b["status"]
    for must in ("App Store WAITING_FOR_REVIEW", "Freigabe nach der Prüfung von Hand", "ersetzt den zurückgezogenen Build 41",
                 "Texte und Bilder unverändert vom 14.11.2026",
                 "Server seit 15.11.2026 01:17 auf demselben Commit (`DEPLOY-DIENST-2026-11-15.md`)",
                 "iPad + iPhone", "`luh hildesheim`", "drei Upload-Versuche in der Nacht scheiterten an fehlender Internetverbindung",
                 "hochgeladen 10:11", "VALID gemeldet 10:12", "Testhinweis gesetzt", "„LUH-Tester“", "IN_BETA_TESTING",
                 "`ios-1.0.4-b42`"):
        assert must in b["status"], must
    for must in ("Build 41 plus", "iPhone-Layout", "höchstens bis 24 Uhr", "untereinander", "Einstieg ohne leere Hälfte",
                 "`LayoutWidthAuditTests`", "Lernplaner", "nach 24:00", "„25:15“ wird repariert", "Stift 0,88",
                 "Fineliner 0,5/0,8/1,5/2,5/4", "Netzfehler bei App Store Connect",
                 "Python 3564", "JS 456", "Swift-Kern 1565", "iPad 1802", "iPhone 139"):
        assert must in b["content"], must
    # Build 43 (15.11.2026 19:41): nur intern in TestFlight, nicht an die LUH-Tester, nicht eingereicht; develop ist Build 44
    assert r[43]["commit"] == "e2e26e56" and r[43]["date"] == "15.11.2026 19:41"
    assert r[43]["status"].startswith("nur TestFlight, nur interne Gruppe „Intern (Inhaber)“")
    for must in ("NICHT an „LUH-Tester“", "keine Beta-Prüfung", "nicht eingereicht", "Der Dienst läuft noch auf `fc66fba4`"):
        assert must in r[43]["status"], must
    # Build 44 (16.11.2026): Hotfix 1.0.5 aus 10cf2836 (Store-Stand + Absturz-Korrektur + Speicher-Runde nach dem
    # Schliessen), 23:42 eingereicht; develop ist Build 45 (Version 1.0.6)
    assert r[44]["commit"] == "10cf2836" and r[44]["date"] == "16.11.2026 23:37"
    assert r[44]["status"].startswith("veröffentlicht: Version 1.0.5 am 18.11.2026 abends vom Inhaber freigegeben")
    assert "eingereicht: Version 1.0.5 am 16.11.2026 23:42 zur Prüfung gegeben" in r[44]["status"]
    for must in ("WAITING_FOR_REVIEW", "Freigabe nach der Prüfung von Hand", "`release/1.0.5-hotfix`", "`ios-1.0.5-b44`", "Server unverändert auf `fc66fba4`"):
        assert must in r[44]["status"], must
    for must in ("Stand der Store-Version 1.0.4 (Build 42, `fc66fba4`) plus genau zwei Korrekturen", "`Views.swift`", "`SyncEngine.swift`", "iPadOS 26.2"):
        assert must in r[44]["content"], must
    # Build 45 (19.11.2026): Version 1.0.6 aus f5e21794, eingereicht 15:00 mit beiden Credit-Paketen; develop ist Build 46 (1.0.7)
    assert r[45]["commit"] == "f5e21794" and project_build() == 52 and r[45]["date"] == "19.11.2026 14:20"
    assert r[45]["status"].startswith("veröffentlicht: Version 1.0.6 seit 20.11.2026")
    assert "eingereicht: Version 1.0.6 am 19.11.2026 15:00 zur Prüfung gegeben" in r[45]["status"]
    for must in ("AFTER_APPROVAL", "Credit-Pakete", "`UFIntakeOffered` YES", "Demo hinter „Hilfe“"):
        assert must in r[45]["status"], must
    # Build 46 (23.11.2026) hochgeladen, nicht eingereicht; Build 47 (24.11.2026) ohne Klausur-Verkauf, Wissensbank, Erklaerungen
    assert r[46]["commit"] == "b9966b80" and r[46]["status"].startswith("hochgeladen (TestFlight), nicht eingereicht: Version 1.0.7")
    assert r[47]["commit"] == "646d1b54" and r[47]["status"].startswith("hochgeladen (TestFlight), nicht eingereicht")
    # 24.11.2026: Build 48 als Version 1.0.7 eingereicht (Freigabe von Hand)
    assert r[48]["commit"] == "c474bbd4" and r[48]["status"].startswith("eingereicht: Version 1.0.7 am 24.11.2026")
    for must in ("Lernkalender aus", "Erinnerungen ab Pro AI", "KI-Credits", "YouTube öffnen"):
        assert must in r[45]["content"], must
    doc = DOC.read_text(encoding="utf-8")
    # 26.11.2026: Build 49 (Version 1.0.8, nur Korrekturen) hochgeladen, wird nicht eingereicht (noch mit Datei-Eingang an)
    assert r[49]["commit"] == "bbb7e05c" and r[49]["status"].startswith("hochgeladen (TestFlight), nicht eingereicht: Version 1.0.8")
    assert "NICHT eingereicht" in r[49]["status"]
    assert r[50]["commit"] == "51571948" and r[50]["status"].startswith("hochgeladen (TestFlight), nicht eingereicht (ersetzt durch Build 51")
    assert r[51]["commit"] == "9a34bb32" and r[51]["status"].startswith("gebaut, nicht hochgeladen")
    assert r[52]["status"].startswith(("vorbereitet, noch nicht hochgeladen: Version 1.0.8", "hochgeladen (TestFlight)"))
    assert submitted() == 48, "24.11.2026: Build 48 als 1.0.7 in der Pruefung, 45 (1.0.6) ist veroeffentlicht"
    assert "Im App Store: 1.0.5 mit Build 44 seit 18.11.2026 abends (vom Inhaber freigegeben), davor 1.0.4 mit Build 42 seit 16.11.2026 10:49." in doc
    assert "keine Version" not in doc and "mit Build 41 seit" not in doc
    # seit Build 40 nicht mehr nur LUH, seit Build 39 nicht mehr nur iPad
    assert "bis Build 39\n`UF_SHIPPED_UNIVERSITIES=luh` (nur LUH), ab Build 40 `luh hildesheim`" in doc
    assert "Alle Builds: Release, `UF_SHIPPED_UNIVERSITIES=luh`" not in doc and "(StudiNow 1.0 und 1.0.1)" not in doc
    store = STORE.read_text(encoding="utf-8")
    row = next(line for line in store.splitlines() if line.startswith("| Version, Build |"))
    assert "Build 42 als Version 1.0.4 veröffentlicht am 16.11.2026 10:49 (eingereicht am 15.11.2026 10:13" in row, row
    assert "Builds 36 bis 40 (1.0.4) nur TestFlight" in row and "noch nicht eingereicht" not in row, row
    head = store.splitlines()[2]
    assert "Build 42 ist seit 16.11.2026 10:49 als Version 1.0.4 veröffentlicht" in head and "Build 45 ist seit 20.11.2026 als Version 1.0.6 veröffentlicht" in head
    assert "Build 44 ist seit 18.11.2026 als Version 1.0.5 veröffentlicht" in head
    assert "noch nicht eingereicht" not in head
    assert "10 iPad-Bilder und\n7 iPhone-Bilder, alle COMPLETE" in store
    assert "Die neue Einreichung vom 15.11.2026 mit Build 42 nutzt dieselben Texte und Bilder\nunverändert." in store
    sheet = (REL / "EINREICHUNG-1-0-4.md").read_text(encoding="utf-8")
    assert "1.0.4 mit Build 42 ist seit 16.11.2026 10:49 veröffentlicht" in sheet and "**eingereicht am 15.11.2026 um 10:13** mit Build 42" in sheet
    assert "WAITING_FOR_REVIEW" in sheet and "noch nicht zur Prüfung eingereicht" not in sheet
    assert "`DEPLOY-DIENST-2026-11-15.md`" in sheet and "unverändert vom 14.11.2026" in sheet
    steps = sheet[sheet.index("## Reihenfolge in App Store Connect"):sheet.index("## 1. Name der App")]
    for n, day, what in ((1, "14", "Neue Version **1.0.4** anlegen"), (2, "14", "Die sieben Textfelder"),
                         (3, "14", "Bildschirmfotos hochladen"), (4, "15", "Build **42** auswählen"),
                         (5, "15", "Freigabe **von Hand**")):
        assert f"{n}. **Erledigt ({day}.11.2026):** {what}" in steps, (n, what)
    assert "neu eingereicht um 10:13" in steps
    # das Server-Update vom 15.11.: derselbe Commit wie Build 42, nur die Lernpaket-Zeiten
    deploy = (REL / "DEPLOY-DIENST-2026-11-15.md").read_text(encoding="utf-8")
    assert deploy.startswith("# Dienst-Update 15.11.2026 – ausgerollt 01:17\n")
    for must in ("derselbe Commit wie Build 42", "seit 14.11.2026 19:55 `6923136b`", "`app/study.py`", "nie nach 24:00",
                 "`repair_times`", "„25:15“", "Nur diese eine Datei", "keine neue Tabelle, keine neue Spalte",
                 "Gelöscht wird nichts", "**3.564 bestanden**", "**456 / 456**",
                 "Ausgerollt am 15.11.2026 um 01:17 (Berlin) auf Freigabe des Inhabers vom 14.11.2026 abends („Ja, beides“",
                 "uniflow-2026-11-15_0115.tar.gz", "`dienst-check.sh`: alle Prüfungen bestanden",
                 "`/login` 200, `/api/billing/plans` 200", "git archive 6923136b",
                 "Version 1.0.4 um 10:13 neu zur Prüfung eingereicht"):
        assert must in deploy, must
    changed = _deploy_table_names_the_changed_service_files(deploy, "6923136b", "fc66fba4")
    assert changed is None or changed == ["app/study.py"], changed
    tag = git("rev-parse", "--verify", "--quiet", "ios-1.0.4-b42^{commit}")
    if tag.returncode == 0:                                  # im flachen Klon ohne Tags nichts zu pruefen
        assert tag.stdout.strip().startswith("fc66fba4"), tag.stdout


def test_commit_notes_next_to_the_archives_name_the_commit_of_the_table():
    """Nur auf dem Mac des Inhabers: ~/Studora-Builds/StudiNow-NN.commit (beim Bauen abgelegt) nennt denselben Commit
    wie die Zeile NN; fuer Build 42 liegt die Datei da."""
    if not BUILDS.is_dir():
        pytest.skip(f"{BUILDS} nicht auf diesem Rechner")
    r = rows()
    notes = {int(p.stem.split("-")[1]): p.read_text(encoding="utf-8").strip() for p in BUILDS.glob("StudiNow-*.commit")
             if p.stem.split("-")[1].isdigit()}
    assert 42 in notes, sorted(notes)
    for build, commit in sorted(notes.items()):
        assert build in r and r[build]["commit"], build
        assert commit and (commit.startswith(r[build]["commit"]) or r[build]["commit"].startswith(commit)), (build, commit)


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


@pytest.mark.parametrize("build", [21, 22, 23, 24, 25, 27, 28, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42])
def test_export_folder_is_exactly_the_commit(build):
    """Nur auf dem Mac des Inhabers: ~/Studora-Builds/export-bNN = git archive <commit> (bis auf erzeugte Dateien)."""
    v = rows()[build]
    export = BUILDS / f"export-b{build}"
    if not export.is_dir():
        pytest.skip(f"{export} nicht auf diesem Rechner")
    if not has_commit(v["commit"]):
        pytest.skip(f"Commit {v['commit']} nicht im Checkout")
    assert _export_differences(v["commit"], export) == []

"""Windows-Paket (05.11.2026, docs/release/WINDOWS-BAU-2026-11-05.md): Daten, die das Backend zur Laufzeit aus dem
Repo liest, stehen in der PyInstaller-Beschreibung; die Anmeldeinformationsverwaltung funktioniert auf echtem Windows
(laeuft im Windows-Workflow, sonst uebersprungen); Smoke-Test und Tesseract-Schritt pruefen, was sie sollen."""
import re
import sys
import uuid
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
WIN = ROOT / "apps" / "windows"
CHAIN = re.compile(r'\bROOT((?:\s*/\s*"[^"]+")+)')
# Pfade unter ROOT, die nicht ins Paket gehoeren: eigene Einstellungen, Daten und Protokolle des Nutzers (am PC per
# Umgebung in den Datenordner umgelenkt, app/desktop.py prepare_environment) und Quellen, die nur tools/ liest
NOT_BUNDLED = {(".env",), ("logs",), ("data",),
               ("packages", "shared-contracts", "study-sources-luh.json"),   # nur tools/build-luh-seed.py, gen-study-catalog-fixture.py
               ("packages", "shared-contracts", "study-sources-hildesheim.json"),   # nur tools/build-hildesheim-seed.py, gen-...
               ("packages", "shared-contracts", "study-sources-hsh.json")}   # nur tools/build-hsh-seed.py, gen-...


def _chains(text: str) -> set[tuple[str, ...]]:
    return {tuple(re.findall(r'"([^"]+)"', m.group(1))) for m in CHAIN.finditer(text)}


def _bundled() -> set[tuple[str, ...]]:
    spec = (WIN / "backend" / "uniflow-backend.spec").read_text(encoding="utf-8")
    return _chains(spec.split("datas = [", 1)[1].split("binaries = []", 1)[0])


def test_spec_bundles_every_repo_file_the_backend_reads():
    """Jede Datei/jeder Ordner, den app/*.py als ROOT / "..." liest, liegt im Paket (oder in einem mitgelieferten
    Ordner); sonst bleibt am PC z. B. die Katalogsuche des Studienverlaufs leer, ohne dass ein Test es merkt."""
    bundled = _bundled()
    for b in bundled:
        assert (ROOT.joinpath(*b)).exists(), f"uniflow-backend.spec nennt {'/'.join(b)}, das es im Repo nicht gibt"
    read = set()
    for f in sorted((ROOT / "app").glob("*.py")):
        read |= _chains(f.read_text(encoding="utf-8"))
    missing = []
    for r in sorted(read - NOT_BUNDLED):
        covered = any(r[:len(b)] == b for b in bundled)                  # Datei selbst oder ein Elternordner
        covered = covered or any(b[:len(r)] == r for b in bundled)       # Ordner, aus dem einzelne Dateien mitkommen
        if not covered:
            missing.append("/".join(r))
    assert not missing, f"Im Windows-Paket fehlen (apps/windows/backend/uniflow-backend.spec): {missing}"
    for need in (("packages", "shared-contracts", "exam-registration-luh.json"),
                 ("packages", "shared-contracts", "exam-registration-hildesheim.json"),
                 ("apps", "apple", "UniFlow", "Resources", "StudyCatalogSeed", "luh.json.gz"),
                 ("apps", "apple", "UniFlow", "Resources", "StudyCatalogSeed", "hildesheim.json.gz"),
                 ("apps", "apple", "UniFlow", "Resources", "StudyCatalogSeed", "hsh.json.gz")):
        assert need in bundled, "/".join(need)


def test_smoke_test_covers_account_login_and_package_data():
    ps = (WIN / "scripts" / "check-backend.ps1").read_text(encoding="utf-8")
    for needle in ("api/app-account/status", "windows_credential_manager", "account_required", "api/app-account/browser-login",
                   '"open_browser":false', "konto/rueckkehr", "exam-registration-luh.json", "exam-registration-hildesheim.json",
                   "luh.json.gz", "study-plan.js",
                   "SkipHttpErrorCheck"):
        assert needle in ps, needle
    # was check-backend.ps1 als Paketdatei verlangt, steht auch in der Beschreibung
    bundled = {"/".join(b) for b in _bundled()}
    for f in re.findall(r'"((?:packages|apps)\\[^"]+)"', ps):
        assert f.replace("\\", "/") in bundled, f


def test_tesseract_step_is_pinned_and_verified():
    ps = (WIN / "scripts" / "add-tesseract.ps1").read_text(encoding="utf-8")
    assert '$tessVersion = "5.4.0.20240606"' in ps and "v$tessVersion/tesseract-ocr-w64-setup-$tessVersion.exe" in ps
    assert "HKLM:\\SOFTWARE\\Tesseract-OCR" in ps and '"Tesseract-OCR"' in ps, "feste Orte statt rekursiver Suche"
    assert "-Recurse -Filter \"tesseract.exe\"" not in ps.split("# ---------------------------------------------------------------- 3.")[0], \
        "vor dem 7-Zip-Rueckfall keine rekursive Suche ueber ganze Laufwerke"
    for needle in ("libtesseract-5.dll", "libleptonica-6.dll", "--version", "Fail \"tesseract.exe startet im Zielordner",
                   "Download gescheitert nach 3 Versuchen", "$LASTEXITCODE"):
        assert needle in ps, needle


def test_windows_workflow_runs_windows_tests_and_smoke():
    wf = (ROOT / ".github" / "workflows" / "windows.yml").read_text(encoding="utf-8")
    assert "tests/test_windows_package.py" in wf and "tests/test_desktop_windows.py" in wf
    assert wf.index("tests/test_windows_package.py") < wf.index("PyInstaller apps/windows/backend")


@pytest.mark.skipif(sys.platform != "win32", reason="Anmeldeinformationsverwaltung gibt es nur unter Windows")
def test_windows_credential_manager_roundtrip():
    """Echter Eintrag (eigenes Ziel, nicht das der App): schreiben, lesen, ueberschreiben, loeschen."""
    from app import token_store
    s = token_store.WindowsCredentialStore(target=f"StudiNow/ci-probe-{uuid.uuid4().hex}")
    try:
        assert s.get() is None
        s.set("dummy-token-äöü-" + "x" * 1500)
        assert s.get() == "dummy-token-äöü-" + "x" * 1500
        s.set("zweites")
        assert s.get() == "zweites"
    finally:
        s.delete()
    assert s.get() is None
    s.delete()                                                           # zweites Loeschen ist kein Fehler
    assert isinstance(token_store.default_store(), token_store.WindowsCredentialStore)


def test_store_json_placeholders_are_marked_until_partner_center_values_exist():
    """apps/windows/msix/store.json (08.11.2026): bis der Inhaber die drei Werte aus Partner Center eintraegt, stehen dort
    klar erkennbare Platzhalter und store_ready=false. Mit store_ready=true darf kein Platzhalter mehr drin sein, der
    Publisher beginnt mit CN= und der Identity Name hat die Form des Stores."""
    import json
    store = json.loads((WIN / "msix" / "store.json").read_text(encoding="utf-8"))
    keys = ("identity_name", "publisher", "publisher_display_name")
    assert set(store["_inhaber_traegt_ein"]) == set(keys), "die Liste fuer den Inhaber nennt genau die drei Werte"
    assert store["display_name"] == "StudiNow"
    if store["store_ready"]:
        assert all("PLATZHALTER" not in str(store[k]) for k in keys), "store_ready=true nur mit echten Werten"
        assert store["publisher"].startswith("CN=") and re.fullmatch(r"[A-Za-z0-9.-]{3,50}", store["identity_name"])
    else:
        assert all("PLATZHALTER" in str(store[k]) for k in keys), "Platzhalter muessen als solche erkennbar sein"
        assert "PLATZHALTER" in store["_hinweis"]
    # das Manifest nutzt genau diese Werte, und build-msix.ps1 warnt ohne store_ready
    manifest = (WIN / "msix" / "AppxManifest.xml.in").read_text(encoding="utf-8")
    for ph in ("{{IDENTITY_NAME}}", "{{PUBLISHER}}", "{{PUBLISHER_DISPLAY_NAME}}", "{{DISPLAY_NAME}}"):
        assert ph in manifest
    assert "store_ready" in (WIN / "scripts" / "build-msix.ps1").read_text(encoding="utf-8")

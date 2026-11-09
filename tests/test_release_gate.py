"""Statische Freigabepruefung der iPad-App (Audit P46-04/07/08, P47-10, 08.11.2026): Berechtigungstexte passen zu den
genutzten Schnittstellen, das Datenschutz-Manifest nennt die Geraete-ID, Hintergrundaufgaben und Entitlements passen
zu Code, Team-Vorlage und Website. Ersetzt nicht das signierte Archiv und den Geraetetest (docs/audit/AUDIT-2026-11-08-PAKET-46-47.md)."""
import plistlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APPLE = ROOT / "apps" / "apple"
YML = (APPLE / "project.yml").read_text(encoding="utf-8")
CODE = {p.relative_to(APPLE).as_posix(): p.read_text(encoding="utf-8")
        for base in ("UniFlow", "Packages/UniFlowCore/Sources") for p in (APPLE / base).rglob("*.swift")}

# Schnittstelle (Regex im Swift-Code) -> Schluessel, ohne den iOS die App beim ersten Aufruf beendet
PERMISSIONS = {
    r"AVAudioApplication\.requestRecordPermission|AVAudioRecorder\(|setCategory\(\.record": ["NSMicrophoneUsageDescription"],
    r"SFSpeechRecognizer\.requestAuthorization": ["NSSpeechRecognitionUsageDescription"],
    r"CLLocationManager\(": ["NSLocationWhenInUseUsageDescription"],
    r"AVCaptureDevice|VNDocumentCameraViewController|sourceType = \.camera|DataScannerViewController": ["NSCameraUsageDescription"],
    r"EKEventStore\(": ["NSCalendarsFullAccessUsageDescription", "NSCalendarsWriteOnlyAccessUsageDescription"],
    r"CNContactStore\(": ["NSContactsUsageDescription"],
    r"LAContext\(": ["NSFaceIDUsageDescription"],
    r"PHPhotoLibrary\.requestAuthorization\(for: \.readWrite": ["NSPhotoLibraryUsageDescription"],
    r"CBCentralManager\(": ["NSBluetoothAlwaysUsageDescription"],
}


def info_value(key: str) -> str | None:
    m = re.search(rf"^\s+{key}: (.+)$", YML, re.M)
    return m.group(1).strip() if m else None


def test_every_used_permission_has_its_usage_text():
    for pattern, keys in PERMISSIONS.items():
        users = [f for f, t in CODE.items() if re.search(pattern, t)]
        if users:
            assert any(info_value(k) for k in keys), (keys, users)


def test_speech_text_names_both_uses_and_matches_the_buttons():
    """P46-08: Spracherkennung gibt es fuer die Vorlesungsaufnahme und fuer "Transkript erstellen" an Audiodateien."""
    speech = info_value("NSSpeechRecognitionUsageDescription")
    assert "Vorlesungsaufnahmen" in speech and "„Transkript erstellen“" in speech and "ohne Server" in speech
    assert 'UFButton("Transkript erstellen' in CODE["UniFlow/Views/Library/TextDocumentView.swift"]
    assert 'UFButton("Aufnehmen"' in CODE["UniFlow/Views/Recordings/LectureRecorderViews.swift"]
    assert "„Aufnehmen“" in info_value("NSMicrophoneUsageDescription")
    # beide Erkenner nur auf dem Geraet (sonst stimmt "ohne Server" nicht)
    for f in ("UniFlow/Services/LectureRecorder.swift", "UniFlow/Services/AudioTranscriber.swift"):
        assert "requiresOnDeviceRecognition = true" in CODE[f], f


def test_privacy_manifest_declares_the_device_id_the_service_receives():
    """P46-04: die zufaellige Installationskennung geht als device_id an app.studinow.app -> Geraete-ID im Manifest."""
    account = CODE["Packages/UniFlowCore/Sources/UniFlowCore/Account/StudoraAccount.swift"]
    assert '"device_id": .string(deviceID)' in account
    # zufaellig, keine Hardware-Kennung; Praefix "ipad-" bzw. auf dem Mac "mac-" (Paritaet 09.11.2026, AccountDevice)
    assert 'AccountDevice.idPrefix(isMac: ProcessInfo.processInfo.isiOSAppOnMac) + UUID().uuidString' in CODE["UniFlow/Services/StudoraAccountLink.swift"]
    assert 'isMac ? "mac-" : "ipad-"' in CODE["Packages/UniFlowCore/Sources/UniFlowCore/Solutions/CommunitySharedState.swift"]
    for t in CODE.values():
        assert "identifierForVendor" not in t and "advertisingIdentifier" not in t
    m = plistlib.loads((APPLE / "UniFlow" / "PrivacyInfo.xcprivacy").read_bytes())
    kinds = {t["NSPrivacyCollectedDataType"] for t in m["NSPrivacyCollectedDataTypes"]}
    assert "NSPrivacyCollectedDataTypeDeviceID" in kinds
    # kein Standort, keine Kontakte, keine Diagnose-SDKs im Code, also auch nicht im Manifest
    assert not kinds & {"NSPrivacyCollectedDataTypePreciseLocation", "NSPrivacyCollectedDataTypeCoarseLocation",
                        "NSPrivacyCollectedDataTypeContacts", "NSPrivacyCollectedDataTypeCrashData"}


def test_background_tasks_and_audio_match_the_code():
    """P46-07: erlaubte BGTask-Kennungen = die im Code; Hintergrund-Audio nur fuer die Aufnahme der Vorlesung."""
    ids = re.search(r"BGTaskSchedulerPermittedIdentifiers:\n((?:\s+- .+\n)+)", YML).group(1)
    declared = set(re.findall(r"- (\S+)", ids))
    sync = CODE["UniFlow/Services/BackgroundSync.swift"]
    used = set(re.findall(r'static let (?:refresh|processing) = "([^"]+)"', sync))
    assert declared == used == {"de.uniflow.ai.sync.refresh", "de.uniflow.ai.sync.files"}
    modes = set(re.findall(r"- (\S+)", re.search(r"UIBackgroundModes:\n((?:\s+- .+\n)+)", YML).group(1)))
    assert modes == {"audio", "fetch", "processing"}, "kein Push, keine Ortung"
    # Audio-Sitzungen nur fuer Aufnahme (LectureRecorder) und vom Nutzer gestartete Wiedergabe von Aufnahmen/Videos
    # (Richtlinie 2.5.4); kein stilles Abspielen, um im Hintergrund wach zu bleiben
    cats = {(f, c) for f, t in CODE.items() for c in re.findall(r"setCategory\(\.(\w+)", t)}
    assert cats == {("UniFlow/Services/LectureRecorder.swift", "record"),
                    ("UniFlow/Views/Recordings/LectureRecorderViews.swift", "playback"),
                    ("UniFlow/Views/Recordings/RecordingsViews.swift", "playback")}, cats
    assert not any("AVAudioPlayer" in t and "numberOfLoops = -1" in t for t in CODE.values())
    # keine feste Uhrzeit versprochen
    assert 'timingText = "iOS entscheidet, wann genau; frühestens' in CODE["UniFlow/Views/Settings/BackgroundSyncCard.swift"]


def test_entitlements_match_team_template_and_website():
    ent = plistlib.loads((APPLE / "UniFlow" / "UniFlow.entitlements").read_bytes())
    team = (APPLE / "Config" / "Team.xcconfig.example").read_text(encoding="utf-8")
    container = re.search(r"^UF_CLOUDKIT_CONTAINER = (\S+)", team, re.M).group(1)
    assert ent["com.apple.developer.icloud-container-identifiers"] == [container]
    assert ent["com.apple.developer.icloud-services"] == ["CloudKit"]
    assert ent["com.apple.developer.applesignin"] == ["Default"]
    assert ent["com.apple.developer.associated-domains"] == ["applinks:studinow.app"]
    aasa = (ROOT / "site" / ".well-known" / "apple-app-site-association").read_text(encoding="utf-8")
    assert '"78MQGF36BD.de.uniflow.ai"' in aasa and '"/i/*"' in aasa
    assert 'linkBase = "https://studinow.app/i/"' in CODE["Packages/UniFlowCore/Sources/UniFlowCore/Account/InviteRewards.swift"]
    assert "PRODUCT_BUNDLE_IDENTIFIER: de.uniflow.ai\n" in YML


def test_release_info_plist_has_no_transport_exception_and_declares_export_compliance():
    info = YML.split("    info:\n", 1)[1].split("\n  UniFlowTests:", 1)[0]
    assert not re.search(r"^\s+NSAppTransportSecurity:", info, re.M) and "NSAllowsArbitraryLoads" not in YML
    assert 'if [ "${CONFIGURATION}" = "Debug" ]; then' in YML, "lokales Netz nur im Debug-Build"
    assert "ITSAppUsesNonExemptEncryption: false" in info
    assert 'TARGETED_DEVICE_FAMILY: "2"' in YML and 'iOS: "17.0"' in YML


def test_ci_runs_the_checks_that_read_apple_files():
    """P47-03/05/07/09: Python-Tests ohne Pfadfilter (sie lesen Swift, project.yml und docs/release), Apple-Workflow auch
    bei gemeinsamen Vertraegen und app/static/formats.js, iPad-Job manuell auch nach rotem Linux-Job, jede Stufe mit
    Zeitlimit."""
    import yaml
    wf = ROOT / ".github" / "workflows"
    load = lambda name: yaml.safe_load((wf / name).read_text(encoding="utf-8"))  # noqa: E731
    py = load("python.yml")
    on = py[True]                                       # YAML 1.1: der Schluessel "on" wird zu True
    assert "paths" not in on["push"] and "paths-ignore" not in on["push"] and "pull_request" in on
    assert any("pytest" in s.get("run", "") for s in py["jobs"]["pytest"]["steps"])
    assert "backend" not in load("ci.yml")["jobs"], "Python-Tests nur einmal (python.yml)"
    apple = load("apple.yml")
    for event in ("push", "pull_request"):
        paths = set(apple[True][event]["paths"])
        assert {"apps/apple/**", "packages/shared-contracts/**", "app/static/formats.js"} <= paths, (event, paths)
    assert "app/static/formats.js" in (APPLE / "Packages/UniFlowCore/Tests/UniFlowCoreTests/PageFormatsTests.swift").read_text(encoding="utf-8")
    ios = apple["jobs"]["ios"]
    assert ios["needs"] == "core-linux" and "workflow_dispatch" in ios["if"] and "!cancelled()" in ios["if"]
    for name in ("python.yml", "ci.yml", "apple.yml", "android.yml", "windows.yml"):
        for job, spec in load(name)["jobs"].items():
            assert isinstance(spec.get("timeout-minutes"), int), (name, job)

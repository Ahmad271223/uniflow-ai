"""Vorgabe des Inhabers (27.10.2026): Das Hochschul-Passwort merkt sich nur der Passwort-Manager des Systems im
Anmeldefenster, nie die App. Prueft die Android-Quellen und die Datenschutzerklaerung darauf."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "apps" / "android" / "app" / "src" / "main" / "kotlin" / "de" / "uniflow" / "android"


def test_webview_takes_part_in_system_autofill_and_app_stores_no_password():
    login = (APP / "ui" / "screens" / "UniversityLoginScreen.kt").read_text(encoding="utf-8")
    assert "importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_YES" in login
    assert "saveFormData" not in login and "savePassword" not in login, "kein eigenes Formular-Merken der WebView"
    for src in APP.rglob("*.kt"):
        text = src.read_text(encoding="utf-8")
        assert "HILDESHEIM_PASSWORD" not in text and "STUDIP_PASSWORD" not in text, src.name
        assert "evaluateJavascript" not in text and "callAsyncJavaScript" not in text, f"{src.name}: kein Vorausfuellen per Skript"
    store = (APP / "University.kt").read_text(encoding="utf-8")
    assert "password" not in store.lower(), "UniversityStore speichert nur Sitzungen (Cookies, Learnweb-Schluessel)"


def test_privacy_policy_and_readme_say_so():
    t = (ROOT / "docs" / "release" / "DATENSCHUTZ.md").read_text(encoding="utf-8")
    assert "Passwort-Manager deines Geräts" in t and "die App\n  selbst speichert weder Benutzername noch Passwort" in t
    r = (ROOT / "apps" / "android" / "README.md").read_text(encoding="utf-8")
    assert "Passwort-Manager des Systems" in r

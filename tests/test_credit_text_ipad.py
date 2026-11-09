"""Text der Credits in der iPad-/Mac-App (SettingsPage.swift, StudoraCreditsRow.explanation) passt zum Dienst:
1 Credit = 0,9 Cent echter KI-Kosten (Entscheidung des Inhabers 08.11.2026, app/ai_prices.MICROEUR_PER_CREDIT).
Bis Build 28 stand dort "1 Credit ist 1 Cent"."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SWIFT = ROOT / "apps" / "apple" / "UniFlow" / "Views" / "Settings" / "SettingsPage.swift"


def explanation() -> str:
    m = re.search(r'static let explanation = "([^"]+)"', SWIFT.read_text(encoding="utf-8"))
    assert m, "StudoraCreditsRow.explanation nicht gefunden"
    return m.group(1)


def test_service_values_one_credit_at_point_nine_cent():
    from app import ai_prices
    assert ai_prices.MICROEUR_PER_CREDIT == 9000


def test_app_text_names_point_nine_cent_not_one_cent():
    text = explanation()
    assert "1 Credit ist 1 Cent" not in text
    assert "0,9 Cent" in text
    assert "Pro AI hat 100" in text and "Probewoche 25" in text

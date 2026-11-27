"""Text der Credits in der iPad-/Mac-App (SettingsPage.swift, StudoraCreditsRow.explanation) passt zum Dienst:
1 Credit = 0,65 Cent echter KI-Kosten (Entscheidung des Inhabers 15.11.2026, vorher 0,9 Cent seit 08.11.2026;
app/ai_prices.MICROEUR_PER_CREDIT).
Bis Build 28 stand dort "1 Credit ist 1 Cent"."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SWIFT = ROOT / "apps" / "apple" / "UniFlow" / "Views" / "Settings" / "SettingsPage.swift"


def explanation() -> str:
    m = re.search(r'static let explanation = "([^"]+)"', SWIFT.read_text(encoding="utf-8"))
    assert m, "StudoraCreditsRow.explanation nicht gefunden"
    return m.group(1)


def test_service_values_one_credit_at_point_six_five_cent():
    from app import ai_prices
    assert ai_prices.MICROEUR_PER_CREDIT == 6500


def test_app_text_names_point_nine_cent_not_one_cent():
    text = explanation()
    assert "1 Credit ist 1 Cent" not in text
    # seit 11.11.2026 nennt die App keinen Centbetrag mehr (Entscheidung des Inhabers); der Dienst rechnet weiter so
    assert "Cent" not in text
    # seit 26.11.2026 (neues Tarifmodell) aus den Werten der App: Pro AI 120, Probewoche 25, KI nur mit Credits
    assert "Pro AI hat \\(UFPlan.proAI.monthlyCredits)" in text and "Probewoche \\(UFTrialTexts.credits)" in text
    assert "nur mit Credits" in text and "mit Plus und Pro AI" in text
    plans_swift = (ROOT / "apps" / "apple" / "UniFlow" / "Purchases" / "Plans.swift").read_text(encoding="utf-8")
    assert "case .proAI: return 120" in plans_swift

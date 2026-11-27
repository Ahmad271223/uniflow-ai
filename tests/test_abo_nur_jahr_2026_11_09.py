"""Nur noch Jahresabos (Entscheidung des Inhabers vom 09.11.2026, abends): "Monatliche Abos komplett entfernen. Nur
19,99 und 39,99." Angeboten werden StudiNow Plus (de.uniflow.plus.yearly, 19,99 EUR im Jahr) und StudiNow Pro AI
(de.uniflow.proai.yearly, 39,99 EUR im Jahr). Die frueheren Monatsprodukte (de.uniflow.plus.monthly, 1,99 EUR;
de.uniflow.proai.monthly, 3,99 EUR) bleiben beim Pruefen eines Kaufs lesbar (gelten wie der Tarif), werden aber
nirgends mehr angeboten oder genannt. Free, 7 Tage Probe (25 Credits), Pro AI 100 Credits im Monat bleiben.
Bericht: docs/release/ABO-NUR-JAHR-2026-11-09.md.

26.11.2026 neues Modell (docs/TARIFE-CREDITS-2026-11-26.md): Plus ist wieder das Monatsabo (de.uniflow.plus.monthly,
1,99 EUR) oder 39,99 EUR einmalig fuer 5 Jahre (de.uniflow.plus.fuenfjahre); Pro AI bleibt das Jahresabo. Das
Jahres-Plus und das Monats-Pro-AI gelten weiter, werden aber nicht mehr angeboten. Die Vertrags- und Einladungs-Tests
unten pruefen den neuen Stand; die Text-Tests den der Texte in diesem Zweig.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OLD_PRICES = ("1,99", "3,99", "21,99", "41,99")


def _read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def test_contract_offers_only_the_products_on_sale():
    """26.11.2026 neues Modell: angeboten werden Plus monatlich, Plus 5 Jahre und Pro AI jaehrlich - sonst nichts."""
    from app import plans as P
    c = P.contract()["plans"]
    assert (c["plus"]["price_cents"], c["pro_ai"]["price_cents"]) == (199, 3999)
    assert (c["plus"]["period"], c["pro_ai"]["period"]) == ("month", "year")
    assert c["plus"]["apple_product_id"] == "de.uniflow.plus.monthly"
    assert c["pro_ai"]["apple_product_id"] == "de.uniflow.proai.yearly"
    assert c["free"]["price_cents"] == 0 and c["free"]["apple_product_id"] is None
    # 27.11.2026: Pro AI auch monatlich (3,99 EUR) wieder im Verkauf; das Jahres-Plus bleibt draussen
    assert [o["product_id"] for o in P.contract()["offers"]] == ["de.uniflow.plus.monthly", "de.uniflow.proai.monthly",
                                                                "de.uniflow.proai.yearly", "de.uniflow.plus.fuenfjahre"]
    text = json.dumps(P.contract(), ensure_ascii=False)
    for old in ("de.uniflow.plus.yearly", "price_cents_yearly", "apple_product_id_yearly"):
        assert old not in text, old
    fixture = _read("packages/shared-contracts/fixtures/plans/plans.json")
    assert "de.uniflow.plus.yearly" not in fixture
    assert '"price_cents": 199,' in fixture and '"price_cents": 3999' in fixture


def test_old_monthly_products_still_unlock_their_plan():
    from app import plans as P
    assert P.plan_for_product("de.uniflow.plus.monthly") == "plus"
    assert P.plan_for_product("de.uniflow.proai.monthly") == "pro_ai"
    assert P.plan_for_product("de.uniflow.plus.yearly") == "plus"
    assert P.plan_for_product("de.uniflow.proai.yearly") == "pro_ai"
    assert P.plan_for_product("de.uniflow.free.yearly") is None and P.plan_for_product(None) is None


def test_invite_rewards_are_gone():
    """27.11.2026: keine Belohnungen fuer Einladungen mehr (Inhaber "gar keine mehr, entnimm das komplett"); die ruhende
    Technik zeigt weiter auf die angebotenen Produkte (Plus monatlich, Pro AI jaehrlich)."""
    from app import invites
    assert invites.TIERS == () and invites.REWARD_LABELS == {}
    assert invites.CHOICES["plus"]["apple_product_id"] == "de.uniflow.plus.monthly"
    assert invites.CHOICES["proai"]["apple_product_id"] == "de.uniflow.proai.yearly"
    cases = _read("packages/shared-contracts/fixtures/invites/cases.json")
    assert "gratis" not in cases and not any(p in cases for p in OLD_PRICES)


def test_web_plan_page_shows_the_yearly_price_only():
    js = _read("app/static/views-abo.js")
    assert "price_cents_yearly" not in js and "/ Monat</span>" not in js
    assert "/ Jahr" in js


# 26.11.2026 neues Modell: nicht mehr verkauft sind Plus im Jahr (19,99), Pro AI im Monat (3,99) und die Preise vom
# 07.11.2026 (21,99 / 41,99); 1,99 EUR ist wieder der Preis von Plus im Monat
# 27.11.2026: Pro AI im Monat (3,99) wird wieder verkauft
SOLD_NO_MORE = (r"19,99\s*(€|EUR)", r"21,99\s*(€|EUR)", r"41,99\s*(€|EUR)")


def test_public_texts_name_only_the_prices_on_sale():
    """26.11.2026 neues Modell (frueher: nur die Jahrespreise): die oeffentlichen Texte nennen Plus 1,99 € im Monat bzw.
    39,99 € fuer 5 Jahre und Pro AI 39,99 € im Jahr, keinen nicht mehr verkauften Preis."""
    for rel in ("docs/release/STARTSEITE.md", "docs/release/NUTZUNGSBEDINGUNGEN.md", "docs/release/EINLADUNG.md",
                "site/index.html", "site/nutzungsbedingungen.html", "site/i/index.html", "README.md",
                "docs/PREISLISTE.md", "docs/ABO-SYSTEM.md", "docs/release/TESTFLIGHT-500-2026-11-08.md"):
        t = _read(rel)
        for p in SOLD_NO_MORE:
            assert not re.search(r"(?<![\d,])" + p, t), f"{rel}: {p}"
        assert "monatlicher oder jährlicher Zahlung" not in t, rel
    for rel in ("docs/release/STARTSEITE.md", "site/index.html", "docs/release/NUTZUNGSBEDINGUNGEN.md",
                "site/nutzungsbedingungen.html"):
        t = _read(rel)
        assert "1,99 €" in t and "39,99 €" in t, rel


def test_terms_describe_the_renewal():
    """26.11.2026 neues Modell: Plus monatlich oder 5 Jahre einmalig (verlaengert sich nicht), Pro AI jaehrlich."""
    nb = " ".join(_read("docs/release/NUTZUNGSBEDINGUNGEN.md").split())
    assert "Monatsabo für 1,99 € im Monat" in nb and "39,99 € pro Jahr" in nb
    assert "einmalig für 39,99 € für 5 Jahre" in nb and "Es verlängert sich nicht" in nb
    assert "verlängert sich automatisch um denselben Zeitraum" in nb and "24 Stunden vor Ablauf" in nb
    assert "einen Monat bzw. ein Jahr" not in nb


def test_app_store_texts_name_only_the_yearly_subscriptions():
    t = _read("docs/release/APP-STORE.md")
    for s in ("StudiNow Plus (19,99 €/Jahr)", "StudiNow Pro AI (39,99 €/Jahr)"):
        assert s in t, s
    for s in ("1,99 €/Monat", "3,99 €/Monat", "21,99 €", "41,99 €", "Monatlich · Jährlich", "einen Monat bzw. ein Jahr"):
        assert s not in t, s


def test_ipad_offers_only_the_products_on_sale():
    """Statische Pruefung der Swift-Quellen; das Verhalten pruefen PlanContractTests und AboNurJahrAppTests.
    26.11.2026 neues Modell (Stand der Swift-Quellen in diesem Zweig): verkauft werden die Angebote UFOffer (Plus
    monatlich, Plus 5 Jahre einmalig, Pro AI jaehrlich)."""
    plans_swift = _read("apps/apple/UniFlow/Purchases/Plans.swift")
    assert "static var sellableProductIDs: [String] { UFOffer.allCases.map(\\.productID) }" in plans_swift
    assert 'case plusMonthly = "de.uniflow.plus.monthly"' in plans_swift and 'case plusFiveYears = "de.uniflow.plus.fuenfjahre"' in plans_swift
    picker = _read("apps/apple/UniFlow/Views/Onboarding/PlanPickerView.swift")
    assert "plans.billing" not in picker and "günstiger" not in picker
    store = _read("apps/apple/UniFlow/Purchases/PurchaseStore.swift")
    assert "günstiger als monatlich" not in store and "billing: UFBilling = .monthly" not in store
    sk = json.loads(_read("apps/apple/UniFlowTests/UniFlow.storekit"))
    subs = [s for g in sk["subscriptionGroups"] for s in g["subscriptions"]]
    assert sorted((s["productID"], s["displayPrice"], s["recurringSubscriptionPeriod"]) for s in subs) == [
        ("de.uniflow.plus.monthly", "1.99", "P1M"), ("de.uniflow.proai.monthly", "3.99", "P1M"),
        ("de.uniflow.proai.yearly", "39.99", "P1Y")]  # 27.11.2026: Pro AI auch monatlich
    assert [p["productID"] for p in sk.get("nonRenewingSubscriptions") or []] == ["de.uniflow.plus.fuenfjahre"]

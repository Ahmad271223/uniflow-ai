"""Nur noch Jahresabos (Entscheidung des Inhabers vom 09.11.2026, abends): "Monatliche Abos komplett entfernen. Nur
19,99 und 39,99." Angeboten werden StudiNow Plus (de.uniflow.plus.yearly, 19,99 EUR im Jahr) und StudiNow Pro AI
(de.uniflow.proai.yearly, 39,99 EUR im Jahr). Die frueheren Monatsprodukte (de.uniflow.plus.monthly, 1,99 EUR;
de.uniflow.proai.monthly, 3,99 EUR) bleiben beim Pruefen eines Kaufs lesbar (gelten wie der Tarif), werden aber
nirgends mehr angeboten oder genannt. Free, 7 Tage Probe (25 Credits), Pro AI 100 Credits im Monat bleiben.
Bericht: docs/release/ABO-NUR-JAHR-2026-11-09.md.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OLD_PRICES = ("1,99", "3,99", "21,99", "41,99")


def _read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def test_contract_offers_only_the_yearly_products():
    from app import plans as P
    c = P.contract()["plans"]
    assert (c["plus"]["price_cents"], c["pro_ai"]["price_cents"]) == (1999, 3999)
    assert (c["plus"]["period"], c["pro_ai"]["period"]) == ("year", "year")
    assert c["plus"]["apple_product_id"] == "de.uniflow.plus.yearly"
    assert c["pro_ai"]["apple_product_id"] == "de.uniflow.proai.yearly"
    assert c["free"]["price_cents"] == 0 and c["free"]["apple_product_id"] is None
    text = json.dumps(P.contract(), ensure_ascii=False)
    assert "monthly" not in text and "price_cents_yearly" not in text and "apple_product_id_yearly" not in text
    fixture = _read("packages/shared-contracts/fixtures/plans/plans.json")
    assert "monthly" not in fixture and '"price_cents": 1999' in fixture and '"price_cents": 3999' in fixture


def test_old_monthly_products_still_unlock_their_plan():
    from app import plans as P
    assert P.plan_for_product("de.uniflow.plus.monthly") == "plus"
    assert P.plan_for_product("de.uniflow.proai.monthly") == "pro_ai"
    assert P.plan_for_product("de.uniflow.plus.yearly") == "plus"
    assert P.plan_for_product("de.uniflow.proai.yearly") == "pro_ai"
    assert P.plan_for_product("de.uniflow.free.yearly") is None and P.plan_for_product(None) is None


def test_invite_rewards_use_the_yearly_products():
    from app import invites
    assert invites.CHOICES["plus"]["apple_product_id"] == "de.uniflow.plus.yearly"
    assert invites.CHOICES["proai"]["apple_product_id"] == "de.uniflow.proai.yearly"
    label = invites.REWARD_LABELS[(20, "proai")]
    assert "19,99 €" in label and "39,99 €" in label and not any(p in label for p in OLD_PRICES)
    cases = _read("packages/shared-contracts/fixtures/invites/cases.json")
    assert label in cases and not any(p in cases for p in OLD_PRICES)


def test_web_plan_page_shows_the_yearly_price_only():
    js = _read("app/static/views-abo.js")
    assert "price_cents_yearly" not in js and "/ Monat</span>" not in js
    assert "/ Jahr" in js


def test_public_texts_name_only_the_yearly_prices():
    for rel in ("docs/release/STARTSEITE.md", "docs/release/NUTZUNGSBEDINGUNGEN.md", "docs/release/EINLADUNG.md",
                "site/index.html", "site/nutzungsbedingungen.html", "site/i/index.html", "README.md",
                "docs/PREISLISTE.md", "docs/ABO-SYSTEM.md", "docs/release/TESTFLIGHT-500-2026-11-08.md"):
        t = _read(rel)
        for p in OLD_PRICES:
            assert not re.search(r"(?<![\d,])" + re.escape(p) + r"\s*(€|EUR)", t), f"{rel}: {p} €"
        assert "monatlich kündbar" not in t and "monatlicher oder jährlicher Zahlung" not in t, rel
    for rel in ("docs/release/STARTSEITE.md", "site/index.html", "docs/release/NUTZUNGSBEDINGUNGEN.md",
                "site/nutzungsbedingungen.html"):
        t = _read(rel)
        assert "19,99 €" in t and "39,99 €" in t, rel


def test_terms_describe_the_yearly_renewal():
    nb = _read("docs/release/NUTZUNGSBEDINGUNGEN.md")
    assert "19,99 € pro Jahr" in nb and "39,99 € pro Jahr" in nb
    assert "verlängert sich automatisch um ein Jahr" in nb and "24 Stunden vor Ablauf" in nb
    assert "einen Monat bzw. ein Jahr" not in nb


def test_app_store_texts_name_only_the_yearly_subscriptions():
    t = _read("docs/release/APP-STORE.md")
    for s in ("StudiNow Plus (19,99 €/Jahr)", "StudiNow Pro AI (39,99 €/Jahr)"):
        assert s in t, s
    for s in ("1,99 €/Monat", "3,99 €/Monat", "21,99 €", "41,99 €", "Monatlich · Jährlich", "einen Monat bzw. ein Jahr"):
        assert s not in t, s


def test_ipad_offers_only_the_yearly_products():
    """Statische Pruefung der Swift-Quellen; das Verhalten pruefen PlanContractTests und AboNurJahrAppTests."""
    plans_swift = _read("apps/apple/UniFlow/Purchases/Plans.swift")
    assert "static var sellableProductIDs: [String] { sellable.compactMap(\\.productID) }" in plans_swift
    assert "var productID: String? { productID(.yearly) }" in plans_swift
    picker = _read("apps/apple/UniFlow/Views/Onboarding/PlanPickerView.swift")
    assert "plans.billing" not in picker and "günstiger" not in picker
    store = _read("apps/apple/UniFlow/Purchases/PurchaseStore.swift")
    assert "günstiger als monatlich" not in store and "billing: UFBilling = .monthly" not in store
    sk = json.loads(_read("apps/apple/UniFlowTests/UniFlow.storekit"))
    subs = [s for g in sk["subscriptionGroups"] for s in g["subscriptions"]]
    assert sorted((s["productID"], s["displayPrice"], s["recurringSubscriptionPeriod"]) for s in subs) == [
        ("de.uniflow.plus.yearly", "19.99", "P1Y"), ("de.uniflow.proai.yearly", "39.99", "P1Y")]

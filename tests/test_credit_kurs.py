"""Kurs der Credits (Entscheidung des Inhabers 24.11.2026): einheitlich 1 Credit = 1 Cent echter KI-Kosten, kein
Aufschlag fuer starke Modelle, Pro AI 80 Credits im Monat (= hoechstens 0,80 EUR KI-Kosten je Konto). Abgezogen wird,
was die Antwort laut `usage` gekostet hat, aufgerundet auf ganze Credits. Die uebrigen Credit-Tests rechnen mit dem
alten Kurs als Beispiel (tests/conftest.py `_credit_kurs_bis_24_11`)."""
from app import ai_prices, credits, plans


def test_one_credit_is_one_cent():
    assert ai_prices.MICROEUR_PER_CREDIT == 10_000
    assert ai_prices.credits_for(10_000) == 1
    assert ai_prices.credits_for(10_001) == 2, "immer aufgerundet"
    assert ai_prices.credits_for(1) == 1, "auch eine winzige Frage kostet einen Credit"
    assert ai_prices.credits_for(0) == 0


def test_no_surcharge_for_strong_models(monkeypatch):
    monkeypatch.delenv(ai_prices.STRONG_FACTOR_ENV, raising=False)
    assert ai_prices.STRONG_CREDIT_FACTOR == 1.0
    assert ai_prices.credit_factor("gpt-6.1-sol") == 1.0
    assert ai_prices.credit_factor("claude-sonnet-5-5") == 1.0
    # eine lange Rechen-Antwort mit 4,9 Cent kostet 5 Credits (vorher 10)
    assert ai_prices.credits_for(49_000, "gpt-6.1-sol") == 5
    assert ai_prices.credits_for(49_000, "gpt-6-luna") == 5


def test_pro_ai_has_80_credits_and_costs_at_most_80_cent(monkeypatch):
    monkeypatch.delenv("LERNAPP_CREDITS_PRO_AI", raising=False)
    assert plans.CREDITS["pro_ai"] == 80
    assert credits.allowance("pro_ai", False) == 80
    assert credits.allowance("pro_ai", False) * ai_prices.MICROEUR_PER_CREDIT / 1_000_000 == 0.80


def test_packs_have_80_and_160_credits_and_cost_at_most_their_cents(monkeypatch):
    monkeypatch.delenv("LERNAPP_CREDIT_PACKS", raising=False)
    assert [p["credits"] for p in plans.credit_packs()] == [80, 160]
    assert [p["credits"] * ai_prices.MICROEUR_PER_CREDIT / 1_000_000 for p in plans.credit_packs()] == [0.8, 1.6]

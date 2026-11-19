

# ---------------------------------------------------------------- Aufschlag starke Modelle (18.11.2026 abends)

def test_strong_model_costs_thirty_percent_more_credits(monkeypatch):
    from app import ai_prices
    monkeypatch.delenv("LERNAPP_CREDIT_STRONG_FACTOR", raising=False)
    monkeypatch.delenv("LERNAPP_AI_PRICES", raising=False)
    monkeypatch.delenv("LERNAPP_AI_PRICE_IN_EUR", raising=False)
    monkeypatch.delenv("LERNAPP_AI_PRICE_OUT_EUR", raising=False)
    # die echte Antwort vom 18.11.: 4,86 Cent mit gpt-6.1-sol -> 10 Credits (vorher 8)
    assert ai_prices.credits_for(48_562) == 8
    assert ai_prices.credits_for(48_562, "gpt-6.1-sol") == 10
    assert ai_prices.credits_for(48_562, "claude-sonnet-5-5") == 10
    # guenstige und mittlere Modelle bleiben beim Kurs
    assert ai_prices.credits_for(770, "gpt-6-luna") == 1
    assert ai_prices.credits_for(48_562, "gpt-6.1-terra") == 8
    assert ai_prices.credit_factor(None) == 1.0
    assert ai_prices.credit_factor("unbekanntes-modell") == 1.0


def test_strong_factor_is_configurable_and_bounded(monkeypatch):
    from app import ai_prices
    monkeypatch.setenv("LERNAPP_CREDIT_STRONG_FACTOR", "1")
    assert ai_prices.credits_for(48_562, "gpt-6.1-sol") == 8
    monkeypatch.setenv("LERNAPP_CREDIT_STRONG_FACTOR", "1,5")
    assert ai_prices.credits_for(48_562, "gpt-6.1-sol") == 12
    for bad in ("0.5", "abc", "nan", "99"):
        monkeypatch.setenv("LERNAPP_CREDIT_STRONG_FACTOR", bad)
        assert ai_prices.credit_factor("gpt-6.1-sol") == ai_prices.STRONG_CREDIT_FACTOR


def test_reservation_covers_the_strong_charge(monkeypatch):
    from app import ai_prices
    for k in ("LERNAPP_CREDIT_STRONG_FACTOR", "LERNAPP_AI_PRICES", "LERNAPP_AI_PRICE_IN_EUR", "LERNAPP_AI_PRICE_OUT_EUR"):
        monkeypatch.delenv(k, raising=False)
    worst = ai_prices.worst_case_microeur("gpt-6.1-sol", "s", "frage " * 400, 6000, None, None)
    assert ai_prices.estimate_credits("gpt-6.1-sol", "s", "frage " * 400, 6000) >= ai_prices.credits_for(worst, "gpt-6.1-sol")
    assert ai_prices.estimate_credits("gpt-6.1-sol", "s", "frage " * 400, 6000) > ai_prices.credits_for(worst)

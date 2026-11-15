"""Texte zum Stand der Credits mit zwei Toepfen (15.11.2026, docs/KI-CREDITS-2026-11-15.md) - die Referenz fuer alle
Oberflaechen. Der Dienst zeigt selbst nichts an; `tools/gen-credit-packs-fixture.py` schreibt aus diesen Funktionen
`packages/shared-contracts/fixtures/credit-packs/contract.json`, und die Apple-App (CreditPacks.swift) und die
Web-Oberflaeche (app/static/ai-panel.js) pruefen ihre eigenen Texte dagegen.

Eingabe ist immer der Stand, wie ihn der Dienst liefert (`credits` aus GET /api/entitlements, app/credits.py):
`allowance`/`remaining` = Monats-Credits, `purchased` = gekaufte, `purchased_usable`, `purchased_scope`, `can_buy`,
`resets_at`. Ein Stand ohne `purchased` (aelterer Dienst) zaehlt als 0 gekaufte Credits.

Wofuer gekaufte Credits gelten (`purchased_scope`, Entscheidung des Inhabers 15.11.2026): "all" mit Pro AI und in der
Probe, "chat" mit Plus (nur Fragen an die KI), "none" mit Free (sie ruhen beim Konto).
"""
from __future__ import annotations

MONTHS = ("Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember")

TITLE_EXHAUSTED = "Deine Credits sind aufgebraucht"
TITLE_SHOP = "Credits kaufen"
NOT_NOW = "Nicht jetzt"
KEEP = "Gekaufte Credits verfallen nicht."
BUY_NEEDS_PRO_AI = "Credits kaufen kannst du mit StudiNow Plus oder Pro AI."
# Plus: was gekaufte Credits koennen (Blatt mit den Paketen) und was an den Lernhilfe-Knoepfen der KI-Hilfe steht
CHAT_ONLY = "Mit Credits kannst du Fragen an die KI stellen. Erklärungen, Karteikarten und Tests gibt es mit Pro AI."
CHAT_LOCK = "Mit StudiNow Plus stellst du der KI Fragen. Erklären, Karteikarten und Tests gibt es mit StudiNow Pro AI."
WEB_HINT = "Credits kaufst du in der App für iPhone und iPad."
NO_CREDITS = "Keine Credits in deinem Tarif"


def _int(v) -> int:
    try:
        return max(0, int(v or 0))
    except (TypeError, ValueError):
        return 0


def reset_day(resets_at: str | None) -> str | None:
    """"1. Dezember" aus `resets_at` (ISO, Beginn des naechsten Monats in Berlin); None ohne lesbares Datum."""
    s = str(resets_at or "")
    if len(s) < 10 or s[4] != "-" or s[7] != "-" or not (s[:4] + s[5:7] + s[8:10]).isdigit():
        return None
    month, day = int(s[5:7]), int(s[8:10])
    if not 1 <= month <= 12 or not 1 <= day <= 31:
        return None
    return f"{day}. {MONTHS[month - 1]}"


def pack_label(credits: int) -> str:
    """Beschriftung eines Pakets: "100 Credits" (die Zahl kommt vom Dienst, der Preis aus dem Store)."""
    return f"{_int(credits)} Credits"


def scope(c: dict | None) -> str:
    """Wofuer die gekauften Credits gelten: all | chat | none (`purchased_scope`; ohne das Feld aus `purchased_usable`)"""
    if not isinstance(c, dict):
        return "none"
    s = c.get("purchased_scope")
    if s in ("all", "chat", "none"):
        return s
    return "all" if c.get("purchased_usable") else "none"


def balance_line(c: dict | None) -> str | None:
    """Stand beider Toepfe: "Diesen Monat: 37 von 100 · Gekauft: 80". Ohne Monats-Credits im Tarif steht nur der
    gekaufte Topf: bei Plus "Gekauft: 80" (auch mit 0), ruhend mit dem Weg dahin; ganz ohne Credits und ohne Kaufrecht
    "Keine Credits in deinem Tarif"; None ohne Stand."""
    if not isinstance(c, dict):
        return None
    allowance, remaining, bought = _int(c.get("allowance")), _int(c.get("remaining")), _int(c.get("purchased"))
    if allowance > 0:
        return f"Diesen Monat: {remaining} von {allowance} · Gekauft: {bought}"
    if scope(c) != "none":
        return f"Gekauft: {bought}"
    if bought > 0:
        return f"Gekauft: {bought} · nutzbar mit StudiNow Plus oder Pro AI"
    return NO_CREDITS


def keep_note(c: dict | None) -> str:
    """Satz im Blatt: "Gekaufte Credits verfallen nicht. Deine 100 Monats-Credits gibt es am 1. Dezember wieder." Ohne
    Monats-Credits oder ohne Datum bleibt nur der erste Satz."""
    c = c if isinstance(c, dict) else {}
    allowance, day = _int(c.get("allowance")), reset_day(c.get("resets_at"))
    if allowance > 0 and day:
        return f"{KEEP} Deine {allowance} Monats-Credits gibt es am {day} wieder."
    return KEEP


def dormant_note(c: dict | None) -> str | None:
    """Ehrlicher Hinweis, wenn gekaufte Credits ruhen (Pro AI ist vorbei): sie bleiben beim Konto. None sonst."""
    if not isinstance(c, dict) or c.get("purchased_usable") or _int(c.get("purchased")) == 0:
        return None
    n = _int(c.get("purchased"))
    return (f"Du hast noch {n} gekaufte Credits. Sie bleiben bei deinem Konto und sind wieder nutzbar, "
            "sobald StudiNow Plus oder Pro AI läuft.")


def scope_note(c: dict | None) -> str | None:
    """Satz im Blatt mit den Paketen fuer Plus: was gekaufte Credits dort koennen. None, wenn sie fuer alles gelten."""
    return CHAT_ONLY if scope(c) == "chat" else None


def available(c: dict | None) -> int:
    """Was jetzt fuer die KI da ist: Rest des Monats plus nutzbare gekaufte Credits."""
    if not isinstance(c, dict):
        return 0
    return _int(c.get("remaining")) + (_int(c.get("purchased")) if c.get("purchased_usable") else 0)


def offers_shop(c: dict | None) -> bool:
    """Zeigt die App bei leeren Credits das Blatt mit den Paketen? Nur, wenn das Konto kaufen darf (`can_buy`)."""
    return isinstance(c, dict) and bool(c.get("can_buy"))

"""StudiNow-Tarife und Berechtigungen: die eine Tabelle fuer Server, Web, Windows und die Apps.

Entscheidung des Inhabers vom 04.11.2026 (docs/PREISLISTE.md, docs/ABO-SYSTEM.md): drei Tarife Free 0 EUR, Plus
1,99 EUR, Pro AI 3,99 EUR (Monatspreise, Endkundenpreise). Jeder Tarif enthaelt alle Rechte des naechstniedrigeren.
Angleichung vom 05.11.2026 (docs/ENTSCHEIDUNGEN-INHABER-2026-11-05.md): Free ohne Community (auch kein Lesen) und ohne
StudiNow-KI, das eigene ChatGPT darf in jedem Tarif verbunden werden (Fragen zu Folien; Schreiben erst ab Plus); Plus
mit Community, Schreiben, eigenen Karteikarten und begrenzt Karteikarten-Stapeln von StudiNow (4/Monat); Pro AI mit
StudiNow-KI, 20 neuen KI-Tests und unbegrenzt Tests und Stapeln (Fair Use).
Pro Connect (2,99 EUR, Auftrag vom 27.10.2026) gibt es nicht mehr: der Schluessel bleibt nur fuer alte Zeilen in
accounts.db/entitlements lesbar (`LEGACY_PLANS`), wird nirgends angeboten oder gezeigt; seine frueheren Rechte
(Lernstatistik, Wiederholung, Empfehlungen, Testhistorie) gehoeren jetzt zu Pro AI.

Diese Datei ist die Quelle. `tools/gen-plans-fixture.py` schreibt daraus
`packages/shared-contracts/fixtures/plans/plans.json`; die Apps (Swift, Kotlin) lesen die Fixture und pruefen ihre
eigene Tabelle dagegen, `tests/test_subscriptions.py` prueft, dass Fixture und diese Datei gleich sind.

Regeln:
- Ein Recht ist ein Name (`can_annotate_pdf`) mit Ja/Nein je Tarif; Kontingente sind Zahlen je Abrechnungsmonat
  (`None` = unbegrenzt, dann gilt die Fair-Use-Grenze aus `FAIR_USE`).
- `status` je Recht sagt der Oberflaeche, ob die Funktion schon technisch freigeschaltet ist (`available`), noch
  gebaut wird (`coming_soon`) oder bewusst aus ist (`disabled`). Nur `available` darf als enthalten beworben werden.
- Begriffe: "Lernstand" ist die Zahl je Modul aus eigenen Daten (app/mastery.py, Mastery.swift) und in jedem Tarif
  frei; "Lernstatistik" ist die moduluebergreifende Auswertung des Dienstes (/api/learning/*) ab Pro AI.
- `chatgpt_connection_premium` (Name historisch) ist eine reine Produktregel: seit 05.11.2026 in jedem Tarif (Free
  darf sein eigenes ChatGPT verbinden und zu Folien fragen). Die offizielle Verbindung zu ChatGPT haengt nie am Tarif:
  siehe `INTEGRATIONS["chatgpt"]` und docs/ABO-SYSTEM.md, Abschnitt 4.
"""
from __future__ import annotations

# die drei Tarife, die es gibt (Reihenfolge der Karten und des Rangs)
ORDER = ("free", "plus", "pro_ai")

# nicht mehr angebotene Tarife, deren Schluessel in alten Zeilen stehen kann; sie gelten wie der Tarif, auf den sie
# zeigen (Rechte und Kontingente), erscheinen aber in keiner Liste und sind nicht kaufbar
LEGACY_PLANS = {"pro_connect": "pro_ai"}

PLANS: dict[str, dict] = {
    "free": {"rank": 0, "name": "StudiNow Free", "price_cents": 0, "currency": "EUR", "period": "month",
             "apple_product_id": None,
             "tagline": "Studium organisieren und Unterlagen lesen"},
    "plus": {"rank": 1, "name": "StudiNow Plus", "price_cents": 199, "currency": "EUR", "period": "month",
             "apple_product_id": "de.uniflow.plus.monthly",
             "tagline": "Mit Stift auf deinen Unterlagen schreiben, Karteikarten und Wochentests"},
    "pro_ai": {"rank": 2, "name": "StudiNow Pro AI", "price_cents": 399, "currency": "EUR", "period": "month",
               "apple_product_id": "de.uniflow.proai.monthly",
               "tagline": "KI von StudiNow inklusive – kein eigenes ChatGPT-Konto nötig"},
    # nur fuer alte Zeilen (LEGACY_PLANS): Rang wie Pro AI, nicht in ORDER, nicht kaufbar, nicht sichtbar
    "pro_connect": {"rank": 2, "name": "StudiNow Pro AI", "price_cents": 399, "currency": "EUR", "period": "month",
                    "apple_product_id": "de.uniflow.proconnect.monthly",
                    "tagline": "KI von StudiNow inklusive – kein eigenes ChatGPT-Konto nötig", "legacy": True},
}

# Recht -> niedrigster Tarif, der es hat (Tarife sind aufsteigend enthalten), dazu Text und Stand der Umsetzung
ENTITLEMENTS: dict[str, dict] = {
    # Free (Grundfunktionen, bleiben wie heute)
    "can_view_pdf": {"from": "free", "label": "PDFs öffnen und lesen", "status": "available"},
    "can_manage_courses": {"from": "free", "label": "Hochschulkurse und Module verwalten", "status": "available"},
    "can_import_documents": {"from": "free", "label": "Automatischer Dokumentimport aus Stud.IP bzw. Learnweb", "status": "available"},
    "can_view_timetable": {"from": "free", "label": "Stundenplan ansehen", "status": "available"},
    "can_use_basic_planner": {"from": "free", "label": "Lernkalender und Lernplanung", "status": "available"},
    # Eigenes ChatGPT (Entscheidung 05.11.2026): in jedem Tarif, auch Free (Fragen zu Folien). Die OpenAI-Bedingungen
    # verbieten ohnehin, die Nutzung an einen bezahlten Tarif zu koppeln (INTEGRATIONS, plan_gating_allowed False).
    "chatgpt_connection_premium": {"from": "free", "label": "Eigenes ChatGPT verbinden und zu Folien fragen (in Vorbereitung)", "status": "disabled"},
    # Plus
    # Community (Entscheidung 05.11.2026): ab Plus auch das Lesen, Free sieht nur den Hinweis "Community ab Plus".
    # Eigene Beitraege lassen sich nach dem Herabstufen trotzdem zurueckziehen (nichts wird geloescht).
    "can_read_community": {"from": "plus", "label": "Community lesen, beitreten und mitmachen", "status": "available"},
    "can_annotate_pdf": {"from": "plus", "label": "PDF-Annotationen, Textmarker, Radierer, Zeichenwerkzeuge, Textfelder", "status": "available"},
    "can_use_pencilkit": {"from": "plus", "label": "Apple Pencil (PencilKit) und handschriftliche Notizen", "status": "available"},
    "can_write_community_comments": {"from": "plus", "label": "Community-Kommentare schreiben", "status": "available"},
    "can_share_solutions": {"from": "plus", "label": "Eigene Lösungen teilen", "status": "available"},
    "can_access_shared_tests": {"from": "plus", "label": "Tests aus der StudiNow-Bibliothek", "status": "available"},
    "can_generate_studora_ai_tests": {"from": "plus", "label": "Neue KI-Tests von StudiNow", "status": "available"},
    # Eigene Karteikarten (Entscheidung 04.11.2026): anlegen, bearbeiten, ueben, Stapel, teilen und geteilte bzw.
    # Wochenstapel uebernehmen ab Plus. Lesen (GET /api/flashcards, /api/flashcard-stacks) bleibt in jedem Tarif frei:
    # nach der Probe sind die eigenen Karten in Free weiter sichtbar, nur nicht mehr bearbeit- oder uebbar.
    "can_use_flashcards": {"from": "plus", "label": "Eigene Karteikarten mit Wiederholung", "status": "available"},
    # Pro AI: Lernstatistik und Planung des Dienstes (frueher Pro Connect). Die Endpunkte /api/learning/* gibt es,
    # eine Oberflaeche dafuer noch nicht (Web und iPad): darum coming_soon, nie als enthalten beworben.
    "can_use_advanced_analytics": {"from": "pro_ai", "label": "Lernstatistik über alle Module", "status": "coming_soon"},
    "can_use_advanced_planner": {"from": "pro_ai", "label": "Intelligente Lernplanung (Empfehlungen für die Woche)", "status": "coming_soon"},
    "can_review_wrong_answers": {"from": "pro_ai", "label": "Automatische Wiederholung falscher Antworten", "status": "coming_soon"},
    "can_use_extended_test_history": {"from": "pro_ai", "label": "Vollständige Testliste (Free und Plus: die letzten 10)", "status": "available"},
    "can_get_recommendations": {"from": "pro_ai", "label": "Personalisierte Lernempfehlungen", "status": "coming_soon"},
    # Pro AI (StudiNow-KI ueber das Backend)
    "can_use_ai_explanations": {"from": "pro_ai", "label": "KI-Erklärungen zu Aufgaben", "status": "available"},
    "can_use_ai_generated_questions": {"from": "pro_ai", "label": "Automatische Lernfragen und Wiederholungsaufgaben", "status": "available"},
    "can_use_ai_summaries": {"from": "pro_ai", "label": "KI-Zusammenfassungen", "status": "available"},
    # KI-Lernempfehlungen: noch kein Endpunkt und keine Oberflaeche (04.11.2026), darum nicht als enthalten beworben
    "can_use_ai_recommendations": {"from": "pro_ai", "label": "KI-gestützte Lernempfehlungen", "status": "coming_soon"},
    # Entscheidung des Inhabers vom 04.11.2026: Plus gilt je Geraet, der Abgleich der Notizen zwischen iPad, PC und Web
    # (Geraete-Abgleich G2, /api/sync/push) erst mit Pro AI
    "can_sync_annotations": {"from": "pro_ai", "label": "Notizen auf allen Geräten (Abgleich zwischen iPad, PC und Web)", "status": "available"},
    # Fertige KI-Fragen je Vorlesungswoche aus der Bibliothek (04.11.2026, app/week_library.py, app/week_library_api.py,
    # docs/BIBLIOTHEK-WOCHENFRAGEN.md): 2-3 Saetze zu je 15 Fragen mit Loesungen und Erklaerungen, nur im Dienst.
    # KI-Karteikarten auf Auftrag (Modul, Lernwoche, Anzahl) haengen an can_use_ai_generated_questions.
    "can_use_prepared_week_sets": {"from": "pro_ai", "label": "Fertige KI-Fragen zu jeder Vorlesungswoche mit Erklärungen", "status": "available"},
}

# Kontingente je Abrechnungsmonat (Tabelle des Inhabers vom 04.11.2026). None = unbegrenzt mit Fair-Use-Grenze (FAIR_USE).
# Plus: 4 neue KI-Tests und 4 Bibliothekstests; Pro AI: 20 neue KI-Tests, Bibliothek unbegrenzt (Fair Use).
# Karteikarten-Stapel von StudiNow (05.11.2026): fertige Wochenstapel aus dem Pool und geteilte Stapel der Community
# uebernehmen, Plus 4 je Monat, Pro AI unbegrenzt (Fair Use); derselbe Stapel zaehlt im Monat nur einmal.
QUOTAS: dict[str, dict[str, int | None]] = {
    "free": {"ai_tests_new": 0, "library_tests": 0, "ai_assist": 0, "card_stacks_adopted": 0},
    "plus": {"ai_tests_new": 4, "library_tests": 4, "ai_assist": 0, "card_stacks_adopted": 4},
    "pro_ai": {"ai_tests_new": 20, "library_tests": None, "ai_assist": 150, "card_stacks_adopted": None},
}
QUOTAS["pro_connect"] = QUOTAS["pro_ai"]        # alte Zeilen gelten wie Pro AI

# Grenze fuer "unbegrenzt" (Schutz vor automatisierten Abrufen), je Monat
FAIR_USE: dict[str, int] = {"library_tests": 300, "ai_tests_new": 20, "ai_assist": 150, "card_stacks_adopted": 300}

QUOTA_LABELS = {"ai_tests_new": "Neue StudiNow-KI-Tests", "library_tests": "Tests aus der Bibliothek",
                "ai_assist": "KI-Erklärungen, Lernfragen und Zusammenfassungen",
                "card_stacks_adopted": "Karteikarten-Stapel von StudiNow (Wochenstapel und geteilte Stapel)"}

# Credits je Kalendermonat fuer die StudiNow-KI (app/credits.py; 1 Credit = 1 Cent OpenAI-Kosten): Pro AI 100,
# sonst 0; die Probe hat 25. Standardwerte, die der Betrieb per Umgebungsvariable (LERNAPP_CREDITS_*) aendern kann.
CREDITS: dict[str, int] = {"free": 0, "plus": 0, "pro_ai": 100, "trial": 25}

# Integrationen, die nicht am Tarif haengen duerfen, bis die Bedingungen des Anbieters es erlauben
INTEGRATIONS: dict[str, dict] = {
    "chatgpt": {
        "status": "disabled",          # disabled | enabled; enabled erst nach Partnerfreigabe durch OpenAI
        "reason": "Die offizielle ChatGPT-Verbindung („Sign in with ChatGPT“) ist für StudiNow noch nicht von OpenAI "
                  "freigegeben. Bis dahin gibt es keine Verbindung.",
        # Laut den "Sign in with ChatGPT Terms" muss die Nutzung des eigenen ChatGPT-Abos ohne Zahlung an den Partner
        # und ohne bezahlten Partner-Tarif moeglich sein. Deshalb wird die Kontingentnutzung nie an Pro AI gekoppelt.
        "plan_gating_allowed": False,
    },
}


def is_legacy(plan: str) -> bool:
    return plan in LEGACY_PLANS


def is_sellable(plan: str) -> bool:
    """Kaufbar: ein Tarif aus ORDER ausser Free (alte Schluessel wie pro_connect nie)."""
    return plan in ORDER and plan != "free"


def rank(plan: str) -> int:
    return PLANS[plan]["rank"]


def has(plan: str, entitlement: str) -> bool:
    """Hat der Tarif das Recht? Unbekannte Rechte und Tarife: nein."""
    e = ENTITLEMENTS.get(entitlement)
    if not e or plan not in PLANS:
        return False
    return rank(plan) >= rank(e["from"])


def entitlements(plan: str) -> dict[str, bool]:
    return {name: has(plan, name) for name in ENTITLEMENTS}


def quota_limit(plan: str, feature: str) -> int:
    """Grenze fuer den Monat; unbegrenzt = Fair-Use-Grenze. Unbekannter Tarif oder Kontingent: 0."""
    q = QUOTAS.get(plan, {})
    if feature not in q:
        return 0
    v = q[feature]
    return FAIR_USE.get(feature, 0) if v is None else int(v)


def plan_for_product(product_id: str | None) -> str | None:
    for key, p in PLANS.items():
        if product_id and p["apple_product_id"] == product_id:
            return key
    return None


# Probe fuer jedes neue Konto (Entscheidung 30.10.2026, iPad 04.11.2026): 7 Tage alles wie Pro AI mit CREDITS["trial"]
# Credits, danach Aufforderung, einen Tarif zu waehlen; ohne Wahl gilt Free, Daten bleiben. Quelle "trial" in
# app/billing.py, nie verlaengerbar, einmal je Konto.
TRIAL = {"days": 7, "plan": "pro_ai"}


def contract() -> dict:
    """Die Tabelle als JSON fuer die Fixture und GET /api/billing/plans (nur die drei Tarife aus ORDER)."""
    return {
        "version": 1,
        "order": list(ORDER),
        "trial": {**TRIAL, "credits": CREDITS["trial"]},
        "plans": {k: {**PLANS[k], "entitlements": entitlements(k), "quotas": QUOTAS[k], "credits": CREDITS[k]} for k in ORDER},
        "entitlements": ENTITLEMENTS,
        "quotas": {"labels": QUOTA_LABELS, "fair_use": FAIR_USE},
        "credits": dict(CREDITS),
        "integrations": {k: {"status": v["status"], "reason": v["reason"], "plan_gating_allowed": v["plan_gating_allowed"]}
                         for k, v in INTEGRATIONS.items()},
    }

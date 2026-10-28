"""Studora-Tarife und Berechtigungen: die eine Tabelle fuer Server, Web, Windows und die Apps.

Auftrag des Inhabers vom 27.10.2026 (docs/ABO-SYSTEM.md): vier Tarife Free 0 EUR, Plus 1,99 EUR, Pro Connect 2,99 EUR,
Pro AI 3,99 EUR (Monatspreise, Endkundenpreise). Jeder Tarif enthaelt alle Rechte des naechstniedrigeren.

Diese Datei ist die Quelle. `tools/gen-plans-fixture.py` schreibt daraus
`packages/shared-contracts/fixtures/plans/plans.json`; die Apps (Swift, Kotlin) lesen die Fixture und pruefen ihre
eigene Tabelle dagegen, `tests/test_subscriptions.py` prueft, dass Fixture und diese Datei gleich sind.

Regeln:
- Ein Recht ist ein Name (`can_annotate_pdf`) mit Ja/Nein je Tarif; Kontingente sind Zahlen je Abrechnungsmonat
  (`None` = unbegrenzt, dann gilt die Fair-Use-Grenze aus `FAIR_USE`).
- `status` je Recht sagt der Oberflaeche, ob die Funktion schon technisch freigeschaltet ist (`available`), noch
  gebaut wird (`coming_soon`) oder bewusst aus ist (`disabled`). Nur `available` darf als enthalten beworben werden.
- `chatgpt_connection_premium` ist eine reine Produktregel (Anzeige ab Pro Connect). Die offizielle Verbindung zu
  ChatGPT haengt davon NICHT ab: siehe `INTEGRATIONS["chatgpt"]` und docs/ABO-SYSTEM.md, Abschnitt 4.
"""
from __future__ import annotations

ORDER = ("free", "plus", "pro_connect", "pro_ai")

PLANS: dict[str, dict] = {
    "free": {"rank": 0, "name": "Studora Free", "price_cents": 0, "currency": "EUR", "period": "month",
             "apple_product_id": None,
             "tagline": "Studium organisieren und Unterlagen lesen"},
    "plus": {"rank": 1, "name": "Studora Plus", "price_cents": 199, "currency": "EUR", "period": "month",
             "apple_product_id": "de.uniflow.plus.monthly",
             "tagline": "Mit Stift auf deinen Unterlagen schreiben"},
    "pro_connect": {"rank": 2, "name": "Studora Pro Connect", "price_cents": 299, "currency": "EUR", "period": "month",
                    "apple_product_id": "de.uniflow.proconnect.monthly",
                    "tagline": "Lernstatistiken, intelligente Planung und Wiederholung"},
    "pro_ai": {"rank": 3, "name": "Studora Pro AI", "price_cents": 399, "currency": "EUR", "period": "month",
               "apple_product_id": "de.uniflow.proai.monthly",
               "tagline": "KI von Studora inklusive – kein eigenes ChatGPT-Konto nötig"},
}

# Recht -> niedrigster Tarif, der es hat (Tarife sind aufsteigend enthalten), dazu Text und Stand der Umsetzung
ENTITLEMENTS: dict[str, dict] = {
    # Free (Grundfunktionen, bleiben wie heute)
    "can_view_pdf": {"from": "free", "label": "PDFs öffnen und lesen", "status": "available"},
    "can_manage_courses": {"from": "free", "label": "Hochschulkurse und Module verwalten", "status": "available"},
    "can_import_documents": {"from": "free", "label": "Automatischer Dokumentimport aus Stud.IP bzw. Learnweb", "status": "available"},
    "can_view_timetable": {"from": "free", "label": "Stundenplan ansehen", "status": "available"},
    "can_use_basic_planner": {"from": "free", "label": "Lernkalender und Lernplanung", "status": "available"},
    "can_read_community": {"from": "free", "label": "Community-Beiträge lesen", "status": "available"},
    # Plus
    "can_annotate_pdf": {"from": "plus", "label": "PDF-Annotationen, Textmarker, Radierer, Zeichenwerkzeuge, Textfelder", "status": "available"},
    "can_use_pencilkit": {"from": "plus", "label": "Apple Pencil (PencilKit) und handschriftliche Notizen", "status": "available"},
    "can_sync_annotations": {"from": "plus", "label": "Notizen auf allen Geräten", "status": "available"},
    "can_write_community_comments": {"from": "plus", "label": "Community-Kommentare schreiben", "status": "available"},
    "can_share_solutions": {"from": "plus", "label": "Eigene Lösungen teilen", "status": "available"},
    "can_access_shared_tests": {"from": "plus", "label": "Tests aus der Studora-Bibliothek", "status": "available"},
    "can_generate_studora_ai_tests": {"from": "plus", "label": "Neue KI-Tests von Studora", "status": "available"},
    # Pro Connect
    "can_use_advanced_analytics": {"from": "pro_connect", "label": "Erweiterte Lernstatistiken", "status": "available"},
    "can_use_advanced_planner": {"from": "pro_connect", "label": "Intelligente Lernplanung (Empfehlungen für die Woche)", "status": "available"},
    "can_review_wrong_answers": {"from": "pro_connect", "label": "Automatische Wiederholung falscher Antworten", "status": "available"},
    "can_use_extended_test_history": {"from": "pro_connect", "label": "Erweiterte Testhistorie", "status": "available"},
    "can_get_recommendations": {"from": "pro_connect", "label": "Personalisierte Lernempfehlungen", "status": "available"},
    "chatgpt_connection_premium": {"from": "pro_connect", "label": "Eigenes ChatGPT-Konto verbinden (in Vorbereitung)", "status": "disabled"},
    # Pro AI (Studora-KI ueber das Backend)
    "can_use_ai_explanations": {"from": "pro_ai", "label": "KI-Erklärungen zu Aufgaben", "status": "available"},
    "can_use_ai_generated_questions": {"from": "pro_ai", "label": "Automatische Lernfragen und Wiederholungsaufgaben", "status": "available"},
    "can_use_ai_summaries": {"from": "pro_ai", "label": "KI-Zusammenfassungen", "status": "available"},
    "can_use_ai_recommendations": {"from": "pro_ai", "label": "KI-gestützte Lernempfehlungen", "status": "available"},
}

# Kontingente je Abrechnungsmonat. None = unbegrenzt mit Fair-Use-Grenze (FAIR_USE).
# Plus: 3 neue KI-Tests laut Tariftabelle des Auftrags (Testfall 3 im Auftrag nennt "sechs" – Widerspruch, hier
# 3 nach der Tabelle; der Wert steht nur hier und laesst sich zentral aendern).
QUOTAS: dict[str, dict[str, int | None]] = {
    "free": {"ai_tests_new": 0, "library_tests": 0, "ai_assist": 0},
    "plus": {"ai_tests_new": 3, "library_tests": 4, "ai_assist": 0},
    "pro_connect": {"ai_tests_new": 3, "library_tests": None, "ai_assist": 0},
    "pro_ai": {"ai_tests_new": 40, "library_tests": None, "ai_assist": 150},
}

# Grenze fuer "unbegrenzt" (Schutz vor automatisierten Abrufen), je Monat
FAIR_USE: dict[str, int] = {"library_tests": 300, "ai_tests_new": 40, "ai_assist": 150}

QUOTA_LABELS = {"ai_tests_new": "Neue Studora-KI-Tests", "library_tests": "Tests aus der Bibliothek",
                "ai_assist": "KI-Erklärungen, Lernfragen und Zusammenfassungen"}

# Integrationen, die nicht am Tarif haengen duerfen, bis die Bedingungen des Anbieters es erlauben
INTEGRATIONS: dict[str, dict] = {
    "chatgpt": {
        "status": "disabled",          # disabled | enabled; enabled erst nach Partnerfreigabe durch OpenAI
        "reason": "Die offizielle ChatGPT-Verbindung („Sign in with ChatGPT“) ist für Studora noch nicht von OpenAI "
                  "freigegeben. Bis dahin gibt es keine Verbindung.",
        # Laut den "Sign in with ChatGPT Terms" muss die Nutzung des eigenen ChatGPT-Abos ohne Zahlung an den Partner
        # und ohne bezahlten Partner-Tarif moeglich sein. Deshalb wird die Kontingentnutzung nie an Pro Connect gekoppelt.
        "plan_gating_allowed": False,
    },
}


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


def contract() -> dict:
    """Die Tabelle als JSON fuer die Fixture und GET /api/billing/plans."""
    return {
        "version": 1,
        "order": list(ORDER),
        "plans": {k: {**PLANS[k], "entitlements": entitlements(k), "quotas": QUOTAS[k]} for k in ORDER},
        "entitlements": ENTITLEMENTS,
        "quotas": {"labels": QUOTA_LABELS, "fair_use": FAIR_USE},
        "integrations": {k: {"status": v["status"], "reason": v["reason"], "plan_gating_allowed": v["plan_gating_allowed"]}
                         for k, v in INTEGRATIONS.items()},
    }

"""StudiNow-Tarife und Berechtigungen: die eine Tabelle fuer Server, Web, Windows und die Apps.

Entscheidung des Inhabers vom 04.11.2026 (docs/PREISLISTE.md, docs/ABO-SYSTEM.md): drei Tarife Free, Plus, Pro AI.
Seit 09.11.2026 (abends, docs/release/ABO-NUR-JAHR-2026-11-09.md) nur noch Jahresabos: Plus 19,99 EUR, Pro AI
39,99 EUR im Jahr (Endkundenpreise, `price_cents` mit `period` "year", `apple_product_id` = Jahresabo). Die frueheren
Monatsabos (1,99 / 3,99 EUR) werden nirgends mehr angeboten; ihre Apple-Produkte gelten beim Pruefen eines Kaufs weiter
wie der Tarif (`LEGACY_PRODUCTS`). Credits und Kontingente gelten weiter je Kalendermonat. Jeder Tarif enthaelt alle
Rechte des naechstniedrigeren.
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

# nicht mehr angebotene Apple-Produkte -> Tarif: ein Kauf damit gilt weiter (Belege, Verlaengerungen, Sandbox), sie
# stehen aber in keiner Liste, keinem Vertrag und keinem Text. Monatsabos bis 09.11.2026, Pro Connect bis 04.11.2026.
LEGACY_PRODUCTS = {"de.uniflow.plus.monthly": "plus", "de.uniflow.proai.monthly": "pro_ai",
                   "de.uniflow.proconnect.monthly": "pro_connect"}

PLANS: dict[str, dict] = {
    "free": {"rank": 0, "name": "StudiNow Free", "price_cents": 0, "currency": "EUR", "period": None,
             "apple_product_id": None,
             "tagline": "Studium organisieren und Unterlagen lesen"},
    "plus": {"rank": 1, "name": "StudiNow Plus", "price_cents": 1999, "currency": "EUR", "period": "year",
             "apple_product_id": "de.uniflow.plus.yearly",
             "tagline": "Mit Stift auf deinen Unterlagen schreiben, Karteikarten und Wochentests"},
    "pro_ai": {"rank": 2, "name": "StudiNow Pro AI", "price_cents": 3999, "currency": "EUR", "period": "year",
               "apple_product_id": "de.uniflow.proai.yearly",
               "tagline": "KI von StudiNow inklusive – kein eigenes ChatGPT-Konto nötig"},
    # nur fuer alte Zeilen (LEGACY_PLANS): Rang wie Pro AI, nicht in ORDER, nicht kaufbar, nicht sichtbar; sein
    # frueheres Produkt steht in LEGACY_PRODUCTS
    "pro_connect": {"rank": 2, "name": "StudiNow Pro AI", "price_cents": 3999, "currency": "EUR", "period": "year",
                    "apple_product_id": None,
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
    # Eigenes ChatGPT (Entscheidung 05.11.2026): in jedem Tarif, auch Free (Fragen zu Folien, seit 07.11.2026 auch der
    # KI-Lernplan). Seit 07.11.2026 `available`: auf dem iPad ueber den eigenen OpenAI-API-Schluessel des Nutzers (nur im
    # Schluesselbund des Geraets, Anfragen direkt an OpenAI; OpenAIKeySession.swift), am PC ueber Sign in with ChatGPT
    # (app/chatgpt_login.py, lokal). Die offizielle Anmeldung "Mit ChatGPT anmelden" im Dienst bleibt aus, bis OpenAI sie
    # freigibt (INTEGRATIONS["chatgpt"]; entitlements.has liefert dafuer weiter False). Die OpenAI-Bedingungen verbieten
    # ohnehin, die Nutzung an einen bezahlten Tarif zu koppeln (plan_gating_allowed False).
    "chatgpt_connection_premium": {"from": "free", "label": "Eigenes ChatGPT verbinden: Fragen zu Folien und KI-Lernplan", "status": "available"},
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
    # Erinnerungen an Abgaben, Tests und Klausuren (Mitteilungen 7 Tage, 3 Tage, 1 Tag und am Morgen vorher, dazu
    # "Neuer Klausurtermin erkannt") ab Pro AI: Entscheidung des Inhabers 18.11.2026, woertlich "Alles ab Pro AI"
    # (vorher ab Plus seit 11.11.2026, davor in jedem Tarif). Steht hier, damit die Reihenfolge des Vertrags gleich
    # bleibt. Die Fristen- und Terminlisten und die Karte "Klausuren und Tests: bald und neu erkannt" bleiben in jedem
    # Tarif sichtbar, gesperrt sind nur die Mitteilungen.
    "can_use_due_reminders": {"from": "pro_ai", "label": "Erinnerungen an Abgaben und Klausuren", "status": "available"},
    # KI-Chat (Entscheidung des Inhabers 15.11.2026: "pro ai und plus können kaufen aber plus sollen ki nur chat benutzen
    # können ohne ki lernhilfe"): die freie Frage an die KI in der KI-Hilfe (Aufgabe `tutor:ask`, CREDIT_PACKS
    # `chat_purposes`). Plus hat keine Monats-Credits: der Chat laeuft dort allein aus gekauften Credits. Alles andere
    # (Erklaeren, Karteikarten, Tests, Lernplan, Zusammenfassungen, KI-Mail) bleibt KI-Lernhilfe ab Pro AI.
    "can_use_ai_chat": {"from": "plus", "label": "KI-Chat mit gekauften Credits (Fragen an die KI)", "status": "available"},
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
    "free": {"ai_tests_new": 0, "library_tests": 0, "ai_assist": 0, "card_stacks_adopted": 0, "ai_mail": 0},
    "plus": {"ai_tests_new": 4, "library_tests": 4, "ai_assist": 0, "card_stacks_adopted": 4, "ai_mail": 0},
    "pro_ai": {"ai_tests_new": 20, "library_tests": None, "ai_assist": 150, "card_stacks_adopted": None, "ai_mail": 50},
}
QUOTAS["pro_connect"] = QUOTAS["pro_ai"]        # alte Zeilen gelten wie Pro AI

# KI-Mails (13.11.2026, Inhaber: "ab Pro AI, Pro hat 50 KI-Mails"): Uni-Mail "Mit KI verbessern" (Rechtschreibung,
# Grammatik, Stil), 50 je Monat, ohne Credits; Aufgabe `mail` in app/ai_relay.py.

# Grenze fuer "unbegrenzt" (Schutz vor automatisierten Abrufen), je Monat
FAIR_USE: dict[str, int] = {"library_tests": 300, "ai_tests_new": 20, "ai_assist": 150, "card_stacks_adopted": 300}

QUOTA_LABELS = {"ai_tests_new": "Neue StudiNow-KI-Tests", "library_tests": "Tests aus der Bibliothek",
                "ai_assist": "KI-Erklärungen, Lernfragen und Zusammenfassungen",
                "card_stacks_adopted": "Karteikarten-Stapel von StudiNow (Wochenstapel und geteilte Stapel)",
                "ai_mail": "E-Mails mit KI verbessern"}

# Credits je Kalendermonat fuer die StudiNow-KI (app/credits.py; 1 Credit = 0,65 Cent KI-Kosten, 15.11.2026): Pro AI 100,
# sonst 0; die Probe hat 25. Standardwerte, die der Betrieb per Umgebungsvariable (LERNAPP_CREDITS_*) aendern kann.
CREDITS: dict[str, int] = {"free": 0, "plus": 0, "pro_ai": 100, "trial": 25}

# Credit-Pakete zum Nachkaufen (Auftrag des Inhabers vom 15.11.2026, docs/KI-CREDITS-2026-11-15.md): Verbrauchskaeufe im
# App Store. Gekaufte Credits verfallen nie und werden erst nach den Monats-Credits verbraucht (app/credits.py).
# - `packs`: Credits je Produkt-ID - die EINE Stelle fuer die Paketgroesse. Die Produkt-IDs tragen keine Zahl, damit eine
#   andere Groesse kein neues Produkt braucht; der Betrieb kann sie mit LERNAPP_CREDIT_PACKS aendern
#   (z. B. "de.uniflow.credits.gross=185"). Die App zeigt die Zahl vom Dienst und den Preis aus StoreKit;
#   `price_cents` ist nur der Listenpreis fuer Vertrag, Tests und die Rechnung.
# - `buy_plans` / `buy_in_trial`: die EINE Stelle fuer "wer darf kaufen" (Entscheidung des Inhabers 15.11.2026: bezahltes
#   Plus und Pro AI; Free nicht; in der Probe allein nicht). Der Dienst meldet es als `credits.can_buy`.
# - `use_right`: mit diesem Recht (KI-Lernhilfe: Pro AI, Probe) gelten gekaufte Credits fuer ALLES.
# - `chat_right` / `chat_purposes`: mit diesem Recht (ab Plus) gelten gekaufte Credits NUR fuer den KI-Chat, also nur fuer
#   die hier genannten Aufgaben. Das prueft der Dienst zweimal: am Recht der Route (app/server.py TUTOR_ENTITLEMENT,
#   app/ai_relay.py TUTOR_RIGHT) und beim Reservieren der Credits (app/credits.py) - ueber keine andere KI-Route kann
#   ein Plus-Konto Credits ausgeben. Ohne beide Rechte (Free) ruhen gekaufte Credits beim Konto.
CREDIT_PACKS: dict = {
    "packs": {
        "de.uniflow.credits.klein": {"credits": 100, "price_cents": 199},
        "de.uniflow.credits.gross": {"credits": 200, "price_cents": 399},
    },
    "currency": "EUR",
    "buy_plans": ("plus", "pro_ai"),
    "buy_in_trial": False,
    "use_right": "can_use_ai_explanations",
    "chat_right": "can_use_ai_chat",
    "chat_purposes": ("tutor:ask",),
}

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
    """Tarif zu einem Apple-Produkt: das angebotene Jahresabo oder ein frueheres Produkt (`LEGACY_PRODUCTS`, z. B. die
    Monatsabos bis 09.11.2026), das weiter wie sein Tarif gilt."""
    if not product_id:
        return None
    for key, p in PLANS.items():
        if product_id == p["apple_product_id"]:
            return key
    return LEGACY_PRODUCTS.get(product_id)


# ---------------------------------------------------------------- Credit-Pakete

def credit_pack_sizes() -> dict[str, int]:
    """Credits je Produkt-ID: Standard aus CREDIT_PACKS, vom Betrieb aenderbar mit LERNAPP_CREDIT_PACKS
    ("produkt=zahl,produkt=zahl"). Unbekannte Produkte und unbrauchbare Zahlen in der Variable zaehlen nicht."""
    import os
    sizes = {pid: int(p["credits"]) for pid, p in CREDIT_PACKS["packs"].items()}
    for part in (os.environ.get("LERNAPP_CREDIT_PACKS") or "").split(","):
        pid, _, raw = part.strip().partition("=")
        if pid.strip() in sizes:
            try:
                n = int(raw.strip())
            except ValueError:
                continue
            if 0 < n <= 100_000:
                sizes[pid.strip()] = n
    return sizes


def credit_pack_credits(product_id: str | None) -> int | None:
    """Credits eines Pakets; None, wenn das Produkt kein Credit-Paket ist."""
    return credit_pack_sizes().get(product_id or "")


def credit_packs() -> list[dict]:
    """Die Pakete in der Reihenfolge der Anzeige (kleines zuerst): Produkt-ID, Credits, Listenpreis."""
    sizes = credit_pack_sizes()
    return [{"product_id": pid, "credits": sizes[pid], "price_cents": p["price_cents"], "currency": CREDIT_PACKS["currency"]}
            for pid, p in CREDIT_PACKS["packs"].items()]


def can_buy_credits(plan: str | None, trial_only: bool = False) -> bool:
    """Darf dieses Konto Credit-Pakete kaufen? Die eine Regel (CREDIT_PACKS): der Tarif steht in `buy_plans`; ein Konto,
    das den Tarif nur aus der Probe hat, nur mit `buy_in_trial`."""
    p = LEGACY_PLANS.get(plan or "", plan)
    if p not in CREDIT_PACKS["buy_plans"]:
        return False
    return CREDIT_PACKS["buy_in_trial"] or not trial_only


def purchased_credits_scope(plan: str | None) -> str:
    """Wofuer gelten gekaufte Credits mit diesem Tarif? "all" (KI-Lernhilfe im Tarif: Pro AI, Probe), "chat" (nur der
    KI-Chat: Plus) oder "none" (Free: sie ruhen beim Konto)."""
    p = LEGACY_PLANS.get(plan or "", plan) or ""
    if has(p, CREDIT_PACKS["use_right"]):
        return "all"
    return "chat" if has(p, CREDIT_PACKS["chat_right"]) else "none"


def is_chat_purpose(purpose: str | None) -> bool:
    """Ist diese KI-Aufgabe der KI-Chat (die freie Frage)? Nur dafuer gelten gekaufte Credits bei Plus."""
    return (purpose or "") in CREDIT_PACKS["chat_purposes"]


def can_use_purchased_credits(plan: str | None, purpose: str | None = None) -> bool:
    """Sind gekaufte Credits mit diesem Tarif nutzbar? Ohne `purpose`: ueberhaupt (Pro AI, Probe, Plus). Mit `purpose`
    (Aufgabe der Anfrage, z. B. "tutor:ask"): fuer genau diese Aufgabe - bei Plus nur der KI-Chat."""
    scope = purchased_credits_scope(plan)
    if scope == "all":
        return True
    return scope == "chat" and (purpose is None or is_chat_purpose(purpose))


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
        "credit_packs": {"packs": credit_packs(), "buy_plans": list(CREDIT_PACKS["buy_plans"]),
                         "buy_in_trial": CREDIT_PACKS["buy_in_trial"], "use_right": CREDIT_PACKS["use_right"],
                         "chat_right": CREDIT_PACKS["chat_right"], "chat_purposes": list(CREDIT_PACKS["chat_purposes"])},
        "integrations": {k: {"status": v["status"], "reason": v["reason"], "plan_gating_allowed": v["plan_gating_allowed"]}
                         for k, v in INTEGRATIONS.items()},
    }

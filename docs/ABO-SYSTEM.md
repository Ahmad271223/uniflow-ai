# StudiNow-Abosystem: drei Tarife, Berechtigungen, KI-Testbibliothek (Stand 05.11.2026, iPad-Teile 07.11.2026)

Auftrag des Inhabers vom 27.10.2026, Tarife und Kontingente nach der Entscheidung vom 04.11.2026 (`docs/PREISLISTE.md`). Umgesetzt im Dienst (Python, `LERNAPP_MODE=hosted`), in der Web-Oberfläche
(gilt auch für die Windows-App) und als gemeinsamer Vertrag für die Apps. Branch `feature/studora-abos`.
Ersetzt die Entscheidungen „nur Free und Plus“ und „KI entfällt in V1“ aus `docs/AUFTRAG-APPSTORE-V1.md`, Abschnitt 6.

## 1. Tarife

| Tarif | Preis/Monat | Neue KI-Tests | Bibliothekstests | Stapel von StudiNow | KI-Erklärungen u. a. | Credits | PDF bearbeiten | Community |
|---|---:|---:|---:|---:|---:|---:|:---:|:---:|
| StudiNow Free | 0,00 € | 0 | 0 | 0 | 0 | 0 | nein | nein |
| StudiNow Plus | 1,99 € | 4 | 4 | 4 | 0 | 0 | ja | ja |
| StudiNow Pro AI | 3,99 € | 20 | unbegrenzt (Fair Use 300) | unbegrenzt (Fair Use 300) | 150 | 100 | ja | ja |

**Angleichung vom 05.11.2026** (`docs/ENTSCHEIDUNGEN-INHABER-2026-11-05.md`): Free ohne Community (auch kein Lesen,
`can_read_community` ab Plus) und ohne StudiNow-KI; das eigene ChatGPT darf in jedem Tarif verbunden werden (Fragen zu
Folien, Schreiben erst ab Plus). Seit 07.11.2026 auf dem iPad nutzbar über den eigenen OpenAI-API-Schlüssel
(`chatgpt_connection_premium` = `available`); die offizielle Anmeldung „Mit ChatGPT anmelden“ bleibt aus (Abschnitt 4). Neues Kontingent `card_stacks_adopted`
(„Stapel von StudiNow“): fertige Wochenstapel aus dem Pool und geteilte Stapel der Community übernehmen, Plus 4 je
Monat (Annahme), Pro AI unbegrenzt mit Fair Use 300; derselbe Stapel zählt im Monat einmal. Nach dem Verlust von Plus
bleibt alles erhalten, eigene Community-Beiträge lassen sich weiter zurückziehen.

**Pro Connect** (2,99 €) gibt es seit dem 04.11.2026 nicht mehr: seine Rechte (Lernstatistik, Wiederholung,
Empfehlungen, vollständige Testliste, Anzeige der ChatGPT-Verbindung) gehören zu Pro AI. Der Schlüssel `pro_connect`
bleibt nur für alte Zeilen lesbar und gilt wie Pro AI (`plans.LEGACY_PLANS`, `billing.normalize_plan`); er ist nicht
kaufbar, nicht wählbar und erscheint auf keiner Karte.

Jeder Tarif enthält alle Rechte des niedrigeren. **Quelle aller Werte: `app/plans.py`.** Daraus erzeugt
`tools/gen-plans-fixture.py` die Datei `packages/shared-contracts/fixtures/plans/plans.json`; Swift und Kotlin prüfen
ihre Tabellen dagegen, `tests/test_subscriptions.py::test_plans_fixture_is_current` hält sie aktuell.

Kontingente nach der Tabelle des Inhabers vom 04.11.2026 (vorher Plus 3 und Pro AI 40 neue KI-Tests). Die Werte
stehen nur in `app/plans.py` (`QUOTAS`) und lassen sich dort ändern.

Apple-Produkte (eine Abo-Gruppe „StudiNow“, damit Apple Upgrades, Downgrades und Doppel-Abos regelt):
`de.uniflow.plus.monthly` (1,99 €), `de.uniflow.proai.monthly` (3,99 €) und seit 07.11.2026 die Jahresabos
`de.uniflow.plus.yearly` (21,99 €, Stufe wie Plus monatlich) und `de.uniflow.proai.yearly` (41,99 €, Stufe wie Pro AI
monatlich; `apple_product_id_yearly`, `price_cents_yearly` in `app/plans.py`). Credits und Kontingente gelten auch beim
Jahresabo je Kalendermonat. Alle vier werden mit Version 1.0 eingereicht (Pro AI ist in 1.0 im Store, Dienst
`app.studinow.app` läuft). Die Kennungen bleiben bei `de.uniflow`, weil die Bundle-ID
`de.uniflow.ai` ist. Ein früheres `de.uniflow.proconnect.monthly` gilt wie Pro AI, wird aber nicht angeboten.

## 2. Berechtigungen

Ein Recht ist ein Name mit Ja/Nein je Tarif (`app/plans.py::ENTITLEMENTS`), dazu der Stand der Umsetzung:
`available` (darf beworben werden), `coming_soon` (es fehlt noch die Oberfläche oder der Endpunkt: Lernstatistik über
alle Module, intelligente Lernplanung, Wiederholung falscher Antworten, Lernempfehlungen, KI-Lernempfehlungen) und
`disabled` (ChatGPT-Verbindung, Abschnitt 4). Begriffe: „Lernstand“ ist die Zahl je Modul aus den eigenen Daten
(`app/mastery.py`), in jedem Tarif frei; „Lernstatistik“ ist die modulübergreifende Auswertung des Dienstes
(`/api/learning/*`) ab Pro AI. Die Abo-Seite zeigt nur `available` als enthalten. Funktionen der
StudiNow-KI erscheinen als „in Vorbereitung“, solange auf dem Server kein KI-Schlüssel eingerichtet ist.

Serverseitig (`app/entitlements.py`): Der Tarif kommt immer aus der Datenbank, nie aus der Anfrage. Geprüft wird an:

| Endpunkt | Recht |
|---|---|
| `PUT /api/files/{id}/annotations`, `POST …/annotations/restore/{v}`, `POST /api/files/{id}/assets` | `can_annotate_pdf` |
| `POST /api/sync/push` (nur Einträge `annotations`, Ergebnis `plan_required`; Plus gilt je Gerät, der Notizen-Abgleich zwischen iPad, PC und Web ist Pro AI, Entscheidung vom 04.11.2026) | `can_sync_annotations` (Pro AI) |
| `POST /api/sync/push` (neue Einträge `flashcards`/`flashcard_stacks` ohne `id`, Ergebnis `plan_required`) | `can_use_flashcards` (Plus) |
| `GET /api/library/week-sets…`, `POST …/prepare`, `POST …/start` (fertige Fragen je Vorlesungswoche, `docs/BIBLIOTHEK-WOCHENFRAGEN.md`) | `can_use_prepared_week_sets` (Pro AI) |
| `POST /api/ai/flashcards` (aus Dokument oder auf Auftrag mit `module_id`, Woche, Anzahl) | `can_use_ai_generated_questions` (Pro AI) |
| `/api/community/*` und `/api/community/card-stacks*` lesen, beitreten, liken, melden (seit 05.11.2026; ausgenommen: eigene Beiträge auflisten, zurückziehen und löschen, Austreten, Moderation) | `can_read_community` (Plus) |
| `POST /api/community/solutions` | `can_share_solutions` |
| Stapel übernehmen (`POST /api/community/card-stacks/{id}/adopt`, Wochenstapel aus dem Pool `POST /api/flashcard-stacks/week/…`) | `can_use_flashcards` + Kontingent `card_stacks_adopted` |
| `POST /api/library/tests` | `can_access_shared_tests` bzw. `can_generate_studora_ai_tests` |
| `GET /api/learning/stats` · `…/review` · `…/recommendations` (Pro AI) | `can_use_advanced_analytics` · `can_review_wrong_answers` · `can_get_recommendations` |
| `GET /api/tests` (ohne Recht die letzten 10; ältere bleiben gespeichert, Nutzungsbedingungen 5a) | `can_use_extended_test_history` (Pro AI) |
| `POST /api/ai/tutor` im Dienst (je Modus) | `can_use_ai_explanations`, `…_summaries`, `…_generated_questions` |

Antwort ohne Recht: `403 {"code": "plan_required", "entitlement", "required_plan"}`. Kontingent leer:
`429 {"code": "quota_exhausted", "feature", "used", "limit"}`. Ohne aktives Abo in Web und Windows (Abschnitt 3d):
`402 {"code": "subscription_required"}` für jedes Schreiben außer Konto und Abo. **Windows-App (seit 05.11.2026):**
Tarif aus dem StudiNow-Konto (Quelle „account“, Abschnitt 3d). **Einzelplatz ohne Konto-Pflicht** (`serve.py` in der
Entwicklung): keine Konten, keine Tarife, alles frei; die KI läuft dort weiter über `claude -p`.

Web/Windows: `state.entitlements` aus `GET /api/entitlements`, `can(name)` in `core.js` (gilt im Dienst und in der
Windows-App mit Konto-Pflicht, `state.gated`); der Editor öffnet ohne
`can_annotate_pdf` im Nur-Lesen-Modus (Werkzeuge aus, Hinweis mit Link auf die Abo-Seite). Seite `#/abo`, auch unter
Einstellungen → Abo & Tarife.

## 3. Abo-Stand und Zahlungen

Tabellen in `accounts.db` (`app/billing.py`): `entitlements` (je Konto und Quelle: Tarif, Ablauf, Status,
`will_renew`, `pending_plan`), `usage` und `usage_requests` (Kontingente je Monat, Anfrage-ID gegen Doppelzählung,
`BEGIN IMMEDIATE` gegen parallele Anfragen), `apple_transactions`, `apple_notifications`. Quellen: `app_store` und
`manual` (Betrieb: `python -m app.accounts plan <email> free|plus|pro_ai [bis YYYY-MM-DD]`, bisheriges
Feld `users.plan`). Es gilt der höchste aktive Tarif.

**Apple (StoreKit 2, `app/apple_store.py`):**
- `POST /api/billing/apple/verify {signed_transaction, signed_renewal?}`: Kauf, Upgrade, Wiederherstellen. Die App
  setzt beim Kauf `appAccountToken` = UniFlow-ID als UUID (`GET /api/entitlements` liefert sie als
  `apple_account_token`).
- `POST /api/billing/apple/notifications {signedPayload}` (App Store Server Notifications V2, öffentlich):
  `SUBSCRIBED`, `DID_RENEW`, `DID_CHANGE_RENEWAL_PREF` (Downgrade → `pending_plan`), `DID_CHANGE_RENEWAL_STATUS`
  (Kündigung → `will_renew = false`), `DID_FAIL_TO_RENEW` (mit/ohne Kulanzzeit), `EXPIRED`, `REFUND`/`REVOKE`.
  Doppelte Meldungen zählen einmal, ältere Meldungen überschreiben keine neueren.
- Geprüft: Kette Blatt → Zwischenzertifikat → Wurzel aus `LERNAPP_APPLE_ROOT_CERTS`, Apple-OIDs, Gültigkeit,
  ES256-Signatur, Bundle-ID, Produkt. Ohne Wurzel: `503 apple_not_configured`.
- Upgrade sofort, Downgrade zur nächsten Verlängerung, Kündigung läuft bis zum Ablauf, Ablauf/Erstattung schaltet ab.
  Eine `originalTransactionId` gehört genau einem Konto (`409 subscription_owned_by_other_account`).
- Daten bleiben bei Kündigung und Ablauf: Notizen lesbar und exportierbar, nur Speichern wird gesperrt.

**Web, Windows, Android:** Web und Windows schließen über Stripe ab (Abschnitte 3a und 3d), sobald Schlüssel und Preise im
Dienst eingerichtet sind; bis dahin meldet `GET /api/billing/plans` `purchase.web.available = false`. Android: kein
Zahlungsweg. Ein Abo aus der Apple-App gilt automatisch auf allen Geräten desselben Kontos.

## 3a. Probe und Stripe (30.10.2026)

Entscheidung des Inhabers: **jedes neue Konto bekommt 7 Tage Probe mit allen Rechten** (wie Pro AI, mit 25 Credits;
Text auf der Abo-Seite „Probe: alles wie StudiNow Pro AI, mit 25 Credits für die StudiNow-KI“), danach die
Aufforderung, einen Tarif zu wählen; ohne Wahl gilt Free. Im Web und unter Windows wird über **Stripe** abgeschlossen,
in der Apple-App weiter über den App Store. Ein Abo gilt auf allen Geräten desselben Kontos.

- `plans.TRIAL = {"days": 7, "plan": "pro_ai"}` steht mit `credits: 25` (`plans.CREDITS["trial"]`) im Vertrag
  (`plans.json`, `GET /api/billing/plans`); jede Tarifkarte trägt `credits` (Pro AI 100, sonst 0).
- `billing.start_trial` beim Anlegen des Kontos (`accounts.register`, Apple/Google-Anmeldung), Quelle `trial`, läuft
  nie nach, nur einmal je Konto; `billing.end_trial` für Betrieb und Tests. `GET /api/entitlements` liefert `trial`
  (`active`, `ends_at`, `days_left`, `expired`), `plan_choice` und `needs_plan_choice` (Probe vorbei, kein bezahlter
  Tarif, noch keine Antwort). Die Oberfläche zeigt dann einmal die Aufforderung; `POST /api/billing/plan-choice {plan}`
  merkt die Antwort und liefert für einen bezahlten Tarif gleich die Checkout-Adresse.
- Stripe (`app/stripe_billing.py`): `POST /api/billing/stripe/checkout {plan}` (Checkout-Sitzung, Monatsabo),
  `POST /api/billing/stripe/portal` (Kundenportal: Wechsel, Kündigung, Rechnungen), `POST /api/billing/stripe/webhook`
  (öffentlich, Signatur `Stripe-Signature` geprüft, höchstens 5 Minuten alt, jedes Ereignis zählt einmal). Verarbeitet:
  `checkout.session.completed` (Abo nachladen), `customer.subscription.created/updated/deleted`. Stand: active/trialing →
  active, past_due → billing_retry, unpaid/canceled → expired; `cancel_at_period_end` → läuft bis zum Periodenende ohne
  Verlängerung. Unbekannter Preis oder Kunde: quittiert (200), nie als Tarif übernommen. Ein Abo gehört genau einem
  Konto (409 `subscription_owned_by_other_account`).
- Konfiguration des Dienstes: `LERNAPP_STRIPE_SECRET_KEY`, `LERNAPP_STRIPE_WEBHOOK_SECRET`,
  `LERNAPP_STRIPE_PRICES="plus=price_…,pro_ai=price_…"` (nur kaufbare Tarife; ein `pro_connect=` wird ignoriert),
  `LERNAPP_PUBLIC_URL`. Ohne Schlüssel bleibt
  der Web-Abschluss ehrlich aus (`purchase.web.available = false`, 503 `stripe_not_configured`).
- Wechsel im Kundenportal (seit 1.11.2026): ein **sofortiger** Wechsel (anteilig berechnet) ändert den Preis am Posten,
  der Tarif wechselt sofort, `pending_plan` bleibt leer. Ein Wechsel **zum Periodenende** (Downgrade) hängt Stripe als
  Subscription Schedule an das Abo (`subscription.schedule`); der Server lädt den Schedule
  (`GET /v1/subscription_schedules/{id}`, oder nutzt ihn eingebettet), nimmt den Preis der Phase nach der laufenden und
  setzt `pending_plan`, wenn er einen anderen bekannten Tarif ergibt (wie Apple `autoRenewProductId`). Gleicher Preis,
  unbekannter Preis, keine weitere Phase oder Schedule nicht ladbar → `pending_plan` leer, kein Fehler. Zusätzlich
  verarbeitet: `subscription_schedule.updated/released/canceled` (Abo nachladen; ohne Schedule wird `pending_plan`
  wieder leer). `pending_update` (Upgrade mit offener Zahlung) zählt nicht als geplanter Wechsel. Am echten Konto zu
  prüfen: dass das Portal den Wechsel zum Periodenende tatsächlich als Schedule anlegt (Portal-Einstellung
  „Proration“/„Wechsel zum Ende des Zeitraums“) und der Webhook-Endpunkt die `subscription_schedule.*`-Ereignisse
  abonniert hat.
- Tests: `tests/test_trial_stripe.py` (17), dazu `tests/test_subscriptions.py` (die Tarif-Tests beenden die Probe zuerst).
- Offen: Microsoft-Store-Beleg, Stripe-Preise in Partner-Konto anlegen (Inhaber).

## 3b. Probe auf dem iPad ohne Dienst (04.11.2026)

Entscheidung des Inhabers (ersetzt „Apple-Einführungsangebot auf Plus, eigene Probe wird nicht gebaut“ vom 25.10.2026 in
`docs/AUFTRAG-APPSTORE-V1.md`, Abschnitt 5): Die iPad-App bietet **drei Tarife** an – Free, Plus 1,99 €/Monat
(`de.uniflow.plus.monthly`) und Pro AI 3,99 €/Monat (`de.uniflow.proai.monthly`), **ohne Apple-Einführungsangebote**.
Jede Person bekommt ab dem ersten Start **dieselbe Probe wie beim Dienst** (`TRIAL`: 7 Tage, alles wie Pro AI), ohne
Zahlungsdaten, einmal je Apple-ID **und einmal je iPad** (07.11.2026), danach eine Pflicht-Entscheidung (Free, Plus
oder Pro AI, unten) – nur dass das iPad sie **ohne Dienst** führt.

- **Ablage** (`apps/apple/UniFlow/Purchases/LocalTrial.swift`, `UFLocalTrial`, `UFTrialRecordStore`): nur der Beginn,
  geschlüsselt mit einem Hash der Apple-Nutzer-ID (`DataContainerKey.userScope`), im Schlüsselbund des Geräts (Dienst
  `de.uniflow.ai.trial`, nur dieses Gerät; überlebt die Neuinstallation) und im iCloud-Schlüssel-Wert-Speicher
  (`NSUbiquitousKeyValueStore`, Schlüssel `uniflow.trial.<hash>`; zweites iPad). Beide werden gelesen, der frühere Beginn
  gilt und wird in die andere Ablage nachgetragen; ohne iCloud zählt der Schlüsselbund allein. Die Antwort „Bei Free
  bleiben“ steht in den UserDefaults (`uniflow.trial.choice.<hash>`) und im Schlüsselbund (`markChoice`). Beim Löschen
  des Kontos bleibt der Eintrag (einmal je Apple-ID; er enthält nur Hash und Datum).
- **Einmal je iPad** (Inhaber 07.11.2026): beim Beginn jeder Probe setzt die App eine Geräte-Marke im Schlüsselbund, die
  an keiner Apple-ID hängt (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, nicht synchronisiert, übersteht die
  Neuinstallation). Eine weitere Apple-ID auf demselben iPad bekommt keine Probe („Auf diesem iPad wurde die Probe schon
  genutzt“, `UFLocalTrial.State.usedOnDevice`) und beim ersten Start gleich die Tarifwahl. Das Zurücksetzen des Geräts
  löscht die Marke; stärker wäre später Apple DeviceCheck.
- **Rechnung** (reine Funktionen, Uhr von außen): `state(startedAt:now:)` liefert Ende und Resttage (aufgerundet wie
  `billing.trial_info`, 0 = vorbei), `resolve(keychain:cloud:now:)` den gültigen Beginn. Werte wie `plans.TRIAL`
  (geprüft in `PlanContractTests.testLocalTrialMatchesContract`).
- **Vorrang** (`UFPlanPrecedence`, in `Entitlements`): Dienst-Probe (`StudoraAccountLink.planStatus`, sobald ein
  StudiNow-Konto verbunden ist) > App Store (`Transaction.currentEntitlements`, `purchasedPlan`) > Probe auf dem iPad >
  Free. Wer Plus kauft, hat Plus; wer Pro AI kauft, Pro AI. Während der Probe gilt die Rechte-Tabelle von Pro AI
  (dieselbe wie im Dienst, `plans.json`, `UFLocalTrial.plan = .proAI`): Pro-AI-Umfang samt StudiNow-KI (diese braucht
  auch in der Probe ein StudiNow-Konto, neue Konten 25 Credits) und Notizen-Abgleich.
- **Oberfläche:** `TrialBanner` auf der Übersicht („Probe: noch n Tage alles frei“, „Danach wählst du einen Tarif oder
  bleibst bei Free“). **Nach der Probe (07.11.2026):** Bildschirm „Deine Probe ist vorbei“ über der ganzen App
  (`UFTrialDecision`, `TrialDecisionCover`, `PlanPickerView` im Kontext `.trialOver`) mit Free, Plus und Pro AI
  (Monatlich/Jährlich); er lässt sich nicht wegwischen und schließt sich erst mit einer Wahl. „Bei Free bleiben“ ist eine
  gültige Wahl ohne Kauf (Free bleibt dauerhaft kostenlos nutzbar, Richtlinien 3.1.2/5.1.1), wird je Apple-ID gemerkt und
  erscheint danach nie wieder; ein Kauf beendet ihn ebenso. Läuft die Probe über den Dienst, bleibt dessen Hinweis auf der
  Übersicht. Tarifseite mit Free, Plus und Pro AI – die Pro-AI-Karte, wenn StoreKit das Produkt liefert (in 1.0 der
  Normalfall; sonst „StudiNow Pro AI konnte gerade nicht aus dem App Store geladen werden …“, `proAIMissingNote`), mit
  der Zeile „Braucht ein StudiNow-Konto (Anmelden mit Apple). 100 Credits im Monat.“; Kopf „7 Tage Probe mit
  allem, danach Free – ohne Zahlungsdaten“ statt „1 Woche gratis, danach …“, mit Pro-AI-Produkt „7 Tage Probe: alles wie
  StudiNow Pro AI, mit 25 Credits für die StudiNow-KI, …“ (`UFTrialTexts.offerProAI`; die Probe-Karte des
  StudiNow-Kontos ebenso); Preise nur aus `Product.displayPrice`.
- **Auf dem iPad am Tarif (Stand des Codes 07.11.2026, `UFFeatureMatrix`):** eigene Karteikarten und der automatische
  Lernplan ab Plus (Free: Lernkalender von Hand; mit eigenem OpenAI-Schlüssel auch in Free der KI-Lernplan);
  „Wochentest erstellen“ ab **Pro AI** (`UFFeature.weeklyTests`, Sperrkarte im Dialog `QuizComposer`), mit der
  StudiNow-KI oder dem eigenen OpenAI-Schlüssel – nicht mehr ab Plus; „Karteikarten aus deinen Unterlagen“ mit der
  StudiNow-KI ab Pro AI, mit dem eigenen Schlüssel ab Plus; KI-Hilfe im Editor mit der StudiNow-KI ab Pro AI, mit dem
  eigenen Schlüssel in jedem Tarif. Mit Dienst entscheidet der Dienst.
- **StoreKit-Testkonfigurationen:** `UniFlow.storekit` (Plus Stufe 2, Pro AI Stufe 1) und `UniFlowAlleTarife.storekit`
  ohne `introductoryOffer`. Tests: `LocalTrialTests`, `TrialAppTests`, `PurchaseTests`, `PurchaseV2PlanSwitchTests`,
  `PlanContractTests`, `EntitlementTests`.
- Berechtigung `com.apple.developer.ubiquity-kvstore-identifier` steht in `UniFlow.entitlements` (04.11.2026; mit
  Personal Team oder im Simulator zählt nur der Schlüsselbund).
- **Inhaber (07.11.2026):** alle vier Produkte (Plus und Pro AI, je monatlich und jährlich) in App Store Connect ohne
  Einführungsangebot, eingereicht mit Version 1.0.

## 3c. Tarifseite in Web und Windows (05.11.2026)

Angleichung an das iPad (3b), nur Oberfläche und Texte (`app/static/views-abo.js`, Tests `tests/test_web_abo.py`,
`tests/test_tarife_texte.py`); die Rechte kommen weiter aus `app/plans.py`.

- **Drei Karten** Free, Plus, Pro AI aus `GET /api/billing/plans` (`contract.order`); Pro Connect erscheint nirgends.
  Kein Einführungsangebot, kein „1 Woche gratis“; die Probe heißt „alles wie Pro AI, ohne Zahlungsdaten, danach Free,
  Daten bleiben“.
- **Dienst (Web):** „Abschließen“ über Stripe nur an Plus und Pro AI (`purchase.web.plans`), nie an Free; ohne Stripe der
  Hinweis auf die Apple-App. **Während der Probe** ist kein Tarif „Dein Tarif“ (wie `purchasedPlan` auf dem iPad): die Karte
  Pro AI trägt „Probe läuft“ und bleibt kaufbar, Kopf „Probe: alles wie StudiNow Pro AI“. Nach der Probe ist Free der Stand,
  dazu „Deine Probe ist vorbei“ mit „Bei Free bleiben“.
- **Eigener PC ohne Konto-Pflicht (Einzelplatz, `mode: local`, nur noch `serve.py` in der Entwicklung):** keine Kaufwege
  und kein Link zu einem Bezahlsystem. Pro AI steht ohne Preis als „kommt mit dem StudiNow-Dienst“, ohne Knopf; Plus zeigt
  seinen Preis ohne Knopf. **Die Windows-App hat seit 05.11.2026 die Konto- und Abo-Pflicht (Abschnitt 3d, `mode:
  account`)** und schließt über Stripe im Systembrowser ab.
- Hinweis beim Geräte-Abgleich der Windows-App (`studora-link.js`): Notizen gleichen erst mit Pro AI zwischen den Geräten ab
  (Plus gilt je Gerät), vorher stand dort „ab Plus“.

## 3d. Konto- und Abo-Pflicht in Windows und Web (05.11.2026)

Entscheidung des Inhabers, Wortlaut: „anmelden immer muss ohne abo geht nichts baue das ein“. **Auslegung des
Koordinators:** In der Windows-App und in der Web-App des Dienstes (dieselbe Oberfläche) ist die Anmeldung mit dem
StudiNow-Konto immer Pflicht, und ohne aktives Abo geht nichts. Neue Konten haben die 7-Tage-Probe (wie Pro AI, wie
bisher). Nach der Probe ohne Plus oder Pro AI: nur die Abo-Seite („Abo wählen“) und die eigenen Daten zum Ansehen und
Exportieren (nur lesen); Daten werden nie gelöscht (Entscheidung „Daten bleiben“). Die iPad-App behält ihren
Free-Tarif unverändert (keine Swift-Änderung). Entscheidung im Wortlaut: `docs/ENTSCHEIDUNGEN-INHABER-2026-11-04.md`.

**Zustände** (`app/access.py`, Windows zusätzlich `app/account_mode.py`):

| Zustand | Windows-App | Web (Dienst) | Server |
|---|---|---|---|
| `signed_out` (kein Token) | nur Anmeldebildschirm | `/login` (wie bisher) | Windows lokal: jede `/api`-Anfrage außer Anmelden/Stand 401 `account_required`; Dienst 401 `unauthenticated` |
| `trial` (Probe läuft) | alles wie Pro AI, Leiste „Probe: noch N Tage alles wie StudiNow Pro AI“ mit „Abo wählen“ | ebenso | alles erlaubt |
| `active` (Plus/Pro AI aus App Store, Stripe oder Betrieb) | Rechte des Tarifs | ebenso | Rechte des Tarifs (`plans.py`) |
| `subscription_required` (Probe vorbei, kein Abo) | Start auf der Abo-Seite: „Kein aktives Abo“, „Meine Daten ansehen“ (nur lesen), „Meine Daten exportieren“ (ZIP der Daten dieses PCs); Leiste „Nur lesen“ über jeder Seite; Editor im Nur-Lesen-Modus | ebenso; Export = DSGVO-Export des Kontos | Lesen (GET) erlaubt; Schreiben 402 `subscription_required` außer `/api/account/*`, `/api/billing/*`, `/api/app-login/*` (Windows lokal zusätzlich `/api/app-account/*`, `/api/desktop/*`, Abmelden, „Hochschul-Konto entfernen“) |
| `unverified` (nur Windows: Abo seit mehr als 7 Tagen nicht prüfbar, oder Uhr zurückgestellt) | wie `subscription_required`, Text „Verbinde den PC kurz mit dem Internet“, Knopf „Erneut prüfen“ | – | 402 `subscription_unverified` |

Konten mit Rolle `admin` sind ausgenommen. „Bei Free bleiben“ und die Aufforderung nach der Probe gibt es in Web und
Windows nicht mehr (`trial-hint.js`, `planChoicePrompt` nur ohne Pflicht).

**Client-Art im Dienst** (`access.client_type`): Anfrage nur mit Sitzungs-Cookie → `web`; `Authorization: Bearer` mit
`X-StudiNow-Client: windows` bzw. `web` → `windows` bzw. `web`; jede andere Bearer-Anfrage → `app` (iPad, Android): der
Vertrag bleibt unverändert, Free bleibt Free. **Fälschen bringt nichts:** Wer die Kopfzeile weglässt oder „ipad“
schickt, bekommt genau die Rechte seines Tarifs aus der Datenbank wie auf dem iPad (ohne Abo also Free, nie mehr); die
Pflicht entscheidet nur, ob ein Konto ohne Abo schreiben darf. `GET /api/entitlements` liefert zusätzlich `access`
(`client`, `account_required`, `state`, `locked`, `read_only`, `trial_days_left`, `trial_ends_at`, `message`),
`paid_plan` (Tarif ohne Probe) und `subscriptions` (`app_store`, `stripe`: aktives Abo je Quelle); alle anderen Felder
wie bisher.

**Windows: Anmeldung.** Dienstadresse fest `https://app.studinow.app` (`service_link.DEFAULT_SERVICE_URL`,
überschreibbar mit `LERNAPP_SERVICE_URL`). Zwei Wege:
- E-Mail und Passwort im Anmeldebildschirm: einmal über den lokalen Server an `POST /api/account/login`.
- „Mit Apple anmelden“, „Mit Google anmelden“, „Konto anlegen“, „Passwort vergessen?“: im **Systembrowser** (nicht im
  App-Fenster: Google sperrt eingebettete Browser). Ablauf wie OAuth für native Apps (RFC 8252) mit Loopback und PKCE
  S256: `POST /api/app-account/browser-login` öffnet `{dienst}/login?app=windows&redirect_uri=http://127.0.0.1:<port>/konto/rueckkehr&state=…&code_challenge=…`;
  die Anmeldeseite (`login.js`) meldet an (Passwort, Apple, Google, Registrieren – alles, was sie kann; ist im Browser
  schon jemand angemeldet, fragt sie „Weiter“ / „Anderes Konto“), holt mit der Browser-Sitzung
  `POST /api/app-login/code` (Einmal-Code, 2 Minuten, nur als SHA-256 gespeichert, an Konto, Challenge und Rückleitung
  gebunden) und leitet auf den PC zurück. `GET /konto/rueckkehr` prüft `state` und tauscht den Code mit dem Verifier über
  `POST /api/app-login/token` (öffentlich, jeder Versuch verbraucht den Code) gegen eine eigene Sitzung des Geräts
  „StudiNow für Windows“. Rückleitungen nur auf `http://127.0.0.1|localhost|[::1]:<port>/konto/rueckkehr`.

**Windows: Ablage des Tokens.** Nur das Sitzungs-Token des Dienstes (30 Tage gleitend, jede Nutzung verlängert es; es ist
damit auch das Erneuerungs-Token), nie das Passwort, in der **Windows-Anmeldeinformationsverwaltung** (`app/token_store.py`:
`CredWriteW`/`CredReadW`/`CredDeleteW` über ctypes, Typ generisch, Ziel `StudiNow/dienst-sitzung`,
`CRED_PERSIST_LOCAL_MACHINE`). Begründung Python statt Tauri: Das Token braucht nur der lokale Python-Server, das
Fenster sieht es nie; ctypes braucht keine neue Abhängigkeit (das Paket `keyring` bräuchte pywin32-ctypes und versteckte
Importe für PyInstaller) und keine Rust-Änderung. Versagt die Ablage, gilt das Token nur bis zum Beenden im Speicher.
Ein Token aus `service-account.json` (bis 0.5) zieht beim ersten Start einmal um. Außerhalb von Windows (Entwicklung):
Datei `service-token` mit Rechten 0600.

**Windows: Rechte und Kulanzzeit.** `account_mode.refresh` holt `GET /api/entitlements` mit `X-StudiNow-Client: windows`
und legt die Antwort mit Zeitpunkt in `account-cache.json` im Datenordner ab: beim Start, alle 15 Minuten, beim
Zurückkehren ins Fenster und nach Kauf/Portal alle 5 Sekunden (10 Minuten lang). Danach gilt der Stand mit der
vorhandenen Rechte-Maschine (`entitlements.has`/`status`, `mode: "account"`): Plus hat am PC die Plus-Rechte, Pro AI
die von Pro AI. Ohne Netz gilt der letzte Stand höchstens `LERNAPP_OFFLINE_GRACE_DAYS` Tage (Standard 7, höchstens 60);
eine Probe endet auch offline zu ihrem Datum; läuft die Uhr mehr als einen Tag rückwärts, gilt der Stand als ungeprüft.
Ein Apple-Abo vom iPad gilt automatisch (der Dienst kennt es am Konto). Credits der StudiNow-KI zählt allein der Dienst,
gemeinsam für alle Geräte (die StudiNow-KI am PC ist noch nicht angebunden, `docs/WINDOWS-LUECKEN-2026-11-05.md` Punkt 3).
Der Geräte-Abgleich ruht ohne aktives Abo. Grenze: Die Sperre am PC ist eine Sperre der Oberfläche und des lokalen
Servers, kein Kopierschutz; alles, was Geld kostet oder geteilt wird, prüft der Dienst selbst.

**Windows: Kaufen, verwalten.** „Abschließen“ (Plus, Pro AI) → `POST /api/app-account/checkout` → der lokale Server lässt
den Dienst mit dem Token der App eine Stripe-Checkout-Sitzung anlegen (`POST /api/billing/stripe/checkout {plan,
client: "windows"}`, keine zweite Anmeldung im Browser) und öffnet sie im Systembrowser. Rückkehr auf die schlichte
Seite `{dienst}/abo-fertig` („Du kannst dieses Fenster schließen“); die App fragt den Stand selbst ab. „Abo verwalten“
→ Stripe-Kundenportal (`POST /api/app-account/portal`). Die Kaufwege (Stripe eingerichtet?) kommen aus dem
zwischengespeicherten Stand des Dienstes. Abweichung vom Auftrag „öffnet studinow.app/abo“: Die App öffnet direkt die
Stripe-Seite, weil sie das Token schon hat und der Browser sonst erneut anmelden müsste.

**Kein zweites Abo** (`stripe_billing.guard_second_purchase`, im Dienst für jeden Client): aktives Apple-Abo →
409 `apple_subscription_active` „Du hast schon ein Abo über Apple – verwalten in den Einstellungen deines iPads/iPhones.“;
aktives Stripe-Abo → 409 `stripe_subscription_active` (wechseln im Kundenportal). Windows prüft das zusätzlich vorher
und zeigt dann keinen Kaufknopf.

**Eigene Daten exportieren** (auch ohne Abo und ohne Anmeldung): Windows `GET /api/app-account/export` (ZIP: Datenbank
dieses PCs, Bilder und Aufnahmen der Notizen, selbst hinzugefügte Dokumente; ohne Hochschuldateien, Zugangsdaten,
Sitzungen); Web `GET /api/account/export` (DSGVO-Export, Abschnitt Konto). „Hochschul-Konto entfernen“ (PC weitergeben)
meldet jetzt auch vom StudiNow-Konto ab und geht ohne Abo.

**Tests:** `tests/test_account_mode.py` (Ablage des Tokens, Zustände mit Kulanzzeit und Uhr, Client-Art, Sperre je
Zustand, Anmeldung im Browser mit PKCE, Kauf und Portal, Apple-Abo sperrt den zweiten Kauf, Web-Pflicht, iPad-Vertrag
unverändert, Admin ausgenommen), `tests/js/account-gate.test.mjs`. Bewusst geändert: `tests/test_web_abo.py` (nach der
Probe im Web „Kein aktives Abo“ statt „Bei Free bleiben“), `tests/test_tarife_texte.py`, `tests/test_rechtstexte.py`
(Stand der Rechtstexte). Handtest auf echtem Windows: `docs/WINDOWS-LUECKEN-2026-11-05.md`, Abschnitt „Handtest Konto-
und Abo-Pflicht“.

**Offen (Inhaber):** Stripe-Schlüssel, Webhook-Geheimnis und Preise im Dienst (`LERNAPP_STRIPE_*`), sonst kann unter
Windows und im Web niemand abschließen und alle Konten sind nach der Probe gesperrt; Microsoft-Store-Regeln für den
eigenen Zahlungsweg vor der Einreichung prüfen; Prüfkonto mit Abo für die Store-Prüfung; Datenschutz und
Nutzungsbedingungen (Stripe, Konto-Pflicht) anwaltlich prüfen. Nicht geändert: die geplanten Hochschul-Abgleiche des
Dienstes laufen auch für gesperrte Konten weiter (`app/jobs.py`).

## 4. ChatGPT-Verbindung

`chatgpt_connection_premium` (seit 05.11.2026 **in jedem Tarif**, auch Free; vorher ab Pro AI bzw. Pro Connect; der
Name ist historisch) ist eine **reine Produktregel für die Anzeige**. Die offizielle
Kontingentnutzung hängt nicht daran: Laut Zusammenfassungen der „Sign in with ChatGPT Terms“ (openai.com/policies/
sign-in-with-chatgpt-terms; die Seite selbst war für die Prüfung nicht abrufbar) müssen Nutzer ihr ChatGPT-Abo über
die Funktion nutzen können, ohne den Partner zu bezahlen oder einen bezahlten Partner-Tarif abzuschließen; ein
Kontingent darf nicht für andere Nutzer verwendet werden. Andere Quellen berichten von Partnern, die die Verbindung
nur in bezahlten Tarifen anbieten. Bis OpenAI das für StudiNow schriftlich klärt, gilt:

- `plans.INTEGRATIONS["chatgpt"]`: `status = disabled`, `plan_gating_allowed = False`.
- `GET /api/integrations/chatgpt` → `available: false`, `connected: false`; `POST …/connect` → `503 chatgpt_not_available`.
- Im Dienst liefert `entitlements.has` für `chatgpt_connection_premium` weiter `false`, solange die Integration aus ist;
  die Abo-Seite in Web/Windows zeigt dafür „in Vorbereitung“. Auf dem iPad ist das eigene ChatGPT über den eigenen
  OpenAI-Schlüssel nutzbar (unten), darum steht das Recht im Vertrag seit 07.11.2026 auf `available`.
- Keine inoffiziellen Sitzungen, keine Passwörter, keine Cookies. Plan und Antrag: `docs/KI-CHATGPT-PLAN.md`.
- Tests aus dem eigenen ChatGPT kämen nur als `chatgpt_user` mit Stufe `private` in die Bibliothek und nur nach
  ausdrücklicher Freigabe in die Moderation (Abschnitt 5).
- **Eigener PC / Windows-App (seit 27.10.2026):** dort ist Sign in with ChatGPT gebaut und erlaubt (private, lokal
  laufende Nutzung braucht keinen Antrag): `app/chatgpt_login.py`, Einstellungen → Erweitert, Token nur auf dem Rechner,
  ohne Tarif, ohne Zahlung an StudiNow. `chatgpt_state` liefert lokal `status: local`, `available: true`,
  `plan_gating_allowed: false`. Details `docs/KI-CHATGPT-PLAN.md`, Abschnitt 3a.
- **iPad: eigener OpenAI-API-Schlüssel (seit 07.11.2026, Auftrag des Inhabers für 1.0):** „Eigenes ChatGPT“ heißt auf
  dem iPad nicht die Anmeldung bei ChatGPT (die braucht die Freigabe von OpenAI und bleibt aus, `ChatGPTLink.isEnabled`),
  sondern der eigene API-Schlüssel des Nutzers (BYOK): Einstellungen → Erweitert → „Eigenes ChatGPT“ (`OpenAIKeyCard`,
  `OpenAIKeyLink`, Kern `OpenAIKeySession`). Schlüssel nur im Schlüsselbund des Geräts (ThisDeviceOnly, je Apple-Nutzer,
  „Konto löschen“ entfernt ihn), nie beim Dienst, nie in Meldungen; Prüfung und Modellliste über `GET /v1/models`
  (Standard `gpt-4o-mini`), Anfragen direkt an `POST /v1/responses`. In jedem Tarif, auch Free; `isMetered` (kostet den
  Nutzer Geld bei OpenAI), darum nie im Hintergrund. Reihenfolge im lokalen Backend (`LocalAI.provider`): ChatGPT-Abo →
  eigener Schlüssel → StudiNow-KI. Darum ist `chatgpt_connection_premium` seit 07.11.2026 `available` (Label „Eigenes
  ChatGPT verbinden: Fragen zu Folien und KI-Lernplan“, iPad `UFFeature.ownChatGPT` auf der Free-Karte); der Dienst
  liefert das Recht in `/api/entitlements` weiter als `false`, solange die offizielle Anmeldung aus ist.
- **KI-Lernplan (07.11.2026):** „Lernplan erstellen“ → „KI-Vorschlag“ (`AIPlanSuggestDialog`): `POST /api/calendar/ai-suggest`
  baut aus Modultiteln, offenen Lehrwochen mit Dateinamen, Klausurterminen, Lernzeit und freier Zeit je Tag den Prompt
  (`AIStudyPlan`, keine Namen, keine Seitentexte), die KI schlägt Blöcke mit Thema und Dauer vor, der Nutzer wählt und
  übernimmt (`POST /api/calendar/ai-apply`, nichts ungefragt). Mit eigenem ChatGPT in jedem Tarif (auch Free: dann ist
  „Lernplan automatisch erstellen“ frei, `Entitlements.ownChatGPTConnected`), mit der StudiNow-KI ab Pro AI (Aufgabe
  `study_plan` in `app/ai_relay.py`, Recht `can_use_ai_explanations`, Kontingent `ai_assist`, Credits).

## 5. Gemeinsame KI-Testbibliothek (`app/test_library.py`, `app/library_api.py`)

Zentral in `library.db`. `POST /api/library/tests {subject, topic, subtopic?, learning_goal?, difficulty?, harder?,
count, module?, doc_sha256?, doc_ref?, doc_version?, request_id?}`:

1. Passende Fragen suchen: Fach, Thema, Unterthema, Lernziel, Schwierigkeit (bei `harder` nur schwerere), Modul,
   Hochschule, Dokument/Fassung/Fingerabdruck als Bonus, Textähnlichkeit (Jaccard über normalisierte Wörter,
   austauschbar gegen Einbettungen). Gleiche PDFs sind nicht nötig: Hannover und Hildesheim teilen sich den Pool.
   Schon gesehene Fragen eines Kontos werden nicht wiederholt.
2. Reicht der Pool: Test nur daraus, Kontingent `library_tests`.
3. Sonst nur die fehlenden Fragen generieren (Kontingent `ai_tests_new`), mit Sperre je Fach+Thema+Schwierigkeit:
   eine zweite gleiche Anfrage wartet und nutzt die Fragen der ersten. Fehlschlag → Kontingent zurück.

Prüfstufen: `private` (nie im Pool), `pending` (eingereicht, Moderation), `auto_checked` (von der StudiNow-KI aus
Fach/Thema erzeugt, automatische Prüfung bestanden), `approved`, `rejected`. Im Pool nur `auto_checked` und
`approved`. Freigabe eigener Tests: `POST /api/library/tests/{id}/share {confirm: true, topic}` – Bereinigung von
E-Mail, Telefon, Matrikelnummer, Adressen und Namen nach „Name:“ vor dem Einreichen. Moderation (Admin):
`GET /api/library/moderation`, `POST /api/library/questions/{id}/moderate {action}`. Bewertung ohne KI
(Multiple-Choice, Musterlösung) für Tests im Dienst.

Gemeinsame **Wochentests** (04.11.2026, docs/GEMEINSAME-WOCHENTESTS.md): je Schlüssel (Hochschule, Dauer, Inhalts-Hashes
der Dateien) höchstens drei Tests im Pool `shared_tests` derselben `library.db`, feste Variante je Konto
(`testshare.variant`). Geräte, die selbst erzeugen, nutzen `GET /api/v2/shared-tests/{key}` (`adopt` | `wait` |
`generate`), `POST …/{key}/claim`, `POST …/{key}/{variant}`, `DELETE …/{key}/{variant}` (nur Anmeldung, kein
Kontingent; ob ein übernommener Test zählt, ist offen).

## 6. KI-Kostenkontrolle (`app/ai_backend.py`)

Anbieter, Schlüssel und Modell zentral auf dem Server (`LERNAPP_AI_PROVIDER`, `LERNAPP_OPENAI_API_KEY`,
`LERNAPP_AI_MODEL`); ohne sie ehrlich `503 ai_not_configured`. Je Anfrage: Budgetprüfung gesamt
(`LERNAPP_AI_BUDGET_EUR`) und je Konto (`LERNAPP_AI_USER_BUDGET_EUR`), Rate-Limit (`LERNAPP_AI_RATE_PER_MINUTE`),
Reservierung in einer Schreibtransaktion, danach Tokens und Kosten (`LERNAPP_AI_PRICE_IN_EUR`/`_OUT_EUR`) in
`ai_usage_log`. Cache gleicher Anfragen (30 Tage), Sperre gegen doppelte Generierung (`ai_inflight`). Monatsbericht
für den Betrieb: `GET /api/billing/ai-usage` (Admin). Alle Grenzen gelten je Kalendermonat (UTC) und setzen sich
ohne Aufräumlauf zurück.

## 6a. Credits (04.11.2026, `app/credits.py`, `app/ai_prices.py`)

Entscheidung des Inhabers: Fragen, Erklärungen, Karteikarten, Dokument-Index und Wochentests über den Dienst kosten das
Konto **Credits**; 1 Credit = 0,9 Cent echter OpenAI-Kosten (Preistabelle je Modell in `app/ai_prices.py`, USD → EUR mit
`LERNAPP_AI_USD_EUR`, Standard 1:1; Überschreibungen `LERNAPP_AI_PRICES`; ohne Preis für das Modell sperrt der Dienst).

- **Rahmen je Kalendermonat (Europe/Berlin):** Pro AI 100 (`LERNAPP_CREDITS_PRO_AI`, höchstens 1 EUR Kosten je Konto),
  Plus/Free 0 (`LERNAPP_CREDITS_PLUS`, `_FREE`), 7-Tage-Probe 25 (`LERNAPP_CREDITS_TRIAL`); Standardwerte aus
  `plans.CREDITS`. Alte Zeilen mit `pro_connect` gelten wie Pro AI.
  Nicht Verbrauchtes verfällt; die Zeile des Monats (`credit_months`) entsteht bei der ersten Nutzung, kein nächtlicher
  Lauf. Der Rahmen folgt dem aktuellen Tarif: wer mitten im Monat Pro AI abschließt, hat sofort 100.
- **Ablauf je Anfrage** (`ai_backend.complete`): Schätzung reservieren (`reserve`), Aufruf, mit `usage` der Antwort
  abrechnen (`settle`, aufgerundet auf ganze Cent) oder bei einem Fehler ohne Kosten zurückgeben (`refund`); eine
  abgebrochene Antwort mit `usage` wird abgerechnet. Reicht der Rest nicht für die Reservierung: `429 credits_exhausted`
  mit „Credits für diesen Monat aufgebraucht – am 1. gibt es neue.“ und dem Stand unter `credits` (mit `needed`).
  Liegengebliebene Reservierungen verfallen nach 15 Minuten. Dem Client wird nie geglaubt: Kosten nur aus `usage`.
- **`request_id`** (Client, je Konto eindeutig; ohne Angabe vergibt der Server eine): dieselbe ID wird nie zweimal
  berechnet. Läuft sie noch: `409 duplicate_request`; ist sie fertig: die gespeicherte Antwort kommt 24 Stunden lang
  ohne neue Kosten zurück (`credits.replay = true`, `charged = 0`), danach wird die Antwort geleert.
- **Reihenfolge der Bezahlung:** erst Geteiltes (gemeinsamer Wochentest, Seite aus der Bibliothek: 0 Credits, kein
  KI-Aufruf), dann das eigene ChatGPT-Abo des Nutzers (0 Credits, läuft auf dem Gerät), erst dann Credits. Das
  Erzeugen für den gemeinsamen Fragenpool (`test_generation`) und die automatischen Wochentests (`weekly_test`) laufen
  weiter über die Kontingente des Tarifs (Abschnitt 1), nicht über Credits.
- **Antworten an die Apps:** `POST /api/ai/tutor` und `POST /api/ai/flashcards` liefern `credits`
  (`period`, `allowance`, `used`, `reserved`, `remaining`, `resets_at`, `plan`, `credit_eur`, `charged`, `replay`);
  `GET /api/entitlements` denselben Stand ohne `charged`/`replay`. Am eigenen PC ist `credits` null.
- **Betrieb:** `GET /api/billing/ai-costs?days=31` (Admin): `credit_ledger` je Tag und Modell, laufender Monat
  (Anfragen, Konten, Kosten, Credits, erschöpfte Konten), Preistabelle mit Prüfdatum. Konto-Export enthält
  `ki_credits` und `ki_credits_anfragen`; beim endgültigen Löschen wird `credit_months` gelöscht und `credit_ledger`
  ohne Konto und ohne gespeicherte Antworten behalten (Kostenrechnung). Tests: `tests/test_credits.py`.

## 6b. StudiNow-KI auf dem iPad (05.11.2026)

Entscheidung des Inhabers: Die KI kommt in 1.0 über **Pro AI** (StudiNow-KI mit 100 Credits, harte Grenze 1 €,
Modellmischung im Dienst), weil „Eigenes ChatGPT verbinden“ ohne Freigabe durch OpenAI aus ist (`ChatGPTLink.isEnabled`).

**Weg von Kauf bis Antwort:**
1. Kauf im App Store (Pro AI) oder die 7-Tage-Probe auf dem iPad (Abschnitt 3b) → `Entitlements.plan == .proAI`.
2. Anmelden beim StudiNow-Konto (Einstellungen → Konto & Tarif): „Mit Apple anmelden“ nativ
   (`SignInWithAppleButton`, Nonce: Rohwert an den Dienst, SHA-256 an Apple) → `POST /api/account/login/apple`
   `{identity_token, nonce, university, email?, device_id, device_name}`; oder E-Mail und Passwort. Neue Konten bekommen
   beim Dienst die Probe (`accounts.grant_trial`, 25 Credits). Gespeichert wird nur das Sitzungs-Token im Schlüsselbund
   je Apple-Nutzer (`StudoraAccountKeychain`, nie synchronisiert, „Konto löschen“ in der App entfernt es).
3. Abo beim Dienst: einmal je Anmeldung alle gültigen Transaktionen (`Transaction.currentEntitlements`) und danach jede
   neue (Kauf, Verlängerung, `Entitlements.verifyOnServer`) an `POST /api/billing/apple/verify`; beim Kauf mit Konto
   `appAccountToken` = `apple_account_token` (`UFBillingServiceLink`, jetzt eingeschaltet). 409
   `subscription_owned_by_other_account` zeigt die Kontokarte; 503 `apple_not_configured` und Netzfehler bleiben still
   (der Kauf gilt auf dem iPad immer, der nächste Start meldet erneut).
4. Weg der KI (`StudiNowAIAccess.decide`, UniFlowCore/AI/StudiNowAI.swift): angemeldet **und** (Pro AI auf dem iPad
   oder `plan == pro_ai` beim Dienst oder laufende Probe des Kontos) → `ready`, die App hängt `StudiNowAI` ins lokale
   Backend (`LocalAI.setService`). Pro AI/Probe ohne Anmeldung → `signInRequired` (Hinweis „Melde dich … an“ mit
   „Mit StudiNow-Konto anmelden“). Free/Plus → `planRequired` (Tarif-Hinweis, „Tarife ansehen“). Ohne `ready` geht
   keine Anfrage an den Dienst.
5. Anfrage: Das lokale Backend baut den Prompt wie für das eigene ChatGPT (das iPad hat Dateien und Seitentexte, der
   Dienst nicht) und schickt ihn mit Aufgabe an `POST /api/ai/relay` (wie die Windows-App, app/ai_relay.py):
   `tutor:<modus>` (KI-Hilfe, KI-Start; `cache` nur für geteilte ganze Seiten, `fresh` bei „Neu erklären lassen“,
   `image` beim „Bereich an KI“, höchstens 3 MB, Bild-Tokens zählen in die Credits), `flashcards` (Karten aus
   Dokument, Wochenstapel), `week_test` (mit `options`, `exam`), `grade`, `weekly`. „Ganzes Dokument“ geht an
   `POST /api/ai/document/{plan,step}` mit `page_texts` (wie `doc_explain_api._forward`). Die Antwort trägt `credits`
   (mit `charged`); die Kostenzeile in KI-Hilfe und KI-Start zeigt „StudiNow-KI · – 3 Credits (37 übrig)“, beim Öffnen
   den Stand aus `GET /api/entitlements`.
6. Reihenfolge der Bezahlung: eigener Erklärungsspeicher und geteilte Erklärungen (0 Credits) → eigenes ChatGPT, wenn
   verbunden (`LocalAI.provider` nimmt es zuerst) → StudiNow-KI mit Credits. Im Hintergrund (Vorab einordnen,
   Erklärungen vorab, Dokument-Index) nie die StudiNow-KI (`LocalAI.backgroundProvider`, `LocalDocIndex.ai(from:)`);
   ohne Aufgabe beim Dienst (Einordnen einer Datei) antwortet sie nicht (`ai_task_unsupported`).

**Fehler** (Status und Code bleiben, Text aus `StudiNowAIText`): 402 `subscription_required` und 403
`plan_required` → Text zu Pro AI mit „Tarif ansehen“; 429 `credits_exhausted` (Text des Dienstes, Stand übernommen),
`quota_exhausted` → „Tarif ansehen“; 429 `rate_limited` mit Retry-After; 401 → Token weg, „Mit StudiNow-Konto
anmelden“; nicht erreichbar → 503 `service_unreachable` „Der StudiNow-Dienst ist gerade nicht erreichbar …“.

**Dienst-Adresse:** Standard `https://app.studinow.app` (`StudoraAccountLink.defaultServiceURL`); anders mit
Info.plist-Eintrag `StudoraServiceURL` (leer = aus) oder dem Startargument `-StudoraServiceURL https://…`; nur https.
Damit ist die Kontokarte jetzt in jedem Build sichtbar (vorher erst mit Eintrag).

**Probe iPad ↔ Dienst:** Die Probe auf dem iPad (je Apple-ID ab dem ersten Start) und die Probe des Kontos (je Konto ab
dem Anlegen, 25 Credits) sind zwei Uhren. Credits gibt es nur beim Dienst. Wer in der iPad-Probe ein neues Konto mit
Apple anlegt, bekommt die Konto-Probe dazu; die KI läuft dann bis zum Ende der **Konto**-Probe bzw. bis die 25 Credits
verbraucht sind. Ist das Konto älter (Probe vorbei, kein Abo), antwortet der Dienst trotz laufender iPad-Probe mit 402/403
→ Tarif-Hinweis. Der Dienst entscheidet immer; die App sendet nur bei `ready`.

**Muss am laufenden Dienst geprüft werden:** `LERNAPP_APPLE_CLIENT_IDS` enthält die Bundle-ID der App (sonst 501
`provider_not_configured` bzw. 401 `token_invalid` beim nativen Token); `LERNAPP_APPLE_ROOT_CERTS` für
`/api/billing/apple/verify`; Relay-Antworten mit echten Modellen (gpt-6-luna, Claude Sonnet über Bedrock) und echte
Credits; Antwortzeit eines Schritts „Ganzes Dokument“ (die App wartet bis 180 s).

Tests: `UniFlowCoreTests/StudiNowAITests.swift`, `DocExplainTests` (Weiterleitung), `UniFlowTests/StudiNowAIAppTests.swift`
(URLProtocol-Attrappe), angepasst `StudoraAccountAppTests`, `PlanContractTests`.

## 7. Tests

`tests/test_subscriptions.py` (Testfälle 1–14 des Auftrags und mehr) und `tests/test_billing.py`; Apple-Signaturen
mit einer selbst erzeugten Zertifikatskette, KI mit einer Attrappe. Gesamtlauf: 402 bestanden. Die zwei Tests in
`tests/test_plan_names.py` scheitern schon auf `develop` (Kodierung der Fixture, nicht Teil dieser Arbeit).

## 8. Offen

- **Inhaber:** Produkte in App Store Connect (eine Abo-Gruppe, zwei Produkte: Plus, Pro AI), App Store Server Notifications auf
  `/api/billing/apple/notifications` einstellen, Apples Wurzelzertifikat auf dem Server ablegen; OpenAI-Konto mit
  API-Schlüssel und Modellwahl für Pro AI; Interessenformular „Sign in with ChatGPT“ mit der Frage nach der
  Tarif-Kopplung; Datenschutzerklärung (KI über das Backend, Weitergabe an OpenAI) und Preise in den Rechtstexten.
- **Mac-Sitzung:** Swift-Tarife auf `fixtures/plans/plans.json` umstellen (`UFPlan`, `UFFeature`,
  `PurchaseStore.productIDs`), (erledigt 05.11.2026, Abschnitt 6b: `appAccountToken` setzen, Transaktionen an
  `/api/billing/apple/verify` melden),
  Abo-Seite mit drei Tarifen, PencilKit nur mit `can_use_pencilkit`. Siehe Nachtrag in `docs/STAND-MAC-SITZUNG.md`.
- **Noch nicht gebaut:** Zahlung im Web/Windows, Community-Kommentare, die ChatGPT-Verbindung selbst,
  Einbettungen für die Themenerkennung. Den KI-Wochenplan (`/api/plan/generate`) gibt es seit dem 30.10.2026 nicht
  mehr: Der Lernplan ist regelbasiert (`app/study.py`, nur Stoff der Lehrwoche plus Skriptrest nach dem Marker).

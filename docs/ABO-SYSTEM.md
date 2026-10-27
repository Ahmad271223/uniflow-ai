# Studora-Abosystem: vier Tarife, Berechtigungen, KI-Testbibliothek (Stand 27.10.2026)

Auftrag des Inhabers vom 27.10.2026. Umgesetzt im Dienst (Python, `LERNAPP_MODE=hosted`), in der Web-Oberfläche
(gilt auch für die Windows-App) und als gemeinsamer Vertrag für die Apps. Branch `feature/studora-abos`.
Ersetzt die Entscheidungen „nur Free und Plus“ und „KI entfällt in V1“ aus `docs/AUFTRAG-APPSTORE-V1.md`, Abschnitt 6.

## 1. Tarife

| Tarif | Preis/Monat | Neue KI-Tests | Bibliothekstests | KI-Erklärungen u. a. | PDF bearbeiten |
|---|---:|---:|---:|---:|:---:|
| Studora Free | 0,00 € | 0 | 0 | 0 | nein |
| Studora Plus | 1,99 € | 3 | 4 | 0 | ja |
| Studora Pro Connect | 2,99 € | 3 | unbegrenzt (Fair Use 300) | 0 | ja |
| Studora Pro AI | 3,99 € | 40 | unbegrenzt (Fair Use 300) | 150 | ja |

Jeder Tarif enthält alle Rechte des niedrigeren. **Quelle aller Werte: `app/plans.py`.** Daraus erzeugt
`tools/gen-plans-fixture.py` die Datei `packages/shared-contracts/fixtures/plans/plans.json`; Swift und Kotlin prüfen
ihre Tabellen dagegen, `tests/test_subscriptions.py::test_plans_fixture_is_current` hält sie aktuell.

**Widerspruch im Auftrag:** Die Tariftabelle nennt für Plus 3 neue KI-Tests, Testfall 3 „maximal sechs“. Umgesetzt
ist 3 (Tabelle). Der Wert steht nur in `app/plans.py` (`QUOTAS["plus"]["ai_tests_new"]`) und lässt sich dort ändern.

Apple-Produkte (eine Abo-Gruppe, damit Apple Upgrades, Downgrades und Doppel-Abos regelt):
`de.uniflow.plus.monthly`, `de.uniflow.proconnect.monthly`, `de.uniflow.proai.monthly`. Die Kennungen bleiben bei
`de.uniflow`, weil die Bundle-ID `de.uniflow.ai` ist; in App Store Connect sind sie noch nicht angelegt.

## 2. Berechtigungen

Ein Recht ist ein Name mit Ja/Nein je Tarif (`app/plans.py::ENTITLEMENTS`), dazu der Stand der Umsetzung:
`available` (darf beworben werden), `coming_soon` (Community-Kommentare: die Funktion gibt es noch nicht) und
`disabled` (ChatGPT-Verbindung, Abschnitt 4). Die Abo-Seite zeigt nur `available` als enthalten. Funktionen der
Studora-KI erscheinen als „in Vorbereitung“, solange auf dem Server kein KI-Schlüssel eingerichtet ist.

Serverseitig (`app/entitlements.py`): Der Tarif kommt immer aus der Datenbank, nie aus der Anfrage. Geprüft wird an:

| Endpunkt | Recht |
|---|---|
| `PUT /api/files/{id}/annotations`, `POST …/annotations/restore/{v}`, `POST /api/files/{id}/assets` | `can_annotate_pdf` |
| `POST /api/sync/push` (nur Einträge `annotations`, Ergebnis `plan_required`) | `can_sync_annotations` |
| `POST /api/community/solutions` (Lesen und Laden für alle) | `can_share_solutions` |
| `POST /api/library/tests` | `can_access_shared_tests` bzw. `can_generate_studora_ai_tests` |
| `GET /api/learning/stats` · `…/review` · `…/recommendations` | `can_use_advanced_analytics` · `can_review_wrong_answers` · `can_get_recommendations` |
| `GET /api/tests` (ohne Recht die letzten 10) | `can_use_extended_test_history` |
| `POST /api/ai/tutor` im Dienst (je Modus) | `can_use_ai_explanations`, `…_summaries`, `…_generated_questions` |

Antwort ohne Recht: `403 {"code": "plan_required", "entitlement", "required_plan"}`. Kontingent leer:
`429 {"code": "quota_exhausted", "feature", "used", "limit"}`. **Einzelplatz (eigener PC, Windows-App):** keine
Konten, keine Tarife, alles frei; die KI läuft dort weiter über `claude -p`.

Web/Windows: `state.entitlements` aus `GET /api/entitlements`, `can(name)` in `core.js`; der Editor öffnet ohne
`can_annotate_pdf` im Nur-Lesen-Modus (Werkzeuge aus, Hinweis mit Link auf die Abo-Seite). Seite `#/abo`, auch unter
Einstellungen → Abo & Tarife.

## 3. Abo-Stand und Zahlungen

Tabellen in `accounts.db` (`app/billing.py`): `entitlements` (je Konto und Quelle: Tarif, Ablauf, Status,
`will_renew`, `pending_plan`), `usage` und `usage_requests` (Kontingente je Monat, Anfrage-ID gegen Doppelzählung,
`BEGIN IMMEDIATE` gegen parallele Anfragen), `apple_transactions`, `apple_notifications`. Quellen: `app_store` und
`manual` (Betrieb: `python -m app.accounts plan <email> free|plus|pro_connect|pro_ai [bis YYYY-MM-DD]`, bisheriges
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

**Web, Windows, Android:** kein Zahlungsweg vorhanden (kein Zahlungsanbieter eingerichtet). `GET /api/billing/plans`
meldet `purchase.web.available = false`; ein Abo aus der Apple-App gilt automatisch auf allen Geräten desselben Kontos.

## 4. ChatGPT-Verbindung

`chatgpt_connection_premium` (ab Pro Connect) ist eine **reine Produktregel für die Anzeige**. Die offizielle
Kontingentnutzung hängt nicht daran: Laut Zusammenfassungen der „Sign in with ChatGPT Terms“ (openai.com/policies/
sign-in-with-chatgpt-terms; die Seite selbst war für die Prüfung nicht abrufbar) müssen Nutzer ihr ChatGPT-Abo über
die Funktion nutzen können, ohne den Partner zu bezahlen oder einen bezahlten Partner-Tarif abzuschließen; ein
Kontingent darf nicht für andere Nutzer verwendet werden. Andere Quellen berichten von Partnern, die die Verbindung
nur in bezahlten Tarifen anbieten. Bis OpenAI das für Studora schriftlich klärt, gilt:

- `plans.INTEGRATIONS["chatgpt"]`: `status = disabled`, `plan_gating_allowed = False`.
- `GET /api/integrations/chatgpt` → `available: false`, `connected: false`; `POST …/connect` → `503 chatgpt_not_available`.
- `chatgpt_connection_premium` ist überall `false`, solange die Integration aus ist; die Abo-Seite zeigt „in Vorbereitung“.
- Keine inoffiziellen Sitzungen, keine Passwörter, keine Cookies. Plan und Antrag: `docs/KI-CHATGPT-PLAN.md`.
- Tests aus dem eigenen ChatGPT kämen nur als `chatgpt_user` mit Stufe `private` in die Bibliothek und nur nach
  ausdrücklicher Freigabe in die Moderation (Abschnitt 5).
- **Eigener PC / Windows-App (seit 27.10.2026):** dort ist Sign in with ChatGPT gebaut und erlaubt (private, lokal
  laufende Nutzung braucht keinen Antrag): `app/chatgpt_login.py`, Einstellungen → Erweitert, Token nur auf dem Rechner,
  ohne Tarif, ohne Zahlung an Studora. `chatgpt_state` liefert lokal `status: local`, `available: true`,
  `plan_gating_allowed: false`. Details `docs/KI-CHATGPT-PLAN.md`, Abschnitt 3a.

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

Prüfstufen: `private` (nie im Pool), `pending` (eingereicht, Moderation), `auto_checked` (von der Studora-KI aus
Fach/Thema erzeugt, automatische Prüfung bestanden), `approved`, `rejected`. Im Pool nur `auto_checked` und
`approved`. Freigabe eigener Tests: `POST /api/library/tests/{id}/share {confirm: true, topic}` – Bereinigung von
E-Mail, Telefon, Matrikelnummer, Adressen und Namen nach „Name:“ vor dem Einreichen. Moderation (Admin):
`GET /api/library/moderation`, `POST /api/library/questions/{id}/moderate {action}`. Bewertung ohne KI
(Multiple-Choice, Musterlösung) für Tests im Dienst.

## 6. KI-Kostenkontrolle (`app/ai_backend.py`)

Anbieter, Schlüssel und Modell zentral auf dem Server (`LERNAPP_AI_PROVIDER`, `LERNAPP_OPENAI_API_KEY`,
`LERNAPP_AI_MODEL`); ohne sie ehrlich `503 ai_not_configured`. Je Anfrage: Budgetprüfung gesamt
(`LERNAPP_AI_BUDGET_EUR`) und je Konto (`LERNAPP_AI_USER_BUDGET_EUR`), Rate-Limit (`LERNAPP_AI_RATE_PER_MINUTE`),
Reservierung in einer Schreibtransaktion, danach Tokens und Kosten (`LERNAPP_AI_PRICE_IN_EUR`/`_OUT_EUR`) in
`ai_usage_log`. Cache gleicher Anfragen (30 Tage), Sperre gegen doppelte Generierung (`ai_inflight`). Monatsbericht
für den Betrieb: `GET /api/billing/ai-usage` (Admin). Alle Grenzen gelten je Kalendermonat (UTC) und setzen sich
ohne Aufräumlauf zurück.

## 7. Tests

`tests/test_subscriptions.py` (Testfälle 1–14 des Auftrags und mehr) und `tests/test_billing.py`; Apple-Signaturen
mit einer selbst erzeugten Zertifikatskette, KI mit einer Attrappe. Gesamtlauf: 402 bestanden. Die zwei Tests in
`tests/test_plan_names.py` scheitern schon auf `develop` (Kodierung der Fixture, nicht Teil dieser Arbeit).

## 8. Offen

- **Inhaber:** Produkte in App Store Connect (eine Abo-Gruppe, drei Produkte), App Store Server Notifications auf
  `/api/billing/apple/notifications` einstellen, Apples Wurzelzertifikat auf dem Server ablegen; OpenAI-Konto mit
  API-Schlüssel und Modellwahl für Pro AI; Interessenformular „Sign in with ChatGPT“ mit der Frage nach der
  Tarif-Kopplung; Datenschutzerklärung (KI über das Backend, Weitergabe an OpenAI) und Preise in den Rechtstexten.
- **Mac-Sitzung:** Swift-Tarife auf `fixtures/plans/plans.json` umstellen (`UFPlan`, `UFFeature`,
  `PurchaseStore.productIDs`), `appAccountToken` setzen, Transaktionen an `/api/billing/apple/verify` melden,
  Abo-Seite mit vier Tarifen, PencilKit nur mit `can_use_pencilkit`. Siehe Nachtrag in `docs/STAND-MAC-SITZUNG.md`.
- **Noch nicht gebaut:** Zahlung im Web/Windows, Community-Kommentare, die ChatGPT-Verbindung selbst,
  KI-Wochenplan im Dienst (`/api/plan/generate` bleibt 501; „Intelligente Lernplanung“ ist heute regelbasiert über
  Empfehlungen), Einbettungen für die Themenerkennung.

# Tarif-Matrix Karteikarten und Tests (Stand des Codes, 04.11.2026)

Prüfung des Abo-/Berechtigungssystems für Karteikarten und Tests über die Tarife **StudiNow Free**, **Plus (1,99 €)**,
**Pro AI (3,99 €)** und die **7-Tage-Probe** (alles wie Pro AI, danach Free, Daten bleiben). Die Tabellen zeigen, was der
Code heute wirklich tut – nicht, was die Docs versprechen. Abweichungen vom Auftrag des Inhabers stehen in Abschnitt 4.
**Nachtrag 04.11.2026 (Teil 1 der Angleichung):** Pro Connect gestrichen (Rechte auf Pro AI, alter Schlüssel gilt wie
Pro AI), Kontingente Plus 4/4, Pro AI 20 neue KI-Tests, „Wochentest erstellen“ auf dem iPad ohne Dienst ab Plus, Probe-
und Tariftexte mit „alles wie Pro AI, 25 Credits“; die Tabellen unten zeigen den neuen Stand, offene Punkte stehen in
Abschnitt 4 als „Teil 2“.
**Nachtrag 04.11.2026 (Teil 2):** Recht `can_use_flashcards` (ab Plus) im Vertrag, im Dienst auf allen schreibenden und
übenden Karteikarten-Routen (403 „Karteikarten gibt es ab StudiNow Plus.“), Lesen in jedem Tarif; Wochenstapel
übernehmen ab Plus ohne Credits und ohne bestätigte E-Mail, nur das Erzeugen eines neuen Satzes ist StudiNow-KI (Pro
AI). Web und iPad zeigen Free die eigenen Karten im Lesemodus. Auf dem iPad ohne Dienst sind „Fehlende Wochentests“ und
die automatischen Wochentests Plus. Das lokale Backend (Kern) bleibt bewusst ohne Tarif: jede Sperre liegt in der
App-Oberfläche (`CardsPage`, `DocumentView`, `FlashcardComposer`, `QuizComposer`, `ExamsPage`, `UFWeeklyAutoGate`).
**Nachtrag 04.11.2026 (Zusammenführung mit der Cloud-Sitzung):** Notizen-Abgleich zwischen iPad, PC und Web
(`can_sync_annotations`) erst ab Pro AI („Plus gilt je Gerät“); neues Recht `can_use_prepared_week_sets` (Pro AI, fertige
Fragen je Vorlesungswoche, nur Dienst); KI-Karteikarten auf Auftrag (`POST /api/ai/flashcards` mit `module_id`) hängen an
`can_use_ai_generated_questions`; neue Karten und Stapel im Geräte-Abgleich nur mit `can_use_flashcards`.
**Nachtrag 05.11.2026 (Angleichung an den Wortlaut des Inhabers, `docs/ENTSCHEIDUNGEN-INHABER-2026-11-05.md`):**
Community ab Plus, auch das Lesen (`can_read_community` von `free` auf `plus`; Free sieht „Community ab Plus“, der Dienst
antwortet mit 403 `plan_required`; eigene Beiträge zurückziehen geht weiter in jedem Tarif). Eigenes ChatGPT in jedem
Tarif (`chatgpt_connection_premium` von `pro_ai` auf `free`, Integration weiter `disabled`, `plan_gating_allowed`
False). Neues Kontingent `card_stacks_adopted` (Wochenstapel aus dem Pool und geteilte Stapel übernehmen): Free 0,
Plus 4 / Monat, Pro AI unbegrenzt (Fair Use 300); derselbe Stapel zählt im Monat einmal. Die Zeilen unten zeigen den
Soll-Stand nach dieser Angleichung.

Quellen der Gates:

- **Dienst (Python):** `app/plans.py` (`ENTITLEMENTS`, `QUOTAS`, `TRIAL`), `app/entitlements.py` (`require` → 403
  `plan_required`, `consume` → 429 `quota_exhausted`, `require_verified_for_ai` → 403 `email_unverified`),
  `app/billing.py` (`current_plan`, Probe als Quelle `trial`), `app/credits.py` (Credits: Pro AI 100, Probe 25, sonst 0),
  `app/jobs.py::HostedQuota` (Wochentests), `app/library_api.py` (Bibliothek, Lernstatistik), `app/server.py`
  (`TUTOR_ENTITLEMENT`, `HOSTED_UNAVAILABLE`, Karteikarten-Routen ohne Gate).
- **iPad (Swift):** `Purchases/Plans.swift` (`UFPlan`, `UFPlanCatalog.sellable = [free, plus, proAI]`, `UFEntitlement.onDevice`),
  `Purchases/Entitlements.swift` (`UFFeature`, `UFFeatureMatrix`, `Entitlements.plan`, `UFGate`, `UFLockedCard`,
  `UFLockedSheet`, `ufRequires`), `Purchases/LocalTrial.swift` (`UFLocalTrial`, `UFPlanPrecedence`: Dienst > App Store >
  Probe > Free). Das lokale Backend (`UniFlowCore/LocalBackend`) kennt **keinen Tarif und keine Kontingente**; jede Sperre
  liegt in der App-Oberfläche.
- **Web/Windows:** `app/static/core.js::can()` für `can_annotate_pdf` (Editor) und `can_use_flashcards`
  (`flashcards.js::readOnly`, `viewCards` im Lesemodus); die Test-Ansichten rufen den Dienst ohne eigene Sperre.

Legende: ✓ frei · ✓ᴾ frei, weil die Probe Pro AI ist · 🔒 gesperrt (Schloss/403 mit Weg zum Tarif) · n/Monat Kontingent ·
– gibt es auf dieser Plattform nicht · **ansteht** = widerspricht dem Auftrag, siehe Abschnitt 4.

## 1. iPad ohne Dienst (lokales Backend, KI nur über das eigene ChatGPT)

Tarif = `Entitlements.plan` aus StoreKit bzw. Probe auf dem iPad (`UFLocalTrial`). Pro AI hat hier denselben Umfang wie
Plus (`UFPlanCard.sameScope(as: .proAI) == .plus`); die Pro-AI-Karte erscheint nur, wenn StoreKit das Produkt liefert
(`UFPlanCatalog.needsProduct`).

| Funktion | Free | Plus | Pro AI | Probe | Gate (Code) |
|---|:---:|:---:|:---:|:---:|---|
| Karte von Hand anlegen, bearbeiten, löschen, Stapel | 🔒 Plus (Knöpfe fehlen, Hinweis) | ✓ | ✓ | ✓ᴾ | `CardsPage.canEdit` (api.isLocal) = `UFFeatureMatrix.flashcards(plan:).canEdit`; `UFFeature.flashcards.minimumPlan = .plus` |
| Wiederholen / Trainer | 🔒 Plus | ✓ | ✓ | ✓ᴾ | `CardsPage` ohne „Heute fällig“/„Frei üben“ im Lesemodus, `FlashcardsAppTests.testFreeShowsTheCardsReadOnly` |
| Eigene Karten nach der Probe **lesen** | ✓ Lesemodus („Mit Plus übst und bearbeitest du deine Karten wieder.“ + „Tarife ansehen“; ohne Karten die Sperrkarte) | ✓ | ✓ | – | `UFFlashcardAccess(canView: true, canEdit:)` wie `UFNoteAccess`, `FlashcardReadOnlyHint`, `testTrialFullThenReadOnlyAfterTheTrial` |
| Karten für Woche n holen, geteilten Stapel übernehmen, Stapel teilen | 🔒 Plus (Schloss `ufRequires(.flashcards)`; Teilen ausgeblendet) | ✓ | ✓ | ✓ᴾ | `CardsPage.plusOnly`, `PlanMatrixAppTests.testCardsPageIsReadOnlyForFreeWithoutService` |
| „Als Karteikarte“ aus markiertem PDF-Text | 🔒 Plus (`UFLockedSheet`) | ✓ | ✓ | ✓ᴾ | `DocumentView.swift:299` (`api.isLocal && !allows(.flashcards)`) |
| Karten aus KI-Antwort (Tutor-Modus `flashcards`) | KI ✓ (eigenes ChatGPT), Speichern 🔒 Plus | ✓ | ✓ | ✓ᴾ | KI: `AIEndpoints` ohne Tarif; Speichern über `CardsPage`/`FlashcardComposer` (Plus) |
| „Karteikarten aus Dokument“ (KI) | 🔒 Plus (nicht Pro AI) | ✓ mit ChatGPT | ✓ mit ChatGPT | ✓ᴾ | `FlashcardComposer.needsPlus/allowed`; ohne ChatGPT „Verbinde dein ChatGPT“ |
| Wochentest erstellen (Standard geteilt / eigener) | 🔒 Plus (Sperrkarte im Dialog, lädt nichts) | ✓ mit ChatGPT | ✓ mit ChatGPT | ✓ᴾ | `QuizComposer.needsPlus/allowed` → `UFLockedCard(.weeklyTests)`; `UFFeature.weeklyTests.minimumPlan = .plus`; `TestEndpoints` ohne Kontingent |
| „Fehlende Wochentests“ (Woche erzeugen) auf der Seite „Tests“ | 🔒 Plus (Schloss; ohne Tests die Sperrkarte) | ✓ mit ChatGPT | ✓ mit ChatGPT | ✓ᴾ | `ExamsPage.weeklyAllowed/plusOnly`, `PlanMatrixAppTests.testExamsPageLocksWeekGenerationForFree` |
| Automatische Wochentests (Takt, nach dem Abgleich, Hintergrund) | 🔒 Plus (kein Lauf, `.off`) | ✓ mit ChatGPT | ✓ mit ChatGPT | ✓ᴾ | `UFWeeklyAutoGate` in `WeeklyAutoTicker`, `StudIPSync.autoPlan`, `BackgroundSyncController.weeklyTick`; `WeeklyAppTests` |
| Test aus der Bibliothek übernehmen | – | – | – | – | nur Dienst (`/api/library/tests`), kein iPad-Aufruf |
| Test durchführen, abgeben, Ergebnis | ✓ | ✓ | ✓ | ✓ | `ExamsPage`, kein Gate |
| KI-Tutor (erklären, zusammenfassen, Begriffe, ähnlich) | ✓ mit ChatGPT | ✓ | ✓ | ✓ᴾ | `AIStartView`/Tutor: nur `ufAIEnabled`; `AICost.line` zeigt für Free/Plus „Braucht dein ChatGPT“ |
| Lernstand je Modul | ✓ | ✓ | ✓ | ✓ | `LernstandView`, `Mastery` im Kern: kein Gate |
| Community (CloudKit): lesen, beitreten, Lösungen und Stapel ansehen, schreiben (seit 05.11.2026) | 🔒 Plus („Community ab Plus“) | ✓ | ✓ | ✓ᴾ | `UFFeature.communityRead.minimumPlan = .plus`; eigene Beiträge zurückziehen in jedem Tarif |
| Lernstatistik des Dienstes, Testbibliothek, KI-Tests von StudiNow | 🔒 „in Vorbereitung“ (kein Tarif schaltet frei) | 🔒 | 🔒 | 🔒 | `UFEntitlement.onDevice = .needsService` → `UFPlanCard.preparing` (Lernstatistik u. a. auf der Pro-AI-Karte) |

## 2. iPad mit StudiNow-Dienst (Konto verbunden, `session.api` nicht lokal)

Die App sperrt nichts mehr selbst (`needsPlus == false`); jede Antwort kommt vom Dienst mit dessen Tarif
(`StudoraAccountLink.planStatus`, Probe des Kontos hat Vorrang vor dem App-Store-Kauf). Die Zellen sind die des Dienstes
(Abschnitt 3); abweichend:

| Funktion | Free | Plus | Pro AI | Probe | Gate (Code) |
|---|:---:|:---:|:---:|:---:|---|
| Seite „Karteikarten“, „Als Karteikarte“, Composer | Lesen ✓, Schreiben/Üben 403 „Karteikarten gibt es ab StudiNow Plus.“ (App zeigt kein eigenes Schloss) | ✓ | ✓ | ✓ | `CardsPage.needsPlus`, `DocumentView.swift:299`, `FlashcardComposer.needsPlus` nur bei `isLocal`; Dienst `can_use_flashcards` |
| „Karteikarten aus Dokument“ | 🔒 403 Pro AI | 🔒 403 Pro AI | ✓ 150/Monat + Credits | ✓ᴾ (25 Credits) | Dienst `POST /api/ai/flashcards` |
| Wochentest erstellen (Dialog) | 501 `not_available_hosted` für alle | 501 | 501 | 501 | `HOSTED_UNAVAILABLE` (`POST /api/tests/generate`); Wochentests nur als Job (`/api/weekly/tick`) |
| KI-Tutor | 🔒 403 Pro AI | 🔒 403 Pro AI | ✓ 150/Monat | ✓ᴾ | `TUTOR_ENTITLEMENT`; `AICost.line` zeigt „≈ n Credits“ nur bei `.proAI` |

## 3. Web / Windows / Dienst (`LERNAPP_MODE=hosted`)

Tarif = `billing.current_plan` (höchste aktive Quelle: `app_store`, `stripe`, `trial`, `manual`). Am eigenen PC
(Einzelplatz) ist alles frei (`billing.LOCAL_PLAN`). Meldungen: 403 „Diese Funktion gibt es ab StudiNow Pro AI.“ bzw.
„… ab StudiNow Plus.“, 429 „<Kontingent>: Kontingent für diesen Monat aufgebraucht (n von m).“, 403 „Bitte zuerst die
E-Mail-Adresse bestätigen.“, 501 „KI-Funktionen kommen mit dem KI-Update.“

| Funktion / Endpunkt | Free | Plus | Pro AI | Probe | Gate (Code) |
|---|:---:|:---:|:---:|:---:|---|
| Karten anlegen, bearbeiten, löschen, Stapel, Wiederholen, Trainer (`POST/PATCH/DELETE /api/flashcards…`, `/api/flashcard-stacks…`) | 🔒 403 „Karteikarten gibt es ab StudiNow Plus.“ | ✓ | ✓ | ✓ᴾ | `app/server.py::_require_flashcards` → `can_use_flashcards` (from `plus`), Meldung `entitlements.MESSAGES` |
| Karten und Stapel nach der Probe lesen (`GET /api/flashcards`, `GET /api/flashcard-stacks`) | ✓ | ✓ | ✓ | – | ohne Gate (Daten bleiben); Web: `viewCards` im Lesemodus |
| Wochenstapel holen (`POST /api/flashcard-stacks/week/…`): vorhandenen bzw. fertigen aus dem Pool übernehmen | 🔒 403 Plus | 4/Monat (`card_stacks_adopted`), 0 Credits, ohne bestätigte E-Mail | unbegrenzt (Fair Use 300) | ✓ᴾ | `can_use_flashcards`; `cardshare.obtain(can_generate=False)` übernimmt jede fertige Variante; Kontingent seit 05.11.2026 |
| Wochenstapel neu erzeugen (Pool leer) | 🔒 | 🔒 403 Pro AI | ✓ Credits, E-Mail bestätigt | ✓ᴾ 25 Credits | `can_use_ai_generated_questions` + `require_verified_for_ai` nur in `generate()` |
| Stapel teilen, zurückziehen, geteilten Stapel übernehmen (`/api/flashcard-stacks/{id}/share`, `/api/community/card-stacks/{id}/adopt`) | 🔒 403 Plus (Lesen, Liken, Melden wie Community: ab Plus; Zurückziehen in jedem Tarif) | ✓ (Teilen mit bestätigter E-Mail wie Lösungen); Übernehmen 4/Monat (`card_stacks_adopted`) | ✓, Übernehmen unbegrenzt (Fair Use 300) | ✓ᴾ | `community_cards_api._flashcards`; Kontingent seit 05.11.2026 |
| Community lesen, beitreten, liken, melden, Fragen und Kommentare (`/api/community/*`) | 🔒 403 „Die Community gibt es ab StudiNow Plus.“ (seit 05.11.2026) | ✓ | ✓ | ✓ᴾ | `can_read_community` (from `plus`); eigene Beiträge auflisten, zurückziehen und löschen in jedem Tarif |
| Karten aus KI-Antwort (`POST /api/ai/tutor` `mode=flashcards`) | 🔒 403 Pro AI | 🔒 403 Pro AI | ✓ 150/Monat | ✓ᴾ 150/Monat, 25 Credits | `TUTOR_ENTITLEMENT["flashcards"] = can_use_ai_generated_questions` (from `pro_ai`), `consume("ai_assist")` |
| „Karteikarten aus Dokument“ (`POST /api/ai/flashcards`) | 🔒 403 Pro AI | 🔒 403 Pro AI | ✓ 150/Monat | ✓ᴾ | `server.py:1178` `require(can_use_ai_generated_questions)` + E-Mail bestätigt + `ai_assist` |
| KI-Karteikarten auf Auftrag (`POST /api/ai/flashcards` mit `module_id`, Woche, 5–50 Karten) | 🔒 403 Pro AI | 🔒 403 Pro AI | ✓ 150/Monat + Credits | ✓ᴾ | `server.py::_ai_flashcards_order` wie oben; nur Doppel/keine Karten: 502, `ai_assist` zurück |
| Fertige Fragen je Vorlesungswoche (`/api/library/week-sets…`) | 🔒 403 Pro AI | 🔒 403 Pro AI | ✓ (Satz starten: `library_tests`, Fair Use) | ✓ᴾ | `week_library_api.RIGHT = can_use_prepared_week_sets`; Vorarbeit aus dem Bibliotheksbudget |
| Notizen-Abgleich zwischen Geräten (`POST /api/sync/push`, Einträge `annotations`) | 🔒 `plan_required` | 🔒 `plan_required` (Plus gilt je Gerät) | ✓ | ✓ᴾ | `can_sync_annotations` (from `pro_ai`); Pläne und alles andere gleichen in jedem Tarif ab |
| Neue Karten/Stapel im Geräte-Abgleich (`flashcards`, `flashcard_stacks` ohne `id`) | 🔒 `plan_required` | ✓ | ✓ | ✓ᴾ | `can_use_flashcards` in `api_sync_push` |
| Wochentest, Standard geteilt (`/api/weekly/tick` → Job) | 🔒 „Wochentests mit KI gibt es ab StudiNow Plus (dein Tarif: StudiNow Free).“ | 4/Monat (`ai_tests_new`), Übernahme aus dem Pool 0 | 20/Monat | ✓ᴾ 20/Monat | `jobs.HostedQuota.check/consume`, `weekly.py:946–957` (`reuse` kostet nichts) |
| Wochentest, eigener (Dialog, `POST /api/tests/generate`) | 501 für alle | 501 | 501 | 501 | `HOSTED_UNAVAILABLE` |
| Test aus der Bibliothek (`POST /api/library/tests`) | 🔒 403 Plus | 4/Monat (`library_tests`) | unbegrenzt (Fair Use 300) | ✓ᴾ 300 | `library_api.py:115–137` `can_access_shared_tests` |
| Neuer KI-Test für die Bibliothek (ebd., Pool zu klein) | 🔒 | 4/Monat (`ai_tests_new`) | 20/Monat | ✓ᴾ 20 | `library_api.py:116, 159` `can_generate_studora_ai_tests` |
| Test durchführen, abgeben, Ergebnis (`GET /api/tests/{id}`, `POST …/submit`) | ✓ | ✓ | ✓ | ✓ | `server.py:1663–1693`, `library_api.grade_and_store`: kein Gate |
| Testliste (`GET /api/tests`) | letzte 10 | letzte 10 (dokumentiert) | alle | ✓ᴾ alle | `server.py` `HISTORY_BASIC`, `can_use_extended_test_history` (from `pro_ai`) |
| KI-Tutor erklären/Begriffe (`explain`, `terms`) | 🔒 403 Pro AI | 🔒 403 Pro AI | ✓ 150/Monat | ✓ᴾ | `can_use_ai_explanations` |
| KI-Tutor zusammenfassen (`summary`) | 🔒 | 🔒 | ✓ | ✓ᴾ | `can_use_ai_summaries` |
| KI-Tutor ähnliche Aufgaben (`similar`) | 🔒 | 🔒 | ✓ | ✓ᴾ | `can_use_ai_generated_questions` |
| Lernstand je Modul (`mastery` in `GET /api/modules`) | ✓ | ✓ | ✓ | ✓ | `app/mastery.py`: kein Gate |
| Lernstatistik, Wiederholung, Empfehlungen (`/api/learning/*`) | 🔒 403 „ab StudiNow Pro AI“ | 🔒 403 „ab StudiNow Pro AI“ | ✓ (Endpunkt; Oberfläche „kommt bald“) | ✓ᴾ | `library_api.py:306–340` (`from: pro_ai`, `status: coming_soon`) |
| Eigenes ChatGPT verbinden (Soll seit 05.11.2026: jeder Tarif, Fragen zu Folien) | – (Integration `disabled`, „in Vorbereitung“) | – | – | – | `chatgpt_connection_premium` (from `free`), `plans.INTEGRATIONS["chatgpt"]`, nie an den Tarif gekoppelt |

Credits (`app/credits.py`, zusätzlich zu den Kontingenten): Pro AI 100/Monat, Probe 25 (Marke `pro_ai:trial`), Free und
Plus 0 – ein Plus-Konto könnte also selbst bei Rechten keinen StudiNow-KI-Aufruf bezahlen.

## 4. Abweichungen vom Auftrag (04.11.2026) und Vorschläge

| Nr. | Befund | Ort | Vorschlag | Stand |
|---|---|---|---|---|
| 1 | **Eigene Karteikarten sind im Dienst in jedem Tarif frei** (Free kann anlegen, ändern, löschen, üben). Der Auftrag und alle Store-Texte („Mit Plus: eigene Karteikarten“) sehen Plus vor; der Vertrag hat gar kein Recht dafür. Auf dem iPad gilt Plus nur lokal; sobald ein Konto verbunden ist, fällt die Sperre weg. | `app/plans.py` ENTITLEMENTS (kein Schlüssel), `app/server.py` Karteikarten-Routen (`add_flashcards`, `patch_flashcard`, `delete_flashcard`, `review_flashcard`, Stapel-Routen), `CardsPage.swift:364`, `FlashcardComposer.swift:65`, `DocumentView.swift:299` | Recht `can_use_flashcards` (from `plus`, `available`) in `plans.py`, Fixture neu erzeugen (`tools/gen-plans-fixture.py`), `UFEntitlement` + `onDevice: .onDevice([.flashcards])` in `Plans.swift`; im Dienst `entitlements.require(request, "can_use_flashcards")` auf POST/PATCH/DELETE/review und Stapel-Schreibrouten, **GET bleibt frei** (Lesen nach der Probe); Web: Sperrkarte über `can("can_use_flashcards")`. | erledigt 04.11.2026: Recht im Vertrag (Fixture, `UFEntitlement.canUseFlashcards`), 403 auf allen schreibenden/übenden Routen inkl. Teilen, Übernehmen und Wochenstapel; Web-Lesemodus (`flashcards.js::readOnly`); `tests/test_tarif_matrix.py`, `tests/js/flashcards.test.mjs` |
| 2 | **Nach der Probe sind die eigenen Karten auf dem iPad lokal unsichtbar**: `CardsPage` lädt in Free nichts, zeigt nur die Sperrkarte. Notizen haben dagegen einen Lese-Modus (`UFFeatureMatrix.notes`). „Daten bleiben“ heißt beim Nutzer „ich sehe sie noch“. | `CardsPage.swift:364–408`, `FlashcardsAppTests.testFreeShowsTheLockCardAndLoadsNoCards` | Lese-Modus wie bei Notizen: Liste und Stapel sichtbar, Üben/Anlegen/Bearbeiten mit Schloss (`UFNoteAccess`-Muster, z. B. `UFFlashcardAccess(canView: true, canEdit: plan >= .plus)`); Trainer/Review mit `ufRequires(.flashcards)`. Dieselbe Regel in den Store-Text („Karten bleiben lesbar“). | erledigt 04.11.2026: `UFFlashcardAccess`, Lesemodus der `CardsPage` (Hinweis + „Tarife ansehen“, ohne Karten die Sperrkarte), `FlashcardsAppTests`, `PlanMatrixAppTests`; Store-Text noch offen |
| 3 | **„KI erstellt Karteikarten“ ist auf dem iPad eine Plus-Funktion über das eigene ChatGPT**, nicht Pro AI; im Dienst (`POST /api/ai/flashcards`) ist sie Pro AI. Das ist mit der ChatGPT-Regel (nie an den Tarif koppeln, `docs/ABO-SYSTEM.md` 4) vereinbar, steht aber nirgends. | `FlashcardComposer.swift:65`, `server.py:1178`, Tarifkarte Pro AI („Automatische Lernfragen“ in Vorbereitung) | Satz in `docs/ABO-SYSTEM.md` und `docs/release/APP-STORE.md`: „Über das eigene ChatGPT laufen Karteikarten aus Dokument und Wochentests in jedem Tarif, in dem das Speichern erlaubt ist (Karten: Plus); StudiNow-KI ohne eigenes ChatGPT ist Pro AI.“ | erledigt 04.11.2026: Karteikarten und Wochentests über das eigene ChatGPT sind Plus (`docs/ABO-SYSTEM.md` 3b, `docs/PREISLISTE.md`), StudiNow-KI ohne eigenes ChatGPT ist Pro AI |
| 4 | **Wochentest erstellen auf dem iPad lokal: kein Tarif, kein Kontingent** – Free mit eigenem ChatGPT erzeugt beliebig viele Tests (auch Standard-geteilte über CloudKit). Der Auftrag nennt „neue KI-Tests“ ab Plus mit 4/Monat. | `QuizComposer.swift:235`, `UniFlowCore/LocalBackend/Endpoints/TestEndpoints.swift` (kein Kontingent) | Entweder ausdrücklich frei (ChatGPT-Regel, dann Doku) oder `UFFeature.weeklyTests` (Plus) mit `UFLockedCard` im Dialog; ein lokales Monatskontingent wäre neu (Zähler im lokalen Backend, `SettingsEndpoints`). | erledigt 04.11.2026: `UFFeature.weeklyTests` (Plus), Sperrkarte in `QuizComposer`; kein lokales Kontingent. „Woche erzeugen“ („Fehlende Wochentests“) auf `ExamsPage` und automatische Wochentests (`UFWeeklyAutoGate`) ebenfalls ab Plus, erledigt 04.11.2026 (Teil 2); das lokale Backend selbst bleibt ohne Tarif |
| 5 | **„4 / Monat“ stimmt nur für Bibliothekstests**; neue KI-Tests für Plus sind **3** (`QUOTAS["plus"]["ai_tests_new"] = 3`, Tabelle in ABO-SYSTEM.md). Der Auftrag vom 04.11. nennt 4. | `app/plans.py:73`, `docs/ABO-SYSTEM.md:12` | Wert auf 4 setzen, Fixture und `tests/test_subscriptions.py::test_03` (3 Durchläufe) und `test_hosted_sync.py::test_weekly_quota_follows_the_plan` nachziehen – oder den Auftrag auf 3 korrigieren. | erledigt 04.11.2026: Plus 4 neue KI-Tests und 4 Bibliothekstests, Pro AI 20 neue KI-Tests (`QUOTAS`, Fixture, Tests) |
| 6 | **Pro Connect lebt im Dienst weiter**: Lernstatistik, Wiederholung, Empfehlungen und erweiterte Testhistorie hängen an `pro_connect`; Plus bekommt „Diese Funktion gibt es ab StudiNow Pro Connect.“ – einen Tarif, den das iPad nicht verkauft und der im Drei-Tarife-Modell des Inhabers fehlt. Die Web-Aboseite zeigt vier Karten. | `app/plans.py` ORDER/PLANS/ENTITLEMENTS (`from: pro_connect`), `library_api.py:306–340`, `server.py:1616`, `app/static/views-abo.js` | Entscheidung: Pro Connect streichen (Rechte auf `pro_ai`, Rang 2) oder ausdrücklich nur Web/Windows. Bis dahin ist die Matrix ehrlich: Pro AI hat alles aus Pro Connect. | erledigt 04.11.2026: Pro Connect gestrichen, Rechte `from: pro_ai`, Meldung „ab StudiNow Pro AI“, Web zeigt drei Karten, alter Schlüssel gilt wie Pro AI (`LEGACY_PLANS`) |
| 7 | **Testliste nach der Probe**: Free/Plus sehen nur die letzten 10 Tests (`HISTORY_BASIC`), ältere Tests „verschwinden“ aus der Liste, obwohl sie gespeichert bleiben. | `server.py:1616` | Grenze nur für die Statistik, nicht für die Liste; oder Hinweis „ältere Tests ab Pro AI“. | entschieden 04.11.2026: Grenze bleibt und ist dokumentiert (Nutzungsbedingungen 5a, `docs/PREISLISTE.md`, Pro-AI-Karte „Vollständige Testliste (Free und Plus: die letzten 10)“) |
| 8 | **Probe = Pro AI überall?** Ja für Rechte und Kontingente (`billing.current_plan` liefert `pro_ai`, Kontingente 40/300/150), **nein für Credits** (25 statt 100, `credits.TRIAL_ENV`) und für das Erzeugen des Pools (`require_verified_for_ai`: nur mit bestätigter E-Mail). iPad: `UFLocalTrial.plan = .proAI`, lokal derselbe Umfang wie Plus. | `app/credits.py:36–38`, `app/entitlements.py:78` | So gewollt (ABO-SYSTEM.md 6a); in die Tarifseite/Probe-Karte „25 Credits in der Probe“ aufnehmen, damit nichts überrascht. | erledigt 04.11.2026: „alles wie Pro AI, 25 Credits“ auf der Abo-Seite (Web), in der Probe-Karte des Kontos und der Tarifseite mit Pro-AI-Produkt (iPad), `trial.credits` im Vertrag |
| 9 | **Pro-AI-Karte nur mit Dienst**: korrekt umgesetzt (`UFPlanCatalog.needsProduct = [.proAI]`, `cards(current:loaded:)`), Hinweis „StudiNow Pro AI folgt mit dem StudiNow-Dienst.“ ohne Preis. Wer Pro AI im Store kauft, bevor der Dienst läuft, hat auf dem iPad Plus-Umfang – die Karte sagt es (`proAIServiceNote`). | `Plans.swift:100–128`, `PlanContractTests.testIPadSellsFreePlusAndProAI` | nichts | ✓ |
| 10 | **Store-/Rechtstexte** nennen Karteikarten nur für Plus und keine KI-Zeile; `docs/release/NUTZUNGSBEDINGUNGEN.md` kennt nur Free und Plus (Abschnitt 5 „StudiNow Plus (Abo)“), obwohl die App Pro AI anbietet, sobald das Produkt da ist. Die Prüftabelle in `docs/release/APP-STORE.md` sagte noch „Nur StudiNow Free und Plus“. | `docs/release/NUTZUNGSBEDINGUNGEN.md:19–30, 59–70`, `docs/release/APP-STORE.md:19` | Absatz „StudiNow Pro AI“ (Preis, Dienst, Credits/Kontingente, Kündigung) vor dem Einreichen des Pro-AI-Produkts ergänzen. | erledigt 04.11.2026: Nutzungsbedingungen Abschnitt 5 (Probe, Plus, Pro AI mit Credits) und 5a (Grenzen je Tarif) |
| 11 | **Lernstatistik = Pro AI** laut Auftrag; „Lernstand je Modul“ (Wochentests, Karteikarten, Aufgaben) ist auf iPad und Web in jedem Tarif frei. Beides heißt in Texten „Lernstand/Lernstatistik“. | `LernstandView.swift`, `app/mastery.py` | Begriffe trennen: „Lernstand“ (frei, aus eigenen Daten) vs. „Erweiterte Lernstatistiken“ (Dienst, Pro AI). | erledigt 04.11.2026: „Lernstand“ (frei, je Modul) vs. „Lernstatistik“ (Pro AI, `/api/learning/*`, Oberfläche „kommt bald“, nirgends als enthalten beworben) |

## 5. Tests, die die Matrix pinnen

- `tests/test_tarif_matrix.py` (Dienst): Rechte und Kontingente je Tarif, Karteikarten ab Plus (jede schreibende Route,
  Lesen frei), Wochenstapel übernehmen ab Plus ohne E-Mail / erzeugen ab Pro AI, Probe → Free mit lesbaren
  Daten, KI-Sperren mit Meldungen (403/429/E-Mail), Bibliothek 4/Monat, Wochentest-Kontingent, 501 für
  `POST /api/tests/generate`, Testliste 10, Lernstatistik ab Pro AI (alte `pro_connect`-Zeile gilt wie Pro AI).
- `apps/apple/UniFlowTests/PlanMatrixAppTests.swift` (iPad): Vorrang Dienst/App Store/Probe, `Entitlements` mit Probe und
  Startargument, Funktionsmatrix (`flashcards`, `weeklyTests` am Tarif, `UFFlashcardAccess`), Tarifkarten, Kostenzeilen,
  `CardsPage` lokal im Lesemodus (Free, nach der Probe) vs. voll (Plus, Probe) vs. mit Dienst offen, `FlashcardComposer`,
  `QuizComposer` und `ExamsPage` lokal ab Plus, Probe-Karte und Tarifseite. `FlashcardsAppTests`: Free liest, Free ohne
  Karten Sperrkarte, Probe voll und danach lesen. `WeeklyAppTests`: automatische Wochentests nur mit Plus.
- Kern (`UniFlowCore`): **bewusst kein Tarif, keine Kontingente** (das lokale Backend antwortet jedem; gesperrt wird in
  der App-Oberfläche) – nichts zu pinnen; `swift test --filter "Plan|Entitlement|Flashcard"` läuft die Vertrags-,
  Plan-Namen- und Karteikarten-Tests des Pakets.

# StudiNow-Preisliste (Entscheidung des Inhabers vom 04.11.2026)

Drei Tarife, Monatspreise inkl. USt. **Quelle aller Werte: `app/plans.py`** (`PLANS`, `QUOTAS`, `FAIR_USE`, `CREDITS`,
`TRIAL`); `tools/gen-plans-fixture.py` schreibt daraus `packages/shared-contracts/fixtures/plans/plans.json`, gegen die
Swift (`PlanContractTests`) und der Dienst (`tests/test_subscriptions.py`, `tests/test_tarif_matrix.py`) prüfen.
Ausführlich: `docs/ABO-SYSTEM.md`; Stand des Codes je Funktion: `docs/TARIF-MATRIX-2026-11-04.md`.

| | StudiNow Free | StudiNow Plus | StudiNow Pro AI |
|---|:---:|:---:|:---:|
| Preis | 0,00 € | 1,99 € | 3,99 € |
| Apple-Produkt | – | `de.uniflow.plus.monthly` | `de.uniflow.proai.monthly` (erst mit dem StudiNow-Dienst im Store) |
| PDF bearbeiten, Apple Pencil, Notizen auf allen Geräten | – | ✓ | ✓ |
| Eigene Karteikarten mit Wiederholung (`can_use_flashcards`; Free: vorhandene Karten lesen) | – | ✓ | ✓ |
| Wochentest erstellen (iPad ohne Dienst: über das eigene ChatGPT) | – | ✓ | ✓ |
| Lösungen teilen, Community schreiben (lesen: alle) | – | ✓ | ✓ |
| Lernstand je Modul | ✓ | ✓ | ✓ |
| Neue KI-Tests von StudiNow im Dienst (`ai_tests_new`) | 0 | 4 / Monat | 20 / Monat |
| Tests aus der Testbibliothek im Dienst (`library_tests`) | 0 | 4 / Monat | unbegrenzt (Fair Use 300) |
| KI-Erklärungen, Lernfragen, Zusammenfassungen im Dienst (`ai_assist`) | 0 | 0 | 150 / Monat |
| Credits für die StudiNow-KI (1 Credit = 1 Cent Kosten beim Anbieter) | 0 | 0 | 100 / Monat |
| Testliste im Dienst (`GET /api/tests`) | letzte 10 | letzte 10 | alle |

**Probe:** jedes neue Konto bzw. jede Apple-ID einmal 7 Tage, alles wie Pro AI, mit 25 Credits (nur mit
StudiNow-Konto; auf dem iPad ohne Dienst heißt „wie Pro AI“ heute der Umfang von Plus). Danach Free, Daten bleiben;
nie automatisch kostenpflichtig. Texte: Web `app/static/views-abo.js` („Probe: alles wie StudiNow Pro AI, mit 25
Credits …“), iPad `UFTrialTexts.offerProAI` bzw. `runningTextService` (nur mit Dienst; ohne Dienst nennt das iPad Pro AI
nicht, weil es die Karte nicht gibt).

**Testliste:** Free und Plus sehen im Dienst die letzten 10 Tests (`app/server.py`, `HISTORY_BASIC`); ältere Tests
bleiben gespeichert und zählen weiter für den Lernstand. Entschieden am 04.11.2026: die Grenze bleibt und steht in den
Nutzungsbedingungen (Abschnitt 5a) und als Zeile „Vollständige Testliste (Free und Plus: die letzten 10)“ auf der
Pro-AI-Karte. Auf dem iPad ohne Dienst gibt es keine Grenze.

**Begriffe:** „Lernstand“ ist die Zahl je Modul aus den eigenen Wochentests, Karteikarten und Aufgaben
(`app/mastery.py`, `Mastery.swift`) und in jedem Tarif frei. „Lernstatistik“ ist die modulübergreifende Auswertung
des Dienstes (`/api/learning/stats`, `…/review`, `…/recommendations`) ab Pro AI; die Endpunkte gibt es, eine
Oberfläche noch nicht, darum steht sie auf der Karte als „kommt bald“ und wird nirgends als enthalten beworben.
Dasselbe gilt für „KI-gestützte Lernempfehlungen“ (noch kein Endpunkt).

**Pro Connect** (2,99 €, Auftrag vom 27.10.2026) gibt es nicht mehr. Der Schlüssel `pro_connect` bleibt nur lesbar
für alte Zeilen und gilt wie Pro AI (`plans.LEGACY_PLANS`, `billing.normalize_plan`, Swift `UFPlan(rawValue:)` und
`UFPlan(productID:)`); er ist nicht kaufbar (`plans.is_sellable`, Stripe-Preise, `POST /api/billing/plan-choice`) und
erscheint auf keiner Karte. Alles, was an Pro Connect hing (Lernstatistik, Wiederholung, Empfehlungen, Testliste,
Anzeige der ChatGPT-Verbindung), hängt jetzt an Pro AI; die Meldung ohne Recht heißt „Diese Funktion gibt es ab
StudiNow Pro AI.“

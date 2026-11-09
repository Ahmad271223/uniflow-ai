# StudiNow-Preisliste (Entscheidung des Inhabers vom 04.11.2026, angeglichen am 05.11., 07.11. und 09.11.2026)

Drei Tarife, Preise inkl. USt. **Seit 09.11.2026 nur noch Jahresabos** (Entscheidung des Inhabers, abends: „Monatliche
Abos komplett entfernen. Nur 19,99 und 39,99.“, `docs/release/ABO-NUR-JAHR-2026-11-09.md`); Kontingente und Credits
gelten weiter je Kalendermonat. **Quelle aller Werte: `app/plans.py`** (`PLANS`, `QUOTAS`, `FAIR_USE`, `CREDITS`,
`TRIAL`); `tools/gen-plans-fixture.py` schreibt daraus `packages/shared-contracts/fixtures/plans/plans.json`, gegen die
Swift (`PlanContractTests`) und der Dienst (`tests/test_subscriptions.py`, `tests/test_tarif_matrix.py`) prüfen.
Jeder Tarif enthält alles aus dem Tarif darunter. **Keine Einführungsangebote** (weder bei Apple noch bei Stripe,
Entscheidung vom 04.11.2026): Plus und Pro AI kosten ab dem ersten Tag den Preis oben; getestet wird mit der Probe (unten).
Ausführlich: `docs/ABO-SYSTEM.md`; Stand des Codes je Funktion:
`docs/TARIF-MATRIX-2026-11-04.md`; Entscheidungen im Wortlaut: `docs/ENTSCHEIDUNGEN-INHABER-2026-11-04.md` und
`docs/ENTSCHEIDUNGEN-INHABER-2026-11-05.md` (Free ohne Community und ohne KI-Hilfe, eigenes ChatGPT in jedem Tarif,
Karteikarten-Stapel von StudiNow für Plus begrenzt).

| | StudiNow Free | StudiNow Plus | StudiNow Pro AI |
|---|:---:|:---:|:---:|
| Preis (Jahresabo, `price_cents`, `period` „year“) | 0,00 € | 19,99 € / Jahr (entspricht 1,67 € im Monat) | 39,99 € / Jahr (entspricht 3,33 € im Monat) |
| Apple-Produkt | – | `de.uniflow.plus.yearly` | `de.uniflow.proai.yearly` (Dienst `app.studinow.app` läuft) |
| PDFs lesen, Kurse, Abgleich mit Stud.IP/Learnweb, Stundenplan, Lernkalender | ✓ | ✓ | ✓ |
| Eigenes ChatGPT über den eigenen OpenAI-API-Schlüssel (`chatgpt_connection_premium`, `available` seit 07.11.2026; iPad: Einstellungen → Erweitert → „Eigenes ChatGPT“): KI-Hilfe zu den Unterlagen und KI-Lernplan in jedem Tarif, nie an den Tarif gekoppelt ² | ✓ | ✓ | ✓ |
| Community lesen, beitreten und mitmachen (`can_read_community`, seit 05.11.2026 ab Plus) | – | ✓ | ✓ |
| PDF bearbeiten, Stift, Textmarker, Apple Pencil (je Gerät) | – | ✓ | ✓ |
| **Notizen auf allen Geräten** (Abgleich zwischen iPad, PC und Web, `can_sync_annotations`) | – | – (Plus gilt je Gerät) | ✓ |
| Eigene Karteikarten mit Wiederholung, Stapel (`can_use_flashcards`; Free: vorhandene Karten lesen) | – | ✓ | ✓ |
| Karteikarten-Stapel teilen und die anderer übernehmen (je Lernwoche oder „Allgemein“, 0 Credits) | – | ✓ | ✓ |
| Wochenstapel „Karten für Woche n holen“ übernehmen (fertiger Satz aus dem Pool, 0 Credits) | – | ✓ | ✓ |
| Karteikarten-Stapel von StudiNow übernehmen (Wochenstapel und geteilte Stapel, `card_stacks_adopted`; derselbe Stapel zählt im Monat einmal) | 0 | 4 / Monat | unbegrenzt (Fair Use 300) |
| Wochentest erstellen auf dem iPad (`UFFeature.weeklyTests`; mit der StudiNow-KI oder dem eigenen OpenAI-Schlüssel) | – | – | ✓ |
| Lösungen teilen, Community schreiben | – | ✓ | ✓ |
| Lernstand je Modul | ✓ | ✓ | ✓ |
| Neue KI-Tests von StudiNow im Dienst (`ai_tests_new`) | 0 | 4 / Monat | 20 / Monat |
| Tests aus der Testbibliothek im Dienst (`library_tests`) | 0 | 4 / Monat | unbegrenzt (Fair Use 300) |
| **KI erstellt Karteikarten** auf Auftrag („Analysis I, Lernwoche 5, 30 Karten“) und „Karteikarten aus Dokument“ im Dienst | – | – | ✓ ¹ |
| **Fertige Fragen zu jeder Vorlesungswoche** (2–3 Sätze à 15 Fragen, Lösungen und Erklärungen schon da, `can_use_prepared_week_sets`) | – | – | ✓ |
| KI-Erklärungen, Lernfragen, Zusammenfassungen im Dienst (`ai_assist`) | 0 | 0 | 150 / Monat |
| Credits für die StudiNow-KI (1 Credit = 0,9 Cent Kosten beim Anbieter (100 Credits = höchstens 0,90 €)) | 0 | 0 | 100 / Monat |
| Testliste im Dienst (`GET /api/tests`) | letzte 10 | letzte 10 | alle |

¹ Zählt auf `ai_assist` (150 / Monat) und kostet Credits; bestätigte E-Mail nötig.

² Stand des Codes 07.11.2026 (`UFFeatureMatrix` in `apps/apple/UniFlow/Purchases/Entitlements.swift`,
`OpenAIKeyCard.introText`): Mit dem eigenen OpenAI-Schlüssel laufen die KI-Hilfe im Editor und der KI-Lernplan
(Vorschlag, erst „übernehmen“ trägt ein) in **jedem** Tarif, auch Free; „Karteikarten aus deinen Unterlagen“ ab Plus
(Speichern eigener Karten ist Plus); Wochentests ab Pro AI. Der Schlüssel liegt nur im Schlüsselbund des iPads, die
Anfragen gehen direkt an OpenAI und laufen über das OpenAI-Konto des Nutzers, nie über uns. Die offizielle Anmeldung
„Mit ChatGPT anmelden“ bleibt aus, bis OpenAI sie freigibt (`plans.INTEGRATIONS["chatgpt"]`, `docs/ABO-SYSTEM.md` 4).

**Plus gilt je Gerät** (Entscheidung vom 04.11.2026): Das Abo schaltet auf jedem Gerät mit derselben Apple-ID frei
(„Käufe wiederherstellen“), aber Notizen wandern erst mit Pro AI zwischen iPad, PC und Web (`POST /api/sync/push`
meldet für Plus `plan_required` mit `required_plan: pro_ai` für genau die Einträge `annotations`; Pläne, Module,
Karteikarten und alles andere gleichen weiter ab). Wer nur im Browser arbeitet, hat seine Notizen im Dienst und sieht
sie in jedem Browser, in dem er angemeldet ist.

**Probe:** 7 Tage alles wie Pro AI, ohne Kauf und ohne Zahlungsdaten (`plans.TRIAL`, `UFLocalTrial.plan = .proAI`),
höchstens einmal je Apple-ID **und einmal je iPad** (Geräte-Marke im Schlüsselbund, übersteht die Neuinstallation; eine
weitere Apple-ID auf demselben iPad sieht „Auf diesem iPad wurde die Probe schon genutzt“). Die StudiNow-KI braucht auch
in der Probe ein StudiNow-Konto (neue Konten: 25 Credits). **Nach der Probe** zeigt das iPad den Bildschirm „Deine Probe
ist vorbei“ mit Free, Plus und Pro AI (Monatlich/Jährlich), der sich erst mit einer Wahl schließt; „Bei Free bleiben“ ist
eine gültige Wahl ohne Kauf (`TrialBanner.swift`, `UFTrialTexts.stayFree`). Daten bleiben; nie automatisch
kostenpflichtig; es gibt keine „1 Woche gratis“ bei Plus. Texte: Web `app/static/views-abo.js` („Probe: alles wie StudiNow Pro AI, mit 25
Credits …“), iPad `UFTrialTexts.offerProAI` bzw. `runningTextService` (sobald StoreKit Pro AI liefert, in 1.0 der Normalfall),
`UFTrialTexts.overTitle` / `overText` und `UFTrialDecision` (Bildschirm nach der Probe, je Apple-ID einmal beantwortet;
eine weitere Apple-ID ohne eigene Probe bekommt beim ersten Start gleich die Tarifwahl).

**Free gilt nur noch in der iPad-App (Entscheidung vom 05.11.2026, „anmelden immer muss ohne abo geht nichts“):** In
der Web-App des Dienstes und in der Windows-App ist die Anmeldung mit dem StudiNow-Konto Pflicht; nach der Probe geht
dort ohne Plus oder Pro AI nichts außer der Abo-Seite und den eigenen Daten zum Ansehen und Exportieren (nur lesen,
Daten bleiben). Ein Abo gilt auf allen Geräten desselben Kontos (Apple-Abo vom iPad auch im Web und unter Windows).
Abschluss im Web und unter Windows über Stripe (unter Windows im Systembrowser), auf dem iPad über den App Store; ein
zweites Abo über Stripe neben einem Apple-Abo ist gesperrt. Ausführlich: `docs/ABO-SYSTEM.md` Abschnitt 3d.

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

## So funktioniert die KI in Pro AI

1. **Die Bibliothek arbeitet vor** (`docs/BIBLIOTHEK-WOCHENFRAGEN.md`). Je Vorlesungswoche kennt die StudiNow-KI die
   Themen, Hinweise aus Ankündigungen und die Aufgaben der Übungsblätter und erarbeitet die Lösungen samt Erklärung –
   **einmal je Inhalt** (gleiche PDF = gleiche Arbeit) für alle Pro-AI-Nutzer, aus einem eigenen Budget
   (`LERNAPP_AI_LIBRARY_BUDGET_EUR`), das weder das Budget der Konten noch deren Kontingente belastet.
2. **Fertige Fragen je Woche:** 2–3 Sätze à 15 Fragen. Pro AI öffnet sie ohne ein Test-Kontingent für neue KI-Tests.
   Nur wer eine Woche als Erster öffnet, wartet einmal ein bis zwei Minuten, danach ist sie für alle sofort da.
3. **Karteikarten auf Auftrag:** „Analysis I, Lernwoche 5, 30 Karten“ (5–50, optional Schwerpunkt) – die KI nimmt das
   Material genau dieser Woche, Karten, die man im Modul schon hat, kommen nicht doppelt. Vorschau mit Haken, dann in
   einen Stapel des Moduls („KI · Woche 5“), danach bearbeiten, üben, teilen (`app/flashcard_order.py`).
4. **Wochenstapel für alle:** „Karten für Woche n holen“ erzeugt je Modul, Woche und Art (Vorlesung/Übung) höchstens
   drei Sätze für alle mit denselben Dateien (`app/cardshare.py`); Plus übernimmt fertige Sätze für 0 Credits, nur das
   Erzeugen eines neuen Satzes ist StudiNow-KI (Pro AI).
5. **Teilen:** Karteikarten-Stapel gibt es je Vorlesungswoche oder „Allgemein“ in der Community des Moduls (nur für
   Mitglieder), mit Pseudonym; Plus kann sie übernehmen, der Autor kann die geteilte Kopie aktualisieren oder
   zurückziehen (`app/community_cards.py`, `docs/KARTEIKARTEN-STAPEL-2026-11-04.md`).

Damit es bezahlbar bleibt, entstehen Wochenfragen und Lösungen **erst, wenn der erste Pro-AI-Nutzer die Woche öffnet**,
und werden dann für alle gespeichert. Kosten grob: 1–4 Cent je Fragensatz einmalig (je nach Modell); bei 1.000 aktiven
Modulen × 14 Wochen × 3 Sätzen also etwa 400–1.700 € pro Semester, verteilt auf alle Pro-AI-Kunden (Schätzung, siehe
`docs/SKALIERUNG-GROSS.md`).

## Was ankommt (je Kunde und Jahr, geschätzt)

| | Plus 19,99 € / Jahr | Pro AI 39,99 € / Jahr |
| --- | --- | --- |
| nach 19 % MwSt | 16,80 € | 33,61 € |
| nach Apple (15 %) | **14,28 €** | **28,57 €** |
| nach Stripe (Web, ca. 1,5 % + 0,25 €) | **16,25 €** | **32,76 €** |
| KI-Kosten | 0 € (eigenes ChatGPT) | höchstens 10,80 € (12 × 100 Credits à 0,9 Cent), dazu der Anteil an der Bibliothek |

## Wo was heute steht

| Teil | Stand |
| --- | --- |
| Tarife, Kontingente (Plus 4, Pro AI 20), Notizen-Abgleich erst mit Pro AI | umgestellt in `app/plans.py`, Prüfdaten und iPad (`Plans.swift`, `PlanContractTests`) |
| Community ab Plus, eigenes ChatGPT in jedem Tarif, Stapel-Kontingent `card_stacks_adopted` (05.11.2026) | umgestellt in `app/plans.py` und Prüfdaten; Dienst, Web/Windows und iPad ziehen nach (`docs/TARIF-MATRIX-2026-11-04.md`, Nachtrag 05.11.2026) |
| Karteikarten mit Stapeln (Woche, Art), Bearbeiten, geschlossenes Üben | gebaut (iPad, Web, Windows, Dienst); im Dienst nur mit Plus (`can_use_flashcards`, auch neue Karten und Stapel beim Geräte-Abgleich) |
| Stapel teilen, übernehmen, geteilte Kopie aktualisieren, Moderation | gebaut im Dienst, Web (Seite „Karteikarten“ und Reiter „Karteikarten“ im Community-Kanal) und iPad (CloudKit); Ersetzen und Moderation nur im Dienst |
| KI-Karteikarten auf Auftrag (Modul, Woche, Anzahl) | gebaut im Dienst und Web/Windows (`POST /api/ai/flashcards` mit `module_id`); iPad: noch nicht (dort „Karteikarten aus Dokument“ mit der StudiNow-KI ab Pro AI oder mit dem eigenen OpenAI-Schlüssel ab Plus) |
| Fertige Wochenfragen mit Erklärungen | gebaut im Dienst und Web/Windows (`docs/BIBLIOTHEK-WOCHENFRAGEN.md`); iPad: nur im Vertrag („in Vorbereitung“) |
| Pro AI im App Store | mit Version 1.0 (Entscheidung 07.11.2026, Dienst `app.studinow.app` läuft), seit 09.11.2026 nur als Jahresabo; liefert StoreKit das Produkt nicht, steht auf der iPad-Tarifseite „StudiNow Pro AI konnte gerade nicht aus dem App Store geladen werden …“ (`Plans.swift`, `proAIMissingNote`) |
| Tarifseite Web (Dienst) | drei Karten aus `GET /api/billing/plans`; „Abschließen“ (Stripe) nur an Plus und Pro AI, nie an Free; in der Probe trägt Pro AI „Probe läuft“ statt „Dein Tarif“ und bleibt kaufbar; nach der Probe ohne Abo „Kein aktives Abo“ mit „Meine Daten ansehen“ und „Meine Daten exportieren“, kein „Bei Free bleiben“ (`app/static/views-abo.js`, `tests/test_web_abo.py`) |
| Tarifseite Windows-App (seit 05.11.2026 mit Konto-Pflicht) | wie im Web: drei Karten, „Abschließen“ öffnet die Stripe-Bezahlseite des Dienstes im Systembrowser, „Abo verwalten“ das Kundenportal; mit Apple-Abo am Konto kein Kaufknopf, sondern „Du hast schon ein Abo über Apple – verwalten in den Einstellungen deines iPads/iPhones“ (`app/account_mode.py`, `app/static/views-abo.js`) |
| Tarifseite Einzelplatz ohne Konto-Pflicht (`serve.py`, Entwicklung) | drei Karten ohne jeden Kaufweg; Pro AI ohne Preis als „kommt mit dem StudiNow-Dienst“ |
| Einladungen („Freunde einladen“) | Dienst gebaut (`app/invites.py`, `docs/EINLADUNGEN.md`), Belohnung als Apple-Angebotscode: Plus 1/3/12 Monate gratis oder Pro AI 12 Monate zum Plus-Preis; Oberfläche nur auf dem iPad, Web/Windows bewusst nicht (`docs/EINLADUNGEN.md` Abschnitt 9) |

# Nur noch Jahresabos: StudiNow Plus 19,99 € und Pro AI 39,99 € (09.11.2026)

**Entscheidung des Inhabers vom 09.11.2026, abends:** „Monatliche Abos komplett entfernen. Nur 19,99 und 39,99.“

Es gibt nur noch zwei Abos:

| Tarif | Apple-Produkt | Preis | Stufe in der Gruppe „StudiNow“ |
|---|---|---|---|
| StudiNow Plus | `de.uniflow.plus.yearly` | 19,99 € pro Jahr (entspricht 1,67 € im Monat) | 2 |
| StudiNow Pro AI | `de.uniflow.proai.yearly` | 39,99 € pro Jahr (entspricht 3,33 € im Monat) | 1 (höchste) |

Unverändert: StudiNow Free (kostenlos, ohne Abo), 7 Tage Probe mit allem wie Pro AI (25 Credits mit StudiNow-Konto),
Pro AI 100 Credits je Kalendermonat (auch beim Jahresabo), Plus 0 Credits, Kontingente je Kalendermonat, kein
Apple-Einführungsangebot.

Die früheren Monatsabos `de.uniflow.plus.monthly` (1,99 €) und `de.uniflow.proai.monthly` (3,99 €) sind in App Store
Connect genehmigt und lassen sich nicht löschen; der Inhaber nimmt sie aus dem Verkauf (Klickliste unten). App und Dienst
erkennen sie weiter als gültigen Kauf ihres Tarifs (z. B. ein alter Sandbox-/TestFlight-Kauf), bieten sie aber nirgends
mehr an und nennen sie in keinem Text.

Grundlage: Build 28 (Commit `7d1a8fb3`) plus die Credit-Text-Korrektur (0,9 Cent, drei Commits von `develop`) plus diese
Änderung. Für das iPad-Release Build 30; die Build-Nummer setzt der Koordinator, nicht dieser Zweig.

## Was sich geändert hat

### iPad/Mac-App (`apps/apple/UniFlow`)

- `Purchases/Plans.swift`: `UFPlan.productID` ist das Jahresabo; `UFPlanCatalog.sellableProductIDs` =
  `de.uniflow.plus.yearly`, `de.uniflow.proai.yearly` (das lädt `PurchaseStore`). `UFBilling.offered = .yearly`.
  `UFPlan.productIDs` und `UFPlan(productID:)` kennen weiter beide Produkte je Tarif (früherer Kauf gilt), die
  Pro-AI-Karte erscheint aber nur mit dem Jahresprodukt. Listenpreise für den Vertragsvergleich 1999/3999 Cent.
- `Purchases/PurchaseStore.swift`: `product(for:)` liefert das Jahresabo; `offersYearly`, die Ersparnis
  („% günstiger als monatlich“) und der Umschalter-Text sind weg. Neu: `UFOfferText.yearlyNote(perMonth:)` =
  „entspricht 1,67 € im Monat“ (Jahrespreis aus StoreKit durch 12), Kündigungszeile beim Jahresabo „verlängert sich
  jährlich, jederzeit zum Laufzeitende kündbar“.
- `Views/Onboarding/PlanPickerView.swift`: kein Umschalter „Monatlich · Jährlich“ mehr, die Karten zeigen
  „19,99 €/Jahr“, „entspricht … im Monat“ und den Kaufknopf „StudiNow Plus für 19,99 €/Jahr“. Pflichttext: „Die Abos
  sind Jahresabos und verlängern sich automatisch um ein Jahr, wenn sie nicht spätestens 24 Stunden vor Ablauf gekündigt
  werden. Kündigen kannst du jederzeit unter „Abo verwalten“ oder in den Einstellungen deiner Apple-ID; der Zugang bleibt
  bis zum Ende des bezahlten Jahres.“ Läuft noch ein früheres Monatsabo (nur Sandbox/Test), bietet die Karte des
  Tarifs „Zum Jahresabo wechseln“ an (Apple stellt zur nächsten Verlängerung um).
- Dieselbe Seite dient beim ersten Start, nach der Probe („Deine Probe ist vorbei“), in den Einstellungen („Tarif
  wechseln“, „Abo verwalten“) und hinter gesperrten Funktionen – alle zeigen nur noch die Jahresabos.
- StoreKit-Testkonfigurationen `UniFlowTests/UniFlow.storekit` und `UniFlowAlleTarife.storekit`: nur noch die zwei
  Jahresabos, 19.99 und 39.99.
- Kern (`UniFlowCore/Account/InviteRewards.swift`): Einladungsbelohnung „12 Monate StudiNow Pro AI zum Plus-Preis
  (19,99 € statt 39,99 €)“.

### Dienst, Web, Windows (`app/`, `packages/shared-contracts`)

- `app/plans.py`: `price_cents` 1999/3999 mit `period` „year“, `apple_product_id` = Jahresabo; die Felder
  `price_cents_yearly`/`apple_product_id_yearly` entfallen. Neu `LEGACY_PRODUCTS` (beide Monatsabos und das frühere
  Pro Connect): `plan_for_product` ordnet sie weiter ihrem Tarif zu, damit `POST /api/billing/apple/verify` und die
  App-Store-Mitteilungen alte Käufe annehmen. Im Vertrag (`GET /api/billing/plans`, `plans.json`) stehen sie nicht.
- `app/invites.py`: Angebotscodes gehören zu den Jahresabos (`apple_product_id` jährlich), Text Pro AI „19,99 € statt
  39,99 €“; `packages/shared-contracts/fixtures/invites/cases.json` gleich.
- `app/static/views-abo.js` (Web und Windows): Tarifkarte „19,99 € / Jahr“, kein „/ Monat“, kein „oder … / Jahr“.
- `app/stripe_billing.py`, `deploy/.env.example`: Stripe-Preise sind Jahrespreise (19,99 / 39,99 €); die Preise
  selbst legt der Inhaber im Stripe-Dashboard an (`LERNAPP_STRIPE_PRICES`).
- `packages/shared-contracts/fixtures/plans/plans.json` neu erzeugt (`tools/gen-plans-fixture.py`).

### Texte

- `docs/release/NUTZUNGSBEDINGUNGEN.md` (Stand 09.11.2026): Plus und Pro AI sind Jahresabos (19,99 € bzw. 39,99 € pro
  Jahr inkl. USt, „Monatsabos bieten wir nicht an“); der Preis wird für ein Jahr im Voraus berechnet, das Abo verlängert
  sich automatisch um ein Jahr, wenn es nicht spätestens 24 Stunden vor Ablauf des laufenden Jahres gekündigt wird;
  nach einer Kündigung bleibt der Tarif bis zum Ende des bezahlten Jahres; Kündigung in den Abo-Einstellungen des
  Apple- bzw. Google-Kontos. Credits weiter je Kalendermonat „auch beim Jahresabo“. Vor der Veröffentlichung
  anwaltlich prüfen (wie der ganze Entwurf).
- `docs/release/APP-STORE.md`: Beschreibungen („StudiNow Plus (19,99 €/Jahr)“, „StudiNow Pro AI (39,99 €/Jahr)“,
  „verlängert sich automatisch um ein Jahr“), Prüfhinweise (yearly only, kein Umschalter), Abschnitt In-App-Käufe nur
  mit den Jahresabos und einem Absatz zu den früheren Monatsabos; Zeichenzahlen neu gezählt.
- `docs/release/STARTSEITE.md` → `site/index.html`, `docs/release/EINLADUNG.md` → `site/i/index.html`,
  `docs/release/NUTZUNGSBEDINGUNGEN.md` → `site/nutzungsbedingungen.html`: mit `tools/gen-site.py` neu erzeugt.
  **Nicht hochgeladen** (Upload später mit `tools/site-hochladen.sh`, nur auf Anweisung des Inhabers).
- `docs/release/TESTFLIGHT-500-2026-11-08.md` (Sandbox: Jahresabo = 1 Stunde, Store-Preise 19,99/39,99 €),
  `docs/release/PLAY-STORE.md`, `docs/release/SCREENSHOTS.md`, `docs/PREISLISTE.md` (inkl. „Was ankommt“ je Jahr),
  `docs/ABO-SYSTEM.md`, `docs/TARIF-MATRIX-2026-11-04.md`, `docs/EINLADUNGEN.md`, `docs/OFFEN-V1.md`,
  `docs/ANLEITUNG-INHABER.md`, `docs/START-DIENST-CHECKLISTE.md`, `README.md`, `RELEASE-READINESS.md`.
- Die Datenschutzerklärung nennt keine Preise und kein „monatlich kündbar“: unverändert.
- Ältere Entscheidungs-, Audit- und Übergabedokumente bleiben als Protokoll unverändert (sie beschreiben den Stand ihres
  Datums).

## Tests

Rot zuerst (Commit „Test zuerst (rot)“): `tests/test_abo_nur_jahr_2026_11_09.py` (Vertrag, alte Monatsprodukte gelten
weiter, Einladungen, Web-Karte, öffentliche Texte, Nutzungsbedingungen, App-Store-Texte, Swift-Quellen und
StoreKit-Konfiguration) und `apps/apple/UniFlowTests/AboNurJahrAppTests.swift` (angebotene Produkte, alte
Monatsprodukte, Angebotstexte, StoreKit lädt nur 19,99/39,99, Kauf Plus jährlich, Tarifseite ohne Umschalter und
ohne „monatlich“) sowie `PlanContractTests` (Vertrag ohne Monatsprodukt, StoreKit nur P1Y). Bestehende Tests mit
Monatspreisen oder Monatsprodukten nachgezogen (`EntitlementTests`, `PurchaseTests`, `PurchaseV2PlanSwitchTests`,
`StoreScreenshot*`, `Abnahme*`, `PlanMatrixAppTests`, `KIAbnahmeLUHAppTests`, `InviteAppTests`, `StudoraNameTests`,
Python `test_subscriptions`, `test_site`, `test_invites`, `test_rechtstexte`, `test_release_texts`, `test_web_abo`).

Der Prüf-Screenshot für App Store Connect (`StoreScreenshotFinalTests.testTarifPruefung`, Ordner
`~/Studora-Builds/appstore-pruefung/`) muss mit dem neuen Build neu aufgenommen werden; das frühere Bild
`tarif-jahr-*.png` (Umschalter „Jährlich“) entfällt.

## Klickliste für den Inhaber in App Store Connect

Nur der Inhaber ändert App Store Connect. Reihenfolge so lassen; nichts davon braucht einen neuen Build.

**(a) Beide Monatsabos aus dem Verkauf nehmen**

1. App Store Connect → Apps → **StudiNow** → links unter „Monetarisierung“ **Abonnements** → Gruppe **StudiNow**.
2. **StudiNow Plus (monatlich)** (`de.uniflow.plus.monthly`) öffnen.
3. Abschnitt **Verfügbarkeit** → **Verfügbarkeit bearbeiten** (bzw. „Länder oder Regionen verwalten“) → alle Länder
   und Regionen abwählen → **Sichern**. Erscheint stattdessen oben rechts der Knopf **„Aus dem Verkauf entfernen“**
   (Remove from Sale), diesen nehmen und bestätigen.
4. Dasselbe für **StudiNow Pro AI (monatlich)** (`de.uniflow.proai.monthly`).
5. Kontrolle: in der Gruppenliste stehen beide Monatsabos mit Status „Aus dem Verkauf entfernt“ bzw. ohne Länder; die
   Jahresabos stehen weiter mit allen Ländern. Löschen geht nicht (genehmigt) und ist nicht nötig.
6. Ist Build 25 oder ein späterer Build noch „In Prüfung“ mit den Monatsabos verknüpft: auf der Versionsseite (iOS-App →
   Version 1.0 → **In-App-Käufe und Abonnements**) die beiden Monatsabos entfernen, sodass nur die zwei Jahresabos mit
   der Version eingereicht sind. Ist die Version schon in Prüfung, gilt das für die nächste Einreichung (Build 30).

**(b) Jahrespreise setzen: Plus 19,99 €, Pro AI 39,99 €**

1. Gruppe **StudiNow** → **StudiNow Plus (jährlich)** (`de.uniflow.plus.yearly`) → Abschnitt **Abonnementpreise** →
   **Abonnementpreis hinzufügen** bzw. **Preis bearbeiten** (+).
2. Land/Region als Basis: **Deutschland (EUR)**, Preis **19,99 €** wählen → **Weiter**.
3. Die Liste der anderen Länder zeigt die von Apple **automatisch angepassten Preise** (aus dem deutschen Preis
   berechnet) – nichts von Hand ändern → **Weiter**.
4. Startdatum: **sofort / heute** → **Bestätigen**. (Fragt Apple nach bestehenden Abonnenten: „Aktuellen Preis
   beibehalten“ ist gleichgültig, siehe (d).)
5. Dasselbe für **StudiNow Pro AI (jährlich)** (`de.uniflow.proai.yearly`) mit **39,99 €**.
6. Kontrolle: in der Gruppe stehen Plus jährlich 19,99 € und Pro AI jährlich 39,99 € für Deutschland.

**(c) Reihenfolge und Stufen der Gruppe prüfen**

1. Gruppe **StudiNow** → Ansicht der Stufen (Abschnitt „Abonnements“, Ziehgriffe links; bzw. **Bearbeiten** der
   Reihenfolge).
2. Soll: **Stufe 1 = StudiNow Pro AI (jährlich)**, **Stufe 2 = StudiNow Plus (jährlich)** – die höchste Leistung oben,
   so wie in `UniFlow.storekit` (`groupNumber` 1 und 2). Die beiden Monatsabos dürfen auf ihren bisherigen Stufen
   bleiben (aus dem Verkauf, ohne Wirkung). Passt die Reihenfolge nicht, Pro AI jährlich nach oben ziehen → Sichern.
3. Lokalisierung der Gruppe und der Jahresabos prüfen: Anzeigename „StudiNow Plus“ bzw. „StudiNow Pro AI“,
   Beschreibung „Stift, Karteikarten, Community, Lösungen“ bzw. „Alles aus Plus und die StudiNow-KI“ (wie
   `docs/release/APP-STORE.md`). Prüfhinweis der Jahresabos durch die Texte aus `APP-STORE.md` ersetzen (yearly only,
   kein Umschalter „Jährlich“ mehr in der App) und den Prüf-Screenshot mit dem neuen Build neu hochladen.

**(d) Bestehende Abonnenten**

Es gibt noch keine zahlenden Abonnenten (nur Sandbox-/TestFlight-Käufe ohne Geld). Preisänderungen für bestehende
Abonnenten (Apple-Hinweis „Preis für bestehende Abonnenten beibehalten oder erhöhen“) spielen darum keine Rolle; die
Voreinstellung kann bleiben. Alte Sandbox-Käufe von Monatsabos schalten in App und Dienst weiter ihren Tarif frei und
laufen von selbst aus.

## Was nicht Teil dieses Zweigs ist

- Kein Upload der Website, kein Deploy des Dienstes, keine Änderung in App Store Connect, keine Build-Nummer.
- Stripe-Preise (Web/Windows) legt der Inhaber im Stripe-Dashboard als **jährliche** Preise an, sobald Stripe
  eingerichtet wird.
- Die Nutzungsbedingungen nennen in Abschnitt 5 weiter „ein Credit entspricht einem Cent“; die Entscheidung vom
  08.11.2026 (0,9 Cent) ist dort noch nicht nachgezogen (eigener Punkt, nicht Teil der Abo-Änderung).

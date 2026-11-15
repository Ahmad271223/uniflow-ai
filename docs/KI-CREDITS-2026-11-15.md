# KI-Credits zum Nachkaufen (Auftrag des Inhabers vom 15.11.2026)

Stand: gebaut auf dem Zweig `feature/ki-credits` (aus `develop`, Build 43). Nichts ist ausgerollt, in App Store Connect
ist nichts angelegt. Abschnitt 1–6 ist der Plan (vor dem Bau geschrieben, danach nachgezogen), 7 der Aufbau, 8 die
Rechnung, 9 was in App Store Connect anzulegen ist, 10 die Textvorschläge, 11 das Server-Update, 12 offene Punkte.

## 1. Was der Inhaber will

- Sind die Credits aufgebraucht, kann man neue kaufen: ein kleines und ein großes Paket.
- Monats-Credits werden bei Pro AI jeden Monat wieder auf höchstens 100 aufgefüllt (nichts wird angespart).
- Gekaufte Credits bleiben, bis sie verbraucht sind.
- Nachträge vom 15.11.: **1 Credit = 0,65 Cent** echte KI-Kosten (vorher 0,9), überall gleich – Monats-Credits, Probe
  und gekaufte Credits. Kleines Paket **100 Credits für 1,99 €**, großes Paket **200 Credits für 3,99 €**.

## 2. Zwei Töpfe je Konto (Dienst, `app/credits.py`)

| Topf | Wo | Regel |
|---|---|---|
| Monats-Credits | `credit_months` (wie bisher) | Pro AI 100, Probe 25, sonst 0; neuer Monat = neuer Stand; Rest verfällt |
| Gekaufte Credits | `credit_wallets` (Stand je Konto), `credit_purchases` (jeder Kauf) | verfallen nie; bleiben bei Monatswechsel, Tarifwechsel, Probe-Ende |

- **Verbrauch:** zuerst die Monats-Credits, erst danach die gekauften (ältester Kauf zuerst). Eine Anfrage kann aus
  beiden Töpfen bezahlt werden (Rest des Monats + gekaufte).
- **Nutzbar** sind gekaufte Credits, solange das Konto die StudiNow-KI hat (Pro AI oder laufende Probe;
  `plans.can_use_purchased_credits`). Ohne Pro AI ruhen sie beim Konto und sind wieder da, sobald Pro AI wieder läuft.
- **Kaufen** darf, wer bezahltes Pro AI hat. Diese Regel steht an EINER Stelle: `plans.CREDIT_PACKS["buy_plans"]`
  (dazu `buy_in_trial`). Der Dienst liefert sie als `credits.can_buy`; die App fragt nur dieses Feld. Sollen später auch
  Plus oder Free kaufen dürfen: dort eintragen, sonst nichts.
  Der Dienst verbucht einen bezahlten Kauf trotzdem immer (wer bezahlt hat, bekommt seine Credits).
- **Paketgröße** ist EINE Einstellung im Dienst: `plans.CREDIT_PACKS["packs"]` (Credits je Produkt-ID, änderbar mit
  `LERNAPP_CREDIT_PACKS`, z. B. `de.uniflow.credits.gross=185`). Die App zeigt die Zahl vom Dienst und den Preis aus
  StoreKit. Die Produkt-IDs tragen keine Zahl: `de.uniflow.credits.klein`, `de.uniflow.credits.gross`.

### Zahlenbeispiel über einen Monatswechsel

Konto mit Pro AI, kauft im November das kleine Paket.

| Zeitpunkt | Was geschieht | Diesen Monat | Gekauft |
|---|---|---|---|
| 10.11. | Stand | 100 von 100 | 0 |
| 12.11. | 90 Credits verbraucht | 10 von 100 | 0 |
| 14.11. | Paket „100 Credits“ gekauft | 10 von 100 | 100 |
| 15.11. | Anfrage kostet 30: 10 aus dem Monat, 20 aus den gekauften | 0 von 100 | 80 |
| 20.11. | Anfrage kostet 5: der Monat ist leer, alles aus den gekauften | 0 von 100 | 75 |
| 01.12. | Monatswechsel: der Monat ist wieder voll, die gekauften bleiben | 100 von 100 | 75 |
| 05.12. | Anfrage kostet 40: ganz aus dem Monat | 60 von 100 | 75 |
| 01.01. | Monatswechsel: wieder höchstens 100 (die 60 werden nicht angespart) | 100 von 100 | 75 |

## 3. Budget (Kostenkontrolle bleibt dicht)

Der Dienst rechnet je Anfrage zweimal:

1. **Credits** (`credit_months`, `credit_ledger`, `credit_wallets`): vor dem Aufruf wird die Obergrenze reserviert –
   zuerst aus dem Rest des Monats, was fehlt aus den gekauften Credits –, danach mit den echten Kosten abgerechnet, nie
   mehr als reserviert. Reicht beides zusammen nicht: `429 credits_exhausted`. Das ist die harte Grenze je Konto:
   **mehr als Monats-Credits + gekaufte Credits kann ein Konto nie verbrauchen**, auch nicht mit gleichzeitigen Anfragen.
2. **Kosten in Euro** (`ai_usage_log`): Becken für alle zahlenden Konten (`LERNAPP_AI_BUDGET_EUR`), Becken der Probe,
   und je Konto und Monat `LERNAPP_AI_USER_BUDGET_EUR` (Standard 2 €). Hier zählen auch KI-Tests und KI-Mails, die keine
   Credits kosten.

Neu bei 2.: Der Teil der Kosten, den gekaufte Credits bezahlen, zählt in keinem dieser Becken
(`ai_usage_log.purchased_microeur`; die Monatssummen rechnen `Kosten − gekaufter Teil`). Dieser Teil ist durch den Kauf
selbst begrenzt. Alles andere zählt wie bisher: KI-Tests und KI-Mails bleiben an das Monats-Budget gebunden, die
gekauften Credits weichen es nicht auf.

- Sperrt ein Becken den Monats-Teil einer Anfrage (Budget erreicht), wird die Anfrage ganz aus den gekauften Credits
  bezahlt, wenn sie dafür reichen. So blockiert das Monats-Budget gekaufte Credits nie.
- Das Monatskontingent „150 KI-Anfragen“ (`ai_assist`) sperrt nicht, solange gekaufte Credits da sind; das Rate-Limit
  (6 je Minute, 60 je Stunde) gilt weiter.
- **Kaufe aus der Testumgebung** (Sandbox: TestFlight, Prüfung durch Apple – ohne Geld) zählen, sonst fiele die Prüfung
  durch, aber höchstens `LERNAPP_CREDITS_SANDBOX_MONTH` Credits je Konto und Monat (Standard 400 = höchstens 2,60 €).
  Ohne diese Grenze könnte ein Tester beliebig viele Pakete kostenlos kaufen.
- **Monats-Budget je Konto:** Mit 0,65 Cent je Credit kosten 100 Monats-Credits höchstens 0,65 € (vorher 0,90 €). Die
  2 € passen weiter. Wer den Spielraum für KI-Tests und KI-Mails gleich lassen will (bisher 2,00 − 0,90 = 1,10 €),
  setzt `LERNAPP_AI_USER_BUDGET_EUR=1.75`. Der Standard im Code ist unverändert 2.

## 4. Kaufablauf (App → Dienst)

1. App: `Product.purchase` (StoreKit 2, Verbrauchskauf) mit `appAccountToken` = Konto (`CreditStore.purchase`).
2. App schickt die signierte Transaktion an `POST /api/billing/credits/apple` `{signed_transaction}`.
3. Dienst prüft Signatur und Zertifikatskette wie bei den Abos, dazu Bundle-ID und Produkt. Jede Transaktion wird genau
   einmal verbucht (`credit_purchases`: Quelle + Transaktions-ID sind der Schlüssel; eine zweite Meldung ändert nichts
   und antwortet `already_granted`).
4. Erst nach Status 200 ruft die App `finish()`. Bei jedem anderen Status und ohne Antwort bleibt der Kauf offen und
   wird nachgeholt: beim nächsten Start bzw. nach der Anmeldung (`Transaction.unfinished`, `CreditStore.processUnfinished`)
   und über `Transaction.updates` (`Entitlements.handle` reicht Pakete an `CreditStore.handle` weiter und schließt sie
   nie selbst ab).
5. Zusätzlich verbucht der Dienst denselben Kauf aus Apples Server-Mitteilung (`ONE_TIME_CHARGE`), falls die App es
   nicht schafft. Auch `POST /api/billing/apple/verify` (alte Abo-Route) verbucht ein Credit-Paket, statt es abzulehnen.

Konto: Die Credits bekommt das Konto aus dem `appAccountToken` (wer gekauft hat), auch wenn ein anderes Konto den Kauf
meldet (`other_account: true`). Die Schnittstelle trennt „Kauf prüfen“ (Apple, `apple_store.apply_credit_purchase`) von
„Topf füllen“ (`credits.grant_purchase(conn, user_id, source, transaction_id, credits)`): ein anderer Bezahlweg (z. B.
Stripe im Web) füllt später denselben Topf mit eigener Quelle.

## 5. Erstattung

- Apple meldet Erstattungen an `POST /api/billing/apple/notifications` (`REFUND`, `REVOKE`) – der Endpunkt wird schon
  für die Abos ausgewertet. Auch die App meldet eine widerrufene Transaktion (`revocationDate`).
- Der Dienst zieht die **noch vorhandenen Credits genau dieses Kaufs** ab, nie ins Minus. Schon verbrauchte Credits
  bleiben verbraucht; eine laufende Anfrage wird nicht mehr aus erstatteten Credits bezahlt.
- Doppelte Meldungen ändern nichts. Kommt die Erstattung, bevor der Kauf je gemeldet wurde, wird er als erstattet
  vermerkt und später nicht mehr gutgeschrieben. `REFUND_REVERSED` gibt die abgezogenen Credits zurück.
- Was fehlt: Apples Anfrage nach Verbrauchsangaben (`CONSUMPTION_REQUEST`) beantwortet der Dienst nicht – dafür braucht
  es den Schlüssel für die App Store Server API. Apple entscheidet über Erstattungen dann ohne unsere Angaben.
- Voraussetzung: In App Store Connect sind beide Adressen für Server-Mitteilungen (Produktion und Sandbox) auf
  `https://app.studinow.app/api/billing/apple/notifications` gesetzt. Ohne sie erfährt der Dienst von einer Erstattung
  erst, wenn die App die widerrufene Transaktion meldet.

## 6. Was alte Apps sehen (1.0.3, 1.0.4)

- Alle bisherigen Felder bleiben, mit derselben Bedeutung: `credits.allowance/used/reserved/remaining` sind weiter nur
  die Monats-Credits. Neue Felder sind zusätzlich und freiwillig.
- Hat ein Konto gekaufte Credits (auf einem Gerät mit neuer App gekauft), arbeitet die KI auch in der alten App weiter;
  sie zeigt nur den Monats-Stand („0 von 100 übrig“), obwohl die Anfrage aus den gekauften Credits bezahlt wird.
- Fehlertext und Code bei leeren Credits bleiben für alte Apps gleich („Credits für diesen Monat aufgebraucht – am 1.
  gibt es neue.“, `credits_exhausted`, Knopf „Tarif ansehen“).
- `credit_eur` in den Antworten ist jetzt 0.0065 statt 0.009 (die Apps zeigen den Wert nicht).

## 7. Aufbau

### Dienst

| Datei | Was |
|---|---|
| `app/plans.py` | `CREDIT_PACKS` (Pakete, Kaufregel, Nutzungsrecht), `credit_packs()`, `credit_pack_credits()`, `can_buy_credits()`, `can_use_purchased_credits()`; Vertrag `credit_packs` |
| `app/ai_prices.py` | `MICROEUR_PER_CREDIT = 6_500` |
| `app/credits.py` | Tabellen `credit_wallets`, `credit_purchases`; Spalten `reserved_purchased`, `charged_purchased`, `purchased_microeur` an `credit_ledger`; `reserve`/`settle`/`refund` mit zwei Töpfen; `grant_purchase`, `refund_purchase`, `restore_purchase`; Stand mit `purchased`, `purchased_usable`, `available`, `can_buy` |
| `app/ai_backend.py` | Spalte `ai_usage_log.purchased_microeur`, Trigger und Monatssummen ohne den gekauften Teil, Ausweichen auf „ganz aus gekauften Credits“, `month_report.purchased_cost_eur` |
| `app/apple_store.py` | `apply_credit_purchase`, `verify_credit_purchase`, Pakete in `verify_purchase` und `handle_notification`, Grenze für Sandbox-Käufe |
| `app/billing_api.py` | `POST /api/billing/credits/apple`; `credit_packs` in `GET /api/entitlements` |
| `app/entitlements.py` | Kontingent `ai_assist` sperrt nicht mit gekauften Credits |
| `app/accounts.py`, `app/account_export.py` | Konto löschen (Stand weg, Käufe ohne Konto behalten), Datenexport (`ki_credits_gekauft`, `ki_credits_kaeufe`) |
| `app/credit_texts.py` | Referenz der Texte für alle Oberflächen |

Felder (alle neu und zusätzlich):

- `credits` (in `GET /api/entitlements`, KI-Antworten, 429): `purchased` (gekaufte, frei), `purchased_usable`,
  `available` (Rest des Monats + nutzbare gekaufte), `can_buy`.
- `credit_packs` (in `GET /api/entitlements`): `packs: [{product_id, credits}]`, `purchase.apple/web {available, note}`.
- `GET /api/billing/plans`: `credit_packs {packs [{product_id, credits, price_cents, currency}], buy_plans, buy_in_trial, use_right}`.
- `POST /api/billing/credits/apple` → `{status, credits_added, credits_removed, product_id, transaction_id, environment,
  other_account, sandbox_limited, credits}`; `status`: `granted | already_granted | refunded | already_refunded`.
  Fehler: 400 `jws_invalid`/`unknown_product`/`wrong_app`, 400 `jws_untrusted`, 401, 503 `apple_not_configured`.

Verträge: `packages/shared-contracts/schemas/api/v2/me.schema.json` (ergänzt), `credit-purchase.schema.json` (neu),
`fixtures/credit-packs/contract.json` (neu, `tools/gen-credit-packs-fixture.py --check`), `fixtures/plans/plans.json`.

Migration: automatisch beim ersten Öffnen der Konto-Datenbank, wiederholbar, ohne Abhängigkeit von der Tabelle `users`
(alles `CREATE … IF NOT EXISTS`, Spalten mit `db.add_column`). Die Trigger der Monatssummen werden in einer
Transaktion ersetzt. Die neuen Tabellen liegen nur in `accounts.db` (Dienst) und stehen nicht im Schema-Vergleich mit
der lokalen Datenbank der App.

### App (iPad, iPhone, Mac)

| Datei | Was |
|---|---|
| `UniFlowCore/Account/CreditPacks.swift` | Pakete, Stand beider Töpfe, Texte (`CreditText`), `StudoraAccount.bookCreditPurchase` |
| `UniFlow/Purchases/CreditStore.swift` | Laden für die Pakete: kaufen, melden, erst danach abschließen, offene Käufe nachholen |
| `UniFlow/Purchases/Entitlements.swift` | Pakete nie selbst abschließen (`creditPurchase`) |
| `UniFlow/Views/Settings/CreditShopSheet.swift` | Blatt, Eintrag „Credits kaufen“, Karte auf der Tarifseite |
| `UniFlow/Services/StudoraAccountLink.swift` | Stand, Pakete, Verbuchen, Handlung `.credits` bei leeren Credits |
| `TutorPanel`, `AIStartView`, `ExamsPage` | Blatt statt Sackgasse |

- Blatt nur über `.ufSheet`; Preise nur aus `Product.displayPrice`; Zahl der Credits vom Dienst.
- Anzeige: „Diesen Monat: x von 100 (neu am 1. Dezember) · Gekauft: y“ – der Zusatz in Klammern gehört zum Monat.
- Wer nicht kaufen darf (Probe, Plus, Free), sieht bei leeren Credits wie bisher „Tarif ansehen“; ruhende gekaufte
  Credits nennt die App ehrlich („… bleiben bei deinem Konto und sind wieder nutzbar, sobald StudiNow Pro AI läuft“).

### Web und Windows

Stand beider Töpfe in der KI-Hilfe und auf „Abo & Tarife“ mit dem Hinweis „Credits kaufst du in der App für iPhone und
iPad.“ (`app/static/credit-packs-logic.js`). Kaufen gibt es dort noch nicht.

## 8. Rechnung je Paket (Deutschland, 19 % Umsatzsteuer)

Apple rechnet seinen Anteil vom Preis ohne Umsatzsteuer. KI-Kosten bei vollem Verbrauch: 0,65 Cent je Credit.

| | 100 Credits für 1,99 € | 200 Credits für 3,99 € |
|---|---|---|
| Preis | 1,99 € | 3,99 € |
| davon 19 % Umsatzsteuer | 0,32 € | 0,64 € |
| Preis ohne Umsatzsteuer | 1,67 € | 3,35 € |
| Apple 30 % | 0,50 € | 1,01 € |
| Auszahlung bei 30 % | 1,17 € | 2,35 € |
| KI-Kosten bei vollem Verbrauch | 0,65 € | 1,30 € |
| **bleibt übrig bei 30 %** | **0,52 €** | **1,05 €** |
| Apple 15 % (Small Business Program) | 0,25 € | 0,50 € |
| Auszahlung bei 15 % | 1,42 € | 2,85 € |
| **bleibt übrig bei 15 %** | **0,77 €** | **1,55 €** |

Nicht eingerechnet: Einkommensteuer, Server, Erstattungen. Wird ein Paket nach dem Verbrauch erstattet, trägt der
Inhaber die KI-Kosten (höchstens 0,65 € bzw. 1,30 €).

Monats-Credits: Pro AI bekommt mit 0,65 Cent je Credit rund 28 % weniger KI je Monat als bisher (100 Credits =
höchstens 0,65 € statt 0,90 €); im Jahr höchstens 7,80 € statt 10,80 € KI-Kosten je Konto.

## 9. Was in App Store Connect anzulegen ist

Zwei In-App-Käufe, Art **Verbrauchsartikel (Consumable)**, ohne Familienfreigabe:

| | Kleines Paket | Großes Paket |
|---|---|---|
| Referenzname | Credits klein | Credits groß |
| Produkt-ID | `de.uniflow.credits.klein` | `de.uniflow.credits.gross` |
| Preis | 1,99 € | 3,99 € |
| Anzeigename (de-DE) | 100 Credits | 200 Credits |
| Beschreibung (de-DE, höchstens 45 Zeichen) | 100 Credits für die StudiNow-KI | 200 Credits für die StudiNow-KI |
| Prüf-Bild | Bildschirmfoto des Blatts „Deine Credits sind aufgebraucht“ mit beiden Paketen | dasselbe |

- Steuerkategorie und Verfügbarkeit wie bei den Abos. Die Käufe gehen mit der nächsten App-Version in die Prüfung
  (erste Einreichung eines neuen In-App-Kaufs braucht eine neue Version).
- Ändert sich später die Größe eines Pakets: im Dienst `LERNAPP_CREDIT_PACKS` setzen und in App Store Connect
  Anzeigename und Beschreibung anpassen – die Produkt-ID bleibt.
- Server-Mitteilungen (Version 2) für Produktion und Sandbox auf `https://app.studinow.app/api/billing/apple/notifications`.

## 10. Textvorschläge (NICHT eingebaut – Rechtstexte, Website und Store-Texte ändert der Inhaber)

### Nutzungsbedingungen (Abschnitt zu Pro AI und neuer Absatz)

Heute steht dort: „Nicht verbrauchte Credits verfallen am Monatsende; sind sie aufgebraucht, steht die KI von StudiNow
bis zum nächsten Monat nicht zur Verfügung, alle anderen Funktionen bleiben.“ Vorschlag statt dieses Satzes:

> Nicht verbrauchte Monats-Credits verfallen am Monatsende. Sind sie aufgebraucht, steht die KI von StudiNow bis zum
> nächsten Monat nicht zur Verfügung, außer du hast gekaufte Credits; alle anderen Funktionen bleiben.

Neuer Absatz:

> **Credit-Pakete.** Mit StudiNow Pro AI kannst du in der App für iPhone, iPad und Mac zusätzliche Credits für die KI
> von StudiNow kaufen (Stand: 100 Credits für 1,99 € und 200 Credits für 3,99 € inkl. USt; den Preis zeigt die App vor
> dem Kauf). Das ist ein einmaliger Kauf über deine Apple-ID, kein Abo. Gekaufte Credits gehören zu deinem
> StudiNow-Konto, gelten auf allen deinen Geräten und verfallen nicht. Verbraucht werden zuerst deine Monats-Credits,
> danach die gekauften. Gekaufte Credits kannst du nutzen, solange du StudiNow Pro AI hast; endet Pro AI, bleiben sie
> bei deinem Konto und sind wieder nutzbar, sobald Pro AI wieder läuft. Gekaufte Credits lassen sich nicht in Geld
> umtauschen, nicht auszahlen und nicht auf ein anderes Konto übertragen. Löschst du dein StudiNow-Konto, verfallen
> noch vorhandene gekaufte Credits mit dem Konto.
>
> **Erstattung und Widerruf.** Vertragspartner für den Kauf ist Apple. Erstattungen beantragst du bei Apple
> (reportaproblem.apple.com). Erstattet Apple einen Kauf, entfernen wir die noch nicht verbrauchten Credits dieses
> Kaufs. Credits sind digitale Inhalte, die sofort bereitgestellt werden: Mit dem Kauf stimmst du zu, dass die
> Bereitstellung vor Ablauf der Widerrufsfrist beginnt; dein Widerrufsrecht erlischt damit, soweit das Gesetz das zulässt.

(Den letzten Satz bitte rechtlich prüfen lassen; bei Käufen über Apple gelten Apples Bedingungen.)

In der Tabelle der Tarife zusätzlich eine Zeile: „Credit-Pakete zum Nachkaufen (verfallen nicht) | – | – | ✓“.

### Datenschutz

Es ändert sich wenig. Vorschlag für eine Ergänzung bei den Kaufdaten:

> Kaufst du ein Credit-Paket, schickt die App die von Apple signierte Transaktion (Produkt, Zeitpunkt,
> Transaktionskennung, Kennung deines StudiNow-Kontos) an unseren Dienst, damit die Credits deinem Konto
> gutgeschrieben werden. Wir speichern dazu den Kauf (Produkt, Zahl der Credits, Zeitpunkt, Transaktionskennung, ob er
> erstattet wurde) und den Stand deiner gekauften Credits. Zahlungsdaten erhalten wir nicht. Rechtsgrundlage ist die
> Erfüllung des Vertrags (Art. 6 Abs. 1 lit. b DSGVO). Löschst du dein Konto, löschen wir den Stand; den Kauf bewahren
> wir ohne Bezug zu deinem Konto auf, soweit wir dazu aus steuerlichen Gründen verpflichtet sind.

In `APP-STORE.md` (Datenschutz-Angaben, Zeile „Käufe → Kaufverlauf“) die Route ergänzen: „… geht an
`/api/billing/apple/verify` bzw. bei Credit-Paketen an `/api/billing/credits/apple` …“. Die Kategorien bleiben gleich.

### Store-Beschreibung (Ergänzung) und „Neu in dieser Version“

Beschreibung, im Absatz zu Pro AI:

> Credits aufgebraucht? Mit Pro AI kannst du Credits nachkaufen: 100 oder 200 Credits als einmaligen Kauf. Gekaufte
> Credits verfallen nicht.

Neu in dieser Version:

> Neu: Credits nachkaufen. Sind deine Monats-Credits für die StudiNow-KI aufgebraucht, holst du dir mit Pro AI 100 oder
> 200 Credits dazu. Gekaufte Credits verfallen nicht. Deine Monats-Credits gibt es wie gewohnt am 1. wieder.

### Review notes for Apple (English)

> New in this version: consumable in-app purchases "100 Credits" (de.uniflow.credits.klein) and "200 Credits"
> (de.uniflow.credits.gross). Credits pay for requests to the StudiNow AI.
>
> Where to find them: sign in with Apple and buy "StudiNow Pro AI" in the sandbox (Settings → Account & plan → Change
> plan). Then open Settings → Account & plan: the plan card shows "Credits" with the line "Diesen Monat: x von 100 ·
> Gekauft: y" and the button "Credits kaufen". The same sheet opens automatically when an AI request fails because the
> monthly credits are used up ("Deine Credits sind aufgebraucht").
>
> How it works: the plan includes 100 credits per calendar month, which are refilled every month and do not carry
> over. Purchased credits are separate: they never expire, they are used only after the monthly credits are used up,
> and they stay with the StudiNow account across devices. The purchase is verified on our server (signed transaction)
> and credited exactly once; the transaction is finished only after the server has credited it. Credit packs can only
> be bought with an active Pro AI subscription, because credits are only useful with the AI; if the subscription ends,
> purchased credits remain on the account and become usable again when Pro AI is active again. The app says so.
> There is nothing to restore: purchased credits are stored with the account, not on the device.

### Wo heute ein Credit-Wert oder die alte Regel steht

- Einen Centwert je Credit nennt kein Rechtstext, keine Seite der Website und kein Store-Text. Er stand nur in
  `docs/PREISLISTE.md` (intern; dort jetzt 0,65 Cent) und in Kommentaren des Codes (nachgezogen). Für den neuen
  Credit-Wert ist an den Rechtstexten also nichts zu ändern.
- Die Regel „Credits verfallen am Monatsende; sind sie aufgebraucht, steht die KI bis zum nächsten Monat nicht zur
  Verfügung“ steht in `docs/release/NUTZUNGSBEDINGUNGEN.md` (Absatz „StudiNow Pro AI“) und damit in
  `site/nutzungsbedingungen.html`. Sie stimmt mit den Paketen nicht mehr ganz (Vorschlag oben).
- `docs/release/APP-STORE.md`: der Satz „Die KI-Credits gelten auch beim Jahresabo je Kalendermonat (100 Credits …)“,
  die Prüfhinweise zu Pro AI („100 credits per month“) und die Zeile „Käufe → Kaufverlauf“ der Datenschutz-Angaben
  brauchen die Ergänzung um die Pakete.

### Tests, die nach der Textänderung anzupassen sind

- `tests/test_abo_nur_jahr_2026_11_09.py::test_public_texts_name_only_the_yearly_prices` verbietet „1,99 €“ und
  „3,99 €“ (die früheren Monatspreise) in `NUTZUNGSBEDINGUNGEN.md`, `STARTSEITE.md`, `EINLADUNG.md`, `site/*.html`,
  `README.md`, `docs/PREISLISTE.md`, `docs/ABO-SYSTEM.md` und der TestFlight-Anleitung. Sobald dort die Paketpreise
  stehen, muss der Test sie als Preise der Credit-Pakete zulassen. (Darum nennt `docs/PREISLISTE.md` die Paketpreise
  heute nicht.)
- `tests/test_site.py`: die Website entsteht aus `docs/release` – nach der Textänderung `tools/gen-site.py` laufen lassen.
- `tests/test_rechtstexte.py`, `tests/test_release_texts.py`, `tests/test_tarife_texte.py`: prüfen den geänderten Satz
  heute nicht wörtlich; nach der Textänderung laufen lassen.

## 11. Server-Update (vor dem neuen Build)

1. Der neue Stand ist abwärtsverträglich: alte Apps merken nichts (Abschnitt 6). Reihenfolge: erst Dienst, dann App.
2. Die Konto-Datenbank zieht sich beim Start selbst nach (neue Tabellen, neue Spalten, Trigger). Vorher wie üblich
   sichern. Ein Zurück auf den alten Stand ist möglich: der alte Code ignoriert die neuen Tabellen und Spalten.
3. **Der Wert eines Credits ändert sich mit dem Update sofort** (0,9 → 0,65 Cent): dieselbe Anfrage kostet danach
   rund 38 % mehr Credits. Laufende Monatsstände bleiben stehen (verbrauchte Credits werden nicht umgerechnet).
4. Neue Einstellungen (alle freiwillig, `deploy/.env.example`): `LERNAPP_CREDIT_PACKS`, `LERNAPP_CREDITS_SANDBOX_MONTH`;
   Vorschlag `LERNAPP_AI_USER_BUDGET_EUR=1.75` (Abschnitt 3).
5. Prüfen: Apples Wurzelzertifikat liegt (sonst antwortet `POST /api/billing/credits/apple` mit 503 und die App holt
   den Kauf später nach) und die Adressen für Server-Mitteilungen sind gesetzt (Abschnitt 5).
6. Kaufen kann man erst, wenn die zwei Produkte in App Store Connect freigegeben sind und der neue Build live ist.

## 12. Offene Entscheidungen für den Inhaber

- **Wer kaufen darf:** gebaut ist „nur mit bezahltem Pro AI“ (Probe, Plus, Free nicht). Änderbar an einer Stelle.
- **Preise:** 1,99 € und 3,99 € (der Inhaber sagte „2 €“ und „4 €“; die übrigen Preise enden auf ,99). Die App zeigt
  immer den Preis aus dem Store.
- **Web und Windows:** dort wird nur der Stand gezeigt. Ein Kauf über Stripe wäre möglich (der Topf ist vorbereitet),
  ist aber nicht gebaut.
- **Monats-Budget je Konto:** 2 € lassen oder auf 1,75 € senken.
- **Kontingent „150 KI-Anfragen je Monat“:** gilt weiter für Monats-Credits, sperrt aber nicht mehr, solange gekaufte
  Credits da sind.
- **Small Business Program:** mit 15 % statt 30 % bleiben je Paket 0,25 € bzw. 0,50 € mehr.

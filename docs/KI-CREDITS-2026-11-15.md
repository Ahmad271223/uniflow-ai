# KI-Credits zum Nachkaufen (Auftrag des Inhabers vom 15.11.2026)

Stand: Plan vor dem Bau. Der Abschnitt „Aufbau“ wird nach dem Bau ergänzt, die Texte am Ende sind Vorschläge.

## 1. Was der Inhaber will

- Sind die Credits aufgebraucht, kann man neue kaufen: ein kleines und ein großes Paket.
- Monats-Credits werden bei Pro AI jeden Monat wieder auf höchstens 100 aufgefüllt (nichts wird angespart).
- Gekaufte Credits bleiben, bis sie verbraucht sind.
- Nachtrag vom 15.11.: 1 Credit = 0,65 Cent echte KI-Kosten (vorher 0,9), überall gleich. Kleines Paket 100 Credits
  für 1,99 €; großes Paket 3,99 €, Größe noch offen (vorerst 200, im Gespräch 185).

## 2. Zwei Töpfe je Konto (Dienst, `app/credits.py`)

| Topf | Wo | Regel |
|---|---|---|
| Monats-Credits | `credit_months` (wie bisher) | Pro AI 100, Probe 25, sonst 0; neuer Monat = neuer Stand; Rest verfällt |
| Gekaufte Credits | `credit_wallets` (Stand je Konto), `credit_purchases` (jeder Kauf) | verfallen nie; bleiben bei Monatswechsel, Tarifwechsel, Probe-Ende |

- **Verbrauch:** zuerst die Monats-Credits, erst danach die gekauften. Eine Anfrage kann aus beiden Töpfen bezahlt
  werden (Rest des Monats + gekaufte).
- **Nutzbar** sind gekaufte Credits nur, solange das Konto die StudiNow-KI hat (Pro AI oder laufende Probe). Ohne
  Pro AI ruhen sie beim Konto und sind wieder da, sobald Pro AI wieder läuft.
- **Kaufen** darf, wer bezahltes Pro AI hat. Diese Regel steht an EINER Stelle: `plans.CREDIT_PACKS["buy_plans"]`
  (dazu `buy_in_trial`). Der Dienst liefert sie als `credits.can_buy`; die App fragt nur dieses Feld.
  Der Dienst verbucht einen bezahlten Kauf trotzdem immer (wer bezahlt hat, bekommt seine Credits).
- **Paketgröße** ist EINE Einstellung im Dienst: `plans.CREDIT_PACKS["packs"]` (Credits je Produkt-ID, änderbar mit
  `LERNAPP_CREDIT_PACKS`). Die App zeigt die Zahl vom Dienst und den Preis aus StoreKit. Produkt-IDs ohne Zahl:
  `de.uniflow.credits.klein`, `de.uniflow.credits.gross`.

## 3. Budget (Kostenkontrolle bleibt dicht)

Heute rechnet der Dienst je Anfrage zweimal:

1. **Credits** (`credit_months`, `credit_ledger`): vor dem Aufruf wird die Obergrenze reserviert, danach mit den echten
   Kosten abgerechnet, nie mehr als reserviert. Das ist die harte Grenze je Konto.
2. **Kosten in Euro** (`ai_usage_log`): Becken für alle zahlenden Konten (`LERNAPP_AI_BUDGET_EUR`), Becken der Probe,
   und je Konto und Monat `LERNAPP_AI_USER_BUDGET_EUR` (2 €). Hier zählen auch KI-Tests und KI-Mails, die keine Credits
   kosten.

Neu:

- Die Reservierung nimmt zuerst den Rest des Monats, den Rest aus den gekauften Credits. Reicht beides zusammen nicht:
  `429 credits_exhausted`. Mehr als Monats-Credits + gekaufte Credits kann ein Konto nie verbrauchen.
- Der Teil der Kosten, den gekaufte Credits bezahlen, zählt NICHT gegen das Monats-Budget je Konto und nicht gegen das
  Becken aller Konten (`ai_usage_log.purchased_microeur`; die Monatssummen rechnen `Kosten − gekaufter Teil`). Dieser
  Teil ist durch den Kauf selbst begrenzt. Alles andere zählt wie bisher.
- Das Monatskontingent „150 KI-Anfragen“ (`ai_assist`) sperrt nicht, solange gekaufte Credits da sind.

## 4. Kaufablauf (App → Dienst)

1. App: `Product.purchase` (StoreKit 2, Verbrauchskauf) mit `appAccountToken` = Konto.
2. App schickt die signierte Transaktion an `POST /api/billing/credits/apple`.
3. Dienst prüft Signatur und Kette wie bei den Abos, Bundle-ID, Produkt. Jede Transaktion wird genau einmal verbucht
   (`credit_purchases.transaction_id` ist der Schlüssel; eine zweite Meldung ändert nichts und antwortet gleich).
4. Erst nach der Antwort des Dienstes ruft die App `finish()`. Ohne Antwort bleibt der Kauf offen und wird beim
   nächsten Start nachgeholt (`Transaction.unfinished`, `Transaction.updates`).
5. Zusätzlich verbucht der Dienst denselben Kauf aus Apples Server-Mitteilung (`ONE_TIME_CHARGE`), falls die App es
   nicht schafft. Auch `POST /api/billing/apple/verify` (alte Route) verbucht ein Credit-Paket, statt es abzulehnen.

Die Schnittstelle trennt „Kauf prüfen“ (Apple) von „Topf füllen“ (`credits.grant_purchase(source, transaction_id, …)`):
ein anderer Bezahlweg (z. B. Stripe im Web) kann später denselben Topf füllen.

## 5. Erstattung

Apple meldet Erstattungen an `POST /api/billing/apple/notifications` (`REFUND`); die App meldet eine widerrufene
Transaktion ebenfalls. Der Dienst zieht dann die noch vorhandenen Credits genau dieses Kaufs ab, nie ins Minus. Schon
verbrauchte Credits bleiben verbraucht. `REFUND_REVERSED` gibt die abgezogenen Credits zurück.

## 6. Was alte Apps sehen (1.0.3, 1.0.4)

- Alle bisherigen Felder bleiben, mit derselben Bedeutung: `credits.allowance/used/reserved/remaining` sind weiter nur
  die Monats-Credits.
- Neue Felder sind zusätzlich und freiwillig (`purchased`, `purchased_usable`, `available`, `can_buy`, `packs`).
- Hat ein Konto gekaufte Credits, arbeitet die KI auch in der alten App weiter; sie zeigt nur den Monats-Stand.
- Der Fehlertext bei leeren Credits bleibt für alte Apps derselbe.

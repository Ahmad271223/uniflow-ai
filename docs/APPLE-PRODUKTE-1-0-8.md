# Apple-Produkte für 1.0.8 (neue Tarife, Stand 27.11.2026)

Vorlage für App Store Connect. Angelegt oder geändert wird erst nach dem ausdrücklichen Ja des Inhabers zu genau
dieser Liste; das macht die Build-Sitzung beim Einreichen. Die neuen Käufe gehen zusammen mit Version 1.0.8 zur
Prüfung. Gelesener Stand bei Apple (27.11., nur gelesen): Abo-Gruppe „Plus“ (22545770) mit `plus.yearly` und
`proai.yearly` (APPROVED) sowie `plus.monthly` (1,99 €) und `proai.monthly` (3,99 €), beide
DEVELOPER_REMOVED_FROM_SALE. Die Preise stimmen schon, eine Preiserhöhung ist nicht nötig.

| # | Produkt-ID | Art | Gruppe / Stufe | Laufzeit | Preis (DE) | Was tun |
|---|---|---|---|---|---|---|
| 1 | `de.uniflow.plus.monthly` | Auto-Abo | Plus, Stufe 2 | 1 Monat | 1,99 € | wieder verkaufen (175 Länder), Texte unten |
| 2 | `de.uniflow.proai.monthly` | Auto-Abo | Plus, Stufe 1 | 1 Monat | 3,99 € | wieder verkaufen (175 Länder), Texte unten |
| 3 | `de.uniflow.proai.yearly` | Auto-Abo | Plus, Stufe 1 | 1 Jahr | 39,99 € | bleibt; Beschreibung auf die Credits anpassen |
| 4 | `de.uniflow.plus.fuenfjahre` | **Nicht verlängerndes Abo** | – (keine Gruppe) | 5 Jahre (rechnet die App/der Dienst) | 39,99 € | **neu anlegen**, mit 1.0.8 einreichen |
| 5 | `de.uniflow.plus.yearly` | Auto-Abo | Plus, Stufe 2 | 1 Jahr | 19,99 € | bleibt für Bestandskunden; erst beim Veröffentlichen aus dem Verkauf |

Credit-Pakete (`de.uniflow.credits.klein` 80 für 1,99 €, `.gross` 160 für 3,99 €) bleiben unverändert.

## Texte (Anzeigename höchstens 35, Beschreibung höchstens 55 Zeichen)

| Produkt | de-DE Name | de-DE Beschreibung | en-US Name | en-US Beschreibung |
|---|---|---|---|---|
| plus.monthly | StudiNow Plus (monatlich) | Alle Funktionen ohne KI, KI mit Credits dazu | StudiNow Plus (Monthly) | All features without AI, add AI with credits |
| proai.monthly | StudiNow Pro AI (monatlich) | Alles aus Plus und 120 KI-Credits jeden Monat | StudiNow Pro AI (Monthly) | Everything in Plus and 120 AI credits every month |
| proai.yearly | StudiNow Pro AI (jährlich) | Alles aus Plus und 120 KI-Credits jeden Monat | StudiNow Pro AI (Yearly) | Everything in Plus and 120 AI credits every month |
| plus.fuenfjahre | Bachelor+Master-Paket | StudiNow Plus 5 Jahre: einmal zahlen, kein Abo | Bachelor+Master Package | StudiNow Plus for 5 years: one payment, no renewal |

Referenzname für `plus.fuenfjahre`: „Bachelor+Master-Paket (Plus 5 Jahre)“.

## Prüfhinweis (Review Notes, englisch)

> StudiNow Plus is offered monthly (1.99 EUR) or as the "Bachelor+Master Package": a non-renewing subscription
> (39.99 EUR) that unlocks Plus for 5 years from the purchase date and never renews. The app computes the end date from
> the purchase date (StoreKit currentEntitlements) and the StudiNow server stores it with the account, so the purchase is
> available on all of the user's devices (iPad, iPhone, Mac) after signing in; "Restore purchases" (Käufe wiederherstellen) is on the plan screen.
> Pro AI (monthly 3.99 EUR or yearly 39.99 EUR) adds 120 AI credits per month. StudiNow's AI features work only with
> credits. A sandbox tester can buy any product on the plan screen after ticking the notice "Gelesen und verstanden".

Bildschirmfoto der Kaufseite für die Prüfung: `~/Studora-Builds/tarife-bilder/` (iPad und iPhone, kommt vom App-Teil).

## Warum „nicht verlängerndes Abo“ und kein Einmalkauf

Das Paket gibt Plus für eine begrenzte Zeit (5 Jahre), danach endet es. Für zeitlich begrenzten Zugang sieht Apple
das nicht verlängernde Abo vor. Ein Einmalkauf (Non-Consumable) gilt für immer und passt darum nicht. Apple nennt
beim nicht verlängernden Abo kein Ende: Das Ende rechnen App (`UFOffer.end`) und Dienst (`plans.offer_end`) aus dem
Kaufdatum.

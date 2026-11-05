# Einladungen („Freunde einladen“) – Regeln, Belohnungen, Apple-Vorgaben

**Entscheidung des Inhabers vom 04.11.2026.** Zum Abo-System insgesamt siehe `docs/ABO-SYSTEM.md` (Tarife, Probe,
App-Store-Käufe); diese Datei beschreibt nur die Einladungen. Code: `app/invites.py` (Regeln, Tabellen),
`app/invites_api.py` (Endpunkte), `tests/test_invites.py`; iPad: `apps/apple/UniFlow/Views/Settings/InviteView.swift`,
Kern `InviteRewards`/`InviteLink` in `apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/Account/InviteRewards.swift`;
Website `docs/release/EINLADUNG.md` → `site/i/index.html` und `site/.well-known/apple-app-site-association`.

## 1. Regeln

| Regel | Wert | Wo |
|---|---|---|
| Wer darf Links anlegen | ein Konto während seiner 7-Tage-Probe oder in den ersten 7 Tagen nach Anlegen (was später endet) | `invites.create_window` |
| Wie viele Links | höchstens **20** je Konto (insgesamt, auch abgelaufene zählen) | `MAX_PER_USER` |
| Link | `https://studinow.app/i/<CODE>`, Code 10 Zeichen aus `ABCDEFGHJKMNPQRSTUVWXYZ23456789` (ohne 0/O, 1/I/L), **30 Tage** gültig | `LINK_BASE`, `CODE_ALPHABET`, `LINK_DAYS` |
| Was zählt („angekommen“) | eine eingeladene Person, die StudiNow **neu** beginnt und sich anmeldet: ein Konto, das **nach** dem Link angelegt wurde, Einlösung innerhalb der 30 Tage, **eine Einlösung je Konto** (egal über welchen Link), nie das eigene Konto, nie ein Link eines gelöschten Kontos | `invites.redeem` |
| Wer löst ein | die App des neuen Kontos ruft nach der ersten Anmeldung einmal `POST /api/invites/redeem {code}` (idempotent; ein zweiter Aufruf antwortet `already: true`) | `PendingInvite` (iPad) |
| Belohnung | je erreichter Stufe einmal (`invite_rewards` PRIMARY KEY (user_id, tier)); ein zweiter Aufruf liefert denselben Code | `invites.claim` |
| Löschen des Kontos | eigene Links, Einlösungen (als Eingeladener und als Einladender) und Belohnungen werden endgültig entfernt; ein schon ausgegebener Angebotscode bleibt als ausgegeben vermerkt (`assigned_to = deleted:…`) | `accounts.ACCOUNT_TABLES`, `invites.forget_user` |
| Datenexport | `konto.json` → `einladungen` (Links, angekommene Einlösungen nur mit Code und Zeitpunkt, eigene Einlösung, Belohnungen) | `account_export._invites` |

Niemand wird zum Teilen gedrängt: die Seite zeigt die Links und das System-Teilen-Blatt (Nachrichten, Mail, AirDrop,
Kopieren) und den QR-Code; es gibt keine Erinnerungen, keine Hinweise beim Start und keine Nachteile ohne Einladung.

## 2. Stufen (Fixture in beiden Welten)

Die Tabelle steht in `app/invites.py` (`TIERS`, `REWARD_LABELS`) und `InviteRewards.tiers` (Swift); beide prüfen sich
gegen `packages/shared-contracts/fixtures/invites/cases.json` (`reward_tier(count)` bzw. `InviteRewards.tier(count:)`).

| Angekommene Personen | Belohnung | Wahl (`choice`) | Produkt im Vorrat (`offer_codes.product`) |
|---|---|---|---|
| 5 | 1 Monat StudiNow Plus gratis | `plus` | `plus` |
| 10 | 3 Monate StudiNow Plus gratis | `plus` | `plus` |
| 20 | 12 Monate StudiNow Plus gratis **oder** 12 Monate StudiNow Pro AI zum Plus-Preis (1,99 € statt 3,99 €) | `plus` oder `proai` | `plus` oder `pro_ai` |

Die Stufen 5 und 10 bleiben einlösbar, auch wenn 20 schon erreicht ist (jede Stufe einmal).

## 3. Apple-Vorgaben (warum Angebotscodes)

- **Belohnungen nur als Angebotscodes.** Ein Abo darf nur über den App Store gewährt werden (Richtlinie 3.1.1);
  StudiNow schaltet **nie selbst** einen Tarif frei. Der Dienst gibt nur einen Code aus seinem Vorrat heraus und
  merkt sich, wem er ihn gegeben hat. Eingelöst wird der Code **in Apples Dialog**:
  `https://apps.apple.com/redeem?ctx=offercodes&id=<APP_ID>&code=<CODE>` (die App öffnet den Link; ohne
  `LERNAPP_APPLE_APP_ID` zeigt sie nur den Code mit dem Weg „App Store → Profil → Code einlösen“).
- Ob die Person das Angebot bekommt, entscheidet Apple (z. B. Einführungs- und Angebotsregeln je Apple-Konto); der
  Tarif landet dann wie jeder Kauf über `POST /api/billing/apple/verify` bzw. die Server-Benachrichtigungen im Dienst
  (`docs/ABO-SYSTEM.md`, `app/apple_store.py`). Angebotscodes tragen `offerType`/`offerIdentifier` in der
  Transaktion; der Dienst behandelt sie wie jede Transaktion.
- Kein Zwang zum Teilen, keine Belohnung fürs Bewerten, keine Belohnung für Freunde, die nichts kaufen – es zählt nur
  „neu angefangen und angemeldet“. Die Person, die eingeladen wird, bekommt nichts und zahlt nichts (die 7-Tage-Probe
  bekommt jedes neue Konto ohnehin).
- Universal Links (`https://studinow.app/i/<CODE>`) brauchen die Fähigkeit **Associated Domains** (Abschnitt 6).

## 4. Endpunkte (`app/invites_api.py`, alle mit Sitzung)

| Endpunkt | Antwort / Fehler |
|---|---|
| `POST /api/invites` | 201 `{invite: {code, url, created_at, expires_at}, …Übersicht}`; 403 `invite_window_closed`, 409 `invite_limit` |
| `GET /api/invites` | `{codes: [{code, url, created_at, expires_at, redemptions, expired}], arrived, max_links, remaining_links, can_create, create_until, tier, tiers: [{count, choices, rewards, reached, claimable, claimed: {choice, offer_code, claimed_at, redeem_url}|null}], apple_app_id}`; Admin zusätzlich `stock` (frei je Produkt und Stufe) und `stock_warning` (Stufen mit weniger als 5 freien Codes) |
| `POST /api/invites/redeem {code}` | `{redeemed: true, already, code}`; 404 `invite_unknown`, 400 `invite_self`, 400 `invite_account_older`, 410 `invite_expired` |
| `POST /api/invites/claim {tier, choice}` | `{tier, choice, offer_code, reward, redeem_url, apple_product_id, already}`; 403 `invite_tier_not_reached`, 400 `invite_tier_invalid` / `invite_choice_invalid`, **409 `offer_codes_exhausted`** („Für diese Belohnung sind gerade keine Codes hinterlegt – bitte später noch einmal versuchen.“) |
| `POST /api/billing/offer-codes {product, tier, codes|text}` | nur Admin (`role = admin`, wie `/api/billing/ai-costs`): `{added, skipped, stock}`; `codes` als Liste oder `text` mit einer Zeile je Code (Zeilen mit `#` werden übersprungen); 400 `offer_product_invalid` (Pro AI nur für Stufe 20) |
| `GET /api/billing/offer-codes` | nur Admin: `{stock, tiers}` |

Tabellen in `accounts.db`: `invites`, `invite_redemptions`, `offer_codes`, `invite_rewards` (Schema in `app/invites.py`,
angelegt über `db.schema_once`).

## 5. Betrieb: Angebotscodes in App Store Connect anlegen und hochladen

Je Abo-Produkt unter **App Store Connect → App → Abonnements → (Produkt) → Angebotscodes → „+“**, Typ
**Einmal-Codes** („One-time use codes“), Kunden-Berechtigung „Neue Kunden, bestehende und ehemalige“ (sonst bekommen
Personen mit Probe keinen Code), Laufzeit so lang wie möglich (höchstens 6 Monate je Stapel; danach neuen Stapel
erzeugen). Vier Angebote:

| Produkt (`apple_product_id`) | Angebot | Angebotstyp | Dauer | Hochladen mit |
|---|---|---|---|---|
| StudiNow Plus `de.uniflow.plus.monthly` | Einladung Stufe 5 | **Kostenlos** | 1 Monat | `product=plus, tier=5` |
| StudiNow Plus `de.uniflow.plus.monthly` | Einladung Stufe 10 | **Kostenlos** | 3 Monate | `product=plus, tier=10` |
| StudiNow Plus `de.uniflow.plus.monthly` | Einladung Stufe 20 | **Kostenlos** | 12 Monate | `product=plus, tier=20` |
| StudiNow Pro AI `de.uniflow.proai.monthly` | Einladung Stufe 20 | **Pay as you go** (Monatspreis 1,99 €) | 12 Monate (12 Zahlungen) | `product=pro_ai, tier=20` |

Die Stapel als `.txt`/`.csv` exportieren (ein Code je Zeile) und hochladen, z. B.:

```
curl -X POST https://app.<domain>/api/billing/offer-codes -H "Authorization: Bearer <Admin-Token>" \
     -H "Content-Type: application/json" \
     --data "{\"product\": \"plus\", \"tier\": 5, \"text\": $(python3 -c 'import json,sys;print(json.dumps(open(sys.argv[1]).read()))' plus-5.txt)}"
```

Vorrat prüfen: `GET /api/billing/offer-codes` oder `GET /api/invites` als Admin (`stock_warning` nennt Stufen mit
weniger als 5 freien Codes). Ist eine Stufe leer, antwortet `claim` mit 409 und die App bittet, es später erneut zu
versuchen; die Stufe bleibt einlösbar. Abgelaufene Stapel (Apple-Laufzeit vorbei) lassen sich nicht erkennen – vor dem
Ablauf neue Codes hochladen und die alten in der Datenbank entfernen (`DELETE FROM offer_codes WHERE assigned_to IS NULL AND uploaded_at < …`).

`deploy/.env`: `LERNAPP_APPLE_APP_ID=<Apple-ID der App>` (App Store Connect → App-Informationen → Apple-ID), damit
der Dienst die Einlöse-Adresse liefert.

## 6. Apple Developer und App: Universal Links und QR

- **Associated Domains** in Apple Developer für die App-ID `de.uniflow.ai` einschalten; in der App steht
  `com.apple.developer.associated-domains = applinks:studinow.app` (`UniFlow.entitlements`, wirkt nur mit
  `CODE_SIGN_ENTITLEMENTS` aus `Config/Team.xcconfig`). In `project.yml` ist nichts einzutragen (die Berechtigungen
  kommen nur über die Entitlements-Datei, wie „Mit Apple anmelden“); Xcode zeigt die Fähigkeit nach `xcodegen generate`.
- **Website:** `site/.well-known/apple-app-site-association` (erzeugt von `tools/gen-site.py`, Team-ID aus
  `apps/apple/Config/Team.xcconfig`, sonst `[[TEAMID]]`) muss unter `https://studinow.app/.well-known/apple-app-site-association`
  ohne Weiterleitung und als `application/json` erreichbar sein (Cloudflare Pages/Netlify: Kopfzeile per `_headers`-Datei
  setzen). Apple holt die Datei über sein CDN; Änderungen brauchen bis zu einem Tag.
- Ohne Associated Domains öffnet der Link die Einladungsseite im Browser; die App nimmt den Code dann über den QR-Code
  „App-Code“ (`uniflow://invite/<CODE>`, `CFBundleURLSchemes` `uniflow`) oder über den erneut geöffneten Link entgegen.
  Der Code wird auf dem iPad gemerkt (`uniflow.invite.pending`), bis ein StudiNow-Konto angemeldet ist, und dann einmal
  eingelöst (`StudoraAccountLink.redeemPendingInvite`).
- Die Einladungsseite `docs/release/EINLADUNG.md` nennt keine KI-Funktionen (Regel in `docs/release/README.md`); nur
  den Produktnamen „StudiNow Pro AI“ in der Stufentabelle.

## 7. Oberfläche (iPad)

Einstellungen → Zugang & Darstellung → Karte **„Freunde einladen“** (nur mit Dienst-Adresse). Ohne angemeldetes
Konto: „Einladungen brauchen dein StudiNow-Konto“. Mit Konto öffnet der Knopf die Seite: Zähler „7 von 20 angekommen“
mit Fortschritt zur nächsten Stufe, die drei Belohnungen mit Stand (erreicht / eingelöst / „Belohnung einlösen“, bei
Stufe 20 die Wahl Plus gratis oder Pro AI zum Plus-Preis), die Links mit „Teilen“ (System-Blatt: Nachrichten, AirDrop,
Kopieren) und „QR-Code“ (Link oder App-Code, auch als PNG teilbar), „Neuer Einladungslink“ (nur im Fenster). Nach dem
Einlösen ein Blatt mit dem Code, „Code kopieren“ und „Bei Apple einlösen“.

## 8. Offene Punkte

- **Seit 05.11.2026 gibt es die Seite in Web und Windows** (`#/einladungen`, Abschnitt 10), aber **ohne Belohnungen**: für
  Stripe-Gutscheine fehlt weiter die Entscheidung des Inhabers (Abschnitt 9).
- Angebotscodes mit abgelaufener Apple-Laufzeit erkennt der Dienst nicht (Abschnitt 5).

## 9. Web und Windows: warum keine Oberfläche, und der Vorschlag für eine Dienstfassung (05.11.2026, nicht gebaut)

**Stand.** Die Regeln (Abschnitt 1 und 2) laufen schon im Dienst (`app/invites.py`, Endpunkte Abschnitt 4), für jedes
StudiNow-Konto, auch eines, das nur im Browser arbeitet. Die Oberfläche („Freunde einladen“) gibt es nur auf dem iPad.
Auf **Web und Windows ist sie bewusst nicht gebaut**:

- Die Belohnung ist ein **Apple-Angebotscode** (Abschnitt 3). Wer nur Web oder Windows hat, kann ihn nicht einlösen
  (Apples Dialog braucht ein Apple-Gerät mit App Store). Eine Seite, die Belohnungen verspricht, die man nicht bekommt,
  wäre unehrlich.
- Die **Windows-App im Einzelplatz** hat kein StudiNow-Konto (`mode: local`), also weder Links noch Einlösungen; Konten
  gibt es nur im Dienst, und die Windows-Fassung zeigt keine Kaufwege und keine Werbung für Bezahlsysteme
  (Microsoft-Store-Regeln, `docs/release/MICROSOFT-STORE.md`). Ein Einladungsabschnitt mit Gratis-Monaten wäre dort
  eine Kaufanreiz-Fläche; die Altersangabe des Stores nennt „keine Kaufanreize“.
- Der Weg „Link teilen“ klappt auf Web ohnehin: `https://studinow.app/i/<CODE>` führt zur Seite mit den Store-Links;
  das Konto der eingeladenen Person löst den Code erst auf dem iPad ein (`POST /api/invites/redeem`).

**Was eine Dienstfassung für Web/Windows bräuchte** (Vorschlag, wenn der Inhaber sie will):

1. **Belohnung, die ohne Apple geht:** Stripe-Gutscheine (Coupon/Promotion Code) statt Apple-Codes. Plus gratis wäre ein
   Gutschein „100 % für n Monate“ (`duration: repeating`, 1/3/12), „Pro AI zum Plus-Preis“ ein Gutschein „2,00 € Rabatt für
   12 Monate“ auf den Pro-AI-Preis. Der Dienst legt sie **bei Bedarf über die Stripe-API an** (kein Vorrat wie bei Apple,
   darum entfällt `409 offer_codes_exhausted`); die Einlösung läuft im Stripe-Checkout (`allow_promotion_codes` oder
   `discounts` fest am Konto). Es bleibt dabei: StudiNow schaltet nie selbst einen Tarif frei, der Tarif entsteht erst
   durch das Abo bei Stripe (Webhook, `app/stripe_billing.py`).
2. **Datenmodell:** `invite_rewards` bekommt `channel` (`apple` | `stripe`) und `stripe_promotion_id`; `offer_codes`
   bleibt für Apple unverändert. Die Wahl in Stufe 20 (Plus gratis oder Pro AI zum Plus-Preis) bleibt dieselbe, nur der
   Kanal hängt am Konto: hat es ein Stripe-Abo oder noch keins und arbeitet im Web, `stripe`; hat es Apple-Käufe, `apple`.
   Ein Konto darf nicht beides für dieselbe Stufe holen (heute schon: eine Belohnung je Konto und Stufe).
3. **Missbrauchsschutz** (heute: Fenster in der Probe, 20 Links, eine Einlösung je Konto, nur neue Konten, Ratenbegrenzung
   `invite_create_user`): zusätzlich **bestätigte E-Mail-Adresse** des eingeladenen Kontos als Bedingung für „angekommen“
   (sonst reichen Wegwerf-Adressen für Stufe 5/10/20), Zählung erst nach **echter Nutzung** (z. B. eine Hochschul-Anmeldung
   oder 1 Tag nach dem Anlegen), Ablehnung bekannter Wegwerf-Domains, höchstens eine Einlösung je Gerät/IP-Bereich und
   Tag, Belohnung nur an Konten mit bestätigter E-Mail, Gutscheine nur einmal je Stripe-Kunde (`max_redemptions: 1`,
   `customer`), Obergrenze der vergebenen Gratis-Monate je Monat im Betrieb (Notbremse), Protokoll im Betrieb.
4. **Kosten:** Plus kostet im Dienst wenig (eigenes ChatGPT, nur 4 neue KI-Tests im Monat): 12 Gratis-Monate sind vor
   allem entgangene Einnahmen von ca. 1,39 € netto je Monat. **Pro AI zum Plus-Preis** kostet echtes Geld: bis zu 100 Credits (1 €) KI je
   Monat und der Anteil an der Bibliothek (`docs/PREISLISTE.md`) bei 1,42 € Einnahme nach Apple bzw. 1,39 € nach Stripe;
   bei 12 Monaten also bis zu 12 € je Belohnung gegen 12 × ca. 1,4 € Einnahme. Darum eine Obergrenze je Monat und
   Benachrichtigung des Betriebs, bevor ein Gutschein ausgegeben wird, der mehr KI verspricht als bezahlt.
5. **Oberfläche (erst danach):** Seite „Freunde einladen“ nur im Dienst und nur im Browser (nicht in der Windows-App,
   siehe oben), Zähler, Links, Teilen (Kopieren, Web-Share), QR; keine Erinnerungen, kein Zwang (wie auf dem iPad).
6. **Rechtliches:** Nutzungsbedingungen Abschnitt „Einladungen und Belohnungen“ (Wer bekommt was, Ablauf der Links,
   Missbrauch führt zum Verlust der Belohnung), Datenschutz (Einlösungen enthalten nur Code und Zeitpunkt, Abschnitt 1).

Entscheidung des Inhabers nötig: Soll es Einladungen für Web-Konten überhaupt geben, und darf Pro AI zum Plus-Preis über
Stripe vergeben werden (Kosten wie in Punkt 4)?


## 10. Web und Windows: Seite ohne Belohnung (05.11.2026, Auftrag „Ja, alle schließen“)

Der Inhaber hat am 05.11.2026 entschieden, die Lücken von Windows gegenüber dem iPad zu schließen. Gebaut ist die Seite
**„Freunde einladen“** (`#/einladungen`, Einstellungen → Zugang & Darstellung → Karte „Freunde einladen“, nur mit
StudiNow-Konto): Zähler der angekommenen Personen, Links mit „Teilen“ (Teilen-Menü des Systems, sonst Kopieren),
„Kopieren“ und „QR-Code“ (Link oder App-Code `uniflow://invite/<CODE>`, als SVG im Browser erzeugt, kein fremder Dienst:
`app/static/qr.js`, gegen Apples QR-Leser geprüft), „Neuer Einladungslink“ nur im Fenster der Probewoche. Die Windows-App
reicht die vier Endpunkte des Kontos mit dessen Token an den Dienst weiter (`invites_api._forward`); der Vorrat (Admin)
bleibt nur im Dienst.

**Keine Belohnungen auf dieser Seite**, solange der Inhaber Abschnitt 9 nicht entschieden hat: keine Stufen, kein
„Belohnung einlösen“, nur der Satz, dass es Belohnungen bisher nur als App-Store-Code in der iPad-App gibt
(`invites-logic.js`: `WEB_REWARDS = false`). Wer Einladungen auch am PC zählt, löst eine erreichte Stufe weiter auf dem
iPad ein (gleiches Konto). Entscheidet der Inhaber für Stripe-Gutscheine, kommen Datenmodell und Missbrauchsschutz aus
Abschnitt 9 dazu, danach `WEB_REWARDS = true` mit Stufenanzeige.

Tests: `tests/test_invites_pc.py` (Weiterleitung, Fehler des Dienstes unverändert, kein Vorrat am PC),
`tests/js/invites.test.mjs`, `tests/js/qr.test.mjs`.

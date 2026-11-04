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

- Web und Windows haben noch keine Einladungsseite (die Endpunkte gelten für alle Clients; Belohnungen sind Apple-Codes,
  für Stripe gäbe es Gutscheine – nicht entschieden).
- Angebotscodes mit abgelaufener Apple-Laufzeit erkennt der Dienst nicht (Abschnitt 5).

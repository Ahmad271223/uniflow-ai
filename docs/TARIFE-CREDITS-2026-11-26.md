# Tarife und Credits ab 26.11.2026 (Entscheidung des Inhabers)

Zweig `tarif/credits-neu` (von `release/1.0.8-alles` @ 52ff61a3), Worktree `~/Studora-Builds/wt-tarife-neu`.
Website dazu: Zweig `site/tarife-neu` (von `site/1.0.8-rechtstexte`), Worktree `~/Studora-Builds/wt-site-tarife` –
erst online stellen, wenn die App mit dem neuen Modell im Store ist.

## Was verkauft wird

| Tarif | Preis (inkl. USt) | Apple-Produkt | Inhalt |
|---|---|---|---|
| StudiNow Free | 0 € | – | wie bisher |
| StudiNow Plus | 1,99 € im Monat | `de.uniflow.plus.monthly` (Auto-Abo, gibt es schon) | alle Funktionen ohne KI (alles, was früher Pro AI hatte) |
| StudiNow Plus | 39,99 € einmalig für 5 Jahre | `de.uniflow.plus.fuenfjahre` (**neu anlegen**, „Nicht verlängerndes Abo“) | wie Plus; endet 5 Jahre nach dem Kauf von selbst |
| StudiNow Pro AI | 39,99 € im Jahr | `de.uniflow.proai.yearly` (gibt es schon) | Plus + 120 Credits je Monat, am 1. neu |
| KI-Credits | 80 für 1,99 €, 160 für 3,99 € | `de.uniflow.credits.klein` / `.gross` (gibt es schon) | kaufen nur Plus und Pro AI (bezahlt), nicht Free, nicht die Probe allein |

Nicht mehr verkauft, gilt weiter: `de.uniflow.plus.yearly` (19,99 €/Jahr) → Plus, `de.uniflow.proai.monthly` → Pro AI.

## Regeln

- **StudiNow-KI nur mit Credits** (Erklärungen, Zusammenfassungen, Lernfragen, KI-Tests, KI-Karteikarten, KI-Chat,
  KI-Mail, fertige Wochenfragen): Rechte mit `needs_credits` in `app/plans.py`; `app/entitlements.py` `has` prüft
  zusätzlich `credits.balance(...)["available"] > 0`; ohne Credits antwortet `require` mit 429 `credits_exhausted`.
- **Immer ohne Credits:** WhisperKit-Mitschrift (auf dem Gerät) und KI über den eigenen OpenAI-Schlüssel des Nutzers
  (Inhaber: „Eigenes ChatGPT frei“).
- **Probe:** 7 Tage Plus + 25 Credits (`plans.TRIAL`, `plans.CREDITS["trial"]`). Probe + bezahltes Plus bleibt Probe
  (`ai_backend._paid_ai` zählt nur Tarife mit Monats-Credits).
- **5 Jahre bei Apple:** Apple nennt kein Ende; `apple_store.apply_transaction` rechnet `plans.offer_end` (Kauf + 5 Jahre)
  und speichert unter der Quelle `app_store_once`, damit ein Monatsabo daneben es nie überschreibt.
- **Stud.IP-Abgabe aus** (Inhaber: „erstmal ausschalten“): `StudIPSubmitEntry.isEnabled = false` (App),
  `STUDIP_SUBMIT_ON = false` in `app/static/editor.js` (Windows). Code bleibt.
- **Rechtstexte:** Abschnitt 4 (keine Zusammenarbeit mit der LUH, Anbindung nicht zugesichert, Sperre kein Grund für
  Rückerstattung „soweit das Gesetz nichts anderes zwingend vorschreibt“), Abschnitt 5/5a neu, Datenschutz 8c/9.
  Vor dem Kauf zeigt die App denselben Hinweis (§ 327h BGB). Anwalt soll beides prüfen.

## Offen (nur mit Okay des Inhabers)

- Apple: `de.uniflow.plus.fuenfjahre` anlegen (39,99 €), `de.uniflow.plus.monthly` wieder zum Verkauf freigeben
  (1,99 €), Jahres-Plus aus dem Verkauf nehmen, Store-Texte.
- Server-Deploy (Tarife, KI nur mit Credits, 120 Credits) zusammen mit der App; vorher `LERNAPP_CREDITS_PRO_AI` in
  `deploy/.env` prüfen (überschreibt sonst die 120).
- Stripe (Web/Windows): Preis-ID für Plus monatlich in `LERNAPP_STRIPE_PRICES`; die 5 Jahre gibt es dort noch nicht
  (nur in der Apple-App).
- ~~Einladungs-Belohnung~~ entschieden 27.11.2026: **keine Belohnungen mehr** (Inhaber: „gar keine mehr, entnimm das
  komplett“, auf Nachfrage „Alle Belohnungen weg“). `app/invites.py` `TIERS = ()`, Einlösen/Hochladen 410
  `invite_rewards_off`; App `InviteRewards.tiers = []`, Stufen-Karte und Fortschritt verborgen; Web ohne Hinweis;
  Einladungsseite `/i/` ohne Tabelle (auch in `site/tarife-neu`). Links, QR-Code, Teilen und Zähler bleiben. Ältere
  Store-Apps zeigen nach dem Deploy keine Stufen mehr (der Dienst liefert `tiers: []`), Einlösen ergibt die 410-Meldung.

## Stand 27.11.2026 (für die Build-Sitzung)

Alles uncommittet im Worktree `wt-tarife-neu` (Zweig `tarif/credits-neu`), nichts gepusht, nichts deployt, nichts bei Apple.

- **Dienst:** volle Suite 4146 grün, 6 rot → danach 2 behoben (veraltete Tests). Rest: 3 schon auf `release/1.0.8-alles`
  rot (`test_audit_p58_87_golive` p82 ×2, p84_03) ; der Einladungstext ist seit 27.11. behoben.
- **App (`apps/apple`, 81 Dateien + 2 neue Testdateien):** UniFlowCore `swift test` 1925 Tests, 0 Fehler. iPad-Tests
  (Simulator „Tarife iPad“ FAC0C610-…, DerivedData `~/Studora-Builds/dd-tarife-neu`, signiert) klassenweise grün bis auf
  `StoreScreenshotTests.test01Uebersicht` („Diese Prüfungen solltest du anmelden“ fehlt, vermutlich datumsabhängig, gegen
  den Ausgangsstand nicht geprüft). Kein Gesamtlauf in einem Stück, nichts von Hand im Simulator angesehen (Kaufseite mit
  Haken, 5-Jahres-Knopf, iPhone, Mac).
- **Website:** `site/tarife-neu` (wt-site-tarife), 27 Tests grün. LUH-Absatz allein für die Live-Seite als Patch
  `~/Studora-Builds/luh-absatz-2026-11-26.patch` (7 Dateien, `git apply --check` ok).
- **Noch offen in der App:** toter
  Nur-Chat-Code (`ufAIChatOnly`, `StudiNowChatAI`, `CreditText.chatOnly`); Schrittnamen in
  `fixtures/credit-packs/contract.json` noch alt („bleibt Pro AI (403)“, die Antwort ist jetzt 429).
- **Fragen an den Inhaber:** Texte des Hinweises vor dem Kauf; nach einer 429-Antwort sperrt die App die KI bis zum nächsten
  Stand vom Dienst; 5-Jahres-Kauf wird neben einem laufenden Monatsabo angeboten (mit „danach kündigen“), neben Pro AI nicht.

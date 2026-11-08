# Windows 1.0: Abnahme und Prüfliste für den Inhaber (Stand 08.11.2026)

Auftrag: „Die Windows-Version komplett fertig machen.“ Umgesetzt auf dem Zweig `windows/1.0` (von `develop`
abgezweigt, `develop` unverändert – die iPad-App 1.0 liegt bei Apple in der Prüfung). Alles, was ohne Windows-PC geht,
ist gebaut und mit Tests abgesichert; was einen echten Windows-Rechner oder Zugangsdaten des Inhabers braucht, steht hier
als Prüfliste. Die Punkte entsprechen der Analyse vom 08.11.2026.

## 1. Was auf dem Zweig fertig ist

| Punkt | Stand | Wo |
|---|---|---|
| 1 „Nur LUH“ auch in Web und Windows-App | **fertig** – Schalter `LERNAPP_SHIPPED_UNIVERSITIES` (Standard `luh` im Dienst und in der Windows-App, `all` in Entwicklung und Tests). Hochschulwahl bei Registrierung, Erststart und Einstellungen zeigt nur die ausgelieferten mit „Weitere Hochschulen folgen mit einem Update.“; Registrierung und Wechsel zu Hildesheim/HsH werden abgelehnt (`university_not_shipped`). | `app/universities.py` (`shipped`, `choices`, `more_note`), `app/account_api.py`, `app/server.py`, `login.js`, `onboarding.js`, `views-misc.js`, `tests/test_shipped_universities.py` |
| 2 „Mit ChatGPT anmelden“ aus, eigener OpenAI-Schlüssel | **fertig** – Sign in with ChatGPT liegt hinter `LERNAPP_CHATGPT_SIGNIN=1` (aus, wie `ChatGPTLink.isEnabled` auf dem iPad); Karten dazu verschwinden. Neu: Einstellungen → Erweitert → „Eigenes ChatGPT (OpenAI-API-Schlüssel)“ nur in der Windows-App/am PC: Schlüssel in der Windows-Anmeldeinformationsverwaltung (DPAPI; am Mac Datei 0600), Einwilligungstext wie `OpenAIKeyLink.consentText`, Prüfung gegen `GET /v1/models`, Standardmodell `gpt-4o-mini`, Weg der KI: Geteiltes → eigener Schlüssel → StudiNow-KI. Im Web kein eigener Schlüssel. „Hochschul-Konto entfernen“ löscht den Schlüssel mit. | `app/openai_key.py`, `app/chatgpt_login.py` (`ENABLED_ENV`), `app/ai.py`, `app/ai_relay.py`, `views-misc.js`, `views-abo.js`, `ai-panel.js`, `openai-key-logic.js`, `tests/test_openai_key.py`, `tests/js/openai-key-logic.test.mjs` |
| 3 Jahresabos bei Stripe | **fertig im Code, offen beim Inhaber (Preise in Stripe anlegen)** – `LERNAPP_STRIPE_PRICES` kennt `plus_yearly=…`, `pro_ai_yearly=…` (auch `de.uniflow.plus.yearly=…`, `de.uniflow.proai.yearly=…`); Checkout und `plan-choice` mit `interval: month|year`; Windows-Checkout reicht den Zeitraum durch; Abo-Seite mit Umschalter Monatlich/Jährlich (21,99 € bzw. 41,99 € aus `app/plans.py`, der Vertrag `plans.json` kannte sie schon). Ohne Jahrespreis bei Stripe gibt es den Knopf nur monatlich. | `app/stripe_billing.py`, `app/billing_api.py`, `app/account_mode.py`, `abo-logic.js`, `views-abo.js`, `tests/test_trial_stripe.py` (Jahresabos), `tests/test_account_mode.py`, `tests/js/abo-logic.test.mjs` |
| 4 Credit-Texte | **fertig** – Nutzungsbedingungen (und Website) „rund einem Cent (0,9 Cent)“, Abo-Seite „1 Credit ≈ 0,9 Cent KI-Kosten“. | `docs/release/NUTZUNGSBEDINGUNGEN.md`, `site/nutzungsbedingungen.html`, `views-abo.js` |
| 5 `store.json` | **Platzhalter markiert, Werte nur Inhaber** – siehe Abschnitt 2. Test erzwingt: Platzhalter solange `store_ready=false`, echte Werte sobald `true`. | `apps/windows/msix/store.json`, `tests/test_windows_package.py` |
| 6a „Passwort speichern“ am Anmeldefenster | **fertig (nur lokal, verschlüsselt)** – Haken „Passwort auf diesem PC speichern“ in Einstellungen → Zugang bei der Stud.IP-Anmeldung (LUH): LUH-ID und WebSSO-Passwort liegen DPAPI-verschlüsselt in der `.env` des Datenordners, nie auf dem Server; StudiNow meldet sich damit bei QIS und Uni-Mail selbst an. Das Anmeldefenster (WebView2) selbst kann kein „Passwort speichern?“ anbieten – siehe Abschnitt 3. | `views-misc.js`, `app/local_secrets.py`, `app/config.py` |
| 6b QIS-Passwort unverschlüsselt | **fertig** – alle `*_PASSWORD`, `*_COOKIES`, `*_TOKEN` in der `.env` der Windows-App per DPAPI (`dpapi:…`), Altbestand wird beim ersten Start umgestellt (Protokolleintrag), Lesen entschlüsselt. Am Mac/in Tests AES-GCM mit Schlüsseldatei. | `app/local_secrets.py`, `app/config.py` (`set_env`, `_env`), `app/desktop.py`, `tests/test_local_secrets.py` (DPAPI-Roundtrip läuft im Windows-Workflow) |
| 6c WebView2 nicht im Paket | **soweit möglich fertig** – NSIS-Installer lädt die Laufzeit ausdrücklich nach (`webviewInstallMode: downloadBootstrapper`); das Fenster prüft beim Start `tauri::webview_version()` und öffnet sonst Microsofts Download-Seite. Ein MSIX kann WebView2 nicht mitbringen; Windows 10 ab 21H2 und Windows 11 haben es. | `apps/windows/src-tauri/src/main.rs`, `tauri.conf.json`, `tests/test_windows_package.py` |
| 7 Paket bauen | **nur in GitHub Actions** (kein Rust/Windows auf dem Mac): der Workflow `windows.yml` läuft jetzt auch bei jedem Push auf `windows/**` und legt `uniflow-windows` (Installer) und `uniflow-windows-msix` (Store-Paket) als Artefakte ab. | `.github/workflows/windows.yml` |

## 2. Partner Center: die drei Werte für `apps/windows/msix/store.json`

Partner Center → Apps und Spiele → StudiNow → Produktverwaltung → **Produktidentität**. Von dort kopieren:

| Feld in `store.json` | Partner Center | Form |
|---|---|---|
| `identity_name` | `Package/Identity/Name` | z. B. `12345ITsolutionsbyAhmadFakih.StudiNow` (Buchstaben, Ziffern, Punkte) |
| `publisher` | `Package/Identity/Publisher` | beginnt mit `CN=`, danach eine GUID-ähnliche Kennung |
| `publisher_display_name` | `Package/Properties/PublisherDisplayName` | Anzeigename des Herausgebers, z. B. `IT solutions by Ahmad Fakih` |

Danach `store_ready` auf `true` setzen (der Test `tests/test_windows_package.py` prüft, dass keine Platzhalter mehr drin
sind), pushen, Lauf abwarten, `StudiNow_<version>.0_x64.msix` aus dem Artefakt `uniflow-windows-msix` hochladen. Vorher
den Namen „StudiNow“ reservieren (er muss `display_name` entsprechen). Weitere Pflichtangaben der Einreichung:
Datenschutzerklärung-URL (`https://studinow.app/datenschutz`), Screenshot 1366 × 768, Altersfreigabe, Prüfhinweis mit
Demo-Konto (Einstellungen → Erweitert → Demo-Inhalte) – `docs/release/MICROSOFT-STORE.md`.

## 3. Prüfliste auf einem echten Windows-PC (Inhaber, je 10–20 Minuten)

Installer bzw. `…-test.msix` aus dem Lauf des Zweigs `windows/1.0` (Actions → Windows) nehmen.

1. **Frischer PC ohne Python:** Installer starten (SmartScreen „Trotzdem ausführen“), App startet, Anmeldebildschirm des
   StudiNow-Kontos erscheint. Auf einem alten Windows 10 ohne WebView2: statt der App öffnet sich Microsofts
   WebView2-Download-Seite; nach dem Installieren startet die App.
2. **Hochschulwahl:** Erststart zeigt nur „Leibniz Universität Hannover“ und den Hinweis „Weitere Hochschulen folgen
   mit einem Update.“ Einstellungen → Zugang → Hochschule ebenso.
3. **Passwort speichern:** Einstellungen → Zugang → Haken „Passwort auf diesem PC speichern“ → LUH-ID und
   WebSSO-Passwort eintragen. Dann `%LOCALAPPDATA%\de.uniflow.desktop\.env` öffnen: `STUDIP_PASSWORD="dpapi:…"`,
   kein Klartext. Noten (QIS) und Uni-Mail laden ohne Nachfrage. Haken abwählen → Zeile verschwindet.
4. **Altbestand:** auf einem PC mit alter `.env` (Klartext-Passwort) die neue Fassung starten; `logs\backend.log` nennt
   „Geheimnis(se) in der .env verschlüsselt (dpapi)“, Abgleich läuft weiter.
5. **Eigener OpenAI-Schlüssel:** Einstellungen → Erweitert → Schlüssel eintragen, Einwilligung anhaken, „Speichern und
   prüfen“ → Badge „aktiv · geprüft“, Modell `gpt-4o-mini` vorgewählt. Windows-Anmeldeinformationsverwaltung
   (`control /name Microsoft.CredentialManager` → Windows-Anmeldeinformationen) zeigt `StudiNow/openai-schluessel`.
   Im Editor eine Frage stellen: Kopfzeile „über deinen OpenAI-Schlüssel · 0 Credits“. Keine Karte „KI über mein
   ChatGPT“ mehr. „Schlüssel entfernen“ löscht den Eintrag; „Hochschul-Konto entfernen“ ebenfalls.
6. **Abo:** Abo & Tarife → Umschalter „Monatlich/Jährlich“ zeigt 1,99 €/21,99 € und 3,99 €/41,99 €. „Abschließen“ bei
   „Jährlich“ öffnet Stripe mit dem Jahrespreis (erst nachdem die Jahrespreise bei Stripe eingetragen sind, Abschnitt 4);
   vorher steht dort „Jährliche Zahlung folgt – monatlich ist möglich.“
7. **Zweiter Start, Schließen, Deinstallieren** wie in `docs/FERTIGSTELLUNG-WINDOWS-UND-DIENST.md` Abschnitt 5.
8. **Noch offen (braucht Rust-Bau mit WebView2-API):** „Passwort speichern?“ *im* Anmeldefenster der Hochschule.
   WebView2 bietet es erst an, wenn die App `ICoreWebView2Settings4::IsPasswordAutosaveEnabled` setzt (Crate
   `webview2-com`, Version passend zu Tauris `wry`). Ohne Windows-Rechner nicht kompilierbar geprüft, darum nicht
   eingebaut; Ersatz ist Punkt 3 (gespeichertes Passwort für QIS/Uni-Mail, Sitzung des Anmeldefensters bleibt im
   WebView2-Profil erhalten).

## 4. Was der Inhaber eintragen muss

| Wo | Was | Wirkung |
|---|---|---|
| **Partner Center** | die drei Werte aus Abschnitt 2 in `store.json`, `store_ready: true`; Name reservieren; Datenschutz-URL, Screenshot, Altersfreigabe, Prüfkonto mit Abo | Store nimmt das MSIX an |
| **Stripe** | zwei weitere Preise anlegen: Plus **21,99 €/Jahr** und Pro AI **41,99 €/Jahr** (wiederkehrend, jährlich); dann in `deploy/.env` `LERNAPP_STRIPE_PRICES=plus=price_…,pro_ai=price_…,plus_yearly=price_…,pro_ai_yearly=price_…`; Dienst neu starten | Umschalter „Jährlich“ bekommt Kaufknöpfe; Webhook ordnet Jahresabos dem Tarif zu |
| **Dienst (`deploy/.env`)** | `LERNAPP_SHIPPED_UNIVERSITIES` leer lassen (= nur LUH) oder später `luh,hildesheim`; `LERNAPP_CHATGPT_SIGNIN` nicht setzen (bleibt aus, bis OpenAI freigibt) | Hochschulwahl und ChatGPT-Karte folgen den Schaltern ohne neuen Build |
| **Apple (Services ID)** | für „Mit Apple anmelden“ im Web und im Browser-Login der Windows-App: Services ID (z. B. `app.studinow.web`) mit Domain `app.studinow.app` und Return-URL `https://app.studinow.app/login` anlegen, in `deploy/.env` `LERNAPP_APPLE_WEB_CLIENT_ID=<Services ID>` und zusätzlich in `LERNAPP_APPLE_CLIENT_IDS` | Apple-Anmeldung in Web/Windows funktioniert; ohne Eintrag bleibt der Knopf aus, E-Mail/Passwort geht |
| **Microsoft Store-Regeln** | prüfen, ob der eigene Zahlungsweg (Stripe im Systembrowser) für diese App-Kategorie zulässig ist | Vermeidet Ablehnung bei der Zertifizierung |

## 5. Tests

Alle auf `windows/1.0`: `pytest` komplett grün (siehe Bericht der Sitzung), `node --test tests/js/*.test.mjs` grün. Neu:
`tests/test_shipped_universities.py`, `tests/test_openai_key.py`, `tests/test_local_secrets.py` (DPAPI-Teil nur auf
Windows), Jahresabo-Tests in `tests/test_trial_stripe.py` und `tests/test_account_mode.py`, `store.json`- und
WebView2-Tests in `tests/test_windows_package.py`, `tests/js/openai-key-logic.test.mjs`, `tests/js/abo-logic.test.mjs`.
Der Windows-Workflow führt `tests/test_local_secrets.py` blockierend aus (DPAPI-Roundtrip auf dem Runner).

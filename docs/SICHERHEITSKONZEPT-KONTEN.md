# Sicherheitskonzept: Benutzerkonten, Abos, KI-Kontingente (vorläufige Architektur)

Stand 26.10.2026. **Entschieden** (Vorgabe vom 25.10.): Stud.IP-Login und Hochschulpasswörter bleiben auf dem Gerät
der Studierenden; der zentrale UniFlow-Server erhält keine Stud.IP-Passwörter; Konten, Abos und KI-Kontingente werden
getrennt verwaltet; kein Hosting gebucht. Nichts davon ist produktiv umgesetzt oder migriert.
**Neu entschieden (Inhaber, 27.10.2026, ersetzt die Regel vom 25.10.):** Hochschul-Passwörter merkt sich nur das System
(iOS-Passwort-Autofill bzw. iCloud-Schlüsselbund im Anmeldefenster, auf Android der Passwort-Manager des Systems), **nie
die App selbst**. Die App speichert weder Benutzername noch Passwort und füllt nichts per Skript aus; „Anmelden“ tippt
immer der Mensch (Abschnitt 1a).

## 1. Komponenten und Vertrauensgrenzen

```
 Gerät (iPad / PC)                                   Zentraler UniFlow-Dienst (später, gehostet)
 ┌──────────────────────────────────────┐            ┌────────────────────────────────────────┐
 │ Stud.IP-Anbindung (OAuth2 bzw. WebSSO)│──HTTPS──►  │ Konten: Anmeldung, Sitzungen, Löschung │
 │  - Tokens/Cookies nur im Schlüsselbund│            │ Abos: App-Store-Transaktionen prüfen   │
 │  - Dateien, Termine lokal             │            │ KI-Kontingente: Zählung, Abrechnung    │
 │ Notizen (Journal, PencilKit)          │──HTTPS──►  │ Notiz-Sync (optional, Ende-zu-Ende?)   │
 │ KI-Anfragen ohne Rohdaten-Konten      │──HTTPS──►  │ KI-Gateway → Anthropic-API             │
 └──────────────────────────────────────┘            └────────────────────────────────────────┘
        ▲ nie: Stud.IP-/LUH-Passwort, Stud.IP-Tokens an den Dienst
```

| Daten | Wo | Schutz |
| --- | --- | --- |
| Hochschul-Passwort (LUH-ID für Stud.IP/WebSSO, QIS, UNI-Account Hildesheim/CAS) | Eingabe auf der Anmeldeseite der Hochschule; gemerkt **nur vom System** (iOS-Passwort-Autofill, Schlüsselbund bzw. iCloud-Schlüsselbund), nie von der App (Abschnitt 1a) | die App liest, speichert und füllt es nicht; nie an einen Server, nie im Protokoll; bei OAuth2 (später) sieht die App es gar nicht |
| Learnweb-Schlüssel (Moodle-Mobile-SSO, Uni Hildesheim) | Gerät, Schlüsselbund `de.uniflow.ai.university` (`<nutzer>.hildesheim.learnweb.token`) | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, nicht synchronisiert; nie an den Dienst |
| Stud.IP-Zugriffstoken / Session-Cookie | Gerät, Schlüsselbund (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) | nicht in Backups, nicht an den Dienst |
| Vorlesungsdateien | Gerät | Dateischutz `completeUntilFirstUserAuthentication` |
| Notizen | Gerät; optional Dienst | Transport TLS; Speicherung beim Dienst nutzergetrennt |
| Konto (E-Mail, Passwort-Hash) | Dienst | Argon2id, Sitzungstokens nur als Hash |
| Abo-Status | Dienst (Quelle: App Store) | nur über signierte Transaktionen änderbar |
| KI-Kontingent | Dienst | atomare Zählung (`app/billing.py`) |

## 1a. Hochschul-Passwörter auf dem iPad: nur das System merkt sie (umgesetzt 27.10.2026, Entscheidung des Inhabers)

**Abgelöst:** Vom 25./26.10.2026 bis zur Fassung auf `wip/passwort-ios` merkte die App mit dem Schalter „Auf diesem iPad
merken“ Benutzername und Passwort selbst im Schlüsselbund (`<nutzer>.luh.studip.user/.password`, `….luh.qis.…`,
`….hildesheim.cas.…`) und füllte sie per Skript in einer eigenen `WKContentWorld` vor (`UniversityLoginAutofill`,
gebunden an die echte Navigation des Hauptrahmens; QIS fiel auf die LUH-ID aus Stud.IP zurück). Das gibt es nicht mehr.

Jetzt:
- **Anmeldefenster:** Die App öffnet die echte Anmeldeseite der gewählten Hochschule in einer `WKWebView`
  (`StudIPWebView`, Konfiguration `loginConfiguration`: nur der `WKWebsiteDataStore` des Containers). Keine
  Benutzerskripte, kein Nachrichtenkanal zur Seite, kein `evaluateJavaScript`/`callAsyncJavaScript` in Formulare, kein
  Eingriff in `autocomplete`. Das Formular ist genau die Seite der Hochschule; iOS bietet dort sein Passwort-Autofill aus
  dem Schlüsselbund bzw. iCloud-Schlüsselbund an (Schlüssel-Symbol über der Tastatur). Nach dem Laden liest die App
  höchstens den Seiteninhalt (`document.documentElement.outerHTML`), um eine angemeldete Seite oder den Fehlertext des
  CAS zu erkennen; eingetippte Werte stehen darin nicht.
- **Hinweis unter dem Fenster** (`UniversityLoginHint`, Stud.IP, QIS, CAS, erster Start und Einstellungen): „Passwörter
  merkt sich iOS (Schlüsselbund). Tippe auf das Schlüssel-Symbol über der Tastatur, um ein gespeichertes Passwort
  einzusetzen.“ Ehrlich: In Webansichten von Apps bietet iOS das **Sichern** oft nicht von selbst an; der Hinweis
  verspricht das nicht, sondern nennt „Passwörter“ (App unter iOS 18, Einstellungen unter iOS 17) zum Hinzufügen von Hand.
- **Was die App behält:** die Sitzung der Hochschule (Cookies im Webdaten-Speicher des Containers, Stud.IP-Sitzungs-
  Cookie im Dienst `de.uniflow.ai.studip`) und in Hildesheim den Learnweb-Schlüssel (`UniversityTokenStore`, Dienst
  `de.uniflow.ai.university`, `<nutzer>.hildesheim.learnweb.token`, `WhenUnlockedThisDeviceOnly`, nicht synchronisiert).
  Getrennt je Apple-Nutzer und Hochschule, kein Rückfall auf die andere Hochschule. Abmelden (Learnweb/LSF), „Daten
  dieser Hochschule löschen“ und „Konto löschen“ entfernen den Schlüssel; ein Passwort hat die App dabei nicht zu
  löschen. Was iOS gesichert hat, bleibt unter „Passwörter“ (das sagen die Rückfragen beim Abmelden und Konto löschen).
- **Bestandsnutzer:** `UniversityPasswordCleanup` löscht beim ersten Start der neuen Fassung (Anlegen von
  `ContainerManager`, erneut beim Öffnen eines Containers und beim Wechsel in den Vordergrund, falls der Schlüsselbund
  beim Start gesperrt war) alle
  Einträge `[<präfix>.]<hochschule>.<dienst>.user|password` im Dienst `de.uniflow.ai.university` – für alle Nutzer und
  Hochschulen dieses iPads, auch ohne Nutzer-Präfix (vor den Containern) und `u-ohne-anmeldung.…` – sowie die Schalter
  `uniflow.login.remember.…`. Erkennung im Kern (`UniversityProfile.isRetiredLoginSecret`). Learnweb-Schlüssel und
  Sitzungen bleiben. Erledigt (`uniflow.login.passwords.removed`) erst, wenn der Schlüsselbund danach sicher keinen
  solchen Eintrag mehr nennt (`KeychainStore.accountList`: gesperrt = nil, nicht „leer“). Der Umzug aus der Zeit vor den
  Containern nimmt gemerkte Zugangsdaten nicht mehr mit.
- **Neuinstallation:** unverändert. Der Schlüsselbund überlebt das Löschen der App, die UserDefaults nicht. Fehlt der
  Merker dieser Installation (`uniflow.login.installed`), leert die App den ganzen Dienst `de.uniflow.ai.university`,
  bevor sie etwas liest; gelingt das nicht (gesperrt), liest und speichert sie nichts und versucht es erneut. Ebenso die
  Stud.IP-Sitzungs-Cookies (`uniflow.studip.installed`). Konto und PIN (`de.uniflow.ai.app`) wie bisher; alle Dienste
  nutzen `KeychainStore`.
- **Nie an einen Server:** weder an den UniFlow-Dienst noch an den PC-Server; keine Protokollzeile, keine Adresse,
  keine Fehlermeldung enthält Passwort oder Schlüssel.

Grenzen und Risiken (ehrlich):
- Eingebettete Anmeldeseiten sind nach RFC 8252 §8.12 nur ein Übergang: Eine App könnte Eingaben in ihrer Webansicht
  technisch lesen. UniFlow tut es nicht (keine Skripte, Tests unten); Ziel bleibt OAuth2 mit
  `ASWebAuthenticationSession`, wo die Hochschule es anbietet.
- Ob iOS in der `WKWebView` das Sichern anbietet und gespeicherte Passwörter vorschlägt, entscheidet iOS (u. a.
  Einstellungen → Passwörter → „Automatisch ausfüllen“, Rechner der Seite); ohne Associated Domains der Hochschulen gibt
  es keine Zuordnung zur App. Am echten iPad zu prüfen.
- Eine kompromittierte Anmeldeseite selbst (XSS genau auf dem Anmeldepfad) kann ein eingetipptes oder von iOS
  eingesetztes Passwort lesen – wie in jedem Browser.
- Rechtlich: Die LUIS-Nutzungsordnung verlangt, das Passwort geheim zu halten; die App hinterlegt es nirgends. Die
  Anfrage „Passwort-Merken durch die App“ an die Hochschulen entfällt.
- Geprüft ohne echte Hochschulseiten (Regel: keine echten Anmeldungen): `UniFlowTests/UniversityLoginPolicyTests.swift`
  (echte `WKWebView` mit der Konfiguration der App und erfundenen Seiten, auch eingebettetes Fremdformular, fremde
  Rechner, http und eine Seite desselben Rechners mit `replaceState`/`pushState`: kein Feld gefüllt, `autocomplete`
  unverändert, kein Kanal, nach dem Absenden nichts im Schlüsselbund oder in den UserDefaults; die echten
  Anmeldeansichten Stud.IP, QIS und CAS/LSF mit den Nachbildungen des Debug-Stubs; Quellen ohne Skript-APIs),
  `UniversityTokenStoreTests.swift` (Learnweb-Schlüssel, einmalige Löschung auch bei gesperrtem Schlüsselbund, erster
  Start mit `ContainerManager`).

## 2. Bedrohungen und Maßnahmen

| Bedrohung | Maßnahme |
| --- | --- |
| Gestohlenes oder entsperrt liegengelassenes iPad | die App hat kein Hochschul-Passwort (das merkt nur iOS, geschützt durch Geräte-Code/Face ID beim Einsetzen); Learnweb-Schlüssel nur entsperrt lesbar (`WhenUnlockedThisDeviceOnly`); nie automatisch angemeldet; Abmelden/Konto löschen entfernt Sitzung und Schlüssel |
| Gefälschte Anmeldeseite (Phishing) in der Webansicht | die App füllt nirgends etwas aus und hat keinen Kanal zur Seite; der Hauptrahmen lädt nur HTTPS; welche gespeicherten Passwörter iOS vorschlägt, entscheidet iOS (am iPad prüfen) |
| Fremde Seite desselben Ursprungs täuscht per `history.replaceState` die Anmeldeadresse vor (z. B. hochgeladene Learnweb-Datei) | kein Vorausfüllen und kein Merken durch die App, also nichts zu erbeuten; `UniversityLoginPolicyTests` prüft das mit solchen Seiten |
| Neuinstallation (auch durch eine andere Person) findet alte Schlüsselbund-Einträge | ohne Installations-Merker werden die Dienste `de.uniflow.ai.university` und `de.uniflow.ai.studip` geleert, bevor etwas gelesen wird |
| Diebstahl der Server-Datenbank | keine Hochschul-Zugangsdaten auf dem Dienst; Passwörter Argon2id; Tokens nur gehasht; Notizen pro Nutzer getrennt |
| Konto-Übernahme durch Raten | Rate-Limit je Konto und IP, Sperre mit Rückmeldung, Passwort-Mindestlänge 10, optional Passkeys (WebAuthn) |
| Gestohlenes Sitzungstoken | kurze Lebensdauer (Zugriffstoken 15 min, Refresh 30 Tage, rotierend), „auf allen Geräten abmelden“ |
| Fremde Daten lesen (IDOR) | jede Abfrage mit `user_id` aus der Sitzung, nie aus der Anfrage; Tests je Endpunkt mit zwei Konten |
| Kontingent umgehen | Zählung am Dienst, Anfrage-ID gegen Doppelzählung, Grenze im selben UPDATE |
| Abo vortäuschen | nur vom Dienst geprüfte App-Store-JWS (Apple-Zertifikatskette), App Store Server Notifications V2 |
| Gefälschte Webseite / CSRF | nur Bearer-Tokens (keine Cookies) für die API; strikte CORS-Liste |
| Datenabfluss über KI | KI-Gateway schickt nur den nötigen Text; kein Training (API-Bedingungen); Protokoll ohne Inhalte |

## 3. Schnittstellen (Entwurf)

Maschinenlesbar: `packages/shared-contracts/schemas/api/v2/` (geprüft von `tests/test_api_schemas.py`).

| Methode | Pfad | Zweck |
| --- | --- | --- |
| POST | `/v2/auth/register` | Konto anlegen (E-Mail, Passwort) → Bestätigungsmail |
| POST | `/v2/auth/login` | → `{access_token, refresh_token, expires_in}` |
| POST | `/v2/auth/refresh` | neues Paar, altes Refresh-Token wird ungültig |
| POST | `/v2/auth/logout` | aktuelles Gerät oder `{all: true}` |
| POST | `/v2/auth/password-reset` / `…/confirm` | Einmal-Link (30 min) |
| GET | `/v2/me` | Konto, Tarif, Kontingente |
| DELETE | `/v2/me` | Konto löschen (sofort gesperrt, endgültig nach 30 Tagen) |
| GET | `/v2/me/export` | ZIP mit allen eigenen Daten |
| POST | `/v2/billing/apple/verify` | signierte Transaktion → Berechtigung |
| POST | `/v2/ai/quota/consume` | `{feature, request_id}` → `{ok, used, limit}` |

## 4. Migration (vorbereitet, nicht ausgeführt)

1. Neuer Dienst getrennt vom heutigen Einzelplatz-Server (eigene Datenbank). Der lokale Server bleibt unverändert.
2. Die App spricht zwei Server: lokal/Gerät (Stud.IP, Notizen offline) und den Dienst (Konto, Abo, KI).
3. Bestehende Notizen wandern erst, wenn Notiz-Sync über den Dienst gewünscht ist; dann per Export aus dem lokalen Server
   und Import beim Konto (Prüfsumme je Dokument vorher/nachher).
4. Jeder Schritt mit Migrationstest auf einer Schema-Kopie; Rückweg = alte Datenbank bleibt unangetastet.

## 5. Offene Entscheidungen

Hosting-Anbieter und Standort (EU), KI-Abrechnung (Anthropic-API), ob Notizen über den Dienst synchronisiert werden
oder nur lokal/zwischen eigenen Geräten, Datenschutzerklärung/Impressum, Apple Developer Program.

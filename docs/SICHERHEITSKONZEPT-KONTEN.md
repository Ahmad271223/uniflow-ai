# Sicherheitskonzept: Benutzerkonten, Abos, KI-Kontingente (vorläufige Architektur)

Stand 26.10.2026. **Entschieden** (Vorgabe vom 25.10.): Stud.IP-Login und Hochschulpasswörter bleiben auf dem Gerät
der Studierenden; der zentrale UniFlow-Server erhält keine Stud.IP-Passwörter; Konten, Abos und KI-Kontingente werden
getrennt verwaltet; kein Hosting gebucht. Nichts davon ist produktiv umgesetzt oder migriert.
**Neu entschieden (Inhaber, 25.10.2026):** Die iPad-App darf sich Benutzername und Passwort der Hochschul-Anmeldeseiten
merken – nur auf dem Gerät im Schlüsselbund, nur mit sichtbarem Schalter, und sie **füllt nur vor**: „Anmelden“ tippt
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
| Hochschul-Passwort (LUH-ID für Stud.IP/WebSSO, QIS, UNI-Account Hildesheim/CAS) | Eingabe auf der Anmeldeseite der Hochschule; **nur mit Schalter „Auf diesem iPad merken“** zusätzlich im Schlüsselbund des iPads (Abschnitt 1a) | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, nicht synchronisiert (kein iCloud-Schlüsselbund, nicht auf neue Geräte), je Hochschule und Dienst getrennt; nie an einen Server, nie im Protokoll; bei OAuth2 (später) sieht die App es nicht |
| Stud.IP-Zugriffstoken / Session-Cookie | Gerät, Schlüsselbund (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) | nicht in Backups, nicht an den Dienst |
| Vorlesungsdateien | Gerät | Dateischutz `completeUntilFirstUserAuthentication` |
| Notizen | Gerät; optional Dienst | Transport TLS; Speicherung beim Dienst nutzergetrennt |
| Konto (E-Mail, Passwort-Hash) | Dienst | Argon2id, Sitzungstokens nur als Hash |
| Abo-Status | Dienst (Quelle: App Store) | nur über signierte Transaktionen änderbar |
| KI-Kontingent | Dienst | atomare Zählung (`app/billing.py`) |

## 1a. Gemerkte Hochschul-Zugangsdaten auf dem iPad (umgesetzt 26.10.2026, Entscheidung des Inhabers)

Ablauf: Die App öffnet die echte Anmeldeseite der gewählten Hochschule in einer Webansicht (LUH: Stud.IP-Login und
WebSSO `sso.idm.uni-hannover.de/idp/…`, QIS; Hildesheim: CAS `www.uni-hildesheim.de/sso/login` für Learnweb und LSF).
Unter der Seite steht der Schalter **„Auf diesem iPad merken“** (Standard an) mit Erklärtext. In der App angebunden
ist bisher nur die **Stud.IP-Anmeldung der LUH** (`StudIPLoginView`); QIS und das Hildesheimer CAS haben Profil, Regeln
und Tests, ihre Anmeldeansichten kommen mit der Hochschulwahl nach der S3–S5-Integration.

- **Merken:** Erst wenn der Mensch auf „Anmelden“ tippt (Absenden des Formulars), liest ein Skript Benutzername und
  Passwort und gibt sie an die App; die App legt sie nur bei eingeschaltetem Schalter im Schlüsselbund ab
  (`de.uniflow.ai.university`, Einträge `luh.studip.user`, `luh.studip.password`, `luh.qis.…`, `hildesheim.cas.…`).
  Schalter aus = nichts wird gemerkt und schon Gemerktes dieses Dienstes sofort gelöscht.
- **Vorausfüllen:** Beim nächsten Öffnen derselben Anmeldeseite setzt die App nur leere Felder; was schon eingetippt ist,
  bleibt. **Es gibt keinen Code-Pfad zum automatischen Anmelden** (kein Absenden, kein Klick, auch nicht vorbereitet);
  ein Test prüft, dass das Formular nicht abgeschickt wird.
- **Nur auf bekannten Seiten:** Skript und App prüfen unabhängig voneinander: HTTPS, Hauptrahmen, genau der Rechner und
  Pfad aus dem Hochschul-Profil (`UniversityProfile`, z. B. nicht `…uni-hildesheim.de.example.org`, nicht der
  Learnweb-Pfad, nicht `http://`). Das Skript läuft in einer eigenen `WKContentWorld`; Skripte der Seite können weder
  den Nachrichtenkanal benutzen noch der App eine fremde Herkunft vortäuschen.
- **Getrennt je Hochschule:** Präfix je Uni und Dienst, kein Rückfall (Hildesheim sieht nie LUH-Daten und umgekehrt).
  Gelöscht wird je Uni beim Abmelden (Stud.IP abmelden → alle LUH-Einträge), beim Uni-Wechsel (Schnittstelle
  `UniversityCredentialStore.universityChanged`, die Hochschulwahl folgt nach der S3–S5-Integration) und beim
  **Konto löschen** (alle Hochschulen).
- **Nie an einen Server:** weder an den UniFlow-Dienst noch an den PC-Server; keine Protokollzeile, keine Adresse,
  keine Fehlermeldung enthält Passwort oder Token (Beschreibungen geschwärzt).

Grenzen und Risiken (ehrlich):
- Wer das **entsperrte iPad** in der Hand hat, kann die Anmeldeseite öffnen und sich mit den vorausgefüllten Daten
  anmelden; das Passwort steht im Feld (verdeckt) und ist für Skripte der echten Hochschulseite lesbar – genauso wie
  beim Eintippen. Schutz: Geräte-Code, Schalter aus, Abmelden.
- Ein **kompromittiertes Gerät** (Jailbreak, Schadsoftware mit Schlüsselbund-Zugriff) oder eine kompromittierte
  Anmeldeseite der Hochschule (z. B. XSS auf dem erlaubten Rechner) kann das Passwort lesen.
- Gemerkt wird beim Absenden, **nicht erst nach erfolgreicher Anmeldung**: ein vertipptes Passwort steht beim nächsten
  Mal im Feld, bis die nächste Anmeldung es überschreibt.
- Ändert die Hochschule Rechner, Pfad oder Feldnamen, wird nichts gemerkt oder vorausgefüllt (kein Raten); die
  Anmeldung von Hand funktioniert weiter.
- Eingebettete Anmeldeseiten sind nach RFC 8252 §8.12 nur ein Übergang (die App kann Eingaben technisch lesen – hier
  tut sie es mit Zustimmung). Ziel bleibt OAuth2 mit `ASWebAuthenticationSession`, wo die Hochschule es anbietet.
- Rechtlich offen: Die LUIS-Nutzungsordnung verlangt, das Passwort geheim zu halten, und LUIS wertet das Hinterlegen
  von Zugangsdaten auf Systemen Dritter als unzulässig (Hinweis zu Mail-Apps mit Server-Abruf,
  `docs/IPAD-STUDIP-SYNC.md` Abschnitt 8). Hier liegt nichts bei Dritten, nur im Schlüsselbund des eigenen Geräts;
  vor einer Veröffentlichung mit LUIS/Datenschutz bzw. der Uni Hildesheim klären.
- Nicht gegen echte Hochschulseiten getestet (Regel: keine echten Anmeldungen); geprüft mit erfundenen lokalen Seiten
  in `WKWebView` (`UniFlowTests/UniversityLoginAutofillTests.swift`) und dem Schlüsselbund im Simulator
  (`UniversityCredentialTests.swift`).

## 2. Bedrohungen und Maßnahmen

| Bedrohung | Maßnahme |
| --- | --- |
| Gestohlenes oder entsperrt liegengelassenes iPad | gemerkte Hochschul-Passwörter nur mit Schalter, nur entsperrt lesbar (`WhenUnlockedThisDeviceOnly`), nie automatisch abgeschickt; Abmelden/Konto löschen entfernt sie |
| Gefälschte Anmeldeseite (Phishing) in der Webansicht | Vorausfüllen und Merken nur auf HTTPS + exakt bekanntem Rechner und Pfad je Hochschule, nur Hauptrahmen, eigene Skript-Welt |
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

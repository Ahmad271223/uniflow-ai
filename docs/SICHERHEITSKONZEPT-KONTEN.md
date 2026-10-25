# Sicherheitskonzept: Benutzerkonten, Abos, KI-Kontingente (vorläufige Architektur)

Stand 25.10.2026. **Entschieden** (Vorgabe vom 25.10.): Stud.IP-Login und Hochschulpasswörter bleiben auf dem Gerät
der Studierenden; der zentrale UniFlow-Server erhält keine Stud.IP-Passwörter; Konten, Abos und KI-Kontingente werden
getrennt verwaltet; kein Hosting gebucht. Nichts davon ist produktiv umgesetzt oder migriert.

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
| LUH-Passwort | nur Eingabe in die Anmeldeseite der Hochschule (SSO) | nie gespeichert; bei OAuth2 sieht die App es nicht |
| Stud.IP-Zugriffstoken / Session-Cookie | Gerät, Schlüsselbund (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) | nicht in Backups, nicht an den Dienst |
| Vorlesungsdateien | Gerät | Dateischutz `completeUntilFirstUserAuthentication` |
| Notizen | Gerät; optional Dienst | Transport TLS; Speicherung beim Dienst nutzergetrennt |
| Konto (E-Mail, Passwort-Hash) | Dienst | Argon2id, Sitzungstokens nur als Hash |
| Abo-Status | Dienst (Quelle: App Store) | nur über signierte Transaktionen änderbar |
| KI-Kontingent | Dienst | atomare Zählung (`app/billing.py`) |

## 2. Bedrohungen und Maßnahmen

| Bedrohung | Maßnahme |
| --- | --- |
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

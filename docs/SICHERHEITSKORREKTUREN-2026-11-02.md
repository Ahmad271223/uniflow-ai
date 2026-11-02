# Sicherheitskorrekturen vom 02.11.2026 (Übergabe an die Mac-Sitzung)

Auf `develop` stehen Korrekturen aus einer Sicherheitsprüfung des Dienstes (Stand der Prüfung: cce7965). Alle Python-Tests (682) und Node-Tests (57) sind grün. Swift-Kern und App wurden in der Cloud nicht gebaut.

## Was sich für die Clients ändert
- **Konto:** Social-Login (Google/Apple) führt nur noch in ein Konto mit bestätigter E-Mail zusammen, sonst 409 `email_taken`. Verknüpfen verlangt eine bestätigte E-Mail (403 `email_unverified`). "Passwort vergessen" löscht verknüpfte Anmeldungen. Neu: `GET /api/account/identities`, `DELETE /api/account/identities/{provider}` (409 `last_login_method`, wenn es die einzige Anmeldung ist).
- **KI im Dienst:** Studora-KI (Tutor, Bibliothek-Erzeugung, Wochentest im Dienst) braucht eine bestätigte E-Mail (403 `email_unverified`). Probekonten haben ein eigenes Budget-Becken (429 `ai_trial_budget_exhausted`). Ohne Token-Preise antwortet der Dienst mit 503 `ai_not_configured_prices`. `LERNAPP_AI_TRIAL_BUDGET_EUR` ist neu (siehe `deploy/.env.example`).
- **Kontingent:** Eine wiederholte `request_id` bekommt 409 `duplicate_request` (kein zweiter KI-Aufruf). Wer nach einem Netzfehler wiederholt, sendet eine neue `request_id`.
- **Community:** Melden verlangt eine bestätigte E-Mail und Sichtbarkeit des Beitrags, Grenze `report_user` (10 pro Tag). Neu: Wiederherstellen für Kommentare, Fragen und Antworten (nur Admin), `GET /api/community/moderation` zeigt zusätzlich `comments`, `questions`, `answers` und je Meldung `reporter`.
- **Stundenplan-Import und Test-Start:** `/api/timetable/import/preview` und `/api/tasks/{id}/start-test` antworten im Dienst mit 501 (sie brauchen die lokale KI-Kommandozeile).
- **Noten (QIS):** Dokumente werden nur aus dem eigenen Konto-Ordner ausgeliefert; `qis_documents.local_path` enthält nur noch den Dateinamen.
- **Sonst:** `/docs`, `/redoc`, `/openapi.json` sind im Dienst abgeschaltet; der Export (`GET /api/account/export`) lehnt Aufrufe von fremden Seiten ab (403 `cross_site`); Stripe-Ereignisse werden erst mit ihrer Wirkung gespeichert und ältere Abo-Ereignisse überschreiben keinen neueren Stand; DOCX-Vorschau begrenzt die Summe der Bilder.

## Gemeinsame Vertragsdateien (bitte auf dem Mac prüfen)
Geändert wurden `packages/shared-contracts/fixtures/account/contract.json` (zwei neue Endpunkte, Grenzwert `report_user`) und `packages/shared-contracts/fixtures/community/contract.json` (additive Felder). Bitte Swift-Kern- und App-Tests (und Android, falls es die Dateien prüft) laufen lassen; falls ein Test die Endpunktliste vergleicht, den neuen Stand übernehmen. Die iPad-App sollte die neuen Fehlercodes (`email_unverified`, `duplicate_request`, `ai_trial_budget_exhausted`) mit verständlichem Text anzeigen.

## Noch offen (nicht Teil dieser Korrekturen)
Prüfung beim Betreiber: `claude`-Programm im Docker-Image, LAN-PIN-Sperre je Adresse, Download-Hosts der Hochschule und Cookie-Weitergabe, Apple-Rückerstattung per erneut gesendeter Nachricht, Service-Worker-Cache nach beendeter Sitzung, KI-Pool-Fragen ohne fachliche Prüfung. Nicht geprüft wurden die App-Schichten, die Community-Änderungen vom 01.11. und acht von der Abschlusskontrolle vorgeschlagene Bereiche (IP-Erkennung hinter dem Proxy, Upload-Größen, Konto-Löschung bei laufendem Abo, Dateinamen aus der Hochschule im Browser, Warte-Zeit der Bibliothek, Speichern im PC-Modus).

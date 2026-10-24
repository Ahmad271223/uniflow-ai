# Benutzerkonten und Abonnements: Ausgangslage und Migrationsplan

Stand 25.10.2026. **Noch nicht umgesetzt**: Konten, Anmeldung und Tarifprüfung am Server. Vorbereitet sind die
Kontingent-Logik (getestet, nicht eingebunden) und der StoreKit-2-Code mit Testkonfiguration (keine echten
Produkte). Der Grund steht in Abschnitt 2: Die Umstellung ist eine Architekturentscheidung mit laufenden Kosten.

## 1. Heute

| Bereich | Stand | Folge für Konten |
| --- | --- | --- |
| Server | läuft auf dem eigenen PC, ein Nutzer, SQLite | für andere Nutzer braucht es einen gehosteten Server mit HTTPS |
| Zugriff | vom PC frei, im WLAN mit PIN | wird durch Anmeldung mit Sitzungen ersetzt |
| Stud.IP | eigene LUH-ID und Passwort in der lokalen `.env` | Passwörter anderer Studierender auf einem Server speichern ist datenschutzrechtlich heikel |
| KI | `claude -p` mit dem eigenen Claude-Abo | für andere Nutzer nicht zulässig; nötig ist die Anthropic-API mit eigener Abrechnung |
| Daten | alle Tabellen ohne Benutzerspalte | jede Tabelle braucht `user_id` |

## 2. Entscheidungen, die du treffen musst

1. **Hosting**: Wo läuft der Server für mehrere Nutzer (z. B. Hetzner, Fly.io, Uni-Server)? Kostet laufend Geld,
   dazu eine Domain mit HTTPS.
2. **KI-Abrechnung**: Anthropic-API-Schlüssel mit Abrechnung pro Nutzung. Die Tarifgrenzen (1/6/40 KI-Tests im Monat)
   müssen die API-Kosten decken.
3. **Stud.IP-Anbindung pro Nutzer**: entweder jede Person meldet sich selbst über den Server an (Passwort verlässt
   das Gerät) oder der Abgleich läuft weiter lokal auf dem Gerät der Person und lädt nur die Dateien hoch.
   Empfehlung: lokal auf dem Gerät, keine fremden Passwörter auf dem Server.
4. **Rechtliches**: Datenschutzerklärung, Auftragsverarbeitung mit dem Hoster, Lösch- und Exportkonzept, Impressum.
5. **Apple Developer Program** (99 €/Jahr) für TestFlight, App Store und echte In-App-Käufe.

Bis diese Punkte entschieden sind, bleibt der Server im Einzelplatz-Modus. Nichts davon wird ohne Freigabe aktiviert.

## 3. Zielarchitektur (Empfehlung)

- **Zwei Betriebsarten im selben Code**: `LERNAPP_MODE=local` (heute, eine Person, PIN) und `LERNAPP_MODE=hosted`
  (Konten). Der lokale Modus bleibt für deine eigene Nutzung unverändert.
- **Konten**: E-Mail + Passwort (Argon2id), Sitzungen als zufällige Tokens (nur gehasht gespeichert), Ablauf nach
  30 Tagen, Abmelden auf allen Geräten. Passwort-Reset per E-Mail-Link (Einmal-Token, 30 min). Rollen: `user`, `admin`.
- **Datenzuordnung**: jede Zeile bekommt `user_id`; jede Abfrage filtert serverseitig danach (ein gemeinsamer
  Datenbankzugriff, der ohne Benutzer nicht aufrufbar ist).
- **Konto löschen**: sofort gesperrt, Daten nach 30 Tagen endgültig gelöscht. **Datenexport**: ZIP mit allen Notizen
  (JSON + PDF mit Notizen), Kalender, Tests.

## 4. Migration der bestehenden Daten (Einzelplatz → Konten)

1. Sicherung: `data/lernapp.db` kopieren und mit `PRAGMA integrity_check` prüfen.
2. Neue Tabellen `users`, `sessions`, `entitlements`, `usage`.
3. Allen bestehenden Tabellen `user_id INTEGER NOT NULL DEFAULT 1` hinzufügen; Nutzer 1 = bisheriger Besitzer.
4. Eindeutige Indizes um `user_id` erweitern (z. B. Wochentest je Modul und Woche → je Nutzer, Modul, Woche).
5. Prüfen: Zeilenzahl je Tabelle vorher = nachher; Stichproben im Web-Editor.
6. Rückweg: Sicherung zurückspielen (die Migration ändert keine bestehenden Werte, sie fügt nur Spalten hinzu).

Jeder Schritt bekommt einen Migrationstest mit einer Kopie des Schemas (keine echten Daten in Tests).

## 5. Tarife und Kontingente

| Tarif | Funktionen | KI-Tests/Monat | Zielpreis |
| --- | --- | --- | --- |
| Free | PDF lesen, keine Notizen | 1 | 0 € |
| Plus | PDF bearbeiten, Apple Pencil, Skript-Split-Screen | 6 | 1,99 €/Monat |
| Pro | alles aus Plus, erweiterte KI | 40 | 4,99 €/Monat |

- **Serverseitig entscheidet die Berechtigung**, nie die App allein.
- **Kontingent**: Zähler je Nutzer, Monat und Funktion. Hochzählen und Grenze prüfen in einem einzigen
  SQL-Befehl in einer Schreibtransaktion → zwei gleichzeitige Anfragen können nicht beide den letzten Test bekommen.
- **Doppelzählung**: jede Anfrage trägt eine Anfrage-ID; dieselbe ID zählt nur einmal (Wiederholung nach Netzfehler).
- **Downgrade**: Notizen bleiben vollständig erhalten und lesbar/exportierbar; nur Bearbeiten ist gesperrt.

Umsetzung der Zählung: `app/billing.py` (nicht eingebunden), Tests `tests/test_billing.py`.

## 6. Apple (StoreKit 2)

- Produkte (nur in der Testkonfiguration `apps/apple/UniFlow/StoreKit/UniFlow.storekit`):
  `de.uniflow.plus.monthly`, `de.uniflow.pro.monthly` in einer Abo-Gruppe.
- App: Produkte laden, kaufen, `Transaction.updates` beobachten, `AppStore.sync()` für „Käufe wiederherstellen“.
- Server: signierte Transaktion (`jwsRepresentation`) an `/api/billing/apple/verify`; der Server prüft die Signatur
  mit Apples Zertifikatskette und speichert `originalTransactionId` + Ablaufdatum. Verlängerungen und Erstattungen
  über App Store Server Notifications V2.
- Echte Produkte in App Store Connect erst nach Freigabe.

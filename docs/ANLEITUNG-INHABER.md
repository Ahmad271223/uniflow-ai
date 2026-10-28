# Anleitung für den Inhaber: Was heute passiert ist, was du einrichten musst, was noch fehlt (27.10.2026)

Diese Anleitung fasst den Tag zusammen und führt Schritt für Schritt dorthin, dass jede Studentin und jeder Student
ein eigenes UniFlow-Konto hat und alles verknüpft ist: Hochschule, Geräte, KI, Abo. Technische Details stehen in den
verlinkten Dokumenten; hier steht, **was du tun musst**.

## 1. Was heute passiert ist

| Thema | Ergebnis |
|---|---|
| Android | Auf deinen Wunsch gestoppt. Der Code bleibt auf `develop`, der Offline-Betrieb mit G2-Abgleich ist fertig (Commit `f18a0f6`). Die Test-App ist noch auf deinem Galaxy, du kannst sie deinstallieren. |
| Windows-App | Von 0.3.0 auf **0.4.0**: Startfehler behoben, Stundenplan nach deinem Stud.IP-Kalender (Programmier-Übungen erscheinen), Module nie mehr doppelt, Links und Hochschul-Anmeldung als Fenster **in der App**, Detailfenster für Fristen und Termine, Fortschritt beim Abgleich, nur ein Fenster bei zweitem Start, Sicherungen außerhalb des App-Ordners. |
| Microsoft Store | MSIX-Paket baut und läuft auf dem GitHub-Prüfrechner (`apps/windows/msix/README.md`). Fehlen nur deine Werte aus Partner Center. |
| GitHub | Windows-Workflow baut erstmals (fehlendes pytest), Android-Kern läuft, Python-Tests grün (434). Apple-Workflow ist seit 26.10. rot (Linux-Testhelfer), Hinweis an die Mac-Sitzung liegt in `docs/STAND-MAC-SITZUNG.md`. |
| Abos (Studora) | Vier Tarife Free / Plus / Pro Connect / Pro AI in `develop` gemergt (`21cb0e5`): Rechte serverseitig, Kontingente, KI-Kostenkontrolle, gemeinsame Testbibliothek, Abo-Seite, App-Store-Kaufprüfung vorbereitet. |
| ChatGPT | **Sign in with ChatGPT** für den eigenen PC gebaut und von dir im Browser erfolgreich verbunden; ab 0.4.0 im Installer. Im Dienst bleibt es aus, bis OpenAI freigibt. Plan für den Antrag: `docs/KI-CHATGPT-PLAN.md`. |
| Doku | `docs/FERTIGSTELLUNG-WINDOWS-UND-DIENST.md` (kritische Stellen, Beschaffungsliste), `docs/ABO-SYSTEM.md`, `docs/KI-CHATGPT-PLAN.md`, diese Anleitung. |

## 2. Sofort: die neue Windows-App

1. UniFlow schließen.
2. Installer starten: `apps\windows\src-tauri\target\installer-0.4.9\UniFlow_0.4.9_x64-setup.exe` (im Projektordner).
   Windows warnt, weil der Installer nicht signiert ist: „Weitere Informationen“ → „Trotzdem ausführen“.
3. UniFlow starten, einmal „Sync“ drücken. Deine Daten bleiben erhalten (Ordner `%LOCALAPPDATA%\de.uniflow.desktop`).
4. ChatGPT verbinden: Einstellungen → Erweitert → „KI über mein ChatGPT“ → „ChatGPT verbinden“ → bei OpenAI anmelden
   und erlauben → Modell wählen. Das Token liegt nur auf deinem PC. Ab dann laufen Erklärungen im Editor, Analysen
   und Lernpläne über dein ChatGPT-Abo; Bilder und PDF-Seiten liest weiterhin nur Claude Code.
5. Prüfen: In den Einstellungen steht „verbunden“ mit deiner E-Mail; im Editor eine Frage stellen.
6. Laptop weitergeben oder mit einem anderen Hochschul-Account arbeiten: Einstellungen → Konto → „Konto entfernen“
   (seit 0.4.2). Löscht auf dem PC alles von diesem Account (Sitzung, Zugangsdaten, Kurse, Dateien, Notizen, Tests,
   Lernpläne, ChatGPT-Verbindung, Sicherungen, Cookies des App-Fensters); danach meldet sich der neue Account an.

## 3. Damit jeder ein Konto hat und alles verknüpft ist: der gehostete Dienst

Heute läuft UniFlow nur als Einzelplatz: jede Windows-App und jedes iPad arbeitet für sich. Konten für andere,
Abgleich zwischen Geräten, Community und Abos brauchen den **gehosteten Dienst**. Der Code ist fertig (`deploy/`,
`docs/release/BETRIEB.md`); du musst ihn in Betrieb nehmen. Reihenfolge:

### 3.1 Beschaffen (einmalig)

| Schritt | Was genau | Wo eintragen | Kosten |
|---|---|---|---|
| **Domain** | z. B. `uniflow.de`; Unterdomain `app.uniflow.de` für den Dienst | DNS: A- und AAAA-Eintrag auf den Server; `deploy/.env`: `UNIFLOW_DOMAIN`, `LERNAPP_ALLOWED_HOSTS`, `LERNAPP_PUBLIC_URL` | 1–2 €/Monat |
| **Server (VPS, EU)** | 2 vCPU, 4 GB RAM, 40 GB SSD, Debian 12 oder Ubuntu 24.04, SSH-Schlüssel statt Passwort, Firewall nur 22/80/443 | Hetzner CX23 (Nürnberg/Falkenstein) oder IONOS | 5–6 €/Monat |
| **Auftragsverarbeitung** | Vertrag nach Art. 28 DSGVO mit dem Hoster (in der Hoster-Konsole abschließen) | Hoster und Standort in `docs/release/DATENSCHUTZ.md` | 0 € |
| **Dienst-Geheimnis** | 32 Byte: `openssl rand -base64 32`; verschlüsselt die Hochschul-Zugangsdaten aller Konten. Nie verlieren, getrennt von Backups aufbewahren (Passwort-Manager) | `LERNAPP_SECRET_KEY` | 0 € |
| **Mail-Anbieter mit SMTP** | Resend, Brevo, Postmark oder Mailgun; Domain dort verifizieren (SPF/DKIM-Einträge im DNS) | `LERNAPP_MAIL=smtp`, `LERNAPP_SMTP_HOST`, `_PORT` (587 oder 465), `_USER`, `_PASSWORD`, `LERNAPP_MAIL_FROM`; Anbieter in `DATENSCHUTZ.md` Abschnitt 11 | Resend bis 3.000 Mails/Monat kostenlos |
| **Backup-Ziel außer Haus** | Hetzner Storage Box oder S3; `deploy/backup.sh` schreibt täglich nach `/srv/uniflow/backups`, von dort per rclone/rsync weg | Cron/Timer auf dem Server | 3–4 €/Monat |
| **Monitoring** | Uptime-Robot o. ä. prüft `https://app.<domain>/login` | kostenlos |
| **Rechtstexte** | Platzhalter in `docs/release/*.md` füllen: Name, Anschrift, E-Mail, Telefon, Domain, Hoster, Standort, Mail-Anbieter, Datum; anwaltlich prüfen lassen | werden vom Dienst unter `/datenschutz`, `/impressum`, `/nutzungsbedingungen`, `/konto-loeschen` ausgeliefert | Anwalt nach Aufwand |

### 3.2 In Betrieb nehmen (nach `docs/release/BETRIEB.md`, Abschnitte 1–7)

1. Server per SSH: `apt update && apt upgrade`, Docker installieren, `ufw` nur 22/80/443.
2. Repository klonen (privat → Deploy-Key in GitHub anlegen).
3. `deploy/.env.example` nach `deploy/.env` kopieren und alle Werte aus 3.1 eintragen. `LERNAPP_MODE=hosted`,
   `LERNAPP_FILES=stream` (der Dienst speichert keine Hochschuldateien), `LERNAPP_HTTPS=1`.
4. `docker compose up -d` im Ordner `deploy/`; Caddy holt das Zertifikat selbst, sobald DNS stimmt.
5. Erstes Konto im Browser unter `https://app.<domain>/login` anlegen; dich selbst zum Admin machen:
   `docker compose exec app python -m app.accounts role <deine-mail> admin`.
6. Backup-Timer einschalten (`deploy/uniflow-backup.timer`), einmal eine Wiederherstellung üben.
7. Nach dem ersten Tag `docker stats` ansehen (Chromium beim Abgleich, 300–500 MB je gleichzeitigem Lauf).

### 3.3 Was ein Nutzer dann hat

- **Konto** (E-Mail + Passwort; „Mit Apple/Google anmelden“, sobald du die Client-IDs einträgst, Abschnitt 4).
- **Hochschule** am Konto (LUH oder Hildesheim), Anmeldung bei Stud.IP/Learnweb **im Gerät**; das Passwort sieht
  der Dienst nie. Der Dienst gleicht zweimal täglich ab (08:00, 15:00) mit der vom Gerät gemeldeten Sitzung.
- **Abgleich zwischen Geräten** (G2): Module, Stundenplan, Lernpakete, Aufgaben, Karteikarten, Einstellungen,
  Notizen; Hochschul-PDFs lädt jedes Gerät selbst.
- **Community** und **Abos** über das Konto (Tarife in `app/plans.py`).

## 4. Konten bei Dritten, die du selbst anlegen musst

| Konto | Wofür | Danach eintragen |
|---|---|---|
| **Microsoft Partner Center** (storedeveloper.microsoft.com) | Windows-App im Store, automatische Updates, Signatur durch Microsoft | drei Werte aus „Produktidentität“ in `apps/windows/msix/store.json`, `store_ready: true`; Paket aus Artefakt `uniflow-windows-msix` hochladen; Datenschutz-URL, Screenshot, Prüfhinweis (Demo-Inhalte) |
| **Apple Developer Program** (99 €/Jahr) | iPad-App, „Mit Apple anmelden“, iCloud, Abos | Team-ID in `apps/apple/Config/Team.xcconfig`; App Store Connect: App, Abo „Plus 1,99 €“, Notification-URL `https://app.<domain>/api/billing/apple/notifications`; für den Dienst `LERNAPP_APPLE_CLIENT_IDS`, Apple-Wurzelzertifikat für die Kaufprüfung |
| **Google Cloud** (kostenlos) | „Mit Google anmelden“ | `LERNAPP_GOOGLE_CLIENT_IDS`, `LERNAPP_GOOGLE_WEB_CLIENT_ID` |
| **OpenAI Plattform** | Pro AI (Studora-KI mit eigenem Schlüssel, der Nutzer braucht kein ChatGPT) | `LERNAPP_OPENAI_API_KEY`, `LERNAPP_AI_MODEL`, Preise und Budget (`LERNAPP_AI_*` in `.env.example`) |
| **OpenAI „Sign in with ChatGPT“** | ChatGPT-Abo der Nutzer **im Dienst** nutzen | Interessenformular <https://openai.com/form/sign-in-with-chatgpt-interest/> mit den Angaben aus `docs/KI-CHATGPT-PLAN.md` Abschnitt 4; nach Freigabe `plans.INTEGRATIONS["chatgpt"]["status"] = "enabled"`. Auf dem eigenen PC geht es schon ohne Antrag. |
| **Code-Signing** (nur außerhalb des Stores, 200–400 €/Jahr) | Installer ohne Windows-Warnung | Schritt im Workflow `windows.yml` vor dem Hochladen |

## 5. Was noch fehlt (nach Wichtigkeit)

1. **Dienst in Betrieb** (Abschnitt 3). Ohne ihn gibt es keine Konten, keinen Geräte-Abgleich, keine Community, keine Abos.
2. **Windows-App an den Dienst anbinden.** Die Windows-App läuft heute nur als Einzelplatz mit eigenem Backend auf
   dem Laptop. Für Konten nutzen Windows-Nutzer bisher die Web-Oberfläche unter `https://app.<domain>` im Browser.
   Eine Anmeldung mit UniFlow-Konto **in der Windows-App** (lokale Daten + Abgleich über G2) ist noch nicht gebaut.
3. **iPad**: Developer Program, echte Daten testen, Geräte-Abgleich-Client (G2) in Swift, StoreKit-Käufe für die
   vier Tarife (Mac-Sitzung), Apple-Workflow wieder grün.
4. **Microsoft Store**: Partner-Center-Werte, Screenshots, öffentliche Datenschutzerklärung, Einreichung.
5. **Abos**: App-Store-Produkte und Apple-Schlüssel; Web-Zahlung gibt es nicht (Tarife werden in der Apple-App gekauft).
6. **KI im Dienst**: OpenAI-Schlüssel für Pro AI; ChatGPT-Antrag; Datenschutzerklärung um „KI über ChatGPT“ ergänzen.
7. **Gerätetests**: Windows-App auf einem fremden Laptop (Installer, WebView2, Firewall), Flugmodus-Test.
8. **Rechtliches**: Rechtstexte prüfen lassen; Auftragsverarbeitung mit Hoster und Mail-Anbieter.

## 6. Dauerhaft: so bleibt alles aktuell

- Jede Änderung auf `develop` baut automatisch den Windows-Installer und das Store-Paket (GitHub Actions, Artefakte
  14 Tage). Neue Version = Versionsnummer in `apps/windows/package.json`, `tauri.conf.json`, `Cargo.toml` erhöhen.
- Nach dem Store-Start bekommen Nutzer Updates automatisch; bis dahin installierst du den Installer von Hand.
- Dienst-Updates: `git pull` und `docker compose up -d --build` auf dem Server (BETRIEB.md, Abschnitt 8).
- Backups täglich 03:30, Löschfristen 04:00 (14 Tage Zugriffsprotokoll, 90 Tage Abgleich-Protokolle).

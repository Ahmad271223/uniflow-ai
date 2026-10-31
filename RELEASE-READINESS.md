# Studora – Release-Readiness (Zweig `develop`, 30.10.2026)

> Neuester Stand: `docs/BERICHT-CLOUD-SITZUNG-2026-10-30.md` (Testzahlen, Architektur, Nachtrag App-Lauf auf dem Mac)
> und `docs/PLAN-WEB-ZUERST-2026-10-30.md` (Entscheidungen des Inhabers vom 30.10., Reihenfolge der Veröffentlichung).

Kurzfassung: **Nicht release-bereit, aber alle Teile sind gebaut und automatisch geprüft.** Python 598, Swift-Kern
776 (Linux 761), iPad-App 564 im Simulator, JS 38, Generatoren 21, Android 119, alles grün in lokalen Läufen (GitHub
Actions sind seit dem 25.10. gesperrt). Was fehlt, liegt außerhalb des Codes: ein Server für den Dienst (nie in
Betrieb), die Freigabe von Apple (am 28.10. abgelehnt), die Zulassung von OpenAI für den gehosteten Dienst, Konten
bei Stripe und im Microsoft Partner Center, Rechtstexte, und jede Prüfung mit echten Geräten und echter KI. `main` ist
unverändert, kein Merge, kein Release.

Reihenfolge nach Entscheidung des Inhabers vom 30.10.: **Web über den eigenen Dienst zuerst**, dann **Windows über den
Microsoft Store**, iPad und Mac vorerst als Web-App, **später App Store** mit Übernahme der Daten über das Konto.

## 1. Gebaut und automatisch geprüft

| Teil | Tests | Wo gelaufen | Datum |
| --- | --- | --- | --- |
| Python-Server (Einzelplatz, Windows-Backend, gehosteter Dienst): Sicherheit, Verträge, Migration, Konto, Abgleich, Community, Abos, Probe und Stripe, Wochentests, Lernplan-Regel, PWA | 598 | Cloud-Container (Linux), zuletzt Commit `8d40053` | 30.10. |
| Generatoren der Prüfdaten (`--check`) | 21 / 21 | Cloud | 30.10. |
| Web: Zusammenführung, Seite drehen, Lösungen, Service-Worker-Regeln | 38 (Node 22) | Cloud | 30.10. |
| Swift-Kern `UniFlowCore`: lokales Backend (118 `/api`-Pfade), Lernplan, Wochentests inkl. Hintergrund-Entscheidung, Sign in with ChatGPT, Abgleich, Journal | 776 (Mac) / 761 (Linux, Docker Swift 6.1) | Mac ×2, Cloud ×2 | 30.10. |
| iPad-App (Xcode 27.2, Simulator iPad Pro 11, iOS 27.2): Build fehlerfrei, voller Lauf ×2 | 564 (2 übersprungen, nur auf Anforderung) | Mac | 30.10. abends |
| Android (Kotlin-Kern und App) | 119 | Docker-Bild `android-sdk:35` | 27.10. |
| Dienst-Paket `deploy/` (Image, Compose, Caddy, Backup) | `tests/test_deploy.py`; Container startet lokal `healthy` | Docker Desktop | 27.10. |
| Windows-App 0.4.9 (Installer NSIS, MSIX für den Store) | `tests/test_desktop*.py`; Installer still installiert und geprüft | Workflow `windows.yml` | 27.10. (siehe Risiko „Actions“ unten) |

## 2. Von Hand geprüft

| Was | Wie | Datum |
| --- | --- | --- |
| Stud.IP-Abgleich mit echten Daten | LUH-Konto des Inhabers, 150 Dateien, am PC und im iPad-Simulator | bis 28.10. |
| Web-App offline: laden, Netz aus, neu laden, Übersicht aus der Ablage, Änderung scheitert mit `offline`, Konto nie aus der Ablage | echter Chromium-Lauf in `tests/test_pwa.py` | 30.10. |
| ChatGPT verbinden auf dem iPad: Karte, Zustimmung, Systemabfrage, echte Anmeldeseite `auth.openai.com`, Abbrechen | Simulator (vorübergehender UI-Test); die Anmeldung selbst nur durch den Inhaber | 30.10. |
| Debug-Knopf „Langen Hintergrundlauf starten“ auf dem iPad | Simulator; iOS selbst kann den Lauf dort nicht starten (`BGTaskScheduler` nicht verfügbar) | 30.10. |
| Windows-App: Start, Abgleich mit Fortschritt, Stundenplan, Dokument, zweites Fenster, Sicherungen | PC des Inhabers | 27.10. |
| Dienst im Container: Registrierung, `/login`, Datenschutzseite, Backup-Archiv | lokal in Docker | 27.10. |

## 3. Nicht geprüft (ehrlich)

| Punkt | Warum nicht | Wer |
| --- | --- | --- |
| **Echte KI auf echtem Skript** (Wochentest, Einordnung, Tutor) | alle KI-Tests laufen mit simulierter KI; der Inhaber hat sich noch nicht mit seinem ChatGPT-Abo angemeldet | Inhaber |
| **Echtes iPad mit Apple Pencil**: Schreibgefühl, Handballen, Doppeltippen, Zoom, Speicher bei großen PDFs, Export, Hintergrundlauf über Tage | nie auf einem Gerät gelaufen; Developer Program fehlt | Inhaber + Mac-Sitzung (`docs/EDITOR-ABNAHME.md`, `docs/MAC-IPAD-CHECKLISTE.md`) |
| **Dienst auf einem Server**: Caddy mit echter Domain, Mailversand, Hochschul-Abgleich mit Chromium unter Last, Backup-Timer, Löschfristen | kein Server, keine Domain, kein Mail-Anbieter | Inhaber (beschaffen), dann Cloud-/PC-Sitzung |
| **Web-App in Safari** (iPad, Mac): Installieren, Offline, Stift im Browser (`touch-action`, Handballen) | nur Chromium im Test | Inhaber + Sitzung |
| **Hintergrund-Wochentests auf dem iPad** (App-Teil) | App-Tests grün, der Start durch iOS geht nur am Gerät | Inhaber |
| **Freigabe nachholen** (ChatGPT) | Knopf erscheint nur bei verbundenem Konto ohne Freigabe | Inhaber |
| QIS auf dem iPad | der Inhaber hat 0 Leistungen | – |
| Hildesheim mit echten Daten auf dem iPad | Zählwerte weichen ab (iPad 195, PC 539 Dateien) | PC-Sitzung (`docs/STAND-MAC-SITZUNG.md`) |
| Android auf einem Gerät | kein Android-Gerät | später (V2) |
| Windows-App auf einem fremden Rechner (WebView2, Firewall, Virenscanner) | nur der PC des Inhabers | Inhaber |
| Stripe gegen das echte Stripe-Konto, Microsoft-Store-Beleg | Stripe-Konto und Preise fehlen; Microsoft-Beleg nicht gebaut | Inhaber, PC-Sitzung |

## 4. Was bis zur Veröffentlichung fehlt, je Weg

### 4.1 Web über den eigenen Dienst (zuerst)

| Schritt | Stand | Wer |
| --- | --- | --- |
| Server (VPS in der EU), Domain, Mail-Anbieter, Dienst-Geheimnis, Backup-Ziel, AVV mit dem Hoster | offen | Inhaber (`docs/FERTIGSTELLUNG-WINDOWS-UND-DIENST.md` Abschnitt 4) |
| Rechtstexte: Impressum, Datenschutz (inkl. Uni-Zugangsdaten beim Dienst, KI über das Backend, Stripe), Nutzungsbedingungen | Entwürfe mit Platzhaltern in `docs/release/`, nicht anwaltlich geprüft | Inhaber |
| Dienst einrichten, Monitoring | offen, nie in Betrieb; Startpaket und Checkliste `docs/START-DIENST-CHECKLISTE.md` fertig (30.10.), Lasttest in-process gemacht (`docs/LASTTEST-DIENST-2026-10-30.md`: ~100 Anfragen/s je Prozess, keine SQLite-Sperren, Engpass Schonpause je Hochschule) | Inhaber (Server) + Sitzung |
| Installierbare Web-App, Offline-Rückfall | gebaut 30.10. | – |
| Notizen ohne Netz zwischenspeichern und nachsenden (`app/static/notes-queue.js`) | gebaut 30.10., Chromium-Lauf grün; Safari offen | Inhaber + Sitzung (Safari) |
| Hochschul-Abgleich durch den Dienst nur mit Zustimmung (Karte, Häkchen, Löschen) | gebaut 30.10.; Anfrage an LUH und Hildesheim läuft parallel | Inhaber |
| Wochentests im Dienst je Konto (Job nach dem Abgleich, zu den Zeitfenstern, auf Knopfdruck) mit Studora-KI und Kontingent | gebaut 30.10.; braucht OpenAI-Schlüssel des Inhabers im Dienst (`LERNAPP_OPENAI_API_KEY`) | Inhaber |
| ChatGPT-Abo des Nutzers im gehosteten Dienst | bleibt aus bis OpenAI freigibt (Warteliste) | Inhaber |
| Probe 7 Tage, Tarifwahl, Stripe (Checkout, Kundenportal, Webhook) | gebaut 30.10.; Stripe-Konto, Preise, Schlüssel fehlen | Inhaber |
| Prüfung in Safari auf iPad und Mac, Edge unter Windows | offen | Inhaber + Sitzung |

### 4.2 Windows über den Microsoft Store

| Schritt | Stand |
| --- | --- |
| MSIX-Paket | baut (`apps/windows/msix/README.md`) |
| Partner-Center-Konto, Produktidentität in `msix/store.json`, Screenshots, Datenschutz-URL | offen (Inhaber) |
| Store-Texte ohne KI-Versprechen, solange OpenAI nicht freigibt | Entwürfe in `docs/release/` |
| Bezahlen: zuerst Free; Stripe für Windows gebaut; Microsoft-Store-Beleg | Stripe fertig, Microsoft-Beleg nicht gebaut |
| Code-Signierung außerhalb des Stores | nicht nötig für den Store; sonst Zertifikat kaufen |

### 4.3 App Store (iPad, Mac), sobald Apple freigibt

| Schritt | Stand |
| --- | --- |
| Apple Developer Program | abgelehnt am 28.10., Support-Fall beim Inhaber |
| Team-ID in `apps/apple/Config/Team.xcconfig`, Signierung, „Mit Apple anmelden“, CloudKit-Container | offen |
| App Store Connect: Eintrag „Studora“, Produkt Plus (`de.uniflow.plus.monthly`), Datenschutzangaben | offen (`docs/release/APP-STORE.md`) |
| iPad: Konto-Anmeldung sichtbar machen (Dienst-Adresse), **G2-Client bauen**, Community von CloudKit auf den Dienst | offen (Mac-Sitzung) |
| Übernahme vom Web: Module, Stundenplan, Lernplan, Karteikarten, Einstellungen, Notizen über G2; eigene Dokumente mit Inhalt noch nicht | offen |
| Gerätetest nach Checkliste | offen |

## 5. Kritische Risiken

| Risiko | Folge | Gegenmaßnahme |
| --- | --- | --- |
| Alles Gerätenahe ist nur im Simulator geprüft | Stift, Hintergrundlauf und Speicher können sich am iPad anders verhalten | erster Gerätetest, sobald eine Signierung möglich ist (kostenlose Signierung per Kabel reicht für das eigene iPad) |
| Dienst nie auf einem Server unter Last | In-process-Lasttest 30.10. ok (100/500 Konten); Chromium-Speicher beim Abgleich, Netz/TLS, Mehrprozess auf accounts.db ungemessen; Backup und Restore im Container durchgespielt | Lasttest auf dem Server wiederholen (`tools/lasttest-dienst.py`), `docker stats` nach dem ersten Tag |
| KI nie echt | Prompts, Fehlercodes der Responses API und Kosten der Studora-KI sind Annahmen | erster echter Lauf durch den Inhaber vor jedem Store-Text, der KI nennt |
| Uni-Zugangsdaten beim Dienst | der Dienst hält Passwörter verschlüsselt und meldet sich von der Server-IP an | Zustimmung je Konto (gebaut), Text in der Datenschutzerklärung, Rückmeldung von LUH und Hildesheim abwarten |
| GitHub Actions gesperrt seit 25.10. | kein Bauen auf GitHub; Windows-Installer und Apple-Läufe nur lokal oder gar nicht; Quellen widersprechen sich, ob der Windows-Workflow am 27.10. lief | Abrechnung klären (`docs/GITHUB-ABRECHNUNG.md`) oder lokal bauen |
| Rechtstexte sind Entwürfe mit Platzhaltern | Abmahnrisiko, Store-Ablehnung | ausfüllen (`tests/test_release_texts.py` listet die Platzhalter), prüfen lassen |
| OpenAI-Zulassung | Repo wird privat (Entscheidung 31.10.), Plus ist kostenpflichtig, das Web läuft gehostet: ChatGPT-Verbindung für andere Nutzer erst nach Freigabe | Warteliste, Frage nach der Tarif-Kopplung stellen |
| Wackliger pytest unter Last | ein Lauf von sieben fiel am 30.10. unter paralleler Last, Name nicht gesichert; danach nicht wiederholbar | bei erneutem Auftreten den Namen sichern |

## 6. Entscheidungen

Getroffen am 30.10.2026 (Inhaber):

1. Web zuerst über den eigenen Dienst, Windows Store, iPad und Mac vorerst als Web-App, später App Store mit Übernahme
   über das Konto.
2. Uni-Passwörter beim Dienst: ja, nur mit ausdrücklicher Zustimmung je Konto.
3. KI im Web: ChatGPT-Abo des Nutzers (nach OpenAI-Freigabe) **und** Studora-KI über den Dienst (Pro AI).
4. Jedes neue Konto: 7 Tage Probe mit allen Rechten, dann Tarifwahl; Stripe für Web und Windows; Apple in der App;
   Microsoft Store später.
5. Lernplan ohne KI nach der Regel „je Tag nur der Stoff seiner Lehrwoche plus Skriptrest nach dem Marker der
   Vorwoche“; der KI-Wochenplan ist entfernt.
6. Bitte um neue Anmeldung bei der Hochschule nach 6 Stunden (Frage beim Öffnen, sonst Mitteilung zum nächsten Termin).

Offen (nur der Inhaber):

1. Repo auf privat stellen (GitHub-Einstellungen), Server, Domain, Mail, Stripe-Konto, Partner Center, Rechtstexte.
2. Plus-Kontingent 3 oder 6 Tests; geteilter Wochentest gegen das Kontingent (`docs/GEMEINSAME-WOCHENTESTS.md`).
3. Name und Domain prüfen („Studora“ als Marke frei?).
4. Alte Branches von Ahmad271223 durchsehen und schließen.
5. GitHub Actions wieder freigeben oder dauerhaft lokal bauen.

## 7. Nächste Schritte in Reihenfolge

1. Inhaber: Server, Domain, Mail, Stripe, Rechtstexte (Abschnitt 4.1).
2. Inhaber: Server, Domain, Mail nach `docs/START-DIENST-CHECKLISTE.md`; Sitzung: Rechtstexte einbauen, Monitoring.
3. Inhaber: einmal mit dem eigenen ChatGPT-Abo anmelden und einen Wochentest auf echtem Skript prüfen.
4. Inhaber + Sitzung: Web-App und Offline-Notizen in Safari auf iPad und Mac prüfen.
5. Inhaber + PC-Sitzung: Partner Center, Screenshots, Store-Einreichung Windows.
6. Mac-Sitzung, sobald Apple freigibt: G2-Client, Community über den Dienst, Gerätetest, App Store.

## Verweise

`docs/BERICHT-CLOUD-SITZUNG-2026-10-30.md` · `docs/PLAN-WEB-ZUERST-2026-10-30.md` · `docs/ARCHITEKTUR-ZIEL-2026-10-29.md` ·
`docs/FERTIGSTELLUNG-WINDOWS-UND-DIENST.md` · `docs/ABO-SYSTEM.md` · `docs/KI-CHATGPT-PLAN.md` · `docs/WOCHENTESTS.md` ·
`docs/UEBERGABE-MAC-NEUE-SITZUNG-2026-10-30.md` · `docs/ENTWICKLUNGSSTAND.md` · `docs/release/BETRIEB.md` ·
`docs/EDITOR-ABNAHME.md` · `docs/MAC-IPAD-CHECKLISTE.md` · `docs/SICHERHEIT.md` · `docs/GITHUB-ABRECHNUNG.md`

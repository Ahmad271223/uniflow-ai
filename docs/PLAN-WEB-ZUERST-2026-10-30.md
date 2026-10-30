# Plan: Web zuerst, Windows Store, später App Store (30.10.2026)

Entscheidung des Inhabers am 30.10.2026: Das Apple Developer Program ist nicht aktiv, der Microsoft Store geht. Darum
kommt zuerst eine gemeinsame Web-Version über den eigenen Dienst: Windows-Nutzer über den Microsoft Store, iPad- und
Mac-Nutzer über Safari aus dem Internet. Sobald Apple freigibt, werden iPad- und Mac-Nutzer gebeten, die App aus dem
App Store zu laden, sich mit ihrem Studora-Konto anzumelden, und alles wird automatisch übernommen.

Dieser Plan baut auf `ARCHITEKTUR-ZIEL-2026-10-29.md` (Dienst, G1 Konto, G2 Abgleich) und
`FERTIGSTELLUNG-WINDOWS-UND-DIENST.md` auf und ändert nur die Reihenfolge: Dienst und Web vor dem App Store.

## 1. Was dafür schon da ist (im Code geprüft)

| Baustein | Stand |
| --- | --- |
| Gehosteter Dienst (`LERNAPP_MODE=hosted`) | Code und Hosting-Paket fertig (`deploy/`: Docker, Caddy mit HTTPS, Backups, systemd-Timer). Eine Datenbank je Konto. Nie in Betrieb gewesen. |
| G1 Konto (`/api/account`, 18 Endpunkte) | Registrieren, E-Mail bestätigen, Anmelden mit E-Mail, Apple oder Google (`social_login.py`), Passwort zurücksetzen, Geräte abmelden, Datenexport, Konto löschen. Dienst und Windows fertig. iPad: `StudoraAccountLink` vorhanden, unsichtbar ohne Dienst-Adresse. |
| G2 Abgleich (`/api/sync/changes`, `/api/sync/push`) | Dienst, Windows (`sync_client.py`) und Android fertig. Überträgt: Module, Ordner, Stundenplan-Termine und Ausnahmen, Lernpakete und Aufgaben, Karteikarten, Einstellungen (ohne `lan_pin`, `university`), Notizen je Datei. **Nicht:** eigene Dokumente mit Inhalt, Hochschul-PDFs (jedes Gerät lädt sie selbst). **iPad hat keinen G2-Client.** |
| Web-Oberfläche (`app/static`) | Editor mit pdf.js und Konva, Stift mit Druck (`pointerType === "pen"`, 22 Stellen), `manifest.webmanifest`. Kein Service Worker, also nichts offline. |
| Windows-App (Tauri 2 + Python-Backend) | Einzelplatz 0.4.9 mit Konto und Community über den Dienst. MSIX für den Store baut; es fehlen Partner-Center-Werte (`msix/store.json`), Screenshots, öffentliche Datenschutzerklärung. |
| Bezahlen | Nur Apple-Belege (`billing_api.py`). Kein Stripe, kein Microsoft-Store-Beleg. Tarife und Rechte je Konto in `plans.py`/`entitlements.py`. |
| KI im Dienst | `files/analyze`, `tests/generate`, `tests/generate-week` antworten 501. Der Wochentest-Takt startet im Dienst nicht (`server.py:1372`, eine Datenbank je Konto). |
| Hochschul-Abgleich im Dienst | Vorhanden über `jobs.py` und `vault.py`: der Dienst speichert die Uni-Zugangsdaten verschlüsselt und meldet sich per Playwright an (Zeiten `LERNAPP_SYNC_TIMES`, Standard 08:00 und 15:00). |

## 2. Die Stufen

### Stufe A: Dienst in Betrieb (Inhaber + Cloud-/PC-Sitzung)

Inhaber: Server (VPS in der EU, zu Beginn 2 Kerne / 4 GB reichen für den Dienst ohne Playwright), Domain, Mail-Anbieter
für Bestätigungs- und Passwort-Mails, Dienst-Geheimnis. Rechtstexte: Impressum, Datenschutzerklärung,
Nutzungsbedingungen, dazu Auftragsverarbeitung mit dem Hoster.

Sitzung: `.env` für den Dienst, Caddy, Backups prüfen, ersten Lasttest (100 Konten, 1000 Dateien), Mail-Versand echt
prüfen, Rechtstexte in die Oberfläche einbauen (heute Platzhalter), Monitoring (Fehler-Log, Plattenplatz).

### Stufe B: Web-Version für iPad und Mac (Cloud-/PC-Sitzung)

1. **Installieren wie eine App:** Hinweis-Seite „Zum Home-Bildschirm“ (iPad) und „Zum Dock hinzufügen“ (Mac ab
   macOS 14), Symbole und Startbild im Manifest. Hinweis auf dem Mac: Safari, nicht Chrome.
2. **Offline:** Service Worker für die Oberfläche und die zuletzt geöffneten PDFs, Notizen zwischenspeichern und beim
   nächsten Netz senden. Ein Journal wie `LocalJournal` auf dem iPad gibt es im Web nicht, das muss gebaut werden.
3. **Dateien hereinbekommen, Entscheidung 1 (siehe 4):** Upload von Hand gibt es (`server.py:2479`). Der Abgleich
   durch den Dienst mit Uni-Zugangsdaten gibt es auch, ist aber die heikle Variante.
4. **Wochentests im Dienst:** Takt je Konto statt nur lokal, Ausführung über die Job-Warteschlange (`jobs.py`),
   KI-Anbindung nach Entscheidung 2.
5. **Stift am iPad im Browser:** `touch-action: none` auf der Zeichenfläche prüfen, Handballen-Erkennung über
   `pointerType === "touch"` während ein Stift aktiv ist, Doppeltipp fällt weg. Einmal auf einem echten iPad testen.
6. **Browser-Prüfung:** Safari auf iPad und Mac, Edge auf Windows (für die Store-App WebView2).

### Stufe C: Windows Store (Inhaber + PC-Sitzung)

1. Partner-Center-Konto, Werte in `msix/store.json`, Screenshots, Datenschutz-URL (aus Stufe A).
2. Die Store-App bleibt die Einzelplatz-App mit lokalem Backend, Konto und G2 Abgleich. Das ist richtig so: sie läuft
   offline und lädt Stud.IP selbst, ohne Passwörter beim Dienst.
3. Store-Texte ohne KI, solange OpenAI nicht freigegeben hat.
4. Bezahlen: zunächst **Free** (keine Bezahlung). Microsoft-Store-Käufe später (Beleg-Prüfung im Dienst wie bei Apple,
   neu zu bauen).

### Stufe D: Bezahlen am Konto, nicht am Gerät (Dienst)

Ein Tarif je Konto beim Dienst. Kanäle: Apple (fertig, `apple/verify`), Microsoft Store (neu), Web über Stripe (neu).
Das Recht hängt am Konto, jedes angemeldete Gerät sieht es. Apple erlaubt in der App die Anmeldung mit einem anderswo
gekauften Konto, solange die App nicht auf den Kauf außerhalb verweist (außerhalb der EU). Das ist mit dem Plan
vereinbar: in der iPad-App gibt es Apple-Kauf, im Web Stripe, im Store Microsoft.

### Stufe E: Umzug in den App Store (Mac-Sitzung, sobald Apple freigibt)

1. iPad-App: Konto-Anmeldung sichtbar machen (Dienst-Adresse setzen), **G2-Client bauen** (fehlt, Stufe-2-Punkt aus
   `ARCHITEKTUR-ZIEL`), Community von CloudKit auf den Dienst (Entscheidung 28.10. §4).
2. Web-Version zeigt iPad- und Mac-Nutzern den Hinweis „Jetzt die App laden“ mit App-Store-Link, solange sie im Browser
   sind.
3. Nach der Anmeldung in der App zieht G2 alles vom Konto: Module, Stundenplan, Lernplan, Karteikarten, Einstellungen,
   Notizen. Hochschul-PDFs lädt die App selbst aus Stud.IP (Nutzer meldet sich einmal in der App an). Eigene Dokumente
   mit Inhalt: Übernahme muss noch gebaut werden (G2 kann sie heute nicht), oder Export/Import.
4. Web-Version bleibt für Nutzer ohne iPad, und als Rückfall.

## 3. Reihenfolge und wer

| Nr. | Schritt | Wer | Hängt ab von |
| --- | --- | --- | --- |
| 1 | Entscheidungen in Abschnitt 4 | Inhaber | – |
| 2 | Server, Domain, Mail, Rechtstexte | Inhaber | 1 |
| 3 | Dienst einrichten, Lasttest, Rechtstexte einbauen | Cloud-/PC-Sitzung | 2 |
| 4 | Web: Installieren-Hinweis, Service Worker, Upload-Weg, Stift-Prüfung | Cloud-/PC-Sitzung | 3 (Test), sonst sofort |
| 5 | Wochentests im Dienst je Konto | Cloud-/PC-Sitzung | 1 (KI-Entscheidung) |
| 6 | Windows Store: Partner Center, Screenshots, Einreichung | Inhaber + PC-Sitzung | 2 (Datenschutz-URL) |
| 7 | Stripe und Microsoft-Beleg im Dienst | PC-Sitzung | 1 (Bezahl-Entscheidung) |
| 8 | iPad: Konto sichtbar, G2-Client, Community über Dienst | Mac-Sitzung | 3, Apple-Freigabe |
| 9 | Hinweis „App laden“ im Web, Übernahme prüfen | Cloud- + Mac-Sitzung | 8 |

Punkte 4, 5 und 7 lassen sich in dieser Cloud-Sitzung oder am PC bauen und mit pytest, Generatoren und JS-Tests
prüfen. Nur Punkt 8 braucht den Mac.

## 4. Entscheidungen, die nur der Inhaber treffen kann

1. **Uni-Passwörter beim Dienst?** Der Dienst kann Stud.IP für Web-Nutzer abgleichen, hält dann aber deren Passwörter
   (verschlüsselt) und meldet sich von der Server-IP an. Empfehlung: **Nein zum Start.** Web-Nutzer laden PDFs selbst
   hoch; Windows und später iPad gleichen selbst ab. Den Dienst-Abgleich erst nach Rücksprache mit LUH und Hildesheim
   und nur mit ausdrücklicher Zustimmung je Nutzer.
2. **KI im Web?** Drei Wege: (a) ohne KI starten, Wochentests nur auf Windows (eigener PC mit Claude) und später iPad;
   (b) ChatGPT-Abo des Nutzers im Browser, braucht die OpenAI-Freigabe wie auf dem iPad; (c) Studora-KI über den
   Dienst (Pro AI), dann zahlst du die KI-Kosten je Nutzer. Empfehlung: **(a) jetzt, (b) sobald OpenAI freigibt**, (c)
   als bezahlter Tarif später.
3. **Bezahlen zum Start?** Free für alle im Web und im Store, bis Stripe und Microsoft-Beleg gebaut sind. Oder gleich
   Stripe bauen (eine Woche PC-Arbeit plus Rechtstexte für Abos). Empfehlung: **erst Free**, Nutzer sammeln.
4. **Name und Domain.** „Studora“ steht in der App; die Domain muss dazu passen und frei sein. Prüfen, ob der Name
   als Marke frei ist, bevor Store-Einträge entstehen.
5. **Plus-Kontingent 3 oder 6 Tests, geteilter Test gegen das Kontingent?** (aus `GEMEINSAME-WOCHENTESTS.md`,
   `ABO-SYSTEM.md`, weiter offen).

## 5. Was dieser Plan nicht löst

- Die KI hängt an OpenAI (Freigabe) oder an deinen Kosten. Keine Stufe hier ändert das.
- „Gemeinsamer Wochentest“ für alle Nutzer eines Kurses gibt es erst mit dem Dienst-Takt (Stufe B.4) und dem
  V2-Dienst aus `GEMEINSAME-WOCHENTESTS.md`.
- Ohne Apple-Freigabe gibt es auf iPad und Mac keinen Pencil mit PencilKit, kein „Mit Apple anmelden“ in einer App
  (im Web geht es über `social_login.py`, wenn Apple die Web-Anmeldung freischaltet, was ebenfalls das Developer
  Program braucht; bis dahin E-Mail und Google).

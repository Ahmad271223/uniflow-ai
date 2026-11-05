# StudiNow im Microsoft Store: Einreichung Schritt für Schritt (Stand 05.11.2026)

Für den Inhaber. Das Paket ist technisch fertig und geprüft: Der Windows-Lauf bei GitHub (Lauf vom 04.11.2026) baut das
MSIX-Paket, installiert eine testsignierte Fassung, startet das Backend im Paket und deinstalliert wieder, alles ohne Fehler
(`apps/windows/msix/README.md`). Es fehlen nur Dinge, die nur du bei Microsoft erledigen kannst, plus Bilder und der
öffentliche Link zur Datenschutzerklärung.

**Nicht geprüft:** Die App lief bisher nur auf dem GitHub-Windows-Rechner, noch auf keinem echten Laptop. Probiere vor der
Einreichung die Testfassung (`…-test.msix`, Anleitung im `msix/README.md`) auf deinem eigenen Windows-PC aus.

## 1. Was du brauchst, bevor du anfängst

| Was | Stand |
| --- | --- |
| Microsoft-Konto und Entwicklerkonto im Partner Center (Einzelperson, laut Microsoft kostenlos; beim Anlegen prüfen) | du |
| Öffentlicher Link zur Datenschutzerklärung (Pflicht, die App verarbeitet persönliche Daten) | du: Seite mit `tools/gen-site.py` erzeugen und veröffentlichen, z. B. unter `studinow.app` (Domain noch nicht gekauft) |
| Mindestens ein Screenshot, besser 4 bis 6, ab 1366 × 768 (PNG) | du: aus der installierten App, am besten mit den Demo-Inhalten (erste Seite der App, ganz unten der kleine Link „Ohne Hochschulkonto ansehen (Demo)“). Die schmale Leiste „Demo-Inhalte – erfunden, ohne Hochschule“ über der Seite darf im Bild sein. |
| App-Symbol | liegt in `apps/windows/app-icon.png` (1024 × 1024); das Paket erzeugt daraus alle Größen. Ist es nicht dein endgültiges StudiNow-Symbol, tausche die Datei vor dem Bauen. |
| Support-Kontakt (E-Mail oder Webseite) | du |

## 2. Reihenfolge im Partner Center

1. **App anlegen und Namen reservieren:** Apps und Spiele → Neues Produkt → MSIX- oder PWA-App → Name **StudiNow**. Ist der
   Name vergeben, sag mir den neuen. Der reservierte Name muss zu `display_name` in `apps/windows/msix/store.json` passen.
2. **Drei Werte kopieren** (Produktverwaltung → Produktidentität) und mir schicken oder selbst in `store.json` eintragen:
   - `Package/Identity/Name` → `identity_name`
   - `Package/Identity/Publisher` (beginnt mit `CN=`) → `publisher`
   - `Package/Properties/PublisherDisplayName` → `publisher_display_name`
   Danach `store_ready` auf `true`. Ein Paket mit den Testwerten nimmt der Store nicht an.
3. **Paket bauen lassen:** Windows-Lauf bei GitHub starten (Actions → Windows → Run workflow), danach aus dem Ergebnis
   `uniflow-windows-msix` das **unsignierte** `StudiNow_<version>.0_x64.msix` herunterladen. Der Store signiert es selbst.
4. **Einreichung ausfüllen** mit den Texten unten.
5. **Einreichen.** Die Prüfung dauert meist einige Werktage. Danach spielt der Store jede neue Fassung automatisch ein.

## 3. Die Felder der Einreichung

**Preise und Verfügbarkeit:** kostenlos; Märkte: mindestens Deutschland; Sichtbarkeit zuerst „Privat, nur per Link“ zum
Testen, danach öffentlich.

**Kauf in der App (geändert 05.11.2026, Entscheidung des Inhabers „anmelden immer muss ohne abo geht nichts“):** Die
Windows-App braucht jetzt immer ein StudiNow-Konto und nach der 7-Tage-Probe ein Abo (Plus oder Pro AI); ohne Abo nur
ansehen und exportieren (`app/account_mode.py`, `docs/ABO-SYSTEM.md` Abschnitt 3d). „Abschließen“ öffnet die
Stripe-Bezahlseite des StudiNow-Dienstes im Standardbrowser; es gibt keinen Microsoft-Store-Kauf. **Vor der Einreichung
prüfen:** Laut Microsoft-Store-Richtlinie (10.8.x) dürfen Apps, die keine Spiele sind, für digitale Inhalte einen eigenen
oder fremden Zahlungsweg nutzen; die Richtlinie ändert sich, der aktuelle Wortlaut ist nicht geprüft. Im Formular
„Preise und Verfügbarkeit“ bleibt die App selbst kostenlos; im Eintrag ehrlich angeben, dass ein Abo nötig ist
(Beschreibung unten anpassen).

**Eigenschaften:** Kategorie **Bildung** (Unterkategorie je nach Auswahl); Datenschutzerklärung: dein Link; Webseite und
Support: dein Link bzw. deine Adresse.

**Altersfreigabe:** IARC-Fragebogen ausfüllen. Die App enthält keine Gewalt, kein Glücksspiel und keine Kaufanreize. Sie hat
(mit Online-Dienst) eine Community mit Nutzerbeiträgen; im Fragebogen ehrlich ankreuzen. Erwartung: ab 0 bis 3 Jahren
beziehungsweise „USK 0“, je nach Antwort zu Nutzerinhalten ggf. höher.

### Kurzbeschreibung (bis 100 Zeichen)
> Dein Studium an einem Ort: Unterlagen, Stundenplan, Notizen und Lernplan.

### Beschreibung (Deutsch)
> StudiNow holt deine Kurse, Dateien, Termine und Ankündigungen aus Stud.IP bzw. Learnweb und bringt sie in eine ruhige
> Übersicht. Du meldest dich dafür selbst bei deiner Hochschule an, in deren eigenem Anmeldefenster. Wenn du es
> ausdrücklich möchtest, kann die App deine Zugangsdaten lokal auf deinem PC merken; an einen Online-Dienst geschickt
> werden sie nicht.
>
> Das kannst du tun:
> • Unterlagen, Skripte und Übungsblätter automatisch laden und durchsuchen
> • Stundenplan, Fristen und Neuigkeiten deiner Kurse auf einen Blick
> • Nachrichten und Ankündigungen aus Stud.IP lesen (bleiben nur auf deinem PC)
> • Direkt in den PDFs schreiben, markieren und Notizen machen
> • Karteikarten anlegen und lernen, Tests zu deinem Stoff üben
> • Lernplan mit Lernkalender und Wochenansicht
> • Texterkennung für gescannte Seiten, damit auch Scans durchsuchbar sind
> • Hilfe der KI über dein eigenes ChatGPT-Konto, wenn du es verbindest
>
> Deine Daten bleiben auf deinem Gerät. StudiNow ist ein unabhängiges Projekt und steht in keiner Verbindung zu deiner
> Hochschule oder zu Stud.IP.

Bewusst **nicht** beworben: Community, geteilte Lösungen und Pro AI. **Achtung (05.11.2026):** Die Windows-App braucht
jetzt immer ein StudiNow-Konto und nach 7 Tagen Probe ein Abo; die Beschreibung muss das vor der Einreichung sagen
(z. B. „Benötigt ein StudiNow-Konto. 7 Tage kostenlos testen, danach StudiNow Plus oder Pro AI im Abo.“).

### Merkmale (je bis 200 Zeichen)
- Stud.IP und Learnweb: Kurse, Dateien, Stundenplan und Ankündigungen automatisch holen
- Eigener PDF-Editor mit Stift, Textmarker und Notizen
- Karteikarten, Tests und Lernplan in einer App
- Texterkennung für Scans
- Deine Daten bleiben auf deinem PC

### Suchbegriffe (je bis 40 Zeichen, höchstens sieben)
`Stud.IP`, `Learnweb`, `Studium`, `Stundenplan`, `Karteikarten`, `Lernplan`, `PDF Notizen`

### Neuigkeiten in dieser Version
> Erste Fassung im Microsoft Store.

### Hinweise für die Zertifizierung (Notes for certification)
```text
StudiNow ist eine Desktop-App (Tauri-Fenster mit eingebautem lokalem Dienst auf 127.0.0.1 und eingebautem Chromium).
Darum braucht sie die eingeschränkte Fähigkeit runFullTrust: Der lokale Dienst und der Browser für die Hochschul-
Anmeldung laufen als Prozesse neben dem Fenster. Die App öffnet keine Ports nach außen (nur 127.0.0.1).

Ohne Hochschulkonto testen (die Demo ist nur für die Prüfung gedacht und sonst nirgends in der App zu sehen):
1. App starten. Die erste Seite ("Übersicht") zeigt, solange keine Hochschule verbunden ist, ganz unten die Karte
   "Willkommen bei StudiNow". Ganz unten in dieser Karte steht ein kleiner unterstrichener Textlink
   "Ohne Hochschulkonto ansehen (Demo)". Bitte diesen Link anklicken.
2. Die App legt ein Demo-Modul "Grundlagen der Informatik" an: drei PDFs (Skript, Folien, Übungsblatt), Stundenplan,
   Lernkalender, fünf Karteikarten, eine Abgabefrist und eine Ankündigung. Alles ist von uns erfunden, es sind keine
   Inhalte einer Hochschule. Im Demo-Modus verbindet sich die App nicht mit der Hochschule und braucht keine Anmeldung.
3. Solange die Demo läuft, steht über jeder Seite eine schmale Leiste "Demo-Inhalte – erfunden, ohne Hochschule" mit
   dem Knopf "Beenden". "Beenden" (nach Rückfrage) entfernt alles, was die Demo angelegt hat, und führt zurück zur
   ersten Seite mit dem Link.
Die Hochschul-Anmeldung (Stud.IP, Learnweb) funktioniert nur mit einem echten Studierendenkonto; das Passwort gibt der
Nutzer selbst im Anmeldefenster der Hochschule ein. Die App merkt sich die Sitzung (nicht das Passwort), damit der
Nutzer angemeldet bleibt. Nur auf ausdrücklichen Wunsch (Einstellungen, mit Einwilligung) speichert die App die
Zugangsdaten lokal im Datenordner des Nutzers; sie verlassen den PC nicht. Nachrichten aus Stud.IP erscheinen in der
Seitenleiste unter "Nachrichten" (erst mit verbundenem Stud.IP); sie bleiben auf dem PC und werden in Stud.IP nicht als
gelesen markiert.

Die App braucht ein StudiNow-Konto (seit 05.11.2026). Prüfkonto mit aktivem Abo: [im Partner Center unter „Hinweise für
die Zertifizierung“ eintragen – E-Mail und Passwort eines eigens angelegten Kontos mit Tarif Plus oder Pro AI, z. B. per
`python -m app.accounts plan <email> pro_ai` im Dienst]. Kein Kauf über den Microsoft Store, keine Werbung. Die
Texterkennung (Tesseract, Apache-2.0) und PDFium sind mitgeliefert; Lizenzhinweise stehen in der Datei LIZENZEN.txt im
Programmordner.
```

### Demo für die Prüfer: Entscheidung und Stand (05.11.2026)
Seit 05.11.2026 kommt vor der ersten Seite die Anmeldung mit dem StudiNow-Konto: Prüfer brauchen das Prüfkonto (oben);
danach gilt wie bisher: Wie auf dem iPad (Entscheidung des Inhabers 04.11.2026 „Nur für Prüfer“): Normale Nutzer sehen die Demo nirgends. Der
einzige Weg ist der kleine Textlink „Ohne Hochschulkonto ansehen (Demo)“ ganz unten auf der ersten Seite ohne
Hochschulverbindung; unter Einstellungen → Erweitert gibt es die Demo nicht mehr. Der Link erscheint nur, solange keine
Hochschule verbunden ist, keine Zugangsdaten hinterlegt sind und kein Modul existiert, und nur am eigenen PC (nie im
Online-Dienst). Die Leiste „Demo-Inhalte – erfunden, ohne Hochschule“ mit „Beenden“ steht über jeder Seite. Der
Wortlaut ist in `app/static/demo-logic.js` festgelegt und mit den Prüfhinweisen oben gleich.
**Beim Prüfen auf einem echten Windows-Rechner kontrollieren:** dass der Link auf der ersten Seite ohne Hochschulkonto
gefunden wird (ohne vorher etwas zu verbinden) und dass „Beenden“ zur ersten Seite zurückführt.

### Store-Tauglichkeit der Oberfläche (geprüft 05.11.2026, `tests/test_web_windows_shell.py`)
**Überholt für die Windows-App seit 05.11.2026:** Die Windows-App hat jetzt die Konto- und Abo-Pflicht mit Abschluss über
Stripe im Browser (siehe „Kauf in der App“ oben). Ohne Kauf- und Bezahllinks ist nur noch der Einzelplatz ohne
Konto-Pflicht (`serve.py` in der Entwicklung), den `tests/test_web_windows_shell.py` weiter prüft. Externe Links (Stud.IP, Learnweb) öffnen im Fenster der App bzw. im Standardbrowser, nur http und https.

## 4. Was ich noch anpassen kann, wenn du es willst
- **Größe:** Das Paket enthält Chromium (für die Hochschul-Anmeldung) und Tesseract mit rund 165 MB. Beides lässt sich
  noch verkleinern (nur nötige Bibliotheken kopieren). Für die Zulassung im Store ist die Größe kein Hindernis.
- **ARM-Laptops:** Das Paket ist für x64 gebaut. Windows auf ARM führt es per Emulation aus. Ob Chromium und Tesseract dort
  gut laufen, ist ungeprüft.
- **Neue Version:** Version in `package.json`, `tauri.conf.json`, `Cargo.toml` erhöhen (Test prüft Gleichheit), pushen,
  Lauf starten, neues Paket hochladen.

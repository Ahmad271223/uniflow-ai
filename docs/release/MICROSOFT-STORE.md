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
| Mindestens ein Screenshot, besser 4 bis 6, ab 1366 × 768 (PNG) | du: aus der installierten App, am besten mit den Demo-Inhalten (Einstellungen → Erweitert → Demo-Inhalte) |
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

**Kauf in der App:** In dieser Fassung gibt es auf Windows **keinen Kauf in der App** und keinen Link zu einem Bezahlsystem.
Das Abo (Plus, später Pro AI) läuft über den Online-Dienst, den es noch nicht gibt. Sobald es einen Kauf auf Windows gibt,
müssen die Store-Regeln für Zahlungen geprüft werden (die Bedingungen von Microsoft ändern sich; nicht geprüft).

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
> • Direkt in den PDFs schreiben, markieren und Notizen machen
> • Karteikarten anlegen und lernen, Tests zu deinem Stoff üben
> • Lernplan mit Lernkalender und Wochenansicht
> • Texterkennung für gescannte Seiten, damit auch Scans durchsuchbar sind
> • Hilfe der KI über dein eigenes ChatGPT-Konto, wenn du es verbindest
>
> Deine Daten bleiben auf deinem Gerät. StudiNow ist ein unabhängiges Projekt und steht in keiner Verbindung zu deiner
> Hochschule oder zu Stud.IP.

Bewusst **nicht** beworben: Community, geteilte Lösungen und Pro AI. Sie brauchen den Online-Dienst und sind in dieser
Windows-Fassung ohne Konto nicht nutzbar.

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

Ohne Hochschulkonto testen: Start der App → Einstellungen → Erweitert → "Demo-Inhalte anlegen". Danach gibt es ein Demo-
Modul mit drei PDFs, Stundenplan, Lernkalender, einer Frist und einer Ankündigung. Die Hochschul-Anmeldung (Stud.IP,
Learnweb) funktioniert nur mit einem echten Studierendenkonto; das Passwort gibt der Nutzer selbst im Anmeldefenster der
Hochschule ein. Nur auf ausdrücklichen Wunsch (Einstellungen, mit Einwilligung) speichert die App die Zugangsdaten lokal
im Datenordner des Nutzers; sie verlassen den PC nicht.

Kein Kauf in der App, keine Werbung, kein Konto bei uns nötig. Die Texterkennung (Tesseract, Apache-2.0) und PDFium sind
mitgeliefert; Lizenzhinweise stehen in der Datei LIZENZEN.txt im Programmordner.
```

## 4. Was ich noch anpassen kann, wenn du es willst
- **Größe:** Das Paket enthält Chromium (für die Hochschul-Anmeldung) und Tesseract mit rund 165 MB. Beides lässt sich
  noch verkleinern (nur nötige Bibliotheken kopieren). Für die Zulassung im Store ist die Größe kein Hindernis.
- **ARM-Laptops:** Das Paket ist für x64 gebaut. Windows auf ARM führt es per Emulation aus. Ob Chromium und Tesseract dort
  gut laufen, ist ungeprüft.
- **Neue Version:** Version in `package.json`, `tauri.conf.json`, `Cargo.toml` erhöhen (Test prüft Gleichheit), pushen,
  Lauf starten, neues Paket hochladen.

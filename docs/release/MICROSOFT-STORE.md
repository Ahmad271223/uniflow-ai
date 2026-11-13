# StudiNow im Microsoft Store: Einreichung Schritt für Schritt (Stand 13.11.2026)

Für den Inhaber, in einfacher Sprache. Diese Datei ersetzt den Stand vom 05.11.2026 vollständig.

## 0. Ehrliche Bestandsaufnahme (13.11.2026, abends)

**Was fertig ist**

- Die Windows-App selbst ist fertig und wird regelmäßig gebaut. Der Windows-Lauf bei GitHub lief heute um 12:24 Uhr
  grün durch (15 Minuten) und hat zwei Pakete abgelegt: den normalen Installer und das Store-Paket (MSIX).
- Die Bau-Kette prüft sich selbst: Tests, Backend packen, Chromium und Tesseract dazulegen, Paket schnüren, Paket auf
  dem Windows-Rechner installieren, Backend darin starten, wieder deinstallieren.
- Die vier Pflichtseiten im Netz sind erreichbar und liefern Inhalt: `studinow.app/datenschutz`, `/impressum`,
  `/support`, `/nutzungsbedingungen` (heute geprüft, alle antworten mit „200 OK“).
- Store-Texte, Prüfhinweise und fünf Bildschirmfotos sind fertig (Abschnitt 3 und 4).

**Was heute Abend noch nicht geht — und warum**

- **Das fertige Store-Paket kann ich heute noch nicht bauen.** Es fehlt nicht an Technik, sondern an drei Zahlen und
  Namen, die nur du bei Microsoft bekommst (Abschnitt 1, Schritt 2). Ohne sie trägt das Paket eine Test-Kennung
  („PLATZHALTER…“), und Partner Center weist so ein Paket beim Hochladen ab. Sobald du mir die drei Werte gibst,
  dauert der Bau rund 15 bis 20 Minuten.
- **Auf diesem Mac lässt sich ein Windows-Paket grundsätzlich nicht bauen.** Dafür braucht es einen echten
  Windows-Rechner: das Werkzeug `makeappx.exe` aus dem Windows-SDK, der Rust-Übersetzer für Windows und PyInstaller,
  das den Python-Teil nur auf dem System packen kann, für das es gedacht ist. Das ist keine Einstellungssache.
- **Gute Nachricht zur alten Warnung:** In `docs/GITHUB-ABRECHNUNG.md` steht, GitHub baue nichts mehr. Das stimmt
  heute **nicht mehr** — ich habe die letzten Läufe angesehen, der Windows-Lauf ist seit Tagen grün. Der Bau über
  GitHub ist also der Weg.
- **Die App war noch nie auf einem echten, frischen Windows-Rechner.** Sie lief bisher nur auf dem Windows-Rechner von
  GitHub. Das ist das größte verbleibende Risiko (Abschnitt 5).

**Was ich heute geändert habe** (Zweig `windows/store-2026-11-13`, nichts an `develop`)

- Versionsnummer der Windows-App von `0.6.0` auf **`1.0.0`** — die erste Fassung im Store soll 1.0 heißen, wie beim
  iPad.
- `store.json`: aus den unauffälligen Testwerten („UniFlow.Test“) klar erkennbare Platzhalter gemacht, dazu eine Liste,
  welcher Wert wo in Partner Center steht. Ein neuer Test schlägt Alarm, wenn jemand `store_ready` auf `true` setzt,
  ohne die echten Werte einzutragen — so kann kein unbrauchbares Paket in Partner Center landen.
- Die App prüft jetzt beim Start, ob die Windows-Komponente „WebView2“ da ist, und öffnet sonst die Download-Seite von
  Microsoft, statt stumm nichts zu tun. Der Installer lädt sie zusätzlich selbst nach. (Betrifft nur sehr alte
  Windows-10-Fassungen; Windows 11 bringt sie mit.)
- Der Bau läuft jetzt auch auf Zweigen `windows/**`, damit das Store-Paket entstehen kann, ohne `develop` anzufassen.
- Fünf Bildschirmfotos in `docs/release/store-windows/` (1920 × 1080, mit den Demo-Inhalten).

## 1. Deine Liste für heute Abend

| # | Was du tust | Wo | Dauer |
|---|---|---|---|
| 1 | **Entwicklerkonto anlegen**, falls noch nicht geschehen: als Einzelperson registrieren, Microsoft-Konto, Identitätsprüfung. Für Einzelpersonen laut Microsoft kostenlos — beim Anlegen prüfen, ob eine Gebühr verlangt wird, und mir Bescheid sagen. | <https://partner.microsoft.com/dashboard> | 15–30 min, die Prüfung kann Tage dauern |
| 2 | **Namen „StudiNow“ reservieren**: Apps und Spiele → Neues Produkt → MSIX- oder PWA-App → Name `StudiNow`. Ist er vergeben, sag mir den neuen Namen. | Partner Center | 5 min |
| 3 | **Drei Werte abschreiben** und mir schicken: Produktverwaltung → Produktidentität → `Package/Identity/Name`, `Package/Identity/Publisher` (beginnt mit `CN=`), `Package/Properties/PublisherDisplayName`. | Partner Center | 5 min |
| 4 | Warten: **ich trage die Werte ein und lasse das Paket bauen.** | — | 15–20 min |
| 5 | **Einreichung ausfüllen** mit den Texten aus Abschnitt 3 und den Bildern aus Abschnitt 4. Ich kann dich dabei Schritt für Schritt führen. | Partner Center | 30–45 min |
| 6 | **Altersfreigabe**: IARC-Fragebogen. Antworten in Abschnitt 3 unten. | Partner Center | 10 min |
| 7 | **Prüfkonto anlegen**: ein eigenes StudiNow-Konto mit Tarif Pro AI für die Microsoft-Prüfer; E-Mail und Passwort in das Feld „Hinweise für die Zertifizierung“ eintragen. | StudiNow-Dienst | 5 min |
| 8 | **Einreichen.** Das machst nur du, nicht ich. | Partner Center | 1 min |

**Was Geld kostet:** das Entwicklerkonto (laut Microsoft für Einzelpersonen 0 €, bitte beim Anlegen prüfen). Sonst
nichts: Der Store signiert das Paket selbst, ein eigenes Code-Signing-Zertifikat brauchst du **nicht**.

**Was realistisch ist:** Schritt 1 bis 4 schaffst du heute Abend, wenn das Entwicklerkonto schon freigeschaltet ist.
Ist es neu, prüft Microsoft dein Konto erst — das dauert in der Regel ein bis mehrere Tage, und bis dahin geht die
Einreichung nicht. Nach dem Einreichen prüft Microsoft die App noch einmal, meist einige Werktage.

## 2. Die Einreichung: Felder und Einstellungen

**Preise und Verfügbarkeit:** App selbst **kostenlos**; Märkte: Deutschland (oder gleich alle, wie im App Store);
Sichtbarkeit zuerst **„Privat, nur per Link“** zum Testen, danach öffentlich.

**Kauf in der App:** Die App braucht ein StudiNow-Konto. Jedes neue Konto hat **7 Tage Probezeit mit allem**, danach
ein Abo (StudiNow Plus 19,99 €/Jahr oder Pro AI 39,99 €/Jahr); ohne Abo bleibt die App zum Ansehen und Exportieren
nutzbar. „Abschließen“ öffnet die Stripe-Bezahlseite des StudiNow-Dienstes im Standardbrowser — **es gibt keinen Kauf
über den Microsoft Store.** Im Formular bleibt die App trotzdem „kostenlos“; die Abo-Pflicht steht ehrlich in der
Beschreibung.
**Vorher prüfen (wichtig):** Nach der Microsoft-Store-Richtlinie 10.8 dürfen Apps, die keine Spiele sind, für digitale
Inhalte einen eigenen Zahlungsweg nutzen. Der Wortlaut ändert sich; ich habe ihn nicht geprüft. Lies die Stelle im
Partner Center einmal selbst, bevor du einreichst — das ist der häufigste Ablehnungsgrund bei so einer App.

**Eigenschaften:** Kategorie **Bildung**. Datenschutzerklärung: `https://studinow.app/datenschutz`. Webseite:
`https://studinow.app`. Support: `https://studinow.app/support` bzw. `support@studinow.app`.

**Altersfreigabe (IARC-Fragebogen):** keine Gewalt, kein Glücksspiel, keine Kaufanreize, keine Werbung. **Ehrlich
ankreuzen, dass es Nutzerinhalte gibt:** StudiNow hat eine Community (Fragen, Antworten, geteilte Lösungen,
Lerngruppen) mit Meldefunktion. Erwartung: USK 0 bis 6, je nach Antwort zu Nutzerinhalten auch höher.

## 3. Die Texte (neu geschrieben, Stand 13.11.2026)

### Kurzbeschreibung (bis 100 Zeichen)
> Lernmanagementsystem für Hochschulen: Unterlagen, Stundenplan, Lernplan und Noten an einem Ort.

### Beschreibung (Deutsch)
> StudiNow ist ein Lernmanagementsystem für Hochschulen in ganz Deutschland – zum Start mit voller Anbindung an die
> Leibniz Universität Hannover, die Hochschule Hannover und die Universität Hildesheim. Weitere Hochschulen folgen.
>
> StudiNow holt deine Kurse, Dateien, Termine und Ankündigungen aus Stud.IP, Learnweb oder Moodle und bringt sie in
> eine ruhige Übersicht. Du meldest dich dafür selbst bei deiner Hochschule an, in deren eigenem Anmeldefenster.
>
> Das kannst du tun:
> • Skripte, Folien und Übungsblätter automatisch laden, nach Modulen und Wochen sortiert
> • Stundenplan, Abgabefristen und Neuigkeiten deiner Kurse auf einen Blick
> • Direkt in deinen PDFs schreiben, markieren und Notizen machen
> • Karteikarten lernen und Wochentests zu deinem Stoff üben
> • Lernkalender und Lernziele: Du sagst, wie viele Stunden du bis zur Klausur lernen willst, StudiNow verteilt sie
>   auf deine freie Zeit
> • Bestandene Prüfungen, Noten und Leistungspunkte aus dem Prüfungssystem deiner Hochschule
> • Texterkennung für gescannte Seiten, damit auch Scans durchsuchbar sind
> • Uni-Mail, Mensaplan und Raumfinder
> • KI-Hilfe zu deinen eigenen Unterlagen (StudiNow Pro AI)
>
> Dein Konto und dein Abo:
> StudiNow braucht ein kostenloses StudiNow-Konto. Jedes neue Konto kann 7 Tage lang alles ausprobieren. Danach
> brauchst du ein Abo: StudiNow Plus für 19,99 € im Jahr oder StudiNow Pro AI mit KI für 39,99 € im Jahr. Ohne Abo
> bleiben deine Unterlagen lesbar und du kannst alles exportieren – deine Daten gehören dir.
>
> Deine Daten:
> Deine Unterlagen, Notizen und Zeichnungen liegen auf deinem PC. Dein Passwort für die Hochschule bleibt auf deinem
> Gerät und wird nie an StudiNow geschickt. Für die KI wirst du einmal gefragt, bevor etwas von deinen Unterlagen
> gelesen wird – erst nach „Okay, los“ geht etwas raus.
>
> StudiNow ist ein unabhängiges Projekt und steht in keiner Verbindung zu deiner Hochschule, zu Stud.IP, Learnweb
> oder Moodle.

**Bewusst nicht beworben:** Community und geteilte Lösungen (sie stehen aber ehrlich in der Altersfreigabe und in den
Prüfhinweisen).

**Was ich aus dem alten Text gestrichen habe und warum:**

- *„Hilfe der KI über dein eigenes ChatGPT-Konto, wenn du es verbindest.“* Den eigenen OpenAI-Schlüssel gibt es nur auf
  dem alten Zweig `windows/1.0`, **nicht** im heutigen Stand. Wäre eine erfundene Funktion gewesen.
- *„Nachrichten und Ankündigungen aus Stud.IP lesen (bleiben nur auf deinem PC)“* — gibt es noch, ist aber nur für die
  LUH; steckt jetzt in „Neuigkeiten deiner Kurse“.
- *„Deine Daten bleiben auf deinem Gerät“* als pauschaler Satz. Das stimmt für Unterlagen und Notizen, nicht für Konto,
  Abo, Community und KI. Jetzt steht genau da, was wo liegt.
- Die Preise 1,99 €/3,99 € im Monat. Seit 09.11.2026 gibt es nur noch Jahresabos.

### Merkmale (je bis 200 Zeichen)
- Kurse, Dateien, Stundenplan und Ankündigungen automatisch aus Stud.IP, Learnweb oder Moodle holen
- Eigener PDF-Editor mit Stift, Textmarker und Notizen
- Karteikarten, Wochentests und Lernkalender in einer App
- Lernziele: Stunden bis zur Klausur eintragen, StudiNow plant sie ein
- Noten und Leistungspunkte aus dem Prüfungssystem deiner Hochschule

### Suchbegriffe (je bis 40 Zeichen, höchstens sieben)
`Stud.IP`, `Learnweb`, `Studium`, `Stundenplan`, `Karteikarten`, `Lernplan`, `PDF Notizen`

### Neuigkeiten in dieser Version
> Erste Fassung im Microsoft Store.

### Hinweise für die Zertifizierung (Notes for certification)
```text
StudiNow ist eine Desktop-App (Tauri-Fenster mit eingebautem lokalem Dienst auf 127.0.0.1 und eingebautem Chromium).
Darum braucht sie die eingeschraenkte Faehigkeit runFullTrust: Der lokale Dienst und der Browser fuer die
Hochschul-Anmeldung laufen als Prozesse neben dem Fenster. Die App oeffnet keine Ports nach aussen (nur 127.0.0.1).

PRUEFKONTO (bitte hier eintragen, mit aktivem Tarif Pro AI):
  E-Mail:   ...
  Passwort: ...
Die App verlangt beim Start ein StudiNow-Konto. Jedes neue Konto hat 7 Tage Probezeit mit allen Funktionen; danach
ist ein Abo noetig (StudiNow Plus 19,99 EUR/Jahr, Pro AI 39,99 EUR/Jahr). Der Abschluss laeuft ueber Stripe im
Standardbrowser, nicht ueber den Microsoft Store. Es gibt keine Werbung.

OHNE HOCHSCHULKONTO TESTEN (die Demo ist nur fuer die Pruefung gedacht und sonst nirgends in der App zu sehen):
1. Nach der Anmeldung mit dem Pruefkonto zeigt die erste Seite ("Uebersicht"), solange keine Hochschule verbunden
   ist, ganz unten die Karte "Willkommen bei StudiNow". Ganz unten in dieser Karte steht ein kleiner unterstrichener
   Textlink "Ohne Hochschulkonto ansehen (Demo)". Bitte diesen Link anklicken.
2. Die App legt ein Demo-Modul "Grundlagen der Informatik" an: drei PDFs (Skript, Folien, Uebungsblatt), Stundenplan,
   Lernkalender, fuenf Karteikarten, eine Abgabefrist und eine Ankuendigung. Alles ist von uns erfunden, es sind
   keine Inhalte einer Hochschule. Im Demo-Modus verbindet sich die App nicht mit der Hochschule.
3. Solange die Demo laeuft, steht ueber jeder Seite eine schmale Leiste "Demo-Inhalte - erfunden, ohne Hochschule"
   mit dem Knopf "Beenden". "Beenden" entfernt nach Rueckfrage alles, was die Demo angelegt hat.

HOCHSCHUL-ANMELDUNG: funktioniert nur mit einem echten Studierendenkonto. Das Passwort gibt der Nutzer selbst im
Anmeldefenster seiner Hochschule ein; es wird nie an einen Server von StudiNow geschickt. Nur auf ausdruecklichen
Wunsch (Einstellungen, mit Einwilligung) merkt sich die App die Zugangsdaten im Datenordner des Nutzers auf diesem PC.

KI: Vor der ersten Nutzung erscheint ein Hinweis, was an den KI-Dienst geschickt wird; erst nach "Okay, los" passiert
etwas. KI-Funktionen gehoeren zum Tarif Pro AI.

NUTZERINHALTE: Es gibt eine Community (Fragen, Antworten, geteilte Loesungen, Lerngruppen) mit Meldefunktion. Sie ist
Teil des Tarifs Plus und in der Altersfreigabe angegeben.

MITGELIEFERT: Texterkennung (Tesseract, Apache-2.0), PDFium und Chromium. Die Lizenzhinweise stehen in der Datei
LIZENZEN.txt im Programmordner.
```

## 4. Bildschirmfotos

Fünf Stück liegen fertig in `docs/release/store-windows/`, alle 1920 × 1080 PNG (Microsoft verlangt mindestens
1366 × 768). Sie zeigen die Demo-Inhalte, nicht die Daten einer echten Hochschule; die schmale Leiste „Demo-Inhalte –
erfunden, ohne Hochschule“ ist im Bild und darf da sein.

| Datei | Zeigt |
|---|---|
| `1-uebersicht.png` | Startseite: Mensa, „Was mache ich heute?“, heutiger Plan, Termine, Neuigkeiten, Module |
| `2-lernkalender.png` | Lernkalender in der Wochenansicht mit Vorlesungen, Lernblöcken und Fortschritt |
| `3-pdf-editor.png` | Ein Skript im eigenen PDF-Editor mit Stift- und Markerleiste |
| `4-karteikarten.png` | Karteikarten-Stapel mit Leitner-Fächern und „Üben“ |
| `5-module.png` | „Meine Module“ mit Lernstand, nächstem Termin und Zahlen |

Nimm sie in dieser Reihenfolge; das erste Bild ist das Titelbild im Store.

Erzeugt mit der echten Weboberfläche der App (dieselbe, die im Windows-Fenster läuft). Neu erzeugen lassen sich sie
jederzeit — sag mir Bescheid, wenn du andere Seiten im Store zeigen willst.

## 5. Vor dem Veröffentlichen auf einem echten Windows-PC prüfen

Die App lief bisher nur auf dem Windows-Rechner von GitHub. Nimm die Testfassung `…-test.msix` aus dem Lauf
(Anleitung in `apps/windows/msix/README.md`) oder den normalen Installer und geh das durch:

1. Installieren und starten; die Anmeldung mit dem StudiNow-Konto erscheint.
2. Der Link „Ohne Hochschulkonto ansehen (Demo)“ ist auf der ersten Seite zu finden, ohne vorher etwas zu verbinden.
   „Beenden“ führt zurück.
3. Sich mit einem echten Hochschulkonto anmelden, ein Modul abgleichen, ein PDF öffnen und darin schreiben.
4. „Abo & Tarife“ → „Abschließen“ öffnet die Stripe-Seite im Browser.
5. Zweiter Start, Fenster schließen, deinstallieren (`docs/FERTIGSTELLUNG-WINDOWS-UND-DIENST.md`, Abschnitt 5).

Wenn hier etwas nicht geht, lieber einen Tag später einreichen als abgelehnt werden.

## 6. Offene Punkte, die ich dir nicht abnehmen kann

- **Die drei Werte aus Partner Center** (Abschnitt 1, Schritt 3). Ohne sie gibt es kein Store-Paket.
- **Anmelden bei Microsoft, Einreichen und Bezahlen** macht nur du. Ich gebe nie deine Zugangsdaten ein.
- **Prüfkonto mit Pro AI** für die Microsoft-Prüfer.
- **Richtlinie 10.8** zum eigenen Bezahlweg einmal selbst lesen (Abschnitt 2).

## 7. Zwei Entscheidungen, die ich dir vorlegen muss

**a) Welcher Stand soll in den Store?** Das heutige `develop` (Build 38) ist der neueste Stand: drei Hochschulen,
Lernziele, Konto löschen, alles, was auf dem iPad in 1.0.3 steckt. Der alte Zweig `windows/1.0` vom 08.11. hat
dagegen drei Windows-Verbesserungen, die nie in `develop` übernommen wurden:

| Was | Nutzen | Mein Rat |
|---|---|---|
| Hochschul-Passwort verschlüsselt in der `.env` (DPAPI) | Heute steht es im Klartext im Datenordner auf dem PC des Nutzers. Verschlüsselt wäre deutlich besser. | **Nachholen, aber nicht heute Abend** — es ist eine Sicherheitsänderung, die ich ohne Windows-Rechner nicht wirklich prüfen kann. Ein eigener Auftrag. |
| Eigener OpenAI-Schlüssel („mein ChatGPT“) | Nice-to-have | Weglassen; steht auch nicht mehr in der Beschreibung. |
| „Nur LUH anbieten“ | Überholt — Hildesheim und Hochschule Hannover sind inzwischen fertig | Weglassen. |

Mein Vorschlag: **Store-Paket aus `develop`** (plus meine heutigen kleinen Änderungen), und das verschlüsselte
Passwort als nächsten Auftrag hinterher. Wenn du das anders willst, sag es vor dem Bauen.

**b) Versionsnummer 1.0.0.** Ich habe die Windows-App von 0.6.0 auf 1.0.0 gesetzt, passend zum iPad. Falls du lieber
bei 0.6 bleiben willst, sag Bescheid — im Store muss jede neue Fassung eine höhere Nummer haben, umkehren geht später
nicht mehr.

## 8. Wenn du mir die drei Werte gibst: was dann passiert

1. Ich trage sie in `apps/windows/msix/store.json` ein und setze `store_ready` auf `true`.
2. Ich schiebe den Zweig `windows/store-2026-11-13` zu GitHub (frage dich vorher). Der Bau startet von selbst.
3. Nach 15 bis 20 Minuten liegt im Lauf das Artefakt `uniflow-windows-msix` mit
   `StudiNow_1.0.0.0_x64.msix` (unsigniert — der Store signiert selbst) und einer Testfassung zum Ausprobieren.
4. Du lädst die unsignierte Datei in Partner Center hoch, füllst die Felder aus Abschnitt 2 und 3 aus, hängst die
   Bilder aus Abschnitt 4 an und reichst ein.

## 9. Später

- **Größe:** Das Paket enthält Chromium und Tesseract, zusammen rund 165 MB. Lässt sich verkleinern, ist für die
  Zulassung aber kein Hindernis.
- **ARM-Laptops:** Das Paket ist für x64. Windows auf ARM führt es per Emulation aus; ungeprüft.
- **Neue Fassung:** Version in `apps/windows/package.json`, `src-tauri/tauri.conf.json` und `src-tauri/Cargo.toml`
  erhöhen (ein Test prüft, dass alle drei gleich sind), bauen lassen, neues Paket hochladen. Danach spielt der Store
  jedem Nutzer das Update von selbst ein.

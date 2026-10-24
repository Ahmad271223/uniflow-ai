# Checkliste: erster Test mit MacBook Air und iPad

Alles hier ist bisher **nicht** auf echter Hardware geprüft. Gebaut und getestet wird nur in GitHub Actions
(Linux + iPad-Simulator). Ergebnisse bitte je Punkt mit OK / Fehler + kurzer Beschreibung festhalten.

## 1. Einrichten (einmalig, ca. 30 min)

1. Xcode aus dem App Store installieren (16.4 oder neuer), einmal öffnen, Zusatzkomponenten installieren lassen.
2. Xcode → Settings → Accounts → Apple-ID hinzufügen (kostenlos reicht für 7 Tage gültige Installationen).
3. Terminal:
   ```bash
   brew install xcodegen
   ```
   ```bash
   git clone https://github.com/Ahmad271223/uniflow-ai.git && cd uniflow-ai && git switch develop
   ```
   ```bash
   cd apps/apple && xcodegen generate && open UniFlow.xcodeproj
   ```
4. Ziel „UniFlow“ → Signing & Capabilities → Team = eigene Apple-ID. Bundle-ID bei Bedarf eindeutig machen
   (z. B. `de.uniflow.ai.<name>`).
5. iPad per USB-C anschließen, „Diesem Computer vertrauen“. Auf dem iPad: Einstellungen → Datenschutz & Sicherheit →
   Entwicklermodus an (Neustart).
6. In Xcode oben das iPad als Ziel wählen, Run (⌘R). Beim ersten Start auf dem iPad: Einstellungen → Allgemein →
   VPN & Geräteverwaltung → Entwickler-App vertrauen.
7. Am PC `Start-iPad.cmd` starten. In der App Adresse (z. B. `http://amo.fritz.box:8765`) und PIN eingeben.
   iOS fragt nach „Lokales Netzwerk“ → erlauben.

## 2. Tests am Gerät

| Nr. | Test | Erwartung |
| --- | --- | --- |
| 1 | PDF öffnen, 15 min schreiben, dabei zoomen und scrollen | Striche erscheinen ohne Verzögerung, nichts springt |
| 2 | 100 kurze Striche mit kurzem Abheben, Hand liegt auf | jeder Strich da, keine Fingerstriche, kein Scrollen durch die Hand |
| 3 | Stift über den Rand der Seite hinaus ziehen | kein Verrutschen der Seite |
| 4 | Zwei Finger zoomen, sofort danach schreiben | Zoom bleibt, Strich an der richtigen Stelle |
| 5 | iPad drehen (hoch ↔ quer) | Zoom bleibt relativ gleich, Striche an der richtigen Stelle |
| 6 | Werkzeugpalette: Stift, Textmarker, Bleistift, Radierer (pixel + Strich), Lasso, Lineal, Farben, Stärken | alles wählbar, Auswahl bleibt nach dem Scrollen |
| 7 | Pencil-Doppeltippen (Pencil 2 / Pro) | wechselt wie in den iPad-Einstellungen eingestellt |
| 8 | Rückgängig/Wiederholen in der Leiste und in der Palette | wirkt auf das aktuelle Dokument |
| 9 | Weit scrollen, zurück | Striche unverändert, keine Verzögerung beim Zurückkommen |
| 10 | App schließen (wegwischen), neu öffnen | alle Striche an derselben Stelle |
| 11 | Flugmodus: schreiben, App schließen, WLAN an, App öffnen | Status „Offline · … lokal gesichert“, danach „Gespeichert“, Striche am PC sichtbar |
| 12 | Gleiche Seite gleichzeitig am PC (Browser) und iPad beschreiben | nach dem Speichern auf beiden Geräten alle Striche |
| 13 | Am PC einen iPad-Strich löschen, iPad neu öffnen | Strich ist weg |
| 14 | Mit dem Pixel-Radierer die Mitte eines Strichs löschen, am PC ansehen | im Browser fehlt die Mitte ebenfalls |
| 15 | Querformat-/gedrehte PDF-Seite beschreiben, am PC ansehen | Striche an derselben Stelle |
| 16 | Großes Skript (100+ Seiten) öffnen und schnell durchscrollen | keine Abstürze, Speicher stabil (Xcode → Debug Navigator) |
| 17 | PDF-Export mit Notizen (sobald vorhanden) | Notizen im exportierten PDF |
| 18 | Dark Mode | Seiten hell, Bedienelemente lesbar |

## 3. Beobachten in Xcode

- Debug Navigator → Memory beim Scrollen (Test 16) und beim Schreiben (Test 1).
- Konsole: Meldungen mit „UniFlow“ oder „PencilKit“.
- Bei Abstürzen: Window → Devices and Simulators → View Device Logs.

## 4. Ergebnis zurück ins Projekt

Je Fehler: Nummer aus der Tabelle, Gerät (iPad-Modell, iPadOS-Version, Pencil-Modell), was passiert ist,
wenn möglich Bildschirmaufnahme. Daraus entsteht die nächste Blocker-Liste in `docs/BESTANDSAUFNAHME.md`.

# Abnahmeliste PDF-Editor (iPad mit Apple Pencil)

Stand 27.10.2026 · Grundlage: `docs/PENCILKIT-ANALYSE-PLAN.md` (Schritt 0 / P0-1) · Messwerte aus dem Simulator:
`docs/EDITOR-MESSUNG.md`.

Diese Liste prüft der Inhaber am **echten iPad mit Apple Pencil**, bevor der Editor umgebaut wird (Schritt 2 ff.), und
danach nach jedem Schritt erneut. Alles hier ist bisher **nicht am Gerät geprüft**. Was der Simulator schon gemessen
hat, steht bei den Punkten als Hinweis („Simulator: …“) – das ersetzt den Gerätetest nicht.

**So ausfüllen:** je Zeile ein Kreuz bei **bestanden** oder **nicht bestanden** und bei Bedarf eine kurze Notiz (was
genau passiert ist, Seite, Zoom, Werkzeug). Punkte, die mit diesem Gerät oder Pencil nicht gehen, mit „entfällt“
notieren. Bei „nicht bestanden“ hilft eine Bildschirmaufnahme (Kontrollzentrum → Bildschirmaufnahme).

## 0. Gerät und Vorbereitung

| Angabe | Eintrag |
|---|---|
| Datum | |
| iPad-Modell (Einstellungen → Allgemein → Info) | |
| iPadOS-Version | |
| Apple Pencil (1. Generation / USB-C / 2. Generation / Pro) | |
| App-Stand (Commit auf `develop`, in Xcode oben links) | |
| Freier Speicher auf dem iPad | |

**App auf das iPad bringen (ohne bezahltes Entwicklerkonto):**

1. Xcode → Settings → Accounts → eigene Apple-ID hinzufügen (kostenloses „Personal Team“, Installation gilt 7 Tage).
2. Terminal: `cd apps/apple && xcodegen generate && open UniFlow.xcodeproj`.
3. Ziel „UniFlow“ → Signing & Capabilities → Team = eigene Apple-ID. Ist die Bundle-ID schon vergeben, eine eigene
   wählen (z. B. `de.uniflow.ai.test`). Fehlermeldungen zu „Sign in with Apple“ oder „iCloud“ sind ohne bezahltes
   Konto normal: diese Berechtigungen dann unter Signing & Capabilities entfernen (nur lokal, nicht einchecken).
4. iPad per Kabel anschließen, „Diesem Computer vertrauen“; auf dem iPad Einstellungen → Datenschutz & Sicherheit →
   Entwicklermodus an (Neustart). Beim ersten Start: Einstellungen → Allgemein → VPN & Geräteverwaltung → Entwickler-App
   vertrauen.
5. Schreiben braucht Plus. Ohne echte Abo-Produkte: Product → Scheme → Edit Scheme → Run → Arguments → bei „Arguments
   Passed On Launch“ `-UFPlan plus` eintragen (nur Debug-Build). Dann Run (⌘R).
6. Beim ersten Start „Anmeldung überspringen (Debug)“ (ohne bezahltes Konto geht „Mit Apple anmelden“ nicht), dann
   Hochschule wählen und selbst anmelden – oder ohne Hochschule über Bibliothek → Neu → „PDF importieren“ eigene PDFs
   aus Dateien holen.

**Testdokumente** (eigene Dateien, bleiben auf dem iPad):

| Kürzel | Dokument | Woher |
|---|---|---|
| D1 | Vorlesungsfolien, 20–60 Seiten | Stud.IP oder „PDF importieren“ |
| D2 | großes Skript, 300–500 Seiten | Stud.IP oder „PDF importieren“ |
| D3 | Übungsblatt (für die geteilte Ansicht mit D1) | Stud.IP oder „PDF importieren“ |
| D4 | PDF mit Querformat- oder gedrehten Seiten | z. B. Folien im Querformat |
| D5 | Seiten in den Formaten A6 bis A0 | siehe Abschnitt 6 |

Vor dem Test einmal in Xcode prüfen, dass die App im **Debug**-Build läuft (Schema „UniFlow“, Ziel = das iPad).

## 1. Schreibgefühl und Verzögerung

| Nr. | Schritt | Erwartung | Ergebnis | Notiz |
|---|---|---|---|---|
| 1.1 | D1 öffnen, Werkzeug Stift, 5 min normal mitschreiben (Wörter, Formeln, kleine Zeichen wie i-Punkte) | Tinte folgt der Spitze ohne sichtbaren Abstand, kein Ruckeln, keine fehlenden Punkte | ☐ bestanden ☐ nicht bestanden | |
| 1.2 | Schnelle Kringel und lange Linien, dabei Druck wechseln | Strichbreite folgt dem Druck, Linien bleiben glatt | ☐ bestanden ☐ nicht bestanden | |
| 1.3 | Nach dem Schreiben auf die Statusanzeige oben rechts sehen | kurz „Speichert…“ bzw. „Lokal gesichert · … wartet“, danach „Gespeichert“; Schreiben stockt dabei nie | ☐ bestanden ☐ nicht bestanden | |
| 1.4 | Verzögerung messen (optional): Zeitlupe des iPhones (240 B/s) auf Spitze und Tinte, schnelle Linie ziehen | Abstand Spitze ↔ Tinte höchstens 2–3 Bilder (etwa 10 ms); Wert notieren | ☐ bestanden ☐ nicht bestanden | Bilder: |
| 1.5 | „Nur Stift“ (Leiste oben) an: mit dem Finger über die Seite wischen | Finger scrollt, schreibt nie | ☐ bestanden ☐ nicht bestanden | |
| 1.6 | „Finger zeichnet“: mit einem Finger schreiben, mit zwei Fingern scrollen | ein Finger schreibt, zwei Finger scrollen und zoomen | ☐ bestanden ☐ nicht bestanden | |
| 1.7 | Stift über den Seitenrand hinaus ziehen, auch in die Lücke zur nächsten Seite | Seite verrutscht nicht, Strich endet am Rand dieser Seite (Striche gelten je Seite) | ☐ bestanden ☐ nicht bestanden | |

## 2. Handballen, Doppeltippen, Squeeze, Hover

| Nr. | Schritt | Erwartung | Ergebnis | Notiz |
|---|---|---|---|---|
| 2.1 | 100 kurze Striche schreiben, dabei Hand und Handballen auf dem Display ablegen | jeder Strich da, keine Striche vom Handballen, kein Scrollen oder Zoomen durch die Hand | ☐ bestanden ☐ nicht bestanden | |
| 2.2 | Hand liegt auf, Stift kurz abheben und sofort weiterschreiben | erster Punkt des neuen Strichs geht nicht verloren | ☐ bestanden ☐ nicht bestanden | |
| 2.3 | Doppeltippen auf den Pencil (nur 2. Generation und Pro) | wirkt wie in Einstellungen → Apple Pencil eingestellt (z. B. Radierer ↔ letztes Werkzeug). Die App hat dafür keinen eigenen Code, es ist Verhalten der Systempalette | ☐ bestanden ☐ nicht bestanden ☐ entfällt | Einstellung: |
| 2.4 | Squeeze (nur Pencil Pro, ab iPadOS 17.5) | Systemverhalten, z. B. kleine Palette an der Spitze; notieren, was passiert | ☐ bestanden ☐ nicht bestanden ☐ entfällt | |
| 2.5 | Hover: Stift knapp über die Seite halten (nur iPads mit Hover-Unterstützung) | Vorschau der Spitze in Farbe und Größe des Werkzeugs, kein Strich, kein Scrollen | ☐ bestanden ☐ nicht bestanden ☐ entfällt | |

## 3. Palette, Radierer, Lasso, Rückgängig

| Nr. | Schritt | Erwartung | Ergebnis | Notiz |
|---|---|---|---|---|
| 3.1 | Palette: Stift, Bleistift, Textmarker, Füller, Fineliner, Wasserfarbe, Wachsmalstift nacheinander wählen und je einen Strich ziehen | jedes Werkzeug zeichnet wie in der Palette angezeigt; Textmarker liegt durchscheinend über dem PDF-Text | ☐ bestanden ☐ nicht bestanden | |
| 3.2 | Farben und Stärken wechseln, eigene Farbe wählen | Auswahl gilt sofort; nach dem Wegscrollen auf eine andere Seite und zurück ist dasselbe Werkzeug gewählt | ☐ bestanden ☐ nicht bestanden | |
| 3.3 | Palette bleibt beim Scrollen über 10 Seiten | Palette schließt sich nicht | ☐ bestanden ☐ nicht bestanden | |
| 3.4 | Radierer „Pixel“: Mitte eines Strichs wegradieren | nur die Mitte fehlt, beide Enden bleiben | ☐ bestanden ☐ nicht bestanden | |
| 3.5 | Radierer „Objekt“: einen Strich antippen | ganzer Strich weg, sonst nichts | ☐ bestanden ☐ nicht bestanden | |
| 3.6 | Lasso: mehrere Striche umkreisen, verschieben | Striche bewegen sich mit, nach dem Loslassen bleiben sie dort (auch nach Wegscrollen und Zurück) | ☐ bestanden ☐ nicht bestanden | |
| 3.7 | Lasso über einen Text, der mit „Text hinzufügen“ angelegt wurde | **bekannt:** das Lasso erfasst nur Striche, der Text bleibt stehen (Plan B2, kommt mit Schritt 6) | ☐ wie beschrieben ☐ anders | |
| 3.8 | Lineal aus der Palette: gerade Linie daran entlang ziehen | Linie gerade; notieren, ob das Lineal auf mehreren sichtbaren Seiten gleichzeitig erscheint | ☐ bestanden ☐ nicht bestanden | |
| 3.9 | Auf Seite 2 schreiben, auf Seite 9 schreiben, dann dreimal „Rückgängig“ (Leiste oben) | nimmt die Striche in umgekehrter Reihenfolge zurück, springt dabei zur betroffenen Seite; „Wiederholen“ bringt sie zurück | ☐ bestanden ☐ nicht bestanden | |
| 3.10 | Rückgängig über die Palette und, falls Tastatur da, ⌘Z / ⇧⌘Z; mit drei Fingern nach links wischen | gleiche Wirkung wie die Leiste | ☐ bestanden ☐ nicht bestanden | |
| 3.11 | Ebenen → „Meine Notizen“ aus, dann Rückgängig versuchen | nichts wird zurückgenommen, Hinweis „Meine Notizen ausgeblendet – nur ansehen“; nach dem Einblenden wirkt Rückgängig wieder | ☐ bestanden ☐ nicht bestanden | |

## 4. Zoom-Schärfe und schnelles Blättern

| Nr. | Schritt | Erwartung | Ergebnis | Notiz |
|---|---|---|---|---|
| 4.1 | Auf D1 eine Zeile mit dünnem Stift schreiben, dann mit zwei Fingern auf 200 %, 400 % und das Maximum zoomen (Anzeige oben rechts, Maximum = 6-fach der eingepassten Breite) | Tinte bleibt so scharf wie der PDF-Text daneben. **Simulator:** Tinte wird mit dem Zoom weicher (Kante 0,5 px eingepasst, rund 5 px beim Maximum), die PDF bleibt scharf (1 px) – bitte genau hinsehen und je Stufe notieren | ☐ bestanden ☐ nicht bestanden | 200 %: · 400 %: · Max: |
| 4.2 | Beim Maximum weiterschreiben | Strich erscheint unter der Spitze, nicht versetzt | ☐ bestanden ☐ nicht bestanden | |
| 4.3 | Zoomen und sofort danach schreiben | Zoom bleibt, Strich an der richtigen Stelle | ☐ bestanden ☐ nicht bestanden | |
| 4.4 | D2 öffnen, mit einem Finger schnell bis zum Ende und zurück wischen | flüssig, kein Absturz, Seiten erscheinen ohne lange weiße Flächen; Zeit bis zum Ende notieren | ☐ bestanden ☐ nicht bestanden | Zeit: |
| 4.5 | Auf 20 Seiten von D2 je eine halbe Seite schreiben, dann schnell darüber blättern | Notizen erscheinen auf jeder Seite. **Simulator:** bei voll beschriebenen Seiten erscheinen die Striche beim schnellen Blättern erst verzögert (Laden staut sich) – notieren, wie lange eine Seite ohne Notizen zu sehen ist | ☐ bestanden ☐ nicht bestanden | Verzögerung: |
| 4.6 | Weit wegscrollen und zurück zu einer beschriebenen Seite | Striche unverändert, Rückgängig wirkt noch auf diese Seite | ☐ bestanden ☐ nicht bestanden | |
| 4.7 | Dunkelmodus an (Kontrollzentrum) | Seiten bleiben weiß, schwarze Tinte bleibt schwarz, Bedienelemente lesbar | ☐ bestanden ☐ nicht bestanden | |

## 5. Geteilte Ansicht

| Nr. | Schritt | Erwartung | Ergebnis | Notiz |
|---|---|---|---|---|
| 5.1 | D3 öffnen, oben „Geteilt“ → D1 daneben öffnen (oder „Passende Skriptstelle“ → „Daneben öffnen“) | beide Dokumente nebeneinander, Breite verstellbar | ☐ bestanden ☐ nicht bestanden | |
| 5.2 | Abwechselnd links und rechts schreiben | eine Palette für beide, jedes Dokument speichert seine eigenen Striche | ☐ bestanden ☐ nicht bestanden | |
| 5.3 | Danach zweimal „Rückgängig“ | nimmt den zuletzt geschriebenen Strich zurück, egal in welchem Dokument | ☐ bestanden ☐ nicht bestanden | |
| 5.4 | „Teilung beenden“, beide Dokumente einzeln neu öffnen | alle Striche beider Dokumente da | ☐ bestanden ☐ nicht bestanden | |
| 5.5 | iPad-Fenster: UniFlow zweimal nebeneinander (Split View oder Stage Manager) und in beiden **dasselbe** Testdokument öffnen, in beiden schreiben, beide schließen, neu öffnen | **Risiko (Plan B11, nicht geprüft):** es gibt keine Sperre für doppelt geöffnete Dokumente. Nur mit einem Testdokument! Notieren, ob danach Striche fehlen | ☐ alles da ☐ Striche fehlen ☐ entfällt | |

## 6. Eingefügte Seiten A6 bis A0

Das iPad kann heute selbst nur eine leere Seite **in der Größe der Seite davor** einfügen (Mehr → „Leere Seite
danach“); andere Formate fehlen noch (Plan B10, Schritt 5). Seiten in A6 bis A0 entstehen im Web-Editor (Notizbuch mit
Format A6…A2, Whiteboard „Groß (A1 quer)“ / „Riesig (A0 quer)“) und kommen nur im Debug-Build über Einstellungen →
Entwicklung → eigener Server aufs iPad. Ohne PC: 6.1 bis 6.4 mit „entfällt“ notieren.

| Nr. | Schritt | Erwartung | Ergebnis | Notiz |
|---|---|---|---|---|
| 6.1 | Dokument mit Seiten A6, A5, A4, A3, A2 öffnen und auf jede Seite in die Mitte schreiben | jede Seite hat ihre Größe, Strich bleibt in der Mitte; im Browser liegt er an derselben Stelle | ☐ bestanden ☐ nicht bestanden ☐ entfällt | |
| 6.2 | Whiteboard A1 quer und A0 quer öffnen, schreiben, zoomen | Schreiben flüssig, kein Absturz; Speicher in Xcode notieren (siehe Abschnitt 11) | ☐ bestanden ☐ nicht bestanden ☐ entfällt | Speicher: |
| 6.3 | Dokument, in dem A4-Seiten **und** eine A0-Seite vorkommen, eingepasst ansehen | **Simulator:** PDFKit passt auf die breiteste Seite ein – A4-Seiten erscheinen dann sehr klein (etwa ein Sechstel der Breite) und lassen sich höchstens auf rund 150 % zoomen. Notieren, ob das am Gerät auch so ist | ☐ wie beschrieben ☐ anders ☐ entfällt | |
| 6.4 | Nach einer A3-Seite „Leere Seite danach“ | neue Seite hat A3-Größe | ☐ bestanden ☐ nicht bestanden ☐ entfällt | |

## 7. Drehen

| Nr. | Schritt | Erwartung | Ergebnis | Notiz |
|---|---|---|---|---|
| 7.1 | iPad drehen (hoch ↔ quer), eingepasst und gezoomt | eingepasst bleibt eingepasst, ein eigener Zoom bleibt relativ gleich; Striche an der richtigen Stelle | ☐ bestanden ☐ nicht bestanden | |
| 7.2 | Auf D4 (Querformat oder gedrehte Seite) schreiben | Striche dort, wo geschrieben; im Browser an derselben Stelle | ☐ bestanden ☐ nicht bestanden | |
| 7.3 | Beschriebene Seite: Mehr → „Seite drehen“ | **bekannt (Plan B5, behebt Schritt 3):** die Seite dreht sich, die Notizen behalten ihre Koordinaten und liegen danach über anderem PDF-Inhalt. Notieren, wie es aussieht | ☐ wie beschrieben ☐ anders | |
| 7.4 | D2 (300+ Seiten): eine Seite drehen bzw. „Leere Seite danach“ | Anzeige baut neu auf und bleibt auf derselben Seite; Wartezeit notieren (**Simulator:** unter 1 s bei 500 Seiten, siehe Messung) | ☐ bestanden ☐ nicht bestanden | Zeit: |

## 8. Absturz oder Abbruch mitten im Schreiben

Die App sichert jede Seite 0,25 s nach dem letzten Strich ins lokale Journal. Solange ohne Pause weitergeschrieben
wird, liegt der neueste Stand nur im Speicher (Plan B3, Obergrenze kommt mit Schritt 2). Diese Prüfungen zeigen, wie
groß das Fenster am Gerät ist. **Nur mit einem Testdokument.**

| Nr. | Schritt | Erwartung | Ergebnis | Notiz |
|---|---|---|---|---|
| 8.1 | Einen Strich schreiben, 2 s warten, App im App-Umschalter wegwischen, neu öffnen | Strich da | ☐ bestanden ☐ nicht bestanden | |
| 8.2 | Strich schreiben und **sofort** (unter 1 s) wegwischen | Strich da, wenn mehr als ¼ s vergangen ist; notieren, wie viel fehlt | ☐ bestanden ☐ nicht bestanden | |
| 8.3 | 30 s ohne Pause schreiben (z. B. schraffieren) und während des Schreibens in Xcode auf Stop (■) drücken – das beendet die App wie ein Absturz | nach dem Neustart: alles bis zur letzten Schreibpause da; notieren, wie viel fehlt (Erwartung heute: bis zu den letzten 30 s) | ☐ bestanden ☐ nicht bestanden | fehlt: |
| 8.4 | Wie 8.3, aber mit kurzen Pausen (Strich, Pause, Strich) | höchstens der letzte Strich fehlt | ☐ bestanden ☐ nicht bestanden | |
| 8.5 | Flugmodus an, schreiben, App wegwischen, neu öffnen | Striche da; Status zeigt den lokalen Stand, danach „Gespeichert“ | ☐ bestanden ☐ nicht bestanden | |
| 8.6 | Nach jedem Neustart oben auf Hinweise achten | höchstens „… ungesendete Seite(n) wiederhergestellt“, nie „… beschädigt“ | ☐ bestanden ☐ nicht bestanden | Hinweis: |

## 9. Speichern im Hintergrund, Export, „Lösung teilen“

| Nr. | Schritt | Erwartung | Ergebnis | Notiz |
|---|---|---|---|---|
| 9.1 | Strich schreiben und sofort zum Home-Bildschirm wischen; nach 1 min zurück | Strich da, Status „Gespeichert“ | ☐ bestanden ☐ nicht bestanden | |
| 9.2 | Strich schreiben, sofort Teilen → „PDF exportieren (nur privat)“ → „Ganzes Dokument“ und in Dateien sichern | exportierte PDF enthält den letzten Strich, Notizen an derselben Stelle wie im Editor | ☐ bestanden ☐ nicht bestanden | |
| 9.3 | Teilen → „Diese Seite“ auf einer gedrehten oder eingefügten Seite | genau diese Seite, richtige Größe und Ausrichtung | ☐ bestanden ☐ nicht bestanden | |
| 9.4 | Strichbreiten im Export mit dem Editor vergleichen (Stift dünn, Stift dick, Bleistift, Textmarker) | gleich breit wie im Editor. **Bekannt (Plan B6):** PencilKit zeichnet anders breit als gespeichert – notieren, ob der Export dünner oder dicker wirkt | ☐ gleich ☐ dünner ☐ dicker | |
| 9.5 | Strich schreiben, sofort Teilen → „Lösung teilen …“, Seiten wählen, teilen | Paket enthält den letzten Strich und nur eigene Notizen, nicht die PDF | ☐ bestanden ☐ nicht bestanden | |
| 9.6 | Großes Dokument (D2, 50 beschriebene Seiten): „Ganzes Dokument“ exportieren | Export fertig ohne Absturz; Dauer notieren (**Simulator:** 150 Seiten unter 15 s) | ☐ bestanden ☐ nicht bestanden | Dauer: |

## 10. Große Skripte

| Nr. | Schritt | Erwartung | Ergebnis | Notiz |
|---|---|---|---|---|
| 10.1 | D2 (300–500 Seiten) zum ersten Mal öffnen | erste Seite nach wenigen Sekunden; Zeit notieren | ☐ bestanden ☐ nicht bestanden | Zeit: |
| 10.2 | In D2 50 Seiten dicht beschreiben (oder über mehrere Tage ansammeln), dabei auf die Statusanzeige achten | Schreiben bleibt flüssig. **Simulator:** jede Speicherrunde schickt das ganze Dokument (rund 1,5 KB je Strich); bei 50 vollen Seiten dauert eine Runde mehrere Sekunden, „Speichert…“ steht entsprechend lange da – Dauer notieren | ☐ bestanden ☐ nicht bestanden | „Speichert…“ für: |
| 10.3 | D2 schließen und neu öffnen | alle Striche da; Zeit bis die beschriebene Seite mit Notizen erscheint notieren (**Simulator:** mehrere Sekunden bei vollen Skripten) | ☐ bestanden ☐ nicht bestanden | Zeit: |
| 10.4 | Speicher beim Blättern in D2 beobachten (Abschnitt 11) | kein stetiges Wachsen, kein Absturz; Höchstwert notieren | ☐ bestanden ☐ nicht bestanden | Höchstwert: |
| 10.5 | Einstellungen → Allgemein → iPad-Speicher → UniFlow | „Dokumente und Daten“ notieren. **Simulator:** der Verlauf hält bis zu 30 volle Kopien je Dokument | ☐ notiert | Größe: |

## 11. Messen am Gerät (ohne bezahltes Entwicklerkonto)

Alles hier geht mit dem kostenlosen „Personal Team“ aus Abschnitt 0, solange die App aus Xcode gestartet wird.

**Speicher, CPU, Energie live (am einfachsten):**

1. App mit Run (⌘R) aus Xcode starten, iPad bleibt am Kabel (oder im selben WLAN mit „Connect via network“ unter
   Window → Devices and Simulators).
2. In Xcode links den **Debug Navigator** öffnen (⌘7). Dort stehen **Memory**, **CPU**, **Energy Impact** und **Disk**.
   „Memory“ ist derselbe Wert wie `phys_footprint` in der Simulator-Messung.
3. Werte an diesen Stellen notieren: nach dem Öffnen von D2, nach dem Blättern bis zum Ende, beim Maximum-Zoom, während
   „Speichert…“ bei einem voll beschriebenen Dokument, nach dem Schließen. Ein Klick auf „Memory“ zeigt den Verlauf.
4. Wird der Speicher knapp, beendet iPadOS die App ohne Meldung. Dann: Window → Devices and Simulators → iPad →
   „View Device Logs“ und nach `JetsamEvent` oder `UniFlow` suchen.

**Genauer mit Instruments:**

1. Product → Scheme → Edit Scheme → **Profile** → Build Configuration auf **Debug** stellen (der Release-Build braucht
   das bezahlte Konto und bricht sonst mit einer Meldung ab).
2. Product → Profile (⌘I), Vorlage wählen:
   - **Animation Hitches**: beim schnellen Blättern (4.4, 4.5) – zeigt Ruckler mit Dauer.
   - **Time Profiler**: beim Schreiben und während „Speichert…“ – zeigt, was die CPU tut (Hauptthread oben).
   - **Allocations**: beim Blättern und Zoomen – „Persistent Bytes“ sollte nach dem Zurückscrollen nicht stetig steigen.
   - **Leaks**: einmal D2 öffnen, blättern, schließen – Lecks werden rot markiert.
3. Aufnahme starten, Schritt am iPad ausführen, stoppen. Die Datei (`.trace`) kann der Inhaber an die Mac-Sitzung geben.

**Ohne Xcode:** Stoppuhr für Öffnen und Blättern; Zeitlupe des iPhones für die Verzögerung (1.4);
Einstellungen → Batterie für den Verbrauch nach einer Schreibstunde; Abstürze unter Einstellungen → Datenschutz &
Sicherheit → Analyse & Verbesserungen → Analysedaten (Einträge mit „UniFlow“ oder „JetsamEvent“).

## 12. Ergebnis zurück ins Projekt

Je „nicht bestanden“: Nummer, Gerät (Abschnitt 0), was passiert ist, wenn möglich Bildschirmaufnahme oder `.trace`.
Die Mac-Sitzung trägt die Ergebnisse in diese Datei ein (Spalten „Ergebnis“ und „Notiz“) und leitet daraus die
Reihenfolge der Härtungen ab (`docs/PENCILKIT-ANALYSE-PLAN.md`, Abschnitt 6). Nach jedem Umbauschritt wird dieselbe
Liste wiederholt; Punkte mit „bekannt“ wechseln dann auf eine normale Erwartung.

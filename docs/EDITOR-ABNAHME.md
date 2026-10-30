# Abnahmeliste PDF-Editor (iPad mit Apple Pencil)

Stand 28.10.2026 nach Schritt 2 (Härtungen) · Grundlage: `docs/PENCILKIT-ANALYSE-PLAN.md` (Schritt 0 / P0-1 und
P0-2, Härtungen P0-3 bis P0-6) · Messwerte aus dem Simulator: `docs/EDITOR-MESSUNG.md` (Befunde M1 bis M10,
Abschnitt 8 zu Schritt 2). Die Gerätepunkte zu Schritt 2 stehen gesammelt in Abschnitt 18.

Diese Liste prüft der Inhaber am **echten iPad mit Apple Pencil**, bevor der Editor umgebaut wird, und danach nach
jedem Schritt erneut. Die App heißt in allen sichtbaren Texten und auf dem Home-Bildschirm **Studora**; das Xcode-Ziel
heißt weiter `UniFlow`, die Bundle-ID `de.uniflow.ai`, und im Gerätelog erscheint der Prozessname `UniFlow`.

Alles hier ist bisher **nicht am Gerät geprüft**. Was der Simulator schon gemessen hat, steht bei den Punkten als
Hinweis („Simulator: …“) – das ersetzt den Gerätetest nicht. Schreibgefühl, Handballen, Pencil-Gesten und echter
Speicherdruck lassen sich im Simulator gar nicht prüfen (`docs/EDITOR-MESSUNG.md`, Abschnitt 6).

**Schritte** meint die freigegebene Reihenfolge des Inhabers: 1 Abnahmeliste und Messung (diese Datei) ·
2 Härtungen · 3 Drehen ohne Verrutschen · 4 Speicherlast · 5 Seitenwerkzeuge · 6 Objekt-Werkzeuge.

**So ausfüllen:** je Zeile ein Kreuz bei **bestanden** oder **nicht bestanden** und bei Bedarf eine kurze Notiz (was
genau passiert ist, Seite, Zoom, Werkzeug). Punkte, die mit diesem Gerät oder Pencil nicht gehen, mit „entfällt“
notieren. Bei „nicht bestanden“ hilft eine Bildschirmaufnahme (Kontrollzentrum → Bildschirmaufnahme). Punkte mit
„**bekannt**“ beschreiben einen Mangel, der erst mit einem späteren Schritt behoben wird; dort nur ankreuzen, ob es so
aussieht wie beschrieben.

## 0. Gerät und Vorbereitung

| Angabe | Eintrag |
|---|---|
| Datum | |
| iPad-Modell (Einstellungen → Allgemein → Info) | |
| Arbeitsspeicher laut Modell (z. B. 4 GB, 8 GB) | |
| iPadOS-Version | |
| Apple Pencil (1. Generation / USB-C / 2. Generation / Pro) | |
| App-Stand (Terminal im Repo: `git log -1 --format=%h`) | |
| Freier Speicher auf dem iPad | |

**App auf das iPad bringen (kostenlose Apple-ID, ohne bezahltes Entwicklerkonto):**

1. Xcode → Settings → Accounts → eigene Apple-ID hinzufügen. Das ergibt ein kostenloses „Personal Team“; eine so
   installierte App läuft 7 Tage, danach einfach erneut aus Xcode starten (die Daten auf dem iPad bleiben).
2. Terminal: `cd apps/apple && xcodegen generate && open UniFlow.xcodeproj` (einmalig vorher `brew install xcodegen`).
   Das Xcode-Projekt ist nicht eingecheckt und wird so jedes Mal neu erzeugt.
3. In Xcode links das Projekt wählen, Ziel **UniFlow** → Signing & Capabilities → Team = eigene Apple-ID
   („Personal Team“). Meldet Xcode, dass die Bundle-ID `de.uniflow.ai` nicht verfügbar ist, dort eine eigene eintragen,
   z. B. `de.uniflow.ai.test` (nur lokal; `xcodegen generate` setzt sie wieder zurück, nichts davon einchecken).
   **Keine** `Config/Team.xcconfig` anlegen: ohne sie baut die App ohne die Berechtigungen „Mit Apple anmelden“ und
   iCloud, genau das braucht das kostenlose Konto.
4. iPad per Kabel anschließen, „Diesem Computer vertrauen“; auf dem iPad Einstellungen → Datenschutz & Sicherheit →
   Entwicklermodus an (Neustart). Oben in Xcode als Ziel das iPad wählen. Beim ersten Start: Einstellungen →
   Allgemein → VPN & Geräteverwaltung → Entwickler-App (eigene Apple-ID) → vertrauen.
5. Schreiben braucht Studora Plus. Ohne echte Abo-Produkte: Product → Scheme → Edit Scheme → Run → Arguments → bei
   „Arguments Passed On Launch“ `-UFPlan plus` eintragen (wirkt nur im Debug-Build). Dann Run (⌘R).
6. Beim ersten Start „Anmeldung überspringen (Debug)“ (ohne bezahltes Konto meldet „Mit Apple anmelden“, dass es in
   diesem Build nicht verfügbar ist), dann Hochschule wählen und selbst anmelden – oder ohne Hochschule unter
   „Dokumente“ bzw. in der Bibliothek über „PDF importieren“ eigene PDFs aus der Dateien-App holen.

Vor dem Test prüfen, dass die App im **Debug**-Build läuft (Product → Scheme → Edit Scheme → Run → Build
Configuration „Debug“, Ziel = das iPad). Die Werkzeuge zum Messen am Gerät stehen in Abschnitt 15.

**Testdokumente** (eigene Dateien, bleiben auf dem iPad; für Abschnitte, die Daten verändern oder die App abbrechen,
nur ein Testdokument nehmen, nie ein Skript mit wichtigen Notizen):

| Kürzel | Dokument | Woher |
|---|---|---|
| D1 | Vorlesungsfolien, 20–60 Seiten | Stud.IP oder „PDF importieren“ |
| D2 | großes Skript, 250–500 Seiten | Stud.IP oder „PDF importieren“ |
| D3 | Übungsblatt (für die geteilte Ansicht mit D1) | Stud.IP oder „PDF importieren“ |
| D4 | PDF mit Querformat- oder gedrehten Seiten | z. B. Folien im Querformat |
| D5 | Testdokument zum Verändern (Kopie von D1 unter anderem Namen) | „PDF importieren“ |

## 1. Schreiben

| Nr. | Schritt | Erwartung | Ergebnis | Notiz |
|---|---|---|---|---|
| 1.1 | D1 öffnen, Werkzeug Stift, 5 min normal mitschreiben (Wörter, Formeln, kleine Zeichen wie i-Punkte) | Tinte folgt der Spitze ohne sichtbaren Abstand, kein Ruckeln, keine fehlenden Punkte | ☐ bestanden ☐ nicht bestanden | |
| 1.2 | Schnelle Kringel und lange Linien, dabei Druck und Neigung wechseln | Strichbreite folgt dem Druck, Linien bleiben glatt | ☐ bestanden ☐ nicht bestanden | |
| 1.3 | Nach dem Schreiben auf die Statusanzeige oben sehen | kurz „Lokal gesichert · 1 Seite wartet“ bzw. „Speichert…“, danach „Gespeichert“; Schreiben stockt dabei nie. **Simulator:** eine Speicherrunde läuft im Hintergrund und hält den Hauptthread höchstens wenige Millisekunden auf (M7) | ☐ bestanden ☐ nicht bestanden | |
| 1.4 | Verzögerung messen (optional): Zeitlupe des iPhones (240 B/s) auf Spitze und Tinte, schnelle Linie ziehen | Abstand Spitze ↔ Tinte höchstens 2–3 Bilder (etwa 10 ms); Wert notieren. **Simulator:** nicht messbar | ☐ bestanden ☐ nicht bestanden | Bilder: |
| 1.5 | „Nur Stift“ (Leiste oben) an: mit dem Finger über die Seite wischen | Finger scrollt, schreibt nie | ☐ bestanden ☐ nicht bestanden | |
| 1.6 | Auf „Finger zeichnet“ umschalten: mit einem Finger schreiben, mit zwei Fingern scrollen und zoomen | ein Finger schreibt, zwei Finger scrollen und zoomen; danach wieder „Nur Stift“ | ☐ bestanden ☐ nicht bestanden | |
| 1.7 | Stift über den Seitenrand hinaus ziehen, auch in die Lücke zur nächsten Seite | Seite verrutscht nicht, Strich endet am Rand dieser Seite (Striche gelten je Seite) | ☐ bestanden ☐ nicht bestanden | |
| 1.8 | Auf einer schon dicht beschriebenen Seite (etwa 300 Striche) weiterschreiben | Schreiben genauso flüssig wie auf einer leeren Seite. **Simulator:** die Umrechnung der ganzen Seite nach jedem Strich dauert im Hintergrund 0,05–0,09 s (M7); am Gerät auf Ruckler achten | ☐ bestanden ☐ nicht bestanden | |
| 1.9 | Palette: Stift, Bleistift, Textmarker, Füller, Fineliner, Wasserfarbe, Wachsmalstift nacheinander wählen und je einen Strich ziehen; Farben und Stärken wechseln | jedes Werkzeug zeichnet wie in der Palette angezeigt; Textmarker liegt durchscheinend über dem PDF-Text; nach dem Wegscrollen und zurück ist dasselbe Werkzeug gewählt | ☐ bestanden ☐ nicht bestanden | |
| 1.10 | Palette beim Scrollen über 10 Seiten beobachten | Palette schließt sich nicht | ☐ bestanden ☐ nicht bestanden | |
| 1.11 | Lineal aus der Palette: gerade Linie daran entlang ziehen | Linie gerade; notieren, ob das Lineal auf mehreren sichtbaren Seiten gleichzeitig erscheint (Plan 1.4, Punkt 3) | ☐ bestanden ☐ nicht bestanden | |

## 2. Handballen und Pencil-Gesten

Im Simulator nicht prüfbar (kein Pencil, kein Handballen). Die App hat für Doppeltippen, Squeeze und Hover keinen eigenen
Code; was passiert, ist Verhalten von iPadOS und der Systempalette.

| Nr. | Schritt | Erwartung | Ergebnis | Notiz |
|---|---|---|---|---|
| 2.1 | 100 kurze Striche schreiben, dabei Hand und Handballen auf dem Display ablegen | jeder Strich da, keine Striche vom Handballen, kein Scrollen oder Zoomen durch die Hand | ☐ bestanden ☐ nicht bestanden | |
| 2.2 | Hand liegt auf, Stift kurz abheben und sofort weiterschreiben | erster Punkt des neuen Strichs geht nicht verloren | ☐ bestanden ☐ nicht bestanden | |
| 2.3 | Doppeltippen auf den Pencil (nur 2. Generation und Pro) | wirkt wie in Einstellungen → Apple Pencil eingestellt (z. B. Radierer ↔ letztes Werkzeug) | ☐ bestanden ☐ nicht bestanden ☐ entfällt | Einstellung: |
| 2.4 | Squeeze (nur Pencil Pro) | Systemverhalten, z. B. kleine Palette an der Spitze; notieren, was passiert | ☐ bestanden ☐ nicht bestanden ☐ entfällt | |
| 2.5 | Hover: Stift knapp über die Seite halten (nur iPads mit Hover-Unterstützung) | Vorschau der Spitze in Farbe und Größe des Werkzeugs, kein Strich, kein Scrollen | ☐ bestanden ☐ nicht bestanden ☐ entfällt | |

## 3. Radieren

| Nr. | Schritt | Erwartung | Ergebnis | Notiz |
|---|---|---|---|---|
| 3.1 | Radierer „Pixel“: Mitte eines Strichs wegradieren | nur die Mitte fehlt, beide Enden bleiben | ☐ bestanden ☐ nicht bestanden | |
| 3.2 | Radierer „Objekt“: einen Strich antippen | ganzer Strich weg, sonst nichts | ☐ bestanden ☐ nicht bestanden | |
| 3.3 | Mit dem Radierer über viele Striche wischen, dann einmal „Rückgängig“ | das ganze Radieren (vom Aufsetzen bis zum Abheben) kommt mit einem Schritt zurück | ☐ bestanden ☐ nicht bestanden | |
| 3.4 | Radieren, Seite weit wegscrollen und zurück | Radiertes bleibt weg | ☐ bestanden ☐ nicht bestanden | |
| 3.5 | Textfeld (Mehr → „Text hinzufügen“) mit dem Radierer überstreichen | **bekannt:** der Radierer wirkt nur auf Striche, Text bleibt (Plan B1/B2, Schritt 6) | ☐ wie beschrieben ☐ anders | |

## 4. Lasso

| Nr. | Schritt | Erwartung | Ergebnis | Notiz |
|---|---|---|---|---|
| 4.1 | Lasso: mehrere Striche umkreisen, verschieben | Striche bewegen sich mit, nach dem Loslassen bleiben sie dort (auch nach Wegscrollen und Zurück) | ☐ bestanden ☐ nicht bestanden | |
| 4.2 | Auswahl über das Lasso-Menü kopieren und an anderer Stelle derselben Seite einsetzen, dann löschen | Kopie erscheint, Löschen entfernt nur die Auswahl | ☐ bestanden ☐ nicht bestanden | |
| 4.3 | Lasso über Striche an der Seitengrenze ziehen | nur Striche dieser Seite werden erfasst (Striche gelten je Seite) | ☐ bestanden ☐ nicht bestanden | |
| 4.4 | Lasso über einen Text, der mit „Text hinzufügen“ angelegt wurde | **bekannt:** das Lasso erfasst nur Striche, der Text bleibt stehen (Plan B2, Schritt 6) | ☐ wie beschrieben ☐ anders | |
| 4.5 | Verschieben mit dem Lasso, dann „Rückgängig“ und „Wiederholen“ | Striche springen zurück und wieder an die neue Stelle | ☐ bestanden ☐ nicht bestanden | |

## 5. Zoom

| Nr. | Schritt | Erwartung | Ergebnis | Notiz |
|---|---|---|---|---|
| 5.1 | Auf D1 eine Zeile mit dünnem Stift schreiben, dann mit zwei Fingern auf 200 %, 400 % und das Maximum zoomen (Anzeige oben, Maximum = 6-fach der eingepassten Breite) | Tinte bleibt so scharf wie der PDF-Text daneben. **Simulator:** die Tinte wird mit dem Zoom weicher, die PDF bleibt scharf (Kante der Tinte 0,5 px eingepasst, 2 / 3 / 5 px bei 2-, 4- und 6-fach; PDF-Linie 1 px; M5). Bitte genau hinsehen und je Stufe notieren | ☐ bestanden ☐ nicht bestanden | 200 %: · 400 %: · Max: |
| 5.2 | Beim Maximum weiterschreiben | Strich erscheint unter der Spitze, nicht versetzt. **Simulator:** das Overlay folgt dem Zoom in etwa 0,05 s auf 5 % genau | ☐ bestanden ☐ nicht bestanden | |
| 5.3 | Zoomen und sofort danach schreiben | Zoom bleibt, Strich an der richtigen Stelle | ☐ bestanden ☐ nicht bestanden | |
| 5.4 | Doppeltippen mit dem Finger bzw. Zurück auf Einpassen | Seite passt wieder auf die Breite, Striche unverändert | ☐ bestanden ☐ nicht bestanden | |
| 5.5 | Beim Maximum zwei Seiten weiterscrollen | flüssig, Striche erscheinen sofort. **Simulator:** Zuwachs an Speicher bis zum Maximum höchstens rund 30 MB (M5) | ☐ bestanden ☐ nicht bestanden | |

## 6. Seitenwechsel und schnelles Blättern

| Nr. | Schritt | Erwartung | Ergebnis | Notiz |
|---|---|---|---|---|
| 6.1 | D2 (250–500 Seiten) zum ersten Mal öffnen | erste Seite nach wenigen Sekunden; Zeit notieren. **Simulator:** Öffnen unter 0,1 s, erste Seite bis 0,2 s (M8; Datei schon auf dem Gerät, ohne Herunterladen) | ☐ bestanden ☐ nicht bestanden | Zeit: |
| 6.2 | D2 mit einem Finger schnell bis zum Ende und zurück wischen | flüssig, kein Absturz, Seiten erscheinen ohne lange weiße Flächen; Zeit bis zum Ende notieren. **Simulator:** 500 Seiten ohne Fehler, danach leben immer 10 Seiten-Overlays mit ihrer Canvas, egal wie lang das Dokument ist, und der Speicher wächst nicht mit der Seitenzahl (M8) | ☐ bestanden ☐ nicht bestanden | Zeit: |
| 6.3 | Auf 20 Seiten von D2 je eine halbe Seite schreiben, dann schnell darüber blättern | Notizen erscheinen auf jeder Seite. **Simulator:** bei voll beschriebenen Seiten erscheinen die Striche beim schnellen Blättern verzögert, weil auch Seiten fertig geladen werden, die schon wieder aus dem Bild sind (M4) – notieren, wie lange eine Seite ohne Notizen zu sehen ist | ☐ bestanden ☐ nicht bestanden | Verzögerung: |
| 6.4 | Über „Seiten“ (Seitenleiste) und über ein Lesezeichen weit springen | Ansicht springt zur Seite, Striche sind da. **Simulator:** volle Seite (300 Striche) anspringen bis Striche da rund 0,4 s (M4) | ☐ bestanden ☐ nicht bestanden | |
| 6.5 | Suchen (Lupe) nach einem Wort, Treffer antippen | springt zur Fundstelle, Notizen der Seite sichtbar | ☐ bestanden ☐ nicht bestanden | |
| 6.6 | Weit wegscrollen und zurück zu einer beschriebenen Seite | Striche unverändert, Rückgängig wirkt noch auf diese Seite (Abschnitt 8) | ☐ bestanden ☐ nicht bestanden | |
| 6.7 | Dokument schließen und wieder öffnen | öffnet auf der zuletzt gelesenen Seite | ☐ bestanden ☐ nicht bestanden | |
| 6.8 | Dunkelmodus an (Kontrollzentrum) | Seiten bleiben weiß, schwarze Tinte bleibt schwarz, Bedienelemente lesbar | ☐ bestanden ☐ nicht bestanden | |

## 7. Drehen

| Nr. | Schritt | Erwartung | Ergebnis | Notiz |
|---|---|---|---|---|
| 7.1 | iPad drehen (hoch ↔ quer), einmal eingepasst und einmal gezoomt | eingepasst bleibt eingepasst, ein eigener Zoom bleibt relativ gleich; Striche an der richtigen Stelle | ☐ bestanden ☐ nicht bestanden | |
| 7.2 | Auf D4 (Querformat oder gedrehte Seite) schreiben | Striche dort, wo geschrieben; im Browser an derselben Stelle (falls PC vorhanden) | ☐ bestanden ☐ nicht bestanden ☐ entfällt | |
| 7.3 | D5: beschriebene Seite über Mehr → „Seite drehen“ | **seit Schritt 3 (P0-7):** die Notizen drehen mit und liegen danach auf demselben Inhalt wie vorher; Stift-Striche behalten ihr Aussehen (Pinsel, Druck) | ☐ bestanden ☐ nicht bestanden | |
| 7.4 | D2 (250+ Seiten): eine Seite drehen bzw. „Leere Seite danach“ | Anzeige baut neu auf und bleibt auf derselben Seite; Wartezeit notieren. **Simulator:** Neuaufbau bei 500 Seiten 0,1–0,2 s (M10) | ☐ bestanden ☐ nicht bestanden | Zeit: |

## 8. Rückgängig und Wiederholen

| Nr. | Schritt | Erwartung | Ergebnis | Notiz |
|---|---|---|---|---|
| 8.1 | Auf Seite 2 schreiben, auf Seite 9 schreiben, dann zweimal „Rückgängig“ (Leiste oben) | nimmt die Striche in umgekehrter Reihenfolge zurück und springt dabei zur betroffenen Seite; zweimal „Wiederholen“ bringt sie zurück | ☐ bestanden ☐ nicht bestanden | |
| 8.2 | Wie 8.1, aber vor dem Rückgängig weit weg blättern (z. B. 40 Seiten) | wie 8.1. **Simulator:** geprüft auch für Seiten, deren Ansicht schon freigegeben war, und für eine volle Seite mit 300 Strichen; je Schritt bis die Seite mit dem alten Stand im Bild ist unter 0,1 s (M9) | ☐ bestanden ☐ nicht bestanden | |
| 8.3 | Rückgängig über die Palette und, falls Tastatur da, ⌘Z / ⇧⌘Z; mit drei Fingern nach links wischen | gleiche Wirkung wie die Leiste | ☐ bestanden ☐ nicht bestanden | |
| 8.4 | Nach dem Rückgängig das Dokument schließen und wieder öffnen | der zurückgenommene Stand ist gespeichert (Striche fehlen weiterhin); ebenso nach „Wiederholen“ | ☐ bestanden ☐ nicht bestanden | |
| 8.5 | 160 kurze Striche schreiben, dann Rückgängig gedrückt halten bzw. oft tippen | höchstens 150 Schritte zurück (wie im Web-Editor), danach nichts mehr | ☐ bestanden ☐ nicht bestanden | |

## 9. Sichern und Wiederöffnen

| Nr. | Schritt | Erwartung | Ergebnis | Notiz |
|---|---|---|---|---|
| 9.1 | Einen Strich schreiben, Dokument schließen, wieder öffnen | Strich da, Status „Gespeichert“ | ☐ bestanden ☐ nicht bestanden | |
| 9.2 | In D2 50 Seiten dicht beschreiben (oder über mehrere Tage ansammeln), dabei auf die Statusanzeige achten | Schreiben bleibt flüssig. **Simulator:** jede Speicherrunde schickt das ganze Dokument (rund 1,5 KB je Strich); eine Runde dauert bei 15 000 Strichen (50 volle Seiten) 7–14 s, auch wenn nur eine Seite geändert wurde; „Speichert…“ steht entsprechend lange da (M1) – Dauer notieren | ☐ bestanden ☐ nicht bestanden | „Speichert…“ für: |
| 9.3 | D2 nach 9.2 schließen und neu öffnen | alle Striche da; Zeit bis die beschriebene Seite mit Notizen erscheint notieren. **Simulator:** 6–9 s bei 15 000 Strichen, bis der Editor etwas zeigt (M3) | ☐ bestanden ☐ nicht bestanden | Zeit: |
| 9.4 | Nach jedem Öffnen oben auf Hinweise achten | höchstens „… ungesendete Seite(n) wiederhergestellt.“, nie „… beschädigt“ | ☐ bestanden ☐ nicht bestanden | Hinweis: |
| 9.5 | Flugmodus an, schreiben, Dokument schließen und wieder öffnen | Striche da (lokales Journal); Status danach „Gespeichert“ | ☐ bestanden ☐ nicht bestanden | |
| 9.6 | Strich schreiben, sofort Teilen → „PDF exportieren (nur privat)“ → „Ganzes Dokument“ und in Dateien sichern | exportierte PDF enthält den letzten Strich, Notizen an derselben Stelle wie im Editor | ☐ bestanden ☐ nicht bestanden | |
| 9.7 | Teilen → „Diese Seite“ auf einer gedrehten oder eingefügten Seite | genau diese Seite, richtige Größe und Ausrichtung | ☐ bestanden ☐ nicht bestanden | |
| 9.8 | Strichbreiten im Export mit dem Editor vergleichen (Stift dünn, Stift dick, Bleistift, Textmarker) | gleich breit wie im Editor. **Bekannt (Plan B6):** PencilKit zeichnet anders breit als gespeichert – notieren, ob der Export dünner oder dicker wirkt | ☐ gleich ☐ dünner ☐ dicker | |
| 9.9 | Strich schreiben, sofort Teilen → „Lösung teilen …“, Seiten wählen, teilen | Paket enthält den letzten Strich und nur eigene Notizen, nicht die PDF | ☐ bestanden ☐ nicht bestanden | |
| 9.10 | Großes Dokument (D2, 50 beschriebene Seiten): „Ganzes Dokument“ exportieren | Export fertig ohne Absturz; Dauer notieren (Härtetest im Simulator: 150 Seiten in unter 15 s) | ☐ bestanden ☐ nicht bestanden | Dauer: |

## 10. Hintergrund und Beenden

Die App sichert jede Seite 0,25 s nach dem letzten Strich ins lokale Journal. Seit Schritt 2 gilt eine Obergrenze:
Auch wenn ohne Pause weitergeschrieben wird, landet der Stand spätestens nach etwa 2 s im Journal (P0-3). Hochgeladen
wird weiterhin erst nach einer Schreibpause. Diese Prüfungen zeigen, wie groß das Fenster am Gerät ist. **Nur mit D5.**

| Nr. | Schritt | Erwartung | Ergebnis | Notiz |
|---|---|---|---|---|
| 10.1 | Strich schreiben und sofort zum Home-Bildschirm wischen; nach 1 min zurück | Strich da, Status „Gespeichert“ | ☐ bestanden ☐ nicht bestanden | |
| 10.2 | Einen Strich schreiben, 2 s warten, App im App-Umschalter wegwischen, neu öffnen | Strich da | ☐ bestanden ☐ nicht bestanden | |
| 10.3 | Strich schreiben und **sofort** (unter 1 s) wegwischen | Strich da, wenn mehr als ¼ s vergangen ist; notieren, wie viel fehlt | ☐ bestanden ☐ nicht bestanden | |
| 10.4 | 30 s ohne Pause schreiben (z. B. schraffieren) und während des Schreibens in Xcode auf Stop (■) drücken – das beendet die App wie ein Absturz | nach dem Neustart: höchstens die letzten etwa 2 s fehlen (Obergrenze P0-3, vor Schritt 2 bis zu 30 s); notieren, wie viel fehlt. **Simulator:** erster Journal-Eintrag nach 2,1–2,2 s Dauerschreiben | ☐ bestanden ☐ nicht bestanden | fehlt: |
| 10.5 | Wie 10.4, aber mit kurzen Pausen (Strich, Pause, Strich) | höchstens der letzte Strich fehlt | ☐ bestanden ☐ nicht bestanden | |
| 10.6 | Dicht beschriebenes D2 (nach 9.2): Strich schreiben, sofort Home-Bildschirm, nach 30 s zurück | Strich da, Status „Gespeichert“. **Simulator:** eine Speicherrunde dauert hier mehrere Sekunden (M1); iPadOS gibt einer App im Hintergrund nur begrenzt Zeit – notieren, ob „Gespeichert“ kommt | ☐ bestanden ☐ nicht bestanden | |

## 11. Speicher

Werte am Gerät mit Xcode messen (Abschnitt 15). Der Simulator ist ein Mac-Prozess ohne echten Speicherdruck; seine
Zahlen sind nur eine Größenordnung (`docs/EDITOR-MESSUNG.md`, Abschnitt 6).

| Nr. | Schritt | Erwartung | Ergebnis | Notiz |
|---|---|---|---|---|
| 11.1 | D2 öffnen, Speicher („Memory“) notieren, bis zum Ende blättern, wieder notieren, zurück an den Anfang, notieren | kein stetiges Wachsen; Höchstwert notieren. **Simulator:** nach 500 Seiten nicht mehr als nach 100 (Prozess rund 230–330 MB, M8) | ☐ bestanden ☐ nicht bestanden | Werte: |
| 11.2 | Beim Maximum-Zoom (5.1) Speicher notieren | kein Sprung. **Simulator:** höchstens rund 30 MB mehr als eingepasst | ☐ bestanden ☐ nicht bestanden | Wert: |
| 11.3 | Dicht beschriebenes D2 (nach 9.2): während „Speichert…“ den Höchstwert notieren | kein Absturz. **Simulator:** bis rund 600 MB während einer Runde mit 30 000 Strichen (M1) – auf iPads mit wenig Arbeitsspeicher kann das knapp werden | ☐ bestanden ☐ nicht bestanden | Höchstwert: |
| 11.4 | Schnell über 50 voll beschriebene Seiten blättern | kein Absturz, Speicher fällt danach wieder. **Simulator:** Spitze 530–590 MB (M4) | ☐ bestanden ☐ nicht bestanden | Höchstwert: |
| 11.5 | Einstellungen → Allgemein → iPad-Speicher → Studora | „Dokumente und Daten“ notieren. **Simulator:** der Verlauf hält bis zu 30 volle Kopien je Dokument; bei 30 000 Strichen wären das über 1 GB (M2) | ☐ notiert | Größe: |
| 11.6 | Beendet iPadOS die App ohne Meldung (sie startet neu)? Dann Gerätelog prüfen (Abschnitt 15) | kein `JetsamEvent` | ☐ kein Abbruch ☐ abgebrochen | |

## 12. Ebenen und Ansichtsmodus

| Nr. | Schritt | Erwartung | Ergebnis | Notiz |
|---|---|---|---|---|
| 12.1 | Ebenen → „Meine Notizen“ ausschalten | eigene Notizen verschwinden, oben steht „Meine Notizen ausgeblendet – nur ansehen“, die Palette ist weg, der Stift schreibt nicht | ☐ bestanden ☐ nicht bestanden | |
| 12.2 | Im Ansichtsmodus: Rückgängig (Leiste, Palette, ⌘Z, drei Finger), Mehr → Seite drehen / Leere Seite / Papierkorb / Lesezeichen / Text | nichts wird zurückgenommen oder geändert, schreibende Menüpunkte sind gesperrt; nach dem Einblenden wirkt Rückgängig wieder | ☐ bestanden ☐ nicht bestanden | |
| 12.3 | Im Ansichtsmodus schnell blättern und zoomen, dann Dokument schließen und neu öffnen | Notizen unverändert (Härtetest im Simulator: Journal bleibt bytegleich) | ☐ bestanden ☐ nicht bestanden | |
| 12.4 | Eine geteilte Lösung importieren (Mehr → „Lösung importieren …“, Datei `.uniflowsolution`), unter Ebenen ein- und ausblenden | fremde Striche liegen über der PDF und unter den eigenen, an der richtigen Stelle; eigene Notizen unverändert | ☐ bestanden ☐ nicht bestanden ☐ entfällt | |
| 12.5 | Mit eingeblendeter fremder Ebene schreiben und radieren | nur eigene Striche ändern sich, die fremde Ebene bleibt | ☐ bestanden ☐ nicht bestanden ☐ entfällt | |
| 12.6 | Fremde Ebene umschalten, während viele Seiten sichtbar oder geparkt sind | Umschalten ohne lange Pause. **Bekannt (Plan B12):** Umschalten baut alle Ebenen auf allen Seiten neu; Wartezeit notieren | ☐ bestanden ☐ nicht bestanden ☐ entfällt | Zeit: |
| 12.7 | Studora Free (Startargument `-UFPlan free` statt `plus`): Dokument mit Notizen öffnen | Notizen sichtbar und exportierbar, fremde Ebenen lassen sich ansehen; Schreiben, Seitenaktionen und „Lösung teilen …“ zeigen ein Schloss „(Studora Plus)“, nichts wird verändert | ☐ bestanden ☐ nicht bestanden | |

## 13. Geteilte Ansicht und zwei Fenster

| Nr. | Schritt | Erwartung | Ergebnis | Notiz |
|---|---|---|---|---|
| 13.1 | D3 öffnen, oben „Geteilt“ → D1 daneben öffnen (oder „Passende Skriptstelle“ → „Daneben öffnen“) | beide Dokumente nebeneinander, Breite verstellbar | ☐ bestanden ☐ nicht bestanden | |
| 13.2 | Abwechselnd links und rechts schreiben | eine Palette für beide, jedes Dokument speichert seine eigenen Striche | ☐ bestanden ☐ nicht bestanden | |
| 13.3 | Danach zweimal „Rückgängig“ | nimmt den zuletzt geschriebenen Strich zurück, egal in welchem Dokument | ☐ bestanden ☐ nicht bestanden | |
| 13.4 | „Teilung beenden“, beide Dokumente einzeln neu öffnen | alle Striche beider Dokumente da | ☐ bestanden ☐ nicht bestanden | |
| 13.5 | Studora zweimal nebeneinander (Split View oder Stage Manager) und in beiden **dasselbe** Dokument D5 öffnen, in beiden schreiben, beide schließen, neu öffnen | seit Schritt 2 (P0-6): das zweite Fenster zeigt „In einem anderen Fenster offen – nur ansehen“, der Stift schreibt dort nicht; nach dem Schließen und Öffnen sind alle Striche des ersten Fensters da. Einzelheiten in 18.8–18.11. Nur mit D5! | ☐ alles da ☐ Striche fehlen ☐ entfällt | |

## 14. Eingefügte Seiten A6 bis A0

Das iPad fügt über Mehr → „Leere Seite danach“ eine Leerseite ein: unter „Wie aktuelle Seite“ in der Größe der Seite
davor, unter „Anderes Format“ in A6 bis A2 (hoch oder quer) oder als Whiteboard bis A0 quer. Nur mit D5.

| Nr. | Schritt | Erwartung | Ergebnis | Notiz |
|---|---|---|---|---|
| 14.1 | Nach Seite 1 nacheinander Seiten A6, A5, A3 und A2 hoch einfügen, auf jede in die Mitte schreiben | jede Seite hat ihre Größe, Strich bleibt in der Mitte (auch nach Schließen und Öffnen). **Simulator:** Lage der Striche in allen Formaten geprüft | ☐ bestanden ☐ nicht bestanden | |
| 14.2 | Nach einer A3-Seite „Leere Seite danach“ → „Wie aktuelle Seite“ | neue Seite hat A3-Größe | ☐ bestanden ☐ nicht bestanden | |
| 14.3 | Whiteboard A1 quer und A0 quer einfügen, schreiben, zoomen; Speicher in Xcode notieren | Schreiben flüssig, kein Absturz | ☐ bestanden ☐ nicht bestanden | Speicher: |
| 14.4 | D5 mit A4-Seiten **und** einer A0-Seite eingepasst ansehen, auf einer A4-Seite zoomen und schreiben | **Simulator (M6, Schritt 5):** PDFKit passt auf die breiteste Seite ein – A4-Seiten erscheinen dann sehr klein (rund 150 pt breit statt 830 pt) und lassen sich höchstens etwa auf Fensterbreite zoomen. Notieren, ob das am Gerät auch so ist und ob man auf A4 noch schreiben kann | ☐ wie beschrieben ☐ anders | |
| 14.5 | Die Seite aus 14.4 wieder in den Papierkorb legen | A4-Seiten wieder normal groß | ☐ bestanden ☐ nicht bestanden | |

## 15. Messen am Gerät (ohne bezahltes Entwicklerkonto)

Alles hier geht mit dem kostenlosen „Personal Team“ aus Abschnitt 0, solange die App aus Xcode gestartet wird.

**Speicher, CPU, Energie live (am einfachsten):**

1. App mit Run (⌘R) aus Xcode starten, iPad bleibt am Kabel (oder im selben WLAN mit „Connect via network“ unter
   Window → Devices and Simulators).
2. In Xcode links den **Debug Navigator** öffnen (⌘7). Dort stehen **Memory**, **CPU**, **Energy Impact** und **Disk**.
   „Memory“ entspricht `phys_footprint` in der Simulator-Messung.
3. Werte an diesen Stellen notieren: nach dem Öffnen von D2, nach dem Blättern bis zum Ende, beim Maximum-Zoom, während
   „Speichert…“ bei einem voll beschriebenen Dokument, nach dem Schließen. Ein Klick auf „Memory“ zeigt den Verlauf.
4. Wird der Speicher knapp, beendet iPadOS die App ohne Meldung. Dann: Window → Devices and Simulators → iPad →
   „View Device Logs“ und nach `JetsamEvent` oder dem Prozessnamen `UniFlow` suchen (Name des Xcode-Ziels; auf dem
   iPad heißt die App Studora, der Prozess behält den Namen).

**Genauer mit Instruments:**

1. Product → Scheme → Edit Scheme → **Profile** → Build Configuration auf **Debug** stellen (der Release-Build verlangt
   ein bezahltes Team und bricht sonst mit einer Meldung ab).
2. Product → Profile (⌘I), Vorlage wählen:
   - **Animation Hitches**: beim schnellen Blättern (6.2, 6.3) – zeigt Ruckler mit Dauer.
   - **Time Profiler**: beim Schreiben auf einer vollen Seite (1.8) und während „Speichert…“ (9.2) – zeigt, was die
     CPU tut (Hauptthread oben).
   - **Allocations**: beim Blättern und Zoomen – „Persistent Bytes“ sollte nach dem Zurückscrollen nicht stetig steigen.
   - **Leaks**: einmal D2 öffnen, blättern, schließen – Lecks werden rot markiert.
3. Aufnahme starten, Schritt am iPad ausführen, stoppen. Die Datei (`.trace`) kann der Inhaber an die Mac-Sitzung geben.

**Ohne Xcode:** Stoppuhr für Öffnen und Blättern; Zeitlupe des iPhones für die Verzögerung (1.4);
Einstellungen → Batterie für den Verbrauch nach einer Schreibstunde; Abstürze unter Einstellungen → Datenschutz &
Sicherheit → Analyse & Verbesserungen → Analysedaten (Einträge, die mit dem Prozessnamen `UniFlow` oder mit
`JetsamEvent` beginnen).

## 16. Bestandsliste (Funktionsmatrix des Plans, Abschnitt 2.2, Spalte Apple)

Was der Editor heute kann und wo es in dieser Liste geprüft wird. Nach jedem Umbauschritt muss alles, was hier als
vorhanden steht, weiter gehen (Plan, Abschnitt 8 Punkt 2). V = vollständig, T = teilweise, – = fehlt.

| Nr. (2.2) | Funktion | Stand | Prüfung |
|---|---|---|---|
| 1 | PDF durchgehend scrollen | V | 6.2 |
| 2 | Zoomen, Notizen bleiben an ihrer Stelle | V | 5.1–5.5, 7.1 |
| 3 | Seitenübersicht mit Miniaturen inkl. Notizen | V | 6.4 |
| 5 | Lesezeichen | V | 6.4 |
| 7 | Volltextsuche im PDF | V | 6.5 |
| 10 | Vollbild | T (nur Navigationsleiste aus) | – |
| 11 | Zwei Dokumente nebeneinander | V (Studora Plus) | 13.1–13.4 |
| 12 | Passende Skriptstelle vorschlagen | V | 13.1 |
| 13 | Zuletzt gelesene Seite merken | V | 6.7 |
| 14–17 | Stift mit Druck und Neigung, sieben Tinten, Farben und Stärken, Textmarker | V (Systempalette) | 1.1, 1.2, 1.9 |
| 18 | Radierer (Pixel und Strich) | V | 3.1–3.4 |
| 19 | Lasso | T (nur Striche) | 4.1–4.5 |
| 20 | Lineal | V (Palette) | 1.11 |
| 21–24 | Formen, Textfelder, Haftnotizen, Bilder | T (nur Anzeige; Text nur anlegen) | 3.5, 4.4 |
| 25 | Rückgängig / Wiederholen (dokumentweit, 150 Schritte) | V | 8.1–8.5, 13.3 |
| 26 | „Nur Stift“ / Finger zeichnet | V | 1.5, 1.6 |
| 27 | Handballen | V (System) | 2.1, 2.2 |
| 28 | Pencil-Doppeltippen, Squeeze, Hover | Systemverhalten | 2.3–2.5 |
| 31 | Tastaturkürzel ⌘Z / ⇧⌘Z | T | 8.3 |
| 33 | Leere Seite mit Vorlage (danach), Formate A6–A0 | V | 7.4, 14.1–14.3 |
| 34 | Seite drehen | V (Notizen verrutschen, B5) | 7.3, 7.4 |
| 35 | Papierkorb, wiederherstellen | V | 14.5 |
| 38 | Notizbuch/Whiteboard ohne PDF | V | – (Bibliothek → Neu) |
| 39 | Eigene Notizen ausblenden (nur ansehen) | V | 12.1–12.3 |
| 40 | Fremde Lösung als Ebene, einzeln schaltbar | V | 12.4–12.6 |
| 41 | Lösung als Datei teilen/importieren | V | 9.9, 12.4 |
| 44, 45 | Automatisch lokal sichern, offline arbeiten | V | 1.3, 9.1, 9.5, 10.1–10.6 |
| 51 | PDF-Export mit Notizen (ganzes Dokument, Seite) | V | 9.6–9.8, 9.10 |

## 17. Ergebnis zurück ins Projekt

Je „nicht bestanden“: Nummer, Gerät (Abschnitt 0), was passiert ist, wenn möglich Bildschirmaufnahme oder `.trace`.
Die Mac-Sitzung trägt die Ergebnisse in diese Datei ein (Spalten „Ergebnis“ und „Notiz“) und leitet daraus die
Reihenfolge der Härtungen ab (`docs/PENCILKIT-ANALYSE-PLAN.md`, Abschnitt 6; Befunde in `docs/EDITOR-MESSUNG.md`,
Abschnitt 4). Nach jedem Umbauschritt wird dieselbe Liste wiederholt; Punkte mit „bekannt“ wechseln dann auf eine
normale Erwartung.

## 18. Gerätepunkte zu Schritt 2 (Härtungen P0-3 bis P0-6)

Neu mit Schritt 2. Die Simulator-Tests dazu stehen in `EditorHardeningStep2Tests` (App) und
`SyncEngineHardeningTests` (Kern). **Nur mit D5.**

**P0-3 Obergrenze beim Sichern.** Ohne Schreibpause wird spätestens alle 2 s ins Journal gesichert. Eine Upload-Runde
mit dem ganzen Dokument startet erst nach der Pause, weil sie bei dichten Dokumenten Sekunden dauert (M1).

| Nr. | Schritt | Erwartung | Ergebnis | Notiz |
|---|---|---|---|---|
| 18.1 | 20 s schraffieren ohne den Stift abzusetzen bzw. ohne Pause zwischen den Strichen, dabei die Statusanzeige beobachten | Status „Lokal gesichert · 1 Seite wartet“; „Speichert…“ erscheint erst nach der Pause, dann einmal und danach „Gespeichert“. Schreiben bleibt flüssig | ☐ bestanden ☐ nicht bestanden | |
| 18.2 | Wie 18.1 auf einer schon voll beschriebenen Seite in einem dichten Dokument (D2 nach 9.2) | Schreiben ohne Ruckler. **Simulator:** je Sicherung der vollen Seite rund 0,08 s im Hintergrund, Hauptthread frei, keine Upload-Runde während des Schreibens (`docs/EDITOR-MESSUNG.md`, Abschnitt 8) | ☐ bestanden ☐ nicht bestanden | |
| 18.3 | Wie 10.4: 30 s schraffieren, während des Schreibens in Xcode Stop (■), neu starten | höchstens die letzten etwa 2 s fehlen; Hinweis „… ungesendete Seite(n) wiederhergestellt.“ | ☐ bestanden ☐ nicht bestanden | fehlt: |

**P0-4 Formatschutz.** Notizen, die eine neuere Version von Studora gespeichert hat (Format `version` größer als 2),
öffnen nur zum Ansehen und werden nie gespeichert.

| Nr. | Schritt | Erwartung | Ergebnis | Notiz |
|---|---|---|---|---|
| 18.4 | Testdokument mit Notizen in Format 3 öffnen (Testdatei bekommt der Inhaber auf Wunsch von der Mac-Sitzung; ohne sie „entfällt“, im Simulator geprüft) | Seitenleiste „Neueres Notizformat – nur ansehen“ und Hinweis „Diese Notizen stammen aus einer neueren Version von Studora – hier nur ansehen …“; keine Palette, der Stift schreibt nicht, Seiten-Menüpunkte gesperrt | ☐ bestanden ☐ nicht bestanden ☐ entfällt | |
| 18.5 | Danach schließen und erneut öffnen | Notizen unverändert sichtbar, weiterhin nur ansehen | ☐ bestanden ☐ nicht bestanden ☐ entfällt | |

**P0-5 Herkunftsstempel.** Beim ersten Speichern merkt sich das Dokument, zu welcher PDF die Notizen gehören. Beim
Öffnen wird das wie bisher geprüft.

| Nr. | Schritt | Erwartung | Ergebnis | Notiz |
|---|---|---|---|---|
| 18.6 | Neues Dokument ohne Notizen öffnen, einen Strich schreiben, schließen, erneut öffnen und weiterschreiben | kein Hinweis „Neue Fassung angekommen“, Schreiben geht | ☐ bestanden ☐ nicht bestanden | |
| 18.7 | Falls Stud.IP eine neue Fassung eines beschriebenen Dokuments liefert: Dokument öffnen | Hinweis „Neue Fassung aus Stud.IP – Notizen übernommen“, Notizen auf den passenden Seiten, Schreiben geht (nach dem erneuten Öffnen) | ☐ bestanden ☐ nicht bestanden ☐ entfällt | |

**P0-6 Dasselbe Dokument in zwei Fenstern.** Zwei Fenster dürfen nicht gleichzeitig in dasselbe Dokument schreiben.
Ist es im anderen Fenster zu sehen, öffnet das zweite nur zum Ansehen. Ist es dort nicht mehr zu sehen (anderes
Dokument gewählt, Fenster im Hintergrund), übernimmt das neue Fenster.

| Nr. | Schritt | Erwartung | Ergebnis | Notiz |
|---|---|---|---|---|
| 18.8 | Stage Manager oder Split View mit zwei Studora-Fenstern. Fenster A: D5 öffnen und schreiben. Fenster B: dasselbe D5 öffnen | B zeigt A's Striche, Seitenleiste „In einem anderen Fenster offen – nur ansehen“, Hinweis „… zum Schreiben dort schließen und hier neu öffnen“; in B keine Palette, der Stift schreibt nicht | ☐ bestanden ☐ nicht bestanden ☐ entfällt | |
| 18.9 | In A weiterschreiben, dann in A ein anderes Dokument wählen; in B D5 schließen und neu öffnen | B kann jetzt schreiben; A's Striche sind alle da | ☐ bestanden ☐ nicht bestanden ☐ entfällt | |
| 18.10 | A: D5 offen, Strich schreiben und sofort in A ein anderes Dokument wählen; dann in B D5 öffnen | B schreibt (Übernahme), der letzte Strich aus A ist in B zu sehen; kehrt man in A zu D5 zurück, während B es noch zeigt, ist A nur zum Ansehen | ☐ bestanden ☐ nicht bestanden ☐ entfällt | |
| 18.11 | Nach 18.8–18.10 beide Fenster schließen, D5 in einem Fenster öffnen | alle Striche aus beiden Fenstern da, kein Hinweis „beschädigt“ | ☐ bestanden ☐ nicht bestanden ☐ entfällt | |

## 19. Gerätepunkte zu Schritt 3 (Drehen P0-7, fremde Zeichnung P0-8)

Neu mit Schritt 3. Die Simulator-Tests dazu stehen in `EditorStep3Tests` (App), `PageOrderTests` und
`SharedFixtureTests.testRotateCasesMatchWebEditor` (Kern) sowie `tests/js/rotate.test.mjs` (Web, gleiche Fälle).

| Nr. | Schritt | Erwartung | Ergebnis | Notiz |
|---|---|---|---|---|
| 19.1 | D5: Seite mit Strichen, Textfeld und Textmarker viermal hintereinander drehen | nach jedem Drehen liegt alles auf demselben Inhalt; nach dem vierten Mal genau wie am Anfang | ☐ bestanden ☐ nicht bestanden | |
| 19.2 | Gedrehte Seite schließen und wieder öffnen | Striche sofort im eigenen Aussehen (nicht kurz anders gezeichnet), an derselben Stelle | ☐ bestanden ☐ nicht bestanden | |
| 19.3 | Mit PC: Seite im Browser drehen, dann auf dem iPad öffnen | Notizen auf demselben Inhalt; Stift-Striche erscheinen im Browser-Aussehen (Pinselbild geht wie bei jeder Browser-Änderung am Strich verloren) | ☐ bestanden ☐ nicht bestanden ☐ entfällt | |
| 19.4 | Mit PC: im Browser drehen, dann **Rückgängig** | Seite und Notizen wieder wie vorher (vorher blieben die Notizen gedreht stehen) | ☐ bestanden ☐ nicht bestanden ☐ entfällt | |
| 19.5 | Nur mit zwei iPads verschiedener iPadOS-Versionen: auf dem neueren mit einem neuen Stift (z. B. Schreibfeder ab iPadOS 26) schreiben, auf dem älteren daneben schreiben, wieder auf dem neueren öffnen | die Striche des neueren iPads behalten dort ihr Aussehen (P0-8); auf dem älteren erscheinen sie in Ersatzdarstellung | ☐ bestanden ☐ nicht bestanden ☐ entfällt | |


## 20. Gerätepunkte zu Schritt 5 (Seitenwerkzeuge P1-1, Navigation P1-2, eingefügte Seiten P1-3)

Neu mit Schritt 5. Simulator-Tests: `EditorStep5Tests` (App), `PageToolsTests` (Kern). Menü: Mehr → Seite.

| Nr. | Schritt | Erwartung | Ergebnis | Notiz |
|---|---|---|---|---|
| 20.1 | Beschriebene Seite kopieren | Kopie direkt dahinter, mit denselben Notizen; Striche der Kopie zuerst im Browser-Aussehen | ☐ bestanden ☐ nicht bestanden | |
| 20.2 | Seite nach vorne, nach hinten, an den Anfang, ans Ende | Reihenfolge stimmt, die Seite bleibt sichtbar; im Browser dieselbe Reihenfolge | ☐ bestanden ☐ nicht bestanden | |
| 20.3 | Leere Seite davor / am Ende, dann Vorlage und Format einer Leerseite ändern | Vorlage und Größe sofort sichtbar; bei PDF-Seiten fehlen „Vorlage“ und „Format“ | ☐ bestanden ☐ nicht bestanden | |
| 20.4 | Seite leeren (Rückfrage bestätigen) | Text, Formen und Striche der Seite weg, Nachbarseiten unverändert | ☐ bestanden ☐ nicht bestanden | |
| 20.5 | Zur Gliederung hinzufügen, Mehr → Gliederung, Eintrag antippen, Eintrag wegwischen | Sprung zur Seite; im Browser dieselbe Gliederung | ☐ bestanden ☐ nicht bestanden | |
| 20.6 | Gehe zu Seite … mit einer Zahl über der Seitenzahl | springt zur letzten Seite | ☐ bestanden ☐ nicht bestanden | |
| 20.7 | Dokument mit einer A0-Whiteboard-Seite zwischen A4-Seiten | A4 füllt die Breite (nicht mehr winzig), die A0-Seite ist breiter und lässt sich durch Herauszoomen ganz sehen (M6) | ☐ bestanden ☐ nicht bestanden | |
| 20.8 | Mit PC: im Browser PDF-Seiten einfügen, auf dem iPad öffnen | die eingefügten Seiten zeigen ihren Inhalt (vorher Platzhalter), Notizen darauf bleiben | ☐ bestanden ☐ nicht bestanden ☐ entfällt | |
| 20.9 | Linkshänder in den Einstellungen, Seitenleiste öffnen | Seitenleiste rechts, Skript in der geteilten Ansicht rechts | ☐ bestanden ☐ nicht bestanden | |

## 21. Gerätepunkte zu Schritt 6 (Objekt-Werkzeuge P1-4 bis P1-7, PDF-Text markieren P2-7)

Neu mit Schritt 6. Simulator-Tests: `EditorStep6Tests` (App), `PageObjectEditTests` (Kern). Umschalter „Tinte/Objekte“
in der Werkzeugleiste; im Objektmodus schreibt der Stift nicht.

| Nr. | Schritt | Erwartung | Ergebnis | Notiz |
|---|---|---|---|---|
| 21.1 | Objekte → Text, auf die Seite tippen, mit dem Pencil hineinschreiben (Scribble) und mit der Tastatur | Text erscheint im Feld, nach „Fertig“ gespeichert; ein leer gelassenes Feld verschwindet | ☐ bestanden ☐ nicht bestanden | |
| 21.2 | Haftnotiz setzen und beschriften | gelbe Notiz, im Browser gleich | ☐ bestanden ☐ nicht bestanden | |
| 21.3 | Rechteck, Ellipse, Linie, Pfeil ziehen | Form folgt dem Finger; Farbe aus der Palette | ☐ bestanden ☐ nicht bestanden | |
| 21.4 | Objekt antippen, ziehen, mit zwei Fingern vergrößern, Farbe ändern, löschen; dann Rückgängig/Wiederholen | jede Aktion umkehrbar; Striche bleiben unberührt | ☐ bestanden ☐ nicht bestanden | |
| 21.5 | Lasso um mehrere Objekte, gemeinsam verschieben | alle Objekte im Lasso bewegen sich, Striche nicht (die wählt das PencilKit-Lasso) | ☐ bestanden ☐ nicht bestanden | |
| 21.6 | Objekte → Text markieren, Text in der PDF gedrückt halten und ziehen, Markieren / Unterstreichen / Durchstreichen | Markierung auf der Zeile, Linie knapp unter der Schrift bzw. mitten durch; im Browser gleich | ☐ bestanden ☐ nicht bestanden | |
| 21.7 | Wie 21.6 auf einer gedrehten Seite | Markierung liegt auf dem gedrehten Text | ☐ bestanden ☐ nicht bestanden | |
| 21.8 | Am Mac („Designed for iPad“, falls freigeschaltet): mit Maus schreiben, mit Trackpad blättern | die Maus schreibt auch bei „Nur Stift“, Blättern mit Rad oder Trackpad | ☐ bestanden ☐ nicht bestanden ☐ entfällt | |

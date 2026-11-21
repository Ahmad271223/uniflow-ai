# Arbeitsspeicher auf kleinen iPads – Messung und Absicherung (21.11.2026, Zweig `app/speicher`)

Auftrag des Inhabers (20.11.2026): „iPads dürfen nie abstürzen wegen zu hohem Arbeitsspeicher, den wir einnehmen –
kontrolliere das.“ Ziel sind die kleinsten Geräte: iPad 9 (3 GB) und iPads mit 4 GB (iPad 10, Air 4, mini 6).
iPadOS beendet eine App dort ab grob 1,4–1,8 GB (3 GB) – geplant wird mit **1 GB**. Auf dem iPad des Inhabers
(A16, 6 GB) gab es bisher keinen Speicher-Absturz; das hier ist Vorsorge.

Basis: `release/1.0.7` @ `0688baa1` (in den Zweig gemischt). Das Blatt ersetzt den Zwischenstand vom 20.11.
(„Scrollen hakt“ von dort ist mit `098b5763` in `release/1.0.7` erledigt.)

## 1. Kurzfassung

| Fall | Spitze (Simulator, siehe 2.) | Bewertung für 1 GB |
|---|---|---|
| (a) 300 Seiten Skript, wenig Handschrift, durchblättern | 374 MB + 124 MB Bildspeicher | unkritisch |
| (a) 300 **volle** Seiten (90 000 Striche), durchblättern | 730 MB | knapp |
| (a) dasselbe Dokument **sichern** (eine Speicherrunde) | **1454 MB** | **zu viel – offen, siehe 6.1** |
| (b) A0-Seite voll beschrieben, Zoom der Zeichenfläche 3 / 4 | **1154 / 2052 MB** Bildspeicher | **zu viel – abgesichert (klein)** |
| (c) A4 bei 600 %, Ausschnitt auf einer Seitengrenze | 115 MB + 214 MB | unkritisch |
| (c) A4 bei 285 % (ganze Seite 4-fach, der größte A4-Fall) | 107 MB + 302 MB | unkritisch |
| (d) Lösung eingeblendet, 285 % | 224 MB + 542 MB | geht, wenig Luft |
| (d) Lösung in der Spalte daneben, größter Fall | 199 MB + 400 MB | unkritisch |
| (d) zwei Dokumente nebeneinander, beide 285 % | 247 MB + 604 MB | geht, wenig Luft |
| (e) Reiter: 18 Wechsel zwischen drei Dokumenten (echte App) | 113–118 MB, immer **ein** Editor | unkritisch, kein Leck |
| (f) Mensa: 40 Fotos gleichzeitig im Bild | 30 MB | unkritisch |
| (g) 30 Fotos in den Notizen | **+459 MB**, blieb bis zum Schließen | **wächst mit dem Dokument – abgesichert** |

„x MB + y MB“ = Speicher des Prozesses + Bildspeicher der Kacheln (auf dem Gerät zählt beides zusammen).

**Abgesichert (zwei Änderungen, je mit Test):**

1. **Große Seiten auf kleinen Geräten:** Seiten größer als A4/Folie zeigen beim Hineinzoomen nur den sichtbaren Teil
   scharf (derselbe Weg wie über 400 %), statt die ganze Seite auf Vorrat zu zeichnen. A0 voll: 54 MB statt 1154 MB.
2. **Fotos in den Notizen:** Was keine Seite mehr zeigt, fällt bei einer Speicherwarnung aus dem Speicher (alle
   Geräte), auf kleinen Geräten schon ab 96 MB. Zurückblättern lädt es neu. Speicherwarnung gab vorher 44 MB frei,
   jetzt 459 MB.

**Für Geräte ab 6 GB ändert sich nichts**, solange iPadOS keine Speicherwarnung schickt (Abschnitt 5).

**Offen und am wichtigsten:** Sichern und Öffnen kosten ein Vielfaches der Dokumentgröße (6.1). Das trifft sehr große
handschriftliche Dokumente auf 3-GB-Geräten und ist ein Umbau am Speicherweg, kein Editor-Thema.

## 2. Wie gemessen wurde – und was der Simulator nicht zeigt

Simulator „fix-speicher“ (Klon von `4495AA80…`, iPad, iPadOS 27.2, 834 × 1210 Punkte, Bildschirmfaktor 2), Mac mit
48 GB, Lastmittel 1–3 bei den Einzelmessungen. Jede Zahl in 3. stammt aus einem **eigenen Testprozess**
(`UNIFLOW_EDITOR_MESSUNG=speicher`, Tests in `apps/apple/UniFlowTests/SpeicherMessungTests.swift`).

- **`phys_footprint`** (wie „Memory“ in Xcode, Grundlage für das Beenden durch iPadOS) – Hilfen aus
  `EditorScaleTests.swift` (`Speicher`, `Spitze` alle 5 ms).
- **Bildspeicher der Kacheln (IOSurface):** PencilKit und PDFKit zeichnen in Kacheln, die als IOSurface angelegt
  werden. **Im Simulator zählen sie nicht zum `phys_footprint`** – von außen nachgemessen: Bei einer vollen A0-Seite
  (Stufe 4) zeigt `footprint <pid>` 82 MB und „IOSurface 0 B“, `vmmap` aber 2,1 GB IOSurface in 526 Bereichen.
  Darum zählt die Messung die IOSurface-Inhalte aller Ebenen selbst (`IOSurfaceGetAllocSize`,
  `EditorScaleTests.surfaceMB`). Auf dem Gerät zählt dieser Speicher zur App (Messung am iPad vom 03.11.2026,
  `SolutionLayer.swift`: fünf gezoomte Zeichenflächen 1178 statt 201 MB).
- **Reiter** in der echten App: `UniFlowUITests/SpeicherReiterUITests` tippt die Reiter an, `tools/speicher-reiter-zaehlen.sh`
  zählt von außen mit `heap <pid>` die Editoren. (In einem im Test gehosteten Fenster hält SwiftUI abgebaute
  Ansichten in seinem Zeichen-Zwischenspeicher fest – dort lebten nach 20 Wechseln 20 Editoren. Das ist eine
  Eigenheit des Testaufbaus, kein Leck der App: in der App ist es immer genau einer.)

**Gesehen** heißt im Folgenden: im Simulator gemessen. **Angenommen** ist: (1) IOSurface-Kacheln belasten das Gerät
in voller Größe, (2) die Grenze von iPadOS liegt bei 1,4–1,8 GB, (3) die CPU-seitigen Zahlen (Dokument, JSON, Fotos)
sind auf dem Gerät gleich groß. Nur am echten 3-GB-Gerät prüfbar: Abschnitt 7.

## 3. Messwerte

### (a) 300 Seiten

| Wert | Skript, 30 Striche je Seite | 300 volle Seiten (je 300 Striche) |
|---|---|---|
| Striche / JSON des Dokuments | 9 000 / 13 MB | 90 001 / 131 MB |
| Dokument im Speicher nach dem Anlegen | 90 MB | 419 MB |
| **eine Speicherrunde, Spitze** | 204 MB | **1454 MB** |
| Blättern bis zum Ende, Spitze `phys_footprint` | 374 MB | 730 MB |
| Blättern, Spitze Bildspeicher (sichtbar + geparkt) | 124 MB | nicht gemessen |
| Overlays danach lebendig (sichtbar / geparkt) | 9 (3 / 6) | 7 (1 / 6) |
| Speicherwarnung: geparkte Overlays danach | 0 | – |

Overlays und Zeichenflächen werden beim Blättern freigegeben (300 angelegt, 9 leben) – kein Leck.

### (b) A0 quer (Whiteboard), voll beschrieben, zwischen zwei A4-Seiten

Der Zoom gilt für das ganze Dokument: Wer auf A4 bei 250 % schreibt und auf die A0-Seite blättert, hat dort Stufe 4.

| PDF-Zoom → Stufe der Zeichenfläche | Zeichenfläche | Kacheln der Tinte (IOSurface) |
|---|---|---|
| ≤ 1,0 → 1 | ganze Seite, 32 Mio. Bildpunkte | 140 MB |
| 1,4 (Einpassung) → 1,5 | ganze Seite | 315 MB |
| 2 → 2 | ganze Seite | 560 MB |
| 3 → 3 | ganze Seite, 289 Mio. | **1154 MB** |
| 4 → 4 | ganze Seite, 514 Mio. | **2052 MB** |
| 6 → 6 / 8,4 → 10 | Ausschnitt | 45 / 31 MB |

`phys_footprint` blieb dabei bei 79–82 MB (siehe 2.). Dokument nur aus einer A0-Seite: Zoom reicht bis 1,5 → 315 MB.

### (c) A4, vier volle Seiten, Zoom relativ zur Einpassung

| Zoom | Zeichenflächen im Bild | `phys_footprint` | Tinte (IOSurface) | alle Kacheln (Tinte + PDF) |
|---|---|---|---|---|
| 100 % | 3 × ganze Seite, Stufe 1,5 | 97 MB | 61 MB | 102 MB |
| 200 % | 2 × ganze Seite, Stufe 3 | 101 MB | 135 MB | 197 MB |
| 285 % | 2 × ganze Seite, Stufe 4 | 107 MB | 240 MB | **302 MB** |
| 300 % | 2 × Ausschnitt, Stufe 6 | 112 MB | 178 MB | 252 MB |
| 400 %, Seitengrenze | 2 × Ausschnitt, Stufe 6 | 112 MB | 155 MB | 230 MB |
| 600 %, Seitenmitte | 1 × Ausschnitt 151 × 219 pt, Stufe 10 | 115 MB | 112 MB | 162 MB |
| **600 %, Seitengrenze** | 2 × Ausschnitt, Stufe 10 | 115 MB | 139 MB | **214 MB** |

Der Ausschnitt mit fester Größe (zwei volle Zeichenflächen an der Seitengrenze) kostet weniger als die ganze Seite bei
Stufe 4. Je Zeichenfläche bleibt das Budget von 33 Mio. Bildpunkten eingehalten (im Test geprüft). PencilKit legt
Kacheln für die **ganze** Zeichenfläche an, nicht nur für den sichtbaren Teil, aber nur dort, wo Tinte liegt.

### (d) Lösung daneben (sechs volle Seiten, Lösung ebenso voll)

| Fall | `phys_footprint` | Tinte (IOSurface) | alle Kacheln |
|---|---|---|---|
| nur eigene Notizen, 285 % | 105 MB | 240 MB | 302 MB |
| Lösung **eingeblendet**, 100 % | 217 MB | 122 MB | 163 MB |
| Lösung eingeblendet, 285 % | 224 MB | 480 MB | **542 MB** |
| Lösung eingeblendet, 600 % | 227 MB | 177 MB | 259 MB |
| Lösung in der **Spalte** daneben, eingepasst | 210 MB | 64 MB | 183 MB |
| Spalte bei 571 % (dort ganze Seite Stufe 4) | 199 MB | 240 MB | 400 MB |
| **zwei Dokumente** nebeneinander, beide 285 % | 247 MB | 480 MB | **604 MB** |
| zwei Dokumente, beide 600 % | 248 MB | 180 MB | 345 MB |

Die Spalte gibt weggescrollte Seiten frei (4 Overlays nach dem Blättern) und der Controller verschwindet beim
Schließen. Bei „zwei Dokumente“ waren beide Fenster im Test bildschirmgroß; in der App ist jede Hälfte schmaler.

### (e) Reiter (echte App, drei Demo-Dokumente, Antippen der Reiter)

| Zeitpunkt | Editoren | Dokumente (`DocumentStore`) | `SyncEngine` | Speicher der App |
|---|---|---|---|---|
| drei Reiter offen | 1 | 1 | 1 | 116 MB |
| nach 9 Wechseln | 1 | 1 | 1 | 114 MB |
| nach 18 Wechseln | 1 | 1 | 1 | 115 MB |

Reiter halten keinen Editor und kein Dokument im Speicher; nur das aktive ist geladen.

### (f) Mensa-Fotos

Die App fragt jedes Foto 480 Pixel breit an (`Mensa.imageWidth`), die Liste baut nur, was im Bild ist
(`LazyVStack`/`LazyVGrid`). 40 Fotos 480 × 360 gleichzeitig gezeigt: **+30 MB** (gerechnet 26 MB). Zum Vergleich
unverkleinert 2000 × 1500: +460 MB – die Anfrage mit `width=480` ist also die Absicherung. Gemessen wurde das
Dekodieren und Anzeigen von Hand; `AsyncImage` selbst lässt sich im Test nicht ohne Netz versorgen. Angenommen: der
Server des Studentenwerks hält sich an `width=480`.

### (g) Fotos in den Notizen (30 Seiten, je ein Foto aus der Kamera 4032 × 3024)

| Wert | vorher | jetzt |
|---|---|---|
| Größe im Speicher je Foto (auf 2400 × 1800 verkleinert) | 16,5 MB | 16,5 MB |
| 30 Fotos in einer Sitzung eingefügt | +494 MB (61 → 555 MB) | groß: unverändert; klein: höchstens 96 MB + die Bilder im Bild (Ablauf im Test geprüft, nicht mit 30 Fotos gemessen) |
| erneut geöffnet und durchgeblättert, danach | +451 MB, bleibt | groß: +459 MB bis zur Speicherwarnung |
| **Speicherwarnung gibt frei** | 44 MB, 30 Bilder bleiben | **459 MB**, 3 Bilder bleiben (die sichtbaren Seiten) |

### Speicherrunde und Öffnen, aufgeteilt (100 volle Seiten, 30 000 Striche, 43,5 MB JSON)

| Schritt | Zuwachs / Spitze |
|---|---|
| 30 000 Striche im Speicher | +119 MB (2,7-fach) |
| Dokument serialisieren (Gerät) | +44 MB |
| `PyJSON.parse` im lokalen Backend | +247 MB, Spitze 290 MB (**6,7-fach**) |
| `dumps` im lokalen Backend | +131 MB |
| ganze Runde (`DocumentStore.pause`) | Spitze +235 MB (5,4-fach) |
| erneut öffnen (`DocumentStore.load`) | Spitze +287 MB (6,6-fach) |

## 4. Auswertung: Was wächst womit?

| Wächst mit … | Was | Obergrenze? |
|---|---|---|
| Seitengröße × Zoom² | Kacheln der Tinte, bis Stufe 4 für die **ganze** Seite | A4: 120 MB je Zeichenfläche. Größere Seiten: vorher keine → **jetzt 144 MB auf kleinen Geräten** |
| Zahl der Zeichenflächen im Bild | eigene Notizen + eingeblendete Lösung + Korrektur, 2–3 Seiten | 2 Seiten × 2 Flächen × 120 MB = 480 MB (gemessen) |
| Zahl der Fotos im Dokument | `DocumentStore.images` | vorher keine → **jetzt Speicherwarnung / 96 MB** |
| Zahl der Striche im Dokument | Dokument im Speicher (2,7-fach JSON), Sichern und Öffnen (5–7-fach obendrauf) | **keine – offen (6.1)** |
| Seitenzahl | nichts Messbares: Overlays höchstens 3 sichtbar + 6 geparkt, Miniaturen höchstens 60 | ja |
| Zahl der Reiter | nichts (leichte Einträge) | ja (15) |

Lecks: keine gefunden (Overlays, Zeichenflächen, Spalte, Reiter geprüft).

## 5. Was abgesichert wurde

Geräteklasse: `apps/apple/UniFlow/Services/MemoryBudget.swift`, aus `ProcessInfo.physicalMemory`.
**klein** = bis 4 GB (Grenze 4,5 GiB), **groß** = alles darüber. Tests setzen `MemoryBudget.current`.

| | klein (≤ 4 GB) | groß (≥ 6 GB, Mac) |
|---|---|---|
| ganze Seite auf der Zeichenfläche (bis Stufe 4) | nur bis Seitenfläche × Zoom² ≤ 9 Mio. pt² | immer (wie bisher) |
| Fotos der Notizen, die keine Seite zeigt | höchstens 96 MB | ohne Grenze (wie bisher) |
| Fotos der Notizen bei Speicherwarnung | fallen heraus | fallen heraus (**neu**, nur bei Speicherwarnung) |

**1. Ganze Seite nur bis zur Flächengrenze** (`PageInkView.inkLayout`, neuer Parameter `wholePageArea`).
9 Mio. pt² lassen A4 (8,0 Mio. bei Stufe 4), Letter und Folien 16:9 (8,3 Mio.) unverändert – auch auf iPhones mit
3x-Bildschirm. Darüber (A3 ab Stufe 3, A2 ab Stufe 3, A1/A0 ab Stufe 1,5) zeigt die Zeichenfläche den sichtbaren
Teil mit Rand, mit demselben Weg wie über 400 % (Ausschnitt, Zoom-Geste, Deckbilder – nicht umgebaut). Die Zoomstufe
bleibt, die Tinte ist so scharf wie bisher. Gemessen mit der kleinen Klasse: A0 voll bei Stufe 3 **54 MB** (vorher
1154), bei Stufe 4 **48 MB** (vorher 2052). Eine Zeichenfläche kostet auf kleinen Geräten damit höchstens 36 Mio.
Bildpunkte (144 MB).

**2. Fotos der Notizen** (`DocumentStore.trimImages`, `PDFEditorController.imageSourcesInUse`). Bilder, die eine
Seite gerade zeigt (sichtbar oder geparkt), bleiben immer – eine Seite, die neu gezeichnet wird, fände ihr Bild sonst
nicht. Alles andere fällt bei einer Speicherwarnung heraus (Editor: `didReceiveMemoryWarning`, und der Store hört
selbst auf die Meldung), auf kleinen Geräten schon über 96 MB, die ältesten zuerst. Beim Zurückblättern lädt
`loadImage` neu (lokal, die Seite zeigt bis dahin kurz die graue Fläche wie beim ersten Laden). Ohne Editor, der
meldet, was im Bild ist (iPhone-Leser), fällt nichts heraus.

**Speicherwarnung – wer gibt was frei** (alles hängt an `UIApplication.didReceiveMemoryWarningNotification` bzw.
`didReceiveMemoryWarning`):

| Stelle | gibt frei |
|---|---|
| `PDFEditorController.didReceiveMemoryWarning` | geparkte Overlays, fremde Ebenen geparkter Seiten, **Fotos der Notizen (neu)** |
| `DocumentStore` (eigener Beobachter der Meldung) | eigene PDF-Instanz der Miniaturen, **Fotos der Notizen (neu)** |
| `PageSidebar` | alle Miniaturen außer den sichtbaren |
| `UFThumbnails` (`NSCache`, 300 Stück / 96 MB) | räumt das System selbst |

Ein zusätzlicher zentraler Verteiler wurde nicht gebaut: Die Messung zeigt keine Stelle, die ihn bräuchte.

**Nicht geändert, weil die Messung es nicht verlangt:** Budget des Ausschnitts (33 Mio. Bildpunkte: an der
Seitengrenze 214 MB), Zahl der geparkten Overlays (6 Stück: gemessen 41 MB bei wenig Handschrift, gerechnet höchstens 144 MB bei vollen Seiten),
Mensa-Fotos, Reiter, Miniaturen.

### Tests

- `SpeicherAbsicherungTests` (4): Geräteklasse nach Arbeitsspeicher; **große Geräte: 3300 Kombinationen** aus Format
  (A6–A0, Folien), Zoom, Lage und Bildschirmfaktor liefern genau dasselbe Ergebnis wie der wörtlich übernommene
  Stand vor der Änderung; kleine Geräte: übliche Formate unverändert, große Formate ≤ 36 Mio. Bildpunkte, sichtbarer
  Teil liegt auf der Zeichenfläche, Zoomstufe bleibt; Größe eines dekodierten Bildes.
- `EditorScaleTests.testKleinesGeraetGrosseSeiteNurAusschnitt`: im Editor mit gesetzter kleiner Klasse – A0 voll bei
  Stufe 3 und 4 nur Ausschnitt, Kacheln < 200 MB, Stift schreibt überall auf der sichtbaren Seite, Strich wird
  gespeichert; Gegenprobe mit der großen Klasse: ganze Seite wie bisher.
- `EditorScaleTests.testBilderDerNotizenFallenHerausUndLadenNeu`: Obergrenze, Speicherwarnung über Editor und über
  die Systemmeldung, sichtbare Seite behält ihr Bild, Zurückblättern lädt neu, große Geräte ohne Speicherwarnung
  unverändert, ohne Editor fällt nichts heraus.
- Messungen nur auf Anforderung: `EditorScaleTests.testSpeicher…OnRequest`, `SpeicherAnsichtenMessungTests`,
  `UniFlowUITests/SpeicherReiterUITests`.

## 6. Offen

### 6.1 Sichern und Öffnen wachsen mit dem ganzen Dokument (wichtigster Punkt)

Gesehen: Das Dokument liegt mit dem 2,7-fachen seiner JSON-Größe im Speicher; eine Speicherrunde legt das 5,4-fache
obendrauf, das Öffnen das 6,6-fache. 90 000 Striche (131 MB JSON): 419 MB Grundlast, **1454 MB beim Sichern**.
Die Grenze von 1 GB ist bei rund 60 000 Strichen erreicht. Der größte Posten ist das lokale Backend, das den Text
einer Runde als Wertebaum einliest (`PyJSON.parse`, 6,7-fach) und wieder schreibt
(`AnnotationEndpoints.swift`, `PUT …/annotations`).

Angenommen: Die Testseiten haben 300 Striche mit 14–24 Punkten; echte, eng beschriebene Seiten können deutlich mehr
Striche haben. Wie groß echte Dokumente sind, ist nicht gemessen – das zeigt die Größe von `annotations.data` in der
Datenbank eines Vielschreibers.

Vorschläge (alle am Speicherweg, darum nicht in diesem Auftrag angefasst; brauchen die Python- und Swift-Fixtures):
1. Im lokalen Backend den Text der Runde im Durchlauf umschreiben statt als Baum (spart rund das 6-fache der
   JSON-Größe; Gegenprobe gegen den heutigen Weg über die vorhandenen Fixtures).
2. Ablage je Seite (schon in `docs/EDITOR-MESSUNG.md` als nächster Schritt genannt; Vertragsänderung mit Python).
3. Bis dahin: Größe von `annotations.data` beobachten.

### 6.2 Große Seiten auf großen Geräten

Für Geräte ab 6 GB ist nichts geändert (Vorgabe). Dort kostet eine voll beschriebene A0-Seite bei Stufe 3 und 4
weiter 1,2 bzw. 2 GB, A1 bei Stufe 4 rund 1 GB. Eine Zeile würde es begrenzen
(`MemoryBudget.standard.wholePageInkArea`, z. B. 36 Mio. = höchstens 576 MB je Zeichenfläche; A4 bis A2 blieben
unverändert) – das ist eine Entscheidung des Inhabers und vorher am iPad zu zeigen.

### 6.3 Kleinere Punkte (nicht gemessen, aus der Durchsicht vom 20.11.)

- Mehrere Zeichenflächen zugleich (Lösung eingeblendet + zwei Dokumente + Korrektur) können sich auf kleinen Geräten
  zu mehr als 0,8 GB addieren; einzeln gemessen bleibt jeder Fall unter 1 GB.
- Beim Pinchen aus dem Ausschnitt liegt kurz eine zweite Zeichenfläche darunter (höchstens 33 Mio. Bildpunkte).
- Skriptsuche-Index (`ScriptSearch.IndexCache`, bis 20 Module ohne Größengrenze), Vorschaubilder der Aufzeichnungen
  (`RecordingLibrary.thumbnails`), Hochladen im Datei-Eingang (Datei bis 80 MB zweimal im Speicher),
  `AppDocumentTools.pdfPageTexts` ohne `autoreleasepool`.
- Miniaturen in der Seitenleiste zeigen ein Foto nur, wenn es im Speicher liegt (war schon so für Seiten, die noch
  nicht im Bild waren; gilt jetzt auch für herausgefallene Fotos).
- Berechtigung `com.apple.developer.kernel.increased-memory-limit` (höhere Grenze auf iPads) – nur mit dem Inhaber.

## 7. Nur am echten 3-GB-Gerät prüfbar

1. Wo iPadOS die App wirklich beendet (`os_proc_available_memory()` beim Start und unter Last).
2. Ob die Kacheln (IOSurface) in voller Größe zählen, und was PDFKit bei echten Vorlesungs-PDFs braucht.
3. Ob das Scrollen auf einer großen Seite (A3 bis A0) mit dem Ausschnitt unter Stufe 4 flüssig ist – der Weg ist
   derselbe wie über 400 % (am iPad des Inhabers abgenommen), auf einem A13 aber nicht gesehen.
4. Ob eine Speicherwarnung rechtzeitig kommt, bevor iPadOS beendet.

Abnahme am Gerät (iPad 9 oder iPad mit 4 GB): Whiteboard A0 voll schreiben, auf A4 auf 250 % zoomen, zur A0-Seite
blättern und dort schreiben und scrollen; Dokument mit 20 Fotos durchblättern; dabei in Xcode „Memory“ ansehen.

## 8. Vorkehrungen, die es schon gab (Durchsicht 20.11.2026)

- Reiter: nur das aktive Dokument im Speicher (`DocumentTabList`).
- Editor: höchstens 6 geparkte Overlays bzw. 6 A4-Flächen, geparkt in Bildschirmauflösung; Speicherwarnung gibt sie frei.
- Zeichenfläche über Stufe 4: nur der sichtbare Ausschnitt, höchstens 33 Mio. Bildpunkte (`inkPixelBudget`).
- Fremde Lösungen: eine gemeinsame Zeichenfläche je Seite statt einer je Ebene.
- Seitenminiaturen höchstens 60 (`ThumbnailCache`), Bibliotheks-Vorschauen `NSCache` 300 Stück / 96 MB.
- Texterkennung je Seite im `autoreleasepool`, Bildseite höchstens 4000 px; Fingerabdruck in 1-MB-Blöcken.
- Eingefügte Bilder höchstens 2400 px; Mensa-Fotos 480 px breit.
- Lösung daneben: weggescrollte Overlays werden freigegeben.

## 9. Wiederholen

```
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd apps/apple && xcodegen generate -q
# Messungen (je Test ein eigener Lauf, sonst mischt sich der Speicher der Tests):
TEST_RUNNER_UNIFLOW_EDITOR_MESSUNG=speicher xcodebuild test -project UniFlow.xcodeproj -scheme UniFlow \
  -destination "id=<Simulator>" -derivedDataPath <Ordner> \
  -only-testing:UniFlowTests/EditorScaleTests/testSpeicherZoomStufenOnRequest | grep EditorMessung
# weitere: testSpeicherA0OnRequest, testSpeicherNurA0OnRequest, testSpeicherLoesungDanebenOnRequest,
#          testSpeicherBilderDerNotizenOnRequest, testSpeicher300SeitenSkriptOnRequest,
#          testSpeicher300VolleSeitenOnRequest (2 min), testSpeicherRundeAufteilungOnRequest,
#          UniFlowTests/SpeicherAnsichtenMessungTests/testSpeicherMensaFotosOnRequest
# Reiter in der echten App (Zähler vorher im Hintergrund starten):
tools/speicher-reiter-zaehlen.sh <Simulator> reiter.log reiter-zaehlung.txt &
TEST_RUNNER_UNIFLOW_EDITOR_MESSUNG=speicher xcodebuild test … -only-testing:UniFlowUITests/SpeicherReiterUITests > reiter.log
# Speicher von außen (zählt im Simulator die Kacheln NICHT): footprint <pid>; vmmap -summary <pid> | grep IOSurface
```

## 10. Testläufe (21.11.2026, Simulator „fix-speicher“, Endstand des Zweigs)

| Lauf | Ergebnis |
|---|---|
| `EditorScaleTests` (ohne die Messungen auf Anforderung) | 17 grün, 9 übersprungen (auf Anforderung) |
| `EditorDeviceFixesTests` | 10 grün |
| `SpeicherAbsicherungTests` | 4 grün |
| `EditorStrichBleibtTests` | 36 grün, 2 übersprungen, **4 rot** (siehe unten) |
| `EditorVerbesserungTests`, `SolutionSideViewerAppTests`, `DocumentTabsHeaderAppTests`, `EditorFeatureTests`, `EditorStep6Tests`, `HardeningSolutionEditorTests`, `ViewTypeDepthAppTests`, `NebenblattBilderAppTests` | 64 grün, 6 übersprungen, 0 rot |
| `UniFlowUITests/SpeicherReiterUITests` (echte App) | grün, immer ein Editor |
| Python: `tests/test_ai_consent.py`, `test_release_gate.py`, `test_release_build_provenance.py` | 41 grün |

**Die vier roten Tests** sind die Lasso-Tests aus `LassoHaengerTests.swift`
(`testLassoGegenprobeTastaturVorherNachher`, `testLassoImDokumentOhneTastaturUndOhneHaenger`,
`testLassoMitSchwebenderPaletteOhneTastatur`, `testLassoVerschiebenKopierenEinfuegenOhneTastatur`): Der Simulator
meldet eine 69 Punkte hohe Tastaturleiste (`UIKeyboardWillShow (0, 1141, 834, 69)`), erwartet ist keine Meldung.
Sie sind **genauso rot auf dem unveränderten Stand** `release/1.0.7` @ `0688baa1` (Gegenprobe im selben Simulator
mit zurückgelegten Änderungen) und auf einem frisch angelegten Klon von `4495AA80…` – also ein Zustand der Klone
(Tastatur), keine Folge der Speicher-Änderung. Einzeln wiederholt: weiter rot.

Nicht gelaufen: der volle App-Lauf (`UniFlowTests` ganz), der Kern (`swift test`, dort nichts geändert), der
Release-Bau (kein Code nur unter `#if DEBUG` hinzugefügt).

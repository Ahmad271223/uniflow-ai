# Lösung teilen: Format, Ablauf, Sicherheit und Grenzen

Stand 26.10.2026, Zweig `wip/loesung-teilen` mit Nachbesserung `wip/loesung-teilen-fix` (Schritt S9 in
`docs/IPAD-OHNE-PC.md`), Online-Community in `wip/community-cloudkit` (S9b). Gilt für die native iPad-App.
Lösungen werden als Datei weitergegeben (AirDrop, Dateien-App, „Öffnen in“) **oder** in der Community veröffentlicht
(öffentliche CloudKit-Datenbank, Abschnitt 7) und ausschließlich auf dem iPad mit der eigenen PDF geöffnet. Die
Online-Community läuft nur in einem Build mit iCloud-Container (bezahltes Developer Program); sonst meldet die App
„Community nicht verfügbar“ und der Dateiweg bleibt.

## 1. Zwei getrennte Wege im Editor

| | A) PDF exportieren | B) Lösung teilen … |
|---|---|---|
| Inhalt | Original-PDF **mit** Notizen (Folien, Aufgaben, Handschrift) | **nur eigene Notizen**: Handschrift/Striche, Textfelder, Haftnotizen (Text mit Hintergrund), Formen, Zeichnungen, eigene Bilder |
| Zweck | privat, z. B. in der Dateien-App sichern | an Kommilitonen weitergeben, die dieselbe PDF haben |
| Hinweis vorher | „Die exportierte PDF enthält das Originalmaterial deiner Hochschule … nur privat“ | „Geteilt werden nur deine eigenen Notizen – keine Folien, keine Aufgabenstellungen, keine PDF. Teile nur, was du selbst erstellt hast.“ + Prüfungsordnung bei bewerteten Abgaben |
| Tarif | Free und Plus | Plus (Funktion `.community`; Free sieht ein Schloss mit Weg zur Abo-Seite über `UFGate`/`UFLockedCard`) |
| Datei | `Titel – Notizen.pdf` bzw. `Titel.pdf` | `Titel – Lösung.uniflowsolution` |

Code: `Views/DocumentView.swift` (Menü „Teilen“ mit den Abschnitten „PDF exportieren (nur privat)“ und „Nur eigene
Notizen“, Menü „Ebenen“, „Mehr → Lösung importieren …“), `Views/SolutionViews.swift` (Dialoge),
`Services/ShareExport.swift` (privater PDF-Export, Kommentar korrigiert: er ist nicht für die Community).

## 2. Dialog „Lösung teilen“

- Vorschau **ohne Original**: je Seite eine Miniatur auf weißem Grund (Leerseiten mit ihrer Vorlage), gezeichnet von
  `SolutionPreview` mit derselben Routine wie PDF-Export und Miniaturen, aber ohne PDF-Seite.
- Auswahl der Seiten, Standard: Seiten mit eigenen Anmerkungen. Knöpfe „Alle“ und „Nur mit Notizen“.
- Eingefügte Bild- oder PDF-Seiten aus dem Browser (`pageOrder` `type: "asset"`) werden nie geteilt (ihr
  Hintergrund kann fremdes Material sein); der Dialog nennt ihre Anzahl.
- Fehlende Bilder (nicht ladbar) werden gezählt und angezeigt; sie fehlen im Paket. Eigene Bilder über
  8 192 Pixel Kantenlänge oder 16,7 Megapixel werden beim Einbetten verkleinert (Lage und Größe auf der Seite bleiben
  gleich), damit der Empfänger sie öffnen kann.
- Seiten, deren Objekte die Prüfungen nicht bestehen (unbekannter Objekttyp, ungültige Zahlen, PDF-Daten in einem
  Verweisfeld), nennt der Dialog mit Seitenangabe („PDF-Seite 3 lässt sich nicht teilen: …“) und lässt sie aus; der
  Rest bleibt teilbar.
- Optionales Pseudonym (leer = anonym, gemerkt für das nächste Mal, je Apple-Nutzer und Hochschule in den Einstellungen des Containers; auch in den Einstellungen unter „Community“).
- „Als Datei teilen“ öffnet das Teilen-Menü des Systems und merkt die Lösung unter „Meine geteilten Lösungen“.
  Inhalt, Siegel (HKDF über die ganze PDF, AES-GCM) und Datei entstehen abseits des Hauptthreads; währenddessen steht
  „Wird erstellt …“ auf dem Knopf.
- Nie ein leeres Paket: Ohne ein einziges eigenes Notizobjekt auf den gewählten Seiten (z. B. „Alle“ gewählt, aber
  nirgends Notizen) bleibt der Knopf gesperrt und der Dialog sagt warum; auch `SolutionBuilder` weist das ab
  (`SolutionError.noOwnNotes`) – keine Datei, kein Eintrag unter „Meine geteilten Lösungen“. Die Vorschau selbst ist
  kein Teilen (`SolutionSharing.draft`, `requireOwnNotes: false`): Stehen die eigenen Notizen nur auf ausgelassenen
  oder eingefügten Seiten, zeigt der Dialog die Vorschau mit genau diesen Gründen statt „keine eigenen Notizen“.
  Bleibt gar keine teilbare Seite, nennt die Meldung alle Gründe.
- Karte „In der Community“: Sichtbarkeit **Modul** (alle mit demselben Kurs; nur bei Dateien aus einem Kurs des eigenen
  Abgleichs, sonst Hinweis), **Lerngruppe** (Auswahl der eigenen Lerngruppen) oder **Anonym** (alle an der Hochschule,
  ohne Pseudonym), dazu der Urheberrechts-Hinweis (`CommunityTexts.copyright`). Ohne iCloud-Container im Build steht
  dort „nicht verfügbar“ und der Knopf bleibt gesperrt.
- „In der Community veröffentlichen“ (nur mit Plus, wie die ganze Seite; nur mit Dienst): Bestätigung mit Sichtbarkeit,
  Pseudonym, Prüfungsordnung und Datenschutz-Hinweis; dann Inhalt und Siegel wie beim Dateiweg, Kopie unter „Meine
  geteilten Lösungen“, Upload; danach „Veröffentlicht … veröffentlicht am …“.
- „Abbrechen“.

## 3. Format `uniflow-solution`, Formatversion 1

Kern: `apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/Solutions/` (Foundation-only, baut und testet unter Linux).

Datei `*.uniflowsolution` (UTF-8-JSON, sortierte Schlüssel, Dokumenttyp `de.uniflow.solution`):

```json
{
  "format": "uniflow-solution",
  "formatVersion": 1,
  "header": {
    "solutionId": "6f1c1c0e-…",                 // UUID, eindeutig je Lösung
    "createdAt": "2026-10-25T10:00:00Z",        // ISO 8601, UTC
    "displayName": "",                          // leer = anonym
    "document": { "sha256": "<64 Hex>", "pageCount": 12 },
    "contents": { "pages": 3, "images": 1, "missingImages": 0 },
    "encryption": { "cipher": "AES-256-GCM", "kdf": "HKDF-SHA256", "keyMaterial": "original-pdf-bytes",
                    "salt": "<Base64, 32 Byte>", "nonce": "<Base64, 12 Byte>", "plaintextBytes": 4711 }
  },
  "ciphertext": "<Base64: Chiffrat + 16-Byte-Tag>"
}
```

Verschlüsselter Inhalt (`SolutionContent`):

```json
{
  "format": "uniflow-solution-content", "formatVersion": 1,
  "solutionId": "…", "createdAt": "…", "title": "Übungsblatt 3", "displayName": "",
  "document": { "sha256": "…", "pageCount": 12 },
  "pages": [
    { "key": "p1", "kind": "pdf", "pdfIndex": 1, "width": 595, "height": 842, "rotation": 0, "extraRotation": 0,
      "objects": [ … 1:1 aus pages[key].objects … ] },
    { "key": "b…", "kind": "blank", "template": "lined", "width": 595, "height": 842, "rotation": 0,
      "extraRotation": 0, "objects": [ … ] }
  ],
  "images": { "<src des Bildobjekts>": { "mime": "image/png", "data": "<Base64>" } },
  "missingImages": [ "<src>" ]
}
```

- **Fingerabdruck** `document.sha256`: SHA-256 der **unveränderten Bytes der Original-PDF-Datei**, aus der der Editor
  die PDF lädt (`DocumentStore.originalPDFURL`), nie `PDFDocument.dataRepresentation()`. Er dient **nur der
  Zuordnung** zur PDF des Empfängers.
- **Seitenzuordnung**: `pdfIndex` 1-basiert; `width`/`height` = CropBox ohne Drehung in PDF-Punkten;
  `rotation` = Drehung der angezeigten Seite beim Absender (`/Rotate` der PDF + `extraRotation` aus `pageOrder`). In
  diesen Koordinaten (Ursprung oben links, ohne Zoom) stehen die Objekte – genau wie im Notizmodell.
- **Objekte**: alle Felder 1:1, auch unbekannte (`JSONValue`). Erlaubte Typen wie im gemeinsamen Notizformat:
  `stroke`, `text`, `shape`, `image`. Ein unbekannter Typ wird beim Teilen gemeldet statt still verworfen und beim
  Öffnen abgewiesen. `pkdrawing` (native PencilKit-Daten) bleibt weg, die Striche stehen vollständig in `objects`.
- **Bilder**: eingebettet als PNG, wenn verfügbar; sonst in `missingImages` gezählt.
- **Nie im Paket**: Original-PDF, PDF-Bytes oder -Stücke, Seitenbilder, Aufgabenstellungen, Wurzelfelder des eigenen
  Dokuments (Lesezeichen, Notiz, Papierkorb). Die **Garantie** dafür ist der Aufbau des Builders
  (`SolutionBuilder`): Er übernimmt nur eigene Objekte aus `pages[key].objects` von PDF- und Leerseiten, keine
  `asset`-Seiten, kein `pkdrawing` und keine Wurzelfelder; eingebettete Bilder müssen PNG oder JPEG sein.
- **Zusatzsicherung (nur eine Heuristik)**: `SolutionValidator.checkNoPDF` weist in Verweis- und Datenfeldern
  (`src`, `data`, `url`, `href`, `file`, `asset`, `uri`) Werte mit `application/pdf`, `%PDF-` oder `JVBERi0` (Base64
  von `%PDF-`) ab und in allen übrigen Feldern Werte, die damit **beginnen**. Freitext (`text`) wird nicht geprüft:
  Eine Notiz „als application/pdf speichern“ ist eigener Inhalt und geht nicht verloren. Base64 einer PDF in anderer
  Ausrichtung (nicht ab Byte 0) erkennt die Heuristik nicht.
- `AnnotationDocument` und `annotations.schema.json` sind **unverändert**; das Paket ist ein eigenes Format neben dem
  Notizmodell.

Prüfungen beim Öffnen (`SolutionPackage.decode`/`open`, dieselben Regeln schon beim Erzeugen): Formatkennung,
Version (ganzzahlig und als `Int` darstellbar, sonst „Kopf: Formatversion“; andere Version: „bitte UniFlow
aktualisieren“ – nie ein Absturz bei Werten wie `1e300`), oberste Ebene genau `format`, `formatVersion`, `header`,
`ciphertext` (jedes weitere Feld wird abgewiesen), Kopf genau in der Form von Version 1 (zusätzliche Felder abgewiesen),
UUID, Datum, Hex-Fingerabdruck, Salz/Nonce-Länge, angegebene Größe = Chiffratgröße, alle Zahlen endlich
(`1e999` wird abgewiesen), Grenzen (65 MB Datei, 48 MB Inhalt, 2 000 Seiten, 20 000 Objekte je Seite, 200 Bilder à
10 MB), Seiten (Art, PDF-Seite im Bereich, Größe, Drehung Vielfaches von 90), Bilder (PNG/JPEG nach den ersten Bytes),
Inhalt passt zum Kopf. In der App zusätzlich vor dem Anzeigen: Pixelmaße jedes Bildes aus dem Bildkopf
(`CGImageSourceCopyPropertiesAtIndex`, ohne zu dekodieren) höchstens 8 192 Pixel je Kante und 16,7 Megapixel – ein
kleines, stark komprimiertes PNG kann sonst beim Entpacken Gigabyte belegen. Ist ein Bild zu groß oder unlesbar, wird
die ganze Lösung abgewiesen.

## 4. Ablauf beim Empfänger (lokal, ohne Server)

1. Datei öffnen: „Öffnen in UniFlow“/AirDrop (`CFBundleDocumentTypes` und `UTExportedTypeDeclarations` in
   `apps/apple/project.yml`, `.onOpenURL` in `UniFlowApp.swift`) oder im Editor „Mehr → Lösung importieren …“ bzw.
   „Ebenen → Lösung importieren …“ (`fileImporter`).
2. Der Kopf wird geprüft, das Paket **verschlüsselt wie empfangen** unter
   `<Container>/solutions/received/<id>.uniflowsolution` abgelegt (Container je Apple-Nutzer und Hochschule) (in der geprüften, kanonischen Form
   `encoded()`: Kopf und Chiffrat unverändert, keine weiteren Bytes), der Index (`solutions/index.json`) ordnet es dem
   Fingerabdruck zu (`SolutionLibrary`). Ein **anderes** Paket mit derselben Lösungs-ID (anderer Fingerabdruck, Kopf
   oder anderes Chiffrat) verdrängt eine schon gespeicherte Lösung nie, denn beim Import ist der Kopf noch nicht
   authentifiziert: Es wird mit „Eine andere Lösung mit derselben Kennung ist schon gespeichert“ abgewiesen. Derselbe
   Inhalt darf erneut importiert werden.
   Import im offenen Dokument („Lösung importieren …“): Passt der Fingerabdruck, wird sofort geöffnet. Lässt sich die
   Lösung trotzdem nicht öffnen (manipuliertes Chiffrat, mit einer anderen PDF versiegelt), wird sie gleich wieder
   entfernt: „Die Datei passt nicht zu dieser PDF oder wurde verändert.“
3. Öffnet der Nutzer die passende PDF, entschlüsselt die App die Lösung im Arbeitsspeicher mit den Bytes seiner
   eigenen Datei und prüft jede PDF-Seite (Seitenzahl, Größe, Drehung). Passt etwas nicht, erscheint die Ebene
   **gar nicht** (auch nicht teilweise) und es gibt eine klare Meldung – einmal je Sitzung als Hinweis, danach steht
   sie im Menü „Ebenen“ unter „Nicht lesbar: …“ mit „Entfernen“. Entschlüsseln (HKDF über die ganze PDF, in Blöcken über
   die gemappte Datei ohne Vollkopie) läuft abseits des Hauptthreads.
4. Menü „Ebenen“: „Meine Notizen“ ein-/ausblenden (ausgeblendet = nur ansehen: Canvas ohne Eingabe, Palette weg,
   kein Rückgängig, auch nicht über das System – Cmd-Z, Wischen mit drei Fingern –, weil der Editor der
   Responder-Kette dann einen leeren Verlauf gibt; im Menü „Mehr“ sind Lesezeichen, Leerseite, Papierkorb, Drehen und
   Text gesperrt, mit dem Eintrag „Meine Notizen einblenden, um zu bearbeiten“; auch der `DocumentStore` nimmt dann
   keine schreibenden Aktionen an, `ownNotesReadOnly`), je Lösung „Lösung von <Name oder Anonym> (<Datum>)“ mit
   Ein-/Ausblenden, „Vorschau ohne Original“ und „Entfernen“.
5. Anzeige: eigene, nicht bearbeitbare Schicht `PageInkView.foreignView` über der PDF und unter den eigenen Objekten
   und der Zeichenfläche (`PDFEditorController.applyForeign`, `ForeignLayerView`). Zuordnung über den PDF-Seitenindex.
   Hat der Empfänger die Seite anders gedreht als der Absender, bildet `SolutionGeometry.transform` die Anzeige um –
   die Objekte selbst werden nie umgerechnet. Zoom ist reine Anzeige. Striche zeichnet PencilKit in einer nicht
   bedienbaren Canvas der Ebene (`ForeignLayerView.ink`), wie auf der Canvas des Absenders; so sind Breite und Tinte
   gleich (vorher CAShapeLayer mit der gespeicherten Breite, beim Empfänger sichtbar dicker, `ForeignInkWidthTests`).
   Der Ende-zu-Ende-Test prüft die Lage auch nach 2-fach-Zoom und Scrollen in Fensterkoordinaten gegen die PDF-Seite
   (PDFKit) und die Strichbreite über die Pixel im Bild. Eigene Leerseiten des Absenders gibt es beim
   Empfänger nicht; sie sind nur in der Vorschau zu sehen. Zahlen der Objekte werden vor dem Anzeigen endlich und
   begrenzt gelesen (`ObjectGeometry.number`: Lage und Größe ±100 000 Punkte, Skalierung ±100, Drehung modulo 360),
   so entsteht auch bei Werten wie `1e300` keine Ebene mit NaN oder Unendlich. Nach einer Speicherwarnung werden die
   fremden Ebenen weggescrollter Seiten freigegeben und beim Zurückscrollen neu aufgebaut.
6. Eigene Notizen werden **nie** verändert: Es gibt keinen Schreibweg von der Lösung in `DocumentStore`, Journal oder
   Server (Test `testOwnNotesUnchangedAfterImportAndShowing`: serialisiertes eigenes Dokument vor/nach Import und
   Einblenden byte-gleich). Auch Scrollen, Ein-/Ausblenden und der Ansichtsmodus schreiben nichts: Der Editor gibt nur
   echte Änderungen der Zeichenfläche an den Store, eine nur angezeigte Seite wird nie gespeichert
   (`HardeningSolutionEditorTests`).

„Meine geteilten Lösungen“ (Menü „Teilen“): Kopien der selbst geteilten und veröffentlichten Pakete unter
`solutions/shared/` mit Zustand „als Datei geteilt“ oder „veröffentlicht am …“ (`SharedEntry.publishedAt`), „Erneut
teilen“, bei Veröffentlichungen „Zurückziehen“ (Dienst: Eintrag als zurückgezogen markiert, Paket gelöscht; danach
erst „Entfernen“ der Kopie). Bereits weitergegebene Dateien und schon geladene Lösungen kann UniFlow nicht
zurückholen – das steht so im Blatt.

## 5. Sicherheit – und was sie nicht leistet

- **Verschlüsselung**: AES-256-GCM (CryptoKit, nur in der App, `Services/SolutionCrypto.swift`). Schlüssel per
  HKDF-SHA256 aus den **vollständigen Bytes der Original-PDF** mit zufälligem 32-Byte-Salz und Info
  `uniflow-solution/v1|<Lösungs-ID>`. Bewusst **nicht** aus dem Fingerabdruck: der steht im Klartext im Kopf, sonst
  könnte jeder mit dem Paket entschlüsseln (Test: mit dem Hash als Schlüsselmaterial lässt sich nichts öffnen).
- **Kopf als AAD**: alles außer dem Chiffrat ist authentifiziert (`format`, `formatVersion`, `header`). Weitere
  Felder auf oberster Ebene oder im Kopf werden schon beim Lesen abgewiesen, es gibt also keinen unbemerkten Träger
  für weitere Daten. Wer Name, Datum, Fingerabdruck, Inhaltsangaben, Salz oder Nonce ändert, bekommt „lässt sich nicht
  öffnen“. Achtung: Authentifiziert ist der Kopf erst beim Öffnen mit der PDF; beim Import ist er nur geprüft (daher
  die Regel zur gleichen Lösungs-ID oben).
- **Was das bedeutet**: Lesen kann eine Lösung nur, wer genau diese PDF-Datei besitzt. Titel und Notizen stehen nicht
  im Klartext; im Klartext stehen Lösungs-ID, Datum, Anzeigename, Fingerabdruck und Seitenzahl.
- **Was es nicht leistet (ehrlich)**: Der Besitz der Datei beweist **keine Kursberechtigung**. Stud.IP-Dateien sind
  für alle Kursteilnehmer gleich und können weitergegeben werden; wer die PDF hat, kann die Lösung lesen. Das ersetzt
  **keine serverseitige Zugriffskontrolle**. Ein Fingerabdruck ist kein Besitznachweis, und eine leicht geänderte
  Fassung der PDF (neuer Upload) passt nicht mehr.
- **Robustheit gegen präparierte Dateien**: `decode` läuft auf ungeprüften fremden Bytes (AirDrop, Dateien,
  „Öffnen in“) und nutzt nur Umwandlungen, die nicht abbrechen können (`exactInt` statt `Int(Double)`). Bilder werden
  vor dem Anzeigen auf ihre Pixelmaße geprüft (siehe oben).
- Der Kern (`SolutionSHA256`) rechnet SHA-256 ohne CryptoKit (Linux); die App nimmt CryptoKit, beide Wege sind im
  Test gleich. HKDF rechnet die App als HMAC-SHA256 in Blöcken (Extract) plus `HKDF.expand`; Test gegen RFC 5869
  (Testfall 1) und gegen CryptoKit `HKDF.deriveKey`.

## 6. Community-Schnittstelle

`Solutions/CommunityService.swift` (Kern, ohne CloudKit – der Dienst ist tauschbar, später Supabase):

| Aufruf | Zweck |
|---|---|
| `publish(_ package, options:)` | verschlüsseltes Paket veröffentlichen; Optionen: Sichtbarkeit, Kurs-Schlüssel, Gruppen-Schlüssel, Titel, Lehrwoche |
| `findMatching(fingerprint:)` | Lösungen zu einer PDF finden (nur Kopfdaten), schon gefiltert nach Hochschule, Sichtbarkeit, Zurückgezogen, Sperrliste |
| `findForCourse(courseKey:)` | Lösungen zu allen Dateien eines Kurses (Moduldetail, nach Lehrwoche) |
| `download(solutionID:)` | Paket laden, geöffnet wird lokal mit der eigenen PDF |
| `withdraw(solutionID:)` | eigene Veröffentlichung zurückziehen (nur eigene) |
| `report(solutionID:reason:note:)` | melden (fremdes Material, bewertete Abgabe, beleidigend, Spam, sonstiges) |
| `block(owner:)`, `unblock`, `blockedOwners()` | eigene Sperrliste (privat) |
| `createStudyGroup(name:)`, `joinStudyGroup(code:)`, `leaveStudyGroup`, `studyGroups()` | Lerngruppen |

Die neuen Aufrufe haben Standardimplementierungen („nicht verbunden“), `publish(_:)` ohne Optionen bleibt als
Kurzform. Umsetzungen: `NotConnectedCommunityService` (Kern: wirft, sendet nichts) und `CloudKitCommunityService`
(App, Abschnitt 7). Reine Funktionen im Kern (`CommunityRules.swift`): `CommunityKeys.courseKey(university:courseID:)`
(SHA-256 aus Hochschule und Stud.IP-/Learnweb-Kurs-ID), `CommunityKeys.groupKey(university:code:)`,
Beitrittscodes (8 Zeichen ohne 0/O/1/I), `CommunityRules.isVisible`/`visible` (Filter), `effectiveDisplayName`
(anonym = nie ein Pseudonym), `validate` (Optionen), `byWeek`.

## 7. Online-Community über CloudKit (S9b)

Entscheidung des Inhabers vom 26.10.2026: **CloudKit für V1**, später Supabase. Code: `Services/CommunityCloud.swift`
(schmale Schnittstelle `CommunityCloud` über die Datensatz-Operationen, Umsetzung `CKCommunityCloud`; Tests nehmen
einen Nachbau im Speicher), `Services/CommunityCloudKit.swift` (`CloudKitCommunityService`, `CommunityMembership`,
`CommunityCourses`, `CommunityMatches`), `Views/CommunityViews.swift` (Oberfläche).

**Datensätze** in der öffentlichen Datenbank des Containers `iCloud.de.uniflow.ai`:

| Typ | Felder |
|---|---|
| `Solution` | `solutionID`, `fingerprint` (SHA-256 der Original-PDF, nur Zuordnung), `university` (`luh`/`hildesheim`), `courseKey`, `visibility` (`modul`/`lerngruppe`/`anonym`), `groupKey`, `displayName` (Pseudonym, leer bei anonym), `title`, `pageCount`, `week`, `createdAt`, `package` (Asset: das verschlüsselte `.uniflowsolution`, ohne Original-PDF), `ownerRecordName` (CloudKit-Nutzerkennung), `withdrawn` |
| `Report` | `solutionID`, `reason`, `note` (höchstens 500 Zeichen), `reporterRecordName`, `createdAt` |
| `StudyGroup` | `groupKey` (Hash aus Hochschule und Code – der Code selbst liegt nie beim Dienst), `name`, `university`, `ownerRecordName`, `createdAt` |
| `Block` (private Datenbank) | `ownerRecordName`, `createdAt` – nur für den Nutzer selbst sichtbar |

**Berechtigung (ehrlich):** Wer sucht, bildet aus allen Kurs-IDs seiner lokalen Datenbank die Kurs-Schlüssel; der
Dienst liefert zu einem Fingerabdruck nur Einträge derselben Hochschule, die nicht zurückgezogen sind, deren
Besitzer nicht gesperrt ist und die zur Sichtbarkeit passen: Modul nur mit passendem Kurs-Schlüssel, Lerngruppe nur
mit passendem Gruppen-Schlüssel (Kenntnis des Codes), anonym für alle an der Hochschule. Die Prüfung läuft in der
App (`CommunityRules`), nicht auf dem Dienst: Wer die Kurs-ID oder den Code kennt, kann den Schlüssel bilden – das
ist **kein** signierter Beleg der Hochschule. Lesen kann eine Lösung weiterhin nur, wer dieselbe PDF besitzt
(Abschnitt 5).

**Datenschutz:** Hochgeladen werden nur Paket, Kopfdaten, Sichtbarkeit und Pseudonym. Nie Apple-ID, Name, E-Mail
oder Matrikelnummer; `ownerRecordName` ist die CloudKit-Nutzerkennung und dient nur dem Zurückziehen (nur eigene),
Melden und Blockieren. Stud.IP-Cookies, -Sitzungen oder -Tokens gehen nie an den Dienst. Pseudonym, Lerngruppen
und Sperrliste (Zwischenspeicher) liegen je Container (Apple-Nutzer, Hochschule); „Daten dieser Hochschule
löschen“ und „Konto löschen“ entfernen sie mit.

**Oberfläche (Plus, `UFGate(.community)`):** Dialog „Lösung teilen“ (Abschnitt 2); im Dokument beim Öffnen
`findMatching` (nur mit Dienst, Ergebnis je Sitzung zwischengespeichert, nie blockierend) → Hinweis „n Lösungen aus
der Community zu diesem Blatt“ und Eintrag im Menü „Ebenen“ → Blatt mit Pseudonym/Datum/Seitenzahl, „Laden und
anzeigen“ (derselbe Weg wie „Lösung importieren …“: `DocumentStore.importFromCommunity` schreibt das Paket als Datei
und ruft `importSolution`; fremde Ebene, eigene Notizen unverändert), „Melden …“ (Grund und Notiz), „Nutzer
blockieren …“, bei eigenen „Zurückziehen“; Moduldetail → Reiter „Community“ (`findForCourse` je Kurs des Moduls, nach
Lehrwoche, „Blatt öffnen“ bei gleichem Titel); „Meine geteilten Lösungen“ (Abschnitt 4); Einstellungen → Karte
„Community“: Pseudonym, Lerngruppen (anlegen → Code und QR `uniflow://community/join/<Code>`, beitreten mit Code,
verlassen), Sperrliste (freigeben).

**Fehler verständlich** (`CommunityServiceError`): nicht verfügbar (Build ohne Container), nicht bei iCloud
angemeldet, kein Netz, Kontingent erschöpft, nur eigene zurückziehen, nicht mehr vorhanden, Datei ohne Kurs,
ungültiger Code, keine Lerngruppe.

**Build:** Container nur mit `Config/Team.xcconfig` (`UF_CLOUDKIT_CONTAINER = iCloud.de.uniflow.ai` → Info.plist
`UFCloudKitContainer`; Berechtigungen `icloud-container-identifiers`/`icloud-services` in `UniFlow.entitlements`,
aktiv nur mit `CODE_SIGN_ENTITLEMENTS`). Ohne Team ist der Wert leer: `CommunityCloudFactory.make()` liefert nil,
`CKContainer` wird nie erzeugt (kein Absturz), `isConnected` ist false.

**Grenzen und offene Punkte (Inhaber):**
1. CloudKit gibt es nur auf Apple-Geräten; für Windows/Android (V2) wird der Dienst hinter `CommunityService`
   gegen Supabase getauscht (gleiche Schlüsselbildung, gleiche Regeln).
2. Echter Lauf nur mit Developer Program: iCloud-Container anlegen, Datensatztypen und Indizes (QUERYABLE auf
   `fingerprint`, `university`, `courseKey`; Development-Umgebung legt Felder beim ersten Speichern an, Production
   braucht „Deploy Schema“), Berechtigungen der öffentlichen Datenbank (Lesen alle, Schreiben nur Ersteller – Standard).
3. Moderation: Meldungen (`Report`) sichtet der Inhaber im CloudKit Dashboard; Löschen und Sperren dort. Löschfristen,
   Kontakt für Lehrende, Nutzungsbedingungen und Datenschutzerklärung mit der Community sind offen.
4. Berechtigung = Kenntnis der Kurs-ID bzw. des Codes (siehe oben); ein signierter Beleg der Hochschule oder OAuth2
   (`docs/ANFRAGE-STUDIP-ZUGANG.md`) wäre stärker.
5. Neue Fassungen der PDF: Zuordnung weiter nur über den Datei-Hash (S7-Anmerkung bleibt).

## 8. Tests

- Kern (`UniFlowCoreTests/SolutionPackageTests`, mit einer nur für Tests gebauten HMAC-Verschlüsselung, damit Format,
  AAD und Prüfungen auch unter Linux laufen): SHA-256-Testvektoren, Objekte inkl. unbekannter Felder exakt gleich,
  kein `pkdrawing`/keine Wurzelfelder, mehrseitig mit Leerseite und Drehung, fehlende Bilder, keine PDF-Bytes/-Stücke/
  `%PDF`/`JVBER` in Datei und Klartext, zweites Gerät (zweiter Ordner) mit derselben PDF → identische Objekte, andere
  PDF/gefälschter Fingerabdruck → keine Entschlüsselung, manipulierte Pakete (Chiffrat, Tag, Kopf, Version, Größe,
  kaputtes JSON, unbekannte Objekttypen, nicht endliche Zahlen, Seiten außerhalb, falsche Drehung, Bild ohne
  Bilddaten, `formatVersion` 1e300/-1e300/1e18/1.5 ohne Absturz, zusätzliches Wurzelfeld mit der PDF als Base64),
  eigener Freitext mit `%PDF-`/`application/pdf` bleibt erhalten, Seitenangabe bei Fehlern, gleiche Lösungs-ID
  verdrängt keine vorhandene Lösung, gespeichert wird nur die kanonische Form, Drehungsabbildung, Ablage, Community
  „nicht verbunden“. `CommunityRulesTests`: Kurs- und Gruppen-Schlüssel (fest, ohne Klartext), Beitrittscodes,
  Sichtbarkeitsregeln (Modul, Lerngruppe, anonym, eigene), Filter (Hochschule, zurückgezogen, gesperrt, Sortierung,
  Dubletten), Optionen, Wochen-Gruppierung, `publishedAt` in der Ablage, Standardimplementierungen des Protokolls.
- App (`UniFlowTests/SolutionSharingTests`, AES-GCM aus CryptoKit, selbst erzeugte Test-PDF mit drei
  Seitengrößen und `/Rotate`): CryptoKit-SHA-256 = Kern-SHA-256, Export ohne PDF, zweites Gerät, andere PDF ohne
  Anzeige, Manipulation, Anzeige auf gedrehter Seite mit Pixelprobe, Vorschau weiß mit Tinte (auch über einer roten
  PDF-Seite), eigene Notizen byte-gleich nach Import und Einblenden, Zuordnung über den Editor mit eigener Leerseite
  vor PDF-Seite 1 und um 180 Grad gedrehter PDF-Seite 2 (Abbildung 90 → 180, eigenes Dokument byte-gleich), „Meine
  Notizen“ ausgeblendet schreibt nichts in den Store, unlesbarer Import mit passendem Fingerabdruck wird entfernt,
  Hinweis nur einmal je Sitzung, großflächiges PNG (20 000 × 20 000 Pixel, wenige Kilobyte) weist die ganze Lösung ab
  und eigene große Bilder werden verkleinert, Block-HKDF = RFC 5869 = CryptoKit, Texte des Dialogs.
- App (`UniFlowTests/CommunityCloudKitTests`, `CloudKitCommunityService` gegen ein nachgebildetes CloudKit im
  Speicher, kein echtes CloudKit): ohne Container nichts und kein Absturz, Upload enthält nur Paket und Kopfdaten
  (keine PDF-Bytes, keine Notizen im Klartext, keine Kurs-ID), Pseudonym bei anonym leer, Sichtbarkeitsregeln über
  mehrere Nutzer und Hochschulen (Kurs-Schlüssel, Lerngruppe, zurückgezogen, gesperrt, eigene), Laden = identisches
  Paket und Import über denselben Weg wie die Datei (eigene Notizen byte-gleich, andere PDF, zurückgezogen),
  Zurückziehen nur eigene (Paket beim Dienst weg), Melden, Sperrliste privat und ohne Netz aus dem Zwischenspeicher,
  Lerngruppen (Code nie beim Dienst, Beitritt auch klein/mit Bindestrich, andere Hochschule nicht, Verlassen),
  Fehlerfälle (kein iCloud-Konto, kein Netz, Kontingent, Serverfehler, CloudKit-Codes), Knopf nur mit Plus, Texte,
  Lehrwoche aus der Modulansicht.

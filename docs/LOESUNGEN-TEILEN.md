# Lösung teilen: Format, Ablauf, Sicherheit und Grenzen

Stand 25.10.2026, Zweig `wip/loesung-teilen` (Schritt S9 in `docs/IPAD-OHNE-PC.md`). Gilt für die native iPad-App.
Es gibt **keinen Server**: Lösungen werden als Datei weitergegeben (AirDrop, Dateien-App, „Öffnen in“) und
ausschließlich auf dem iPad geöffnet. Die Online-Community ist vorbereitet, aber nicht verbunden.

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
- Fehlende Bilder (nicht ladbar) werden gezählt und angezeigt; sie fehlen im Paket.
- Optionaler Anzeigename (leer = anonym, gemerkt für das nächste Mal).
- „Als Datei teilen“ öffnet das Teilen-Menü des Systems und merkt die Lösung unter „Meine geteilten Lösungen“.
- „In der Community veröffentlichen“ ist deaktiviert: „Community-Dienst noch nicht verbunden“.
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
  Dokuments (Lesezeichen, Notiz, Papierkorb). Zusätzliche Sicherung beim Erzeugen: Texte mit `%PDF-`, `JVBERi0`
  (Base64 von `%PDF-`) oder `application/pdf` werden abgewiesen.
- `AnnotationDocument` und `annotations.schema.json` sind **unverändert**; das Paket ist ein eigenes Format neben dem
  Notizmodell.

Prüfungen beim Öffnen (`SolutionPackage.decode`/`open`, dieselben Regeln schon beim Erzeugen): Formatkennung,
Version (sonst „bitte UniFlow aktualisieren“), Kopf genau in der Form von Version 1 (zusätzliche Felder abgewiesen),
UUID, Datum, Hex-Fingerabdruck, Salz/Nonce-Länge, angegebene Größe = Chiffratgröße, alle Zahlen endlich
(`1e999` wird abgewiesen), Grenzen (64 MB Datei, 48 MB Inhalt, 2 000 Seiten, 20 000 Objekte je Seite, 200 Bilder à
10 MB), Seiten (Art, PDF-Seite im Bereich, Größe, Drehung Vielfaches von 90), Bilder (PNG/JPEG nach den ersten Bytes),
Inhalt passt zum Kopf.

## 4. Ablauf beim Empfänger (lokal, ohne Server)

1. Datei öffnen: „Öffnen in UniFlow“/AirDrop (`CFBundleDocumentTypes` und `UTExportedTypeDeclarations` in
   `apps/apple/project.yml`, `.onOpenURL` in `UniFlowApp.swift`) oder im Editor „Mehr → Lösung importieren …“ bzw.
   „Ebenen → Lösung importieren …“ (`fileImporter`).
2. Der Kopf wird geprüft, das Paket **verschlüsselt wie empfangen** unter
   `Application Support/UniFlow/solutions/received/<id>.uniflowsolution` abgelegt, der Index
   (`solutions/index.json`) ordnet es dem Fingerabdruck zu (`SolutionLibrary`).
3. Öffnet der Nutzer die passende PDF, entschlüsselt die App die Lösung im Arbeitsspeicher mit den Bytes seiner
   eigenen Datei und prüft jede PDF-Seite (Seitenzahl, Größe, Drehung). Passt etwas nicht, erscheint die Ebene
   **gar nicht** (auch nicht teilweise) und es gibt eine klare Meldung.
4. Menü „Ebenen“: „Meine Notizen“ ein-/ausblenden (ausgeblendet = nur ansehen: Canvas ohne Eingabe, Palette weg,
   kein Rückgängig), je Lösung „Lösung von <Name oder Anonym> (<Datum>)“ mit Ein-/Ausblenden, „Vorschau ohne
   Original“ und „Entfernen“.
5. Anzeige: eigene, nicht bearbeitbare Schicht `PageInkView.foreignView` über der PDF und unter den eigenen Objekten
   und der Zeichenfläche (`PDFEditorController.applyForeign`, `ForeignLayerView`). Zuordnung über den PDF-Seitenindex.
   Hat der Empfänger die Seite anders gedreht als der Absender, bildet `SolutionGeometry.transform` die Anzeige um –
   die Objekte selbst werden nie umgerechnet. Zoom ist reine Anzeige. Eigene Leerseiten des Absenders gibt es beim
   Empfänger nicht; sie sind nur in der Vorschau zu sehen.
6. Eigene Notizen werden **nie** verändert: Es gibt keinen Schreibweg von der Lösung in `DocumentStore`, Journal oder
   Server (Test `testOwnNotesUnchangedAfterImportAndShowing`: serialisiertes eigenes Dokument vor/nach Import und
   Einblenden byte-gleich).

„Meine geteilten Lösungen“ (Menü „Teilen“): Kopien der selbst geteilten Pakete unter `solutions/shared/`, „Erneut
teilen“ und „Entfernen“. Ohne Dienst heißt Zurückziehen nur: die Kopie auf diesem iPad löschen. Bereits
weitergegebene Dateien kann UniFlow nicht zurückholen – das steht so im Blatt.

## 5. Sicherheit – und was sie nicht leistet

- **Verschlüsselung**: AES-256-GCM (CryptoKit, nur in der App, `Services/SolutionCrypto.swift`). Schlüssel per
  HKDF-SHA256 aus den **vollständigen Bytes der Original-PDF** mit zufälligem 32-Byte-Salz und Info
  `uniflow-solution/v1|<Lösungs-ID>`. Bewusst **nicht** aus dem Fingerabdruck: der steht im Klartext im Kopf, sonst
  könnte jeder mit dem Paket entschlüsseln (Test: mit dem Hash als Schlüsselmaterial lässt sich nichts öffnen).
- **Kopf als AAD**: alles außer dem Chiffrat ist authentifiziert. Wer Name, Datum, Fingerabdruck, Inhaltsangaben, Salz
  oder Nonce ändert, bekommt „lässt sich nicht öffnen“.
- **Was das bedeutet**: Lesen kann eine Lösung nur, wer genau diese PDF-Datei besitzt. Titel und Notizen stehen nicht
  im Klartext; im Klartext stehen Lösungs-ID, Datum, Anzeigename, Fingerabdruck und Seitenzahl.
- **Was es nicht leistet (ehrlich)**: Der Besitz der Datei beweist **keine Kursberechtigung**. Stud.IP-Dateien sind
  für alle Kursteilnehmer gleich und können weitergegeben werden; wer die PDF hat, kann die Lösung lesen. Das ersetzt
  **keine serverseitige Zugriffskontrolle**. Ein Fingerabdruck ist kein Besitznachweis, und eine leicht geänderte
  Fassung der PDF (neuer Upload) passt nicht mehr.
- Der Kern (`SolutionSHA256`) rechnet SHA-256 ohne CryptoKit (Linux); die App nimmt CryptoKit, beide Wege sind im
  Test gleich.

## 6. Community-Schnittstelle (vorbereitet, nicht verbunden)

`Solutions/CommunityService.swift`:

| Aufruf | Zweck |
|---|---|
| `publish(_ package)` | verschlüsseltes Paket veröffentlichen |
| `findMatching(fingerprint:)` | Lösungen zu einer PDF finden (nur Kopfdaten) |
| `download(solutionID:)` | Paket laden, geöffnet wird lokal mit der eigenen PDF |
| `withdraw(solutionID:)` | eigene Veröffentlichung zurückziehen |
| `report(solutionID:reason:note:)` | melden (fremdes Material, bewertete Abgabe, beleidigend, Spam, sonstiges) |

Einzige Umsetzung heute: `NotConnectedCommunityService` – jeder Aufruf wirft „Community-Dienst noch nicht
verbunden.“, es wird nichts gesendet und kein Erfolg vorgetäuscht. Der Dienst bekäme nur das verschlüsselte Paket,
nie Stud.IP-Cookies, -Sitzungen oder -Tokens.

## 7. Was für die Online-Community fehlt

1. **Entscheidung und Betrieb des Dienstes** (CloudKit mit Developer Program oder Supabase; kostenpflichtig, Inhaber).
2. **Echte Berechtigungsprüfung auf dem Dienst** – der Fingerabdruck reicht nicht. Optionen:
   - Mitwirkung der Hochschule: signierter Beleg der Kursmitgliedschaft (z. B. von Stud.IP ausgestellt, kurz gültig,
     an Kurs und Nutzer gebunden), den der Dienst prüft;
   - OAuth2 mit Stud.IP (Freigabe ZQS/elsa) und einem Scope, mit dem der Dienst die Kursmitgliedschaft selbst
     abfragen darf – ohne dass die App Tokens weiterreicht, die mehr erlauben;
   - Moderation: Meldungen prüfen, Sperren, Löschfristen, Kontakt für Lehrende.
3. **Konten** für Veröffentlichen, Zurückziehen und Melden (Mit Apple anmelden), Blockieren von Nutzern
   (App-Store-Richtlinie 1.2), Nutzungsbedingungen und Datenschutzerklärung.
4. **Klärung mit der Hochschule**: Teilen eigener Anmerkungen über fremden Folien innerhalb eines Kurses,
   Umgang mit bewerteten Abgaben (Prüfungsämter), siehe `docs/ANFRAGE-STUDIP-ZUGANG.md`.
5. **Neue Fassungen der PDF**: Zuordnung über Seiteninhalt statt nur über den Datei-Hash (S7).
6. Danach: `CommunityService` umsetzen, Knopf „In der Community veröffentlichen“ freischalten, Treffer im Menü
   „Ebenen“ anbieten, „Zurückziehen“ beim Dienst statt nur lokal.

## 8. Tests

- Kern (`UniFlowCoreTests/SolutionPackageTests`, mit einer nur für Tests gebauten HMAC-Verschlüsselung, damit Format,
  AAD und Prüfungen auch unter Linux laufen): SHA-256-Testvektoren, Objekte inkl. unbekannter Felder exakt gleich,
  kein `pkdrawing`/keine Wurzelfelder, mehrseitig mit Leerseite und Drehung, fehlende Bilder, keine PDF-Bytes/-Stücke/
  `%PDF`/`JVBER` in Datei und Klartext, zweites Gerät (zweiter Ordner) mit derselben PDF → identische Objekte, andere
  PDF/gefälschter Fingerabdruck → keine Entschlüsselung, manipulierte Pakete (Chiffrat, Tag, Kopf, Version, Größe,
  kaputtes JSON, unbekannte Objekttypen, nicht endliche Zahlen, Seiten außerhalb, falsche Drehung, Bild ohne
  Bilddaten), Drehungsabbildung, Ablage, Community „nicht verbunden“.
- App (`UniFlowTests/SolutionSharingTests`, AES-GCM aus CryptoKit, selbst erzeugte Test-PDF mit drei
  Seitengrößen und `/Rotate`): CryptoKit-SHA-256 = Kern-SHA-256, Export ohne PDF, zweites Gerät, andere PDF ohne
  Anzeige, Manipulation, Anzeige auf gedrehter Seite mit Pixelprobe, Vorschau weiß mit Tinte (auch über einer roten
  PDF-Seite), eigene Notizen byte-gleich nach Import und Einblenden, Texte des Dialogs.

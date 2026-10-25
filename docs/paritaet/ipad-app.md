<!-- Bestandsaufnahme native iPad-App (vor dem 1:1-Umbau), erstellt 25.10.2026 aus dem Quelltext (Stand develop). Teil von WEB-IPAD-PARITAET.md. -->
# Bestandsaufnahme native iPad-App „UniFlow“ (`apps/apple`)

Ich habe alle Swift-Dateien unter `apps/apple/UniFlow`, `apps/apple/UniFlowTests` und `apps/apple/Packages/UniFlowCore` (Quellen und Tests) gelesen, dazu `project.yml`, `README.md`, `UniFlow.storekit` und `Assets.xcassets`. Zum Vergleich habe ich `app/static/editor.js` (Web-Editor) und `.github/workflows/apple.yml` kurz angesehen. Nichts wurde verändert.

**Wichtigste Befunde**
- **Dokumentliste offline:** Die Bibliothek nutzt den Offline-Cache nicht. Ohne WLAN ist die Dokumentliste leer, obwohl die PDFs auf dem Gerät liegen.
- **Stud.IP-Dateien:** Direkt aus Stud.IP geladene Dateien lassen sich nur in QuickLook ansehen. Sie können nicht im Editor geöffnet oder beschrieben werden.
- **Web-Objekte nur Anzeige:** Text, Formen, Bilder und Haftnotizen aus dem Browser werden angezeigt, lassen sich auf dem iPad aber nicht auswählen, verschieben oder bearbeiten.
- **Rückgängig:** Es gilt nur für PencilKit-Striche, nicht für Leerseite, Drehen, Lesezeichen oder Text.
- **README veraltet:** Es behauptet, Text, Formen, Bilder und eingefügte Seiten würden auf dem iPad nicht angezeigt. Der Code zeigt sie inzwischen an.

---

## A) App-Struktur

### Projekt / Build (`apps/apple/project.yml`)
| Punkt | Wert | Zeile |
|---|---|---|
| Projektname | UniFlow, `bundleIdPrefix: de.uniflow` | 3–5 |
| Mindestversion | iOS 17.0 | 6–7 |
| Entwicklungssprache | `de` | 8 |
| Lokales Paket | `UniFlowCore` (Pfad `Packages/UniFlowCore`) | 9–11 |
| Swift / Versionen | Swift 5.0, `MARKETING_VERSION 0.2.0`, `CURRENT_PROJECT_VERSION 2` | 14–16 |
| App-Ziel | `PRODUCT_BUNDLE_IDENTIFIER de.uniflow.ai`, `TARGETED_DEVICE_FAMILY "1,2"` (iPhone und iPad) | 28–29 |
| AppIcon / Akzentfarbe | `AppIcon`, `AccentColor` | 30–31 |
| Info.plist (erzeugt) | `UniFlow/Info.plist`, Anzeigename UniFlow, Startbildschirm in `AccentColor`, mehrere Fenster erlaubt (`UIApplicationSupportsMultipleScenes: true`), iPad alle Ausrichtungen, iPhone nur Hochformat | 34–50 |
| Lokales Netz | `NSLocalNetworkUsageDescription` | 51 |
| ATS (nur Entwicklung) | `NSAllowsLocalNetworking: true`, `NSAllowsArbitraryLoads: true`. Kommentar: vor TestFlight entfernen | 52–55 |
| Testziel | `UniFlowTests` (`de.uniflow.ai.tests`), `UniFlow.storekit` als Ressource | 56–71 |
| Schema | Tests in Debug, StoreKit-Konfiguration `UniFlowTests/UniFlow.storekit` für Run | 72–86 |
| Paket | `Package.swift`: swift-tools 5.9, `.iOS(.v17)`, `.macOS(.v14)`, Target `UniFlowCore` und Testtarget `UniFlowCoreTests` | Package.swift 1–16 |
| CI | `.github/workflows/apple.yml`: Kern mit `swift test` unter Linux (`swift:6.0-jammy`), danach macOS-15-Job (Kern-Tests, `xcodegen generate`, App-Tests im iPad-Simulator), kein Signieren | – |

### Einstieg
- `UniFlow/UniFlowApp.swift:5-22`: `@main struct UniFlowApp`.
  - Legt zwei `@StateObject` an: `Session()` (:7) und `StudIPSync()` (:8).
  - `WindowGroup { RootView() }` mit `.environmentObject(session)`, `.environmentObject(studip)` und `.tint(Color("AccentColor"))` (:12-17).
  - Bei `scenePhase == .active` wird `studip.runIfDue()` aufgerufen: Stud.IP-Abgleich beim Öffnen, höchstens alle 30 Minuten (:18-20).
- Root-Logik in `UniFlowApp.swift:24-34`: `RootView` zeigt `MainView()`, wenn `session.api != nil`, sonst `ConnectView()` (:28-32).
  - `session.api` wird in `Session.init` gesetzt, wenn in UserDefaults `uniflow.serverURL` **und** im Schlüsselbund `uniflow.pin` vorhanden sind (`Services/Session.swift:13-18`).
  - Nach erfolgreichem `connect` wird `api` ebenfalls gesetzt (`Session.swift:38`).
  - Bei `disconnect()` wird `api = nil` gesetzt und der PIN gelöscht (`Session.swift:48-51`). Die URL bleibt erhalten.

### Navigation (`Views/MainView.swift:4-24`)
`TabView(selection:)` mit `@SceneStorage("uniflow.tab")`. Standard ist `"docs"`, die App startet also auf „Dokumente“, nicht auf dem ersten Tab (:6). Die Tabs in Reihenfolge:

| # | Tab-Titel | SF Symbol | Tag | Ansicht | Zeile |
|---|---|---|---|---|---|
| 1 | Übersicht | house | home | `DashboardView(api:)` | 10–11 |
| 2 | Dokumente | doc.richtext | docs | `LibraryView()` | 12–13 |
| 3 | Module | books.vertical | modules | `ModulesView(api:)` | 14–15 |
| 4 | Kalender | calendar | calendar | `CalendarView(api:)` | 16–17 |
| 5 | Tests | graduationcap | tests | `TestsView(api:)` | 18–19 |
| 6 | Einstellungen | gearshape | settings | `SettingsView(api:)` | 20–21 |

### Environment-Objekte und Dienste
| Objekt | Art | Datei:Zeile | Aufgabe |
|---|---|---|---|
| `Session` | `@MainActor ObservableObject`, Environment | Services/Session.swift:6-52 | Serververbindung; `api`, `lastError`, `connecting`; `connect`, `disconnect`, `savedURL` |
| `Keychain` | enum | Session.swift:55-76 | Generic Password `set`, `get`, `delete` (für `uniflow.pin`, `kSecAttrAccessibleAfterFirstUnlock`) |
| `StudIPSync` | `@MainActor ObservableObject`, Environment | Services/StudIPSync.swift:95-264 | Stud.IP direkt (siehe unten) |
| `APIClient` | final class, `@unchecked Sendable` | Services/APIClient.swift:12-87 | HTTP zum UniFlow-Server |
| `HTTPAnnotationTransport` | struct (`AnnotationTransport`) | APIClient.swift:90-112 | GET/PUT der Notizen inklusive 409 |
| `RemoteData` | `@MainActor ObservableObject`, je Ansicht | Services/RemoteData.swift:30-76 | Laden/Fehler/Offline je Pfad |
| `ResponseCache` | struct, `.shared` | RemoteData.swift:7-27 | letzte Antwort je Pfad auf Platte |
| `DocumentStore` | `@MainActor ObservableObject`, je Dokument | Services/DocumentStore.swift:83-404 | Dokument, Journal, Sync, Struktur-Aktionen |
| `InkProcessor` | actor | DocumentStore.swift:28-44 | Umrechnung PencilKit und JSON im Hintergrund |
| `SyncEngine` | actor (Paket) | UniFlowCore/SyncEngine.swift:76-517 | lokales Sichern, Upload, Konflikt-Merge |
| `LocalJournal` | class (Paket) | UniFlowCore/LocalJournal.swift:35-141 | Ablage je Dokument |
| `FileBlobStore` / `MemoryBlobStore` | Paket | UniFlowCore/BlobStore.swift:12-45 / 55-101 | atomare Dateiablage / Testspeicher |
| `PurchaseStore` | `@MainActor ObservableObject` (nur in SubscriptionView) | Purchases/PurchaseStore.swift:10-98 | StoreKit 2 (nur Testmodus) |
| `EditorBridge`, `ToolPickerHolder` | ObservableObject | Views/DocumentView.swift:10-19, 23-26 | SwiftUI ↔ UIKit-Editor; gemeinsame `PKToolPicker` und `UndoManager` |

### Kommunikation mit dem Server
- **Basis-URL:** Der Nutzer gibt sie in `ConnectView` ein. Vorbelegung `savedURL` mit Standardwert `"http://192.168.0.10:8765"` (`Session.swift:20`). Prüfung: Schema und Host müssen vorhanden sein (`Session.swift:27`). Gespeichert wird in UserDefaults `uniflow.serverURL` (`Session.swift:11,36`).
- **PIN:** Cookie-Header `Cookie: lernapp_pin=<PIN>` bei jeder Anfrage, wenn der PIN nicht leer ist (`APIClient.swift:33`). `httpShouldSetCookies = false`, Timeout 25 s, `waitsForConnectivity = false` (`APIClient.swift:20-24`). PIN im Schlüsselbund unter `uniflow.pin` (`Session.swift:15,37,50`).
- **Verbindungsprüfung:** `GET /api/settings`. Status 200 gilt als verbunden, 401 als „PIN ist falsch.“, 429 als „Zu viele falsche PIN-Eingaben. Bitte 10 Minuten warten.“, alles andere als Statusmeldung. Netzwerkfehler ergeben einen Hinweis auf `Start-iPad.cmd` (`Session.swift:33-45`).
- **Methoden:** `data()` (:41-45), `json<T>()` (:47-53, Decodable), `upload()` multipart (:56-77), `value()` als JSONValue roh (:80-86). Fehlertyp `APIError` mit Text „Server-Fehler <status>: <message>“ (:4-8).
- **Server-Modelle:** `LibraryResponse` (files, modules), `LibModule` (id, name, color), `LibFile` mit `id, name, title, kind, module_id, subject, doc_type, ai_title, sub_label, downloaded_at, has_notes, page_count, studip_folder` (`APIClient.swift:116-144`). `displayTitle = ai_title ?? title ?? name`; `isPDF` = Name endet auf `.pdf` **und** `downloaded_at != nil` (:142-143).

#### Alle Endpunkt-Strings (UniFlow-Server)
| Methode | Endpunkt | Datei:Zeile | Zweck |
|---|---|---|---|
| GET | `/api/settings` | Services/Session.swift:33 | Verbindungs- und PIN-Prüfung |
| GET | `/api/files//(documentID)/annotations` | Services/APIClient.swift:94 | Notizen laden (`version`, `data`) |
| PUT | `/api/files//(documentID)/annotations?base_version=/(baseVersion)` | Services/APIClient.swift:99 | Notizen speichern; 409 bedeutet Konflikt mit Serverstand |
| (Kommentar) | `POST /api/notebooks` | APIClient.swift:55 | Doku-Kommentar |
| (Kommentar) | `GET/PUT /api/files/{id}/annotations` | APIClient.swift:89 | Doku-Kommentar |
| GET | `/api/library` | Views/Views.swift:162 | Bibliothek (LibraryView) |
| POST multipart | `/api/notebooks` (Felder `kind=pdf`, `title`, Datei-Feld `upload`) | Views/Views.swift:178 | PDF-Import |
| GET | `/api/dashboard` | Views/DashboardView.swift:11 | Übersicht |
| GET | `/api/tasks/open` | Views/DashboardView.swift:12 | offene Aufgaben |
| GET | `/api/modules` | Views/ModulesView.swift:11 | Modulliste |
| GET | `/api/modules//(moduleID)` | Views/ModulesView.swift:65 | Moduldetail |
| GET | `/api/timetable/week?start=<yyyy-MM-dd>` | Views/CalendarView.swift:28 | Termine, Pakete, freie Zeit |
| GET | `/api/calendar?start=<…>&end=<…+6 Tage>` | Views/CalendarView.swift:30 | Lernpakete/Aufgaben |
| (Kommentar) | `/api/timetable/week`, `/api/calendar` | CalendarView.swift:5 | Doku-Kommentar |
| GET | `/api/tests` | Views/TestsView.swift:12 | Testliste |
| (Kommentar) | `/api/tests/{id}` | TestsView.swift:5 | Doku-Kommentar |
| GET | `/api/tests//(testID)` | Views/TestsView.swift:107 | Test öffnen (Server merkt sich den Beginn) |
| POST | `/api/tests//(testID)/submit` (Body `{answers:{nr:text}}`) | Views/TestsView.swift:122 | Abgabe und KI-Auswertung |
| GET | `/api/tests//(testID)` | Views/TestsView.swift:123 | Neu laden mit Musterlösungen |
| POST | `/api/tests/generate` (Body `{module_id}` oder `{subject}`) | Views/TestsView.swift:182 | Wiederholungstest erzeugen |
| GET | `/api/settings` (RemoteData) | Views/SettingsView.swift:17 | Einstellungen laden |
| GET | `/api/dashboard` (RemoteData) | Views/SettingsView.swift:18 | `last_sync` anzeigen |
| PUT | `/api/settings` (Body `{user_name}` oder `{hand}`) | Views/SettingsView.swift:96 | Einstellungen speichern |
| POST | `/api/sync` (Body `{}`) | Views/SettingsView.swift:106 | Stud.IP-Abgleich am PC starten |
| POST | `/api/related` (Body `{file_id, page}`) | Views/DocumentView.swift:237 | Skriptstellen-Vorschlag |
| (Kommentar) | `POST /api/related`, `/api/related` | DocumentView.swift:47, 52 | Doku-Kommentar |
| GET | `/api/library` | Views/DocumentView.swift:396 | CompanionPicker (zweites Dokument) |
| GET | `/api/files//(file.id)/content` | Services/DocumentStore.swift:130 | PDF-Inhalt (muss mit `%PDF` beginnen) |
| GET | `src` aus Bildobjekt (dynamisch, muss mit `/` beginnen) | Services/DocumentStore.swift:197, 201 | Bilder auf Seiten |
| GET | `src` aus Bildobjekt (dynamisch) | Services/DocumentStore.swift:337 | Bilder für den PDF-Export |

#### Stud.IP-Endpunkte (direkt, ohne UniFlow-Server)
| Endpunkt | Datei:Zeile |
|---|---|
| Basis `https://studip.uni-hannover.de` | Services/StudIPSync.swift:96 |
| `dispatch.php/login` (WebView-Anmeldeseite, Prüfung `/dispatch.php/login`) | Views/StudIPView.swift:127, 139 |
| `jsonapi.php/v1/users/me` | UniFlowCore/StudIPClient.swift:170 |
| `jsonapi.php/v1/users//(userID)/courses?page[limit]=100&include=start-semester` | StudIPClient.swift:177 |
| `jsonapi.php/v1/courses//(courseID)/folders?page[limit]=200` | StudIPClient.swift:195 |
| `jsonapi.php/v1/folders//(folderID)/file-refs?page[limit]=500` | StudIPClient.swift:210 |
| `jsonapi.php/v1/folders//(folderID)/folders?page[limit]=200` | StudIPClient.swift:219 |
| `jsonapi.php/v1/file-refs//(fileID)/content` | StudIPClient.swift:230 |
| `links.next` (Paginierung, nur eigener Host) | StudIPClient.swift:110-121, 162 |
| Accept-Header `application/vnd.api+json` | StudIPClient.swift:98 |
| Abgelaufene Anmeldung erkannt an `/dispatch.php/login`, `/idp/` oder Host `sso.*` | StudIPClient.swift:140-144 |

### Offline-Zwischenspeicher (`Services/RemoteData.swift`)
- `ResponseCache.shared` liegt unter `Application Support/UniFlow/cache/`. Dateiname: erste 16 Bytes von SHA256(Pfad) als Hex plus `.json` (:8-14). `store` schreibt atomar, Fehler werden ignoriert (:16-19). `load` liefert den Wert und das Änderungsdatum der Datei (:21-26).
- `RemoteData` hat die Zustände `.loading`, `.loaded(JSONValue, offlineSince: Date?)` und `.failed(String)` (:32-36).
  - `load()`: ohne API sofort `failed`.
  - Ist noch nichts geladen, wird zuerst der Cache gezeigt, **mit `offlineSince`**. Dadurch erscheint während jedes Ladens kurz das Offline-Banner.
  - Erfolg: im Cache speichern und `loaded(nil)`.
  - Fehler: Cache mit Datum zeigen, sonst `failed` (:61-75).
  - `reload(path:)` wechselt den Pfad, z. B. im Kalender (:53-59).
- Darstellung über `RemoteContent` (`Views/Components.swift:5-38`): Ladeanzeige, Fehler mit „Erneut versuchen“, orangefarbenes Banner „Offline – Stand <relativ>“, Leerzustand.
- RemoteData nutzen: Dashboard (Dashboard und Tasks), Module, Moduldetail, Kalender (Woche und Plan), Tests-Liste, Settings (Settings und Dashboard).
- **Kein Cache:** `LibraryView` (`api.json`, Views.swift:162), `CompanionPicker` (DocumentView.swift:396) und `TestRunView` (`api.value`, TestsView.swift:107).
- Hilfen: `JSONValue.s/n/i/list/items` (:80-86), `Row.rows` für eindeutige IDs (:89-101), `Fmt` für Datum, Minuten und relative Zeit mit `de_DE`-Formatierung (:103-134), `Color(hex:)` mit Akzentfarbe als Rückfall (:136-141).

### Lokale Ablage
**Pfade** (`AppPaths`, DocumentStore.swift:9-18):
- `Application Support/UniFlow/journal/` (Journal)
- `Application Support/UniFlow/pdf/<safe(id)>.pdf` (PDF-Cache)
- `Application Support/UniFlow/cache/` (ResponseCache)
- Stud.IP: `Application Support/StudIP/` mit `index.json`, `courses.json`, `files/<id>/<name>`, vom iCloud-Backup ausgenommen (StudIPSync.swift:118-120, 248-254)
- Export: `tmp/export/<Titel> – Notizen.pdf` (PDFExporter.swift:11-13)

**LocalJournal** (Paket, LocalJournal.swift:30-141): Ordner `docs/<safeName(id)>/` mit
- `meta.json` (`schema`, `rootMeta`, `metaRev`, `baseRootMeta`)
- `acks.json` (`serverVersion`, `metaAckedRev`, `acked`)
- `pages/<key>.json` (`key`, `localRev`, `page`)
- `base/<key>.json` (`key`, `page`)

`safeName` erlaubt `[A-Za-z0-9_-]` bis 100 Zeichen, sonst `~` plus Hex (:44-50). `load()` meldet beschädigte Dateien in `damaged`, statt sie still zu verwerfen (:72-107).

**FileBlobStore:** atomares Schreiben mit `.completeFileProtectionUntilFirstUserAuthentication` unter iOS (BlobStore.swift:25-33).

**DocumentStore** (DocumentStore.swift:83-404):
- PDF wird einmal geladen und dann für immer aus `AppPaths.pdf` genommen; keine Aktualisierung (:128-136).
- `SyncEngine` mit `HTTPAnnotationTransport` und Journal (:115-120).
- Schreibweg: `canvasChanged` merkt sich die Zeichnung, nach 0,25 s Ruhe folgt `processPending`, dann `InkProcessor.page` und `engine.updatePage` (:209-237).
- Bei Netzwechsel (`NWPathMonitor`) wird der Upload angestoßen. Beim Wechsel in den Hintergrund: Background-Task, `processPending` und `syncNow`. Beim Zurückkehren: `requestUpload` (:353-379).
- `pause()` bei `onDisappear` (:382-385); `deinit` ruft `engine.shutdown` (:387-393).
- `close()` (:396-403) wird **nirgends aufgerufen**.

**SyncEngine** (Paket, SyncEngine.swift:76-517):
- Jede Seitenänderung bekommt eine neue `localRev` und wird sofort ins Journal geschrieben (:189-199). Wurzelfelder (`pageOrder`, `bookmarks`) laufen separat über `metaRev` (:202-212).
- Upload nach 1,2 s (`uploadDelay`), höchstens einer gleichzeitig. Bestätigt werden genau die gesendeten Revisionen (:254-310).
- 409: Drei-Wege-Merge objektweise (`AnnotationMerge`), danach neuer Versuch; mehr als 5 Konflikte in Folge ergeben `conflictUnresolved` (:297-305, 361-424).
- Netzfehler: Wiederholung nach 2 s, Verdopplung bis 60 s (:270-278).
- Status: `loading`, `saved`, `pending`, `uploading`, `offline`, `localSaveFailed`, `conflictUnresolved` mit deutschen Labels (:28-56).
- Beim Öffnen: Journal laden, Serverstand holen, zusammenführen (:143-170).

**AnnotationMerge** (Paket, AnnotationMerge.swift):
- Merge-Regeln je Objekt (:3-10)
- `mergePage` (:24-46); `pkdrawing` bleibt nur, wenn es noch zu den Objekten passt
- `mergeObjects` (:54-89)
- `mergeRootMeta`/`mergePageOrder`: Serverreihenfolge, lokal neu hinzugefügte Seiten werden angehängt (:92-121)

**AnnotationDocument** (Paket, AnnotationDocument.swift):
- Format Version 2, `emptyRoot` mit `version 2, zoom 1.2, pages {}, pageOrder []` (:14-16)
- `ensurePDFPages` legt p1…pN an (:49-59)
- `pageKey(forPDFIndex:)`, `pdfIndex(forPageKey:)`, `insertedPageCount`, `removedPDFIndices` (:62-83)
- `StoredDrawing` (`pkdrawing`: `data`, `objectsSig`, `format "pkdrawing-v1"`, `strokeIds`) (:91-116)

**JSONValue** (Paket): eigener Parser und Writer, verlustfrei, `sortedKeys`, ganze Zahlen ohne `.0`, Codable, Literale (JSONValue.swift:9-378).

### Stud.IP-Direktimport (`Services/StudIPSync.swift`, `UniFlowCore/StudIPClient.swift`, `UniFlowCore/StudIPImport.swift`, `Views/StudIPView.swift`)
- **Anmeldung:**
  - Echte Uni-Seite in `WKWebView` mit `websiteDataStore = .default()`, ohne eingeschleuste Skripte (StudIPView.swift:155-178).
  - Nach jedem `didFinish` außerhalb von `/dispatch.php/login` werden die Cookies des Hosts gesammelt. `StudIPSync.sessionIsValid` prüft sie über `users/me` (StudIPView.swift:138-150, StudIPSync.swift:154-158).
- **Cookies:** JSON im Schlüsselbund, Service `de.uniflow.ai.studip`, Account `session-cookies`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (StudIPSync.swift:11-59).
- **Transport:** flüchtige `URLSession` ohne Cookie-Speicher. Cookies werden nach Domain und Ablauf gefiltert. Timeouts 30 s pro Anfrage und 600 s pro Ressource (StudIPSync.swift:62-90).
- **Client:**
  - nur lesend, 250 ms Pause zwischen Anfragen, höchstens 1500 Anfragen
  - Ordnerbaum ab `RootFolder`, höchstens 6 Ebenen
  - Kennungen werden aus Fehlermeldungen entfernt (`scrub`)
  - 401 oder Login-Weiterleitung ergeben `sessionExpired` (StudIPClient.swift:91-236)
- **Ablauf `run()`:**
  - Kurse laden, sortieren und in `courses.json` sichern
  - Vorauswahl beim ersten Mal: jüngstes Startsemester (`StudIPImport.defaultSelection`)
  - Dateilisten der gewählten Kurse holen, `StudIPImport.plan` erstellen (neu/geändert, unverändert, nicht herunterladbar, „in Stud.IP nicht mehr vorhanden“)
  - Herunterladen nach `files/<id>/<safeName>`; `index.json` wird nach jeder Datei gesichert
  - Zusammenfassung in UserDefaults (StudIPSync.swift:186-238)
- **Zustände (`Phase`):** `signedOut`, `idle`, `running(String)`, `needsLogin`, `failed(String)` (:98-104).
- **`runIfDue`:** nur wenn `idle` oder `failed` und der letzte Lauf mindestens 30 Minuten zurückliegt (:178-182).
- **`signOut`:** Schlüsselbund leeren und **alle** Daten von `WKWebsiteDataStore.default()` löschen (:162-167). `removeDownloads` löscht den Ordner `files` und den Index (:169-174).
- **UserDefaults:** `uniflow.studip.courses`, `uniflow.studip.lastRun`, `uniflow.studip.lastSummary` (:112, 121-123, 243-244).
- **Nutzung der Dateien:** Sie erscheinen nur in `StudIPView` und öffnen sich per QuickLook (StudIPView.swift:51, 68). Sie werden **nicht** in Bibliothek oder Editor übernommen und nicht zum Server hochgeladen.

### Weitere persistente Schlüssel
| Schlüssel | Art | Datei:Zeile |
|---|---|---|
| `uniflow.tab` | SceneStorage | MainView.swift:6 |
| `uniflow.pencilOnly` (Standard true) | AppStorage | SettingsView.swift:9, DocumentView.swift:66 |
| `uniflow.hand` (Standard "right") | UserDefaults/AppStorage | SettingsView.swift:33, 83; DocumentView.swift:67 |
| `uniflow.splitFraction` (Standard 0.42) | AppStorage | DocumentView.swift:68 |
| `uniflow.toolpicker` | `PKToolPicker.stateAutosaveName` | PDFEditorController.swift:168 |

---

## B) Ansichten

Legende Status: **funktional** = löst echte Aktion/Speicherung aus; **nur Anzeige** = liest Daten, keine Aktion; **Platzhalter/Testmodus** = ohne echte Wirkung; **TODO** = im Code als offen erkennbar.

### Einstieg und Grundgerüst
| Ansicht | Elemente und Aktionen | Datenquelle | Status | Datei:Zeile |
|---|---|---|---|---|
| UniFlowApp | WindowGroup, Environment-Objekte, Tint, scenePhase startet Stud.IP-`runIfDue` | lokal / Stud.IP | funktional | UniFlowApp.swift:5-22 |
| RootView | Schaltet zwischen MainView und ConnectView je nach `session.api` | lokal | funktional | UniFlowApp.swift:24-34 |
| MainView | TabView mit 6 Tabs (Übersicht, Dokumente, Module, Kalender, Tests, Einstellungen); Auswahl in SceneStorage | – | funktional | MainView.swift:4-24 |
| Preview „Verbinden“ | `ConnectView().environmentObject(Session())` | – | Vorschau | MainView.swift:26-28 |
| Preview „Karte“ | `Card(title: "Heute", systemImage: "sun.max")` mit `ProgressBar(0.4)` und Text „2 von 5 Aufgaben“ | – | Vorschau | MainView.swift:30-36 |

### Verbinden
| Ansicht | Elemente und Aktionen | Datenquelle | Status | Datei:Zeile |
|---|---|---|---|---|
| ConnectView (Form in NavigationStack, Titel „UniFlow“) | TextField Adresse (Platzhalter `http://192.168.0.10:8765`, URL-Tastatur, ohne Autokorrektur) | lokal | funktional | Views.swift:17-18 |
| | SecureField „PIN (6 Ziffern)“ (Zifferntastatur) | lokal | funktional | Views.swift:19 |
| | Section-Header „UniFlow-Server“; Footer-Hilfetext (Start-iPad.cmd, Beispiel `http://amo.fritz.box:8765`) | – | nur Anzeige | Views.swift:20-24 |
| | Fehlerzeile `session.lastError` (rot, Warndreieck) | lokal | nur Anzeige | Views.swift:25-27 |
| | Button „Verbinden“ (ProgressView während des Verbindens; deaktiviert bei leerer URL, leerem PIN oder laufender Verbindung) startet `session.connect` | API `GET /api/settings` | funktional | Views.swift:28-35 |
| | NavigationLink „Stud.IP ohne PC nutzen“ öffnet StudIPView; Footer-Hinweis | Stud.IP | funktional | Views.swift:36-40 |
| | `onAppear`: Adresse mit `session.savedURL` vorbelegen | UserDefaults | funktional | Views.swift:43 |

### Dokumente (Bibliothek)
| Ansicht | Elemente und Aktionen | Datenquelle | Status | Datei:Zeile |
|---|---|---|---|---|
| LibraryView (NavigationSplitView, 3 Spalten, `.prominentDetail`) | Seitenleiste: List-Auswahl „Alle Dokumente“ (tray.full) | API `/api/library` | funktional (Filter) | Views.swift:77-79 |
| | Section „Module“: je Modul ein Eintrag (book.closed) als Filter | API | funktional | Views.swift:80-84 |
| | Toolbar-Button „Trennen“ (destructive) ruft `session.disconnect()` | lokal | funktional | Views.swift:87 |
| | Dateiliste: Titel (2 Zeilen), Unterzeile `subject · sub_label`; Auswahl setzt `fileSelection`. Nur Dateien mit `isPDF` (.pdf und `downloaded_at`) | API | funktional | Views.swift:62-72, 89-94 |
| | `.searchable` „Dokumente suchen“ (Titel, Fach, Dateiname) | lokal gefiltert | funktional | Views.swift:95 |
| | Overlays: ProgressView; „Bibliothek nicht geladen“ (wifi.exclamationmark); `ContentUnavailableView.search` | – | nur Anzeige | Views.swift:96-102 |
| | Pull-to-refresh | API | funktional | Views.swift:103 |
| | Toolbar „PDF importieren“ (square.and.arrow.down) öffnet `fileImporter` (nur `.pdf`) | lokal → API `POST /api/notebooks` | funktional | Views.swift:105-110, 169-186 |
| | Alert „Import“ mit Button „OK“ (Erfolg „„<Titel>“ wurde importiert.“, Fehler „Die Datei ist keine PDF.“ oder „Import fehlgeschlagen: …“) | – | funktional | Views.swift:111-113 |
| | Detailbereich: Dokument-Tab-Leiste (falls Tabs offen) und `DocumentView(file:api:).id(f.id)`, sonst „Dokument wählen“ | – | funktional | Views.swift:114-123 |
| | Bei Dateiauswahl: als Tab anhängen und `columns = .detailOnly` | lokal (@State, nicht dauerhaft) | funktional | Views.swift:125-129 |
| Tab-Leiste (`tabStrip`) | Horizontales Scrollen; je Tab Titel (max. 220 pt), Antippen wählt den Tab, Button „xmark“ (Label „Tab schließen“) schließt ihn und wählt den linken Nachbarn; aktiver Tab hinterlegt | lokal | funktional | Views.swift:133-157 |

### Übersicht
| Ansicht | Elemente und Aktionen | Datenquelle | Status | Datei:Zeile |
|---|---|---|---|---|
| DashboardView (NavigationStack, Titel „Übersicht“, adaptives Grid ab 320 pt) | Pull-to-refresh und `.task` laden Dashboard und Tasks parallel | API `/api/dashboard`, `/api/tasks/open` (Cache) | funktional (Laden) | DashboardView.swift:10-45 |
| Karte „Heute“ / „Hallo <Name>“ | Datum, ProgressBar (`tasks_done/tasks_total`), „x von y Aufgaben · geplant …“, Terminliste (Punkt, Start, Titel, Raum), „Heute ist nichts geplant.“ | API | nur Anzeige | DashboardView.swift:47-65 |
| Karte „Lernfortschritt der Woche“ | ProgressBar, Tagesbalken (Farbe nach Status done/partial/missed, Höhe = Minuten/3), Hinweis „n Aufgabe(n) nachzuholen“ | API | nur Anzeige | DashboardView.swift:67-83, 144-151 |
| Karte „Anstehend“ | bis zu 6 Termine (Punkt, Titel, Datum), Leertext | API | nur Anzeige | DashboardView.swift:85-98 |
| Karte „Offene Aufgaben“ | bis zu 8 Aufgaben (Titel, Fach · Datum · Minuten), „Alles erledigt.“; **kein Abhaken** | API `/api/tasks/open` | nur Anzeige | DashboardView.swift:100-114 |
| Karte „Module“ | je Modul Punkt, Name, „n neu“, farbige ProgressBar; **keine Navigation** | API | nur Anzeige | DashboardView.swift:116-130 |
| Karte „Neue Dateien (n)“ | bis zu 6 Dateien (Titel, Fach); **nicht antippbar** | API | nur Anzeige | DashboardView.swift:132-142 |
| Fußzeile | „Letzter Stud.IP-Abgleich: <Datum> – <Meldung>“ | API | nur Anzeige | DashboardView.swift:28-31 |

### Module
| Ansicht | Elemente und Aktionen | Datenquelle | Status | Datei:Zeile |
|---|---|---|---|---|
| ModulesView (Titel „Module“) | Liste mit NavigationLink je Modul zum Moduldetail; Leerzustand „Noch keine Module“ | API `/api/modules` (Cache) | funktional | ModulesView.swift:14-26 |
| | `.searchable` „Module suchen“ (Name und Themen) | lokal | funktional | ModulesView.swift:20, 29-34 |
| | Pull-to-refresh | API | funktional | ModulesView.swift:24 |
| Modulzeile | Punkt, Name, Badge „n neu“, ProgressBar, Zähler Dateien/offene Aufgaben/Tests, „Nächster Termin: …“ | API | nur Anzeige | ModulesView.swift:36-56 |
| ModuleDetailView (Titel = Modulname) | ProgressBar, „Nächstes Lernpaket“, „Offene Aufgaben“ | API `/api/modules/{id}` (Cache) | nur Anzeige | ModulesView.swift:76-84 |
| | Je Woche eine Section (Header `label · topic`) mit Gruppen Vorlesungen, Übungen, Lösungen, Skripte, Klausuren, Sonstiges | API | nur Anzeige | ModulesView.swift:69-73, 85-97 |
| | Dateizeile als Button (Symbol pencil.and.outline bei Notizen, sonst doc.richtext; Titel; `sub_label · status`) öffnet das Dokument als Sheet; deaktiviert, wenn kein `.pdf` | API | funktional | ModulesView.swift:113-126 |
| | Sheet: NavigationStack mit `DocumentView`, Toolbar „Schließen“ | – | funktional | ModulesView.swift:103-110 |
| | Pull-to-refresh | API | funktional | ModulesView.swift:101 |
| `LibFile(json:)` | Baut LibFile aus der Modulzeile; `downloaded_at` fällt auf `"unbekannt"` zurück | – | Hilfscode | ModulesView.swift:129-137 |

### Kalender
| Ansicht | Elemente und Aktionen | Datenquelle | Status | Datei:Zeile |
|---|---|---|---|---|
| CalendarView (Titel = Monat Jahr) | Segment-Picker „Ansicht“: Tag / 3 Tage / Woche (Standard 3 Tage) | lokal | funktional | CalendarView.swift:7, 10, 49-50 |
| | Button chevron.left („Zurück“), Button „Heute“, Button chevron.right („Weiter“); Schritt 1/3/7 Tage, danach neu laden | API | funktional | CalendarView.swift:52-54, 80-84 |
| | Pull-to-refresh und `.task` laden ab dem ersten sichtbaren Tag 7 Tage (Woche und Plan) | API `/api/timetable/week`, `/api/calendar` (Cache) | funktional (Laden) | CalendarView.swift:71-72, 87-91 |
| | Tagesspalten nebeneinander im ScrollView | API | nur Anzeige | CalendarView.swift:57-66 |
| DayColumn | Kopf „EEE d.M.“ (heute in Akzentfarbe); Termine (Zeit, Titel, Raum, person.3; bei `status=="skip"` blass); Lernpakete (Zeit, Titel, geplante Minuten, book) mit Aufgaben (Haken bei „erledigt“, **nicht antippbar**); freie Zeit (gestrichelt); „Nichts geplant“ | API | nur Anzeige | CalendarView.swift:94-143 |

### Tests
| Ansicht | Elemente und Aktionen | Datenquelle | Status | Datei:Zeile |
|---|---|---|---|---|
| TestsView (Titel „KI-Tests“) | Sections „Offen“ und „Abgegeben“ (nach `submitted_at`); Leerzustand „Noch keine Tests“; Pull-to-refresh | API `/api/tests` (Cache) | funktional | TestsView.swift:15-34 |
| Testzeile | NavigationLink zu TestRunView; Titel, Fach, Anzahl Fragen, Dauer, Punkte | API | funktional | TestsView.swift:36-51 |
| TestRunView (Form, Titel = Testtitel) | Laden startet den Test auf dem Server; vorhandene `answers` werden übernommen | API `GET /api/tests/{id}` (kein Cache) | funktional | TestsView.swift:103-113 |
| | Je Frage eine Section „Frage n · x Punkte“; MC: Inline-Picker „Antwort“ mit „–“ und Optionen; sonst mehrzeiliges TextField („Rechenweg und Ergebnis“ bei `calc`, sonst „Antwort“); nach Abgabe gesperrt | lokal (@State) | funktional | TestsView.swift:130-152 |
| | Nach Abgabe: „Musterlösung: …“ (lightbulb) | API | nur Anzeige | TestsView.swift:146-148 |
| | Button „Abgeben und auswerten“ (ProgressView; deaktiviert bei laufender Abgabe oder ohne Antworten); Footer „Die KI bewertet …“ | API `POST /api/tests/{id}/submit`, danach GET | funktional | TestsView.swift:72-81, 115-127 |
| | Section „Ergebnis“: Punkte, ProgressBar, Zusammenfassung, Bewertung je Frage, „Nochmal anschauen: …“ | API | nur Anzeige | TestsView.swift:155-170 |
| | Button „Wiederholungstest erzeugen“ (nur bei `weak_topics`) | API `POST /api/tests/generate` | funktional | TestsView.swift:171, 177-187 |
| | Alert „Wiederholung“ mit „OK“ | – | funktional | TestsView.swift:91-93 |
| | Fehler „Test nicht geladen“; Laden „Lädt…“ | – | nur Anzeige | TestsView.swift:83-87 |
| | Kein Timer für `duration_min`; Zwischenstände werden nicht gespeichert | – | Lücke | – |

### Einstellungen
| Ansicht | Elemente und Aktionen | Datenquelle | Status | Datei:Zeile |
|---|---|---|---|---|
| SettingsView (Form, Titel „Einstellungen“) | Section „Profil“: TextField „Name“, speichert **nur bei Return** | API `PUT /api/settings {user_name}` | funktional | SettingsView.swift:24-26, 93-101 |
| | Section „Schreiben“: Picker „Schreibhand“ (Rechts/Links), speichert lokal und auf dem Server; legt die Seite des Skripts in der geteilten Ansicht fest | UserDefaults und API `PUT /api/settings {hand}` | funktional | SettingsView.swift:27-35 |
| | Toggle „Nur Apple Pencil schreibt (Finger scrollt)“; Footer zum Pencil-Doppeltippen | AppStorage | funktional | SettingsView.swift:36-39 |
| | Section „Server“: „Adresse“, Button „Verbindung trennen“ (destructive) | lokal | funktional | SettingsView.swift:40-43 |
| | Section „Synchronisierung“: „Letzter Stud.IP-Abgleich“ mit Meldung, „Dokumente mit ungesendeten Notizen“, „Ungesendete Seiten“ | API `/api/dashboard` und lokales Journal | nur Anzeige | SettingsView.swift:44-52 |
| | Button „Stud.IP jetzt abgleichen“ öffnet Bestätigungsdialog | – | funktional | SettingsView.swift:53 |
| | ConfirmationDialog „Stud.IP-Abgleich am PC starten?“ mit Button „Abgleichen“ und Erklärtext | API `POST /api/sync` | funktional | SettingsView.swift:87-89, 103-111 |
| | Section „Stud.IP“: NavigationLink „Stud.IP direkt auf dem iPad“ | Stud.IP | funktional | SettingsView.swift:55-59 |
| | Section „Tarif“: NavigationLink „Abo (Testmodus)“ öffnet SubscriptionView | StoreKit-Test | Testmodus | SettingsView.swift:60-62 |
| | Section „Diagnose“: App-Version, iPadOS, Größe der lokalen Notizen, Größe des Zwischenspeichers, „Beschädigte lokale Dateien“ (rot), sonst ProgressView | lokal | nur Anzeige | SettingsView.swift:63-73, 115-151 |
| | Statuszeile `saveMessage` („Gespeichert.“, „Nicht gespeichert: …“, „Abgleich läuft am PC (dauert einige Minuten).“, „Abgleich nicht gestartet: …“) | – | nur Anzeige | SettingsView.swift:74, 97-110 |
| | `.task`: Settings und Dashboard laden, Name und Hand übernehmen, Diagnose sammeln | API und lokal | funktional | SettingsView.swift:77-86 |
| SubscriptionView (Titel „Tarif“) | „Aktueller Tarif“; Footer „Testmodus: …“ | StoreKit | Testmodus | PurchaseStore.swift:106-110 |
| | Section „Tarife“: je Produkt Name, Beschreibung und Button mit Preis (`borderedProminent`, deaktiviert während eines Kaufs) | StoreKit (nur `UniFlow.storekit`) | Testmodus | PurchaseStore.swift:111-124 |
| | Button „Käufe wiederherstellen“ (`AppStore.sync`) | StoreKit | Testmodus | PurchaseStore.swift:125-127 |
| | Fehlerzeile (rot) | – | nur Anzeige | PurchaseStore.swift:128-130 |
| | `.task`: `loadProducts` und `refreshEntitlements` | StoreKit | funktional (Test) | PurchaseStore.swift:133-136 |

### Stud.IP
| Ansicht | Elemente und Aktionen | Datenquelle | Status | Datei:Zeile |
|---|---|---|---|---|
| StudIPView (List, Titel „Stud.IP“) | Statuszeile je Phase: „Nicht angemeldet“, „Anmeldung abgelaufen – bitte neu anmelden“ (orange), Fortschritt mit Text, Fehler (rot), „Zuletzt abgeglichen: …“ mit Zusammenfassung, „Angemeldet“ | lokal | nur Anzeige | StudIPView.swift:93-113 |
| | Button „Bei Stud.IP anmelden“ (person.badge.key), sichtbar bei signedOut/needsLogin, öffnet das Login-Sheet | – | funktional | StudIPView.swift:17-18 |
| | Button „Jetzt abgleichen“ (deaktiviert während des Laufs) | Stud.IP JSON:API | funktional | StudIPView.swift:20-21 |
| | Button „Abmelden“ (destructive, deaktiviert während des Laufs) öffnet Bestätigungsdialog | – | funktional | StudIPView.swift:22-23 |
| | Header „Stud.IP der Leibniz Universität Hannover“; Datenschutz-Footer | – | nur Anzeige | StudIPView.swift:25-29 |
| | Section „Kurse“: Toggle je Kurs (Titel, Semester) für die Auswahl, deaktiviert während des Laufs; Footer zur Vorauswahl | UserDefaults | funktional | StudIPView.swift:31-46 |
| | Je Kurs eine Section „<Kurs> (n)“: Button je Datei (Symbol, Name, Ordnerpfad, Größe) öffnet QuickLook | lokal (Application Support/StudIP) | funktional (nur Ansehen) | StudIPView.swift:48-65, 83-91 |
| | `.quickLookPreview($preview)` | lokal | funktional | StudIPView.swift:68 |
| | Sheet StudIPLoginView | – | funktional | StudIPView.swift:69-74 |
| | ConfirmationDialog „Von Stud.IP abmelden?“: „Abmelden“, „Abmelden und Dateien löschen“ (beide destructive); Hinweistext | lokal | funktional | StudIPView.swift:75-80 |
| StudIPLoginView (Titel „Stud.IP-Anmeldung“) | WKWebView auf `…/dispatch.php/login`; Toolbar „Abbrechen“; ProgressView während der Prüfung; automatische Erkennung der Sitzung | Stud.IP Web | funktional | StudIPView.swift:118-151 |
| StudIPWebView | UIViewRepresentable, WKWebView mit `.default()` Datenspeicher, Navigation-Delegate meldet `didFinish` | – | funktional | StudIPView.swift:155-178 |

### Dokumentansicht und Editor
| Ansicht | Elemente und Aktionen | Datenquelle | Status | Datei:Zeile |
|---|---|---|---|---|
| DocumentView (Titel = Dokumenttitel, inline) | Zustände: Fehler „Dokument nicht verfügbar“, Laden „Lädt…“, Editor | API und Journal | funktional | DocumentView.swift:100-126 |
| | Layout: optionale Seitenleiste (200 pt), Skript links (Rechtshänder) oder rechts, Hauptdokument, Trenngriff | lokal | funktional | DocumentView.swift:105-122 |
| | Toolbar links: „Seiten“ (sidebar.left, Seitenleiste ein/aus) | lokal | funktional | DocumentView.swift:256 |
| | Toolbar links: „Rückgängig“ (arrow.uturn.backward) | lokal (UndoManager) | funktional (nur Striche) | DocumentView.swift:257 |
| | Toolbar links: „Wiederholen“ (arrow.uturn.forward) | lokal | funktional (nur Striche) | DocumentView.swift:258 |
| | Toolbar rechts: StatusLabel (Sync-Status mit Symbol und Farbe) | SyncEngine | nur Anzeige | DocumentView.swift:261, 536-564 |
| | Toolbar rechts: „Suchen“ (magnifyingglass) öffnet SearchSheet | lokal (PDFKit) | funktional | DocumentView.swift:262 |
| | Toolbar rechts: „Geteilt“ / „Teilung beenden“ (rectangle.split.2x1) öffnet CompanionPicker bzw. schließt die Teilung | – | funktional | DocumentView.swift:263-265 |
| | Toolbar rechts: „Nur Stift“ / „Finger zeichnet“ (applepencil / hand.draw) schaltet `pencilOnly` | AppStorage | funktional | DocumentView.swift:266-268 |
| | Menü „Mehr“ (ellipsis.circle): „Lesezeichen setzen“ / „Lesezeichen entfernen“ (Titel fest „Seite n“) | Journal/Server (`bookmarks`) | funktional | DocumentView.swift:269-277 |
| | Untermenü „Leere Seite danach“ (doc.badge.plus): Leer, Liniert, Kariert, Gepunktet, Millimeter, Cornell | Journal/Server (`pageOrder`) | funktional | DocumentView.swift:278-282, 29-37 |
| | „Seite drehen“ (rotate.right, +90°) | Journal/Server | funktional | DocumentView.swift:283-285 |
| | „Text hinzufügen“ (textformat) öffnet einen Alert | Journal/Server | funktional | DocumentView.swift:286 |
| | „Als PDF mit Notizen teilen“ („Exportiert…“, deaktiviert während des Exports) öffnet das Teilen-Sheet | lokal (Bilder ggf. per API) | funktional | DocumentView.swift:288-295 |
| | „Dokumentinformation“ (info.circle) öffnet InfoSheet | lokal | funktional | DocumentView.swift:296 |
| | „Vollbild“ blendet nur die Navigationsleiste aus; Overlay-Button „Vollbild beenden“ | lokal | funktional | DocumentView.swift:297, 129-136 |
| | Seiteninfo unten (Kapsel): „Seite x / n“, Button „<Zoom> %“ (Hinweis „Seite einpassen“) passt die Seite ein, Hinweistext `store.notice` | lokal | funktional | DocumentView.swift:302-317 |
| | Banner „Passende Skriptstelle“ oben (nur Übungs-/Lösungs-/Klausurdateien, nach 2,5 s Ruhe, einmal pro Seite, nur ohne Teilung): Titel · Seite, Button „Daneben öffnen“, Button „xmark“ („Für diese Seite ausblenden“), Tooltip „Gemeinsame Begriffe“ | API `POST /api/related` | funktional | DocumentView.swift:93-98, 200-251 |
| | Trenngriff: Ziehen ändert die Breite der Teilung (20–65 %), wird gespeichert | AppStorage | funktional | DocumentView.swift:184-197 |
| | Alert „Text hinzufügen“: TextField „Text“, „Hinzufügen“, „Abbrechen“; Hinweis „Erscheint oben links … im Browser bearbeitbar“ | – | funktional | DocumentView.swift:145-153 |
| | Alert „Hinweis“ (Exportfehler) mit „OK“ | – | funktional | DocumentView.swift:154-156 |
| | Sheets: SearchSheet, InfoSheet, CompanionPicker, ActivityView | – | funktional | DocumentView.swift:137-144 |
| | `.task` lädt den Store und plant den Vorschlag; `onDisappear` bricht den Vorschlag ab und ruft `store.pause()` | – | funktional | DocumentView.swift:157-165 |
| CompanionView (zweites Dokument) | Kopfzeile: Titel, StatusLabel, „S. n“, Button xmark.circle.fill („Schließen“); eigener PDFEditor mit gemeinsamer Werkzeugpalette und gemeinsamem Undo; springt zur vorgeschlagenen PDF-Seite | API und Journal (eigener DocumentStore) | funktional | DocumentView.swift:322-364 |
| CompanionPicker (Titel „Daneben öffnen“) | Liste der Bibliotheks-PDFs (gleiches Modul zuerst), Antippen wählt und schließt; `.searchable` „Skript suchen“; Toolbar „Abbrechen“; Fehler „Nicht geladen“ | API `/api/library` (kein Cache) | funktional | DocumentView.swift:367-410 |
| PageSidebar | Section „Lesezeichen“ (Buttons springen zur Seite, max. 180 pt hoch); darunter ThumbnailStrip | lokal | funktional | DocumentView.swift:413-437 |
| ThumbnailStrip | `PDFThumbnailView` vertikal, 140×190; Antippen springt (Standardverhalten von PDFKit); zeigt **keine Handschrift und keine Vorlagen** | lokal | funktional | DocumentView.swift:439-454 |
| SearchSheet (Titel „Suchen“) | `.searchable` „Im PDF suchen“ (immer sichtbar), Ergebnisliste „Seite n“ mit Textausschnitt; Antippen markiert, springt und schließt; Leerzustand; Toolbar „Fertig“ | lokal (PDFKit `findString`, ab 2 Zeichen, höchstens 200 Treffer) | funktional | DocumentView.swift:456-485, DocumentStore.swift:318-328 |
| InfoSheet (Titel „Dokumentinformation“) | Section Dokument (Titel, Datei, Veranstaltung, Stud.IP-Ordner); Section Seiten (Angezeigt, Im PDF, Eingefügt (Browser/iPad), Im Browser entfernt, Lesezeichen); Section Speichern (Status, Ungesendete Seiten, Serverversion); Toolbar „Fertig“ | lokal | nur Anzeige | DocumentView.swift:487-525, DocumentStore.swift:342-349 |
| ActivityView | `UIActivityViewController` mit der exportierten PDF | lokal | funktional | DocumentView.swift:528-534 |
| StatusLabel | Symbole: saved checkmark.icloud; uploading/loading arrow.triangle.2.circlepath.icloud; pending internaldrive; offline icloud.slash; Fehler/Konflikt exclamationmark.triangle. Farben: Fehler rot, offline orange, sonst sekundär | SyncEngine | nur Anzeige | DocumentView.swift:536-564 |
| PDFEditorView | UIViewControllerRepresentable für `PDFEditorController`; verbindet Zoom und Seite mit der Bridge; baut die Anzeige nur bei neuer `layoutVersion` neu | – | funktional | DocumentView.swift:566-596 |

### Gemeinsame Bausteine (`Views/Components.swift`)
| Baustein | Elemente | Status | Zeile |
|---|---|---|---|
| RemoteContent | Laden „Lädt…“; Fehler „Nicht geladen“ mit Button „Erneut versuchen“ (`borderedProminent`); Offline-Banner; Leerzustand (tray) | funktional | 5-38 |
| Card | optionaler Titel mit Symbol (headline), Padding 16, Hintergrund `secondarySystemGroupedBackground`, Eckenradius 16 | nur Anzeige | 41-57 |
| ProgressBar | ProgressView mit Tint und Prozentangabe | nur Anzeige | 60-70 |
| ModuleDot | Kreis 10×10 in Modulfarbe | nur Anzeige | 72-75 |

---

## C) PDF-Editor

### Unterstützte Funktionen
| Funktion | Umsetzung | Datei:Zeile |
|---|---|---|
| PDF-Anzeige | `PDFView`, `.singlePageContinuous`, vertikal, `usePageViewController(false)`, Seitenschatten, Hintergrund `secondarySystemBackground` | PDFEditorController.swift:148-160 |
| Markup-Modus | `isInMarkupMode = true`: Overlays bekommen die Stifteingabe, **keine Textauswahl im PDF** | PDFEditorController.swift:163 |
| PencilKit je Seite | `PDFPageOverlayViewProvider` liefert eine `PageInkView` je Seite: `content` mit `PageObjectsView` (unten) und `PKCanvasView` (oben). Die Canvas scrollt und zoomt nie selbst; Seitenpunkte werden über eine Transformation skaliert | PDFEditorController.swift:15-69, 280-297 |
| Wiederverwendung von Overlays | höchstens 6 geparkte Overlays (`parkedLimit`), Generation pro Seitenaufbau | PDFEditorController.swift:90-92, 299-314 |
| Werkzeugpalette | Systemeigene `PKToolPicker`, an einem unsichtbaren Anker (`ToolPickerAnchor`) befestigt, damit sie beim Scrollen bleibt. Zustand gespeichert unter `uniflow.toolpicker`. Jede Canvas beobachtet die Palette. Die App schränkt die Werkzeuge nicht ein; es gibt das volle iPadOS-Angebot (Stift, Marker, Bleistift, weitere iOS-17-Tinten, Radierer, Lasso, Lineal, Farben) | PDFEditorController.swift:6-10, 166-170, 316-322 |
| Eine Palette für die Teilung | `ToolPickerHolder` teilt Palette und Undo. Nur das Hauptdokument zeigt die Palette (`ownsToolPicker`) | DocumentView.swift:23-26, 168-182; PDFEditorController.swift:82-89 |
| Stift oder Finger | `drawingPolicy` `.pencilOnly` oder `.anyInput`. Scroll- und Pinch-Gesten nur mit direkten Berührungen; im Finger-Zeichenmodus scrollt man mit 2 Fingern; `delaysContentTouches = false` | PDFEditorController.swift:104-110, 235-248 |
| Zoom | Einmal einpassen (`autoScales` nur am Anfang), Grenzen 0,5× bis 6× der Einpassung (`ZoomPolicy`). Nach Größenänderung bleibt ein Nutzer-Zoom relativ erhalten. Prozentanzeige relativ zur Einpassung; Antippen passt wieder ein. Zoomen nur per Pinch, **keine +/−-Buttons** | PDFEditorController.swift:207-232, 408-412; Geometry.swift:41-65; DocumentView.swift:306 |
| Seitenaufbau aus `pageOrder` | `DisplayLayout.build`: PDF-Seiten (Index 1-basiert, Kopie mit zusätzlicher Drehung), Leerseiten mit Größe `w`/`h` (Standard 595×842), Asset-Seiten als leere Seite mit Platzhaltertext. Im Browser entfernte Seiten fehlen, doppelte Schlüssel werden übersprungen. Neuaufbau nur bei geänderter Struktur-Signatur; Position und Zoom bleiben über den Seitenschlüssel erhalten | DisplayLayout.swift:10-63; DocumentStore.swift:158-173; PDFEditorController.swift:253-276 |
| Asset-Seiten aus dem Web | nur Platzhalter „Eingefügte Seite aus dem Browser – Inhalt nur dort sichtbar. Notizen hier werden gespeichert.“ | PDFEditorController.swift:336 |
| Web-Objekte anzeigen | `PageObjectsView` (ohne Eingabe): Formen (rect, ellipse, triangle, polygon, arrow mit Spitze, sonst Linienzug) als `CAShapeLayer`; Text als UILabel (Schriftart, Größe, fett, kursiv, unterstrichen, Ausrichtung, Zeilenhöhe, Hintergrund `bg`, damit auch Haftnotizen); Bilder als UIImageView (per API nachgeladen); Transformation verschieben → drehen → skalieren wie bei Konva; Deckkraft | PageObjects.swift:7-170, 174-284; PDFEditorController.swift:335-346; DocumentStore.swift:196-205 |
| Seitenvorlagen | blank, lined (ab y=60, Abstand 24), grid (14,17), dotted (14,17), mm (2,835), cornell (Linien wie lined, Rand x=150, Fußbereich H−150); Farbe `UIColor(0.85, 0.87, 0.91)` | PageObjects.swift:8, 102-131 |
| Striche umrechnen | `StrokeConverter`: Gespeicherte PencilKit-Zeichnung (`pkdrawing`) wird bevorzugt, wenn ihre Signatur passt; sonst Neuaufbau aus den Objekten. Stabile IDs über Erstellzeit, Punktzahl und Tintenart. Lasso-Verschieben und Pixel-Radierer behalten die ID; geteilte Striche werden in sichtbare Teile zerlegt. Werkzeuge pen, pencil, marker; Breite je Punkt (`widths`), Farbe, Deckkraft; Marker-Deckkraft fest 0,35; neue IDs `pk` plus 12 Hex-Zeichen | StrokeConverter.swift:15-247 |
| Speichern | Entprellung 0,25 s, Umrechnung im Actor, Journal, Upload nach 1,2 s, Merge bei 409. Laufender Strich wird nie unterbrochen (`isDrawing`, `deferredReload`); Striche vor dem Laden bleiben erhalten | DocumentStore.swift:209-237; PDFEditorController.swift:350-391 |
| Änderungen von außen | `onRemoteChange` → `onPagesChanged(keys)` → betroffene Overlays neu laden | DocumentStore.swift:239-242; PDFEditorController.swift:182, 362-367 |
| Lesezeichen | Feld `bookmarks` `{key, title}` wie im Web; umschalten im Menü; Liste in der Seitenleiste springt zur Seite | DocumentStore.swift:161-164, 256-268; DocumentView.swift:270-277, 419-428 |
| Leerseiten | `addBlankPage(afterKey:template:)`: Schlüssel `b` plus 11 Hex-Zeichen, Größe der aktuellen Seite (sonst 595×842), Eintrag in `pageOrder` nach der aktuellen Seite | DocumentStore.swift:271-285 |
| Drehen | `rotatePage`: `pageOrder[i].rotation` um 90° erhöhen (normalisiert); Notizen behalten ihre Koordinaten | DocumentStore.swift:288-296 |
| Text hinzufügen | `addText`: Objekt `type text` an x=40, y=40 + (Anzahl % 10)·30, Arial 14, `#1d2130`, Breite 220, `source "ipad"`; **auf dem iPad danach nicht bearbeitbar oder verschiebbar** | DocumentStore.swift:299-314 |
| Suche | PDFKit `findString` (ohne Groß-/Kleinschreibung und Akzente), höchstens 200 Treffer, Ausschnitt 160 Zeichen; Treffer markieren und anspringen | DocumentStore.swift:318-328; PDFEditorController.swift:400-403 |
| Miniaturen | `PDFThumbnailView` (nur PDF-Inhalt, ohne Overlays) | DocumentView.swift:439-454 |
| Export | `PDFExporter`: Seiten in `pageOrder`-Reihenfolge, PDF-Seite (Vektor), Vorlage, Text/Formen/Bilder (Vektor bzw. Bild), Handschrift **als Rasterbild** (Faktor 3, immer helles Erscheinungsbild); Dateiname bereinigt (max. 80 Zeichen) plus „ – Notizen.pdf“; Bilder werden vorher geladen; Teilen über `UIActivityViewController` | PDFExporter.swift:7-72; DocumentStore.swift:330-340 |
| Import | PDF über `fileImporter` → `POST /api/notebooks` (Bibliothek, nicht im Editor) | Views.swift:106-110, 169-186 |
| Dokument-Tabs | in LibraryView, nur im Speicher (`@State openTabs`). Wegen `.id(f.id)` entsteht bei jedem Wechsel eine neue DocumentView mit neuem DocumentStore; Zoom und Scrollposition gehen verloren, Daten kommen aus dem lokalen Cache bzw. Journal | Views.swift:56, 116-118, 125-157 |
| Geteilte Ansicht | zweites Dokument über den Picker oder den Skript-Vorschlag (`/api/related`, springt per `initialPDFPage` zur passenden Anzeige-Seite); Seite links oder rechts nach Schreibhand; Breite ziehbar; gemeinsame Palette und gemeinsames Undo; beim Verschwinden werden die Undo-Einträge des Begleitdokuments entfernt | DocumentView.swift:44-59, 111-119, 176-251, 322-410; PDFEditorController.swift:185-205 |
| Undo/Redo | `UndoManager` je Dokument (bzw. gemeinsam in der Teilung), Toolbar-Buttons; wirkt **nur auf PencilKit-Striche** | PDFEditorController.swift:89, 112, 405-406; DocumentView.swift:16-17, 257-258 |
| Vollbild | blendet die Navigationsleiste aus; Tab-Leiste und Dokument-Tabs bleiben sichtbar | DocumentView.swift:129-136 |
| Dokumentinformation | siehe InfoSheet | DocumentView.swift:487-525 |
| Hintergrund, Netz, Neustart | Background-Task beim Verlassen, `NWPathMonitor`, Hinweise „n ungesendete Seite(n) wiederhergestellt.“ bzw. „n lokale Datei(en) beschädigt …“ | DocumentStore.swift:146-150, 353-379 |
| Nicht genutzt | `PDFEditorController.showToolPicker(_:)` (PDFEditorController.swift:414-418), `DocumentStore.close()` (DocumentStore.swift:396-403), `DocumentStore.pageKey(forPageIndex:)` (DocumentStore.swift:177) | – |

### Funktionen des Web-Editors, die nativ fehlen
Abgeleitet aus `app/static/editor.js`, Zeilen 190–237 (Toolbar) und 825–942 (Menüs):

**Werkzeuge**
- **Lasso über Web-Objekte:** Das PencilKit-Lasso erfasst nur Striche. Text, Formen, Bilder und Haftnotizen sind nativ nicht auswählbar, verschiebbar, skalierbar oder löschbar (`PageObjectsView.isUserInteractionEnabled = false`, PageObjects.swift:181).
- **Text-Werkzeug:** Platzieren per Tippen, Bearbeiten bestehender Textboxen, Formatieren (Schrift, Größe, fett, kursiv, unterstrichen, Ausrichtung, Hintergrund). Nativ gibt es nur „Text hinzufügen“ an fester Position.
- **Formen-Werkzeug:** rect, ellipse, triangle, polygon, arrow. Nativ werden Formen nur angezeigt.
- **Bild einfügen:** fehlt.
- **Haftnotiz anlegen:** fehlt. Vorhandene Notizen werden als Text mit Hintergrund angezeigt.
- **„PDF-Text markieren (für KI)“:** fehlt. Textauswahl ist nativ ganz gesperrt.
- **Hand-Werkzeug:** nicht nötig, Finger scrollen.

**Werkzeugtypen**
- Der Web-Stiftyp „fountain“ wird nativ als „pen“ gezeichnet.
- Die PencilKit-Tinten monoline, fountainPen, watercolor und crayon werden beim Speichern als „pen“ ins Web übertragen (StrokeConverter.swift:179-184).

**Seitenleiste und Panels**
- **KI-Tutor** mit den Modi Markiertes erklären, Einfach erklären, Seite zusammenfassen, Fachbegriffe definieren, Aufgabe schrittweise lösen, Nur Hinweise geben, Meine Lösung prüfen, Ähnliche Aufgabe erstellen, Karteikarten erstellen, Quizfragen erstellen: fehlt.
- **Gliederung** (eigene Einträge und PDF-Outline): fehlt. Das Feld `outline` bleibt im Modell erhalten.
- **Aufnahmen** (Audio aufnehmen und anzeigen): fehlt.
- **Miniaturen ziehen** (Seiten umsortieren): fehlt.

**Zubehör**
- **Lineal (Web):** fehlt. PencilKit hat ein eigenes Lineal in der Palette, die App bindet es nicht gesondert ein; am Gerät nicht geprüft.
- **Zeitmesser:** fehlt.
- **Zoom-Ansicht (Zoomfenster):** fehlt.
- **Werkzeugleiste anpassen:** fehlt.

**Seitenmenü**
- vorhanden: Favoriten (= Lesezeichen) und Seite drehen
- fehlt: Seite kopieren/duplizieren, Seite zur Gliederung hinzufügen, Vorlage wechseln, Gehe zu Seite, Seite leeren, Seite in den Papierkorb legen, Papierkorb wiederherstellen und leeren

**Seite hinzufügen**
- vorhanden: nur „nach dieser Seite“
- fehlt: „Vor dieser“ und „Letzte Seite“, Bild-Seite, PDF-Seiten importieren, aktuelle Seite duplizieren

**Export**
- vorhanden: nur das ganze Dokument über das Teilen-Sheet (Drucken bietet ggf. das System an)
- fehlt: „Diese Seite exportieren“, „Ausgewählte Seiten…“, eigener „Drucken“-Befehl

**Seiteninfo**
- fehlt: Seitenzahl eingeben, Vor/Zurück-Buttons, Zoom +/−; nativ nur Pinch und Einpassen

**Einstellungen**
- vorhanden: Eingabe Stift/Finger
- fehlt: Scrollrichtung, Seitenleiste links/rechts, Einzelseite/Fortlaufend; nativ fest vertikal fortlaufend, Seitenleiste links

---

## D) Visuelles Design

**Kein eigenes Designsystem.** Die App nutzt überwiegend SwiftUI- und UIKit-Standards (Form, List, NavigationSplitView, TabView, ContentUnavailableView, `.borderedProminent`, Materialien, SF Symbols). Eigene Schriften gibt es nicht; nur Systemstile (`.headline`, `.subheadline`, `.callout`, `.caption`, `.caption2`, `.monospacedDigit()`, `.bold()`).

**Eigene Farben und Stile**
| Element | Wert | Fundstelle |
|---|---|---|
| AccentColor hell | sRGB 0.310 / 0.357 / 0.835 (≈ `#4F5BD5`, Blau-Violett) | Assets.xcassets/AccentColor.colorset/Contents.json |
| AccentColor dunkel | sRGB 0.482 / 0.525 / 0.941 (≈ `#7B86F0`) | ebenda |
| Akzent global | `.tint(Color("AccentColor"))`, `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`, Startbildschirmfarbe | UniFlowApp.swift:16; project.yml:31, 40-41 |
| Modulfarben | `Color(hex:)` / `UIColor(hex:)` aus `#rrggbb` vom Server, Rückfall Akzentfarbe | RemoteData.swift:136-141; StrokeConverter.swift:249-255 |
| Vorlagenlinien | `UIColor(red: 0.85, green: 0.87, blue: 0.91)` (≈ `#D9DEE8`) | PageObjects.swift:8 |
| Standard-Textfarbe Objekte | `#1d2130` | PageObjects.swift:84; DocumentStore.swift:307 |
| Card | `secondarySystemGroupedBackground`, `RoundedRectangle(cornerRadius: 16, style: .continuous)`, Padding 16 (Kommentar: „UniFlow-Stil … violetter Akzent“) | Components.swift:40-57 |
| ProgressBar | `ProgressView` mit Tint (Standard Akzent oder Modulfarbe) und Prozent in caption/monospacedDigit, sekundär | Components.swift:60-70 |
| ModuleDot | Kreis 10×10 | Components.swift:72-75 |
| Offline-Banner | `.orange` Text, Hintergrund `.orange.opacity(0.1)` | Components.swift:25-29 |
| Wochenbalken | done `.green`, partial `.orange`, missed `.red`, sonst `.accentColor.opacity(0.35)`; Eckenradius 4, Breite 22 | DashboardView.swift:75-76, 144-151 |
| Hintergründe | `systemGroupedBackground` (Dashboard, Kalender), `secondarySystemBackground` (Editor, Seitenleiste, Miniaturen) | DashboardView.swift:34; CalendarView.swift:69; PDFEditorController.swift:142, 160; DocumentView.swift:435, 446 |
| Dokument-Tab | aktiv `Color.accentColor.opacity(0.18)`, sonst `Color.secondary.opacity(0.08)`, Kapsel; Leiste `.bar` | Views.swift:144, 150 |
| Modul-Badge „neu“ | `.tint.opacity(0.15)` Kapsel | ModulesView.swift:42 |
| Kalendereintrag | farbiger Balken 4 pt (Eckenradius 2), Hintergrund `Color(hex).opacity(0.12)`, Eckenradius 10 continuous; freie Zeit gestrichelt (`dash [3]`, `.secondary.opacity(0.4)`, Eckenradius 8) | CalendarView.swift:122, 130-142 |
| Seiteninfo / Vorschlagsbanner | `.regularMaterial` als Kapsel bzw. `RoundedRectangle(cornerRadius: 12)` | DocumentView.swift:216, 315 |
| Trenngriff | `separator` 1 pt, Kapsel `secondary.opacity(0.5)` 5×44 | DocumentView.swift:185-189 |
| Status- und Fehlerfarben | `.red` (Fehler), `.orange` (offline / abgelaufen), `.secondary` | DocumentView.swift:557-563; StudIPView.swift:98, 102; Views.swift:26; SettingsView.swift:69 |
| Text in Objekten | Schriftart aus JSON (`fontFamily`, Standard „Arial“) über `UIFont(name:)` | PageObjects.swift:68-88 |
| App-Icon | einzelnes `AppIcon-1024.png` | AppIcon.appiconset |

---

## E) Tests

### App-Tests (`apps/apple/UniFlowTests`, XCTest, `@testable import UniFlow`)
| Datei | Klasse | Testfunktionen |
|---|---|---|
| EditorFeatureTests.swift | `EditorFeatureTests` | `testLayoutFollowsWebPageOrder`, `testLayoutWithoutPageOrderUsesAllPDFPages`, `testShapeAndTextGeometry`, `testTemplateLinesMatchWebSpacing`, `testObjectsViewShowsTemplateAndShapes` (@MainActor), `testExportContainsPagesAndInk`; Hilfen `makePDF`, `brightness` |
| PDFLayoutTests.swift | `RecordingOverlayProvider` (Hilfe), `PDFLayoutTests` | `testPageGeometryFromRealPages`, `testOverlayCanvasUsesPagePoints`, `testPageKeyMappingWithInsertedWebPage`, `testPDFViewRequestsOverlaysForVisiblePages` (@MainActor) |
| PurchaseTests.swift | `PurchaseTests` | `testPlusPurchaseAndRestoreInTestSession` (@MainActor, SKTestSession; prüft trotz Namen kein Wiederherstellen), `testPlanMapping` |
| StrokeConverterTests.swift | `StrokeConverterTests` | `testWebStrokesSurviveUnchanged`, `testNewStrokeGetsNewIDOldKeepTheirs`, `testReopenFromStoredDrawingKeepsIDs`, `testEraseRemovesOnlyThatStroke`, `testLassoMoveKeepsIDAndMovesPoints`, `testPixelEraserSplitsIntoVisibleParts`, `testThousandStrokesProcessQuickly`, `testColorRoundTrip` |
| SupportTests.swift | `SupportTests` | `testResponseCacheRoundTrip`, `testRowsGetUniqueIDs`, `testFormatting`, `testPDFPageMapsToDisplayIndex` |
| UniFlow.storekit | – | StoreKit-Testkonfiguration: Abo-Gruppe „UniFlow“; `de.uniflow.plus.monthly` (UniFlow Plus, 1,99, P1M, „PDFs bearbeiten, Apple Pencil, Skript-Split-Screen, 6 KI-Tests im Monat“); `de.uniflow.pro.monthly` (UniFlow Pro, 4,99, P1M, „Alles aus Plus, 40 KI-Tests im Monat, erweiterte KI-Funktionen“); Storefront DEU, Locale de_DE |

Summe App: 24 Testfunktionen.

### Paket-Tests (`Packages/UniFlowCore/Tests/UniFlowCoreTests`)
| Datei | Klasse | Testfunktionen |
|---|---|---|
| JSONValueTests.swift | `JSONValueTests` | `testParsesWebEditorDocument`, `testRoundTripKeepsValues`, `testIntegersWithoutFraction`, `testUnicodeEscapesAndSurrogates`, `testRejectsInvalidInput`, `testSortedOutputIsDeterministic`, `testLargeDocumentSpeed` |
| MergeAndDocumentTests.swift | `MergeTests` | `testBothDevicesAddOnSamePage`, `testDeletionOnOneSideWins`, `testDeletedHereButChangedThereIsKept`, `testBothChangedSameObjectLocalWinsAndCounts`, `testUnknownFieldsArePreserved`, `testPageOrderKeepsLocallyAddedPage`, `testMerge5000ObjectsIsFast` |
| | `DocumentTests` | `testEnsurePDFPagesAndMapping`, `testInsertedAndRemovedPagesFromWebEditor`, `testStoredDrawingRoundTrip` |
| | `GeometryTests` | `testRotatedPageSwapsSize`, `testViewToPageAndBack`, `testZoomKeptOnResizeWhenUserZoomed` |
| SharedFixtureTests.swift | `SharedFixtureTests` | `testMergeCasesMatchWebEditor` (liest `packages/shared-contracts/fixtures/merge/cases.json`), `testWebEditorDocumentFixture` (liest `packages/shared-contracts/fixtures/documents/web-editor.json`) |
| StudIPTests.swift | `StubTransport` (Hilfe), `StudIPClientTests` | `testCoursesFollowPaginationAndSemester`, `testFilesWalkFolderTreeWithPaths`, `testUnauthorizedMeansSessionExpired`, `testRedirectToLoginPageMeansSessionExpired`, `testDownloadReturnsBytesAndReportsHTTPErrorsWithoutIDs`, `testRequestLimitStopsRun`, `testForeignNextLinkIsRejected`, `testScrubRemovesIDsAndQuery` |
| | `StudIPImportTests` | `testPlanSortsNewChangedUnchangedAndGone`, `testSafeFileName`, `testDefaultSelectionPicksNewestSemester` |
| SyncEngineTests.swift | `SyncEngineTests` | `testEditIsSavedLocallyThenUploaded`, `test1000Strokes`, `test5000Strokes`, `testStrokesWrittenDuringUploadStayUnsent`, `testCrashRightAfterAckKeepsLaterStrokesUnsent`, `testParallelWritingAndSyncingUsesOneUploadAtATime`, `testNetworkFailureKeepsChangesAndRetries`, `testOpenOfflineWithoutLocalDataGivesEmptyDocument`, `testAppCrashBeforeUploadRestoresFromJournal`, `testRestartAfterLostAckDoesNotDuplicate`, `testFailedLocalSaveIsNeverShownAsSaved`, `testVersionConflictOnDifferentPagesMergesBoth`, `testSimultaneousEditsOnSamePageKeepBothDevices`, `testDeleteOnOneDeviceIsNotUndoneByOther`, `testRemoteChangeIsReportedForDisplayedPage`; Hilfsklasse `ChangedBox` |
| TestSupport.swift | – (Hilfen) | `TestError`, `actor MockServer` (fetch/put mit 409, holdNext/releaseHeldPut, externalEdit, objectIDs, allObjectIDs), `stroke()`, `page()`, `pageWith()`, `fastSleeper`, `makeEngine()`, `waitUntil()` |

Summe Paket: 48 Testfunktionen. Gesamt: 72.

**Nicht durch Tests abgedeckt:** alle SwiftUI-Ansichten (keine UI-Tests), `APIClient`, `HTTPAnnotationTransport`, `Session`, `Keychain`, `RemoteData.load`, `DocumentStore` (Bookmark, Leerseite, Drehen, Text, Export-Pfad, Suche), `PDFEditorController`-Ablauf, `StudIPSync` (App-Teil, Schlüsselbund, WebView), Pfadberechnung in `CalendarView`, `Diagnostics`.

---

## F) Lücken, TODOs, Platzhalter, fest eingetragene Werte

### Funktionale Lücken
1. **Dokumentliste offline:** LibraryView und CompanionPicker nutzen keinen Offline-Cache (`api.json`, Views.swift:162; DocumentView.swift:396). Ohne Server ist die Dokumentliste leer, obwohl PDFs und Journal lokal liegen. TestRunView ist ebenfalls ohne Cache (TestsView.swift:107).
2. **Stud.IP-Dateien:** Direkt aus Stud.IP geladene Dateien sind nur per QuickLook ansehbar (StudIPView.swift:51, 68). Sie lassen sich nicht im Editor öffnen oder beschreiben und erscheinen nicht in der Bibliothek. „In Stud.IP nicht mehr vorhanden“ wird nur gemeldet; es gibt kein Löschen einzelner Dateien. Kommentar: Übergang bis OAuth2 (StudIPSync.swift:6).
3. **Web-Objekte auf dem iPad:** Text, Formen, Bilder und Haftnotizen sind nur Anzeige (PageObjects.swift:181); Bearbeiten ist nur im Browser möglich. Asset-Seiten zeigen nur einen Platzhaltertext (PDFEditorController.swift:336).
4. **Undo/Redo** gilt nur für PencilKit-Striche. Leerseite, Drehen, Lesezeichen und Text lassen sich nicht rückgängig machen.
5. **„Text hinzufügen“** hat feste Position und Formatierung und ist danach auf dem iPad nicht änderbar (DocumentStore.swift:304-310).
6. **Lesezeichentitel** fest „Seite n“, nicht editierbar (DocumentView.swift:272).
7. **Miniaturen** zeigen weder Handschrift noch Vorlagen noch Web-Objekte (PDFThumbnailView, DocumentView.swift:439-454).
8. **Export:** Handschrift wird gerastert, nicht als Vektor (PDFExporter.swift:59). Nur das ganze Dokument, keine Seitenauswahl.
9. **Keine PDF-Textauswahl** (`isInMarkupMode = true`, PDFEditorController.swift:163); damit auch keine Textmarkierung als Text und keine KI-Auswahl.
10. **Dokument-Tabs** werden nicht gespeichert. Jeder Tabwechsel baut das Dokument neu auf (`.id(f.id)`, Views.swift:118); Zoom und Scrollposition gehen verloren. Der Kommentar in DocumentView.swift:164 („weiter synchronisieren“) passt dazu nur teilweise, weil der Store beim Wechsel freigegeben wird (`deinit` → `shutdown`).
11. **Vollbild** blendet nur die Navigationsleiste aus; Tab-Leiste und Dokument-Tabs bleiben (DocumentView.swift:129).
12. **Navigation im Dokument:** kein Seitensprung per Eingabe, keine Vor/Zurück- oder Zoom-Buttons.
13. **Dashboard und Kalender** sind reine Anzeige: Aufgaben nicht abhakbar, Karten nicht antippbar, keine Termin- oder Paketbearbeitung.
14. **Tests:** kein Timer für `duration_min`; Antworten werden vor der Abgabe nicht zwischengespeichert, beim Verlassen der Ansicht gehen sie verloren.
15. **Einstellungen:**
    - Der Name wird nur bei Return gespeichert (SettingsView.swift:25).
    - Das Setzen von `hand` aus den Serverdaten in `.task` löst `onChange` aus. Weicht der Wert von „right“ ab, folgt ein unnötiges `PUT /api/settings` mit der Meldung „Gespeichert.“ (SettingsView.swift:32-35, 82).
16. **Abo/Tarif:**
    - Nur Testmodus.
    - `verifyOnServer` wird nie gesetzt (PurchaseStore.swift:19).
    - Der Tarif schaltet nirgends Funktionen frei oder sperrt sie.
    - `SubscriptionView` legt bei jedem Erscheinen einen neuen `PurchaseStore` mit neuer `Transaction.updates`-Schleife an.
17. **PIN-Zwang:**
    - Verbinden ohne PIN geht nicht (Button deaktiviert, Views.swift:34).
    - `Session.init` stellt die Sitzung nur mit gespeichertem PIN wieder her (Session.swift:14-16).
    - Ein 401 im laufenden Betrieb führt nicht zur Abmeldung, sondern nur zu Fehlertexten.
18. **PDF-Cache** wird nie erneuert: Ändert sich die PDF auf dem Server, bleibt die alte (DocumentStore.swift:129).
19. **ResponseCache:**
    - Schlüssel ist nur der Pfad, nicht der Server; nach einem Serverwechsel können fremde Daten erscheinen.
    - Es wird nie aufgeräumt (z. B. Kalenderpfade je Woche).
    - „Trennen“ löscht weder Cache noch Journal noch PDFs.
20. **Offline-Banner flackert:** RemoteData zeigt beim normalen Laden zuerst den Cache mit `offlineSince`, dadurch kurz „Offline – Stand …“ (RemoteData.swift:63).
21. **Diagnose-Fehler möglich:** `Diagnostics.collect` übergibt den bereits kodierten Ordnernamen erneut als `documentID` an `LocalJournal` (SettingsView.swift:133-134). Bei IDs, die `~`-kodiert wurden, entsteht ein falscher Pfad; solche Dokumente fehlen in der Zählung.
22. **Zwei Namensschemata:** `LocalJournalName.safe` (Hex ohne Präfix, für PDF-Dateinamen, DocumentStore.swift:20-25) und `LocalJournal.safeName` (`~` plus Hex, höchstens 100 Zeichen, LocalJournal.swift:44-50).
23. **Ungenutzter Code:** `DocumentStore.close()`, `PDFEditorController.showToolPicker(_:)`, `DocumentStore.pageKey(forPageIndex:)`. `PageGeometry.toPage/toView` wird nur in Tests genutzt.
24. **Synthetisierte LibFile-Daten:**
    - Der Skript-Vorschlag baut eine `LibFile` mit erfundenen Werten: `name = title + ".pdf"`, `doc_type "vorlesung"`, `downloaded_at "unbekannt"`, Modul und Fach des aktuellen Dokuments (DocumentView.swift:222-226). Dateiname und Fach im InfoSheet können deshalb falsch sein.
    - `LibFile(json:)` setzt `downloaded_at` auf `"unbekannt"` (ModulesView.swift:134). Nicht heruntergeladene Server-Dateien gelten dadurch als PDF und scheitern erst beim Laden.
25. **Erkennung von Übungsdateien** (für den Skript-Vorschlag) über feste Schlüsselwörter: `uebung`, `loesung`, `klausur` bzw. „übung“, „uebung“, „blatt“, „aufgabe“ (DocumentView.swift:93-98).
26. **Tinten-Kompatibilität:**
    - PencilKit-Tinten außer pen, pencil und marker werden als „pen“ gespeichert.
    - Marker-Deckkraft fest 0,35 (StrokeConverter.swift:179-184, 203).
    - Das Web-Werkzeug „fountain“ erscheint auf dem iPad als „pen“ (StrokeConverter.swift:110).
27. **Gerätefamilie:** `TARGETED_DEVICE_FAMILY "1,2"` schließt das iPhone ein, obwohl die App als iPad-App beschrieben ist; iPhone nur Hochformat (project.yml:29, 49-50).
28. **README veraltet:** README.md:45-46 sagt, Text, Formen, Bilder und eingefügte Leer-/Bildseiten würden „auf dem iPad noch nicht angezeigt“. PageObjects.swift und DisplayLayout.swift zeigen sie inzwischen an (Asset-Seiten als Platzhalter). Ebenso README.md:15: „Views.swift: Verbinden, Bibliothek, Dokumentansicht“ – die Dokumentansicht liegt inzwischen in DocumentView.swift.
29. **Nicht am Gerät getestet** laut README.md:3-5: Schreibgefühl, Handballen-Erkennung, Pencil-Doppeltippen, Zoomverhalten. Checkliste in `docs/MAC-IPAD-CHECKLISTE.md`.
30. **Vor einer Veröffentlichung** (README.md:68-69, project.yml:52): `NSAllowsArbitraryLoads` entfernen, HTTPS, Bundle-ID und Team festlegen, Datenschutzangaben, App-Store-Connect-Eintrag.
31. **Keine Lokalisierung:** Alle UI-Texte stehen fest auf Deutsch im Code; es gibt keine `Localizable`-Dateien.

### Platzhalter / Testmodus
- „Abo (Testmodus)“ und `SubscriptionView` mit Footer „Testmodus: … Es wird nichts abgerechnet.“ (SettingsView.swift:61; PurchaseStore.swift:100, 109).
- Kommentar „NUR TESTKONFIGURATION … Echte Produkte … erst nach ausdrücklicher Freigabe“ (PurchaseStore.swift:6-8); project.yml:85 „nur lokales StoreKit-Testen“.
- Platzhaltertext für Asset-Seiten (PDFEditorController.swift:336).
- Keine `TODO`/`FIXME`-Kommentare im Code gefunden.

### Fest eingetragene Werte
| Wert | Datei:Zeile |
|---|---|
| Standard-Server `http://192.168.0.10:8765` | Session.swift:20, 28; Views.swift:17 |
| Persönlicher Rechnername `http://amo.fritz.box:8765` im Hilfetext | Views.swift:23 |
| Hinweis auf `Start-iPad.cmd` und Menüpfad „Einstellungen → Zugang & Darstellung → Auf dem iPad benutzen“ | Views.swift:23; Session.swift:44 |
| Cookie-Name `lernapp_pin` | APIClient.swift:33 |
| HTTP-Timeout 25 s | APIClient.swift:21 |
| Multipart-Boundary-Präfix `uniflow-`, Felder `kind: "pdf"`, Datei-Feld `upload` | APIClient.swift:57; Views.swift:178-179 |
| Stud.IP-Basis `https://studip.uni-hannover.de`; Text „Leibniz Universität Hannover“ | StudIPSync.swift:96; StudIPView.swift:26 |
| Stud.IP: 30-Minuten-Intervall | StudIPSync.swift:180; UniFlowApp.swift:19 |
| Stud.IP: Timeouts 30 s / 600 s | StudIPSync.swift:76-77 |
| Stud.IP: Pause 250 ms, max. 1500 Anfragen, Ordnertiefe 6, Seitenlimits 100/200/500 | StudIPClient.swift:100, 177, 195, 208, 210, 219 |
| Stud.IP: Dateinamen max. 120 Zeichen | StudIPImport.swift:81-85 |
| Schlüsselbund-Service `de.uniflow.ai.studip` / Account `session-cookies` | StudIPSync.swift:12-13 |
| Produkt-IDs `de.uniflow.plus.monthly`, `de.uniflow.pro.monthly`; Ränge free/plus/pro | PurchaseStore.swift:11, 33-37 |
| SyncEngine: Upload-Verzögerung 1,2 s, Wiederholung 2–60 s, max. 5 Konflikte in Folge | SyncEngine.swift:106, 116, 273, 300 |
| Entprellung Zeichnung 0,25 s | DocumentStore.swift:214 |
| Skript-Vorschlag nach 2,5 s | DocumentView.swift:234 |
| Overlay-Parkplätze 6 | PDFEditorController.swift:92 |
| Zoomgrenzen 0,5× / 6× | Geometry.swift:42-43 |
| Teilung: Standard 0,42, Grenzen 0,2–0,65 | DocumentView.swift:68, 194 |
| Seitenleiste 200 pt, Miniaturen 140×190, Lesezeichenliste max. 180 pt | DocumentView.swift:108, 430, 445 |
| Standard-Seitengröße 595×842 (A4) | DocumentStore.swift:274; DisplayLayout.swift:47; PDFExporter.swift:20 |
| Leerseiten-Schlüssel `b` plus 11 Zeichen; Strich-IDs `pk` plus 12 Zeichen | DocumentStore.swift:275; StrokeConverter.swift:243 |
| Text-Objekt: x 40, y 40+n·30, Arial 14, `#1d2130`, Breite 220 | DocumentStore.swift:304-310 |
| Vorlagen-Raster 24 / 14,17 / 2,835 pt, Cornell-Rand 150 pt, erste Linie bei 60 pt | PageObjects.swift:105-129 |
| Suche: mindestens 2 Zeichen, max. 200 Treffer, Ausschnitt 160 Zeichen | DocumentStore.swift:319-326 |
| Export: Rasterfaktor 3, Dateiname max. 80 Zeichen, Suffix „ – Notizen.pdf“ | PDFExporter.swift:13, 59, 70 |
| Dashboard-Listen: 6 Termine / 8 Aufgaben / 6 neue Dateien | DashboardView.swift:88, 103, 135 |
| Kalender: Standardmodus „3 Tage“, Ladezeitraum 7 Tage | CalendarView.swift:10, 30 |
| Neue-Version-Format `version 2`, `zoom 1.2` | AnnotationDocument.swift:14-16 |
| `MARKETING_VERSION 0.2.0`, Build 2, Bundle `de.uniflow.ai` | project.yml:15-16, 28 |

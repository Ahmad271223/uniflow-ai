import PDFKit
import PencilKit
import PhotosUI
import SwiftUI
import UniFlowCore
import UniformTypeIdentifiers

// MARK: - Dokument

/// Verbindung zwischen SwiftUI-Leisten und dem UIKit-Editor.
@MainActor
final class EditorBridge: ObservableObject {
    weak var controller: PDFEditorController?
    @Published var zoomPercent = 100
    @Published var pageIndex = 0
    @Published var pageKey: String?
    /// Objekt-Werkzeuge (Editor-Schritt 6)
    @Published var objectMode = false
    @Published var objectTool: ObjectEditing.Tool = .select
    @Published var objectSelection = 0
    @Published var textSelected = false
    /// Markierter PDF-Text soll an die KI-Hilfe (Leiste "Text markieren": "KI erklärt", "KI löst")
    @Published var tutorRequest: TutorRequest?
    /// Anhang fuer das Eingabefeld der KI-Hilfe (05.11.2026): markierter Text ("In KI-Hilfe einfügen", "KI fragen")
    /// oder ein Ausschnitt als Bild ("Bereich an KI", "Ganze Seite an KI"); oeffnet die KI-Hilfe
    @Published var tutorAttachment: TutorAttachment?
    /// Kurzer Hinweis unten im Editor (verschwindet von selbst)
    @Published var hint: Hint?

    struct Hint: Equatable {
        let id = UUID()
        let text: String
    }
    /// Feste Werkzeugleiste oben (`EditorToolbar`): sichtbar bzw. nur Tinte, vom Editor gemeldet
    @Published var toolbar = EditorToolbarMode.hidden

    struct TutorRequest: Equatable {
        let id = UUID()
        let mode: String
        let selection: String
    }

    /// KI-Hilfe oeffnen ohne Anhang (z. B. "KI erklärt" ohne markierten Text): jede Erhoehung oeffnet sie
    @Published var askAIRequested = 0
    /// "Als Karteikarte" aus markiertem PDF-Text (Schritt K): Vorderseite fuer das Blatt "Karte anlegen"
    @Published var flashcardRequest: FlashcardRequest?

    struct FlashcardRequest: Equatable {
        let id = UUID()
        let question: String
    }

    /// Markierten Text an die KI-Hilfe geben (oeffnet sie und fragt sofort); ohne Auswahl nur die KI-Hilfe oeffnen
    /// (vorher geschah dann gar nichts)
    func askTutor(_ mode: String) {
        let text = controller?.pdfView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { askAIRequested += 1; return }
        tutorRequest = TutorRequest(mode: mode, selection: text)
    }

    /// Vom Editor: Anhang in die KI-Hilfe, ohne Anhang nur die KI-Hilfe oeffnen
    func attachToTutor(_ a: TutorAttachment?) {
        if let a { tutorAttachment = a } else { askAIRequested += 1 }
    }

    /// Markierten Text als Vorderseite einer neuen Karteikarte anbieten (Leiste "Text markieren" und Bearbeitungsmenue)
    func makeFlashcard(_ selection: String? = nil) {
        guard let text = PDFEditorController.flashcardText(selection ?? controller?.pdfView.currentSelection?.string) else { return }
        flashcardRequest = FlashcardRequest(question: text)
    }

    func setObjectMode(_ on: Bool) {
        controller?.setObjectMode(on)
        objectMode = controller?.objects.isActive ?? false
    }

    func setObjectTool(_ t: ObjectEditing.Tool) {
        controller?.setObjectTool(t)
        objectTool = t
    }

    /// "Fertig" in der Objektleiste: zurueck zum Stift (ueber die feste Leiste)
    func finishObjectTools() {
        controller?.finishObjectTools()
        objectMode = controller?.objects.isActive ?? false
    }

    func undo() { controller?.undo() }
    func redo() { controller?.redo() }
    func fitWidth() { controller?.fitWidth() }

    /// Menueleiste und Tastenkuerzel (10.11.2026): Blaetter des Dokuments oeffnen (Suchen, Gehe zu, Sichern, Drucken)
    @Published var menuRequest: EditorMenuRequest?

    func request(_ kind: EditorMenuRequest.Kind) { menuRequest = EditorMenuRequest(kind: kind) }

    /// Schreiblupe offen (`WritingMagnifier`)
    @Published var magnifierOpen = false
    func toggleMagnifier() { controller?.setMagnifier(!magnifierOpen) }

    /// Werkzeug aus Menue oder Tastatur. Am Mac schreibt die Maus danach (sonst blaetterte sie weiter und das gewaehlte
    /// Werkzeug taete nichts).
    func choose(_ tool: EditorTool) {
        if tool.isInk { mouseWrites() }
        controller?.choose(tool)
    }

    /// Werkzeug in der festen Leiste gewaehlt: am Mac schreibt die Maus danach mit Stift, Radierer oder Lasso (wie
    /// ueber Menue und Tastatur)
    func toolbarPicked(_ tool: EditorToolState.Tool) {
        if tool.drawsOnCanvas { mouseWrites() }
    }

    private func mouseWrites() {
        guard PDFEditorController.isMac, UserDefaults.standard.object(forKey: "uniflow.pencilOnly") as? Bool ?? true else { return }
        UserDefaults.standard.set(false, forKey: "uniflow.pencilOnly")
        hint = Hint(text: EditorPointer.macHint(pencilOnly: false))
    }
}

/// Ein Werkzeugstand (feste Leiste, `EditorToolState`) und ein Rueckgaengig-Verlauf fuer beide Seiten der geteilten
/// Ansicht
@MainActor
final class EditorToolsHolder: ObservableObject {
    let tools = EditorToolState()
    let undo = UndoManager()
}

/// Vorlagen fuer neue Seiten (gleiche Namen wie TEMPLATES im Web-Editor).
/// Seite fuer den Dialog "Vorlesung bis hier" (PDF-Seite 1-basiert und Seitenschluessel)
struct MarkerPage: Identifiable {
    let page: Int
    let key: String
    var id: String { key }
}

struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
    /// Hinweis ueber dem Teilen-Menue (z. B. fehlende Bilder).
    var notice: String? = nil
    var purpose: ExportPurpose = .share
}

/// Was mit der exportierten PDF geschieht: Teilen-Menue, Sichern in einen Ordner (am Mac das Fenster "Sichern"),
/// Drucken (10.11.2026)
enum ExportPurpose: Equatable {
    case share, save, print

    var confirmTitle: String {
        switch self {
        case .share: return "Exportieren"
        case .save: return "Sichern …"
        case .print: return "Drucken …"
        }
    }
}

/// Befehl aus der Menueleiste bzw. per Tastenkuerzel an das offene Dokument (`EditorCommands`)
struct EditorMenuRequest: Equatable {
    enum Kind: Equatable { case search, goToPage, save, print, share, photo, imageFile, magnifier, present, endPresentation, newWindow }
    let id = UUID()
    let kind: Kind
}

/// Blaetter rund um "Lösung teilen".
enum SolutionSheet: Identifiable, Equatable {
    case share
    case shared
    /// Vorschau einer empfangenen Loesung (Loesungs-ID)
    case preview(String)
    /// Loesungen aus der Community zu dieser PDF (Fingerabdruck)
    case community(String)
    /// gesperrte Community-Funktion (Teilen in Free): Sperrkarte mit Weg zur Abo-Seite
    case locked(UFFeature)

    var id: String {
        switch self {
        case .share: return "share"
        case .shared: return "shared"
        case .preview(let id): return "preview-" + id
        case .community(let fp): return "community-" + fp
        case .locked(let f): return "locked-" + f.rawValue
        }
    }
}

/// Zweites Dokument der geteilten Ansicht (meist das Skript zur Uebung).
struct Companion: Identifiable, Equatable {
    let file: LibFile
    /// PDF-Seite (1-basiert, wie von /api/related geliefert), `nil` = Anfang.
    let pdfPage: Int?
    /// "Leeres Blatt" zu einem Dokument, das schon ein Blatt hat: unten eine Seite mit dieser Vorlage anfuegen und
    /// hinspringen, statt ein weiteres Notizbuch anzulegen (Wunsch des Inhabers 13.11.2026)
    var appendTemplate: String? = nil
    /// je Anfuegen neu, damit die Ansicht daneben auch beim selben Blatt neu anfaengt
    var request = ""
    var id: String { file.id }
}

/// Vorschlag der Skriptsuche (`POST /api/related`), ohne KI-Aufruf.
struct ScriptSuggestion: Equatable {
    let fileID: String
    let title: String
    let page: Int
    let terms: [String]
    let forPage: Int
}

struct DocumentView: View {
    let api: APIClient
    @StateObject private var store: DocumentStore
    @StateObject private var bridge = EditorBridge()
    @StateObject private var tools = EditorToolsHolder()
    @AppStorage("uniflow.pencilOnly") private var pencilOnly = true
    @AppStorage("uniflow.hand") private var hand = "right"
    @AppStorage("uniflow.splitFraction") private var splitFraction = 0.42
    /// Lage der Werkzeuge (Einstellungen, 12.11.2026): oben fest, unten fest oder schwebend (`EditorToolbarPlacement`)
    @AppStorage(EditorToolbarPlacement.key) private var toolbarPlacementRaw = EditorToolbarPlacement.standard.rawValue
    /// an der Kopfzeile getauschte Paare (SplitSides.swift), wie die Breite der Teilung auf dem Geraet gemerkt
    @AppStorage(SplitSides.swappedKey) private var splitSwapped = ""
    /// Breite der KI-Hilfe, am Rand gezogen und je Geraet gemerkt (TutorPanelWidth.swift; 0 = Standard)
    @AppStorage(TutorPanelWidth.key) private var tutorStoredWidth = 0.0
    /// Ziehen an der Kopfzeile der Spalte daneben laeuft (x im Raum "split", nil = noch nicht bewegt)
    @State private var swapDrag: CGFloat?? = nil
    /// wird gerade neu geoeffnet (nach "Hier bearbeiten" bzw. Freigabe im anderen Fenster)
    @State private var reopening = false
    @State private var fullScreen = false
    /// Praesentation (11.11.2026): ohne Leisten, ganze Seite, seitenweise blaettern
    @State private var presenting = false
    @State private var showSidebar = false
    @State private var showSearch = false
    @State private var showTutor = false
    /// KI-Start bittet um offene KI-Hilfe (`UFRouter.tutorOpenRequest`)
    @EnvironmentObject private var router: UFRouter
    /// KI ueber das ChatGPT-Abo verbunden (Vorlesungsmarker; die KI-Hilfe zeigt ohne Verbindung den Weg dorthin)
    @Environment(\.ufAIEnabled) private var aiEnabled
    @Environment(\.ufProAIOfferHidden) private var proAIOfferHidden
    @State private var showInfo = false
    @State private var showTrash = false
    @State private var choosingCompanion = false
    /// Loesung zum Ansehen neben dem Dokument (statt eines zweiten Dokuments)
    @State private var solutionSide: ForeignSolutionLayer?
    /// Dokument der geteilten Ansicht (ein Notizblatt daneben geht beim Teilen der Loesung mit)
    @State private var companionStore: DocumentStore?
    @State private var addingText = false
    // Seitenwerkzeuge (Editor-Schritt 5)
    @State private var goingToPage = false
    @State private var goToText = ""
    @State private var addingOutline = false
    @State private var outlineTitle = ""
    @State private var confirmClear = false
    @State private var showOutline = false
    @State private var newText = ""
    @State private var exportFile: ExportFile?
    /// Teilen, Sichern oder Drucken nach dem Hinweis "nur privat"
    @State private var exportPurpose: ExportPurpose = .share
    /// Bild einfuegen (10.11.2026): aus Fotos bzw. aus Dateien (am Mac: Finder)
    @State private var pickingPhoto = false
    @State private var photoItem: PhotosPickerItem?
    @State private var pickingImageFile = false
    @State private var exporting = false
    @State private var actionError: String?
    @State private var companion: Companion?
    @State private var suggestion: ScriptSuggestion?
    /// Skriptsuche gescheitert (Fehlerantwort, Server nicht erreichbar): Hinweis statt stillem Ausbleiben
    @State private var suggestionError: String?
    @State private var dismissedSuggestions: Set<Int> = []
    @State private var suggestionTask: Task<Void, Never>?
    @State private var suggestionCache: [Int: ScriptSuggestion?] = [:]
    /// PDF-Export (privat) wartet auf die Bestaetigung des Hinweises
    @State private var pendingExport: ShareScope?
    /// Blatt "In Stud.IP abgeben" (docs/ABGEBEN-STUDIP-2026-11-05.md)
    @State private var submittingToStudIP = false
    /// Hochschule Hannover: Abgabe in einer Moodle-Aufgabe
    @State private var submittingToMoodle = false
    @State private var mailingDocument = false
    @Environment(\.uniMail) private var uniMailConnection
    @Environment(\.hsh) private var hshConnection
    @Environment(\.hildesheim) private var hildesheimConnection
    @State private var solutionSheet: SolutionSheet?
    @State private var importingSolution = false
    /// "Meine Notizen" sichtbar; ausgeblendet = nur ansehen
    @State private var ownNotesVisible = true
    /// passende empfangene Loesungen (nur Anzeige)
    @State private var foreignLayers: [ForeignSolutionLayer] = []
    /// passende, aber nicht lesbare Loesungen (im Ebenen-Menue entfernbar)
    @State private var foreignProblems: [SolutionLayerLoad.Problem] = []
    /// Treffer aus der Community zu dieser PDF (beim Oeffnen geholt, je Sitzung zwischengespeichert, nie blockierend)
    @State private var communityMatches: [CommunitySolutionSummary] = []
    @State private var communityFingerprint: String?
    @State private var communityBannerDismissed = false
    @ObservedObject private var entitlements = Entitlements.shared
    /// gesperrte Plus-Funktion, deren Sperrkarte gerade offen ist (Schreiben, geteilte Ansicht)
    @State private var lockedFeature: UFFeature?
    /// "Als Karteikarte": Vorderseite aus markiertem PDF-Text, solange das Blatt "Karte anlegen" offen ist (Schritt K)
    @State private var flashcardQuestion: String?
    /// Stapel fuer das Blatt (Module und Dokumente zur Auswahl); erst beim ersten "Als Karteikarte" geladen
    @StateObject private var flashcards = FlashcardDeck()
    /// geoeffnete alte Fassung (S7, nur zum Ansehen)
    @State private var openedVersion: FileVersionInfo?
    /// alte Original-Fassung: nur ansehen (S7)
    let readOnly: Bool
    /// PDF-Seite beim Oeffnen (1-basiert, Treffer der Suche), nil = wie zuletzt
    let initialPDFPage: Int?
    /// gemerkte Stelle des Reiters (Seite, Punkt, Zoom; `DocumentTabList`), gilt ohne `initialPDFPage`
    let initialSpot: DocumentViewSpot?
    /// Kennung, unter der dieses Dokument seinen Schutz vor dem Reiterwechsel meldet
    @State private var leaveOwner = UUID()
    /// Stelle des Reiters merken (entprellt)
    @State private var spotTask: Task<Void, Never>?
    /// Aufgabe des Lernplans, aus der das Dokument geoeffnet wurde: Knopf "Erledigt" wie im Web (views-doc.js)
    let task: Int?
    @State private var taskDone = false
    /// zuletzt gelesene Seite merken (`last_page`, wie onPage im Web), entprellt
    @State private var lastPageTask: Task<Void, Never>?
    /// Vorlesungs-Seitenmarker ("Vorlesung bis hier", views-weekly.js setupLectureMarker)
    @StateObject private var markers = LectureMarkers()
    @State private var markerPage: MarkerPage?
    @State private var markerNotice: String?
    /// Korrekturvorschlag: fremde Loesung (Kennung beim Dienst), die beim Oeffnen korrigiert wird (`CorrectionMode.swift`)
    let correcting: String?
    /// laufende Korrektur (Korrektur-Modus); eigene Notizen dann ausgeblendet und nur lesbar
    @State private var correction: CorrectionSession?
    /// empfangene Korrektur ueber den eigenen Notizen (nur Anzeige)
    @State private var shownCorrection: CommunityCorrection?
    /// Randnotiz, die gerade gesetzt wird (Seite und Stelle)
    @State private var notePlacement: CorrectionNotePlacement?
    @State private var noteText = ""
    /// angetippte Randnotiz (Text ansehen, im Korrektur-Modus aendern oder loeschen)
    @State private var openedNote: CommunityCorrection.Note?
    @State private var editingCorrectionMessage = false
    @State private var correctionMessage = ""
    @State private var confirmDiscardCorrection = false
    @ObservedObject private var correctionLaunch = CorrectionLaunch.shared
    /// fremde Korrektur ansehen (nicht an mich): die korrigierte Loesung liegt dabei als Ebene darunter, eigene Notizen aus
    @State private var shownCorrectionTarget: ForeignSolutionLayer?
    /// offene Korrekturhinweise zu meiner eigenen, geteilten Loesung dieser PDF ("N Korrekturhinweise")
    @State private var ownCorrections: [CommunityCorrection] = []
    @State private var ownCorrectionsDismissed = false
    /// Bildschirm fixieren (docs/FIXIEREN-ABPAUSEN-2026-11-05.md): nur fuer diese Sitzung, nichts davon gespeichert
    /// ausser dem Wunsch "Helligkeit auf Maximum"
    @StateObject private var freeze = EditorFreezeSession()
    @AppStorage(EditorFreeze.maxBrightnessPreferenceKey) private var freezeMaxBrightness = false
    @AppStorage(EditorFreeze.introSeenKey) private var freezeIntroSeen = false
    @State private var freezeContrast = false
    /// Erklaerung beim ersten Mal, danach startet die gewaehlte Stufe
    @State private var freezeIntroFor: EditorFreeze.Mode?
    @Environment(\.scenePhase) private var scenePhase

    /// Zurueck-Pfeil mit eigener Aufgabe (Vollbild einer frueheren Fassung: schliessen); nil = Pfeil der App-Huelle
    /// (`\.ufBack`; im Vollbild darf der Pfeil nicht die Seite darunter wechseln, darum ausdruecklich)
    private let onBack: (() -> Void)?

    init(file: LibFile, api: APIClient, readOnly: Bool = false, initialPDFPage: Int? = nil, initialSpot: DocumentViewSpot? = nil,
         task: Int? = nil, correcting: String? = nil, onBack: (() -> Void)? = nil) {
        self.onBack = onBack
        self.api = api
        self.readOnly = readOnly
        self.initialPDFPage = initialPDFPage
        self.initialSpot = initialSpot
        self.task = task
        self.correcting = correcting
        _store = StateObject(wrappedValue: DocumentStore(file: file, api: api))
    }

    /// PDF-Seite (1-basiert) der angezeigten Seite, nil fuer eingefuegte Seiten
    private func pdfPage(at index: Int) -> Int? { store.entry(forPageIndex: index)?.pdfIndex }

    /// Seite gewechselt: nach 0,8 s Ruhe als zuletzt gelesene Seite speichern (POST /api/files/{id}/opened). Als
    /// PDF-Seite, so wie "Weiterlernen" sie wieder oeffnet (`initialPDFPage`)
    private func rememberPage(_ index: Int) {
        guard !readOnly, !store.isOldVersion, let page = pdfPage(at: index) else { return }
        lastPageTask?.cancel()
        let api = self.api, id = store.file.id
        lastPageTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            router.resume.notePage(page, of: id)          // Weitermachen wie zuvor (ResumeState.swift)
            _ = try? await api.value("/api/files/\(id)/opened", method: "POST", body: ["last_page": .number(Double(page))])
        }
    }

    /// Reiter fuer offene Dokumente (12.11.2026): nur fuer Dokumente der Bibliothek (keine alte Fassung, kein Dokument
    /// aus einem ZIP, die haben ein eigenes Zurueck)
    private var tabsEnabled: Bool { onBack == nil && !readOnly }

    /// Stelle des Reiters nach 1 s Ruhe merken (Seite, Punkt, Zoom; beim Verlassen ohnehin)
    private func scheduleSpot() {
        guard tabsEnabled else { return }
        spotTask?.cancel()
        let tabs = router.tabs, id = store.file.id
        spotTask = Task { [bridge] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            tabs.setSpot(bridge.controller?.currentSpot(), for: id)
        }
    }

    /// Vor dem Wechsel zu einem anderen Reiter: PDFKit nie waehrend einer Geste tauschen (Stift liegt auf, Finger
    /// scrollt oder zoomt, Ansicht rollt aus; wie `showLayout`), dann Stelle merken und alle Striche sichern
    static func prepareToLeave(store: DocumentStore, bridge: EditorBridge, tabs: DocumentTabList) async {
        let id = store.file.id
        await bridge.controller?.waitUntilSettled()
        tabs.setSpot(bridge.controller?.currentSpot(), for: id)
        await store.flush()
        tabs.setUnsaved(Self.unsaved(store.status), for: id)
    }

    /// Nicht lokal gesichert (der Reiter faellt dann nie von selbst heraus)
    static func unsaved(_ status: SyncStatus) -> Bool {
        switch status {
        case .localSaveFailed, .conflictUnresolved: return true
        default: return false
        }
    }

    /// Weitermachen wie zuvor (ResumeState.swift): Dokument fuer den naechsten Start merken; wurde es beim Start
    /// wiederhergestellt, die KI-Hilfe (ihr Gespraech laedt `TutorPanel` aus `TutorConversations`) und "Daneben öffnen"
    /// wie zuvor oeffnen. Ein verschwundenes zweites Dokument bleibt still weg.
    private func restorePanels() async {
        guard !readOnly, !store.isOldVersion, store.errorMessage == nil else { return }
        let id = store.file.id
        router.resume.noteDocument(id: id, page: initialPDFPage)
        guard let p = router.resume.takeRestoredPanels(for: id) else { return }
        if p.tutorOpen { showTutor = true }
        if let cid = p.companionID, cid != id, companion == nil, solutionSide == nil,
           let f = try? await api.json("/api/files/\(cid)", as: LibFile.self) {
            companion = Companion(file: f, pdfPage: p.companionPage)
        }
    }

    /// "Erledigt": Aufgabe abhaken (POST /api/tasks/{id}/status), danach zeigt der Knopf den Stand
    private func markTaskDone() async {
        guard let task else { return }
        do {
            _ = try await api.value("/api/tasks/\(task)/status", method: "POST", body: ["status": "erledigt"])
            taskDone = true
        } catch {
            actionError = "Aufgabe ließ sich nicht abhaken: \(error.localizedDescription)"
        }
    }

    /// "Vorlesung bis hier" nur fuer PDFs eines Moduls, nicht fuer eigene Uploads und nicht in alten Fassungen
    /// (views-doc.js: module_id, .pdf, course_id != "__user__"); der Marker dient den Wochentests der KI, darum lokal
    /// nur mit ChatGPT-Abo (wie die Wochentest-Box)
    private var offersLectureMarker: Bool {
        Self.offersLectureMarker(store.file, readOnly: readOnly || store.isOldVersion, local: api.isLocal, ai: aiEnabled)
    }

    static func offersLectureMarker(_ f: LibFile, readOnly: Bool, local: Bool, ai: Bool) -> Bool {
        f.module_id != nil && f.isPDF && f.course_id != "__user__" && !readOnly && (!local || ai)
    }

    /// Knopf: nur auf Originalseiten des Skripts (keine eingefuegte Notizseite)
    private func openLectureMarker() {
        guard let e = store.entry(forPageIndex: bridge.pageIndex), e.kind == "pdf", let page = e.pdfIndex else {
            actionError = "Bitte eine Seite des Vorlesungsskripts wählen (keine eingefügte Notizseite)."
            return
        }
        markerPage = MarkerPage(page: page, key: e.key)
    }

    /// "Als Karteikarte" (Schritt K): lokal nur mit Plus (Sperrkarte wie auf der Karteikarten-Seite), sonst das Blatt
    /// "Karte anlegen" mit der Auswahl vorn, Modul und Dokument dieser Datei; der Stapel laedt Module und Dokumente
    /// vorher, damit die Auswahl im Blatt stimmt (ein Fehler dabei sperrt das Blatt nicht)
    private func openFlashcard(_ question: String) {
        bridge.flashcardRequest = nil
        if api.isLocal, !entitlements.allows(.flashcards) {
            lockedFeature = .flashcards
            return
        }
        flashcards.attach(api)
        Task {
            if !flashcards.loaded { try? await flashcards.load() }
            flashcardQuestion = question
        }
    }

    /// Seite der freien Hand (Seitenleiste, KI-Hilfe, Schloss beim Abpausen): Rechtshaender -> links.
    private var scriptLeft: Bool { SplitSides.freeHandLeft(hand: hand) }

    /// Spalte daneben: Skript und Loesung auf der Seite der freien Hand, ein Blatt oder eine Uebung neben der Folie
    /// auf der Seite der Schreibhand (Befund 09.11.2026); an der Kopfzeile getauscht gespiegelt
    private var sideLeft: Bool {
        SplitSides.sidePaneLeft(hand: hand, role: SplitSides.role(side: solutionSide == nil ? companion?.file : nil, primary: store.file),
                                swapped: sideKey.map { SplitSides.isSwapped(splitSwapped, key: $0) } ?? false)
    }

    /// Paar aus Hauptdokument und Spalte daneben (fuer den gemerkten Tausch)
    private var sideKey: String? {
        if let s = solutionSide { return SplitSides.pairKey(primary: store.file.id, side: "loesung:" + s.id) }
        return companion.map { SplitSides.pairKey(primary: store.file.id, side: $0.file.id) }
    }

    private func swapSides() {
        guard let key = sideKey else { return }
        withAnimation(.easeInOut(duration: 0.2)) { splitSwapped = SplitSides.toggling(splitSwapped, key: key) }
    }

    /// Kopfzeile der Spalte daneben: gedrueckt halten, zur anderen Haelfte ziehen, loslassen tauscht
    private func paneSwap(width: CGFloat) -> UFPaneSwap {
        UFPaneSwap(moved: { active, x in swapDrag = active ? .some(x) : nil },
                   ended: { x in
                       let swaps = SplitSides.dropSwaps(sidePaneLeft: sideLeft, x: x, width: width)
                       swapDrag = nil
                       if swaps { swapSides() }
                   },
                   swapNow: { swapSides() })
    }

    /// "Zum Abpausen einfrieren": nur die Seite, keine Leisten, keine Eingabe
    private var tracing: Bool { freeze.isTracing }
    /// Leisten und Seitenspalten aus: beim Abpausen und in der Praesentation
    private var chromeHidden: Bool { tracing || presenting }

    /// Lage der Werkzeuge; am Mac nie schwebend
    private var toolbarPlacement: EditorToolbarPlacement {
        EditorToolbarPlacement.resolve(toolbarPlacementRaw, isMac: PDFEditorController.isMac)
    }

    /// "Oben fest": eine Kopfzeile statt Navigationsleiste und Werkzeugleiste (`EditorHeaderBar`)
    private var usesHeader: Bool { toolbarPlacement == .top }

    /// Schloss der KI-Stellen im Editor (KI-Hilfe, "KI fragen", "Bereich an KI"): ohne KI und ohne Pro AI "ab Pro AI"
    private var aiLock: UFPlan? {
        UFLock.ai(.aiHelp, plan: entitlements.plan, aiEnabled: aiEnabled, offerHidden: proAIOfferHidden)
    }

    /// Feste Werkzeugleiste (eigener Typ, damit `documentChrome` flach bleibt, `ViewTypeDepthAppTests`). In der einen
    /// Kopfzeile (`embedded`) ohne "KI fragen": dort fuehrt der KI-Knopf der Zeile beides (KI-Hilfe, markierter Text)
    private func toolbarStrip(embedded: Bool = false) -> EditorToolbar {
        EditorToolbar(tools: tools.tools, mode: bridge.toolbar, undo: { [bridge] in bridge.undo() }, redo: { [bridge] in bridge.redo() },
                      onPick: { [bridge] t in bridge.toolbarPicked(t) },
                      askAI: aiEnabled && !proAIOfferHidden && !embedded ? { [bridge] in bridge.controller?.askAIFromToolbar() } : nil,
                      askAILock: embedded ? nil : aiLock, atBottom: toolbarPlacement == .bottom, embedded: embedded)
    }

    /// Ohne Schreiben im Tarif (Free, nach dem Herabstufen) steht die Leiste mit Schloss da
    private var writingLocked: Bool { !planAllowsWriting && !readOnly && !store.isOldVersion && correction == nil }

    /// Platz der Werkzeuge oben bzw. unten (Leiste, Leiste mit Schloss ohne Plus, Hinweis bei "Schwebend"); "Oben fest"
    /// stehen sie in der einen Kopfzeile (`editorHeader`), hier dann nichts
    private func toolbarSlot(_ edge: EditorToolbarSlot.Edge) -> EditorToolbarSlot {
        let shown = !chromeHidden && !(usesHeader && edge == .top)
        let locked = shown && writingLocked
        return EditorToolbarSlot(edge: edge, placement: toolbarPlacement,
                                 toolbar: shown && bridge.toolbar.visible && toolbarPlacement != .floating ? toolbarStrip() : nil,
                                 lockedPlan: locked ? UFLock.plan(.pencilWriting, plan: entitlements.plan) : nil,
                                 askAILock: aiLock)
    }

    /// Leiste der Praesentation (klein, unten rechts)
    private var presentationControls: some View {
        HStack(spacing: 12) {
            Button { bridge.controller?.perform(.left) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Vorige Seite")
            Text("\(bridge.pageIndex + 1) / \(bridge.controller?.pageCount ?? store.pdf?.pageCount ?? 0)")
                .monospacedDigit()
            Button { bridge.controller?.perform(.right) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel("Nächste Seite")
            Divider().frame(height: 16)
            Button("Beenden") { presenting = false }
                .keyboardShortcut(.escape, modifiers: [])
                .accessibilityIdentifier("doc.presentation.end")
        }
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .opacity(0.85)
        .padding(16)
        .modifier(MacHelp(text: "Pfeiltasten, Leertaste oder Klicker blättern; Esc beendet. Am Mac: Fenster auf den Beamer ziehen und mit ⌃⌘F auf Vollbild."))
    }

    /// Dokument in einem eigenen Fenster: hier schliessen, dort oeffnen (sonst waere es dort nur zum Ansehen offen)
    private func openInNewWindow() {
        // mit Reitern: Reiter hier schliessen (Striche gesichert, Nachbar kommt), Dokument im neuen Fenster an seiner Stelle
        if tabsEnabled, router.tabs.entry(store.file.id) != nil {
            router.tabs.setSpot(bridge.controller?.currentSpot(), for: store.file.id)
            router.tabs.openInNewWindow(store.file.id, router: router)
            return
        }
        let id = store.file.id
        let page = store.entry(forPageIndex: bridge.pageIndex)?.pdfIndex
        if let onBack { onBack() } else { router.back() }
        Task {
            await store.pause()
            try? await Task.sleep(nanoseconds: 300_000_000)
            DocumentWindows.open(fileID: id, page: page)
        }
    }

    /// Menue, Cmd-L: beim ersten Mal die Erklaerung, sonst gleich; "Ansicht fixieren" bei fixierter Ansicht loest sie
    private func requestFreeze(_ mode: EditorFreeze.Mode) {
        guard store.pdf != nil, !tracing else { return }
        if mode == .view, freeze.mode == .view { freeze.unlock(); return }
        if !freezeIntroSeen { freezeIntroFor = mode; return }
        startFreeze(mode)
    }

    private func startFreeze(_ mode: EditorFreeze.Mode) {
        freezeIntroSeen = true
        if mode == .trace {
            freeze.startTracing(.init(maxBrightness: freezeMaxBrightness && !PDFEditorController.isMac, highContrast: freezeContrast))
        } else {
            freeze.fixView()
        }
    }

    /// Schreiben mit dem Pencil, Seiten und Lesezeichen nur mit Plus; Free und nach dem Herabstufen nur ansehen
    /// (Notizen bleiben sichtbar und exportierbar, docs/AUFTRAG-APPSTORE-V1.md Abschnitt 4)
    private var canWrite: Bool {
        planAllowsWriting && !readOnly && !store.outdatedByNewVersion && !store.journalUnreadable && !store.viewOnlyHere
    }

    /// Tarif mit Schreiben (sonst Schloss mit Weg zur Abo-Seite)
    private var planAllowsWriting: Bool { entitlements.notes.canEdit }

    /// Standardbreite der KI-Hilfe: genug zum Lesen, die PDF behaelt den Grossteil (`TutorPanelWidth.standard`)
    static func tutorWidth(_ total: CGFloat) -> CGFloat { TutorPanelWidth.standard(total) }

    /// Feste Spalten neben der KI-Hilfe (Seitenleiste, Spalte daneben mit Griff): die PDF behaelt daneben ihren Platz
    private func tutorReserved(_ total: CGFloat) -> CGFloat {
        (showSidebar ? 201 : 0) + (hasSidePane ? total * splitFraction + 12 : 0)
    }

    /// Breite der KI-Hilfe: gemerkt (am Rand gezogen) oder Standard, in den Grenzen des Fensters
    private func currentTutorWidth(_ total: CGFloat) -> CGFloat {
        TutorPanelWidth.width(stored: tutorStoredWidth, total: total, reserved: tutorReserved(total))
    }

    /// Griff am inneren Rand der KI-Hilfe (statt der Trennlinie)
    private func tutorHandle(panelOnLeft: Bool, total: CGFloat) -> some View {
        TutorResizeHandle(panelOnLeft: panelOnLeft, total: total, reserved: tutorReserved(total), stored: $tutorStoredWidth)
    }

    /// KI-Hilfe neben der PDF; Seite der Original-PDF aus dem Seitenaufbau (wie der Skriptvorschlag), sonst aus dem
    /// Schluessel, beides beim Senden
    private var tutorPanel: some View {
        TutorPanel(fileID: store.file.id, fileName: store.file.displayTitle,
                   page: { store.entry(forPageIndex: bridge.pageIndex)?.pdfIndex ?? Self.pdfPage(key: bridge.pageKey, index: bridge.pageIndex) },
                   selection: { bridge.controller?.pdfView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" },
                   open: { id, page in if id == store.file.id { bridge.controller?.goToPage(page - 1) } },
                   close: { showTutor = false }, request: $bridge.tutorRequest, attachment: $bridge.tutorAttachment,
                   moduleID: store.file.module_id,                       // "Wochentest erstellen" waehlt das Modul des Dokuments vor
                   // Seitennotizen und Blatt daneben dieser Folie gehen als Kontext mit (05.11.2026)
                   ownNotes: { [store, bridge, api, companionStore] in
                       await AttachedNotes.text(for: store, pageKey: bridge.pageKey, api: api, open: companionStore)
                   })
    }

    /// "Bereich an KI" (05.11.2026): Rahmen ziehen bzw. einkreisen (Werkzeug wie in der Leiste) oder ohne Gesten die
    /// ganze angezeigte Seite
    @ViewBuilder private var areaMenuItems: some View {
        if let lock = aiLock {
            // ohne KI und ohne Pro AI: sichtbar mit Schloss, Antippen oeffnet die Tarifwahl (12.11.2026)
            Button { lockedFeature = .aiHelp } label: { Label(UFLock.label("Bereich an KI …", lock), systemImage: UFLock.symbol) }
                .accessibilityIdentifier("doc.areaAI.pick")
            Button { lockedFeature = .aiHelp } label: { Label(UFLock.label("Ganze Seite an KI", lock), systemImage: UFLock.symbol) }
                .accessibilityIdentifier("doc.areaAI.page")
        } else {
            Button { bridge.controller?.startAreaCapture() } label: { Label("Bereich an KI …", systemImage: "rectangle.dashed") }
                .accessibilityIdentifier("doc.areaAI.pick")
            Button { bridge.controller?.sendVisiblePage() } label: { Label("Ganze Seite an KI", systemImage: "doc.viewfinder") }
                .accessibilityIdentifier("doc.areaAI.page")
        }
    }

    private var isExercise: Bool { SplitSides.isExercise(store.file) }

    // `body` in Teilen, jeder endet mit `ufTypeCut` (Absturz Build 32: der Typ war 115 Ebenen tief, `ViewTypeCut`).
    // Reihenfolge der Modifikatoren wie vorher: Inhalt mit Leisten, Dialoge und Blaetter, zuletzt Hinweise und Aufgaben.

    /// Teil 1: Inhalt (PDF, Seitenleiste, KI-Hilfe, Spalte daneben), Leisten und Ueberlagerungen
    private var documentChrome: AnyView {
        VStack(spacing: 0) {
        // "Oben fest" (12.11.2026): eine Kopfzeile mit Zurueck, Reitern, Werkzeugen und Knoepfen statt Navigationsleiste,
        // Reiterstreifen und Werkzeugleiste; auch waehrend des Ladens (Reiter bleiben bedienbar)
        if usesHeader, !chromeHidden, !fullScreen { editorHeader }
        Group {
            if let error = store.errorMessage {
                ContentUnavailableView("Dokument nicht verfügbar", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if store.pdf != nil {
                VStack(spacing: 0) {
                // Werkzeugleiste (11.11.2026, `EditorToolbar.swift`): oben oder unten fest bzw. schwebend nach der
                // Einstellung (12.11.2026); nicht beim Abpausen, nicht in der Praesentation; ohne Plus mit Schloss
                toolbarSlot(.top)
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        // Seitenleiste auf der Seite der freien Hand (Linkshaender rechts), damit die Schreibhand sie
                        // nicht verdeckt oder beruehrt
                        if showSidebar, scriptLeft, !chromeHidden {
                            PageSidebar(store: store, bridge: bridge, markers: markers, canEdit: canWrite).frame(width: 200)
                            Divider()
                        }
                        if showTutor, scriptLeft, !chromeHidden {
                            tutorPanel.frame(width: currentTutorWidth(geo.size.width))
                            tutorHandle(panelOnLeft: true, total: geo.size.width)
                        }
                        // Spalte daneben links oder rechts (SplitSides); dieselben Ansichten, wenn die Seite wechselt
                        SplitRow(sideLeft: sideLeft) {
                            if hasSidePane, !chromeHidden {
                                sidePane.frame(width: geo.size.width * splitFraction)
                                    .environment(\.ufPaneSwap, paneSwap(width: geo.size.width))
                                splitHandle(width: geo.size.width)
                            }
                            primaryPane
                        }
                        if showTutor, !scriptLeft, !chromeHidden {
                            tutorHandle(panelOnLeft: false, total: geo.size.width)
                            tutorPanel.frame(width: currentTutorWidth(geo.size.width))
                        }
                        if showSidebar, !scriptLeft, !chromeHidden {
                            Divider()
                            PageSidebar(store: store, bridge: bridge, markers: markers, canEdit: canWrite).frame(width: 200)
                        }
                    }
                    .coordinateSpace(NamedCoordinateSpace.named("split"))
                    .overlay {
                        if let d = swapDrag, hasSidePane, !chromeHidden { SplitSwapHint(sideLeft: sideLeft, x: d, width: geo.size.width) }
                    }
                }
                toolbarSlot(.bottom)
                }
            } else {
                ProgressView("Lädt…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(store.file.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(fullScreen || chromeHidden || usesHeader ? .hidden : .visible, for: .navigationBar)
        .toolbar { toolbar }
        .toolbar(removing: .sidebarToggle)                  // eigener Knopf "Seiten"; zwei gleiche Symbole verwirrten
        .overlay(alignment: .bottom) {
            if bridge.objectMode, !chromeHidden { ObjectToolbar(bridge: bridge).padding(.bottom, 12) }
        }
        .overlay(alignment: usesHeader ? .top : .topTrailing) {
            if fullScreen, !tracing {
                if usesHeader {
                    // Vollbild-Schreiben: nur ein kleiner Griff oben in der Mitte holt die Kopfzeile zurueck
                    EditorHeaderRestoreHandle { withAnimation(UF.motion(.default)) { fullScreen = false } }
                } else {
                    Button { fullScreen = false } label: { Label("Vollbild beenden", systemImage: "xmark").padding(10) }
                        .buttonStyle(.borderedProminent).padding()
                        .padding(.top, bridge.toolbar.visible && !chromeHidden ? EditorToolbar.height : 0)   // unter der Leiste
                }
            }
        }
        // Abpausen: Sperre ueber allem, Schloss auf der Seite der freien Hand; Statusleiste und Home-Balken zurueckhaltend
        .overlay { if tracing { TraceLockOverlay(freeze: freeze, leading: scriptLeft) } }
        .statusBarHidden(chromeHidden)
        .persistentSystemOverlays(chromeHidden ? .hidden : .automatic)
        // Praesentation: nur die Seite, unten klein Seitenzahl, Blaettern und Beenden (Esc)
        .overlay(alignment: .bottomTrailing) { if presenting, !tracing { presentationControls } }
        .onChange(of: presenting) { _, on in
            if on { showSidebar = false; showTutor = false }
            bridge.controller?.presentationMode = on
        }
        .defersSystemGestures(on: tracing ? .all : [])
        // Reiterleiste der offenen Dokumente aus: beim Abpausen und in der Praesentation
        .preference(key: EditorTracingKey.self, value: PDFEditorController.isMac ? chromeHidden : tracing)
        // die Kopfzeile zeigt die Reiter selbst: die Bibliothek blendet ihren Streifen aus
        .preference(key: EditorOwnsTabsKey.self, value: usesHeader && tabsEnabled)
        .background {
            // Cmd-L: Ansicht fixieren bzw. loesen (beim Abpausen ohne Wirkung)
            Button("") { requestFreeze(.view) }
                .keyboardShortcut("l", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .ufTypeCut("DocumentView.chrome")
    }

    /// Teil 2: Fixieren, Suche, Menuebefehle, Bild einfuegen, Hinweis, Karteikarte, Vorlesungsmarker
    private var documentPanels: AnyView {
        documentChrome
        .ufModal(isPresented: Binding(get: { freezeIntroFor != nil }, set: { if !$0 { freezeIntroFor = nil } })) {
            FreezeIntroDialog(maxBrightness: $freezeMaxBrightness, contrast: $freezeContrast, start: { mode in
                freezeIntroFor = nil
                startFreeze(mode)
            }, cancel: { freezeIntroFor = nil })
        }
        // App im Hintergrund: Helligkeit vorerst zurueck, beim Zurueckkommen wieder hell
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { freeze.suspend() } else if phase == .active { freeze.resume() }
            // Fenster im Hintergrund gibt das Dokument frei fuer ein anderes Fenster; wieder vorn: ist das Dokument hier
            // nur zum Ansehen und das andere Fenster nicht zu sehen, hier neu oeffnen und schreiben (13.11.2026)
            store.setSceneVisible(phase != .background)
            companionStore?.setSceneVisible(phase != .background)
            if phase == .active { reopenHere(force: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .uniflowDocumentReleased)) { n in
            if n.userInfo?["key"] as? String == store.openKey { reopenHere(force: false) }
        }
        .sheet(isPresented: $showSearch) { SearchSheet(store: store, bridge: bridge) }
        // Menueleiste (Mac, iPad mit Tastatur): Befehle an dieses Dokument
        .focusedSceneObject(bridge)
        .onChange(of: bridge.menuRequest) { _, r in handleMenuRequest(r) }
        .photosPicker(isPresented: $pickingPhoto, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task { insertPicked((try? await item.loadTransferable(type: Data.self)).flatMap(UIImage.init(data:))) }
        }
        .background {
            // eigener Ort fuer die Dateiauswahl (eine zweite `fileImporter` an derselben Ansicht ginge verloren)
            Color.clear.fileImporter(isPresented: $pickingImageFile, allowedContentTypes: [.image]) { result in
                guard case .success(let url) = result else { return }
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                insertPicked((try? Data(contentsOf: url)).flatMap(UIImage.init(data:)))
            }
        }
        .onChange(of: bridge.tutorRequest) { _, r in if r != nil { showTutor = true } }
        // Anhang (markierter Text, Bereich als Bild): KI-Hilfe auf, der Anhang steht im Eingabefeld
        .onChange(of: bridge.tutorAttachment) { _, a in if a != nil, !tracing { showTutor = true } }
        .overlay(alignment: .bottom) {
            if let h = bridge.hint, !chromeHidden {
                Text(h.text).ufFont(13.6, 550, lh: 1.35).foregroundStyle(UF.text)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.horizontal, 24).padding(.bottom, bridge.objectMode ? 96 : 28)
                    .accessibilityIdentifier("doc.hint")
                    .task(id: h.id) {
                        try? await Task.sleep(nanoseconds: 3_500_000_000)
                        if bridge.hint?.id == h.id { bridge.hint = nil }
                    }
            }
        }
        // KI-Hilfe ohne Anhang oeffnen (z. B. "KI erklärt" ohne markierten Text)
        .onChange(of: bridge.askAIRequested) { _, _ in showTutor = true }
        // "Als Karteikarte" (Schritt K): Blatt "Karte anlegen" mit dem markierten Text als Vorderseite
        .onChange(of: bridge.flashcardRequest) { _, r in if let r { openFlashcard(r.question) } }
        .ufModal(isPresented: Binding(get: { flashcardQuestion != nil }, set: { if !$0 { flashcardQuestion = nil } })) {
            if let q = flashcardQuestion {
                FlashcardCreateDialog(deck: flashcards, entitlements: entitlements, question: q, moduleID: store.file.module_id,
                                      fileID: store.file.id)
                    .environment(\.ufClose, { flashcardQuestion = nil })
            }
        }
        .sheet(item: $markerPage) { mp in
            LectureMarkerSheet(api: api, fileID: store.file.id, page: mp.page, pageKey: mp.key, markers: markers,
                               goTo: { pdfPage in
                                   if let i = store.layout?.entries.firstIndex(where: { $0.kind == "pdf" && $0.pdfIndex == pdfPage }) {
                                       bridge.controller?.goToPage(i)
                                   }
                               }, done: { markerNotice = $0 })
        }
        .alert("Vorlesung bis hier", isPresented: Binding(get: { markerNotice != nil }, set: { if !$0 { markerNotice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(markerNotice ?? "") }
        .ufTypeCut("DocumentView.panels")
    }

    /// Teil 3: Blaetter (Info, Papierkorb, Gliederung, Daneben, Loesungen, Abgabe, Export) und alte Fassung
    private var documentSheets: AnyView {
        documentPanels
        .sheet(isPresented: $showInfo) { InfoSheet(store: store) }
        .sheet(isPresented: $showTrash) { PageTrashSheet(bridge: bridge) }
        .sheet(isPresented: $showOutline) { OutlineSheet(bridge: bridge) }
        .onChange(of: ObjectIdentifier(api)) { _, _ in Task { await store.updateAPI(api) } }
        .sheet(isPresented: $choosingCompanion) {
            CompanionPicker(api: api, moduleID: store.file.module_id, excluding: store.file.id, sourceTitle: store.file.displayTitle,
                            linkedSheetIDs: store.sideSheetFileIDs,
                            solutions: foreignLayers.map { ($0.id, $0.label) }, solutionHint: SplitSides.solutionHint(hand: hand),
                            onSolution: { id in
                                if let layer = foreignLayers.first(where: { $0.id == id }) { companion = nil; solutionSide = layer }
                            }, onAppend: { f, template in
                                solutionSide = nil
                                companion = Companion(file: f, pdfPage: nil, appendTemplate: template, request: UUID().uuidString)
                            }) { f in
                solutionSide = nil
                companion = Companion(file: f, pdfPage: nil)
            }
        }
        .sheet(item: $solutionSheet) { sheet in solutionSheetView(sheet) }
        .sheet(isPresented: $submittingToStudIP) { StudIPSubmitEntry(store: store, api: api) }
        .sheet(isPresented: $submittingToMoodle) { MoodleSubmitEntry(store: store, api: api) }
        .sheet(isPresented: $mailingDocument) {
            if let uniMailConnection { UniMailDocumentEntry(store: store, api: api, connection: uniMailConnection) }
        }
        // Schloss angetippt: Tarifwahl mit dem noetigen Tarif vorausgewaehlt (Auftrag des Inhabers 12.11.2026)
        .sheet(item: $lockedFeature) { f in UFPlanSheet(required: f.minimumPlan) { lockedFeature = nil } }
        .fullScreenCover(item: $openedVersion) { v in
            NavigationStack {
                // Vollbild einer frueheren Fassung: derselbe Zurueck-Pfeil wie im Editor schliesst sie (vorher "Schließen")
                DocumentView(file: store.oldVersionFile(v), api: api, readOnly: true, onBack: { openedVersion = nil })
            }
        }
        .fileImporter(isPresented: $importingSolution, allowedContentTypes: [Self.solutionType]) { result in
            importSolution(result)
        }
        .ufModal(isPresented: Binding(get: { pendingExport != nil }, set: { if !$0 { pendingExport = nil } })) {
            if let scope = pendingExport {
                PDFExportNoticeWithSheets(store: store, api: api, open: companionStore, scope: scope, confirm: exportPurpose.confirmTitle,
                                          export: { excluded in
                    pendingExport = nil
                    share(scope, purpose: exportPurpose, excludedSheets: excluded)
                }, cancel: { pendingExport = nil })
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .uniflowSolutionsChanged)) { _ in
            Task { await reloadSolutionLayers() }
        }
        .onChange(of: entitlements.plan) { _, _ in Task { await reloadSolutionLayers() } }
        .sheet(item: Binding(get: { exportFile?.purpose == .save ? exportFile : nil }, set: { exportFile = $0 })) { f in
            // Sichern: Ordner waehlen (iPad: Dateien, Mac: Fenster "Sichern"), die PDF wird dorthin kopiert
            ExportToFolderView(url: f.url) { exportFile = nil }
        }
        .sheet(item: Binding(get: { exportFile?.purpose == .share ? exportFile : nil }, set: { exportFile = $0 })) { f in
            VStack(spacing: 0) {
                if let notice = f.notice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                    Divider()
                }
                ActivityView(items: [f.url])
            }
        }
        .ufTypeCut("DocumentView.sheets")
    }

    /// Teil 4: Eingaben, Seitenwechsel, Laden und Ende
    var body: some View {
        documentSheets
        .alert("Text hinzufügen", isPresented: $addingText) {
            TextField("Text", text: $newText)
            Button("Hinzufügen") {
                let text = newText
                newText = ""
                // ausgeblendete eigene Notizen oder Free = nur ansehen (der Store weist es ebenfalls ab)
                if ownNotesVisible, canWrite, let key = bridge.pageKey { Task { await store.addText(text, pageKey: key) } }
            }
            Button("Abbrechen", role: .cancel) { newText = "" }
        } message: { Text("Erscheint oben links auf der aktuellen Seite und ist im Browser bearbeitbar.") }
        .alert("Gehe zu Seite", isPresented: $goingToPage) {
            TextField("Seite", text: $goToText).keyboardType(.numberPad)
            Button("Springen") {
                if let n = Int(goToText.trimmingCharacters(in: .whitespaces)), let c = bridge.controller, c.pageCount > 0 {
                    c.goToPage(min(max(n, 1), c.pageCount) - 1)
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { Text("1 – \(bridge.controller?.pageCount ?? 1)") }
        .alert("Zur Gliederung hinzufügen", isPresented: $addingOutline) {
            TextField("Titel", text: $outlineTitle)
            Button("Hinzufügen") {
                let title = outlineTitle
                if let key = bridge.pageKey { Task { await bridge.controller?.addOutline(title: title, key: key) } }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { Text("Erscheint unter „Gliederung“ und im Browser in der Seitenleiste.") }
        .confirmationDialog("Alle Notizen auf dieser Seite löschen?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Seite leeren", role: .destructive) {
                if let key = bridge.pageKey { Task { await bridge.controller?.clearPage(key: key) } }
            }
        } message: { Text("Text, Formen und Striche dieser Seite werden entfernt.") }
        .alert("Hinweis", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(actionError ?? "") }
        .onChange(of: bridge.pageIndex) { _, page in
            scheduleSuggestion(page)
            rememberPage(page)
            scheduleSpot()
        }
        // Weitermachen wie zuvor: KI-Hilfe und "Daneben öffnen" fuer den naechsten Start merken (ResumeState.swift)
        .onChange(of: showTutor) { _, open in if !readOnly { router.resume.noteTutor(open: open, of: store.file.id) } }
        .onChange(of: companion) { _, c in
            if !readOnly { router.resume.noteCompanion(id: c?.file.id, page: c?.pdfPage, of: store.file.id) }
        }
        .task {
            await store.load()
            // KI-Start "Im Dokument mit KI-Hilfe öffnen": die KI-Hilfe gleich offen (einmalig, nur fuer diese Datei)
            if router.takeTutorOpenRequest(for: store.file.id) { showTutor = true }
            await restorePanels()
            #if DEBUG
            // -UFDocPanel tutor|companion: Seitenspalte bzw. "Daneben öffnen" gleich offen (nur Bildvergleiche)
            switch UserDefaults.standard.string(forKey: "UFDocPanel") {
            case "tutor": showTutor = true
            case "companion": choosingCompanion = true
            default: break
            }
            // -UFDocFreeze view|trace: gleich fixiert bzw. zum Abpausen eingefroren (Bildvergleiche, Tests); ohne
            // Erklaerung und ohne etwas zu merken
            switch UserDefaults.standard.string(forKey: "UFDocFreeze") {
            case "view": freeze.fixView()
            case "trace": freeze.startTracing(.init(highContrast: freezeContrast))
            default: break
            }
            #endif
            scheduleSuggestion(bridge.pageIndex)
            await reloadSolutionLayers()
            if let sid = correcting { await startCorrection(sid) }
            await takeCorrectionRequest()
            await loadCommunityMatches()
            await loadOwnCorrections()
            if offersLectureMarker { await markers.refresh(api: api, fileID: store.file.id) }
        }
        .onChange(of: correctionLaunch.pending[store.file.id]) { _, r in
            if r != nil, store.pdf != nil { Task { await takeCorrectionRequest() } }
        }
        .modifier(CorrectionDialogs(correction: correction, notePlacement: $notePlacement, noteText: $noteText,
                                    openedNote: $openedNote, editingMessage: $editingCorrectionMessage, message: $correctionMessage,
                                    confirmDiscard: $confirmDiscardCorrection,
                                    discard: { correction?.discard(); correction = nil }))
        // zu sehen oder nicht: ein anderes Fenster darf ein nicht sichtbares Dokument uebernehmen (OpenDocuments)
        .onAppear {
            store.setShown(true)
            reopenHere(force: false)
            // Reiterwechsel: erst Stift und Finger abwarten, Stelle merken, Striche sichern (`DocumentTabList`)
            if tabsEnabled {
                router.tabs.setLeaveGuard(leaveOwner) { [store, bridge, tabs = router.tabs] in
                    await Self.prepareToLeave(store: store, bridge: bridge, tabs: tabs)
                }
            }
        }
        .onChange(of: bridge.zoomPercent) { _, _ in scheduleSpot() }
        .onDisappear {
            if tabsEnabled {
                router.tabs.setSpot(bridge.controller?.currentSpot(), for: store.file.id)
                router.tabs.clearLeaveGuard(leaveOwner)
            }
            spotTask?.cancel()
            freeze.end()                          // Fixieren gilt nur fuer diese Sitzung; Bildschirm wie vorher
            correction?.saveNow()                 // Entwurf der Korrektur bleibt bis Senden oder Verwerfen
            store.setShown(false)
            suggestionTask?.cancel()
            Task { await store.pause() }       // Tabwechsel: weiter synchronisieren; endgueltig beendet beim Schliessen
        }
    }

    /// Hauptspalte mit der PDF; eigener Schnitt, sie steckt tief in Teil 1 (Seitenleiste, Teilung, KI-Hilfe)
    private var primaryPane: AnyView {
        PDFEditorView(store: store, bridge: bridge, pencilOnly: pencilOnly, layoutVersion: store.layoutVersion,
                      tools: tools.tools, ownsToolPicker: true, undoManager: tools.undo, initialPDFPage: initialPDFPage,
                      initialSpot: initialSpot,
                      foreignLayers: correction.map { [$0.target] } ?? shownCorrectionTarget.map { [$0] } ?? foreignLayers,
                      ownNotesVisible: correction == nil && shownCorrectionTarget == nil && ownNotesVisible, canEdit: canWrite,
                      correction: correction, shownCorrection: correction == nil ? shownCorrection : nil,
                      onCorrectionNote: { event in correctionNoteEvent(event) }, aiAvailable: aiEnabled,
                      freezeMode: freeze.mode, traceContrast: freezeContrast, toolbarPlacement: toolbarPlacement)
            .ignoresSafeArea(edges: tracing ? .all : .bottom)
            .overlay(alignment: .bottom) { if !chromeHidden { pageInfo } }
            .overlay(alignment: .topLeading) {
                if freeze.mode == .view { FreezeBadge { freeze.unlock() } }
            }
            .overlay(alignment: .top) {
                if !chromeHidden { VStack(spacing: 6) {
                    if let correction {
                        CorrectionBar(session: correction, send: { await sendCorrection() },
                                      editMessage: { correctionMessage = correction.draft.note; editingCorrectionMessage = true },
                                      pause: { correction.saveNow(); self.correction = nil },
                                      discard: { confirmDiscardCorrection = true })
                    } else if let shownCorrection {
                        ShownCorrectionBanner(correction: shownCorrection, onSolution: shownCorrectionTarget != nil,
                                              ignore: shownCorrection.isForMe && !shownCorrection.isMine ? { ignoreShownCorrection() } : nil) {
                            self.shownCorrection = nil
                            shownCorrectionTarget = nil
                        }
                    } else if !ownCorrections.isEmpty, !ownCorrectionsDismissed {
                        OwnCorrectionsHint(corrections: ownCorrections, open: { c in markCorrectionSeen(c); shownCorrection = c },
                                           dismiss: { ownCorrectionsDismissed = true })
                    }
                    versionBanner
                    communityBanner
                    suggestionBanner
                    // passende Opencast-Aufzeichnung nur bei sicherem Treffer (lokal: der Abgleich des iPads holt sie);
                    // nicht in der alten Fassung (S7, nur ansehen)
                    if api.isLocal, !readOnly, companion == nil, let pdf = store.pdf {
                        RecordingMatchBanner(fileID: store.file.id) { String((pdf.page(at: 0)?.string ?? "").prefix(1500)) }
                    }
                } }
            }
            .ufTypeCut("DocumentView.primaryPane")
    }

    /// Hinweis nach einer neuen Original-Fassung mit Notizen (S7): uebernommen, welche Seiten zu pruefen sind, Weg zur
    /// alten Fassung
    @ViewBuilder
    private var versionBanner: some View {
        if let v = store.versionNotice {
            HStack(spacing: 10) {
                Image(systemName: "doc.badge.clock")
                VStack(alignment: .leading, spacing: 1) {
                    Text(v.noticeTitle).font(.caption).bold()
                    if let detail = v.noticeDetail { Text(detail).font(.caption).lineLimit(2) }
                }
                if v.available {
                    Button("Alte Fassung") { openedVersion = v }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                Button("OK") { Task { await store.dismissVersionNotice() } }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.top, 8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("versionNotice")
        }
    }

    private var hasSidePane: Bool { companion != nil || solutionSide != nil }

    /// Rechte bzw. linke Spalte der geteilten Ansicht: ein zweites Dokument oder eine Loesung zum Ansehen
    @ViewBuilder private var sidePane: some View {
        if let s = solutionSide {
            SolutionSidePane(layer: s, source: store.offscreenPDF) { solutionSide = nil }
                .id("solution-" + s.id)
        } else if let c = companion {
            companionPane(c)
        }
    }

    private func companionPane(_ c: Companion) -> some View {
        CompanionView(file: c.file, api: api, pdfPage: c.pdfPage, tools: tools.tools, undoManager: tools.undo,
                      pencilOnly: pencilOnly, canEdit: canWrite, viewLocked: freeze.locksView, appendTemplate: c.appendTemplate,
                      onStore: { [store, bridge] s, shown in
                          // SwiftUI garantiert die Reihenfolge von Erscheinen (neu) und Verschwinden (alt) nicht
                          if shown { companionStore = s } else if companionStore === s { companionStore = nil }
                          Self.linkSideSheet(s, shown: shown, main: store, bridge: bridge)
                      }) { [bridge] in
            // wo das Blatt danach zu finden ist (Fehlerbericht 13.11.2026: geschlossen, dann nirgends mehr gesehen)
            if c.file.isNotebook { bridge.hint = .init(text: Self.sheetClosedHint(c.file.displayTitle)) }
            companion = nil
        }
        .id(c.id + "-" + String(c.pdfPage ?? -1) + c.request)
    }

    /// Nur zum Ansehen, weil ein anderes Fenster das Dokument haelt: hier neu oeffnen und schreiben. `force`: "Hier
    /// bearbeiten" (das andere Fenster gibt ab, auch wenn es zu sehen ist); sonst nur, wenn das andere Fenster nicht zu
    /// sehen ist (im Hintergrund, Dokument dort geschlossen). Nur in der Dokumentansicht der App (Reiter), nicht in alten
    /// Fassungen oder ZIP-Ordnern.
    private func reopenHere(force: Bool) {
        guard tabsEnabled, store.canTakeOverHere, force || !store.writerElsewhereShown, !reopening else { return }
        reopening = true
        Task {
            if force { await store.takeOverFromOtherWindow() }
            await store.close()
            DocumentReopen.shared.reopen(store.file.id)
        }
    }

    /// Hinweis nach dem Schliessen eines Blatts daneben: gespeichert, und wo es wieder auftaucht
    static func sheetClosedHint(_ title: String) -> String {
        "„\(title)“ ist gespeichert. Wieder öffnen: „Geteilt“ › Deine Blätter, Bibliothek › Eigene Notizen oder „Zuletzt benutzt“."
    }

    /// Blatt daneben (Notizbuch): wer darauf schreibt, schreibt neben der gerade angezeigten Seite dieses Dokuments.
    /// Das Dokument merkt sich je Blattseite die erste Seite (docs/NOTIZEN-MITSCHICKEN-2026-11-05.md), damit die
    /// Notizen beim Teilen, Exportieren und Abgeben direkt hinter dieser Folie mitgehen.
    static func linkSideSheet(_ sheet: DocumentStore, shown: Bool, main: DocumentStore, bridge: EditorBridge) {
        guard shown, sheet.isNotebook, sheet.file.id != main.file.id else {
            if !shown { sheet.onLocalEdit = nil }
            return
        }
        sheet.onLocalEdit = { [weak main, weak bridge, weak sheet] sheetPage in
            guard let main, let sheet, let mainKey = bridge?.pageKey else { return }
            Task { await main.linkSideSheet(file: sheet.file.id, sheetPage: sheetPage, to: mainKey) }
        }
    }

    private func splitHandle(width: CGFloat) -> some View {
        ZStack {
            UF.line.frame(width: 1)
            Capsule().fill(UF.lineStrong).frame(width: 5, height: 44)
        }
        .frame(width: 12)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: NamedCoordinateSpace.named("split")).onChanged { g in
            let x = g.location.x
            let f = sideLeft ? x / max(width, 1) : (width - x) / max(width, 1)
            splitFraction = min(0.65, max(0.2, Double(f)))
        })
        .accessibilityLabel("Breite der geteilten Ansicht")
    }

    @ViewBuilder
    private var suggestionBanner: some View {
        if companion == nil, let suggestionError {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                Text(suggestionError).font(.caption).lineLimit(2)
                Button { self.suggestionError = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("Hinweis ausblenden")
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.top, 8)
        } else if companion == nil, let s = suggestion, s.forPage == bridge.pageIndex, !dismissedSuggestions.contains(s.forPage) {
            HStack(spacing: 10) {
                Image(systemName: "book")
                VStack(alignment: .leading, spacing: 1) {
                    Text("Passende Skriptstelle").font(.caption).bold()
                    Text("\(s.title) · Seite \(s.page)").font(.caption).lineLimit(1)
                }
                Button("Daneben öffnen") {
                    if entitlements.allows(.splitView) {
                        solutionSide = nil
                        companion = Companion(file: libFile(id: s.fileID, title: s.title), pdfPage: s.page)
                    } else {
                        lockedFeature = .splitView
                    }
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                Button { dismissedSuggestions.insert(s.forPage) } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Für diese Seite ausblenden")
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.top, 8)
            .help("Gemeinsame Begriffe: \(s.terms.joined(separator: ", "))")
        }
    }

    private func libFile(id: String, title: String) -> LibFile {
        LibFile(id: id, name: title + ".pdf", title: title, kind: "pdf", module_id: store.file.module_id, subject: store.file.subject,
                doc_type: "vorlesung", ai_title: title, sub_label: nil, downloaded_at: "unbekannt", has_notes: nil,
                page_count: nil, studip_folder: nil)
    }

    /// Skriptsuche hoechstens einmal je Seite und erst nach 2,5 s Ruhe (keine Anfrage bei jeder Stiftbewegung).
    private func scheduleSuggestion(_ page: Int) {
        suggestionTask?.cancel()
        guard isExercise, companion == nil else { return }
        if let cached = suggestionCache[page] { suggestion = cached; return }
        suggestionTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, let pdfPage = store.entry(forPageIndex: page)?.pdfIndex else { return }
            do {
                let r = try await api.value("/api/related", method: "POST",
                                            body: .object(["file_id": .string(store.file.id), "page": .number(Double(pdfPage))]))
                let hit = r.list("results").first
                let s = hit.flatMap { h -> ScriptSuggestion? in
                    guard let id = h.s("file_id"), let p = h.i("page") else { return nil }
                    return ScriptSuggestion(fileID: id, title: h.s("title") ?? h.s("name") ?? "Skript", page: p,
                                            terms: h.list("terms").compactMap { $0.string }, forPage: page)
                }
                suggestionCache[page] = .some(s)
                if bridge.pageIndex == page { suggestion = s; suggestionError = nil }
            } catch {
                // Skriptsuche gescheitert: einmal sichtbar statt still (die naechste Seite versucht es wieder)
                guard !Task.isCancelled, bridge.pageIndex == page else { return }
                suggestionError = "Skriptsuche nicht möglich: \(error.localizedDescription)"
            }
        }
    }

    /// Seite der PDF zur angezeigten Seite: Originalseiten heissen "p<N>" (Seitenaufbau), sonst die Position
    static func pdfPage(key: String?, index: Int) -> Int {
        if let key, key.hasPrefix("p"), let n = Int(key.dropFirst()), n >= 1 { return n }
        return index + 1
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            // Zurueck (06.11.2026): schliesst das Dokument dorthin, wo es geoeffnet wurde (vorige Seite, sonst Startseite)
            UFBackButton(style: .toolbar, action: onBack)
            UFLogoMenu()                                       // die App-Leiste ist im Editor aus (mehr Platz zum Schreiben)
            Button { withAnimation(UF.motion(.default)) { showSidebar.toggle() } } label: {
                Label("Seiten", systemImage: "rectangle.stack")
            }
            // Rueckgaengig und Wiederholen stehen in der festen Werkzeugleiste (iPad und Mac, derselbe Verlauf fuer
            // Striche, Objekte und eingefuegte Seiten); am Mac dort mit Cmd-Z und Umschalt-Cmd-Z (Befund 09.11.2026)
            if !planAllowsWriting && !readOnly {
                // Free: Schloss mit Weg zur Abo-Seite statt still nicht schreibender Stift
                Button { lockedFeature = .pencilWriting } label: {
                    Label(UFLock.label("Schreiben", UFFeature.pencilWriting.minimumPlan), systemImage: UFLock.symbol)
                }
                .labelStyle(.titleAndIcon)
                .accessibilityValue(UFLock.accessibilityValue(UFFeature.pencilWriting.minimumPlan))
            }
        }
        // Rechts in Gruppen nach Aufgabe (Design-Ueberarbeitung 03.11.2026; vorher elf Knoepfe in einer Reihe):
        // Stand (kein Knopf, ohne Glasflaeche) | Lesen und Nachschlagen | Schreiben | Teilen und Mehr
        ToolbarItemGroup(placement: .topBarTrailing) {
            if task != nil, !readOnly {
                Button { Task { await markTaskDone() } } label: {
                    Label(taskDone ? "Erledigt ✓" : "Erledigt", systemImage: taskDone ? "checkmark.circle.fill" : "checkmark.circle")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(taskDone)
                .accessibilityIdentifier("doc.task.done")
            }
        }
        UFPlainToolbarItem {
            HStack(spacing: 4) {
                StatusLabel(status: store.status)
                SyncIssueBadge(store: store)
            }
        }
        UFToolbarGap()
        ToolbarItemGroup(placement: .topBarTrailing) {
            if offersLectureMarker {
                Button { openLectureMarker() } label: {
                    Label("Vorlesung bis hier", systemImage: markers.needsReview ? "bookmark.trianglebadge.exclamationmark" : "bookmark")
                }
                .tint(markers.needsReview ? UF.warn : nil)
                .help(markers.needsReview ? "Ein Marker muss nach einer Dokumentänderung geprüft werden"
                                          : "Vorlesung bis hier: letzte behandelte Seite markieren")
                .accessibilityIdentifier("doc.lectureMarker")
            }
            Button { showSearch = true } label: { Label("Suchen", systemImage: "magnifyingglass") }
            if !proAIOfferHidden {                          // nur Store-Bilder der Fassung nur mit Plus blenden ihn aus
                Button { toggleTutor() } label: {
                    // Symbol bleibt das der KI (Entscheidung: in der Kopfzeile traegt nur "Schreiben" das Schloss); die Sperre
                    // nennen Text und VoiceOver "(ab Pro AI)", Antippen oeffnet die Tarifwahl
                    Label(showTutor ? "KI-Hilfe schließen" : aiLock.map { UFLock.label("KI-Hilfe", $0) } ?? "KI-Hilfe",
                          systemImage: "sparkles")
                }
                    .accessibilityIdentifier("doc.tutor")
                    .contextMenu { areaMenuItems }
            }
            Button { toggleSplit() } label: {
                // immer das Symbol der Teilung (in der Kopfzeile traegt nur "Schreiben" das Schloss); die Sperre nennt der
                // Text einheitlich "(ab Plus)" (12.11.2026)
                Label(!hasSidePane ? Self.lockedLabel("Geteilt", entitlements.access(.splitView)) : "Teilung beenden",
                      systemImage: "rectangle.split.2x1")
            }
            .contextMenu {
                // auch fuer Bedienungshilfen: dasselbe wie Ziehen an der Kopfzeile der Spalte daneben
                if hasSidePane {
                    Button { swapSides() } label: { Label(UFPaneSwap.actionName, systemImage: "arrow.left.arrow.right") }
                        .accessibilityIdentifier("doc.split.swap")
                }
            }
        }
        UFToolbarGap()
        ToolbarItemGroup(placement: .topBarTrailing) {
            // unser Schalter (Standard: nur der Stift schreibt, der Finger blaettert); die iPadOS-Einstellung gilt nicht
            // (siehe `EditorPalette`). Mac: "Maus blättert" / "Maus schreibt"
            // (EditorPointer, 09.11.2026)
            let penLabel = EditorPointer.toggleLabel(isMac: PDFEditorController.isMac, pencilOnly: pencilOnly)
            Button {
                pencilOnly.toggle()
                if PDFEditorController.isMac { bridge.hint = EditorBridge.Hint(text: EditorPointer.macHint(pencilOnly: pencilOnly)) }
            } label: {
                Label(penLabel.title, systemImage: penLabel.icon)
            }
            .modifier(MacHelp(text: EditorPointer.macHint(pencilOnly: pencilOnly)))
            .accessibilityIdentifier("doc.pencilOnly")
            layersMenu
        }
        UFToolbarGap()
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu { shareMenuItems } label: { Label(exporting ? "Exportiert…" : "Teilen", systemImage: "square.and.arrow.up") }
                .disabled(exporting || store.pdf == nil)
            Menu { moreMenuItems } label: { Label("Mehr", systemImage: "ellipsis.circle") }
        }
    }

    /// KI-Hilfe auf oder zu; ohne KI und ohne Pro AI das Schloss (Tarifwahl, 12.11.2026). Markierter Text geht als
    /// Anhang mit (sichtbar im Eingabefeld), statt erst beim Senden gelesen zu werden
    private func toggleTutor() {
        if aiLock != nil, !showTutor { lockedFeature = .aiHelp; return }
        if !showTutor, let a = bridge.controller?.selectionAttachment() { bridge.tutorAttachment = a }
        showTutor.toggle()
    }

    /// Daneben oeffnen (zweites Dokument oder Loesung) bzw. Teilung beenden; ohne Plus das Schloss
    private func toggleSplit() {
        if hasSidePane { companion = nil; solutionSide = nil }
        else if entitlements.allows(.splitView) { choosingCompanion = true }
        else { lockedFeature = .splitView }
    }

    // MARK: Eine Kopfzeile ("Oben fest", 12.11.2026)

    /// Zurueck, Reiter, Werkzeuge, Knoepfe in einer Zeile (`EditorHeaderBar`); eigene Typen hinter Schnitten, damit
    /// `documentChrome` flach bleibt (`ViewTypeDepthAppTests`)
    private var editorHeader: AnyView {
        EditorHeaderBar(leading: { layout in headerLeading(layout) }, tools: headerTools, actions: { layout in headerActions(layout) })
            .ufTypeCut("DocumentView.header")
    }

    private func headerLeading(_ layout: EditorHeaderLayout) -> AnyView {
        HStack(spacing: 0) {
            // Zurueck: schliesst das Dokument dorthin, wo es geoeffnet wurde (die Reiter bleiben)
            UFBackButton(style: .header, compact: true, action: onBack)
                .frame(width: EditorToolbar.hitSide, height: EditorToolbar.hitSide)
            DocumentTabStrip(tabs: router.tabs, currentID: store.file.id, currentTitle: store.file.displayTitle,
                             maxWidth: layout.tabMaxWidth, asMenu: layout.tabsAsMenu, enabled: tabsEnabled)
        }
        .padding(.leading, 4)
        .ufTypeCut("DocumentView.headerLeading")
    }

    /// Werkzeuge in der Zeile: die Leiste (schreiben erlaubt), ohne Plus dieselbe mit Schloss, sonst nichts (lesen)
    private var headerTools: AnyView? {
        if bridge.toolbar.visible { return toolbarStrip(embedded: true).ufTypeCut("DocumentView.headerTools") }
        if writingLocked, let plan = UFLock.plan(.pencilWriting, plan: entitlements.plan) {
            return EditorLockedToolbar(plan: plan, embedded: true)
                .ufTypeCut("DocumentView.headerTools")
        }
        return nil
    }

    /// Rechts: Stand, Seiten, KI, Daneben, Teilen, Mehr, Leiste ausblenden; schmal nur KI und Mehr (der Rest im Menue)
    private func headerActions(_ layout: EditorHeaderLayout) -> AnyView {
        HStack(spacing: 0) {
            if task != nil, !readOnly {
                EditorHeaderButton(title: taskDone ? "Erledigt ✓" : "Erledigt", icon: taskDone ? "checkmark.circle.fill" : "checkmark.circle",
                                   selected: taskDone, identifier: "doc.task.done") { Task { await markTaskDone() } }
                    .disabled(taskDone)
            }
            // Stand nur bei Problemen in der Zeile (offline, nicht gesichert, Konflikt); sonst oben im Menue "Mehr"
            if StatusLabel.needsAttention(store.status) {
                StatusLabel(status: store.status).padding(.horizontal, 2)
            }
            SyncIssueBadge(store: store)
            if !layout.compactActions {
                EditorHeaderButton(title: "Seiten", icon: "rectangle.stack", selected: showSidebar, identifier: "doc.pages") {
                    withAnimation(UF.motion(.default)) { showSidebar.toggle() }
                }
            }
            headerAIButton(narrow: layout.narrow)
            if !layout.compactActions {
                EditorHeaderButton(title: !hasSidePane ? Self.lockedLabel("Geteilt", entitlements.access(.splitView)) : "Teilung beenden",
                                   icon: "rectangle.split.2x1", selected: hasSidePane, identifier: "doc.split") { toggleSplit() }
                    .contextMenu {
                        if hasSidePane {
                            Button { swapSides() } label: { Label(UFPaneSwap.actionName, systemImage: "arrow.left.arrow.right") }
                        }
                    }
                Menu { shareMenuItems } label: { EditorHeaderMenuLabel(icon: "square.and.arrow.up") }
                    .disabled(exporting || store.pdf == nil)
                    .accessibilityLabel(exporting ? "Exportiert…" : "Teilen")
                    .accessibilityIdentifier("doc.share")
            }
            Menu { headerMoreItems(compact: layout.compactActions) } label: { EditorHeaderMenuLabel(icon: "ellipsis.circle") }
                .accessibilityLabel("Mehr")
                .accessibilityIdentifier("doc.more")
            if !layout.compactActions {
                EditorHeaderButton(title: "Leiste ausblenden", icon: "arrow.up.left.and.arrow.down.right", identifier: "editor.header.hide") {
                    withAnimation(UF.motion(.default)) { fullScreen = true }
                }
            }
        }
        .padding(.trailing, 4)
        .ufTypeCut("DocumentView.headerActions")
    }

    /// KI-Hilfe (auch mit markiertem Text als Anhang); ohne KI und ohne Pro AI mit Schloss (Tarifwahl)
    @ViewBuilder private func headerAIButton(narrow: Bool) -> some View {
        if !proAIOfferHidden {
            if let lock = aiLock, !showTutor, narrow {
                // sehr schmal: Symbol mit kleinem Schloss statt Schild "ab Pro AI"
                EditorHeaderButton(title: "KI-Hilfe", icon: "sparkles", identifier: "toolbar.askAI.locked") { lockedFeature = .aiHelp }
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: UFLock.symbol).font(.system(size: 8, weight: .bold)).foregroundStyle(UF.accentText)
                            .offset(x: -8, y: 9).accessibilityHidden(true)
                    }
                    .ufLockAccessibility(lock)
            } else if let lock = aiLock, !showTutor {
                UFLockedButton(plan: lock, title: "KI-Hilfe", identifier: "toolbar.askAI.locked") {
                    Image(systemName: "sparkles").font(.system(size: 17, weight: .medium)).foregroundStyle(UF.text)
                }
            } else {
                EditorHeaderButton(title: showTutor ? "KI-Hilfe schließen" : "KI-Hilfe", icon: "sparkles", selected: showTutor,
                                   identifier: "doc.tutor") { toggleTutor() }
                    .contextMenu { areaMenuItems }
            }
        }
    }

    /// Menue "Mehr" der Kopfzeile: was frueher einzeln in der Navigationsleiste stand (Suchen, Vorlesung bis hier,
    /// Stift/Finger, Ebenen), schmal dazu Seiten, Daneben und Teilen, dann das bisherige Menue "Mehr"
    @ViewBuilder private func headerMoreItems(compact: Bool) -> some View {
        Section(store.status.label) {
            Button { showSearch = true } label: { Label("Suchen", systemImage: "magnifyingglass") }
            if offersLectureMarker {
                Button { openLectureMarker() } label: {
                    Label("Vorlesung bis hier", systemImage: markers.needsReview ? "bookmark.trianglebadge.exclamationmark" : "bookmark")
                }
            }
            let penLabel = EditorPointer.toggleLabel(isMac: PDFEditorController.isMac, pencilOnly: pencilOnly)
            Button {
                pencilOnly.toggle()
                if PDFEditorController.isMac { bridge.hint = EditorBridge.Hint(text: EditorPointer.macHint(pencilOnly: pencilOnly)) }
            } label: { Label(penLabel.title, systemImage: penLabel.icon) }
            layersMenu
        }
        if compact {
            Section {
                Button { withAnimation(UF.motion(.default)) { showSidebar.toggle() } } label: {
                    Label(showSidebar ? "Seiten ausblenden" : "Seiten", systemImage: "rectangle.stack")
                }
                Button { toggleSplit() } label: {
                    Label(!hasSidePane ? Self.lockedLabel("Geteilt", entitlements.access(.splitView)) : "Teilung beenden",
                          systemImage: "rectangle.split.2x1")
                }
                Menu { shareMenuItems } label: { Label(exporting ? "Exportiert…" : "Teilen", systemImage: "square.and.arrow.up") }
                    .disabled(exporting || store.pdf == nil)
            }
        }
        moreMenuItems
    }

    /// Inhalt des Menues "Teilen" (Navigationsleiste und Kopfzeile)
    private var shareMenuItems: AnyView {
        Group {
                // A) privat: Original-PDF mit Notizen (auch in Free), vorher Hinweis auf das Originalmaterial
                Section("PDF exportieren (nur privat)") {
                    Button { startExport(.document, .share) } label: { Label("Ganzes Dokument", systemImage: "doc.on.doc") }
                    Button { startExport(.page(bridge.pageIndex), .share) } label: { Label("Diese Seite", systemImage: "doc") }
                    Button { startExport(.document, .save) } label: { Label("Als PDF sichern …", systemImage: "square.and.arrow.down") }
                    Button { startExport(.document, .print) } label: { Label("Drucken …", systemImage: "printer") }
                }
                // B) nur eigene Notizen, ohne Original (Teilen ab Plus; "Meine geteilten Lösungen" mit Zurueckziehen fuer alle)
                Section("Nur eigene Notizen") {
                    Button { openSolutionSheet(.share) } label: {
                        Label(Self.lockedLabel("Lösung teilen …", entitlements.access(.shareSolutions)),
                              systemImage: entitlements.allows(.shareSolutions) ? "person.2" : UFLock.symbol)
                    }
                    Button { openSolutionSheet(.shared) } label: { Label("Meine geteilten Lösungen …", systemImage: "tray.full") }
                }
                // C) eigene Loesung mit Notizen in Stud.IP hochladen (Entscheidung des Inhabers 05.11.2026)
                if StudIPSubmitEntry.offered(api: api, readOnly: readOnly || store.isOldVersion) {
                    Section("Abgeben") {
                        Button { submittingToStudIP = true } label: {
                            Label {
                                Text("In Stud.IP abgeben …")
                                if let last = StudIPSubmitEntry.lastLine(documentID: store.file.id) { Text(last) }
                            } icon: { Image(systemName: "tray.and.arrow.up") }
                        }
                        .accessibilityIdentifier("doc.submitStudIP")
                    }
                }
                // Hochschule Hannover: in einer Moodle-Aufgabe abgeben (Entwurf, dann ausdruecklich "Jetzt abgeben")
                if MoodleSubmitEntry.offered(api: api, readOnly: readOnly || store.isOldVersion, hsh: hshConnection) {
                    Section("Abgeben") {
                        Button { submittingToMoodle = true } label: { Label("In Moodle abgeben …", systemImage: "tray.and.arrow.up") }
                            .accessibilityIdentifier("doc.submitMoodle")
                    }
                }
                // Uni Hildesheim: in einer Learnweb-Aufgabe abgeben (dasselbe Blatt, Sitzung des Learnwebs, 05.11.2026)
                if MoodleSubmitEntry.offeredLearnweb(api: api, readOnly: readOnly || store.isOldVersion, hildesheim: hildesheimConnection) {
                    Section("Abgeben") {
                        Button { submittingToMoodle = true } label: { Label("Im Learnweb abgeben …", systemImage: "tray.and.arrow.up") }
                            .accessibilityIdentifier("doc.submitLearnweb")
                    }
                }
                // LUH, Uni Hildesheim: als PDF mit Notizen an eine neue Uni-Mail (SOGo), gesendet erst mit "Senden"
                if UniMailDocumentEntry.offered(api: api, connection: uniMailConnection) {
                    Section("Per E-Mail") {
                        Button { mailingDocument = true } label: { Label("Per Uni-Mail senden …", systemImage: "envelope") }
                            .accessibilityIdentifier("doc.uniMail")
                    }
                }
        }
        .ufTypeCut("DocumentView.shareMenu")
    }

    /// Inhalt des Menues "Mehr" (Navigationsleiste und Kopfzeile)
    private var moreMenuItems: AnyView {
        Group {
                // "Bereich an KI" auch ohne Leiste und ohne Schreiben im Tarif (05.11.2026)
                Section("KI-Hilfe") { areaMenuItems }
                if !planAllowsWriting && !readOnly {
                    // Free: jeder schreibende Eintrag sichtbar mit Schloss (statt grau), Antippen oeffnet die Tarifwahl
                    // (Auftrag des Inhabers 12.11.2026); eigener Typ, damit das Menue flach bleibt
                    EditorLockedWriteItems(plan: UFFeature.pencilWriting.minimumPlan, bookmarked: store.isBookmarked(pageKey: bridge.pageKey)) {
                        lockedFeature = .pencilWriting
                    }
                    Divider()
                } else if !ownNotesVisible {
                    // nur ansehen: schreibende Eintraege sind gesperrt
                    Button { ownNotesVisible = true } label: {
                        Label("Meine Notizen einblenden, um zu bearbeiten", systemImage: "eye")
                    }
                    Divider()
                }
                // schreiben ins eigene Dokument: gesperrt, solange "Meine Notizen" ausgeblendet ist; ohne Plus stehen die
                // Eintraege oben mit Schloss
                if planAllowsWriting || readOnly {
                Group {

                    Button {
                        if let key = bridge.pageKey {
                            let title = "Seite \(bridge.pageIndex + 1)"
                            Task { await store.toggleBookmark(pageKey: key, title: title) }
                        }
                    } label: {
                        Label(store.isBookmarked(pageKey: bridge.pageKey) ? "Lesezeichen entfernen" : "Lesezeichen setzen", systemImage: "bookmark")
                    }
                    Menu {
                        Section("Wie aktuelle Seite") {
                            ForEach(PaperTemplate.choices, id: \.id) { t in
                                // ueber den Editor: Groesse und Schluessel wie im Web, danach springt er zur neuen Seite
                                Button(t.name) { Task { await bridge.controller?.insertBlankPage(after: bridge.pageKey, template: t.id) } }
                            }
                        }
                        // Formate wie formats.js (Seite hinzufuegen im Web): A6 ... A2 hoch und quer, Whiteboards
                        Menu("Anderes Format") {
                            ForEach(PageFormats.paper, id: \.key) { f in
                                ForEach(PageFormats.Orientation.allCases, id: \.self) { o in
                                    blankPageMenu(o == .portrait ? "\(f.name) hoch" : "\(f.name) quer", format: f.key, orientation: o)
                                }
                            }
                            Section("Whiteboard (immer quer)") {
                                ForEach(PageFormats.whiteboards, id: \.key) { f in blankPageMenu(f.name, format: f.key, orientation: .landscape) }
                            }
                        }
                    } label: { Label("Leere Seite danach", systemImage: "doc.badge.plus") }
                    Button(role: .destructive) {
                        Task {
                            if await bridge.controller?.trashPage(key: bridge.pageKey) != true {
                                actionError = "Diese Seite lässt sich nicht in den Papierkorb legen (letzte Seite oder noch nicht geladen)."
                            }
                        }
                    } label: { Label("Seite in den Papierkorb", systemImage: "trash") }
                    Button { showTrash = true } label: { Label("Papierkorb …", systemImage: "trash.slash") }
                    Button {
                        if let key = bridge.pageKey { Task { await store.rotatePage(key: key) } }
                    } label: { Label("Seite drehen", systemImage: "rotate.right") }
                    Button { addingText = true } label: { Label("Text hinzufügen", systemImage: "textformat") }
                    Button { pickingPhoto = true } label: { Label("Bild aus Fotos …", systemImage: "photo") }
                    Button { pickingImageFile = true } label: { Label("Bild aus Dateien …", systemImage: "folder") }
                    Button { bridge.toggleMagnifier() } label: {
                        Label(bridge.magnifierOpen ? "Schreiblupe schließen" : "Schreiblupe", systemImage: "rectangle.and.text.magnifyingglass")
                    }
                    pageToolsMenu
                }
                .disabled(!ownNotesVisible || !canWrite)
                }
                Button { goToText = ""; goingToPage = true } label: { Label("Gehe zu Seite …", systemImage: "arrow.right.to.line") }
                Button { showOutline = true } label: { Label("Gliederung …", systemImage: "list.bullet.indent") }
                Divider()
                Button {
                    if entitlements.allows(.communityRead) { importingSolution = true } else { solutionSheet = .locked(.communityRead) }
                } label: { Label("Lösung importieren …", systemImage: "square.and.arrow.down") }
                if !store.versions.isEmpty {
                    // S7: aufbewahrte alte Fassungen mit ihren Notizen (nur zum Ansehen)
                    Section("Alte Fassungen") {
                        ForEach(store.versions) { v in
                            Button { openedVersion = v } label: { Label(v.label, systemImage: "doc.badge.clock") }
                                .disabled(!v.available)
                        }
                    }
                }
                Button { showInfo = true } label: { Label("Dokumentinformation", systemImage: "info.circle") }
                Button { withAnimation(UF.motion(.default)) { fullScreen = true } } label: {
                    Label(usesHeader ? "Vollbild-Schreiben (Leiste ausblenden)" : "Vollbild", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .accessibilityIdentifier("doc.fullScreen")
                Button { presenting = true } label: { Label("Präsentieren", systemImage: "play.rectangle") }
                    .accessibilityIdentifier("doc.present")
                if DocumentWindows.supported, !readOnly {
                    Button { openInNewWindow() } label: { Label("In neuem Fenster öffnen", systemImage: "macwindow.badge.plus") }
                        .accessibilityIdentifier("doc.newWindow")
                }
                // Bildschirm fixieren (technische Zeichnungen, Abpausen; docs/FIXIEREN-ABPAUSEN-2026-11-05.md)
                Section(FreezeTexts.introTitle) {
                    Button { requestFreeze(.view) } label: {
                        Label(freeze.mode == .view ? FreezeTexts.releaseView : FreezeTexts.fixView,
                              systemImage: freeze.mode == .view ? "lock.open" : "lock")
                    }
                    .accessibilityIdentifier("doc.freeze.view")
                    Button { requestFreeze(.trace) } label: { Label(FreezeTexts.trace, systemImage: "lock.rectangle") }
                        .accessibilityIdentifier("doc.freeze.trace")
                    if !PDFEditorController.isMac {
                        Toggle(isOn: $freezeMaxBrightness) { Label(FreezeTexts.brightness, systemImage: "sun.max") }
                    }
                    Toggle(isOn: $freezeContrast) { Label(FreezeTexts.contrast, systemImage: "circle.lefthalf.filled") }
                }
        }
        .ufTypeCut("DocumentView.moreMenu")
    }

    /// Untermenue "Seite" wie das Seitenmenue im Web-Editor: kopieren, verschieben, Leerseite davor/am Ende, Vorlage und
    /// Format (nur Leerseiten), Gliederung, leeren
    @ViewBuilder private var pageToolsMenu: some View {
        let isBlank = bridge.controller?.pageEntry(key: bridge.pageKey)?.kind == "blank"
        Menu {
            Button { Task { await bridge.controller?.duplicatePage(key: bridge.pageKey) } } label: {
                Label("Seite kopieren", systemImage: "plus.square.on.square")
            }
            Menu {
                Button("Nach vorne") { Task { await bridge.controller?.movePage(key: bridge.pageKey, to: .forward) } }
                Button("Nach hinten") { Task { await bridge.controller?.movePage(key: bridge.pageKey, to: .backward) } }
                Button("An den Anfang") { Task { await bridge.controller?.movePage(key: bridge.pageKey, to: .first) } }
                Button("Ans Ende") { Task { await bridge.controller?.movePage(key: bridge.pageKey, to: .last) } }
            } label: { Label("Seite verschieben", systemImage: "arrow.up.arrow.down") }
            Menu {
                ForEach(PaperTemplate.choices, id: \.id) { t in
                    Button(t.name) { if let key = bridge.pageKey { Task { await bridge.controller?.insertBlankPage(before: key, template: t.id) } } }
                }
            } label: { Label("Leere Seite davor", systemImage: "doc.badge.plus") }
            Menu {
                ForEach(PaperTemplate.choices, id: \.id) { t in
                    Button(t.name) { Task { await bridge.controller?.appendBlankPage(template: t.id) } }
                }
            } label: { Label("Leere Seite am Ende", systemImage: "doc.badge.plus") }
            if isBlank {
                Menu {
                    ForEach(PaperTemplate.choices, id: \.id) { t in
                        Button(t.name) { Task { await bridge.controller?.setTemplate(t.id, key: bridge.pageKey) } }
                    }
                } label: { Label("Vorlage wechseln", systemImage: "squareshape.split.3x3") }
                Menu {
                    ForEach(PageFormats.paper, id: \.key) { f in
                        ForEach(PageFormats.Orientation.allCases, id: \.self) { o in
                            if let size = PageFormats.size(f.key, o) {
                                Button(o == .portrait ? "\(f.name) hoch" : "\(f.name) quer") {
                                    Task { await bridge.controller?.setFormat(CGSize(width: size.width, height: size.height), key: bridge.pageKey) }
                                }
                            }
                        }
                    }
                    Section("Whiteboard (immer quer)") {
                        ForEach(PageFormats.whiteboards, id: \.key) { f in
                            if let size = PageFormats.size(f.key, .landscape) {
                                Button(f.name) {
                                    Task { await bridge.controller?.setFormat(CGSize(width: size.width, height: size.height), key: bridge.pageKey) }
                                }
                            }
                        }
                    }
                } label: { Label("Seitenformat ändern", systemImage: "rectangle.portrait.and.arrow.right") }
            }
            Button { outlineTitle = "Seite \(bridge.pageIndex + 1)"; addingOutline = true } label: {
                Label("Zur Gliederung hinzufügen", systemImage: "list.bullet.indent")
            }
            Button(role: .destructive) { confirmClear = true } label: { Label("Seite leeren", systemImage: "eraser") }
        } label: { Label("Seite", systemImage: "doc.on.doc") }
    }

    /// Untermenue "Leere Seite danach > Anderes Format > <Format>": Vorlage waehlen, Seite in diesem Format einfuegen
    private func blankPageMenu(_ title: String, format: String, orientation: PageFormats.Orientation) -> some View {
        Menu(title) {
            if let s = PageFormats.size(format, orientation) {
                ForEach(PaperTemplate.choices, id: \.id) { t in
                    Button(t.name) {
                        Task {
                            await bridge.controller?.insertBlankPage(after: bridge.pageKey, template: t.id,
                                                                     size: CGSize(width: s.width, height: s.height))
                        }
                    }
                }
            }
        }
    }

    // MARK: Loesungen (nur eigene Notizen teilen, fremde Loesungen ansehen)

    static var solutionType: UTType { UTType(SolutionPackage.typeIdentifier) ?? .data }

    /// "n Lösungen aus der Community zu diesem Blatt" (Lesen, auch in Free, nur mit Treffern)
    @ViewBuilder private var communityBanner: some View {
        if !communityMatches.isEmpty, !communityBannerDismissed, entitlements.allows(.communityRead), let fp = communityFingerprint {
            HStack(spacing: 10) {
                Image(systemName: "person.2")
                Text(CommunityTexts.matches(communityMatches.count)).font(.caption).bold().lineLimit(1)
                Button("Ansehen") { solutionSheet = .community(fp) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button { communityBannerDismissed = true } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Hinweis ausblenden")
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.top, 8)
        }
    }

    /// Ebenen: eigene Notizen und passende empfangene Loesungen ein-/ausblenden.
    private var layersMenu: some View {
        Menu {
            Button { ownNotesVisible.toggle() } label: {
                Label("Meine Notizen", systemImage: ownNotesVisible ? "checkmark.circle.fill" : "circle")
            }
            if entitlements.allows(.communityRead) {
                Section("Lösungen anderer") {
                    if foreignLayers.isEmpty && foreignProblems.isEmpty {
                        Text("Keine Lösungen zu dieser PDF")
                    }
                    ForEach(foreignProblems) { problem in
                        Menu {
                            Text(problem.message)
                            Button(role: .destructive) { removeProblem(problem) } label: { Label("Entfernen", systemImage: "trash") }
                        } label: {
                            Label("Nicht lesbar: \(problem.label)", systemImage: "exclamationmark.triangle")
                        }
                    }
                    ForEach(foreignLayers) { layer in
                        Menu {
                            Button { setVisible(layer, !layer.visible) } label: {
                                Label(layer.visible ? "Ausblenden" : "Einblenden", systemImage: layer.visible ? "eye.slash" : "eye")
                            }
                            Button { companion = nil; solutionSide = layer } label: {
                                Label("Daneben ansehen", systemImage: "rectangle.split.2x1")
                            }
                            Button { solutionSheet = .preview(layer.id) } label: {
                                Label("Vorschau ohne Original", systemImage: "rectangle.on.rectangle")
                            }
                            Button(role: .destructive) { removeLayer(layer) } label: { Label("Entfernen", systemImage: "trash") }
                        } label: {
                            Label(layer.label, systemImage: layer.visible ? "checkmark.circle.fill" : "circle")
                        }
                    }
                    Button { importingSolution = true } label: { Label("Lösung importieren …", systemImage: "square.and.arrow.down") }
                }
                // nur mit CloudKit-Dienst im Build (sonst kein Platzhalter; die Einstellungen sagen, warum)
                if SolutionSharing.community.isConnected {
                    Section("Community") {
                        Button {
                            if let fp = communityFingerprint { solutionSheet = .community(fp) }
                        } label: {
                            Label(communityMatches.isEmpty ? "Community durchsuchen …" : CommunityTexts.matches(communityMatches.count) + " …",
                                  systemImage: "person.2")
                        }
                        .disabled(communityFingerprint == nil)
                    }
                }
            } else {
                Button { solutionSheet = .locked(.communityRead) } label: {
                    Label(Self.lockedLabel("Lösungen anderer ansehen", entitlements.access(.communityRead)), systemImage: UFLock.symbol)
                }
            }
        } label: { Label("Ebenen", systemImage: "square.3.layers.3d") }
        .disabled(store.pdf == nil)
    }

    /// Teilen braucht Plus; die Liste "Meine geteilten Lösungen" (Zurueckziehen, Entfernen) steht allen offen
    private func openSolutionSheet(_ sheet: SolutionSheet) {
        let feature: UFFeature = sheet.id == SolutionSheet.share.id ? .shareSolutions : .communityRead
        solutionSheet = entitlements.allows(feature) ? sheet : .locked(feature)
    }

    /// Menuepunkt einer gesperrten Funktion: "Lösung teilen … (ab Plus)" bzw. "(bald)" (einheitlich `UFLock.label`)
    static func lockedLabel(_ title: String, _ access: UFAccess) -> String {
        switch access {
        case .allowed: return title
        case .locked(let p): return UFLock.label(title, p)
        case .comingSoon: return "\(title) (bald)"
        }
    }

    @ViewBuilder
    private func solutionSheetView(_ sheet: SolutionSheet) -> some View {
        switch sheet {
        case .share:
            SolutionShareSheet(store: store, api: api, notebook: companionStore) { solutionSheet = nil }
        case .shared:
            SharedSolutionsSheet { solutionSheet = nil }
        case .preview(let id):
            if let layer = foreignLayers.first(where: { $0.id == id }) {
                SolutionPreviewSheet(layer: layer) { solutionSheet = nil }
            }
        case .community(let fp):
            // "Laden und anzeigen" nimmt denselben Weg wie die Datei (fremde Ebene, eigene Notizen unveraendert)
            CommunitySolutionsSheet(fingerprint: fp, service: SolutionSharing.community,
                                    importer: { id in try await store.importFromCommunity(id, service: SolutionSharing.community) },
                                    onImported: { result in Task { await handleImport(result) } },
                                    onBeside: { id in Task { await showSolutionBeside(id) } }) { solutionSheet = nil }
        case .locked(let feature):
            SolutionLockedSheet(feature: feature) { solutionSheet = nil }
        }
    }

    /// Geladene Community-Loesung neben dem Dokument zeigen: jede Seite auf der eigenen PDF-Seite (gleicher Fingerabdruck)
    /// bzw. auf der Vorlage des leeren Blatts, wie sie geschrieben wurde (Wunsch des Inhabers 13.11.2026)
    private func showSolutionBeside(_ id: String) async {
        await reloadSolutionLayers()
        solutionSheet = nil
        guard let layer = foreignLayers.first(where: { $0.id == id }) else { return }
        if entitlements.allows(.splitView) { companion = nil; solutionSide = layer } else { lockedFeature = .splitView }
    }

    /// Passende Loesungen neu laden (Lesen, auch in Free). Passt eine nicht zur PDF, erscheint sie nicht; die Meldung kommt
    /// einmal je Sitzung als Hinweis, danach steht sie im Ebenen-Menue (mit "Entfernen").
    // MARK: Korrekturvorschlag

    /// Wartende Bitte aus `CorrectionLaunch` (Router) abholen: korrigieren oder eine empfangene Korrektur zeigen
    private func takeCorrectionRequest() async {
        switch correctionLaunch.take(fileID: store.file.id) {
        case .correct(let sid): await startCorrection(sid)
        case .show(let c):
            correction?.saveNow()
            correction = nil
            shownCorrectionTarget = nil
            if !c.isForMe, let pdf = store.originalPDF ?? store.pdf {
                // fremde Korrektur: die korrigierte Loesung darunter zeigen (sonst lagen die Striche ueber den eigenen Notizen)
                shownCorrectionTarget = try? await CorrectionLaunch.targetLayer(solutionID: c.targetSolutionID, known: foreignLayers, pdf: pdf,
                                                                                fingerprint: await store.originalFingerprint(),
                                                                                service: SolutionSharing.community)
            }
            markCorrectionSeen(c)
            shownCorrection = c
        case nil: break
        }
    }

    /// Hinweis an mich geoeffnet: ab jetzt "gesehen" (Posteingang unter "Gesehen", nicht mehr im Abzeichen); nur lokal
    private func markCorrectionSeen(_ c: CommunityCorrection) {
        guard c.isForMe, !c.isMine, c.status == .open else { return }
        SolutionSharing.community.setCorrectionStatus(.seen, id: c.id)
        CommunityBadge.shared.resolve(c.id)
        if let i = ownCorrections.firstIndex(where: { $0.id == c.id }) { ownCorrections[i].status = .seen }
    }

    /// Korrekturhinweise (offen und gesehen) zu meiner eigenen geteilten Loesung dieser PDF (Hinweis oben im Dokument)
    private func loadOwnCorrections() async {
        let service = SolutionSharing.community
        guard service.supportsCorrections, entitlements.allows(.communityRead), !readOnly, let fp = communityFingerprint else { return }
        let mine = CorrectionInbox.solutionIDs(fingerprint: fp, known: communityMatches, shared: SolutionSharing.library.sharedEntries())
        guard !mine.isEmpty, let inbox = try? await service.correctionsForMyOwnSolutions() else { return }
        ownCorrections = CorrectionInbox.items(inbox, only: mine).map(\.correction)
    }

    /// Angezeigte Korrektur an mich ignorieren (nur auf diesem Geraet) und schliessen
    private func ignoreShownCorrection() {
        guard let c = shownCorrection else { return }
        SolutionSharing.community.setCorrectionStatus(.ignored, id: c.id)
        CommunityBadge.shared.resolve(c.id)
        ownCorrections.removeAll { $0.id == c.id }
        shownCorrection = nil
        shownCorrectionTarget = nil
    }

    /// Korrektur-Modus fuer eine fremde Loesung: als Ebene ueber der eigenen PDF, eigene Notizen aus, Entwurf geladen
    private func startCorrection(_ solutionID: String) async {
        guard !readOnly, let pdf = store.originalPDF ?? store.pdf else { return }
        do {
            let layer = try await CorrectionLaunch.targetLayer(solutionID: solutionID, known: foreignLayers, pdf: pdf,
                                                               fingerprint: await store.originalFingerprint(),
                                                               service: SolutionSharing.community)
            bridge.setObjectMode(false)
            shownCorrection = nil
            shownCorrectionTarget = nil
            correction = CorrectionSession(target: layer)
        } catch {
            actionError = "Korrektur nicht möglich: " + SolutionSharing.message(error)
        }
    }

    private func sendCorrection() async {
        guard let session = correction else { return }
        do {
            let sent = try await session.send(service: SolutionSharing.community)
            correction = nil
            let name = session.target.displayName.trimmingCharacters(in: .whitespaces).isEmpty ? "Anonym" : session.target.displayName
            actionError = "Korrekturhinweis an \(name) gesendet (\(sent.strokeCount) Markierungen, \(sent.noteCount) Randnotizen). "
                + "Die Lösung selbst bleibt unverändert."
        } catch {
            actionError = "Senden fehlgeschlagen: " + SolutionSharing.message(error) + " Der Entwurf bleibt erhalten."
        }
    }

    private func correctionNoteEvent(_ event: CorrectionNoteEvent) {
        switch event {
        case .place(let info, let x, let y):
            noteText = ""
            notePlacement = CorrectionNotePlacement(info: info, x: x, y: y)
        case .open(let id):
            openedNote = correction?.note(id: id) ?? shownCorrection?.pages.lazy.flatMap(\.notes).first { $0.id == id }
        }
    }

    private func reloadSolutionLayers() async {
        guard entitlements.allows(.communityRead), store.pdf != nil else {
            foreignLayers = []
            foreignProblems = []
            return
        }
        let result = await store.solutionLayers()
        foreignLayers = result.layers
        foreignProblems = result.problems
        let unseen = SolutionProblemNotices.unseen(result.problems)
        if !unseen.isEmpty, actionError == nil { actionError = unseen.map(\.text).joined(separator: "\n") }
    }

    /// Treffer aus der Community zu dieser PDF (Lesen, auch in Free, nur mit Dienst im Build; Fehler bleiben still, die Liste
    /// zeigt sie beim Oeffnen des Blatts)
    private func loadCommunityMatches() async {
        guard entitlements.allows(.communityRead), store.pdf != nil, !readOnly, let fp = await store.originalFingerprint() else { return }
        communityFingerprint = fp
        guard SolutionSharing.community.isConnected else { return }
        if let cached = CommunityMatches.shared.cached(fp) { communityMatches = cached }
        communityMatches = (try? await CommunityMatches.shared.load(fingerprint: fp, service: SolutionSharing.community)) ?? communityMatches
    }

    private func removeProblem(_ problem: SolutionLayerLoad.Problem) {
        do {
            try SolutionSharing.library.remove(problem.id)
            foreignProblems.removeAll { $0.id == problem.id }
        } catch {
            actionError = "Entfernen fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func setVisible(_ layer: ForeignSolutionLayer, _ visible: Bool) {
        try? SolutionSharing.library.setVisible(layer.id, visible)
        if let i = foreignLayers.firstIndex(where: { $0.id == layer.id }) { foreignLayers[i].visible = visible }
    }

    private func removeLayer(_ layer: ForeignSolutionLayer) {
        do {
            try SolutionSharing.library.remove(layer.id)
            foreignLayers.removeAll { $0.id == layer.id }
        } catch {
            actionError = "Entfernen fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func importSolution(_ result: Result<URL, Error>) {
        Task {
            do {
                await handleImport(try await store.importSolution(try result.get()))
            } catch {
                actionError = (error as? SolutionError)?.description ?? "Import fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }

    /// Ergebnis eines Imports (Datei oder Community): Ebenen neu laden bzw. erklaeren, warum nichts erscheint
    private func handleImport(_ result: SolutionImportResult) async {
        switch result {
        case .shown:
            await reloadSolutionLayers()
        case .otherPDF(let entry):
            let label = ForeignSolutionLayer.label(displayName: entry.displayName, createdAt: entry.createdAt)
            actionError = "\(label): \(SolutionError.fingerprintMismatch.description) Sie ist gespeichert und erscheint, sobald du die passende PDF öffnest."
        case .removedUnreadable(let entry, let error):
            let label = ForeignSolutionLayer.label(displayName: entry.displayName, createdAt: entry.createdAt)
            actionError = "\(label): \(SolutionSharing.unreadableImportMessage)\n(\(error.description))"
            await reloadSolutionLayers()
        }
    }

    /// PDF mit Notizen (Ganzes Dokument oder aktuelle Seite) erzeugen und das Teilen-Menue des Systems zeigen.
    private func share(_ scope: ShareScope, purpose: ExportPurpose = .share, excludedSheets: Set<String> = []) {
        exporting = true
        Task {
            defer { exporting = false }
            do {
                // Seitennotizen und Blaetter daneben gehen direkt hinter ihrer Folie mit (NotesExport, 05.11.2026); das
                // gerade offene Blatt geht mit, im Hinweis abgewaehlte und solche im Papierkorb nicht (13.11.2026)
                var options = NotesExport.Options(scope: scope)
                options.excludedSheets = excludedSheets
                let result = try await NotesExport.pdf(for: store, api: api, options: options, open: companionStore)
                if purpose == .print {
                    PDFPrinting.print(result.url, title: store.file.displayTitle) { error in
                        if let error { actionError = "Drucken fehlgeschlagen: \(error)" }
                    }
                } else {
                    exportFile = ExportFile(url: result.url, notice: result.payload.missingImagesNotice, purpose: purpose)
                }
            } catch {
                actionError = (purpose == .print ? "Drucken" : purpose == .save ? "Sichern" : "Teilen") + " fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }

    /// PDF exportieren: erst der Hinweis "nur privat", dann Teilen, Sichern oder Drucken
    private func startExport(_ scope: ShareScope, _ purpose: ExportPurpose) {
        exportPurpose = purpose
        pendingExport = scope
    }

    /// Befehl aus der Menueleiste (`EditorCommands`)
    private func handleMenuRequest(_ r: EditorMenuRequest?) {
        guard let r, !tracing else { return }
        switch r.kind {
        case .search: showSearch = true
        case .goToPage: goToText = ""; goingToPage = true
        case .save: startExport(.document, .save)
        case .print: startExport(.document, .print)
        case .share: startExport(.document, .share)
        case .photo: if canWrite && ownNotesVisible { pickingPhoto = true }
        case .imageFile: if canWrite && ownNotesVisible { pickingImageFile = true }
        case .magnifier: if canWrite && ownNotesVisible { bridge.toggleMagnifier() }
        case .present: presenting.toggle()
        case .endPresentation: presenting = false
        case .newWindow: if DocumentWindows.supported, !readOnly { openInNewWindow() }
        }
    }

    /// Gewaehltes Bild auf die aktuelle Seite
    private func insertPicked(_ image: UIImage?) {
        guard let image, let c = bridge.controller, let key = c.currentPageKey else {
            if image == nil { actionError = "Das Bild ließ sich nicht öffnen." }
            return
        }
        Task { await c.objects.insertImage(image, on: key) }
    }

    private var pageInfo: some View {
        HStack(spacing: 10) {
            Text("Seite \(bridge.pageIndex + 1) / \(store.pdf?.pageCount ?? 0)")
            Divider().frame(height: 14)
            Button("\(bridge.zoomPercent) %") { bridge.fitWidth() }
                .accessibilityHint("Seite einpassen")
                .disabled(freeze.locksView)                      // fixiert: Zoom bleibt
            if readOnly {
                Divider().frame(height: 14)
                Label("Alte Fassung – nur ansehen", systemImage: "doc.badge.clock").lineLimit(1)
            } else if store.outdatedByNewVersion {
                Divider().frame(height: 14)
                Label("Neue Fassung angekommen – Dokument neu öffnen", systemImage: "arrow.triangle.2.circlepath").lineLimit(1)
            } else if store.journalUnreadable {
                Divider().frame(height: 14)
                Label("Lokale Notizen nicht lesbar – nur ansehen", systemImage: "exclamationmark.triangle").lineLimit(1)
            } else if let label = store.viewOnlyLabel {
                Divider().frame(height: 14)
                ViewOnlyElsewhereLabel(label: label, canTakeOver: store.canTakeOverHere && tabsEnabled) { reopenHere(force: true) }
            } else if !planAllowsWriting {
                Divider().frame(height: 14)
                Button { lockedFeature = .pencilWriting } label: {
                    Label("Nur ansehen – Schreiben ab \(UFPlan.plus.name)", systemImage: "lock").lineLimit(1)
                }
                .accessibilityHint("Öffnet die Tarifwahl")
            } else if !ownNotesVisible {
                Divider().frame(height: 14)
                Label("Meine Notizen ausgeblendet – nur ansehen", systemImage: "eye.slash").lineLimit(1)
            }
            if foreignLayers.contains(where: \.visible) {
                Divider().frame(height: 14)
                // antippen: die Loesung daneben ansehen (03.11.2026: tief im Ebenen-Menue nicht gefunden)
                Button {
                    if let layer = foreignLayers.first(where: \.visible) {
                        if entitlements.allows(.splitView) { companion = nil; solutionSide = layer } else { lockedFeature = .splitView }
                    }
                } label: {
                    Label("\(foreignLayers.filter(\.visible).count) Lösung(en) eingeblendet · daneben ansehen", systemImage: "square.3.layers.3d").lineLimit(1)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("doc.solutionBeside")
            }
            if let notice = store.notice ?? store.pageNotice ?? store.inkNotice {
                Divider().frame(height: 14)
                Text(notice).lineLimit(1)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 12)
    }
}

/// Rechte bzw. linke Seite der geteilten Ansicht: eigenes Dokument, eigenes Scrollen und Zoomen,
/// keine eigene Werkzeugleiste (die feste Leiste des Hauptdokuments gilt fuer beide).
struct CompanionView: View {
    let api: APIClient
    @StateObject private var store: DocumentStore
    @StateObject private var bridge = EditorBridge()
    let pdfPage: Int?
    let tools: EditorToolState
    let undoManager: UndoManager
    let pencilOnly: Bool
    let canEdit: Bool
    /// "Ansicht fixieren" im Hauptdokument fixiert auch das Dokument daneben
    var viewLocked = false
    /// nach dem Laden unten eine Seite mit dieser Vorlage anfuegen und hinspringen (`Companion.appendTemplate`)
    var appendTemplate: String?
    /// meldet das offene Dokument an die Hauptansicht (sichtbar ja/nein)
    var onStore: (DocumentStore, Bool) -> Void = { _, _ in }
    let onClose: () -> Void

    init(file: LibFile, api: APIClient, pdfPage: Int?, tools: EditorToolState, undoManager: UndoManager,
         pencilOnly: Bool, canEdit: Bool = true, viewLocked: Bool = false, appendTemplate: String? = nil,
         onStore: @escaping (DocumentStore, Bool) -> Void = { _, _ in }, onClose: @escaping () -> Void) {
        self.appendTemplate = appendTemplate
        _store = StateObject(wrappedValue: DocumentStore(file: file, api: api))
        self.api = api
        self.pdfPage = pdfPage
        self.tools = tools
        self.undoManager = undoManager
        self.pencilOnly = pencilOnly
        self.canEdit = canEdit
        self.viewLocked = viewLocked
        self.onStore = onStore
        self.onClose = onClose
    }

    /// "Eigenes Fenster" nur am Mac: auf dem iPad schob das neue Fenster das Dokument ganz weg (Vollbild), man kam nicht
    /// mehr zur PDF zurueck und sie blieb im alten Fenster gesperrt (Fehlerbericht des Inhabers 13.11.2026)
    static var offersOwnWindow: Bool { PDFEditorController.isMac && DocumentWindows.supported }

    var body: some View {
        VStack(spacing: 0) {
            // Kopf wie KI-Hilfe und Loesung daneben (UFPaneHeader)
            UFPaneHeader(store.file.displayTitle, icon: store.file.isNotebook ? "note" : "file-text", close: onClose) {
                if Self.offersOwnWindow {
                    // Uebung bzw. Loesung als eigenes Fenster (Mac: frei verschieben, auch auf einen zweiten Bildschirm)
                    Button {
                        let id = store.file.id
                        let page = store.entry(forPageIndex: bridge.pageIndex)?.pdfIndex
                        onClose()
                        Task {
                            await store.pause()
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            DocumentWindows.open(fileID: id, page: page)
                        }
                    } label: { Label("Eigenes Fenster", systemImage: "macwindow.badge.plus").ufFont(12.8, 600) }
                    .buttonStyle(.plain)
                    .foregroundStyle(UF.text2)
                    .accessibilityLabel("In eigenem Fenster öffnen")
                    .modifier(MacHelp(text: "In eigenem Fenster öffnen"))
                }
                StatusLabel(status: store.status)
                SyncIssueBadge(store: store)
                // weitere Seite unter der angezeigten, wie "Seite anhängen" im Hauptdokument (Frage des Inhabers 13.11.2026)
                CompanionAddPageButton(store: store, bridge: bridge,
                                       enabled: canEdit && store.pdf != nil && !store.journalUnreadable && !store.viewOnlyHere)
                CompanionPageLabel(bridge: bridge, count: store.layout?.entries.count ?? 0)
            }
            if let error = store.errorMessage {
                ContentUnavailableView("Nicht verfügbar", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if store.pdf != nil {
                PDFEditorView(store: store, bridge: bridge, pencilOnly: pencilOnly, layoutVersion: store.layoutVersion,
                              tools: tools, ownsToolPicker: false, undoManager: undoManager, initialPDFPage: pdfPage,
                              canEdit: canEdit && !store.journalUnreadable && !store.viewOnlyHere,
                              freezeMode: viewLocked ? .view : .off)
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
        }
        .task {
            await store.load()
            // fuer "Zuletzt benutzt" (Uebersicht) und "Zuletzt bearbeitet" (Bibliothek): ein Blatt daneben war sonst
            // nach dem Schliessen nirgends zu sehen (Fehlerbericht 13.11.2026)
            if store.errorMessage == nil, !store.isOldVersion {
                _ = try? await api.value("/api/files/\(store.file.id)/opened", method: "POST", body: [:])
            }
            if let t = appendTemplate, canEdit, store.isWritable, let index = await Self.appendPage(to: store, template: t) {
                // warten, bis der Editor da ist, dann zur neuen Seite
                for _ in 0..<40 where bridge.controller == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
                try? await Task.sleep(nanoseconds: 150_000_000)
                bridge.controller?.goToPage(index)
            }
        }
        .onAppear {
            store.setShown(true)
            onStore(store, true)
        }
        .onDisappear {
            store.setShown(false)
            onStore(store, false)
            Task { await store.pause() }
        }
        .onChange(of: ObjectIdentifier(api)) { _, _ in Task { await store.updateAPI(api) } }
    }
}

/// "In einem anderen Fenster offen – nur ansehen" mit "Hier bearbeiten" (uebernimmt das Dokument aus dem anderen
/// Fenster; Fehlerbericht 13.11.2026: das andere Fenster war nicht zu finden, die PDF blieb gesperrt)
struct ViewOnlyElsewhereLabel: View {
    let label: String
    let canTakeOver: Bool
    let takeOver: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label(label, systemImage: "eye").lineLimit(1)
            if canTakeOver {
                Button(action: takeOver) {
                    Text("Hier bearbeiten").fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent).controlSize(.mini)
                .accessibilityIdentifier("doc.takeOverHere")
                .accessibilityHint("Das andere Fenster gibt das Dokument ab, hier kannst du schreiben")
            }
        }
    }
}

extension CompanionView {
    /// Weitere Seite unten an ein vorhandenes Blatt: eine leere letzte Seite derselben Vorlage wird wiederverwendet (kein
    /// Stapel leerer Seiten bei jedem Antippen). Liefert den Index der Zielseite.
    static func appendPage(to store: DocumentStore, template: String) async -> Int? {
        guard let entries = store.layout?.entries, let last = entries.last else { return nil }
        let doc = await store.pageStructureDocument()
        if last.kind == "blank", last.template == template, doc.objects(page: last.key).isEmpty { return entries.count - 1 }
        await store.addBlankPage(afterKey: last.key, template: template)
        return (store.layout?.entries.count ?? entries.count + 1) - 1
    }
}

/// "S. 2 / 3" in der Kopfzeile des Dokuments daneben (die Seitenzahl zeigt, dass es weitere Seiten gibt)
struct CompanionPageLabel: View {
    @ObservedObject var bridge: EditorBridge
    let count: Int

    var body: some View {
        Text(count > 1 ? "S. \(bridge.pageIndex + 1) / \(count)" : "S. \(bridge.pageIndex + 1)")
            .ufFont(12.8, 500, lh: 1.25).monospacedDigit().foregroundStyle(UF.text2)
            .accessibilityIdentifier("companion.pageLabel")
    }
}

/// "+ Seite" im Kopf des Dokuments daneben: fragt erst nach dem Papier (leer, liniert, kariert ... wie beim Oeffnen
/// eines leeren Blatts), fuegt die Seite dann direkt unter der angezeigten ein und springt hin; das Blatt bleibt offen.
///
/// Fehlerbericht des Inhabers (Build 37, 13.11.2026): Antippen tat nichts. Der Knopf war ein `Menu` mit Hauptaktion;
/// die Kopfzeile hat eine Geste "gedrueckt halten und ziehen" (Seiten tauschen, `UFPaneSwapGesture`), die jede
/// Beruehrung sofort aufnimmt. Ein `Button` setzt sich dagegen durch (wie das X), das System-Menue nicht. Belegt mit
/// echter Beruehrung in `UniFlowUITests/CompanionAddPageUITests`.
struct CompanionAddPageButton: View {
    let store: DocumentStore
    @ObservedObject var bridge: EditorBridge
    let enabled: Bool
    @State private var choosing = false

    var body: some View {
        Button { choosing = true } label: {
            // beschriftet, damit er nicht mit einem Fenster-Knopf verwechselt wird
            Label("Seite", systemImage: "plus").ufFont(12.8, 600)
                .lineLimit(1).fixedSize()                  // hochkant nicht zu "+ S…" kuerzen (der Titel gibt nach)
                .padding(.horizontal, 8).frame(height: 30)
                .background(UF.surface2, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .layoutPriority(1)
        .foregroundStyle(enabled ? UF.text2 : UF.muted)
        .disabled(!enabled)
        .accessibilityLabel("Seite darunter einfügen")
        .accessibilityHint("Fragt nach dem Papier und fügt eine Seite unter der angezeigten ein")
        .accessibilityIdentifier("companion.addPage")
        .modifier(MacHelp(text: "Seite darunter einfügen"))
        .popover(isPresented: $choosing, arrowEdge: .top) {
            CompanionPaperChooser(current: Self.template(store.layout?.entries, at: bridge.pageIndex)) { t in
                choosing = false
                add(t)
            }
        }
    }

    /// Vorlage der angezeigten Seite (Leerseite), sonst "blank" - wie `PageSidebarActions.appendTemplate`
    static func template(_ entries: [DisplayLayout.Entry]?, at index: Int) -> String {
        guard let entries, entries.indices.contains(index) else { return PageSidebarActions.appendTemplate(lastEntry: entries?.last) }
        return PageSidebarActions.appendTemplate(lastEntry: entries[index])
    }

    private func add(_ template: String) {
        let after = bridge.pageKey
        Task { await bridge.controller?.insertBlankPage(after: after, template: template) }
    }
}

/// Papier fuer die neue Seite: dieselben Vorlagen wie "Leeres Blatt" unter "Daneben öffnen"; die der angezeigten
/// Seite ist markiert
struct CompanionPaperChooser: View {
    let current: String
    let choose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Neue Seite darunter").ufFont(15.2, 650, em: -0.01).foregroundStyle(UF.text)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 10)], spacing: 10) {
                ForEach(CompanionPicker.blankTemplates, id: \.id) { t in
                    Button { choose(t.id) } label: {
                        VStack(spacing: 6) {
                            UFTemplatePreview(template: t.id)
                                .frame(width: 46, height: 60)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(UF.lineStrong, lineWidth: 1))
                            Text(t.name).ufFont(12.8, 600).foregroundStyle(UF.text)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(UF.surface, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(t.id == current ? UF.accent : UF.line, lineWidth: t.id == current ? 2 : 1))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(t.name)
                    .accessibilityIdentifier("companion.addPage.\(t.id)")
                }
            }
        }
        .padding(16)
        .frame(width: 300)
        .presentationCompactAdaptation(.popover)
    }
}

/// "Deine Blätter zu diesem Dokument" unter "Daneben öffnen": Blaetter, die schon einmal neben diesem Dokument
/// beschrieben wurden, mit Datum; eins im Papierkorb laesst sich hier wiederherstellen (Fehlerbericht 13.11.2026)
struct CompanionOwnSheetsSection: View {
    let sheets: [SideSheetLoader.Entry]
    let open: (String) -> Void
    let restore: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Deine Blätter zu diesem Dokument").ufFont(15.2, 650, em: -0.01).foregroundStyle(UF.text)
            VStack(spacing: 0) {
                ForEach(Array(sheets.enumerated()), id: \.element.id) { i, e in
                    if i > 0 { Rectangle().fill(UF.line).frame(height: 1).padding(.leading, 48) }
                    Button { e.trashed ? restore(e.id) : open(e.id) } label: {
                        HStack(spacing: 12) {
                            UFIcon("note", size: 18).foregroundStyle(e.trashed ? UF.muted : UF.accent).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.title).ufFont(14.5, 600).foregroundStyle(UF.text).lineLimit(2)
                                Text([e.trashed ? "im Papierkorb" : nil, e.editedLabel].compactMap { $0 }.joined(separator: " · "))
                                    .ufFont(12.8).foregroundStyle(UF.muted).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Text(e.trashed ? "Wiederherstellen" : "Daneben öffnen").ufFont(12.8, 600).foregroundStyle(UF.accentText)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("companion.own.\(i)")
                }
            }
            .background(UF.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(UF.line, lineWidth: 1))
        }
    }
}

/// "Daneben öffnen": ein leeres Blatt mit Vorlage (mitschreiben, ohne auf die Folie zu schreiben) oder ein vorhandenes
/// Dokument (Dokumente desselben Moduls zuerst). Das Blatt ist ein Notizbuch im Modul der offenen Datei.
struct CompanionPicker: View {
    let api: APIClient
    let moduleID: Int?
    let excluding: String
    /// Titel der offenen Datei, fuer den Namen des neuen Blatts
    var sourceTitle = ""
    /// Blaetter, die neben diesem Dokument beschrieben wurden (`sideSheets`): "Deine Blätter zu diesem Dokument"
    var linkedSheetIDs: [String] = []
    /// empfangene Loesungen zu dieser PDF (ID, Name): "Lösung daneben ansehen" steht dann zuerst
    var solutions: [(id: String, label: String)] = []
    /// Lage von Folie und Loesung nach der Schreibhand (SplitSides.solutionHint)
    var solutionHint = SplitSides.solutionHint(hand: "right")
    var onSolution: (String) -> Void = { _ in }
    /// "Leeres Blatt", wenn es zu diesem Dokument schon ein Blatt gibt: dort unten eine Seite anfuegen (Blatt, Vorlage).
    /// nil: immer ein neues Notizbuch (alter Weg)
    var onAppend: ((LibFile, String) -> Void)? = nil
    let onPick: (LibFile) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var files: [LibFile] = []
    @State private var query = ""
    @State private var error: String?
    @State private var creating: String?
    /// eigene Blaetter zu diesem Dokument (verknuepft oder nach ihm benannt), auch solche im Papierkorb
    @State private var ownSheets: [SideSheetLoader.Entry] = []

    /// Vorlagen fuer das leere Blatt in der Reihenfolge der Auswahl im Editor
    static var blankTemplates: [(id: String, name: String)] { PaperTemplate.choices }

    /// Titel des neuen Blatts
    static func sheetTitle(for source: String) -> String {
        let base = (source as NSString).deletingPathExtension.trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? "Notizen" : "Notizen – \(base)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !solutions.isEmpty { solutionSection }
                    if !ownSheets.isEmpty {
                        CompanionOwnSheetsSection(sheets: ownSheets, open: { id in Task { await openOwn(id, restore: false) } },
                                                  restore: { id in Task { await openOwn(id, restore: true) } })
                    }
                    blankSection
                    documentSection
                }
                .padding(20)
            }
            .background(UF.bg)
            .navigationTitle("Daneben öffnen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
            .task { await loadFiles() }
        }
    }

    private var solutionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Lösung daneben ansehen").ufFont(15.2, 650, em: -0.01).foregroundStyle(UF.text)
            Text(solutionHint)
                .ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(Array(solutions.enumerated()), id: \.element.id) { i, sol in
                    if i > 0 { Rectangle().fill(UF.line).frame(height: 1).padding(.leading, 48) }
                    Button { onSolution(sol.id); dismiss() } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "rectangle.split.2x1").foregroundStyle(UF.accent).frame(width: 24)
                            Text(sol.label).ufFont(14.5, 600).foregroundStyle(UF.text).lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("companion.solution.\(i)")
                }
            }
            .background(UF.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(UF.line, lineWidth: 1))
        }
    }

    private var blankSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Leeres Blatt").ufFont(15.2, 650, em: -0.01).foregroundStyle(UF.text)
            Text(ownSheets.contains { !$0.trashed } && onAppend != nil
                 ? "Es gibt schon Notizen zu diesem Dokument: die neue Seite kommt dort unten dazu, im gewählten Muster. So bleibt alles in einer Notiz."
                 : "Zum Mitschreiben neben der Folie, ohne auf sie zu schreiben. Die Notiz bleibt gespeichert: hier oben unter „Deine Blätter“, in der Bibliothek beim Modul unter „Eigene Notizen“ und unter „Zuletzt benutzt“. Mit „+ Seite“ im Kopf kommen weitere Seiten darunter.")
                .ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 12)], spacing: 12) {
                ForEach(Self.blankTemplates, id: \.id) { t in
                    Button { Task { await createBlank(t.id) } } label: {
                        VStack(spacing: 8) {
                            UFTemplatePreview(template: t.id)
                                .frame(width: 58, height: 76)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(UF.lineStrong, lineWidth: 1))
                                .overlay { if creating == t.id { ProgressView() } }
                            Text(t.name).ufFont(13.12, 600).foregroundStyle(UF.text)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(UF.surface, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(UF.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(creating != nil)
                    .accessibilityIdentifier("companion.blank.\(t.id)")
                }
            }
        }
    }

    private var documentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Dokument").ufFont(15.2, 650, em: -0.01).foregroundStyle(UF.text)
            UFTextInput("Skript oder Blatt suchen", text: $query)
            if let error {
                Text(error).ufFont(13.12).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                ForEach(Array(filtered.enumerated()), id: \.element.id) { i, f in
                    if i > 0 { Rectangle().fill(UF.line).frame(height: 1).padding(.leading, 48) }
                    Button { onPick(f); dismiss() } label: {
                        HStack(spacing: 12) {
                            // Symbole der App (UFIcon) statt SF Symbols, wie in Bibliothek und Uebersicht
                            UFIcon(f.isNotebook ? "note" : "file-text", size: 18)
                                .foregroundStyle(f.module_id == moduleID ? UF.accent : UF.muted)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.displayTitle).ufFont(14.5, 600).foregroundStyle(UF.text).lineLimit(2)
                                Text([f.subject, f.sub_label].compactMap { $0 }.joined(separator: " · "))
                                    .ufFont(12.8).foregroundStyle(UF.muted).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(UF.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(UF.line, lineWidth: 1))
        }
    }

    private var filtered: [LibFile] {
        let q = query.lowercased()
        return q.isEmpty ? files : files.filter { ($0.displayTitle + " " + $0.name).lowercased().contains(q) }
    }

    private func library() async throws -> [LibFile] {
        try await api.json("/api/library", as: LibraryResponse.self).files
    }

    private func loadFiles() async {
        do {
            files = try await library().filter { $0.opensInEditor && $0.id != excluding }
                .sorted { ($0.module_id == moduleID ? 0 : 1, $0.displayTitle) < ($1.module_id == moduleID ? 0 : 1, $1.displayTitle) }
        } catch let e {
            error = e.localizedDescription
        }
        ownSheets = await Self.ownSheets(linked: linkedSheetIDs, named: Self.sheetTitle(for: sourceTitle), library: files,
                                         excluding: excluding, api: api)
    }

    /// Eigene Blaetter zu einem Dokument: erst die neben ihm beschriebenen (`sideSheets`, auch im Papierkorb), dann
    /// Notizbuecher, die "Daneben öffnen" fuer dieses Dokument angelegt hat (Titel "Notizen – <Dokument>"), aber auf
    /// denen noch nichts verknuepft wurde. Neueste zuerst innerhalb jeder Gruppe.
    static func ownSheets(linked: [String], named title: String, library: [LibFile], excluding: String,
                          api: APIClient) async -> [SideSheetLoader.Entry] {
        var out: [SideSheetLoader.Entry] = []
        for id in linked where id != excluding {
            if let e = await SideSheetLoader.entry(id, api: api) { out.append(e) }
        }
        let known = Set(out.map(\.id))
        let named = library.filter { $0.isNotebook && $0.id != excluding && !known.contains($0.id) && $0.displayTitle == title }
        var more: [SideSheetLoader.Entry] = []
        for f in named {
            if let e = await SideSheetLoader.entry(f.id, api: api) { more.append(e) }
        }
        let newest: (SideSheetLoader.Entry, SideSheetLoader.Entry) -> Bool = { ($0.edited ?? "") > ($1.edited ?? "") }
        return out.sorted(by: newest) + more.sorted(by: newest)
    }

    /// Blatt, in dem ein neues "Leeres Blatt" weitergeht: das zuletzt benutzte nicht geloeschte (verknuepfte zuerst)
    static func sheetToContinue(_ own: [SideSheetLoader.Entry]) -> String? { own.first { !$0.trashed }?.id }

    /// Eigenes Blatt wieder daneben oeffnen (aus dem Papierkorb zuerst wiederherstellen)
    private func openOwn(_ id: String, restore: Bool) async {
        do {
            if restore { _ = try await api.value("/api/library/files/\(id)", method: "PATCH", body: ["restore": true]) }
            var f = try await library().first(where: { $0.id == id })
            if f == nil { f = try await api.json("/api/files/\(id)", as: LibFile.self) }
            guard let f else { return }
            onPick(f)
            dismiss()
        } catch let e {
            error = e.localizedDescription
        }
    }

    /// Neues Notizbuch mit Vorlage im Modul der offenen Datei, dann daneben oeffnen
    private func createBlank(_ template: String) async {
        guard Entitlements.shared.allows(NotebookDialog.feature) else {
            error = "Notizblätter gibt es ab \(UFPlan.plus.name)."
            return
        }
        creating = template
        defer { creating = nil }
        // schon ein Blatt zu diesem Dokument: neue Seite dort unten statt eines weiteren "Notizen – …" (13.11.2026)
        if let onAppend {
            let own = ownSheets.isEmpty
                ? await Self.ownSheets(linked: linkedSheetIDs, named: Self.sheetTitle(for: sourceTitle), library: files,
                                       excluding: excluding, api: api)
                : ownSheets
            if let id = Self.sheetToContinue(own) {
                var f = files.first(where: { $0.id == id })
                if f == nil { f = try? await api.json("/api/files/\(id)", as: LibFile.self) }
                if let f {
                    onAppend(f, template)
                    dismiss()
                    return
                }
            }
        }
        var fields = NotebookDialog.fields(kind: "notebook", title: Self.sheetTitle(for: sourceTitle), template: template,
                                           format: PageFormats.defaultNotebook, orientation: .portrait)
        if let moduleID { fields["module_id"] = "\(moduleID)" }
        do {
            let r = try await api.form("/api/notebooks", fields: fields)
            guard let id = r.s("id"), let f = try await library().first(where: { $0.id == id }) else {
                error = "Das Blatt wurde angelegt, ließ sich aber nicht öffnen. Du findest es in der Bibliothek."
                return
            }
            onPick(f)
            dismiss()
        } catch let e {
            error = e.localizedDescription
        }
    }
}

// Seitenleiste (PageSidebar, ThumbnailStrip, MarkerTag): Views/PageSidebar.swift (Schritt E)

/// Gezeichnete Miniaturen je Seitenschluessel mit Hash-Signatur des gezeichneten Stands.
/// Signatur und Zeichnen laufen ausserhalb des Hauptthreads (Stifteingabe hat Vorrang); nur das Ergebnis wird hier
/// gesetzt. Hoechstens `limit` Miniaturen bleiben im Speicher (zuletzt benutzte zuerst behalten).
@MainActor
final class ThumbnailCache: ObservableObject {
    @Published private(set) var images: [String: UIImage] = [:]
    /// Sichtbare Zellen (Seitenschluessel); nicht veroeffentlicht, damit Scrollen keine Neuberechnung ausloest.
    var visible: Set<String> = []
    let limit: Int
    /// Anzahl gezeichneter Miniaturen (fuer Tests und Diagnose).
    private(set) var renderCount = 0
    private var signatures: [String: Int] = [:]
    private var recent: [String] = []                                            // aeltester zuerst

    init(limit: Int = 60) { self.limit = max(1, limit) }

    /// Signatur des gezeichneten Stands: Seitenaufbau, Seite, Objekte, Quellen der geladenen Bilder.
    nonisolated static func signature(layoutVersion: Int, entry: DisplayLayout.Entry, rotation: Int,
                                      objects: [JSONValue], loadedImages: [String]) -> Int {
        var h = Hasher()
        h.combine(layoutVersion)
        h.combine(entry.key); h.combine(entry.kind); h.combine(entry.template); h.combine(entry.pdfIndex)
        h.combine(rotation)
        h.combine(objects)
        h.combine(loadedImages)
        return h.finalize()
    }

    /// Zeichnet die Miniatur neu, wenn sich die Signatur geaendert hat. `true` = neu gezeichnet.
    /// Die PDF-Seite kommt aus `source`, einer eigenen PDF-Instanz (`OffscreenPDF`); die Seite der PDFView wird hier nie
    /// angefasst, nur ihre Form (`shape`, auf dem Hauptthread gelesen). Vorher wurde eine Kopie der angezeigten Seite im
    /// Hintergrund gezeichnet, gleichzeitig mit den Kacheln der PDFView (Absturz Build 30, iPad 9).
    @discardableResult
    func refresh(key: String, shape: OffscreenPDF.Shape, entry: DisplayLayout.Entry, objects: [JSONValue],
                 images: [String: UIImage], source: OffscreenPDF, layoutVersion: Int, width: CGFloat, scale: CGFloat) async -> Bool {
        // nur Bilder dieser Seite (kleiner Uebergabewert, Signatur aendert sich nur bei eigenen Bildern)
        let srcs = Set(objects.compactMap { $0["type"]?.string == "image" ? $0["src"]?.string : nil })
        let own = images.filter { srcs.contains($0.key) }
        let rotation = shape.rotation
        let sig = await Task.detached(priority: .utility) {
            Self.signature(layoutVersion: layoutVersion, entry: entry, rotation: rotation, objects: objects,
                           loadedImages: own.keys.sorted())
        }.value
        guard signatures[key] != sig else { touch(key); return false }
        signatures[key] = sig
        let img = await source.thumbnail(shape: shape, entry: entry, objects: objects, images: own, width: width, scale: scale)
        guard signatures[key] == sig else { return false }                       // inzwischen neuerer Stand unterwegs
        self.images[key] = img
        renderCount += 1
        touch(key)
        evict()
        return true
    }

    /// Speicherwarnung: Miniaturen, die gerade nicht zu sehen sind, verwerfen (sie werden beim Erscheinen neu gezeichnet)
    func releaseHidden() {
        for key in images.keys where !visible.contains(key) {
            images[key] = nil
            signatures[key] = nil
            recent.removeAll { $0 == key }
        }
    }

    private func touch(_ key: String) {
        recent.removeAll { $0 == key }
        recent.append(key)
    }

    /// Aelteste Miniaturen verwerfen (samt Signatur, damit sie beim naechsten Erscheinen neu gezeichnet werden).
    private func evict() {
        while recent.count > limit {
            let old = recent.removeFirst()
            images[old] = nil
            signatures[old] = nil
        }
    }
}

struct SearchSheet: View {
    @ObservedObject var store: DocumentStore
    @ObservedObject var index: NoteTextIndex
    /// Treffer zeigen (Editor: Stelle markieren bzw. zur Seite; iPhone-Leseansicht ebenso)
    private let pick: (SearchHit) -> Void
    /// Seite, ab der Handschrift und Scans gelesen werden (die gerade offene zuerst)
    private let startAt: () -> Int
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var pdfHits: [SearchHit] = []

    init(store: DocumentStore, bridge: EditorBridge) {
        self.init(store: store, startAt: { bridge.pageIndex }) { hit in
            if let sel = hit.selection { bridge.controller?.show(sel) } else { bridge.controller?.goToPage(hit.pageIndex) }
        }
    }

    /// Ohne Editor (iPhone-Leseansicht, `PhoneDocumentReader`)
    init(store: DocumentStore, startAt: @escaping () -> Int, pick: @escaping (SearchHit) -> Void) {
        self.store = store
        self.index = store.noteIndex
        self.startAt = startAt
        self.pick = pick
    }

    /// Treffer im PDF zuerst, dann Textfelder, Handschrift, Scans (je Gruppe in Seitenreihenfolge)
    private var groups: [(NoteSearch.Source, [SearchHit])] {
        let notes = index.hits(query, layout: store.layout)
        return NoteSearch.Source.allCases.compactMap { source in
            let hits = source == .pdf ? pdfHits : notes.filter { $0.source == source }
            return hits.isEmpty ? nil : (source, hits)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let r = index.reading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Handschrift und Scans werden gelesen … \(r.done) von \(r.total)").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                ForEach(groups, id: \.0) { source, hits in
                    Section {
                        ForEach(hits) { hit in
                            Button {
                                pick(hit)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Seite \(hit.pageIndex + 1)").font(.caption).foregroundStyle(.secondary)
                                    Text(hit.snippet).lineLimit(2)
                                }
                            }
                        }
                    } header: {
                        Label(source.title, systemImage: source.icon)
                    }
                }
            }
            .overlay {
                if query.count >= 2 && groups.isEmpty && index.reading == nil { ContentUnavailableView.search(text: query) }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Im PDF und in deinen Notizen suchen")
            .onChange(of: query) { _, q in pdfHits = store.search(q) }
            .onAppear { index.refresh(store: store, startAt: startAt()) }
            // Lesen nur, solange die Suche offen ist (Akku); Gelesenes bleibt fuer das naechste Mal
            .onDisappear { index.cancel() }
            .navigationTitle("Suchen")
            .toolbar { Button("Fertig") { dismiss() } }
        }
    }
}

struct InfoSheet: View {
    @ObservedObject var store: DocumentStore
    @Environment(\.dismiss) private var dismiss
    /// KI ueber das ChatGPT-Abo verbunden: "Mit KI einordnen" (nur diese Datei, POST /api/files/{id}/analyze)
    @Environment(\.ufAIEnabled) private var aiEnabled
    @State private var info: DocumentInfo?
    @State private var analysis: JSONValue?
    @State private var analyzing = false
    @State private var analysisError: String?

    var body: some View {
        NavigationStack {
            List {
                if let i = info {
                    Section("Dokument") {
                        LabeledContent("Titel", value: i.title)
                        LabeledContent("Datei", value: i.fileName)
                        if let s = i.subject { LabeledContent("Veranstaltung", value: s) }
                        if let f = i.folder { LabeledContent("Stud.IP-Ordner", value: f) }
                    }
                    Section("Seiten") {
                        LabeledContent("Angezeigt", value: "\(i.displayPages)")
                        LabeledContent("Im PDF", value: "\(i.pdfPages)")
                        LabeledContent("Eingefügt (Browser/iPad)", value: "\(i.insertedPages)")
                        if !i.removedPDFPages.isEmpty {
                            LabeledContent("Im Browser entfernt", value: i.removedPDFPages.map(String.init).joined(separator: ", "))
                        }
                        LabeledContent("Lesezeichen", value: "\(i.bookmarks)")
                    }
                    Section("Speichern") {
                        LabeledContent("Status", value: i.status)
                        LabeledContent("Ungesendete Seiten", value: "\(i.unsentPages)")
                        LabeledContent("Serverversion", value: "\(i.serverVersion)")
                    }
                    if aiEnabled || analysis?.s("summary") != nil { analysisSection }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Dokumentinformation")
            .toolbar { Button("Fertig") { dismiss() } }
            .task {
                info = await store.info()
                analysis = try? await store.api.value("/api/files/\(store.file.id)")
            }
        }
    }

    /// KI-Einordnung wie `ai.analyze_file`: Art, Titel, Themen, Schwierigkeit, Lernzeit, Zusammenfassung
    @ViewBuilder private var analysisSection: some View {
        Section("KI-Einordnung") {
            if let a = analysis, a.s("summary") != nil || a.s("ai_title") != nil {
                if let t = a.s("ai_title") { LabeledContent("Titel", value: t) }
                if let d = a.s("doc_type") { LabeledContent("Art", value: d) }
                if let n = a.i("difficulty") { LabeledContent("Schwierigkeit", value: "\(n) von 5") }
                if let m = a.i("est_minutes") { LabeledContent("Lernzeit", value: "ca. \(m) min") }
                if let s = a.s("summary") { Text(s).font(.callout) }
            }
            if aiEnabled {
                Button(analyzing ? "Die KI liest die Datei …" : "Mit KI einordnen") { Task { await analyze() } }
                    .disabled(analyzing)
                    .accessibilityIdentifier("doc.analyze")
                Text(OpenAIKeyLink.isOffered ? "Schickt den Text dieser Datei an dein ChatGPT (nur diese Datei)." : "Schickt den Text dieser Datei an die KI (nur diese Datei).").font(.caption).foregroundStyle(.secondary)
            }
            if let e = analysisError { Text(e).font(.caption).foregroundStyle(.red) }
        }
    }

    private func analyze() async {
        analyzing = true
        analysisError = nil
        defer { analyzing = false }
        do {
            _ = try await store.api.value("/api/files/\(store.file.id)/analyze", method: "POST", body: .object([:]))
            analysis = try await store.api.value("/api/files/\(store.file.id)")
        } catch {
            analysisError = error.localizedDescription
        }
    }
}

/// Papierkorb der Seiten (deletedPages wie im Web-Editor): neueste zuerst, Wiederherstellen an den frueheren Platz.
struct PageTrashSheet: View {
    @ObservedObject var bridge: EditorBridge
    @Environment(\.dismiss) private var dismiss
    @State private var pages: [PageOrder.TrashedPage]?

    var body: some View {
        NavigationStack {
            List {
                if let pages {
                    if pages.isEmpty { ContentUnavailableView("Papierkorb ist leer", systemImage: "trash") }
                    ForEach(pages.reversed(), id: \.trashIndex) { p in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title(p))
                                Text(detail(p)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Wiederherstellen") {
                                Task {
                                    if await bridge.controller?.restorePage(key: p.key) == true { dismiss() } else { await reload() }
                                }
                            }
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Papierkorb")
            .toolbar { Button("Fertig") { dismiss() } }
            .task { await reload() }
        }
    }

    private func reload() async { pages = await bridge.controller?.trashedPages() ?? [] }

    private func title(_ p: PageOrder.TrashedPage) -> String {
        if p.type == "pdf", let i = p.pdfIndex { return "PDF-Seite \(i)" }
        if p.type == "blank" { return "Leere Seite (\(p.template.flatMap { PaperTemplate.names[$0] } ?? "Leer"))" }
        return "Eingefügte Seite"
    }

    private func detail(_ p: PageOrder.TrashedPage) -> String {
        var parts = ["früher an Stelle \(p.position + 1)"]
        if p.objectCount > 0 { parts.append("\(p.objectCount) Notizen") }
        if let d = p.deletedAt { parts.append(d.formatted(date: .abbreviated, time: .shortened)) }
        return parts.joined(separator: " · ")
    }
}

/// Leiste im Objektmodus (unten): was zur Auswahl ("Auswählen": Farbe, Schrift, Löschen), zum markierten Text ("Text
/// markieren") bzw. zu "Bereich an KI" gehoert. Die Werkzeuge selbst, Rueckgaengig und Wiederholen stehen in der festen
/// Werkzeugleiste oben (`EditorToolbar`).
struct ObjectToolbar: View {
    @ObservedObject var bridge: EditorBridge
    private let colors: [(String, String)] = [("#e5322d", "Rot"), ("#1d2130", "Schwarz"), ("#2f7fd1", "Blau"), ("#2e9e5b", "Grün"),
                                              ("#f5d90a", "Gelb"), ("#fff7a8", "Notizgelb")]

    var body: some View {
        VStack(spacing: 8) {
            if bridge.objectTool == .area {
                // Bereich an KI: was zu tun ist, und der Weg zurueck
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.dashed").accessibilityHidden(true)
                    Text("Rahmen ziehen oder Bereich einkreisen").font(.callout)
                    Button { bridge.controller?.sendVisiblePage() } label: { Label("Ganze Seite", systemImage: "doc.viewfinder") }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("objects.area.page")
                    Button("Fertig") { bridge.finishObjectTools() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("objects.area.done")
                }
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            if bridge.objectTool == .markup {
                HStack(spacing: 8) {
                    if bridge.textSelected {
                        Button("Markieren") { bridge.controller?.objects.applyMarkup(.highlight) }
                            .accessibilityIdentifier("objects.markup.highlight")
                        Button("Unterstreichen") { bridge.controller?.objects.applyMarkup(.underline) }
                        Button("Durchstreichen") { bridge.controller?.objects.applyMarkup(.strike) }
                        Divider().frame(height: 24)
                        Button { bridge.askTutor("explain") } label: { Label("KI erklärt", systemImage: "sparkles") }
                            .accessibilityIdentifier("objects.markup.tutorExplain")
                        Button { bridge.askTutor("steps") } label: { Label("KI löst", systemImage: "sparkles") }
                            .accessibilityIdentifier("objects.markup.tutorSolve")
                        Button { bridge.makeFlashcard() } label: { Label(PDFEditorController.flashcardTitle, systemImage: "rectangle.on.rectangle") }
                            .accessibilityIdentifier("objects.markup.flashcard")
                    } else {
                        Text("Text in der PDF auswählen (gedrückt halten und ziehen)").font(.callout).foregroundStyle(.secondary)
                    }
                    Button("Fertig") { bridge.finishObjectTools() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("objects.markup.done")
                }
                .buttonStyle(.borderedProminent)
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            if bridge.objectSelection > 0 { selectionActions }
        }
    }

    private var selectionActions: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(colors, id: \.0) { c in
                    Button(c.1) { bridge.controller?.objects.recolorSelection(c.0) }
                }
            } label: { Image(systemName: "paintpalette").frame(width: 30, height: 30) }
                .accessibilityLabel("Farbe")
            Button { bridge.controller?.objects.resizeText(by: -2) } label: { Image(systemName: "textformat.size.smaller").frame(width: 30, height: 30) }
                .disabled(bridge.objectSelection == 0).accessibilityLabel("Schrift kleiner")
            Button { bridge.controller?.objects.resizeText(by: 2) } label: { Image(systemName: "textformat.size.larger").frame(width: 30, height: 30) }
                .disabled(bridge.objectSelection == 0).accessibilityLabel("Schrift größer")
            Button(role: .destructive) { bridge.controller?.objects.deleteSelection() } label: {
                Image(systemName: "trash").frame(width: 30, height: 30)
            }
            .disabled(bridge.objectSelection == 0).accessibilityLabel("Auswahl löschen")
            .accessibilityIdentifier("objects.delete")
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 4)
    }
}

/// Gliederung des Dokuments (`outline` wie im Web): antippen springt zur Seite, Wischen entfernt den Eintrag.
struct OutlineSheet: View {
    @ObservedObject var bridge: EditorBridge
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [(title: String, key: String, index: Int?)]?

    var body: some View {
        NavigationStack {
            List {
                if let entries {
                    if entries.isEmpty {
                        ContentUnavailableView("Noch keine Gliederung", systemImage: "list.bullet.indent",
                                               description: Text("Mehr → Seite → Zur Gliederung hinzufügen"))
                    }
                    ForEach(Array(entries.enumerated()), id: \.offset) { i, e in
                        Button {
                            if let index = e.index { bridge.controller?.goToPage(index); dismiss() }
                        } label: {
                            HStack {
                                Text(e.title)
                                Spacer()
                                Text(e.index.map { "Seite \($0 + 1)" } ?? "Seite fehlt").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(e.index == nil)
                        .swipeActions {
                            if bridge.controller?.writable == true {
                                Button("Entfernen", role: .destructive) {
                                    Task { await bridge.controller?.removeOutline(at: i); await reload() }
                                }
                            }
                        }
                        // Mac (Rechtsklick) und Tastatur: dasselbe wie das Wischen
                        .contextMenu {
                            if bridge.controller?.writable == true {
                                Button(role: .destructive) {
                                    Task { await bridge.controller?.removeOutline(at: i); await reload() }
                                } label: { Label("Entfernen", systemImage: "trash") }
                            }
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Gliederung")
            .toolbar { Button("Fertig") { dismiss() } }
            .task { await reload() }
        }
    }

    private func reload() async { entries = await bridge.controller?.outlineEntries() ?? [] }
}

/// Hilfetext beim Zeigen mit der Maus, nur am Mac (iPad unveraendert ohne Hilfetext)
struct MacHelp: ViewModifier {
    let text: String

    @ViewBuilder func body(content: Content) -> some View {
        if PDFEditorController.isMac { content.help(text) } else { content }
    }
}

/// Teilen-Dialog des Systems (z. B. exportierte PDF in Dateien sichern).
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Grund, warum gerade nicht gespeichert wird (PIN, Zugriff, Serverfehler, offline) oder Hinweis auf
/// zusammengefuehrte Konflikte; Tippen zeigt "Erneut versuchen" bzw. "Verstanden".
struct SyncIssueBadge: View {
    @ObservedObject var store: DocumentStore

    var body: some View {
        if let issue = store.syncIssue {
            Menu {
                if case .konflikteZusammengefuehrt = issue {
                    Button("Verstanden") { Task { await store.acknowledgeSyncNotice() } }
                } else if case .seitenreihenfolge = issue {
                    // Vertrag mergeDocument: beide Geraete haben umsortiert, die Reihenfolge dieses Geraets gilt
                    Button("Verstanden") { Task { await store.acknowledgeSyncNotice() } }
                } else {
                    Button("Erneut versuchen") { Task { await store.retrySync() } }
                }
            } label: {
                Label(Self.text(issue, pages: store.conflictPages), systemImage: issue.needsUserAction ? "exclamationmark.triangle" : "info.circle")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(issue.needsUserAction ? .red : .orange)
                    .lineLimit(1)
            }
            .accessibilityLabel(Self.text(issue, pages: store.conflictPages))
        }
    }

    /// Text des Hinweises; bei zusammengefuehrten Konflikten mit den betroffenen Seiten ("– Seite 3", "– Seiten 2, 5"),
    /// damit man weiss, wo man nachsehen sollte
    static func text(_ issue: SyncIssue, pages: [Int]) -> String {
        guard case .konflikteZusammengefuehrt = issue, !pages.isEmpty else { return issue.label }
        let shown = pages.prefix(6).map(String.init).joined(separator: ", ") + (pages.count > 6 ? " …" : "")
        return issue.label + " – " + (pages.count == 1 ? "Seite " : "Seiten ") + shown
    }
}

/// Abstand zwischen Knopfgruppen der Editor-Leiste (ab iOS 26 eigene Glasflaeche je Gruppe); davor ohne Wirkung
struct UFToolbarGap: ToolbarContent {
    var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }
    }
}

/// Anzeige in der Leiste, die kein Knopf ist (Sicherungsstand): ab iOS 26 ohne Glasflaeche, damit sie nicht wie ein
/// Knopf aussieht
struct UFPlainToolbarItem<Content: View>: ToolbarContent {
    @ViewBuilder var content: Content

    var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarTrailing) { content }.sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarTrailing) { content }
        }
    }
}

struct StatusLabel: View {
    let status: SyncStatus

    var body: some View {
        // Normalfall nur das Symbol mit fester Breite: der Text wechselt nach jedem Strich ("Speichert …", "Gespeichert")
        // und liess die Leiste springen; Probleme stehen weiter mit Text da
        Group {
            if problem {
                Label(status.label, systemImage: icon).labelStyle(.titleAndIcon).lineLimit(1).fixedSize()
            } else {
                Image(systemName: icon).frame(width: 26, height: 22)
            }
        }
        .font(.caption)
        .foregroundStyle(color)
        .help(status.label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.label)
    }

    private var problem: Bool { Self.needsAttention(status) }

    /// Offline, nicht gesichert oder Konflikt: der Stand steht mit Text da (auch in schmaler Kopfzeile)
    static func needsAttention(_ status: SyncStatus) -> Bool {
        switch status {
        case .offline, .localSaveFailed, .conflictUnresolved: return true
        default: return false
        }
    }

    private var icon: String {
        switch status {
        case .saved: return "checkmark.icloud"
        case .uploading, .loading: return "arrow.triangle.2.circlepath.icloud"
        case .pending: return "internaldrive"
        case .offline: return "icloud.slash"
        case .localSaveFailed, .conflictUnresolved: return "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch status {
        case .localSaveFailed, .conflictUnresolved: return .red
        case .offline: return .orange
        default: return .secondary
        }
    }
}

struct PDFEditorView: UIViewControllerRepresentable {
    let store: DocumentStore
    let bridge: EditorBridge
    let pencilOnly: Bool
    let layoutVersion: Int
    var tools: EditorToolState?
    var ownsToolPicker = true
    var undoManager: UndoManager?
    var initialPDFPage: Int?
    /// gemerkte Stelle des Reiters (ohne `initialPDFPage`)
    var initialSpot: DocumentViewSpot?
    /// fremde Loesungen (nur Anzeige) und Sichtbarkeit der eigenen Notizen
    var foreignLayers: [ForeignSolutionLayer] = []
    var ownNotesVisible = true
    /// Tarif erlaubt Schreiben (Plus); sonst nur ansehen
    var canEdit = true
    /// Korrektur-Modus bzw. angezeigte empfangene Korrektur (`CorrectionMode.swift`)
    var correction: CorrectionSession?
    var shownCorrection: CommunityCorrection?
    var onCorrectionNote: ((CorrectionNoteEvent) -> Void)?
    /// KI verbunden (`ufAIEnabled`)
    var aiAvailable = false
    /// Bildschirm fixieren (`EditorFreezeLock.swift`)
    var freezeMode: EditorFreeze.Mode = .off
    var traceContrast = false
    /// Lage der Werkzeuge (Einstellung): "Schwebend" zeigt der Editor Apples Palette
    var toolbarPlacement: EditorToolbarPlacement = .standard

    func makeUIViewController(context: Context) -> PDFEditorController {
        let vc = PDFEditorController(store: store, tools: tools, ownsToolPicker: ownsToolPicker,
                                     undoManager: undoManager, initialPDFPage: initialPDFPage, initialSpot: initialSpot)
        let bridge = self.bridge
        vc.pencilOnly = pencilOnly
        vc.foreignLayers = foreignLayers
        vc.ownNotesVisible = ownNotesVisible
        vc.canEdit = canEdit
        vc.onCorrectionNote = onCorrectionNote
        vc.correction = correction
        vc.shownCorrection = shownCorrection
        vc.onZoomChange = { [weak bridge] z in bridge?.zoomPercent = Int((z * 100).rounded()) }
        vc.onPageChange = { [weak bridge] i, key in
            bridge?.pageIndex = i
            bridge?.pageKey = key
        }
        vc.objects.onSelectionChange = { [weak bridge] n in bridge?.objectSelection = n }
        vc.objects.onToolChange = { [weak bridge] t in bridge?.objectTool = t }
        vc.onObjectModeChange = { [weak bridge] on, t in
            if bridge?.objectMode != on { bridge?.objectMode = on }
            if bridge?.objectTool != t { bridge?.objectTool = t }
        }
        if ownsToolPicker { vc.onToolbarChange = { [weak bridge] m in if bridge?.toolbar != m { bridge?.toolbar = m } } }
        vc.objects.onTextSelection = { [weak bridge] on in bridge?.textSelected = on }
        // "Als Karteikarte" im Bearbeitungsmenue, Hinweise und KI-Anhaenge melden sich ueber die Bruecke
        vc.aiAvailable = aiAvailable
        vc.onAskAI = { [weak bridge] a in bridge?.attachToTutor(a) }
        vc.onHint = { [weak bridge] text in bridge?.hint = EditorBridge.Hint(text: text) }
        vc.onFlashcardFromSelection = { [weak bridge] text in bridge?.makeFlashcard(text) }
        vc.onRequestImage = { [weak bridge] fromFiles in bridge?.request(fromFiles ? .imageFile : .photo) }
        vc.onMagnifierChange = { [weak bridge] on in bridge?.magnifierOpen = on }
        vc.onEndPresentation = { [weak bridge] in bridge?.request(.endPresentation) }
        vc.traceContrast = traceContrast
        vc.freezeMode = freezeMode
        vc.toolbarPlacement = toolbarPlacement
        bridge.controller = vc
        return vc
    }

    /// Wird bei jeder SwiftUI-Aktualisierung aufgerufen (z. B. Statuswechsel). Fasst die Canvas nicht an; baut die
    /// Anzeige nur neu auf, wenn sich die Seitenstruktur geaendert hat.
    func updateUIViewController(_ vc: PDFEditorController, context: Context) {
        if vc.pencilOnly != pencilOnly { vc.pencilOnly = pencilOnly }
        if vc.shownLayoutVersion != layoutVersion { vc.showLayout() }
        if vc.foreignSignature != PDFEditorController.signature(foreignLayers) { vc.foreignLayers = foreignLayers }
        if vc.ownNotesVisible != ownNotesVisible { vc.ownNotesVisible = ownNotesVisible }
        if vc.canEdit != canEdit { vc.canEdit = canEdit }
        if vc.aiAvailable != aiAvailable { vc.aiAvailable = aiAvailable }
        vc.onCorrectionNote = onCorrectionNote
        if vc.correction !== correction { vc.correction = correction }
        if vc.shownCorrection != shownCorrection { vc.shownCorrection = shownCorrection }
        if vc.traceContrast != traceContrast { vc.traceContrast = traceContrast }
        if vc.freezeMode != freezeMode { vc.freezeMode = freezeMode }
        if vc.toolbarPlacement != toolbarPlacement { vc.toolbarPlacement = toolbarPlacement }
    }
}

/// Schreibende Eintraege im Menue "Mehr" ohne Schreiben im Tarif (Free, nach dem Herabstufen): sichtbar mit Schloss
/// "(ab Plus)" statt grau, jeder oeffnet die Tarifwahl (Auftrag des Inhabers 12.11.2026)
struct EditorLockedWriteItems: View {
    let plan: UFPlan
    let bookmarked: Bool
    let open: () -> Void

    /// Eintraege wie im Menue mit Plus (Lesezeichen, Seiten, Text, Bilder, Schreiblupe)
    static func titles(bookmarked: Bool) -> [String] {
        [bookmarked ? "Lesezeichen entfernen" : "Lesezeichen setzen", "Leere Seite danach", "Seite in den Papierkorb",
         "Papierkorb …", "Seite drehen", "Text hinzufügen", "Bild aus Fotos …", "Bild aus Dateien …", "Schreiblupe"]
    }

    var body: some View {
        ForEach(Self.titles(bookmarked: bookmarked), id: \.self) { title in
            Button(action: open) { Label(UFLock.label(title, plan), systemImage: UFLock.symbol) }
                .accessibilityValue(UFLock.accessibilityValue(plan))
        }
    }
}

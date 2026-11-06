import PDFKit
import PencilKit
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
    /// Die Palette traegt unsere Objektwerkzeuge (iPadOS 18 mit eigenen Eintraegen); sonst Objektleiste und
    /// "Tinte/Objekte" wie unter iPadOS 17
    @Published var toolsInPalette = false

    struct TutorRequest: Equatable {
        let id = UUID()
        let mode: String
        let selection: String
    }

    /// "KI fragen" am Rand der Palette (Schritt F): jede Erhoehung oeffnet die KI-Hilfe
    @Published var askAIRequested = 0
    /// iPhone: Hoehe der unten angedockten Palette ueber dem Sicherheitsabstand (die kompakte Leiste rueckt darueber)
    @Published var paletteInset: CGFloat = 0
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

    /// "Fertig" in der Objektleiste: zurueck zum Stift (ab iPadOS 18 ueber die Palette)
    func finishObjectTools() {
        controller?.finishObjectTools()
        objectMode = controller?.objects.isActive ?? false
    }

    func undo() { controller?.undo() }
    func redo() { controller?.redo() }
    func fitWidth() { controller?.fitWidth() }
}

/// Eine Werkzeugpalette und ein Rueckgaengig-Verlauf fuer beide Seiten der geteilten Ansicht. Die Palette traegt ab
/// iPadOS 18 auch die Objektwerkzeuge (`EditorPalette`).
@MainActor
final class ToolPickerHolder: ObservableObject {
    let picker = EditorPalette.makePicker()
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
    @StateObject private var tools = ToolPickerHolder()
    @AppStorage("uniflow.pencilOnly") private var pencilOnly = true
    @AppStorage("uniflow.hand") private var hand = "right"
    @AppStorage("uniflow.splitFraction") private var splitFraction = 0.42
    /// Kompakte Fassung (iPhone, schmaler Split View; docs/IPHONE-2026-11-04.md): PDF bildschirmfuellend, Seiten und
    /// KI-Hilfe als Blatt von unten, Werkzeuge in einer Leiste unten, "Daneben öffnen" aus
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize
    /// Ziele des Logos (AppShell): kompakt im langen Druck auf "Zurück"
    @Environment(\.ufLogoMenu) private var logoMenu
    /// iPhone (kein Pencil): der Finger schreibt nur im Modus "Zeichnen"; jedes Dokument beginnt mit "Blättern"
    @State private var phoneDraws = false
    @State private var fullScreen = false
    @State private var showSidebar = false
    @State private var showSearch = false
    @State private var showTutor = false
    /// KI-Start bittet um offene KI-Hilfe (`UFRouter.tutorOpenRequest`)
    @EnvironmentObject private var router: UFRouter
    /// KI ueber das ChatGPT-Abo verbunden (Vorlesungsmarker; die KI-Hilfe zeigt ohne Verbindung den Weg dorthin)
    @Environment(\.ufAIEnabled) private var aiEnabled
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

    init(file: LibFile, api: APIClient, readOnly: Bool = false, initialPDFPage: Int? = nil, task: Int? = nil, correcting: String? = nil,
         onBack: (() -> Void)? = nil) {
        self.onBack = onBack
        self.api = api
        self.readOnly = readOnly
        self.initialPDFPage = initialPDFPage
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
            present { lockedFeature = .flashcards }
            return
        }
        flashcards.attach(api)
        Task {
            if !flashcards.loaded { try? await flashcards.load() }
            present { flashcardQuestion = question }
        }
    }

    /// Skript auf der Seite der freien Hand: Rechtshaender -> links.
    private var scriptLeft: Bool { hand != "left" }

    // MARK: Kompakte Fassung (iPhone)

    /// Kompakte Darstellung nach Platz (`UFCompact.isCompact`); das iPad (regulaer) bleibt wie es ist
    private var compact: Bool { UFCompact.isCompact(horizontal: hSize, vertical: vSize) }

    /// Finger schreibt: iPhone ueber "Zeichnen" (nur fuer dieses Dokument), iPad ueber den gemerkten Schalter
    /// "Nur Stift / Finger zeichnet" (kompakt heisst er "Blättern / Zeichnen")
    private var fingerDraws: Bool { UFCompact.isPhone ? phoneDraws : !pencilOnly }

    /// Eingabeart des Editors: iPad wie bisher `pencilOnly`; iPhone "Blättern" = `.pencilOnly` (ein Finger blaettert und
    /// markiert Text), "Zeichnen" = `.anyInput` (ein Finger schreibt, zwei Finger blaettern und zoomen)
    private var editorPencilOnly: Bool { !fingerDraws }

    /// iPhone im Modus "Blättern": keine Palette (sie diente nur dem Schreiben)
    private var paletteSuppressed: Bool { UFCompact.isPhone && !phoneDraws }

    /// "Zeichnen" geht: eigene Notizen schreibbar oder Korrektur-Modus
    private var drawAvailable: Bool { (canWrite && ownNotesVisible) || correction != nil }

    /// "Blättern / Zeichnen" umschalten. Ohne Plus: Sperrkarte statt eines Fingers, der still nichts schreibt.
    /// Zurueck zu "Blättern" beendet ein Objektwerkzeug (sonst legte ein Antippen Text an, statt zu blaettern).
    private func setFingerDraws(_ on: Bool) {
        if on, !drawAvailable {
            if !planAllowsWriting && !readOnly { present { lockedFeature = .pencilWriting } }
            return
        }
        if UFCompact.isPhone { phoneDraws = on } else { pencilOnly = !on }
        if !on, bridge.objectMode { bridge.finishObjectTools() }
    }

    /// Kompakt: hoechstens ein Blatt zur Zeit. Ist "Seiten" oder die KI-Hilfe offen, schliessen sie zuerst und `open`
    /// folgt nach dem Wegschieben (sonst kaeme das zweite Blatt nicht). Breit (iPad) sofort.
    private func present(_ open: @escaping () -> Void) {
        guard compact, showTutor || showSidebar else { open(); return }
        showTutor = false
        showSidebar = false
        DispatchQueue.main.asyncAfter(deadline: .now() + TutorPanel.sheetDismissDelay, execute: open)
    }

    /// Abstand des Hinweises ("Rahmen ziehen …") vom unteren Rand: iPad ueber der Objektleiste; iPhone ueber der
    /// unteren Leiste (und der Objektleiste bzw. der angedockten Palette)
    private var hintBottom: CGFloat {
        guard compact else { return bridge.objectMode ? 96 : 28 }
        return 76 + (bridge.objectMode ? (bridge.objectTool == .area ? 100 : 64) : 0) + bridge.paletteInset
    }

    /// KI-Hilfe oeffnen (kompakt: das Blatt "Seiten" macht vorher Platz)
    private func openTutor() {
        if compact, showSidebar {
            showSidebar = false
            DispatchQueue.main.asyncAfter(deadline: .now() + TutorPanel.sheetDismissDelay) { showTutor = true }
        } else {
            showTutor = true
        }
    }

    /// Seitenuebersicht oeffnen bzw. schliessen (kompakt: die KI-Hilfe macht vorher Platz)
    private func toggleSidebar() {
        if compact, showTutor, !showSidebar {
            showTutor = false
            DispatchQueue.main.asyncAfter(deadline: .now() + TutorPanel.sheetDismissDelay) { showSidebar = true }
        } else {
            withAnimation(UF.motion(.default)) { showSidebar.toggle() }
        }
    }

    /// "Zum Abpausen einfrieren": nur die Seite, keine Leisten, keine Eingabe
    private var tracing: Bool { freeze.isTracing }

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

    /// Breite der KI-Hilfe: genug zum Lesen, die PDF behaelt den Grossteil
    static func tutorWidth(_ total: CGFloat) -> CGFloat { min(400, max(300, total * 0.32)) }

    /// KI-Hilfe neben der PDF; Seite der Original-PDF aus dem Seitenaufbau (wie der Skriptvorschlag), sonst aus dem
    /// Schluessel, beides beim Senden
    private var tutorPanel: some View { tutorPanel(inSheet: false) }

    private func tutorPanel(inSheet: Bool) -> some View {
        TutorPanel(fileID: store.file.id, fileName: store.file.displayTitle,
                   page: { store.entry(forPageIndex: bridge.pageIndex)?.pdfIndex ?? Self.pdfPage(key: bridge.pageKey, index: bridge.pageIndex) },
                   selection: { bridge.controller?.pdfView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" },
                   open: { id, page in if id == store.file.id { bridge.controller?.goToPage(page - 1) } },
                   close: { showTutor = false }, request: $bridge.tutorRequest, attachment: $bridge.tutorAttachment,
                   moduleID: store.file.module_id,                       // "Wochentest erstellen" waehlt das Modul des Dokuments vor
                   // Seitennotizen und Blatt daneben dieser Folie gehen als Kontext mit (05.11.2026)
                   ownNotes: { [store, bridge, api, companionStore] in
                       await AttachedNotes.text(for: store, pageKey: bridge.pageKey, api: api, open: companionStore)
                   },
                   inSheet: inSheet)
    }

    /// "Bereich an KI" (05.11.2026): Rahmen ziehen bzw. einkreisen (Werkzeug wie in der Palette) oder ohne Gesten die
    /// ganze angezeigte Seite
    @ViewBuilder private var areaMenuItems: some View {
        // kompakt: offene Blaetter (Seiten, KI-Hilfe) machen zuerst Platz, damit der Finger den Bereich ziehen kann
        Button { present { bridge.controller?.startAreaCapture() } } label: { Label("Bereich an KI …", systemImage: "rectangle.dashed") }
            .accessibilityIdentifier("doc.areaAI.pick")
        Button { present { bridge.controller?.sendVisiblePage() } } label: { Label("Ganze Seite an KI", systemImage: "doc.viewfinder") }
            .accessibilityIdentifier("doc.areaAI.page")
    }

    private var isExercise: Bool {
        let f = store.file
        if ["uebung", "loesung", "klausur"].contains(f.doc_type ?? "") { return true }
        let text = (f.name + " " + (f.studip_folder ?? "")).lowercased()
        return ["übung", "uebung", "blatt", "aufgabe"].contains { text.contains($0) }
    }

    var body: some View {
        Group {
            if let error = store.errorMessage {
                ContentUnavailableView("Dokument nicht verfügbar", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if store.pdf != nil {
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        // Seitenleiste auf der Seite der freien Hand (Linkshaender rechts), damit die Schreibhand sie
                        // nicht verdeckt oder beruehrt
                        // kompakt: Seiten und KI-Hilfe als Blatt von unten, keine geteilte Ansicht (siehe unten)
                        if showSidebar, scriptLeft, !compact, !tracing {
                            PageSidebar(store: store, bridge: bridge, markers: markers, canEdit: canWrite).frame(width: 200)
                            Divider()
                        }
                        if showTutor, scriptLeft, !compact, !tracing {
                            tutorPanel.frame(width: Self.tutorWidth(geo.size.width))
                            Divider()
                        }
                        if hasSidePane, scriptLeft, !compact, !tracing {
                            sidePane.frame(width: geo.size.width * splitFraction)
                            splitHandle(width: geo.size.width)
                        }
                        primaryPane
                        if hasSidePane, !scriptLeft, !compact, !tracing {
                            splitHandle(width: geo.size.width)
                            sidePane.frame(width: geo.size.width * splitFraction)
                        }
                        if showTutor, !scriptLeft, !compact, !tracing {
                            Divider()
                            tutorPanel.frame(width: Self.tutorWidth(geo.size.width))
                        }
                        if showSidebar, !scriptLeft, !compact, !tracing {
                            Divider()
                            PageSidebar(store: store, bridge: bridge, markers: markers, canEdit: canWrite).frame(width: 200)
                        }
                    }
                    .coordinateSpace(NamedCoordinateSpace.named("split"))
                }
            } else {
                ProgressView("Lädt…")
            }
        }
        .navigationTitle(store.file.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(fullScreen || tracing ? .hidden : .visible, for: .navigationBar)
        .toolbar {
            if compact { compactToolbar } else { toolbar }
        }
        .toolbar(removing: .sidebarToggle)                  // eigener Knopf "Seiten"; zwei gleiche Symbole verwirrten
        // kompakt: eigenes Zurueck (Route davor bzw. Bibliothek) statt des Zurueck der zusammengeklappten Spaltenansicht
        .navigationBarBackButtonHidden(compact && (!readOnly || onBack != nil))
        .overlay(alignment: .bottom) {
            // Abpausen: keine Leiste, auch nicht die untere des iPhones
            if tracing {
                EmptyView()
            } else if compact {
                if store.pdf != nil, store.errorMessage == nil { compactBottom }
            } else if bridge.objectMode {
                ObjectToolbar(bridge: bridge).padding(.bottom, 12)
            }
        }
        // kompakt: Seitenuebersicht und KI-Hilfe als Blatt von unten (halb: die Seite bleibt sichtbar und bedienbar)
        .sheet(isPresented: Binding(get: { compact && showSidebar && !tracing }, set: { if !$0 { showSidebar = false } })) {
            PageSidebar(store: store, bridge: bridge, markers: markers, canEdit: canWrite, sheet: true) { showSidebar = false }
                .ufHalfSheet()
        }
        .sheet(isPresented: Binding(get: { compact && showTutor && !tracing }, set: { if !$0 { showTutor = false } })) {
            tutorPanel(inSheet: true)
                .ufHalfSheet()
        }
        .overlay(alignment: .topTrailing) {
            if fullScreen, !tracing {
                Button { fullScreen = false } label: { Label("Vollbild beenden", systemImage: "xmark").padding(10) }
                    .buttonStyle(.borderedProminent).padding()
            }
        }
        // Abpausen: Sperre ueber allem, Schloss auf der Seite der freien Hand; Statusleiste und Home-Balken zurueckhaltend
        .overlay { if tracing { TraceLockOverlay(freeze: freeze, leading: scriptLeft) } }
        .statusBarHidden(tracing)
        .persistentSystemOverlays(tracing ? .hidden : .automatic)
        .defersSystemGestures(on: tracing ? .all : [])
        .preference(key: EditorTracingKey.self, value: tracing)
        .background {
            // Cmd-L: Ansicht fixieren bzw. loesen (beim Abpausen ohne Wirkung)
            Button("") { requestFreeze(.view) }
                .keyboardShortcut("l", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .ufModal(isPresented: Binding(get: { freezeIntroFor != nil }, set: { if !$0 { freezeIntroFor = nil } })) {
            FreezeIntroDialog(maxBrightness: $freezeMaxBrightness, contrast: $freezeContrast, start: { mode in
                freezeIntroFor = nil
                startFreeze(mode)
            }, cancel: { freezeIntroFor = nil })
        }
        // App im Hintergrund: Helligkeit vorerst zurueck, beim Zurueckkommen wieder hell
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { freeze.suspend() } else if phase == .active { freeze.resume() }
        }
        .sheet(isPresented: $showSearch) { SearchSheet(store: store, bridge: bridge) }
        .onChange(of: bridge.tutorRequest) { _, r in if r != nil, !showTutor { openTutor() } }
        // Anhang (markierter Text, Bereich als Bild): KI-Hilfe auf, der Anhang steht im Eingabefeld
        .onChange(of: bridge.tutorAttachment) { _, a in if a != nil, !tracing, !showTutor { openTutor() } }
        .overlay(alignment: .bottom) {
            if let h = bridge.hint, !tracing {
                Text(h.text).ufFont(13.6, 550, lh: 1.35).foregroundStyle(UF.text)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.horizontal, 24).padding(.bottom, hintBottom)
                    .accessibilityIdentifier("doc.hint")
                    .task(id: h.id) {
                        try? await Task.sleep(nanoseconds: 3_500_000_000)
                        if bridge.hint?.id == h.id { bridge.hint = nil }
                    }
            }
        }
        // "KI fragen" am Rand der Palette (Schritt F): dieselbe KI-Hilfe wie der Knopf oben
        .onChange(of: bridge.askAIRequested) { _, _ in openTutor() }
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
        .sheet(isPresented: $showInfo) { InfoSheet(store: store) }
        .sheet(isPresented: $showTrash) { PageTrashSheet(bridge: bridge) }
        .sheet(isPresented: $showOutline) { OutlineSheet(bridge: bridge) }
        .onChange(of: ObjectIdentifier(api)) { _, _ in Task { await store.updateAPI(api) } }
        .sheet(isPresented: $choosingCompanion) {
            CompanionPicker(api: api, moduleID: store.file.module_id, excluding: store.file.id, sourceTitle: store.file.displayTitle,
                            solutions: foreignLayers.map { ($0.id, $0.label) },
                            onSolution: { id in
                                if let layer = foreignLayers.first(where: { $0.id == id }) { companion = nil; solutionSide = layer }
                            }) { f in
                solutionSide = nil
                companion = Companion(file: f, pdfPage: nil)
            }
        }
        .sheet(item: $solutionSheet) { sheet in solutionSheetView(sheet) }
        .sheet(isPresented: $submittingToStudIP) { Self.submitSheet(store: store, api: api, compact: compact) }
        .sheet(isPresented: $submittingToMoodle) { Self.moodleSubmitSheet(store: store, api: api, compact: compact) }
        .sheet(isPresented: $mailingDocument) {
            // Uni-Mail (LUH): Entwurf mit dem PDF als Anhang; kompakt als ganzes Blatt (Empfaenger, Text, Tastatur)
            if let uniMailConnection {
                UniMailDocumentEntry(store: store, api: api, connection: uniMailConnection)
                    .ufFullSheet(when: compact)
            }
        }
        .sheet(item: $lockedFeature) { f in UFLockedSheet(f) { lockedFeature = nil } }
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
                PDFExportNoticeDialog(scope: scope, export: {
                    pendingExport = nil
                    share(scope)
                }, cancel: { pendingExport = nil })
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .uniflowSolutionsChanged)) { _ in
            Task { await reloadSolutionLayers() }
        }
        .onChange(of: entitlements.plan) { _, _ in Task { await reloadSolutionLayers() } }
        .sheet(item: $exportFile) { f in
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
            // -UFDocPanel tutor|pages|companion: KI-Hilfe, Seiten bzw. "Daneben öffnen" gleich offen (Bildvergleiche, Tests)
            switch UserDefaults.standard.string(forKey: "UFDocPanel") {
            case "tutor": showTutor = true
            case "pages": showSidebar = true
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
        .onAppear { store.setShown(true) }
        .onDisappear {
            freeze.end()                          // Fixieren gilt nur fuer diese Sitzung; Bildschirm wie vorher
            correction?.saveNow()                 // Entwurf der Korrektur bleibt bis Senden oder Verwerfen
            store.setShown(false)
            suggestionTask?.cancel()
            Task { await store.pause() }       // Tabwechsel: weiter synchronisieren; endgueltig beendet beim Schliessen
        }
    }

    private var primaryPane: some View {
        PDFEditorView(store: store, bridge: bridge, pencilOnly: editorPencilOnly, layoutVersion: store.layoutVersion,
                      toolPicker: tools.picker, ownsToolPicker: true, undoManager: tools.undo, initialPDFPage: initialPDFPage,
                      foreignLayers: correction.map { [$0.target] } ?? shownCorrectionTarget.map { [$0] } ?? foreignLayers,
                      ownNotesVisible: correction == nil && shownCorrectionTarget == nil && ownNotesVisible, canEdit: canWrite,
                      correction: correction, shownCorrection: correction == nil ? shownCorrection : nil,
                      onCorrectionNote: { event in correctionNoteEvent(event) }, aiAvailable: aiEnabled,
                      paletteSuppressed: paletteSuppressed, freezeMode: freeze.mode, traceContrast: freezeContrast)
            .ignoresSafeArea(edges: tracing ? .all : .bottom)
            .overlay(alignment: .bottom) { if !compact, !tracing { pageInfo } }
            .overlay(alignment: .topLeading) {
                if freeze.mode == .view { FreezeBadge { freeze.unlock() } }
            }
            .overlay(alignment: .top) {
                if !tracing { VStack(spacing: 6) {
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
                }
                .padding(.horizontal, compact ? 12 : 0) }
            }
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
            SolutionSidePane(layer: s, pdf: store.originalPDF) { solutionSide = nil }
                .id("solution-" + s.id)
        } else if let c = companion {
            companionPane(c)
        }
    }

    private func companionPane(_ c: Companion) -> some View {
        CompanionView(file: c.file, api: api, pdfPage: c.pdfPage, toolPicker: tools.picker, undoManager: tools.undo,
                      pencilOnly: editorPencilOnly, canEdit: canWrite, viewLocked: freeze.locksView, onStore: { [store, bridge] s, shown in
                          // SwiftUI garantiert die Reihenfolge von Erscheinen (neu) und Verschwinden (alt) nicht
                          if shown { companionStore = s } else if companionStore === s { companionStore = nil }
                          Self.linkSideSheet(s, shown: shown, main: store, bridge: bridge)
                      }) {
            companion = nil
        }
        .id(c.id + "-" + String(c.pdfPage ?? -1))
    }

    /// Blatt "In Stud.IP abgeben": kompakt (iPhone) von unten, halb/ganz, ohne bedienbaren Hintergrund; iPad wie bisher
    static func submitSheet(store: DocumentStore, api: APIClient, compact: Bool) -> some View {
        StudIPSubmitEntry(store: store, api: api)
            .ufHalfSheet(when: compact)
    }

    /// Blatt "In Moodle/Learnweb abgeben" (HsH, Hildesheim): kompakt von unten wie das Stud.IP-Blatt, iPad wie bisher
    static func moodleSubmitSheet(store: DocumentStore, api: APIClient, compact: Bool) -> some View {
        MoodleSubmitEntry(store: store, api: api)
            .ufHalfSheet(when: compact)
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
            let f = scriptLeft ? x / max(width, 1) : (width - x) / max(width, 1)
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
                if compact {
                    // kompakt keine geteilte Ansicht: die Skriptstelle als eigenes Dokument oeffnen
                    Button("Öffnen") { router.go(.doc(s.fileID, page: s.page)) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .accessibilityIdentifier("doc.suggestion.open")
                } else {
                Button("Daneben öffnen") {
                    if entitlements.allows(.splitView) {
                        solutionSide = nil
                        companion = Companion(file: libFile(id: s.fileID, title: s.title), pdfPage: s.page)
                    } else {
                        lockedFeature = .splitView
                    }
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                }
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
            if PDFEditorController.isMac {
                // iPad: Rueckgaengig und Wiederholen stehen in Apples Palette (derselbe Verlauf fuer Striche, Objekte und
                // eingefuegte Seiten); im Objektmodus zusaetzlich in der Objektleiste. Am Mac bleiben sie hier.
                Button { bridge.undo() } label: { Label("Rückgängig", systemImage: "arrow.uturn.backward") }
                    .disabled(!canWrite && correction == nil)
                Button { bridge.redo() } label: { Label("Wiederholen", systemImage: "arrow.uturn.forward") }
                    .disabled(!canWrite && correction == nil)
            }
            if !planAllowsWriting && !readOnly {
                // Free: Schloss mit Weg zur Abo-Seite statt still nicht schreibender Stift
                Button { lockedFeature = .pencilWriting } label: { Label("Schreiben (\(UFPlan.plus.name))", systemImage: "lock") }
                    .labelStyle(.titleAndIcon)
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
            Button {
                // markierter Text geht als Anhang mit (sichtbar im Eingabefeld), statt erst beim Senden gelesen zu werden
                if !showTutor, let a = bridge.controller?.selectionAttachment() { bridge.tutorAttachment = a }
                showTutor.toggle()
            } label: { Label(showTutor ? "KI-Hilfe schließen" : "KI-Hilfe", systemImage: "sparkles") }
                .accessibilityIdentifier("doc.tutor")
                .contextMenu { areaMenuItems }
            Button {
                if hasSidePane { companion = nil; solutionSide = nil }
                else if entitlements.allows(.splitView) { choosingCompanion = true }
                else { lockedFeature = .splitView }
            } label: {
                // immer das Symbol der Teilung (die Sperre nennt der Text): nur "Schreiben (Plus)" links traegt das Schloss
                Label(!hasSidePane ? (entitlements.allows(.splitView) ? "Geteilt" : "Geteilt (\(UFPlan.plus.name))") : "Teilung beenden",
                      systemImage: "rectangle.split.2x1")
            }
        }
        UFToolbarGap()
        ToolbarItemGroup(placement: .topBarTrailing) {
            // unser Schalter (Standard: nur der Stift schreibt, der Finger blaettert); der Schalter der Palette ist aus,
            // er schreibt nur die iPadOS-Einstellung (siehe `EditorPalette`)
            Button { pencilOnly.toggle() } label: {
                Label(pencilOnly ? "Nur Stift" : "Finger zeichnet", systemImage: pencilOnly ? "applepencil" : "hand.draw")
            }
            .accessibilityIdentifier("doc.pencilOnly")
            if !bridge.toolsInPalette {
                // ab iPadOS 18 stehen Text, Haftnotiz, Formen, Auswahl und Text markieren in der Palette; sonst hier
                Button { bridge.setObjectMode(!bridge.objectMode) } label: {
                    Label(bridge.objectMode ? "Objekte" : "Tinte", systemImage: bridge.objectMode ? "square.on.circle" : "pencil.tip")
                }
                .disabled(!ownNotesVisible || !canWrite || correction != nil)
                .accessibilityIdentifier("doc.objectMode")
            }
            layersMenu
        }
        UFToolbarGap()
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu { shareMenuItems } label: { Label(exporting ? "Exportiert…" : "Teilen", systemImage: "square.and.arrow.up") }
                .disabled(exporting || store.pdf == nil)
            Menu { moreMenuItems } label: { Label("Mehr", systemImage: "ellipsis.circle") }
        }
    }

    /// Menue "Teilen": privat exportieren, nur eigene Notizen teilen (iPad in der Leiste, kompakt im Menue "…")
    @ViewBuilder private var shareMenuItems: some View {
        // A) privat: Original-PDF mit Notizen (auch in Free), vorher Hinweis auf das Originalmaterial
        Section("PDF exportieren (nur privat)") {
            Button { present { pendingExport = .document } } label: { Label("Ganzes Dokument", systemImage: "doc.on.doc") }
            Button { present { pendingExport = .page(bridge.pageIndex) } } label: { Label("Diese Seite", systemImage: "doc") }
        }
        // B) nur eigene Notizen, ohne Original (Teilen ab Plus; "Meine geteilten Lösungen" mit Zurueckziehen fuer alle)
        Section("Nur eigene Notizen") {
            Button { present { openSolutionSheet(.share) } } label: {
                Label(Self.lockedLabel("Lösung teilen …", entitlements.access(.shareSolutions)),
                      systemImage: entitlements.allows(.shareSolutions) ? "person.2" : "lock")
            }
            Button { present { openSolutionSheet(.shared) } } label: { Label("Meine geteilten Lösungen …", systemImage: "tray.full") }
        }
        // C) eigene Loesung mit Notizen in Stud.IP hochladen (Entscheidung des Inhabers 05.11.2026)
        if StudIPSubmitEntry.offered(api: api, readOnly: readOnly || store.isOldVersion) {
            Section("Abgeben") {
                Button { present { submittingToStudIP = true } } label: {
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
                Button { present { submittingToMoodle = true } } label: { Label("In Moodle abgeben …", systemImage: "tray.and.arrow.up") }
                    .accessibilityIdentifier("doc.submitMoodle")
            }
        }
        // Uni Hildesheim: in einer Learnweb-Aufgabe abgeben (dasselbe Blatt, Sitzung des Learnwebs, 05.11.2026)
        if MoodleSubmitEntry.offeredLearnweb(api: api, readOnly: readOnly || store.isOldVersion, hildesheim: hildesheimConnection) {
            Section("Abgeben") {
                Button { present { submittingToMoodle = true } } label: { Label("Im Learnweb abgeben …", systemImage: "tray.and.arrow.up") }
                    .accessibilityIdentifier("doc.submitLearnweb")
            }
        }
        // LUH: als PDF mit Notizen an eine neue Uni-Mail (SOGo), gesendet erst mit "Senden"
        if UniMailDocumentEntry.offered(api: api, connection: uniMailConnection) {
            Section("Per E-Mail") {
                Button { present { mailingDocument = true } } label: { Label("Per Uni-Mail senden …", systemImage: "envelope") }
                    .accessibilityIdentifier("doc.uniMail")
            }
        }
    }

    /// Menue "Mehr": Bereich an KI, Schreiben, Seiten, Navigation, Loesungen, Fassungen, Information, Vollbild
    @ViewBuilder private var moreMenuItems: some View {
        // "Bereich an KI" auch ohne Palette und ohne Schreiben im Tarif (05.11.2026)
        Section("KI-Hilfe") { areaMenuItems }
        if !planAllowsWriting && !readOnly {
            // Free: schreibende Eintraege gesperrt, Schloss fuehrt zur Abo-Seite
            Button { present { lockedFeature = .pencilWriting } } label: {
                Label("Schreiben, Seiten und Lesezeichen ab \(UFPlan.plus.name)", systemImage: "lock")
            }
            Divider()
        } else if !ownNotesVisible {
            // nur ansehen: schreibende Eintraege sind gesperrt
            Button { ownNotesVisible = true } label: {
                Label("Meine Notizen einblenden, um zu bearbeiten", systemImage: "eye")
            }
            Divider()
        }
        // schreiben ins eigene Dokument: gesperrt, solange "Meine Notizen" ausgeblendet ist
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
                        present { actionError = "Diese Seite lässt sich nicht in den Papierkorb legen (letzte Seite oder noch nicht geladen)." }
                    }
                }
            } label: { Label("Seite in den Papierkorb", systemImage: "trash") }
            Button { present { showTrash = true } } label: { Label("Papierkorb …", systemImage: "trash.slash") }
            Button {
                if let key = bridge.pageKey { Task { await store.rotatePage(key: key) } }
            } label: { Label("Seite drehen", systemImage: "rotate.right") }
            Button { present { addingText = true } } label: { Label("Text hinzufügen", systemImage: "textformat") }
            pageToolsMenu
        }
        .disabled(!ownNotesVisible || !canWrite)
        Button { present { goToText = ""; goingToPage = true } } label: { Label("Gehe zu Seite …", systemImage: "arrow.right.to.line") }
        Button { present { showOutline = true } } label: { Label("Gliederung …", systemImage: "list.bullet.indent") }
        Divider()
        Button {
            present { if entitlements.allows(.communityRead) { importingSolution = true } else { solutionSheet = .locked(.communityRead) } }
        } label: { Label("Lösung importieren …", systemImage: "square.and.arrow.down") }
        if !store.versions.isEmpty {
            // S7: aufbewahrte alte Fassungen mit ihren Notizen (nur zum Ansehen)
            Section("Alte Fassungen") {
                ForEach(store.versions) { v in
                    Button { present { openedVersion = v } } label: { Label(v.label, systemImage: "doc.badge.clock") }
                        .disabled(!v.available)
                }
            }
        }
        Button { present { showInfo = true } } label: { Label("Dokumentinformation", systemImage: "info.circle") }
        Button { present { fullScreen = true } } label: { Label("Vollbild", systemImage: "arrow.up.left.and.arrow.down.right") }
        // Bildschirm fixieren (technische Zeichnungen, Abpausen; docs/FIXIEREN-ABPAUSEN-2026-11-05.md); kompakt
        // schliessen offene Blaetter vorher (`present`)
        Section(FreezeTexts.introTitle) {
            Button { present { requestFreeze(.view) } } label: {
                Label(freeze.mode == .view ? FreezeTexts.releaseView : FreezeTexts.fixView,
                      systemImage: freeze.mode == .view ? "lock.open" : "lock")
            }
            .accessibilityIdentifier("doc.freeze.view")
            Button { present { requestFreeze(.trace) } } label: { Label(FreezeTexts.trace, systemImage: "lock.rectangle") }
                .accessibilityIdentifier("doc.freeze.trace")
            if !PDFEditorController.isMac {
                Toggle(isOn: $freezeMaxBrightness) { Label(FreezeTexts.brightness, systemImage: "sun.max") }
            }
            Toggle(isOn: $freezeContrast) { Label(FreezeTexts.contrast, systemImage: "circle.lefthalf.filled") }
        }
    }

    // MARK: Leiste oben, kompakt

    /// Kompakt (iPhone): Zurueck, Titel (vom System gekuerzt), Sicherungsstand und ein Menue "…" mit allem, was am iPad
    /// in der Leiste steht (Suchen, Lesezeichen, Vorlesung bis hier, Teilen, Ebenen, Seiten, Schloss, Information).
    /// "Geteilt" ("Daneben öffnen") gibt es kompakt nicht.
    @ToolbarContentBuilder
    private var compactToolbar: some ToolbarContent {
        // genau ein Pfeil: unserer (das System-Zurueck ist kompakt aus); auch in der alten Fassung (Vollbild, `onBack`)
        if !readOnly || onBack != nil {
            ToolbarItem(placement: .topBarLeading) { compactBackButton }
        }
        UFPlainToolbarItem {
            StatusLabel(status: store.status)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu { compactMenuItems } label: { Label("Mehr", systemImage: "ellipsis.circle") }
                .accessibilityIdentifier("doc.more")
        }
    }

    /// Zurueck zur vorigen Seite der App (sonst zur Bibliothek); gedrueckt halten: alle Bereiche wie das Logo am iPad
    private var compactBackButton: some View {
        Button {
            if let onBack { onBack() } else if router.canGoBack { router.back() } else { router.go(.files()) }
        } label: {
            Label(UFBackButton.title, systemImage: "chevron.backward")
        }
        .contextMenu {
            if let logoMenu {
                ForEach(logoMenu.items, id: \.title) { item in Button(item.title) { logoMenu.go(item.route) } }
                Divider()
                Button("Einstellungen") { logoMenu.go(.settings()) }
            }
        }
        .accessibilityIdentifier("doc.back")
    }

    /// Inhalt des Menues "…" (kompakt)
    @ViewBuilder private var compactMenuItems: some View {
        Section {
            if task != nil, !readOnly {
                Button { Task { await markTaskDone() } } label: {
                    Label(taskDone ? "Erledigt ✓" : "Erledigt", systemImage: taskDone ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .disabled(taskDone)
            }
            Button { present { showSearch = true } } label: { Label("Suchen", systemImage: "magnifyingglass") }
            if offersLectureMarker {
                Button { present { openLectureMarker() } } label: {
                    Label(markers.needsReview ? "Vorlesung bis hier (prüfen)" : "Vorlesung bis hier",
                          systemImage: markers.needsReview ? "bookmark.trianglebadge.exclamationmark" : "bookmark")
                }
            }
            Button { bridge.fitWidth() } label: { Label("Seite einpassen (\(bridge.zoomPercent) %)", systemImage: "arrow.left.and.right") }
                .disabled(freeze.locksView)                      // fixiert: Zoom bleibt
        }
        Menu { shareMenuItems } label: { Label(exporting ? "Exportiert…" : "Teilen", systemImage: "square.and.arrow.up") }
            .disabled(exporting || store.pdf == nil)
        Menu { layersMenuItems } label: { Label("Ebenen", systemImage: "square.3.layers.3d") }
            .disabled(store.pdf == nil)
        moreMenuItems
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
            Button { present { outlineTitle = "Seite \(bridge.pageIndex + 1)"; addingOutline = true } } label: {
                Label("Zur Gliederung hinzufügen", systemImage: "list.bullet.indent")
            }
            Button(role: .destructive) { present { confirmClear = true } } label: { Label("Seite leeren", systemImage: "eraser") }
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
        Menu { layersMenuItems } label: { Label("Ebenen", systemImage: "square.3.layers.3d") }
            .disabled(store.pdf == nil)
    }

    /// Inhalt des Menues "Ebenen" (kompakt ohne "Daneben ansehen", dort "Vorschau ohne Original")
    @ViewBuilder private var layersMenuItems: some View {
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
                        if !compact {
                            Button { companion = nil; solutionSide = layer } label: {
                                Label("Daneben ansehen", systemImage: "rectangle.split.2x1")
                            }
                        }
                        Button { present { solutionSheet = .preview(layer.id) } } label: {
                            Label("Vorschau ohne Original", systemImage: "rectangle.on.rectangle")
                        }
                        Button(role: .destructive) { removeLayer(layer) } label: { Label("Entfernen", systemImage: "trash") }
                    } label: {
                        Label(layer.label, systemImage: layer.visible ? "checkmark.circle.fill" : "circle")
                    }
                }
                Button { present { importingSolution = true } } label: { Label("Lösung importieren …", systemImage: "square.and.arrow.down") }
            }
            // nur mit CloudKit-Dienst im Build (sonst kein Platzhalter; die Einstellungen sagen, warum)
            if SolutionSharing.community.isConnected {
                Section("Community") {
                    Button {
                        if let fp = communityFingerprint { present { solutionSheet = .community(fp) } }
                    } label: {
                        Label(communityMatches.isEmpty ? "Community durchsuchen …" : CommunityTexts.matches(communityMatches.count) + " …",
                              systemImage: "person.2")
                    }
                    .disabled(communityFingerprint == nil)
                }
            }
        } else {
            Button { present { solutionSheet = .locked(.communityRead) } } label: {
                Label(Self.lockedLabel("Lösungen anderer ansehen", entitlements.access(.communityRead)), systemImage: "lock")
            }
        }
    }

    /// Teilen braucht Plus; die Liste "Meine geteilten Lösungen" (Zurueckziehen, Entfernen) steht allen offen
    private func openSolutionSheet(_ sheet: SolutionSheet) {
        let feature: UFFeature = sheet.id == SolutionSheet.share.id ? .shareSolutions : .communityRead
        solutionSheet = entitlements.allows(feature) ? sheet : .locked(feature)
    }

    /// Menuepunkt einer gesperrten Funktion: "Lösung teilen … (StudiNow Plus)" bzw. "(bald)"
    static func lockedLabel(_ title: String, _ access: UFAccess) -> String {
        switch access {
        case .allowed: return title
        case .locked(let p): return "\(title) (\(p.name))"
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
                                    onImported: { result in Task { await handleImport(result) } }) { solutionSheet = nil }
        case .locked(let feature):
            SolutionLockedSheet(feature: feature) { solutionSheet = nil }
        }
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
    private func share(_ scope: ShareScope) {
        exporting = true
        Task {
            defer { exporting = false }
            do {
                // Seitennotizen und Blaetter daneben gehen direkt hinter ihrer Folie mit (NotesExport, 05.11.2026)
                let result = try await NotesExport.pdf(for: store, api: api, options: .init(scope: scope))
                exportFile = ExportFile(url: result.url, notice: result.payload.missingImagesNotice)
            } catch {
                actionError = "Teilen fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Leiste unten, kompakt

    /// Kompakt (iPhone): Objektleiste (wenn ein Objektwerkzeug aktiv ist), Hinweise in einer Zeile und die Leiste mit
    /// Seiten, "Blättern / Zeichnen", Werkzeugen und KI-Hilfe. Mit angedockter Palette (Zeichnen) rueckt alles darueber.
    private var compactBottom: some View {
        VStack(spacing: 8) {
            if bridge.objectMode { ObjectToolbar(bridge: bridge, compact: true) }
            compactNotice
            compactBar
        }
        .padding(.horizontal, 12)
        .padding(.bottom, bridge.paletteInset + 6)
        .animation(UF.motion(.easeOut(duration: 0.18)), value: bridge.paletteInset)
    }

    /// Hinweis ueber der Leiste (nur ansehen, Sperre, Loesungen, Speicherproblem); eine Zeile, antippbar wo es weitergeht
    @ViewBuilder private var compactNotice: some View {
        let solutions = foreignLayers.filter(\.visible)
        if readOnly || store.outdatedByNewVersion || store.journalUnreadable || store.viewOnlyLabel != nil || !planAllowsWriting
            || !ownNotesVisible || !solutions.isEmpty || store.syncIssue != nil || (store.notice ?? store.pageNotice ?? store.inkNotice) != nil {
            HStack(spacing: 8) {
                if readOnly {
                    Label("Alte Fassung – nur ansehen", systemImage: "doc.badge.clock")
                } else if store.outdatedByNewVersion {
                    Label("Neue Fassung – neu öffnen", systemImage: "arrow.triangle.2.circlepath")
                } else if store.journalUnreadable {
                    Label("Notizen nicht lesbar – nur ansehen", systemImage: "exclamationmark.triangle")
                } else if let label = store.viewOnlyLabel {
                    Label(label, systemImage: "eye")
                } else if !planAllowsWriting {
                    Button { present { lockedFeature = .pencilWriting } } label: {
                        Label("Nur ansehen – Schreiben ab \(UFPlan.plus.name)", systemImage: "lock")
                    }
                    .accessibilityHint("Öffnet die Tarifwahl")
                    .accessibilityIdentifier("doc.compact.lock")
                } else if !ownNotesVisible {
                    Label("Meine Notizen ausgeblendet", systemImage: "eye.slash")
                }
                if let layer = solutions.first {
                    // kompakt keine geteilte Ansicht: Vorschau der Loesung ohne Original
                    Button { present { solutionSheet = .preview(layer.id) } } label: {
                        Label("\(solutions.count) Lösung(en) · ansehen", systemImage: "square.3.layers.3d")
                    }
                    .accessibilityIdentifier("doc.solutionPreview")
                }
                SyncIssueBadge(store: store)
                if let notice = store.notice ?? store.pageNotice ?? store.inkNotice { Text(notice) }
            }
            .lineLimit(1)
            .font(.caption)
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .frame(maxWidth: .infinity)
        }
    }

    /// Leiste unten: Seiten (mit Seitenzahl), "Blättern / Zeichnen", Werkzeuge (nur beim Zeichnen), KI-Hilfe
    private var compactBar: some View {
        HStack(spacing: 6) {
            Button { toggleSidebar() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "rectangle.stack")
                    Text("\(bridge.pageIndex + 1)/\(store.pdf?.pageCount ?? 0)").monospacedDigit().lineLimit(1)
                }
                .font(.subheadline.weight(.medium))
                .frame(minWidth: 44, minHeight: 44)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Seiten")
            .accessibilityValue("Seite \(bridge.pageIndex + 1) von \(store.pdf?.pageCount ?? 0)")
            .accessibilityIdentifier("doc.pages")
            Spacer(minLength: 0)
            drawToggle
            Spacer(minLength: 0)
            if fingerDraws, drawAvailable, correction == nil, ownNotesVisible { objectToolsMenu }
            Button { if showTutor { showTutor = false } else { openTutor() } } label: {
                Image(systemName: "sparkles").font(.body.weight(.medium))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel(showTutor ? "KI-Hilfe schließen" : "KI-Hilfe")
            .accessibilityIdentifier("doc.tutor")
        }
        .buttonStyle(.plain)
        .foregroundStyle(UF.text)
        .padding(.horizontal, 6)
        .frame(height: 52)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(UF.line, lineWidth: 1))
        .ufShadow(.md)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("doc.bottomBar")
    }

    /// "Blättern / Zeichnen": zwei Felder, das aktive gefuellt. Ohne Schreiben im Tarif traegt "Zeichnen" ein Schloss.
    private var drawToggle: some View {
        let locked = !drawAvailable && !planAllowsWriting && !readOnly
        return HStack(spacing: 2) {
            drawSegment("Blättern", icon: "hand.point.up.left", on: !fingerDraws, id: "doc.mode.scroll") { setFingerDraws(false) }
            drawSegment("Zeichnen", icon: locked ? "lock" : "pencil.tip", on: fingerDraws && drawAvailable, id: "doc.mode.draw") { setFingerDraws(true) }
                .disabled(!drawAvailable && !locked)
        }
        .padding(3)
        .background(UF.surface2, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Blättern oder Zeichnen")
    }

    private func drawSegment(_ title: String, icon: String, on: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ViewThatFits(in: .horizontal) {
                Label(title, systemImage: icon).labelStyle(.titleAndIcon)
                Image(systemName: icon)
            }
            .font(.subheadline.weight(on ? .semibold : .regular))
            .foregroundStyle(on ? UF.accentText : UF.text2)
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .background(on ? UF.accentSoft : Color.clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? [.isSelected] : [])
        .accessibilityIdentifier(id)
    }

    /// Objektwerkzeuge (Text, Haftnotiz, Formen, Auswahl, Text markieren) auch ohne Wischen durch die Palette; dieselben
    /// Werkzeuge wie die eigenen Eintraege der Palette (die angedockte iPhone-Palette zeigt nur wenige auf einmal)
    private var objectToolsMenu: some View {
        Menu {
            Button { if bridge.objectMode { bridge.finishObjectTools() } } label: { Label("Stift", systemImage: "pencil.tip") }
            Section {
                ForEach([ObjectEditing.Tool.text, .sticky, .select, .lasso, .markup], id: \.self) { t in
                    Button { chooseObjectTool(t) } label: { Label(t.label, systemImage: t.systemImage) }
                }
            }
            Section("Formen") {
                ForEach([ObjectEditing.Tool.rect, .ellipse, .line, .arrow], id: \.self) { t in
                    Button { chooseObjectTool(t) } label: { Label(t.label, systemImage: t.systemImage) }
                }
            }
            // "Bereich an KI" (05.11.2026): mit dem Finger Rahmen ziehen oder einkreisen, das Bild geht in die KI-Hilfe
            Section("KI-Hilfe") {
                Button { chooseObjectTool(.area) } label: { Label(ObjectEditing.Tool.area.label, systemImage: ObjectEditing.Tool.area.systemImage) }
                    .accessibilityIdentifier("doc.objectTools.area")
            }
        } label: {
            Image(systemName: bridge.objectMode ? bridge.objectTool.systemImage : "square.on.circle")
                .font(.body.weight(.medium))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel("Werkzeuge")
        .accessibilityIdentifier("doc.objectTools")
    }

    private func chooseObjectTool(_ t: ObjectEditing.Tool) {
        if !bridge.objectMode { bridge.setObjectMode(true) }
        bridge.setObjectTool(t)
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
                Label(label, systemImage: "eye").lineLimit(1)
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
/// keine eigene Werkzeugpalette (die Palette des Hauptdokuments gilt fuer beide).
struct CompanionView: View {
    let api: APIClient
    @StateObject private var store: DocumentStore
    @StateObject private var bridge = EditorBridge()
    let pdfPage: Int?
    let toolPicker: PKToolPicker
    let undoManager: UndoManager
    let pencilOnly: Bool
    let canEdit: Bool
    /// "Ansicht fixieren" im Hauptdokument fixiert auch das Dokument daneben
    var viewLocked = false
    /// meldet das offene Dokument an die Hauptansicht (sichtbar ja/nein)
    var onStore: (DocumentStore, Bool) -> Void = { _, _ in }
    let onClose: () -> Void

    init(file: LibFile, api: APIClient, pdfPage: Int?, toolPicker: PKToolPicker, undoManager: UndoManager,
         pencilOnly: Bool, canEdit: Bool = true, viewLocked: Bool = false,
         onStore: @escaping (DocumentStore, Bool) -> Void = { _, _ in }, onClose: @escaping () -> Void) {
        _store = StateObject(wrappedValue: DocumentStore(file: file, api: api))
        self.api = api
        self.pdfPage = pdfPage
        self.toolPicker = toolPicker
        self.undoManager = undoManager
        self.pencilOnly = pencilOnly
        self.canEdit = canEdit
        self.viewLocked = viewLocked
        self.onStore = onStore
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            // Kopf wie KI-Hilfe und Loesung daneben (UFPaneHeader)
            UFPaneHeader(store.file.displayTitle, icon: store.file.isNotebook ? "note" : "file-text", close: onClose) {
                StatusLabel(status: store.status)
                SyncIssueBadge(store: store)
                Text("S. \(bridge.pageIndex + 1)").ufFont(12.8, 500, lh: 1.25).monospacedDigit().foregroundStyle(UF.text2)
            }
            if let error = store.errorMessage {
                ContentUnavailableView("Nicht verfügbar", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if store.pdf != nil {
                PDFEditorView(store: store, bridge: bridge, pencilOnly: pencilOnly, layoutVersion: store.layoutVersion,
                              toolPicker: toolPicker, ownsToolPicker: false, undoManager: undoManager, initialPDFPage: pdfPage,
                              canEdit: canEdit && !store.journalUnreadable && !store.viewOnlyHere,
                              freezeMode: viewLocked ? .view : .off)
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
        }
        .task { await store.load() }
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

/// "Daneben öffnen": ein leeres Blatt mit Vorlage (mitschreiben, ohne auf die Folie zu schreiben) oder ein vorhandenes
/// Dokument (Dokumente desselben Moduls zuerst). Das Blatt ist ein Notizbuch im Modul der offenen Datei.
struct CompanionPicker: View {
    let api: APIClient
    let moduleID: Int?
    let excluding: String
    /// Titel der offenen Datei, fuer den Namen des neuen Blatts
    var sourceTitle = ""
    /// empfangene Loesungen zu dieser PDF (ID, Name): "Lösung daneben ansehen" steht dann zuerst
    var solutions: [(id: String, label: String)] = []
    var onSolution: (String) -> Void = { _ in }
    let onPick: (LibFile) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var files: [LibFile] = []
    @State private var query = ""
    @State private var error: String?
    @State private var creating: String?

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
            Text("Links deine Folie, rechts die Lösung auf derselben Seite.")
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
            Text("Zum Mitschreiben neben der Folie, ohne auf sie zu schreiben. Das Blatt landet bei deinen Notizen im Modul.")
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
    }

    /// Neues Notizbuch mit Vorlage im Modul der offenen Datei, dann daneben oeffnen
    private func createBlank(_ template: String) async {
        guard Entitlements.shared.allows(NotebookDialog.feature) else {
            error = "Notizblätter gibt es ab \(UFPlan.plus.name)."
            return
        }
        creating = template
        defer { creating = nil }
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

    /// PDFPage-Kopie fuer das Zeichnen im Hintergrund (das Original gehoert dem Editor auf dem Hauptthread).
    private struct PageBox: @unchecked Sendable { let page: PDFPage }

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
    @discardableResult
    func refresh(key: String, page: PDFPage, entry: DisplayLayout.Entry, objects: [JSONValue], images: [String: UIImage],
                 layoutVersion: Int, width: CGFloat, scale: CGFloat) async -> Bool {
        // nur Bilder dieser Seite (kleiner Uebergabewert, Signatur aendert sich nur bei eigenen Bildern)
        let srcs = Set(objects.compactMap { $0["type"]?.string == "image" ? $0["src"]?.string : nil })
        let own = images.filter { srcs.contains($0.key) }
        let rotation = page.rotation
        let sig = await Task.detached(priority: .utility) {
            Self.signature(layoutVersion: layoutVersion, entry: entry, rotation: rotation, objects: objects,
                           loadedImages: own.keys.sorted())
        }.value
        guard signatures[key] != sig else { touch(key); return false }
        signatures[key] = sig
        let box = PageBox(page: page.copy() as? PDFPage ?? page)
        let img = await Task.detached(priority: .utility) {
            PageRenderer.thumbnail(page: box.page, entry: entry, objects: objects, images: own, width: width, scale: scale)
        }.value
        guard signatures[key] == sig else { return false }                       // inzwischen neuerer Stand unterwegs
        self.images[key] = img
        renderCount += 1
        touch(key)
        evict()
        return true
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
    let bridge: EditorBridge
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [SearchHit] = []

    var body: some View {
        NavigationStack {
            List(hits) { hit in
                Button {
                    bridge.controller?.show(hit.selection)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Seite \(hit.pageIndex + 1)").font(.caption).foregroundStyle(.secondary)
                        Text(hit.snippet).lineLimit(2)
                    }
                }
            }
            .overlay {
                if query.count >= 2 && hits.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Im PDF suchen")
            .onChange(of: query) { _, q in hits = store.search(q) }
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
                Text("Schickt den Text dieser Datei an dein ChatGPT (nur diese Datei).").font(.caption).foregroundStyle(.secondary)
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

/// Leiste im Objektmodus: Werkzeuge wie im Web (Auswaehlen, Text, Haftnotiz, Formen, Lasso) und Aktionen fuer die
/// Auswahl. Die Stiftpalette von PencilKit ist in diesem Modus ohne Wirkung.
struct ObjectToolbar: View {
    @ObservedObject var bridge: EditorBridge
    /// Kompakt (iPhone): jede Reihe seitlich verschiebbar, damit nichts ueber den Rand ragt
    var compact = false
    private let colors: [(String, String)] = [("#e5322d", "Rot"), ("#1d2130", "Schwarz"), ("#2f7fd1", "Blau"), ("#2e9e5b", "Grün"),
                                              ("#f5d90a", "Gelb"), ("#fff7a8", "Notizgelb")]

    /// Ab iPadOS 18 waehlt man die Werkzeuge in Apples Palette; die Leiste zeigt dann nur, was zur Auswahl bzw. zum
    /// markierten Text gehoert (unter iPadOS 17, oder ohne die Eintraege in der Palette, weiter mit den Werkzeugen)
    private var toolsInPalette: Bool { bridge.toolsInPalette }

    var body: some View {
        VStack(spacing: 8) {
            if bridge.objectTool == .area {
                // Bereich an KI: was zu tun ist, und der Weg zurueck (ohne Palette sonst kein Ausweg aus dem Werkzeug);
                // iPhone: Text ueber den Knoepfen (der Finger zieht, zwei Finger blaettern)
                let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
                layout {
                    HStack(spacing: 10) {
                        Image(systemName: "rectangle.dashed").accessibilityHidden(true)
                        Text(compact ? "Mit dem Finger Rahmen ziehen oder einkreisen – zwei Finger blättern"
                                     : "Rahmen ziehen oder Bereich einkreisen").font(.callout)
                            .fixedSize(horizontal: false, vertical: compact)
                            .accessibilityIdentifier("objects.area.hint")
                    }
                    HStack(spacing: 10) {
                        Button { bridge.controller?.sendVisiblePage() } label: { Label("Ganze Seite", systemImage: "doc.viewfinder") }
                            .buttonStyle(.bordered)
                            .controlSize(compact ? .large : .regular)          // iPhone: Daumen (44 pt)
                            .accessibilityIdentifier("objects.area.page")
                        if compact { Spacer(minLength: 0) }
                        Button("Fertig") { bridge.finishObjectTools() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(compact ? .large : .regular)
                            .accessibilityIdentifier("objects.area.done")
                    }
                }
                .padding(8)
                .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            if bridge.objectTool == .markup {
                scrolling(markupRow)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            if !toolsInPalette || bridge.objectSelection > 0 {
                scrolling(tools)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .shadow(radius: 4)
            }
        }
    }

    /// Kompakt seitlich verschiebbar (zentriert, solange es passt), sonst wie bisher
    @ViewBuilder private func scrolling<C: View>(_ row: C) -> some View {
        if compact {
            ViewThatFits(in: .horizontal) {
                row
                ScrollView(.horizontal, showsIndicators: false) { row }
            }
        } else {
            row
        }
    }

    /// Reihe "Text markieren": Markieren, Unterstreichen, Durchstreichen, KI, Karteikarte, Fertig
    private var markupRow: some View {
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
                Text(compact ? "Text gedrückt halten und ziehen" : "Text in der PDF auswählen (gedrückt halten und ziehen)")
                .font(.callout).foregroundStyle(.secondary)
            }
            if toolsInPalette {
                // beim Markieren hat die PDF-Ansicht den Fokus und die Palette ist weg: hier zurueck zum Stift
                Button("Fertig") { bridge.finishObjectTools() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("objects.markup.done")
            }
        }
        .buttonStyle(.borderedProminent)
        .padding(8)
    }

    private var tools: some View {
        HStack(spacing: 6) {
            if !toolsInPalette {
                ForEach(ObjectEditing.Tool.allCases, id: \.self) { t in
                    Button { bridge.setObjectTool(t) } label: { Image(systemName: t.systemImage).frame(width: 30, height: 30) }
                        .buttonStyle(.bordered)
                        .tint(bridge.objectTool == t ? .accentColor : .secondary)
                        .accessibilityLabel(t.label)
                        .accessibilityIdentifier("objects.tool.\(t.rawValue)")
                }
                Divider().frame(height: 26)
            }
            // eigenes Rueckgaengig fuer Objektaktionen (derselbe Verlauf wie die Palette)
            Button { bridge.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 30, height: 30) }
                .accessibilityLabel("Rückgängig")
                .accessibilityIdentifier("objects.undo")
            Button { bridge.redo() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 30, height: 30) }
                .accessibilityLabel("Wiederholen")
            Divider().frame(height: 26)
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
            if !toolsInPalette {
                Divider().frame(height: 26)
                Button("Fertig") { bridge.finishObjectTools() }
            }
        }
        .padding(8)
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

    private var problem: Bool {
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
    var toolPicker: PKToolPicker?
    var ownsToolPicker = true
    var undoManager: UndoManager?
    var initialPDFPage: Int?
    /// fremde Loesungen (nur Anzeige) und Sichtbarkeit der eigenen Notizen
    var foreignLayers: [ForeignSolutionLayer] = []
    var ownNotesVisible = true
    /// Tarif erlaubt Schreiben (Plus); sonst nur ansehen
    var canEdit = true
    /// Korrektur-Modus bzw. angezeigte empfangene Korrektur (`CorrectionMode.swift`)
    var correction: CorrectionSession?
    var shownCorrection: CommunityCorrection?
    var onCorrectionNote: ((CorrectionNoteEvent) -> Void)?
    /// KI verbunden: "KI fragen" am Rand der Palette (Schritt F)
    var aiAvailable = false
    /// iPhone im Modus "Blättern": keine Palette (`PDFEditorController.paletteSuppressed`)
    var paletteSuppressed = false
    /// Bildschirm fixieren (`EditorFreezeLock.swift`)
    var freezeMode: EditorFreeze.Mode = .off
    var traceContrast = false

    func makeUIViewController(context: Context) -> PDFEditorController {
        let vc = PDFEditorController(store: store, toolPicker: toolPicker, ownsToolPicker: ownsToolPicker,
                                     undoManager: undoManager, initialPDFPage: initialPDFPage)
        let bridge = self.bridge
        vc.pencilOnly = pencilOnly
        vc.paletteSuppressed = paletteSuppressed
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
        if ownsToolPicker { bridge.toolsInPalette = vc.toolsInPalette }
        vc.objects.onTextSelection = { [weak bridge] on in bridge?.textSelected = on }
        // "KI fragen" an der Palette und "Als Karteikarte" im Bearbeitungsmenue melden sich ueber die Bruecke
        vc.aiAvailable = aiAvailable
        vc.onAskAI = { [weak bridge] a in bridge?.attachToTutor(a) }
        vc.onHint = { [weak bridge] text in bridge?.hint = EditorBridge.Hint(text: text) }
        vc.onFlashcardFromSelection = { [weak bridge] text in bridge?.makeFlashcard(text) }
        vc.onPaletteInset = { [weak bridge] h in if bridge?.paletteInset != h { bridge?.paletteInset = h } }
        vc.traceContrast = traceContrast
        vc.freezeMode = freezeMode
        bridge.controller = vc
        return vc
    }

    /// Wird bei jeder SwiftUI-Aktualisierung aufgerufen (z. B. Statuswechsel). Fasst die Canvas nicht an; baut die
    /// Anzeige nur neu auf, wenn sich die Seitenstruktur geaendert hat.
    func updateUIViewController(_ vc: PDFEditorController, context: Context) {
        if vc.pencilOnly != pencilOnly { vc.pencilOnly = pencilOnly }
        if vc.paletteSuppressed != paletteSuppressed { vc.paletteSuppressed = paletteSuppressed }
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
    }
}

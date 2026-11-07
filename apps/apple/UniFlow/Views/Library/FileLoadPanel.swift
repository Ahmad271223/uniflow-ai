import SwiftUI
import UniFlowCore

// Datei gelistet, aber noch nicht geladen (Befund vom iPad 07.11.2026): statt der Zusage "Der naechste Abgleich laedt
// sie" laedt die Ansicht die Datei beim Oeffnen selbst ("Jetzt laden" mit der vorhandenen Stud.IP-Sitzung), zeigt den
// Fortschritt und bei einem Fehler den Grund mit "Erneut versuchen"; ohne Anmeldung den Hinweis dazu. Der Text
// verspricht nur, was wirklich passiert.

private struct StudIPFilesKey: EnvironmentKey {
    static let defaultValue: StudIPSync? = nil
}

extension EnvironmentValues {
    /// Stud.IP-Abgleich des offenen Containers fuer "Jetzt laden" einzelner Dateien (nil: keiner, z. B. Tests, Server)
    var studipFiles: StudIPSync? {
        get { self[StudIPFilesKey.self] }
        set { self[StudIPFilesKey.self] = newValue }
    }
}

/// Zustand der Ansicht "Datei nicht geladen" (testbar ohne Netz)
enum FileLoadState: Equatable {
    /// noch nichts versucht
    case idle
    case loading
    case loaded
    /// keine oder abgelaufene Stud.IP-Anmeldung
    case needsLogin
    case failed(String)
    /// keine Stud.IP-Datei (eigene Datei, Learnweb): laedt der Abgleich ihrer Quelle
    case otherSource

    init(_ outcome: StudIPSync.FileLoadOutcome) {
        switch outcome {
        case .loaded: self = .loaded
        case .needsLogin: self = .needsLogin
        case .failed(let m): self = .failed(m)
        case .notStudIP: self = .otherSource
        }
    }

    /// Ueberschrift unter dem Dateinamen
    var headline: String {
        switch self {
        case .idle: return "Noch nicht auf diesem iPad"
        case .loading: return "Wird geladen …"
        case .loaded: return "Geladen"
        case .needsLogin: return "Stud.IP-Anmeldung nötig"
        case .failed: return "Nicht geladen"
        case .otherSource: return "Noch nicht auf diesem iPad"
        }
    }

    /// Erklaerung (verspricht nur, was passiert)
    var detail: String {
        switch self {
        case .idle: return "Die Datei steht in Stud.IP. „Jetzt laden“ holt sie sofort auf dieses iPad."
        case .loading: return "Die Datei kommt gerade von Stud.IP auf dieses iPad."
        case .loaded: return "Die Datei ist da und öffnet sich gleich."
        case .needsLogin:
            return "Melde dich unter Einstellungen → Stud.IP neu an. Danach lädt „Erneut versuchen“ die Datei, und jeder Abgleich holt fehlende Dateien nach."
        case .failed(let m): return m + " Jeder Abgleich versucht es wieder; „Erneut versuchen“ fragt sofort."
        case .otherSource: return "Diese Datei kommt mit dem Abgleich ihrer Quelle; „Sync“ oben startet ihn."
        }
    }

    var canRetry: Bool {
        switch self {
        case .idle, .failed, .needsLogin: return true
        case .loading, .loaded, .otherSource: return false
        }
    }
}

/// Inhalt von `FileOutsideEditorView` fuer eine nicht geladene Datei: laedt beim Erscheinen automatisch (einmal je
/// Oeffnen), danach `onLoaded` (die Bibliothek liest die Datei neu und oeffnet sie im Editor bzw. in der Vorschau)
struct FileLoadPanel: View {
    let file: LibFile
    var onLoaded: (() async -> Void)?
    @Environment(\.studipFiles) private var studip
    /// beginnt mit "Wird geladen": beim Oeffnen laedt die Ansicht sofort selbst; vorher kurz "Noch nicht auf diesem
    /// iPad" mit "Jetzt laden" zu zeigen, blitzte bei jedem Oeffnen auf (Befund vom iPad 07.11.2026, 23:35)
    @State private var state: FileLoadState = .loading
    @State private var autoTried = false
    /// Die Ladeansicht erscheint erst, wenn das Laden laenger als einen Moment dauert: eine kleine Datei ist in
    /// Sekundenbruchteilen da, und dann blitzte "Wird geladen" vor dem Dokument auf (Befund iPad 07.11., 23:50)
    @State private var showWhileLoading = false

    var body: some View {
        Group {
            if state == .loading, !showWhileLoading {
                UF.bg.ignoresSafeArea()
            } else {
                FileLoadPanelContent(title: file.displayTitle, size: file.size, state: state) { Task { await retry() } }
            }
        }
        .task(id: file.id) {
            guard !autoTried else { return }
            autoTried = true
            let delay = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                if !Task.isCancelled { showWhileLoading = true }
            }
            await run()
            delay.cancel()
            showWhileLoading = true                                 // Fehler oder Anmeldung sofort zeigen
        }
    }

    /// "Erneut versuchen" bzw. "Jetzt laden"
    private func retry() async {
        guard state != .loading else { return }
        await run()
    }

    private func run() async {
        guard let studip else { state = .otherSource; return }
        state = .loading
        state = FileLoadState(await studip.loadFile(id: file.id))
        if state == .loaded { await onLoaded?() }
    }
}

/// Darstellung (ohne Netz, fuer Ansichtstests und Fotos)
struct FileLoadPanelContent: View {
    let title: String
    var size: Int?
    let state: FileLoadState
    let retry: () -> Void

    private var icon: String {
        switch state {
        case .failed: return "exclamationmark.icloud"
        case .needsLogin: return "person.crop.circle.badge.exclamationmark"
        case .loaded: return "checkmark.icloud"
        default: return "icloud.and.arrow.down"
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 44, weight: .regular))
                .foregroundStyle(state == .loaded ? UF.ok : UF.muted)
                .accessibilityHidden(true)
            Text(title).ufFont(19, 650, lh: 1.3).foregroundStyle(UF.text).multilineTextAlignment(.center).lineLimit(3)
            Text(state.headline).ufFont(14.5, 600, lh: 1.3)
                .foregroundStyle(isProblem ? UF.badText : UF.text2)
                .accessibilityIdentifier("file.load.state")
            Text(state.detail).ufFont(14, lh: 1.45).foregroundStyle(UF.text2).multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .fixedSize(horizontal: false, vertical: true)
            if state == .loading {
                ProgressView(sizeText.map { "Lädt \($0) …" } ?? "Lädt …")
                    .accessibilityIdentifier("file.load.progress")
            } else if state.canRetry {
                Button(action: retry) {
                    Label(state == .idle ? "Jetzt laden" : "Erneut versuchen", systemImage: "arrow.down.circle")
                        .ufFont(14.5, 600)
                }
                .buttonStyle(UFButtonStyle(kind: .primary))
                .accessibilityIdentifier("file.load.retry")
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(UF.bg)
        .accessibilityElement(children: .contain)
    }

    private var isProblem: Bool {
        switch state {
        case .failed, .needsLogin: return true
        default: return false
        }
    }

    private var sizeText: String? {
        guard let size, size > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

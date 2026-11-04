import SwiftUI
import UniFlowCore

/// Textansicht fuer Dateien, die nicht in den PDF-Editor gehoeren (docs/DATEIARTEN.md, 04.11.2026): Word und
/// PowerPoint als Seiten (Folien) aus dem Seitentext-Index des lokalen Backends (`GET /api/files/{id}/pagetext`),
/// Audio ueber das Transkript auf dem Geraet. Daneben die KI-Hilfe wie im Editor (`TutorPanel`, Seite = aktuelle
/// Seite). Keine Bearbeitung, keine Notizen; das Original laesst sich weiter als Vorschau ansehen.
struct TextDocumentView: View {
    let file: LibFile
    let api: APIClient
    @State private var pages = 0
    @State private var page = 1
    @State private var texts: [Int: String] = [:]
    @State private var loading = false
    /// 404 no_content: nie gelesen (Audio ohne Transkript) oder nicht lesbar
    @State private var noContent = false
    @State private var problem: String?
    @State private var showTutor = false
    @State private var showOriginal = false
    @StateObject private var transcriber = AudioTranscriber()
    @Environment(\.ufAIEnabled) private var aiEnabled

    /// Beschriftung der Art (Kopfzeile)
    static func kindLabel(_ kind: String?) -> String {
        switch kind {
        case "docx": return "Word · Text"
        case "pptx": return "PowerPoint · Folientext"
        case "audio": return "Audio · Transkript"
        default: return "Text"
        }
    }

    static func icon(_ kind: String?) -> String { ShellState.typeIcon[LibraryStyle.displayKind(kind)] ?? "file" }

    private var kind: String? { file.sourceKind }
    private var pageWord: String { kind == "pptx" ? "Folie" : "Seite" }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    header
                    if showOriginal {
                        FileOutsideEditorView(file: file, api: api)
                    } else {
                        content
                    }
                }
                if showTutor {
                    Divider()
                    TutorPanel(fileID: file.id, fileName: file.displayTitle, page: { page }, selection: { "" },
                               open: { id, p in if id == file.id, p >= 1, p <= max(pages, 1) { page = p } },
                               close: { showTutor = false })
                        .frame(width: DocumentView.tutorWidth(geo.size.width))
                }
            }
        }
        .background(UF.bg)
        .navigationTitle(file.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: file.id) { await load(1) }
        .onChange(of: page) { _, p in Task { await load(p) } }
        .onChange(of: transcriber.state) { _, s in if case .done = s { Task { await reload() } } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            UFIcon(Self.icon(kind), size: 16).foregroundStyle(UF.muted)
            VStack(alignment: .leading, spacing: 0) {
                Text(file.displayTitle).ufFont(14.5, 650, lh: 1.25).foregroundStyle(UF.text).lineLimit(1)
                Text(Self.kindLabel(kind) + (pages > 0 ? " · \(pages) \(pages == 1 ? pageWord : pageWord + "n")" : "")).ufFont(12, lh: 1.3).foregroundStyle(UF.muted)
            }
            Spacer(minLength: 8)
            if pages > 1, !showOriginal {
                HStack(spacing: 2) {
                    UFButton(nil, icon: "chevron-left", kind: .ghost, size: .small) { page = max(1, page - 1) }
                        .disabled(page <= 1).accessibilityLabel("Zurück").accessibilityIdentifier("text.prev")
                    Text("\(pageWord) \(page) von \(pages)").ufFont(12.8).foregroundStyle(UF.text2).monospacedDigit()
                        .accessibilityIdentifier("text.pageLabel")
                    UFButton(nil, icon: "chevron-right", kind: .ghost, size: .small) { page = min(pages, page + 1) }
                        .disabled(page >= pages).accessibilityLabel("Weiter").accessibilityIdentifier("text.next")
                }
            }
            UFButton(showOriginal ? "Text" : "Original", icon: showOriginal ? "text" : "eye", kind: .ghost, size: .small) { showOriginal.toggle() }
                .accessibilityIdentifier("text.original")
            UFButton("KI-Hilfe", icon: "sparkles", kind: showTutor ? .primary : .normal, size: .small) { showTutor.toggle() }
                .accessibilityIdentifier("text.tutor")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(UF.surface)
        .ufBorderBottom()
    }

    @ViewBuilder private var content: some View {
        if let problem {
            ContentUnavailableView("Text nicht lesbar", systemImage: "doc.questionmark", description: Text(problem))
        } else if noContent {
            if kind == "audio" {
                AudioTranscriptPrompt(file: file, transcriber: transcriber)
            } else {
                ContentUnavailableView("Kein Text gefunden", systemImage: "doc.text.magnifyingglass",
                                       description: Text(kind == "pptx" ? "Die Folien enthalten keinen Text (nur Bilder) oder die Datei lässt sich nicht lesen."
                                                         : "Das Dokument enthält keinen Text oder lässt sich nicht lesen. Das Original lässt sich oben ansehen."))
            }
        } else if let text = texts[page] {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if kind == "pptx" { Text("Folie \(page)").ufFont(12.8, 650).foregroundStyle(UF.muted) }
                    if text.isEmpty {
                        Text(kind == "pptx" ? "(Folie ohne Text)" : "(ohne Text)").ufFont(14.4).foregroundStyle(UF.muted)
                    } else {
                        Text(text).ufFont(15.2, lh: 1.55).foregroundStyle(UF.text).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("text.page")
            }
            .id(page)
        } else if loading {
            ProgressView("Text wird gelesen …").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear
        }
    }

    private func reload() async {
        texts = [:]
        pages = 0
        noContent = false
        problem = nil
        page = 1
        await load(1)
    }

    /// Seite laden (einmal je Seite; `pages` aus der Antwort). 404 `no_content` heisst "kein Text".
    private func load(_ n: Int) async {
        if texts[n] != nil { return }
        loading = true
        defer { loading = false }
        do {
            let r = try await api.value("/api/files/\(file.id)/pagetext?page=\(n)")
            pages = r["pages"]?.int ?? 0
            texts[n] = r["text"]?.string ?? ""
            if let e = r["error"]?.string, !e.isEmpty, pages == 0 { problem = e }
            noContent = pages == 0 && problem == nil
        } catch let e as APIError where e.status == 404 {
            noContent = true
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// Audio ohne Transkript: erklaeren, was passiert, und auf Wunsch erkennen lassen (Deutsch oder Englisch), nie von selbst
struct AudioTranscriptPrompt: View {
    let file: LibFile
    @ObservedObject var transcriber: AudioTranscriber
    @EnvironmentObject private var session: Session

    var body: some View {
        VStack(spacing: 14) {
            UFIcon("play", size: 36).foregroundStyle(UF.muted)
            Text("Noch kein Transkript").ufFont(17.6, 700).foregroundStyle(UF.text)
            Text("Die Aufnahme wird auf dem iPad in Text umgewandelt (Spracherkennung des Geräts, ohne Internet). Der Text liegt danach neben der Datei und dient der Suche, der KI-Hilfe und den Wochentests. Die Aufnahme selbst verlässt das Gerät nicht. Das dauert etwa so lange wie ein Fünftel der Aufnahme; die Qualität hängt von Aufnahme und Sprache ab.")
                .ufFont(13.6, lh: 1.5).foregroundStyle(UF.text2).multilineTextAlignment(.center).frame(maxWidth: 520)
            switch transcriber.state {
            case .running(let p):
                ProgressView(value: p).frame(maxWidth: 320)
                Text(p > 0 ? "Erkennung läuft … \(Int(p * 100)) %" : "Erkennung läuft …").ufFont(12.8).foregroundStyle(UF.muted)
                UFButton("Abbrechen", icon: "x", kind: .ghost, size: .small) { transcriber.cancel() }
            case .failed(let m):
                Text(m).ufFont(12.8).foregroundStyle(UF.bad).multilineTextAlignment(.center).frame(maxWidth: 520)
                buttons
            case .done:
                Text("Transkript erstellt.").ufFont(12.8).foregroundStyle(UF.muted)
            case .idle:
                buttons
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            ForEach(AudioTranscriber.languages, id: \.locale) { l in
                UFButton("Transkript erstellen (\(l.label))", icon: "sparkles", kind: l.locale == "de-DE" ? .primary : .normal, size: .small) {
                    guard let c = ActiveContainer.current else { return }
                    Task { await transcriber.transcribe(fileID: file.id, locale: l.locale, container: c) }
                }
                .accessibilityIdentifier("audio.transcribe.\(l.locale)")
            }
        }
    }
}

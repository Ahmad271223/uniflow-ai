import SwiftUI
import UniFlowCore

// "Bessere Mitschrift" mit Whisper (1.0.8, docs/WHISPER-MITSCHRIFT.md): Karte in den Einstellungen, Dialog zum Laden
// der Sprachmodelle, Fortschritt an einer Aufnahme und der Knopf "Mitschrift" an geladenen Uni-Aufzeichnungen.
// Die Arbeit selbst macht `UniFlow/Services/WhisperMitschrift.swift`.

enum WhisperText {
    static let title = "Bessere Mitschrift"
    static let short = "Genauere Mitschrift für Aufnahmen und Uni-Videos. Läuft nur auf diesem Gerät."
    static let long = "StudiNow lädt dafür einmal ein Sprachmodell (Whisper) auf dieses iPad. Danach wandelt es deine Aufnahmen, Audio-Dateien und geladene Uni-Aufzeichnungen auf dem Gerät in Text um. Ton und Text verlassen das Gerät dabei nicht. Fachbegriffe aus den Vorlesungen und Skripten des Moduls, die auf dem Gerät liegen, helfen bei der Erkennung. Geladen wird das Modell vom Modell-Verzeichnis Hugging Face; wie bei jedem Download sieht der Anbieter dabei deine IP-Adresse. Eine Mitschrift kann Fehler enthalten, vor allem bei Namen und Formeln."
    static let duration = "Eine Vorlesung von 90 Minuten braucht je nach Gerät einige Minuten bis über eine halbe Stunde. StudiNow muss dabei geöffnet bleiben; wird es unterbrochen, geht es später an derselben Stelle weiter."
    static let noModel = "Für die genauere Mitschrift lädst du einmal ein Sprachmodell."

    static func size(_ megabytes: Int) -> String {
        megabytes >= 1000 ? String(format: "%.1f GB", Double(megabytes) / 1000).replacingOccurrences(of: ".", with: ",") : "\(megabytes) MB"
    }

    static func size(bytes: Int64) -> String { size(Int(bytes / 1_000_000)) }

    static func percent(_ fraction: Double) -> String { "\(Int((min(1, max(0, fraction)) * 100).rounded())) %" }

    static func confirmDownload(_ choice: WhisperModelChoice) -> String {
        "Sprachmodell „\(choice.title)“ laden? Das sind \(size(choice.megabytes)) – am besten im WLAN."
    }

    /// Zeile in der Karte: was geladen ist
    static func status(active: WhisperModelChoice?, bytes: Int64) -> String {
        guard let active else { return "Kein Sprachmodell geladen." }
        return "Sprachmodell „\(active.title)“ geladen (\(size(bytes: bytes)))."
    }

    /// Beschriftung des Knopfs an einer Aufnahme
    /// - `sections`: Zahl der vorhandenen Abschnitte, `status`/`engine`: Stand der Mitschrift
    static func action(sections: Int, status: String, engine: String?) -> String? {
        if engine == "whisper" {
            if status == "done" { return nil }
            return sections > 0 ? "Weiter erkennen" : "Mitschrift erstellen"
        }
        return sections > 0 ? "Genauer erkennen" : "Mitschrift erstellen"
    }
}

// MARK: - Karte in den Einstellungen

struct WhisperSettingsCard: View {
    @ObservedObject private var store = WhisperModelStore.shared
    @EnvironmentObject private var overlay: UFOverlay

    var body: some View {
        if WhisperFeature.isEnabled {
            UFCard {
                UFCardHead(WhisperText.title, icon: "text") {
                    if store.active != nil { UFBadge("Geladen", tone: .ok) }
                }
                Text(WhisperText.status(active: store.active, bytes: store.active.map(store.bytesOnDisk) ?? 0))
                    .ufFont(13.6).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("whisper.status")
                SettingsMore(summary: WhisperText.short, text: UFDevice.adapt(WhisperText.long) + " " + WhisperText.duration, identifier: "whisper.more")
                    .padding(.top, 2)
                UFButton(store.active == nil ? "Sprachmodell laden" : "Sprachmodelle verwalten", icon: "download", size: .small) {
                    _ = overlay.modal { WhisperModelDialog() }
                }
                .padding(.top, 6)
                .accessibilityIdentifier("whisper.manage")
            }
            .onAppear { store.refresh() }
        }
    }
}

// MARK: - Sprachmodelle laden und loeschen

struct WhisperModelDialog: View {
    @ObservedObject private var store = WhisperModelStore.shared
    @EnvironmentObject private var overlay: UFOverlay
    @Environment(\.ufClose) private var close
    @State private var supported: [String] = []
    @State private var checked = false

    var body: some View {
        UFDialog(WhisperText.title, icon: "text") {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(UFDevice.adapt(WhisperText.long)).ufFont(13.1, lh: 1.45).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                    Text(WhisperText.duration).ufFont(12.5, lh: 1.45).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                    ForEach(WhisperModels.all) { choice in
                        WhisperModelRow(choice: choice, state: store.state(choice), isActive: store.active == choice,
                                        bytes: store.bytesOnDisk(choice), offered: !checked || WhisperModels.offered(choice, supported: supported),
                                        suggested: checked && WhisperModels.suggested(supported: supported) == choice,
                                        load: { Task { await load(choice) } }, cancel: { store.cancel(choice) }, use: { store.use(choice) },
                                        delete: { Task { await delete(choice) } })
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 520)
        } foot: {
            UFButton("Fertig", kind: .primary) { close() }
        }
        .task {
            store.refresh()
            supported = WhisperModelStore.supportedVariants()
            checked = true
        }
    }

    private func load(_ choice: WhisperModelChoice) async {
        // angefangenen Download ohne Rueckfrage fortsetzen
        if store.bytesOnDisk(choice) == 0, await !overlay.confirm(WhisperText.confirmDownload(choice)) { return }
        store.download(choice)
    }

    private func delete(_ choice: WhisperModelChoice) async {
        guard await overlay.confirm(UFDevice.adapt("Sprachmodell „\(choice.title)“ von diesem iPad löschen? Fertige Mitschriften bleiben.")) else { return }
        await store.delete(choice)
    }
}

/// Zeile eines Sprachmodells: Name, Groesse, Stand und die passenden Knoepfe (ohne eigenen Zustand, damit sie sich
/// in jedem Stand zeichnen laesst)
struct WhisperModelRow: View {
    let choice: WhisperModelChoice
    let state: WhisperModelStore.State
    let isActive: Bool
    let bytes: Int64
    let offered: Bool
    let suggested: Bool
    let load: () -> Void
    let cancel: () -> Void
    let use: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(choice.title).ufFont(15.2, 650).foregroundStyle(UF.text)
                Text(WhisperText.size(choice.megabytes)).ufFont(12.8).foregroundStyle(UF.muted)
                if suggested, state != .ready { UFBadge("Empfohlen", tone: .accent) }
                if state == .ready { UFBadge(isActive ? "In Benutzung" : "Geladen", tone: .ok) }
                Spacer(minLength: 0)
            }
            Text(choice.note).ufFont(12.8, lh: 1.4).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
            controls
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UF.surface2))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("whisper.model.\(choice.id)")
    }

    @ViewBuilder private var controls: some View {
        switch state {
        case .downloading(let f):
            HStack(spacing: 8) {
                UFProgress(value: f).frame(maxWidth: 220)
                Text(WhisperText.percent(f)).ufFont(12.48).monospacedDigit().foregroundStyle(UF.muted).frame(minWidth: 40, alignment: .leading)
                UFButton("Abbrechen", icon: "x", kind: .ghost, size: .small, action: cancel)
            }
        case .preparing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Wird für dieses Gerät eingerichtet … Das kann eine Minute dauern.").ufFont(12.8).foregroundStyle(UF.muted)
            }
        case .ready:
            HStack(spacing: 8) {
                if !isActive { UFButton("Benutzen", icon: "check", size: .small, action: use) }
                UFButton("Löschen", icon: "trash", kind: .ghost, size: .small, action: delete)
            }
        case .failed(let message):
            Text(message).ufFont(12.8).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                UFButton("Erneut versuchen", icon: "refresh", size: .small, action: load)
                if bytes > 0 { UFButton("Verwerfen", icon: "trash", kind: .ghost, size: .small, action: delete) }
            }
        case .missing:
            if !offered {
                Text("Für dieses Gerät zu groß.").ufFont(12.8).foregroundStyle(UF.muted)
            } else if bytes > 0 {
                HStack(spacing: 8) {
                    UFButton("Fortsetzen", icon: "download", size: .small, action: load)
                    UFButton("Verwerfen", icon: "trash", kind: .ghost, size: .small, action: delete)
                    Text("\(WhisperText.size(bytes: bytes)) schon geladen").ufFont(12.48).foregroundStyle(UF.muted)
                }
            } else {
                UFButton("Laden", icon: "download", kind: suggested ? .primary : .normal, size: .small, action: load)
            }
        }
    }
}

// MARK: - Fortschritt an einer Aufnahme

/// Stand der Whisper-Erkennung einer Aufnahme (wartet, laedt das Modell, laeuft mit Anteil, Fehler)
struct WhisperJobStatus: View {
    let state: WhisperJobs.State
    let cancel: () -> Void

    var body: some View {
        switch state {
        case .waiting:
            line("Wartet, bis die andere Mitschrift fertig ist.", cancelable: true)
        case .loadingModel:
            line("Sprachmodell wird geladen …", cancelable: true)
        case .running(let f):
            HStack(spacing: 8) {
                UFProgress(value: f).frame(maxWidth: 220)
                Text(WhisperText.percent(f)).ufFont(12.48).monospacedDigit().foregroundStyle(UF.muted).frame(minWidth: 40, alignment: .leading)
                UFButton("Anhalten", icon: "square", kind: .ghost, size: .small, action: cancel)
                    .accessibilityHint("Hält die Erkennung an; was fertig ist, bleibt")
            }
            .accessibilityIdentifier("whisper.job.running")
        case .failed(let message):
            Text("Mitschrift nicht möglich: \(message)").ufFont(12.8).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func line(_ text: String, cancelable: Bool) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).ufFont(12.8).foregroundStyle(UF.muted)
            if cancelable { UFButton("Abbrechen", icon: "x", kind: .ghost, size: .small, action: cancel) }
        }
    }
}

// MARK: - Mitschrift zu einer Uni-Aufzeichnung

/// Stand der Mitschriften zu Uni-Aufzeichnungen ({Kennung des Videos: Stand}), fuer die Marke an der Zeile
@MainActor
final class VideoTranscriptIndex: ObservableObject {
    static let shared = VideoTranscriptIndex()
    @Published private(set) var statuses: [String: String] = [:]

    func reload(_ api: APIClient?) async {
        guard WhisperFeature.isEnabled, let api, let v = try? await api.value("/api/recordings/own/videos"), let o = v.object else { return }
        statuses = o.compactMapValues(\.string)
    }

    static func label(_ status: String?) -> String {
        switch status {
        case "done": return "Mitschrift"
        case "partial", "running": return "Mitschrift (teilweise)"
        default: return "Mitschrift erstellen"
        }
    }
}

/// Knopf "Mitschrift" an einer geladenen Uni-Aufzeichnung: legt beim ersten Tippen den Eintrag an und oeffnet die
/// Ansicht der Mitschrift (dieselbe wie bei eigenen Aufnahmen: Erkennen, Lesen, KI-Hilfe).
struct VideoTranscriptControl: View {
    let entry: OpencastEntry
    @ObservedObject var library: RecordingLibrary
    @ObservedObject private var index = VideoTranscriptIndex.shared
    @ObservedObject private var jobs = WhisperJobs.shared
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @State private var opening = false

    var body: some View {
        if WhisperFeature.isEnabled, library.localFile(entry) != nil {
            UFButton(VideoTranscriptIndex.label(index.statuses[entry.id]), icon: "text", kind: .ghost, size: .small) { Task { await open() } }
                .disabled(opening)
                .accessibilityHint("Wandelt den Ton der Aufzeichnung auf dem Gerät in Text um")
                .accessibilityIdentifier("recording.transcript")
                .task { if index.statuses.isEmpty { await index.reload(session.api) } }
                .onChange(of: jobs.revision) { _, _ in Task { await index.reload(session.api) } }
        }
    }

    /// Koerper fuer den neuen Eintrag: Titel und Modul der Aufzeichnung, noch keine Mitschrift
    static func body(for entry: OpencastEntry) -> JSONValue {
        var o: [String: JSONValue] = ["source_video_id": .string(entry.id), "title": .string(entry.video.title), "language": "de-DE",
                                      "course_id": .string(entry.courseID)]
        if let m = entry.moduleID { o["module_id"] = .number(Double(m)) }
        if let d = entry.video.duration { o["duration"] = .number(Double(d)) }
        return .object(o)
    }

    private func open() async {
        guard let api = session.api else { return }
        opening = true
        defer { opening = false }
        do {
            let found = try? await api.value("/api/recordings/own/video?id=\(APIClient.queryValue(entry.id))")
            let row: JSONValue
            if let found, found.s("id") != nil {
                row = found
            } else {
                row = try await api.value("/api/recordings/own", method: "POST", body: Self.body(for: entry))
            }
            guard let id = row.s("id") else { return }
            await index.reload(api)
            _ = overlay.modal(wide: true) { OwnRecordingDetail(id: id) { Task { await index.reload(api) } } }
        } catch {
            toast.show("Mitschrift nicht möglich: \(error.localizedDescription)")
        }
    }
}

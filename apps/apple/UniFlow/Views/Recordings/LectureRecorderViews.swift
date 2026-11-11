import AVFoundation
import SwiftUI
import UniFlowCore

// Vorlesung aufnehmen (docs/VORLESUNG-AUFNEHMEN.md): Bereich "Eigene Aufnahmen" im Reiter Aufzeichnungen des
// Moduldetails, Dialog zum Aufnehmen (Termin aus dem Stundenplan, Pegel, Dauer, Start/Pause/Stopp, Mitschrift live)
// und die Ansicht einer Aufnahme (Abspielen, Abschnitte mit Zeitmarken, auf Wunsch KI-Hilfe mit dem Text, Mitschrift
// nachholen, Loeschen). Aufnahme und Mitschrift bleiben auf dem iPad (`LectureRecorder`); die KI bekommt nur Text und
// nur nach dem Antippen (0 Aufrufe ohne Klick).

// MARK: - Bereich im Moduldetail

struct OwnRecordingsSection: View {
    let moduleID: Int
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @State private var items: [JSONValue]?
    @State private var revision = 0

    var body: some View {
        UFCard {
            UFCardHead("Eigene Aufnahmen", icon: "circle", wrap: true) {
                UFButton("Aufnehmen", icon: "circle", kind: .primary, size: .small) {
                    overlay.modal(wide: true) { LectureRecordDialog(moduleID: moduleID) { revision += 1 } }
                }
                .accessibilityIdentifier("ownrec.record")
                .accessibilityHint("Nimmt die Vorlesung mit dem Mikrofon auf; Aufnahme und Mitschrift bleiben auf dem \(UFDevice.textName)")
            }
            if let items {
                if items.isEmpty {
                    Text("Noch keine eigene Aufnahme. „Aufnehmen“ nimmt die Vorlesung mit dem Mikrofon des \(UFDevice.textName)s auf und schreibt sie auf dem Gerät mit – mit Zeitmarken, später durchsuchbar und auf Wunsch von der KI zusammengefasst.")
                        .ufFont(13.12).foregroundStyle(UF.muted).padding(.top, 8)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 0) {
                        ForEach(items, id: \.self) { r in
                            OwnRecordingRow(recording: r) {
                                overlay.modal(wide: true) { OwnRecordingDetail(id: r.s("id") ?? "") { revision += 1 } }
                            } remove: { Task { await remove(r) } }
                        }
                    }
                    .padding(.top, 8)
                }
            } else {
                UFSkeleton().frame(height: 48).padding(.top, 8)
            }
            Text(UFDevice.adapt("Aufnahme und Mitschrift bleiben auf diesem iPad. An die KI geht nur Text – und nur, wenn du es antippst."))
                .ufFont(12.16).foregroundStyle(UF.muted).padding(.top, 8)
        }
        .padding(.bottom, 14.4)
        .task(id: "\(moduleID)-\(revision)") { await load() }
    }

    private func load() async {
        guard let api = session.api else { items = []; return }
        items = (try? await api.value("/api/recordings/own?module_id=\(moduleID)"))?.array ?? []
    }

    private func remove(_ r: JSONValue) async {
        guard let api = session.api, let id = r.s("id") else { return }
        guard await overlay.confirm(UFDevice.adapt("„\(r.s("title") ?? "Aufnahme")“ samt Mitschrift von diesem iPad löschen?")) else { return }
        do {
            _ = try await api.value("/api/recordings/own/\(id)", method: "DELETE")
            toast.show("Aufnahme gelöscht.")
            revision += 1
        } catch {
            toast.show("Löschen fehlgeschlagen: \(error.localizedDescription)", seconds: 4)
        }
    }
}

/// Zeile einer eigenen Aufnahme: Titel, Datum, Dauer, Stand der Mitschrift, Oeffnen und Loeschen
struct OwnRecordingRow: View {
    let recording: JSONValue
    let open: () -> Void
    let remove: () -> Void

    static func badge(_ r: JSONValue) -> (String, UFTone) {
        let n = r.i("sections") ?? 0
        switch r.s("transcript_status") ?? "none" {
        case "done": return (n == 1 ? "Mitschrift · 1 Abschnitt" : "Mitschrift · \(n) Abschnitte", .ok)
        case "partial": return ("Mitschrift unvollständig", .warn)
        case "running": return ("Mitschrift läuft", .info)
        default: return ("Ohne Mitschrift", .neutral)
        }
    }

    /// "10.11.2026 · 10:20 · 1:28 h"
    static func meta(_ r: JSONValue) -> String {
        let at = r.s("recorded_at") ?? ""
        var parts = [UFFmt.date(String(at.prefix(10)))]
        if at.count >= 16 { parts.append(String(at.dropFirst(11).prefix(5))) }
        if let d = RecordingText.duration(r.n("duration").map { Int($0) }) { parts.append(d) }
        if let e = r.s("event_title"), !e.isEmpty, e != r.s("title") { parts.append(e) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let (text, _) = Self.badge(recording)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12.8) {
                info.frame(maxWidth: .infinity, alignment: .leading)
                actions.fixedSize()
            }
            VStack(alignment: .leading, spacing: 8) {
                info.frame(maxWidth: .infinity, alignment: .leading)
                actions
            }
        }
        .padding(.vertical, 9.6).padding(.horizontal, 8)
        .ufBorderBottom()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(recording.s("title") ?? "Aufnahme"), \(Self.meta(recording)), \(text)")
        .accessibilityIdentifier("ownrec.row")
    }

    private var info: some View {
        let (text, tone) = Self.badge(recording)
        return VStack(alignment: .leading, spacing: 2.4) {
            Text(recording.s("title") ?? "Aufnahme").ufFont(14.5, 550, lh: 1.3).foregroundStyle(UF.text).lineLimit(2)
            Text(Self.meta(recording)).ufFont(12.48).foregroundStyle(UF.muted).lineLimit(1)
            UFBadge(text, tone: tone).padding(.top, 2)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            UFButton("Öffnen", icon: "play", kind: .primary, size: .small, action: open)
            UFButton("Löschen", icon: "trash", kind: .ghost, size: .small, action: remove)
                .accessibilityHint("Entfernt Aufnahme und Mitschrift von diesem Gerät")
        }
    }
}

// MARK: - Dialog "Vorlesung aufnehmen"

struct LectureRecordDialog: View {
    let moduleID: Int
    let onSaved: () -> Void
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @Environment(\.ufClose) private var close
    @StateObject private var holder = RecorderHolder()
    @State private var candidates: [JSONValue] = []
    @State private var eventIndex = -1
    @State private var title = ""
    @State private var language = "de-DE"
    @State private var error: String?
    @State private var saving = false
    @State private var saved = false
    @State private var loadedSuggestion = false

    /// haelt den Recorder ueber Neuzeichnungen; beim Verschwinden des Dialogs wird eine laufende Aufnahme beendet und
    /// gespeichert statt verworfen (90 Minuten gehen nicht durch ein versehentliches Schliessen verloren)
    @MainActor final class RecorderHolder: ObservableObject {
        @Published var recorder: LectureRecorder?
        var id = LocalContext.randomHex()
    }

    private var recorder: LectureRecorder? { holder.recorder }

    /// Speicherort der Aufnahme im Container; nil ohne Container (keine Hochschule gewaehlt)
    private var fileURL: URL? { LocalBackendHost.shared.files?.url(stored: OwnRecordingFiles.audioPath(holder.id)) }

    var body: some View {
        UFDialog("Vorlesung aufnehmen", icon: "circle") {
            VStack(alignment: .leading, spacing: 12) {
                if let r = recorder {
                    RecorderStatus(recorder: r)
                } else {
                    setup
                }
                if let error {
                    Text(error).ufFont(12.8).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ownrec.error")
                }
                Text(UFDevice.adapt("Die Aufnahme läuft auch mit gesperrtem Bildschirm weiter. Aufnahme und Mitschrift bleiben auf diesem iPad; die Spracherkennung läuft nur auf dem Gerät. Frag die Lehrenden vorher, ob du aufnehmen darfst."))
                    .ufFont(12.16).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            }
            .frame(minWidth: 320)
        } foot: {
            foot
        }
        .task { await loadSuggestion() }
        .onDisappear {
            // Dialog weg, Aufnahme laeuft noch: beenden und speichern (nicht verwerfen)
            if let r = holder.recorder, r.state == .recording || r.state == .paused, !saved {
                let snapshot = SaveRequest(id: holder.id, moduleID: moduleID, event: selectedEvent, title: title, language: language, api: session.api)
                Task { @MainActor in await r.stop(); _ = await Self.save(r, snapshot) }
            }
        }
    }

    private var selectedEvent: JSONValue? { eventIndex >= 0 && eventIndex < candidates.count ? candidates[eventIndex] : nil }

    @ViewBuilder private var setup: some View {
        if !candidates.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Termin").ufFont(12.8, 600).foregroundStyle(UF.text2)
                UFSelect(options: [(-1, "Ohne Termin")] + candidates.indices.map { ($0, Self.label(candidates[$0])) }, selection: $eventIndex, fill: true)
                    .accessibilityIdentifier("ownrec.event")
            }
        } else if loadedSuggestion {
            Text("Heute steht kein Termin dieses Moduls im Stundenplan – die Aufnahme bekommt nur Datum und Titel.")
                .ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("Titel").ufFont(12.8, 600).foregroundStyle(UF.text2)
            UFTextField("Titel der Aufnahme", text: $title).accessibilityIdentifier("ownrec.title")
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("Sprache der Mitschrift").ufFont(12.8, 600).foregroundStyle(UF.text2)
            UFSelect(options: LectureRecorder.languages, selection: $language)
            if !LectureRecorder.onDeviceAvailable(language) {
                Text("Für diese Sprache ist die Spracherkennung auf dem Gerät nicht geladen (iOS-Einstellungen → Allgemein → Tastatur → Diktieren). Aufgenommen wird trotzdem, die Mitschrift lässt sich später nachholen.")
                    .ufFont(12.16).foregroundStyle(UF.warn).fixedSize(horizontal: false, vertical: true)
            }
        }
        if fileURL == nil {
            Text("Auf diesem Gerät gibt es keinen Speicherort für Aufnahmen (keine Hochschule gewählt).")
                .ufFont(12.8).foregroundStyle(UF.bad)
        }
    }

    @ViewBuilder private var foot: some View {
        if let r = recorder {
            switch r.state {
            case .recording:
                UFButton("Pause", icon: "square", kind: .ghost) { r.pause() }
                UFButton("Stopp und speichern", icon: "check", kind: .primary) { Task { await finish() } }
            case .paused:
                UFButton("Fortsetzen", icon: "play", kind: .ghost) { r.resume() }
                UFButton("Stopp und speichern", icon: "check", kind: .primary) { Task { await finish() } }
            case .finishing:
                UFButton(saving ? "Speichert …" : "Beendet …", kind: .primary) {}.disabled(true)
            case .done:
                if saved {
                    UFButton("Schließen") { close() }
                } else {
                    UFButton("Verwerfen", icon: "trash", kind: .ghost) { r.discard(); close() }
                    UFButton(saving ? "Speichert …" : "Erneut speichern", kind: .primary) { Task { await finish() } }.disabled(saving)
                }
            case .failed, .idle:
                UFButton("Schließen") { r.discard(); close() }
            }
        } else {
            UFButton("Abbrechen") { close() }
            UFButton("Aufnahme starten", icon: "circle", kind: .primary) { Task { await start() } }
                .disabled(fileURL == nil)
                .accessibilityIdentifier("ownrec.start")
        }
    }

    static func label(_ e: JSONValue) -> String {
        [e.s("title") ?? "Termin", [e.s("start"), e.s("end")].compactMap { $0 }.joined(separator: "–"), e.s("room")]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Termine des Tages fuer dieses Modul; der laufende ist vorgewaehlt
    private func loadSuggestion() async {
        defer { loadedSuggestion = true }
        guard let api = session.api, let r = try? await api.value("/api/recordings/own/suggest") else { return }
        candidates = r.list("candidates").filter { $0.i("module_id") == moduleID }
        if let current = r["event"], current.i("module_id") == moduleID,
           let i = candidates.firstIndex(where: { $0["event_id"] == current["event_id"] && $0["start"] == current["start"] }) {
            eventIndex = i
        } else if candidates.count == 1 {
            eventIndex = 0
        }
        if title.isEmpty { title = defaultTitle() }
    }

    /// "Analysis I · 10.11.2026" bzw. "Vorlesung vom 10.11.2026" (heute nach der Ortszeit des Geraets)
    static func defaultTitle(event: String?, date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "dd.MM.yyyy"
        let day = f.string(from: date)
        if let e = event, !e.isEmpty { return "\(e) · \(day)" }
        return "Vorlesung vom \(day)"
    }

    private func defaultTitle() -> String { Self.defaultTitle(event: selectedEvent?.s("title")) }

    private func start() async {
        error = nil
        guard let url = fileURL else { return }
        guard await LectureRecorder.requestMicrophone() else {
            error = "Ohne Zugriff auf das Mikrofon kann StudiNow nicht aufnehmen (Einstellungen → StudiNow → Mikrofon)."
            return
        }
        _ = await LectureRecorder.requestSpeech()           // abgelehnt: Aufnahme ohne Mitschrift (der Recorder sagt es)
        if title.trimmingCharacters(in: .whitespaces).isEmpty { title = defaultTitle() }
        let r = LectureRecorder(id: holder.id, fileURL: url, language: language)
        holder.recorder = r
        r.start()
        if case .failed(let m) = r.state { error = m }
    }

    /// Aufnahme beenden und eintragen; bei einem Fehler bleibt die Datei liegen und "Erneut speichern" versucht es noch einmal
    private func finish() async {
        guard let r = recorder else { return }
        saving = true
        defer { saving = false }
        if r.state == .recording || r.state == .paused { await r.stop() }
        let req = SaveRequest(id: holder.id, moduleID: moduleID, event: selectedEvent, title: title, language: language, api: session.api)
        if let problem = await Self.save(r, req) {
            error = problem
        } else {
            saved = true
            onSaved()
            toast.show("Aufnahme gespeichert" + (RecordingText.duration(Int(r.seconds)).map { " (\($0))" } ?? "") + ".")
            close()
        }
    }

    struct SaveRequest {
        let id: String
        let moduleID: Int
        let event: JSONValue?
        let title: String
        let language: String
        let api: APIClient?
    }

    /// POST /api/recordings/own mit Dauer, Termin und Abschnitten; nil bei Erfolg, sonst die Meldung
    static func save(_ r: LectureRecorder, _ s: SaveRequest) async -> String? {
        guard let api = s.api else { return "Keine Verbindung zum lokalen Backend." }
        var body: [String: JSONValue] = ["id": .string(s.id), "module_id": .number(Double(s.moduleID)), "duration": .number(r.seconds),
                                         "language": .string(s.language), "transcript_status": .string(r.transcriptStatus)]
        let t = s.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { body["title"] = .string(t) }
        if let e = s.event {
            body["event_title"] = e["title"] ?? .null
            body["event_id"] = e["event_id"] ?? .null
            body["course_id"] = e["course_id"] ?? .null
        }
        if !r.sections.isEmpty { body["transcript"] = TranscriptSections.json(r.sections) }
        do {
            _ = try await api.value("/api/recordings/own", method: "POST", body: .object(body))
            return nil
        } catch {
            return "Die Aufnahme ließ sich nicht eintragen: \(error.localizedDescription) Die Datei liegt noch auf dem \(UFDevice.textName)."
        }
    }
}

/// Pegel, Dauer, Zustand und Mitschrift waehrend der Aufnahme
private struct RecorderStatus: View {
    @ObservedObject var recorder: LectureRecorder

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Circle().fill(recorder.state == .recording ? UF.bad : UF.muted).frame(width: 12, height: 12)
                    .opacity(recorder.state == .recording ? 1 : 0.6)
                Text(stateText).ufFont(14.5, 600).foregroundStyle(UF.text)
                Spacer()
                Text(TranscriptSections.timestamp(recorder.seconds)).ufFont(21.6, 700).monospacedDigit().foregroundStyle(UF.text)
                    .accessibilityLabel("Dauer \(TranscriptSections.timestamp(recorder.seconds))")
            }
            UFProgress(value: recorder.level, color: recorder.state == .recording ? UF.accent : UF.muted)
                .accessibilityLabel("Pegel")
            HStack(spacing: 8) {
                UFBadge(transcriptLabel, tone: transcriptTone)
                if let note = recorder.transcriptNote {
                    Text(note).ufFont(12.16).foregroundStyle(UF.muted).lineLimit(3)
                }
            }
            if !recorder.sections.isEmpty || !recorder.partial.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(recorder.sections.suffix(2).enumerated()), id: \.offset) { _, s in
                            SectionText(section: s)
                        }
                        if !recorder.partial.isEmpty {
                            Text(recorder.partial).ufFont(13.12).foregroundStyle(UF.text2).italic()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UF.surface2))
            }
        }
    }

    private var stateText: String {
        switch recorder.state {
        case .recording: return "Aufnahme läuft"
        case .paused: return "Pause"
        case .finishing: return "Wird beendet …"
        case .done: return "Aufnahme beendet"
        case .failed(let m): return m
        case .idle: return "Bereit"
        }
    }

    private var transcriptLabel: String {
        switch recorder.transcript {
        case .running: return "Mitschrift läuft (auf dem Gerät)"
        case .partial: return "Mitschrift unvollständig"
        case .done: return "Mitschrift fertig"
        case .failed: return "Mitschrift fehlgeschlagen"
        case .unavailable: return "Ohne Mitschrift"
        case .none: return "Mitschrift"
        }
    }

    private var transcriptTone: UFTone {
        switch recorder.transcript {
        case .running, .done: return .ok
        case .partial: return .warn
        case .failed, .unavailable: return .neutral
        case .none: return .info
        }
    }
}

/// Ein Abschnitt mit Zeitmarke; antippbar zum Springen im Player
struct SectionText: View {
    let section: TranscriptSection
    var seek: ((Double) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let seek {
                Button(TranscriptSections.timestamp(section.start)) { seek(section.start) }
                    .font(.uf(12.48, 650)).monospacedDigit().foregroundStyle(UF.accentText).buttonStyle(.plain)
                    .accessibilityLabel("Springe zu \(TranscriptSections.timestamp(section.start))")
            } else {
                Text(TranscriptSections.timestamp(section.start)).ufFont(12.48, 650).monospacedDigit().foregroundStyle(UF.accentText)
            }
            Text(section.text).ufFont(13.12, lh: 1.4).foregroundStyle(UF.text).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Ansicht einer Aufnahme

struct OwnRecordingDetail: View {
    let id: String
    let onChange: () -> Void
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @Environment(\.ufClose) private var close
    @Environment(\.ufAIEnabled) private var aiEnabled
    @StateObject private var player = OwnRecordingPlayer()
    @State private var recording: JSONValue?
    @State private var sections: [TranscriptSection] = []
    @State private var chunk = 0
    @State private var busy: String?
    @State private var answer: String?
    @State private var answerLabel = ""
    @State private var cards: [JSONValue] = []
    @State private var cardsSaved = false
    @State private var error: String?
    @State private var transcribing = false

    private var audioURL: URL? {
        guard let p = recording?.s("audio_path"), let files = LocalBackendHost.shared.files, files.exists(stored: p) else { return nil }
        return files.url(stored: p)
    }

    var body: some View {
        UFDialog(recording?.s("title") ?? "Aufnahme", icon: "circle") {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let r = recording {
                        Text(OwnRecordingRow.meta(r) + (r.s("module_name").map { " · \($0)" } ?? "")).ufFont(12.8).foregroundStyle(UF.muted)
                        playerView
                        transcriptView(r)
                        if aiEnabled, !sections.isEmpty { aiView } else if !sections.isEmpty {
                            Text(ChatGPTLink.isEnabled ? "Zusammenfassung, Kernpunkte und Karteikarten aus der Mitschrift gibt es, sobald ChatGPT in den Einstellungen verbunden ist."
                                                       : "Zusammenfassung, Kernpunkte und Karteikarten aus der Mitschrift kommen mit der StudiNow-KI in StudiNow Pro AI.")
                                .ufFont(12.16).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                        }
                        if let error { Text(error).ufFont(12.8).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true) }
                    } else {
                        UFSkeleton().frame(height: 120)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 620)
        } foot: {
            UFButton("Umbenennen", icon: "pencil", kind: .ghost) { Task { await rename() } }
            UFButton("Löschen", icon: "trash", kind: .danger) { Task { await remove() } }
            UFButton("Schließen") { player.stop(); close() }
        }
        .task { await load() }
        .onDisappear { player.stop() }
    }

    private var playerView: some View {
        HStack(spacing: 10) {
            if audioURL != nil {
                UFButton(player.playing ? "Pause" : "Abspielen", icon: player.playing ? "square" : "play", kind: .primary, size: .small) {
                    if player.playing { player.pause() } else if let url = audioURL { player.play(url) }
                }
                Text("\(TranscriptSections.timestamp(player.position)) / \(TranscriptSections.timestamp(player.duration))")
                    .ufFont(12.8).monospacedDigit().foregroundStyle(UF.muted)
            } else {
                Text(UFDevice.adapt("Die Audiodatei liegt nicht mehr auf diesem iPad.")).ufFont(12.8).foregroundStyle(UF.muted)
            }
        }
    }

    @ViewBuilder private func transcriptView(_ r: JSONValue) -> some View {
        let status = r.s("transcript_status") ?? "none"
        HStack(spacing: 8) {
            Text("Mitschrift").ufFont(15.2, 650).foregroundStyle(UF.text)
            let (text, tone) = OwnRecordingRow.badge(r)
            UFBadge(text, tone: tone)
            Spacer()
            if status != "done", audioURL != nil {
                UFButton(transcribing ? "Erkennt …" : "Mitschrift nachholen", icon: "text", size: .small) { Task { await transcribe() } }
                    .disabled(transcribing)
                    .accessibilityHint("Spracherkennung auf dem Gerät für die ganze Aufnahme")
            }
        }
        if sections.isEmpty {
            Text(status == "unavailable" ? "Diese Aufnahme wurde ohne Spracherkennung gemacht." : "Noch keine Mitschrift.")
                .ufFont(12.8).foregroundStyle(UF.muted)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, s in
                    SectionText(section: s) { t in if let url = audioURL { player.seek(url, to: t) } }
                }
            }
        }
    }

    private var chunks: [[TranscriptSection]] { TranscriptSections.chunks(sections) }

    private var aiView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("KI-Hilfe mit der Mitschrift").ufFont(15.2, 650).foregroundStyle(UF.text)
            let parts = chunks
            if parts.count > 1 {
                Text("Die KI bekommt höchstens \(TranscriptSections.promptChars) Zeichen auf einmal – die Mitschrift ist in \(parts.count) Teile geteilt.")
                    .ufFont(12.16).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                UFSelect(options: parts.indices.map { i in
                    (i, "Teil \(i + 1): \(TranscriptSections.timestamp(parts[i].first?.start ?? 0))–\(TranscriptSections.timestamp(parts[i].last?.end ?? 0))")
                }, selection: $chunk)
            }
            HStack(spacing: 8) {
                UFButton(busy == "summary" ? "Fasst zusammen …" : "Zusammenfassen", icon: "sparkles", size: .small) { Task { await ask("summary") } }
                UFButton(busy == "points" ? "Sucht Kernpunkte …" : "Kernpunkte", icon: "list", size: .small) { Task { await ask("points") } }
                UFButton(busy == "flashcards" ? "Erstellt Karten …" : "Karteikarten", icon: "cards", size: .small) { Task { await ask("flashcards") } }
            }
            .disabled(busy != nil)
            Text(OpenAIKeyLink.isOffered ? "Gesendet wird nur der Text dieses Teils an dein ChatGPT – nie die Aufnahme." : "Gesendet wird nur der Text dieses Teils an die KI – nie die Aufnahme.").ufFont(12.16).foregroundStyle(UF.muted)
            if let answer {
                VStack(alignment: .leading, spacing: 6) {
                    Text(answerLabel).ufFont(12.8, 650).foregroundStyle(UF.text2)
                    AIMarkdownText(answer).accessibilityIdentifier("ownrec.answer")
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UF.surface2))
            }
            if !cards.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(cards.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(FormulaText.attributed(cards[i].s("question") ?? "", size: 13.76, weight: 650)).ufFont(13.76, 650).foregroundStyle(UF.text)
                            Text(FormulaText.attributed(cards[i].s("answer") ?? "", size: 13.12)).ufFont(13.12).foregroundStyle(UF.text2)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UF.surface2))
                    }
                    UFButton(cardsSaved ? "In Karteikarten gespeichert" : "Als Karteikarten speichern", icon: "cards", size: .small) { Task { await saveCards() } }
                        .disabled(cardsSaved)
                }
            }
        }
    }

    private func load() async {
        guard let api = session.api else { return }
        do {
            let r = try await api.value("/api/recordings/own/\(id)")
            recording = r
            sections = TranscriptSections.sections(r["transcript"]) ?? []
            chunk = 0
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Tutor-Endpunkt mit dem Text des gewaehlten Teils (kein Dokument, keine Seite); nur nach Antippen
    private func ask(_ what: String) async {
        guard let api = session.api, chunk < chunks.count else { return }
        busy = what
        error = nil
        defer { busy = nil }
        let text = TranscriptSections.plainText(chunks[chunk])
        var body: [String: JSONValue] = ["page_text": .string(text), "file_id": .null]
        switch what {
        case "summary":
            body["mode"] = "summary"
            answerLabel = "Zusammenfassung"
        case "points":
            body["mode"] = "ask"
            body["question"] = "Nenne die Kernpunkte dieses Vorlesungsabschnitts als knappe Liste (höchstens 8 Punkte) und danach die wichtigsten Fachbegriffe mit je einem Satz."
            answerLabel = "Kernpunkte"
        default:
            body["mode"] = "flashcards"
            answerLabel = "Karteikarten"
        }
        do {
            let r = try await api.value("/api/ai/tutor", method: "POST", body: .object(body))
            if what == "flashcards" {
                cards = r["cards"]?.array ?? []
                cardsSaved = false
                answer = cards.isEmpty ? (r.s("answer") ?? "") : nil
            } else {
                answer = r.s("answer") ?? ""
                cards = []
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func saveCards() async {
        guard let api = session.api, !cards.isEmpty else { return }
        do {
            _ = try await api.value("/api/flashcards", method: "POST", body: ["cards": .array(cards)])
            cardsSaved = true
            toast.show("\(cards.count) Karteikarten gespeichert.")
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Spracherkennung der ganzen Datei auf dem Geraet, danach PATCH mit den Abschnitten
    private func transcribe() async {
        guard let url = audioURL, let api = session.api else { return }
        transcribing = true
        error = nil
        defer { transcribing = false }
        do {
            let result = try await LectureRecorder.transcribe(url: url, language: recording?.s("language") ?? "de-DE")
            _ = try await api.value("/api/recordings/own/\(id)", method: "PATCH",
                                    body: ["transcript": TranscriptSections.json(result), "transcript_status": .string(result.isEmpty ? "failed" : "done")])
            await load()
            onChange()
            toast.show(result.isEmpty ? "Keine Sprache erkannt." : "Mitschrift fertig (\(result.count) Abschnitte).")
        } catch {
            self.error = "Mitschrift nicht möglich: \(error.localizedDescription)"
        }
    }

    private func rename() async {
        guard let api = session.api, let t = await overlay.prompt("Neuer Titel", value: recording?.s("title") ?? ""),
              !t.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            _ = try await api.value("/api/recordings/own/\(id)", method: "PATCH", body: ["title": .string(t)])
            await load()
            onChange()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove() async {
        guard let api = session.api, await overlay.confirm(UFDevice.adapt("Aufnahme samt Mitschrift von diesem iPad löschen?")) else { return }
        do {
            player.stop()
            _ = try await api.value("/api/recordings/own/\(id)", method: "DELETE")
            onChange()
            toast.show("Aufnahme gelöscht.")
            close()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Abspielen der m4a-Datei (AVAudioPlayer) mit Stelle und Sprung zu einer Zeitmarke
@MainActor
final class OwnRecordingPlayer: ObservableObject {
    @Published private(set) var playing = false
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func play(_ url: URL) {
        if player?.url != url {
            player = try? AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            duration = player?.duration ?? 0
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        player?.play()
        playing = player?.isPlaying ?? false
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    func seek(_ url: URL, to seconds: Double) {
        if player?.url != url || player == nil { play(url) }
        player?.currentTime = max(0, min(seconds, (player?.duration ?? 0) - 0.5))
        if !(player?.isPlaying ?? false) { player?.play() }
        playing = player?.isPlaying ?? false
        position = player?.currentTime ?? 0
    }

    func pause() {
        player?.pause()
        playing = false
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        playing = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func tick() {
        guard let p = player else { return }
        position = p.currentTime
        duration = p.duration
        if !p.isPlaying, playing { playing = false }
    }
}

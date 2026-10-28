import AVKit
import SwiftUI
import UniFlowCore
import WebKit

// Opencast-Aufzeichnungen im UniFlow-Design. Bereich "Aufzeichnungen" im Moduldetail nach Lehrwoche (dieselben Bloecke
// wie die Dokumente, `OpencastStore`), je Video Vorschau, Titel, Art, Laufzeit, Datum, Autor, "Abspielen" und "Laden".
// Abspielen im eigenen Player (geladene Datei vor Stream, 720p bevorzugt, Fortsetzen an der gemerkten Stelle);
// verlangt der Videoserver eine Anmeldung, zeigt die Stud.IP-Player-Seite das Video in einer Webansicht mit der
// Stud.IP-Sitzung. Laden nur auf Wunsch (`RecordingDownloadPolicy`). Passende Aufzeichnung an Dokument und Lernpaket
// nur bei sicherem Treffer. Videos gehoeren den Lehrenden: nur privat ansehen, kein Teilen.
// Die Daten liegen in der lokalen Datenbank; mit eigenem PC-Server (Entwicklungsmodus) gibt es den Bereich nicht.

// MARK: - Bereich "Aufzeichnungen" im Moduldetail

struct RecordingsPanel: View {
    let moduleID: Int
    /// Woche, zu der aus der Uebersicht gesprungen wurde (hervorgehoben)
    var focusWeek: Int?
    @EnvironmentObject private var studip: StudIPSync

    var body: some View {
        RecordingsPanelContent(moduleID: moduleID, focusWeek: focusWeek, library: studip.recordings)
    }
}

private struct RecordingsPanelContent: View {
    let moduleID: Int
    var focusWeek: Int?
    @ObservedObject var library: RecordingLibrary
    @EnvironmentObject private var studip: StudIPSync
    @Environment(\.ufDemoActive) private var demo
    @State private var blocks: [OpencastWeekBlock]?

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                if let blocks {
                    if blocks.isEmpty {
                        UFCard { UFEmpty(icon: "play", text: emptyText) }
                    } else {
                        RecordingWeekBlocks(blocks: blocks, focusWeek: focusWeek, library: library)
                        RecordingsPrivacyNote()
                    }
                } else {
                    UFSkeleton().frame(height: 120)
                }
            }
            .task(id: "\(moduleID)-\(library.revision)") {
                blocks = await library.blocks(moduleID: moduleID)
                // Sprung aus dem Wochenblock der Uebersicht: diese Woche zeigen
                if let w = focusWeek, blocks?.contains(where: { $0.week == w }) == true {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    withAnimation(UF.transition) { proxy.scrollTo("rec-week-\(w)", anchor: .top) }
                }
            }
        }
    }

    private var emptyText: String {
        // dieselbe Weiche wie die Seiten (`UFDataMode.current`): Stud.IP des offenen Containers, an einer Hochschule
        // ohne Stud.IP (Universitaet Hildesheim) kommen keine Aufzeichnungen
        let link: StudIPLink = demo ? .demo : studip.offersStudIP ? StudIPLink(studip.phase, hasSession: studip.hasStoredSession) : .otherSources
        switch link {
        case .notConnected: return "Verbinde Stud.IP, dann erscheinen hier die Aufzeichnungen deiner Kurse nach Vorlesungswoche."
        case .expired: return "Melde dich erneut bei Stud.IP an, damit Studora die Aufzeichnungen aktualisiert."
        case .connected:
            return studip.isRunning ? "Aufzeichnungen werden beim laufenden Abgleich geprüft …" : "Keine Aufzeichnungen zu diesem Modul."
        case .otherSources: return "Aufzeichnungen (Opencast) gibt es in Studora nur über das Stud.IP der Leibniz Universität Hannover; das Learnweb der Universität Hildesheim bietet keine."
        case .demo: return "Die Demo-Inhalte haben keine Aufzeichnungen. Sie kommen mit deiner Stud.IP-Anmeldung, wenn die Demo entfernt ist."
        }
    }
}

struct RecordingsPrivacyNote: View {
    var body: some View {
        Text("Aufzeichnungen gehören den Lehrenden: nur zum privaten Ansehen, nicht weitergeben.")
            .ufFont(12.16).foregroundStyle(UF.muted)
            .padding(.top, 4)
    }
}

/// Wochenbloecke (.card.week-block) mit den Videos, Reihenfolge und Beschriftung wie im Moduldetail
struct RecordingWeekBlocks: View {
    let blocks: [OpencastWeekBlock]
    var focusWeek: Int?
    @ObservedObject var library: RecordingLibrary
    @State private var playing: OpencastEntry?
    @State private var collapsed: Set<Int> = []

    var body: some View {
        let manyCourses = Set(blocks.flatMap { $0.entries.map(\.courseID) }).count > 1
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks) { b in
                let open = !collapsed.contains(b.week)
                UFCard {
                    HStack(spacing: 9.6) {
                        UFIcon("chevron-down", size: 16).foregroundStyle(UF.text).rotationEffect(.degrees(open ? 0 : -90))
                        Text(b.label).ufFont(15.2, 650, em: -0.01).foregroundStyle(UF.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(RecordingText.count(b.entries.count)).ufFont(12.8).foregroundStyle(UF.muted)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .onTapGesture { if open { collapsed.insert(b.week) } else { collapsed.remove(b.week) } }
                    if open {
                        VStack(spacing: 0) {
                            ForEach(b.entries) { e in
                                RecordingRow(entry: e, showCourse: manyCourses, library: library) { playing = e }
                            }
                        }
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(UF.accent, lineWidth: focusWeek == b.week ? 2 : 0))
                .id("rec-week-\(b.week)")
                .padding(.bottom, 14.4)
            }
        }
        .fullScreenCover(item: $playing) { e in RecordingPlayerView(entry: e, library: library) }
    }
}

enum RecordingText {
    static func count(_ n: Int) -> String { n == 1 ? "1 Aufzeichnung" : "\(n) Aufzeichnungen" }

    /// "1:28 h", "36 min"
    static func duration(_ seconds: Int?) -> String? {
        guard let s = seconds, s > 0 else { return nil }
        if s >= 3600 { return String(format: "%d:%02d h", s / 3600, (s % 3600) / 60) }
        return "\(max(1, Int((Double(s) / 60).rounded()))) min"
    }

    /// Erstellt am, wie das Datum der Dokumente
    static func date(_ unix: Int?) -> String? {
        unix.map { UFFmt.date(UFFmt.isoFromUnix(Double($0))) }
    }
}

// MARK: - Zeile

struct RecordingRow: View {
    let entry: OpencastEntry
    var showCourse = false
    @ObservedObject var library: RecordingLibrary
    let play: () -> Void

    var body: some View {
        let v = entry.video
        let meta = [entry.label, RecordingText.duration(v.duration), RecordingText.date(v.created), v.author].compactMap { $0 }
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12.8) {
                RecordingThumbnail(url: v.thumbnailURL, library: library, action: play)
                info(meta).frame(maxWidth: .infinity, alignment: .leading)
                actions.fixedSize()
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12.8) {
                    RecordingThumbnail(url: v.thumbnailURL, library: library, action: play)
                    info(meta).frame(maxWidth: .infinity, alignment: .leading)
                }
                actions
            }
        }
        .padding(.vertical, 9.6).padding(.horizontal, 8)
        .ufBorderBottom()
    }

    private func info(_ meta: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2.4) {
            Text(entry.video.title).ufFont(14.5, 550, lh: 1.3).foregroundStyle(UF.text).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let d = entry.video.description {
                Text(d).ufFont(12.8).foregroundStyle(UF.text2).lineLimit(2)
            }
            Text((showCourse ? [entry.courseTitle] + meta : meta).joined(separator: " · ")).ufFont(12.48).foregroundStyle(UF.muted).lineLimit(1)
            if entry.gone {
                UFBadge("In Stud.IP nicht mehr vorhanden", tone: .warn).padding(.top, 2)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            UFButton("Abspielen", icon: "play", kind: .primary, size: .small, action: play)
            RecordingDownloadControl(entry: entry, library: library)
        }
    }
}

/// Vorschaubild ueber `RecordingLibrary.thumbnail` (eigene Sitzung des Containers, kein app-weiter Zwischenspeicher)
struct RecordingThumbnail: View {
    let url: URL?
    let library: RecordingLibrary
    let action: () -> Void
    @State private var image: UIImage?

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: UF.rSm).fill(UF.surface2)
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                Circle().fill(.black.opacity(0.45)).frame(width: 30, height: 30)
                    .overlay(UFIcon("play", size: 14).foregroundStyle(.white))
            }
            .frame(width: 128, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: UF.rSm))
            .overlay(RoundedRectangle(cornerRadius: UF.rSm).strokeBorder(UF.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Abspielen")
        .task(id: url) { image = nil; if let url { image = await library.thumbnail(url) } }
    }
}

// MARK: - Laden nur auf Wunsch

/// "Laden" / Fortschritt mit "Abbrechen" / "Fortsetzen" / "Geladen" mit "Entfernen". Der Abgleich laedt nie ein Video;
/// ueber 100 MB oder mit unbekannter Groesse erst nach ausdruecklicher Bestaetigung (Entscheidung 7).
struct RecordingDownloadControl: View {
    let entry: OpencastEntry
    @ObservedObject var library: RecordingLibrary
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @State private var asking = false

    var body: some View {
        if let local = library.localFile(entry) {
            HStack(spacing: 6) {
                UFBadge("Geladen · \(local.quality)", tone: .ok)
                UFButton("Entfernen", icon: "trash", kind: .ghost, size: .small) { Task { await library.remove(entry) } }
                    .accessibilityHint("Entfernt die geladene Datei von diesem Gerät")
            }
        } else if let state = library.state(entry) {
            pending(state)
        } else if let d = RecordingPlayback.quality(for: entry.video) {
            HStack(spacing: 6) {
                // abgebrochener Download (auch nach einem Neustart der App): in seiner Fassung fortsetzen
                if let paused = library.pausedMedia(entry) {
                    UFButton("Fortsetzen", icon: "download", size: .small) { Task { await load(paused) } }
                        .accessibilityHint("Lädt die Fassung \(paused.quality) weiter")
                    UFButton("Verwerfen", icon: "trash", kind: .ghost, size: .small) { Task { await library.remove(entry) } }
                } else {
                    UFButton(asking ? "Prüft …" : "Laden", icon: "download", size: .small) { Task { await load(d) } }
                        .disabled(asking)
                        .contextMenu {
                            ForEach(entry.video.media, id: \.quality) { other in
                                Button("\(other.quality) laden") { Task { await load(other) } }
                            }
                        }
                        .accessibilityHint("Lädt die Aufzeichnung nur auf Wunsch auf dieses Gerät")
                }
            }
        }
    }

    @ViewBuilder private func pending(_ state: RecordingLibrary.DownloadState) -> some View {
        switch state {
        case .running(let f, _):
            HStack(spacing: 8) {
                UFProgress(value: f ?? 0).frame(width: 90)
                Text(f.map { "\(Int(($0 * 100).rounded())) %" } ?? "…").ufFont(12.48).foregroundStyle(UF.muted)
                    .frame(minWidth: 36, alignment: .leading)
                UFButton("Abbrechen", icon: "x", kind: .ghost, size: .small) { library.cancel(entry) }
            }
        case .paused:
            HStack(spacing: 6) {
                UFButton("Fortsetzen", icon: "download", size: .small) { resume() }
                UFButton("Verwerfen", icon: "trash", kind: .ghost, size: .small) { Task { await library.remove(entry) } }
            }
        case .failed(let message, _):
            HStack(spacing: 6) {
                Text(message).ufFont(12.48).foregroundStyle(UF.bad).lineLimit(2).frame(maxWidth: 220, alignment: .leading)
                UFButton("Erneut", icon: "refresh", size: .small) { resume() }
                UFButton("Verwerfen", icon: "trash", kind: .ghost, size: .small) { Task { await library.remove(entry) } }
            }
        }
    }

    /// "Fortsetzen" und "Erneut": dieselbe Fassung wie der abgebrochene bzw. gescheiterte Download
    private func resume() {
        guard let d = library.resumeMedia(entry) ?? RecordingPlayback.quality(for: entry.video) else { return }
        Task { await load(d) }
    }

    /// Groesse fragen, nach `RecordingDownloadPolicy` entscheiden, dann laden
    private func load(_ d: OpencastMedia) async {
        guard !library.isLoading(entry) else {
            toast.show("Für diese Aufzeichnung läuft bereits ein Download.")
            return
        }
        // Fortsetzen braucht keine neue Bestaetigung (der Wunsch galt schon)
        if library.hasResumeData(entry, quality: d.quality), RecordingLibrary.resumeUsable(library.resumeURL(entry, quality: d.quality), url: d.url) {
            library.start(entry, media: d)
            return
        }
        asking = true
        let probe = await library.probe(d.url)
        asking = false
        if probe.needsLogin {
            toast.show("Der Videoserver verlangt eine Anmeldung – laden geht nicht, abspielen geht über Stud.IP.", seconds: 4)
            return
        }
        // keine Antwort oder Fehlerstatus: der Download koennte gar nicht starten, also keine Rueckfrage zur Groesse
        if let problem = probe.failure {
            toast.show(problem, seconds: 4)
            return
        }
        switch RecordingDownloadPolicy.decide(title: entry.video.title, quality: d.quality, size: probe.size, freeBytes: library.freeBytes()) {
        case .refuse(let message):
            toast.show(message, seconds: 4)
        case .confirm(let question):
            if await overlay.confirm(question) { library.start(entry, media: d) }
        case .start:
            library.start(entry, media: d)
            toast.show("„\(entry.video.title)“ wird geladen (\(d.quality)).")
        }
    }
}

// MARK: - Aufzeichnungen ohne Modul (Meine Module)

/// Kurse ohne Modul (z. B. Begruessung) mit Aufzeichnungen: je Kurs eine Karte, oeffnet die Aufzeichnungen nach Woche
struct RecordingsUnassignedSection: View {
    @EnvironmentObject private var studip: StudIPSync

    var body: some View { Content(library: studip.recordings) }

    private struct Content: View {
        @ObservedObject var library: RecordingLibrary
        @EnvironmentObject private var overlay: UFOverlay
        @State private var groups: [OpencastCourseGroup] = []

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                if !groups.isEmpty {
                    HStack(spacing: 7.2) {
                        UFIcon("play", size: 18)
                        Text("Aufzeichnungen ohne Modul").ufFont(17.6, 650, em: -0.01)
                    }
                    .foregroundStyle(UF.text)
                    Text("Opencast-Aufzeichnungen aus Stud.IP-Kursen, die keinem Modul zugeordnet sind.")
                        .ufFont(13.12).foregroundStyle(UF.muted).padding(.top, 2.4).padding(.bottom, 12.8)
                    UFAutoGrid(min: 260, spacing: 12.8) {
                        ForEach(groups) { g in
                            Button {
                                overlay.modal(wide: true) { RecordingsCourseDialog(group: g, library: library) }
                            } label: {
                                UFCard {
                                    HStack(spacing: 12) {
                                        RoundedRectangle(cornerRadius: 10).fill(UF.accentSoft).frame(width: 40, height: 40)
                                            .overlay(UFIcon("play", size: 18).foregroundStyle(UF.accentText))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(g.courseTitle).ufFont(14.5, 650).foregroundStyle(UF.text).lineLimit(2)
                                            Text(RecordingText.count(g.count)).ufFont(12.48).foregroundStyle(UF.muted)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        UFIcon("chevron-right", size: 16).foregroundStyle(UF.accentText)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
            .task(id: library.revision) { groups = await library.unassigned() }
        }
    }
}

struct RecordingsCourseDialog: View {
    let group: OpencastCourseGroup
    @ObservedObject var library: RecordingLibrary
    @Environment(\.ufClose) private var close

    var body: some View {
        UFDialog("Aufzeichnungen: \(group.courseTitle)", icon: "play") {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    RecordingWeekBlocks(blocks: group.blocks, library: library)
                    RecordingsPrivacyNote()
                }
            }
            .frame(maxHeight: 560)
        } foot: {
            UFButton("Schließen") { close() }
        }
    }
}

// MARK: - Passende Aufzeichnung (Dokument, Lernpaket)

/// Hinweis im Dokument: nur bei sicherem Treffer (gleiches Fach UND gleiche Lehrwoche oder eindeutiges Thema)
struct RecordingMatchBanner: View {
    let fileID: String
    /// weiterer Text des Dokuments (Anfang der ersten Seite); erst beim Suchen gelesen, nicht bei jedem Neuzeichnen
    let text: () -> String
    @EnvironmentObject private var studip: StudIPSync

    var body: some View { Content(fileID: fileID, text: text, library: studip.recordings) }

    private struct Content: View {
        let fileID: String
        let text: () -> String
        @ObservedObject var library: RecordingLibrary
        @State private var match: OpencastMatch?
        @State private var dismissed = false
        @State private var playing: OpencastEntry?

        var body: some View {
            // VStack statt Group: an einer leeren Group liefe .task nie
            VStack(spacing: 0) {
                if let m = match, !dismissed {
                    HStack(spacing: 10) {
                        Image(systemName: "play.rectangle")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(m.entries.count == 1 ? "Passende Aufzeichnung" : "Passende Aufzeichnungen").font(.caption).bold()
                            Text(m.entries.count == 1 ? "\(m.entries[0].video.title) · \(m.reasonText)" : m.reasonText)
                                .font(.caption).lineLimit(1)
                        }
                        if m.entries.count == 1 {
                            Button("Abspielen") { playing = m.entries[0] }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                        } else {
                            Menu("Abspielen") {
                                ForEach(m.entries) { e in Button(e.video.title) { playing = e } }
                            }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                        }
                        Button { dismissed = true } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Hinweis ausblenden")
                    }
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.top, 8)
                }
            }
            .task(id: "\(fileID)-\(library.revision)") { match = await library.match(fileID: fileID, text: text()) }
            .fullScreenCover(item: $playing) { e in RecordingPlayerView(entry: e, library: library) }
        }
    }
}

/// Passende Aufzeichnungen zu den Aufgaben eines Lernpakets (nur bei sicherem Treffer, jedes Video einmal)
struct RecordingPackageHints: View {
    let packageID: Int
    @EnvironmentObject private var studip: StudIPSync

    var body: some View { Content(packageID: packageID, library: studip.recordings) }

    private struct Content: View {
        let packageID: Int
        @ObservedObject var library: RecordingLibrary
        @State private var matches: [OpencastTaskMatch] = []
        @State private var playing: OpencastEntry?

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                if !matches.isEmpty {
                    Text(matches.count == 1 && matches[0].match.entries.count == 1 ? "Passende Aufzeichnung" : "Passende Aufzeichnungen")
                        .ufFont(13.6, 650, em: -0.01).foregroundStyle(UF.text2).padding(.top, 12)
                    ForEach(matches) { m in
                        ForEach(m.match.entries) { e in
                            HStack(spacing: 9.6) {
                                UFIcon("play", size: 14).foregroundStyle(UF.accentText)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(e.video.title).ufFont(14.5, 550).foregroundStyle(UF.text).lineLimit(1)
                                    Text("Zu „\(m.taskTitle)“ · \(m.match.reasonText)").ufFont(12.48).foregroundStyle(UF.muted).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                UFButton("Abspielen", icon: "play", size: .small) { playing = e }
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
            }
            .task(id: "\(packageID)-\(library.revision)") { matches = await library.packageMatches(packageID: packageID) }
            .fullScreenCover(item: $playing) { e in RecordingPlayerView(entry: e, library: library) }
        }
    }
}

// MARK: - Player

/// Vollbild mit AVPlayerViewController (Streaming oder geladene Datei); Ersatzweg Stud.IP-Player-Seite.
struct RecordingPlayerView: View {
    let entry: OpencastEntry
    @ObservedObject var library: RecordingLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .loading
    @State private var player: AVPlayer?
    @State private var timeObserver: Any?
    @State private var statusObserver: NSKeyValueObservation?
    /// zuletzt gemerkte Stelle (Sekunden), damit nicht jede Sekunde geschrieben wird
    @State private var savedAt: Double = 0

    enum Mode: Equatable {
        case loading
        case player(local: Bool, quality: String)
        case web(URL, message: String?)
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9.6) {
                UFButton("Schließen", icon: "x", kind: .ghost, size: .small) { close() }
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.video.title).ufFont(14.5, 650).foregroundStyle(UF.text).lineLimit(1)
                    Text(subtitle).ufFont(12.16).foregroundStyle(UF.muted).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if case .player(_, let current) = mode, entry.video.media.count > 1 {
                    Menu {
                        ForEach(entry.video.media, id: \.quality) { d in
                            Button { switchQuality(d.quality) } label: {
                                let text = d.quality + (entry.localQuality == d.quality ? " · geladen" : "")
                                if d.quality == current { Label(text, systemImage: "checkmark") } else { Text(text) }
                            }
                        }
                    } label: {
                        Text(current).ufFont(12.8, 600).foregroundStyle(UF.accentText)
                            .padding(.vertical, 5.6).padding(.horizontal, 10.4)
                            .background(Capsule().fill(UF.accentSoft))
                    }
                    .accessibilityLabel("Qualität wählen")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(UF.surface)
            .ufBorderBottom()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black.ignoresSafeArea())
        .task { await start() }
        .onDisappear { stop() }
    }

    private var subtitle: String {
        switch mode {
        case .player(let local, let q): return "\(entry.courseTitle) · \(q) · \(local ? "geladen, offline" : "Stream")"
        case .web: return "\(entry.courseTitle) · Stud.IP-Player"
        default: return entry.courseTitle
        }
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .loading:
            ProgressView().tint(.white)
        case .player:
            if let player { UFAVPlayer(player: player).ignoresSafeArea(edges: .bottom) }
        case .web(let url, let message):
            VStack(spacing: 0) {
                if let message {
                    HStack(alignment: .top, spacing: 8) {
                        UFIcon("info", size: 15).padding(.top, 2)
                        Text(message).fixedSize(horizontal: false, vertical: true)
                    }
                    .ufFont(13.12).foregroundStyle(UF.text2)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(UF.infoSoft)
                }
                StudIPPlayerWebView(url: url)
            }
        case .failed(let message):
            VStack(spacing: 12) {
                UFIcon("alert", size: 36).foregroundStyle(.white.opacity(0.7))
                Text(message).ufFont(14.5).foregroundStyle(.white).multilineTextAlignment(.center)
                if let p = entry.video.playerURL {
                    UFButton("Über Stud.IP abspielen", icon: "play", kind: .primary) { mode = .web(p, message: nil) }
                }
            }
            .padding(24)
        }
    }

    private func start(preferred: String? = nil) async {
        stop()
        // neu lesen: geladene Datei und gemerkte Stelle koennen sich seit dem Oeffnen der Liste geaendert haben
        let current = await library.reload(entry) ?? entry
        switch RecordingPlayback.source(for: current.video, local: library.localFile(current), preferred: preferred) {
        case .local(let url, let q):
            play(url, local: true, quality: q, saved: current.position)
        case .stream(let url, let q):
            mode = .loading
            let probe = await library.probe(url)
            if probe.needsLogin {
                fallback("Der Videoserver verlangt eine Anmeldung (HTTP \(probe.status ?? 0)). Die Aufzeichnung läuft deshalb über die Stud.IP-Seite mit deiner Stud.IP-Sitzung.")
                return
            }
            // offline oder Server nicht erreichbar: klare Meldung statt der Stud.IP-Seite, die dann ebenfalls leer bliebe
            if let message = probe.playbackFailure {
                mode = .failed(message)
                return
            }
            play(url, local: false, quality: q, saved: current.position)
        case .webPlayer(let url):
            mode = .web(url, message: "Für diese Aufzeichnung gibt es keine direkte Videodatei; sie läuft über die Stud.IP-Seite.")
        case .unavailable:
            mode = .failed("Diese Aufzeichnung lässt sich nicht abspielen: Stud.IP nennt weder Videodatei noch Player-Seite.")
        }
    }

    private func play(_ url: URL, local: Bool, quality q: String, saved: Double?) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        let duration = entry.video.duration.map(Double.init)
        statusObserver = item.observe(\.status, options: [.new]) { item, _ in
            Task { @MainActor in
                switch item.status {
                case .readyToPlay:
                    if let s = RecordingPlayback.resumePosition(saved: saved, duration: duration ?? item.duration.seconds) {
                        _ = await p.seek(to: CMTime(seconds: s, preferredTimescale: 600))
                    }
                    p.play()
                case .failed:
                    if local { mode = .failed("Die geladene Datei lässt sich nicht abspielen. Entferne sie und lade sie neu.") }
                    else { fallback("Der Stream ließ sich nicht starten (\(item.error?.localizedDescription ?? "unbekannter Fehler")). Die Aufzeichnung läuft deshalb über die Stud.IP-Seite.") }
                default: break
                }
            }
        }
        let lib = library, e = entry
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) { t in
            let s = t.seconds
            guard s.isFinite, s > 0 else { return }
            Task { @MainActor in await lib.savePosition(e, seconds: s) }
        }
        player = p
        mode = .player(local: local, quality: q)
    }

    private func fallback(_ message: String) {
        stop()
        if let p = entry.video.playerURL { mode = .web(p, message: message) } else { mode = .failed(message) }
    }

    private func switchQuality(_ q: String) {
        if let p = player { let t = p.currentTime().seconds; Task { await library.savePosition(entry, seconds: t) } }
        Task { await start(preferred: q) }
    }

    private func stop() {
        if let p = player {
            let t = p.currentTime().seconds
            if t.isFinite, t > 0 { let lib = library, e = entry; Task { await lib.savePosition(e, seconds: t) } }
            p.pause()
            if let o = timeObserver { p.removeTimeObserver(o) }
        }
        timeObserver = nil
        statusObserver?.invalidate()
        statusObserver = nil
        player = nil
    }

    private func close() {
        stop()
        dismiss()
    }
}

/// AVPlayerViewController mit den Bedienelementen des Systems (ohne Teilen).
struct UFAVPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let c = AVPlayerViewController()
        c.player = player
        c.allowsPictureInPicturePlayback = true
        c.entersFullScreenWhenPlaybackBegins = false
        return c
    }

    func updateUIViewController(_ c: AVPlayerViewController, context: Context) {
        if c.player !== player { c.player = player }
    }
}

/// Stud.IP-Player-Seite mit der Stud.IP-Sitzung: fluechtiger Datenspeicher nur fuer diese Ansicht, darin die Cookies
/// aus dem Schluesselbund (nur fuer den Stud.IP-Host). Keine eigenen Skripte.
struct StudIPPlayerWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsLinkPreview = false
        let host = StudIPSync.base.host ?? ""
        let cookies = StudIPKeychain.load().filter { c in
            let d = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
            return host == d || host.hasSuffix("." + d)
        }
        let store = config.websiteDataStore.httpCookieStore
        let target = url
        Task { @MainActor in
            for c in cookies { await store.setCookie(c) }
            view.load(URLRequest(url: target))
        }
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

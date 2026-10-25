import AVKit
import SwiftUI
import UniFlowCore
import WebKit

// Opencast-Aufzeichnungen im UniFlow-Design: nach Lehrwoche gruppiert wie die Wochenbloecke im Moduldetail, je Video
// Vorschau, Titel, Laufzeit, Datum, Autor, "Abspielen" und "Laden". Abspielen im eigenen Player (lokale Datei vor
// Stream, 720p bevorzugt, Fortsetzen an der letzten Stelle); verlangt der Videoserver eine Anmeldung, zeigt die
// Stud.IP-Player-Seite das Video in einer Webansicht mit der vorhandenen Stud.IP-Sitzung. Videos gehoeren den
// Lehrenden: nur privat ansehen, kein Teilen.

// MARK: - Bereich "Aufzeichnungen"

/// Inhalt des Reiters "Aufzeichnungen": Hinweis zur Stud.IP-Verbindung, leerer Zustand oder die Wochenbloecke.
struct RecordingsPanel: View {
    let entries: [RecordingEntry]
    let semesterStart: Date?
    /// Beschriftung der Wochen aus dem Moduldetail ("Woche 3 · 26.10. – 01.11.")
    var weekLabels: [Int: String] = [:]
    /// Woche, zu der gesprungen wurde (hervorgehoben)
    var focusWeek: Int?
    @EnvironmentObject private var studip: StudIPSync

    var body: some View {
        let link = StudIPLink(studip.phase, hasSession: !StudIPKeychain.load().isEmpty)
        VStack(alignment: .leading, spacing: 0) {
            if link != .connected {
                RecordingsConnectCard(expired: link == .expired).padding(.bottom, 14.4)
            }
            if entries.isEmpty {
                if link == .connected {
                    UFCard {
                        if studip.recordings.courses.isEmpty {
                            UFEmpty(icon: "play", text: studip.isRunning ? "Aufzeichnungen werden beim laufenden Abgleich geprüft …"
                                                                          : "Aufzeichnungen erscheinen nach dem nächsten Stud.IP-Abgleich.") {
                                if !studip.isRunning {
                                    UFButton("Jetzt abgleichen", icon: "sync", size: .small) { Task { await studip.run() } }
                                }
                            }
                        } else {
                            UFEmpty(icon: "play", text: "Keine Aufzeichnungen zu diesem Modul.")
                        }
                    }
                }
            } else {
                RecordingWeekBlocks(entries: entries, semesterStart: semesterStart, weekLabels: weekLabels, focusWeek: focusWeek)
                Text("Aufzeichnungen gehören den Lehrenden: nur zum privaten Ansehen, nicht weitergeben.")
                    .ufFont(12.16).foregroundStyle(UF.muted)
                    .padding(.top, 4)
            }
        }
    }
}

/// "Stud.IP verbinden, um Aufzeichnungen zu sehen" mit dem vorhandenen Weg zur echten Anmeldung
struct RecordingsConnectCard: View {
    let expired: Bool
    @EnvironmentObject private var studip: StudIPSync
    @State private var showLogin = false

    var body: some View {
        UFCard {
            UFCardHead(expired ? "Stud.IP-Anmeldung abgelaufen" : "Stud.IP verbinden, um Aufzeichnungen zu sehen", icon: "play")
            Text(expired ? "Melde dich erneut an, damit UniFlow die Aufzeichnungen deiner Kurse aktualisiert."
                         : "UniFlow liest die Aufzeichnungen (Opencast) deiner Kurse aus Stud.IP und ordnet sie nach Fach und Vorlesungswoche.")
                .ufFont(14.5).foregroundStyle(UF.text2)
                .fixedSize(horizontal: false, vertical: true)
            UFButton(expired ? "Erneut anmelden" : "Stud.IP verbinden", icon: "arrow-right", kind: .primary) { showLogin = true }
                .padding(.top, 12.8)
        }
        .sheet(isPresented: $showLogin) {
            StudIPLoginView(base: StudIPSync.base) { cookies in
                showLogin = false
                studip.signedIn(cookies: cookies)
            }
        }
    }
}

/// Wochenbloecke (.card.week-block) mit den Videos; "Ohne Woche" zuletzt.
struct RecordingWeekBlocks: View {
    let entries: [RecordingEntry]
    let semesterStart: Date?
    var weekLabels: [Int: String] = [:]
    var focusWeek: Int?
    @State private var playing: RecordingEntry?
    @State private var collapsed: Set<String> = []
    @EnvironmentObject private var library: RecordingLibrary

    var body: some View {
        let groups = RecordingWeeks.grouped(entries).map { WeekGroup(week: $0.week, entries: $0.entries) }
        let manyCourses = Set(entries.map(\.courseID)).count > 1
        VStack(alignment: .leading, spacing: 0) {
            ForEach(groups) { g in
                let key = g.id
                let open = !collapsed.contains(key)
                UFCard {
                    HStack(spacing: 9.6) {
                        UFIcon("chevron-down", size: 16).foregroundStyle(UF.text).rotationEffect(.degrees(open ? 0 : -90))
                        Text(title(g.week)).ufFont(15.2, 650, em: -0.01).foregroundStyle(UF.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(Self.count(g.entries.count)).ufFont(12.8).foregroundStyle(UF.muted)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .onTapGesture { if open { collapsed.insert(key) } else { collapsed.remove(key) } }
                    if open {
                        VStack(spacing: 0) {
                            ForEach(g.entries) { e in
                                RecordingRow(entry: e, showCourse: manyCourses) { playing = e }
                            }
                        }
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(UF.accent, lineWidth: focusWeek != nil && focusWeek == g.week ? 2 : 0))
                .id("rec-week-\(key)")
                .padding(.bottom, 14.4)
            }
        }
        .fullScreenCover(item: $playing) { e in
            RecordingPlayerView(entry: e).environmentObject(library)
        }
    }

    private func title(_ week: Int?) -> String {
        guard let w = week else { return "Ohne Woche" }
        return weekLabels[w] ?? LectureWeek.label(w, semesterStart: semesterStart)
    }

    static func count(_ n: Int) -> String { n == 1 ? "1 Aufzeichnung" : "\(n) Aufzeichnungen" }

    struct WeekGroup: Identifiable {
        let week: Int?
        let entries: [RecordingEntry]
        var id: String { week.map { "w\($0)" } ?? "none" }
    }
}

// MARK: - Zeile

struct RecordingRow: View {
    let entry: RecordingEntry
    var showCourse = false
    let play: () -> Void

    var body: some View {
        let v = entry.video
        let meta = [RecordingFormat.duration(v.duration), v.created.map(RecordingFormat.date), v.author].compactMap { $0 }
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12.8) {
                RecordingThumbnail(url: v.thumbnailURL, action: play)
                info(meta).frame(maxWidth: .infinity, alignment: .leading)
                actions.fixedSize()
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12.8) {
                    RecordingThumbnail(url: v.thumbnailURL, action: play)
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
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            UFButton("Abspielen", icon: "play", kind: .primary, size: .small, action: play)
            RecordingDownloadControl(entry: entry)
        }
    }
}

struct RecordingThumbnail: View {
    let url: URL?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: UF.rSm).fill(UF.surface2)
                if let url {
                    AsyncImage(url: url) { phase in
                        if let img = phase.image { img.resizable().scaledToFill() } else { Color.clear }
                    }
                }
                Circle().fill(.black.opacity(0.45)).frame(width: 30, height: 30)
                    .overlay(UFIcon("play", size: 14).foregroundStyle(.white))
            }
            .frame(width: 128, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: UF.rSm))
            .overlay(RoundedRectangle(cornerRadius: UF.rSm).strokeBorder(UF.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Abspielen")
    }
}

enum RecordingFormat {
    /// "1:28 h", "36 min"
    static func duration(_ seconds: Int?) -> String? {
        guard let s = seconds, s > 0 else { return nil }
        if s >= 3600 { return String(format: "%d:%02d h", s / 3600, (s % 3600) / 60) }
        return "\(max(1, Int((Double(s) / 60).rounded()))) min"
    }

    static func date(_ d: Date) -> String {
        let c = LectureWeek.calendar.dateComponents([.day, .month, .year], from: d)
        return String(format: "%02d.%02d.%04d", c.day ?? 0, c.month ?? 0, c.year ?? 0)
    }
}

// MARK: - Laden

/// "Laden (… MB)" / Fortschritt mit "Abbrechen" / "Fortsetzen" / "Geladen ✓" mit "Entfernen". Nur auf Wunsch.
struct RecordingDownloadControl: View {
    let entry: RecordingEntry
    @EnvironmentObject private var library: RecordingLibrary
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter

    var body: some View {
        let course = entry.courseID, video = entry.video.id
        let have = library.qualities(course: course, video: video)
        if let q = have.sorted().first {
            HStack(spacing: 6) {
                UFBadge("Geladen ✓", tone: .ok)
                UFButton("Entfernen", icon: "trash", kind: .ghost, size: .small) {
                    for q in have { library.remove(course: course, video: video, quality: q) }
                }
                .help(q)
            }
        } else if let d = RecordingPlayback.quality(for: entry.video) {
            let state = library.state(course: course, video: video, quality: d.quality)
            switch state {
            case .running(let f)?:
                HStack(spacing: 8) {
                    UFProgress(value: f ?? 0).frame(width: 90)
                    Text(f.map { "\(Int(($0 * 100).rounded())) %" } ?? "…").ufFont(12.48).foregroundStyle(UF.muted).frame(minWidth: 34)
                    UFButton("Abbrechen", icon: "x", kind: .ghost, size: .small) { library.cancel(course: course, video: video, quality: d.quality) }
                }
            case .failed(let message)?:
                HStack(spacing: 6) {
                    Text(message).ufFont(12.48).foregroundStyle(UF.bad).lineLimit(2).frame(maxWidth: 220, alignment: .leading)
                    UFButton(resumable(d) ? "Fortsetzen" : "Erneut", icon: "refresh", size: .small) { Task { await load(d) } }
                }
            default:
                if resumable(d) || state == .paused {
                    HStack(spacing: 6) {
                        UFButton("Fortsetzen", icon: "download", size: .small) { Task { await load(d) } }
                        UFButton("Verwerfen", icon: "trash", kind: .ghost, size: .small) { library.remove(course: course, video: video, quality: d.quality) }
                    }
                } else {
                    UFButton(library.size(d.url).map { "Laden (\(RecordingFormatBytes.text($0)))" } ?? "Laden", icon: "download", size: .small) {
                        Task { await load(d) }
                    }
                    .contextMenu {
                        ForEach(entry.video.downloads, id: \.quality) { other in
                            Button("\(other.quality) laden") { Task { await load(other) } }
                        }
                    }
                    .onAppear { library.requestSize(d.url) }
                }
            }
        }
    }

    private func resumable(_ d: OpencastDownload) -> Bool {
        library.resumable.contains(RecordingLibrary.key(course: entry.courseID, video: entry.video.id, quality: d.quality))
    }

    /// Groesse vorher zeigen, bei wenig Platz warnen, dann laden
    private func load(_ d: OpencastDownload) async {
        let probe = await library.probe(d.url)
        if probe.needsLogin {
            toast.show("Der Videoserver verlangt eine Anmeldung – laden ist nicht möglich, abspielen geht über Stud.IP.")
            return
        }
        let free = library.freeBytes()
        if let size = probe.size, let free, size >= free {
            toast.show(RecordingFilesLayout.storageWarning(fileSize: size, freeBytes: free) ?? "Nicht genug Speicherplatz.")
            return
        }
        var question = "„\(entry.video.title)“ in \(d.quality) laden\(probe.size.map { " (\(RecordingFormatBytes.text($0)))" } ?? "")? Nur zum privaten Ansehen auf diesem iPad."
        if let w = RecordingFilesLayout.storageWarning(fileSize: probe.size, freeBytes: free) { question = w + " " + question }
        guard await overlay.confirm(question) else { return }
        library.start(course: entry.courseID, video: entry.video.id, download: d)
    }
}

enum RecordingFormatBytes {
    static func text(_ bytes: Int64) -> String { RecordingFilesLayout.megabytes(bytes) }
}

// MARK: - Player

/// Vollbild-Blatt mit AVPlayerViewController; Ersatzweg Stud.IP-Player-Seite in der Webansicht.
struct RecordingPlayerView: View {
    let entry: RecordingEntry
    @EnvironmentObject private var library: RecordingLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .loading
    @State private var quality: String?
    @State private var player: AVPlayer?
    @State private var timeObserver: Any?
    @State private var statusObserver: NSKeyValueObservation?

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
                if case .player = mode, entry.video.downloads.count > 1 {
                    Menu {
                        ForEach(entry.video.downloads, id: \.quality) { d in
                            Button { switchQuality(d.quality) } label: {
                                if d.quality == currentQuality { Label(d.quality, systemImage: "checkmark") } else { Text(d.quality) }
                            }
                        }
                    } label: {
                        Text(currentQuality ?? "Qualität").ufFont(12.8, 600).foregroundStyle(UF.accentText)
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

    private var currentQuality: String? { if case .player(_, let q) = mode { return q }; return quality }

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
        let v = entry.video
        switch RecordingPlayback.source(for: v, downloaded: library.qualities(course: entry.courseID, video: v.id), preferred: preferred) {
        case .local(let q):
            play(library.fileURL(course: entry.courseID, video: v.id, quality: q), local: true, quality: q)
        case .stream(let url, let q):
            mode = .loading
            let probe = await library.probe(url)
            if probe.needsLogin {
                fallback("Der Videoserver verlangt eine Anmeldung (HTTP \(probe.status ?? 0)). Die Aufzeichnung läuft deshalb über die Stud.IP-Seite mit deiner Stud.IP-Sitzung.")
                return
            }
            play(url, local: false, quality: q)
        case .webPlayer(let url):
            mode = .web(url, message: "Für diese Aufzeichnung gibt es keine direkte Videodatei; sie läuft über die Stud.IP-Seite.")
        case .unavailable:
            mode = .failed("Diese Aufzeichnung lässt sich nicht abspielen: Stud.IP nennt weder Videodatei noch Player-Seite.")
        }
    }

    private func play(_ url: URL, local: Bool, quality q: String) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        let id = entry.video.id
        let lib = library
        let duration = entry.video.duration.map(Double.init)
        statusObserver = item.observe(\.status, options: [.new]) { item, _ in
            Task { @MainActor in
                switch item.status {
                case .readyToPlay:
                    if let s = RecordingPlayback.resumePosition(saved: lib.position(video: id), duration: duration ?? item.duration.seconds) {
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
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 1), queue: .main) { t in
            MainActor.assumeIsolated { lib.savePosition(t.seconds, video: id) }
        }
        player = p
        quality = q
        mode = .player(local: local, quality: q)
    }

    private func fallback(_ message: String) {
        stop()
        if let p = entry.video.playerURL { mode = .web(p, message: message) } else { mode = .failed(message) }
    }

    private func switchQuality(_ q: String) {
        if let p = player { library.savePosition(p.currentTime().seconds, video: entry.video.id) }
        Task { await start(preferred: q) }
    }

    private func stop() {
        if let p = player {
            let t = p.currentTime().seconds
            if t > 0 { library.savePosition(t, video: entry.video.id) }
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

/// Stud.IP-Player-Seite mit der vorhandenen Sitzung: derselbe Datenspeicher wie die Anmeldung, dazu die Cookies aus
/// dem Schluesselbund (nur fuer den Stud.IP-Host). Keine eigenen Skripte.
struct StudIPPlayerWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
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

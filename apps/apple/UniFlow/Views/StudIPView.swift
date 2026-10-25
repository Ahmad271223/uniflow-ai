import QuickLook
import SwiftUI
import UniFlowCore
import WebKit

/// Stud.IP direkt auf dem iPad: Anmeldung, Kursauswahl, Abgleich, heruntergeladene Dateien. Im UniFlow-Design
/// (Karten, Knoepfe, Icons wie die uebrigen Seiten), weil die leeren Zustaende ohne Server hierher fuehren.
struct StudIPView: View {
    @EnvironmentObject private var studip: StudIPSync
    @EnvironmentObject private var library: RecordingLibrary
    @State private var showLogin = false
    @State private var preview: URL?
    @State private var confirmSignOut = false

    var body: some View {
        UFContent(maxWidth: 860) {
            UFPageHead("Stud.IP", sub: "Stud.IP der Leibniz Universität Hannover")
            VStack(alignment: .leading, spacing: 16) {
                accountCard
                if !studip.courses.isEmpty { coursesCard }
                if !orphanRecordings.isEmpty { orphanRecordingsCard(orphanRecordings) }
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(groups) { g in groupCard(g) }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .quickLookPreview($preview)
        .sheet(isPresented: $showLogin) {
            StudIPLoginView(base: StudIPSync.base) { cookies in
                showLogin = false
                studip.signedIn(cookies: cookies)
            }
        }
        .confirmationDialog("Von Stud.IP abmelden?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Abmelden", role: .destructive) { Task { @MainActor in await studip.signOut() } }
            Button("Abmelden und Dateien löschen", role: .destructive) { Task { @MainActor in await studip.signOut(); await studip.removeDownloads() } }
        } message: {
            Text("Das Sitzungs-Cookie und die Anmeldung in der Webansicht werden gelöscht.")
        }
    }

    // MARK: Konto und Abgleich

    private var accountCard: some View {
        UFCard {
            UFCardHead("Verbindung", icon: "graduation") { badge }
            status
            UFFlexWrap(gap: 9.6) {
                if studip.phase == .signedOut || studip.phase == .needsLogin {
                    UFButton("Bei Stud.IP anmelden", icon: "arrow-right", kind: .primary) { showLogin = true }
                } else {
                    UFButton("Jetzt abgleichen", icon: "sync", kind: .primary) { Task { @MainActor in await studip.run() } }
                        .disabled(studip.isRunning)
                    UFButton("Abmelden", icon: "log-out", kind: .danger) { confirmSignOut = true }
                        .disabled(studip.isRunning)
                }
            }
            .padding(.top, 12.8)
            Text("Du meldest dich auf der Seite der Universität an. UniFlow liest keine Eingaben aus dieser Seite und speichert nur das Sitzungs-Cookie im Schlüsselbund dieses iPads. Dateien werden nur auf diesem Gerät gespeichert und nicht weitergegeben. Abgleich beim Öffnen der App (höchstens alle 30 Minuten) und auf Knopfdruck.")
                .ufFont(13.12).foregroundStyle(UF.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12.8)
        }
    }

    @ViewBuilder private var badge: some View {
        switch studip.phase {
        case .signedOut: UFBadge("nicht angemeldet", tone: .neutral)
        case .needsLogin: UFBadge("Anmeldung abgelaufen", tone: .warn, icon: "alert")
        case .running: UFBadge("gleicht ab", tone: .info, icon: "sync")
        case .failed: UFBadge("Fehler", tone: .bad, icon: "alert")
        case .idle: UFBadge("verbunden", tone: .ok, icon: "check")
        }
    }

    @ViewBuilder private var status: some View {
        switch studip.phase {
        case .signedOut:
            Text("Nicht angemeldet.").ufFont(14.5).foregroundStyle(UF.text2)
        case .needsLogin:
            Text("Die Anmeldung ist abgelaufen – bitte neu anmelden.").ufFont(14.5).foregroundStyle(UF.warn)
        case .running(let text):
            HStack(spacing: 9.6) {
                ProgressView().tint(UF.accent)
                Text(text).ufFont(14.5).foregroundStyle(UF.text2).lineLimit(2)
            }
        case .failed(let message):
            HStack(alignment: .top, spacing: 6) {
                UFIcon("alert", size: 16).padding(.top, 2)
                Text(message).fixedSize(horizontal: false, vertical: true)
            }
            .ufFont(14.5).foregroundStyle(UF.bad)
        case .idle:
            if let last = studip.lastRun {
                VStack(alignment: .leading, spacing: 2.4) {
                    Text("Zuletzt abgeglichen: \(last.formatted(date: .abbreviated, time: .shortened))")
                        .ufFont(14.5).foregroundStyle(UF.text2)
                    if let s = studip.lastSummary { Text(s).ufFont(13.12).foregroundStyle(UF.muted) }
                }
            } else {
                Text("Angemeldet.").ufFont(14.5).foregroundStyle(UF.text2)
            }
        }
    }

    // MARK: Aufzeichnungen ohne Eintrag

    /// erst nach einem Abgleich: sonst waere jede Datei "ohne Eintrag", nur weil der Index noch fehlt
    private var orphanRecordings: [RecordingStoredFile] {
        studip.lastRun == nil ? [] : library.orphans(in: studip.recordings)
    }

    /// Geladene Aufzeichnungen abgewaehlter Kurse oder aus Opencast entfernter Videos: sonst nirgends sichtbar
    private func orphanRecordingsCard(_ files: [RecordingStoredFile]) -> some View {
        UFCard {
            UFCardHead("Aufzeichnungen ohne Eintrag", icon: "play") {
                UFBadge(RecordingFilesLayout.megabytes(library.bytes(files)), tone: .neutral)
            }
            Text("\(files.count == 1 ? "Eine geladene Datei gehört" : "\(files.count) geladene Dateien gehören") zu abgewählten Kursen oder zu Aufzeichnungen, die es in Stud.IP nicht mehr gibt.")
                .ufFont(14.5).foregroundStyle(UF.text2)
                .fixedSize(horizontal: false, vertical: true)
            UFButton("Entfernen", icon: "trash", kind: .danger) { library.removeOrphans(in: studip.recordings) }
                .padding(.top, 12.8)
        }
    }

    // MARK: Kurse

    private var coursesCard: some View {
        UFCard {
            UFCardHead("Kurse", icon: "book") { UFBadge("\(studip.selectedCourses.count) von \(studip.courses.count)", tone: .neutral) }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(studip.courses, id: \.id) { c in
                    CourseRow(title: c.title, semester: c.semesterTitle, isOn: Binding(
                        get: { studip.selectedCourses.contains(c.id) },
                        set: { on in if on { studip.selectedCourses.insert(c.id) } else { studip.selectedCourses.remove(c.id) } }))
                        .disabled(studip.isRunning)
                }
            }
            Text("Beim ersten Abgleich sind die Kurse des aktuellen Semesters ausgewählt.")
                .ufFont(13.12).foregroundStyle(UF.muted).padding(.top, 8)
        }
    }

    /// Kurs mit Haken (wie .check im Web): Kaestchen in --accent, Titel und Semester
    private struct CourseRow: View {
        let title: String
        let semester: String?
        @Binding var isOn: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            Button { isOn.toggle() } label: {
                HStack(alignment: .top, spacing: 9.6) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4).fill(isOn ? UF.accent : UF.surface)
                        RoundedRectangle(cornerRadius: 4).strokeBorder(isOn ? UF.accent : UF.lineStrong, lineWidth: 1)
                        if isOn { UFIcon("check", size: 12).foregroundStyle(.white) }
                    }
                    .frame(width: 18, height: 18)
                    .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title).ufFont(14.5, 550).foregroundStyle(UF.text).multilineTextAlignment(.leading)
                        if let semester { Text(semester).ufFont(12.8).foregroundStyle(UF.muted) }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 7.2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isEnabled ? 1 : 0.55)
            .accessibilityAddTraits(isOn ? .isSelected : [])
        }
    }

    // MARK: Dateien

    private struct EntryGroup: Identifiable {
        let id: String
        let entries: [StudIPLocalEntry]
    }

    private var groups: [EntryGroup] {
        let byCourse = Dictionary(grouping: studip.entries, by: { $0.courseTitle })
        return byCourse.keys.sorted().map { EntryGroup(id: $0, entries: byCourse[$0] ?? []) }
    }

    private func groupCard(_ g: EntryGroup) -> some View {
        UFCard {
            UFCardHead(g.id, icon: "folder") { UFBadge("\(g.entries.count)", tone: .neutral) }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(g.entries, id: \.id) { e in
                    Button { preview = studip.fileURL(e) } label: {
                        UFItemRow(e.name, sub: e.folderPath.isEmpty ? nil : e.folderPath) {
                            UFIcon(e.mimeType == "application/pdf" || e.name.lowercased().hasSuffix(".pdf") ? "file-text" : "file", size: 18)
                                .foregroundStyle(UF.muted)
                        } trailing: {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(e.size), countStyle: .file))
                                .ufFont(12.8).foregroundStyle(UF.muted)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Anmeldung auf der echten Stud.IP-Seite. Sobald Stud.IP die Sitzung bestaetigt (users/me), werden die Cookies
/// an `onSignedIn` uebergeben. Keine eingeschleusten Skripte, kein Zugriff auf Formularfelder.
struct StudIPLoginView: View {
    let base: URL
    let onSignedIn: ([HTTPCookie]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var checking = false
    @State private var done = false

    var body: some View {
        NavigationStack {
            StudIPWebView(url: base.appendingPathComponent("dispatch.php/login")) { webView in check(webView) }
                .navigationTitle("Stud.IP-Anmeldung")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                    if checking { ToolbarItem(placement: .confirmationAction) { ProgressView() } }
                }
        }
    }

    /// Nach jedem geladenen Stud.IP-Seitenaufruf ausserhalb der Anmeldeseite pruefen, ob die Sitzung gilt.
    private func check(_ webView: WKWebView) {
        guard !done, !checking, let url = webView.url, url.host == base.host, !url.path.contains("/dispatch.php/login") else { return }
        checking = true
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let host = base.host ?? ""
            let mine = cookies.filter { host.hasSuffix($0.domain.hasPrefix(".") ? String($0.domain.dropFirst()) : $0.domain) }
            Task { @MainActor in
                let ok = await StudIPSync.sessionIsValid(mine)
                checking = false
                if ok, !done { done = true; onSignedIn(mine) }
            }
        }
    }
}

/// Eingebettete Webansicht ohne eigene Skripte. Eigener, dauerhafter Datenspeicher der App (nicht Safari):
/// die Hochschul-Anmeldung bleibt erhalten, sodass eine erneute Anmeldung oft ohne Passwort gelingt.
struct StudIPWebView: UIViewRepresentable {
    let url: URL
    let onPageLoaded: (WKWebView) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPageLoaded: onPageLoaded) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onPageLoaded: (WKWebView) -> Void
        init(onPageLoaded: @escaping (WKWebView) -> Void) { self.onPageLoaded = onPageLoaded }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onPageLoaded(webView) }
    }
}

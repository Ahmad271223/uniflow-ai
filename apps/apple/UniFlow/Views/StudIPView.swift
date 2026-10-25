import QuickLook
import SwiftUI
import UniFlowCore
import WebKit

/// Stud.IP direkt auf dem iPad: Anmeldung, Kursauswahl, Abgleich, heruntergeladene Dateien.
struct StudIPView: View {
    @EnvironmentObject private var studip: StudIPSync
    @State private var showLogin = false
    @State private var preview: URL?
    @State private var confirmSignOut = false

    var body: some View {
        List {
            Section {
                status
                if studip.phase == .signedOut || studip.phase == .needsLogin {
                    Button { showLogin = true } label: { Label("Bei Stud.IP anmelden", systemImage: "person.badge.key") }
                } else {
                    Button { Task { @MainActor in await studip.run() } } label: { Label("Jetzt abgleichen", systemImage: "arrow.triangle.2.circlepath") }
                        .disabled(studip.isRunning)
                    Button("Abmelden", role: .destructive) { confirmSignOut = true }
                        .disabled(studip.isRunning)
                }
            } header: {
                Text("Stud.IP der Leibniz Universität Hannover")
            } footer: {
                Text("Du meldest dich auf der Seite der Universität an. UniFlow liest keine Eingaben aus dieser Seite und speichert nur das Sitzungs-Cookie im Schlüsselbund dieses iPads. Dateien werden nur auf diesem Gerät gespeichert und nicht weitergegeben. Abgleich beim Öffnen der App (höchstens alle 30 Minuten) und auf Knopfdruck.")
            }

            if !studip.courses.isEmpty {
                Section {
                    ForEach(studip.courses, id: \.id) { c in
                        Toggle(isOn: Binding(get: { studip.selectedCourses.contains(c.id) },
                                             set: { on in if on { studip.selectedCourses.insert(c.id) } else { studip.selectedCourses.remove(c.id) } })) {
                            VStack(alignment: .leading) {
                                Text(c.title)
                                if let s = c.semesterTitle { Text(s).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        .disabled(studip.isRunning)
                    }
                } header: { Text("Kurse") } footer: {
                    Text("Beim ersten Abgleich sind die Kurse des aktuellen Semesters ausgewählt.")
                }
            }

            ForEach(groups) { g in
                Section(g.id) {
                    ForEach(g.entries, id: \.id) { e in
                        Button { preview = studip.fileURL(e) } label: {
                            HStack {
                                Image(systemName: e.mimeType == "application/pdf" || e.name.lowercased().hasSuffix(".pdf") ? "doc.richtext" : "doc")
                                VStack(alignment: .leading) {
                                    Text(e.name).lineLimit(2)
                                    if !e.folderPath.isEmpty { Text(e.folderPath).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: Int64(e.size), countStyle: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Stud.IP")
        .quickLookPreview($preview)
        .sheet(isPresented: $showLogin) {
            StudIPLoginView(base: StudIPSync.base) { cookies in
                showLogin = false
                studip.signedIn(cookies: cookies)
            }
        }
        .confirmationDialog("Von Stud.IP abmelden?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Abmelden", role: .destructive) { Task { @MainActor in await studip.signOut() } }
            Button("Abmelden und Dateien löschen", role: .destructive) { Task { @MainActor in await studip.signOut(); studip.removeDownloads() } }
        } message: {
            Text("Das Sitzungs-Cookie und die Anmeldung in der Webansicht werden gelöscht.")
        }
    }

    private struct EntryGroup: Identifiable {
        let id: String
        let entries: [StudIPLocalEntry]
    }

    private var groups: [EntryGroup] {
        let byCourse = Dictionary(grouping: studip.entries, by: { $0.courseTitle })
        return byCourse.keys.sorted().map { EntryGroup(id: "\($0) (\(byCourse[$0]?.count ?? 0))", entries: byCourse[$0] ?? []) }
    }

    @ViewBuilder private var status: some View {
        switch studip.phase {
        case .signedOut:
            Label("Nicht angemeldet", systemImage: "person.crop.circle.badge.questionmark")
        case .needsLogin:
            Label("Anmeldung abgelaufen – bitte neu anmelden", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .running(let text):
            HStack { ProgressView(); Text(text).font(.callout) }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        case .idle:
            if let last = studip.lastRun {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Zuletzt abgeglichen: \(last.formatted(date: .abbreviated, time: .shortened))")
                    if let s = studip.lastSummary { Text(s).font(.caption).foregroundStyle(.secondary) }
                }
            } else {
                Label("Angemeldet", systemImage: "checkmark.circle")
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

import SwiftUI
import UniFlowCore
import WebKit

// Seite "Bescheinigungen" unter Uni & Noten (06.11.2026, docs/BESCHEINIGUNGEN-2026-11-06.md), wie #/bescheinigungen in
// app/static/certificates.js: alle Dokumente, die das Portal anbietet (Immatrikulations-/Studienbescheinigung, § 9 BAföG,
// Datenkontrollblatt, Notenspiegel als PDF, Rueckmeldebescheinigung, Bescheide ...), gruppiert nach Art; je Dokument
// "Herunterladen" bzw. "Öffnen" und "Neu laden" mit Datum der gespeicherten Kopie ("Stand"), Teilen/Sichern in Dateien
// aus der Vorschau, Semesterwahl, wo das Portal eine anbietet. Arten, die das Portal nicht anbietet, stehen ehrlich
// darunter. Abgelaufene Sitzung: "Anmeldung nötig" mit dem Anmeldefenster des Portals.

struct CertificatesPage: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var shell: ShellState
    @EnvironmentObject private var router: UFRouter
    @Environment(\.qis) private var qis
    @Environment(\.hsh) private var hsh
    @Environment(\.hildesheim) private var hildesheim
    @State private var data: JSONValue?
    @State private var error: String?
    @State private var center: CertificateCenter?
    @State private var preview: CertificatePreview?
    @State private var semesters: [String: String] = [:]
    @State private var login = false
    @State private var autoChecked = false

    private var isLocal: Bool { session.api?.isLocal == true }

    var body: some View {
        Group {
            if let data { content(data) }
            else if let error { UFContent(maxWidth: 960) { UFEmpty(icon: "alert", text: error) } }
            else { UFContent(maxWidth: 960) { UFSkeleton().frame(width: 280, height: 28).padding(.bottom, 16); UFSkeleton().frame(height: 260) } }
        }
        .task {
            if center == nil, isLocal { center = CertificateCenter.make(qis: qis, hsh: hsh, hildesheim: hildesheim) }
            await load()
            await refreshIfStale()
        }
        .ufReload { await load() }
        .onChange(of: center?.finished) { _, _ in Task { await load() } }
        .sheet(item: $preview) { p in CertificatePreviewSheet(preview: p, reload: p.offerID.map { id in { await download(id, show: true) } }) }
        .sheet(isPresented: $login) { loginSheet }
        .accessibilityIdentifier("certificates.page")
    }

    private func load() async {
        guard let api = session.api else { error = "Nicht mit dem Server verbunden."; return }
        do {
            data = try await api.value("/api/certificates")
            error = nil
        } catch { if data == nil { self.error = error.localizedDescription } }
    }

    /// Beim Oeffnen: Liste lesen, wenn nie gelesen oder aelter als 7 Tage (nur Links, erzeugt nichts). Abgelaufene
    /// Anmeldung: erst still mit dem gemerkten Passwort (falls zugelassen), sonst "Anmeldung nötig"
    private func refreshIfStale() async {
        guard !autoChecked, let center, let data else { return }
        autoChecked = true
        if !center.isConnected, !(await center.silentLogin()) { center.needsLogin = true; return }
        if center.shouldRefresh(status: data.s("status"), checkedAt: data.s("checked_at")) { await center.refresh() }
    }

    // MARK: Inhalt

    @ViewBuilder private func content(_ d: JSONValue) -> some View {
        let offers = d.list("offers")
        let portal = d.s("portal") ?? "Portal"
        UFContent(maxWidth: 960) {
            UFPageHead("Bescheinigungen", sub: "Alles, was \(portal) an Bescheinigungen anbietet. StudiNow lädt eine PDF nur, wenn du tippst, und speichert sie mit Datum auf diesem iPad.") {
                UFButton("Uni & Noten", icon: "graduation", size: .small) { router.go(.services) }
            }
            statusCard(d, portal: portal)
            if offers.isEmpty {
                UFCard {
                    UFEmpty(icon: "file-text", text: Self.emptyText(status: d.s("status"), portal: portal), small: true)
                        .accessibilityIdentifier("certificates.empty")
                }
                .padding(.bottom, 16)
            }
            ForEach(Self.groups(offers), id: \.kind) { g in
                UFCard {
                    UFCardHead(g.label, icon: g.kind == "notenspiegel" ? "exam" : "file-text")
                    VStack(spacing: 0) {
                        ForEach(g.offers.indices, id: \.self) { i in
                            offerRow(g.offers[i]).ufBorderBottom(i < g.offers.count - 1)
                        }
                    }
                }
                .padding(.bottom, 16)
                .accessibilityIdentifier("certificates.kind.\(g.kind)")
            }
            missingCard(d)
            legacyCard(d)
            Text(d.s("note") ?? "")
                .ufFont(11.84).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4).padding(.bottom, 12)
        }
    }

    /// Stand der Liste, "Liste aktualisieren", "Anmeldung nötig"
    private func statusCard(_ d: JSONValue, portal: String) -> some View {
        let status = d.s("status") ?? "never"
        let loginNeeded = status == "login" || center?.needsLogin == true
        return UFCard {
            UFCardHead("Aus \(portal)", icon: "graduation", wrap: true) {
                if loginNeeded, center != nil {
                    UFButton("Anmeldung nötig", icon: "arrow-right", kind: .primary, size: .small) { login = true }
                        .fixedSize()
                        .accessibilityIdentifier("certificates.login")
                }
                UFButton(center?.busy == "list" ? "Wird gelesen …" : "Liste aktualisieren", icon: "sync", size: .small) {
                    Task { await refreshList() }
                }
                .fixedSize()
                .disabled(center?.busy != nil || (center?.portalBusy ?? false))
                .accessibilityIdentifier("certificates.refresh")
            }
            HStack(spacing: 8) {
                if loginNeeded {
                    UFBadge("Anmeldung nötig", tone: .warn)
                } else if status == "error" {
                    UFBadge("Fehler", tone: .bad)
                } else if let c = d.s("checked_at") {
                    UFBadge("Liste vom \(Self.stand(c))", tone: .neutral)
                }
                Text(center?.message ?? d.s("message") ?? "").ufFont(13.12).foregroundStyle(UF.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if loginNeeded {
                Text("Deine Sitzung bei \(portal) ist abgelaufen oder noch nicht da. Melde dich im Fenster selbst an; StudiNow speichert kein Passwort.")
                    .ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }
        }
        .padding(.bottom, 16)
    }

    private func offerRow(_ o: JSONValue) -> some View {
        let id = o.s("id") ?? ""
        let file = o["file"].flatMap { $0.isNull ? nil : $0 }
        let options = o.list("semesters").map { (value: $0.s("value") ?? "", label: $0.s("label") ?? "") }
        let busy = center?.busy == id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                UFIcon("file-text", size: 16).foregroundStyle(UF.accentText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(o.s("title") ?? "").ufFont(14.5, 650).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                    Text(Self.subline(o)).ufFont(12.16).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            UFFlexWrap(gap: 8) {
                if !options.isEmpty {
                    UFSelect(options: options, selection: Binding(get: { semesters[id] ?? options.first?.value ?? "" },
                                                                   set: { semesters[id] = $0 }))
                        .accessibilityLabel("Semester")
                }
                if file != nil {
                    UFButton("Öffnen", icon: "eye", kind: .primary, size: .small) { Task { await open(o) } }
                        .accessibilityIdentifier("certificates.open.\(id)")
                    UFButton(busy ? "Lädt …" : "Neu laden", icon: "sync", size: .small) { Task { await download(id, show: true) } }
                        .disabled(center?.busy != nil || !canDownload)
                        .accessibilityIdentifier("certificates.reload.\(id)")
                } else {
                    UFButton(busy ? "Lädt …" : "Herunterladen", icon: "download", kind: .primary, size: .small) { Task { await download(id, show: true) } }
                        .disabled(center?.busy != nil || !canDownload)
                        .accessibilityIdentifier("certificates.download.\(id)")
                }
            }
            .padding(.leading, 24)
        }
        .padding(.vertical, 10)
    }

    /// Arten, die das Portal (gerade) nicht anbietet
    @ViewBuilder private func missingCard(_ d: JSONValue) -> some View {
        let missing = d.list("kinds").filter { $0["offered"]?.bool != true }
        if !missing.isEmpty, d.s("status") != "never" {
            UFCard {
                UFCardHead("Nicht im Portal gefunden", icon: "info")
                Text(missing.compactMap { $0.s("label") }.joined(separator: " · "))
                    .ufFont(13.12).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                Text("Diese Dokumente bietet \(d.s("portal") ?? "das Portal") deinem Konto gerade nicht an. Manche erscheinen erst nach der Rückmeldung oder wenn Leistungen verbucht sind; sonst hilft das Studierendensekretariat.")
                    .ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
            .padding(.bottom, 16)
            .accessibilityIdentifier("certificates.missing")
        }
    }

    /// Am PC beim Notenabruf gespeicherte Dokumente (aeltere Fassung); auf dem iPad leer
    @ViewBuilder private func legacyCard(_ d: JSONValue) -> some View {
        let docs = d.list("documents")
        if !docs.isEmpty {
            UFCard {
                UFCardHead("Beim Notenabruf gespeichert", icon: "folder")
                ForEach(docs.indices, id: \.self) { i in
                    Button { Task { await openLegacy(docs[i]) } } label: {
                        UFItemRow(docs[i].s("title") ?? "", sub: UFFmt.date(docs[i].s("fetched_at")), link: true, leading: { UFIcon("file-text", size: 16) })
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 16)
        }
    }

    @ViewBuilder private var loginSheet: some View {
        switch center?.portal {
        case .qis(let q)?: QISLoginView(connection: q).onDisappear { if q.state != .needsLogin, q.isConnected { center?.signedIn() } }
        case .hsh(let h)?: HsHLoginView(source: .campus, connection: h).onDisappear { if h.isConnected(.campus), h.state(.campus) != .needsLogin { center?.signedIn() } }
        case .plus(let l)?: PLuSLoginView(dataStore: l.websiteDataStore) { center?.signedIn() }
        case nil: EmptyView()
        }
    }

    // MARK: Aktionen

    private var canDownload: Bool { !isLocal || center != nil }

    private func refreshList() async {
        if let center {
            if !center.isConnected, !(await center.silentLogin()) { center.needsLogin = true; login = true; return }
            await center.refresh()
            if center.needsLogin { toast.show("\(center.portalName): Anmeldung nötig", seconds: 4) }
            return
        }
        guard let api = session.api else { return }
        do {
            _ = try await api.value("/api/certificates/refresh", method: "POST")
            toast.show("Bescheinigungen werden gelesen …")
            await shell.pollBackground(toast: toast)
            await load()
        } catch { toast.show(error.localizedDescription, seconds: 4) }
    }

    private func download(_ id: String, show: Bool) async {
        let semester = semesters[id] ?? data?.list("offers").first { $0.s("id") == id }?.list("semesters").first?.s("value")
        if let center {
            if !center.isConnected, !(await center.silentLogin()) { center.needsLogin = true; login = true; return }
            let url = await center.download(id, semester: semester)
            await load()
            if let url, show, let o = data?.list("offers").first(where: { $0.s("id") == id }) {
                preview = CertificatePreview(url: try? copy(url, title: o.s("title") ?? "Bescheinigung"), title: o.s("title") ?? "Bescheinigung",
                                             stand: o["file"]?.s("fetched_at"), offerID: id)
            } else if url == nil, let m = center.message {
                toast.show(m, seconds: 5)
            }
            return
        }
        guard let api = session.api else { return }
        do {
            let body: JSONValue = semester.map { ["semester": .string($0)] } ?? [:]
            _ = try await api.value("/api/certificates/\(id)/download", method: "POST", body: body)
            toast.show("Bescheinigung wird geladen …")
            await shell.pollBackground(toast: toast)
            await load()
        } catch { toast.show(error.localizedDescription, seconds: 4) }
    }

    private func open(_ o: JSONValue) async {
        guard let api = session.api, let id = o.s("id") else { return }
        do {
            let (bytes, http) = try await api.data("/api/certificates/\(id)/file")
            guard http.statusCode == 200 else { toast.show("Die gespeicherte Kopie fehlt. Bitte neu laden.", seconds: 4); return }
            let title = o.s("title") ?? "Bescheinigung"
            let url = try AppTemp.file("bescheinigung", name: Self.fileName(title, stand: o["file"]?.s("fetched_at")))
            try bytes.write(to: url, options: .atomic)
            preview = CertificatePreview(url: url, title: title, stand: o["file"]?.s("fetched_at"), offerID: id)
        } catch { toast.show(error.localizedDescription, seconds: 4) }
    }

    private func openLegacy(_ d: JSONValue) async {
        guard let api = session.api, let id = d.i("id") else { return }
        do {
            let (bytes, _) = try await api.data("/api/qis/documents/\(id)")
            let url = try AppTemp.file("bescheinigung", name: (d.s("title") ?? "Bescheinigung") + ".pdf")
            try bytes.write(to: url)
            preview = CertificatePreview(url: url, title: d.s("title") ?? "Bescheinigung", stand: d.s("fetched_at"), offerID: nil)
        } catch { toast.show(error.localizedDescription, seconds: 4) }
    }

    /// Kopie mit lesbarem Namen fuer Teilen/Dateien ("Immatrikulationsbescheinigung (Stand 06.11.2026).pdf")
    private func copy(_ url: URL, title: String) throws -> URL {
        let target = try AppTemp.file("bescheinigung", name: Self.fileName(title, stand: nil, date: Date()))
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: url, to: target)
        return target
    }

    // MARK: Regeln (rein, CertificatesAppTests)

    struct KindGroup { let kind: String; let label: String; let offers: [JSONValue] }

    /// Dokumente nach Art in der Reihenfolge der Liste (der Kern sortiert schon)
    static func groups(_ offers: [JSONValue]) -> [KindGroup] {
        var order: [String] = []
        var by: [String: [JSONValue]] = [:]
        for o in offers {
            let k = o.s("kind") ?? "sonstige"
            if by[k] == nil { order.append(k) }
            by[k, default: []].append(o)
        }
        return order.map { KindGroup(kind: $0, label: by[$0]?.first?.s("kind_label") ?? $0, offers: by[$0] ?? []) }
    }

    /// "WiSe 2026/27 · Stand: 06.11.2026, 14:03" bzw. "noch nicht geladen"; unbestaetigter Aufbau mit Hinweis
    static func subline(_ o: JSONValue) -> String {
        var parts: [String] = []
        if let s = o.s("semester") { parts.append(s) }
        if let f = o["file"], !f.isNull {
            parts.append("Stand: " + stand(f.s("fetched_at") ?? "") + (f.s("semester").map { $0 == o.s("semester") ? "" : " (\($0))" } ?? ""))
        } else {
            parts.append("noch nicht geladen")
        }
        if o["confirmed"]?.bool == false { parts.append("Aufbau noch nicht mit echtem Konto geprüft") }
        return parts.joined(separator: " · ")
    }

    static func emptyText(status: String?, portal: String) -> String {
        switch status {
        case "login": return "Melde dich bei \(portal) an, dann zeigt StudiNow hier alle Bescheinigungen."
        case "never", nil: return "Noch nicht gelesen. Tippe auf „Liste aktualisieren“, dann zeigt StudiNow hier alles, was \(portal) anbietet."
        default: return "\(portal) bietet deinem Konto gerade keine Bescheinigungen an."
        }
    }

    private static let standFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.timeZone = TimeZone(identifier: "Europe/Berlin")
        f.dateFormat = "dd.MM.yyyy, HH:mm"
        return f
    }()

    /// "06.11.2026, 14:03" aus der ISO-Zeit; ohne Uhrzeit nur das Datum
    static func stand(_ iso: String) -> String {
        if let d = Fmt.dateTime(iso) { return standFormat.string(from: d) }
        return UFFmt.date(iso)
    }

    static func fileName(_ title: String, stand: String?, date: Date? = nil) -> String {
        let day: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "de_DE")
            f.timeZone = TimeZone(identifier: "Europe/Berlin")
            f.dateFormat = "dd.MM.yyyy"
            if let date { return f.string(from: date) }
            if let s = stand, let d = Fmt.dateTime(s) ?? Fmt.date(s) { return f.string(from: d) }
            return f.string(from: Date())
        }()
        let clean = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " ")
        return "\(clean.prefix(80)) (Stand \(day)).pdf"
    }
}

/// PDF in der Vorschau der App (QuickLook) mit "Teilen oder sichern" (Teilen-Blatt: "In Dateien sichern", AirDrop ...)
struct CertificatePreview: Identifiable {
    let id = UUID()
    let url: URL?
    let title: String
    let stand: String?
    let offerID: String?
}

struct CertificatePreviewSheet: View {
    let preview: CertificatePreview
    let reload: (() async -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let url = preview.url {
                    UFQuickLookView(url: url).accessibilityIdentifier("certificates.preview")
                } else {
                    ContentUnavailableView(preview.title, systemImage: "doc", description: Text("Die PDF ist gespeichert, die Vorschau konnte nicht geöffnet werden."))
                }
            }
            .navigationTitle(preview.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } }
                if let url = preview.url {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: url) { Label("Teilen oder sichern", systemImage: "square.and.arrow.up") }
                            .accessibilityIdentifier("certificates.share")
                    }
                }
                if let stand = preview.stand {
                    ToolbarItem(placement: .status) { Text("Stand: \(CertificatesPage.stand(stand))").ufFont(12.16).foregroundStyle(UF.muted) }
                }
            }
        }
    }
}

/// Anmeldung im PLuS (Uni Hildesheim) als Blatt: echte Seite, das Passwort tippt der Mensch (iOS darf es merken)
struct PLuSLoginView: View {
    let dataStore: WKWebsiteDataStore
    let onSignedIn: () -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var load = UFWebLoadState()
    @State private var done = false

    var body: some View {
        NavigationStack {
            StudIPWebView(url: DebugUniStub.loginPage("plus", real: CertificatePortal.plusLogin), dataStore: dataStore, load: load) { web in
                guard !done else { return }
                if DebugUniStub.isSignedIn(web.url, service: "plus") { finish(); return }
                guard let url = web.url, url.host?.lowercased() == PLuSLogin.host else { return }
                web.evaluateJavaScript("document.documentElement.outerHTML", in: nil, in: .defaultClient) { result in
                    if PLuSLogin.isSignedIn(html: (try? result.get()) as? String ?? "", url: url) { finish() }
                }
            }
            .ufWebLoadFailure(load)
            .safeAreaInset(edge: .bottom, spacing: 0) { UniversityLoginHint() }
            .navigationTitle("PLuS-Anmeldung")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
        }
    }

    private func finish() {
        guard !done else { return }
        done = true
        Task { await UniWebSessions.save(dataStore) }
        onSignedIn()
        dismiss()
    }
}

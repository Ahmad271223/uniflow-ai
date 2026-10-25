import SwiftUI
import UniFlowCore

/// Einstellungen: Profil, Serververbindung, Schreibhand, Apple Pencil, Synchronisierung, Tarif, Diagnose.
struct SettingsView: View {
    @EnvironmentObject private var session: Session
    @StateObject private var settings: RemoteData
    @StateObject private var dashboard: RemoteData
    @AppStorage("uniflow.pencilOnly") private var pencilOnly = true
    @State private var userName = ""
    @State private var hand = "right"
    @State private var saveMessage: String?
    @State private var diagnostics: Diagnostics?
    @State private var confirmSync = false

    init(api: APIClient?) {
        _settings = StateObject(wrappedValue: RemoteData(path: "/api/settings", api: api))
        _dashboard = StateObject(wrappedValue: RemoteData(path: "/api/dashboard", api: api))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Profil") {
                    TextField("Name", text: $userName).onSubmit { Task { await save(["user_name": .string(userName)]) } }
                }
                Section {
                    Picker("Schreibhand", selection: $hand) {
                        Text("Rechts").tag("right")
                        Text("Links").tag("left")
                    }
                    .onChange(of: hand) { _, v in
                        UserDefaults.standard.set(v, forKey: "uniflow.hand")      // Seite des Skripts in der geteilten Ansicht
                        Task { await save(["hand": .string(v)]) }
                    }
                    Toggle("Nur Apple Pencil schreibt (Finger scrollt)", isOn: $pencilOnly)
                } header: { Text("Schreiben") } footer: {
                    Text("Die Schreibhand legt fest, auf welcher Seite das Skript in der geteilten Ansicht erscheint. Doppeltippen am Pencil folgt der Einstellung in iPadOS (Einstellungen → Apple Pencil).")
                }
                Section("Server") {
                    LabeledContent("Adresse", value: session.api?.base.absoluteString ?? "–")
                    Button("Verbindung trennen", role: .destructive) { session.disconnect() }
                }
                Section("Synchronisierung") {
                    if let s = dashboard.value?["last_sync"] {
                        LabeledContent("Letzter Stud.IP-Abgleich", value: Fmt.day(s.s("finished_at") ?? s.s("started_at"), style: "d.M. HH:mm"))
                        if let m = s.s("message") { Text(m).font(.caption).foregroundStyle(.secondary) }
                    }
                    if let d = diagnostics {
                        LabeledContent("Dokumente mit ungesendeten Notizen", value: "\(d.documentsWithUnsent)")
                        LabeledContent("Ungesendete Seiten", value: "\(d.unsentPages)")
                    }
                    Button("Stud.IP jetzt abgleichen") { confirmSync = true }
                }
                Section {
                    NavigationLink("Stud.IP direkt auf dem iPad") { StudIPView() }
                } header: { Text("Stud.IP") } footer: {
                    Text("Anmeldung auf der Stud.IP-Seite der Universität, Dateien werden ohne PC aufs iPad geladen.")
                }
                Section("Tarif") {
                    NavigationLink("Abo (Testmodus)") { SubscriptionView() }
                }
                Section("Diagnose") {
                    if let d = diagnostics {
                        LabeledContent("App-Version", value: d.appVersion)
                        LabeledContent("iPadOS", value: d.osVersion)
                        LabeledContent("Lokale Notizen", value: ByteCountFormatter.string(fromByteCount: d.journalBytes, countStyle: .file))
                        LabeledContent("Zwischenspeicher", value: ByteCountFormatter.string(fromByteCount: d.cacheBytes, countStyle: .file))
                        if !d.damaged.isEmpty { Text("Beschädigte lokale Dateien: \(d.damaged.joined(separator: ", "))").foregroundStyle(.red) }
                    } else {
                        ProgressView()
                    }
                }
                if let saveMessage { Section { Text(saveMessage).font(.caption) } }
            }
            .navigationTitle("Einstellungen")
            .task {
                await settings.load()
                await dashboard.load()
                if let s = settings.value {
                    userName = s.s("user_name") ?? ""
                    hand = s.s("hand") ?? "right"
                    UserDefaults.standard.set(hand, forKey: "uniflow.hand")
                }
                diagnostics = await Diagnostics.collect()
            }
            .confirmationDialog("Stud.IP-Abgleich am PC starten?", isPresented: $confirmSync) {
                Button("Abgleichen") { Task { await startSync() } }
            } message: { Text("Der PC meldet sich mit den dort gespeicherten Zugangsdaten bei Stud.IP an und lädt neue Dateien.") }
        }
    }

    private func save(_ values: [String: JSONValue]) async {
        guard let api = session.api else { return }
        do {
            _ = try await api.value("/api/settings", method: "PUT", body: .object(values))
            saveMessage = "Gespeichert."
        } catch {
            saveMessage = "Nicht gespeichert: \(error.localizedDescription)"
        }
    }

    private func startSync() async {
        guard let api = session.api else { return }
        do {
            _ = try await api.value("/api/sync", method: "POST", body: .object([:]))
            saveMessage = "Abgleich läuft am PC (dauert einige Minuten)."
        } catch {
            saveMessage = "Abgleich nicht gestartet: \(error.localizedDescription)"
        }
    }
}

/// Zustand der lokalen Daten fuer die Diagnose (ohne Inhalte).
struct Diagnostics {
    var appVersion: String
    var osVersion: String
    var journalBytes: Int64
    var cacheBytes: Int64
    var documentsWithUnsent: Int
    var unsentPages: Int
    var damaged: [String]

    @MainActor
    static func collect() async -> Diagnostics {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        let os = UIDevice.current.systemVersion
        return await Task.detached(priority: .utility) {
            let store = FileBlobStore(root: AppPaths.journal)
            var docs = 0, pages = 0
            var damaged: [String] = []
            for dir in (try? store.list("docs")) ?? [] {
                guard let snap = try? LocalJournal(store: store, documentID: dir).load() else { continue }
                let unsent = snap.pages.filter { $0.value.localRev > (snap.acked[$0.key] ?? 0) }.count + (snap.metaRev > snap.metaAckedRev ? 1 : 0)
                if unsent > 0 { docs += 1; pages += unsent }
                damaged += snap.damaged.map { "\(dir)/\($0)" }
            }
            return Diagnostics(appVersion: version, osVersion: os,
                               journalBytes: folderSize(AppPaths.journal), cacheBytes: folderSize(ResponseCache.shared.root),
                               documentsWithUnsent: docs, unsentPages: pages, damaged: damaged)
        }.value
    }

    static func folderSize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }
}

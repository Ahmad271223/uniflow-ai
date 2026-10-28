import SwiftUI
import UniFlowCore

// Demo-Inhalte fuer die App-Pruefung (Entscheidung des Inhabers 27.10.2026, ersetzt "kein Demo-Modus"): dieselben
// Inhalte wie am PC (app/demo.py, im Kern `DemoContent`, `POST /api/demo`), im Container des angemeldeten Nutzers und
// der gewaehlten Hochschule. Wege dorthin: Einstellungen -> Erweitert (auch im Release-Build, die Pruefer von Apple
// muessen ihn finden) und im ersten Start "Ohne Hochschulkonto ansehen (Demo)" auf der Anmeldeseite der Hochschule.
// Solange die Demo aktiv ist: Hinweis auf der Uebersicht mit "Entfernen", keine Karten "… verbinden", kein Abgleich
// mit der Hochschule (die Abgleiche fragen die Datenbank, `LocalBackendHost.demoActive`), keine Anmeldung noetig.

private struct UFDemoActiveKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Demo-Inhalte im offenen Container aktiv (`ContainerManager.demoActive`, gesetzt in UniFlowApp)
    var ufDemoActive: Bool {
        get { self[UFDemoActiveKey.self] }
        set { self[UFDemoActiveKey.self] = newValue }
    }
}

/// Texte der Demo (eine Stelle, DemoAppTests)
enum DemoTexts {
    static let cardTitle = "Demo-Inhalte für die App-Prüfung"
    static let cardText = "Nur zum Ausprobieren ohne Hochschulkonto: ein Demo-Modul „Grundlagen der Informatik“ mit drei selbst erstellten PDFs (Skript, Folien, Übungsblatt), Stundenplan, Lernkalender, einer Abgabefrist und einer Ankündigung – keine Inhalte einer Hochschule. Entfernen nimmt alles rückstandslos wieder weg, deine eigenen Daten bleiben."
    static let offlineNote = "Solange die Demo aktiv ist, verbindet sich Studora nicht mit der Hochschule und braucht keine Anmeldung."
    static let install = "Demo-Inhalte anlegen"
    static let remove = "Demo-Inhalte entfernen"
    static let barTitle = "Demo-Inhalte aktiv"
    static let barText = "Beispielinhalte zum Ausprobieren ohne Hochschulkonto. Studora verbindet sich solange nicht mit der Hochschule."
    static let barRemove = "Entfernen"
    static let firstStart = "Ohne Hochschulkonto ansehen (Demo)"
    static let firstStartRunning = "Demo wird angelegt …"
    static let confirmRemove = "Demo-Inhalte entfernen? Das Demo-Modul mit PDFs, Terminen, Lernpaketen und Notizen dazu verschwindet; deine eigenen Daten bleiben."
    static let removed = "Demo-Inhalte entfernt"
    static let syncBlocked = "Demo-Inhalte aktiv: Studora gleicht nicht mit der Hochschule ab. Zum Abgleichen entferne die Demo unter Einstellungen → Erweitert."

    /// "3 PDFs · 3 Termine · 3 Lernpakete" aus GET/POST /api/demo
    static func summary(_ s: JSONValue) -> String {
        let f = s.i("files") ?? 0, e = s.i("events") ?? 0, p = s.i("packages") ?? 0
        return "\(f) \(f == 1 ? "PDF" : "PDFs") · \(e) \(e == 1 ? "Termin" : "Termine") · \(p) \(p == 1 ? "Lernpaket" : "Lernpakete")"
    }

    /// Meldung nach dem Anlegen wie im Web (views-misc.js): "Demo angelegt: 3 PDFs, 3 Termine, 3 Lernpakete"
    static func installed(_ s: JSONValue) -> String {
        "Demo angelegt: \(s.i("files") ?? 0) PDFs, \(s.i("events") ?? 0) Termine, \(s.i("packages") ?? 0) Lernpakete"
    }
}

/// Anlegen und Entfernen fuer die Oberflaeche: lokal ueber den Container (mit den Kopien auf dem Geraet), mit eigenem
/// Server (nur Entwicklung) dessen `/api/demo`
@MainActor
enum DemoActions {
    static func set(_ on: Bool, session: Session, containers: ContainerManager) async throws -> JSONValue {
        if session.isOwnServer, let api = session.api {
            return try await api.value("/api/demo", method: "POST", body: ["enabled": .bool(on)])
        }
        return try await containers.setDemo(on)
    }
}

/// Karte unter Einstellungen -> Erweitert: kurzer, ehrlicher Text, Stand, Anlegen bzw. Entfernen
struct DemoContentCard: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var containers: ContainerManager
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var router: UFRouter
    @State private var status: JSONValue?
    @State private var busy = false

    private var enabled: Bool { status?["enabled"]?.bool ?? (!session.isOwnServer && containers.demoActive) }

    var body: some View {
        UFCard {
            UFCardHead(DemoTexts.cardTitle, icon: "sparkles", wrap: true) {
                enabled ? UFBadge("aktiv", tone: .ok, icon: "check") : UFBadge("aus", tone: .neutral)
            }
            Text(DemoTexts.cardText)
                .ufFont(13.12).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
            Text(DemoTexts.offlineNote)
                .ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 6.4)
            if enabled, let status {
                Text(DemoTexts.summary(status)).ufFont(12.8, 600).foregroundStyle(UF.text).padding(.top, 6.4)
                    .accessibilityIdentifier("demo.summary")
            }
            UFFlexWrap(gap: 9.6) {
                if enabled {
                    UFButton(DemoTexts.remove, icon: "trash", kind: .danger, size: .small) { Task { await toggle(false) } }
                        .disabled(busy)
                        .accessibilityIdentifier("demo.toggle")
                } else {
                    UFButton(DemoTexts.install, icon: "sparkles", kind: .primary, size: .small) { Task { await toggle(true) } }
                        .disabled(busy)
                        .accessibilityIdentifier("demo.toggle")
                }
            }
            .padding(.top, 12.8)
        }
        .accessibilityIdentifier("demo.card")
        .task(id: containers.demoActive) { await load() }
    }

    private func load() async {
        guard let api = session.api else { status = nil; return }
        status = try? await api.value("/api/demo")
    }

    private func toggle(_ on: Bool) async {
        if !on, !(await overlay.confirm(DemoTexts.confirmRemove)) { return }
        busy = true
        defer { busy = false }
        do {
            let r = try await DemoActions.set(on, session: session, containers: containers)
            status = r
            toast.show(on ? DemoTexts.installed(r) : DemoTexts.removed, seconds: 3)
            router.reload()
        } catch {
            toast.show(error.localizedDescription, seconds: 4)
        }
    }
}

/// Hinweis oben auf der Uebersicht, solange die Demo aktiv ist: "Demo-Inhalte aktiv" mit "Entfernen"
struct DemoActiveBar: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var containers: ContainerManager
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var router: UFRouter
    @State private var busy = false

    var body: some View {
        UFCard(flat: true) {
            HStack(alignment: .center, spacing: 11.2) {
                UFIcon("sparkles", size: 20).foregroundStyle(UF.accent)
                VStack(alignment: .leading, spacing: 2.4) {
                    Text(DemoTexts.barTitle).ufFont(14.5, 650).foregroundStyle(UF.text)
                    Text(DemoTexts.barText).ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                UFButton(DemoTexts.barRemove, icon: "trash", size: .small) { Task { await remove() } }
                    .disabled(busy)
                    .accessibilityIdentifier("demo.remove")
            }
        }
        .accessibilityIdentifier("demo.bar")
    }

    private func remove() async {
        guard await overlay.confirm(DemoTexts.confirmRemove) else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await DemoActions.set(false, session: session, containers: containers)
            toast.show(DemoTexts.removed, seconds: 3)
            router.reload()
        } catch {
            toast.show(error.localizedDescription, seconds: 4)
        }
    }
}

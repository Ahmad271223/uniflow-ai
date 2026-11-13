import SwiftUI
import UniFlowCore

/// Eigene Wochen und Abschnitte im Moduldetail (Auftrag des Inhabers 12.11.2026: "Wenn keine klaren Vorlesungswochen
/// bestehen, soll der Nutzer selbst welche anlegen koennen. Wir geben ihm alle Dateien so gut geordnet wie moeglich,
/// und den Rest darf er selbst umstrukturieren").
///
/// Bedienung: am Mac mit Maus (Ziehen, Rechtsklick), am iPad mit Finger/Pencil (lange druecken = Menue, ziehen), mit
/// VoiceOver ueber die Menues ("Aktionen"). Jede Ansicht ist ein eigener, flacher Typ (`ViewTypeDepthAppTests`).
/// Kern: `ModuleLayout`, Endpunkte `ModuleLayoutEndpoints` (am PC-Server dieselben Pfade, app/module_layout.py).
@MainActor
enum ModuleLayoutAction {
    /// Aenderung senden, Seite neu laden, kurze Rueckmeldung
    static func run(_ session: Session, _ toast: UFToastCenter, _ router: UFRouter, _ path: String, method: String = "POST",
                    body: JSONValue = .object([:]), done: String? = nil) async {
        guard let api = session.api else { toast.show("Nicht verbunden."); return }
        do {
            _ = try await api.value(path, method: method, body: body)
            if let done { toast.show(done) }
            router.reload()
        } catch {
            toast.show(error.localizedDescription, seconds: 4)
        }
    }

    /// Reihenfolge nach dem Verschieben eines Blocks um `by` Plaetze
    static func moved(_ keys: [String], _ key: String, by: Int) -> [String]? {
        guard let i = keys.firstIndex(of: key) else { return nil }
        let j = i + by
        guard keys.indices.contains(j) else { return nil }
        var out = keys
        out.swapAt(i, j)
        return out
    }

    static let unassignedKey = "w:-4"
    static let hint = "Hier liegen Dateien, deren Woche die App nicht sicher erkennt. Zieh sie in eine Woche, nutze „Verschieben nach …“ oder übernimm die Vorschläge."
}

/// Leiste unter den Wochen: Abschnitt anlegen, eigene Ordnung zuruecksetzen
struct ModuleLayoutBar: View {
    let moduleID: Int
    let custom: Bool
    let lastKey: String?
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter

    var body: some View {
        HStack(spacing: 8) {
            Text("Eigene Wochen und Abschnitte").ufFont(13.12, 600).foregroundStyle(UF.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
            UFButton("Abschnitt hinzufügen", icon: "plus", kind: .ghost, size: .small) {
                overlay.modal { ModuleSectionNameDialog(moduleID: moduleID, mode: .create(after: lastKey)) }
            }
            .accessibilityIdentifier("module.layout.add")
            if custom {
                Menu {
                    Button("Eigene Ordnung zurücksetzen", role: .destructive) {
                        Task { await ModuleLayoutAction.run(session, toast, router, "/api/modules/\(moduleID)/layout", method: "DELETE",
                                                            done: "Die App ordnet wieder selbst") }
                    }
                } label: {
                    UFIcon("more", size: 16).foregroundStyle(UF.text2).frame(width: 24, height: 20).contentShape(Rectangle()).ufHitArea()
                }
                .menuStyle(.button).buttonStyle(.plain)
                .accessibilityLabel("Mehr zur Ordnung")
                .accessibilityIdentifier("module.layout.more")
            }
        }
        .padding(.bottom, 6)
    }
}

/// Menue im Kopf eines Wochenblocks: umbenennen, nach oben/unten, Abschnitt dahinter, loeschen
struct ModuleSectionMenu: View {
    let moduleID: Int
    let block: JSONValue
    let keys: [String]
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter

    private var key: String { block.s("key") ?? "" }

    var body: some View {
        Menu {
            if key != ModuleLayoutAction.unassignedKey {
                Button("Umbenennen …") { overlay.modal { ModuleSectionNameDialog(moduleID: moduleID, mode: .rename(key: key, current: block.s("label") ?? "")) } }
                if block["renamed"]?.bool == true {
                    Button("Ursprünglichen Namen verwenden") { send("/sections/rename", ["key": .string(key), "title": ""]) }
                }
            }
            if let up = ModuleLayoutAction.moved(keys, key, by: -1) { Button("Nach oben") { order(up) } }
            if let down = ModuleLayoutAction.moved(keys, key, by: 1) { Button("Nach unten") { order(down) } }
            Button("Neuer Abschnitt dahinter …") { overlay.modal { ModuleSectionNameDialog(moduleID: moduleID, mode: .create(after: key)) } }
            if key != ModuleLayoutAction.unassignedKey {
                Button(block["custom"]?.bool == true ? "Abschnitt löschen" : "Woche entfernen", role: .destructive) {
                    send("/sections/delete", ["key": .string(key)],
                         done: block["custom"]?.bool == true ? "Abschnitt gelöscht – Dateien wieder automatisch eingeordnet" : "Woche entfernt – Dateien unter „Nicht zugeordnet“")
                }
            }
        } label: {
            // sichtbar klein (der Wochenkopf wird nicht hoeher), antippbar 44 pt (`ufHitArea`)
            UFIcon("more", size: 16).foregroundStyle(UF.muted).frame(width: 24, height: 20).contentShape(Rectangle()).ufHitArea()
        }
        .menuStyle(.button).buttonStyle(.plain)
        .accessibilityLabel("Abschnitt \(block.s("label") ?? "") bearbeiten")
        .accessibilityIdentifier("module.section.menu.\(key)")
    }

    private func order(_ keys: [String]) {
        send("/sections/order", ["keys": .array(keys.map { .string($0) })], method: "PUT")
    }

    private func send(_ path: String, _ body: JSONValue, method: String = "POST", done: String? = nil) {
        Task { await ModuleLayoutAction.run(session, toast, router, "/api/modules/\(moduleID)" + path, method: method, body: body, done: done) }
    }
}

/// Name fuer einen neuen oder bestehenden Abschnitt ("Woche 7" legt die Lehrwoche 7 an)
struct ModuleSectionNameDialog: View {
    enum Mode { case create(after: String?), rename(key: String, current: String) }
    let moduleID: Int
    let mode: Mode
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var close
    @State private var name = ""
    @State private var loaded = false

    private var isCreate: Bool { if case .create = mode { return true }; return false }

    var body: some View {
        UFDialog(isCreate ? "Abschnitt hinzufügen" : "Abschnitt umbenennen", icon: "list") {
            UFField("Name") { UFTextInput(isCreate ? "z. B. Woche 7 oder Kapitel Graphen" : "", text: $name) }
                .accessibilityIdentifier("module.section.name")
            Text(isCreate ? "„Woche 7“ legt die Lehrwoche 7 an (auch leer, zum Hineinziehen). Jeder andere Name wird ein eigener Abschnitt."
                          : "Leer lassen, um den ursprünglichen Namen zu verwenden.")
                .ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
        } foot: {
            UFButton("Abbrechen") { close() }
            UFButton(isCreate ? "Anlegen" : "Speichern", kind: .primary) { Task { await save() } }
                .accessibilityIdentifier("module.section.save")
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if case .rename(_, let current) = mode { name = current }
        }
    }

    private func save() async {
        let path: String, body: JSONValue
        switch mode {
        case .create(let after):
            path = "/api/modules/\(moduleID)/sections"
            body = ["title": .string(name), "after": after.map { .string($0) } ?? .null]
        case .rename(let key, _):
            path = "/api/modules/\(moduleID)/sections/rename"
            body = ["key": .string(key), "title": .string(name)]
        }
        guard let api = session.api else { return }
        do {
            _ = try await api.value(path, body: body)
            close()
            router.reload()
        } catch { toast.show(error.localizedDescription, seconds: 4) }
    }
}

/// Zeile einer Datei im Wochenblock: oeffnen, ziehen, "Verschieben nach …", in "Nicht zugeordnet" mit Vorschlag
struct ModuleWeekFileRow: View {
    let moduleID: Int
    let f: JSONValue
    let targets: [JSONValue]
    let open: () -> Void
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter

    private var id: String { f.s("id") ?? "" }

    var body: some View {
        HStack(spacing: 6) {
            UFDocRow(f: f, open: open)
            if let k = f.s("suggest_key"), let label = f.s("suggest_label") {
                ModuleSuggestionChip(label: label, reason: f.s("suggest_reason") ?? "") { place(k) }
            }
            ModuleFileDoneToggle(moduleID: moduleID, f: f)                  // ganz rechts: erledigt (13.11.2026)
        }
        .draggable(ModuleDragFile(id: id)) {
            Text(f.s("ai_title") ?? f.s("name") ?? "Datei").ufFont(13.12, 550).padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(UF.surface))
        }
        // Rechtsklick (Mac) bzw. lange druecken (iPad); VoiceOver: "Aktionen anzeigen"
        .contextMenu { ModuleFileMoveMenu(f: f, targets: targets, place: place) }
    }

    private func place(_ key: String?) {
        Task {
            await ModuleLayoutAction.run(session, toast, router, "/api/modules/\(moduleID)/place",
                                         body: ["file_ids": [.string(id)], "to": key.map { .string($0) } ?? .null],
                                         done: key == nil ? "Wieder automatisch eingeordnet" : nil)
        }
    }
}

/// Inhalt des Kontextmenues einer Datei
struct ModuleFileMoveMenu: View {
    let f: JSONValue
    let targets: [JSONValue]
    let place: (String?) -> Void

    var body: some View {
        Menu("Verschieben nach …") {
            ForEach(targets.filter { $0.s("key") != f.s("section") }, id: \.self) { t in
                Button(t.s("label") ?? "") { place(t.s("key")) }
            }
        }
        if f["placed"]?.bool == true {
            Button("Wieder automatisch einordnen") { place(nil) }
        }
    }
}

/// Vorschlag in "Nicht zugeordnet": antippen legt die Datei dorthin
struct ModuleSuggestionChip: View {
    let label: String
    let reason: String
    let accept: () -> Void

    var body: some View {
        UFChip(text: "→ " + (label.components(separatedBy: "·").first?.trimmingCharacters(in: .whitespaces) ?? label), icon: "sparkles", action: accept)
            .help(reason)
            .accessibilityLabel("Vorschlag: \(label)")
            .accessibilityHint("\(reason). Legt die Datei dorthin.")
            .fixedSize()
    }
}

/// Kopf des Blocks "Nicht zugeordnet": Erklaerung, Vorschlaege uebernehmen, Vorschlaege suchen (erste Seiten lesen)
struct ModuleUnassignedBar: View {
    let moduleID: Int
    let suggestions: Int
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @State private var scanning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ModuleLayoutAction.hint).ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if suggestions > 0 {
                    UFButton("Vorschläge übernehmen (\(suggestions))", icon: "check", kind: .primary, size: .small) {
                        Task { await ModuleLayoutAction.run(session, toast, router, "/api/modules/\(moduleID)/suggestions/accept",
                                                            done: "Vorschläge übernommen") }
                    }
                    .accessibilityIdentifier("module.layout.accept")
                }
                if session.api?.isLocal == true {
                    UFButton(scanning ? "Lese erste Seiten …" : "Vorschläge suchen", icon: "search", kind: .ghost, size: .small) {
                        Task { await scan() }
                    }
                    .disabled(scanning)
                    .accessibilityIdentifier("module.layout.scan")
                }
            }
        }
        .padding(.horizontal, 8).padding(.bottom, 6)
    }

    private func scan() async {
        scanning = true
        await ModuleLayoutAction.run(session, toast, router, "/api/modules/\(moduleID)/suggestions/scan")
        scanning = false
    }
}

/// Gezogene Datei (nur die ID; Ziehen innerhalb der App)
struct ModuleDragFile: Codable, Transferable {
    let id: String
    static var transferRepresentation: some TransferRepresentation { CodableRepresentation(contentType: .data) }
}

/// Wochenblock als Ablageziel: Datei hineinziehen legt sie in diesen Abschnitt
struct ModuleDropZone: ViewModifier {
    let moduleID: Int
    let key: String
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(UF.accent, lineWidth: targeted ? 2 : 0).allowsHitTesting(false))
            .dropDestination(for: ModuleDragFile.self) { files, _ in
                let ids = files.map(\.id)
                guard !ids.isEmpty else { return false }
                Task { await ModuleLayoutAction.run(session, toast, router, "/api/modules/\(moduleID)/place",
                                                    body: ["file_ids": .array(ids.map { .string($0) }), "to": .string(key)]) }
                return true
            } isTargeted: { targeted = $0 }
    }
}

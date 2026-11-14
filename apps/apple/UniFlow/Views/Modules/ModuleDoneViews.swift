import SwiftUI
import UniFlowCore

/// Haken "erledigt" je Datei und ganze Woche im Moduldetail (Auftrag des Inhabers 13.11.2026). Derselbe Stand wie bei
/// den Lernpaketen (`files.status = 'erledigt'`, durchgestrichen); Abhaken schliesst offene Lernaufgaben zur Datei.
/// Kern und PC-Server: `POST /api/modules/{id}/done` {file_ids, done}.
enum ModuleDoneAction {
    static let groups = ["vorlesungen", "uebungen", "loesungen", "skripte", "klausuren", "sonstiges"]

    /// Alle Dateien eines Wochenblocks
    static func files(_ w: JSONValue) -> [JSONValue] { groups.flatMap { w.list($0) } }
    static func isDone(_ f: JSONValue) -> Bool { f.s("status") == "erledigt" }

    /// Fortschritt eines Wochenblocks: erledigt / alle
    static func progress(_ w: JSONValue) -> (done: Int, total: Int) {
        let fs = files(w)
        return (fs.filter(isDone).count, fs.count)
    }

    static func text(_ p: (done: Int, total: Int)) -> String { "\(p.done)/\(p.total) erledigt" }

    /// Senden, danach laedt die Seite neu (gleicher Weg wie die eigenen Wochen)
    static func send(_ session: Session, _ toast: UFToastCenter, _ router: UFRouter, moduleID: Int, ids: [String], done: Bool,
                     message: String? = nil) async {
        guard !ids.isEmpty else { return }
        await ModuleLayoutAction.run(session, toast, router, "/api/modules/\(moduleID)/done",
                                     body: ["file_ids": .array(ids.map { .string($0) }), "done": .bool(done)], done: message)
    }
}

/// Kaestchen ganz rechts in der Dateizeile: antippen = erledigt bzw. wieder offen (44 pt Trefferflaeche)
struct ModuleFileDoneToggle: View {
    let moduleID: Int
    let f: JSONValue
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    /// sofort zeigen, bis die Seite neu geladen ist
    @State private var shown: Bool?

    var body: some View {
        let done = shown ?? ModuleDoneAction.isDone(f)
        Button {
            let next = !done
            shown = next
            Task { await ModuleDoneAction.send(session, toast, router, moduleID: moduleID, ids: [f.s("id") ?? ""], done: next) }
        } label: {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(done ? UF.ok : UF.muted)
                .frame(width: 30, height: 30)
                .ufHitArea()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Erledigt: \(f.s("ai_title") ?? f.s("name") ?? "Datei")")
        .accessibilityValue(done ? "abgehakt" : "offen")
        .accessibilityAddTraits(done ? .isSelected : [])
        .help(done ? "Als offen markieren" : "Als erledigt abhaken")
        .onChange(of: ModuleDoneAction.isDone(f)) { _, _ in shown = nil }
    }
}

/// Wochenkopf rechts: Fortschritt ("5/8 erledigt") und Knopf "Woche erledigt" (sind alle abgehakt, nimmt er alle Haken
/// wieder weg)
struct ModuleWeekDoneButton: View {
    let moduleID: Int
    let w: JSONValue
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    /// iPhone (13.11.2026): nur das Zeichen, sonst bricht "Woche erledigt" im schmalen Wochenkopf Buchstabe fuer
    /// Buchstabe um; die Beschriftung fuer VoiceOver bleibt
    @Environment(\.ufCompact) private var compact

    var body: some View {
        let p = ModuleDoneAction.progress(w)
        let all = p.total > 0 && p.done == p.total
        HStack(spacing: 8) {
            if p.done > 0 {
                Text(ModuleDoneAction.text(p)).ufFont(12.8, all ? 600 : 400).monospacedDigit()
                    .foregroundStyle(all ? UF.okText : UF.muted)
            }
            Button {
                let ids = ModuleDoneAction.files(w).compactMap { $0.s("id") }
                Task {
                    await ModuleDoneAction.send(session, toast, router, moduleID: moduleID, ids: ids, done: !all,
                                                message: all ? "Haken der Woche entfernt" : "Woche erledigt")
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: all ? "checkmark.circle.fill" : "checkmark.circle").font(.system(size: 14, weight: .medium))
                    if !compact { Text("Woche erledigt").ufFont(13.12, 550).lineLimit(1).fixedSize() }
                }
                .foregroundStyle(all ? UF.okText : UF.text)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: UF.rSm).fill(all ? UF.okSoft : .clear))
                .ufHitArea()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Woche erledigt")
            .accessibilityValue(all ? "alle abgehakt" : ModuleDoneAction.text(p))
            .accessibilityHint(all ? "Nimmt alle Haken dieser Woche weg" : "Hakt alle Dateien dieser Woche ab")
            .accessibilityAddTraits(all ? .isSelected : [])
        }
    }
}

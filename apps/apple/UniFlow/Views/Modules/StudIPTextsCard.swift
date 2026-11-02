import SwiftUI
import UniFlowCore

// "Aus Stud.IP" in der Modulansicht (Uebersicht): ein einziger, standardmaessig zugeklappter Bereich mit einer kurzen
// Zeile je Quelle (Courseware · Wiki · Forum, Anzahl, zuletzt geaendert). Antippen einer Zeile zeigt die Eintraege,
// ein Eintrag oeffnet einen einfachen Leser (Text, Herkunft, "In Stud.IP öffnen"). Daten: GET /api/modules/{id}/studip
// und /api/studip-texts/{id} (StudIPTexts, nur lokal). Ohne Eintraege erscheint der Bereich nicht. Die Fristen der
// Courseware-Aufgaben stehen nicht hier, sondern wo Fristen schon stehen ("Abgaben & Prüfungen", Planer).

/// Texte und Formatierung an einer Stelle (Tests)
enum StudIPTextsText {
    static let title = "Aus Stud.IP"
    static let readerOpen = "In Stud.IP öffnen"
    static let icons = ["courseware": "book", "wiki": "file-text", "forum": "users"]

    /// "Courseware · 3 · geändert Fr., 31.10."
    static func line(_ g: JSONValue) -> String {
        var s = "\(g.s("label") ?? "") · \(g.i("count") ?? 0)"
        if let c = g.s("changed"), !c.isEmpty { s += " · geändert \(UFFmt.short(c))" }
        return s
    }

    /// Kopfzeile zugeklappt: "Courseware 3 · Wiki 2 · Forum 1"
    static func summary(_ groups: [JSONValue]) -> String {
        groups.map { "\($0.s("label") ?? "") \($0.i("count") ?? 0)" }.joined(separator: " · ")
    }
}

struct StudIPTextsCard: View {
    let moduleID: Int
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @State private var groups: [JSONValue] = []
    @State private var expanded = false
    @State private var openKind: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 0)
            if !groups.isEmpty { card.padding(.bottom, 14.4) }
        }
        .task(id: moduleID) { await load() }
        .ufReload { await load() }
    }

    private func load() async {
        guard let api = session.api, api.isLocal, let v = try? await api.value("/api/modules/\(moduleID)/studip") else { return }
        groups = v.list("groups")
    }

    private var card: some View {
        UFCard {
            Button { withAnimation(UF.motion(.default)) { expanded.toggle() } } label: {
                HStack(spacing: 9.6) {
                    UFIcon(expanded ? "chevron-down" : "chevron-right", size: 16).foregroundStyle(UF.text)
                    Text(StudIPTextsText.title).ufFont(15.2, 650, em: -0.01).foregroundStyle(UF.text)
                    Spacer(minLength: 8)
                    if !expanded {
                        Text(StudIPTextsText.summary(groups)).ufFont(12.8).foregroundStyle(UF.muted).lineLimit(1)
                    }
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("studip.texts.toggle")
            .accessibilityHint(expanded ? "Zuklappen" : "Courseware, Wiki und Forum aus Stud.IP zeigen")
            if expanded {
                let rows = Row.rows(groups)
                ForEach(rows) { r in group(r.value).ufBorderBottom(r.id != rows.last?.id) }
            }
        }
        .accessibilityIdentifier("studip.texts.card")
    }

    @ViewBuilder private func group(_ g: JSONValue) -> some View {
        let kind = g.s("kind") ?? ""
        let open = openKind == kind
        VStack(alignment: .leading, spacing: 0) {
            Button { openKind = open ? nil : kind } label: {
                HStack(spacing: 9.6) {
                    UFIcon(StudIPTextsText.icons[kind] ?? "file", size: 15).foregroundStyle(UF.text2)
                    Text(StudIPTextsText.line(g)).ufFont(13.6).foregroundStyle(UF.text).frame(maxWidth: .infinity, alignment: .leading)
                    UFIcon(open ? "chevron-down" : "chevron-right", size: 13).foregroundStyle(UF.muted)
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("studip.texts.group.\(kind)")
            if open {
                ForEach(Row.rows(g.list("items"))) { r in item(r.value) }
            }
        }
    }

    private func item(_ x: JSONValue) -> some View {
        Button { overlay.modal { StudIPTextReader(id: x.s("id") ?? "") } } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(x.s("title") ?? "").ufFont(13.6, 550).foregroundStyle(UF.text).lineLimit(1)
                Text([x.s("course_title"), x.s("changed").map { UFFmt.short($0) }].compactMap { $0 }.joined(separator: " · "))
                    .ufFont(12).foregroundStyle(UF.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 25).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("studip.texts.item.\(x.s("id") ?? "")")
    }
}

/// Einfacher Leser fuer einen Stud.IP-Text (nur Text, ohne Formatierung) mit Link zur Seite in Stud.IP
struct StudIPTextReader: View {
    let id: String
    @EnvironmentObject private var session: Session
    @Environment(\.ufClose) private var close
    @Environment(\.openURL) private var openURL
    @State private var d: JSONValue?
    @State private var error: String?

    var body: some View {
        UFDialog(d?.s("title") ?? StudIPTextsText.title, icon: StudIPTextsText.icons[d?.s("kind") ?? ""] ?? "file-text") {
            VStack(alignment: .leading, spacing: 9.6) {
                if let d {
                    Text([d.s("kind_label"), d.s("course_title"), d.s("changed").map { "geändert " + UFFmt.short($0) }].compactMap { $0 }
                        .joined(separator: " · ")).ufFont(12.16).foregroundStyle(UF.muted)
                    ScrollView {
                        Text(d.s("text") ?? "").ufFont(14).foregroundStyle(UF.text).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 460)
                } else if let error {
                    Text(error).ufFont(13.12).foregroundStyle(UF.muted)
                } else {
                    UFSkeleton().frame(height: 120)
                }
            }
            .frame(minWidth: 320)
        } foot: {
            if let u = d?.s("url").flatMap(UFDayExtras.safeURL) {
                UFButton(StudIPTextsText.readerOpen, icon: "arrow-right") { openURL(u) }
            }
            UFButton("Schließen", kind: .primary) { close() }
        }
        .task(id: id) {
            guard let api = session.api else { return }
            do { d = try await api.value("/api/studip-texts/\(id)") } catch { self.error = error.localizedDescription }
        }
    }
}

import SwiftUI
import UniFlowCore

// "Aus Stud.IP" in der Modulansicht (Uebersicht): ein einziger, standardmaessig zugeklappter Bereich mit einer kurzen
// Zeile je Quelle (Courseware · Wiki · Forum, Anzahl, zuletzt geaendert). Antippen einer Zeile zeigt die Eintraege,
// ein Eintrag oeffnet einen einfachen Leser (Text, Herkunft, "In Stud.IP öffnen"). Daten: GET /api/modules/{id}/studip
// und /api/studip-texts/{id} (StudIPTexts, nur lokal). Ohne Eintraege erscheint der Bereich nicht. Die Fristen der
// Courseware-Aufgaben stehen nicht hier, sondern wo Fristen schon stehen ("Abgaben & Prüfungen", Planer).
// Seit 03.11.2026 dazu "Blubber" (Kurs-Chats, StudIPBlubber, nur lokal): je Thread eine Zeile mit dem neuesten Beitrag,
// der Leser zeigt die Beitraege der Reihe nach mit Rolle statt Name (GET /api/studip/blubber?module=, /api/studip/blubber/{id}).

/// Texte und Formatierung an einer Stelle (Tests)
enum StudIPTextsText {
    static let title = "Aus Stud.IP"
    static let readerOpen = "In Stud.IP öffnen"
    static let icons = ["courseware": "book", "wiki": "file-text", "forum": "users", "blubber": "note"]
    static let blubberLabel = "Blubber"

    /// Bereich "Blubber" wie die Gruppen von /api/modules/{id}/studip; nil ohne Threads
    static func blubberGroup(_ v: JSONValue?) -> JSONValue? {
        let threads = v?.list("threads") ?? []
        guard !threads.isEmpty else { return nil }
        let changed = threads.compactMap { $0.s("changed") }.max() ?? ""
        return ["kind": "blubber", "label": .string(blubberLabel), "count": .number(Double(threads.count)),
                "changed": changed.isEmpty ? .null : .string(changed), "items": .array(threads)]
    }

    /// Zweite Zeile eines Threads: "Analysis I · 3 neu · Mo., 02.11."
    static func threadDetail(_ t: JSONValue) -> String {
        var parts = [t.s("course_title") ?? ""]
        if let n = t.i("new_count"), n > 0 { parts.append("\(n) neu") }
        if let c = t.s("changed") { parts.append(UFFmt.short(c)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

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
    @State private var texts: [JSONValue] = []
    @State private var blubber: JSONValue?
    private var groups: [JSONValue] { texts + [StudIPTextsText.blubberGroup(blubber)].compactMap { $0 } }
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
        guard let api = session.api, api.isLocal else { return }
        if let v = try? await api.value("/api/modules/\(moduleID)/studip") { texts = v.list("groups") }
        blubber = try? await api.value("/api/studip/blubber?module=\(moduleID)")
    }

    private var card: some View {
        UFCard {
            Button { UFMotion.toggle { expanded.toggle() } } label: {
                HStack(spacing: 9.6) {
                    UFIcon("chevron-right", size: 16).foregroundStyle(UF.muted).rotationEffect(.degrees(expanded ? 90 : 0))   // dreht beim Aufklappen
                    Text(StudIPTextsText.title).ufFont(15.2, 650, em: -0.01).foregroundStyle(UF.text)
                    Spacer(minLength: 8)
                    if !expanded {
                        Text(StudIPTextsText.summary(groups)).ufFont(12.8).foregroundStyle(UF.muted).lineLimit(1)
                    }
                }
                .padding(.vertical, 8)                                      // Kopfzeile mindestens 44 pt hoch
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("studip.texts.toggle")
            .accessibilityHint(expanded ? "Zuklappen" : "Courseware, Wiki, Forum und Blubber aus Stud.IP zeigen")
            if expanded {
                let rows = Row.rows(groups)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { r in group(r.value).ufBorderBottom(r.id != rows.last?.id) }
                }
                .ufReveal()
            }
        }
        .accessibilityIdentifier("studip.texts.card")
    }

    @ViewBuilder private func group(_ g: JSONValue) -> some View {
        let kind = g.s("kind") ?? ""
        let open = openKind == kind
        VStack(alignment: .leading, spacing: 0) {
            Button { UFMotion.toggle { openKind = open ? nil : kind } } label: {
                HStack(spacing: 9.6) {
                    UFIcon(StudIPTextsText.icons[kind] ?? "file", size: 15).foregroundStyle(UF.text2)
                    Text(StudIPTextsText.line(g)).ufFont(13.6).monospacedDigit().foregroundStyle(UF.text).frame(maxWidth: .infinity, alignment: .leading)
                    UFIcon("chevron-right", size: 13).foregroundStyle(UF.muted).rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.vertical, 11)                                     // Zeile mindestens 44 pt hoch
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("studip.texts.group.\(kind)")
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Row.rows(g.list("items"))) { r in kind == "blubber" ? AnyView(thread(r.value)) : AnyView(item(r.value)) }
                }
                .ufReveal()
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
            .padding(.leading, 25).padding(.vertical, 7.2)
            .contentShape(Rectangle())
        }
        .buttonStyle(ModuleRowPressStyle())
        .accessibilityIdentifier("studip.texts.item.\(x.s("id") ?? "")")
    }
}

extension StudIPTextsCard {
    /// Ein Blubber-Thread: neuester Beitrag (Rolle: Text), darunter Kurs, Zahl neuer Beitraege, Tag
    func thread(_ t: JSONValue) -> some View {
        Button { overlay.modal { StudIPBlubberReader(id: t.s("id") ?? "") } } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(t.s("preview") ?? "").ufFont(13.6, 550).foregroundStyle(UF.text).lineLimit(1)
                Text(StudIPTextsText.threadDetail(t)).ufFont(12).foregroundStyle(UF.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 25).padding(.vertical, 7.2)
            .contentShape(Rectangle())
        }
        .buttonStyle(ModuleRowPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Blubber: \(t.s("preview") ?? "") · \(StudIPTextsText.threadDetail(t))")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("studip.blubber.thread.\(t.s("id") ?? "")")
    }
}

/// Leser fuer einen Blubber-Thread: Beitraege der Reihe nach (aelteste zuerst) mit Rolle statt Name, Tag und Uhrzeit,
/// dazu "In Stud.IP öffnen". Nur lesen; Studora markiert in Stud.IP nichts als gesehen.
struct StudIPBlubberReader: View {
    let id: String
    @EnvironmentObject private var session: Session
    @Environment(\.ufClose) private var close
    @Environment(\.openURL) private var openURL
    @State private var d: JSONValue?
    @State private var error: String?

    /// "Lehrende · Mo., 02.11. 09:30"
    static func head(_ c: JSONValue) -> String {
        var s = c.s("role") ?? ""
        if let at = c.s("posted_at"), at.count >= 16 { s += " · \(UFFmt.short(at)) \(at.dropFirst(11).prefix(5))" }
        return s
    }

    var body: some View {
        UFDialog(d.map { "Blubber · \($0.s("course_title") ?? "")" } ?? StudIPTextsText.blubberLabel, icon: StudIPTextsText.icons["blubber"] ?? "note") {
            VStack(alignment: .leading, spacing: 9.6) {
                if let d {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Row.rows(d.list("comments"))) { r in
                                VStack(alignment: .leading, spacing: 2.4) {
                                    Text(Self.head(r.value)).ufFont(12, 600).foregroundStyle(UF.text2)
                                    Text(r.value.s("text") ?? "").ufFont(14, lh: 1.55).foregroundStyle(UF.text).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: 640, alignment: .leading)
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 460)
                    Text("Nur die neuesten Beiträge, ohne Namen; Studora markiert in Stud.IP nichts als gelesen.")
                        .ufFont(12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                } else if let error {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        UFIcon("alert", size: 14).foregroundStyle(UF.bad)
                        Text(error).ufFont(13.12).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                    }
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
            do { d = try await api.value("/api/studip/blubber/\(id)") } catch { self.error = error.localizedDescription }
        }
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
                    // Lesetext: Grundschrift mit grosszuegigem Zeilenabstand, Zeilen hoechstens etwa 75 Zeichen lang
                    ScrollView {
                        Text(d.s("text") ?? "").ufFont(14.5, lh: 1.65).foregroundStyle(UF.text).textSelection(.enabled)
                            .frame(maxWidth: 640, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 460)
                } else if let error {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        UFIcon("alert", size: 14).foregroundStyle(UF.bad)
                        Text(error).ufFont(13.12).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                    }
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

import SwiftUI
import UniFlowCore

// Schwarzes Brett aus Stud.IP unter "Uni & Noten" (Auftrag des Inhabers 03.11.2026: "mit einbinden, wenn eine Uni das
// hat"). Eine ruhige Karte, nur wenn die Hochschule das Brett hat und Anzeigen gespeichert sind: Themen-Chips mit
// Anzahl, Liste der Anzeigen (ganzer Titel, Thema, Tag, ganzer Text; nie "…", Inhaber 03.11.2026), Antippen oeffnet
// einen einfachen Leser mit "In Stud.IP öffnen" (wie der Leser der Stud.IP-Texte). Daten: GET /api/studip/bulletin und
// /api/studip/bulletin/{id} (StudIPBulletin, nur lokal, keine Autoren). Auf dem PC-Server gibt es den Endpunkt nicht;
// dann bleibt die Karte weg.

/// Texte und Formatierung an einer Stelle (Tests)
enum BulletinText {
    static let title = "Schwarzes Brett"
    static let readerOpen = "In Stud.IP öffnen"
    static let all = "Alle"
    static let icon = "note"
    static let shown = 8

    /// "Schwarzes Brett: 5 neue Anzeigen" fuer die Karte "Neuigkeiten"
    static func newLine(_ n: Int) -> String { "\(title): \(n) neue \(n == 1 ? "Anzeige" : "Anzeigen")" }

    /// "Anzeige: Fahrrad zu verkaufen · Biete · Mo., 02.11."
    static func accessibility(_ e: JSONValue) -> String {
        ["Anzeige: " + (e.s("title") ?? ""), e.s("topic") ?? "", e.s("posted_at").map { UFFmt.short($0) } ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func filtered(_ entries: [JSONValue], _ topic: String) -> [JSONValue] {
        topic.isEmpty ? entries : entries.filter { $0.s("topic") == topic }
    }
}

struct BulletinCard: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @Environment(\.openURL) private var openURL
    @State private var data: JSONValue?
    @State private var topic = ""
    @State private var expanded = false

    private var entries: [JSONValue] { data?.list("entries") ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 0)
            if data?["available"]?.bool == true, !entries.isEmpty { card.padding(.top, 16) }
        }
        .task { await load() }
        .ufReload { await load() }
    }

    private func load() async {
        guard let api = session.api, api.isLocal, let v = try? await api.value("/api/studip/bulletin") else { return }
        data = v
    }

    private var card: some View {
        let topics = data?.list("topics") ?? []
        let shown = BulletinText.filtered(entries, topic)
        let rows = Row.rows(Array(expanded ? shown : Array(shown.prefix(BulletinText.shown))))
        return UFCard {
            UFCardHead(BulletinText.title, icon: BulletinText.icon, wrap: true) {
                if let u = data?.s("url").flatMap(UFDayExtras.safeURL) {
                    UFButton(BulletinText.readerOpen, icon: "arrow-right", size: .small) { openURL(u) }
                }
            }
            UFFlexWrap(gap: 6.4) {
                UFChip(text: "\(BulletinText.all) \(entries.count)", on: topic.isEmpty) { select("") }
                    .accessibilityIdentifier("bulletin.topic.alle")
                ForEach(Row.rows(topics, key: "title")) { t in
                    let name = t.value.s("title") ?? ""
                    UFChip(text: "\(name) \(t.value.i("count") ?? 0)", on: topic == name) { select(name) }
                        .accessibilityIdentifier("bulletin.topic.\(name)")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Themen")
            .padding(.bottom, 6.4)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { r in entry(r.value).ufBorderBottom(r.id != rows.last?.id) }
            }
            if shown.count > BulletinText.shown {
                Button(expanded ? "Weniger anzeigen" : "Alle \(shown.count) anzeigen") { UFMotion.toggle { expanded.toggle() } }
                    .ufFont(13.12).foregroundStyle(UF.accentText).buttonStyle(.plain)
                    .padding(.top, 9.6).frame(minHeight: 44)
                    .accessibilityIdentifier("bulletin.more")
            }
            Text("Kleinanzeigen aus dem Schwarzen Brett in Stud.IP, nur auf diesem Gerät gespeichert; Namen der Anbietenden holt StudiNow nicht.")
                .ufFont(11.84).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 9.6).padding(.bottom, 5.6)
        }
        .accessibilityIdentifier("bulletin.card")
    }

    private func select(_ name: String) {
        UFMotion.toggle { topic = name; expanded = false }
    }

    private func entry(_ e: JSONValue) -> some View {
        Button { overlay.modal { BulletinReader(id: e.s("id") ?? "") } } label: {
            VStack(alignment: .leading, spacing: 3.2) {
                // ganzer Titel und ganzer Text, umbrechend, nie "…" (Inhaber 03.11.2026)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(e.s("title") ?? "").ufFont(14.5, 550).foregroundStyle(UF.text)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(e.s("posted_at").map { UFFmt.short($0) } ?? "").ufFont(12.16).foregroundStyle(UF.muted).fixedSize()
                }
                UFBadge(e.s("topic") ?? "", tone: .neutral).padding(.top, 1.6)
                if let text = e.s("text"), !text.isEmpty {
                    Text(text).ufFont(12.8, lh: 1.5).foregroundStyle(UF.text2)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 640, alignment: .leading)
                        .padding(.top, 2.4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)                                           // Zeile mindestens 44 pt hoch
            .contentShape(Rectangle())
        }
        .buttonStyle(ModuleRowPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(BulletinText.accessibility(e))
        .accessibilityValue(e.s("text") ?? "")                          // ganzer Text auch fuer VoiceOver
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Anzeige lesen")
        .accessibilityIdentifier("bulletin.entry.\(e.s("id") ?? "")")
    }
}

/// Einfacher Leser fuer eine Anzeige (nur Text) mit Link zur Anzeige in Stud.IP
struct BulletinReader: View {
    let id: String
    @EnvironmentObject private var session: Session
    @Environment(\.ufClose) private var close
    @Environment(\.openURL) private var openURL
    @State private var d: JSONValue?
    @State private var error: String?

    var body: some View {
        UFDialog(d?.s("title") ?? BulletinText.title, icon: BulletinText.icon) {
            VStack(alignment: .leading, spacing: 9.6) {
                if let d {
                    Text([d.s("topic"), d.s("posted_at").map { UFFmt.date($0) }].compactMap { $0 }.joined(separator: " · "))
                        .ufFont(12.16).foregroundStyle(UF.muted)
                    ScrollView {
                        UFLongText(text: d.s("text") ?? "")                 // sehr lange Texte in Abschnitten
                            .frame(maxWidth: 640, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 460)
                    Text("Antworten und Kontakt über die Anzeige in Stud.IP.")
                        .ufFont(11.84).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
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
                UFButton(BulletinText.readerOpen, icon: "arrow-right") { openURL(u) }
            }
            UFButton("Schließen", kind: .primary) { close() }
        }
        .task(id: id) {
            guard let api = session.api else { return }
            do { d = try await api.value("/api/studip/bulletin/\(id)") } catch { self.error = error.localizedDescription }
        }
    }
}

import SwiftUI
import UIKit
import UniFlowCore

// Termin-Detail (06.11.2026, Auftrag des Inhabers): Stundenplan oder Lernkalender -> Termin antippen -> im Termin-Panel
// (`EventDrawer`, ohne Serie `DatedEventDialog`) stehen der Raum und alle Lehrenden des Kurses.
// - Raum (LUH): Antippen loest ihn im Raumfinder auf (GET /api/rooms/resolve) und startet sofort die Route zu Fuss in
//   Google Maps (App `comgooglemaps://` mit directionsmode=walking, sonst Webadresse mit travelmode=walking); nicht
//   eindeutig -> Raumfinder mit vorbelegter Suche. Daneben "Im Raumfinder anzeigen" (Etage, Gebaeude, Adresse).
//   Uni Hildesheim (07.11.2026): genauso ueber den Raumplan des LSF (Raumcode "HC.I.1.Hörsaal 1" -> Gebaeudetabelle, Route
//   ohne Anfrage). HsH (kein Raumfinder): Raum als Text und "In Karten suchen" (Standort der Hochschule).
// - Lehrende (nur LUH, Stud.IP): alle Dozent/innen des Kurses, Tutor/innen zugeklappt; fehlen sie noch, werden sie fuer
//   diesen Kurs nachgeladen (`StudIPSync.loadLecturers`). E-Mail antippen -> neue Uni-Mail an diese Person, Betreff
//   "Frage zu <Kurs>", gesendet erst mit "Senden" vom eigenen Uni-Postfach (SOGo). "Allen Lehrenden schreiben": alle
//   Adressen in "An". Uni-Mail nicht verbunden -> zuerst "Uni-Mail verbinden" (sonst Mail-App), ohne Adresse
//   "Nachricht in Stud.IP". Regeln im Kern (`TerminDetail`), gleich in app/static/termin-detail-logic.js.

enum TerminDetailText {
    static let room = "Raum"
    static let rooms = "Räume"
    static let routeSub = "Route zu Fuß in Google Maps"
    static let showInFinder = "Im Raumfinder anzeigen"
    static let searchMaps = "In Karten suchen"
    static let lecturers = "Lehrende"
    static let writeAll = "Allen Lehrenden schreiben"
    static let toModule = "Zum Modul"
    static let loading = "Lehrende werden geladen …"
    static let connectTitle = "Uni-Mail ist nicht verbunden"
    static let connectMessage = "Mit Uni-Mail schreibst du direkt aus StudiNow von deinem Uni-Postfach aus. Gesendet wird erst mit „Senden“."
    static let connect = "Uni-Mail verbinden"
    static let mailApp = "Mit der Mail-App schreiben"

    static func routeLabel(_ room: String) -> String { "Raum \(room), Route zu Fuß starten" }
    static func finderLabel(_ room: String) -> String { "Raum \(room) im Raumfinder anzeigen" }
    static func mapsLabel(_ room: String) -> String { "Raum \(room) in Karten suchen" }
    static func tutors(_ n: Int) -> String { "Tutor/innen (\(n))" }
}

/// Links oeffnen (Google Maps, mailto:); Tests zeichnen auf statt zu oeffnen
@MainActor
enum TerminOpen {
    static var handler: ((URL) -> Void)?
    static func open(_ url: URL) {
        if let handler { handler(url) } else { RoomUI.open(url) }
    }
}

/// Raum und Lehrende eines Termins (Termin-Panel und Einzeltermin)
struct TerminDetailSections: View {
    /// Vorkommen bzw. Serie: room, course_id, module_id
    let event: JSONValue
    let title: String
    /// Raum nur als Text (Uni-Kalender einer Hochschule ohne Raumfinder)
    var roomAsText = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let room = event.s("room"), !TerminDetail.rooms(room).isEmpty {
                TerminRoomSection(text: room, plain: roomAsText)
            }
            TerminLecturersSection(event: event, title: title)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("termin.detail")
    }
}

/// Ueberschrift eines Bereichs im Termin-Detail
private struct TerminSectionHead<Trailing: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        UFFlexWrap(gap: 8, rowGap: 6) {
            HStack(spacing: 7.2) { UFIcon(icon, size: 16); Text(title) }
                .ufFont(15.2, 650, em: -0.01).foregroundStyle(UF.text)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            trailing
        }
    }
}

// MARK: - Raum

struct TerminRoomSection: View {
    let text: String
    var plain = false
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    /// Hochschule mit Raumfinder (LUH)? nil = noch unbekannt (GET /api/rooms/campuses, ohne Netz)
    @State private var finder: Bool?
    @State private var busy: String?
    @State private var search: RoomQuery?
    @State private var details: RoomQuery?
    /// iPhone: "Im Raumfinder anzeigen" und "In Karten suchen" in voller Breite (Daumen)
    @Environment(\.ufCompact) private var compact

    struct RoomQuery: Identifiable { let text: String; var id: String { text } }

    var body: some View {
        let rooms = TerminDetail.rooms(text)
        VStack(alignment: .leading, spacing: 8) {
            TerminSectionHead(title: rooms.count > 1 ? TerminDetailText.rooms : TerminDetailText.room, icon: "map-pin") { EmptyView() }
            ForEach(Array(rooms.enumerated()), id: \.offset) { _, r in row(r) }
        }
        .task(id: session.api?.base) { await loadFinder() }
        .sheet(item: $search) { q in TerminRoomFinderSheet(query: q.text) }
        .sheet(item: $details) { q in RoomResolveSheet(text: q.text, api: session.api) }
    }

    @ViewBuilder private func row(_ r: TerminDetail.Room) -> some View {
        if r.link && finder == true && !plain {
            VStack(alignment: .leading, spacing: 4) {
                Button { Task { await route(r.text) } } label: {
                    HStack(spacing: 10) {
                        UFIcon("map-pin", size: 18).foregroundStyle(UF.accentText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.text).ufFont(15, 650).foregroundStyle(UF.text).multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(TerminDetailText.routeSub).ufFont(12.5).foregroundStyle(UF.muted)
                        }
                        Spacer(minLength: 6)
                        if busy == r.text { ProgressView() } else { UFIcon("arrow-right", size: 16).foregroundStyle(UF.accentText) }
                    }
                    .padding(.vertical, 10).padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface))
                    .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(UF.line, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: UF.r))
                }
                .buttonStyle(.plain)
                .disabled(busy != nil)
                .accessibilityLabel(TerminDetailText.routeLabel(r.text))
                .accessibilityHint("Öffnet Google Maps mit der Route zu Fuß")
                .accessibilityIdentifier("termin.room.route")
                Group {
                    if compact {
                        UFWideButton(TerminDetailText.showInFinder, icon: "layers", kind: .ghost) { details = RoomQuery(text: r.text) }
                    } else {
                        UFButton(TerminDetailText.showInFinder, icon: "layers", kind: .ghost, size: .small) { details = RoomQuery(text: r.text) }
                    }
                }
                .accessibilityLabel(TerminDetailText.finderLabel(r.text))
                .accessibilityIdentifier("termin.room.finder")
            }
        } else {
            UFFlexWrap(gap: 8, rowGap: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    UFIcon(r.link ? "map-pin" : "info", size: 14).foregroundStyle(UF.muted)
                    Text(r.text).ufFont(14.5, 600).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(r.link ? "Raum \(r.text)" : r.text)
                if r.link && finder == false {
                    Group {
                        if compact {
                            UFWideButton(TerminDetailText.searchMaps, icon: "search") { Task { await searchMaps(r.text) } }
                        } else {
                            UFButton(TerminDetailText.searchMaps, icon: "search", size: .small) { Task { await searchMaps(r.text) } }
                        }
                    }
                    .disabled(busy != nil)
                    .accessibilityLabel(TerminDetailText.mapsLabel(r.text))
                    .accessibilityIdentifier("termin.room.maps")
                }
            }
            .accessibilityIdentifier("termin.room.text")
        }
    }

    private func loadFinder() async {
        guard finder == nil, let api = session.api else { return }
        finder = (try? await api.value("/api/rooms/campuses"))?["finder"]?.bool ?? false
    }

    private func resolve(_ text: String) async -> JSONValue? {
        guard let api = session.api else { return nil }
        busy = text
        defer { busy = nil }
        return (try? await api.value(RoomUI.path(text: text)))?.list("parts").first
    }

    /// Antippen: aufloesen, gefunden -> Route zu Fuss sofort; sonst Raumfinder mit vorbelegter Suche
    private func route(_ text: String) async {
        let part = await resolve(text) ?? ["text": .string(text), "status": "none"]
        switch TerminDetail.route(part, appInstalled: RoomUI.googleAppInstalled) {
        case .route(let s): if let u = URL(string: s) { TerminOpen.open(u) }
        case .search(let q): search = RoomQuery(text: q.isEmpty ? text : q)
        case .none: break
        }
    }

    /// HsH (ohne Raumfinder): Standort bzw. Adresse der Hochschule in Google Maps (Suche, keine Route)
    private func searchMaps(_ text: String) async {
        let part = await resolve(text)
        if let u = RoomUI.googleURL(part?["maps"], route: false, appInstalled: RoomUI.googleAppInstalled) {
            TerminOpen.open(u)
        } else {
            toast.show("Der Ort ließ sich nicht suchen.")
        }
    }
}

/// Raumfinder als Blatt mit vorbelegter Suche (Raum nicht eindeutig aufgeloest)
struct TerminRoomFinderSheet: View {
    let query: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            RoomFinderPage(initialQuery: query)
                .background(UF.bg)
                .navigationTitle("Raumfinder")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() }.accessibilityIdentifier("termin.finder.done") } }
        }
        .accessibilityIdentifier("termin.finder")
    }
}

// MARK: - Lehrende

struct TerminLecturersSection: View {
    let event: JSONValue
    let title: String
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var studip: StudIPSync
    @EnvironmentObject private var toast: UFToastCenter
    @Environment(\.uniMail) private var uniMail
    @State private var data: JSONValue?
    @State private var loading = false
    @State private var tutorsOpen = false
    @State private var compose: UniMailComposeRequest?
    @State private var pending: UniMailComposeRequest?
    @State private var askConnect = false
    @State private var login = false
    @State private var message: LecturerMessageRequest?
    /// iPhone: "Allen Lehrenden schreiben" in voller Breite unter der Ueberschrift statt daneben
    @Environment(\.ufCompact) private var compact

    /// Tests: Nachladen eines Kurses ohne Stud.IP-Sitzung (sonst `StudIPSync.loadLecturers`)
    static var fetchOverride: ((String) async -> Void)?
    /// je Kurs hoechstens ein Nachladen je App-Start (der Kern ruht danach 7 Tage)
    static var tried: Set<String> = []

    private var available: Bool { data?["available"]?.bool == true }
    private var people: [JSONValue] { available ? data?.list("people") ?? [] : [] }

    var body: some View {
        let g = TerminDetail.groups(people)
        let all = TerminDetail.recipients(people)
        VStack(alignment: .leading, spacing: 0) {
            if available, !people.isEmpty || loading || data?.s("hint") != nil {
                TerminSectionHead(title: TerminDetailText.lecturers, icon: "users") {
                    if all.count > 1, !compact {
                        UFButton(TerminDetailText.writeAll, icon: "mail", size: .small) { write(all, person: nil) }
                            .accessibilityHint("Neue E-Mail an alle \(all.count) Lehrenden")
                            .accessibilityIdentifier("termin.lecturers.all")
                    }
                }
                .padding(.bottom, 2)
                if all.count > 1, compact {
                    UFWideButton(TerminDetailText.writeAll, icon: "mail") { write(all, person: nil) }
                        .accessibilityHint("Neue E-Mail an alle \(all.count) Lehrenden")
                        .accessibilityIdentifier("termin.lecturers.all")
                        .padding(.vertical, 6)
                }
                if loading && people.isEmpty {
                    HStack(spacing: 8) { ProgressView(); Text(TerminDetailText.loading) }
                        .ufFont(13.12).foregroundStyle(UF.muted).padding(.vertical, 8)
                } else if people.isEmpty, let hint = data?.s("hint") {
                    Text(hint).ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true).padding(.vertical, 6)
                }
                rows(g.lecturers)
                if !g.tutors.isEmpty {
                    DisclosureGroup(isExpanded: $tutorsOpen) {
                        rows(g.tutors)
                    } label: {
                        Text(TerminDetailText.tutors(g.tutors.count)).ufFont(14, 650).foregroundStyle(UF.text2)
                            .frame(minHeight: 44, alignment: .leading)
                    }
                    .tint(UF.text2)
                    .accessibilityIdentifier("termin.tutors")
                }
            }
        }
        .task(id: TerminDetail.lecturersQuery(event) ?? "") { await load() }
        .sheet(item: $compose) { req in
            if let c = uniMail { UniMailComposeSheet(connection: c, request: req) { sent in if sent { toast.show("Gesendet.") } } }
        }
        .background {
            Color.clear
                .sheet(isPresented: $login, onDismiss: afterLogin) { if let c = uniMail { UniMailLoginView(connection: c) } }
                // Abgleich ausdruecklich ins Fenster (Mac "Designed for iPad": fehlte sonst, wie in LecturerList)
                .sheet(item: $message) { req in MessageReplyEntry(original: req.original, mode: .sender).environmentObject(studip) }
        }
        .confirmationDialog(TerminDetailText.connectTitle, isPresented: $askConnect, titleVisibility: .visible) {
            Button(TerminDetailText.connect) { login = true }
            Button(TerminDetailText.mailApp) { mailto(pending); pending = nil }
            Button("Abbrechen", role: .cancel) { pending = nil }
        } message: {
            Text(TerminDetailText.connectMessage)
        }
        .accessibilityIdentifier("termin.lecturers")
    }

    @ViewBuilder private func rows(_ list: [JSONValue]) -> some View {
        let rs = Row.rows(list)
        ForEach(rs) { r in
            LecturerRow(person: r.value, onMail: { write([$0], person: r.value) },
                        onMessage: { message = LecturerMessageRequest(person: r.value, module: title) })
                .ufBorderBottom(r.id != rs.last?.id)
        }
    }

    private func load() async {
        guard let api = session.api, api.isLocal, let q = TerminDetail.lecturersQuery(event) else { return }
        let path = "/api/lecturers?\(q)"
        data = try? await api.value(path)
        // noch nie geladen: die Lehrenden dieses Kurses jetzt holen (nur LUH, nur mit Stud.IP-Sitzung)
        guard available, data?["loaded"]?.bool == false, let course = event.s("course_id"), !course.isEmpty,
              !Self.tried.contains(course) else { return }
        Self.tried.insert(course)
        loading = true
        if let f = Self.fetchOverride { await f(course) } else { await studip.loadLecturers(courseID: course) }
        if let fresh = try? await api.value(path) { data = fresh }
        loading = false
    }

    private var mailState: TerminDetail.UniMailState {
        guard let uniMail else { return .none }
        return uniMail.isConnected ? .connected : .disconnected
    }

    private func write(_ to: [String], person: JSONValue?) {
        var req = UniMailComposeRequest()
        req.to = to.joined(separator: ", ")
        req.subject = TerminDetail.subject(title)
        switch TerminDetail.mailChoice(to, uniMail: mailState) {
        case .compose: compose = req
        case .connect: pending = req; askConnect = true
        case .mailto: mailto(req)
        case .studip: if let person { message = LecturerMessageRequest(person: person, module: title) }
        }
    }

    private func mailto(_ req: UniMailComposeRequest?) {
        guard let req, let to = req.to else { return }
        let list = to.components(separatedBy: ",")
        if let s = TerminDetail.mailto(list, subject: req.subject ?? ""), let u = URL(string: s) { TerminOpen.open(u) }
    }

    /// nach der Anmeldung bei Uni-Mail gleich weiter zum Schreibfenster
    private func afterLogin() {
        guard let p = pending else { return }
        pending = nil
        if uniMail?.isConnected == true { compose = p }
    }
}

import SafariServices
import SwiftUI
import UIKit
import UniFlowCore

// Raumfinder (05.11.2026, docs/RAUMFINDER-2026-11-05.md): Seite "Raumfinder" (Gruppe "Alltag") mit Suche im Standortfinder
// der LUH (Raum, Gebaeude, Einrichtung), Ergebnisliste und Detail mit Raumplan (In-App-Browser), Barrierefreiheit und
// automatisch einem Link zu Google Maps ("In Google Maps öffnen", "Route" zu Fuss, "In Apple Karten"). Ueberall, wo ein Raum
// steht (Stundenplan, Lernkalender, Klausuren, Modul), macht `UFRoomLink` den Text antippbar und loest ihn ueber
// GET /api/rooms/resolve auf (lokal: Rooms/LocalRooms.swift mit Cache; am eigenen PC app/rooms_api.py).
// HsH und Uni Hildesheim: Standort der Hochschule mit Adresse ("Ort laut Hochschule; genaue Lage ohne Gewähr").
// Datenschutz: An Google geht nichts von selbst, erst beim Antippen eines Karten-Links. Frei in jedem Tarif.

// MARK: - Karten oeffnen

enum RoomUI {
    /// Google Maps: die App, wenn installiert (`comgooglemaps://`, LSApplicationQueriesSchemes), sonst die Webadresse
    static func googleURL(_ maps: JSONValue?, route: Bool, appInstalled: Bool) -> URL? {
        let key = (appInstalled ? "google_app" : "google") + (route ? "_route" : "")
        return maps?[key]?.string.flatMap(URL.init(string:))
    }

    static func appleURL(_ maps: JSONValue?, route: Bool = false) -> URL? {
        maps?[route ? "apple_route" : "apple"]?.string.flatMap(URL.init(string:))
    }

    @MainActor static var googleAppInstalled: Bool {
        URL(string: "comgooglemaps://").map { UIApplication.shared.canOpenURL($0) } ?? false
    }

    /// Erst hier geht etwas an Google bzw. Apple (nach Antippen)
    @MainActor static func open(_ url: URL?) {
        guard let url else { return }
        UIApplication.shared.open(url)
    }

    static func icon(_ type: String?) -> String {
        switch type {
        case "room": return "map-pin"
        case "facility": return "book"
        case "campus": return "graduation"
        default: return "home"
        }
    }

    /// Ueberschrift je Ergebnis einer aufgeloesten Angabe
    static func statusText(_ part: JSONValue) -> String? {
        switch part.s("status") {
        case "online": return "Online-Termin – kein Ort."
        case "offline", "not_found", "unknown", "ambiguous", "building", "campus", "search": return part.s("note")
        default: return nil
        }
    }

    static func path(text: String) -> String { "/api/rooms/resolve?text=\(PyText.quote(text, safe: ""))" }
}

/// Raumplan und Gebaeudeinfo der LUH (info.cafm.uni-hannover.de) im In-App-Browser
struct RoomSafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

struct RoomWebTarget: Identifiable { let url: URL; var id: String { url.absoluteString } }

// MARK: - Karten-Knoepfe

struct RoomMapsButtons: View {
    let maps: JSONValue?
    var compact = false
    /// iPhone (docs/IPHONE-2026-11-04.md): "In Google Maps öffnen" und "Route" in voller Breite untereinander (Daumen),
    /// Apple Karten darunter als schlichter Knopf; iPad wie bisher in einer Reihe
    @Environment(\.ufCompact) private var phone

    var body: some View {
        if maps != nil, phone {
            VStack(spacing: 8) {
                UFWideButton("In Google Maps öffnen", icon: "map-pin", kind: .primary) {
                    RoomUI.open(RoomUI.googleURL(maps, route: false, appInstalled: RoomUI.googleAppInstalled))
                }
                .accessibilityIdentifier("rooms.maps.google")
                UFWideButton("Route", icon: "arrow-right") {
                    RoomUI.open(RoomUI.googleURL(maps, route: true, appInstalled: RoomUI.googleAppInstalled))
                }
                .accessibilityLabel("Route zu Fuß in Google Maps")
                .accessibilityIdentifier("rooms.maps.route")
                UFWideButton("In Apple Karten", kind: .ghost) { RoomUI.open(RoomUI.appleURL(maps)) }
                    .accessibilityIdentifier("rooms.maps.apple")
            }
            .frame(maxWidth: .infinity)
        } else if maps != nil {
            UFFlexWrap(gap: 8) {
                UFButton("In Google Maps öffnen", icon: "map-pin", kind: .primary, size: compact ? .small : .regular) {
                    RoomUI.open(RoomUI.googleURL(maps, route: false, appInstalled: RoomUI.googleAppInstalled))
                }
                .accessibilityIdentifier("rooms.maps.google")
                UFButton("Route", icon: "arrow-right", size: compact ? .small : .regular) {
                    RoomUI.open(RoomUI.googleURL(maps, route: true, appInstalled: RoomUI.googleAppInstalled))
                }
                .accessibilityLabel("Route zu Fuß in Google Maps")
                .accessibilityIdentifier("rooms.maps.route")
                UFButton("In Apple Karten", size: compact ? .small : .regular) { RoomUI.open(RoomUI.appleURL(maps)) }
                    .accessibilityIdentifier("rooms.maps.apple")
            }
        }
    }
}

// MARK: - Detail eines Orts

struct RoomPlaceView: View {
    let place: JSONValue
    var attribution: String?
    @State private var web: RoomWebTarget?
    /// iPhone: Raumplan und Gebaeudeinfo als Zeilen in voller Breite statt kleiner Knoepfe im Fluss
    @Environment(\.ufCompact) private var compact

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    UFIcon(RoomUI.icon(place.s("type")), size: 20).foregroundStyle(UF.accent)
                    Text(place.s("title") ?? "").ufFont(20, 700).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                if let sub = place.s("subtitle"), !sub.isEmpty {
                    Text(sub).ufFont(13.5).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let note = place.s("note") {
                HStack(alignment: .top, spacing: 8) { UFIcon("info", size: 15); Text(note).ufFont(13).fixedSize(horizontal: false, vertical: true) }
                    .foregroundStyle(UF.warnText).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UF.warnSoft)).accessibilityElement(children: .combine)
            }
            RoomMapsButtons(maps: place["maps"])
            section("Angaben") {
                row("Gebäude", place.s("building").map { b in "\(b)" + (place.s("building_name").map { " (\($0))" } ?? "") })
                row("Etage", place.s("floor_label").map { l in l + (place.s("floor").map { " (Etage \($0))" } ?? "") })
                row("Raum", place.s("room").map { r in r + (place.s("room_name").map { " – \($0)" } ?? "") })
                row("Adresse", place["address"]?.s("line"))
                if let d = place.s("description") { Text(d).ufFont(13.5).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true) }
            }
            let links: [(String, String, String)] = [("Raumplan ansehen", "floorplan_url", "rooms.floorplan"),
                                                     ("Raum im Gebäudeinfo der LUH", "room_url", "rooms.roominfo"),
                                                     ("Gebäudeinfo der LUH", "building_url", "rooms.buildinginfo"),
                                                     ("Website", "website", "rooms.website"),
                                                     ("Öffnungszeiten", "opening_hours_url", "rooms.hours")]
            let shown = links.filter { place.s($0.1).flatMap(URL.init(string:)) != nil }
            if !shown.isEmpty, compact {
                VStack(spacing: 8) {
                    ForEach(shown, id: \.1) { l in
                        UFWideButton(l.0, icon: l.1 == "floorplan_url" ? "layers" : "file-text") {
                            web = place.s(l.1).flatMap(URL.init(string:)).map(RoomWebTarget.init)
                        }
                        .accessibilityIdentifier(l.2)
                    }
                }
            } else if !shown.isEmpty {
                UFFlexWrap(gap: 8) {
                    ForEach(shown, id: \.1) { l in
                        UFButton(l.0, icon: l.1 == "floorplan_url" ? "layers" : "file-text", kind: .ghost, size: .small) {
                            web = place.s(l.1).flatMap(URL.init(string:)).map(RoomWebTarget.init)
                        }
                        .accessibilityIdentifier(l.2)
                    }
                }
            }
            accessibility
            if let attribution {
                Text("\(attribution). Angaben ohne Gewähr.").ufFont(12.5).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(item: $web) { t in RoomSafariView(url: t.url).ignoresSafeArea() }
        .accessibilityIdentifier("rooms.place")
    }

    @ViewBuilder private var accessibility: some View {
        let rows = place["accessibility"]?.list("building") ?? [] , roomRows = place["accessibility"]?.list("room") ?? []
        if place.s("source") == "standortfinder" {
            section("Barrierefreiheit") {
                if rows.isEmpty && roomRows.isEmpty {
                    Text("Keine Angaben zur Barrierefreiheit im Standortfinder.").ufFont(13.5).foregroundStyle(UF.text2)
                } else {
                    ForEach(Array((rows + roomRows).enumerated()), id: \.offset) { _, r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text([r.s("title"), r.s("status").map { "(\($0))" }].compactMap { $0 }.joined(separator: " "))
                                .ufFont(13.5, 600).foregroundStyle(UF.text)
                            if let t = r.s("text") { Text(t).ufFont(13).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true) }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    @ViewBuilder private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(label).ufFont(13.5).foregroundStyle(UF.muted).frame(width: compact ? 68 : 80, alignment: .leading)
                Text(value).ufFont(13.5, 600).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).ufFont(15, 650).foregroundStyle(UF.text).accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface))
        .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(UF.line, lineWidth: 1))
    }
}

/// Blatt mit einem Ort (aus der Suche)
struct RoomDetailSheet: View {
    let place: JSONValue
    var attribution: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.ufCompact) private var compact

    var body: some View {
        NavigationStack {
            ScrollView {
                RoomPlaceView(place: place, attribution: attribution)
                    .padding(compact ? 16 : 20).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
            }
            .background(UF.bg)
            .navigationTitle(compact ? "Ort" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() }.accessibilityIdentifier("rooms.detail.done") } }
        }
        // iPhone: von unten halb (Name, Karten-Knoepfe) und ganz (Angaben, Raumplan, Barrierefreiheit)
        .ufHalfSheet(when: compact)
        .accessibilityIdentifier("rooms.detail")
    }
}

// MARK: - Raumangabe aufloesen (Stundenplan, Lernkalender, Klausuren)

struct RoomResolveSheet: View {
    let text: String
    let api: APIClient?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.ufCompact) private var compact
    @State private var result: JSONValue?
    @State private var error: String?
    @State private var chosen: [Int: JSONValue] = [:]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Ort für „\(text)“").ufFont(13.5).foregroundStyle(UF.muted)
                    if let error {
                        UFEmpty(icon: "alert", text: error) { UFButton("Erneut versuchen", icon: "refresh") { Task { await load() } } }
                    } else if let result {
                        if let msg = result.s("message") {
                            Text(msg).ufFont(13).foregroundStyle(UF.warnText).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UF.warnSoft))
                        }
                        ForEach(Array(result.list("parts").enumerated()), id: \.offset) { i, part in partView(i, part) }
                        if let a = result["source"]?.s("attribution") {
                            Text("\(a). Angaben ohne Gewähr.").ufFont(12.5).foregroundStyle(UF.muted)
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(30)
                    }
                }
                .padding(compact ? 16 : 20).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
            }
            .background(UF.bg)
            .navigationTitle("Raum")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() }.accessibilityIdentifier("rooms.resolve.done") } }
        }
        .task { await load() }
        .ufHalfSheet(when: compact)                                  // iPhone: von unten, halb und ganz
        .accessibilityIdentifier("rooms.resolve")
    }

    private func load() async {
        guard let api else { error = "Keine Verbindung zur App-Datenquelle."; return }
        do {
            result = try await api.value(RoomUI.path(text: text))
            error = nil
        } catch {
            self.error = "Der Ort konnte nicht geladen werden."
        }
    }

    @ViewBuilder private func partView(_ i: Int, _ part: JSONValue) -> some View {
        let parts = result?.list("parts").count ?? 1
        VStack(alignment: .leading, spacing: 10) {
            if parts > 1 { Text(part.s("text") ?? "").ufFont(15, 650).foregroundStyle(UF.text) }
            if let place = chosen[i] ?? part["place"].flatMap({ $0.isNull ? nil : $0 }) {
                if part.s("status") != "found", let note = RoomUI.statusText(part), chosen[i] == nil {
                    Text(note).ufFont(13).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                }
                RoomPlaceView(place: place)
            } else {
                if let note = RoomUI.statusText(part) {
                    Text(note).ufFont(13.5).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(part.list("candidates").enumerated()), id: \.offset) { _, c in
                    Button { chosen[i] = c } label: { RoomResultRow(place: c) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("rooms.candidate")
                }
                if part.s("status") != "online" {
                    if !part.list("candidates").isEmpty { Text("Oder nach dem Text suchen:").ufFont(13).foregroundStyle(UF.muted) }
                    RoomMapsButtons(maps: part["maps"], compact: true)
                }
            }
        }
    }
}

/// Raumangabe als Link: Stecknadel und Text; Antippen zeigt den Ort mit Google-Maps-Link. "Online" bleibt Text.
struct UFRoomLink: View {
    let text: String
    var size: CGFloat = 13.12
    var color: Color = UF.accentText
    @State private var open = false

    var body: some View {
        if Rooms.mayLink(text) {
            Button { open = true } label: {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    UFIcon("map-pin", size: size)
                    Text(text).ufFont(size, 600).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(color)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Raum \(text)")
            .accessibilityHint("Zeigt den Ort mit Link zu Google Maps")
            .accessibilityIdentifier("room.link")
            .sheet(isPresented: $open) { RoomResolveHost(text: text) }
        } else {
            Text(text).ufFont(size).foregroundStyle(UF.text2)
        }
    }
}

/// Blatt mit der Sitzung erst beim Oeffnen (der Link selbst braucht keine; Bildvergleiche ohne `Session` bleiben heil)
struct RoomResolveHost: View {
    let text: String
    @EnvironmentObject private var session: Session
    var body: some View { RoomResolveSheet(text: text, api: session.api) }
}

// MARK: - Seite "Raumfinder"

struct RoomResultRow: View {
    let place: JSONValue

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            UFIcon(RoomUI.icon(place.s("type")), size: 18).foregroundStyle(UF.accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(place.s("title") ?? "").ufFont(14.5, 650).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                if let s = place.s("subtitle"), !s.isEmpty {
                    Text(s).ufFont(12.8).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            UFIcon("chevron-right", size: 14).foregroundStyle(UF.muted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface))
        .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(UF.line, lineWidth: 1))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

struct RoomFinderPage: View {
    @EnvironmentObject private var session: Session
    /// iPhone: Suchfeld und "Suchen" in voller Breite untereinander, Beispiele als waagerecht scrollende Reihe
    @Environment(\.ufCompact) private var compact
    @State private var query = ""
    @State private var result: JSONValue?
    @State private var campuses: JSONValue?
    @State private var loading = false
    @State private var error: String?
    @State private var detail: RoomDetailItem?

    struct RoomDetailItem: Identifiable { let place: JSONValue; var id: String { place.s("id") ?? UUID().uuidString } }

    static let examples = ["F102", "1101", "Hauptgebäude", "Bibliothek", "Audimax"]

    var body: some View {
        UFContent(maxWidth: 1000) {
            UFPageHead("Raumfinder", sub: "Räume, Gebäude und Einrichtungen finden – mit Link zu Google Maps")
            searchBar
            if let error {
                UFCard { UFEmpty(icon: "alert", text: error) { UFButton("Erneut versuchen", icon: "refresh") { Task { await search() } } } }
            }
            if let r = result { results(r) } else if loading { ProgressView().frame(maxWidth: .infinity).padding(30) }
            if let c = campuses { campusList(c) }
            Text("Suche: \(Rooms.source.s("name") ?? "Standortfinder"). Die Karten-Links öffnen Google Maps oder Apple Karten erst, wenn du sie antippst.")
                .ufFont(12.5).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 14)
        }
        .task(id: session.api?.base) { await loadCampuses() }
        .sheet(item: $detail) { d in RoomDetailSheet(place: d.place, attribution: Rooms.source.s("attribution")) }
        .accessibilityIdentifier("rooms.page")
    }

    private var searchField: some View {
        UFInputBox(focused: false) {
            TextField(compact ? "Raum, Gebäude, Einrichtung" : "Raum, Gebäude oder Einrichtung (z. B. F102, 1101, Bibliothek)", text: $query)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { Task { await search() } }
                .accessibilityIdentifier("rooms.search")
        }
    }

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if compact {
                searchField.frame(maxWidth: .infinity)
                UFWideButton("Suchen", icon: "search", kind: .primary) { Task { await search() } }
                    .accessibilityIdentifier("rooms.search.go")
            } else {
                HStack(spacing: 10) {
                    searchField
                    UFButton("Suchen", icon: "search", kind: .primary) { Task { await search() } }
                        .accessibilityIdentifier("rooms.search.go")
                }
            }
            if result == nil, compact {
                UFCompactScrollRow {
                    ForEach(Self.examples, id: \.self) { e in
                        UFButton(e, size: .small) { query = e; Task { await search() } }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Beispiele")
            } else if result == nil {
                UFFlexWrap(gap: 8) {
                    ForEach(Self.examples, id: \.self) { e in
                        UFButton(e, size: .small) { query = e; Task { await search() } }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Beispiele")
            }
        }
        .padding(.bottom, 14)
    }

    @ViewBuilder private func results(_ r: JSONValue) -> some View {
        let items = r.list("items")
        VStack(alignment: .leading, spacing: 8) {
            if let m = r.s("message") {
                Text(m).ufFont(13).foregroundStyle(UF.warnText).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UF.warnSoft))
            }
            let count = r.i("count") ?? 0
            Text(count == 0 ? "Keine Treffer für „\(r.s("query") ?? "")“." : count == 1 ? "1 Treffer" : "\(count) Treffer")
                .ufFont(13.5, 600).foregroundStyle(UF.text2)
                .accessibilityIdentifier("rooms.count")
            ForEach(Array(items.enumerated()), id: \.offset) { _, p in
                Button { detail = RoomDetailItem(place: p) } label: { RoomResultRow(place: p) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("rooms.result")
            }
            if (r.i("pages") ?? 0) > (r.i("page") ?? 0) + 1 {
                if compact {
                    UFWideButton("Weitere Treffer laden", icon: "chevron-down") { Task { await search(page: (r.i("page") ?? 0) + 1) } }
                } else {
                    UFButton("Weitere Treffer laden", icon: "chevron-down") { Task { await search(page: (r.i("page") ?? 0) + 1) } }
                }
            }
        }
        .padding(.bottom, 14)
    }

    @ViewBuilder private func campusList(_ c: JSONValue) -> some View {
        UFCard {
            UFCardHead(c["finder"]?.bool == true ? "Standorte der Leibniz Universität Hannover" : "Standorte: \(c.s("name") ?? "")", icon: "graduation")
            VStack(alignment: .leading, spacing: 12) {
                if let note = c.s("note") {
                    Text("\(c.s("name") ?? "") hat keinen öffentlichen Raumfinder. \(note).").ufFont(13).foregroundStyle(UF.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(c.list("campuses").enumerated()), id: \.offset) { _, p in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(p.s("title") ?? "").ufFont(14.5, 650).foregroundStyle(UF.text)
                        Text(p["address"]?.s("line") ?? "").ufFont(13).foregroundStyle(UF.text2)
                        RoomMapsButtons(maps: p["maps"], compact: true)
                    }
                    .accessibilityIdentifier("rooms.campus")
                }
            }
        }
    }

    private func loadCampuses() async {
        guard let api = session.api else { return }
        campuses = try? await api.value("/api/rooms/campuses")
    }

    private func search(page: Int = 0) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let api = session.api else { return }
        loading = true
        defer { loading = false }
        do {
            let r = try await api.value("/api/rooms/search?q=\(PyText.quote(q, safe: ""))&page=\(page)")
            if page > 0, var old = result {
                old["items"] = .array(old.list("items") + r.list("items"))
                old["page"] = r["page"] ?? .null
                result = old
            } else {
                result = r
            }
            error = nil
        } catch {
            self.error = "Die Suche ist gerade nicht möglich. Versuche es später erneut."
        }
    }
}

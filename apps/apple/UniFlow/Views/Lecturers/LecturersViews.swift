import SwiftUI
import UniFlowCore

// Lehrende und Kontakte (LUH, Stud.IP), 06.11.2026, docs/LEHRENDE-KONTAKTE-2026-11-06.md. Auftrag des Inhabers: E-Mails
// der Lehrenden finden, die man ueber Stud.IP sehen kann; HsH und LSF in einer spaeteren Version.
// - Modulseite (Uebersicht): Bereich "Lehrende" (Name, Rolle, E-Mail, Sprechstunde, Raum), nur an der LUH und nur mit
//   Eintraegen (sonst nichts, kein Platzhalter)
// - Seite "Lehrende" (#/lehrende): alle Lehrenden der eigenen Kurse, Suche nach Name oder Modul; erreichbar von Uni-Mail
//   und der Modulseite
// Antippen der E-Mail: neue E-Mail in Uni-Mail mit dem Empfaenger (ohne Uni-Mail: mailto:); "Nachricht in Stud.IP"
// oeffnet das Schreibfenster der Stud.IP-Nachrichten (`MessageReplySheet` mit festem Empfaenger). Raeume in der
// Sprechstunde fuehren zum Raumfinder (`UFRoomLink`). Daten: GET /api/lecturers (`StudIPLecturers`, nur auf dem Geraet).

/// Texte und Regeln an einer Stelle (Tests)
enum LecturersText {
    static let title = "Lehrende"
    static let pageSub = "Lehrende und Tutor/innen deiner Kurse aus Stud.IP – mit E-Mail und Sprechstunde"
    static let search = "Suchen (Name oder Modul)"
    static let allButton = "Alle Lehrenden"
    static let studipMessage = "Nachricht in Stud.IP"
    static let office = "Sprechstunde"
    static let privacy = "Aus Stud.IP, so wie du es dort siehst. Die Angaben bleiben auf diesem iPad."
    static let notAvailable = "Lehrende mit E-Mail und Sprechstunde gibt es vorerst für die Leibniz Universität Hannover (Stud.IP)."

    /// Zweite Zeile: "Dozent/in · Analysis I – Vorlesung, Analysis I – Übung" (in einem Modul nur die Rolle und die Funktion)
    static func detail(_ p: JSONValue, showCourses: Bool) -> String {
        var parts = [p.s("role_label") ?? ""]
        if let l = p.s("label"), !l.isEmpty { parts.append(l) }
        if showCourses {
            let names = p.list("courses").compactMap { c -> String? in
                let m = c.s("module_name") ?? ""
                return m.isEmpty ? c.s("title") : m
            }
            var seen = Set<String>()
            let unique = names.filter { !$0.isEmpty && seen.insert($0).inserted }
            if !unique.isEmpty { parts.append(unique.joined(separator: ", ")) }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Zeilen der Sprechstunde (jede fuer sich ein Raum-Link, wenn sie einen Raum nennt)
    static func officeLines(_ s: String?) -> [String] {
        (s ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Nennt eine Zeile der Sprechstunde einen Raum oder ein Gebaeude der LUH? (`Rooms.parse`, wie im Stundenplan)
    static func namesRoom(_ line: String) -> Bool { Rooms.parse(line, university: "luh")["linkable"]?.bool == true }

    /// Bedienungshilfe der Zeile: "Prof. Dr. Erika Beispiel, Dozent/in, E-Mail erika.beispiel@example.org, Sprechstunde Di 10–11 Uhr"
    static func accessibility(_ p: JSONValue) -> String {
        var parts = [p.s("name") ?? "", p.s("role_label") ?? ""]
        if let e = p.s("email"), !e.isEmpty { parts.append("E-Mail \(e)") } else { parts.append(StudIPLecturers.noEmail) }
        let office = officeLines(p.s("office_hours")).joined(separator: ", ")
        if !office.isEmpty { parts.append("\(Self.office) \(office)") }
        if let l = p.s("location"), !l.isEmpty { parts.append(l.lowercased().hasPrefix("raum") ? l : "Raum \(l)") }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// Betreff einer neuen Nachricht: "Frage zu Analysis I"
    static func subject(_ p: JSONValue, module: String? = nil) -> String {
        if let m = module, !m.isEmpty { return "Frage zu \(m)" }
        let c = p.list("courses").first
        let name = (c?.s("module_name")).flatMap { $0.isEmpty ? nil : $0 } ?? c?.s("title") ?? ""
        return name.isEmpty ? "" : "Frage zu \(name)"
    }
}

/// Was das Antippen der E-Mail-Adresse tut: neue E-Mail in Uni-Mail (verbunden) oder mailto: (sonst)
enum LecturerMailAction: Equatable {
    case uniMail(String)
    case mailto(URL)

    static func choose(email: String, uniMailConnected: Bool) -> LecturerMailAction? {
        let e = email.trimmingCharacters(in: .whitespaces)
        guard !e.isEmpty else { return nil }
        if uniMailConnected { return .uniMail(e) }
        return URL(string: "mailto:" + (e.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? e)).map { .mailto($0) }
    }
}

/// Neue Stud.IP-Nachricht (Identifiable fuer das Blatt)
struct LecturerMessageRequest: Identifiable {
    let original: MessageReplyOriginal
    var id: String { original.localID }

    init(person p: JSONValue, module: String? = nil) {
        original = .direct(to: StudIPPerson(id: p.s("id") ?? "", name: p.s("name") ?? StudIPLecturers.unknownName),
                           username: p.s("username") ?? "", subject: LecturersText.subject(p, module: module))
    }
}

// MARK: - Zeile

struct LecturerRow: View {
    let person: JSONValue
    var showCourses = false
    let onMail: (String) -> Void
    let onMessage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(person.s("name") ?? "").ufFont(15, 650).foregroundStyle(UF.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            let detail = LecturersText.detail(person, showCourses: showCourses)
            if !detail.isEmpty {
                Text(detail).ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            }
            if let email = person.s("email"), !email.isEmpty {
                Button { onMail(email) } label: {
                    HStack(spacing: 6) {
                        UFIcon("mail", size: 14)
                        Text(email).ufFont(13.6, 600).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(UF.accentText)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("E-Mail an \(email)")
                .accessibilityHint("Öffnet eine neue E-Mail an diese Adresse")
                .accessibilityIdentifier("lecturer.email")
            } else {
                Text(StudIPLecturers.noEmail).ufFont(12.8).foregroundStyle(UF.muted).accessibilityIdentifier("lecturer.noEmail")
            }
            let office = LecturersText.officeLines(person.s("office_hours"))
            if !office.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(LecturersText.office).ufFont(12, 650).foregroundStyle(UF.text2)
                    ForEach(Array(office.enumerated()), id: \.offset) { _, line in
                        // Zeilen mit Raum oder Gebaeude fuehren zum Raumfinder, Zeiten bleiben Text
                        if LecturersText.namesRoom(line) { UFRoomLink(text: line, size: 12.8) } else {
                            Text(line).ufFont(12.8).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .accessibilityIdentifier("lecturer.office")
            }
            if let loc = person.s("location"), !loc.isEmpty {
                UFRoomLink(text: loc, size: 12.8).accessibilityIdentifier("lecturer.room")
            }
            if let inst = person.s("institute"), !inst.isEmpty {
                Text(inst).ufFont(12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            }
            UFButton(LecturersText.studipMessage, icon: "message", size: .small, action: onMessage)
                .padding(.top, 4)
                .accessibilityIdentifier("lecturer.studipMessage")
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(LecturersText.accessibility(person))
        .accessibilityIdentifier("lecturer.row")
    }
}

/// Liste mit den Kontakt-Wegen (Uni-Mail bzw. mailto:, Stud.IP-Nachricht)
struct LecturerList: View {
    let people: [JSONValue]
    var showCourses = false
    var module: String?
    @Environment(\.uniMail) private var uniMail
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var toast: UFToastCenter
    @State private var compose: UniMailComposeRequest?
    @State private var message: LecturerMessageRequest?

    var body: some View {
        let rows = Row.rows(people)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { r in
                LecturerRow(person: r.value, showCourses: showCourses,
                            onMail: { mail($0, person: r.value) },
                            onMessage: { message = LecturerMessageRequest(person: r.value, module: module) })
                    .ufBorderBottom(r.id != rows.last?.id)
            }
        }
        .sheet(item: $compose) { req in
            if let c = uniMail { UniMailComposeSheet(connection: c, request: req) { sent in if sent { toast.show("Gesendet.") } } }
        }
        .sheet(item: $message) { req in MessageReplyEntry(original: req.original, mode: .sender) }
    }

    private func mail(_ email: String, person: JSONValue) {
        switch LecturerMailAction.choose(email: email, uniMailConnected: uniMail?.isConnected == true) {
        case .uniMail(let to)?:
            var r = UniMailComposeRequest()
            r.to = to
            r.subject = LecturersText.subject(person, module: module)
            compose = r
        case .mailto(let url)?: openURL(url)
        case nil: break
        }
    }
}

// MARK: - Modulseite

/// Bereich "Lehrende" in der Uebersicht eines Moduls; ohne Eintraege oder an HsH/Hildesheim unsichtbar
struct ModuleLecturersCard: View {
    let moduleID: Int
    var moduleName: String?
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var router: UFRouter
    @State private var data: JSONValue?
    /// eingeklappt (Wunsch des Inhabers 07.11.2026), je Modul gemerkt
    @AppStorage("module.lecturers.open") private var openIDs = ""

    private var people: [JSONValue] { data?["available"]?.bool == true ? data?.list("people") ?? [] : [] }
    private var open: Bool { openIDs.split(separator: ",").contains(Substring(String(moduleID))) }

    private func toggle() {
        var ids = Set(openIDs.split(separator: ",").map(String.init))
        if open { ids.remove(String(moduleID)) } else { ids.insert(String(moduleID)) }
        withAnimation(UF.motion(.easeOut(duration: 0.18))) { openIDs = ids.sorted().joined(separator: ",") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 0)
            if !people.isEmpty {
                UFCard {
                    HStack(spacing: 10) {
                        Button(action: toggle) {
                            HStack(spacing: 8) {
                                UFIcon("users", size: 18).foregroundStyle(UF.text2)
                                Text(LecturersText.title).ufFont(16, 700).foregroundStyle(UF.text)
                                Text("\(people.count)").ufFont(12.8, 600).foregroundStyle(UF.muted)
                                    .padding(.horizontal, 7).padding(.vertical, 1).background(Capsule().fill(UF.surface2))
                                Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(UF.muted)
                                Spacer(minLength: 0)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(open ? "Lehrende einklappen" : "Lehrende ausklappen (\(people.count))")
                        .accessibilityIdentifier("lecturers.toggle")
                        UFButton(LecturersText.allButton, icon: "arrow-right", size: .small) { router.go(.lecturers) }
                            .accessibilityIdentifier("lecturers.all")
                    }
                    if open {
                        LecturerList(people: people, module: moduleName)
                        Text(LecturersText.privacy).ufFont(11.5).foregroundStyle(UF.muted).padding(.top, 6)
                    }
                }
                .accessibilityIdentifier("lecturers.card")
                .padding(.bottom, 14.4)
            }
        }
        .task(id: moduleID) { await load() }
        .ufReload { await load() }
    }

    private func load() async {
        guard let api = session.api, api.isLocal else { return }
        data = try? await api.value("/api/lecturers?module_id=\(moduleID)")
    }
}

// MARK: - Seite "Lehrende"

struct LecturersPage: View {
    @EnvironmentObject private var session: Session
    @State private var data: JSONValue?
    @State private var query = ""
    @State private var error: String?

    var body: some View {
        UFContent(maxWidth: 1000) {
            UFPageHead(LecturersText.title, sub: LecturersText.pageSub)
            if let error {
                UFCard { UFEmpty(icon: "alert", text: error) }
            } else if let d = data {
                if d["available"]?.bool != true {
                    UFCard { UFEmpty(icon: "users", text: LecturersText.notAvailable) }
                        .accessibilityIdentifier("lecturers.unavailable")
                } else {
                    UFTextInput(LecturersText.search, text: $query)
                        .frame(maxWidth: 420)
                        .padding(.bottom, 12)
                        .accessibilityIdentifier("lecturers.search")
                    let people = d.list("people")
                    UFCard {
                        if people.isEmpty {
                            UFEmpty(icon: "users", text: d.s("hint") ?? StudIPLecturers.unknownName, small: true)
                                .accessibilityIdentifier("lecturers.hint")
                        } else {
                            Text(Self.countLine(d)).ufFont(12.5, 600).foregroundStyle(UF.muted)
                                .accessibilityIdentifier("lecturers.count")
                            LecturerList(people: people, showCourses: true)
                        }
                    }
                    Text(LecturersText.privacy).ufFont(12).foregroundStyle(UF.muted).padding(.top, 8)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(30)
            }
        }
        .task(id: query) {
            if data != nil { try? await Task.sleep(nanoseconds: 250_000_000) }      // Tippen: kurz warten
            guard !Task.isCancelled else { return }
            await load()
        }
        .ufReload { await load() }
        .accessibilityIdentifier("lecturers.page")
    }

    /// "12 Lehrende" bzw. "3 von 12 Lehrenden"
    static func countLine(_ d: JSONValue) -> String {
        let n = d.i("count") ?? 0, total = d.i("total") ?? n
        return n == total ? "\(n) \(n == 1 ? "Person" : "Personen")" : "\(n) von \(total) Personen"
    }

    private func load() async {
        guard let api = session.api else { error = "Nicht verbunden."; return }
        guard api.isLocal else { data = ["available": false]; return }
        let q = query.trimmingCharacters(in: .whitespaces)
        let path = "/api/lecturers" + (q.isEmpty ? "" : "?q=" + (q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""))
        do {
            data = try await api.value(path)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

import SwiftUI
import QuickLook
import UniFlowCore

// Uni & Noten 1:1 nach viewServices() und credDialog() in app/static/views-misc.js.
// Bewusst anders (WEB-IPAD-PARITAET.md, W.B.9.1): Auf dem iPad wird kein Passwort eingegeben oder gespeichert.
// Universitaet Hildesheim ohne PC (lokales Backend): dieselben Kennzahlen und Uni-Dienste, dazu der Notenspiegel aus
// dem LSF (nur die Leistungstabelle, HildesheimSync) und die Karte "Learnweb & LSF" statt der Zugaenge der LUH.

/// Uni & Noten: Kennzahlen, Notenspiegel (QIS), Bescheinigungen, Stundenplan-Status, Zugaenge, Uni-Dienste.
struct ServicesPage: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var shell: ShellState
    @Environment(\.ufWindowWidth) private var windowWidth
    @Environment(\.openURL) private var openURL
    @Environment(\.hildesheim) private var hildesheim
    @State private var svc: JSONValue?
    @State private var grades: JSONValue = .null
    @State private var tt: JSONValue?
    @State private var error: String?
    @State private var preview: URL?

    /// CRED_LIST
    static let credList: [(key: String, name: String)] = [
        ("studip", "Stud.IP / WebSSO"), ("qis", "QIS (Prüfungsverwaltung)"), ("idm", "IDM Account-Manager"), ("ilias", "ILIAS"),
        ("mail", "E-Mail (LUIS)"), ("matrix", "Matrix-Chat"), ("luhki", "LUHKI"), ("gitlab", "GitLab"),
    ]
    static func credName(_ k: String) -> String { credList.first { $0.key == k }?.name ?? k }

    var body: some View {
        Group {
            if let svc { content(svc) } else if let error { UFContent(maxWidth: 1120) { UFEmpty(icon: "alert", text: error) } } else {
                UFContent(maxWidth: 1120) { UFSkeleton().frame(width: 280, height: 28).padding(.bottom, 16); UFSkeleton().frame(height: 300) }
            }
        }
        .task { await load() }
        .ufReload { await load() }
        .quickLookPreview($preview)
    }

    private func load() async {
        guard let api = session.api else { error = "Nicht mit dem Server verbunden."; return }
        do {
            async let s = api.value("/api/services")
            async let g = api.value("/api/grades")
            let (sv, gv) = try await (s, g)
            tt = try? await api.value("/api/timetable/auto-status")      // .catch(() => null)
            grades = gv
            svc = sv
            error = nil
        } catch { if svc == nil { self.error = error.localizedDescription } }
    }

    /// String(zahl) wie in JavaScript: ganze Zahlen ohne ".0"
    static func js(_ d: Double) -> String { d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : "\(d)" }

    /// toLocaleDateString("de-DE") ohne Optionen: T.M.JJJJ
    static func plainDate(_ s: String?) -> String {
        guard let d = Fmt.date(s) else { return s ?? "" }
        let c = Fmt.calendar.dateComponents([.day, .month, .year], from: d)
        return "\(c.day ?? 0).\(c.month ?? 0).\(c.year ?? 0)"
    }

    @ViewBuilder private func content(_ svc: JSONValue) -> some View {
        let g = grades
        let rows = g.list("grades")
        let last = g["last_run"].flatMap { $0.isNull ? nil : $0 }
        let lastOK = (last?.i("ok") ?? 0) == 1 || last?["ok"]?.bool == true
        let creds = svc["credentials"] ?? .null
        let qis = creds["qis"] ?? .null
        let cols = windowWidth <= 820 ? 1 : windowWidth <= 1100 ? 2 : 3
        // Uni Hildesheim auf dem Geraet: Notenspiegel aus dem LSF, Zugaenge ueber Learnweb & LSF
        let lsf = session.api?.isLocal == true ? hildesheim : nil
        UFContent(maxWidth: 1120) {
            UFPageHead("Uni & Noten", sub: lsf == nil
                       ? "Alle Dienste der Leibniz Universität an einem Ort, Notenspiegel direkt in der App."
                       : "Alle Dienste der Universität Hildesheim an einem Ort, Notenspiegel aus dem LSF direkt in der App.")
            UFGrid(columns: 3) {
                UFCard { UFKPI(value: g.n("average").map { Self.js($0).replacingOccurrences(of: ".", with: ",") } ?? "–",
                               label: "Notendurchschnitt" + ((g.n("credits") ?? 0) != 0 ? " · \(Self.js(g.n("credits") ?? 0)) LP" : "")) }
                UFCard { UFKPI(value: "\(rows.count)", label: "Leistungen im Notenspiegel" + ((g.i("passed") ?? 0) != 0 ? " · \(g.i("passed") ?? 0) bestanden" : "")) }
                UFCard { UFKPI(value: last.map { Self.plainDate($0.s("finished_at")) } ?? "–",
                               label: last == nil ? "noch nicht abgerufen" : lastOK ? "zuletzt abgerufen" : "letzter Abruf fehlgeschlagen") }
            }
            .padding(.bottom, 19.2)

            ServicesSpanLayout(columns: cols) {
                if let lsf {
                    LSFGradesCard(connection: lsf, rows: rows, last: last, lastOK: lastOK).environment(\.ufFillsCell, true)
                    VStack(alignment: .leading, spacing: 8) {                              // .stack
                        lsfTimetableCard
                        HildesheimSourcesCard()
                    }
                } else {
                    gradesCard(rows: rows, last: last, lastOK: lastOK, qis: qis).environment(\.ufFillsCell, true)
                    VStack(alignment: .leading, spacing: 8) {                              // .stack
                        timetableCard
                        credentialsCard(creds)
                    }
                }
            }

            UFCardHead("Uni-Dienste", icon: "layers").padding(.top, 22.4)
            UFGridLayout(minWidth: 250) {                                                  // .grid.auto
                ForEach(svc.list("services").indices, id: \.self) { i in
                    ServiceTile(s: svc.list("services")[i]) { url in openURL(url) }
                }
            }
            .environment(\.ufFillsCell, true)
        }
    }

    /// Stundenplan der Uni Hildesheim: Serien aus dem LSF-Export (HildesheimSync, UniStore.importPlan)
    private var lsfTimetableCard: some View {
        UFCard {
            UFCardHead("Stundenplan", icon: "clock")
            Text("Die Termine deines LSF-Stundenplans werden bei jedem Abgleich übernommen; vorlesungsfreie Tage stehen darin als Ausfall. Eigene Änderungen und Ausnahmen bleiben erhalten.")
                .ufFont(13.12).foregroundStyle(UF.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 5.6)
            UFButton("Stundenplan öffnen", icon: "calendar", size: .small) { router.go(.timetable()) }.padding(.top, 8)
        }
    }

    // MARK: Notenspiegel (QIS)

    private func gradesCard(rows: [JSONValue], last: JSONValue?, lastOK: Bool, qis: JSONValue) -> some View {
        UFCard {
            UFCardHead("Notenspiegel (QIS)", icon: "exam", wrap: true) {
                UFButton("Zugang", icon: "log-out", size: .small) { openCred("qis") }
                UFButton("Noten & Bescheinigungen abrufen", icon: "sync", kind: .primary, size: .small) { Task { await sync(show: false) } }
            }
            if qis["own"]?.bool != true {
                // Web: Inline-Felder Benutzername/QIS-Passwort; auf dem iPad bewusst ohne Passwortfeld
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) { UFIcon("log-out", size: 14); Text("QIS-Zugang hinterlegen").ufFont(14.5, 700) }
                        .foregroundStyle(UF.text)
                    Text("QIS hat meist ein eigenes Passwort (nicht das WebSSO-Passwort). Du trägst es einmal selbst in der Web-App am PC ein (Uni & Noten → Zugang); danach holt die App Noten und Bescheinigungen selbst. Auf dem iPad wird kein Passwort eingegeben oder gespeichert." + (qis.s("same_as").map { " Aktuell: wie \($0)." } ?? ""))
                        .ufFont(13.12).foregroundStyle(UF.muted)
                        .padding(.top, 3.2).padding(.bottom, 8)
                }
                .padding(.vertical, 17.6 + ufB).padding(.horizontal, 19.2 + ufB)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.accentSoft))
                .padding(.bottom, 12.8)
            } else {
                Text("Zugang gespeichert (\(qis.s("user") ?? "")). Die App meldet sich selbst an und holt Notenspiegel, Bescheinigungen und Transcript of Records.")
                    .ufFont(13.12).foregroundStyle(UF.muted).padding(.bottom, 9.6)
            }
            if let last, !lastOK {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) { UFIcon("alert", size: 14); Text(last.s("message") ?? "").ufFont(14.5, 700) }.foregroundStyle(UF.text)
                    Text("Ein Screenshot der Seite liegt unter logs/qis-fehler.png. Mit „Noten abrufen (sichtbar)“ kannst du den Ablauf im Browserfenster verfolgen.")
                        .ufFont(13.12).foregroundStyle(UF.muted)
                    UFButton("Noten abrufen (sichtbar)", size: .small) { Task { await sync(show: true) } }.padding(.top, 6.4)
                }
                .padding(.vertical, 17.6 + ufB).padding(.horizontal, 19.2 + ufB)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.badSoft))
                .padding(.bottom, 9.6)
            }
            if rows.isEmpty {
                UFEmpty(icon: "exam", text: "Noch keine Noten geladen. Nach dem ersten Abruf erscheinen hier alle Prüfungsleistungen aus dem QIS-Notenspiegel.", small: true)
            } else {
                GradesTable(rows: rows)
            }
            let docs = grades.list("documents")
            if !docs.isEmpty {
                Text("Bescheinigungen & Transcript of Records").ufFont(15.2, 650, em: -0.01).foregroundStyle(UF.text).padding(.top, 16)
                VStack(spacing: 0) {                                                       // .list
                    ForEach(docs.indices, id: \.self) { i in
                        let d = docs[i]
                        Button { Task { await openDocument(d) } } label: {
                            UFItemRow(d.s("title") ?? "", sub: UFFmt.date(d.s("fetched_at")), link: true, leading: {
                                UFIcon("file-text", size: 16).foregroundStyle(UF.accentText)
                            })
                        }
                        .buttonStyle(.plain)
                        .ufBorderBottom(i < docs.count - 1)                               // .item:last-child ohne Linie
                    }
                }
            }
            Text("Die Noten werden mit deinen Zugangsdaten direkt aus dem QIS-Portal gelesen (Prüfungsverwaltung → Notenspiegel) und nur lokal gespeichert. Prüfungsanmeldungen bleiben im Portal selbst.")
                .ufFont(11.84).foregroundStyle(UF.muted)
                .padding(.top, 12.8).padding(.bottom, 5.6)
            Spacer(minLength: 0)
        }
    }

    // MARK: Stundenplan und Zugaenge

    private var timetableCard: some View {
        UFCard {
            UFCardHead("Stundenplan", icon: "clock")                     // margin .8rem; der obere p-Rand (5.6) faellt damit zusammen
            if let tt {
                let personal = tt.list("personal").count
                Text("Vorlesungen und eindeutige Termine werden bei jedem Sync automatisch übernommen" + (personal > 0 ? ", dazu \(personal) persönliche Einträge aus deinem Stud.IP-Stundenplan" : "") + ".")
                    .ufFont(13.12).foregroundStyle(UF.text)
                    .padding(.bottom, 5.6)
            }
            if (tt?.i("pending_groups") ?? 0) > 0, let tt {
                let courses = tt.list("courses").compactMap(\.string)
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(courses.count) \(courses.count == 1 ? "Fach" : "Fächer") mit parallelen Übungsgruppen").ufFont(14.5, 700).foregroundStyle(UF.text)
                    Text(courses.joined(separator: ", ")).ufFont(13.12).foregroundStyle(UF.muted)
                    Text("Trage deine Gruppe im Stud.IP-Stundenplan ein oder wähle sie hier unter Stundenplan → Importieren.")
                        .ufFont(13.12).foregroundStyle(UF.text).padding(.top, 4.8)
                }
                .padding(.vertical, 17.6 + ufB).padding(.horizontal, 19.2 + ufB)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.warnSoft))
            } else {
                Text("Keine offenen Gruppenentscheidungen.").ufFont(13.12).foregroundStyle(UF.muted)
            }
            UFButton("Stundenplan öffnen", icon: "calendar", size: .small) { router.go(.timetable()) }.padding(.top, 8)
        }
    }

    private func credentialsCard(_ creds: JSONValue) -> some View {
        UFCard {
            UFCardHead("Zugänge", icon: "log-out")
            VStack(spacing: 0) {
                ForEach(Self.credList, id: \.key) { item in
                    let k = item.key, n = item.name
                    let c = creds[k] ?? .null
                    let st: (UFTone, String) = k == "studip"
                        ? (c["configured"]?.bool == true ? (.ok, "LUH-ID gespeichert") : (.warn, "fehlt"))
                        : c["own"]?.bool == true ? (.ok, "eigener Zugang" + (c.s("user").map { " · \($0)" } ?? ""))
                        : c.s("same_as").map { (.info, "wie \(Self.credName($0))") } ?? (.neutral, "nicht gesetzt")
                    HStack(spacing: 9.6) {
                        Text(n).ufFont(13.12).foregroundStyle(UF.text)
                        Spacer(minLength: 0)
                        HStack(spacing: 5.6) {
                            UFBadge(st.1, tone: st.0)
                            Button { k == "studip" ? router.go(.settings(tab: "account")) : openCred(k) } label: {
                                UFIcon("pencil", size: 13)
                            }
                            .buttonStyle(UFButtonStyle(kind: .ghost, size: .small, iconOnly: true))
                            .accessibilityLabel("Bearbeiten")
                        }
                    }
                    .padding(.vertical, 5.6)
                    .ufBorderBottom()
                }
            }
            Text("Jeder Dienst kann ein eigenes Passwort haben oder auf einen anderen verweisen (z. B. IDM „wie QIS“). Alles liegt nur in der lokalen .env auf deinem PC. Genutzt werden Stud.IP (Sync) und QIS (Noten); die übrigen merkst du dir hier als Übersicht.")
                .ufFont(11.84).foregroundStyle(UF.muted)
                .padding(.top, 9.6).padding(.bottom, 5.6)
        }
    }

    // MARK: Aktionen

    private func openCred(_ key: String) {
        let cur = svc?["credentials"]?[key] ?? .null
        overlay.modal { CredentialDialog(key: key, cur: cur) }
    }

    /// POST /grades/sync[?show=true], Meldung, dann pollBg
    private func sync(show: Bool) async {
        guard let api = session.api else { return }
        do {
            _ = try await api.value("/api/grades/sync" + (show ? "?show=true" : ""), method: "POST")
            toast.show("Notenspiegel wird abgerufen…")
            await shell.pollBackground(toast: toast)
        } catch { toast.show(error.localizedDescription, seconds: 4) }
    }

    /// Web: neuer Tab mit dem PDF; hier Vorschau (QuickLook) aus einer temporaeren Datei
    private func openDocument(_ d: JSONValue) async {
        guard let api = session.api, let id = d.i("id") else { return }
        do {
            let (data, _) = try await api.data("/api/qis/documents/\(id)")
            let url = try AppTemp.file("bescheinigung", name: (d.s("title") ?? "Bescheinigung") + ".pdf")
            try data.write(to: url)
            preview = url
        } catch { toast.show(error.localizedDescription, seconds: 4) }
    }
}

/// .grid.cols-3 mit .span-2: drei Spalten (Karte ueber zwei, Stapel in einer, gleiche Zeilenhoehe),
/// bis 1100 px zwei Spalten (Karte ueber beide, Stapel darunter in der ersten), bis 820 px eine.
private struct ServicesSpanLayout: Layout {
    var columns: Int
    var spacing: CGFloat = 16

    private func frames(_ w: CGFloat, _ subviews: Subviews) -> [CGRect] {
        guard subviews.count == 2 else { return [] }
        switch columns {
        case 3:
            let col = (w - 2 * spacing) / 3, lw = 2 * col + spacing
            let h = max(subviews[0].sizeThatFits(.init(width: lw, height: nil)).height,
                        subviews[1].sizeThatFits(.init(width: col, height: nil)).height)
            return [CGRect(x: 0, y: 0, width: lw, height: h), CGRect(x: lw + spacing, y: 0, width: col, height: h)]
        default:
            let rw = columns == 2 ? (w - spacing) / 2 : w
            let h0 = subviews[0].sizeThatFits(.init(width: w, height: nil)).height
            let h1 = subviews[1].sizeThatFits(.init(width: rw, height: nil)).height
            return [CGRect(x: 0, y: 0, width: w, height: h0), CGRect(x: 0, y: h0 + spacing, width: rw, height: h1)]
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 900
        return CGSize(width: w, height: frames(w, subviews).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, f) in frames(bounds.width, subviews).enumerated() {
            // die Karte wird auf die Zeilenhoehe gestreckt, der Stapel behaelt seine Hoehe (Karten darin wachsen nicht)
            subviews[i].place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY),
                              proposal: ProposedViewSize(width: f.width, height: i == 0 ? f.height : nil))
        }
    }
}

/// Notenspiegel aus dem LSF der Uni Hildesheim: nur die Leistungstabelle (Stammdaten liest und speichert UniFlow nie),
/// abgerufen beim Abgleich hoechstens alle 20 Stunden, mit "Noten abrufen" sofort
private struct LSFGradesCard: View {
    @ObservedObject var connection: HildesheimConnection
    let rows: [JSONValue]
    let last: JSONValue?
    let lastOK: Bool
    @State private var login: HildesheimConnection.Source?

    var body: some View {
        let connected = connection.isConnected(.lsf)
        UFCard {
            UFCardHead("Notenspiegel (LSF)", icon: "exam", wrap: true) {
                if connected && connection.state(.lsf) != .needsLogin {
                    UFButton("Noten abrufen", icon: "sync", kind: .primary, size: .small) { Task { await connection.run(forceGrades: true) } }
                        .disabled(connection.isRunning)
                } else {
                    UFButton(connected ? "Erneut anmelden" : "LSF verbinden", icon: "arrow-right", kind: .primary, size: .small) { login = .lsf }
                }
            }
            if let last, !lastOK {
                HStack(alignment: .top, spacing: 4) {
                    UFIcon("alert", size: 14).padding(.top, 2)
                    Text(last.s("message") ?? "").ufFont(14.5, 700).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(UF.text)
                .padding(.vertical, 17.6 + ufB).padding(.horizontal, 19.2 + ufB)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.badSoft))
                .padding(.bottom, 9.6)
            }
            if rows.isEmpty {
                UFEmpty(icon: "exam", text: connected
                        ? "Noch keine Leistungen. Nach dem nächsten Abruf erscheinen hier alle Prüfungsleistungen aus deinem LSF-Notenspiegel."
                        : "Verbinde das LSF, damit UniFlow deinen Notenspiegel holt.", small: true)
            } else {
                GradesTable(rows: rows)
            }
            Text("Die Noten liest UniFlow mit deiner LSF-Anmeldung aus dem Notenspiegel (nur die Leistungstabelle, keine persönlichen Daten) und speichert sie nur auf diesem iPad. Prüfungsanmeldungen bleiben im LSF selbst.")
                .ufFont(11.84).foregroundStyle(UF.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12.8).padding(.bottom, 5.6)
            Spacer(minLength: 0)
        }
        .sheet(item: $login) { s in HildesheimLoginView(target: s, connection: connection) }
    }
}

/// table.tbl: Prüfung (+ Nr · Abschluss), Semester, Note, LP, Status-Badge, Versuch
private struct GradesTable: View {
    let rows: [JSONValue]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(["Prüfung", "Semester", "Note", "LP", "Status", "Versuch"], id: \.self) { h in
                    Text(h.uppercased()).ufFont(12.16, 600, em: 0.04).foregroundStyle(UF.muted)
                        .padding(.vertical, 7.2).padding(.horizontal, 8)
                        .frame(maxWidth: h == "Prüfung" ? .infinity : nil, alignment: .leading)
                }
            }
            line
            ForEach(rows.indices, id: \.self) { i in
                let r = rows[i]
                let st = (r.s("status") ?? "").lowercased()
                GridRow(alignment: .center) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(r.s("text") ?? "").ufFont(13.76, 700).foregroundStyle(UF.text)
                        if let nr = r.s("pruefungsnr"), !nr.isEmpty {
                            Text(nr + ((r.s("abschluss") ?? "").isEmpty ? "" : " · " + (r.s("abschluss") ?? ""))).ufFont(11.84).foregroundStyle(UF.muted)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    cell(r.s("semester") ?? "", small: true)
                    Text(r.s("note").flatMap { $0.isEmpty ? nil : $0 } ?? "–").ufFont(13.76, 700).foregroundStyle(UF.text).padding(8)
                    cell(r.s("credits") ?? "", small: true)
                    UFBadge(r.s("status").flatMap { $0.isEmpty ? nil : $0 } ?? "–",
                            tone: st.hasPrefix("be") ? .ok : st.hasPrefix("ni") ? .bad : .neutral).padding(8)
                    cell(r.s("versuch") ?? "", small: true)
                }
                line
            }
        }
    }

    private var line: some View { Rectangle().fill(UF.line).frame(height: 1).gridCellUnsizedAxes(.horizontal) }

    private func cell(_ s: String, small: Bool) -> some View {
        Text(s).ufFont(small ? 13.12 : 13.76).foregroundStyle(UF.text).fixedSize().padding(8)
    }
}

/// a.card.mod-card (neuer Tab): linker Balken 4 pt --accent, Icon-Kachel 34 pt, Name, Beschreibung, Login-Badge, Status
private struct ServiceTile: View {
    let s: JSONValue
    let open: (URL) -> Void
    @Environment(\.ufFillsCell) private var fills

    var body: some View {
        Button { if let u = URL(string: s.s("url") ?? "") { open(u) } } label: {
            VStack(alignment: .leading, spacing: 8.8) {
                HStack(spacing: 9.6) {
                    UFIcon(s.s("icon") ?? "file", size: 18).foregroundStyle(UF.accentText)
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 9).fill(UF.accentSoft))
                    Text(s.s("name") ?? "").ufFont(16, 650, lh: 1.25).foregroundStyle(UF.accentText)   // erbt die Linkfarbe
                }
                Text(s.s("desc") ?? "").ufFont(13.12).foregroundStyle(UF.muted)
                HStack {
                    UFBadge(s.s("login") ?? "", tone: .neutral)
                    Spacer(minLength: 9.6)
                    if s["connected"]?.bool == true { UFBadge("synchronisiert", tone: .ok) }
                    else if s["connector"]?.bool == true { UFBadge("Noten-Abruf", tone: .info) }
                    else { Text("öffnen ↗").ufFont(13.12).foregroundStyle(UF.muted) }
                }
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 17.6 + ufB).padding(.horizontal, 19.2 + ufB)
            .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface))
            .overlay(alignment: .leading) { Rectangle().fill(UF.accent).frame(width: 4) }
            .clipShape(RoundedRectangle(cornerRadius: UF.r))
            .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(UF.line, lineWidth: 1))
            .ufShadow(.sm)
            .contentShape(RoundedRectangle(cornerRadius: UF.r))
        }
        .buttonStyle(UFLiftStyle())
    }
}

/// .mod-card:active – kein Hover auf dem iPad; beim Druecken leicht anheben wie :hover (translateY -2px)
private struct UFLiftStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.offset(y: configuration.isPressed ? -2 : 0).animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// credDialog(): Zugang eines Dienstes. Auf dem iPad ohne Passwortfeld – "Eigene Zugangsdaten" traegt der Nutzer in
/// der Web-App am PC ein; "Gleiches Passwort wie …" und "Nicht speichern" funktionieren wie im Web.
struct CredentialDialog: View {
    let key: String
    let cur: JSONValue
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var close
    @State private var mode = "none"
    @State private var same = ""

    private var others: [(value: String, label: String)] { ServicesPage.credList.filter { $0.key != key }.map { ($0.key, $0.name) } }

    var body: some View {
        UFDialog("Zugang: \(ServicesPage.credName(key))") {
            Text("Wird nur lokal in der .env gespeichert. " + (key == "qis" ? "QIS braucht meist ein eigenes Passwort (nicht das WebSSO-Passwort)." : key == "idm" ? "Der Account-Manager nutzt in der Regel dasselbe Passwort wie QIS." : "Wenn der Dienst über WebSSO läuft, reicht „wie Stud.IP“."))
                .ufFont(13.12).foregroundStyle(UF.muted).padding(.vertical, 5.6)
            VStack(alignment: .leading, spacing: 8) {                                   // .stack
                option("own", own: true) {
                    Text("Eigene Zugangsdaten" + (cur["own"]?.bool == true ? " (\(cur.s("user") ?? ""))" : ""))
                }
                Text(cur["own"]?.bool == true
                     ? "Bleibt gespeichert. Ändern nur in der Web-App am PC – auf dem iPad wird kein Passwort eingegeben."
                     : "Benutzername und Passwort trägst du selbst in der Web-App am PC ein – auf dem iPad wird kein Passwort eingegeben.")
                    .ufFont(13.12).foregroundStyle(UF.muted).padding(.leading, 22.4)
                option("same") {
                    HStack(spacing: 6.4) {
                        Text("Gleiches Passwort wie")
                        UFSelect(options: others, selection: $same)
                    }
                }
                option("none") { Text("Nicht speichern") }
            }
        } foot: {
            UFButton("Abbrechen") { close() }
            UFButton("Speichern", kind: .primary) { Task { await save() } }
        }
        .onAppear {
            mode = cur["own"]?.bool == true ? "own" : cur.s("same_as") != nil ? "same" : "none"
            same = cur.s("same_as") ?? others.first?.value ?? ""
        }
    }

    /// label.chip mit Radio (justify-content flex-start, padding .5rem .8rem, Radius 10px)
    private func option<L: View>(_ value: String, own: Bool = false, @ViewBuilder label: () -> L) -> some View {
        let enabled = !own || cur["own"]?.bool == true
        return Button { mode = value } label: {
            HStack(spacing: 6.4) {
                UFRadio(on: mode == value)
                label()
            }
            .ufFont(12.8)
            .foregroundStyle(UF.text2)
            .padding(.vertical, 8 + ufB).padding(.horizontal, 12.8 + ufB)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(UF.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(UF.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
    }

    private func save() async {
        guard let api = session.api else { return }
        do {
            switch mode {
            case "none": _ = try await api.value("/api/credentials/\(key)", method: "PUT", body: ["clear": .bool(true)])
            case "same": _ = try await api.value("/api/credentials/\(key)", method: "PUT", body: ["same_as": .string(same)])
            default: close(); return                                                   // eigener Zugang bleibt unveraendert
            }
            close()
            toast.show("Zugang gespeichert")
            router.reload()
        } catch { toast.show(error.localizedDescription, seconds: 4) }
    }
}

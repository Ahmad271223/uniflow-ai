import SwiftUI
import UniFlowCore

/// Meine Module 1:1 nach viewModules()/modCard() in app/static/views-misc.js: Karten (.mod2) oder Liste (.lib-row),
/// Umschalter in localStorage "mod-mode", Link zu den Moduleinstellungen. Daten: GET /api/modules.
/// Lokal ohne Module (Einordnung in Faecher erst mit S4) stehen hier die abgeglichenen Stud.IP-Kurse
/// (GET /api/courses); ein Kurs oeffnet seinen Ordner in Dokumente & Notizen (`LibraryCourses`).
struct ModulesPage: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var router: UFRouter
    @AppStorage("mod-mode") private var mode = "cards"
    @State private var mods: [JSONValue]?
    /// lokal ohne Module: Stud.IP-Kurse ohne Modul
    @State private var courses: [JSONValue] = []
    @State private var error: String?

    var body: some View {
        Group {
            if let mods { content(mods) } else if let error { UFContent { UFEmpty(icon: "alert", text: error) } } else {
                UFContent { UFSkeleton().frame(width: 280, height: 28).padding(.bottom, 16); UFSkeleton().frame(height: 300) }
            }
        }
        .task { await load() }
        .ufReload { await load() }
    }

    private func load() async {
        guard let api = session.api else { error = "Nicht mit dem Server verbunden."; return }
        do {
            let list = try await api.value("/api/modules").items
            courses = api.isLocal && list.isEmpty ? LibraryCourses.unassigned((try? await api.value("/api/courses"))?.items ?? []) : []
            mods = list
            error = nil
        } catch { if mods == nil { self.error = error.localizedDescription } }
    }

    @ViewBuilder private func content(_ mods: [JSONValue]) -> some View {
        UFContent(maxWidth: 1480) {
            UFPageHead("Meine Module", sub: "Alle Module deines Studiums – Vorlesungen, Übungen, Materialien und Tests an einem Ort.") {
                UFSegPill(options: [("cards", "Karten", nil), ("list", "Liste", nil)], selection: mode) { mode = $0 }
                UFButton("Module & Wochentests", icon: "settings") { router.go(.settings(tab: "modules")) }
            }
            if mods.isEmpty, !courses.isEmpty {
                LocalCoursesCard(courses: courses) { router.go(.files(path: LibraryCourses.path($0))) }
            } else if mods.isEmpty {
                UFCard { UFEmpty(icon: "book", text: "Noch keine Module. Erst synchronisieren.") }
            } else if mode == "cards" {
                UFAutoGrid(min: 300, spacing: 19.2) {
                    ForEach(Row.rows(mods)) { row in ModuleCard(m: row.value) { router.go(.module(row.value.i("id") ?? 0)) } }
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Row.rows(mods)) { row in ModuleListRow(m: row.value) { router.go(.module(row.value.i("id") ?? 0)) } }
                }
                .padding(ufB)
                .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface))
                .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(UF.line, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: UF.r))
                .ufShadow(.sm)
            }
        }
    }
}

/// Lokal ohne Module: Stud.IP-Kurse als Liste im Stil von .mod2-list (Titel, Semester, Dateien, neu); ein Kurs oeffnet
/// seinen Ordner in Dokumente & Notizen
struct LocalCoursesCard: View {
    let courses: [JSONValue]
    let open: (String) -> Void

    var body: some View {
        UFCard {
            UFCardHead("Deine Stud.IP-Kurse", icon: "book") { Text("\(courses.count)").ufFont(13.12).foregroundStyle(UF.muted) }
            Text("Ein Modul fasst die Vorlesung und die Übungen eines Fachs zusammen. Diese Einordnung macht UniFlow auf dem iPad noch nicht – bis dahin findest du deine Unterlagen hier und in „Dokumente & Notizen“ nach Stud.IP-Kursen.")
                .ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true).padding(.bottom, 5.6)
            VStack(spacing: 0) {
                ForEach(Row.rows(courses)) { row in
                    let c = row.value
                    let sub = [c.s("semester"), c.s("number")].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
                    Button { if let id = c.s("id") { open(id) } } label: {
                        HStack(spacing: 9.6) {
                            RoundedRectangle(cornerRadius: 6).fill(UF.accent).frame(width: 36, height: 36)
                                .overlay(UFIcon("folder", size: 18).foregroundStyle(.white))
                            VStack(alignment: .leading, spacing: 0) {
                                Text(c.s("title") ?? "").ufFont(14.08, 700).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                                if !sub.isEmpty { Text(sub).ufFont(11.84).foregroundStyle(UF.muted) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            let n = c.i("file_count") ?? 0
                            Text("\(n) \(n == 1 ? "Datei" : "Dateien") · \(c.i("new_count") ?? 0) neu").ufFont(13.12).foregroundStyle(UF.muted).fixedSize()
                            UFIcon("chevron-right", size: 16).foregroundStyle(UF.text).frame(width: 36)
                        }
                        .padding(.vertical, 7.2).padding(.horizontal, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .ufBorderBottom()
                }
            }
        }
    }
}

/// grid-template-columns: repeat(auto-fill, minmax(min, 1fr)) mit gleich hohen Zeilen
struct UFAutoGrid<Content: View>: View {
    let min: CGFloat
    var spacing: CGFloat = 16
    @ViewBuilder let content: Content

    var body: some View {
        UFGridLayout(spacing: spacing, minWidth: min) { content }
            .environment(\.ufFillsCell, true)
    }
}

enum ModuleDeco {
    /// DECO in views-misc.js: Deko-Icon nach dem Modulnamen
    static func icon(_ name: String?) -> String {
        let n = (name ?? "").lowercased()
        let table: [(String, String)] = [("mathe", "grid"), ("elektro", "sparkles"), ("signal", "rotate"), ("programm", "type"),
                                         ("datenstruktur", "layers"), ("algorithm", "layers"), ("einf", "columns"), ("digital", "cards")]
        return table.first { n.contains($0.0) }?.1 ?? "book"
    }
}

/// .mod2: Verlauf 160deg (Modulfarbe 14 % -> --surface bei 72 %), Rahmen Farbe 22 % in --line, Radius 18
struct ModuleCard: View {
    let m: JSONValue
    let open: () -> Void
    @Environment(\.ufFillsCell) private var fills

    var body: some View {
        let mc = Color(hex: m.s("color"))
        let topics = m.list("topics").compactMap(\.string)
        let courses = m.i("courses") ?? 0
        let desc = topics.isEmpty ? "Vorlesung, Übungen und Material – \(courses) Veranstaltung\(courses == 1 ? "" : "en") aus Stud.IP." : topics.joined(separator: ", ")
        let progress = m.i("progress") ?? 0
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12.8) {                                     // .hd
                    RoundedRectangle(cornerRadius: 12).fill(mc).frame(width: 48, height: 48)
                        .overlay(Text(UFFmt.initial(m.s("name"))).font(.uf(16, 700)).foregroundStyle(.white))
                    Text(m.s("name") ?? "").ufFont(17.92, 700, lh: 1.2).foregroundStyle(UF.text)
                        .fixedSize(horizontal: false, vertical: true)               // umbrechen statt kuerzen
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.trailing, 40).padding(.bottom, 9.6)
                Text(desc).ufFont(13.76).foregroundStyle(UF.text2).lineLimit(2)        // .desc: min-height 2.6em
                    .frame(minHeight: 13.76 * 2.6, alignment: .topLeading)
                    .padding(.bottom, 12.8)
                HStack {                                                    // .pr
                    (Text("\(progress)%").font(.uf(12.8, 700)).foregroundColor(UF.text) + Text(" bearbeitet"))
                    Spacer()
                    if let n = m.i("new_count"), n > 0 {
                        Text("\(n) neue Inhalte").font(.uf(12.8, 700)).foregroundStyle(mc)
                    } else {
                        Text(m.s("exam_date").map { "Klausur " + UFFmt.date($0) } ?? "aktuell").foregroundStyle(UF.muted)
                    }
                }
                .ufFont(12.8).foregroundStyle(UF.text2).padding(.bottom, 5.6)
                UFProgress(value: Double(progress) / 100, color: mc, track: Color.mix(mc, 0.15, UF.surface), height: 7)
                next(mc).padding(.vertical, 14.4)
                HStack {                                                    // .stats
                    stat("file-text", m.i("file_count") ?? 0, "Dateien")
                    Spacer(minLength: 8)
                    stat("tasks", m.i("task_count") ?? m.i("open_tasks") ?? 0, "Aufgaben")
                    Spacer(minLength: 8)
                    let t = m.i("test_count") ?? 0
                    stat("exam", t, "Wochentest\(t == 1 ? "" : "s")")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 19.2 + ufB).padding(.bottom, 17.6 + ufB).padding(.horizontal, 20.8 + ufB)
            .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
            .background(LinearGradient(stops: [.init(color: Color.mix(mc, 0.14, UF.surface), location: 0), .init(color: UF.surface, location: 0.72)],
                                       startPoint: UnitPoint(x: 0.33, y: 0), endPoint: UnitPoint(x: 0.67, y: 1)))
            .overlay(alignment: .topTrailing) {                            // .deco: rechts 1rem, oben .9rem, Deckkraft .18
                UFIcon(ModuleDeco.icon(m.s("name")), size: 44).foregroundStyle(mc).opacity(0.18).padding(.top, 14.4).padding(.trailing, 16)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.mix(mc, 0.22, UF.line), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }

    /// .next: Nächster Termin, sonst nächster Lernblock, sonst Hinweis
    @ViewBuilder private func next(_ mc: Color) -> some View {
        let nx = m["next_event"].flatMap { $0.isNull ? nil : $0 }
        let np = m["next_package"].flatMap { $0.isNull ? nil : $0 }
        HStack(spacing: 11.2) {
            UFIcon(nx == nil && np != nil ? "book" : "calendar", size: 20).foregroundStyle(mc)
            VStack(alignment: .leading, spacing: 0) {
                Text(nx != nil || np == nil ? "Nächster Termin" : "Nächster Lernblock").ufFont(11.52).foregroundStyle(UF.muted)
                if let nx {
                    Text(UFFmt.shortName(nx.s("title"))).ufFont(13.76, 700).foregroundStyle(UF.text).lineLimit(1)
                    let room = nx.s("room").flatMap { $0.isEmpty ? nil : " · " + ($0.components(separatedBy: ":").first ?? "") } ?? ""
                    Text("\(UFFmt.short(nx.s("date"))) · \(nx.s("start") ?? "") – \(nx.s("end") ?? "")\(room)").ufFont(12.16).foregroundStyle(UF.text2)
                } else if let np {
                    Text(np.s("title") ?? "").ufFont(13.76, 700).foregroundStyle(UF.text).lineLimit(1)
                    Text(UFFmt.short(np.s("date"))).ufFont(12.16).foregroundStyle(UF.text2)
                } else {
                    Text("Kein Termin in den nächsten 14 Tagen").ufFont(13.76, 700).foregroundStyle(UF.muted).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if nx != nil || np != nil { UFIcon("chevron-right", size: 16).foregroundStyle(UF.accentText) }
        }
        .padding(.vertical, 9.6 + ufB).padding(.horizontal, 12.8 + ufB)
        .background(RoundedRectangle(cornerRadius: 12).fill(UF.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(UF.line, lineWidth: 1))
    }

    private func stat(_ icon: String, _ n: Int, _ label: String) -> some View {
        HStack(spacing: 7.2) {
            UFIcon(icon, size: 18).foregroundStyle(UF.text2)
            VStack(alignment: .leading, spacing: 1.6) {
                Text("\(n)").font(.uf(16.8, 700)).foregroundStyle(UF.text)
                Text(label).ufFont(11.52).foregroundStyle(UF.muted)
            }
        }
    }
}

/// .lib-row in .mod2-list: Spalten 44px 1fr 120px 120px 120px 36px
struct ModuleListRow: View {
    let m: JSONValue
    let open: () -> Void

    var body: some View {
        let nx = m["next_event"].flatMap { $0.isNull ? nil : $0 }
        let topics = m.list("topics").compactMap(\.string).joined(separator: ", ")
        Button(action: open) {
            HStack(spacing: 9.6) {
                RoundedRectangle(cornerRadius: 6).fill(Color(hex: m.s("color"))).frame(width: 36, height: 36)
                    .overlay(Text(UFFmt.initial(m.s("name"))).font(.uf(14.08)).foregroundStyle(.white))
                    .frame(width: 44, alignment: .leading)
                VStack(alignment: .leading, spacing: 0) {
                    Text(m.s("name") ?? "").ufFont(14.08, 700).foregroundStyle(UF.text)
                    Text(topics.isEmpty ? "\(m.i("courses") ?? 0) Veranstaltungen" : topics).ufFont(11.84).foregroundStyle(UF.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(m.i("progress") ?? 0)% bearbeitet").ufFont(13.12).foregroundStyle(UF.text).frame(width: 120, alignment: .leading)
                Text("\(m.i("file_count") ?? 0) Dateien · \(m.i("new_count") ?? 0) neu").ufFont(13.12).foregroundStyle(UF.muted).frame(width: 120, alignment: .leading)
                Text(nx.map { "\(UFFmt.short($0.s("date"))) \($0.s("start") ?? "")" } ?? "–").ufFont(13.12).foregroundStyle(UF.muted).frame(width: 120, alignment: .leading)
                UFIcon("chevron-right", size: 16).foregroundStyle(UF.text).frame(width: 36)
            }
            .padding(.vertical, 7.2).padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .ufBorderBottom()
    }
}

// MARK: - Moduldetail (viewModule)

struct ModulePage: View {
    let id: Int
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var router: UFRouter
    @State private var d: JSONValue?
    @State private var error: String?
    @State private var tab = "overview"                                   // nur im Speicher wie im Web
    @State private var mode = "list"
    @State private var collapsed: Set<Int> = []

    var body: some View {
        Group {
            if let d { content(d) } else if let error { UFContent { UFEmpty(icon: "alert", text: error) } } else {
                UFContent { UFSkeleton().frame(width: 280, height: 28).padding(.bottom, 16); UFSkeleton().frame(height: 300) }
            }
        }
        .task(id: id) { await load() }
        .ufReload { await load() }
    }

    private func load() async {
        guard let api = session.api else { error = "Nicht mit dem Server verbunden."; return }
        do { d = try await api.value("/api/modules/\(id)"); error = nil } catch { if d == nil { self.error = error.localizedDescription } }
    }

    @ViewBuilder private func content(_ d: JSONValue) -> some View {
        let m = d["module"] ?? .null
        let weeks = d.list("weeks")
        let cur = weeks.filter { ($0.i("week") ?? 0) >= 1 }.last
        let np = d["next_package"].flatMap { $0.isNull ? nil : $0 }
        let progress = d.i("progress") ?? 0
        UFContent {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 16) { head(d, m).fixedSize(horizontal: true, vertical: false); Spacer(minLength: 0); actions.fixedSize() }
                VStack(alignment: .leading, spacing: 16) { head(d, m); actions }
            }
            .padding(.bottom, 19.2)
            UFGrid(columns: 3) {
                UFCard {
                    UFKPI(value: "\(progress)%", label: "Lernfortschritt")
                    UFProgress(value: Double(progress) / 100).padding(.top, 6.4)
                }
                UFCard {
                    UFKPI(value: cur.map { ($0.s("label") ?? "").components(separatedBy: "·").first?.trimmingCharacters(in: .whitespaces) ?? "–" } ?? "–",
                          label: "Aktuelle Lehrwoche" + (cur?.s("topic").flatMap { $0.isEmpty ? nil : " · " + $0 } ?? ""))
                }
                UFCard {
                    VStack(alignment: .leading, spacing: 2.4) {
                        Text(np.map { UFFmt.short($0.s("date")) } ?? "–").ufFont(21.6, 700).foregroundStyle(UF.text)
                        HStack(spacing: 0) {
                            Text(np?.s("title") ?? "Kein Lernblock geplant").foregroundStyle(UF.muted)
                            if let np {
                                Text(" · ").foregroundStyle(UF.muted)
                                Button("öffnen") { router.go(.plan(view: "day", date: np.s("date"))) }.font(.uf(12.8, 600)).foregroundStyle(UF.accentText).buttonStyle(.plain)
                            }
                        }
                        .ufFont(12.8)
                    }
                }
            }
            .padding(.bottom, 16)
            UFTabs(options: [("overview", "Übersicht"), ("lectures", "Vorlesungen"), ("exercises", "Übungen"), ("solutions", "Lösungen"),
                             ("scripts", "Skripte"), ("exams", "Klausuren"), ("notes", "Notizen")], selection: $tab)
            if tab == "overview" {
                if weeks.isEmpty { UFCard { UFEmpty(icon: "file", text: "Keine Dokumente.") } }
                ForEach(Row.rows(weeks, key: "week")) { row in weekBlock(row.value, m: m) }
            } else {
                let key = ["lectures": "vorlesung", "exercises": "uebung", "solutions": "loesung", "scripts": "skript", "exams": "klausur"][tab]
                let files = tab == "notes" ? d.list("notes")
                    : d.list("files").filter { ($0.s("doc_type") ?? "sonstiges") == key }.sorted { ($0.n("chdate") ?? 0) > ($1.n("chdate") ?? 0) }
                UFCard { docList(files) }
            }
        }
    }

    private func head(_ d: JSONValue, _ m: JSONValue) -> some View {
        let kinds = d.list("courses").map { UFKind.text($0.s("kind")) }.joined(separator: ", ")
        return HStack(spacing: 16) {                                         // .mod-head
            RoundedRectangle(cornerRadius: 12).fill(Color(hex: m.s("color"))).frame(width: 46, height: 46)
                .overlay(Text(UFFmt.initial(m.s("name"))).font(.uf(17.6, 700)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 2.4) {
                Text(m.s("name") ?? "").ufFont(30.4, 700, em: -0.02).foregroundStyle(UF.text)
                Text("\(d.list("courses").count) Veranstaltungen: \(kinds)\(m.s("exam_date").map { " · Klausur " + UFFmt.date($0) } ?? "")")
                    .ufFont(14.5).foregroundStyle(UF.muted)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            UFButton("Modul", icon: "settings", size: .small) {
                if let m = d?["module"] { overlay.modal { ModuleEditDialog(m: m) } }
            }
            UFIconSegmented(options: [("list", "list"), ("cards", "grid")], selection: $mode)
        }
    }

    @ViewBuilder private func docList(_ files: [JSONValue]) -> some View {
        if files.isEmpty {
            Text("Nichts vorhanden.").ufFont(13.12).foregroundStyle(UF.muted).frame(maxWidth: .infinity).padding(.vertical, 32)
        } else if mode == "list" {
            ForEach(Row.rows(files)) { row in UFDocRow(f: row.value) { router.go(.doc(row.value.s("id") ?? "")) } }
        } else {
            UFAutoGrid(min: 210, spacing: 11.2) {
                ForEach(Row.rows(files)) { row in UFDocCard(f: row.value) { router.go(.doc(row.value.s("id") ?? "")) } }
            }
        }
    }

    /// .card.week-block: Kopf klappt ein/aus, Gruppen nach sub_label, "Zusammenfassen" bei Vorlesungen
    private func weekBlock(_ w: JSONValue, m: JSONValue) -> some View {
        let wk = w.i("week") ?? 0
        let open = !collapsed.contains(wk)
        let groupsOrder = ["vorlesungen", "uebungen", "loesungen", "skripte", "klausuren", "sonstiges"]
        let fallback = ["vorlesungen": "Vorlesung", "uebungen": "Übung", "loesungen": "Lösung", "skripte": "Skript", "klausuren": "Klausur", "sonstiges": "Sonstiges"]
        return UFCard {
            HStack(spacing: 9.6) {
                UFIcon("chevron-down", size: 16).foregroundStyle(UF.text)
                Text("\(w.s("label") ?? "")\(w.s("topic").flatMap { $0.isEmpty ? nil : " – " + $0 } ?? "")").ufFont(15.2, 650, em: -0.01)
                    .foregroundStyle(UF.text).frame(maxWidth: .infinity, alignment: .leading)
                Text("\(w.i("count") ?? 0) Dokumente").ufFont(12.8).foregroundStyle(UF.muted)
                if !w.list("vorlesungen").isEmpty {
                    UFButton("Zusammenfassen", icon: "sparkles", kind: .ghost, size: .small) { overlay.modal { WeekSummaryDialog(w: w, m: m) } }
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture { if open { collapsed.insert(wk) } else { collapsed.remove(wk) } }
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groupsOrder, id: \.self) { k in
                        let fs = w.list(k)
                        if !fs.isEmpty {
                            // Gruppen nach sub_label in Reihenfolge des ersten Auftretens
                            let labels = fs.reduce(into: [String]()) { acc, f in
                                let l = f.s("sub_label") ?? fallback[k] ?? k
                                if !acc.contains(l) { acc.append(l) }
                            }
                            ForEach(labels, id: \.self) { lab in
                                let group = fs.filter { ($0.s("sub_label") ?? fallback[k] ?? k) == lab }
                                (Text(lab) + Text(group.count > 1 ? " · \(group.count)" : "").font(.uf(13.6, 400)).foregroundColor(UF.muted))
                                    .ufFont(13.6, 650, em: -0.01).foregroundStyle(UF.text2)
                                    .padding(.top, 8).padding(.bottom, 3.2)
                                ForEach(Row.rows(group)) { row in UFDocRow(f: row.value) { router.go(.doc(row.value.s("id") ?? "")) } }
                            }
                        }
                    }
                }
            }
        }
        .padding(.bottom, 14.4)
    }
}

/// .seg mit Icons (Liste/Kacheln im Moduldetail)
struct UFIconSegmented<Value: Hashable>: View {
    let options: [(value: Value, icon: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let o = options[i]
                let active = o.value == selection
                Button { selection = o.value } label: {
                    UFIcon(o.icon, size: 15)
                        .foregroundStyle(active ? UF.text : UF.text2)
                        .padding(.vertical, 5.6 + 3.3).padding(.horizontal, 11.2)  // Hoehe wie eine Textzeile (1.5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(active ? UF.surface : .clear))
                        .ufShadow(active ? .sm : .none)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UF.surface2))
    }
}

/// a.doc-row: Typ-Icon, Titel (500) und direkt dahinter die Unterzeile (inline), rechts Stern und Stufe
struct UFDocRow: View {
    let f: JSONValue
    let open: () -> Void

    var body: some View {
        let st = f.s("status")
        let folder = f.s("studip_folder").flatMap { $0.isEmpty ? nil : " · " + ($0.components(separatedBy: "/").last ?? "") } ?? ""
        let sub = "\(f.s("sub_label") ?? ShellState.typeText[f.s("doc_type") ?? ""] ?? "Dokument")\(folder) · \(UFFmt.date(UFFmt.isoFromUnix(f.n("chdate"))))"
            + (f.i("est_minutes").map { " · ca. \($0) min" } ?? "") + (f["has_notes"].map { !$0.isNull && $0.int != 0 } == true ? " · mit Notizen" : "")
        Button(action: open) {
            HStack(spacing: 9.6) {
                UFIcon(ShellState.typeIcon[f.s("doc_type") ?? ""] ?? "file", size: 17).foregroundStyle(UF.accentText).frame(width: 24)
                (Text(f.s("ai_title") ?? f.s("name") ?? "").font(.uf(14.5, 500)).foregroundColor(st == "erledigt" ? UF.muted : UF.accentText)
                    .strikethrough(st == "erledigt")
                 + Text(st == "neu" ? "  Neu  " : "").font(.uf(10.88, 600)).foregroundColor(UF.accentText)
                 + Text(sub).font(.uf(12.48)).foregroundColor(UF.muted))
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4.8) {
                    if f.i("favorite") == 1 || f["favorite"]?.bool == true { UFIcon("star", size: 14).foregroundStyle(UF.accentText) }
                    UFDiffBadge(level: f.i("difficulty"))
                }
            }
            .padding(.vertical, 7.2).padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(f.s("name") ?? "")
    }
}

/// a.doc-card: Typ-Badge und Stufe, Titel, Datum · Minuten, Zusammenfassung (3 Zeilen)
struct UFDocCard: View {
    let f: JSONValue
    let open: () -> Void
    @Environment(\.ufFillsCell) private var fills

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6.4) {
                HStack {
                    UFBadge(ShellState.typeText[f.s("doc_type") ?? ""] ?? "Dokument", tone: .neutral)
                    Spacer()
                    UFDiffBadge(level: f.i("difficulty"))
                }
                Text(f.s("ai_title") ?? f.s("name") ?? "").ufFont(14.5, 550, lh: 1.3).foregroundStyle(UF.text)
                Text("\(UFFmt.date(UFFmt.isoFromUnix(f.n("chdate"))))\(f.i("est_minutes").map { " · \($0) min" } ?? "")").ufFont(13.12).foregroundStyle(UF.muted)
                if let s = f.s("summary"), !s.isEmpty { Text(s).ufFont(13.12).foregroundStyle(UF.muted).lineLimit(3) }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(12.8 + ufB)
            .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface))
            .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(UF.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Dialoge

/// editModule(m): Name, Farbe, Prioritaet, Klausurtermin, aktiv, Wochentest, abweichende Testdauer
struct ModuleEditDialog: View {
    let m: JSONValue
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var close
    @State private var name = ""
    @State private var color = Color.accentColor
    @State private var prio = 2
    @State private var exam = ""
    @State private var active = true
    @State private var weekly = true
    @State private var tmin = 0
    @State private var loaded = false

    var body: some View {
        UFDialog("Modul bearbeiten") {
            UFField("Name") { UFTextInput(text: $name) }
            HStack(alignment: .top, spacing: 9.6) {
                UFField("Farbe") {
                    UFInputBox { ColorPicker("", selection: $color, supportsOpacity: false).labelsHidden().frame(maxWidth: .infinity, alignment: .leading) }
                }
                UFField("Priorität") { UFSelect(options: [(1, "Niedrig"), (2, "Normal"), (3, "Hoch")], selection: $prio, fill: true) }
                UFField("Klausurtermin") { UFDateField(iso: $exam, allowEmpty: true) }
            }
            HStack(alignment: .top, spacing: 9.6) {
                UFCheckbox("Modul aktiv (wird eingeplant)", isOn: $active).frame(maxWidth: .infinity, alignment: .leading)
                UFCheckbox("Gemeinsamer Wochentest", isOn: $weekly).frame(maxWidth: .infinity, alignment: .leading)
                UFField("Abweichende Testdauer") { UFSelect(options: [(0, "Standard")] + [15, 30, 45, 60, 90].map { ($0, "\($0) min") }, selection: $tmin, fill: true) }
            }
        } foot: {
            UFButton("Abbrechen") { close() }
            UFButton("Speichern", kind: .primary) { Task { await save() } }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            name = m.s("name") ?? ""
            color = Color(hex: m.s("color") ?? "#4f5bd5")
            prio = m.i("priority") ?? 2
            exam = m.s("exam_date") ?? ""
            active = m.i("active") != 0
            weekly = m.i("weekly_test") != 0
            tmin = m.i("test_minutes") ?? 0
        }
    }

    private func save() async {
        guard let api = session.api, let id = m.i("id") else { return }
        let body: JSONValue = ["name": .string(name), "color": .string(color.hexString), "priority": .number(Double(prio)),
                               "exam_date": exam.isEmpty ? .null : .string(exam), "active": .number(active ? 1 : 0),
                               "weekly_test": .number(weekly ? 1 : 0), "test_minutes": tmin == 0 ? .null : .number(Double(tmin))]
        do {
            _ = try await api.value("/api/modules/\(id)", method: "PATCH", body: body)
            close()
            toast.show("Gespeichert")
            router.reload()
        } catch { toast.show(error.localizedDescription) }
    }
}

/// summarizeWeek: Seitentext von bis zu 3 Vorlesungen (je Seite 1–4, max. 9000 Zeichen) -> POST /api/ai/tutor
struct WeekSummaryDialog: View {
    let w: JSONValue
    let m: JSONValue
    @EnvironmentObject private var session: Session
    @Environment(\.ufClose) private var close
    @State private var out: String?
    @State private var failed = false

    var body: some View {
        UFDialog("Zusammenfassung: \(w.s("label") ?? "")", icon: "sparkles") {
            if let out {
                Text(failed ? AttributedString(out) : ((try? AttributedString(markdown: out, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(out)))
                    .ufFont(14.5).foregroundStyle(UF.text)
            } else {
                Text("⏳ Die KI liest die Vorlesungsfolien dieser Woche…").ufFont(14.5).foregroundStyle(UF.muted)
            }
        } foot: {
            UFButton("Schließen") { close() }
        }
        .task { await run() }
    }

    private func run() async {
        guard let api = session.api else { return }
        do {
            var text = ""
            outer: for f in w.list("vorlesungen").prefix(3) {
                for p in 1...4 {
                    let r = try await api.value("/api/files/\(f.s("id") ?? "")/pagetext?page=\(p)")
                    guard let t = r.s("text"), !t.isEmpty else { break }
                    text += "\n--- \(f.s("name") ?? "") S.\(p) ---\n\(t)"
                    if text.count > 9000 { break outer }
                }
            }
            let first = w.list("vorlesungen").first?.s("id") ?? ""
            let r = try await api.value("/api/ai/tutor", method: "POST",
                                        body: ["file_id": .string(first), "page": 1, "mode": "summary", "page_text": .string(String(text.prefix(9000))),
                                               "question": .string("Fasse die Vorlesungen der \(w.s("label") ?? "") im Modul \(m.s("name") ?? "") zusammen.")])
            out = r.s("answer") ?? ""
        } catch {
            failed = true
            out = "Fehler: " + error.localizedDescription
        }
    }
}

extension UFFmt {
    /// fmtDate(Unix-Zeit): Stud.IP-chdate in Sekunden -> ISO-Datum
    static func isoFromUnix(_ t: Double?) -> String? {
        guard let t else { return nil }
        return Fmt.isoDay(Date(timeIntervalSince1970: t))
    }
}

extension Color {
    /// "#rrggbb" fuer <input type="color">
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02x%02x%02x", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}

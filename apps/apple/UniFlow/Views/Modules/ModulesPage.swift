import SwiftUI
import UniFlowCore

/// Meine Module 1:1 nach viewModules()/modCard() in app/static/views-misc.js: Karten (.mod2) oder Liste (.lib-row),
/// Umschalter in localStorage "mod-mode", Link zu den Moduleinstellungen. Daten: GET /api/modules.
/// Module je Semester (Wunsch des Inhabers 05.11.2026, `SyncOrder`, module-semesters.js): aktuelles Semester zuerst
/// (aufgeklappt), dann das naechste, dann "Frühere Semester" je Semester zugeklappt mit Zahl der Module und Dateien,
/// fuer alle Portale; darueber der Hinweis zum Abgleich ("Aktuelles Semester ist da · ältere Semester … (3 von 6)").
/// Daten: GET /api/module-semesters.
/// Lokal ordnet der Abgleich die Stud.IP-Kurse nach Fach in Module (classify und ensure_modules wie am PC, S4). Gibt
/// es dabei kein einziges Modul (z. B. nur eine Begruessung, Art "sonstiges"), stehen hier die Kurse ohne Modul
/// (GET /api/courses); ein Kurs oeffnet seinen Ordner in Dokumente & Notizen (`LibraryCourses`).
struct ModulesPage: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var studip: StudIPSync
    @Environment(\.ufDemoActive) private var demo
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("mod-mode") private var mode = "cards"
    @State private var mods: [JSONValue]?
    /// lokal ohne ein einziges Modul: Stud.IP-Kurse ohne Modul
    @State private var courses: [JSONValue] = []
    @State private var error: String?
    /// Module je Semester (nil: Server ohne diese Route, dann alles wie bisher)
    @State private var semesters: JSONValue?
    /// aufgeklappte fruehere Semester (Beschriftung)
    @State private var openTerms: Set<String> = []

    var body: some View {
        Group {
            if let mods { content(mods) } else if let error {
                // Fehler: Grund und der Weg, es noch einmal zu versuchen (derselbe Ladevorgang)
                UFContent { UFCard { UFEmpty(icon: "alert", text: error) { UFButton("Erneut versuchen", icon: "refresh", size: .small) { Task { await load() } } } } }
            } else {
                // Laden: Platzhalter in der Form der fertigen Seite (Kopf, zwei Karten), damit nichts springt
                UFContent {
                    UFSkeleton().frame(width: 280, height: 30).padding(.bottom, 10)
                    UFSkeleton().frame(maxWidth: 520).frame(height: 16).padding(.bottom, 28)
                    HStack(spacing: 19.2) { UFSkeleton().frame(height: 260); UFSkeleton().frame(height: 260) }
                }
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
            semesters = try? await api.value("/api/module-semesters")
            mods = list
            error = nil
        } catch {
            // Neu laden gescheitert: der letzte Stand bleibt, der Grund steht als Meldung (vorher still)
            if mods == nil { self.error = error.localizedDescription } else { toast.show("Neu laden fehlgeschlagen: \(error.localizedDescription)", seconds: 4) }
        }
    }

    @ViewBuilder private func content(_ all: [JSONValue]) -> some View {
        let split = ModuleSemesters.split(all, semesters)
        let mods = split.current
        UFContent(maxWidth: 1480) {
            UFPageHead("Meine Module", sub: "Alle Module deines Studiums – Vorlesungen, Übungen, Materialien und Tests an einem Ort.") {
                UFSegPill(options: [("cards", "Karten", nil), ("list", "Liste", nil)], selection: mode) { mode = $0 }
                // ohne PC keine Wochentests (KI): der Reiter "Module" der Einstellungen ordnet nur zu
                UFButton(session.api?.isLocal == true ? "Module verwalten" : "Module & Wochentests", icon: "settings") {
                    router.go(.settings(tab: "modules"))
                }
            }
            // Demo und noch nicht verbunden: kein Ladehinweis (Pruefbericht 06.11.2026: in der Demo drehte
            // "Aktuelles Semester wird geladen …" dauerhaft, weil nie ein Abgleich laeuft)
            if !demo, !studip.offersStudIP || studip.phase != .signedOut, let hint = ModuleSemesters.hint(semesters) {
                ModuleSemesterHint(text: hint, busy: ModuleSemesters.stillLoading(semesters))
            }
            if let head = ModuleSemesters.currentHead(split) { ModuleSemesterHead(title: head, count: mods.count) }
            if all.isEmpty, !courses.isEmpty {
                LocalCoursesCard(courses: courses) { router.go(.files(path: LibraryCourses.path($0))) }
            } else if mods.isEmpty, !all.isEmpty {
                UFCard { UFEmpty(icon: "book", text: "Im aktuellen Semester noch keine Module.") }
            } else if mods.isEmpty {
                UFCard { UFEmpty(icon: "book", text: "Noch keine Module. Nach dem ersten Abgleich mit \(studip.university.profile.filesSource) erscheinen sie hier.") }
            } else if mode == "cards" {
                // bei Bedienungshilfen-Schriftgroessen breitere Karten (eine Spalte im Hochformat), damit Namen ganz bleiben
                UFAutoGrid(min: typeSize.isAccessibilitySize ? 520 : 300, spacing: 19.2) {
                    // Kacheln erscheinen beim ersten Oeffnen der Seite leicht gestaffelt (UFMotion), sonst sofort
                    ForEach(Array(Row.rows(mods).enumerated()), id: \.element.id) { i, row in
                        ModuleCard(m: row.value) { router.go(.module(row.value.i("id") ?? 0)) }.ufAppear("modules", index: i)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Row.rows(mods)) { row in ModuleListRow(m: row.value) { router.go(.module(row.value.i("id") ?? 0)) } }
                }
                .padding(ufB)
                .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface))
                .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(UF.line, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: UF.r))
            }
            // naechstes Semester (Karten wie das aktuelle), dann fruehere Semester zugeklappt
            ForEach(Array(split.upcoming.enumerated()), id: \.offset) { _, g in
                ModuleSemesterHead(title: "Nächstes Semester · \(g.label)", count: g.mods.count)
                UFAutoGrid(min: typeSize.isAccessibilitySize ? 520 : 300, spacing: 19.2) {
                    ForEach(Row.rows(g.mods)) { row in ModuleCard(m: row.value) { router.go(.module(row.value.i("id") ?? 0)) } }
                }
            }
            if !split.older.isEmpty {
                OlderModuleSemesters(older: split.older, open: $openTerms) { item in
                    if let id = item.i("module_id") { router.go(.module(id)) }
                    else if let course = item["course_ids"]?.array?.first?.string { router.go(.files(path: LibraryCourses.path(course))) }
                }
                .padding(.top, 22.4)
            }
            // Opencast-Aufzeichnungen aus Kursen ohne Modul (lokal; die uebrigen stehen im Moduldetail)
            if session.api?.isLocal == true { RecordingsUnassignedSection().padding(.top, 24) }
        }
    }
}

/// Lokal ohne ein einziges Modul: Stud.IP-Kurse ohne Modul als Liste im Stil von .mod2-list (Titel, Semester, Dateien,
/// neu); ein Kurs oeffnet seinen Ordner in Dokumente & Notizen
struct LocalCoursesCard: View {
    let courses: [JSONValue]
    let open: (String) -> Void

    var body: some View {
        UFCard {
            UFCardHead("Deine Stud.IP-Kurse", icon: "book") { Text("\(courses.count)").ufFont(13.12).foregroundStyle(UF.muted) }
            Text("Ein Modul fasst die Vorlesung und die Übungen eines Fachs zusammen. Diese Kurse gehören zu keinem Modul – ihre Unterlagen findest du hier und in „Dokumente & Notizen“ nach Stud.IP-Kursen. Unter „Module verwalten“ legst du ein Modul an und ordnest sie zu.")
                .ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true).padding(.bottom, 5.6)
            VStack(spacing: 0) {
                ForEach(Row.rows(courses)) { row in
                    let c = row.value
                    let sub = [c.s("semester"), c.s("number")].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
                    Button { if let id = c.s("id") { open(id) } } label: {
                        HStack(spacing: 9.6) {
                            // Ordner neutral (Farbe gehoert den Daten, nicht dem Rahmen)
                            RoundedRectangle(cornerRadius: UF.rSm).fill(UF.surface2).frame(width: 36, height: 36)
                                .overlay(UFIcon("folder", size: 18).foregroundStyle(UF.text2))
                            VStack(alignment: .leading, spacing: 0) {
                                Text(c.s("title") ?? "").ufFont(14.5, 600).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                                if !sub.isEmpty { Text(sub).ufFont(12.48).foregroundStyle(UF.muted) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            let n = c.i("file_count") ?? 0
                            Text("\(n) \(n == 1 ? "Datei" : "Dateien") · \(c.i("new_count") ?? 0) neu").ufFont(13.12).monospacedDigit().foregroundStyle(UF.muted).fixedSize()
                            UFIcon("chevron-right", size: 16).foregroundStyle(UF.muted).frame(width: 28)
                        }
                        .padding(.vertical, 9.6).padding(.horizontal, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(ModuleRowPressStyle())
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
    @EnvironmentObject private var session: Session
    @Environment(\.ufAIEnabled) private var aiEnabled
    @EnvironmentObject private var studip: StudIPSync
    /// Wochentests am eigenen Server oder mit KI ueber das ChatGPT-Abo; sonst weder anbieten noch ankuendigen
    private var showsTests: Bool { session.api?.isLocal == false || aiEnabled }

    /// Herkunft der Veranstaltungen: Demo-Modul "aus den Demo-Inhalten", sonst die Quelle der Hochschule (Stud.IP bzw.
    /// Learnweb; Audit 03.11.2026: "aus Stud.IP" stand auch an der Demo und an der Uni Hildesheim)
    static func desc(courses: Int, moduleName: String?, filesSource: String) -> String {
        let source = moduleName == DemoContent.moduleName ? "den Demo-Inhalten" : filesSource
        return "Vorlesung, Übungen und Material – \(courses) Veranstaltung\(courses == 1 ? "" : "en") aus \(source)."
    }

    var body: some View {
        let mc = Color(hex: m.s("color"))
        let topics = m.list("topics").compactMap(\.string)
        let courses = m.i("courses") ?? 0
        let desc = topics.isEmpty ? Self.desc(courses: courses, moduleName: m.s("name"), filesSource: studip.university.profile.filesSource)
                                  : topics.joined(separator: ", ")
        let progress = m.i("progress") ?? 0
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12.8) {                                     // .hd
                    RoundedRectangle(cornerRadius: 12).fill(mc).frame(width: 48, height: 48)
                        .overlay(Text(UFFmt.initial(m.s("name"))).font(.uf(16, 700)).foregroundStyle(.white))
                    // umbrechen statt kuerzen, aber nie mitten im Wort (UFWordWrapText)
                    UFWordWrapText(m.s("name") ?? "", size: 17.92, weight: 700, lh: 1.2).foregroundStyle(UF.text)
                }
                .padding(.trailing, 40).padding(.bottom, 9.6)
                Text(desc).ufFont(13.76).foregroundStyle(UF.text2).lineLimit(2)        // .desc: min-height 2.6em
                    .frame(minHeight: 13.76 * 2.6, alignment: .topLeading)
                    .padding(.bottom, 12.8)
                // Lernstand (docs/LERNSTAND-2026-11-04.md): Ring, Zahl und Begruendung; grau ohne Signal
                LernstandTile(m: m["mastery"], color: mc, style: .inline).padding(.bottom, 12.8)
                HStack {                                                    // .pr
                    (Text("\(progress)%").font(.uf(12.8, 700)).foregroundColor(UF.text) + Text(" bearbeitet"))
                        .ufNumber(progress, numeric: Double(progress))
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
                    if showsTests {
                        Spacer(minLength: 8)
                        let t = m.i("test_count") ?? 0
                        stat("exam", t, "Wochentest\(t == 1 ? "" : "s")")
                    }
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
        .buttonStyle(UFPressStyle())                                        // gibt beim Druecken leicht nach (0.98), Aussehen unveraendert
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
    /// iPhone: Zahlen unter dem Namen statt in drei Spalten
    @Environment(\.ufCompact) private var compact

    var body: some View {
        let nx = m["next_event"].flatMap { $0.isNull ? nil : $0 }
        let topics = m.list("topics").compactMap(\.string).joined(separator: ", ")
        Button(action: open) {
            HStack(spacing: 9.6) {
                RoundedRectangle(cornerRadius: UF.rSm).fill(Color(hex: m.s("color"))).frame(width: 36, height: 36)
                    .overlay(Text(UFFmt.initial(m.s("name"))).font(.uf(13.6, 700)).foregroundStyle(.white))
                    .frame(width: 44, alignment: .leading)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    UFWordWrapText(m.s("name") ?? "", size: 14.5, weight: 600).foregroundStyle(UF.text)
                    Text(topics.isEmpty ? "\(m.i("courses") ?? 0) Veranstaltungen" : topics).ufFont(12.48).foregroundStyle(UF.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if compact {
                    VStack(alignment: .trailing, spacing: 2) {
                        LernstandBadge(m: m["mastery"], color: Color(hex: m.s("color")), size: .small)
                        Text("\(m.i("progress") ?? 0)%").ufFont(12.48).monospacedDigit().foregroundStyle(UF.muted)
                    }
                    .fixedSize()
                    UFIcon("chevron-right", size: 16).foregroundStyle(UF.muted)
                } else {
                VStack(alignment: .leading, spacing: 1.6) {
                    Text("\(m.i("progress") ?? 0)% bearbeitet").ufFont(13.12).monospacedDigit().foregroundStyle(UF.text)
                    LernstandBadge(m: m["mastery"], color: Color(hex: m.s("color")), size: .small)   // docs/LERNSTAND-2026-11-04.md
                }
                .frame(width: 120, alignment: .leading)
                Text("\(m.i("file_count") ?? 0) \(m.i("file_count") == 1 ? "Datei" : "Dateien") · \(m.i("new_count") ?? 0) neu").ufFont(13.12).monospacedDigit().foregroundStyle(UF.muted).frame(width: 120, alignment: .leading)
                Text(nx.map { "\(UFFmt.short($0.s("date"))) \($0.s("start") ?? "")" } ?? "–").ufFont(13.12).monospacedDigit().foregroundStyle(UF.muted).frame(width: 120, alignment: .leading)
                UFIcon("chevron-right", size: 16).foregroundStyle(UF.muted).frame(width: 36)
                }
            }
            .padding(.vertical, 9.6).padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(ModuleRowPressStyle(radius: 0))
        .ufBorderBottom()
    }
}

// MARK: - Moduldetail (viewModule)

struct ModulePage: View {
    let id: Int
    @EnvironmentObject private var session: Session
    /// KI ueber das ChatGPT-Abo des Nutzers verbunden (dann gibt es die Zusammenfassung auch ohne PC)
    @Environment(\.ufAIEnabled) private var aiEnabled
    @Environment(\.ufProAIOfferHidden) private var proAIOfferHidden
    /// Tarif fuer die Schloesser der KI-Stellen (Wochentests, Zusammenfassen)
    @ObservedObject private var ent = Entitlements.shared
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var toast: UFToastCenter
    @State private var d: JSONValue?
    @State private var error: String?
    @State private var tab = "overview"                                   // nur im Speicher wie im Web
    @State private var mode = "list"
    @State private var collapsed: Set<Int> = []
    /// Opencast-Aufzeichnungen je Block (nur lokal) und Woche, zu der aus der Uebersicht gesprungen wurde
    @State private var recordingCounts: [Int: Int] = [:]
    @State private var focusWeek: Int?
    /// Sprung aus Lernkalender/Stundenplan (`ModuleFocus`): nur die Woche des Termins bzw. Lernpakets aufgeklappt
    @State private var focus: ModuleFocus.Request?
    @EnvironmentObject private var studip: StudIPSync

    /// Gehoert die Antwort zu diesem Modul? Wechselt die Route direkt von einem Modul zum naechsten (Seitenleiste), behaelt
    /// SwiftUI den Zustand der Seite (gleicher Zweig in `MainView`): ohne diese Pruefung stand das vorige Modul unter der
    /// neuen Adresse, bis die neue Antwort kam, nach einem Fehler beim Laden dauerhaft (Audit 08.11.2026, Paket 40)
    nonisolated static func shows(_ d: JSONValue?, moduleID: Int) -> Bool { d?["module"]?.i("id") == moduleID }

    var body: some View {
        Group {
            if let d, Self.shows(d, moduleID: id) { content(d) } else if let error {
                UFContent { UFCard { UFEmpty(icon: "alert", text: error) { UFButton("Erneut versuchen", icon: "refresh", size: .small) { Task { await load() } } } } }
            } else {
                // Platzhalter in der Form der Seite: Kopf, Kennzahlenleiste, Reiter, erster Block
                UFContent {
                    HStack(spacing: 16) {
                        UFSkeleton().frame(width: 46, height: 46)
                        VStack(alignment: .leading, spacing: 8) { UFSkeleton().frame(width: 320, height: 30); UFSkeleton().frame(width: 220, height: 16) }
                    }
                    .padding(.bottom, 22)
                    UFSkeleton().frame(height: 96).padding(.bottom, 20)
                    UFSkeleton().frame(height: 40).padding(.bottom, 16)
                    UFSkeleton().frame(height: 240)
                }
            }
        }
        .task(id: id) { await load() }
        .ufReload { await load() }
        .onChange(of: tab) { _, t in if t != "recordings" { focusWeek = nil } }
    }

    private func load() async {
        // anderes Modul als die angezeigte Antwort: deren Stand gilt hier nicht (Fehler, Aufzeichnungen, Sprung zur Woche)
        if d != nil, !Self.shows(d, moduleID: id) { d = nil; error = nil; recordingCounts = [:]; focusWeek = nil; focus = nil; collapsed = [] }
        // Sprung aus Lernkalender/Stundenplan: einmal abholen; beim Neuladen bleibt die Abfrage, die Klappzustaende auch
        let jump = ModuleFocus.take(for: id)
        if let jump { focus = jump }
        guard let api = session.api else { error = "Nicht mit dem Server verbunden."; return }
        do {
            let v = try await api.value("/api/modules/\(id)" + ModuleFocus.query(focus))
            // andere Modul-ID waehrend des Ladens (.task(id:) bricht den alten Lauf ab): dessen Antwort nie anzeigen
            guard !Task.isCancelled else { return }
            if jump != nil {
                // nur die Woche des Termins/Pakets offen, die anderen zugeklappt (vorher alle Wochen offen)
                let weeks = v.list("weeks").compactMap { $0.i("week") }
                collapsed = ModuleFocus.collapsed(weeks, open: ModuleFocus.openWeek(weeks, focus: v.i("focus_week")))
            }
            d = v
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            if d == nil { self.error = error.localizedDescription } else { toast.show("Neu laden fehlgeschlagen: \(error.localizedDescription)", seconds: 4) }
        }
        if api.isLocal {
            let counts = await studip.recordings.weekCounts(moduleID: id)
            if !Task.isCancelled { recordingCounts = counts }
        }
    }

    @ViewBuilder private func content(_ d: JSONValue) -> some View {
        let m = d["module"] ?? .null
        let weeks = d.list("weeks")
        let cur = weeks.filter { ($0.i("week") ?? 0) >= 1 }.last
        let np = d["next_package"].flatMap { $0.isNull ? nil : $0 }
        let progress = d.i("progress") ?? 0
        UFContent {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) { head(d, m).fixedSize(horizontal: true, vertical: false); Spacer(minLength: 0); actions.fixedSize() }
                VStack(alignment: .leading, spacing: 16) { head(d, m); actions }
            }
            .padding(.bottom, 22.4)
            // Kennzahlen als Schrift in einer Leiste, getrennt durch Haarlinien (statt drei einzelner Kacheln, die
            // auf dem iPad hochkant als 2 + 1 umbrachen)
            let cells: [AnyView] = [
                AnyView(VStack(alignment: .leading, spacing: 0) {
                    UFKPI(value: "\(progress)%", label: "Lernfortschritt")
                    UFProgress(value: Double(progress) / 100).padding(.top, 8)
                }),
                // fehlender Wert: grauer Strich statt eines Strichs in voller Textfarbe (liest sich sonst wie Laden)
                AnyView(VStack(alignment: .leading, spacing: 2.4) {
                    Text(cur.map { ($0.s("label") ?? "").components(separatedBy: "·").first?.trimmingCharacters(in: .whitespaces) ?? "–" } ?? "–")
                        .ufFont(21.6, 700).foregroundStyle(cur == nil ? UF.muted : UF.text)
                    Text("Aktuelle Lehrwoche" + (cur?.s("topic").flatMap { $0.isEmpty ? nil : " · " + $0 } ?? "")).ufFont(12.8).foregroundStyle(UF.muted)
                }),
                AnyView(VStack(alignment: .leading, spacing: 2.4) {
                    Text(np.map { UFFmt.short($0.s("date")) } ?? "–").ufFont(21.6, 700).foregroundStyle(np == nil ? UF.muted : UF.text)
                    HStack(spacing: 0) {
                        Text(np?.s("title") ?? "Kein Lernblock geplant").foregroundStyle(UF.muted).lineLimit(1)
                        if let np {
                            Text(" · ").foregroundStyle(UF.muted)
                            Button("öffnen") { router.go(.plan(view: "day", date: np.s("date"))) }.font(.uf(12.8, 600)).foregroundStyle(UF.accentText).buttonStyle(.plain)
                        }
                    }
                    .ufFont(12.8)
                }),
            ]
            // Lernstand (docs/LERNSTAND-2026-11-04.md) als eigene Kachel ueber der Kennzahlenleiste: Ring mit Prozent in
            // Modulfarbe, Begruendung, ohne Lernstand grau mit dem Hinweis (`LernstandTile`)
            LernstandTile(m: d["mastery"], color: Color(hex: m.s("color"))).padding(.bottom, 14.4)
            ModuleKPIStrip(cells: cells).padding(.bottom, 20)
            // Aufzeichnungen (Opencast) gibt es nur lokal: der Stud.IP-Abgleich des iPads holt sie
            // (nur an Hochschulen mit Stud.IP)
            // (seit 04.11.2026 auch ohne Stud.IP: eigene Aufnahmen mit dem Mikrofon, docs/VORLESUNG-AUFNEHMEN.md)
            let recordings: [(value: String, label: String)] = session.api?.isLocal == true
                ? [("recordings", "Aufzeichnungen")] : []
            // Community (Loesungen aus der Community nach Lehrwoche, Plus) nur lokal (sie gehoert zum Container) und
            // nur mit CloudKit-Dienst im Build (sonst kein Platzhalter-Reiter)
            let community: [(value: String, label: String)] = session.api?.isLocal == true && SolutionSharing.community.isConnected
                ? [("community", "Community")] : []
            UFTabs(options: [("overview", "Übersicht"), ("lectures", "Vorlesungen"), ("exercises", "Übungen"), ("solutions", "Lösungen"),
                             ("scripts", "Skripte"), ("exams", "Klausuren")] + recordings + community + [("notes", "Notizen")], selection: $tab)
            // Reiterwechsel: der neue Inhalt blendet sanft ein (transition-panel, UFMotion)
            VStack(alignment: .leading, spacing: 0) { tabContent(d, m: m, weeks: weeks) }.ufTabPanel(tab)
        }
    }

    @ViewBuilder private func tabContent(_ d: JSONValue, m: JSONValue, weeks: [JSONValue]) -> some View {
        if tab == "overview" {
            DueListCard(moduleID: id, limit: 4).padding(.bottom, 14.4)       // Abgaben & Prüfungen dieses Moduls
            // Lernfortschritt & Wochentests (#wtBox): erstellt die KI, darum lokal nur mit ChatGPT-Abo (wie der
            // Modul-Dialog: sonst weder anbieten noch ankuendigen)
            if session.api?.isLocal == false || aiEnabled {
                WeeklyTestsCard(module: m)
            } else if aiLock(.weeklyTests) != nil {
                // ohne KI und ohne Pro AI sichtbar mit Schloss (Auftrag des Inhabers 12.11.2026), Pro AI ohne Anmeldung nicht
                UFLockedCard(.weeklyTests, entitlements: ent).padding(.bottom, 14.4)
            }
            // Courseware, Wiki und Forum aus Stud.IP: ein zugeklappter Bereich, nur mit Eintraegen (nur lokal)
            if session.api?.isLocal == true && studip.offersStudIP { StudIPTextsCard(moduleID: id) }
            // Lehrende mit E-Mail und Sprechstunde (LUH, 06.11.2026): nur mit Eintraegen, an HsH/Hildesheim nie
            if session.api?.isLocal == true && studip.offersStudIP { ModuleLecturersCard(moduleID: id, moduleName: m.s("name")) }
            if weeks.isEmpty { UFCard { UFEmpty(icon: "file", text: "Noch keine Dokumente in diesem Modul. Nach dem nächsten Abgleich stehen sie hier nach Lehrwoche.", small: true) } }
            if let focus, !weeks.isEmpty, !collapsed.isEmpty {
                ModuleFocusBar(label: focus.label) { UFMotion.toggle { collapsed = [] } }
            }
            // eigene Wochen und Abschnitte (12.11.2026): je Block Menue, Ziehen, Verschieben; unter den Wochen anlegen und
            // zuruecksetzen (unten, damit die Wochen oben stehen bleiben wie bisher)
            let keys = weeks.compactMap { $0.s("key") }, targets = d.list("targets")
            ForEach(Row.rows(weeks, key: "week")) { row in weekBlock(row.value, m: m, keys: keys, targets: targets) }
            if !weeks.isEmpty {
                ModuleLayoutBar(moduleID: id, custom: d["layout_custom"]?.bool == true,
                                lastKey: weeks.last { ($0.i("week") ?? 0) >= 1 }?.s("key"))
            }
        } else if tab == "recordings" {
            RecordingsPanel(moduleID: id, focusWeek: focusWeek)
        } else if tab == "community" {
            CommunityModulePanel(module: d, files: d.list("files"), weeks: weeks)
        } else {
            let key = ["lectures": "vorlesung", "exercises": "uebung", "solutions": "loesung", "scripts": "skript", "exams": "klausur"][tab]
            let files = tab == "notes" ? d.list("notes")
                : d.list("files").filter { ($0.s("doc_type") ?? "sonstiges") == key }.sorted { ($0.n("chdate") ?? 0) > ($1.n("chdate") ?? 0) }
            let names = ["lectures": "Vorlesungen", "exercises": "Übungen", "solutions": "Lösungen", "scripts": "Skripte",
                         "exams": "Klausuren", "notes": "Notizen"]
            UFCard {
                docList(files, empty: "Keine \(names[tab] ?? "Dokumente") in diesem Modul.",
                        icon: tab == "notes" ? "note" : ShellState.typeIcon[key ?? ""] ?? "file")
            }
        }
    }

    private func head(_ d: JSONValue, _ m: JSONValue) -> some View {
        let kinds = d.list("courses").map { UFKind.text($0.s("kind")) }.joined(separator: ", ")
        return HStack(alignment: .top, spacing: 16) {                        // .mod-head
            // Kuerzel oben buendig mit der ersten Titelzeile (bei grosser Schrift bricht der Titel um)
            RoundedRectangle(cornerRadius: 12).fill(Color(hex: m.s("color"))).frame(width: 46, height: 46)
                .overlay(Text(UFFmt.initial(m.s("name"))).font(.uf(17.6, 700)).foregroundStyle(.white))
                .accessibilityHidden(true)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2.4) {
                UFWordWrapText(m.s("name") ?? "", size: 30.4, weight: 700, em: -0.02).foregroundStyle(UF.text)
                Text("\(d.list("courses").count) Veranstaltungen: \(kinds)\(m.s("exam_date").map { " · Klausur " + UFFmt.date($0) } ?? "")")
                    .ufFont(14.5).foregroundStyle(UF.muted)
                // naechste Klausur aus allen Quellen mit Countdown, Uhrzeit, Raum und Quelle (04.11.2026, `ModuleNextExam`)
                ModuleNextExam(api: session.api, moduleID: id).padding(.top, 4)
                // "Prüfung anmelden" (05.11.2026): nur wenn das Modul in diesem Semester zur Anmeldung vorgeschlagen ist
                ExamRegistrationModuleBlock(api: session.api, appModuleID: id).padding(.top, 6).frame(maxWidth: 560, alignment: .leading)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            UFButton("Modul", icon: "settings", size: .small) {
                if let m = d?["module"] { overlay.modal { ModuleEditDialog(m: m) } }
            }
            // Studienverlauf (04.11.2026): das Modul im persoenlichen Plan zeigen (Zuordnung ueber den Modulnamen)
            if let name = d?["module"]?["name"]?.string, !name.isEmpty {
                UFButton("Im Studienverlauf", icon: "columns", size: .small) { router.go(.studyPlan(module: name)) }
                    .accessibilityIdentifier("module.studyPlan")
            }
            UFIconSegmented(options: [("list", "list"), ("cards", "grid")], selection: $mode)
        }
    }

    /// Schloss einer KI-Stelle auf dem Geraet: ohne KI und ohne Pro AI "ab Pro AI"; am eigenen Server nie
    private func aiLock(_ f: UFFeature) -> UFPlan? {
        guard session.api?.isLocal != false else { return nil }
        return UFLock.ai(f, plan: ent.plan, aiEnabled: aiEnabled, offerHidden: proAIOfferHidden)
    }

    @ViewBuilder private func docList(_ files: [JSONValue], empty: String, icon: String) -> some View {
        if files.isEmpty {
            // leer: Rahmen bleibt, ein Satz sagt, was hier fehlt
            UFEmpty(icon: icon, text: empty, small: true)
        } else if mode == "list" {
            // Zeilen durch Haarlinien getrennt (Tabelle aus Linien und Ausrichtung)
            let rows = Row.rows(files)
            ForEach(rows) { row in
                UFDocRow(f: row.value) { router.go(.doc(row.value.s("id") ?? "")) }.ufBorderBottom(row.id != rows.last?.id)
            }
        } else {
            UFAutoGrid(min: 210, spacing: 11.2) {
                ForEach(Row.rows(files)) { row in UFDocCard(f: row.value) { router.go(.doc(row.value.s("id") ?? "")) } }
            }
        }
    }

    /// .card.week-block: Kopf klappt ein/aus, Gruppen nach sub_label, "Zusammenfassen" bei Vorlesungen (nur PC-Server)
    private func weekBlock(_ w: JSONValue, m: JSONValue, keys: [String], targets: [JSONValue]) -> some View {
        let wk = w.i("week") ?? 0
        let open = !collapsed.contains(wk)
        let groupsOrder = ["vorlesungen", "uebungen", "loesungen", "skripte", "klausuren", "sonstiges"]
        let fallback = ["vorlesungen": "Vorlesung", "uebungen": "Übung", "loesungen": "Lösung", "skripte": "Skript", "klausuren": "Klausur", "sonstiges": "Sonstiges"]
        return UFCard {
            HStack(spacing: 9.6) {
                // Pfeil zeigt den Zustand: nach unten offen, nach rechts zugeklappt
                UFIcon("chevron-right", size: 16).foregroundStyle(UF.muted).rotationEffect(.degrees(open ? 90 : 0))
                Text("\(w.s("label") ?? "")\(w.s("topic").flatMap { $0.isEmpty ? nil : " – " + $0 } ?? "")").ufFont(15.2, 650, em: -0.01)
                    .foregroundStyle(UF.text).frame(maxWidth: .infinity, alignment: .leading)
                if let n = recordingCounts[wk], n > 0 {
                    // Aufzeichnungen derselben Woche: Sprung in den Bereich "Aufzeichnungen"
                    UFChip(text: RecordingText.count(n), icon: "play") { focusWeek = wk; tab = "recordings" }
                        .accessibilityHint("Zeigt die Aufzeichnungen dieser Woche")
                }
                Text("\(w.i("count") ?? 0) \(w.i("count") == 1 ? "Dokument" : "Dokumente")").ufFont(12.8).monospacedDigit().foregroundStyle(UF.muted)
                if w.s("key") != nil { ModuleSectionMenu(moduleID: id, block: w, keys: keys) }
                // KI-Zusammenfassung mit dem PC-Server oder ueber das ChatGPT-Abo des Nutzers (LocalContext.ai)
                if !w.list("vorlesungen").isEmpty, session.api?.isLocal != true || aiEnabled {
                    UFButton("Zusammenfassen", icon: "sparkles", kind: .ghost, size: .small) { overlay.modal { WeekSummaryDialog(w: w, m: m) } }
                } else if !w.list("vorlesungen").isEmpty, let lock = aiLock(.aiHelp) {
                    UFLockedButton(plan: lock, title: "Zusammenfassen", identifier: "module.week.summary.locked") {
                        HStack(spacing: 5) { UFIcon("sparkles", size: 14); Text("Zusammenfassen").ufFont(13.12, 550) }
                            .foregroundStyle(UF.text).frame(minHeight: 44)
                    }
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture { UFMotion.toggle { if open { collapsed.insert(wk) } else { collapsed.remove(wk) } } }   // wie disclosure
            // VoiceOver: Auf-/Zuklappen als benannte Aktion (die Kopfzeile ist kein eigener Knopf)
            .accessibilityAction(named: open ? "Zuklappen" : "Aufklappen") { if open { collapsed.insert(wk) } else { collapsed.remove(wk) } }
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    if wk == -4 { ModuleUnassignedBar(moduleID: id, suggestions: w.i("suggestions") ?? 0) }
                    if (w.i("count") ?? 0) == 0 {
                        Text("Noch leer – zieh Dateien hierher oder nutze bei einer Datei „Verschieben nach …“.")
                            .ufFont(12.8).foregroundStyle(UF.muted).padding(.horizontal, 8).padding(.vertical, 10)
                    }
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
                                (Text(lab) + Text(group.count > 1 ? " · \(group.count)" : "").font(.uf(12.8, 400)).foregroundColor(UF.muted))
                                    .ufFont(12.8, 600).foregroundStyle(UF.text2)
                                    .padding(.top, 12).padding(.bottom, 2).padding(.leading, 8)
                                ForEach(Row.rows(group)) { row in
                                    ModuleWeekFileRow(moduleID: id, f: row.value, targets: targets) { router.go(.doc(row.value.s("id") ?? "")) }
                                }
                            }
                        }
                    }
                }
                .ufReveal()                                                 // Aufklappen wie disclosure (UFMotion)
            }
        }
        .modifier(ModuleDropZone(moduleID: id, key: w.s("key") ?? ""))         // Datei hineinziehen
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
                // VoiceOver (Abnahme 07.11.2026): sonst unbeschriftete Symbol-Knoepfe
                .accessibilityLabel(o.icon == "list" ? "Liste" : o.icon == "grid" ? "Kacheln" : o.icon)
                .accessibilityAddTraits(active ? .isSelected : [])
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
    /// Dynamic Type: die zusammengesetzte Zeile skaliert wie `ufFont` (vorher feste Groessen)
    @Environment(\.dynamicTypeSize) private var typeSize

    private func size(_ s: CGFloat) -> CGFloat { UFScaledFont.scaled(s, typeSize) }

    var body: some View {
        let st = f.s("status")
        let folder = f.s("studip_folder").flatMap { $0.isEmpty ? nil : " · " + ($0.components(separatedBy: "/").last ?? "") } ?? ""
        let sub = "\(f.s("sub_label") ?? ShellState.typeText[f.s("doc_type") ?? ""] ?? "Dokument")\(folder) · \(UFFmt.date(UFFmt.isoFromUnix(f.n("chdate"))))"
            + (f.i("est_minutes").map { " · ca. \($0) min" } ?? "") + (f["has_notes"].map { !$0.isNull && $0.int != 0 } == true ? " · mit Notizen" : "")
        Button(action: open) {
            HStack(spacing: 9.6) {
                // Typ-Symbol gedimmt; Titel in Textfarbe statt Linkfarbe (eine Liste aus lauter blauen Zeilen hat
                // keine Hierarchie), nur "Neu" traegt den Akzent
                UFIcon(ShellState.typeIcon[f.s("doc_type") ?? ""] ?? "file", size: 17).foregroundStyle(UF.text2).frame(width: 24)
                (Text(f.s("ai_title") ?? f.s("name") ?? "").font(.uf(size(14.5), 500)).foregroundColor(st == "erledigt" ? UF.muted : UF.text)
                    .strikethrough(st == "erledigt")
                 + Text(st == "neu" ? "  Neu  " : "  ").font(.uf(size(11.52), 650)).foregroundColor(UF.accentText)
                 + Text(sub).font(.uf(size(12.48))).foregroundColor(UF.muted))
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4.8) {
                    if f.i("favorite") == 1 || f["favorite"]?.bool == true { UFIcon("star", size: 14).foregroundStyle(UF.accentText) }
                    UFDiffBadge(level: f.i("difficulty"))
                }
            }
            .padding(.vertical, 10).padding(.horizontal, 8)                // Zeile mindestens 44 pt hoch
            .contentShape(Rectangle())
        }
        .buttonStyle(ModuleRowPressStyle())
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
                Text("\(UFFmt.date(UFFmt.isoFromUnix(f.n("chdate"))))\(f.i("est_minutes").map { " · \($0) min" } ?? "")").ufFont(12.8).monospacedDigit().foregroundStyle(UF.muted)
                if let s = f.s("summary"), !s.isEmpty { Text(s).ufFont(13.12).foregroundStyle(UF.text2).lineLimit(3) }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(14.4 + ufB)
            .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface))
            .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(UF.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(ModuleCardPressStyle(radius: UF.r))
    }
}

/// Rueckmeldung beim Antippen einer Zeile: Flaeche --surface-2 dahinter, ohne Groessen- oder Lageaenderung
struct ModuleRowPressStyle: ButtonStyle {
    var radius: CGFloat = UF.rSm

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: radius).fill(configuration.isPressed ? UF.surface2 : .clear))
    }
}

/// Rueckmeldung beim Antippen einer Karte: kurz leicht abgedunkelt (Textfarbe 5 %), ohne Groessenaenderung
struct ModuleCardPressStyle: ButtonStyle {
    var radius: CGFloat = UF.r

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(RoundedRectangle(cornerRadius: radius).fill(UF.text.opacity(configuration.isPressed ? 0.05 : 0)).allowsHitTesting(false))
    }
}

/// Kennzahlen des Moduls in einer Karte, durch Haarlinien geteilt: nebeneinander, wenn jede Zelle mindestens 200 pt
/// bekommt, sonst untereinander (Dynamic Type, schmale Fenster)
struct ModuleKPIStrip: View {
    let cells: [AnyView]

    var body: some View {
        UFCard(padded: false) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(cells.indices, id: \.self) { i in
                        cell(i).frame(minWidth: 200, maxWidth: .infinity, alignment: .topLeading)
                            .overlay(alignment: .leading) { if i > 0 { Rectangle().fill(UF.line).frame(width: 1) } }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(cells.indices, id: \.self) { i in
                        cell(i).frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(alignment: .top) { if i > 0 { Rectangle().fill(UF.line).frame(height: 1) } }
                    }
                }
            }
        }
    }

    private func cell(_ i: Int) -> some View {
        cells[i].padding(.vertical, 16).padding(.horizontal, 20)
    }
}

// MARK: - Dialoge

/// editModule(m): Name, Farbe, Prioritaet, Klausurtermin, aktiv, Wochentest, abweichende Testdauer
struct ModuleEditDialog: View {
    let m: JSONValue
    @EnvironmentObject private var session: Session
    @Environment(\.ufAIEnabled) private var aiEnabled
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var close
    @State private var name = ""
    /// gewaehlte Farbe als "#rrggbb" (klein); `was` = gespeicherte Farbe, gesendet wird nur eine Aenderung
    @State private var color = ""
    @State private var was = ""
    /// Farben der anderen Module -> Name (blass mit Hinweis, waehlbar bleiben sie)
    @State private var used: [String: String] = [:]
    @State private var prio = 2
    @State private var exam = ""
    @State private var active = true
    @State private var weekly = true
    @State private var tmin = 0
    @State private var loaded = false

    var body: some View {
        UFDialog("Modul bearbeiten") {
            UFField("Name") { UFTextInput(text: $name) }
            UFField("Farbe") { ModuleColorChoice(color: $color, used: used) }
            HStack(alignment: .top, spacing: 9.6) {
                UFField("Priorität") { UFSelect(options: [(1, "Niedrig"), (2, "Normal"), (3, "Hoch")], selection: $prio, fill: true) }
                UFField("Klausurtermin") { UFDateField(iso: $exam, allowEmpty: true) }
            }
            HStack(alignment: .top, spacing: 9.6) {
                UFCheckbox("Modul aktiv (wird eingeplant)", isOn: $active).frame(maxWidth: .infinity, alignment: .leading)
                // Wochentests (KI) am eigenen Server oder ueber das ChatGPT-Abo; sonst weder anbieten noch ankuendigen
                if session.api?.isLocal == false || aiEnabled {
                    UFCheckbox("Gemeinsamer Wochentest", isOn: $weekly).frame(maxWidth: .infinity, alignment: .leading)
                    UFField("Abweichende Testdauer") { UFSelect(options: [(0, "Standard")] + [15, 30, 45, 60, 90].map { ($0, "\($0) min") }, selection: $tmin, fill: true) }
                }
            }
        } foot: {
            UFButton("Abbrechen") { close() }
            UFButton("Speichern", kind: .primary) { Task { await save() } }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            name = m.s("name") ?? ""
            was = (m.s("color") ?? "").lowercased()
            color = was
            prio = m.i("priority") ?? 2
            exam = m.s("exam_date") ?? ""
            active = m.i("active") != 0
            weekly = m.i("weekly_test") != 0
            tmin = m.i("test_minutes") ?? 0
        }
        .task {
            guard let api = session.api, let list = try? await api.value("/api/modules").items else { return }
            var u: [String: String] = [:]
            for x in list where x.i("id") != m.i("id") {
                if let c = x.s("color")?.lowercased(), u[c] == nil { u[c] = x.s("name") ?? "" }
            }
            used = u
        }
    }

    private func save() async {
        guard let api = session.api, let id = m.i("id") else { return }
        var body: JSONValue = ["name": .string(name), "priority": .number(Double(prio)),
                               "exam_date": exam.isEmpty ? .null : .string(exam), "active": .number(active ? 1 : 0),
                               "weekly_test": .number(weekly ? 1 : 0), "test_minutes": tmin == 0 ? .null : .number(Double(tmin))]
        // wie im Web: Farbe nur bei einer Aenderung (sonst bliebe der Merker color_custom nicht verlaesslich)
        if !color.isEmpty && color != was { body["color"] = .string(color) }
        do {
            _ = try await api.value("/api/modules/\(id)", method: "PATCH", body: body)
            close()
            toast.show("Gespeichert")
            router.reload()
        } catch { toast.show(error.localizedDescription) }
    }
}

/// Farbwahl im Modul-Dialog wie `.mod-colors` im Web: die 12 Farben der Palette (`ModuleColors`) und ein Feld
/// fuer eine eigene Farbe; die gewaehlte ist umrandet.
struct ModuleColorChoice: View {
    @Binding var color: String
    /// Farben anderer Module -> Name: blass, mit Hinweis "schon vergeben"
    var used: [String: String] = [:]

    private var own: Bool { !color.isEmpty && !ModuleColors.palette.contains(color) }

    var body: some View {
        UFFlexWrap(gap: 7.2, rowGap: 7.2) {
            ForEach(ModuleColors.palette, id: \.self) { c in
                Button { color = c } label: { swatch(Color(hex: c), on: color == c).opacity(used[c] != nil && color != c ? 0.35 : 1) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Farbe \(c)")
                    .accessibilityHint(used[c].map { "Schon vergeben: \($0)" } ?? "")
                    .help(used[c].map { "Farbe \(c) – schon vergeben: \($0)" } ?? "Farbe \(c)")
            }
            ColorPicker(selection: Binding(get: { Color(hex: color.isEmpty ? "#4f5bd5" : color) },
                                           set: { color = $0.hexString.lowercased() }), supportsOpacity: false) {
                Text("Eigene Farbe")
            }
            .labelsHidden()
            .frame(width: 28, height: 28)
            .overlay { if own { Circle().strokeBorder(UF.text, lineWidth: 2).frame(width: 32, height: 32).allowsHitTesting(false) } }
            .accessibilityLabel("Eigene Farbe")
        }
        .padding(.top, 5.6)
    }

    private func swatch(_ c: Color, on: Bool) -> some View {
        Circle().fill(c).frame(width: 24, height: 24)
            .padding(2)
            .overlay(Circle().strokeBorder(on ? UF.text : UF.line, lineWidth: on ? 2 : 1))
            .frame(width: 28, height: 28)
            .contentShape(Circle())
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
                    .ufFont(14.5, lh: 1.6).foregroundStyle(failed ? UF.bad : UF.text)
                    .frame(maxWidth: 680, alignment: .leading)                  // Lesbare Zeilenlaenge
            } else {
                // Ladezustand mit Systemanzeige statt Emoji
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Die KI liest die Vorlesungsfolien dieser Woche …").ufFont(14.5).foregroundStyle(UF.muted)
                }
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

// MARK: - Module je Semester

/// Verteilung und Texte fuer Module je Semester, gleich wie app/static/module-semesters.js (splitModules, countLabel,
/// hintText); `sem` = GET /api/module-semesters (`SyncOrder.modulesBySemester`)
enum ModuleSemesters {
    struct Split {
        var current: [JSONValue]
        var upcoming: [(label: String, mods: [JSONValue])]
        var older: [JSONValue]
        var label: String
    }

    /// Module, die keinem anderen Semester zugeordnet sind (auch selbst angelegte), gehoeren zum aktuellen
    static func split(_ mods: [JSONValue], _ sem: JSONValue?) -> Split {
        guard let sem, sem["current"] != nil else { return Split(current: mods, upcoming: [], older: [], label: "") }
        var elsewhere = Set<Int>()
        let byID = Dictionary(mods.compactMap { m in m.i("id").map { ($0, m) } }, uniquingKeysWith: { a, _ in a })
        let upcoming: [(label: String, mods: [JSONValue])] = (sem["upcoming"]?.array ?? []).map { g in
            let ids = (g["module_ids"]?.array ?? []).compactMap(\.int)
            elsewhere.formUnion(ids)
            return (g.s("label") ?? "", ids.compactMap { byID[$0] })
        }
        let older = sem["older"]?.array ?? []
        for g in older { for it in g["items"]?.array ?? [] { if let id = it.i("module_id") { elsewhere.insert(id) } } }
        return Split(current: mods.filter { !elsewhere.contains($0.i("id") ?? -1) }, upcoming: upcoming.filter { !$0.mods.isEmpty },
                     older: older, label: sem["current"]?.s("label") ?? "")
    }

    /// Ueberschrift des aktuellen Semesters, nur wenn es andere Semester gibt
    static func currentHead(_ s: Split) -> String? {
        s.label.isEmpty || (s.upcoming.isEmpty && s.older.isEmpty) ? nil : "Aktuelles Semester · \(s.label)"
    }

    /// Hinweis zum Stand der Stufen ("Aktuelles Semester ist da · ältere Semester … (3 von 6)")
    static func hint(_ sem: JSONValue?) -> String? {
        guard let h = sem?["status"]?["hint"]?.string, !h.isEmpty else { return nil }
        return h
    }

    /// Laeuft noch etwas (erster Abgleich oder fruehere Semester im Hintergrund)?
    static func stillLoading(_ sem: JSONValue?) -> Bool {
        guard let st = sem?["status"] else { return false }
        return st["current"]?["ready"]?.bool == false || st["older"]?["running"]?.bool == true
    }

    /// "3 Module · 12 Dateien", "2 Module · 4 von 10 Dateien geladen", "1 Modul · Dateien noch nicht geladen"
    static func countLabel(_ g: JSONValue) -> String {
        let n = g.i("count") ?? (g["items"]?.array?.count ?? 0), files = g.i("files") ?? 0, done = g.i("downloaded") ?? 0
        var t = "\(n) \(n == 1 ? "Modul" : "Module")"
        if files > 0 { t += done >= files ? " · \(files) \(files == 1 ? "Datei" : "Dateien")" : " · \(done) von \(files) Dateien geladen" }
        else if g["loaded"]?.bool != true { t += " · Dateien noch nicht geladen" }
        return t
    }

    /// "2 Veranstaltungen · 5 Dateien"
    static func itemStatus(_ it: JSONValue) -> String {
        let n = it.i("courses") ?? 0, files = it.i("files") ?? 0, done = it.i("downloaded") ?? 0
        let first = "\(n) \(n == 1 ? "Veranstaltung" : "Veranstaltungen")"
        if files == 0 { return first + (it["loaded"]?.bool == true ? " · keine Dateien" : " · Dateien noch nicht geladen") }
        return first + (done >= files ? " · \(files) \(files == 1 ? "Datei" : "Dateien")" : " · \(done) von \(files) Dateien geladen")
    }
}

/// Hinweisleiste ueber den Modulen (wie .sem-hint)
struct ModuleSemesterHint: View {
    let text: String
    var busy = false

    var body: some View {
        HStack(spacing: 8) {
            UFIcon(busy ? "refresh" : "clock", size: 15).foregroundStyle(UF.text2)
            Text(text).ufFont(13.6).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8.8).padding(.horizontal, 12.8)
        .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface2))
        .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(UF.line, lineWidth: 1))
        .padding(.bottom, 16)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("module-semester-hint")
    }
}

/// Ueberschrift eines Semesters (wie .sem-head)
struct ModuleSemesterHead: View {
    let title: String
    let count: Int

    /// iPhone: Titel bricht um, die Zahl steht darunter (lange Semesternamen werden nicht gekuerzt)
    @Environment(\.ufCompact) private var compact

    var body: some View {
        let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                             : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        layout {
            Text(title).ufFont(16.32, 700).foregroundStyle(UF.text).accessibilityAddTraits(.isHeader)
                .modifier(UFCompactWrap(on: compact))
            Text("\(count) \(count == 1 ? "Modul" : "Module")").ufFont(13.12).foregroundStyle(UF.muted)
        }
        .padding(.top, 6).padding(.bottom, 11.2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("module-semester-head")
    }
}

/// "Frühere Semester": je Semester zugeklappt mit Zahlen; aufgeklappt die Module (echte Module oeffnen das Modul,
/// erkannte Faecher ohne Modul den Kursordner in "Dokumente & Notizen")
struct OlderModuleSemesters: View {
    let older: [JSONValue]
    @Binding var open: Set<String>
    let select: (JSONValue) -> Void
    @Environment(\.ufCompact) private var compact

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Frühere Semester").ufFont(16.32, 700).foregroundStyle(UF.text).accessibilityAddTraits(.isHeader)
            ForEach(Array(older.enumerated()), id: \.offset) { _, g in term(g) }
        }
    }

    private func term(_ g: JSONValue) -> some View {
        let label = g.s("label") ?? "Früheres Semester"
        let isOpen = open.contains(label)
        let items = g["items"]?.array ?? []
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if isOpen { open.remove(label) } else { open.insert(label) }
            } label: {
                HStack(spacing: 10) {
                    UFIcon(isOpen ? "chevron-down" : "chevron-right", size: 16).foregroundStyle(UF.text2)
                    RoundedRectangle(cornerRadius: 8).fill(UF.surface2).frame(width: 36, height: 36)
                        .overlay(UFIcon("book", size: 18).foregroundStyle(UF.text2))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label).ufFont(15.2, 650).foregroundStyle(UF.text).modifier(UFPhoneWrap())
                        Text(ModuleSemesters.countLabel(g)).ufFont(12.8).foregroundStyle(UF.muted).modifier(UFPhoneWrap())
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(label), \(ModuleSemesters.countLabel(g)), \(isOpen ? "aufgeklappt" : "zugeklappt")")
            .accessibilityIdentifier("module-semester.term")
            if isOpen {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                        Button { select(it) } label: {
                            HStack(spacing: 9.6) {
                                if it.s("color") != nil { Circle().fill(Color(hex: it.s("color"))).frame(width: 9.6, height: 9.6) }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(it.s("name") ?? "").ufFont(14.5, 600).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                                    Text(ModuleSemesters.itemStatus(it)).ufFont(12.48).foregroundStyle(UF.muted)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                UFIcon("chevron-right", size: 16).foregroundStyle(UF.muted).frame(width: 28)
                            }
                            .padding(.vertical, 8).padding(.horizontal, 8)
                            .frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(ModuleRowPressStyle())
                        .ufBorderBottom()
                    }
                }
                .padding(.top, 6).padding(.leading, compact ? 8 : 26)     // iPhone: Platz fuer lange Modulnamen
            }
        }
        .padding(.vertical, 8 + ufB).padding(.horizontal, 14.4 + ufB)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface))
        .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(UF.line, lineWidth: 1))
    }
}

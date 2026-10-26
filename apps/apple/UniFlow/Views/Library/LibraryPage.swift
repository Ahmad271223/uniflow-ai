import PDFKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UniFlowCore

// Dokumente & Notizen 1:1 nach viewFiles() in app/static/views-lib.js: Modulordner, eigene Ordner, Typ-Chips,
// Bereiche (Favoriten, Zuletzt, Neu aus Stud.IP, Papierkorb), Kacheln/Liste, Suche, Sortierung, Neu-Menü,
// Menüs je Element. Daten: GET /api/library.
// Lokal (ohne PC) zusaetzlich: Stud.IP-Kurse ohne Modul als Ordner (Pfad "c<Kurs-ID>", Kursliste aus GET /api/courses).
// Seit S4 ordnet der Abgleich die Kurse nach Fach in Module (Modulordner wie im Web); ohne Modul bleiben nur Kurse ohne
// Fach oder mit der Art "sonstiges" (z. B. eine Begruessung). Mit eigenem Server wie im Web.

enum LibraryStyle {
    /// FILE_COLORS in views-lib.js
    static let fileColors: [String: UInt32] = ["vorlesung": 0xe5484d, "uebung": 0x2f7fd1, "skript": 0xd9851e, "klausur": 0x8b5cf6, "loesung": 0x1f9d5b,
                                               "notebook": 0x7c3aed, "whiteboard": 0x0ea5a0, "image": 0x1f9d5b, "sonstiges": 0x7a8199]
    static let typeFolders: [(String, String)] = [("vorlesung", "Vorlesungen"), ("uebung", "Übungen"), ("loesung", "Lösungen"), ("skript", "Skripte"),
                                                  ("klausur", "Klausuren"), ("sonstiges", "Sonstiges")]
    static let chips: [(String, String)] = [("all", "Alle"), ("vorlesung", "Vorlesungen"), ("uebung", "Übungen"), ("skript", "Skripte"),
                                            ("klausur", "Klausuren"), ("notes", "Notizen"), ("sonstiges", "Sonstiges")]

    /// fileType(f): PDFs nach Dokumenttyp, sonst die Art (notebook, whiteboard, image)
    static func fileType(_ f: JSONValue) -> String { f.s("kind") == "pdf" ? (f.s("doc_type") ?? "sonstiges") : (f.s("kind") ?? "file") }

    /// ago(v): heute, gestern, vor N Tagen, sonst Datum
    static func ago(_ f: JSONValue) -> String {
        let v = f.s("edited_at") ?? f.s("last_opened")
        guard let v, let d = ISO8601DateFormatter.local.date(from: v) ?? Fmt.date(v) else { return "" }
        let days = Int(floor(Date().timeIntervalSince(d) / 86_400))
        return days <= 0 ? "heute" : days == 1 ? "gestern" : days < 30 ? "vor \(days) Tagen" : UFFmt.date(Fmt.isoDay(d))
    }
}

/// Stud.IP-Kurse ohne Modul als Ordner in Dokumente & Notizen und in Meine Module (nur lokal): Kurse ohne Fach oder mit
/// der Art "sonstiges" bekommen von ensure_modules kein Modul, ihre Dokumente stuenden sonst nur unter "Neu aus
/// Stud.IP" und "Zuletzt" (bewusste Abweichung vom Web, docs/IPAD-OHNE-PC.md). Mit eigenem Server wie im Web.
enum LibraryCourses {
    /// Pseudokurs der eigenen Dokumente (app/db.py)
    static let ownDocuments = "__user__"

    /// Stud.IP-Kurse aus `GET /api/courses`, die keinem Modul zugeordnet sind
    static func unassigned(_ courses: [JSONValue]) -> [JSONValue] {
        courses.filter { $0.s("id") != ownDocuments && $0["module_id"]?.isNull != false }
    }

    /// Pfad des Kursordners
    static func path(_ courseID: String) -> String { "c" + courseID }

    /// Kurs-ID aus einem Pfad "c<Kurs-ID>[/...]"; nil fuer Modul- und eigene Ordner
    static func courseID(_ path: String) -> String? {
        let first = path.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        guard first.hasPrefix("c"), first.count > 1 else { return nil }
        return String(first.dropFirst())
    }

    /// Kurstitel eines Stud.IP-Dokuments (lokal ohne Fach statt "Eigene Notizen" im Schnellzugriff)
    static func title(of file: JSONValue, in courses: [JSONValue]) -> String? {
        guard let cid = file.s("course_id"), cid != ownDocuments else { return nil }
        return courses.first { $0.s("id") == cid }?.s("title")
    }

    /// Ordner je Kurs ohne Modul, der Dokumente in der Bibliothek hat (Papierkorb und inaktive Kurse zaehlen nicht,
    /// die liefert `/api/library` nicht); Reihenfolge wie `/api/courses` (nach Titel)
    static func folders(_ courses: [JSONValue], files: [JSONValue]) -> [LibraryPage.Item] {
        unassigned(courses).compactMap { c in
            guard let id = c.s("id") else { return nil }
            let n = files.filter { $0.s("course_id") == id && $0["module_id"]?.isNull != false }.count
            return n > 0 ? LibraryPage.Item(id: path(id), kind: .folder, label: c.s("title") ?? "Kurs", count: n, path: path(id)) : nil
        }
    }
}

extension ISO8601DateFormatter {
    /// "2026-10-25T08:23:26" ohne Zeitzone (lokale Zeit wie db.now_iso)
    static let local: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        f.timeZone = .current
        return f
    }()
}

struct LibraryPage: View {
    let section: String?
    let path: String?
    let q: String?
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    /// Hochschule des Containers: Quelle der Dateien ("Stud.IP" bzw. "Learnweb") in den Beschriftungen
    @EnvironmentObject private var studip: StudIPSync

    private var newTitle: String { UFSourceText.newFiles(studip.university) }
    @AppStorage("lib-mode") private var mode = "grid"
    @State private var lib: JSONValue?
    /// lokal: Kursliste fuer die Kursordner (`LibraryCourses`); mit eigenem Server leer
    @State private var courses: [JSONValue] = []
    @State private var error: String?
    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?

    /// sort/filter im Web: Modulvariablen, bleiben fuer die Sitzung erhalten
    @MainActor static var sort = "date"
    @MainActor static var filter = "all"
    @State private var tick = 0                                             // erzwingt Neuaufbau nach sort/filter

    var body: some View {
        Group {
            if let lib { content(lib) } else if let error { UFContent { UFEmpty(icon: "alert", text: error) } } else {
                UFContent { UFSkeleton().frame(width: 280, height: 28).padding(.bottom, 16); UFSkeleton().frame(height: 300) }
            }
        }
        .task(id: "\(section ?? "")|\(path ?? "")|\(q ?? "")") { query = q ?? ""; await load() }
        .ufReload { await load() }
    }

    private func load() async {
        guard let api = session.api else { error = "Nicht mit dem Server verbunden."; return }
        do {
            let value = try await api.value("/api/library")
            courses = api.isLocal ? ((try? await api.value("/api/courses"))?.items ?? []) : []
            lib = value
            error = nil
        } catch { if lib == nil { self.error = error.localizedDescription } }
    }

    private var actions: PlanActions { PlanEnv.make(session, overlay, toast, router) }

    // MARK: Elemente wie in viewFiles

    struct Item: Identifiable {
        enum Kind { case folder, doc, trash }
        let id: String
        let kind: Kind
        var label = ""
        var color: String?
        var count = 0
        var path = ""
        var module: JSONValue?
        var user: JSONValue?
        var f: JSONValue = .null
    }

    private struct Built {
        var items: [Item] = []
        var crumbs: [(label: String, path: String)] = [("Dokumente & Notizen", "")]
        var root = false
    }

    private func build(_ lib: JSONValue) -> Built {
        let section = self.section ?? "docs"
        let path = self.path ?? ""
        let files = lib.list("files")
        let folders = lib.list("folders")
        let modules = lib.list("modules")
        let filter = Self.filter
        let qq = (q ?? "").lowercased()
        var b = Built()
        b.root = section == "docs" && path.isEmpty && qq.isEmpty && filter == "all"
        let doc: (JSONValue) -> Item = { Item(id: "d" + ($0.s("id") ?? ""), kind: .doc, f: $0) }
        let count: (Int) -> Int = { fid in files.filter { $0.i("folder_id") == fid }.count }
        let byFilter: ([JSONValue]) -> [Item] = { list in
            list.filter { f in filter == "notes" ? (f.s("kind") != "pdf" && f.s("kind") != "image") : LibraryStyle.fileType(f) == filter }.map(doc)
        }
        switch section {
        case "fav": b.items = files.filter { $0.i("favorite") == 1 }.map(doc)
        case "recent": b.items = recentFiles(files, limit: 60).map(doc)
        case "new": b.items = files.filter { $0.s("status") == "neu" }.map(doc)
        case "trash": b.items = lib.list("trash").map { Item(id: "t" + ($0.s("id") ?? ""), kind: .trash, f: $0) }
        default:
            let seg = path.isEmpty ? [] : path.components(separatedBy: "/")
            if seg.isEmpty {
                b.items = modules.map { m in
                    Item(id: "m\(m.i("id") ?? 0)", kind: .folder, label: m.s("name") ?? "", color: m.s("color"),
                         count: files.filter { $0.i("module_id") == m.i("id") }.count, path: "m\(m.i("id") ?? 0)", module: m)
                } + LibraryCourses.folders(courses, files: files) + folders.filter { $0["parent_id"]?.isNull != false && $0["module_id"]?.isNull != false }.map { f in
                    Item(id: "f\(f.i("id") ?? 0)", kind: .folder, label: f.s("name") ?? "", color: f.s("color") ?? "#8b93a8", count: count(f.i("id") ?? 0),
                         path: "f\(f.i("id") ?? 0)", user: f)
                } + files.filter { $0.s("course_id") == "__user__" && $0["folder_id"]?.isNull != false }.map(doc)
                if filter != "all" { b.items = byFilter(files) }
            } else if seg[0].hasPrefix("m") {
                let mid = Int(seg[0].dropFirst()) ?? 0
                let m = modules.first { $0.i("id") == mid }
                b.crumbs.append((m?.s("name") ?? "Modul", seg[0]))
                let modFiles = files.filter { $0.i("module_id") == mid }
                if seg.count == 1 {
                    b.items = LibraryStyle.typeFolders.compactMap { k, l in
                        let n = modFiles.filter { ($0.s("doc_type") ?? "sonstiges") == k && $0.s("course_id") != "__user__" }.count
                        return n > 0 ? Item(id: seg[0] + "/" + k, kind: .folder, label: l, color: m?.s("color"), count: n, path: seg[0] + "/" + k) : nil
                    } + folders.filter { $0.i("module_id") == mid && $0["parent_id"]?.isNull != false }.map { f in
                        Item(id: "f\(f.i("id") ?? 0)", kind: .folder, label: f.s("name") ?? "", color: f.s("color") ?? m?.s("color"), count: count(f.i("id") ?? 0),
                             path: seg[0] + "/f\(f.i("id") ?? 0)", user: f)
                    } + modFiles.filter { $0.s("course_id") == "__user__" && $0["folder_id"]?.isNull != false }.map(doc)
                    if filter != "all" { b.items = byFilter(modFiles) }
                } else if seg[1].hasPrefix("f") {
                    let fid = Int(seg[1].dropFirst()) ?? 0
                    b.crumbs.append((folders.first { $0.i("id") == fid }?.s("name") ?? "Ordner", seg.joined(separator: "/")))
                    b.items = folders.filter { $0.i("parent_id") == fid }.map { f in
                        Item(id: "f\(f.i("id") ?? 0)", kind: .folder, label: f.s("name") ?? "", color: f.s("color") ?? m?.s("color"), count: count(f.i("id") ?? 0),
                             path: seg.joined(separator: "/") + "/f\(f.i("id") ?? 0)", user: f)
                    } + files.filter { $0.i("folder_id") == fid }.map(doc)
                } else {
                    let t = seg[1]
                    b.crumbs.append((LibraryStyle.typeFolders.first { $0.0 == t }?.1 ?? t, seg.joined(separator: "/")))
                    b.items = modFiles.filter { ($0.s("doc_type") ?? "sonstiges") == t && $0.s("course_id") != "__user__" }.map(doc)
                }
            } else if let cid = LibraryCourses.courseID(seg[0]) {
                // lokal: Kursordner mit allen Dokumenten des Kurses
                b.crumbs.append((courses.first { $0.s("id") == cid }?.s("title") ?? "Kurs", seg[0]))
                let courseFiles = files.filter { $0.s("course_id") == cid }
                b.items = filter == "all" ? courseFiles.map(doc) : byFilter(courseFiles)
            } else if seg[0].hasPrefix("f") {
                var parent = 0
                for (i, s) in seg.enumerated() {
                    let fid = Int(s.dropFirst()) ?? 0
                    b.crumbs.append((folders.first { $0.i("id") == fid }?.s("name") ?? "Ordner", seg[0...i].joined(separator: "/")))
                    parent = fid
                }
                b.items = folders.filter { $0.i("parent_id") == parent }.map { f in
                    Item(id: "f\(f.i("id") ?? 0)", kind: .folder, label: f.s("name") ?? "", color: f.s("color") ?? "#8b93a8", count: count(f.i("id") ?? 0),
                         path: path + "/f\(f.i("id") ?? 0)", user: f)
                } + files.filter { $0.i("folder_id") == parent }.map(doc)
            }
        }
        if !qq.isEmpty {
            b.items = files.filter { f in
                "\(f.s("title") ?? "") \(f.s("name") ?? "") \(f.s("ai_title") ?? "") \(f.s("subject") ?? "")".lowercased().contains(qq)
            }.map(doc)
        }
        // Ordner zuerst; Dokumente nach Name oder zuletzt bearbeitet (edited_at, dann chdate)
        let sortName = Self.sort == "name"
        b.items.sort { a, c in
            if (a.kind == .folder) != (c.kind == .folder) { return a.kind == .folder }
            guard a.kind != .folder else { return false }
            if sortName { return (a.f.s("title") ?? "").compare(c.f.s("title") ?? "", locale: Locale(identifier: "de_DE")) == .orderedAscending }
            let ea = a.f.s("edited_at") ?? "", ec = c.f.s("edited_at") ?? ""
            if ea != ec { return ea > ec }
            return (a.f.n("chdate") ?? 0) > (c.f.n("chdate") ?? 0)
        }
        return b
    }

    private func recentFiles(_ files: [JSONValue], limit: Int) -> [JSONValue] {
        files.filter { $0.s("last_opened") != nil || $0.s("edited_at") != nil }
            .sorted { ($0.s("edited_at") ?? $0.s("last_opened") ?? "") > ($1.s("edited_at") ?? $1.s("last_opened") ?? "") }
            .prefix(limit).map { $0 }
    }

    // MARK: Darstellung

    @ViewBuilder private func content(_ lib: JSONValue) -> some View {
        let _ = tick
        let b = build(lib)
        let section = self.section ?? "docs"
        let path = self.path ?? ""
        let curMod = path.hasPrefix("m") ? Int(path.components(separatedBy: "/")[0].dropFirst()) ?? 0 : 0
        // im Kursordner entsteht Neues auf der Stammebene (ein Kurs ist kein Ablageort eigener Dokumente)
        let inCourse = LibraryCourses.courseID(path) != nil
        let newCount = lib.list("files").filter { $0.s("status") == "neu" }.count
        let sectionTitle = ["fav": "Favoriten", "recent": "Zuletzt bearbeitet", "new": newTitle, "trash": "Papierkorb"][section]
        UFContent(maxWidth: 1480) {
            UFPageHead("Dokumente & Notizen", sub: "Alle Materialien deiner Module an einem Ort. Übersichtlich, schnell und fokussiert.") {
                searchField(section: section, path: path)
                UFSelect(options: [(0, "Alle Module")] + lib.list("modules").compactMap { m in m.i("id").map { ($0, m.s("name") ?? "") } },
                         selection: Binding(get: { curMod }, set: { v in router.go(.files(path: v == 0 ? nil : "m\(v)")) }))
                UFSelect(options: [("date", "Zuletzt bearbeitet"), ("name", "Name")], selection: Binding(get: { Self.sort }, set: { Self.sort = $0; tick += 1 }))
                UFIconSegmented(options: [("grid", "grid"), ("list", "list")], selection: $mode)
                UFButton("Neu", icon: "plus", kind: .primary) {
                    overlay.modal { LibraryNewDialog(lib: lib, path: inCourse ? "" : path, current: inCourse ? b.crumbs[0] : (b.crumbs.last ?? ("", ""))) }
                }
            }
            UFFlexWrap(gap: 9.6, justify: .between) {                         // .row.between.wrap
                UFFlexWrap(gap: 8) {                                         // .chips
                    ForEach(LibraryStyle.chips, id: \.0) { k, l in
                        UFLibChip(text: l, on: Self.filter == k && section == "docs") {
                            Self.filter = k
                            if section != "docs" { router.go(.files()) } else { tick += 1 }
                        }
                    }
                }
                HStack(spacing: 4.8) {
                    sectionLink("fav", "Favoriten", "star", section: section)
                    sectionLink("recent", "Zuletzt", "clock", section: section)
                    sectionLink("new", newTitle, "sparkles", section: section, badge: newCount)
                    sectionLink("trash", "Papierkorb", "trash", section: section)
                }
            }
            .padding(.bottom, 19.2)
            if !b.root { crumbs(b, section: section, title: sectionTitle).padding(.bottom, 16) }
            if section == "trash" {
                Text("Dokumente im Papierkorb lassen sich wiederherstellen. \(studip.university.profile.filesSource)-Dokumente bleiben erhalten, eigene Dokumente können endgültig gelöscht werden.")
                    .ufFont(13.12).foregroundStyle(UF.muted).padding(.vertical, 5.6)
            }
            if b.root {
                UFGridLayout(spacing: 19.2, minWidth: 290) {
                    ForEach(b.items.filter { $0.kind == .folder }) { it in LibraryFolderCard(it: it, open: { open(it) }, menu: { menu(it, lib: lib) }) }
                }
                .environment(\.ufFillsCell, true)
                let own = b.items.filter { $0.kind == .doc }
                if !own.isEmpty {
                    LibraryQuickCard(title: "Eigene Dokumente", icon: "note") {
                        itemsView(own, lib: lib, inCard: false)
                    }
                }
                let recent = recentFiles(lib.list("files"), limit: 4)
                LibraryQuickCard(title: "Schnellzugriff", icon: "clock", trailing: {
                    Button("Alle anzeigen →") { router.go(.files(section: "recent")) }.ufFont(13.12).foregroundStyle(UF.accentText).buttonStyle(.plain)
                }) {
                    if recent.isEmpty {
                        Text("Zuletzt geöffnete Dokumente erscheinen hier.").ufFont(13.12).foregroundStyle(UF.muted)
                    } else {
                        UFGridLayout(spacing: 12.8, minWidth: 230) {
                            ForEach(Row.rows(recent)) { row in
                                LibraryQuickItem(f: row.value, place: LibraryCourses.title(of: row.value, in: courses)) { openDoc(row.value) }
                            }
                        }
                        .environment(\.ufFillsCell, true)
                    }
                }
            } else if b.items.isEmpty {
                UFCard {
                    UFEmpty(icon: "folder", text: section == "trash" ? "Papierkorb ist leer." : !(q ?? "").isEmpty ? "Keine Treffer."
                            : "Hier ist noch nichts. Über „Neu“ ein Notizbuch anlegen oder eine PDF importieren.")
                }
            } else {
                itemsView(b.items, lib: lib, inCard: true)
            }
        }
    }

    @ViewBuilder private func itemsView(_ items: [Item], lib: JSONValue, inCard: Bool) -> some View {
        if mode == "grid" {
            UFGridLayout(spacing: 16, minWidth: 150) {                       // .lib-grid: gap 1.2rem 1rem
                ForEach(items) { it in LibraryGridItem(it: it, api: session.api, open: { open(it) }, menu: { menu(it, lib: lib) }, fav: { Task { await toggleFav(it.f) } }) }
            }
            .environment(\.ufFillsCell, false)
        } else {
            let list = VStack(spacing: 0) {
                ForEach(items) { it in LibraryListRow(it: it, api: session.api, open: { open(it) }, menu: { menu(it, lib: lib) }) }
            }
            if inCard {
                list.padding(ufB)
                    .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface))
                    .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(UF.line, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: UF.r))
                    .ufShadow(.sm)
            } else { list }
        }
    }

    private func searchField(section: String, path: String) -> some View {
        HStack(spacing: 0) {
            UFIcon("search", size: 15).foregroundStyle(UF.muted).padding(.leading, 10.4).padding(.trailing, 7.2)
            TextField("In Dokumenten suchen…", text: $query)
                .ufFont(14.5).foregroundStyle(UF.text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .onChange(of: query) { _, v in
                    searchTask?.cancel()
                    searchTask = Task {                                       // debounce 300 ms, setzt q= in der Route
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        guard !Task.isCancelled, v != (q ?? "") else { return }
                        router.go(.files(section: section, path: path.isEmpty ? nil : path, q: v.isEmpty ? nil : v))
                    }
                }
        }
        .padding(.vertical, 8 + ufB).padding(.trailing, 11.2 + ufB)
        .frame(width: 230)
        .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UF.surface))
        .overlay(RoundedRectangle(cornerRadius: UF.rSm).strokeBorder(UF.lineStrong, lineWidth: 1))
    }

    private func sectionLink(_ k: String, _ label: String, _ icon: String, section: String, badge: Int = 0) -> some View {
        let active = section == k
        return Button { router.go(.files(section: k)) } label: {
            HStack(spacing: 7.2) {
                UFIcon(icon, size: 14)
                Text(label)
                if badge > 0 { UFBadge("\(badge)") }
            }
        }
        .buttonStyle(UFButtonStyle(kind: .ghost, size: .small, activeFill: active))
    }

    private func crumbs(_ b: Built, section: String, title: String?) -> some View {
        UFFlexWrap(gap: 4.8) {
            if section != "docs" {
                Text(title ?? "").ufFont(20.8, 700).foregroundStyle(UF.text)
            } else {
                ForEach(b.crumbs.indices, id: \.self) { i in
                    let c = b.crumbs[i]
                    if i == b.crumbs.count - 1 {
                        Text(c.label).ufFont(20.8, 700).foregroundStyle(UF.text)
                    } else {
                        Button(c.label) { router.go(.files(path: c.path.isEmpty ? nil : c.path)) }.ufFont(14.4).foregroundStyle(UF.accentText).buttonStyle(.plain)
                        Text("›").ufFont(14.4).foregroundStyle(UF.muted)
                    }
                }
            }
            if let qq = q, !qq.isEmpty {
                Text("· Suche „\(qq)“").ufFont(14.4).foregroundStyle(UF.muted)
            } else if Self.filter != "all" && section == "docs" {
                Text("· \(LibraryStyle.chips.first { $0.0 == Self.filter }?.1 ?? "")").ufFont(14.4).foregroundStyle(UF.muted)
            }
        }
    }

    // MARK: Aktionen

    private func open(_ it: Item) {
        switch it.kind {
        case .folder: router.go(.files(path: it.path))
        case .doc: openDoc(it.f)
        case .trash: break
        }
    }

    private func openDoc(_ f: JSONValue) { if let id = f.s("id") { router.go(.doc(id)) } }

    private func toggleFav(_ f: JSONValue) async {
        guard let id = f.s("id") else { return }
        _ = try? await session.api?.value("/api/files/\(id)/favorite", method: "POST", body: ["favorite": .bool(f.i("favorite") != 1)])
        router.reload()
    }

    private func menu(_ it: Item, lib: JSONValue) {
        switch it.kind {
        case .folder:
            if let f = it.user { overlay.modal { LibraryFolderMenu(folder: f) } }
            else if let m = it.module { overlay.modal { LibraryModuleMenu(module: m) } }
        case .trash: overlay.modal { LibraryTrashMenu(id: it.f.s("id") ?? "") }
        case .doc: overlay.modal { LibraryDocMenu(f: it.f, lib: lib) }
        }
    }
}

// MARK: - Bausteine

/// .chips .chip: .45rem .95rem, .86rem, Radius 10, Flaeche --surface-2, ohne Rahmen
struct UFLibChip: View {
    let text: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text).ufFont(13.76, on ? 600 : 400)
                .foregroundStyle(on ? UF.accentText : UF.text2)
                .padding(.vertical, 7.2 + ufB).padding(.horizontal, 15.2 + ufB)
                .background(RoundedRectangle(cornerRadius: 10).fill(on ? UF.accentSoft : UF.surface2))
        }
        .buttonStyle(.plain)
    }
}

/// .quick-card: Radius 18, padding 1rem 1.2rem 1.2rem, Abstand 1.4rem nach oben
struct LibraryQuickCard<Trailing: View, Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    init(title: String, icon: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            UFCardHead(title, icon: icon) { trailing }
            content
        }
        .padding(.top, 16 + ufB).padding(.bottom, 19.2 + ufB).padding(.horizontal, 19.2 + ufB)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(UF.surface))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(UF.line, lineWidth: 1))
        .ufShadow(.sm)
        .padding(.top, 22.4)
    }
}

/// .folder-card: Welle, Mappe, Initialen-Kachel, Name, Kebab-Menue, Anzahl
struct LibraryFolderCard: View {
    let it: LibraryPage.Item
    let open: () -> Void
    let menu: () -> Void
    @Environment(\.ufFillsCell) private var fills

    var body: some View {
        let fc = Color(hex: it.color ?? "#4f8ef7")
        ZStack(alignment: .topLeading) {
            // .wave: radial-gradient(130% 95% at 90% 105%, Farbe 22 %, transparent 62 %), 135 pt hoch
            GeometryReader { g in
                EllipticalGradient(colors: [fc.opacity(0.22), fc.opacity(0)], center: UnitPoint(x: 0.9, y: 1.05),
                                   startRadiusFraction: 0, endRadiusFraction: 0.62)
                    .frame(width: g.size.width * 1.3 * 2, height: 135 * 0.95 * 2)
                    .position(x: g.size.width * 0.9, y: 135 * 1.05)
                    .frame(width: g.size.width, height: 135, alignment: .topLeading)
                    .clipped()
            }
            .frame(height: 135)
            VStack(alignment: .leading, spacing: 0) {
                UFFolderShape(color: fc).frame(width: 92, height: 70).padding(.top, 6.4).padding(.leading, 41.6).padding(.bottom, 24)
                HStack(alignment: .top, spacing: 9.6) {
                    Text(it.label).ufFont(16.32, 650, lh: 1.25).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // Kursordner (lokal) haben kein Menue
                    if it.user != nil || it.module != nil {
                        Button(action: menu) { UFIcon("more", size: 18).foregroundStyle(UF.muted).padding(3.2) }.buttonStyle(.plain).help("Mehr")
                    }
                }
                .padding(.leading, 56).frame(minHeight: 44, alignment: .top)
                Text("\(it.count) Dokument\(it.count == 1 ? "" : "e")").ufFont(12.8).foregroundStyle(UF.muted).padding(.leading, 56).padding(.top, 2.4)
            }
            .padding(.top, 22.4 + ufB).padding(.horizontal, 19.2 + ufB).padding(.bottom, 17.6 + ufB)
            // .ini: links 1.2rem, oben 7rem, 44 pt, Radius 12
            RoundedRectangle(cornerRadius: 12).fill(fc).frame(width: 44, height: 44)
                .overlay {
                    if it.module != nil { Text(UFFmt.initial(it.label)).font(.uf(14.4, 700)).foregroundStyle(.white) }
                    else { UFIcon("folder", size: 20).foregroundStyle(.white) }
                }
                .ufShadow(.md)
                .offset(x: 19.2 + ufB, y: 112 + ufB)
        }
        .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18).fill(UF.surface))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(UF.line, lineWidth: 1))
        .ufShadow(.sm)
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture(perform: open)
    }
}

/// .fold: Lasche (40 x 20, Radius 8 oben, Helligkeit .9) und Mappe mit Verlauf (Farbe 92 % -> 75 % mit Weiss) und Farbschatten
struct UFFolderShape: View {
    let color: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8).fill(color).brightness(-0.06)
                .frame(width: 40, height: 20).offset(y: -11)
            UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 10, bottomTrailingRadius: 10, topTrailingRadius: 10)
                .fill(LinearGradient(colors: [Color.mix(color, 0.92, .white), Color.mix(color, 0.75, .white)], startPoint: .top, endPoint: .bottom))
                .shadow(color: color.opacity(0.32), radius: 10, x: 0, y: 10)
        }
    }
}

/// .lib-folder (Unterebenen): 112 x 86, Radius 12, Lasche 46 x 16, Glanz
struct UFLibFolder: View {
    let color: Color
    var body: some View {
        ZStack(alignment: .topLeading) {
            UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8).fill(color).brightness(0.06)
                .frame(width: 46, height: 16).offset(y: -10)
            RoundedRectangle(cornerRadius: 12).fill(color)
                .overlay(RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [.black.opacity(0), .black.opacity(0.08)], startPoint: .center, endPoint: .bottom)))
                .ufShadow(.sm)
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom))
                .padding(.top, 6)
        }
        .frame(width: 112, height: 86)
    }
}

/// .lib-item: Mappe oder Vorschau, Name (2 Zeilen) mit Menuepfeil, Datum
struct LibraryGridItem: View {
    let it: LibraryPage.Item
    let api: APIClient?
    let open: () -> Void
    let menu: () -> Void
    let fav: () -> Void

    var body: some View {
        VStack(spacing: 6.4) {
            if it.kind == .folder {
                UFLibFolder(color: Color(hex: it.color ?? "#4f8ef7")).padding(.top, 10)
                name(it.label, menu: it.user != nil)
                Text("\(it.count) Dokumente").ufFont(11.84).foregroundStyle(UF.muted)
            } else {
                let f = it.f
                LibraryThumb(f: f, api: api, star: it.kind != .trash, favorite: f.i("favorite") == 1, fav: fav)
                name(f.s("title") ?? "", menu: true)
                date(f)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }

    private func name(_ s: String, menu show: Bool) -> some View {
        HStack(spacing: 3.2) {
            Text(s).ufFont(14.08, 500, lh: 1.25).foregroundStyle(UF.text).lineLimit(2).multilineTextAlignment(.center)
            if show { Button(action: menu) { UFIcon("chevron-down", size: 14).foregroundStyle(UF.accentText) }.buttonStyle(.plain) }
        }
        .frame(maxWidth: 150)
    }

    @ViewBuilder private func date(_ f: JSONValue) -> some View {
        if it.kind == .trash {
            Text("gelöscht " + UFFmt.date(f.s("deleted_at"))).ufFont(11.84).foregroundStyle(UF.muted)
        } else {
            let base = f.s("edited_at").map { "bearbeitet " + UFFmt.date($0) } ?? UFFmt.date(UFFmt.isoFromUnix(f.n("chdate")))
            (Text(base) + (f.s("status") == "neu" ? Text(" · ") + Text("Neu").font(.uf(11.84, 700)).foregroundColor(UF.accentText) : Text("")))
                .ufFont(11.84).foregroundStyle(UF.muted)
        }
    }
}

/// .lib-thumb: 112 x 86, Radius 6, weiss mit Rand; PDF-Vorschau der ersten Seite, Notizbuch liniert, Bild, Stern
struct LibraryThumb: View {
    let f: JSONValue
    let api: APIClient?
    var star = true
    var favorite = false
    var fav: () -> Void = {}
    @State private var image: UIImage?

    var body: some View {
        let kind = f.s("kind") ?? "pdf"
        let isPdf = kind == "pdf" && f.s("downloaded_at") != nil
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: 112, height: 86, alignment: .top).clipped()
                } else if kind == "notebook" {
                    Canvas { ctx, size in                                     // repeating-linear-gradient(#fff 0 9px, #e6e9f0 9px 10px)
                        var y: CGFloat = 9
                        while y < size.height { ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(Color(hex: 0xe6e9f0))); y += 10 }
                    }
                    .background(Color.white)
                    .overlay(UFIcon("note", size: 28).foregroundStyle(UF.lineStrong))
                } else {
                    (kind == "whiteboard" ? Color(hex: 0xfafbfd) : Color.white)
                        .overlay(UFIcon(isPdf ? "file-text" : kind == "whiteboard" ? "square" : "note", size: 28).foregroundStyle(UF.lineStrong))
                }
            }
            .frame(width: 112, height: 86)
            if star {
                Button(action: fav) {
                    UFIcon("star", size: 16).foregroundStyle(favorite ? UF.warn : UF.lineStrong).padding(.top, 4).padding(.trailing, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 112, height: 86)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(UF.line, lineWidth: 1))
        .ufShadow(.sm)
        .task(id: f.s("id")) {
            guard let api, let id = f.s("id") else { return }
            if isPdf || kind == "image" {
                image = await UFThumbnails.shared.image(fileID: id, version: f.s("edited_at") ?? "\(f.n("chdate") ?? 0)", image: kind == "image", api: api)
            }
        }
    }
}

/// .lib-list .lib-row: Spalten 44px 1fr 110px 120px 90px 36px
struct LibraryListRow: View {
    let it: LibraryPage.Item
    let api: APIClient?
    let open: () -> Void
    let menu: () -> Void
    @State private var image: UIImage?

    var body: some View {
        HStack(spacing: 9.6) {
            if it.kind == .folder {
                RoundedRectangle(cornerRadius: 6).fill(Color(hex: it.color ?? "#4f8ef7")).frame(width: 36, height: 36)
                    .overlay(UFIcon("folder", size: 16).foregroundStyle(.white)).frame(width: 44, alignment: .leading)
                Text(it.label).ufFont(14.08, 700).foregroundStyle(UF.text).frame(maxWidth: .infinity, alignment: .leading)
                Text("Ordner").ufFont(13.12).foregroundStyle(UF.muted).frame(width: 110, alignment: .leading)
                Text("\(it.count) Dokumente").ufFont(13.12).foregroundStyle(UF.muted).frame(width: 120, alignment: .leading)
                Color.clear.frame(width: 90, height: 1)
                Group { if it.user != nil { Button(action: menu) { UFIcon("more", size: 16).foregroundStyle(UF.accentText) }.buttonStyle(.plain) } else { Color.clear } }
                    .frame(width: 36)
            } else {
                let f = it.f
                let isPdf = f.s("kind") == "pdf" && f.s("downloaded_at") != nil
                let t = f.s("kind") == "pdf" ? (f.s("doc_type") ?? "pdf") : (f.s("kind") ?? "file")
                RoundedRectangle(cornerRadius: 6).fill(UF.surface2).frame(width: 36, height: 36)
                    .overlay {
                        if let image { Image(uiImage: image).resizable().scaledToFill().frame(width: 36, height: 36, alignment: .top).clipped() }
                        else { UFIcon(ShellState.typeIcon[t] ?? "file", size: 16).foregroundStyle(UF.text) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .frame(width: 44, alignment: .leading)
                    .task(id: f.s("id")) {
                        if isPdf, let api, let id = f.s("id") {
                            image = await UFThumbnails.shared.image(fileID: id, version: f.s("edited_at") ?? "\(f.n("chdate") ?? 0)", image: false, api: api)
                        }
                    }
                VStack(alignment: .leading, spacing: 0) {
                    Text(f.s("title") ?? "").ufFont(14.08, 700).foregroundStyle(UF.text)
                    if let ai = f.s("ai_title"), ai != f.s("title") { Text(f.s("name") ?? "").ufFont(11.84).foregroundStyle(UF.muted) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(ShellState.typeText[t] ?? "").ufFont(13.12).foregroundStyle(UF.muted).frame(width: 110, alignment: .leading)
                Text(f.s("subject") ?? "Eigene").ufFont(13.12).foregroundStyle(UF.muted).lineLimit(1).frame(width: 120, alignment: .leading)
                Text(f.s("edited_at").map { UFFmt.date($0) } ?? UFFmt.date(UFFmt.isoFromUnix(f.n("chdate")))).ufFont(13.12).foregroundStyle(UF.muted)
                    .frame(width: 90, alignment: .leading)
                Button(action: menu) { UFIcon("more", size: 16).foregroundStyle(UF.accentText) }.buttonStyle(.plain).frame(width: 36)
            }
        }
        .padding(.vertical, 7.2).padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .ufBorderBottom()
    }
}

/// .quick-item: Farbkachel je Typ, Titel, "Fach · vor N Tagen"
struct LibraryQuickItem: View {
    let f: JSONValue
    /// lokal: Kurs, wenn das Dokument noch kein Fach hat
    var place: String?
    let open: () -> Void
    @Environment(\.ufFillsCell) private var fills

    var body: some View {
        let t = LibraryStyle.fileType(f)
        let ic = f.s("kind") == "pdf" ? "file-text" : (ShellState.typeIcon[f.s("kind") ?? ""] ?? "file")
        HStack(spacing: 11.2) {
            RoundedRectangle(cornerRadius: 10).fill(Color(hex: LibraryStyle.fileColors[t] ?? LibraryStyle.fileColors["sonstiges"]!)).frame(width: 38, height: 38)
                .overlay(UFIcon(ic, size: 18).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 0) {
                Text(f.s("title") ?? "").ufFont(14.08, 700).foregroundStyle(UF.text).lineLimit(1)
                Text("\(f.s("subject") ?? place ?? "Eigene Notizen") · \(LibraryStyle.ago(f))").ufFont(11.84).foregroundStyle(UF.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9.6 + ufB).padding(.horizontal, 11.2 + ufB)
        .frame(maxHeight: fills ? .infinity : nil)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(UF.line, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }
}

// MARK: - PDF-Vorschauen (renderThumbnail)

/// Erste Seite als Bild (Breite 220 px wie im Web), im Speicher und auf der Platte zwischengespeichert;
/// Schluessel: Datei + Bearbeitungsstand, damit neue Fassungen eine neue Vorschau bekommen.
actor UFThumbnails {
    /// Vorschauen des aktiven Containers (Speicher und Platte je Apple-Nutzer und Hochschule getrennt)
    static var shared: UFThumbnails { ActiveContainer.current?.thumbnails ?? withoutContainer }
    private static let withoutContainer = UFThumbnails(root: ContainerPaths.none)
    private var memory: [String: UIImage] = [:]
    private let dir: URL
    /// Journal desselben Containers (Vorschau mit Notizen)
    private let journalRoot: URL

    init(root: URL) {
        dir = DataContainerLayout.Folder.thumbs.url(in: root)
        journalRoot = DataContainerLayout.Folder.journal.url(in: root)
    }

    /// Schluessel einer Vorschau: je Datenquelle getrennt (lokal und ein Server koennen dieselbe Datei-ID haben)
    nonisolated static func key(fileID: String, namespace: DataSourceNamespace, version: String) -> String {
        "\(namespace.id):\(fileID):\(version):220"
    }

    /// Anfang der Dateinamen aller Vorschauen einer Datei (der Schluessel enthaelt ":", `LocalJournalName.safe`
    /// schreibt ihn deshalb byteweise hexadezimal; das Praefix bleibt so ein Praefix)
    nonisolated static func fileNamePrefix(fileID: String, namespace: DataSourceNamespace) -> String {
        LocalJournalName.safe("\(namespace.id):\(fileID):")
    }

    func image(fileID: String, version: String, image isImage: Bool, api: APIClient) async -> UIImage? {
        let key = Self.key(fileID: fileID, namespace: api.namespace, version: version)
        if let m = memory[key] { return m }
        let file = dir.appendingPathComponent(LocalJournalName.safe(key) + ".jpg")
        if let d = try? Data(contentsOf: file), let img = UIImage(data: d) { memory[key] = img; return img }
        guard let (data, http) = try? await api.data("/api/files/\(fileID)/content"), (200..<300).contains(http.statusCode) else { return nil }
        var out: UIImage?
        if isImage {
            out = UIImage(data: data)
        } else if let doc = PDFDocument(data: data), let page = doc.page(at: 0) {
            let b = page.bounds(for: .mediaBox)
            let w: CGFloat = 220
            out = Self.inkThumbnail(journal: LocalJournal(store: FileBlobStore(root: journalRoot), documentID: fileID, namespace: api.namespace),
                                    pdf: doc, width: w)
                ?? page.thumbnail(of: CGSize(width: w, height: w * b.height / max(1, b.width)), for: .mediaBox)
        }
        guard let out else { return nil }
        memory[key] = out
        // nur im bestehenden Container (wie ResponseCache.store): nach dem Loeschen kein neuer Ordner ohne Kennzeichnung
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        try? DataContainerLayout.setExcludedFromBackup(dir)                               // Vorschauen von Stud.IP-Dateien: nur auf dem Geraet
        try? out.jpegData(compressionQuality: 0.75)?.write(to: file, options: .atomic)
        return out
    }

    /// Erste PDF-Seite mit den Notizen aus dem lokalen Journal (nur Dokumente, die auf diesem Geraet schon offen
    /// waren; ohne Netzwerk). Gleiche Zeichenroutine wie PDF-Export und Seitenminiaturen. `nil` = keine Notizen.
    /// Journal frei waehlbar (testbar mit eigenem Ordner).
    static func inkThumbnail(journal: LocalJournal, pdf: PDFDocument, width: CGFloat) -> UIImage? {
        guard let snap = try? journal.load() else { return nil }
        let doc = AnnotationDocument(rootMeta: snap.rootMeta, pages: snap.pages.mapValues(\.page))
        let key = doc.pageKey(forPDFIndex: 1) ?? "p1"
        let objects = doc.objects(page: key)
        guard !objects.isEmpty else { return nil }
        let layout = DisplayLayout.build(original: pdf, document: doc)
        guard let i = layout.index(ofKey: key), let page = layout.pdf.page(at: i), let entry = layout.entry(at: i) else { return nil }
        return PageRenderer.thumbnail(page: page, entry: entry, objects: objects, images: [:], width: width)
    }
}

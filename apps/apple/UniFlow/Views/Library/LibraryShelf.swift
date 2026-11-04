import SwiftUI
import UniFlowCore

// "Mein Regal" (04.11.2026): ruhiges, sehr ordentliches digitales Buecherregal unter Dokumente & Notizen (Umschalter
// "Ordner | Regal"). Daten: GET /api/index/shelf (lokales Backend, docs/DOKUMENT-INDEX-2026-11-04.md). Studiengang und
// Semester sind Abschnittskoepfe, jedes Modul ein Regal in seiner Fachfarbe, jede Lehrwoche ein Brett mit Datum, jede
// Art ein kleines Etikett in der Farbe der Community-Etiketten (`CommunityChannelKind.pair`), jede Datei ein Buch mit
// Titel, Seitenzahl, "erklärt" (Index fertig) und den Seiten mit eigenen Notizen. Auch Dateien ohne Index stehen darin,
// eingeordnet aus den lokalen Daten. Antippen oeffnet das Dokument.

/// Regal aus `GET /api/index/shelf`, in der Reihenfolge des Kerns (Studiengaenge und Module nach Name, Semester
/// neueste zuerst, Wochen wie das Moduldetail, Arten fest, Dateien nach Name)
struct ShelfTree: Equatable {
    struct File: Equatable, Identifiable {
        let id: String
        let name: String
        let title: String
        /// Datum der Datei (YYYY-MM-DD), "" ohne Datum
        let date: String
        let pageCount: Int?
        let indexedPages: Int
        /// ready | partial | none
        let status: String
        let kind: String
        let kindLabel: String
        /// Seiten mit eigenen Notizen (nur lokal)
        let notePages: Int
        let downloaded: Bool

        var explained: Bool { status == "ready" }
        var partial: Bool { status == "partial" }

        init(_ j: JSONValue) {
            id = j.s("file_id") ?? ""
            name = j.s("name") ?? ""
            title = j.s("title").flatMap { $0.isEmpty ? nil : $0 } ?? name
            date = j.s("date") ?? ""
            pageCount = j.i("page_count")
            indexedPages = j.i("indexed_pages") ?? 0
            status = j.s("status") ?? "none"
            kind = j.s("kind") ?? "sonstiges"
            kindLabel = j.s("kind_label") ?? DocIndexCatalog.kindLabels[kind] ?? kind
            notePages = j.i("note_pages") ?? 0
            downloaded = j["downloaded"]?.bool ?? true
        }
    }

    struct Kind: Equatable, Identifiable {
        let kind: String
        let label: String
        let files: [File]
        var id: String { kind }
    }

    struct Week: Equatable, Identifiable {
        let week: Int
        /// "Woche 2 · 26.10. – 01.11." bzw. "Klausuren & Altklausuren"
        let label: String
        let from: String
        let to: String
        let kinds: [Kind]
        var id: Int { week }
        var files: [File] { kinds.flatMap(\.files) }

        /// "Woche 2" (vor dem Mittelpunkt), sonst die ganze Bezeichnung
        var title: String { label.components(separatedBy: " · ").first ?? label }

        /// Daten der Woche ("26.10. – 01.11."); ohne Lehrwoche die Spanne der Dateidaten
        var dates: String {
            let parts = label.components(separatedBy: " · ")
            if parts.count > 1 { return parts.dropFirst().joined(separator: " · ") }
            return ShelfTree.range(from, to)
        }
    }

    struct Module: Equatable, Identifiable {
        let name: String
        let moduleID: Int?
        let key: String
        /// Fachfarbe "#rrggbb", nil ohne Modul
        let color: String?
        let weeks: [Week]
        var id: String { moduleID.map { "m\($0)" } ?? (key.isEmpty ? "n:" + name : key) }
        var files: [File] { weeks.flatMap(\.files) }
    }

    struct Semester: Equatable, Identifiable {
        let name: String
        let modules: [Module]
        var id: String { name }
    }

    struct Program: Equatable, Identifiable {
        let name: String
        let semesters: [Semester]
        var id: String { name }
    }

    var university: String
    var programs: [Program]
    /// Dateien im Regal, davon mit Index (ganz oder teilweise) und ganz erklaert
    var files: Int
    var indexed: Int
    var explained: Int

    init(json j: JSONValue) {
        university = j["university"]?.s("name") ?? ""
        programs = (j["programs"]?.array ?? []).map { p in
            Program(name: p.s("name") ?? "", semesters: (p["semesters"]?.array ?? []).map { s in
                Semester(name: s.s("name") ?? "", modules: (s["modules"]?.array ?? []).map { m in
                    Module(name: m.s("name") ?? "", moduleID: m.i("module_id"), key: m.s("key") ?? "", color: m.s("color"),
                           weeks: (m["weeks"]?.array ?? []).map { w in
                               Week(week: w.i("week") ?? 0, label: w.s("label") ?? "", from: w.s("from") ?? "", to: w.s("to") ?? "",
                                    kinds: (w["kinds"]?.array ?? []).map { k in
                                        Kind(kind: k.s("kind") ?? "sonstiges", label: k.s("label") ?? "", files: (k["files"]?.array ?? []).map(File.init))
                                    })
                           })
                })
            })
        }
        let all = programs.flatMap { $0.semesters.flatMap { $0.modules.flatMap(\.files) } }
        files = j.i("files") ?? all.count
        indexed = j.i("indexed") ?? all.filter { $0.status != "none" }.count
        explained = j.i("explained") ?? all.filter(\.explained).count
    }

    /// Alle Module (fuer die Auswahl), je Kennung einmal, in der Reihenfolge des Regals
    var moduleChoices: [(id: String, name: String)] {
        var seen = Set<String>()
        return programs.flatMap { $0.semesters.flatMap(\.modules) }.compactMap { m in seen.insert(m.id).inserted ? (m.id, m.name) : nil }
    }

    /// Nur ein Modul (leere Semester und Studiengaenge fallen weg); "" = alles
    func only(module id: String) -> ShelfTree {
        guard !id.isEmpty else { return self }
        var t = self
        t.programs = programs.compactMap { p in
            let semesters = p.semesters.compactMap { s -> Semester? in
                let mods = s.modules.filter { $0.id == id }
                return mods.isEmpty ? nil : Semester(name: s.name, modules: mods)
            }
            return semesters.isEmpty ? nil : Program(name: p.name, semesters: semesters)
        }
        return t
    }

    /// "27.10." aus "2026-10-27"; "" ohne Datum
    static func short(_ iso: String) -> String {
        let p = iso.prefix(10).split(separator: "-")
        guard p.count == 3 else { return "" }
        return "\(p[2]).\(p[1])."
    }

    /// "20.10. – 27.10." bzw. ein Tag; "" ohne Daten
    static func range(_ from: String, _ to: String) -> String {
        let a = short(from), b = short(to)
        if a.isEmpty { return b }
        return b.isEmpty || a == b ? a : "\(a) – \(b)"
    }

    /// "Notizen auf 2 Seiten"
    static func notesText(_ n: Int) -> String { n == 1 ? "Notizen auf 1 Seite" : "Notizen auf \(n) Seiten" }

    /// Was VoiceOver zu einem Buch sagt: Titel, Art, Seiten, Stand des Index, Notizen, geladen
    static func spoken(_ f: File) -> String {
        var parts = [f.title, f.kindLabel]
        if let n = f.pageCount { parts.append(n == 1 ? "1 Seite" : "\(n) Seiten") }
        if f.explained { parts.append("erklärt") } else if f.partial { parts.append("teilweise erklärt") }
        if f.notePages > 0 { parts.append(notesText(f.notePages)) }
        if !f.downloaded { parts.append("nicht geladen") }
        return parts.joined(separator: ", ")
    }

    /// Kopfzeile des Regals: "24 Dateien · 6 erklärt"
    var summary: String {
        "\(files == 1 ? "1 Datei" : "\(files) Dateien") · \(explained) erklärt"
    }
}

/// Texte des Regals
enum LibraryShelf {
    /// Leerzustand und Hinweis, solange nichts eingeordnet ist (Vorgabe des Inhabers)
    static let emptyText = "Noch nichts eingeordnet – öffne eine Datei mit KI-Hilfe"
    /// Mit eigenem Server gibt es das Regal (noch) nicht: es ist eine Abfrage des lokalen Backends
    static let serverText = "Das Regal entsteht auf dem iPad: es ordnet die Dateien, die StudiNow direkt aus deiner Hochschule lädt."
    static let subtitle = "Jede Datei an ihrem Platz – nach Semester, Modul, Woche und Art."
}

/// Farben und Symbole der Arten: dieselben weichen Paare wie die Etiketten der Community (`CommunityChannelKind.pair`);
/// Arten, die es dort nicht gibt, aus derselben Palette (Skript Butter, Lösung Flieder), Sonstiges neutral
enum ShelfKindStyle {
    static let neutral = CommunityPair(bg: UF.surface2, fg: UF.text2, solid: UF.lineStrong)

    static func pair(_ kind: String) -> CommunityPair {
        switch kind {
        case "vorlesung": return CommunityChannelKind.vorlesung.pair
        case "uebung": return CommunityChannelKind.uebung.pair
        case "hoersaaluebung": return CommunityChannelKind.hoersaaluebung.pair
        case "gruppenuebung": return CommunityChannelKind.gruppenuebung.pair
        case "tutorium": return CommunityChannelKind.tutorium.pair
        case "klausur", "altklausur": return CommunityChannelKind.klausur.pair
        case "skript": return CommunityPalette.butter
        case "loesung": return CommunityPalette.lilac
        default: return neutral
        }
    }

    static func icon(_ kind: String) -> String {
        switch kind {
        case "vorlesung": return CommunityChannelKind.vorlesung.icon
        case "uebung": return CommunityChannelKind.uebung.icon
        case "hoersaaluebung": return CommunityChannelKind.hoersaaluebung.icon
        case "gruppenuebung": return CommunityChannelKind.gruppenuebung.icon
        case "tutorium": return CommunityChannelKind.tutorium.icon
        case "klausur", "altklausur": return CommunityChannelKind.klausur.icon
        case "skript": return "file-text"
        case "loesung": return "check"
        default: return "file"
        }
    }
}

// MARK: - Ansicht

/// "Mein Regal": Kopf mit Zahlen und Modulauswahl, Hinweis solange nichts eingeordnet ist, dann je Studiengang und
/// Semester die Regale der Module
struct LibraryShelfView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var router: UFRouter
    @State private var tree: ShelfTree?
    @State private var error: String?
    /// gewaehltes Modul ("" = alle)
    @State private var module = ""

    var body: some View {
        Group {
            if let tree { content(tree) } else if let error {
                UFCard { UFEmpty(icon: "book", text: error) }.accessibilityIdentifier("shelf.error")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    UFSkeleton().frame(width: 220, height: 24)
                    UFSkeleton().frame(height: 220)
                }
            }
        }
        .task { await load() }
        .ufReload { await load() }
    }

    private func load() async {
        guard let api = session.api else { error = "Nicht mit dem Server verbunden."; return }
        do {
            tree = ShelfTree(json: try await api.value("/api/index/shelf"))
            error = nil
        } catch {
            // neu laden gescheitert: der letzte Stand bleibt
            if tree == nil { self.error = api.isLocal ? "Das Regal ließ sich nicht laden: \(error.localizedDescription)" : LibraryShelf.serverText }
        }
    }

    @ViewBuilder private func content(_ full: ShelfTree) -> some View {
        let t = full.only(module: module)
        VStack(alignment: .leading, spacing: 0) {
            head(full)
            if full.files == 0 {
                UFCard {
                    UFEmpty(icon: "book", text: LibraryShelf.emptyText) {
                        UFButton("Zu den Ordnern", icon: "folder", size: .small) { router.go(.files()) }
                            .padding(.top, 6)
                    }
                }
                .accessibilityIdentifier("shelf.empty")
            } else {
                if full.indexed == 0 { hint }
                ForEach(t.programs) { p in
                    ForEach(p.semesters) { s in
                        semesterHeader(program: p.name, semester: s.name)
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(s.modules) { m in ShelfModuleShelf(module: m) { router.go(.doc($0.id)) } }
                        }
                        .padding(.bottom, 28)
                    }
                }
            }
        }
    }

    /// "Mein Regal", Zahlen und (ab zwei Modulen) die Auswahl eines Moduls
    private func head(_ t: ShelfTree) -> some View {
        UFFlexWrap(gap: 12, rowGap: 10, justify: .between) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Mein Regal").ufFont(20.8, 700, em: -0.01).foregroundStyle(UF.text).accessibilityAddTraits(.isHeader)
                Text([t.university, t.files > 0 ? t.summary : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .ufFont(13.12).foregroundStyle(UF.muted)
                    .accessibilityIdentifier("shelf.summary")
            }
            let choices = t.moduleChoices
            if choices.count > 1 {
                UFSelect(options: [("", "Alle Module")] + choices.map { ($0.id, $0.name) }, selection: $module)
                    .accessibilityLabel("Modul")
                    .accessibilityIdentifier("shelf.module")
            }
        }
        .padding(.bottom, 18)
    }

    /// Hinweis ueber dem Regal, solange keine Datei eingeordnet ist (die Dateien stehen trotzdem schon darin)
    private var hint: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            UFIcon("sparkles", size: 16).foregroundStyle(UF.accentText).accessibilityHidden(true)
            Text(LibraryShelf.emptyText).ufFont(13.6).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11).padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: UF.r, style: .continuous).fill(UF.accentSoft))
        .padding(.bottom, 20)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("shelf.hint")
    }

    /// Abschnittskopf: Studiengang klein darueber, Semester gross
    private func semesterHeader(program: String, semester: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(program.uppercased()).ufFont(11.52, 650, em: 0.06).foregroundStyle(UF.muted)
            Text(semester.isEmpty ? "Ohne Semester" : semester).ufFont(18.4, 700, em: -0.01).foregroundStyle(UF.text)
        }
        .padding(.bottom, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(program), \(semester.isEmpty ? "Ohne Semester" : semester)")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("shelf.semester")
    }
}

/// Regal eines Moduls: blasse Flaeche in der Fachfarbe, Kopf mit Kuerzel-Kachel und Zahlen, je Lehrwoche ein Brett
struct ShelfModuleShelf: View {
    let module: ShelfTree.Module
    let open: (ShelfTree.File) -> Void

    private var tint: Color {
        Color(hex: module.color ?? CommunityTint.hex(module.key.isEmpty ? module.name : module.key))
    }

    var body: some View {
        let c = tint
        let files = module.files
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(c)
                    .frame(width: 34, height: 34)
                    .overlay(Text(UFFmt.initial(module.name)).font(.uf(14.4, 700)).foregroundStyle(.white))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(module.name).ufFont(16.32, 650, lh: 1.25).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                    let explained = files.filter(\.explained).count
                    Text("\(files.count == 1 ? "1 Datei" : "\(files.count) Dateien") · \(explained) erklärt").ufFont(12.8).foregroundStyle(UF.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 6)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("shelf.module.\(module.id)")
            ForEach(Array(module.weeks.enumerated()), id: \.element.id) { i, w in
                ShelfWeekRow(week: w, tint: c, moduleID: module.id, last: i == module.weeks.count - 1, open: open)
            }
        }
        .padding(.top, 16).padding(.horizontal, 18).padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.mix(c, 0.07, UF.bg)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.mix(c, 0.22, UF.line), lineWidth: 1))
    }
}

/// Brett einer Lehrwoche: links Woche und Datum, rechts je Art Etikett und Buecher, darunter das Brett in der Fachfarbe
struct ShelfWeekRow: View {
    let week: ShelfTree.Week
    let tint: Color
    let moduleID: String
    var last = false
    let open: (ShelfTree.File) -> Void
    @Environment(\.ufWindowWidth) private var windowWidth
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var labelWidth: CGFloat = 132
    @ScaledMetric(relativeTo: .body) private var bookWidth: CGFloat = 168

    var body: some View {
        // schmal oder sehr grosse Schrift: Woche ueber den Buechern statt daneben
        let stacked = windowWidth <= 760 || typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        VStack(alignment: .leading, spacing: 0) {
            layout {
                weekLabel.frame(width: stacked ? nil : labelWidth, alignment: .leading)
                // die Arten nebeneinander wie Abschnitte eines Bretts (Etikett ueber ihren Buechern), umbrechend
                ShelfFlow(spacing: 22, rowSpacing: 14) {
                    ForEach(week.kinds) { k in
                        VStack(alignment: .leading, spacing: 8) {
                            ShelfKindTag(kind: k.kind, label: k.label, count: k.files.count)
                                .accessibilityIdentifier("shelf.kind.\(moduleID).\(week.week).\(k.kind)")
                            ShelfFlow(spacing: 10, rowSpacing: 10) {
                                ForEach(k.files) { f in ShelfBook(file: f) { open(f) }.frame(width: bookWidth) }
                            }
                        }
                        // VoiceOver liest je Art Etikett und Buecher zusammen (nicht erst alle Etiketten der Zeile)
                        .accessibilityElement(children: .contain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // das Brett, auf dem die Buecher der Woche stehen
            Capsule().fill(Color.mix(tint, 0.32, UF.surface)).frame(height: 4)
                .padding(.top, 12)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 10)
    }

    private var weekLabel: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(week.title).ufFont(13.6, 650, lh: 1.3).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
            if !week.dates.isEmpty {
                Text(week.dates).ufFont(12.48, lh: 1.3).foregroundStyle(UF.muted).monospacedDigit()
            }
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("shelf.week.\(moduleID).\(week.week)")
    }
}

/// Fluss von links nach rechts mit Umbruch, oben buendig (Buecher einer Art, Arten einer Woche). Ein Element, das
/// allein breiter ist als die Zeile (eine Art mit vielen Buechern), bekommt die Zeilenbreite und bricht in sich um.
struct ShelfFlow: Layout {
    var spacing: CGFloat = 10
    var rowSpacing: CGFloat = 10

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
        var out: [[(index: Int, size: CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, s) in subviews.enumerated() {
            var size = s.sizeThatFits(.unspecified)
            if size.width > width {
                size = s.sizeThatFits(ProposedViewSize(width: width, height: nil))
                size.width = min(size.width, width)
            }
            if !out[out.count - 1].isEmpty && x + spacing + size.width > width + 0.5 { out.append([]); x = 0 }
            x = out[out.count - 1].isEmpty ? size.width : x + spacing + size.width
            out[out.count - 1].append((i, size))
        }
        return out.filter { !$0.isEmpty }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(1, proposal.width ?? .infinity)
        let rs = rows(subviews, width: width)
        let w = rs.map { r in r.map(\.size.width).reduce(0, +) + spacing * CGFloat(max(0, r.count - 1)) }.max() ?? 0
        let h = rs.map { r in r.map(\.size.height).max() ?? 0 }.reduce(0, +) + rowSpacing * CGFloat(max(0, rs.count - 1))
        return CGSize(width: min(w, width), height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for r in rows(subviews, width: max(1, bounds.width)) {
            var x = bounds.minX
            for item in r {
                subviews[item.index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                           proposal: ProposedViewSize(width: item.size.width, height: item.size.height))
                x += item.size.width + spacing
            }
            y += (r.map(\.size.height).max() ?? 0) + rowSpacing
        }
    }
}

/// Kleines Etikett der Art in den Farben der Community-Etiketten
struct ShelfKindTag: View {
    let kind: String
    let label: String
    var count = 0

    var body: some View {
        let pair = ShelfKindStyle.pair(kind)
        HStack(spacing: 4) {
            UFIcon(ShelfKindStyle.icon(kind), size: 11)
            Text(label)
        }
        .ufFont(11.52, 620)
        .lineLimit(1)
        .foregroundStyle(pair.fg)
        .padding(.vertical, 3).padding(.horizontal, 8)
        .background(Capsule().fill(pair.bg))
        .overlay(Capsule().strokeBorder(pair.fg.opacity(0.14), lineWidth: 1))   // auch auf gleichfarbigem Regal sichtbar
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count > 0 ? "\(label), \(count == 1 ? "1 Datei" : "\(count) Dateien")" : label)
    }
}

/// Eine Datei als Buch: Ruecken in der Farbe der Art, Titel (bis drei Zeilen), Abzeichen "erklärt" und Notizen,
/// darunter Seitenzahl und Datum. Ganze Flaeche antippbar (mindestens 112 pt hoch).
struct ShelfBook: View {
    let file: ShelfTree.File
    let open: () -> Void
    @ScaledMetric(relativeTo: .body) private var minHeight: CGFloat = 112

    private var meta: String {
        var parts: [String] = []
        if let n = file.pageCount { parts.append(n == 1 ? "1 Seite" : "\(n) Seiten") }
        let d = ShelfTree.short(file.date)
        if !d.isEmpty { parts.append(d) }
        if !file.downloaded { parts.append("nicht geladen") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let pair = ShelfKindStyle.pair(file.kind)
        Button(action: open) {
            HStack(spacing: 0) {
                Rectangle().fill(pair.solid).frame(width: 5)
                VStack(alignment: .leading, spacing: 8) {
                    Text(file.title).ufFont(13.6, 600, lh: 1.3).foregroundStyle(file.downloaded ? UF.text : UF.text2)
                        .lineLimit(3).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                    if file.explained || file.partial || file.notePages > 0 {
                        UFFlexWrap(gap: 4, rowGap: 4) {
                            if file.explained { UFBadge("erklärt", tone: .ok, icon: "check") }
                            else if file.partial { UFBadge("teilweise erklärt", tone: .neutral, icon: "sparkles") }
                            if file.notePages > 0 { UFBadge(file.notePages == 1 ? "1 Seite Notizen" : "\(file.notePages) Seiten Notizen", tone: .accent, icon: "pencil") }
                        }
                    }
                    if !meta.isEmpty { Text(meta).ufFont(11.52).foregroundStyle(UF.muted).lineLimit(1).monospacedDigit() }
                }
                .padding(.vertical, 10).padding(.leading, 11).padding(.trailing, 10)
            }
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .background(UF.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(UF.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(UFPressStyle())
        .accessibilityLabel(ShelfTree.spoken(file))
        .accessibilityHint("Öffnet das Dokument")
        .accessibilityIdentifier("shelf.file.\(file.id)")
    }
}

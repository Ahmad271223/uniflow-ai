import SwiftUI
import UniFlowCore

// Kanal einer Community nach dem Vorbild Studydrive, aber nach Lehrwoche geordnet (Wunsch des Inhabers 03.11.2026):
// je Woche eine waagerechte Reihe Karten (Vorlesung, Hoersaaluebung, Uebung, Gruppenuebung, Tutorium, Klausur, eigene
// Notizen) mit der ersten Seite als Vorschau. Tippen auf eine Karte zeigt, wer dazu Notizen geteilt hat; Tippen auf eine
// Person zeigt ihre Notizen, mit Pfeilen oder Wischen geht es zur naechsten bzw. vorherigen Person. Likes und
// Kommentare stehen im Reiter "Diskussion (N)" neben "Dokument" (nur wenn der Dienst sie kann: `supportsDiscussion`).

// MARK: - Einordnung (testbar)

/// Art eines geteilten Blatts; die Reihenfolge ist die der Karten in einer Woche
enum CommunityChannelKind: Int, CaseIterable, Comparable, Sendable {
    case vorlesung, hoersaaluebung, uebung, gruppenuebung, tutorium, klausur, notizen

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .vorlesung: return "Vorlesung"
        case .hoersaaluebung: return "Hörsaalübung"
        case .uebung: return "Übung"
        case .gruppenuebung: return "Gruppenübung"
        case .tutorium: return "Tutorium"
        case .klausur: return "Klausur"
        case .notizen: return "Eigene Notizen"
        }
    }

    var icon: String {
        switch self {
        case .vorlesung: return "book"
        case .hoersaaluebung: return "columns"
        case .uebung: return "pencil"
        case .gruppenuebung: return "users"
        case .tutorium: return "graduation"
        case .klausur: return "exam"
        case .notizen: return "note"
        }
    }

    /// Schriftfarbe des Etiketts (Textstufe des Pastellpaars, kontrastsicher in hell und dunkel; `pair` in
    /// CommunityStyle.swift)
    var tint: Color { pair.fg }

    /// Einordnung eines geteilten Blatts: zuerst die eigene Datei (Bezeichnung `sub_label`, sonst `doc_type`, wie die
    /// Bibliothek), sonst der Titel (dieselben Muster, `StudyClassify.effectiveType`); nichts davon = eigene Notizen.
    /// Sagt die Datei nur "Übung", der Titel aber Gruppen-, Hoersaaluebung oder Tutorium, gilt das genauere.
    static func classify(subLabel: String?, docType: String?, title: String) -> Self {
        let fromFile = fromLabel(subLabel) ?? fromType(docType)
        let fromTitle = fromLabel(title) ?? fromLabel(StudyClassify.effectiveType(name: title, folder: nil, aiType: nil).label)
        if fromFile == .uebung, let t = fromTitle, [.hoersaaluebung, .gruppenuebung, .tutorium].contains(t) { return t }
        return fromFile ?? fromTitle ?? .notizen
    }

    /// Bezeichnung wie "Gruppenübung", "Altklausur", "Lösung" (auch Freitext) → Art; nil = nichts erkannt
    static func fromLabel(_ raw: String?) -> Self? {
        let l = (raw ?? "").lowercased()
        guard !l.isEmpty else { return nil }
        func has(_ words: String...) -> Bool { words.contains { l.contains($0) } }
        if has("klausur", "kurztest", "probeklausur") { return .klausur }
        if has("gruppenübung", "gruppenuebung") { return .gruppenuebung }
        if has("hörsaal", "hoersaal", "zentralübung", "zentraluebung") { return .hoersaaluebung }
        if has("tutorium", "tutorien") { return .tutorium }
        if has("übung", "uebung", "lösung", "loesung", "übungsblatt", "aufgabenblatt") { return .uebung }
        if has("vorlesung", "folien", "skript", "mitschrift") { return .vorlesung }
        return nil
    }

    static func fromType(_ type: String?) -> Self? {
        switch type {
        case "vorlesung", "skript": return .vorlesung
        case "uebung", "loesung": return .uebung
        case "klausur": return .klausur
        default: return nil
        }
    }
}

/// Eigene Datei zu einem geteilten Blatt (Vorschau, Einordnung, "In meiner PDF oeffnen")
struct CommunityChannelFile: Equatable, Sendable {
    let id: String
    let title: String
    var subLabel: String?
    var docType: String?
    /// Stand der Vorschau (aendert sich die Datei, entsteht eine neue)
    var version: String = ""
    var isPDF = true
}

/// Ein Blatt einer Woche mit allen Personen, die Notizen dazu geteilt haben
struct CommunityChannelItem: Identifiable, Equatable {
    let id: String
    let kind: CommunityChannelKind
    let title: String
    let week: Int
    /// eigene zuerst, dann meistgelikt, dann neueste
    let people: [CommunitySolutionSummary]
    let file: CommunityChannelFile?

    var commentCount: Int { people.reduce(0) { $0 + $1.commentCount } }

    /// "2 Personen · 3 Kommentare" (Kommentare nur, wenn der Dienst sie kennt)
    func detail(discussion: Bool) -> String {
        if people.isEmpty { return "Noch niemand geteilt" }
        var parts = [people.count == 1 ? "1 Person" : "\(people.count) Personen"]
        if discussion { parts.append(commentCount == 1 ? "1 Kommentar" : "\(commentCount) Kommentare") }
        return parts.joined(separator: " · ")
    }
}

struct CommunityChannelWeek: Identifiable, Equatable {
    let week: Int
    let items: [CommunityChannelItem]
    var id: Int { week }
}

enum CommunityChannel {
    /// Titel zum Vergleichen (wie die Dateien des Moduls: ohne Endung und Kuerzel, klein)
    static func titleKey(_ title: String) -> String {
        ShareExport.cleanTitle(title).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Loesungen zu Blaettern buendeln (gleicher Fingerabdruck oder gleicher Titel = dasselbe Blatt), nach Lehrwoche
    /// ordnen (ohne Woche zuletzt), in der Woche nach Art und Titel.
    static func build(_ list: [CommunitySolutionSummary], file: (CommunitySolutionSummary) -> CommunityChannelFile? = { _ in nil },
                      skeleton: [(file: CommunityChannelFile, week: Int)] = []) -> [CommunityChannelWeek] {
        var groups: [[CommunitySolutionSummary]] = []
        var byPrint: [String: Int] = [:], byTitle: [String: Int] = [:]
        for s in list {
            let t = titleKey(s.title)
            let index = (s.fingerprint.isEmpty ? nil : byPrint[s.fingerprint]) ?? (t.isEmpty ? nil : byTitle[t])
            let i: Int
            if let index { i = index; groups[i].append(s) } else { i = groups.count; groups.append([s]) }
            if !s.fingerprint.isEmpty, byPrint[s.fingerprint] == nil { byPrint[s.fingerprint] = i }
            if !t.isEmpty, byTitle[t] == nil { byTitle[t] = i }
        }
        let items = groups.map { people -> CommunityChannelItem in
            let own = people.lazy.compactMap(file).first
            let title = people.first { !$0.title.isEmpty }?.title ?? own?.title ?? "Ohne Titel"
            let weeks = people.map(\.week).filter { $0 > 0 }
            let sorted = people.sorted { a, b in
                if a.isOwn != b.isOwn { return a.isOwn }
                if a.likes != b.likes { return a.likes > b.likes }
                return a.createdAt > b.createdAt
            }
            let first = people[0]
            return CommunityChannelItem(id: first.fingerprint.isEmpty ? "t:\(titleKey(title))" : "f:\(first.fingerprint)",
                                        kind: .classify(subLabel: own?.subLabel, docType: own?.docType, title: title),
                                        title: title, week: weeks.min() ?? 0, people: sorted, file: own)
        }
        // Blaetter des Moduls ohne geteilte Notizen stehen trotzdem in ihrer Woche (03.11.2026: der Kanal zeigt die
        // Woche wie im Modul, nicht nur das Geteilte)
        var all = items
        var covered = Set(items.map { titleKey($0.title) })
        for id in items.compactMap({ $0.file?.id }) { covered.insert("id:" + id) }
        for (f, week) in skeleton {
            let t = titleKey(f.title)
            guard !t.isEmpty, !covered.contains(t), !covered.contains("id:" + f.id) else { continue }
            covered.insert(t)
            all.append(CommunityChannelItem(id: "m:\(f.id)", kind: .classify(subLabel: f.subLabel, docType: f.docType, title: f.title),
                                            title: f.title, week: week, people: [], file: f))
        }
        return Dictionary(grouping: all, by: \.week).map { week, items in
            CommunityChannelWeek(week: week, items: items.sorted {
                $0.kind != $1.kind ? $0.kind < $1.kind : $0.title.localizedStandardCompare($1.title) == .orderedAscending
            })
        }.sorted { a, b in
            if a.week == 0 || b.week == 0 { return b.week == 0 && a.week != 0 }
            return a.week < b.week
        }
    }

    /// Beschriftung einer Woche aus den Wochen des Moduls ("Woche 3 · 28.10.–01.11."), sonst "Woche 3"
    static func weekLabel(_ week: Int, weeks: [JSONValue]) -> String {
        if week == 0 { return "Ohne Lehrwoche" }
        return weeks.first { $0.i("week") == week }?.s("label") ?? "Woche \(week)"
    }

    /// Dateien des Moduls (`/api/modules/{id}`) nach Titel
    static func moduleFiles(_ files: [JSONValue]) -> [String: CommunityChannelFile] {
        var out: [String: CommunityChannelFile] = [:]
        for f in files {
            guard let c = channelFile(f) else { continue }
            let key = titleKey(c.title)
            guard !key.isEmpty, out[key] == nil else { continue }
            out[key] = c
        }
        return out
    }

    static func channelFile(_ f: JSONValue) -> CommunityChannelFile? {
        guard let id = f.s("id") else { return nil }
        let title = f.s("ai_title") ?? f.s("title") ?? f.s("name") ?? ""
        let name = (f.s("name") ?? "").lowercased()
        return CommunityChannelFile(id: id, title: title, subLabel: f.s("sub_label"), docType: f.s("doc_type"),
                                    version: f.s("edited_at") ?? "\(Int(f.n("chdate") ?? 0))",
                                    isPDF: name.isEmpty || name.hasSuffix(".pdf"))
    }

    /// Blaetter je Lehrwoche aus den Wochen des Moduls (Vorlesungen, Uebungen, Skripte, Klausuren; ohne fertige
    /// Loesungen und Sonstiges)
    static func skeleton(weeks: [JSONValue]) -> [(file: CommunityChannelFile, week: Int)] {
        weeks.flatMap { w in
            ["vorlesungen", "uebungen", "skripte", "klausuren"].flatMap { g in
                w.list(g).compactMap { f in channelFile(f).map { (file: $0, week: max(0, w.i("week") ?? 0)) } }
            }
        }
    }

    /// Moduldetail (`/api/modules/{id}`) zur Community einer Modul-Community: das Modul, dessen Kurse denselben
    /// Schluessel ergeben; nil, wenn es lokal keins gibt
    static func module(for key: String, university: String, api: APIClient) async -> JSONValue? {
        guard let list = try? await api.value("/api/modules") else { return nil }
        for m in list.items {
            guard let id = m.i("id"), let d = try? await api.value("/api/modules/\(id)") else { continue }
            if CommunityCourses.courseKeys(module: d, university: university).contains(key) { return d }
        }
        return nil
    }

    /// Eigene Dateien zu den Fingerabdruecken (lokale Datenbank), eingeordnet wie in der Bibliothek
    static func localFiles(fingerprints: Set<String>, host: LocalBackendHost) async -> [String: CommunityChannelFile] {
        let prints = Array(fingerprints.filter { !$0.isEmpty }.prefix(400))
        guard !prints.isEmpty, let backend = try? await host.backend() else { return [:] }
        let marks = Array(repeating: "?", count: prints.count).joined(separator: ",")
        let rows = (try? await backend.context.database.withConnection { c in
            try c.rows("""
                SELECT f.id AS id, f.name AS name, f.studip_folder AS folder, f.chdate AS chdate, f.content_sha256 AS sha,
                       a.doc_type AS ai, a.title AS ai_title
                FROM files f LEFT JOIN analysis a ON a.file_id = f.id
                WHERE f.deleted_at IS NULL AND f.local_path IS NOT NULL AND f.content_sha256 IN (\(marks))
                """, prints.map { .text($0) })
        }) ?? []
        var out: [String: CommunityChannelFile] = [:]
        for r in rows {
            guard let id = r["id"]?.string, let sha = r["sha"]?.string, out[sha] == nil else { continue }
            let name = r["name"]?.string ?? ""
            let type = StudyClassify.effectiveType(name: name, folder: r["folder"]?.string, aiType: r["ai"]?.string)
            out[sha] = CommunityChannelFile(id: id, title: r["ai_title"]?.string ?? name, subLabel: type.label, docType: type.type,
                                            version: "\(r["chdate"]?.int ?? 0)", isPDF: name.lowercased().hasSuffix(".pdf"))
        }
        return out
    }
}

// MARK: - Kanal: Wochen mit Karten

/// Darstellung des Kanals: Wochen mit Kartenreihen, Liste (Seite der Community, Reiter "Dokumente") oder nur die
/// neuesten geteilten Blaetter als eine Reihe (Reiter "Diskussion")
enum CommunityChannelLayout: Hashable { case weeks, list, latest }

struct CommunityChannelView: View {
    let service: CommunityService
    @Binding var solutions: [CommunitySolutionSummary]
    /// Dateien und Wochen des Moduls (Moduldetail); im Kanal einer Community leer
    var files: [JSONValue] = []
    var weeks: [JSONValue] = []
    var layout: CommunityChannelLayout = .weeks
    var sort: CommunityDocsSort = .relevance
    /// Farbe der Community (Fachfarbe): Wochenmarken
    var tint: Color = UF.accent
    /// Person gewaehlt: die Seite oeffnet ihre Notizen als ganze Seite (ohne: im Blatt "Wer hat etwas geteilt")
    var onRead: ((CommunityChannelItem, Int) -> Void)?
    @State private var local: [String: CommunityChannelFile] = [:]
    @State private var open: CommunityChannelItem?
    @State private var notice: String?

    /// so viele Blaetter in der Reihe "Neueste geteilte Notizen"
    static let latestLimit = 8

    var body: some View {
        let byTitle = CommunityChannel.moduleFiles(files)
        let sections = CommunityChannel.build(solutions, file: { s in local[s.fingerprint] ?? byTitle[CommunityChannel.titleKey(s.title)] },
                                              skeleton: layout == .weeks ? CommunityChannel.skeleton(weeks: weeks) : [])
        VStack(alignment: .leading, spacing: 28) {
            if let notice { CommunityNotice(text: notice, tone: .ok) }
            switch layout {
            case .weeks:
                ForEach(Array(sections.enumerated()), id: \.element.id) { i, w in
                    weekSection(w).ufAppear("community-channel", index: i)
                }
            case .list:
                listSection(CommunityChannel.rows(sections, sort: sort))
            case .latest:
                latestSection(Array(CommunityChannel.rows(sections, sort: .newest).prefix(Self.latestLimit)))
            }
        }
        .accessibilityIdentifier("community.channel")
        .task(id: Set(solutions.map(\.fingerprint))) {
            guard let host = ActiveContainer.current?.host else { return }
            local = await CommunityChannel.localFiles(fingerprints: Set(solutions.map(\.fingerprint)), host: host)
        }
        .sheet(item: $open) { item in
            CommunityContributorsSheet(item: item, weekLabel: CommunityChannel.weekLabel(item.week, weeks: weeks), service: service,
                                       removed: { text, matches in
                                           open = nil
                                           solutions.removeAll(where: matches)
                                           notice = text
                                       },
                                       close: { open = nil },
                                       onRead: onRead.map { read in { i in open = nil; read(item, i) } })
        }
    }

    private func weekSection(_ w: CommunityChannelWeek) -> some View {
        let shared = w.items.filter { !$0.people.isEmpty }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                weekMark(w.week)
                VStack(alignment: .leading, spacing: 1) {
                    Text(CommunityChannel.weekLabel(w.week, weeks: weeks)).ufFont(17.6, 650, em: -0.01).foregroundStyle(UF.text)
                        .accessibilityAddTraits(.isHeader)
                    Text(Self.weekDetail(sheets: w.items.count, shared: shared)).ufFont(12.8).foregroundStyle(UF.muted)
                }
                Spacer(minLength: 8)
            }
            cardRow(w.items)
        }
        .accessibilityIdentifier("community.week.\(w.week)")
    }

    /// "3 Blätter · 2 mit Notizen"
    static func weekDetail(sheets: Int, shared: Int) -> String {
        let s = sheets == 1 ? "1 Blatt" : "\(sheets) Blätter"
        return shared == 0 || shared == sheets ? s : "\(s) · \(shared) mit Notizen"
    }

    /// Wochenmarke in der Fachfarbe: Zahl der Lehrwoche (ohne Woche: Symbol)
    private func weekMark(_ week: Int) -> some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous).fill(CommunityTint.wash(tint, 0.16))
            .frame(width: 40, height: 40)
            .overlay {
                if week > 0 { Text("\(week)").font(.uf(17, 700)).foregroundStyle(CommunityTint.ink(tint)) }
                else { UFIcon("layers", size: 18).foregroundStyle(CommunityTint.ink(tint)) }
            }
            .accessibilityHidden(true)
    }

    private func cardRow(_ items: [CommunityChannelItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(items) { item in
                    CommunityChannelCard(item: item, discussion: service.supportsDiscussion) { open = item }
                }
            }
            .padding(.vertical, 4)
        }
        .scrollClipDisabled()
    }

    @ViewBuilder private func latestSection(_ items: [CommunityChannelItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    UFIcon("sparkles", size: 17).foregroundStyle(CommunityPalette.butter.fg)
                    Text("Neueste geteilte Notizen").ufFont(17.6, 650, em: -0.01).foregroundStyle(UF.text)
                        .accessibilityAddTraits(.isHeader)
                }
                cardRow(items)
            }
        }
    }

    private func listSection(_ rows: [CommunityChannelItem]) -> some View {
        UFCard(padded: false) {
            VStack(spacing: 0) {
                ForEach(rows) { item in
                    CommunityDocumentRow(item: item, discussion: service.supportsDiscussion) { open = item }
                        .ufBorderBottom(item.id != rows.last?.id)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 2)
        }
    }
}

/// Zeile der Liste: Vorschau, Titel, von wem und wann, Art, Likes und Kommentare
struct CommunityDocumentRow: View {
    let item: CommunityChannelItem
    let discussion: Bool
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var thumbWidth: CGFloat = 76

    private var meta: String { "\(item.byline) · \(ForeignSolutionLayer.date(item.latest))" }

    private var label: String {
        var parts = ["\(item.kind.title): \(item.title)", meta]
        if discussion { parts += [CommunitySpaceTexts.likes(item.likes), CommunitySpaceTexts.comments(item.commentCount)] }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                CommunityChannelThumb(file: item.file, kind: item.kind, width: thumbWidth, height: (thumbWidth * 0.72).rounded(), badge: false)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).ufFont(14.5, 600).foregroundStyle(UF.text).lineLimit(2).multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        CommunityAvatarStack(names: item.people.map(CommunityContributorsSheet.name), size: 18)
                        Text(meta).ufFont(12.8).foregroundStyle(UF.muted).lineLimit(1)
                    }
                    HStack(spacing: 10) {
                        CommunityKindTag(kind: item.kind)
                        if discussion {
                            HStack(spacing: 4) { UFIcon("star", size: 12); Text("\(item.likes)") }
                            HStack(spacing: 4) { UFIcon("note", size: 12); Text("\(item.commentCount)") }
                        }
                    }
                    .ufFont(12.48, 500).foregroundStyle(UF.text2)
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                UFIcon("chevron-right", size: 16).foregroundStyle(UF.muted)
            }
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(CommunityRowPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityHint("Zeigt, wer Notizen dazu geteilt hat")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
        .accessibilityIdentifier("community.row.\(item.id)")
    }
}

/// Zeile einer Liste: beim Druecken eine Tonstufe dunkler (keine Lageaenderung)
struct CommunityRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: UF.rSm).fill(configuration.isPressed ? UF.surface2 : Color.clear).padding(.horizontal, -8))
    }
}

/// Karte eines Blatts: Vorschau mit farbigem Etikett der Art, Titel (zwei Zeilen reserviert, damit eine Reihe fluchtet),
/// darunter die Kreise der Personen und wie viele. Ohne geteilte Notizen: gestrichelter Rand, gedaempft
struct CommunityChannelCard: View {
    let item: CommunityChannelItem
    let discussion: Bool
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 196
    /// zwei Zeilen Titel (14,5 pt, Zeilenhoehe 1,5): Karten einer Reihe fluchten
    @ScaledMetric(relativeTo: .body) private var titleHeight: CGFloat = 44

    private var empty: Bool { item.people.isEmpty }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                CommunityChannelThumb(file: item.file, kind: item.kind, width: width - 16, height: ((width - 16) * 0.68).rounded(), radius: 10)
                    .opacity(empty ? 0.75 : 1)
                    .padding(8)
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title).ufFont(14.5, 620).foregroundStyle(UF.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: titleHeight, alignment: .topLeading)
                    // sichtbar kurz: Kreise, "n Personen", Kommentare als Symbol mit Zahl (VoiceOver liest den ganzen Satz)
                    HStack(spacing: 7) {
                        if empty {
                            UFIcon("plus", size: 13).foregroundStyle(UF.muted)
                                .frame(width: 20, height: 20)
                                .overlay(Circle().strokeBorder(UF.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [2.5, 2.5])))
                            Text(item.detail(discussion: false)).ufFont(12.8, 550).foregroundStyle(UF.muted).lineLimit(1)
                        } else {
                            CommunityAvatarStack(names: item.people.map(CommunityContributorsSheet.name), size: 22, limit: 2)
                            Text(item.detail(discussion: false)).ufFont(12.8, 550).foregroundStyle(UF.text2).lineLimit(1)
                            Spacer(minLength: 4)
                            if discussion && item.commentCount > 0 {
                                HStack(spacing: 3) {
                                    UFIcon("note", size: 12)
                                    Text("\(item.commentCount)")
                                }
                                .ufFont(12.48, 600).foregroundStyle(UF.text2)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 12)
            }
            .frame(width: width, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: UF.rLg, style: .continuous).fill(UF.surface))
            .overlay {
                RoundedRectangle(cornerRadius: UF.rLg, style: .continuous)
                    .strokeBorder(empty ? UF.lineStrong : UF.line, style: StrokeStyle(lineWidth: 1, dash: empty ? [5, 4] : []))
            }
            .contentShape(RoundedRectangle(cornerRadius: UF.rLg, style: .continuous))
            .hoverEffect(.lift)
        }
        .buttonStyle(UFPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.kind.title): \(item.title), \(item.detail(discussion: discussion))")
        .accessibilityHint("Zeigt, wer Notizen dazu geteilt hat")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
        .accessibilityIdentifier("community.card.\(item.id)")
    }
}

/// Erste Seite der eigenen PDF (Vorschau der Bibliothek, `UFThumbnails`: abseits des Hauptthreads, zwischengespeichert)
/// oder eine weiche Flaeche in der Farbe der Art mit angedeuteten Zeilen und ihrem Symbol; oben links das Etikett
struct CommunityChannelThumb: View {
    let file: CommunityChannelFile?
    let kind: CommunityChannelKind
    let width: CGFloat
    let height: CGFloat
    /// Etikett der Art oben links (in der Liste steht es neben dem Titel)
    var badge = true
    var radius: CGFloat = UF.r
    @EnvironmentObject private var session: Session
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: width, height: height, alignment: .top).clipped()
            } else {
                // Platzhalter: kleines Blatt mit Zeilen in der Farbe der Art, schraeg gelegt, darauf das Symbol
                ZStack {
                    kind.pair.bg
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(UF.surface.opacity(0.85))
                        .frame(width: min(width * 0.46, 92), height: min(height * 0.78, 110))
                        .overlay(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach([0.9, 0.7, 0.82, 0.5], id: \.self) { f in
                                    Capsule().fill(kind.pair.fg.opacity(0.22)).frame(width: min(width * 0.46, 92) * 0.72 * f, height: 3.5)
                                }
                            }
                            .padding(.top, 12).padding(.leading, 9)
                        }
                        .rotationEffect(.degrees(-6))
                        .offset(x: width * 0.12, y: height * 0.1)
                    UFIcon(kind.icon, size: 22).foregroundStyle(kind.pair.fg)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(UF.surface))
                        .offset(x: -width * 0.14, y: height * 0.12)
                }
                .frame(width: width, height: height)
            }
            if badge { CommunityKindTag(kind: kind, floating: true).padding(8) }
        }
        .frame(width: width, height: height)
        .background(UF.surface2)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(image == nil ? Color.clear : UF.line, lineWidth: 1))
        .accessibilityHidden(true)
        .task(id: file?.id) {
            guard let file, file.isPDF, let api = session.api else { return }
            image = await UFThumbnails.shared.image(fileID: file.id, version: file.version, image: false, api: api)
        }
    }
}

// MARK: - Wer hat etwas geteilt

struct CommunityContributorsSheet: View {
    let item: CommunityChannelItem
    let weekLabel: String
    let service: CommunityService
    /// nach Blockieren oder Zurueckziehen: Hinweis und welche Loesungen aus dem Kanal verschwinden
    let removed: (String, @escaping (CommunitySolutionSummary) -> Bool) -> Void
    let close: () -> Void
    /// Person gewaehlt: Notizen als ganze Seite (Seite der Community); ohne: Leser im Blatt
    var onRead: ((Int) -> Void)?
    @EnvironmentObject private var router: UFRouter
    @State private var reading: Int?
    @Environment(\.ufCompact) private var shellCompact
    @Environment(\.ufLearnCompact) private var learnCompact

    /// schmal (iPhone): kleinere Vorschau, Rand 16 pt
    private var compact: Bool { UFCompactLearn.inSheet(shell: shellCompact, inherited: learnCompact) }

    var body: some View {
        NavigationStack {
            UFContent(maxWidth: 760, insets: EdgeInsets(top: 16, leading: compact ? 16 : 20, bottom: 32, trailing: compact ? 16 : 20)) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: compact ? 12 : 16) {
                        CommunityChannelThumb(file: item.file, kind: item.kind, width: compact ? 112 : 156, height: compact ? 76 : 106)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).ufFont(17.6, 650, em: -0.01).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                            Text("\(item.kind.title) · \(weekLabel)").ufFont(13.12).foregroundStyle(UF.muted)
                            if let id = item.file?.id {
                                UFButton("In meiner PDF öffnen", icon: "file-text", size: .small) {
                                    close()
                                    router.go(.doc(id))
                                }
                                .padding(.top, 6)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if item.people.isEmpty {
                        UFCard {
                            CommunityEmptyState(icon: item.kind.icon, companions: ["pencil", "users"], tint: item.kind.pair.solid,
                                                title: "Sei die erste Person",
                                                text: "Noch niemand hat Notizen zu diesem Blatt geteilt. Öffne die PDF und teile deine über „Teilen“ → Community.")
                        }
                    } else {
                    Text(item.people.count == 1 ? "1 Person hat Notizen geteilt" : "\(item.people.count) Personen haben Notizen geteilt")
                        .ufFont(13.6, 650).foregroundStyle(UF.text2).accessibilityAddTraits(.isHeader)
                    UFCard(padded: false) {
                        VStack(spacing: 0) {
                            ForEach(Array(item.people.enumerated()), id: \.element.solutionID) { i, s in
                                row(s, index: i).ufBorderBottom(i < item.people.count - 1)
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 4)
                    }
                    }
                }
            }
            .navigationTitle(item.kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig", action: close) } }
            .navigationDestination(item: $reading) { i in
                CommunityPeopleReader(title: item.title, people: item.people, start: i, service: service, leave: close, removed: removed)
            }
        }
        .accessibilityIdentifier("community.people")
    }

    static func name(_ s: CommunitySolutionSummary) -> String { s.displayName.isEmpty ? "Anonym" : s.displayName }

    static func detail(_ s: CommunitySolutionSummary, discussion: Bool) -> String {
        var parts = [ForeignSolutionLayer.date(s.createdAt), s.pageCount == 1 ? "1 Seite" : "\(s.pageCount) Seiten"]
        if discussion {
            parts.append(s.likes == 1 ? "1 Like" : "\(s.likes) Likes")
            parts.append(s.commentCount == 1 ? "1 Kommentar" : "\(s.commentCount) Kommentare")
        }
        return parts.joined(separator: " · ")
    }

    private func row(_ s: CommunitySolutionSummary, index: Int) -> some View {
        let name = Self.name(s), detail = Self.detail(s, discussion: service.supportsDiscussion)
        return Button { choose(index) } label: {
            HStack(spacing: 12) {
                CommunityAvatar(name: name, size: 40, own: s.isOwn)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text(name).ufFont(14.5, 550).foregroundStyle(UF.text).lineLimit(1)
                        if s.isOwn { UFBadge("Du", tone: .accent) }
                    }
                    Text(detail).ufFont(12.8).foregroundStyle(UF.muted).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                UFIcon("chevron-right", size: 16).foregroundStyle(UF.muted)
            }
            .padding(.vertical, 10).padding(.horizontal, 8)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(CommunityRowPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Notizen von \(name)\(s.isOwn ? " (du)" : ""), \(detail)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { choose(index) }
        .accessibilityIdentifier("community.person.\(s.solutionID)")
    }

    private func choose(_ index: Int) {
        if let onRead { onRead(index) } else { reading = index }
    }
}

// MARK: - Notizen einer Person, weiter zur naechsten

/// Reiter der Notizen einer Person: das Dokument (Seiten gross) oder die Diskussion (Kommentare mit Eingabe)
enum CommunityReaderTab: Hashable { case notes, discussion }

/// Knopf der schwebenden Leiste unter den Notizen. "Korrektur vorschlagen" setzt der Leser selbst
/// (`CorrectionCommunityViews.swift`), weitere Aktionen kommen ueber `CommunityPeopleReader.extraActions` dazu.
struct CommunityReaderAction: Identifiable {
    let id: String
    let title: String
    /// Symbol der Leiste (UFIcon) bzw. im Menue (SF Symbol)
    var icon: String = "more"
    var systemImage: String = "ellipsis"
    var destructive = false
    let action: () -> Void
}

struct CommunityPeopleReader: View {
    let title: String
    let people: [CommunitySolutionSummary]
    let service: CommunityService
    /// ganze Seite (Seite der Community): Seiten breiter
    var wide = false
    /// zusaetzliche Knoepfe der schwebenden Leiste je Person (Erweiterungspunkt)
    var extraActions: (CommunitySolutionSummary) -> [CommunityReaderAction] = { _ in [] }
    /// eigene Datei zu einem Fingerabdruck (Korrektur vorschlagen bzw. ansehen)
    let localFile: (String) async -> String?
    /// vor dem Wechsel ins Dokument (Blatt schliessen bzw. Leser verlassen)
    var leave: (() -> Void)?
    let removed: (String, @escaping (CommunitySolutionSummary) -> Bool) -> Void
    @ObservedObject private var entitlements: Entitlements
    @EnvironmentObject private var router: UFRouter
    /// Fingerabdruck -> eigene Datei (.some(nil): keine)
    @State private var pdfFiles: [String: String?] = [:]
    @State private var lockedFeature: UFFeature?
    @State private var hint: String?
    @State private var index: Int
    @State private var forward = true
    @State private var tab: CommunityReaderTab = .notes
    @State private var reporting: CommunitySolutionSummary?
    @State private var blocking: CommunitySolutionSummary?
    @State private var withdrawing: CommunitySolutionSummary?
    @State private var notice: String?
    @State private var error: String?
    @Environment(\.accessibilityReduceMotion) private var reduce

    init(title: String, people: [CommunitySolutionSummary], start: Int, service: CommunityService, wide: Bool = false,
         extraActions: @escaping (CommunitySolutionSummary) -> [CommunityReaderAction] = { _ in [] },
         entitlements: Entitlements? = nil, localFile: ((String) async -> String?)? = nil, leave: (() -> Void)? = nil,
         removed: @escaping (String, @escaping (CommunitySolutionSummary) -> Bool) -> Void) {
        self.title = title
        self.people = people
        self.service = service
        self.wide = wide
        self.extraActions = extraActions
        self.localFile = localFile ?? { await CorrectionLaunch.localFile(fingerprint: $0) }
        self.leave = leave
        self.removed = removed
        _entitlements = ObservedObject(wrappedValue: entitlements ?? .shared)
        _index = State(initialValue: min(max(0, start), max(0, people.count - 1)))
    }

    private var current: CommunitySolutionSummary { people[index] }

    var body: some View {
        VStack(spacing: 0) {
            personBar
            ZStack {
                CommunityPersonPane(solution: current, service: service, notice: notice, error: error, hint: hint, tab: $tab, wide: wide,
                                    actions: correctionActions(current) + extraActions(current), menu: menu(current),
                                    localFile: localFile, leave: leave)
                    .id(current.solutionID)
                    .transition(transition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            // Wischen nach links = naechste Person; nur deutlich waagerecht (senkrecht bleibt Blaettern der Seiten)
            .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { v in
                let dx = v.translation.width, dy = v.translation.height
                guard abs(dx) > 70, abs(dx) > abs(dy) * 1.5 else { return }
                step(dx < 0 ? 1 : -1)
            })
        }
        .background(UF.bg)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        // eigene PDF zur Loesung suchen (Korrektur nur mit derselben PDF)
        .task(id: current.solutionID) { await lookUpPDF(current) }
        .sheet(item: $lockedFeature) { f in UFLockedSheet(f) { lockedFeature = nil } }
        .ufModal(isPresented: Binding(get: { reporting != nil }, set: { if !$0 { reporting = nil } })) {
            if let s = reporting {
                CommunityReportDialog(solution: s, service: service, done: { m in reporting = nil; notice = m })
            }
        }
        .ufModal(isPresented: Binding(get: { blocking != nil }, set: { if !$0 { blocking = nil } })) {
            if let s = blocking {
                UFDialog("Nutzer blockieren", icon: "users") {
                    Text(CommunityTexts.blockNotice).ufFont(13.12).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                } foot: {
                    UFButton("Abbrechen") { blocking = nil }
                    UFButton("Blockieren", kind: .danger) { blocking = nil; block(s) }
                }
            }
        }
        .ufModal(isPresented: Binding(get: { withdrawing != nil }, set: { if !$0 { withdrawing = nil } })) {
            if let s = withdrawing {
                UFDialog("Lösung zurückziehen", icon: "trash") {
                    Text("Die Lösung verschwindet aus der Community und das Paket wird beim Dienst gelöscht. Wer sie schon geladen hat, behält sie.")
                        .ufFont(13.12).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                } foot: {
                    UFButton("Abbrechen") { withdrawing = nil }
                    UFButton("Zurückziehen", kind: .danger) { withdrawing = nil; withdraw(s) }
                }
            }
        }
    }

    // MARK: Korrektur vorschlagen

    func correctionOffer(_ s: CommunitySolutionSummary) -> CorrectionOffer {
        CorrectionOffer.resolve(s, supportsCorrections: service.supportsCorrections, access: entitlements.access(.shareSolutions),
                                localFile: s.fingerprint.isEmpty ? .some(nil) : pdfFiles[s.fingerprint])
    }

    /// Knopf "Korrektur vorschlagen" (nicht unter eigenen Notizen, nur wenn der Dienst Korrekturen kann)
    private func correctionActions(_ s: CommunitySolutionSummary) -> [CommunityReaderAction] {
        // iPhone: kein Editor, also kein Korrektur-Modus (Vorgabe 11.11.2026)
        guard UFEditorAvailability.available, correctionOffer(s) != .hidden else { return [] }
        return [CommunityReaderAction(id: "correct", title: CorrectionTexts.action, icon: "pen", systemImage: "pencil.and.outline") {
            suggestCorrection(s)
        }]
    }

    private func lookUpPDF(_ s: CommunitySolutionSummary) async {
        guard service.supportsCorrections, !s.isOwn, !s.fingerprint.isEmpty, pdfFiles[s.fingerprint] == nil else { return }
        let file = await localFile(s.fingerprint)
        pdfFiles[s.fingerprint] = .some(file)
    }

    private func suggestCorrection(_ s: CommunitySolutionSummary) {
        switch correctionOffer(s) {
        case .hidden: return
        case .locked: lockedFeature = .shareSolutions
        case .checking: Task { await lookUpPDF(s); if correctionOffer(s) != .checking { suggestCorrection(s) } }
        case .needsPDF:
            notice = nil
            hint = CorrectionTexts.needsPDF
        case .ready(let fileID):
            hint = nil
            leave?()
            CorrectionLaunch.shared.correct(solutionID: s.solutionID, fileID: fileID, router: router)
        }
    }

    /// "Mehr" in der schwebenden Leiste: eigene zurueckziehen, fremde melden oder blockieren
    private func menu(_ s: CommunitySolutionSummary) -> [CommunityReaderAction] {
        if s.isOwn {
            return [CommunityReaderAction(id: "withdraw", title: "Zurückziehen", systemImage: "trash", destructive: true) { withdrawing = s }]
        }
        return [CommunityReaderAction(id: "report", title: "Melden …", systemImage: "flag") { reporting = s },
                CommunityReaderAction(id: "block", title: "Nutzer blockieren …", systemImage: "hand.raised", destructive: true) { blocking = s }]
    }

    private var personBar: some View {
        HStack(spacing: 12) {
            arrow("chevron-left", label: "Vorherige Person", id: "community.reader.previous", enabled: index > 0) { step(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [])          // Mac und Tastatur: statt Wischen
            HStack(spacing: 10) {
                CommunityAvatar(name: CommunityContributorsSheet.name(current), size: 36, own: current.isOwn)
                    .id(current.solutionID)
                    .transition(.opacity)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text(CommunityContributorsSheet.name(current)).ufFont(15.2, 650).foregroundStyle(UF.text).lineLimit(1)
                        if current.isOwn { UFBadge("Du", tone: .accent) }
                    }
                    Text("Person \(index + 1) von \(people.count) · \(ForeignSolutionLayer.date(current.createdAt))")
                        .ufFont(12.8).foregroundStyle(UF.muted).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("community.reader.person")
            arrow("chevron-right", label: "Nächste Person", id: "community.reader.next", enabled: index < people.count - 1) { step(1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(UF.surface)
        .ufBorderBottom()
    }

    private func arrow(_ icon: String, label: String, id: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            UFIcon(icon, size: 18).foregroundStyle(enabled ? UF.text : UF.muted.opacity(0.5))
                .frame(width: 44, height: 44)
                .background(Circle().fill(enabled ? UF.surface2 : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(UFPressStyle(scale: 0.94))
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    /// Bewegung reduzieren: nur Ueberblenden statt Schieben
    private var transition: AnyTransition {
        guard UFMotion.moves, !reduce else { return .opacity }
        return .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                           removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    func step(_ delta: Int) {
        let next = index + delta
        guard people.indices.contains(next) else { return }
        forward = delta > 0
        notice = nil
        error = nil
        hint = nil
        withAnimation(UFMotion.animation(reduce: reduce)) { index = next }
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }

    private func block(_ s: CommunitySolutionSummary) {
        Task {
            do {
                try await service.block(owner: s.ownerRecordName)
                CommunityMatches.shared.invalidate()
                let owner = s.ownerRecordName
                removed("Nutzer blockiert.") { $0.ownerRecordName == owner }
            } catch { self.error = CommunityTexts.message(error) }
        }
    }

    private func withdraw(_ s: CommunitySolutionSummary) {
        Task {
            do {
                try await SolutionSharing.withdrawFromCommunity(s.solutionID, service: service)
                let id = s.solutionID
                removed("Lösung zurückgezogen.") { $0.solutionID == id }
            } catch { self.error = CommunityTexts.message(error) }
        }
    }
}

/// Notizen einer Person: Reiter "Dokument" (Seiten gross) und "Diskussion (N)" (Kommentare mit Eingabe), unten eine
/// schwebende Leiste (Kommentar, Gefaellt mir, weitere Aktionen, Mehr)
struct CommunityPersonPane: View {
    let solution: CommunitySolutionSummary
    let service: CommunityService
    var notice: String?
    var error: String?
    /// Hinweis ohne Fehler (z. B. "Lade die PDF, um zu korrigieren.")
    var hint: String?
    @Binding var tab: CommunityReaderTab
    var wide = false
    var actions: [CommunityReaderAction] = []
    var menu: [CommunityReaderAction] = []
    var localFile: (String) async -> String? = { await CorrectionLaunch.localFile(fingerprint: $0) }
    var leave: (() -> Void)?
    @EnvironmentObject private var router: UFRouter
    /// Korrekturvorschlaege zu dieser Loesung (fuer alle Mitglieder, eigener Eintrag unter der Diskussion)
    @State private var corrections: [CommunityCorrection] = []
    @State private var paneNotice: String?
    @State private var paneHint: String?
    @State private var content: SolutionContent?
    @State private var images: [String: UIImage] = [:]
    @State private var failure: String?
    @State private var comments: [CommunityComment] = []
    @State private var liked = false
    @State private var likes = 0
    @State private var draft = ""
    @State private var replyTo: CommunityComment?
    @State private var editing: CommunityComment?
    @State private var spot: (page: String, anchor: CommunityComment.Anchor)?
    @State private var busy = false
    /// eigene Kommentare, die schon im Verlauf stehen und noch zum Dienst gehen (Kennung -> Zustand), 08.11.2026
    @State private var pending: [String: CommunitySendState] = [:]
    /// was fuer einen noch nicht gesendeten Kommentar an den Dienst geht ("Erneut senden")
    @State private var pendingSends: [String: PendingComment] = [:]
    /// fremder Kommentar, der nach der Rueckfrage ausgeblendet wird (P42-05)
    @State private var hiding: CommunityComment?

    /// Auftrag eines Kommentars: neu (mit Antwort-auf, Seite, Stelle) oder Aenderung eines bestehenden
    struct PendingComment {
        var text: String
        var parentID: String?
        var pageKey: String?
        var anchor: CommunityComment.Anchor?
        /// Kennung des Kommentars beim Dienst, wenn es eine Aenderung ist
        var editID: String?
        /// der Kommentar vor der Aenderung (zum Zuruecknehmen bei "Verwerfen")
        var previous: CommunityComment?
    }
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// kompakt laut Huelle (auch iPhone quer, `UFLayout.isCompact`)
    @Environment(\.ufCompact) private var shellCompact
    @Environment(\.ufLearnCompact) private var learnCompact

    private var discussion: Bool { service.supportsDiscussion }
    private var showsNotes: Bool { !discussion || tab == .notes }
    /// schmal (iPhone): Leiste nur mit Symbolen, in der Diskussion statt der Leiste das Kommentarfeld unten fest
    private var compact: Bool { UFCompactLearn.isCompact(sizeClass, shell: shellCompact, inherited: learnCompact) }
    /// schmal in der Diskussion: Feld unten statt schwebender Leiste
    private var composerPinned: Bool { compact && discussion && !showsNotes }

    var body: some View {
        VStack(spacing: 0) {
            if discussion {
                CommunityTabBar(options: [(CommunityReaderTab.notes, "Dokument", "community.reader.tab.notes"),
                                          (.discussion, CorrectionTexts.discussionTab(comments: comments.count, corrections: corrections.count),
                                           "community.reader.tab.discussion")],
                                selection: $tab)
                    .padding(.horizontal, 16)
                    .background(UF.surface)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let text = paneNotice ?? notice { CommunityNotice(text: text, tone: .ok) }
                    if let text = paneHint ?? hint { CommunityNotice(text: text, tone: .info) }
                    if let message = error ?? failure { CommunityNotice(text: message) }
                    if showsNotes {
                        if let content {
                            ForEach(Array(content.pages.enumerated()), id: \.element.key) { i, page in
                                CommunityReaderPage(page: page, images: images, marks: marks(page), tapped: discussion ? { anchor in
                                    resetComposer()
                                    spot = (page.key, anchor)
                                    tab = .discussion
                                } : nil, title: SolutionBuilder.pageTitle(content.pages, at: i))
                            }
                        } else if failure == nil { CommunityLoading(text: "Notizen werden geladen …") }
                    } else {
                        if !corrections.isEmpty { correctionsSection }
                        commentsCard
                    }
                }
                .padding(EdgeInsets(top: 16, leading: compact ? 16 : 20, bottom: composerPinned ? 16 : 96, trailing: compact ? 16 : 20))      // Platz fuer die schwebende Leiste
                .frame(maxWidth: wide ? 1100 : 860, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(compact ? .interactively : .automatic)          // iPad wie bisher
            .overlay(alignment: .bottom) { if !composerPinned { floatingBar } }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if composerPinned {
                    UFCompactBottomBar { commentComposer }.accessibilityIdentifier("community.reader.bottom")
                }
            }
        }
        .alert(CommunityTexts.hideCommentTitle, isPresented: Binding(get: { hiding != nil }, set: { if !$0 { hiding = nil } }), presenting: hiding) { c in
            Button(CommunityTexts.CommentRemoval.hide.title, role: .destructive) { act { try await service.deleteComment(id: c.id) } }
            Button("Abbrechen", role: .cancel) {}
        } message: { _ in Text(CommunityTexts.hideCommentMessage) }
        .task { await load() }
    }

    // MARK: Schwebende Leiste

    private var floatingBar: some View {
        HStack(spacing: 2) {
            if discussion {
                barButton("Kommentar", icon: "note", id: "community.reader.bar.comment") {
                    resetComposer()
                    tab = .discussion
                }
                likeControl
            }
            ForEach(actions) { a in barButton(a.title, icon: a.icon, id: "community.reader.bar.\(a.id)", action: a.action) }
            if !menu.isEmpty {
                Menu {
                    ForEach(menu) { a in
                        Button(role: a.destructive ? .destructive : nil, action: a.action) { Label(a.title, systemImage: a.systemImage) }
                    }
                } label: {
                    UFIcon("more", size: 18).foregroundStyle(UF.text2).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Mehr")
                .accessibilityIdentifier("community.reader.bar.more")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(UF.surface))
        .overlay(Capsule().strokeBorder(UF.line, lineWidth: 1))
        .ufShadow(.lg)
        .padding(.bottom, 18)
    }

    private func barButton(_ title: String, icon: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                UFIcon(icon, size: 16)
                // schmal nur das Symbol (die Beschriftung bleibt fuer VoiceOver): die Leiste passt so auf 390 pt
                if !compact { Text(title).lineLimit(1) }
            }
            .ufFont(13.6, 550).foregroundStyle(UF.text)
            .padding(.horizontal, compact ? 10 : 12).frame(minWidth: 44, minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(UFPressStyle())
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }

    @ViewBuilder private var likeControl: some View {
        if solution.isOwn {
            Text(CommunitySpaceTexts.likes(likes)).ufFont(13.6).foregroundStyle(UF.muted)
                .padding(.horizontal, 12).frame(minHeight: 44)
        } else {
            Button { toggleLike() } label: {
                HStack(spacing: 6) {
                    CommunityLikeStar(liked: liked, size: 16)
                    Text(compact ? "\(likes)" : "\(liked ? "Gefällt dir" : "Gefällt mir") · \(likes)").lineLimit(1)
                }
                .ufFont(13.6, liked ? 650 : 550).foregroundStyle(liked ? CommunityPalette.butter.fg : UF.text)
                .padding(.horizontal, 14).frame(minHeight: 36)
                .background(Capsule().fill(liked ? CommunityPalette.butter.bg : Color.clear))
                .frame(minHeight: 44)
                .contentShape(Capsule())
            }
            .buttonStyle(UFPressStyle())
            .disabled(busy)
            .accessibilityLabel("\(liked ? "Gefällt dir" : "Gefällt mir") · \(likes)")
            .accessibilityIdentifier("community.reader.like")
        }
    }

    // MARK: Diskussion

    private func marks(_ page: SolutionPage) -> [CommunityReaderPage.Mark] {
        comments.enumerated().compactMap { i, c in
            guard c.pageKey == page.key, c.parentID == nil, let a = c.anchor else { return nil }
            return CommunityReaderPage.Mark(number: i + 1, anchor: a)
        }
    }

    // MARK: Korrekturvorschlaege

    private var correctionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                UFIcon("pen", size: 16).foregroundStyle(CommunityPalette.peach.fg)
                Text("\(CorrectionTexts.sectionTitle) (\(corrections.count))").ufFont(15.2, 650).foregroundStyle(UF.text)
                    .accessibilityAddTraits(.isHeader)
            }
            Text(CorrectionTexts.sectionNotice).ufFont(12.48).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            ForEach(corrections) { c in
                CorrectionEntryRow(correction: c, busy: busy, view: { viewCorrection(c) },
                                   delete: c.isMine ? { deleteCorrection(c) } : nil,
                                   report: c.isMine ? nil : { reportCorrection(c) })
            }
        }
        .accessibilityIdentifier("community.reader.corrections")
    }

    /// Korrektur im eigenen Dokument ansehen (nur Anzeige, ueber der Loesung)
    private func viewCorrection(_ c: CommunityCorrection) {
        let print = solution.fingerprint
        guard UFEditorAvailability.available else { paneHint = CorrectionTexts.onIPad; return }
        Task {
            guard !print.isEmpty, let file = await localFile(print) else {
                paneHint = CorrectionTexts.needsPDFToView
                return
            }
            paneHint = nil
            leave?()
            CorrectionLaunch.shared.show(c, fileID: file, router: router)
        }
    }

    private func deleteCorrection(_ c: CommunityCorrection) {
        actOnCorrections(done: CorrectionTexts.deleted) { try await service.deleteCorrection(id: c.id) }
    }

    private func reportCorrection(_ c: CommunityCorrection) {
        actOnCorrections(done: CorrectionTexts.reported) { try await service.reportCorrection(id: c.id, reason: .other) }
    }

    private func actOnCorrections(done: String, _ op: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await op()
                corrections = try await service.corrections(solutionID: solution.solutionID)
                paneNotice = done
                failure = nil
            } catch { failure = CommunityTexts.message(error) }
        }
    }

    private var commentsCard: some View {
        UFCard {
            Text(service.isAccountService ? CommunityTexts.commentsNotice : CommunityTexts.commentsNoticeCloud)
                .ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
            if comments.isEmpty {
                CommunityEmptyState(icon: "note", companions: ["users", "star"], text: "Noch keine Kommentare.")
            }
            ForEach(Array(comments.enumerated()), id: \.element.id) { i, c in
                commentRow(c, number: i + 1).ufBorderBottom(c.id != comments.last?.id)
            }
            if !composerPinned { commentComposer.padding(.top, 8) }
        }
    }

    /// Kommentarfeld: breit in der Karte, schmal in der Diskussion unten fest ueber der Tastatur
    @ViewBuilder private var commentComposer: some View {
        if let target = composerTitle { Text(target).ufFont(12.8, 600).foregroundStyle(UF.text2) }
        Group {
            if composerPinned {
                UFCompactComposerField(placeholder: "Kommentar schreiben …", text: $draft)
            } else {
                UFTextArea(placeholder: "Kommentar schreiben …", text: $draft, minHeight: 70)
            }
        }
        .accessibilityIdentifier("community.reader.commentField")
        HStack(spacing: 8) {
            UFButton(editing == nil ? "Senden" : "Speichern", icon: "check", kind: .primary, size: .small) { send() }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("community.reader.send")
            if composerTitle != nil { UFButton("Abbrechen", size: .small) { resetComposer() } }
        }
    }

    private var composerTitle: String? {
        if editing != nil { return "Kommentar bearbeiten" }
        if let replyTo { return "Antwort an \(replyTo.pseudonym)" }
        return spot != nil ? "Kommentar an der gewählten Stelle" : nil
    }

    private func commentRow(_ c: CommunityComment, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                CommunityAvatar(name: c.pseudonym, size: 26, own: c.isMine)
                if c.anchor != nil {
                    Text("\(number)").ufFont(11.84, 650).foregroundStyle(UF.accentText)
                        .frame(minWidth: 20, minHeight: 20).background(Circle().fill(UF.accentSoft))
                }
                Text(c.pseudonym + (c.byAuthor ? " · Autor" : "") + (c.edited ? " · bearbeitet" : "")).ufFont(12.8, 650).foregroundStyle(UF.text)
                Text(ForeignSolutionLayer.date(c.createdAt)).ufFont(11.84).foregroundStyle(UF.muted)
            }
            Text(c.deleted ? CommunityTexts.removedComment(accountService: service.isAccountService) : c.text).ufFont(14.5, lh: 1.55).foregroundStyle(c.deleted ? UF.muted : UF.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 34)
            if let state = pending[c.id] {
                CommunitySendStateView(state: state, id: "community.reader.comment.\(c.id)", retry: { resend(c.id) }, discard: { discard(c.id) })
                    .padding(.leading, 34)
            } else if !c.deleted {
                HStack(spacing: 4) {
                    UFButton("Antworten", kind: .ghost, size: .small) { resetComposer(); replyTo = c }
                    if c.isMine {
                        UFButton("Bearbeiten", kind: .ghost, size: .small) { resetComposer(); editing = c; draft = c.text }
                    } else {
                        UFButton("Melden", kind: .ghost, size: .small) { act { try await service.reportComment(id: c.id, reason: .other) } }
                    }
                    if let removal = CommunityTexts.commentRemoval(isMine: c.isMine, ownSolution: solution.isOwn, accountService: service.isAccountService) {
                        UFButton(removal.title, kind: .danger, size: .small) {
                            if removal == .hide { hiding = c } else { act { try await service.deleteComment(id: c.id) } }
                        }
                        .accessibilityHint(removal == .hide ? CommunityTexts.hideCommentHint : "")
                    }
                }
                .padding(.leading, 26)
            }
        }
        .padding(.vertical, 9.6)
        .padding(.leading, c.parentID == nil ? 0 : 34)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resetComposer() {
        draft = ""
        replyTo = nil
        editing = nil
        spot = nil
    }

    private func load() async {
        likes = solution.likes
        liked = solution.likedByMe
        if discussion { comments = (try? await service.comments(solutionID: solution.solutionID)) ?? [] }
        if service.supportsCorrections { corrections = (try? await service.corrections(solutionID: solution.solutionID)) ?? [] }
        do {
            let c = try await SolutionSharing.loadCommunity(solution.solutionID, service: service)
            images = c.images.compactMapValues { UIImage(data: $0.data) }
            content = c
        } catch { failure = CommunityTexts.message(error) }
    }

    /// Loeschen, Melden, Like: danach den Verlauf neu holen (eigene, noch nicht gesendete Kommentare bleiben stehen)
    private func act(_ op: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await op()
                let fresh = try await service.comments(solutionID: solution.solutionID)
                comments = CommunityPendingSend.merge(fresh: fresh, pending: comments.filter { pending[$0.id] != nil })
                failure = nil
            } catch { failure = CommunityTexts.message(error) }
        }
    }

    /// Senden oder Speichern: der Kommentar steht sofort im Verlauf, der Save laeuft im Hintergrund und ersetzt nur
    /// diesen Eintrag (Befund iPad 08.11.2026: vorher Sekunden bis zum Erscheinen)
    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let name = SolutionDisplayName.load()
        if let edit = editing, pending[edit.id] == nil {
            var changed = edit
            changed.text = text
            changed.edited = true
            CommunityPendingSend.replace(&comments, localID: edit.id, with: changed)
            pendingSends[edit.id] = PendingComment(text: text, editID: edit.id, previous: edit)
            resetComposer()
            perform(edit.id)
            return
        }
        // Antwort auf eine Antwort haengt am ersten Kommentar, ohne eigene Stelle die des Kommentars (wie der Dienst)
        let parent = replyTo.map { $0.parentID ?? $0.id }
        let pageKey = spot?.page ?? replyTo?.pageKey, anchor = spot?.anchor ?? replyTo?.anchor
        let local = CommunityPendingSend.comment(text: text, parentID: parent, pageKey: pageKey, anchor: anchor, pseudonym: name)
        CommunityPendingSend.insert(local, into: &comments)
        pendingSends[local.id] = PendingComment(text: text, parentID: parent, pageKey: pageKey, anchor: anchor)
        resetComposer()
        perform(local.id)
    }

    private func perform(_ id: String) {
        guard let job = pendingSends[id] else { return }
        pending[id] = .sending
        Task {
            do {
                let saved: CommunityComment
                if let edit = job.editID {
                    saved = try await service.editComment(id: edit, text: job.text)
                } else {
                    saved = try await service.addComment(solutionID: solution.solutionID, text: job.text, parentID: job.parentID,
                                                         pageKey: job.pageKey, anchor: job.anchor)
                }
                CommunityPendingSend.replace(&comments, localID: id, with: saved)
                pending[id] = nil
                pendingSends[id] = nil
                failure = nil
            } catch {
                pending[id] = .failed(CommunityTexts.message(error))
            }
        }
    }

    private func resend(_ id: String) {
        guard case .failed = pending[id] else { return }
        perform(id)
    }

    /// Verwerfen: neuer Kommentar weg, eine Aenderung zurueck auf den Stand davor
    private func discard(_ id: String) {
        if let previous = pendingSends[id]?.previous {
            CommunityPendingSend.replace(&comments, localID: id, with: previous)
        } else {
            comments.removeAll { $0.id == id }
        }
        pending[id] = nil
        pendingSends[id] = nil
    }

    private func toggleLike() {
        let next = !liked
        act {
            likes = try await service.setLiked(solutionID: solution.solutionID, next)
            liked = next
        }
    }
}

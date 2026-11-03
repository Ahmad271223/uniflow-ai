import SwiftUI
import UniFlowCore

// Kanal einer Community nach dem Vorbild Studydrive, aber nach Lehrwoche geordnet (Wunsch des Inhabers 03.11.2026):
// je Woche eine waagerechte Reihe Karten (Vorlesung, Hoersaaluebung, Uebung, Gruppenuebung, Tutorium, Klausur, eigene
// Notizen) mit der ersten Seite als Vorschau. Tippen auf eine Karte zeigt, wer dazu Notizen geteilt hat; Tippen auf eine
// Person zeigt ihre Notizen, mit Pfeilen oder Wischen geht es zur naechsten bzw. vorherigen Person. Likes und
// Kommentare stehen unter den Notizen (nur wenn der Dienst sie kann: `supportsDiscussion`).

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
        case .hoersaaluebung, .gruppenuebung: return "users"
        case .uebung: return "pencil"
        case .tutorium: return "graduation"
        case .klausur: return "flag"
        case .notizen: return "note"
        }
    }

    /// Farbe des Etiketts: Textfarben der Toene (kontrastsicher in hell und dunkel)
    var tint: Color {
        switch self {
        case .vorlesung: return UF.infoText
        case .hoersaaluebung: return UF.accentText
        case .uebung, .gruppenuebung: return UF.okText
        case .tutorium: return UF.warnText
        case .klausur: return UF.badText
        case .notizen: return UF.text2
        }
    }

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

struct CommunityChannelView: View {
    let service: CommunityService
    @Binding var solutions: [CommunitySolutionSummary]
    /// Dateien und Wochen des Moduls (Moduldetail); im Kanal einer Community leer
    var files: [JSONValue] = []
    var weeks: [JSONValue] = []
    @State private var local: [String: CommunityChannelFile] = [:]
    @State private var open: CommunityChannelItem?
    @State private var notice: String?

    var body: some View {
        let byTitle = CommunityChannel.moduleFiles(files)
        let sections = CommunityChannel.build(solutions, file: { s in local[s.fingerprint] ?? byTitle[CommunityChannel.titleKey(s.title)] },
                                              skeleton: CommunityChannel.skeleton(weeks: weeks))
        VStack(alignment: .leading, spacing: 28) {
            if let notice { CommunityNotice(text: notice, tone: .ok) }
            ForEach(Array(sections.enumerated()), id: \.element.id) { i, w in
                weekSection(w).ufAppear("community-channel", index: i)
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
                                       close: { open = nil })
        }
    }

    private func weekSection(_ w: CommunityChannelWeek) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(CommunityChannel.weekLabel(w.week, weeks: weeks)).ufFont(17.6, 650, em: -0.01).foregroundStyle(UF.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Text(w.items.count == 1 ? "1 Blatt" : "\(w.items.count) Blätter").ufFont(12.8).foregroundStyle(UF.muted)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(w.items) { item in
                        CommunityChannelCard(item: item, discussion: service.supportsDiscussion) { open = item }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
        }
        .accessibilityIdentifier("community.week.\(w.week)")
    }
}

/// Karte wie bei Studydrive: Vorschau mit Etikett der Art, darunter Titel und wer etwas geteilt hat
struct CommunityChannelCard: View {
    let item: CommunityChannelItem
    let discussion: Bool
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 184

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                CommunityChannelThumb(file: item.file, kind: item.kind, width: width, height: (width * 0.72).rounded())
                Text(item.title).ufFont(14.5, 600).foregroundStyle(UF.text).lineLimit(2)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Text(item.detail(discussion: discussion)).ufFont(12.8, 500).foregroundStyle(UF.accentText).lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
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
/// oder eine ruhige Flaeche mit dem Symbol der Art; oben links das Etikett
struct CommunityChannelThumb: View {
    let file: CommunityChannelFile?
    let kind: CommunityChannelKind
    let width: CGFloat
    let height: CGFloat
    @EnvironmentObject private var session: Session
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: width, height: height, alignment: .top).clipped()
            } else {
                // Platzhalter: angedeutete Textzeilen und das Symbol der Art
                VStack(alignment: .leading, spacing: 7) {
                    Spacer(minLength: 0)
                    ForEach([0.78, 0.92, 0.6], id: \.self) { f in
                        Capsule().fill(UF.line).frame(width: width * 0.7 * f, height: 5)
                    }
                }
                .padding(14)
                .frame(width: width, height: height, alignment: .bottomLeading)
                .overlay { UFIcon(kind.icon, size: 26).foregroundStyle(UF.muted.opacity(0.7)) }
            }
            UFBadge(kind.title, tint: kind.tint).padding(8)
        }
        .frame(width: width, height: height)
        .background(UF.surface2)
        .clipShape(RoundedRectangle(cornerRadius: UF.r))
        .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(UF.line, lineWidth: 1))
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
    @EnvironmentObject private var router: UFRouter
    @State private var reading: Int?

    var body: some View {
        NavigationStack {
            UFContent(maxWidth: 760, insets: EdgeInsets(top: 16, leading: 20, bottom: 32, trailing: 20)) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 16) {
                        CommunityChannelThumb(file: item.file, kind: item.kind, width: 120, height: 86)
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
                            UFEmpty(icon: "users", text: "Noch niemand hat Notizen zu diesem Blatt geteilt. Öffne die PDF und teile deine über „Teilen“ → Community.", small: true)
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
                CommunityPeopleReader(title: item.title, people: item.people, start: i, service: service, removed: removed)
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
        return Button { reading = index } label: {
            HStack(spacing: 12) {
                Text(ShellState.initials(of: name).isEmpty ? "?" : ShellState.initials(of: name))
                    .ufFont(13.12, 600).foregroundStyle(UF.accentText)
                    .frame(width: 36, height: 36).background(Circle().fill(UF.accentSoft))
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
            .padding(.vertical, 9.6).padding(.horizontal, 8)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Notizen von \(name)\(s.isOwn ? " (du)" : ""), \(detail)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { reading = index }
        .accessibilityIdentifier("community.person.\(s.solutionID)")
    }
}

// MARK: - Notizen einer Person, weiter zur naechsten

struct CommunityPeopleReader: View {
    let title: String
    let people: [CommunitySolutionSummary]
    let service: CommunityService
    let removed: (String, @escaping (CommunitySolutionSummary) -> Bool) -> Void
    @State private var index: Int
    @State private var forward = true
    @State private var reporting: CommunitySolutionSummary?
    @State private var blocking: CommunitySolutionSummary?
    @State private var withdrawing: CommunitySolutionSummary?
    @State private var notice: String?
    @State private var error: String?
    @Environment(\.accessibilityReduceMotion) private var reduce

    init(title: String, people: [CommunitySolutionSummary], start: Int, service: CommunityService,
         removed: @escaping (String, @escaping (CommunitySolutionSummary) -> Bool) -> Void) {
        self.title = title
        self.people = people
        self.service = service
        self.removed = removed
        _index = State(initialValue: min(max(0, start), max(0, people.count - 1)))
    }

    private var current: CommunitySolutionSummary { people[index] }

    var body: some View {
        VStack(spacing: 0) {
            personBar
            ZStack {
                CommunityPersonPane(solution: current, service: service, notice: notice, error: error)
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if current.isOwn {
                        Button(role: .destructive) { withdrawing = current } label: { Label("Zurückziehen", systemImage: "trash") }
                    } else {
                        Button { reporting = current } label: { Label("Melden …", systemImage: "flag") }
                        Button(role: .destructive) { blocking = current } label: { Label("Nutzer blockieren …", systemImage: "hand.raised") }
                    }
                } label: {
                    UFIcon("more", size: 18).foregroundStyle(UF.text2).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Mehr")
            }
        }
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

    private var personBar: some View {
        HStack(spacing: 12) {
            arrow("chevron-left", label: "Vorherige Person", id: "community.reader.previous", enabled: index > 0) { step(-1) }
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text(CommunityContributorsSheet.name(current)).ufFont(15.2, 650).foregroundStyle(UF.text).lineLimit(1)
                    if current.isOwn { UFBadge("Du", tone: .accent) }
                }
                Text("Person \(index + 1) von \(people.count) · \(ForeignSolutionLayer.date(current.createdAt))")
                    .ufFont(12.8).foregroundStyle(UF.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("community.reader.person")
            arrow("chevron-right", label: "Nächste Person", id: "community.reader.next", enabled: index < people.count - 1) { step(1) }
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

/// Notizen einer Person (Seiten wie im Leser), darunter Gefaellt mir und Kommentare mit Eingabe
struct CommunityPersonPane: View {
    let solution: CommunitySolutionSummary
    let service: CommunityService
    var notice: String?
    var error: String?
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

    private var discussion: Bool { service.supportsDiscussion }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let notice { CommunityNotice(text: notice, tone: .ok) }
                    if let message = error ?? failure { CommunityNotice(text: message) }
                    if discussion {
                        HStack(spacing: 8) {
                            likeControl
                            UFButton(comments.count == 1 ? "1 Kommentar" : "\(comments.count) Kommentare", icon: "note", kind: .ghost, size: .small) {
                                withAnimation(UFMotion.animation(reduce: UIAccessibility.isReduceMotionEnabled)) { proxy.scrollTo("comments", anchor: .top) }
                            }
                            .accessibilityIdentifier("community.reader.comments")
                        }
                    }
                    if let content {
                        ForEach(content.pages, id: \.key) { page in
                            CommunityReaderPage(page: page, images: images, marks: marks(page), tapped: discussion ? { anchor in
                                spot = (page.key, anchor)
                                replyTo = nil
                                editing = nil
                            } : nil)
                        }
                    } else if failure == nil { CommunityLoading(text: "Notizen werden geladen …") }
                    if discussion { commentsCard.id("comments") }
                }
                .padding(EdgeInsets(top: 16, leading: 20, bottom: 32, trailing: 20))
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .task { await load() }
    }

    @ViewBuilder private var likeControl: some View {
        if solution.isOwn {
            Text(likes == 1 ? "1 Like" : "\(likes) Likes").ufFont(13.12).foregroundStyle(UF.muted)
                .frame(minHeight: 44)
        } else {
            UFButton("\(liked ? "Gefällt dir" : "Gefällt mir") · \(likes)", icon: "star", kind: liked ? .primary : .normal, size: .small) { toggleLike() }
                .disabled(busy)
                .frame(minHeight: 44)
                .accessibilityIdentifier("community.reader.like")
        }
    }

    private func marks(_ page: SolutionPage) -> [CommunityReaderPage.Mark] {
        comments.enumerated().compactMap { i, c in
            guard c.pageKey == page.key, c.parentID == nil, let a = c.anchor else { return nil }
            return CommunityReaderPage.Mark(number: i + 1, anchor: a)
        }
    }

    private var commentsCard: some View {
        UFCard {
            UFCardHead("Kommentare", icon: "users")
            Text(CommunityTexts.commentsNotice).ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
            if comments.isEmpty { Text("Noch keine Kommentare.").ufFont(13.12).foregroundStyle(UF.muted) }
            ForEach(Array(comments.enumerated()), id: \.element.id) { i, c in
                commentRow(c, number: i + 1).ufBorderBottom(c.id != comments.last?.id)
            }
            if let target = composerTitle { Text(target).ufFont(12.8, 600).foregroundStyle(UF.text2).padding(.top, 8) }
            UFTextArea(placeholder: "Kommentar schreiben …", text: $draft, minHeight: 70).padding(.top, 8)
                .accessibilityIdentifier("community.reader.commentField")
            HStack(spacing: 8) {
                UFButton(editing == nil ? "Senden" : "Speichern", icon: "check", kind: .primary, size: .small) { send() }
                    .disabled(busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("community.reader.send")
                if composerTitle != nil { UFButton("Abbrechen", size: .small) { resetComposer() } }
            }
            .padding(.top, 8)
        }
    }

    private var composerTitle: String? {
        if editing != nil { return "Kommentar bearbeiten" }
        if let replyTo { return "Antwort an \(replyTo.pseudonym)" }
        return spot != nil ? "Kommentar an der gewählten Stelle" : nil
    }

    private func commentRow(_ c: CommunityComment, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if c.anchor != nil { Text("\(number)").ufFont(11.84, 600).foregroundStyle(UF.accentText) }
                Text(c.pseudonym + (c.byAuthor ? " · Autor" : "") + (c.edited ? " · bearbeitet" : "")).ufFont(12.8, 600).foregroundStyle(UF.text2)
                Text(ForeignSolutionLayer.date(c.createdAt)).ufFont(11.84).foregroundStyle(UF.muted)
            }
            Text(c.deleted ? "Kommentar gelöscht" : c.text).ufFont(14.5, lh: 1.55).foregroundStyle(c.deleted ? UF.muted : UF.text)
                .fixedSize(horizontal: false, vertical: true)
            if !c.deleted {
                HStack(spacing: 4) {
                    UFButton("Antworten", kind: .ghost, size: .small) { resetComposer(); replyTo = c }
                    if c.isMine {
                        UFButton("Bearbeiten", kind: .ghost, size: .small) { resetComposer(); editing = c; draft = c.text }
                    } else {
                        UFButton("Melden", kind: .ghost, size: .small) { act { try await service.reportComment(id: c.id, reason: .other) } }
                    }
                    if c.isMine || solution.isOwn {
                        UFButton("Löschen", kind: .danger, size: .small) { act { try await service.deleteComment(id: c.id) } }
                    }
                }
                .padding(.leading, -8)
            }
        }
        .padding(.vertical, 9.6)
        .padding(.leading, c.parentID == nil ? 0 : 20)
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
        do {
            let c = try await SolutionSharing.loadCommunity(solution.solutionID, service: service)
            images = c.images.compactMapValues { UIImage(data: $0.data) }
            content = c
        } catch { failure = CommunityTexts.message(error) }
    }

    private func act(_ op: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await op()
                comments = try await service.comments(solutionID: solution.solutionID)
                failure = nil
            } catch { failure = CommunityTexts.message(error) }
        }
    }

    private func send() {
        let text = draft, parent = replyTo?.id, edit = editing?.id, place = spot
        act {
            if let edit {
                _ = try await service.editComment(id: edit, text: text)
            } else {
                _ = try await service.addComment(solutionID: solution.solutionID, text: text, parentID: parent, pageKey: place?.page, anchor: place?.anchor)
            }
            resetComposer()
        }
    }

    private func toggleLike() {
        let next = !liked
        act {
            likes = try await service.setLiked(solutionID: solution.solutionID, next)
            liked = next
        }
    }
}

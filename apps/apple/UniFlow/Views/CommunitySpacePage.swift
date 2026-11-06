import SwiftUI
import UniFlowCore

// Seite einer Community (Wunsch des Inhabers 03.11.2026, nach Fotos einer anderen Lern-App, in eigener Gestaltung):
// ganze Seite in der App-Huelle statt Vollbild-Blatt (Route `.communitySpace`), oben links das StudiNow-Logo zur
// Uebersicht und ein Zurueck. Kopf mit Modulname und Hochschule, Reiter "Diskussion" (Fragen und Antworten des Moduls,
// darueber die neuesten geteilten Notizen) und "Dokumente (N)" (Kanal nach Lehrwoche oder als Liste mit Sortierung).
// Nicht beigetreten: unten ein deutlicher Knopf "Beitreten". Die Notizen einer Person oeffnen sich als ganze Seite
// (Reiter "Dokument" | "Diskussion (N)", schwebende Leiste unten).

// MARK: - Texte und Einordnung (testbar)

enum CommunitySpaceTab: Hashable { case discussion, documents }

/// Darstellung der Dokumente: Wochen (Kanal) oder Liste
enum CommunityDocsLayout: Hashable { case weeks, list }

/// Sortierung der Liste: Relevanz = Likes + Kommentare, sonst neueste zuerst
enum CommunityDocsSort: String, CaseIterable, Hashable {
    case relevance, newest

    var title: String { self == .relevance ? "Relevanz" : "Neueste" }
}

enum CommunitySpaceTexts {
    static let joinHint = "Tritt der Community bei, um die geteilten Notizen und die Diskussion zu sehen."
    static let discussionUnavailable = "Fragen und Antworten je Modul gibt es mit diesem Dienst noch nicht. Die geteilten Notizen findest du unter „Dokumente“."
    static let discussionNotice = "Alle Mitglieder sehen deine Fragen und Antworten unter deinem Pseudonym. Sie sind mit dem Schlüssel der Community verschlüsselt."

    /// "Leibniz Universität Hannover · 24 Mitglieder" (Mitglieder nur, wenn der Dienst sie kennt)
    static func subtitle(_ space: CommunitySpace, university: String?) -> String {
        var parts: [String] = []
        if space.kind == .group { parts.append("Lerngruppe") } else if let university, !university.isEmpty { parts.append(university) }
        if !space.current && space.kind == .course { parts.append("früheres Semester") }
        if let m = space.members { parts.append(m == 1 ? "1 Mitglied" : "\(m) Mitglieder") }
        return parts.joined(separator: " · ")
    }

    static func documents(_ n: Int) -> String { "Dokumente (\(n))" }
    static func replies(_ n: Int) -> String { n == 1 ? "1 Antwort" : "\(n) Antworten" }
    static func likes(_ n: Int) -> String { n == 1 ? "1 Like" : "\(n) Likes" }
    static func comments(_ n: Int) -> String { n == 1 ? "1 Kommentar" : "\(n) Kommentare" }

    /// "gerade eben", "vor 3 Stunden"; aelter als eine Woche: das Datum
    static func relative(_ iso: String, now: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        guard let date = f.date(from: iso) ?? { f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.date(from: iso) }() else {
            return ForeignSolutionLayer.date(iso)
        }
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "gerade eben" }
        if seconds > 7 * 86_400 { return ForeignSolutionLayer.date(iso) }
        let r = RelativeDateTimeFormatter()
        r.locale = Locale(identifier: "de_DE")
        r.unitsStyle = .full
        return r.localizedString(for: date, relativeTo: now)
    }

    /// VoiceOver-Text einer Frage
    static func postLabel(_ p: CommunityPost, now: Date = Date()) -> String {
        var parts = ["Frage von \(p.question.pseudonym), \(relative(p.question.createdAt, now: now)): "
                     + (p.question.deleted ? "Frage gelöscht" : p.question.text)]
        if p.answered { parts.append("Beantwortet") }
        parts.append(replies(p.replies.count))
        parts.append(likes(p.likes))
        return parts.joined(separator: ", ")
    }
}

extension CommunityChannelItem {
    var likes: Int { people.reduce(0) { $0 + $1.likes } }
    /// juengste Veroeffentlichung zu diesem Blatt
    var latest: String { people.map(\.createdAt).max() ?? "" }
    /// "von Lea" bzw. "3 Personen"
    var byline: String { people.count == 1 ? "von \(CommunityContributorsSheet.name(people[0]))" : "\(people.count) Personen" }
}

extension CommunityChannel {
    /// Blaetter mit geteilten Notizen als Liste: Relevanz (Likes + Kommentare, dann neueste) oder neueste zuerst
    static func rows(_ weeks: [CommunityChannelWeek], sort: CommunityDocsSort) -> [CommunityChannelItem] {
        let all = weeks.flatMap(\.items).filter { !$0.people.isEmpty }
        return all.sorted { a, b in
            if sort == .relevance, a.likes + a.commentCount != b.likes + b.commentCount { return a.likes + a.commentCount > b.likes + b.commentCount }
            if a.latest != b.latest { return a.latest > b.latest }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }
}

// MARK: - Bausteine

/// Reiter mit Unterstrich wie `UFTabs`, aber mit 44 pt Tippflaeche, ausgewaehlt fuer VoiceOver und Kennungen fuer Tests
struct CommunityTabBar<Value: Hashable>: View {
    let options: [(value: Value, label: String, id: String)]
    @Binding var selection: Value
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Namespace private var underline

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options.indices, id: \.self) { i in
                let o = options[i]
                let active = o.value == selection
                Button {
                    withAnimation(UFMotion.animation(reduce: reduce, fadeWhenReduced: false)) { selection = o.value }
                } label: {
                    Text(o.label).ufFont(15.2, active ? 620 : 500)
                        .foregroundStyle(active ? UF.accentText : UF.text2)
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .overlay(alignment: .bottom) {
                            if active { Rectangle().fill(UF.accent).frame(height: 2).matchedGeometryEffect(id: "community-tab", in: underline) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? [.isSelected] : [])
                .accessibilityIdentifier(o.id)
            }
            Spacer(minLength: 0)
        }
        .ufBorderBottom()
    }
}

/// Filter- bzw. Umschalt-Chip: sichtbar klein, Tippflaeche 44 pt
struct CommunityChip: View {
    let title: String
    var icon: String?
    let on: Bool
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { UFIcon(icon, size: 13) }
                Text(title)
            }
            .ufFont(13.12, on ? 600 : 500)
            .foregroundStyle(on ? UF.accentText : UF.text2)
            .padding(.vertical, 6).padding(.horizontal, 12)
            .background(Capsule().fill(on ? UF.accentSoft : UF.surface))
            .overlay(Capsule().strokeBorder(on ? Color.clear : UF.line, lineWidth: 1))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? [.isSelected] : [])
        .accessibilityIdentifier(id)
    }
}

/// Notizen einer Person, die als ganze Seite offen sind
struct CommunityReading: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let people: [CommunitySolutionSummary]
    let start: Int
}

// MARK: - Seite einer Community

struct CommunitySpacePage: View {
    let key: String
    let service: CommunityService
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var account: AccountStore
    @State private var space: CommunitySpace?
    @State private var missing = false
    @State private var tab: CommunitySpaceTab
    @State private var layout: CommunityDocsLayout = .weeks
    @State private var sort: CommunityDocsSort = .relevance
    @State private var items: [CommunitySolutionSummary]?
    @State private var module: JSONValue?
    @State private var error: String?
    @State private var notice: String?
    @State private var joining = false
    @State private var reading: CommunityReading?
    /// Fachfarbe des Moduls ("#rrggbb"), sobald bekannt
    @State private var tintHex: String?
    /// schmal (iPhone): Fassung an Blaetter weitergeben (Frage, Lösung lesen)
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// kompakt laut Huelle (auch iPhone quer, `UFLayout.isCompact`)
    @Environment(\.ufCompact) private var shellCompact
    /// Korrekturhinweise an eigene Loesungen dieser Community
    @StateObject private var inbox: CorrectionInboxModel
    /// eigene Datei zu einem Fingerabdruck (Korrektur vorschlagen bzw. ansehen); Tests setzen sie
    private let localFile: (String) async -> String?

    init(key: String, space: CommunitySpace? = nil, service: CommunityService? = nil, localFile: ((String) async -> String?)? = nil,
         shared: (() -> [SolutionLibrary.SharedEntry])? = nil) {
        let service = service ?? SolutionSharing.community
        let localFile = localFile ?? { await CorrectionLaunch.localFile(fingerprint: $0) }
        self.key = key
        self.service = service
        self.localFile = localFile
        _inbox = StateObject(wrappedValue: CorrectionInboxModel(service: service, localFile: localFile,
                                                                shared: shared ?? { SolutionSharing.library.sharedEntries() }))
        _space = State(initialValue: space)
        _tintHex = State(initialValue: CommunityTint.known[key])
        _tab = State(initialValue: service.supportsSpaceDiscussion ? .discussion : .documents)
    }

    var body: some View {
        UFGate(.communityRead) {
            Group {
                if let reading { readerPage(reading) } else { overview }
            }
        }
        .environment(\.ufLearnCompact, UFCompactLearn.isCompact(sizeClass, shell: shellCompact))
        .task { await load() }
        // Notizen einer Person wie ein Dokument: ohne Leiste und Kopfzeile (das Logo fuehrt zurueck)
        .onChange(of: reading?.id) { _, id in router.fullscreenDoc = id != nil }
        .onDisappear { if reading != nil { router.fullscreenDoc = false } }
    }

    // MARK: Ueberblick

    private var overview: some View {
        VStack(spacing: 0) {
            UFContent {
                VStack(alignment: .leading, spacing: 16) {
                    // Zurueck steht oben links in der Kopfzeile (`UFBackButton`, 06.11.2026); vorher zusaetzlich "‹ Community" hier
                    if let space {
                        header(space)
                        if space.joined, !inbox.items.isEmpty || inbox.notice != nil { CorrectionInboxList(model: inbox) }
                        CommunityTabBar(options: [(CommunitySpaceTab.discussion, "Diskussion", "community.tab.discussion"),
                                                  (.documents, CommunitySpaceTexts.documents(items?.count ?? 0), "community.tab.documents")],
                                        selection: $tab)
                        if let notice { CommunityNotice(text: notice, tone: .ok) }
                        if let error { CommunityNotice(text: error) }
                        if !space.joined {
                            // Einladung: kleine Komposition und ein Satz; die eine Handlung ist der Knopf unten
                            UFCard {
                                CommunityEmptyState(icon: space.kind == .group ? "users" : "book", companions: ["note", "users"], tint: tint,
                                                    text: CommunitySpaceTexts.joinHint)
                            }
                        } else {
                            Group {
                                switch tab {
                                case .discussion: discussion(space)
                                case .documents: documents
                                }
                            }
                            .ufTabPanel(tab)
                        }
                    } else if missing {
                        UFCard {
                            CommunityEmptyState(icon: "users", companions: ["search", "book"], text: "Diese Community gibt es in deinem Hochschul-Abgleich nicht.") {
                                UFButton("Zur Community", icon: "chevron-left", size: .small) { back() }
                            }
                        }
                    } else if let error {
                        CommunityNotice(text: error)
                    } else {
                        CommunityLoading(text: "Community wird geladen …")
                    }
                }
            }
            if let space, !space.joined { joinBar(space) }
        }
    }

    /// Farbe der Community: Fachfarbe des Moduls (Moduldetail, sonst aus den eigenen Modulen), Lerngruppen im Akzent
    private var tint: Color {
        guard let space else { return UF.accent }
        if space.kind == .course, let hex = tintHex { return Color(hex: hex) }
        return CommunityTint.color(space)
    }

    /// Kopf als Kachel in der Fachfarbe (wie die frueheren Modulkarten, die der Inhaber mochte): blasse Tonflaeche,
    /// Kuerzel-Kachel, grosses ruhiges Symbol rechts oben
    private func header(_ space: CommunitySpace) -> some View {
        let tint = self.tint
        return HStack(alignment: .center, spacing: 16) {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(tint)
                .frame(width: 60, height: 60)
                .overlay {
                    if space.kind == .group { UFIcon("users", size: 26).foregroundStyle(.white) }
                    else { Text(UFFmt.initial(space.name)).font(.uf(24, 700)).foregroundStyle(.white) }
                }
                .rotationEffect(.degrees(-4))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(space.name).ufFont(26, 700, lh: 1.2, em: -0.02).foregroundStyle(UF.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("community.space.title")
                let sub = CommunitySpaceTexts.subtitle(space, university: account.university?.profile.name)
                if !sub.isEmpty { Text(sub).ufFont(13.6).foregroundStyle(UF.text2) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, UFCompactLearn.isCompact(sizeClass, shell: shellCompact) ? 24 : 56)
        }
        .padding(UFCompactLearn.isCompact(sizeClass, shell: shellCompact) ? 16 : 20)
        .background(LinearGradient(stops: [.init(color: CommunityTint.wash(tint, 0.16), location: 0), .init(color: UF.surface, location: 0.78)],
                                   startPoint: UnitPoint(x: 0.2, y: 0), endPoint: UnitPoint(x: 0.8, y: 1)))
        .overlay(alignment: .topTrailing) {
            UFIcon(space.kind == .group ? "users" : "graduation", size: 64).foregroundStyle(tint).opacity(0.16)
                .rotationEffect(.degrees(10)).padding(.top, 14).padding(.trailing, 18)
                .accessibilityHidden(true)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.mix(tint, 0.22, UF.line), lineWidth: 1))
    }

    /// Nicht beigetreten: ein deutlicher Knopf unten (die Erklaerung steht schon auf der Seite)
    private func joinBar(_ space: CommunitySpace) -> some View {
        Button { join(space) } label: {
            HStack(spacing: 8) {
                UFIcon("plus", size: 17)
                Text(joining ? "Wird beigetreten …" : "Beitreten")
            }
            .ufFont(15.2, 650)
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .frame(minWidth: 240, maxWidth: UFCompactLearn.isCompact(sizeClass, shell: shellCompact) ? .infinity : nil, minHeight: 50)
            .background(Capsule().fill(UF.accentFill))
            .contentShape(Capsule())
        }
        .buttonStyle(UFPressStyle(scale: 0.97))
        .disabled(joining)
        .opacity(joining ? 0.7 : 1)
        .accessibilityIdentifier("community.space.join")
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 14)
        .background(UF.surface.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(UF.line).frame(height: 1) }
    }

    /// eigener Stapel: unter `ufTabPanel` (ZStack) lagen die Teile sonst uebereinander
    private func discussion(_ space: CommunitySpace) -> some View {
        VStack(alignment: .leading, spacing: 24) { discussionParts(space) }
    }

    @ViewBuilder private func discussionParts(_ space: CommunitySpace) -> some View {
        if let items, !items.isEmpty {
            CommunityChannelView(service: service, solutions: solutionsBinding, files: module?.list("files") ?? [], weeks: weeks,
                                 layout: .latest, tint: tint, onRead: read)
        }
        if service.supportsSpaceDiscussion {
            CommunitySpaceDiscussion(space: space, service: service, tint: tint)
        } else {
            UFCard { CommunityEmptyState(icon: "users", companions: ["note", "file-text"], tint: tint, text: CommunitySpaceTexts.discussionUnavailable) }
        }
    }

    private var documents: some View {
        VStack(alignment: .leading, spacing: 16) { documentsParts }
    }

    @ViewBuilder private var documentsParts: some View {
        UFFlexWrap(gap: 8) {
            CommunityChip(title: "Wochen", icon: "calendar", on: layout == .weeks, id: "community.docs.weeks") { layout = .weeks }
            CommunityChip(title: "Liste", icon: "list", on: layout == .list, id: "community.docs.list") { layout = .list }
            if layout == .list {
                Text("Sortieren:").ufFont(13.12).foregroundStyle(UF.muted).frame(minHeight: 44).padding(.leading, 12)
                ForEach(CommunityDocsSort.allCases, id: \.self) { s in
                    CommunityChip(title: s.title, on: sort == s, id: "community.docs.sort.\(s.rawValue)") { sort = s }
                }
            }
        }
        if let items {
            if items.isEmpty && (layout == .list || CommunityChannel.skeleton(weeks: weeks).isEmpty) {
                UFCard {
                    CommunityEmptyState(icon: "file-text", companions: ["pencil", "star"], tint: tint,
                                        text: "Noch keine geteilten Notizen in dieser Community. Teile deine über „Teilen“ → Community in einer PDF.")
                }
            } else {
                CommunityChannelView(service: service, solutions: solutionsBinding, files: module?.list("files") ?? [], weeks: weeks,
                                     layout: layout == .weeks ? .weeks : .list, sort: sort, tint: tint, onRead: read)
            }
        } else if error == nil {
            CommunityLoading(text: "Lösungen werden geladen …")
        }
    }

    private var weeks: [JSONValue] { module?.list("weeks") ?? [] }

    private var solutionsBinding: Binding<[CommunitySolutionSummary]> {
        Binding(get: { self.items ?? [] }, set: { self.items = $0 })
    }

    // MARK: Notizen einer Person

    private func read(_ item: CommunityChannelItem, _ index: Int) {
        reading = CommunityReading(title: item.title, people: item.people, start: index)
    }

    private func readerPage(_ r: CommunityReading) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Text(r.title).ufFont(15.2, 650).foregroundStyle(UF.text).lineLimit(1)
                    .padding(.horizontal, 200)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 6) {
                    // derselbe Pfeil wie ueberall: schliesst die Notizen zurueck zur Community-Seite
                    UFBackButton(style: .header) { reading = nil }
                    UFLogoMenu()
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .background(UF.surface)
            .ufBorderBottom()
            CommunityPeopleReader(title: r.title, people: r.people, start: r.start, service: service, wide: true,
                                  localFile: localFile, leave: { reading = nil },
                                  removed: { text, matches in
                                      reading = nil
                                      items?.removeAll(where: matches)
                                      notice = text
                                  })
        }
        .background(UF.bg)
    }

    // MARK: Ablauf

    private func back() {
        if router.canGoBack { router.back() } else { router.go(.community) }
    }

    /// Eine Seite fuer jede Antwort: Community, Wochen des eigenen Moduls (Kanal), Loesungen nur fuer Mitglieder
    func load() async {
        guard Entitlements.shared.allows(.communityRead) else { return }          // Community ab Plus (05.11.2026)
        if space == nil {
            do {
                space = try await service.communities().first { $0.key == key }
                missing = space == nil
            } catch {
                self.error = CommunityTexts.message(error)
                return
            }
        }
        guard let space else { return }
        if space.kind == .course, module == nil, let api = session.api, let uni = account.university?.rawValue {
            if CommunityTint.known[space.key] == nil { await CommunityTint.load(api: api, university: uni) }
            tintHex = CommunityTint.known[space.key]
            module = await CommunityChannel.module(for: space.key, university: uni, api: api)
            if let hex = module?["module"]?.s("color") {
                CommunityTint.remember(space.key, hex: hex)
                tintHex = CommunityTint.known[space.key] ?? tintHex
            }
        }
        guard space.joined else { return }
        do { items = try await service.solutions(in: space); error = nil } catch { self.error = CommunityTexts.message(error) }
        if let items {
            await inbox.load(known: items, only: Set(items.filter(\.isOwn).map { $0.solutionID.lowercased() }))
        }
    }

    private func join(_ s: CommunitySpace) {
        joining = true
        error = nil
        Task {
            defer { joining = false }
            do {
                try await service.join(s)
                CommunityMatches.shared.invalidate()
                space?.joined = true
                await load()
            } catch { self.error = CommunityTexts.message(error) }
        }
    }

    /// Zeile einer Loesung (Trefferliste, Tests): Pseudonym, Datum und – wenn der Dienst sie kennt – Likes und Kommentare
    static func detail(_ s: CommunitySolutionSummary, account: Bool) -> String {
        var parts = ["Lösung von \(s.displayName.isEmpty ? "Anonym" : s.displayName)", ForeignSolutionLayer.date(s.createdAt)]
        if account {
            parts.append(CommunitySpaceTexts.likes(s.likes))
            parts.append(CommunitySpaceTexts.comments(s.commentCount))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Diskussion: Fragen und Antworten des Moduls

struct CommunitySpaceDiscussion: View {
    let space: CommunitySpace
    let service: CommunityService
    /// Farbe der Community (Leerzustand)
    var tint: Color = UF.accent
    @State private var posts: [CommunityPost]?
    @State private var filter: CommunityPostFilter = .newest
    @State private var draft = ""
    @State private var busy = false
    @State private var error: String?
    @State private var thread: CommunityPost?
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// kompakt laut Huelle (auch iPhone quer, `UFLayout.isCompact`)
    @Environment(\.ufCompact) private var shellCompact
    @Environment(\.ufLearnCompact) private var learnCompact

    /// schmal: Filter unter dem Titel, Feld ohne Kreis in voller Breite, Knopf darunter
    private var compact: Bool { UFCompactLearn.isCompact(sizeClass, shell: shellCompact, inherited: learnCompact) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if compact {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Fragen und Antworten").ufFont(17.6, 650, em: -0.01).foregroundStyle(UF.text).accessibilityAddTraits(.isHeader)
                    UFCompactScrollRow(spacing: 8, inset: 0) { filterChips }
                }
            } else {
                HStack(alignment: .center, spacing: 8) {
                    Text("Fragen und Antworten").ufFont(17.6, 650, em: -0.01).foregroundStyle(UF.text).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    filterChips
                }
            }
            UFCard {
                HStack(alignment: .top, spacing: 12) {
                    if !compact {
                        CommunityAvatar(name: SolutionDisplayName.load().isEmpty ? "Du" : SolutionDisplayName.load(), size: 36, own: true)
                            .padding(.top, 2)
                    }
                    UFTextArea(placeholder: "Frage stellen …", text: $draft, minHeight: 44)
                        .accessibilityIdentifier("community.discussion.field")
                }
                let foot = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
                foot {
                    Text(CommunitySpaceTexts.discussionNotice).ufFont(12.48).foregroundStyle(UF.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if !compact { Spacer(minLength: 8) }
                    UFButton(busy ? "Wird gesendet …" : "Frage stellen", icon: "check", kind: .primary, size: .small) { ask() }
                        .disabled(busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("community.discussion.ask")
                }
                .padding(.top, 10).padding(.leading, compact ? 0 : 48)
            }
            if let error { CommunityNotice(text: error) }
            if let posts {
                let shown = CommunityDiscussion.filtered(posts, filter)
                if shown.isEmpty {
                    UFCard {
                        if filter == .unanswered {
                            CommunityEmptyState(icon: "check", companions: ["note", "star"], tint: UF.ok, text: "Keine offenen Fragen.")
                        } else {
                            CommunityEmptyState(icon: "note", companions: ["users", "sparkles"], tint: tint, text: "Noch keine Fragen. Stell die erste!")
                        }
                    }
                } else {
                    // je Frage eine eigene Karte: luftiger als eine lange Liste, erscheint beim ersten Mal leicht gestaffelt
                    VStack(spacing: 10) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { i, p in
                            CommunityPostRow(post: p, busy: busy, open: { thread = p }, like: { like(p) })
                                .ufAppear("community-posts", index: i)
                        }
                    }
                }
            } else if error == nil {
                CommunityLoading(text: "Fragen werden geladen …")
            }
        }
        .task(id: space.key) { await load() }
        .sheet(item: $thread, onDismiss: { Task { await load() } }) { p in
            CommunityThreadSheet(space: space, service: service, post: p) { thread = nil }
        }
    }

    @ViewBuilder private var filterChips: some View {
        ForEach(CommunityPostFilter.allCases, id: \.self) { f in
            CommunityChip(title: f.title, on: filter == f, id: "community.discussion.filter.\(f.rawValue)") { filter = f }
        }
    }

    private func load() async {
        do { posts = try await service.posts(in: space); error = nil } catch { self.error = CommunityTexts.message(error) }
    }

    private func ask() {
        let text = draft
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try await service.addPost(in: space, text: text, parentID: nil)
                draft = ""
                filter = .newest
                await load()
            } catch { self.error = CommunityTexts.message(error) }
        }
    }

    private func like(_ p: CommunityPost) {
        let next = !p.likedByMe
        busy = true
        Task {
            defer { busy = false }
            do {
                let n = try await service.setPostLiked(in: space, postID: p.id, next)
                if let i = posts?.firstIndex(where: { $0.id == p.id }) {
                    posts?[i].likes = n
                    posts?[i].likedByMe = next
                }
                error = nil
            } catch { self.error = CommunityTexts.message(error) }
        }
    }
}

/// Eine Frage als Karte: Person (Pastellkreis), wann, "Beantwortet", Text; darunter Gefaellt mir und Antworten (mit den
/// Kreisen derer, die geantwortet haben)
struct CommunityPostRow: View {
    let post: CommunityPost
    var busy = false
    let open: () -> Void
    let like: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: open) {
                HStack(alignment: .top, spacing: 12) {
                    CommunityAvatar(name: post.question.pseudonym, size: 38, own: post.question.isMine)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(post.question.pseudonym).ufFont(14.08, 650).foregroundStyle(UF.text).lineLimit(1)
                            Text(CommunitySpaceTexts.relative(post.question.createdAt)).ufFont(12.8).foregroundStyle(UF.muted).lineLimit(1)
                            Spacer(minLength: 8)
                            if post.answered { UFBadge("Beantwortet", tone: .ok, icon: "check") }
                        }
                        Text(post.question.deleted ? "Frage gelöscht" : post.question.text)
                            .ufFont(15.2, lh: 1.5).foregroundStyle(post.question.deleted ? UF.muted : UF.text)
                            .lineLimit(4).multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(CommunitySpaceTexts.postLabel(post))
            .accessibilityHint("Öffnet die Antworten")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open() }
            .accessibilityIdentifier("community.post.\(post.id)")
            HStack(spacing: 6) {
                CommunityLikeButton(count: post.likes, liked: post.likedByMe, enabled: !post.question.isMine && !post.question.deleted && !busy,
                                    id: "community.post.like.\(post.id)", action: like)
                Button(action: open) {
                    HStack(spacing: 7) {
                        if post.replies.isEmpty {
                            UFIcon("note", size: 15)
                        } else {
                            CommunityAvatarStack(names: Self.repliers(post), size: 20)
                        }
                        Text(CommunitySpaceTexts.replies(post.replies.count))
                    }
                    .ufFont(13.12, 550).foregroundStyle(UF.text2)
                    .padding(.horizontal, 10).frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(UFPressStyle(scale: 0.96))
                .accessibilityLabel(CommunitySpaceTexts.replies(post.replies.count))
                .accessibilityHint("Öffnet die Antworten")
                .accessibilityIdentifier("community.post.replies.\(post.id)")
            }
            .padding(.leading, 40)
        }
        .padding(.top, 14).padding(.bottom, 4).padding(.horizontal, 16)
        .background(RoundedRectangle(cornerRadius: UF.rLg, style: .continuous).fill(UF.surface))
        .overlay(RoundedRectangle(cornerRadius: UF.rLg, style: .continuous).strokeBorder(UF.line, lineWidth: 1))
    }

    /// verschiedene Personen, die geantwortet haben (Reihenfolge der Antworten)
    static func repliers(_ p: CommunityPost) -> [String] {
        var seen = Set<String>()
        return p.replies.filter { !$0.deleted }.map(\.pseudonym).filter { seen.insert($0).inserted }
    }
}

/// Stern mit Zahl als weiche Kapsel; gemocht: gefuellter Stern in Gelb mit kurzem Funkenflug. Eigene Beitraege zeigen
/// nur die Zahl (Knopf gesperrt)
struct CommunityLikeButton: View {
    let count: Int
    let liked: Bool
    let enabled: Bool
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                CommunityLikeStar(liked: liked, size: 15)
                Text("\(count)").ufNumber(count, numeric: Double(count))
            }
            .ufFont(13.12, liked ? 650 : 550)
            .foregroundStyle(liked ? CommunityPalette.butter.fg : UF.text2)
            .padding(.horizontal, 12).frame(minHeight: 32)
            .background(Capsule().fill(liked ? CommunityPalette.butter.bg : Color.clear))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(UFPressStyle(scale: 0.94))
        .disabled(!enabled)
        .accessibilityLabel("\(liked ? "Gefällt dir" : "Gefällt mir"), \(CommunitySpaceTexts.likes(count))")
        .accessibilityIdentifier(id)
    }
}

/// Eine Frage mit allen Antworten und Eingabe
struct CommunityThreadSheet: View {
    let space: CommunitySpace
    let service: CommunityService
    @State var post: CommunityPost
    let close: () -> Void
    @State private var draft = ""
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// kompakt laut Huelle (auch iPhone quer, `UFLayout.isCompact`)
    @Environment(\.ufCompact) private var shellCompact
    @Environment(\.ufLearnCompact) private var learnCompact

    /// schmal: Antwortfeld unten fest ueber der Tastatur, Rand 16 pt
    private var compact: Bool { UFCompactLearn.inSheet(shell: shellCompact, inherited: learnCompact) }

    var body: some View {
        NavigationStack {
            UFContent(maxWidth: 760, insets: EdgeInsets(top: 16, leading: compact ? 16 : 20, bottom: 32, trailing: compact ? 16 : 20)) {
                VStack(alignment: .leading, spacing: 16) {
                    if let notice { CommunityNotice(text: notice, tone: .ok) }
                    if let error { CommunityNotice(text: error) }
                    UFCard {
                        entryHead(post.question)
                        Text(post.question.deleted ? "Frage gelöscht" : post.question.text)
                            .ufFont(17.6, 500, lh: 1.5).foregroundStyle(post.question.deleted ? UF.muted : UF.text)
                            .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                            .textSelection(.enabled)
                        HStack(spacing: 8) {
                            CommunityLikeButton(count: post.likes, liked: post.likedByMe,
                                                enabled: !post.question.isMine && !post.question.deleted && !busy,
                                                id: "community.thread.like") { like() }
                            if post.answered { UFBadge("Beantwortet", tone: .ok, icon: "check") }
                        }
                        .padding(.leading, -8)
                    }
                    Text(post.replies.isEmpty ? "Noch keine Antworten" : CommunitySpaceTexts.replies(post.replies.count))
                        .ufFont(13.6, 650).foregroundStyle(UF.text2).accessibilityAddTraits(.isHeader)
                    if !post.replies.isEmpty {
                        UFCard(padded: false) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(post.replies) { r in
                                    VStack(alignment: .leading, spacing: 4) {
                                        entryHead(r)
                                        Text(r.text).ufFont(14.5, lh: 1.55).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                                            .textSelection(.enabled)
                                    }
                                    .padding(.vertical, 10)
                                    .ufBorderBottom(r.id != post.replies.last?.id)
                                    .accessibilityElement(children: .combine)
                                }
                            }
                            .padding(.horizontal, 14)
                        }
                    }
                    if !post.question.deleted && !compact { replyComposer }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !post.question.deleted && compact {
                    UFCompactBottomBar { replyComposer }.accessibilityIdentifier("community.thread.bottom")
                }
            }
            .navigationTitle("Frage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig", action: close) } }
        }
        .accessibilityIdentifier("community.thread")
    }

    /// Antwortfeld: breit unter den Antworten, schmal unten fest (Feld und Senden in einer Reihe)
    @ViewBuilder private var replyComposer: some View {
        let send = UFButton(busy ? "Wird gesendet …" : "Antworten", icon: "check", kind: .primary, size: .small) { reply() }
            .disabled(busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("community.thread.send")
        if compact {
            HStack(alignment: .bottom, spacing: 8) {
                UFCompactComposerField(placeholder: "Antworten …", text: $draft)
                    .accessibilityIdentifier("community.thread.field")
                send.frame(minHeight: 44)
            }
        } else {
            UFTextArea(placeholder: "Antworten …", text: $draft, minHeight: 60)
                .accessibilityIdentifier("community.thread.field")
            send
        }
    }

    private func entryHead(_ c: CommunityComment) -> some View {
        HStack(spacing: 8) {
            CommunityAvatar(name: c.pseudonym, size: 32, own: c.isMine)
            Text(c.pseudonym + (c.edited ? " · bearbeitet" : "")).ufFont(13.6, 600).foregroundStyle(UF.text).lineLimit(1)
            Text(CommunitySpaceTexts.relative(c.createdAt)).ufFont(12.8).foregroundStyle(UF.muted).lineLimit(1)
            Spacer(minLength: 8)
            if !c.deleted {
                Menu {
                    if c.isMine {
                        Button(role: .destructive) { act { try await service.deleteComment(id: c.id) } } label: { Label("Löschen", systemImage: "trash") }
                    } else {
                        Button {
                            act {
                                try await service.reportComment(id: c.id, reason: .other)
                                notice = "Danke – der Beitrag wurde gemeldet."
                            }
                        } label: { Label("Melden …", systemImage: "flag") }
                    }
                } label: {
                    UFIcon("more", size: 18).foregroundStyle(UF.text2).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Mehr zu diesem Beitrag")
            }
        }
    }

    private func reload() async throws {
        if let fresh = try await service.posts(in: space).first(where: { $0.id == post.id }) {
            post = fresh
        } else {
            close()                                             // geloeschte Frage ohne Antworten
        }
    }

    private func act(_ op: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await op()
                try await reload()
                error = nil
            } catch { self.error = CommunityTexts.message(error) }
        }
    }

    private func reply() {
        let text = draft
        act {
            _ = try await service.addPost(in: space, text: text, parentID: post.id)
            draft = ""
        }
    }

    private func like() {
        let next = !post.likedByMe
        busy = true
        Task {
            defer { busy = false }
            do {
                post.likes = try await service.setPostLiked(in: space, postID: post.id, next)
                post.likedByMe = next
            } catch { self.error = CommunityTexts.message(error) }
        }
    }
}

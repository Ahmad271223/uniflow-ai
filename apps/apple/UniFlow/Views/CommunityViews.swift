import CoreImage.CIFilterBuiltins
import SwiftUI
import UniFlowCore

// Oberflaeche der Online-Community (docs/LOESUNGEN-TEILEN.md, Abschnitt 7): Treffer zu einem Blatt im Dokument
// (Laden und anzeigen, Melden, Blockieren, eigene zurueckziehen), Bereich "Community" im Moduldetail nach Lehrwoche,
// Einstellungen (Pseudonym, Lerngruppen mit Code/QR, Sperrliste). Lesen, Laden, Melden, Blockieren, Beitreten und das
// Zurueckziehen eigener Loesungen gehen in jedem Tarif (can_read_community, wie app/community.py); Veroeffentlichen,
// Pseudonym und Lerngruppen anlegen ab Plus (can_share_solutions). Nur, wenn der Build einen iCloud-Container hat
// (sonst "nicht verfuegbar", nichts vorgetaeuscht).

/// Feste Texte (auch fuer Tests).
enum CommunityTexts {
    static let copyright = "In der Community erscheinen nur deine eigenen Notizen – kein Originalmaterial deiner Hochschule (Folien, Aufgabenstellungen, Skripte). Mit dem Veröffentlichen bestätigst du, dass alles von dir stammt."
    static let visibilityModule = "Sichtbar für alle an deiner Hochschule, die dasselbe Modul in Stud.IP bzw. Learnweb haben. Eine Bestätigung der Hochschule gibt es nicht."
    static let visibilityGroup = "Sichtbar nur für Mitglieder der gewählten Lerngruppe (wer den Beitrittscode kennt)."
    static let visibilityAnonymous = "Sichtbar für alle an deiner Hochschule, die dieselbe PDF haben – ohne Pseudonym."
    static let privacy = "Hochgeladen werden nur das verschlüsselte Paket, Fingerabdruck und Seitenzahl, Community und dein Pseudonym – nie Apple-ID, Name, E-Mail, Matrikelnummer oder Kurs-ID. Lesen können die Lösung die Mitglieder der Community."
    static let visibilityMembers = "Sichtbar für die Mitglieder dieser Community. Wer dieselbe PDF hat, sieht deine Notizen darüber, alle anderen auf leeren Seiten."
    static let commentsNotice = "Alle Mitglieder dieser Community sehen deine Kommentare unter deinem Pseudonym. Tippe auf eine Seite, um eine Stelle zu kommentieren. Schreiben geht ab Plus mit bestätigter E-Mail-Adresse."
    /// CloudKit: Kommentare verschluesselt mit dem Schluessel der Community, Apple sieht nur Zeitpunkte
    static let commentsNoticeCloud = "Alle Mitglieder dieser Community sehen deine Kommentare unter deinem Pseudonym aus den Einstellungen. Sie sind mit dem Schlüssel der Community verschlüsselt. Tippe auf eine Seite, um eine Stelle zu kommentieren."
    static let noCommunity = "Du bist noch in keiner Community. Tritt unter „Community“ dem Modul bei, dann kannst du hier teilen."
    static let privacyAccount = "Der StudiNow-Dienst bekommt das verschlüsselte Paket, Fingerabdruck, Seitenzahl, Titel und dein Pseudonym, dazu die Schlüssel deiner Kurse und die Fingerabdrücke deiner PDFs. Kurs-IDs und Beitrittscodes bleiben auf dem Gerät. Andere sehen nie deine E-Mail-Adresse. Lesen können die Lösung die Mitglieder der Community."
    static let unavailable = CommunityServiceError.unavailable.localizedDescription
    /// Einstellungen und Community-Seite ohne iCloud-Container: ehrlich, mit dem Weg, der bleibt
    static let unavailableHint = "Dieser Build hat keinen iCloud-Container (dafür braucht es das Apple Developer Program). Es wird nichts veröffentlicht und nichts gesucht. Lösungen teilst du weiterhin als verschlüsselte Datei – im Editor unter „Ebenen“."
    static let blockNotice = "Lösungen dieser Person erscheinen für dich nicht mehr. Die Sperrliste ist nur für dich sichtbar und lässt sich in den Einstellungen aufheben."
    static let reportNotice = "Die Meldung geht an die Moderation von StudiNow. Gemeldet wird nur die Lösung, nicht deine Apple-ID. Schreib keine persönlichen Daten in den Hinweis."
    /// Free: wo man schreiben wuerde, steht der Weg zu Plus (Lesen, Melden, Blockieren und Beitreten gehen ohne)
    static let pseudonymPlusHint = "Ein Pseudonym brauchst du erst zum Veröffentlichen eigener Lösungen – ab \(UFPlan.plus.name)."
    static let createGroupPlusHint = "Eigene Lerngruppen anlegen und Lösungen veröffentlichen kannst du ab \(UFPlan.plus.name). Beitreten geht in jedem Tarif."

    static func matches(_ n: Int) -> String {
        n == 1 ? "1 Lösung aus der Community zu diesem Blatt" : "\(n) Lösungen aus der Community zu diesem Blatt"
    }

    static func privacy(_ service: CommunityService) -> String { service.isAccountService ? privacyAccount : privacy }

    @MainActor @ViewBuilder static func badge(_ service: CommunityService) -> some View {
        if service.isConnected {
            UFBadge(service.isAccountService ? "StudiNow-Konto" : "iCloud", tone: .ok)          // nicht "CloudKit" (Fachwort)
        } else {
            UFBadge("nicht verfügbar", tone: .warn)
        }
    }

    static func publishedAt(_ iso: String) -> String { "veröffentlicht am \(ForeignSolutionLayer.date(iso))" }

    static func visibility(_ v: CommunityVisibility) -> String {
        switch v {
        case .module: return visibilityModule
        case .studyGroup: return visibilityGroup
        case .anonymous: return visibilityAnonymous
        }
    }

    /// Nutzerkennung des Dienstes gekuerzt (nie Apple-ID oder E-Mail; sie ist ohnehin nur eine Zufallskennung)
    static func owner(_ record: String) -> String {
        record.count > 10 ? "Nutzer …" + String(record.suffix(6)) : "Nutzer " + record
    }

    static func message(_ error: Error) -> String {
        (error as? CommunityServiceError)?.localizedDescription ?? (error as? SolutionError)?.description ?? error.localizedDescription
    }
}

/// Beitrittslink im QR-Code einer Lerngruppe: uniflow://community/join/<Code>
enum CommunityJoinLink {
    static func url(code: String) -> URL { URL(string: "uniflow://community/join/\(code)")! }

    static func code(from url: URL) -> String? {
        guard url.scheme == "uniflow", url.host == "community", url.pathComponents.count == 3, url.pathComponents[1] == "join" else {
            return nil
        }
        return CommunityKeys.normalizedGroupCode(url.pathComponents[2])
    }

    /// Rueckfrage vor dem Beitritt ueber einen Link (Sicherheitspruefung 3.11.2026): nie still beitreten
    static func confirmText(name: String) -> String {
        "Der Lerngruppe „\(name)“ beitreten? Mitglieder sehen die Lösungen, die in dieser Gruppe geteilt werden."
    }
}

// MARK: - Zustaende (Hinweis, Laden)

/// Rueckmeldung im Ablauf (Fehler oder Erfolg): Symbol im Ton, Text in Textfarbe, blasse Flaeche im Ton – statt
/// einer nackten roten oder gruenen Zeile, die neben Fliesstext leicht untergeht
struct CommunityNotice: View {
    let text: String
    var tone: UFTone = .bad

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            UFIcon(tone == .ok ? "check" : tone == .info ? "info" : "alert", size: 14).foregroundStyle(tone.fg)
            Text(text).ufFont(13.12, 500).foregroundStyle(UF.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8.8).padding(.horizontal, 12.8)
        .background(RoundedRectangle(cornerRadius: UF.rSm).fill(tone.bg))
        .accessibilityElement(children: .combine)
    }
}

/// Laden mit Satz, was gerade passiert (statt eines einzelnen Kreisels ohne Kontext)
struct CommunityLoading: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).ufFont(13.12).foregroundStyle(UF.muted)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Communities (je Modul und Lerngruppe)

/// Alle Module aus dem eigenen Abgleich und die Lerngruppen: beitreten, verlassen, Loesungen ansehen. Jede Community als
/// Kachel in der Fachfarbe ihres Moduls (blasse Tonflaeche, Kuerzel-Kachel, ruhiges Symbol), wie die frueheren
/// Modulkarten, die der Inhaber mochte
struct CommunitySpacesCard: View {
    private var service: CommunityService { SolutionSharing.community }
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var account: AccountStore
    @State private var spaces: [CommunitySpace]?
    @State private var error: String?
    @State private var busy: String?
    /// fruehere Kurse eingeblendet (03.11.2026: sonst nur das aktuelle Semester)
    @State private var showOlder = false
    /// Fachfarben geladen (loest das Neuzeichnen aus)
    @State private var tintsLoaded = false
    @StateObject private var inbox = CorrectionInboxModel(service: SolutionSharing.community)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                UFIcon("users", size: 20).foregroundStyle(UF.accentText)
                Text("Deine Communities").ufFont(19.2, 680, em: -0.01).foregroundStyle(UF.text).accessibilityAddTraits(.isHeader)
            }
            Text("Jedes Modul hat eine Community für Vorlesung, Übungen und Tutorien. Tritt bei, dann siehst und teilst du dort Lösungen.")
                .ufFont(13.6).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
            if let error { CommunityNotice(text: error) }
            // Korrekturhinweise an eigene Loesungen (Posteingang, ruhig ueber den Kacheln)
            if !inbox.items.isEmpty || inbox.notice != nil { CorrectionInboxList(model: inbox) }
            if let all = spaces {
                let _ = tintsLoaded                                    // nach dem Laden der Fachfarben neu zeichnen
                let older = all.filter { $0.kind == .course && !$0.current }
                let spaces = showOlder ? all : all.filter { $0.kind == .group || $0.current }
                if spaces.isEmpty && older.isEmpty {
                    UFCard {
                        CommunityEmptyState(icon: "book", companions: ["users", "sync"], text: "Noch keine Module. Gleiche zuerst deine Hochschule ab.")
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                    ForEach(Array(spaces.enumerated()), id: \.element.id) { i, s in
                        CommunitySpaceTile(space: s, tint: CommunityTint.color(s), busy: busy != nil,
                                           open: { router.go(.communitySpace(s.key)) },
                                           change: { change(s, join: $0) })
                            .ufAppear("community-spaces", index: i)
                    }
                }
                if !older.isEmpty {
                    UFButton(showOlder ? "Frühere Kurse ausblenden" : "Frühere Kurse (\(older.count))",
                             icon: showOlder ? "chevron-up" : "clock", size: .small) { UFMotion.toggle { showOlder.toggle() } }
                        .padding(.top, 2)
                        .accessibilityIdentifier("community.older")
                }
            } else if error == nil {
                CommunityLoading(text: "Communities werden geladen …")
            }
        }
        .padding(.bottom, 24)
        .task { await reload() }
        .task { await inbox.load() }
        .task {
            guard let api = session.api, let uni = account.university?.rawValue else { return }
            await CommunityTint.load(api: api, university: uni)
            tintsLoaded = true
        }
    }

    static func detail(_ s: CommunitySpace) -> String {
        var parts = [s.kind == .group ? "Lerngruppe" : (s.current ? "Modul" : "Modul · früheres Semester")]
        if let m = s.members { parts.append(m == 1 ? "1 Mitglied" : "\(m) Mitglieder") }
        if let n = s.solutions { parts.append(n == 1 ? "1 Lösung" : "\(n) Lösungen") }
        return parts.joined(separator: " · ")
    }

    private func reload() async {
        do { spaces = try await service.communities(); error = nil } catch { self.error = CommunityTexts.message(error) }
    }

    private func change(_ s: CommunitySpace, join: Bool) {
        busy = s.key
        Task {
            defer { busy = nil }
            do {
                if join { try await service.join(s) } else { try await service.leave(s) }
                CommunityMatches.shared.invalidate()
                await reload()
            } catch { self.error = CommunityTexts.message(error) }
        }
    }
}

/// Kachel einer Community: Kuerzel in der Fachfarbe, Name, Art und Zahlen; unten Oeffnen bzw. Ansehen und Beitreten
/// bzw. Verlassen (dieselben Handlungen und Kennungen wie vorher in der Zeile)
struct CommunitySpaceTile: View {
    let space: CommunitySpace
    let tint: Color
    let busy: Bool
    let open: () -> Void
    let change: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint)
                    .frame(width: 44, height: 44)
                    .overlay {
                        if space.kind == .group { UFIcon("users", size: 20).foregroundStyle(.white) }
                        else { Text(UFFmt.initial(space.name)).font(.uf(18, 700)).foregroundStyle(.white) }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if space.joined {
                            UFIcon("check", size: 10).foregroundStyle(.white)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(UF.okFill))
                                .overlay(Circle().strokeBorder(UF.surface, lineWidth: 2))
                                .offset(x: 5, y: 5)
                        }
                    }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(space.name).ufFont(15.2, 650, lh: 1.3).foregroundStyle(UF.text)
                        .lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(CommunitySpacesCard.detail(space))
                        .ufFont(12.8).foregroundStyle(UF.text2).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 30)
                .accessibilityElement(children: .combine)
                .accessibilityValue(space.joined ? "beigetreten" : "")
            }
            HStack(spacing: 8) {
                // ganze Seite der Community (03.11.2026, vorher Vollbild-Blatt); auch vor dem Beitritt ansehen
                UFButton(space.joined ? "Öffnen" : "Ansehen", size: .small, action: open)
                    .accessibilityIdentifier("community.open.\(space.key)")
                Spacer(minLength: 0)
                if space.joined {
                    if space.kind == .course { UFButton("Verlassen", kind: .ghost, size: .small) { change(false) }.disabled(busy) }
                } else {
                    UFButton("Beitreten", icon: "plus", kind: .primary, size: .small) { change(true) }.disabled(busy)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(LinearGradient(stops: [.init(color: CommunityTint.wash(tint, 0.13), location: 0), .init(color: UF.surface, location: 0.8)],
                                   startPoint: UnitPoint(x: 0.25, y: 0), endPoint: UnitPoint(x: 0.75, y: 1)))
        .overlay(alignment: .topTrailing) {
            UFIcon(space.kind == .group ? "users" : "graduation", size: 40).foregroundStyle(tint).opacity(0.15)
                .rotationEffect(.degrees(10)).padding(.top, 12).padding(.trailing, 12)
                .accessibilityHidden(true)
        }
        .clipShape(RoundedRectangle(cornerRadius: UF.rLg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: UF.rLg, style: .continuous).strokeBorder(Color.mix(tint, 0.2, UF.line), lineWidth: 1))
        .hoverEffect(.highlight)
    }
}

/// Leser einer Community-Loesung: Notizen auf leeren Seiten, darunter die Kommentare der Community. Tippen auf eine Seite
/// kommentiert genau diese Stelle. Hat das Geraet dieselbe PDF, fuehrt der Knopf ins Dokument; dort liegt die Loesung als
/// Ebene ueber der PDF.
struct CommunityReaderSheet: View {
    let solution: CommunitySolutionSummary
    let service: CommunityService
    let close: () -> Void
    @EnvironmentObject private var router: UFRouter
    @State private var content: SolutionContent?
    @State private var images: [String: UIImage] = [:]
    @State private var localFile: String?
    @State private var error: String?
    @State private var comments: [CommunityComment] = []
    @State private var liked = false
    @State private var likes = 0
    @State private var draft = ""
    @State private var replyTo: CommunityComment?
    @State private var editing: CommunityComment?
    @State private var spot: (page: String, anchor: CommunityComment.Anchor)?
    @State private var busy = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// kompakt laut Huelle (auch iPhone quer, `UFLayout.isCompact`)
    @Environment(\.ufCompact) private var shellCompact
    @Environment(\.ufLearnCompact) private var learnCompact

    /// schmal: Kommentarfeld unten fest ueber der Tastatur, Rand 16 pt
    private var compact: Bool { UFCompactLearn.inSheet(shell: shellCompact, inherited: learnCompact) }

    var body: some View {
        NavigationStack {
            UFContent(maxWidth: 860, insets: EdgeInsets(top: 16, leading: compact ? 16 : 20, bottom: 32, trailing: compact ? 16 : 20)) {
                VStack(alignment: .leading, spacing: 16) {
                    if let error { CommunityNotice(text: error) }
                    if let localFile {
                        UFCard {
                            Text("Du hast dieselbe PDF. Im Dokument liegt die Lösung als Ebene darüber.").ufFont(13.12).foregroundStyle(UF.text2)
                            UFButton("In meiner PDF ansehen", icon: "layers", kind: .primary, size: .small) {
                                close()
                                router.go(.doc(localFile, task: nil, page: nil))
                            }
                            .padding(.top, 8)
                        }
                    } else if content != nil {
                        Text("Du hast diese PDF nicht, darum stehen die Notizen auf leeren Seiten.").ufFont(13.12).foregroundStyle(UF.muted)
                    }
                    if let content {
                        ForEach(content.pages, id: \.key) { page in
                            CommunityReaderPage(page: page, images: images, marks: marks(page), tapped: service.supportsDiscussion ? { anchor in
                                spot = (page.key, anchor)
                                replyTo = nil
                                editing = nil
                            } : nil)
                        }
                    } else if error == nil { CommunityLoading(text: "Lösung wird geladen …") }
                    if service.supportsDiscussion { commentsCard }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if service.supportsDiscussion && compact {
                    UFCompactBottomBar { commentComposer }.accessibilityIdentifier("community.reader.bottom")
                }
            }
            .navigationTitle(solution.title.isEmpty ? "Lösung" : solution.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig", action: close) } }
        }
        .task { await load() }
    }

    private func marks(_ page: SolutionPage) -> [CommunityReaderPage.Mark] {
        comments.enumerated().compactMap { i, c in
            guard c.pageKey == page.key, c.parentID == nil, let a = c.anchor else { return nil }
            return CommunityReaderPage.Mark(number: i + 1, anchor: a)
        }
    }

    private var commentsCard: some View {
        UFCard {
            UFCardHead("Kommentare", icon: "users") {
                if !solution.isOwn {
                    UFButton("\(liked ? "Gefällt dir" : "Gefällt mir") · \(likes)", size: .small) { toggleLike() }.disabled(busy)
                } else {
                    Text(likes == 1 ? "1 Like" : "\(likes) Likes").ufFont(12.8).foregroundStyle(UF.muted)
                }
            }
            Text(service.isAccountService ? CommunityTexts.commentsNotice : CommunityTexts.commentsNoticeCloud).ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
            if comments.isEmpty { Text("Noch keine Kommentare.").ufFont(13.12).foregroundStyle(UF.muted) }
            ForEach(Array(comments.enumerated()), id: \.element.id) { i, c in
                commentRow(c, number: i + 1).ufBorderBottom(c.id != comments.last?.id)
            }
            if !compact { commentComposer.padding(.top, 8) }
        }
    }

    /// Kommentarfeld: breit in der Karte, schmal unten fest (Ziel, Feld, Senden)
    @ViewBuilder private var commentComposer: some View {
        if let target = composerTitle { Text(target).ufFont(12.8, 600).foregroundStyle(UF.text2) }
        if compact {
            UFCompactComposerField(placeholder: "Kommentar schreiben …", text: $draft)
        } else {
            UFTextArea(placeholder: "Kommentar schreiben …", text: $draft, minHeight: 70)
        }
        HStack(spacing: 8) {
            UFButton(editing == nil ? "Senden" : "Speichern", icon: "check", kind: .primary, size: .small) { send() }
                .disabled(busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if composerTitle != nil {
                UFButton("Abbrechen", size: .small) { resetComposer() }
            }
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
                // Aktionen je Kommentar zurueckhaltend (ohne Rahmen), damit der Text fuehrt
                HStack(spacing: 4) {
                    UFButton("Antworten", kind: .ghost, size: .small) {
                        resetComposer()
                        replyTo = c
                    }
                    if c.isMine {
                        UFButton("Bearbeiten", kind: .ghost, size: .small) {
                            resetComposer()
                            editing = c
                            draft = c.text
                        }
                    } else {
                        UFButton("Melden", kind: .ghost, size: .small) { report(c) }
                    }
                    if c.isMine || solution.isOwn { UFButton("Löschen", kind: .danger, size: .small) { remove(c) } }
                }
                .padding(.leading, -8)                                     // Text der Geisterknoepfe fluchtet mit dem Kommentar
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
        do {
            let c = try await SolutionSharing.loadCommunity(solution.solutionID, service: service)
            images = c.images.compactMapValues { UIImage(data: $0.data) }
            content = c
            if let host = ActiveContainer.current?.host { localFile = await CommunityCourses.localFile(fingerprint: c.fingerprint, host: host) }
            if service.supportsDiscussion { comments = try await service.comments(solutionID: solution.solutionID) }
        } catch { self.error = CommunityTexts.message(error) }
    }

    private func act(_ op: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await op()
                comments = try await service.comments(solutionID: solution.solutionID)
                error = nil
            } catch { self.error = CommunityTexts.message(error) }
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

    private func remove(_ c: CommunityComment) { act { try await service.deleteComment(id: c.id) } }

    private func report(_ c: CommunityComment) { act { try await service.reportComment(id: c.id, reason: .other) } }

    private func toggleLike() {
        let next = !liked
        act {
            likes = try await service.setLiked(solutionID: solution.solutionID, next)
            liked = next
        }
    }
}

struct CommunityReaderPage: View {
    struct Mark: Identifiable {
        let number: Int
        let anchor: CommunityComment.Anchor
        var id: Int { number }
    }

    let page: SolutionPage
    let images: [String: UIImage]
    var marks: [Mark] = []
    var tapped: ((CommunityComment.Anchor) -> Void)?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit().overlay(Rectangle().stroke(UF.line))
                    .overlay {
                        GeometryReader { geo in
                            ZStack(alignment: .topLeading) {
                                Color.clear.contentShape(Rectangle())
                                    .onTapGesture { p in tapped?(.init(x: Self.clamped(p.x / geo.size.width), y: Self.clamped(p.y / geo.size.height))) }
                                ForEach(marks) { m in
                                    Text("\(m.number)").ufFont(11.84, 600).foregroundStyle(.white).frame(width: 20, height: 20)
                                        .background(Circle().fill(UF.accentText))
                                        .position(x: m.anchor.x * geo.size.width, y: m.anchor.y * geo.size.height)
                                }
                            }
                        }
                    }
                    .accessibilityLabel("Seite mit \(page.objects.count) Notizobjekten")
                    .accessibilityHint(tapped == nil ? "" : "Tippen kommentiert diese Stelle")
            } else {
                // Platz der Seite freihalten, solange das Bild entsteht (kein Springen)
                RoundedRectangle(cornerRadius: UF.rSm).fill(UF.surface2).aspectRatio(1 / 1.414, contentMode: .fit)
                    .overlay(ProgressView().controlSize(.small))
                    .accessibilityLabel("Seite wird geladen")
            }
        }
        .task(id: page.key) {
            let page = self.page, images = self.images
            image = await Task.detached(priority: .utility) { ImageBox(SolutionPreview.image(page, images: images, width: 860)) }.value.image
        }
    }

    static func clamped(_ v: Double) -> Double { v.isFinite ? min(1, max(0, v)) : 0 }

    private struct ImageBox: @unchecked Sendable {
        let image: UIImage
        init(_ i: UIImage) { image = i }
    }
}

// MARK: - Treffer zu einem Blatt (im Dokument)

struct CommunitySolutionsSheet: View {
    let fingerprint: String
    let service: CommunityService
    /// "Laden und anzeigen": derselbe Weg wie die Datei (`DocumentStore.importFromCommunity`)
    let importer: (String) async throws -> SolutionImportResult
    let onImported: (SolutionImportResult) -> Void
    let close: () -> Void

    @State private var items: [CommunitySolutionSummary]?
    @State private var error: String?
    @State private var busyID: String?
    @State private var reporting: CommunitySolutionSummary?
    @State private var blocking: CommunitySolutionSummary?
    @State private var withdrawing: CommunitySolutionSummary?
    @State private var discussing: CommunitySolutionSummary?
    @State private var notice: String?
    @Environment(\.ufCompact) private var shellCompact
    @Environment(\.ufLearnCompact) private var learnCompact

    /// schmal (iPhone): Knoepfe einer Loesung unter ihrem Namen, Rand 16 pt
    private var compact: Bool { UFCompactLearn.inSheet(shell: shellCompact, inherited: learnCompact) }

    var body: some View {
        NavigationStack {
            UFContent(maxWidth: 760, insets: EdgeInsets(top: 16, leading: compact ? 16 : 20, bottom: 32, trailing: compact ? 16 : 20)) {
                UFGate(.communityRead) { content }
            }
            .navigationTitle("Lösungen aus der Community")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig", action: close) } }
        }
        .task { await load() }
        .sheet(isPresented: Binding(get: { discussing != nil }, set: { if !$0 { discussing = nil } })) {
            if let s = discussing { CommunityReaderSheet(solution: s, service: service) { discussing = nil } }
        }
        .ufModal(isPresented: Binding(get: { reporting != nil }, set: { if !$0 { reporting = nil } })) {
            if let s = reporting {
                CommunityReportDialog(solution: s, service: service, done: { message in
                    reporting = nil
                    notice = message
                })
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

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            UFCard {
                Text("Lösungen anderer zu genau dieser PDF. „Laden und anzeigen“ legt sie als eigene, nicht bearbeitbare Ebene über deine PDF – deine Notizen bleiben unverändert.")
                    .ufFont(13.12).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
            }
            if let notice { CommunityNotice(text: notice, tone: .ok) }
            if let error { CommunityNotice(text: error) }
            UFCard(padded: false) {
                if let items {
                    if items.isEmpty {
                        UFEmpty(icon: "users", text: "Keine Lösungen aus der Community zu diesem Blatt.", small: true) {
                            UFButton("Erneut suchen", icon: "refresh", size: .small) { Task { await load(force: true) } }
                        }
                    } else {
                        VStack(spacing: 0) {
                            ForEach(items, id: \.solutionID) { s in
                                row(s)
                                if s.solutionID != items.last?.solutionID { Divider().overlay(UF.line) }
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 4)
                    }
                } else if error == nil {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Community wird durchsucht …").ufFont(14.5).foregroundStyle(UF.muted)
                    }
                    .padding(16)
                } else {
                    UFEmpty(icon: "alert", text: "Keine Verbindung zur Community.", small: true) {
                        UFButton("Erneut versuchen", icon: "refresh", size: .small) { Task { await load(force: true) } }
                    }
                }
            }
        }
    }

    @ViewBuilder private func row(_ s: CommunitySolutionSummary) -> some View {
        if compact {
            // schmal: Name und Zeile in voller Breite, darunter die Knoepfe (nebeneinander passten sie nicht)
            VStack(alignment: .leading, spacing: 6) {
                UFItemRow(rowTitle(s), sub: rowSub(s), leading: { UFIcon("users", size: 18).foregroundStyle(UF.muted) }, trailing: { EmptyView() })
                rowActions(s).padding(.leading, 30).padding(.bottom, 8)
            }
        } else {
            UFItemRow(rowTitle(s), sub: rowSub(s), leading: { UFIcon("users", size: 18).foregroundStyle(UF.muted) }, trailing: { rowActions(s) })
        }
    }

    private func rowTitle(_ s: CommunitySolutionSummary) -> String { ForeignSolutionLayer.label(displayName: s.displayName, createdAt: s.createdAt) }

    private func rowSub(_ s: CommunitySolutionSummary) -> String {
        let pages = s.pageCount == 1 ? "1 Seite" : "\(s.pageCount) Seiten"
        let who = s.isOwn ? "deine Veröffentlichung" : s.visibility.title
        return "\(pages) · \(who)\(service.supportsDiscussion ? " · \(s.likes) Likes · \(s.commentCount) Kommentare" : "")"
    }

    private func rowActions(_ s: CommunitySolutionSummary) -> some View {
                             HStack(spacing: 8) {
                                 UFButton(busyID == s.solutionID ? "Wird geladen …" : "Laden und anzeigen", icon: "download", kind: .primary, size: .small) {
                                     load(s)
                                 }
                                 .disabled(busyID != nil)
                                 if service.supportsDiscussion {
                                     UFButton("Kommentare", size: .small) { discussing = s }
                                 }
                                 Menu {
                                     if s.isOwn {
                                         Button(role: .destructive) { withdrawing = s } label: { Label("Zurückziehen", systemImage: "trash") }
                                     } else {
                                         Button { reporting = s } label: { Label("Melden …", systemImage: "flag") }
                                         Button(role: .destructive) { blocking = s } label: { Label("Nutzer blockieren …", systemImage: "hand.raised") }
                                     }
                                 } label: {
                                     UFIcon("more", size: 18).foregroundStyle(UF.text2).frame(width: 44, height: 44)    // Tippflaeche 44 pt
                                 }
                                 .accessibilityLabel("Mehr")
                             }
    }

    private func load(force: Bool = false) async {
        error = nil
        do {
            items = try await CommunityMatches.shared.load(fingerprint: fingerprint, service: service, force: force)
        } catch {
            self.error = CommunityTexts.message(error)
        }
    }

    private func load(_ s: CommunitySolutionSummary) {
        busyID = s.solutionID
        error = nil
        Task {
            defer { busyID = nil }
            do {
                let result = try await importer(s.solutionID)
                onImported(result)
                if case .shown = result { notice = "Lösung geladen – sie liegt jetzt unter „Ebenen“ über deiner PDF." }
            } catch {
                self.error = CommunityTexts.message(error)
            }
        }
    }

    private func block(_ s: CommunitySolutionSummary) {
        Task {
            do {
                try await service.block(owner: s.ownerRecordName)
                items?.removeAll { $0.ownerRecordName == s.ownerRecordName }
                await CommunityMatches.shared.invalidate()
                notice = "Nutzer blockiert."
            } catch {
                self.error = CommunityTexts.message(error)
            }
        }
    }

    private func withdraw(_ s: CommunitySolutionSummary) {
        Task {
            do {
                try await SolutionSharing.withdrawFromCommunity(s.solutionID, service: service)
                items?.removeAll { $0.solutionID == s.solutionID }
                notice = "Lösung zurückgezogen."
            } catch {
                self.error = CommunityTexts.message(error)
            }
        }
    }
}

/// Melden (App-Store-Richtlinie 1.2): Grund und optionale Notiz
struct CommunityReportDialog: View {
    let solution: CommunitySolutionSummary
    let service: CommunityService
    let done: (String?) -> Void
    @State private var reason: CommunityReportReason = .foreignMaterial
    @State private var note = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        UFDialog("Lösung melden", icon: "flag") {
            VStack(alignment: .leading, spacing: 9.6) {
                Text(CommunityTexts.reportNotice).ufFont(13.12).foregroundStyle(UF.text2)
                UFField("Grund") {
                    UFSelect(options: CommunityReportReason.allCases.map { ($0, $0.title) }, selection: $reason, fill: true)
                }
                UFField("Hinweis (optional)") { UFTextArea(placeholder: "Was ist das Problem?", text: $note, minHeight: 80) }
                if let error { CommunityNotice(text: error) }
            }
            .fixedSize(horizontal: false, vertical: true)
        } foot: {
            UFButton("Abbrechen") { done(nil) }
            UFButton(busy ? "Wird gesendet …" : "Melden", icon: "flag", kind: .primary) { send() }.disabled(busy)
        }
    }

    private func send() {
        busy = true
        Task {
            do {
                try await service.report(solutionID: solution.solutionID, reason: reason, note: note.isEmpty ? nil : note)
                done("Danke – die Lösung wurde gemeldet.")
            } catch {
                self.error = CommunityTexts.message(error)
                busy = false
            }
        }
    }
}

// MARK: - Moduldetail: Community nach Lehrwoche

struct CommunityModulePanel: View {
    /// Detailansicht des Moduls (`/api/modules/{id}`): Kurse und Name fuer die Kurs-Schluessel
    let module: JSONValue
    /// Dateien des Moduls (Titel → Dokument oeffnen) und Wochen (Beschriftung)
    let files: [JSONValue]
    let weeks: [JSONValue]
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var account: AccountStore
    @State private var items: [CommunitySolutionSummary]?
    @State private var error: String?

    private var service: CommunityService { SolutionSharing.community }

    var body: some View {
        UFGate(.communityRead) {
            VStack(alignment: .leading, spacing: 16) {
                UFCard {
                    UFCardHead("Lösungen aus der Community", icon: "users") {
                        UFButton("Aktualisieren", icon: "refresh", size: .small) { Task { await load() } }
                    }
                    Text("Geteilte Notizen zu diesem Modul, nach Lehrwoche. Tippe ein Blatt an, um zu sehen, wer dazu Notizen geteilt hat.")
                        .ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                    if let error { CommunityNotice(text: error).padding(.top, 8) }
                }
                if let items {
                    if items.isEmpty && CommunityChannel.skeleton(weeks: weeks).isEmpty {
                        UFCard { UFEmpty(icon: "users", text: "Noch keine Lösungen aus der Community zu diesem Modul.", small: true) }
                    } else {
                        // Kanal wie Studydrive, nach Lehrwoche (CommunityChannelView)
                        CommunityChannelView(service: service, solutions: Binding(get: { self.items ?? [] }, set: { self.items = $0 }),
                                             files: files, weeks: weeks)
                    }
                } else if error == nil {
                    // Laden: Platzhalter in Form eines Wochenblocks (Ueberschrift, zwei Zeilen)
                    UFCard {
                        VStack(alignment: .leading, spacing: 12) {
                            UFSkeleton().frame(width: 180, height: 18)
                            UFSkeleton().frame(height: 40)
                            UFSkeleton().frame(height: 40)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Lösungen werden geladen")
                    }
                }
            }
            .task(id: courseKeys) { await load() }
        }
    }

    /// Community-Schluessel des Moduls (Kurstitel und Modulname, eine Stelle: CommunityCourses)
    private var courseKeys: [String] {
        account.university.map { CommunityCourses.courseKeys(module: module, university: $0.rawValue) } ?? []
    }

    private func load() async {
        error = nil
        do {
            var all: [CommunitySolutionSummary] = []
            for key in courseKeys {
                all += try await service.findForCourse(courseKey: key)
            }
            var seen = Set<String>()
            items = all.filter { seen.insert($0.solutionID).inserted }
        } catch {
            self.error = CommunityTexts.message(error)
            if items == nil { items = [] }
        }
    }
}

// MARK: - Einstellungen: Pseudonym, Lerngruppen, Sperrliste

struct CommunitySettingsCard: View {
    @EnvironmentObject private var toast: UFToastCenter
    /// Lesen, Beitreten und Sperrliste in jedem Tarif; Pseudonym und Lerngruppen anlegen ab Plus (`.shareSolutions`)
    @ObservedObject var entitlements: Entitlements = .shared
    @Environment(\.ufShowPlans) private var showPlans
    @State private var plansSheet = false
    @State private var pseudonym = SolutionDisplayName.load()
    @State private var groups: [CommunityStudyGroup] = []
    @State private var blocked: [String] = []
    @State private var newGroupName = ""
    @State private var joinCode = ""
    @State private var error: String?
    @State private var showingCode: CommunityStudyGroup?
    @State private var leaving: CommunityStudyGroup?
    @State private var busy = false

    private var service: CommunityService { SolutionSharing.community }

    var body: some View {
        UFCard {
            UFCardHead("Community", icon: "users") {
                CommunityTexts.badge(service)
            }
            UFGate(.communityRead, entitlements: entitlements) {
                VStack(alignment: .leading, spacing: 0) {
                    if !service.isConnected {
                        Text(CommunityTexts.unavailableHint).ufFont(13.12).foregroundStyle(UF.warnText)
                            .fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
                    }
                    Text(CommunityTexts.privacy(service)).ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                    if let error { CommunityNotice(text: error).padding(.top, 8) }

                    sectionHead("Pseudonym")
                    if canShare {
                        HStack(spacing: 9.6) {
                            // Vorschau: so erscheint das Pseudonym bei anderen (feste Pastellfarbe)
                            CommunityAvatar(name: pseudonym.isEmpty ? "Anonym" : pseudonym, size: 36)
                            UFTextInput("Leer lassen = anonym", text: $pseudonym).frame(maxWidth: 260)
                            UFButton("Speichern", size: .small) {
                                let name = pseudonym.trimmingCharacters(in: .whitespacesAndNewlines)
                                pseudonym = name
                                SolutionDisplayName.save(name)
                                toast.show("Pseudonym gespeichert")
                            }
                        }
                        Text("Erscheint bei Lösungen, die du veröffentlichst. Nie dein echter Name.")
                            .ufFont(11.84).foregroundStyle(UF.muted).padding(.top, 6.4)
                    } else {
                        shareHint(CommunityTexts.pseudonymPlusHint)
                    }

                    sectionHead("Lerngruppen")
                    if groups.isEmpty {
                        Text("Du bist in keiner Lerngruppe. Lege eine an und gib den Code weiter, oder tritt mit einem Code bei.")
                            .ufFont(13.12).foregroundStyle(UF.muted)
                    }
                    ForEach(groups, id: \.code) { g in
                        UFItemRow(g.name, sub: "Code \(g.code)",
                                  leading: {
                                      UFIcon("users", size: 16).foregroundStyle(UF.accentText)
                                          .frame(width: 32, height: 32)
                                          .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(UF.accentSoft))
                                  },
                                  trailing: {
                                      HStack(spacing: 8) {
                                          UFButton("Code & QR", icon: "grid", size: .small) { showingCode = g }
                                          UFButton("Verlassen", kind: .danger, size: .small) { leaving = g }
                                      }
                                  })
                    }
                    UFFlexWrap(gap: 9.6) {
                        if canShare {
                            HStack(spacing: 8) {
                                UFTextInput("Name der neuen Lerngruppe", text: $newGroupName).frame(width: 220)
                                UFButton("Anlegen", icon: "plus", size: .small) { create() }.disabled(busy || !service.isConnected)
                            }
                        }
                        HStack(spacing: 8) {
                            UFTextInput("Beitrittscode", text: $joinCode).frame(width: 160)
                                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                            UFButton("Beitreten", icon: "log-out", size: .small) { join() }.disabled(busy || !service.isConnected)
                        }
                    }
                    .padding(.top, 8)
                    if !canShare { shareHint(CommunityTexts.createGroupPlusHint).padding(.top, 8) }

                    sectionHead("Sperrliste")
                    if blocked.isEmpty {
                        Text("Niemand blockiert. Blockieren kannst du bei einer Lösung unter „Mehr“.").ufFont(13.12).foregroundStyle(UF.muted)
                    }
                    ForEach(blocked, id: \.self) { owner in
                        UFItemRow(CommunityTexts.owner(owner), trailing: {
                            UFButton("Freigeben", size: .small) { unblock(owner) }.disabled(busy)
                        })
                    }
                }
                .task { await reload() }
            }
        }
        .sheet(item: $showingCode) { g in StudyGroupCodeSheet(group: g) { showingCode = nil } }
        .sheet(isPresented: $plansSheet) { UFPlanSheet(required: .plus, close: { plansSheet = false }) }
        .ufModal(isPresented: Binding(get: { leaving != nil }, set: { if !$0 { leaving = nil } })) {
            if let g = leaving {
                UFDialog("Lerngruppe verlassen", icon: "users") {
                    Text("Du siehst danach keine Lösungen dieser Lerngruppe mehr. Mit dem Code kannst du jederzeit wieder beitreten.")
                        .ufFont(13.12).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                } foot: {
                    UFButton("Abbrechen") { leaving = nil }
                    UFButton("Verlassen", kind: .danger) { leaving = nil; leave(g) }
                }
            }
        }
    }

    /// Unterabschnitt der Karte: eine Stufe unter dem Kartentitel (h3), getrennt durch eine Haarlinie – vorher hatten
    /// Karte und Abschnitte dieselbe Titelgroesse mit Symbol, die Hierarchie war flach
    private func sectionHead(_ title: String) -> some View {
        Text(title).ufFont(15.2, 650, em: -0.01).foregroundStyle(UF.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 16).padding(.bottom, 8)
            .overlay(alignment: .top) { Rectangle().fill(UF.line).frame(height: 1) }
            .padding(.top, 19.2)
            .accessibilityAddTraits(.isHeader)
    }

    /// Teilen (Pseudonym, Lerngruppe anlegen) im aktuellen Tarif erlaubt?
    private var canShare: Bool { entitlements.allows(.shareSolutions) }

    /// Hinweis an Stellen, an denen man schreiben wuerde: Schloss mit Tarif, Text; Tippen fuehrt zur Tarifwahl
    private func shareHint(_ text: String) -> some View {
        Button {
            if let showPlans { showPlans() } else { plansSheet = true }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                UFLockMark(access: entitlements.access(.shareSolutions))
                Text(text).ufFont(12.8).foregroundStyle(UF.muted).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
        .accessibilityLabel(text)
        .accessibilityHint("Öffnet die Tarifwahl.")
    }

    private func reload() async {
        groups = (try? await service.studyGroups()) ?? []
        guard service.isConnected else { return }
        do { blocked = try await service.blockedOwners() } catch { self.error = CommunityTexts.message(error) }
    }

    private func create() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let g = try await service.createStudyGroup(name: newGroupName)
                newGroupName = ""
                groups = (try? await service.studyGroups()) ?? groups + [g]
                showingCode = g
            } catch {
                self.error = CommunityTexts.message(error)
            }
        }
    }

    private func join() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let g = try await service.joinStudyGroup(code: joinCode)
                joinCode = ""
                groups = (try? await service.studyGroups()) ?? groups + [g]
                toast.show("Lerngruppe „\(g.name)“ beigetreten")
            } catch {
                self.error = CommunityTexts.message(error)
            }
        }
    }

    private func leave(_ g: CommunityStudyGroup) {
        Task {
            try? await service.leaveStudyGroup(code: g.code)
            groups = (try? await service.studyGroups()) ?? []
            await CommunityMatches.shared.invalidate()
        }
    }

    private func unblock(_ owner: String) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await service.unblock(owner: owner)
                blocked.removeAll { $0 == owner }
                await CommunityMatches.shared.invalidate()
            } catch {
                self.error = CommunityTexts.message(error)
            }
        }
    }
}

extension CommunityStudyGroup: Identifiable {
    public var id: String { code }
}

/// Beitrittscode und QR-Code einer Lerngruppe
struct StudyGroupCodeSheet: View {
    let group: CommunityStudyGroup
    let close: () -> Void

    var body: some View {
        NavigationStack {
            UFContent(maxWidth: 520, insets: EdgeInsets(top: 16, leading: 20, bottom: 32, trailing: 20)) {
                UFCard {
                    VStack(spacing: 14) {
                        Text(group.name).ufFont(17.6, 700).foregroundStyle(UF.text)
                        if let qr = Self.qrImage(CommunityJoinLink.url(code: group.code).absoluteString) {
                            Image(uiImage: qr).interpolation(.none).resizable().scaledToFit().frame(width: 220, height: 220)
                                .accessibilityLabel("QR-Code mit dem Beitrittscode \(group.code)")
                        }
                        Text(group.code).font(.system(size: 28, weight: .bold, design: .monospaced)).foregroundStyle(UF.text)
                            .textSelection(.enabled)
                        Text("Wer den Code kennt, kann beitreten und deine Lösungen mit Sichtbarkeit „Lerngruppe“ sehen. Gib ihn nur an deine Lerngruppe weiter.")
                            .ufFont(13.12).foregroundStyle(UF.muted).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        UFButton("Code kopieren", icon: "copy", size: .small) { UIPasteboard.general.string = group.code }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Beitrittscode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig", action: close) } }
        }
    }

    static func qrImage(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

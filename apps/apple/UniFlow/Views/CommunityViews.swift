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
    static let noCommunity = "Du bist noch in keiner Community. Tritt unter „Community“ dem Modul bei, dann kannst du hier teilen."
    static let privacyAccount = "Der Studora-Dienst bekommt das verschlüsselte Paket, Fingerabdruck, Seitenzahl, Titel und dein Pseudonym, dazu die Schlüssel deiner Kurse und die Fingerabdrücke deiner PDFs. Kurs-IDs und Beitrittscodes bleiben auf dem Gerät. Andere sehen nie deine E-Mail-Adresse. Lesen können die Lösung die Mitglieder der Community."
    static let unavailable = CommunityServiceError.unavailable.localizedDescription
    /// Einstellungen und Community-Seite ohne iCloud-Container: ehrlich, mit dem Weg, der bleibt
    static let unavailableHint = "Dieser Build hat keinen iCloud-Container (dafür braucht es das Apple Developer Program). Es wird nichts veröffentlicht und nichts gesucht. Lösungen teilst du weiterhin als verschlüsselte Datei – im Editor unter „Ebenen“."
    static let blockNotice = "Lösungen dieser Person erscheinen für dich nicht mehr. Die Sperrliste ist nur für dich sichtbar und lässt sich in den Einstellungen aufheben."
    static let reportNotice = "Die Meldung geht an die Moderation von Studora. Gemeldet wird nur die Lösung, nicht deine Apple-ID. Schreib keine persönlichen Daten in den Hinweis."
    /// Free: wo man schreiben wuerde, steht der Weg zu Plus (Lesen, Melden, Blockieren und Beitreten gehen ohne)
    static let pseudonymPlusHint = "Ein Pseudonym brauchst du erst zum Veröffentlichen eigener Lösungen – ab \(UFPlan.plus.name)."
    static let createGroupPlusHint = "Eigene Lerngruppen anlegen und Lösungen veröffentlichen kannst du ab \(UFPlan.plus.name). Beitreten geht in jedem Tarif."

    static func matches(_ n: Int) -> String {
        n == 1 ? "1 Lösung aus der Community zu diesem Blatt" : "\(n) Lösungen aus der Community zu diesem Blatt"
    }

    static func privacy(_ service: CommunityService) -> String { service.isAccountService ? privacyAccount : privacy }

    @MainActor @ViewBuilder static func badge(_ service: CommunityService) -> some View {
        if service.isConnected {
            UFBadge(service.isAccountService ? "Studora-Konto" : "CloudKit", tone: .ok)
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
}

// MARK: - Communities (je Modul und Lerngruppe)

/// Alle Module aus dem eigenen Abgleich und die Lerngruppen: beitreten, verlassen, Loesungen ansehen
struct CommunitySpacesCard: View {
    private var service: CommunityService { SolutionSharing.community }
    @State private var spaces: [CommunitySpace]?
    @State private var error: String?
    @State private var busy: String?
    @State private var open: CommunitySpace?

    var body: some View {
        UFCard {
            UFCardHead("Deine Communities", icon: "users")
            Text("Jedes Modul hat eine Community für Vorlesung, Übungen und Tutorien. Tritt bei, dann siehst und teilst du dort Lösungen.")
                .ufFont(13.12).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
            if let error { Text(error).ufFont(13.12, 600).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true) }
            if let spaces {
                if spaces.isEmpty { Text("Noch keine Module. Gleiche zuerst deine Hochschule ab.").ufFont(13.12).foregroundStyle(UF.muted) }
                ForEach(spaces) { s in
                    UFItemRow(s.name, sub: Self.detail(s),
                              leading: { UFIcon(s.kind == .group ? "users" : "book", size: 18).foregroundStyle(UF.muted) },
                              trailing: {
                                  HStack(spacing: 8) {
                                      if s.joined {
                                          UFButton("Öffnen", size: .small) { open = s }
                                          if s.kind == .course { UFButton("Verlassen", size: .small) { change(s, join: false) }.disabled(busy != nil) }
                                      } else {
                                          UFButton("Beitreten", icon: "plus", kind: .primary, size: .small) { change(s, join: true) }.disabled(busy != nil)
                                      }
                                  }
                              })
                }
            } else if error == nil {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.bottom, 16)
        .task { await reload() }
        .sheet(item: $open) { s in CommunitySpaceSheet(space: s, service: service) { open = nil } }
    }

    static func detail(_ s: CommunitySpace) -> String {
        var parts = [s.kind == .group ? "Lerngruppe" : "Modul"]
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

/// Loesungen einer Community; jede laesst sich ansehen, auch ohne die PDF
struct CommunitySpaceSheet: View {
    let space: CommunitySpace
    let service: CommunityService
    let close: () -> Void
    @State private var items: [CommunitySolutionSummary]?
    @State private var error: String?
    @State private var reading: CommunitySolutionSummary?
    @State private var reporting: CommunitySolutionSummary?
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            UFContent(maxWidth: 760, insets: EdgeInsets(top: 16, leading: 20, bottom: 32, trailing: 20)) {
                VStack(alignment: .leading, spacing: 12) {
                    if let notice { Text(notice).ufFont(13.12, 600).foregroundStyle(UF.ok) }
                    if let error { Text(error).ufFont(13.12, 600).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true) }
                    if let items {
                        if items.isEmpty { UFEmpty(icon: "users", text: "Noch keine Lösungen in dieser Community.", small: true) }
                        ForEach(items, id: \.solutionID) { s in row(s) }
                    } else if error == nil { ProgressView().controlSize(.small) }
                }
            }
            .navigationTitle(space.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig", action: close) } }
        }
        .task { await load() }
        .sheet(item: Binding(get: { reading.map(ReadingItem.init) }, set: { reading = $0?.solution })) { r in
            CommunityReaderSheet(solution: r.solution, service: service) { reading = nil }
        }
        .ufModal(isPresented: Binding(get: { reporting != nil }, set: { if !$0 { reporting = nil } })) {
            if let s = reporting {
                CommunityReportDialog(solution: s, service: service, done: { m in reporting = nil; notice = m })
            }
        }
    }

    private struct ReadingItem: Identifiable {
        let solution: CommunitySolutionSummary
        var id: String { solution.solutionID }
    }

    private func row(_ s: CommunitySolutionSummary) -> some View {
        UFItemRow(s.title.isEmpty ? "Lösung" : s.title, sub: detail(s),
                  leading: { UFIcon("layers", size: 18).foregroundStyle(UF.muted) },
                  trailing: {
                      HStack(spacing: 8) {
                          UFButton("Ansehen", size: .small) { reading = s }
                          if s.isOwn {
                              UFButton("Zurückziehen", kind: .danger, size: .small) { withdraw(s) }
                          } else {
                              UFButton("Melden", size: .small) { reporting = s }
                              UFButton("Blockieren", size: .small) { block(s) }
                          }
                      }
                  })
    }

    private func detail(_ s: CommunitySolutionSummary) -> String { Self.detail(s, account: service.isAccountService) }

    static func detail(_ s: CommunitySolutionSummary, account: Bool) -> String {
        var parts = ["Lösung von \(s.displayName.isEmpty ? "Anonym" : s.displayName)", ForeignSolutionLayer.date(s.createdAt)]
        if account {
            parts.append(s.likes == 1 ? "1 Like" : "\(s.likes) Likes")
            parts.append(s.commentCount == 1 ? "1 Kommentar" : "\(s.commentCount) Kommentare")
        }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        do { items = try await service.solutions(in: space); error = nil } catch { self.error = CommunityTexts.message(error) }
    }

    private func block(_ s: CommunitySolutionSummary) {
        Task {
            do {
                try await service.block(owner: s.ownerRecordName)
                items?.removeAll { $0.ownerRecordName == s.ownerRecordName }
                CommunityMatches.shared.invalidate()
                notice = "Nutzer blockiert."
            } catch { self.error = CommunityTexts.message(error) }
        }
    }

    private func withdraw(_ s: CommunitySolutionSummary) {
        Task {
            do {
                try await SolutionSharing.withdrawFromCommunity(s.solutionID, service: service)
                items?.removeAll { $0.solutionID == s.solutionID }
                notice = "Lösung zurückgezogen."
            } catch { self.error = CommunityTexts.message(error) }
        }
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

    var body: some View {
        NavigationStack {
            UFContent(maxWidth: 860, insets: EdgeInsets(top: 16, leading: 20, bottom: 32, trailing: 20)) {
                VStack(alignment: .leading, spacing: 16) {
                    if let error { Text(error).ufFont(13.12, 600).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true) }
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
                            CommunityReaderPage(page: page, images: images, marks: marks(page), tapped: service.isAccountService ? { anchor in
                                spot = (page.key, anchor)
                                replyTo = nil
                                editing = nil
                            } : nil)
                        }
                    } else if error == nil { ProgressView().controlSize(.small) }
                    if service.isAccountService { commentsCard }
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
            Text(CommunityTexts.commentsNotice).ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
            if comments.isEmpty { Text("Noch keine Kommentare.").ufFont(13.12).foregroundStyle(UF.muted) }
            ForEach(Array(comments.enumerated()), id: \.element.id) { i, c in commentRow(c, number: i + 1) }
            if let target = composerTitle { Text(target).ufFont(12.8, 600).foregroundStyle(UF.text2).padding(.top, 8) }
            UFTextArea(placeholder: "Kommentar schreiben …", text: $draft, minHeight: 70).padding(.top, 8)
            HStack(spacing: 8) {
                UFButton(editing == nil ? "Senden" : "Speichern", icon: "check", kind: .primary, size: .small) { send() }
                    .disabled(busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if composerTitle != nil {
                    UFButton("Abbrechen", size: .small) { resetComposer() }
                }
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
            Text(c.deleted ? "Kommentar gelöscht" : c.text).ufFont(14.5).foregroundStyle(c.deleted ? UF.muted : UF.text)
                .fixedSize(horizontal: false, vertical: true)
            if !c.deleted {
                HStack(spacing: 8) {
                    UFButton("Antworten", size: .small) {
                        resetComposer()
                        replyTo = c
                    }
                    if c.isMine {
                        UFButton("Bearbeiten", size: .small) {
                            resetComposer()
                            editing = c
                            draft = c.text
                        }
                    } else {
                        UFButton("Melden", size: .small) { report(c) }
                    }
                    if c.isMine || solution.isOwn { UFButton("Löschen", kind: .danger, size: .small) { remove(c) } }
                }
            }
        }
        .padding(.vertical, 6)
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
            if service.isAccountService { comments = try await service.comments(solutionID: solution.solutionID) }
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
            } else { ProgressView().controlSize(.small) }
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

    var body: some View {
        NavigationStack {
            UFContent(maxWidth: 760, insets: EdgeInsets(top: 16, leading: 20, bottom: 32, trailing: 20)) {
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
            if let notice { Text(notice).ufFont(13.12, 600).foregroundStyle(UF.ok) }
            if let error { Text(error).ufFont(13.12, 600).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true) }
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

    private func row(_ s: CommunitySolutionSummary) -> some View {
        let pages = s.pageCount == 1 ? "1 Seite" : "\(s.pageCount) Seiten"
        let who = s.isOwn ? "deine Veröffentlichung" : s.visibility.title
        return UFItemRow(ForeignSolutionLayer.label(displayName: s.displayName, createdAt: s.createdAt), sub: "\(pages) · \(who)\(service.isAccountService ? " · \(s.likes) Likes · \(s.commentCount) Kommentare" : "")",
                         leading: { UFIcon("users", size: 18).foregroundStyle(UF.muted) },
                         trailing: {
                             HStack(spacing: 8) {
                                 UFButton(busyID == s.solutionID ? "Wird geladen …" : "Laden und anzeigen", icon: "download", kind: .primary, size: .small) {
                                     load(s)
                                 }
                                 .disabled(busyID != nil)
                                 if service.isAccountService {
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
                                     UFIcon("more", size: 18).foregroundStyle(UF.text2).frame(width: 32, height: 32)
                                 }
                                 .accessibilityLabel("Mehr")
                             }
                         })
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
                if let error { Text(error).ufFont(13.12, 600).foregroundStyle(UF.bad) }
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
                    Text("Veröffentlichte Lösungen zu den Dateien dieses Moduls, nach Lehrwoche. Öffne das passende Blatt – dort liegt die Lösung unter „Ebenen“.")
                        .ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                    if let error { Text(error).ufFont(13.12, 600).foregroundStyle(UF.bad).padding(.top, 8).fixedSize(horizontal: false, vertical: true) }
                }
                if let items {
                    if items.isEmpty {
                        UFCard { UFEmpty(icon: "users", text: "Noch keine Lösungen aus der Community zu diesem Modul.", small: true) }
                    } else {
                        ForEach(CommunityRules.byWeek(items), id: \.week) { block in
                            UFCard {
                                Text(weekLabel(block.week)).ufFont(15.2, 650, em: -0.01).foregroundStyle(UF.text).padding(.vertical, 8)
                                VStack(spacing: 0) {
                                    ForEach(block.solutions, id: \.solutionID) { s in row(s) }
                                }
                            }
                        }
                    }
                } else if error == nil {
                    UFCard { UFSkeleton().frame(height: 120) }
                }
            }
            .task(id: courseKeys) { await load() }
        }
    }

    /// Community-Schluessel des Moduls (Kurstitel und Modulname, eine Stelle: CommunityCourses)
    private var courseKeys: [String] {
        account.university.map { CommunityCourses.courseKeys(module: module, university: $0.rawValue) } ?? []
    }

    private func weekLabel(_ week: Int) -> String {
        if week == 0 { return "Ohne Lehrwoche" }
        return weeks.first { $0.i("week") == week }?.s("label") ?? "Woche \(week)"
    }

    /// Datei des Moduls mit demselben Titel (so heisst das Blatt beim Absender)
    private func file(for s: CommunitySolutionSummary) -> JSONValue? {
        let t = s.title.lowercased()
        guard !t.isEmpty else { return nil }
        return files.first { ShareExport.cleanTitle($0.s("ai_title") ?? $0.s("title") ?? $0.s("name") ?? "").lowercased() == t }
    }

    private func row(_ s: CommunitySolutionSummary) -> some View {
        let pages = s.pageCount == 1 ? "1 Seite" : "\(s.pageCount) Seiten"
        let name = s.displayName.isEmpty ? "Anonym" : s.displayName
        let target = file(for: s)
        return UFItemRow(s.title.isEmpty ? "Lösung" : s.title, sub: "Lösung von \(name) · \(ForeignSolutionLayer.date(s.createdAt)) · \(pages) · \(s.isOwn ? "deine Veröffentlichung" : s.visibility.title)",
                         link: target != nil,
                         leading: { UFIcon("users", size: 18).foregroundStyle(UF.muted) },
                         trailing: {
                             if let id = target?.s("id") {
                                 UFButton("Blatt öffnen", icon: "file-text", size: .small) { router.go(.doc(id)) }
                             } else {
                                 Text("Blatt nicht in diesem Modul").ufFont(12.8).foregroundStyle(UF.muted)
                             }
                         })
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
                        Text(CommunityTexts.unavailableHint).ufFont(13.12).foregroundStyle(UF.warn)
                            .fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
                    }
                    Text(CommunityTexts.privacy(service)).ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                    if let error { Text(error).ufFont(13.12, 600).foregroundStyle(UF.bad).padding(.top, 8).fixedSize(horizontal: false, vertical: true) }

                    UFCardHead("Pseudonym", icon: "user").padding(.top, 16)
                    if canShare {
                        HStack(spacing: 9.6) {
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

                    UFCardHead("Lerngruppen", icon: "users").padding(.top, 16)
                    if groups.isEmpty {
                        Text("Du bist in keiner Lerngruppe. Lege eine an und gib den Code weiter, oder tritt mit einem Code bei.")
                            .ufFont(13.12).foregroundStyle(UF.muted)
                    }
                    ForEach(groups, id: \.code) { g in
                        UFItemRow(g.name, sub: "Code \(g.code)",
                                  leading: { UFIcon("users", size: 18).foregroundStyle(UF.muted) },
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

                    UFCardHead("Sperrliste", icon: "alert").padding(.top, 16)
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

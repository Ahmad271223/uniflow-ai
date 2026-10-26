import CoreImage.CIFilterBuiltins
import SwiftUI
import UniFlowCore

// Oberflaeche der Online-Community (docs/LOESUNGEN-TEILEN.md, Abschnitt 7): Treffer zu einem Blatt im Dokument
// (Laden und anzeigen, Melden, Blockieren, eigene zurueckziehen), Bereich "Community" im Moduldetail nach Lehrwoche,
// Einstellungen (Pseudonym, Lerngruppen mit Code/QR, Sperrliste). Alles nur mit Plus (UFGate(.community)) und nur,
// wenn der Build einen iCloud-Container hat (sonst "nicht verfügbar", nichts vorgetaeuscht).

/// Feste Texte (auch fuer Tests).
enum CommunityTexts {
    static let copyright = "In der Community erscheinen nur deine eigenen Notizen – kein Originalmaterial deiner Hochschule (Folien, Aufgabenstellungen, Skripte). Mit dem Veröffentlichen bestätigst du, dass alles von dir stammt."
    static let visibilityModule = "Sichtbar für alle an deiner Hochschule, die denselben Kurs in Stud.IP bzw. Learnweb haben oder ein Modul mit demselben Namen. Wer den Kurs nicht kennt, findet sie nicht – eine Bestätigung der Hochschule gibt es nicht."
    static let visibilityGroup = "Sichtbar nur für Mitglieder der gewählten Lerngruppe (wer den Beitrittscode kennt)."
    static let visibilityAnonymous = "Sichtbar für alle an deiner Hochschule, die dieselbe PDF haben – ohne Pseudonym."
    static let privacy = "Hochgeladen werden nur das verschlüsselte Paket, Fingerabdruck und Seitenzahl, Sichtbarkeit und dein Pseudonym – nie Apple-ID, Name, E-Mail, Matrikelnummer oder Kurs-ID. Öffnen kann die Lösung nur, wer dieselbe PDF hat."
    static let unavailable = CommunityServiceError.unavailable.localizedDescription
    /// Einstellungen und Community-Seite ohne iCloud-Container: ehrlich, mit dem Weg, der bleibt
    static let unavailableHint = "Dieser Build hat keinen iCloud-Container (dafür braucht es das Apple Developer Program). Es wird nichts veröffentlicht und nichts gesucht. Lösungen teilst du weiterhin als verschlüsselte Datei – im Editor unter „Ebenen“."
    static let blockNotice = "Lösungen dieser Person erscheinen für dich nicht mehr. Die Sperrliste ist nur für dich sichtbar und lässt sich in den Einstellungen aufheben."
    static let reportNotice = "Die Meldung geht an die Moderation von UniFlow. Gemeldet wird nur die Lösung, nicht deine Apple-ID. Schreib keine persönlichen Daten in den Hinweis."

    static func matches(_ n: Int) -> String {
        n == 1 ? "1 Lösung aus der Community zu diesem Blatt" : "\(n) Lösungen aus der Community zu diesem Blatt"
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
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            UFContent(maxWidth: 760, insets: EdgeInsets(top: 16, leading: 20, bottom: 32, trailing: 20)) {
                UFGate(.community) { content }
            }
            .navigationTitle("Lösungen aus der Community")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig", action: close) } }
        }
        .task { await load() }
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
        return UFItemRow(ForeignSolutionLayer.label(displayName: s.displayName, createdAt: s.createdAt), sub: "\(pages) · \(who)",
                         leading: { UFIcon("users", size: 18).foregroundStyle(UF.muted) },
                         trailing: {
                             HStack(spacing: 8) {
                                 UFButton(busyID == s.solutionID ? "Wird geladen …" : "Laden und anzeigen", icon: "download", kind: .primary, size: .small) {
                                     load(s)
                                 }
                                 .disabled(busyID != nil)
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
        UFGate(.community) {
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

    /// Kurs-Schluessel des Moduls (Kurs-IDs und Modulname, eine Stelle: CommunityCourses)
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
                service.isConnected ? UFBadge("CloudKit", tone: .ok) : UFBadge("nicht verfügbar", tone: .warn)
            }
            UFGate(.community) {
                VStack(alignment: .leading, spacing: 0) {
                    if !service.isConnected {
                        Text(CommunityTexts.unavailableHint).ufFont(13.12).foregroundStyle(UF.warn)
                            .fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
                    }
                    Text(CommunityTexts.privacy).ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                    if let error { Text(error).ufFont(13.12, 600).foregroundStyle(UF.bad).padding(.top, 8).fixedSize(horizontal: false, vertical: true) }

                    UFCardHead("Pseudonym", icon: "user").padding(.top, 16)
                    HStack(spacing: 9.6) {
                        UFTextInput("Leer lassen = anonym", text: $pseudonym).frame(maxWidth: 260)
                        UFButton("Speichern", size: .small) {
                            let name = pseudonym.trimmingCharacters(in: .whitespacesAndNewlines)
                            pseudonym = name
                            SolutionDisplayName.save(name)
                            toast.show("Pseudonym gespeichert")
                        }
                    }
                    Text("Erscheint bei Lösungen, die du mit Sichtbarkeit „Modul“ oder „Lerngruppe“ veröffentlichst. Nie dein echter Name.")
                        .ufFont(11.84).foregroundStyle(UF.muted).padding(.top, 6.4)

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
                        HStack(spacing: 8) {
                            UFTextInput("Name der neuen Lerngruppe", text: $newGroupName).frame(width: 220)
                            UFButton("Anlegen", icon: "plus", size: .small) { create() }.disabled(busy || !service.isConnected)
                        }
                        HStack(spacing: 8) {
                            UFTextInput("Beitrittscode", text: $joinCode).frame(width: 160)
                                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                            UFButton("Beitreten", icon: "log-out", size: .small) { join() }.disabled(busy || !service.isConnected)
                        }
                    }
                    .padding(.top, 8)

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

import SwiftUI
import UniFlowCore

// Korrekturvorschlag in der Community (Teil 2, 03.11.2026, Wunsch des Inhabers): "Korrektur vorschlagen" in der
// schwebenden Leiste der Notizen einer Person, Posteingang des Erstellers ("Deine Lösung „…“ hat einen Korrekturhinweis
// von … bekommen" mit Öffnen / Ignorieren) auf der Community-Seite und in "Deine Communities", Eintraege unter der
// Diskussion einer Loesung fuer alle Mitglieder und der Hinweis "N Korrekturhinweise" im eigenen Dokument. Die Loesung
// des Erstellers bleibt immer unveraendert; Ansehen legt die Korrektur im Editor als eigene Ebene darueber
// (`CorrectionLaunch.show`).

// MARK: - Texte und Regeln (testbar)

enum CorrectionTexts {
    static let action = "Korrektur vorschlagen"
    static let needsPDF = "Lade die PDF, um zu korrigieren."
    static let needsPDFToView = "Lade die PDF, um die Korrektur anzusehen."
    static let reported = "Danke – die Korrektur wurde gemeldet."
    static let deleted = "Deine Korrektur wurde zurückgenommen."
    static let sectionTitle = "Korrekturvorschläge"
    static let sectionNotice = "Korrekturen ändern die Lösung nicht. Mit „Ansehen“ liegen sie in deiner PDF über der Lösung."

    static func strokes(_ n: Int) -> String { n == 1 ? "1 Markierung" : "\(n) Markierungen" }
    static func notes(_ n: Int) -> String { n == 1 ? "1 Randnotiz" : "\(n) Randnotizen" }
    /// "3 Markierungen · 1 Randnotiz"
    static func summary(_ c: CommunityCorrection) -> String { "\(strokes(c.strokeCount)) · \(notes(c.noteCount))" }

    /// "Korrekturvorschlag von Ben"
    static func entryTitle(_ c: CommunityCorrection) -> String { "Korrekturvorschlag von \(c.displayName)" }

    /// "Deine Lösung „Blatt 3“ hat einen Korrekturhinweis von Ben bekommen" (ohne Titel wie `inboxMessage`)
    static func inbox(_ c: CommunityCorrection, title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return c.inboxMessage }
        return "Deine Lösung „\(t)“ hat einen Korrekturhinweis von \(c.displayName) bekommen"
    }

    /// Hinweis im eigenen Dokument
    static func editorHint(_ n: Int) -> String { n == 1 ? "1 Korrekturhinweis zu deiner Lösung" : "\(n) Korrekturhinweise zu deiner Lösung" }

    /// Reiter "Diskussion (N)": Kommentare und Korrekturen zusammen
    static func discussionTab(comments: Int, corrections: Int) -> String { "Diskussion (\(comments + corrections))" }
}

/// Was die Leiste unter fremden Notizen zu "Korrektur vorschlagen" anbietet
enum CorrectionOffer: Equatable {
    /// eigene Notizen oder Dienst ohne Korrekturen: kein Knopf
    case hidden
    /// Tarif ohne Teilen: Knopf oeffnet die Sperrkarte
    case locked
    /// eigene PDF wird noch gesucht
    case checking
    /// PDF fehlt auf dem Geraet: Knopf zeigt "Lade die PDF, um zu korrigieren."
    case needsPDF
    /// eigene Datei zur PDF: Korrektur-Modus im Dokument
    case ready(fileID: String)

    /// `localFile`: nil = noch nicht gesucht, .some(nil) = keine eigene Datei
    static func resolve(_ s: CommunitySolutionSummary, supportsCorrections: Bool, access: UFAccess, localFile: String??) -> CorrectionOffer {
        guard supportsCorrections, !s.isOwn else { return .hidden }
        switch access {
        case .allowed: break
        case .locked: return .locked
        case .comingSoon: return .hidden
        }
        guard let lookup = localFile else { return .checking }
        guard let id = lookup else { return .needsPDF }
        return .ready(fileID: id)
    }
}

// MARK: - Posteingang des Erstellers

/// Offener Korrekturhinweis an eine eigene Loesung, mit Titel und Fingerabdruck der Loesung (soweit bekannt)
struct CorrectionInboxItem: Identifiable, Equatable {
    let correction: CommunityCorrection
    let title: String
    let fingerprint: String?

    var id: String { correction.id }
    var message: String { CorrectionTexts.inbox(correction, title: title) }
}

enum CorrectionInbox {
    /// Offene Hinweise (an mich, nicht von mir, nicht ignoriert); Titel und Fingerabdruck aus den bekannten Loesungen
    /// der Community bzw. den eigenen geteilten Loesungen. `only`: nur diese Ziel-Loesungen (z. B. die einer Community)
    static func items(_ corrections: [CommunityCorrection], known: [CommunitySolutionSummary] = [], shared: [SolutionLibrary.SharedEntry] = [],
                      only: Set<String>? = nil) -> [CorrectionInboxItem] {
        CommunityCorrections.openInbox(corrections).compactMap { c in
            let sid = c.targetSolutionID.lowercased()
            if let only, !only.contains(sid) { return nil }
            let k = known.first { $0.solutionID.lowercased() == sid }
            let e = shared.first { $0.solutionID.lowercased() == sid }
            let title = [k?.title, e?.title].compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
            let fingerprint = [k?.fingerprint, e?.fingerprint].compactMap { $0 }.first { !$0.isEmpty }
            return CorrectionInboxItem(correction: c, title: title, fingerprint: fingerprint)
        }
    }

    /// Eigene Loesungen (Kennung beim Dienst) zu einer PDF
    static func solutionIDs(fingerprint: String, known: [CommunitySolutionSummary], shared: [SolutionLibrary.SharedEntry]) -> Set<String> {
        guard !fingerprint.isEmpty else { return [] }
        return Set(known.filter { $0.isOwn && $0.fingerprint == fingerprint }.map { $0.solutionID.lowercased() }
                   + shared.filter { $0.fingerprint == fingerprint }.map { $0.solutionID.lowercased() })
    }
}

/// Posteingang laden, oeffnen und ignorieren (fuer die Community-Seite und "Deine Communities")
@MainActor
final class CorrectionInboxModel: ObservableObject {
    @Published private(set) var items: [CorrectionInboxItem] = []
    @Published var notice: String?
    @Published private(set) var busy: String?
    let service: CommunityService
    let localFile: (String) async -> String?
    let shared: () -> [SolutionLibrary.SharedEntry]

    init(service: CommunityService, localFile: ((String) async -> String?)? = nil,
         shared: @escaping () -> [SolutionLibrary.SharedEntry] = { SolutionSharing.library.sharedEntries() }) {
        self.service = service
        self.localFile = localFile ?? { await CorrectionLaunch.localFile(fingerprint: $0) }
        self.shared = shared
    }

    func load(known: [CommunitySolutionSummary] = [], only: Set<String>? = nil) async {
        guard service.supportsCorrections else { items = []; return }
        // ohne Netz bleibt der letzte Stand stehen (ein Posteingang ist kein Fehlerort)
        guard let all = try? await service.correctionsForMyOwnSolutions() else { return }
        items = CorrectionInbox.items(all, known: known, shared: shared(), only: only)
    }

    /// Nur auf diesem Geraet; der Absender erfaehrt davon nichts
    func ignore(_ item: CorrectionInboxItem, reduceMotion: Bool = false) {
        service.setCorrectionStatus(.ignored, id: item.id)
        withAnimation(UFMotion.animation(reduce: reduceMotion)) { items.removeAll { $0.id == item.id } }
    }

    /// Im eigenen Dokument ueber den eigenen Notizen zeigen; ohne die PDF ein kurzer Hinweis
    func open(_ item: CorrectionInboxItem, router: UFRouter) async {
        busy = item.id
        defer { busy = nil }
        var print = item.fingerprint
        if print == nil { print = try? await service.download(solutionID: item.correction.targetSolutionID).header.fingerprint }
        guard let print, !print.isEmpty, let file = await localFile(print) else {
            notice = CorrectionTexts.needsPDFToView
            return
        }
        notice = nil
        CorrectionLaunch.shared.show(item.correction, fileID: file, router: router)
    }
}

/// Ruhige Hinweise des Posteingangs, je offener Korrektur einer
struct CorrectionInboxList: View {
    @ObservedObject var model: CorrectionInboxModel
    @EnvironmentObject private var router: UFRouter
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice = model.notice { CommunityNotice(text: notice, tone: .info) }
            ForEach(model.items) { item in
                CorrectionInboxBanner(item: item, busy: model.busy == item.id,
                                      open: { Task { await model.open(item, router: router) } },
                                      ignore: { model.ignore(item, reduceMotion: reduce) })
                    .transition(.opacity)
            }
        }
        .accessibilityIdentifier("correction.inbox")
    }
}

/// Ein Hinweis: Kreis der Person, Satz, kurz was markiert ist, Öffnen und Ignorieren
struct CorrectionInboxBanner: View {
    let item: CorrectionInboxItem
    var busy = false
    let open: () -> Void
    let ignore: () -> Void

    var body: some View {
        let c = item.correction
        HStack(alignment: .top, spacing: 12) {
            CommunityAvatar(name: c.displayName, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.message).ufFont(14.5, 600, lh: 1.4).foregroundStyle(UF.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(CorrectionTexts.summary(c) + (c.note.isEmpty ? "" : " · „\(c.note)“"))
                    .ufFont(12.8).foregroundStyle(UF.text2).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                UFFlexWrap(gap: 8) {
                    CorrectionPill(title: busy ? "Wird geöffnet …" : "Öffnen", icon: "file-text", tone: .primary,
                                   id: "correction.inbox.open.\(c.id)", action: open)
                        .disabled(busy)
                    CorrectionPill(title: "Ignorieren", icon: "x", tone: .plain, id: "correction.inbox.ignore.\(c.id)", action: ignore)
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: UF.rLg, style: .continuous).fill(CommunityTint.wash(CommunityPalette.peach.solid, 0.10)))
        .overlay(RoundedRectangle(cornerRadius: UF.rLg, style: .continuous).strokeBorder(Color.mix(CommunityPalette.peach.solid, 0.3, UF.line), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.message)
        .accessibilityIdentifier("correction.inbox.\(c.id)")
    }
}

// MARK: - Unter der Diskussion einer Loesung

/// Korrekturvorschlag als eigener Eintrag (anders als ein Kommentar: Pfirsichflaeche, Stift, Zahlen statt Text)
struct CorrectionEntryRow: View {
    let correction: CommunityCorrection
    var busy = false
    let view: () -> Void
    var delete: (() -> Void)?
    var report: (() -> Void)?

    private var label: String {
        var parts = [CorrectionTexts.entryTitle(correction), ForeignSolutionLayer.date(correction.createdAt), CorrectionTexts.summary(correction)]
        if !correction.note.isEmpty { parts.append(correction.note) }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        let pair = CommunityPalette.peach
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    CommunityAvatar(name: correction.displayName, size: 32, own: correction.isMine)
                    UFIcon("pen", size: 10).foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(pair.solid))
                        .overlay(Circle().strokeBorder(UF.surface, lineWidth: 1.5))
                        .offset(x: 5, y: 5)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(CorrectionTexts.entryTitle(correction) + (correction.isMine ? " (du)" : ""))
                            .ufFont(13.6, 650).foregroundStyle(pair.fg).lineLimit(2)
                        Text(ForeignSolutionLayer.date(correction.createdAt)).ufFont(11.84).foregroundStyle(UF.muted).lineLimit(1)
                    }
                    Text(CorrectionTexts.summary(correction)).ufFont(12.8, 550).foregroundStyle(UF.text2)
                    if !correction.note.isEmpty {
                        Text(correction.note).ufFont(14.08, lh: 1.5).foregroundStyle(UF.text)
                            .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            UFFlexWrap(gap: 6) {
                CorrectionPill(title: "Ansehen", icon: "layers", tone: .primary, id: "correction.entry.view.\(correction.id)", action: view)
                if let delete {
                    CorrectionPill(title: "Löschen", icon: "trash", tone: .danger, id: "correction.entry.delete.\(correction.id)", action: delete)
                }
                if let report {
                    CorrectionPill(title: "Melden", icon: "flag", tone: .plain, id: "correction.entry.report.\(correction.id)", action: report)
                }
            }
            .disabled(busy)
            .padding(.leading, 42)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: UF.r, style: .continuous).fill(CommunityTint.wash(pair.solid, 0.09)))
        .overlay(RoundedRectangle(cornerRadius: UF.r, style: .continuous).strokeBorder(Color.mix(pair.solid, 0.28, UF.line), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("correction.entry.\(correction.id)")
    }
}

/// Knopf als Kapsel: sichtbar kompakt, Tippflaeche 44 pt, Schrift folgt Dynamic Type (`ufFont`)
struct CorrectionPill: View {
    enum Tone { case primary, plain, danger }
    let title: String
    var icon: String?
    var tone: Tone = .plain
    let id: String
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { UFIcon(icon, size: 13) }
                Text(title).lineLimit(1)
            }
            .ufFont(13.12, 600)
            .foregroundStyle(tone == .primary ? Color.white : tone == .danger ? UF.badText : UF.text)
            .padding(.horizontal, 13).frame(minHeight: 32)
            .background(Capsule().fill(tone == .primary ? UF.accentFill : UF.surface))
            .overlay(Capsule().strokeBorder(tone == .primary ? Color.clear : (tone == .danger ? UF.bad.opacity(0.45) : UF.line), lineWidth: 1))
            .opacity(enabled ? 1 : 0.55)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(UFPressStyle(scale: 0.96))
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }
}

// MARK: - Im eigenen Dokument

/// Hinweis oben im Dokument: Korrekturhinweise zur eigenen geteilten Loesung dieser PDF
struct OwnCorrectionsHint: View {
    let corrections: [CommunityCorrection]
    let open: (CommunityCorrection) -> Void
    let dismiss: () -> Void

    private var names: String {
        var seen = Set<String>()
        return corrections.map(\.displayName).filter { seen.insert($0).inserted }.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.bubble").foregroundStyle(UF.warn).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(CorrectionTexts.editorHint(corrections.count)).font(.caption).bold()
                Text("von \(names) · deine Notizen bleiben unverändert").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if corrections.count == 1, let c = corrections.first {
                Button("Öffnen") { open(c) }.buttonStyle(.borderedProminent).controlSize(.small)
                    .accessibilityIdentifier("ownCorrections.open")
            } else {
                Menu {
                    ForEach(corrections) { c in
                        Button("\(c.displayName) · \(CorrectionTexts.summary(c))") { open(c) }
                    }
                } label: { Text("Öffnen") }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .accessibilityIdentifier("ownCorrections.open")
            }
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.bordered).controlSize(.small)
                .accessibilityLabel("Hinweis ausblenden")
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(UF.warn.opacity(0.6), lineWidth: 1))
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ownCorrections")
    }
}

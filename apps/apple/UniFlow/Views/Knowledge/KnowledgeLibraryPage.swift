import SwiftUI
import UniformTypeIdentifiers
import UniFlowCore

// Seite "Wissensbibliothek" (#/wissen, 20.11.2026): Fach -> Semester/Rolle -> Einheit -> Dateien. Der aktuelle
// Semesterordner (`_aeltere-PC-Version`, WiSe 2026/27) steht vorn. Kopfzeile je Einheit: Quellen, Typ, Loesungsstatus
// ("KI-Lösung, ungeprüft" deutlich), [sic]-Hinweis, Verweise auf gleiche Seiten anderer Einheiten. `_pruefung.py` nur
// als Hinweis "maschinell nachgeprüft", nie gezeigt oder ausgefuehrt.

struct KnowledgeLibraryPage: View {
    let subject: String?
    let unit: String?
    let file: String?
    let anchor: String?
    @AppStorage(KnowledgeLibrarySetting.key) private var enabled = false
    @ObservedObject private var center = KnowledgeLibraryCenter.shared
    @EnvironmentObject private var router: UFRouter

    var body: some View {
        Group {
            if !enabled {
                UFContent(maxWidth: 960) {
                    UFPageHead("Wissensbibliothek")
                    UFCard {
                        UFEmpty(icon: "bookmark", text: "Die Wissensbibliothek ist ausgeschaltet. Einschalten unter Einstellungen → Erweitert.") {
                            UFButton("Einstellungen", icon: "settings", size: .small) { router.go(.settings(tab: SettingsArea.advanced.rawValue)) }
                        }
                    }
                }
            } else if let lib = center.current {
                if let key = unit, let u = lib.catalog.unit(key: key) {
                    KnowledgeUnitView(library: lib, unit: u, initialFile: file, anchor: anchor).id(u.key + "|" + (file ?? "") + "|" + (anchor ?? ""))
                } else if let s = subject, let subj = lib.catalog.subject(s) {
                    KnowledgeSubjectView(library: lib, subject: subj).id(subj.folder)
                } else {
                    KnowledgeHomeView(library: lib)
                }
            } else if center.phase == .loading {
                UFContent(maxWidth: 960) { UFSkeleton().frame(width: 280, height: 28).padding(.bottom, 16); UFSkeleton().frame(height: 260) }
            } else {
                KnowledgeImportPage()
            }
        }
        .task { await center.ensureLoaded() }
        .accessibilityIdentifier("knowledge.page")
    }
}

// MARK: - Einlesen

/// Leere Bibliothek: worum es geht und wie man sie einliest
private struct KnowledgeImportPage: View {
    @ObservedObject private var center = KnowledgeLibraryCenter.shared

    var body: some View {
        UFContent(maxWidth: 960) {
            UFPageHead("Wissensbibliothek", sub: "Deine eigene Bibliothek mit Erklärungen und Lösungen, nur auf diesem Gerät.")
            UFCard {
                UFCardHead("Bibliothek einlesen", icon: "download")
                Text(KnowledgeTexts.importHelp)
                    .ufFont(13.6).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                KnowledgeImportButtons().padding(.top, 10)
                KnowledgeMessage().padding(.top, 8)
            }
        }
    }
}

enum KnowledgeTexts {
    static let importHelp = UFDevice.adapt("""
    Wähle den Ordner „uniflow-wissensbibliothek“ (mit katalog.json) oder eine ZIP-Datei davon. StudiNow kopiert die \
    Erklärungen und Lösungen in den Speicher dieses iPads. Nichts davon wird hochgeladen, geteilt oder an eine KI \
    geschickt. Prüfskripte (_pruefung.py) werden nicht kopiert und nie ausgeführt.
    """)
    static let privacy = "Nur auf diesem Gerät. Wird nicht hochgeladen, nicht geteilt und nicht an eine KI geschickt."
    static let kiWarning = "Für diese Einheit gibt es (teilweise) keine offizielle Lösung: Die Lösung hat eine KI erstellt und sie ist nicht mit einer Musterlösung geprüft."
}

/// Knoepfe "Ordner wählen", "ZIP wählen", "Neu einlesen" (gemerkter Ordner) und nach "ist aktuell" "Trotzdem ersetzen"
struct KnowledgeImportButtons: View {
    @ObservedObject private var center = KnowledgeLibraryCenter.shared
    @State private var pickFolder = false
    @State private var pickZip = false
    /// zuletzt gewaehlte Quelle (fuer "Trotzdem ersetzen")
    @State private var last: URL?
    @State private var offerForce = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            UFFlexWrap(gap: 8) {
                UFButton("Ordner wählen", icon: "folder", kind: center.library == nil ? .primary : .normal, size: .small) { pickFolder = true }
                    .accessibilityIdentifier("knowledge.pickFolder")
                UFButton("ZIP wählen", icon: "download", size: .small) { pickZip = true }
                    .accessibilityIdentifier("knowledge.pickZip")
                if center.hasRememberedSource {
                    UFButton("Neu einlesen", icon: "refresh", size: .small) { Task { _ = await center.reimportRemembered() } }
                        .accessibilityIdentifier("knowledge.reimport")
                }
                if offerForce, let last {
                    UFButton("Trotzdem ersetzen", icon: "rotate", kind: .ghost, size: .small) { run(last, force: true) }
                        .accessibilityIdentifier("knowledge.force")
                }
            }
            .disabled(isImporting)
            if case .importing(let done, let total) = center.phase {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(total > 0 ? "Wird eingelesen … \(done) von \(total) Dateien" : "Wird eingelesen …")
                        .ufFont(12.8).foregroundStyle(UF.muted)
                }
            }
        }
        .background {
            Color.clear.fileImporter(isPresented: $pickFolder, allowedContentTypes: [.folder]) { r in
                if case .success(let url) = r { run(url, force: false) }
            }
        }
        .background {
            Color.clear.fileImporter(isPresented: $pickZip, allowedContentTypes: [.zip]) { r in
                if case .success(let url) = r { run(url, force: false) }
            }
        }
    }

    private var isImporting: Bool { if case .importing = center.phase { return true }; return false }

    private func run(_ url: URL, force: Bool) {
        last = url
        offerForce = false
        Task {
            let before = center.library?.manifest.importedAt
            _ = await center.importFrom(url, force: force)
            // nichts eingelesen (gleicher oder aelterer Stand): "Trotzdem ersetzen" anbieten
            offerForce = center.library?.manifest.importedAt == before && center.library != nil
        }
    }
}

/// Meldung des letzten Einlesens
struct KnowledgeMessage: View {
    @ObservedObject private var center = KnowledgeLibraryCenter.shared

    var body: some View {
        if let m = center.message {
            Text(m).ufFont(12.8, 550).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("knowledge.message")
        }
    }
}

// MARK: - Startseite: Faecher

private struct KnowledgeHomeView: View {
    let library: KnowledgeLibrary
    @EnvironmentObject private var router: UFRouter

    var body: some View {
        UFContent(maxWidth: 1100) {
            UFPageHead("Wissensbibliothek", sub: KnowledgeFormat.standLine(library.manifest))
            UFCard {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(library.catalog.subjects) { s in
                        Button { router.go(.knowledge(subject: s.folder)) } label: {
                            UFItemRow(library.title(of: s), sub: KnowledgeFormat.subjectLine(s, library: library), link: true, wraps: true) {
                                UFIcon("book", size: 18).foregroundStyle(UF.text2)
                            } trailing: {
                                let ki = s.units.filter { library.summary($0).marks.kiUnchecked }.count
                                if ki > 0 { UFBadge("\(ki) KI ungeprüft", tone: .bad) }
                                Image(systemName: "chevron.right").foregroundStyle(UF.muted)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("knowledge.subject.\(s.folder)")
                        if s.id != library.catalog.subjects.last?.id { Rectangle().fill(UF.line).frame(height: 1) }
                    }
                }
            }
            UFCard {
                UFCardHead("Bibliothek aktualisieren", icon: "refresh")
                Text(KnowledgeTexts.privacy).ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                KnowledgeImportButtons().padding(.top, 8)
                KnowledgeMessage().padding(.top, 6)
            }
            .padding(.top, 16)
        }
    }
}

enum KnowledgeFormat {
    static func standLine(_ m: KnowledgeImportManifest) -> String {
        "Stand \(UFFmt.dateDE(m.stand)) · \(m.subjects) Fächer · \(m.units) Einheiten · nur auf diesem Gerät"
    }

    static func subjectLine(_ s: KnowledgeSubject, library: KnowledgeLibrary) -> String {
        let current = s.units.filter(\.isCurrentSemester).count
        let semesters = Set(s.units.map(\.semester)).count
        var parts = ["\(s.units.count) Einheiten", "\(semesters) Semester"]
        if current > 0 { parts.append("\(current) im aktuellen Semester") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Fach: Semester, Rollen, Einheiten

private struct KnowledgeSubjectView: View {
    let library: KnowledgeLibrary
    let subject: KnowledgeSubject
    @EnvironmentObject private var router: UFRouter
    @State private var showOverview = false

    var body: some View {
        UFContent(maxWidth: 1100) {
            UFPageHead(library.title(of: subject), sub: KnowledgeFormat.subjectLine(subject, library: library)) {
                UFButton("Alle Fächer", icon: "bookmark", size: .small) { router.go(.knowledge()) }
            }
            if let overview = library.subjectOverview(subject) {
                UFCard {
                    Button { showOverview.toggle() } label: {
                        HStack {
                            UFCardHead("Fachüberblick", icon: "info")
                            Image(systemName: showOverview ? "chevron.up" : "chevron.down").foregroundStyle(UF.muted)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showOverview {
                        AIMarkdownText(KnowledgeDocument.parse(overview).body, size: 14, formulasOnly: true).padding(.top, 6)
                    }
                }
                .padding(.bottom, 16)
            }
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(subject.semesters) { sem in
                    UFCard {
                        HStack(spacing: 8) {
                            Text(sem.label).ufFont(17, 700).foregroundStyle(UF.text)
                            if sem.isCurrent { UFBadge("aktuell", tone: .ok) }
                            Spacer(minLength: 0)
                            Text("\(sem.unitCount) Einheiten").ufFont(12.8).foregroundStyle(UF.muted)
                        }
                        ForEach(sem.roles) { role in
                            Text(role.label.uppercased(with: Locale(identifier: "de_DE")))
                                .ufFont(11.5, 650, em: 0.04).foregroundStyle(UF.muted)
                                .padding(.top, 10)
                            ForEach(role.units) { u in
                                Button { router.go(.knowledge(unit: u.key)) } label: {
                                    KnowledgeUnitRow(unit: u, summary: library.summary(u))
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("knowledge.unit.\(u.id)")
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct KnowledgeUnitRow: View {
    let unit: KnowledgeUnit
    let summary: KnowledgeUnitSummary

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(unit.id).ufFont(12.8, 650).foregroundStyle(UF.accentText).monospacedDigit()
                .frame(minWidth: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(unit.shortTitle).ufFont(14.2, 500).foregroundStyle(UF.text)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                KnowledgeBadges(marks: summary.marks, checked: unit.hasCheckScript, compact: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(UF.muted).padding(.top, 3)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// Status-Abzeichen aus den Markierungen
struct KnowledgeBadges: View {
    let marks: KnowledgeMarks
    var checked = false
    var compact = false

    var body: some View {
        UFFlexWrap(gap: 6) {
            if marks.kiUnchecked { UFBadge("KI-Lösung, ungeprüft", tone: .bad, icon: "alert").accessibilityIdentifier("knowledge.badge.ki") }
            if marks.independent { UFBadge("unabhängig gelöst", tone: .ok, icon: "check") }
            if marks.recomputed { UFBadge("nachgerechnet", tone: .info) }
            if marks.sic > 0 { UFBadge(compact ? "[sic] \(marks.sic)" : "[sic] \(marks.sic)× Fehler der Vorlage", tone: .warn) }
            if checked && !compact { UFBadge("maschinell nachgeprüft", tone: .neutral, icon: "check") }
            if !compact && !marks.links.isEmpty { UFBadge("\(marks.links.count) Verweise", tone: .neutral, icon: "layers") }
        }
    }
}

// MARK: - Einheit: Kopf, Dateien, Inhalt

struct KnowledgeUnitView: View {
    let library: KnowledgeLibrary
    let unit: KnowledgeUnit
    let initialFile: String?
    let anchor: String?
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufCompact) private var compact
    @State private var file: String = ""
    @State private var doc: KnowledgeDocument?
    @State private var plain: String?
    @State private var missing = false
    @State private var target: Int?
    @State private var showSources = false
    /// Sprungziel nur beim ersten Laden anwenden (nicht bei jedem Reiterwechsel)
    @State private var anchorApplied = false

    private var summary: KnowledgeUnitSummary { library.summary(unit) }
    private var files: [String] { unit.visibleFiles }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    header.id(-1)
                    fileTabs
                    if missing {
                        UFCard { UFEmpty(icon: "alert", text: "Diese Datei fehlt in der eingelesenen Bibliothek.", small: true) }
                    } else if let plain {
                        ScrollView(.horizontal) {
                            Text(plain).font(.system(size: 13, design: .monospaced)).foregroundStyle(UF.text).textSelection(.enabled)
                                .padding(12)
                        }
                        .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UF.surface2))
                    } else if let doc {
                        if let fm = doc.frontMatter { KnowledgeFileHead(frontMatter: fm) }
                        ForEach(doc.sections) { s in
                            KnowledgeSectionView(section: s, library: library, unit: unit, highlighted: s.index == target)
                                .id(s.index)
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                }
                .padding(.horizontal, compact ? 16 : 25.6)
                .padding(.top, compact ? 16 : 22.4)
                .padding(.bottom, 48)
                .frame(maxWidth: UFDevice.pageWidth(1000), alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(UF.bg)
            .task(id: file) {
                if file.isEmpty { file = await startFile(); return }
                await load(file)
                if let t = target {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    withAnimation(UF.transition) { proxy.scrollTo(t, anchor: .top) }
                }
            }
        }
        .accessibilityIdentifier("knowledge.unit")
    }

    // Kopf: Fach, Semester, Rolle, Titel, Status, Quellen, Typ, Verweise
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            UFFlexWrap(gap: 6) {
                Button { router.go(.knowledge(subject: unit.subject)) } label: {
                    Text(library.catalog.subject(unit.subject).map { library.title(of: $0) } ?? unit.subject)
                        .ufFont(12.8, 600).foregroundStyle(UF.accentText)
                }
                .buttonStyle(.plain)
                Text("· \(KnowledgeSemester.label(unit.semester)) · \(KnowledgeRole.label(unit.role, area: unit.area))")
                    .ufFont(12.8).foregroundStyle(UF.muted)
            }
            Text(unit.title).ufFont(compact ? 22 : 26, 700, em: -0.01).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
            KnowledgeBadges(marks: summary.marks, checked: unit.hasCheckScript)
            if summary.marks.kiUnchecked {
                HStack(alignment: .top, spacing: 8) {
                    UFIcon("alert", size: 16).foregroundStyle(UF.bad)
                    Text(KnowledgeTexts.kiWarning).ufFont(13.2, 550).foregroundStyle(UF.badText).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UF.badSoft))
                .accessibilityIdentifier("knowledge.kiWarning")
            }
            if !summary.types.isEmpty || !summary.solutionBy.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    if !summary.types.isEmpty { line("Typ", summary.types.joined(separator: ", ")) }
                    if !summary.solutionBy.isEmpty { line("Lösung von", summary.solutionBy.joined(separator: "; ")) }
                }
            }
            if !summary.sources.isEmpty {
                Button { showSources.toggle() } label: {
                    HStack(spacing: 4) {
                        Text("Quellen (\(summary.sources.count))").ufFont(12.8, 650).foregroundStyle(UF.text2)
                        Image(systemName: showSources ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(UF.muted)
                    }
                }
                .buttonStyle(.plain)
                if showSources || summary.sources.count <= 2 {
                    ForEach(summary.sources, id: \.self) { s in
                        Text("• " + s).ufFont(12.8).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            let links = KnowledgeLinkTarget.resolve(summary.marks.links, library: library, from: unit)
            if !links.isEmpty {
                Text("Gleiche Seiten in anderen Einheiten").ufFont(12.8, 650).foregroundStyle(UF.text2)
                UFFlexWrap(gap: 6) {
                    ForEach(Array(links.prefix(12))) { t in
                        UFChip(text: t.link.label, icon: "arrow-right") { router.go(.knowledge(unit: t.unitKey, anchor: t.link.hint)) }
                    }
                }
            }
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        (Text(label + ": ").font(.uf(12.8, 650)) + Text(value).font(.uf(12.8)))
            .foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
    }

    private var fileTabs: some View {
        UFFlexWrap(gap: 6) {
            ForEach(files, id: \.self) { f in
                UFChip(text: KnowledgeFileKind.displayName(f), on: f == file, icon: KnowledgeFileKind.of(f).isMarkdown ? "file-text" : "file") {
                    target = nil
                    file = f
                }
                .accessibilityIdentifier("knowledge.file.\(f)")
            }
        }
    }

    /// Erste Datei: die gewuenschte; mit Sprungziel die erste, die es enthaelt (01-, 02-, README …); sonst Erklaerung,
    /// Loesung oder Ueberblick
    private func startFile() async -> String {
        if let f = initialFile, files.contains(f) { return f }
        if let anchor {
            for f in files where KnowledgeFileKind.of(f).isMarkdown && KnowledgeFileKind.of(f) != .readme {
                if let text = try? library.read(unit, file: f), KnowledgeDocument.parse(text).sectionIndex(for: anchor) != nil { return f }
            }
        }
        return files.first { KnowledgeFileKind.of($0) == .explained } ?? files.first { KnowledgeFileKind.of($0) == .solved } ?? files.first ?? ""
    }

    private func load(_ f: String) async {
        doc = nil; plain = nil; missing = false
        guard !f.isEmpty else { missing = true; return }
        let lib = library, u = unit
        let text = await Task.detached(priority: .userInitiated) { try? lib.read(u, file: f) }.value
        guard let text else { missing = true; return }
        if KnowledgeFileKind.of(f).isMarkdown {
            let d = await Task.detached(priority: .userInitiated) { KnowledgeDocument.parse(text) }.value
            doc = d
            if let anchor, !anchorApplied {
                anchorApplied = true
                target = d.sectionIndex(for: anchor)
            }
        } else {
            plain = text
        }
    }
}

/// Verweis mit aufgeloester Ziel-Einheit (nur Verweise, deren Einheit es gibt)
struct KnowledgeLinkTarget: Identifiable, Hashable {
    let link: KnowledgeLink
    let unitKey: String
    var id: KnowledgeLink { link }

    static func resolve(_ links: [KnowledgeLink], library: KnowledgeLibrary, from unit: KnowledgeUnit) -> [KnowledgeLinkTarget] {
        links.compactMap { l in library.resolve(l, from: unit).map { KnowledgeLinkTarget(link: l, unitKey: $0.key) } }
    }
}

/// Kopfdaten einer Datei als kleine Kopfzeile (Quellen, Typ, Loesung, Abgleich, Rechenprobe)
private struct KnowledgeFileHead: View {
    let frontMatter: KnowledgeFrontMatter
    @State private var allSources = false

    private static let shown: [(String, String)] = [("typ", "Typ"), ("loesung_von", "Lösung von"), ("abgleich", "Abgleich"),
                                                     ("rechenprobe", "Rechenprobe"), ("status", "Status")]

    var body: some View {
        let rows = Self.shown.compactMap { k, label in frontMatter[k].map { (label, $0) } }
        if !rows.isEmpty || !frontMatter.sources.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                // viele Quellen (Sammel-Einheiten mit 14 Blaettern): die ersten drei, der Rest auf Tippen
                let sources = frontMatter.sources
                ForEach(allSources ? sources : Array(sources.prefix(3)), id: \.self) { s in
                    (Text("Quelle: ").font(.uf(12.5, 650)) + Text(s).font(.uf(12.5))).foregroundStyle(UF.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if sources.count > 3 && !allSources {
                    Button("+ \(sources.count - 3) weitere Quellen") { allSources = true }
                        .font(.uf(12.5, 650)).foregroundStyle(UF.accentText).buttonStyle(.plain)
                }
                ForEach(rows, id: \.0) { label, value in
                    (Text(label + ": ").font(.uf(12.5, 650)) + Text(value).font(.uf(12.5)))
                        .foregroundStyle(value.lowercased().contains("ki-lösung, ungeprüft") ? UF.badText : UF.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UF.surface2))
            .accessibilityIdentifier("knowledge.fileHead")
        }
    }
}

/// Ein Abschnitt (## [Q1] Seite 3 …) mit Verweisen "identisch mit G00xx" als Knopf
private struct KnowledgeSectionView: View {
    let section: KnowledgeSection
    let library: KnowledgeLibrary
    let unit: KnowledgeUnit
    var highlighted = false
    @EnvironmentObject private var router: UFRouter

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AIMarkdownText(section.markdown, size: 15, formulasOnly: true)
            let links = KnowledgeLinkTarget.resolve(KnowledgeMarks.links(in: section.markdown), library: library, from: unit)
            if !links.isEmpty {
                UFFlexWrap(gap: 6) {
                    ForEach(links) { t in
                        UFChip(text: "Erklärung in \(t.link.label)", icon: "arrow-right") { router.go(.knowledge(unit: t.unitKey, anchor: t.link.hint)) }
                            .accessibilityIdentifier("knowledge.link.\(t.link.unit)")
                    }
                }
            }
        }
        .padding(highlighted ? 12 : 0)
        .background(RoundedRectangle(cornerRadius: UF.r).fill(highlighted ? UF.accentSoft.opacity(0.5) : .clear))
        .accessibilityIdentifier("knowledge.section.\(section.index)")
    }
}

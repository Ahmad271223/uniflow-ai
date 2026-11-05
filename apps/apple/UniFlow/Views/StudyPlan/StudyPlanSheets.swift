import SwiftUI
import UniFlowCore

// Blaetter des Studienverlaufs: Moduldetail (Fakten, eigener Stand mit Versuchen, lokale Modultexte zum Aufklappen,
// "Deine Unterlagen" aus StudiNow, Quelle mit Seitenzahl) und Einstellungen (Pruefungsordnung, Studienbeginn,
// Wahlpflicht mit LP-Zaehler). Daten: GET /api/study-plan/module/{id}, GET/POST /api/study-plan/settings.

// MARK: - Groesse der Blaetter

/// Nur kompakt (iPhone): Blatt von unten mit halber und voller Hoehe und Griff; am iPad bleibt das uebliche Blatt
/// (etwa "Verschieben nach …", das dort kein Seitenblatt ist)
struct StudyPlanCompactSheet: ViewModifier {
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize

    func body(content: Content) -> some View {
        if UFLayout.isCompact(horizontal: hSize, vertical: vSize) {
            content
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        } else {
            content
        }
    }
}

/// iPadOS 18: Blatt in Seitenbreite (Fakten nebeneinander); iPadOS 17: das uebliche Formblatt. Kompakt (iPhone): Blatt
/// von unten mit halber und voller Hoehe und Griff (docs/IPHONE-2026-11-04.md)
struct StudyPlanSheetSizing: ViewModifier {
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize

    func body(content: Content) -> some View {
        if UFLayout.isCompact(horizontal: hSize, vertical: vSize) {
            content
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        } else if #available(iOS 18.0, *) {
            content.presentationSizing(.page)
        } else {
            content
        }
    }
}

/// Kopfzeile eines Blatts: optional "Zurück", Titel, Schliessen (44 pt)
struct StudyPlanSheetHeader: View {
    let title: String
    var back: (() -> Void)?
    let close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let back {
                Button(action: back) {
                    HStack(spacing: 2) {
                        UFIcon("chevron-left", size: 16)
                        Text("Zurück").ufFont(14.5, 550)
                    }
                    .foregroundStyle(UF.accentText)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("studyplan.sheet.back")
            }
            Text(title).ufFont(15.2, 650, lh: 1.25).foregroundStyle(UF.text).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: back == nil ? .leading : .center)
                .accessibilityAddTraits(.isHeader)
            Button(action: close) {
                UFIcon("x", size: 16).foregroundStyle(UF.text2).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Schließen")
            .accessibilityIdentifier("studyplan.sheet.close")
        }
        .padding(.leading, 16).padding(.trailing, 8)
        .frame(minHeight: 52)
        .background(UF.surface)
        .ufBorderBottom()
    }
}

// MARK: - Moduldetail

struct StudyModuleSheet: View {
    let startID: String
    let api: APIClient?
    /// Titel je Modul-id aus dem Plan (Voraussetzungen, wenn der Kern nur ids nennt)
    var titles: [String: String] = [:]
    /// Modul im Plan (eigene Lage, verschiebbar) und Aenderungen daran (05.11.2026); nil: nur lesen
    var planModule: StudyPlanModule?
    var manage: ((String, StudyPlanModuleAction) -> Void)?
    /// Unterlage oeffnen: Blatt zu, Seite wechseln
    let open: (UFRoute) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var stack: [String] = []
    @State private var details: [String: StudyModuleDetail] = [:]
    @State private var failed: [String: String] = [:]
    @State private var expanded: Set<String> = ["content"]

    private var currentID: String { stack.last ?? startID }

    var body: some View {
        VStack(spacing: 0) {
            StudyPlanSheetHeader(title: "Moduldetails",
                                 back: stack.count > 1 ? { UFMotion.toggle { _ = stack.popLast() } } : nil,
                                 close: { dismiss() })
            ScrollView {
                Group {
                    if let d = details[currentID] {
                        content(d)
                    } else if let f = failed[currentID] {
                        StudyPlanNoticeCard(icon: "alert", tone: .bad, title: "Modul nicht lesbar", text: f) {
                            UFButton("Erneut laden", icon: "refresh") { Task { await load(currentID, force: true) } }
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 240)
                    }
                }
                .padding(EdgeInsets(top: 18, leading: 20, bottom: 32, trailing: 20))
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .id(currentID)
        }
        .background(UF.bg)
        .onAppear { if stack.isEmpty { stack = [startID] } }
        .task(id: currentID) { await load(currentID) }
        .modifier(StudyPlanSheetSizing())
        .accessibilityIdentifier("studyplan.detail")
    }

    @ViewBuilder private func content(_ d: StudyModuleDetail) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            titleBlock(d)
            ownBlock(d)
            manageBlock
            // "Prüfung anmelden" (05.11.2026): nur wenn der Studienverlauf das Modul in diesem Semester vorschlaegt
            ExamRegistrationModuleBlock(api: api, catalogID: currentID)
            factsBlock(d)
            if !d.sections.isEmpty { textsBlock(d) } else if d.textsLoading { textsLoadingBlock }
            materialsBlock(d)
            sourceBlock(d)
        }
    }

    /// Im Plan: verschieben, nicht belegen, zurueck ins empfohlene Semester (nur fuer das Modul, mit dem das Blatt
    /// geoeffnet wurde)
    @ViewBuilder private var manageBlock: some View {
        if let m = planModule, m.movable, let manage, currentID == startID {
            UFFlexWrap(gap: 8) {
                UFButton("Verschieben nach …", icon: "move", size: .small) { manage(m.id, .move) }
                    .accessibilityIdentifier("studyplan.detail.move")
                if m.placed {
                    UFButton("Ins empfohlene Semester", icon: "undo", size: .small) { manage(m.id, .resetPlacement) }
                        .accessibilityIdentifier("studyplan.detail.reset")
                }
                if m.replaceable {
                    UFButton("Anderes Modul wählen", icon: "refresh", size: .small) { manage(m.id, .replace) }
                        .accessibilityIdentifier("studyplan.detail.replace")
                }
                UFButton("Nicht belegen", icon: "x", size: .small) { manage(m.id, .drop) }
                    .accessibilityIdentifier("studyplan.detail.drop")
            }
            if !m.hints.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(m.hints, id: \.self) { h in
                        Label { Text(h) } icon: { UFIcon("alert", size: 12) }
                            .ufFont(12.8, lh: 1.4).foregroundStyle(UF.warnText).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func titleBlock(_ d: StudyModuleDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(d.title).ufFont(21.6, 700, lh: 1.25, em: -0.01).foregroundStyle(UF.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("studyplan.detail.title")
            UFFlexWrap(gap: 6, rowGap: 6) {
                StudyPlanTag(text: StudyPlanText.kind(d.kind), pair: StudyPlanText.kindPair(d.kind))
                if let t = StudyPlanText.turnus(d.turnus) { StudyPlanTag(text: t, pair: nil) }
                if let c = d.code { StudyPlanTag(text: c, pair: nil) }
                if let a = d.area { Text(a).ufFont(12.8).foregroundStyle(UF.muted) }
            }
        }
    }

    // eigener Stand mit Versuchen
    private func ownBlock(_ d: StudyModuleDetail) -> some View {
        StudyPlanSection(title: "Dein Stand", icon: "user") {
            VStack(alignment: .leading, spacing: 8) {
                StudyPlanStatusPill(text: ownText(d), status: d.status)
                    .accessibilityIdentifier("studyplan.detail.status")
                if let r = d.reason {
                    Text(r).ufFont(13.12, lh: 1.4).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                }
                if !d.attempts.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(d.attempts.enumerated()), id: \.offset) { i, a in
                            HStack(spacing: 10) {
                                Text(a.attempt.map { "Versuch \($0)" } ?? "Versuch").ufFont(13.12, 600).foregroundStyle(UF.text)
                                Text([a.term, a.date.map { UFFmt.date($0) }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                    .ufFont(12.8).foregroundStyle(UF.muted)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let g = a.grade { Text(g).ufFont(13.12, 650).monospacedDigit().foregroundStyle(UF.text) }
                                StudyPlanStatusPill(text: StudyPlanText.status(a.status), status: a.status).fixedSize()
                            }
                            .padding(.vertical, 8)
                            .ufBorderBottom(i < d.attempts.count - 1)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .accessibilityIdentifier("studyplan.detail.attempts")
                }
                if d.lastAttempt {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        UFIcon("alert", size: 14)
                        Text(StudyPlanText.lastAttemptWarning).fixedSize(horizontal: false, vertical: true)
                    }
                    .ufFont(13.12, 600, lh: 1.4)
                    .foregroundStyle(UF.badText)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UF.badSoft))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func ownText(_ d: StudyModuleDetail) -> String {
        switch d.status {
        case .passed:
            let g = d.attempts.last(where: { $0.status == .passed })?.grade
            return g.map { "Bestanden · \($0)" } ?? "Bestanden"
        case .failed:
            let n = d.attempts.compactMap(\.attempt).max()
            return n.map { "Nicht bestanden · Versuch \($0)" } ?? "Nicht bestanden"
        case .moved: return d.movedFrom.map { "Verschoben · aus \($0)" } ?? "Nachholen"
        default: return StudyPlanText.status(d.status)
        }
    }

    // Fakten aus dem Katalog
    private func factsBlock(_ d: StudyModuleDetail) -> some View {
        let facts: [(String, String)] = [
            ("Leistungspunkte", StudyPlanText.lp(d.lp)),
            ("Empfohlen", StudyPlanText.fach(d.semester) ?? "frei wählbar"),
            ("Turnus", StudyPlanText.turnusLong(d.turnus)),
            ("Prüfungsleistung", d.exam ?? "–"),
            ("Studienleistung", d.coursework ?? "keine"),
            ("Sprache", d.language.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "–"),
            ("Arbeitsaufwand", d.workloadH.map { "\($0) Stunden" } ?? "–"),
        ]
        return StudyPlanSection(title: "Fakten", icon: "list") {
            VStack(alignment: .leading, spacing: 14) {
                UFGridLayout(spacing: 12, minWidth: 168) {
                    ForEach(facts, id: \.0) { f in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.0).ufFont(11.84, 600).foregroundStyle(UF.muted)
                            Text(f.1).ufFont(14, 500, lh: 1.35).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(f.0): \(f.1)")
                    }
                }
                .accessibilityIdentifier("studyplan.detail.facts")
                VStack(alignment: .leading, spacing: 6) {
                    Text("Voraussetzungen").ufFont(11.84, 600).foregroundStyle(UF.muted)
                    if d.prerequisites.isEmpty {
                        Text("keine").ufFont(14, 500).foregroundStyle(UF.text)
                    } else {
                        UFFlexWrap(gap: 6, rowGap: 6) {
                            ForEach(d.prerequisites) { p in
                                UFChip(text: p.title, icon: "arrow-right") { UFMotion.toggle { stack.append(p.id) } }
                                    .accessibilityLabel("Voraussetzung \(p.title)")
                                    .accessibilityHint("Zeigt dieses Modul")
                                    .accessibilityIdentifier("studyplan.detail.prereq.\(p.id)")
                            }
                        }
                    }
                }
            }
        }
    }

    // Modultexte kommen gleich (einmal je Katalog aus der oeffentlichen PDF)
    private var textsLoadingBlock: some View {
        StudyPlanSection(title: "Aus dem Modulkatalog", icon: "file-text") {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Inhalte und Lernziele werden geladen …").ufFont(13.12, lh: 1.4).foregroundStyle(UF.muted)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("studyplan.detail.textsLoading")
        }
    }

    // lokale Modultexte zum Aufklappen
    private func textsBlock(_ d: StudyModuleDetail) -> some View {
        StudyPlanSection(title: "Aus dem Modulkatalog", icon: "file-text") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(d.sections.enumerated()), id: \.element.id) { i, s in
                    let open = expanded.contains(s.id)
                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            UFMotion.toggle { if open { expanded.remove(s.id) } else { expanded.insert(s.id) } }
                        } label: {
                            HStack(spacing: 8) {
                                Text(s.title).ufFont(14.5, 600).foregroundStyle(UF.text)
                                Spacer(minLength: 4)
                                UFIcon("chevron-down", size: 14).foregroundStyle(UF.muted).rotationEffect(.degrees(open ? 180 : 0))
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(s.title)
                        .accessibilityValue(open ? "aufgeklappt" : "zugeklappt")
                        .accessibilityHint(open ? "Zuklappen" : "Aufklappen")
                        .accessibilityIdentifier("studyplan.detail.text.\(s.id)")
                        if open {
                            UFLongText(text: s.text, size: 14, lh: 1.55, color: UF.text2)
                                .padding(.bottom, 10)
                                .transition(UFMotion.reveal)
                        }
                    }
                    .ufBorderBottom(i < d.sections.count - 1)
                }
                Text(StudyPlanText.localOnly).ufFont(12).foregroundStyle(UF.muted).padding(.top, 8)
            }
        }
    }

    // Kurse und Dateien in StudiNow zu diesem Modul
    private func materialsBlock(_ d: StudyModuleDetail) -> some View {
        StudyPlanSection(title: "Deine Unterlagen", icon: "folder") {
            if d.materials.isEmpty {
                Text(StudyPlanText.materialsEmpty).ufFont(13.12, lh: 1.4).foregroundStyle(UF.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(d.materials.enumerated()), id: \.element.id) { i, m in
                        Button {
                            if let r = m.route { open(r) }
                        } label: {
                            HStack(spacing: 12) {
                                UFIcon(m.kind == "course" || m.kind == "module" ? "book" : "file-text", size: 17)
                                    .foregroundStyle(UF.accentText)
                                    .frame(width: 32, height: 32)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(UF.accentSoft))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(m.title).ufFont(14.5, 550, lh: 1.3).foregroundStyle(UF.text)
                                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                    if let sub = m.sub { Text(sub).ufFont(12.8).foregroundStyle(UF.muted).lineLimit(1) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if m.route != nil { UFIcon("chevron-right", size: 14).foregroundStyle(UF.muted) }
                            }
                            .padding(.vertical, 8)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(m.route == nil)
                        .ufBorderBottom(i < d.materials.count - 1)
                        .accessibilityLabel(([m.kind == "course" || m.kind == "module" ? "Kurs" : "Datei", m.title] + [m.sub].compactMap { $0 })
                            .joined(separator: ", "))
                        .accessibilityIdentifier("studyplan.detail.material.\(m.id)")
                    }
                }
            }
        }
    }

    private func sourceBlock(_ d: StudyModuleDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let url = d.sourceURL {
                UFButton(StudyPlanText.sourceLabel(page: d.sourcePage), icon: "arrow-right") { openURL(url) }
                    .accessibilityHint("Öffnet den Modulkatalog der Hochschule")
                    .accessibilityIdentifier("studyplan.detail.source")
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                UFIcon("info", size: 13)
                Text(StudyPlanText.disclaimer).fixedSize(horizontal: false, vertical: true)
            }
            .ufFont(12.48, lh: 1.4)
            .foregroundStyle(UF.muted)
            .accessibilityElement(children: .combine)
        }
    }

    private func load(_ id: String, force: Bool = false) async {
        guard force || details[id] == nil, let api else {
            if api == nil { failed[id] = "Keine Datenquelle." }
            return
        }
        do {
            let v = try await api.value("/api/study-plan/module/\(APIClient.queryValue(id))")
            details[id] = StudyModuleDetail(v, titles: titles)
            failed[id] = nil
            // Texte laden im Hintergrund: einige Male nachfragen, solange das Blatt dieses Modul zeigt
            var tries = 0
            while details[id]?.textsLoading == true, details[id]?.sections.isEmpty == true, tries < 8, currentID == id {
                tries += 1
                try await Task.sleep(nanoseconds: 2_500_000_000)
                let again = try await api.value("/api/study-plan/module/\(APIClient.queryValue(id))")
                let d = StudyModuleDetail(again, titles: titles)
                details[id] = d
                if !d.sections.isEmpty { break }
            }
        } catch {
            failed[id] = error.localizedDescription
        }
    }
}

/// Abschnitt im Blatt: kleine Ueberschrift mit Symbol, Inhalt auf einer Karte
struct StudyPlanSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                UFIcon(icon, size: 14)
                Text(title)
            }
            .ufFont(13.12, 650)
            .foregroundStyle(UF.text2)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface))
                .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(UF.line, lineWidth: 1))
        }
    }
}

// MARK: - Einstellungen

struct StudyPlanSettingsSheet: View {
    let api: APIClient?
    /// gelesener Plan: Schwerpunkt-Gruppen und eigene Eintraege (05.11.2026); nil: ohne diese Abschnitte
    var plan: StudyPlan? = nil
    /// nach dem Speichern: Plan neu lesen
    let saved: () async -> Void
    /// Tests: "heute" fuer die Liste der Semester
    var today = Date()

    @Environment(\.dismiss) private var dismiss
    @State private var settings: StudyPlanSettings?
    @State private var po = ""
    @State private var start = ""
    @State private var chosen: Set<String> = []
    @State private var error: String?
    @State private var saving = false
    /// Schwerpunkt je Gruppe ("" = noch offen) und entfernte eigene Eintraege
    @State private var tracks: [String: String] = [:]
    @State private var removedCustom: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            StudyPlanSheetHeader(title: "Studienverlauf einstellen", close: { dismiss() })
            ScrollView {
                Group {
                    if let s = settings {
                        form(s)
                    } else if let error {
                        StudyPlanNoticeCard(icon: "alert", tone: .bad, title: "Einstellungen nicht lesbar", text: error) {
                            UFButton("Erneut laden", icon: "refresh") { Task { await load() } }
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                    }
                }
                .padding(EdgeInsets(top: 18, leading: 20, bottom: 24, trailing: 20))
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            if settings != nil {
                VStack(alignment: .trailing, spacing: 6) {
                    if let error {
                        Text(error).ufFont(12.8).foregroundStyle(UF.badText).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("studyplan.settings.error")
                    }
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        UFButton("Abbrechen", kind: .ghost) { dismiss() }
                        UFButton(saving ? "Speichert …" : "Speichern", icon: "check", kind: .primary) { Task { await save() } }
                            .disabled(saving)
                            .accessibilityIdentifier("studyplan.settings.save")
                    }
                }
                .padding(.vertical, 12).padding(.horizontal, 20)
                .background(UF.surface)
                .overlay(alignment: .top) { Rectangle().fill(UF.line).frame(height: 1) }
            }
        }
        .background(UF.bg)
        .task { if settings == nil { await load() } }
        .accessibilityIdentifier("studyplan.settings.sheet")
    }

    @ViewBuilder private func form(_ s: StudyPlanSettings) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            StudyPlanSection(title: "Prüfungsordnung", icon: "file-text") {
                VStack(alignment: .leading, spacing: 8) {
                    if s.poOptions.isEmpty {
                        Text("Für deinen Studiengang ist nur eine Ordnung bekannt.").ufFont(13.12).foregroundStyle(UF.muted)
                    } else if s.poOptions.count <= 4 {
                        UFSegmented(options: s.poOptions.map { ($0, "PO \($0)") }, selection: $po)
                            .accessibilityIdentifier("studyplan.settings.po")
                    } else {
                        UFSelect(options: s.poOptions.map { ($0, "PO \($0)") }, selection: $po)
                            .accessibilityIdentifier("studyplan.settings.po")
                    }
                    Text("Bestimmt den Modulkatalog und den Verlaufsplan. Verbindlich ist die Ordnung, nach der du eingeschrieben bist.")
                        .ufFont(12.48, lh: 1.4).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            StudyPlanSection(title: "Studienbeginn", icon: "calendar") {
                VStack(alignment: .leading, spacing: 8) {
                    UFSelect(options: s.termOptions.map { ($0, $0) }, selection: $start)
                        .accessibilityLabel("Studienbeginn")
                        .accessibilityValue(start)
                        .accessibilityIdentifier("studyplan.settings.start")
                    Text("Ab hier zählen die Fachsemester. StudiNow schlägt das früheste Semester aus QIS vor.")
                        .ufFont(12.48, lh: 1.4).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            tracksSection
            electives(s)
            customSection
        }
    }

    @ViewBuilder private var tracksSection: some View {
        if let plan, !plan.groups.isEmpty {
            StudyPlanSection(title: "Schwerpunkt", icon: "layers") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(plan.groups) { g in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(g.label).ufFont(13.12, 650).foregroundStyle(UF.text2)
                            UFSelect(options: [("", "Noch offen")] + g.options.map { ($0, plan.area($0)?.name ?? $0) },
                                     selection: Binding(get: { tracks[g.id] ?? "" }, set: { tracks[g.id] = $0 }))
                                .accessibilityLabel(g.label)
                                .accessibilityValue(plan.area(tracks[g.id])?.name ?? "Noch offen")
                                .accessibilityIdentifier("studyplan.settings.track.\(g.id)")
                            if let r = plan.area(tracks[g.id])?.rule {
                                Text(r).ufFont(12.48, lh: 1.4).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var customSection: some View {
        if let plan, !plan.customModules.isEmpty {
            StudyPlanSection(title: "Eigene Einträge", icon: "pen") {
                VStack(alignment: .leading, spacing: 0) {
                    let list = plan.customModules.filter { !removedCustom.contains($0.id) }
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, m in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.title).ufFont(14.5, 550, lh: 1.3).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                                Text([StudyPlanText.lp(m.lp), plan.area(m.area)?.name, StudyPlanText.status(m)].compactMap { $0 }.joined(separator: " · "))
                                    .ufFont(12.48).foregroundStyle(UF.muted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            UFButton(icon: "trash", size: .small) { removedCustom.insert(m.id) }
                                .accessibilityLabel("\(m.title) entfernen")
                                .accessibilityIdentifier("studyplan.settings.custom.remove.\(m.id)")
                        }
                        .padding(.vertical, 8)
                        .ufBorderBottom(i < list.count - 1)
                    }
                    if list.isEmpty { Text("Alle eigenen Einträge werden entfernt.").ufFont(13.12).foregroundStyle(UF.muted) }
                }
            }
        }
    }

    @ViewBuilder private func electives(_ s: StudyPlanSettings) -> some View {
        StudyPlanSection(title: "Wahlpflicht", icon: "layers") {
            if s.electiveOptions.isEmpty {
                Text("Dein Studiengang hat keine Wahlpflichtmodule zum Auswählen.").ufFont(13.12).foregroundStyle(UF.muted)
            } else {
                let lp = s.chosenLP(chosen)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(counter(lp, s.electiveLPRequired)).ufFont(14, 650).foregroundStyle(lpTone(lp, s.electiveLPRequired))
                            .monospacedDigit()
                            .accessibilityIdentifier("studyplan.settings.counter")
                        Spacer(minLength: 4)
                        Text("\(chosen.intersection(s.electiveOptions.map(\.id)).count) von \(s.electiveOptions.count) Modulen")
                            .ufFont(12.8).foregroundStyle(UF.muted)
                    }
                    if let req = s.electiveLPRequired, req > 0 {
                        UFProgress(value: lp / req, ok: lp >= req, color: lp > req ? UF.warn : nil)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(s.electiveOptions.enumerated()), id: \.element.id) { i, e in
                            electiveRow(e).ufBorderBottom(i < s.electiveOptions.count - 1)
                        }
                    }
                }
            }
        }
    }

    private func electiveRow(_ e: StudyPlanSettings.Elective) -> some View {
        let on = chosen.contains(e.id)
        return Button {
            if on { chosen.remove(e.id) } else { chosen.insert(e.id) }
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(on ? UF.accentFill : UF.surface)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(on ? UF.accentFill : UF.lineStrong, lineWidth: 1.5))
                    .overlay { if on { UFIcon("check", size: 14).foregroundStyle(.white) } }
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.title).ufFont(14.5, 550, lh: 1.3).foregroundStyle(UF.text)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    if let a = e.area { Text(a).ufFont(12.48).foregroundStyle(UF.muted).lineLimit(1) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(StudyPlanText.lp(e.lp)).ufFont(13.12, 600).monospacedDigit().foregroundStyle(UF.text2).fixedSize()
            }
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(e.title), \(StudyPlanText.number(e.lp)) Leistungspunkte")
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("studyplan.settings.elective.\(e.id)")
    }

    /// "15 von 30 LP gewählt" bzw. "15 LP gewählt"
    static func counter(_ lp: Double, _ required: Double?) -> String {
        if let r = required, r > 0 { return "\(StudyPlanText.number(lp)) von \(StudyPlanText.number(r)) LP gewählt" }
        return "\(StudyPlanText.number(lp)) LP gewählt"
    }

    private func counter(_ lp: Double, _ required: Double?) -> String { Self.counter(lp, required) }

    private func lpTone(_ lp: Double, _ required: Double?) -> Color {
        guard let r = required, r > 0 else { return UF.text }
        return lp > r ? UF.warnText : (lp >= r ? UF.okText : UF.text)
    }

    private func load() async {
        guard let api else { error = "Keine Datenquelle."; return }
        do {
            let s = StudyPlanSettings(try await api.value("/api/study-plan/settings"), today: today)
            po = s.po ?? s.poOptions.first ?? ""
            start = s.startTerm ?? s.termOptions.first ?? ""
            chosen = Set(s.electives)
            var t: [String: String] = [:]
            for g in plan?.groups ?? [] { t[g.id] = g.auto ? "" : (g.chosen ?? "") }
            tracks = t
            settings = s
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        guard let api, let s = settings else { return }
        saving = true
        defer { saving = false }
        do {
            var body = s.body(po: po.isEmpty ? nil : po, startTerm: start.isEmpty ? nil : start, electives: chosen)
            if let plan {
                // Schwerpunkt und eigene Eintraege nur, wenn geaendert (der Kern speichert teilweise)
                var before: [String: String] = [:]
                for g in plan.groups { before[g.id] = g.auto ? "" : (g.chosen ?? "") }
                if tracks != before {
                    body["tracks"] = .object(tracks.filter { !$0.value.isEmpty }.mapValues(JSONValue.string))
                }
                if !removedCustom.isEmpty {
                    body["custom"] = .array(plan.customModules.filter { !removedCustom.contains($0.id) }.map { StudyPlanEdit.customJSON($0, plan: plan) })
                }
            }
            _ = try await api.value("/api/study-plan/settings", method: "POST", body: body)
            error = nil
            await saved()
            dismiss()
        } catch {
            self.error = "Speichern fehlgeschlagen: \(error.localizedDescription)"
        }
    }
}

import SwiftUI
import UniFlowCore

/// Studiengang waehlen (14.11.2026, erstes echtes Hildesheim-Konto: nach einem Wechsel zu Sozialpaedagogik nahm die App
/// weiter Erziehungswissenschaft, und in der App liess sich kein anderer Studiengang waehlen). Gewaehlt wird ein Kuerzel
/// aus dem Register (`POST /api/study-plan/settings {po: code}`); es gilt vor dem Studiengang aus dem Notenspiegel.

/// Ein Studiengang aus dem Notenspiegel (`programs` im Plan)
struct StudyPlanProgramChoice: Equatable, Identifiable {
    let label: String
    let program: String
    let degree: String?
    let po: String?
    let code: String?
    var id: String { code ?? label }

    init(_ v: JSONValue) {
        label = v.s("label") ?? ""
        program = v.s("program") ?? label
        degree = v.s("degree")
        po = v.s("po") ?? v.i("po").map(String.init)
        code = v.s("code")
    }

    /// "Sozialpädagogik (B.A.)"
    var name: String { degree.map { "\(program) (\($0))" } ?? program }
}

/// Karte "Welchen Studiengang studierst du gerade?": der Notenspiegel nennt mehrere Studiengaenge
struct StudyPlanProgramQuestion: View {
    let programs: [StudyPlanProgramChoice]
    let source: String
    /// die Studiengaenge sind die Faecher eines Mehr-Faecher-Studiengangs (26.11.2026): alle zaehlen, gefragt ist nur,
    /// fuer welches Fach der Verlaufsplan gezeigt wird
    var subjects = false
    let busy: Bool
    let pick: (String) -> Void
    let other: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                StudyPlanIconTile(icon: "graduation", pair: CommunityPalette.sky)
                VStack(alignment: .leading, spacing: 3) {
                    Text(subjects ? Self.subjectsTitle : "Welchen Studiengang studierst du gerade?").ufFont(15.2, 650, lh: 1.3).foregroundStyle(UF.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subjects ? Self.subjectsHint(source: source)
                         : "\(source) nennt mehrere Studiengänge. Leistungen aus einem früheren Studiengang zählen nur, wenn sie anerkannt sind.")
                        .ufFont(13.12, lh: 1.4).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            UFFlexWrap(gap: 8) {
                ForEach(Array(programs.enumerated()), id: \.element.id) { i, p in
                    if let code = p.code {
                        UFButton(p.name + (p.po.map { " · PO \($0)" } ?? ""), kind: i == 0 ? .primary : .normal, size: .small) { pick(code) }
                            .disabled(busy)
                    } else {
                        UFButton("\(p.name) (Katalog fehlt)", size: .small) { other() }
                    }
                }
                UFButton("Anderer Studiengang", size: .small) { other() }
                    .accessibilityIdentifier("studyplan.program.other")
            }
            .padding(.leading, 52)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: UF.r).fill(Color.mix(UF.info, 0.07, UF.surface)))
        .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(Color.mix(UF.info, 0.3, UF.line), lineWidth: 1))
        .accessibilityIdentifier("studyplan.programs")
    }

    static let subjectsTitle = "Für welches Fach möchtest du den Verlaufsplan sehen?"
    static func subjectsHint(source: String) -> String {
        "\(source) führt die Fächer deines Studiengangs einzeln. Alle zählen zu deinen Leistungspunkten; der Verlaufsplan zeigt die Module eines Fachs."
    }
}

/// Karte des ganzen Mehr-Faecher-Studiengangs (26.11.2026): LP aller Faecher gegen die Gesamtzahl (Bachelor 180), je Fach
/// seine LP; vorher stand ein Fach fuer den ganzen Studiengang ("69 von 72 LP") und ein anderes unter "Früheres Studium"
struct StudyPlanDegreeCard: View {
    let degree: StudyPlanDegree
    let source: String

    var body: some View {
        UFCard {
            UFCardHead("Dein Studiengang", icon: "graduation") {
                Text(degree.progress).ufFont(14.5, 700).monospacedDigit().foregroundStyle(UF.okText)
            }
            Text(degree.name).ufFont(15.2, 650, lh: 1.3).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
            if let total = degree.lpTotal {
                UFProgress(value: min(1, max(0, degree.lpDone / total)), ok: true).padding(.vertical, 6)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(degree.subjects) { s in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.program).ufFont(14.5, 600).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                            Text(Self.detail(s)).ufFont(12.48).foregroundStyle(UF.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(StudyPlanText.number(s.lpDone)) LP").ufFont(14.5, 650).monospacedDigit().foregroundStyle(UF.text)
                    }
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                    if s.id != degree.subjects.last?.id { Divider().overlay(UF.line) }
                }
            }
            if let official = degree.official(source: source) {
                Text(official).ufFont(12.48).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("studyplan.degree.official")
            }
        }
        .accessibilityIdentifier("studyplan.degree")
    }

    /// "PO 2025 · 7 bestandene Leistungen · Verlaufsplan unten"
    static func detail(_ s: StudyPlanDegree.Subject) -> String {
        [s.po.map { "PO \($0)" }, "\(s.passed) \(s.passed == 1 ? "bestandene Leistung" : "bestandene Leistungen")",
         s.current ? "Verlaufsplan unten" : nil].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Karte "Bestanden je Semester" (26.11.2026, Wunsch des Inhabers): jede bestandene Leistung des Notenspiegels unter dem
/// Semester, in dem sie bestanden wurde, mit LP; unabhaengig vom Katalog, alle Faecher
struct StudyPlanPassedTermsCard: View {
    let terms: [StudyPlanPassedTerm]
    @State private var closed: Set<String> = []

    var body: some View {
        UFCard {
            UFCardHead("Bestanden je Semester", icon: "check")
            ForEach(terms) { t in
                let isOpen = !closed.contains(t.id)
                Button { UFMotion.toggle { if isOpen { closed.insert(t.id) } else { closed.remove(t.id) } } } label: {
                    HStack(spacing: 8) {
                        UFIcon("chevron-right", size: 14).foregroundStyle(UF.muted).rotationEffect(.degrees(isOpen ? 90 : 0))
                        Text(t.title).ufFont(14.5, 600).foregroundStyle(UF.text).frame(maxWidth: .infinity, alignment: .leading)
                        Text(t.summary).ufFont(12.8).monospacedDigit().foregroundStyle(UF.muted)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(isOpen ? "aufgeklappt" : "zugeklappt")
                if isOpen {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(t.rows.enumerated()), id: \.offset) { _, r in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(r.text).ufFont(13.12).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                                    if let program = r.program { Text(program).ufFont(11.84).foregroundStyle(UF.muted) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Text([r.note.map { "Note \($0)" }, "\(StudyPlanText.number(r.lp)) LP"].compactMap { $0 }.joined(separator: " · "))
                                    .ufFont(12.48).monospacedDigit().foregroundStyle(UF.muted)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.leading, 22).padding(.bottom, 6)
                }
            }
        }
        .accessibilityIdentifier("studyplan.passedterms")
    }
}

/// Blatt "Studiengang wählen": alle Studiengaenge des Registers der eigenen Hochschule mit ihren Pruefungsordnungen
struct StudyPlanProgramPicker: View {
    let api: APIClient?
    /// gewaehltes Kuerzel (hervorgehoben)
    let current: String?
    let university: String
    let picked: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var all: [JSONValue]?
    @State private var query = ""
    @State private var error: String?
    @State private var saving = false
    /// Neben-/Begleitfaecher (Kuerzel bzw. ID des Studiengangs, hoechstens drei)
    @State private var minors: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            StudyPlanSheetHeader(title: "Studiengang wählen", close: { dismiss() })
            VStack(alignment: .leading, spacing: 10) {
                Text("Alle Studiengänge der \(university), für die StudiNow Modulkataloge kennt. Wähle deine Prüfungsordnung (PO). Verbindlich ist die Ordnung, nach der du eingeschrieben bist.")
                    .ufFont(13.12, lh: 1.45).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                UFTextField("Studiengang suchen", text: $query)
                    .accessibilityLabel("Studiengang suchen")
                if let error { Text(error).ufFont(12.8).foregroundStyle(UF.badText).fixedSize(horizontal: false, vertical: true) }
                if !minors.isEmpty, let all {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Neben- oder Begleitfach").ufFont(12.8, 600).foregroundStyle(UF.text2)
                        UFFlexWrap(gap: 6) {
                            ForEach(minors, id: \.self) { k in
                                UFButton("\(Self.name(of: k, in: all)) entfernen", icon: "x", size: .small) { Task { await setMinors(minors.filter { $0 != k }) } }
                                    .disabled(saving)
                            }
                        }
                    }
                }
            }
            .padding(16)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let all {
                        let items = Self.filter(all, query)
                        if items.isEmpty {
                            Text("Kein Studiengang gefunden. Prüfe die Schreibweise.").ufFont(13.12).foregroundStyle(UF.muted).padding(16)
                        }
                        ForEach(Array(items.prefix(80).enumerated()), id: \.offset) { _, p in
                            StudyPlanProgramRow(program: p, current: current, busy: saving, minor: minors.contains(Self.key(p))) { code in
                                Task { await choose(code) }
                            } toggleMinor: {
                                let k = Self.key(p)
                                Task { await setMinors(minors.contains(k) ? minors.filter { $0 != k } : Array((minors + [k]).prefix(3))) }
                            }
                        }
                    } else if error == nil {
                        ProgressView().frame(maxWidth: .infinity).padding(24)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 16)
            }
        }
        .task { await loadList() }
        .accessibilityIdentifier("studyplan.programpicker")
    }

    /// Suche wie im Kern (`StudySources.programMatches`)
    static func filter(_ all: [JSONValue], _ q: String) -> [JSONValue] {
        StudySources.filterPrograms(all, query: q)
    }

    private func loadList() async {
        guard let api else { error = "Nicht verbunden."; return }
        do { all = try await api.value("/api/study-catalog/programs").list("programs") } catch { self.error = error.localizedDescription }
        minors = ((try? await api.value("/api/study-plan/settings"))?.list("minors") ?? []).compactMap(\.string)
    }

    /// Schluessel eines Studiengangs fuer Neben-/Begleitfaecher: Kuerzel der neuesten PO, sonst die ID
    static func key(_ p: JSONValue) -> String {
        p.list("pos").filter { $0.s("code") != nil }.max { ($0.s("po") ?? "") < ($1.s("po") ?? "") }?.s("code") ?? p.s("id") ?? ""
    }

    static func name(of key: String, in all: [JSONValue]) -> String {
        guard let p = all.first(where: { Self.key($0) == key }) else { return key }
        return (p.s("program") ?? key) + (p.s("degree").map { " (\($0))" } ?? "")
    }

    private func setMinors(_ list: [String]) async {
        guard let api else { return }
        saving = true
        defer { saving = false }
        do {
            _ = try await api.value("/api/study-plan/settings", method: "POST", body: ["minors": .array(list.map { .string($0) })])
            minors = list
            await picked()
        } catch {
            self.error = "Speichern fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func choose(_ code: String) async {
        guard let api else { return }
        saving = true
        defer { saving = false }
        do {
            _ = try await api.value("/api/study-plan/settings", method: "POST", body: ["po": .string(code)])
            _ = try? await api.value("/api/study-catalog/status")               // stoesst die Suche nach dem Katalog an
            await picked()
            dismiss()
        } catch {
            self.error = "Speichern fehlgeschlagen: \(error.localizedDescription)"
        }
    }
}

/// Zeile im Blatt: Name, Abschluss, Fachbereich und je Pruefungsordnung ein Knopf
struct StudyPlanProgramRow: View {
    let program: JSONValue
    let current: String?
    let busy: Bool
    /// als Neben-/Begleitfach gewaehlt
    var minor = false
    let choose: (String) -> Void
    var toggleMinor: (() -> Void)? = nil

    var body: some View {
        let pos = program.list("pos")
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(program.s("program") ?? "").ufFont(14.5, 600).foregroundStyle(UF.text)
                Text(program.s("degree") ?? "").ufFont(13.12).foregroundStyle(UF.muted)
            }
            if let f = program.s("faculty") { Text(f).ufFont(12.48).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true) }
            if let toggleMinor {
                UFButton(minor ? "Begleitfach ✓" : "als Neben-/Begleitfach", size: .small) { toggleMinor() }
                    .disabled(busy)
                    .accessibilityLabel("\(program.s("program") ?? "") als Neben- oder Begleitfach")
                    .accessibilityAddTraits(minor ? .isSelected : [])
            }
            if pos.isEmpty {
                // ohne Katalog trotzdem waehlbar (14.11.2026): der Studienverlauf sagt dann ehrlich, dass er fehlt
                HStack(spacing: 8) {
                    UFButton("Wählen", size: .small) { if let id = program.s("id") { choose(id) } }
                        .disabled(busy)
                        .accessibilityLabel("\(program.s("program") ?? "") wählen, noch ohne Modulkatalog")
                    Text("Für diesen Studiengang gibt es noch keinen Modulkatalog.").ufFont(12.48).foregroundStyle(UF.muted)
                }
            } else {
                UFFlexWrap(gap: 6) {
                    ForEach(Array(pos.enumerated()), id: \.offset) { _, x in
                        if let code = x.s("code") {
                            let on = current == code || current == x.s("po")
                            UFButton("PO \(x.s("po") ?? "")", kind: on ? .primary : .normal, size: .small) { choose(code) }
                                .disabled(busy)
                                .accessibilityLabel("\(program.s("program") ?? "") PO \(x.s("po") ?? "")")
                        }
                    }
                }
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(UF.line).frame(height: 1) }
    }
}

/// Karte "Studierst du jetzt …?": gewaehlt ist ein Studiengang, der Notenspiegel nennt einen neueren (14.11.2026: die
/// Wahl gilt, aber einmal fragen statt still zu ueberschreiben)
struct StudyPlanProgramMismatchCard: View {
    let found: StudyPlanProgramChoice
    let chosen: String
    let source: String
    let busy: Bool
    let switchTo: () -> Void
    let stay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                StudyPlanIconTile(icon: "graduation", pair: CommunityPalette.sky)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Studierst du jetzt \(found.name)?").ufFont(15.2, 650, lh: 1.3).foregroundStyle(UF.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(source) nennt \(found.name)\(found.po.map { " (PO \($0))" } ?? ""), gewählt ist \(chosen).")
                        .ufFont(13.12, lh: 1.4).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            UFFlexWrap(gap: 8) {
                UFButton("Ja, \(found.program)", icon: "check", kind: .primary, size: .small) { switchTo() }.disabled(busy)
                UFButton("Nein, bei \(chosen) bleiben", size: .small) { stay() }.disabled(busy)
            }
            .padding(.leading, 52)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: UF.r).fill(Color.mix(UF.info, 0.07, UF.surface)))
        .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(Color.mix(UF.info, 0.3, UF.line), lineWidth: 1))
        .accessibilityIdentifier("studyplan.mismatch")
    }
}

/// Ein frueherer Studiengang mit seinen Leistungen (wie im Notenspiegel)
struct StudyPlanEarlierStudy: Identifiable, Equatable {
    struct Row: Equatable { let text: String; let note: String?; let status: String?; let credits: String?; let semester: String? }
    let program: String
    let count: Int
    let lp: Double
    let rows: [Row]
    var id: String { program }

    init(_ v: JSONValue) {
        program = v.s("program") ?? "Ohne Angabe"
        count = v.i("count") ?? 0
        lp = v.n("lp") ?? 0
        rows = v.list("rows").map { Row(text: $0.s("text") ?? "", note: $0.s("note"), status: $0.s("status"), credits: $0.s("credits"),
                                        semester: $0.s("semester")) }
    }

    /// "17 Leistungen · 66 LP bestanden"
    var summary: String {
        let lpText = lp == lp.rounded() ? String(Int(lp)) : String(lp).replacingOccurrences(of: ".", with: ",")
        return "\(count) \(count == 1 ? "Leistung" : "Leistungen") · \(lpText) LP bestanden"
    }
}

/// Abschnitt "Früheres Studium" (14.11.2026, Studiengangswechsel): Leistungen anderer Studiengaenge vollstaendig, aber
/// getrennt; sie zaehlen nicht in LP und Studienverlauf des aktuellen Studiengangs
struct StudyPlanEarlierCard: View {
    let studies: [StudyPlanEarlierStudy]
    @State private var open: Set<String> = []

    var body: some View {
        UFCard {
            UFCardHead("Früheres Studium", icon: "graduation")
            Text("Diese Leistungen gehören zu einem anderen Studiengang und zählen hier nicht. Angerechnete Leistungen zählen, sobald der Notenspiegel sie beim aktuellen Studiengang führt.")
                .ufFont(13.12, lh: 1.45).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
            ForEach(studies) { s in
                let isOpen = open.contains(s.id)
                Button { UFMotion.toggle { if isOpen { open.remove(s.id) } else { open.insert(s.id) } } } label: {
                    HStack(spacing: 8) {
                        UFIcon("chevron-right", size: 14).foregroundStyle(UF.muted).rotationEffect(.degrees(isOpen ? 90 : 0))
                        Text(s.program).ufFont(14.5, 600).foregroundStyle(UF.text).frame(maxWidth: .infinity, alignment: .leading)
                        Text(s.summary).ufFont(12.8).monospacedDigit().foregroundStyle(UF.muted)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(isOpen ? "aufgeklappt" : "zugeklappt")
                if isOpen {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(s.rows.enumerated()), id: \.offset) { _, r in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(r.text).ufFont(13.12).foregroundStyle(UF.text).frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text([r.note, r.status, r.credits.map { "\($0) LP" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                    .ufFont(12.48).foregroundStyle(UF.muted)
                            }
                        }
                    }
                    .padding(.leading, 22)
                }
            }
        }
        .accessibilityIdentifier("studyplan.earlier")
    }
}

/// Vorschlag der alten Ordnung (`order_suggestion`)
struct StudyPlanOrderSuggestion: Equatable {
    let code: String
    let since: String
    let startTerm: String
    let program: String
    let degree: String?
    let po: String?
    let url: String

    init?(_ v: JSONValue) {
        guard let code = v.s("code"), let url = v.s("url"), let program = v.s("program") else { return nil }
        self.code = code
        self.url = url
        self.program = program
        since = v.s("since") ?? ""
        startTerm = v.s("start_term") ?? ""
        degree = v.s("degree")
        po = v.s("po")
    }
}

/// Karte "Für dich gilt vermutlich die bisherige Ordnung" (14.11.2026: Sozialpaedagogik gilt ab WiSe 2025/26, wer
/// frueher angefangen hat, studiert nach Sozial- und Organisationspaedagogik weiter); bestaetigen, nicht raten
struct StudyPlanOrderCard: View {
    let suggestion: StudyPlanOrderSuggestion
    let current: String
    let busy: Bool
    let takeOlder: () -> Void
    let keep: () -> Void

    var body: some View {
        let older = suggestion.program + (suggestion.po.map { " (PO \($0))" } ?? "")
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                StudyPlanIconTile(icon: "file-text", pair: CommunityPalette.sky)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Gilt für dich noch die bisherige Ordnung?").ufFont(15.2, 650, lh: 1.3).foregroundStyle(UF.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Du hast im \(suggestion.startTerm) angefangen. \(current) gilt erst ab dem \(suggestion.since); bei früherem Studienbeginn studierst du meist nach „\(older)“ weiter. Ein Wechsel ist auf Antrag möglich.")
                        .ufFont(13.12, lh: 1.4).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            UFFlexWrap(gap: 8) {
                UFButton("Bisherige Ordnung nehmen", icon: "check", kind: .primary, size: .small) { takeOlder() }.disabled(busy)
                UFButton("Bei \(current) bleiben", size: .small) { keep() }.disabled(busy)
            }
            .padding(.leading, 52)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: UF.r).fill(Color.mix(UF.info, 0.07, UF.surface)))
        .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(Color.mix(UF.info, 0.3, UF.line), lineWidth: 1))
        .accessibilityIdentifier("studyplan.order")
    }
}

/// Einstellungen, Abschnitt "Studium": Studiengang mit Neben-/Begleitfach und "Ändern" (14.11.2026)
struct StudyProgramSettingsCard: View {
    @EnvironmentObject private var session: Session
    @State private var main: String?
    @State private var minors: [String] = []
    @State private var picking = false
    let university: String

    var body: some View {
        UFCard {
            UFCardHead("Studiengang", icon: "graduation")
            Text(main.map { "Hauptfach: \($0)" } ?? "Noch nicht gewählt – StudiNow nimmt sonst den Studiengang aus deinem Notenspiegel.")
                .ufFont(13.6).foregroundStyle(main == nil ? UF.muted : UF.text).fixedSize(horizontal: false, vertical: true)
            if !minors.isEmpty {
                Text("Neben- oder Begleitfach: " + minors.joined(separator: ", ")).ufFont(13.12).foregroundStyle(UF.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            UFButton(main == nil ? "Studiengang wählen" : "Studiengang ändern", icon: "list", size: .small) { picking = true }
                .padding(.top, 8)
                .accessibilityIdentifier("settings.program")
        }
        .task { await load() }
        .ufSheet(isPresented: $picking) {
            StudyPlanProgramPicker(api: session.api, current: nil, university: university) { await load() }
        }
    }

    private func load() async {
        guard let api = session.api else { return }
        let s = try? await api.value("/api/study-plan/settings")
        let all = (try? await api.value("/api/study-catalog/programs"))?.list("programs") ?? []
        main = s?.s("po").map { StudyPlanProgramPicker.name(of: $0, in: all) }
        minors = (s?.list("minors") ?? []).compactMap(\.string).map { StudyPlanProgramPicker.name(of: $0, in: all) }
    }
}

/// Link zum LSF-"Studiengangsplan" (14.11.2026): das Wochenraster der Veranstaltungen dieses Semesters, ehrlich so
/// beschriftet (kein Studienverlauf, keine Fachsemester)
struct StudyPlanLSFLink: View {
    let url: URL
    let label: String
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button { openURL(url) } label: {
            HStack(spacing: 6) {
                UFIcon("calendar", size: 14)
                Text(label).ufFont(13.6, 600)
                UFIcon("external-link", size: 12)
            }
            .foregroundStyle(UF.accentText)
            .ufHitArea()
        }
        .buttonStyle(.plain)
        .accessibilityHint("Öffnet das LSF im Browser: Wochenplan der Veranstaltungen, kein Studienverlauf")
        .accessibilityIdentifier("studyplan.lsf")
    }
}

/// Link zum LSF-Wochenraster (`lsf_plan`)
struct StudyPlanLSFRef: Equatable {
    let url: URL
    let label: String
}

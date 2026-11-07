import SwiftUI
import UniFlowCore

// KI-Hilfe fuer das ganze Dokument (05.11.2026, docs/KI-GANZES-DOKUMENT-2026-11-05.md): Umfang "Diese Seite | Ganzes
// Dokument | Seiten …", die Schnellknoepfe "Ganze Vorlesung erklären" und "Alle Aufgaben erklären", die Rueckfrage zu
// den Kosten und der Lauf Schritt fuer Schritt (`POST /api/ai/document/plan`, dann `/step` je Teil). Die Bloecke kommen
// nach und nach in eine Antwort des Gespraechs (Markdown "## Titel [S. 5–7]", damit sie gemerkt werden koennen) und
// tragen ihre Seiten als Knopf: Antippen springt zur Seite.

/// Umfang der KI-Hilfe
enum TutorDocScope: String, CaseIterable, Identifiable {
    case page, document, range

    var id: String { rawValue }

    var title: String {
        switch self {
        case .page: return "Diese Seite"
        case .document: return "Ganzes Dokument"
        case .range: return "Seiten …"
        }
    }
}

/// Reine Regeln der Oberflaeche (UniFlowTests/TutorDocumentAppTests.swift)
enum TutorDocRun {
    /// Die beiden Schnellknoepfe: Modus des Laufs, Beschriftung, Symbol
    static let chips: [(mode: String, label: String, icon: String)] = [
        ("lecture", "Ganze Vorlesung erklären", "book"), ("tasks", "Alle Aufgaben erklären", "check"),
    ]

    /// `scope` fuer den Dienst
    static func scopeJSON(_ scope: TutorDocScope, from: Int, to: Int) -> JSONValue {
        switch scope {
        case .page: return ["kind": "page"]
        case .document: return ["kind": "all"]
        case .range: return ["kind": "range", "from": .number(Double(min(from, to))), "to": .number(Double(max(from, to)))]
        }
    }

    /// Ein Knopf des Reiters "Erklären" bei Umfang "Ganzes Dokument"/"Seiten": Erklaeren, Zusammenfassen, Fachbegriffe
    /// erklaeren die Vorlesung; Aufgabe loesen und Hinweise gehen alle Aufgaben durch. nil = wie bisher fuer die Seite.
    static func docMode(forTutorMode mode: String, scope: TutorDocScope) -> String? {
        guard scope != .page else { return nil }
        switch mode {
        case "explain", "explain_simple", "summary", "terms": return "lecture"
        case "steps", "hints": return "tasks"
        default: return nil
        }
    }

    /// Was im Verlauf als Frage steht
    static func userLabel(mode: String, scope: TutorDocScope, from: Int, to: Int) -> String {
        let what = mode == "tasks" ? "Alle Aufgaben erklären" : "Ganze Vorlesung erklären"
        switch scope {
        case .page: return "\(what) · diese Seite"
        case .document: return "\(what) · ganzes Dokument"
        case .range: return "\(what) · \(DocExplain.rangeWords(min(from, to), max(from, to)))"
        }
    }

    /// Bloecke als Markdown fuer die Antwort im Gespraech ("## Titel [S. 5–7]")
    static func markdown(_ blocks: [DocExplain.Block]) -> String {
        blocks.map { "## \($0.title) [\(DocExplain.pagesLabel($0.from, $0.to))]\n\($0.text)" }.joined(separator: "\n\n")
    }

    /// Bloecke aus der gemerkten Antwort (Gegenstueck zu `markdown`)
    static func blocks(fromMarkdown text: String, mode: String) -> [DocExplain.Block] {
        guard !text.isEmpty else { return [] }
        let step = DocExplain.Step(id: "", n: 1, kind: mode == "doc_tasks" ? "tasks" : "full", from: 1, to: 100_000, title: "", tasks: [],
                                   parts: [], labels: [], hash: "")
        return DocExplain.parseBlocks(text, step: step)
    }

    /// Fortschritt waehrend des Laufs
    static func progress(done: Int, total: Int, title: String) -> String {
        "Teil \(min(done + 1, total)) von \(total) · \(title)"
    }

    /// Herkunft unter der Antwort: alles aus dem Speicher -> "Schon erklärt · 0 Credits"
    static func storedNote(cached: Int, total: Int) -> String? {
        guard total > 0, cached > 0 else { return nil }
        return cached == total ? "Schon erklärt · 0 Credits" : "\(cached) von \(total) Teilen schon erklärt · 0 Credits"
    }

    /// `explain` der Antwort im Gespraech (gemerkt mit dem Gespraech): Zahl der Teile und der schon erklaerten
    static func marker(cached: Int, total: Int) -> JSONValue {
        ["doc": true, "stored": false, "cached_steps": .number(Double(cached)),
         "steps": .number(Double(total))]
    }
}

/// Ablauf eines Laufs: Plan holen, bei Bedarf nach den Kosten fragen, die Teile nacheinander holen
@MainActor
final class TutorDocRunner: ObservableObject {
    enum Phase: Equatable { case idle, confirm, running }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var plan: JSONValue?
    @Published private(set) var progress = ""
    private var request: [String: JSONValue] = [:]
    private var cancelled = false

    var mode: String { plan?["mode"]?.string ?? "lecture" }
    var steps: [JSONValue] { plan?["steps"]?.array ?? [] }

    /// Plan holen. nil = in der Frage steckt kein Wunsch fuers ganze Dokument (dann normale Frage zur Seite).
    func prepare(api: APIClient, fileID: String, page: Int, mode: String?, scope: JSONValue?, question: String?) async throws -> JSONValue? {
        var body: [String: JSONValue] = ["file_id": .string(fileID), "page": .number(Double(page))]
        if let mode { body["mode"] = .string(mode) }
        if let scope { body["scope"] = scope }
        if let question { body["question"] = .string(question) }
        let p = try await api.value("/api/ai/document/plan", method: "POST", body: .object(body))
        guard p["intent"]?.bool == true else { return nil }
        plan = p
        request = ["file_id": .string(fileID), "page": .number(Double(page)), "mode": p["mode"] ?? "lecture", "scope": p["scope"] ?? ["kind": "all"]]
        phase = (p["confirm"]?.bool == true || p["enough"]?.bool == false) ? .confirm : .idle
        return p
    }

    /// Rueckfrage verworfen
    func dismiss() {
        phase = .idle
        plan = nil
    }

    func cancel() { cancelled = true }

    /// Die Teile nacheinander; `update` bekommt nach jedem Teil alle Bloecke bisher und wie viele Teile aus dem
    /// Speicher kamen. Wirft beim ersten Fehler (die bisherigen Bloecke bleiben).
    func run(api: APIClient, force: Bool = false, note: (JSONValue) -> Void = { _ in },
             update: ([DocExplain.Block], _ cached: Int, _ total: Int) -> Void) async throws {
        let steps = self.steps
        guard !steps.isEmpty else { return }
        phase = .running
        cancelled = false
        defer { phase = .idle; progress = "" }
        var blocks: [DocExplain.Block] = []
        var cached = 0
        for (i, s) in steps.enumerated() {
            if cancelled { break }
            progress = TutorDocRun.progress(done: i, total: steps.count, title: s["title"]?.string ?? "")
            var body = request
            body["step"] = s["id"] ?? .null
            body["request_id"] = .string(UUID().uuidString)
            if force { body["force"] = true }
            let r = try await api.value("/api/ai/document/step", method: "POST", body: .object(body))
            note(r)
            if r["stored"]?["stored"]?.bool == true { cached += 1 }
            blocks += (r["blocks"]?.array ?? []).compactMap(DocExplain.Block.init(json:))
            update(blocks, cached, steps.count)
        }
    }

    /// Fuer "Neu erklären lassen": gibt es einen Lauf, der wiederholt werden kann?
    var canRepeat: Bool { plan != nil && !request.isEmpty }
}

/// Umfang ueber den Aktionen des Reiters "Erklären": eine Zeile Segmente, bei "Seiten …" darunter die beiden Felder.
/// Die Schnellknoepfe stehen seit 07.11.2026 vorn in der Aktionsreihe (`TutorDocChips`), damit der Kopf flach bleibt.
struct TutorDocControls: View {
    @Binding var scope: TutorDocScope
    @Binding var from: Int
    @Binding var to: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Segmente nach Inhalt breit (Store-Bilder 05.11.2026: im iPad-Hochformat ist die Leiste 330 pt schmal, gleich
            // breite Segmente kuerzten "Ganzes Dokument" auf "Ganzes Doku…")
            TutorScopeSegments(scope: $scope)
                .accessibilityIdentifier("tutor.scope")
            if scope == .range {
                HStack(spacing: 6) {
                    Text("Seiten").ufFont(12.8).foregroundStyle(UF.muted)
                    pageField($from, id: "tutor.scope.from")
                    Text("bis").ufFont(12.8).foregroundStyle(UF.muted)
                    pageField($to, id: "tutor.scope.to")
                }
            }
        }
    }

    private func pageField(_ value: Binding<Int>, id: String) -> some View {
        TextField("1", value: value, format: .number)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.center)
            .ufFont(13.12)
            .frame(width: 52)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(UF.line, lineWidth: 1))
            .accessibilityIdentifier(id)
    }
}

/// Die beiden Schnellknoepfe "Ganze Vorlesung erklären" und "Alle Aufgaben erklären" (vorn in der Aktionsreihe des
/// Reiters "Erklären"; Kennungen tutor.doc.lecture / tutor.doc.tasks)
struct TutorDocChips: View {
    let busy: Bool
    let start: (_ mode: String) -> Void

    var body: some View {
        ForEach(TutorDocRun.chips, id: \.mode) { c in
            AIModeChip(text: c.label, icon: c.icon, pair: CommunityPalette.mint) { start(c.mode) }
                .disabled(busy)
                .accessibilityIdentifier("tutor.doc.\(c.mode)")
        }
    }
}

/// Umfang als Segmente wie `Picker(.segmented)`, aber je Segment so breit wie sein Titel
/// (`apportionsSegmentWidthsByContent`); der Rest der Breite verteilt sich anteilig. Schrift etwas kleiner als die
/// Vorgabe (Kopf der KI-Hilfe, 07.11.2026), waechst mit Dynamic Type.
struct TutorScopeSegments: UIViewRepresentable {
    @Binding var scope: TutorDocScope

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl(items: TutorDocScope.allCases.map(\.title))
        control.apportionsSegmentWidthsByContent = true
        let font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .systemFont(ofSize: 12.5, weight: .medium))
        control.setTitleTextAttributes([.font: font], for: .normal)
        control.setTitleTextAttributes([.font: UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .systemFont(ofSize: 12.5, weight: .semibold))], for: .selected)
        control.accessibilityLabel = "Umfang"
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return control
    }

    func updateUIView(_ control: UISegmentedControl, context: Context) {
        context.coordinator.scope = $scope
        let i = TutorDocScope.allCases.firstIndex(of: scope) ?? 0
        if control.selectedSegmentIndex != i { control.selectedSegmentIndex = i }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISegmentedControl, context: Context) -> CGSize? {
        let ideal = uiView.intrinsicContentSize
        return CGSize(width: proposal.width ?? ideal.width, height: ideal.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(scope: $scope) }

    final class Coordinator: NSObject {
        var scope: Binding<TutorDocScope>
        init(scope: Binding<TutorDocScope>) { self.scope = scope }

        @objc func changed(_ control: UISegmentedControl) {
            let all = TutorDocScope.allCases
            guard all.indices.contains(control.selectedSegmentIndex) else { return }
            scope.wrappedValue = all[control.selectedSegmentIndex]
        }
    }
}

/// Rueckfrage zu den Kosten und der Fortschritt eines Laufs (unter dem Gespraech)
struct TutorDocRunCard: View {
    @ObservedObject var runner: TutorDocRunner
    let start: () -> Void

    var body: some View {
        switch runner.phase {
        case .confirm:
            VStack(alignment: .leading, spacing: 10) {
                Text(runner.plan?["title"]?.string ?? "Ganzes Dokument").ufFont(14.5, 650, lh: 1.35).foregroundStyle(UF.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(runner.plan?["message"]?.string ?? "").ufFont(13.12, lh: 1.45).foregroundStyle(UF.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("tutor.doc.estimate")
                HStack(spacing: 8) {
                    UFButton("Starten", icon: "sparkles", kind: .primary, size: .small) { start() }
                        .disabled(runner.plan?["enough"]?.bool == false)
                        .accessibilityIdentifier("tutor.doc.start")
                    UFButton("Abbrechen", kind: .ghost, size: .small) { runner.dismiss() }
                        .accessibilityIdentifier("tutor.doc.cancel")
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: UF.r).fill(CommunityPalette.mint.bg.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(CommunityPalette.mint.solid.opacity(0.4), lineWidth: 1))
        case .running:
            HStack(spacing: 8) {
                ProgressView()
                UFShimmerText(runner.progress)
                Spacer(minLength: 4)
                UFButton("Stopp", kind: .ghost, size: .small) { runner.cancel() }.accessibilityIdentifier("tutor.doc.stop")
            }
            .accessibilityIdentifier("tutor.doc.progress")
        case .idle:
            EmptyView()
        }
    }
}

/// Eine Antwort des Laufs: je Block Titel, Seiten als Knopf, Text
struct TutorDocBlocks: View {
    let text: String
    let mode: String
    let explain: JSONValue?
    let open: (_ page: Int) -> Void

    var body: some View {
        let blocks = TutorDocRun.blocks(fromMarkdown: text, mode: mode)
        VStack(alignment: .leading, spacing: 14) {
            ForEach(blocks.indices, id: \.self) { i in
                let b = blocks[i]
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(b.title).ufFont(15.2, 700, lh: 1.3).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button { open(b.from) } label: {
                            Text(DocExplain.pagesLabel(b.from, b.to)).ufFont(12.5, 650).foregroundStyle(UF.accentText)
                                .padding(.vertical, 3).padding(.horizontal, 8)
                                .background(Capsule().fill(UF.accent.opacity(0.1)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Zu \(DocExplain.rangeWords(b.from, b.to)) springen")
                        .accessibilityIdentifier("tutor.doc.page.\(b.from)")
                    }
                    if !b.text.isEmpty { AIMarkdownText(b.text, size: TutorPanel.answerSize) }
                }
                .padding(b.kind == "overview" ? 10 : 0)
                .background(b.kind == "overview" ? RoundedRectangle(cornerRadius: UF.r).fill(CommunityPalette.mint.bg.opacity(0.45)) : nil)
            }
            if let note = TutorDocRun.storedNote(cached: explain?["cached_steps"]?.int ?? 0, total: explain?["steps"]?.int ?? 0) {
                HStack(spacing: 6) {
                    UFIcon("check", size: 13).foregroundStyle(UF.ok)
                    Text(note).ufFont(12, lh: 1.35).foregroundStyle(UF.muted)
                }
                .accessibilityIdentifier("tutor.doc.stored")
            }
        }
        .accessibilityIdentifier("tutor.doc.answer")
    }
}

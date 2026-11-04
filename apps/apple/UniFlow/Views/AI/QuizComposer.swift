import SwiftUI
import UniFlowCore

/// Laufende Erstellung eines Wochentests (03.11.2026): die Seite "Tests & Wiederholung" zeigt dazu Platzhalterkarten
/// mit Zaehler und Phase, der Dialog schliesst sich nach dem Start. Erst wird ein gemeinsamer Test des Moduls gesucht
/// (`shared` im Test), nur ohne einen erstellt die KI 15 Aufgaben. Der Hintergrundauftrag kommt von `POST
/// /api/tests/generate` (`/api/bg`); die Phase hier ist die Erwartung des Nutzers, nicht ein Stand aus dem Backend.
@MainActor
final class TestGenerationState: ObservableObject {
    enum Phase: Equatable { case searching, generating }

    struct Job: Equatable {
        let subject: String
        let weekNo: Int?
        let startedAt: Date
        var phase: Phase = .searching
    }

    static let shared = TestGenerationState()
    /// nach so vielen Sekunden gilt die Suche nach einem gemeinsamen Test als vorbei (sie ist eine Datenbankabfrage)
    static let searchSeconds: Double = 4

    @Published private(set) var job: Job?
    /// Ergebnis des letzten Laufs (Meldung des Backends), bis zum naechsten Start
    @Published private(set) var lastMessage: String?
    private var phaseTask: Task<Void, Never>?

    init() {}

    func start(subject: String, weekNo: Int?, now: Date = Date()) {
        job = Job(subject: subject, weekNo: weekNo, startedAt: now)
        lastMessage = nil
        phaseTask?.cancel()
        phaseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.searchSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.advance()
        }
    }

    /// Nach der Suche: die KI erstellt die Aufgaben
    func advance() { if job != nil { job?.phase = .generating } }

    func finish(message: String? = nil) {
        phaseTask?.cancel()
        job = nil
        lastMessage = message
    }
}

/// Dialog "Wochentest erstellen" (03.11.2026): Modul, Lehrwoche (oder die neuesten Unterlagen), Dauer, die festen
/// Regeln des Wochentests (15 Aufgaben, 4 leicht · 6 mittel · 5 schwer, Multiple Choice · Kurzantwort · Rechnen; nur
/// das bietet das Backend), die Unterlagen, die einfliessen, und die Kostenzeile. "Test erstellen" schickt genau die
/// Parameter, die `POST /api/tests/generate` kennt (module_id, duration_min, week_no); danach sucht das Backend erst
/// einen gemeinsamen Test und laesst nur ohne einen die KI arbeiten.
struct QuizComposer: View {
    let initialModuleID: Int
    @ObservedObject private var ent: Entitlements
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var shell: ShellState
    @Environment(\.ufClose) private var close
    @Environment(\.ufAIEnabled) private var aiEnabled
    @Environment(\.ufChatGPTLink) private var chatgpt
    @ObservedObject private var generation: TestGenerationState
    @State private var modules: [JSONValue] = []
    @State private var detail: JSONValue?
    @State private var loaded = false
    @State private var module = 0
    /// 0 = die neuesten Unterlagen des Moduls
    @State private var week = 0
    @State private var duration = 30
    @State private var starting = false
    @State private var error: String?

    static let durations = [15, 30, 45, 60, 90]
    /// Aufbau nach der Regel vom 29.10.2026 (`AIPromptTexts.weekTestDifficulty`, `weekTestTypes`)
    static let total = 15
    static let composition = "4 leicht · 6 mittel · 5 schwer"
    static let types = ["Multiple Choice", "Kurzantwort", "Rechnen / Programmieren"]

    /// `entitlements: nil` = `Entitlements.shared`, `generation: nil` = `TestGenerationState.shared`
    @MainActor
    init(moduleID: Int, entitlements: Entitlements? = nil, generation: TestGenerationState? = nil) {
        initialModuleID = moduleID
        _ent = ObservedObject(wrappedValue: entitlements ?? .shared)
        _generation = ObservedObject(wrappedValue: generation ?? .shared)
        _module = State(initialValue: moduleID)
    }

    /// Lehrwochen mit Unterlagen, aus denen ein Wochentest entstehen kann (Vorlesung, Übung, Lösung, Skript), neueste zuerst
    static func weeks(_ detail: JSONValue?) -> [JSONValue] {
        (detail?.list("weeks") ?? []).filter { w in (w.i("week") ?? 0) >= 1 && !materials(w).isEmpty }
            .sorted { ($0.i("week") ?? 0) > ($1.i("week") ?? 0) }
    }

    /// Unterlagen einer Woche in der Reihenfolge des Backends (Vorlesung, Skript, Übung, Lösung), hoechstens 10
    static func materials(_ week: JSONValue) -> [JSONValue] {
        Array((week.list("vorlesungen") + week.list("skripte") + week.list("uebungen") + week.list("loesungen")).prefix(10))
    }

    static func docLabel(_ t: String?) -> String {
        switch t {
        case "vorlesung": return "Vorlesung"
        case "uebung": return "Übung"
        case "loesung": return "Lösung"
        case "skript": return "Skript"
        case "klausur": return "Klausur"
        default: return "Unterlage"
        }
    }

    /// Der Dialog lässt sich abschicken: Modul gewaehlt, KI da, nichts laeuft
    var canStart: Bool { module != 0 && aiEnabled && !starting && generation.job == nil }

    private var selectedWeek: JSONValue? { Self.weeks(detail).first { $0.i("week") == week } }

    var body: some View {
        UFDialog("Wochentest erstellen", icon: "exam") {
            if !aiEnabled {
                connect
            } else {
                form
            }
        } foot: {
            UFButton("Abbrechen") { close() }.accessibilityIdentifier("quiz.cancel")
            UFButton(starting ? "Gemeinsamer Test wird gesucht …" : "Test erstellen", icon: starting ? nil : "sparkles", kind: .primary) {
                Task { await start() }
            }
            .disabled(!canStart)
            .accessibilityIdentifier("quiz.start")
        }
        .task { await load() }
        .onChange(of: module) { _, _ in Task { await loadDetail() } }
    }

    @ViewBuilder private var connect: some View {
        if let chatgpt {
            TutorConnectState(link: chatgpt) { close(); router.go(.settings(tab: "advanced")) }.padding(-16)
        } else {
            TutorConnectState.Content(reason: .notConnected, message: nil, busy: false, fix: nil) { close(); router.go(.settings(tab: "advanced")) }
                .padding(-16)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 4) {
            UFField("Modul") {
                if !loaded {
                    Text("Module werden geladen …").ufFont(13.12).foregroundStyle(UF.muted)
                } else if modules.isEmpty {
                    Text("Noch keine Module. Verbinde zuerst Stud.IP bzw. Learnweb.").ufFont(13.12).foregroundStyle(UF.muted)
                        .accessibilityIdentifier("quiz.noModules")
                } else {
                    // nie eine leere Auswahl: ein Menü ohne Eintraege laesst den Bedienungshilfen-Baum dahinter leer
                    UFSelect(options: (module == 0 ? [(0, "– Modul wählen –")] : []) + modules.compactMap { m in m.i("id").map { ($0, m.s("name") ?? "") } },
                             selection: $module, fill: true)
                        .accessibilityIdentifier("quiz.module")
                }
            }
            UFField("Lehrwoche") {
                let weeks = Self.weeks(detail)
                UFSelect(options: [(0, "Neueste Unterlagen des Moduls")] + weeks.map { w in
                    (w.i("week") ?? 0, "\(w.s("label") ?? "Lehrwoche \(w.i("week") ?? 0)")" + ((w.s("topic") ?? "").isEmpty ? "" : " · \(w.s("topic")!)"))
                }, selection: $week, fill: true)
                .accessibilityIdentifier("quiz.week")
            }
            UFField("Dauer") {
                UFFlexWrap(gap: 6, rowGap: 6) {
                    ForEach(Self.durations, id: \.self) { d in
                        AIChoiceChip(text: "\(d) min", on: duration == d) { duration = d }.accessibilityIdentifier("quiz.duration.\(d)")
                    }
                }
            }
            UFField("Aufbau (fest, Regel vom 29.10.)") {
                UFFlexWrap(gap: 6, rowGap: 6) {
                    UFBadge("\(Self.total) Aufgaben", tone: .accent)
                    UFBadge(Self.composition, tone: .neutral)
                    ForEach(Self.types, id: \.self) { UFBadge($0, tone: .info) }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("quiz.composition")
            }
            UFField("Unterlagen, die einfließen") { materialsList }
            Divider().padding(.vertical, 6)
            HStack(spacing: 8) {
                UFIcon("sparkles", size: 14).foregroundStyle(UF.accent)
                Text(costLine).ufFont(12.8).foregroundStyle(UF.muted).accessibilityIdentifier("quiz.cost")
            }
            Text("Gibt es für dieses Modul schon einen gemeinsamen Test (höchstens 3 Varianten je Lehrwoche), bekommst du eine Variante ohne neue KI-Anfrage.")
                .ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
            if let error {
                Text(error).ufFont(13.12).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("quiz.error")
            }
        }
    }

    @ViewBuilder private var materialsList: some View {
        if module == 0 {
            Text("Wähle ein Modul.").ufFont(13.12).foregroundStyle(UF.muted)
        } else if week != 0, let w = selectedWeek {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Row.rows(Self.materials(w))) { row in
                    let f = row.value
                    HStack(spacing: 8) {
                        UFIcon("check", size: 13).foregroundStyle(UF.ok)
                        Text(f.s("ai_title") ?? f.s("title") ?? f.s("name") ?? "").ufFont(13.12).foregroundStyle(UF.text).lineLimit(1)
                        UFBadge(Self.docLabel(f.s("doc_type")), tone: .neutral)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .accessibilityIdentifier("quiz.materials")
        } else {
            Text(detail == nil ? "Unterlagen werden geladen …" : "Die 8 neuesten Unterlagen des Moduls (ohne Organisatorisches).")
                .ufFont(13.12).foregroundStyle(UF.muted)
        }
    }

    private var costLine: String {
        AICost.line(chatgpt: aiEnabled, plan: ent.plan, credits: 10) + " · bei gemeinsamem Test 0 Credits"
    }

    private func load() async {
        guard let api = session.api else { return }
        do {
            modules = try await api.value("/api/modules").items
            if module == 0, modules.count == 1, let only = modules.first?.i("id") { module = only }
            loaded = true
            await loadDetail()
        } catch { self.error = error.localizedDescription }
    }

    private func loadDetail() async {
        guard let api = session.api, module != 0 else { detail = nil; return }
        detail = try? await api.value("/api/modules/\(module)")
        if week != 0, !Self.weeks(detail).contains(where: { $0.i("week") == week }) { week = 0 }
        if week == 0, let newest = Self.weeks(detail).first?.i("week") { week = newest }
    }

    /// `POST /api/tests/generate` mit genau den Parametern des Backends; danach beobachtet die Seite den Auftrag
    private func start() async {
        guard let api = session.api, canStart else { return }
        starting = true
        error = nil
        defer { starting = false }
        var body: [String: JSONValue] = ["module_id": .number(Double(module)), "duration_min": .number(Double(duration))]
        if week != 0 { body["week_no"] = .number(Double(week)) }
        do {
            _ = try await api.value("/api/tests/generate", method: "POST", body: .object(body))
        } catch {
            self.error = error.localizedDescription
            return
        }
        let subject = modules.first { $0.i("id") == module }?.s("name") ?? "Modul"
        generation.start(subject: subject, weekNo: week != 0 ? week : nil)
        AIRecents.shared.count()
        close()
        router.go(.exams)
        Task {
            await shell.pollBackground(toast: toast)
            generation.finish()
        }
    }
}

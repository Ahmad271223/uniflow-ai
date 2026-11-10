import SwiftUI
import UniFlowCore

/// Laufende Erstellung eines Wochentests (03.11.2026): die Seite "Tests & Wiederholung" zeigt dazu Platzhalterkarten
/// mit Zaehler und Phase, der Dialog schliesst sich nach dem Start. In der Standardeinstellung wird erst ein
/// gemeinsamer Test des Moduls gesucht (`shared` im Test), nur ohne einen erstellt die KI die Aufgaben; ein eigener
/// Test (andere Parameter, 04.11.2026) geht gleich zur KI und gibt sich nie als gemeinsam aus. Der Hintergrundauftrag
/// kommt von `POST /api/tests/generate` (`/api/bg`); die Phase hier ist die Erwartung des Nutzers, bis das Backend
/// seinen Stand meldet (`phase` in `/api/bg`).
@MainActor
final class TestGenerationState: ObservableObject {
    /// Stand wie `phase` in `/api/bg` (shared_lookup, shared_wait, generate, shared_adopted)
    enum Phase: Equatable {
        case searching, waiting, generating, adopted

        /// Wert des Backends -> Phase; unbekannte Werte nil
        init?(backend raw: String) {
            switch raw {
            case "shared_lookup": self = .searching
            case "shared_wait": self = .waiting
            case "generate": self = .generating
            case "shared_adopted": self = .adopted
            default: return nil
            }
        }

        /// Zeile unter dem Titel der Platzhalterkarte
        func text(count: Int) -> String {
            switch self {
            case .searching: return "Gemeinsamer Test wird gesucht …"
            case .waiting: return "Jemand erstellt den gemeinsamen Test gerade – kurz warten …"
            case .generating: return "Aufgaben werden erstellt … 0/\(count)"
            case .adopted: return "Gemeinsamer Test gefunden – wird übernommen …"
            }
        }

        /// Hinweis unter den Platzhalterkarten; ein eigener Test sagt das auch
        func note(count: Int, shared: Bool) -> String {
            switch self {
            case .searching: return "Gibt es für dieses Modul schon einen gemeinsamen Test, bekommst du eine Variante ohne neue KI-Anfrage."
            case .waiting: return "Ein anderer Studierender erstellt diesen Test gerade; du bekommst gleich dieselbe Variante (0 Credits)."
            case .generating:
                return (shared ? "" : "Eigener Test, nicht geteilt. ")
                    + "Die KI erstellt \(count) Aufgaben aus den Unterlagen (ca. 1 Minute). Du kannst die Seite derweil verlassen."
            case .adopted: return "Variante eines gemeinsamen Tests, ohne KI-Anfrage – 0 Credits."
            }
        }
    }

    struct Job: Equatable {
        let subject: String
        let weekNo: Int?
        let startedAt: Date
        /// Zahl der Aufgaben (Platzhalterkarten, Zaehler)
        var count: Int = QuizComposer.total
        /// Standardeinstellung: ein gemeinsamer Test ist moeglich; sonst eigener Test (keine Suche, keine Varianten)
        var shared = true
        var phase: Phase = .searching
        /// das Backend hat seinen Stand gemeldet (dann keine Schaetzung mehr)
        var fromBackend = false

        var phaseText: String { phase.text(count: count) }
        var note: String { phase.note(count: count, shared: shared) }
    }

    static let shared = TestGenerationState()
    /// ohne Stand vom Backend gilt die Suche nach so vielen Sekunden als vorbei (sie ist eine Datenbankabfrage)
    static let searchSeconds: Double = 4

    @Published private(set) var job: Job?
    /// Ergebnis des letzten Laufs (Meldung des Backends), bis zum naechsten Start
    @Published private(set) var lastMessage: String?
    private var phaseTask: Task<Void, Never>?

    init() {}

    /// `shared: false` = eigener Test: beginnt gleich bei "Aufgaben werden erstellt", nichts gibt sich als Suche aus
    func start(subject: String, weekNo: Int?, count: Int = QuizComposer.total, shared: Bool = true, now: Date = Date()) {
        job = Job(subject: subject, weekNo: weekNo, startedAt: now, count: count, shared: shared, phase: shared ? .searching : .generating)
        lastMessage = nil
        phaseTask?.cancel()
        guard shared else { return }
        phaseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.searchSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.advance()
        }
    }

    /// Ohne Stand vom Backend nach der Suche: die KI erstellt die Aufgaben
    func advance() { if let j = job, !j.fromBackend { job?.phase = .generating } }

    /// Stand aus `/api/bg` (`phase`); nil oder Unbekanntes aendert nichts
    func apply(backendPhase raw: String?) {
        guard job != nil, let raw, let p = Phase(backend: raw) else { return }
        phaseTask?.cancel()
        job?.phase = p
        job?.fromBackend = true
    }

    func finish(message: String? = nil) {
        phaseTask?.cancel()
        job = nil
        lastMessage = message
    }
}

/// Einstellungen des Dialogs "Wochentest erstellen" (04.11.2026): Zahl der Aufgaben, Schwierigkeit, Aufgabenarten,
/// Thema. Reine Werte ohne Oberflaeche: `isStandard` entscheidet, ob ein GEMEINSAMER Test (hoechstens drei Varianten
/// je Schluessel, 0 Credits beim Uebernehmen) moeglich ist; jede Abweichung ist ein eigener Test des Nutzers mit
/// seiner KI, und der Dialog sagt das so (Vorgabe des Inhabers: nichts gibt sich als geteilt aus, was es nicht ist).
/// Die Regel selbst liegt im Kern (`WeekTestOptions`, wie am PC).
struct QuizSettings: Equatable {
    var count = WeekTestOptions.standard.count
    var difficulty = WeekTestOptions.standard.difficulty
    /// gewaehlte Arten in der Reihenfolge des Backends
    var types = WeekTestOptions.standard.types
    var topic = ""

    static let counts = WeekTestOptions.counts
    static let levels: [(key: String, label: String)] = [("beliebig", "Beliebig"), ("leicht", "Leicht"), ("mittel", "Mittel"), ("schwer", "Schwer")]
    static let typeLabels: [(key: String, label: String)] = [("mc", "Multiple Choice"), ("tf", "Wahr / Falsch"), ("cloze", "Lückentext"),
                                                             ("short", "Kurzantwort"), ("calc", "Rechnen / Programmieren")]

    /// Werte fuer das Backend (`WeekTestOptions`): Thema ohne Leerraum aussen und begrenzt
    var options: WeekTestOptions {
        WeekTestOptions(count: count, difficulty: difficulty, types: WeekTestOptions.allTypes.filter { types.contains($0) },
                        topic: String(topic.trimmingCharacters(in: .whitespacesAndNewlines).prefix(WeekTestOptions.topicChars)))
    }

    /// Nur die Standardeinstellung (15 Aufgaben, beliebig, alle Arten, kein Thema) kann ein gemeinsamer Test sein
    var isStandard: Bool { options.isStandard }

    /// Art an- oder abwaehlen; die letzte bleibt an (mindestens eine Aufgabenart)
    mutating func toggle(_ type: String) {
        if types.contains(type) {
            if types.count > 1 { types.removeAll { $0 == type } }
        } else {
            types = WeekTestOptions.allTypes.filter { $0 == type || types.contains($0) }
        }
    }

    /// Kurzer Aufbau fuer die Anzeige: "15 Aufgaben · 4 leicht · 6 mittel · 5 schwer" bzw. "10 Aufgaben · alle schwer"
    var composition: String {
        let o = options
        if o.difficulty == "beliebig" {
            return "\(o.count) Aufgaben · " + o.distribution.map { "\($0.count) \($0.level)" }.joined(separator: " · ")
        }
        return "\(o.count) Aufgaben · alle \(o.difficulty)"
    }

    /// Was der Nutzer vor dem Start liest: gemeinsam moeglich oder eigener Test
    var shareNote: String {
        isStandard
            ? "Standardeinstellung: Gibt es für dieses Modul schon einen gemeinsamen Test (höchstens 3 Varianten je Lehrwoche), bekommst du eine Variante ohne neue KI-Anfrage."
            : "Eigener Test, nicht geteilt: Mit eigenen Einstellungen erstellt deine KI den Test nur für dich; gemeinsame Varianten gibt es nur in der Standardeinstellung."
    }

    /// Kurzes Etikett im Dialog
    var shareBadge: String { isStandard ? "Gemeinsamer Test möglich" : "Eigener Test, nicht geteilt" }

    /// Rumpf fuer `POST /api/tests/generate`: Modul, Dauer, Lehrwoche (nur wenn gewaehlt) und die Parameter, die das
    /// Backend kennt (count, difficulty, types, topic)
    func body(module: Int, duration: Int, week: Int) -> [String: JSONValue] {
        var body: [String: JSONValue] = ["module_id": .number(Double(module)), "duration_min": .number(Double(duration))]
        if week != 0 { body["week_no"] = .number(Double(week)) }
        for (k, v) in options.json { body[k] = v }
        return body
    }
}

/// Dialog "Wochentest erstellen" (03.11.2026, erweitert 04.11.2026): Modul, Lehrwoche (oder die neuesten Unterlagen),
/// Dauer, Zahl der Aufgaben (5/10/15/20), Schwierigkeit, Aufgabenarten (Multiple Choice, Wahr/Falsch, Lückentext,
/// Kurzantwort, Rechnen/Programmieren), ein Thema oder Hinweis, die Unterlagen, die einfliessen, und die Kostenzeile.
/// "Test erstellen" schickt genau die Parameter, die `POST /api/tests/generate` kennt; in der Standardeinstellung sucht
/// das Backend erst einen gemeinsamen Test, bei eigenen Einstellungen entsteht ein eigener Test (so beschriftet).
/// Ohne PC (lokales Backend) braucht der Dialog eine KI, auf dem iPad die StudiNow-KI, und gehoert darum zu Pro AI
/// (07.11.2026, vorher Plus mit dem eigenen ChatGPT, das aus ist): Free und Plus sehen die Sperrkarte
/// `UFLockedCard(.weeklyTests)` mit dem Weg zu Pro AI; mit Dienst entscheidet er.
struct QuizComposer: View {
    let initialModuleID: Int
    @ObservedObject private var ent: Entitlements
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var shell: ShellState
    @Environment(\.ufClose) private var close
    @Environment(\.ufAIEnabled) private var aiEnabled
    /// StudiNow-KI (Pro AI, Probe) statt eigenem ChatGPT: die Kostenzeile nennt Credits, nie "über dein ChatGPT"
    @Environment(\.ufStudiNowAI) private var studinowAI
    @Environment(\.ufAIAccess) private var aiAccess
    @Environment(\.ufChatGPTLink) private var chatgpt
    @ObservedObject private var generation: TestGenerationState
    @EnvironmentObject private var containers: ContainerManager
    @State private var modules: [JSONValue] = []
    @State private var detail: JSONValue?
    @State private var loaded = false
    /// Modulliste nicht lesbar (Meldung statt "Module werden geladen …" ohne Ende)
    @State private var loadError: String?
    /// Unterlagen des Moduls nicht lesbar
    @State private var detailError: String?
    @State private var module = 0
    /// 0 = die neuesten Unterlagen des Moduls
    @State private var week = 0
    @State private var duration = 30
    @State private var settings = QuizSettings()
    @State private var starting = false
    @State private var error: String?
    /// Rueckmeldung von "Jetzt abgleichen" (Hochschule laeuft los, nichts verbunden)
    @State private var syncNote: String?

    static let durations = [15, 30, 45, 60, 90]
    /// Standard nach der Regel vom 29.10.2026 (`WeekTestOptions.standard`): 15 Aufgaben, 4 leicht · 6 mittel · 5 schwer
    static let total = WeekTestOptions.standard.count

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

    /// Hat das Modul Unterlagen, aus denen ein Test entstehen kann? Eine Lehrwoche mit Materialien oder (fuer "Neueste
    /// Unterlagen") irgendeine Datei des Moduls ausser Organisatorischem, wie `WeekTests.materials` im Backend. Ohne:
    /// klarer Hinweis statt eines Auftrags, der still mit "Keine Materialien" endet (Befund HsH 07.11.2026).
    static func hasMaterials(_ detail: JSONValue?) -> Bool {
        guard let detail else { return false }
        if !weeks(detail).isEmpty { return true }
        return detail.list("files").contains { ($0.s("doc_type") ?? "") != "organisatorisch" }
    }

    /// Hinweis ohne Unterlagen (derselbe Text wie im Backend)
    static let noMaterialsHint = WeekTestOptions.noMaterialsHint

    /// Warum die KI gerade nicht antwortet (Zeile ueber "ChatGPT verbinden"), damit der Dialog nie still bleibt
    static func aiReason(access: StudiNowAIAccess, chatgpt: Bool) -> String {
        switch access {
        case .ready: return chatgpt ? "Die KI ist gerade ausgeschaltet oder nicht verbunden." : "Die StudiNow-KI ist bereit, aber noch nicht angeschlossen – bitte die App neu öffnen."
        case .signInRequired: return "Melde dich einmal mit deinem StudiNow-Konto an, dann erstellt die StudiNow-KI den Test."
        case .planRequired: return "Für Tests braucht es StudiNow Pro AI (oder die Probe) – oder dein eigenes ChatGPT."
        case .unavailable: return "Diese Version hat keinen KI-Dienst. Verbinde dein eigenes ChatGPT."
        }
    }

    /// Meldung des Hintergrundauftrags ohne das Praefix "Test: FEHLER " (`LocalBackgroundJob`), nil wenn kein Fehler
    static func jobFailure(_ bg: JSONValue?) -> String? {
        guard let bg, bg["running"]?.bool != true, let m = bg.s("message"), let r = m.range(of: "FEHLER ") else { return nil }
        let text = String(m[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "Der Test konnte nicht erstellt werden." : text
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

    /// Ohne PC (lokales Backend) nur mit Pro AI (`UFFeature.weeklyTests`); am eigenen Server bzw. mit Dienst ohne Sperre in der App
    private var needsPlus: Bool { session.api?.isLocal != false }
    private var allowed: Bool { !needsPlus || ent.allows(.weeklyTests) }

    /// Unterlagen des gewaehlten Moduls sind da (geladen und nicht leer)
    private var materialsReady: Bool { module != 0 && detail != nil && Self.hasMaterials(detail) }

    /// Der Dialog lässt sich abschicken: Tarif passt, Modul gewaehlt, Unterlagen da, KI da, nichts laeuft
    var canStart: Bool { allowed && module != 0 && materialsReady && aiEnabled && !starting && generation.job == nil }

    private var selectedWeek: JSONValue? { Self.weeks(detail).first { $0.i("week") == week } }

    var body: some View {
        UFDialog("Wochentest erstellen", icon: "exam") {
            if !allowed {
                UFLockedCard(.weeklyTests, entitlements: ent).padding(.vertical, 4)
            } else if !aiEnabled {
                connect
            } else {
                form
            }
        } foot: {
            UFButton("Abbrechen") { close() }.accessibilityIdentifier("quiz.cancel")
            if allowed {
                UFButton(starting ? (settings.isStandard ? "Gemeinsamer Test wird gesucht …" : "Test wird erstellt …")
                            : (error == nil ? "Test erstellen" : "Erneut versuchen"),
                         icon: starting ? nil : (error == nil ? "sparkles" : "refresh"), kind: .primary) {
                    Task { await start() }
                }
                .disabled(!canStart)
                .accessibilityIdentifier("quiz.start")
            }
        }
        .task { await load() }
        .onChange(of: module) { _, _ in Task { await loadDetail() } }
        // nach einem Kauf aus der Sperrkarte heraus die Module nachladen
        .onChange(of: allowed) { _, ok in if ok, !loaded { Task { await load() } } }
        // ein Abgleich ist durch (z. B. "Jetzt abgleichen" von hier): Unterlagen neu lesen
        .ufReload { await loadDetail() }
    }

    @ViewBuilder private var connect: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.aiReason(access: aiAccess, chatgpt: chatgpt != nil))
                .ufFont(13.12).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("quiz.aiReason")
            if let chatgpt {
                TutorConnectState(link: chatgpt) { close(); router.go(.settings(tab: ChatGPTLink.settingsTab)) }.padding(-16)
            } else {
                TutorConnectState.Content(reason: TutorConnectState.reason(nil, access: aiAccess), message: nil, busy: false, fix: nil) { close(); router.go(.settings(tab: ChatGPTLink.settingsTab)) }
                    .padding(-16)
            }
        }
    }

    /// Ohne Unterlagen: der Hinweis und "Jetzt abgleichen" (Hochschule des Containers), "Test erstellen" bleibt aus
    private var noMaterials: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                UFIcon("info", size: 16).foregroundStyle(UF.warn)
                Text(Self.noMaterialsHint).ufFont(13.12).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("quiz.noMaterials")
            UFButton("Jetzt abgleichen", icon: "sync", size: .small) {
                let start = containers.startUniversitySync { syncNote = $0.text }   // LUH: Ergebnis aller Portale
                syncNote = start.text
                if case .notConnected = start { close(); router.go(.settings(tab: "account")) }
            }
            .accessibilityIdentifier("quiz.sync")
            if let syncNote {
                Text(syncNote).ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("quiz.syncNote")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UF.surface2))
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 4) {
            UFField("Modul") {
                if let loadError {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Module konnten nicht geladen werden: \(loadError)").ufFont(13.12).foregroundStyle(UF.bad)
                            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("quiz.loadError")
                        UFButton("Erneut laden", icon: "refresh", size: .small) { Task { await load() } }
                    }
                } else if !loaded {
                    Text("Module werden geladen …").ufFont(13.12).foregroundStyle(UF.muted)
                } else if modules.isEmpty {
                    Text("Noch keine Module. Verbinde zuerst \(UFReleaseUniversities.filePlatforms).").ufFont(13.12).foregroundStyle(UF.muted)
                        .accessibilityIdentifier("quiz.noModules")
                } else {
                    // nie eine leere Auswahl: ein Menü ohne Eintraege laesst den Bedienungshilfen-Baum dahinter leer
                    UFSelect(options: (module == 0 ? [(0, "– Modul wählen –")] : []) + modules.compactMap { m in m.i("id").map { ($0, m.s("name") ?? "") } },
                             selection: $module, fill: true)
                        .accessibilityIdentifier("quiz.module")
                }
            }
            if module != 0, detail != nil, !Self.hasMaterials(detail) {
                noMaterials
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
            UFField("Aufgaben") {
                UFFlexWrap(gap: 6, rowGap: 6) {
                    ForEach(QuizSettings.counts, id: \.self) { n in
                        AIChoiceChip(text: "\(n)", on: settings.count == n) { settings.count = n }
                            .accessibilityLabel("\(n) Aufgaben")
                            .accessibilityIdentifier("quiz.count.\(n)")
                    }
                }
            }
            UFField("Schwierigkeit") {
                UFFlexWrap(gap: 6, rowGap: 6) {
                    ForEach(QuizSettings.levels, id: \.key) { l in
                        AIChoiceChip(text: l.label, on: settings.difficulty == l.key) { settings.difficulty = l.key }
                            .accessibilityIdentifier("quiz.difficulty.\(l.key)")
                    }
                }
            }
            UFField("Aufgabenarten (mindestens eine)") {
                UFFlexWrap(gap: 6, rowGap: 6) {
                    ForEach(QuizSettings.typeLabels, id: \.key) { t in
                        let on = settings.types.contains(t.key)
                        AIChoiceChip(text: t.label, on: on, icon: on ? "check" : nil) { settings.toggle(t.key) }
                            .accessibilityIdentifier("quiz.type.\(t.key)")
                    }
                }
            }
            UFField("Thema oder Hinweise (optional)") {
                UFTextField("z. B. nur Kapitel 3, mehr Beweise, ohne Programmieren", text: $settings.topic)
                    .accessibilityLabel("Thema oder Hinweise")
                    .accessibilityIdentifier("quiz.topic")
            }
            UFField("Aufbau") {
                UFFlexWrap(gap: 6, rowGap: 6) {
                    UFBadge(settings.composition, tone: .accent)
                    UFBadge(settings.shareBadge, tone: settings.isStandard ? .info : .neutral, icon: settings.isStandard ? "users" : "user")
                        .accessibilityIdentifier("quiz.share")
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
            Text(settings.shareNote)
                .ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                .accessibilityIdentifier("quiz.shareNote")
            if let error {
                Text(error).ufFont(13.12).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("quiz.error")
            }
        }
    }

    @ViewBuilder private var materialsList: some View {
        if module == 0 {
            Text("Wähle ein Modul.").ufFont(13.12).foregroundStyle(UF.muted)
        } else if let detailError {
            VStack(alignment: .leading, spacing: 6) {
                Text("Unterlagen konnten nicht geladen werden: \(detailError)").ufFont(13.12).foregroundStyle(UF.bad)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("quiz.detailError")
                UFButton("Erneut laden", icon: "refresh", size: .small) { Task { await loadDetail() } }
            }
        } else if detail != nil, !Self.hasMaterials(detail) {
            Text("Keine Unterlagen – siehe Hinweis oben.").ufFont(13.12).foregroundStyle(UF.muted)
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

    /// Kostenzeile, ehrlich: nur ein gemeinsamer Test kann 0 Credits kosten, ein eigener Test braucht immer die KI
    private var costLine: String {
        AICost.line(chatgpt: aiEnabled && !studinowAI, plan: studinowAI ? .proAI : ent.plan, credits: 10) + (settings.isStandard ? " · bei gemeinsamem Test 0 Credits" : " · eigener Test")
    }

    /// Modulliste; ein Fehler steht sichtbar im Feld "Modul" mit "Erneut laden" (vorher blieb "Module werden geladen …")
    private func load() async {
        guard let api = session.api, allowed else { return }
        loadError = nil
        do {
            modules = try await api.value("/api/modules").items
            if module == 0, modules.count == 1, let only = modules.first?.i("id") { module = only }
            loaded = true
            await loadDetail()
        } catch { loadError = error.localizedDescription }
    }

    /// Unterlagen des Moduls; ein Fehler steht sichtbar bei den Unterlagen (vorher `try?`: still "werden geladen …")
    private func loadDetail() async {
        guard let api = session.api, module != 0 else { detail = nil; return }
        detailError = nil
        do { detail = try await api.value("/api/modules/\(module)") } catch {
            detail = nil
            detailError = error.localizedDescription
            return
        }
        if week != 0, !Self.weeks(detail).contains(where: { $0.i("week") == week }) { week = 0 }
        if week == 0, let newest = Self.weeks(detail).first?.i("week") { week = newest }
    }

    /// `POST /api/tests/generate` mit genau den Parametern des Backends; danach beobachtet die Seite den Auftrag.
    /// Endet der Auftrag sofort mit einem Fehler (keine Unterlagen, Zeitlimit, KI nicht erreichbar), bleibt der Dialog
    /// offen und zeigt ihn mit "Erneut versuchen" (vorher schloss er sich, und die Seite zeigte nichts).
    private func start() async {
        guard let api = session.api, canStart else { return }
        starting = true
        error = nil
        defer { starting = false }
        let body = settings.body(module: module, duration: duration, week: week)
        do {
            _ = try await api.value("/api/tests/generate", method: "POST", body: .object(body))
        } catch {
            self.error = error.localizedDescription
            return
        }
        // sofortiges Ende (Fehler vor der ersten KI-Anfrage, z. B. keine Unterlagen) abfangen, solange der Dialog noch
        // offen ist: bis zu 1,5 s zusehen, laeuft der Auftrag danach noch, beobachtet ihn die Seite
        var probe: JSONValue? = try? await api.value("/api/bg")
        var looks = 0
        while probe?["running"]?.bool == true, looks < 6 {
            looks += 1
            try? await Task.sleep(nanoseconds: 250_000_000)
            probe = try? await api.value("/api/bg")
        }
        if let failed = Self.jobFailure(probe) {
            self.error = failed
            return
        }
        let subject = modules.first { $0.i("id") == module }?.s("name") ?? "Modul"
        generation.start(subject: subject, weekNo: week != 0 ? week : nil, count: settings.count, shared: settings.isStandard)
        AIRecents.shared.count()
        close()
        router.go(.exams)
        Task {
            await shell.pollBackground(toast: toast)
            // Fehler des Auftrags (Zeitlimit, falsche Form, Dienst) bleibt auf der Seite mit "Erneut versuchen"
            generation.finish(message: Self.jobFailure(try? await api.value("/api/bg")))
        }
    }
}

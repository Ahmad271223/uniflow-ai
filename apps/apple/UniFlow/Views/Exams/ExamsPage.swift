import SwiftUI
import UniFlowCore

// Tests & Wiederholung nach viewExams(), runTest() und viewCards() in app/static/views-misc.js; seit 03.11.2026 mit
// dem Dialog "Wochentest erstellen" (QuizComposer), KI-Start, Platzhalterkarten waehrend der Erstellung, gemeinsamen
// Tests (`shared` im Test) und einem Testlauf mit Fortschritt, einer Karte je Aufgabe und einer Ergebnisseite.
// Seit 04.11.2026: Wahr/Falsch und Lueckentext als Aufgabenarten, Erklaerung der KI je Aufgabe aus dem Test selbst,
// eigene Tests sind als "Eigener Test, nicht geteilt" beschriftet, Formeln lesbar (FormulaText).

// Tarif (04.11.2026): ohne Dienst sind "Fehlende Wochentests" (Woche erzeugen) und die automatischen Wochentests
// (UFWeeklyAutoGate) Plus wie "Wochentest erstellen" (QuizComposer); Free sieht das Schloss bzw. ohne Tests die
// Sperrkarte UFLockedCard(.weeklyTests). Vorhandene Tests lesen, durchfuehren und abgeben bleibt in jedem Tarif frei.

/// Tests & Wiederholung: Wochentest erstellen, KI-Start, Statusleiste, Testkarten, Löschen-Dialog.
struct ExamsPage: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var shell: ShellState
    @Environment(\.ufWindowWidth) private var windowWidth
    @ObservedObject private var generation: TestGenerationState
    @ObservedObject private var ent: Entitlements
    @State private var tests: [JSONValue]?
    @State private var mods: [JSONValue] = []
    @State private var dueCards = 0
    @State private var error: String?
    @State private var subject = 0
    /// Tests, die es vor der laufenden Erstellung schon gab (danach den neuen erkennen)
    @State private var knownIDs: Set<Int>?

    /// `generation: nil` = `TestGenerationState.shared`, `entitlements: nil` = `Entitlements.shared`
    @MainActor
    init(generation: TestGenerationState? = nil, entitlements: Entitlements? = nil) {
        _generation = ObservedObject(wrappedValue: generation ?? .shared)
        _ent = ObservedObject(wrappedValue: entitlements ?? .shared)
    }

    /// Ohne Dienst (lokales Backend) gilt der Tarif der App; mit Dienst entscheidet der Dienst
    private var needsPlus: Bool { session.api?.isLocal != false }
    /// neue Wochentests erzeugen (von Hand oder automatisch); vorhandene lesen und durchfuehren ist immer frei
    private var weeklyAllowed: Bool { !needsPlus || ent.allows(.weeklyTests) }

    @ViewBuilder private func plusOnly<V: View>(_ v: V) -> some View {
        if weeklyAllowed { v } else { v.ufRequires(.weeklyTests, entitlements: ent) }
    }

    var body: some View {
        Group {
            if let tests { content(tests) } else if let error { UFContent { UFEmpty(icon: "alert", text: error) } } else {
                UFContent { UFSkeleton().frame(width: 280, height: 28).padding(.bottom, 16); UFSkeleton().frame(height: 300) }
            }
        }
        .task { await load() }
        .ufReload { await load() }
        .onChange(of: generation.job == nil) { _, idle in if idle { Task { await load() } } }
        // Stand des Backends waehrend der Erstellung (`/api/bg` phase): sucht, wartet, KI erstellt, uebernommen
        .onChange(of: shell.backgroundPhase) { _, p in generation.apply(backendPhase: p) }
    }

    private func load() async {
        guard let api = session.api else { error = "Nicht mit dem Server verbunden."; return }
        do {
            async let t = api.value("/api/tests")
            async let m = api.value("/api/modules")
            async let c = api.value("/api/flashcards?due=true")
            let (tv, mv, cv) = try await (t, m, c)
            mods = mv.items
            dueCards = cv.items.count
            if subject == 0 { subject = mods.first?.i("id") ?? 0 }
            let ids = Set(tv.items.compactMap { $0.i("id") })
            if generation.job != nil, knownIDs == nil { knownIDs = ids }
            if generation.job == nil, let known = knownIDs {
                // Erstellung vorbei: ein gemeinsamer Test wurde uebernommen? (Felder vom Dienst, nur wenn vorhanden)
                if let new = tv.items.first(where: { $0.i("id").map { !known.contains($0) } ?? false }), let label = Self.sharedLabel(new) {
                    toast.show("\(label) übernommen – 0 Credits")
                }
                knownIDs = nil
            }
            tests = tv.items
            error = nil
        } catch { if tests == nil { self.error = error.localizedDescription } }
    }

    /// Titel ohne "Wochentest <Fach> – " und ohne "(… Minuten …)"
    static func cleanTitle(_ t: String?) -> String {
        var s = t ?? ""
        if let r = s.range(of: #"^Wochentest\s+[^–-]+[–-]\s*"#, options: .regularExpression) { s.removeSubrange(r) }
        if let r = s.range(of: #"\(.*?Minuten.*?\)"#, options: .regularExpression) { s.removeSubrange(r) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// "Gemeinsamer Test · Variante 2 von 3" aus `shared: {variant, of, adopted}` (Regel des Inhabers: hoechstens 3
    /// Varianten je Modul und Lehrwoche; die Felder liefert der Dienst, ohne sie nichts)
    static func sharedLabel(_ t: JSONValue) -> String? {
        guard let s = t["shared"], !s.isNull, s.object != nil else { return nil }
        guard let v = s.i("variant"), let of = s.i("of") else { return "Gemeinsamer Test" }
        return "Gemeinsamer Test · Variante \(v) von \(of)"
    }

    /// Etikett eines Tests: gemeinsam (Variante) oder ehrlich "Eigener Test, nicht geteilt" (kein `shared`, also ohne
    /// Variante: eigene Einstellungen, kein Dienst oder ohne Inhalts-Hashes)
    static func shareLabel(_ t: JSONValue) -> String { sharedLabel(t) ?? "Eigener Test, nicht geteilt" }

    @ViewBuilder private func content(_ tests: [JSONValue]) -> some View {
        let done = tests.filter { $0["submitted_at"].map { !$0.isNull } == true }
        let avg = done.isEmpty ? 0 : Int((done.reduce(0.0) { $0 + 100 * ($1.n("score") ?? 0) / max(1, $1.n("max_score") ?? 1) } / Double(done.count)).rounded())
        // Gruppen nach Modul + Lehrwoche, neueste Woche zuerst (wie im Web)
        var order: [String] = [], groups: [String: [JSONValue]] = [:]
        let _ = tests.forEach { t in
            let k = "\(t.i("module_id").map(String.init) ?? t.s("subject") ?? ""):\(t.i("week_no").map(String.init) ?? t.s("week_start") ?? "")"
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(t)
        }
        let sorted = order.sorted { (groups[$0]?.first?.s("week_start") ?? "") > (groups[$1]?.first?.s("week_start") ?? "") }
        let flat = sorted.flatMap { groups[$0] ?? [] }
        let byName = Dictionary(mods.map { ($0.s("name") ?? "", $0) }, uniquingKeysWith: { a, _ in a })
        UFContent {
            UFPageHead("Tests & Wiederholung", sub: "Ein gemeinsamer Wochentest pro Modul und Lehrwoche, dazu Karteikarten zum Wiederholen.") {
                UFButton("KI-Start", icon: "sparkles", kind: .ghost, size: .small) { router.go(.aiStart) }.accessibilityIdentifier("exams.aiStart")
                plusOnly(UFButton("Fehlende Wochentests", icon: "refresh", size: .small) { Task { await generateWeek() } }
                    .disabled(generation.job != nil)
                    .accessibilityIdentifier("exams.generateWeek"))
                UFButton("Wochentest erstellen", icon: "plus", kind: .primary, size: .small) { openComposer() }
                    .disabled(generation.job != nil)
                    .accessibilityIdentifier("exams.compose")
            }
            UFFlexWrap(gap: 25.6, rowGap: 8) {                               // .statbar
                statItem("\(tests.count - done.count)", " offene Tests")
                statItem("\(done.count)", " abgeschlossen" + (done.isEmpty ? "" : " · Ø \(avg) %"))
                Button { router.go(.cards) } label: {
                    (Text("\(dueCards)").font(.uf(16.8, 700)) + Text(" Karteikarten fällig →")).foregroundStyle(UF.accentText)
                }
                .buttonStyle(.plain)
            }
            .ufFont(14.4).foregroundStyle(UF.text2)
            .padding(.vertical, 9.6 + ufB).padding(.horizontal, 16 + ufB)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface))
            .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(UF.line, lineWidth: 1))
            .padding(.bottom, 16)
            if let job = generation.job {
                TestGeneratingCard(job: job).padding(.bottom, 16)
            }
            if tests.isEmpty && generation.job == nil && !weeklyAllowed {
                UFLockedCard(.weeklyTests, entitlements: ent)
            } else if tests.isEmpty && generation.job == nil {
                UFCard {
                    UFEmpty(icon: "exam", text: "Noch keine Wochentests. Sie entstehen automatisch pro Modul und Lehrwoche, sobald neue Inhalte da sind, oder mit „Wochentest erstellen“.") {
                        UFButton("Wochentest erstellen", icon: "plus", kind: .primary, size: .small) { openComposer() }.padding(.top, 8)
                    }
                }
            } else if !tests.isEmpty {
                // .test-grid: auto-fill minmax(280px), bis 1366 px zwei Spalten, bis 640 px eine
                let grid = windowWidth <= 640 ? UFGridLayout(columns: 1) : windowWidth <= 1366 ? UFGridLayout(columns: 2) : UFGridLayout(minWidth: 280)
                grid {
                    ForEach(Array(Row.rows(flat).enumerated()), id: \.element.id) { i, row in
                        TestCard(t: row.value, color: byName[row.value.s("subject") ?? ""].flatMap { $0.s("color") }) {
                            overlay.modal { TestDeleteDialog(t: row.value) }
                        }
                        .ufAppear("exams.cards", index: i)
                    }
                }
                .environment(\.ufFillsCell, true)
            }
        }
    }

    private func statItem(_ n: String, _ text: String) -> some View {
        Text(n).font(.uf(16.8, 700)).foregroundColor(UF.text) + Text(text)
    }

    private func openComposer() {
        overlay.modal { QuizComposer(moduleID: subject) }
    }

    private func generateWeek() async {
        guard let api = session.api, weeklyAllowed else { return }
        do {
            _ = try await api.value("/api/tests/generate-week", method: "POST")
            generation.start(subject: "alle Module", weekNo: nil)
            await shell.pollBackground(toast: toast)
            generation.finish()
        } catch { toast.show(error.localizedDescription) }
    }
}

/// Platzhalter waehrend ein Wochentest entsteht: Phase (gemeinsamer Test wird gesucht, dann erstellt die KI die
/// Aufgaben; ein eigener Test beginnt gleich bei der KI), Zaehler, verstrichene Zeit und so viele Karten mit Schimmer
/// wie Aufgaben gewaehlt. Die Phase kommt aus `/api/bg`, davor ist sie die Erwartung; fertig ist der Test, wenn
/// `/api/bg` endet und die Seite neu laedt.
struct TestGeneratingCard: View {
    let job: TestGenerationState.Job
    @Environment(\.ufWindowWidth) private var windowWidth

    /// Text im Chip rechts: Phase, bei der KI mit verstrichener Zeit
    static func chip(_ phase: TestGenerationState.Phase, seconds s: Int) -> String {
        switch phase {
        case .searching: return "sucht"
        case .waiting: return "wartet"
        case .generating: return "KI arbeitet · \(s / 60):\(String(format: "%02d", s % 60))"
        case .adopted: return "0 Credits"
        }
    }

    var body: some View {
        let generating = job.phase == .generating
        UFCard {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wochentest \(UFFmt.shortName(job.subject))" + (job.weekNo.map { " · Lehrwoche \($0)" } ?? "")).ufFont(15.2, 650, em: -0.01).foregroundStyle(UF.text)
                    UFShimmerText(job.phaseText, size: 13.12)
                        .accessibilityIdentifier("exams.generating.phase")
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    TimelineView(.periodic(from: job.startedAt, by: 1)) { ctx in
                        Text(Self.chip(job.phase, seconds: max(0, Int(ctx.date.timeIntervalSince(job.startedAt))))).ufFont(12, 600).monospacedDigit()
                    }
                }
                .foregroundStyle(job.phase == .adopted ? UF.okText : UF.accentText)
                .padding(.vertical, 3).padding(.horizontal, 10)
                .background(Capsule().fill(job.phase == .adopted ? UF.okSoft : UF.accentSoft))
                .accessibilityIdentifier("exams.generating.chip")
            }
            .padding(.bottom, 10)
            let grid = windowWidth <= 640 ? UFGridLayout(columns: 1, spacing: 8) : windowWidth <= 1000 ? UFGridLayout(columns: 3, spacing: 8) : UFGridLayout(columns: 5, spacing: 8)
            grid {
                ForEach(0..<max(1, job.count), id: \.self) { i in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Aufgabe \(i + 1)").ufFont(12, 600).foregroundStyle(UF.muted)
                            Spacer()
                            UFShimmerText(generating ? "wird erstellt …" : "…", size: 11.52)
                        }
                        UFSkeleton().frame(height: 10)
                        UFSkeleton().frame(height: 10).frame(maxWidth: 120)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface2))
                    .ufAppear("exams.generating", index: i)
                }
            }
            Text(job.note).ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("exams.generating")
    }
}

/// .card.test-card: oberer Rand 4 pt in Modulfarbe, Fach, Badge, Löschen, Lehrwoche/Dauer/Aufgaben, Titel, Ergebnis oder Start
struct TestCard: View {
    let t: JSONValue
    let color: String?
    let delete: () -> Void
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufFillsCell) private var fills

    var body: some View {
        let mc = color.map { Color(hex: $0) } ?? UF.accent
        let submitted = t["submitted_at"].map { !$0.isNull } == true
        let pct = submitted ? Int((100 * (t.n("score") ?? 0) / max(1, t.n("max_score") ?? 1)).rounded()) : nil
        let week = t.i("week_no").map { "Lehrwoche \($0)" } ?? t.s("week_start").map { "Woche \(UFFmt.date($0))" } ?? ""
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 9.6) { UFDot(color: mc); Text(UFFmt.shortName(t.s("subject"))).ufFont(14.5, 700).foregroundStyle(UF.text) }
                Spacer()
                HStack(spacing: 2.4) {                                      // .test-head-r
                    if t.i("auto") == 1 { UFBadge("Wochentest", tone: .neutral) } else { UFBadge("manuell", tone: .info) }
                    Button(action: delete) { UFIcon("trash", size: 16).foregroundStyle(UF.muted).frame(width: 40, height: 40).ufHitArea() }
                        .buttonStyle(.plain).accessibilityLabel("Test löschen")
                }
                .padding(.vertical, -5.6).padding(.trailing, -7.2)
            }
            Text("\(week) · \(t.i("duration_min") ?? 0) min · \(t.i("question_count").map(String.init) ?? "?") Aufgaben")
                .ufFont(13.12).foregroundStyle(UF.muted).padding(.vertical, 4.8)
            if let shared = ExamsPage.sharedLabel(t) {
                UFBadge(shared, tone: .info, icon: "users").padding(.bottom, 6).accessibilityIdentifier("exams.shared")
            } else {
                UFBadge(ExamsPage.shareLabel(t), tone: .neutral, icon: "user").padding(.bottom, 6).accessibilityIdentifier("exams.private")
            }
            Text(ExamsPage.cleanTitle(t.s("title"))).ufFont(13.12).foregroundStyle(UF.text)
                .frame(minHeight: 13.12 * 2.6, alignment: .topLeading)
            Spacer(minLength: 0)
            if let pct {
                UFProgress(value: Double(pct) / 100, ok: pct >= 60, color: pct < 60 ? UF.bad : nil).padding(.top, 8).padding(.bottom, 4.8)
                HStack {
                    Text("\(Int((t.n("score") ?? 0).rounded()))/\(Int((t.n("max_score") ?? 0).rounded())) Punkte (\(pct) %)").ufFont(13.12).foregroundStyle(UF.text)
                    Spacer()
                    Button("Ansehen") { router.go(.exam(t.i("id") ?? 0)) }.buttonStyle(UFTestGoStyle(primary: false))
                }
            } else {
                HStack {
                    Text(t["started_at"].map { !$0.isNull } == true ? "begonnen" : "noch nicht gestartet").ufFont(13.12).foregroundStyle(UF.muted)
                    Spacer()
                    Button { router.go(.exam(t.i("id") ?? 0)) } label: {
                        HStack(spacing: 7.2) { UFIcon("play", size: 15); Text(t["started_at"].map { !$0.isNull } == true ? "Fortsetzen" : "Starten") }
                    }
                    .buttonStyle(UFTestGoStyle(primary: true))
                }
                .padding(.top, 8)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 17.6 + 4).padding(.bottom, 17.6 + ufB).padding(.horizontal, 19.2 + ufB)
        .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface))
        .overlay(alignment: .top) { Rectangle().fill(mc).frame(height: 4) }
        .clipShape(RoundedRectangle(cornerRadius: UF.r))
        .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(UF.line, lineWidth: 1))
        .ufShadow(.sm)
    }
}

/// .btn.test-go: min-height 40, padding .5rem 1rem
struct UFTestGoStyle: ButtonStyle {
    let primary: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.uf(14.5, 500))
            .foregroundStyle(primary ? .white : UF.text)
            .padding(.vertical, 8 + ufB).padding(.horizontal, 16 + ufB)
            .frame(minHeight: 40)
            .background(RoundedRectangle(cornerRadius: UF.rSm).fill(primary ? (configuration.isPressed ? UF.accentStrong : UF.accent) : (configuration.isPressed ? UF.surface2 : UF.surface)))
            .overlay(RoundedRectangle(cornerRadius: UF.rSm).strokeBorder(primary ? UF.accent : UF.lineStrong, lineWidth: 1))
            .offset(y: configuration.isPressed ? 1 : 0)
    }
}

/// Modal "Test löschen?" (eigene Rueckfrage statt confirm, wie im Web)
struct TestDeleteDialog: View {
    let t: JSONValue
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var close

    var body: some View {
        UFDialog("Test löschen?") {
            (Text(UFFmt.shortName(t.s("subject"))).font(.uf(14.5, 700)) + Text(" · \(ExamsPage.cleanTitle(t.s("title")))"))
                .ufFont(14.5).foregroundStyle(UF.text).padding(.vertical, 5.6)
            if t.i("auto") == 1 {
                Text("Dieser Wochentest wird danach nicht automatisch neu erstellt. Einen neuen Test legst du jederzeit mit „Wochentest erstellen“ an.")
                    .ufFont(13.12).foregroundStyle(UF.muted).padding(.vertical, 5.6)
            }
            if t["submitted_at"].map({ !$0.isNull }) == true {
                Text("Ergebnis und Antworten werden mit gelöscht.").ufFont(13.12).foregroundStyle(UF.muted).padding(.vertical, 5.6)
            }
        } foot: {
            UFButton("Abbrechen") { close() }
            UFButton("Löschen", icon: "trash", kind: .danger) {
                close()
                Task {
                    do {
                        _ = try await session.api?.value("/api/tests/\(t.i("id") ?? 0)", method: "DELETE")
                        toast.show("Test gelöscht")
                        router.reload()
                    } catch { toast.show("Löschen fehlgeschlagen: " + error.localizedDescription) }
                }
            }
        }
    }
}

// MARK: - Testlauf (runTest)

/// Testlauf (03.11.2026): Fortschritt "n / 15" oben, eine Karte je Aufgabe untereinander, Auswahl deutlich (gruener
/// Rand), zwei grosse Antworten bei Wahr/Falsch (und bei genau zwei Optionen), ein Feld fuer die Luecke beim
/// Lueckentext, Textfeld bei Kurzantwort und Rechnen, unten "Abbrechen" und "Abgeben & bewerten". Nach der Abgabe die
/// Ergebnisseite: Prozent, Balken, "n/15 richtig", je Aufgabe die eigene Antwort (falsch rot mit ✕), die richtige
/// Antwort und die Erklaerung (aus dem Test, dazu die Rueckmeldung der Bewertung). Formeln werden als lesbarer Text
/// gezeigt (FormulaText: Hoch-/Tiefstellung, Wurzel, Brueche), ohne Web-Ansicht.
struct ExamRunPage: View {
    let id: Int
    let task: Int?
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @State private var t: JSONValue?
    @State private var error: String?
    @State private var answers: [String: String] = [:]
    @State private var submitting = false
    /// "Frag die KI zu Aufgabe n": offene KI-Hilfe zu einer falsch beantworteten Aufgabe (quer rechts als Spalte,
    /// schmal als Dialog)
    @State private var ask: ExamAskContext?
    @Environment(\.ufWindowWidth) private var windowWidth

    /// KI-Hilfe als Spalte rechts neben dem Ergebnis (wie im Vorbild), sonst als Dialog
    static func asksInColumn(windowWidth: CGFloat) -> Bool { windowWidth >= 1100 }

    /// Entwurf der Antworten je Server und Test (im Web nur im Speicher, s. Bestandsaufnahme E.8). Gespeichert in den
    /// Einstellungen des Containers (Apple-Nutzer, Hochschule), nie in UserDefaults.standard: ein anderes Konto auf
    /// demselben iPad sieht die Antworten nicht, "Konto löschen" nimmt sie mit.
    private var draftKey: String { "exam-draft:\(session.api?.base.absoluteString ?? ""):\(id)" }
    private var draftStore: UserDefaults { ActiveContainer.current?.defaults ?? .standard }

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if let t { content(t) } else if let error { UFContent { UFEmpty(icon: "alert", text: error) } } else {
                    UFContent { UFSkeleton().frame(width: 280, height: 28).padding(.bottom, 16); UFSkeleton().frame(height: 300) }
                }
            }
            if let ask, Self.asksInColumn(windowWidth: windowWidth) {
                ExamAskPanel(context: ask, close: { self.ask = nil })
                    .id(ask.id)
                    .frame(width: 380)
                    .transition(UFMotion.moves ? .move(edge: .trailing).combined(with: .opacity) : .opacity)
            }
        }
        .background(UF.bg.ignoresSafeArea())
        .animation(UFMotion.animation(reduce: UIAccessibility.isReduceMotionEnabled), value: ask?.id)
        .task(id: id) { await load() }
        .onDisappear { router.examFocus = false }
    }

    /// KI-Hilfe zu einer Aufgabe oeffnen: quer als Spalte rechts, schmal als Dialog
    private func openAsk(_ context: ExamAskContext) {
        if Self.asksInColumn(windowWidth: windowWidth) {
            ask = context
        } else {
            overlay.modal { ExamAskPanel(context: context, close: nil) }
        }
    }

    private func load() async {
        guard let api = session.api else { error = "Nicht mit dem Server verbunden."; return }
        do {
            let v = try await api.value("/api/tests/\(id)")
            var a: [String: String] = [:]
            for (k, x) in v["answers"]?.object ?? [:] { a[k] = x.string ?? "" }
            let submitted = v["submitted_at"].map { !$0.isNull } == true
            if !submitted, let d = draftStore.dictionary(forKey: draftKey) as? [String: String] { a.merge(d) { _, new in new } }
            if submitted { draftStore.removeObject(forKey: draftKey) }
            answers = a
            t = v
            router.examFocus = !submitted                                    // body.exam-focus: Seitenleiste und Kopfzeile aus
        } catch { self.error = error.localizedDescription }
    }

    private func setAnswer(_ nr: String, _ value: String) {
        answers[nr] = value
        draftStore.set(answers, forKey: draftKey)
    }

    static func nrOf(_ q: JSONValue) -> String { q["nr"].map { JSONValue.format($0.double ?? 0) } ?? "" }

    /// Eine Aufgabe gilt als richtig, wenn sie mindestens 60 % ihrer Punkte bekam (wie die Farbe der Chips im Web)
    static func isRight(_ f: JSONValue?) -> Bool? { f.map { ($0.n("points") ?? 0) >= ($0.n("max") ?? 0) * 0.6 } }

    /// Zahl der richtigen Aufgaben aus `per_question`
    static func rightCount(_ fb: JSONValue?) -> Int { (fb?.list("per_question") ?? []).filter { isRight($0) == true }.count }

    @ViewBuilder private func content(_ t: JSONValue) -> some View {
        let qs = t.list("questions")
        let submitted = t["submitted_at"].map { !$0.isNull } == true
        let fb = t["feedback"].flatMap { $0.isNull ? nil : $0 }
        var perQ: [String: JSONValue] = [:]
        let _ = fb?.list("per_question").forEach { if let nr = $0["nr"].map({ JSONValue.format($0.double ?? 0) }) { perQ[nr] = $0 } }
        let answered = qs.filter { !(answers[Self.nrOf($0)] ?? "").isEmpty }.count
        UFContent(maxWidth: 900) {
            UFFlexWrap(gap: 9.6) {
                UFButton(submitted ? "Zurück" : "Abbrechen", icon: "arrow-left", size: .small) { leave() }
                    .accessibilityIdentifier("exam.back")
                VStack(alignment: .leading, spacing: 0) {
                    Text((submitted ? "Ergebnis: " : "Test: ") + ExamsPage.cleanTitle(t.s("title"))).ufFont(14.5, 700).foregroundStyle(UF.text)
                    Text("\(t.s("subject") ?? "") · \(t.i("duration_min") ?? 0) min · \(qs.count) Aufgaben · KI-generiert\(t.i("week_no").map { " · Lehrwoche \($0)" } ?? "")"
                         + " · " + ExamsPage.shareLabel(t))
                        .ufFont(13.12).foregroundStyle(UF.muted)
                }
                UFFlexSpacer()
            }
            .padding(.bottom, 16)
            if submitted, let fb {
                resultCard(fb, questions: qs.count)
            }
            ForEach(Array(qs.enumerated()), id: \.offset) { i, q in
                ExamQuestionCard(q: q, index: i, count: qs.count, submitted: submitted, feedback: perQ[Self.nrOf(q)],
                                 answer: Binding(get: { answers[Self.nrOf(q)] ?? "" }, set: { setAnswer(Self.nrOf(q), $0) }),
                                 asking: ask?.nr == Self.nrOf(q),
                                 onAskAI: submitted ? { openAsk($0) } : nil)
                    .padding(.bottom, 16)
                    .ufAppear("exam.\(id)", index: i)
            }
            if !submitted, !qs.isEmpty {
                HStack {
                    UFButton("Abbrechen", icon: "x") { leave() }
                    Spacer()
                    Text("\(answered) von \(qs.count) beantwortet").ufFont(13.12).foregroundStyle(UF.muted)
                    UFButton(submitting ? "Wird bewertet…" : "Abgeben & bewerten", icon: submitting ? nil : "check", kind: .ok) { Task { await submit(qs) } }
                        .disabled(submitting)
                        .accessibilityIdentifier("exam.submit")
                }
                .padding(.top, 4)
            }
        }
        // Testlauf: Fortschritt und Zeit bleiben oben stehen, waehrend die Aufgaben darunter scrollen
        .safeAreaInset(edge: .top, spacing: 0) {
            if !submitted, !qs.isEmpty {
                HStack(spacing: 18) {
                    progressBar(answered: answered, total: qs.count)
                    ExamTimer(startedAt: t.s("started_at"), minutes: t.i("duration_min") ?? 0)
                }
                .padding(.vertical, 12).padding(.horizontal, 25.6)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
                .background(UF.surface.opacity(0.97))
                .overlay(alignment: .bottom) { Rectangle().fill(UF.line).frame(height: 1) }
            }
        }
    }

    private func leave() {
        router.examFocus = false
        router.go(task != nil ? .plan() : .exams)
    }

    private func progressBar(answered: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("Fortschritt").ufFont(14.5, 650).foregroundStyle(UF.text2)
                Spacer()
                Text("\(answered) / \(total)").ufFont(17.6, 700).foregroundStyle(UF.text).monospacedDigit().ufNumber(answered)
            }
            UFProgress(value: total == 0 ? 0 : Double(answered) / Double(total), height: 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Fortschritt \(answered) von \(total) beantwortet")
        .accessibilityValue("\(answered) / \(total)")
        .accessibilityIdentifier("exam.progress")
    }

    private func resultCard(_ fb: JSONValue, questions: Int) -> some View {
        let total = fb.n("total") ?? 0, max = fb.n("max") ?? 1
        let pct = Int((100 * total / Swift.max(1, max)).rounded())
        let right = Self.rightCount(fb)
        let badge = UFBadge(pct >= 60 ? "Bestanden" : "Nochmal üben", tone: pct >= 60 ? .ok : .bad, icon: pct >= 60 ? "check" : "alert")
        let score = VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(pct) %").font(.uf(36, 800)).foregroundStyle(pct >= 60 ? UF.okText : UF.badText).ufNumber(pct)
                    .accessibilityIdentifier("exam.result.percent")
                Text("\(Int(total.rounded())) / \(Int(max.rounded())) Punkte").ufFont(14.5).foregroundStyle(UF.muted)
            }
            (Text("\(right)/\(questions) richtig").font(.uf(14.5, 650)).foregroundColor(UF.text)
             + Text(" · \(questions - right) zum Nacharbeiten").font(.uf(14.5)).foregroundColor(UF.muted))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("exam.result.right")
        }
        return UFCard {
            // breit: Ring, Zahlen, Etikett rechts; schmal (KI-Hilfe daneben): das Etikett unter den Zahlen
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 18) {
                    ExamScoreRing(percent: pct, passed: pct >= 60)
                    score.fixedSize()
                    Spacer(minLength: 12)
                    badge
                }
                HStack(alignment: .center, spacing: 16) {
                    ExamScoreRing(percent: pct, passed: pct >= 60, size: 72)
                    VStack(alignment: .leading, spacing: 8) { score; badge }
                    Spacer(minLength: 0)
                }
            }
            if let summary = fb.s("summary"), !summary.isEmpty {
                Text(summary).ufFont(14.5).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }
            let weak = fb.list("weak_topics").compactMap(\.string)
            if !weak.isEmpty {
                UFFlexWrap(gap: 6, rowGap: 6) {
                    Text("Nochmal anschauen:").ufFont(13.12, 650).foregroundStyle(UF.text2)
                    ForEach(weak, id: \.self) { UFBadge($0, tone: .warn) }
                }
                .padding(.top, 8)
            }
        }
        .padding(.bottom, 16)
    }

    /// confirm("Test abgeben? …"), POST /api/tests/:id/submit, mit task zusaetzlich Aufgabe erledigt
    private func submit(_ qs: [JSONValue]) async {
        guard let api = session.api else { return }
        let open = qs.filter { (answers[Self.nrOf($0)] ?? "").isEmpty }.count
        guard await overlay.confirm("Test abgeben?\(open > 0 ? " \(open) Aufgaben sind unbeantwortet." : "") Die KI bewertet deine Antworten.") else { return }
        submitting = true
        do {
            _ = try await api.value("/api/tests/\(id)/submit", method: "POST",
                                    body: ["answers": .object(answers.mapValues { .string($0) })])
        } catch {
            toast.show("Bewertung fehlgeschlagen: " + error.localizedDescription, seconds: 5)
            submitting = false
            return
        }
        // abgegeben: der Entwurf ist erledigt, der Stand kommt vom Server. Die Aufgabe des Lernplans ist ein zweiter
        // Schritt; scheitert nur er, sagt die Meldung genau das (vorher "Bewertung fehlgeschlagen", obwohl der Test
        // abgegeben war, und die Aufgabe blieb still offen)
        draftStore.removeObject(forKey: draftKey)
        if let task {
            await toast.attempt("Test abgegeben, Aufgabe im Lernplan abhaken") {
                _ = try await api.value("/api/tasks/\(task)/status", method: "POST", body: ["status": "erledigt"])
            }
        }
        submitting = false
        await load()
    }
}

/// Eine Aufgabe als Karte: Kopf (Aufgabe N · Art · Punkte), Frage, Antwortmoeglichkeiten (Radio mit gruenem Rand bei
/// Auswahl; Wahr/Falsch und genau zwei Optionen als zwei grosse Flaechen), Feld fuer die Luecke oder Textfeld; nach
/// der Abgabe die eigene Antwort (richtig gruen mit Haken, falsch rot mit ✕), "Richtige Antwort" und "Erklärung".
struct ExamQuestionCard: View {
    let q: JSONValue
    let index: Int
    let count: Int
    let submitted: Bool
    let feedback: JSONValue?
    @Binding var answer: String
    /// die KI-Hilfe zu dieser Aufgabe ist gerade offen (Knopf markiert)
    var asking = false
    /// "Frag die KI zu Aufgabe n" (nur nach der Abgabe, nur bei falschen Aufgaben)
    var onAskAI: ((ExamAskContext) -> Void)?

    static func kind(_ type: String?) -> String {
        switch type {
        case "mc": return "Multiple Choice"
        case "tf": return "Wahr / Falsch"
        case "cloze": return "Lückentext"
        case "calc": return "Rechnen / Programmieren"
        default: return "Kurzantwort"
        }
    }

    /// Zwei Optionen (Wahr/Falsch, Ja/Nein): zwei grosse Flaechen nebeneinander
    static func isTwoWay(_ options: [String]) -> Bool { options.count == 2 }

    /// Antwortmoeglichkeiten: bei Wahr/Falsch immer die beiden festen, auch wenn der Test keine mitbringt
    static func choices(type: String?, options: [String]) -> [String] {
        type == "tf" && options.count != 2 ? WeekTestOptions.tfOptions : options
    }

    /// Richtige Antwort zum Anzeigen: beim Lueckentext das Wort fuer die Luecke (`blank`), sonst die Musterloesung
    static func correctAnswer(_ q: JSONValue) -> String {
        if q.s("type") == "cloze", let b = q.s("blank"), !b.trimmingCharacters(in: .whitespaces).isEmpty { return b }
        return q.s("answer") ?? ""
    }

    /// Erklaerung zur Aufgabe: die der KI aus dem Test (`explanation`, 1-3 Saetze); die Rueckmeldung der Bewertung
    /// kommt dazu, wenn sie etwas anderes sagt
    static func explanations(_ q: JSONValue, feedback: JSONValue?) -> (explanation: String?, feedback: String?) {
        let e = (q.s("explanation") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let f = (feedback?.s("feedback") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (e.isEmpty ? nil : e, f.isEmpty || f == e ? nil : f)
    }

    var body: some View {
        let nr = ExamRunPage.nrOf(q)
        let type = q.s("type")
        let options = Self.choices(type: type, options: q.list("options").compactMap(\.string))
        let right = ExamRunPage.isRight(feedback)
        VStack(alignment: .leading, spacing: 0) {
            // Kopf: "Aufgabe 3" gross, "von 15 · Art" daneben, Schwierigkeit und Punkte rechts
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let right {
                        UFIcon(right ? "check" : "x", size: 16).foregroundStyle(right ? UF.okText : UF.badText)
                            .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 2 }
                    }
                    Text("Aufgabe \(nr)").ufFont(20.8, 700, em: -0.01).foregroundStyle(UF.text)
                    Text("von \(count) · \(Self.kind(type))").ufFont(13.12).foregroundStyle(UF.muted)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Aufgabe \(nr) von \(count) · \(Self.kind(type))" + (right == nil ? "" : (right! ? ", richtig" : ", falsch")))
                .accessibilityAddTraits(.isHeader)
                if let d = q.s("difficulty") { UFBadge(d, tone: d == "schwer" ? .warn : .neutral) }
                Spacer()
                Text("\(JSONValue.format(q.n("points") ?? 0)) P.\(feedback.map { " → \(JSONValue.format($0.n("points") ?? 0))" } ?? "")")
                    .ufFont(13.12, feedback == nil ? 500 : 700).foregroundStyle(right == nil ? UF.muted : (right! ? UF.okText : UF.badText))
            }
            .padding(.bottom, 10)
            Text(FormulaText.render(q.s("question") ?? "")).ufFont(17.6, 500).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true).padding(.bottom, 14)
                .textSelection(.enabled)
            if submitted {
                review(options: options)
            } else if type == "mc" || type == "tf" {
                if Self.isTwoWay(options) {
                    HStack(spacing: 10) { ForEach(options, id: \.self) { o in bigOption(o) } }
                } else {
                    ForEach(options, id: \.self) { o in option(o) }
                }
            } else if type == "cloze" {
                UFTextField("Lücke ausfüllen", text: $answer)
                    .accessibilityLabel("Lücke zu Aufgabe \(nr)")
            } else {
                UFTextArea(placeholder: type == "calc" ? "Deine Antwort / Rechenweg" : "Deine Antwort", text: $answer, minHeight: 80)
                    .accessibilityLabel("Antwort zu Aufgabe \(nr)")
            }
        }
        .padding(.vertical, 18 + ufB).padding(.horizontal, 20 + ufB)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(UF.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(right == nil ? UF.line : (right! ? UF.ok : UF.bad), lineWidth: right == nil ? 1 : 1.5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("exam.question.\(nr)")
    }

    private func option(_ o: String) -> some View {
        let on = answer == o
        return Button { answer = o } label: {
            HStack(spacing: 10) {
                UFRadio(on: on).foregroundStyle(on ? UF.ok : UF.muted)
                Text(FormulaText.render(o)).ufFont(14.5, on ? 600 : 400).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8 + ufB).padding(.horizontal, 11.2 + ufB)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: UF.rSm).fill(on ? UF.okSoft : UF.surface))
            .overlay(RoundedRectangle(cornerRadius: UF.rSm).strokeBorder(on ? UF.ok : UF.line, lineWidth: on ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(UFPressStyle())
        .accessibilityAddTraits(on ? .isSelected : [])
        .padding(.vertical, 4)
    }

    private func bigOption(_ o: String) -> some View {
        let on = answer == o
        return Button { answer = o } label: {
            VStack(spacing: 6) {
                UFIcon(on ? "check" : "circle", size: 18).foregroundStyle(on ? UF.okText : UF.muted)
                Text(FormulaText.render(o)).ufFont(15.2, 650).foregroundStyle(on ? UF.okText : UF.text).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 14).padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(RoundedRectangle(cornerRadius: UF.r).fill(on ? UF.okSoft : UF.surface2))
            .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(on ? UF.ok : UF.line, lineWidth: on ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: UF.r))
        }
        .buttonStyle(UFPressStyle())
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Nach der Abgabe: eigene Antwort, richtige Antwort, Erklaerung
    @ViewBuilder private func review(options: [String]) -> some View {
        let right = ExamRunPage.isRight(feedback)
        let given = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = Self.correctAnswer(q)
        let texts = Self.explanations(q, feedback: feedback)
        VStack(alignment: .leading, spacing: 10) {
            if !options.isEmpty {
                ForEach(options, id: \.self) { o in
                    let mine = o == given
                    let correct = Self.matches(option: o, model: model)
                    HStack(spacing: 10) {
                        if mine && right == false { UFIcon("x", size: 15).foregroundStyle(UF.bad) }
                        else if correct || (mine && right == true) { UFIcon("check", size: 15).foregroundStyle(UF.ok) }
                        else { UFIcon("circle", size: 15).foregroundStyle(UF.lineStrong) }
                        Text(FormulaText.render(o)).ufFont(14.5, mine || correct ? 600 : 400)
                            .foregroundStyle(mine && right == false ? UF.badText : (correct ? UF.okText : UF.text2))
                            .underline(mine && right == false, color: UF.bad)
                            .fixedSize(horizontal: false, vertical: true)
                        if mine { UFBadge("deine Antwort", tone: right == false ? .bad : .ok) }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6).padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: UF.rSm).fill(mine && right == false ? UF.badSoft : (correct ? UF.okSoft : .clear)))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel((mine ? "Deine Antwort: " : "") + o + (correct ? ", richtig" : (mine && right == false ? ", falsch" : "")))
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if let right { UFIcon(right ? "check" : "x", size: 14).foregroundStyle(right ? UF.ok : UF.bad) }
                        Text("Deine Antwort").ufFont(12.8, 650).foregroundStyle(right == false ? UF.badText : UF.text2)
                    }
                    Text(given.isEmpty ? "[keine Antwort]" : given).ufFont(14.08).foregroundStyle(given.isEmpty ? UF.muted : UF.text)
                        .underline(right == false && !given.isEmpty, color: UF.bad)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 8).padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: UF.rSm).fill(right == false ? UF.badSoft : UF.surface2))
                .accessibilityElement(children: .combine)
            }
            if !model.isEmpty {
                box(title: "Richtige Antwort", icon: "check", text: FormulaText.render(model), fill: UF.okSoft, tint: UF.okText)
                    .accessibilityIdentifier("exam.answer.\(ExamRunPage.nrOf(q))")
            }
            if let e = texts.explanation {
                box(title: "Erklärung", icon: "info", text: FormulaText.render(e), fill: UF.accentSoft, tint: UF.accentText)
                    .accessibilityIdentifier("exam.explanation.\(ExamRunPage.nrOf(q))")
            }
            if let f = texts.feedback {
                box(title: texts.explanation == nil ? "Erklärung" : "Rückmeldung zur Antwort", icon: "sparkles", text: FormulaText.render(f), fill: UF.accentSoft, tint: UF.accentText)
                    .accessibilityIdentifier("exam.feedback.\(ExamRunPage.nrOf(q))")
            }
            if right == false, let onAskAI {
                let nr = ExamRunPage.nrOf(q)
                Button { onAskAI(ExamAskContext.make(q, given: given, feedback: feedback)) } label: {
                    HStack(spacing: 8) {
                        UFIcon("sparkles", size: 15)
                        Text(ExamAskContext.buttonTitle(nr: nr))
                    }
                    .ufFont(14.08, 600)
                    .foregroundStyle(asking ? Color.white : UF.accentText)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 40)
                    .background(Capsule().fill(asking ? UF.accentFill : UF.accentSoft))
                    .overlay(Capsule().strokeBorder(UF.accent.opacity(asking ? 0 : 0.35), lineWidth: 1))
                    .contentShape(Capsule())
                    .ufHitArea()
                }
                .buttonStyle(UFPressStyle())
                .accessibilityLabel(ExamAskContext.buttonTitle(nr: nr))
                .accessibilityHint("Öffnet die KI-Hilfe mit Aufgabe, deiner Antwort und der richtigen Antwort.")
                .accessibilityAddTraits(asking ? .isSelected : [])
                .accessibilityIdentifier("exam.ask.\(nr)")
                .padding(.top, 2)
            }
        }
    }

    /// Option entspricht der Musterloesung ("B", "B ...", gleicher Text)
    static func matches(option: String, model: String) -> Bool {
        let o = option.trimmingCharacters(in: .whitespaces), m = model.trimmingCharacters(in: .whitespaces)
        guard !o.isEmpty, !m.isEmpty else { return false }
        if o.caseInsensitiveCompare(m) == .orderedSame { return true }
        let letter = String(o.prefix(1)).uppercased()
        let mLetter = String(m.prefix(1)).uppercased()
        if m.count <= 2, letter == mLetter, o.count > 1, o.dropFirst().first.map({ $0 == ")" || $0 == "." || $0 == " " }) ?? false { return true }
        return o.lowercased().hasPrefix(m.lowercased()) || m.lowercased().hasPrefix(o.lowercased())
    }

    private func box(title: String, icon: String, text: String, fill: Color, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) { UFIcon(icon, size: 14).foregroundStyle(tint); Text(title).ufFont(12.8, 650).foregroundStyle(tint) }
            Text(text).ufFont(14.08).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .padding(.vertical, 9.6).padding(.horizontal, 11.2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: UF.rSm).fill(fill))
    }
}

/// #timer: "⏱ m:ss" ab started_at + Dauer, rot unter 5 min, bei 0 einmal Hinweis
struct ExamTimer: View {
    let startedAt: String?
    let minutes: Int
    @EnvironmentObject private var toast: UFToastCenter
    @State private var warned = false

    var body: some View {
        if let start = startedAt.flatMap({ ISO8601DateFormatter.local.date(from: String($0.prefix(19))) }) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let end = start.addingTimeInterval(Double(minutes) * 60)
                let left = max(0, end.timeIntervalSince(ctx.date))
                Text("⏱ \(Int(left) / 60):\(String(format: "%02d", Int(left) % 60))")
                    .font(.uf(16.8, 700)).monospacedDigit()
                    .foregroundStyle(left < 300 ? UF.bad : UF.text)
                    .onChange(of: left <= 0) { _, over in
                        if over && !warned { warned = true; toast.show("Zeit abgelaufen – bitte abgeben.") }
                    }
            }
        } else {
            // ohne Startzeit vom Server keinen Countdown ab der Renderzeit vortaeuschen: nur die Dauer
            Text("⏱ \(minutes) min").font(.uf(16.8, 700)).monospacedDigit().foregroundStyle(UF.text)
        }
    }
}

// Karteikarten (viewCards): CardsPage.swift

// MARK: - Ergebnis: Ring und "Frag die KI zu Aufgabe n" (Neugestaltung 04.11.2026)

/// Ring neben der Prozentzahl: Anteil der Punkte, gruen ab 60 %, sonst rot; in der Mitte Haken bzw. "nochmal"
struct ExamScoreRing: View {
    let percent: Int
    let passed: Bool
    var size: CGFloat = 84

    /// Anteil fuer den Ring (0...1)
    static func fraction(_ percent: Int) -> Double { Double(min(100, max(0, percent))) / 100 }

    var body: some View {
        ZStack {
            Circle().stroke(UF.surface2, lineWidth: 10)
            Circle()
                .trim(from: 0, to: Self.fraction(percent))
                .stroke(passed ? UF.ok : UF.bad, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            UFIcon(passed ? "check" : "refresh", size: 26).foregroundStyle(passed ? UF.okText : UF.badText)
        }
        .frame(width: size, height: size)
        .padding(5)
        .accessibilityHidden(true)
        .accessibilityIdentifier("exam.result.ring")
    }
}

/// Kontext einer falsch beantworteten Aufgabe fuer die KI-Hilfe: Aufgabe, eigene Antwort, richtige Antwort und die
/// Erklaerung aus dem Test. `prompt` ist die erste Frage an die KI (`POST /api/ai/tutor`, mode "ask").
struct ExamAskContext: Identifiable, Equatable {
    let nr: String
    let kind: String
    let question: String
    let given: String
    let correct: String
    let explanation: String?

    var id: String { nr }

    static func buttonTitle(nr: String) -> String { "Frag die KI zu Aufgabe \(nr)" }

    /// aus der Aufgabe des Tests, der eigenen Antwort und der Bewertung
    static func make(_ q: JSONValue, given: String, feedback: JSONValue?) -> ExamAskContext {
        let texts = ExamQuestionCard.explanations(q, feedback: feedback)
        return ExamAskContext(nr: ExamRunPage.nrOf(q), kind: ExamQuestionCard.kind(q.s("type")),
                              question: (q.s("question") ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                              given: given.trimmingCharacters(in: .whitespacesAndNewlines),
                              correct: ExamQuestionCard.correctAnswer(q).trimmingCharacters(in: .whitespacesAndNewlines),
                              explanation: texts.explanation ?? texts.feedback)
    }

    /// Kurzform im Verlauf der KI-Hilfe (statt des ganzen Kontexts)
    var title: String { "Warum ist meine Antwort zu Aufgabe \(nr) falsch?" }

    /// Erste Frage an die KI mit dem ganzen Kontext
    var prompt: String {
        var lines = [
            "Ich habe in meinem Wochentest Aufgabe \(nr) (\(kind)) falsch beantwortet.",
            "",
            "Aufgabe: \(question)",
            "Meine Antwort: \(given.isEmpty ? "(keine Antwort)" : given)",
            "Richtige Antwort: \(correct.isEmpty ? "(nicht angegeben)" : correct)",
        ]
        if let explanation, !explanation.isEmpty { lines.append("Erklärung aus dem Test: \(explanation)") }
        lines += ["", "Erkläre mir kurz und verständlich, warum meine Antwort falsch ist und wie ich auf die richtige Antwort komme."]
        return lines.joined(separator: "\n")
    }

    /// Anschlussfragen nach der ersten Antwort
    static let followUps = ["Erklär es mir einfacher", "Gib mir eine ähnliche Übungsaufgabe", "Welcher Denkfehler steckt dahinter?"]
}

/// KI-Hilfe zum Ergebnis (Vorbild: Chat rechts neben dem Quiz): oben die Aufgabe mit deiner Antwort (rot, ✗) und der
/// richtigen (gruen, ✓), darunter das Gespraech. Fragt dieselbe KI wie die KI-Hilfe im Editor und der KI-Start
/// (`POST /api/ai/tutor`, mode "ask", mit Verlauf), erst nach dem Antippen. Quer als Spalte rechts, schmal als Dialog.
struct ExamAskPanel: View {
    let context: ExamAskContext
    /// Spalte: schliessen; nil = im Dialog (schliesst ueber `ufClose`)
    let close: (() -> Void)?
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var closeDialog
    @Environment(\.ufAIEnabled) private var aiEnabled
    @Environment(\.ufStudoraAccount) private var studoraAccount
    @State private var messages: [Message] = []
    @State private var draft = ""
    @State private var busy = false
    @State private var error: String?

    struct Message: Identifiable, Equatable {
        let id = UUID()
        let user: Bool
        /// Anzeige (bei der ersten Frage die Kurzform)
        let shown: String
        /// an die KI gesendeter Text
        let sent: String
    }

    /// ohne verbundene KI auf dem Geraet fragt nur ein Dienst bzw. eigener Server
    private var canAsk: Bool { aiEnabled || session.api?.isLocal == false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        contextCard
                        if !canAsk { connectHint }
                        ForEach(messages) { m in bubble(m).id(m.id) }
                        if busy {
                            UFShimmerText("Die KI denkt nach …", size: 13.12).padding(.horizontal, 4).id("busy")
                        }
                        if let error {
                            Text(error).ufFont(13.12).foregroundStyle(UF.badText).fixedSize(horizontal: false, vertical: true)
                        }
                        suggestions
                    }
                    .padding(16)
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last { withAnimation(UFMotion.animation(reduce: true)) { proxy.scrollTo(last.id, anchor: .top) } }
                }
            }
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(height: close == nil ? 600 : nil)
        .background(UF.surface.ignoresSafeArea(edges: close == nil ? [] : .vertical))
        .overlay(alignment: .leading) { if close != nil { Rectangle().fill(UF.line).frame(width: 1).ignoresSafeArea(edges: .vertical) } }
        .clipShape(RoundedRectangle(cornerRadius: close == nil ? UF.rLg : 0))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("exam.ask.panel")
    }

    private var head: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(UF.accentSoft)
                UFIcon("sparkles", size: 18).foregroundStyle(UF.accentText)
            }
            .frame(width: 36, height: 36)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("KI-Hilfe").ufFont(16, 700, em: -0.01).foregroundStyle(UF.text)
                Text("Aufgabe \(context.nr) · \(context.kind)").ufFont(12.8).foregroundStyle(UF.muted).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            UFButton(icon: "x", kind: .ghost, size: .small) { if let close { close() } else { closeDialog() } }
                .accessibilityLabel("KI-Hilfe schließen")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(UF.line).frame(height: 1) }
    }

    /// Aufgabe, deine Antwort (rot), richtige Antwort (gruen)
    private var contextCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(FormulaText.render(context.question)).ufFont(14.08, 500).foregroundStyle(UF.text)
                .fixedSize(horizontal: false, vertical: true)
            answerLine(icon: "x", title: "Deine Antwort", text: context.given.isEmpty ? "[keine Antwort]" : context.given, fg: UF.badText, bg: UF.badSoft)
            if !context.correct.isEmpty {
                answerLine(icon: "check", title: "Richtige Antwort", text: context.correct, fg: UF.okText, bg: UF.okSoft)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(UF.surface2))
        .accessibilityElement(children: .combine)
    }

    private func answerLine(icon: String, title: String, text: String, fg: Color, bg: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            UFIcon(icon, size: 13).foregroundStyle(fg)
            (Text(title + ": ").font(.uf(12.8, 650)) + Text(FormulaText.render(text)).font(.uf(13.6)))
                .foregroundStyle(fg)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6).padding(.horizontal, 9)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(bg))
    }

    private var connectHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Für Fragen an die KI verbinde zuerst deine KI in den Einstellungen.").ufFont(13.6).foregroundStyle(UF.text2)
                .fixedSize(horizontal: false, vertical: true)
            UFButton("KI verbinden", icon: "settings", size: .small) {
                if let close { close() } else { closeDialog() }
                router.go(.settings(tab: "advanced"))
            }
        }
    }

    @ViewBuilder private var suggestions: some View {
        if canAsk && !busy {
            let list = messages.isEmpty ? [context.title] : ExamAskContext.followUps
            UFFlexWrap(gap: 6, rowGap: 6) {
                ForEach(list, id: \.self) { s in
                    UFChip(text: s, icon: "sparkles") { Task { await send(s) } }
                        .accessibilityIdentifier(messages.isEmpty ? "exam.ask.start" : "exam.ask.followUp")
                }
            }
        }
    }

    private func bubble(_ m: Message) -> some View {
        HStack {
            if m.user { Spacer(minLength: 40) }
            Group {
                if m.user {
                    Text(m.shown).ufFont(13.6, 500).foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    AIMarkdownText(m.shown).accessibilityIdentifier("exam.ask.answer")
                }
            }
            .padding(.vertical, 9).padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(m.user ? UF.accentFill : UF.surface2))
            if !m.user { Spacer(minLength: 0) }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Frag weiter zu dieser Aufgabe …", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .ufFont(14.5)
                .padding(.vertical, 9).padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(UF.surface2))
                .onSubmit { Task { await send(draft) } }
                .disabled(!canAsk)
            UFButton(icon: "arrow-right", kind: .primary) { Task { await send(draft) } }
                .disabled(!canAsk || busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Senden")
        }
        .padding(12)
        .overlay(alignment: .top) { Rectangle().fill(UF.line).frame(height: 1) }
    }

    /// Frage senden: die erste traegt den ganzen Kontext (`prompt`), weitere den Verlauf
    private func send(_ text: String) async {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let api = session.api, !busy, !q.isEmpty, canAsk else { return }
        let first = messages.isEmpty
        let sent = first ? context.prompt : q
        let history: [JSONValue] = messages.map { ["role": .string($0.user ? "user" : "assistant"), "text": .string($0.sent)] }
        messages.append(Message(user: true, shown: q, sent: sent))
        draft = ""
        busy = true
        error = nil
        defer { busy = false }
        do {
            let r = try await api.value("/api/ai/tutor", method: "POST",
                                        body: ["mode": "ask", "page": 1, "question": .string(sent), "history": .array(history)])
            studoraAccount?.noteAIResponse(r)
            let answer = r.s("answer") ?? ""
            messages.append(Message(user: false, shown: answer, sent: answer))
        } catch {
            _ = studoraAccount?.noteAIError(error)
            self.error = error.localizedDescription
        }
    }
}

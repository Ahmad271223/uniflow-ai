import SwiftUI
import UniFlowCore

// Tests & Wiederholung 1:1 nach viewExams(), runTest() und viewCards() in app/static/views-misc.js.

/// Tests & Wiederholung: Zusatztest, Wochentests erstellen, Statusleiste, Testkarten, Löschen-Dialog.
struct ExamsPage: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var shell: ShellState
    @Environment(\.ufWindowWidth) private var windowWidth
    @State private var tests: [JSONValue]?
    @State private var mods: [JSONValue] = []
    @State private var dueCards = 0
    @State private var error: String?
    @State private var subject = 0
    @State private var duration = 30

    var body: some View {
        Group {
            if let tests { content(tests) } else if let error { UFContent { UFEmpty(icon: "alert", text: error) } } else {
                UFContent { UFSkeleton().frame(width: 280, height: 28).padding(.bottom, 16); UFSkeleton().frame(height: 300) }
            }
        }
        .task { await load() }
        .ufReload { await load() }
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
                UFSelect(options: mods.compactMap { m in m.i("id").map { ($0, UFFmt.shortName(m.s("name"))) } }, selection: $subject)
                UFSelect(options: [15, 30, 45, 60, 90].map { ($0, "\($0) min") }, selection: $duration)
                UFButton("Zusatztest", icon: "plus", size: .small) { Task { await generate() } }
                UFButton("Wochentests erstellen", icon: "sparkles", kind: .primary, size: .small) { Task { await generateWeek() } }
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
            if tests.isEmpty {
                UFCard {
                    UFEmpty(icon: "exam", text: "Noch keine Wochentests. Sie entstehen automatisch pro Modul und Lehrwoche, sobald neue Inhalte da sind, oder manuell unten.")
                }
            } else {
                // .test-grid: auto-fill minmax(280px), bis 1366 px zwei Spalten, bis 640 px eine
                let grid = windowWidth <= 640 ? UFGridLayout(columns: 1) : windowWidth <= 1366 ? UFGridLayout(columns: 2) : UFGridLayout(minWidth: 280)
                grid {
                    ForEach(Row.rows(flat)) { row in
                        TestCard(t: row.value, color: byName[row.value.s("subject") ?? ""].flatMap { $0.s("color") }) {
                            overlay.modal { TestDeleteDialog(t: row.value) }
                        }
                    }
                }
                .environment(\.ufFillsCell, true)
            }
        }
    }

    private func statItem(_ n: String, _ text: String) -> some View {
        Text(n).font(.uf(16.8, 700)).foregroundColor(UF.text) + Text(text)
    }

    private func generate() async {
        guard let api = session.api else { return }
        do {
            _ = try await api.value("/api/tests/generate", method: "POST", body: ["module_id": .number(Double(subject)), "duration_min": .number(Double(duration))])
            toast.show("Zusatztest wird erstellt (ca. 1 Minute)…")
            await shell.pollBackground(toast: toast)
        } catch { toast.show(error.localizedDescription) }
    }

    private func generateWeek() async {
        guard let api = session.api else { return }
        do {
            _ = try await api.value("/api/tests/generate-week", method: "POST")
            toast.show("Fehlende Wochentests werden erstellt…")
            await shell.pollBackground(toast: toast)
        } catch { toast.show(error.localizedDescription) }
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
                    Button(action: delete) { UFIcon("trash", size: 16).foregroundStyle(UF.muted).frame(width: 40, height: 40) }
                        .buttonStyle(.plain).accessibilityLabel("Test löschen")
                }
                .padding(.vertical, -5.6).padding(.trailing, -7.2)
            }
            Text("\(week) · \(t.i("duration_min") ?? 0) min · \(t.i("question_count").map(String.init) ?? "?") Aufgaben")
                .ufFont(13.12).foregroundStyle(UF.muted).padding(.vertical, 4.8)
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
                Text("Dieser Wochentest wird danach nicht automatisch neu erstellt. Einen neuen Test legst du jederzeit mit „Zusatztest“ an.")
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

struct ExamRunPage: View {
    let id: Int
    let task: Int?
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @State private var t: JSONValue?
    @State private var error: String?
    @State private var cur = 0
    @State private var answers: [String: String] = [:]
    @State private var submitting = false
    @State private var warned = false

    /// Entwurf der Antworten je Server und Test (im Web nur im Speicher, s. Bestandsaufnahme E.8)
    private var draftKey: String { "exam-draft:\(session.api?.base.absoluteString ?? ""):\(id)" }

    var body: some View {
        Group {
            if let t { content(t) } else if let error { UFContent { UFEmpty(icon: "alert", text: error) } } else {
                UFContent { UFSkeleton().frame(width: 280, height: 28).padding(.bottom, 16); UFSkeleton().frame(height: 300) }
            }
        }
        .task(id: id) { await load() }
        .onDisappear { router.examFocus = false }
    }

    private func load() async {
        guard let api = session.api else { error = "Nicht mit dem Server verbunden."; return }
        do {
            let v = try await api.value("/api/tests/\(id)")
            var a: [String: String] = [:]
            for (k, x) in v["answers"]?.object ?? [:] { a[k] = x.string ?? "" }
            let submitted = v["submitted_at"].map { !$0.isNull } == true
            if !submitted, let d = UserDefaults.standard.dictionary(forKey: draftKey) as? [String: String] { a.merge(d) { _, new in new } }
            if submitted { UserDefaults.standard.removeObject(forKey: draftKey) }
            answers = a
            t = v
            router.examFocus = !submitted                                    // body.exam-focus: Seitenleiste und Kopfzeile aus
        } catch { self.error = error.localizedDescription }
    }

    private func setAnswer(_ nr: String, _ value: String) {
        answers[nr] = value
        UserDefaults.standard.set(answers, forKey: draftKey)
    }

    @ViewBuilder private func content(_ t: JSONValue) -> some View {
        let qs = t.list("questions")
        let submitted = t["submitted_at"].map { !$0.isNull } == true
        let fb = t["feedback"].flatMap { $0.isNull ? nil : $0 }
        var perQ: [String: JSONValue] = [:]
        let _ = fb?.list("per_question").forEach { if let nr = $0["nr"].map({ JSONValue.format($0.double ?? 0) }) { perQ[nr] = $0 } }
        UFContent(maxWidth: 900) {
            UFFlexWrap(gap: 9.6) {
                UFButton(submitted ? "Zurück" : "Abbrechen", icon: "arrow-left", size: .small) {
                    router.examFocus = false
                    router.go(task != nil ? .plan() : .exams)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(t.s("title") ?? "").ufFont(14.5, 700).foregroundStyle(UF.text)
                    Text("\(t.s("subject") ?? "") · \(t.i("duration_min") ?? 0) min · \(qs.count) Aufgaben · KI-generiert\(t.i("week_no").map { " · Lehrwoche \($0)" } ?? "")")
                        .ufFont(13.12).foregroundStyle(UF.muted)
                }
                UFFlexSpacer()
                if !submitted { ExamTimer(startedAt: t.s("started_at"), minutes: t.i("duration_min") ?? 0) }
            }
            .padding(.bottom, 16)
            if submitted, let fb { resultCard(fb) }
            if !qs.isEmpty {
                UFFlexWrap(gap: 4.8) {                                       // Aufgaben-Chips
                    ForEach(qs.indices, id: \.self) { i in
                        let nr = nrOf(qs[i])
                        let f = perQ[nr]
                        let border: Color? = f.map { ($0.n("points") ?? 0) >= ($0.n("max") ?? 0) * 0.6 ? UF.ok : UF.bad } ?? ((answers[nr] ?? "").isEmpty ? nil : UF.accent)
                        Button { cur = i } label: {
                            Text(nr).ufFont(12.8, i == cur ? 600 : 400)
                                .foregroundStyle(i == cur ? UF.accentText : UF.text2)
                                .padding(.vertical, 4 + ufB).padding(.horizontal, 10.4 + ufB)
                                .background(Capsule().fill(i == cur ? UF.accentSoft : UF.surface))
                                .overlay(Capsule().strokeBorder(border ?? (i == cur ? .clear : UF.line), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 12.8)
                question(qs[min(cur, qs.count - 1)], index: min(cur, qs.count - 1), count: qs.count, submitted: submitted, f: perQ[nrOf(qs[min(cur, qs.count - 1)])])
                HStack {
                    UFButton("Zurück", icon: "chevron-left") { cur -= 1 }.disabled(cur == 0)
                    Spacer()
                    if cur < qs.count - 1 {
                        Button { cur += 1 } label: { HStack(spacing: 7.2) { Text("Weiter"); UFIcon("chevron-right", size: 14) } }
                            .buttonStyle(UFButtonStyle(kind: .primary))
                    } else if !submitted {
                        UFButton(submitting ? "Wird bewertet…" : "Abgeben & bewerten", icon: submitting ? nil : "check", kind: .ok) { Task { await submit(qs) } }
                            .disabled(submitting)
                    }
                }
            }
        }
    }

    private func nrOf(_ q: JSONValue) -> String { q["nr"].map { JSONValue.format($0.double ?? 0) } ?? "" }

    private func resultCard(_ fb: JSONValue) -> some View {
        let total = fb.n("total") ?? 0, max = fb.n("max") ?? 1
        return UFCard {
            (Text("\(Int(total.rounded())) / \(Int(max.rounded())) Punkte ").font(.uf(32, 800)).foregroundColor(UF.text)
             + Text("(\(Int((100 * total / Swift.max(1, max)).rounded())) %)").font(.uf(16)).foregroundColor(UF.muted))
                .ufFont(32, 800)
            Text(fb.s("summary") ?? "").ufFont(14.5).foregroundStyle(UF.text).padding(.vertical, 5.6)
            let weak = fb.list("weak_topics").compactMap(\.string)
            if !weak.isEmpty {
                (Text("Nochmal anschauen: ").font(.uf(13.12, 700)) + Text(weak.joined(separator: ", "))).ufFont(13.12).foregroundStyle(UF.text).padding(.vertical, 5.6)
            }
        }
        .padding(.bottom, 16)
    }

    /// .q: Kopf (Aufgabe N von M · Art, Punkte), Frage, Optionen oder Textfeld, Feedback mit Musterlösung
    private func question(_ q: JSONValue, index: Int, count: Int, submitted: Bool, f: JSONValue?) -> some View {
        let nr = nrOf(q)
        let type = q.s("type")
        let kind = type == "mc" ? "Multiple Choice" : type == "calc" ? "Rechnen / Programmieren" : "Kurzantwort"
        let good = f.map { ($0.n("points") ?? 0) >= ($0.n("max") ?? 0) * 0.6 }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Aufgabe \(nr) von \(count) · \(kind)")
                Spacer()
                Text("\(JSONValue.format(q.n("points") ?? 0)) P.\(f.map { " → \(JSONValue.format($0.n("points") ?? 0))" } ?? "")")
            }
            .ufFont(12.8).foregroundStyle(UF.muted).padding(.bottom, 6.4)
            Text(q.s("question") ?? "").ufFont(16.32).foregroundStyle(UF.text).padding(.bottom, 11.2)
            if type == "mc" {
                ForEach(q.list("options").compactMap(\.string), id: \.self) { o in
                    Button { if !submitted { setAnswer(nr, o) } } label: {
                        HStack(spacing: 8) { UFRadio(on: answers[nr] == o); Text(o).foregroundStyle(UF.text); Spacer(minLength: 0) }
                            .ufFont(14.5)
                            .padding(.vertical, 6.4 + ufB).padding(.horizontal, 9.6 + ufB)
                            .overlay(RoundedRectangle(cornerRadius: UF.rSm).strokeBorder(UF.line, lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(submitted)
                    .padding(.vertical, 4.8)
                }
            } else {
                UFTextArea(placeholder: "Deine Antwort / Rechenweg", text: Binding(get: { answers[nr] ?? "" }, set: { setAnswer(nr, $0) }), minHeight: 80)
                    .disabled(submitted)
            }
            if let f {
                (Text("Feedback: ").font(.uf(14.08, 700)) + Text(f.s("feedback") ?? "") + Text("\n") + Text("Musterlösung: ").font(.uf(14.08, 700)) + Text(q.s("answer") ?? ""))
                    .ufFont(14.08).foregroundStyle(UF.text)
                    .padding(.vertical, 9.6).padding(.horizontal, 11.2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UF.surface2))
                    .padding(.top, 9.6)
            }
        }
        .padding(.vertical, 16 + ufB).padding(.horizontal, 17.6 + ufB)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface))
        .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(good == nil ? UF.line : (good! ? UF.ok : UF.bad), lineWidth: 1))
        .padding(.bottom, 12.8)
    }

    /// confirm("Test abgeben? …"), POST /api/tests/:id/submit, mit task zusaetzlich Aufgabe erledigt
    private func submit(_ qs: [JSONValue]) async {
        guard let api = session.api else { return }
        let open = qs.filter { (answers[nrOf($0)] ?? "").isEmpty }.count
        guard await overlay.confirm("Test abgeben?\(open > 0 ? " \(open) Aufgaben sind unbeantwortet." : "") Die KI bewertet deine Antworten.") else { return }
        submitting = true
        do {
            _ = try await api.value("/api/tests/\(id)/submit", method: "POST",
                                    body: ["answers": .object(answers.mapValues { .string($0) })])
            if let task { _ = try await api.value("/api/tasks/\(task)/status", method: "POST", body: ["status": "erledigt"]) }
            UserDefaults.standard.removeObject(forKey: draftKey)
            submitting = false
            await load()
        } catch {
            toast.show("Bewertung fehlgeschlagen: " + error.localizedDescription, seconds: 5)
            submitting = false
        }
    }
}

/// #timer: "⏱ m:ss" ab started_at + Dauer, rot unter 5 min, bei 0 einmal Hinweis
struct ExamTimer: View {
    let startedAt: String?
    let minutes: Int
    @EnvironmentObject private var toast: UFToastCenter
    @State private var warned = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let end = (startedAt.flatMap { ISO8601DateFormatter.local.date(from: String($0.prefix(19))) } ?? ctx.date).addingTimeInterval(Double(minutes) * 60)
            let left = max(0, end.timeIntervalSince(ctx.date))
            Text("⏱ \(Int(left) / 60):\(String(format: "%02d", Int(left) % 60))")
                .font(.uf(16.8, 700)).monospacedDigit()
                .foregroundStyle(left < 300 ? UF.bad : UF.text)
                .onChange(of: left <= 0) { _, over in
                    if over && !warned { warned = true; toast.show("Zeit abgelaufen – bitte abgeben.") }
                }
        }
    }
}

// MARK: - Karteikarten (viewCards)

struct CardsPage: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var router: UFRouter
    @State private var due: [JSONValue] = []
    @State private var all: [JSONValue] = []
    @State private var loaded = false
    @State private var i = 0
    @State private var shown = false

    var body: some View {
        UFContent(maxWidth: 820) {
            UFPageHead("Karteikarten", sub: "\(due.count) fällig · Leitner-System: richtig = seltener, falsch = morgen wieder.") {
                UFButton("Tests", icon: "arrow-left", size: .small) { router.go(.exams) }
            }
            if i < due.count {
                let c = due[i]
                Text("Karte \(i + 1) von \(due.count) · Fach \(c.i("box") ?? 1) · \(c.s("subject") ?? "")").ufFont(13.12).foregroundStyle(UF.muted).padding(.vertical, 5.6)
                Button { shown = true } label: {                              // .fc-card
                    VStack(spacing: 0) {
                        Text(c.s("question") ?? "").foregroundStyle(UF.text)
                        if shown { Text(c.s("answer") ?? "").foregroundStyle(UF.accentText).padding(.top, 12.8) }
                        else { Text("Klicken zum Aufdecken").ufFont(13.12).foregroundStyle(UF.muted).padding(.top, 9.6) }
                    }
                    .ufFont(16.8)
                    .multilineTextAlignment(.center)
                    .padding(25.6 + ufB)
                    .frame(maxWidth: .infinity, minHeight: 180)
                    .background(RoundedRectangle(cornerRadius: UF.rLg).fill(UF.surface))
                    .overlay(RoundedRectangle(cornerRadius: UF.rLg).strokeBorder(UF.line, lineWidth: 1))
                    .ufShadow(.sm)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if shown {
                    HStack(spacing: 9.6) {
                        UFButton("Falsch", kind: .danger) { Task { await review(c, correct: false) } }
                        UFButton("Richtig", kind: .ok) { Task { await review(c, correct: true) } }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 11.2)
                }
            } else if loaded {
                UFCard { UFEmpty(icon: "check", text: "Heute nichts fällig.") }
            }
            UFCard {
                UFCardHead("Alle Karten") { Text("\(all.count)").ufFont(13.12).foregroundStyle(UF.muted) }
                if all.isEmpty {
                    Text("Noch keine Karten. Erstelle welche im Editor über die KI-Seitenleiste.").ufFont(13.12).foregroundStyle(UF.muted)
                        .frame(maxWidth: .infinity).padding(.vertical, 32)
                } else {
                    let rows = Row.rows(all)
                    ForEach(rows) { row in
                        let c = row.value
                        UFItemRow(c.s("question") ?? "", sub: "\(c.s("answer") ?? "") · Fach \(c.i("box") ?? 1) · fällig \(UFFmt.date(c.s("due")))") {
                            EmptyView()
                        } trailing: {
                            UFButton(icon: "trash", kind: .ghost, size: .small) {
                                Task {
                                    _ = try? await session.api?.value("/api/flashcards/\(c.i("id") ?? 0)", method: "DELETE")
                                    await load()
                                }
                            }
                        }
                        .ufBorderBottom(row.id != rows.last?.id)
                    }
                }
            }
            .padding(.top, 16)
        }
        .task { await load() }
    }

    private func load() async {
        guard let api = session.api else { return }
        due = (try? await api.value("/api/flashcards?due=true"))?.items ?? []
        all = (try? await api.value("/api/flashcards"))?.items ?? []
        i = 0
        shown = false
        loaded = true
    }

    private func review(_ c: JSONValue, correct: Bool) async {
        _ = try? await session.api?.value("/api/flashcards/\(c.i("id") ?? 0)/review", method: "POST", body: ["correct": .bool(correct)])
        i += 1
        shown = false
    }
}

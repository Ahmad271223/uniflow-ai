import SwiftUI
import UniFlowCore

// Vorlesungs-Seitenmarker ("Vorlesung bis hier"), Lernfortschritt & Wochentests, Testdetails, Probeklausur wie
// app/static/views-weekly.js. Dieselben Endpunkte am PC-Server und im lokalen Backend (WeeklyEndpoints).

extension Notification.Name {
    /// Wochentests geaendert (Marker, Takt mit Veroeffentlichung, Einstellungen): offene Boxen laden neu
    static let uniflowWeeklyChanged = Notification.Name("uniflow.weeklyChanged")
}

/// Texte aus views-weekly.js (SRC, when, pct, lecText, pubText)
enum WeeklyText {
    static let sources = ["hoersaaluebung": "Hörsaalübung", "gruppenuebung": "Gruppenübung", "uebungsblatt": "Übungsblatt",
                          "zusatz": "Zusatzübung", "tutorium": "Tutorium", "altklausur": "Altklausur", "loesung": "Musterlösung"]
    static let expectable = ["hoersaaluebung", "gruppenuebung", "uebungsblatt", "zusatz", "tutorium"]

    static func source(_ k: String) -> String { sources[k] ?? k }

    private static let isoF: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Fmt.zone
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    private static let whenF: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.timeZone = Fmt.zone
        f.setLocalizedDateFormatFromTemplate("EEEddMMHHmm")      // "Mi., 21.10., 13:00"
        return f
    }()

    /// when(): Wochentag, Tag, Monat, Uhrzeit; "–" ohne Zeitpunkt (naive Ortszeit Berlin wie am Server)
    static func when(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "–" }
        guard let d = isoF.date(from: String(s.prefix(19))) else { return s }
        return whenF.string(from: d)
    }

    /// pct(): Prozent eines abgegebenen Tests, sonst nil
    static func pct(_ t: JSONValue?) -> Int? {
        guard let t, !t.isNull, t.s("submitted_at") != nil, let max = t.n("max_score"), max != 0 else { return nil }
        return Int((100 * (t.n("score") ?? 0) / max).rounded())
    }

    /// Zahl ohne ".0" (publish_hours kommt als Gleitkommazahl)
    static func number(_ v: Double?) -> String {
        guard let v else { return "–" }
        return v == v.rounded() ? String(Int(v)) : String(v)
    }

    static func lecture(_ pv: JSONValue) -> String {
        guard let l = pv["lecture"], !l.isNull else { return "kein Termin im Stundenplan – Ende wird geschätzt" }
        let room = l.s("room").flatMap { $0.isEmpty ? nil : " · " + $0 } ?? ""
        return "\(l.s("start") ?? "")–\(l.s("end") ?? "")\(room) (Stundenplan)"
    }

    static func publish(_ pv: JSONValue) -> (when: String, detail: String) {
        ("voraussichtlich \(when(pv.s("publish_at")))",
         "(\(number(pv.n("publish_hours"))) h nach Vorlesungsende, Lehrwoche \(pv.i("week_no") ?? 0))")
    }

    static func range(_ m: JSONValue) -> String {
        let r = m.list("page_range")
        return "S. \(r.first?.int ?? m.i("page") ?? 0)–\(m.i("page") ?? 0)"
    }
}

// MARK: - Modulübersicht: Lernfortschritt & Wochentests (renderWeeklyBox)

struct WeeklyTestsCard: View {
    let module: JSONValue
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var shell: ShellState
    @Environment(\.ufAIEnabled) private var aiEnabled
    @State private var d: JSONValue?
    @State private var error: String?

    private var moduleID: Int { module.i("id") ?? 0 }
    /// Erzeugen und Bewerten brauchen die KI: am PC-Server immer, lokal nur mit verbundenem ChatGPT-Abo
    private var canGenerate: Bool { session.api?.isLocal == false || aiEnabled }

    var body: some View {
        UFCard {
            UFCardHead("Lernfortschritt & Wochentests", icon: "exam", wrap: true) {
                HStack(spacing: 4.8) {
                    if canGenerate {
                        UFButton("Probeklausur", icon: "sparkles", size: .small) { overlay.modal { MockExamDialog(module: module) } }
                            .accessibilityIdentifier("weekly.mock")
                    }
                    UFButton(icon: "settings", kind: .ghost, size: .small) {
                        if let s = d?["settings"] { overlay.modal { WeeklySettingsDialog(module: module, settings: s) } }
                    }
                    .accessibilityLabel("Einstellungen für Wochentests")
                    .disabled(d == nil)
                }
            }
            if let error {
                Text("Wochentests nicht geladen: \(error)").ufFont(13.12).foregroundStyle(UF.muted)
            } else if let d {
                content(d)
            } else {
                Text("Lade Wochentests…").ufFont(13.12).foregroundStyle(UF.muted)
            }
        }
        .padding(.bottom, 14.4)
        .accessibilityIdentifier("weekly.box")
        .task(id: moduleID) { await load() }
        .ufReload { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .uniflowWeeklyChanged)) { _ in Task { await load() } }
    }

    private func load() async {
        guard let api = session.api else { error = "Nicht mit dem Server verbunden."; return }
        do {
            let v = try await api.value("/api/weekly/module/\(moduleID)")
            guard !Task.isCancelled else { return }
            d = v
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            if d == nil { self.error = error.localizedDescription }
        }
    }

    @ViewBuilder private func content(_ d: JSONValue) -> some View {
        let review = d.list("needs_review").count
        if review > 0 {
            HStack(spacing: 6) {
                UFIcon("alert", size: 14)
                Text("\(review) Marker nach Dokumentänderung prüfen – der betroffene Stoff zählt bis dahin nicht.")
            }
            .ufFont(13.6).foregroundStyle(UF.warn)
            .padding(.vertical, 7.2).padding(.horizontal, 11.2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(UF.warnSoft))
            .padding(.bottom, 8)
        }
        VStack(spacing: 0) {
            ForEach(Array(rows(d).enumerated()), id: \.offset) { n, r in
                if n > 0 { Divider().overlay(UF.line) }
                row(r.week, r.plan)
            }
        }
        let mocks = d.list("mock_exams")
        if !mocks.isEmpty {
            UFFlexWrap(gap: 6, rowGap: 4) {
                Text("Probeklausuren:").ufFont(13.6, 650).foregroundStyle(UF.text)
                ForEach(Array(mocks.enumerated()), id: \.offset) { _, m in
                    Button {
                        if let id = m["test"]?.i("id") { router.go(.exam(id)) }
                    } label: {
                        Text((m.s("title") ?? "Probeklausur") + (WeeklyText.pct(m["test"]).map { " (\($0) %)" } ?? ""))
                            .ufFont(13.6).foregroundStyle(UF.accentText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 9.6)
        }
        Text("Ein gemeinsamer Test pro Lehrwoche, \(WeeklyText.number(d["settings"]?.n("publish_hours"))) h nach Vorlesungsende, nur aus Stoff bis zum Marker. Spätere Uploads kommen als Nachtrag dazu, der Test selbst bleibt unverändert.")
            .ufFont(12).foregroundStyle(UF.muted).padding(.top, 9.6)
    }

    private struct Line { let week: JSONValue; let plan: JSONValue? }

    /// je Woche ihre Plaene (Teil 1, 2 …), ohne Plan eine leere Zeile
    private func rows(_ d: JSONValue) -> [Line] {
        d.list("weeks").flatMap { w -> [Line] in
            let plans = w.list("plans")
            return plans.isEmpty ? [Line(week: w, plan: nil)] : plans.map { Line(week: w, plan: $0) }
        }
    }

    private func row(_ w: JSONValue, _ p: JSONValue?) -> some View {
        let label = "Woche \(w.i("week") ?? 0)" + ((p?.i("part") ?? 1) > 1 ? " · Teil \(p?.i("part") ?? 1)" : "")
        let topic = w.s("topic").flatMap { $0.isEmpty ? nil : $0 } ?? p?.s("topic").flatMap { $0.isEmpty ? nil : $0 } ?? "–"
        let status = p == nil ? (w.s("status") ?? "") : (p?.s("status_text") ?? "")
        let pages = (p?.list("pages") ?? []).map { "S. \($0.i("from") ?? 0)–\($0.i("to") ?? 0)" }.joined(separator: ", ")
        var sub = status
        if !pages.isEmpty { sub += " · " + pages }
        if let n = p?.i("question_count"), n > 0 { sub += " · \(n) Aufgaben" }
        let info = VStack(alignment: .leading, spacing: 1.6) {
            Text(topic).ufFont(14.4, p == nil ? 500 : 650).foregroundStyle(p == nil ? UF.muted : UF.text).lineLimit(1)
            Text(sub).ufFont(12.8).foregroundStyle(UF.muted)
            ForEach(Array((p?.list("nachtraege") ?? []).enumerated()), id: \.offset) { _, n in
                Button {
                    if let id = n["test"]?.i("id") { router.go(.exam(id)) }
                } label: {
                    HStack(spacing: 4) {
                        UFIcon("plus", size: 12)
                        Text("Nachtrag: \(n.s("title") ?? "ergänzende Aufgaben")" + (WeeklyText.pct(n["test"]).map { " · \($0) %" } ?? ""))
                    }
                    .ufFont(12.8).foregroundStyle(UF.accentText)
                }
                .buttonStyle(.plain)
            }
        }
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 11.2) {
                Text(label).ufFont(13.6, 600).foregroundStyle(UF.text2).frame(width: 92, alignment: .leading)
                info.frame(maxWidth: .infinity, alignment: .leading)
                actions(w, p).fixedSize()
            }
            VStack(alignment: .leading, spacing: 4.8) {
                Text(label).ufFont(13.6, 600).foregroundStyle(UF.text2)
                info
                actions(w, p)
            }
        }
        .padding(.vertical, 8.8)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func actions(_ w: JSONValue, _ p: JSONValue?) -> some View {
        HStack(spacing: 5.6) {
            if let p {
                switch p.s("status") {
                case "veroeffentlicht":
                    let t = p["test"].flatMap { $0.isNull ? nil : $0 }
                    if let pc = WeeklyText.pct(t) { UFBadge("\(pc) %", tone: pc >= 60 ? .ok : .bad) }
                    let done = t?.s("submitted_at") != nil
                    UFButton(done ? "Ergebnis" : "Starten", icon: done ? nil : "play", kind: done ? .normal : .primary, size: .small) {
                        Task { await open(test: t, defID: p.i("def_id")) }
                    }
                    if let def = p.i("def_id") {
                        UFButton("Details", kind: .ghost, size: .small) { overlay.modal { WeeklyDefDialog(id: def) } }
                    }
                case "wartet":
                    Text("wartet auf \(p.list("missing").compactMap(\.string).map(WeeklyText.source).joined(separator: ", ")) · spätestens \(WeeklyText.when(p.s("deadline_at")))")
                        .ufFont(12.8).foregroundStyle(UF.muted)
                case "fehlgeschlagen":
                    HStack(spacing: 4) { UFIcon("alert", size: 13); Text("nicht freigegeben") }
                        .ufFont(12.8).foregroundStyle(UF.bad)
                        .help(p.s("error") ?? "")
                        .accessibilityHint(p.s("error") ?? "")
                    if canGenerate { UFButton("Erneut versuchen", kind: .ghost, size: .small) { Task { await retry() } } }
                default:
                    HStack(spacing: 4) { UFIcon("clock", size: 13); Text("erscheint \(WeeklyText.when(p.s("publish_at")))") }
                        .ufFont(12.8).foregroundStyle(UF.muted)
                }
            } else if !w.list("markers").isEmpty {
                Text("Marker gesetzt").ufFont(12.8).foregroundStyle(UF.muted)
            } else {
                HStack(spacing: 4) { UFIcon("bookmark", size: 13); Text("im Skript „Vorlesung bis hier“ setzen") }
                    .ufFont(12.8).foregroundStyle(UF.muted)
            }
        }
    }

    /// Test oeffnen; fehlt der eigene Versuch noch, ihn zuerst anlegen (POST /api/weekly/defs/{id}/attempt)
    private func open(test: JSONValue?, defID: Int?) async {
        if let id = test?.i("id") { router.go(.exam(id)); return }
        guard let api = session.api, let defID else { return }
        do {
            let r = try await api.value("/api/weekly/defs/\(defID)/attempt", method: "POST")
            if let id = r.i("test_id") { router.go(.exam(id)) }
        } catch { toast.show(error.localizedDescription, seconds: 5) }
    }

    private func retry() async {
        guard let api = session.api else { return }
        do {
            _ = try await api.value("/api/weekly/tick", method: "POST")
            toast.show("Wird erneut versucht…")
            await shell.pollBackground(toast: toast)
            NotificationCenter.default.post(name: .uniflowWeeklyChanged, object: nil)
        } catch { toast.show(error.localizedDescription) }
    }
}

// MARK: - Testdetails (defDetails)

struct WeeklyDefDialog: View {
    let id: Int
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var close
    @State private var d: JSONValue?
    @State private var error: String?

    var body: some View {
        UFDialog("Testdetails", icon: "exam") {
            if let error {
                Text("Fehler: \(error)").ufFont(14.4).foregroundStyle(UF.bad)
            } else if let d {
                details(d)
            } else {
                Text("Lade…").ufFont(14.4).foregroundStyle(UF.muted)
            }
        } foot: {
            UFButton("Schließen") { close() }
        }
        .task { await load() }
    }

    private func load() async {
        guard let api = session.api else { error = "Nicht mit dem Server verbunden."; return }
        do { d = try await api.value("/api/weekly/defs/\(id)") } catch { self.error = error.localizedDescription }
    }

    private func fact<V: View>(_ label: String, @ViewBuilder _ value: () -> V) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 14.4) {
                Text(label).ufFont(13.6).foregroundStyle(UF.muted).frame(width: 170, alignment: .leading)
                value().frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 3.2) {
                Text(label).ufFont(13.6).foregroundStyle(UF.muted)
                value()
            }
        }
        .padding(.vertical, 4.4)
    }

    @ViewBuilder private func details(_ d: JSONValue) -> some View {
        let kind = d.s("kind") == "probeklausur" ? "Probeklausur" : d.s("kind") == "nachtrag" ? "Nachtrag" : "Lehrwoche \(d.i("week_no") ?? 0)"
        let test = d["test"].flatMap { $0.isNull ? nil : $0 }
        let state = test.map { t -> String in
            if t.s("submitted_at") != nil { return "abgegeben · \(Int((t.n("score") ?? 0).rounded()))/\(Int((t.n("max_score") ?? 0).rounded())) Punkte" }
            return t.s("started_at") != nil ? "begonnen" : "noch nicht gestartet"
        } ?? "–"
        VStack(alignment: .leading, spacing: 0) {
            fact("Thema") {
                (Text(d.s("topic").flatMap { $0.isEmpty ? nil : $0 } ?? d.s("title") ?? "–").bold()
                 + Text("  \(kind) · Version \(d.i("version") ?? 1)").foregroundColor(UF.muted))
                    .ufFont(14.4).foregroundStyle(UF.text)
            }
            fact("Vorlesungsseiten") {
                VStack(alignment: .leading, spacing: 2) {
                    let pages = d.list("pages")
                    Text(pages.isEmpty ? "–" : pages.map { "\($0.s("name") ?? "Skript"): S. \($0.i("from") ?? 0)–\($0.i("to") ?? 0)" }.joined(separator: "\n"))
                    let prior = d.list("prior_pages")
                    if !prior.isEmpty {
                        Text("Vorwissen: " + prior.map { "S. \($0.i("from") ?? 0)–\($0.i("to") ?? 0)" }.joined(separator: ", "))
                            .ufFont(12.8).foregroundStyle(UF.muted)
                    }
                }
                .ufFont(14.4).foregroundStyle(UF.text)
            }
            fact("Verwendete Übungen") {
                let used = d.list("used_materials")
                Text(used.isEmpty ? "nur Vorlesungsinhalte" : used.compactMap { $0.s("label") }.joined(separator: "\n"))
                    .ufFont(used.isEmpty ? 14.4 : 13.6).foregroundStyle(used.isEmpty ? UF.muted : UF.text)
            }
            fact("Altklausuraufgaben") {
                Text("\(d.i("exam_questions") ?? 0) im Test · \(d.i("exam_candidates") ?? 0) passende gefunden").ufFont(14.4).foregroundStyle(UF.text)
            }
            fact("Testaufgaben") {
                let levels = d["levels"]?.object.map { $0.sorted { $0.key < $1.key }.map { "\($0.value.int ?? 0) \($0.key)" }.joined(separator: ", ") }
                Text("\(d.i("question_count") ?? 0)\(levels.map { " (\($0))" } ?? "") · \(d.i("duration_min") ?? 0) min").ufFont(14.4).foregroundStyle(UF.text)
            }
            fact("Veröffentlicht") { Text(WeeklyText.when(d.s("published_at"))).ufFont(14.4).foregroundStyle(UF.text) }
            fact("Bearbeitung") {
                HStack(spacing: 8) {
                    Text(state).ufFont(14.4).foregroundStyle(UF.text)
                    if let t = test, let tid = t.i("id") {
                        UFButton(t.s("submitted_at") != nil ? "Ansehen" : "Starten", size: .small) { close(); router.go(.exam(tid)) }
                    }
                }
            }
            let missing = d.list("missing").compactMap(\.string)
            if !missing.isEmpty {
                fact("Fehlende Quellen") {
                    Text("\(missing.map(WeeklyText.source).joined(separator: ", ")) waren bis zur Veröffentlichung nicht hochgeladen")
                        .ufFont(14.4).foregroundStyle(UF.warn)
                }
            }
            if let n = d.i("excluded_count"), n > 0 {
                fact("Ausgeschlossen") {
                    Text("\(n) Aufgaben aus Übungen/Altklausuren betreffen noch nicht behandelten Stoff").ufFont(12.8).foregroundStyle(UF.muted)
                }
            }
            let nachtraege = d.list("nachtraege")
            if !nachtraege.isEmpty {
                fact("Nachträge") {
                    Text(nachtraege.map { "\($0.s("title") ?? "Nachtrag") · \(WeeklyText.when($0.s("published_at")))" }.joined(separator: "\n"))
                        .ufFont(14.4).foregroundStyle(UF.text)
                }
            }
            let ranking = d.list("ranking")
            if !ranking.isEmpty {
                HStack(spacing: 6) { UFIcon("users", size: 15); Text("Rangliste dieser Testversion") }
                    .ufFont(14.4, 650).foregroundStyle(UF.text).padding(.top, 16).padding(.bottom, 4.8)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        ForEach(["#", "Teilnehmer", "Punkte", "Dauer"], id: \.self) { Text($0).ufFont(12.8, 650).foregroundStyle(UF.muted) }
                    }
                    ForEach(Array(ranking.enumerated()), id: \.offset) { _, r in
                        GridRow {
                            Text("\(r.i("rank") ?? 0)")
                            Text(r.s("user_id") == "local" ? "Du" : (r.s("user_id") ?? ""))
                            Text("\(Int((r.n("score") ?? 0).rounded()))/\(Int((r.n("max_score") ?? 0).rounded())) (\(WeeklyText.number(r.n("percent"))) %)")
                            Text(r.n("duration_sec").map { $0 > 0 ? "\(Int(($0 / 60).rounded())) min" : "–" } ?? "–")
                        }
                        .ufFont(13.6).foregroundStyle(UF.text)
                    }
                }
                Text("Alle Teilnehmer dieser Version haben dieselben Aufgaben und Bewertungskriterien. Nachträge zählen nicht.")
                    .ufFont(12).foregroundStyle(UF.muted).padding(.top, 6)
            }
        }
        .accessibilityIdentifier("weekly.def")
    }
}

// MARK: - Einstellungen (weeklySettings)

struct WeeklySettingsDialog: View {
    let module: JSONValue
    let settings: JSONValue
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @Environment(\.ufClose) private var close
    @State private var hours = 24
    @State private var expected: Set<String> = []
    @State private var reuse = "paraphrase"
    @State private var loaded = false

    var body: some View {
        UFDialog("Wochentests · \(module.s("name") ?? "")", icon: "settings") {
            UFField("Veröffentlichung nach Vorlesungsende") {
                UFSelect(options: [5, 24, 48].map { ($0, "\($0) Stunden") }, selection: $hours)
                Text("gilt für alle Module").ufFont(12).foregroundStyle(UF.muted)
            }
            UFField("Diese Übungen kommen jede Woche sicher – der Test wartet darauf (höchstens \(WeeklyText.number(settings.n("max_delay_hours"))) h länger):") {
                UFFlexWrap(gap: 6, rowGap: 6) {
                    ForEach(WeeklyText.expectable, id: \.self) { k in
                        UFChip(text: WeeklyText.source(k), on: expected.contains(k), icon: expected.contains(k) ? "check" : nil) {
                            if expected.contains(k) { expected.remove(k) } else { expected.insert(k) }
                        }
                        .accessibilityAddTraits(expected.contains(k) ? [.isSelected] : [])
                    }
                }
                .padding(.top, 4.8)
                Text("Nichts ankreuzen, wenn unklar. Ohne Angabe wird nicht gewartet, später hochgeladene Aufgaben kommen als Nachtrag.")
                    .ufFont(12).foregroundStyle(UF.muted)
            }
            UFField("Altklausuren") {
                UFFlexWrap(gap: 6, rowGap: 6) {
                    reuseChoice("paraphrase", "nur angelehnte neue Aufgaben")
                    reuseChoice("original", "Originalaufgaben erlaubt")
                }
                .padding(.top, 4.8)
                Text("Originale nur, wenn die Nutzungsrechte das erlauben.").ufFont(12).foregroundStyle(UF.muted)
            }
        } foot: {
            UFButton("Abbrechen") { close() }
            UFButton("Speichern", kind: .primary) { Task { await save() } }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            hours = Int((settings.n("publish_hours") ?? 24).rounded())
            if ![5, 24, 48].contains(hours) { hours = 24 }
            expected = Set(settings.list("expected_materials").compactMap(\.string))
            reuse = settings.s("exam_reuse") == "original" ? "original" : "paraphrase"
        }
    }

    private func reuseChoice(_ value: String, _ text: String) -> some View {
        Button { reuse = value } label: {
            HStack(spacing: 6) { UFRadio(on: reuse == value); Text(text).ufFont(13.6).foregroundStyle(UF.text) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(reuse == value ? [.isSelected] : [])
    }

    private func save() async {
        guard let api = session.api, let id = module.i("id") else { return }
        do {
            _ = try await api.value("/api/settings", method: "PUT", body: ["weekly_publish_hours": .string(String(hours))])
            let exp = WeeklyText.expectable.filter { expected.contains($0) }.map { JSONValue.string($0) }
            _ = try await api.value("/api/modules/\(id)", method: "PATCH", body: ["expected_materials": .array(exp), "exam_reuse": .string(reuse)])
            close()
            toast.show("Gespeichert")
            NotificationCenter.default.post(name: .uniflowWeeklyChanged, object: nil)
        } catch { toast.show(error.localizedDescription, seconds: 5) }
    }
}

// MARK: - Probeklausur (mockDialog)

struct MockExamDialog: View {
    let module: JSONValue
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var shell: ShellState
    @Environment(\.ufClose) private var close

    var body: some View {
        UFDialog("Probeklausur · \(module.s("name") ?? "")", icon: "sparkles") {
            Text("Die Probeklausur orientiert sich an Aufbau, Aufgabentypen und Punkteverteilung der echten Altklausuren. Sie wird nur auf Anfrage erstellt.")
                .ufFont(13.6).foregroundStyle(UF.text)
            VStack(alignment: .leading, spacing: 8) {
                UFButton("Lernstandsklausur – nur bis zum letzten Marker", icon: "bookmark") { Task { await go(full: false) } }
                    .accessibilityIdentifier("weekly.mock.now")
                UFButton("Abschlussprobeklausur – gesamter Stoff", icon: "flag") { Task { await go(full: true) } }
            }
            .padding(.vertical, 11.2)
            Text("Die Abschlussprobeklausur ist erst möglich, wenn alle Vorlesungsskripte bis zur letzten Seite markiert sind.")
                .ufFont(12).foregroundStyle(UF.muted)
        } foot: {
            UFButton("Schließen") { close() }
        }
    }

    private func go(full: Bool) async {
        guard let api = session.api, let id = module.i("id") else { return }
        do {
            _ = try await api.value("/api/weekly/mock-exam", method: "POST", body: ["module_id": .number(Double(id)), "full": .bool(full)])
            close()
            toast.show("Probeklausur wird erstellt und geprüft (einige Minuten)…", seconds: 4)
            await shell.pollBackground(toast: toast)
            NotificationCenter.default.post(name: .uniflowWeeklyChanged, object: nil)
        } catch { toast.show(error.localizedDescription, seconds: 6) }
    }
}

// MARK: - PDF-Editor: "Vorlesung bis hier" (setupLectureMarker)

/// Marker eines Dokuments (GET /api/markers?file_id=…): Knopf mit Warnfarbe bei zu pruefenden Markern, Kennzeichen
/// "bis hier" an den Miniaturen
@MainActor
final class LectureMarkers: ObservableObject {
    @Published private(set) var marks: [JSONValue] = []

    var needsReview: Bool { marks.contains { $0["needs_review"]?.bool == true || ($0.i("needs_review") ?? 0) != 0 } }

    /// Marker, der auf dieser PDF-Seite endet (1-basiert)
    func mark(pdfPage: Int?) -> JSONValue? {
        guard let pdfPage else { return nil }
        return marks.first { $0.i("page") == pdfPage }
    }

    func refresh(api: APIClient, fileID: String) async {
        let id = fileID.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? fileID
        marks = (try? await api.value("/api/markers?file_id=\(id)"))?.array ?? []
    }

    static func reviewFlag(_ m: JSONValue) -> Bool { m["needs_review"]?.bool == true || (m.i("needs_review") ?? 0) != 0 }
}

extension CharacterSet {
    /// Wert eines Abfrageparameters (encodeURIComponent)
    static let urlQueryValueAllowed: CharacterSet = {
        var c = CharacterSet.alphanumerics
        c.insert(charactersIn: "-_.!~*'()")
        return c
    }()
}

/// Dialog "Vorlesung bis hier" zur angezeigten PDF-Seite: Vorschau (Termin, Seitenbereich, Thema, Veroeffentlichung),
/// eigene Marker des Dokuments mit Springen, Verschieben, Freigeben und Loeschen
struct LectureMarkerSheet: View {
    let api: APIClient
    let fileID: String
    /// PDF-Seite (1-basiert) und Schluessel der angezeigten Seite
    let page: Int
    let pageKey: String?
    @ObservedObject var markers: LectureMarkers
    let goTo: (Int) -> Void
    let done: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pv: JSONValue?
    @State private var error: String?
    @State private var date = Date()
    @State private var topic = ""
    @State private var working = false
    @State private var confirmDelete: JSONValue?
    @State private var confirmRelease: JSONValue?

    private static let dayF: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Fmt.zone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var fileQuery: String { fileID.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? fileID }

    var body: some View {
        NavigationStack {
            Group {
                if let pv { form(pv) }
                else if let error { ContentUnavailableView("Vorlesung bis hier", systemImage: "exclamationmark.triangle", description: Text(error)) }
                else { ProgressView("Lädt…") }
            }
            .navigationTitle("Vorlesung bis hier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                if let pv {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(pv["existing"]?.isNull == false ? "Änderungen speichern" : "Bis Seite \(pv.i("page") ?? page) markieren") {
                            Task { await save() }
                        }
                        .disabled(working)
                        .accessibilityIdentifier("marker.save")
                    }
                }
            }
        }
        .task { await load(date: nil) }
        .confirmationDialog("Marker löschen?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Löschen", role: .destructive) { if let m = confirmDelete { Task { await delete(m) } } }
        } message: { Text("Bereits veröffentlichte Wochentests bleiben unverändert.") }
        .alert("Als Kursstand freigeben?", isPresented: Binding(get: { confirmRelease != nil }, set: { if !$0 { confirmRelease = nil } })) {
            Button("Freigeben") { if let m = confirmRelease { Task { await release(m) } } }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Dann richtet sich der gemeinsame Wochentest aller Teilnehmer nach diesem Stoffumfang. Nur freigeben, wenn der Stand für den ganzen Kurs stimmt.")
        }
    }

    @ViewBuilder private func form(_ pv: JSONValue) -> some View {
        let existing = pv["existing"].flatMap { $0.isNull ? nil : $0 }
        let range = pv.list("range")
        let pub = WeeklyText.publish(pv)
        let own = markers.marks.filter { $0.s("scope") == "personal" }
        Form {
            Section {
                VStack(alignment: .leading, spacing: 3) {
                    Text(existing != nil ? "Seite \(pv.i("page") ?? page) ist bereits als Vorlesungsende markiert."
                                         : "Bis Seite \(pv.i("page") ?? page) als behandelt markieren?").bold()
                    Text("Folie \(pv.i("page") ?? page) von \(pv.i("page_count") ?? 0)").font(.caption).foregroundStyle(.secondary)
                }
                DatePicker("Vorlesungstermin", selection: $date, in: ...Date(), displayedComponents: .date)
                    .environment(\.timeZone, Fmt.zone)
                    .onChange(of: date) { _, d in Task { await load(date: d) } }
                Text(WeeklyText.lecture(pv)).font(.caption).foregroundStyle(.secondary)
                LabeledContent("Erfasster Seitenbereich") {
                    Text("Seite \(range.first?.int ?? 0)–\(range.dropFirst().first?.int ?? 0)").bold()
                }
                TextField("Thema, z. B. Variablen und Datentypen", text: $topic)
                    .accessibilityLabel("Thema")
                LabeledContent("Wochentest") {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(pub.when).bold()
                        Text(pub.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Label("Der Marker begrenzt den Lernstoff: Seiten danach kommen in keinem Wochentest vor. Er ist keine Textmarkierung und gilt zunächst nur für dich.",
                      systemImage: "info.circle")
            }
            if !own.isEmpty {
                Section("Marker in diesem Dokument") {
                    ForEach(Array(own.enumerated()), id: \.offset) { _, m in markRow(m, current: pv.i("page") ?? page) }
                }
            }
        }
    }

    private func markRow(_ m: JSONValue, current: Int) -> some View {
        let review = LectureMarkers.reviewFlag(m)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: review ? "exclamationmark.triangle" : "flag").foregroundStyle(review ? Color.orange : Color.accentColor)
                Text(WeeklyText.range(m)).bold()
                Text("· \(UFFmt.date(m.s("lecture_date")))\(m.s("topic").flatMap { $0.isEmpty ? nil : " · " + $0 } ?? "")")
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            if review, let note = m.s("review_note"), !note.isEmpty { Text(note).font(.caption).foregroundStyle(.orange) }
            HStack(spacing: 8) {
                Button { dismiss(); goTo(m.i("page") ?? 1) } label: { Label("Zur Seite", systemImage: "arrow.left") }
                if m.i("page") != current {
                    Button("→ S. \(current)") { Task { await move(m) } }
                        .accessibilityLabel("Auf aktuelle Seite \(current) verschieben")
                }
                Button { confirmRelease = m } label: { Label("Für den Kurs freigeben", systemImage: "person.2") }
                Button(role: .destructive) { confirmDelete = m } label: { Label("Marker löschen", systemImage: "trash") }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    private func load(date d: Date?) async {
        let dateQuery = d.map { "&lecture_date=\(Self.dayF.string(from: $0))" } ?? ""
        do {
            let r = try await api.value("/api/markers/preview?file_id=\(fileQuery)&page=\(page)\(dateQuery)")
            pv = r
            error = nil
            if d == nil {
                // erster Aufruf: Vorschlaege des Servers (Termin aus dem Stundenplan, Thema aus der Seite)
                if let s = r.s("lecture_date"), let day = Self.dayF.date(from: s) { date = day }
                topic = r.s("topic") ?? ""
            }
        } catch {
            if pv == nil { self.error = error.localizedDescription } else { done(error.localizedDescription) }
        }
    }

    private func save() async {
        guard let pv else { return }
        working = true
        defer { working = false }
        let day = Self.dayF.string(from: date)
        do {
            if let existing = pv["existing"], !existing.isNull, let id = existing.i("id") {
                _ = try await api.value("/api/markers/\(id)", method: "PATCH", body: ["lecture_date": .string(day), "topic": .string(topic)])
            } else {
                var body: JSONValue = ["file_id": .string(fileID), "page": .number(Double(page)), "lecture_date": .string(day), "topic": .string(topic)]
                if let pageKey { body["page_key"] = .string(pageKey) }
                _ = try await api.value("/api/markers", method: "POST", body: body)
            }
            let range = pv.list("range")
            await finish("Seite \(range.first?.int ?? 0)–\(pv.i("page") ?? page) als behandelt markiert. Wochentest ab \(WeeklyText.when(pv.s("publish_at"))).")
        } catch { done(error.localizedDescription) }
    }

    private func move(_ m: JSONValue) async {
        guard let id = m.i("id") else { return }
        var body: JSONValue = ["page": .number(Double(page))]
        if let pageKey { body["page_key"] = .string(pageKey) }
        do {
            _ = try await api.value("/api/markers/\(id)", method: "PATCH", body: body)
            await finish("Marker verschoben")
        } catch { done(error.localizedDescription) }
    }

    private func delete(_ m: JSONValue) async {
        guard let id = m.i("id") else { return }
        do {
            _ = try await api.value("/api/markers/\(id)", method: "DELETE")
            await finish("Marker gelöscht")
        } catch { done(error.localizedDescription) }
    }

    private func release(_ m: JSONValue) async {
        guard let id = m.i("id") else { return }
        do {
            _ = try await api.value("/api/markers/\(id)/release", method: "POST", body: ["confirm": true])
            await finish("Als Kursmarker freigegeben")
        } catch { done(error.localizedDescription) }
    }

    private func finish(_ message: String) async {
        await markers.refresh(api: api, fileID: fileID)
        NotificationCenter.default.post(name: .uniflowWeeklyChanged, object: nil)
        dismiss()
        done(message)
    }
}

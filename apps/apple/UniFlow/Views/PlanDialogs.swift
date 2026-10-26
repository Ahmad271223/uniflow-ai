import SwiftUI
import UniFlowCore

// Dialoge des Lernkalenders 1:1 nach app/static/views-plan.js: generatePlan(), configDialog(), suggestFlow().

/// "Lernplan erstellen": Machbarkeit (GET /api/calendar/feasibility), Start, Tage, Ersetzen -> POST /api/calendar/generate
struct GeneratePlanDialog: View {
    let api: APIClient?
    let start: String
    let onClose: () -> Void
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var toast: UFToastCenter
    @State private var feas: JSONValue?
    @State private var startDate = ""
    @State private var days = 7
    @State private var replace = false
    @State private var busy = false
    @State private var showConfig = false

    var body: some View {
        if showConfig {
            ConfigDialog(api: api) { saved in showConfig = false; if !saved { onClose() } }
        } else {
            UFDialog("Lernplan erstellen", icon: "sparkles") {
                VStack(alignment: .leading, spacing: 0) {
                    // ohne PC keine Wochentests (KI, entfallen in V1): weder anbieten noch ankuendigen
                    Text("Erstellt Lernpakete pro Modul und Lehrwoche (\(api?.isLocal == true ? "Vorlesung → Übungen" : "Vorlesung → Übungen → gemeinsamer Wochentest")) für freie Tage ab dem gewählten Datum und legt sie in freie Zeitfenster deines Stundenplans. Bestehende Pakete bleiben erhalten.")
                        .ufFont(13.12).foregroundStyle(UF.muted).padding(.vertical, 5.6)
                    if let f = feas {
                        if let hint = f.s("hint"), !hint.isEmpty {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                UFIcon("alert", size: 14).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                                (Text("Hinweis: ").font(.uf(14.5, 700)) + Text(hint))
                            }
                            .ufFont(14.5).foregroundStyle(UF.text)
                            .padding(.vertical, 17.6 + ufB).padding(.horizontal, 19.2 + ufB)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.warnSoft))
                            .padding(.vertical, 8)
                        } else {
                            Text("Offen: ca. \(UFFmt.min(f.n("open_minutes"))) · verfügbar in 4 Wochen: \(UFFmt.min(f.n("available_minutes_4w")))")
                                .ufFont(13.12).foregroundStyle(UF.muted)
                        }
                    }
                    HStack(alignment: .top, spacing: 9.6) {
                        UFField("Ab") { UFDateField(iso: $startDate) }
                        UFField("Tage") { UFSelect(options: [(7, "7 Tage"), (14, "14 Tage"), (28, "4 Wochen")], selection: $days, fill: true) }
                    }
                    UFCheckbox("Bereits geplante, noch nicht begonnene Pakete in diesem Zeitraum ersetzen", isOn: $replace)
                }
            } foot: {
                UFButton("Abbrechen") { onClose() }
                UFButton("Lernkombination ändern") { showConfig = true }
                UFButton("Erstellen", kind: .primary) { Task { await create() } }.disabled(busy)
            }
            .task {
                startDate = start
                feas = try? await api?.value("/api/calendar/feasibility")
            }
        }
    }

    private func create() async {
        guard let api else { return }
        busy = true
        let st = startDate
        do {
            let r = try await api.value("/api/calendar/generate", method: "POST",
                                        body: ["start": .string(st), "days": .number(Double(days)), "replace": .bool(replace)])
            toast.show(r.s("message") ?? "Lernplan erstellt")
            onClose()
            router.go(.plan(view: "week", date: st))
        } catch {
            toast.show(error.localizedDescription)
            busy = false
        }
    }
}

/// "Meinen Lernplan konfigurieren": Vorlagen A–E, Faecher/Lernzeit/Vorlesungen/Uebungen/Test, Lerntage, Klausur-Prioritaet;
/// Live-Rechnung wie upd() in configDialog. Speichern -> PUT /api/settings. onDone(true) = gespeichert.
/// Ohne PC (lokales Backend) gibt es keine Wochentests (KI, entfallen in V1): Vorlagen ohne Test und Wiederholung,
/// keine Felder dafuer, gespeichert wird immer tests_per_subject 0 (Entscheidung 2).
struct ConfigDialog: View {
    let api: APIClient?
    let onDone: (Bool) -> Void
    @EnvironmentObject private var toast: UFToastCenter
    @State private var preset = ""
    @State private var sub = 1
    @State private var minutes = 120
    @State private var lec = 1
    @State private var ex = 1
    @State private var tests = 0
    @State private var testMin = 45
    @State private var learnDays: Set<Int> = Set(0..<7)
    @State private var examPriority = false

    private struct Preset { let key, name, desc: String; let v: (sub: Int, lec: Int, ex: Int, tests: Int)? }
    private let presets: [Preset] = [
        Preset(key: "A", name: "Intensiv", desc: "1 Fach pro Tag · Vorlesung + Übungen + Wochentest", v: (1, 1, 1, 1)),
        Preset(key: "B", name: "Intensiv mit Wiederholung", desc: "1 Fach pro Tag · zusätzlich Wiederholung (Karteikarten)", v: (1, 1, 1, 2)),
        Preset(key: "C", name: "Abwechslungsreich", desc: "2 Fächer pro Tag · je Vorlesung + Übungen + Wochentest", v: (2, 1, 1, 1)),
        Preset(key: "D", name: "Zwei Fächer mit Wiederholung", desc: "2 Fächer pro Tag · zusätzlich Wiederholung", v: (2, 1, 1, 2)),
        Preset(key: "E", name: "Benutzerdefiniert", desc: "Alles selbst kombinieren", v: nil),
    ]
    private let localPresets: [Preset] = [
        Preset(key: "A", name: "Intensiv", desc: "1 Fach pro Tag · Vorlesung + Übungen", v: (1, 1, 1, 0)),
        Preset(key: "B", name: "Abwechslungsreich", desc: "2 Fächer pro Tag · je Vorlesung + Übungen", v: (2, 1, 1, 0)),
        Preset(key: "C", name: "Benutzerdefiniert", desc: "Alles selbst kombinieren", v: nil),
    ]

    /// lokales Backend: ohne Wochentests
    private var local: Bool { api?.isLocal == true }

    var body: some View {
        UFDialog("Meinen Lernplan konfigurieren") {
            VStack(alignment: .leading, spacing: 8) {                     // .stack#presets: label.chip mit Radioknopf
                ForEach(local ? localPresets : presets, id: \.key) { p in
                    Button {
                        preset = p.key
                        if let v = p.v { sub = v.sub; lec = v.lec; ex = v.ex; tests = v.tests }
                    } label: {
                        HStack(spacing: 0) {
                            UFRadio(on: preset == p.key).padding(.trailing, 6.4)
                            Text("\(p.key) – \(p.name)").font(.uf(12.8, 700)).foregroundStyle(UF.text2)
                            Text(" ").font(.uf(12.8))
                            Text(p.desc).font(.uf(12.8)).foregroundStyle(UF.muted).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .ufFont(12.8)
                        .padding(.vertical, 8 + ufB).padding(.horizontal, 12.8 + ufB)
                        .background(RoundedRectangle(cornerRadius: 10).fill(UF.surface))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(UF.line, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            UFGridLayout(columns: 2) {                                    // .grid.cols-2, margin-top .8rem
                UFField("Fächer pro Tag") { UFSelect(options: [(1, "1 Fach"), (2, "2 Fächer"), (3, "3 Fächer")], selection: $sub, fill: true) }
                UFField("Lernzeit pro Tag (Minuten)") { UFNumberField(value: $minutes) }
                UFField("Vorlesungen der Woche") { UFSelect(options: [(0, "nicht einplanen"), (1, "alle der Lehrwoche")], selection: $lec, fill: true) }
                UFField("Übungen der Woche") { UFSelect(options: [(0, "nicht einplanen"), (1, "alle (Hörsaal-, Gruppenübung …)")], selection: $ex, fill: true) }
                if !local {
                    UFField("Wochentest pro Modul") { UFSelect(options: [(0, "kein Test"), (1, "1 gemeinsamer Test"), (2, "1 Test + Wiederholung")], selection: $tests, fill: true) }
                    UFField("Dauer Wochentest") { UFSelect(options: [15, 30, 45, 60, 90].map { ($0, "\($0) min") }, selection: $testMin, fill: true) }
                }
            }
            .padding(.top, 12.8)
            UFField("Lerntage") {
                HStack(spacing: 9.6) {
                    ForEach(0..<7, id: \.self) { i in
                        UFChip(text: ShellState.days[i], on: learnDays.contains(i)) {
                            if learnDays.contains(i) { learnDays.remove(i) } else { learnDays.insert(i) }
                        }
                    }
                }
            }
            UFCheckbox("Klausurtermine stärker priorisieren", isOn: $examPriority)
            feasibility.ufFont(13.12).padding(.vertical, 6.4)
        } foot: {
            UFButton("Abbrechen") { onDone(false) }
            UFButton("Speichern", kind: .primary) { Task { await save() } }
        }
        .task { await load() }
    }

    /// Bedarf je Tag wie im Web: Faecher * (Vorlesung 45 + Uebung 60 + Testdauer + 15 bei Wiederholung)
    private var feasibility: Text {
        let t = local ? 0 : tests
        let need = sub * (lec * 45 + ex * 60 + (t > 0 ? testMin : 0) + (t > 1 ? 15 : 0))
        var combo = "\(sub) Fächer täglich · \(lec > 0 ? "Vorlesung" : "ohne Vorlesung") · \(ex > 0 ? "Übungen" : "ohne Übung")"
        if !local { combo += " · \(t > 0 ? "1 Wochentest" : "kein Test")\(t > 1 ? " + Wiederholung" : "")" }
        let head = Text("Deine Kombination: ").foregroundColor(UF.muted) + Text(combo).bold().foregroundColor(UF.muted)
            + Text(" → etwa \(UFFmt.min(need)) pro Tag. ").foregroundColor(UF.muted)
        if need > minutes {
            return head + Text("Das passt nicht in \(UFFmt.min(minutes)). Vorschlag: \(sub > 1 ? "weniger Fächer pro Tag" : local ? "mehr Lernzeit" : "kürzerer Test oder mehr Lernzeit").").foregroundColor(UF.bad)
        }
        return head + Text("Passt in \(UFFmt.min(minutes)).").foregroundColor(UF.ok)
    }

    private func load() async {
        guard let s = try? await api?.value("/api/settings") else { return }
        sub = s.i("subjects_per_day") ?? Int(s.s("subjects_per_day") ?? "") ?? 1
        minutes = s.i("minutes_per_day") ?? Int(((s.n("hours_per_day") ?? Double(s.s("hours_per_day") ?? "") ?? 2) * 60).rounded())
        lec = min(1, s.i("parts_lecture") ?? Int(s.s("parts_lecture") ?? "") ?? 1)
        ex = min(1, s.i("parts_exercise") ?? Int(s.s("parts_exercise") ?? "") ?? 1)
        tests = local ? 0 : s.i("tests_per_subject") ?? Int(s.s("tests_per_subject") ?? "") ?? 0
        testMin = s.i("test_minutes") ?? Int(s.s("test_minutes") ?? "") ?? 45
        let free = Set((s["free_days"]?.array ?? []).compactMap { $0.int })
        learnDays = Set(0..<7).subtracting(free)
        examPriority = s["exam_priority"]?.bool ?? ((s.i("exam_priority") ?? 0) == 1)
    }

    /// gleiche Felder und Formate wie cOk im Web (Auswahlwerte als Zeichenkette, hours_per_day mit zwei Nachkommastellen)
    private func save() async {
        guard let api else { return }
        let free = (0..<7).filter { !learnDays.contains($0) }.map { JSONValue.number(Double($0)) }
        let body: JSONValue = [
            "subjects_per_day": .string("\(sub)"), "parts_lecture": .string("\(lec)"), "parts_exercise": .string("\(ex)"),
            "tests_per_subject": .string("\(local ? 0 : tests)"), "test_minutes": .string("\(testMin)"),
            "hours_per_day": .string(String(format: "%.2f", Double(minutes) / 60)), "free_days": .array(free),
            "exam_priority": .bool(examPriority),
        ]
        do {
            _ = try await api.value("/api/settings", method: "PUT", body: body)
            toast.show("Lernkombination gespeichert")
            onDone(true)
        } catch { toast.show(error.localizedDescription) }
    }
}

/// "Meine Woche retten" / "Neu einplanen": Vorschlaege mit aenderbarem Zieldatum -> POST /api/calendar/apply
struct SuggestDialog: View {
    let api: APIClient?
    let rescue: Bool
    let suggestion: JSONValue
    let onClose: () -> Void
    @EnvironmentObject private var toast: UFToastCenter
    @State private var targets: [String] = []

    var body: some View {
        let moves = suggestion.list("moves")
        UFDialog(rescue ? "Meine Woche retten" : "Neu einplanen", icon: rescue ? "life-buoy" : "move") {
            Text(suggestion.s("message") ?? "").ufFont(14.5).foregroundStyle(UF.text).padding(.vertical, 5.6)
            VStack(alignment: .leading, spacing: 0) {                     // ul.sugg: Spalten 1fr auto auto auto
                ForEach(moves.indices, id: \.self) { i in
                    let mv = moves[i]
                    HStack(spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            UFIcon(ShellState.typeIcon[mv.s("type") ?? ""] ?? "file", size: 14).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                            Text("\(UFFmt.shortName(mv.s("subject"))): \(mv.s("title") ?? "")")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(mv.i("est_minutes") ?? 0) min").ufFont(13.12).foregroundStyle(UF.muted)
                        Text("\(UFFmt.short(mv.s("from"))) →").ufFont(13.12).foregroundStyle(UF.muted)
                        if i < targets.count { UFDateField(iso: $targets[i]).frame(width: 150) }
                    }
                    .ufFont(13.76)
                    .padding(.vertical, 6.4)
                    .ufBorderBottom()
                }
            }
            .padding(.vertical, 8)
            Text((rescue ? "Verteilt auf die nächsten 7 Tage, höchstens 60 % deiner Tageszeit, damit nichts gestapelt wird."
                         : "Verteilt nach freier Lernzeit. Erledigte Aufgaben bleiben erledigt.") + " Du kannst jeden Tag noch ändern.")
                .ufFont(13.12).foregroundStyle(UF.muted).padding(.vertical, 5.6)
        } foot: {
            UFButton("Abbrechen") { onClose() }
            UFButton("Vorschlag übernehmen", kind: .primary) { Task { await apply(moves) } }
        }
        .onAppear { targets = moves.map { $0.s("to") ?? "" } }
    }

    private func apply(_ moves: [JSONValue]) async {
        guard let api else { return }
        let updated: [JSONValue] = moves.enumerated().map { i, mv in
            var o = mv.object ?? [:]
            if i < targets.count { o["to"] = .string(targets[i]) }
            return .object(o)
        }
        do {
            let a = try await api.value("/api/calendar/apply", method: "POST", body: ["moves": .array(updated)])
            toast.show("\(a.i("moved") ?? 0) Aufgaben neu eingeplant")
            onClose()
        } catch { toast.show(error.localizedDescription) }
    }
}

// MARK: - Formularbausteine (label.field, Checkbox)

/// label.field: Beschriftung .85rem in --text-2, darunter das Eingabeelement
struct UFField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {                     // label.field: .85rem, margin .55rem 0
            Text(label).ufFont(13.6).foregroundStyle(UF.text2)
            content
        }
        .padding(.vertical, 4.4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Kontrollkaestchen mit Text wie <label class="field"><input type="checkbox"> …</label>
struct UFCheckbox: View {
    let text: String
    @Binding var isOn: Bool

    init(_ text: String, isOn: Binding<Bool>) {
        self.text = text
        self._isOn = isOn
    }

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(alignment: .top, spacing: 6.4) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square").foregroundStyle(isOn ? UF.accent : UF.muted)
                Text(text).ufFont(13.6).foregroundStyle(UF.text2).multilineTextAlignment(.leading)
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }
}

import SwiftUI
import UniFlowCore

// Fragen im Gespraech (neuer Einstieg, nach der Uni-Anmeldung): der Begleiter fragt, die Antworten erscheinen als
// eigene Sprechblasen; auf breiten Bildschirmen links das Gespraech, rechts die Antwort. Drei Fragen:
//  1. Rufname fuer die Begruessung (`Rufname.save`, vorbelegt mit dem Vornamen aus der Apple-Anmeldung)
//  2. Faecher fuer den Lernkalender (`GET/POST /api/calendar/modules`, wie "Was soll in den Lernkalender?"; gilt danach
//     als gefragt, die Frage kommt nicht noch einmal von selbst)
//  3. Pruefungstermine der gewaehlten Faecher: was QIS schon kennt, steht da; sonst "In 7 Tagen", "In etwa einem
//     Monat", "Datum wählen" oder "Keine Klausur" (`PATCH /api/modules/{id}` mit `exam_date`, wie im Lernziel-Dialog)
// Danach "Ich richte alles ein" mit Haken. Jede Frage laesst sich ueberspringen, oben auch alles auf einmal.

/// Ein Fach in den Fragen
struct IntroSetupModule: Identifiable, Equatable {
    /// Modul-ID fuer den Pruefungstermin (nil: Fach nur im Lernkalender bekannt)
    var moduleID: Int?
    let name: String
    let color: String?
    var planned: Bool
    /// Pruefungstag (YYYY-MM-DD)
    var exam: String?
    /// Termin kam aus QIS bzw. der Hochschule (nicht aenderbar in den Fragen)
    var examFromUni = false
    var noExam = false

    var id: String { name }
}

/// Schnellwahl fuer einen Pruefungstermin
enum IntroExamChoice: String, CaseIterable, Identifiable {
    case week, month, date, none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: return "In 7 Tagen"
        case .month: return "In etwa einem Monat"
        case .date: return "Datum wählen …"
        case .none: return "Keine Klausur"
        }
    }

    /// Tag zur Schnellwahl (nil bei "Datum wählen" und "Keine Klausur")
    func day(from today: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .week: return calendar.date(byAdding: .day, value: 7, to: today)
        case .month: return calendar.date(byAdding: .month, value: 1, to: today)
        case .date, .none: return nil
        }
    }
}

/// Ablauf der Fragen (reine Logik, IntroAppTests)
struct IntroSetupModel: Equatable {
    enum Step: Int, CaseIterable { case name, modules, exams, ready }

    var step: Step = .name
    var name: String = ""
    var modules: [IntroSetupModule] = []

    var planned: [IntroSetupModule] { modules.filter(\.planned) }
    /// Faecher mit Termin (aus QIS oder eingetragen)
    var withExam: [IntroSetupModule] { planned.filter { $0.exam != nil } }

    var displayName: String? { UFGreeting.displayName(name) }

    /// Frage des Begleiters
    func question(_ s: Step) -> String {
        switch s {
        case .name:
            return "Schön, dass du da bist! Wie sollen wir dich nennen?"
        case .modules:
            if modules.isEmpty {
                return "Ich habe noch keine Fächer gefunden. Sobald Stud.IP sie geliefert hat, wählst du sie in den Einstellungen unter „Lernzeit“."
            }
            return (displayName.map { "Hallo \($0)! " } ?? "") + "Für welche Fächer soll StudiNow Lernzeit planen?"
        case .exams:
            let known = planned.filter(\.examFromUni).count
            let lead = known == 0 ? "" : (known == 1 ? "Einen Prüfungstermin kenne ich schon aus QIS. " : "\(known) Prüfungstermine kenne ich schon aus QIS. ")
            return lead + "Wann sind deine anderen Prüfungen?"
        case .ready:
            return "Alles klar" + (displayName.map { ", \($0)" } ?? "") + "! Ich richte deinen Lernplan ein …"
        }
    }

    /// Antwort als eigene Sprechblase (nil: uebersprungen, ohne Blase)
    func answer(_ s: Step) -> String? {
        switch s {
        case .name: return displayName.map { "Nenn mich \($0)." }
        case .modules:
            let p = planned
            if modules.isEmpty { return nil }
            if p.isEmpty { return "Erst mal keine." }
            let names = p.prefix(3).map(\.name).joined(separator: ", ")
            return p.count > 3 ? "\(names) und \(p.count - 3) weitere." : names + "."
        case .exams:
            let n = withExam.count
            if planned.isEmpty { return nil }
            if n == 0 { return "Gerade keine Klausur." }
            return n == 1 ? "Ein Termin steht." : "\(n) Termine stehen."
        case .ready: return nil
        }
    }

    /// Fragen ohne Inhalt fallen weg: ohne Faecher keine Termin-Frage
    func next(after s: Step) -> Step {
        switch s {
        case .name: return .modules
        case .modules: return planned.isEmpty ? .ready : .exams
        case .exams, .ready: return .ready
        }
    }

    /// Fortschritt oben (drei Fragen)
    var progressIndex: Int { min(step.rawValue, 2) }

    /// Termin setzen (nur Faecher ohne Termin aus QIS)
    mutating func setExam(_ name: String, day: String?, none: Bool = false) {
        guard let i = modules.firstIndex(where: { $0.name == name }), !modules[i].examFromUni else { return }
        modules[i].exam = day
        modules[i].noExam = none
    }

    /// Faecher aus `GET /api/calendar/modules` und Termine aus `GET /api/modules` (gleicher Name)
    static func modules(calendar: JSONValue, list: JSONValue) -> [IntroSetupModule] {
        let rows = list.array ?? list["modules"]?.array ?? []
        return PlanModuleItem.list(calendar).map { item in
            let row = rows.first { $0["name"]?.string == item.name }
            let exam = row?["exam_date"]?.string.map { String($0.prefix(10)) }
            return IntroSetupModule(moduleID: row?["id"]?.int, name: item.name, color: item.color, planned: item.planned,
                                    exam: exam, examFromUni: exam != nil)
        }
    }

    static func iso(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Berlin")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// "Mo., 8. Feb. 2027"
    static func shown(_ iso: String) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Berlin")
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: String(iso.prefix(10))) else { return iso }
        let out = DateFormatter()
        out.locale = Locale(identifier: "de_DE")
        out.timeZone = f.timeZone
        out.dateFormat = "EE, d. MMM yyyy"
        return out.string(from: d)
    }
}

/// Die Fragen am offenen Container: laedt die Faecher, speichert jede Antwort sofort, `onDone` am Ende
struct IntroSetupView: View {
    /// `true`: Faecher fuer den Lernkalender gewaehlt (danach der Lernkalender statt der Übersicht)
    let onDone: (Bool) -> Void
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var account: AccountStore
    @State private var model = IntroSetupModel()
    @State private var loaded = false

    var body: some View {
        IntroSetupLayout(model: $model, onAnswer: answer, onSkipAll: { onDone(false) }, onFinish: finish)
            .task {
                guard !loaded else { return }
                loaded = true
                model.name = UFGreeting.name(for: account.account) ?? ""
                guard let api = session.api else { return }
                let cal = try? await api.value("/api/calendar/modules")
                let list = try? await api.value("/api/modules")
                model.modules = IntroSetupModel.modules(calendar: cal ?? .null, list: list ?? .null)
            }
    }

    /// Antwort uebernehmen und zur naechsten Frage
    private func answer(_ step: IntroSetupModel.Step) {
        switch step {
        case .name: Rufname.save(model.displayName)
        case .modules: saveModules()
        case .exams: saveExams()
        case .ready: finish(); return
        }
        withAnimation(UFMotion.animation(reduce: !UFMotion.moves)) { model.step = model.next(after: step) }
    }

    private func saveModules() {
        guard let api = session.api, !model.modules.isEmpty else { return }
        let items = model.modules.map { PlanModuleItem(name: $0.name, color: $0.color, planned: $0.planned) }
        Task {
            _ = try? await api.value("/api/calendar/modules", method: "POST", body: PlanModulesSheet.body(items))
            _ = try? await api.value("/api/calendar/modules", method: "POST", body: ["asked": true])
        }
    }

    private func saveExams() {
        guard let api = session.api else { return }
        let changes = model.planned.filter { !$0.examFromUni && $0.exam != nil }
        Task {
            for m in changes {
                guard let id = m.moduleID, let day = m.exam else { continue }
                _ = try? await api.value("/api/modules/\(id)", method: "PATCH", body: ["exam_date": .string(day)])
            }
        }
    }

    private func finish() { onDone(!model.planned.isEmpty && model.step == .ready) }
}

/// Aufbau der Fragen (ohne Netz, fuer Bilder und Tests)
struct IntroSetupLayout: View {
    @Binding var model: IntroSetupModel
    let onAnswer: (IntroSetupModel.Step) -> Void
    let onSkipAll: () -> Void
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            IntroTopBar(count: 3, index: model.progressIndex, skipTitle: "Später", onSkip: model.step == .ready ? nil : onSkipAll)
            GeometryReader { geo in
                if geo.size.width >= 900 {
                    HStack(alignment: .top, spacing: 32) {
                        IntroChatHistory(model: model).frame(width: min(480, geo.size.width * 0.42))
                        IntroAnswerPanel(model: $model, onAnswer: onAnswer, onFinish: onFinish).frame(maxWidth: 560)
                    }
                    .padding(.horizontal, 40).padding(.top, 28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            IntroChatHistory(model: model)
                            IntroAnswerPanel(model: $model, onAnswer: onAnswer, onFinish: onFinish)
                        }
                        .frame(maxWidth: IntroStyle.column)
                        .padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 30)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .background(UF.bg.ignoresSafeArea())
    }
}

/// Bisheriges Gespraech: vergangene Fragen klein mit Antwort, die aktuelle gross
struct IntroChatHistory: View {
    let model: IntroSetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(IntroSetupModel.Step.allCases.filter { $0.rawValue < model.step.rawValue && !skipped($0) }, id: \.self) { s in
                IntroSays(text: model.question(s))
                    .opacity(0.75)
                if let a = model.answer(s) {
                    HStack { Spacer(minLength: 60); IntroBubble(text: a, mine: true) }
                }
            }
            IntroSays(text: model.question(model.step), large: true)
                .id(model.step)
                .transition(.opacity.combined(with: .offset(y: 10)))
                .accessibilityIdentifier("intro.setup.question")
        }
    }

    /// Termin-Frage ohne geplante Faecher wurde gar nicht gestellt
    private func skipped(_ s: IntroSetupModel.Step) -> Bool { s == .exams && model.planned.isEmpty }
}

/// Antwortflaeche zur aktuellen Frage
struct IntroAnswerPanel: View {
    @Binding var model: IntroSetupModel
    let onAnswer: (IntroSetupModel.Step) -> Void
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch model.step {
            case .name: IntroNameAnswer(name: $model.name)
            case .modules: IntroModulesAnswer(modules: $model.modules)
            case .exams: IntroExamsAnswer(model: $model)
            case .ready: IntroReadyAnswer(model: model)
            }
            HStack(spacing: 16) {
                IntroCTA(title: model.step == .ready ? "Weiter" : "Weiter") { onAnswer(model.step) }
                    .accessibilityIdentifier("intro.setup.next")
                if model.step == .name {
                    Button("Ohne Namen weiter") { model.name = ""; onAnswer(.name) }
                        .ufFont(14.5, 550).foregroundStyle(UF.text2).buttonStyle(.plain).ufHitArea()
                }
            }
        }
        .id(model.step)
        .transition(.opacity)
    }
}

/// Frage 1: Rufname
struct IntroNameAnswer: View {
    @Binding var name: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Dein Rufname", text: $name)
                .ufFont(22, 600)
                .foregroundStyle(UF.text)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .focused($focused)
                .padding(.vertical, 14).padding(.horizontal, 18)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(UF.surface))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(focused ? UF.accent : UF.lineStrong, lineWidth: focused ? 2 : 1))
                .accessibilityIdentifier("intro.setup.name")
            Text(UFDevice.adapt("Für „Hallo … – lass uns gemeinsam lernen.“ auf der Übersicht. Bleibt auf diesem iPad."))
                .ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Frage 2: Faecher fuer den Lernkalender
struct IntroModulesAnswer: View {
    @Binding var modules: [IntroSetupModule]

    var body: some View {
        if modules.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 10) {
                ForEach($modules) { $m in IntroModuleToggle(module: $m) }
                Text(PlanModulesText.note).ufFont(12.8).foregroundStyle(UF.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct IntroModuleToggle: View {
    @Binding var module: IntroSetupModule

    var body: some View {
        Button { module.planned.toggle() } label: {
            HStack(spacing: 12) {
                Circle().fill(Color(hex: module.color)).frame(width: 12, height: 12)
                Text(module.name).ufFont(15.5, 600).foregroundStyle(UF.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                UFIcon(module.planned ? "check" : "plus", size: 15)
                    .foregroundStyle(module.planned ? Color.white : UF.text2)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(module.planned ? UF.accentFill : UF.surface2))
            }
            .padding(.vertical, 12).padding(.horizontal, 16)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(UF.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(module.planned ? UF.accent : UF.line, lineWidth: module.planned ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(module.name)
        .accessibilityValue(module.planned ? "im Lernkalender" : "nicht im Lernkalender")
        .accessibilityAddTraits(module.planned ? .isSelected : [])
    }
}

/// Frage 3: Pruefungstermine je gewaehltem Fach
struct IntroExamsAnswer: View {
    @Binding var model: IntroSetupModel

    var body: some View {
        VStack(spacing: 10) {
            ForEach(model.planned) { m in
                IntroExamRow(module: m) { day, none in model.setExam(m.name, day: day, none: none) }
            }
        }
    }
}

/// Ein Fach mit Termin aus QIS oder Schnellwahl
struct IntroExamRow: View {
    let module: IntroSetupModule
    let onSet: (String?, Bool) -> Void
    @State private var picking = false
    @State private var picked = Date().addingTimeInterval(14 * 86_400)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Circle().fill(Color(hex: module.color)).frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(module.name).ufFont(15.5, 600).foregroundStyle(UF.text)
                    Text(status).ufFont(13.12).foregroundStyle(module.exam == nil ? UF.muted : UF.text2)
                }
                Spacer(minLength: 8)
                if module.examFromUni {
                    UFBadge("aus QIS", tone: .ok, icon: "check")
                } else {
                    Menu {
                        ForEach(IntroExamChoice.allCases) { c in
                            Button(c.title) { choose(c) }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(module.exam == nil && !module.noExam ? "Termin wählen" : "Ändern")
                            UFIcon("chevron-down", size: 12)
                        }
                        .ufFont(13.6, 600).foregroundStyle(UF.accentText)
                        .padding(.vertical, 7).padding(.horizontal, 12)
                        .background(Capsule().fill(UF.accentSoft))
                    }
                    .accessibilityIdentifier("intro.exam.\(module.name)")
                }
            }
            if picking {
                DatePicker("Prüfungstag", selection: $picked, in: Date()..., displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .environment(\.locale, Locale(identifier: "de_DE"))
                    .ufFont(14.5)
                    .onChange(of: picked) { _, d in onSet(IntroSetupModel.iso(d), false) }
                    .ufReveal()
            }
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(UF.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(UF.line, lineWidth: 1))
    }

    private var status: String {
        if let e = module.exam { return "Klausur am " + IntroSetupModel.shown(e) }
        return module.noExam ? "Keine Klausur" : "Noch kein Termin"
    }

    private func choose(_ c: IntroExamChoice) {
        switch c {
        case .date:
            UFMotion.toggle { picking = true }
            onSet(IntroSetupModel.iso(picked), false)
        case .none:
            picking = false
            onSet(nil, true)
        case .week, .month:
            picking = false
            onSet(c.day(from: Date()).map(IntroSetupModel.iso), false)
        }
    }
}

/// Zum Schluss: was eingerichtet ist, mit Haken
struct IntroReadyAnswer: View {
    let model: IntroSetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            IntroReadyRow(text: model.displayName.map { "Begrüßung für \($0)" } ?? "Begrüßung mit deinem Vornamen", index: 0)
            IntroReadyRow(text: model.planned.isEmpty ? "Fächer wählst du später" : "\(model.planned.count) \(model.planned.count == 1 ? "Fach" : "Fächer") im Lernkalender", index: 1)
            IntroReadyRow(text: model.withExam.isEmpty ? "Prüfungstermine ergänzt QIS" : "\(model.withExam.count) \(model.withExam.count == 1 ? "Prüfungstermin" : "Prüfungstermine") im Kalender", index: 2)
            IntroReadyRow(text: "Dein erster Lernplan", index: 3)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(UF.surface))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(UF.line, lineWidth: 1))
    }
}

struct IntroReadyRow: View {
    let text: String
    let index: Int
    @State private var shown = !UFMotion.moves

    var body: some View {
        HStack(spacing: 12) {
            UFIcon("check", size: 15).foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(shown ? UF.okFill : UF.lineStrong))
            Text(text).ufFont(15.5, 550).foregroundStyle(UF.text)
        }
        .opacity(shown ? 1 : 0.4)
        .task {
            guard !shown else { return }
            try? await Task.sleep(nanoseconds: UInt64(350_000_000 * (index + 1)))
            withAnimation(UFMotion.springCurve) { shown = true }
        }
    }
}

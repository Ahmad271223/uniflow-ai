import SwiftUI
import UniFlowCore

/// Klausur-Generator (Auftrag des Inhabers vom 17.11.2026): Pro AI waehlt in EINEM Modul Vorlesungen, Skripte, Uebungen
/// und Altklausuren aus, die StudiNow-KI erstellt daraus bis zu 10 Probeklausuren als PDF mit Loesungen.
///
/// Stufe (a): Karte auf der Modulseite und das Blatt mit der Auswahl (Haken, Zaehler, Grenzen). Die Regeln stehen im
/// Kern (`ExamGeneratorSelection`). Kostenanzeige, Start und Ergebnis folgen in den naechsten Stufen.
///
/// Nicht zu verwechseln mit der "Probeklausur" der Wochentests (`MockExamDialog`): das ist ein Test in der App.
enum ExamGenerator {
    /// Schalter fuer die ganze Funktion (aus = nirgends sichtbar)
    static var isEnabled = true

    static let title = "Klausur-Generator"
    static let intro = "Die KI liest deine Vorlesungen, Übungen und Altklausuren und erstellt daraus Probeklausuren als PDF, mit Lösungen."
    static let open = "Unterlagen auswählen"
    static let pickerTitle = "Unterlagen für die Probeklausuren"
    static let selectAll = "Alles auswählen"
    static let selectNone = "Nichts auswählen"
    static let next = "Weiter zu den Kosten"
    static let cancel = "Abbrechen"
    static let empty = "In diesem Modul gibt es noch keine PDFs."
    static let notLoaded = "nicht auf dem Gerät"
    static let countLabel = "Probeklausuren"
    // Kauf (18.11.2026: einmal erzeugen, an alle verkaufen, 15 Credits je Probeklausur)
    static let buyTitle = "Probeklausuren kaufen"
    static let back = "Zurück"
    static let close = "Schließen"
    static let working = "StudiNow erstellt deine Probeklausuren. Das dauert einige Minuten. Du kannst das Blatt schließen; fertige Probeklausuren holst du hier wieder ab."
    static let fetchAgain = "Fertige abholen"
    static let sendNote = "Für neue Probeklausuren gehen die Seitentexte der gewählten Dateien einmal an StudiNow und die KI. Fertige Probeklausuren sind sofort da. Klappt etwas nicht, kostet es nichts."
    static let savedNote = "Fertige Probeklausuren liegen in der Bibliothek im Ordner „Probeklausuren“ dieses Moduls."
    static let allOwned = "Zu diesen Unterlagen hast du schon alle Probeklausuren."

    static func buyButton(_ credits: Int) -> String { "Für \(credits) Credits kaufen" }

    /// "3 Probeklausuren × 15 Credits = 45 Credits"
    static func priceLine(count: Int, price: Int) -> String {
        "\(count) \(count == 1 ? "Probeklausur" : "Probeklausuren") × \(price) Credits = \(count * price) Credits"
    }

    /// "1 ist schon fertig (sofort da), 2 erstellt StudiNow neu (einige Minuten)."
    static func splitLine(ready: Int, new: Int) -> String {
        var parts: [String] = []
        if ready > 0 { parts.append("\(ready) \(ready == 1 ? "ist" : "sind") schon fertig (sofort da)") }
        if new > 0 { parts.append("\(new) erstellt StudiNow neu (einige Minuten)") }
        return parts.joined(separator: ", ") + "."
    }

    static func statusText(_ status: String?, hasFiles: Bool) -> String {
        if hasFiles { return "liegt im Modul" }
        switch status {
        case "ready": return "fertig"
        case "pending", "running": return "wird erstellt"
        case "failed": return "hat nicht geklappt – nichts berechnet"
        default: return ""
        }
    }

    static func sectionTitle(_ g: ExamGeneratorSelection.Group) -> String {
        switch g {
        case .material: return "Vorlesung und Skript"
        case .exams: return "Altklausuren"
        case .exercises: return "Übungen"
        }
    }

    /// Zaehler rechts neben der Ueberschrift: "212 von 300 Seiten", "4 von 10"
    static func counter(_ g: ExamGeneratorSelection.Group, _ c: ExamGeneratorSelection.Check, limits: ExamGeneratorSelection.Limits) -> String {
        switch g {
        case .material: return "\(c.materialPages) von \(limits.materialPages) Seiten"
        case .exams: return "\(c.examFiles) von \(limits.examFiles)"
        case .exercises: return "\(c.exerciseFiles) von \(limits.exerciseFiles)"
        }
    }

    static func isOver(_ g: ExamGeneratorSelection.Group, _ c: ExamGeneratorSelection.Check, limits: ExamGeneratorSelection.Limits) -> Bool {
        switch g {
        case .material: return c.materialPages > limits.materialPages
        case .exams: return c.examFiles > limits.examFiles || c.examSolutions > limits.examFiles
        case .exercises: return c.exerciseFiles > limits.exerciseFiles || c.exerciseSolutions > limits.exerciseFiles
        }
    }

    static func pages(_ n: Int) -> String { n == 1 ? "1 Seite" : "\(n) Seiten" }

    /// VoiceOver einer Zeile: "VL01 Folgen, Vorlesung, 24 Seiten, ausgewählt"
    static func rowAccessibility(_ it: ExamGeneratorSelection.Item, selected: Bool) -> String {
        guard it.isAvailable, let p = it.pages else { return "\(it.title), \(it.label), \(notLoaded)" }
        return "\(it.title), \(it.label), \(pages(p)), \(selected ? "ausgewählt" : "nicht ausgewählt")"
    }
}

// MARK: - Karte auf der Modulseite

/// Karte "Klausur-Generator" in der Uebersicht eines Moduls. Ohne Pro AI mit Schloss "ab Pro AI" (Antippen oeffnet
/// die Tarifwahl); ist Pro AI nicht zu kaufen (`ufProAIOfferHidden`), zeigt die Stelle nichts.
struct ExamGeneratorCard: View {
    let moduleID: Int
    let moduleName: String
    @ObservedObject private var ent = Entitlements.shared
    @Environment(\.ufProAIOfferHidden) private var proAIOfferHidden
    @State private var picker = false
    @State private var plan: UFPlan?

    /// Schloss: die Funktion gehoert zur StudiNow-KI (wie die KI-Lernhilfe), ein eigenes ChatGPT reicht nicht
    private var lock: UFPlan? { UFLock.plan(.aiHelp, plan: ent.plan) }

    var body: some View {
        if ExamGenerator.isEnabled, !(lock != nil && proAIOfferHidden) {
            UFCard {
                UFCardHead(ExamGenerator.title, icon: "flag", wrap: true) { UFLockMark(lock) }
                Text(ExamGenerator.intro).ufFont(13.6).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                UFButton(lock.map { UFLock.label(ExamGenerator.open, $0) } ?? ExamGenerator.open, icon: lock == nil ? "sparkles" : nil,
                         kind: .primary, size: .small) {
                    if let lock { plan = lock } else { picker = true }
                }
                .ufLockAccessibility(lock)
                .accessibilityIdentifier("examgen.open")
                .padding(.top, 10)
            }
            .padding(.bottom, 14.4)
            .ufPlanSheet($plan)
            .ufSheet(isPresented: $picker) {
                ExamGeneratorFlow(moduleID: moduleID, moduleName: moduleName) { picker = false }
            }
        }
    }
}

// MARK: - Blatt mit der Auswahl

/// Auswahl der PDFs eines Moduls: drei Gruppen mit Haken, Zaehler je Gruppe, "Alles auswählen", Zahl der
/// Probeklausuren (1 bis 10). "Weiter" geht erst, wenn die Auswahl in die Grenzen passt.
struct ExamGeneratorPicker: View {
    let moduleID: Int
    let moduleName: String
    let close: () -> Void
    /// gewaehlte Dateien und Zahl der Probeklausuren
    let next: (_ fileIDs: [String], _ mockExams: Int) -> Void

    @EnvironmentObject private var session: Session
    @State private var items: [ExamGeneratorSelection.Item]?
    @State private var limits = ExamGeneratorSelection.limits
    @State private var selected: Set<String> = []
    @State private var count = 1
    @State private var error: String?

    private var check: ExamGeneratorSelection.Check {
        ExamGeneratorSelection.check(items ?? [], selected: selected, mockExams: count, limits: limits)
    }

    var body: some View {
        let c = check
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    head
                    if let error {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            UFIcon("alert", size: 14).foregroundStyle(UF.bad)
                            Text(error).ufFont(13.6).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            UFButton("Erneut laden", icon: "refresh", kind: .ghost, size: .small) { Task { await load() } }
                        }
                    } else if let items {
                        if items.isEmpty {
                            UFEmpty(icon: "file", text: ExamGenerator.empty, small: true)
                        } else {
                            ForEach(ExamGeneratorSelection.Group.allCases, id: \.self) { g in section(g, items: items, c) }
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
                    }
                }
                .padding(20)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            Divider().overlay(UF.line)
            foot(c)
        }
        .background(UF.surface)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task { await load() }
    }

    private var head: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                UFIcon("flag", size: 20).foregroundStyle(UF.accentFill).accessibilityHidden(true)
                Text(ExamGenerator.pickerTitle).ufFont(20, 700, em: -0.01).foregroundStyle(UF.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("examgen.title")
            }
            Text(moduleName).ufFont(14.5, 600).foregroundStyle(UF.text2)
            Text("Höchstens \(limits.materialPages) Seiten Vorlesung und Skript, dazu \(limits.examFiles) Altklausuren und \(limits.exerciseFiles) Übungen.")
                .ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            if let items, !items.isEmpty {
                HStack(spacing: 8) {
                    UFButton(ExamGenerator.selectAll, icon: "check", size: .small) {
                        selected = ExamGeneratorSelection.all(items, limits: limits)
                    }
                    .accessibilityIdentifier("examgen.all")
                    UFButton(ExamGenerator.selectNone, kind: .ghost, size: .small) { selected = [] }
                        .disabled(selected.isEmpty)
                        .accessibilityIdentifier("examgen.none")
                }
                .padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private func section(_ g: ExamGeneratorSelection.Group, items: [ExamGeneratorSelection.Item], _ c: ExamGeneratorSelection.Check) -> some View {
        // neueste zuerst; Loesungen stehen bei ihrer Gruppe
        let list = items.filter { $0.group == g }.sorted { ($0.chdate, $0.id) > ($1.chdate, $1.id) }
        if !list.isEmpty {
            let over = ExamGenerator.isOver(g, c, limits: limits)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ExamGenerator.sectionTitle(g)).ufFont(15.2, 650, em: -0.01).foregroundStyle(UF.text)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    Text(ExamGenerator.counter(g, c, limits: limits)).ufFont(13.12, 650)
                        .foregroundStyle(over ? UF.bad : UF.text2)
                        .monospacedDigit()
                        .accessibilityIdentifier("examgen.counter.\(g.rawValue)")
                }
                VStack(spacing: 0) {
                    ForEach(list) { it in
                        row(it)
                        if it.id != list.last?.id { Divider().overlay(UF.line).padding(.leading, 44) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: UF.r, style: .continuous).fill(UF.surface2))
                .overlay(RoundedRectangle(cornerRadius: UF.r, style: .continuous).strokeBorder(over ? UF.bad : UF.line, lineWidth: 1))
            }
        }
    }

    private func row(_ it: ExamGeneratorSelection.Item) -> some View {
        let on = selected.contains(it.id)
        return Button {
            guard it.isAvailable else { return }
            if on { selected.remove(it.id) } else { selected.insert(it.id) }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(on ? UF.accentFill : UF.muted)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(it.title).ufFont(14.5, 600).foregroundStyle(UF.text)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    Text(it.label).ufFont(12.4).foregroundStyle(UF.muted)
                }
                Spacer(minLength: 8)
                Text(it.pages.flatMap { $0 > 0 ? ExamGenerator.pages($0) : nil } ?? ExamGenerator.notLoaded)
                    .ufFont(12.8, 600).foregroundStyle(UF.text2).monospacedDigit()
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!it.isAvailable)
        .opacity(it.isAvailable ? 1 : 0.5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ExamGenerator.rowAccessibility(it, selected: on))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("examgen.file.\(it.id)")
    }

    private func foot(_ c: ExamGeneratorSelection.Check) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // erst ab der ersten Auswahl melden, was fehlt (vorher steht dort nur der leere Zaehler)
            if !selected.isEmpty, let p = c.problems.first {
                Text(p).ufFont(13.12, 600).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("examgen.problem")
            } else if !selected.isEmpty, let h = c.hint {
                Text(h).ufFont(13.12).foregroundStyle(UF.warnText).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("examgen.hint")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { stepper; Spacer(minLength: 8); buttons(c) }
                VStack(alignment: .leading, spacing: 10) { stepper; HStack { Spacer(minLength: 0); buttons(c) } }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity)
        .background(UF.surface)
    }

    private var stepper: some View {
        Stepper(value: $count, in: 1...limits.mockExams) {
            Text("\(count) \(count == 1 ? "Probeklausur" : ExamGenerator.countLabel)").ufFont(14.5, 650).foregroundStyle(UF.text)
                .monospacedDigit()
        }
        .fixedSize()
        .accessibilityIdentifier("examgen.count")
    }

    private func buttons(_ c: ExamGeneratorSelection.Check) -> some View {
        HStack(spacing: 8) {
            UFButton(ExamGenerator.cancel, kind: .ghost) { close() }
                .accessibilityIdentifier("examgen.cancel")
            UFButton(ExamGenerator.next, kind: .primary) {
                let ids = (items ?? []).filter { selected.contains($0.id) && $0.isAvailable }.map(\.id)
                next(ids, count)
            }
            .disabled(!c.isValid)
            .accessibilityIdentifier("examgen.next")
        }
    }

    private func load() async {
        guard let api = session.api else { error = "Nicht mit dem Gerät verbunden."; return }
        do {
            let v = try await api.value("/api/modules/\(moduleID)/exam-generator/files")
            let l = v["limits"] ?? .null
            var lim = ExamGeneratorSelection.Limits()
            lim.materialPages = l.i("material_pages") ?? lim.materialPages
            lim.examFiles = l.i("exam_files") ?? lim.examFiles
            lim.exerciseFiles = l.i("exercise_files") ?? lim.exerciseFiles
            lim.mockExams = l.i("mock_exams") ?? lim.mockExams
            limits = lim
            items = v.list("files").compactMap(ExamGeneratorSelection.Item.init(json:))
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Ablauf im Blatt: Auswahl -> Kosten -> Kauf -> Abholen

/// Ein Blatt fuer den ganzen Ablauf: erst die Auswahl (`ExamGeneratorPicker`), dann Kosten und Kauf
/// (`ExamGeneratorBuy`). Zurueck fuehrt zur Auswahl mit derselben Auswahl.
struct ExamGeneratorFlow: View {
    let moduleID: Int
    let moduleName: String
    let close: () -> Void
    @State private var choice: (ids: [String], count: Int)?

    var body: some View {
        if let choice {
            ExamGeneratorBuy(moduleID: moduleID, moduleName: moduleName, fileIDs: choice.ids, count: choice.count,
                             back: { self.choice = nil }, close: close)
        } else {
            ExamGeneratorPicker(moduleID: moduleID, moduleName: moduleName, close: close) { ids, count in choice = (ids, count) }
        }
    }
}

/// Kosten zeigen, kaufen, fertige Probeklausuren abholen (in den Ordner „Probeklausuren“ des Moduls)
struct ExamGeneratorBuy: View {
    let moduleID: Int
    let moduleName: String
    let fileIDs: [String]
    let count: Int
    let back: () -> Void
    let close: () -> Void

    @EnvironmentObject private var session: Session
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufStudoraAccount) private var account
    @State private var state: JSONValue?
    @State private var error: String?
    @State private var busy = false
    @State private var bought = false
    @State private var shop = false

    private var request: [String: JSONValue] { ["file_ids": .array(fileIDs.map(JSONValue.string)), "count": .number(Double(count))] }
    private var variants: [JSONValue] { state?.list("variants") ?? [] }
    private var price: Int { state?.i("price") ?? 15 }
    /// die naechsten `count`, die das Konto noch nicht hat (wie der Dienst waehlt)
    private var next: [JSONValue] { Array(variants.filter { $0["owned"]?.bool != true }.prefix(count)) }
    private var mine: [JSONValue] { variants.filter { $0["owned"]?.bool == true } }
    private var pending: Bool { mine.contains { ["pending", "running"].contains($0.s("status") ?? "") } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    UFIcon("flag", size: 20).foregroundStyle(UF.accentFill).accessibilityHidden(true)
                    Text(ExamGenerator.buyTitle).ufFont(20, 700, em: -0.01).foregroundStyle(UF.text)
                        .accessibilityAddTraits(.isHeader).accessibilityIdentifier("examgen.buy.title")
                }
                Text(moduleName).ufFont(14.5, 600).foregroundStyle(UF.text2)
                if let error {
                    Text(error).ufFont(13.6, 600).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("examgen.buy.error")
                }
                if state == nil && error == nil {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
                } else if !bought {
                    offerView
                }
                if !mine.isEmpty { mineView }
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(UF.surface)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task { await load() }
        .task(id: bought) {
            // nach dem Kauf: fertige abholen, solange etwas erstellt wird (alle 8 s, hoechstens 30 min)
            guard bought else { return }
            for _ in 0..<225 {
                await collect()
                if !pending || Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 8_000_000_000)
            }
        }
        .ufCreditShop(isPresented: $shop)
    }

    @ViewBuilder private var offerView: some View {
        if next.isEmpty {
            Text(ExamGenerator.allOwned).ufFont(14.5).foregroundStyle(UF.text)
        } else {
            let ready = next.filter { $0.s("status") == "ready" }.count
            VStack(alignment: .leading, spacing: 8) {
                Text(ExamGenerator.priceLine(count: next.count, price: price)).ufFont(17.6, 700).foregroundStyle(UF.text)
                    .accessibilityIdentifier("examgen.buy.price")
                Text(ExamGenerator.splitLine(ready: ready, new: next.count - ready)).ufFont(14.5).foregroundStyle(UF.text2)
                    .fixedSize(horizontal: false, vertical: true)
                if let line = AICost.balanceLine(account?.credits, trial: account?.planStatus?.trialActive ?? false) {
                    Text(line).ufFont(13.6, 600).foregroundStyle(UF.text2).accessibilityIdentifier("examgen.buy.balance")
                }
                Text(ExamGenerator.sendNote).ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                UFButton(ExamGenerator.back, kind: .ghost) { back() }.accessibilityIdentifier("examgen.buy.back")
                Spacer(minLength: 0)
                UFButton(ExamGenerator.buyButton(next.count * price), kind: .primary) { Task { await buy() } }
                    .disabled(busy)
                    .accessibilityIdentifier("examgen.buy.go")
            }
        }
    }

    private var mineView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if pending {
                HStack(alignment: .top, spacing: 10) {
                    ProgressView()
                    Text(ExamGenerator.working).ufFont(13.6).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(Row.rows(mine, key: "key")) { row in
                let v = row.value
                let files = v["files"]?.object ?? [:]
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Probeklausur \(v.i("variant") ?? 0)").ufFont(14.5, 600).foregroundStyle(UF.text)
                        Text(ExamGenerator.statusText(v.s("status"), hasFiles: !files.isEmpty)).ufFont(12.4).foregroundStyle(UF.muted)
                    }
                    Spacer(minLength: 8)
                    if let a = files["aufgaben"]?.string {
                        UFButton("Aufgaben", icon: "file", size: .small) { close(); router.go(.doc(a)) }
                    }
                    if let l = files["loesungen"]?.string {
                        UFButton("Lösungen", icon: "check", kind: .ghost, size: .small) { close(); router.go(.doc(l)) }
                    }
                }
                .accessibilityIdentifier("examgen.mine.\(v.i("variant") ?? 0)")
            }
            Text(ExamGenerator.savedNote).ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                UFButton(ExamGenerator.fetchAgain, icon: "refresh", kind: .ghost, size: .small) { Task { await collect() } }
                Spacer(minLength: 0)
                UFButton(ExamGenerator.close) { close() }.accessibilityIdentifier("examgen.buy.close")
            }
        }
        .padding(.top, 6)
    }

    private func call(_ path: String) async -> JSONValue? {
        guard let api = session.api else { error = "Nicht mit dem Gerät verbunden."; return nil }
        do {
            let v = try await api.value("/api/modules/\(moduleID)/exam-generator/\(path)", method: "POST", body: .object(request))
            error = nil
            return v
        } catch let e as APIError {
            if e.code == "credits_exhausted" { shop = true }
            error = e.localizedDescription
        } catch {
            self.error = error.localizedDescription
        }
        return nil
    }

    private func load() async {
        if let v = await call("offer") {
            state = v
            if !mine.isEmpty { await collect() }
        }
    }

    private func buy() async {
        busy = true
        defer { busy = false }
        if let v = await call("buy") {
            state = v
            bought = true
            await account?.refreshCredits()
        }
    }

    private func collect() async {
        if let v = await call("collect") { state = v }
    }
}

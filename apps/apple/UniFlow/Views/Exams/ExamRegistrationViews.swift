import Combine
import SwiftUI
import UniFlowCore

// Pruefungsanmeldung (Entscheidung des Inhabers 05.11.2026, docs/PRUEFUNGSANMELDUNG-2026-11-05.md). Daten aus
// GET /api/exam-registration (Kern: ExamRegistrationAPI): Meldezeitraum des Studiengangs, "Diese Prüfungen solltest du
// anmelden" mit Grund und Termin, abgehakt ueber den Notenspiegel (Vermerk AN) und "Info über angemeldete Prüfungen".
// Gezeigt:
// - Uebersicht: Karte "Prüfungsanmeldung" im Meldezeitraum und in den 7 Tagen davor (`ExamRegistrationCard`)
// - Studienverlauf: Abschnitt mit Zeitraeumen, allen Vorschlaegen, gelesenen Anmeldungen, Erinnerungen (`ExamRegistrationSection`)
// - Karte "Nächste Klausuren": Abzeichen angemeldet/nicht angemeldet und eine Zeile zum Meldezeitraum
// - Moduldetails im Studienverlauf und Modulseite: Block "Prüfung anmelden" (`ExamRegistrationModuleBlock`)
// "Im QIS zur Prüfung anmelden" oeffnet nur "Mein Studium" im In-App-Browser (`openURL` -> `UniWebBrowser`, gleiche
// Cookies wie der Notenabruf); anmelden und bestaetigen tut der Mensch dort selbst. Die App fuellt nichts aus und schickt
// nichts ab. Nach dem Schliessen dieses Browsers ruft die App die angemeldeten Pruefungen einmal selbst ab
// (`ExamRegistrationAutoFetch`, Befund des Inhabers 09.11.2026: er erwartete danach "angemeldet").
// Uni Hildesheim (`system` "LSF"): "Im LSF zur Prüfung anmelden" oeffnet die Startseite des LSF (`UniversityProfile.hildesheimLSFStart`),
// der Meldezeitraum hat kein Ende (`openEnd`: Start der POS-Anmeldung, Fristen je Pruefung im LSF), "Angemeldete Prüfungen
// abrufen" liest "Meine POS-Anmeldungen" (`HildesheimConnection.fetchRegistrations`).

/// Antwort von GET /api/exam-registration
struct ExamRegistrationState: Equatable {
    struct Window: Equatable {
        let term: String
        let kind: String
        let label: String
        let start: String
        let end: String
        let phase: String
        let daysLeft: Int
        let daysUntil: Int
        /// kein Ende bekannt (Uni Hildesheim: Fristen je Pruefung im LSF); `end` ist dann das Semesterende
        let openEnd: Bool

        init?(_ v: JSONValue?) {
            guard let v, let term = v.s("term"), let start = v.s("start"), let end = v.s("end") else { return nil }
            self.term = term
            kind = v.s("kind") ?? "meldung"
            label = v.s("label") ?? "Meldezeitraum"
            self.start = start
            self.end = end
            phase = v.s("phase") ?? "later"
            daysLeft = v.i("days_left") ?? 0
            daysUntil = v.i("days_until") ?? 0
            openEnd = v["open_end"]?.bool ?? false
        }

        var isOpen: Bool { phase == "open" }
    }

    struct Period: Equatable, Identifiable {
        let kind: String
        let label: String
        let start: String
        let end: String
        var openEnd = false
        var id: String { kind + start + end }
    }

    struct Suggestion: Equatable, Identifiable {
        let id: String
        let title: String
        let lp: Double?
        let exam: String?
        let reason: String
        let reasonKind: String
        let examDate: String?
        let examTime: String?
        let examRoom: String?
        let registered: Bool
        let registeredVia: String?
        let period: String
        let withdrawUntil: String?
        let appModuleIDs: [Int]
        let lastAttempt: Bool
        /// Pruefungsnummer aus dem Katalog, wenn bekannt (Weg im QIS)
        let code: String?

        init(_ v: JSONValue) {
            id = v.s("id") ?? UUID().uuidString
            title = v.s("title") ?? "Prüfung"
            code = v.s("code")
            lp = v.n("lp")
            exam = v.s("exam")
            reason = v.s("reason") ?? ""
            reasonKind = v.s("reason_kind") ?? "plan"
            examDate = v.s("exam_date")
            examTime = v.s("exam_time")
            examRoom = v.s("exam_room")
            registered = v["registered"]?.bool ?? false
            registeredVia = v.s("registered_via")
            period = v.s("period") ?? "meldung"
            withdrawUntil = v.s("withdraw_until")
            appModuleIDs = v.list("app_module_ids").compactMap(\.int)
            lastAttempt = v["last_attempt"]?.bool ?? false
        }
    }

    struct Registered: Equatable, Identifiable {
        let id: Int
        let text: String
        let date: String?
        let dateText: String?
        let time: String?
        let registered: Bool
        let withdrawUntil: String?
    }

    let supported: Bool
    let programName: String?
    let verified: Bool
    let sourceURL: URL?
    let checkedAt: String?
    let term: String?
    let window: Window?
    let vbpWindow: Window?
    let periods: [Period]
    let showCard: Bool
    let planAvailable: Bool
    let planMessage: String?
    let suggestions: [Suggestion]
    let openCount: Int
    let registered: [Registered]
    let registrationsCheckedAt: String?
    let registrationsMessage: String?
    let registrationsOK: Bool
    let warnings: [(tone: String, text: String)]
    let qisURL: URL?
    let hint: String
    let rules: [String]
    let disclaimer: String
    /// "QIS" (LUH) oder "LSF" (Uni Hildesheim)
    let system: String
    /// "Im QIS zur Prüfung anmelden" / "Im LSF zur Prüfung anmelden"
    let openLabel: String
    /// Hinweis statt der Zeitraeume (Uni Hildesheim: keine einheitliche Frist)
    let periodNote: String?

    init(_ v: JSONValue) {
        supported = v["supported"]?.bool ?? false
        programName = v.s("program_name")
        verified = v["program"]?["verified"]?.bool ?? false
        sourceURL = UFDayExtras.safeURL(v["source"]?.s("url"))
        checkedAt = v["source"]?.s("checked_at")
        term = v.s("term")
        window = Window(v["window"])
        vbpWindow = Window(v["vbp_window"])
        periods = v.list("periods").map {
            Period(kind: $0.s("kind") ?? "", label: $0.s("label") ?? "", start: $0.s("start") ?? "", end: $0.s("end") ?? "",
                   openEnd: $0["open_end"]?.bool ?? false)
        }
        showCard = v["show_card"]?.bool ?? false
        planAvailable = v["plan_available"]?.bool ?? false
        planMessage = v.s("plan_message")
        suggestions = v.list("suggestions").map(Suggestion.init)
        openCount = v.i("open_count") ?? suggestions.filter { !$0.registered }.count
        registered = v.list("registered").enumerated().map { i, r in
            Registered(id: i, text: r.s("text") ?? "", date: r.s("date"), dateText: r.s("date_text"), time: r.s("time"),
                       registered: r["registered"]?.bool ?? true, withdrawUntil: r.s("withdraw_until"))
        }
        registrationsCheckedAt = v.s("registrations_checked_at")
        registrationsMessage = v.s("registrations_message")
        registrationsOK = v["registrations_ok"]?.bool ?? false
        warnings = v.list("warnings").map { ($0.s("tone") ?? "warn", $0.s("text") ?? "") }
        qisURL = UFDayExtras.safeURL(v.s("qis_url"))
        hint = v.s("hint") ?? ExamRegistrationAPI.hint
        rules = v.list("rules").compactMap { $0.string }
        disclaimer = v.s("disclaimer") ?? ExamRegistrationAPI.disclaimer
        system = v.s("system") ?? "QIS"
        openLabel = v.s("open_label") ?? ExamRegistrationAPI.openLabel(system)
        periodNote = v.s("period_note")
    }

    /// Pruefungen fuer den Weg im QIS (`QISRegistrationGuide`): zuerst `first`, dann die uebrigen noch nicht angemeldeten.
    /// Nur LUH (QIS); das LSF der Uni Hildesheim oeffnet wie bisher die Startseite.
    func guideTargets(first: Suggestion? = nil) -> [QISRegistrationTarget] {
        guard system == "QIS" else { return [] }
        let rest = suggestions.filter { !$0.registered && $0.id != first?.id }
        return ([first].compactMap { $0 } + rest).map { QISRegistrationTarget(title: $0.title, nr: $0.code) }
    }

    static func == (a: Self, b: Self) -> Bool {
        a.suggestions == b.suggestions && a.window == b.window && a.registered == b.registered && a.showCard == b.showCard
            && a.registrationsCheckedAt == b.registrationsCheckedAt && a.warnings.map(\.text) == b.warnings.map(\.text)
    }

    /// Antwort laden; nil ohne Verbindung, bei Fehler oder am PC-Server ohne den Pfad
    static func load(_ api: APIClient?) async -> ExamRegistrationState? {
        guard let api, let v = try? await api.value("/api/exam-registration") else { return nil }
        let s = ExamRegistrationState(v)
        return s.supported ? s : nil
    }

    /// Vorschlag zu einem Katalogmodul (Studienverlauf) bzw. einem Modul der App
    func suggestion(catalogID: String) -> Suggestion? { suggestions.first { $0.id == catalogID } }
    func suggestion(appModuleID: Int) -> Suggestion? { suggestions.first { $0.appModuleIDs.contains(appModuleID) } }

    /// Vorschlag zu einer Klausur der Liste "Nächste Klausuren" (Modul der App, sonst gleicher Namensschluessel)
    func suggestion(exam e: JSONValue) -> Suggestion? {
        if let m = e.i("module_id"), let s = suggestion(appModuleID: m) { return s }
        let names = [e.s("module_name"), e.s("course_title")].compactMap { $0 }.map(StudyPlanEngine.nameKey).filter { !$0.isEmpty }
        return suggestions.first { s in names.contains(StudyPlanEngine.nameKey(s.title)) }
    }
}

/// Texte (rein, testbar)
enum ExamRegistrationText {
    /// "So, 22.11."
    static func dayShort(_ iso: String?) -> String {
        guard let iso, Fmt.date(iso) != nil else { return iso ?? "" }
        return "\(UFFmt.weekdayShort(iso)), \(UFFmt.date(iso).prefix(6))"
    }

    /// "09.11.–22.11.2026"
    static func range(_ start: String, _ end: String) -> String {
        start == end ? UFFmt.date(end) : "\(UFFmt.date(start).prefix(6))–\(UFFmt.date(end))"
    }

    /// Zeile zum Fenster: "Meldezeitraum 09.11.–22.11.2026 · noch 13 Tage", "Anmeldung ab Mo, 09.11. (bis So, 22.11.)";
    /// ohne Ende (Uni Hildesheim): "Anmeldung im LSF seit Mi, 11.11. · Fristen je Prüfung im LSF"
    static func windowLine(_ w: ExamRegistrationState.Window, system: String = "QIS") -> String {
        let what = w.kind == "vbp_meldung" ? "Meldezeitraum VbP" : "Meldezeitraum"
        if w.openEnd {
            switch w.phase {
            case "open": return "Anmeldung im \(system) seit \(dayShort(w.start)) · Fristen je Prüfung im \(system)"
            case "soon": return "Anmeldung im \(system) ab \(dayShort(w.start)) (\(w.term)) · Fristen je Prüfung"
            default: return "Nächste Anmeldung im \(system): ab \(UFFmt.date(w.start)) (\(w.term))"
            }
        }
        switch w.phase {
        case "open":
            let left: String
            switch w.daysLeft {
            case 0: left = "heute letzter Tag"
            case 1: left = "morgen letzter Tag"
            default: left = "noch \(w.daysLeft) Tage"
            }
            return "\(what) \(range(w.start, w.end)) · \(left)"
        case "soon":
            return "Anmeldung ab \(dayShort(w.start)) bis \(dayShort(w.end)) (\(w.term))"
        default:
            return "Nächster \(what): \(range(w.start, w.end)) (\(w.term))"
        }
    }

    /// "Klausur Mo, 15.02.2027 · 09:00 Uhr · HS A · Rücktritt bis 08.02."
    static func examLine(_ s: ExamRegistrationState.Suggestion) -> String? {
        var parts: [String] = []
        if let d = s.examDate { parts.append("Termin \(UFFmt.weekdayShort(d)), \(UFFmt.date(d))") }
        if let t = s.examTime { parts.append("\(t) Uhr") }
        if let r = s.examRoom, !r.isEmpty { parts.append(r) }
        if let w = s.withdrawUntil { parts.append("Rücktritt bis \(dayShort(w))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func status(_ s: ExamRegistrationState.Suggestion) -> String { s.registered ? "angemeldet" : "nicht angemeldet" }

    static func accessibility(_ s: ExamRegistrationState.Suggestion) -> String {
        [s.title, status(s), s.reason, examLine(s), s.period == "vbp" ? "Meldezeitraum für VbP" : nil].compactMap { $0 }
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// Name der Seite mit den angemeldeten Pruefungen: QIS "Info über angemeldete Prüfungen", LSF "Meine POS-Anmeldungen"
    static func infoPage(_ system: String) -> String {
        system == "LSF" ? "Meine POS-Anmeldungen" : "Info über angemeldete Prüfungen"
    }

    /// "Abgehakt über den Notenspiegel (AN)" / "aus „Info über angemeldete Prüfungen“"
    static func via(_ s: ExamRegistrationState.Suggestion, system: String = "QIS") -> String? {
        switch s.registeredVia {
        case "notenspiegel": return system == "LSF" ? "im Notenspiegel als angemeldet geführt" : "im Notenspiegel als angemeldet (AN) geführt"
        case "qis_info": return "laut „\(infoPage(system))“"
        default: return nil
        }
    }

    /// "09.11.–22.11.2026", ohne Ende "ab 11.11.2026"
    static func periodRange(_ p: ExamRegistrationState.Period) -> String {
        p.openEnd ? "ab \(UFFmt.date(p.start))" : range(p.start, p.end)
    }

    /// Stand des letzten Abrufs der Info-Seite
    static func checked(_ st: ExamRegistrationState) -> String {
        guard let at = st.registrationsCheckedAt else {
            return st.system == "LSF"
                ? "Angemeldete Prüfungen noch nicht abgerufen. Abgehakt wird schon, was der Notenspiegel als angemeldet führt."
                : "Angemeldete Prüfungen noch nicht abgerufen. Abgehakt wird schon, was der Notenspiegel als „AN“ führt."
        }
        let when = "\(UFFmt.date(String(at.prefix(10)))) \(at.dropFirst(11).prefix(5)) Uhr"
        return "Zuletzt abgerufen \(when)" + (st.registrationsMessage.map { ": \($0)" } ?? "")
    }
}

// MARK: - Knoepfe

/// "Im QIS zur Prüfung anmelden": oeffnet "Mein Studium" im In-App-Browser der Hochschule (`openURL` -> `UniWebBrowser`);
/// Uni Hildesheim "Im LSF zur Prüfung anmelden": Startseite des LSF. Merkt sich das Oeffnen, damit nach dem Schliessen
/// einmal abgerufen wird (`ExamRegistrationAutoFetch`)
struct ExamRegistrationQISButton: View {
    let url: URL?
    var system: String = "QIS"
    var size: UFButtonSize = .regular
    /// Pruefungen, zu denen der Browser im QIS direkt fuehrt (erste zuerst; leer: nur "Mein Studium")
    var targets: [QISRegistrationTarget] = []
    @Environment(\.openURL) private var openURL
    @Environment(\.qis) private var qis
    @Environment(\.hildesheim) private var hildesheim
    @Environment(\.ufDemoActive) private var demo

    var body: some View {
        if let url {
            UFButton(ExamRegistrationAPI.openLabel(system), icon: "arrow-right", kind: .primary, size: size) {
                ExamRegistrationAutoFetch.shared.arm(url, qis: qis, hildesheim: hildesheim, demo: demo)
                if !demo { QISGuideRequests.set(url: url, targets: targets) }
                openURL(url)
            }
                .fixedSize()
                .accessibilityHint(targets.isEmpty
                    ? "Öffnet das \(system). Zur Prüfung anmelden und bestätigen tust du dort selbst; danach ruft StudiNow die angemeldeten Prüfungen ab."
                    : "Öffnet das \(system) und führt zu „\(targets[0].title)“. Auf „Prüfung anmelden“ tippst du dort selbst; danach ruft StudiNow die angemeldeten Prüfungen ab.")
                .accessibilityIdentifier("examreg.qis")
        }
    }
}

/// Nach dem Schliessen des In-App-Browsers, den "Im QIS/LSF zur Prüfung anmelden" geoeffnet hat: einmal die angemeldeten
/// Pruefungen abrufen, derselbe Weg wie "Angemeldete Prüfungen abrufen" (`fetchRegistrations` erhoeht `finishedRuns`,
/// die offenen Ansichten laden neu). Nur mit bestehender Verbindung (nicht "erneut anmelden"), nie in der Demo, hoechstens
/// einmal je Schliessen (danach nicht mehr vorgemerkt). Andere geschlossene Seiten (anderer Rechner) zaehlen nicht.
@MainActor
final class ExamRegistrationAutoFetch {
    static let shared = ExamRegistrationAutoFetch()

    private struct Armed {
        let host: String?
        weak var qis: QISConnection?
        weak var hildesheim: HildesheimConnection?
    }

    private var armed: Armed?
    private var observer: NSObjectProtocol?

    init(center: NotificationCenter = .default) {
        // UniWebBrowser meldet auf dem Hauptthread (MainActor)
        observer = center.addObserver(forName: UniWebBrowser.didClose, object: nil, queue: nil) { [weak self] n in
            let url = n.userInfo?["url"] as? URL
            MainActor.assumeIsolated { self?.browserClosed(url) }
        }
    }

    /// Beim Tippen auf den Knopf (Demo: nichts vormerken)
    func arm(_ url: URL, qis: QISConnection?, hildesheim: HildesheimConnection?, demo: Bool) {
        armed = demo || (qis == nil && hildesheim == nil) ? nil : Armed(host: url.host?.lowercased(), qis: qis, hildesheim: hildesheim)
    }

    func disarm() { armed = nil }

    /// Blatt geschlossen: gehoert es zum vorgemerkten Rechner, einmal abrufen
    private func browserClosed(_ url: URL?) {
        guard let a = armed, let host = url?.host?.lowercased(), host == a.host else { return }
        armed = nil
        if let qis = a.qis {
            guard qis.isConnected, qis.state != .needsLogin else { return }
            Task { await qis.fetchRegistrations() }
        } else if let lsf = a.hildesheim {
            guard lsf.isConnected(.lsf), lsf.lsf != .needsLogin else { return }
            Task { await lsf.fetchRegistrations() }
        }
    }
}

/// "Angemeldete Prüfungen abrufen" (nur lesend) bzw. "QIS verbinden"; Uni Hildesheim: "Meine POS-Anmeldungen" im LSF
struct ExamRegistrationFetchButton: View {
    let reload: () async -> Void
    @Environment(\.qis) private var qis
    @Environment(\.hildesheim) private var hildesheim

    var body: some View {
        if let qis {
            Inner(connection: qis, reload: reload)
        } else if let hildesheim {
            LSFInner(connection: hildesheim, reload: reload)
        }
    }

    /// LSF der Uni Hildesheim: nur mit verbundenem LSF (Verbinden in Dienste/Einstellungen wie beim Notenspiegel)
    private struct LSFInner: View {
        @ObservedObject var connection: HildesheimConnection
        let reload: () async -> Void

        var body: some View {
            if connection.isConnected(.lsf) && connection.lsf != .needsLogin {
                UFButton(connection.registrationsRunning ? "Ruft ab …" : "Angemeldete Prüfungen abrufen", icon: "sync", size: .small) {
                    Task {
                        await connection.fetchRegistrations()
                        await reload()
                    }
                }
                .disabled(connection.registrationsRunning || connection.isRunning)
                .fixedSize()
                .accessibilityHint("Liest „Meine POS-Anmeldungen“ im LSF, nur lesend.")
                .accessibilityIdentifier("examreg.fetch")
            }
        }
    }

    private struct Inner: View {
        @ObservedObject var connection: QISConnection
        let reload: () async -> Void
        @State private var login = false

        var body: some View {
            Group {
                if connection.isConnected && connection.state != .needsLogin {
                    UFButton(connection.registrationsRunning ? "Ruft ab …" : "Angemeldete Prüfungen abrufen", icon: "sync", size: .small) {
                        Task {
                            await connection.fetchRegistrations()
                            await reload()
                        }
                    }
                    .disabled(connection.registrationsRunning || connection.isRunning)
                    .accessibilityIdentifier("examreg.fetch")
                } else {
                    UFButton(connection.isConnected ? "QIS erneut anmelden" : "QIS verbinden", icon: "arrow-right", size: .small) { login = true }
                        .accessibilityIdentifier("examreg.connect")
                }
            }
            .fixedSize()
            .sheet(isPresented: $login) { QISLoginView(connection: connection) }
        }
    }
}

// MARK: - Liste

/// Vorschlaege als Liste mit Haken (angemeldet) bzw. Kreis (offen), Grund, Termin, Ruecktritt
struct ExamRegistrationList: View {
    let items: [ExamRegistrationState.Suggestion]
    var limit: Int?

    var body: some View {
        let shown = limit.map { Array(items.prefix($0)) } ?? items
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, s in
                row(s).ufBorderBottom(i < shown.count - 1)
            }
            if let limit, items.count > limit {
                Text("und \(items.count - limit) weitere im Studienverlauf").ufFont(12.8).foregroundStyle(UF.muted).padding(.top, 6)
            }
        }
        .accessibilityIdentifier("examreg.list")
    }

    private func row(_ s: ExamRegistrationState.Suggestion) -> some View {
        HStack(alignment: .top, spacing: 10) {
            UFIcon(s.registered ? "check" : "circle", size: 16)
                .foregroundStyle(s.registered ? UF.ok : UF.warn)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(s.title).ufFont(14.5, 650).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    UFBadge(ExamRegistrationText.status(s), tone: s.registered ? .ok : .warn).fixedSize()
                }
                Text(s.reason + (s.period == "vbp" ? " · VbP" : "")).ufFont(12.8).foregroundStyle(UF.text2)
                    .fixedSize(horizontal: false, vertical: true)
                if let line = ExamRegistrationText.examLine(s) {
                    Text(line).ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                }
                if s.lastAttempt {
                    Text("Letzter Versuch – sprich mit der Studienberatung.").ufFont(12.8, 600).foregroundStyle(UF.badText)
                }
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ExamRegistrationText.accessibility(s))
        .accessibilityIdentifier("examreg.row.\(s.id)")
    }
}

/// Hinweis unter dem Knopf: der Mensch meldet sich selbst an
struct ExamRegistrationHint: View {
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            UFIcon("info", size: 13)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .ufFont(12.48, lh: 1.4).foregroundStyle(UF.text2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("examreg.hint")
    }
}

/// Warnungen ("Die Anmeldung endet in 2 Tagen …")
struct ExamRegistrationWarnings: View {
    let warnings: [(tone: String, text: String)]
    var body: some View {
        ForEach(Array(warnings.enumerated()), id: \.offset) { _, w in
            HStack(alignment: .top, spacing: 6) {
                UFIcon("alert", size: 14).padding(.top, 2)
                Text(w.text).ufFont(13.6, 650).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(w.tone == "bad" ? UF.badText : UF.warnText)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: UF.rSm).fill(w.tone == "bad" ? UF.badSoft : UF.warnSoft))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("examreg.warning")
        }
    }
}

/// Laedt die Antwort und laedt neu nach jedem QIS-Abruf und bei `ufReload`
private struct ExamRegistrationLoader<Content: View>: View {
    let api: APIClient?
    var token: String = ""
    @ViewBuilder let content: (ExamRegistrationState?, @escaping () async -> Void) -> Content
    @Environment(\.qis) private var qis
    @Environment(\.hildesheim) private var hildesheim
    @State private var state: ExamRegistrationState?

    var body: some View {
        // immer eine echte Ansicht (Laden haengt sonst an einer leeren Ansicht und startet nie)
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 0).accessibilityHidden(true)
            content(state, load)
        }
            .task(id: token) { await load() }
            .ufReload { await load() }
            .onReceive(qisRuns) { _ in Task { await load() } }
    }

    private var qisRuns: AnyPublisher<Int, Never> {
        // QIS (LUH) bzw. Abgleich und Abruf im LSF (Uni Hildesheim)
        qis.map { $0.$finishedRuns.dropFirst().eraseToAnyPublisher() }
            ?? hildesheim.map { $0.$finishedRuns.dropFirst().eraseToAnyPublisher() } ?? Empty().eraseToAnyPublisher()
    }

    private func load() async {
        let s = await ExamRegistrationState.load(api)
        if s != state { state = s }
        if !StudIPSync.isUnderTest() { await ExamRegistrationReminderScheduler.shared.refresh() }
    }
}

// MARK: - Uebersicht

/// Karte "Prüfungsanmeldung" der Uebersicht: nur im Meldezeitraum und in den 7 Tagen davor (`show_card`)
struct ExamRegistrationCard: View {
    let api: APIClient?
    var token: String = ""
    @EnvironmentObject private var router: UFRouter

    var body: some View {
        ExamRegistrationLoader(api: api, token: token) { state, reload in
            if let st = state, st.showCard { Self.card(st, reload: reload, open: { router.go(.studyPlan()) }).padding(.bottom, 19.2) }
        }
    }

    @ViewBuilder static func card(_ st: ExamRegistrationState, reload: @escaping () async -> Void, open: @escaping () -> Void) -> some View {
        let missing = st.suggestions.filter { !$0.registered }
        UFCard {
            UFCardHead("Prüfungsanmeldung", icon: "exam", wrap: true) {
                ExamRegistrationQISButton(url: st.qisURL, system: st.system, size: .small, targets: st.guideTargets())
            }
            VStack(alignment: .leading, spacing: 10) {
                if let w = st.window {
                    Text(ExamRegistrationText.windowLine(w, system: st.system)).ufFont(13.6, 650).foregroundStyle(w.isOpen ? UF.accentText : UF.text2)
                        .accessibilityIdentifier("examreg.window")
                }
                ExamRegistrationWarnings(warnings: st.warnings)
                if st.suggestions.isEmpty {
                    Text(st.planMessage ?? "Für dieses Semester schlägt dein Studienverlauf keine Prüfung vor.")
                        .ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(missing.isEmpty ? "Alle vorgeschlagenen Prüfungen sind angemeldet." : "Diese Prüfungen solltest du anmelden:")
                        .ufFont(13.12, 600).foregroundStyle(UF.text)
                    ExamRegistrationList(items: st.suggestions, limit: 5)
                }
                ExamRegistrationHint(text: st.hint)
                UFFlexWrap(gap: 8) {
                    ExamRegistrationFetchButton(reload: reload)
                    UFButton("Im Studienverlauf", icon: "columns", kind: .ghost, size: .small, action: open).fixedSize()
                        .accessibilityIdentifier("examreg.open")
                }
            }
        }
        .accessibilityIdentifier("examreg.card")
    }
}

// MARK: - Studienverlauf

/// Abschnitt "Prüfungsanmeldung" im Studienverlauf: Zeitraeume (oder Link), alle Vorschlaege, gelesene Anmeldungen,
/// Erinnerungen, Regeln, Quelle
struct ExamRegistrationSection: View {
    let api: APIClient?

    var body: some View {
        ExamRegistrationLoader(api: api) { state, reload in
            if let st = state { Self.section(st, reload: reload) }
        }
    }

    @ViewBuilder static func section(_ st: ExamRegistrationState, reload: @escaping () async -> Void) -> some View {
        UFCard {
            UFCardHead("Prüfungsanmeldung" + (st.term.map { " · \($0)" } ?? ""), icon: "exam", wrap: true) {
                ExamRegistrationQISButton(url: st.qisURL, system: st.system, size: .small, targets: st.guideTargets())
            }
            VStack(alignment: .leading, spacing: 12) {
                periodsBlock(st)
                ExamRegistrationWarnings(warnings: st.warnings)
                if let m = st.planMessage { Text(m).ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true) }
                if st.suggestions.isEmpty {
                    Text("Für dieses Semester schlägt dein Studienverlauf keine Prüfung vor.").ufFont(13.12).foregroundStyle(UF.muted)
                } else {
                    Text("Diese Prüfungen solltest du anmelden").ufFont(13.6, 650).foregroundStyle(UF.text)
                    ExamRegistrationList(items: st.suggestions)
                }
                registeredBlock(st)
                ExamRegistrationHint(text: st.hint)
                UFFlexWrap(gap: 8) { ExamRegistrationFetchButton(reload: reload) }
                ExamRegistrationReminderToggle()
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(st.rules, id: \.self) { r in Text("• " + r).ufFont(11.84).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true) }
                    Text(st.disclaimer).ufFont(11.84).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("examreg.rules")
            }
        }
        .accessibilityIdentifier("examreg.section")
    }

    @ViewBuilder private static func periodsBlock(_ st: ExamRegistrationState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let w = st.window {
                Text(ExamRegistrationText.windowLine(w, system: st.system)).ufFont(13.6, 650).foregroundStyle(w.isOpen ? UF.accentText : UF.text)
                    .accessibilityIdentifier("examreg.window")
            }
            if let w = st.vbpWindow, w.phase != "later" {
                Text(ExamRegistrationText.windowLine(w, system: st.system)).ufFont(12.8, 600).foregroundStyle(UF.text2)
            }
            if !st.periods.isEmpty {
                ForEach(st.periods.filter { $0.kind.hasSuffix("meldung") || $0.kind.hasSuffix("pruefung") }) { p in
                    HStack(spacing: 8) {
                        Text(p.label).ufFont(12.48).foregroundStyle(UF.text2).frame(maxWidth: .infinity, alignment: .leading)
                        Text(ExamRegistrationText.periodRange(p)).ufFont(12.48, 600).monospacedDigit().foregroundStyle(UF.text)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if let note = st.periodNote {
                // Uni Hildesheim: keine einheitliche Frist, Hinweis statt "nicht sicher"
                Text(note).ufFont(12.8).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("examreg.periodnote")
            }
            if !st.verified || (st.window == nil && st.periodNote == nil) {
                Text("Die Zeiträume für \(st.programName ?? "deinen Studiengang") kennt StudiNow nicht sicher. Sieh auf der Terminseite des Prüfungsamts nach.")
                    .ufFont(12.8).foregroundStyle(UF.warnText).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("examreg.unverified")
            }
            if let u = st.sourceURL {
                Link(destination: u) {
                    Text((st.system == "LSF" ? "Quelle: Seite des Prüfungsamts" : "Quelle: Terminseite des Prüfungsamts")
                         + (st.checkedAt.map { " (gelesen am \(UFFmt.date($0)))" } ?? ""))
                        .ufFont(11.84, 600).foregroundStyle(UF.accentText)
                }
                .accessibilityIdentifier("examreg.source")
            }
        }
    }

    @ViewBuilder private static func registeredBlock(_ st: ExamRegistrationState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ExamRegistrationText.checked(st)).ufFont(12.48).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("examreg.checked")
            let regs = st.registered.filter(\.registered)
            if !regs.isEmpty {
                Text("Im \(st.system) angemeldet").ufFont(12.8, 650).foregroundStyle(UF.text)
                ForEach(regs) { r in
                    HStack(spacing: 6) {
                        UFIcon("check", size: 13).foregroundStyle(UF.ok)
                        Text(r.text).ufFont(12.8).foregroundStyle(UF.text)
                        Spacer(minLength: 4)
                        Text([r.date.map { UFFmt.date($0) } ?? r.dateText, r.time.map { "\($0) Uhr" }].compactMap { $0 }.joined(separator: " "))
                            .ufFont(12.48).foregroundStyle(UF.muted)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

// MARK: - Modul

/// Block "Prüfung anmelden" fuer ein Modul (Moduldetails im Studienverlauf: Katalog-id; Modulseite: Modul der App).
/// Ohne Vorschlag fuer dieses Modul nichts.
struct ExamRegistrationModuleBlock: View {
    let api: APIClient?
    var catalogID: String?
    var appModuleID: Int?

    var body: some View {
        ExamRegistrationLoader(api: api, token: (catalogID ?? "") + "|" + String(appModuleID ?? 0)) { state, reload in
            if let st = state, let s = catalogID.flatMap(st.suggestion(catalogID:)) ?? appModuleID.flatMap(st.suggestion(appModuleID:)) {
                Self.block(st, s, reload: reload)
            }
        }
    }

    @ViewBuilder static func block(_ st: ExamRegistrationState, _ s: ExamRegistrationState.Suggestion,
                                   reload: @escaping () async -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                UFIcon("exam", size: 15)
                Text("Prüfung anmelden").ufFont(14.4, 700)
                Spacer(minLength: 4)
                UFBadge(ExamRegistrationText.status(s), tone: s.registered ? .ok : .warn).fixedSize()
            }
            .foregroundStyle(UF.text)
            Text(([s.reason] + [ExamRegistrationText.examLine(s), ExamRegistrationText.via(s, system: st.system)].compactMap { $0 }).joined(separator: " · "))
                .ufFont(12.8).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
            if let w = s.period == "vbp" ? st.vbpWindow : st.window {
                Text(ExamRegistrationText.windowLine(w, system: st.system)).ufFont(12.8, 600).foregroundStyle(UF.accentText)
            }
            if !s.registered {
                ExamRegistrationQISButton(url: st.qisURL, system: st.system, size: .small, targets: st.guideTargets(first: s))
                ExamRegistrationHint(text: st.hint)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: UF.rSm).fill(s.registered ? UF.okSoft : UF.warnSoft))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("examreg.module")
    }
}

// MARK: - Naechste Klausuren

/// Zeile unter "Nächste Klausuren": Meldezeitraum (offen oder bald) mit Knopf
struct ExamRegistrationExamsFooter: View {
    let state: ExamRegistrationState
    var body: some View {
        if let w = state.window, w.phase != "later" {
            UFFlexWrap(gap: 8) {
                Text("Prüfungsanmeldung: " + ExamRegistrationText.windowLine(w, system: state.system)).ufFont(12.8, 600).foregroundStyle(UF.text2)
                    .fixedSize(horizontal: false, vertical: true)
                ExamRegistrationQISButton(url: state.qisURL, system: state.system, size: .small, targets: state.guideTargets())
            }
            .padding(.top, 6)
            .accessibilityIdentifier("exams.registration")
        }
    }
}

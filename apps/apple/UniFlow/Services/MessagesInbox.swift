import Combine
import SwiftUI
import UniFlowCore

/// Stand der Stud.IP-Nachrichten fuer den Menuepunkt "Nachrichten" (04.11.2026): wie viele gespeichert sind (ob der
/// Eintrag erscheint) und wie viele neu sind (Abzeichen).
///
/// Sichtbar (`showsNavItem`): nur mit lokalem Backend (iPad ohne eigenen Server; der PC-Server gleicht den
/// Posteingang nicht ab) und nur, wenn die Hochschule Stud.IP hat und es verbunden ist (Sitzung gespeichert, auch
/// abgelaufen) oder schon Nachrichten auf dem Geraet liegen. Uni Hildesheim und Hochschule Hannover: sobald der
/// Abgleich Learnweb- bzw. Moodle-Nachrichten gespeichert hat (seit 05.11.2026).
///
/// Ungelesen (seit 26.11.2026 je Nachricht, Entscheidung des Inhabers „nur in StudiNow“, `isUnread`): eigene Wahl zuerst
/// (Nachricht geoeffnet = gelesen, "Als ungelesen markieren", "Alle als gelesen"; `stateKey`), sonst gilt alles bis zur
/// Marke beim Umstieg als gelesen (`baselineKey` = die fruehere Marke "beim letzten Oeffnen der Seite", `seenKey`), sonst
/// der Stand in Stud.IP (`read`; unbekannt bei Moodle/Learnweb = ungelesen). Nach Stud.IP schreibt StudiNow nichts.
/// Das Oeffnen der Seite allein setzt nichts mehr auf gelesen. Alles je Container (Konto und Hochschule) getrennt.
/// Daten: GET /api/studip/messages (nur lokal, `StudIPExtras.messageList`); keine Anfrage an Stud.IP.
@MainActor
final class MessagesInbox: ObservableObject {
    static let shared = MessagesInbox()
    static let navKey = "messages"
    /// `sent_at` der neuesten Nachricht beim letzten Oeffnen der Seite (Einstellungen des Containers); bis 26.11.2026
    /// die Regel fuer "neu", seitdem nur noch der Ausgangspunkt fuer `baselineKey`
    static let seenKey = "uniflow.messages.seenUpTo"
    /// eigene Wahl je Nachricht: [Kennung: true = gelesen, false = ungelesen]
    static let stateKey = "uniflow.messages.readState"
    /// bis zu diesem `sent_at` gilt alles als gelesen (Stand beim Umstieg auf "gelesen je Nachricht"; "" = keine Marke)
    static let baselineKey = "uniflow.messages.readBaseline"

    /// gespeicherte Nachrichten insgesamt (0 ohne lokales Backend)
    @Published private(set) var stored = 0
    /// ungelesene Nachrichten (Abzeichen, Widget)
    @Published private(set) var newCount = 0
    /// zaehlt hoch, wenn sich "gelesen" einer Nachricht aendert (die Seite zeichnet die Punkte neu)
    @Published private(set) var revision = 0
    /// `sent_at` der neuesten gespeicherten Nachricht
    private(set) var latest: String?
    /// zuletzt gelesene Liste (fuer das Neuzaehlen nach "gelesen")
    private var all: [JSONValue] = []

    private(set) weak var router: UFRouter?
    /// Tests: Einstellungen statt des aktiven Containers
    var defaultsOverride: UserDefaults?
    private var defaults: UserDefaults? { defaultsOverride ?? ActiveContainer.current?.defaults }

    // MARK: Regeln (rein, MessagesAppTests)

    /// Menuepunkt zeigen? Nur lokal; dort mit verbundenem Stud.IP oder gespeicherten Nachrichten
    static func showsNavItem(local: Bool, studipConnected: Bool, stored: Int) -> Bool {
        local && (studipConnected || stored > 0)
    }

    /// Stud.IP gilt als verbunden, sobald eine Sitzung gespeichert ist (auch abgelaufen: die Nachrichten bleiben lesbar)
    static func studipConnected(_ studip: StudIPSync) -> Bool { studip.offersStudIP && studip.phase != .signedOut }

    func showsNavItem(api: APIClient?, studip: StudIPSync) -> Bool {
        Self.showsNavItem(local: api?.isLocal ?? true, studipConnected: Self.studipConnected(studip), stored: stored)
    }

    /// Ist eine Nachricht neuer als die Marke? Ohne Marke ja. Verglichen wird der Zeitpunkt (Stud.IP nennt den Versatz
    /// zur Weltzeit, der im Herbst wechselt), ohne lesbaren Zeitpunkt der Text.
    static func isNew(_ sentAt: String?, since mark: String?) -> Bool {
        guard let mark, !mark.isEmpty else { return true }
        guard let sentAt, !sentAt.isEmpty else { return false }
        if let a = StudIPExtras.messageInstant(sentAt), let b = StudIPExtras.messageInstant(mark) { return a > b }
        return sentAt > mark
    }

    /// Gelesen-Stand eines Containers
    struct ReadState: Equatable {
        /// eigene Wahl je Nachricht (true = gelesen)
        var overrides: [String: Bool] = [:]
        /// bis hierher gilt alles als gelesen
        var baseline: String?
    }

    /// Ungelesen? Eigene Wahl, sonst bis zur Marke gelesen, sonst wie in Stud.IP (unbekannt = ungelesen)
    static func isUnread(_ m: JSONValue, state: ReadState) -> Bool {
        if let id = m.s("id"), let mine = state.overrides[id] { return !mine }
        if let b = state.baseline, !b.isEmpty, !isNew(m.s("sent_at"), since: b) { return false }
        return m["read"]?.bool != true
    }

    static func unreadCount(_ messages: [JSONValue], state: ReadState) -> Int {
        messages.filter { isUnread($0, state: state) }.count
    }

    /// Stand aus den Einstellungen des Containers; beim ersten Mal wird die fruehere Marke zur festen Ausgangsmarke
    static func readState(_ d: UserDefaults?) -> ReadState {
        guard let d else { return ReadState() }
        if d.object(forKey: baselineKey) == nil { d.set(d.string(forKey: seenKey) ?? "", forKey: baselineKey) }
        let raw = d.dictionary(forKey: stateKey) as? [String: Bool] ?? [:]
        let b = d.string(forKey: baselineKey)
        return ReadState(overrides: raw, baseline: b?.isEmpty == false ? b : nil)
    }

    /// Eigene Wahl speichern; Kennungen, die es nicht mehr gibt, fallen weg (die Liste bleibt klein)
    static func save(_ overrides: [String: Bool], keeping ids: Set<String>?, to d: UserDefaults?) {
        let kept = ids.map { ids in overrides.filter { ids.contains($0.key) } } ?? overrides
        d?.set(kept, forKey: stateKey)
    }

    /// Neueste `sent_at` einer Liste (nach Zeitpunkt)
    static func newest(_ messages: [JSONValue]) -> String? {
        messages.compactMap { $0.s("sent_at") }.filter { !$0.isEmpty }.max { isNew($1, since: $0) }
    }

    // MARK: Zustand

    /// Marke des aktiven Containers
    var seenMark: String? { defaults?.string(forKey: Self.seenKey) }

    /// Router verbinden (MainView, je Container neu) und den Stand lesen
    func attach(_ router: UFRouter, api: APIClient?) {
        self.router = router
        Task { await refresh(api: api) }
    }

    /// Stand aus dem lokalen Backend lesen; am eigenen Server (kein Posteingang) und bei Fehlern nichts
    func refresh(api: APIClient?) async {
        guard let api, api.isLocal, let r = try? await api.value("/api/studip/messages") else {
            apply(stored: 0, latest: nil, new: 0)
            return
        }
        let list = r.list("messages")
        all = list
        var state = readState
        // ungefilterte Liste: eigene Wahl zu geloeschten Nachrichten aufraeumen
        if r.s("q").map({ $0.isEmpty }) ?? true {
            let ids = Set(list.compactMap { $0.s("id") })
            if state.overrides.keys.contains(where: { !ids.contains($0) }) {
                Self.save(state.overrides, keeping: ids, to: defaults)
                state = readState
            }
        }
        apply(stored: r.i("total") ?? list.count, latest: Self.newest(list), new: Self.unreadCount(list, state: state))
    }

    /// Gelesen-Stand des offenen Containers
    var readState: ReadState { Self.readState(defaults) }

    func isUnread(_ m: JSONValue) -> Bool { Self.isUnread(m, state: readState) }

    /// Nachricht geoeffnet bzw. "Als (un)gelesen markieren": nur in StudiNow
    func mark(_ ids: [String], read: Bool) {
        guard !ids.isEmpty else { return }
        var o = readState.overrides
        for id in ids { o[id] = read }
        Self.save(o, keeping: nil, to: defaults)
        revision += 1
        publish(Self.unreadCount(all, state: readState))
    }

    /// Seite geoeffnet: merkt nur noch die neueste Nachricht (Ausgangspunkt fuer Container ohne Marke); setzt seit
    /// 26.11.2026 nichts mehr auf gelesen. Liefert die Marke davor.
    @discardableResult
    func markSeen() -> String? {
        let before = seenMark
        _ = readState                                                    // Ausgangsmarke festhalten, bevor sie wandert
        if let latest, Self.isNew(latest, since: before) { defaults?.set(latest, forKey: Self.seenKey) }
        return before
    }

    private func apply(stored: Int, latest: String?, new: Int) {
        self.stored = stored
        self.latest = latest
        publish(new)
    }

    private func publish(_ n: Int) {
        if newCount != n { newCount = n }
        router?.setBadge(n, for: Self.navKey)
    }
}

/// Haengt den Stand der Nachrichten an den Rahmen (MainView): lesen beim Erscheinen, bei anderer Datenquelle, im
/// Vordergrund und nach jedem Stud.IP-Abgleich (der die Nachrichten neu holt)
struct MessagesInboxHost: ViewModifier {
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var studip: StudIPSync
    @Environment(\.hsh) private var hsh
    @Environment(\.hildesheim) private var hildesheim
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear { MessagesInbox.shared.attach(router, api: session.api) }
            .onChange(of: session.api?.base) { _, _ in MessagesInbox.shared.attach(router, api: session.api) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await MessagesInbox.shared.refresh(api: session.api) } }
            }
            .onChange(of: studip.finishedRuns) { _, _ in Task { await MessagesInbox.shared.refresh(api: session.api) } }
            // Moodle-Nachrichten der Hochschule Hannover kommen mit deren Abgleich
            .onReceive(hsh.map { $0.$finishedRuns.dropFirst().eraseToAnyPublisher() } ?? Empty().eraseToAnyPublisher()) { _ in
                Task { await MessagesInbox.shared.refresh(api: session.api) }
            }
            // Learnweb-Nachrichten der Uni Hildesheim kommen mit deren Abgleich (LearnwebMessages, 05.11.2026)
            .onReceive(hildesheim.map { $0.$finishedRuns.dropFirst().eraseToAnyPublisher() } ?? Empty().eraseToAnyPublisher()) { _ in
                Task { await MessagesInbox.shared.refresh(api: session.api) }
            }
    }
}

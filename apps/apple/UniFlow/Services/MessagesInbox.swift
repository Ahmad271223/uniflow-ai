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
/// Neu (`isNew`): gesendet nach der neuesten Nachricht, die beim letzten Oeffnen der Seite da war. Die Marke steht in
/// den Einstellungen des Containers (`seenKey`, je Konto und Hochschule getrennt) als `sent_at` dieser Nachricht; so
/// zaehlt auch eine Nachricht, die erst nach dem Oeffnen abgeglichen wurde, aber neuer ist. Nie geoeffnet: alle neu.
/// Daten: GET /api/studip/messages (nur lokal, `StudIPExtras.messageList`); keine Anfrage an Stud.IP.
@MainActor
final class MessagesInbox: ObservableObject {
    static let shared = MessagesInbox()
    static let navKey = "messages"
    /// `sent_at` der neuesten Nachricht beim letzten Oeffnen der Seite (Einstellungen des Containers)
    static let seenKey = "uniflow.messages.seenUpTo"

    /// gespeicherte Nachrichten insgesamt (0 ohne lokales Backend)
    @Published private(set) var stored = 0
    /// Nachrichten neuer als die Marke
    @Published private(set) var newCount = 0
    /// `sent_at` der neuesten gespeicherten Nachricht
    private(set) var latest: String?

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

    static func newCount(_ messages: [JSONValue], since mark: String?) -> Int {
        messages.filter { isNew($0.s("sent_at"), since: mark) }.count
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
        let all = r.list("messages")
        apply(stored: r.i("total") ?? all.count, latest: Self.newest(all), new: Self.newCount(all, since: seenMark))
    }

    /// Seite geoeffnet: alle gespeicherten gelten als gesehen. Liefert die Marke davor (fuer die Punkte "neu seit dem
    /// letzten Besuch" auf der Seite).
    @discardableResult
    func markSeen() -> String? {
        let before = seenMark
        if let latest, Self.isNew(latest, since: before) { defaults?.set(latest, forKey: Self.seenKey) }
        publish(0)
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

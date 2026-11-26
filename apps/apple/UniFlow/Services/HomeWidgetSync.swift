import Combine
import Foundation
import UniFlowCore
import SwiftUI
import WidgetKit

/// Schnappschuss fuer die Widgets (WidgetShared/HomeWidgetData.swift) aus der lokalen Datenquelle schreiben: naechste
/// 14 Tage Stundenplan (wie die Wochenansicht, ohne Ausfaelle laut Stud.IP und ohne "nicht besucht") und der Speiseplan
/// von heute und morgen der gewaehlten Mensa mit den Filtern und der Preisgruppe der Mensa-Seite (`MensaPrefs`).
/// Wann: nach jedem Abgleich (`StudIPSync.finishedRuns`), nach dem Hintergrundlauf und beim Wechsel in den Hintergrund.
/// Ohne Container (abgemeldet, Hochschule gewechselt) wird der Schnappschuss geloescht. Demo-Inhalte erscheinen wie
/// echte (erfundene Daten, kein Konto; so sieht auch die App-Pruefung die Widgets); beim Verlassen der Demo neu geschrieben.
@MainActor
enum HomeWidgetSync {
    /// so viele Tage Stundenplan ab heute
    static let days = 14
    /// so viele Gerichte je Tag (das grosse Widget zeigt hoechstens fuenf)
    static let mealsPerDay = 6

    private static var running = false
    private static var again = false
    /// Uni-Mail des offenen Containers (setzt `HomeWidgetRefresher`), fuer die Zahl im Widget "Nachrichten"
    static weak var mail: UniMailConnection?

    /// Schnappschuss neu schreiben bzw. loeschen; laeuft schon einer, folgt genau ein weiterer danach
    static func refresh(api: APIClient?, now: Date = Date()) async {
        guard !StudIPSync.isUnderTest() else { return }
        if running { again = true; return }
        running = true
        defer { running = false }
        repeat {
            again = false
            await refreshOnce(api: api, now: now)
        } while again
    }

    private static func refreshOnce(api: APIClient?, now: Date) async {
        guard let api else {
            if HomeWidgetStore.clear() { WidgetCenter.shared.reloadAllTimelines() }
            return
        }
        guard let data = await build(api: api, now: now) else { return }   // Fehler: alten Stand behalten
        if HomeWidgetStore.save(data) { WidgetCenter.shared.reloadAllTimelines() }
    }

    /// Schnappschuss aus der Datenquelle; nil, wenn der Stundenplan nicht lesbar war
    static func build(api: APIClient, now: Date, prefs: MensaPrefs = .load()) async -> HomeWidgetData? {
        let today = HomeWidgetClock.isoDay(now)
        let lastDay = Mensa.addDays(today, days - 1)
        var week: [JSONValue] = []
        var start = today
        while start <= lastDay {
            guard let w = try? await api.value("/api/timetable/week?start=\(start)") else { return nil }
            week.append(w)
            start = Mensa.addDays(start, 7)
        }
        let cancelled = await StudIPCancelled.keys(api, from: today, to: lastDay)
        let events = Self.events(weeks: week, cancelled: cancelled, from: today, to: lastDay)
        let until = HomeWidgetClock.date(day: Mensa.addDays(lastDay, 1), time: "00:00") ?? now.addingTimeInterval(Double(days) * 86_400)
        let mensa = await Self.mensa(api: api, today: today, prefs: prefs)
        let messages = await Self.messages(api: api)
        return HomeWidgetData(createdAt: now, events: events, eventsUntil: until, mensa: mensa, messages: messages)
    }

    // MARK: Nachrichten (26.11.2026)

    /// Widget "Nachrichten": nur mit lokalem Backend (der eigene Server gleicht den Posteingang nicht ab)
    static func messages(api: APIClient, prefs: MessagesWidgetPrefs = .load()) async -> HomeWidgetData.Messages? {
        guard api.isLocal else { return nil }
        let list = try? await api.value("/api/studip/messages")
        let mailOn = prefs.mail && (mail?.isConnected ?? false)
        let cached = mailOn ? await mail?.cachedInbox() : nil
        return messages(list: list, mark: ActiveContainer.current?.defaults.string(forKey: MessagesInbox.seenKey),
                        source: sourceName(ActiveContainer.current?.key.university), prefs: prefs,
                        mailUnread: mailOn ? mail?.unseen : nil, mailListing: cached)
    }

    static func sourceName(_ u: UniversityKey?) -> String {
        switch u {
        case .hildesheim: return "Learnweb"
        case .hsh: return "Moodle"
        default: return "Stud.IP"
        }
    }

    /// so viele Zeichen Textanfang (nur mit dem Schalter)
    static let previewLength = 120

    /// Reine Regel (WidgetSnapshotAppTests): ungelesen = laut Stud.IP nicht gelesen (unbekannt zaehlt mit) und neuer als
    /// das letzte Oeffnen der Seite "Nachrichten" in StudiNow (`MessagesInbox.isNew`). Zeilen: neueste ungelesene der
    /// Quelle, danach ungelesene E-Mails der ersten Seite des Posteingangs. nil, wenn es weder gespeicherte Nachrichten
    /// noch Uni-Mail gibt.
    static func messages(list: JSONValue?, mark: String?, source: String, prefs: MessagesWidgetPrefs,
                         mailUnread: Int?, mailListing: JSONValue?) -> HomeWidgetData.Messages? {
        let all = list?.list("messages") ?? []
        if all.isEmpty, mailUnread == nil { return nil }
        let unread = all.filter { MessagesInbox.isUnread($0, since: mark) }
        func clean(_ s: String?) -> String { (s ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
        func preview(_ s: String?) -> String? {
            guard prefs.preview else { return nil }
            let t = clean(s).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !t.isEmpty else { return nil }
            return t.count > previewLength ? String(t.prefix(previewLength - 1)) + "…" : t
        }
        var lines: [HomeWidgetData.MessageLine] = unread.prefix(HomeWidgetData.messageLines).map { m in
            .init(sender: clean(m.s("sender")).isEmpty ? source : clean(m.s("sender")),
                  subject: clean(m.s("subject")).isEmpty ? "(ohne Betreff)" : clean(m.s("subject")),
                  preview: preview(m.s("text")), sentAt: StudIPExtras.messageInstant(m.s("sent_at")), isMail: false)
        }
        if mailUnread != nil {
            for m in mailListing?.list("messages") ?? [] where m["read"]?.bool == false {
                guard lines.count < HomeWidgetData.messageLines else { break }
                let sender = clean(m.s("sender"))
                lines.append(.init(sender: sender.isEmpty ? "Uni-Mail" : sender,
                                   subject: clean(m.s("subject")).isEmpty ? "(ohne Betreff)" : clean(m.s("subject")),
                                   preview: nil, sentAt: nil, isMail: true))
            }
        }
        let fetched = list?.s("fetched_at").flatMap { StudIPExtras.messageInstant($0) ?? ISO8601DateFormatter().date(from: $0) }
        return .init(source: source, unread: unread.count, mailUnread: mailUnread.map { max(0, $0) }, lines: lines,
                     lockSubjects: prefs.lockSubjects, fetchedAt: fetched)
    }

    /// Termine aus Antworten von GET /api/timetable/week: nur "teilnahme" (Ausfall, verschoben, nicht besucht fallen
    /// weg), ohne Ausfaelle laut Stud.IP, nach Beginn sortiert, doppelte (gleicher Titel, gleiche Zeit) einmal
    static func events(weeks: [JSONValue], cancelled: Set<String>, from: String, to: String) -> [HomeWidgetData.Event] {
        var out: [HomeWidgetData.Event] = []
        var seen = Set<String>()
        for w in weeks {
            for day in w.list("days") {
                guard let date = day.s("date"), date >= from, date <= to else { continue }
                let visible = StudIPCancellations.visible(day.list("events"), keys: cancelled)
                for e in visible where (e.s("status") ?? "teilnahme") == "teilnahme" {
                    guard let s = e.s("start"), let st = HomeWidgetClock.date(day: date, time: s) else { continue }
                    let en = e.s("end").flatMap { HomeWidgetClock.date(day: date, time: $0) }.flatMap { $0 > st ? $0 : nil }
                        ?? st.addingTimeInterval(90 * 60)
                    let title = (e.s("title") ?? e.s("module_name") ?? "Termin").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard seen.insert("\(title)|\(st.timeIntervalSince1970)").inserted else { continue }
                    let room = e.s("room")?.trimmingCharacters(in: .whitespacesAndNewlines)
                    out.append(.init(title: title.isEmpty ? "Termin" : title, room: room?.isEmpty == false ? room : nil,
                                     start: st, end: en, color: e.s("color"), kind: e.s("kind")))
                }
            }
        }
        return out.sorted { ($0.start, $0.title) < ($1.start, $1.title) }
    }

    /// Speiseplan heute und morgen; nil ohne Mensa (Hochschule ohne Speiseplan) oder bei Fehler
    static func mensa(api: APIClient, today: String, prefs: MensaPrefs) async -> HomeWidgetData.Mensa? {
        guard let list = try? await api.value("/api/mensa/canteens"), !list.list("canteens").isEmpty else { return nil }
        let id = prefs.chosen(in: list)
        guard let menu = try? await api.value("/api/mensa/menu?canteen=\(id)&date=\(today)&days=2") else { return nil }
        let name = list.list("canteens").first { $0.s("id") == id }?.s("name") ?? menu["canteen"]?.s("name") ?? "Mensa"
        return mensa(menu: menu, name: name, prefs: prefs)
    }

    static func mensa(menu: JSONValue, name: String, prefs: MensaPrefs) -> HomeWidgetData.Mensa {
        let days = menu.list("days").compactMap { d -> HomeWidgetData.Day? in
            guard let date = d.s("date") else { return nil }
            let meals = Mensa.sort(Mensa.filter(d.list("meals"), prefs.filter), by: prefs.sort, role: prefs.role)
                .prefix(mealsPerDay)
                .compactMap { m -> HomeWidgetData.Meal? in
                    guard let n = m.s("name")?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty else { return nil }
                    let labels = Mensa.labels(m)
                    return .init(name: n, category: m.s("category"), price: Mensa.price(m, role: prefs.role).map { MensaUI.price($0) },
                                 vegan: labels.contains("vegan"), vegetarian: labels.contains("vegetarisch") || labels.contains("vegan"))
                }
            return .init(date: date, status: d.s("status") ?? "unknown", meals: Array(meals))
        }
        return .init(canteen: name, days: days)
    }
}

/// Unsichtbar unter jedem Fenster: schreibt den Widget-Schnappschuss nach jedem Stud.IP-Abgleich (`finishedRuns`),
/// beim Wechsel des Containers (Abmelden, andere Hochschule: `generation`) und beim Ein-/Ausschalten der Demo neu.
/// Mehrere Fenster loesen hoechstens einen weiteren Lauf aus (`HomeWidgetSync.refresh`).
struct HomeWidgetRefresher: View {
    @ObservedObject var containers: ContainerManager
    @ObservedObject var studip: StudIPSync

    private struct Trigger: Equatable {
        let runs: Int
        let generation: Int
        let demo: Bool
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: Trigger(runs: studip.finishedRuns, generation: containers.generation, demo: containers.demoActive), initial: true) { _, _ in
                HomeWidgetSync.mail = containers.uniMail
                Task { await HomeWidgetSync.refresh(api: containers.active?.api) }
            }
            // Widget "Nachrichten": Seite geoeffnet (gesehen), Learnweb/Moodle abgeglichen, Uni-Mail gelesen
            .onReceive(MessagesInbox.shared.$newCount.removeDuplicates().dropFirst()) { _ in
                Task { await HomeWidgetSync.refresh(api: containers.active?.api) }
            }
            .onReceive(containers.uniMail.map { $0.$unseen.removeDuplicates().dropFirst().eraseToAnyPublisher() } ?? Empty().eraseToAnyPublisher()) { _ in
                HomeWidgetSync.mail = containers.uniMail
                Task { await HomeWidgetSync.refresh(api: containers.active?.api) }
            }
    }
}

/// Was das Widget "Nachrichten" zeigen darf (Geraet, `UserDefaults.standard`; Karte in den Einstellungen)
struct MessagesWidgetPrefs: Equatable {
    /// Betreffe auch auf dem Sperrbildschirm (Vorgabe aus: dort nur Zahl und Absender)
    var lockSubjects = false
    /// Anfang des Nachrichtentexts im Widget (Vorgabe aus)
    var preview = false
    /// Uni-Mail mitzaehlen, wenn verbunden (Vorgabe an)
    var mail = true

    enum Keys {
        static let lockSubjects = "uniflow.widget.messages.lockSubjects"
        static let preview = "uniflow.widget.messages.preview"
        static let mail = "uniflow.widget.messages.mail"
    }

    static func load(_ d: UserDefaults = .standard) -> MessagesWidgetPrefs {
        var p = MessagesWidgetPrefs()
        p.lockSubjects = d.bool(forKey: Keys.lockSubjects)
        p.preview = d.bool(forKey: Keys.preview)
        if d.object(forKey: Keys.mail) != nil { p.mail = d.bool(forKey: Keys.mail) }
        return p
    }

    func save(_ d: UserDefaults = .standard) {
        d.set(lockSubjects, forKey: Keys.lockSubjects)
        d.set(preview, forKey: Keys.preview)
        d.set(mail, forKey: Keys.mail)
    }

    static let intro = "Das Widget zeigt, wie viele Nachrichten ungelesen sind, und auf dem Home-Bildschirm Absender und Betreff der neuesten. Auf dem Sperrbildschirm stehen ohne den Schalter nur die Zahl und der Absender, nie ein Nachrichtentext. Alles bleibt auf diesem Gerät."
}

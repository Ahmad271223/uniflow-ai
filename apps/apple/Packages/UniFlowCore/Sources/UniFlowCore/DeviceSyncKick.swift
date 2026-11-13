import Foundation

/// Abgleich mit dem Konto bald nach einer Aenderung in der App (13.11.2026, Plan "Ein Konto, alle Geraete" Schritt 1,
/// docs/ALLE-GERAETE-PLAN-2026-11-13.md). Vorher glichen iPad und iPhone nur beim Oeffnen der App ab; eine Notiz ging
/// erst beim naechsten Oeffnen los. Wie `sync_client.kick` der Windows-App: Aenderungen werden gebuendelt.
///
/// `kick()` nach jeder Aenderung; `run` laeuft, sobald `quiet` lang keine weitere kam, spaetestens `maxWait` nach der
/// ersten noch nicht gesendeten (wer laenger am Stueck schreibt, gleicht trotzdem regelmaessig ab). Nie zwei Laeufe
/// zugleich; Aenderungen waehrend eines Laufs fuehren zu einem weiteren. `flush()` sendet sofort, was noch aussteht
/// (Wechsel in den Hintergrund), und wartet auf einen laufenden Lauf.
public actor DeviceSyncKicker {
    public typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    private let quiet: TimeInterval
    private let maxWait: TimeInterval
    private let sleep: Sleep
    private let now: @Sendable () -> Date
    private let run: @Sendable () async -> Void

    private var firstPending: Date?
    private var lastKick: Date?
    private var worker: Task<Void, Never>?
    private var running: Task<Void, Never>?

    public init(quiet: TimeInterval = 5, maxWait: TimeInterval = 30,
                sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) },
                now: @escaping @Sendable () -> Date = Date.init,
                run: @escaping @Sendable () async -> Void) {
        self.quiet = quiet
        self.maxWait = maxWait
        self.sleep = sleep
        self.now = now
        self.run = run
    }

    /// Steht eine Aenderung aus, die noch nicht gesendet wurde?
    public var pending: Bool { firstPending != nil }

    public func kick() {
        let t = now()
        lastKick = t
        if firstPending == nil { firstPending = t }
        if worker == nil { worker = Task { await self.wait() } }
    }

    /// Sofort senden, was aussteht; wartet auf einen laufenden Lauf (danach ist alles bis jetzt Geaenderte gesendet)
    public func flush() async {
        worker?.cancel()
        worker = nil
        if let running { await running.value }
        if firstPending != nil { await execute() }
    }

    /// Aussteht nichts mehr (z. B. Abmelden): wartende Aenderungen verwerfen, ohne zu senden
    public func cancel() {
        worker?.cancel()
        worker = nil
        firstPending = nil
        lastKick = nil
    }

    private func wait() async {
        while !Task.isCancelled, let first = firstPending, let last = lastKick {
            let due = min(last.addingTimeInterval(quiet), first.addingTimeInterval(maxWait))
            let left = due.timeIntervalSince(now())
            if left <= 0 { break }
            do { try await sleep(left) } catch { return }
        }
        guard !Task.isCancelled else { return }
        if let running { await running.value }
        guard !Task.isCancelled else { return }
        worker = nil
        if firstPending != nil { await execute() }
    }

    private func execute() async {
        firstPending = nil
        let task = Task { await run() }
        running = task
        await task.value
        running = nil
        // waehrend des Laufs geaendert: noch einmal (gebuendelt)
        if firstPending != nil, worker == nil { worker = Task { await self.wait() } }
    }

    /// Loest diese Anfrage an das lokale Backend einen Abgleich aus? Nur gelungene Aenderungen (POST/PUT/PATCH/DELETE,
    /// Status unter 400) an Daten des Kontos; wie `_NO_KICK` in app/server.py ohne Konto-, Community-, Hochschul-Abgleich-,
    /// Fortschritts- und KI-Pfade.
    public static func isAccountChange(method: String, path: String, status: Int) -> Bool {
        guard ["POST", "PUT", "PATCH", "DELETE"].contains(method.uppercased()), status < 400, path.hasPrefix("/api/") else { return false }
        return !noKick.contains { path.hasPrefix($0) }
    }

    static let noKick = ["/api/studora/", "/api/account/", "/api/community/", "/api/sync", "/api/desktop/", "/api/progress", "/api/ai"]
}

import Foundation
import UniFlowCore

// Gesamt-Abgleich beim Oeffnen (Entscheidung des Inhabers 07.11.2026, docs/UNI-MAIL-2026-11-05.md): kein Takt alle
// 20 Minuten, sondern einmal Uni-Mail UND alle anderen Daten abgleichen, wenn
// - die App geoeffnet wird (erster Wechsel nach "aktiv" in diesem Prozess),
// - nach der Anmeldung bzw. der Wahl der Hochschule ein Container neu geoeffnet wird (neuer Container: noch kein Lauf),
// - die App aus dem Hintergrund zurueckkommt und der letzte solche Abgleich mehr als 15 Minuten her ist.
// Sonst gelten die bisherigen Regeln (`runIfDue` je Quelle, mit ihren eigenen Abstaenden). Reihenfolge: zuerst der
// Posteingang (docs/SYNC-REIHENFOLGE-2026-11-05.md), dann Stud.IP bzw. Learnweb/LSF, HISinOne/Moodle und Noten (QIS
// weiter hoechstens alle 20 Stunden). Nur lesend; ein laufender Abgleich wird nie doppelt gestartet, eine bekannte
// abgelaufene Anmeldung wird wie bisher still erneuert oder bleibt "Anmeldung nötig".
// Uni-Zugang einmal speichern (Entscheidung des Inhabers 10.11.2026): an der LUH gleichen der Knopf "Sync" und das
// Oeffnen ALLE Portale ab - Uni-Mail (SOGo) zuerst, dann Stud.IP und QIS (Noten, Pruefungen, angemeldete Pruefungen;
// Bescheinigungen nur die Liste, erzeugt nichts). Ist ein Uni-Zugang gespeichert, verbindet die App vorher die Portale
// (`connectWithStoredLogin`, beim Knopf als Handlung des Menschen). Ein Portal ohne Verbindung wird uebersprungen und im
// Ergebnis genannt ("QIS: Anmeldung nötig"); ein Fehler eines Portals haelt die anderen nicht auf.

/// Wann der Gesamt-Abgleich beim Oeffnen faellig ist
enum OpenSyncPolicy {
    /// zurueck aus dem Hintergrund: erst nach mehr als 15 Minuten wieder alles
    static let staleAfter: TimeInterval = 15 * 60

    /// Faellig ohne bisherigen Lauf in diesem Prozess, nach mehr als `staleAfter` oder bei verstellter Uhr
    static func due(last: Date?, now: Date, staleAfter: TimeInterval = staleAfter) -> Bool {
        guard let last else { return true }
        let age = now.timeIntervalSince(last)
        return age < 0 || age > staleAfter
    }
}

/// Stand des Gesamt-Abgleichs je Container, nur im Arbeitsspeicher (ein neuer Start der App gleicht immer ab)
@MainActor
enum OpenSync {
    /// automatisch erlaubt (nie unter XCTest, -UFNoStudIPSync oder Startargumenten fuer Bildvergleiche; Tests setzen ihn)
    static var allowed: () -> Bool = { StudIPSync.automaticRunAllowed() }
    /// letzter Gesamt-Abgleich je Container
    static var last: [DataContainerKey: Date] = [:]
    /// Container, deren Abgleich aller Portale (Knopf oder Oeffnen) gerade laeuft: nie ein zweiter zugleich
    static var running: Set<DataContainerKey> = []
    /// Verbinden mit dem gespeicherten Uni-Zugang vor dem Abgleich (Tests ersetzen es durch eine Nachbildung)
    static var storedLoginConnect: @MainActor (ContainerManager, Bool) async -> StoredLoginReport = { m, userAction in
        await m.connectWithStoredLogin(userAction: userAction)
    }

    /// Namen der Portale wie in `StoredLoginReport`
    static let studIP = "Stud.IP", qis = "QIS", uniMail = "Uni-Mail"
}

extension ContainerManager {
    /// Beim Oeffnen, nach der Anmeldung und bei der Rueckkehr aus dem Hintergrund: faellig (`OpenSyncPolicy`) → alles
    /// einmal abgleichen; sonst die bisherigen `runIfDue`. Rueckgabe: true, wenn der Gesamt-Abgleich gestartet wurde.
    @discardableResult
    func syncAllOnOpen(now: Date = Date()) -> Bool {
        guard OpenSync.allowed(), let c = active, problem == nil else { return false }
        // laeuft schon ein Abgleich aller Portale (Knopf "Sync"), keinen zweiten und keine Einzel-Abrufe daneben
        guard !OpenSync.running.contains(c.key) else { return false }
        guard OpenSyncPolicy.due(last: OpenSync.last[c.key], now: now) else {
            runAllIfDue()
            return false
        }
        OpenSync.last[c.key] = now
        // LUH: alle Portale, mit gespeichertem Uni-Zugang vorher verbinden (still, keine Handlung des Menschen)
        if syncsAllPortals {
            beginAllPortals(c, userAction: false, forceGrades: false, finished: nil)
            return true
        }
        let mail = uniMail, studip = studip, hildesheim = hildesheim, hsh = hsh, qis = qis
        Task { @MainActor in
            // Posteingang zuerst (still, ohne bekannte abgelaufene Anmeldung)
            if let mail, mail.isConnected, !mail.isRunning, mail.state != .needsLogin { await mail.refreshInbox() }
            if !studip.isRunning { Task { await studip.run() } }  // prueft selbst Angebot, Sitzung und Demo
            if let hildesheim, hildesheim.anyConnected, !hildesheim.isRunning {
                // abgelaufen: zuerst still erneuern (startet danach selbst), sonst gleich voll abgleichen
                if hildesheim.expiredSources.isEmpty { Task { await hildesheim.run() } } else { hildesheim.runIfDue() }
            }
            if let hsh, hsh.anyConnected, !hsh.isRunning { Task { await hsh.run() } }
            qis?.runIfDue()                                       // Noten weiter hoechstens alle 20 Stunden
        }
        return true
    }

    /// Bisherige Regeln je Quelle (eigene Abstaende), wenn der Gesamt-Abgleich nicht faellig ist
    func runAllIfDue() {
        studip.runIfDue()
        hildesheim?.runIfDue()
        qis?.runIfDue()
        hsh?.runIfDue()
        uniMail?.runIfDue()
    }

    /// Der eine Knopf "Sync" (Kopfzeile) und "Jetzt abgleichen" in Dialogen fuer jede Hochschule des Containers:
    /// Hochschule Hannover (Moodle und Campusmanagement), Uni Hildesheim (Learnweb und LSF), LUH (Stud.IP). Befund
    /// 07.11.2026: der Knopf kannte nur Stud.IP und Hildesheim und sagte an der HsH "Zuerst Learnweb oder LSF
    /// verbinden". Demo prueft der Aufrufer. Nie zwei Laeufe zugleich (`isRunning`).
    /// LUH (10.11.2026): alle Portale - Stud.IP, QIS (mit Bescheinigungen, nur lesend) und Uni-Mail -, mit gespeichertem
    /// Uni-Zugang vorher verbinden; `finished` bekommt am Ende das Ergebnis fuer die Leiste (nur LUH).
    @discardableResult
    func startUniversitySync(forceGrades: Bool = true,
                             finished: (@MainActor (UniversitySyncReport) -> Void)? = nil) -> UniversitySyncStart {
        if let hsh {
            let names = HsHConnection.Source.allCases.filter { hsh.isConnected($0) }.map(\.rawValue)
            guard !names.isEmpty else { return .notConnected(UniversitySyncStart.connectHint(.hsh)) }
            if hsh.isRunning { return .alreadyRunning }
            Task { await hsh.run(forceGrades: forceGrades) }
            return .started(UniversitySyncStart.startedText(names))
        }
        if let hildesheim {
            let names = HildesheimConnection.Source.allCases.filter { hildesheim.isConnected($0) }.map(\.rawValue)
            guard !names.isEmpty else { return .notConnected(UniversitySyncStart.connectHint(.hildesheim)) }
            if hildesheim.isRunning { return .alreadyRunning }
            Task { await hildesheim.run() }
            return .started(UniversitySyncStart.startedText(names))
        }
        if syncsAllPortals, let c = active {
            if OpenSync.running.contains(c.key) { return .alreadyRunning }
            let stored = hasStoredLogin
            let names = stored ? portalNames : connectedPortals
            if names.isEmpty { return .notConnected(UniversitySyncStart.connectHint(.luh)) }
            // ohne gespeicherten Zugang und alle verbundenen Portale laufen schon: nichts Neues zu starten
            if !stored, connectedPortals.allSatisfy(portalBusy) { return .alreadyRunning }
            beginAllPortals(c, userAction: true, forceGrades: forceGrades, finished: finished)
            return .started(UniversitySyncStart.startedText(names))
        }
        return .notConnected(UniversitySyncStart.connectHint(active?.key.university))
    }

    // MARK: Alle Portale (LUH)

    /// Container mit Stud.IP und ohne Learnweb/LSF bzw. Moodle/Campusmanagement: LUH (Stud.IP, QIS, Uni-Mail)
    var syncsAllPortals: Bool { hsh == nil && hildesheim == nil && studip.offersStudIP }

    /// Portale dieses Containers in der Reihenfolge der Anzeige
    var portalNames: [String] {
        [OpenSync.studIP] + (qis == nil ? [] : [OpenSync.qis]) + (uniMail == nil ? [] : [OpenSync.uniMail])
    }

    /// Verbundene Portale ohne bekannte abgelaufene Anmeldung (laufend oder nicht)
    var connectedPortals: [String] {
        portalNames.filter { name in
            switch name {
            case OpenSync.studIP: return studip.phase != .signedOut && studip.phase != .needsLogin
            case OpenSync.qis: return qis.map { $0.isConnected && $0.state != .needsLogin } ?? false
            default: return uniMail.map { $0.isConnected && $0.state != .needsLogin } ?? false
            }
        }
    }

    /// Laeuft das Portal schon (ein Stud.IP-Lauf nur fuer fruehere Semester weicht dem Sync)?
    private func portalBusy(_ name: String) -> Bool {
        switch name {
        case OpenSync.studIP: return studip.isRunning && !studip.runningOlderOnly
        case OpenSync.qis: return qis?.isRunning ?? false
        default: return uniMail?.isRunning ?? false
        }
    }

    /// Merker setzen (sofort, damit ein zweiter Tipp "läuft bereits" sagt) und den Abgleich aller Portale starten
    private func beginAllPortals(_ c: ActiveContainer, userAction: Bool, forceGrades: Bool,
                                 finished: (@MainActor (UniversitySyncReport) -> Void)?) {
        let key = c.key
        OpenSync.running.insert(key)
        Task { @MainActor in
            let report = await self.runAllPortals(container: c, userAction: userAction, forceGrades: forceGrades)
            OpenSync.running.remove(key)
            finished?(report)
        }
    }

    /// Ein Abgleich aller Portale: gespeicherten Zugang verbinden, Uni-Mail zuerst, dann Stud.IP und QIS nebeneinander
    /// (verschiedene Rechner). `userAction`: Knopf "Sync" (gleicht auch nicht faellige Noten und die Bescheinigungen ab);
    /// beim Oeffnen gelten die eigenen Abstaende (Noten 20 Stunden, Bescheinigungen 7 Tage).
    private func runAllPortals(container c: ActiveContainer, userAction: Bool, forceGrades: Bool) async -> UniversitySyncReport {
        var report = UniversitySyncReport()
        if hasStoredLogin {
            let r = await OpenSync.storedLoginConnect(self, userAction)
            report.rejected = r.rejected
        }
        // nach dem Verbinden: die Verbindungen dieses Containers (ein Wechsel des Containers bricht hier ab)
        guard active === c else { return report }
        let studip = studip, qis = qis, mail = uniMail
        if let mail { await Self.syncMail(mail) }
        async let s: Void = Self.syncStudIP(studip, userAction: userAction)
        async let q: Bool = Self.syncQIS(qis, container: c, userAction: userAction, forceGrades: forceGrades)
        let (_, certificatesFailed) = await (s, q)
        report.add(OpenSync.studIP, Self.studIPNote(studip.phase))
        if let qis { report.add(OpenSync.qis, Self.qisNote(qis)) }
        if certificatesFailed { report.notes.append("Bescheinigungen: Fehler") }
        if let mail { report.add(OpenSync.uniMail, Self.mailNote(mail)) }
        return report
    }

    /// Wartet, solange `busy` gilt (hoechstens `seconds`)
    private static func wait(seconds: Double, while busy: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while busy(), Date() < end { try? await Task.sleep(nanoseconds: 200_000_000) }
    }

    /// Posteingang lesen (vor allem anderen); laeuft das Lesen schon (nach dem Verbinden), darauf warten
    private static func syncMail(_ mail: UniMailConnection) async {
        guard mail.isConnected, mail.state != .needsLogin else { return }
        if mail.isRunning { await wait(seconds: 60) { mail.isRunning }; return }
        await mail.refreshInbox()
    }

    /// Stud.IP abgleichen. Knopf: ohne Sitzung bzw. abgelaufen ueberspringen (verbunden hat schon `connectWithStoredLogin`);
    /// beim Oeffnen wie bisher immer `run` (prueft selbst Angebot, Sitzung und Demo und erneuert still)
    private static func syncStudIP(_ studip: StudIPSync, userAction: Bool) async {
        if userAction, studip.phase == .signedOut || studip.phase == .needsLogin { return }
        if studip.isRunning, !studip.runningOlderOnly {
            await wait(seconds: 30 * 60) { studip.isRunning }    // laeuft schon (z. B. nach dem Verbinden): abwarten
            return
        }
        await studip.run()
    }

    /// QIS: Noten mit Pruefungen und angemeldeten Pruefungen (`QISConnection.run`), danach die Liste der Bescheinigungen
    /// (nur Links, erzeugt kein Dokument; beim Oeffnen nur, wenn sie aelter als 7 Tage ist). Nie Anmelden zu Pruefungen.
    /// Rueckgabe: das Lesen der Bescheinigungen ist gescheitert (nicht wegen der Anmeldung).
    private static func syncQIS(_ qis: QISConnection?, container c: ActiveContainer, userAction: Bool, forceGrades: Bool) async -> Bool {
        guard let qis, qis.isConnected, qis.state != .needsLogin else { return false }
        if qis.isRunning {
            await wait(seconds: 5 * 60) { qis.isRunning }        // laeuft schon (z. B. nach dem Verbinden): abwarten
        } else {
            await qis.run(force: userAction && forceGrades)
        }
        guard qis.isConnected, !qis.isRunning else { return false }
        switch qis.state {
        case .ok, .connected: break
        default: return false
        }
        let center = CertificateCenter(portal: .qis(qis))
        if !userAction {
            let list = try? await c.api.value("/api/certificates")
            guard center.shouldRefresh(status: list?["status"]?.string, checkedAt: list?["checked_at"]?.string) else { return false }
        }
        guard let r = await center.refresh(), !r.cancelled else { return false }
        return !r.ok && !r.needsLogin
    }

    static func studIPNote(_ phase: StudIPSync.Phase) -> String? {
        switch phase {
        case .signedOut: return "nicht verbunden"
        case .needsLogin: return "Anmeldung nötig"
        case .failed: return "Fehler"
        case .idle, .running: return nil
        }
    }

    static func qisNote(_ qis: QISConnection) -> String? {
        switch qis.state {
        case .notConnected: return "nicht verbunden"
        case .needsLogin: return "Anmeldung nötig"
        case .failed: return "Fehler"
        case .connected, .running, .ok: return nil
        }
    }

    static func mailNote(_ mail: UniMailConnection) -> String? {
        guard mail.isConnected else { return "nicht verbunden" }
        switch mail.state {
        case .notConnected: return "nicht verbunden"
        case .needsLogin: return "Anmeldung nötig"
        case .failed: return "Fehler"
        case .connected, .running, .ok: return nil
        }
    }
}

/// Ergebnis eines Abgleichs aller Portale (Knopf "Sync" an der LUH) mit dem Text fuer die Leiste
struct UniversitySyncReport: Equatable {
    /// abgeglichene Portale ("Stud.IP", "QIS", "Uni-Mail")
    var synced: [String] = []
    /// uebersprungen oder gescheitert, je kurz ("QIS: Anmeldung nötig")
    var notes: [String] = []
    /// die Hochschule hat das gespeicherte Passwort abgelehnt
    var rejected = false

    mutating func add(_ portal: String, _ note: String?) {
        if let note { notes.append("\(portal): \(note)") } else { synced.append(portal) }
    }

    /// "Abgeglichen: Stud.IP und Uni-Mail. QIS: Anmeldung nötig."
    var text: String {
        var parts: [String] = []
        if rejected { parts.append("Die Hochschule hat das gespeicherte Passwort abgelehnt.") }
        parts.append(synced.isEmpty ? "Nichts abgeglichen." : "Abgeglichen: \(UniversitySyncStart.list(synced)).")
        parts += notes.map { $0 + "." }
        return parts.joined(separator: " ")
    }
}

/// Ergebnis von `ContainerManager.startUniversitySync` mit dem Text fuer die Leiste
enum UniversitySyncStart: Equatable {
    /// Abgleich laeuft los ("Moodle und Campusmanagement werden abgeglichen …")
    case started(String)
    /// nichts verbunden ("Zuerst Moodle oder Campusmanagement verbinden"): Weg zu den Einstellungen
    case notConnected(String)
    case alreadyRunning

    var text: String {
        switch self {
        case .started(let t), .notConnected(let t): return t
        case .alreadyRunning: return "Der Abgleich läuft bereits …"
        }
    }

    /// "Stud.IP wird abgeglichen …", "Stud.IP, QIS und Uni-Mail werden abgeglichen …"
    static func startedText(_ names: [String]) -> String {
        "\(list(names)) \(names.count == 1 ? "wird" : "werden") abgeglichen …"
    }

    /// "A", "A und B", "A, B und C"
    static func list(_ names: [String]) -> String {
        guard let lastName = names.last, names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " und " + lastName
    }

    /// Quellen der Hochschule, die zuerst verbunden sein muessen
    static func connectHint(_ u: UniversityKey?) -> String {
        switch u {
        case .hsh?: return "Zuerst Moodle oder Campusmanagement verbinden"
        case .hildesheim?: return "Zuerst Learnweb oder LSF verbinden"
        case .luh?: return "Zuerst den Uni-Zugang in den Einstellungen speichern"
        default: return "Zuerst die Hochschule verbinden"
        }
    }
}

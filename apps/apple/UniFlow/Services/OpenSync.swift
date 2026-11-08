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
}

extension ContainerManager {
    /// Beim Oeffnen, nach der Anmeldung und bei der Rueckkehr aus dem Hintergrund: faellig (`OpenSyncPolicy`) → alles
    /// einmal abgleichen; sonst die bisherigen `runIfDue`. Rueckgabe: true, wenn der Gesamt-Abgleich gestartet wurde.
    @discardableResult
    func syncAllOnOpen(now: Date = Date()) -> Bool {
        guard OpenSync.allowed(), let c = active, problem == nil else { return false }
        guard OpenSyncPolicy.due(last: OpenSync.last[c.key], now: now) else {
            runAllIfDue()
            return false
        }
        OpenSync.last[c.key] = now
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
    func startUniversitySync(forceGrades: Bool = true) -> UniversitySyncStart {
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
        if studip.offersStudIP {
            switch studip.phase {
            case .signedOut, .needsLogin: return .notConnected(UniversitySyncStart.connectHint(.luh))
            default:
                // ein Lauf nur fuer fruehere Semester (Stufe d) weicht dem Sync; er setzt spaeter fort
                if studip.isRunning, !studip.runningOlderOnly { return .alreadyRunning }
                Task { await studip.run() }
                return .started(UniversitySyncStart.startedText(["Stud.IP"]))
            }
        }
        return .notConnected(UniversitySyncStart.connectHint(active?.key.university))
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

    static func startedText(_ names: [String]) -> String {
        "\(names.joined(separator: " und ")) \(names.count == 1 ? "wird" : "werden") abgeglichen …"
    }

    /// Quellen der Hochschule, die zuerst verbunden sein muessen
    static func connectHint(_ u: UniversityKey?) -> String {
        switch u {
        case .hsh?: return "Zuerst Moodle oder Campusmanagement verbinden"
        case .hildesheim?: return "Zuerst Learnweb oder LSF verbinden"
        case .luh?: return "Zuerst Stud.IP verbinden"
        default: return "Zuerst die Hochschule verbinden"
        }
    }
}

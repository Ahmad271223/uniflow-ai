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
// Oeffnen ALLE Portale ab - Uni-Mail (SOGo), Stud.IP und QIS, seit 11.11.2026 nebeneinander (Noten, Pruefungen,
// angemeldete Pruefungen; Bescheinigungen nur die Liste, erzeugt nichts, seit 11.11.2026 in jedem solchen Sync und
// mit Zahl im Ergebnis). Ist ein Uni-Zugang gespeichert, verbindet die App vorher die Portale
// (`connectWithStoredLogin`, beim Knopf als Handlung des Menschen). Ein Portal ohne Verbindung wird uebersprungen und im
// Ergebnis genannt ("QIS: Anmeldung nötig"); ein Fehler eines Portals haelt die anderen nicht auf.
// Seit 17.11.2026 (Auftrag des Inhabers, docs/ABGLEICH-8-BIS-18-2026-11-17.md): von selbst nur zwischen 8 und 18 Uhr und
// je Portal alle 30 Minuten - beim Oeffnen, bei der Rueckkehr, im Takt bei offener App und im Hintergrundlauf
// (`runAutomaticSync`, AutoSync.swift; die Regel `AutoSyncSchedule` im Kern). Die Regeln oben "erster Wechsel nach aktiv:
// immer" und "nach 15 Minuten" (`OpenSyncPolicy`) gelten dafuer nicht mehr. Der Knopf "Sync" bleibt ohne Fenster und
// ohne Abstand: immer sofort, alle Portale, stille Neuanmeldung als Handlung des Menschen.

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
    /// Verbinden mit dem gespeicherten Uni-Zugang vor dem Abgleich (Tests ersetzen es durch eine Nachbildung).
    /// Parameter: Handlung des Menschen, nur diese Portale (nil: alle; der Abgleich von selbst: die faelligen)
    static var storedLoginConnect: @MainActor (ContainerManager, Bool, Set<String>?) async -> StoredLoginReport = { m, userAction, only in
        await m.connectWithStoredLogin(userAction: userAction, only: only)
    }

    /// Namen der Portale wie in `StoredLoginReport`
    static let studIP = "Stud.IP", qis = "QIS", uniMail = "Uni-Mail"
}

extension ContainerManager {
    /// Beim Oeffnen, nach der Anmeldung und bei der Rueckkehr aus dem Hintergrund. Seit 17.11.2026 (Auftrag des Inhabers,
    /// docs/ABGLEICH-8-BIS-18-2026-11-17.md) gilt dieselbe Regel wie fuer den Zeitgeber und den Hintergrundlauf
    /// (`runAutomaticSync`, AutoSync.swift): nur zwischen 8 und 18 Uhr, je Portal hoechstens alle 30 Minuten; ausserhalb
    /// gleicht nur der Knopf "Sync" ab. Die Uni-Mail behaelt zusaetzlich ihren bisherigen Abruf bei jedem Oeffnen
    /// (hoechstens alle 5 Minuten, zu jeder Uhrzeit), damit sie nicht schlechter wird.
    /// Rueckgabe: true, wenn ein Abgleich von selbst gestartet wurde.
    @discardableResult
    func syncAllOnOpen(now: Date = Date()) -> Bool {
        guard OpenSync.allowed(), let c = active, problem == nil else { return false }
        // laeuft schon ein Abgleich aller Portale (Knopf "Sync"), keinen zweiten und keine Einzel-Abrufe daneben
        guard !OpenSync.running.contains(c.key) else { return false }
        let started = runAutomaticSync(now: now)
        if !started.contains(OpenSync.uniMail) { uniMail?.runIfDue() }
        return !started.isEmpty
    }

    /// Der eine Knopf "Sync" (Kopfzeile) und "Jetzt abgleichen" in Dialogen fuer jede Hochschule des Containers:
    /// Hochschule Hannover (Moodle und Campusmanagement), Uni Hildesheim (Learnweb und LSF), LUH (Stud.IP). Befund
    /// 07.11.2026: der Knopf kannte nur Stud.IP und Hildesheim und sagte an der HsH "Zuerst Learnweb oder LSF
    /// verbinden". Demo prueft der Aufrufer. Nie zwei Laeufe zugleich (`isRunning`).
    /// LUH (10.11.2026): alle Portale - Stud.IP, QIS (mit Bescheinigungen, nur lesend) und Uni-Mail -, mit gespeichertem
    /// Uni-Zugang vorher verbinden; `finished` bekommt am Ende das Ergebnis fuer die Leiste (nur LUH).
    /// "Sync" immer sofort (Auftrag des Inhabers 17.11.2026): zu jeder Uhrzeit, ohne Fenster und ohne Abstand. Laeuft
    /// gerade ein Abgleich von selbst (oft nur die faelligen Portale), wartet der Tipp darauf und gleicht danach ALLE
    /// Portale als Handlung des Menschen ab - nie zwei Laeufe zugleich, ein zweiter Tipp sagt "läuft bereits".
    @discardableResult
    func startUniversitySync(forceGrades: Bool = true,
                             finished: (@MainActor (UniversitySyncReport) -> Void)? = nil) -> UniversitySyncStart {
        if hsh == nil, let c = active, OpenSync.running.contains(c.key), let auto = AutoSync.automatic[c.key] {
            let key = c.key
            if AutoSync.userQueued.contains(key) { return .alreadyRunning }
            let names: [String]
            if let hildesheim {
                let stored = hasStoredLogin
                names = HildesheimConnection.Source.allCases.filter { stored || hildesheim.isConnected($0) }.map(\.rawValue)
                    + ((uniMail.map { stored || $0.isConnected } ?? false) ? [OpenSync.uniMail] : [])
            } else {
                names = hasStoredLogin ? portalNames : connectedPortals
            }
            guard !names.isEmpty else { return .alreadyRunning }
            AutoSync.userQueued.insert(key)
            Task { @MainActor in
                await auto.value
                AutoSync.userQueued.remove(key)
                guard self.active === c else { return }
                _ = self.startUniversitySync(forceGrades: forceGrades, finished: finished)
            }
            return .started(UniversitySyncStart.startedText(names))
        }
        if let hsh {
            let names = HsHConnection.Source.allCases.filter { hsh.isConnected($0) }.map(\.rawValue)
            guard !names.isEmpty else { return .notConnected(UniversitySyncStart.connectHint(.hsh)) }
            if hsh.isRunning { return .alreadyRunning }
            Task {
                // abgelaufen: zuerst still mit dem gespeicherten Zugang anmelden, als Handlung des Menschen (ohne
                // Ruecknahme; `autoLogin` gleicht danach selbst ab), dann der Abgleich der uebrigen Quellen
                for s in HsHConnection.Source.allCases where hsh.isConnected(s) && hsh.state(s) == .needsLogin {
                    _ = await hsh.autoLogin(s, userAction: true)
                }
                await hsh.run(forceGrades: forceGrades)
            }
            return .started(UniversitySyncStart.startedText(names))
        }
        // Uni Hildesheim (12.11.2026, wie die LUH seit 10.11.): ein Tipp gleicht alle Portale ab - Learnweb, LSF (Noten,
        // angemeldete Pruefungen), PLuS-Bescheinigungen (nur die Liste) und Uni-Mail -, vorher mit dem gespeicherten
        // Uni-Zugang verbinden
        if let hildesheim, let c = active {
            // laeuft der Datei-Abgleich schon (z. B. der erste nach dem Verbinden, 25 Minuten am 15.11.2026), verbindet der
            // Knopf trotzdem die uebrigen Portale (Uni-Mail) und wartet dann auf ihn - vorher nur "läuft bereits"
            if OpenSync.running.contains(c.key) { return .alreadyRunning }
            let stored = hasStoredLogin
            let names = HildesheimConnection.Source.allCases.filter { stored || hildesheim.isConnected($0) }.map(\.rawValue)
                + ((uniMail.map { stored || $0.isConnected } ?? false) ? [OpenSync.uniMail] : [])
            guard !names.isEmpty else { return .notConnected(UniversitySyncStart.connectHint(.hildesheim)) }
            let key = c.key
            OpenSync.running.insert(key)
            Task { @MainActor in
                let report = await self.runHildesheimPortals(container: c, hildesheim: hildesheim, userAction: true, forceGrades: forceGrades)
                OpenSync.running.remove(key)
                finished?(report)
            }
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
    /// `only`: nur diese Portale (Abgleich von selbst: die faelligen); nil: alle
    func beginAllPortals(_ c: ActiveContainer, userAction: Bool, forceGrades: Bool, only: Set<String>? = nil,
                         finished: (@MainActor (UniversitySyncReport) -> Void)?) {
        let key = c.key
        OpenSync.running.insert(key)
        Task { @MainActor in
            let report = await self.runAllPortals(container: c, userAction: userAction, forceGrades: forceGrades, only: only)
            OpenSync.running.remove(key)
            finished?(report)
        }
    }

    /// Ein Abgleich aller Portale: gespeicherten Zugang verbinden, dann Uni-Mail, Stud.IP und QIS nebeneinander
    /// (verschiedene Rechner; Stud.IP nur bis "fertig"). `userAction`: Knopf "Sync" (gleicht auch nicht faellige
    /// Noten ab); beim Oeffnen gelten fuer die Noten die eigenen 20 Stunden. Die Liste der Bescheinigungen liest jeder solche Sync (nur lesend).
    /// `forceGrades`: Noten auch vor Ablauf ihrer eigenen 20 Stunden (Knopf; von selbst, wenn QIS nach der Regel faellig
    /// ist). `only`: nur diese Portale.
    func runAllPortals(container c: ActiveContainer, userAction: Bool, forceGrades: Bool,
                               only: Set<String>? = nil, now: Date = Date()) async -> UniversitySyncReport {
        var report = UniversitySyncReport()
        if hasStoredLogin {
            let r = await OpenSync.storedLoginConnect(self, userAction, only)
            report.rejected = r.rejected
        } else if studip.offersStudIP, studip.phase == .needsLogin, only?.contains(OpenSync.studIP) ?? true {
            // ohne gespeicherten Zugang: die abgelaufene Stud.IP-Sitzung ueber die noch gueltige Uni-Anmeldung (WebSSO)
            // erneuern, ohne Passwort - beim Knopf als Handlung des Menschen (vorher uebersprang der Knopf Stud.IP dann)
            _ = await studip.renewSilently(trigger: userAction ? .userAction : .foreground)
        }
        // nach dem Verbinden: die Verbindungen dieses Containers (ein Wechsel des Containers bricht hier ab)
        guard active === c else { return report }
        func wanted(_ name: String) -> Bool { only?.contains(name) ?? true }
        let studip = studip, qis = wanted(OpenSync.qis) ? qis : nil, mail = wanted(OpenSync.uniMail) ? uniMail : nil
        // Liste der Bescheinigungen: beim Knopf immer; von selbst hoechstens alle `AutoSync.certificatesInterval` und
        // nur, wenn QIS mitlaeuft (sonst verbrauchte ein reiner Mail-Abruf den Termin der Liste, 27.11.2026)
        let certificatesWanted = userAction || (qis != nil && autoCertificatesDue(c, now: now))
        // Uni-Mail, Stud.IP und QIS nebeneinander (11.11.2026; vorher wartete alles auf den Posteingang). Die
        // unsichtbaren Anmeldungen bleiben je Datenspeicher nacheinander (`UniAutoLogin`, `Entry.tail`)
        async let m: Void = Self.syncMail(mail)
        async let s: Void = Self.syncStudIP(wanted(OpenSync.studIP) ? studip : nil, userAction: userAction)
        async let q: CertificatesSync.Report? = Self.syncQIS(qis, container: c, userAction: userAction, forceGrades: forceGrades,
                                                             certificates: certificatesWanted)
        let (_, _, certificates) = await (m, s, q)
        if wanted(OpenSync.studIP) { report.add(OpenSync.studIP, Self.studIPNote(studip.phase)) }
        if let qis { report.add(OpenSync.qis, Self.qisNote(qis)) }
        if let certificates {
            if certificates.ok {
                report.info.append(Self.certificatesNote(certificates.offers))
            } else if !certificates.needsLogin {
                report.notes.append("Bescheinigungen: Fehler")
            }
        }
        if let mail { report.add(OpenSync.uniMail, Self.mailNote(mail)) }
        return report
    }

    // MARK: Alle Portale (Uni Hildesheim)

    /// Ein Abgleich aller Portale der Uni Hildesheim: gespeicherten Zugang verbinden (Learnweb, LSF, Uni-Mail), eine
    /// abgelaufene Anmeldung still erneuern und abwarten, dann Uni-Mail und Learnweb/LSF nebeneinander, danach die Liste
    /// der PLuS-Bescheinigungen (nur lesend, erzeugt nichts). `forceGrades`: Noten auch vor Ablauf der 20 Stunden.
    /// `only`: nur diese Portale (Abgleich von selbst: die faelligen; Learnweb und LSF laufen zusammen); nil: alle.
    func runHildesheimPortals(container c: ActiveContainer, hildesheim: HildesheimConnection, userAction: Bool,
                              forceGrades: Bool, only: Set<String>? = nil, now: Date = Date()) async -> UniversitySyncReport {
        var report = UniversitySyncReport()
        if hasStoredLogin {
            let r = await OpenSync.storedLoginConnect(self, userAction, only)
            report.rejected = r.rejected
        } else if !hildesheim.expiredSources.isEmpty,
                  HildesheimConnection.Source.allCases.contains(where: { only?.contains($0.rawValue) ?? true }) {
            // nur, wenn Learnweb oder LSF in diesem Lauf dran sind (27.11.2026: ein reiner Mail-Abruf meldet sie nicht an)
            _ = await hildesheim.renewSilently(trigger: userAction ? .userAction : .foreground)
        }
        guard active === c else { return report }
        func wanted(_ name: String) -> Bool { only?.contains(name) ?? true }
        let files = HildesheimConnection.Source.allCases.contains { wanted($0.rawValue) }
        let mail = wanted(OpenSync.uniMail) ? uniMail : nil
        let certificatesWanted = userAction || (files && autoCertificatesDue(c, now: now))
        // eine schon vorhandene SOGo-Sitzung uebernehmen (ohne Passwort), bevor der Posteingang gelesen wird
        if let mail, !mail.isConnected, OpenSync.allowed() { _ = await mail.adoptExistingSession() }
        async let m: Void = Self.syncMail(mail)
        async let h: Void = Self.syncHildesheim(files ? hildesheim : nil, forceGrades: forceGrades)
        _ = await (m, h)
        if files { for s in HildesheimConnection.Source.allCases { report.add(s.rawValue, Self.hildesheimNote(hildesheim, s)) } }
        if files, certificatesWanted, hildesheim.isConnected(.lsf), hildesheim.state(.lsf) != .needsLogin,
           let r = await CertificateCenter(portal: .plus(hildesheim)).refresh(), !r.cancelled {
            if r.ok { report.info.append(Self.certificatesNote(r.offers)) } else if !r.needsLogin { report.notes.append("Bescheinigungen: Fehler") }
        }
        if let mail { report.add(OpenSync.uniMail, Self.mailNote(mail)) }
        return report
    }

    /// Learnweb/LSF abgleichen; laeuft schon ein Lauf (z. B. nach dem Verbinden), darauf warten
    private static func syncHildesheim(_ h: HildesheimConnection?, forceGrades: Bool) async {
        guard let h, h.anyConnected else { return }
        if h.isRunning { await wait(seconds: 30 * 60) { h.isRunning }; if !forceGrades { return } }
        await h.run(forceGrades: forceGrades)
    }

    static func hildesheimNote(_ h: HildesheimConnection, _ s: HildesheimConnection.Source) -> String? {
        guard h.isConnected(s) else { return "nicht verbunden" }
        switch h.state(s) {
        case .notConnected: return "nicht verbunden"
        case .needsLogin: return "Anmeldung nötig"
        case .failed: return "Fehler"
        case .connected, .running, .ok: return nil
        }
    }

    /// Wartet, solange `busy` gilt (hoechstens `seconds`)
    private static func wait(seconds: Double, while busy: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while busy(), Date() < end { try? await Task.sleep(nanoseconds: 200_000_000) }
    }

    /// Posteingang lesen (neben Stud.IP und QIS); laeuft das Lesen schon (nach dem Verbinden), darauf warten
    private static func syncMail(_ mail: UniMailConnection?) async {
        guard let mail, mail.isConnected, mail.state != .needsLogin else { return }
        if mail.isRunning { await wait(seconds: 60) { mail.isRunning }; return }
        await mail.refreshInbox()
    }

    /// Stud.IP abgleichen. Knopf: ohne Sitzung bzw. abgelaufen ueberspringen (verbunden hat schon `connectWithStoredLogin`);
    /// beim Oeffnen wie bisher immer `run` (prueft selbst Angebot, Sitzung und Demo und erneuert still)
    private static func syncStudIP(_ studip: StudIPSync?, userAction: Bool) async {
        guard let studip else { return }
        if userAction, studip.phase == .signedOut || studip.phase == .needsLogin { return }
        if studip.finishingUp { return }                         // eben fertig, Aufzeichnungen/Lernstoff laufen noch
        if studip.isRunning, !studip.runningOlderOnly {
            await wait(seconds: 30 * 60) { studip.isRunning }    // laeuft schon (z. B. nach dem Verbinden): abwarten
            return
        }
        await studip.runUntilReady()                             // nur bis "fertig" (11.11.2026)
    }

    /// QIS: Noten mit Pruefungen und angemeldeten Pruefungen (`QISConnection.runRenewingSession`: eine dabei abgelaufene
    /// Sitzung wird still erneuert und abgewartet, dann im selben Lauf neu gelesen), danach IMMER die Liste der
    /// Bescheinigungen (11.11.2026; nur Menues und Links, erzeugt nie ein Dokument - verpublish, hisreports, verify und
    /// Formulare bleiben dem Tippen vorbehalten). Nie Anmelden zu Pruefungen.
    /// Rueckgabe: Ergebnis der Liste (nil, wenn sie nicht gelesen wurde).
    /// `certificates: false`: ohne die Liste der Bescheinigungen (Abgleich von selbst, Liste noch nicht wieder faellig).
    private static func syncQIS(_ qis: QISConnection?, container c: ActiveContainer, userAction: Bool,
                                forceGrades: Bool, certificates: Bool = true) async -> CertificatesSync.Report? {
        // QIS gerade im In-App-Browser offen: nicht in derselben Sitzung lesen (QISConnection.browserUses)
        guard let qis, qis.isConnected, qis.state != .needsLogin, !qis.browserOpen else { return nil }
        if qis.isRunning {
            await wait(seconds: 5 * 60) { qis.isRunning }        // laeuft schon (z. B. nach dem Verbinden): abwarten
        } else {
            await qis.runRenewingSession(force: forceGrades, userAction: userAction)
        }
        guard certificates, qis.isConnected, !qis.isRunning, !qis.browserOpen else { return nil }
        switch qis.state {
        case .ok, .connected: break
        default: return nil
        }
        guard let r = await CertificateCenter(portal: .qis(qis)).refresh(), !r.cancelled else { return nil }
        return r
    }

    /// "Bescheinigungen: 2 verfügbar" (Ergebnis des Sync)
    static func certificatesNote(_ offers: Int) -> String {
        offers == 0 ? "Bescheinigungen: keine verfügbar" : "Bescheinigungen: \(offers) verfügbar"
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
    /// gelungen, mit Ergebnis ("Bescheinigungen: 2 verfügbar")
    var info: [String] = []
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
        parts += info.map { $0 + "." }
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
        case .luh?, .goettingen?: return "Zuerst den Uni-Zugang in den Einstellungen speichern"
        default: return "Zuerst die Hochschule verbinden"
        }
    }
}

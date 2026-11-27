import Foundation
import UniFlowCore

// Abgleich von selbst (Auftrag des Inhabers 17.11.2026, docs/ABGLEICH-8-BIS-18-2026-11-17.md): zwischen 8 und 18 Uhr
// Ortszeit gleicht die App alle verbundenen Portale von selbst ab, je Portal alle 30 Minuten - Stud.IP, QIS und Uni-Mail
// (LUH), Learnweb, LSF und Uni-Mail (Uni Hildesheim), Moodle und Campusmanagement (HsH). Ausserhalb nur der Knopf "Sync".
// Die Rechnung steht im Kern (`AutoSyncSchedule`, `AutoSyncLedger`); hier:
// - `ContainerManager.runAutomaticSync`: der EINE Einstieg fuer jeden Abgleich von selbst bei offener App (Oeffnen,
//   Rueckkehr aus dem Hintergrund, Zeitgeber). Er fragt die Regel je Portal, vermerkt den Versuch, bevor er beginnt,
//   und benutzt denselben Abgleich aller Portale wie der Knopf (OpenSync.swift) - nur ohne "Handlung des Menschen":
//   die stille Neuanmeldung folgt den Ruecknahmen von `UniAutoLoginMachine` und `UniRenewalPolicy`, ein abgelehntes
//   Passwort ist vergessen und wird nie erneut gesendet.
// - `AutoSyncTicker`: der Zeitgeber bei offener App. Er schlaeft bis zum naechsten faelligen Zeitpunkt (hoechstens
//   5 Minuten am Stueck, damit eine verstellte Uhr, eine neue Zeitzone oder ein eben verbundenes Portal bald zaehlen) und
//   fragt dann nur die Regel; ist nichts faellig, aendert sich nichts an der Oberflaeche.
// Der Abgleich selbst laeuft wie bisher: Netz, Datenbank, Dateien und Pruefsummen ausserhalb des Hauptthreads (Actors
// des Kerns), kein Dialog, kein Sprung; sichtbar ist nur der dezente Fortschritt der Leiste.
// Sparsam: die Liste der Bescheinigungen (QIS, PLuS) liest ein Abgleich von selbst hoechstens alle 6 Stunden; meldet
// eine Hochschule "ueberlastet" (429/503), ruht der Abgleich von selbst fuer dieses Portal 2 Stunden.
// Seit 26.11.2026 ("Abruf schonen", Freigabe des Inhabers): Noten (QIS der LUH, LSF der Uni Hildesheim, Campus der HsH)
// liest ein Abgleich von selbst hoechstens alle 4 Stunden (`gradesInterval`, also 3-mal im Fenster statt 20-mal), und
// jedes Geraet beginnt das Fenster mit einem festen Versatz von 0 bis 29 Minuten (`AutoSyncStagger`). Der Knopf "Sync"
// fragt weiter alles sofort ab.
// Seit 27.11.2026 (Auftrag des Inhabers, docs/ABRUF-ZWEIMAL-TAEGLICH-2026-11-27.md): "die App soll 2-mal am Tag pro
// Nutzer sich selber einloggen, ausser ein Nutzer drueckt selber auf Sync … aber Mail immer, nicht nur 2-mal". Alle
// Portale ausser der Uni-Mail gleicht die App von selbst nur noch in zwei festen Fenstern am Tag ab (`schedule` =
// `AutoSyncSchedule.twiceDaily`: ab 8 und ab 14 Uhr, je Geraet um 0 bis 59 Minuten versetzt, verpasst bis 18 Uhr
// nachgeholt); die Uni-Mail behaelt alle 30 Minuten (`mailSchedule`) und den Abruf beim Oeffnen. Das gilt bei offener
// App, im Hintergrund von iOS, nach dem Weck-Signal und am Mac - alle fragen dieselbe Regel (`autoSyncDue`). "Sync"
// fragt weiter alles sofort ab, so oft man will.

@MainActor
enum AutoSync {
    /// Plan aller Portale ausser der Uni-Mail: zweimal am Tag (Tests setzen eigene). In der App mit dem festen Versatz
    /// dieses Geraets; unter XCTest ohne, damit die Tests mit festen Uhrzeiten (8:00, 14:00) rechnen koennen.
    static var schedule: AutoSyncSchedule = StudIPSync.isUnderTest()
        ? .twiceDaily : .twiceDaily.staggered(by: AutoSyncStagger.slotOffset(defaults: .standard))
    /// Plan der Uni-Mail: zwischen 8 und 18 Uhr alle 30 Minuten (unter XCTest ohne Versatz)
    static var mailSchedule: AutoSyncSchedule = StudIPSync.isUnderTest()
        ? .standard : .standard.staggered(by: AutoSyncStagger.offset(defaults: .standard))
    /// Ortszeit des Geraets (auf Reisen die dortige)
    static var timeZone: () -> TimeZone = { TimeZone.current }
    /// Liste der Bescheinigungen von selbst hoechstens so oft (der Knopf "Sync" liest sie immer)
    static let certificatesInterval: TimeInterval = 6 * 3600
    static let certificates = "Bescheinigungen"
    /// Noten von selbst hoechstens so oft (Uni Hildesheim, HsH: im Abgleich der Dateien, der selbst nur noch zweimal am
    /// Tag laeuft; QIS der LUH folgt seit 27.11.2026 wie jedes Portal den zwei Fenstern). Der Knopf "Sync" liest sie immer.
    static let gradesInterval: TimeInterval = 4 * 3600
    static let grades = "Noten"
    /// Vor einem Abgleich von selbst (Mitteilungen: Stand der Datenbank vorher; Tests)
    static var willRun: (@MainActor (ActiveContainer, Set<String>) async -> Void)?
    /// Nach einem Abgleich von selbst mit den abgeglichenen Portalen (Mitteilungen ueber Neues; Tests)
    static var didRun: (@MainActor (ActiveContainer, Set<String>) async -> Void)?
    /// Laufender Abgleich von selbst je Container (der Knopf "Sync" wartet darauf und gleicht danach alles ab)
    static var automatic: [DataContainerKey: Task<Void, Never>] = [:]
    /// Container, bei denen ein Tipp auf "Sync" auf das Ende des Abgleichs von selbst wartet (nie zwei)
    static var userQueued: Set<DataContainerKey> = []
}

/// Ein Portal, das am Abgleich von selbst teilnimmt
struct AutoSyncPortalState: Equatable {
    let name: String
    /// letzter gelungener Abgleich (auch von Hand)
    let lastSuccess: Date?
    /// ein begonnener Abgleich wartet auf seine Fortsetzung
    var pending = false
}

extension ContainerManager {
    func autoLedger(_ c: ActiveContainer) -> AutoSyncLedger {
        AutoSyncLedger(defaults: c.defaults, schedule: AutoSync.schedule, overrides: [OpenSync.uniMail: AutoSync.mailSchedule])
    }

    /// Portale des offenen Containers, die von selbst abgeglichen werden: verbunden oder - mit gespeichertem Uni-Zugang -
    /// noch zu verbinden (nie eines, bei dem sich der Mensch bewusst abgemeldet hat). Ohne Portal: nichts.
    var autoSyncPortals: [AutoSyncPortalState] {
        guard active != nil else { return [] }
        if let hsh {
            return HsHConnection.Source.allCases.filter { hsh.isConnected($0) }
                .map { AutoSyncPortalState(name: $0.rawValue, lastSuccess: hsh.lastRun) }
        }
        let stored = hasStoredLogin
        var out: [AutoSyncPortalState] = []
        if let h = hildesheim {
            let waiting = h.downloadsPending || h.interrupted
            for s in HildesheimConnection.Source.allCases where h.isConnected(s) || stored {
                out.append(AutoSyncPortalState(name: s.rawValue, lastSuccess: h.lastRun, pending: waiting && h.isConnected(s)))
            }
        } else if studip.offersStudIP {
            let store = studip.websiteDataStore
            if studip.hasStoredSession || (stored && !UniAutoLogin.signedOut(.studip, store: store)) {
                out.append(AutoSyncPortalState(name: OpenSync.studIP, lastSuccess: studip.lastRun,
                                               pending: studip.hasStoredSession && (studip.downloadsPending || studip.interrupted)))
            }
            if let qis, qis.isConnected || (stored && !UniAutoLogin.signedOut(.qis, store: store)) {
                out.append(AutoSyncPortalState(name: OpenSync.qis, lastSuccess: qis.lastRun))
            }
        }
        if let mail = uniMail, mail.isConnected || (stored && !UniAutoLogin.signedOut(.sogo, store: studip.websiteDataStore)) {
            out.append(AutoSyncPortalState(name: OpenSync.uniMail, lastSuccess: mail.lastCheck))
        }
        return out
    }

    /// Portale, die nach der Regel jetzt faellig sind (im Fenster, Abstand um, keine Pause nach "ueberlastet").
    /// `timeZone`: nil = `AutoSync.timeZone()`. `continueAtOnce`: wartende Arbeit ohne `AutoSyncLedger.retryGap` (der
    /// lange Hintergrundlauf laedt die Dateien eines eben gelaufenen kurzen Laufs; iOS bestimmt dort ohnehin den Takt)
    func autoSyncDue(now: Date, timeZone: TimeZone? = nil, continueAtOnce: Bool = false) -> Set<String> {
        guard let c = active else { return [] }
        let ledger = autoLedger(c), tz = timeZone ?? AutoSync.timeZone()
        return Set(autoSyncPortals.filter {
            ledger.isDue($0.name, lastSuccess: $0.lastSuccess, pending: $0.pending, now: now, timeZone: tz,
                         retryGap: continueAtOnce ? 0 : AutoSyncLedger.retryGap)
        }.map(\.name))
    }

    /// Fruehester naechster Abgleich von selbst (fuer den Zeitgeber und den Wunschtermin an iOS). Ohne Portal: der
    /// naechste Zeitpunkt im Fenster, damit ein spaeter verbundenes Portal mitkommt.
    func nextAutomaticSync(now: Date, timeZone: TimeZone? = nil) -> Date {
        let tz = timeZone ?? AutoSync.timeZone()
        guard let c = active else { return AutoSync.schedule.nextRun(last: nil, now: now, timeZone: tz) }
        let ledger = autoLedger(c)
        let times = autoSyncPortals.map { p -> Date in
            // wartende Arbeit (unterbrochen, Dateien noch nicht geladen) darf frueher weitergehen
            if p.pending, ledger.isDue(p.name, lastSuccess: p.lastSuccess, pending: true, now: now, timeZone: tz) { return now }
            return ledger.nextRun(p.name, lastSuccess: p.lastSuccess, now: now, timeZone: tz)
        }
        return times.min() ?? AutoSync.schedule.nextRun(last: nil, now: now, timeZone: tz)
    }

    /// Liste der Bescheinigungen in einem Abgleich von selbst lesen? Hoechstens alle `AutoSync.certificatesInterval`;
    /// vermerkt den Versuch gleich.
    func autoCertificatesDue(_ c: ActiveContainer, now: Date = Date()) -> Bool {
        let ledger = autoLedger(c)
        guard ledger.isDue(AutoSync.certificates, lastSuccess: nil, now: now, timeZone: AutoSync.timeZone(),
                           interval: AutoSync.certificatesInterval) else { return false }
        ledger.recordAttempt(AutoSync.certificates, at: now, timeZone: AutoSync.timeZone())
        return true
    }

    /// Noten in einem Abgleich von selbst lesen (Uni Hildesheim, HsH: Noten laufen dort im Abgleich der Dateien mit)?
    /// Hoechstens alle `AutoSync.gradesInterval`; vermerkt den Versuch gleich. Nein heisst: die Quelle entscheidet nach
    /// ihrer eigenen, laengeren Regel (`gradesDue`, 20 Stunden).
    func autoGradesDue(_ c: ActiveContainer, now: Date = Date()) -> Bool {
        let ledger = autoLedger(c)
        guard ledger.isDue(AutoSync.grades, lastSuccess: nil, now: now, timeZone: AutoSync.timeZone(),
                           interval: AutoSync.gradesInterval) else { return false }
        ledger.recordAttempt(AutoSync.grades, at: now, timeZone: AutoSync.timeZone())
        return true
    }

    /// Der eine Einstieg fuer den Abgleich von selbst bei offener App: beim Oeffnen, bei der Rueckkehr und im Takt des
    /// Zeitgebers. Gleicht genau die Portale ab, die nach der Regel faellig sind - nichts ausserhalb von 8 bis 18 Uhr,
    /// nichts ohne verbundenes Portal, nichts mit Demo-Inhalten, nie neben einem laufenden Abgleich aller Portale.
    /// Rueckgabe: die gestarteten Portale (leer: nichts gestartet).
    @discardableResult
    func runAutomaticSync(now: Date = Date()) -> Set<String> {
        guard OpenSync.allowed(), let c = active, problem == nil, !demoActive else { return [] }
        guard !OpenSync.running.contains(c.key), !isSyncing(c.key) else { return [] }
        let due = autoSyncDue(now: now)
        guard !due.isEmpty else { return [] }
        // Versuch vermerken, BEVOR er beginnt: auch ein gescheiterter oder abgebrochener Lauf zaehlt fuer sein Fenster
        let ledger = autoLedger(c)
        for p in due { ledger.recordAttempt(p, at: now, timeZone: AutoSync.timeZone()) }
        OpenSync.last[c.key] = now
        let key = c.key
        OpenSync.running.insert(key)
        AutoSync.automatic[key] = Task { @MainActor in
            defer { AutoSync.automatic[key] = nil }
            await AutoSync.willRun?(c, due)
            // Noten nur fragen, wenn eine Quelle der Dateien mitlaeuft (ein reiner Mail-Abruf verbraucht ihren Termin nicht)
            let files = !due.subtracting([OpenSync.uniMail]).isEmpty
            if let hsh = self.hsh {
                // eine abgelaufene Quelle meldet sich nach dem Lauf selbst still neu an (`HsHConnection.run`)
                await hsh.run(forceGrades: files && self.autoGradesDue(c, now: now))
            } else if let h = self.hildesheim {
                _ = await self.runHildesheimPortals(container: c, hildesheim: h, userAction: false,
                                                    forceGrades: files && self.autoGradesDue(c, now: now), only: due, now: now)
            } else if self.syncsAllPortals {
                _ = await self.runAllPortals(container: c, userAction: false, forceGrades: due.contains(OpenSync.qis), only: due, now: now)
            }
            OpenSync.running.remove(key)
            guard self.active === c else { return }
            self.noteAutomaticResult(c, portals: due, now: now)
            await AutoSync.didRun?(c, due)
        }
        return due
    }

    /// Nach einem Abgleich von selbst: meldete ein Portal "ueberlastet" (429/503), ruht es `AutoSyncOverload.pause`;
    /// lief es ohne Fehler, endet eine alte Pause.
    func noteAutomaticResult(_ c: ActiveContainer, portals: Set<String>, now: Date) {
        let ledger = autoLedger(c)
        for p in portals {
            let message = automaticFailure(p)
            if AutoSyncOverload.mentionsOverload(message) { ledger.pause(p, from: now) } else if message == nil { ledger.clearPause(p) }
        }
    }

    /// Fehlermeldung des letzten Abgleichs dieses Portals (nil: kein Fehler)
    func automaticFailure(_ portal: String) -> String? {
        if let hsh, let s = HsHConnection.Source(rawValue: portal) {
            if case .failed(let m) = hsh.state(s) { return ([m] + hsh.messages).joined(separator: " ") }
            return nil
        }
        if let h = hildesheim, let s = HildesheimConnection.Source(rawValue: portal) {
            if case .failed(let m) = h.state(s) { return ([m] + h.messages).joined(separator: " ") }
            return nil
        }
        switch portal {
        case OpenSync.studIP:
            if case .failed(let m) = studip.phase { return m }
        case OpenSync.qis:
            if case .failed(let m)? = qis?.state { return m }
        case OpenSync.uniMail:
            if case .failed(let m)? = uniMail?.state { return m }
        default: break
        }
        return nil
    }
}

/// Zeitgeber des Abgleichs von selbst bei offener App: wartet bis zum naechsten faelligen Zeitpunkt und ruft dann `tick`
/// (der fragt die Regel und startet, was faellig ist). Auf iPad und iPhone laeuft er, solange die App vorn ist (im
/// Hintergrund haelt iOS die App ohnehin an); am Mac ("Designed for iPad"), solange die App laeuft.
/// Schreiben im Editor: Ist ein Dokument offen (`editing`), schiebt der Zeitgeber den Abgleich auf, bis es zu ist, aber
/// hoechstens `maxHold` (der Abgleich selbst laeuft ohnehin abseits des Hauptthreads; so faellt auch das Schreiben in
/// die Datenbank und das Laden der Dateien nicht mitten in einen Strich). Der Knopf "Sync" wartet nie.
@MainActor
final class AutoSyncTicker {
    /// nie laenger am Stueck schlafen: eine verstellte Uhr, eine neue Zeitzone oder ein eben verbundenes Portal zaehlen
    /// spaetestens dann
    static let maxSleep: TimeInterval = 5 * 60
    /// nie kuerzer (kein Dauerfeuer, wenn ein Lauf nicht starten kann)
    static let minSleep: TimeInterval = 15
    /// Dokument offen: so lange hoechstens aufschieben, dann trotzdem
    static let maxHold: TimeInterval = 10 * 60
    /// waehrend des Aufschubs so oft nachsehen, ob das Dokument zu ist
    static let holdPoll: TimeInterval = 60

    /// Wartezeit bis `next`, begrenzt auf `minSleep` … `maxSleep`
    static func delay(next: Date, now: Date) -> TimeInterval { min(max(next.timeIntervalSince(now), minSleep), maxSleep) }

    /// Aufschieben? Nur mit offenem Dokument und nur bis `maxHold` nach dem ersten Aufschub (Uhr zurueckgestellt: nicht
    /// mehr aufschieben)
    static func holds(editing: Bool, heldSince: Date?, now: Date) -> Bool {
        guard editing else { return false }
        guard let heldSince else { return true }
        let age = now.timeIntervalSince(heldSince)
        return age >= 0 && age < maxHold
    }

    private let next: @MainActor (Date) -> Date
    private let tick: @MainActor (Date) async -> Void
    /// Uhr (Tests: eingefroren und vorgespult)
    var now: () -> Date = { Date() }
    /// Warten; false, wenn abgebrochen (Tests: spulen die Uhr vor)
    var sleep: (TimeInterval) async -> Bool = { s in (try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))) != nil }
    /// Ist gerade ein Dokument im Editor offen? (App: ein Fenster zeigt ein Dokument)
    var editing: @MainActor () -> Bool = { false }
    /// seit wann aufgeschoben wird (nil: nicht)
    private(set) var heldSince: Date?
    private var task: Task<Void, Never>?
    /// am Mac: App Nap wuerde den Takt sonst stark verzoegern (erlaubt den Ruhezustand des Macs)
    private var activity: NSObjectProtocol?

    /// - Parameters:
    ///   - next: fruehester naechster faelliger Zeitpunkt (`ContainerManager.nextAutomaticSync`)
    ///   - tick: Regel fragen und starten, was faellig ist
    init(next: @escaping @MainActor (Date) -> Date, tick: @escaping @MainActor (Date) async -> Void) {
        self.next = next
        self.tick = tick
    }

    var isActive: Bool { task != nil }

    func start() {
        guard task == nil else { return }
        if MacBackgroundTicker.isMac {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                             reason: "StudiNow gleicht zweimal am Tag ab, die Uni-Mail zwischen 8 und 18 Uhr alle 30 Minuten")
        }
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = self.sleep
                let delay = self.heldSince != nil ? Self.holdPoll : Self.delay(next: self.next(self.now()), now: self.now())
                guard await wait(delay), !Task.isCancelled, self.task != nil else { return }
                await self.fire()
            }
        }
    }

    /// Ein Takt: faellig und kein Aufschub → `tick`
    func fire() async {
        let now = self.now()
        guard next(now) <= now else { return }
        if Self.holds(editing: editing(), heldSince: heldSince, now: now) {
            if heldSince == nil { heldSince = now }
            return
        }
        heldSince = nil
        await tick(now)
    }

    func stop() {
        task?.cancel()
        task = nil
        heldSince = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}

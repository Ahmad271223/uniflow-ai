import Foundation
import UniFlowCore
import WebKit

// Bescheinigungen auf dem iPad (06.11.2026, docs/BESCHEINIGUNGEN-2026-11-06.md): die duenne Schicht ueber dem Kern
// (`CertificatesSync`). Liste lesen und Herunterladen mit der Sitzung der Webansicht des Containers (nie ein Passwort):
// - LUH: QIS-Sitzung von `QISConnection` (Menue "Meine Bescheinigungen", PDF-Notenspiegel)
// - HsH: Campusmanagement-Sitzung von `HsHConnection` (Studienservice, Berichtsknoepfe mit Hintergrundauftrag)
// - Uni Hildesheim: PLuS (HISinOne) mit eigener Anmeldung im Datenspeicher von `HildesheimConnection`; das LSF hat keine
//   Bescheinigungen
// Reihenfolge (docs/SYNC-REIHENFOLGE-2026-11-05.md): nichts davon laeuft im Abgleich. Die Liste liest die Seite
// Bescheinigungen beim Oeffnen, wenn sie aelter als 7 Tage ist (nur Links, erzeugt nichts), und auf "Liste aktualisieren";
// eine PDF nur auf "Herunterladen" bzw. "Neu laden" (jeder Abruf erzeugt im Portal ein Dokument).

@MainActor
final class CertificateCenter: ObservableObject {
    enum Portal {
        case qis(QISConnection)
        case hsh(HsHConnection)
        case plus(HildesheimConnection)
    }

    let portal: Portal
    /// laufender Abruf: "list" oder die Kennung eines Dokuments
    @Published private(set) var busy: String?
    /// Sitzung abgelaufen bzw. noch nie angemeldet: "Anmeldung nötig" mit dem Anmeldefenster des Portals
    @Published var needsLogin = false
    @Published private(set) var message: String?
    /// zaehlt jeden beendeten Abruf (die Seite laedt danach neu)
    @Published private(set) var finished = 0

    /// Liste von selbst neu lesen, wenn sie aelter ist (beim Oeffnen der Seite)
    static let staleAfter: TimeInterval = 7 * 24 * 3600

    init(portal: Portal) { self.portal = portal }

    /// Portal des offenen Containers; nil ohne Hochschulverbindung (eigener Server, Demo ohne Container)
    static func make(qis: QISConnection?, hsh: HsHConnection?, hildesheim: HildesheimConnection?) -> CertificateCenter? {
        if let qis { return CertificateCenter(portal: .qis(qis)) }
        if let hsh { return CertificateCenter(portal: .hsh(hsh)) }
        if let hildesheim { return CertificateCenter(portal: .plus(hildesheim)) }
        return nil
    }

    var university: UniversityKey {
        switch portal {
        case .qis: return .luh
        case .hsh: return .hsh
        case .plus: return .hildesheim
        }
    }

    var portalName: String { CertificatePortal.name(university) }

    /// Ohne Anmeldung gar nicht erst anfragen (QIS bzw. Campusmanagement nie verbunden); PLuS wird versucht
    var isConnected: Bool {
        switch portal {
        case .qis(let q): return q.isConnected && q.state != .needsLogin
        case .hsh(let h): return h.isConnected(.campus) && h.state(.campus) != .needsLogin
        case .plus: return true
        }
    }

    /// laeuft gerade der Abgleich derselben Sitzung? Dann warten (kein zweiter Weg durch dieselben Seiten)
    var portalBusy: Bool {
        switch portal {
        case .qis(let q): return q.isRunning
        case .hsh(let h): return h.isRunning
        case .plus: return false
        }
    }

    private var host: LocalBackendHost {
        switch portal {
        case .qis(let q): return q.certificateHost
        case .hsh(let h): return h.certificateHost
        case .plus(let l): return l.certificateHost
        }
    }

    private var clock: UniFlowClock {
        switch portal {
        case .qis(let q): return q.certificateClock
        case .hsh(let h): return h.certificateClock
        case .plus(let l): return l.certificateClock
        }
    }

    private func transport() async -> UniTransport {
        switch portal {
        case .qis(let q): return await q.certificateTransport()
        case .hsh(let h): return await h.certificateTransport()
        case .plus(let l): return await l.certificateTransport()
        }
    }

    private func expired() {
        needsLogin = true
        switch portal {
        case .qis(let q): q.certificatesExpired()
        case .hsh(let h): h.certificatesExpired()
        case .plus: break
        }
    }

    /// Soll die Seite beim Oeffnen die Liste lesen? Nie gelesen oder aelter als 7 Tage, verbunden, nicht im Abgleich
    func shouldRefresh(status: String?, checkedAt: String?, now: Date = Date()) -> Bool {
        guard isConnected, !portalBusy, busy == nil, status != "login" else { return false }
        guard let checkedAt, let d = Fmt.date(checkedAt) else { return true }
        return now.timeIntervalSince(d) >= Self.staleAfter
    }

    /// Liste der Dokumente neu lesen (nur Links/Knoepfe, erzeugt nichts)
    @discardableResult
    func refresh() async -> CertificatesSync.Report? {
        guard busy == nil else { return nil }
        if await host.demoActive() { message = "Im Demo-Modus fragt StudiNow kein Portal an."; return nil }
        busy = "list"
        defer { busy = nil; finished += 1 }
        let t = await transport()
        do {
            let db = try await host.backend().context.database
            let r = await CertificatesSync.refresh(db: db, transport: t, clock: clock)
            if r.needsLogin { expired() } else if r.ok { needsLogin = false }
            if !r.cancelled { message = r.message }
            return r
        } catch {
            message = LocalBackendHost.message(for: error)
            return nil
        }
    }

    /// Ein Dokument laden und speichern; Rueckgabe: die gespeicherte PDF (fuer die Vorschau)
    func download(_ id: String, semester: String? = nil) async -> URL? {
        guard busy == nil else { return nil }
        if await host.demoActive() { message = "Im Demo-Modus fragt StudiNow kein Portal an."; return nil }
        busy = id
        defer { busy = nil; finished += 1 }
        let t = await transport()
        do {
            let backend = try await host.backend()
            guard let files = backend.context.files else { message = "Auf diesem Gerät gibt es keinen Speicherort für Dateien."; return nil }
            let r = await CertificatesSync.download(db: backend.context.database, files: files, transport: t, offerID: id, semester: semester, clock: clock)
            if r.needsLogin { expired() } else if r.ok { needsLogin = false }
            if !r.cancelled { message = r.message }
            return r.file
        } catch {
            message = LocalBackendHost.message(for: error)
            return nil
        }
    }

    /// Nach der Anmeldung im Fenster: gleich die Liste lesen
    func signedIn() {
        needsLogin = false
        Task { await refresh() }
    }
}

/// Anmeldung im PLuS der Uni Hildesheim ("Anmelden mit Single Sign-On" -> CAS, fragt erneut nach dem Passwort): auf
/// der echten Seite im Datenspeicher des Containers; fertig, sobald eine PLuS-Seite mit Abmelden-Link erscheint. Die App
/// fuellt kein Passwort ein und speichert keins.
enum PLuSLogin {
    static let host = CertificatePortal.plusBase.host?.lowercased() ?? "plus.uni-hildesheim.de"

    static func isSignedIn(html: String, url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.host?.lowercased() == host else { return false }
        return html.contains("category=auth.logout")
    }
}

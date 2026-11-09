import XCTest
import UniFlowCore
@testable import UniFlow

/// Externe Review-Liste, Nr. 26 (docs/audit/LISTE-95-2026-11-09.md): `UFTrialRecordStore` schrieb den Beginn der Probe,
/// die Geraete-Marke und „Ende gesehen“ mit `try?` in den Schluesselbund. Lehnte der Schluesselbund das Schreiben ab
/// (z. B. fehlende Berechtigung, unsignierter Build, Schutzklasse), war ohne iCloud nichts gespeichert: jeder Wechsel in
/// den Vordergrund (`Entitlements.refreshLocalTrial` ruft `UFLocalTrial.begin` erneut) und jeder Start begann die Probe
/// neu - das Geraet bekam beliebig viele Proben. Jetzt: Ersatzablage in den UserDefaults, nur wenn das Schreiben scheitert.
@MainActor
final class Liste95AppTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private func day(_ n: Double) -> Date { t0.addingTimeInterval(n * 86_400) }

    /// Schluesselbund, der jedes Schreiben ablehnt (ungueltige Schutzklasse: SecItemAdd meldet einen Fehler)
    private func refusingKeychain(_ service: String) -> KeychainStore {
        KeychainStore(service: service, accessible: "uniflow.ungueltig" as CFString)
    }

    func testNr26TrialDoesNotStartAgainWhenTheKeychainRefusesToWrite() throws {
        let service = "de.uniflow.ai.trial.l95.\(UUID().uuidString)"
        let keychain = refusingKeychain(service)
        let device = refusingKeychain(service + ".device")
        XCTAssertThrowsError(try keychain.write("x", account: "probe"), "Voraussetzung: dieser Schluesselbund schreibt nicht")
        let suite = "uniflow.tests.l95.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let store = UFTrialRecordStore(keychain: keychain, deviceKeychain: device, cloud: nil, defaults: defaults)
        let scope = UFLocalTrial.scope(userID: "001234.l95.\(UUID().uuidString.prefix(8))")

        let first = UFLocalTrial.begin(scope: scope, records: store, now: t0)
        XCTAssertTrue(first.isActive)
        XCTAssertEqual(first.startedAt, t0)
        // Vordergrund am 8. Tag: vorbei - vorher begann hier eine neue Probe mit Beginn "jetzt"
        let later = UFLocalTrial.begin(scope: scope, records: store, now: day(8))
        XCTAssertFalse(later.isActive, "keine zweite Probe, wenn der Schluesselbund nicht schreibt")
        XCTAssertEqual(later.startedAt, t0)
        // Neustart der App (neue Ablage, dieselben UserDefaults): bleibt vorbei
        let restarted = UFTrialRecordStore(keychain: keychain, deviceKeychain: device, cloud: nil, defaults: defaults)
        XCTAssertFalse(UFLocalTrial.begin(scope: scope, records: restarted, now: day(9)).isActive)
        // Uhr zurueckgestellt: "Ende gesehen" hat ebenfalls einen Ersatz
        XCTAssertFalse(UFLocalTrial.begin(scope: scope, records: restarted, now: day(2)).isActive)
        // eine weitere Apple-ID auf demselben iPad: die Geraete-Marke gilt auch ohne Schluesselbund
        let other = UFLocalTrial.begin(scope: UFLocalTrial.scope(userID: "001234.l95.andere"), records: restarted, now: day(9))
        XCTAssertTrue(other.deviceUsed)
        XCTAssertFalse(other.isActive)
        // "Bei Free bleiben" ebenso
        restarted.markChoice(scope)
        XCTAssertTrue(UFTrialRecordStore(keychain: keychain, deviceKeychain: device, cloud: nil, defaults: defaults).load(scope).choiceMade)
    }

    /// Mit funktionierendem Schluesselbund bleibt alles wie bisher: keine Eintraege in den UserDefaults
    func testNr26WorkingKeychainWritesNoFallback() throws {
        let store = UFTrialRecordStore(keychain: KeychainStore(service: "de.uniflow.ai.trial.l95ok.\(UUID().uuidString)"), cloud: nil,
                                       defaults: try XCTUnwrap(UserDefaults(suiteName: "uniflow.tests.l95ok.\(UUID().uuidString)")))
        let scope = UFLocalTrial.scope(userID: "001234.l95ok.\(UUID().uuidString.prefix(8))")
        addTeardownBlock { store.remove(scope); store.keychain.removeAll(); store.removeDeviceMark() }
        UFLocalTrial.begin(scope: scope, records: store, now: t0)
        XCTAssertEqual(store.load(scope).keychain, t0, "Schluesselbund nicht beschreibbar – App mit Signatur bauen")
        XCTAssertTrue(store.defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("uniflow.trial.fallback.") }.isEmpty)
    }
}

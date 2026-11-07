import XCTest
import UniFlowCore
@testable import UniFlow

/// Probe des StudiNow-Kontos (docs/ABO-SYSTEM.md 3a): Texte wie im Web, die Probe hebt den Tarif nur solange sie laeuft
@MainActor
final class TrialAppTests: XCTestCase {
    func testTexts() {
        XCTAssertEqual(UFTrialTexts.running(1), "Probe: noch 1 Tag alles frei")
        XCTAssertEqual(UFTrialTexts.running(7), "Probe: noch 7 Tage alles frei")
        XCTAssertEqual(UFTrialTexts.overTitle, "Deine Probe ist vorbei")
        XCTAssertEqual(UFTrialTexts.offer, "7 Tage Probe mit allem, danach Free – ohne Zahlungsdaten")
    }

    func testServiceTrialRaisesThePlanOnlyWhileItRuns() {
        let e = Entitlements.shared
        defer { e.useServiceTrial(nil) }
        let before = e.plan
        e.useServiceTrial(.proAI)
        XCTAssertEqual(e.plan, .proAI)
        e.useServiceTrial(nil)
        XCTAssertEqual(e.plan, before, "Ende der Probe: zurueck zum Stand des App Store")
    }
}

/// Probe auf dem iPad ohne Dienst (Entscheidung des Inhabers vom 04.11.2026, LocalTrial.swift): Zustandsautomat mit
/// fester Uhr, Beginn aus Schluesselbund und iCloud (der fruehere gewinnt), Vorrang der Quellen, Probe-Karte und
/// Tarif-Beschriftung. Nur erfundene Apple-IDs, Ablage im Speicher; ein Test mit dem echten Schluesselbund unter
/// eigenem Schluessel.
@MainActor
final class LocalTrialTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)      // fester Beginn
    private func day(_ n: Double) -> Date { t0.addingTimeInterval(n * 86_400) }

    // MARK: Zustandsautomat

    func testStateCountsDownAndExpiresAfterSevenDays() {
        XCTAssertEqual(UFLocalTrial.days, 7)
        XCTAssertEqual(UFLocalTrial.plan, .proAI)
        let start = UFLocalTrial.state(startedAt: t0, now: t0)
        XCTAssertEqual(start, UFLocalTrial.State(startedAt: t0, endsAt: day(7), daysLeft: 7))
        XCTAssertTrue(start.isActive)
        XCTAssertFalse(start.isExpired)
        // Resttage aufgerundet wie billing.trial_info: eine Sekunde vor Tagesende zaehlt der Tag noch
        XCTAssertEqual(UFLocalTrial.state(startedAt: t0, now: day(1)).daysLeft, 6)
        XCTAssertEqual(UFLocalTrial.state(startedAt: t0, now: day(1).addingTimeInterval(-1)).daysLeft, 7)
        XCTAssertEqual(UFLocalTrial.state(startedAt: t0, now: day(6.5)).daysLeft, 1)
        XCTAssertEqual(UFLocalTrial.state(startedAt: t0, now: day(7).addingTimeInterval(-1)).daysLeft, 1)
        // genau am Ende und danach: vorbei, nie negativ
        let end = UFLocalTrial.state(startedAt: t0, now: day(7))
        XCTAssertEqual(end.daysLeft, 0)
        XCTAssertTrue(end.isExpired)
        XCTAssertFalse(end.isActive)
        XCTAssertEqual(UFLocalTrial.state(startedAt: t0, now: day(400)).daysLeft, 0)
        // Beginn in der Zukunft (Uhr eines anderen Geraets): laeuft, hoechstens 7 Tage plus Vorsprung
        XCTAssertTrue(UFLocalTrial.state(startedAt: day(1), now: t0).isActive)
    }

    func testEarliestStartWinsAcrossKeychainAndCloud() {
        // nichts bekannt: beginnt jetzt, beide Ablagen schreiben
        XCTAssertEqual(UFLocalTrial.resolve(keychain: nil, cloud: nil, now: t0),
                       UFLocalTrial.Resolution(start: t0, writeKeychain: true, writeCloud: true, isNew: true))
        // Neuinstallation: Schluesselbund kennt den Beginn, iCloud nicht -> nachtragen, nicht neu starten
        XCTAssertEqual(UFLocalTrial.resolve(keychain: t0, cloud: nil, now: day(3)),
                       UFLocalTrial.Resolution(start: t0, writeKeychain: false, writeCloud: true, isNew: false))
        // zweites iPad: iCloud kennt den Beginn -> in den Schluesselbund uebernehmen
        XCTAssertEqual(UFLocalTrial.resolve(keychain: nil, cloud: t0, now: day(10)),
                       UFLocalTrial.Resolution(start: t0, writeKeychain: true, writeCloud: false, isNew: false))
        // beide bekannt, verschieden: der fruehere gilt, der spaetere wird ueberschrieben
        XCTAssertEqual(UFLocalTrial.resolve(keychain: day(2), cloud: t0, now: day(4)),
                       UFLocalTrial.Resolution(start: t0, writeKeychain: true, writeCloud: false, isNew: false))
        XCTAssertEqual(UFLocalTrial.resolve(keychain: t0, cloud: day(2), now: day(4)),
                       UFLocalTrial.Resolution(start: t0, writeKeychain: false, writeCloud: true, isNew: false))
        // beide gleich: nichts zu schreiben
        XCTAssertEqual(UFLocalTrial.resolve(keychain: t0, cloud: t0, now: day(4)),
                       UFLocalTrial.Resolution(start: t0, writeKeychain: false, writeCloud: false, isNew: false))
    }

    func testScopeIsAHashOfTheAppleUserIDNeverTheIDItself() {
        let id = "001234.erfundene-apple-id.0815"
        let scope = UFLocalTrial.scope(userID: id)
        XCTAssertEqual(scope, DataContainerKey.userScope(id))
        XCTAssertFalse(scope.contains("erfundene"))
        XCTAssertTrue(scope.hasPrefix("u") && scope.count == 17, scope)
        XCTAssertNotEqual(scope, UFLocalTrial.scope(userID: id + "x"))
        XCTAssertEqual(UFTrialRecordStore.cloudKey(scope), "uniflow.trial." + scope)
        XCTAssertFalse(UFTrialRecordStore.cloudKey(scope).contains("erfundene"))
    }

    // MARK: Beginn festhalten

    func testBeginStartsOncePerAppleIDAndSurvivesReinstallAndSecondIPad() {
        let records = UFMemoryTrialRecords()
        let id = "001234.probe.\(UUID().uuidString.prefix(8))"
        let scope = UFLocalTrial.scope(userID: id)
        let first = UFLocalTrial.begin(userID: id, records: records, now: t0)
        XCTAssertEqual(first.daysLeft, 7)
        XCTAssertEqual(records.load(scope), UFTrialRecords(keychain: t0, cloud: t0))
        // Neuinstallation nach drei Tagen: Schluesselbund und iCloud kennen den Beginn, es bleiben 4 Tage
        XCTAssertEqual(UFLocalTrial.begin(userID: id, records: records, now: day(3)).daysLeft, 4)
        XCTAssertEqual(records.load(scope).keychain, t0, "Beginn wird nie nach hinten verschoben")
        // zweites iPad (nur iCloud kennt den Beginn) nach zehn Tagen: vorbei, Schluesselbund dort nachgetragen
        let other = UFMemoryTrialRecords(cloud: t0, scope: scope)
        let onOther = UFLocalTrial.begin(userID: id, records: other, now: day(10))
        XCTAssertTrue(onOther.isExpired)
        XCTAssertEqual(other.load(scope).keychain, t0)
        // andere Apple-ID auf demselben iPad: keine neue Probe (Geraete-Marke, 07.11.2026)
        let second = UFLocalTrial.begin(userID: id + "-andere", records: records, now: day(10))
        XCTAssertTrue(second.deviceUsed)
        XCTAssertEqual(records.load(scope).keychain, t0)
    }

    /// Je Geraet hoechstens eine Probe (Inhaber 07.11.2026): erste Probe ueberhaupt -> 7 Tage und Marke; weitere
    /// Apple-ID auf demselben iPad -> keine Probe, auch nicht am selben Tag, auch nach Neuinstallation; dieselbe Apple-ID
    /// behaelt ihre Probe; die Regel je Apple-ID (iCloud) gilt weiter
    func testOneTrialPerDevice() {
        let records = UFMemoryTrialRecords()
        let a = "001234.geraet-a.\(UUID().uuidString.prefix(8))", b = "001234.geraet-b.\(UUID().uuidString.prefix(8))"
        // erste Probe auf dem Geraet
        let first = UFLocalTrial.begin(userID: a, records: records, now: t0)
        XCTAssertEqual(first.daysLeft, 7)
        XCTAssertFalse(first.deviceUsed)
        XCTAssertEqual(records.device, t0, "Marke beim Beginn gesetzt")
        // zweite Apple-ID noch am selben Tag: keine Probe, nichts fuer sie gespeichert
        let second = UFLocalTrial.begin(userID: b, records: records, now: day(0.5))
        XCTAssertTrue(second.deviceUsed)
        XCTAssertFalse(second.isActive)
        XCTAssertEqual(records.load(UFLocalTrial.scope(userID: b)), UFTrialRecords())
        XCTAssertEqual(UFPlanPrecedence.effective(service: nil, purchased: .free, localTrial: second), .free)
        XCTAssertTrue(second.updated(now: day(1)).deviceUsed, "Tageswechsel macht daraus keine Probe")
        // Neuinstallation: Schluesselbund (Apple-ID und Marke) bleibt, UserDefaults sind leer
        let reinstalled = UFMemoryTrialRecords()
        reinstalled.records = records.records.mapValues { UFTrialRecords(keychain: $0.keychain, cloud: $0.cloud) }
        reinstalled.device = records.device
        XCTAssertTrue(UFLocalTrial.begin(userID: b, records: reinstalled, now: day(2)).deviceUsed, "keine neue Probe nach Neuinstallation")
        XCTAssertEqual(UFLocalTrial.begin(userID: a, records: reinstalled, now: day(2)).daysLeft, 5, "die erste Apple-ID behaelt ihre Probe")
        // iCloud-Regel bleibt: Apple-ID A auf einem neuen iPad -> ihr alter Beginn, Marke dort gesetzt
        let otherIPad = UFMemoryTrialRecords(cloud: t0, scope: UFLocalTrial.scope(userID: a))
        XCTAssertEqual(UFLocalTrial.begin(userID: a, records: otherIPad, now: day(3)).daysLeft, 4)
        XCTAssertEqual(otherIPad.device, t0)
        // Hinweis auf der Uebersicht
        XCTAssertEqual(UFTrialBannerContent.make(service: nil, local: second, purchased: .free, choiceMade: false), .usedOnDevice)
        XCTAssertEqual(UFTrialBannerContent.usedOnDevice.title, "Auf diesem iPad wurde die Probe schon genutzt")
        XCTAssertNil(UFTrialBannerContent.make(service: nil, local: second, purchased: .free, choiceMade: true))
        XCTAssertNil(UFTrialBannerContent.make(service: nil, local: second, purchased: .plus, choiceMade: false))
    }

    func testEntitlementsGiveNoTrialToASecondAppleIDOnTheSameDevice() {
        let records = UFMemoryTrialRecords()
        let e = Entitlements(observe: false)
        e.beginLocalTrial(userID: "001234.erste.\(UUID().uuidString.prefix(8))", records: records, now: t0)
        XCTAssertEqual(e.plan, .proAI)
        e.useLocalTrial(startedAt: nil)
        e.beginLocalTrial(userID: "001234.zweite.\(UUID().uuidString.prefix(8))", records: records, now: day(1))
        XCTAssertEqual(e.plan, .free)
        XCTAssertEqual(e.localTrial?.deviceUsed, true)
        XCTAssertNil(e.runningLocalTrial)
        e.refreshLocalTrial(now: day(2))
        XCTAssertEqual(e.plan, .free, "bleibt ohne Probe")
        XCTAssertEqual(e.statusLabel, "StudiNow Free")
    }

    func testWithoutICloudTheKeychainAloneCounts() {
        let records = UFMemoryTrialRecords()
        records.cloudAvailable = false
        let id = "001234.ohne-icloud"
        let scope = UFLocalTrial.scope(userID: id)
        UFLocalTrial.begin(userID: id, records: records, now: t0)
        XCTAssertEqual(records.load(scope), UFTrialRecords(keychain: t0, cloud: nil))
        XCTAssertEqual(UFLocalTrial.begin(userID: id, records: records, now: day(5)).daysLeft, 2)
        XCTAssertNil(records.load(scope).cloud)
    }

    /// echter Schluesselbund des Geraets (eigener Dienst, eigener Schluessel), ohne iCloud; danach aufgeraeumt
    func testDeviceStoreKeepsTheStartInTheKeychain() throws {
        let store = UFTrialRecordStore(keychain: KeychainStore(service: "de.uniflow.ai.trial.test.\(UUID().uuidString)"),
                                       cloud: nil, defaults: UserDefaults(suiteName: "uniflow.tests.trial.\(UUID().uuidString)")!)
        let scope = UFLocalTrial.scope(userID: "001234.schluesselbund.\(UUID().uuidString.prefix(8))")
        addTeardownBlock { store.remove(scope); store.keychain.removeAll(); store.removeDeviceMark() }
        XCTAssertEqual(store.load(scope), UFTrialRecords())
        store.save(start: t0, scope: scope, keychain: true, cloud: true)
        let loaded = store.load(scope)
        XCTAssertEqual(loaded.keychain, t0, "Schluesselbund nicht beschreibbar – App mit Signatur bauen")
        XCTAssertNil(loaded.cloud, "ohne iCloud kein Eintrag dort")
        XCTAssertFalse(loaded.choiceMade)
        store.markChoice(scope)
        XCTAssertTrue(store.load(scope).choiceMade)
        // nur dieses Geraet, nie synchronisiert (wie alle Eintraege der App)
        let attrs = try XCTUnwrap(store.keychain.attributes(scope))
        XCTAssertEqual(attrs.accessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(attrs.synchronizable, false)
        // Geraete-Marke: eigener Dienst, an keiner Apple-ID, nur dieses Geraet, nicht synchronisiert
        XCTAssertNil(store.deviceTrialStart())
        store.markDeviceTrial(start: t0)
        XCTAssertEqual(store.deviceTrialStart(), t0)
        XCTAssertEqual(store.deviceKeychain.service, store.keychain.service + ".device")
        let mark = try XCTUnwrap(store.deviceKeychain.attributes(UFTrialRecordStore.deviceAccount))
        XCTAssertEqual(mark.accessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(mark.synchronizable, false)
        // neue Instanz (wie nach Neuinstallation) liest dieselbe Marke
        XCTAssertEqual(UFTrialRecordStore(keychain: store.keychain, cloud: nil, defaults: store.defaults).deviceTrialStart(), t0)
    }

    // MARK: Vorrang der Quellen

    func testPrecedenceServiceBeforeStoreBeforeLocalTrialBeforeFree() {
        let running = UFLocalTrial.state(startedAt: t0, now: day(2))
        let over = UFLocalTrial.state(startedAt: t0, now: day(9))
        XCTAssertEqual(UFPlanPrecedence.effective(service: nil, purchased: .free, localTrial: nil), .free)
        XCTAssertEqual(UFPlanPrecedence.effective(service: nil, purchased: .free, localTrial: running), .proAI, "Probe: alles wie Pro AI")
        XCTAssertEqual(UFPlanPrecedence.effective(service: nil, purchased: .free, localTrial: over), .free, "danach Free")
        XCTAssertEqual(UFPlanPrecedence.effective(service: nil, purchased: .plus, localTrial: running), .plus, "Plus gekauft gibt Plus")
        XCTAssertEqual(UFPlanPrecedence.effective(service: nil, purchased: .plus, localTrial: over), .plus)
        XCTAssertEqual(UFPlanPrecedence.effective(service: nil, purchased: .proAI, localTrial: over), .proAI, "Pro AI gekauft gibt Pro AI")
        XCTAssertEqual(UFPlanPrecedence.effective(service: .proAI, purchased: .plus, localTrial: over), .proAI, "Probe des Kontos hat Vorrang")
        XCTAssertEqual(UFPlanPrecedence.effective(service: .free, purchased: .plus, localTrial: nil), .plus, "Dienst ohne Probe aendert nichts")
    }

    func testEntitlementsApplyTheLocalTrialAndDropItAtTheEnd() {
        let e = Entitlements(observe: false)
        XCTAssertNil(e.localTrial)
        XCTAssertEqual(e.plan, .free)
        let records = UFMemoryTrialRecords()
        let id = "001234.entitlements.\(UUID().uuidString.prefix(8))"
        e.beginLocalTrial(userID: id, records: records, now: t0)
        XCTAssertEqual(e.localTrial?.daysLeft, 7)
        XCTAssertEqual(e.plan, .proAI)
        XCTAssertEqual(e.purchasedPlan, .free)
        XCTAssertTrue(e.allows(.pencilWriting) && e.allows(.flashcards) && e.allows(.shareSolutions))
        XCTAssertEqual(e.statusLabel, "Probe: noch 7 Tage alles frei")
        XCTAssertFalse(e.localTrialChoiceMade)
        // Tageswechsel
        e.refreshLocalTrial(now: day(6.2))
        XCTAssertEqual(e.localTrial?.daysLeft, 1)
        XCTAssertEqual(e.plan, .proAI)
        // Ende: Free, Sperren zeigen "Jetzt freischalten" (UFLockedCard), Notizen bleiben lesbar
        e.refreshLocalTrial(now: day(7))
        XCTAssertEqual(e.localTrial?.daysLeft, 0)
        XCTAssertEqual(e.plan, .free)
        XCTAssertEqual(e.access(.pencilWriting), .locked(.plus))
        XCTAssertEqual(e.notes, UFNoteAccess(canView: true, canExport: true, canEdit: false))
        XCTAssertEqual(e.statusLabel, "StudiNow Free")
        // "Bei Free bleiben" merkt sich die Antwort in der Ablage
        e.stayOnFreeAfterLocalTrial()
        XCTAssertTrue(e.localTrialChoiceMade)
        XCTAssertTrue(records.load(UFLocalTrial.scope(userID: id)).choiceMade)
        // erneute Anmeldung derselben Apple-ID: Probe bleibt vorbei, Antwort bleibt
        e.beginLocalTrial(userID: id, records: records, now: day(20))
        XCTAssertEqual(e.plan, .free)
        XCTAssertTrue(e.localTrialChoiceMade)
        // Abmeldung: kein Stand mehr
        e.useLocalTrial(startedAt: nil)
        XCTAssertNil(e.localTrial)
        XCTAssertFalse(e.localTrialChoiceMade)
        XCTAssertEqual(e.plan, .free)
    }

    func testServiceTrialKeepsPriorityOverTheLocalTrial() {
        let e = Entitlements(observe: false)
        e.useLocalTrial(startedAt: t0, now: day(9))                     // iPad-Probe vorbei
        XCTAssertEqual(e.plan, .free)
        e.useServiceTrial(.proAI)                                       // Konto beim Dienst: dessen Probe laeuft
        XCTAssertEqual(e.plan, .proAI)
        XCTAssertEqual(e.statusLabel, "StudiNow Pro AI", "Dienst-Probe: keine iPad-Beschriftung")
        e.useServiceTrial(nil)
        XCTAssertEqual(e.plan, .free)
    }

    // MARK: Probe-Karte auf der Uebersicht

    func testBannerContentServiceFirstThenDeviceOnlyWithoutPurchase() {
        let running = UFLocalTrial.state(startedAt: t0, now: day(4))
        let over = UFLocalTrial.state(startedAt: t0, now: day(9))
        // Dienst hat Vorrang, auch wenn die iPad-Probe etwas anderes sagt
        let serviceRunning = StudoraAccount.PlanStatus(plan: "pro_ai", trialActive: true, trialDaysLeft: 2, trialPlan: "pro_ai")
        XCTAssertEqual(UFTrialBannerContent.make(service: serviceRunning, local: over, purchased: .free, choiceMade: false),
                       .running(daysLeft: 2, source: .service))
        let serviceOver = StudoraAccount.PlanStatus(plan: "free", needsPlanChoice: true)
        XCTAssertEqual(UFTrialBannerContent.make(service: serviceOver, local: running, purchased: .free, choiceMade: false),
                       .over(source: .service))
        XCTAssertNil(UFTrialBannerContent.make(service: StudoraAccount.PlanStatus(plan: "plus"), local: running, purchased: .free, choiceMade: false),
                     "Konto mit Tarif: keine Karte")
        // ohne Dienst: iPad-Probe
        XCTAssertNil(UFTrialBannerContent.make(service: nil, local: nil, purchased: .free, choiceMade: false))
        XCTAssertEqual(UFTrialBannerContent.make(service: nil, local: running, purchased: .free, choiceMade: false),
                       .running(daysLeft: 3, source: .device))
        XCTAssertEqual(UFTrialBannerContent.make(service: nil, local: over, purchased: .free, choiceMade: false), .over(source: .device))
        XCTAssertNil(UFTrialBannerContent.make(service: nil, local: over, purchased: .free, choiceMade: true), "Bei Free bleiben beantwortet")
        XCTAssertNil(UFTrialBannerContent.make(service: nil, local: running, purchased: .plus, choiceMade: false), "gekauft: keine Probe-Karte")
        XCTAssertNil(UFTrialBannerContent.make(service: nil, local: over, purchased: .proAI, choiceMade: false))
        // Texte
        let r = UFTrialBannerContent.running(daysLeft: 3, source: .device)
        XCTAssertTrue(r.isRunning)
        XCTAssertEqual(r.title, "Probe: noch 3 Tage alles frei")
        XCTAssertEqual(r.text, UFTrialTexts.runningText)
        let o = UFTrialBannerContent.over(source: .device)
        XCTAssertFalse(o.isRunning)
        XCTAssertEqual(o.title, "Deine Probe ist vorbei")
        XCTAssertEqual(o.text, UFTrialTexts.overText)
        XCTAssertTrue(o.text.contains("bleib bei Free"), "Free bleibt nutzbar")
    }
}

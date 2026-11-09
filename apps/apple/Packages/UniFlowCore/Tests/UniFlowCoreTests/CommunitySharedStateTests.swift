import XCTest
@testable import UniFlowCore

/// Paritaet iPad <-> Mac (09.11.2026, docs/paritaet/COMMUNITY-UND-ABGLEICH-2026-11-09.md, Abschnitt Mac): dieselbe
/// App ("Designed for iPad") mit derselben Apple-ID auf zwei Geraeten. Jedes Geraet hat eigene UserDefaults, beide
/// teilen den iCloud-Schluessel-Wert-Speicher (hier `SharedKV`). Bis Build 28 lagen Beitritte, Lerngruppen, Pseudonym
/// und der Zustand der Korrekturhinweise nur in den UserDefaults: der Mac sah davon nichts.
final class CommunitySharedStateTests: XCTestCase {

    /// Nachbau von NSUbiquitousKeyValueStore: ein Speicher fuer beide Geraete (sofort "synchronisiert")
    final class SharedKV: UbiquitousValueStore {
        var values: [String: Any] = [:]
        var syncs = 0
        func object(forKey key: String) -> Any? { values[key] }
        func set(_ value: Any?, forKey key: String) { values[key] = value }
        func removeObject(forKey key: String) { values.removeValue(forKey: key) }
        func synchronize() -> Bool { syncs += 1; return true }
    }

    private var suites: [String] = []

    private func defaults() -> UserDefaults {
        let name = "test.shared-state." + UUID().uuidString
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    override func tearDown() {
        for s in suites { UserDefaults(suiteName: s)?.removePersistentDomain(forName: s) }
        suites = []
        super.tearDown()
    }

    /// Container (Nutzer, Hochschule): auf iPad und Mac dieselbe Kennung, weil sie nur aus Apple-Nutzer und Hochschule entsteht
    private let container = DataContainerKey(userID: "001234.apple-nutzer.0001", university: .luh).identifier

    private func devices(_ kv: SharedKV) -> (ipad: CommunitySharedState, mac: CommunitySharedState) {
        (CommunitySharedState(defaults: defaults(), cloud: kv, scope: container),
         CommunitySharedState(defaults: defaults(), cloud: kv, scope: container))
    }

    // MARK: Der Befund (bis Build 28): UserDefaults allein reichen nicht

    func testDeviceDefaultsAloneDoNotReachTheMac() {
        let ipad = CommunityCorrectionStatusStore(defaults: defaults())
        let mac = CommunityCorrectionStatusStore(defaults: defaults())
        ipad.set(.seen, id: "K1")
        XCTAssertEqual(mac.status(id: "k1"), .open, "so war es: auf dem Mac zaehlte der gesehene Hinweis wieder im Abzeichen")
    }

    // MARK: Beitritte, Lerngruppen, Sperrliste, Pseudonym

    func testIPadStateIsSeenOnTheMac() {
        let kv = SharedKV()
        let (ipad, mac) = devices(kv)
        ipad.set(["kurs-a", "kurs-b"], forKey: "uniflow.community.joined")
        ipad.set([["code": "ABCD2345", "name": "Lernrunde", "university": "luh"]], forKey: "uniflow.community.groups")
        ipad.set(["owner-x"], forKey: "uniflow.community.blocked")
        ipad.set("Erika", forKey: "uniflow.solution.displayName")
        XCTAssertEqual(mac.stringArray(forKey: "uniflow.community.joined"), ["kurs-a", "kurs-b"])
        XCTAssertEqual((mac.array(forKey: "uniflow.community.groups") as? [[String: String]])?.first?["code"], "ABCD2345")
        XCTAssertEqual(mac.stringArray(forKey: "uniflow.community.blocked"), ["owner-x"])
        XCTAssertEqual(mac.string(forKey: "uniflow.solution.displayName"), "Erika", "sonst schreibt der Mac als \"Anonym\"")
        XCTAssertGreaterThan(kv.syncs, 0, "jede Aenderung stoesst den Abgleich an")
    }

    func testExistingIPadDataIsTakenAlongOnFirstRead() {
        let kv = SharedKV()
        let ipadDefaults = defaults()
        ipadDefaults.set(["kurs-alt"], forKey: "uniflow.community.joined")              // Bestand aus Build 28
        ipadDefaults.set("Ben", forKey: "uniflow.solution.displayName")
        let ipad = CommunitySharedState(defaults: ipadDefaults, cloud: kv, scope: container)
        let mac = CommunitySharedState(defaults: defaults(), cloud: kv, scope: container)
        XCTAssertNil(mac.stringArray(forKey: "uniflow.community.joined"), "noch hat das iPad nichts gespiegelt")
        XCTAssertEqual(ipad.stringArray(forKey: "uniflow.community.joined"), ["kurs-alt"])
        XCTAssertEqual(ipad.string(forKey: "uniflow.solution.displayName"), "Ben")
        XCTAssertEqual(mac.stringArray(forKey: "uniflow.community.joined"), ["kurs-alt"])
        XCTAssertEqual(mac.string(forKey: "uniflow.solution.displayName"), "Ben")
    }

    func testLeavingOnTheMacDoesNotComeBackFromTheIPad() {
        let kv = SharedKV()
        let (ipad, mac) = devices(kv)
        ipad.set(["kurs-a"], forKey: "uniflow.community.joined")
        XCTAssertEqual(mac.stringArray(forKey: "uniflow.community.joined"), ["kurs-a"])
        mac.set([String](), forKey: "uniflow.community.joined")
        XCTAssertEqual(ipad.stringArray(forKey: "uniflow.community.joined"), [], "der lokale Stand des iPads stellt den Beitritt nicht wieder her")
    }

    func testOtherContainerAndLocalOnlyKeysStaySeparate() {
        let kv = SharedKV()
        let other = DataContainerKey(userID: "001234.apple-nutzer.0001", university: .hildesheim).identifier
        let luh = CommunitySharedState(defaults: defaults(), cloud: kv, scope: container)
        let hil = CommunitySharedState(defaults: defaults(), cloud: kv, scope: other)
        luh.set(["kurs-a"], forKey: "uniflow.community.joined")
        XCTAssertNil(hil.stringArray(forKey: "uniflow.community.joined"), "andere Hochschule = anderer Container")
        luh.set("geheim", forKey: "uniflow.etwas.anderes")
        XCTAssertFalse(kv.values.values.contains { ($0 as? String) == "geheim" }, "nur die Community-Schluessel gehen nach iCloud")
        for key in CommunitySharedState.shortKeys.keys {
            XCTAssertLessThanOrEqual(luh.cloudKey(key)!.utf8.count, CommunitySharedState.maxKeyBytes, key)
        }
    }

    func testWithoutICloudItBehavesLikeBefore() {
        let d = defaults()
        let s = CommunitySharedState(defaults: d, cloud: nil, scope: container)
        s.set(["kurs-a"], forKey: "uniflow.community.joined")
        XCTAssertEqual(d.stringArray(forKey: "uniflow.community.joined"), ["kurs-a"])
        XCTAssertEqual(s.stringArray(forKey: "uniflow.community.joined"), ["kurs-a"])
        XCTAssertFalse(s.isMirrored)
    }

    func testICloudValueIsKeptLocallyForOfflineUse() {
        let kv = SharedKV()
        let (ipad, _) = devices(kv)
        let macDefaults = defaults()
        let mac = CommunitySharedState(defaults: macDefaults, cloud: kv, scope: container)
        ipad.set(["kurs-a"], forKey: "uniflow.community.joined")
        _ = mac.stringArray(forKey: "uniflow.community.joined")
        XCTAssertEqual(macDefaults.stringArray(forKey: "uniflow.community.joined"), ["kurs-a"])
        let offline = CommunitySharedState(defaults: macDefaults, cloud: nil, scope: container)
        XCTAssertEqual(offline.stringArray(forKey: "uniflow.community.joined"), ["kurs-a"])
    }

    // MARK: Korrekturhinweise: Abzeichen auf beiden Geraeten gleich

    func testCorrectionStatusIsTheSameOnIPadAndMac() {
        let kv = SharedKV()
        let (ipadState, macState) = devices(kv)
        let ipad = CommunityCorrectionStatusStore(defaults: nil, state: ipadState)
        let mac = CommunityCorrectionStatusStore(defaults: nil, state: macState)
        ipad.set(.seen, id: "K1")
        mac.set(.ignored, id: "k2")
        XCTAssertEqual(mac.status(id: "k1"), .seen)
        XCTAssertEqual(ipad.status(id: "K2"), .ignored)
        func inbox(_ store: CommunityCorrectionStatusStore) -> [CommunityCorrection] {
            ["k1", "k2", "k3"].map { id in
                var c = CommunityCorrection(id: id, targetSolutionID: "s", pseudonym: "Ben", createdAt: "2026-11-09T10:00:00Z", note: "x", pages: [])
                c.isForMe = true
                c.status = store.status(id: id)
                return c
            }
        }
        XCTAssertEqual(CommunityCorrections.openInbox(inbox(ipad)).map(\.id), ["k3"])
        XCTAssertEqual(CommunityCorrections.openInbox(inbox(mac)).map(\.id), ["k3"], "Zahl am Menuepunkt Community gleich")
        mac.set(.open, id: "k1")
        XCTAssertEqual(ipad.status(id: "k1"), .open)
    }

    // MARK: Geraet beim StudiNow-Konto

    func testMacIsNamedMacInTheAccountDeviceList() {
        XCTAssertEqual(AccountDevice.name(systemName: "iPad", model: "iPad", isMac: true), "Mac")
        XCTAssertEqual(AccountDevice.name(systemName: "", model: "iPad", isMac: true), "Mac")
        XCTAssertEqual(AccountDevice.name(systemName: "MacBook von Ahmad", model: "iPad", isMac: true), "MacBook von Ahmad")
        XCTAssertEqual(AccountDevice.name(systemName: "iPad", model: "iPad", isMac: false), "iPad")
        XCTAssertEqual(AccountDevice.idPrefix(isMac: true), "mac-")
        XCTAssertEqual(AccountDevice.idPrefix(isMac: false), "ipad-")
        XCTAssertEqual(AccountDevice.systemLabel(version: "26.1", isMac: false), "iPadOS 26.1")
        XCTAssertTrue(AccountDevice.systemLabel(version: "26.1", isMac: true).hasPrefix("macOS"))
    }
}

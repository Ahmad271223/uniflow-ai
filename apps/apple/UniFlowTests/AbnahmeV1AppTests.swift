import Security
import UniFlowCore
import XCTest
@testable import UniFlow

/// Abnahme V1: Texte und Regeln, die ohne PC (lokales Backend) gelten, Info.plist/Datenschutz-Manifest des Bundles,
/// Schluesselbund, Teilen-Ordner je Container und voller Speicher
final class AbnahmeV1AppTests: XCTestCase {

    // MARK: Stundenplan

    func testTimetableHintOnlyPromisesStudIPDatesWhenThereAreSome() {
        XCTAssertTrue(TimetableView.emptyHint(studipPending: 3).contains("haben bereits Termine"))
        let none = TimetableView.emptyHint(studipPending: 0)
        XCTAssertFalse(none.contains("haben bereits Termine"))
        XCTAssertTrue(none.contains("nächsten Abgleich"))
    }

    func testTimetableImportOffersNoAIWaysOnTheDevice() {
        let local = TimetableImportDialog.sources(local: true, offersStudIP: true).map(\.id)
        XCTAssertEqual(local, ["studip", "ics", "manual"])
        XCTAssertEqual(TimetableImportDialog.sources(local: true, offersStudIP: false).map(\.id), ["ics", "manual"])
        XCTAssertEqual(TimetableImportDialog.sources(local: true, offersStudIP: false).first { $0.primary }?.id, "ics")
        XCTAssertEqual(TimetableImportDialog.sources(local: false, offersStudIP: true).map(\.id),
                       ["studip", "ics", "pdf", "image", "text", "manual"])
        XCTAssertFalse(TimetableImport.waitText("ics").contains("KI"))
        XCTAssertTrue(TimetableImport.waitText("pdf").contains("KI"))
    }

    func testEventSourceIsReadable() {
        XCTAssertEqual(EventDrawer.sourceText("lsf-auto"), "aus dem LSF")
        XCTAssertEqual(EventDrawer.sourceText("studip"), "aus Stud.IP")
        XCTAssertEqual(EventDrawer.sourceText("manual"), "eigener Termin")
        XCTAssertNil(EventDrawer.sourceText(nil))
    }

    // MARK: Navigation, Texte

    func testSidebarShowsOnlyAreasWithAFunctionOnTheDevice() {
        let without = UFNavItem.visible(local: true, gradesOnDevice: false, community: false).map(\.id)
        XCTAssertEqual(without, ["dashboard", "plan", "timetable", "modules", "files", "cards"])
        let both = UFNavItem.visible(local: true, gradesOnDevice: true, community: false).map(\.id)
        XCTAssertEqual(both, ["dashboard", "plan", "timetable", "modules", "files", "cards", "services"], "Notenspiegel aus QIS (LUH) bzw. LSF (Hildesheim)")
        // Community nur mit CloudKit-Dienst im Build (iCloud-Container)
        let withCloud = UFNavItem.visible(local: true, gradesOnDevice: true, community: true).map(\.id)
        XCTAssertEqual(withCloud, ["dashboard", "plan", "timetable", "modules", "files", "cards", "services", "community"])
        // eigene Karteikarten an Stelle der Wochentests (KI), ohne Funktion auf dem Geraet kein Eintrag
        XCTAssertEqual(UFNavItem.visible(local: true, gradesOnDevice: true, community: false, flashcards: false).map(\.id),
                       ["dashboard", "plan", "timetable", "modules", "files", "services"])
        XCTAssertFalse(UFNavItem.visible(local: true, gradesOnDevice: true, community: true).contains { $0.id == "exams" })
        XCTAssertEqual(UFNavItem.cards.title, "Karteikarten")
        XCTAssertTrue(UFNavItem.cards.isActive(.cards))
        XCTAssertFalse(UFNavItem.cards.isActive(.exams))
        XCTAssertTrue(UFNavItem.main.first { $0.id == "exams" }?.isActive(.cards) == true, "am eigenen Server unter Tests & Wiederholung")
        XCTAssertEqual(UFNavItem.visible(local: false, gradesOnDevice: false, community: false).map(\.id), UFNavItem.main.map(\.id), "eigener Server")
        // dieser Testlauf hat keinen Container: der Eintrag fehlt, die Einstellungen sagen ehrlich warum
        XCTAssertFalse(SolutionSharing.community.isConnected)
        XCTAssertTrue(CommunityTexts.unavailableHint.contains("kein") && CommunityTexts.unavailableHint.contains("verschlüsselte Datei"))
    }

    func testDeleteAccountMentionsPINOnlyWithOwnServer() {
        XCTAssertFalse(DeleteAccountText.removed(ownServer: false).contains("PIN"))
        XCTAssertTrue(DeleteAccountText.removed(ownServer: true).contains("Server-PIN"))
        XCTAssertTrue(DeleteAccountText.appleID.contains("Mit Apple anmelden"))
    }

    func testCommunityTextDoesNotClaimNothingIsShared() {
        let device = CommunityPage.text(onDevice: true)
        XCTAssertFalse(device.contains("nichts verlässt"))
        XCTAssertTrue(device.contains("verschlüsselte Datei"))
        XCTAssertTrue(device.contains("iCloud-Container"), "sagt, was dem Build fehlt")
        XCTAssertFalse(CommunityPage.planned(onDevice: true).contains { $0.hasPrefix("Eigene Lösungen freiwillig teilen") })
        XCTAssertFalse(CommunityPage.planned(onDevice: true).contains { $0.hasPrefix("Lösungen in der Online-Community veröffentlichen – geplant") },
                       "nicht mehr 'geplant': programmiert, nur ohne Container nicht verfuegbar")
        XCTAssertEqual(CommunityPage.howItWorks.count, 3)
        XCTAssertTrue(CommunityPage.howItWorks.contains { $0.text.contains("„Ebenen“") })
    }

    /// Empfangene Loesungen ansehen gehoert zum Lesen der Community (jeder Tarif, Entscheidung 28.10.2026); nur ohne
    /// Community im Build verspricht die Meldung nichts
    @MainActor
    func testReceivedSolutionMessageFollowsCommunityReading() {
        XCTAssertTrue(Entitlements(observe: false, plan: .free).allows(.communityRead))
        XCTAssertTrue(SolutionSharing.receivedMessage(label: "Lösung", canView: true).contains("„Ebenen“"))
        let off = SolutionSharing.receivedMessage(label: "Lösung", canView: false)
        XCTAssertFalse(off.contains("Plus"), "Lesen braucht keinen Tarif")
        XCTAssertFalse(off.contains("erscheint"))
        XCTAssertTrue(CommunityPage.howItWorks.contains { $0.text.hasPrefix("Ab \(UFPlan.plus.name)") && $0.text.contains("veröffentlichen") })
        // Free: wo man schreiben wuerde, steht der Weg zu Plus; Beitreten, Melden und Blockieren gehen ohne
        XCTAssertTrue(CommunityTexts.pseudonymPlusHint.hasSuffix("ab \(UFPlan.plus.name)."))
        XCTAssertTrue(CommunityTexts.createGroupPlusHint.contains("Beitreten geht in jedem Tarif"))
        XCTAssertTrue(CommunityTexts.reportNotice.contains("Moderation von Studora"))
    }

    func testNewFilesSourceFollowsTheUniversity() {
        XCTAssertEqual(UFSourceText.newFiles(.luh), "Neu aus \(UniversityKey.luh.profile.filesSource)")
        XCTAssertEqual(UFSourceText.newFiles(.hildesheim), "Neu aus \(UniversityKey.hildesheim.profile.filesSource)")
        XCTAssertNotEqual(UFSourceText.newFiles(.luh), UFSourceText.newFiles(.hildesheim))
    }

    // MARK: Dateien ausserhalb des Editors

    private func file(name: String, kind: String?, downloaded: Bool, pages: Int? = nil) -> LibFile {
        LibFile(id: "f1", name: name, title: nil, kind: kind, module_id: nil, subject: nil, doc_type: nil, ai_title: nil,
                sub_label: nil, downloaded_at: downloaded ? "2026-10-25" : nil, has_notes: nil, page_count: pages, studip_folder: nil)
    }

    func testOnlyLoadedPDFsAndNotebooksOpenInTheEditor() {
        XCTAssertTrue(file(name: "Blatt.pdf", kind: "pdf", downloaded: true).opensInEditor)
        XCTAssertTrue(file(name: "Blatt", kind: "pdf", downloaded: true).isPDF, "PDF ohne Endung (mime application/pdf)")
        XCTAssertFalse(file(name: "Blatt.pdf", kind: "pdf", downloaded: false).opensInEditor)
        XCTAssertFalse(file(name: "daten.pdf", kind: "file", downloaded: true).isPDF)
        XCTAssertFalse(file(name: "Daten.zip", kind: "file", downloaded: true).opensInEditor)
        XCTAssertTrue(file(name: "Foto.pdf", kind: "image", downloaded: true, pages: 1).isPDF, "Bild als PDF-Seite")
        XCTAssertFalse(file(name: "Foto.pdf", kind: "image", downloaded: true).isPDF, "Bild ohne Umwandlung")
        XCTAssertTrue(file(name: "Notizen", kind: "notebook", downloaded: false).opensInEditor)
        XCTAssertTrue(file(name: "Tafel", kind: "whiteboard", downloaded: false).opensInEditor)
        XCTAssertEqual(FileOutsideEditorView.message(for: file(name: "Daten.zip", kind: "file", downloaded: false)), DocumentOpenText.notLoaded)
        XCTAssertEqual(FileOutsideEditorView.message(for: file(name: "Daten.zip", kind: "file", downloaded: true)), DocumentOpenText.notPDF)
        XCTAssertEqual(DocumentOpenText.problem(status: 404), DocumentOpenText.notLoaded)
        XCTAssertEqual(DocumentOpenText.problem(status: 200), DocumentOpenText.notPDF)
        XCTAssertTrue(DocumentOpenText.problem(status: 500).contains("500"))
        XCTAssertEqual(APIError(status: 404, message: "{}", text: DocumentOpenText.notLoaded).errorDescription, DocumentOpenText.notLoaded)
    }

    // MARK: Anmelde-Webansicht

    func testWebLoadFailuresAreReadableAndCancelIsNone() {
        XCTAssertNil(UFWebLoadState.message(for: URLError(.cancelled)))
        XCTAssertNil(UFWebLoadState.message(for: NSError(domain: "WebKitErrorDomain", code: 102)))
        XCTAssertEqual(UFWebLoadState.message(for: URLError(.notConnectedToInternet)),
                       "Keine Internetverbindung. Prüfe WLAN oder mobile Daten und versuche es erneut.")
        XCTAssertTrue(UFWebLoadState.message(for: URLError(.timedOut))?.contains("nicht erreichbar") == true)
        XCTAssertTrue(StudIPWebView.blocksMainFrame(URL(string: "http://example.test/login")!))
        XCTAssertFalse(StudIPWebView.blocksMainFrame(URL(string: "https://example.test/login")!))
    }

    // MARK: Bundle

    func testInfoPlistHasNoArbitraryLoadsAndOnlyDebugAllowsTheLocalNetwork() throws {
        let ats = Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any]
        XCTAssertNil(ats?["NSAllowsArbitraryLoads"])
        #if DEBUG
        XCTAssertEqual(ats?["NSAllowsLocalNetworking"] as? Bool, true, "Debug: eigener Server im lokalen Netz")
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription"))
        #endif
    }

    func testPrivacyManifestIsInTheBundle() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        let types = (plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? []).compactMap { $0["NSPrivacyAccessedAPIType"] as? String }
        XCTAssertTrue(types.contains("NSPrivacyAccessedAPICategoryUserDefaults"))
        XCTAssertTrue(types.contains("NSPrivacyAccessedAPICategoryFileTimestamp"))
        XCTAssertTrue(types.contains("NSPrivacyAccessedAPICategoryDiskSpace"))
    }

    // MARK: Schluesselbund

    func testLegacyItemWithoutServiceMovesToTheAppServiceAndThisDeviceOnly() throws {
        let key = "uniflow.test.legacy.\(UUID().uuidString)"
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                  kSecValueData as String: Data("alt-123".utf8)]
        XCTAssertEqual(SecItemAdd(add as CFDictionary, nil), errSecSuccess, "Schluesselbund nicht beschreibbar (Signatur)")
        defer { Keychain.delete(key); KeychainStore.removeLegacy(account: key) }

        XCTAssertEqual(Keychain.get(key), "alt-123")
        XCTAssertNil(KeychainStore.legacyData(account: key), "alter Eintrag ohne Dienst entfernt")
        let attrs = try XCTUnwrap(Keychain.store.attributes(key))
        XCTAssertEqual(attrs.accessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertNotEqual(attrs.synchronizable, true)
        XCTAssertEqual(Keychain.get(key), "alt-123", "zweites Lesen aus dem neuen Eintrag")
    }

    // MARK: Teilen-Ordner, Speicher

    func testShareFilesLiveInTheirContainerAndGoWithIt() throws {
        let a = UUID(), b = UUID()
        defer { AppTemp.remove(container: a); AppTemp.remove(container: b) }
        let first = try AppTemp.file("download", name: "../Blatt 1.pdf", container: a)
        try Data("x".utf8).write(to: first)
        XCTAssertTrue(first.path.hasPrefix(AppTemp.folder(container: a).path + "/"))
        XCTAssertFalse(first.lastPathComponent.contains("/"))
        XCTAssertTrue(first.lastPathComponent.hasSuffix(".pdf"))
        let other = try AppTemp.file("download", name: "Blatt.pdf", container: b)
        try Data("y".utf8).write(to: other)

        let second = try AppTemp.file("download", name: "Blatt 2.pdf", container: a)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path), "neuer Export desselben Zwecks ersetzt den vorigen")
        try Data("z".utf8).write(to: second)
        AppTemp.remove(container: a)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path), "anderer Container bleibt")
    }

    func testFullStorageIsRecognisedAndExplained() {
        XCTAssertTrue(DeviceStorage.fits(10, free: nil))
        XCTAssertTrue(DeviceStorage.fits(1024, free: DeviceStorage.reserve + 1024))
        XCTAssertFalse(DeviceStorage.fits(1025, free: DeviceStorage.reserve + 1024))
        XCTAssertTrue(DeviceStorage.isFull(DeviceStorage.Full()))
        XCTAssertTrue(DeviceStorage.isFull(URLError(.cannotWriteToFile)))
        XCTAssertTrue(DeviceStorage.isFull(CocoaError(.fileWriteOutOfSpace)))
        XCTAssertTrue(DeviceStorage.isFull(SQLiteError(stage: .step, code: 13, message: "database or disk is full")))
        XCTAssertTrue(DeviceStorage.isFull(NSError(domain: NSCocoaErrorDomain, code: 512,
                                                   userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])))
        XCTAssertFalse(DeviceStorage.isFull(URLError(.timedOut)))
        XCTAssertFalse(DeviceStorage.isFull(SQLiteError(stage: .step, code: 19, message: "constraint")))
        XCTAssertEqual(LocalBackendHost.message(for: SQLiteError(stage: .step, code: 13, message: "full")), DeviceStorage.fullMessage)
        XCTAssertEqual(LocalBackendHost.message(for: SQLiteError(stage: .step, code: 1, message: "x")),
                       "Die Datenbank auf diesem iPad meldet einen Fehler (1). Versuche es erneut.")
        XCTAssertNotNil(DeviceStorage.availableBytes(at: FileManager.default.temporaryDirectory.appendingPathComponent("gibt-es-nicht/x")))
    }
}

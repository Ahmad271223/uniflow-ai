import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Anzeige beim ersten Abgleich (Auftrag des Inhabers 15.11.2026, docs/ERST-ABGLEICH-2026-11-15.md): die Leiste "Deine
/// Kurse werden geladen: 121 von 250 Dateien" und der Hinweis "Dateien werden noch geladen …" im Modul, am iPad und am
/// iPhone - nichts ragt heraus, nichts ist gequetscht (Pruefer `squeezed`). Ohne Netz und ohne Konto. Mit
/// UF_SCREENSHOT_DIR schreibt der Test die beiden Bilder fuer den Bericht.
@MainActor
final class FirstSyncViewTests: XCTestCase {
    private var window: UIWindow!

    override func setUp() async throws {
        try await super.setUp()
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
    }

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        UFCompact.phoneOverride = UniFlowTestsPrincipal.deviceDefault
        try await super.tearDown()
    }

    /// Ausschnitt einer Modulseite waehrend des ersten Abgleichs: Leiste oben, ein Modul ohne und eins mit Dateien
    private struct Sample: View {
        let progress: UFSyncProgressBar.Content

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                UFSyncProgressBar(content: progress)
                Text("Einführung in die Erziehungswissenschaft").ufFont(20, 700).foregroundStyle(UF.text)
                    .fixedSize(horizontal: false, vertical: true)
                ModulePendingRow(text: SyncPending.hint(unlisted: 1, waiting: 0) ?? "", empty: true)
                Text("Statistik I").ufFont(20, 700).foregroundStyle(UF.text)
                ModulePendingRow(text: SyncPending.hint(unlisted: 0, waiting: 5) ?? "", empty: false)
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 22.4, leading: 16, bottom: 16, trailing: 16))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(UF.bg)
        }
    }

    private func show(_ content: UFSyncProgressBar.Content, size: CGSize, phone: Bool) -> UIViewController {
        UFCompact.phoneOverride = phone
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let frame = CGRect(origin: .zero, size: size)
        window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        let hosting = UIHostingController(rootView: Sample(progress: content).environment(\.ufCompact, phone))
        hosting.traitOverrides.horizontalSizeClass = phone ? .compact : .regular
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        hosting.view.frame = window.bounds
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        hosting.view.layoutIfNeeded()
        return hosting
    }

    private func picture(_ hosting: UIViewController, _ name: String) {
        guard let path = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !path.isEmpty else { return }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let view = hosting.view!
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let data = UIGraphicsImageRenderer(bounds: view.bounds, format: format).pngData { _ in
            _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        do { try data.write(to: dir.appendingPathComponent(name)) } catch { XCTFail("\(name): \(error)") }
    }

    private let running = UFSyncProgressBar.Content.running(
        SyncProgress(step: .files, coursesDone: 14, coursesTotal: 14, filesDone: 121, filesTotal: 250, current: "Einführung in die Erziehungswissenschaft"))

    private func check(size: CGSize, phone: Bool, name: String) {
        for (content, suffix) in [(running, ""), (UFSyncProgressBar.Content.interrupted, "-unterbrochen")] {
            let hosting = show(content, size: size, phone: phone)
            let texts = LayoutWidthAuditTests.texts(hosting.view)
            XCTAssertTrue(texts.contains { $0.contains(content.title) }, "\(name)\(suffix): Titel fehlt in \(texts)")
            XCTAssertTrue(texts.contains { $0.contains("Dateien werden noch geladen …") }, "\(name)\(suffix): \(texts)")
            XCTAssertTrue(texts.contains { $0.contains("5 Dateien werden noch geladen …") }, "\(name)\(suffix): \(texts)")
            let squeezed = LayoutWidthAuditTests.squeezed(in: window)
            XCTAssertTrue(squeezed.isEmpty, "\(name)\(suffix): " + squeezed.map(\.text).joined(separator: "; "))
            // nichts ragt ueber den Rand
            for e in LayoutWidthAuditTests.elements(in: window) {
                let r = e.accessibilityFrame
                guard r.width > 2, !r.isNull, !r.isInfinite else { continue }
                XCTAssertLessThanOrEqual(r.maxX, size.width + 1, "\(name)\(suffix): „\(e.accessibilityLabel ?? "")“ ragt heraus")
            }
            picture(hosting, "erst-abgleich-\(name)\(suffix).png")
            window.isHidden = true
        }
    }

    func testIPadShowsProgressAndStillLoading() {
        check(size: CGSize(width: 1194, height: 600), phone: false, name: "ipad")
    }

    func testIPhoneShowsProgressAndStillLoading() {
        check(size: CGSize(width: 393, height: 600), phone: true, name: "iphone")
        check(size: CGSize(width: 375, height: 600), phone: true, name: "iphone-schmal")
    }

    // MARK: Texte und Zustaende (ohne Ansicht)

    func testTextsInPlainGerman() {
        XCTAssertEqual(running.title, "Deine Kurse werden geladen: 121 von 250 Dateien")
        XCTAssertEqual(running.detail, "Gerade: Einführung in die Erziehungswissenschaft")
        XCTAssertEqual(running.fraction ?? 0, 0.484, accuracy: 0.001)
        XCTAssertEqual(UFSyncProgressBar.Content.interrupted.title, "Deine Kurse sind noch nicht vollständig geladen")
        XCTAssertEqual(UFSyncProgressBar.Content.interrupted.detail, "StudiNow lädt gleich weiter.")
        XCTAssertNil(UFSyncProgressBar.Content.interrupted.fraction)
        XCTAssertEqual(SyncProgress(step: .lists, coursesDone: 5, coursesTotal: 14, filesTotal: 80).title,
                       "Deine Kurse werden geladen: 5 von 14 Kursen · bisher 80 Dateien")
        XCTAssertEqual(SyncProgress(step: .files, filesDone: 3, filesTotal: 113, older: true).title, "Frühere Semester werden geladen: 3 von 113 Dateien")
        XCTAssertEqual(SyncProgress().title, "Deine Kurse werden geladen …")
    }

    /// LUH: dieselbe Anzeige statt "Stud.IP wird abgeglichen – …"; ein unterbrochener Lauf zeigt "wird fortgesetzt",
    /// ein fertiger nichts (keine Dauerleiste)
    func testStatusBarOnlyWhileLoadingOrInterrupted() {
        let connected = UFDataMode.local(.connected)
        XCTAssertNil(UFNoServerContent.resolve(kind: .modules, mode: connected, phase: .idle).status, "fertig: keine Leiste")
        XCTAssertEqual(UFNoServerContent.resolve(kind: .modules, mode: connected, phase: .idle, interrupted: true).status, .resuming)
        XCTAssertEqual(UFNoServerContent.resolve(kind: .modules, mode: connected, phase: .running("x")).status, .syncing("x"))
        XCTAssertNil(UFNoServerContent.resolve(kind: .modules, mode: connected, phase: .needsLogin, interrupted: true).status)
        XCTAssertEqual(UFGatePresentation.resolve(spec: .modules, mode: connected, phase: .idle, interrupted: true), .pageBelowStudIPStatus)
        XCTAssertEqual(UFGatePresentation.resolve(spec: .modules, mode: connected, phase: .idle), .page)
    }

    /// Die Frage "Auch frühere Semester laden?" kommt erst, wenn das laufende Semester wirklich fertig ist
    func testOlderSemestersQuestionWaitsForTheCurrentSemester() {
        typealias Q = OlderSemestersQuestionHost
        XCTAssertTrue(Q.currentSemesterDone(studipRunning: false, studipInterrupted: false, hildesheimRunning: nil, hildesheimInterrupted: nil))
        XCTAssertFalse(Q.currentSemesterDone(studipRunning: true, studipInterrupted: false, hildesheimRunning: nil, hildesheimInterrupted: nil))
        XCTAssertFalse(Q.currentSemesterDone(studipRunning: false, studipInterrupted: true, hildesheimRunning: nil, hildesheimInterrupted: nil))
        XCTAssertFalse(Q.currentSemesterDone(studipRunning: false, studipInterrupted: false, hildesheimRunning: true, hildesheimInterrupted: false))
        XCTAssertFalse(Q.currentSemesterDone(studipRunning: false, studipInterrupted: false, hildesheimRunning: false, hildesheimInterrupted: true))
        XCTAssertTrue(Q.currentSemesterDone(studipRunning: false, studipInterrupted: false, hildesheimRunning: false, hildesheimInterrupted: false))
    }

    /// Learnweb-Datei antippen: dieselben Zustaende wie bei Stud.IP, in Worten ohne "Stud.IP"
    func testFileLoadTextsNameTheLearnweb() {
        XCTAssertEqual(FileLoadState(HildesheimSync.SingleLoad.loaded), .loaded)
        XCTAssertEqual(FileLoadState(HildesheimSync.SingleLoad.needsLogin), .needsLogin)
        XCTAssertEqual(FileLoadState(HildesheimSync.SingleLoad.failed("x")), .failed("x"))
        XCTAssertEqual(FileLoadState(HildesheimSync.SingleLoad.unknown), .otherSource)
        XCTAssertEqual(FileLoadState(nil as HildesheimSync.SingleLoad?), .otherSource)
        XCTAssertEqual(FileLoadState.needsLogin.headline(source: "Learnweb"), "Learnweb-Anmeldung nötig")
        XCTAssertTrue(FileLoadState.loading.detail(source: "Learnweb").contains("aus dem Learnweb"))
        XCTAssertFalse(FileLoadState.needsLogin.detail(source: "Learnweb").contains("Stud.IP"))
        // Stud.IP wie bisher
        XCTAssertEqual(FileLoadState.needsLogin.headline, "Stud.IP-Anmeldung nötig")
        XCTAssertTrue(FileLoadState.needsLogin.detail.hasPrefix("Melde dich unter Einstellungen → Uni-Zugang & Abgleich neu bei Stud.IP an."))
    }
}

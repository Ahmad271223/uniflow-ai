import Darwin
import SwiftUI
import UniFlowCore
import XCTest
@testable import UniFlow

/// Wache gegen zu tief geschachtelte Ansichtstypen (Absturz Build 32, 11.11.2026; iPad Pro 12,9" 2020, iPadOS 27.0.1:
/// "App spinnt, geht an aus an aus").
///
/// Befund: EXC_BAD_ACCESS im Stapel-Schutzbereich des Haupt-Threads (1 MB), ueber 150 Rahmen `decodeMangledType`/
/// `decodeGenericArgs` aus `DocumentView.body`. Jeder Modifikator schachtelt den Typ von `body` eine Ebene tiefer; die
/// Laufzeit loest diesen Typ beim ersten Zeichnen rekursiv aus seinem Namen auf, je Ebene mehrere Stapelrahmen.
///
/// Gemessen am 11.11.2026 (Simulator, Debug):
///
/// |                                         | Build 31 (lief) | Build 32 (Absturz) | jetzt                 |
/// |-----------------------------------------|-----------------|--------------------|-----------------------|
/// | Tiefe `DocumentView` (groesster Teil)   | 104             | 115                | 42 (`chrome`)         |
/// | Stapel zum Aufloesen des Typs           | 137 KB          | 151 KB             | hoechstens 70 KB      |
/// | Haupt-Thread beim ersten Zeichnen       | ~960 KB         | ~1220 KB           | ~440 KB               |
///
/// Tiefe = hoechste Zahl offener `<`/`(` im Typnamen (`metrics`). Von allen 420 Ansichten mit eigenem `body` war nur
/// `DocumentView` so tief; die naechsten: `StudyPlanPage` 58, `CardsPage` 55, `TutorPanel` 50 (in Build 32 nicht
/// gewachsen). Build 31 lag beim Zeichnen knapp unter dem 1-MB-Stapel des iPads, Build 32 darueber.
///
/// Grenzen mit Abstand unter den Werten von Build 31 und knapp ueber den heute groessten Ansichten. Reisst ein Teil sie:
/// in eigene `struct … : View` zerlegen oder `ufTypeCut` setzen (siehe `ViewTypeCut`), nicht die Grenze anheben.
@MainActor
final class ViewTypeDepthAppTests: XCTestCase {

    /// Hoechste Schachtelungstiefe eines Ansichtstyps: etwa 60 % des Absturzwerts (115), zwei Drittel von Build 31 (104)
    static let maxDepth = 70
    /// Hoechster Stapelbedarf zum Aufloesen eines Ansichtstyps: Build 31 137 KB, Build 32 151 KB, heute hoechstens 75 KB
    static let maxStackBytes = 100 * 1024
    /// Hoechster Bedarf des Haupt-Threads beim ersten Zeichnen eines Dokuments. Das iPad hat 1008 KB; Build 31 brauchte
    /// ~960 KB (lief knapp), Build 32 ~1220 KB (Absturz), heute ~440 KB. Im selben Testlauf schon gezeichnet: der Wert ist
    /// kleiner (Metadaten im Speicher), nie groesser.
    static let maxRenderStackBytes = 768 * 1024

    struct Metrics: CustomStringConvertible {
        let length: Int
        let depth: Int
        let angleDepth: Int
        var description: String { "Länge \(length), Tiefe \(depth) (nur <>: \(angleDepth))" }
    }

    /// Laenge und Schachtelungstiefe des voll ausgeschriebenen Typnamens (`->` in Funktionstypen zaehlt nicht)
    static func metrics(_ type: Any.Type) -> Metrics {
        let name = _typeName(type, qualified: true)
        var depth = 0, maxDepth = 0, angle = 0, maxAngle = 0
        var previous: Character = " "
        for c in name {
            let closesAngle = c == ">" && previous != "-"
            if c == "<" || c == "(" { depth += 1; maxDepth = max(maxDepth, depth) } else if closesAngle || c == ")" { depth -= 1 }
            if c == "<" { angle += 1; maxAngle = max(maxAngle, angle) } else if closesAngle { angle -= 1 }
            previous = c
        }
        return Metrics(length: name.count, depth: maxDepth, angleDepth: maxAngle)
    }

    private final class Box: @unchecked Sendable { var value = 0 }

    /// Stapelbedarf, um `type` aus seinem Namen aufzuloesen wie die Laufzeit beim ersten Zeichnen
    /// (`swift_getTypeByMangledName`; die Rekursion laeuft auch, wenn die Metadaten schon im Speicher sind)
    nonisolated static func stackBytes(_ type: Any.Type) -> Int {
        guard let mangled = _mangledTypeName(type) else { return -1 }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.value = paintAndRun { _ = _typeByName(mangled) }
            done.signal()
        }
        thread.stackSize = 8 << 20
        thread.start()
        done.wait()
        return box.value
    }

    /// Stapel unterhalb des eigenen Rahmens mit einem Muster fuellen, `work` laufen lassen, tiefste beschriebene Stelle
    /// suchen. Ergebnis in Bytes unter dem eigenen Rahmen (mindestens der Abstand von 8 KB).
    @inline(never)
    nonisolated static func paintAndRun(_ work: () throws -> Void) rethrows -> Int {
        let pattern: UInt64 = 0x5354_4143_4B50_524F
        let me = pthread_self()
        let top = UInt(bitPattern: pthread_get_stackaddr_np(me))
        let low = top - UInt(pthread_get_stacksize_np(me))
        var anchor: UInt = 0
        let sp = withUnsafeMutablePointer(to: &anchor) { UInt(bitPattern: $0) }
        let from = (low + 16 * 1024) & ~UInt(7)
        let to = (sp - 8 * 1024) & ~UInt(7)
        let words = Int((to - from) / 8)
        guard words > 0, let p = UnsafeMutablePointer<UInt64>(bitPattern: from) else { return -1 }
        for i in 0..<words { p[i] = pattern }
        try work()
        var i = 0
        while i < words, p[i] == pattern { i += 1 }
        return Int(sp - (from + UInt(i) * 8))
    }

    /// Die grossen Ansichten (Rangfolge der Tiefe am 11.11.2026) und die Haupt-Seiten
    private static let bodies: [(String, Any.Type)] = [
        ("DocumentView", DocumentView.Body.self),
        ("CompanionView", CompanionView.Body.self),
        ("StudyPlanPage", StudyPlanPage.Body.self),
        ("CardsPage", CardsPage.Body.self),
        ("TutorPanel", TutorPanel.Body.self),
        ("MessagesPage", MessagesPage.Body.self),
        ("ZipFolderView", ZipFolderView.Body.self),
        ("AIStartView", AIStartView.Body.self),
        ("StudyModuleSheet", StudyModuleSheet.Body.self),
        ("DashboardView", DashboardView.Body.self),
        ("UFSidebar", UFSidebar.Body.self),
        ("LibraryView", LibraryView.Body.self),
        ("LibraryPage", LibraryPage.Body.self),
        ("SettingsPage", SettingsPage.Body.self),
        ("MainView", MainView.Body.self),
        ("TextDocumentView", TextDocumentView.Body.self),
        ("StudyGroupsSheet", StudyGroupsSheet.Body.self),
        ("StudyGroupRow", StudyGroupRow.Body.self),
        ("StudyGroupsCard", StudyGroupsCard.Body.self),
        ("PlanModulesSheet", PlanModulesSheet.Body.self),
        ("StudIPView", StudIPView.Body.self),
        ("EditorHeaderBar", EditorHeaderBar.Body.self),
        ("DocumentTabStrip", DocumentTabStrip.Body.self),
        ("EditorToolbar", EditorToolbar.Body.self),
        // eigene Wochen im Moduldetail (12.11.2026)
        ("ModulePage", ModulePage.Body.self),
        ("ModuleWeekFileRow", ModuleWeekFileRow.Body.self),
        ("ModuleSectionMenu", ModuleSectionMenu.Body.self),
        ("ModuleUnassignedBar", ModuleUnassignedBar.Body.self),
        // Lernziele (Smart Planner 2.0, 12.11.2026) und der Lernkalender, in den sie eingebettet sind
        ("PlanView", PlanView.Body.self),
        ("GoalsPage", GoalsPage.Body.self),
        ("GoalsBody", GoalsBody.Body.self),
        ("GoalsModuleRow", GoalsModuleRow.Body.self),
        ("GoalEditDialog", GoalEditDialog.Body.self),
        ("GoalSettingsDialog", GoalSettingsDialog.Body.self),
        ("PackageDrawer", PackageDrawer.Body.self),
        // Uni-Mail "Mit KI verbessern" (13.11.2026)
        ("UniMailComposeSheet", UniMailComposeSheet.Body.self),
        ("UniMailAIButton", UniMailAIButton.Body.self),
        ("UniMailAIProposal", UniMailAIProposal.Body.self),
        // neuer Einstieg (13.11.2026)
        ("IntroWelcomeLayout", IntroWelcomeLayout.Body.self),
        ("IntroWelcomeSignIn", IntroWelcomeSignIn.Body.self),
        ("IntroWelcomeStage", IntroWelcomeStage.Body.self),
        ("IntroTourLayout", IntroTourLayout.Body.self),
        ("IntroTourArt", IntroTourArt.Body.self),
        ("IntroSetupLayout", IntroSetupLayout.Body.self),
        ("IntroChatHistory", IntroChatHistory.Body.self),
        ("IntroAnswerPanel", IntroAnswerPanel.Body.self),
        ("IntroExamRow", IntroExamRow.Body.self),
        ("IntroPlanLayout", IntroPlanLayout.Body.self),
        ("IntroPlanHero", IntroPlanHero.Body.self),
        ("IntroPlanTile", IntroPlanTile.Body.self),
        ("IntroContainerStep", IntroContainerStep.Body.self),
    ]

    private func check(_ name: String, _ type: Any.Type, file: StaticString = #filePath, line: UInt = #line) {
        let m = Self.metrics(type)
        let stack = Self.stackBytes(type)
        print("TYPTIEFE \(name): \(m), Stapel \(stack / 1024) KB")
        XCTAssertLessThanOrEqual(m.depth, Self.maxDepth, "\(name): Typ zu tief geschachtelt (\(m)); in eigene Ansichten oder mit "
                                 + "ufTypeCut zerlegen, siehe ViewTypeCut", file: file, line: line)
        XCTAssertLessThanOrEqual(stack, Self.maxStackBytes, "\(name): Aufloesen des Typs braucht \(stack / 1024) KB Stapel",
                                 file: file, line: line)
    }

    /// Typ von `body` der grossen Ansichten, ohne sie zu zeichnen (Name mit V: laeuft nach den Zeichen-Tests, die die
    /// Metadaten zum ersten Mal brauchen sollen)
    func testViewBodyTypesStayShallow() {
        for (name, type) in Self.bodies { check(name, type) }
    }

    /// Erstes Zeichnen eines Dokuments: Stapelbedarf des Haupt-Threads wie auf dem iPad (dort 1008 KB). Laeuft vor den
    /// anderen Tests dieser Klasse (Reihenfolge nach Namen).
    func testDocumentFirstRenderFitsIPadStack() throws {
        var env: HostedEnvironment?
        let used = try Self.paintAndRun {
            let hosted = try hostDocument()
            env = hosted
            XCTAssertTrue(hosted.wait(timeout: 15) { hosted.labels().contains("Seiten") }, hosted.labels().joined(separator: "\n"))
        }
        print("TYPTIEFE Haupt-Thread beim ersten Zeichnen von DocumentView: \(used / 1024) KB")
        XCTAssertNotNil(env)
        XCTAssertLessThanOrEqual(used, Self.maxRenderStackBytes,
                                 "erstes Zeichnen von DocumentView braucht \(used / 1024) KB Stapel (iPad: 1008 KB)")
    }

    private func hostDocument() throws -> HostedEnvironment {
        HostedEnvironment.accessibilityAutomation(true)
        addTeardownBlock { @MainActor in HostedEnvironment.accessibilityAutomation(false) }
        let t = AIViewsAppTests.Transport()
        let id = "f-tiefe-\(UUID().uuidString.prefix(8))"
        t.answer("/api/files/\(id)/content", data: Self.makePDF(pages: 2), type: "application/pdf")
        t.answer("/api/files/\(id)/annotations", ["data": AnnotationDocument.emptyRoot, "version": 0, "updated_at": .null])
        let meta: JSONValue = ["id": .string(id), "name": "Skript.pdf", "title": "Skript.pdf", "kind": "pdf", "module_id": 1,
                               "downloaded_at": "2026-11-11T09:00:00", "page_count": 2, "doc_type": "vorlesung"]
        let file = try JSONDecoder().decode(LibFile.self, from: meta.serialized())
        let api = APIClient(base: URL(string: "http://erfunden.test/")!, transport: t)
        return try hostWithEnvironment(NavigationStack { DocumentView(file: file, api: api) }, api: api)
    }

    private static func makePDF(pages: Int) -> Data {
        let raw = NSMutableData()
        let size = CGSize(width: 595, height: 842)
        UIGraphicsBeginPDFContextToData(raw, CGRect(origin: .zero, size: size), nil)
        for i in 1...pages {
            UIGraphicsBeginPDFPageWithInfo(CGRect(origin: .zero, size: size), nil)
            "Folie \(i)".draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
        UIGraphicsEndPDFContext()
        return raw as Data
    }

    // ANFANG Teile (gibt es erst seit dem Fix nach Build 32)

    /// Die Teile hinter `ufTypeCut` im gezeichneten Dokument: alle gesehen, alle flach
    func testDocumentPartsStayShallow() throws {
        ViewTypeCut.seen = [:]
        let env = try hostDocument()
        // seit 12.11.2026 dazu die eine Kopfzeile ("Oben fest") mit Reitern, Werkzeugen und Knoepfen
        let parts = ["DocumentView.chrome", "DocumentView.panels", "DocumentView.sheets", "DocumentView.primaryPane",
                     "DocumentView.header", "DocumentView.headerLeading", "DocumentView.headerActions"]
        XCTAssertTrue(env.wait(timeout: 15) { parts.allSatisfy { ViewTypeCut.seen[$0] != nil } },
                      "nicht alle Teile gezeichnet: \(ViewTypeCut.seen.keys.sorted())")
        for name in parts {
            let type = try XCTUnwrap(ViewTypeCut.seen[name], name)
            check(name, type)
        }
    }

    // ENDE Teile
}

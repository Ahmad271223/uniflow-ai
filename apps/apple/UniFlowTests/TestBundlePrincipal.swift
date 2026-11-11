import UIKit
import XCTest
@testable import UniFlow

/// Hauptklasse des Testbundles (INFOPLIST_KEY_NSPrincipalClass in project.yml). Die meisten App-Tests hosten ihre
/// Ansicht in einem Fenster in iPad-Groesse (1180 x 820) und erwarten die breite Fassung; ihre Groessenklasse erbt das
/// Fenster aber von der Szene. Auf dem iPad-Simulator ist die regular, auf einem iPhone-Simulator compact - dort bekamen
/// diese Tests die iPhone-Fassung (Blaetter statt Spalten) und schlugen fehl (iPhone-Lauf 06.11.2026). Auf einem
/// iPhone-Simulator setzt die Szene deshalb dieselben Groessenklassen wie das iPad; die iPhone-Tests (`hostPhone`,
/// Breiten-Audit) setzen compact weiter selbst am Fenster bzw. Hosting-Controller. Auf dem iPad aendert sich nichts.
@objc(UniFlowTestsPrincipal)
final class UniFlowTestsPrincipal: NSObject, XCTestObservation {
    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testBundleWillStart(_ testBundle: Bundle) {
        MainActor.assumeIsolated { Self.regularSceneOnPhone() }
    }

    /// Die iPhone-Fassung gibt es in der App nur auf dem iPhone (`UFCompact.phoneLayouts`). Die iPhone-Tests
    /// (Klassen `IPhone…`, Methoden `testIPhone…`) pruefen sie auch auf dem iPad-Simulator in Fenstern in iPhone-Groesse;
    /// alle anderen Tests sehen das echte Geraet (am iPad also nie die iPhone-Fassung, wie in der App).
    func testCaseWillStart(_ testCase: XCTestCase) {
        UFCompact.phoneLayoutsOverride = Self.isPhoneTest(testCase.name) ? true : nil
        OpenAIKeyLink.isOffered = Self.isOwnChatGPTTest(testCase.name)
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        UFCompact.phoneLayoutsOverride = nil
        OpenAIKeyLink.isOffered = false
    }

    /// „Eigenes ChatGPT“ ist in der App aus (`OpenAIKeyLink.isOffered`, Vorgabe des Inhabers 11.11.2026). Die Tests der
    /// ruhenden Funktion (eigener OpenAI-Schluessel, Kosten- und Fusszeilen ueber das eigene ChatGPT) schalten sie fuer
    /// sich ein, damit sie beim Wiedereinschalten noch stimmt; alle anderen Tests sehen sie aus wie die App.
    static func isOwnChatGPTTest(_ name: String) -> Bool {
        ["OpenAIKeyLinkAppTests", "ChatGPTLinkAppTests", "AIViewsAppTests", "AIStartPolishAppTests", "CreditsDisplayAppTests",
         "StudiNowAIAppTests", "PlanMatrixAppTests", "KIAbnahmeLUHAppTests test1EigenerSchluesselInJedemTarif"]
            .contains { name.contains($0) }
    }

    static func isPhoneTest(_ name: String) -> Bool { name.contains("IPhone") }

    /// Geraet fuer Stift-Fragen (`UFCompact.isPhone`) ausserhalb der iPhone-Tests: auf dem iPhone-Simulator wie ein
    /// iPad (false), auf dem iPad das echte Geraet (nil). Tests, die ein iPhone vortaeuschen, setzen danach hierauf zurueck.
    static let deviceDefault: Bool? = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]?.hasPrefix("iPhone") == true ? false : nil

    /// Editor (Schreiben auf PDFs) ausserhalb der iPhone-Tests: auf dem iPhone-Simulator wie am iPad vorhanden (false), auf
    /// dem iPad nach Geraet (nil). Die iPhone-Tests (`IPhoneReaderTests`) erzwingen die Leseansicht und setzen hierauf zurueck.
    static let readerOnlyDefault: Bool? = deviceDefault

    /// iPhone-Simulator: Szene wie ein iPad (horizontal und vertikal regular), Stift-Fragen wie am iPad
    @MainActor static func regularSceneOnPhone() {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        UFCompact.phoneOverride = deviceDefault
        UFEditorAvailability.forcedReaderOnlyForTesting = readerOnlyDefault
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.traitOverrides.horizontalSizeClass = .regular
            scene.traitOverrides.verticalSizeClass = .regular
        }
        // Das Fenster bestimmt seine Groessenklasse auf dem iPhone selbst (Szene regular genuegt nicht, Probe 06.11.):
        // jedes Testfenster regular, und zwar schon vor dem ersten Zeichnen (`makeKeyAndVisible` ausgetauscht; eine
        // Benachrichtigung danach kam fuer manche Ansichten zu spaet, sie blieben kompakt). Overrides am
        // Hosting-Controller (iPhone-Tests) gehen vor.
        if let original = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.makeKeyAndVisible)),
           let replacement = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.uf_testMakeKeyAndVisible)) {
            method_exchangeImplementations(original, replacement)
        }
        observer = NotificationCenter.default.addObserver(forName: UIWindow.didBecomeVisibleNotification, object: nil, queue: nil) { note in
            guard let w = note.object as? UIWindow else { return }
            MainActor.assumeIsolated { w.uf_regularForTests() }
        }
    }

    @MainActor private static var observer: NSObjectProtocol?
}

extension UIWindow {
    /// Groessenklassen wie am iPad (nur Tests auf dem iPhone-Simulator, `UniFlowTestsPrincipal`): ein Fenster ab 700 pt
    /// Breite ist dort regular; schmaler (Split View, iPhone-Groesse) bleibt es kompakt wie am iPad
    func uf_regularForTests() {
        guard frame.width >= 700 else { return }
        if traitOverrides.contains(UITraitHorizontalSizeClass.self), traitOverrides.horizontalSizeClass == .regular { return }
        traitOverrides.horizontalSizeClass = .regular
        traitOverrides.verticalSizeClass = .regular
    }

    /// Ersatz fuer `makeKeyAndVisible` (vertauscht): erst regular, dann das Original
    @objc func uf_testMakeKeyAndVisible() {
        uf_regularForTests()
        rootViewController?.view.setNeedsLayout()
        uf_testMakeKeyAndVisible()
    }
}

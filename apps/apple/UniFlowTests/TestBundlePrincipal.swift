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

    /// Geraet fuer Stift-Fragen (`UFCompact.isPhone`) ausserhalb der iPhone-Tests: auf dem iPhone-Simulator wie ein
    /// iPad (false), auf dem iPad das echte Geraet (nil). Tests, die ein iPhone vortaeuschen, setzen danach hierauf zurueck.
    static let deviceDefault: Bool? = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]?.hasPrefix("iPhone") == true ? false : nil

    /// iPhone-Simulator: Szene wie ein iPad (horizontal und vertikal regular), Stift-Fragen wie am iPad
    @MainActor static func regularSceneOnPhone() {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        UFCompact.phoneOverride = deviceDefault
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
        // Bildschirmtastatur: der iPad-Simulator hat die Hardware-Tastatur, der iPhone-Simulator blendet die
        // Bildschirmtastatur ein. Ueber einem Testfenster in iPad-Groesse verkleinerte sie den sicheren Bereich so weit,
        // dass Dialoge und Leisten nicht mehr gezeichnet wurden; je nach Zeitpunkt schlugen andere Tests fehl (voller
        // Lauf 06.11.2026). Wie am iPad: Eingaben bekommen eine leere Eingabeansicht (Text setzen die Tests direkt).
        for name in [UITextField.textDidBeginEditingNotification, UITextView.textDidBeginEditingNotification] {
            keyboards.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { note in
                MainActor.assumeIsolated {
                    if let f = note.object as? UITextField, !(f.inputView is NoKeyboard) { f.inputView = NoKeyboard(); f.reloadInputViews() }
                    if let v = note.object as? UITextView, !(v.inputView is NoKeyboard) { v.inputView = NoKeyboard(); v.reloadInputViews() }
                }
            })
        }
    }

    /// Leere Eingabeansicht statt der Bildschirmtastatur (nur iPhone-Simulator, nur Tests)
    final class NoKeyboard: UIView {
        init() { super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override var intrinsicContentSize: CGSize { .zero }
    }

    @MainActor private static var observer: NSObjectProtocol?
    @MainActor private static var keyboards: [NSObjectProtocol] = []
}

extension UIWindow {
    /// Groessenklassen wie am iPad (nur Tests auf dem iPhone-Simulator, `UniFlowTestsPrincipal`)
    func uf_regularForTests() {
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

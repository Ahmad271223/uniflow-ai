import SwiftUI
import UIKit
import UniFlowCore

/// Einwilligung vor der StudiNow-KI auf dem iPad (06.11.2026, App Store Review Guideline 5.1.2(i)). Die StudiNow-KI
/// (`StudiNowAI.json`) fragt vor jeder Anfrage `ensure`: liegt die Zustimmung zum aktuellen Text fuer dieses Konto vor,
/// geht es sofort weiter; sonst zeigt die App einmal den Hinweis "KI-Hilfe: Was wird gesendet?" (`AIConsentSheet`) ueber
/// allem, was gerade offen ist, und die Anfrage wartet auf "Okay, los" bzw. "Abbrechen". Gleichzeitige
/// Anfragen (z. B. "Ganzes Dokument") teilen sich denselben Hinweis. Gespeichert je StudiNow-Konto auf diesem Geraet
/// (`AIConsentStore`, UserDefaults, Schluessel mit dem Stand des Textes); widerrufen in Einstellungen → Zugang &
/// Darstellung → StudiNow-Konto → "KI-Einwilligung widerrufen".
@MainActor
final class AIConsentCenter: ObservableObject {
    static let shared = AIConsentCenter()

    /// Zeigt den Hinweis und ruft `decide` genau einmal; `false` = konnte ihn nicht zeigen (dann gilt Abbrechen)
    typealias Presenter = @MainActor (_ decide: @escaping @MainActor (Bool) -> Void) -> Bool

    var store: AIConsentStore
    var present: Presenter
    /// zaehlt Zustimmungen und Widerrufe (Einstellungen zeichnen sich neu)
    @Published private(set) var revision = 0
    private var waiting: [CheckedContinuation<Bool, Never>] = []
    private var asking: String?

    init(store: AIConsentStore = AIConsentStore(), present: @escaping Presenter = AIConsentCenter.presentOverTopController) {
        self.store = store
        self.present = present
    }

    func isGranted(_ account: String) -> Bool { store.isGranted(account) }
    func grantedAt(_ account: String) -> Date? { store.grantedAt(account) }

    /// Zustimmung fuer `account`; fragt hoechstens einmal gleichzeitig
    func ensure(account: String) async -> Bool {
        if store.isGranted(account) { return true }
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            waiting.append(c)
            guard waiting.count == 1 else { return }                // Hinweis ist schon offen
            asking = account
            let shown = present { [weak self] granted in self?.finish(granted) }
            if !shown { finish(false) }
        }
    }

    private func finish(_ granted: Bool) {
        guard !waiting.isEmpty else { return }                     // schon entschieden
        if granted, let a = asking {
            store.grant(a)
            revision += 1
        }
        let w = waiting
        waiting = []
        asking = nil
        for c in w { c.resume(returning: granted) }
    }

    func revoke(_ account: String) {
        store.revoke(account)
        revision += 1
    }

    // MARK: Anzeige

    /// Hinweis als Formblatt ueber dem obersten Fenster-Inhalt (auch ueber Editor und Dialogen); ohne Fenster false
    static func presentOverTopController(_ decide: @escaping @MainActor (Bool) -> Void) -> Bool {
        guard let top = topController() else { return false }
        final class Box { weak var host: UIViewController? }
        let box = Box()
        let host = AIConsentHost(rootView: AIConsentSheet { granted in
            (box.host as? AIConsentHost)?.onGone = nil               // entschieden: das Verschwinden zaehlt nicht mehr
            box.host?.dismiss(animated: true)
            decide(granted)
        })
        // Verschwindet der Hinweis ohne Entscheidung (das Blatt darunter schliesst sich, z. B. "Test erstellen" am
        // iPhone), gilt "Abbrechen". Vorher blieb die Anfrage fuer immer offen, und jede weitere KI-Anfrage wartete
        // mit - bis zum Neustart der App (Durchsicht 26.11.2026).
        host.onGone = { decide(false) }
        box.host = host
        host.modalPresentationStyle = .formSheet
        host.isModalInPresentation = true                           // nur ueber die beiden Knoepfe zu schliessen
        top.present(host, animated: true)
        // Lehnt UIKit das Zeigen ab (`top` zeigt gerade selbst etwas oder verschwindet), erscheint der Hinweis nie und
        // verschwindet darum auch nie: nach kurzer Zeit nachsehen. Nicht sofort - ein Zeigen, das UIKit nur aufschiebt
        // (das Blatt darunter erscheint noch), ist direkt nach dem Aufruf ebenfalls noch nicht eingetragen.
        DispatchQueue.main.asyncAfter(deadline: .now() + neverShownAfter) { [host] in
            guard host.onGone != nil, host.presentingViewController == nil, host.viewIfLoaded?.window == nil else { return }
            let gone = host.onGone
            host.onGone = nil
            gone?()
        }
        return true
    }

    /// so lange darf UIKit brauchen, bis der Hinweis eingetragen ist; danach gilt er als nie gezeigt
    static let neverShownAfter: TimeInterval = 2

    static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.sorted { a, _ in a.activationState == .foregroundActive }.flatMap(\.windows)
        guard var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController else { return nil }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
}

/// Formblatt des Hinweises: meldet, wenn es ohne Entscheidung verschwunden ist (`onGone`). `UFSheetHold` haelt faellige
/// Blaetter zurueck, solange es steht (wie bei einem Hinweis: UIKit lehnte sie sonst ab).
final class AIConsentHost: UIHostingController<AIConsentSheet> {
    var onGone: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // erst nach dem Abbau pruefen: ueberdeckt (etwas liegt darueber) ist nicht verschwunden
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presentingViewController == nil, self.viewIfLoaded?.window == nil else { return }
            let gone = self.onGone
            self.onGone = nil
            gone?()
        }
    }
}

/// Einwilligung der StudiNow-KI dieses Kontos (`StudiNowAI(consent:)`): fragt `AIConsentCenter` mit dem Konto, das
/// `account` gerade nennt
struct AppAIConsentGate: AIConsentGate {
    let center: AIConsentCenter
    let account: @MainActor @Sendable () -> String

    func ensureConsent() async -> Bool {
        await center.ensure(account: await MainActor.run { account() })
    }
}

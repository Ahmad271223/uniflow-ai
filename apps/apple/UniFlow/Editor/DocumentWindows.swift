import SwiftUI
import UIKit

/// Dokument in einem eigenen Fenster (11.11.2026): Uebung und Loesung bzw. Skript nebeneinander als zwei Fenster
/// (Mac: frei verschieb- und vergroesserbar, auch auf einen zweiten Bildschirm; iPad: Stage Manager bzw. Split View).
/// Das neue Fenster ist die ganze App (gleiche Oberflaeche wie das iPad) und oeffnet gleich das Dokument.
///
/// Weg: `requestSceneSessionActivation` mit einer `NSUserActivity` (Typ in der Info.plist unter `NSUserActivityTypes`).
/// Zusaetzlich liegt die Anfrage in `pending`: Ein neues Fenster nimmt sie beim ersten Erscheinen, falls das System
/// die Aktivitaet nicht an `onContinueUserActivity` weitergibt. Jede Anfrage wirkt nur einmal (Kennung).
@MainActor
enum DocumentWindows {
    static let activityType = "de.studinow.openDocument"

    struct Request: Equatable {
        let id: String
        let fileID: String
        let page: Int?
    }

    /// Anfragen, die ein neues Fenster noch nicht genommen hat
    private(set) static var pending: [Request] = []
    private static var handled: Set<String> = []

    /// Mehrere Fenster moeglich (iPad mit Stage Manager/Split View, Mac)
    static var supported: Bool { UIApplication.shared.supportsMultipleScenes }

    static func activity(for r: Request) -> NSUserActivity {
        let a = NSUserActivity(activityType: activityType)
        a.title = "Dokument öffnen"
        var info: [String: Any] = ["id": r.id, "file": r.fileID]
        if let p = r.page { info["page"] = p }
        a.userInfo = info
        a.targetContentIdentifier = "doc:" + r.fileID
        return a
    }

    static func request(from a: NSUserActivity) -> Request? {
        guard a.activityType == activityType, let id = a.userInfo?["id"] as? String, let file = a.userInfo?["file"] as? String,
              !file.isEmpty else { return nil }
        return Request(id: id, fileID: file, page: a.userInfo?["page"] as? Int)
    }

    /// Dokument in einem neuen Fenster oeffnen
    static func open(fileID: String, page: Int? = nil, from scene: UIScene? = nil) {
        let r = Request(id: UUID().uuidString, fileID: fileID, page: page)
        pending.append(r)
        let options = UIScene.ActivationRequestOptions()
        options.requestingScene = scene ?? UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive }
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: activity(for: r), options: options) { _ in
            Task { @MainActor in pending.removeAll { $0.id == r.id } }
        }
    }

    /// Anfrage annehmen (einmal je Kennung); `nil`, wenn schon erledigt
    static func take(_ r: Request) -> Request? {
        guard !handled.contains(r.id) else { return nil }
        handled.insert(r.id)
        pending.removeAll { $0.id == r.id }
        return r
    }

    /// Neues Fenster ohne Aktivitaet: aelteste offene Anfrage
    static func takePending() -> Request? {
        guard let r = pending.first else { return nil }
        return take(r)
    }

    static func route(for r: Request) -> UFRoute { .doc(r.fileID, page: r.page) }

    /// Nur fuer Tests
    static func resetForTesting() {
        pending = []
        handled = []
    }
}

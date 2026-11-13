import SwiftUI

/// Schnitt in der Typschachtelung grosser Ansichten (Absturz Build 32, iPad Pro 12,9" mit iPadOS 27.0.1, 11.11.2026):
/// Jeder Modifikator schachtelt den Typ von `body` eine Ebene tiefer (`ModifiedContent<ModifiedContent<…>>`). Beim
/// ersten Zeichnen loest die Swift-Laufzeit diesen Typ aus seinem Namen auf, rekursiv je Ebene und mit grossen
/// Stapelrahmen. `DocumentView.body` war mit gut 70 Modifikatoren 115 Ebenen tief (Build 31: 104); auf dem Haupt-Thread
/// (1 MB Stapel) lief das Aufloesen in die Schutzseite (EXC_BAD_ACCESS, "App geht an, aus, an, aus").
///
/// `AnyView` beendet die Schachtelung: der Typ dahinter wird getrennt aufgeloest. Aussehen und Verhalten bleiben gleich,
/// weil der Typ dahinter immer derselbe ist (SwiftUI behaelt Zustand und Identitaet der Kinder). Wachen ueber die Tiefe:
/// `ViewTypeDepthAppTests`.
enum ViewTypeCut {
    #if DEBUG
    /// Zuletzt gesehener Typ je Schnitt (nur fuer die Tests: so pruefen sie auch die Teile hinter `AnyView`)
    @MainActor static var seen: [String: Any.Type] = [:]
    #endif
}

extension View {
    /// Typschachtelung hier beenden (siehe `ViewTypeCut`); `name` nennt die Stelle fuer die Tests
    @MainActor func ufTypeCut(_ name: String) -> AnyView {
        #if DEBUG
        ViewTypeCut.seen[name] = Self.self
        #endif
        return AnyView(self)
    }
}

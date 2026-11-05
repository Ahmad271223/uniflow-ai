import SwiftUI
import UIKit

/// iPhone-Fassung (docs/IPHONE-2026-11-04.md): Die kompakte Darstellung richtet sich nach dem Platz, nicht nach dem
/// Geraet. Kompakt ist eine schmale Breite (iPhone hochkant, iPad im schmalen Split View) und eine niedrige Hoehe
/// (iPhone quer; das iPad hat nie eine kompakte Hoehe, die iPad-Darstellung aendert sich dadurch nicht). Das Geraet
/// zaehlt nur, wo es um den Stift geht: Ein iPhone hat keinen Apple Pencil, dort schreibt der Finger.
enum UFCompact {
    /// Kompakte Darstellung fuer diese Groessenklassen
    static func isCompact(horizontal: UserInterfaceSizeClass?, vertical: UserInterfaceSizeClass?) -> Bool {
        horizontal == .compact || vertical == .compact
    }

    /// Geraet ohne Apple Pencil (iPhone). Nur fuer Stift-Fragen, nie fuer das Layout.
    @MainActor static var isPhone: Bool { phoneOverride ?? (UIDevice.current.userInterfaceIdiom == .phone) }

    /// Nur Tests: ein iPhone vortaeuschen (iPad-Simulator mit Fenster in iPhone-Groesse); nil = echtes Geraet
    @MainActor static var phoneOverride: Bool?
}

/// Blatt von unten mit den Hoehen "halb" und "ganz" (iPhone): bei halber Hoehe bleibt die Seite darueber sichtbar und
/// bedienbar (Blaettern, Text markieren), das Blatt laesst sich am Griff aufziehen
struct UFHalfSheetStyle: ViewModifier {
    /// Hintergrund bleibt bei halber Hoehe bedienbar
    var interactiveBackground = true

    func body(content: Content) -> some View {
        content
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(interactiveBackground ? .enabled(upThrough: .medium) : .disabled)
            .presentationContentInteraction(.resizes)
    }
}

extension View {
    /// Blatt von unten (halb/ganz) fuer die kompakte Darstellung, siehe `UFHalfSheetStyle`
    func ufHalfSheet(interactiveBackground: Bool = true) -> some View {
        modifier(UFHalfSheetStyle(interactiveBackground: interactiveBackground))
    }

    /// Nur kompakt ein Blatt von unten (halb/ganz); breit (iPad) bleibt die Darstellung wie sie ist. Fuer Formulare
    /// mit eigenem Abschluss (z. B. "In Stud.IP abgeben") ohne bedienbaren Hintergrund.
    @ViewBuilder func ufHalfSheet(when compact: Bool, interactiveBackground: Bool = false) -> some View {
        if compact { ufHalfSheet(interactiveBackground: interactiveBackground) } else { self }
    }
}

import SwiftUI
import UIKit

/// iPhone-Fassung (docs/IPHONE-2026-11-04.md): Auf dem iPhone richtet sich die kompakte Darstellung nach dem Platz:
/// kompakt ist eine schmale Breite (hochkant) und eine niedrige Hoehe (quer). **Nur auf dem iPhone** (Vorgabe des
/// Inhabers 11.11.2026: „iPad-Version nicht anfassen“): ein iPad – auch im schmalen Split View oder in einem Blatt – und
/// der Mac behalten die bisherige Darstellung, die Groessenklassen zaehlen dort nicht (`phoneLayouts`).
enum UFCompact {
    /// Kompakte Darstellung fuer diese Groessenklassen (nur auf dem iPhone, sonst nie)
    static func isCompact(horizontal: UserInterfaceSizeClass?, vertical: UserInterfaceSizeClass?) -> Bool {
        phoneLayouts && (horizontal == .compact || vertical == .compact)
    }

    /// Gibt es die iPhone-Fassung auf diesem Geraet? Nur auf dem iPhone (Geraetefrage, ohne UIKit lesbar)
    static var phoneLayouts: Bool { phoneLayoutsOverride ?? UFDevice.isPhone }

    /// Nur Tests: die iPhone-Fassung auch auf dem iPad-Simulator pruefen (iPhone-Tests in Fenstern in iPhone-Groesse,
    /// `UniFlowTestsPrincipal`); nil = nach Geraet
    nonisolated(unsafe) static var phoneLayoutsOverride: Bool?

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

    /// Nur kompakt ein ganzes Blatt von unten (Schreiben mit Tastatur, z. B. neue Uni-Mail): sofort volle Hoehe, Griff
    /// sichtbar, Wischen nach unten schliesst es nicht versehentlich (ein Entwurf ginge sonst verloren); breit unveraendert
    @ViewBuilder func ufFullSheet(when compact: Bool) -> some View {
        if compact {
            presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
        } else { self }
    }
}

/// Text auf dem iPhone mehrzeilig umbrechen lassen (linksbuendig, volle Hoehe); sonst unveraendert (keine Wirkung auf
/// das iPad, auch nicht auf die Kantenglaettung)
struct UFCompactWrap: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true) } else { content }
    }
}

/// Wie `UFCompactWrap`, mit `\.ufCompact` aus der Umgebung (iPhone: umbrechen, iPad: unveraendert)
struct UFPhoneWrap: ViewModifier {
    @Environment(\.ufCompact) private var compact
    func body(content: Content) -> some View { content.modifier(UFCompactWrap(on: compact)) }
}

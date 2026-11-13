import SwiftUI

/// Erster Start (neuer Einstieg 13.11.2026, Views/Onboarding/Einstieg): Willkommen (Mit Apple anmelden) -> Rundgang ->
/// Hochschule waehlen -> sofort die Anmeldeseiten der Hochschule mit Erstabgleich (`main`, dort FirstLoginFlow im
/// offenen Container) -> Fragen im Gespraech und Probe/Tarife (ebenfalls im Container, `IntroContainerStep`) -> die
/// UniFlow-Oberflaeche.
/// Kein Verbindungsformular: die Verbindung zum eigenen PC-Server liegt in den Einstellungen unter "Entwicklung".
struct OnboardingFlow<Main: View>: View {
    @EnvironmentObject private var account: AccountStore
    @ViewBuilder let main: () -> Main

    var body: some View {
        Group {
            switch account.stage {
            case .welcome: IntroWelcomeView()
            case .tour: IntroTourView { account.markTourDone() }
            case .universityPicker: UniversityPickerView { account.chooseUniversity($0) }
            // Uni-Anmeldung, Fragen und Tarife brauchen den Container der Hochschule (Faecher, Termine)
            case .universityLogin, .setup, .planPicker, .ready: main()
            }
        }
        .animation(UF.transition, value: account.stage)
        .task { await account.verifyCredential() }          // still beim Start: widerrufen -> Begruessung
    }
}

// MARK: - Gemeinsamer Rahmen

/// Vollbild-Seite des ersten Starts: Hintergrund --bg, Inhalt mittig, hoechstens 520 pt breit, scrollt bei wenig Platz
struct OnboardingPage<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { content }
                    .frame(maxWidth: 520)
                    .padding(.horizontal, 25.6)
                    .padding(.vertical, 48)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(UF.bg.ignoresSafeArea())
    }
}

/// Das StudiNow-Logo (06.11.2026: Doktorhut mit Netz, wie das App-Icon), abgerundet wie ein App-Icon. Ueberall in der
/// App dieselbe Marke: Seitenleiste, Logo-Knopf im Editor, Anmeldung, Hochschulwahl, KI-Start.
struct UFLogoImage: View {
    var size: CGFloat

    var body: some View {
        Image("StudiNowLogo")
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Logo wie die Marke in der Seitenleiste (.brand), vergroessert
struct UFLogoMark: View {
    var size: CGFloat = 64

    var body: some View {
        UFLogoImage(size: size)
            .ufShadow(.sm)
    }
}

/// Schritte des Einstiegs im offenen Container: Uni-Anmeldung, Fragen, Probe und Tarife, danach die Oberflaeche. Nach
/// den Tarifen oeffnet die App den Lernkalender (der erste Lernplan), wenn in den Fragen Faecher gewaehlt wurden, sonst
/// die Übersicht.
struct IntroContainerStep: View {
    let stage: AccountStore.Stage
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var router: UFRouter

    var body: some View {
        switch stage {
        case .universityLogin: FirstLoginFlow()
        case .setup:
            IntroSetupView { planned in
                account.introPlannedModules = planned
                account.markSetupDone()
            }
        case .planPicker:
            IntroPlanView {
                let toPlan = account.introPlannedModules
                account.markPlanShown()
                // ohne Verlauf: auf der ersten Seite nach dem Einstieg gibt es keinen Zurück-Pfeil
                if toPlan { router.replace(UFRoute(hash: IntroContainerStep.firstRoute)) }
            }
        default: MainView()
        }
    }

    /// Ziel nach dem Einstieg: der Lernkalender mit dem ersten Lernplan
    static let firstRoute = "#/plan"
}

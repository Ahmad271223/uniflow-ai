import SwiftUI

/// Erster Start nach docs/AUFTRAG-APPSTORE-V1.md Abschnitt 2a und docs/AUFTRAG-HILDESHEIM-IPAD.md Abschnitt 1:
/// Begruessung (Mit Apple anmelden) -> beim ersten Mal Tarifwahl -> Hochschule waehlen -> sofort die Anmeldeseiten
/// der Hochschule mit Erstabgleich (`main`, dort FirstLoginFlow im offenen Container) -> die UniFlow-Oberflaeche.
/// Kein Verbindungsformular: die Verbindung zum eigenen PC-Server liegt in den Einstellungen unter "Entwicklung".
struct OnboardingFlow<Main: View>: View {
    @EnvironmentObject private var account: AccountStore
    @ViewBuilder let main: () -> Main

    var body: some View {
        Group {
            switch account.stage {
            case .welcome: WelcomeView()
            case .planPicker: PlanPickerView { account.markPlanShown() }
            case .universityPicker: UniversityPickerView { account.chooseUniversity($0) }
            case .universityLogin, .ready: main()
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

/// Logo wie die Marke in der Seitenleiste (.brand), vergroessert
struct UFLogoMark: View {
    var size: CGFloat = 64

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3).fill(UF.logoGradient)
            .frame(width: size, height: size)
            .overlay(UFIcon("graduation", size: size * 0.6).foregroundStyle(.white))
            .ufShadow(.sm)
            .accessibilityHidden(true)
    }
}

import SwiftUI

/// Erster Start nach docs/AUFTRAG-APPSTORE-V1.md Abschnitt 2a:
/// Begruessung (Mit Apple anmelden) -> beim ersten Mal Tarifwahl -> direkt die UniFlow-Oberflaeche.
/// Kein Verbindungsformular: die Verbindung zum eigenen PC-Server liegt in den Einstellungen unter "Entwicklung".
struct OnboardingFlow<Main: View>: View {
    @EnvironmentObject private var account: AccountStore
    @ViewBuilder let main: () -> Main

    var body: some View {
        Group {
            switch account.stage {
            case .welcome: WelcomeView()
            case .planPicker: OnboardingPlanStep.current.make { account.markPlanShown() }
            case .ready: main()
            }
        }
        .animation(UF.transition, value: account.stage)
        .task { await account.verifyCredential() }          // still beim Start: widerrufen -> Begruessung
    }
}

// MARK: - Bruecke zur Tarifwahl

/// Schritt "Tarif waehlen" im ersten Start. Die echte Tarifwahl (`PlanPickerView(onDone:)` in
/// Views/Onboarding/PlanPickerView.swift) baut das Abo-Paket; bis sie da ist, zeigt der Standard einen Platzhalter.
/// Einsetzen: `static let current = OnboardingPlanStep { AnyView(PlanPickerView(onDone: $0)) }`
struct OnboardingPlanStep {
    /// baut den Bildschirm; `onDone` fuehrt weiter zur Oberflaeche (Free gewaehlt oder Kauf erfolgreich)
    let make: (@escaping () -> Void) -> AnyView

    static let current: OnboardingPlanStep = .placeholder

    static let placeholder = OnboardingPlanStep { onDone in AnyView(PlanStepPlaceholder(onDone: onDone)) }
}

/// Platzhalter fuer die Tarifwahl: nur Titel und "Weiter", keine erfundenen Tarife oder Preise
private struct PlanStepPlaceholder: View {
    let onDone: () -> Void

    var body: some View {
        OnboardingPage {
            UFCard {
                UFCardHead("Tarif wählen", icon: "star")
                Text("Die Auswahl zwischen Free, Plus und Pro folgt hier. Du kannst den Tarif später jederzeit in den Einstellungen wechseln.")
                    .ufFont(14.5).foregroundStyle(UF.muted)
                HStack {
                    Spacer()
                    UFButton("Weiter", icon: "arrow-right", kind: .primary, action: onDone)
                }
                .padding(.top, 16)
            }
        }
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

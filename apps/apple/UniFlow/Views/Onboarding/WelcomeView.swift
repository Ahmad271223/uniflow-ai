import AuthenticationServices
import SwiftUI

/// Begruessung beim ersten Start (Abschnitt 2a, Schritt 1): Logo, ein Satz, wofuer das Konto dient
/// (Richtlinie 5.1.1(v), Abschnitt 7), Knopf "Mit Apple anmelden". Keine Adresse, keine PIN.
struct WelcomeView: View {
    @EnvironmentObject private var account: AccountStore
    @Environment(\.colorScheme) private var scheme

    /// wofuer das Konto dient: Icon, Titel, Erklaerung. Nur was V1 wirklich tut: Das Abo haengt an der Apple-ID im App
    /// Store (StoreKit, ohne appAccountToken), nicht an dieser Anmeldung; einen Abgleich zwischen Geraeten gibt es nicht.
    static let reasons: [(String, String, String)] = [
        ("graduation", "Hochschul-Zuordnung", "Deine Hochschule, ihre Verbindungen (z. B. Stud.IP) und deine Kurse werden deinem Konto zugeordnet – getrennt je Hochschule."),
        ("user", "Getrennte Daten", "Dateien, Notizen und Anmeldungen liegen je Konto und Hochschule getrennt auf diesem iPad. Nichts davon wird an UniFlow gesendet."),
        ("star", "Abo", "Ein Abo läuft über deine Apple-ID im App Store, unabhängig von der Anmeldung in UniFlow."),
    ]

    var body: some View {
        OnboardingPage {
            VStack(alignment: .leading, spacing: 0) {
                UFLogoMark()
                Text("Willkommen bei UniFlow").ufFont(30.4, 700, em: -0.02).foregroundStyle(UF.text).padding(.top, 22.4)
                Text("Stud.IP-Dateien, Lernplan und Notizen mit dem Apple Pencil – dein Studium an einem Ort.")
                    .ufFont(16).foregroundStyle(UF.text2).padding(.top, 6.4)
                    .fixedSize(horizontal: false, vertical: true)

                if let n = account.notice { notice(n).padding(.top, 19.2) }

                UFCard {
                    UFCardHead("Wofür du ein Konto brauchst", icon: "user")
                    VStack(alignment: .leading, spacing: 12.8) {
                        ForEach(Self.reasons, id: \.1) { r in
                            HStack(alignment: .top, spacing: 11.2) {
                                UFIcon(r.0, size: 16).foregroundStyle(UF.accentText)
                                    .frame(width: 30, height: 30)
                                    .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UF.accentSoft))
                                VStack(alignment: .leading, spacing: 1.6) {
                                    Text(r.1).ufFont(14.5, 600).foregroundStyle(UF.text)
                                    Text(r.2).ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .padding(.top, 25.6)

                SignInWithAppleButton(.signIn, onRequest: AccountStore.configure, onCompletion: { account.handle($0) })
                    .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
                    .frame(height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: UF.rSm))
                    .id(scheme)                                   // Stil wechselt sonst erst nach dem naechsten Aufbau
                    .padding(.top, 25.6)

                if let e = account.lastError {
                    HStack(alignment: .top, spacing: 7.2) {
                        UFIcon("alert", size: 14)
                        Text(e).fixedSize(horizontal: false, vertical: true)
                    }
                    .ufFont(13.12).foregroundStyle(UF.bad).padding(.top, 9.6)
                }

                #if DEBUG
                UFButton("Anmeldung überspringen (Debug)", icon: "arrow-right", kind: .ghost, size: .small) {
                    account.skipSignInForDebug()
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 12.8)
                #endif

                Text("Dateien aus Stud.IP bleiben nur auf diesem iPad. Mit der Anmeldung erhält UniFlow von Apple eine Kennung und, wenn du zustimmst, deinen Namen und deine E-Mail-Adresse.")
                    .ufFont(11.84).foregroundStyle(UF.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 19.2)
            }
        }
    }

    /// einmaliger Hinweis nach "Konto loeschen" bzw. nach einem Widerruf bei Apple
    @ViewBuilder private func notice(_ n: AccountStore.Notice) -> some View {
        HStack(alignment: .top, spacing: 9.6) {
            UFIcon("info", size: 16).foregroundStyle(UF.info)
            VStack(alignment: .leading, spacing: 4.8) {
                switch n {
                case .deleted:
                    Text("Dein Konto wurde von diesem iPad gelöscht.").ufFont(13.12, 600).foregroundStyle(UF.text)
                    if let problem = account.deletionProblem {
                        Text(problem).ufFont(13.12, 600).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Ein laufendes Abo wird dadurch nicht gekündigt. Abos verwaltest du bei Apple.")
                        .ufFont(13.12).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                    Link("Abos verwalten", destination: AccountStore.manageSubscriptionsURL).ufFont(13.12, 600).foregroundStyle(UF.accentText)
                case .signedOut:
                    Text("Deine Anmeldung mit Apple ist nicht mehr gültig. Bitte melde dich erneut an – deine Daten auf diesem iPad bleiben erhalten.")
                        .ufFont(13.12).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Button { account.notice = nil } label: { UFIcon("x", size: 14) }
                .buttonStyle(UFButtonStyle(kind: .ghost, size: .small, iconOnly: true))
                .accessibilityLabel("Hinweis schließen")
        }
        .padding(.vertical, 11.2).padding(.horizontal, 14.4)
        .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.infoSoft))
    }
}

#Preview("Begrüßung") {
    WelcomeView().environmentObject(AccountStore())
}

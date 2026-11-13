import AuthenticationServices
import SwiftUI

// Willkommen (neuer Einstieg, Schritt 1): links die Buehne in den Farben des App-Icons mit kleinen Ausschnitten aus der
// App (erfundene Beispiele), rechts Logo, Begruessung mit wechselndem Wort und "Mit Apple anmelden". Die Anmeldung
// bleibt Pflicht (eine Apple-Anmeldung fuer alles, Inhaber 12.11.2026); "Wofür brauchst du ein Konto?" klappt die
// Gruende auf (Richtlinie 5.1.1(v)). Schmal (Hochformat, kleines iPad, iPhone): die Buehne oben als Band.

/// Wörter, die in der Begruessung wechseln
enum IntroWelcomeText {
    static let title = "Willkommen bei StudiNow"
    static let lead = "Dein Studium an einem Ort:"
    static let words = ["Stud.IP-Dateien", "Lernplan", "Prüfungstermine", "Karteikarten", "Notizen"]
    static let accountQuestion = "Wofür brauchst du ein Konto?"
    static let stageCaption = UFDevice.adapt("Kurse, Dateien, Stundenplan und Noten deiner Hochschule – direkt auf dein iPad.")
}

/// Willkommen mit Anmeldung (am `AccountStore`)
struct IntroWelcomeView: View {
    @EnvironmentObject private var account: AccountStore

    var body: some View {
        IntroWelcomeLayout(notice: account.notice, error: account.lastError, deletionProblem: account.deletionProblem,
                           onCloseNotice: { account.notice = nil }) { result in
            account.handle(result)
        } onDebugSkip: {
            #if DEBUG
            account.skipSignInForDebug()       // nur in Test-Builds; der Knopf steht im Release nicht da
            #endif
        }
    }
}

/// Aufbau der Willkommensseite (ohne Konto, fuer Bilder und Tests)
struct IntroWelcomeLayout: View {
    var notice: AccountStore.Notice?
    var error: String?
    var deletionProblem: String?
    var onCloseNotice: () -> Void = {}
    let onSignIn: (Result<ASAuthorization, Error>) -> Void
    var onDebugSkip: () -> Void = {}

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 900
            Group {
                if wide {
                    HStack(spacing: 0) {
                        IntroWelcomeStage(compact: false)
                            .frame(width: geo.size.width * 0.48)
                            .padding(16)
                        IntroWelcomeSignIn(notice: notice, error: error, deletionProblem: deletionProblem, onCloseNotice: onCloseNotice,
                                           onSignIn: onSignIn, onDebugSkip: onDebugSkip)
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            IntroWelcomeStage(compact: true)
                                .frame(height: min(420, geo.size.height * 0.42))
                                .padding(12)
                            IntroWelcomeSignIn(notice: notice, error: error, deletionProblem: deletionProblem, onCloseNotice: onCloseNotice,
                                               onSignIn: onSignIn, onDebugSkip: onDebugSkip)
                        }
                        .frame(minHeight: geo.size.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
        }
        .background(UF.bg.ignoresSafeArea())
    }
}

/// Buehne der Willkommensseite: Farben des App-Icons, darauf kleine Ausschnitte der App
struct IntroWelcomeStage: View {
    let compact: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            IntroStage()
            GeometryReader { geo in
                // schmale Buehnen (kleines Fenster, iPhone): die Collage verkleinert, nie abgeschnitten
                let scale = min(1, geo.size.width / (compact ? 540 : 560), geo.size.height / (compact ? 400 : 760))
                IntroWelcomeCollage(compact: compact)
                    .scaleEffect(scale)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
                .padding(.bottom, compact ? 12 : 90)
            if !compact {
                VStack(alignment: .leading, spacing: 6) {
                    Text("StudiNow").ufFont(15, 700, em: 0.02).foregroundStyle(IntroStyle.onStage2)
                    Text(IntroWelcomeText.stageCaption).ufFont(19, 600).foregroundStyle(IntroStyle.onStage)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(32)
            }
        }
    }
}

/// Collage aus vier Kacheln (erfundene Beispiele): Heute im Lernplan, naechste Klausur, Karteikarte, neue Dateien
struct IntroWelcomeCollage: View {
    let compact: Bool

    var body: some View {
        let w: CGFloat = compact ? 230 : 270
        ZStack {
            if compact {
                // schmal: drei Kacheln nebeneinander versetzt, nichts verdeckt Text
                IntroTileToday().frame(width: w).offset(x: -130, y: -10)
                IntroTileExam().frame(width: w * 0.86).offset(x: 130, y: -50)
                IntroTileFiles().frame(width: w * 0.86).offset(x: 130, y: 105)
            } else {
                IntroTileToday().frame(width: w).offset(x: -80, y: -210)
                IntroTileExam().frame(width: w * 0.86).offset(x: 120, y: -10)
                IntroTileCard().frame(width: w * 0.95).offset(x: -90, y: 165)
                IntroTileFiles().frame(width: w * 0.8).offset(x: 150, y: 210)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Kachel "Heute": drei Lernbloecke, einer erledigt
struct IntroTileToday: View {
    var body: some View {
        IntroTile {
            IntroTileHead(icon: "calendar", title: "Heute im Lernplan")
            IntroTodayRow(color: Color(hex: 0x4f5bd5), title: "Analysis I", detail: "Übungsblatt 4 · 45 min", done: true)
            IntroTodayRow(color: Color(hex: 0x0ea5e9), title: "Technische Mechanik", detail: "Kapitel 3 · 30 min", done: false)
            IntroTodayRow(color: Color(hex: 0x16a34a), title: "Programmieren", detail: "Karteikarten · 20 min", done: false)
        }
    }
}

struct IntroTodayRow: View {
    let color: Color
    let title: String
    let detail: String
    let done: Bool

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).ufFont(12.5, 600).foregroundStyle(UF.text).strikethrough(done, color: UF.muted)
                Text(detail).ufFont(11.2).foregroundStyle(UF.muted)
            }
            Spacer(minLength: 4)
            UFIcon(done ? "check" : "circle", size: 14).foregroundStyle(done ? UF.ok : UF.lineStrong)
        }
    }
}

/// Kachel "Nächste Klausur" mit Tagen bis dahin
struct IntroTileExam: View {
    var body: some View {
        IntroTile {
            IntroTileHead(icon: "exam", title: "Nächste Klausur", tint: UF.warn)
            Text("Lineare Algebra").ufFont(14.5, 650).foregroundStyle(UF.text)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("12").ufFont(30, 700, em: -0.02).foregroundStyle(UF.text)
                Text("Tage").ufFont(13.12).foregroundStyle(UF.muted)
            }
            UFProgress(value: 0.62)
            Text("62 % der Lernzeit geschafft").ufFont(11.2).foregroundStyle(UF.muted)
        }
    }
}

/// Kachel Karteikarte mit Frage
struct IntroTileCard: View {
    var body: some View {
        IntroTile {
            IntroTileHead(icon: "cards", title: "Karteikarte", tint: Color(hex: 0x8b5cf6))
            Text("Was ist ein Eigenwert einer Matrix?").ufFont(14, 600).foregroundStyle(UF.text)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                IntroMiniChip(text: "Nochmal", tone: .bad)
                IntroMiniChip(text: "Gut", tone: .info)
                IntroMiniChip(text: "Leicht", tone: .ok)
            }
        }
    }
}

/// Kachel "Stud.IP": neue Dateien
struct IntroTileFiles: View {
    var body: some View {
        IntroTile {
            IntroTileHead(icon: "download", title: "Stud.IP", tint: UF.info)
            Text("3 neue Dateien").ufFont(14, 650).foregroundStyle(UF.text)
            Text("Vorlesung 5.pdf · Blatt 4.pdf …").ufFont(11.2).foregroundStyle(UF.muted).lineLimit(1)
        }
    }
}

/// kleiner Knopf-Ausschnitt in einer Kachel (nur Bild)
struct IntroMiniChip: View {
    let text: String
    let tone: UFTone

    var body: some View {
        Text(text).ufFont(11.2, 600).foregroundStyle(tone.fg)
            .padding(.vertical, 4).padding(.horizontal, 9)
            .background(Capsule().fill(tone.bg))
    }
}

/// Rechte Spalte: Logo, Begruessung, Anmeldung, Gruende fuer das Konto, Hinweis
struct IntroWelcomeSignIn: View {
    var notice: AccountStore.Notice?
    var error: String?
    var deletionProblem: String?
    var onCloseNotice: () -> Void = {}
    let onSignIn: (Result<ASAuthorization, Error>) -> Void
    var onDebugSkip: () -> Void = {}
    @Environment(\.colorScheme) private var scheme
    @State private var showReasons = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            UFLogoMark(size: 60)
            Text(IntroWelcomeText.title).ufFont(34, 700, em: -0.02).foregroundStyle(UF.text).padding(.top, 22)
                .accessibilityAddTraits(.isHeader)
            Text(IntroWelcomeText.lead).ufFont(19, 500).foregroundStyle(UF.text2).padding(.top, 8)
            IntroRotatingWord(words: IntroWelcomeText.words).padding(.top, 2)
            if let notice { IntroWelcomeNotice(notice: notice, deletionProblem: deletionProblem, onClose: onCloseNotice).padding(.top, 18) }
            SignInWithAppleButton(.signIn, onRequest: AccountStore.configure, onCompletion: onSignIn)
                .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
                .frame(height: IntroStyle.ctaHeight)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .id(scheme)
                .padding(.top, 34)
                .accessibilityIdentifier("intro.signin")
            if let error {
                HStack(alignment: .top, spacing: 7.2) {
                    UFIcon("alert", size: 14)
                    Text(error).fixedSize(horizontal: false, vertical: true)
                }
                .ufFont(13.12).foregroundStyle(UF.bad).padding(.top, 9.6)
            }
            #if DEBUG
            UFButton("Anmeldung überspringen (Debug)", icon: "arrow-right", kind: .ghost, size: .small, action: onDebugSkip)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
            #endif
            IntroAccountReasons(open: $showReasons).padding(.top, 18)
            Text(WelcomeView.footnote)
                .ufFont(12.16).foregroundStyle(UF.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
        }
        .frame(maxWidth: 440, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Wort in Akzentfarbe, das alle 2,2 s wechselt (bei "Bewegung reduzieren" und in Tests: das erste Wort fest)
struct IntroRotatingWord: View {
    let words: [String]
    @State private var index = 0

    var body: some View {
        Text(words[index])
            .ufFont(34, 700, em: -0.02)
            .foregroundStyle(LinearGradient(colors: [UF.accent, Color(hex: 0x8b5cf6), IntroStyle.teal],
                                            startPoint: .leading, endPoint: .trailing))
            .id(index)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 14)), removal: .opacity.combined(with: .offset(y: -14))))
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .clipped()
            .accessibilityLabel(words.joined(separator: ", "))
            .task {
                guard UFMotion.moves, words.count > 1 else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_200_000_000)
                    withAnimation(UFMotion.springCurve) { index = (index + 1) % words.count }
                }
            }
    }
}

/// "Wofür brauchst du ein Konto?" zum Aufklappen (die Gruende wie bisher, `WelcomeView.reasons`)
struct IntroAccountReasons: View {
    @Binding var open: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { UFMotion.toggle { open.toggle() } } label: {
                HStack(spacing: 8) {
                    UFIcon("info", size: 15)
                    Text(IntroWelcomeText.accountQuestion).ufFont(14, 600)
                    UFIcon(open ? "chevron-down" : "chevron-right", size: 13)
                }
                .foregroundStyle(UF.accentText)
                .ufHitArea()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("intro.reasons")
            if open {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(WelcomeView.reasons, id: \.1) { r in
                        HStack(alignment: .top, spacing: 10) {
                            UFIcon(r.0, size: 16).foregroundStyle(UF.accentText).frame(width: 20).padding(.top, 1)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.1).ufFont(13.6, 600).foregroundStyle(UF.text)
                                Text(r.2).ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 12)
                .ufReveal()
            }
        }
    }
}

/// Hinweis nach "Konto löschen" bzw. einem Widerruf bei Apple
struct IntroWelcomeNotice: View {
    let notice: AccountStore.Notice
    var deletionProblem: String?
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9.6) {
            UFIcon("info", size: 16).foregroundStyle(UF.info)
            VStack(alignment: .leading, spacing: 4.8) {
                switch notice {
                case .deleted:
                    Text(UFDevice.adapt("Dein Konto wurde von diesem iPad gelöscht.")).ufFont(13.12, 600).foregroundStyle(UF.text)
                    if let deletionProblem {
                        Text(deletionProblem).ufFont(13.12, 600).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Ein laufendes Abo wird dadurch nicht gekündigt. Abos verwaltest du bei Apple.")
                        .ufFont(13.12).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                    Link("Abos verwalten", destination: AccountStore.manageSubscriptionsURL).ufFont(13.12, 600).foregroundStyle(UF.accentText)
                case .signedOut:
                    Text(UFDevice.adapt("Deine Anmeldung mit Apple ist nicht mehr gültig. Bitte melde dich erneut an – deine Daten auf diesem iPad bleiben erhalten."))
                        .ufFont(13.12).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Button(action: onClose) { UFIcon("x", size: 14) }
                .buttonStyle(UFButtonStyle(kind: .ghost, size: .small, iconOnly: true))
                .accessibilityLabel("Hinweis schließen")
        }
        .padding(.vertical, 11.2).padding(.horizontal, 14.4)
        .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.infoSoft))
    }
}

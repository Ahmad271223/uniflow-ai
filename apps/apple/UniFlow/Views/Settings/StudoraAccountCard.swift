import AuthenticationServices
import SwiftUI
import UniFlowCore

/// Einstellungen → Konto & Tarif → Karte "Konto", unterer Teil "StudiNow-Konto": dasselbe Konto wie auf Windows und im
/// Web (Vertrag G1). Seit 12.11.2026 (Entscheidung des Inhabers: eine Apple-Anmeldung fuer alles) keine eigene Karte
/// mehr: die Anmeldung mit Apple beim ersten Start meldet auch hier an (`StudoraAccountLink.adoptFirstLogin`); die
/// Felder zum Anmelden sind nur noch Rueckfall (offline beim Start, Konto mit E-Mail aus der Windows-App). "Konto
/// löschen" steht einmal in der Karte und loescht beides (`AccountDeletion`). Sichtbar erst mit Dienst-Adresse
/// (`StudoraAccountLink.available`). Das Passwort geht nur an den Dienst, gemerkt wird es nur von iOS.
struct StudoraAccountCard: View {
    @ObservedObject var link: StudoraAccountLink
    @Environment(\.colorScheme) private var scheme
    /// iPhone: Anmelden und "Mit Apple anmelden" in voller Breite, Abgleich unter dem Stand
    @Environment(\.ufCompact) private var compact
    @State private var email = ""
    @State private var password = ""
    @State private var exportURL: URL?

    /// Wofuer das StudiNow-Konto da ist (12.11.2026)
    static let purpose = "Mit derselben Apple-ID bist du auch beim StudiNow-Dienst angemeldet. Darüber laufen die StudiNow-KI mit deinen Credits (Pro AI und Probe), dein Tarif auf allen Geräten und der Abgleich von Modulen, Stundenplan, Lernplan, Karteikarten und Einstellungen zwischen deinen Geräten; Notizen ab Pro AI. Hochschuldateien lädt jedes Gerät selbst, Hochschul-Passwörter gehen nie an StudiNow."
    /// Rueckfall: die Anmeldung beim Dienst hat (noch) nicht geklappt
    static let fallback = "Die Anmeldung beim StudiNow-Dienst fehlt auf diesem Gerät noch (z. B. weil du beim Start offline warst). Tippe auf „Mit Apple anmelden“ – mit derselben Apple-ID wie oben. Noch kein Konto? „Mit Apple anmelden“ legt es an (7 Tage Probe mit 25 Credits für die StudiNow-KI). Hast du dein Konto in der Windows-App mit E-Mail angelegt, melde dich mit E-Mail und Passwort an."

    var body: some View {
        VStack(alignment: .leading, spacing: 9.6) {
            HStack(spacing: 9.6) {
                Text("StudiNow-Konto").ufFont(14.5, 650).foregroundStyle(UF.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                UFBadge(link.user == nil ? "nicht verbunden" : "verbunden", tone: link.user == nil ? .neutral : .ok)
            }
            Text(Self.purpose)
                .ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("account.purpose")
            if let line = Self.aiLine(link.aiAccess, credits: link.credits, trial: link.planStatus?.trialActive ?? false) {
                Text(line).ufFont(13.12, 600).foregroundStyle(link.aiAccess == .ready ? UF.text2 : UF.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("account.ai")
            }
            if link.aiAccess == .ready || link.aiConsentGrantedAt != nil {
                AIConsentRow(link: link, center: link.consentCenter)
            }
            if let u = link.user { signedIn(u) } else { signIn }
            if let m = link.message {
                Text(m).ufFont(13.12).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("account.message")
                // Handlung zum Fehlercode (ServiceErrorText.action); der Link steht unten schon, wenn unbestaetigt
                if link.messageAction == .verifyEmail, link.user?.emailVerified != false { resendButton }
            }
            if let n = link.notice {
                Text(n).ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("account.notice")
            }
        }
        .task { await link.refresh() }
        .sheet(item: Binding(get: { exportURL.map(ExportItem.init) }, set: { exportURL = $0?.url })) { item in ActivityView(items: [item.url]) }
    }

    /// Zeile zur StudiNow-KI: bereit mit Credits-Stand, bzw. was fehlt (Anmeldung); nil ohne Pro AI und ohne Probe
    static func aiLine(_ access: StudiNowAIAccess, credits: StudoraCredits?, trial: Bool) -> String? {
        switch access {
        case .ready:
            return "StudiNow-KI bereit" + (AICost.balanceLine(credits, trial: trial, labelled: false).map { " · \($0)" } ?? "")
        case .signInRequired:
            return "Du hast StudiNow Pro AI: melde dich hier an, dann antwortet die StudiNow-KI."
        case .planRequired, .unavailable:
            return nil
        }
    }

    /// Stand des Geraete-Abgleichs in einem Satz
    static func syncText(_ r: DeviceSyncResult?) -> String {
        guard let r else { return "Noch nicht abgeglichen" }
        guard r.ok else { return r.error ?? "Abgleich fehlgeschlagen" }
        var s = "Abgeglichen: \(r.applied) geholt, \(r.pushed) gesendet"
        if r.pending > 0 { s += ", \(r.pending) warten auf ihre Datei" }
        if r.planRequired { s += ". Notizen bleiben im Tarif Free auf diesem Gerät" }
        if let e = r.errors.first { s += ". \(e)" }
        return s
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 9.6) {
            Text(Self.fallback).ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            // "Mit Apple anmelden": Token-Tausch beim Dienst; ein neues Konto bekommt die Hochschule dieses iPads
            SignInWithAppleButton(.signIn, onRequest: { link.prepareAppleRequest($0) }, onCompletion: { result in
                Task { await link.handleAppleSignIn(result) }
            })
            .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
            .frame(maxWidth: compact ? .infinity : 320, minHeight: 44, maxHeight: 44)
            .disabled(link.busy)
            .accessibilityIdentifier("account.apple")
            // Felder im Stil der App mit Beschriftung darueber
            UFField("E-Mail") {
                UFTextField("name@beispiel.de", text: $email)
                    .textContentType(.username).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            UFField("Passwort") {
                UFTextField("Passwort", text: $password, secure: true).textContentType(.password)
            }
            UFFlexWrap(gap: 9.6) {
                UFButton(link.busy ? "Melde an …" : "Mit E-Mail anmelden", icon: "log-out", size: .small) {
                    Task {
                        await link.login(email: email, password: password)
                        password = ""                                            // nie im Speicher behalten
                    }
                }
                .disabled(link.busy || email.isEmpty || password.isEmpty)
                .accessibilityIdentifier("account.login")
            }
        }
        .padding(.top, 4)
    }

    private func login() {
        Task {
            await link.login(email: email, password: password)
            password = ""                                            // nie im Speicher behalten
        }
    }

    @ViewBuilder private func signedIn(_ u: StudoraAccount.User) -> some View {
        VStack(alignment: .leading, spacing: 9.6) {
            SettingsValue(label: "Angemeldet als", value: u.email)
            if !u.emailVerified {
                Text("E-Mail noch nicht bestätigt: bitte den Link in der Willkommensmail öffnen. Ohne Bestätigung gehen StudiNow-KI und Schreiben in der Community nicht.")
                    .ufFont(12.8).foregroundStyle(UF.warn).fixedSize(horizontal: false, vertical: true)
                resendButton
            }
            SettingsDivider()
            let syncLayout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 9.6))
            syncLayout {
                Text(Self.syncText(link.lastSync)).ufFont(12.8).foregroundStyle(link.lastSync?.ok == false ? UF.bad : UF.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("account.sync")
                if !compact { Spacer() }
                UFButton(link.syncing ? "Gleiche ab …" : "Jetzt abgleichen", icon: "sync", size: .small) { Task { await link.syncNow(force: true) } }
                    .disabled(link.syncing)
                    .accessibilityIdentifier("account.syncNow")
            }
            SettingsDivider()
            Text("Angemeldete Geräte").ufFont(13.12, 600).foregroundStyle(UF.text2)
                .accessibilityAddTraits(.isHeader)
            // Geraete als Liste mit Linien; dieses Geraet mit Haken statt Klammerzusatz am Ende
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(link.sessions.enumerated()), id: \.element.id) { i, s in
                    if i > 0 { SettingsDivider() }
                    HStack(spacing: 9.6) {
                        Text((s.deviceName ?? "Gerät") + (s.current ? " (dieses Gerät)" : "")).ufFont(14.5).foregroundStyle(UF.text)
                        Spacer()
                        if s.current {
                            UFIcon("check", size: 16).foregroundStyle(UF.ok)
                        } else {
                            UFButton("Abmelden", size: .small) { Task { await link.revoke(s.id) } }
                        }
                    }
                    .frame(minHeight: 44)
                }
            }
            UFFlexWrap(gap: 9.6) {
                if link.sessions.count > 1 {
                    UFButton("Andere Geräte abmelden", size: .small) { Task { await link.logoutOthers() } }
                }
                UFButton("Daten exportieren", icon: "download", size: .small) { Task { exportURL = await link.export() } }
                UFButton("Abmelden", icon: "log-out", size: .small) { Task { await link.logout() } }
                    .accessibilityIdentifier("account.logout")
            }
            // "Konto löschen" steht einmal oben in der Karte "Konto" und loescht auch dieses Konto (`AccountDeletion`)
        }
        .padding(.top, 4)
    }

    private var resendButton: some View {
        UFButton("Bestätigungslink erneut senden", icon: "refresh", size: .small) { Task { await link.resendVerification() } }
            .disabled(link.busy)
            .accessibilityIdentifier("account.resendVerification")
    }

    private struct ExportItem: Identifiable {
        let url: URL
        var id: String { url.path }
    }
}

/// Einwilligung zur StudiNow-KI (App Store 5.1.2(i), `AIConsentCenter`): Stand und "KI-Einwilligung widerrufen"
struct AIConsentRow: View {
    @ObservedObject var link: StudoraAccountLink
    @ObservedObject var center: AIConsentCenter

    /// "KI-Einwilligung erteilt am 6. November 2026" bzw. der Hinweis, dass vor der ersten Anfrage gefragt wird
    static func text(grantedAt: Date?) -> String {
        guard let d = grantedAt else {
            return "KI-Einwilligung: noch nicht erteilt. Vor der ersten Anfrage an die StudiNow-KI fragt StudiNow, ob Seitentext und Frage an den KI-Anbieter gehen dürfen."
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.timeZone = TimeZone(identifier: "Europe/Berlin")
        f.dateFormat = "d. MMMM yyyy"
        return "KI-Einwilligung erteilt am \(f.string(from: d)): Seitentext, Bereich und Frage gehen über den StudiNow-Dienst an OpenAI bzw. Claude (Amazon Bedrock, Frankfurt)."
    }

    var body: some View {
        let granted = center.grantedAt(link.aiConsentAccount)
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.text(grantedAt: granted)).ufFont(12.8).foregroundStyle(UF.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("account.aiConsent")
            if granted != nil {
                UFButton(AIConsentText.revokeButton, icon: "x", size: .small) { link.revokeAIConsent() }
                    .accessibilityIdentifier("account.aiConsent.revoke")
            }
        }
        .padding(.top, 4)
    }
}

// MARK: - Hinweis auf der Uebersicht: Pro AI ohne Anmeldung

/// Pro AI (oder Probe) ist auf dem iPad aktiv, aber das StudiNow-Konto ist nicht angemeldet: die StudiNow-KI laeuft
/// ueber den Dienst, der Tarif und Credits kennen muss. Die Anmeldung beim ersten Start (Apple-ID) bleibt nur auf dem
/// Geraet und reicht dafuer nicht. Rueckmeldung des Inhabers 10.11.2026 ("gib wenigstens eine Nachricht davor"):
/// vorher stand der Hinweis nur in den Einstellungen und auf den KI-Seiten, "Tests & Wiederholung" fehlte ohne Erklaerung.
enum ProAISignInHint {
    static let title = "Noch ein Schritt für die KI"
    static let text = "Du hast StudiNow Pro AI. Damit die StudiNow-KI antwortet, melde dich einmal mit deinem StudiNow-Konto an. "
        + "Danach erscheint „Tests & Wiederholung“ in der Leiste."
    static let otherLogin = "Mit E-Mail anmelden"

    /// Karte zeigen? Nur, wenn genau die Anmeldung fehlt (nicht ohne Tarif, nicht ohne Dienst)
    static func shows(_ access: StudiNowAIAccess) -> Bool { access == .signInRequired }
}

/// Karte auf der Uebersicht mit "Mit Apple anmelden" (wie in der Karte "StudiNow-Konto") und dem Weg zur Anmeldung
/// mit E-Mail in den Einstellungen; verschwindet von selbst, sobald die KI bereit ist
struct ProAISignInBanner: View {
    @ObservedObject var link: StudoraAccountLink
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var router: UFRouter

    var body: some View {
        if ProAISignInHint.shows(link.aiAccess) {
            UFCard(flat: true) {
                VStack(alignment: .leading, spacing: 11.2) {
                    HStack(alignment: .top, spacing: 11.2) {
                        UFIcon("sparkles", size: 20).foregroundStyle(UF.accent)
                        VStack(alignment: .leading, spacing: 2.4) {
                            Text(ProAISignInHint.title).ufFont(14.5, 650).foregroundStyle(UF.text)
                            Text(ProAISignInHint.text).ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack(spacing: 11.2) {
                        SignInWithAppleButton(.signIn, onRequest: { link.prepareAppleRequest($0) }, onCompletion: { result in
                            Task { await link.handleAppleSignIn(result) }
                        })
                        .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
                        .frame(maxWidth: 260, minHeight: 40, maxHeight: 40)
                        .disabled(link.busy)
                        .accessibilityIdentifier("proai.signin.apple")
                        UFButton(ProAISignInHint.otherLogin, size: .small) { router.go(.settings(tab: "account")) }
                            .accessibilityIdentifier("proai.signin.settings")
                    }
                    if let m = link.message {
                        Text(m).ufFont(13.12).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .accessibilityIdentifier("proai.signin")
        }
    }
}

// MARK: - Direkt nach dem Kauf von Pro AI

extension ProAISignInHint {
    static let purchasedTitle = "Pro AI ist aktiv"
    static let purchasedText = "Noch ein Tippen: Melde dich mit deiner Apple-ID beim StudiNow-Konto an, dann antwortet die StudiNow-KI "
        + "und „Tests & Wiederholung“ erscheint in der Leiste."
    static let later = "Später"

    /// Nach einem Kauf gleich zur Anmeldung bitten? Nur fuer Pro AI, nur mit StudiNow-Dienst und nur ohne Anmeldung
    /// (Inhaber 10.11.2026: "ja" zur Anmeldung direkt nach dem Kauf). Seit 12.11.2026 nur noch als Rueckfall und nur mit
    /// offenem Datenbereich (`accountOpen`): beim ersten Start liegt die Tarifwahl VOR der Hochschulwahl, dort lief
    /// "Mit Apple anmelden" ins Leere und die Karte schloss nie. Dort meldet die Anmeldung vom Start nach der
    /// Hochschulwahl beim Dienst an (`StudoraAccountLink.adoptFirstLogin`), sonst zeigt die Uebersicht den Hinweis.
    static func asksAfterPurchase(plan: UFPlan, serviceAvailable: Bool, signedIn: Bool, accountOpen: Bool) -> Bool {
        plan == .proAI && serviceAvailable && !signedIn && accountOpen
    }
}

/// Karte ueber der Tarifseite nach dem Kauf von Pro AI: "Mit Apple anmelden" oder "Später" (dann bleibt der Hinweis auf
/// der Uebersicht, `ProAISignInBanner`). Sobald die Anmeldung steht, schliesst sie die Tarifseite (`done`).
struct ProAIAfterPurchasePrompt: View {
    @ObservedObject var link: StudoraAccountLink
    let done: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            UFCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 11.2) {
                        UFIcon("sparkles", size: 22).foregroundStyle(UF.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ProAISignInHint.purchasedTitle).ufFont(17, 700).foregroundStyle(UF.text)
                            Text(ProAISignInHint.purchasedText).ufFont(14).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    SignInWithAppleButton(.signIn, onRequest: { link.prepareAppleRequest($0) }, onCompletion: { result in
                        Task { await link.handleAppleSignIn(result) }
                    })
                    .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
                    .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
                    .disabled(link.busy)
                    .accessibilityIdentifier("proai.purchased.apple")
                    if let m = link.message {
                        Text(m).ufFont(13.12).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Spacer()
                        UFButton(ProAISignInHint.later, size: .small) { done() }
                            .accessibilityIdentifier("proai.purchased.later")
                    }
                }
            }
            .frame(maxWidth: 440)
            .padding(24)
        }
        .onChange(of: link.user?.id) { _, id in if id != nil { done() } }
        .accessibilityIdentifier("proai.purchased")
    }
}

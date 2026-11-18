import SwiftUI
import UniFlowCore

/// Datei-Eingang auf dem Geraet (Auftrag des Inhabers vom 18.11.2026): neue Kurs-PDFs gehen einmal an den Eingang und
/// werden dort geordnet (`CourseFileIntake` im Kern, Server app/intake_server.py).
///
/// Nur mit Zustimmung (Schalter, aus bis zur Zustimmung), nur mit StudiNow-Konto, nur im WLAN, nie in der Demo und nie
/// unter XCTest. Die Texte sind ein Entwurf: vor einer Veroeffentlichung mit dem Inhaber abstimmen (auch die
/// Datenschutzerklaerung braucht dann einen Absatz).
enum CourseFileIntakeSetting {
    /// Schalter des Builds: aus = nirgends sichtbar, nichts wird geschickt
    static var isOffered = true

    static let key = "studinow.courseFileIntake.v1"
    static let consentKey = "studinow.courseFileIntake.v1.consentAt"

    static func isOn(_ d: UserDefaults = .standard) -> Bool { isOffered && d.bool(forKey: key) }

    static func set(_ on: Bool, _ d: UserDefaults = .standard, now: Date = Date()) {
        d.set(on, forKey: key)
        if on { d.set(now, forKey: consentKey) } else { d.removeObject(forKey: consentKey) }
    }

    static let title = "Neue Kursdateien an StudiNow schicken"
    static let short = "Neue Vorlesungen, Übungen, Skripte und Altklausuren gehen einmal an StudiNow und werden dort nach Hochschule, Studiengang, Semester und Modul geordnet."
    static let consentTitle = "Kursdateien an StudiNow schicken?"
    static let consentPoints = [
        "Was: neue PDFs aus deinen Kursen – Vorlesungen, Übungen, Lösungen, Skripte und Altklausuren.",
        "Wohin: an StudiNow. Dort werden sie nach Hochschule, Studiengang, Semester und Modul geordnet.",
        "Jede Datei geht nur einmal hoch. Hat sie schon jemand geschickt, geht nichts mehr hoch.",
        "Nie gesendet: dein Name, dein Konto, deine Notizen, eigene Dokumente, Organisatorisches und Listen mit Namen, Matrikelnummern oder Noten.",
        "Nur im WLAN. Ausschalten geht jederzeit hier in den Einstellungen.",
    ]
    static let agree = "Zustimmen und einschalten"
    static let cancel = "Nicht jetzt"
    static let on = "Eingeschaltet"
}

enum CourseFileIntakeRunner {
    /// Konto-Anschluss des offenen Datenbereichs (gesetzt vom `ContainerManager`)
    @MainActor static weak var link: StudoraAccountLink?

    /// Nach dem Abgleich (`StudIPSync.autoPlan`): neue Dateien schicken, wenn alles passt. Fehler bleiben still, der
    /// naechste Abgleich versucht es wieder.
    nonisolated static func afterSync(host: LocalBackendHost) async {
        guard CourseFileIntakeSetting.isOn(), !StudIPSync.isUnderTest(), !(await host.demoActive()),
              let backend = try? await host.backend(), await DocIndexPrewarm.onWiFi(),
              let account = await MainActor.run(body: { link?.account }), await account.isSignedIn else { return }
        let ctx = backend.context
        let uni = try? await ctx.database.withConnection { try CourseFileIntake.university($0) }
        // an den StudiNow-Dienst; der reicht ueber das private Netz an den Eingang weiter (keine eigene Domain)
        let transport = AccountCourseFileIntake(account: account, university: uni)
        _ = try? await CourseFileIntake.run(ctx, transport: transport, shouldStop: { Task.isCancelled })
    }
}

// MARK: - Einstellungen

/// Schalter in der Karte "StudiNow-Konto": aus, bis der Nutzer im Blatt zustimmt
struct CourseFileIntakeRow: View {
    @State private var on = CourseFileIntakeSetting.isOn()
    @State private var asking = false

    var body: some View {
        if CourseFileIntakeSetting.isOffered {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: Binding(get: { on }, set: { want in
                    if want { asking = true } else { CourseFileIntakeSetting.set(false); on = false }
                })) {
                    Text(CourseFileIntakeSetting.title).ufFont(14.5, 600).foregroundStyle(UF.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .tint(UF.accentFill)
                .accessibilityIdentifier("intake.toggle")
                Text(CourseFileIntakeSetting.short).ufFont(12.8).foregroundStyle(UF.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)
            .ufSheet(isPresented: $asking) {
                CourseFileIntakeConsent(agree: {
                    CourseFileIntakeSetting.set(true)
                    on = true
                    asking = false
                }, cancel: { asking = false })
            }
        }
    }
}

/// Blatt vor dem Einschalten: was, wohin, was nie, nur WLAN
struct CourseFileIntakeConsent: View {
    let agree: () -> Void
    let cancel: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(CourseFileIntakeSetting.consentTitle).ufFont(20, 700, em: -0.01).foregroundStyle(UF.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("intake.consent.title")
                ForEach(CourseFileIntakeSetting.consentPoints, id: \.self) { p in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("•").ufFont(14.5, 700).foregroundStyle(UF.accentFill).accessibilityHidden(true)
                        Text(p).ufFont(14.5).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { Spacer(minLength: 0); buttons }
                    VStack(alignment: .trailing, spacing: 8) { buttons }.frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.top, 6)
            }
            .padding(20)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(UF.surface)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder private var buttons: some View {
        UFButton(CourseFileIntakeSetting.cancel, kind: .ghost) { cancel() }
            .accessibilityIdentifier("intake.consent.cancel")
        UFButton(CourseFileIntakeSetting.agree, kind: .primary) { agree() }
            .accessibilityIdentifier("intake.consent.agree")
    }
}

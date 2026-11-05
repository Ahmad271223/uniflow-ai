import SwiftUI

/// Hinweis unter dem Anmeldefenster einer Hochschule (Stud.IP, QIS, CAS fuer Learnweb und LSF; erster Start und
/// Einstellungen). Entscheidung des Inhabers (27.10.2026): Hochschul-Passwoerter merkt sich nur iOS (Passwort-Autofill
/// aus dem Schluesselbund im Anmeldefenster), nie UniFlow; es gibt keinen eigenen Schalter mehr. Seit 04.11.2026 merkt
/// die App den Benutzernamen (kein Geheimnis) fuer die Anmeldeseite des WebSSO bzw. CAS (`UniLoginHelper`). Ehrlich: In
/// Webansichten von Apps bietet iOS das Sichern oft nicht von selbst an - der Text verspricht das nicht, sondern nennt
/// den Weg ueber "Passwörter" (App unter iOS 18, Einstellungen unter iOS 17).
/// Eingeklappt eine Zeile mit "Mehr" (Audit 03.11.2026, P3: im ersten Start stehen sonst zwei Hinweisleisten mit viel
/// Text uebereinander, darunter noch "Später anmelden"); "Mehr" zeigt den ganzen Hinweis, "Weniger" klappt ihn zu.
struct UniversityLoginHint: View {
    static let text = "Passwörter merkt sich iOS (Schlüsselbund). Tippe auf das Schlüssel-Symbol über der Tastatur, um ein gespeichertes Passwort einzusetzen."
    static let detail = "StudiNow speichert nie dein Passwort. Nur deinen Benutzernamen merkt sich StudiNow auf diesem \(UFDevice.name), damit er beim nächsten Anmelden schon dasteht, und „Angemeldet bleiben“ ist angekreuzt. Bietet iOS das Sichern des Passworts nicht von selbst an, kannst du es unter „Passwörter“ selbst hinzufügen."
    static let more = "Mehr"
    static let less = "Weniger"

    @State private var expanded = false

    /// Beschriftung des Knopfs (reine Funktion fuer Tests)
    static func toggleTitle(expanded: Bool) -> String { expanded ? less : more }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            UFIcon("info", size: 15).foregroundStyle(UF.muted).padding(.top, 1.6)
            VStack(alignment: .leading, spacing: 2.4) {
                Text(Self.text).ufFont(12.8, 550).foregroundStyle(UF.text2)
                    .lineLimit(expanded ? nil : 1)
                if expanded {
                    Text(Self.detail).ufFont(12.16).foregroundStyle(UF.muted)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                Text(Self.toggleTitle(expanded: expanded)).ufFont(12.8, 600).foregroundStyle(UF.accentText)
                    .ufHitArea()                                       // eine Textzeile hoch, 44 pt antippbar
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Hinweis zuklappen" : "Ganzen Hinweis zu Passwörtern zeigen")
            .accessibilityIdentifier("login.hint.toggle")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9.6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UF.surface)
        .overlay(alignment: .top) { Rectangle().fill(UF.line).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("login.hint")
    }
}

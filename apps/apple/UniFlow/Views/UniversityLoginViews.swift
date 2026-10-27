import SwiftUI

/// Hinweis unter dem Anmeldefenster einer Hochschule (Stud.IP, QIS, CAS fuer Learnweb und LSF; erster Start und
/// Einstellungen). Entscheidung des Inhabers (27.10.2026): Hochschul-Passwoerter merkt sich nur iOS (Passwort-Autofill
/// aus dem Schluesselbund im Anmeldefenster), nie UniFlow; es gibt keinen eigenen Schalter mehr. Ehrlich: In
/// Webansichten von Apps bietet iOS das Sichern oft nicht von selbst an - der Text verspricht das nicht, sondern nennt
/// den Weg ueber "Passwörter" (App unter iOS 18, Einstellungen unter iOS 17).
struct UniversityLoginHint: View {
    static let text = "Passwörter merkt sich iOS (Schlüsselbund). Tippe auf das Schlüssel-Symbol über der Tastatur, um ein gespeichertes Passwort einzusetzen."
    static let detail = "UniFlow selbst speichert weder Benutzername noch Passwort. Bietet iOS das Sichern nicht von selbst an, kannst du das Passwort unter „Passwörter“ selbst hinzufügen."

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            UFIcon("info", size: 15).foregroundStyle(UF.muted).padding(.top, 1.6)
            VStack(alignment: .leading, spacing: 2.4) {
                Text(Self.text).ufFont(12.8, 550).foregroundStyle(UF.text2)
                Text(Self.detail).ufFont(12.16).foregroundStyle(UF.muted)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9.6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UF.surface)
        .overlay(alignment: .top) { Rectangle().fill(UF.line).frame(height: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("login.hint")
    }
}

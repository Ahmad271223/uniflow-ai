import SwiftUI
import UniFlowCore

/// Leiste unter der Anmeldeseite einer Hochschule: Schalter "Auf diesem iPad merken" (Standard an) mit Erklaerung.
/// Die App fuellt beim naechsten Mal nur vor; "Anmelden" tippt der Mensch selbst (Entscheidung des Inhabers).
struct UniversityRememberBar: View {
    @ObservedObject var autofill: UniversityLoginAutofill

    var body: some View {
        VStack(alignment: .leading, spacing: 4.8) {
            Toggle(isOn: $autofill.remember) {
                Text("Auf diesem iPad merken").ufFont(14.5, 550).foregroundStyle(UF.text)
            }
            .tint(UF.accent)
            .accessibilityIdentifier("login.remember")
            Text(Self.explanation(remember: autofill.remember, login: "\(autofill.service.name) · \(autofill.university.profile.short)"))
                .ufFont(12.8).foregroundStyle(UF.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("login.remember.info")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11.2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UF.surface)
        .overlay(alignment: .top) { Rectangle().fill(UF.line).frame(height: 1) }
    }

    static func explanation(remember: Bool, login: String) -> String {
        remember
            ? "Beim Tippen auf „Anmelden“ merkt sich UniFlow Benutzername und Passwort (\(login)) – nur im Schlüsselbund dieses iPads, nicht in iCloud und nie auf einem Server. Beim nächsten Mal stehen sie schon im Formular; anmelden tippst du selbst."
            : "UniFlow merkt sich nichts von dieser Seite. Bereits gemerkte Zugangsdaten (\(login)) wurden von diesem iPad entfernt."
    }
}

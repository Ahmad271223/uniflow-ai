import Foundation
import LocalAuthentication

/// "Konto löschen" nur durch die Besitzerin oder den Besitzer des Geraets (24.11.2026: in der Nacht zuvor hat jemand
/// am entsperrten iPad des Inhabers "Konto löschen" angetippt). Vor dem Loeschen Face ID bzw. Touch ID, sonst der
/// Code des Geraets (`LAPolicy.deviceOwnerAuthentication`, auf dem Mac das Anmeldepasswort). Hat das Geraet gar keinen
/// Code, laesst sich das nicht pruefen: dann tippt man zur Bestaetigung "LÖSCHEN" (`DeleteAccountGate`), damit das
/// Loeschen moeglich bleibt (Apple: nicht unnoetig erschweren).
///
/// Tests ersetzen die Pruefung ueber `evaluate` (die echte zeigt eine Systemabfrage, die unter XCTest niemand beantwortet).
enum DeviceOwnerCheck {
    enum Result: Equatable {
        /// Face ID, Touch ID oder Geraetecode bestaetigt
        case confirmed
        /// abgebrochen (Abbrechen, App im Hintergrund): nichts passiert
        case cancelled
        /// auf dem Geraet ist kein Code eingerichtet: Bestaetigung durch Eintippen
        case noPasscode
        /// andere Fehler (z. B. zu viele Versuche, Face ID gesperrt): Meldung fuer die Rueckfrage
        case failed(String)
    }

    static let reason = "Bestätige, dass du dein Konto löschen möchtest."

    /// Die Pruefung; Standard ist die echte des Systems, Tests setzen eine eigene
    @MainActor static var evaluate: @MainActor (String) async -> Result = system

    @MainActor
    static func confirm(reason: String = reason) async -> Result { await evaluate(reason) }

    /// Systemabfrage ueber LocalAuthentication
    @MainActor
    static func system(_ reason: String) async -> Result {
        let context = LAContext()
        context.localizedCancelTitle = "Abbrechen"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return result(for: error ?? LAError(.passcodeNotSet))
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? .confirmed : .cancelled
        } catch {
            return result(for: error)
        }
    }

    /// Fehler des Systems in ein Ergebnis uebersetzen
    static func result(for error: Error) -> Result {
        guard let e = error as? LAError else { return .failed(failedMessage) }
        switch e.code {
        case .passcodeNotSet:
            return .noPasscode
        case .userCancel, .appCancel, .systemCancel, .userFallback:
            return .cancelled
        case .biometryLockout:
            return .failed("Face ID bzw. Touch ID ist gesperrt. Entsperre das Gerät einmal mit dem Code und versuche es erneut.")
        default:
            return .failed(failedMessage)
        }
    }

    static let failedMessage = "Die Bestätigung mit Face ID, Touch ID oder dem Gerätecode hat nicht geklappt. Versuche es erneut."
}

/// Was "Konto löschen" in der Rueckfrage als Naechstes tut (Logik ohne Oberflaeche, `DeleteAccountDialog`)
struct DeleteAccountGate: Equatable {
    /// Wort, das ohne Geraetecode eingetippt wird
    static let typedWord = "LÖSCHEN"

    /// einmal bestaetigt, gilt es fuer diese Rueckfrage ("Erneut versuchen" nach einem Fehler des Dienstes fragt nicht neu)
    private(set) var ownerConfirmed = false
    /// kein Geraetecode: Feld zum Eintippen zeigen
    private(set) var needsTypedConfirmation = false
    private(set) var message: String?

    enum Step: Equatable {
        /// loeschen
        case proceed
        /// nichts tun (abgebrochen, Eingabe fehlt)
        case wait
    }

    /// Eintippen passt (Gross-/Kleinschreibung und Leerzeichen egal)
    static func matches(_ typed: String) -> Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == typedWord
    }

    /// Antippen von "Konto löschen": schon bestaetigt -> loeschen; sonst die Pruefung des Geraets (bzw. das Eintippen)
    @MainActor
    mutating func tap(typed: String, check: () async -> DeviceOwnerCheck.Result = { await DeviceOwnerCheck.confirm() }) async -> Step {
        if ownerConfirmed { return .proceed }
        if needsTypedConfirmation {
            guard Self.matches(typed) else {
                message = "Tippe „\(Self.typedWord)“ ein, um zu bestätigen."
                return .wait
            }
            ownerConfirmed = true
            message = nil
            return .proceed
        }
        switch await check() {
        case .confirmed:
            ownerConfirmed = true
            message = nil
            return .proceed
        case .cancelled:
            message = nil
            return .wait
        case .noPasscode:
            needsTypedConfirmation = true
            message = Self.noPasscodeMessage
            return .wait
        case .failed(let m):
            message = m
            return .wait
        }
    }

    static let noPasscodeMessage = "Auf diesem Gerät ist kein Code eingerichtet. Tippe zur Bestätigung „\(typedWord)“ ein und dann noch einmal auf „Konto löschen“."
}

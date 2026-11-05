import Foundation

/// Was der Bildschirm fuer "Zum Abpausen einfrieren" koennen muss: Bildschirm anlassen (Ruhezustand aus) und
/// Helligkeit. Auf dem iPad `UIApplication.isIdleTimerDisabled` und `UIScreen.brightness`, in den Tests ein Ersatz.
public protocol EditorFreezeScreen: AnyObject {
    var idleTimerDisabled: Bool { get set }
    /// Helligkeit steuerbar (iPad ja, Mac mit "Designed for iPad" nein)
    var supportsBrightness: Bool { get }
    /// 0 ... 1
    var brightness: Double { get set }
}

/// Bildschirm fixieren im Editor (Wunsch des Inhabers 05.11.2026, docs/FIXIEREN-ABPAUSEN-2026-11-05.md).
///
/// Zwei Stufen:
/// - `view` ("Ansicht fixieren"): Zoom, Scrollen und Seitenwechsel gesperrt, Stift und Werkzeuge schreiben weiter
///   (genaues Zeichnen, ohne dass die Seite verrutscht).
/// - `trace` ("Zum Abpausen einfrieren"): nichts reagiert mehr, auch der Stift nicht; Leisten weg, Bildschirm bleibt an,
///   auf Wunsch volle Helligkeit. Entsperren nur bewusst: Schloss etwa zwei Sekunden halten, Esc, VoiceOver-Aktion.
///
/// Zustand nur fuer die offene Sitzung des Dokuments; nichts davon wird gespeichert (die App merkt sich nur den Wunsch
/// "Helligkeit auf Maximum" unter `maxBrightnessPreferenceKey`). Plattformunabhaengig, damit die iPhone-Fassung
/// dieselbe Logik uebernehmen kann.
public final class EditorFreeze {

    public enum Mode: String, Sendable, Equatable, CaseIterable {
        case off
        case view
        case trace
    }

    public struct TraceOptions: Equatable, Sendable {
        /// Helligkeit auf Maximum, beim Entsperren zurueck auf den Stand davor
        public var maxBrightness: Bool
        /// weisser Hintergrund ohne Seitenschatten (Kontrast fuer das Abpausen)
        public var highContrast: Bool

        public init(maxBrightness: Bool = false, highContrast: Bool = false) {
            self.maxBrightness = maxBrightness
            self.highContrast = highContrast
        }
    }

    /// So lange muss das Schloss gehalten werden (Papier auf dem Bildschirm soll nichts entsperren)
    public static let unlockHoldDuration: TimeInterval = 2.0
    /// gemerkter Wunsch "Helligkeit auf Maximum" (UserDefaults)
    public static let maxBrightnessPreferenceKey = "uniflow.freeze.maxBrightness"
    /// Erklaerung beim ersten Mal gezeigt (UserDefaults)
    public static let introSeenKey = "uniflow.freeze.introSeen"

    public private(set) var mode: Mode = .off
    public private(set) var options = TraceOptions()
    /// Meldet jeden Wechsel der Stufe (fuer die Oberflaeche)
    public var onChange: ((Mode) -> Void)?

    private let screen: EditorFreezeScreen
    /// Stufe vor dem Abpausen (Entsperren fuehrt dorthin zurueck)
    private var modeBeforeTrace: Mode = .off
    /// Stand des Bildschirms vor dem Abpausen
    private var savedIdleTimer: Bool?
    private var savedBrightness: Double?
    /// App im Hintergrund: Helligkeit vorerst zurueck (iPadOS behielte sie sonst bis zur Sperre des Geraets)
    public private(set) var isSuspended = false
    /// Beginn des Haltens auf dem Schloss
    private var holdStart: Date?

    public init(screen: EditorFreezeScreen) {
        self.screen = screen
    }

    /// Zoom, Scrollen und Seitenwechsel gesperrt (beide Stufen)
    public var locksView: Bool { mode != .off }
    /// Stift und Werkzeuge nehmen Eingaben an (nur nicht beim Abpausen)
    public var acceptsInput: Bool { mode != .trace }
    /// Leisten, Seitenleiste und Hinweise sichtbar (nur nicht beim Abpausen)
    public var showsChrome: Bool { mode != .trace }

    // MARK: Stufen

    /// "Ansicht fixieren". Beim Abpausen ohne Wirkung (erst entsperren). true = Stufe gewechselt
    @discardableResult
    public func fixView() -> Bool {
        guard mode == .off else { return false }
        set(.view)
        return true
    }

    /// Cmd-L und Menue: Ansicht fixieren bzw. loesen; beim Abpausen ohne Wirkung
    @discardableResult
    public func toggleView() -> Bool {
        switch mode {
        case .off: return fixView()
        case .view: set(.off); return true
        case .trace: return false
        }
    }

    /// "Zum Abpausen einfrieren": Bildschirm bleibt an, auf Wunsch volle Helligkeit. Aus beiden anderen Stufen;
    /// ein zweiter Aufruf beim Abpausen aendert nichts. true = Stufe gewechselt
    @discardableResult
    public func startTracing(_ options: TraceOptions = TraceOptions()) -> Bool {
        guard mode != .trace else { return false }
        self.options = options
        modeBeforeTrace = mode
        savedIdleTimer = screen.idleTimerDisabled
        screen.idleTimerDisabled = true
        savedBrightness = nil
        if options.maxBrightness, screen.supportsBrightness {
            savedBrightness = screen.brightness
            if !isSuspended { screen.brightness = 1 }
        }
        holdStart = nil
        set(.trace)
        return true
    }

    /// Entsperren: vom Abpausen zurueck zur Stufe davor (Bildschirm wie vorher), von "Ansicht fixiert" ganz aus
    public func unlock() {
        switch mode {
        case .off: return
        case .view: set(.off)
        case .trace:
            restoreScreen()
            holdStart = nil
            set(modeBeforeTrace == .view ? .view : .off)
        }
    }

    /// Dokument geschlossen: alles aus, Bildschirm wie vorher
    public func end() {
        if mode == .trace { restoreScreen() }
        holdStart = nil
        isSuspended = false
        set(.off)
    }

    /// App geht in den Hintergrund: Helligkeit zurueck (der Ruhezustand gilt ohnehin nur fuer die App im Vordergrund)
    public func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        holdStart = nil
        if mode == .trace, let b = savedBrightness { screen.brightness = b }
    }

    /// App wieder vorn: beim Abpausen wieder volle Helligkeit
    public func resume() {
        guard isSuspended else { return }
        isSuspended = false
        if mode == .trace, savedBrightness != nil, screen.supportsBrightness {
            screen.brightness = 1
        }
    }

    private func restoreScreen() {
        if let idle = savedIdleTimer { screen.idleTimerDisabled = idle }
        if let b = savedBrightness, screen.supportsBrightness { screen.brightness = b }
        savedIdleTimer = nil
        savedBrightness = nil
    }

    private func set(_ m: Mode) {
        guard m != mode else { return }
        mode = m
        onChange?(m)
    }

    // MARK: Schloss halten (Entsperren beim Abpausen)

    /// Finger (oder Stift) auf dem Schloss. Nur beim Abpausen
    public func holdBegan(at date: Date = Date()) {
        guard mode == .trace else { return }
        holdStart = date
    }

    /// 0 ... 1 fuer den Fortschrittsring
    public func holdProgress(at date: Date = Date()) -> Double {
        guard mode == .trace, let start = holdStart else { return 0 }
        return min(1, max(0, date.timeIntervalSince(start) / Self.unlockHoldDuration))
    }

    /// Waehrend des Haltens (Zeitgeber): lange genug gehalten -> entsperren. true = entsperrt
    @discardableResult
    public func holdCheck(at date: Date = Date()) -> Bool {
        guard mode == .trace, holdStart != nil, holdProgress(at: date) >= 1 else { return false }
        unlock()
        return true
    }

    /// Losgelassen: lange genug -> entsperren, sonst zuruecksetzen. true = entsperrt
    @discardableResult
    public func holdEnded(at date: Date = Date()) -> Bool {
        defer { holdStart = nil }
        return holdCheck(at: date)
    }

    /// Halten abgebrochen (Geste verloren, App im Hintergrund)
    public func holdCancelled() {
        holdStart = nil
    }

    public var isHolding: Bool { holdStart != nil }
}

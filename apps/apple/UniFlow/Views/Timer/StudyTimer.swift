import SwiftUI
import UserNotifications

/// Zeitmesser aus views-doc.js (global, laeuft ueber Ansichten hinweg): Stoppuhr, Countdown, Pomodoro.
/// Offen als Kasten unten rechts (.timer-widget), geschlossen und angefangen als Pille (.timer-pill).
///
/// Zeitbasis (Pruefpunkte 241–249): Der Takt alle 500 ms zeichnet nur; die Zeit kommt aus Zeitstempeln. Solange die
/// App laeuft, zaehlt die fortlaufende Systemuhr (`CLOCK_MONOTONIC`, laeuft auch im Ruhezustand weiter und haengt
/// nicht an der Geraetezeit): Suspendierung, Sperre und ein verstelltes Datum verfaelschen nichts. Jeder Zustand
/// (Modus, laufend, Beginn als Datum, Ziel, Pomodoro-Phase) steht in den UserDefaults; nach einem Neustart (auch nach
/// einer Beendigung durch das System) rechnet die App den laufenden Abschnitt ueber das Datum nach, rueckwaerts
/// gestellte Uhren ziehen nie etwas ab. Das Ende eines Countdowns oder einer Pomodoro-Phase meldet eine lokale
/// Benachrichtigung, die beim Start eingeplant wird: Die App muss dafuer nicht im Hintergrund laufen. Die Erlaubnis
/// wird erst beim ersten Start eines Countdowns erfragt, nie beim App-Start. Endet die Phase, waehrend die App nicht
/// lief, gilt beim naechsten Oeffnen genau diese eine Phase als beendet (Countdown steht auf 0:00, Pomodoro wechselt
/// in die naechste Phase und wartet auf "Start" – wie im Web endet jede Phase mit Anhalten).
@MainActor
final class StudyTimer: ObservableObject {
    enum Mode: String, Codable { case stopwatch, countdown, pomodoro }
    struct Pomo: Equatable, Codable { var work = 25, pause = 5, phase = "work", round = 1 }

    /// Zustand in den UserDefaults (`stateKey`)
    struct Snapshot: Codable, Equatable {
        var mode: Mode
        var running: Bool
        /// verstrichene Zeit, zuletzt gesehen
        var elapsed: Double
        /// Datum, zu dem `elapsed` galt (nur bei `running`; danach laeuft die Zeit weiter)
        var seenAt: Date?
        var target: Double
        var pomo: Pomo
    }

    static let stateKey = "uniflow.timer.state"
    /// laufend hoechstens alle 10 s speichern (ein Neustart verliert so hoechstens 10 s, auch bei verstellter Uhr)
    static let persistEvery: Double = 10

    @Published private(set) var mode: Mode = .stopwatch
    @Published private(set) var running = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var target: Double = 25 * 60
    @Published private(set) var pomo = Pomo()
    @Published private(set) var open = false
    weak var toast: UFToastCenter?
    private var base: Double = 0
    /// laufender Abschnitt: Beginn nach beiden Uhren
    private var start: StudyTimerNow?
    private var ticker: Task<Void, Never>?
    /// fortlaufende Uhr beim letzten Speichern
    private var persistedAt: Double = -.infinity
    private let defaults: UserDefaults
    private let notifier: StudyTimerNotifying
    private let clock: () -> StudyTimerNow

    /// `defaults`, `notifier`, `clock`: Tests. Ein gespeicherter Zustand wird sofort wiederhergestellt.
    init(defaults: UserDefaults = .standard, notifier: StudyTimerNotifying? = nil,
         clock: @escaping () -> StudyTimerNow = StudyTimerNow.current) {
        self.defaults = defaults
        self.notifier = notifier ?? StudyTimerNotifications()
        self.clock = clock
        restore()
    }

    /// toggleTimer(open)
    func toggle(_ open: Bool? = nil) { self.open = open ?? !self.open }

    /// angezeigte Zeit: Stoppuhr vorwaerts, sonst Restzeit
    var left: Double { mode == .stopwatch ? elapsed : target - elapsed }
    var showsPill: Bool { !open && (running || elapsed > 0) }

    /// fmt(): m:ss, gerundet, nie negativ
    nonisolated static func fmt(_ s: Double) -> String {
        let v = max(0, Int(s.rounded()))
        return "\(v / 60):\(String(format: "%02d", v % 60))"
    }

    func setMode(_ m: Mode) {
        stop()
        mode = m; elapsed = 0; base = 0
        if m == .pomodoro { pomo = Pomo(); target = 25 * 60 }
        if m == .countdown { target = 25 * 60 }
        persist()
    }

    func setMinutes(_ n: Int) {
        stop()
        target = Double(n) * 60; elapsed = 0; base = 0
        persist()
    }

    func reset() {
        stop()
        elapsed = 0; base = 0
        persist()
    }

    func startPause() {
        if running {
            tick()
            stop()
            persist()
        } else {
            let now = clock()
            running = true; base = elapsed; start = now
            if mode != .stopwatch {
                notifier.requestPermissionIfNeeded()
                notifier.schedule(title: Self.notificationTitle(mode), body: endMessage, at: now.wall.addingTimeInterval(max(0, target - base)))
            }
            persist()
            if ticker == nil {                                        // setInterval(tick, 500), einmal angelegt
                ticker = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        self?.tick()
                    }
                }
            }
        }
    }

    /// Anhalten ohne zu speichern (Teil von Pause, Zuruecksetzen, Moduswechsel): verstrichene Zeit festhalten,
    /// Benachrichtigung zuruecknehmen
    private func stop() {
        running = false
        base = elapsed
        start = nil
        notifier.cancel()
    }

    /// ein Takt (alle 500 ms, beim Wechsel in den Vordergrund und beim Anhalten)
    func tick() {
        guard running, let start else { return }
        let now = clock()
        elapsed = base + max(0, now.monotonic - start.monotonic)
        finishIfDue()
        if running, now.monotonic - persistedAt >= Self.persistEvery { persist() }
    }

    /// Countdown bzw. Pomodoro-Phase zu Ende: anhalten, melden, bei Pomodoro die naechste Phase vorbereiten (sie
    /// startet erst der Mensch). Stoppuhr endet nie.
    private func finishIfDue() {
        guard mode != .stopwatch, elapsed >= target else { return }
        let message = endMessage
        running = false; elapsed = target; base = target; start = nil
        notifier.cancel()
        toast?.show(message)
        if mode == .pomodoro {
            pomo.phase = pomo.phase == "work" ? "pause" : "work"
            if pomo.phase == "work" { pomo.round += 1 }
            target = Double(pomo.phase == "work" ? pomo.work : pomo.pause) * 60
            elapsed = 0; base = 0
        }
        persist()
    }

    /// Meldung am Ende des laufenden Countdowns bzw. der laufenden Pomodoro-Phase
    var endMessage: String {
        mode == .pomodoro ? (pomo.phase == "work" ? "Pomodoro vorbei – Pause!" : "Pause vorbei – weiter geht's") : "Zeit abgelaufen"
    }

    static func notificationTitle(_ m: Mode) -> String { m == .pomodoro ? "Pomodoro" : "Countdown" }

    /// Wechsel in den Vordergrund (nach Suspendierung, Sperre): Zeit sofort nachfuehren statt auf den naechsten Takt
    /// zu warten
    func sceneBecameActive() { tick() }

    /// Wechsel in den Hintergrund: Stand sichern (das System darf die App danach jederzeit beenden)
    func sceneWillResignActive() { persist() }

    // MARK: Zustand

    var snapshot: Snapshot {
        Snapshot(mode: mode, running: running, elapsed: elapsed, seenAt: running ? clock().wall : nil, target: target, pomo: pomo)
    }

    func persist() {
        persistedAt = clock().monotonic
        if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: Self.stateKey) }
    }

    /// Nach einem Neustart: laufender Abschnitt ueber das Datum nachgerechnet (eine zurueckgestellte Uhr zieht nichts
    /// ab), dann wie ein Takt – ein inzwischen abgelaufener Countdown steht auf 0:00, eine Pomodoro-Phase wechselt.
    private func restore() {
        guard let data = defaults.data(forKey: Self.stateKey), let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        mode = s.mode; target = s.target; pomo = s.pomo
        base = s.elapsed; elapsed = s.elapsed
        guard s.running, let seenAt = s.seenAt else { return }
        let now = clock()
        base = s.elapsed + max(0, now.wall.timeIntervalSince(seenAt))
        elapsed = base
        running = true
        start = now
        finishIfDue()
        guard running else { return }
        if mode != .stopwatch {
            // die beim Start eingeplante Benachrichtigung bleibt beim System; nach einem Neustart des Geraets zur
            // Sicherheit neu einplanen (gleiche Kennung: nie zwei)
            notifier.schedule(title: Self.notificationTitle(mode), body: endMessage, at: now.wall.addingTimeInterval(max(0, target - base)))
        }
        persist()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.tick()
            }
        }
    }
}

/// Zeitpunkt nach beiden Uhren: Datum (zum Speichern) und fortlaufende Systemuhr in Sekunden (zum Rechnen, laeuft im
/// Ruhezustand weiter, unabhaengig von der Geraetezeit)
struct StudyTimerNow {
    var wall: Date
    var monotonic: Double

    static func current() -> StudyTimerNow {
        StudyTimerNow(wall: Date(), monotonic: Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000)
    }
}

/// Lokale Benachrichtigung am Ende eines Countdowns bzw. einer Pomodoro-Phase (Tests: eigener Mitschreiber)
@MainActor
protocol StudyTimerNotifying: AnyObject {
    /// Erlaubnis erfragen, falls noch nie gefragt (nur beim ersten Start eines Countdowns, nie beim App-Start)
    func requestPermissionIfNeeded()
    /// genau eine Benachrichtigung (eine neue ersetzt die alte)
    func schedule(title: String, body: String, at date: Date)
    func cancel()
}

final class StudyTimerNotifications: StudyTimerNotifying {
    static let identifier = "de.uniflow.timer.end"
    private var asked = false

    func requestPermissionIfNeeded() {
        guard !asked else { return }
        asked = true
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func schedule(title: String, body: String, at date: Date) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // ein Ausloeser braucht mindestens eine Sekunde; ein schon vergangenes Ende meldet der Takt selbst
        let interval = max(1, date.timeIntervalSinceNow)
        let request = UNNotificationRequest(identifier: Self.identifier, content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false))
        UNUserNotificationCenter.current().add(request)
    }

    func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.identifier])
    }
}

/// position: fixed; right/bottom 1rem; z-index 45 – ueber Schublade und Seiteninhalt, unter Dialogen und Meldungen
struct StudyTimerHost: ViewModifier {
    @ObservedObject var timer: StudyTimer
    let toast: UFToastCenter
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .overlay {
                ZStack(alignment: .bottomTrailing) {
                    Color.clear.allowsHitTesting(false)
                    if timer.open {
                        StudyTimerWidget(timer: timer).padding(16)
                            .transition(.opacity)                     // animation: fade .15s
                    } else if timer.showsPill {
                        StudyTimerPill(timer: timer).padding(16)
                    }
                }
                .ignoresSafeArea()
                .animation(UF.motion(.easeOut(duration: 0.15)), value: timer.open)
            }
            .onAppear { timer.toast = toast }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { timer.sceneBecameActive() } else { timer.sceneWillResignActive() }
            }
    }
}

/// .timer-widget: 260 pt breit, Rand --line, Radius --r-lg, Schatten --sh-lg, Innenabstand .8rem
struct StudyTimerWidget: View {
    @ObservedObject var timer: StudyTimer
    private let inner: CGFloat = 260 - 2 * (12.8 + ufB)

    var body: some View {
        let left = timer.left
        VStack(spacing: 0) {
            // .row.between: Die Moduswahl ist breiter als der Kasten; sie ragt wie im Web rechts hinaus,
            // der Schliessen-Knopf liegt dahinter (Schliessen auch ueber das Uhr-Symbol in der Kopfzeile)
            HStack(spacing: 9.6) {
                UFSegmented(options: [(StudyTimer.Mode.stopwatch, "Stoppuhr"), (.countdown, "Countdown"), (.pomodoro, "Pomodoro")],
                            selection: Binding(get: { timer.mode }, set: { timer.setMode($0) }))
                UFButton(icon: "x", kind: .ghost, size: .small) { timer.toggle(false) }
            }
            .fixedSize()
            .frame(width: inner, alignment: .leading)

            // .big: 2rem fett, Ziffern gleich breit, margin .3rem 0 (unten mit dem margin-top der Knopfzeile zusammengelegt)
            Text(StudyTimer.fmt(left))
                .ufFont(32, 700)
                .monospacedDigit()
                .foregroundStyle(timer.mode != .stopwatch && left <= 0 ? UF.bad : UF.text)
                .frame(maxWidth: .infinity)
                .padding(.top, 4.8)
                .padding(.bottom, timer.mode == .stopwatch ? 0 : 4.8)

            if timer.mode == .countdown {
                // .row (zentriert, gap .3rem): Die Chips schrumpfen auf die Breite von "min", der Text bricht um
                HStack(spacing: 4.8) {
                    ForEach([5, 15, 25, 45, 60], id: \.self) { n in
                        Button { timer.setMinutes(n) } label: {
                            Text("\(n)\nmin")
                                .ufFont(12.8)
                                .multilineTextAlignment(.center)
                                .fixedSize()
                                .foregroundStyle(UF.text2)
                                .padding(.vertical, 4 + ufB)
                                .padding(.horizontal, 10.4 + ufB)
                                .background(Capsule().fill(UF.surface))
                                .overlay(Capsule().strokeBorder(UF.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .fixedSize()
                .frame(width: inner)
            } else if timer.mode == .pomodoro {
                Text("\(timer.pomo.phase == "work" ? "Arbeiten" : "Pause") · Runde \(timer.pomo.round) · \(timer.pomo.work)/\(timer.pomo.pause) min")
                    .ufFont(13.12)
                    .foregroundStyle(UF.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }

            HStack(spacing: 9.6) {
                UFButton(timer.running ? "Pause" : "Start", kind: .primary, size: .small) { timer.startPause() }
                UFButton("Zurücksetzen", size: .small) { timer.reset() }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
        }
        .padding(12.8 + ufB)
        .frame(width: 260)
        .background(RoundedRectangle(cornerRadius: UF.rLg).fill(UF.surface).ufShadow(.lg))
        .overlay(RoundedRectangle(cornerRadius: UF.rLg).strokeBorder(UF.line, lineWidth: 1))
    }
}

/// .timer-pill: Akzentfarbe, weiss, rund, .4rem .8rem, fett 600; Tippen oeffnet den Kasten
struct StudyTimerPill: View {
    @ObservedObject var timer: StudyTimer

    var body: some View {
        Button { timer.toggle(true) } label: {
            Text(StudyTimer.fmt(timer.left))
                .ufFont(14.5, 600)
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.vertical, 6.4)
                .padding(.horizontal, 12.8)
                .background(Capsule().fill(UF.accent).ufShadow(.lg))
        }
        .buttonStyle(.plain)
    }
}

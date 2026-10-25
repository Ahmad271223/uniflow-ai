import SwiftUI

/// Zeitmesser aus views-doc.js (global, laeuft ueber Ansichten hinweg): Stoppuhr, Countdown, Pomodoro.
/// Offen als Kasten unten rechts (.timer-widget), geschlossen und angefangen als Pille (.timer-pill).
@MainActor
final class StudyTimer: ObservableObject {
    enum Mode: String { case stopwatch, countdown, pomodoro }
    struct Pomo: Equatable { var work = 25, pause = 5, phase = "work", round = 1 }

    @Published private(set) var mode: Mode = .stopwatch
    @Published private(set) var running = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var target: Double = 25 * 60
    @Published private(set) var pomo = Pomo()
    @Published private(set) var open = false
    weak var toast: UFToastCenter?
    private var base: Double = 0
    private var startAt = Date()
    private var ticker: Task<Void, Never>?

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
        mode = m; running = false; elapsed = 0; base = 0
        if m == .pomodoro { pomo = Pomo(); target = 25 * 60 }
        if m == .countdown { target = 25 * 60 }
    }

    func setMinutes(_ n: Int) { target = Double(n) * 60; elapsed = 0; base = 0 }

    func reset() { running = false; elapsed = 0; base = 0 }

    func startPause() {
        if running {
            running = false; base = elapsed
        } else {
            running = true; base = elapsed; startAt = Date()
            if ticker == nil {                                        // setInterval(tick, 500), einmal angelegt
                ticker = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        self?.tick(now: Date())
                    }
                }
            }
        }
    }

    /// ein Takt (alle 500 ms); `now` von aussen fuer Tests
    func tick(now: Date) {
        guard running else { return }
        elapsed = base + now.timeIntervalSince(startAt)
        guard mode != .stopwatch, elapsed >= target else { return }
        running = false; elapsed = target
        toast?.show(mode == .pomodoro ? (pomo.phase == "work" ? "Pomodoro vorbei – Pause!" : "Pause vorbei – weiter geht's") : "Zeit abgelaufen")
        if mode == .pomodoro {
            pomo.phase = pomo.phase == "work" ? "pause" : "work"
            if pomo.phase == "work" { pomo.round += 1 }
            target = Double(pomo.phase == "work" ? pomo.work : pomo.pause) * 60
            elapsed = 0; base = 0
        }
    }
}

/// position: fixed; right/bottom 1rem; z-index 45 – ueber Schublade und Seiteninhalt, unter Dialogen und Meldungen
struct StudyTimerHost: ViewModifier {
    @ObservedObject var timer: StudyTimer
    let toast: UFToastCenter

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
                .animation(.easeOut(duration: 0.15), value: timer.open)
            }
            .onAppear { timer.toast = toast }
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

import SwiftUI
import UniFlowCore

/// Fragen zum eigenen Stud.IP-Kalender ueber dem Stundenplan (nur auf dem Geraet, GET /api/timetable/studip-questions,
/// `StudIPCalendar` im Kern). Kurs belegt, aber nicht im Kalender: uebernehmen oder weglassen (bis zur Antwort nicht im
/// Stundenplan, wie in Stud.IP). Kurs mit drei oder mehr Serien je Woche: welche besuchst du (alle vorausgewaehlt,
/// abgewaehlte werden grau und geben Zeit frei). Antworten gelten fuer jeden weiteren Abgleich.
struct StudIPCalendarQuestions: View {
    let questions: JSONValue
    /// nach einer Antwort: Stundenplan neu laden
    let onAnswered: () async -> Void
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 12.8) {
            ForEach(Row.rows(questions.list("hidden"), key: "course_id")) { r in hiddenCard(r.value) }
            ForEach(Row.rows(questions.list("busy"), key: "course_id")) { r in
                BusyCourseCard(course: r.value) { attend in await answerTimes(r.value, attend: attend) }
            }
        }
        .padding(.bottom, 12.8)
    }

    static func hiddenText(_ title: String) -> String {
        "Du bist in „\(title)“ eingetragen, aber der Kurs steht nicht in deinem Stud.IP-Kalender."
    }

    private func hiddenCard(_ q: JSONValue) -> some View {
        UFCard {
            VStack(alignment: .leading, spacing: 9.6) {
                Text(Self.hiddenText(q.s("title") ?? "")).ufFont(14.5, 600).foregroundStyle(UF.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Bis du entscheidest, bleibt er wie in Stud.IP draußen.").ufFont(13.12).foregroundStyle(UF.muted)
                HStack(spacing: 9.6) {
                    UFButton("Übernehmen", kind: .primary, size: .small) { Task { await answerCourse(q, include: true) } }
                        .accessibilityIdentifier("studip.question.include")
                    UFButton("Weglassen", size: .small) { Task { await answerCourse(q, include: false) } }
                        .accessibilityIdentifier("studip.question.exclude")
                }
            }
        }
    }

    private func answerCourse(_ q: JSONValue, include: Bool) async {
        guard let api = session.api, let course = q.s("course_id") else { return }
        do {
            let r = try await api.value("/api/timetable/studip-questions/course", method: "POST", body: ["course_id": .string(course), "include": .bool(include)])
            if include {
                let n = r.i("new") ?? 0
                toast.show(n > 0 ? "\(n) \(n == 1 ? "Termin" : "Termine") übernommen" : "Kurs übernommen")
            } else {
                toast.show("Kurs weggelassen")
            }
        } catch {
            toast.show("Antwort nicht gespeichert: \(error.localizedDescription)")
        }
        await onAnswered()
    }

    private func answerTimes(_ q: JSONValue, attend: [String]) async {
        guard let api = session.api, let course = q.s("course_id") else { return }
        do {
            let r = try await api.value("/api/timetable/studip-questions/times", method: "POST",
                                        body: ["course_id": .string(course), "attend": .array(attend.map(JSONValue.string))])
            let skipped = r.i("skipped") ?? 0
            toast.show(skipped > 0 ? "\(skipped) \(skipped == 1 ? "Termin" : "Termine") als „nicht besucht“ markiert" : "Alle Termine bleiben")
        } catch {
            toast.show("Antwort nicht gespeichert: \(error.localizedDescription)")
        }
        await onAnswered()
    }
}

/// Kurs mit vielen Serien je Woche: Termine zum Abwaehlen, alle vorausgewaehlt
private struct BusyCourseCard: View {
    let course: JSONValue
    let save: ([String]) async -> Void
    @State private var attend: Set<String> = []
    @State private var started = false
    @State private var saving = false

    static func question(_ title: String, count: Int) -> String {
        "„\(title)“ steht \(count)-mal pro Woche in deinem Kalender. Welche Termine besuchst du?"
    }

    var body: some View {
        let times = course.list("times")
        UFCard {
            VStack(alignment: .leading, spacing: 9.6) {
                Text(Self.question(course.s("title") ?? "", count: times.count)).ufFont(14.5, 600).foregroundStyle(UF.text)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Row.rows(times, key: "cycle_id")) { r in
                    let id = r.value.s("cycle_id") ?? r.id
                    UFCheckbox(Self.label(r.value), isOn: Binding(get: { attend.contains(id) }, set: { on in
                        if on { attend.insert(id) } else { attend.remove(id) }
                    }))
                }
                Text("Abgewählte Termine werden grau und geben die Zeit für Lernblöcke frei.").ufFont(13.12).foregroundStyle(UF.muted)
                UFButton(saving ? "Wird gespeichert …" : "Speichern", kind: .primary, size: .small) {
                    guard !saving else { return }
                    saving = true
                    let list = times.compactMap { $0.s("cycle_id") }.filter(attend.contains)
                    Task { await save(list); saving = false }
                }
                .accessibilityIdentifier("studip.question.times.save")
            }
        }
        .onAppear {
            guard !started else { return }
            started = true
            attend = Set(times.filter { $0["attend"] != false }.compactMap { $0.s("cycle_id") })
        }
    }

    static func label(_ t: JSONValue) -> String {
        let day = ShellState.days[safe: t.i("weekday") ?? 0] ?? ""
        let room = t.s("room").flatMap { $0.isEmpty ? nil : " · \($0)" } ?? ""
        return "\(day) \(t.s("start_time") ?? "")–\(t.s("end_time") ?? "")\(room)"
    }
}

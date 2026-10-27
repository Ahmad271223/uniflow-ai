package de.uniflow.core

import java.time.LocalDate
import java.time.temporal.ChronoUnit
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Ansichten aus der lokalen Ablage, ohne Netz: Lernpakete und Aufgaben kommen immer aus den synchronisierten Zeilen
 * (so ist eine abgehakte Aufgabe sofort sichtbar, auch offline), Termine, Feiertage, Fristen und Ankuendigungen aus
 * der letzten Momentaufnahme der Server-Antwort; fehlt die, werden die Termine aus `course_events` und
 * `event_exceptions` berechnet (gleiche Regeln wie app/timetable.py::occurrences, ohne Feiertage und Semestergrenzen –
 * die kennt nur der Server). Tagesstatus und Paketstatus folgen app/study.py (calendar, _derive_status).
 *
 * Solange noch nie abgeglichen wurde (kein Cursor), zeigt die Ablage nur die Momentaufnahmen.
 */
object LocalViews {

    // ---- Lernpakete ----

    fun packages(store: LocalStore, start: String, end: String, today: LocalDate): List<StudyPackage> {
        val modules = store.rows("modules").associate { it.id to it.data }
        val tasks = store.rows("study_tasks").map { it.data }.groupBy { it.s("package_id") ?: "" }
        return store.rows("study_packages").map { it.data }
            .filter { val d = it.s("date") ?: ""; d >= start && d <= end }
            .sortedWith(compareBy({ it.s("date") }, { it.i("sort") ?: 0 }, { it.i("id") ?: 0 }))
            .map { p ->
                val ts = (tasks[p.s("id") ?: ""] ?: emptyList()).sortedWith(compareBy({ it.i("sort") ?: 0 }, { it.i("id") ?: 0 })).map { StudyTask.from(it) }
                val past = (p.s("date") ?: "") < today.toString()
                val statuses = ts.map { if (past && it.status in setOf("geplant", "in_bearbeitung")) "nachholen" else it.status }
                val status = if (ts.isEmpty()) p.s("status") ?: "geplant" else deriveStatus(statuses, past)
                StudyPackage(p.i("id") ?: 0, p.s("date") ?: "", p.s("subject") ?: "", p.s("title") ?: "", status, p.s("start_time"), p.s("end_time"),
                    p.i("planned_minutes") ?: 0, p.s("color") ?: modules[p.s("module_id") ?: ""]?.s("color"),
                    ts.map { t -> if (past && t.status in setOf("geplant", "in_bearbeitung")) t.copy(status = "nachholen") else t })
            }
    }

    /** Paketstatus aus den Aufgaben wie app/study.py::_derive_status. */
    fun deriveStatus(statuses: List<String>, past: Boolean): String {
        if (statuses.isEmpty()) return "geplant"
        val s = statuses.toSet()
        if (s.all { it in setOf("erledigt", "uebersprungen", "verschoben") }) {
            return if ("erledigt" in s) "erledigt" else if ("verschoben" in s) "verschoben" else "uebersprungen"
        }
        if ("erledigt" in s && (past || "nachholen" in s)) return "teilweise"
        if ("nachholen" in s) return "nachholen"
        if ("in_bearbeitung" in s) return "in_bearbeitung"
        return "geplant"
    }

    /** Tagesstatus wie app/study.py::calendar. */
    fun dayStatus(packages: List<StudyPackage>, date: LocalDate, today: LocalDate, learnDays: Set<Int>): String {
        if (packages.isEmpty()) return if ((date.dayOfWeek.value - 1) !in learnDays) "frei" else "leer"
        val statuses = packages.map { it.status }
        val done = packages.sumOf { p -> p.tasks.count { it.done } }
        return when {
            statuses.all { it in setOf("erledigt", "uebersprungen", "verschoben") } && "erledigt" in statuses -> "erledigt"
            "nachholen" in statuses || (date < today && statuses.any { it in setOf("geplant", "in_bearbeitung") }) -> if (done == 0) "nachholen" else "teilweise"
            "teilweise" in statuses -> "teilweise"
            "in_bearbeitung" in statuses -> "in_bearbeitung"
            else -> "geplant"
        }
    }

    /** Lerntage aus der Einstellung `free_days` (JSON-Liste, 0 = Montag; Standard [6] = Sonntag frei). */
    fun learnDays(store: LocalStore): Set<Int> {
        val free = store.setting("free_days")?.let { runCatching { (Json.parseToJsonElement(it) as JsonArray).map { d -> d.jsonPrimitive.content.toInt() } }.getOrNull() } ?: listOf(6)
        return (0..6).filter { it !in free }.toSet()
    }

    // ---- Lernkalender ----

    fun calendar(store: LocalStore, start: String, end: String, snapshot: CalendarRange?, today: LocalDate = LocalDate.now()): CalendarRange {
        if (store.cursor == null) return snapshot ?: CalendarRange(start, end, emptyList())
        val pk = packages(store, start, end, today).groupBy { it.date }
        val byDate = snapshot?.days?.associateBy { it.date } ?: emptyMap()
        val fallbackEvents = if (snapshot == null) occurrences(store, LocalDate.parse(start), LocalDate.parse(end)).groupBy { it.date } else emptyMap()
        val learn = learnDays(store)
        val days = ArrayList<CalendarDay>()
        var d = LocalDate.parse(start)
        val last = LocalDate.parse(end)
        while (!d.isAfter(last)) {
            val s = d.toString()
            val snap = byDate[s]
            val p = pk[s] ?: emptyList()
            days.add(CalendarDay(s, d.dayOfWeek.value - 1, dayStatus(p, d, today, learn), p.sumOf { it.plannedMinutes }, p,
                snap?.events ?: fallbackEvents[s] ?: emptyList(), snap?.marks ?: emptyList(), snap?.deadlines ?: emptyList(), snap?.notices ?: emptyList()))
            d = d.plusDays(1)
        }
        return CalendarRange(start, end, days)
    }

    // ---- Stundenplan ----

    fun timetable(store: LocalStore, monday: LocalDate, snapshot: TimetableWeek?): TimetableWeek? {
        if (snapshot != null) return snapshot
        if (store.cursor == null || store.count("course_events") == 0) return null
        val occ = occurrences(store, monday, monday.plusDays(6)).groupBy { it.date }
        return TimetableWeek(monday.toString(), monday.plusDays(6).toString(), (0..6).map { i ->
            val d = monday.plusDays(i.toLong()); val s = d.toString()
            TimetableDay(s, i, occ[s] ?: emptyList(), emptyList(), emptyList(), emptyList())
        }, null)
    }

    /**
     * Termine im Zeitraum aus den Serien (`course_events`) mit Ausnahmen (`event_exceptions`), wie
     * app/timetable.py::occurrences ohne Semestergrenzen, Feiertage und Bemerkungen (nur der Server kennt sie).
     */
    fun occurrences(store: LocalStore, start: LocalDate, end: LocalDate): List<EventOccurrence> {
        val modules = store.rows("modules").associate { it.id to it.data }
        val events = store.rows("course_events").map { it.data }
        if (events.isEmpty()) return emptyList()
        val exceptions = store.rows("event_exceptions").map { it.data }
        val exByEvent = exceptions.groupBy { it.s("event_id") ?: "" }.mapValues { (_, xs) -> xs.associateBy { it.s("date") ?: "" } }
        val out = ArrayList<EventOccurrence>()
        var d = start
        while (!d.isAfter(end)) {
            val di = d.toString()
            for (e in events) {
                if (!matches(e, d)) continue
                val x = exByEvent[e.s("id") ?: ""]?.get(di)
                val attend = (e.i("attend") ?: 1) != 0
                var status = if (attend) "teilnahme" else "nicht_teilnahme"
                var startT = e.s("start_time") ?: ""; var endT = e.s("end_time") ?: ""
                if (x != null) when (x.s("type")) {
                    "skip" -> status = "nicht_teilnahme"
                    "attend" -> status = "teilnahme"
                    "cancelled" -> status = "ausfall"
                    "moved", "edit" -> {
                        startT = x.s("new_start") ?: startT; endT = x.s("new_end") ?: endT
                        if (x.s("type") == "moved" && !x.s("new_date").isNullOrEmpty() && x.s("new_date") != di) status = "verschoben"
                    }
                }
                out.add(EventOccurrence(e.i("id") ?: 0, di, startT, endT, e.s("title") ?: "", e.s("kind") ?: "vorlesung", e.s("room"), status,
                    e.s("color") ?: modules[e.s("module_id") ?: ""]?.s("color") ?: "#4f5bd5", x?.s("note")))
            }
            // hierher verschobene Termine anderer Tage
            for (x in exceptions.filter { it.s("type") == "moved" && it.s("new_date") == di && it.s("date") != di }) {
                val e = events.firstOrNull { it.s("id") == x.s("event_id") } ?: continue
                out.add(EventOccurrence(e.i("id") ?: 0, di, x.s("new_start") ?: e.s("start_time") ?: "", x.s("new_end") ?: e.s("end_time") ?: "", e.s("title") ?: "",
                    e.s("kind") ?: "vorlesung", e.s("room"), "teilnahme", e.s("color") ?: modules[e.s("module_id") ?: ""]?.s("color") ?: "#4f5bd5", x.s("note")))
            }
            d = d.plusDays(1)
        }
        return out.sortedWith(compareBy({ it.date }, { it.start }))
    }

    /** Wie app/timetable.py::_matches, ohne Semester als Standardgrenzen (offene Enden). */
    fun matches(e: JsonObject, d: LocalDate): Boolean {
        val iso = d.toString()
        val from = e.s("date_from")?.takeIf { it.isNotEmpty() }
        val to = e.s("date_to")?.takeIf { it.isNotEmpty() }
        if (from != null && iso < from) return false
        if (to != null && iso > to) return false
        val rrule = e.s("rrule") ?: "weekly"
        if (rrule == "once") return iso == (from ?: "")
        if (d.dayOfWeek.value - 1 != (e.i("weekday") ?: -1)) return false
        if (rrule == "biweekly") {
            val anchor = from?.let { runCatching { LocalDate.parse(it) }.getOrNull() } ?: return true
            return (ChronoUnit.DAYS.between(anchor, d) / 7) % 2 == 0L
        }
        return true
    }

    // ---- Uebersicht ----

    /** Uebersicht offline: Momentaufnahme mit den heutigen Lernpaketen aus der Ablage; ohne Momentaufnahme nur das Lokale. */
    fun dashboard(store: LocalStore, snapshot: Dashboard?, today: LocalDate = LocalDate.now()): Dashboard? {
        if (store.cursor == null) return snapshot
        val s = today.toString()
        val todayPackages = packages(store, s, s, today)
        if (snapshot != null) return snapshot.copy(todayPackages = todayPackages)
        val events = occurrences(store, today, today)
        return Dashboard(events, todayPackages, emptyList(), emptyList(), emptyList(), 0, null, store.lastSyncAt, false, null)
    }
}

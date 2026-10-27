package de.uniflow.core

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/** Antworten des Servers als leicht lesbare Modelle; unbekannte Felder stoeren nicht (JsonObject bleibt erreichbar). */

data class LibraryFile(val id: String, val name: String, val title: String, val kind: String, val moduleId: Int?, val subject: String?,
                       val docType: String?, val downloadedAt: String?, val chdate: Long?, val raw: JsonObject,
                       // Direkter Download auf das Geraet (University.kt): Adresse bei der Hochschule, Quelle
                       // ("studip" | "learnweb" | "own" = eigenes Dokument ohne Hochschulquelle) und Fingerabdruck des Inhalts
                       val downloadUrl: String? = null, val source: String = "studip", val contentSha256: String? = null) {
    val isPdf: Boolean get() = kind == "pdf"
    val isLocal: Boolean get() = !downloadedAt.isNullOrEmpty()

    companion object {
        fun from(o: JsonObject): LibraryFile = LibraryFile(
            id = o.s("id") ?: "", name = o.s("name") ?: "", title = o.s("title") ?: o.s("ai_title") ?: o.s("name") ?: "",
            kind = o.s("kind") ?: "pdf", moduleId = o.i("module_id"), subject = o.s("subject"), docType = o.s("doc_type"),
            downloadedAt = o.s("downloaded_at"), chdate = o.s("chdate")?.toDoubleOrNull()?.toLong(), raw = o,
            downloadUrl = o.s("download_url"),
            // fehlt "source": eigene Dokumente haengen am Pseudo-Kurs __user__, alles andere kommt aus Stud.IP
            source = o.s("source") ?: if (o.s("course_id") == "__user__") "own" else "studip",
            contentSha256 = o.s("content_sha256"),
        )
    }
}

data class Module(val id: Int, val name: String, val color: String?, val raw: JsonObject) {
    companion object {
        fun from(o: JsonObject) = Module(o.i("id") ?: 0, o.s("name") ?: "", o.s("color"), o)
    }
}

data class Library(val files: List<LibraryFile>, val modules: List<Module>) {
    fun byModule(): Map<Module?, List<LibraryFile>> = files.groupBy { f -> modules.firstOrNull { it.id == f.moduleId } }

    companion object {
        fun from(j: JsonElement): Library = Library(j.list("files").map { LibraryFile.from(it) }, j.list("modules").map { Module.from(it) })
    }
}

/** Markierung eines Kalendertags (Feiertag, Pause, vorlesungsfrei) – Felder marks/deadlines/notices aus docs/HILDESHEIM.md. */
data class DayMark(val kind: String, val label: String)
data class Deadline(val title: String, val kindLabel: String, val time: String?, val url: String?, val courseTitle: String?, val overdue: Boolean)
data class Notice(val title: String, val kindLabel: String, val time: String?, val snippet: String?, val url: String?)

fun marksOf(o: JsonObject): List<DayMark> = o.list("marks").map { DayMark(it.s("kind") ?: "", it.s("label") ?: "") }
fun deadlinesOf(o: JsonObject): List<Deadline> = o.list("deadlines").map {
    Deadline(it.s("title") ?: "", it.s("kind_label") ?: "Frist", it.s("time"), it.s("url"), it.s("course_title"), it.b("overdue"))
}
fun noticesOf(o: JsonObject): List<Notice> = o.list("notices").map {
    Notice(it.s("title") ?: "", it.s("kind_label") ?: "Termin", it.s("time"), it.s("snippet"), it.s("url"))
}

data class EventOccurrence(val eventId: Int, val date: String, val start: String, val end: String, val title: String, val kind: String,
                           val room: String?, val status: String, val color: String?, val note: String?) {
    companion object {
        fun from(o: JsonObject) = EventOccurrence(o.i("event_id") ?: 0, o.s("date") ?: "", o.s("start") ?: "", o.s("end") ?: "",
            o.s("title") ?: "", o.s("kind") ?: "vorlesung", o.s("room"), o.s("status") ?: "teilnahme", o.s("color"), o.s("note"))
    }
}

data class TimetableDay(val date: String, val weekday: Int, val events: List<EventOccurrence>, val marks: List<DayMark>,
                        val deadlines: List<Deadline>, val notices: List<Notice>)

data class TimetableWeek(val start: String, val end: String, val days: List<TimetableDay>, val termName: String?) {
    companion object {
        fun from(j: JsonElement): TimetableWeek = TimetableWeek(j.s("start") ?: "", j.s("end") ?: "", j.list("days").map { d ->
            TimetableDay(d.s("date") ?: "", d.i("weekday") ?: 0, d.list("events").map { EventOccurrence.from(it) }, marksOf(d), deadlinesOf(d), noticesOf(d))
        }, j.o("term").s("name"))
    }
}

data class StudyTask(val id: Int, val title: String, val type: String, val status: String, val estMinutes: Int, val fileId: String?) {
    val done: Boolean get() = status == "erledigt"

    companion object {
        fun from(o: JsonObject) = StudyTask(o.i("id") ?: 0, o.s("title") ?: "", o.s("type") ?: "frei", o.s("status") ?: "geplant",
            o.i("est_minutes") ?: 0, o.s("file_id"))
    }
}

data class StudyPackage(val id: Int, val date: String, val subject: String, val title: String, val status: String, val startTime: String?,
                        val endTime: String?, val plannedMinutes: Int, val color: String?, val tasks: List<StudyTask>) {
    companion object {
        fun from(o: JsonObject) = StudyPackage(o.i("id") ?: 0, o.s("date") ?: "", o.s("subject") ?: "", o.s("title") ?: "",
            o.s("status") ?: "geplant", o.s("start_time"), o.s("end_time"), o.i("planned_minutes") ?: 0, o.s("color"),
            o.list("tasks").map { StudyTask.from(it) })
    }
}

data class CalendarDay(val date: String, val weekday: Int, val status: String, val minutes: Int, val packages: List<StudyPackage>,
                       val events: List<EventOccurrence>, val marks: List<DayMark>, val deadlines: List<Deadline>, val notices: List<Notice>)

data class CalendarRange(val start: String, val end: String, val days: List<CalendarDay>) {
    companion object {
        fun from(j: JsonElement): CalendarRange = CalendarRange(j.s("start") ?: "", j.s("end") ?: "", j.list("days").map { d ->
            CalendarDay(d.s("date") ?: "", d.i("weekday") ?: 0, d.s("status") ?: "leer", d.i("minutes") ?: 0,
                d.list("packages").map { StudyPackage.from(it) }, d.list("events").map { EventOccurrence.from(it) },
                marksOf(d), deadlinesOf(d), noticesOf(d))
        })
    }
}

data class UpcomingItem(val date: String, val time: String?, val kind: String, val kindLabel: String?, val title: String, val courseTitle: String?,
                        val url: String?, val overdue: Boolean)

data class Announcement(val id: String, val title: String, val text: String, val postedAt: String, val courseTitle: String?, val source: String,
                        val url: String?, val upcoming: List<JsonObject>)

data class Dashboard(val todayEvents: List<EventOccurrence>, val todayPackages: List<StudyPackage>, val upcoming: List<UpcomingItem>,
                     val announcements: List<Announcement>, val newFiles: List<LibraryFile>, val newTotal: Int, val lastSyncMessage: String?,
                     val lastSyncAt: String?, val bgRunning: Boolean, val bgMessage: String?) {
    companion object {
        fun from(j: JsonElement): Dashboard {
            val today = j.o("today")
            val sync = j.o("last_sync")
            val bg = j.o("bg")
            return Dashboard(
                todayEvents = today.list("events").map { EventOccurrence.from(it) },
                todayPackages = today.list("packages").map { StudyPackage.from(it) },
                upcoming = j.list("upcoming").map {
                    UpcomingItem(it.s("date") ?: "", it.s("time"), it.s("kind") ?: "", it.s("kind_label"), it.s("title") ?: "",
                        it.s("course_title"), it.s("url"), it.b("overdue"))
                },
                announcements = j.list("announcements").map {
                    Announcement(it.s("id") ?: "", it.s("title") ?: "", it.s("text") ?: "", it.s("posted_at") ?: "", it.s("course_title"),
                        it.s("source") ?: "", it.s("url"), it.list("upcoming"))
                },
                newFiles = j.list("new_files").map { LibraryFile.from(it) },
                newTotal = j.i("new_total") ?: 0,
                lastSyncMessage = sync.s("message"), lastSyncAt = sync.s("finished_at"),
                bgRunning = bg.b("running"), bgMessage = bg.s("message"),
            )
        }
    }
}

/** Lesbare Beschriftungen wie in der Web-Oberflaeche. */
object Labels {
    val kind = mapOf("vorlesung" to "Vorlesung", "uebung" to "Übung", "hoersaaluebung" to "Hörsaalübung", "gruppenuebung" to "Gruppenübung",
        "tutorium" to "Tutorium", "labor" to "Labor", "seminar" to "Seminar", "sonstiges" to "Sonstiges", "persoenlich" to "Persönlich")
    val status = mapOf("geplant" to "Geplant", "in_bearbeitung" to "In Bearbeitung", "erledigt" to "Erledigt", "teilweise" to "Teilweise erledigt",
        "nachholen" to "Nachholen", "verschoben" to "Verschoben", "uebersprungen" to "Übersprungen", "frei" to "Frei", "leer" to "Nichts geplant")
    val occurrence = mapOf("teilnahme" to "", "nicht_teilnahme" to "nicht besucht", "ausfall" to "fällt aus", "verschoben" to "verschoben")
    val taskType = mapOf("vorlesung" to "Vorlesung", "uebung" to "Übung", "test" to "Wochentest", "wiederholung" to "Wiederholung", "frei" to "Lernen")
}

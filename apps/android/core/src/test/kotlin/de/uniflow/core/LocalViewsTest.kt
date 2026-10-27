package de.uniflow.core

import java.time.LocalDate
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject

/** Ansichten aus der Ablage ohne Netz: Lernpakete mit Tagesstatus, Termine aus Serien und Ausnahmen, Uebersicht. */
class LocalViewsTest {
    private val today = LocalDate.parse("2026-10-28")       // Mittwoch
    private fun obj(vararg p: Pair<String, Any?>) = ApiClient.obj(*p)

    private fun seeded(): LocalStore {
        val s = LocalStore(JdbcSqlDb.memory(), "test-device")
        s.applying {
            s.putServerRow("modules", "1", obj("id" to 1, "name" to "Mathe I", "color" to "#4f5bd5"), 1, "t", null)
            s.putServerRow("study_packages", "10", obj("id" to 10, "date" to "2026-10-28", "module_id" to 1, "subject" to "Mathe I", "title" to "Woche 3", "planned_minutes" to 60, "status" to "geplant", "sort" to 0), 1, "t", null)
            s.putServerRow("study_packages", "11", obj("id" to 11, "date" to "2026-10-26", "module_id" to 1, "subject" to "Mathe I", "title" to "Woche 2", "planned_minutes" to 30, "status" to "geplant"), 1, "t", null)
            s.putServerRow("study_tasks", "100", obj("id" to 100, "package_id" to 10, "type" to "uebung", "title" to "Blatt 3", "est_minutes" to 30, "status" to "geplant", "sort" to 1), 1, "t", null)
            s.putServerRow("study_tasks", "101", obj("id" to 101, "package_id" to 10, "type" to "vorlesung", "title" to "VL 3", "est_minutes" to 30, "status" to "geplant", "sort" to 0), 1, "t", null)
            s.putServerRow("study_tasks", "102", obj("id" to 102, "package_id" to 11, "type" to "uebung", "title" to "Blatt 2", "est_minutes" to 30, "status" to "geplant"), 1, "t", null)
            s.putServerRow("course_events", "5", obj("id" to 5, "module_id" to 1, "title" to "Analysis", "kind" to "vorlesung", "weekday" to 2, "start_time" to "10:00", "end_time" to "12:00", "room" to "A1", "rrule" to "weekly", "attend" to 1), 1, "t", null)
            s.putServerRow("course_events", "6", obj("id" to 6, "title" to "Übung", "kind" to "uebung", "weekday" to 4, "start_time" to "08:00", "end_time" to "10:00", "rrule" to "biweekly", "date_from" to "2026-10-23", "attend" to 1), 1, "t", null)
            s.putServerRow("course_events", "7", obj("id" to 7, "title" to "Klausurbesprechung", "kind" to "sonstiges", "weekday" to 0, "start_time" to "14:00", "end_time" to "15:00", "rrule" to "once", "date_from" to "2026-10-26", "attend" to 1), 1, "t", null)
            s.putServerRow("event_exceptions", "50", obj("id" to 50, "event_id" to 5, "date" to "2026-11-04", "type" to "cancelled", "note" to "Dienstreise"), 1, "t", null)
            s.putServerRow("event_exceptions", "51", obj("id" to 51, "event_id" to 7, "date" to "2026-10-26", "type" to "moved", "new_date" to "2026-10-27", "new_start" to "16:00", "new_end" to "17:00"), 1, "t", null)
            s.putServerRow("settings", "free_days", obj("key" to "free_days", "value" to "[5,6]"), 1, "t", null)
        }
        s.cursor = "c1"
        return s
    }

    @Test
    fun calendarComesFromTheStoreAndReflectsLocalChanges() {
        val s = seeded()
        var cal = LocalViews.calendar(s, "2026-10-26", "2026-11-01", null, today)
        assertEquals(7, cal.days.size)
        val wed = cal.days.first { it.date == "2026-10-28" }
        assertEquals("geplant", wed.status); assertEquals(60, wed.minutes)
        assertEquals(listOf("VL 3", "Blatt 3"), wed.packages.single().tasks.map { it.title }, "Aufgaben nach sort")
        assertEquals("#4f5bd5", wed.packages.single().color, "Farbe des Moduls")
        assertEquals(listOf("Analysis"), wed.events.map { it.title }, "ohne Momentaufnahme Termine aus den Serien")
        assertEquals("nachholen", cal.days.first { it.date == "2026-10-26" }.status, "vergangenes Paket mit offener Aufgabe")
        assertEquals("nachholen", cal.days.first { it.date == "2026-10-26" }.packages.single().tasks.single().status)
        assertEquals("frei", cal.days.first { it.date == "2026-10-31" }.status, "Samstag frei laut free_days")
        assertEquals("leer", cal.days.first { it.date == "2026-10-29" }.status)

        // Abhaken offline: sofort sichtbar, Paket- und Tagesstatus abgeleitet
        s.update("study_tasks", "100", obj("status" to "erledigt"))
        cal = LocalViews.calendar(s, "2026-10-26", "2026-11-01", null, today)
        assertEquals("geplant", cal.days.first { it.date == "2026-10-28" }.status, "ein Teil erledigt, Tag noch offen")
        s.update("study_tasks", "101", obj("status" to "erledigt"))
        cal = LocalViews.calendar(s, "2026-10-26", "2026-11-01", null, today)
        assertEquals("erledigt", cal.days.first { it.date == "2026-10-28" }.status)
        assertEquals("erledigt", cal.days.first { it.date == "2026-10-28" }.packages.single().status)
        s.update("study_tasks", "102", obj("status" to "erledigt"))
        assertEquals("erledigt", LocalViews.calendar(s, "2026-10-26", "2026-10-26", null, today).days.single().status)

        // Mit Momentaufnahme: Feiertage/Fristen/Termine aus ihr, Pakete weiter aus der Ablage
        val snap = CalendarRange.from(Json.parseToJsonElement("""{"start":"2026-10-26","end":"2026-11-01","days":[{"date":"2026-10-28","weekday":2,"status":"geplant","minutes":0,"packages":[{"id":999,"date":"2026-10-28","subject":"alt","title":"vom Server","status":"geplant","planned_minutes":5,"tasks":[]}],
            "events":[{"event_id":9,"date":"2026-10-28","start":"08:00","end":"09:00","title":"Vom Server","kind":"seminar","status":"teilnahme"}],"marks":[{"kind":"feiertag","label":"Reformationstag"}],"deadlines":[],"notices":[]}]}"""))
        cal = LocalViews.calendar(s, "2026-10-26", "2026-11-01", snap, today)
        val w = cal.days.first { it.date == "2026-10-28" }
        assertEquals("Woche 3", w.packages.single().title); assertEquals(listOf("Vom Server"), w.events.map { it.title }); assertEquals("Reformationstag", w.marks.single().label)
        assertTrue(cal.days.first { it.date == "2026-10-29" }.events.isEmpty(), "Tag ohne Eintrag in der Momentaufnahme: keine erfundenen Termine")

        // Ohne Abgleich (kein Cursor): nur die Momentaufnahme
        val fresh = LocalStore(JdbcSqlDb.memory(), "x")
        assertEquals(snap, LocalViews.calendar(fresh, "2026-10-26", "2026-11-01", snap, today))
        assertTrue(LocalViews.calendar(fresh, "2026-10-26", "2026-11-01", null, today).days.isEmpty())
    }

    @Test
    fun deriveStatusFollowsTheServer() {
        assertEquals("geplant", LocalViews.deriveStatus(emptyList(), false))
        assertEquals("erledigt", LocalViews.deriveStatus(listOf("erledigt", "uebersprungen"), false))
        assertEquals("verschoben", LocalViews.deriveStatus(listOf("verschoben", "uebersprungen"), false))
        assertEquals("uebersprungen", LocalViews.deriveStatus(listOf("uebersprungen"), false))
        assertEquals("teilweise", LocalViews.deriveStatus(listOf("erledigt", "geplant"), true))
        assertEquals("teilweise", LocalViews.deriveStatus(listOf("erledigt", "nachholen"), false))
        assertEquals("geplant", LocalViews.deriveStatus(listOf("erledigt", "geplant"), false))
        assertEquals("nachholen", LocalViews.deriveStatus(listOf("nachholen", "geplant"), false))
        assertEquals("in_bearbeitung", LocalViews.deriveStatus(listOf("in_bearbeitung", "geplant"), false))
    }

    @Test
    fun occurrencesApplySeriesAndExceptions() {
        val s = seeded()
        val monday = LocalDate.parse("2026-10-26")
        val week = LocalViews.timetable(s, monday, null)!!
        assertEquals(7, week.days.size); assertNull(week.termName)
        val byDate = week.days.associateBy { it.date }
        assertEquals(listOf("Analysis"), byDate["2026-10-28"]!!.events.map { it.title })
        assertEquals("A1", byDate["2026-10-28"]!!.events.single().room)
        assertEquals("verschoben", byDate["2026-10-26"]!!.events.single().status, "einmaliger Termin ist verschoben (die Ansicht blendet ihn aus)")
        val moved = byDate["2026-10-27"]!!.events.single()
        assertEquals("Klausurbesprechung" to "16:00", moved.title to moved.start)
        assertTrue(byDate["2026-10-30"]!!.events.isEmpty(), "zweiwoechig ab 23.10.: 30.10. nicht, 6.11. ja")
        val next = LocalViews.timetable(s, monday.plusWeeks(1), null)!!.days.associateBy { it.date }
        assertEquals("ausfall", next["2026-11-04"]!!.events.single().status); assertEquals("Dienstreise", next["2026-11-04"]!!.events.single().note)
        assertEquals(listOf("Übung"), next["2026-11-06"]!!.events.map { it.title })

        // Momentaufnahme hat Vorrang; ohne Abgleich oder ohne Serien gibt es nichts
        val snap = TimetableWeek("2026-10-26", "2026-11-01", emptyList(), "WiSe 26/27")
        assertEquals(snap, LocalViews.timetable(s, monday, snap))
        assertNull(LocalViews.timetable(LocalStore(JdbcSqlDb.memory(), "x"), monday, null))
    }

    @Test
    fun biweeklyRuleCountsFromTheAnchor() {
        val e: JsonObject = obj("weekday" to 4, "rrule" to "biweekly", "date_from" to "2026-10-23")
        assertTrue(LocalViews.matches(e, LocalDate.parse("2026-10-23")))
        assertTrue(!LocalViews.matches(e, LocalDate.parse("2026-10-30")))
        assertTrue(LocalViews.matches(e, LocalDate.parse("2026-11-06")))
        assertTrue(!LocalViews.matches(e, LocalDate.parse("2026-10-16")), "vor date_from")
        assertTrue(!LocalViews.matches(obj("weekday" to 4, "rrule" to "weekly", "date_to" to "2026-10-30"), LocalDate.parse("2026-11-06")), "nach date_to")
        assertTrue(LocalViews.matches(obj("weekday" to 4, "rrule" to "weekly"), LocalDate.parse("2026-11-06")), "offene Enden ohne Semester")
    }

    @Test
    fun dashboardTakesTodaysPackagesFromTheStore() {
        val s = seeded()
        s.update("study_tasks", "100", obj("status" to "erledigt"))
        val snap = Dashboard(emptyList(), listOf(StudyPackage(999, "2026-10-28", "alt", "vom Server", "geplant", null, null, 5, null, emptyList())), emptyList(), emptyList(), emptyList(), 3, "ok", "2026-10-27T08:00", false, null)
        val d = LocalViews.dashboard(s, snap, today)!!
        assertEquals("Woche 3", d.todayPackages.single().title); assertTrue(d.todayPackages.single().tasks.first { it.id == 100 }.done)
        assertEquals(3, d.newTotal, "Rest aus der Momentaufnahme")
        val local = LocalViews.dashboard(s, null, today)!!
        assertEquals(listOf("Analysis"), local.todayEvents.map { it.title }); assertEquals(1, local.todayPackages.size)
        assertEquals(snap, LocalViews.dashboard(LocalStore(JdbcSqlDb.memory(), "x"), snap, today), "ohne Abgleich die Momentaufnahme")
        assertNull(LocalViews.dashboard(LocalStore(JdbcSqlDb.memory(), "x"), null, today))
        assertNotNull(LocalViews.learnDays(s)); assertEquals(setOf(0, 1, 2, 3, 4), LocalViews.learnDays(s))
    }
}

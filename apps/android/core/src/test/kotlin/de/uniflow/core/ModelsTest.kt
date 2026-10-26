package de.uniflow.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.serialization.json.Json

/** Antwortformen des Servers (Bibliothek, Stundenplan, Lernkalender, Uebersicht) in die Modelle der App. */
class ModelsTest {

    @Test
    fun libraryGroupsByModuleAndKeepsUnknownFields() {
        val j = Json.parseToJsonElement("""{"files":[
            {"id":"f1","name":"Folien 1.pdf","title":"Folien 1","kind":"pdf","module_id":3,"subject":"Mathe","doc_type":"vorlesung","downloaded_at":"2026-10-26T10:00:00","chdate":1793000000,"extra":1},
            {"id":"u1","name":"Notizbuch","kind":"notebook","module_id":null},
            {"id":"f2","name":"Blatt.pdf","kind":"pdf","module_id":9,"downloaded_at":null}],
            "modules":[{"id":3,"name":"Mathe I","color":"#4f5bd5"}],"folders":[],"trash":[]}""")
        val lib = Library.from(j)
        assertEquals(3, lib.files.size)
        assertEquals("Folien 1", lib.files[0].title)
        assertTrue(lib.files[0].isPdf && lib.files[0].isLocal && !lib.files[2].isLocal)
        assertEquals(1793000000L, lib.files[0].chdate)
        val groups = lib.byModule()
        assertEquals(listOf("f1"), groups[lib.modules[0]]!!.map { it.id })
        assertEquals(2, groups[null]!!.size)
        assertEquals("1", lib.files[0].raw["extra"].toString())
    }

    @Test
    fun timetableWeekWithMarksDeadlinesNotices() {
        val j = Json.parseToJsonElement("""{"start":"2026-12-21","end":"2026-12-27","term":{"name":"WiSe 2026/27"},"days":[
            {"date":"2026-12-21","weekday":0,"events":[{"event_id":5,"date":"2026-12-21","start":"10:00","end":"12:00","title":"Mathe I","kind":"vorlesung","room":"F 102","status":"teilnahme","color":"#111"}],
             "packages":[],"marks":[],"deadlines":[{"title":"Blatt 7","kind_label":"Abgabe","time":"23:59","url":"https://lw/x","course_title":"Mathe I","overdue":false}],"notices":[]},
            {"date":"2026-12-24","weekday":3,"events":[{"event_id":5,"start":"10:00","end":"12:00","title":"Mathe I","status":"ausfall","note":"Weihnachtspause"}],
             "marks":[{"kind":"pause","label":"Weihnachtspause"}],"deadlines":[],"notices":[{"title":"Hinweis","kind_label":"Ausfall?","time":null,"snippet":"faellt aus","url":null}]}]}""")
        val w = TimetableWeek.from(j)
        assertEquals("WiSe 2026/27", w.termName)
        assertEquals(2, w.days.size)
        assertEquals("F 102", w.days[0].events[0].room)
        assertEquals("Abgabe", w.days[0].deadlines[0].kindLabel)
        assertEquals("ausfall", w.days[1].events[0].status)
        assertEquals("Weihnachtspause", w.days[1].marks[0].label)
        assertEquals("Ausfall?", w.days[1].notices[0].kindLabel)
        assertEquals("fällt aus", Labels.occurrence["ausfall"])
    }

    @Test
    fun calendarRangeWithPackagesAndTasks() {
        val j = Json.parseToJsonElement("""{"start":"2026-11-02","end":"2026-11-03","days":[
            {"date":"2026-11-02","weekday":0,"status":"geplant","minutes":90,"events":[],"marks":[],"deadlines":[],"notices":[],
             "packages":[{"id":7,"date":"2026-11-02","subject":"Mathe I","title":"Woche 3","status":"geplant","start_time":"14:00","end_time":"15:30","planned_minutes":90,"color":"#4f5bd5",
               "tasks":[{"id":70,"title":"Blatt 3","type":"uebung","status":"erledigt","est_minutes":45,"file_id":"f1"},{"id":71,"title":"Folien","type":"vorlesung","status":"geplant","est_minutes":45}]}]},
            {"date":"2026-11-03","weekday":1,"status":"frei","minutes":0,"packages":[],"events":[],"marks":[{"kind":"feiertag","label":"Testtag"}]}]}""")
        val c = CalendarRange.from(j)
        assertEquals(2, c.days.size)
        val p = c.days[0].packages[0]
        assertEquals("Woche 3", p.title)
        assertEquals(listOf(true, false), p.tasks.map { it.done })
        assertEquals("f1", p.tasks[0].fileId)
        assertEquals("Testtag", c.days[1].marks[0].label)
        assertEquals("Frei", Labels.status["frei"])
    }

    @Test
    fun dashboardParsesTheFieldsTheHomeScreenNeeds() {
        val j = Json.parseToJsonElement("""{"today":{"date":"2026-10-26","status":"leer","events":[{"event_id":1,"start":"10:00","end":"12:00","title":"Kunst","status":"teilnahme"}],"packages":[]},
            "upcoming":[{"date":"2026-11-04","time":"23:59","kind":"abgabe","kind_label":"Abgabe","title":"Eigenständigkeitserklärung","course_title":"BWL 2","url":"https://lw/a","deadline_id":"lw-ev-1","overdue":false}],
            "announcements":[{"id":"lw-post-1","title":"Raum","text":"Ab 4.11. in Raum 4.","posted_at":"2026-10-05T09:00:00+02:00","course_title":"BWL 2","source":"learnweb","url":"https://lw/d","upcoming":[{"date":"2026-11-04","kind":"raum"}]}],
            "new_files":[{"id":"f9","name":"x.pdf","kind":"pdf"}],"new_total":12,"last_sync":{"finished_at":"2026-10-26T10:30:00","message":"0 neue Dateien"},"bg":{"running":true,"message":"Sync: wartet"}}""")
        val d = Dashboard.from(j)
        assertEquals("Kunst", d.todayEvents[0].title)
        assertEquals("Abgabe", d.upcoming[0].kindLabel)
        assertEquals("learnweb", d.announcements[0].source)
        assertEquals(1, d.announcements[0].upcoming.size)
        assertEquals(12, d.newTotal)
        assertTrue(d.bgRunning && d.bgMessage == "Sync: wartet")
        assertEquals("0 neue Dateien", d.lastSyncMessage)
    }
}

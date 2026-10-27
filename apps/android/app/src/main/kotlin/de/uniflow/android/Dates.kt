package de.uniflow.android

import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/** Datumshilfen der Oberflaeche (reines Kotlin, im JVM-Test pruefbar). */
object Dates {
    private val iso: DateTimeFormatter = DateTimeFormatter.ISO_LOCAL_DATE
    val weekdays = listOf("Mo", "Di", "Mi", "Do", "Fr", "Sa", "So")
    val weekdaysLong = listOf("Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag")

    fun today(): LocalDate = LocalDate.now()
    fun mondayOf(d: LocalDate): LocalDate = d.minusDays(((d.dayOfWeek.value - DayOfWeek.MONDAY.value) % 7).toLong())
    fun parse(s: String): LocalDate = LocalDate.parse(s.take(10), iso)
    fun format(d: LocalDate): String = d.format(iso)

    /** "Mo., 02.11." wie in der Web-Oberflaeche. */
    fun short(s: String): String = runCatching { parse(s) }.map { "${weekdays[it.dayOfWeek.value - 1]}., ${"%02d.%02d.".format(it.dayOfMonth, it.monthValue)}" }.getOrDefault(s)

    fun weekLabel(monday: LocalDate): String {
        val sunday = monday.plusDays(6)
        return "${monday.dayOfMonth}.${monday.monthValue}. – ${sunday.dayOfMonth}.${sunday.monthValue}.${sunday.year}"
    }

    fun minutes(m: Int): String = if (m >= 60) "${m / 60} h" + (if (m % 60 != 0) " ${m % 60} min" else "") else "$m min"

    /** Zeitpunkt in Sekunden seit 1970 als "27.10.2026, 14:03" in der Zeitzone des Geraets. */
    fun dateTime(epochSeconds: Long, zone: ZoneId = ZoneId.systemDefault()): String =
        Instant.ofEpochSecond(epochSeconds).atZone(zone).format(DateTimeFormatter.ofPattern("dd.MM.yyyy, HH:mm"))
}

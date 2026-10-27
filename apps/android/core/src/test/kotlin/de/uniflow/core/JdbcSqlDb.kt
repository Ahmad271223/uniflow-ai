package de.uniflow.core

import java.sql.Connection
import java.sql.DriverManager
import java.sql.PreparedStatement

/** SqlDb fuer den JVM-Test mit sqlite-jdbc (echtes SQLite, gleiche Trigger wie auf dem Geraet). */
class JdbcSqlDb(url: String) : SqlDb {
    private val conn: Connection = DriverManager.getConnection(url)
    private var depth = 0

    private fun bind(st: PreparedStatement, args: List<Any?>) {
        args.forEachIndexed { i, a ->
            when (a) {
                null -> st.setNull(i + 1, java.sql.Types.NULL)
                is Int -> st.setInt(i + 1, a)
                is Long -> st.setLong(i + 1, a)
                is Boolean -> st.setInt(i + 1, if (a) 1 else 0)
                else -> st.setString(i + 1, a.toString())
            }
        }
    }

    override fun exec(sql: String, args: List<Any?>) {
        conn.prepareStatement(sql).use { st -> bind(st, args); st.executeUpdate() }
    }

    override fun query(sql: String, args: List<Any?>): List<Map<String, Any?>> =
        conn.prepareStatement(sql).use { st ->
            bind(st, args)
            st.executeQuery().use { rs ->
                val meta = rs.metaData
                val names = (1..meta.columnCount).map { meta.getColumnLabel(it) }
                val out = ArrayList<Map<String, Any?>>()
                while (rs.next()) out.add(names.withIndex().associate { (i, n) -> n to rs.getObject(i + 1) })
                out
            }
        }

    override fun <T> transaction(block: () -> T): T {
        if (depth > 0) { depth++; try { return block() } finally { depth-- } }
        conn.autoCommit = false
        depth = 1
        try {
            val r = block(); conn.commit(); return r
        } catch (e: Throwable) {
            conn.rollback(); throw e
        } finally {
            depth = 0; conn.autoCommit = true
        }
    }

    override fun close() { conn.close() }

    companion object {
        fun memory() = JdbcSqlDb("jdbc:sqlite::memory:")
        fun file(path: java.io.File) = JdbcSqlDb("jdbc:sqlite:" + path.absolutePath.replace('\\', '/'))
    }
}

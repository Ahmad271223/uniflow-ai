package de.uniflow.core

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/** UniFlow-Konto (Vertrag G1, packages/shared-contracts/fixtures/account/contract.json). */
data class User(val id: String, val email: String, val university: String, val plan: String, val role: String,
                val emailVerified: Boolean) {
    companion object {
        fun from(o: JsonElement?): User = User(
            id = o.s("id") ?: "", email = o.s("email") ?: "", university = o.s("university") ?: "luh",
            plan = o.s("plan") ?: "free", role = o.s("role") ?: "user", emailVerified = o.b("email_verified"),
        )
    }
}

data class SessionInfo(val id: Int, val deviceId: String?, val deviceName: String?, val lastSeenAt: String?, val current: Boolean)

data class LoginResult(val user: User, val token: String, val created: Boolean = false)

data class AccountInfo(val mode: String, val hosted: Boolean, val passwordMin: Int, val sessionDays: Int,
                       val universities: List<String>, val providers: List<String>)

class AccountApi(private val client: ApiClient) {

    fun info(): AccountInfo {
        val j = client.get("/api/account/info")
        return AccountInfo(j.s("mode") ?: "local", j.b("hosted"), j.i("password_min") ?: 10, j.i("session_days") ?: 30,
            ApiClient.arr(j, "universities").mapNotNull { (it as? kotlinx.serialization.json.JsonPrimitive)?.content },
            ApiClient.arr(j, "providers").mapNotNull { (it as? kotlinx.serialization.json.JsonPrimitive)?.content })
    }

    fun register(email: String, password: String, university: String, deviceId: String? = null, deviceName: String? = null): LoginResult {
        val j = client.post("/api/account/register", ApiClient.obj("email" to email, "password" to password, "university" to university,
            "device_id" to deviceId, "device_name" to deviceName))
        return result(j, created = true)
    }

    fun login(email: String, password: String, deviceId: String? = null, deviceName: String? = null): LoginResult {
        val j = client.post("/api/account/login", ApiClient.obj("email" to email, "password" to password,
            "device_id" to deviceId, "device_name" to deviceName))
        return result(j)
    }

    /** Anmelden mit Apple/Google (identity_token vom Anbieter); neues Konto braucht die Hochschule. */
    fun loginWithIdentity(provider: String, identityToken: String, university: String? = null, deviceId: String? = null,
                          deviceName: String? = null): LoginResult {
        val j = client.post("/api/account/login/$provider", ApiClient.obj("identity_token" to identityToken,
            "university" to university, "device_id" to deviceId, "device_name" to deviceName))
        return result(j, created = j.b("created"))
    }

    fun linkIdentity(provider: String, identityToken: String): Boolean =
        client.post("/api/account/link/$provider", ApiClient.obj("identity_token" to identityToken)).b("linked")

    fun me(): Pair<User, List<SessionInfo>> {
        val j = client.get("/api/account/me")
        val sessions = j.list("sessions").map {
            SessionInfo(it.i("id") ?: 0, it.s("device_id"), it.s("device_name"), it.s("last_seen_at"), it.b("current"))
        }
        return User.from(j.o("user")) to sessions
    }

    fun logout() { client.post("/api/account/logout") }
    fun logoutAll(): Int = client.post("/api/account/logout-all").i("revoked") ?: 0
    fun changePassword(old: String, new: String) { client.post("/api/account/password", ApiClient.obj("old_password" to old, "new_password" to new)) }
    fun requestPasswordReset(email: String): String? = client.post("/api/account/password/reset-request", ApiClient.obj("email" to email)).s("message")
    fun resetPassword(token: String, newPassword: String) { client.post("/api/account/password/reset", ApiClient.obj("token" to token, "new_password" to newPassword)) }
    fun setUniversity(university: String): User = User.from(client.post("/api/account/university", ApiClient.obj("university" to university)).o("user"))
    fun delete(password: String?): Boolean = client.post("/api/account/delete", ApiClient.obj("password" to password)).b("deleted")

    private fun result(j: JsonElement, created: Boolean = false): LoginResult {
        val token = j.s("token") ?: throw ApiError(0, "no_token", "Antwort ohne Sitzungs-Token")
        return LoginResult(User.from(j.o("user")), token, created)
    }
}

/** Hilfen fuer Anfragen, die der Test gegen den Vertrag prueft. */
object AccountRequests {
    fun bodyFor(path: String, request: JsonObject?): JsonObject? = request
}

package de.uniflow.android.ui.screens

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import de.uniflow.android.Repo
import de.uniflow.android.Session
import de.uniflow.android.SessionRules
import de.uniflow.android.ui.theme.Bad
import de.uniflow.core.ApiError
import kotlinx.coroutines.launch

/** Zugang: UniFlow-Konto beim Dienst (E-Mail + Passwort, Registrieren mit Hochschule) oder der eigene PC im WLAN (PIN). */
@Composable
fun LoginScreen(session: Session, repo: Repo, onDone: () -> Unit) {
    var mode by remember { mutableStateOf(if (session.pin != null) "pc" else "dienst") }
    var url by remember { mutableStateOf(session.baseUrl) }
    var email by remember { mutableStateOf(session.email ?: "") }
    var password by remember { mutableStateOf("") }
    var pin by remember { mutableStateOf("") }
    var register by remember { mutableStateOf(false) }
    var university by remember { mutableStateOf(session.university) }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp)) {
        Text("UniFlow", style = MaterialTheme.typography.headlineMedium, color = MaterialTheme.colorScheme.primary)
        Text("Dein Studium, deine Unterlagen, dein Plan.", style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(bottom = 16.dp))
        Row {
            FilterChip(selected = mode == "dienst", onClick = { mode = "dienst" }, label = { Text("UniFlow-Konto") })
            FilterChip(selected = mode == "pc", onClick = { mode = "pc" }, label = { Text("Eigener PC im WLAN") }, modifier = Modifier.padding(start = 8.dp))
        }
        OutlinedTextField(url, { url = it }, label = { Text(if (mode == "pc") "Adresse des PCs (z. B. 192.168.1.5:8765)" else "Adresse des Dienstes") },
            singleLine = true, modifier = Modifier.fillMaxWidth().padding(top = 12.dp), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
        if (mode == "dienst") {
            OutlinedTextField(email, { email = it }, label = { Text("E-Mail") }, singleLine = true, modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email))
            OutlinedTextField(password, { password = it }, label = { Text(if (register) "Passwort (mindestens 10 Zeichen)" else "Passwort") }, singleLine = true,
                visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
            if (register) {
                Text("Hochschule", style = MaterialTheme.typography.labelLarge, modifier = Modifier.padding(top = 10.dp))
                Row {
                    FilterChip(selected = university == "luh", onClick = { university = "luh" }, label = { Text("LUH Hannover") })
                    FilterChip(selected = university == "hildesheim", onClick = { university = "hildesheim" }, label = { Text("Uni Hildesheim") }, modifier = Modifier.padding(start = 8.dp))
                }
            }
        } else {
            OutlinedTextField(pin, { pin = it.filter { c -> c.isDigit() }.take(6) }, label = { Text("PIN (Einstellungen > Zugang auf dem PC)") }, singleLine = true,
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword))
        }
        error?.let { Text(it, color = Bad, modifier = Modifier.padding(top = 8.dp)) }
        Button(enabled = !busy && url.isNotBlank(), onClick = {
            error = null; busy = true
            scope.launch {
                try {
                    val normalized = SessionRules.normalizeUrl(url)
                    if (!SessionRules.isHttpAllowed(normalized)) throw ApiError(0, "insecure", "Der Dienst braucht https; http nur für den eigenen PC im WLAN.")
                    if (mode == "pc") {
                        val uni = repo.checkPin(normalized, pin)
                        session.baseUrl = normalized; session.pin = pin; session.token = null; session.university = uni
                    } else {
                        val r = if (register) repo.register(normalized, email, password, university) else repo.login(normalized, email, password)
                        session.baseUrl = normalized; session.token = r.token; session.pin = null; session.email = r.user.email; session.university = r.user.university
                    }
                    onDone()
                } catch (e: ApiError) {
                    error = when (e.code) {
                        "credentials_invalid" -> "E-Mail-Adresse oder Passwort stimmt nicht."
                        "email_taken" -> "Für diese Adresse gibt es schon ein Konto."
                        "locked" -> "Zu viele Fehlversuche. Bitte 10 Minuten warten."
                        "not_hosted" -> "Diese Adresse ist ein PC, kein Dienst: bitte „Eigener PC im WLAN“ wählen."
                        else -> if (e.isAuth && mode == "pc") "PIN falsch." else e.message
                    }
                } finally { busy = false }
            }
        }, modifier = Modifier.fillMaxWidth().padding(top = 16.dp)) {
            Text(if (busy) "…" else if (mode == "pc") "Verbinden" else if (register) "Konto anlegen" else "Anmelden")
        }
        if (mode == "dienst") TextButton(onClick = { register = !register }) { Text(if (register) "Ich habe schon ein Konto" else "Neues Konto anlegen") }
    }
}

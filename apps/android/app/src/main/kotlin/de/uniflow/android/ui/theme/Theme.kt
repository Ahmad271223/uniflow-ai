package de.uniflow.android.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

val Accent = Color(0xFF4F5BD5)
val Ok = Color(0xFF1F9D5B)
val Warn = Color(0xFFD9851E)
val Bad = Color(0xFFD64545)

private val Light = lightColorScheme(primary = Accent, secondary = Color(0xFF6D4AE0), surface = Color(0xFFFFFFFF), background = Color(0xFFF6F7FB))
private val Dark = darkColorScheme(primary = Color(0xFF8E97FF), secondary = Color(0xFFB39DFF), surface = Color(0xFF1D1F29), background = Color(0xFF14151C))

@Composable
fun UniFlowTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = if (dark) Dark else Light, content = content)
}

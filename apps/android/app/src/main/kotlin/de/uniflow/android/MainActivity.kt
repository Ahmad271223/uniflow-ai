package de.uniflow.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import de.uniflow.android.ui.UniFlowApp
import de.uniflow.android.ui.theme.UniFlowTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val app = application as UniFlowApplication
        setContent {
            UniFlowTheme {
                UniFlowApp(session = app.session, repo = app.repo)
            }
        }
    }
}

package de.uniflow.android.ui

import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.DateRange
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import de.uniflow.android.Repo
import de.uniflow.android.Session
import de.uniflow.android.ui.screens.CalendarScreen
import de.uniflow.android.ui.screens.DocumentScreen
import de.uniflow.android.ui.screens.HomeScreen
import de.uniflow.android.ui.screens.LibraryScreen
import de.uniflow.android.ui.screens.LoginScreen
import de.uniflow.android.ui.screens.TimetableScreen

private data class Tab(val route: String, val label: String, val icon: androidx.compose.ui.graphics.vector.ImageVector)

private val tabs = listOf(
    Tab("home", "Übersicht", Icons.Filled.Home),
    Tab("library", "Dokumente", Icons.AutoMirrored.Filled.List),
    Tab("timetable", "Stundenplan", Icons.Filled.DateRange),
    Tab("calendar", "Lernkalender", Icons.Filled.Edit),
)

@Composable
fun UniFlowApp(session: Session, repo: Repo) {
    var loggedIn by remember { mutableStateOf(session.isLoggedIn) }
    if (!loggedIn) {
        LoginScreen(session = session, repo = repo, onDone = { loggedIn = true })
        return
    }
    val nav = rememberNavController()
    val entry by nav.currentBackStackEntryAsState()
    val route = entry?.destination?.route ?: "home"
    Scaffold(bottomBar = {
        if (!route.startsWith("doc/")) NavigationBar {
            tabs.forEach { t ->
                NavigationBarItem(selected = route == t.route, onClick = {
                    nav.navigate(t.route) { popUpTo("home") { saveState = true }; launchSingleTop = true; restoreState = true }
                }, icon = { Icon(t.icon, contentDescription = t.label) }, label = { Text(t.label) })
            }
        }
    }) { padding ->
        NavHost(nav, startDestination = "home", modifier = Modifier.padding(padding)) {
            composable("home") { HomeScreen(repo, onLogout = { loggedIn = false }, onOpenLibrary = { nav.navigate("library") }) }
            composable("library") { LibraryScreen(repo, onOpen = { nav.navigate("doc/${it.id}") }) }
            composable("timetable") { TimetableScreen(repo) }
            composable("calendar") { CalendarScreen(repo) }
            composable("doc/{fileId}") { back ->
                DocumentScreen(repo, fileId = back.arguments?.getString("fileId") ?: "", onBack = { nav.popBackStack() })
            }
        }
    }
}

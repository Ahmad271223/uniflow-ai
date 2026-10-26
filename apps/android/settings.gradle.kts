// UniFlow Android: der plattformunabhaengige Kern (JVM, ohne Android-SDK testbar) und die App (Jetpack Compose).
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "uniflow-android"
include(":core")
include(":app")

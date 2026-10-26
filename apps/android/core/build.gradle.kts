plugins {
    id("org.jetbrains.kotlin.jvm")
    id("org.jetbrains.kotlin.plugin.serialization")
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    testImplementation(kotlin("test"))
}

// Laeuft mit JDK 17 oder neuer (CI: 17, Docker-Bild des Android-SDK: 21); Zielplattform bleibt 17
java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}
kotlin {
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
}

tasks.test {
    useJUnitPlatform()
    // gemeinsame Testfaelle aus packages/shared-contracts
    systemProperty("uniflow.fixtures", rootProject.projectDir.resolve("../../packages/shared-contracts/fixtures").canonicalPath)
    testLogging { events("passed", "failed", "skipped"); showStandardStreams = true }
}

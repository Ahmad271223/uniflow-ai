plugins {
    kotlin("jvm") version "2.0.21"
    kotlin("plugin.serialization") version "2.0.21"
}

repositories { mavenCentral() }

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    testImplementation(kotlin("test"))
}

kotlin { jvmToolchain(17) }

tasks.test {
    useJUnitPlatform()
    // gemeinsame Testfaelle aus packages/shared-contracts
    systemProperty("uniflow.fixtures", rootProject.projectDir.resolve("../../packages/shared-contracts/fixtures").canonicalPath)
    testLogging { events("passed", "failed", "skipped"); showStandardStreams = true }
}

plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
        allWarningsAsErrors = true
    }
}

dependencies {
    api(libs.serialization.json)
    testImplementation(libs.junit)
}

// Tests read the canonical example (examples/home.scene.json) from the repo.
tasks.test {
    systemProperty("aer.repoRoot", rootProject.projectDir.resolve("../..").canonicalPath)
}

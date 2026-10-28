pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "aer-home-android"

// :core-api — Core REST client and client state (pure Kotlin, JVM tests)
// :scene    — scene format v1 geometry and bindings (pure Kotlin, JVM tests)
// :app      — Jetpack Compose UI: «Дом» and «Классика»
include(":core-api", ":scene", ":app")

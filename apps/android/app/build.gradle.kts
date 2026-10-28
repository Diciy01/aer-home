plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "home.aer.android"
    compileSdk = 36

    defaultConfig {
        applicationId = "home.aer.android"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.12.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            testProguardFiles("test-proguard-rules.pro")
            if (providers.gradleProperty("aerTestBuildType").orNull == "release") proguardFiles("proguard-instrumented.pro")
            // Test build only: signed with the local debug key, not for distribution.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    // `-PaerTestBuildType=release` runs the instrumented tests against the minified (R8) build.
    testBuildType = providers.gradleProperty("aerTestBuildType").getOrElse("debug")

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
    }

    lint {
        abortOnError = true
        warningsAsErrors = true
        checkDependencies = true
        // Versions are pinned on purpose (gradle/libs.versions.toml: compileSdk 36 limits them).
        // UseKtx: core-ktx is deliberately not a dependency for a few one-line helpers.
        disable += setOf("GradleDependency", "NewerVersionAvailable", "AndroidGradlePluginVersion", "UseKtx")
    }

    packaging {
        resources.excludes += setOf("META-INF/{AL2.0,LGPL2.1}", "META-INF/versions/9/OSGI-INF/MANIFEST.MF")
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
        allWarningsAsErrors = true
    }
}

/** Bundles the canonical demo layout (examples/home.scene.json) — the same file Core and desktop use. */
abstract class CopyDemoScene : DefaultTask() {
    @get:InputFile
    abstract val source: RegularFileProperty

    @get:OutputDirectory
    abstract val outputDir: DirectoryProperty

    @TaskAction
    fun copy() {
        val dir = outputDir.get().asFile.resolve("scenes")
        dir.mkdirs()
        source.get().asFile.copyTo(dir.resolve("demo_home.scene.json"), overwrite = true)
    }
}

val copyDemoScene = tasks.register<CopyDemoScene>("copyDemoScene") {
    source.set(rootProject.layout.projectDirectory.file("../../examples/home.scene.json"))
}

androidComponents {
    onVariants { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(copyDemoScene, CopyDemoScene::outputDir)
    }
}

dependencies {
    implementation(project(":core-api"))
    implementation(project(":scene"))

    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.graphics)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.compose.material3)
    implementation(libs.compose.material.icons)
    implementation(libs.activity.compose)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.lifecycle.runtime.compose)
    implementation(libs.coroutines.android)
    debugImplementation(libs.compose.ui.tooling)
    debugImplementation(libs.compose.ui.test.manifest)

    testImplementation(libs.junit)
    testImplementation(libs.coroutines.test)

    androidTestImplementation(platform(libs.compose.bom))
    androidTestImplementation(libs.compose.ui.test.junit4)
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.espresso.core)
}

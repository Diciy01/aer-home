# Added to the release build ONLY with -PaerTestBuildType=release: the test
# framework calls into AndroidX/Compose classes that R8 would strip or rename.
# The app's own code (home.aer.**, kotlinx.serialization, OkHttp) is still
# shrunk and optimised exactly as in the shipped release build.
-dontobfuscate
-keep class androidx.** { *; }
-keep class kotlinx.coroutines.** { *; }
-keep class kotlin.** { *; }
-keep class org.junit.** { *; }
-dontwarn javax.lang.model.**

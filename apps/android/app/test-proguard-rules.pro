# Instrumented tests against the minified build (-PaerTestBuildType=release).
-dontobfuscate
-dontwarn javax.lang.model.**
-dontwarn com.google.errorprone.annotations.**
-keep class home.aer.android.LiveCoreTest { *; }
-keep class home.aer.android.LiveCoreTestKt { *; }

# kotlinx.serialization and OkHttp ship their own consumer rules.
# Keep @Serializable DTOs' generated serializers (belt and braces for R8 full mode).
-keepclassmembers @kotlinx.serialization.Serializable class home.aer.** {
    *** Companion;
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class home.aer.**$$serializer { *; }

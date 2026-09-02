# ─────────────────────────────────────────────────────────────────────
# ProGuard / R8 rules for Epilepsy Monitor (graduation project)
# Applied only in release builds to protect against reverse engineering.
# ─────────────────────────────────────────────────────────────────────

# Flutter wrapper — keep the embedding entry point
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Dart-side encryption / secure storage
-keep class com.it_nomads.fluttersecurestorage.** { *; }

# local_auth biometrics
-keep class io.flutter.plugins.localauth.** { *; }

# Firebase (when google-services.json is present)
-keep class com.google.firebase.** { *; }
-dontwarn com.google.firebase.**

# Keep Gson / JSON model serialization (used by plugins)
-keepattributes Signature
-keepattributes *Annotation*
-keep class sun.misc.Unsafe { *; }

# SQLite / SQLCipher
-keep class net.sqlcipher.** { *; }
-keep class net.sqlcipher.database.** { *; }

# Connectivity Plus
-keep class dev.fluttercommunity.plus.** { *; }

# SMS / URL launcher
-keep class io.flutter.plugins.urllauncher.** { *; }

# General: don't warn about missing optional deps
-dontwarn javax.annotation.**
-dontwarn org.conscrypt.**

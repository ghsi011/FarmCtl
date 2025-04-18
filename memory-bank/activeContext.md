# Active Context

## Current Focus
* Finalizing project scaffolding and build configuration: version catalog integration, Gradle wrapper, plugin aliases, compileOptions/JVM alignment.
* Cleaning up AndroidManifest and resource setup.
* Preparing for Compose UI implementation in MainActivity.

## Recent Changes
* Configured `pluginManagement` and `dependencyResolutionManagement` in `settings.gradle.kts` with central version catalog.
* Created `gradle/libs.versions.toml` with all dependency and plugin versions and aliases.
* Updated root and module `build.gradle.kts` to use `alias(libs.plugins.*)`, Kotlin 2.1 + Compose compiler plugin, jvmTarget 17, and Java 17 compileOptions.
* Generated Gradle wrapper (`gradlew`) via `gradle wrapper`.
* Cleaned up `AndroidManifest.xml`: removed invalid package/attribute definitions and missing resource references.
* Verified clean build success with `./gradlew clean build` on Windows (`.gradlew.bat clean build`).

## Next Steps
1. Add launcher icons and theme resources under `app/src/main/res`.
2. Implement Compose-based UI in `MainActivity.kt`.
3. Configure CI to invoke `./gradlew` and ensure workflows pass.
4. Create `local.properties` or set `ANDROID_HOME`/`ANDROID_SDK_ROOT` for SDK path.
5. Address manifest namespace warnings and any resource linkage issues.

## Decisions & Considerations
* Leveraging Gradle version catalogs (`libs.versions.toml`) for centralized version management.
* Employing the Gradle wrapper to lock Gradle version for all developers and CI.
* Targeting Java 17 and Kotlin jvmTarget 17 with AGP 8.5.
* Stripped unsupported resource attributes in `AndroidManifest.xml` to avoid AAPT linkage errors.

---
_Update this file whenever the immediate focus or decisions change._ 
# Progress

## What Works
* Documentation guide (`guidlines.md`) covers steps 1‑9.
* Memory Bank core files initialised.
* Core Gradle files (`settings.gradle.kts`, `gradle/libs.versions.toml`, root & app `build.gradle.kts`) now use the version catalog and plugin aliases correctly.
* Gradle wrapper (`gradlew`) generated and `.gradlew.bat clean build` succeeds on Windows.
* `AndroidManifest.xml` cleaned up; no missing resource linkage errors after removing icons and theme attributes.
* `app/build.gradle.kts` now has `compileOptions` for Java 17 and Kotlin `jvmTarget = "17"`, resolving JVM–target compatibility.

## Remaining Tasks
| Task | Status |
| ---- | ------ |
| Add launcher icons & style resources under `app/src/main/res` | TODO |
| Implement Compose UI in `MainActivity.kt` | TODO |
| Create `local.properties` (or set `ANDROID_HOME`/`ANDROID_SDK_ROOT`) for SDK | TODO |
| Configure CI workflow to run `./gradlew` and pass build | DONE |
| Add GitHub Actions workflow with unit‑test step | DONE |
| Write initial JUnit + MockK sample test | DONE |
| Add business logic class and tests | PLANNED |
| Integrate AndroidX UI test and run in CI | PLANNED |
| Stabilise tool‑chain (SDK/AGP) | TODO |
| Integrate Spotless + detekt & CI | TODO |
| Restructure CI into unit-jvm & android jobs | TODO |
| Add Material3 theme + icons | TODO |
| Expand docs (README, licence) | TODO |
| Add Dependabot config | TODO |

## Known Issues
* None of the build errors block compilation, but the following warnings remain:
  * `package="…"`
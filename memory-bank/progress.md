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
| **CI: Instrumented Tests** - Add new job to `ci.yml` for `connectedCheck` (emulator API 35, AVD caching). | TODO |
| **Architecture: ViewModel & Hilt** - Create `GreetingViewModel`, inject into `MainActivity`. | TODO |
| **Testing: ViewModel Unit Tests** - Write JUnit/MockK tests for `GreetingViewModel`. | TODO |
| **Architecture: Repository Layer** - Define `GreetingRepository` interface & stub implementation, inject into ViewModel. | TODO |
| **Testing: Instrumented UI Test** - Verify greeting display via Espresso/Compose test. | TODO |
| **Project Polish: Docs & Repo Essentials** - Expand README, add LICENSE, Dependabot. | TODO |
| Create `local.properties` (or set `ANDROID_HOME`/`ANDROID_SDK_ROOT`) for SDK | TODO |
| Stabilise tool-chain (SDK/AGP) - Optional: Await AGP 8.6/9.x for official SDK 35 support. | PLANNED |

## Known Issues
* Warnings from D8 about Kotlin metadata/R8 compatibility with Compose Compiler (monitor with AGP/Kotlin updates).
* `package="…"` attribute warning in manifest (cosmetic, investigate if problematic).

## Next Steps (High-Level Iterations)
1.  **Enhance CI with Instrumented Tests** (Emulator, AVD caching)
2.  **Introduce Basic ViewModel with Hilt**
3.  **Unit Test the ViewModel**
4.  **Implement Basic Repository Layer**
5.  **Instrumented UI Test for Greeting**
6.  **Polish Documentation & Repo Essentials**

<!-- Detailed tasks for current iteration will be tracked under a separate heading or in a dedicated task management tool/issue. -->
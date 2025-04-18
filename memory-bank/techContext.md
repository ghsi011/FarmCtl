# Tech Context

| Category | Technology / Version | Notes |
| -------- | -------------------- | ----- |
| Language | Kotlin 1.9.x | Primary app language. |
| JDK | 17 (Temurin) | Required by AGP 8+. |
| Build Tool | Gradle Wrapper 8.x (Kotlin DSL) | Wrapper ensures consistent builds. |
| AGP | 8.1+ | Android Gradle Plugin version. |
| SDK | Android 34 (Build‑Tools 34.0.0) | Installed via `sdkmanager`. |
| UI | Jetpack Compose 1.7.x + Material3 1.3.x | Declarative UI toolkit. |
| DI | Hilt 2.56.x | Annotation‑based dependency injection. |
| DB | Room 2.6.x | Persistence layer. |
| Tests | JUnit 4.13.2, MockK 1.13.x, Espresso 3.5.x | Unit & UI testing. |
| CI | GitHub Actions (ubuntu‑latest) | `ci.yml` automates build & tests. |

## Tooling Setup Quick Commands
```bash
# Install Android SDK components
sdkmanager "platforms;android-34" "build-tools;34.0.0" "platform-tools"
# Verify Gradle wrapper
./gradlew --version
```

---
_Update when upgrading libraries or build tools._ 
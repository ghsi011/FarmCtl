# Setting Up a Minimal Android Development Environment (Kotlin, API 34+) 🚀

Creating a lean Android project that is fully manageable via the terminal involves setting up Kotlin, configuring Android 14 (API level 34) settings, adding essential libraries, and ensuring everything (including tests and deployment) works via command-line. Below is a step-by-step guide with explanations, code snippets, and directory structures to help you build this environment.

## Step 1: Install Prerequisites (JDK, Android SDK, CLI Tools)

Before initializing the project, make sure your system is ready:

- **Java Development Kit (JDK)** – Install JDK 17 (required by modern Android Gradle plugins). Ensure `JAVA_HOME` is set accordingly.
- **Android SDK and Build Tools** – Install the Android SDK **command-line tools**. Using the `sdkmanager` utility (part of the Android SDK), download the latest SDK platform for Android 14 (API 34) and the latest build-tools. For example:  
  ```bash
  sdkmanager "platforms;android-34" "build-tools;34.0.0" "platform-tools"
  ``` 
  This will install the API 34 SDK, build tools, and platform tools (which include `adb`).
- **Environment Variables** – Set `ANDROID_HOME` (or `ANDROID_SDK_ROOT`) to your SDK install path, and add the SDK's platform-tools and tools to your `PATH` (for access to `adb`, `sdkmanager`, etc. ([The Missing Bit | Setting up an android app from scratch without IDE](https://www.kuon.ch/post/2020-01-12-android-app/#:~:text=If%20you%20are%20not%20on,to%20install%20the%20SDK))】. For example:  
  ```bash
  # In ~/.bashrc or ~/.zshrc
  export ANDROID_HOME="$HOME/Android/Sdk"
  export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
  ``` 

With these in place, you have the basic tools to build and deploy Android apps via the terminal.

## Step 2: Initialize a New Kotlin Android Project Structure

Create a new project directory and use Gradle's initialization to set up a Kotlin project:

```bash
mkdir MyAndroidApp
cd MyAndroidApp
gradle init
```

Gradle's interactive `init` wizard will prompt you for project type and language. Choose **"application"** for project type and **"Kotlin"** as the implementation language, and **Kotlin DSL** for the build script (Gradle will ask for Groovy vs Kotlin DSL ([The Missing Bit | Setting up an android app from scratch without IDE](https://www.kuon.ch/post/2020-01-12-android-app/#:~:text=Select%20implementation%20language%3A%201%3A%20C%2B%2B,1..5%5D%204))】. This generates a basic project. Next, we will convert it to an Android app structure:

1. **Create the App Module**: Gradle's init may create a single-module project. Create an `app/` module for the Android app and the typical Android directory structure:
   ```bash
   mkdir -p app/src/main/kotlin/com/example/myandroidapp
   mkdir -p app/src/main/res
   mkdir -p app/src/main/AndroidManifest.xml   # (we will add content next)
   mkdir -p app/src/test/java/com/example/myandroidapp
   mkdir -p app/src/androidTest/java/com/example/myandroidapp
   ```
   Also, include the new module in settings. Append the following to **`settings.gradle.kts`**:
   ```kotlin
   include(":app")
   ```
2. **Android Manifest**: Create **`app/src/main/AndroidManifest.xml`** with a minimal manifest declaring the application and a launcher activity:
   ```xml
   <manifest xmlns:android="http://schemas.android.com/apk/res/android"
       package="com.example.myandroidapp">
       <application
           android:label="MyAndroidApp"
           android:icon="@mipmap/ic_launcher"
           android:roundIcon="@mipmap/ic_launcher_round"
           android:supportsRtl="true"
           android:theme="@style/Theme.Material3.DayNight.NoActionBar">
           <activity android:name=".MainActivity"
                     android:exported="true"
                     android:theme="@style/Theme.Material3.DayNight.NoActionBar">
               <intent-filter>
                   <action android:name="android.intent.action.MAIN" />
                   <category android:name="android.intent.category.LAUNCHER" />
               </intent-filter>
           </activity>
       </application>
   </manifest>
   ```
   This manifest uses a Material3 theme (from the Material Components library) and declares `MainActivity` as the launcher.

3. **Main Activity**: Create **`app/src/main/kotlin/com/example/myandroidapp/MainActivity.kt`** as a simple entry point. For example, using Jetpack Compose for UI:
   ```kotlin
   package com.example.myandroidapp

   import android.os.Bundle
   import androidx.activity.ComponentActivity
   import androidx.activity.compose.setContent
   import androidx.compose.material3.Text
   import androidx.compose.material3.MaterialTheme

   class MainActivity : ComponentActivity() {
       override fun onCreate(savedInstanceState: Bundle?) {
           super.onCreate(savedInstanceState)
           setContent {
               MaterialTheme {
                   Text("Hello, Android 14!")
               }
           }
       }
   }
   ```
   This minimal activity uses **Jetpack Compose** to display a greeting text.

Now your project structure should look like this:

```plaintext
MyAndroidApp/
├── build.gradle.kts                # Root Gradle build (we'll configure next)
├── settings.gradle.kts             # Includes :app module
├── gradle/
│   └── libs.versions.toml          # (Will contain centralized dependency versions)
├── app/
│   ├── build.gradle.kts            # Module-level Gradle config
│   └── src/
│       ├── main/
│       │   ├── AndroidManifest.xml
│       │   └── kotlin/com/example/myandroidapp/MainActivity.kt
│       ├── test/                   # Unit tests will go here
│       │   └── ... (e.g., ExampleUnitTest.kt)
│       └── androidTest/            # Instrumented UI tests will go here
│           └── ... (e.g., ExampleInstrumentedTest.kt)
└── memory.md                       # AI memory/notes file (explained in Step 7)
```

## Step 3: Configure Gradle for Kotlin and Android API Level 34

Now configure the Gradle build scripts for an Android app using Kotlin:

- **Root build.gradle.kts**: In the project's root `build.gradle.kts`, set up the Gradle plugins and repositories. We will use the Kotlin DSL for a cleaner config. For example:
  ```kotlin
  plugins {
      # Version numbers will be managed in libs.versions.toml (shown later)
      id("com.android.application") version "<AGP_VERSION>" apply false
      id("org.jetbrains.kotlin.android") version "<KOTLIN_VERSION>" apply false
      id("com.google.dagger.hilt.android") version "<HILT_VERSION>" apply false
  }
  dependencyResolutionManagement {
      repositories {
          google()
          mavenCentral()
      }
      # Link to version catalog
      versionCatalogs {
          create("libs") {
              from(files("gradle/libs.versions.toml"))
          }
      }
  }
  ```
  In the `plugins` block above, we declare the Android Gradle Plugin (AGP), Kotlin plugin, and Hilt plugin with `apply false` (so they can be applied per-module later ([Dependency injection with Hilt  |  App architecture  |  Android Developers](https://developer.android.com/training/dependency-injection/hilt-android#:~:text=First,%2C%20add%20the%20%60hilt,file))】. We also ensure the Google and MavenCentral repositories are used for dependencies.

- **Module build.gradle.kts (app)**: In **`app/build.gradle.kts`**, apply the plugins and configure Android specifics:
  ```kotlin
  plugins {
      id("com.android.application")
      id("org.jetbrains.kotlin.android")
      id("org.jetbrains.kotlin.kapt")          # for annotation processing (e.g., Room, Hilt)
      id("com.google.dagger.hilt.android")
  }

  android {
      namespace = "com.example.myandroidapp"
      compileSdk = 34
      defaultConfig {
          applicationId = "com.example.myandroidapp"
          minSdk = 21
          targetSdk = 34
          versionCode = 1
          versionName = "1.0"
          testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
      }
      buildFeatures {
          compose = true  # Enable Jetpack Compose U ([Compose  |  Jetpack  |  Android Developers](https://developer.android.com/jetpack/androidx/releases/compose#:~:text=android%20,true))】
      }
      composeOptions {
          kotlinCompilerExtensionVersion = "<COMPOSE_COMPILER_VER>"  # e.g., "1.5.15"
      }
      kotlinOptions {
          jvmTarget = "1.8"
      }
   }

  dependencies {
      implementation(libs.androidx.core.ktx)
      implementation(libs.androidx.lifecycle.runtime.ktx)
      implementation(libs.androidx.activity.compose)
      implementation(libs.compose.ui)
      implementation(libs.compose.material3)
      implementation(libs.compose.ui.tooling)
      implementation(libs.hilt.android)
      kapt(libs.hilt.compiler)
      implementation(libs.room.runtime)
      kapt(libs.room.compiler)
      # Test libraries
      testImplementation(libs.junit4)
      testImplementation(libs.mockk)
      androidTestImplementation(libs.androidx.junit.ext)       # JUnit extensions for Android
      androidTestImplementation(libs.androidx.test.espresso)   # Espresso for UI tests
  }
  ```

  Let's break down some key points in this module configuration:
  - We set `compileSdk = 34` and `targetSdk = 34` to use Android 14 (ensuring the app meets the latest Play Store requirement of targeting API 3 ([Meet Google Play's target API level requirement - Android Developers](https://developer.android.com/google/play/requirements/target-sdk#:~:text=Developers%20developer,for%20Wear%20OS%20and))】). We chose `minSdk = 21` (Android 5.0) for broad device support, but you can adjust it.
  - `buildFeatures.compose = true` enables Jetpack Compose in the build, and we specify a Kotlin Compose Compiler extension version to match our Compose library versio ([Compose  |  Jetpack  |  Android Developers](https://developer.android.com/jetpack/androidx/releases/compose#:~:text=android%20,true))】.
  - We apply Kotlin KAPT plugin for annotation processing since libraries like Room and Hilt use annotation processors.
  - The `dependencies` block uses **type-safe aliases** (like `libs.compose.ui`) which will be defined in our version catalog (next step). We include **AndroidX Core KTX** for base Android utilities, **Lifecycle Runtime KTX** for app lifecycle support, **Activity Compose** for Compose integration in activities, **Jetpack Compose UI** libraries (core UI and Material3 components), **Hilt** for dependency injection, and **Room** for database access. Test dependencies for JUnit4, MockK, AndroidX JUnit (ext), and Espresso are also added.

At this point, the Gradle scripts define a Kotlin-based Android app module with modern libraries and target API 34. Next, we'll manage the library versions in one place.

## Step 4: Centralize Dependency Versions with Gradle Version Catalog

To keep the build maintainable, we use a **Gradle Version Catalog** (a centralized `libs.versions.toml` file) for all dependency and plugin versions. This avoids hard-coding versions in multiple places and makes updates easie ([Migrate your build to version catalogs  |  Android Studio  |  Android Developers](https://developer.android.com/build/migrate-to-catalogs#:~:text=Gradle%20version%20catalogs%20enable%20you,way%20with%20Android%20Studio%20assistance)) ([Migrate your build to version catalogs  |  Android Studio  |  Android Developers](https://developer.android.com/build/migrate-to-catalogs#:~:text=Start%20by%20creating%20a%20version,recommend%20using%20this%20default%20name))】.

1. **Create the Version Catalog file**: Create **`gradle/libs.versions.toml`** in the project's `gradle/` directory. Gradle will automatically detect this file by defaul ([Migrate your build to version catalogs  |  Android Studio  |  Android Developers](https://developer.android.com/build/migrate-to-catalogs#:~:text=Start%20by%20creating%20a%20version,recommend%20using%20this%20default%20name))】.
2. **Define versions and libraries**: Open `libs.versions.toml` and add sections for versions, libraries, and plugins. For example:

   ```toml
   [versions]
   kotlin = "1.9.10"              # Kotlin version (or 2.x if using Kotlin 2)
   agp = "8.1.2"                  # Android Gradle Plugin version
   compose = "1.7.8"              # Jetpack Compose BOM version for core UI libraries
   composeCompiler = "1.5.15"     # Compose Kotlin compiler extension
   material3 = "1.3.2"            # Material3 Compose library version
   hilt = "2.56.1"                # Dagger Hilt version
   room = "2.6.1"                 # Room library version
   junit4 = "4.13.2"              # JUnit 4
   espresso = "3.5.1"             # Espresso core
   androidxTestExt = "1.1.5"      # AndroidX JUnit (ext)
   mockk = "1.13.5"               # MockK for mocking in tests

   [libraries]
   androidx-core-ktx = { module = "androidx.core:core-ktx", version = "1.10.1" }
   androidx-lifecycle-runtime-ktx = { module = "androidx.lifecycle:lifecycle-runtime-ktx", version = "2.6.1" }
   androidx-activity-compose = { module = "androidx.activity:activity-compose", version = "1.7.2" }
   compose-ui = { module = "androidx.compose.ui:ui", version.ref = "compose" }
   compose-material3 = { module = "androidx.compose.material3:material3", version.ref = "material3" }
   compose-ui-tooling = { module = "androidx.compose.ui:ui-tooling", version.ref = "compose" }
   hilt-android = { module = "com.google.dagger:hilt-android", version.ref = "hilt" }
   hilt-compiler = { module = "com.google.dagger:hilt-android-compiler", version.ref = "hilt" }
   room-runtime = { module = "androidx.room:room-runtime", version.ref = "room" }
   room-compiler = { module = "androidx.room:room-compiler", version.ref = "room" }
   junit4 = { module = "junit:junit", version.ref = "junit4" }
   androidx-junit-ext = { module = "androidx.test.ext:junit", version.ref = "androidxTestExt" }
   androidx-test-espresso = { module = "androidx.test.espresso:espresso-core", version.ref = "espresso" }
   mockk = { module = "io.mockk:mockk", version.ref = "mockk" }

   [plugins]
   android-app = { id = "com.android.application", version.ref = "agp" }
   kotlin-android = { id = "org.jetbrains.kotlin.android", version.ref = "kotlin" }
   kotlin-kapt = { id = "org.jetbrains.kotlin.kapt", version.ref = "kotlin" }
   dagger-hilt = { id = "com.google.dagger.hilt.android", version.ref = "hilt" }
   ```
   
   In this TOML:
   - **[versions]** defines version numbers for each major dependency or plugin.
   - **[libraries]** maps a friendly name (alias) to each dependency coordinate, reusing the version references. For example, `compose-ui` uses `version.ref = "compose"` which refers to the Compose BOM version defined above, and `room-runtime` uses `version.ref = "room"` (2.6.1).
   - **[plugins]** defines plugin identifiers and their versions, similar to how we declared them in the root Gradle script. These can be used via `libs.plugins.` alias if needed.

3. **Using the Catalog in Gradle**: We already configured `settings.gradle.kts` (in Step 3) to load this catalog. The `libs.*` aliases used in `app/build.gradle.kts` now correspond to entries in this catalog. For example, `libs.compose.ui` will resolve to `androidx.compose.ui:ui:1.7.8`, and `libs.hilt.android` to `com.google.dagger:hilt-android:2.56.1`. This centralized approach prevents version mismatches and makes updates easy – just edit the TOML file, and all modules use the new versions.

## Step 5: Add Essential Libraries (Room, Compose, Hilt, etc.)

With the version catalog in place, we ensure our project includes the modern essential libraries:

- **Jetpack Compose** – Already enabled in buildFeatures. We included Compose UI core and Material3 for a modern UI toolkit. Compose eliminates the need for XML layouts and integrates well with Kotlin.
- **Room (SQLite Persistence)** – Added `androidx.room:room-runtime` with a KAPT dependency on `room-compiler` for annotation processing. Room provides a robust SQLite abstraction for local data.
- **Hilt (Dependency Injection)** – Included Hilt's Gradle plugin and dependencies. The `hilt-android` library and its compiler are added. Don't forget to annotate your Application class with `@HiltAndroidApp` and activities with `@AndroidEntryPoint` when you start writing the app logic.
- **AndroidX Core & Lifecycle** – Core KTX provides convenient Kotlin extensions for Android APIs. Lifecycle runtime helps manage app lifecycle events. These are part of a solid app foundation.
- **Activity Compose** – Allows using Compose within an Activity (provides `ComponentActivity.setContent` extension we used in `MainActivity`).
- **Material3 Components** – We used Material3 Compose library for modern theming and UI components adhering to Material Design 3.

These libraries cover UI, data, DI, and app basics, giving a strong starting point for almost any app. Because we added them in the Gradle config, they'll be available to the AI assistant to use in code generation.

## Step 6: Ensure a Testable Architecture (Unit & UI Tests Setup)

We want all parts of the app to be testable. We include testing frameworks and will structure code to allow testability:

- **JUnit for Unit Tests**: We added JUnit 4 (`testImplementation(libs.junit4)`) which is the default for Android unit tests. You can write plain unit tests in `app/src/test/...` that run on the JVM. (If you prefer JUnit 5, additional setup is required, but JUnit 4 is straightforward and supported out-of-the-box.)
- **MockK for Mocks/Stubs**: Added `testImplementation(libs.mockk)` to use the MockK library, which is a Kotlin-friendly mocking library. This helps in unit testing components by simulating dependencies.
- **Instrumented (UI) Tests**: We added AndroidX Test dependencies: `androidTestImplementation(libs.androidx.junit.ext)` for JUnit extensions that integrate with Android (e.g., `AndroidJUnit4` runner), and `androidTestImplementation(libs.androidx.test.espresso)` for the Espresso framework to drive UI tests. These tests will reside in `app/src/androidTest/...`.
- **Test Runner**: The `testInstrumentationRunner` in the Android defaultConfig is set to AndroidJUnitRunner (`"androidx.test.runner.AndroidJUnitRunner"`), which is the standard runner for Android UI tests. This is important for running Espresso tests.
- **Espresso Setup**: With Espresso included, you can write tests that launch `MainActivity` and verify UI interactions. (Typically, also include `androidTestImplementation("androidx.test:rules:1.5.0")` and others as needed. Our minimal setup keeps just core dependencies for simplicity.)

With this setup, you can create test classes. For example, a simple unit test in `src/test`:

```kotlin
class ExampleUnitTest {
    @Test
    fun addition_isCorrect() {
        assertEquals(4, 2+2)
    }
}
```

And an instrumented test in `src/androidTest`:

```kotlin
@HiltAndroidTest
class MainActivityTest {
    @get:Rule
    val hiltRule = HiltAndroidRule(this)  # if using Hilt in tests

    @Test
    fun launchMainActivity_checkHelloText() {
        launchActivity<MainActivity>()
        onView(withText("Hello, Android 14!")).check(matches(isDisplayed()))
    }
}
```

*(Ensure to include the Hilt testing dependencies and call `hiltRule.inject()` in setup if using Hilt in tests.)*

The key point is our project is configured to support both local unit tests and instrumented UI tests, following Android best practices.

## Step 7: Build, Run, and Deploy via Command-Line

One goal is **full command-line management** of the app lifecycle: building, testing, and deployment – without relying on Android Studio. Gradle and Android SDK tools enable this:

- **Gradle Wrapper**: Use the Gradle Wrapper scripts (`./gradlew` for Linux/Mac, or `gradlew.bat` on Windows) for consistency. Gradle wrapper ensures the correct Gradle version is used for the projec ([Build your app from the command line  |  Android Studio  |  Android Developers](https://developer.android.com/build/building-cmdline#:~:text=You%20can%20execute%20all%20the,you%20create%20with%20Android%20Studio))】. Common tasks:
  - **Build the APK**: Run `./gradlew assembleDebug` to compile the app and produce an APK (or `assembleRelease` for a release build). You can also run `./gradlew build` which includes compilation and testing.
  - **Run Unit Tests**: Execute `./gradlew test` to run all local unit tests (JVM tests ([Test from the command line  |  Android Studio  |  Android Developers](https://developer.android.com/studio/test/command-line#:~:text=Unit%20test%20type%20  Command,task))】. Results will appear in `app/build/reports/tests/testDebugUnitTest/`.
  - **Run Instrumented Tests**: Ensure you have an emulator or device connected (with USB debugging enabled). Then run `./gradlew connectedAndroidTest` to compile and execute all instrumented UI tests on the connected devic ([Test from the command line  |  Android Studio  |  Android Developers](https://developer.android.com/studio/test/command-line#:~:text=XML%20test%20result%20files%3A%20%60path_to_your_project%2Fmodule_name%2Fbuild%2Ftest,directory))】. Gradle will install the app and test APK, run tests, and output results.
  - **Install/Deploy APK**: After assembling, you can install the app on a device via ADB. For example:  
    ```bash
    adb install -r app/build/outputs/apk/debug/app-debug.apk
    ``` 
    This uses the Android Debug Bridge to push the APK (-r to replace existing). You can then launch it with `adb shell am start -n "com.example.myandroidapp/.MainActivity"`.
  - **Other Gradle tasks**: `./gradlew tasks` will list all available tasks in the project for building, testing, and more. 

**USB Debugging Tip:** Ensure your Android device has Developer Options and USB debugging enabled, and verify the connection with `adb devices`. Once the device is listed, the above Gradle and adb commands will be able to deploy and run the app on your device.

All these operations can be done purely via terminal, which is ideal for AI-assisted coding sessions or automation. For example, an AI tool could trigger tests or builds by invoking these CLI commands and read the output.

## Step 8: Create a Memory/Documentation File for AI Notes

To facilitate AI-assisted development, maintain a "memory bank" in your project where the AI (and you) can log decisions, context, and important notes. Create a simple Markdown file (for example, **`memory.md`** at the project root). This file will serve as a running journal of the project's context that the AI can refer back to. 

In `memory.md`, you might record things like:
- Project goals and high-level architecture decisions.
- Summaries of API endpoints or data models once you add them.
- Explanations for why certain libraries or patterns were chosen.
- A changelog of major iterations or bug fixes.

By updating `memory.md` during development, you provide the AI assistant with persistent context it can "remember" across coding sessions. This is especially useful if the AI interface doesn't retain long-term memory of the entire project. Before asking the AI to generate new code or refactor something, you (or the AI, if it has file access) can quickly review this file to get up to speed on the project's state.

**Example `memory.md` excerpt:**
```markdown
# Project Memory

## Dec 1, 2025
- Set up initial project structure (Kotlin, Compose, Hilt, Room). All builds/tests passing.
- Decided on MVVM architecture; will use ViewModel and Repository patterns.
- Main features to implement: User login, local data caching with Room, etc.

## Dec 5, 2025
- Added `User` data model and DAO in Room.
- Integrated Retrofit for network calls (see `build.gradle.kts` for Retrofit dependency).
- Facing an issue with Hilt injection in ViewModel (AI assistance needed).
```

This running log helps both the human developer and the AI to maintain continuity. It's essentially an in-project knowledge base that grows with your app.

## Step 9: Integrate Continuous Integration with GitHub Actions

To automate building, testing, and quality checks on every commit and pull request, set up GitHub Actions:

1. Create the workflow directory:
   ```bash
   mkdir -p .github/workflows
   ```

2. Add `.github/workflows/ci.yml` with the following content:
   ```yaml
   name: Android CI

   on:
     push:
       branches: [main]
     pull_request:
       branches: [main]

   jobs:
     build:
       runs-on: ubuntu-latest
       steps:
         - name: Checkout code
           uses: actions/checkout@v3
         - name: Set up JDK 17
           uses: actions/setup-java@v3
           with:
             distribution: temurin
             java-version: '17'
         - name: Cache Gradle
           uses: actions/cache@v3
           with:
             path: |
               ~/.gradle/caches
               ~/.gradle/wrapper
             key: ${{ runner.os }}-gradle-${{ hashFiles('**/*.gradle*', '**/gradle-wrapper.properties') }}
             restore-keys: |
               ${{ runner.os }}-gradle-
         - name: Set up Android SDK
           uses: android-actions/setup-android@v2
           with:
             api-level: 34
             build-tools: '34.0.0'
         - name: Build and Test
           run: ./gradlew build
         - name: Run Instrumented Tests
           run: ./gradlew connectedAndroidTest
         - name: Upload Test Results
           uses: actions/upload-artifact@v3
           with:
             name: test-results
             path: app/build/reports
   ```

Feel free to adjust workflow settings to suit your project.

---

By following these steps, you now have:

- A clean **Kotlin-based Android project** targeting API level 34.
- Modern libraries (Jetpack Compose, Hilt, Room, etc.) integrated for a solid foundation.
- A **centralized dependency version catalog** to manage versions easily.
- Full support for **unit and UI testing** using JUnit, Espresso, and MockK.
- The ability to **build, test, and deploy entirely from the command line**, which is ideal for scripting and AI-assisted workflow ([Build your app from the command line  |  Android Studio  |  Android Developers](https://developer.android.com/build/building-cmdline#:~:text=You%20can%20execute%20all%20the,you%20create%20with%20Android%20Studio)) ([Test from the command line  |  Android Studio  |  Android Developers](https://developer.android.com/studio/test/command-line#:~:text=XML%20test%20result%20files%3A%20%60path_to_your_project%2Fmodule_name%2Fbuild%2Ftest,directory))】.
- A project-level **memory/documentation file** to aid AI in retaining context between sessions.

This minimal environment is ready for AI-assisted development – you can now confidently use an AI coding assistant to start generating code, running builds, and iterating on your Android app, all within a terminal-driven setup. Happy coding! 🎉

**Sources:**

- Official Android documentation on command-line buil ([Build your app from the command line  |  Android Studio  |  Android Developers](https://developer.android.com/build/building-cmdline#:~:text=You%20can%20execute%20all%20the,you%20create%20with%20Android%20Studio))2】 and testi ([Test from the command line  |  Android Studio  |  Android Developers](https://developer.android.com/studio/test/command-line#:~:text=XML%20test%20result%20files%3A%20%60path_to_your_project%2Fmodule_name%2Fbuild%2Ftest,directory))0】.  
- Android API level 34 requirement (Google Play target API mandat ([Meet Google Play's target API level requirement - Android Developers](https://developer.android.com/google/play/requirements/target-sdk#:~:text=Developers%20developer,for%20Wear%20OS%20and))8】.  
- Gradle Version Catalog usage for centralized dependency manageme ([Migrate your build to version catalogs  |  Android Studio  |  Android Developers](https://developer.android.com/build/migrate-to-catalogs#:~:text=Gradle%20version%20catalogs%20enable%20you,way%20with%20Android%20Studio%20assistance)) ([Migrate your build to version catalogs  |  Android Studio  |  Android Developers](https://developer.android.com/build/migrate-to-catalogs#:~:text=Start%20by%20creating%20a%20version,recommend%20using%20this%20default%20name))6】.
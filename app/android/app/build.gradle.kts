import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing is driven by android/key.properties when present (created by CI
// from GitHub secrets, or locally for signed local builds). When absent, the release
// build falls back to debug signing so `flutter run --release` and CI debug builds work.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasKeystore = keystorePropertiesFile.exists()
if (hasKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.example.farmctl"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Enable core library desugaring required by some dependencies
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.farmctl"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasKeystore) {
            create("release") {
                fun prop(key: String): String =
                    keystoreProperties[key] as? String
                        ?: error("$key missing from android/key.properties")
                keyAlias = prop("keyAlias")
                keyPassword = prop("keyPassword")
                storeFile = file(prop("storeFile"))
                storePassword = prop("storePassword")
            }
        }
    }

    buildTypes {
        release {
            // Use the real release signing config when key.properties is present,
            // otherwise fall back to debug keys so the build still produces an APK.
            signingConfig = if (hasKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Core library desugaring support library
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}

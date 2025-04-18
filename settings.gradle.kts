import org.gradle.kotlin.dsl.versionCatalogs

// Plugin repositories via pluginManagement
pluginManagement {
    repositories {
        gradlePluginPortal()
        google()
        mavenCentral()
    }
}

// Version catalog for dependencies
// (pluginManagement.versionCatalogs is not supported here)
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
    versionCatalogs {
        create("libs") {
            from(files("gradle/libs.versions.toml"))
        }
    }
}

// Project definition
rootProject.name = "MyAndroidApp"
include(":app") 
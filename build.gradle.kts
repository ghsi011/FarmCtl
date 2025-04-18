// AI GUIDANCE: Always use plugin aliases from the version catalog (libs.plugins.*) and avoid hardcoding plugin IDs or version placeholders.
// AI AGENTS: Do not define or update plugin versions directly here—instead, update them only in gradle/libs.versions.toml and rely on pluginManagement in settings.gradle.kts.

plugins {
    alias(libs.plugins.androidApp)      apply false
    alias(libs.plugins.kotlinAndroid)  apply false
    alias(libs.plugins.kotlinCompose)  apply false
    alias(libs.plugins.daggerHilt)     apply false
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
    // Link to version catalog
    versionCatalogs {
        create("libs") {
            from(files("gradle/libs.versions.toml"))
        }
    }
} 
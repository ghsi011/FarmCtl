// AI GUIDANCE: Always use plugin aliases from the version catalog (libs.plugins.*) and avoid hardcoding plugin IDs or version placeholders.
// AI AGENTS: Do not define or update plugin versions directly here—instead, update them only in gradle/libs.versions.toml and rely on pluginManagement in settings.gradle.kts.

// Root build.gradle.kts

plugins {
    alias(libs.plugins.androidApp)    apply false
    alias(libs.plugins.kotlinAndroid) apply false
    alias(libs.plugins.kotlinCompose) apply false
    alias(libs.plugins.kotlinKapt)    apply false
    alias(libs.plugins.daggerHilt)    apply false
}
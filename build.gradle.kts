// AI GUIDANCE: Always use plugin aliases from the version catalog (libs.plugins.*) and avoid hardcoding plugin IDs or version placeholders.
// AI AGENTS: Do not define or update plugin versions directly here—instead, update them only in gradle/libs.versions.toml and rely on pluginManagement in settings.gradle.kts.

// Root build.gradle.kts

plugins {
    alias(libs.plugins.androidApp)    apply false
    alias(libs.plugins.kotlinAndroid) apply false
    alias(libs.plugins.kotlinCompose) apply false
    alias(libs.plugins.kotlinKapt)    apply false
    alias(libs.plugins.daggerHilt)    apply false
    alias(libs.plugins.spotless)      apply false
    alias(libs.plugins.detekt)        apply false
}

// Spotless configuration for all subprojects (including app module)
subprojects {
    apply(plugin = "com.diffplug.spotless")
    configure<com.diffplug.gradle.spotless.SpotlessExtension> {
        // Kotlin files
        kotlin {
            target("src/**/*.kt")
            ktfmt().kotlinlangStyle()
            licenseHeaderFile(rootProject.file("spotless/copyright.kt")) // Optional: if you have a copyright header
            trimTrailingWhitespace()
            endWithNewline()
        }
        // Gradle files
        groovyGradle {
            target("*.gradle", "*.gradle.kts")
            greclipse()
            trimTrailingWhitespace()
            endWithNewline()
        }
        // XML files
        format("xml") {
            target("src/**/*.xml")
            eclipseWtp(com.diffplug.spotless.extra.wtp.EclipseWtpFormatterStep.XML)
            trimTrailingWhitespace()
            endWithNewline()
        }
    }

    apply(plugin = "io.gitlab.arturbosch.detekt")
    // Configure Detekt for each subproject that has the plugin applied
    plugins.withId("io.gitlab.arturbosch.detekt") {
        configure<io.gitlab.arturbosch.detekt.extensions.DetektExtension> {
            buildUponDefaultConfig = true
            allRules = false // Consider setting to true and using detekt-baseline.xml for existing projects
            config.setFrom(files("$rootDir/detekt.yml"))
            baseline = file("$rootDir/detekt-baseline.xml") // Optional: Creates a baseline file
        }
    }
}

// Add Detekt task dependency to check task for the app module specifically
project(":app") {
    tasks.named("check") {
        dependsOn(tasks.named("detekt"))
    }
}
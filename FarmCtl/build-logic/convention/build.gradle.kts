plugins {
    `kotlin-dsl`
}

group = "com.by.farm.buildlogic"

java {
    sourceCompatibility = JavaVersion.VERSION_11
    targetCompatibility = JavaVersion.VERSION_11
}

dependencies {
    compileOnly(libs.gradle.plugin.android)
    compileOnly(libs.gradle.plugin.kotlin)
}

gradlePlugin {
    plugins {
        register("coroutines") {
            id = "FarmCtl.coroutines"
            implementationClass = "CoroutinesConventionPlugin"
        }

        register("kotlinFeature") {
            id = "FarmCtl.kotlin.feature"
            implementationClass = "KotlinFeatureConventionPlugin"
        }
    }
}

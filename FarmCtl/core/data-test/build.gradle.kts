plugins {
    id("FarmCtl.kotlin.feature")
    id("FarmCtl.coroutines")
    id(libs.plugins.kotlin.serialization.get().pluginId)
}

dependencies {
    implementation(project(":core:commons"))
    implementation(project(":core:data"))

    implementation(libs.ktor.engine.mock)
}

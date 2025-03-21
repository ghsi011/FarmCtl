plugins {
    id("FarmCtl.kotlin.feature")
    id("FarmCtl.coroutines")
    id(libs.plugins.kotlin.serialization.get().pluginId)
}

dependencies {
    implementation(project(":core:commons"))
    api(libs.bundles.network)
    implementation(libs.datastore)

    testImplementation(project(":core:data-test"))
}

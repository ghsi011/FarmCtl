plugins {
    id("FarmCtl.kotlin.feature")
    id("FarmCtl.coroutines")
}

dependencies {
    implementation(project(":core:commons"))
    implementation(project(":core:data"))

    implementation(libs.bundles.javax)
}

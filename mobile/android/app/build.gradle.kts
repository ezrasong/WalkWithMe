import java.util.Properties

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}
android {
    namespace = "app.kaze.phone"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion
    defaultConfig {
        applicationId = "app.kaze.trail"
        minSdk = 28
        targetSdk = flutter.targetSdkVersion
        versionCode = 2
        versionName = "0.2"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    sourceSets.getByName("main") {
        java.srcDir("../../../android/phone/src/main/java")
        manifest.srcFile("../../../android/phone/src/main/AndroidManifest.xml")
    }
    buildTypes {
        debug { manifestPlaceholders["cleartextAllowed"] = "true" }
        release { manifestPlaceholders["cleartextAllowed"] = "false" }
    }
}
dependencies {
    implementation("com.google.ar:core:1.57.0")
    implementation("com.google.android.gms:play-services-auth:21.4.0")
    implementation("com.google.android.gms:play-services-location:21.3.0")
    implementation(project(":shared"))
    implementation("com.google.android.gms:play-services-wearable:19.0.0")
}
flutter { source = "../.." }

// Flutter can rewrite local.properties with unescaped Windows drive colons while
// compiling assets. Serialize with Java's standard writer immediately before
// lint reads it; keep lint enabled and preserve every decoded property value.
tasks.matching { it.name == "lintAnalyzeDebug" || it.name == "lintAnalyzeRelease" }.configureEach {
    doFirst {
        val file = rootProject.file("local.properties")
        if (file.exists()) {
            val properties = Properties()
            file.inputStream().use { properties.load(it) }
            file.outputStream().use { properties.store(it, null) }
        }
    }
}

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.apnacircle.app"
    // Regenerated with Flutter 3.35.7 template (22 Nov 2026, Run #8 fix):
    // the old Flutter 3.24 Groovy Gradle files are rejected by Flutter
    // 3.35 ("unsupported Gradle project"). Template is now Kotlin DSL.
    // compileSdk/targetSdk 35 (not 36): SDK 35 is guaranteed on the GitHub
    // runner; plugins that need 36 (geolocator_android) only log a warning.
    compileSdk = 35
    // NDK 27.0.12077973 = AGP 8.9.1 default.
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.apnacircle.app"
        // minSdk 24 = Android 7.0 (raised from 21 on 22 Nov 2026).
        // Flutter 3.35's Gradle plugin FAILS the build when minSdk < 23
        // and warns below 24, so Android 5.0/6.0 are no longer supported.
        minSdk = 24
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Google Maps key comes from gradle.properties / local.properties
        // (MAPS_API_KEY). Default is the placeholder — the map will not
        // load until a real key is set on the build machine. The key is
        // never hard-coded in source or committed to git.
        manifestPlaceholders["MAPS_API_KEY"] =
            if (project.hasProperty("MAPS_API_KEY")) {
                project.property("MAPS_API_KEY").toString()
            } else {
                "YOUR_GOOGLE_MAPS_API_KEY"
            }
        // AndroidManifest.xml uses ${applicationName}; Flutter's plugin
        // only injects it when defaultConfig does NOT override
        // manifestPlaceholders, so define it here or the manifest
        // merger fails (Run #7, 22 Nov 2026).
        manifestPlaceholders["applicationName"] =
            "io.flutter.app.FlutterApplication"
    }

    signingConfigs {
        // Release signing is configured on the build machine:
        // create a keystore with keytool, put its path/passwords in
        // android/key.properties (NEVER commit it). See README.
        create("release") {
            keyAlias = "apnacircle"
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Keep in step with the Kotlin plugin version in settings.gradle.kts (2.1.0).
    implementation("org.jetbrains.kotlin:kotlin-stdlib:2.1.0")
}

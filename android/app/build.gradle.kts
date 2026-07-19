import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releasePropertiesFile = rootProject.file("key.properties")
val releaseProperties = Properties()
val hasReleaseSigning = releasePropertiesFile.exists()
if (hasReleaseSigning) {
    FileInputStream(releasePropertiesFile).use(releaseProperties::load)
    val requiredKeys = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
    val missingKeys = requiredKeys.filter { releaseProperties.getProperty(it).isNullOrBlank() }
    if (missingKeys.isNotEmpty()) {
        throw GradleException(
            "android/key.properties に必要な項目がありません: ${missingKeys.joinToString()}",
        )
    }
}

android {
    namespace = "com.sukashiform.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                keyAlias = releaseProperties.getProperty("keyAlias")
                keyPassword = releaseProperties.getProperty("keyPassword")
                storeFile = rootProject.file(releaseProperties.getProperty("storeFile"))
                storePassword = releaseProperties.getProperty("storePassword")
            }
        }
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.sukashiform.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 28
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

tasks.configureEach {
    if (name == "packageRelease" || name == "bundleRelease" || name == "packageReleaseBundle") {
        doFirst {
            if (!hasReleaseSigning) {
                throw GradleException(
                    "release署名情報がありません。docs/17_リリース署名手順.md に従って " +
                        "android/key.properties を用意してください。署名鍵をGitへ追加しないでください。",
                )
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

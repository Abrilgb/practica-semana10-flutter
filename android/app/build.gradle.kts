import java.io.FileInputStream
import java.util.Properties
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("kotlin-android")
    // El plugin de Flutter debe aplicarse después de los plugins de Android y Kotlin.
    id("dev.flutter.flutter-gradle-plugin")
}

// --- Lectura segura de la API Key desde android/local.properties (ignorado por Git) ---
val localProperties = Properties().apply {
    val archivo = rootProject.file("local.properties")
    if (archivo.exists()) {
        FileInputStream(archivo).use { load(it) }
    }
}
val mapsApiKey: String = localProperties.getProperty("maps.apikey")?.trim() ?: ""

// Falla con un mensaje claro si se intenta compilar/instalar sin una clave válida.
gradle.taskGraph.whenReady {
    val compilando = allTasks.any {
        it.name.startsWith("assemble") ||
            it.name.startsWith("bundle") ||
            it.name.startsWith("install")
    }
    if (compilando && !mapsApiKey.startsWith("AIza")) {
        throw GradleException(
            "Falta la API Key de Google Maps. Agrega la línea " +
                "'maps.apikey=TU_CLAVE' en android/local.properties."
        )
    }
}

android {
    namespace = "com.utxj.localizador_poi"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.utxj.localizador_poi"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Inyección en el manifiesto: ${MAPS_API_KEY}
        manifestPlaceholders["MAPS_API_KEY"] = mapsApiKey
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

flutter {
    source = "../.."
}

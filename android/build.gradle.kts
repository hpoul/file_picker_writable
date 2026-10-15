plugins {
    id 'com.android.library'
    id 'org.jetbrains.kotlin.android'
}

group 'codeux.design.filepicker.file_picker_writable'
version '1.0-SNAPSHOT'

android {
    namespace "codeux.design.filepicker.file_picker_writable"
    compileSdk 36

    compileOptions {
        sourceCompatibility JavaVersion.VERSION_17
        targetCompatibility JavaVersion.VERSION_17
    }

    sourceSets {
        main.java.srcDirs += 'src/main/kotlin'
        test.java.srcDirs += 'src/test/kotlin'
    }
    defaultConfig {
        minSdkVersion 24
    }
    lint {
        disable 'InvalidPackage'
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    api "org.jetbrains.kotlinx:kotlinx-coroutines-core:1.6.4"
    implementation "org.jetbrains.kotlinx:kotlinx-coroutines-android:1.6.4"
    testImplementation "junit:junit:4.13.2"
}

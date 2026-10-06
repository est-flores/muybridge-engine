plugins {
    id("com.android.library") version "8.2.0"
    id("org.jetbrains.kotlin.android") version "1.9.22"
    id("maven-publish")
    id("signing")
}

// Version configuration
val libraryVersion = "1.0.0"
val libraryGroup = "com.muybridge"
val libraryArtifact = "player"

android {
    namespace = "com.muybridge.player"
    compileSdk = 34

    defaultConfig {
        minSdk = 24
        
        consumerProguardFiles("consumer-rules.pro")
        
        externalNativeBuild {
            cmake {
                cppFlags("-std=c++17", "-Wall", "-Wextra", "-O3", "-flto")
                arguments("-DANDROID_STL=c++_shared")
            }
        }
        
        ndk {
            abiFilters.addAll(listOf("arm64-v8a", "armeabi-v7a"))
        }
        
        aarMetadata {
            minCompileSdk = 24
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    externalNativeBuild {
        cmake {
            path = file("CMakeLists.txt")
            version = "3.22.1"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    sourceSets {
        getByName("main") {
            kotlin.srcDirs("kotlin")
        }
    }
    
    publishing {
        singleVariant("release") {
            withSourcesJar()
        }
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
}

// Maven Publishing
publishing {
    publications {
        create<MavenPublication>("release") {
            groupId = libraryGroup
            artifactId = libraryArtifact
            version = libraryVersion

            afterEvaluate {
                from(components["release"])
            }

            pom {
                name.set("Muybridge Player")
                description.set("Hardware-accelerated video player for Android")
                url.set("https://github.com/est-flores/muybridge-engine")
                
                licenses {
                    license {
                        name.set("All rights reserved")
                        comments.set("Copyright Formula Systems, LLC. All rights reserved. The source is published for reference; no license to use, copy or distribute it is granted.")
                    }
                }
                
                developers {
                    developer {
                        id.set("muybridge")
                        name.set("Muybridge Team")
                    }
                }
                
                scm {
                    connection.set("scm:git:git://github.com/est-flores/muybridge-engine.git")
                    url.set("https://github.com/est-flores/muybridge-engine")
                }
            }
        }
    }

    repositories {
        maven {
            name = "GitHubPackages"
            url = uri("https://maven.pkg.github.com/est-flores/muybridge-engine")
            credentials {
                username = System.getenv("GITHUB_ACTOR") ?: ""
                password = System.getenv("ACCESS_TOKEN") ?: ""
            }
        }
        
        // Local publishing for testing
        maven {
            name = "local"
            url = uri(layout.buildDirectory.dir("repo"))
        }
    }
}

// Signing (for Maven Central)
signing {
    val signingKey = System.getenv("SIGNING_KEY")
    val signingPassword = System.getenv("SIGNING_PASSWORD")
    if (signingKey != null && signingPassword != null) {
        useInMemoryPgpKeys(signingKey, signingPassword)
        sign(publishing.publications["release"])
    }
}

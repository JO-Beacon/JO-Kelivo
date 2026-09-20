allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Flutter 的 integration_test 插件要求 androidx.test:runner:1.2+。
// 动态版本会去查询每个仓库的 maven-metadata.xml；Maven Central 一旦出现
// TLS／404 抖动，整个依赖解析就会失败，哪怕 Google Maven 上有这个包。
subprojects {
    configurations.configureEach {
        resolutionStrategy.eachDependency {
            if (requested.group == "androidx.test" && requested.name == "runner") {
                useVersion("1.5.2")
                because("pin past dynamic 1.2+ metadata fetch")
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

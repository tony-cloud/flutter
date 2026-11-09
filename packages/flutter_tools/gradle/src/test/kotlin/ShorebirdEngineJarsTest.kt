// Copyright 2026 The Open Shorebird Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package com.flutter.gradle

import com.flutter.gradle.tasks.BaseFlutterTask
import com.flutter.gradle.tasks.BaseFlutterTaskHelper
import io.mockk.every
import io.mockk.mockk
import io.mockk.slot
import org.gradle.api.file.FileCollection
import org.gradle.api.tasks.InputFiles
import org.gradle.api.tasks.Optional
import org.gradle.process.ExecSpec
import org.gradle.process.ProcessForkOptions
import org.gradle.testfixtures.ProjectBuilder
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ShorebirdEngineJarsTest {
    private val hardened = mapOf("SHOREBIRD_SECURITY_PROFILE" to "hardened")

    @Test
    fun `only hardened builds hand engine jars to flutter assemble`() {
        assertTrue(ShorebirdEngineJars.isHardened(hardened))
        assertTrue(ShorebirdEngineJars.isHardened(mapOf("SHOREBIRD_SECURITY_PROFILE" to "hardened-diversified")))
        assertFalse(ShorebirdEngineJars.isHardened(emptyMap()))
        assertFalse(ShorebirdEngineJars.isHardened(mapOf("SHOREBIRD_SECURITY_PROFILE" to "legacy")))
        // A legacy build never touches the project's configurations.
        assertNull(ShorebirdEngineJars.forVariant(mockk(), "release", "release", emptyMap()))
    }

    @Test
    fun `engine modules are the per-ABI io_flutter jars of the build mode`() {
        assertTrue(ShorebirdEngineJars.isEngineModule("io.flutter", "arm64_v8a_release", "release"))
        assertTrue(ShorebirdEngineJars.isEngineModule("io.flutter", "x86_64_release", "release"))
        assertFalse(ShorebirdEngineJars.isEngineModule("io.flutter", "flutter_embedding_release", "release"))
        assertFalse(ShorebirdEngineJars.isEngineModule("io.flutter", "arm64_v8a_debug", "release"))
        assertFalse(ShorebirdEngineJars.isEngineModule("com.example", "arm64_v8a_release", "release"))
    }

    @Test
    fun `the environment is a sorted JSON array of absolute paths`() {
        val environment = ShorebirdEngineJars.environment(listOf(File("/m/x86_64.jar"), File("/m/arm64.jar")))
        assertEquals(mapOf("SHOREBIRD_ANDROID_ENGINE_JARS" to """["/m/arm64.jar","/m/x86_64.jar"]"""), environment)
    }

    @Test
    fun `resolves exactly the engine jars of the variant runtime classpath`() {
        val repository = createTempDirectory("shorebird-maven").toFile()
        try {
            fun publish(module: String): File {
                val directory = File(repository, "io/flutter/$module/1.0.0-abc")
                directory.mkdirs()
                File(directory, "$module-1.0.0-abc.pom").writeText(
                    """
                    <project xmlns="http://maven.apache.org/POM/4.0.0">
                      <modelVersion>4.0.0</modelVersion>
                      <groupId>io.flutter</groupId>
                      <artifactId>$module</artifactId>
                      <version>1.0.0-abc</version>
                    </project>
                    """.trimIndent()
                )
                val jar = File(directory, "$module-1.0.0-abc.jar")
                ZipOutputStream(jar.outputStream()).use {
                    it.putNextEntry(ZipEntry("lib/arm64-v8a/libflutter.so"))
                    it.write(byteArrayOf(0x7f))
                    it.closeEntry()
                }
                return jar
            }
            val engine = publish("arm64_v8a_release")
            publish("flutter_embedding_release")
            val project = ProjectBuilder.builder().build()
            project.repositories.maven { url = repository.toURI() }
            val configuration = project.configurations.create("freeReleaseRuntimeClasspath")
            project.dependencies.add(configuration.name, "io.flutter:arm64_v8a_release:1.0.0-abc")
            project.dependencies.add(configuration.name, "io.flutter:flutter_embedding_release:1.0.0-abc")
            val jars = ShorebirdEngineJars.forVariant(project, "freeRelease", "release", hardened)!!
            assertEquals(setOf(engine.canonicalFile), jars.files.map { it.canonicalFile }.toSet())
            // An unknown variant has nothing to bind; flutter_tools then refuses the build.
            assertNull(ShorebirdEngineJars.forVariant(project, "paidRelease", "release", hardened))
        } finally {
            repository.deleteRecursively()
        }
    }

    @Test
    fun `the jars are an optional task input and reach flutter assemble through its environment`() {
        val getter = BaseFlutterTask::class.java.getMethod("getShorebirdEngineJars")
        assertTrue(getter.isAnnotationPresent(InputFiles::class.java))
        assertTrue(getter.isAnnotationPresent(Optional::class.java))

        val task = mockk<BaseFlutterTask>(relaxed = true)
        val jars = mockk<FileCollection>()
        every { jars.files } returns setOf(File("/m/arm64.jar"))
        every { task.sourceDir } returns File("/project")
        every { task.flutterExecutable } returns File("/flutter/bin/flutter")
        every { task.localEngine } returns null
        every { task.localEngineHost } returns null
        every { task.verbose } returns false
        every { task.buildMode } returns "release"
        every { task.deferredComponents } returns false
        every { task.targetPlatformValues } returns listOf("android-arm64")
        every { task.shorebirdEngineJars } returns jars
        val spec = mockk<ExecSpec>(relaxed = true)
        val environment = slot<Map<String, Any>>()
        every { spec.environment(capture(environment)) } returns spec
        every { spec.workingDir(any()) } returns mockk<ProcessForkOptions>()
        BaseFlutterTaskHelper.createExecSpecActionFromTask(task).execute(spec)
        assertEquals(mapOf<String, Any>("SHOREBIRD_ANDROID_ENGINE_JARS" to """["/m/arm64.jar"]"""), environment.captured)
    }
}

// Copyright 2026 The Open Shorebird Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package com.flutter.gradle

import groovy.json.JsonOutput
import org.gradle.api.Project
import org.gradle.api.artifacts.component.ComponentIdentifier
import org.gradle.api.artifacts.component.ModuleComponentIdentifier
import org.gradle.api.file.FileCollection
import java.io.File

/**
 * Shorebird-specific (hardening P6, shorebird-workspace
 * `docs/HARDENING_CONTRACTS.md` §12): the engine jars a hardened Android build
 * packages.
 *
 * The signed build manifest in the bundled `shorebird.yaml` binds the
 * measurement of every `libflutter.so` the app ships. Those libraries reach
 * the APK or app bundle through Gradle's Maven resolution of
 * `io.flutter:<abi>_<mode>`, which `flutter assemble` cannot see, so the
 * plugin hands it the exact jars it resolved for the variant. Legacy builds
 * get nothing: their task inputs and `flutter assemble` environment are
 * unchanged.
 */
object ShorebirdEngineJars {
    /** JSON array of absolute jar paths, read by flutter_tools. */
    const val ENGINE_JARS_ENV = "SHOREBIRD_ANDROID_ENGINE_JARS"

    private const val SECURITY_PROFILE_ENV = "SHOREBIRD_SECURITY_PROFILE"
    private val hardenedProfiles = setOf("hardened", "hardened-diversified")

    /** Whether [environment] selects a hardened build. */
    fun isHardened(environment: Map<String, String>): Boolean = environment[SECURITY_PROFILE_ENV] in hardenedProfiles

    /** Whether a dependency is an engine jar (not the embedding) for [buildMode]. */
    fun isEngineModule(
        group: String,
        module: String,
        buildMode: String
    ): Boolean =
        group == "io.flutter" &&
            module.endsWith("_$buildMode") &&
            !module.startsWith("flutter_embedding_")

    private fun isEngineComponent(
        id: ComponentIdentifier,
        buildMode: String
    ): Boolean = id is ModuleComponentIdentifier && isEngineModule(id.group, id.module, buildMode)

    /**
     * The engine jars of [variantName]'s runtime classpath, resolved lazily
     * when the task's inputs are computed, or null when [environment] is not
     * hardened (so a legacy build never resolves anything extra).
     */
    fun forVariant(
        project: Project,
        variantName: String,
        buildMode: String,
        environment: Map<String, String>
    ): FileCollection? {
        if (!isHardened(environment)) {
            return null
        }
        val configuration =
            project.configurations.findByName("${variantName}RuntimeClasspath") ?: return null
        return configuration.incoming
            .artifactView {
                componentFilter { isEngineComponent(it, buildMode) }
            }.files
    }

    /** The `flutter assemble` environment entry for [jars]. */
    fun environment(jars: Collection<File>): Map<String, String> =
        mapOf(ENGINE_JARS_ENV to JsonOutput.toJson(jars.map { it.absolutePath }.sorted()))
}

// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:yaml/yaml.dart';

import '../base/file_system.dart';
import 'shorebird_aot_link.dart';

/// Source YAML opt-in for baselines that support structural bytecode updates.
const kShorebirdStructuralUpdatesKey = 'aot_patch_structural_updates';

/// Source YAML opt-in for complete mutable-domain replacement.
const kShorebirdFullReplacementKey = 'aot_patch_full_replacement';

/// Validates the source-owned full replacement compiler profile.
bool shorebirdFullReplacementEnabled(Map<Object?, Object?> configuration) {
  final Object? value = configuration[kShorebirdFullReplacementKey];
  if (!configuration.containsKey(kShorebirdFullReplacementKey)) {
    return false;
  }
  if (value is! bool) {
    throw const FormatException('aot_patch_full_replacement must be a YAML boolean');
  }
  if (value && configuration['aot_patch_runtime_mode'] != 'dart-bytecode-interpreter') {
    throw const FormatException(
      'aot_patch_full_replacement requires aot_patch_runtime_mode: dart-bytecode-interpreter',
    );
  }
  if (value && configuration[kShorebirdStructuralUpdatesKey] == true) {
    throw const FormatException(
      'aot_patch_full_replacement and aot_patch_structural_updates are mutually exclusive',
    );
  }
  return value;
}

/// Reads and validates the source profile, which must match all build stages.
///
/// The profile has no environment override: the CLI checks it against the
/// immutable release baseline before compiling a patch.
bool shorebirdStructuralUpdatesEnabled(Map<Object?, Object?> configuration) {
  if (!configuration.containsKey(kShorebirdStructuralUpdatesKey)) {
    return false;
  }
  final Object? value = configuration[kShorebirdStructuralUpdatesKey];
  if (value is! bool) {
    throw const FormatException('aot_patch_structural_updates must be a YAML boolean');
  }
  if (value && configuration['aot_patch_runtime_mode'] != 'dart-bytecode-interpreter') {
    throw const FormatException(
      'aot_patch_structural_updates requires aot_patch_runtime_mode: dart-bytecode-interpreter',
    );
  }
  return value;
}

YamlMap? _readConfiguration(FileSystem fileSystem, Directory? projectDirectory) {
  final File config = (projectDirectory ?? fileSystem.currentDirectory).childFile('shorebird.yaml');
  if (!config.existsSync()) {
    return null;
  }
  final Object? yaml = loadYaml(config.readAsStringSync());
  return yaml is YamlMap ? yaml : null;
}

/// Normalizes Flutter's desktop platform name to the compiler target OS.
String? shorebirdTargetOS(String? targetOS) => targetOS == 'darwin' ? 'macos' : targetOS;

/// Selects the supported interpreter compiler profile for the actual target.
/// macOS currently implements complete replacement only, with no body-only or
/// additive structural update route.
bool shorebirdUsesBytecodeInterpreter(
  FileSystem fileSystem,
  String? targetOS, {
  Directory? projectDirectory,
}) {
  targetOS = shorebirdTargetOS(targetOS);
  if (targetOS != 'ios' && targetOS != 'macos') {
    return false;
  }
  final YamlMap? yaml = _readConfiguration(fileSystem, projectDirectory);
  if (yaml == null) {
    return false;
  }
  shorebirdStructuralUpdatesEnabled(yaml);
  final bool full = shorebirdFullReplacementEnabled(yaml);
  final interpreter = yaml['aot_patch_runtime_mode'] == 'dart-bytecode-interpreter';
  if (targetOS == 'macos' && interpreter && !full) {
    throw const FormatException('macOS interpreter builds require full replacement');
  }
  return interpreter;
}

/// Selects the public AOT baseline for no-JIT bytecode interpreter updates.
///
/// This route disables type-flow analysis to preserve ordinary patch targets
/// and skips the native linker metadata and DD pass. Other routes keep their
/// existing compiler behavior.
bool shorebirdUsesIosBytecodeInterpreter(
  FileSystem fileSystem,
  String? targetOS, {
  Directory? projectDirectory,
}) {
  return targetOS == 'ios' &&
      shorebirdUsesBytecodeInterpreter(fileSystem, targetOS, projectDirectory: projectDirectory);
}

/// Enables the structural compiler profile only for opted-in iOS baselines.
bool shorebirdUsesIosStructuralUpdates(
  FileSystem fileSystem,
  String? targetOS, {
  Directory? projectDirectory,
}) {
  if (targetOS != 'ios') {
    return false;
  }
  final YamlMap? yaml = _readConfiguration(fileSystem, projectDirectory);
  if (yaml == null) {
    return false;
  }
  shorebirdFullReplacementEnabled(yaml);
  return shorebirdStructuralUpdatesEnabled(yaml);
}

/// Enables complete-domain replacement for opted-in iOS and macOS baselines.
bool shorebirdUsesFullReplacement(
  FileSystem fileSystem,
  String? targetOS, {
  Directory? projectDirectory,
}) {
  final YamlMap? yaml = _readConfiguration(fileSystem, projectDirectory);
  if (yaml == null) {
    return false;
  }
  shorebirdStructuralUpdatesEnabled(yaml);
  final bool enabled = shorebirdFullReplacementEnabled(yaml);
  targetOS = shorebirdTargetOS(targetOS);
  if (targetOS == 'macos') {
    shorebirdUsesBytecodeInterpreter(fileSystem, targetOS, projectDirectory: projectDirectory);
  }
  if (enabled && targetOS != 'ios' && targetOS != 'macos') {
    throw const FormatException('aot_patch_full_replacement is supported only on iOS and macOS');
  }
  return enabled;
}

/// Selects the iOS linked AOT profile (`aot-link`): native AOT whose patches
/// are linked against the release (`aot_patch_runtime_mode: ios-aot-link`).
bool shorebirdUsesAotLink(FileSystem fileSystem, String? targetOS, {Directory? projectDirectory}) {
  final YamlMap? yaml = _readConfiguration(fileSystem, projectDirectory);
  if (yaml == null) {
    return false;
  }
  final bool enabled = shorebirdUsesAotLinkMode(
    yaml['aot_patch_runtime_mode'] as String?,
    shorebirdTargetOS(targetOS),
  );
  if (enabled) {
    // These profiles require the interpreter runtime mode; reject the mix with
    // the same message as everywhere else.
    shorebirdStructuralUpdatesEnabled(yaml);
    shorebirdFullReplacementEnabled(yaml);
  }
  return enabled;
}

/// Retains the iOS-only selector for existing callers.
bool shorebirdUsesIosFullReplacement(
  FileSystem fileSystem,
  String? targetOS, {
  Directory? projectDirectory,
}) {
  final bool enabled = shorebirdUsesFullReplacement(
    fileSystem,
    targetOS,
    projectDirectory: projectDirectory,
  );
  return targetOS == 'ios' && enabled;
}

/// Prevents LinkSupplement from collecting stale private native linker tables
/// when a previous build used the legacy native linker.
void shorebirdRemoveNativeLinkOutputs(Directory buildDirectory, {bool keepAotLink = false}) {
  for (final name in <String>[
    'App.class_table.json',
    'App.ct.link',
    'App.field_table.json',
    'App.ft.link',
    'App.dispatch_table.json',
    'App.dt.link',
    'App.dd_identity.link',
    'App.dd.link',
    'App.dd_callers.link',
    'App.dd_slots.link',
    'App.dd_resolution.tsv',
    // The linked AOT profile's sidecars. A release/patch of another profile
    // must not ship them.
    if (!keepAotLink) ...kShorebirdAotLinkSupplementFiles,
  ]) {
    final File file = buildDirectory.childFile(name);
    if (file.existsSync()) {
      file.deleteSync();
    }
  }
}

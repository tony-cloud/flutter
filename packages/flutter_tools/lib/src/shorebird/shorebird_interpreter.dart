// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:yaml/yaml.dart';

import '../base/file_system.dart';

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
  if (targetOS != 'ios') {
    return false;
  }
  final File config = (projectDirectory ?? fileSystem.currentDirectory).childFile('shorebird.yaml');
  if (!config.existsSync()) {
    return false;
  }
  final Object? yaml = loadYaml(config.readAsStringSync());
  return yaml is YamlMap && yaml['aot_patch_runtime_mode'] == 'dart-bytecode-interpreter';
}

/// Prevents LinkSupplement from collecting stale private native linker tables
/// when a previous build used the legacy native linker.
void shorebirdRemoveNativeLinkOutputs(Directory buildDirectory) {
  for (final name in const <String>[
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
  ]) {
    final File file = buildDirectory.childFile(name);
    if (file.existsSync()) {
      file.deleteSync();
    }
  }
}

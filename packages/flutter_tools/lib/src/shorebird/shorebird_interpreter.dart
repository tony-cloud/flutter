// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:yaml/yaml.dart';

import '../base/file_system.dart';

/// Keeps ordinary function bodies available for no-JIT interpreter updates.
///
/// AOT type-flow analysis can inline/remove patch targets and their callers.
/// Only an explicit interpreter baseline disables that optimization on iOS.
bool shorebirdInterpreterDisablesTfa(
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

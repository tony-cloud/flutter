// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/shorebird/shorebird_selection.dart';
import 'package:flutter_tools/src/shorebird/shorebird_yaml.dart';
import 'package:yaml/yaml.dart';

import '../../src/common.dart';

void main() {
  testWithoutContext('v2 binds exact original baseline and seven-field scope', () {
    final fs = MemoryFileSystem.test();
    final File base = fs.file('/original.bytecode')..writeAsStringSync('original baseline');
    final hash = sha256.convert(base.readAsBytesSync()).toString();
    final scope = <String, Object?>{
      'app_id': '11111111-1111-4111-8111-111111111111',
      'release_version': '1.0.0+1',
      'platform': 'ios',
      'arch': 'aarch64',
      'base_artifact_hash': hash,
      'host_abi_hash': null,
      'runtime_profile': 'interpreter-body',
    };
    final env = <String, String>{
      kShorebirdReleaseScopeEnvVar: jsonEncode(scope),
      kShorebirdInterpreterBaseEnvVar: base.path,
    };
    final inputs = ShorebirdSelectionInputs.read(fs, env);
    expect(inputs.assetName, 'shorebird_release_scope_ios_aarch64.json');
    expect(inputs.baselineAsset, 'shorebird_interpreter_base.bytecode');
    base.writeAsStringSync('new variant');
    expect(() => ShorebirdSelectionInputs.read(fs, env), throwsFormatException);
    expect(
      () => ShorebirdSelectionInputs.read(fs, <String, String>{
        ...env,
        kShorebirdReleaseScopeEnvVar: jsonEncode(<String, Object?>{...scope, 'variant': 'pro'}),
      }),
      throwsFormatException,
    );
  });
  testWithoutContext('v2 YAML rejects missing binding; omission retains v1', () {
    final yaml =
        loadYaml('''
app_id: 11111111-1111-4111-8111-111111111111
selection_protocol: 2
aot_patch_runtime_mode: dart-bytecode-interpreter
aot_patch_base_snapshot_hash: ${'11' * 32}
patch_public_key: pinned-key
''')
            as YamlMap;
    expect(
      () => compileShorebirdYaml(
        yaml,
        flavor: null,
        environment: <String, String>{},
        fileSystem: MemoryFileSystem.test(),
      ),
      throwsFormatException,
    );
    final Map<String, dynamic> legacy = compileShorebirdYaml(
      loadYaml('app_id: app') as YamlMap,
      flavor: null,
      environment: <String, String>{},
    );
    expect(legacy.containsKey('selection_protocol'), isFalse);
  });
}

// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import '../base/file_system.dart';
import '../globals.dart' as globals;
import 'shorebird_interpreter.dart';
import 'shorebird_replacement.dart';

/// The environment variable whose value is written to the generated
/// shorebird.yaml as `patch_public_key`.
const kShorebirdPublicKeyEnvVar = 'SHOREBIRD_PUBLIC_KEY';

/// SHA-256 derived from the release bytecode before sealing bundled assets.
const kShorebirdAotBaseSnapshotHashEnvVar = 'SHOREBIRD_AOT_BASE_SNAPSHOT_HASH';

void updateShorebirdYaml(
  String? flavor,
  String shorebirdYamlPath, {
  required Map<String, String> environment,
  FileSystem? fileSystem,
}) {
  final File shorebirdYaml = (fileSystem ?? globals.fs).file(shorebirdYamlPath);
  if (!shorebirdYaml.existsSync()) {
    throw Exception('shorebird.yaml not found at $shorebirdYamlPath');
  }
  final YamlDocument input = loadYamlDocument(shorebirdYaml.readAsStringSync());
  final yamlMap = input.contents as YamlMap;
  final Map<String, dynamic> compiled = compileShorebirdYaml(
    yamlMap,
    flavor: flavor,
    environment: environment,
    fileSystem: fileSystem,
  );
  // Currently we write out over the same yaml file, we should fix this to
  // write to a new .json file instead and avoid naming confusion between the
  // input and compiled files.
  final yamlEditor = YamlEditor('');
  yamlEditor.update(<Object?>[], compiled);
  shorebirdYaml.writeAsStringSync(yamlEditor.toString(), flush: true);
}

String appIdForFlavor(YamlMap yamlMap, {required String? flavor}) {
  if (flavor == null || flavor.isEmpty) {
    final defaultAppId = yamlMap['app_id'] as String?;
    if (defaultAppId == null || defaultAppId.isEmpty) {
      throw Exception('Cannot find "app_id" in shorebird.yaml');
    }
    return defaultAppId;
  }

  final yamlFlavors = yamlMap['flavors'] as YamlMap?;
  if (yamlFlavors == null) {
    throw Exception('Cannot find "flavors" in shorebird.yaml.');
  }
  final flavorAppId = yamlFlavors[flavor] as String?;
  if (flavorAppId == null || flavorAppId.isEmpty) {
    throw Exception('Cannot find "app_id" for $flavor in shorebird.yaml');
  }
  return flavorAppId;
}

Map<String, dynamic> compileShorebirdYaml(
  YamlMap yamlMap, {
  required String? flavor,
  required Map<String, String> environment,
  FileSystem? fileSystem,
}) {
  final String appId = appIdForFlavor(yamlMap, flavor: flavor);
  final bool structuralUpdates = shorebirdStructuralUpdatesEnabled(yamlMap);
  final bool fullReplacement = shorebirdFullReplacementEnabled(yamlMap);
  final compiled = <String, dynamic>{'app_id': appId};
  if (yamlMap.containsKey(kShorebirdStructuralUpdatesKey)) {
    compiled[kShorebirdStructuralUpdatesKey] = structuralUpdates;
  }
  if (yamlMap.containsKey(kShorebirdFullReplacementKey)) {
    compiled[kShorebirdFullReplacementKey] = fullReplacement;
  }
  void copyIfSet(String key) {
    if (yamlMap[key] != null) {
      compiled[key] = yamlMap[key];
    }
  }

  copyIfSet('base_url');
  copyIfSet('auto_update');
  copyIfSet('patch_verification');
  copyIfSet('patch_response_verification');
  copyIfSet('patch_public_key');
  // Expectations are public policy, copied from the signed app's build input.
  // The AES key and patch-only paths/hashes must never enter bundled assets.
  const interpreterFields = <String>[
    'aot_patch_runtime_mode',
    'aot_patch_app_build_id',
    'aot_patch_base_flavor_id',
    'aot_patch_base_license_type',
    'aot_patch_flavor_id',
    'aot_patch_license_type',
    'aot_patch_sdk_hash',
    'aot_patch_base_snapshot_hash',
    'aot_patch_obfuscation_map_hash',
    'aot_patch_key_id',
  ];
  for (final key in interpreterFields) {
    final String? override = environment['SHOREBIRD_${key.toUpperCase()}'];
    if (override != null) {
      // A patch build can restore the release's absent optional restriction
      // even when its source YAML names the desired upgrade target.
      if (override.isEmpty &&
          const <String>{
            'aot_patch_app_build_id',
            'aot_patch_flavor_id',
            'aot_patch_license_type',
            'aot_patch_obfuscation_map_hash',
          }.contains(key)) {
        continue;
      }
      compiled[key] = override;
    } else {
      copyIfSet(key);
    }
  }
  final String? baseHash = environment[kShorebirdAotBaseSnapshotHashEnvVar];
  if (baseHash != null) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(baseHash)) {
      throw Exception('$kShorebirdAotBaseSnapshotHashEnvVar must be a lowercase SHA-256');
    }
    compiled['aot_patch_base_snapshot_hash'] = baseHash;
  }

  final String? shorebirdPublicKeyEnvVar = environment[kShorebirdPublicKeyEnvVar];
  if (shorebirdPublicKeyEnvVar != null) {
    compiled['patch_public_key'] = shorebirdPublicKeyEnvVar;
  }
  if (compiled['patch_public_key'] is String &&
      (compiled['patch_public_key'] as String).trim().isNotEmpty) {
    compiled.putIfAbsent('patch_response_verification', () => 'required');
  }
  if (compiled['aot_patch_runtime_mode'] == 'dart-bytecode-interpreter') {
    final Object? publicKey = compiled['patch_public_key'];
    if (publicKey is! String || publicKey.trim().isEmpty) {
      throw Exception(
        'Interpreter patches require a pinned patch_public_key or SHOREBIRD_PUBLIC_KEY',
      );
    }
    compiled['patch_verification'] = 'strict';
    compiled['patch_response_verification'] = 'required';
  }
  // Runtime policy overrides must not contradict the source compiler profile.
  shorebirdStructuralUpdatesEnabled(compiled);
  shorebirdFullReplacementEnabled(compiled);
  if (fullReplacement) {
    final inputs = ShorebirdReplacementInputs.read(fileSystem ?? globals.fs, environment);
    compiled['aot_patch_replacement_base'] = kShorebirdReplacementBaseAsset;
    compiled['aot_patch_host_abi'] = inputs.hostAbi;
    compiled['aot_patch_base_snapshot_hash'] = inputs.snapshotHash;
  }
  return compiled;
}

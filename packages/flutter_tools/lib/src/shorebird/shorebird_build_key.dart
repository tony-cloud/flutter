// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../build_info.dart';
import '../build_system/build_system.dart';
import 'shorebird_dd.dart';
import 'shorebird_interpreter.dart';
import 'shorebird_replacement.dart';
import 'shorebird_replacement_host.dart';
import 'shorebird_yaml.dart';

/// Folds a digest of Shorebird environment [values] into [buildKey].
///
/// Only the SHA-256 digest reaches the stamp file, never the values.
/// Returns [buildKey] unchanged when [values] is empty, so a build without
/// Shorebird environment variables keeps its existing stamps.
String? _withShorebirdDigest(String? buildKey, Map<String, String> values) {
  if (values.isEmpty) {
    return buildKey;
  }
  final digest = sha256.convert(utf8.encode(jsonEncode(values))).toString();
  return jsonEncode(<String, String>{'buildKey': ?buildKey, 'shorebird': digest});
}

/// Reruns asset bundling when the signing key or public baseline policy changes.
///
/// `copyAssets` writes the key into the generated shorebird.yaml in
/// flutter_assets, but the variable is not a define, so it is not part of the
/// build directory hash.
mixin ShorebirdPublicKeyBuildKey on Target {
  @override
  String? buildKeyFor(Environment environment) {
    final String? publicKey = environment.platform.environment[kShorebirdPublicKeyEnvVar];
    return _withShorebirdDigest(super.buildKeyFor(environment), <String, String>{
      kShorebirdPublicKeyEnvVar: ?publicKey,
      ..._replacementBuildKey(environment),
      for (final String key in const <String>[
        'SHOREBIRD_AOT_BASE_SNAPSHOT_HASH',
        'SHOREBIRD_AOT_PATCH_BASE_SNAPSHOT_HASH',
        'SHOREBIRD_AOT_PATCH_RUNTIME_MODE',
        'SHOREBIRD_AOT_PATCH_APP_BUILD_ID',
        'SHOREBIRD_AOT_PATCH_BASE_FLAVOR_ID',
        'SHOREBIRD_AOT_PATCH_BASE_LICENSE_TYPE',
        'SHOREBIRD_AOT_PATCH_FLAVOR_ID',
        'SHOREBIRD_AOT_PATCH_LICENSE_TYPE',
        'SHOREBIRD_AOT_PATCH_SDK_HASH',
        'SHOREBIRD_AOT_PATCH_OBFUSCATION_MAP_HASH',
        'SHOREBIRD_AOT_PATCH_KEY_ID',
      ])
        key: ?environment.platform.environment[key],
    });
  }
}

/// Reruns an AOT target when `SHOREBIRD_DD_MAX_BYTES` changes.
///
/// Only targets whose snapshot build runs the DD pass need this, which today
/// is iOS alone (see `AOTSnapshotter.build`).
mixin ShorebirdDdMaxBytesBuildKey on Target {
  @override
  String? buildKeyFor(Environment environment) {
    final int ddMaxBytes = shorebirdDdMaxBytes(environment.platform.environment);
    return _withShorebirdDigest(super.buildKeyFor(environment), <String, String>{
      if (ddMaxBytes > 0) kShorebirdDdMaxBytesEnvVar: '$ddMaxBytes',
    });
  }
}

/// Reruns Apple AOT targets when opting into or out of private linker metadata.
mixin ShorebirdLegacyNativeLinkerBuildKey on Target {
  @override
  String? buildKeyFor(Environment environment) =>
      _withShorebirdDigest(super.buildKeyFor(environment), <String, String>{
        if (shorebirdLegacyAotToolsEnabled(environment.platform.environment))
          kShorebirdLegacyAotToolsEnvVar: 'true',
      });
}

/// Invalidates kernel and AOT output when the iOS interpreter profile changes.
mixin ShorebirdInterpreterBuildKey on Target {
  @override
  String? buildKeyFor(Environment environment) {
    final bool enabled =
        environment.defines[kTargetPlatform] == 'ios' &&
        shorebirdUsesIosBytecodeInterpreter(
          environment.fileSystem,
          'ios',
          projectDirectory: environment.projectDir,
        );
    return _withShorebirdDigest(super.buildKeyFor(environment), <String, String>{
      if (enabled) 'shorebirdInterpreterTfa': 'disabled',
      ..._replacementBuildKey(environment),
      if (enabled &&
          shorebirdUsesIosStructuralUpdates(
            environment.fileSystem,
            'ios',
            projectDirectory: environment.projectDir,
          ))
        'shorebirdStructuralPatching': 'enabled',
    });
  }
}

Map<String, String> _replacementBuildKey(Environment environment) {
  if (!shorebirdUsesIosFullReplacement(
    environment.fileSystem,
    environment.defines[kTargetPlatform],
    projectDirectory: environment.projectDir,
  )) {
    return const <String, String>{};
  }
  final buildMode = BuildMode.fromCliName(environment.defines[kBuildMode]!);
  if (buildMode != BuildMode.release) {
    throw const FormatException('Full replacement requires a PRODUCT release build');
  }
  final inputs = ShorebirdReplacementInputs.read(
    environment.fileSystem,
    environment.platform.environment,
  );
  final host = ShorebirdReplacementHost.read(
    environment.fileSystem,
    environment.artifacts,
    buildMode: buildMode,
  )..validate(inputs.hostAbi);
  return <String, String>{...inputs.buildKey, ...host.artifactHashes};
}

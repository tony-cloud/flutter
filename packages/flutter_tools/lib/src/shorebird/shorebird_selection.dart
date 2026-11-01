// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../base/file_system.dart';

/// Trusted CLI inputs used only while building a new immutable native release.
const kShorebirdReleaseScopeEnvVar = 'SHOREBIRD_RELEASE_SCOPE';
const kShorebirdInterpreterBaseEnvVar = 'SHOREBIRD_INTERPRETER_BASE';
const kShorebirdInterpreterBaseAsset = 'shorebird_interpreter_base.bytecode';

/// Validated original baseline and exact public scope for a v2 asset bundle.
class ShorebirdSelectionInputs {
  ShorebirdSelectionInputs._(this.scope, this.baseline);

  factory ShorebirdSelectionInputs.read(FileSystem fs, Map<String, String> environment) {
    final Object? decoded = jsonDecode(environment[kShorebirdReleaseScopeEnvVar] ?? 'null');
    const keys = <String>{
      'app_id',
      'release_version',
      'platform',
      'arch',
      'base_artifact_hash',
      'host_abi_hash',
      'runtime_profile',
    };
    if (decoded is! Map<String, dynamic> ||
        decoded.length != keys.length ||
        !decoded.keys.toSet().containsAll(keys)) {
      throw const FormatException(
        'Protocol 2 requires the exact immutable seven-field release scope',
      );
    }
    final Map<String, dynamic> scope = decoded;
    final Object? hash = scope['base_artifact_hash'];
    final Object? hostAbi = scope['host_abi_hash'];
    final Object? profile = scope['runtime_profile'];
    if (!RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
        ).hasMatch(scope['app_id'] as String? ?? '') ||
        (scope['release_version'] as String? ?? '').isEmpty ||
        !const <String>{'ios', 'macos'}.contains(scope['platform']) ||
        scope['arch'] != 'aarch64' ||
        hash is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash) ||
        !const <String>{
          'interpreter-full',
          'interpreter-body',
          'interpreter-structural',
        }.contains(profile) ||
        (profile == 'interpreter-full'
            ? hostAbi is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(hostAbi)
            : hostAbi != null)) {
      throw const FormatException('Invalid protocol 2 Apple interpreter release scope');
    }
    final String? path = environment[kShorebirdInterpreterBaseEnvVar];
    if (path == null || !fs.path.isAbsolute(path) || !fs.file(path).existsSync()) {
      throw const FormatException(
        'Protocol 2 requires an absolute original interpreter baseline path',
      );
    }
    final File baseline = fs.file(path);
    if (sha256.convert(baseline.readAsBytesSync()).toString() != hash) {
      throw const FormatException('Original interpreter baseline does not match release scope');
    }
    return ShorebirdSelectionInputs._(scope, baseline);
  }

  final Map<String, dynamic> scope;
  final File baseline;
  String get assetName => 'shorebird_release_scope_${scope['platform']}_${scope['arch']}.json';
  String get baselineAsset => scope['runtime_profile'] == 'interpreter-full'
      ? 'shorebird_replacement_base.sbr'
      : kShorebirdInterpreterBaseAsset;
}

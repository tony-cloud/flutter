// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import '../artifacts.dart';
import '../base/file_system.dart';
import '../base/io.dart';
import '../build_info.dart';
import '../globals.dart' as globals;
import 'shorebird_build_manifest.dart';
import 'shorebird_interpreter.dart';
import 'shorebird_native_selection.dart';
import 'shorebird_release_trust.dart';
import 'shorebird_replacement.dart';
import 'shorebird_selection.dart';

/// The environment variable whose value is written to the generated
/// shorebird.yaml as `patch_public_key`.
const kShorebirdPublicKeyEnvVar = 'SHOREBIRD_PUBLIC_KEY';

/// SHA-256 derived from the release bytecode before sealing bundled assets.
const kShorebirdAotBaseSnapshotHashEnvVar = 'SHOREBIRD_AOT_BASE_SNAPSHOT_HASH';

/// Release-owned limit for reconstructing encrypted native patch images.
const kShorebirdNativePatchMaxBytesKey = 'native_patch_max_bytes';

void updateShorebirdYaml(
  String? flavor,
  String shorebirdYamlPath, {
  required Map<String, String> environment,
  FileSystem? fileSystem,
  TargetPlatform? targetPlatform,
  BuildMode? buildMode,
  Artifacts? artifacts,
  String Function(List<String> argv)? runSigner,
  DateTime Function()? clock,
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
  if (compiled[kShorebirdSecurityProfileKey] != 'hardened') {
    shorebirdYaml.writeAsStringSync(yamlEditor.toString(), flush: true);
    return;
  }
  shorebirdYaml.writeAsStringSync(
    signHardenedShorebirdYaml(
      yamlEditor.toString(),
      compiled: compiled,
      environment: environment,
      fileSystem: fileSystem ?? globals.fs,
      targetPlatform: targetPlatform,
      buildMode: buildMode,
      artifacts: artifacts,
      runSigner: runSigner,
      clock: clock,
    ),
    flush: true,
  );
}

/// Appends the signed build manifest (hardening P3, release root P4) to the
/// hardened YAML [text]. The manifest binds every byte of [text], so nothing
/// may change the file afterwards.
///
/// The release-trust bundle must verify under the compiled root pin the
/// engine was built with, be current at the build clock, and delegate the
/// signer's key for the `build-manifest` role inside its validity window.
String signHardenedShorebirdYaml(
  String text, {
  required Map<String, dynamic> compiled,
  required Map<String, String> environment,
  required FileSystem fileSystem,
  required TargetPlatform? targetPlatform,
  required BuildMode? buildMode,
  required Artifacts? artifacts,
  String Function(List<String> argv)? runSigner,
  DateTime Function()? clock,
}) {
  if (targetPlatform == null || buildMode == null || artifacts == null) {
    throw const FormatException(
      'A hardened shorebird.yaml needs the build target to measure its engine module',
    );
  }
  final developmentExceptions = compiled[kShorebirdSecurityDevelopmentExceptionsKey] == true;
  final ShorebirdReleaseTrust trust = loadShorebirdReleaseTrust(environment, fileSystem);
  if (trust.development && !developmentExceptions) {
    throw const FormatException(
      'The release root is the DEVELOPMENT-ONLY root, whose private key is public; only a '
      'development build ($kShorebirdSecurityDevelopmentExceptionsEnvVar=true) may use it',
    );
  }
  final ShorebirdBuildManifestSigner signer = _manifestSigner(
    environment,
    fileSystem,
    runSigner ?? _runSigner,
  );
  final DateTime now = (clock ?? DateTime.now)().toUtc();
  try {
    trust.roleKey(ShorebirdSigningRole.buildManifest, signer.keyId, at: now);
  } on ShorebirdReleaseTrustException catch (error) {
    throw FormatException('The build-manifest signer is not authorized: $error');
  }
  final String output = appendShorebirdBuildManifest(
    text.endsWith('\n') ? text : '$text\n',
    signer: signer,
    trust: trust,
    toolchainId: compiled[kShorebirdToolchainIdKey] as String,
    developmentExceptions: developmentExceptions,
    modules: shorebirdEngineModuleMeasurements(
      artifacts: artifacts,
      fileSystem: fileSystem,
      targetPlatform: targetPlatform,
      buildMode: buildMode,
    ),
    targetPlatform: targetPlatform,
    androidSigningCerts: shorebirdAndroidSigningCerts(
      environment[kShorebirdAndroidSigningCertEnvVar],
    ),
    appleTeamIds: shorebirdAppleTeamIds(environment[kShorebirdAppleTeamIdsEnvVar]),
  );
  final String recordDir = environment[kShorebirdBuildManifestRecordDirEnvVar] ?? '';
  if (recordDir.isNotEmpty) {
    final Map<String, Object?> record = shorebirdReleaseRecord(output, trust);
    final manifests = record['build_manifests']! as List<Object>;
    final digest = (manifests.single as Map<String, Object?>)['manifest_sha256']! as String;
    fileSystem.directory(recordDir).createSync(recursive: true);
    fileSystem
        .file(fileSystem.path.join(recordDir, 'build-manifest-$digest.json'))
        .writeAsStringSync(shorebirdCanonicalJson(record), flush: true);
  }
  return output;
}

ShorebirdBuildManifestSigner _manifestSigner(
  Map<String, String> environment,
  FileSystem fileSystem,
  String Function(List<String> argv) runSigner,
) {
  final String keyPath = environment[kShorebirdBuildManifestSigningKeyEnvVar] ?? '';
  final String command = environment[kShorebirdBuildManifestSignerEnvVar] ?? '';
  if (keyPath.isNotEmpty == command.isNotEmpty) {
    throw const FormatException(
      'The hardened security profile requires exactly one build-manifest signer: '
      '$kShorebirdBuildManifestSigningKeyEnvVar (a PKCS#8 PEM file) or '
      '$kShorebirdBuildManifestSignerEnvVar (an external KMS/HSM signer)',
    );
  }
  if (command.isNotEmpty) {
    final String keyId = environment[kShorebirdBuildManifestSignerKeyIdEnvVar] ?? '';
    if (!RegExp(r'^sha256:[0-9a-f]{64}$').hasMatch(keyId)) {
      throw const FormatException(
        '$kShorebirdBuildManifestSignerEnvVar requires $kShorebirdBuildManifestSignerKeyIdEnvVar '
        '(sha256:<64 lowercase hex>)',
      );
    }
    return ShorebirdCommandManifestSigner(command, keyId, runSigner);
  }
  final File keyFile = fileSystem.file(keyPath);
  if (!keyFile.existsSync()) {
    throw FormatException('$kShorebirdBuildManifestSigningKeyEnvVar does not exist: $keyPath');
  }
  return ShorebirdSeedManifestSigner(
    parseShorebirdEd25519PrivateKeyPem(keyFile.readAsStringSync()),
  );
}

String _runSigner(List<String> argv) {
  final String executable = argv.first.toLowerCase();
  final ProcessResult result = globals.processManager.runSync(
    argv,
    // A .bat/.cmd adapter needs cmd.exe on Windows; nothing else uses a shell.
    runInShell: executable.endsWith('.bat') || executable.endsWith('.cmd'),
  );
  if (result.exitCode != 0) {
    throw FormatException(
      'The build-manifest signer ${argv.first} failed (exit ${result.exitCode}): '
      '${result.stderr}',
    );
  }
  return result.stdout as String;
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

/// The environment variable selecting the security profile: `legacy` (default
/// when unset or empty) or `hardened`. `hardened-diversified` is reserved by
/// contract v1 and rejected.
const kShorebirdSecurityProfileEnvVar = 'SHOREBIRD_SECURITY_PROFILE';

/// The environment variable carrying the toolchain identity,
/// `sha256:<64 lowercase hex>`. Required by the hardened profile.
const kShorebirdToolchainIdEnvVar = 'SHOREBIRD_TOOLCHAIN_ID';

/// `true` allows a visibly development-only hardened build (http to loopback).
const kShorebirdSecurityDevelopmentExceptionsEnvVar = 'SHOREBIRD_SECURITY_DEVELOPMENT_EXCEPTIONS';

/// Bundled shorebird.yaml declaration keys, written only by this compiler for
/// hardened builds; a source shorebird.yaml must never contain them.
const kShorebirdSecurityProfileKey = 'security_profile';
const kShorebirdSecurityContractVersionKey = 'security_contract_version';
const kShorebirdToolchainIdKey = 'toolchain_id';
const kShorebirdSecurityDevelopmentExceptionsKey = 'security_development_exceptions';

const _kShorebirdSecurityContractVersion = 2;
const _kShorebirdReservedSecurityKeys = <String>[
  kShorebirdSecurityProfileKey,
  kShorebirdSecurityContractVersionKey,
  kShorebirdToolchainIdKey,
  kShorebirdSecurityDevelopmentExceptionsKey,
  kShorebirdBuildManifestKey,
];

Map<String, dynamic> compileShorebirdYaml(
  YamlMap yamlMap, {
  required String? flavor,
  required Map<String, String> environment,
  FileSystem? fileSystem,
}) {
  for (final String key in _kShorebirdReservedSecurityKeys) {
    if (yamlMap.containsKey(key)) {
      throw FormatException(
        'shorebird.yaml must not contain "$key"; security declarations are written by '
        '`shorebird release --security-profile`, not shorebird.yaml',
      );
    }
  }
  final String profile = environment[kShorebirdSecurityProfileEnvVar] ?? '';
  final String? developmentExceptionsValue =
      environment[kShorebirdSecurityDevelopmentExceptionsEnvVar];
  if (profile.isEmpty || profile == 'legacy') {
    if (developmentExceptionsValue == 'true') {
      throw const FormatException(
        '$kShorebirdSecurityDevelopmentExceptionsEnvVar=true is not valid for the legacy '
        'security profile',
      );
    }
    return _compileLegacyShorebirdYaml(
      yamlMap,
      flavor: flavor,
      environment: environment,
      fileSystem: fileSystem,
    );
  }
  if (profile != 'hardened') {
    throw FormatException(
      'Unsupported $kShorebirdSecurityProfileEnvVar "$profile"; expected "legacy" or "hardened"',
    );
  }
  // The hardened step wraps the legacy compiler so that its keys and checks
  // apply on every return path (including the native selection_protocol 2
  // early return).
  final Map<String, dynamic> compiled = _compileLegacyShorebirdYaml(
    yamlMap,
    flavor: flavor,
    environment: environment,
    fileSystem: fileSystem,
  );
  return _applyHardenedProfile(
    yamlMap,
    compiled,
    environment: environment,
    developmentExceptionsValue: developmentExceptionsValue,
  );
}

Map<String, dynamic> _applyHardenedProfile(
  YamlMap source,
  Map<String, dynamic> compiled, {
  required Map<String, String> environment,
  required String? developmentExceptionsValue,
}) {
  final bool developmentExceptions;
  switch (developmentExceptionsValue) {
    case null:
    case 'false':
      developmentExceptions = false;
    case 'true':
      developmentExceptions = true;
    default:
      throw const FormatException(
        '$kShorebirdSecurityDevelopmentExceptionsEnvVar must be unset, "true" or "false"',
      );
  }
  final String? toolchainId = environment[kShorebirdToolchainIdEnvVar];
  if (toolchainId == null || !RegExp(r'^sha256:[0-9a-f]{64}$').hasMatch(toolchainId)) {
    throw const FormatException(
      'The hardened security profile requires $kShorebirdToolchainIdEnvVar of the form '
      'sha256:<64 lowercase hex>',
    );
  }
  final Object? publicKey = compiled['patch_public_key'];
  if (publicKey is! String || publicKey.trim().isEmpty) {
    throw const FormatException(
      'The hardened security profile requires a pinned patch_public_key or '
      '$kShorebirdPublicKeyEnvVar',
    );
  }
  if (source.containsKey('patch_verification') && source['patch_verification'] != 'strict') {
    throw const FormatException(
      'The hardened security profile requires patch_verification: strict',
    );
  }
  if (source.containsKey('patch_response_verification') &&
      source['patch_response_verification'] != 'required') {
    throw const FormatException(
      'The hardened security profile requires patch_response_verification: required',
    );
  }
  _checkHardenedBaseUrl(source, compiled['base_url'], developmentExceptions);
  compiled['patch_verification'] = 'strict';
  compiled['patch_response_verification'] = 'required';
  compiled[kShorebirdSecurityProfileKey] = 'hardened';
  compiled[kShorebirdSecurityContractVersionKey] = _kShorebirdSecurityContractVersion;
  compiled[kShorebirdToolchainIdKey] = toolchainId;
  if (developmentExceptions) {
    compiled[kShorebirdSecurityDevelopmentExceptionsKey] = true;
  }
  return compiled;
}

void _checkHardenedBaseUrl(YamlMap source, Object? baseUrl, bool developmentExceptions) {
  if (!source.containsKey('base_url') || baseUrl is! String || baseUrl.isEmpty) {
    throw const FormatException('The hardened security profile requires an explicit base_url');
  }
  final Uri? uri = Uri.tryParse(baseUrl);
  if (uri == null ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      RegExp(r'^[^/?#]*//[^/?#]*@').hasMatch(baseUrl)) {
    throw FormatException(
      'The hardened security profile requires base_url to have a host and no user info: $baseUrl',
    );
  }
  if (uri.scheme == 'https') {
    return;
  }
  if (uri.scheme == 'http' && developmentExceptions && _isLoopbackHost(uri.host)) {
    return;
  }
  throw FormatException('The hardened security profile requires an https base_url: $baseUrl');
}

bool _isLoopbackHost(String host) {
  if (host == 'localhost' || host == '::1') {
    return true;
  }
  final RegExpMatch? match = RegExp(
    r'^127\.(0|[1-9]\d{0,2})\.(0|[1-9]\d{0,2})\.(0|[1-9]\d{0,2})$',
  ).firstMatch(host);
  return match != null &&
      <int>[1, 2, 3].every((int group) => int.parse(match.group(group)!) <= 255);
}

Map<String, dynamic> _compileLegacyShorebirdYaml(
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
  if (yamlMap.containsKey(kShorebirdNativePatchMaxBytesKey)) {
    final Object? value = yamlMap[kShorebirdNativePatchMaxBytesKey];
    if (value is! int || value <= 0 || value > 0x7fffffffffffffff) {
      throw const FormatException(
        'native_patch_max_bytes must be a positive integer no greater than 9223372036854775807',
      );
    }
    // This is bundled release policy, never a patch or environment override.
    compiled[kShorebirdNativePatchMaxBytesKey] = value;
  }
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
  if (yamlMap.containsKey('selection_protocol')) {
    final Object? protocol = yamlMap['selection_protocol'];
    if (protocol is! int || (protocol != 1 && protocol != 2)) {
      throw const FormatException('selection_protocol must be integer 1 or 2');
    }
    compiled['selection_protocol'] = protocol;
    if (protocol == 2) {
      if (environment.containsKey(kShorebirdNativeSelectionManifest) ||
          compiled['aot_patch_runtime_mode'] != 'dart-bytecode-interpreter') {
        // Native license/expiry are publisher metadata. They do not restrict
        // the bundled free host or establish an interpreter artifact policy.
        compiled.remove('aot_patch_license_type');
        compiled.putIfAbsent('patch_verification', () => 'strict');
        final inputs = ShorebirdNativeSelectionInputs.read(fileSystem ?? globals.fs, environment);
        if (compiled['patch_verification'] != 'strict' ||
            compiled['patch_response_verification'] != 'required' ||
            compiled['patch_public_key'] is! String ||
            (compiled['patch_public_key'] as String).trim().isEmpty ||
            inputs.appId != appId ||
            (compiled['aot_patch_app_build_id'] != null &&
                compiled['aot_patch_app_build_id'] != inputs.releaseVersion) ||
            (compiled['aot_patch_runtime_mode'] != null &&
                compiled['aot_patch_runtime_mode'] != 'native-aot') ||
            structuralUpdates ||
            fullReplacement ||
            interpreterFields
                .where(
                  (String key) =>
                      key != 'aot_patch_runtime_mode' && key != 'aot_patch_app_build_id',
                )
                .any(compiled.containsKey)) {
          throw const FormatException(
            'Compiled native policy differs from immutable release scope',
          );
        }
        compiled['aot_patch_app_build_id'] = inputs.releaseVersion;
        return compiled;
      }
      final inputs = ShorebirdSelectionInputs.read(fileSystem ?? globals.fs, environment);
      final profile = fullReplacement
          ? 'interpreter-full'
          : structuralUpdates
          ? 'interpreter-structural'
          : 'interpreter-body';
      if (compiled['aot_patch_runtime_mode'] != 'dart-bytecode-interpreter' ||
          compiled['patch_verification'] != 'strict' ||
          compiled['patch_response_verification'] != 'required' ||
          compiled['patch_public_key'] is! String ||
          (compiled['patch_public_key'] as String).trim().isEmpty ||
          inputs.scope['app_id'] != appId ||
          inputs.scope['runtime_profile'] != profile ||
          inputs.scope['base_artifact_hash'] != compiled['aot_patch_base_snapshot_hash'] ||
          inputs.scope['host_abi_hash'] != compiled['aot_patch_host_abi']) {
        throw const FormatException('Compiled policy differs from immutable release scope');
      }
    }
  }
  return compiled;
}

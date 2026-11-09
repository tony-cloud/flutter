// Copyright 2026 The Open Shorebird Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Re-verification of a hardened release's final distributable (hardening
/// stage P6, shorebird-workspace `docs/HARDENING_CONTRACTS.md` §12).
///
/// The build manifest is signed while `flutter assemble` writes the bundled
/// `shorebird.yaml`, before Gradle, Xcode or the CLI package the app. This
/// library opens what is actually distributed (an app bundle, APK, IPA,
/// xcarchive, `.app`, Windows or Linux bundle, or an xcframework directory)
/// and checks, with the updater's rules and without a clock, that every
/// bundled `shorebird.yaml`:
///
/// 1. ends in exactly one manifest line, which chains to the compiled
///    release root and is signed by a current `build-manifest` delegate;
/// 2. declares the toolchain's profile, contract, toolchain ID, development
///    setting and diversification profile, in the YAML and in the manifest;
/// 3. is the byte sequence the manifest's `config_sha256` covers; and
/// 4. binds every engine module packaged next to it (each Android ABI, each
///    macOS slice) with the measurement of the packaged bytes.
///
/// It catches packaging that differs from what was signed (a stripped or
/// substituted engine library, a post-processed YAML, a missing ABI) before
/// anything is uploaded. It is not a substitute for the on-device gate.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' show ArchiveFile, ZipDecoder;
import 'package:crypto/crypto.dart' show sha256;
import 'package:yaml/yaml.dart';

import '../base/file_system.dart';
import 'shorebird_build_manifest.dart';
import 'shorebird_ed25519.dart';
import 'shorebird_release_trust.dart';

/// The platforms whose distributables can be re-verified.
const kShorebirdVerifiablePlatforms = <String>['android', 'ios', 'macos', 'windows', 'linux'];

/// Thrown when the distributable does not match what the build signed.
class ShorebirdArtifactVerificationException implements Exception {
  const ShorebirdArtifactVerificationException(this.code, this.message);

  /// The updater gate code the device would report, or `artifact_*` for a
  /// packaging problem the device cannot see (no YAML, no engine module).
  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

Never _fail(String code, String message) =>
    throw ShorebirdArtifactVerificationException(code, message);

/// What the distributable must declare: the toolchain the CLI built with.
class ShorebirdExpectedPolicy {
  const ShorebirdExpectedPolicy({
    required this.securityProfile,
    required this.toolchainId,
    required this.pinnedRoot,
    this.minDelegationsVersion = 1,
    this.developmentExceptions = false,
    this.diversificationProfileId,
  });

  /// Reads the hardened build environment the CLI passes to `flutter build`.
  factory ShorebirdExpectedPolicy.fromEnvironment(Map<String, String> environment) {
    final String profile = environment['SHOREBIRD_SECURITY_PROFILE'] ?? '';
    if (profile != 'hardened' && profile != 'hardened-diversified') {
      throw const FormatException(
        'Re-verification applies to hardened releases: set SHOREBIRD_SECURITY_PROFILE',
      );
    }
    final String toolchainId = environment['SHOREBIRD_TOOLCHAIN_ID'] ?? '';
    final String pin = environment[kShorebirdReleaseRootEnvVar] ?? '';
    if (toolchainId.isEmpty || pin.isEmpty) {
      throw const FormatException(
        'Re-verification needs SHOREBIRD_TOOLCHAIN_ID and $kShorebirdReleaseRootEnvVar',
      );
    }
    final String minimum = environment[kShorebirdReleaseMinDelegationsVersionEnvVar] ?? '';
    if (minimum.isNotEmpty && !RegExp(r'^[1-9][0-9]{0,8}$').hasMatch(minimum)) {
      throw const FormatException(
        '$kShorebirdReleaseMinDelegationsVersionEnvVar must be a positive integer',
      );
    }
    final String profileId = environment['SHOREBIRD_DIVERSIFICATION_PROFILE_ID'] ?? '';
    return ShorebirdExpectedPolicy(
      securityProfile: profile,
      toolchainId: toolchainId,
      pinnedRoot: base64.decode(pin),
      minDelegationsVersion: minimum.isEmpty ? 1 : int.parse(minimum),
      developmentExceptions: environment['SHOREBIRD_SECURITY_DEVELOPMENT_EXCEPTIONS'] == 'true',
      diversificationProfileId: profileId.isEmpty ? null : profileId,
    );
  }

  final String securityProfile;
  final String toolchainId;
  final List<int> pinnedRoot;
  final int minDelegationsVersion;
  final bool developmentExceptions;
  final String? diversificationProfileId;

  bool get diversified => securityProfile == 'hardened-diversified';
}

/// A manifest that verified under the compiled root.
class ShorebirdVerifiedManifest {
  ShorebirdVerifiedManifest._(this.manifest, this.manifestSha256);

  final Map<String, Object?> manifest;

  /// Lowercase hex SHA-256 of the manifest bytes (the release record key).
  final String manifestSha256;

  /// `(platform, arch) -> measurement` of the bound engine modules.
  Map<(String, String), String> get modules => <(String, String), String>{
    for (final Object? entry in manifest['modules']! as List<Object?>)
      if (entry case {
        'platform': final String platform,
        'arch': final String arch,
        'measurement': final String measurement,
      })
        (platform, arch): measurement,
  };
}

List<int> _unb64url(String value, String what) {
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
    _fail('manifest_malformed', '$what is not unpadded base64url');
  }
  try {
    return base64Url.decode(base64Url.normalize(value));
  } on FormatException {
    _fail('manifest_malformed', '$what is not base64url');
  }
}

const _kManifestPrefix = 'shorebird_build_manifest: ';

/// Verifies the manifest of one bundled hardened `shorebird.yaml` [text]
/// with the updater gate's order and rules (§9.4, §10.5, §11.6), except the
/// module and package identity checks, which need the packaged binaries.
ShorebirdVerifiedManifest verifyShorebirdBuildManifest(
  String text,
  ShorebirdExpectedPolicy expected,
) {
  if (text.contains('\r')) {
    _fail('manifest_malformed', 'the YAML contains a carriage return');
  }
  final String body = text.endsWith('\n') ? text.substring(0, text.length - 1) : text;
  final int at = body.lastIndexOf('\n') + 1;
  final String line = body.substring(at);
  if (!line.startsWith(_kManifestPrefix)) {
    _fail(
      body.contains('\n$_kManifestPrefix') || body.startsWith(_kManifestPrefix)
          ? 'manifest_malformed'
          : 'manifest_missing',
      'the last line is not the build manifest',
    );
  }
  final String config = text.substring(0, at);
  if (config.contains('\n$_kManifestPrefix') || config.startsWith(_kManifestPrefix)) {
    _fail('manifest_malformed', 'the build manifest appears more than once');
  }
  final String token = line.substring(_kManifestPrefix.length);
  final prefix = expected.diversified ? 'v3.' : 'v2.';
  if (!token.startsWith(prefix)) {
    _fail('manifest_malformed', 'expected a $prefix token');
  }
  final List<String> parts = token.substring(prefix.length).split('.');
  if (parts.length != 3) {
    _fail('manifest_malformed', 'the token must have three parts');
  }
  final List<int> manifestBytes = _unb64url(parts[0], 'manifest');
  final List<int> signature = _unb64url(parts[1], 'signature');
  final List<int> bundle = _unb64url(parts[2], 'release trust');
  final ShorebirdReleaseTrust trust;
  try {
    trust = verifyShorebirdReleaseTrust(
      bundle,
      pinnedRoot: expected.pinnedRoot,
      minDelegationsVersion: expected.minDelegationsVersion,
    );
  } on ShorebirdReleaseTrustException catch (error) {
    _fail(error.code, error.message);
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(manifestBytes));
  } on FormatException {
    _fail('manifest_malformed', 'the manifest is not JSON');
  }
  if (decoded is! Map<String, Object?> || decoded['signer_key_id'] is! String) {
    _fail('manifest_malformed', 'the manifest has no signer');
  }
  final List<int> key;
  try {
    key = trust.roleKey(ShorebirdSigningRole.buildManifest, decoded['signer_key_id']! as String);
  } on ShorebirdReleaseTrustException catch (error) {
    _fail(error.code, error.message);
  }
  final manifestSha256 = sha256.convert(manifestBytes).toString();
  if (signature.length != 64 ||
      !ed25519Verify(
        key,
        utf8.encode('$kShorebirdBuildManifestSignatureDomain$manifestSha256'),
        signature,
      )) {
    _fail('manifest_bad_signature', 'the manifest signature does not verify');
  }
  final contract = expected.diversified ? 3 : 2;
  final expectedFields = <String, Object?>{
    'schema': 'open-shorebird.build-manifest',
    'contract_version': contract,
    'security_profile': expected.securityProfile,
    'toolchain_id': expected.toolchainId,
    'development_exceptions': expected.developmentExceptions,
    'delegations_sha256': trust.delegationsSha256,
    'diversification_profile_id': expected.diversificationProfileId,
  };
  for (final MapEntry<String, Object?> field in expectedFields.entries) {
    if (decoded[field.key] != field.value) {
      _fail('manifest_policy_mismatch', '${field.key} is not ${jsonEncode(field.value)}');
    }
  }
  if (decoded['config_sha256'] != sha256.convert(utf8.encode(config)).toString()) {
    _fail('config_digest_mismatch', 'the YAML differs from the bytes the manifest signed');
  }
  if (decoded['modules'] is! List<Object?>) {
    _fail('manifest_malformed', 'the manifest has no module list');
  }
  // The declaration itself (the updater's admission input).
  final Object? yaml;
  try {
    yaml = loadYaml(config);
  } on YamlException {
    _fail('manifest_malformed', 'the YAML does not parse');
  }
  if (yaml is! YamlMap ||
      yaml['security_profile'] != expected.securityProfile ||
      yaml['security_contract_version'] != contract ||
      yaml['toolchain_id'] != expected.toolchainId ||
      yaml['diversification_profile_id'] != expected.diversificationProfileId) {
    _fail('manifest_policy_mismatch', 'the YAML declaration differs from the toolchain');
  }
  return ShorebirdVerifiedManifest._(decoded, manifestSha256);
}

/// One file of a distributable.
class _Entry {
  _Entry(this.path, this.read);

  /// `/`-separated path inside the distributable.
  final String path;
  final Uint8List Function() read;
}

/// The files of [path]: a directory tree (symbolic links are not followed,
/// so a framework's `Versions/Current` aliases count once), or the members
/// of a ZIP-format file (`.aab`, `.apk`, `.ipa`, `.zip`).
List<_Entry> _entries(FileSystem fileSystem, String path) {
  final FileSystemEntityType type = fileSystem.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.directory) {
    final Directory root = fileSystem.directory(path);
    return <_Entry>[
      for (final FileSystemEntity entity in root.listSync(recursive: true, followLinks: false))
        if (entity is File)
          _Entry(
            fileSystem.path
                .relative(entity.path, from: root.path)
                .replaceAll(fileSystem.path.separator, '/'),
            entity.readAsBytesSync,
          ),
    ];
  }
  if (type == FileSystemEntityType.file) {
    final List<ArchiveFile> files = ZipDecoder()
        .decodeBytes(fileSystem.file(path).readAsBytesSync())
        .files;
    return <_Entry>[
      for (final ArchiveFile file in files)
        if (file.isFile) _Entry(file.name, () => Uint8List.fromList(file.content as List<int>)),
    ];
  }
  _fail('artifact_missing', '$path does not exist');
}

const _kAndroidAbiArches = <String, String>{
  'arm64-v8a': 'aarch64',
  'armeabi-v7a': 'arm',
  'x86_64': 'x86_64',
  'x86': 'x86',
};

/// The engine modules packaged in [entries] for [platform]:
/// `(platform, arch) -> measurement`.
Map<(String, String), String> _packagedModules(String platform, List<_Entry> entries) {
  final modules = <(String, String), String>{};
  void add(String arch, String measurement, String path) {
    final key = (platform, arch);
    if (modules.containsKey(key) && modules[key] != measurement) {
      _fail('artifact_ambiguous', 'two different $platform/$arch engine modules ($path)');
    }
    modules[key] = measurement;
  }

  for (final entry in entries) {
    final String path = entry.path;
    switch (platform) {
      case 'android':
        final RegExpMatch? match = RegExp(r'(^|/)lib/([^/]+)/libflutter\.so$').firstMatch(path);
        if (match != null) {
          final String? arch = _kAndroidAbiArches[match.group(2)];
          if (arch == null) {
            _fail('artifact_unsupported', '$path is for an unsupported ABI');
          }
          add(arch, measureShorebirdModuleImage(entry.read()), path);
        }
      case 'ios':
        // Device slices only: the manifest binds what a device loads.
        if (path.endsWith('Flutter.framework/Flutter') && !path.contains('-simulator/')) {
          measureShorebirdMachOArchitectures(
            entry.read(),
          ).forEach((String arch, String measurement) => add(arch, measurement, path));
        }
      case 'macos':
        if (path.endsWith('FlutterMacOS.framework/Versions/A/FlutterMacOS')) {
          measureShorebirdMachOArchitectures(
            entry.read(),
          ).forEach((String arch, String measurement) => add(arch, measurement, path));
        }
      case 'windows':
        if (path == 'flutter_windows.dll' || path.endsWith('/flutter_windows.dll')) {
          final Uint8List image = entry.read();
          add(_peArch(image, path), measureShorebirdModuleImage(image), path);
        }
      case 'linux':
        if (path == 'libflutter_linux_gtk.so' || path.endsWith('/libflutter_linux_gtk.so')) {
          final Uint8List image = entry.read();
          add(_elfArch(image, path), measureShorebirdModuleImage(image), path);
        }
      default:
        _fail('artifact_unsupported', 'cannot re-verify $platform distributables');
    }
  }
  return modules;
}

String _peArch(Uint8List image, String path) {
  if (image.length >= 0x40) {
    final data = ByteData.sublistView(image);
    final int pe = data.getUint32(0x3c, Endian.little);
    if (pe + 6 <= image.length) {
      switch (data.getUint16(pe + 4, Endian.little)) {
        case 0x8664:
          return 'x86_64';
        case 0xaa64:
          return 'aarch64';
      }
    }
  }
  _fail('artifact_unsupported', '$path is not an x64 or ARM64 PE image');
}

String _elfArch(Uint8List image, String path) {
  if (image.length >= 0x14) {
    switch (ByteData.sublistView(image).getUint16(0x12, Endian.little)) {
      case 0x3e:
        return 'x86_64';
      case 0xb7:
        return 'aarch64';
    }
  }
  _fail('artifact_unsupported', '$path is not an x86-64 or AArch64 ELF image');
}

/// The result of [verifyShorebirdReleaseArtifact].
class ShorebirdArtifactReport {
  ShorebirdArtifactReport(this.manifests, this.modules);

  /// Bundled YAML path -> manifest SHA-256.
  final Map<String, String> manifests;

  /// Every packaged engine module, verified against every manifest.
  final Map<(String, String), String> modules;

  Map<String, Object?> toJson() => <String, Object?>{
    'verified': true,
    'manifests': <Object>[
      for (final MapEntry<String, String> m in manifests.entries)
        <String, String>{'path': m.key, 'manifest_sha256': m.value},
    ],
    'modules': <Object>[
      for (final MapEntry<(String, String), String> m in modules.entries)
        <String, String>{'platform': m.key.$1, 'arch': m.key.$2, 'measurement': m.value},
    ],
  };
}

/// Re-verifies the distributable at [artifactPath] for [platform] (one of
/// [kShorebirdVerifiablePlatforms]). [recordManifests], when given, are the
/// `manifest_sha256` values of the release record the CLI stores; every
/// bundled manifest must be one of them.
ShorebirdArtifactReport verifyShorebirdReleaseArtifact({
  required FileSystem fileSystem,
  required String artifactPath,
  required String platform,
  required ShorebirdExpectedPolicy expected,
  Set<String>? recordManifests,
}) {
  if (!kShorebirdVerifiablePlatforms.contains(platform)) {
    _fail('artifact_unsupported', 'cannot re-verify $platform distributables');
  }
  final List<_Entry> entries = _entries(fileSystem, artifactPath);
  final yamls = <_Entry>[
    for (final _Entry entry in entries)
      if (entry.path.endsWith('flutter_assets/shorebird.yaml')) entry,
  ];
  if (yamls.isEmpty) {
    _fail('artifact_no_config', '$artifactPath has no bundled flutter_assets/shorebird.yaml');
  }
  final Map<(String, String), String> modules = _packagedModules(platform, entries);
  if (modules.isEmpty) {
    _fail('artifact_no_engine', '$artifactPath packages no $platform engine module');
  }
  final manifests = <String, String>{};
  for (final yaml in yamls) {
    final String text;
    try {
      text = utf8.decode(yaml.read());
    } on FormatException {
      _fail('manifest_malformed', '${yaml.path} is not UTF-8');
    }
    final ShorebirdVerifiedManifest manifest;
    try {
      manifest = verifyShorebirdBuildManifest(text, expected);
    } on ShorebirdArtifactVerificationException catch (error) {
      _fail(error.code, '${yaml.path}: ${error.message}');
    }
    final Map<(String, String), String> bound = manifest.modules;
    for (final MapEntry<(String, String), String> module in modules.entries) {
      final String? measurement = bound[module.key];
      if (measurement == null) {
        _fail(
          'module_unbound',
          '${yaml.path}: the manifest does not bind the packaged '
              '${module.key.$1}/${module.key.$2} engine module',
        );
      }
      if (measurement != module.value) {
        _fail(
          'module_mismatch',
          '${yaml.path}: the packaged ${module.key.$1}/${module.key.$2} engine module is not the '
              'one the build measured',
        );
      }
    }
    if (recordManifests != null && !recordManifests.contains(manifest.manifestSha256)) {
      _fail('artifact_not_recorded', '${yaml.path}: the manifest is not in the release record');
    }
    manifests[yaml.path] = manifest.manifestSha256;
  }
  return ShorebirdArtifactReport(manifests, modules);
}

// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../base/file_system.dart';
import '../build_info.dart';

/// Private CLI input. Only the seven-field scopes are packaged in the app.
const kShorebirdNativeSelectionManifest = 'SHOREBIRD_NATIVE_SELECTION_MANIFEST';

/// The original native AOT baselines measured by the release producer.
class ShorebirdNativeSelectionInputs {
  ShorebirdNativeSelectionInputs._(this.manifest, this.configuration, this.scopes, this.baselines);

  factory ShorebirdNativeSelectionInputs.read(FileSystem fs, Map<String, String> environment) {
    final String? path = environment[kShorebirdNativeSelectionManifest];
    if (path == null || !fs.path.isAbsolute(path) || !fs.file(path).existsSync()) {
      throw const FormatException(
        'Protocol 2 native builds require an absolute selection manifest',
      );
    }
    final File manifest = fs.file(path);
    final Map<String, dynamic> config = _object(
      _decodeJson(manifest.readAsStringSync()),
      const <String>{
        'version',
        'mode',
        'app_id',
        'release_version',
        'platform',
        'arches',
        'entries',
      },
    );
    final Object? appId = config['app_id'];
    final Object? version = config['release_version'];
    final Object? platform = config['platform'];
    final Object? arches = config['arches'];
    final Object? entries = config['entries'];
    if (config['version'] is! int ||
        config['version'] != 1 ||
        !const <String>{'measure', 'sealed'}.contains(config['mode']) ||
        appId is! String ||
        !RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
        ).hasMatch(appId) ||
        version is! String ||
        !_validVersion(version) ||
        !const <String>{'android', 'linux', 'windows'}.contains(platform) ||
        arches is! List<dynamic> ||
        arches.isEmpty ||
        arches.any(
          (Object? arch) =>
              !(platform == 'android'
                      ? const <String>{'arm', 'aarch64', 'x86_64'}
                      : const <String>{'aarch64', 'x86_64'})
                  .contains(arch),
        ) ||
        arches.toSet().length != arches.length ||
        (platform != 'android' && arches.length != 1) ||
        entries is! List<dynamic>) {
      throw const FormatException('Invalid native selection manifest');
    }
    final scopes = <String, Map<String, dynamic>>{};
    final baselines = <File>[];
    for (final Object? value in entries) {
      final Map<String, dynamic> entry = _object(value, const <String>{
        'scope',
        'original_baseline_path',
      });
      final Map<String, dynamic> scope = _object(entry['scope'], const <String>{
        'app_id',
        'release_version',
        'platform',
        'arch',
        'base_artifact_hash',
        'host_abi_hash',
        'runtime_profile',
      });
      final Object? arch = scope['arch'];
      final Object? hash = scope['base_artifact_hash'];
      final Object? baselinePath = entry['original_baseline_path'];
      if (scope['app_id'] != appId ||
          scope['release_version'] != version ||
          scope['platform'] != platform ||
          arch is! String ||
          !arches.contains(arch) ||
          scopes.containsKey(arch) ||
          scope['runtime_profile'] != 'native-aot' ||
          scope['host_abi_hash'] != null ||
          hash is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash) ||
          baselinePath is! String ||
          !fs.path.isAbsolute(baselinePath) ||
          !fs.file(baselinePath).existsSync()) {
        throw const FormatException('Native release scope differs from selection manifest');
      }
      final File baseline = fs.file(baselinePath);
      final Uint8List bytes = baseline.readAsBytesSync();
      _validateMachine(bytes, arch);
      if (sha256.convert(bytes).toString() != hash) {
        throw const FormatException('Original native baseline does not match release scope');
      }
      scopes[arch] = scope;
      baselines.add(baseline);
    }
    if (config['mode'] == 'measure' ? entries.isNotEmpty : scopes.length != arches.length) {
      throw const FormatException(
        'Native selection entries must exactly cover sealed architectures',
      );
    }
    return ShorebirdNativeSelectionInputs._(manifest, config, scopes, baselines);
  }

  final File manifest;
  final Map<String, dynamic> configuration;
  final Map<String, Map<String, dynamic>> scopes;
  final List<File> baselines;
  String get appId => configuration['app_id'] as String;
  String get releaseVersion => configuration['release_version'] as String;
  String get platform => configuration['platform'] as String;
  bool get isMeasurement => configuration['mode'] == 'measure';
  List<File> get inputs => <File>[manifest, ...baselines];
  Map<String, Map<String, dynamic>> get assets => <String, Map<String, dynamic>>{
    for (final MapEntry<String, Map<String, dynamic>> entry in scopes.entries)
      'shorebird_release_scope_${platform}_${entry.key}.json': entry.value,
  };

  /// Content digests, including the private phase, never private paths.
  Map<String, String> get buildKey => <String, String>{
    'nativeSelectionManifestSha256': sha256.convert(manifest.readAsBytesSync()).toString(),
    for (var index = 0; index < baselines.length; index++)
      'nativeSelectionBaseline$index': sha256
          .convert(baselines[index].readAsBytesSync())
          .toString(),
  };

  void validateTarget(TargetPlatform target, Map<String, String> defines) {
    final String name = target.getName();
    final String targetOS = name.split('-').first;
    final List<String> targetArches = targetOS == 'android'
        ? (defines[kAndroidArchs] ?? '')
              .split(' ')
              .where((String value) => value.isNotEmpty)
              .toList()
        : <String>[name];
    const wireArches = <String, String>{
      'android-arm': 'arm',
      'android-arm64': 'aarch64',
      'android-x64': 'x86_64',
      'linux-x64': 'x86_64',
      'linux-arm64': 'aarch64',
      'windows-x64': 'x86_64',
      'windows-arm64': 'aarch64',
    };
    final Set<String?> actual = targetArches.map((String arch) => wireArches[arch]).toSet();
    final Set<dynamic> declared = (configuration['arches'] as List<dynamic>).toSet();
    if (targetOS != platform ||
        actual.contains(null) ||
        actual.length != targetArches.length ||
        actual.length != declared.length ||
        !actual.containsAll(declared)) {
      throw const FormatException('Native selection architectures differ from build target');
    }
  }
}

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !value.keys.toSet().containsAll(keys)) {
    throw const FormatException('Native selection requires exact manifest and scope fields');
  }
  return value;
}

bool _validVersion(String value) {
  if (value.isEmpty || utf8.encode(value).length > 256) {
    return false;
  }
  for (var index = 0; index < value.length; index++) {
    final int unit = value.codeUnitAt(index);
    if (unit < 32 || unit == 127 || (unit >= 0xdc00 && unit <= 0xdfff)) {
      return false;
    }
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++index == value.length ||
          value.codeUnitAt(index) < 0xdc00 ||
          value.codeUnitAt(index) > 0xdfff) {
        return false;
      }
    }
  }
  return true;
}

void _validateMachine(Uint8List bytes, String arch) {
  final is32 = arch == 'arm';
  if (bytes.length < (is32 ? 52 : 64) ||
      bytes[0] != 0x7f ||
      bytes[1] != 0x45 ||
      bytes[2] != 0x4c ||
      bytes[3] != 0x46 ||
      bytes[4] != (is32 ? 1 : 2) ||
      bytes[5] != 1 ||
      bytes[6] != 1 ||
      ByteData.sublistView(bytes).getUint16(18, Endian.little) !=
          <String, int>{'arm': 40, 'aarch64': 183, 'x86_64': 62}[arch]) {
    throw const FormatException('Original native baseline has the wrong ELF architecture');
  }
}

/// JSON's standard decoder accepts duplicate keys. Reject them before using
/// that decoded object, including keys spelled with different Unicode escapes.
Object? _decodeJson(String source) {
  final Object? decoded = jsonDecode(source);
  var offset = 0;
  void whitespace() {
    while (offset < source.length && ' \r\n\t'.contains(source[offset])) {
      offset++;
    }
  }

  String string() {
    final int start = offset++;
    while (source[offset] != '"') {
      if (source[offset++] == r'\') {
        offset++;
      }
    }
    offset++;
    return jsonDecode(source.substring(start, offset)) as String;
  }

  void value() {
    whitespace();
    final String token = source[offset];
    if (token == '{' || token == '[') {
      offset++;
      whitespace();
      final keys = <String>{};
      final end = token == '{' ? '}' : ']';
      while (source[offset] != end) {
        if (token == '{') {
          if (!keys.add(string())) {
            throw const FormatException('Duplicate native selection JSON key');
          }
          whitespace();
          offset++;
        }
        value();
        whitespace();
        if (source[offset] == ',') {
          offset++;
          whitespace();
        }
      }
      offset++;
    } else if (token == '"') {
      string();
    } else {
      while (offset < source.length && !',]} \r\n\t'.contains(source[offset])) {
        offset++;
      }
    }
  }

  value();
  return decoded;
}

/// Digests in generated CMake commands invalidate outer native build caching.
/// The private manifest and baseline paths stay in the invoking environment.
Map<String, String> shorebirdNativeSelectionBuildEnvironment(
  FileSystem fs,
  Map<String, String> environment,
) => <String, String>{
  if (environment.containsKey(kShorebirdNativeSelectionManifest))
    'SHOREBIRD_NATIVE_SELECTION_INPUT_DIGEST': sha256
        .convert(
          utf8.encode(jsonEncode(ShorebirdNativeSelectionInputs.read(fs, environment).buildKey)),
        )
        .toString(),
};

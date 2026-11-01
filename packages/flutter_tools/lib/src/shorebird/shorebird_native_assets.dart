// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import '../base/file_system.dart';
import '../build_info.dart';
import '../build_system/build_system.dart';
import 'shorebird_interpreter.dart';
import 'shorebird_replacement_host.dart';

/// Compiler-owned description of the effective legacy native-assets carrier.
const kShorebirdNativeAssetsDescriptor = 'shorebird_native_assets.json';

/// The original physical arm64 iOS descriptor target.
const kShorebirdNativeAssetsTarget = 'ios_arm64';

/// Derives the descriptor target from trusted build settings, never its JSON.
String shorebirdNativeAssetsTarget(String targetOS, {String targetArch = 'arm64'}) {
  return switch (shorebirdTargetOS(targetOS)) {
    'ios' when targetArch == 'arm64' => kShorebirdNativeAssetsTarget,
    'macos' when const <String>{'arm64', 'x64'}.contains(targetArch) => 'macos_$targetArch',
    _ => throw const FormatException('Unsupported full replacement native-assets target OS'),
  };
}

/// Declares the descriptor even before compilation, so missing or modified
/// sidecars invalidate a cached kernel. Generic builds have no extra output.
class ShorebirdNativeAssetsOutput implements Source {
  const ShorebirdNativeAssetsOutput();

  @override
  bool get implicit => false;

  @override
  void accept(SourceVisitor visitor) {
    final Environment environment = visitor.environment;
    if (_fullReplacement(environment)) {
      visitor.visitPattern('{BUILD_DIR}/$kShorebirdNativeAssetsDescriptor', false);
    }
  }
}

bool _fullReplacement(Environment environment) => shorebirdUsesFullReplacement(
  environment.fileSystem,
  environment.defines[kTargetPlatform],
  projectDirectory: environment.projectDir,
);

/// Clears previous compiler output before any new compilation can fail.
///
/// The path is a trusted tool argument, never an extra frontend option.
String? shorebirdPrepareNativeAssetsDescriptor(Environment environment) {
  final File descriptor = environment.buildDir.childFile(kShorebirdNativeAssetsDescriptor);
  if (descriptor.existsSync()) {
    descriptor.deleteSync();
  }
  if (!_fullReplacement(environment)) {
    return null;
  }
  if (shorebirdTargetOS(environment.defines[kTargetPlatform]) == 'macos') {
    shorebirdValidateMacOSReplacementArchitectures(getDarwinArchsFromEnv(environment.defines));
  }
  return descriptor.absolute.path;
}

/// Prevents user options from overriding the trusted full-replacement binding.
List<String> shorebirdNativeAssetsFrontendOptions({
  required bool fullReplacement,
  String targetOS = 'ios',
  String targetArch = 'arm64',
  required String? descriptorPath,
  required List<String>? extraFrontEndOptions,
}) {
  final reserved = <String>[
    '--shorebird-full-replacement',
    '--no-shorebird-full-replacement',
    '--shorebird-replacement-base',
    '--shorebird-host-abi',
    '--shorebird-native-assets-descriptor',
    '--shorebird-native-assets-target',
    if (fullReplacement) ...<String>['--output-dill', '--depfile'],
  ];
  for (final String option in extraFrontEndOptions ?? const <String>[]) {
    if (reserved.any((String flag) => option == flag || option.startsWith('$flag='))) {
      throw FormatException(
        'Shorebird compiler binding must be supplied by the build tool: $option',
      );
    }
  }
  if (descriptorPath == null) {
    return const <String>[];
  }
  if (!fullReplacement) {
    throw const FormatException('Native-assets descriptor requires full replacement');
  }
  return <String>[
    '--shorebird-native-assets-descriptor=$descriptorPath',
    '--shorebird-native-assets-target=${shorebirdNativeAssetsTarget(targetOS, targetArch: targetArch)}',
  ];
}

/// Rejects a descriptor compiled alongside a redirected kernel when the build
/// graph would otherwise consume an older kernel at its declared output path.
void shorebirdValidateNativeAssetsKernelOutput(
  FileSystem fileSystem, {
  required String expectedPath,
  required String outputPath,
}) {
  String normalized(String path) => fileSystem.path.normalize(fileSystem.file(path).absolute.path);
  if (normalized(outputPath) != normalized(expectedPath)) {
    throw const FormatException(
      'Compiler native-assets descriptor must accompany the expected kernel',
    );
  }
}

/// Validates the compiler descriptor without reinterpreting native-assets YAML
/// or replacing its exact bytes with a tool-generated serialization.
File shorebirdReadNativeAssetsDescriptor(
  Directory buildDirectory, {
  String targetOS = 'ios',
  String targetArch = 'arm64',
}) {
  final String target = shorebirdNativeAssetsTarget(targetOS, targetArch: targetArch);
  final File descriptor = buildDirectory.childFile(kShorebirdNativeAssetsDescriptor);
  if (!descriptor.existsSync()) {
    throw const FormatException('Missing compiler-produced shorebird_native_assets.json');
  }
  if (descriptor.lengthSync() > 1024) {
    throw const FormatException('Compiler native-assets descriptor exceeds size limit');
  }
  final String contents = descriptor.readAsStringSync();
  final Object? value = jsonDecode(contents);
  if (value is! Map<String, Object?> ||
      value['schema'] is! int ||
      value['schema'] != 1 ||
      value['target'] != target ||
      value['carrier_present'] is! bool) {
    throw const FormatException('Invalid compiler native-assets descriptor');
  }
  final present = value['carrier_present']! as bool;
  final Object? digest = value['mapping_sha256'];
  if (value.length != (present ? 4 : 3) ||
      (present && (digest is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest))) ||
      (!present && value.containsKey('mapping_sha256'))) {
    throw const FormatException('Invalid compiler native-assets descriptor mapping digest');
  }
  final String canonical = jsonEncode(<String, Object>{
    'schema': 1,
    'target': target,
    'carrier_present': present,
    if (present) 'mapping_sha256': digest! as String,
  });
  if (contents != canonical && contents != '$canonical\n') {
    throw const FormatException('Compiler native-assets descriptor must be canonical JSON');
  }
  return descriptor;
}

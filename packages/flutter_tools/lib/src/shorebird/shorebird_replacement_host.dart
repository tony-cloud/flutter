// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:process/process.dart';

import '../artifacts.dart';
import '../base/file_system.dart';
import '../base/io.dart';
import '../build_info.dart';

/// Resolves the exact PRODUCT platform consumed by the full-profile compiler.
String shorebirdReplacementSdkRoot(Artifacts artifacts, FileSystem fileSystem) {
  final LocalEngineInfo? local = artifacts.localEngineInfo;
  if (local == null) {
    return artifacts.getArtifactPath(
      Artifact.flutterPatchedSdkPath,
      platform: TargetPlatform.ios,
      mode: BuildMode.release,
    );
  }
  final File args = fileSystem.directory(local.targetOutPath).childFile('args.gn');
  if (!args.existsSync()) {
    throw const FormatException('Full replacement requires verified local engine args.gn');
  }
  final values = <String, String>{};
  final assignment = RegExp(r'^\s*([a-z_]+)\s*=\s*(.*?)\s*(?:#.*)?$');
  for (final String line in args.readAsLinesSync()) {
    final RegExpMatch? match = assignment.firstMatch(line);
    if (match != null) {
      values[match[1]!] = match[2]!;
    }
  }
  const required = <String, String>{
    'is_debug': 'false',
    'flutter_runtime_mode': '"release"',
    'dart_runtime_mode': '"release"',
    'target_os': '"ios"',
    'target_cpu': '"arm64"',
    'dart_target_arch': '"arm64"',
    'use_ios_simulator': 'false',
    'ios_use_simulator': 'false',
  };
  for (final MapEntry<String, String> entry in required.entries) {
    if (values[entry.key] != entry.value) {
      throw FormatException('Full replacement local engine requires ${entry.key} = ${entry.value}');
    }
  }
  // GN writes flutter_patched_sdk for release too; only archive packaging
  // renames this directory to flutter_patched_sdk_product.
  return fileSystem.path.join(local.targetOutPath, 'flutter_patched_sdk');
}

/// Canonical v1 stamp shared with the CLI. Paths never contribute to identity.
String shorebirdReplacementHostAbi({
  required String engineHash,
  required String genSnapshotHash,
  required String platformHash,
}) {
  final descriptor = BytesBuilder();
  for (final value in <String>[
    'shorebird-ios-full-replacement-host-v1',
    'ios',
    'device',
    'arm64',
    'product',
    'dart-bytecode-interpreter',
    'full-replacement-v1',
    engineHash,
    genSnapshotHash,
    platformHash,
  ]) {
    final List<int> bytes = utf8.encode(value);
    descriptor.add((ByteData(4)..setUint32(0, bytes.length, Endian.little)).buffer.asUint8List());
    descriptor.add(bytes);
  }
  return sha256.convert(descriptor.takeBytes()).toString();
}

/// Fingerprints selected artifacts, independently of environment declarations.
class ShorebirdReplacementHost {
  ShorebirdReplacementHost._(this.hostAbi, this.artifactHashes);

  factory ShorebirdReplacementHost.read(
    FileSystem fileSystem,
    Artifacts artifacts, {
    required BuildMode buildMode,
    ProcessManager? processManager,
  }) {
    if (buildMode != BuildMode.release) {
      throw const FormatException('Full replacement requires a PRODUCT release build');
    }
    final String sdkRoot = shorebirdReplacementSdkRoot(artifacts, fileSystem);
    final String framework = artifacts.getArtifactPath(
      Artifact.flutterFramework,
      platform: TargetPlatform.ios,
      mode: BuildMode.release,
      environmentType: EnvironmentType.physical,
    );
    final String genSnapshot = artifacts.getArtifactPath(
      Artifact.genSnapshotArm64,
      platform: TargetPlatform.ios,
      mode: BuildMode.release,
    );
    final paths = <String, String>{
      'engine': fileSystem.path.join(framework, 'Flutter'),
      'genSnapshot': genSnapshot,
      'platform': fileSystem.path.join(sdkRoot, 'platform_strong.dill'),
      // These tools do not define the frozen-host ABI, but replacing either
      // must invalidate cached work and rerun the compiler version checks.
      'runtime': artifacts.getArtifactPath(Artifact.engineDartAotRuntime),
      'frontend': artifacts.getArtifactPath(Artifact.frontendServerSnapshotForEngineDartSdk),
    };
    final hashes = <String, String>{};
    for (final MapEntry<String, String> entry in paths.entries) {
      final File file = fileSystem.file(entry.value);
      if (!file.existsSync()) {
        throw FormatException('Missing full replacement host artifact: ${entry.key}');
      }
      hashes[entry.key] = sha256.convert(file.readAsBytesSync()).toString();
    }
    if (processManager != null) {
      String version(String executable) {
        final ProcessResult result = processManager.runSync(<String>[executable, '--version']);
        final String value = '${result.stdout}${result.stderr}'.trim();
        if (result.exitCode != 0 || value.isEmpty) {
          throw const FormatException('Unable to verify full replacement compiler versions');
        }
        return value.replaceFirst(RegExp(r' on "[^"]+"$'), '');
      }

      final String runtime = artifacts.getArtifactPath(Artifact.engineDartAotRuntime);
      if (version(genSnapshot) != version(runtime)) {
        throw const FormatException(
          'Full replacement gen_snapshot and host Dart runtime versions differ',
        );
      }
    }
    return ShorebirdReplacementHost._(
      shorebirdReplacementHostAbi(
        engineHash: hashes['engine']!,
        genSnapshotHash: hashes['genSnapshot']!,
        platformHash: hashes['platform']!,
      ),
      hashes,
    );
  }

  final String hostAbi;
  final Map<String, String> artifactHashes;

  /// Fails closed when the builder's claimed host differs from selected files.
  void validate(String expected) {
    if (hostAbi != expected) {
      throw const FormatException(
        'Replacement host ABI does not match selected native build artifacts',
      );
    }
  }
}

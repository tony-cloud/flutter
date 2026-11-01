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
import 'shorebird_interpreter.dart';

/// Resolves the exact PRODUCT platform consumed by the full-profile compiler.
String shorebirdReplacementSdkRoot(
  Artifacts artifacts,
  FileSystem fileSystem, {
  String targetOS = 'ios',
  String targetArch = 'arm64',
}) {
  targetOS = _targetOS(targetOS);
  _validateArchitecture(targetOS, targetArch);
  final LocalEngineInfo? local = artifacts.localEngineInfo;
  if (local == null) {
    if (targetOS == 'macos') {
      throw const FormatException(
        'macOS full replacement requires a verified local interpreter engine; '
        'hosted engine capability verification is not yet available',
      );
    }
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
  final required = <String, String>{
    'is_debug': 'false',
    'flutter_runtime_mode': '"release"',
    'dart_runtime_mode': '"release"',
    if (targetOS == 'ios') 'target_os': '"ios"',
    if (targetOS == 'macos') 'target_os': '"mac"',
    'target_cpu': '"$targetArch"',
    'dart_target_arch': '"$targetArch"',
    if (targetOS == 'ios') 'use_ios_simulator': 'false',
    if (targetOS == 'ios') 'ios_use_simulator': 'false',
    if (targetOS == 'macos') 'dart_enable_shorebird_interpreter': 'true',
    if (targetOS == 'macos') 'shorebird_use_interpreter': 'false',
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

String _targetOS(String targetOS) {
  final String normalized = shorebirdTargetOS(targetOS)!;
  if (normalized != 'ios' && normalized != 'macos') {
    throw const FormatException('Unsupported full replacement host target OS');
  }
  return normalized;
}

/// Rejects universal full builds, including the universal default.
/// The caller must pass the complete requested architecture set unchanged.
String shorebirdValidateMacOSReplacementArchitectures(List<DarwinArch> architectures) {
  if (architectures.length != 1 ||
      !const <DarwinArch>{DarwinArch.arm64, DarwinArch.x86_64}.contains(architectures.single)) {
    throw const FormatException(
      'macOS full replacement requires explicit darwin-arm64 or darwin-x64; '
      'universal and implicit architecture selection are not supported',
    );
  }
  return architectures.single == DarwinArch.x86_64 ? 'x64' : 'arm64';
}

void _validateArchitecture(String targetOS, String targetArch) {
  if ((targetOS == 'ios' && targetArch == 'arm64') ||
      (targetOS == 'macos' && const <String>{'arm64', 'x64'}.contains(targetArch))) {
    return;
  }
  throw const FormatException('Unsupported Apple full replacement architecture');
}

/// Canonical v1 stamp shared with the CLI. Paths never contribute to identity.
///
/// SHA-256 of UTF-8 fields, each preceded by its uint32 little-endian byte
/// length, in this exact order: domain, OS, platform kind, architecture,
/// product mode, runtime mode, profile, engine hash, gen_snapshot hash,
/// PRODUCT platform_strong.dill hash. iOS bytes remain unchanged; macOS uses
/// domain shorebird-macos-full-replacement-host-v1, OS macos, kind desktop.
String shorebirdReplacementHostAbi({
  required String engineHash,
  required String genSnapshotHash,
  required String platformHash,
  String targetOS = 'ios',
  String targetArch = 'arm64',
}) {
  targetOS = _targetOS(targetOS);
  _validateArchitecture(targetOS, targetArch);
  final descriptor = BytesBuilder();
  for (final value in <String>[
    'shorebird-$targetOS-full-replacement-host-v1',
    targetOS,
    if (targetOS == 'ios') 'device' else 'desktop',
    targetArch,
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
    String targetOS = 'ios',
    String targetArch = 'arm64',
  }) {
    targetOS = _targetOS(targetOS);
    _validateArchitecture(targetOS, targetArch);
    if (buildMode != BuildMode.release) {
      throw const FormatException('Full replacement requires a PRODUCT release build');
    }
    final String sdkRoot = shorebirdReplacementSdkRoot(
      artifacts,
      fileSystem,
      targetOS: targetOS,
      targetArch: targetArch,
    );
    final String framework = artifacts.getArtifactPath(
      targetOS == 'ios' ? Artifact.flutterFramework : Artifact.flutterMacOSFramework,
      platform: targetOS == 'ios' ? TargetPlatform.ios : TargetPlatform.darwin,
      mode: BuildMode.release,
      environmentType: EnvironmentType.physical,
    );
    final String genSnapshot = artifacts.getArtifactPath(
      targetArch == 'x64' ? Artifact.genSnapshotX64 : Artifact.genSnapshotArm64,
      platform: targetOS == 'ios' ? TargetPlatform.ios : TargetPlatform.darwin,
      mode: BuildMode.release,
    );
    final paths = <String, String>{
      'engine': fileSystem.path.join(framework, targetOS == 'ios' ? 'Flutter' : 'FlutterMacOS'),
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
        targetOS: targetOS,
        targetArch: targetArch,
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

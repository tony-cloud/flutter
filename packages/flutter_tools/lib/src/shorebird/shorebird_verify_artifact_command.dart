// Copyright 2026 The Open Shorebird Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import '../base/common.dart';
import '../base/file_system.dart';
import '../globals.dart' as globals;
import '../runner/flutter_command.dart';
import 'shorebird_release_artifact.dart';

/// `flutter shorebird-verify-artifact` (hidden): re-verifies the final
/// distributable of a hardened release against the toolchain's compiled
/// policy (hardening P6, contract §12). The Shorebird CLI runs it after the
/// build and before uploading anything, with the same hardened environment
/// it passed to `flutter build`.
///
/// Prints a JSON report on success; exits non-zero with the gate code
/// otherwise.
class ShorebirdVerifyArtifactCommand extends FlutterCommand {
  ShorebirdVerifyArtifactCommand() {
    argParser
      ..addOption('artifact', help: 'The distributable: a file (.aab, .apk, .ipa) or a directory.')
      ..addOption('platform', allowed: kShorebirdVerifiablePlatforms)
      ..addMultiOption(
        'record-manifest',
        help: 'A manifest_sha256 of the release record; every bundled manifest must be one.',
      );
  }

  @override
  final String name = 'shorebird-verify-artifact';

  @override
  final String description = 'Re-verify the build manifest of a hardened Shorebird release.';

  @override
  bool get hidden => true;

  @override
  String get category => FlutterCommandCategory.tools;

  @override
  bool get shouldUpdateCache => false;

  @override
  Future<Set<DevelopmentArtifact>> get requiredArtifacts async => const <DevelopmentArtifact>{};

  @override
  Future<FlutterCommandResult> runCommand() async {
    final String? artifact = stringArg('artifact');
    final String? platform = stringArg('platform');
    if (artifact == null || platform == null) {
      throwToolExit('--artifact and --platform are required', exitCode: 64);
    }
    final List<String> record = stringsArg('record-manifest');
    try {
      final ShorebirdArtifactReport report = verifyShorebirdReleaseArtifact(
        fileSystem: globals.fs,
        artifactPath: artifact,
        platform: platform,
        expected: ShorebirdExpectedPolicy.fromEnvironment(globals.platform.environment),
        recordManifests: record.isEmpty ? null : record.toSet(),
      );
      globals.printStatus(jsonEncode(report.toJson()));
    } on ShorebirdArtifactVerificationException catch (error) {
      throwToolExit('Hardened release artifact verification failed: $error', exitCode: 1);
    } on FormatException catch (error) {
      throwToolExit('Hardened release artifact verification failed: ${error.message}', exitCode: 1);
    } on FileSystemException catch (error) {
      throwToolExit('Hardened release artifact verification failed: $error', exitCode: 1);
    }
    return FlutterCommandResult.success();
  }
}

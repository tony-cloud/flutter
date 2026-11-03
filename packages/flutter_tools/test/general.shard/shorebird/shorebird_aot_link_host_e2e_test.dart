// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Host end-to-end run of the ios-aot-link profile through the real
// AOTSnapshotter (real gen_snapshot, ios_linker, xcrun), not fakes. Skipped
// unless SHOREBIRD_AOT_LINK_E2E names a JSON config; driven by
// tools/ios_linker/scripts/run_cli_e2e.py, which also runs the CLI stages.
//
// Config keys: stage (release|patch), project (dir with shorebird.yaml),
// work (output root), gen_snapshot, dart, tool (ios_linker.dart), dill,
// sdk_root (iPhoneOS SDK), and for patches base_link (the release App.link,
// from the downloaded supplement) and dd_targets (optional).

@Timeout(Duration(minutes: 20))
library;

import 'dart:convert';
import 'dart:io' as io;

import 'package:file/local.dart';
import 'package:flutter_tools/src/artifacts.dart';
import 'package:flutter_tools/src/base/build.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/macos/xcode.dart';
import 'package:flutter_tools/src/shorebird/shorebird_aot_link.dart';
import 'package:process/process.dart';
import 'package:test/fake.dart';

import '../../src/common.dart';

class _E2eArtifacts extends Fake implements Artifacts {
  _E2eArtifacts(this.genSnapshot, this.dart);
  final String genSnapshot;
  final String dart;

  @override
  String getArtifactPath(
    Artifact artifact, {
    TargetPlatform? platform,
    BuildMode? mode,
    EnvironmentType? environmentType,
  }) {
    if (artifact == Artifact.genSnapshotArm64) {
      return genSnapshot;
    }
    if (artifact == Artifact.engineDartBinary) {
      return dart;
    }
    throw StateError('unexpected artifact $artifact');
  }
}

void main() {
  final String? configPath = io.Platform.environment['SHOREBIRD_AOT_LINK_E2E'];
  testWithoutContext('ios-aot-link host end-to-end', () async {
    final config = json.decode(io.File(configPath!).readAsStringSync()) as Map<String, dynamic>;
    final stage = config['stage'] as String;
    const fs = LocalFileSystem();
    final logger = BufferLogger.test();
    const processManager = LocalProcessManager();
    final environment = <String, String>{
      kShorebirdAotLinkToolEnvVar: config['tool'] as String,
      if (stage == 'patch') kShorebirdAotLinkBaseEnvVar: config['base_link'] as String,
      if (stage == 'patch' && config['dd_targets'] != null)
        kShorebirdAotLinkDdTargetsEnvVar: config['dd_targets'] as String,
      if (stage == 'release' && config['dd_max_bytes'] != null) ...<String, String>{
        kShorebirdAotLinkDdMaxBytesEnvVar: '${config['dd_max_bytes']}',
        kShorebirdAotLinkDdPackagesEnvVar: (config['dd_packages'] as List<dynamic>).join(','),
      },
    };
    final snapshotter = AOTSnapshotter(
      fileSystem: fs,
      logger: logger,
      xcode: Xcode.test(processManager: processManager),
      artifacts: _E2eArtifacts(config['gen_snapshot'] as String, config['dart'] as String),
      processManager: processManager,
      platform: FakePlatform(environment: environment),
      projectDirectory: fs.directory(config['project'] as String),
    );
    final String outputPath = fs.path.join(config['work'] as String, stage, 'aot', 'arm64');
    final int exit = await snapshotter.build(
      platform: TargetPlatform.ios,
      buildMode: BuildMode.release,
      mainPath: config['dill'] as String,
      outputPath: outputPath,
      darwinArch: DarwinArch.arm64,
      sdkRoot: config['sdk_root'] as String,
      dartObfuscation: false,
      quiet: true,
    );
    io.stdout.writeln(logger.statusText);
    io.stderr.writeln(logger.errorText);
    expect(exit, 0, reason: logger.errorText);

    final String side = fs.path.dirname(outputPath);
    final String framework = fs.path.join(outputPath, 'App.framework', 'App');
    expect(fs.file(framework).existsSync(), isTrue);
    final List<String> sidecars =
        fs.directory(side).listSync().map((e) => fs.path.basename(e.path)).toList()..sort();
    io.stdout.writeln('sidecar dir: $sidecars');
    if (stage == 'release') {
      expect(sidecars, contains(kShorebirdAotLinkReleaseSidecar));
      expect(sidecars, isNot(contains(kShorebirdAotLinkPatchElf)));
    } else {
      expect(
        sidecars,
        containsAll(<String>[
          kShorebirdAotLinkPatchElf,
          kShorebirdAotLinkPatchSidecar,
          kShorebirdAotLinkConstraints,
        ]),
      );
      expect(sidecars, isNot(contains(kShorebirdAotLinkReleaseSidecar)));
      expect(sidecars, isNot(contains(kShorebirdAotLinkPass1Elf)));
    }
    // Sidecars never enter the app bundle's framework directory.
    final Iterable<String> inFramework = fs
        .directory(fs.path.join(outputPath, 'App.framework'))
        .listSync(recursive: true)
        .map((e) => fs.path.basename(e.path));
    expect(inFramework.where((n) => n.endsWith('.link') || n.endsWith('.aot')), isEmpty);
    io.File(fs.path.join(config['work'] as String, '$stage.build.json')).writeAsStringSync(
      json.encode(<String, dynamic>{
        'framework': framework,
        'sidecar_dir': side,
        'sidecars': sidecars,
      }),
    );
  }, skip: configPath == null ? 'set SHOREBIRD_AOT_LINK_E2E to run' : false);
}

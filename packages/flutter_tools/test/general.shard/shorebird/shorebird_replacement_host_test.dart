// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/artifacts.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/build_system/build_system.dart';
import 'package:flutter_tools/src/shorebird/shorebird_replacement_host.dart';

import '../../src/common.dart';
import '../../src/fake_process_manager.dart';
import '../../src/shorebird_replacement.dart';

const _releaseArgs = '''
is_debug = false
flutter_runtime_mode = "release"
dart_runtime_mode = "release"
target_os = "ios"
target_cpu = "arm64"
dart_target_arch = "arm64"
use_ios_simulator = false
ios_use_simulator = false
''';

void main() {
  testWithoutContext('host ABI uses the agreed length-prefixed descriptor', () {
    expect(
      shorebirdReplacementHostAbi(
        engineHash: 'a' * 64,
        genSnapshotHash: 'b' * 64,
        platformHash: 'c' * 64,
      ),
      '26f4a45b3cdd50b49c8e5cc102d7ecd99e87777e6454d51662c9c793567bbcef',
    );
  });

  testWithoutContext('actual artifact changes invalidate an otherwise matching host stamp', () {
    final fileSystem = MemoryFileSystem.test();
    final artifacts = Artifacts.test();
    final String expected = writeShorebirdReplacementHost(fileSystem, artifacts);
    final host = ShorebirdReplacementHost.read(fileSystem, artifacts, buildMode: BuildMode.release);
    host.validate(expected);
    writeShorebirdReplacementHost(fileSystem, artifacts, content: 2);
    expect(
      () => ShorebirdReplacementHost.read(
        fileSystem,
        artifacts,
        buildMode: BuildMode.release,
      ).validate(expected),
      throwsFormatException,
    );
    expect(
      () => ShorebirdReplacementHost.read(fileSystem, artifacts, buildMode: BuildMode.profile),
      throwsFormatException,
    );
  });

  testWithoutContext('compiler versions must match except for the trailing host', () {
    final fileSystem = MemoryFileSystem.test();
    final artifacts = Artifacts.test();
    writeShorebirdReplacementHost(fileSystem, artifacts);
    ShorebirdReplacementHost.read(
      fileSystem,
      artifacts,
      buildMode: BuildMode.release,
      processManager: FakeProcessManager.list(shorebirdReplacementVersionCommands(artifacts)),
    );
    final String gen = artifacts.getArtifactPath(
      Artifact.genSnapshotArm64,
      platform: TargetPlatform.ios,
      mode: BuildMode.release,
    );
    final String runtime = artifacts.getArtifactPath(Artifact.engineDartAotRuntime);
    for (final version in <String>[
      '',
      'Dart SDK version: other',
      'Dart SDK version: test on macos_arm64',
    ]) {
      expect(
        () => ShorebirdReplacementHost.read(
          fileSystem,
          artifacts,
          buildMode: BuildMode.release,
          processManager: FakeProcessManager.list(<FakeCommand>[
            FakeCommand(
              command: <String>[gen, '--version'],
              stderr: 'Dart SDK version: test on "macos_arm64"',
            ),
            FakeCommand(command: <String>[runtime, '--version'], stdout: version),
          ]),
        ),
        throwsFormatException,
      );
    }
  });

  testWithoutContext('local PRODUCT platform requires verified release device args', () {
    final fileSystem = MemoryFileSystem.test();
    final artifacts = Artifacts.testLocalEngine(
      localEngine: '/engine/ios_release',
      localEngineHost: '/engine/host',
    );
    final File args = fileSystem.file('/engine/ios_release/args.gn')..createSync(recursive: true);
    args.writeAsStringSync(_releaseArgs);
    expect(
      shorebirdReplacementSdkRoot(artifacts, fileSystem),
      '/engine/ios_release/flutter_patched_sdk',
    );
    for (final String line in _releaseArgs.trim().split('\n')) {
      args.writeAsStringSync(_releaseArgs.replaceFirst(line, ''));
      expect(
        () => shorebirdReplacementSdkRoot(artifacts, fileSystem),
        throwsFormatException,
        reason: line,
      );
      args.writeAsStringSync('$_releaseArgs${line.split('=').first}= true\n');
      expect(
        () => shorebirdReplacementSdkRoot(artifacts, fileSystem),
        throwsFormatException,
        reason: line,
      );
    }
  });

  testWithoutContext('full local platform source uses the selected release output', () {
    final fileSystem = MemoryFileSystem.test();
    final artifacts = Artifacts.testLocalEngine(
      localEngine: '/engine/ios_release',
      localEngineHost: '/engine/host',
    );
    fileSystem.file('/engine/ios_release/args.gn')
      ..createSync(recursive: true)
      ..writeAsStringSync(_releaseArgs);
    fileSystem
        .file('shorebird.yaml')
        .writeAsStringSync(
          'aot_patch_runtime_mode: dart-bytecode-interpreter\naot_patch_full_replacement: true\n',
        );
    final environment = Environment.test(
      fileSystem.currentDirectory,
      artifacts: artifacts,
      fileSystem: fileSystem,
      logger: BufferLogger.test(),
      platform: FakePlatform(),
      processManager: FakeProcessManager.any(),
      defines: <String, String>{kBuildMode: 'release', kTargetPlatform: 'ios'},
    );
    final visitor = SourceVisitor(environment);
    visitor.visitArtifact(Artifact.platformKernelDill, TargetPlatform.ios, BuildMode.release);
    expect(
      visitor.sources.single.path,
      '/engine/ios_release/flutter_patched_sdk/platform_strong.dill',
    );
    fileSystem.file('shorebird.yaml').writeAsStringSync('app_id: body-only\n');
    final legacy = SourceVisitor(environment);
    legacy.visitArtifact(Artifact.platformKernelDill, TargetPlatform.ios, BuildMode.release);
    expect(legacy.sources.single.path, 'Artifact.platformKernelDill.TargetPlatform.ios.release');
  });
}

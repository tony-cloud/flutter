// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:file/memory.dart';
import 'package:flutter_tools/src/artifacts.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/build_system/build_system.dart';
import 'package:flutter_tools/src/build_system/file_store.dart';
import 'package:flutter_tools/src/build_system/targets/common.dart';
import 'package:flutter_tools/src/compile.dart';
import 'package:flutter_tools/src/features.dart';
import 'package:flutter_tools/src/shorebird/shorebird_native_assets.dart';

import '../../src/common.dart';
import '../../src/context.dart';
import '../../src/fake_process_manager.dart';
import '../../src/fakes.dart';
import '../../src/shorebird_replacement.dart';

const _absent = '{"schema":1,"target":"ios_arm64","carrier_present":false}';

void main() {
  late FileSystem fileSystem;
  late Environment environment;
  late BufferLogger logger;

  setUp(() {
    fileSystem = MemoryFileSystem.test();
    logger = BufferLogger.test();
    environment = Environment.test(
      fileSystem.currentDirectory,
      fileSystem: fileSystem,
      logger: logger,
      artifacts: Artifacts.test(),
      processManager: FakeProcessManager.empty(),
      defines: <String, String>{kBuildMode: 'release', kTargetPlatform: 'ios'},
    );
    environment.buildDir.createSync(recursive: true);
  });

  void enableFullReplacement() {
    fileSystem
        .file('shorebird.yaml')
        .writeAsStringSync(
          'aot_patch_runtime_mode: dart-bytecode-interpreter\naot_patch_full_replacement: true\n',
        );
  }

  testWithoutContext('validates canonical descriptors with and without a carrier', () {
    final File descriptor = environment.buildDir.childFile(kShorebirdNativeAssetsDescriptor);
    expect(() => shorebirdReadNativeAssetsDescriptor(environment.buildDir), throwsFormatException);
    for (final contents in <String>[
      _absent,
      '$_absent\n',
      jsonEncode(<String, Object>{
        'schema': 1,
        'target': 'ios_arm64',
        'carrier_present': true,
        'mapping_sha256': 'a' * 64,
      }),
    ]) {
      descriptor.writeAsStringSync(contents);
      expect(
        shorebirdReadNativeAssetsDescriptor(environment.buildDir).readAsStringSync(),
        contents,
      );
    }
  });

  testWithoutContext('rejects malformed, noncanonical and ambiguous descriptors', () {
    final File descriptor = environment.buildDir.childFile(kShorebirdNativeAssetsDescriptor);
    for (final contents in <String>[
      'not json',
      ' ' * 1025,
      '[]',
      _absent.replaceFirst('1', '1.0'),
      _absent.replaceFirst('1', '2'),
      _absent.replaceFirst('ios_arm64', 'ios_x64'),
      _absent.replaceFirst('false', '"false"'),
      _absent.replaceFirst('false', 'true'),
      _absent.replaceFirst('}', ',"mapping_sha256":null}'),
      _absent.replaceFirst('}', ',"other":false}'),
      _absent.replaceFirst('}', ',"carrier_present":false}'),
      _absent.replaceFirst('"schema":1', '"schema":1,"schema":1'),
      ' $_absent',
      '$_absent\n\n',
      for (final Object? digest in <Object?>[null, 1, 'abc', 'A' * 64])
        jsonEncode(<String, Object?>{
          'schema': 1,
          'target': 'ios_arm64',
          'carrier_present': true,
          'mapping_sha256': digest,
        }),
    ]) {
      descriptor.writeAsStringSync(contents);
      expect(
        () => shorebirdReadNativeAssetsDescriptor(environment.buildDir),
        throwsFormatException,
        reason: contents,
      );
    }
  });

  testWithoutContext('uses paired trusted options and rejects user binding overrides', () {
    expect(
      shorebirdNativeAssetsFrontendOptions(
        fullReplacement: true,
        descriptorPath: '/build/$kShorebirdNativeAssetsDescriptor',
        extraFrontEndOptions: <String>['--native-assets=/project/native_assets.yaml'],
      ),
      <String>[
        '--shorebird-native-assets-descriptor=/build/$kShorebirdNativeAssetsDescriptor',
        '--shorebird-native-assets-target=ios_arm64',
      ],
    );
    expect(
      shorebirdNativeAssetsFrontendOptions(
        fullReplacement: false,
        descriptorPath: null,
        extraFrontEndOptions: <String>[
          '--native-assets=/project/native_assets.yaml',
          '--no-tfa',
          '--output-dill=/other.dill',
          '--depfile=/other.d',
        ],
      ),
      isEmpty,
    );
    expect(
      () => shorebirdNativeAssetsFrontendOptions(
        fullReplacement: false,
        descriptorPath: '/build/descriptor.json',
        extraFrontEndOptions: null,
      ),
      throwsFormatException,
    );
    for (final flag in <String>[
      '--shorebird-full-replacement',
      '--no-shorebird-full-replacement',
      '--shorebird-replacement-base',
      '--shorebird-host-abi',
      '--shorebird-native-assets-descriptor',
      '--shorebird-native-assets-target',
      '--output-dill',
      '--depfile',
    ]) {
      for (final option in <String>[flag, '$flag=override']) {
        expect(
          () => shorebirdNativeAssetsFrontendOptions(
            fullReplacement: true,
            descriptorPath: '/build/descriptor.json',
            extraFrontEndOptions: <String>[option],
          ),
          throwsFormatException,
        );
      }
    }
  });

  testWithoutContext('descriptor target comes from the build OS and rejects cross-OS bytes', () {
    final File descriptor = environment.buildDir.childFile(kShorebirdNativeAssetsDescriptor);
    final String macOS = _absent.replaceFirst('ios_arm64', 'macos_arm64');
    for (final targetOS in <String>['ios', 'macos']) {
      descriptor.writeAsStringSync(targetOS == 'ios' ? _absent : macOS);
      expect(
        shorebirdReadNativeAssetsDescriptor(
          environment.buildDir,
          targetOS: targetOS,
        ).readAsStringSync(),
        targetOS == 'ios' ? _absent : macOS,
      );
      expect(
        () => shorebirdReadNativeAssetsDescriptor(
          environment.buildDir,
          targetOS: targetOS == 'ios' ? 'macos' : 'ios',
        ),
        throwsFormatException,
      );
    }
    expect(
      shorebirdNativeAssetsFrontendOptions(
        fullReplacement: true,
        descriptorPath: descriptor.path,
        targetOS: 'macos',
        extraFrontEndOptions: null,
      ),
      contains('--shorebird-native-assets-target=macos_arm64'),
    );
  });

  testWithoutContext('kernel output comparison normalizes absolute and relative paths', () {
    shorebirdValidateNativeAssetsKernelOutput(
      fileSystem,
      expectedPath: '/build/app.dill',
      outputPath: 'build/temporary/../app.dill',
    );
    expect(
      () => shorebirdValidateNativeAssetsKernelOutput(
        fileSystem,
        expectedPath: '/build/app.dill',
        outputPath: '/other/app.dill',
      ),
      throwsFormatException,
    );
  });

  testWithoutContext('preparation removes stale output in both build profiles', () {
    final File descriptor = environment.buildDir.childFile(kShorebirdNativeAssetsDescriptor);
    descriptor.writeAsStringSync(_absent);
    expect(shorebirdPrepareNativeAssetsDescriptor(environment), isNull);
    expect(descriptor.existsSync(), isFalse);
    enableFullReplacement();
    descriptor.writeAsStringSync(_absent);
    expect(shorebirdPrepareNativeAssetsDescriptor(environment), descriptor.absolute.path);
    expect(descriptor.existsSync(), isFalse);
  });

  testUsingContext(
    'kernel declares descriptor only for full replacement and consumes native YAML depfile',
    () {
      const kernel = KernelSnapshot();
      final File descriptor = environment.buildDir.childFile(kShorebirdNativeAssetsDescriptor);
      expect(
        kernel.resolveOutputs(environment).sources.map((File file) => file.path),
        isNot(contains(descriptor.path)),
      );
      enableFullReplacement();
      expect(
        kernel.resolveOutputs(environment).sources.map((File file) => file.path),
        contains(descriptor.path),
      );
      final File nativeYaml = fileSystem.file('/native_assets.yaml')..writeAsStringSync('before');
      final File dill = environment.buildDir.childFile('app.dill')..writeAsStringSync('dill');
      descriptor.writeAsStringSync(_absent);
      environment.buildDir
          .childFile(KernelSnapshot.depfile)
          .writeAsStringSync('${dill.path}: ${nativeYaml.path}\n');
      expect(
        kernel.resolveInputs(environment).sources.map((File file) => file.path),
        contains(nativeYaml.path),
      );
      final store = FileStore(
        cacheFile: environment.buildDir.childFile('.filecache'),
        logger: logger,
      );
      store.diffFileList(<File>[nativeYaml, dill, descriptor]);
      store.persistIncremental();
      Node node() => Node.withStamp(
        kernel,
        <File>[nativeYaml],
        <String>{nativeYaml.path},
        <File>[dill, descriptor],
        <String>{dill.path, descriptor.path},
        <Node>[],
        null,
        null,
        false,
      );
      final Node unchanged = node();
      unchanged.computeChanges(environment, store, fileSystem, logger);
      expect(unchanged.dirty, isFalse);
      store.persistIncremental();
      nativeYaml.writeAsStringSync('after');
      final Node changed = node();
      changed.computeChanges(environment, store, fileSystem, logger);
      expect(changed.invalidatedReasons, contains(InvalidatedReasonKind.inputChanged));
      store.persistIncremental();
      descriptor.writeAsStringSync('stale');
      final Node stale = node();
      stale.computeChanges(environment, store, fileSystem, logger);
      expect(stale.dirty, isTrue);
      store.persistIncremental();
      descriptor.deleteSync();
      final Node missing = node();
      missing.computeChanges(environment, store, fileSystem, logger);
      expect(missing.invalidatedReasons, contains(InvalidatedReasonKind.outputMissing));
    },
    overrides: <Type, Generator>{FeatureFlags: () => TestFeatureFlags()},
  );

  for (final targetOS in <String>['ios', 'macos']) {
    for (final (bool success, bool redirected) in <(bool, bool)>[
      (true, false),
      (false, false),
      (true, true),
    ]) {
      testUsingContext(
        'kernel requests compiler descriptor and clears stale output '
        '(target=$targetOS, success=$success, redirected=$redirected)',
        () async {
          enableFullReplacement();
          final Artifacts artifacts;
          if (targetOS == 'macos') {
            artifacts = Artifacts.testLocalEngine(
              localEngine: '/engine/macos_release_arm64',
              localEngineHost: '/engine/host',
            );
            fileSystem.file('/engine/macos_release_arm64/args.gn')
              ..createSync(recursive: true)
              ..writeAsStringSync(shorebirdMacOSReplacementArgs);
          } else {
            artifacts = Artifacts.test();
          }
          final String expectedDescriptor = _absent.replaceFirst('ios_arm64', '${targetOS}_arm64');
          final Map<String, String> binding = writeShorebirdReplacementBase(
            fileSystem,
            hostAbi: writeShorebirdReplacementHost(fileSystem, artifacts, targetOS: targetOS),
          );
          final processManager = FakeProcessManager.empty();
          environment = Environment.test(
            fileSystem.currentDirectory,
            fileSystem: fileSystem,
            logger: logger,
            artifacts: artifacts,
            processManager: processManager,
            platform: FakePlatform(environment: binding),
            defines: <String, String>{
              kBuildMode: 'release',
              kTargetPlatform: targetOS == 'macos' ? 'darwin' : 'ios',
              if (targetOS == 'macos') kDarwinArchs: 'arm64',
              kExtraFrontEndOptions: '--native-assets=/native_assets.yaml',
            },
          );
          fileSystem.file('.dart_tool/package_config.json')
            ..createSync(recursive: true)
            ..writeAsStringSync('{"configVersion":2,"packages":[]}');
          final File descriptor = environment.buildDir.childFile(kShorebirdNativeAssetsDescriptor)
            ..createSync(recursive: true)
            ..writeAsStringSync('stale');
          final String build = environment.buildDir.path;
          final File expectedKernel = environment.buildDir.childFile('app.dill')
            ..writeAsStringSync('stale expected kernel');
          final String reportedKernel = redirected ? '$build/other.dill' : expectedKernel.path;
          processManager.addCommands(<FakeCommand>[
            ...shorebirdReplacementVersionCommands(artifacts, targetOS: targetOS),
            FakeCommand(
              command: <String>[
                artifacts.getArtifactPath(Artifact.engineDartAotRuntime),
                artifacts.getArtifactPath(Artifact.frontendServerSnapshotForEngineDartSdk),
                '--sdk-root',
                if (targetOS == 'ios')
                  'Artifact.flutterPatchedSdkPath.TargetPlatform.ios.release/'
                else
                  '/engine/macos_release_arm64/flutter_patched_sdk/',
                '--target=flutter',
                '--no-print-incremental-dependencies',
                ...buildModeOptions(BuildMode.release, <String>[]),
                '--aot',
                '--no-tfa',
                '--shorebird-full-replacement',
                '--shorebird-replacement-base=/private/base.sbr',
                '--shorebird-host-abi=${binding['SHOREBIRD_AOT_HOST_ABI']}',
                '--target-os',
                targetOS,
                '--packages',
                'org-dartlang-root:///.dart_tool/package_config.json',
                '--output-dill',
                '$build/app.dill',
                '--depfile',
                '$build/${KernelSnapshot.depfile}',
                '--filesystem-root',
                '/',
                '--filesystem-scheme',
                'org-dartlang-root',
                '--shorebird-native-assets-descriptor=${descriptor.path}',
                '--shorebird-native-assets-target=${targetOS}_arm64',
                '--verbosity=error',
                '--native-assets=/native_assets.yaml',
                'org-dartlang-root:///lib/main.dart',
              ],
              onRun: (List<String> command) {
                expect(descriptor.existsSync(), isFalse);
                if (success) {
                  descriptor.writeAsStringSync('$expectedDescriptor\n');
                  if (redirected) {
                    fileSystem.file(reportedKernel).writeAsStringSync('fresh redirected kernel');
                  }
                }
              },
              exitCode: success ? 0 : 1,
              stdout: success ? 'result boundary\nboundary\nboundary $reportedKernel 0\n' : '',
            ),
          ]);
          if (success && !redirected) {
            await const KernelSnapshot().build(environment);
            expect(descriptor.readAsStringSync(), '$expectedDescriptor\n');
          } else {
            await expectLater(
              const KernelSnapshot().build(environment),
              redirected
                  ? throwsA(
                      isA<FormatException>().having(
                        (FormatException error) => error.message,
                        'message',
                        contains('expected kernel'),
                      ),
                    )
                  : throwsException,
            );
            expect(descriptor.existsSync(), success);
            expect(expectedKernel.readAsStringSync(), 'stale expected kernel');
            if (redirected) {
              expect(fileSystem.file(reportedKernel).readAsStringSync(), 'fresh redirected kernel');
            }
          }
          expect(processManager, hasNoRemainingExpectations);
        },
        overrides: <Type, Generator>{
          FeatureFlags: () => TestFeatureFlags(),
          FileSystem: () => fileSystem,
          ProcessManager: () => environment.processManager,
        },
      );
    }
  }
}

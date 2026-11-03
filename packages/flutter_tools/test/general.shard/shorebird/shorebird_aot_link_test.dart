// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/artifacts.dart';
import 'package:flutter_tools/src/base/build.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/macos/xcode.dart';
import 'package:flutter_tools/src/shorebird/shorebird_aot_link.dart';
import 'package:flutter_tools/src/shorebird/shorebird_interpreter.dart';

import '../../src/common.dart';
import '../../src/fake_process_manager.dart';

const _kYaml = 'aot_patch_runtime_mode: ios-aot-link\n';

void main() {
  group('profile selection', () {
    testWithoutContext('only ios-aot-link on iOS selects it', () {
      expect(shorebirdUsesAotLinkMode('ios-aot-link', 'ios'), isTrue);
      expect(shorebirdUsesAotLinkMode('dart-bytecode-interpreter', 'ios'), isFalse);
      expect(shorebirdUsesAotLinkMode(null, 'ios'), isFalse);
      expect(() => shorebirdUsesAotLinkMode('ios-aot-link', 'macos'), throwsFormatException);
      expect(() => shorebirdUsesAotLinkMode('ios-aot-link', 'android-arm64'), throwsFormatException);
    });

    testWithoutContext('reads shorebird.yaml and is not the interpreter', () {
      final fs = MemoryFileSystem.test();
      expect(shorebirdUsesAotLink(fs, 'ios'), isFalse);
      fs.file('shorebird.yaml').writeAsStringSync(_kYaml);
      expect(shorebirdUsesAotLink(fs, 'ios'), isTrue);
      expect(shorebirdUsesBytecodeInterpreter(fs, 'ios'), isFalse);
      expect(shorebirdUsesFullReplacement(fs, 'ios'), isFalse);
      expect(() => shorebirdUsesAotLink(fs, 'darwin'), throwsFormatException);
    });

    testWithoutContext('rejects the interpreter-only options', () {
      final fs = MemoryFileSystem.test();
      fs.file('shorebird.yaml').writeAsStringSync('${_kYaml}aot_patch_structural_updates: true\n');
      expect(() => shorebirdUsesAotLink(fs, 'ios'), throwsFormatException);
    });
  });

  group('ShorebirdAotLink.read', () {
    late MemoryFileSystem fs;
    setUp(() {
      fs = MemoryFileSystem.test();
      fs.file('/rel/App.link').createSync(recursive: true);
      fs.file('/rel/App.dd').createSync(recursive: true);
    });

    testWithoutContext('a release has no base', () {
      final link = ShorebirdAotLink.read(fs, <String, String>{}, 'build');
      expect(link.isPatch, isFalse);
      expect(link.ddMaxBytes, 0);
      expect(link.ddPackages, isEmpty);
    });

    testWithoutContext('a release enables DD only with a positive threshold', () {
      final off = ShorebirdAotLink.read(fs, <String, String>{
        kShorebirdAotLinkDdMaxBytesEnvVar: '0',
      }, 'build');
      expect(off.ddMaxBytes, 0);
      final on = ShorebirdAotLink.read(fs, <String, String>{
        kShorebirdAotLinkDdMaxBytesEnvVar: '10000',
        kShorebirdAotLinkDdPackagesEnvVar: ' my_app, my_pkg,,',
        kShorebirdAotLinkToolEnvVar: '/t/ios_linker.dart',
      }, 'build');
      expect(on.ddMaxBytes, 10000);
      expect(on.ddPackages, <String>['my_app', 'my_pkg']);
      expect(on.toolPath, '/t/ios_linker.dart');
    });

    testWithoutContext('a patch needs an existing absolute base', () {
      expect(
        () => ShorebirdAotLink.read(fs, <String, String>{
          kShorebirdAotLinkBaseEnvVar: 'rel/App.link',
        }, 'build'),
        throwsFormatException,
      );
      expect(
        () => ShorebirdAotLink.read(fs, <String, String>{
          kShorebirdAotLinkBaseEnvVar: '/rel/missing.link',
        }, 'build'),
        throwsFormatException,
      );
      final link = ShorebirdAotLink.read(fs, <String, String>{
        kShorebirdAotLinkBaseEnvVar: '/rel/App.link',
        kShorebirdAotLinkDdTargetsEnvVar: '/rel/App.dd',
      }, 'build');
      expect(link.isPatch, isTrue);
      expect(link.ddTargets, '/rel/App.dd');
    });

    testWithoutContext('DD targets need a base; a patch cannot select DD', () {
      expect(
        () => ShorebirdAotLink.read(fs, <String, String>{
          kShorebirdAotLinkDdTargetsEnvVar: '/rel/App.dd',
        }, 'build'),
        throwsFormatException,
      );
      expect(
        () => ShorebirdAotLink.read(fs, <String, String>{
          kShorebirdAotLinkBaseEnvVar: '/rel/App.link',
          kShorebirdAotLinkDdMaxBytesEnvVar: '10000',
        }, 'build'),
        throwsFormatException,
      );
    });
  });

  group('AOTSnapshotter ios-aot-link', () {
    late MemoryFileSystem fileSystem;
    late Artifacts artifacts;
    late FakeProcessManager processManager;
    late BufferLogger logger;
    late String genSnapshot;
    late String dart;

    AOTSnapshotter make(Map<String, String> environment) => AOTSnapshotter(
      fileSystem: fileSystem,
      logger: logger,
      xcode: Xcode.test(processManager: processManager),
      artifacts: artifacts,
      processManager: processManager,
      platform: FakePlatform(environment: environment),
    );

    Future<int> build(AOTSnapshotter snapshotter, {bool obfuscate = false, BuildMode mode = BuildMode.release}) =>
        snapshotter.build(
          platform: TargetPlatform.ios,
          buildMode: mode,
          mainPath: 'main.dill',
          outputPath: 'build/foo',
          darwinArch: DarwinArch.arm64,
          sdkRoot: 'path/to/sdk',
          dartObfuscation: obfuscate,
        );

    /// What flutter_tools runs after gen_snapshot for every iOS build.
    List<FakeCommand> frameworkCommands() => const <FakeCommand>[
      kWhichSysctl,
      kArmCheck,
      FakeCommand(
        command: <String>[
          'xcrun', 'cc', '-arch', 'arm64', '-miphoneos-version-min=15.0', '-isysroot', 'path/to/sdk',
          '-c', 'build/foo/snapshot_assembly.S', '-o', 'build/foo/snapshot_assembly.o', //
        ],
      ),
      FakeCommand(command: <String>['xcrun', 'clang', '-arch', 'arm64', ..._kClang]),
      FakeCommand(
        command: <String>[
          'xcrun', 'dsymutil', '-o', 'build/foo/App.framework.dSYM', 'build/foo/App.framework/App', //
        ],
      ),
      FakeCommand(
        command: <String>[
          'xcrun', 'strip', '-x', 'build/foo/App.framework/App', '-o', 'build/foo/App.framework/App', //
        ],
      ),
    ];

    FakeCommand asm(List<String> extra) => FakeCommand(
      command: <String>[
        genSnapshot,
        '--deterministic',
        '--snapshot_kind=app-aot-assembly',
        '--assembly=build/foo/snapshot_assembly.S',
        ...extra,
        'main.dill',
      ],
    );

    FakeCommand elf(String name, List<String> extra) => FakeCommand(
      command: <String>[
        genSnapshot,
        '--deterministic',
        '--snapshot_kind=app-aot-elf',
        '--elf=build/$name',
        '--strip',
        ...extra,
        'main.dill',
      ],
      onRun: (_) => fileSystem.file('build/$name').writeAsStringSync('elf'),
    );

    setUp(() {
      fileSystem = MemoryFileSystem.test();
      artifacts = Artifacts.test();
      processManager = FakeProcessManager.empty();
      logger = BufferLogger.test();
      dart = artifacts.getArtifactPath(Artifact.engineDartBinary);
      genSnapshot = artifacts.getArtifactPath(
        Artifact.genSnapshotArm64,
        platform: TargetPlatform.ios,
        mode: BuildMode.release,
      );
      fileSystem.file('shorebird.yaml').writeAsStringSync(_kYaml);
    });

    testWithoutContext('a release writes the sidecar next to, not into, the output', () async {
      processManager.addCommands(<FakeCommand>[
        asm(<String>['--print_link_info_to=build/App.link']),
        ...frameworkCommands(),
      ]);

      expect(await build(make(<String, String>{})), 0);
      expect(processManager, hasNoRemainingExpectations);
    });

    testWithoutContext('a release removes the files of an earlier patch build', () async {
      for (final name in <String>['out.aot', 'out.link', 'constraints.link', 'App.dd']) {
        fileSystem.file('build/$name').createSync(recursive: true);
      }
      processManager.addCommands(<FakeCommand>[
        asm(<String>['--print_link_info_to=build/App.link']),
        ...frameworkCommands(),
      ]);

      expect(await build(make(<String, String>{})), 0);
      for (final name in <String>['out.aot', 'out.link', 'constraints.link', 'App.dd']) {
        expect(fileSystem.file('build/$name').existsSync(), isFalse, reason: name);
      }
    });

    testWithoutContext('a DD release selects targets from the app packages only', () async {
      processManager.addCommands(<FakeCommand>[
        elf('App.analysis.aot', <String>['--print_link_info_to=build/App.analysis.link']),
        FakeCommand(
          command: <String>[
            dart, '/tools/ios_linker.dart', 'dd-select', '--base', 'build/App.analysis.aot',
            '--link', 'build/App.analysis.link', '--max-bytes', '10000', '--only-packages', 'my_app,my_pkg',
            '--out', 'build/App.dd', //
          ],
        ),
        asm(<String>['--print_link_info_to=build/App.link', '--link_dd_targets=build/App.dd']),
        ...frameworkCommands(),
      ]);

      final AOTSnapshotter snapshotter = make(<String, String>{
        kShorebirdAotLinkDdMaxBytesEnvVar: '10000',
        kShorebirdAotLinkDdPackagesEnvVar: 'my_app,my_pkg',
        kShorebirdAotLinkToolEnvVar: '/tools/ios_linker.dart',
      });
      expect(await build(snapshotter), 0);
      expect(processManager, hasNoRemainingExpectations);
      expect(fileSystem.file('build/App.analysis.aot').existsSync(), isFalse);
    });

    testWithoutContext('a patch builds two ELF passes with pool hints, then the framework', () async {
      fileSystem.file('/rel/App.link').createSync(recursive: true);
      fileSystem.file('build/App.link').createSync(recursive: true);
      processManager.addCommands(<FakeCommand>[
        elf('out.pass1.aot', <String>[
          '--link_base=/rel/App.link',
          '--print_link_info_to=build/out.pass1.link',
        ]),
        FakeCommand(
          command: <String>[
            dart, '/tools/ios_linker.dart', 'pool-hints', '--base-link', '/rel/App.link',
            '--patch-link', 'build/out.pass1.link', '--out', 'build/constraints.link', //
          ],
        ),
        elf('out.aot', <String>[
          '--link_base=build/constraints.link',
          '--print_link_info_to=build/out.link',
        ]),
        asm(<String>['--link_base=build/constraints.link']),
        ...frameworkCommands(),
      ]);

      final AOTSnapshotter snapshotter = make(<String, String>{
        kShorebirdAotLinkBaseEnvVar: '/rel/App.link',
        kShorebirdAotLinkToolEnvVar: '/tools/ios_linker.dart',
      });
      expect(await build(snapshotter), 0);
      expect(processManager, hasNoRemainingExpectations);
      // The release's files are not mixed into the patch's, and pass 1 is gone.
      expect(fileSystem.file('build/App.link').existsSync(), isFalse);
      expect(fileSystem.file('build/out.pass1.aot').existsSync(), isFalse);
      expect(fileSystem.file('build/out.aot').existsSync(), isTrue);
    });

    testWithoutContext('a patch of a DD release passes the release targets on every pass', () async {
      fileSystem.file('/rel/App.link').createSync(recursive: true);
      fileSystem.file('/rel/App.dd').createSync(recursive: true);
      const dd = '--link_dd_targets=/rel/App.dd';
      processManager.addCommands(<FakeCommand>[
        elf('out.pass1.aot', <String>[
          '--link_base=/rel/App.link',
          '--print_link_info_to=build/out.pass1.link',
          dd,
        ]),
        FakeCommand(
          command: <String>[
            dart, '/tools/ios_linker.dart', 'pool-hints', '--base-link', '/rel/App.link',
            '--patch-link', 'build/out.pass1.link', '--out', 'build/constraints.link', //
          ],
        ),
        elf('out.aot', <String>[
          '--link_base=build/constraints.link',
          '--print_link_info_to=build/out.link',
          dd,
        ]),
        asm(<String>['--link_base=build/constraints.link', dd]),
        ...frameworkCommands(),
      ]);

      final AOTSnapshotter snapshotter = make(<String, String>{
        kShorebirdAotLinkBaseEnvVar: '/rel/App.link',
        kShorebirdAotLinkDdTargetsEnvVar: '/rel/App.dd',
        kShorebirdAotLinkToolEnvVar: '/tools/ios_linker.dart',
      });
      expect(await build(snapshotter), 0);
      expect(processManager, hasNoRemainingExpectations);
    });

    testWithoutContext('a failing pool-hints pass fails the build before the framework', () async {
      fileSystem.file('/rel/App.link').createSync(recursive: true);
      processManager.addCommands(<FakeCommand>[
        elf('out.pass1.aot', <String>[
          '--link_base=/rel/App.link',
          '--print_link_info_to=build/out.pass1.link',
        ]),
        FakeCommand(
          command: <String>[
            dart, '/tools/ios_linker.dart', 'pool-hints', '--base-link', '/rel/App.link',
            '--patch-link', 'build/out.pass1.link', '--out', 'build/constraints.link', //
          ],
          exitCode: 4,
          stderr: 'compiler mismatch',
        ),
      ]);

      final AOTSnapshotter snapshotter = make(<String, String>{
        kShorebirdAotLinkBaseEnvVar: '/rel/App.link',
        kShorebirdAotLinkToolEnvVar: '/tools/ios_linker.dart',
      });
      expect(await build(snapshotter), 4);
      expect(logger.errorText, contains('compiler mismatch'));
      expect(processManager, hasNoRemainingExpectations);
    });

    testWithoutContext('a patch without the tool says how to set it', () async {
      fileSystem.file('/rel/App.link').createSync(recursive: true);
      processManager.addCommand(
        elf('out.pass1.aot', <String>[
          '--link_base=/rel/App.link',
          '--print_link_info_to=build/out.pass1.link',
        ]),
      );
      final AOTSnapshotter snapshotter = make(<String, String>{
        kShorebirdAotLinkBaseEnvVar: '/rel/App.link',
      });
      expect(await build(snapshotter), 1);
      expect(logger.errorText, contains(kShorebirdAotLinkToolEnvVar));
    });

    testWithoutContext('refuses profile builds, obfuscation and simulators', () async {
      expect(
        () => build(make(<String, String>{}), mode: BuildMode.profile),
        throwsFormatException,
      );
      expect(() => build(make(<String, String>{}), obfuscate: true), throwsFormatException);
      expect(
        () => make(<String, String>{}).build(
          platform: TargetPlatform.ios,
          buildMode: BuildMode.release,
          mainPath: 'main.dill',
          outputPath: 'build/foo',
          darwinArch: DarwinArch.arm64,
          sdkRoot: '/x/iPhoneSimulator.sdk',
          dartObfuscation: false,
        ),
        throwsFormatException,
      );
    });

    testWithoutContext('other profiles never get the sidecar flags', () async {
      fileSystem.file('shorebird.yaml').deleteSync();
      fileSystem.file('build/App.link').createSync(recursive: true);
      fileSystem.file('build/out.aot').createSync(recursive: true);
      processManager.addCommands(<FakeCommand>[asm(<String>[]), ...frameworkCommands()]);
      expect(await build(make(<String, String>{})), 0);
      expect(fileSystem.file('build/App.link').existsSync(), isFalse);
      expect(fileSystem.file('build/out.aot').existsSync(), isFalse);
    });
  });
}

const kWhichSysctl = FakeCommand(command: <String>['which', 'sysctl']);
const kArmCheck = FakeCommand(command: <String>['sysctl', 'hw.optional.arm64'], exitCode: 1);
const _kClang = <String>[
  '-miphoneos-version-min=15.0',
  '-isysroot',
  'path/to/sdk',
  '-dynamiclib',
  '-Xlinker',
  '-rpath',
  '-Xlinker',
  '@executable_path/Frameworks',
  '-Xlinker',
  '-rpath',
  '-Xlinker',
  '@loader_path/Frameworks',
  '-fapplication-extension',
  '-install_name',
  '@rpath/App.framework/App',
  '-o',
  'build/foo/App.framework/App',
  'build/foo/snapshot_assembly.o',
];

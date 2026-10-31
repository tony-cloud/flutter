// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:file/memory.dart';
import 'package:flutter_tools/src/artifacts.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/compile.dart';
import 'package:package_config/package_config.dart';

import '../src/common.dart';
import '../src/fake_process_manager.dart';
import '../src/shorebird_replacement.dart';

void main() {
  testWithoutContext('StdoutHandler can parse output for successful batch compilation', () async {
    final logger = BufferLogger.test();
    final stdoutHandler = StdoutHandler(logger: logger, fileSystem: MemoryFileSystem.test());

    stdoutHandler.reset();
    'result abc\nline1\nline2\nabc\nabc /path/to/main.dart.dill 0'
        .split('\n')
        .forEach(stdoutHandler.handler);
    final CompilerOutput? output = await stdoutHandler.compilerOutput?.future;

    expect(logger.errorText, equals('line1\nline2\n'));
    expect(output?.outputFilename, equals('/path/to/main.dart.dill'));
  });

  testWithoutContext('StdoutHandler can parse output for failed batch compilation', () async {
    final logger = BufferLogger.test();
    final stdoutHandler = StdoutHandler(logger: logger, fileSystem: MemoryFileSystem.test());

    stdoutHandler.reset();
    'result abc\nline1\nline2\nabc\nabc'.split('\n').forEach(stdoutHandler.handler);
    final CompilerOutput? output = await stdoutHandler.compilerOutput?.future;

    expect(logger.errorText, equals('line1\nline2\n'));
    expect(output, equals(null));
  });

  testWithoutContext(
    'KernelCompiler passes correct configuration to frontend server process',
    () async {
      final logger = BufferLogger.test();
      final stdoutHandler = StdoutHandler(logger: logger, fileSystem: MemoryFileSystem.test());
      final completer = Completer<void>();

      final kernelCompiler = KernelCompiler(
        artifacts: Artifacts.test(),
        fileSystem: MemoryFileSystem.test(),
        fileSystemRoots: <String>[],
        fileSystemScheme: '',
        logger: logger,
        processManager: FakeProcessManager.list(<FakeCommand>[
          FakeCommand(
            command: const <String>[
              'Artifact.engineDartAotRuntime',
              'Artifact.frontendServerSnapshotForEngineDartSdk',
              '--sdk-root',
              '/path/to/sdkroot/',
              '--target=flutter',
              '--no-print-incremental-dependencies',
              '-Ddart.vm.profile=false',
              '-Ddart.vm.product=false',
              '--enable-asserts',
              '--no-link-platform',
              '--packages',
              '.dart_tool/package_config.json',
              '--verbosity=error',
              'file:///path/to/main.dart',
            ],
            completer: completer,
          ),
        ]),
        stdoutHandler: stdoutHandler,
      );
      final Future<CompilerOutput?> output = kernelCompiler.compile(
        sdkRoot: '/path/to/sdkroot',
        mainPath: '/path/to/main.dart',
        buildMode: BuildMode.debug,
        trackWidgetCreation: false,
        dartDefines: const <String>[],
        packageConfig: PackageConfig.empty,
        packagesPath: '.dart_tool/package_config.json',
      );
      stdoutHandler.compilerOutput?.complete(const CompilerOutput('', 0, <Uri>[]));
      completer.complete();

      expect((await output)?.outputFilename, '');
    },
  );

  testWithoutContext('KernelCompiler returns null if StdoutHandler returns null', () async {
    final logger = BufferLogger.test();
    final stdoutHandler = StdoutHandler(logger: logger, fileSystem: MemoryFileSystem.test());
    final completer = Completer<void>();

    final kernelCompiler = KernelCompiler(
      artifacts: Artifacts.test(),
      fileSystem: MemoryFileSystem.test(),
      fileSystemRoots: <String>[],
      fileSystemScheme: '',
      logger: logger,
      processManager: FakeProcessManager.list(<FakeCommand>[
        FakeCommand(
          command: const <String>[
            'Artifact.engineDartAotRuntime',
            'Artifact.frontendServerSnapshotForEngineDartSdk',
            '--sdk-root',
            '/path/to/sdkroot/',
            '--target=flutter',
            '--no-print-incremental-dependencies',
            '-Ddart.vm.profile=false',
            '-Ddart.vm.product=false',
            '--enable-asserts',
            '--no-link-platform',
            '--packages',
            '.dart_tool/package_config.json',
            '--verbosity=error',
            'file:///path/to/main.dart',
          ],
          completer: completer,
        ),
      ]),
      stdoutHandler: stdoutHandler,
    );
    final Future<CompilerOutput?> output = kernelCompiler.compile(
      sdkRoot: '/path/to/sdkroot',
      mainPath: '/path/to/main.dart',
      buildMode: BuildMode.debug,
      trackWidgetCreation: false,
      dartDefines: const <String>[],
      packageConfig: PackageConfig.empty,
      packagesPath: '.dart_tool/package_config.json',
    );
    stdoutHandler.compilerOutput?.complete();
    completer.complete();

    expect(await output, null);
  });

  testWithoutContext(
    'KernelCompiler returns null if frontend_server process exits with non-zero code',
    () async {
      final logger = BufferLogger.test();
      final stdoutHandler = StdoutHandler(logger: logger, fileSystem: MemoryFileSystem.test());
      final completer = Completer<void>();

      final kernelCompiler = KernelCompiler(
        artifacts: Artifacts.test(),
        fileSystem: MemoryFileSystem.test(),
        fileSystemRoots: <String>[],
        fileSystemScheme: '',
        logger: logger,
        processManager: FakeProcessManager.list(<FakeCommand>[
          FakeCommand(
            command: const <String>[
              'Artifact.engineDartAotRuntime',
              'Artifact.frontendServerSnapshotForEngineDartSdk',
              '--sdk-root',
              '/path/to/sdkroot/',
              '--target=flutter',
              '--no-print-incremental-dependencies',
              '-Ddart.vm.profile=false',
              '-Ddart.vm.product=false',
              '--enable-asserts',
              '--no-link-platform',
              '--packages',
              '.dart_tool/package_config.json',
              '--verbosity=error',
              'file:///path/to/main.dart',
            ],
            completer: completer,
            exitCode: 127,
          ),
        ]),
        stdoutHandler: stdoutHandler,
      );
      final Future<CompilerOutput?> output = kernelCompiler.compile(
        sdkRoot: '/path/to/sdkroot',
        mainPath: '/path/to/main.dart',
        buildMode: BuildMode.debug,
        trackWidgetCreation: false,
        dartDefines: const <String>[],
        packageConfig: PackageConfig.empty,
        packagesPath: '.dart_tool/package_config.json',
      );
      stdoutHandler.compilerOutput?.complete(const CompilerOutput('', 0, <Uri>[]));
      completer.complete();

      expect(await output, null);
    },
  );

  for (final (bool interpreter, bool structural, bool full, String? targetOS)
      in <(bool, bool, bool, String?)>[
        (false, false, false, null),
        (true, false, false, 'ios'),
        (true, true, false, 'ios'),
        (true, true, false, 'android'),
        (true, false, true, 'ios'),
      ]) {
    testWithoutContext(
      'KernelCompiler AOT profile: $interpreter/$structural/$full/$targetOS',
      () async {
        final fileSystem = MemoryFileSystem.test();
        if (full) {
          fileSystem.currentDirectory = fileSystem.directory('/path/to')
            ..createSync(recursive: true);
          fileSystem.file('/path/to/.dart_tool/flutter_build/dart_plugin_registrant.dart')
            ..createSync(recursive: true)
            ..writeAsStringSync('// registrant');
        }
        if (interpreter) {
          fileSystem
              .file('shorebird.yaml')
              .writeAsStringSync(
                'aot_patch_runtime_mode: dart-bytecode-interpreter\n'
                'aot_patch_structural_updates: $structural\n'
                'aot_patch_full_replacement: $full\n',
              );
        }
        final Map<String, String> environment = full
            ? writeShorebirdReplacementBase(
                fileSystem,
                hostAbi: writeShorebirdReplacementHost(fileSystem, Artifacts.test()),
              )
            : <String, String>{};
        final logger = BufferLogger.test();
        final stdoutHandler = StdoutHandler(logger: logger, fileSystem: fileSystem);
        final completer = Completer<void>();

        final kernelCompiler = KernelCompiler(
          platform: FakePlatform(environment: environment),
          artifacts: Artifacts.test(),
          fileSystem: fileSystem,
          fileSystemRoots: <String>[],
          fileSystemScheme: '',
          logger: logger,
          processManager: FakeProcessManager.list(<FakeCommand>[
            if (full) ...shorebirdReplacementVersionCommands(Artifacts.test()),
            FakeCommand(
              command: <String>[
                'Artifact.engineDartAotRuntime',
                'Artifact.frontendServerSnapshotForEngineDartSdk',
                '--sdk-root',
                if (full)
                  'Artifact.flutterPatchedSdkPath.TargetPlatform.ios.release/'
                else
                  '/path/to/sdkroot/',
                '--target=flutter',
                '--no-print-incremental-dependencies',
                if (full) '-Ddart.vm.profile=false' else '-Ddart.vm.profile=true',
                if (full) '-Ddart.vm.product=true' else '-Ddart.vm.product=false',
                '--delete-tostring-package-uri=dart:ui',
                '--delete-tostring-package-uri=package:flutter',
                '--no-link-platform',
                '--aot',
                if (interpreter && targetOS == 'ios') '--no-tfa' else '--tfa',
                if (structural && targetOS == 'ios') '--shorebird-structural-patching',
                if (full) ...<String>[
                  '--shorebird-full-replacement',
                  '--shorebird-replacement-base=/private/base.sbr',
                  '--shorebird-host-abi=${environment['SHOREBIRD_AOT_HOST_ABI']}',
                ],
                if (targetOS != null) ...<String>['--target-os', targetOS],
                '--packages',
                if (full)
                  'org-dartlang-root:///.dart_tool/package_config.json'
                else
                  '.dart_tool/package_config.json',
                if (full) ...<String>[
                  '--depfile',
                  '/path/to/main.d',
                  '--filesystem-root',
                  '/path/to',
                  '--filesystem-scheme',
                  'org-dartlang-root',
                  '--source',
                  'org-dartlang-root:///.dart_tool/flutter_build/dart_plugin_registrant.dart',
                  '--source',
                  'package:flutter/src/dart_plugin_registrant.dart',
                  '-Dflutter.dart_plugin_registrant=org-dartlang-root:///.dart_tool/flutter_build/dart_plugin_registrant.dart',
                ],
                '--verbosity=error',
                if (full) 'org-dartlang-root:///main.dart' else 'file:///path/to/main.dart',
              ],
              completer: completer,
            ),
          ]),
          stdoutHandler: stdoutHandler,
        );
        final Future<CompilerOutput?> output = kernelCompiler.compile(
          sdkRoot: '/path/to/sdkroot',
          mainPath: '/path/to/main.dart',
          buildMode: full ? BuildMode.release : BuildMode.profile,
          trackWidgetCreation: false,
          aot: true,
          buildDir: full ? fileSystem.directory('/path/to/.dart_tool/flutter_build/hash') : null,
          checkDartPluginRegistry: full,
          depFilePath: full ? '/path/to/main.d' : null,
          targetOS: targetOS,
          dartDefines: const <String>[],
          packageConfig: PackageConfig.empty,
          packagesPath: '.dart_tool/package_config.json',
        );
        stdoutHandler.compilerOutput?.complete(const CompilerOutput('', 0, <Uri>[]));
        completer.complete();

        expect((await output)?.outputFilename, '');
      },
    );
  }

  testWithoutContext('full profile rejects non-AOT, nonrelease and non-iOS compilation', () async {
    final fileSystem = MemoryFileSystem.test();
    fileSystem
        .file('shorebird.yaml')
        .writeAsStringSync(
          'aot_patch_runtime_mode: dart-bytecode-interpreter\naot_patch_full_replacement: true\n',
        );
    final processManager = FakeProcessManager.empty();
    final compiler = KernelCompiler(
      fileSystem: fileSystem,
      logger: BufferLogger.test(),
      processManager: processManager,
      artifacts: Artifacts.test(),
      fileSystemRoots: <String>[],
      platform: FakePlatform(environment: writeShorebirdReplacementBase(fileSystem)),
    );
    for (final (bool aot, BuildMode mode, String os) in <(bool, BuildMode, String)>[
      (false, BuildMode.debug, 'ios'),
      (true, BuildMode.profile, 'ios'),
      (true, BuildMode.release, 'android'),
    ]) {
      await expectLater(
        compiler.compile(
          sdkRoot: '/sdk',
          mainPath: '/main.dart',
          aot: aot,
          targetOS: os,
          packagesPath: null,
          buildMode: mode,
          trackWidgetCreation: false,
          dartDefines: const <String>[],
          packageConfig: PackageConfig.empty,
        ),
        throwsFormatException,
      );
    }
    expect(processManager, hasNoRemainingExpectations);
  });

  testWithoutContext('passes correct AOT config to kernel compiler in aot/release mode', () async {
    final logger = BufferLogger.test();
    final stdoutHandler = StdoutHandler(logger: logger, fileSystem: MemoryFileSystem.test());
    final completer = Completer<void>();

    final kernelCompiler = KernelCompiler(
      artifacts: Artifacts.test(),
      fileSystem: MemoryFileSystem.test(),
      fileSystemRoots: <String>[],
      fileSystemScheme: '',
      logger: logger,
      processManager: FakeProcessManager.list(<FakeCommand>[
        FakeCommand(
          command: const <String>[
            'Artifact.engineDartAotRuntime',
            'Artifact.frontendServerSnapshotForEngineDartSdk',
            '--sdk-root',
            '/path/to/sdkroot/',
            '--target=flutter',
            '--no-print-incremental-dependencies',
            '-Ddart.vm.profile=false',
            '-Ddart.vm.product=true',
            '--delete-tostring-package-uri=dart:ui',
            '--delete-tostring-package-uri=package:flutter',
            '--no-link-platform',
            '--aot',
            '--tfa',
            '--packages',
            '.dart_tool/package_config.json',
            '--verbosity=error',
            'file:///path/to/main.dart',
          ],
          completer: completer,
        ),
      ]),
      stdoutHandler: stdoutHandler,
    );
    final Future<CompilerOutput?> output = kernelCompiler.compile(
      sdkRoot: '/path/to/sdkroot',
      mainPath: '/path/to/main.dart',
      buildMode: BuildMode.release,
      trackWidgetCreation: false,
      aot: true,
      dartDefines: const <String>[],
      packageConfig: PackageConfig.empty,
      packagesPath: '.dart_tool/package_config.json',
    );
    stdoutHandler.compilerOutput?.complete(const CompilerOutput('', 0, <Uri>[]));
    completer.complete();

    expect((await output)?.outputFilename, '');
  });

  testWithoutContext('KernelCompiler passes dartDefines to the frontend_server', () async {
    final logger = BufferLogger.test();
    final stdoutHandler = StdoutHandler(logger: logger, fileSystem: MemoryFileSystem.test());
    final completer = Completer<void>();

    final kernelCompiler = KernelCompiler(
      artifacts: Artifacts.test(),
      fileSystem: MemoryFileSystem.test(),
      fileSystemRoots: <String>[],
      fileSystemScheme: '',
      logger: logger,
      processManager: FakeProcessManager.list(<FakeCommand>[
        FakeCommand(
          command: const <String>[
            'Artifact.engineDartAotRuntime',
            'Artifact.frontendServerSnapshotForEngineDartSdk',
            '--sdk-root',
            '/path/to/sdkroot/',
            '--target=flutter',
            '--no-print-incremental-dependencies',
            '-DFOO=bar',
            '-DBAZ=qux',
            '-Ddart.vm.profile=false',
            '-Ddart.vm.product=false',
            '--enable-asserts',
            '--no-link-platform',
            '--packages',
            '.dart_tool/package_config.json',
            '--verbosity=error',
            'file:///path/to/main.dart',
          ],
          completer: completer,
        ),
      ]),
      stdoutHandler: stdoutHandler,
    );

    final Future<CompilerOutput?> output = kernelCompiler.compile(
      sdkRoot: '/path/to/sdkroot',
      mainPath: '/path/to/main.dart',
      buildMode: BuildMode.debug,
      trackWidgetCreation: false,
      dartDefines: const <String>['FOO=bar', 'BAZ=qux'],
      packageConfig: PackageConfig.empty,
      packagesPath: '.dart_tool/package_config.json',
    );

    stdoutHandler.compilerOutput?.complete(const CompilerOutput('', 0, <Uri>[]));
    completer.complete();

    expect((await output)?.outputFilename, '');
  });

  testWithoutContext('KernelCompiler maps a file to a multi-root scheme if provided', () async {
    final logger = BufferLogger.test();
    final stdoutHandler = StdoutHandler(logger: logger, fileSystem: MemoryFileSystem.test());
    final completer = Completer<void>();

    final kernelCompiler = KernelCompiler(
      artifacts: Artifacts.test(),
      fileSystem: MemoryFileSystem.test(),
      fileSystemRoots: <String>['/foo/bar/fizz'],
      fileSystemScheme: 'scheme',
      logger: logger,
      processManager: FakeProcessManager.list(<FakeCommand>[
        FakeCommand(
          command: const <String>[
            'Artifact.engineDartAotRuntime',
            'Artifact.frontendServerSnapshotForEngineDartSdk',
            '--sdk-root',
            '/path/to/sdkroot/',
            '--target=flutter',
            '--no-print-incremental-dependencies',
            '-Ddart.vm.profile=false',
            '-Ddart.vm.product=false',
            '--enable-asserts',
            '--no-link-platform',
            '--packages',
            '.dart_tool/package_config.json',
            '--verbosity=error',
            'scheme:///main.dart',
          ],
          completer: completer,
        ),
      ]),
      stdoutHandler: stdoutHandler,
    );

    final Future<CompilerOutput?> output = kernelCompiler.compile(
      sdkRoot: '/path/to/sdkroot',
      mainPath: '/foo/bar/fizz/main.dart',
      buildMode: BuildMode.debug,
      trackWidgetCreation: false,
      dartDefines: const <String>[],
      packageConfig: PackageConfig.empty,
      packagesPath: '.dart_tool/package_config.json',
    );

    stdoutHandler.compilerOutput?.complete(const CompilerOutput('', 0, <Uri>[]));
    completer.complete();

    expect((await output)?.outputFilename, '');
  });

  testWithoutContext('KernelCompiler uses generated entrypoint', () async {
    final logger = BufferLogger.test();
    final stdoutHandler = StdoutHandler(logger: logger, fileSystem: MemoryFileSystem.test());
    final completer = Completer<void>();
    final fs = MemoryFileSystem.test();
    final kernelCompiler = KernelCompiler(
      artifacts: Artifacts.test(),
      fileSystem: fs,
      fileSystemRoots: <String>['/foo/bar/fizz'],
      fileSystemScheme: 'scheme',
      logger: logger,
      processManager: FakeProcessManager.list(<FakeCommand>[
        FakeCommand(
          command: const <String>[
            'Artifact.engineDartAotRuntime',
            'Artifact.frontendServerSnapshotForEngineDartSdk',
            '--sdk-root',
            '/path/to/sdkroot/',
            '--target=flutter',
            '--no-print-incremental-dependencies',
            '-Ddart.vm.profile=false',
            '-Ddart.vm.product=false',
            '--enable-asserts',
            '--no-link-platform',
            '--packages',
            '.dart_tool/package_config.json',
            '--source',
            '.dart_tools/flutter_build/dart_plugin_registrant.dart',
            '--source',
            'package:flutter/src/dart_plugin_registrant.dart',
            '-Dflutter.dart_plugin_registrant=.dart_tools/flutter_build/dart_plugin_registrant.dart',
            '--verbosity=error',
            'scheme:///main.dart',
          ],
          completer: completer,
        ),
      ]),
      stdoutHandler: stdoutHandler,
    );

    final Directory buildDir = fs
        .directory('.dart_tools')
        .childDirectory('flutter_build')
        .childDirectory('test');

    buildDir.parent.childFile('dart_plugin_registrant.dart').createSync(recursive: true);

    final Future<CompilerOutput?> output = kernelCompiler.compile(
      sdkRoot: '/path/to/sdkroot',
      mainPath: '/foo/bar/fizz/main.dart',
      buildMode: BuildMode.debug,
      trackWidgetCreation: false,
      dartDefines: const <String>[],
      packageConfig: PackageConfig.empty,
      packagesPath: '.dart_tool/package_config.json',
      buildDir: buildDir,
      checkDartPluginRegistry: true,
    );

    stdoutHandler.compilerOutput?.complete(const CompilerOutput('', 0, <Uri>[]));
    completer.complete();
    await output;
  });

  testWithoutContext('KernelCompiler passes native assets', () async {
    final logger = BufferLogger.test();
    final stdoutHandler = StdoutHandler(logger: logger, fileSystem: MemoryFileSystem.test());
    final completer = Completer<void>();

    final kernelCompiler = KernelCompiler(
      artifacts: Artifacts.test(),
      fileSystem: MemoryFileSystem.test(),
      fileSystemRoots: <String>[],
      fileSystemScheme: '',
      logger: logger,
      processManager: FakeProcessManager.list(<FakeCommand>[
        FakeCommand(
          command: const <String>[
            'Artifact.engineDartAotRuntime',
            'Artifact.frontendServerSnapshotForEngineDartSdk',
            '--sdk-root',
            '/path/to/sdkroot/',
            '--target=flutter',
            '--no-print-incremental-dependencies',
            '-Ddart.vm.profile=false',
            '-Ddart.vm.product=false',
            '--enable-asserts',
            '--no-link-platform',
            '--packages',
            '.dart_tool/package_config.json',
            '--native-assets',
            'path/to/native_assets.yaml',
            '--verbosity=error',
            'file:///path/to/main.dart',
          ],
          completer: completer,
        ),
      ]),
      stdoutHandler: stdoutHandler,
    );
    final Future<CompilerOutput?> output = kernelCompiler.compile(
      sdkRoot: '/path/to/sdkroot',
      mainPath: '/path/to/main.dart',
      buildMode: BuildMode.debug,
      trackWidgetCreation: false,
      dartDefines: const <String>[],
      packageConfig: PackageConfig.empty,
      packagesPath: '.dart_tool/package_config.json',
      nativeAssets: 'path/to/native_assets.yaml',
    );
    stdoutHandler.compilerOutput?.complete(const CompilerOutput('', 0, <Uri>[]));
    completer.complete();

    expect((await output)?.outputFilename, '');
  });
}

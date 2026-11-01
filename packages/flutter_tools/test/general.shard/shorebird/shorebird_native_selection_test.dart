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
import 'package:flutter_tools/src/build_system/depfile.dart';
import 'package:flutter_tools/src/build_system/targets/assets.dart';
import 'package:flutter_tools/src/cmake.dart';
import 'package:flutter_tools/src/isolated/native_assets/dart_hook_result.dart';
import 'package:flutter_tools/src/project.dart';
import 'package:flutter_tools/src/shorebird/shorebird_native_selection.dart';
import 'package:flutter_tools/src/shorebird/shorebird_yaml.dart';
import 'package:yaml/yaml.dart';

import '../../src/common.dart';
import '../../src/context.dart';
import '../../src/package_config.dart';
import '../../src/shorebird_native_selection.dart';

void main() {
  late FileSystem fs;
  late Map<String, String> environment;
  setUp(() {
    fs = MemoryFileSystem.test();
    environment = writeNativeSelectionManifest(fs);
  });
  ShorebirdNativeSelectionInputs read() => ShorebirdNativeSelectionInputs.read(fs, environment);
  Map<String, dynamic> config() =>
      jsonDecode(fs.file('/private/manifest.json').readAsStringSync()) as Map<String, dynamic>;
  void write(Map<String, dynamic> config) =>
      fs.file('/private/manifest.json').writeAsStringSync(jsonEncode(config));
  Map<String, dynamic> compile([String yaml = nativeSelectionYaml]) => compileShorebirdYaml(
    loadYaml(yaml) as YamlMap,
    flavor: null,
    environment: environment,
    fileSystem: fs,
  );

  testWithoutContext('sealed Android covers all supported native wire architectures', () {
    final ShorebirdNativeSelectionInputs inputs = read()
      ..validateTarget(TargetPlatform.android, <String, String>{
        kAndroidArchs: 'android-arm android-arm64 android-x64',
      });
    expect(inputs.scopes.keys, <String>['arm', 'aarch64', 'x86_64']);
    expect(inputs.inputs.map((File file) => file.path), <String>[
      '/private/manifest.json',
      '/private/arm.so',
      '/private/aarch64.so',
      '/private/x86_64.so',
    ]);
    expect(jsonEncode(inputs.assets), isNot(contains('/private')));
    expect(compile()['aot_patch_app_build_id'], '1.0.0+1');
  });

  for (final platform in <String>['linux', 'windows']) {
    for (final arch in <String>['aarch64', 'x86_64']) {
      testWithoutContext('$platform $arch validates ELF AOT and exact target', () {
        environment = writeNativeSelectionManifest(fs, platform: platform, arches: <String>[arch]);
        read().validateTarget(
          getTargetPlatformForName('$platform-${arch == 'aarch64' ? 'arm64' : 'x64'}'),
          <String, String>{},
        );
      });
    }
  }

  for (final MapEntry<String, void Function(Map<String, dynamic>)> mutation
      in <String, void Function(Map<String, dynamic>)>{
        'missing architecture': (Map<String, dynamic> value) =>
            (value['entries'] as List<dynamic>).removeLast(),
        'extra architecture': (Map<String, dynamic> value) =>
            (value['arches'] as List<dynamic>).add('x86'),
        'duplicate architecture': (Map<String, dynamic> value) =>
            (value['arches'] as List<dynamic>).add('arm'),
        'extra entry': (Map<String, dynamic> value) =>
            (value['entries'] as List<dynamic>).add((value['entries'] as List<dynamic>).first),
        'unknown field': (Map<String, dynamic> value) => value['private'] = true,
        'wrong version type': (Map<String, dynamic> value) => value['version'] = 1.0,
        'unknown mode': (Map<String, dynamic> value) => value['mode'] = 'auto',
        'invalid release version': (Map<String, dynamic> value) =>
            value['release_version'] = '\u0000',
      }.entries) {
    testWithoutContext('rejects ${mutation.key}', () {
      final Map<String, dynamic> value = config();
      mutation.value(value);
      write(value);
      expect(read, throwsFormatException);
    });
  }

  for (final MapEntry<String, Object?> entry in <String, Object?>{
    'app_id': '22222222-2222-4222-8222-222222222222',
    'release_version': 'other',
    'platform': 'linux',
    'arch': 'x86',
    'base_artifact_hash': '00' * 32,
    'host_abi_hash': '11' * 32,
    'runtime_profile': 'interpreter-body',
    'unknown': null,
  }.entries) {
    testWithoutContext('rejects conflicting scope ${entry.key}', () {
      final Map<String, dynamic> value = config();
      final scope =
          ((value['entries'] as List<dynamic>).first as Map<String, dynamic>)['scope']
              as Map<String, dynamic>;
      scope[entry.key] = entry.value;
      write(value);
      expect(read, throwsFormatException);
    });
  }

  testWithoutContext('rejects ambiguous duplicate keys including escaped spellings', () {
    final File manifest = fs.file('/private/manifest.json');
    final String original = manifest.readAsStringSync();
    manifest.writeAsStringSync(
      original.replaceFirst('"version":1', r'"version":1,"ver\u0073ion":1'),
    );
    expect(read, throwsFormatException);
    manifest.writeAsStringSync(
      original.replaceFirst('"host_abi_hash":null', '"host_abi_hash":null,"host_abi_hash":null'),
    );
    expect(read, throwsFormatException);
  });

  testWithoutContext('rejects wrong ELF machine even with a matching content hash', () {
    fs.file('/private/arm.so').writeAsBytesSync(fs.file('/private/aarch64.so').readAsBytesSync());
    final Map<String, dynamic> value = config();
    final entries = value['entries'] as List<dynamic>;
    final scope = (entries.first as Map<String, dynamic>)['scope'] as Map<String, dynamic>;
    scope['base_artifact_hash'] =
        ((entries[1] as Map<String, dynamic>)['scope']
            as Map<String, dynamic>)['base_artifact_hash'];
    write(value);
    expect(read, throwsFormatException);
  });

  testWithoutContext('rejects missing or relative private inputs', () {
    environment = <String, String>{};
    expect(read, throwsFormatException);
    environment = <String, String>{kShorebirdNativeSelectionManifest: 'private/manifest.json'};
    expect(read, throwsFormatException);
  });

  testWithoutContext('exact build target architecture set cannot differ from manifest', () {
    for (final arches in <String>[
      'android-arm',
      'android-arm android-arm64 android-x64 android-x86',
      '',
    ]) {
      expect(
        () =>
            read().validateTarget(TargetPlatform.android, <String, String>{kAndroidArchs: arches}),
        throwsFormatException,
      );
    }
    expect(
      () => read().validateTarget(TargetPlatform.linux_x64, <String, String>{}),
      throwsFormatException,
    );
  });

  testWithoutContext('measurement is explicit, scope-free, and remains protocol 2', () {
    environment = writeNativeSelectionManifest(fs, measure: true);
    expect(read().isMeasurement, isTrue);
    expect(read().assets, isEmpty);
    expect(compile()['selection_protocol'], 2);
    final Map<String, dynamic> value = config()..['mode'] = 'sealed';
    write(value);
    expect(read, throwsFormatException);
    environment = writeNativeSelectionManifest(fs);
    write(config()..['mode'] = 'measure');
    expect(read, throwsFormatException);
  });

  testWithoutContext('compiled v2 rejects missing manifest and conflicting native policy', () {
    for (final yaml in <String>[
      nativeSelectionYaml.replaceFirst('strict', 'permissive'),
      nativeSelectionYaml.replaceFirst('required', 'optional'),
      nativeSelectionYaml.replaceFirst('pinned-key', ''),
      nativeSelectionYaml.replaceFirst('1.0.0+1', 'other'),
      nativeSelectionYaml.replaceFirst(
        nativeSelectionAppId,
        '22222222-2222-4222-8222-222222222222',
      ),
      '$nativeSelectionYaml\naot_patch_runtime_mode: dart-bytecode-interpreter',
      '$nativeSelectionYaml\naot_patch_base_snapshot_hash: ${'11' * 32}',
    ]) {
      expect(() => compile(yaml), throwsFormatException);
    }
    environment = <String, String>{};
    expect(compile, throwsFormatException);
  });

  testWithoutContext('native protocol 2 supplies absent strict verification defaults', () {
    final Map<String, dynamic> compiled = compile(
      nativeSelectionYaml
          .replaceFirst('patch_verification: strict\n', '')
          .replaceFirst('patch_response_verification: required\n', ''),
    );
    expect(compiled['patch_verification'], 'strict');
    expect(compiled['patch_response_verification'], 'required');
  });

  testWithoutContext('native license and expiry metadata stay outside compiled runtime policy', () {
    final Map<String, dynamic> compiled = compile(
      '$nativeSelectionYaml\naot_patch_license_type: pro\naot_patch_offline_expires_at: 2030-01-01T00:00:00Z',
    );
    expect(compiled.containsKey('aot_patch_license_type'), isFalse);
    expect(compiled.containsKey('aot_patch_offline_expires_at'), isFalse);
  });

  testWithoutContext('generated CMake command changes for measurement and sealed content', () {
    fs.file('pubspec.yaml').writeAsStringSync('name: example\nversion: 1.0.0+1\n');
    final LinuxProject project = FlutterProject.fromDirectoryTest(fs.currentDirectory).linux;
    const info = BuildInfo(
      BuildMode.release,
      null,
      treeShakeIcons: false,
      packageConfigPath: '.dart_tool/package_config.json',
    );
    String generated() {
      writeGeneratedCmakeConfig(
        '/flutter',
        project,
        info,
        shorebirdNativeSelectionBuildEnvironment(fs, environment),
        BufferLogger.test(),
      );
      return project.generatedCmakeConfigFile.readAsStringSync();
    }

    final String sealed = generated();
    expect(sealed, contains('SHOREBIRD_NATIVE_SELECTION_INPUT_DIGEST='));
    expect(sealed, isNot(contains('/private')));
    environment = writeNativeSelectionManifest(fs, measure: true);
    expect(generated(), isNot(sealed));
  });

  testWithoutContext('build key changes on manifest contents, phase and baseline digests', () {
    String key() => const CopyAssets().buildKeyFor(
      Environment.test(
        fs.currentDirectory,
        fileSystem: fs,
        logger: BufferLogger.test(),
        artifacts: Artifacts.test(),
        processManager: FakeProcessManager.any(),
        platform: FakePlatform(environment: environment),
        defines: <String, String>{kBuildMode: 'release'},
      ),
    )!;
    final String sealed = key();
    fs
        .file('/private/manifest.json')
        .writeAsStringSync('${fs.file('/private/manifest.json').readAsStringSync()}\n');
    expect(key(), isNot(sealed));
    environment = writeNativeSelectionManifest(fs, measure: true);
    expect(key(), isNot(sealed));
    environment = writeNativeSelectionManifest(fs);
    fs.file('/private/arm.so').writeAsStringSync('changed original baseline');
    expect(key, throwsFormatException);
  });
  testUsingContext(
    'asset bundle seals exact scopes, tracks private inputs and cleans stale scopes',
    () async {
      fs
          .file('pubspec.yaml')
          .writeAsStringSync(
            'name: example\nflutter:\n  assets:\n    - shorebird.yaml\n    - shorebird_release_scope_fake_arm.json\n',
          );
      fs.file('shorebird.yaml').writeAsStringSync(nativeSelectionYaml);
      fs.file('shorebird_release_scope_fake_arm.json').writeAsStringSync('untrusted user binding');
      writePackageConfigFiles(directory: fs.currentDirectory, mainLibName: 'example');
      final Directory output = fs.directory('/out')..createSync();
      output
          .childFile('shorebird_release_scope_ios_aarch64.json')
          .writeAsStringSync('old Apple scope');
      output.childFile('shorebird_interpreter_base.bytecode').writeAsStringSync('old bytecode');
      var targetArches = 'android-arm android-arm64 android-x64';
      Future<Depfile> bundle() => copyAssets(
        Environment.test(
          fs.currentDirectory,
          fileSystem: fs,
          logger: BufferLogger.test(),
          artifacts: Artifacts.test(),
          processManager: FakeProcessManager.any(),
          platform: FakePlatform(environment: environment),
          defines: <String, String>{
            kBuildMode: 'release',
            kAndroidArchs: targetArches,
            'TreeShakeIcons': 'false',
          },
        ),
        output,
        dartHookResult: DartHooksResult.empty(),
        targetPlatform: TargetPlatform.android,
        buildMode: BuildMode.release,
      );
      final Depfile depfile = await bundle();
      expect(
        depfile.inputs.map((File file) => file.path),
        containsAll(<String>[
          '/private/manifest.json',
          '/private/arm.so',
          '/private/aarch64.so',
          '/private/x86_64.so',
        ]),
      );
      final List<String> names = output
          .listSync()
          .map((FileSystemEntity file) => file.basename)
          .toList();
      expect(
        names.where((String name) => name.startsWith('shorebird_release_scope_')),
        unorderedEquals(<String>[
          'shorebird_release_scope_android_arm.json',
          'shorebird_release_scope_android_aarch64.json',
          'shorebird_release_scope_android_x86_64.json',
        ]),
      );
      expect(names, isNot(contains('shorebird_interpreter_base.bytecode')));
      expect(names.any((String name) => name.endsWith('.so')), isFalse);
      for (final File file in output.listSync().whereType<File>().where(
        (File file) => file.basename.endsWith('.json') || file.basename == 'shorebird.yaml',
      )) {
        expect(file.readAsStringSync(), isNot(contains('/private')));
      }
      targetArches = 'android-arm64';
      environment = writeNativeSelectionManifest(fs, arches: <String>['aarch64']);
      await bundle();
      expect(
        output
            .listSync()
            .where((FileSystemEntity file) => file.basename.startsWith('shorebird_release_scope_'))
            .map((FileSystemEntity file) => file.basename),
        <String>['shorebird_release_scope_android_aarch64.json'],
      );
      targetArches = 'android-arm android-arm64 android-x64';
      environment = writeNativeSelectionManifest(fs, measure: true);
      await bundle();
      expect(
        output.listSync().any(
          (FileSystemEntity file) => file.basename.startsWith('shorebird_release_scope_'),
        ),
        isFalse,
      );
      expect(
        (loadYaml(output.childFile('shorebird.yaml').readAsStringSync())
            as YamlMap)['selection_protocol'],
        2,
      );
      environment = writeNativeSelectionManifest(fs);
      await bundle();
      fs.file('shorebird.yaml').writeAsStringSync('app_id: legacy');
      environment = <String, String>{};
      await bundle();
      expect(
        output.listSync().any(
          (FileSystemEntity file) => file.basename.startsWith('shorebird_release_scope_'),
        ),
        isFalse,
      );
    },
    overrides: <Type, Generator>{
      FileSystem: () => fs,
      ProcessManager: () => FakeProcessManager.any(),
    },
  );
}

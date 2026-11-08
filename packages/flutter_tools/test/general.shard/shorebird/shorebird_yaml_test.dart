// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:file/memory.dart';
import 'package:flutter_tools/src/artifacts.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/shorebird/shorebird_yaml.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../../src/shorebird_native_selection.dart';
import '../../src/shorebird_replacement.dart';

void main() {
  group('ShorebirdYaml', () {
    test('native image budget stays absent unless the release specifies it', () {
      final Map<String, dynamic> compiled = compileShorebirdYaml(
        loadYaml('app_id: app') as YamlMap,
        flavor: null,
        environment: <String, String>{'SHOREBIRD_NATIVE_PATCH_MAX_BYTES': '1'},
      );
      expect(compiled.containsKey('native_patch_max_bytes'), isFalse);
    });
    test('native image budget preserves release values across flavor selection', () {
      for (final bytes in <int>[1, 536870912, 0x7fffffffffffffff]) {
        final Map<String, dynamic> compiled = compileShorebirdYaml(
          loadYaml('app_id: app\nflavors:\n  paid: paid-app\nnative_patch_max_bytes: $bytes\n')
              as YamlMap,
          flavor: 'paid',
          environment: <String, String>{'SHOREBIRD_NATIVE_PATCH_MAX_BYTES': '2'},
        );
        expect(compiled['app_id'], 'paid-app');
        expect(compiled['native_patch_max_bytes'], bytes);
      }
    });
    test('native image budget rejects malformed or unbounded release values', () {
      for (final value in <String>[
        'null',
        'true',
        '"1024"',
        '1.5',
        '0',
        '-1',
        '9223372036854775808',
      ]) {
        expect(
          () => compileShorebirdYaml(
            loadYaml('app_id: app\nnative_patch_max_bytes: $value\n') as YamlMap,
            flavor: null,
            environment: <String, String>{},
          ),
          throwsFormatException,
          reason: value,
        );
      }
    });
    test('yaml ignores comments', () {
      const yamlContents = '''
# This file is used to configure the Shorebird updater used by your app.
app_id: 6160a7d8-cc18-4928-1233-05b51c0bb02c

# auto_update controls if Shorebird should automatically update in the background on launch.
auto_update: false
''';
      final YamlDocument input = loadYamlDocument(yamlContents);
      final yamlMap = input.contents as YamlMap;
      final Map<String, dynamic> compiled = compileShorebirdYaml(
        yamlMap,
        flavor: null,
        environment: <String, String>{},
      );
      expect(compiled, <String, dynamic>{
        'app_id': '6160a7d8-cc18-4928-1233-05b51c0bb02c',
        'auto_update': false,
      });
    });
    test('flavors', () {
      // These are invalid app_ids but make for easy testing.
      const yamlContents = '''
app_id: 1-a
auto_update: false
flavors:
  foo: 2-a
  bar: 3-a
''';
      final YamlDocument input = loadYamlDocument(yamlContents);
      final yamlMap = input.contents as YamlMap;
      expect(appIdForFlavor(yamlMap, flavor: null), '1-a');
      expect(appIdForFlavor(yamlMap, flavor: 'foo'), '2-a');
      expect(appIdForFlavor(yamlMap, flavor: 'bar'), '3-a');
      expect(() => appIdForFlavor(yamlMap, flavor: 'unknown'), throwsException);
    });
    test('all values', () {
      // These are invalid app_ids but make for easy testing.
      const yamlContents = '''
app_id: 1-a
auto_update: false
flavors:
  foo: 2-a
  bar: 3-a
base_url: https://example.com
patch_verification: strict
''';
      final YamlDocument input = loadYamlDocument(yamlContents);
      final yamlMap = input.contents as YamlMap;
      final Map<String, dynamic> compiled1 = compileShorebirdYaml(
        yamlMap,
        flavor: null,
        environment: <String, String>{},
      );
      expect(compiled1, <String, dynamic>{
        'app_id': '1-a',
        'auto_update': false,
        'base_url': 'https://example.com',
        'patch_verification': 'strict',
      });
      final Map<String, dynamic> compiled2 = compileShorebirdYaml(
        yamlMap,
        flavor: 'foo',
        environment: <String, String>{'SHOREBIRD_PUBLIC_KEY': '4-a'},
      );
      expect(compiled2, <String, dynamic>{
        'app_id': '2-a',
        'auto_update': false,
        'base_url': 'https://example.com',
        'patch_verification': 'strict',
        'patch_public_key': '4-a',
        'patch_response_verification': 'required',
      });
    });
    test('interpreter metadata survives compilation without secrets', () {
      final yaml =
          loadYamlDocument('''
app_id: app-id
aot_patch_runtime_mode: dart-bytecode-interpreter
aot_patch_structural_updates: true
aot_patch_app_build_id: '1.0.0+1'
aot_patch_base_flavor_id: free
aot_patch_base_license_type: free
aot_patch_flavor_id: pro
aot_patch_license_type: pro
aot_patch_sdk_hash: sdk
aot_patch_base_snapshot_hash: base-hash
aot_patch_obfuscation_map_hash: map-hash
aot_patch_key_id: account-key
aot_patch_key_hex: NEVER_BUNDLE_THIS
aot_patch_bytecode_path: /private/patch.bytecode
aot_patch_patch_snapshot_hash: future-patch
patch_verification: none
patch_response_verification: optional
''').contents
              as YamlMap;
      final Map<String, dynamic> compiled = compileShorebirdYaml(
        yaml,
        flavor: null,
        environment: <String, String>{'SHOREBIRD_PUBLIC_KEY': 'publisher-key'},
      );
      expect(compiled['aot_patch_runtime_mode'], 'dart-bytecode-interpreter');
      expect(compiled['aot_patch_structural_updates'], isTrue);
      expect(compiled['aot_patch_app_build_id'], '1.0.0+1');
      expect(compiled['aot_patch_base_flavor_id'], 'free');
      expect(compiled['aot_patch_base_license_type'], 'free');
      expect(compiled['aot_patch_flavor_id'], 'pro');
      expect(compiled['aot_patch_license_type'], 'pro');
      expect(compiled['aot_patch_sdk_hash'], 'sdk');
      expect(compiled['aot_patch_base_snapshot_hash'], 'base-hash');
      expect(compiled['aot_patch_obfuscation_map_hash'], 'map-hash');
      expect(compiled['aot_patch_key_id'], 'account-key');
      expect(compiled['patch_verification'], 'strict');
      expect(compiled['patch_response_verification'], 'required');
      expect(compiled['patch_public_key'], 'publisher-key');
      expect(compiled.containsKey('aot_patch_key_hex'), isFalse);
      expect(compiled.containsKey('aot_patch_bytecode_path'), isFalse);
      expect(compiled.containsKey('aot_patch_patch_snapshot_hash'), isFalse);
    });
    test('structural profile stays source-owned and preserves absent or false values', () {
      for (final setting in <String>['', 'aot_patch_structural_updates: false\n']) {
        final yaml = loadYaml('app_id: app\n$setting') as YamlMap;
        final Map<String, dynamic> compiled = compileShorebirdYaml(
          yaml,
          flavor: null,
          environment: <String, String>{'SHOREBIRD_AOT_PATCH_STRUCTURAL_UPDATES': 'true'},
        );
        expect(compiled.containsKey('aot_patch_structural_updates'), setting.isNotEmpty);
        if (setting.isNotEmpty) {
          expect(compiled['aot_patch_structural_updates'], isFalse);
        }
      }
    });
    test('compilation rejects malformed and contradictory structural profiles', () {
      for (final configuration in <String>[
        'aot_patch_structural_updates: "true"\n',
        'aot_patch_structural_updates: null\n',
        'aot_patch_structural_updates: true\n',
        'aot_patch_structural_updates: true\naot_patch_runtime_mode: native-aot\n',
      ]) {
        expect(
          () => compileShorebirdYaml(
            loadYaml('app_id: app\n$configuration') as YamlMap,
            flavor: null,
            environment: <String, String>{'SHOREBIRD_PUBLIC_KEY': 'publisher'},
          ),
          throwsFormatException,
        );
      }
      expect(
        () => compileShorebirdYaml(
          loadYaml(
                'app_id: app\naot_patch_structural_updates: true\n'
                'aot_patch_runtime_mode: dart-bytecode-interpreter\n',
              )
              as YamlMap,
          flavor: null,
          environment: <String, String>{
            'SHOREBIRD_PUBLIC_KEY': 'publisher',
            'SHOREBIRD_AOT_PATCH_RUNTIME_MODE': 'native-aot',
          },
        ),
        throwsFormatException,
      );
    });
    test('full replacement bundles only public binding and rejects inconsistent hashes', () {
      final fileSystem = MemoryFileSystem.test();
      final environment = <String, String>{
        ...writeShorebirdReplacementBase(fileSystem),
        'SHOREBIRD_PUBLIC_KEY': 'publisher',
        'SHOREBIRD_AOT_PATCH_KEY_HEX': 'SECRET',
      };
      final yaml =
          loadYaml(
                'app_id: app\naot_patch_runtime_mode: dart-bytecode-interpreter\n'
                'aot_patch_full_replacement: true\naot_patch_replacement_base: /secret/path\n'
                'aot_patch_host_abi: stale\n',
              )
              as YamlMap;
      final Map<String, dynamic> compiled = compileShorebirdYaml(
        yaml,
        flavor: null,
        environment: environment,
        fileSystem: fileSystem,
      );
      expect(compiled['aot_patch_full_replacement'], isTrue);
      expect(compiled['aot_patch_replacement_base'], 'shorebird_replacement_base.sbr');
      expect(compiled['aot_patch_host_abi'], environment['SHOREBIRD_AOT_HOST_ABI']);
      expect(
        compiled['aot_patch_base_snapshot_hash'],
        environment['SHOREBIRD_AOT_BASE_SNAPSHOT_HASH'],
      );
      expect(compiled.toString(), isNot(contains('/private/')));
      expect(compiled.toString(), isNot(contains('SECRET')));
      expect(
        () => compileShorebirdYaml(
          yaml,
          flavor: null,
          fileSystem: fileSystem,
          environment: <String, String>{
            ...environment,
            'SHOREBIRD_AOT_BASE_SNAPSHOT_HASH': 'b' * 64,
          },
        ),
        throwsFormatException,
      );
    });
    test('interpreter compilation fails without publisher pin', () {
      final yaml =
          loadYamlDocument('''
app_id: app-id
aot_patch_runtime_mode: dart-bytecode-interpreter
''').contents
              as YamlMap;
      expect(
        () => compileShorebirdYaml(yaml, flavor: null, environment: <String, String>{}),
        throwsException,
      );
    });
    test('derived release hash overrides stale source without bundling secrets', () {
      final yaml =
          loadYamlDocument('''
app_id: app-id
aot_patch_base_snapshot_hash: stale-source-hash
''').contents
              as YamlMap;
      final String hash = 'a' * 64;
      final Map<String, dynamic> compiled = compileShorebirdYaml(
        yaml,
        flavor: null,
        environment: <String, String>{
          'SHOREBIRD_AOT_BASE_SNAPSHOT_HASH': hash,
          'SHOREBIRD_AOT_PATCH_SDK_HASH': 'derived-sdk',
          'SHOREBIRD_AOT_PATCH_KEY_HEX': 'NEVER_BUNDLE',
        },
      );
      expect(compiled['aot_patch_base_snapshot_hash'], hash);
      expect(compiled['aot_patch_sdk_hash'], 'derived-sdk');
      expect(compiled.containsKey('aot_patch_key_hex'), isFalse);
      expect(
        () => compileShorebirdYaml(
          yaml,
          flavor: null,
          environment: <String, String>{'SHOREBIRD_AOT_BASE_SNAPSHOT_HASH': 'not-a-sha256'},
        ),
        throwsException,
      );
    });
    test('patch builds can retain absent baseline target restrictions', () {
      final yaml =
          loadYamlDocument('''
app_id: app
aot_patch_app_build_id: source-build
aot_patch_flavor_id: pro
aot_patch_license_type: pro
aot_patch_obfuscation_map_hash: patch-map
''').contents
              as YamlMap;
      final Map<String, dynamic> compiled = compileShorebirdYaml(
        yaml,
        flavor: null,
        environment: <String, String>{
          'SHOREBIRD_AOT_PATCH_APP_BUILD_ID': '',
          'SHOREBIRD_AOT_PATCH_FLAVOR_ID': '',
          'SHOREBIRD_AOT_PATCH_LICENSE_TYPE': '',
          'SHOREBIRD_AOT_PATCH_OBFUSCATION_MAP_HASH': '',
        },
      );
      expect(compiled, <String, dynamic>{'app_id': 'app'});
    });
    test('native legacy builds can explicitly retain optional responses', () {
      final yaml =
          loadYamlDocument('app_id: app\npatch_response_verification: optional\n').contents
              as YamlMap;
      final Map<String, dynamic> compiled = compileShorebirdYaml(
        yaml,
        flavor: null,
        environment: <String, String>{'SHOREBIRD_PUBLIC_KEY': 'publisher'},
      );
      expect(compiled['patch_response_verification'], 'optional');
    });
    test('edit in place', () {
      const yamlContents = '''
app_id: 1-a
auto_update: false
flavors:
  foo: 2-a
  bar: 3-a
base_url: https://example.com
''';
      // Make a temporary file to test editing in place.
      final Directory tempDir = Directory.systemTemp.createTempSync('shorebird_yaml_test.');
      final tempFile = File('${tempDir.path}/shorebird.yaml');
      tempFile.writeAsStringSync(yamlContents);
      updateShorebirdYaml(
        'foo',
        tempFile.path,
        environment: <String, String>{'SHOREBIRD_PUBLIC_KEY': '4-a'},
      );
      final String updatedContents = tempFile.readAsStringSync();
      // Order is not guaranteed, so parse as YAML to compare.
      final YamlDocument updated = loadYamlDocument(updatedContents);
      final yamlMap = updated.contents as YamlMap;
      expect(yamlMap['app_id'], '2-a');
      expect(yamlMap['auto_update'], false);
      expect(yamlMap['base_url'], 'https://example.com');
    });
  });

  group('security profiles', () {
    final toolchainId = 'sha256:${'ab' * 32}';
    const hardenedYaml = '''
app_id: app
base_url: https://updates.example.com
''';
    Map<String, String> hardenedEnv([Map<String, String> extra = const <String, String>{}]) =>
        <String, String>{
          'SHOREBIRD_SECURITY_PROFILE': 'hardened',
          'SHOREBIRD_TOOLCHAIN_ID': toolchainId,
          'SHOREBIRD_PUBLIC_KEY': 'pinned-key',
          ...extra,
        };
    Map<String, dynamic> compile(String yaml, Map<String, String> environment) =>
        compileShorebirdYaml(loadYaml(yaml) as YamlMap, flavor: null, environment: environment);
    void expectRejected(String yaml, Map<String, String> environment, {String? reason}) {
      expect(() => compile(yaml, environment), throwsFormatException, reason: reason);
    }

    test('legacy output is unchanged when profile is unset, empty or legacy', () {
      const yaml = 'app_id: app\nbase_url: http://example.com\npatch_verification: install_only\n';
      final Map<String, dynamic> baseline = compile(yaml, <String, String>{
        'SHOREBIRD_PUBLIC_KEY': 'k',
      });
      expect(baseline, <String, dynamic>{
        'app_id': 'app',
        'base_url': 'http://example.com',
        'patch_verification': 'install_only',
        'patch_public_key': 'k',
        'patch_response_verification': 'required',
      });
      for (final profile in <String?>[null, '', 'legacy']) {
        final Map<String, dynamic> compiled = compile(yaml, <String, String>{
          'SHOREBIRD_PUBLIC_KEY': 'k',
          'SHOREBIRD_TOOLCHAIN_ID': toolchainId,
          'SHOREBIRD_SECURITY_DEVELOPMENT_EXCEPTIONS': 'false',
          'SHOREBIRD_SECURITY_PROFILE': ?profile,
        });
        expect(compiled, baseline, reason: '$profile');
        for (final key in <String>[
          'security_profile',
          'security_contract_version',
          'toolchain_id',
          'security_development_exceptions',
        ]) {
          expect(compiled.containsKey(key), isFalse, reason: key);
        }
      }
    });

    test('hardened writes declarations and forces strict and required', () {
      final Map<String, dynamic> compiled = compile(hardenedYaml, hardenedEnv());
      expect(compiled, <String, dynamic>{
        'app_id': 'app',
        'base_url': 'https://updates.example.com',
        'patch_public_key': 'pinned-key',
        'patch_verification': 'strict',
        'patch_response_verification': 'required',
        'security_profile': 'hardened',
        'security_contract_version': 1,
        'toolchain_id': toolchainId,
      });
      expect(compiled['security_contract_version'], isA<int>());
      // Explicit but compliant source values are accepted.
      final Map<String, dynamic> explicit = compile(
        '${hardenedYaml}patch_verification: strict\npatch_response_verification: required\n'
        'patch_public_key: source-key\n',
        hardenedEnv()..remove('SHOREBIRD_PUBLIC_KEY'),
      );
      expect(explicit['patch_public_key'], 'source-key');
      expect(explicit['patch_verification'], 'strict');
      expect(explicit.containsKey('security_development_exceptions'), isFalse);
    });

    test('hardened toolchain_id round-trips through YamlEditor and loadYaml', () {
      final fs = MemoryFileSystem.test();
      fs.file('/shorebird.yaml')
        ..createSync()
        ..writeAsStringSync(hardenedYaml);
      // P3: a hardened build also signs a build manifest (see
      // shorebird_build_manifest_test.dart); Android binds no engine module.
      fs
          .file('/manifest.pem')
          .writeAsStringSync(
            '-----BEGIN PRIVATE KEY-----\n'
            '${base64.encode(<int>[0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20, ...List<int>.filled(32, 7)])}\n'
            '-----END PRIVATE KEY-----\n',
          );
      updateShorebirdYaml(
        '',
        '/shorebird.yaml',
        environment: hardenedEnv(<String, String>{
          'SHOREBIRD_BUILD_MANIFEST_SIGNING_KEY': '/manifest.pem',
        }),
        fileSystem: fs,
        targetPlatform: TargetPlatform.android,
        buildMode: BuildMode.release,
        artifacts: Artifacts.test(fileSystem: fs),
      );
      final String text = fs.file('/shorebird.yaml').readAsStringSync();
      expect(text.trimRight().split('\n').last, startsWith('shorebird_build_manifest: v1.'));
      final loaded = loadYaml(text) as YamlMap;
      expect(loaded['toolchain_id'], toolchainId);
      expect(loaded['security_profile'], 'hardened');
      expect(loaded['security_contract_version'], 1);
      // The updater splits at the first ':'; the value is emitted plain (unquoted).
      expect(text, contains(RegExp('^toolchain_id: $toolchainId\$', multiLine: true)));
    });

    test('hardened rejects bad or missing toolchain id and missing trust root', () {
      expectRejected(
        hardenedYaml,
        hardenedEnv()..remove('SHOREBIRD_TOOLCHAIN_ID'),
        reason: 'missing',
      );
      for (final bad in <String>[
        '',
        'ab' * 32,
        'sha256:${'ab' * 31}',
        'sha256:${'ab' * 33}',
        'sha256:${'AB' * 32}',
        'sha256:${'zz' * 32}',
        'sha256:${'ab' * 32}\n',
        ' sha256:${'ab' * 32}',
        'sha1:${'ab' * 20}',
      ]) {
        expectRejected(
          hardenedYaml,
          hardenedEnv(<String, String>{'SHOREBIRD_TOOLCHAIN_ID': bad}),
          reason: bad,
        );
      }
      expectRejected(hardenedYaml, hardenedEnv()..remove('SHOREBIRD_PUBLIC_KEY'));
      expectRejected(hardenedYaml, hardenedEnv(<String, String>{'SHOREBIRD_PUBLIC_KEY': ''}));
      expectRejected(hardenedYaml, hardenedEnv(<String, String>{'SHOREBIRD_PUBLIC_KEY': '  '}));
    });

    test('hardened source yaml cannot lower the verification floor', () {
      expectRejected('${hardenedYaml}patch_verification: install_only\n', hardenedEnv());
      expectRejected('${hardenedYaml}patch_verification: permissive\n', hardenedEnv());
      expectRejected('${hardenedYaml}patch_response_verification: optional\n', hardenedEnv());
    });

    test('hardened requires an explicit https base_url without user info', () {
      expectRejected('app_id: app\n', hardenedEnv(), reason: 'missing base_url');
      for (final url in <String>[
        'http://updates.example.com',
        'http://localhost:8080',
        'ftp://updates.example.com',
        'updates.example.com',
        'https://',
        'https:///path',
        'https://user@updates.example.com',
        'https://user:pw@updates.example.com',
        'https://@updates.example.com',
      ]) {
        expectRejected('app_id: app\nbase_url: "$url"\n', hardenedEnv(), reason: url);
      }
      expectRejected(
        'app_id: app\nbase_url: https://updates.example.com\n',
        hardenedEnv()..remove('SHOREBIRD_PUBLIC_KEY'),
      );
    });

    test('development exception allows only http to loopback hosts', () {
      final Map<String, String> dev = hardenedEnv(<String, String>{
        'SHOREBIRD_SECURITY_DEVELOPMENT_EXCEPTIONS': 'true',
      });
      for (final url in <String>[
        'http://localhost:8080',
        'http://127.0.0.1',
        'http://127.1.2.3:9000/x',
        'http://[::1]:8080',
        'https://updates.example.com',
      ]) {
        final Map<String, dynamic> compiled = compile('app_id: app\nbase_url: "$url"\n', dev);
        expect(compiled['security_development_exceptions'], true, reason: url);
        expect(compiled['security_profile'], 'hardened');
      }
      for (final url in <String>[
        'http://example.com',
        'http://localhost.example.com',
        'http://128.0.0.1',
        'http://127.0.0.256',
        'http://127.0.0.1.example.com',
        'http://user@localhost',
        'ftp://localhost',
      ]) {
        expectRejected('app_id: app\nbase_url: "$url"\n', dev, reason: url);
      }
      // Without the exception, loopback http is rejected, and false is never written.
      expectRejected('app_id: app\nbase_url: http://localhost:8080\n', hardenedEnv());
      final Map<String, dynamic> explicitFalse = compile(
        hardenedYaml,
        hardenedEnv(<String, String>{'SHOREBIRD_SECURITY_DEVELOPMENT_EXCEPTIONS': 'false'}),
      );
      expect(explicitFalse.containsKey('security_development_exceptions'), isFalse);
      for (final bad in <String>['', 'TRUE', '1', 'yes']) {
        expectRejected(
          hardenedYaml,
          hardenedEnv(<String, String>{'SHOREBIRD_SECURITY_DEVELOPMENT_EXCEPTIONS': bad}),
          reason: bad,
        );
      }
    });

    test('source yaml cannot contain the reserved declaration keys in any profile', () {
      const values = <String, String>{
        'security_profile': 'hardened',
        'security_contract_version': '1',
        'toolchain_id': 'x',
        'security_development_exceptions': 'true',
      };
      for (final MapEntry<String, String> entry in values.entries) {
        final yaml = '$hardenedYaml${entry.key}: ${entry.value}\n';
        expectRejected(yaml, hardenedEnv(), reason: entry.key);
        expectRejected(yaml, <String, String>{}, reason: 'unset ${entry.key}');
        expectRejected(yaml, <String, String>{
          'SHOREBIRD_SECURITY_PROFILE': 'legacy',
        }, reason: 'legacy ${entry.key}');
      }
    });

    test('unknown, reserved and legacy-invalid settings are rejected', () {
      for (final profile in <String>['hardened-diversified', 'strict', 'HARDENED', ' hardened']) {
        expectRejected(
          hardenedYaml,
          hardenedEnv(<String, String>{'SHOREBIRD_SECURITY_PROFILE': profile}),
          reason: profile,
        );
      }
      expectRejected(hardenedYaml, <String, String>{
        'SHOREBIRD_SECURITY_DEVELOPMENT_EXCEPTIONS': 'true',
      }, reason: 'unset profile');
      expectRejected(hardenedYaml, <String, String>{
        'SHOREBIRD_SECURITY_PROFILE': 'legacy',
        'SHOREBIRD_SECURITY_DEVELOPMENT_EXCEPTIONS': 'true',
      }, reason: 'legacy profile');
    });

    test('hardened keys and checks apply to the native selection_protocol 2 path', () {
      final fs = MemoryFileSystem.test();
      final Map<String, String> nativeEnv = writeNativeSelectionManifest(fs);
      const nativeYaml = '$nativeSelectionYaml\nbase_url: https://updates.example.com\n';
      Map<String, dynamic> compileNative(String yaml, Map<String, String> environment) =>
          compileShorebirdYaml(
            loadYaml(yaml) as YamlMap,
            flavor: null,
            environment: environment,
            fileSystem: fs,
          );
      final env = <String, String>{...nativeEnv, ...hardenedEnv()..remove('SHOREBIRD_PUBLIC_KEY')};
      final Map<String, dynamic> compiled = compileNative(nativeYaml, env);
      expect(compiled['selection_protocol'], 2);
      expect(compiled['aot_patch_app_build_id'], '1.0.0+1');
      expect(compiled['security_profile'], 'hardened');
      expect(compiled['security_contract_version'], 1);
      expect(compiled['toolchain_id'], toolchainId);
      expect(compiled['patch_verification'], 'strict');
      expect(compiled['patch_response_verification'], 'required');
      // Checks also run on the early-return path.
      expect(
        () => compileNative(
          nativeYaml.replaceFirst('https://updates.example.com', 'http://updates.example.com'),
          env,
        ),
        throwsFormatException,
      );
      expect(
        () => compileNative(
          nativeYaml.replaceFirst('base_url: https://updates.example.com\n', ''),
          env,
        ),
        throwsFormatException,
      );
      expect(
        () => compileNative(nativeYaml, <String, String>{...env}..remove('SHOREBIRD_TOOLCHAIN_ID')),
        throwsFormatException,
      );
    });
  });
}

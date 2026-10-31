// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:file/memory.dart';
import 'package:flutter_tools/src/shorebird/shorebird_yaml.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../../src/shorebird_replacement.dart';

void main() {
  group('ShorebirdYaml', () {
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
}

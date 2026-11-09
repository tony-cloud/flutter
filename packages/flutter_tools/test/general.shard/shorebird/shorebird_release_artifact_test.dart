// Copyright 2026 The Open Shorebird Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' show Archive, ArchiveFile, ZipEncoder;
import 'package:file/memory.dart';
import 'package:flutter_tools/src/artifacts.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/shorebird/shorebird_build_manifest.dart';
import 'package:flutter_tools/src/shorebird/shorebird_release_artifact.dart';
import 'package:flutter_tools/src/shorebird/shorebird_release_trust.dart';
import 'package:flutter_tools/src/shorebird/shorebird_yaml.dart';
import 'package:test/test.dart';

import 'shorebird_release_trust_fixtures.dart' as fixtures;

const _toolchainId = 'sha256:70229e407e5311401aa3251418eff106467a750ccfcb7e8fe7b61c4442700040';

void _put16(Uint8List b, int at, int v) => b.buffer.asByteData().setUint16(at, v, Endian.little);
void _put32(Uint8List b, int at, int v) => b.buffer.asByteData().setUint32(at, v, Endian.little);
void _put64(Uint8List b, int at, int v) => b.buffer.asByteData().setUint64(at, v, Endian.little);

/// A small 64-bit ELF with one read-only and one writable PT_LOAD segment
/// for `machine` (0x3e x86-64, 0xb7 AArch64); `salt` changes measured bytes.
Uint8List _elf(int machine, {int salt = 0}) {
  final b = Uint8List(0x400);
  b.setRange(0, 4, <int>[0x7f, 0x45, 0x4c, 0x46]);
  b[4] = 2;
  b[5] = 1;
  b[6] = 1;
  _put16(b, 0x10, 3);
  _put16(b, 0x12, machine);
  _put64(b, 0x20, 0x40);
  _put16(b, 0x36, 56);
  _put16(b, 0x38, 2);
  const segments = <List<int>>[
    <int>[1, 5, 0x100, 0x1100, 0x80],
    <int>[1, 6, 0x200, 0x2200, 0x40],
  ];
  for (var i = 0; i < segments.length; i++) {
    final int at = 0x40 + i * 56;
    _put32(b, at, segments[i][0]);
    _put32(b, at + 4, segments[i][1]);
    _put64(b, at + 8, segments[i][2]);
    _put64(b, at + 16, segments[i][3]);
    _put64(b, at + 32, segments[i][4]);
    _put64(b, at + 40, segments[i][4]);
  }
  for (var i = 0; i < 0x200; i++) {
    b[0x100 + i] = (i * 7 + salt) % 251;
  }
  return b;
}

String _pem(List<int> seed) {
  final der = <int>[
    0x30,
    0x2e,
    0x02,
    0x01,
    0x00,
    0x30,
    0x05,
    0x06,
    0x03,
    0x2b,
    0x65,
    0x70,
    0x04,
    0x22,
    0x04,
    0x20, //
    ...seed,
  ];
  return '-----BEGIN PRIVATE KEY-----\n${base64.encode(der)}\n-----END PRIVATE KEY-----\n';
}

void main() {
  late MemoryFileSystem fs;
  late Artifacts artifacts;
  final String rootPin = base64.encode(utf8.encode(fixtures.operatorRoot));

  Map<String, String> env([Map<String, String> extra = const <String, String>{}]) =>
      <String, String>{
        'SHOREBIRD_SECURITY_PROFILE': 'hardened',
        'SHOREBIRD_TOOLCHAIN_ID': _toolchainId,
        'SHOREBIRD_PUBLIC_KEY': 'pinned-key',
        kShorebirdBuildManifestSigningKeyEnvVar: '/keys/manifest.pem',
        kShorebirdReleaseTrustEnvVar: '/keys/release-trust.json',
        kShorebirdReleaseRootEnvVar: rootPin,
        ...extra,
      };

  ShorebirdExpectedPolicy expected([Map<String, String> extra = const <String, String>{}]) =>
      ShorebirdExpectedPolicy.fromEnvironment(env(extra));

  /// The bundled YAML a hardened build of [platform] writes.
  String signedYaml(TargetPlatform platform, {Map<String, String> extra = const {}}) {
    fs.file('/build/shorebird.yaml')
      ..createSync(recursive: true)
      ..writeAsStringSync('app_id: app\nbase_url: https://updates.example.com\n');
    updateShorebirdYaml(
      null,
      '/build/shorebird.yaml',
      environment: env(extra),
      fileSystem: fs,
      targetPlatform: platform,
      buildMode: BuildMode.release,
      artifacts: artifacts,
      clock: () => DateTime.utc(2027, 3),
    );
    return fs.file('/build/shorebird.yaml').readAsStringSync();
  }

  void write(String path, List<int> bytes) => fs.file(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes);

  String zip(String path, Map<String, List<int>> files) {
    final archive = Archive();
    for (final MapEntry<String, List<int>> file in files.entries) {
      archive.addFile(ArchiveFile(file.key, file.value.length, file.value));
    }
    write(path, ZipEncoder().encode(archive)!);
    return path;
  }

  ShorebirdArtifactReport verify(
    String path,
    String platform, {
    ShorebirdExpectedPolicy? policy,
    Set<String>? record,
  }) => verifyShorebirdReleaseArtifact(
    fileSystem: fs,
    artifactPath: path,
    platform: platform,
    expected: policy ?? expected(),
    recordManifests: record,
  );

  Matcher refusedWith(String code) => throwsA(
    isA<ShorebirdArtifactVerificationException>().having(
      (ShorebirdArtifactVerificationException e) => e.code,
      'code',
      code,
    ),
  );

  setUp(() {
    fs = MemoryFileSystem.test();
    artifacts = Artifacts.test(fileSystem: fs);
    write('/keys/manifest.pem', utf8.encode(_pem(List<int>.filled(32, 7))));
    write('/keys/release-trust.json', utf8.encode(fixtures.operatorBundle()));
    write(
      fs.path.join(
        artifacts.getArtifactPath(
          Artifact.linuxDesktopPath,
          platform: TargetPlatform.linux_x64,
          mode: BuildMode.release,
        ),
        'libflutter_linux_gtk.so',
      ),
      _elf(0x3e),
    );
  });

  group('Linux bundle', () {
    late String yaml;

    setUp(() {
      yaml = signedYaml(TargetPlatform.linux_x64);
      write('/bundle/data/flutter_assets/shorebird.yaml', utf8.encode(yaml));
      write('/bundle/lib/libflutter_linux_gtk.so', _elf(0x3e));
      write('/bundle/app', utf8.encode('runner'));
    });

    test('the distributed bundle verifies and reports what it bound', () {
      final ShorebirdArtifactReport report = verify('/bundle', 'linux');
      final Map<String, Object?> json = report.toJson();
      expect(json['verified'], isTrue);
      expect(json['modules'], <Object>[
        <String, String>{
          'platform': 'linux',
          'arch': 'x86_64',
          'measurement': measureShorebirdModuleImage(_elf(0x3e)),
        },
      ]);
      final String digest = report.manifests['data/flutter_assets/shorebird.yaml']!;
      expect(verify('/bundle', 'linux', record: <String>{digest}).manifests, hasLength(1));
      expect(
        () => verify('/bundle', 'linux', record: <String>{'00' * 32}),
        refusedWith('artifact_not_recorded'),
      );
    });

    test('a tampered YAML is refused', () {
      final String head = yaml.substring(0, yaml.indexOf('shorebird_build_manifest'));
      final String line = yaml.substring(head.length);
      for (final tampered in <String>[
        head.replaceFirst('updates.example.com', 'evil.example.com') + line,
        '${head}auto_update: false\n$line',
      ]) {
        write('/bundle/data/flutter_assets/shorebird.yaml', utf8.encode(tampered));
        expect(() => verify('/bundle', 'linux'), refusedWith('config_digest_mismatch'));
      }
      write('/bundle/data/flutter_assets/shorebird.yaml', utf8.encode(head));
      expect(() => verify('/bundle', 'linux'), refusedWith('manifest_missing'));
      write('/bundle/data/flutter_assets/shorebird.yaml', utf8.encode('$yaml$line'));
      expect(() => verify('/bundle', 'linux'), refusedWith('manifest_malformed'));
      write(
        '/bundle/data/flutter_assets/shorebird.yaml',
        utf8.encode(yaml.replaceAll('\n', '\r\n')),
      );
      expect(() => verify('/bundle', 'linux'), refusedWith('manifest_malformed'));
      // A flipped signature byte.
      final String token = line.trim().split(' ').last;
      final List<String> parts = token.split('.');
      final flipped = parts[2].startsWith('A')
          ? 'B${parts[2].substring(1)}'
          : 'A${parts[2].substring(1)}';
      write(
        '/bundle/data/flutter_assets/shorebird.yaml',
        utf8.encode(
          '${head}shorebird_build_manifest: ${parts[0]}.${parts[1]}.$flipped.${parts[3]}\n',
        ),
      );
      expect(() => verify('/bundle', 'linux'), refusedWith('manifest_bad_signature'));
    });

    test('a replaced or substituted engine library is refused', () {
      write('/bundle/lib/libflutter_linux_gtk.so', _elf(0x3e, salt: 1));
      expect(() => verify('/bundle', 'linux'), refusedWith('module_mismatch'));
      // Another architecture's engine is not bound by this manifest.
      write('/bundle/lib/libflutter_linux_gtk.so', _elf(0xb7));
      expect(() => verify('/bundle', 'linux'), refusedWith('module_unbound'));
      fs.file('/bundle/lib/libflutter_linux_gtk.so').deleteSync();
      expect(() => verify('/bundle', 'linux'), refusedWith('artifact_no_engine'));
    });

    test('the declaration must be the toolchain the CLI built with', () {
      expect(
        () => verify(
          '/bundle',
          'linux',
          policy: expected(<String, String>{'SHOREBIRD_TOOLCHAIN_ID': 'sha256:${'1' * 64}'}),
        ),
        refusedWith('manifest_policy_mismatch'),
      );
      expect(
        () => verify(
          '/bundle',
          'linux',
          policy: expected(<String, String>{'SHOREBIRD_SECURITY_DEVELOPMENT_EXCEPTIONS': 'true'}),
        ),
        refusedWith('manifest_policy_mismatch'),
      );
      // A diversified toolchain expects a v3 token.
      expect(
        () => verify(
          '/bundle',
          'linux',
          policy: expected(<String, String>{
            'SHOREBIRD_SECURITY_PROFILE': 'hardened-diversified',
            'SHOREBIRD_DIVERSIFICATION_PROFILE_ID':
                'sha256:832856d0bed27833434e3f26b65d03cedc313f9850c2577ca7565c4dc644f46d',
          }),
        ),
        refusedWith('manifest_malformed'),
      );
      // Another compiled root (the DEVELOPMENT-ONLY one) does not chain.
      expect(
        () => verify(
          '/bundle',
          'linux',
          policy: expected(<String, String>{
            kShorebirdReleaseRootEnvVar: fixtures.kDevelopmentRootPin,
          }),
        ),
        throwsA(isA<ShorebirdArtifactVerificationException>()),
      );
      // A delegations floor above the bundle is a rollback.
      expect(
        () => verify(
          '/bundle',
          'linux',
          policy: expected(<String, String>{kShorebirdReleaseMinDelegationsVersionEnvVar: '9'}),
        ),
        refusedWith('trust_rollback'),
      );
    });

    test('a bundle without a bundled configuration is refused', () {
      fs.file('/bundle/data/flutter_assets/shorebird.yaml').deleteSync();
      expect(() => verify('/bundle', 'linux'), refusedWith('artifact_no_config'));
      expect(() => verify('/missing', 'linux'), refusedWith('artifact_missing'));
      expect(() => verify('/bundle', 'web'), refusedWith('artifact_unsupported'));
    });
  });

  group('Android app bundle', () {
    late Map<String, List<int>> aab;

    setUp(() {
      final String arm64 = zip('/gradle/arm64_v8a_release.jar', <String, List<int>>{
        'lib/arm64-v8a/libflutter.so': _elf(0xb7),
      });
      final String arm = zip('/gradle/armeabi_v7a_release.jar', <String, List<int>>{
        'lib/armeabi-v7a/libflutter.so': _elf(0xb7, salt: 5),
      });
      final String yaml = signedYaml(
        TargetPlatform.android,
        extra: <String, String>{
          kShorebirdAndroidEngineJarsEnvVar: jsonEncode(<String>[arm64, arm]),
        },
      );
      aab = <String, List<int>>{
        'base/assets/flutter_assets/shorebird.yaml': utf8.encode(yaml),
        'base/lib/arm64-v8a/libflutter.so': _elf(0xb7),
        'base/lib/armeabi-v7a/libflutter.so': _elf(0xb7, salt: 5),
        'base/lib/arm64-v8a/libapp.so': _elf(0xb7, salt: 9),
        'base/manifest/AndroidManifest.xml': utf8.encode('<manifest/>'),
      };
    });

    test('every packaged ABI is bound by the manifest Gradle-measured jars produced', () {
      zip('/out/app-release.aab', aab);
      final ShorebirdArtifactReport report = verify('/out/app-release.aab', 'android');
      expect(
        report.modules.keys,
        unorderedEquals(<(String, String)>[('android', 'aarch64'), ('android', 'arm')]),
      );
      // A split APK carries one ABI.
      zip('/out/app-arm64.apk', <String, List<int>>{
        'assets/flutter_assets/shorebird.yaml': aab['base/assets/flutter_assets/shorebird.yaml']!,
        'lib/arm64-v8a/libflutter.so': _elf(0xb7),
      });
      expect(verify('/out/app-arm64.apk', 'android').modules, hasLength(1));
    });

    test('a library Gradle packaged differently, or an extra ABI, is refused', () {
      zip('/out/stripped.aab', <String, List<int>>{
        ...aab,
        'base/lib/armeabi-v7a/libflutter.so': _elf(0xb7, salt: 6),
      });
      expect(() => verify('/out/stripped.aab', 'android'), refusedWith('module_mismatch'));
      zip('/out/extra.aab', <String, List<int>>{
        ...aab,
        'base/lib/x86_64/libflutter.so': _elf(0x3e),
      });
      expect(() => verify('/out/extra.aab', 'android'), refusedWith('module_unbound'));
      zip('/out/mips.aab', <String, List<int>>{...aab, 'base/lib/mips/libflutter.so': _elf(8)});
      expect(() => verify('/out/mips.aab', 'android'), refusedWith('artifact_unsupported'));
    });
  });

  test('re-verification is only for hardened toolchains', () {
    expect(
      () => ShorebirdExpectedPolicy.fromEnvironment(const <String, String>{}),
      throwsFormatException,
    );
    expect(
      () => ShorebirdExpectedPolicy.fromEnvironment(const <String, String>{
        'SHOREBIRD_SECURITY_PROFILE': 'hardened',
      }),
      throwsFormatException,
    );
  });
}

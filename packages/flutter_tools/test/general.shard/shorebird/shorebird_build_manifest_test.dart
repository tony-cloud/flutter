// Copyright 2026 The Open Shorebird Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:file/memory.dart';
import 'package:flutter_tools/src/artifacts.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/shorebird/shorebird_build_manifest.dart';
import 'package:flutter_tools/src/shorebird/shorebird_ed25519.dart';
import 'package:flutter_tools/src/shorebird/shorebird_yaml.dart';
import 'package:test/test.dart';

List<int> _hex(String hex) => <int>[
  for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
];

String _toHex(List<int> bytes) => bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();

void _put32(Uint8List b, int at, int v) => b.buffer.asByteData().setUint32(at, v, Endian.little);
void _put64(Uint8List b, int at, int v) => b.buffer.asByteData().setUint64(at, v, Endian.little);
void _put16(Uint8List b, int at, int v) => b.buffer.asByteData().setUint16(at, v, Endian.little);

// The synthetic images below mirror updater/library/src/module_measurement.rs
// `tests::{elf64,macho,pe}_fixture`; both implementations pin the same golden
// values, so the build-time and run-time measurements cannot drift apart.
Uint8List _elf64Fixture() {
  final b = Uint8List(0x400);
  b.setRange(0, 4, <int>[0x7f, 0x45, 0x4c, 0x46]);
  b[4] = 2;
  b[5] = 1;
  b[6] = 1;
  _put16(b, 0x10, 3);
  _put64(b, 0x20, 0x40);
  _put16(b, 0x36, 56);
  _put16(b, 0x38, 3);
  const segments = <List<int>>[
    <int>[1, 5, 0x100, 0x1100, 0x80],
    <int>[1, 6, 0x200, 0x2200, 0x40],
    <int>[1, 4, 0x300, 0x3300, 0x20],
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
  for (var i = 0; i < 0x300; i++) {
    b[0x100 + i] = i * 7 % 251;
  }
  return b;
}

Uint8List _machoFixture() {
  final b = Uint8List(0x400);
  _put32(b, 0, 0xfeedfacf);
  _put32(b, 4, 0x0100000c);
  _put32(b, 12, 6);
  _put32(b, 16, 2);
  _put32(b, 20, 2 * 72 + 2 * 80 + 80);
  var at = 32;
  _put32(b, at, 0x19);
  _put32(b, at + 4, 72 + 2 * 80);
  b.setRange(at + 8, at + 14, ascii.encode('__TEXT'));
  _put64(b, at + 24, 0x100000000);
  _put64(b, at + 32, 0x400);
  _put64(b, at + 40, 0);
  _put64(b, at + 48, 0x300);
  _put32(b, at + 56, 5);
  _put32(b, at + 60, 5);
  _put32(b, at + 64, 2);
  final int s = at + 72;
  b.setRange(s, s + 6, ascii.encode('__text'));
  b.setRange(s + 16, s + 22, ascii.encode('__TEXT'));
  _put64(b, s + 32, 0x100000200);
  _put64(b, s + 40, 0x60);
  _put32(b, s + 48, 0x200);
  final int z = s + 80;
  b.setRange(z, z + 6, ascii.encode('__bss0'));
  b.setRange(z + 16, z + 22, ascii.encode('__TEXT'));
  _put64(b, z + 32, 0x100000300);
  _put64(b, z + 40, 0x10);
  _put32(b, z + 64, 1);
  at += 72 + 2 * 80;
  _put32(b, at, 0x19);
  _put32(b, at + 4, 72 + 80);
  b.setRange(at + 8, at + 14, ascii.encode('__DATA'));
  _put64(b, at + 24, 0x100000400);
  _put64(b, at + 40, 0x300);
  _put64(b, at + 48, 0x100);
  _put32(b, at + 60, 3);
  _put32(b, at + 64, 1);
  final int d = at + 72;
  b.setRange(d, d + 6, ascii.encode('__data'));
  b.setRange(d + 16, d + 22, ascii.encode('__DATA'));
  _put64(b, d + 32, 0x100000400);
  _put64(b, d + 40, 0x40);
  _put32(b, d + 48, 0x300);
  for (var i = 0; i < 0x200; i++) {
    b[0x200 + i] = i * 13 % 251;
  }
  return b;
}

Uint8List _peFixture() {
  final b = Uint8List(0x400);
  b[0] = 0x4d;
  b[1] = 0x5a;
  _put32(b, 0x3c, 0x80);
  b.setRange(0x80, 0x84, <int>[0x50, 0x45, 0, 0]);
  _put16(b, 0x84, 0xaa64);
  _put16(b, 0x86, 2);
  _put16(b, 0x94, 0xf0);
  const int table = 0x80 + 24 + 0xf0;
  final sections = <(String, int, int, int, int)>[
    ('.text', 0x1000, 0x80, 0x200, 0x60000020),
    ('.data', 0x2000, 0x40, 0x300, 0xc0000040),
  ];
  for (var i = 0; i < sections.length; i++) {
    final int at = table + i * 40;
    final (String name, int va, int size, int offset, int ch) = sections[i];
    b.setRange(at, at + name.length, ascii.encode(name));
    _put32(b, at + 8, size);
    _put32(b, at + 12, va);
    _put32(b, at + 16, size);
    _put32(b, at + 20, offset);
    _put32(b, at + 36, ch);
  }
  for (var i = 0; i < 0x200; i++) {
    b[0x200 + i] = i * 31 % 251;
  }
  return b;
}

const _elfGolden = 'sha256:f177169245186be8e0fa2e8e6ffb9df70f8dd0824c8f305c06e17f30f63991cd';
const _machoGolden = 'sha256:33a600d96d0444bd5699f78f29c1643dd9e234fa03cbca06d85fc7d424572f60';
const _peGolden = 'sha256:336fbd0090a289316b3d4d5d1801f4d2f41a699217b3d8c3df50ed99bfec927b';

final List<int> _seed = List<int>.filled(32, 7);
const _toolchainId = 'sha256:70229e407e5311401aa3251418eff106467a750ccfcb7e8fe7b61c4442700040';

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

List<int> _unb64url(String value) => base64Url.decode(base64Url.normalize(value));

void main() {
  group('ed25519 signing', () {
    test('matches RFC 8032 test vectors 1 and 2', () {
      final List<int> seed1 = _hex(
        '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60',
      );
      expect(
        _toHex(ed25519PublicKey(seed1)),
        'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a',
      );
      expect(
        _toHex(ed25519Sign(seed1, const <int>[])),
        'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155'
        '5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
      );
      final List<int> seed2 = _hex(
        '4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb',
      );
      expect(
        _toHex(ed25519Sign(seed2, const <int>[0x72])),
        '92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da'
        '085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00',
      );
    });

    test('signatures verify, and a changed message does not', () {
      final List<int> signature = ed25519Sign(_seed, utf8.encode('manifest'));
      expect(ed25519Verify(ed25519PublicKey(_seed), utf8.encode('manifest'), signature), isTrue);
      expect(ed25519Verify(ed25519PublicKey(_seed), utf8.encode('manifesT'), signature), isFalse);
    });

    test('reads only PKCS#8 Ed25519 PEM keys', () {
      expect(parseShorebirdEd25519PrivateKeyPem(_pem(_seed)), _seed);
      for (final bad in <String>[
        '',
        'garbage',
        _pem(_seed).replaceAll('PRIVATE KEY', 'RSA PRIVATE KEY'),
        _pem(List<int>.filled(31, 7)),
        // An X25519 key has a different algorithm OID (1.3.101.110).
        _pem(_seed).replaceFirst(base64.encode(<int>[0x2b, 0x65, 0x70]).substring(0, 2), 'AA'),
      ]) {
        expect(() => parseShorebirdEd25519PrivateKeyPem(bad), throwsFormatException, reason: bad);
      }
    });
  });

  group('module measurement', () {
    test('matches the updater golden values', () {
      expect(measureShorebirdModuleImage(_elf64Fixture()), _elfGolden);
      expect(measureShorebirdModuleImage(_machoFixture()), _machoGolden);
      expect(measureShorebirdModuleImage(_peFixture()), _peGolden);
    });

    test('measures each slice of a universal Mach-O', () {
      final Uint8List thin = _machoFixture();
      final x64 = Uint8List.fromList(thin);
      _put32(x64, 4, 0x01000007);
      x64[0x210] ^= 0x01; // a different __text
      final fat = Uint8List(0x1000 + 0x800);
      final ByteData header = fat.buffer.asByteData();
      header.setUint32(0, 0xcafebabe);
      header.setUint32(4, 2);
      for (final (int i, int cpu, int offset) in <(int, int, int)>[
        (0, 0x0100000c, 0x1000),
        (1, 0x01000007, 0x1400),
      ]) {
        header.setUint32(8 + i * 20, cpu);
        header.setUint32(8 + i * 20 + 8, offset);
        header.setUint32(8 + i * 20 + 12, 0x400);
      }
      fat.setRange(0x1000, 0x1400, thin);
      fat.setRange(0x1400, 0x1800, x64);
      final Map<String, String> slices = measureShorebirdMachOArchitectures(fat);
      expect(slices['aarch64'], _machoGolden);
      expect(slices['x86_64'], measureShorebirdModuleImage(x64));
      expect(slices['x86_64'], isNot(_machoGolden));
    });

    test('refuses malformed images', () {
      expect(() => measureShorebirdModuleImage(Uint8List(16)), throwsFormatException);
      final Uint8List elf = _elf64Fixture();
      _put64(elf, 0x40 + 8, 0x3f0);
      expect(() => measureShorebirdModuleImage(elf), throwsFormatException);
      final Uint8List macho = _machoFixture();
      _put32(macho, 20, 0xffff);
      expect(() => measureShorebirdModuleImage(macho), throwsFormatException);
    });
  });

  group('build manifest', () {
    const config = 'app_id: app\nbase_url: https://updates.example.com\n';
    const modules = <ShorebirdModuleMeasurement>[
      ShorebirdModuleMeasurement('linux', 'x86_64', _elfGolden),
    ];

    String build({
      String text = config,
      TargetPlatform platform = TargetPlatform.linux_x64,
      List<String> android = const <String>[],
      List<String> apple = const <String>[],
    }) => appendShorebirdBuildManifest(
      text,
      signingSeed: _seed,
      toolchainId: _toolchainId,
      developmentExceptions: false,
      modules: modules,
      targetPlatform: platform,
      androidSigningCerts: android,
      appleTeamIds: apple,
    );

    test('is the signed last line and binds every byte before it', () {
      final String output = build();
      expect(output.startsWith(config), isTrue);
      final String line = output.substring(config.length);
      expect(
        line,
        matches(RegExp(r'^shorebird_build_manifest: v1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\n$')),
      );
      final List<String> parts = line.trim().split(' ').last.split('.');
      final List<int> manifestBytes = _unb64url(parts[1]);
      final manifest = jsonDecode(utf8.decode(manifestBytes)) as Map<String, Object?>;
      expect(manifest['config_sha256'], sha256.convert(utf8.encode(config)).toString());
      expect(manifest['toolchain_id'], _toolchainId);
      expect(manifest['signer_key_id'], shorebirdEd25519KeyId(ed25519PublicKey(_seed)));
      expect(manifest['modules'], <Object>[
        <String, String>{'platform': 'linux', 'arch': 'x86_64', 'measurement': _elfGolden},
      ]);
      final List<int> message = utf8.encode(
        'open-shorebird.build-manifest-signature.v1:${sha256.convert(manifestBytes)}',
      );
      expect(ed25519Verify(ed25519PublicKey(_seed), message, _unb64url(parts[2])), isTrue);
      // Deterministic: the same inputs give byte-identical output, so a
      // patch build reproduces the release's shorebird.yaml.
      expect(build(), output);
    });

    test('matches the token the updater verifies', () {
      // updater/library/src/integrity.rs `tests::flutter_tools_output_verifies`
      // pins this exact output and accepts it with the compiled test key.
      expect(build(), _kUpdaterGolden);
    });

    test('declares package identities only where the updater verifies them', () {
      final String cert = 'ab' * 32;
      expect(
        () => build(platform: TargetPlatform.android, android: <String>[cert]),
        returnsNormally,
      );
      expect(
        () => build(platform: TargetPlatform.darwin, apple: const <String>['ABCDE12345']),
        returnsNormally,
      );
      expect(() => build(android: <String>[cert]), throwsFormatException);
      expect(
        () => build(platform: TargetPlatform.ios, apple: const <String>['ABCDE12345']),
        throwsFormatException,
      );
      expect(shorebirdAndroidSigningCerts('AB:${'CD:' * 30}EF, ${'0a' * 32}'), <String>[
        'ab${'cd' * 30}ef',
        '0a' * 32,
      ]);
      expect(() => shorebirdAndroidSigningCerts('abc'), throwsFormatException);
      expect(() => shorebirdAppleTeamIds('abcde12345'), throwsFormatException);
    });

    test('refuses text it cannot bind exactly', () {
      for (final bad in <String>[
        'app_id: app',
        'app_id: app\r\n',
        '${config}shorebird_build_manifest: v1.a.b\n',
      ]) {
        expect(() => build(text: bad), throwsFormatException, reason: bad);
      }
    });
  });

  group('updateShorebirdYaml under hardened', () {
    late MemoryFileSystem fs;
    late Artifacts artifacts;
    Map<String, String> env([Map<String, String> extra = const <String, String>{}]) =>
        <String, String>{
          'SHOREBIRD_SECURITY_PROFILE': 'hardened',
          'SHOREBIRD_TOOLCHAIN_ID': _toolchainId,
          'SHOREBIRD_PUBLIC_KEY': 'pinned-key',
          kShorebirdBuildManifestSigningKeyEnvVar: '/keys/manifest.pem',
          ...extra,
        };

    setUp(() {
      fs = MemoryFileSystem.test();
      artifacts = Artifacts.test(fileSystem: fs);
      fs.file('/keys/manifest.pem')
        ..createSync(recursive: true)
        ..writeAsStringSync(_pem(_seed));
      fs
          .file('/shorebird.yaml')
          .writeAsStringSync('app_id: app\nbase_url: https://updates.example.com\n');
      final String linuxDir = artifacts.getArtifactPath(
        Artifact.linuxDesktopPath,
        platform: TargetPlatform.linux_x64,
        mode: BuildMode.release,
      );
      fs.file(fs.path.join(linuxDir, 'libflutter_linux_gtk.so'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(_elf64Fixture());
    });

    void update(Map<String, String> environment, TargetPlatform platform) => updateShorebirdYaml(
      null,
      '/shorebird.yaml',
      environment: environment,
      fileSystem: fs,
      targetPlatform: platform,
      buildMode: BuildMode.release,
      artifacts: artifacts,
    );

    test('binds the engine module the build packages', () {
      update(env(), TargetPlatform.linux_x64);
      final String text = fs.file('/shorebird.yaml').readAsStringSync();
      final List<String> lines = text.trimRight().split('\n');
      expect(lines.last, startsWith('shorebird_build_manifest: v1.'));
      expect(lines.where((String l) => l.startsWith('shorebird_build_manifest')), hasLength(1));
      final String token = lines.last.split(' ').last;
      final manifest =
          jsonDecode(utf8.decode(_unb64url(token.split('.')[1]))) as Map<String, Object?>;
      expect(manifest['modules'], <Object>[
        <String, String>{'platform': 'linux', 'arch': 'x86_64', 'measurement': _elfGolden},
      ]);
      final int split = text.indexOf('shorebird_build_manifest');
      expect(
        manifest['config_sha256'],
        sha256.convert(utf8.encode(text.substring(0, split))).toString(),
      );
    });

    test('Android binds the signer instead of a module', () {
      update(
        env(<String, String>{kShorebirdAndroidSigningCertEnvVar: 'ab' * 32}),
        TargetPlatform.android,
      );
      final String token = fs.file('/shorebird.yaml').readAsStringSync().trim().split(' ').last;
      final manifest =
          jsonDecode(utf8.decode(_unb64url(token.split('.')[1]))) as Map<String, Object?>;
      expect(manifest['modules'], isEmpty);
      expect(
        (manifest['package_identity']! as Map<String, Object?>)['android_signing_cert_sha256'],
        <String>['ab' * 32],
      );
    });

    test('fails the build without a key, a target or an engine module', () {
      expect(
        () => update(
          env()..remove(kShorebirdBuildManifestSigningKeyEnvVar),
          TargetPlatform.linux_x64,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => update(
          env(<String, String>{kShorebirdBuildManifestSigningKeyEnvVar: '/missing.pem'}),
          TargetPlatform.linux_x64,
        ),
        throwsA(isA<FormatException>()),
      );
      // The Windows engine artifact is absent in this file system.
      expect(() => update(env(), TargetPlatform.windows_x64), throwsA(isA<FormatException>()));
      expect(
        () => updateShorebirdYaml(null, '/shorebird.yaml', environment: env(), fileSystem: fs),
        throwsA(isA<FormatException>()),
      );
    });

    test('legacy output never carries a manifest', () {
      update(<String, String>{
        kShorebirdBuildManifestSigningKeyEnvVar: '/keys/manifest.pem',
      }, TargetPlatform.linux_x64);
      expect(
        fs.file('/shorebird.yaml').readAsStringSync(),
        isNot(contains('shorebird_build_manifest')),
      );
    });

    test('a checked-in manifest key is rejected in every profile', () {
      fs.file('/shorebird.yaml').writeAsStringSync('app_id: app\nshorebird_build_manifest: x\n');
      expect(() => update(const <String, String>{}, TargetPlatform.linux_x64), throwsA(anything));
      expect(() => update(env(), TargetPlatform.linux_x64), throwsA(anything));
    });
  });
}

const _kUpdaterGolden =
    'app_id: app\nbase_url: https://updates.example.com\n'
    'shorebird_build_manifest: '
    'v1.eyJzY2hlbWEiOiJvcGVuLXNob3JlYmlyZC5idWlsZC1tYW5pZmVzdCIsImNvbnRyYWN0X3ZlcnNpb24iOjEsInNlY3VyaXR5X3Byb2ZpbGUiOiJoYXJkZW5lZCIsInRvb2xjaGFpbl9pZCI6InNoYTI1Njo3MDIyOWU0MDdlNTMxMTQwMWFhMzI1MTQxOGVmZjEwNjQ2N2E3NTBjY2ZjYjdlOGZlN2I2MWM0NDQyNzAwMDQwIiwiZGV2ZWxvcG1lbnRfZXhjZXB0aW9ucyI6ZmFsc2UsInNpZ25lcl9rZXlfaWQiOiJzaGEyNTY6ZmU4MTJjMTJmM2FiNGNlNmFjNWRiNjlhYzM1MmY5MDZjYjFiMTFlZjQzZmIzM2UyNTJlZjdmZjU1MjI2Mzg4OSIsImNvbmZpZ19zaGEyNTYiOiIwODRjOGQ2NTQyODRjMGZjZjkyZWQ5ZTgxNDE0YTE1ZGQxOTUzMjYxMmU2MzAxZDllMTg0ZTRlMGU2MjQyNmM0IiwibW9kdWxlcyI6W3sicGxhdGZvcm0iOiJsaW51eCIsImFyY2giOiJ4ODZfNjQiLCJtZWFzdXJlbWVudCI6InNoYTI1NjpmMTc3MTY5MjQ1MTg2YmU4ZTBmYTJlOGU2ZmZiOWRmNzBmOGRkMDgyNGM4ZjMwNWMwNmUxN2YzMGY2Mzk5MWNkIn1dLCJwYWNrYWdlX2lkZW50aXR5Ijp7ImFuZHJvaWRfc2lnbmluZ19jZXJ0X3NoYTI1NiI6W10sImFwcGxlX3RlYW1faWRzIjpbXX19.ZYBT71bqRnbCzQ61c36AO41gM27qCV_JTwJcMh0GCw8USHsg9wTsefmPQ3bbnZZQl96YEtgUZhIyUOLpi0xcCw\n';

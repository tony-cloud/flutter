// Copyright 2026 The Open Shorebird Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:flutter_tools/src/artifacts.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/shorebird/shorebird_build_manifest.dart';
import 'package:flutter_tools/src/shorebird/shorebird_ed25519.dart';
import 'package:flutter_tools/src/shorebird/shorebird_release_trust.dart';
import 'package:flutter_tools/src/shorebird/shorebird_yaml.dart';
import 'package:test/test.dart';

import 'shorebird_release_trust_fixtures.dart' as fixtures;

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

/// The DEVELOPMENT-ONLY diversification profile ID
/// (`scripts/testdata/diversification/profile.DEVELOPMENT-ONLY.json`).
const _profileId = 'sha256:832856d0bed27833434e3f26b65d03cedc313f9850c2577ca7565c4dc644f46d';

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

ShorebirdReleaseTrust _developmentTrust() => verifyShorebirdReleaseTrust(
  utf8.encode(fixtures.kDevelopmentBundle),
  pinnedRoot: base64.decode(fixtures.kDevelopmentRootPin),
);

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
      String? profileId,
    }) => appendShorebirdBuildManifest(
      text,
      signer: ShorebirdSeedManifestSigner(_seed),
      trust: _developmentTrust(),
      toolchainId: _toolchainId,
      developmentExceptions: false,
      modules: modules,
      targetPlatform: platform,
      androidSigningCerts: android,
      appleTeamIds: apple,
      diversificationProfileId: profileId,
    );

    test('is the signed last line and binds every byte before it', () {
      final String output = build();
      expect(output.startsWith(config), isTrue);
      final String line = output.substring(config.length);
      expect(
        line,
        matches(
          RegExp(
            r'^shorebird_build_manifest: v2\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\n$',
          ),
        ),
      );
      final List<String> parts = line.trim().split(' ').last.split('.');
      final List<int> manifestBytes = _unb64url(parts[1]);
      final manifest = jsonDecode(utf8.decode(manifestBytes)) as Map<String, Object?>;
      expect(manifest['config_sha256'], sha256.convert(utf8.encode(config)).toString());
      expect(manifest['toolchain_id'], _toolchainId);
      expect(manifest['signer_key_id'], shorebirdEd25519KeyId(ed25519PublicKey(_seed)));
      expect(manifest['contract_version'], 2);
      expect(manifest['delegations_sha256'], _developmentTrust().delegationsSha256);
      // The last segment is the release-trust bundle, canonical JSON.
      expect(utf8.decode(_unb64url(parts[3])), fixtures.kDevelopmentBundle);
      expect(manifest['modules'], <Object>[
        <String, String>{'platform': 'linux', 'arch': 'x86_64', 'measurement': _elfGolden},
      ]);
      final List<int> message = utf8.encode(
        'open-shorebird.build-manifest-signature.v2:${sha256.convert(manifestBytes)}',
      );
      expect(ed25519Verify(ed25519PublicKey(_seed), message, _unb64url(parts[2])), isTrue);
      // Deterministic: the same inputs give byte-identical output, so a
      // patch build reproduces the release's shorebird.yaml.
      expect(build(), output);
    });

    test('matches the token the updater verifies', () {
      // updater/library/src/integrity.rs `tests::flutter_tools_output_verifies`
      // pins this exact output and accepts it under the compiled
      // DEVELOPMENT-ONLY release root.
      expect(build(), _kUpdaterGolden);
    });

    test('hardened-diversified writes a v3 token that binds the profile', () {
      final String output = build(profileId: _profileId);
      final String line = output.substring(config.length);
      expect(line, startsWith('shorebird_build_manifest: v3.'));
      final List<String> parts = line.trim().split(' ').last.split('.');
      expect(parts, hasLength(4));
      final List<int> manifestBytes = _unb64url(parts[1]);
      final manifest = jsonDecode(utf8.decode(manifestBytes)) as Map<String, Object?>;
      expect(manifest['contract_version'], 3);
      expect(manifest['security_profile'], 'hardened-diversified');
      expect(manifest['diversification_profile_id'], _profileId);
      expect(manifest['toolchain_id'], _toolchainId);
      // The signature domain is unchanged (contract §11.6).
      final List<int> message = utf8.encode(
        'open-shorebird.build-manifest-signature.v2:${sha256.convert(manifestBytes)}',
      );
      expect(ed25519Verify(ed25519PublicKey(_seed), message, _unb64url(parts[2])), isTrue);
      expect(build(profileId: _profileId), output);
      // Without a profile, the v2 output is unchanged.
      expect(build(), _kUpdaterGolden);
      for (final bad in <String>['', 'sha256:${'AB' * 32}', 'cd' * 32]) {
        expect(() => build(profileId: bad), throwsFormatException, reason: bad);
      }
    });

    test('matches the v3 token the updater verifies', () {
      // updater/library/src/integrity.rs
      // `tests::flutter_tools_v3_output_verifies` pins this exact output and
      // accepts it under a hardened-diversified updater compiled with the
      // DEVELOPMENT-ONLY release root and diversification profile.
      expect(build(profileId: _profileId), _kUpdaterV3Golden);
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
    // Inside every fixture validity window.
    DateTime clock() => DateTime.utc(2027, 3);
    Map<String, String> env([Map<String, String> extra = const <String, String>{}]) =>
        <String, String>{
          'SHOREBIRD_SECURITY_PROFILE': 'hardened',
          'SHOREBIRD_TOOLCHAIN_ID': _toolchainId,
          'SHOREBIRD_PUBLIC_KEY': 'pinned-key',
          kShorebirdBuildManifestSigningKeyEnvVar: '/keys/manifest.pem',
          kShorebirdReleaseTrustEnvVar: '/keys/release-trust.json',
          kShorebirdReleaseRootEnvVar: base64.encode(utf8.encode(fixtures.operatorRoot)),
          ...extra,
        };

    void writeTrust(String bundle) => fs.file('/keys/release-trust.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(bundle);

    setUp(() {
      fs = MemoryFileSystem.test();
      artifacts = Artifacts.test(fileSystem: fs);
      fs.file('/keys/manifest.pem')
        ..createSync(recursive: true)
        ..writeAsStringSync(_pem(_seed));
      writeTrust(fixtures.operatorBundle());
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

    void update(
      Map<String, String> environment,
      TargetPlatform platform, {
      String Function(List<String> argv)? runSigner,
      DateTime Function()? at,
    }) => updateShorebirdYaml(
      null,
      '/shorebird.yaml',
      environment: environment,
      fileSystem: fs,
      targetPlatform: platform,
      buildMode: BuildMode.release,
      artifacts: artifacts,
      runSigner: runSigner,
      clock: at ?? clock,
    );

    Map<String, Object?> manifestOf(String text) {
      final String token = text.trimRight().split('\n').last.split(' ').last;
      return jsonDecode(utf8.decode(_unb64url(token.split('.')[1]))) as Map<String, Object?>;
    }

    Matcher refusedWith(String text) => throwsA(
      isA<FormatException>().having((FormatException e) => e.message, 'message', contains(text)),
    );

    test('binds the engine module the build packages', () {
      update(env(), TargetPlatform.linux_x64);
      final String text = fs.file('/shorebird.yaml').readAsStringSync();
      final List<String> lines = text.trimRight().split('\n');
      expect(lines.last, startsWith('shorebird_build_manifest: v2.'));
      expect(lines.where((String l) => l.startsWith('shorebird_build_manifest')), hasLength(1));
      expect(text, contains('security_contract_version: 2\n'));
      final Map<String, Object?> manifest = manifestOf(text);
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
      final Map<String, Object?> manifest = manifestOf(
        fs.file('/shorebird.yaml').readAsStringSync(),
      );
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
        refusedWith('exactly one build-manifest signer'),
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

    test('requires a release-trust bundle that chains to the compiled root', () {
      for (final name in <String>[kShorebirdReleaseTrustEnvVar, kShorebirdReleaseRootEnvVar]) {
        expect(
          () => update(env()..remove(name), TargetPlatform.linux_x64),
          refusedWith(kShorebirdReleaseTrustEnvVar),
          reason: name,
        );
      }
      // Another root than the engine compiled.
      expect(
        () => update(
          env(<String, String>{
            kShorebirdReleaseRootEnvVar: base64.encode(
              utf8.encode(fixtures.rootPayload(1, <List<int>>[fixtures.strangerSeed])),
            ),
          }),
          TargetPlatform.linux_x64,
        ),
        refusedWith('trust_unverified'),
      );
      // Delegations below the compiled floor.
      expect(
        () => update(
          env(<String, String>{kShorebirdReleaseMinDelegationsVersionEnvVar: '2'}),
          TargetPlatform.linux_x64,
        ),
        refusedWith('trust_rollback'),
      );
      for (final bad in <String>['0', '-1', 'x', '01']) {
        expect(
          () => update(
            env(<String, String>{kShorebirdReleaseMinDelegationsVersionEnvVar: bad}),
            TargetPlatform.linux_x64,
          ),
          refusedWith(kShorebirdReleaseMinDelegationsVersionEnvVar),
          reason: bad,
        );
      }
    });

    test('refuses a signer the delegations do not authorize now', () {
      // Wrong key ID: a key no role names.
      fs.file('/keys/manifest.pem').writeAsStringSync(_pem(fixtures.strangerSeed));
      expect(
        () => update(env(), TargetPlatform.linux_x64),
        refusedWith('manifest_untrusted_signer'),
      );
      // Role confusion: the artifact-catalog key, or the root key itself.
      for (final seed in <List<int>>[fixtures.catalogSeed, fixtures.nextRootSeed]) {
        fs.file('/keys/manifest.pem').writeAsStringSync(_pem(seed));
        expect(() => update(env(), TargetPlatform.linux_x64), refusedWith('manifest_signer_role'));
      }
      // Revoked: delegations v2 rotate to [8]*32 and revoke [7]*32.
      fs.file('/keys/manifest.pem').writeAsStringSync(_pem(_seed));
      writeTrust(
        fixtures.operatorBundle(
          version: 2,
          manifest: <List<int>>[fixtures.nextManifestSeed],
          revoked: <String>[fixtures.keyId(_seed)],
        ),
      );
      expect(() => update(env(), TargetPlatform.linux_x64), refusedWith('manifest_signer_revoked'));
      // Rotated out: the new key signs.
      fs.file('/keys/manifest.pem').writeAsStringSync(_pem(fixtures.nextManifestSeed));
      update(env(), TargetPlatform.linux_x64);
      // Outside the key's validity window, and after the delegations expire.
      writeTrust(fixtures.operatorBundle(notBefore: '2028-01-01T00:00:00Z'));
      fs.file('/keys/manifest.pem').writeAsStringSync(_pem(_seed));
      fs
          .file('/shorebird.yaml')
          .writeAsStringSync('app_id: app\nbase_url: https://updates.example.com\n');
      expect(() => update(env(), TargetPlatform.linux_x64), refusedWith('signer_outside_window'));
      writeTrust(fixtures.operatorBundle());
      expect(
        () => update(env(), TargetPlatform.linux_x64, at: () => DateTime.utc(2037)),
        refusedWith('trust_expired'),
      );
    });

    test('the DEVELOPMENT-ONLY root needs a development build', () {
      writeTrust(fixtures.kDevelopmentBundle);
      final Map<String, String> development = env(<String, String>{
        kShorebirdReleaseRootEnvVar: fixtures.kDevelopmentRootPin,
      });
      expect(() => update(development, TargetPlatform.linux_x64), refusedWith('DEVELOPMENT-ONLY'));
      update(<String, String>{
        ...development,
        'SHOREBIRD_SECURITY_DEVELOPMENT_EXCEPTIONS': 'true',
      }, TargetPlatform.linux_x64);
      expect(
        manifestOf(fs.file('/shorebird.yaml').readAsStringSync())['development_exceptions'],
        isTrue,
      );
    });

    test('an external KMS/HSM signer signs without the key in process', () {
      final argvs = <List<String>>[];
      final Map<String, String> external = env(<String, String>{
        kShorebirdBuildManifestSignerEnvVar: '/opt/kms-signer',
        kShorebirdBuildManifestSignerKeyIdEnvVar: fixtures.keyId(_seed),
      })..remove(kShorebirdBuildManifestSigningKeyEnvVar);
      update(
        external,
        TargetPlatform.linux_x64,
        runSigner: (List<String> argv) {
          argvs.add(argv);
          // The adapter holds the key; it signs exactly the message given.
          return '${base64.encode(ed25519Sign(_seed, utf8.encode(argv.last)))}\n';
        },
      );
      expect(argvs, hasLength(1));
      expect(argvs.single.sublist(0, 4), <String>[
        '/opt/kms-signer',
        'sign',
        '--key-id',
        fixtures.keyId(_seed),
      ]);
      expect(argvs.single[4], '--message');
      expect(argvs.single[5], startsWith('open-shorebird.build-manifest-signature.v2:'));
      // The same output as the in-process signer: signing is deterministic.
      final String viaKms = fs.file('/shorebird.yaml').readAsStringSync();
      fs
          .file('/shorebird.yaml')
          .writeAsStringSync('app_id: app\nbase_url: https://updates.example.com\n');
      update(env(), TargetPlatform.linux_x64);
      expect(fs.file('/shorebird.yaml').readAsStringSync(), viaKms);
    });

    test('an external signer is checked before its output is used', () {
      Map<String, String> external(String keyId) => env(<String, String>{
        kShorebirdBuildManifestSignerEnvVar: '/opt/kms-signer',
        kShorebirdBuildManifestSignerKeyIdEnvVar: keyId,
      })..remove(kShorebirdBuildManifestSigningKeyEnvVar);
      // Both signers, or no key ID.
      expect(
        () => update(
          env(<String, String>{kShorebirdBuildManifestSignerEnvVar: '/opt/kms-signer'}),
          TargetPlatform.linux_x64,
        ),
        refusedWith('exactly one build-manifest signer'),
      );
      expect(
        () => update(external(''), TargetPlatform.linux_x64),
        refusedWith(kShorebirdBuildManifestSignerKeyIdEnvVar),
      );
      // A signer that answers with another key's signature, or garbage.
      expect(
        () => update(
          external(fixtures.keyId(_seed)),
          TargetPlatform.linux_x64,
          runSigner: (List<String> argv) =>
              base64.encode(ed25519Sign(fixtures.strangerSeed, utf8.encode(argv.last))),
        ),
        refusedWith('does not verify'),
      );
      expect(
        () => update(
          external(fixtures.keyId(_seed)),
          TargetPlatform.linux_x64,
          runSigner: (List<String> argv) => 'not a signature',
        ),
        refusedWith('did not print'),
      );
      // A KMS key that the delegations give another role.
      expect(
        () => update(
          external(fixtures.keyId(fixtures.catalogSeed)),
          TargetPlatform.linux_x64,
          runSigner: (List<String> argv) => fail('must not be asked to sign'),
        ),
        refusedWith('manifest_signer_role'),
      );
    });

    test('writes the release record the CLI stores with the release', () {
      update(
        env(<String, String>{kShorebirdBuildManifestRecordDirEnvVar: '/records'}),
        TargetPlatform.linux_x64,
      );
      final List<File> files = fs.directory('/records').listSync().whereType<File>().toList();
      expect(files, hasLength(1));
      final record = jsonDecode(files.single.readAsStringSync()) as Map<String, Object?>;
      final String text = fs.file('/shorebird.yaml').readAsStringSync();
      final String token = text.trimRight().split('\n').last.split(' ').last;
      final List<int> manifestBytes = _unb64url(token.split('.')[1]);
      expect(record['schema'], 'open-shorebird.release-record');
      expect(record['contract_version'], 2);
      expect(record['toolchain_id'], _toolchainId);
      expect(
        record['release_root_sha256'],
        'sha256:${sha256.convert(utf8.encode(fixtures.operatorRoot))}',
      );
      expect(record['delegations_version'], 1);
      final manifests = record['build_manifests']! as List<Object?>;
      expect(
        (manifests.single! as Map<String, Object?>)['manifest_sha256'],
        sha256.convert(manifestBytes).toString(),
      );
      expect(files.single.basename, 'build-manifest-${sha256.convert(manifestBytes)}.json');
    });

    test('hardened-diversified writes the v3 manifest and a release-record.v3', () {
      final operatorProfileId = 'sha256:${'cd' * 32}';
      update(
        env(<String, String>{
          'SHOREBIRD_SECURITY_PROFILE': 'hardened-diversified',
          'SHOREBIRD_DIVERSIFICATION_PROFILE_ID': operatorProfileId,
          kShorebirdBuildManifestRecordDirEnvVar: '/records',
        }),
        TargetPlatform.linux_x64,
      );
      final String text = fs.file('/shorebird.yaml').readAsStringSync();
      expect(text, contains('security_profile: hardened-diversified\n'));
      expect(text, contains('security_contract_version: 3\n'));
      expect(text, contains('diversification_profile_id: $operatorProfileId\n'));
      expect(text.trimRight().split('\n').last, startsWith('shorebird_build_manifest: v3.'));
      final Map<String, Object?> manifest = manifestOf(text);
      expect(manifest['contract_version'], 3);
      expect(manifest['security_profile'], 'hardened-diversified');
      expect(manifest['diversification_profile_id'], operatorProfileId);
      final File record = fs.directory('/records').listSync().whereType<File>().single;
      final decoded = jsonDecode(record.readAsStringSync()) as Map<String, Object?>;
      expect(decoded['contract_version'], 3);
      expect(decoded['security_profile'], 'hardened-diversified');
      expect(decoded['diversification_profile_id'], operatorProfileId);
      expect(decoded['toolchain_id'], _toolchainId);
      // The release root rules are those of hardened.
      fs
          .file('/shorebird.yaml')
          .writeAsStringSync('app_id: app\nbase_url: https://updates.example.com\n');
      expect(
        () => update(
          env(<String, String>{
            'SHOREBIRD_SECURITY_PROFILE': 'hardened-diversified',
            'SHOREBIRD_DIVERSIFICATION_PROFILE_ID': operatorProfileId,
          })..remove(kShorebirdReleaseTrustEnvVar),
          TargetPlatform.linux_x64,
        ),
        refusedWith(kShorebirdReleaseTrustEnvVar),
      );
      // The DEVELOPMENT-ONLY profile needs a development build.
      expect(
        () => update(
          env(<String, String>{
            'SHOREBIRD_SECURITY_PROFILE': 'hardened-diversified',
            'SHOREBIRD_DIVERSIFICATION_PROFILE_ID': _profileId,
          }),
          TargetPlatform.linux_x64,
        ),
        refusedWith('DEVELOPMENT-ONLY'),
      );
    });

    test('a hardened release record stays release-record.v2', () {
      update(
        env(<String, String>{kShorebirdBuildManifestRecordDirEnvVar: '/records'}),
        TargetPlatform.linux_x64,
      );
      final File record = fs.directory('/records').listSync().whereType<File>().single;
      final decoded = jsonDecode(record.readAsStringSync()) as Map<String, Object?>;
      expect(decoded['contract_version'], 2);
      expect(decoded['security_profile'], 'hardened');
      expect(decoded.containsKey('diversification_profile_id'), isFalse);
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
      for (final key in <String>['shorebird_build_manifest', 'diversification_profile_id']) {
        fs.file('/shorebird.yaml').writeAsStringSync('app_id: app\n$key: x\n');
        expect(() => update(const <String, String>{}, TargetPlatform.linux_x64), throwsA(anything));
        expect(() => update(env(), TargetPlatform.linux_x64), throwsA(anything));
        expect(
          () => update(
            env(<String, String>{
              'SHOREBIRD_SECURITY_PROFILE': 'hardened-diversified',
              'SHOREBIRD_DIVERSIFICATION_PROFILE_ID': 'sha256:${'cd' * 32}',
            }),
            TargetPlatform.linux_x64,
          ),
          throwsA(anything),
        );
      }
    });
  });
}

const _kUpdaterGolden =
    'app_id: app\nbase_url: https://updates.example.com\n'
    'shorebird_build_manifest: '
    'v2.eyJzY2hlbWEiOiJvcGVuLXNob3JlYmlyZC5idWlsZC1tYW5pZmVzdCIsImNvbnRyYWN0X3ZlcnNpb24iOjIsInNlY3VyaXR5X3Byb2ZpbGUiOiJoYXJkZW5lZCIsInRvb2xjaGFpbl9pZCI6InNoYTI1Njo3MDIyOWU0MDdlNTMxMTQwMWFhMzI1MTQxOGVmZjEwNjQ2N2E3NTBjY2ZjYjdlOGZlN2I2MWM0NDQyNzAwMDQwIiwiZGV2ZWxvcG1lbnRfZXhjZXB0aW9ucyI6ZmFsc2UsInNpZ25lcl9rZXlfaWQiOiJzaGEyNTY6ZmU4MTJjMTJmM2FiNGNlNmFjNWRiNjlhYzM1MmY5MDZjYjFiMTFlZjQzZmIzM2UyNTJlZjdmZjU1MjI2Mzg4OSIsImRlbGVnYXRpb25zX3NoYTI1NiI6Ijc5YTYwNGZmOTFkNjhhYWRjYmQxMmM0ZmE0YTNlNDJjNWRjZTJiNGQ5Y2U3MWExZWYyMmRjMzk3N2NiOTk0ZGYiLCJjb25maWdfc2hhMjU2IjoiMDg0YzhkNjU0Mjg0YzBmY2Y5MmVkOWU4MTQxNGExNWRkMTk1MzI2MTJlNjMwMWQ5ZTE4NGU0ZTBlNjI0MjZjNCIsIm1vZHVsZXMiOlt7InBsYXRmb3JtIjoibGludXgiLCJhcmNoIjoieDg2XzY0IiwibWVhc3VyZW1lbnQiOiJzaGEyNTY6ZjE3NzE2OTI0NTE4NmJlOGUwZmEyZThlNmZmYjlkZjcwZjhkZDA4MjRjOGYzMDVjMDZlMTdmMzBmNjM5OTFjZCJ9XSwicGFja2FnZV9pZGVudGl0eSI6eyJhbmRyb2lkX3NpZ25pbmdfY2VydF9zaGEyNTYiOltdLCJhcHBsZV90ZWFtX2lkcyI6W119fQ.HK-FpA4qt5auJPBUoqhL0ixlBNl5kabAz_RW80B_ZLjc1anfgGMyzGNmAZAJyF8NCCeQurW91yB1aw6bxa2wCw.eyJjb250cmFjdF92ZXJzaW9uIjoyLCJkZWxlZ2F0aW9ucyI6eyJwYXlsb2FkIjoiZXlKamIyNTBjbUZqZEY5MlpYSnphVzl1SWpveUxDSmxlSEJwY21WelgyRjBJam9pTWpBek5pMHhNUzB3TVZRd01Eb3dNRG93TUZvaUxDSnBjM04xWldSZllYUWlPaUl5TURJMkxURXhMVEF4VkRBd09qQXdPakF3V2lJc0luSmxkbTlyWldSZmEyVjVYMmxrY3lJNlcxMHNJbkp2YkdWeklqcDdJbUZ5ZEdsbVlXTjBMV05oZEdGc2IyY2lPbHQ3SW10bGVWOXBaQ0k2SW5Ob1lUSTFOam80Tm1RME5tVXdPV1E1TW1JME1UTXhNREJpWWpZMVl6Rm1NRGs0TWpNMVpXUXlNMlJrWWpnMFpUQTRNV0kxTnpSak1qQmlaVEV4WkRFMVptUTJOVGcwSWl3aWJtOTBYMkZtZEdWeUlqb2lNakF6TmkweE1TMHdNVlF3TURvd01Eb3dNRm9pTENKdWIzUmZZbVZtYjNKbElqb2lNakF5TmkweE1TMHdNVlF3TURvd01Eb3dNRm9pTENKd2RXSnNhV05mYTJWNUlqb2lWblp6ZEVkMkwydGlNemxZTm5JelJqUjZWSEJZYUV0a1IyMTNVMEZHYTFkQ09YbzRMMUpyVVZoMGJ6MGlmVjBzSW1KMWFXeGtMVzFoYm1sbVpYTjBJanBiZXlKclpYbGZhV1FpT2lKemFHRXlOVFk2Wm1VNE1USmpNVEptTTJGaU5HTmxObUZqTldSaU5qbGhZek0xTW1ZNU1EWmpZakZpTVRGbFpqUXpabUl6TTJVeU5USmxaamRtWmpVMU1qSTJNemc0T1NJc0ltNXZkRjloWm5SbGNpSTZJakl3TXpZdE1URXRNREZVTURBNk1EQTZNREJhSWl3aWJtOTBYMkpsWm05eVpTSTZJakl3TWpZdE1URXRNREZVTURBNk1EQTZNREJhSWl3aWNIVmliR2xqWDJ0bGVTSTZJalpyY0hOWkswdGpWV2R4S3psV1FqZEZlVGRHSzFwV1NHUnhOaXQyYm5WVFVXZzNjV0ZTVWtjd2FYYzlJbjFkZlN3aWNtOXZkRjkyWlhKemFXOXVJam94TENKelkyaGxiV0VpT2lKdmNHVnVMWE5vYjNKbFltbHlaQzV5Wld4bFlYTmxMV1JsYkdWbllYUnBiMjV6SWl3aWRtVnljMmx2YmlJNk1YMD0iLCJzaWduYXR1cmVzIjpbeyJrZXlfaWQiOiJzaGEyNTY6MzQ3NTBmOThiZDU5ZmNmYzk0NmRhNDVhYWFiZTkzM2JlMTU0YTRiNTA5NGUxYzRhYmY0Mjg2NjUwNWYzYzk3ZSIsInNpZ25hdHVyZSI6ImI2NzQ1cFFFS2k4WHR4cHg3VzM5NlZqb1pWUWUxUXRNcUthWlJWeFJJcVJobk85NldnUngrK1lxdzFZeE1NR05XZEZYNlhwVnlDQkpQOGtjbEt3WUJBPT0ifV19LCJyb290X2NoYWluIjpbeyJwYXlsb2FkIjoiZXlKamIyNTBjbUZqZEY5MlpYSnphVzl1SWpveUxDSmxlSEJwY21WelgyRjBJam9pTWpBek5pMHhNUzB3T1ZRd01Eb3dNRG93TUZvaUxDSnJaWGx6SWpwYmV5SnJaWGxmYVdRaU9pSnphR0V5TlRZNk16UTNOVEJtT1RoaVpEVTVabU5tWXprME5tUmhORFZoWVdGaVpUa3pNMkpsTVRVMFlUUmlOVEE1TkdVeFl6UmhZbVkwTWpnMk5qVXdOV1l6WXprM1pTSXNJbkIxWW14cFkxOXJaWGtpT2lKcGIycHFNMWhSU2poYVdEbFZkSE4wVUV4d1pHTnpjRzVEWWpoa2JFSkpZamd6VTBsQllsRlFZakYzUFNKOVhTd2ljMk5vWlcxaElqb2liM0JsYmkxemFHOXlaV0pwY21RdWNtVnNaV0Z6WlMxeWIyOTBJaXdpZEdoeVpYTm9iMnhrSWpveExDSjJaWEp6YVc5dUlqb3hmUT09Iiwic2lnbmF0dXJlcyI6W3sia2V5X2lkIjoic2hhMjU2OjM0NzUwZjk4YmQ1OWZjZmM5NDZkYTQ1YWFhYmU5MzNiZTE1NGE0YjUwOTRlMWM0YWJmNDI4NjY1MDVmM2M5N2UiLCJzaWduYXR1cmUiOiJENE5KdWpSL3NZZHNHYWw4VS96VjhFUVY4ck1lZlc4UUR2NnNYdUMvVEd0Lys2YnArZGlpVS9VMjBwYit1VWEyaGxwaVZDTGxtcU1wb29UL2FycldEZz09In1dfV0sInNjaGVtYSI6Im9wZW4tc2hvcmViaXJkLnJlbGVhc2UtdHJ1c3QifQ\n';

const _kUpdaterV3Golden =
    'app_id: app\nbase_url: https://updates.example.com\n'
    'shorebird_build_manifest: '
    'v3.eyJzY2hlbWEiOiJvcGVuLXNob3JlYmlyZC5idWlsZC1tYW5pZmVzdCIsImNvbnRyYWN0X3ZlcnNpb24iOjMsInNlY3VyaXR5X3Byb2ZpbGUiOiJoYXJkZW5lZC1kaXZlcnNpZmllZCIsInRvb2xjaGFpbl9pZCI6InNoYTI1Njo3MDIyOWU0MDdlNTMxMTQwMWFhMzI1MTQxOGVmZjEwNjQ2N2E3NTBjY2ZjYjdlOGZlN2I2MWM0NDQyNzAwMDQwIiwiZGV2ZWxvcG1lbnRfZXhjZXB0aW9ucyI6ZmFsc2UsImRpdmVyc2lmaWNhdGlvbl9wcm9maWxlX2lkIjoic2hhMjU2OjgzMjg1NmQwYmVkMjc4MzM0MzRlM2YyNmI2NWQwM2NlZGMzMTNmOTg1MGMyNTc3Y2E3NTY1YzRkYzY0NGY0NmQiLCJzaWduZXJfa2V5X2lkIjoic2hhMjU2OmZlODEyYzEyZjNhYjRjZTZhYzVkYjY5YWMzNTJmOTA2Y2IxYjExZWY0M2ZiMzNlMjUyZWY3ZmY1NTIyNjM4ODkiLCJkZWxlZ2F0aW9uc19zaGEyNTYiOiI3OWE2MDRmZjkxZDY4YWFkY2JkMTJjNGZhNGEzZTQyYzVkY2UyYjRkOWNlNzFhMWVmMjJkYzM5NzdjYjk5NGRmIiwiY29uZmlnX3NoYTI1NiI6IjA4NGM4ZDY1NDI4NGMwZmNmOTJlZDllODE0MTRhMTVkZDE5NTMyNjEyZTYzMDFkOWUxODRlNGUwZTYyNDI2YzQiLCJtb2R1bGVzIjpbeyJwbGF0Zm9ybSI6ImxpbnV4IiwiYXJjaCI6Ing4Nl82NCIsIm1lYXN1cmVtZW50Ijoic2hhMjU2OmYxNzcxNjkyNDUxODZiZThlMGZhMmU4ZTZmZmI5ZGY3MGY4ZGQwODI0YzhmMzA1YzA2ZTE3ZjMwZjYzOTkxY2QifV0sInBhY2thZ2VfaWRlbnRpdHkiOnsiYW5kcm9pZF9zaWduaW5nX2NlcnRfc2hhMjU2IjpbXSwiYXBwbGVfdGVhbV9pZHMiOltdfX0.7ENISJNDkATY08LKzMmG06cTNqDolWt8yE7q516TfjdapJmY-H0tlhT2s5JekK5N0vRyUuyHVF_FjJZb7JDBAw.eyJjb250cmFjdF92ZXJzaW9uIjoyLCJkZWxlZ2F0aW9ucyI6eyJwYXlsb2FkIjoiZXlKamIyNTBjbUZqZEY5MlpYSnphVzl1SWpveUxDSmxlSEJwY21WelgyRjBJam9pTWpBek5pMHhNUzB3TVZRd01Eb3dNRG93TUZvaUxDSnBjM04xWldSZllYUWlPaUl5TURJMkxURXhMVEF4VkRBd09qQXdPakF3V2lJc0luSmxkbTlyWldSZmEyVjVYMmxrY3lJNlcxMHNJbkp2YkdWeklqcDdJbUZ5ZEdsbVlXTjBMV05oZEdGc2IyY2lPbHQ3SW10bGVWOXBaQ0k2SW5Ob1lUSTFOam80Tm1RME5tVXdPV1E1TW1JME1UTXhNREJpWWpZMVl6Rm1NRGs0TWpNMVpXUXlNMlJrWWpnMFpUQTRNV0kxTnpSak1qQmlaVEV4WkRFMVptUTJOVGcwSWl3aWJtOTBYMkZtZEdWeUlqb2lNakF6TmkweE1TMHdNVlF3TURvd01Eb3dNRm9pTENKdWIzUmZZbVZtYjNKbElqb2lNakF5TmkweE1TMHdNVlF3TURvd01Eb3dNRm9pTENKd2RXSnNhV05mYTJWNUlqb2lWblp6ZEVkMkwydGlNemxZTm5JelJqUjZWSEJZYUV0a1IyMTNVMEZHYTFkQ09YbzRMMUpyVVZoMGJ6MGlmVjBzSW1KMWFXeGtMVzFoYm1sbVpYTjBJanBiZXlKclpYbGZhV1FpT2lKemFHRXlOVFk2Wm1VNE1USmpNVEptTTJGaU5HTmxObUZqTldSaU5qbGhZek0xTW1ZNU1EWmpZakZpTVRGbFpqUXpabUl6TTJVeU5USmxaamRtWmpVMU1qSTJNemc0T1NJc0ltNXZkRjloWm5SbGNpSTZJakl3TXpZdE1URXRNREZVTURBNk1EQTZNREJhSWl3aWJtOTBYMkpsWm05eVpTSTZJakl3TWpZdE1URXRNREZVTURBNk1EQTZNREJhSWl3aWNIVmliR2xqWDJ0bGVTSTZJalpyY0hOWkswdGpWV2R4S3psV1FqZEZlVGRHSzFwV1NHUnhOaXQyYm5WVFVXZzNjV0ZTVWtjd2FYYzlJbjFkZlN3aWNtOXZkRjkyWlhKemFXOXVJam94TENKelkyaGxiV0VpT2lKdmNHVnVMWE5vYjNKbFltbHlaQzV5Wld4bFlYTmxMV1JsYkdWbllYUnBiMjV6SWl3aWRtVnljMmx2YmlJNk1YMD0iLCJzaWduYXR1cmVzIjpbeyJrZXlfaWQiOiJzaGEyNTY6MzQ3NTBmOThiZDU5ZmNmYzk0NmRhNDVhYWFiZTkzM2JlMTU0YTRiNTA5NGUxYzRhYmY0Mjg2NjUwNWYzYzk3ZSIsInNpZ25hdHVyZSI6ImI2NzQ1cFFFS2k4WHR4cHg3VzM5NlZqb1pWUWUxUXRNcUthWlJWeFJJcVJobk85NldnUngrK1lxdzFZeE1NR05XZEZYNlhwVnlDQkpQOGtjbEt3WUJBPT0ifV19LCJyb290X2NoYWluIjpbeyJwYXlsb2FkIjoiZXlKamIyNTBjbUZqZEY5MlpYSnphVzl1SWpveUxDSmxlSEJwY21WelgyRjBJam9pTWpBek5pMHhNUzB3T1ZRd01Eb3dNRG93TUZvaUxDSnJaWGx6SWpwYmV5SnJaWGxmYVdRaU9pSnphR0V5TlRZNk16UTNOVEJtT1RoaVpEVTVabU5tWXprME5tUmhORFZoWVdGaVpUa3pNMkpsTVRVMFlUUmlOVEE1TkdVeFl6UmhZbVkwTWpnMk5qVXdOV1l6WXprM1pTSXNJbkIxWW14cFkxOXJaWGtpT2lKcGIycHFNMWhSU2poYVdEbFZkSE4wVUV4d1pHTnpjRzVEWWpoa2JFSkpZamd6VTBsQllsRlFZakYzUFNKOVhTd2ljMk5vWlcxaElqb2liM0JsYmkxemFHOXlaV0pwY21RdWNtVnNaV0Z6WlMxeWIyOTBJaXdpZEdoeVpYTm9iMnhrSWpveExDSjJaWEp6YVc5dUlqb3hmUT09Iiwic2lnbmF0dXJlcyI6W3sia2V5X2lkIjoic2hhMjU2OjM0NzUwZjk4YmQ1OWZjZmM5NDZkYTQ1YWFhYmU5MzNiZTE1NGE0YjUwOTRlMWM0YWJmNDI4NjY1MDVmM2M5N2UiLCJzaWduYXR1cmUiOiJENE5KdWpSL3NZZHNHYWw4VS96VjhFUVY4ck1lZlc4UUR2NnNYdUMvVEd0Lys2YnArZGlpVS9VMjBwYit1VWEyaGxwaVZDTGxtcU1wb29UL2FycldEZz09In1dfV0sInNjaGVtYSI6Im9wZW4tc2hvcmViaXJkLnJlbGVhc2UtdHJ1c3QifQ\n';

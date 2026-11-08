// Copyright 2026 The Open Shorebird Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:file/local.dart' as local_fs;
import 'package:file/memory.dart';
import 'package:file_testing/file_testing.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/io.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/shorebird/shorebird_artifact_catalog.dart';
import 'package:flutter_tools/src/shorebird/shorebird_artifact_origins.dart';
import 'package:flutter_tools/src/shorebird/shorebird_ed25519.dart';
import 'package:flutter_tools/src/shorebird/shorebird_release_trust.dart';

import '../../src/common.dart';
import '../../src/fake_http_client.dart';
import '../../src/fakes.dart';
import 'shorebird_artifact_catalog_fixtures.dart';
import 'shorebird_release_trust_fixtures.dart' as release_trust;

/// The test-only production catalog key of [kFixtureTrust].
const _kProductionCatalogKey = 'zZztknZglq/ihnRvhFj3arnd3YDtvz52y8fHWQ/gCww=';

/// A release-trust bundle under the operator test root that delegates the
/// test production catalog key for the given roles.
String _catalogBundle({
  bool asCatalog = true,
  bool asManifest = false,
  bool revoke = false,
  int version = 1,
}) => release_trust.bundle(
  const <Map<String, Object?>>[],
  release_trust.envelope(
    kShorebirdReleaseDelegationsSignatureDomain,
    release_trust.delegationsPayload(
      version,
      1,
      manifest: <List<int>>[release_trust.manifestSeed],
      catalogPublicKeys: <String>[if (asCatalog) _kProductionCatalogKey],
      manifestPublicKeys: <String>[if (asManifest) _kProductionCatalogKey],
      revoked: <String>[if (revoke) shorebirdReleaseKeyId(base64.decode(_kProductionCatalogKey))],
    ),
    <List<int>>[release_trust.nextRootSeed],
  ),
);

ShorebirdReleaseTrust _catalogTrust([String? bundle]) => verifyShorebirdReleaseTrust(
  utf8.encode(bundle ?? _catalogBundle()),
  pinnedRoot: utf8.encode(release_trust.operatorRoot),
);

List<int> _hex(String hex) => <int>[
  for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
];

List<int> _bytes(String text) => utf8.encode(text);

const _flutterRoot = '/flutter';
const _frameworkRoute =
    r'flutter_infra_release/flutter/$engine/darwin-arm64-release/FlutterMacOS.framework.zip';

void main() {
  group('ed25519Verify', () {
    // RFC 8032 section 7.1, TEST 1-3.
    const vectors = <(String, String, String)>[
      (
        'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a',
        '',
        'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
      ),
      (
        '3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c',
        '72',
        '92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00',
      ),
      (
        'fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025',
        'af82',
        '6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a',
      ),
    ];

    test('accepts the RFC 8032 vectors', () {
      for (final (String key, String message, String signature) in vectors) {
        expect(ed25519Verify(_hex(key), _hex(message), _hex(signature)), isTrue);
      }
    });

    test('rejects a modified message, signature or key', () {
      final (String key, String message, String signature) = vectors[2];
      expect(ed25519Verify(_hex(key), <int>[..._hex(message), 0], _hex(signature)), isFalse);
      final List<int> flipped = _hex(signature)..[63] ^= 1;
      expect(ed25519Verify(_hex(key), _hex(message), flipped), isFalse);
      expect(ed25519Verify(_hex(vectors[0].$1), _hex(message), _hex(signature)), isFalse);
    });

    test('rejects S >= L and non-canonical points', () {
      final (String key, String message, String signature) = vectors[0];
      final List<int> sig = _hex(signature);
      // Add L to S (little-endian): the same group element, not canonical.
      final BigInt l = (BigInt.one << 252) + BigInt.parse('27742317777372353535851937790883648493');
      BigInt s = BigInt.zero;
      for (var i = 63; i >= 32; i--) {
        s = (s << 8) | BigInt.from(sig[i]);
      }
      s += l;
      for (var i = 32; i < 64; i++) {
        sig[i] = (s & BigInt.from(0xff)).toInt();
        s >>= 8;
      }
      expect(ed25519Verify(_hex(key), _hex(message), sig), isFalse);
      final notAPoint = List<int>.filled(32, 0xff);
      expect(ed25519Verify(notAPoint, _hex(message), _hex(signature)), isFalse);
    });
  });

  group('verifyShorebirdArtifactCatalog', () {
    (ShorebirdArtifactCatalog, ShorebirdCatalogTrust) verify(
      String catalog,
      String? signature, {
      String profile = 'legacy',
      String engine = kFixtureEngine,
      bool allowUnsigned = false,
      String trust = kFixtureTrust,
      ShorebirdReleaseTrust? releaseTrust,
    }) => verifyShorebirdArtifactCatalog(
      catalogBytes: _bytes(catalog),
      signatureBytes: signature == null ? null : _bytes(signature),
      trustBytes: _bytes(trust),
      securityProfile: profile,
      engineRevision: engine,
      allowUnsigned: allowUnsigned,
      releaseTrust: releaseTrust ?? (profile == 'hardened' ? _catalogTrust() : null),
    );

    Matcher rejects(String reason) => throwsA(
      isA<ShorebirdCatalogException>().having((e) => e.message, 'message', contains(reason)),
    );

    test('a production signature is accepted in both profiles', () {
      final (ShorebirdArtifactCatalog catalog, ShorebirdCatalogTrust trust) = verify(
        kLegacyCatalog,
        kLegacyProdSignature,
      );
      expect(trust, ShorebirdCatalogTrust.production);
      expect(catalog.upstreamEngineRevision, kFixtureUpstream);
      expect(catalog.artifacts[_frameworkRoute]!.custom, isTrue);
      expect(
        verify(kHardenedCatalog, kHardenedProdSignature, profile: 'hardened').$2,
        ShorebirdCatalogTrust.production,
      );
    });

    test('hardened: the signer must be the release root artifact-catalog delegate', () {
      ShorebirdReleaseTrust? none;
      expect(
        () => verifyShorebirdArtifactCatalog(
          catalogBytes: _bytes(kHardenedCatalog),
          signatureBytes: _bytes(kHardenedProdSignature),
          trustBytes: _bytes(kFixtureTrust),
          securityProfile: 'hardened',
          engineRevision: kFixtureEngine,
          releaseTrust: none,
        ),
        rejects('under the release root'),
      );
      for (final (String bundle, String code) in <(String, String)>[
        // Not delegated at all, delegated as a build-manifest key (role
        // confusion), and revoked.
        (_catalogBundle(asCatalog: false), 'manifest_untrusted_signer'),
        (_catalogBundle(asCatalog: false, asManifest: true), 'manifest_signer_role'),
        (_catalogBundle(asCatalog: false, revoke: true, version: 2), 'manifest_signer_revoked'),
      ]) {
        expect(
          () => verify(
            kHardenedCatalog,
            kHardenedProdSignature,
            profile: 'hardened',
            releaseTrust: _catalogTrust(bundle),
          ),
          rejects(code),
          reason: code,
        );
      }
      // Legacy is unchanged: no release trust is consulted.
      expect(verify(kLegacyCatalog, kLegacyProdSignature).$2, ShorebirdCatalogTrust.production);
    });

    test('a development key is legacy-only', () {
      expect(verify(kLegacyCatalog, kLegacyDevSignature).$2, ShorebirdCatalogTrust.development);
      expect(
        () => verify(kHardenedCatalog, kHardenedDevSignature, profile: 'hardened'),
        rejects('rejects a catalog signed by a development key'),
      );
    });

    test('an unsigned catalog needs the explicit override and never passes hardened', () {
      expect(
        () => verify(kLegacyCatalog, null),
        rejects('SHOREBIRD_ALLOW_UNSIGNED_ARTIFACT_CATALOG'),
      );
      expect(verify(kLegacyCatalog, null, allowUnsigned: true).$2, ShorebirdCatalogTrust.unsigned);
      expect(
        () => verify(kHardenedCatalog, null, profile: 'hardened', allowUnsigned: true),
        rejects('a hardened toolchain requires a production signature'),
      );
      expect(
        () => verify(kLegacyCatalog, kLegacyProdSignature, profile: 'hardened'),
        rejects('a hardened toolchain requires a hardened catalog'),
      );
    });

    test('a modified catalog or signature is rejected', () {
      final String tampered = kLegacyCatalog.replaceFirst('"size":16', '"size":17');
      expect(tampered, isNot(kLegacyCatalog));
      expect(() => verify(tampered, kLegacyProdSignature), rejects('different catalog digest'));
      final envelope = json.decode(kLegacyProdSignature) as Map<String, Object?>;
      envelope['catalog_sha256'] = sha256.convert(_bytes(tampered)).toString();
      expect(
        () => verify(tampered, shorebirdCanonicalJson(envelope)),
        rejects('signature does not verify'),
      );
    });

    test('non-canonical bytes and duplicate keys are rejected', () {
      final String pretty = const JsonEncoder.withIndent(' ').convert(json.decode(kLegacyCatalog));
      expect(() => verify(pretty, kLegacyProdSignature), rejects('not in canonical JSON form'));
      final String duplicate = kLegacyCatalog.replaceFirst(
        '{"artifacts":',
        '{"schema":"x","artifacts":',
      );
      expect(() => verify(duplicate, kLegacyProdSignature), rejects('not in canonical JSON form'));
    });

    test('a key outside the trust document is rejected', () {
      final trust = json.decode(kFixtureTrust) as Map<String, Object?>;
      (trust['keys']! as List<Object?>).removeLast();
      expect(
        () => verify(kLegacyCatalog, kLegacyProdSignature, trust: json.encode(trust)),
        rejects('untrusted key'),
      );
    });

    test('a catalog for another engine is rejected', () {
      expect(
        () => verify(kLegacyCatalog, kLegacyProdSignature, engine: 'f' * 40),
        rejects('not this toolchain engine'),
      );
    });

    test('an official artifact never satisfies a custom route', () {
      final catalog = json.decode(kLegacyCatalog) as Map<String, Object?>;
      final artifact = (catalog['artifacts']! as List<Object?>).first! as Map<String, Object?>;
      artifact
        ..['class'] = 'official-unchanged'
        ..['origin'] = 'flutter-official'
        ..['revision'] = kFixtureUpstream;
      expect(
        () => ShorebirdArtifactCatalog.parse(_bytes(shorebirdCanonicalJson(catalog))),
        throwsA(
          isA<ShorebirdCatalogException>().having(
            (e) => e.message,
            'message',
            contains('an official artifact must never satisfy it'),
          ),
        ),
      );
    });

    test('unknown fields and the reserved profile are rejected', () {
      final catalog = json.decode(kLegacyCatalog) as Map<String, Object?>;
      catalog['extra'] = 1;
      expect(
        () => ShorebirdArtifactCatalog.parse(_bytes(shorebirdCanonicalJson(catalog))),
        throwsA(isA<ShorebirdCatalogException>()),
      );
      catalog
        ..remove('extra')
        ..['security_profile'] = 'hardened-diversified';
      expect(
        () => ShorebirdArtifactCatalog.parse(_bytes(shorebirdCanonicalJson(catalog))),
        throwsA(isA<ShorebirdCatalogException>()),
      );
    });

    test('the shipped trust document pins only the development key', () {
      const FileSystem fs = local_fs.LocalFileSystem();
      final File shipped = fs.file(
        fs.path.join(
          fs.currentDirectory.path,
          '..',
          '..',
          'bin',
          'internal',
          'shorebird_artifact_trust.json',
        ),
      );
      final shippedKeys =
          (json.decode(shipped.readAsStringSync()) as Map<String, Object?>)['keys']!
              as List<Object?>;
      expect(shippedKeys, hasLength(1));
      expect((shippedKeys.single! as Map<String, Object?>)['usage'], 'development');
      final fixture = json.decode(kFixtureTrust) as Map<String, Object?>;
      final fixtureKeys = (fixture['keys']! as List<Object?>)..removeLast();
      expect(json.encode(fixtureKeys), json.encode(shippedKeys));
    });
  });

  group('ShorebirdArtifactOrigins', () {
    ShorebirdArtifactOrigins resolve(Map<String, String> env) =>
        ShorebirdArtifactOrigins.fromEnvironment(env);
    Matcher conflict(String reason) => throwsA(
      isA<ShorebirdOriginException>().having((e) => e.message, 'message', contains(reason)),
    );

    test('defaults: split, official origin direct, operator store for custom', () {
      final ShorebirdArtifactOrigins origins = resolve(<String, String>{});
      expect(origins.mode, ShorebirdOriginMode.split);
      expect(origins.officialBaseUrl, 'https://storage.googleapis.com');
      expect(origins.artifactStoreUrl, 'http://localhost:8080/artifacts');
    });

    test('FLUTTER_STORAGE_BASE_URL scopes official artifacts only; PUB_HOSTED_URL is ignored', () {
      final ShorebirdArtifactOrigins origins = resolve(<String, String>{
        'FLUTTER_STORAGE_BASE_URL': 'https://mirror.example/',
        'SHOREBIRD_ARTIFACT_BASE_URL': 'https://store.example/',
        'PUB_HOSTED_URL': 'https://pub.example',
      });
      expect(origins.mode, ShorebirdOriginMode.split);
      expect(origins.officialBaseUrl, 'https://mirror.example');
      expect(origins.artifactStoreUrl, 'https://store.example');
    });

    test('legacy aliases select one all-in-one mirror', () {
      for (final name in <String>[
        'SHOREBIRD_DOWNLOAD_URL',
        'SHOREBIRD_FLUTTER_STORAGE_BASE_URL',
        'FLUTTER_STORAGE_BASE_URL',
      ]) {
        final ShorebirdArtifactOrigins origins = resolve(<String, String>{
          name: 'http://localhost:8080/download.flutter.io',
        });
        expect(origins.mode, ShorebirdOriginMode.legacyMirror, reason: name);
        expect(origins.officialBaseUrl, 'http://localhost:8080/download.flutter.io');
      }
      expect(
        resolve(<String, String>{'SHOREBIRD_ORIGIN_MODE': 'legacy-mirror'}).mirrorUrl,
        'http://localhost:8080/download.flutter.io',
      );
    });

    test('conflicting overrides are errors', () {
      expect(
        () => resolve(<String, String>{
          'SHOREBIRD_DOWNLOAD_URL': 'https://a.example',
          'SHOREBIRD_FLUTTER_STORAGE_BASE_URL': 'https://b.example',
        }),
        conflict('Conflicting artifact mirror overrides'),
      );
      expect(
        () => resolve(<String, String>{
          'SHOREBIRD_ORIGIN_MODE': 'split',
          'SHOREBIRD_DOWNLOAD_URL': 'https://a.example',
        }),
        conflict('SHOREBIRD_ORIGIN_MODE=split conflicts'),
      );
      expect(
        () => resolve(<String, String>{
          'SHOREBIRD_DOWNLOAD_URL': 'https://a.example',
          'FLUTTER_STORAGE_BASE_URL': 'https://storage.googleapis.com',
        }),
        conflict('Conflicting artifact origins'),
      );
      expect(
        () => resolve(<String, String>{'SHOREBIRD_ORIGIN_MODE': 'everything'}),
        conflict('Unknown SHOREBIRD_ORIGIN_MODE'),
      );
    });
  });

  group('shorebirdGradleEnvironment', () {
    test('split mode keeps Gradle on the compatibility Maven route', () {
      expect(
        shorebirdGradleEnvironment(
          <String, String>{'JAVA_HOME': '/jdk'},
          <String, String>{'FLUTTER_STORAGE_BASE_URL': 'https://storage.googleapis.com'},
        ),
        <String, String>{
          'JAVA_HOME': '/jdk',
          'FLUTTER_STORAGE_BASE_URL': 'http://localhost:8080/download.flutter.io',
        },
      );
      expect(
        shorebirdGradleEnvironment(null, <String, String>{
          'SHOREBIRD_MAVEN_BASE_URL': 'https://maven.example/',
        }),
        <String, String>{'FLUTTER_STORAGE_BASE_URL': 'https://maven.example'},
      );
    });

    test('legacy-mirror mode leaves Gradle unchanged', () {
      final env = <String, String>{'JAVA_HOME': '/jdk'};
      expect(
        shorebirdGradleEnvironment(env, <String, String>{
          'SHOREBIRD_DOWNLOAD_URL': 'https://proxy.example',
        }),
        same(env),
      );
    });
  });

  group('ShorebirdArtifactResolver', () {
    late MemoryFileSystem fileSystem;
    late List<String> warnings;
    late List<Uri> fetched;

    setUp(() {
      fileSystem = MemoryFileSystem.test();
      fileSystem.file('$_flutterRoot/bin/internal/shorebird_artifact_trust.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(kFixtureTrust);
      warnings = <String>[];
      fetched = <Uri>[];
    });

    ShorebirdArtifactResolver resolver(Map<String, String> env) => ShorebirdArtifactResolver(
      environment: env,
      fileSystem: fileSystem,
      flutterRoot: _flutterRoot,
      engineRevision: () => kFixtureEngine,
      warn: warnings.add,
    );

    ShorebirdFetch serving(String? catalog, String? signature, {Object? error}) => (Uri url) async {
      fetched.add(url);
      if (error != null) {
        throw Exception(error);
      }
      final body = url.path.endsWith('.sig') ? signature : catalog;
      return body == null ? null : _bytes(body);
    };

    Uri engineUrl(String base, String path) =>
        Uri.parse('$base/flutter_infra_release/flutter/$kFixtureEngine/$path');

    test('custom routes resolve to the custom store with the catalog digest', () async {
      final ShorebirdResolvedDownload resolved =
          (await resolver(<String, String>{
            'SHOREBIRD_ARTIFACT_BASE_URL': 'https://store.example',
          }).resolve(
            engineUrl(
              'https://storage.googleapis.com',
              'darwin-arm64-release/FlutterMacOS.framework.zip',
            ),
            serving(kLegacyCatalog, kLegacyProdSignature),
          ))!;
      expect(
        resolved.url.toString(),
        'https://store.example/shorebird/flutter_infra_release/flutter/$kFixtureEngine/darwin-arm64-release/FlutterMacOS.framework.zip',
      );
      expect(resolved.custom, isTrue);
      expect(resolved.sha256, sha256.convert(_bytes('custom-framework')).toString());
      expect(
        fetched.first.toString(),
        'https://store.example/shorebird/$kFixtureEngine/artifact-catalog.v1.json',
      );
      expect(warnings, isEmpty);
    });

    test(
      'official routes go directly to FLUTTER_STORAGE_BASE_URL at the upstream revision',
      () async {
        final ShorebirdArtifactResolver r = resolver(<String, String>{
          'FLUTTER_STORAGE_BASE_URL': 'https://mirror.example',
        });
        final ShorebirdFetch fetch = serving(kLegacyCatalog, kLegacyProdSignature);
        final ShorebirdResolvedDownload pinned = (await r.resolve(
          engineUrl('https://mirror.example', 'sky_engine.zip'),
          fetch,
        ))!;
        expect(
          pinned.url.toString(),
          'https://mirror.example/flutter_infra_release/flutter/$kFixtureUpstream/sky_engine.zip',
        );
        expect(pinned.sha256, sha256.convert(_bytes('sky')).toString());
        final ShorebirdResolvedDownload unpinned = (await r.resolve(
          engineUrl('https://mirror.example', 'flutter_gpu.zip'),
          fetch,
        ))!;
        expect(unpinned.url.toString(), contains('/$kFixtureUpstream/flutter_gpu.zip'));
        expect(unpinned.sha256, isNull);
        expect(
          await r.resolve(
            Uri.parse('https://mirror.example/flutter_infra_release/flutter/fonts/1/fonts.zip'),
            fetch,
          ),
          isNull,
        );
      },
    );

    test('a custom route missing from the catalog is a precise error', () async {
      await expectLater(
        resolver(<String, String>{}).resolve(
          engineUrl('https://storage.googleapis.com', 'linux-arm64-release/artifacts.zip'),
          serving(kLegacyCatalog, kLegacyProdSignature),
        ),
        throwsA(
          isA<ShorebirdOriginException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains(r'Missing custom artifact'),
              contains(r'linux-arm64-release/artifacts.zip'),
              contains('a stock Flutter artifact cannot replace'),
            ),
          ),
        ),
      );
    });

    test(
      'no published catalog, or an unreachable store without a cache, is a precise error',
      () async {
        final Uri url = engineUrl('https://storage.googleapis.com', 'sky_engine.zip');
        await expectLater(
          resolver(<String, String>{}).resolve(url, serving(null, null)),
          throwsA(
            isA<ShorebirdOriginException>().having(
              (e) => e.message,
              'message',
              contains('HTTP 404'),
            ),
          ),
        );
        await expectLater(
          resolver(
            <String, String>{},
          ).resolve(url, serving(null, null, error: 'connection refused')),
          throwsA(
            isA<ShorebirdOriginException>().having(
              (e) => e.message,
              'message',
              contains('Could not fetch the signed artifact catalog'),
            ),
          ),
        );
      },
    );

    test('a verified catalog is cached and reused offline', () async {
      final Uri url = engineUrl('https://storage.googleapis.com', 'sky_engine.zip');
      await resolver(
        <String, String>{},
      ).resolve(url, serving(kLegacyCatalog, kLegacyProdSignature));
      expect(
        fileSystem.file(
          '$_flutterRoot/bin/cache/shorebird/artifact-catalog/$kFixtureEngine/artifact-catalog.v1.json',
        ),
        exists,
      );
      final ShorebirdResolvedDownload offline = (await resolver(
        <String, String>{},
      ).resolve(url, serving(null, null, error: 'offline')))!;
      expect(offline.sha256, isNotNull);
      expect(warnings.single, contains('using the cached verified artifact catalog'));
    });

    test('a tampered catalog from the store is refused, not replaced by the cache', () async {
      final Uri url = engineUrl('https://storage.googleapis.com', 'sky_engine.zip');
      await resolver(
        <String, String>{},
      ).resolve(url, serving(kLegacyCatalog, kLegacyProdSignature));
      await expectLater(
        resolver(<String, String>{}).resolve(
          url,
          serving(kLegacyCatalog.replaceFirst('"size":3', '"size":4'), kLegacyProdSignature),
        ),
        throwsA(
          isA<ShorebirdOriginException>().having(
            (e) => e.message,
            'message',
            contains('Refusing the artifact catalog'),
          ),
        ),
      );
    });

    test('hardened resolves only with the release trust of the toolchain', () async {
      final Uri url = engineUrl('https://storage.googleapis.com', 'sky_engine.zip');
      final hardened = <String, String>{'SHOREBIRD_SECURITY_PROFILE': 'hardened'};
      await expectLater(
        resolver(hardened).resolve(url, serving(kHardenedCatalog, kHardenedProdSignature)),
        throwsA(
          isA<ShorebirdOriginException>().having(
            (e) => e.message,
            'message',
            contains(kShorebirdReleaseTrustEnvVar),
          ),
        ),
      );
      fileSystem.file('/release-trust.json').writeAsStringSync(_catalogBundle());
      final ShorebirdResolvedDownload resolved = (await resolver(<String, String>{
        ...hardened,
        kShorebirdReleaseTrustEnvVar: '/release-trust.json',
        kShorebirdReleaseRootEnvVar: base64.encode(utf8.encode(release_trust.operatorRoot)),
      }).resolve(url, serving(kHardenedCatalog, kHardenedProdSignature)))!;
      expect(resolved.sha256, isNotNull);
    });

    test('development-signed catalogs warn loudly; hardened refuses them', () async {
      final Uri url = engineUrl('https://storage.googleapis.com', 'sky_engine.zip');
      await resolver(<String, String>{}).resolve(url, serving(kLegacyCatalog, kLegacyDevSignature));
      expect(warnings.single, contains('development-signed'));
      await expectLater(
        resolver(<String, String>{
          'SHOREBIRD_SECURITY_PROFILE': 'hardened',
        }).resolve(url, serving(kHardenedCatalog, kHardenedDevSignature)),
        throwsA(isA<ShorebirdOriginException>()),
      );
    });

    test('an explicit SHOREBIRD_ARTIFACT_CATALOG needs no network', () async {
      fileSystem.file('/catalog.json').writeAsStringSync(kLegacyCatalog);
      fileSystem.file('/catalog.json.sig').writeAsStringSync(kLegacyProdSignature);
      final ShorebirdResolvedDownload resolved =
          (await resolver(<String, String>{'SHOREBIRD_ARTIFACT_CATALOG': '/catalog.json'}).resolve(
            engineUrl('https://storage.googleapis.com', 'sky_engine.zip'),
            serving(null, null, error: 'no network expected'),
          ))!;
      expect(resolved.sha256, isNotNull);
      expect(fetched, isEmpty);
    });

    test('legacy-mirror mode leaves URLs to the artifact proxy', () async {
      expect(
        await resolver(<String, String>{
          'SHOREBIRD_DOWNLOAD_URL': 'http://localhost:8080/download.flutter.io',
        }).resolve(
          engineUrl('http://localhost:8080/download.flutter.io', 'sky_engine.zip'),
          serving(null, null, error: 'no network expected'),
        ),
        isNull,
      );
      expect(fetched, isEmpty);
    });
  });

  group('ArtifactUpdater with the Shorebird resolver', () {
    late MemoryFileSystem fileSystem;
    late BufferLogger logger;

    setUp(() {
      fileSystem = MemoryFileSystem.test();
      logger = BufferLogger.test();
      fileSystem.file('$_flutterRoot/bin/internal/shorebird_artifact_trust.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(kFixtureTrust);
      fileSystem.file('/catalog.json').writeAsStringSync(kLegacyCatalog);
      fileSystem.file('/catalog.json.sig').writeAsStringSync(kLegacyProdSignature);
    });

    ArtifactUpdater updater(FakeHttpClient client) => ArtifactUpdater(
      fileSystem: fileSystem,
      logger: logger,
      operatingSystemUtils: FakeOperatingSystemUtils(),
      platform: FakePlatform(),
      httpClient: client,
      tempStorage: fileSystem.currentDirectory.childDirectory('temp')..createSync(),
      allowedBaseUrls: <String>['https://storage.googleapis.com'],
      shorebirdResolver: ShorebirdArtifactResolver(
        environment: <String, String>{
          'SHOREBIRD_ARTIFACT_CATALOG': '/catalog.json',
          'SHOREBIRD_ARTIFACT_BASE_URL': 'https://store.example',
        },
        fileSystem: fileSystem,
        flutterRoot: _flutterRoot,
        engineRevision: () => kFixtureEngine,
        warn: (String message) {},
      ),
    );

    final Uri requested = Uri.parse(
      'https://storage.googleapis.com/flutter_infra_release/flutter/$kFixtureEngine/darwin-arm64-release/FlutterMacOS.framework.zip',
    );
    final Uri custom = Uri.parse(
      'https://store.example/shorebird/flutter_infra_release/flutter/$kFixtureEngine/darwin-arm64-release/FlutterMacOS.framework.zip',
    );

    testWithoutContext('downloads a custom artifact from the store and verifies it', () async {
      final ArtifactUpdater artifactUpdater = updater(
        FakeHttpClient.list(<FakeRequest>[
          FakeRequest(custom, response: FakeResponse(body: _bytes('custom-framework'))),
        ]),
      );
      await artifactUpdater.downloadZipArchive(
        'framework',
        requested,
        fileSystem.directory('/out'),
      );
      expect(artifactUpdater.downloadedFiles.single.readAsStringSync(), 'custom-framework');
      expect(logger.errorText, isEmpty);
    });

    testWithoutContext('refuses bytes that do not match the catalog before unpacking', () async {
      await expectLater(
        updater(
          FakeHttpClient.list(<FakeRequest>[
            FakeRequest(custom, response: FakeResponse(body: _bytes('stock-framework!'))),
          ]),
        ).downloadZipArchive('framework', requested, fileSystem.directory('/out')),
        throwsToolExit(message: 'does not match the signed artifact catalog'),
      );
      expect(fileSystem.directory('/out/FlutterMacOS.framework'), isNot(exists));
    });

    testWithoutContext(
      'a catalog-listed custom artifact missing from the store is precise',
      () async {
        await expectLater(
          updater(
            FakeHttpClient.list(<FakeRequest>[
              FakeRequest(custom, response: const FakeResponse(statusCode: HttpStatus.notFound)),
            ]),
          ).downloadZipArchive('framework', requested, fileSystem.directory('/out')),
          throwsToolExit(message: 'Missing custom artifact'),
        );
      },
    );
  });
}

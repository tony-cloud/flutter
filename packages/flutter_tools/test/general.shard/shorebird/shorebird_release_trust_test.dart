// Copyright 2026 The Open Shorebird Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_tools/src/shorebird/shorebird_ed25519.dart';
import 'package:flutter_tools/src/shorebird/shorebird_release_trust.dart';
import 'package:test/test.dart';

import 'shorebird_release_trust_fixtures.dart';

ShorebirdReleaseTrust _verify(String bundle, {String? root, int minimum = 1}) =>
    verifyShorebirdReleaseTrust(
      utf8.encode(bundle),
      pinnedRoot: utf8.encode(root ?? rootPayload(1, <List<int>>[rootSeed])),
      minDelegationsVersion: minimum,
    );

String _defaultDelegations() => delegationsPayload(
  1,
  1,
  manifest: <List<int>>[manifestSeed],
  catalog: <List<int>>[catalogSeed],
);

String _signed(String delegations, [List<List<int>>? signers]) => bundle(
  const <Map<String, Object?>>[],
  envelope(
    kShorebirdReleaseDelegationsSignatureDomain,
    delegations,
    signers ?? <List<int>>[rootSeed],
  ),
);

Matcher _refused(String code) => throwsA(
  isA<ShorebirdReleaseTrustException>().having(
    (ShorebirdReleaseTrustException e) => e.code,
    'code',
    code,
  ),
);

void main() {
  test('the Python reference bundle verifies under its pinned root', () {
    final ShorebirdReleaseTrust trust = verifyShorebirdReleaseTrust(
      utf8.encode(kDevelopmentBundle),
      pinnedRoot: base64.decode(kDevelopmentRootPin),
    );
    expect(utf8.decode(base64.decode(kDevelopmentRootPin)), rootPayload(1, <List<int>>[rootSeed]));
    expect(trust.development, isTrue);
    expect(trust.rootVersion, 1);
    // The value release_trust.rs `PYTHON_DELEGATIONS_SHA256` pins.
    expect(
      trust.delegationsSha256,
      '79a604ff91d68aadcbd12c4fa4a3e42c5dce2b4d9ce71a1ef22dc3977cb994df',
    );
    expect(trust.compactBundle, kDevelopmentBundle);
    expect(trust.roleKey(ShorebirdSigningRole.buildManifest, keyId(manifestSeed)), isNotEmpty);
    // The repository's artifact-catalog development key is delegated for
    // that role only.
    const catalogKey = 'sha256:86d46e09d92b413100bb65c1f098235ed23ddb84e081b574c20be11d15fd6584';
    expect(trust.roleKey(ShorebirdSigningRole.artifactCatalog, catalogKey), isNotEmpty);
    expect(
      () => trust.roleKey(ShorebirdSigningRole.buildManifest, catalogKey),
      _refused('manifest_signer_role'),
    );
  });

  test('an operator root is not a development root', () {
    final ShorebirdReleaseTrust trust = _verify(operatorBundle(), root: operatorRoot);
    expect(trust.development, isFalse);
    expect(trust.rootSha256, 'sha256:${sha256.convert(utf8.encode(operatorRoot))}');
  });

  test('role confusion, unknown, revoked and rotated-out keys are refused', () {
    final ShorebirdReleaseTrust trust = _verify(_signed(_defaultDelegations()));
    for (final confused in <List<int>>[catalogSeed, rootSeed]) {
      expect(
        () => trust.roleKey(ShorebirdSigningRole.buildManifest, keyId(confused)),
        _refused('manifest_signer_role'),
      );
    }
    expect(
      () => trust.roleKey(ShorebirdSigningRole.buildManifest, keyId(strangerSeed)),
      _refused('manifest_untrusted_signer'),
    );
    final ShorebirdReleaseTrust rotated = _verify(
      _signed(
        delegationsPayload(
          2,
          1,
          manifest: <List<int>>[nextManifestSeed],
          revoked: <String>[keyId(manifestSeed)],
        ),
      ),
      minimum: 2,
    );
    expect(
      () => rotated.roleKey(ShorebirdSigningRole.buildManifest, keyId(manifestSeed)),
      _refused('manifest_signer_revoked'),
    );
    expect(
      rotated.roleKey(ShorebirdSigningRole.buildManifest, keyId(nextManifestSeed)),
      isNotEmpty,
    );
    // The old delegations under a raised floor.
    expect(() => _verify(_signed(_defaultDelegations()), minimum: 2), _refused('trust_rollback'));
  });

  test('delegations must be signed by a threshold of the root', () {
    for (final signers in <List<List<int>>>[
      <List<int>>[manifestSeed],
      <List<int>>[strangerSeed],
    ]) {
      expect(() => _verify(_signed(_defaultDelegations(), signers)), _refused('trust_unverified'));
    }
    // A root-domain signature over delegations bytes is not accepted.
    expect(
      () => _verify(
        bundle(
          const <Map<String, Object?>>[],
          envelope(kShorebirdReleaseRootSignatureDomain, _defaultDelegations(), <List<int>>[
            rootSeed,
          ]),
        ),
      ),
      _refused('trust_unverified'),
    );
    final String twoOfTwo = rootPayload(1, <List<int>>[rootSeed, nextRootSeed], threshold: 2);
    expect(
      () => _verify(_signed(_defaultDelegations()), root: twoOfTwo),
      _refused('trust_unverified'),
    );
    expect(
      _verify(
        _signed(_defaultDelegations(), <List<int>>[rootSeed, nextRootSeed]),
        root: twoOfTwo,
      ).rootVersion,
      1,
    );
  });

  test('a root rotation needs both thresholds and no gap', () {
    final String next = rootPayload(2, <List<int>>[nextRootSeed]);
    final Map<String, Object?> delegations = envelope(
      kShorebirdReleaseDelegationsSignatureDomain,
      delegationsPayload(1, 2, manifest: <List<int>>[manifestSeed]),
      <List<int>>[nextRootSeed],
    );
    final ShorebirdReleaseTrust trust = _verify(
      bundle(<Map<String, Object?>>[
        envelope(kShorebirdReleaseRootSignatureDomain, next, <List<int>>[rootSeed, nextRootSeed]),
      ], delegations),
    );
    expect(trust.rootVersion, 2);
    for (final only in <List<int>>[rootSeed, nextRootSeed]) {
      expect(
        () => _verify(
          bundle(<Map<String, Object?>>[
            envelope(kShorebirdReleaseRootSignatureDomain, next, <List<int>>[only]),
          ], delegations),
        ),
        _refused('trust_unverified'),
      );
    }
    final String skipped = rootPayload(3, <List<int>>[nextRootSeed]);
    expect(
      () => _verify(
        bundle(<Map<String, Object?>>[
          envelope(kShorebirdReleaseRootSignatureDomain, skipped, <List<int>>[
            rootSeed,
            nextRootSeed,
          ]),
        ], delegations),
      ),
      _refused('trust_unverified'),
    );
  });

  test('malformed bundles, payloads and pins are refused', () {
    final String good = _signed(_defaultDelegations());
    for (final bad in <String>[
      '',
      '{}',
      good.replaceFirst('"contract_version":2', '"contract_version":1'),
      good.replaceFirst('{', '{"x":1,'),
      'x' * (kShorebirdReleaseTrustMaxBytes + 1),
      // Same key in two roles; a root key delegated; a revoked key delegated.
      _signed(
        delegationsPayload(
          1,
          1,
          manifest: <List<int>>[manifestSeed],
          catalog: <List<int>>[manifestSeed],
        ),
      ),
      _signed(delegationsPayload(1, 1, manifest: <List<int>>[rootSeed])),
      _signed(
        delegationsPayload(
          1,
          1,
          manifest: <List<int>>[manifestSeed],
          revoked: <String>[keyId(manifestSeed)],
        ),
      ),
      // A non-canonical payload (whitespace) under a valid signature.
      _signed(_defaultDelegations().replaceFirst(',', ', ')),
    ]) {
      expect(() => _verify(bad), _refused('trust_malformed'), reason: bad);
    }
    for (final pin in <String>[
      '',
      '{}',
      rootPayload(1, <List<int>>[rootSeed], threshold: 2),
    ]) {
      expect(() => _verify(good, root: pin), _refused('trust_malformed'), reason: pin);
    }
  });

  test('build-time checks: expiry and key validity windows', () {
    final ShorebirdReleaseTrust trust = _verify(
      _signed(
        delegationsPayload(
          1,
          1,
          manifest: <List<int>>[manifestSeed],
          notBefore: '2027-01-01T00:00:00Z',
          notAfter: '2028-01-01T00:00:00Z',
        ),
      ),
    );
    final String id = keyId(manifestSeed);
    expect(
      trust.roleKey(ShorebirdSigningRole.buildManifest, id, at: DateTime.utc(2027, 6)),
      ed25519PublicKey(manifestSeed),
    );
    for (final outside in <DateTime>[DateTime.utc(2026, 12), DateTime.utc(2028)]) {
      expect(
        () => trust.roleKey(ShorebirdSigningRole.buildManifest, id, at: outside),
        _refused('signer_outside_window'),
      );
    }
    expect(
      () => trust.roleKey(ShorebirdSigningRole.buildManifest, id, at: DateTime.utc(2036, 12)),
      _refused('trust_expired'),
    );
  });
}

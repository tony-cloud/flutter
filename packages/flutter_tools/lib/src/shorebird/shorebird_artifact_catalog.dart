// Copyright 2026 The Open Shorebird Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Strict reader and verifier for Open Shorebird artifact catalogs, contract
/// v1 (shorebird-workspace `docs/HARDENING_CONTRACTS.md` sections 4 and 8 and
/// `docs/schemas/artifact-catalog*.v1.schema.json`).
///
/// A catalog is accepted only when:
///  * its bytes are exactly its canonical JSON (sorted keys, no whitespace),
///    so the digest the signature covers is the file digest and duplicate keys
///    cannot hide;
///  * it satisfies every v1 schema and cross-field rule, including that an
///    official artifact never satisfies a custom runtime/SDK route;
///  * an Ed25519 key pinned in `bin/internal/shorebird_artifact_trust.json`
///    signed `open-shorebird.artifact-catalog-signature.v1:<sha256 hex>`;
///  * a hardened toolchain sees a hardened catalog and a production key. A
///    development key or (with an explicit override) no signature is allowed
///    only for legacy toolchains, and the caller warns loudly;
///  * contract v3 (P5, section 11): a `hardened-diversified` toolchain sees a
///    contract version 3 `hardened-diversified` catalog naming its own
///    `diversification_profile_id`, under the hardened signer rule. Contract
///    v3 catalogs are accepted for no other profile, and v1 catalogs keep
///    `diversification_profile_id: null`.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;

import 'shorebird_ed25519.dart';
import 'shorebird_release_trust.dart';

/// Thrown when a catalog, signature or trust document must not be used.
class ShorebirdCatalogException implements Exception {
  ShorebirdCatalogException(this.message);

  final String message;

  @override
  String toString() => message;
}

const kShorebirdSignatureDomain = 'open-shorebird.artifact-catalog-signature.v1:';

final _revision = RegExp(r'^[0-9a-f]{40}$');
final _sha256Hex = RegExp(r'^[0-9a-f]{64}$');
final _sha256Id = RegExp(r'^sha256:[0-9a-f]{64}$');
final _originName = RegExp(r'^[a-z0-9][a-z0-9-]{0,63}$');
final _baseUrl = RegExp(r'^https://[^\s?#]+[^/\s?#]$');
final _artifactPath = RegExp(
  r'^(flutter_infra_release/flutter/\$engine/|download\.flutter\.io/io/flutter/[a-z0-9_]+/1\.0\.0-\$engine/)[^\s]+$',
);
const _platforms = <String>{
  'any',
  'android-arm',
  'android-arm64',
  'android-x64',
  'ios-arm64',
  'darwin-arm64',
  'darwin-x64',
  'linux-arm64',
  'linux-x64',
  'windows-arm64',
  'windows-x64',
};

/// Whether [path] (a catalog route, or any URL path) is a runtime binary,
/// kernel tool or SDK that must match the custom VM. Mirrors the artifact
/// proxy's `_requiresCustomSdkArtifact` and
/// `inventory_release_binaries.REQUIRES_CUSTOM_ROUTE`.
bool shorebirdRequiresCustomArtifact(String path) {
  final p = '/$path';
  return RegExp(r'/dart-sdk-[^/]+\.zip$').hasMatch(p) ||
      p.endsWith('/font-subset.zip') ||
      p.endsWith('/flutter_patched_sdk_product.zip') ||
      RegExp('/(?:android-[^/]+|ios|darwin(?:-[^/]+)?|linux-[^/]+)-release/').hasMatch(p) ||
      RegExp(r'/windows-[^/]+/windows-[^/]+-flutter\.zip$').hasMatch(p) ||
      RegExp('/io/flutter/[^/]+_release/').hasMatch(p);
}

/// The canonical JSON of contract v1: sorted keys, `,`/`:` separators, UTF-8,
/// integers only. Matches Python's
/// `json.dumps(sort_keys=True, separators=(",", ":"), ensure_ascii=False)` for
/// the documents it accepts (strings without control characters).
String shorebirdCanonicalJson(Object? value) {
  if (value is Map<String, Object?>) {
    final List<String> keys = value.keys.toList()..sort();
    return '{${keys.map((String key) => '${_canonicalString(key)}:${shorebirdCanonicalJson(value[key])}').join(',')}}';
  }
  if (value is List<Object?>) {
    return '[${value.map(shorebirdCanonicalJson).join(',')}]';
  }
  if (value is String) {
    return _canonicalString(value);
  }
  if (value is int || value is bool || value == null) {
    return jsonEncode(value);
  }
  throw ShorebirdCatalogException('canonical JSON allows no ${value.runtimeType} values');
}

String _canonicalString(String value) {
  for (final int unit in value.codeUnits) {
    if (unit < 0x20 || (unit >= 0xd800 && unit <= 0xdfff)) {
      throw ShorebirdCatalogException(
        'catalog strings must not contain control or surrogate characters',
      );
    }
  }
  return jsonEncode(value);
}

Object? _decodeCanonical(List<int> bytes, String what) {
  final Object? value;
  try {
    value = jsonDecode(utf8.decode(bytes));
  } on FormatException catch (error) {
    throw ShorebirdCatalogException('$what is not valid JSON: ${error.message}');
  }
  final List<int> canonical = utf8.encode(shorebirdCanonicalJson(value));
  if (!_sameBytes(canonical, bytes)) {
    throw ShorebirdCatalogException(
      '$what is not in canonical JSON form (sorted keys, no whitespace, no duplicate keys)',
    );
  }
  return value;
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

Map<String, Object?> _object(Object? value, String where, Set<String> keys) {
  if (value is! Map<String, Object?>) {
    throw ShorebirdCatalogException('$where must be an object');
  }
  final Set<String> actual = value.keys.toSet();
  if (actual.length != keys.length || !actual.containsAll(keys)) {
    throw ShorebirdCatalogException(
      '$where must have exactly the fields ${(keys.toList()..sort()).join(', ')}',
    );
  }
  return value;
}

String _string(Map<String, Object?> map, String key, String where, [RegExp? pattern]) {
  final Object? value = map[key];
  if (value is! String || (pattern != null && !pattern.hasMatch(value))) {
    throw ShorebirdCatalogException('$where.$key is invalid');
  }
  return value;
}

/// One origin of a catalog.
class ShorebirdCatalogOrigin {
  ShorebirdCatalogOrigin(this.name, this.officialClass, this.baseUrl);

  final String name;

  /// True for `official`, false for `custom-project`.
  final bool officialClass;
  final String baseUrl;
}

/// One artifact route of a catalog.
class ShorebirdCatalogArtifact {
  ShorebirdCatalogArtifact({
    required this.path,
    required this.origin,
    required this.custom,
    required this.revision,
    required this.platform,
    required this.sha256,
    required this.size,
    required this.required,
  });

  /// The route with `$engine`, for example
  /// `flutter_infra_release/flutter/$engine/sky_engine.zip`.
  final String path;
  final ShorebirdCatalogOrigin origin;

  /// True for `custom-toolchain`, false for `official-unchanged`.
  final bool custom;
  final String revision;
  final String platform;
  final String sha256;
  final int size;
  final bool required;

  /// The download URL: origin base URL plus the route at [revision].
  Uri urlFrom(String baseUrl) => Uri.parse('$baseUrl/${path.replaceAll(r'$engine', revision)}');
}

/// A parsed and validated contract v1 catalog.
class ShorebirdArtifactCatalog {
  ShorebirdArtifactCatalog._({
    required this.toolchainId,
    required this.securityProfile,
    required this.diversificationProfileId,
    required this.engineRevision,
    required this.upstreamEngineRevision,
    required this.artifacts,
    required this.sha256Hex,
  });

  final String toolchainId;
  final String securityProfile;

  /// `sha256:` ID for a contract v3 `hardened-diversified` catalog; null for
  /// contract v1.
  final String? diversificationProfileId;
  final String engineRevision;
  final String upstreamEngineRevision;

  /// Routes (with `$engine`) to artifacts.
  final Map<String, ShorebirdCatalogArtifact> artifacts;

  /// SHA-256 of the catalog bytes, which the signature covers.
  final String sha256Hex;

  /// Parses [bytes], enforcing canonical form, the v1 schema and the
  /// cross-field rules. Does not check any signature.
  static ShorebirdArtifactCatalog parse(List<int> bytes) {
    final Map<String, Object?> doc =
        _object(_decodeCanonical(bytes, 'catalog'), r'$', const <String>{
          'schema',
          'contract_version',
          'toolchain_id',
          'security_profile',
          'diversification_profile_id',
          'engine_revision',
          'upstream_engine_revision',
          'origins',
          'artifacts',
        });
    final Object? contractVersion = doc['contract_version'];
    if (doc['schema'] != 'open-shorebird.artifact-catalog' ||
        (contractVersion != 1 && contractVersion != 3)) {
      throw ShorebirdCatalogException(
        'not an open-shorebird.artifact-catalog contract 1 or 3 document',
      );
    }
    final String profile = _string(doc, 'security_profile', r'$');
    final String? diversificationProfileId;
    if (contractVersion == 1) {
      if (profile != 'legacy' && profile != 'hardened') {
        throw ShorebirdCatalogException(
          r'$.security_profile '
          '$profile is not admissible under contract v1',
        );
      }
      if (doc['diversification_profile_id'] != null) {
        throw ShorebirdCatalogException(
          r'$.diversification_profile_id must be null under contract v1',
        );
      }
      diversificationProfileId = null;
    } else {
      // Contract v3 exists only for hardened-diversified toolchains.
      if (profile != 'hardened-diversified') {
        throw ShorebirdCatalogException(
          r'$.security_profile '
          '$profile is not admissible under contract v3',
        );
      }
      if (doc['diversification_profile_id'] == null) {
        throw ShorebirdCatalogException(
          r'$.diversification_profile_id is required under contract v3',
        );
      }
      diversificationProfileId = _string(doc, 'diversification_profile_id', r'$', _sha256Id);
    }
    final String engine = _string(doc, 'engine_revision', r'$', _revision);
    final String upstream = _string(doc, 'upstream_engine_revision', r'$', _revision);
    final Object? rawOrigins = doc['origins'];
    if (rawOrigins is! Map<String, Object?> || rawOrigins.isEmpty) {
      throw ShorebirdCatalogException(r'$.origins must be a non-empty object');
    }
    final origins = <String, ShorebirdCatalogOrigin>{};
    for (final MapEntry<String, Object?> entry in rawOrigins.entries) {
      final where = '\$.origins.${entry.key}';
      if (!_originName.hasMatch(entry.key)) {
        throw ShorebirdCatalogException('$where: invalid origin name');
      }
      final Map<String, Object?> origin = _object(entry.value, where, const <String>{
        'class',
        'base_url',
      });
      final String originClass = _string(origin, 'class', where);
      if (originClass != 'official' && originClass != 'custom-project') {
        throw ShorebirdCatalogException('$where.class must be official or custom-project');
      }
      origins[entry.key] = ShorebirdCatalogOrigin(
        entry.key,
        originClass == 'official',
        _string(origin, 'base_url', where, _baseUrl),
      );
    }
    final Object? rawArtifacts = doc['artifacts'];
    if (rawArtifacts is! List<Object?> || rawArtifacts.isEmpty) {
      throw ShorebirdCatalogException(r'$.artifacts must be a non-empty array');
    }
    final artifacts = <String, ShorebirdCatalogArtifact>{};
    for (var i = 0; i < rawArtifacts.length; i++) {
      final where = '\$.artifacts[$i]';
      final Map<String, Object?> a = _object(rawArtifacts[i], where, const <String>{
        'path',
        'origin',
        'class',
        'revision',
        'platform',
        'sha256',
        'size',
        'required',
      });
      final String path = _string(a, 'path', where, _artifactPath);
      final ShorebirdCatalogOrigin? origin = origins[_string(a, 'origin', where)];
      if (origin == null) {
        throw ShorebirdCatalogException('$where.origin is not a declared origin');
      }
      final String artifactClass = _string(a, 'class', where);
      final bool custom;
      if (artifactClass == 'custom-toolchain') {
        custom = true;
      } else if (artifactClass == 'official-unchanged') {
        custom = false;
      } else {
        throw ShorebirdCatalogException('$where.class is invalid');
      }
      final String revision = _string(a, 'revision', where, _revision);
      final String platform = _string(a, 'platform', where);
      if (!_platforms.contains(platform)) {
        throw ShorebirdCatalogException('$where.platform is invalid');
      }
      final Object? size = a['size'];
      final Object? required = a['required'];
      if (size is! int || size < 0 || required is! bool) {
        throw ShorebirdCatalogException('$where.size or .required is invalid');
      }
      if (custom) {
        if (origin.officialClass) {
          throw ShorebirdCatalogException(
            '$where: custom-toolchain artifacts must use a custom-project origin',
          );
        }
        if (revision != engine) {
          throw ShorebirdCatalogException(
            '$where.revision: custom-toolchain artifacts use engine_revision',
          );
        }
      } else {
        if (!origin.officialClass) {
          throw ShorebirdCatalogException(
            '$where: official-unchanged artifacts must use an official origin',
          );
        }
        if (revision != upstream) {
          throw ShorebirdCatalogException(
            '$where.revision: official-unchanged artifacts use upstream_engine_revision',
          );
        }
        if (shorebirdRequiresCustomArtifact(path)) {
          throw ShorebirdCatalogException(
            '$where: $path is a custom runtime/SDK route; an official artifact must never satisfy it',
          );
        }
      }
      if (artifacts.containsKey(path)) {
        throw ShorebirdCatalogException('$where.path: duplicate route $path');
      }
      artifacts[path] = ShorebirdCatalogArtifact(
        path: path,
        origin: origin,
        custom: custom,
        revision: revision,
        platform: platform,
        sha256: _string(a, 'sha256', where, _sha256Hex),
        size: size,
        required: required,
      );
    }
    return ShorebirdArtifactCatalog._(
      toolchainId: _string(doc, 'toolchain_id', r'$', _sha256Id),
      securityProfile: profile,
      diversificationProfileId: diversificationProfileId,
      engineRevision: engine,
      upstreamEngineRevision: upstream,
      artifacts: artifacts,
      sha256Hex: sha256.convert(bytes).toString(),
    );
  }
}

/// How a verified catalog was authenticated.
enum ShorebirdCatalogTrust { production, development, unsigned }

class _TrustedKey {
  _TrustedKey(this.publicKey, this.production);

  final List<int> publicKey;
  final bool production;
}

Map<String, _TrustedKey> _parseTrust(List<int> bytes) {
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes));
  } on FormatException catch (error) {
    throw ShorebirdCatalogException('trust document is not valid JSON: ${error.message}');
  }
  final Map<String, Object?> doc = _object(decoded, 'trust', const <String>{
    'schema',
    'contract_version',
    'keys',
  });
  if (doc['schema'] != 'open-shorebird.artifact-catalog-trust' || doc['contract_version'] != 1) {
    throw ShorebirdCatalogException(
      'trust document is not open-shorebird.artifact-catalog-trust contract 1',
    );
  }
  final Object? keys = doc['keys'];
  if (keys is! List<Object?>) {
    throw ShorebirdCatalogException('trust.keys must be an array');
  }
  final result = <String, _TrustedKey>{};
  for (var i = 0; i < keys.length; i++) {
    final where = 'trust.keys[$i]';
    final Map<String, Object?> key = _object(keys[i], where, const <String>{
      'key_id',
      'algorithm',
      'public_key',
      'usage',
      'description',
    });
    if (key['algorithm'] != 'ed25519') {
      throw ShorebirdCatalogException('$where.algorithm must be ed25519');
    }
    final String usage = _string(key, 'usage', where);
    if (usage != 'production' && usage != 'development') {
      throw ShorebirdCatalogException('$where.usage must be production or development');
    }
    final List<int> publicKey = base64.decode(_string(key, 'public_key', where));
    final String keyId = _string(key, 'key_id', where, _sha256Id);
    if (publicKey.length != 32 || keyId != 'sha256:${sha256.convert(publicKey)}') {
      throw ShorebirdCatalogException('$where.key_id must be sha256 over the 32-byte public key');
    }
    if (result.containsKey(keyId)) {
      throw ShorebirdCatalogException('$where.key_id is duplicated');
    }
    result[keyId] = _TrustedKey(publicKey, usage == 'production');
  }
  return result;
}

/// Verifies [catalogBytes] and its detached [signatureBytes] against the pinned
/// [trustBytes] for a toolchain of [securityProfile] (`legacy`, `hardened` or
/// `hardened-diversified`; the last one with its [diversificationProfileId]).
///
/// Returns the catalog and how it was authenticated, or throws a
/// [ShorebirdCatalogException] naming why it must not be used.
(ShorebirdArtifactCatalog, ShorebirdCatalogTrust) verifyShorebirdArtifactCatalog({
  required List<int> catalogBytes,
  required List<int>? signatureBytes,
  required List<int> trustBytes,
  required String securityProfile,
  required String engineRevision,
  bool allowUnsigned = false,
  ShorebirdReleaseTrust? releaseTrust,
  String? diversificationProfileId,
}) {
  if (securityProfile != 'legacy' &&
      securityProfile != 'hardened' &&
      securityProfile != 'hardened-diversified') {
    throw ShorebirdCatalogException('unsupported security profile $securityProfile');
  }
  final diversified = securityProfile == 'hardened-diversified';
  // hardened-diversified follows every hardened rule (section 10.6).
  final bool hardened = securityProfile == 'hardened' || diversified;
  if (diversified != (diversificationProfileId != null)) {
    throw ShorebirdCatalogException(
      'a diversification profile ID is required exactly for a hardened-diversified toolchain',
    );
  }
  if (diversified && !_sha256Id.hasMatch(diversificationProfileId!)) {
    throw ShorebirdCatalogException('the diversification profile ID must be sha256:<64 hex>');
  }
  if (hardened && releaseTrust == null) {
    throw ShorebirdCatalogException(
      'a hardened toolchain verifies the catalog signer under the release root '
      '($kShorebirdReleaseTrustEnvVar, $kShorebirdReleaseRootEnvVar)',
    );
  }
  final Map<String, _TrustedKey> trust = _parseTrust(trustBytes);
  final ShorebirdArtifactCatalog catalog = ShorebirdArtifactCatalog.parse(catalogBytes);
  if (catalog.engineRevision != engineRevision) {
    throw ShorebirdCatalogException(
      'the catalog is for engine ${catalog.engineRevision}, not this toolchain engine $engineRevision',
    );
  }
  if (catalog.securityProfile != securityProfile &&
      (hardened || catalog.securityProfile == 'hardened-diversified')) {
    throw ShorebirdCatalogException(
      'a $securityProfile toolchain requires a $securityProfile catalog, not '
      '${catalog.securityProfile}',
    );
  }
  if (diversified && catalog.diversificationProfileId != diversificationProfileId) {
    throw ShorebirdCatalogException(
      'the catalog is for diversification profile ${catalog.diversificationProfileId}, not '
      "this toolchain's $diversificationProfileId",
    );
  }
  if (signatureBytes == null) {
    if (hardened) {
      throw ShorebirdCatalogException(
        'unsigned catalog: a hardened toolchain requires a production signature',
      );
    }
    if (!allowUnsigned) {
      throw ShorebirdCatalogException(
        'unsigned catalog: set SHOREBIRD_ALLOW_UNSIGNED_ARTIFACT_CATALOG=1 to accept it for local development',
      );
    }
    return (catalog, ShorebirdCatalogTrust.unsigned);
  }
  final Map<String, Object?> signature = _object(
    _decodeCanonical(signatureBytes, 'catalog signature'),
    'signature',
    const <String>{
      'schema',
      'contract_version',
      'algorithm',
      'key_id',
      'catalog_sha256',
      'signature',
    },
  );
  if (signature['schema'] != 'open-shorebird.artifact-catalog-signature' ||
      signature['contract_version'] != 1 ||
      signature['algorithm'] != 'ed25519') {
    throw ShorebirdCatalogException(
      'signature is not an open-shorebird.artifact-catalog-signature contract 1 ed25519 document',
    );
  }
  final String digest = _string(signature, 'catalog_sha256', 'signature', _sha256Hex);
  if (digest != catalog.sha256Hex) {
    throw ShorebirdCatalogException('the signature covers a different catalog digest');
  }
  final String keyId = _string(signature, 'key_id', 'signature', _sha256Id);
  final _TrustedKey? key = trust[keyId];
  if (key == null) {
    throw ShorebirdCatalogException('the catalog is signed by untrusted key $keyId');
  }
  final List<int> signatureValue;
  try {
    signatureValue = base64.decode(_string(signature, 'signature', 'signature'));
  } on FormatException {
    throw ShorebirdCatalogException('the signature value is not base64');
  }
  if (!ed25519Verify(
    key.publicKey,
    utf8.encode('$kShorebirdSignatureDomain$digest'),
    signatureValue,
  )) {
    throw ShorebirdCatalogException('the catalog signature does not verify');
  }
  if (!key.production && hardened) {
    throw ShorebirdCatalogException(
      'a hardened toolchain rejects a catalog signed by a development key',
    );
  }
  if (hardened) {
    // Contract v2 (P4): the signer must also be the release root's current
    // artifact-catalog delegate, so a revoked, rotated-out or other-role key
    // (a build-manifest or root key) never authenticates a catalog.
    try {
      releaseTrust!.roleKey(ShorebirdSigningRole.artifactCatalog, keyId);
    } on ShorebirdReleaseTrustException catch (error) {
      throw ShorebirdCatalogException(
        'the catalog signer is not an artifact-catalog key under the release root: $error',
      );
    }
  }
  return (
    catalog,
    key.production ? ShorebirdCatalogTrust.production : ShorebirdCatalogTrust.development,
  );
}

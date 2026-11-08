// Copyright 2026 The Open Shorebird Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Release root of trust (hardening stage P4, contract v2,
/// shorebird-workspace `docs/HARDENING_CONTRACTS.md` §10).
///
/// The engine compiles one version of the operator's offline release root
/// (GN `shorebird_release_root`: the base64 of a canonical `release-root`
/// payload) and a delegations version floor. A `release-trust` bundle carries
/// the root chain and the current `release-delegations`, which name the keys
/// of each signing role. This file verifies a bundle exactly as the updater
/// (`updater/library/src/release_trust.rs`) does, and in addition enforces
/// what only a build machine can: expiry and key validity windows against
/// the build clock, and the refusal of the DEVELOPMENT-ONLY root outside a
/// development build. The reference tool is `scripts/release_trust.py`.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;

import '../base/file_system.dart';
import 'shorebird_artifact_catalog.dart' show ShorebirdCatalogException, shorebirdCanonicalJson;
import 'shorebird_ed25519.dart';

export 'shorebird_artifact_catalog.dart' show shorebirdCanonicalJson;

/// Path of the `release-trust` bundle a hardened build embeds.
const kShorebirdReleaseTrustEnvVar = 'SHOREBIRD_RELEASE_TRUST';

/// The compiled release-root pin (base64 payload), as the engine was built.
const kShorebirdReleaseRootEnvVar = 'SHOREBIRD_RELEASE_ROOT';

/// The compiled delegations version floor (default 1).
const kShorebirdReleaseMinDelegationsVersionEnvVar = 'SHOREBIRD_RELEASE_MIN_DELEGATIONS_VERSION';

const kShorebirdReleaseRootSignatureDomain = 'open-shorebird.release-root-signature.v2:';
const kShorebirdReleaseDelegationsSignatureDomain =
    'open-shorebird.release-delegations-signature.v2:';
const _kRootSchema = 'open-shorebird.release-root';
const _kDelegationsSchema = 'open-shorebird.release-delegations';
const _kTrustSchema = 'open-shorebird.release-trust';
const _kContractVersion = 2;
const _kMaxRootChain = 16;
const _kMaxKeys = 32;
const int kShorebirdReleaseTrustMaxBytes = 32 * 1024;

/// Public keys of the committed DEVELOPMENT-ONLY release root
/// (`scripts/testdata/release-trust/root-1.DEVELOPMENT-ONLY.pem`).
const kShorebirdDevelopmentRootPublicKeys = <String>[
  'iojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1w=',
];

/// The signing roles a delegations document names.
enum ShorebirdSigningRole {
  buildManifest('build-manifest'),
  artifactCatalog('artifact-catalog');

  const ShorebirdSigningRole(this.wireName);

  final String wireName;
}

/// A refusal; [code] matches the updater's integrity codes where both apply
/// (`trust_malformed`, `trust_unverified`, `trust_rollback`,
/// `manifest_signer_revoked`, `manifest_signer_role`,
/// `manifest_untrusted_signer`) plus the build-only `trust_expired`,
/// `signer_outside_window` and `trust_development`.
class ShorebirdReleaseTrustException implements Exception {
  const ShorebirdReleaseTrustException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'Release trust refused ($code): $message';
}

Never _fail(String code, String message) => throw ShorebirdReleaseTrustException(code, message);

Never _malformed(String message) => _fail('trust_malformed', message);

String _canonical(Object? value) {
  try {
    return shorebirdCanonicalJson(value);
  } on ShorebirdCatalogException catch (error) {
    _malformed(error.message);
  }
}

List<int> _b64(Object? value, String what) {
  if (value is! String) {
    _malformed('$what is not a string');
  }
  final List<int> raw;
  try {
    raw = base64.decode(value);
  } on FormatException {
    _malformed('$what is not base64');
  }
  if (base64.encode(raw) != value) {
    _malformed('$what is not canonical base64');
  }
  return raw;
}

Map<String, Object?> _object(Object? value, Set<String> fields, String what) {
  if (value is! Map<String, Object?> ||
      value.length != fields.length ||
      !value.keys.every(fields.contains)) {
    _malformed('$what must have exactly the fields ${fields.join(', ')}');
  }
  return value;
}

String _string(Map<String, Object?> map, String field, String what) {
  final Object? value = map[field];
  if (value is! String) {
    _malformed('$what.$field must be a string');
  }
  return value;
}

int _positive(Map<String, Object?> map, String field, String what) {
  final Object? value = map[field];
  if (value is! int || value < 1) {
    _malformed('$what.$field must be a positive integer');
  }
  return value;
}

final _idPattern = RegExp(r'^sha256:[0-9a-f]{64}$');
final _timePattern = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$');

/// `sha256:` over a raw 32-byte Ed25519 public key.
String shorebirdReleaseKeyId(List<int> publicKey) => 'sha256:${sha256.convert(publicKey)}';

DateTime _time(String value, String what) {
  if (!_timePattern.hasMatch(value)) {
    _malformed('$what is not YYYY-MM-DDTHH:MM:SSZ');
  }
  final DateTime? parsed = DateTime.tryParse(value);
  if (parsed == null) {
    _malformed('$what is not a valid time');
  }
  return parsed;
}

class _Key {
  _Key(this.id, this.raw, {this.notBefore, this.notAfter});

  final String id;
  final List<int> raw;
  final DateTime? notBefore;
  final DateTime? notAfter;
}

List<_Key> _keys(Object? value, String what, {required bool delegated}) {
  if (value is! List<Object?> || value.length > _kMaxKeys) {
    _malformed('$what must be a list of at most $_kMaxKeys keys');
  }
  final keys = <_Key>[];
  for (final Object? entry in value) {
    final Map<String, Object?> map = _object(
      entry,
      delegated
          ? const <String>{'key_id', 'public_key', 'not_before', 'not_after'}
          : const <String>{'key_id', 'public_key'},
      what,
    );
    final String id = _string(map, 'key_id', what);
    final List<int> raw = _b64(map['public_key'], '$what.public_key');
    if (raw.length != 32 || shorebirdReleaseKeyId(raw) != id) {
      _malformed('$what: $id does not match its public key');
    }
    if (keys.any((_Key k) => k.id == id)) {
      _malformed('$what: duplicate key $id');
    }
    if (delegated) {
      final DateTime notBefore = _time(_string(map, 'not_before', what), '$what.not_before');
      final DateTime notAfter = _time(_string(map, 'not_after', what), '$what.not_after');
      if (!notBefore.isBefore(notAfter)) {
        _malformed('$what: not_after must be after not_before');
      }
      keys.add(_Key(id, raw, notBefore: notBefore, notAfter: notAfter));
    } else {
      keys.add(_Key(id, raw));
    }
  }
  return keys;
}

/// Parses a canonical JSON payload; any other encoding (whitespace,
/// reordered or duplicated keys) is refused.
Object? _payload(List<int> bytes, String what) {
  final Object? value;
  try {
    value = jsonDecode(utf8.decode(bytes));
  } on FormatException {
    _malformed('$what is not JSON');
  }
  if (_canonical(value) != utf8.decode(bytes)) {
    _malformed('$what payload is not canonical JSON');
  }
  return value;
}

class _Root {
  _Root(this.version, this.threshold, this.keys, this.expiresAt, this.payload);

  final int version;
  final int threshold;
  final List<_Key> keys;
  final DateTime expiresAt;
  final List<int> payload;
}

_Root _parseRoot(List<int> payload) {
  final Map<String, Object?> map = _object(_payload(payload, 'release root'), const <String>{
    'schema',
    'contract_version',
    'version',
    'threshold',
    'keys',
    'expires_at',
  }, 'release root');
  if (map['schema'] != _kRootSchema || map['contract_version'] != _kContractVersion) {
    _malformed('release root schema');
  }
  final List<_Key> keys = _keys(map['keys'], 'release root keys', delegated: false);
  final int threshold = _positive(map, 'threshold', 'release root');
  if (keys.isEmpty || threshold > keys.length) {
    _malformed('release root threshold');
  }
  return _Root(
    _positive(map, 'version', 'release root'),
    threshold,
    keys,
    _time(_string(map, 'expires_at', 'release root'), 'release root expires_at'),
    payload,
  );
}

(List<int>, Map<String, List<int>>) _open(Object? envelope, String what) {
  final Map<String, Object?> map = _object(envelope, const <String>{'payload', 'signatures'}, what);
  final List<int> payload = _b64(map['payload'], '$what.payload');
  final Object? list = map['signatures'];
  if (list is! List<Object?> || list.isEmpty) {
    _malformed('$what needs signatures');
  }
  final signatures = <String, List<int>>{};
  for (final Object? entry in list) {
    final Map<String, Object?> signature = _object(entry, const <String>{
      'key_id',
      'signature',
    }, what);
    final String id = _string(signature, 'key_id', what);
    final List<int> bytes = _b64(signature['signature'], '$what.signature');
    if (!_idPattern.hasMatch(id) || bytes.length != 64 || signatures.containsKey(id)) {
      _malformed('$what has a malformed or repeated signature');
    }
    signatures[id] = bytes;
  }
  return (payload, signatures);
}

int _countValid(
  String domain,
  List<int> payload,
  Map<String, List<int>> signatures,
  List<_Key> keys,
) {
  final List<int> message = utf8.encode('$domain${sha256.convert(payload)}');
  return keys
      .where(
        (_Key key) =>
            signatures.containsKey(key.id) && ed25519Verify(key.raw, message, signatures[key.id]!),
      )
      .length;
}

/// A bundle verified under a compiled root.
class ShorebirdReleaseTrust {
  ShorebirdReleaseTrust._({
    required this.rootVersion,
    required this.rootSha256,
    required this.delegationsVersion,
    required this.delegationsSha256,
    required this.compactBundle,
    required this.rootExpiresAt,
    required this.issuedAt,
    required this.expiresAt,
    required List<String> rootKeyIds,
    required Map<ShorebirdSigningRole, List<_Key>> roles,
    required List<String> revoked,
    required this.development,
  }) : _rootKeyIds = rootKeyIds,
       _roles = roles,
       _revoked = revoked;

  final int rootVersion;

  /// `sha256:` over the payload of the root version the chain ends at.
  final String rootSha256;
  final int delegationsVersion;

  /// Lowercase hex SHA-256 of the delegations payload bytes.
  final String delegationsSha256;

  /// The bundle as canonical JSON, the form a build manifest carries.
  final String compactBundle;
  final DateTime rootExpiresAt;
  final DateTime issuedAt;
  final DateTime expiresAt;

  /// Whether the compiled or final root contains a DEVELOPMENT-ONLY key.
  final bool development;
  final List<String> _rootKeyIds;
  final Map<ShorebirdSigningRole, List<_Key>> _roles;
  final List<String> _revoked;

  /// The raw public key [keyId] may use for [role]. With [at], also the
  /// build-time checks: the root and delegations are current and the key is
  /// inside its validity window.
  List<int> roleKey(ShorebirdSigningRole role, String keyId, {DateTime? at}) {
    if (_revoked.contains(keyId)) {
      _fail('manifest_signer_revoked', '$keyId is revoked');
    }
    final _Key? key = _roles[role]!.where((_Key k) => k.id == keyId).firstOrNull;
    if (key == null) {
      final bool otherRole = _roles.entries.any(
        (MapEntry<ShorebirdSigningRole, List<_Key>> e) =>
            e.key != role && e.value.any((_Key k) => k.id == keyId),
      );
      if (otherRole || _rootKeyIds.contains(keyId)) {
        _fail('manifest_signer_role', '$keyId is not a ${role.wireName} key');
      }
      _fail('manifest_untrusted_signer', '$keyId is not a delegated ${role.wireName} key');
    }
    if (at != null) {
      checkCurrent(at);
      if (at.isBefore(key.notBefore!) || !at.isBefore(key.notAfter!)) {
        _fail(
          'signer_outside_window',
          '$keyId may sign from ${key.notBefore!.toIso8601String()} until '
              '${key.notAfter!.toIso8601String()}',
        );
      }
    }
    return key.raw;
  }

  /// Fails unless the root and the delegations are current at [at].
  void checkCurrent(DateTime at) {
    if (!at.isBefore(rootExpiresAt)) {
      _fail('trust_expired', 'root version $rootVersion has expired');
    }
    if (at.isBefore(issuedAt) || !at.isBefore(expiresAt)) {
      _fail('trust_expired', 'delegations version $delegationsVersion are not current');
    }
  }
}

/// Verifies [bundle] against the compiled [pinnedRoot] payload and
/// [minDelegationsVersion], with the updater's rules.
ShorebirdReleaseTrust verifyShorebirdReleaseTrust(
  List<int> bundle, {
  required List<int> pinnedRoot,
  int minDelegationsVersion = 1,
}) {
  _Root root;
  try {
    root = _parseRoot(pinnedRoot);
  } on ShorebirdReleaseTrustException {
    _malformed('compiled release root');
  }
  final pinned = root;
  if (bundle.length > kShorebirdReleaseTrustMaxBytes) {
    _malformed('release trust size');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bundle));
  } on FormatException {
    _malformed('release trust is not JSON');
  }
  final Map<String, Object?> map = _object(decoded, const <String>{
    'schema',
    'contract_version',
    'root_chain',
    'delegations',
  }, 'release trust');
  if (map['schema'] != _kTrustSchema || map['contract_version'] != _kContractVersion) {
    _malformed('release trust schema');
  }
  final Object? chain = map['root_chain'];
  if (chain is! List<Object?> || chain.length > _kMaxRootChain) {
    _malformed('root chain');
  }
  for (final Object? envelope in chain) {
    final (List<int> payload, Map<String, List<int>> signatures) = _open(envelope, 'root chain');
    final _Root next = _parseRoot(payload);
    if (next.version <= root.version) {
      continue;
    }
    if (next.version != root.version + 1) {
      _fail('trust_unverified', 'root chain gap');
    }
    if (_countValid(kShorebirdReleaseRootSignatureDomain, payload, signatures, root.keys) <
            root.threshold ||
        _countValid(kShorebirdReleaseRootSignatureDomain, payload, signatures, next.keys) <
            next.threshold) {
      _fail('trust_unverified', 'root rotation');
    }
    root = next;
  }
  final (List<int> payload, Map<String, List<int>> signatures) = _open(
    map['delegations'],
    'delegations',
  );
  final Map<String, Object?> delegations = _object(_payload(payload, 'delegations'), const <String>{
    'schema',
    'contract_version',
    'version',
    'root_version',
    'issued_at',
    'expires_at',
    'roles',
    'revoked_key_ids',
  }, 'delegations');
  if (delegations['schema'] != _kDelegationsSchema ||
      delegations['contract_version'] != _kContractVersion) {
    _malformed('delegations schema');
  }
  final int version = _positive(delegations, 'version', 'delegations');
  if (_positive(delegations, 'root_version', 'delegations') != root.version) {
    _fail('trust_unverified', 'delegations root version');
  }
  if (_countValid(kShorebirdReleaseDelegationsSignatureDomain, payload, signatures, root.keys) <
      root.threshold) {
    _fail('trust_unverified', 'delegations signature');
  }
  if (version < minDelegationsVersion) {
    _fail(
      'trust_rollback',
      'delegations version $version is below the compiled minimum $minDelegationsVersion',
    );
  }
  final Map<String, Object?> rolesMap = _object(delegations['roles'], const <String>{
    'build-manifest',
    'artifact-catalog',
  }, 'delegations roles');
  final roles = <ShorebirdSigningRole, List<_Key>>{
    for (final ShorebirdSigningRole role in ShorebirdSigningRole.values)
      role: _keys(rolesMap[role.wireName], 'delegated ${role.wireName} keys', delegated: true),
  };
  final Object? revoked = delegations['revoked_key_ids'];
  if (revoked is! List<Object?> ||
      !revoked.every((Object? id) => id is String && _idPattern.hasMatch(id))) {
    _malformed('revoked key IDs');
  }
  final List<String> revokedIds = revoked.cast<String>();
  final rootIds = <String>[for (final _Key key in root.keys) key.id];
  final seen = <String>{};
  for (final _Key key in roles.values.expand((List<_Key> keys) => keys)) {
    if (!seen.add(key.id) || rootIds.contains(key.id) || revokedIds.contains(key.id)) {
      _malformed('role separation');
    }
  }
  final developmentIds = <String>[
    for (final String key in kShorebirdDevelopmentRootPublicKeys)
      shorebirdReleaseKeyId(base64.decode(key)),
  ];
  return ShorebirdReleaseTrust._(
    rootVersion: root.version,
    rootSha256: 'sha256:${sha256.convert(root.payload)}',
    delegationsVersion: version,
    delegationsSha256: sha256.convert(payload).toString(),
    compactBundle: _canonical(decoded),
    rootExpiresAt: root.expiresAt,
    issuedAt: _time(_string(delegations, 'issued_at', 'delegations'), 'issued_at'),
    expiresAt: _time(_string(delegations, 'expires_at', 'delegations'), 'expires_at'),
    rootKeyIds: rootIds,
    roles: roles,
    revoked: revokedIds,
    development: <_Key>[
      ...pinned.keys,
      ...root.keys,
    ].any((_Key key) => developmentIds.contains(key.id)),
  );
}

/// Loads and verifies the bundle a hardened build names in [environment]
/// ([kShorebirdReleaseTrustEnvVar], [kShorebirdReleaseRootEnvVar],
/// [kShorebirdReleaseMinDelegationsVersionEnvVar]). Throws a
/// [FormatException] naming what is missing or refused.
ShorebirdReleaseTrust loadShorebirdReleaseTrust(
  Map<String, String> environment,
  FileSystem fileSystem,
) {
  final String trustPath = environment[kShorebirdReleaseTrustEnvVar] ?? '';
  final String pin = environment[kShorebirdReleaseRootEnvVar] ?? '';
  if (trustPath.isEmpty || pin.isEmpty) {
    throw const FormatException(
      'The hardened security profile requires $kShorebirdReleaseTrustEnvVar (the release-trust '
      'bundle) and $kShorebirdReleaseRootEnvVar (the release root compiled into the engine)',
    );
  }
  final File trustFile = fileSystem.file(trustPath);
  if (!trustFile.existsSync()) {
    throw FormatException('$kShorebirdReleaseTrustEnvVar does not exist: $trustPath');
  }
  final String minimum = environment[kShorebirdReleaseMinDelegationsVersionEnvVar] ?? '';
  if (minimum.isNotEmpty && !RegExp(r'^[1-9][0-9]{0,8}$').hasMatch(minimum)) {
    throw const FormatException(
      '$kShorebirdReleaseMinDelegationsVersionEnvVar must be a positive integer',
    );
  }
  final List<int> pinnedRoot;
  try {
    pinnedRoot = base64.decode(pin);
  } on FormatException {
    throw const FormatException('$kShorebirdReleaseRootEnvVar is not base64');
  }
  try {
    return verifyShorebirdReleaseTrust(
      trustFile.readAsBytesSync(),
      pinnedRoot: pinnedRoot,
      minDelegationsVersion: minimum.isEmpty ? 1 : int.parse(minimum),
    );
  } on ShorebirdReleaseTrustException catch (error) {
    throw FormatException('$kShorebirdReleaseTrustEnvVar: $error');
  }
}

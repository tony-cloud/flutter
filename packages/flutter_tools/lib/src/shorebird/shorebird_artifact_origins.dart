// Copyright 2026 The Open Shorebird Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// The Open Shorebird origin resolver used by the Flutter tool.
///
/// One precedence model is shared by `bin/internal/shorebird_dart_sdk.{sh,ps1}`
/// (the Dart SDK bootstrap), this file (Flutter tool artifacts), and the
/// Shorebird CLI (`shorebird_env.dart`, its launchers). It is documented in
/// shorebird-workspace `docs/HARDENING_CONTRACTS.md` section 8:
///
///  * `PUB_HOSTED_URL` applies to Pub only and is never read here.
///  * `FLUTTER_STORAGE_BASE_URL` names an origin of *official-compatible*
///    artifacts. It never serves a custom (patched) route.
///  * `SHOREBIRD_ARTIFACT_BASE_URL` names the custom artifact store. Custom
///    routes resolve to `<store>/shorebird/<route>`, and the signed catalog for
///    an engine is `<store>/shorebird/<engine>/artifact-catalog.v1.json`.
///  * `SHOREBIRD_ORIGIN_MODE=legacy-mirror`, or the compatibility aliases
///    `SHOREBIRD_DOWNLOAD_URL` / `SHOREBIRD_FLUTTER_STORAGE_BASE_URL` (or
///    `FLUTTER_STORAGE_BASE_URL` naming the open artifact proxy), select one
///    all-in-one artifact proxy for every artifact, as before.
///  * Conflicting settings are errors, never a silent choice.
library;

import 'package:crypto/crypto.dart' show sha256;

import '../base/file_system.dart';
import 'shorebird_artifact_catalog.dart';
import 'shorebird_release_trust.dart';

/// The open artifact proxy; as `FLUTTER_STORAGE_BASE_URL` it is the legacy
/// all-in-one mirror alias. Equal to `kOpenFlutterStorageUrl` in cache.dart.
const kShorebirdOpenProxyUrl = 'http://localhost:8080/download.flutter.io';

/// The official Flutter artifact origin.
const kShorebirdOfficialStorageUrl = 'https://storage.googleapis.com';

/// The default custom artifact store: the operator's self-hosted server.
const kShorebirdDefaultArtifactStoreUrl = 'http://localhost:8080/artifacts';

const kShorebirdCatalogFileName = 'artifact-catalog.v1.json';

/// Thrown for an unusable origin configuration; the message is user-facing.
class ShorebirdOriginException implements Exception {
  ShorebirdOriginException(this.message);

  final String message;

  @override
  String toString() => message;
}

enum ShorebirdOriginMode { split, legacyMirror }

String? _value(Map<String, String> environment, String name) {
  // Not trimmed: a malformed URL must still fail loudly where it is parsed.
  String? value = environment[name];
  if (value == null || value.trim().isEmpty) {
    return null;
  }
  while (value!.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

/// The resolved origins for one environment.
class ShorebirdArtifactOrigins {
  ShorebirdArtifactOrigins._({
    required this.mode,
    required this.officialBaseUrl,
    required this.mirrorUrl,
    required this.artifactStoreUrl,
  });

  /// Resolves [environment], throwing [ShorebirdOriginException] on conflicts.
  factory ShorebirdArtifactOrigins.fromEnvironment(Map<String, String> environment) {
    String? legacy;
    String? legacyName;
    for (final name in <String>['SHOREBIRD_DOWNLOAD_URL', 'SHOREBIRD_FLUTTER_STORAGE_BASE_URL']) {
      final String? value = _value(environment, name);
      if (value == null) {
        continue;
      }
      if (legacy != null && legacy != value) {
        throw ShorebirdOriginException(
          'Conflicting artifact mirror overrides: $legacyName=$legacy but $name=$value. '
          'Both name a legacy all-in-one artifact mirror. Set one of them, or neither.',
        );
      }
      legacy = value;
      legacyName = name;
    }
    final String? official = _value(environment, 'FLUTTER_STORAGE_BASE_URL');
    if (legacy == null && official == kShorebirdOpenProxyUrl) {
      legacy = official;
      legacyName = 'FLUTTER_STORAGE_BASE_URL';
    }
    final ShorebirdOriginMode mode;
    switch (_value(environment, 'SHOREBIRD_ORIGIN_MODE')) {
      case null:
        mode = legacy == null ? ShorebirdOriginMode.split : ShorebirdOriginMode.legacyMirror;
      case 'split':
        if (legacy != null) {
          throw ShorebirdOriginException(
            'SHOREBIRD_ORIGIN_MODE=split conflicts with $legacyName=$legacy, a legacy all-in-one mirror. '
            'Unset the mirror variable, or set SHOREBIRD_ORIGIN_MODE=legacy-mirror.',
          );
        }
        mode = ShorebirdOriginMode.split;
      case 'legacy-mirror':
        mode = ShorebirdOriginMode.legacyMirror;
        legacy ??= official ?? kShorebirdOpenProxyUrl;
      case final String other:
        throw ShorebirdOriginException(
          'Unknown SHOREBIRD_ORIGIN_MODE=$other. Use split (default) or legacy-mirror.',
        );
    }
    if (mode == ShorebirdOriginMode.legacyMirror && official != null && official != legacy) {
      throw ShorebirdOriginException(
        'Conflicting artifact origins: FLUTTER_STORAGE_BASE_URL=$official but the legacy all-in-one '
        'mirror is $legacy. In legacy-mirror mode one mirror serves every artifact. Unset '
        'FLUTTER_STORAGE_BASE_URL or set it to the mirror.',
      );
    }
    return ShorebirdArtifactOrigins._(
      mode: mode,
      officialBaseUrl: mode == ShorebirdOriginMode.split
          ? (official ?? kShorebirdOfficialStorageUrl)
          : legacy!,
      mirrorUrl: mode == ShorebirdOriginMode.legacyMirror ? legacy : null,
      artifactStoreUrl:
          _value(environment, 'SHOREBIRD_ARTIFACT_BASE_URL') ?? kShorebirdDefaultArtifactStoreUrl,
    );
  }

  final ShorebirdOriginMode mode;

  /// Where official-compatible artifacts come from: `FLUTTER_STORAGE_BASE_URL`
  /// or the official origin in split mode, the mirror in legacy-mirror mode.
  /// This is the Flutter tool's storage base URL.
  final String officialBaseUrl;

  /// The all-in-one mirror (legacy-mirror mode only).
  final String? mirrorUrl;

  /// The custom artifact store (`SHOREBIRD_ARTIFACT_BASE_URL`).
  final String artifactStoreUrl;
}

/// A download the resolver redirected and, where the catalog pins it, must
/// match [sha256] and [size] before it is unpacked.
class ShorebirdResolvedDownload {
  ShorebirdResolvedDownload({
    required this.url,
    required this.route,
    required this.custom,
    this.sha256,
    this.size,
  });

  final Uri url;
  final String route;
  final bool custom;
  final String? sha256;
  final int? size;
}

/// Fetches [url]; returns null for HTTP 404 and throws on any other failure.
typedef ShorebirdFetch = Future<List<int>?> Function(Uri url);

/// Maps Flutter tool engine-artifact URLs to verified origins using the signed
/// artifact catalog for the toolchain's engine revision (split mode only).
class ShorebirdArtifactResolver {
  ShorebirdArtifactResolver({
    required Map<String, String> environment,
    required FileSystem fileSystem,
    required String flutterRoot,
    required String Function() engineRevision,
    required void Function(String message) warn,
  }) : _environment = environment,
       _fileSystem = fileSystem,
       _flutterRoot = flutterRoot,
       _engineRevision = engineRevision,
       _warn = warn;

  final Map<String, String> _environment;
  final FileSystem _fileSystem;
  final String _flutterRoot;
  final String Function() _engineRevision;
  final void Function(String message) _warn;
  ShorebirdArtifactCatalog? _catalog;

  ShorebirdArtifactOrigins get origins => ShorebirdArtifactOrigins.fromEnvironment(_environment);

  String get _securityProfile => _environment['SHOREBIRD_SECURITY_PROFILE'] ?? 'legacy';

  /// Returns where [url] must really be downloaded from, or null when the URL
  /// is not an engine-revision route this resolver owns (or the mode is
  /// legacy-mirror). Throws [ShorebirdOriginException] when a custom artifact
  /// cannot be resolved, so a stock artifact is never substituted.
  Future<ShorebirdResolvedDownload?> resolve(Uri url, ShorebirdFetch fetch) async {
    final ShorebirdArtifactOrigins origins = this.origins;
    if (origins.mode != ShorebirdOriginMode.split) {
      return null;
    }
    final String engine = _engineRevision();
    final text = url.toString();
    final String? relative = _relativeTo(text, origins.officialBaseUrl);
    if (relative == null) {
      return null;
    }
    final String route;
    if (relative.startsWith('flutter_infra_release/flutter/$engine/')) {
      route = relative.replaceFirst('/$engine/', r'/$engine/');
    } else if (RegExp(
      '^download\\.flutter\\.io/io/flutter/[a-z0-9_]+/1\\.0\\.0-$engine/',
    ).hasMatch(relative)) {
      route = relative.replaceAll(engine, r'$engine');
    } else {
      return null;
    }
    final ShorebirdArtifactCatalog catalog = await _loadCatalog(engine, origins, fetch);
    final ShorebirdCatalogArtifact? artifact = catalog.artifacts[route];
    if (artifact != null) {
      final Uri resolved = artifact.custom
          ? artifact.urlFrom('${origins.artifactStoreUrl}/shorebird')
          : artifact.urlFrom(origins.officialBaseUrl);
      return ShorebirdResolvedDownload(
        url: resolved,
        route: route,
        custom: artifact.custom,
        sha256: artifact.sha256,
        size: artifact.size,
      );
    }
    if (shorebirdRequiresCustomArtifact(route)) {
      throw ShorebirdOriginException(
        'Missing custom artifact: the signed artifact catalog for engine $engine has no $route. '
        'This toolchain did not publish it, and a stock Flutter artifact cannot replace a patched '
        'runtime, SDK or kernel tool. Build and publish this target first.',
      );
    }
    // An unchanged official artifact the catalog does not pin: fetched
    // directly from the official origin at the upstream engine revision,
    // under Flutter's own transport checks.
    return ShorebirdResolvedDownload(
      url: Uri.parse(
        '${origins.officialBaseUrl}/${route.replaceAll(r'$engine', catalog.upstreamEngineRevision)}',
      ),
      route: route,
      custom: false,
    );
  }

  String? _relativeTo(String url, String base) {
    for (final candidate in <String>[base, kShorebirdOfficialStorageUrl]) {
      if (url.startsWith('$candidate/')) {
        return url.substring(candidate.length + 1);
      }
    }
    return null;
  }

  /// The verified catalog cache: `bin/cache/shorebird/artifact-catalog/<engine>/`.
  Directory _cacheDir(String engine) => _fileSystem.directory(
    _fileSystem.path.join(_flutterRoot, 'bin', 'cache', 'shorebird', 'artifact-catalog', engine),
  );

  Future<ShorebirdArtifactCatalog> _loadCatalog(
    String engine,
    ShorebirdArtifactOrigins origins,
    ShorebirdFetch fetch,
  ) async {
    final ShorebirdArtifactCatalog? loaded = _catalog;
    if (loaded != null && loaded.engineRevision == engine) {
      return loaded;
    }
    final File trustFile = _fileSystem.file(
      _fileSystem.path.join(_flutterRoot, 'bin', 'internal', 'shorebird_artifact_trust.json'),
    );
    if (!trustFile.existsSync()) {
      throw ShorebirdOriginException(
        'Missing ${trustFile.path}; this Flutter checkout cannot verify artifact catalogs.',
      );
    }
    final List<int> trust = trustFile.readAsBytesSync();
    List<int>? catalogBytes;
    List<int>? signatureBytes;
    String source;
    final String? explicit = _environment['SHOREBIRD_ARTIFACT_CATALOG'];
    final Directory cache = _cacheDir(engine);
    final File cachedCatalog = cache.childFile(kShorebirdCatalogFileName);
    final File cachedSignature = cache.childFile('$kShorebirdCatalogFileName.sig');
    var fromNetwork = false;
    if (explicit != null && explicit.isNotEmpty) {
      source = explicit;
      final File file = _fileSystem.file(explicit);
      if (!file.existsSync()) {
        throw ShorebirdOriginException(
          'SHOREBIRD_ARTIFACT_CATALOG names a missing file: $explicit',
        );
      }
      catalogBytes = file.readAsBytesSync();
      final File signature = _fileSystem.file('$explicit.sig');
      signatureBytes = signature.existsSync() ? signature.readAsBytesSync() : null;
    } else {
      final Uri catalogUrl = Uri.parse(
        '${origins.artifactStoreUrl}/shorebird/$engine/$kShorebirdCatalogFileName',
      );
      source = catalogUrl.toString();
      try {
        catalogBytes = await fetch(catalogUrl);
        if (catalogBytes != null) {
          signatureBytes = await fetch(Uri.parse('$catalogUrl.sig'));
          fromNetwork = true;
        }
      } on Exception catch (error) {
        // Offline: reuse the last verified catalog for this engine.
        if (cachedCatalog.existsSync()) {
          _warn(
            'Could not reach $catalogUrl ($error); using the cached verified artifact catalog.',
          );
          source = cachedCatalog.path;
          catalogBytes = cachedCatalog.readAsBytesSync();
          signatureBytes = cachedSignature.existsSync() ? cachedSignature.readAsBytesSync() : null;
        } else {
          throw ShorebirdOriginException(
            'Could not fetch the signed artifact catalog for engine $engine from $catalogUrl: $error\n'
            'Custom artifacts resolve only through a verified catalog. Start or configure the custom '
            'artifact store (SHOREBIRD_ARTIFACT_BASE_URL), point SHOREBIRD_ARTIFACT_CATALOG at a local '
            'copy, or opt into SHOREBIRD_ORIGIN_MODE=legacy-mirror with an artifact proxy.',
          );
        }
      }
      if (catalogBytes == null) {
        throw ShorebirdOriginException(
          'No artifact catalog is published for engine $engine at $catalogUrl (HTTP 404). '
          'Publish the signed catalog with the toolchain, or point SHOREBIRD_ARTIFACT_CATALOG at it.',
        );
      }
    }
    final ShorebirdArtifactCatalog catalog;
    final ShorebirdCatalogTrust trustLevel;
    try {
      (catalog, trustLevel) = verifyShorebirdArtifactCatalog(
        catalogBytes: catalogBytes,
        signatureBytes: signatureBytes,
        trustBytes: trust,
        securityProfile: _securityProfile,
        engineRevision: engine,
        allowUnsigned: _environment['SHOREBIRD_ALLOW_UNSIGNED_ARTIFACT_CATALOG'] == '1',
        releaseTrust: _securityProfile == 'hardened' || _securityProfile == 'hardened-diversified'
            ? loadShorebirdReleaseTrust(_environment, _fileSystem)
            : null,
        diversificationProfileId: _securityProfile == 'hardened-diversified'
            ? _environment['SHOREBIRD_DIVERSIFICATION_PROFILE_ID'] ?? ''
            : null,
      );
    } on FormatException catch (error) {
      throw ShorebirdOriginException(
        'Refusing the artifact catalog from $source: ${error.message}',
      );
    } on ShorebirdCatalogException catch (error) {
      throw ShorebirdOriginException('Refusing the artifact catalog from $source: $error');
    }
    if (trustLevel != ShorebirdCatalogTrust.production) {
      _warn(
        'WARNING: the artifact catalog for engine $engine is ${trustLevel.name}'
        '${trustLevel == ShorebirdCatalogTrust.unsigned ? '' : '-signed'} ($source). '
        'It is accepted only because this is a legacy (non-hardened) toolchain. '
        'Never build a production release from it.',
      );
    }
    if (fromNetwork) {
      cache.createSync(recursive: true);
      cachedCatalog.writeAsBytesSync(catalogBytes);
      if (signatureBytes != null) {
        cachedSignature.writeAsBytesSync(signatureBytes);
      } else if (cachedSignature.existsSync()) {
        cachedSignature.deleteSync();
      }
    }
    return _catalog = catalog;
  }
}

/// SHA-256 of [file] as lowercase hex.
String shorebirdFileSha256(File file) => sha256.convert(file.readAsBytesSync()).toString();

/// Open Shorebird: the environment for a Gradle build.
///
/// The Flutter Gradle plugin resolves `io.flutter` Maven coordinates from
/// `FLUTTER_STORAGE_BASE_URL` (default: the open artifact proxy). In split mode
/// that variable names official-compatible artifacts only, which have no
/// coordinate at a custom engine revision, so Gradle keeps the compatibility
/// route until it gets catalog-aware repositories: `SHOREBIRD_MAVEN_BASE_URL`,
/// else the open artifact proxy. Legacy-mirror mode is unchanged.
Map<String, String>? shorebirdGradleEnvironment(
  Map<String, String>? base,
  Map<String, String> processEnvironment,
) {
  final ShorebirdArtifactOrigins origins;
  try {
    origins = ShorebirdArtifactOrigins.fromEnvironment(processEnvironment);
  } on ShorebirdOriginException {
    // Reported by the cache before any build; leave Gradle as configured.
    return base;
  }
  if (origins.mode != ShorebirdOriginMode.split) {
    return base;
  }
  return <String, String>{
    ...?base,
    'FLUTTER_STORAGE_BASE_URL':
        _value(processEnvironment, 'SHOREBIRD_MAVEN_BASE_URL') ?? kShorebirdOpenProxyUrl,
  };
}

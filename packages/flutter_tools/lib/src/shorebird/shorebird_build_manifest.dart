// Copyright 2026 The Open Shorebird Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Signed build manifest for hardened releases (hardening stage P3,
/// shorebird-workspace `docs/HARDENING_CONTRACTS.md` §9; release root of
/// trust from stage P4, contract v2, §10).
///
/// A hardened build appends one final line to the bundled shorebird.yaml:
///
///     shorebird_build_manifest: v2.<b64url(manifest JSON)>.<b64url(Ed25519 signature)>.<b64url(release-trust JSON)>
///
/// A `hardened-diversified` build (stage P5, contract v3, §11) writes the
/// same line with the `v3.` prefix; its manifest also binds
/// `diversification_profile_id`. The signature domain is unchanged.
///
/// The signer is a `build-manifest` key that the release-trust bundle
/// delegates under the release root compiled into the engine, and the
/// manifest binds the digest of those delegations.
///
/// The manifest binds the compiled policy, the SHA-256 of every YAML byte
/// before that line, the measurement of each engine module the build
/// packages, and optional platform package identities. The updater
/// (`updater/library/src/integrity.rs`) verifies it at startup against the
/// release root compiled into the engine. Module measurements follow
/// `updater/library/src/module_measurement.rs`; both are pinned to the same
/// golden values.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' show ArchiveFile, ZipDecoder;
import 'package:crypto/crypto.dart' show sha256;

import '../artifacts.dart';
import '../base/file_system.dart';
import '../build_info.dart';
import 'shorebird_ed25519.dart';
import 'shorebird_release_trust.dart';

/// Path of a PKCS#8 PEM Ed25519 private key that signs the build manifest
/// (`openssl genpkey -algorithm ed25519`): the file signer. A hardened build
/// sets exactly one of this and [kShorebirdBuildManifestSignerEnvVar].
const kShorebirdBuildManifestSigningKeyEnvVar = 'SHOREBIRD_BUILD_MANIFEST_SIGNING_KEY';

/// Path of an external signer executable (the KMS/HSM interface, contract
/// §10): invoked as `<signer> sign --key-id <sha256:..> --message <text>`, it
/// prints the base64 Ed25519 signature of the message bytes. The private key
/// never enters this process.
const kShorebirdBuildManifestSignerEnvVar = 'SHOREBIRD_BUILD_MANIFEST_SIGNER';

/// The `sha256:` key ID the external signer holds (required with
/// [kShorebirdBuildManifestSignerEnvVar]).
const kShorebirdBuildManifestSignerKeyIdEnvVar = 'SHOREBIRD_BUILD_MANIFEST_SIGNER_KEY_ID';

/// Directory where a hardened build writes its release record
/// (`release-record.v2`, one file per distinct manifest) for the CLI.
const kShorebirdBuildManifestRecordDirEnvVar = 'SHOREBIRD_BUILD_MANIFEST_RECORD_DIR';

/// Comma-separated SHA-256 digests of the Android signer certificate(s) the
/// installed APK may carry (`keytool`/Play Console form with colons, or hex).
const kShorebirdAndroidSigningCertEnvVar = 'SHOREBIRD_ANDROID_SIGNING_CERT_SHA256';

/// Comma-separated Apple team identifiers allowed to sign a macOS app.
const kShorebirdAppleTeamIdsEnvVar = 'SHOREBIRD_APPLE_TEAM_IDS';

/// Comma-separated SHA-256 digests (hex, or colon form) of the DER leaf
/// certificate(s) allowed to Authenticode-sign the Windows engine module
/// `flutter_windows.dll` (hardening P6, contract §12).
const kShorebirdWindowsSigningCertEnvVar = 'SHOREBIRD_WINDOWS_SIGNING_CERT_SHA256';

/// JSON array of the absolute paths of the engine jars
/// (`io.flutter:<abi>_release`) that Gradle resolved for the variant being
/// built, each carrying `lib/<abi>/libflutter.so`. The Flutter Gradle
/// plugin sets it for hardened builds only (hardening P6, contract §12):
/// these are the exact libraries the APK or app bundle packages.
const kShorebirdAndroidEngineJarsEnvVar = 'SHOREBIRD_ANDROID_ENGINE_JARS';

const kShorebirdBuildManifestKey = 'shorebird_build_manifest';
const _kTokenPrefix = 'v2.';
const _kDiversifiedTokenPrefix = 'v3.';
const kShorebirdBuildManifestSignatureDomain = 'open-shorebird.build-manifest-signature.v2:';
const _kContractVersion = 2;
const _kDiversifiedContractVersion = 3;
const _kManifestSchema = 'open-shorebird.build-manifest';
const _kMeasurementDomain = 'open-shorebird.module-measurement.v1\u0000';

/// One engine module binding.
class ShorebirdModuleMeasurement {
  const ShorebirdModuleMeasurement(this.platform, this.arch, this.measurement);

  /// Updater platform name: android, ios, linux, macos or windows.
  final String platform;

  /// Updater arch name: aarch64, arm, x86 or x86_64.
  final String arch;

  /// `sha256:<hex>`.
  final String measurement;

  Map<String, String> toJson() => <String, String>{
    'platform': platform,
    'arch': arch,
    'measurement': measurement,
  };
}

class _Measurer {
  _Measurer(String format) {
    _bytes.add(utf8.encode(_kMeasurementDomain));
    _bytes.add(utf8.encode('$format\u0000'));
  }

  final _bytes = BytesBuilder(copy: false);
  int _regions = 0;

  void region(List<int> label, int address, Uint8List bytes) {
    final padded = Uint8List(32)..setRange(0, label.length.clamp(0, 32), label);
    _bytes
      ..add(padded)
      ..add(_u64(address))
      ..add(_u64(bytes.length))
      ..add(bytes);
    _regions++;
  }

  String finish() {
    if (_regions == 0) {
      throw const FormatException('Module has no measurable region');
    }
    return 'sha256:${sha256.convert(_bytes.takeBytes())}';
  }

  static Uint8List _u64(int value) =>
      Uint8List(8)..buffer.asByteData().setUint64(0, value, Endian.little);
}

class _Reader {
  _Reader(this.bytes) : _data = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData _data;

  void _check(int offset, int length) {
    if (offset < 0 || length < 0 || offset + length > bytes.length) {
      throw const FormatException('Module image is truncated');
    }
  }

  int u16(int offset) {
    _check(offset, 2);
    return _data.getUint16(offset, Endian.little);
  }

  int u32(int offset, [Endian endian = Endian.little]) {
    _check(offset, 4);
    return _data.getUint32(offset, endian);
  }

  int u64(int offset) {
    _check(offset, 8);
    return _data.getUint64(offset, Endian.little);
  }

  Uint8List slice(int offset, int length) {
    _check(offset, length);
    return Uint8List.sublistView(bytes, offset, offset + length);
  }
}

String _measureElf(Uint8List image) {
  final r = _Reader(image);
  if (image.length < 0x34 || image[5] != 1) {
    throw const FormatException('Unsupported ELF image');
  }
  final bool is64 = switch (image[4]) {
    1 => false,
    2 => true,
    _ => throw const FormatException('Unsupported ELF class'),
  };
  final int phoff = is64 ? r.u64(0x20) : r.u32(0x1c);
  final int phentsize = r.u16(is64 ? 0x36 : 0x2a);
  final int phnum = r.u16(is64 ? 0x38 : 0x2c);
  if (phentsize != (is64 ? 56 : 32) || phnum == 0xffff) {
    throw const FormatException('Unsupported ELF program headers');
  }
  final m = _Measurer(is64 ? 'elf64' : 'elf32');
  for (var i = 0; i < phnum; i++) {
    final int at = phoff + i * phentsize;
    final int type = r.u32(at);
    final int flags = is64 ? r.u32(at + 4) : r.u32(at + 24);
    final int offset = is64 ? r.u64(at + 8) : r.u32(at + 4);
    final int vaddr = is64 ? r.u64(at + 16) : r.u32(at + 8);
    final int filesz = is64 ? r.u64(at + 32) : r.u32(at + 16);
    // PT_LOAD without PF_W.
    if (type == 1 && flags & 2 == 0 && filesz > 0) {
      m.region(const <int>[], vaddr, r.slice(offset, filesz));
    }
  }
  return m.finish();
}

const _kMhMagic64 = 0xfeedfacf;

/// Measures one thin 64-bit Mach-O image; returns (cputype, measurement).
(int, String) _measureMachO(Uint8List image) {
  final r = _Reader(image);
  if (r.u32(0) != _kMhMagic64) {
    throw const FormatException('Unsupported Mach-O image');
  }
  final int cputype = r.u32(4);
  final int ncmds = r.u32(16);
  final int end = 32 + r.u32(20);
  r.slice(32, end - 32);
  final m = _Measurer('macho64');
  var at = 32;
  for (var i = 0; i < ncmds; i++) {
    final int cmd = r.u32(at);
    final int cmdsize = r.u32(at + 4);
    if (cmdsize < 8 || at + cmdsize > end) {
      throw const FormatException('Module image is truncated');
    }
    if (cmd == 0x19) {
      if (cmdsize < 72) {
        throw const FormatException('Module image is truncated');
      }
      final Uint8List segname = r.slice(at + 8, 16);
      final int initprot = r.u32(at + 60);
      final int nsects = r.u32(at + 64);
      if (72 + nsects * 80 > cmdsize) {
        throw const FormatException('Module image is truncated');
      }
      final linkedit = ascii.decode(segname.takeWhile((int b) => b != 0).toList()) == '__LINKEDIT';
      if (initprot & 2 == 0 && !linkedit) {
        for (var s = 0; s < nsects; s++) {
          final int sect = at + 72 + s * 80;
          final int kind = r.u32(sect + 64) & 0xff;
          final int size = r.u64(sect + 40);
          if (size == 0 || kind == 0x1 || kind == 0xc || kind == 0x12) {
            continue;
          }
          m.region(
            <int>[...segname, ...r.slice(sect, 16)],
            r.u64(sect + 32),
            r.slice(r.u32(sect + 48), size),
          );
        }
      }
    }
    at += cmdsize;
  }
  return (cputype, m.finish());
}

String _measurePe(Uint8List image) {
  final r = _Reader(image);
  if (image.length < 0x40 || image[0] != 0x4d || image[1] != 0x5a) {
    throw const FormatException('Unsupported PE image');
  }
  final int pe = r.u32(0x3c);
  if (r.u32(pe) != 0x00004550) {
    throw const FormatException('Unsupported PE image');
  }
  final int count = r.u16(pe + 6);
  final int table = pe + 24 + r.u16(pe + 20);
  final m = _Measurer('pe');
  for (var i = 0; i < count; i++) {
    final int s = table + i * 40;
    final int characteristics = r.u32(s + 36);
    final int rawSize = r.u32(s + 16);
    if (characteristics & 0x80000000 != 0 || rawSize == 0) {
      continue;
    }
    m.region(r.slice(s, 8), r.u32(s + 12), r.slice(r.u32(s + 20), rawSize));
  }
  return m.finish();
}

/// Measures an ELF, thin 64-bit Mach-O or PE file image.
String measureShorebirdModuleImage(Uint8List image) {
  if (image.length >= 4 &&
      image[0] == 0x7f &&
      image[1] == 0x45 &&
      image[2] == 0x4c &&
      image[3] == 0x46) {
    return _measureElf(image);
  }
  if (image.length >= 4 && _Reader(image).u32(0) == _kMhMagic64) {
    return _measureMachO(image).$2;
  }
  if (image.length >= 2 && image[0] == 0x4d && image[1] == 0x5a) {
    return _measurePe(image);
  }
  throw const FormatException('Unsupported module format');
}

String? _machOArch(int cputype) => switch (cputype) {
  0x0100000c => 'aarch64',
  0x01000007 => 'x86_64',
  _ => null,
};

/// Measures each architecture of a (possibly universal) Mach-O file.
Map<String, String> measureShorebirdMachOArchitectures(Uint8List image) {
  final r = _Reader(image);
  final int magic = image.length >= 4 ? r.u32(0, Endian.big) : 0;
  final slices = <Uint8List>[];
  if (magic == 0xcafebabe || magic == 0xcafebabf) {
    final fat64 = magic == 0xcafebabf;
    final int count = r.u32(4, Endian.big);
    for (var i = 0; i < count; i++) {
      final int at = 8 + i * (fat64 ? 32 : 20);
      final data = ByteData.sublistView(r.slice(at, fat64 ? 32 : 20));
      final int offset = fat64 ? data.getUint64(8) : data.getUint32(8);
      final int size = fat64 ? data.getUint64(16) : data.getUint32(12);
      slices.add(r.slice(offset, size));
    }
  } else {
    slices.add(image);
  }
  final measurements = <String, String>{};
  for (final slice in slices) {
    final (int cputype, String measurement) = _measureMachO(slice);
    final String? arch = _machOArch(cputype);
    if (arch != null) {
      measurements[arch] = measurement;
    }
  }
  if (measurements.isEmpty) {
    throw const FormatException('No supported Mach-O architecture');
  }
  return measurements;
}

/// Updater arch name of an Android ABI directory.
const _kAndroidAbiArches = <String, String>{
  'arm64-v8a': 'aarch64',
  'armeabi-v7a': 'arm',
  'x86_64': 'x86_64',
  'x86': 'x86',
};

final _kAndroidEngineLibrary = RegExp(r'^lib/([^/]+)/libflutter\.so$');

/// The `libflutter.so` measurements of the Android engine jars listed in
/// [jars] (the [kShorebirdAndroidEngineJarsEnvVar] value), one per ABI,
/// sorted by arch. Every jar must carry exactly one engine library, and no
/// ABI may appear twice.
List<ShorebirdModuleMeasurement> shorebirdAndroidEngineModuleMeasurements(
  String? jars,
  FileSystem fileSystem,
) {
  if (jars == null || jars.trim().isEmpty) {
    throw const FormatException(
      'A hardened Android build binds the libflutter.so that Gradle packages, but '
      '$kShorebirdAndroidEngineJarsEnvVar is not set; build through the Flutter Gradle plugin '
      'of this toolchain',
    );
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(jars);
  } on FormatException {
    throw const FormatException('$kShorebirdAndroidEngineJarsEnvVar must be a JSON array of paths');
  }
  if (decoded is! List<Object?> || decoded.isEmpty || decoded.any((Object? p) => p is! String)) {
    throw const FormatException(
      '$kShorebirdAndroidEngineJarsEnvVar must be a non-empty JSON array of paths',
    );
  }
  final measurements = <String, String>{};
  for (final String path in decoded.cast<String>()) {
    final File jar = fileSystem.file(path);
    if (!jar.existsSync()) {
      throw FormatException('Hardened build cannot measure the engine module: $path is missing');
    }
    final libraries = <ArchiveFile>[
      for (final ArchiveFile entry in ZipDecoder().decodeBytes(jar.readAsBytesSync()).files)
        if (entry.isFile && _kAndroidEngineLibrary.hasMatch(entry.name)) entry,
    ];
    if (libraries.length != 1) {
      throw FormatException(
        '$path must carry exactly one lib/<abi>/libflutter.so, not ${libraries.length}',
      );
    }
    final String abi = _kAndroidEngineLibrary.firstMatch(libraries.single.name)!.group(1)!;
    final String? arch = _kAndroidAbiArches[abi];
    if (arch == null) {
      throw FormatException('$path carries an engine for the unsupported ABI $abi');
    }
    if (measurements.containsKey(arch)) {
      throw FormatException('Two engine jars carry a libflutter.so for $abi');
    }
    measurements[arch] = measureShorebirdModuleImage(
      Uint8List.fromList(libraries.single.content as List<int>),
    );
  }
  return <ShorebirdModuleMeasurement>[
    for (final String arch in measurements.keys.toList()..sort())
      ShorebirdModuleMeasurement('android', arch, measurements[arch]!),
  ];
}

/// The `FlutterMacOS` binary inside [xcframework]: the universal slice of a
/// published engine (`macos-arm64_x86_64`), or the one slice of a
/// single-architecture local engine build.
String _macOSFrameworkBinary(FileSystem fileSystem, String xcframework) {
  const binary = 'FlutterMacOS.framework/Versions/A/FlutterMacOS';
  final String universal = fileSystem.path.join(xcframework, 'macos-arm64_x86_64', binary);
  if (fileSystem.file(universal).existsSync()) {
    return universal;
  }
  final Directory directory = fileSystem.directory(xcframework);
  final slices = directory.existsSync()
      ? <String>[
          for (final FileSystemEntity entity in directory.listSync())
            if (entity is Directory &&
                fileSystem.path.basename(entity.path).startsWith('macos-') &&
                fileSystem.file(fileSystem.path.join(entity.path, binary)).existsSync())
              fileSystem.path.join(entity.path, binary),
        ]
      : <String>[];
  if (slices.length == 1) {
    return slices.single;
  }
  // Reported as missing by the caller.
  return universal;
}

/// The engine modules a hardened build of [targetPlatform] packages, measured
/// from the engine artifacts this build uses. Android measures the engine
/// jars Gradle resolved ([kShorebirdAndroidEngineJarsEnvVar] in
/// [environment]), since its engine library reaches the app through Gradle's
/// Maven resolution rather than the Flutter artifact cache (P6).
List<ShorebirdModuleMeasurement> shorebirdEngineModuleMeasurements({
  required Artifacts artifacts,
  required FileSystem fileSystem,
  required TargetPlatform targetPlatform,
  required BuildMode buildMode,
  Map<String, String> environment = const <String, String>{},
}) {
  Uint8List read(String path) {
    final File file = fileSystem.file(path);
    if (!file.existsSync()) {
      throw FormatException('Hardened build cannot measure the engine module: $path is missing');
    }
    return file.readAsBytesSync();
  }

  String path(Artifact artifact, String relative) => fileSystem.path.join(
    artifacts.getArtifactPath(artifact, platform: targetPlatform, mode: buildMode),
    relative,
  );

  switch (targetPlatform) {
    case TargetPlatform.ios:
      return <ShorebirdModuleMeasurement>[
        ShorebirdModuleMeasurement(
          'ios',
          'aarch64',
          measureShorebirdModuleImage(
            read(path(Artifact.flutterXcframework, 'ios-arm64/Flutter.framework/Flutter')),
          ),
        ),
      ];
    case TargetPlatform.darwin:
      final Map<String, String> slices = measureShorebirdMachOArchitectures(
        read(
          _macOSFrameworkBinary(
            fileSystem,
            artifacts.getArtifactPath(
              Artifact.flutterMacOSXcframework,
              platform: targetPlatform,
              mode: buildMode,
            ),
          ),
        ),
      );
      return <ShorebirdModuleMeasurement>[
        for (final MapEntry<String, String> slice in slices.entries)
          ShorebirdModuleMeasurement('macos', slice.key, slice.value),
      ];
    case TargetPlatform.windows_x64:
    case TargetPlatform.windows_arm64:
      return <ShorebirdModuleMeasurement>[
        ShorebirdModuleMeasurement(
          'windows',
          targetPlatform == TargetPlatform.windows_x64 ? 'x86_64' : 'aarch64',
          measureShorebirdModuleImage(
            read(path(Artifact.windowsDesktopPath, 'flutter_windows.dll')),
          ),
        ),
      ];
    case TargetPlatform.linux_x64:
    case TargetPlatform.linux_arm64:
      return <ShorebirdModuleMeasurement>[
        ShorebirdModuleMeasurement(
          'linux',
          targetPlatform == TargetPlatform.linux_x64 ? 'x86_64' : 'aarch64',
          measureShorebirdModuleImage(
            read(path(Artifact.linuxDesktopPath, 'libflutter_linux_gtk.so')),
          ),
        ),
      ];
    case TargetPlatform.android:
    case TargetPlatform.android_arm:
    case TargetPlatform.android_arm64:
    case TargetPlatform.android_x64:
      return shorebirdAndroidEngineModuleMeasurements(
        environment[kShorebirdAndroidEngineJarsEnvVar],
        fileSystem,
      );
    case TargetPlatform.linux_riscv64:
    case TargetPlatform.fuchsia_arm64:
    case TargetPlatform.fuchsia_x64:
    case TargetPlatform.tester:
    case TargetPlatform.web_javascript:
    case TargetPlatform.unsupported:
      throw FormatException(
        'The hardened security profile does not support ${targetPlatform.getName()}',
      );
  }
}

/// The 32-byte Ed25519 seed of a PKCS#8 PEM private key, as written by
/// `openssl genpkey -algorithm ed25519`.
List<int> parseShorebirdEd25519PrivateKeyPem(String pem) {
  final RegExpMatch? match = RegExp(
    r'^-----BEGIN PRIVATE KEY-----\s+([A-Za-z0-9+/=\s]+?)\s*-----END PRIVATE KEY-----\s*$',
  ).firstMatch(pem.trim());
  if (match == null) {
    throw const FormatException('The build-manifest signing key is not a PKCS#8 PEM private key');
  }
  final List<int> der;
  try {
    der = base64.decode(match.group(1)!.replaceAll(RegExp(r'\s'), ''));
  } on FormatException {
    throw const FormatException('The build-manifest signing key is not valid base64');
  }
  const prefix = <int>[
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
  ];
  if (der.length != prefix.length + 32 ||
      !List<int>.generate(
        prefix.length,
        (int i) => der[i],
      ).asMap().entries.every((MapEntry<int, int> e) => e.value == prefix[e.key])) {
    throw const FormatException('The build-manifest signing key is not an Ed25519 key');
  }
  return der.sublist(prefix.length);
}

/// `sha256:` over a raw 32-byte Ed25519 public key.
String shorebirdEd25519KeyId(List<int> publicKey) => 'sha256:${sha256.convert(publicKey)}';

List<String> _list(String? value) =>
    (value ?? '').split(',').map((String v) => v.trim()).where((String v) => v.isNotEmpty).toList();

/// Normalizes `AB:CD:…` (keytool, Play Console) or hex to lowercase hex.
List<String> shorebirdAndroidSigningCerts(String? value) {
  final certs = <String>[];
  for (final String raw in _list(value)) {
    final String hex = raw.replaceAll(':', '').toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hex)) {
      throw FormatException('$kShorebirdAndroidSigningCertEnvVar entry is not a SHA-256: $raw');
    }
    if (!certs.contains(hex)) {
      certs.add(hex);
    }
  }
  return certs;
}

/// Normalizes the [kShorebirdWindowsSigningCertEnvVar] list like
/// [shorebirdAndroidSigningCerts].
List<String> shorebirdWindowsSigningCerts(String? value) {
  final certs = <String>[];
  for (final String raw in _list(value)) {
    final String hex = raw.replaceAll(':', '').toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hex)) {
      throw FormatException('$kShorebirdWindowsSigningCertEnvVar entry is not a SHA-256: $raw');
    }
    if (!certs.contains(hex)) {
      certs.add(hex);
    }
  }
  return certs;
}

List<String> shorebirdAppleTeamIds(String? value) {
  final ids = <String>[];
  for (final String id in _list(value)) {
    if (!RegExp(r'^[A-Z0-9]{10}$').hasMatch(id)) {
      throw FormatException('$kShorebirdAppleTeamIdsEnvVar entry is not a team identifier: $id');
    }
    if (!ids.contains(id)) {
      ids.add(id);
    }
  }
  return ids;
}

String _b64url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

/// Signs build-manifest messages with the key [keyId].
abstract class ShorebirdBuildManifestSigner {
  /// The `sha256:` ID of the public key.
  String get keyId;

  /// The 64-byte Ed25519 signature of [message].
  List<int> sign(List<int> message);
}

/// Signs in process with a 32-byte seed (a PEM file on a build machine the
/// signer controls; not constant time).
class ShorebirdSeedManifestSigner implements ShorebirdBuildManifestSigner {
  ShorebirdSeedManifestSigner(this._seed) : keyId = shorebirdEd25519KeyId(ed25519PublicKey(_seed));

  final List<int> _seed;

  @override
  final String keyId;

  @override
  List<int> sign(List<int> message) => ed25519Sign(_seed, message);
}

/// Signs through an external signer (KMS/HSM adapter); [run] executes
/// `argv` and returns its standard output, throwing on failure.
class ShorebirdCommandManifestSigner implements ShorebirdBuildManifestSigner {
  ShorebirdCommandManifestSigner(this.executable, this.keyId, this.run);

  final String executable;

  @override
  final String keyId;
  final String Function(List<String> argv) run;

  @override
  List<int> sign(List<int> message) {
    final String output = run(<String>[
      executable,
      'sign',
      '--key-id',
      keyId,
      '--message',
      ascii.decode(message),
    ]).trim();
    try {
      final List<int> signature = base64.decode(output);
      if (signature.length == 64) {
        return signature;
      }
    } on FormatException {
      // Reported below.
    }
    throw FormatException(
      'The build-manifest signer $executable did not print a base64 Ed25519 signature',
    );
  }
}

/// Appends the signed manifest line to [config], the complete hardened YAML
/// text as written (must end with `\n`, contain no `\r`, and not mention the
/// manifest key). [signer] must hold a `build-manifest` key delegated by
/// [trust]; the signature is verified before anything is returned. Returns
/// the final file contents.
///
/// A non-null [diversificationProfileId] makes it the contract v3
/// (`hardened-diversified`) manifest and `v3.` token; otherwise the output is
/// the contract v2 hardened line, unchanged.
String appendShorebirdBuildManifest(
  String config, {
  required ShorebirdBuildManifestSigner signer,
  required ShorebirdReleaseTrust trust,
  required String toolchainId,
  required bool developmentExceptions,
  required List<ShorebirdModuleMeasurement> modules,
  required TargetPlatform targetPlatform,
  List<String> androidSigningCerts = const <String>[],
  List<String> appleTeamIds = const <String>[],
  List<String> windowsSigningCerts = const <String>[],
  String? diversificationProfileId,
}) {
  final diversified = diversificationProfileId != null;
  if (diversified && !RegExp(r'^sha256:[0-9a-f]{64}$').hasMatch(diversificationProfileId)) {
    throw const FormatException('diversification_profile_id must be sha256:<64 lowercase hex>');
  }
  if (!config.endsWith('\n') ||
      config.contains('\r') ||
      config.contains(kShorebirdBuildManifestKey)) {
    throw const FormatException('Hardened shorebird.yaml cannot carry a build manifest');
  }
  final bool android = targetPlatform.getName().startsWith('android');
  if (androidSigningCerts.isNotEmpty && !android) {
    throw FormatException(
      '$kShorebirdAndroidSigningCertEnvVar applies only to Android builds, not '
      '${targetPlatform.getName()}',
    );
  }
  // The updater verifies a team identifier only on macOS; iOS has no public
  // API for it and would fail closed, so a build never declares one there.
  if (appleTeamIds.isNotEmpty && targetPlatform != TargetPlatform.darwin) {
    throw FormatException(
      '$kShorebirdAppleTeamIdsEnvVar applies only to macOS builds, not ${targetPlatform.getName()}',
    );
  }
  if (windowsSigningCerts.isNotEmpty &&
      targetPlatform != TargetPlatform.windows_x64 &&
      targetPlatform != TargetPlatform.windows_arm64) {
    throw FormatException(
      '$kShorebirdWindowsSigningCertEnvVar applies only to Windows builds, not '
      '${targetPlatform.getName()}',
    );
  }
  final List<int> publicKey = trust.roleKey(ShorebirdSigningRole.buildManifest, signer.keyId);
  // Field order is fixed for reproducible output; the signature covers the
  // exact bytes, so the order carries no meaning to the verifier.
  final String manifest = jsonEncode(<String, Object>{
    'schema': _kManifestSchema,
    'contract_version': diversified ? _kDiversifiedContractVersion : _kContractVersion,
    'security_profile': diversified ? 'hardened-diversified' : 'hardened',
    'toolchain_id': toolchainId,
    'development_exceptions': developmentExceptions,
    if (diversified) 'diversification_profile_id': diversificationProfileId,
    'signer_key_id': signer.keyId,
    'delegations_sha256': trust.delegationsSha256,
    'config_sha256': sha256.convert(utf8.encode(config)).toString(),
    'modules': <Map<String, String>>[
      for (final ShorebirdModuleMeasurement module in modules) module.toJson(),
    ],
    'package_identity': <String, List<String>>{
      'android_signing_cert_sha256': androidSigningCerts,
      'apple_team_ids': appleTeamIds,
      // Contract §12 (P6): written only when declared, so every manifest
      // without a Windows identity keeps its pre-P6 bytes.
      if (windowsSigningCerts.isNotEmpty) 'windows_signing_cert_sha256': windowsSigningCerts,
    },
  });
  final List<int> manifestBytes = utf8.encode(manifest);
  final List<int> message = utf8.encode(
    '$kShorebirdBuildManifestSignatureDomain${sha256.convert(manifestBytes)}',
  );
  final List<int> signature = signer.sign(message);
  if (!ed25519Verify(publicKey, message, signature)) {
    throw FormatException(
      'The build-manifest signature does not verify under the delegated key ${signer.keyId}',
    );
  }
  final String prefix = diversified ? _kDiversifiedTokenPrefix : _kTokenPrefix;
  return '$config$kShorebirdBuildManifestKey: '
      '$prefix${_b64url(manifestBytes)}.${_b64url(signature)}.'
      '${_b64url(utf8.encode(trust.compactBundle))}\n';
}

/// The release record describing the manifest in [text] (the final hardened
/// shorebird.yaml), which the CLI stores with the release:
/// `release-record.v2` for a hardened manifest, `release-record.v3` (v2 plus
/// `diversification_profile_id`) for a hardened-diversified one.
Map<String, Object?> shorebirdReleaseRecord(String text, ShorebirdReleaseTrust trust) {
  final String line = text.trimRight().split('\n').last;
  final String token = line.substring('$kShorebirdBuildManifestKey: '.length);
  final List<int> manifestBytes = base64Url.decode(base64Url.normalize(token.split('.')[1]));
  final manifest = jsonDecode(utf8.decode(manifestBytes)) as Map<String, Object?>;
  final diversified = manifest['contract_version'] == _kDiversifiedContractVersion;
  return <String, Object?>{
    'schema': 'open-shorebird.release-record',
    'contract_version': diversified ? _kDiversifiedContractVersion : _kContractVersion,
    'security_profile': diversified ? 'hardened-diversified' : 'hardened',
    if (diversified) 'diversification_profile_id': manifest['diversification_profile_id'],
    'toolchain_id': manifest['toolchain_id'],
    'development_exceptions': manifest['development_exceptions'],
    'release_root_sha256': trust.rootSha256,
    'root_version': trust.rootVersion,
    'delegations_version': trust.delegationsVersion,
    'delegations_sha256': trust.delegationsSha256,
    'build_manifests': <Object>[
      <String, Object?>{
        'manifest_sha256': sha256.convert(manifestBytes).toString(),
        'signer_key_id': manifest['signer_key_id'],
        'config_sha256': manifest['config_sha256'],
        'modules': manifest['modules'],
      },
    ],
  };
}

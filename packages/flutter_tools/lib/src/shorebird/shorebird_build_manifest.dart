// Copyright 2026 The Open Shorebird Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Signed build manifest for hardened releases (hardening stage P3,
/// shorebird-workspace `docs/HARDENING_CONTRACTS.md` §9).
///
/// A hardened build appends one final line to the bundled shorebird.yaml:
///
///     shorebird_build_manifest: v1.<base64url(manifest JSON)>.<base64url(Ed25519 signature)>
///
/// The manifest binds the compiled policy, the SHA-256 of every YAML byte
/// before that line, the measurement of each engine module the build
/// packages, and optional platform package identities. The updater
/// (`updater/library/src/integrity.rs`) verifies it at startup against the
/// build-manifest keys compiled into the engine. Module measurements follow
/// `updater/library/src/module_measurement.rs`; both are pinned to the same
/// golden values.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;

import '../artifacts.dart';
import '../base/file_system.dart';
import '../build_info.dart';
import 'shorebird_ed25519.dart';

/// Path of a PKCS#8 PEM Ed25519 private key that signs the build manifest
/// (`openssl genpkey -algorithm ed25519`). Required for hardened builds.
const kShorebirdBuildManifestSigningKeyEnvVar = 'SHOREBIRD_BUILD_MANIFEST_SIGNING_KEY';

/// Comma-separated SHA-256 digests of the Android signer certificate(s) the
/// installed APK may carry (`keytool`/Play Console form with colons, or hex).
const kShorebirdAndroidSigningCertEnvVar = 'SHOREBIRD_ANDROID_SIGNING_CERT_SHA256';

/// Comma-separated Apple team identifiers allowed to sign a macOS app.
const kShorebirdAppleTeamIdsEnvVar = 'SHOREBIRD_APPLE_TEAM_IDS';

const kShorebirdBuildManifestKey = 'shorebird_build_manifest';
const _kTokenPrefix = 'v1.';
const _kSignatureDomain = 'open-shorebird.build-manifest-signature.v1:';
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

/// The engine modules a hardened build of [targetPlatform] packages, measured
/// from the engine artifacts this build uses. Android returns none: its
/// engine library reaches the app through Gradle (P6), and the updater binds
/// the APK signer instead.
List<ShorebirdModuleMeasurement> shorebirdEngineModuleMeasurements({
  required Artifacts artifacts,
  required FileSystem fileSystem,
  required TargetPlatform targetPlatform,
  required BuildMode buildMode,
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
          path(
            Artifact.flutterMacOSXcframework,
            'macos-arm64_x86_64/FlutterMacOS.framework/Versions/A/FlutterMacOS',
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
      return const <ShorebirdModuleMeasurement>[];
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

/// Appends the signed manifest line to [config], the complete hardened YAML
/// text as written (must end with `\n`, contain no `\r`, and not mention the
/// manifest key). Returns the final file contents.
String appendShorebirdBuildManifest(
  String config, {
  required List<int> signingSeed,
  required String toolchainId,
  required bool developmentExceptions,
  required List<ShorebirdModuleMeasurement> modules,
  required TargetPlatform targetPlatform,
  List<String> androidSigningCerts = const <String>[],
  List<String> appleTeamIds = const <String>[],
}) {
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
  final List<int> publicKey = ed25519PublicKey(signingSeed);
  // Field order is fixed for reproducible output; the signature covers the
  // exact bytes, so the order carries no meaning to the verifier.
  final String manifest = jsonEncode(<String, Object>{
    'schema': _kManifestSchema,
    'contract_version': 1,
    'security_profile': 'hardened',
    'toolchain_id': toolchainId,
    'development_exceptions': developmentExceptions,
    'signer_key_id': shorebirdEd25519KeyId(publicKey),
    'config_sha256': sha256.convert(utf8.encode(config)).toString(),
    'modules': <Map<String, String>>[
      for (final ShorebirdModuleMeasurement module in modules) module.toJson(),
    ],
    'package_identity': <String, List<String>>{
      'android_signing_cert_sha256': androidSigningCerts,
      'apple_team_ids': appleTeamIds,
    },
  });
  final List<int> manifestBytes = utf8.encode(manifest);
  final List<int> signature = ed25519Sign(
    signingSeed,
    utf8.encode('$_kSignatureDomain${sha256.convert(manifestBytes)}'),
  );
  return '$config$kShorebirdBuildManifestKey: '
      '$_kTokenPrefix${_b64url(manifestBytes)}.${_b64url(signature)}\n';
}

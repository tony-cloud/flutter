// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../base/file_system.dart';

/// The exact release wrapper used by the native compiler and asset bundle.
const kShorebirdReplacementBaseEnvVar = 'SHOREBIRD_AOT_REPLACEMENT_BASE';

/// A trusted builder's digest of the frozen host artifacts and build settings.
const kShorebirdHostAbiEnvVar = 'SHOREBIRD_AOT_HOST_ABI';

/// Public asset name; private build paths never enter the compiled YAML.
const kShorebirdReplacementBaseAsset = 'shorebird_replacement_base.sbr';

/// Validated immutable inputs shared by compilation and bundling.
class ShorebirdReplacementInputs {
  ShorebirdReplacementInputs._(this.base, this.hostAbi, this.snapshotHash);

  /// Validates the wrapper binding. The SDK compiler validates the full domain.
  factory ShorebirdReplacementInputs.read(FileSystem fileSystem, Map<String, String> environment) {
    final String? path = environment[kShorebirdReplacementBaseEnvVar];
    if (path == null || !fileSystem.path.isAbsolute(path) || !fileSystem.file(path).existsSync()) {
      throw const FormatException(
        'SHOREBIRD_AOT_REPLACEMENT_BASE must name an absolute existing base wrapper file',
      );
    }
    String digest(String key) {
      final String? value = environment[key];
      if (value == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
        throw FormatException('$key must be a lowercase SHA-256');
      }
      return value;
    }

    final String hostAbi = digest(kShorebirdHostAbiEnvVar);
    final String snapshotHash = digest('SHOREBIRD_AOT_BASE_SNAPSHOT_HASH');
    final File base = fileSystem.file(path);
    if (base.lengthSync() > 24 + 4 * 1024 * 1024 + 128 * 1024 * 1024) {
      throw const FormatException('Replacement base wrapper exceeds size limit');
    }
    final Uint8List bytes = base.readAsBytesSync();
    if (sha256.convert(bytes).toString() != snapshotHash) {
      throw const FormatException(
        'Replacement base wrapper SHA-256 does not match the release hash',
      );
    }
    // Version 1 has a 24-byte header followed by a manifest containing policy,
    // host ABI, baseline digest and current digest. Reject an update as a base.
    if (bytes.length < 124 || String.fromCharCodes(bytes.take(8)) != 'SBRPLCE\u0000') {
      throw const FormatException('Invalid replacement base wrapper');
    }
    final header = ByteData.sublistView(bytes);
    final int manifestLength = header.getUint32(12, Endian.little);
    final int componentLength = header.getUint32(16, Endian.little);
    if (header.getUint32(8, Endian.little) != 1 ||
        header.getUint32(20, Endian.little) != 0 ||
        manifestLength < 116 ||
        manifestLength > 4 * 1024 * 1024 ||
        componentLength < 8 ||
        componentLength > 128 * 1024 * 1024 ||
        24 + manifestLength + componentLength != bytes.length ||
        header.getUint32(24, Endian.little) != 1) {
      throw const FormatException('Invalid replacement base wrapper lengths or version');
    }
    if (header.getUint32(24 + manifestLength, Endian.little) != 0x44424333) {
      throw const FormatException('Replacement base must contain a DBC3 component');
    }
    String hex(Iterable<int> values) =>
        values.map((int value) => value.toRadixString(16).padLeft(2, '0')).join();
    final componentHash = sha256.convert(bytes.sublist(24 + manifestLength)).toString();
    if (hex(bytes.sublist(28, 60)) != hostAbi ||
        hex(bytes.sublist(60, 92)) != componentHash ||
        hex(bytes.sublist(92, 124)) != componentHash) {
      throw const FormatException('Replacement base host ABI or component digest mismatch');
    }
    return ShorebirdReplacementInputs._(base, hostAbi, snapshotHash);
  }

  final File base;
  final String hostAbi;
  final String snapshotHash;

  /// Compiler options binding the native baseline to the exact bundled bytes.
  List<String> get frontendOptions => <String>[
    '--shorebird-full-replacement',
    '--shorebird-replacement-base=${base.path}',
    '--shorebird-host-abi=$hostAbi',
  ];

  /// Public values hashed into build stamps, including same-path byte changes.
  Map<String, String> get buildKey => <String, String>{
    kShorebirdReplacementBaseEnvVar: base.path,
    kShorebirdHostAbiEnvVar: hostAbi,
    'shorebirdReplacementBaseSha256': snapshotHash,
  };
}

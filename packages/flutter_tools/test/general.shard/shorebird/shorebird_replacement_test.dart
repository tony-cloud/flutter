// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/shorebird/shorebird_replacement.dart';
import 'package:flutter_tools/src/shorebird/shorebird_yaml.dart';

import '../../src/common.dart';
import '../../src/shorebird_replacement.dart';

void main() {
  testWithoutContext('validates exact wrapper and compiler binding', () {
    final fileSystem = MemoryFileSystem.test();
    final Map<String, String> environment = writeShorebirdReplacementBase(fileSystem);
    final inputs = ShorebirdReplacementInputs.read(fileSystem, environment);
    expect(inputs.frontendOptions, <String>[
      '--shorebird-full-replacement',
      '--shorebird-replacement-base=/private/base.sbr',
      '--shorebird-host-abi=${environment[kShorebirdHostAbiEnvVar]}',
    ]);
    for (final entry in <MapEntry<String, String>>[
      const MapEntry<String, String>(kShorebirdReplacementBaseEnvVar, 'relative.sbr'),
      const MapEntry<String, String>(kShorebirdReplacementBaseEnvVar, '/missing.sbr'),
      MapEntry<String, String>(kShorebirdHostAbiEnvVar, 'A' * 64),
      MapEntry<String, String>(kShorebirdHostAbiEnvVar, 'b' * 64),
      MapEntry<String, String>(kShorebirdAotBaseSnapshotHashEnvVar, 'b' * 64),
    ]) {
      expect(
        () => ShorebirdReplacementInputs.read(fileSystem, <String, String>{
          ...environment,
          entry.key: entry.value,
        }),
        throwsFormatException,
      );
    }
    for (final String key in environment.keys) {
      expect(
        () => ShorebirdReplacementInputs.read(
          fileSystem,
          <String, String>{...environment}..remove(key),
        ),
        throwsFormatException,
      );
    }
  });
  testWithoutContext('rejects malformed wrappers even with a matching outer digest', () {
    final fileSystem = MemoryFileSystem.test();
    for (final offset in <int>[0, 8, 12, 16, 20, 24, 28, 60, 92]) {
      final Map<String, String> environment = writeShorebirdReplacementBase(fileSystem);
      final File file = fileSystem.file(environment[kShorebirdReplacementBaseEnvVar]);
      final Uint8List bytes = file.readAsBytesSync();
      bytes[offset] ^= 1;
      file.writeAsBytesSync(bytes);
      environment[kShorebirdAotBaseSnapshotHashEnvVar] = sha256.convert(bytes).toString();
      expect(
        () => ShorebirdReplacementInputs.read(fileSystem, environment),
        throwsFormatException,
        reason: 'offset $offset',
      );
    }
  });
}

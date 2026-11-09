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

  group('hardened-diversified (contract v3)', () {
    const profileId = 'sha256:832856d0bed27833434e3f26b65d03cedc313f9850c2577ca7565c4dc644f46d';
    const otherId = 'sha256:0000000000000000000000000000000000000000000000000000000000000000';

    testWithoutContext('accepts a DBP3 component bound to the configured profile', () {
      final fileSystem = MemoryFileSystem.test();
      final Map<String, String> environment = writeShorebirdReplacementBase(
        fileSystem,
        profileId: profileId,
      );
      expect(environment[kShorebirdSecurityProfileEnvVar], 'hardened-diversified');
      expect(() => ShorebirdReplacementInputs.read(fileSystem, environment), returnsNormally);
    });

    testWithoutContext('refuses a DBC3 component, another profile, or no profile ID', () {
      final fileSystem = MemoryFileSystem.test();
      // A canonical (DBC3) base under a diversified build.
      final Map<String, String> canonical = writeShorebirdReplacementBase(fileSystem);
      expect(
        () => ShorebirdReplacementInputs.read(fileSystem, <String, String>{
          ...canonical,
          kShorebirdSecurityProfileEnvVar: 'hardened-diversified',
          kShorebirdDiversificationProfileIdEnvVar: profileId,
        }),
        throwsA(
          isA<FormatException>().having(
            (FormatException e) => e.message,
            'message',
            contains('DBP3'),
          ),
        ),
      );
      final Map<String, String> profiled = writeShorebirdReplacementBase(
        fileSystem,
        profileId: profileId,
      );
      for (final environment in <Map<String, String>>[
        // Another profile's build.
        <String, String>{...profiled, kShorebirdDiversificationProfileIdEnvVar: otherId},
        // No (or a malformed) profile ID.
        <String, String>{...profiled}..remove(kShorebirdDiversificationProfileIdEnvVar),
        <String, String>{
          ...profiled,
          kShorebirdDiversificationProfileIdEnvVar: profileId.toUpperCase(),
        },
        // A legacy or hardened build is canonical: DBP3 is refused.
        <String, String>{...profiled}
          ..remove(kShorebirdSecurityProfileEnvVar)
          ..remove(kShorebirdDiversificationProfileIdEnvVar),
        <String, String>{...profiled, kShorebirdSecurityProfileEnvVar: 'hardened'},
      ]) {
        expect(
          () => ShorebirdReplacementInputs.read(fileSystem, environment),
          throwsFormatException,
          reason: '$environment',
        );
      }
    });

    testWithoutContext('refuses a DBP3 header with a wrong version or digest', () {
      final fileSystem = MemoryFileSystem.test();
      final Map<String, String> profiled = writeShorebirdReplacementBase(
        fileSystem,
        profileId: profileId,
      );
      final File file = fileSystem.file(profiled[kShorebirdReplacementBaseEnvVar]);
      final Uint8List original = file.readAsBytesSync();
      final int component = original.length - 41;
      for (final offset in <int>[component + 4, component + 8, component + 39]) {
        final bytes = Uint8List.fromList(original);
        bytes[offset] ^= 1;
        // Keep the outer wrapper consistent: only the component header lies.
        final digest = sha256.convert(bytes.sublist(component)).toString();
        final raw = <int>[
          for (var i = 0; i < 64; i += 2) int.parse(digest.substring(i, i + 2), radix: 16),
        ];
        bytes.setRange(60, 92, raw);
        bytes.setRange(92, 124, raw);
        file.writeAsBytesSync(bytes);
        expect(
          () => ShorebirdReplacementInputs.read(fileSystem, <String, String>{
            ...profiled,
            kShorebirdAotBaseSnapshotHashEnvVar: sha256.convert(bytes).toString(),
          }),
          throwsFormatException,
          reason: 'offset $offset',
        );
      }
    });
  });
}

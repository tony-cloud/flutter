// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/shorebird/shorebird_native_selection.dart';

const nativeSelectionAppId = '11111111-1111-4111-8111-111111111111';
const nativeSelectionYaml =
    '''
app_id: $nativeSelectionAppId
selection_protocol: 2
aot_patch_app_build_id: 1.0.0+1
patch_public_key: pinned-key
patch_verification: strict
patch_response_verification: required
''';

Map<String, String> writeNativeSelectionManifest(
  FileSystem fs, {
  String platform = 'android',
  List<String> arches = const <String>['arm', 'aarch64', 'x86_64'],
  bool measure = false,
}) {
  final entries = <Map<String, Object?>>[];
  if (!measure) {
    for (final arch in arches) {
      final bytes = Uint8List(64);
      bytes.setAll(0, <int>[0x7f, 0x45, 0x4c, 0x46, if (arch == 'arm') 1 else 2, 1, 1]);
      ByteData.sublistView(
        bytes,
      ).setUint16(18, <String, int>{'arm': 40, 'aarch64': 183, 'x86_64': 62}[arch]!, Endian.little);
      final File base = fs.file('/private/$arch.so')..createSync(recursive: true);
      base.writeAsBytesSync(bytes);
      entries.add(<String, Object?>{
        'scope': <String, Object?>{
          'app_id': nativeSelectionAppId,
          'release_version': '1.0.0+1',
          'platform': platform,
          'arch': arch,
          'base_artifact_hash': sha256.convert(bytes).toString(),
          'host_abi_hash': null,
          'runtime_profile': 'native-aot',
        },
        'original_baseline_path': base.path,
      });
    }
  }
  final File manifest = fs.file('/private/manifest.json')..createSync(recursive: true);
  manifest.writeAsStringSync(
    jsonEncode(<String, Object?>{
      'version': 1,
      'mode': measure ? 'measure' : 'sealed',
      'app_id': nativeSelectionAppId,
      'release_version': '1.0.0+1',
      'platform': platform,
      'arches': arches,
      'entries': entries,
    }),
  );
  return <String, String>{kShorebirdNativeSelectionManifest: manifest.path};
}

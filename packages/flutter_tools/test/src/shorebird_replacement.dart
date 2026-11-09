// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_tools/src/artifacts.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/shorebird/shorebird_replacement.dart';
import 'package:flutter_tools/src/shorebird/shorebird_replacement_host.dart';
import 'package:flutter_tools/src/shorebird/shorebird_yaml.dart';

import 'fake_process_manager.dart';

/// Explicit local engine configuration for macOS full replacement fixtures.
const shorebirdMacOSReplacementArgs = '''
is_debug = false
flutter_runtime_mode = "release"
dart_runtime_mode = "release"
target_os = "mac"
target_cpu = "arm64"
dart_target_arch = "arm64"
dart_enable_shorebird_interpreter = true
shorebird_use_interpreter = false
''';

/// Writes a version 1 base wrapper fixture with a single mutable root library.
///
/// With [profileId] (`sha256:<hex>`), the component is a profiled `DBP3`
/// component bound to that diversification profile (contract v3), and the
/// returned environment selects hardened-diversified.
Map<String, String> writeShorebirdReplacementBase(
  FileSystem fileSystem, {
  String hostAbi = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  int content = 1,
  String? profileId,
}) {
  final component = profileId == null
      ? <int>[0x33, 0x43, 0x42, 0x44, 1, 0, 0, 0, content]
      : <int>[
          0x33, 0x50, 0x42, 0x44, 3, 0, 0, 0, //
          for (var i = 7; i < profileId.length; i += 2)
            int.parse(profileId.substring(i, i + 2), radix: 16),
          content,
        ];
  final List<int> hash = sha256.convert(component).bytes;
  final manifest = BytesBuilder();
  void u32(BytesBuilder builder, int value) {
    builder.add((ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List());
  }

  void uri(String value) {
    final List<int> bytes = utf8.encode(value);
    u32(manifest, bytes.length);
    manifest.add(bytes);
  }

  u32(manifest, 1);
  manifest.add(<int>[
    for (var i = 0; i < hostAbi.length; i += 2) int.parse(hostAbi.substring(i, i + 2), radix: 16),
  ]);
  manifest.add(hash);
  manifest.add(hash);
  uri('package:app/main.dart');
  for (var i = 0; i < 2; ++i) {
    u32(manifest, 1);
    uri('package:app/main.dart');
  }
  u32(manifest, 0);
  final Uint8List metadata = manifest.takeBytes();
  final wrapper = BytesBuilder()..add(<int>[83, 66, 82, 80, 76, 67, 69, 0]);
  u32(wrapper, 1);
  u32(wrapper, metadata.length);
  u32(wrapper, component.length);
  u32(wrapper, 0);
  wrapper.add(metadata);
  wrapper.add(component);
  final File base = fileSystem.file('/private/base.sbr')..createSync(recursive: true);
  final Uint8List bytes = wrapper.takeBytes();
  base.writeAsBytesSync(bytes);
  return <String, String>{
    kShorebirdReplacementBaseEnvVar: base.path,
    kShorebirdHostAbiEnvVar: hostAbi,
    kShorebirdAotBaseSnapshotHashEnvVar: sha256.convert(bytes).toString(),
    if (profileId != null) ...<String, String>{
      kShorebirdSecurityProfileEnvVar: 'hardened-diversified',
      kShorebirdDiversificationProfileIdEnvVar: profileId,
    },
  };
}

/// Writes selected host artifacts and returns their independently derived stamp.
String writeShorebirdReplacementHost(
  FileSystem fileSystem,
  Artifacts artifacts, {
  int content = 1,
  String targetOS = 'ios',
  String targetArch = 'arm64',
}) {
  final macOS = targetOS == 'macos';
  final String framework = artifacts.getArtifactPath(
    macOS ? Artifact.flutterMacOSFramework : Artifact.flutterFramework,
    platform: macOS ? TargetPlatform.darwin : TargetPlatform.ios,
    mode: BuildMode.release,
    environmentType: EnvironmentType.physical,
  );
  for (final path in <String>[
    fileSystem.path.join(framework, macOS ? 'FlutterMacOS' : 'Flutter'),
    artifacts.getArtifactPath(
      targetArch == 'x64' ? Artifact.genSnapshotX64 : Artifact.genSnapshotArm64,
      platform: macOS ? TargetPlatform.darwin : TargetPlatform.ios,
      mode: BuildMode.release,
    ),
    fileSystem.path.join(
      shorebirdReplacementSdkRoot(
        artifacts,
        fileSystem,
        targetOS: targetOS,
        targetArch: targetArch,
      ),
      'platform_strong.dill',
    ),
    artifacts.getArtifactPath(Artifact.engineDartAotRuntime),
    artifacts.getArtifactPath(Artifact.frontendServerSnapshotForEngineDartSdk),
  ]) {
    fileSystem.file(path)
      ..createSync(recursive: true)
      ..writeAsStringSync('$path:$content');
  }
  return ShorebirdReplacementHost.read(
    fileSystem,
    artifacts,
    buildMode: BuildMode.release,
    targetOS: targetOS,
    targetArch: targetArch,
  ).hostAbi;
}

/// Matching probes for fake compilation, differing only in reported host.
List<FakeCommand> shorebirdReplacementVersionCommands(
  Artifacts artifacts, {
  String targetOS = 'ios',
  String targetArch = 'arm64',
}) => <FakeCommand>[
  FakeCommand(
    command: <String>[
      artifacts.getArtifactPath(
        targetArch == 'x64' ? Artifact.genSnapshotX64 : Artifact.genSnapshotArm64,
        platform: targetOS == 'macos' ? TargetPlatform.darwin : TargetPlatform.ios,
        mode: BuildMode.release,
      ),
      '--version',
    ],
    stderr: 'Dart SDK version: test on "macos_arm64"',
  ),
  FakeCommand(
    command: <String>[artifacts.getArtifactPath(Artifact.engineDartAotRuntime), '--version'],
    stdout: 'Dart SDK version: test on "macos_x64"',
  ),
];

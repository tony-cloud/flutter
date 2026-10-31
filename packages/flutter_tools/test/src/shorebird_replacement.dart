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

/// Writes a version 1 base wrapper fixture with a single mutable root library.
Map<String, String> writeShorebirdReplacementBase(
  FileSystem fileSystem, {
  String hostAbi = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  int content = 1,
}) {
  final component = <int>[0x33, 0x43, 0x42, 0x44, 1, 0, 0, 0, content];
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
  };
}

/// Writes selected host artifacts and returns their independently derived stamp.
String writeShorebirdReplacementHost(
  FileSystem fileSystem,
  Artifacts artifacts, {
  int content = 1,
}) {
  final String framework = artifacts.getArtifactPath(
    Artifact.flutterFramework,
    platform: TargetPlatform.ios,
    mode: BuildMode.release,
    environmentType: EnvironmentType.physical,
  );
  for (final path in <String>[
    fileSystem.path.join(framework, 'Flutter'),
    artifacts.getArtifactPath(
      Artifact.genSnapshotArm64,
      platform: TargetPlatform.ios,
      mode: BuildMode.release,
    ),
    fileSystem.path.join(
      shorebirdReplacementSdkRoot(artifacts, fileSystem),
      'platform_strong.dill',
    ),
    artifacts.getArtifactPath(Artifact.engineDartAotRuntime),
    artifacts.getArtifactPath(Artifact.frontendServerSnapshotForEngineDartSdk),
  ]) {
    fileSystem.file(path)
      ..createSync(recursive: true)
      ..writeAsStringSync('$path:$content');
  }
  return ShorebirdReplacementHost.read(fileSystem, artifacts, buildMode: BuildMode.release).hostAbi;
}

/// Matching probes for fake compilation, differing only in reported host.
List<FakeCommand> shorebirdReplacementVersionCommands(Artifacts artifacts) => <FakeCommand>[
  FakeCommand(
    command: <String>[
      artifacts.getArtifactPath(
        Artifact.genSnapshotArm64,
        platform: TargetPlatform.ios,
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

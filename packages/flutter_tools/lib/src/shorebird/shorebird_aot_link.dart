// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import '../base/file_system.dart';

/// `aot_patch_runtime_mode` value that selects the iOS "linked AOT" profile
/// (`aot-link`).
///
/// A release is a normal TFA AOT build whose gen_snapshot also writes a link
/// sidecar (`--print_link_info_to`). A patch is a full optimized AOT build
/// compiled against the release's sidecar (`--link_base`); the CLI then maps
/// unchanged code to the release's native instructions with `ios_linker`.
/// See docs/ios-linker/COMPILER_LINKER.md.
const kShorebirdAotLinkRuntimeMode = 'ios-aot-link';

/// Patch builds only: the release's `App.link` sidecar. Its presence makes the
/// build a patch build. Absent on release builds.
const kShorebirdAotLinkBaseEnvVar = 'SHOREBIRD_AOT_LINK_BASE';

/// Patch builds only: the release's `App.dd` target list (DD releases).
const kShorebirdAotLinkDdTargetsEnvVar = 'SHOREBIRD_AOT_LINK_DD_TARGETS';

/// Release builds only: enables DD selection with this caller-tree byte
/// threshold. Unset or non-positive means no DD (the default).
const kShorebirdAotLinkDdMaxBytesEnvVar = 'SHOREBIRD_AOT_LINK_DD_MAX_BYTES';

/// Release builds only: comma-separated package names DD targets may come
/// from. DD selection never considers functions outside these packages.
const kShorebirdAotLinkDdPackagesEnvVar = 'SHOREBIRD_AOT_LINK_DD_PACKAGES';

/// Path of the `ios_linker` tool (a `.dart`/`.dill`/`.snapshot` run with the
/// engine's Dart, or a native executable). Needed for the second pass of patch
/// builds (pool hints) and for DD selection.
const kShorebirdAotLinkToolEnvVar = 'SHOREBIRD_IOS_LINKER';

/// Sidecar files, written next to (never inside) the snapshot output
/// directory so they stay out of `App.framework`.
const kShorebirdAotLinkReleaseSidecar = 'App.link';
const kShorebirdAotLinkDdTargets = 'App.dd';
const kShorebirdAotLinkDdAnalysisElf = 'App.analysis.aot';
const kShorebirdAotLinkDdAnalysisSidecar = 'App.analysis.link';
const kShorebirdAotLinkPass1Elf = 'out.pass1.aot';
const kShorebirdAotLinkPass1Sidecar = 'out.pass1.link';
const kShorebirdAotLinkConstraints = 'constraints.link';
const kShorebirdAotLinkPatchElf = 'out.aot';
const kShorebirdAotLinkPatchSidecar = 'out.link';

/// Names LinkSupplement copies into `build/ios/shorebird` (outside the app).
const kShorebirdAotLinkSupplementFiles = <String>[
  kShorebirdAotLinkReleaseSidecar,
  kShorebirdAotLinkDdTargets,
  kShorebirdAotLinkConstraints,
  kShorebirdAotLinkPatchElf,
  kShorebirdAotLinkPatchSidecar,
];

/// Whether the project selects the linked AOT profile for [targetOS].
///
/// Throws for targets other than iOS and for combinations with the
/// interpreter profiles.
bool shorebirdUsesAotLinkMode(String? runtimeMode, String? targetOS) {
  if (runtimeMode != kShorebirdAotLinkRuntimeMode) {
    return false;
  }
  if (targetOS != 'ios') {
    throw const FormatException('aot_patch_runtime_mode: ios-aot-link supports only iOS');
  }
  return true;
}

/// Resolved inputs of one linked AOT snapshot build.
class ShorebirdAotLink {
  const ShorebirdAotLink({
    required this.sidecarDirectory,
    this.baseLink,
    this.ddTargets,
    this.ddMaxBytes = 0,
    this.ddPackages = const <String>[],
    this.toolPath,
  });

  /// Reads the build inputs from [environment]. [sidecarDirectory] is the
  /// directory the sidecars go to: the snapshot output directory's parent.
  factory ShorebirdAotLink.read(FileSystem fs, Map<String, String> environment, String sidecarDirectory) {
    String? path(String key) {
      final String? value = environment[key]?.trim();
      return value == null || value.isEmpty ? null : value;
    }

    final String? base = path(kShorebirdAotLinkBaseEnvVar);
    final String? dd = path(kShorebirdAotLinkDdTargetsEnvVar);
    final int ddMaxBytes = int.tryParse(path(kShorebirdAotLinkDdMaxBytesEnvVar) ?? '') ?? 0;
    if (base != null) {
      if (!fs.path.isAbsolute(base) || !fs.file(base).existsSync()) {
        throw const FormatException('$kShorebirdAotLinkBaseEnvVar must name an existing absolute file');
      }
      if (ddMaxBytes > 0) {
        throw const FormatException(
          '$kShorebirdAotLinkDdMaxBytesEnvVar applies to release builds; a patch uses the '
          "release's $kShorebirdAotLinkDdTargetsEnvVar",
        );
      }
    }
    if (dd != null) {
      if (base == null) {
        throw const FormatException('$kShorebirdAotLinkDdTargetsEnvVar requires $kShorebirdAotLinkBaseEnvVar');
      }
      if (!fs.path.isAbsolute(dd) || !fs.file(dd).existsSync()) {
        throw const FormatException('$kShorebirdAotLinkDdTargetsEnvVar must name an existing absolute file');
      }
    }
    final String? packages = path(kShorebirdAotLinkDdPackagesEnvVar);
    return ShorebirdAotLink(
      sidecarDirectory: sidecarDirectory,
      baseLink: base,
      ddTargets: dd,
      ddMaxBytes: ddMaxBytes > 0 ? ddMaxBytes : 0,
      ddPackages: packages == null
          ? const <String>[]
          : packages.split(',').map((String s) => s.trim()).where((String s) => s.isNotEmpty).toList(),
      toolPath: path(kShorebirdAotLinkToolEnvVar),
    );
  }

  final String sidecarDirectory;

  /// The release sidecar; non-null on patch builds.
  final String? baseLink;

  /// The release's DD targets; patch builds of a DD release.
  final String? ddTargets;

  /// Release DD threshold; 0 disables DD.
  final int ddMaxBytes;
  final List<String> ddPackages;
  final String? toolPath;

  bool get isPatch => baseLink != null;
}

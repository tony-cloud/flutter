// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Caps the iOS DD table when the private legacy compiler route is enabled.
const kShorebirdDdMaxBytesEnvVar = 'SHOREBIRD_DD_MAX_BYTES';

/// Development-only opt-in shared with the CLI's closed aot-tools cache gate.
/// Requires a legacy compiler that implements the private native linker flags.
const kShorebirdLegacyAotToolsEnvVar = 'SHOREBIRD_ENABLE_LEGACY_AOT_TOOLS';

bool shorebirdLegacyAotToolsEnabled(Map<String, String> environment) {
  final String? value = environment[kShorebirdLegacyAotToolsEnvVar]?.trim().toLowerCase();
  return value == '1' || value == 'true' || value == 'yes';
}

/// The `dd_max_bytes` an AOT build passes to the DD pass, read from
/// [environment] (preferring a `dart-define` on the tool itself), or 0 if
/// unset, malformed, or non-positive, which means no DD pass.
int shorebirdDdMaxBytes(Map<String, String> environment) {
  const fromDefine = String.fromEnvironment(kShorebirdDdMaxBytesEnvVar);
  final String? raw = fromDefine.isNotEmpty ? fromDefine : environment[kShorebirdDdMaxBytesEnvVar];
  final int value = int.tryParse(raw ?? '') ?? 0;
  return value > 0 ? value : 0;
}

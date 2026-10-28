// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/shorebird/shorebird_dd.dart';

import '../../src/common.dart';

void main() {
  testWithoutContext('private native linker flags require explicit legacy opt-in', () {
    expect(shorebirdLegacyAotToolsEnabled(<String, String>{}), isFalse);
    for (final value in <String>['', '0', 'false', 'no', 'invalid']) {
      expect(
        shorebirdLegacyAotToolsEnabled(<String, String>{kShorebirdLegacyAotToolsEnvVar: value}),
        isFalse,
        reason: value,
      );
    }
    for (final value in <String>['1', 'true', 'yes', ' TRUE ']) {
      expect(
        shorebirdLegacyAotToolsEnabled(<String, String>{kShorebirdLegacyAotToolsEnvVar: value}),
        isTrue,
        reason: value,
      );
    }
  });
}

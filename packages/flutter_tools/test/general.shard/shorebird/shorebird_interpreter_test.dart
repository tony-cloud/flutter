// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/shorebird/shorebird_interpreter.dart';

import '../../src/common.dart';

void main() {
  testWithoutContext('only explicitly configured iOS interpreter builds disable TFA', () {
    final fileSystem = MemoryFileSystem.test();
    expect(shorebirdInterpreterDisablesTfa(fileSystem, 'ios'), isFalse);
    final File config = fileSystem.file('shorebird.yaml');
    config.writeAsStringSync('app_id: test\n');
    expect(shorebirdInterpreterDisablesTfa(fileSystem, 'ios'), isFalse);
    config.writeAsStringSync('aot_patch_runtime_mode: native-aot\n');
    expect(shorebirdInterpreterDisablesTfa(fileSystem, 'ios'), isFalse);
    config.writeAsStringSync('aot_patch_runtime_mode: dart-bytecode-interpreter\n');
    expect(shorebirdInterpreterDisablesTfa(fileSystem, 'ios'), isTrue);
    expect(shorebirdInterpreterDisablesTfa(fileSystem, 'android'), isFalse);
    expect(shorebirdInterpreterDisablesTfa(fileSystem, null), isFalse);
  });
}

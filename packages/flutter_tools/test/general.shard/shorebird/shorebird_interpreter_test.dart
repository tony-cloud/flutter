// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/shorebird/shorebird_interpreter.dart';

import '../../src/common.dart';

void main() {
  testWithoutContext('only explicit iOS interpreter mode selects the public AOT baseline', () {
    final fileSystem = MemoryFileSystem.test();
    expect(shorebirdUsesIosBytecodeInterpreter(fileSystem, 'ios'), isFalse);
    final File config = fileSystem.file('shorebird.yaml');
    config.writeAsStringSync('app_id: test\n');
    expect(shorebirdUsesIosBytecodeInterpreter(fileSystem, 'ios'), isFalse);
    config.writeAsStringSync('aot_patch_runtime_mode: native-aot\n');
    expect(shorebirdUsesIosBytecodeInterpreter(fileSystem, 'ios'), isFalse);
    config.writeAsStringSync('aot_patch_runtime_mode: dart-bytecode-interpreter\n');
    expect(shorebirdUsesIosBytecodeInterpreter(fileSystem, 'ios'), isTrue);
    expect(shorebirdUsesIosBytecodeInterpreter(fileSystem, 'android'), isFalse);
    expect(shorebirdUsesIosBytecodeInterpreter(fileSystem, null), isFalse);
  });
}

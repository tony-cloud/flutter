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

  testWithoutContext('structural updates require an explicit iOS interpreter profile', () {
    final fileSystem = MemoryFileSystem.test();
    expect(shorebirdUsesIosStructuralUpdates(fileSystem, 'ios'), isFalse);
    final Directory project = fileSystem.directory('/project')..createSync();
    final File config = project.childFile('shorebird.yaml');
    for (final setting in <String>['', 'aot_patch_structural_updates: false\n']) {
      config.writeAsStringSync('aot_patch_runtime_mode: dart-bytecode-interpreter\n$setting');
      expect(
        shorebirdUsesIosStructuralUpdates(fileSystem, 'ios', projectDirectory: project),
        isFalse,
      );
    }
    config.writeAsStringSync(
      'aot_patch_runtime_mode: dart-bytecode-interpreter\n'
      'aot_patch_structural_updates: true\n',
    );
    expect(shorebirdUsesIosStructuralUpdates(fileSystem, 'ios', projectDirectory: project), isTrue);
    for (final targetOS in <String?>['android', 'macos', null]) {
      expect(
        shorebirdUsesIosStructuralUpdates(fileSystem, targetOS, projectDirectory: project),
        isFalse,
      );
    }
  });

  testWithoutContext('invalid structural profiles fail before compiler selection', () {
    final fileSystem = MemoryFileSystem.test();
    final File config = fileSystem.file('shorebird.yaml');
    for (final value in <String>['"true"', '1', 'null', '[]']) {
      config.writeAsStringSync(
        'aot_patch_runtime_mode: dart-bytecode-interpreter\n'
        'aot_patch_structural_updates: $value\n',
      );
      expect(() => shorebirdUsesIosBytecodeInterpreter(fileSystem, 'ios'), throwsFormatException);
      expect(() => shorebirdUsesIosStructuralUpdates(fileSystem, 'ios'), throwsFormatException);
    }
    for (final runtime in <String>['', 'aot_patch_runtime_mode: native-aot\n']) {
      config.writeAsStringSync('${runtime}aot_patch_structural_updates: true\n');
      expect(() => shorebirdUsesIosBytecodeInterpreter(fileSystem, 'ios'), throwsFormatException);
      expect(() => shorebirdUsesIosStructuralUpdates(fileSystem, 'ios'), throwsFormatException);
    }
    config.writeAsStringSync(
      'aot_patch_runtime_mode: native-aot\naot_patch_structural_updates: false\n',
    );
    expect(shorebirdUsesIosStructuralUpdates(fileSystem, 'ios'), isFalse);
  });
  testWithoutContext('full replacement requires an exclusive iOS interpreter profile', () {
    final fileSystem = MemoryFileSystem.test();
    final File config = fileSystem.file('shorebird.yaml');
    for (final value in <String>['"true"', 'null', '1']) {
      config.writeAsStringSync('aot_patch_full_replacement: $value\n');
      expect(() => shorebirdUsesIosFullReplacement(fileSystem, 'ios'), throwsFormatException);
    }
    for (final extra in <String>[
      '',
      'aot_patch_runtime_mode: native-aot\n',
      'aot_patch_runtime_mode: dart-bytecode-interpreter\naot_patch_structural_updates: true\n',
    ]) {
      config.writeAsStringSync('${extra}aot_patch_full_replacement: true\n');
      expect(() => shorebirdUsesIosFullReplacement(fileSystem, 'ios'), throwsFormatException);
    }
    config.writeAsStringSync(
      'aot_patch_runtime_mode: dart-bytecode-interpreter\naot_patch_full_replacement: true\n',
    );
    expect(shorebirdUsesIosFullReplacement(fileSystem, 'ios'), isTrue);
    expect(shorebirdUsesIosStructuralUpdates(fileSystem, 'ios'), isFalse);
    expect(() => shorebirdUsesIosFullReplacement(fileSystem, 'android'), throwsFormatException);
  });
}

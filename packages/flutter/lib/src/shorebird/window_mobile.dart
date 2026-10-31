// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/foundation.dart';

import '../widgets/_window.dart';

/// Keeps iOS's unsupported-window behavior without importing desktop FFI code
/// into a full replacement component.
///
/// {@macro flutter.widgets.windowing.experimental}
@internal
WindowingOwner? createDefaultOwner() => null;

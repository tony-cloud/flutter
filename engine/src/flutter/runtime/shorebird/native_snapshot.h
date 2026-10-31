// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_RUNTIME_SHOREBIRD_NATIVE_SNAPSHOT_H_
#define FLUTTER_RUNTIME_SHOREBIRD_NATIVE_SNAPSHOT_H_

#include <memory>

#include "flutter/fml/mapping.h"

namespace flutter::shorebird {

// Android native-mode loader. Resolves both isolate symbols from one retained
// image. Success with empty mappings selects the bundled base; false refuses
// startup because a checked source could not be selected/begun.
bool ResolvePreparedAndroidSnapshot(
    std::shared_ptr<const fml::Mapping>& data,
    std::shared_ptr<const fml::Mapping>& instructions);

}  // namespace flutter::shorebird

#endif  // FLUTTER_RUNTIME_SHOREBIRD_NATIVE_SNAPSHOT_H_

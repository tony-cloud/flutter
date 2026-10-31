// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_SHELL_PLATFORM_EMBEDDER_SHOREBIRD_AOT_DATA_H_
#define FLUTTER_SHELL_PLATFORM_EMBEDDER_SHOREBIRD_AOT_DATA_H_

#include <cstdint>

#include "flutter/shell/platform/embedder/embedder.h"

namespace flutter::shorebird {

// Engine-internal Linux hook; does not extend the public AOT source ABI.
// Takes ownership of fd on every path. Result ownership matches CreateAOTData.
FlutterEngineResult CreateAOTDataFromFD(int fd,
                                        uint64_t selection_id,
                                        FlutterEngineAOTData* data_out);

// Engine-internal Windows memory source (also exercised by Linux tests).
// Borrows authenticated immutable bytes for this call only. Loaded mappings
// and Windows unwind tables are retained across engine destruction/recreation.
FlutterEngineResult CreateAOTDataFromMemory(const uint8_t* bytes,
                                            uint64_t length,
                                            uint64_t selection_id,
                                            FlutterEngineAOTData* data_out);

}  // namespace flutter::shorebird

#endif  // FLUTTER_SHELL_PLATFORM_EMBEDDER_SHOREBIRD_AOT_DATA_H_

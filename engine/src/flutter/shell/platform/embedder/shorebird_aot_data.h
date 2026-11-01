// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_SHELL_PLATFORM_EMBEDDER_SHOREBIRD_AOT_DATA_H_
#define FLUTTER_SHELL_PLATFORM_EMBEDDER_SHOREBIRD_AOT_DATA_H_

#include <cstddef>
#include <cstdint>

#include "flutter/shell/platform/embedder/embedder.h"

namespace flutter {
struct ShorebirdConfigArgs;
struct Settings;
}  // namespace flutter

namespace flutter::shorebird {

// First-party signed-host initializer. Copies settings synchronously before
// returning; neither args pointer is retained. No public embedder ABI changes.
FlutterEngineResult InitializeWithShorebirdInterpreter(
    size_t version,
    const FlutterRendererConfig* renderer_config,
    const FlutterProjectArgs* project_args,
    void* user_data,
    FLUTTER_API_SYMBOL(FlutterEngine) * engine_out,
    const ShorebirdConfigArgs* shorebird_args);

// Pin the signed macOS ARM64 host's symbols and configure immutable bytecode
// settings. Rejects external AOT sources; no executable patch mapping occurs.
bool ConfigureSignedInterpreterHost(const ShorebirdConfigArgs& args,
                                    Settings& settings);

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

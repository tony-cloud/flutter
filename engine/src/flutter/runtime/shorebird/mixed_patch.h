// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_RUNTIME_SHOREBIRD_MIXED_PATCH_H_
#define FLUTTER_RUNTIME_SHOREBIRD_MIXED_PATCH_H_

#include <memory>
#include <optional>
#include <string>

#include "flutter/fml/mapping.h"

namespace flutter {
namespace shorebird {

struct MixedPatchSnapshot {
  std::shared_ptr<const fml::Mapping> data;
  std::shared_ptr<const fml::Mapping> instructions;
};

// Loads a linked AOT patch (vmcode v1, docs/ios-linker/COMPILER_LINKER.md
// section 6) for mixed-mode execution against the release isolate snapshot
// (docs/ios-linker/RUNTIME.md):
//   - validates the container, the SHA-256 of the embedded ELF and the
//     SHA-256 of the release's mapped `_kDartSnapshotText` region;
//   - maps the patch ELF with its text read-only (never executable);
//   - registers the images and link records and links the patch against the
//     release code, all before any isolate exists.
// Returns the patch's isolate snapshot, or nothing after logging why; the
// caller then boots the release unchanged (fail closed). The release's VM
// snapshot and isolate text stay in use either way.
//
// Trust: the file must come from the updater's verified boot path (signed
// hash checked over the whole file) or, in test engines only, from the
// SHOREBIRD_MIXED_DEV_PATCH location.
std::optional<MixedPatchSnapshot> LoadMixedPatch(
    const std::string& path,
    const std::shared_ptr<const fml::Mapping>& release_instructions);

}  // namespace shorebird
}  // namespace flutter

#endif  // FLUTTER_RUNTIME_SHOREBIRD_MIXED_PATCH_H_

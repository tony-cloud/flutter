// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "flutter/runtime/shorebird/patch_mapping.h"

#include <cstdint>
#include <cstring>

namespace flutter {
namespace {

constexpr int32_t kDartSnapshotMagicValue = 0xdcdcf5f5;
constexpr size_t kDartSnapshotMagicOffset = 0;
constexpr size_t kDartSnapshotMagicSize = sizeof(int32_t);
constexpr size_t kDartSnapshotLengthOffset =
    kDartSnapshotMagicOffset + kDartSnapshotMagicSize;
constexpr size_t kDartImageSizeOffset = 0;

template <typename T>
T ReadUnaligned(const uint8_t* ptr, size_t offset) {
  T value;
  memcpy(&value, ptr + offset, sizeof(T));
  return value;
}

size_t SnapshotDataSize(const uint8_t* ptr) {
  if (ptr == nullptr) {
    return 0;
  }
  const int32_t magic =
      ReadUnaligned<int32_t>(ptr, kDartSnapshotMagicOffset);
  if (magic != kDartSnapshotMagicValue) {
    return 0;
  }
  const int64_t length =
      ReadUnaligned<int64_t>(ptr, kDartSnapshotLengthOffset);
  return length < 0 ? 0 : static_cast<size_t>(length + kDartSnapshotMagicSize);
}

size_t SnapshotInstructionsSize(const uint8_t* ptr) {
  if (ptr == nullptr) {
    return 0;
  }
  return ReadUnaligned<size_t>(ptr, kDartImageSizeOffset);
}

}  // namespace

std::shared_ptr<PatchMapping> PatchMapping::CreateIsolateData(
    std::shared_ptr<PatchCacheEntry> entry) {
  if (!entry) {
    return nullptr;
  }
  const uint8_t* data = entry->isolate_data();
  size_t size = SnapshotDataSize(data);
  return std::shared_ptr<PatchMapping>(new PatchMapping(entry, data, size));
}

std::shared_ptr<PatchMapping> PatchMapping::CreateIsolateInstructions(
    std::shared_ptr<PatchCacheEntry> entry) {
  if (!entry) {
    return nullptr;
  }
  const uint8_t* data = entry->isolate_instructions();
  size_t size = SnapshotInstructionsSize(data);
  return std::shared_ptr<PatchMapping>(new PatchMapping(entry, data, size));
}

PatchMapping::PatchMapping(std::shared_ptr<PatchCacheEntry> entry,
                           const uint8_t* data,
                           size_t size)
    : cache_entry_(std::move(entry)), data_(data), size_(size) {}

PatchMapping::~PatchMapping() = default;

size_t PatchMapping::GetSize() const {
  return size_;
}

const uint8_t* PatchMapping::GetMapping() const {
  return data_;
}

bool PatchMapping::IsDontNeedSafe() const {
  // Patch mappings are file-backed and safe for madvise(DONTNEED).
  return true;
}

}  // namespace flutter

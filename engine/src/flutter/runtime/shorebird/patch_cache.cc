// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "flutter/runtime/shorebird/patch_cache.h"

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <mutex>

#include "flutter/fml/build_config.h"
#include "flutter/fml/logging.h"
#include "flutter/fml/mapping.h"
#include "flutter/runtime/shorebird/patch_mapping.h"
#include "third_party/dart/runtime/bin/elf_loader.h"
#include "third_party/dart/runtime/include/dart_api.h"

#if defined(FML_OS_MACOSX)
#include "third_party/dart/runtime/bin/macho_loader.h"
#endif

namespace flutter {

namespace {

// These symbol names match the constants in dart_snapshot.cc.
// We duplicate them here rather than extracting them into a header.
// They are actually defined down in Dart and will never change.
constexpr const char* kIsolateDataSymbol = "kDartIsolateSnapshotData";
constexpr const char* kIsolateInstructionsSymbol =
    "kDartIsolateSnapshotInstructions";

struct VmcodeObjectLocation {
  PatchObjectFormat format = PatchObjectFormat::kElf;
  uint64_t file_offset = 0;
};

bool HasMagic(const uint8_t* bytes,
              const uint8_t* magic,
              size_t magic_size) {
  return memcmp(bytes, magic, magic_size) == 0;
}

bool IsElfMagic(const uint8_t* bytes) {
  constexpr uint8_t kElfMagic[] = {0x7f, 'E', 'L', 'F'};
  return HasMagic(bytes, kElfMagic, sizeof(kElfMagic));
}

bool IsMachOMagic(const uint8_t* bytes) {
  constexpr uint8_t kMachO32Le[] = {0xce, 0xfa, 0xed, 0xfe};
  constexpr uint8_t kMachO32Be[] = {0xfe, 0xed, 0xfa, 0xce};
  constexpr uint8_t kMachO64Le[] = {0xcf, 0xfa, 0xed, 0xfe};
  constexpr uint8_t kMachO64Be[] = {0xfe, 0xed, 0xfa, 0xcf};
  constexpr uint8_t kFat32Be[] = {0xca, 0xfe, 0xba, 0xbe};
  constexpr uint8_t kFat32Le[] = {0xbe, 0xba, 0xfe, 0xca};
  constexpr uint8_t kFat64Be[] = {0xca, 0xfe, 0xba, 0xbf};
  constexpr uint8_t kFat64Le[] = {0xbf, 0xba, 0xfe, 0xca};
  return HasMagic(bytes, kMachO32Le, sizeof(kMachO32Le)) ||
         HasMagic(bytes, kMachO32Be, sizeof(kMachO32Be)) ||
         HasMagic(bytes, kMachO64Le, sizeof(kMachO64Le)) ||
         HasMagic(bytes, kMachO64Be, sizeof(kMachO64Be)) ||
         HasMagic(bytes, kFat32Be, sizeof(kFat32Be)) ||
         HasMagic(bytes, kFat32Le, sizeof(kFat32Le)) ||
         HasMagic(bytes, kFat64Be, sizeof(kFat64Be)) ||
         HasMagic(bytes, kFat64Le, sizeof(kFat64Le));
}

bool FindVmcodeObject(const uint8_t* mapping,
                      size_t size,
                      VmcodeObjectLocation* location) {
  if (mapping == nullptr || size < 4) {
    return false;
  }

  const size_t search_size = std::min<size_t>(size, 64 * 1024);
  for (size_t offset = 0; offset + 4 <= search_size; offset++) {
    const uint8_t* current = mapping + offset;
    if (IsElfMagic(current)) {
      *location = {PatchObjectFormat::kElf, offset};
      return true;
    }
    if (IsMachOMagic(current)) {
      *location = {PatchObjectFormat::kMachO, offset};
      return true;
    }
  }

  return false;
}

const char* FormatName(PatchObjectFormat format) {
  switch (format) {
    case PatchObjectFormat::kElf:
      return "ELF";
    case PatchObjectFormat::kMachO:
      return "Mach-O";
  }
  return "unknown";
}

}  // namespace

// PatchCacheEntry implementation

std::shared_ptr<PatchCacheEntry> PatchCacheEntry::Create(
    const std::string& path) {
  // vmcode files may be raw AOT snapshots or snapshots after a compact linker
  // header. Scan for the loadable object header instead of assuming offset 0.
  auto patch_mapping = fml::FileMapping::CreateReadOnly(path);
  if (!patch_mapping) {
    FML_LOG(ERROR) << "Failed to map file: " << path;
    return nullptr;
  }

  VmcodeObjectLocation object_location;
  if (!FindVmcodeObject(patch_mapping->GetMapping(), patch_mapping->GetSize(),
                        &object_location)) {
    FML_LOG(ERROR) << "Failed to find an AOT snapshot object in patch: "
                   << path;
    return nullptr;
  }

  const char* error = nullptr;
  // The VM Snapshot is identical for all binaries produced by a given version
  // of Dart. Our linker checks this and will fail to link if ever the VM
  // snapshot changes. We ignore the VM data/instrs here.
  const uint8_t* ignored_vm_data = nullptr;
  const uint8_t* ignored_vm_instrs = nullptr;
  const uint8_t* isolate_data = nullptr;
  const uint8_t* isolate_instrs = nullptr;

  void* loaded_object = nullptr;
  if (object_location.format == PatchObjectFormat::kElf) {
    loaded_object = Dart_LoadELF(
        path.c_str(), object_location.file_offset, &error, &ignored_vm_data,
        &ignored_vm_instrs, &isolate_data, &isolate_instrs,
        dart::bin::kReadOnly);
  } else {
#if defined(FML_OS_MACOSX)
    loaded_object =
        Dart_LoadMachODylib(path.c_str(), object_location.file_offset, &error,
                            &isolate_data, &isolate_instrs);
#else
    error = "Mach-O patch snapshots are only supported on Apple platforms.";
#endif
  }

  if (loaded_object == nullptr) {
    FML_LOG(ERROR) << "Failed to load " << FormatName(object_location.format)
                   << " patch at " << path << " error: "
                   << (error == nullptr ? "unknown error" : error);
    return nullptr;
  }

  FML_LOG(INFO) << "Loaded " << FormatName(object_location.format)
                << " patch from " << path;

  return std::shared_ptr<PatchCacheEntry>(
      new PatchCacheEntry(path, object_location.format, loaded_object,
                          isolate_data, isolate_instrs));
}

PatchCacheEntry::PatchCacheEntry(const std::string& path,
                                 PatchObjectFormat object_format,
                                 void* loaded_object,
                                 const uint8_t* isolate_data,
                                 const uint8_t* isolate_instrs)
    : path_(path),
      object_format_(object_format),
      loaded_object_(loaded_object),
      isolate_data_(isolate_data),
      isolate_instrs_(isolate_instrs) {}

PatchCacheEntry::~PatchCacheEntry() {
  if (loaded_object_ != nullptr) {
    FML_LOG(INFO) << "Unloading patch from " << path_;
    switch (object_format_) {
      case PatchObjectFormat::kElf:
        Dart_UnloadELF(reinterpret_cast<Dart_LoadedElf*>(loaded_object_));
        break;
      case PatchObjectFormat::kMachO:
#if defined(FML_OS_MACOSX)
        Dart_UnloadMachODylib(
            reinterpret_cast<Dart_LoadedMachODylib*>(loaded_object_));
#else
        FML_LOG(ERROR) << "Mach-O patch loaded on a non-Apple platform.";
#endif
        break;
    }
    loaded_object_ = nullptr;
  }
}

PatchCache& PatchCache::Instance() {
  static PatchCache instance;
  return instance;
}

std::shared_ptr<PatchCacheEntry> PatchCache::GetOrLoad(
    const std::string& path) {
  std::lock_guard<std::mutex> lock(mutex_);

  // Check if we have a cached entry that's still alive
  auto it = cache_.find(path);
  if (it != cache_.end()) {
    if (auto entry = it->second.lock()) {
      FML_LOG(INFO) << "PatchCache hit for " << path;
      return entry;
    }
    // Entry expired, remove it
    cache_.erase(it);
  }

  // Load a new entry
  auto entry = PatchCacheEntry::Create(path);
  if (entry) {
    cache_[path] = entry;  // Store weak_ptr
  }

  return entry;
}

void PatchCache::PruneExpired() {
  std::lock_guard<std::mutex> lock(mutex_);

  for (auto it = cache_.begin(); it != cache_.end();) {
    if (it->second.expired()) {
      it = cache_.erase(it);
    } else {
      ++it;
    }
  }
}

std::shared_ptr<const fml::Mapping> TryLoadFromPatch(
    const std::vector<std::string>& native_library_paths,
    const char* symbol_name) {
  if (native_library_paths.empty()) {
    return nullptr;
  }

  // Check if the first path is a Shorebird patch (.vmcode file)
  const auto& patch_path = native_library_paths.front();
  bool is_patch = patch_path.find(".vmcode") != std::string::npos;
  if (!is_patch) {
    return nullptr;
  }

  // Patches only contain isolate data/instructions, not VM data/instructions.
  // Return nullptr for VM symbols to allow fallback to the base app.
  std::string symbol(symbol_name);
  if (symbol != kIsolateDataSymbol && symbol != kIsolateInstructionsSymbol) {
    return nullptr;
  }

  // Load the patch using the cache.
  auto cache_entry = PatchCache::Instance().GetOrLoad(patch_path);
  if (!cache_entry) {
    FML_LOG(FATAL) << "Failed to load symbol from patch at " << patch_path;
    return nullptr;
  }

  FML_LOG(INFO) << "Loading symbol from patch: " << symbol_name;

  // ReportLaunchStart is now called from ResolveIsolateData in
  // dart_snapshot.cc, which runs before TryLoadFromPatch on all platforms.

  if (symbol == kIsolateDataSymbol) {
    return PatchMapping::CreateIsolateData(cache_entry);
  } else {
    FML_CHECK(symbol == kIsolateInstructionsSymbol);
    return PatchMapping::CreateIsolateInstructions(cache_entry);
  }
}

}  // namespace flutter

// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "flutter/runtime/shorebird/mixed_patch.h"

#include <cstring>
#include <mutex>
#include <vector>

#include "flutter/fml/file.h"
#include "flutter/fml/logging.h"
#include "flutter/fml/mapping.h"
#include "openssl/sha.h"
#include "third_party/dart/runtime/bin/elf_loader.h"
#include "third_party/dart/runtime/include/dart_mixed_mode_api.h"

namespace flutter {
namespace shorebird {

namespace {

constexpr uint8_t kVmcodeMagic[8] = {'O', 'S', 'B', 'V', 'M', 'C', 0, 1};
constexpr size_t kHeaderSize = 128;
constexpr uint64_t kElfAlignment = 16384;

uint32_t ReadU32(const uint8_t* p) {
  uint32_t v;
  memcpy(&v, p, sizeof(v));
  return v;
}

uint64_t ReadU64(const uint8_t* p) {
  uint64_t v;
  memcpy(&v, p, sizeof(v));
  return v;
}

struct Vmcode {
  uint64_t elf_offset = 0;
  std::vector<Dart_MixedLink> links;
};

// Same checks as the host embedder (dart-sdk runtime/bin/main_impl.cc).
const char* ParseVmcode(const uint8_t* bytes,
                        uint64_t length,
                        const uint8_t* release_text,
                        Vmcode* out) {
  if (length < kHeaderSize || memcmp(bytes, kVmcodeMagic, 8) != 0) {
    return "bad vmcode magic";
  }
  if (ReadU32(bytes + 8) != 1) {
    return "unsupported vmcode version";
  }
  const uint64_t offset = ReadU64(bytes + 16);
  const uint64_t elf_size = ReadU64(bytes + 24);
  const uint32_t count = ReadU32(bytes + 32);
  if (ReadU32(bytes + 12) != offset || offset % kElfAlignment != 0 ||
      ReadU32(bytes + 36) != sizeof(Dart_MixedLink) ||
      ReadU32(bytes + 40) != kHeaderSize || ReadU32(bytes + 44) != 0 ||
      kHeaderSize + uint64_t{count} * sizeof(Dart_MixedLink) > offset ||
      offset > length || length - offset != elf_size) {
    return "malformed vmcode header";
  }
  for (uint64_t i = kHeaderSize + uint64_t{count} * sizeof(Dart_MixedLink);
       i < offset; i++) {
    if (bytes[i] != 0) {
      return "malformed vmcode padding";
    }
  }
  uint8_t digest[SHA256_DIGEST_LENGTH];
  SHA256(bytes + offset, elf_size, digest);
  if (memcmp(digest, bytes + 80, sizeof(digest)) != 0) {
    return "vmcode ELF hash mismatch";
  }
  if (release_text == nullptr) {
    return "no release text to check the patch against";
  }
  // The release text hash covers the shipped App.framework _kDartSnapshotText
  // region, `release text image size` bytes long (COMPILER_LINKER.md 6.1).
  SHA256(release_text, ReadU32(bytes + 112), digest);
  if (memcmp(digest, bytes + 48, sizeof(digest)) != 0) {
    return "patch was linked against a different release";
  }
  out->elf_offset = offset;
  out->links.resize(count);
  if (count > 0) {
    memcpy(out->links.data(), bytes + kHeaderSize,
           count * sizeof(Dart_MixedLink));
  }
  return nullptr;
}

}  // namespace

namespace {

std::optional<MixedPatchSnapshot> LoadMixedPatchOnce(
    const std::string& path,
    const std::shared_ptr<const fml::Mapping>& release_instructions) {
  auto reject = [&path](const char* reason) {
    FML_LOG(ERROR) << "Shorebird mixed mode: patch " << path
                   << " rejected (" << reason << "); running the release";
    Dart_MixedModeDeactivate();
    return std::nullopt;
  };
  const uint8_t* release_text =
      release_instructions ? release_instructions->GetMapping() : nullptr;

  Vmcode vmcode;
  {
    auto file = fml::FileMapping::CreateReadOnly(path);
    if (!file || file->GetMapping() == nullptr) {
      return reject("cannot map the patch");
    }
    if (const char* error = ParseVmcode(file->GetMapping(), file->GetSize(),
                                        release_text, &vmcode)) {
      return reject(error);
    }
  }

  // The patch text is mapped readable only: the CPU never executes it.
  dart::bin::elf_loader_map_text_read_only = true;
  const char* error = nullptr;
  const uint8_t* patch_data = nullptr;
  const uint8_t* patch_text = nullptr;
  Dart_LoadedElf* elf = Dart_LoadELF(path.c_str(), vmcode.elf_offset, &error,
                                     &patch_data, &patch_text);
  dart::bin::elf_loader_map_text_read_only = false;
  if (elf == nullptr) {
    return reject(error != nullptr ? error : "cannot load the patch ELF");
  }
  if (patch_data == nullptr || patch_text == nullptr) {
    Dart_UnloadELF(elf);
    return reject("the patch ELF has no isolate snapshot");
  }
  // Never pass nullptr records: that would request identity linking.
  static const Dart_MixedLink kNoLinks[1] = {};
  const Dart_MixedLink* links =
      vmcode.links.empty() ? kNoLinks : vmcode.links.data();
  if (!Dart_MixedModeRegisterImages(patch_text, release_text, links,
                                    vmcode.links.size(), &error) ||
      !Dart_MixedModeLinkSnapshot(patch_data, patch_text, &error)) {
    Dart_UnloadELF(elf);
    return reject(error);
  }
  FML_LOG(INFO) << "Shorebird mixed mode: patch " << path << " linked ("
                << vmcode.links.size() << " linked entries)";
  // The ELF stays loaded for the life of the process: its isolate data and
  // text back every isolate group created from the snapshot.
  MixedPatchSnapshot snapshot;
  snapshot.data = std::make_shared<fml::NonOwnedMapping>(patch_data, 0,
                                                         nullptr, true);
  snapshot.instructions = std::make_shared<fml::NonOwnedMapping>(
      patch_text, 0, nullptr, true);
  return snapshot;
}

}  // namespace

std::optional<MixedPatchSnapshot> LoadMixedPatch(
    const std::string& path,
    const std::shared_ptr<const fml::Mapping>& release_instructions) {
  // The VM holds one patch per process (gates are process-global), and the
  // engine may resolve the isolate snapshot more than once. Decide once.
  static std::mutex mutex;
  static bool decided = false;
  static std::string decided_path;
  static std::optional<MixedPatchSnapshot> decided_snapshot;
  std::scoped_lock lock(mutex);
  if (!decided) {
    decided = true;
    decided_path = path;
    decided_snapshot = LoadMixedPatchOnce(path, release_instructions);
  } else if (path != decided_path) {
    FML_LOG(ERROR) << "Shorebird mixed mode: a different patch was requested "
                      "after "
                   << decided_path << "; running the release";
    return std::nullopt;
  }
  return decided_snapshot;
}

}  // namespace shorebird
}  // namespace flutter

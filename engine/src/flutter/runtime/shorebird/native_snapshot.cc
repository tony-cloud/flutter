// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "flutter/runtime/shorebird/native_snapshot.h"

#include "flutter/fml/build_config.h"

#if FML_OS_ANDROID
#include <android/dlext.h>
#include <dlfcn.h>
#include <limits.h>
#include <unistd.h>

#include <cstdlib>

#include <mutex>
#include <string>

#include "flutter/fml/native_library.h"
#include "flutter/runtime/dart_snapshot.h"
#include "flutter/shell/common/shorebird/updater.h"  // nogncheck

namespace flutter::shorebird {
namespace {
struct NativeSnapshot {
  uint64_t selection_id = 0;
  std::shared_ptr<const fml::Mapping> data;
  std::shared_ptr<const fml::Mapping> instructions;
};

// Dynamic-linker images must survive engine teardown: new engines in this
// process reuse precisely this image and both mappings retain its handle.
std::mutex snapshot_mutex;
NativeSnapshot snapshot;

bool LoadSnapshot(PreparedBootSource& source) {
  std::lock_guard<std::mutex> lock(snapshot_mutex);
  if (snapshot.selection_id == source.selection_id()) {
    return true;
  }
  fml::RefPtr<fml::NativeLibrary> library;
  std::string image_identity;
  if (source.kind() == PreparedBootSource::Kind::kFD) {
    // Identity observation only: never pass this procfs path to any loader.
    // Bionic records the FD's realpath as the image name. Rust gives each
    // memfd a unique process-local label, so dependencies cannot satisfy this
    // exact identity check merely by exporting the same snapshot symbols.
    const auto fd_link = "/proc/self/fd/" + std::to_string(source.fd());
    char identity[PATH_MAX];
    const auto length = readlink(fd_link.c_str(), identity, sizeof(identity));
    if (length <= 0 || static_cast<size_t>(length) == sizeof(identity)) {
      return false;
    }
    image_identity.assign(identity, length);
    android_dlextinfo info = {};
    info.flags = ANDROID_DLEXT_USE_LIBRARY_FD;
    info.library_fd = source.fd();  // android_dlopen_ext borrows this FD.
    // Do not reuse libapp.so's linker lookup identity. No force-load flag or
    // private namespace changes are needed for a single immutable selection.
    const auto name = "shorebird-patch-" +
                      std::to_string(source.selection_id()) + "-" +
                      std::to_string(source.patch_number()) + ".so";
    void* handle = android_dlopen_ext(name.c_str(), RTLD_NOW, &info);
    if (handle) {
      library = fml::NativeLibrary::CreateWithHandle(handle, true);
    }
  } else if (source.kind() == PreparedBootSource::Kind::kPath) {
    char identity[PATH_MAX];
    if (!realpath(source.path().c_str(), identity)) {
      return false;
    }
    image_identity = identity;
    library = fml::NativeLibrary::Create(source.path().c_str());
  }
  if (!library) {
    return false;
  }
  // SymbolMapping preserves the existing underscore-prefixed fallback and
  // owns the NativeLibrary. Publish neither half until both are present.
  auto data = std::make_shared<fml::SymbolMapping>(
      library, DartSnapshot::kIsolateDataSymbol);
  auto instructions = std::make_shared<fml::SymbolMapping>(
      library, DartSnapshot::kIsolateInstructionsSymbol);
  if (!data->GetMapping() || !instructions->GetMapping()) {
    return false;
  }
  Dl_info data_image = {};
  Dl_info instructions_image = {};
  if (!dladdr(data->GetMapping(), &data_image) ||
      !dladdr(instructions->GetMapping(), &instructions_image) ||
      !data_image.dli_fbase ||
      data_image.dli_fbase != instructions_image.dli_fbase ||
      !data_image.dli_fname || !instructions_image.dli_fname ||
      image_identity != data_image.dli_fname ||
      image_identity != instructions_image.dli_fname) {
    // dlsym(handle) also searches dependencies. A non-null pair is
    // insufficient: both addresses must originate in this prepared image, not
    // libapp.so or another dependency. Ambiguous identity is a retryable
    // refusal.
    return false;
  }
  snapshot = {source.selection_id(), std::move(data), std::move(instructions)};
  return true;
}
}  // namespace

bool ResolvePreparedAndroidSnapshot(
    std::shared_ptr<const fml::Mapping>& data,
    std::shared_ptr<const fml::Mapping>& instructions) {
  bool base = false;
  const bool loaded =
      Updater::Instance().LoadPreparedBootSource(LoadSnapshot, [&base]() {
        base = true;
        return true;
      });
  if (!loaded) {
    return false;
  }
  if (!base) {
    std::lock_guard<std::mutex> lock(snapshot_mutex);
    data = snapshot.data;
    instructions = snapshot.instructions;
  }
  return true;
}

}  // namespace flutter::shorebird
#endif  // FML_OS_ANDROID

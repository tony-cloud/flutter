// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "flutter/shell/platform/embedder/shorebird_aot_data.h"

#include "flutter/fml/native_library.h"
#include "flutter/runtime/dart_snapshot.h"
#include "flutter/runtime/dart_vm.h"
#include "flutter/shell/common/shorebird/shorebird.h"

namespace flutter::shorebird {

bool ConfigureSignedInterpreterHost(const ShorebirdConfigArgs& args,
                                    Settings& settings) {
#if FML_OS_MACOSX && !FML_OS_IOS && (FML_ARCH_CPU_ARM64 || FML_ARCH_CPU_X86_64)
  // Full replacement can execute only the reviewed, signed host's snapshot.
  // Reject user-supplied snapshot buffers, ELF data and command-line overrides.
  if (!flutter::DartVM::IsRunningPrecompiledCode() ||
      args.release_app_library_path.empty() || settings.vm_snapshot_data ||
      settings.vm_snapshot_instr || settings.isolate_snapshot_data ||
      settings.isolate_snapshot_instr ||
      !settings.vm_snapshot_data_path.empty() ||
      !settings.vm_snapshot_instr_path.empty() ||
      !settings.isolate_snapshot_data_path.empty() ||
      !settings.isolate_snapshot_instr_path.empty() ||
      !settings.application_library_paths.empty()) {
    return false;
  }
  auto library =
      fml::NativeLibrary::Create(args.release_app_library_path.c_str());
  if (!library) {
    return false;
  }
  const auto* data =
      library->ResolveSymbol(flutter::DartSnapshot::kVMDataSymbol);
  const auto* instructions =
      library->ResolveSymbol(flutter::DartSnapshot::kVMInstructionsSymbol);
  if (!data || !instructions) {
    return false;
  }
  // Both VM and isolate use the same signed pair. Capture the library in each
  // mapping, so settings copies and spawned engines retain its loaded image.
  auto mapping = [library](const uint8_t* bytes) {
    return [library, bytes]() {
      return std::make_unique<fml::NonOwnedMapping>(
          bytes, 0, [library](const uint8_t*, size_t) {});
    };
  };
  settings.vm_snapshot_data = mapping(data);
  settings.vm_snapshot_instr = mapping(instructions);
  settings.isolate_snapshot_data = mapping(data);
  settings.isolate_snapshot_instr = mapping(instructions);
  settings.application_library_paths = {args.release_app_library_path};
  return flutter::ConfigureShorebirdInterpreter(args, settings);
#else
  // Never fall through on unsupported hosts to native ELF loading, JIT, or
  // an inactive application snapshot.
  return false;
#endif
}

}  // namespace flutter::shorebird

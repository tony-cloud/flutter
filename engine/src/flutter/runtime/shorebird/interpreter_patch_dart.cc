// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
#include "flutter/runtime/shorebird/interpreter_patch.h"

#include <mutex>

namespace flutter::shorebird {
namespace {
class DartInterpreterPatchApi final : public InterpreterPatchApi {
 public:
  void SetKeyCallback(Dart_AotPatchKeyCallback callback) override {
    static std::once_flag callback_once;
    std::call_once(callback_once,
                   [callback] { Dart_SetAotPatchKeyCallback(callback); });
  }
  bool Install(const fml::Mapping& artifact,
               const Dart_AotPatchInstallOptions& options,
               uint8_t** payload,
               intptr_t* length,
               std::string* error) override {
    if (!Dart_IsPrecompiledRuntime() || !Dart_AotPatchingEnabled()) {
      *error = "Interpreter patch requires an AOT patch-enabled runtime";
      return false;
    }
    return Check(Dart_InstallAotPatch(artifact.GetMapping(), artifact.GetSize(),
                                      &options, payload, length),
                 error);
  }
  bool Reload(const uint8_t* payload,
              intptr_t length,
              std::string* error) override {
    return Check(Dart_ReloadBytecodePatch(payload, length), error);
  }
  void FreePayload(uint8_t* payload) override {
    Dart_FreeAotPatchPayload(payload);
  }

 private:
  static bool Check(Dart_Handle result, std::string* error) {
    if (Dart_IsError(result)) {
      *error = Dart_GetError(result);
      return false;
    }
    return true;
  }
};
}  // namespace

bool ApplyInterpreterPatch(const InterpreterPatchConfig& config,
                           std::string* error) {
  auto artifact = fml::FileMapping::CreateReadOnly(config.path);
  if (!artifact) {
    *error = "Could not map selected interpreter patch";
    return false;
  }
  DartInterpreterPatchApi api;
  return ApplyInterpreterPatch(config, *artifact, api, error);
}
bool ApplyInterpreterReplacementBase(
    const InterpreterReplacementBaseConfig& config,
    std::string* error) {
  if (!config.validation_error.empty()) {
    *error = config.validation_error;
    return false;
  }
  auto artifact = fml::FileMapping::CreateReadOnly(config.path);
  if (!artifact) {
    *error = "Could not map bundled interpreter replacement base";
    return false;
  }
  DartInterpreterPatchApi api;
  // The signed application's immutable asset needs neither an envelope nor an
  // app-owned AES key. Both paths use the same VM replacement loader.
  return ApplyInterpreterReplacementBase(config, *artifact, api, error);
}
}  // namespace flutter::shorebird

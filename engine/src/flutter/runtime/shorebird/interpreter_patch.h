// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
#ifndef FLUTTER_RUNTIME_SHOREBIRD_INTERPRETER_PATCH_H_
#define FLUTTER_RUNTIME_SHOREBIRD_INTERPRETER_PATCH_H_

#include <functional>
#include <memory>
#include <string>

#include "flutter/fml/mapping.h"
#include "third_party/dart/runtime/include/dart_api.h"

namespace flutter::shorebird {

// Immutable expectations from the signed application bundle. The future patch
// hash comes from the authenticated envelope, never from baseline settings.
struct InterpreterPatchConfig {
  std::string path;
  std::string app_id;
  std::string app_build_id;
  std::string base_flavor_id;
  std::string base_license_type;
  std::string flavor_id;
  std::string license_type;
  std::string sdk_hash;
  std::string base_snapshot_hash;
  std::string obfuscation_map_hash;
  std::string key_id;
  bool strict_verification = false;
};

using InterpreterKeyProvider =
    std::function<bool(const char*, uint8_t*, intptr_t, intptr_t*)>;

// Process-wide, immutable after registration. Must be supplied by the native
// app before constructing its first Flutter project/engine. Never logs keys.
bool RegisterInterpreterKeyProvider(InterpreterKeyProvider provider);
void SealInterpreterKeyProvider();
// Latch the process boot choice, including a base-only boot. Background
// downloads must not change code for a later independently created engine.
std::shared_ptr<const InterpreterPatchConfig> SelectInterpreterPatchForProcess(
    std::shared_ptr<const InterpreterPatchConfig> candidate);
bool RejectInterpreterPatchForProcess();
void CompleteInterpreterMainForProcess(bool succeeded);
void ResetInterpreterKeyProviderForTesting();

// Small seam for exercising the production install sequence without executing
// downloaded code or requiring a Dart isolate in unit tests.
class InterpreterPatchApi {
 public:
  virtual ~InterpreterPatchApi() = default;
  virtual void SetKeyCallback(Dart_AotPatchKeyCallback callback) = 0;
  virtual bool Install(const fml::Mapping& artifact,
                       const Dart_AotPatchInstallOptions& options,
                       uint8_t** payload,
                       intptr_t* length,
                       std::string* error) = 0;
  virtual bool Reload(const uint8_t* payload,
                      intptr_t length,
                      std::string* error) = 0;
  virtual void FreePayload(uint8_t* payload) = 0;
};

// Called inside the base root isolate's Dart scope, after libraries exist and
// before making it runnable. Failure requires destroying that isolate group.
bool ApplyInterpreterPatch(const InterpreterPatchConfig& config,
                           const fml::Mapping& artifact,
                           InterpreterPatchApi& api,
                           std::string* error);
bool ApplyInterpreterPatch(const InterpreterPatchConfig& config,
                           std::string* error);

}  // namespace flutter::shorebird
#endif

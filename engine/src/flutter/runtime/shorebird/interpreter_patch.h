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
  bool full_replacement = false;
  std::string host_abi;
};

// Signed bundle data, independent of updater availability and licensed keys.
// An invalid compiled full-profile configuration is retained to fail startup;
// silently dropping it would try to run the inactive native application.
inline constexpr char kReplacementBaseAsset[] =
    "shorebird_replacement_base.sbr";
struct InterpreterReplacementBaseConfig {
  std::string path;
  std::string snapshot_hash;
  std::string host_abi;
  std::string validation_error;
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

// Choose exactly one install in a fresh group. An update failure returns to
// the caller to destroy the group; it never installs base into a touched group.
// Install callbacks let native tests verify selection without executing code.
bool InstallInterpreterCodeForFreshGroup(
    const InterpreterPatchConfig* patch,
    const InterpreterReplacementBaseConfig* base,
    const std::function<bool()>& install_patch,
    const std::function<bool()>& install_base,
    std::string* error);

// Validation performs no VM mutation. The VM additionally validates the native
// descriptor, complete library domain, root and component before installation.
bool ValidateInterpreterReplacementBase(
    const InterpreterReplacementBaseConfig& config,
    const fml::Mapping& artifact,
    std::string* error);
bool ApplyInterpreterReplacementBase(
    const InterpreterReplacementBaseConfig& config,
    const fml::Mapping& artifact,
    InterpreterPatchApi& api,
    std::string* error);
bool ApplyInterpreterReplacementBase(
    const InterpreterReplacementBaseConfig& config,
    std::string* error);

}  // namespace flutter::shorebird
#endif

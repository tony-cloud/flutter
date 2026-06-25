// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "flutter/runtime/dart_isolate.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <optional>
#include <string_view>
#include <utility>

#include "flutter/fml/build_config.h"
#include "flutter/fml/file.h"
#include "flutter/fml/logging.h"
#include "flutter/fml/mapping.h"
#include "flutter/fml/posix_wrappers.h"
#include "flutter/fml/trace_event.h"
#include "flutter/lib/io/dart_io.h"
#include "flutter/lib/ui/dart_runtime_hooks.h"
#include "flutter/lib/ui/dart_ui.h"
#include "flutter/runtime/dart_isolate_group_data.h"
#include "flutter/runtime/dart_plugin_registrant.h"
#include "flutter/runtime/dart_service_isolate.h"
#include "flutter/runtime/dart_vm.h"
#include "flutter/runtime/dart_vm_lifecycle.h"
#include "flutter/runtime/isolate_configuration.h"
#include "flutter/runtime/platform_isolate_manager.h"
#include "flutter/shell/common/shorebird/shorebird.h"
#include "flutter/shell/common/shorebird/updater.h"
#include "fml/message_loop_task_queues.h"
#include "fml/task_source.h"
#include "fml/time/time_point.h"
#include "third_party/dart/runtime/include/bin/native_assets_api.h"
#include "third_party/dart/runtime/include/dart_api.h"
#include "third_party/dart/runtime/include/dart_tools_api.h"
#include "third_party/tonic/converter/dart_converter.h"
#include "third_party/tonic/dart_class_library.h"
#include "third_party/tonic/dart_class_provider.h"
#include "third_party/tonic/dart_message_handler.h"
#include "third_party/tonic/dart_state.h"
#include "third_party/tonic/logging/dart_invoke.h"
#include "third_party/tonic/scopes/dart_api_scope.h"
#include "third_party/tonic/scopes/dart_isolate_scope.h"

namespace flutter {

namespace {

constexpr std::string_view kFileUriPrefix = "file://";

#if SHOREBIRD_USE_INTERPRETER
struct JsonStringValue {
  const char* chars = nullptr;
  intptr_t length = 0;

  std::string ToString() const { return std::string(chars, length); }
};

struct ShorebirdAotPatchKeyState {
  std::string key_id;
  std::array<uint8_t, 32> key = {};
  shorebird::AotPatchKeyCallback app_key_callback;
  bool is_configured = false;
};

static ShorebirdAotPatchKeyState g_shorebird_aot_patch_key_state;

void WriteShorebirdInterpreterPatchStage(const std::string& active_path,
                                         const std::string& stage) {
  std::string marker_path = active_path;
  const auto patches = active_path.rfind("/patches/");
  if (patches != std::string::npos) {
    marker_path =
        active_path.substr(0, patches) + "/last_interpreter_reload.stage";
  } else {
    marker_path += ".stage";
  }

  const auto separator = marker_path.find_last_of('/');
  if (separator == std::string::npos) {
    return;
  }

  const std::string directory_path = marker_path.substr(0, separator);
  const std::string stage_file_name = marker_path.substr(separator + 1);
  fml::UniqueFD directory = fml::OpenDirectory(directory_path.c_str(), false,
                                               fml::FilePermission::kRead);
  if (!directory.is_valid()) {
    return;
  }

  const std::string content = stage + "\n";
  fml::NonOwnedMapping mapping(reinterpret_cast<const uint8_t*>(content.data()),
                               content.size());
  fml::WriteAtomically(directory, stage_file_name.c_str(), mapping);
}

bool IsJsonWhitespace(char c) {
  return c == ' ' || c == '\n' || c == '\r' || c == '\t';
}

void SkipJsonWhitespace(const char* json, intptr_t json_length, intptr_t* pos) {
  while (*pos < json_length && IsJsonWhitespace(json[*pos])) {
    (*pos)++;
  }
}

bool ParseJsonString(const char* json,
                     intptr_t json_length,
                     intptr_t* pos,
                     JsonStringValue* out) {
  if (*pos >= json_length || json[*pos] != '"') {
    return false;
  }
  (*pos)++;
  const intptr_t start = *pos;
  while (*pos < json_length) {
    const char c = json[*pos];
    if (c == '\\') {
      // Open patch artifact metadata is stable ASCII. Reject escaped strings
      // here so raw comparisons cannot silently accept ambiguous metadata.
      return false;
    }
    if (c == '"') {
      out->chars = json + start;
      out->length = *pos - start;
      (*pos)++;
      return true;
    }
    if (static_cast<unsigned char>(c) < 0x20) {
      return false;
    }
    (*pos)++;
  }
  return false;
}

bool JsonStringEquals(const JsonStringValue& value, const char* expected) {
  const intptr_t expected_length = strlen(expected);
  return value.length == expected_length &&
         strncmp(value.chars, expected, value.length) == 0;
}

std::optional<std::string> FindJsonString(const fml::Mapping& mapping,
                                          const char* key) {
  const char* json = reinterpret_cast<const char*>(mapping.GetMapping());
  const intptr_t json_length = static_cast<intptr_t>(mapping.GetSize());
  intptr_t pos = 0;
  while (pos < json_length) {
    if (json[pos] != '"') {
      pos++;
      continue;
    }

    JsonStringValue current_key;
    if (!ParseJsonString(json, json_length, &pos, &current_key)) {
      return std::nullopt;
    }
    SkipJsonWhitespace(json, json_length, &pos);
    if (pos >= json_length || json[pos] != ':') {
      continue;
    }
    pos++;
    SkipJsonWhitespace(json, json_length, &pos);

    if (!JsonStringEquals(current_key, key)) {
      continue;
    }
    JsonStringValue value;
    if (!ParseJsonString(json, json_length, &pos, &value)) {
      return std::nullopt;
    }
    return value.ToString();
  }
  return std::nullopt;
}

std::string UnquoteYamlValue(std::string value) {
  if (value.size() >= 2 && ((value.front() == '"' && value.back() == '"') ||
                            (value.front() == '\'' && value.back() == '\''))) {
    return value.substr(1, value.size() - 2);
  }
  return value;
}

std::string YamlValue(const shorebird::AppConfig& config,
                      const std::string& key) {
  return UnquoteYamlValue(GetValueFromYaml(config.yaml_config, key));
}

std::string RequiredJsonString(const fml::Mapping& artifact,
                               const char* key,
                               const std::string& path,
                               bool* ok) {
  auto value = FindJsonString(artifact, key);
  if (value.has_value() && !value->empty()) {
    return *value;
  }
  FML_LOG(ERROR) << "Shorebird updater: encrypted interpreter patch is missing "
                 << key << ": " << path;
  *ok = false;
  return "";
}

std::string YamlValueOrRequiredJson(const shorebird::AppConfig& config,
                                    const std::string& yaml_key,
                                    const fml::Mapping& artifact,
                                    const char* json_key,
                                    const std::string& path,
                                    bool* ok) {
  std::string value = YamlValue(config, yaml_key);
  if (!value.empty()) {
    return value;
  }
  return RequiredJsonString(artifact, json_key, path, ok);
}

std::string CurrentTargetOs() {
#if FML_OS_IOS
  return "ios";
#elif FML_OS_ANDROID
  return "android";
#elif FML_OS_MACOSX
  return "macos";
#elif FML_OS_LINUX
  return "linux";
#elif FML_OS_WIN
  return "windows";
#else
  return "";
#endif
}

std::string CurrentTargetArch() {
#if FML_ARCH_CPU_ARM64
  return "arm64";
#elif FML_ARCH_CPU_X86_64
  return "x64";
#elif FML_ARCH_CPU_ARMEL
  return "arm";
#elif FML_ARCH_CPU_X86
  return "ia32";
#else
  return "";
#endif
}

int HexNibble(char c) {
  if ('0' <= c && c <= '9') {
    return c - '0';
  }
  if ('a' <= c && c <= 'f') {
    return 10 + (c - 'a');
  }
  if ('A' <= c && c <= 'F') {
    return 10 + (c - 'A');
  }
  return -1;
}

bool ParseAes256KeyHex(const std::string& key_hex,
                       std::array<uint8_t, 32>* key) {
  if (key_hex.size() != key->size() * 2) {
    return false;
  }
  for (size_t i = 0; i < key->size(); i++) {
    const int high = HexNibble(key_hex[i * 2]);
    const int low = HexNibble(key_hex[(i * 2) + 1]);
    if (high < 0 || low < 0) {
      return false;
    }
    (*key)[i] = static_cast<uint8_t>((high << 4) | low);
  }
  return true;
}

bool ShorebirdAotPatchKeyCallback(const char* key_id,
                                  uint8_t* key_buffer,
                                  intptr_t key_buffer_length,
                                  intptr_t* key_length) {
  const auto& state = g_shorebird_aot_patch_key_state;
  if (!state.is_configured || key_buffer == nullptr || key_length == nullptr ||
      key_buffer_length < static_cast<intptr_t>(state.key.size())) {
    return false;
  }
  if (state.app_key_callback) {
    return state.app_key_callback(key_id, key_buffer, key_buffer_length,
                                  key_length);
  }
  if (!state.key_id.empty() &&
      (key_id == nullptr || state.key_id != std::string(key_id))) {
    return false;
  }
  memmove(key_buffer, state.key.data(), state.key.size());
  *key_length = static_cast<intptr_t>(state.key.size());
  return true;
}

class ScopedShorebirdAotPatchKeyCallback {
 public:
  explicit ScopedShorebirdAotPatchKeyCallback(
      shorebird::AotPatchKeyCallback app_key_callback) {
    g_shorebird_aot_patch_key_state.app_key_callback =
        std::move(app_key_callback);
    g_shorebird_aot_patch_key_state.is_configured = true;
    Dart_SetAotPatchKeyCallback(ShorebirdAotPatchKeyCallback);
  }

  ScopedShorebirdAotPatchKeyCallback(std::string key_id,
                                     std::array<uint8_t, 32> key) {
    g_shorebird_aot_patch_key_state.key_id = std::move(key_id);
    g_shorebird_aot_patch_key_state.key = key;
    g_shorebird_aot_patch_key_state.is_configured = true;
    Dart_SetAotPatchKeyCallback(ShorebirdAotPatchKeyCallback);
  }

  ~ScopedShorebirdAotPatchKeyCallback() {
    Dart_SetAotPatchKeyCallback(nullptr);
    std::fill(g_shorebird_aot_patch_key_state.key.begin(),
              g_shorebird_aot_patch_key_state.key.end(), 0);
    g_shorebird_aot_patch_key_state.key_id.clear();
    g_shorebird_aot_patch_key_state.app_key_callback = nullptr;
    g_shorebird_aot_patch_key_state.is_configured = false;
  }

 private:
  FML_DISALLOW_COPY_AND_ASSIGN(ScopedShorebirdAotPatchKeyCallback);
};

std::shared_ptr<const fml::Mapping> InstallEncryptedShorebirdInterpreterPatch(
    const fml::Mapping& artifact,
    const std::string& path) {
  auto config = shorebird::Updater::Instance().LastAppConfig();
  if (!config.has_value()) {
    FML_LOG(ERROR) << "Shorebird updater: encrypted interpreter patch selected "
                      "before updater initialization: "
                   << path;
    return nullptr;
  }

  bool ok = true;
  const auto app_key_callback = config->aot_patch_key_callback;
  std::array<uint8_t, 32> key = {};
  std::string key_id;
  if (!app_key_callback) {
    const std::string key_hex = YamlValue(*config, "aot_patch_key_hex");
    if (!ParseAes256KeyHex(key_hex, &key)) {
      FML_LOG(ERROR) << "Shorebird updater: configure an app-owned AOT patch "
                        "key callback or provide a development-only "
                        "aot_patch_key_hex value as 64 hex characters in "
                        "shorebird.yaml to install encrypted interpreter "
                        "patches.";
      return nullptr;
    }
    key_id = YamlValue(*config, "aot_patch_key_id");
    if (key_id.empty()) {
      key_id = RequiredJsonString(artifact, "key_id", path, &ok);
    }
  }

  std::string app_id = config->app_id.empty()
                           ? RequiredJsonString(artifact, "app_id", path, &ok)
                           : config->app_id;
  std::string app_build_id =
      config->release_version.empty()
          ? RequiredJsonString(artifact, "app_build_id", path, &ok)
          : config->release_version;
  std::string base_flavor_id = YamlValue(*config, "aot_patch_base_flavor_id");
  std::string base_license_type =
      YamlValue(*config, "aot_patch_base_license_type");
  std::string flavor_id = YamlValueOrRequiredJson(
      *config, "aot_patch_flavor_id", artifact, "flavor_id", path, &ok);
  std::string license_type = YamlValueOrRequiredJson(
      *config, "aot_patch_license_type", artifact, "license_type", path, &ok);
  std::string sdk_hash = YamlValueOrRequiredJson(
      *config, "aot_patch_sdk_hash", artifact, "sdk_hash", path, &ok);
  std::string base_snapshot_hash =
      YamlValueOrRequiredJson(*config, "aot_patch_base_snapshot_hash", artifact,
                              "base_snapshot_hash", path, &ok);
  std::string patch_snapshot_hash =
      RequiredJsonString(artifact, "patch_snapshot_hash", path, &ok);
  std::string obfuscation_map_hash =
      YamlValue(*config, "aot_patch_obfuscation_map_hash");
  if (obfuscation_map_hash.empty()) {
    obfuscation_map_hash =
        FindJsonString(artifact, "obfuscation_map_hash").value_or("");
  }
  std::string target_os = CurrentTargetOs();
  std::string target_arch = CurrentTargetArch();
  if (target_os.empty() || target_arch.empty()) {
    FML_LOG(ERROR) << "Shorebird updater: unsupported target for encrypted "
                      "interpreter patch.";
    ok = false;
  }
  if (!ok) {
    return nullptr;
  }

  Dart_AotPatchInstallOptions options = {};
  options.app_id = app_id.c_str();
  options.app_build_id = app_build_id.c_str();
  options.base_flavor_id =
      base_flavor_id.empty() ? nullptr : base_flavor_id.c_str();
  options.base_license_type =
      base_license_type.empty() ? nullptr : base_license_type.c_str();
  options.flavor_id = flavor_id.c_str();
  options.license_type = license_type.c_str();
  options.sdk_hash = sdk_hash.c_str();
  options.base_snapshot_hash = base_snapshot_hash.c_str();
  options.patch_snapshot_hash = patch_snapshot_hash.c_str();
  options.obfuscation_map_hash =
      obfuscation_map_hash.empty() ? nullptr : obfuscation_map_hash.c_str();
  options.target_os = target_os.c_str();
  options.target_arch = target_arch.c_str();
  options.runtime_mode = "dart-bytecode-interpreter";

  uint8_t* patch_payload = nullptr;
  intptr_t patch_payload_length = 0;
  if (app_key_callback) {
    ScopedShorebirdAotPatchKeyCallback scoped_key(app_key_callback);
    Dart_Handle install_result = Dart_InstallAotPatch(
        artifact.GetMapping(), static_cast<intptr_t>(artifact.GetSize()),
        &options, &patch_payload, &patch_payload_length);
    if (tonic::CheckAndHandleError(install_result)) {
      return nullptr;
    }
  } else {
    ScopedShorebirdAotPatchKeyCallback scoped_key(key_id, key);
    Dart_Handle install_result = Dart_InstallAotPatch(
        artifact.GetMapping(), static_cast<intptr_t>(artifact.GetSize()),
        &options, &patch_payload, &patch_payload_length);
    if (tonic::CheckAndHandleError(install_result)) {
      return nullptr;
    }
  }
  if (patch_payload == nullptr || patch_payload_length <= 0) {
    FML_LOG(ERROR) << "Shorebird updater: encrypted interpreter patch "
                      "decrypted to an empty payload: "
                   << path;
    if (patch_payload != nullptr) {
      Dart_FreeAotPatchPayload(patch_payload);
    }
    return nullptr;
  }

  auto payload_mapping = std::make_shared<fml::NonOwnedMapping>(
      patch_payload, static_cast<size_t>(patch_payload_length),
      [](const uint8_t* data, size_t size) {
        Dart_FreeAotPatchPayload(const_cast<uint8_t*>(data));
      });
  if (!Dart_IsBytecode(payload_mapping->GetMapping(),
                       payload_mapping->GetSize())) {
    FML_LOG(ERROR) << "Shorebird updater: decrypted interpreter patch payload "
                      "is not Dart bytecode: "
                   << path;
    return nullptr;
  }
  return payload_mapping;
}

bool ApplyShorebirdBytecodePatch(
    const std::shared_ptr<const fml::Mapping>& mapping,
    const std::string& active_path) {
  if (!Dart_IsBytecode(mapping->GetMapping(), mapping->GetSize())) {
    FML_LOG(ERROR) << "Shorebird updater: interpreter patch payload is not "
                      "Dart bytecode: "
                   << active_path;
    WriteShorebirdInterpreterPatchStage(active_path,
                                        "reload_error: payload_not_bytecode");
    shorebird::Updater::Instance().ReportLaunchFailure();
    return true;
  }
  FML_LOG(INFO) << "Shorebird updater: applying interpreter reload patch: "
                << active_path << " (" << mapping->GetSize() << " bytes)";
  WriteShorebirdInterpreterPatchStage(active_path, "reload_begin");
  Dart_Handle reload_result = Dart_ReloadBytecodePatch(
      mapping->GetMapping(), static_cast<intptr_t>(mapping->GetSize()));
  if (Dart_IsError(reload_result)) {
    const char* error = Dart_GetError(reload_result);
    WriteShorebirdInterpreterPatchStage(
        active_path,
        std::string("reload_error: ") + (error == nullptr ? "" : error));
    FML_LOG(ERROR) << "Shorebird updater: interpreter reload patch failed: "
                   << (error == nullptr ? "" : error);
    shorebird::Updater::Instance().ReportLaunchFailure();
    return true;
  }
  if (tonic::CheckAndHandleError(reload_result)) {
    shorebird::Updater::Instance().ReportLaunchFailure();
    return true;
  }

  WriteShorebirdInterpreterPatchStage(active_path, "reload_success");
  shorebird::Updater::Instance().ReportLaunchSuccess();
  FML_LOG(INFO) << "Shorebird updater: applied interpreter reload patch: "
                << active_path;
  return true;
}

bool LoadShorebirdInterpreterPatchIfNeeded() {
  std::string active_path = shorebird::Updater::Instance().NextBootPatchPath();
  if (active_path.empty()) {
    shorebird::Updater::Instance().ReportLaunchSuccess();
    return true;
  }

  auto file_mapping = fml::FileMapping::CreateReadOnly(active_path);
  if (!file_mapping || file_mapping->GetSize() == 0) {
    FML_LOG(ERROR) << "Shorebird updater: interpreter patch is not readable: "
                   << active_path;
    WriteShorebirdInterpreterPatchStage(active_path,
                                        "reload_error: patch_not_readable");
    shorebird::Updater::Instance().ReportLaunchFailure();
    return true;
  }

  std::shared_ptr<const fml::Mapping> mapping(std::move(file_mapping));
  if (!Dart_IsBytecode(mapping->GetMapping(), mapping->GetSize())) {
    mapping = InstallEncryptedShorebirdInterpreterPatch(*mapping, active_path);
    if (!mapping) {
      WriteShorebirdInterpreterPatchStage(active_path,
                                          "reload_error: decrypt_failed");
      shorebird::Updater::Instance().ReportLaunchFailure();
      return true;
    }
  }

  return ApplyShorebirdBytecodePatch(mapping, active_path);
}
#endif  // SHOREBIRD_USE_INTERPRETER

class DartErrorString {
 public:
  DartErrorString() {}
  ~DartErrorString() {
    if (str_) {
      ::free(str_);
    }
  }
  char** error() { return &str_; }
  const char* str() const { return str_; }
  explicit operator bool() const { return str_ != nullptr; }

 private:
  FML_DISALLOW_COPY_AND_ASSIGN(DartErrorString);
  char* str_ = nullptr;
};

}  // anonymous namespace

DartIsolate::Flags::Flags() : Flags(nullptr) {}

DartIsolate::Flags::Flags(const Dart_IsolateFlags* flags) {
  if (flags) {
    flags_ = *flags;
  } else {
    ::Dart_IsolateFlagsInitialize(&flags_);
  }
}

DartIsolate::Flags::~Flags() = default;

void DartIsolate::Flags::SetNullSafetyEnabled(bool enabled) {
  flags_.null_safety = enabled;
}

void DartIsolate::Flags::SetIsDontNeedSafe(bool value) {
  flags_.snapshot_is_dontneed_safe = value;
}

Dart_IsolateFlags DartIsolate::Flags::Get() const {
  return flags_;
}

std::weak_ptr<DartIsolate> DartIsolate::CreateRunningRootIsolate(
    const Settings& settings,
    const fml::RefPtr<const DartSnapshot>& isolate_snapshot,
    std::unique_ptr<PlatformConfiguration> platform_configuration,
    Flags isolate_flags,
    const fml::closure& root_isolate_create_callback,
    const fml::closure& isolate_create_callback,
    const fml::closure& isolate_shutdown_callback,
    std::optional<std::string> dart_entrypoint,
    std::optional<std::string> dart_entrypoint_library,
    const std::vector<std::string>& dart_entrypoint_args,
    std::unique_ptr<IsolateConfiguration> isolate_configuration,
    const UIDartState::Context& context,
    const DartIsolate* spawning_isolate,
    std::shared_ptr<NativeAssetsManager> native_assets_manager) {
  if (!isolate_snapshot) {
    FML_LOG(ERROR) << "Invalid isolate snapshot.";
    return {};
  }

  if (!isolate_configuration) {
    FML_LOG(ERROR) << "Invalid isolate configuration.";
    return {};
  }

  isolate_flags.SetNullSafetyEnabled(
      isolate_configuration->IsNullSafetyEnabled(*isolate_snapshot));
  isolate_flags.SetIsDontNeedSafe(isolate_snapshot->IsDontNeedSafe());

  auto isolate = CreateRootIsolate(settings,                           //
                                   isolate_snapshot,                   //
                                   std::move(platform_configuration),  //
                                   isolate_flags,                      //
                                   isolate_create_callback,            //
                                   isolate_shutdown_callback,          //
                                   context,                            //
                                   spawning_isolate,                   //
                                   std::move(native_assets_manager)    //
                                   )
                     .lock();

  if (!isolate) {
    FML_LOG(ERROR) << "Could not create root isolate.";
    return {};
  }

  fml::ScopedCleanupClosure shutdown_on_error([isolate]() {
    if (!isolate->Shutdown()) {
      FML_DLOG(ERROR) << "Could not shutdown transient isolate.";
    }
  });

  if (isolate->GetPhase() != DartIsolate::Phase::LibrariesSetup) {
    FML_LOG(ERROR) << "Root isolate was created in an incorrect phase: "
                   << static_cast<int>(isolate->GetPhase());
    return {};
  }

  if (!isolate_configuration->PrepareIsolate(*isolate.get())) {
    FML_LOG(ERROR) << "Could not prepare isolate.";
    return {};
  }

  if (isolate->GetPhase() != DartIsolate::Phase::Ready) {
    FML_LOG(ERROR) << "Root isolate not in the ready phase for Dart entrypoint "
                      "invocation.";
    return {};
  }

  {
    tonic::DartState::Scope scope(isolate.get());
    if (settings.merged_platform_ui_thread !=
        Settings::MergedPlatformUIThread::kMergeAfterLaunch) {
      Dart_SetCurrentThreadOwnsIsolate();
    }

    if (settings.root_isolate_create_callback) {
      // Isolate callbacks always occur in isolate scope and before user code
      // has had a chance to run.
      settings.root_isolate_create_callback(*isolate.get());
    }
  }

  if (root_isolate_create_callback) {
    root_isolate_create_callback();
  }

  if (!isolate->RunFromLibrary(std::move(dart_entrypoint_library),  //
                               std::move(dart_entrypoint),          //
                               dart_entrypoint_args)) {
    FML_LOG(ERROR) << "Could not run the run main Dart entrypoint.";
    return {};
  }

  if (settings.root_isolate_shutdown_callback) {
    isolate->AddIsolateShutdownCallback(
        settings.root_isolate_shutdown_callback);
  }

  shutdown_on_error.Release();

  return isolate;
}

void DartIsolate::SpawnIsolateShutdownCallback(
    std::shared_ptr<DartIsolateGroupData>* isolate_group_data,
    std::shared_ptr<DartIsolate>* isolate_data) {
  DartIsolate::DartIsolateShutdownCallback(isolate_group_data, isolate_data);
}

std::weak_ptr<DartIsolate> DartIsolate::CreateRootIsolate(
    const Settings& settings,
    fml::RefPtr<const DartSnapshot> isolate_snapshot,
    std::unique_ptr<PlatformConfiguration> platform_configuration,
    const Flags& flags,
    const fml::closure& isolate_create_callback,
    const fml::closure& isolate_shutdown_callback,
    const UIDartState::Context& context,
    const DartIsolate* spawning_isolate,
    std::shared_ptr<NativeAssetsManager> native_assets_manager) {
  TRACE_EVENT0("flutter", "DartIsolate::CreateRootIsolate");

  // Only needed if this is the main isolate for the group.
  std::unique_ptr<std::shared_ptr<DartIsolateGroupData>> isolate_group_data;

  auto isolate_data = std::make_unique<std::shared_ptr<DartIsolate>>(
      std::shared_ptr<DartIsolate>(new DartIsolate(
          /*settings=*/settings,
          /*is_root_isolate=*/true,
          /*context=*/context,
          /*is_spawning_in_group=*/!!spawning_isolate)));

  DartErrorString error;
  Dart_Isolate vm_isolate = nullptr;
  auto isolate_flags = flags.Get();

  IsolateMaker isolate_maker;
  if (spawning_isolate) {
    isolate_maker =
        [spawning_isolate](
            std::shared_ptr<DartIsolateGroupData>* isolate_group_data,
            std::shared_ptr<DartIsolate>* isolate_data,
            Dart_IsolateFlags* flags, char** error) {
          return Dart_CreateIsolateInGroup(
              /*group_member=*/spawning_isolate->isolate(),
              /*name=*/
              spawning_isolate->GetIsolateGroupData()
                  .GetAdvisoryScriptEntrypoint()
                  .c_str(),
              /*shutdown_callback=*/
              reinterpret_cast<Dart_IsolateShutdownCallback>(
                  DartIsolate::SpawnIsolateShutdownCallback),
              /*cleanup_callback=*/
              reinterpret_cast<Dart_IsolateCleanupCallback>(
                  DartIsolateCleanupCallback),
              /*child_isolate_data=*/isolate_data,
              /*error=*/error);
        };
  } else {
    // The child isolate preparer is null but will be set when the isolate is
    // being prepared to run.
    isolate_group_data =
        std::make_unique<std::shared_ptr<DartIsolateGroupData>>(
            std::shared_ptr<DartIsolateGroupData>(new DartIsolateGroupData(
                settings,                            // settings
                std::move(isolate_snapshot),         // isolate snapshot
                context.advisory_script_uri,         // advisory URI
                context.advisory_script_entrypoint,  // advisory entrypoint
                nullptr,                             // child isolate preparer
                isolate_create_callback,             // isolate create callback
                isolate_shutdown_callback,        // isolate shutdown callback
                std::move(native_assets_manager)  //
                )));
    isolate_maker = [](std::shared_ptr<DartIsolateGroupData>*
                           isolate_group_data,
                       std::shared_ptr<DartIsolate>* isolate_data,
                       Dart_IsolateFlags* flags, char** error) {
      return Dart_CreateIsolateGroup(
          (*isolate_group_data)->GetAdvisoryScriptURI().c_str(),
          (*isolate_group_data)->GetAdvisoryScriptEntrypoint().c_str(),
          (*isolate_group_data)->GetIsolateSnapshot()->GetDataMapping(),
          (*isolate_group_data)->GetIsolateSnapshot()->GetInstructionsMapping(),
          flags, isolate_group_data, isolate_data, error);
    };
  }

  vm_isolate = CreateDartIsolateGroup(std::move(isolate_group_data),
                                      std::move(isolate_data), &isolate_flags,
                                      error.error(), isolate_maker);

  if (error) {
    FML_LOG(ERROR) << "CreateRootIsolate failed: " << error.str();
  }

  if (vm_isolate == nullptr) {
    return {};
  }

  std::shared_ptr<DartIsolate>* root_isolate_data =
      static_cast<std::shared_ptr<DartIsolate>*>(Dart_IsolateData(vm_isolate));

  (*root_isolate_data)
      ->SetPlatformConfiguration(std::move(platform_configuration));

  return (*root_isolate_data)->GetWeakIsolatePtr();
}

Dart_Isolate DartIsolate::CreatePlatformIsolate(Dart_Handle entry_point,
                                                char** error) {
  *error = nullptr;
  PlatformConfiguration* platform_config = platform_configuration();
  FML_DCHECK(platform_config != nullptr);
  std::shared_ptr<PlatformIsolateManager> platform_isolate_manager =
      platform_config->client()->GetPlatformIsolateManager();
  std::weak_ptr<PlatformIsolateManager> weak_platform_isolate_manager =
      platform_isolate_manager;
  if (platform_isolate_manager->HasShutdownMaybeFalseNegative()) {
    // Don't set the error string. We want to silently ignore this error,
    // because the engine is shutting down.
    FML_LOG(INFO) << "CreatePlatformIsolate called after shutdown";
    return nullptr;
  }

  Dart_Isolate parent_isolate = isolate();
  Dart_ExitIsolate();  // Exit parent_isolate.

  const TaskRunners& task_runners = GetTaskRunners();
  fml::RefPtr<fml::TaskRunner> platform_task_runner =
      task_runners.GetPlatformTaskRunner();
  FML_DCHECK(platform_task_runner);

  auto isolate_group_data = std::shared_ptr<DartIsolateGroupData>(
      *static_cast<std::shared_ptr<DartIsolateGroupData>*>(
          Dart_IsolateGroupData(parent_isolate)));

  Settings settings(isolate_group_data->GetSettings());

  // PlatformIsolate.spawn should behave like Isolate.spawn when unhandled
  // exceptions happen (log the exception, but don't terminate the app). But the
  // default unhandled_exception_callback may terminate the app, because it is
  // only called for the root isolate (child isolates are managed by the VM and
  // have a different error code path). So override it to simply log the error.
  settings.unhandled_exception_callback = [](const std::string& error,
                                             const std::string& stack_trace) {
    FML_LOG(ERROR) << "Unhandled exception:\n" << error << "\n" << stack_trace;
    return true;
  };

  // The platform isolate task observer must be added on the platform thread. So
  // schedule the add function on the platform task runner.
  TaskObserverAdd old_task_observer_add = settings.task_observer_add;
  settings.task_observer_add = [old_task_observer_add, platform_task_runner,
                                weak_platform_isolate_manager](
                                   intptr_t key, const fml::closure& callback) {
    platform_task_runner->PostTask([old_task_observer_add,
                                    weak_platform_isolate_manager, key,
                                    callback]() {
      std::shared_ptr<PlatformIsolateManager> platform_isolate_manager =
          weak_platform_isolate_manager.lock();
      if (platform_isolate_manager == nullptr ||
          platform_isolate_manager->HasShutdown()) {
        // Shutdown happened in between this task being posted, and it running.
        // platform_isolate has already been shut down. Do nothing.
        FML_LOG(INFO) << "Shutdown before platform isolate task observer added";
        return;
      }
      old_task_observer_add(key, callback);
    });
    return platform_task_runner->GetTaskQueueId();
  };

  UIDartState::Context context(task_runners);
  context.advisory_script_uri = isolate_group_data->GetAdvisoryScriptURI();
  context.advisory_script_entrypoint =
      isolate_group_data->GetAdvisoryScriptEntrypoint();
  auto isolate_data = std::make_unique<std::shared_ptr<DartIsolate>>(
      std::shared_ptr<DartIsolate>(
          new DartIsolate(settings, context, platform_isolate_manager)));

  IsolateMaker isolate_maker =
      [parent_isolate](
          std::shared_ptr<DartIsolateGroupData>* unused_isolate_group_data,
          std::shared_ptr<DartIsolate>* isolate_data, Dart_IsolateFlags* flags,
          char** error) {
        return Dart_CreateIsolateInGroup(
            /*group_member=*/parent_isolate,
            /*name=*/"PlatformIsolate",
            /*shutdown_callback=*/
            reinterpret_cast<Dart_IsolateShutdownCallback>(
                DartIsolate::SpawnIsolateShutdownCallback),
            /*cleanup_callback=*/
            reinterpret_cast<Dart_IsolateCleanupCallback>(
                DartIsolateCleanupCallback),
            /*child_isolate_data=*/isolate_data,
            /*error=*/error);
      };
  Dart_Isolate platform_isolate = CreateDartIsolateGroup(
      nullptr, std::move(isolate_data), nullptr, error, isolate_maker);

  Dart_EnterIsolate(parent_isolate);

  if (*error) {
    return nullptr;
  }

  if (!platform_isolate_manager->RegisterPlatformIsolate(platform_isolate)) {
    // The PlatformIsolateManager was shutdown while we were creating the
    // isolate. This means that we're shutting down the engine. We need to
    // shutdown the platform isolate.
    FML_LOG(INFO) << "Shutdown during platform isolate creation";
    tonic::DartIsolateScope isolate_scope(platform_isolate);
    Dart_ShutdownIsolate();
    return nullptr;
  }

  tonic::DartApiScope api_scope;
  Dart_PersistentHandle entry_point_handle =
      Dart_NewPersistentHandle(entry_point);

  platform_task_runner->PostTask([entry_point_handle, platform_isolate,
                                  weak_platform_isolate_manager]() {
    std::shared_ptr<PlatformIsolateManager> platform_isolate_manager =
        weak_platform_isolate_manager.lock();
    if (platform_isolate_manager == nullptr ||
        platform_isolate_manager->HasShutdown()) {
      // Shutdown happened in between this task being posted, and it running.
      // platform_isolate has already been shut down. Do nothing.
      FML_LOG(INFO) << "Shutdown before platform isolate entry point";
      return;
    }

    tonic::DartIsolateScope isolate_scope(platform_isolate);
    tonic::DartApiScope api_scope;
    Dart_Handle entry_point = Dart_HandleFromPersistent(entry_point_handle);
    Dart_DeletePersistentHandle(entry_point_handle);

    // Disable Isolate.exit().
    Dart_Handle isolate_lib = Dart_LookupLibrary(tonic::ToDart("dart:isolate"));
    FML_CHECK(!tonic::CheckAndHandleError(isolate_lib));
    Dart_Handle isolate_type = Dart_GetNonNullableType(
        isolate_lib, tonic::ToDart("Isolate"), 0, nullptr);
    FML_CHECK(!tonic::CheckAndHandleError(isolate_type));
    Dart_Handle result =
        Dart_SetField(isolate_type, tonic::ToDart("_mayExit"), Dart_False());
    FML_CHECK(!tonic::CheckAndHandleError(result));

    tonic::DartInvokeVoid(entry_point);
  });

  return platform_isolate;
}

DartIsolate::DartIsolate(const Settings& settings,
                         bool is_root_isolate,
                         const UIDartState::Context& context,
                         bool is_spawning_in_group)
    : UIDartState(settings.task_observer_add,
                  settings.task_observer_remove,
                  settings.log_tag,
                  settings.unhandled_exception_callback,
                  settings.log_message_callback,
                  DartVMRef::GetIsolateNameServer(),
                  is_root_isolate,
                  context),
      may_insecurely_connect_to_all_domains_(
          settings.may_insecurely_connect_to_all_domains),
      is_platform_isolate_(false),
      is_spawning_in_group_(is_spawning_in_group),
      domain_network_policy_(settings.domain_network_policy) {
  phase_ = Phase::Uninitialized;
}

DartIsolate::DartIsolate(
    const Settings& settings,
    const UIDartState::Context& context,
    std::shared_ptr<PlatformIsolateManager> platform_isolate_manager)
    : UIDartState(settings.task_observer_add,
                  settings.task_observer_remove,
                  settings.log_tag,
                  settings.unhandled_exception_callback,
                  settings.log_message_callback,
                  DartVMRef::GetIsolateNameServer(),
                  false,  // is_root_isolate
                  context),
      may_insecurely_connect_to_all_domains_(
          settings.may_insecurely_connect_to_all_domains),
      is_platform_isolate_(true),
      is_spawning_in_group_(false),
      domain_network_policy_(settings.domain_network_policy),
      platform_isolate_manager_(std::move(platform_isolate_manager)) {
  phase_ = Phase::Uninitialized;
}

DartIsolate::~DartIsolate() {
  if (IsRootIsolate() && GetMessageHandlingTaskRunner()) {
    FML_DCHECK(GetMessageHandlingTaskRunner()->RunsTasksOnCurrentThread());
  }
}

DartIsolate::Phase DartIsolate::GetPhase() const {
  return phase_;
}

std::string DartIsolate::GetServiceId() {
  const char* service_id_buf = Dart_IsolateServiceId(isolate());
  std::string service_id(service_id_buf);
  free(const_cast<char*>(service_id_buf));
  return service_id;
}

bool DartIsolate::Initialize(Dart_Isolate dart_isolate) {
  TRACE_EVENT0("flutter", "DartIsolate::Initialize");
  if (phase_ != Phase::Uninitialized) {
    return false;
  }

  FML_DCHECK(dart_isolate != nullptr);
  FML_DCHECK(dart_isolate == Dart_CurrentIsolate());

  // After this point, isolate scopes can be safely used.
  SetIsolate(dart_isolate);

  // For the root isolate set the "AppStartUp" as soon as the root isolate
  // has been initialized. This is to ensure that all the timeline events
  // that have the set user-tag will be listed user AppStartUp.
  if (IsRootIsolate()) {
    tonic::DartApiScope api_scope;
    Dart_SetCurrentUserTag(Dart_NewUserTag("AppStartUp"));
  }

  if (is_platform_isolate_) {
    SetMessageHandlingTaskRunner(GetTaskRunners().GetPlatformTaskRunner(),
                                 true);
  } else {
    // When running with custom UI task runner post directly to runner (there is
    // no task queue).
    bool post_directly_to_runner =
        GetTaskRunners().GetUITaskRunner() &&
        !GetTaskRunners().GetUITaskRunner()->GetTaskQueueId().is_valid();
    SetMessageHandlingTaskRunner(GetTaskRunners().GetUITaskRunner(),
                                 post_directly_to_runner);
  }

  if (tonic::CheckAndHandleError(
          Dart_SetLibraryTagHandler(tonic::DartState::HandleLibraryTag))) {
    return false;
  }

  if (tonic::CheckAndHandleError(
          Dart_SetDeferredLoadHandler(OnDartLoadLibrary))) {
    return false;
  }

  if (!UpdateThreadPoolNames()) {
    return false;
  }

  phase_ = Phase::Initialized;
  return true;
}

fml::RefPtr<fml::TaskRunner> DartIsolate::GetMessageHandlingTaskRunner() const {
  return message_handling_task_runner_;
}

bool DartIsolate::LoadLoadingUnit(
    intptr_t loading_unit_id,
    std::unique_ptr<const fml::Mapping> snapshot_data,
    std::unique_ptr<const fml::Mapping> snapshot_instructions) {
  tonic::DartState::Scope scope(this);

  fml::RefPtr<DartSnapshot> dart_snapshot =
      DartSnapshot::IsolateSnapshotFromMappings(
          std::move(snapshot_data), std::move(snapshot_instructions));

  Dart_Handle result = Dart_DeferredLoadComplete(
      loading_unit_id, dart_snapshot->GetDataMapping(),
      dart_snapshot->GetInstructionsMapping());
  if (tonic::CheckAndHandleError(result)) {
    LoadLoadingUnitError(loading_unit_id, Dart_GetError(result),
                         /*transient*/ true);
    return false;
  }
  loading_unit_snapshots_.insert(dart_snapshot);
  return true;
}

void DartIsolate::LoadLoadingUnitError(intptr_t loading_unit_id,
                                       const std::string& error_message,
                                       bool transient) {
  tonic::DartState::Scope scope(this);
  Dart_Handle result = Dart_DeferredLoadCompleteError(
      loading_unit_id, error_message.c_str(), transient);
  tonic::CheckAndHandleError(result);
}

void DartIsolate::SetMessageHandlingTaskRunner(
    const fml::RefPtr<fml::TaskRunner>& runner,
    bool post_directly_to_runner) {
  if (!runner) {
    return;
  }

  message_handling_task_runner_ = runner;

  tonic::DartMessageHandler::TaskDispatcher dispatcher;

#ifdef OS_FUCHSIA
  post_directly_to_runner = true;
#endif

  if (post_directly_to_runner) {
    dispatcher = [runner](std::function<void()> task) {
      runner->PostTask([task = std::move(task)]() {
        TRACE_EVENT0("flutter", "DartIsolate::HandleMessage");
        task();
      });
    };
  } else {
    dispatcher = [runner](std::function<void()> task) {
      auto task_queues = fml::MessageLoopTaskQueues::GetInstance();
      task_queues->RegisterTask(
          runner->GetTaskQueueId(),
          [task = std::move(task)]() {
            TRACE_EVENT0("flutter", "DartIsolate::HandleMessage");
            task();
          },
          fml::TimePoint::Now(), fml::TaskSourceGrade::kDartEventLoop);
    };
  }

  message_handler().Initialize(dispatcher);
}

// Updating thread names here does not change the underlying OS thread names.
// Instead, this is just additional metadata for the Dart VM Service to show the
// thread name of the isolate.
bool DartIsolate::UpdateThreadPoolNames() const {
  // TODO(chinmaygarde): This implementation does not account for multiple
  // shells sharing the same (or subset of) threads.
  const auto& task_runners = GetTaskRunners();

  if (auto task_runner = task_runners.GetRasterTaskRunner()) {
    task_runner->PostTask(
        [label = task_runners.GetLabel() + std::string{".raster"}]() {
          Dart_SetThreadName(label.c_str());
        });
  }

  if (auto task_runner = task_runners.GetUITaskRunner()) {
    task_runner->PostTask(
        [label = task_runners.GetLabel() + std::string{".ui"}]() {
          Dart_SetThreadName(label.c_str());
        });
  }

  if (auto task_runner = task_runners.GetIOTaskRunner()) {
    task_runner->PostTask(
        [label = task_runners.GetLabel() + std::string{".io"}]() {
          Dart_SetThreadName(label.c_str());
        });
  }

  if (auto task_runner = task_runners.GetPlatformTaskRunner()) {
    bool is_merged_platform_ui_thread =
        task_runner == task_runners.GetUITaskRunner();
    std::string label;
    if (is_merged_platform_ui_thread) {
      label = task_runners.GetLabel() + std::string{".ui"};
    } else {
      label = task_runners.GetLabel() + std::string{".platform"};
    }
    task_runner->PostTask(
        [label = std::move(label)]() { Dart_SetThreadName(label.c_str()); });
  }

  return true;
}

bool DartIsolate::LoadLibraries() {
  TRACE_EVENT0("flutter", "DartIsolate::LoadLibraries");
  if (phase_ != Phase::Initialized) {
    return false;
  }

  tonic::DartState::Scope scope(this);

  DartIO::InitForIsolate(may_insecurely_connect_to_all_domains_,
                         domain_network_policy_, GetAdvisoryScriptURI());

  const auto& settings = GetIsolateGroupData().GetSettings();

  DartUI::InitForIsolate(settings);

  const bool is_service_isolate = Dart_IsServiceIsolate(isolate());

  DartRuntimeHooks::Install(IsRootIsolate() && !is_service_isolate,
                            settings.profile_microtasks,
                            GetAdvisoryScriptURI());

  if (!is_service_isolate) {
    class_library().add_provider(
        "ui", std::make_unique<tonic::DartClassProvider>(this, "dart:ui"));
  }

  phase_ = Phase::LibrariesSetup;
  return true;
}

bool DartIsolate::PrepareForRunningFromPrecompiledCode() {
  TRACE_EVENT0("flutter", "DartIsolate::PrepareForRunningFromPrecompiledCode");
  if (phase_ != Phase::LibrariesSetup) {
    return false;
  }

  tonic::DartState::Scope scope(this);

  if (Dart_IsNull(Dart_RootLibrary())) {
    return false;
  }

#if SHOREBIRD_USE_INTERPRETER
  if (IsRootIsolate() && !Dart_IsServiceIsolate(isolate()) &&
      !LoadShorebirdInterpreterPatchIfNeeded()) {
    return false;
  }
#endif  // SHOREBIRD_USE_INTERPRETER

  if (!MarkIsolateRunnable()) {
    return false;
  }

  if (GetIsolateGroupData().GetChildIsolatePreparer() == nullptr) {
    GetIsolateGroupData().SetChildIsolatePreparer([](DartIsolate* isolate) {
      return isolate->PrepareForRunningFromPrecompiledCode();
    });
  }

  const fml::closure& isolate_create_callback =
      GetIsolateGroupData().GetIsolateCreateCallback();
  if (isolate_create_callback) {
    isolate_create_callback();
  }

  phase_ = Phase::Ready;
  return true;
}

bool DartIsolate::LoadKernel(const std::shared_ptr<const fml::Mapping>& mapping,
                             bool last_piece) {
  if (!Dart_IsKernel(mapping->GetMapping(), mapping->GetSize())) {
    return false;
  }

  // Mapping must be retained until isolate group shutdown.
  GetIsolateGroupData().AddKernelBuffer(mapping);

  Dart_Handle library =
      Dart_LoadLibraryFromKernel(mapping->GetMapping(), mapping->GetSize());
  if (tonic::CheckAndHandleError(library)) {
    return false;
  }

  if (!last_piece) {
    // More to come.
    return true;
  }

  Dart_SetRootLibrary(library);
  if (tonic::CheckAndHandleError(Dart_FinalizeLoading(false))) {
    return false;
  }
  return true;
}

[[nodiscard]] bool DartIsolate::PrepareForRunningFromKernel(
    const std::shared_ptr<const fml::Mapping>& mapping,
    bool child_isolate,
    bool last_piece) {
  TRACE_EVENT0("flutter", "DartIsolate::PrepareForRunningFromKernel");
  if (phase_ != Phase::LibrariesSetup) {
    return false;
  }

  if (DartVM::IsRunningPrecompiledCode()) {
    return false;
  }

  tonic::DartState::Scope scope(this);

  if (!child_isolate && !is_spawning_in_group_) {
    if (!mapping || mapping->GetSize() == 0) {
      return false;
    }

    // Use root library provided by kernel in favor of one provided by snapshot.
    Dart_SetRootLibrary(Dart_Null());

    if (!LoadKernel(mapping, last_piece)) {
      return false;
    }
  }

  if (!last_piece) {
    // More to come.
    return true;
  }

  if (Dart_IsNull(Dart_RootLibrary())) {
    return false;
  }

  if (!MarkIsolateRunnable()) {
    return false;
  }

  // Child isolate shares root isolate embedder_isolate (lines 691 and 693
  // below). Re-initializing child_isolate_preparer_ lambda while it is being
  // executed leads to crashes.
  if (GetIsolateGroupData().GetChildIsolatePreparer() == nullptr) {
    GetIsolateGroupData().SetChildIsolatePreparer(
        [buffers =
             GetIsolateGroupData().GetKernelBuffers()](DartIsolate* isolate) {
          for (uint64_t i = 0; i < buffers.size(); i++) {
            bool last_piece = i + 1 == buffers.size();
            const std::shared_ptr<const fml::Mapping>& buffer = buffers.at(i);
            if (!isolate->PrepareForRunningFromKernel(buffer,
                                                      /*child_isolate=*/true,
                                                      last_piece)) {
              return false;
            }
          }
          return true;
        });
  }

  const fml::closure& isolate_create_callback =
      GetIsolateGroupData().GetIsolateCreateCallback();
  if (isolate_create_callback) {
    isolate_create_callback();
  }

  phase_ = Phase::Ready;

  return true;
}

[[nodiscard]] bool DartIsolate::PrepareForRunningFromKernels(
    std::vector<std::shared_ptr<const fml::Mapping>> kernels) {
  const auto count = kernels.size();
  if (count == 0) {
    return false;
  }

  for (size_t i = 0; i < count; ++i) {
    bool last = (i == (count - 1));
    if (!PrepareForRunningFromKernel(kernels[i], /*child_isolate=*/false,
                                     last)) {
      return false;
    }
  }

  return true;
}

[[nodiscard]] bool DartIsolate::PrepareForRunningFromKernels(
    std::vector<std::unique_ptr<const fml::Mapping>> kernels) {
  std::vector<std::shared_ptr<const fml::Mapping>> shared_kernels;
  shared_kernels.reserve(kernels.size());
  for (auto& kernel : kernels) {
    shared_kernels.emplace_back(std::move(kernel));
  }
  return PrepareForRunningFromKernels(shared_kernels);
}

bool DartIsolate::MarkIsolateRunnable() {
  TRACE_EVENT0("flutter", "DartIsolate::MarkIsolateRunnable");
  if (phase_ != Phase::LibrariesSetup) {
    return false;
  }

  // This function may only be called from an active isolate scope.
  if (Dart_CurrentIsolate() != isolate()) {
    return false;
  }

  // There must be no current isolate to mark an isolate as being runnable.
  Dart_ExitIsolate();

  char* error = Dart_IsolateMakeRunnable(isolate());
  if (error) {
    FML_DLOG(ERROR) << error;
    ::free(error);
    // Failed. Restore the isolate.
    Dart_EnterIsolate(isolate());
    return false;
  }
  // Success. Restore the isolate.
  Dart_EnterIsolate(isolate());
  return true;
}

[[nodiscard]] static bool InvokeMainEntrypoint(
    Dart_Handle user_entrypoint_function,
    Dart_Handle args) {
  if (tonic::CheckAndHandleError(user_entrypoint_function)) {
    FML_LOG(ERROR) << "Could not resolve main entrypoint function.";
    return false;
  }

  Dart_Handle start_main_isolate_function =
      tonic::DartInvokeField(Dart_LookupLibrary(tonic::ToDart("dart:isolate")),
                             "_getStartMainIsolateFunction", {});

  if (tonic::CheckAndHandleError(start_main_isolate_function)) {
    FML_LOG(ERROR) << "Could not resolve main entrypoint trampoline.";
    return false;
  }

  if (tonic::CheckAndHandleError(tonic::DartInvokeField(
          Dart_LookupLibrary(tonic::ToDart("dart:ui")), "_runMain",
          {start_main_isolate_function, user_entrypoint_function, args}))) {
    FML_LOG(ERROR) << "Could not invoke the main entrypoint.";
    return false;
  }

  return true;
}

bool DartIsolate::RunFromLibrary(std::optional<std::string> library_name,
                                 std::optional<std::string> entrypoint,
                                 const std::vector<std::string>& args) {
  TRACE_EVENT0("flutter", "DartIsolate::RunFromLibrary");
  if (phase_ != Phase::Ready) {
    return false;
  }

  tonic::DartState::Scope scope(this);

  auto library_handle =
      library_name.has_value() && !library_name.value().empty()
          ? ::Dart_LookupLibrary(tonic::ToDart(library_name.value().c_str()))
          : ::Dart_RootLibrary();
  auto entrypoint_handle = entrypoint.has_value() && !entrypoint.value().empty()
                               ? tonic::ToDart(entrypoint.value().c_str())
                               : tonic::ToDart("main");

  if (!FindAndInvokeDartPluginRegistrant()) {
    // TODO(gaaclarke): Remove once the framework PR lands that uses `--source`
    // to compile the Dart Plugin Registrant
    // (https://github.com/flutter/flutter/pull/100572).
    InvokeDartPluginRegistrantIfAvailable(library_handle);
  }

  auto user_entrypoint_function =
      ::Dart_GetField(library_handle, entrypoint_handle);

  auto entrypoint_args = tonic::ToDart(args);

  if (!InvokeMainEntrypoint(user_entrypoint_function, entrypoint_args)) {
    return false;
  }

  phase_ = Phase::Running;

  return true;
}

bool DartIsolate::Shutdown() {
  TRACE_EVENT0("flutter", "DartIsolate::Shutdown");
  // This call may be re-entrant since Dart_ShutdownIsolate can invoke the
  // cleanup callback which deletes the embedder side object of the dart isolate
  // (a.k.a. this).
  if (phase_ == Phase::Shutdown) {
    return false;
  }
  phase_ = Phase::Shutdown;
  Dart_Isolate vm_isolate = isolate();
  // The isolate can be nullptr if this instance is the stub isolate data used
  // during root isolate creation.
  if (vm_isolate != nullptr) {
    // We need to enter the isolate because Dart_ShutdownIsolate does not take
    // the isolate to shutdown as a parameter.
    FML_DCHECK(Dart_CurrentIsolate() == nullptr);
    Dart_EnterIsolate(vm_isolate);
    Dart_ShutdownIsolate();
    FML_DCHECK(Dart_CurrentIsolate() == nullptr);
  }
  return true;
}

Dart_Isolate DartIsolate::DartCreateAndStartServiceIsolate(
    const char* package_root,
    const char* package_config,
    Dart_IsolateFlags* flags,
    char** error) {
  auto vm_data = DartVMRef::GetVMData();

  if (!vm_data) {
    *error = fml::strdup(
        "Could not access VM data to initialize isolates. This may be because "
        "the VM has initialized shutdown on another thread already.");
    return nullptr;
  }

  const auto& settings = vm_data->GetSettings();

  if (!settings.enable_vm_service) {
    return nullptr;
  }

  flags->load_vmservice_library = true;

#if (FLUTTER_RUNTIME_MODE != FLUTTER_RUNTIME_MODE_DEBUG)
  // TODO(68663): The service isolate in debug mode is always launched without
  // sound null safety. Fix after the isolate snapshot data is created with the
  // right flags.
  flags->null_safety = vm_data->GetServiceIsolateSnapshotNullSafety();
#endif

  UIDartState::Context context(
      TaskRunners("io.flutter." DART_VM_SERVICE_ISOLATE_NAME, nullptr, nullptr,
                  nullptr, nullptr));
  context.advisory_script_uri = DART_VM_SERVICE_ISOLATE_NAME;
  context.advisory_script_entrypoint = DART_VM_SERVICE_ISOLATE_NAME;
  std::weak_ptr<DartIsolate> weak_service_isolate =
      DartIsolate::CreateRootIsolate(vm_data->GetSettings(),                //
                                     vm_data->GetServiceIsolateSnapshot(),  //
                                     nullptr,                               //
                                     DartIsolate::Flags{flags},             //
                                     nullptr,                               //
                                     nullptr,                               //
                                     context);                              //

  std::shared_ptr<DartIsolate> service_isolate = weak_service_isolate.lock();
  if (!service_isolate) {
    *error = fml::strdup("Could not create the service isolate.");
    FML_DLOG(ERROR) << *error;
    return nullptr;
  }

  tonic::DartState::Scope scope(service_isolate);
  if (!DartServiceIsolate::Startup(
          settings.vm_service_host,            // server IP address
          settings.vm_service_port,            // server VM service port
          tonic::DartState::HandleLibraryTag,  // embedder library tag handler
          false,  //  disable websocket origin check
          settings.disable_service_auth_codes,  // disable VM service auth codes
          settings.enable_service_port_fallback,  // enable fallback to port 0
                                                  // when bind fails.
          error                                   // error (out)
          )) {
    // Error is populated by call to startup.
    FML_DLOG(ERROR) << *error;
    return nullptr;
  }

  if (auto callback = vm_data->GetSettings().service_isolate_create_callback) {
    callback();
  }

  if (auto service_protocol = DartVMRef::GetServiceProtocol()) {
    service_protocol->ToggleHooks(true);
  } else {
    FML_DLOG(ERROR)
        << "Could not acquire the service protocol handlers. This might be "
           "because the VM has already begun teardown on another thread.";
  }

  return service_isolate->isolate();
}

DartIsolateGroupData& DartIsolate::GetIsolateGroupData() {
  std::shared_ptr<DartIsolateGroupData>* isolate_group_data =
      static_cast<std::shared_ptr<DartIsolateGroupData>*>(
          Dart_IsolateGroupData(isolate()));
  return **isolate_group_data;
}

const DartIsolateGroupData& DartIsolate::GetIsolateGroupData() const {
  DartIsolate* non_const_this = const_cast<DartIsolate*>(this);
  return non_const_this->GetIsolateGroupData();
}

// |Dart_IsolateGroupCreateCallback|
Dart_Isolate DartIsolate::DartIsolateGroupCreateCallback(
    const char* advisory_script_uri,
    const char* advisory_script_entrypoint,
    const char* package_root,
    const char* package_config,
    Dart_IsolateFlags* flags,
    std::shared_ptr<DartIsolate>* parent_isolate_data,
    char** error) {
  TRACE_EVENT0("flutter", "DartIsolate::DartIsolateGroupCreateCallback");
  if (parent_isolate_data == nullptr &&
      strcmp(advisory_script_uri, DART_VM_SERVICE_ISOLATE_NAME) == 0) {
    // The VM attempts to start the VM service for us on |Dart_Initialize|. In
    // such a case, the callback data will be null and the script URI will be
    // DART_VM_SERVICE_ISOLATE_NAME. In such cases, we just create the service
    // isolate like normal but dont hold a reference to it at all. We also start
    // this isolate since we will never again reference it from the engine.
    return DartCreateAndStartServiceIsolate(package_root,    //
                                            package_config,  //
                                            flags,           //
                                            error            //
    );
  }

  if (!parent_isolate_data) {
    return nullptr;
  }

  DartIsolateGroupData& parent_group_data =
      (*parent_isolate_data)->GetIsolateGroupData();

  if (strncmp(advisory_script_uri, kFileUriPrefix.data(),
              kFileUriPrefix.size())) {
    std::string error_msg =
        std::string("Unsupported isolate URI: ") + advisory_script_uri;
    *error = fml::strdup(error_msg.c_str());
    return nullptr;
  }

  auto isolate_group_data =
      std::make_unique<std::shared_ptr<DartIsolateGroupData>>(
          std::shared_ptr<DartIsolateGroupData>(new DartIsolateGroupData(
              parent_group_data.GetSettings(),
              parent_group_data.GetIsolateSnapshot(), advisory_script_uri,
              advisory_script_entrypoint,
              parent_group_data.GetChildIsolatePreparer(),
              parent_group_data.GetIsolateCreateCallback(),
              parent_group_data.GetIsolateShutdownCallback(),
              nullptr  // native_assets_manager
              )));

  TaskRunners null_task_runners(advisory_script_uri,
                                /* platform= */ nullptr,
                                /* raster= */ nullptr,
                                /* ui= */ nullptr,
                                /* io= */ nullptr);

  UIDartState::Context context(null_task_runners);
  context.advisory_script_uri = advisory_script_uri;
  context.advisory_script_entrypoint = advisory_script_entrypoint;
  auto isolate_data = std::make_unique<std::shared_ptr<DartIsolate>>(
      std::shared_ptr<DartIsolate>(
          new DartIsolate((*isolate_group_data)->GetSettings(),  // settings
                          false,       // is_root_isolate
                          context)));  // context

  Dart_Isolate vm_isolate = CreateDartIsolateGroup(
      std::move(isolate_group_data), std::move(isolate_data), flags, error,
      [](std::shared_ptr<DartIsolateGroupData>* isolate_group_data,
         std::shared_ptr<DartIsolate>* isolate_data, Dart_IsolateFlags* flags,
         char** error) {
        return Dart_CreateIsolateGroup(
            (*isolate_group_data)->GetAdvisoryScriptURI().c_str(),
            (*isolate_group_data)->GetAdvisoryScriptEntrypoint().c_str(),
            (*isolate_group_data)->GetIsolateSnapshot()->GetDataMapping(),
            (*isolate_group_data)
                ->GetIsolateSnapshot()
                ->GetInstructionsMapping(),
            flags, isolate_group_data, isolate_data, error);
      });

  if (*error) {
    FML_LOG(ERROR) << "CreateDartIsolateGroup failed: " << *error;
  }

  return vm_isolate;
}

// |Dart_IsolateInitializeCallback|
bool DartIsolate::DartIsolateInitializeCallback(void** child_callback_data,
                                                char** error) {
  TRACE_EVENT0("flutter", "DartIsolate::DartIsolateInitializeCallback");
  Dart_Isolate isolate = Dart_CurrentIsolate();
  if (isolate == nullptr) {
    *error = fml::strdup("Isolate should be available in initialize callback.");
    FML_DLOG(ERROR) << *error;
    return false;
  }

  auto* isolate_group_data =
      static_cast<std::shared_ptr<DartIsolateGroupData>*>(
          Dart_CurrentIsolateGroupData());

  TaskRunners null_task_runners((*isolate_group_data)->GetAdvisoryScriptURI(),
                                /* platform= */ nullptr,
                                /* raster= */ nullptr,
                                /* ui= */ nullptr,
                                /* io= */ nullptr);

  UIDartState::Context context(null_task_runners);
  context.advisory_script_uri = (*isolate_group_data)->GetAdvisoryScriptURI();
  context.advisory_script_entrypoint =
      (*isolate_group_data)->GetAdvisoryScriptEntrypoint();
  auto embedder_isolate = std::make_unique<std::shared_ptr<DartIsolate>>(
      std::shared_ptr<DartIsolate>(
          new DartIsolate((*isolate_group_data)->GetSettings(),  // settings
                          false,       // is_root_isolate
                          context)));  // context

  // root isolate should have been created via CreateRootIsolate
  if (!InitializeIsolate(*embedder_isolate, isolate, error)) {
    return false;
  }

  // The ownership of the embedder object is controlled by the Dart VM. So the
  // only reference returned to the caller is weak.
  *child_callback_data = embedder_isolate.release();

  return true;
}

static void* NativeAssetsDlopenRelative(const char* path, char** error) {
  auto* isolate_group_data =
      static_cast<std::shared_ptr<DartIsolateGroupData>*>(
          Dart_CurrentIsolateGroupData());
  const std::string& script_uri = (*isolate_group_data)->GetAdvisoryScriptURI();
  return dart::bin::NativeAssets::DlopenRelative(path, script_uri.data(),
                                                 error);
}

static void* NativeAssetsDlopen(const char* asset_id, char** error) {
  auto* isolate_group_data =
      static_cast<std::shared_ptr<DartIsolateGroupData>*>(
          Dart_CurrentIsolateGroupData());
  auto native_assets_manager = (*isolate_group_data)->GetNativeAssetsManager();
  if (native_assets_manager == nullptr) {
    return nullptr;
  }

  std::vector<std::string> asset_path =
      native_assets_manager->LookupNativeAsset(asset_id);
  if (asset_path.size() == 0) {
    // The asset id was not in the mapping.
    return nullptr;
  }

  auto& path_type = asset_path[0];
  std::string path;
  static constexpr const char* kAbsolute = "absolute";
  static constexpr const char* kExecutable = "executable";
  static constexpr const char* kProcess = "process";
  static constexpr const char* kRelative = "relative";
  static constexpr const char* kSystem = "system";
  if (path_type == kAbsolute || path_type == kRelative ||
      path_type == kSystem) {
    path = asset_path[1];
  }

  if (path_type == kAbsolute) {
    return dart::bin::NativeAssets::DlopenAbsolute(path.c_str(), error);
  } else if (path_type == kRelative) {
    return NativeAssetsDlopenRelative(path.c_str(), error);
  } else if (path_type == kSystem) {
    return dart::bin::NativeAssets::DlopenSystem(path.c_str(), error);
  } else if (path_type == kProcess) {
    return dart::bin::NativeAssets::DlopenProcess(error);
  } else if (path_type == kExecutable) {
    return dart::bin::NativeAssets::DlopenExecutable(error);
  }

  return nullptr;
}

static char* NativeAssetsAvailableAssets() {
  auto* isolate_group_data =
      static_cast<std::shared_ptr<DartIsolateGroupData>*>(
          Dart_CurrentIsolateGroupData());
  auto native_assets_manager = (*isolate_group_data)->GetNativeAssetsManager();
  FML_DCHECK(native_assets_manager != nullptr);
  auto available_assets = native_assets_manager->AvailableNativeAssets();
  auto* result = fml::strdup(available_assets.c_str());
  return result;
}

static void InitDartFFIForIsolateGroup() {
  NativeAssetsApi native_assets;
  memset(&native_assets, 0, sizeof(native_assets));
  // TODO(dacoharkes): Remove after flutter_tools stops kernel embedding.
  native_assets.dlopen_absolute = &dart::bin::NativeAssets::DlopenAbsolute;
  native_assets.dlopen_relative = &NativeAssetsDlopenRelative;
  native_assets.dlopen_system = &dart::bin::NativeAssets::DlopenSystem;
  native_assets.dlopen_executable = &dart::bin::NativeAssets::DlopenExecutable;
  native_assets.dlopen_process = &dart::bin::NativeAssets::DlopenProcess;
  // TODO(dacoharkes): End todo.
  native_assets.dlsym = &dart::bin::NativeAssets::Dlsym;
  native_assets.dlopen = &NativeAssetsDlopen;
  native_assets.available_assets = &NativeAssetsAvailableAssets;
  Dart_InitializeNativeAssetsResolver(&native_assets);
};

Dart_Isolate DartIsolate::CreateDartIsolateGroup(
    std::unique_ptr<std::shared_ptr<DartIsolateGroupData>> isolate_group_data,
    std::unique_ptr<std::shared_ptr<DartIsolate>> isolate_data,
    Dart_IsolateFlags* flags,
    char** error,
    const DartIsolate::IsolateMaker& make_isolate) {
  TRACE_EVENT0("flutter", "DartIsolate::CreateDartIsolateGroup");

  // Create the Dart VM isolate and give it the embedder object as the baton.
  Dart_Isolate isolate =
      make_isolate(isolate_group_data.get(), isolate_data.get(), flags, error);

  if (isolate == nullptr) {
    return nullptr;
  }

  bool success = false;
  {
    // Ownership of the isolate data objects has been transferred to the Dart
    // VM.
    // NOLINTBEGIN(clang-analyzer-cplusplus.NewDeleteLeaks)
    std::shared_ptr<DartIsolate> embedder_isolate(*isolate_data);
    isolate_group_data.release();
    isolate_data.release();
    // NOLINTEND(clang-analyzer-cplusplus.NewDeleteLeaks)

    InitDartFFIForIsolateGroup();

    success = InitializeIsolate(embedder_isolate, isolate, error);
  }
  if (!success) {
    Dart_ShutdownIsolate();
    return nullptr;
  }

  // Balances the implicit [Dart_EnterIsolate] by [make_isolate] above.
  Dart_ExitIsolate();
  return isolate;
}

bool DartIsolate::InitializeIsolate(
    const std::shared_ptr<DartIsolate>& embedder_isolate,
    Dart_Isolate isolate,
    char** error) {
  TRACE_EVENT0("flutter", "DartIsolate::InitializeIsolate");
  if (!embedder_isolate->Initialize(isolate)) {
    *error = fml::strdup("Embedder could not initialize the Dart isolate.");
    FML_DLOG(ERROR) << *error;
    return false;
  }

  if (!embedder_isolate->LoadLibraries()) {
    *error = fml::strdup(
        "Embedder could not load libraries in the new Dart isolate.");
    FML_DLOG(ERROR) << *error;
    return false;
  }

  // Root isolates will be set up by the engine and the service isolate
  // (which is also a root isolate) by the utility routines in the VM.
  // However, secondary isolates will be run by the VM if they are
  // marked as runnable.
  if (!embedder_isolate->IsRootIsolate()) {
    auto child_isolate_preparer =
        embedder_isolate->GetIsolateGroupData().GetChildIsolatePreparer();
    FML_DCHECK(child_isolate_preparer);
    if (!child_isolate_preparer(embedder_isolate.get())) {
      *error = fml::strdup("Could not prepare the child isolate to run.");
      FML_DLOG(ERROR) << *error;
      return false;
    }
  }

  return true;
}

// |Dart_IsolateShutdownCallback|
void DartIsolate::DartIsolateShutdownCallback(
    std::shared_ptr<DartIsolateGroupData>* isolate_group_data,
    std::shared_ptr<DartIsolate>* isolate_data) {
  TRACE_EVENT0("flutter", "DartIsolate::DartIsolateShutdownCallback");

  // If the isolate initialization failed there will be nothing to do.
  // This can happen e.g. during a [DartIsolateInitializeCallback] invocation
  // that fails to initialize the VM-created isolate.
  if (isolate_data == nullptr) {
    return;
  }

  isolate_data->get()->OnShutdownCallback();
}

// |Dart_IsolateGroupCleanupCallback|
void DartIsolate::DartIsolateGroupCleanupCallback(
    std::shared_ptr<DartIsolateGroupData>* isolate_data) {
  TRACE_EVENT0("flutter", "DartIsolate::DartIsolateGroupCleanupCallback");
  delete isolate_data;
}

// |Dart_IsolateCleanupCallback|
void DartIsolate::DartIsolateCleanupCallback(
    std::shared_ptr<DartIsolateGroupData>* isolate_group_data,
    std::shared_ptr<DartIsolate>* isolate_data) {
  TRACE_EVENT0("flutter", "DartIsolate::DartIsolateCleanupCallback");
  delete isolate_data;
}

std::weak_ptr<DartIsolate> DartIsolate::GetWeakIsolatePtr() {
  return std::static_pointer_cast<DartIsolate>(shared_from_this());
}

void DartIsolate::SetOwnerToCurrentThread() {
  tonic::DartIsolateScope isolate_scope(isolate());
  Dart_SetCurrentThreadOwnsIsolate();
}

void DartIsolate::AddIsolateShutdownCallback(const fml::closure& closure) {
  shutdown_callbacks_.emplace_back(std::make_unique<AutoFireClosure>(closure));
}

void DartIsolate::OnShutdownCallback() {
  tonic::DartState* state = tonic::DartState::Current();
  if (state != nullptr) {
    state->SetIsShuttingDown();
  }

  {
    tonic::DartApiScope api_scope;
    Dart_Handle sticky_error = Dart_GetStickyError();
    if (!Dart_IsNull(sticky_error) && !Dart_IsFatalError(sticky_error)) {
      FML_LOG(ERROR) << Dart_GetError(sticky_error);
    }
  }

  if (is_platform_isolate_) {
    FML_DCHECK(platform_isolate_manager_ != nullptr);
    platform_isolate_manager_->RemovePlatformIsolate(isolate());
  }

  shutdown_callbacks_.clear();

  const fml::closure& isolate_shutdown_callback =
      GetIsolateGroupData().GetIsolateShutdownCallback();
  if (isolate_shutdown_callback) {
    isolate_shutdown_callback();
  }
}

Dart_Handle DartIsolate::OnDartLoadLibrary(intptr_t loading_unit_id) {
  if (Current()->platform_configuration()) {
    Current()->platform_configuration()->client()->RequestDartDeferredLibrary(
        loading_unit_id);
    return Dart_Null();
  }
  const std::string error_message =
      "Platform Configuration was null. Deferred library load request "
      "for loading unit id " +
      std::to_string(loading_unit_id) + " was not sent.";
  FML_LOG(ERROR) << error_message;
  return Dart_NewApiError(error_message.c_str());
}

Dart_Handle DartIsolate::LoadLibraryFromKernel(
    const std::shared_ptr<const fml::Mapping>& mapping) {
  if (DartVM::IsRunningPrecompiledCode()) {
    return Dart_Null();
  }

  auto* isolate_group_data =
      static_cast<std::shared_ptr<DartIsolateGroupData>*>(
          Dart_CurrentIsolateGroupData());
  // Mapping must be retained until isolate shutdown.
  (*isolate_group_data)->AddKernelBuffer(mapping);

  auto lib =
      Dart_LoadLibraryFromKernel(mapping->GetMapping(), mapping->GetSize());
  if (tonic::CheckAndHandleError(lib)) {
    return Dart_Null();
  }
  auto result = Dart_FinalizeLoading(false);
  if (Dart_IsError(result)) {
    return result;
  }
  return Dart_GetField(lib, Dart_NewStringFromCString("main"));
}

DartIsolate::AutoFireClosure::AutoFireClosure(const fml::closure& closure)
    : closure_(closure) {}

DartIsolate::AutoFireClosure::~AutoFireClosure() {
  if (closure_) {
    closure_();
  }
}

}  // namespace flutter

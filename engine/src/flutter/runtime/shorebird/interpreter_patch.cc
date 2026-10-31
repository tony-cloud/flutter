// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
#include "flutter/runtime/shorebird/interpreter_patch.h"

#include <cstring>
#include <mutex>
#include <set>

#include "openssl/sha.h"
#include "rapidjson/document.h"

namespace flutter::shorebird {
namespace {
std::mutex provider_mutex;
InterpreterKeyProvider key_provider;
bool provider_sealed = false;
bool boot_selected = false;
bool main_completed = false;
std::shared_ptr<const InterpreterPatchConfig> process_patch;
thread_local const std::string* expected_key_id = nullptr;

bool ResolveKey(const char* key_id,
                uint8_t* buffer,
                intptr_t capacity,
                intptr_t* length) {
  if (!key_id || !buffer || !length || !expected_key_id ||
      *expected_key_id != key_id || capacity < 32) {
    return false;
  }
  InterpreterKeyProvider provider;
  {
    std::lock_guard<std::mutex> lock(provider_mutex);
    provider = key_provider;
  }
  *length = 0;
  if (!provider || !provider(key_id, buffer, capacity, length) ||
      *length != 32) {
    std::memset(buffer, 0, capacity);
    *length = 0;
    return false;
  }
  return true;
}

bool UniqueObject(const rapidjson::Value& value, size_t depth = 0) {
  if (depth > 16) {
    return false;
  }
  if (value.IsObject()) {
    std::set<std::string> names;
    for (auto it = value.MemberBegin(); it != value.MemberEnd(); ++it) {
      if (!names.emplace(it->name.GetString(), it->name.GetStringLength())
               .second ||
          !UniqueObject(it->value, depth + 1)) {
        return false;
      }
    }
  } else if (value.IsArray()) {
    for (const auto& element : value.GetArray()) {
      if (!UniqueObject(element, depth + 1)) {
        return false;
      }
    }
  }
  return true;
}

const char* StringField(const rapidjson::Value& object, const char* name) {
  if (!object.IsObject() || !object.HasMember(name) ||
      !object[name].IsString()) {
    return nullptr;
  }
  const auto& value = object[name];
  // C API expectations must not silently truncate embedded NULs.
  if (std::strlen(value.GetString()) != value.GetStringLength()) {
    return nullptr;
  }
  return value.GetString();
}

bool Hash(const char* value) {
  if (!value || std::strlen(value) != 64) {
    return false;
  }
  for (size_t i = 0; i < 64; ++i) {
    if (!((value[i] >= '0' && value[i] <= '9') ||
          (value[i] >= 'a' && value[i] <= 'f'))) {
      return false;
    }
  }
  return true;
}
constexpr size_t kMaxReplacementManifest = 4 * 1024 * 1024;
constexpr size_t kMaxReplacementComponent = 128 * 1024 * 1024;
constexpr size_t kReplacementHeaderSize = 24;

bool IsReplacementWrapper(const uint8_t* bytes, size_t size) {
  static constexpr uint8_t magic[] = {'S', 'B', 'R', 'P', 'L', 'C', 'E', 0};
  return bytes && size >= sizeof(magic) &&
         std::memcmp(bytes, magic, sizeof(magic)) == 0;
}

uint32_t UInt32(const uint8_t* bytes) {
  return static_cast<uint32_t>(bytes[0]) |
         (static_cast<uint32_t>(bytes[1]) << 8) |
         (static_cast<uint32_t>(bytes[2]) << 16) |
         (static_cast<uint32_t>(bytes[3]) << 24);
}

std::string Hex(const uint8_t* bytes, size_t size) {
  static constexpr char digits[] = "0123456789abcdef";
  std::string result;
  result.reserve(size * 2);
  for (size_t i = 0; i < size; ++i) {
    result.push_back(digits[bytes[i] >> 4]);
    result.push_back(digits[bytes[i] & 15]);
  }
  return result;
}

bool ValidateReplacementWrapper(const uint8_t* bytes,
                                size_t size,
                                const std::string& host_abi,
                                bool require_base,
                                std::string* error) {
  if (!Hash(host_abi.c_str()) || !IsReplacementWrapper(bytes, size) ||
      size < kReplacementHeaderSize || UInt32(bytes + 8) != 1) {
    *error = "Invalid full replacement profile, wrapper or host ABI";
    return false;
  }
  const uint32_t manifest_size = UInt32(bytes + 12);
  const uint64_t component_size =
      static_cast<uint64_t>(UInt32(bytes + 16)) |
      (static_cast<uint64_t>(UInt32(bytes + 20)) << 32);
  // The policy plus three digests precede the variable-length URI sets. Full
  // manifest/domain/component validation belongs to the native VM descriptor.
  if (manifest_size < 100 || manifest_size > kMaxReplacementManifest ||
      component_size == 0 || component_size > kMaxReplacementComponent ||
      size != kReplacementHeaderSize + manifest_size + component_size) {
    *error = "Invalid full replacement wrapper bounds";
    return false;
  }
  const uint8_t* manifest = bytes + kReplacementHeaderSize;
  if (UInt32(manifest) != 1 || Hex(manifest + 4, 32) != host_abi ||
      (require_base && std::memcmp(manifest + 36, manifest + 68, 32) != 0)) {
    *error = "Full replacement wrapper policy, host or base identity mismatch";
    return false;
  }
  return true;
}
}  // namespace

bool RegisterInterpreterKeyProvider(InterpreterKeyProvider provider) {
  std::lock_guard<std::mutex> lock(provider_mutex);
  if (!provider || provider_sealed || key_provider) {
    return false;
  }
  key_provider = std::move(provider);
  return true;
}

void SealInterpreterKeyProvider() {
  std::lock_guard<std::mutex> lock(provider_mutex);
  provider_sealed = true;
}

std::shared_ptr<const InterpreterPatchConfig> SelectInterpreterPatchForProcess(
    std::shared_ptr<const InterpreterPatchConfig> candidate) {
  std::lock_guard<std::mutex> lock(provider_mutex);
  if (!boot_selected) {
    process_patch = std::move(candidate);
    boot_selected = true;
  }
  return process_patch;
}

bool RejectInterpreterPatchForProcess() {
  std::lock_guard<std::mutex> lock(provider_mutex);
  if (main_completed) {
    return false;
  }
  process_patch.reset();
  boot_selected = true;
  return true;
}

void CompleteInterpreterMainForProcess(bool succeeded) {
  std::lock_guard<std::mutex> lock(provider_mutex);
  if (main_completed) {
    return;
  }
  if (!succeeded) {
    process_patch.reset();
    boot_selected = true;
  }
  main_completed = true;
}

void ResetInterpreterKeyProviderForTesting() {
  std::lock_guard<std::mutex> lock(provider_mutex);
  key_provider = {};
  provider_sealed = false;
  process_patch.reset();
  boot_selected = false;
  main_completed = false;
}

bool ApplyInterpreterPatch(const InterpreterPatchConfig& config,
                           const fml::Mapping& artifact,
                           InterpreterPatchApi& api,
                           std::string* error) {
  SealInterpreterKeyProvider();
  auto reject = [&](const char* message) {
    *error = message;
    return false;
  };
  if (!config.strict_verification || config.app_id.empty() ||
      config.app_build_id.empty() || config.base_flavor_id.empty() ||
      config.base_license_type.empty() || config.sdk_hash.empty() ||
      !Hash(config.base_snapshot_hash.c_str()) || config.key_id.empty() ||
      (config.full_replacement && !Hash(config.host_abi.c_str()))) {
    return reject(
        "Interpreter patch expectations are incomplete or verification is not "
        "strict");
  }
  if (!artifact.GetMapping() || artifact.GetSize() == 0 ||
      artifact.GetSize() > 256 * 1024 * 1024) {
    return reject("Interpreter patch artifact is empty or too large");
  }
  rapidjson::Document envelope;
  envelope.Parse<rapidjson::kParseValidateEncodingFlag |
                 rapidjson::kParseIterativeFlag>(
      reinterpret_cast<const char*>(artifact.GetMapping()), artifact.GetSize());
  if (envelope.HasParseError() || !envelope.IsObject() ||
      !UniqueObject(envelope) || !envelope.HasMember("metadata") ||
      !envelope.HasMember("encryption")) {
    return reject("Invalid interpreter patch envelope");
  }
  const auto& metadata = envelope["metadata"];
  const char* patch_hash = StringField(metadata, "patch_snapshot_hash");
  const char* flavor = StringField(metadata, "flavor_id");
  const char* license = StringField(metadata, "license_type");
  const char* runtime = StringField(metadata, "runtime_mode");
  const char* key_id = StringField(envelope["encryption"], "key_id");
  const char* payload_kind = StringField(envelope, "payload_kind");
  if (!flavor || !*flavor || !license || !*license ||
      (!config.flavor_id.empty() && config.flavor_id != flavor) ||
      (!config.license_type.empty() && config.license_type != license) ||
      !Hash(patch_hash) || !runtime ||
      std::strcmp(runtime, "dart-bytecode-interpreter") != 0 || !key_id ||
      config.key_id != key_id || !payload_kind ||
      std::strcmp(payload_kind, "full-snapshot") != 0) {
    return reject(
        "Interpreter patch mode, payload hash, or key id does not match");
  }
  {
    std::lock_guard<std::mutex> lock(provider_mutex);
    if (!key_provider) {
      return reject("No app-owned interpreter key provider registered");
    }
  }

  Dart_AotPatchInstallOptions options{};
  options.app_id = config.app_id.c_str();
  options.app_build_id = config.app_build_id.c_str();
  options.base_flavor_id = config.base_flavor_id.c_str();
  options.base_license_type = config.base_license_type.c_str();
  // Optional bundle restrictions take precedence. Otherwise the authenticated
  // target is authorized by the app providing this envelope's licensed key.
  options.flavor_id = flavor;
  options.license_type = license;
  options.sdk_hash = config.sdk_hash.c_str();
  options.base_snapshot_hash = config.base_snapshot_hash.c_str();
  options.patch_snapshot_hash = patch_hash;
  options.obfuscation_map_hash = config.obfuscation_map_hash.empty()
                                     ? nullptr
                                     : config.obfuscation_map_hash.c_str();
  options.target_os = "ios";
  options.target_arch = "arm64";
  options.runtime_mode = "dart-bytecode-interpreter";

  // The SDK authenticates the metadata with AES-GCM before this hash is used.
  // The updater additionally pins the downloaded artifact's publisher hash.
  expected_key_id = &config.key_id;
  api.SetKeyCallback(ResolveKey);
  uint8_t* payload = nullptr;
  intptr_t length = 0;
  bool installed = api.Install(artifact, options, &payload, &length, error);
  expected_key_id = nullptr;
  bool reloaded = false;
  if (installed && payload && length > 0) {
    // Decryption/authentication stays unchanged. Reject profile mixing before
    // asking the VM to stage any declarations; it owns final descriptor checks.
    if (config.full_replacement) {
      if (ValidateReplacementWrapper(payload, length, config.host_abi, false,
                                     error)) {
        reloaded = api.Reload(payload, length, error);
      }
    } else if (IsReplacementWrapper(payload, length)) {
      *error = "Full replacement update requires a full replacement release";
    } else {
      reloaded = api.Reload(payload, length, error);
    }
  } else if (installed) {
    *error = "Interpreter patch decrypted to an empty payload";
  }
  // Always free, including errors after the SDK allocated a plaintext buffer.
  if (payload) {
    api.FreePayload(payload);
  }
  return installed && reloaded;
}
bool InstallInterpreterCodeForFreshGroup(
    const InterpreterPatchConfig* patch,
    const InterpreterReplacementBaseConfig* base,
    const std::function<bool()>& install_patch,
    const std::function<bool()>& install_base,
    std::string* error) {
  if (base && !base->validation_error.empty()) {
    *error = base->validation_error;
    return false;
  }
  if (patch) {
    if (patch->full_replacement != (base != nullptr) ||
        (base && (patch->host_abi != base->host_abi ||
                  patch->base_snapshot_hash != base->snapshot_hash))) {
      *error = "Selected interpreter update does not match the bundled profile";
      return false;
    }
    return install_patch();
  }
  return !base || install_base();
}

bool ValidateInterpreterReplacementBase(
    const InterpreterReplacementBaseConfig& config,
    const fml::Mapping& artifact,
    std::string* error) {
  if (!config.validation_error.empty()) {
    *error = config.validation_error;
    return false;
  }
  const std::string filename = std::string("/") + kReplacementBaseAsset;
  if (config.path.size() <= filename.size() ||
      config.path.compare(config.path.size() - filename.size(), filename.size(),
                          filename) != 0 ||
      !Hash(config.snapshot_hash.c_str())) {
    *error = "Incomplete bundled replacement base configuration";
    return false;
  }
  if (!ValidateReplacementWrapper(artifact.GetMapping(), artifact.GetSize(),
                                  config.host_abi, true, error)) {
    return false;
  }
  uint8_t digest[SHA256_DIGEST_LENGTH];
  SHA256(artifact.GetMapping(), artifact.GetSize(), digest);
  if (Hex(digest, sizeof(digest)) != config.snapshot_hash) {
    *error = "Bundled replacement base hash mismatch";
    return false;
  }
  return true;
}

bool ApplyInterpreterReplacementBase(
    const InterpreterReplacementBaseConfig& config,
    const fml::Mapping& artifact,
    InterpreterPatchApi& api,
    std::string* error) {
  return ValidateInterpreterReplacementBase(config, artifact, error) &&
         api.Reload(artifact.GetMapping(), artifact.GetSize(), error);
}
}  // namespace flutter::shorebird

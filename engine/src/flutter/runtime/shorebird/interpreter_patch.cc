// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
#include "flutter/runtime/shorebird/interpreter_patch.h"

#include <cstdio>
#include <cstring>
#include <ctime>
#include <initializer_list>
#include <mutex>
#include <set>
#include <vector>

#include "openssl/sha.h"
#include "rapidjson/document.h"

namespace flutter::shorebird {
namespace {
std::mutex provider_mutex;
InterpreterKeyProvider key_provider;
InterpreterKeyProviderV2 key_provider_v2;
bool provider_sealed = false;
bool boot_selected = false;
bool main_completed = false;
bool source_committed = false;
bool committed_source_failed = false;
std::shared_ptr<const InterpreterPatchConfig> process_patch;
thread_local const std::string* expected_key_id = nullptr;
thread_local const std::string* verified_key_context = nullptr;
class ScopedKeyContext {
 public:
  ScopedKeyContext(const std::string& key, const std::string* context)
      : previous_key_(expected_key_id),
        previous_context_(verified_key_context) {
    expected_key_id = &key;
    verified_key_context = context;
  }
  ~ScopedKeyContext() {
    expected_key_id = previous_key_;
    verified_key_context = previous_context_;
  }

 private:
  const std::string* previous_key_;
  const std::string* previous_context_;
};

bool ResolveKey(const char* key_id,
                uint8_t* buffer,
                intptr_t capacity,
                intptr_t* length) {
  if (!key_id || !buffer || !length || !expected_key_id ||
      *expected_key_id != key_id || capacity < 32) {
    return false;
  }
  InterpreterKeyProvider provider;
  InterpreterKeyProviderV2 provider_v2;
  {
    std::lock_guard<std::mutex> lock(provider_mutex);
    provider = key_provider;
    provider_v2 = key_provider_v2;
  }
  *length = 0;
  const bool provided =
      verified_key_context
          ? provider_v2 && provider_v2(key_id, *verified_key_context, buffer,
                                       capacity, length)
          : provider && provider(key_id, buffer, capacity, length);
  if (!provided || *length != 32) {
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
bool ExactFields(const rapidjson::Value& object,
                 std::initializer_list<const char*> fields) {
  if (!object.IsObject() || object.MemberCount() != fields.size())
    return false;
  for (const auto field : fields)
    if (!object.HasMember(field))
      return false;
  return true;
}
bool Decimal(const rapidjson::Value& value,
             uint64_t maximum,
             uint64_t* result) {
  if (!value.IsString() || value.GetStringLength() == 0)
    return false;
  const std::string text(value.GetString(), value.GetStringLength());
  if (text.size() > 1 && text.front() == '0')
    return false;
  *result = 0;
  for (char digit : text) {
    if (digit < '0' || digit > '9' || *result > (maximum - (digit - '0')) / 10)
      return false;
    *result = *result * 10 + digit - '0';
  }
  return true;
}
// These spellings belong to different protocols. Never derive the trusted
// expectation from an artifact or equate updater wire names with SDK names.
struct InterpreterTargetIdentity {
  const char* platform;
  const char* wire_arch;
  const char* envelope_arch;
};
bool TargetIdentity(InterpreterPatchTarget target,
                    InterpreterTargetIdentity* identity) {
  switch (target) {
    case InterpreterPatchTarget::kIOSArm64:
      *identity = {"ios", "aarch64", "arm64"};
      return true;
    case InterpreterPatchTarget::kMacOSArm64:
      *identity = {"macos", "aarch64", "arm64"};
      return true;
    case InterpreterPatchTarget::kMacOSX64:
      *identity = {"macos", "x86_64", "x64"};
      return true;
  }
  return false;
}
std::string Hex(const uint8_t* bytes, size_t size);
bool ValidateSelection(const InterpreterPatchConfig& config,
                       const fml::Mapping& artifact,
                       const rapidjson::Value& envelope,
                       std::string* selected_key,
                       std::string* error) {
  auto reject = [&] {
    *error =
        "Selected interpreter artifact does not match verified v2 authority";
    return false;
  };
  if (config.selection_id == 0 || !config.begin_boot_source ||
      !config.owned_artifact || config.verified_selection_json.empty() ||
      config.verified_selection_json.size() > 64 * 1024 ||
      config.owned_artifact->GetMapping() != artifact.GetMapping() ||
      config.owned_artifact->GetSize() != artifact.GetSize())
    return reject();
  rapidjson::Document context;
  context.Parse<rapidjson::kParseValidateEncodingFlag |
                rapidjson::kParseIterativeFlag>(
      config.verified_selection_json.data(),
      config.verified_selection_json.size());
  if (context.HasParseError() || !UniqueObject(context) ||
      !ExactFields(context, {"version", "selection", "selection_digest"}) ||
      !context["version"].IsInt() || context["version"].GetInt() != 2 ||
      !Hash(StringField(context, "selection_digest")))
    return reject();
  const auto& selection = context["selection"];
  if (!ExactFields(selection,
                   {"epoch", "scope", "channel", "variant_id", "license_type",
                    "entitlement_revision", "target", "not_before",
                    "offline_valid_until", "fallback"}))
    return reject();
  const auto& scope = selection["scope"];
  const auto& target = selection["target"];
  const auto& fallback = selection["fallback"];
  if (!ExactFields(scope, {"app_id", "release_version", "platform", "arch",
                           "client_id_hash", "base_artifact_hash",
                           "host_abi_hash", "runtime_profile"}) ||
      !ExactFields(target, {"kind", "patch_number", "artifact_hash",
                            "encryption", "artifact_key_id"}) ||
      !ExactFields(fallback, {"kind", "variant_id", "license_type"}))
    return reject();
  auto equal = [](const rapidjson::Value& object, const char* key,
                  const std::string& expected) {
    const char* actual = StringField(object, key);
    return actual && actual == expected;
  };
  uint64_t epoch, number, not_before, expiry = 0;
  if (!Decimal(selection["epoch"], INT64_MAX, &epoch) || epoch == 0 ||
      !Decimal(target["patch_number"], INT32_MAX, &number) ||
      number != config.patch_number || number == 0 ||
      !Decimal(selection["not_before"], 253402300799ULL, &not_before) ||
      (!selection["offline_valid_until"].IsNull() &&
       (!Decimal(selection["offline_valid_until"], 253402300799ULL, &expiry) ||
        expiry <= not_before)))
    return reject();
  const auto now = std::time(nullptr);
  if (!config.boot_source_begun ||
      (!config.boot_source_begun->load() &&
       (now < 0 || static_cast<uint64_t>(now) < not_before ||
        (expiry != 0 && static_cast<uint64_t>(now) >= expiry))))
    return reject();
  InterpreterTargetIdentity identity;
  if (!TargetIdentity(config.target, &identity) ||
      (config.target != InterpreterPatchTarget::kIOSArm64 &&
       (!config.full_replacement ||
        config.runtime_profile != "interpreter-full")))
    return reject();
  if (!equal(scope, "app_id", config.app_id) ||
      !equal(scope, "release_version", config.release_version) ||
      !equal(scope, "platform", identity.platform) ||
      !equal(scope, "arch", identity.wire_arch) ||
      !equal(scope, "base_artifact_hash", config.base_snapshot_hash) ||
      !equal(scope, "runtime_profile", config.runtime_profile) ||
      !Hash(StringField(scope, "client_id_hash")) ||
      (config.full_replacement ? !equal(scope, "host_abi_hash", config.host_abi)
                               : !scope["host_abi_hash"].IsNull()) ||
      !equal(target, "kind", "patch") ||
      !equal(target, "encryption", "artifact-aes-256-gcm") ||
      !equal(fallback, "kind", "base") ||
      !equal(fallback, "variant_id", "free") ||
      !equal(fallback, "license_type", "free"))
    return reject();
  const char* flavor = StringField(selection, "variant_id");
  const char* license = StringField(selection, "license_type");
  const char* key = StringField(target, "artifact_key_id");
  const char* hash = StringField(target, "artifact_hash");
  if (!flavor || !*flavor || !license || !*license || !key || !*key ||
      !Hash(hash) || !equal(envelope["metadata"], "flavor_id", flavor) ||
      !equal(envelope["metadata"], "license_type", license) ||
      !equal(envelope["metadata"], "target_os", identity.platform) ||
      !equal(envelope["metadata"], "target_arch", identity.envelope_arch) ||
      !equal(envelope["metadata"], "app_id", config.app_id) ||
      !equal(envelope["metadata"], "app_build_id", config.app_build_id) ||
      !equal(envelope["metadata"], "base_snapshot_hash",
             config.base_snapshot_hash) ||
      !equal(envelope["encryption"], "key_id", key))
    return reject();
  uint8_t digest[SHA256_DIGEST_LENGTH];
  SHA256(artifact.GetMapping(), artifact.GetSize(), digest);
  if (Hex(digest, sizeof(digest)) != hash)
    return reject();
  *selected_key = key;
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

bool RegisterInterpreterKeyProviderV2(InterpreterKeyProviderV2 provider) {
  std::lock_guard<std::mutex> lock(provider_mutex);
  if (!provider || provider_sealed || key_provider_v2)
    return false;
  key_provider_v2 = std::move(provider);
  return true;
}

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

bool CommitInterpreterSourceForProcess(const InterpreterPatchConfig* expected) {
  std::lock_guard<std::mutex> lock(provider_mutex);
  if (committed_source_failed || process_patch.get() != expected) {
    return false;
  }
  // A BASE-only interpreter host may not have configured an updater. It still
  // commits its explicit source before any application code becomes runnable.
  boot_selected = true;
  source_committed = true;
  return true;
}

bool RejectInterpreterPatchForProcess(
    const std::function<void()>& report_outcome) {
  std::lock_guard<std::mutex> lock(provider_mutex);
  if (committed_source_failed || (source_committed && process_patch)) {
    return false;
  }
  if (boot_selected && !process_patch) {
    // BASE already won. A concurrently installed stale patch must destroy its
    // group and may retry that same BASE without reporting another outcome.
    return true;
  }
  // Another UI runner must not select BASE or report its main's success until
  // this candidate's outcome (including failed persistence) is finalized.
  if (report_outcome) {
    report_outcome();
  }
  process_patch.reset();
  boot_selected = true;
  source_committed = true;
  return true;
}

void CompleteInterpreterMainForProcess(
    bool succeeded,
    const std::function<void()>& report_outcome) {
  std::lock_guard<std::mutex> lock(provider_mutex);
  // Order actual-main completion with rejection too. A later loader failure
  // cannot claim the updater's outcome before this main's success report.
  // Later reports retain the updater's once-only outcome/update-thread guards.
  if (report_outcome) {
    report_outcome();
  }
  if (main_completed) {
    return;
  }
  // Actual-main completion implies commitment even for callers that merely
  // report their existing process context. A failed committed startup cannot
  // execute BASE in this process; keep its source and require a cold restart.
  boot_selected = true;
  source_committed = true;
  committed_source_failed = !succeeded;
  main_completed = true;
}

void ResetInterpreterKeyProviderForTesting() {
  std::lock_guard<std::mutex> lock(provider_mutex);
  key_provider = {};
  key_provider_v2 = {};
  provider_sealed = false;
  process_patch.reset();
  boot_selected = false;
  main_completed = false;
  source_committed = false;
  committed_source_failed = false;
}

bool ApplyInterpreterPatch(const InterpreterPatchConfig& config,
                           const fml::Mapping& artifact,
                           InterpreterPatchApi& api,
                           std::string* error,
                           Dart_AotPatchInstallStatus* status) {
  if (status) {
    *status = kDartAotPatchInstallRejected;
  }
  SealInterpreterKeyProvider();
  auto reject = [&](const char* message) {
    *error = message;
    return false;
  };
  if (!config.strict_verification || config.app_id.empty() ||
      config.app_build_id.empty() || config.base_flavor_id.empty() ||
      config.base_license_type.empty() || config.sdk_hash.empty() ||
      !Hash(config.base_snapshot_hash.c_str()) ||
      (!config.selection_protocol_v2 && config.key_id.empty()) ||
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
  std::string selected_key = config.key_id;
  if (config.selection_protocol_v2 &&
      !ValidateSelection(config, artifact, envelope, &selected_key, error))
    return false;
  const auto& metadata = envelope["metadata"];
  const char* patch_hash = StringField(metadata, "patch_snapshot_hash");
  const char* flavor = StringField(metadata, "flavor_id");
  const char* license = StringField(metadata, "license_type");
  const char* runtime = StringField(metadata, "runtime_mode");
  const char* key_id = StringField(envelope["encryption"], "key_id");
  const char* payload_kind = StringField(envelope, "payload_kind");
  if (!flavor || !*flavor || !license || !*license ||
      (!config.selection_protocol_v2 && !config.flavor_id.empty() &&
       config.flavor_id != flavor) ||
      (!config.selection_protocol_v2 && !config.license_type.empty() &&
       config.license_type != license) ||
      !Hash(patch_hash) || !runtime ||
      std::strcmp(runtime, "dart-bytecode-interpreter") != 0 || !key_id ||
      selected_key != key_id || !payload_kind ||
      std::strcmp(payload_kind, "full-snapshot") != 0) {
    return reject(
        "Interpreter patch mode, payload hash, or key id does not match");
  }
  InterpreterTargetIdentity identity;
  if (!TargetIdentity(config.target, &identity)) {
    return reject("Unsupported interpreter patch platform");
  }
  const char* target_os = StringField(metadata, "target_os");
  const char* target_arch = StringField(metadata, "target_arch");
  if (!target_os || std::strcmp(target_os, identity.platform) != 0 ||
      !target_arch || std::strcmp(target_arch, identity.envelope_arch) != 0) {
    return reject("Interpreter patch platform or architecture does not match");
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
  options.target_os = identity.platform;
  options.target_arch = identity.envelope_arch;
  options.runtime_mode = "dart-bytecode-interpreter";

  // The SDK authenticates the metadata with AES-GCM before this hash is used.
  // The updater additionally pins the downloaded artifact's publisher hash.
  if (config.selection_protocol_v2) {
    if (!config.begin_boot_source()) {
      return reject(
          "Prepared interpreter selection is stale or could not begin");
    }
    config.boot_source_begun->store(true);
  }
  api.SetKeyCallback(ResolveKey);
  uint8_t* payload = nullptr;
  intptr_t length = 0;
  Dart_AotPatchInstallStatus install_status = kDartAotPatchInstallRejected;
  bool installed;
  {
    ScopedKeyContext key_context(selected_key,
                                 config.selection_protocol_v2
                                     ? &config.verified_selection_json
                                     : nullptr);
    installed = api.Install(artifact, options, &payload, &length, error,
                            &install_status);
  }
  if (!installed && status && IsInterpreterPatchKeyFailure(install_status)) {
    *status = install_status;
  }
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
  if (installed && reloaded && status) {
    *status = kDartAotPatchInstallSuccess;
  }
  return installed && reloaded;
}

std::shared_ptr<const fml::Mapping> LoadOwnedInterpreterArtifact(
    const std::string& path) {
  std::unique_ptr<FILE, decltype(&std::fclose)> file(
      std::fopen(path.c_str(), "rb"), std::fclose);
  if (!file || std::fseek(file.get(), 0, SEEK_END) != 0)
    return nullptr;
  const long length = std::ftell(file.get());
  if (length <= 0 || static_cast<uint64_t>(length) > 256 * 1024 * 1024 ||
      std::fseek(file.get(), 0, SEEK_SET) != 0)
    return nullptr;
  std::vector<uint8_t> bytes(length);
  if (std::fread(bytes.data(), 1, bytes.size(), file.get()) != bytes.size() ||
      std::fgetc(file.get()) != EOF)
    return nullptr;
  return std::make_shared<const fml::DataMapping>(std::move(bytes));
}

bool IsInterpreterPatchKeyFailure(Dart_AotPatchInstallStatus status) {
  return status == kDartAotPatchInstallKeyUnavailable ||
         status == kDartAotPatchInstallAuthenticationFailed;
}
bool IsInterpreterPatchRetryableFailure(const InterpreterPatchConfig& config,
                                        Dart_AotPatchInstallStatus status) {
  return IsInterpreterPatchKeyFailure(status) ||
         (config.selection_protocol_v2 && config.owned_artifact_read_failed &&
          !config.owned_artifact);
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
